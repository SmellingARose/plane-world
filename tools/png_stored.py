#!/usr/bin/env python3
"""Re-encode a PNG as 8-bit RGBA with filter 0 and stored (uncompressed) deflate blocks, the subset that
pw::render::readPNG (render_selftests.cpp) decodes. Used for the Swift reference screenshots in tests/render_ref.
usage: python3 -I tools/png_stored.py in.png out.png"""
import struct, sys, zlib
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGBA")
w, h = img.size
raw = b"".join(b"\x00" + img.tobytes()[y * w * 4:(y + 1) * w * 4] for y in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
with open(sys.argv[2], "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n")
    f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
    f.write(chunk(b"IDAT", zlib.compress(raw, 0)))
    f.write(chunk(b"IEND", b""))
