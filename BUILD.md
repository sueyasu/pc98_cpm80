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
