#!/usr/bin/env python3
import argparse
import math
import re
import struct
from fractions import Fraction


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


def aspect_code(width, height):
    ratio = Fraction(width, height)
    ratios = {
        Fraction(1, 1): 0,
        Fraction(5, 4): 1,
        Fraction(4, 3): 2,
        Fraction(15, 9): 3,
        Fraction(16, 9): 4,
        Fraction(16, 10): 5,
        Fraction(64, 27): 6,
        Fraction(256, 135): 7,
    }
    return ratios.get(ratio, 8)


def displayid_descriptor(value, preferred=False):
    clock = value["clock"] // 10 - 1
    if not 0 <= clock <= 0xFFFFFF:
        raise ValueError("pixel clock exceeds DisplayID Type I limit")
    flags = aspect_code(value["width"], value["height"])
    if preferred:
        flags |= 0x80
    hsync = value["hfront"] - 1 | 0x8000
    vsync = value["vfront"] - 1
    return struct.pack(
        "<3sBHHHHHHHH",
        clock.to_bytes(3, "little"),
        flags,
        value["width"] - 1,
        value["hblank"] - 1,
        hsync,
        value["hsync"] - 1,
        value["height"] - 1,
        value["vblank"] - 1,
        vsync,
        value["vsync"] - 1,
    )


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


def serial_descriptor():
    data = bytearray(18)
    data[3] = 255
    data[5:15] = b"VIRTUAL001"
    data[15] = 10
    data[16:18] = b" " * 2
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
            if not (
                320 <= width <= 4095
                and 320 <= height <= 4095
                and 24 <= refresh <= 240
            ):
                raise ValueError(f"mode outside allowed range: {line}")
            key = width, height, round(refresh, 3)
            if key in seen:
                continue
            seen.add(key)
            value = timing(width, height, refresh)
            values.append(value)
    if not values:
        raise ValueError("at least one mode is required")
    return values


def base_block(mode, name, extensions):
    block = bytearray(128)
    block[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    block[8:10] = b"Pt"
    block[10:12] = struct.pack("<H", 1)
    block[12:16] = struct.pack("<I", 0)
    block[16:20] = bytes([1, 36, 1, 4])
    block[20:25] = bytes([165, 60, 34, 120, 6])
    block[25:35] = bytes([238, 145, 163, 84, 76, 153, 38, 15, 80, 84])
    block[35] = 32
    for index in range(8):
        block[38 + index * 2:40 + index * 2] = b"\x01\x01"
    block[54:72] = descriptor(mode)
    block[72:90] = range_descriptor()
    block[90:108] = name_descriptor(name)
    block[108:126] = serial_descriptor()
    block[126] = extensions
    block[127] = checksum(block)
    return block


def displayid_product_block():
    payload = b"VRT" + struct.pack("<HI", 1, 1) + bytes([1, 26, 0])
    return bytes([0, 0, len(payload)]) + payload


def displayid_parameters_block(native):
    payload = struct.pack(
        "<HHHHBBBB",
        6000,
        3400,
        native["width"],
        native["height"],
        0,
        120,
        60,
        0x77,
    )
    return bytes([1, 0, len(payload)]) + payload


def displayid_interface_block():
    payload = bytes([0xA1, 0x14, 0x02, 0, 0, 0, 0, 0, 0, 0])
    return bytes([0x0F, 0, len(payload)]) + payload


def displayid_extension(payload, product_type, extension_count):
    block = bytearray(128)
    block[:5] = bytes([0x70, 0x13, len(payload), product_type, extension_count])
    block[5:5 + len(payload)] = payload
    displayid_checksum = 5 + len(payload)
    block[displayid_checksum] = (-sum(block[1:displayid_checksum])) & 255
    block[127] = checksum(block)
    return block


def displayid_extensions(modes, native):
    groups = []
    remaining = list(modes)
    while remaining:
        capacity = 3 if not groups else 5
        groups.append(remaining[:capacity])
        remaining = remaining[capacity:]
    blocks = []
    for index, group in enumerate(groups):
        timings = b"".join(
            displayid_descriptor(value, preferred=index == 0 and item == 0)
            for item, value in enumerate(group)
        )
        timing_block = bytes([3, 1, len(timings)]) + timings
        prefix = b""
        if index == 0:
            prefix = (
                displayid_product_block()
                + displayid_parameters_block(native)
                + displayid_interface_block()
            )
        blocks.append(
            displayid_extension(
                prefix + timing_block,
                3 if index == 0 else 0,
                len(groups) - 1 if index == 0 else 0,
            )
        )
    return blocks


def base_mode(modes):
    preferred = next(
        (
            value
            for value in modes
            if value["width"] == 1920
            and value["height"] == 1080
            and abs(value["refresh"] - 60) < 0.01
        ),
        None,
    )
    if preferred is not None:
        return preferred
    fallback = next((value for value in modes if value["clock"] // 10 <= 65535), None)
    if fallback is None:
        raise ValueError("at least one mode must fit the EDID base timing")
    return fallback


def build(modes, name):
    native = max(modes, key=lambda value: value["clock"])
    ordered = list(modes)
    ordered.remove(native)
    ordered.insert(0, native)
    extensions = displayid_extensions(ordered, native)
    blocks = [base_block(base_mode(modes), name, len(extensions)), *extensions]
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
    print(f"wrote {len(data)} bytes with {len(modes)} DisplayID modes")


if __name__ == "__main__":
    main()
