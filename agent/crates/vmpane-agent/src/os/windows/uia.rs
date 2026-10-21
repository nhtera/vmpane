//! The controls of the foreground window through UI Automation, for `screen.elements`. One cross-process call
//! (`FindAllBuildCache` over the control view) fetches every element with the properties it needs cached, which
//! is far faster than walking the tree element by element. Runs in the user-session helper, which is
//! Per-Monitor-V2 DPI aware so the rectangles are the display's pixels.

use vmpane_agent_proto::methods::{ScreenElement, ScreenElements};
use windows::Win32::Foundation::{E_FAIL, RECT};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows::Win32::System::Variant::{VT_BOOL, VT_BSTR, VariantClear};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

/// The properties read for each element.
const PROPERTIES: [UIA_PROPERTY_ID; 8] = [
    UIA_NamePropertyId,
    UIA_ControlTypePropertyId,
    UIA_BoundingRectanglePropertyId,
    UIA_IsOffscreenPropertyId,
    UIA_IsEnabledPropertyId,
    UIA_HasKeyboardFocusPropertyId,
    UIA_ValueValuePropertyId,
    UIA_IsPasswordPropertyId,
];

/// Up to `max` visible controls of the foreground window, in tree (reading) order.
pub fn screen_elements(max: usize) -> windows::core::Result<ScreenElements> {
    // SAFETY: COM is initialized on this (blocking pool) thread for the call and uninitialized after it; every
    // interface used below lives within that span.
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        let read = read(max);
        CoUninitialize();
        read
    }
}

/// The top-level window the user works in: the foreground window, else (none in front for a moment, as while
/// windows switch) the window holding the keyboard focus.
///
/// # Safety
/// COM must be initialized on this thread.
unsafe fn front_window(automation: &IUIAutomation) -> windows::core::Result<IUIAutomationElement> {
    // SAFETY: COM calls on interfaces this function owns.
    unsafe {
        let window = GetForegroundWindow();
        if !window.is_invalid() {
            return automation.ElementFromHandle(window);
        }
        // Up from the focus to the desktop (whose parent is none: an "error" with code 0): the window is the
        // element just below it.
        let walker = automation.ControlViewWalker()?;
        let focused = automation
            .GetFocusedElement()
            .map_err(|_| windows::core::Error::new(E_FAIL, "no window is in front"))?;
        let mut chain = vec![focused];
        while chain.len() < 64 {
            let Some(last) = chain.last() else { break };
            match walker.GetParentElement(last) {
                Ok(parent) => chain.push(parent),
                Err(_) => break,
            }
        }
        let below_root = chain.len().saturating_sub(2);
        Ok(chain.swap_remove(below_root))
    }
}

/// # Safety
/// COM must be initialized on this thread.
unsafe fn read(max: usize) -> windows::core::Result<ScreenElements> {
    // SAFETY (whole body): plain COM calls on interfaces this function owns.
    unsafe {
        let mut found = ScreenElements::default();
        let automation: IUIAutomation =
            CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let cache = automation.CreateCacheRequest()?;
        for property in PROPERTIES {
            cache.AddProperty(property)?;
        }
        let root = front_window(&automation)?;
        let all = root.FindAllBuildCache(
            TreeScope_Subtree,
            &automation.ControlViewCondition()?,
            &cache,
        )?;
        let count = all.Length()?;
        let mut skipped = [0; 3]; // off screen, no box, unnamed
        for index in 0..count {
            let element = all.GetElement(index)?;
            if element.CachedIsOffscreen()?.as_bool() {
                skipped[0] += 1;
                continue;
            }
            let RECT {
                left,
                top,
                right,
                bottom,
            } = element.CachedBoundingRectangle()?;
            let role = role(element.CachedControlType()?);
            let name = element.CachedName()?.to_string();
            if right <= left || bottom <= top {
                skipped[1] += 1;
                continue;
            }
            if name.trim().is_empty() && !interactive(role) {
                skipped[2] += 1;
                continue;
            }
            if found.elements.len() == max {
                found.truncated = true;
                break;
            }
            found.elements.push(ScreenElement {
                role: role.to_owned(),
                name,
                // Look only must not show more than a screenshot does: a password field's value never.
                value: if is_password(&element) {
                    None
                } else {
                    value(&element)
                },
                rect: [left, top, right - left, bottom - top],
                enabled: element.CachedIsEnabled()?.as_bool(),
                focused: element.CachedHasKeyboardFocus()?.as_bool(),
            });
        }
        if found.elements.is_empty() && count > 0 {
            // Why there are none, rather than an empty answer.
            let [offscreen, boxless, unnamed] = skipped;
            return Err(windows::core::Error::new(
                E_FAIL,
                format!(
                    "{count} controls, none listed ({offscreen} off screen, {boxless} without a box, {unnamed} unnamed)"
                ),
            ));
        }
        Ok(found)
    }
}

/// The element's value (an edit's text, a slider's position) when it has one as text.
///
/// # Safety
/// COM must be initialized on this thread.
unsafe fn value(element: &IUIAutomationElement) -> Option<String> {
    // SAFETY: the VARIANT comes from UI Automation; its string is read only when it is tagged BSTR, and it is
    // cleared (freeing the string) before returning.
    unsafe {
        let mut variant = element
            .GetCachedPropertyValue(UIA_ValueValuePropertyId)
            .ok()?;
        let inner = &variant.Anonymous.Anonymous;
        let text = (inner.vt == VT_BSTR).then(|| inner.Anonymous.bstrVal.to_string());
        let _ = VariantClear(&mut variant);
        text.filter(|text| !text.is_empty())
    }
}

/// Whether the element is a password field.
///
/// # Safety
/// COM must be initialized on this thread.
unsafe fn is_password(element: &IUIAutomationElement) -> bool {
    // SAFETY: as in `value`; a VT_BOOL is read only when tagged so.
    unsafe {
        let Ok(mut variant) = element.GetCachedPropertyValue(UIA_IsPasswordPropertyId) else {
            return true; // unknown: treat as a password
        };
        let inner = &variant.Anonymous.Anonymous;
        let password = inner.vt != VT_BOOL || inner.Anonymous.boolVal.as_bool();
        let _ = VariantClear(&mut variant);
        password
    }
}

/// Controls worth listing even without a name (an unnamed edit box is still where text goes).
fn interactive(role: &str) -> bool {
    matches!(
        role,
        "button" | "edit" | "checkbox" | "radiobutton" | "combobox" | "slider" | "spinner"
    )
}

#[allow(non_upper_case_globals)] // the SDK's constant names
fn role(control: UIA_CONTROLTYPE_ID) -> &'static str {
    match control {
        UIA_ButtonControlTypeId => "button",
        UIA_CalendarControlTypeId => "calendar",
        UIA_CheckBoxControlTypeId => "checkbox",
        UIA_ComboBoxControlTypeId => "combobox",
        UIA_EditControlTypeId => "edit",
        UIA_HyperlinkControlTypeId => "link",
        UIA_ImageControlTypeId => "image",
        UIA_ListItemControlTypeId => "listitem",
        UIA_ListControlTypeId => "list",
        UIA_MenuControlTypeId => "menu",
        UIA_MenuBarControlTypeId => "menubar",
        UIA_MenuItemControlTypeId => "menuitem",
        UIA_ProgressBarControlTypeId => "progressbar",
        UIA_RadioButtonControlTypeId => "radiobutton",
        UIA_ScrollBarControlTypeId => "scrollbar",
        UIA_SliderControlTypeId => "slider",
        UIA_SpinnerControlTypeId => "spinner",
        UIA_StatusBarControlTypeId => "statusbar",
        UIA_TabControlTypeId => "tablist",
        UIA_TabItemControlTypeId => "tab",
        UIA_TextControlTypeId => "text",
        UIA_ToolBarControlTypeId => "toolbar",
        UIA_ToolTipControlTypeId => "tooltip",
        UIA_TreeControlTypeId => "tree",
        UIA_TreeItemControlTypeId => "treeitem",
        UIA_GroupControlTypeId => "group",
        UIA_ThumbControlTypeId => "thumb",
        UIA_DataGridControlTypeId => "grid",
        UIA_DataItemControlTypeId => "row",
        UIA_DocumentControlTypeId => "document",
        UIA_SplitButtonControlTypeId => "splitbutton",
        UIA_WindowControlTypeId => "window",
        UIA_PaneControlTypeId => "pane",
        UIA_HeaderControlTypeId => "header",
        UIA_HeaderItemControlTypeId => "headeritem",
        UIA_TableControlTypeId => "table",
        UIA_TitleBarControlTypeId => "titlebar",
        UIA_SeparatorControlTypeId => "separator",
        _ => "other",
    }
}
