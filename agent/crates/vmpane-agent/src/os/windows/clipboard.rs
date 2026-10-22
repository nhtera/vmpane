//! The Windows clipboard (the user-session helper's window station): text, formatted text (HTML and RTF), PNG
//! and file lists. Images are read as the "PNG" format when the copying app put one there, else from the bitmap
//! (CF_DIB) Windows offers for every image; they are written as both, for apps that paste only bitmaps
//! (`clipformat` converts). Files are written with "Preferred DropEffect" copy, so Explorer copies them.

use std::sync::OnceLock;
use std::time::Duration;

use vmpane_agent_proto::methods::ClipboardType;
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, GetClipboardSequenceNumber,
    IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::Memory::{
    GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
};
use windows::core::w;

use crate::clipformat;

/// One representation on the clipboard.
pub enum Content {
    Bytes(Vec<u8>),
    Files(Vec<String>),
}

const CF_DIB: u32 = 8;
const CF_UNICODETEXT: u32 = 13;
const CF_HDROP: u32 = 15;
/// Clipboard data read at most (a 4K screen's bitmap is 33 MB; what goes to the host is capped later).
const MAX_READ: usize = 256 << 20;

/// The "PNG" format browsers, Office and the Snipping Tool register.
fn png_format() -> u32 {
    static FORMAT: OnceLock<u32> = OnceLock::new();
    // SAFETY: a constant NUL-terminated wide string.
    *FORMAT.get_or_init(|| unsafe { RegisterClipboardFormatW(w!("PNG")) })
}

/// CF_HTML, as browsers and Office copy formatted text.
fn html_format() -> u32 {
    static FORMAT: OnceLock<u32> = OnceLock::new();
    // SAFETY: as above.
    *FORMAT.get_or_init(|| unsafe { RegisterClipboardFormatW(w!("HTML Format")) })
}

/// RTF, as WordPad, Word and Outlook copy formatted text.
fn rtf_format() -> u32 {
    static FORMAT: OnceLock<u32> = OnceLock::new();
    // SAFETY: as above.
    *FORMAT.get_or_init(|| unsafe { RegisterClipboardFormatW(w!("Rich Text Format")) })
}

/// Whether a paste of CF_HDROP copies or moves (a DWORD DROPEFFECT).
fn drop_effect_format() -> u32 {
    static FORMAT: OnceLock<u32> = OnceLock::new();
    // SAFETY: as above.
    *FORMAT.get_or_init(|| unsafe { RegisterClipboardFormatW(w!("Preferred DropEffect")) })
}

const DROPEFFECT_COPY: u32 = 1;

/// Bumped by every change to the clipboard, by anyone.
pub fn change_count() -> isize {
    // SAFETY: no arguments.
    unsafe { GetClipboardSequenceNumber() as isize }
}

fn has(format: u32) -> bool {
    // SAFETY: no pointers; the clipboard need not be open.
    unsafe { IsClipboardFormatAvailable(format) }.is_ok()
}

/// What the clipboard holds now, of the types this agent handles.
pub fn available() -> Vec<ClipboardType> {
    let mut types = Vec::new();
    if has(CF_HDROP) {
        types.push(ClipboardType::Files);
    }
    if has(png_format()) || has(CF_DIB) {
        types.push(ClipboardType::Png);
    }
    if has(CF_UNICODETEXT) {
        types.push(ClipboardType::Text);
    }
    if has(html_format()) {
        types.push(ClipboardType::Html);
    }
    if has(rtf_format()) {
        types.push(ClipboardType::Rtf);
    }
    types
}

/// The clipboard, open on this thread until dropped. Another app may hold it for a moment: retried for 0.5 s.
struct Open;

impl Open {
    fn new() -> std::io::Result<Self> {
        let mut last = None;
        for _ in 0..50 {
            // SAFETY: no owner window; closed by Drop on this same thread.
            match unsafe { OpenClipboard(None) } {
                Ok(()) => return Ok(Open),
                Err(err) => last = Some(err),
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Err(std::io::Error::other(format!(
            "the clipboard is busy: {}",
            last.map(|e| e.message()).unwrap_or_default()
        )))
    }

    /// A copy of `format`'s data, if the clipboard has it.
    fn data(&self, format: u32) -> Option<Vec<u8>> {
        // SAFETY: the clipboard is open (self); the handle stays valid until it closes.
        let handle = unsafe { GetClipboardData(format) }.ok()?;
        let global = HGLOBAL(handle.0);
        // SAFETY: a global memory handle owned by the clipboard; locked only while copied.
        unsafe {
            let size = GlobalSize(global);
            if size == 0 || size > MAX_READ {
                return None;
            }
            let ptr = GlobalLock(global).cast::<u8>();
            if ptr.is_null() {
                return None;
            }
            let bytes = std::slice::from_raw_parts(ptr, size).to_vec();
            let _ = GlobalUnlock(global);
            Some(bytes)
        }
    }

    /// Puts `bytes` on the clipboard as `format` (after EmptyClipboard); the clipboard owns the copy.
    fn set(&self, format: u32, bytes: &[u8]) -> std::io::Result<()> {
        // SAFETY: a fresh movable block of bytes.len() bytes, filled while locked; freed here unless the
        // clipboard took it.
        unsafe {
            let global = GlobalAlloc(GMEM_MOVEABLE, bytes.len()).map_err(std::io::Error::other)?;
            let ptr = GlobalLock(global).cast::<u8>();
            if ptr.is_null() {
                let _ = GlobalFree(Some(global));
                return Err(std::io::Error::other("cannot lock clipboard memory"));
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
            let _ = GlobalUnlock(global);
            if let Err(err) = SetClipboardData(format, Some(HANDLE(global.0))) {
                let _ = GlobalFree(Some(global));
                return Err(std::io::Error::other(err));
            }
        }
        Ok(())
    }
}

impl Drop for Open {
    fn drop(&mut self) {
        // SAFETY: opened by Open::new on this thread.
        let _ = unsafe { CloseClipboard() };
    }
}

/// Reads `kind` from the clipboard, if it is there.
pub fn read(kind: ClipboardType) -> Option<Content> {
    let clipboard = Open::new().ok()?;
    match kind {
        ClipboardType::Text => clipboard
            .data(CF_UNICODETEXT)
            .map(|bytes| Content::Bytes(clipformat::text_from_utf16(&bytes).into_bytes())),
        ClipboardType::Png => {
            if let Some(png) = clipboard.data(png_format()) {
                return Some(Content::Bytes(png));
            }
            let bitmap = clipboard.data(CF_DIB)?;
            drop(clipboard); // converted with the clipboard closed: other apps wait while it is open
            clipformat::dib_to_png(&bitmap).map(Content::Bytes)
        }
        ClipboardType::Files => clipboard
            .data(CF_HDROP)
            .map(|bytes| clipformat::paths_from_dropfiles(&bytes))
            .filter(|files| !files.is_empty())
            .map(Content::Files),
        ClipboardType::Html => clipboard
            .data(html_format())
            .and_then(|bytes| clipformat::html_from_cf(&bytes))
            .map(|html| Content::Bytes(html.into_bytes())),
        ClipboardType::Rtf => clipboard
            .data(rtf_format())
            .map(|bytes| Content::Bytes(clipformat::rtf_from_cf(&bytes))),
    }
}

/// Replaces the clipboard's contents with `items` (text, PNG and files may go together).
pub fn write(items: Vec<(ClipboardType, Content)>) -> std::io::Result<()> {
    // Converted before the clipboard is opened: other apps wait while it is.
    let mut formats = Vec::new();
    for (kind, content) in items {
        match (kind, content) {
            (ClipboardType::Text, Content::Bytes(bytes)) => {
                let text = String::from_utf8(bytes)
                    .map_err(|_| std::io::Error::other("clipboard text is not UTF-8"))?;
                formats.push((CF_UNICODETEXT, clipformat::text_to_utf16(&text)));
            }
            (ClipboardType::Png, Content::Bytes(bytes)) => {
                let dib = clipformat::png_to_dib(&bytes)
                    .ok_or_else(|| std::io::Error::other("the clipboard image is not a PNG"))?;
                formats.push((png_format(), bytes));
                formats.push((CF_DIB, dib));
            }
            (ClipboardType::Files, Content::Files(paths)) => {
                formats.push((CF_HDROP, clipformat::dropfiles(&paths)));
                formats.push((drop_effect_format(), DROPEFFECT_COPY.to_le_bytes().to_vec()));
            }
            (ClipboardType::Html, Content::Bytes(bytes)) => {
                let html = String::from_utf8(bytes)
                    .map_err(|_| std::io::Error::other("clipboard HTML is not UTF-8"))?;
                formats.push((html_format(), clipformat::html_to_cf(&html)));
            }
            (ClipboardType::Rtf, Content::Bytes(mut bytes)) => {
                bytes.push(0);
                formats.push((rtf_format(), bytes));
            }
            _ => return Err(std::io::Error::other("the clipboard refused the contents")),
        }
    }
    let clipboard = Open::new()?;
    // SAFETY: the clipboard is open on this thread.
    unsafe { EmptyClipboard() }.map_err(std::io::Error::other)?;
    for (format, bytes) in formats {
        clipboard.set(format, &bytes)?;
    }
    Ok(())
}
