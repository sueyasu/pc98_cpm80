#!/usr/bin/env python3
"""PC-98 CP/M-80 24-bit BDOS disk-relative record regression model.

Run with: python3 tests/check_bdos24.py
The test checks source invariants and exercises the 24/16 division
algorithm independently. It does not emulate the assembled CP/M binary.
"""
from pathlib import Path

core = Path("src/cpm22_pc98.asm").read_text()
assert "LOGHIGH         DB" in core
assert "DIVCOUNT        DB" in core
assert "STA     LOGHIGH" in core
assert "TRKSEC1 LHLD    BLKNMBR" in core
assert "LHLD    SECTORS" in core
assert "TRKSUB  MOV     A,L" in core
assert "TRKBIT  LDA     DIVCOUNT" in core
assert "TRKSEC2" not in core
assert "TRKSEC3" not in core
assert "TRKSEC4" not in core

def divide_24_by_16(record, spt):
    assert 0 <= record <= 0xFFFFFF
    assert 1 <= spt <= 0xFFFF
    quotient = record & 0xFFFF
    remainder = record >> 16
    for _ in range(16):
        carry = (quotient >> 15) & 1
        quotient = (quotient << 1) & 0xFFFF
        remainder = (remainder << 1) | carry
        if remainder >= spt:
            remainder -= spt
            quotient |= 1
    return quotient, remainder

# 2DD/2HD and the large PC-98 HDD SPT values (records/cylinder).
sp_values = (64, 120, 128, 136, 256, 272, 360, 480, 544, 1020)
record_values = (0, 1, 127, 128, 65534, 65535, 65536, 65537,
                 131071, 131072, 262143, 524287, 1048575)
for spt in sp_values:
    for record in record_values:
        q, rem = divide_24_by_16(record, spt)
        assert (q, rem) == divmod(record, spt), (spt, record, q, rem)
        assert q < 65536

# Verify the 16 KiB allocation block to 128-byte record mapping.
for block in (0, 1, 511, 512, 1023, 4095, 8191):
    high = ((block << 7) >> 16) & 0xFF
    low = (block << 7) & 0xFFFF
    for offset in (0, 1, 63, 126, 127):
        record = (high << 16) | ((low | offset) & 0xFFFF)
        assert record == block * 128 + offset
        if block >= 512:
            assert record >= 65536

print("PASS: PC-98 CP/M-80 24-bit relative record / 16-bit SPT model")
