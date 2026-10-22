//! A drag going on in the guest, caught for `drag.probe`: a nearly invisible window over the whole screen,
//! registered as an OLE drop target and nudged under the pointer, gets the drag's data in DragEnter, and its file
//! list (CF_HDROP) is the answer. Every answer to the drag is DROPEFFECT_NONE: once the host lets go of the guest's
//! mouse button the drag ends as a cancelled one, so a "move" in the guest never deletes anything.

use std::cell::Cell;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINTL, WPARAM};
use windows::Win32::System::Com::{DVASPECT_CONTENT, FORMATETC, IDataObject, TYMED_HGLOBAL};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
use windows::Win32::System::Ole::{
    CF_HDROP, DROPEFFECT, DROPEFFECT_NONE, IDropTarget, IDropTarget_Impl, OleInitialize,
    OleUninitialize, RegisterDragDrop, ReleaseStgMedium, RevokeDragDrop,
};
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_MOVE, MOUSEINPUT, SendInput,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetSystemMetrics, LWA_ALPHA,
    MA_NOACTIVATE, MSG, MsgWaitForMultipleObjects, PM_REMOVE, PeekMessageW, QS_ALLINPUT,
    RegisterClassW, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
    SW_SHOWNOACTIVATE, SetLayeredWindowAttributes, ShowWindow, TranslateMessage, WM_MOUSEACTIVATE,
    WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};
use windows::core::{Ref, implement, w};

use crate::clipformat;

/// Where the probe is: waiting for the drag, the drag over its window, or the drag gone (dropped or left).
#[derive(Clone, Copy, PartialEq)]
enum Stage {
    Waiting,
    Over,
    Ended,
}

#[implement(IDropTarget)]
struct Target {
    stage: Rc<Cell<Stage>>,
    found: mpsc::Sender<Vec<String>>,
}

impl IDropTarget_Impl for Target_Impl {
    fn DragEnter(
        &self,
        data: Ref<IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        if self.stage.get() == Stage::Waiting {
            let files = data.ok().map(hdrop_files).unwrap_or_default();
            // A drag of something else (text, say) goes on in the guest: the window gets out of its way at once.
            self.stage.set(if files.is_empty() {
                Stage::Ended
            } else {
                Stage::Over
            });
            let _ = self.found.send(files);
        }
        refuse(effect);
        Ok(())
    }

    fn DragOver(
        &self,
        _keys: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        refuse(effect);
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        self.stage.set(Stage::Ended);
        Ok(())
    }

    fn Drop(
        &self,
        _data: Ref<IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        refuse(effect);
        self.stage.set(Stage::Ended);
        Ok(())
    }
}

fn refuse(effect: *mut DROPEFFECT) {
    if !effect.is_null() {
        // SAFETY: OLE passes a valid out pointer (checked for null anyway).
        unsafe { *effect = DROPEFFECT_NONE };
    }
}

/// The paths in the drag's CF_HDROP; none when it carries no files.
fn hdrop_files(data: &IDataObject) -> Vec<String> {
    let format = FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    };
    // SAFETY: GetData hands over a medium this function releases; its global memory is locked only while copied.
    unsafe {
        let Ok(mut medium) = data.GetData(&format) else {
            return Vec::new();
        };
        let global = medium.u.hGlobal;
        let size = GlobalSize(global);
        let ptr = GlobalLock(global).cast::<u8>();
        let bytes = if ptr.is_null() || size == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(ptr, size).to_vec()
        };
        let _ = GlobalUnlock(global);
        ReleaseStgMedium(&mut medium);
        clipformat::paths_from_dropfiles(&bytes)
    }
}

extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_MOUSEACTIVATE {
        return LRESULT(MA_NOACTIVATE as isize);
    }
    // SAFETY: the default handling of a message for our own window.
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// A pointer move of `dx` pixels (OLE looks for a drop target under the pointer as it moves).
fn nudge(dx: i32) {
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dwFlags: MOUSEEVENTF_MOVE,
                ..Default::default()
            },
        },
    };
    // SAFETY: one fully initialized input of the size given.
    unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
}

/// The paths of the files the guest's drag carries, if one reaches the probe's window within `wait`; the window
/// stays, on the thread returned, until the drag ends on it, at most `linger` longer.
pub fn drag_probe(
    wait: Duration,
    linger: Duration,
) -> std::io::Result<(Vec<String>, std::thread::JoinHandle<()>)> {
    let (found, answer) = mpsc::channel();
    let window = std::thread::Builder::new()
        .name("drag-probe".into())
        .spawn(move || {
            if let Err(err) = catch(found, wait, linger) {
                tracing::warn!("drag probe: {err}");
            }
        })?;
    let paths = answer
        .recv_timeout(wait + Duration::from_secs(2))
        .unwrap_or_default();
    Ok((paths, window))
}

fn catch(
    found: mpsc::Sender<Vec<String>>,
    wait: Duration,
    linger: Duration,
) -> windows::core::Result<()> {
    // SAFETY: OLE is initialized on this thread (an STA, as drop targets need) for the window's lifetime and
    // uninitialized after it; the window, its drop target and its messages all stay on this thread.
    unsafe {
        OleInitialize(None)?;
        let caught = show_and_wait(found, wait, linger);
        OleUninitialize();
        caught
    }
}

/// # Safety
/// OLE must be initialized on this thread.
unsafe fn show_and_wait(
    found: mpsc::Sender<Vec<String>>,
    wait: Duration,
    linger: Duration,
) -> windows::core::Result<()> {
    // SAFETY: Win32 calls on a window this function creates and destroys on this thread.
    unsafe {
        let instance = GetModuleHandleW(None)?;
        let class = w!("VMPaneDragProbe");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(window_proc),
            hInstance: instance.into(),
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassW(&wc); // fails harmlessly once the class exists
        let window = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            class,
            w!(""),
            WS_POPUP,
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
            None,
            None,
            Some(instance.into()),
            None,
        )?;
        // Alpha 1 of 255: not seen, yet hit-tested (a fully transparent window would not be a drop target).
        let stage = Rc::new(Cell::new(Stage::Waiting));
        let target: IDropTarget = Target {
            stage: Rc::clone(&stage),
            found: found.clone(),
        }
        .into();
        let shown = SetLayeredWindowAttributes(window, COLORREF(0), 1, LWA_ALPHA)
            .and_then(|()| RegisterDragDrop(window, &target));
        if shown.is_ok() {
            let _ = ShowWindow(window, SW_SHOWNOACTIVATE);
            nudge(1);
            nudge(-1);
            let start = Instant::now();
            while stage.get() != Stage::Ended {
                let elapsed = start.elapsed();
                if (stage.get() == Stage::Waiting && elapsed > wait) || elapsed > wait + linger {
                    break;
                }
                let mut msg = MSG::default();
                while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
                MsgWaitForMultipleObjects(None, false, 20, QS_ALLINPUT);
            }
            let _ = RevokeDragDrop(window);
        }
        if stage.get() == Stage::Waiting {
            let _ = found.send(Vec::new()); // no drag reached the window
        }
        let _ = DestroyWindow(window);
        shown
    }
}
