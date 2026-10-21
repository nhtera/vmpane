//! The controls of the frontmost app's focused window through the accessibility API (AXUIElement), for
//! `screen.elements` in the user-session LaunchAgent. macOS lets only processes the user has granted
//! Accessibility (System Settings › Privacy & Security › Accessibility) read other apps' controls; without it the
//! answer is `permissionDenied`, and the first such answer asks macOS to show its prompt.

use std::collections::VecDeque;
use std::ffi::c_void;
use std::path::PathBuf;
use std::ptr::NonNull;

use objc2_application_services::{
    AXCopyMultipleAttributeOptions, AXError, AXIsProcessTrusted, AXIsProcessTrustedWithOptions,
    AXUIElement, AXValue, AXValueType,
};
use objc2_core_foundation::{
    CFArray, CFBoolean, CFDictionary, CFRetained, CFString, CFType, CGPoint, CGSize, Type,
};
use vmpane_agent_proto::limits::SCREEN_MAX_DEPTH;
use vmpane_agent_proto::methods::{ScreenElement, ScreenElements};

/// Why the controls could not be read.
pub enum AxError {
    /// The user has not granted the agent Accessibility.
    NotTrusted,
    Other(String),
}

/// Read for every element, in one call each.
const ATTRIBUTES: [&str; 10] = [
    "AXRole",
    "AXSubrole",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXPosition",
    "AXSize",
    "AXEnabled",
    "AXFocused",
    "AXChildren",
];

/// Up to `max` controls of the focused window of the frontmost app, top to bottom, boxes in display pixels.
/// The most elements one read visits, and how long it may take: a huge tree (a long web page) gives a partial,
/// truncated answer rather than none.
const MAX_VISITS: usize = 4000;
const READ_DEADLINE: std::time::Duration = std::time::Duration::from_secs(2);
/// How long one call into the app may take before it counts as not answering (seconds).
const APP_TIMEOUT: f32 = 1.0;

/// Up to `max` controls of the focused window of the frontmost app, top to bottom, in display points (the answer
/// says so in `space`: the helper scales them to the display's pixels). Only what is on screen: each element is
/// clipped to its window and to every scroll area above it, and dropped when nothing of it is left; text areas
/// give no value (their whole text, scrolled-away lines included).
pub fn screen_elements(max: usize) -> Result<ScreenElements, AxError> {
    // SAFETY: creating the system-wide element has no preconditions.
    let system = unsafe { AXUIElement::new_system_wide() };
    // Trusted or not as of now: this runs in a process of its own each time (`screen::read`), so the check is not
    // the stale first answer a long-running process keeps.
    // SAFETY: a plain query of this process's trust.
    if !unsafe { AXIsProcessTrusted() } {
        ask_for_accessibility_once();
        return Err(AxError::NotTrusted);
    }
    let app = element(&system, "AXFocusedApplication")
        .ok()
        .or_else(front_app)
        .ok_or_else(|| AxError::Other("no app is in front".into()))?;
    // SAFETY: a positive timeout on an element this function holds.
    unsafe { app.set_messaging_timeout(APP_TIMEOUT) };
    let window = element(&app, "AXFocusedWindow")
        .or_else(|_| element(&app, "AXMainWindow"))
        .map_err(|_| AxError::Other("the app in front has no window".into()))?;
    let names: Vec<CFRetained<CFString>> =
        ATTRIBUTES.iter().map(|a| CFString::from_str(a)).collect();
    let names = CFArray::from_retained_objects(&names);
    let started = std::time::Instant::now();
    let mut found = ScreenElements {
        space: Some(display_points()),
        ..ScreenElements::default()
    };
    // Each element with the area it can show in (its window's, narrowed by scroll areas above it).
    let mut queue = VecDeque::from([(window, 0u32, None::<Rect>)]);
    let mut visits = 0;
    while let Some((element, depth, clip)) = queue.pop_front() {
        visits += 1;
        if visits > MAX_VISITS || started.elapsed() > READ_DEADLINE {
            found.truncated = true;
            break;
        }
        let Some(values) = attributes(&element, &names) else {
            continue;
        };
        let ax_role = string(&values[0]).unwrap_or_default();
        let frame = match (point(&values[5]), size(&values[6])) {
            (Some(origin), Some(size)) => Some(Rect::new(origin, size)),
            _ => None,
        };
        // What of it shows: the window clips everything in it; a scroll area clips what is inside it.
        let visible = match (frame, clip) {
            (Some(frame), Some(clip)) => frame.intersection(&clip),
            (frame, None) => frame,
            (None, clip) => clip,
        };
        let inner_clip = if clip.is_none() || ax_role == "AXScrollArea" {
            visible
        } else {
            clip
        };
        let children = values[9].as_ref().and_then(|v| v.downcast_ref::<CFArray>());
        if let Some(children) = children.filter(|_| depth < SCREEN_MAX_DEPTH && visible.is_some()) {
            // SAFETY: an array of CF objects.
            for child in unsafe { children.cast_unchecked::<CFType>() }.iter() {
                if let Some(child) = child.downcast_ref::<AXUIElement>() {
                    queue.push_back((child.retain(), depth + 1, inner_clip));
                }
            }
        }
        let Some(shown) = visible.filter(|_| frame.is_some()) else {
            continue;
        };
        let role = role(&ax_role);
        let text = string(&values[4]);
        // Static text's words are its value; other controls are named by a title or a description.
        let name = if role == "text" {
            text.clone().unwrap_or_default()
        } else {
            string(&values[2])
                .filter(|t| !t.is_empty())
                .or_else(|| string(&values[3]))
                .unwrap_or_default()
        };
        if name.trim().is_empty() && !crate::screen::interactive(&role) {
            continue;
        }
        if found.elements.len() == max {
            found.truncated = true;
            break;
        }
        // No value for static text (it is the name), password fields, and text areas (all their text).
        let secure = string(&values[1]).as_deref() == Some("AXSecureTextField");
        let hidden_value = role == "text" || secure || ax_role == "AXTextArea";
        found.elements.push(ScreenElement {
            value: if hidden_value {
                None
            } else {
                text.filter(|t| !t.is_empty())
            },
            role,
            name,
            rect: shown.rounded(),
            enabled: boolean(&values[7]).unwrap_or(true),
            focused: boolean(&values[8]).unwrap_or(false),
        });
    }
    Ok(found)
}

/// A rectangle in display points.
#[derive(Clone, Copy)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Rect {
    fn new(origin: CGPoint, size: CGSize) -> Rect {
        Rect {
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height,
        }
    }

    /// The common part, if any.
    fn intersection(&self, other: &Rect) -> Option<Rect> {
        let (left, top) = (self.x.max(other.x), self.y.max(other.y));
        let right = (self.x + self.width).min(other.x + other.width);
        let bottom = (self.y + self.height).min(other.y + other.height);
        (right > left && bottom > top).then_some(Rect {
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
        })
    }

    fn rounded(&self) -> [i32; 4] {
        [self.x, self.y, self.width, self.height].map(|v| v.round() as i32)
    }
}

/// The first time controls are asked for without the grant: macOS shows its "allow Accessibility" prompt, which
/// also lists the agent in System Settings. Once per user (a marker file), so nobody is asked again and again.
fn ask_for_accessibility_once() {
    // In the agent's own folder of the user's Library; without a home there is nowhere to remember it: no prompt.
    let Some(home) = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|h| h.is_absolute())
    else {
        return;
    };
    let marker = home.join("Library/Application Support/VMPane Agent/accessibility-asked");
    if marker.exists() {
        return;
    }
    let key = CFString::from_static_str("AXTrustedCheckOptionPrompt");
    let options = CFDictionary::from_slices(&[&*key], &[CFBoolean::new(true)]);
    // SAFETY: the options dictionary lives across the call.
    unsafe { AXIsProcessTrustedWithOptions(Some(options.as_opaque())) };
    if let Some(dir) = marker.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(&marker, b"");
}

/// The app in front as AppKit knows it: the system-wide element does not always answer a process that is not an
/// app itself (the agent's reader).
fn front_app() -> Option<CFRetained<AXUIElement>> {
    let pid = objc2_app_kit::NSWorkspace::sharedWorkspace()
        .frontmostApplication()?
        .processIdentifier();
    // SAFETY: creating an application element has no preconditions.
    (pid > 0).then(|| unsafe { AXUIElement::new_application(pid) })
}

/// One attribute that is itself an element.
fn element(of: &AXUIElement, name: &str) -> Result<CFRetained<AXUIElement>, AXError> {
    let mut value: *const CFType = std::ptr::null();
    // SAFETY: `value` is a valid out pointer; on success it holds a +1 reference this function takes over.
    let error =
        unsafe { of.copy_attribute_value(&CFString::from_str(name), NonNull::from(&mut value)) };
    if error != AXError::Success || value.is_null() {
        return Err(if error == AXError::Success {
            AXError::NoValue
        } else {
            error
        });
    }
    // SAFETY: a non-null +1 reference from a Copy function.
    let value = unsafe { CFRetained::from_raw(NonNull::new_unchecked(value.cast_mut())) };
    value
        .downcast::<AXUIElement>()
        .map_err(|_| AXError::IllegalArgument)
}

/// `ATTRIBUTES` of `element`, each none when it has no such attribute.
fn attributes(
    element: &AXUIElement,
    names: &CFArray<CFString>,
) -> Option<Vec<Option<CFRetained<CFType>>>> {
    let mut values: *const CFArray = std::ptr::null();
    // SAFETY: `values` is a valid out pointer; on success it holds a +1 reference this function takes over.
    let error = unsafe {
        element.copy_multiple_attribute_values(
            names.as_opaque(),
            AXCopyMultipleAttributeOptions::empty(),
            NonNull::from(&mut values),
        )
    };
    if error != AXError::Success || values.is_null() {
        return None;
    }
    // SAFETY: a non-null +1 reference from a Copy function.
    let values = unsafe { CFRetained::from_raw(NonNull::new_unchecked(values.cast_mut())) };
    // SAFETY: an array of CF objects.
    let values = unsafe { values.cast_unchecked::<CFType>() };
    Some(
        (0..ATTRIBUTES.len())
            .map(|index| values.get(index).filter(|value| !is_error(value)))
            .collect(),
    )
}

/// A missing attribute comes back as an AXValue holding an AXError.
fn is_error(value: &CFType) -> bool {
    value
        .downcast_ref::<AXValue>()
        // SAFETY: reading a value's type has no preconditions.
        .is_some_and(|v| unsafe { v.r#type() } == AXValueType::AXError)
}

fn string(value: &Option<CFRetained<CFType>>) -> Option<String> {
    value
        .as_ref()?
        .downcast_ref::<CFString>()
        .map(|s| s.to_string())
}

fn boolean(value: &Option<CFRetained<CFType>>) -> Option<bool> {
    value
        .as_ref()?
        .downcast_ref::<CFBoolean>()
        .map(CFBoolean::as_bool)
}

fn point(value: &Option<CFRetained<CFType>>) -> Option<CGPoint> {
    let mut point = CGPoint::default();
    let ax = value.as_ref()?.downcast_ref::<AXValue>()?;
    // SAFETY: `point` matches the CGPoint type asked for.
    unsafe {
        ax.value(
            AXValueType::CGPoint,
            NonNull::from(&mut point).cast::<c_void>(),
        )
    }
    .then_some(point)
}

fn size(value: &Option<CFRetained<CFType>>) -> Option<CGSize> {
    let mut size = CGSize::default();
    let ax = value.as_ref()?.downcast_ref::<AXValue>()?;
    // SAFETY: `size` matches the CGSize type asked for.
    unsafe {
        ax.value(
            AXValueType::CGSize,
            NonNull::from(&mut size).cast::<c_void>(),
        )
    }
    .then_some(size)
}

/// The control type as `screen.elements` names it: the AX role without its prefix, lowercase, with the names other
/// guests use where they differ.
fn role(ax: &str) -> String {
    let plain = ax.strip_prefix("AX").unwrap_or(ax).to_ascii_lowercase();
    match plain.as_str() {
        "statictext" => "text",
        "textfield" | "textarea" => "edit",
        "popupbutton" => "combobox",
        "menubutton" => "button",
        "outline" => "tree",
        "tabgroup" => "tablist",
        "scrollarea" => "pane",
        "splitgroup" => "group",
        other if other.len() <= 20 && other.chars().all(|c| c.is_ascii_lowercase()) => other,
        _ => "other",
    }
    .to_owned()
}

/// The main display's size in points: the space the rectangles are in.
fn display_points() -> [u32; 2] {
    #[repr(C)]
    struct CGRectRaw {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    }
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGMainDisplayID() -> u32;
        fn CGDisplayBounds(display: u32) -> CGRectRaw;
    }
    // SAFETY: plain queries with no pointers.
    let bounds = unsafe { CGDisplayBounds(CGMainDisplayID()) };
    [bounds.width.round() as u32, bounds.height.round() as u32]
}
