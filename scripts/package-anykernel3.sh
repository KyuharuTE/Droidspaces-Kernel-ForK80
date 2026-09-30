#!/usr/bin/env bash
#
# Wrap a built kernel Image into a flashable AnyKernel3 zip.
#
# AnyKernel3 replaces the kernel inside whatever boot.img is already on the
# device, so the zip stays valid across ROM updates and does not need the
# stock boot image as an input.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

IMAGE="${IMAGE:?IMAGE must point at the built Image}"
OUT_ZIP="${OUT_ZIP:?OUT_ZIP must be the output zip path}"
DEVICE_CODENAME="${DEVICE_CODENAME:-zorn}"
KERNEL_STRING="${KERNEL_STRING:-Droidspaces + KernelSU-Next}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
# WildKernels' GKI fork ships sane defaults for A/B dynamic-partition devices.
# Upstream osm0sis/master still carries Galaxy Nexus defaults and needs them
# patched, which the sed block below does. Override to osm0sis/AnyKernel3 +
# AK3_REF=master if you prefer upstream.
AK3_REPO="${AK3_REPO:-https://github.com/WildKernels/AnyKernel3.git}"
AK3_REF="${AK3_REF:-gki-2.0}"
# gzip | lz4 | none. Compressed by default: the raw Image is ~36 MB and does not
# fit the boot partition, which shows up as "New image larger than target
# partition" during the flash.
KERNEL_COMPRESSION="${KERNEL_COMPRESSION:-gzip}"

info() { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$IMAGE" ] || die "Image not found: $IMAGE"

# An arm64 kernel Image is a raw binary, not an ELF. The arm64 boot header
# carries the magic "ARM\x64" at offset 56. Catching a wrong-arch or truncated
# image here beats flashing it and wondering why the device is dark.
info "Sanity checking kernel image"
MAGIC="$(dd if="$IMAGE" bs=1 skip=56 count=4 2>/dev/null || true)"
EXPECTED_MAGIC="$(printf 'ARM\x64')"
if [ "$MAGIC" != "$EXPECTED_MAGIC" ]; then
    die "Image does not look like an arm64 kernel Image (magic: $MAGIC)"
fi
info "arm64 magic present, $(du -h "$IMAGE" | cut -f1)"

info "Fetching AnyKernel3"
# The osm0sis template still ships Galaxy Nexus defaults: BLOCK points at an
# omap partition that does not exist on any modern device, and IS_SLOT_DEVICE=0
# makes an A/B device non-slotted. Both are rewritten below. Note AnyKernel3
# master removed the lowercase aliases (block=, is_slot_device=) in mid-2026, so
# the uppercase spellings are the only ones that work on master.
AK3_DIR="$RUNNER_TEMP/AnyKernel3"
if [ ! -d "$AK3_DIR/.git" ]; then
    git clone --depth 1 --branch "$AK3_REF" "$AK3_REPO" "$AK3_DIR" \
        || die "AnyKernel3 clone failed"
fi

# AnyKernel3 is a template for many devices. Trim it to one, and drop the
# sample kernels so the zip only contains what this build produced.
rm -rf "$AK3_DIR/.git" "$AK3_DIR/README.md" "$AK3_DIR/LICENSE"
rm -f "$AK3_DIR"/Image* "$AK3_DIR"/*.zip
find "$AK3_DIR" -maxdepth 1 -name '*.md' -delete

[ -f "$AK3_DIR/anykernel.sh" ] || die "anykernel.sh missing from AnyKernel3"

info "Configuring anykernel.sh for $DEVICE_CODENAME"
sed -i -E "s|^kernel\.string=.*|kernel.string=${KERNEL_STRING}|" "$AK3_DIR/anykernel.sh"
# do.devicecheck=1 would make the zip refuse to install on an unexpected
# codename. Off, because the same GKI kernel is valid across zorn-family ROMs
# and a wrong codename string should not block recovery from a bad flash.
sed -i -E "s|^do\.devicecheck=.*|do.devicecheck=0|" "$AK3_DIR/anykernel.sh"
sed -i -E "s|^device\.name1=.*|device.name1=${DEVICE_CODENAME}|" "$AK3_DIR/anykernel.sh"
# Only boot.img is replaced, so vendor_dlkm keeps the stock modules. systemless
# overlay handling is for Magisk-style ramdisk patching and is off in every
# maintained GKI builder.
sed -i -E "s|^do\.modules=.*|do.modules=0|" "$AK3_DIR/anykernel.sh"
sed -i -E "s|^do\.systemless=.*|do.systemless=0|" "$AK3_DIR/anykernel.sh"
# The decisive two, in whichever spelling this AnyKernel3 revision uses. The
# WildKernels GKI fork still uses lowercase `block=`/`is_slot_device=` (it keeps
# the backwards-compat aliases), while osm0sis master deleted those aliases and
# uses uppercase only. Match case-insensitively so either fork lands correctly.
# Upstream master's template hardcodes an omap by-name path and
# IS_SLOT_DEVICE=0, which on a zorn (A/B, dynamic partitions) either fails to
# find the partition or writes to the inactive slot. `auto` makes AnyKernel3
# resolve boot via by-name/bootdevice and append _a/_b itself.
sed -i -E "s|^[Bb][Ll][Oo][Cc][Kk]=.*|block=auto;|" "$AK3_DIR/anykernel.sh"
sed -i -E "s|^[Ii][Ss]_[Ss][Ll][Oo][Tt]_[Dd][Ee][Vv][Ii][Cc][Ee]=.*|is_slot_device=auto;|" "$AK3_DIR/anykernel.sh"

# Fail loudly rather than shipping a zip that flashes the wrong partition.
# Verify by value, not by spelling, so both forks pass.
if ! grep -qiE '^[Bb][Ll][Oo][Cc][Kk]=(auto|boot);?' "$AK3_DIR/anykernel.sh"; then
    die "BLOCK is not auto/boot in anykernel.sh, the zip would target the wrong partition"
fi
if ! grep -qiE '^[Ii][Ss]_[Ss][Ll][Oo][Tt]_[Dd][Ee][Vv][Ii][Cc][Ee]=auto;?' "$AK3_DIR/anykernel.sh"; then
    die "IS_SLOT_DEVICE is not auto, an A/B device would get the wrong slot"
fi

grep -iE '^(do\.devicecheck|do\.modules|do\.systemless|block|is_slot_device)=' "$AK3_DIR/anykernel.sh" \
    | while read -r line; do info "anykernel.sh: $line"; done

info "Placing kernel"
# Ship a compressed kernel, not the raw one.
#
# The raw arm64 Image for this tree is ~36 MB, and flashing it fails with
# "New image larger than target partition". AnyKernel3 hands whatever it finds
# to magiskboot, and magiskboot only keeps a kernel compressed if it was given
# one already: given a raw Image it writes a raw Image, which the boot partition
# cannot hold.
#
# AnyKernel3 looks for these names in order (ak3-core.sh):
#   zImage zImage-dtb Image Image-dtb Image.gz Image.gz-dtb Image.bz2 ...
# so Image.gz is picked up correctly and magiskboot then repacks it gzipped.
#
# gzip is the safe default: arm64 GKI kernels always carry CONFIG_KERNEL_GZIP,
# so the bootloader can decompress it. -n omits the timestamp and filename so
# the same Image always produces the same bytes.
case "$KERNEL_COMPRESSION" in
    gzip | "" )
        info "Compressing Image with gzip (raw: $(du -h "$IMAGE" | cut -f1))"
        gzip -9nc "$IMAGE" >"$AK3_DIR/Image.gz" || die "gzip failed"
        # A truncated or empty gz would still be flashed, so verify it round-trips.
        gzip -t "$AK3_DIR/Image.gz" || die "produced Image.gz is corrupt"
        RAW_SIZE=$(stat -c %s "$IMAGE")
        GZ_SIZE=$(stat -c %s "$AK3_DIR/Image.gz")
        [ "$GZ_SIZE" -lt "$RAW_SIZE" ] || die "Image.gz is not smaller than Image"
        info "Image.gz: $((GZ_SIZE / 1024 / 1024)) MB vs $((RAW_SIZE / 1024 / 1024)) MB raw"
        ;;
    lz4)
        info "Compressing Image with lz4"
        lz4 -l -9 -f "$IMAGE" "$AK3_DIR/Image.lz4" >/dev/null || die "lz4 failed"
        ;;
    none)
        warn "KERNEL_COMPRESSION=none: shipping the raw Image, which may not fit the boot partition"
        cp "$IMAGE" "$AK3_DIR/Image"
        ;;
    *)
        die "Unknown KERNEL_COMPRESSION '$KERNEL_COMPRESSION' (use gzip, lz4 or none)"
        ;;
esac

[ -d "$AK3_DIR/META-INF" ] || die "AnyKernel3 META-INF missing"
[ -d "$AK3_DIR/tools" ] || die "AnyKernel3 tools missing"

info "Creating zip"
mkdir -p "$(dirname "$OUT_ZIP")"
rm -f "$OUT_ZIP"
# -r recurse, -9 max compression. Zip the directory contents so the archive
# root is what a recovery expects, not a nested AnyKernel3/ folder.
( cd "$AK3_DIR" && zip -r9 "$OUT_ZIP" . -x '*.zip' >/dev/null ) || die "zip failed"

[ -f "$OUT_ZIP" ] || die "zip was not produced"
info "Package: $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"

info "Archive layout"
unzip -l "$OUT_ZIP" | awk 'NR<=6 || /anykernel\.sh|Image/'
