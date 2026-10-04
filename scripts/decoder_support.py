#!/usr/bin/env python3
"""Independent development-only ZXing-C++ and ZXing Java decoding.

Checks complete real PNG pixels before decoding. Java strict PNG detection uses
scale 3, without PURE_BARCODE or matrix fallback. The known default-scale8
case and an independent same-pixel control are reported separately, including
both rejections if they occur. No failed detection is counted as success.
"""
# SPDX-License-Identifier: MIT
# Adapted from SpecQR-CPP tools/verify-decode.py at e91cd8.
import argparse
import base64
import hashlib
import importlib
import importlib.metadata
import json
import shutil
from pathlib import Path
import string
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[1]
_FAILURE_OUTPUT = None
_FAILURE_CONTEXT = {}
JAR_VERSION = '3.5.4'
JAR_SHA256 = '71de5d89341b5fcf5dd89da7f44e84d825d0e084cdf3ec77c9abe26b0f0ceb13'
JAR_URL = f'https://repo.maven.apache.org/maven2/com/google/zxing/core/{JAR_VERSION}/core-{JAR_VERSION}.jar'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def b64(data):
    return base64.b64encode(bytes(data)).decode('ascii')


def verify_png(encoded, matrix, scale):
    """Decode standard RGB/RGBA PNG scanlines and prove every resulting pixel.

    The reference image/png decoder optimizes opaque NRGBA to RGB and chooses adaptive filters.
    Neither storage choice relaxes the expected RGBA pixels or quiet zone.
    """
    png = bytes.fromhex(encoded)
    require(png[:8] == b'\x89PNG\r\n\x1a\n', 'PNG signature mismatch')
    position, compressed, header, ended = 8, bytearray(), None, False
    while position < len(png):
        require(position + 12 <= len(png), 'Truncated PNG chunk')
        length = struct.unpack('>I', png[position:position + 4])[0]
        require(position + length + 12 <= len(png), 'Truncated PNG chunk data')
        kind, data = png[position + 4:position + 8], png[position + 8:position + 8 + length]
        require(zlib.crc32(kind + data) == struct.unpack('>I', png[position + 8 + length:position + 12 + length])[0], 'PNG CRC mismatch')
        if kind == b'IHDR':
            require(header is None and position == 8 and length == 13, 'PNG header structure mismatch')
            header = struct.unpack('>IIBBBBB', data)
        else:
            require(header is not None, 'PNG header must precede image data')
            if kind == b'IDAT':
                compressed.extend(data)
            elif kind == b'IEND':
                require(length == 0 and position + 12 == len(png), 'PNG end/trailing data mismatch')
                ended = True
            elif kind[:1].isupper():
                raise RuntimeError('Unexpected critical PNG chunk: ' + repr(kind))
        position += length + 12
    require(header is not None and ended and compressed, 'Incomplete PNG')
    width, height, depth, color, compression, filtering, interlace = header
    require(depth == 8 and color in (2, 6) and (compression, filtering, interlace) == (0, 0, 0), 'PNG RGB/RGBA format mismatch')
    dimension = (len(matrix) + 8) * scale
    require(width == height == dimension, 'PNG dimensions mismatch')
    channels = 3 if color == 2 else 4
    stride = dimension * channels
    inflater = zlib.decompressobj()
    expected_length = dimension * (stride + 1)
    raw = inflater.decompress(compressed, expected_length + 1)
    require(inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail and len(raw) == expected_length, 'PNG scanline length/compression mismatch')
    white = (b'\xff' * channels) * scale
    black = (b'\x00\x00\x00' + (b'\xff' if channels == 4 else b'')) * scale
    blank = white * (len(matrix) + 8)
    rows = [blank] * 4 + [white * 4 + b''.join(black if v == '1' else white for v in row) + white * 4 for row in matrix] + [blank] * 4
    luminance, previous = bytearray(), bytearray(stride)
    for y in range(dimension):
        start = y * (stride + 1)
        filter_type, scanline = raw[start], bytearray(raw[start + 1:start + stride + 1])
        require(filter_type in range(5), 'Invalid PNG scanline filter')
        if filter_type == 1:
            for x in range(channels, stride):
                scanline[x] = (scanline[x] + scanline[x - channels]) & 255
        elif filter_type == 2:
            scanline = bytearray((value + above) & 255 for value, above in zip(scanline, previous)) if any(scanline) else previous[:]
        elif filter_type == 3:
            for x in range(stride):
                left = scanline[x - channels] if x >= channels else 0
                scanline[x] = (scanline[x] + (left + previous[x]) // 2) & 255
        elif filter_type == 4:
            for x in range(stride):
                left = scanline[x - channels] if x >= channels else 0
                above = previous[x]
                upper_left = previous[x - channels] if x >= channels else 0
                p = left + above - upper_left
                distances = (abs(p - left), abs(p - above), abs(p - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
                scanline[x] = (scanline[x] + predictor) & 255
        # RGB storage has implicit alpha 255 at every pixel; RGBA must explicitly
        # match it. The complete channel comparison validates both representations.
        require(scanline == rows[y // scale], f'PNG pixel/quiet-zone mismatch at row {y}')
        luminance.extend(scanline[0::channels])
        previous = scanline
    return png, luminance, dimension


def independent_png(matrix, scale):
    dimension = (len(matrix) + 8) * scale
    raw = bytearray()
    for y in range(dimension):
        raw.append(0)
        for x in range(dimension):
            row, column = y // scale - 4, x // scale - 4
            raw.append(0 if 0 <= row < len(matrix) and 0 <= column < len(matrix) and matrix[row][column] == '1' else 255)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', dimension, dimension, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def verify_control_pixels(png, expected_luminance, dimension):
    position, compressed = 8, bytearray()
    while position < len(png):
        length = struct.unpack('>I', png[position:position + 4])[0]
        kind, data = png[position + 4:position + 8], png[position + 8:position + 8 + length]
        require(zlib.crc32(kind + data) == struct.unpack('>I', png[position + 8 + length:position + 12 + length])[0], 'Independent control PNG CRC mismatch')
        if kind == b'IHDR':
            require(struct.unpack('>IIBBBBB', data) == (dimension, dimension, 8, 0, 0, 0, 0), 'Independent control PNG format mismatch')
        if kind == b'IDAT':
            compressed.extend(data)
        position += length + 12
    raw = zlib.decompress(compressed)
    require(len(raw) == dimension * (dimension + 1), 'Independent control scanline length differs')
    for y in range(dimension):
        row = raw[y * (dimension + 1):(y + 1) * (dimension + 1)]
        require(row[0] == 0 and row[1:] == expected_luminance[y * dimension:(y + 1) * dimension], 'Independent control pixels differ from candidate PNG')

def cases(include_second):
    result = []
    def add(name, request, expected):
        result.append((name, request, expected))
    for level in 'LMQH':
        for mask in range(8):
            options = {'version': 4, 'errorCorrectionLevel': level, 'maskPattern': mask}
            for mode, text in [('numeric', '012345678901234567890123456789'), ('alphanumeric', 'SPECQR / 12345 %'), ('kanji', '漢字東京大阪日本語')]:
                add(f'{mode}-{level}-{mask}', {'text': text, 'options': {**options, 'mode': mode}}, {'text': text, 'bytes': text.encode('shift_jis' if mode == 'kanji' else 'utf-8')})
            text = 'e\u0301🙂漢字 café'
            add(f'utf8-{level}-{mask}', {'text': text, 'options': {**options, 'mode': 'byte', 'eci': 26}}, {'text': text, 'bytes': text.encode(), 'identifier': ']Q2'})
            data = bytes([0, 255, 128, 127, 13, 10, 29, 0, 254, 65])
            add(f'binary-{level}-{mask}', {'bytes': list(data), 'options': options}, {'bytes': data})
            add(f'fnc1-alpha-{level}-{mask}', {'segments': [{'mode': 'fnc1'}, {'mode': 'alphanumeric', 'text': '10LOT%21SER%%IAL'}], 'options': options}, {'text': '10LOT\x1d21SER%IAL', 'bytes': b'10LOT\x1d21SER%IAL', 'identifier': ']Q3'})
            add(f'fnc1-high-{level}-{mask}', {'text': '10LOT%\x1d21SER%%IAL', 'options': {**options, 'gs1': True}}, {'text': '10LOT%\x1d21SER%%IAL', 'bytes': b'10LOT%\x1d21SER%%IAL', 'identifier': ']Q3'})
    for assignment, data, text in [(3, [99,97,102,233], 'café'), (20,[138,191,142,154],'漢字'), (170,[65,83,67,73,73],'ASCII')]:
        add(f'eci-{assignment}', {'segments':[{'mode':'eci','assignmentNumber':assignment},{'mode':'byte','bytes':data}]}, {'text':text,'bytes':bytes(data),'identifier':']Q2'})
    for total in range(2, 17):
        for index in range(1, total + 1):
            data, checksum = bytes([0, index, total, 255, 128]), (total * 17 + index * 31) & 255
            add(f'sa-{index}-{total}', {'bytes': list(data), 'options': {'version': 2, 'maskPattern': index % 8, 'structuredAppend': {'index': index, 'total': total, 'parity': checksum}}}, {'bytes': data, 'sequence': (index - 1) * 16 + total - 1, 'parity': checksum})
    if include_second:
        indicators = [f'{n:02}' for n in range(100)] + list(string.ascii_uppercase + string.ascii_lowercase)
        for i, indicator in enumerate(indicators):
            for route in ['manual', 'options']:
                request = {'options': {'version': 3, 'errorCorrectionLevel': 'LMQH'[i % 4], 'maskPattern': i % 8}}
                if route == 'manual':
                    request['segments'] = [{'mode': 'fnc1-second', 'applicationIndicator': indicator}, {'mode': 'alphanumeric', 'text': 'ABC%123%%XYZ'}]
                    data = b'ABC\x1d123%XYZ'
                else:
                    request.update(text='ABC%123%%XYZ'); request['options']['fnc1Second'] = indicator
                    data = b'ABC%123%%XYZ'
                add(f'second-{indicator}-{route}', request, {'bytes': indicator.encode() + data, 'identifier': ']Q5'})
    # Detection and real PNG coverage across every Model 2 version. Fixed
    # deterministic payload size grows independently of the encoder's estimates.
    for version in range(1, 41):
        data = bytes((i * 149 + version * 43) & 255 for i in range(min(5 + version * 5, 200)))
        add(f'version-{version}', {'bytes': list(data), 'options': {'version': version, 'errorCorrectionLevel': 'LMQH'[(version - 1) % 4], 'maskPattern': (version - 1) % 8}}, {'bytes': data})
    return result

