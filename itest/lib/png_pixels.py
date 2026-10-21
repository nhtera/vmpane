"""Pixels of a PNG with the standard library only (/usr/bin/python3 has no imaging library): 8-bit RGB or RGBA,
not interlaced, which is what VMPane's screenshots are. For finding controls that have no text (a switch)."""
import struct
import zlib


def read(data):
    """(width, height, rows): rows of (r, g, b) tuples."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, chunks, header = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            chunks.append(body)
        pos += 12 + length
    width, height, depth, color, _, _, interlace = header
    assert depth == 8 and color in (2, 6) and interlace == 0, f"unsupported PNG {depth} {color} {interlace}"
    channels = 3 if color == 2 else 4
    raw = zlib.decompress(b"".join(chunks))
    stride = width * channels
    rows, previous = [], bytearray(stride)
    for y in range(height):
        kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            left = line[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if kind == 1:
                line[x] = (line[x] + left) & 0xFF
            elif kind == 2:
                line[x] = (line[x] + up) & 0xFF
            elif kind == 3:
                line[x] = (line[x] + (left + up) // 2) & 0xFF
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[x] = (line[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 0xFF
        rows.append([tuple(line[i:i + 3]) for i in range(0, stride, channels)])
        previous = line
    return width, height, rows


def switch_right_of(rows, y, x):
    """The center x of a switch on row `y` right of `x` (a list row's label): the first run of pixels, 20 to 120
    wide, that stands out from the row's background; None when there is none."""
    line = [sum(pixel) // 3 for pixel in rows[y]]
    background = line[x + 10]
    start = None
    for here in range(x + 10, len(line)):
        differs = abs(line[here] - background) > 20
        if differs and start is None:
            start = here
        elif start is not None and not differs and all(abs(v - background) <= 4 for v in line[here:here + 6]):
            if 20 <= here - start <= 120:
                return (start + here) // 2
            start = None
    return None
