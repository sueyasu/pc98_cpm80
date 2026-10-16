#!/usr/bin/env python3
import argparse
import struct
from pathlib import Path

FORMATS = {
    "2dd": {"tracks": 160, "sectors": 8, "sector_size": 512, "media": 0x10},
    "2hd": {"tracks": 160, "sectors": 15, "sector_size": 512, "media": 0x20},
}

D88_HEADER_SIZE = 0x2B0
D88_TRACK_SLOTS = 164


def build_d88(raw: bytes, fmt: str, name: str) -> bytes:
    geometry = FORMATS[fmt]
    tracks = geometry["tracks"]
    sectors = geometry["sectors"]
    sector_size = geometry["sector_size"]
    expected = tracks * sectors * sector_size
    if len(raw) != expected:
        raise ValueError(
            f"{fmt}: expected {expected} bytes, got {len(raw)} bytes"
        )

    header = bytearray(D88_HEADER_SIZE)
    disk_name = name.encode("ascii", "replace")[:16]
    header[: len(disk_name)] = disk_name
    header[0x1A] = 0x00  # write enabled
    header[0x1B] = geometry["media"]

    out = bytearray(header)
    offsets = []

    for logical_track in range(tracks):
        offsets.append(len(out))
        cylinder = logical_track // 2
        head = logical_track & 1
        track_base = logical_track * sectors * sector_size

        for sector in range(1, sectors + 1):
            # D88 sector header: C H R N, sectors/track, density, deleted,
            # status, reserved[5], data size. 512 bytes => N=2.
            out += struct.pack(
                "<BBBBHBBB5sH",
                cylinder,
                head,
                sector,
                2,
                sectors,
                0x00,
                0x00,
                0x00,
                b"\x00" * 5,
                sector_size,
            )
            start = track_base + (sector - 1) * sector_size
            out += raw[start : start + sector_size]

    for index, offset in enumerate(offsets):
        struct.pack_into("<I", out, 0x20 + index * 4, offset)
    for index in range(len(offsets), D88_TRACK_SLOTS):
        struct.pack_into("<I", out, 0x20 + index * 4, 0)

    struct.pack_into("<I", out, 0x1C, len(out))
    return bytes(out)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert a PC-98 CP/M raw floppy image to D88"
    )
    parser.add_argument("--format", choices=sorted(FORMATS), required=True)
    parser.add_argument("--name", default="PC98 CPM80")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    raw = args.input.read_bytes()
    d88 = build_d88(raw, args.format, args.name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(d88)


if __name__ == "__main__":
    main()
