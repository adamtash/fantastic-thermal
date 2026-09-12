#!/usr/bin/env python3
"""Losslessly recompress ICNS PNG streams with the standard-library zlib.

Preserves every pixel byte, row filter, color profile, and transparency channel.
No platform-specific PNG optimizer or imaging dependency is required.
"""
from pathlib import Path
import struct
import sys
import zlib


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def compress_png(source):
    chunks = []
    offset = 8
    compressed = bytearray()
    while offset < len(source):
        size = struct.unpack('>I', source[offset:offset + 4])[0]
        kind = source[offset + 4:offset + 8]
        data = source[offset + 8:offset + 8 + size]
        crc = struct.unpack('>I', source[offset + 8 + size:offset + 12 + size])[0]
        if zlib.crc32(kind + data) != crc:
            raise ValueError('Invalid source PNG checksum')
        chunks.append((kind, data))
        if kind == b'IDAT': compressed.extend(data)
        offset += size + 12
    pixels = zlib.decompress(compressed)
    repacked = zlib.compress(pixels, level=9)
    assert zlib.decompress(repacked) == pixels
    result = bytearray(source[:8])
    emitted = False
    for kind, data in chunks:
        if kind == b'IDAT':
            if emitted: continue
            data = repacked
            emitted = True
        result.extend(png_chunk(kind, data))
    return bytes(result) if len(result) < len(source) else source


path = Path(sys.argv[1])
source = path.read_bytes()
if source[:4] != b'icns': raise ValueError('Expected ICNS')
chunks = []
cache = {}
offset = 8
while offset < len(source):
    kind = source[offset:offset + 4]
    length = struct.unpack('>I', source[offset + 4:offset + 8])[0]
    if length < 8 or offset + length > len(source): raise ValueError('Invalid ICNS chunk')
    data = source[offset + 8:offset + length]
    if data.startswith(b'\x89PNG'):
        if data not in cache: cache[data] = compress_png(data)
        data = cache[data]
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
    offset += length
body = b''.join(chunks)
path.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
print(f'Lossless icon compression: {len(source):,} → {len(body) + 8:,} bytes')
