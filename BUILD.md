# Building floppy images

The top-level `Makefile` builds bootable PC-9801 CP/M-80 floppy images from source.

## Required tools

The normal `make` target requires:

- `make`
- `nasm`
- `asm8080`
- Python 3

`cpmtools` is not required for the normal build. The repository keeps `cpmtools/diskdefs` as a reference for manual use, but Debian/Ubuntu cpmtools reads disk format definitions from its system diskdefs file and `CPMTOOLSFMT` selects a default format name rather than a diskdefs pathname.

Run:

```sh
make
```

This creates the following files under `build/`:

```text
commands/FDISK.COM
commands/FDFORMAT.COM
commands/HDFORMAT.COM
pc98_cpm80_2dd.img
pc98_cpm80_2dd.d88
pc98_cpm80_2hd.img
pc98_cpm80_2hd.d88
```

The three command binaries are assembled from the sources in `command/` and are included in user 0 of both generated floppy images.

The RAW images use the native PC-98 geometry used by this port:

- 2DD: 80 cylinders, 2 heads, 8 x 512-byte sectors per side (640 KiB)
- 2HD: 80 cylinders, 2 heads, 15 x 512-byte sectors per side (1200 KiB)

`scripts/mkcpmimage.py` creates the CP/M 2.2 filesystem directly, writes `build/system.bin` into the system tracks, and adds the built-in commands plus optional external commands. This avoids requiring a machine-wide modification of `/etc/cpmtools/diskdefs`.

The D88 files are generated from the RAW images by `scripts/raw2d88.py` and therefore do not require a separate D88 conversion utility.

## External CP/M commands

Any `*.COM` files present in `external/commands/` are also copied into user 0 of both the 2DD and 2HD RAW images during `make`. The D88 and optional HFE images are derived from those populated RAW images.

Only put software in that directory when its redistribution terms permit doing so.

## HFE images

HFE generation is optional. If the HxC command-line converter `hxcfe` is installed, run:

```sh
make hfe
```

This converts the generated D88 images with:

```text
hxcfe -finput:<image.d88> -conv:HXC_HFE -foutput:<image.hfe>
```

`make` itself does not require HxC and succeeds without it.

## Other targets

```sh
make commands     # build FDISK.COM, FDFORMAT.COM, HDFORMAT.COM
make raw          # RAW .img images only
make d88          # RAW prerequisites plus D88 images
make hfe          # D88 prerequisites plus HFE images (requires hxcfe)
make check-tools  # check normal build dependencies
make clean        # remove build/
```

Generated floppy images are intentionally ignored by Git and should normally be published as release artifacts rather than committed to the repository.

## Boot drive and SUBMIT

BDOS function 13 takes no drive parameter. It clears the login and read-only vectors, resets DMA, and logs in the logical boot drive (the PC-98 equivalent of standard CP/M's A: reset default). CCP scans, reads and deletes the batch file `$$$.SUB` on that same boot drive, then restores the user's current drive, including A:. Warm boot preserves the current user/drive byte independently of the boot drive.

The original Digital Research SUBMIT.COM creates its temporary file on the current/default disk. Run that version with the boot drive as the current drive; use a drive prefix for the input .SUB file if necessary. External SUBMIT variants that hard-code A: require adjustment or replacement when booting from another drive. The system does not redirect explicit A: file accesses.

## Large HDD partition addressing

The BDOS stores disk-relative 128-byte record addresses as 24-bit values.
The high byte `LOGHIGH` complements the existing 16-bit `BLKNMBR`;
`TRKSEC1` divides that 24-bit address by the full **16-bit** SPT from
the current DPB. PC-98 HDD SPT may exceed 255 (unlike FM-11), so the
remainder and sector passed to the BIOS remain 16 bits. The BIOS/Gateway
layout, 16 KiB allocation blocks and 128 MiB partition limit are unchanged.
This prevents addresses above 8 MiB from wrapping to the start of a
partition. The CCP/BDOS resident image is still exactly 5632 bytes.

Run `make test-bdos24` for a host-side arithmetic regression. It checks
the source and the shift/subtract division model at 8 MiB and the
128 MiB final allocation block. It does **not** replace assembling the
BDOS or testing a disposable HDD image on V30 hardware/emulator.

A runtime check should allocate a 16 KiB file block at block number 512
(8 MiB) and near 8191 (128 MiB), write/read distinctive data, and
verify the physical image against low-address guard sectors. Include
ordinary sequential access and BDOS function 40 (zero-fill) operations.
