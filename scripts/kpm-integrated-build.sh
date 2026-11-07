#!/usr/bin/env bash
#
# Build a kernel with KernelPatch compiled in, so the resulting Image can load
# .kpm modules directly. No image patching, no boot.img repack, no kptools.
#
# Contrast with scripts/kpm-patch-image.sh, which does the opposite: it leaves
# the kernel build alone and appends a payload to a finished Image. That works,
# but it is a step outside the build. This script makes KPM support part of the
# build, so `make Image` already produces a kernel that has the supercall and the
# KPM loader.
#
# The superkey is baked into the kernel at vendor time, so it must be decided
# before the build and must match what the manager app sends.
#
# Usage:
#   SUPERKEY='...' bash scripts/kpm-integrated-build.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_ROOT="${KERNEL_ROOT:-$REPO_ROOT/kernel}"
OUT_DIR="${OUT_DIR:-$KERNEL_ROOT/out}"
SUPERKEY="${SUPERKEY:-}"

info() { printf '\n[INFO] %s\n' "$*"; }
die()  { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

[ -f "$KERNEL_ROOT/Makefile" ] || die "No kernel source at $KERNEL_ROOT. Run scripts/codespace-build.sh setup first."
[ -n "$SUPERKEY" ] || die "SUPERKEY is not set. It is compiled into the kernel and must match the manager app's key."

# --- 1. Vendor KernelPatch ------------------------------------------------
#
# Idempotent: re-running re-clones and re-applies the superkey, which is what
# you want after changing the key.
info "Vendoring KernelPatch with the compiled-in superkey"
python3 "$REPO_ROOT/scripts/vendor-kpatch.py" "$KERNEL_ROOT" "$SUPERKEY" \
    || die "vendoring failed"

# --- 2. Configure ---------------------------------------------------------
MAKE_ARGS=(
    -C "$KERNEL_ROOT"
    O="$OUT_DIR"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    HOSTCC=gcc
)

info "Generating the base config"
make "${MAKE_ARGS[@]}" gki_defconfig >/dev/null || die "gki_defconfig failed"

FRAGMENT="$REPO_ROOT/kernel-configs/droidspaces-gki.config"
info "Merging $FRAGMENT"
"$KERNEL_ROOT/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
    "$OUT_DIR/.config" "$FRAGMENT" >/dev/null || die "merge_config failed"

# The fragment already sets CONFIG_KP_LKM=y; set it again explicitly so a build
# with an older checkout of the fragment still produces a KPM-capable kernel.
for sym in CONFIG_KP_LKM; do
    if grep -qE "^${sym}=" "$OUT_DIR/.config"; then
        sed -i -E "s|^${sym}=.*|${sym}=y|" "$OUT_DIR/.config"
    else
        printf '%s=y\n' "$sym" >>"$OUT_DIR/.config"
    fi
done

make "${MAKE_ARGS[@]}" olddefconfig >/dev/null || die "olddefconfig failed"

# --- 3. Verify it is really going to be in the kernel ---------------------
#
# KP_LKM is a bool now, not a tristate, so the only valid value is y. If it
# silently went away, the loader will be missing at boot and the failure would
# only show up on the device.
FAILED=0
check_y() {
    local sym="$1" desc="$2"
    if grep -qE "^${sym}=y" "$OUT_DIR/.config"; then
        printf '  \033[1;32mOK\033[0m      %-28s %s\n' "$sym" "$desc"
    else
        printf '  \033[1;31mMISSING\033[0m %-28s %s\n' "$sym" "$desc"
        FAILED=1
    fi
}

info "Verifying KPM support is enabled"
check_y CONFIG_KP_LKM   "the KernelPatch driver is compiled in"
check_y CONFIG_KALLSYMS "the loader resolves KPM symbols by name"
[ "$FAILED" = "0" ] || die "KPM support is not enabled in this config"

# --- 4. Build -------------------------------------------------------------
info "Compiling"
make "${MAKE_ARGS[@]}" -j"${BUILD_JOBS:-$(nproc)}" Image || die "kernel build failed"

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "no Image at $IMAGE"

# The supercall lives on syscall 45 and the key is a plain literal in the
# kernel image, so its presence is a cheap end-to-end check that the rewrite
# actually made it into the build.
if ! strings -a "$IMAGE" | grep -qF "$SUPERKEY"; then
    die "the superkey is not present in $IMAGE; the vendored supercall.c may not have been rebuilt"
fi
info "Superkey is embedded in the Image"

info "Built $IMAGE ($(du -h "$IMAGE" | cut -f1))"
info "Load .kpm files from the manager app with the same SUPERKEY."
info "Package with scripts/package-anykernel3.sh as usual."
