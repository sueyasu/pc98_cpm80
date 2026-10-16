#!/usr/bin/env python3
import argparse
import math
import struct
from pathlib import Path

FORMATS = {
    "2dd": {
        "tracks": 160, "sectors": 8, "sector_size": 512,
        "boot_tracks": 4, "block_size": 2048, "max_dir": 128,
        "exm": 0, "reserved_dir_blocks": 2,
    },
    "2hd": {
        "tracks": 160, "sectors": 15, "sector_size": 512,
        "boot_tracks": 3, "block_size": 4096, "max_dir": 128,
        "exm": 1, "reserved_dir_blocks": 1,
    },
}

RECORD_SIZE = 128
DIR_ENTRY_SIZE = 32
ERASED = 0xE5
EOF_FILL = 0x1A


def cpm_name(path: Path):
    name = path.name.upper()
    stem, dot, ext = name.rpartition(".")
    if not dot:
        stem, ext = name, ""
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~"
    if not stem or len(stem) > 8 or len(ext) > 3:
        raise ValueError(f"{path}: filename is not CP/M 8.3 compatible")
    if any(ch not in allowed for ch in stem + ext):
        raise ValueError(f"{path}: filename contains unsupported CP/M characters")
    return stem.ljust(8).encode("ascii"), ext.ljust(3).encode("ascii")


def add_file(image, cfg, directory, dir_index, next_block, path):
    data = path.read_bytes()
    name, ext = cpm_name(path)
    block_size = cfg["block_size"]
    exm = cfg["exm"]
    boot_bytes = cfg["boot_tracks"] * cfg["sectors"] * cfg["sector_size"]
    total_blocks = (len(image) - boot_bytes) // block_size
    records_left = math.ceil(len(data) / RECORD_SIZE)
    source_pos = 0
    extent_base = 0

    if records_left == 0:
        records_left = 1

    while records_left:
        if dir_index >= cfg["max_dir"]:
            raise ValueError(f"{path}: CP/M directory is full")

        extent_records = min(records_left, 128 * (exm + 1))
        bytes_left = max(0, len(data) - source_pos)
        extent_bytes = min(bytes_left, extent_records * RECORD_SIZE)
        blocks_needed = math.ceil(extent_bytes / block_size) if extent_bytes else 0
        if blocks_needed > 8:
            raise AssertionError("extent needs more than eight allocation pointers")
        if next_block + blocks_needed > total_blocks:
            raise ValueError(f"{path}: disk is full")

        blocks = list(range(next_block, next_block + blocks_needed))
        for block in blocks:
            dest = boot_bytes + block * block_size
            chunk = data[source_pos:source_pos + block_size]
            image[dest:dest + len(chunk)] = chunk
            source_pos += len(chunk)

        logical_extent = extent_base + ((extent_records - 1) // 128)
        rc = extent_records - ((extent_records - 1) // 128) * 128
        entry = bytearray(DIR_ENTRY_SIZE)
        entry[0] = 0
        entry[1:9] = name
        entry[9:12] = ext
        entry[12] = logical_extent & 0x1F
        entry[13] = 0
        entry[14] = (logical_extent >> 5) & 0x3F
        entry[15] = rc
        for i, block in enumerate(blocks):
            struct.pack_into("<H", entry, 16 + i * 2, block)

        off = dir_index * DIR_ENTRY_SIZE
        directory[off:off + DIR_ENTRY_SIZE] = entry
        dir_index += 1
        next_block += blocks_needed
        records_left -= extent_records
        extent_base += exm + 1

    # CP/M file sizes are record-granular. Pad only the last partial record.
    if data and len(data) % RECORD_SIZE:
        last_record_end = source_pos - (source_pos % block_size) + (len(data) % block_size)
        if len(data) % block_size == 0:
            last_record_end = source_pos
        block_base = boot_bytes + (next_block - 1) * block_size
        used = len(data) % block_size
        if used == 0:
            used = block_size
        pad = RECORD_SIZE - (len(data) % RECORD_SIZE)
        image[block_base + used:block_base + used + pad] = bytes([EOF_FILL]) * pad

    return dir_index, next_block


def build_image(fmt, system, files):
    cfg = FORMATS[fmt]
    total_size = cfg["tracks"] * cfg["sectors"] * cfg["sector_size"]
    boot_bytes = cfg["boot_tracks"] * cfg["sectors"] * cfg["sector_size"]
    system_data = system.read_bytes()
    if len(system_data) > boot_bytes:
        raise ValueError(
            f"{system}: {len(system_data)} bytes exceeds {fmt} boot area of {boot_bytes} bytes"
        )

    image = bytearray([ERASED]) * total_size
    image[:len(system_data)] = system_data

    directory_size = cfg["max_dir"] * DIR_ENTRY_SIZE
    directory = bytearray([ERASED]) * directory_size
    dir_index = 0
    next_block = cfg["reserved_dir_blocks"]
    seen = set()

    for path in files:
        name, ext = cpm_name(path)
        key = name + ext
        if key in seen:
            raise ValueError(f"{path}: duplicate CP/M filename")
        seen.add(key)
        dir_index, next_block = add_file(
            image, cfg, directory, dir_index, next_block, path
        )

    image[boot_bytes:boot_bytes + directory_size] = directory
    return bytes(image)


def main():
    parser = argparse.ArgumentParser(
        description="Build a raw CP/M 2.2 floppy image for the PC-98 port"
    )
    parser.add_argument("--format", choices=sorted(FORMATS), required=True)
    parser.add_argument("--system", type=Path, required=True)
    parser.add_argument("--file", action="append", type=Path, default=[])
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    image = build_image(args.format, args.system, args.file)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)


if __name__ == "__main__":
    main()
