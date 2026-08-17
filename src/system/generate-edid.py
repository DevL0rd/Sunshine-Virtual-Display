#!/usr/bin/env python3
import argparse
import math
import re
import struct
import sys

VICS = [97, 118, 117, 96, 95, 63, 64, 16, 4, 1]


def timing(width, height, refresh):
    hblank, hfront, hsync = 160, 48, 32
    htotal = width + hblank
    vfront, vsync = 3, 8
    minimum = 0.00046
    vblank = math.ceil(minimum * refresh * height / (1.0 - minimum * refresh))
    vblank = max(vblank, vfront + vsync + 6)
    vtotal = height + vblank
    clock = int(round(htotal * vtotal * refresh / 10000.0)) * 10
    return {
        "width": width,
        "height": height,
        "refresh": refresh,
        "hblank": hblank,
        "hfront": hfront,
        "hsync": hsync,
        "vblank": vblank,
        "vfront": vfront,
        "vsync": vsync,
        "clock": clock,
    }


def descriptor(value):
    width = value["width"]
    height = value["height"]
    hblank = value["hblank"]
    vblank = value["vblank"]
    hfront = value["hfront"]
    hsync = value["hsync"]
    vfront = value["vfront"]
    vsync = value["vsync"]
    clock = value["clock"] // 10
    if clock > 65535:
        raise ValueError("pixel clock exceeds EDID DTD limit")
    data = bytearray(18)
    data[0] = clock & 255
    data[1] = clock >> 8
    data[2] = width & 255
    data[3] = hblank & 255
    data[4] = ((width >> 4) & 240) | ((hblank >> 8) & 15)
    data[5] = height & 255
    data[6] = vblank & 255
    data[7] = ((height >> 4) & 240) | ((vblank >> 8) & 15)
    data[8] = hfront & 255
    data[9] = hsync & 255
    data[10] = ((vfront & 15) << 4) | (vsync & 15)
    data[11] = (((hfront >> 8) & 3) << 6) | (((hsync >> 8) & 3) << 4) | (((vfront >> 4) & 3) << 2) | ((vsync >> 4) & 3)
    data[12:15] = bytes([88, 84, 33])
    data[17] = 30
    return bytes(data)


def name_descriptor(name):
    data = bytearray(18)
    data[3] = 252
    encoded = name.encode("ascii")[:13]
    data[5:5 + len(encoded)] = encoded
    position = 5 + len(encoded)
    if position < 18:
        data[position] = 10
        position += 1
    data[position:18] = b" " * (18 - position)
    return bytes(data)


def range_descriptor():
    data = bytearray(18)
    data[3] = 253
    data[4] = 10
    data[5:11] = bytes([24, 240, 30, 255, 120, 1])
    data[11] = 10
    data[12:18] = b" " * 6
    return bytes(data)


def checksum(block):
    return (-sum(block[:-1])) & 255


def parse_modes(path):
    values = []
    seen = set()
    pattern = re.compile(r"^(\d{3,4})x(\d{3,4})@(\d{2,3}(?:\.\d+)?)$")
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            match = pattern.fullmatch(line)
            if not match:
                raise ValueError(f"invalid mode: {line}")
            width, height = int(match.group(1)), int(match.group(2))
            refresh = float(match.group(3))
            if not 320 <= width <= 4095 or not 320 <= height <= 4095 or not 24 <= refresh <= 240:
                raise ValueError(f"mode outside allowed range: {line}")
            key = width, height, round(refresh, 3)
            if key in seen:
                continue
            seen.add(key)
            value = timing(width, height, refresh)
            if value["clock"] // 10 > 65535:
                raise ValueError(f"mode exceeds EDID DTD pixel clock limit: {line}")
            values.append(value)
    if len(values) < 2:
        raise ValueError("at least two encodable modes are required")
    return values


def base_block(modes, name, extensions):
    block = bytearray(128)
    block[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    block[8:10] = b"Pt"
    block[10:12] = struct.pack("<H", 1)
    block[12:16] = struct.pack("<I", 1)
    block[16:20] = bytes([1, 36, 1, 4])
    block[20:25] = bytes([165, 60, 34, 120, 6])
    block[25:35] = bytes([238, 145, 163, 84, 76, 153, 38, 15, 80, 84])
    block[35] = 32
    for index in range(8):
        block[38 + index * 2:40 + index * 2] = b"\x01\x01"
    block[54:72] = descriptor(modes[0])
    block[72:90] = descriptor(modes[1])
    block[90:108] = range_descriptor()
    block[108:126] = name_descriptor(name)
    block[126] = extensions
    block[127] = checksum(block)
    return block


def primary_extension(modes):
    block = bytearray(128)
    block[0:2] = b"\x02\x03"
    position = 4
    block[position] = 64 | len(VICS)
    block[position + 1:position + 1 + len(VICS)] = bytes(VICS)
    position += 1 + len(VICS)
    block[position:position + 4] = bytes([35, 23, 127, 7])
    position += 4
    block[position:position + 4] = bytes([131, 1, 0, 0])
    position += 4
    block[position:position + 3] = bytes([226, 0, 79])
    position += 3
    block[2] = position
    block[3] = 192
    used = 0
    while used < len(modes) and position + 18 <= 127:
        block[position:position + 18] = descriptor(modes[used])
        position += 18
        used += 1
    block[127] = checksum(block)
    return block, used


def extra_extension(modes):
    block = bytearray(128)
    block[:4] = bytes([2, 3, 4, 192])
    position = 4
    used = 0
    while used < len(modes) and position + 18 <= 127:
        block[position:position + 18] = descriptor(modes[used])
        position += 18
        used += 1
    block[127] = checksum(block)
    return block, used


def build(modes, name):
    remaining = modes[2:]
    primary, used = primary_extension(remaining)
    remaining = remaining[used:]
    extensions = [primary]
    while remaining:
        block, used = extra_extension(remaining)
        extensions.append(block)
        remaining = remaining[used:]
    blocks = [base_block(modes, name, len(extensions)), *extensions]
    return b"".join(blocks)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("modes")
    parser.add_argument("output")
    parser.add_argument("--name", default="SUNSHINE-VM")
    args = parser.parse_args()
    modes = parse_modes(args.modes)
    data = build(modes, args.name)
    with open(args.output, "wb") as handle:
        handle.write(data)
    for index in range(len(data) // 128):
        if sum(data[index * 128:(index + 1) * 128]) & 255:
            raise RuntimeError(f"checksum failure in block {index}")
    print(f"wrote {len(data)} bytes with {len(modes)} DTD modes and {len(VICS)} CTA modes")


if __name__ == "__main__":
    main()
