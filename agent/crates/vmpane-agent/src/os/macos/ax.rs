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
pub fn screen_elements(max: usize) -> Result<ScreenElements, AxError> {
    let scale = backing_scale();
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
    let window = element(&app, "AXFocusedWindow")
        .or_else(|_| element(&app, "AXMainWindow"))
        .map_err(|_| AxError::Other("the app in front has no window".into()))?;
    let names: Vec<CFRetained<CFString>> =
        ATTRIBUTES.iter().map(|a| CFString::from_str(a)).collect();
    let names = CFArray::from_retained_objects(&names);
    let mut found = ScreenElements::default();
    let mut queue = VecDeque::from([(window, 0u32)]);
    while let Some((element, depth)) = queue.pop_front() {
        let Some(values) = attributes(&element, &names) else {
            continue;
        };
        let children = values[9].as_ref().and_then(|v| v.downcast_ref::<CFArray>());
        if let Some(children) = children.filter(|_| depth < SCREEN_MAX_DEPTH) {
            // SAFETY: an array of CF objects.
            for child in unsafe { children.cast_unchecked::<CFType>() }.iter() {
                if let Some(child) = child.downcast_ref::<AXUIElement>() {
                    queue.push_back((child.retain(), depth + 1));
                }
            }
        }
        let ax_role = string(&values[0]).unwrap_or_default();
        let (Some(origin), Some(size)) = (point(&values[5]), size(&values[6])) else {
            continue;
        };
        if size.width <= 0.0 || size.height <= 0.0 {
            continue;
        }
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
        let secure = string(&values[1]).as_deref() == Some("AXSecureTextField");
        found.elements.push(ScreenElement {
            value: if role == "text" || secure {
                None
            } else {
                text.filter(|t| !t.is_empty())
            },
            role,
            name,
            rect: [
                (origin.x * scale).round() as i32,
                (origin.y * scale).round() as i32,
                (size.width * scale).round() as i32,
                (size.height * scale).round() as i32,
            ],
            enabled: boolean(&values[7]).unwrap_or(true),
            focused: boolean(&values[8]).unwrap_or(false),
        });
    }
    Ok(found)
}

/// The first time controls are asked for without the grant: macOS shows its "allow Accessibility" prompt, which
/// also lists the agent in System Settings. Once per user (a marker file), so nobody is asked again and again.
fn ask_for_accessibility_once() {
    let marker = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
        .join("Library/Application Support/VMPane/accessibility-asked");
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

/// Display pixels per point of the main display (2 on a Retina-like guest display).
fn backing_scale() -> f64 {
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGMainDisplayID() -> u32;
        fn CGDisplayCopyDisplayMode(display: u32) -> *mut c_void;
        fn CGDisplayModeGetPixelWidth(mode: *mut c_void) -> usize;
        fn CGDisplayModeGetWidth(mode: *mut c_void) -> usize;
        fn CGDisplayModeRelease(mode: *mut c_void);
    }
    // SAFETY: the mode is released once; null is checked.
    unsafe {
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
        if mode.is_null() {
            return 1.0;
        }
        let (pixels, points) = (
            CGDisplayModeGetPixelWidth(mode),
            CGDisplayModeGetWidth(mode),
        );
        CGDisplayModeRelease(mode);
        if points == 0 {
            1.0
        } else {
            pixels as f64 / points as f64
        }
    }
}
