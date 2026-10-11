//! The macOS pasteboard: text, PNG and file lists. A debug build reads and writes the named pasteboard
//! `$VMPANE_TEST_PASTEBOARD` instead of the general one, so tests never touch the user's clipboard.

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_app_kit::{
    NSPasteboard, NSPasteboardItem, NSPasteboardTypeFileURL, NSPasteboardTypePNG,
    NSPasteboardTypeString, NSPasteboardWriting,
};
use objc2_foundation::{NSArray, NSData, NSString, NSURL};
use vmpane_agent_proto::methods::ClipboardType;

/// One representation on the pasteboard.
pub enum Content {
    Bytes(Vec<u8>),
    Files(Vec<String>),
}

fn pasteboard() -> Retained<NSPasteboard> {
    if cfg!(debug_assertions)
        && let Ok(name) = std::env::var("VMPANE_TEST_PASTEBOARD")
    {
        return NSPasteboard::pasteboardWithName(&NSString::from_str(&name));
    }
    NSPasteboard::generalPasteboard()
}

/// Bumped by every change to the pasteboard, by anyone.
pub fn change_count() -> isize {
    pasteboard().changeCount()
}

/// What the pasteboard holds now, of the types this agent handles.
pub fn available() -> Vec<ClipboardType> {
    let pb = pasteboard();
    let mut types = Vec::new();
    // SAFETY: AppKit's constant pasteboard type strings.
    let (string, png) = unsafe { (NSPasteboardTypeString, NSPasteboardTypePNG) };
    if !files(&pb).is_empty() {
        types.push(ClipboardType::Files);
    }
    if pb.dataForType(png).is_some() {
        types.push(ClipboardType::Png);
    }
    if pb.stringForType(string).is_some() {
        types.push(ClipboardType::Text);
    }
    types
}

fn files(pb: &NSPasteboard) -> Vec<String> {
    // SAFETY: as above.
    let file_url = unsafe { NSPasteboardTypeFileURL };
    let Some(items) = pb.pasteboardItems() else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| item.stringForType(file_url))
        .filter_map(|url| NSURL::URLWithString(&url))
        .filter_map(|url| url.path())
        .map(|path| path.to_string())
        .collect()
}

/// Reads `kind` from the pasteboard, if it is there.
pub fn read(kind: ClipboardType) -> Option<Content> {
    let pb = pasteboard();
    // SAFETY: as above.
    let (string, png) = unsafe { (NSPasteboardTypeString, NSPasteboardTypePNG) };
    match kind {
        ClipboardType::Text => pb
            .stringForType(string)
            .map(|s| Content::Bytes(s.to_string().into_bytes())),
        ClipboardType::Png => pb.dataForType(png).map(|d| Content::Bytes(d.to_vec())),
        ClipboardType::Files => Some(files(&pb))
            .filter(|f| !f.is_empty())
            .map(Content::Files),
    }
}

/// Replaces the pasteboard's contents with `items` (text, PNG and files may go together).
pub fn write(items: Vec<(ClipboardType, Content)>) -> std::io::Result<()> {
    let pb = pasteboard();
    // SAFETY: as above.
    let (string, png, file_url) = unsafe {
        (
            NSPasteboardTypeString,
            NSPasteboardTypePNG,
            NSPasteboardTypeFileURL,
        )
    };
    pb.clearContents();
    let mut ok = true;
    for (kind, content) in items {
        ok &= match (kind, content) {
            (ClipboardType::Text, Content::Bytes(bytes)) => {
                let text = String::from_utf8(bytes)
                    .map_err(|_| std::io::Error::other("clipboard text is not UTF-8"))?;
                pb.setString_forType(&NSString::from_str(&text), string)
            }
            (ClipboardType::Png, Content::Bytes(bytes)) => {
                pb.setData_forType(Some(&NSData::with_bytes(&bytes)), png)
            }
            (ClipboardType::Files, Content::Files(paths)) => {
                let items: Vec<Retained<ProtocolObject<dyn NSPasteboardWriting>>> = paths
                    .iter()
                    .filter_map(|path| {
                        let url = NSURL::fileURLWithPath(&NSString::from_str(path));
                        let item = NSPasteboardItem::new();
                        let text = url.absoluteString()?;
                        item.setString_forType(&text, file_url).then_some(item)
                    })
                    .map(ProtocolObject::from_retained)
                    .collect();
                pb.writeObjects(&NSArray::from_retained_slice(&items))
            }
            _ => false,
        };
    }
    if ok {
        Ok(())
    } else {
        Err(std::io::Error::other("the pasteboard refused the contents"))
    }
}
