//! The Windows clipboard's data formats, converted to and from what the host moves (Windows guests; built on
//! every OS so the tests run on the Mac): UTF-16 text with CRLF line ends, file lists (`DROPFILES`), formatted
//! text (`HTML Format`, CF_HTML: UTF-8 HTML after a header of byte offsets), and device-independent bitmaps
//! (CF_DIB), which most Windows apps copy and paste images as, to and from PNG. Bitmaps of 24 and 32 bits per
//! pixel only: what screenshots and image apps put on the clipboard.

use std::io::Cursor;

/// Pixels in a bitmap converted either way (8K×8K: well above any screen; PNG is capped at 32 MiB later).
const MAX_PIXELS: u64 = 8192 * 8192;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const BI_ALPHABITFIELDS: u32 = 6;
/// BITMAPINFOHEADER.
const INFO_HEADER: usize = 40;
/// DROPFILES: pFiles, pt (x, y), fNC, fWide.
const DROPFILES_HEADER: usize = 20;

/// CF_UNICODETEXT: UTF-16, CRLF line ends, NUL-terminated.
pub fn text_to_utf16(text: &str) -> Vec<u8> {
    let text = text.replace("\r\n", "\n").replace('\n', "\r\n");
    text.encode_utf16()
        .chain([0])
        .flat_map(u16::to_le_bytes)
        .collect()
}

/// CF_UNICODETEXT as text with LF line ends (up to the first NUL).
pub fn text_from_utf16(bytes: &[u8]) -> String {
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .take_while(|&unit| unit != 0)
        .collect();
    String::from_utf16_lossy(&units).replace("\r\n", "\n")
}

/// CF_HDROP's `DROPFILES`: wide paths, each NUL-terminated, and an empty one to end the list.
pub fn dropfiles(paths: &[String]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(DROPFILES_HEADER as u32).to_le_bytes()); // pFiles
    out.extend_from_slice(&[0; 12]); // pt, fNC
    out.extend_from_slice(&1u32.to_le_bytes()); // fWide
    for path in paths {
        out.extend(path.encode_utf16().chain([0]).flat_map(u16::to_le_bytes));
    }
    out.extend_from_slice(&[0, 0]);
    out
}

/// The paths in a `DROPFILES`; empty when it is malformed.
pub fn paths_from_dropfiles(bytes: &[u8]) -> Vec<String> {
    let (Some(offset), Some(wide)) = (u32_at(bytes, 0), u32_at(bytes, 16)) else {
        return Vec::new();
    };
    let Some(list) = bytes.get(offset as usize..) else {
        return Vec::new();
    };
    if wide == 0 {
        // ANSI paths (old apps): read as UTF-8, right for ASCII paths.
        return list
            .split(|&b| b == 0)
            .take_while(|name| !name.is_empty())
            .map(|name| String::from_utf8_lossy(name).into_owned())
            .collect();
    }
    let units: Vec<u16> = list
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    units
        .split(|&unit| unit == 0)
        .take_while(|name| !name.is_empty())
        .map(String::from_utf16_lossy)
        .collect()
}

/// CF_HTML's header: the byte offsets of the document and of the fragment in it, 10 digits each (105 bytes).
fn html_header(
    start_html: usize,
    end_html: usize,
    start_fragment: usize,
    end_fragment: usize,
) -> String {
    format!(
        "Version:0.9\r\nStartHTML:{start_html:010}\r\nEndHTML:{end_html:010}\r\n\
         StartFragment:{start_fragment:010}\r\nEndFragment:{end_fragment:010}\r\n"
    )
}

const START_FRAGMENT: &str = "<!--StartFragment-->";
const END_FRAGMENT: &str = "<!--EndFragment-->";

/// An HTML document or fragment (what the Mac's `public.html` holds) as CF_HTML, NUL-terminated: the fragment is
/// the document's body, or all of it when it has none (then wrapped in `<html><body>`).
pub fn html_to_cf(html: &str) -> Vec<u8> {
    // ASCII lowercasing keeps byte offsets.
    let lower = html.to_ascii_lowercase();
    // `<body` then `>` or white space (not `<bodyx>`).
    let body_tag = lower.match_indices("<body").map(|(at, _)| at).find(|&at| {
        lower[at + 5..]
            .chars()
            .next()
            .is_some_and(|c| c == '>' || c.is_ascii_whitespace())
    });
    let body = body_tag.and_then(|open| {
        let start = open + lower[open..].find('>')? + 1;
        let end = lower.rfind("</body")?;
        (start <= end).then_some((start, end))
    });
    let (document, fragment) = match body {
        Some((start, end)) => {
            let document = [
                &html[..start],
                START_FRAGMENT,
                &html[start..end],
                END_FRAGMENT,
                &html[end..],
            ]
            .concat();
            let at = start + START_FRAGMENT.len();
            (document, (at, at + end - start))
        }
        None => {
            let open = format!("<html><body>{START_FRAGMENT}");
            let document = format!("{open}{html}{END_FRAGMENT}</body></html>");
            (document, (open.len(), open.len() + html.len()))
        }
    };
    let header = html_header(0, 0, 0, 0).len();
    let mut out = html_header(
        header,
        header + document.len(),
        header + fragment.0,
        header + fragment.1,
    )
    .into_bytes();
    out.extend_from_slice(document.as_bytes());
    out.push(0);
    out
}

/// CF_HTML as an HTML document: StartHTML..EndHTML (with the styles Word and browsers put in its head), else the
/// fragment, else everything from the first tag; each from its first tag on (an offset a little off, into the
/// header or before some white space, still reads). None when there is no HTML in it.
pub fn html_from_cf(bytes: &[u8]) -> Option<String> {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let bytes = &bytes[..end];
    let first_tag = bytes.iter().position(|&b| b == b'<')?;
    let offset = |name: &str| -> Option<usize> {
        let header = std::str::from_utf8(&bytes[..first_tag]).ok()?;
        let line = header
            .lines()
            .find_map(|line| line.strip_prefix(name)?.strip_prefix(':'))?;
        line.trim()
            .parse::<i64>()
            .ok()
            .and_then(|n| usize::try_from(n).ok())
    };
    let range = |start: &str, stop: &str| -> Option<&[u8]> {
        let (start, stop) = (offset(start)?, offset(stop)?.min(bytes.len()));
        let slice = bytes.get(start..stop)?;
        Some(&slice[slice.iter().position(|&b| b == b'<')?..])
    };
    let html = range("StartHTML", "EndHTML")
        .or_else(|| range("StartFragment", "EndFragment"))
        .unwrap_or(&bytes[first_tag..]);
    Some(String::from_utf8_lossy(html).into_owned())
}

/// RTF as the guest holds it (`Rich Text Format`): the text up to a NUL terminator, if any.
pub fn rtf_from_cf(bytes: &[u8]) -> Vec<u8> {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    bytes[..end].to_vec()
}

/// A CF_DIB (BITMAPINFOHEADER or a later header, then pixels) as PNG; None for a bitmap this does not read
/// (palettes, compression, other channel masks) or a malformed one.
pub fn dib_to_png(dib: &[u8]) -> Option<Vec<u8>> {
    let header = u32_at(dib, 0)? as usize;
    let width = i32_at(dib, 4)?;
    let height = i32_at(dib, 8)?;
    let bits = u16_at(dib, 14)?;
    let compression = u32_at(dib, 16)?;
    let colors = u32_at(dib, 32)? as usize;
    if header < INFO_HEADER || width <= 0 || height == 0 || !(bits == 24 || bits == 32) {
        return None;
    }
    // Channel masks: after a BITMAPINFOHEADER, or inside a V4/V5 header. Only BGR(A) byte order is read.
    let masks = match compression {
        BI_RGB => 0,
        BI_BITFIELDS | BI_ALPHABITFIELDS if bits == 32 => {
            let at = if header == INFO_HEADER {
                INFO_HEADER
            } else {
                40
            };
            let rgb = (u32_at(dib, at)?, u32_at(dib, at + 4)?, u32_at(dib, at + 8)?);
            if rgb != (0x00FF_0000, 0x0000_FF00, 0x0000_00FF) {
                return None;
            }
            match (header == INFO_HEADER, compression) {
                (true, BI_BITFIELDS) => 12,
                (true, _) => 16,
                (false, _) => 0,
            }
        }
        _ => return None,
    };
    let (width, rows) = (width as usize, height.unsigned_abs() as usize);
    if (width as u64) * (rows as u64) > MAX_PIXELS {
        return None;
    }
    let pixel_bytes = usize::from(bits / 8);
    let stride = (width * pixel_bytes).div_ceil(4) * 4;
    let start = header + masks + colors * 4;
    let pixels = dib.get(start..start + stride * rows)?;

    let mut rgba = Vec::with_capacity(width * rows * 4);
    for row in 0..rows {
        // Positive height: bottom-up rows.
        let source = if height > 0 { rows - 1 - row } else { row };
        let line = &pixels[source * stride..source * stride + width * pixel_bytes];
        for px in line.chunks_exact(pixel_bytes) {
            rgba.extend_from_slice(&[px[2], px[1], px[0], if bits == 32 { px[3] } else { 255 }]);
        }
    }
    // BI_RGB leaves the fourth byte undefined; most apps write 0 there, which would be fully transparent.
    if bits == 32 && compression == BI_RGB && rgba.chunks_exact(4).all(|px| px[3] == 0) {
        rgba.chunks_exact_mut(4).for_each(|px| px[3] = 255);
    }

    let mut png = Vec::new();
    let mut encoder = png::Encoder::new(&mut png, width as u32, rows as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().ok()?;
    writer.write_image_data(&rgba).ok()?;
    writer.finish().ok()?;
    Some(png)
}

/// A PNG as a CF_DIB: 32-bit BGRA rows bottom-up after a BITMAPINFOHEADER, which every Windows app reads.
pub fn png_to_dib(png: &[u8]) -> Option<Vec<u8>> {
    let limits = png::Limits {
        bytes: (MAX_PIXELS * 4) as usize,
    };
    let mut decoder = png::Decoder::new_with_limits(Cursor::new(png), limits);
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0; reader.output_buffer_size()?];
    let frame = reader.next_frame(&mut buffer).ok()?;
    let (width, height) = (frame.width as usize, frame.height as usize);
    if (width as u64) * (height as u64) > MAX_PIXELS || frame.bit_depth != png::BitDepth::Eight {
        return None;
    }
    let channels = match frame.color_type {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => return None, // expanded by the transformations
    };

    let size = width * height * 4;
    let mut dib = Vec::with_capacity(INFO_HEADER + size);
    dib.extend_from_slice(&(INFO_HEADER as u32).to_le_bytes());
    dib.extend_from_slice(&(frame.width as i32).to_le_bytes());
    dib.extend_from_slice(&(frame.height as i32).to_le_bytes()); // positive: bottom-up
    dib.extend_from_slice(&1u16.to_le_bytes()); // planes
    dib.extend_from_slice(&32u16.to_le_bytes());
    dib.extend_from_slice(&BI_RGB.to_le_bytes());
    dib.extend_from_slice(&(size as u32).to_le_bytes());
    dib.extend_from_slice(&2835i32.to_le_bytes()); // 72 dpi
    dib.extend_from_slice(&2835i32.to_le_bytes());
    dib.extend_from_slice(&[0; 8]); // colours used, important
    for row in (0..height).rev() {
        let line = &buffer[row * frame.line_size..row * frame.line_size + width * channels];
        for px in line.chunks_exact(channels) {
            let (r, g, b, a) = match *px {
                [v] => (v, v, v, 255),
                [v, a] => (v, v, v, a),
                [r, g, b] => (r, g, b, 255),
                [r, g, b, a] => (r, g, b, a),
                _ => return None,
            };
            dib.extend_from_slice(&[b, g, r, a]);
        }
    }
    Some(dib)
}

fn u16_at(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
}

fn u32_at(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

fn i32_at(bytes: &[u8], at: usize) -> Option<i32> {
    Some(i32::from_le_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A width×height bitmap with `bits` per pixel; `pixel(x, y)` (y from the top) gives BGR(A).
    fn dib(width: i32, height: i32, bits: u16, pixel: impl Fn(usize, usize) -> [u8; 4]) -> Vec<u8> {
        let pixel_bytes = usize::from(bits / 8);
        let stride = (width as usize * pixel_bytes).div_ceil(4) * 4;
        let rows = height.unsigned_abs() as usize;
        let mut out = Vec::new();
        out.extend_from_slice(&40u32.to_le_bytes());
        out.extend_from_slice(&width.to_le_bytes());
        out.extend_from_slice(&height.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&bits.to_le_bytes());
        out.extend_from_slice(&[0; 24]);
        for stored in 0..rows {
            let y = if height > 0 {
                rows - 1 - stored
            } else {
                stored
            };
            let mut line: Vec<u8> = (0..width as usize)
                .flat_map(|x| pixel(x, y)[..pixel_bytes].to_vec())
                .collect();
            line.resize(stride, 0xEE); // padding that must not be read
            out.extend(line);
        }
        out
    }

    fn decode(png: &[u8]) -> (u32, u32, Vec<u8>) {
        let mut decoder = png::Decoder::new(Cursor::new(png));
        decoder.set_transformations(png::Transformations::normalize_to_color8());
        let mut reader = decoder.read_info().unwrap_or_else(|e| panic!("{e}"));
        let mut buffer = vec![0; reader.output_buffer_size().unwrap_or(0)];
        let frame = reader
            .next_frame(&mut buffer)
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(frame.color_type, png::ColorType::Rgba);
        buffer.truncate(frame.buffer_size());
        (frame.width, frame.height, buffer)
    }

    #[test]
    fn text_round_trips_with_crlf_in_the_guest() {
        let bytes = text_to_utf16("a\nb\r\nc ✓");
        let expected: Vec<u8> = "a\r\nb\r\nc ✓\0"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        assert_eq!(bytes, expected);
        assert_eq!(text_from_utf16(&bytes), "a\nb\nc ✓");
        let raw: Vec<u8> = "x\r\ny".encode_utf16().flat_map(u16::to_le_bytes).collect();
        assert_eq!(text_from_utf16(&raw), "x\ny");
    }

    #[test]
    fn file_lists_round_trip() {
        let paths = vec![
            r"C:\Users\me\a.txt".to_owned(),
            r"C:\Temp\ünï.png".to_owned(),
        ];
        assert_eq!(paths_from_dropfiles(&dropfiles(&paths)), paths);
        assert!(paths_from_dropfiles(&[1, 2, 3]).is_empty());
        let mut ansi = vec![20, 0, 0, 0];
        ansi.extend_from_slice(&[0; 16]);
        ansi.extend_from_slice(b"C:\\a\0C:\\b\0\0");
        assert_eq!(paths_from_dropfiles(&ansi), vec![r"C:\a", r"C:\b"]);
    }

    /// The (StartHTML, EndHTML, StartFragment, EndFragment) a CF_HTML header names.
    fn offsets(cf: &[u8]) -> Vec<usize> {
        let text = String::from_utf8_lossy(cf);
        ["StartHTML:", "EndHTML:", "StartFragment:", "EndFragment:"]
            .iter()
            .map(|name| {
                let at = text.find(name).unwrap_or(0) + name.len();
                text[at..at + 10].parse().unwrap_or(0)
            })
            .collect()
    }

    #[test]
    fn html_documents_mark_their_body_as_the_fragment() {
        let html = "<html><head><style>b{color:red}</style></head><BODY class=\"x\"><b>bold ✓</b></BODY></html>";
        let cf = html_to_cf(html);
        assert_eq!(cf.last(), Some(&0));
        let o = offsets(&cf);
        assert_eq!(o[0], 105);
        assert_eq!(o[1], cf.len() - 1);
        assert_eq!(&cf[o[2]..o[3]], "<b>bold ✓</b>".as_bytes());
        assert_eq!(
            &cf[o[2] - START_FRAGMENT.len()..o[2]],
            START_FRAGMENT.as_bytes()
        );
        // Read back: the whole document, styles included, with the fragment markers Windows apps look for.
        let back = html_from_cf(&cf).unwrap_or_default();
        assert!(back.starts_with("<html><head><style>") && back.ends_with("</html>"));
        assert!(back.contains("<!--StartFragment--><b>bold ✓</b><!--EndFragment-->"));
    }

    #[test]
    fn html_fragments_are_wrapped() {
        let cf = html_to_cf("<i>a</i> & b");
        let o = offsets(&cf);
        assert_eq!(&cf[o[2]..o[3]], b"<i>a</i> & b");
        assert_eq!(
            html_from_cf(&cf).as_deref(),
            Some("<html><body><!--StartFragment--><i>a</i> & b<!--EndFragment--></body></html>")
        );
    }

    #[test]
    fn cf_html_from_other_apps_is_read_leniently() {
        // Version 1.0 with no document range (-1), an EndFragment past the end, and a source URL.
        let html = "<html><body><!--StartFragment--><p>x</p><!--EndFragment--></body></html>";
        let header = "Version:1.0\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:0000000000\r\nEndFragment:0000009999\r\nSourceURL:https://example.com/\r\n";
        let start = header.len() + html.find("<p>").unwrap_or(0);
        let header = header.replace(
            "StartFragment:0000000000",
            &format!("StartFragment:{start:010}"),
        );
        let cf = [header.as_bytes(), html.as_bytes(), b"\0"].concat();
        assert_eq!(
            html_from_cf(&cf).as_deref(),
            Some("<p>x</p><!--EndFragment--></body></html>")
        );
        // StartHTML a little early (into the header's line end): read from the document's first tag.
        let doc = "<html><body>z</body></html>";
        let header = |start: usize, end: usize| {
            format!("Version:0.9\r\nStartHTML:{start:010}\r\nEndHTML:{end:010}\r\n")
        };
        let n = header(0, 0).len();
        let early = format!("{}{doc}", header(n - 2, n + doc.len()));
        assert_eq!(html_from_cf(early.as_bytes()).as_deref(), Some(doc));
        // A <bodyx> tag is not the body.
        let cf = html_to_cf("<bodyx>a</bodyx>");
        let o = offsets(&cf);
        assert_eq!(&cf[o[2]..o[3]], b"<bodyx>a</bodyx>");
        // No usable header at all: everything from the first tag.
        assert_eq!(html_from_cf(b"junk<p>y</p>").as_deref(), Some("<p>y</p>"));
        assert_eq!(html_from_cf(b"no tags"), None);
        assert_eq!(rtf_from_cf(b"{\\rtf1 x}\0\0"), b"{\\rtf1 x}");
    }

    #[test]
    fn bottom_up_24_bit_bitmaps_become_opaque_png() {
        // Width 3 at 3 bytes a pixel: rows padded to 12 bytes.
        let bitmap = dib(3, 2, 24, |x, y| [x as u8, y as u8, 7, 0]);
        let (w, h, rgba) = decode(&dib_to_png(&bitmap).unwrap_or_default());
        assert_eq!((w, h), (3, 2));
        assert_eq!(&rgba[..4], &[7, 0, 0, 255]); // top-left: R 7, G y 0, B x 0
        assert_eq!(&rgba[(3 + 2) * 4..(3 + 2) * 4 + 4], &[7, 1, 2, 255]); // x 2, y 1
    }

    #[test]
    fn top_down_32_bit_bitmaps_keep_alpha_or_are_opaque_without_it() {
        let bitmap = dib(2, -2, 32, |x, y| [1, 2, 3, (x + y) as u8 * 100]);
        let (_, _, rgba) = decode(&dib_to_png(&bitmap).unwrap_or_default());
        assert_eq!(
            rgba.chunks_exact(4).map(|px| px[3]).collect::<Vec<_>>(),
            [0, 100, 100, 200]
        );
        let no_alpha = dib(2, 2, 32, |_, _| [1, 2, 3, 0]);
        let (_, _, rgba) = decode(&dib_to_png(&no_alpha).unwrap_or_default());
        assert!(rgba.chunks_exact(4).all(|px| px == [3, 2, 1, 255]));
    }

    #[test]
    fn bitfield_masks_are_read_only_in_bgr_order() {
        let mut bitmap = dib(1, 1, 32, |_, _| [1, 2, 3, 4]);
        bitmap[16..20].copy_from_slice(&BI_BITFIELDS.to_le_bytes());
        let pixel = bitmap.split_off(40);
        let masks: Vec<u8> = [0x00FF_0000u32, 0x0000_FF00, 0x0000_00FF]
            .iter()
            .flat_map(|m| m.to_le_bytes())
            .collect();
        let standard = [bitmap.clone(), masks, pixel.clone()].concat();
        assert_eq!(
            decode(&dib_to_png(&standard).unwrap_or_default()).2,
            [3, 2, 1, 4]
        );
        let swapped: Vec<u8> = [0x0000_00FFu32, 0x0000_FF00, 0x00FF_0000]
            .iter()
            .flat_map(|m| m.to_le_bytes())
            .collect();
        assert!(dib_to_png(&[bitmap, swapped, pixel].concat()).is_none());
    }

    #[test]
    fn unreadable_bitmaps_are_refused() {
        assert!(dib_to_png(&dib(2, 2, 8, |_, _| [0; 4])).is_none());
        let mut truncated = dib(4, 4, 32, |_, _| [0; 4]);
        truncated.truncate(truncated.len() - 1);
        assert!(dib_to_png(&truncated).is_none());
        assert!(dib_to_png(&[0; 10]).is_none());
        assert!(dib_to_png(&dib(0, 1, 32, |_, _| [0; 4])).is_none());
    }

    #[test]
    fn png_becomes_a_bottom_up_bitmap_and_back() {
        let source = dib(3, -2, 32, |x, y| {
            [x as u8 * 50, y as u8 * 90, 9, 128 + x as u8]
        });
        let png = dib_to_png(&source).unwrap_or_default();
        let bitmap = png_to_dib(&png).unwrap_or_default();
        assert_eq!(i32_at(&bitmap, 8), Some(2)); // bottom-up
        assert_eq!(u16_at(&bitmap, 14), Some(32));
        assert_eq!(bitmap.len(), 40 + 3 * 2 * 4);
        // The first stored row is the bottom one (y 1): x 0 is B 0, G 90, R 9, A 128.
        assert_eq!(&bitmap[40..44], &[0, 90, 9, 128]);
        assert_eq!(
            decode(&dib_to_png(&bitmap).unwrap_or_default()),
            decode(&png)
        );
        assert!(png_to_dib(b"not a png").is_none());
    }

    #[test]
    fn grey_and_rgb_png_become_opaque_bitmaps() {
        for (color, data) in [
            (png::ColorType::Grayscale, vec![10, 20]),
            (png::ColorType::Rgb, vec![1, 2, 3, 4, 5, 6]),
        ] {
            let mut png = Vec::new();
            let mut encoder = png::Encoder::new(&mut png, 2, 1);
            encoder.set_color(color);
            let mut writer = encoder.write_header().unwrap_or_else(|e| panic!("{e}"));
            writer
                .write_image_data(&data)
                .unwrap_or_else(|e| panic!("{e}"));
            writer.finish().unwrap_or_else(|e| panic!("{e}"));
            let bitmap = png_to_dib(&png).unwrap_or_default();
            let expected: &[u8] = if color == png::ColorType::Rgb {
                &[3, 2, 1, 255, 6, 5, 4, 255]
            } else {
                &[10, 10, 10, 255, 20, 20, 20, 255]
            };
            assert_eq!(&bitmap[40..], expected);
        }
    }
}
