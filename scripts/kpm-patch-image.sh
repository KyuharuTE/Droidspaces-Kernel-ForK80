#!/usr/bin/env bash
#
# Patch a built arm64 kernel Image with KernelPatch (kpimg) so the kernel can
# load .kpm modules at runtime.
#
# Why a binary patch and not a kernel source change
# -------------------------------------------------
# KernelPatch is not an in-tree kernel option. kptools appends a freestanding
# payload (kpimg) to the Image, redirects primary_entry to it, and fixes the
# arm64 header. At boot kpimg installs the supercall (syscall 45), the inline
# hook engine and the KPM loader.
#
# That keeps the kernel source clean and, importantly, does not touch exported
# symbols or struct layouts, so the kABI stays intact and the stock vendor
# modules keep loading.
#
# Requirements on the Image (checked instead of assumed):
#   CONFIG_KALLSYMS=y     kpimg resolves kernel functions by name at boot
#   KALLSYMS_ALL          strongly recommended
#
# Input is a raw uncompressed Image, never a bare gzipped one: kptools accepts
# an Image or an ANDROID! boot.img, and handles compression only inside a boot
# image. Compress after patching, when packaging.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_ROOT="${KERNEL_ROOT:-$REPO_ROOT/kernel}"
OUT_DIR="${OUT_DIR:-$KERNEL_ROOT/out}"
IMAGE="${IMAGE:-$OUT_DIR/arch/arm64/boot/Image}"
OUT_IMAGE="${OUT_IMAGE:-$REPO_ROOT/dist/Image.kp}"

# Vendored separate from the kernel tree so a kernel rebuild never wipes it.
KP_DIR="${KP_DIR:-$REPO_ROOT/.kp/KernelPatch}"
KP_REF="${KP_REF:-main}"

# AARCH64_CODE_MODEL: the payload is built for bare metal. Distro GCC is fine
# here because the payload is freestanding (-nostdinc), it just needs the
# default flags fixed up for a kernel-resident blob.
CROSS="${CROSS:-aarch64-linux-gnu-}"

# The superkey authenticates privileged supercalls. Keep it out of argv when you
# can: kptools also accepts --skey-fd. Providing it here makes it visible in the
# process list, so prefer the environment, and rotate it if this host is shared.
SUPERKEY="${SUPERKEY:-}"

info() { printf '\n[INFO] %s\n' "$*"; }
die()  { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

[ -f "$IMAGE" ] || die "No kernel Image at $IMAGE. Build the kernel first."
[ -n "$SUPERKEY" ] || die "SUPERKEY is not set. Export it, e.g. SUPERKEY='...' bash scripts/kpm-patch-image.sh"
[ "${#SUPERKEY}" -le 64 ] || die "SUPERKEY is longer than the 64-byte KernelPatch limit"

# --- 1. KernelPatch sources and tools ---------------------------------------
if [ ! -d "$KP_DIR/.git" ]; then
    info "Cloning KernelPatch into $KP_DIR"
    mkdir -p "$(dirname "$KP_DIR")"
    git clone --depth 1 --branch "$KP_REF" \
        https://github.com/bmax121/KernelPatch.git "$KP_DIR" \
        || die "KernelPatch clone failed"
fi
info "KernelPatch $(cat "$KP_DIR/version" 2>/dev/null | tr '\n' ' ')"

KPT_TOOLS="$KP_DIR/tools/kptools"
KPIMG="$KP_DIR/kernel/kpimg"

# --- 2. Build the host tool (kptools) --------------------------------------
if [ ! -x "$KPT_TOOLS" ]; then
    info "Building kptools"
    command -v cc >/dev/null || die "No host C compiler for kptools"
    ( cd "$KP_DIR/tools" && ANDROID=1 make -j"$(nproc)" ) || die "kptools build failed"
    [ -x "$KPT_TOOLS" ] || die "kptools was not produced"
fi

# --- 3. Build the payload (kpimg) ------------------------------------------
#
# The in-tree CFLAGS assume an older distro GCC. Modern GCC enables the stack
# protector and PIC by default, and the payload is freestanding with no libc, so
# the link fails with undefined __stack_chk_guard and "Unexpected GOT/PLT
# entries". Both have to be turned back off, and command line CFLAGS wins over
# the Makefile's +=, which is the only reason this override works.
KP_CFLAGS="-Wall -fno-builtin -std=gnu11 -nostdinc -mgeneral-regs-only \
-ffixed-x18 -fno-stack-protector -fno-stack-clash-protection \
-fno-asynchronous-unwind-tables -fno-pic -mcmodel=large"

if [ ! -f "$KPIMG" ]; then
    info "Building kpimg with $CROSS"
    command -v "${CROSS}gcc" >/dev/null \
        || die "${CROSS}gcc not found. Install gcc-aarch64-linux-gnu, or set CROSS."
    ( cd "$KP_DIR/kernel" && \
      TARGET_COMPILE="$CROSS" ANDROID=1 \
      make -j"$(nproc)" "CFLAGS=$KP_CFLAGS" ) || die "kpimg build failed"
    [ -f "$KPIMG" ] || die "kpimg was not produced"
fi
info "kpimg: $(du -h "$KPIMG" | cut -f1)"

# --- 4. Check the Image actually supports KernelPatch ----------------------
#
# kpimg resolves kernel symbols by name at boot, so a kernel without kallsyms
# produces an image that patches fine and hangs later. Catch it here.
info "Checking KALLSYMS in the target Image"
KCFG="$OUT_DIR/.config"
if [ -f "$KCFG" ]; then
    grep -qE '^CONFIG_KALLSYMS=y' "$KCFG" \
        || die "CONFIG_KALLSYMS is not enabled; kpimg cannot resolve symbols."
    grep -qE '^CONFIG_KALLSYMS_ALL=y' "$KCFG" || \
        printf '[WARN] CONFIG_KALLSYMS_ALL is not enabled; only exported symbols will be resolvable\n'
else
    printf '[WARN] No %s, skipping the kallsyms check\n' "$KCFG"
fi

# --- 5. Patch --------------------------------------------------------------
mkdir -p "$(dirname "$OUT_IMAGE")"

info "Dumping kallsyms to confirm the Image is parseable"
"$KPT_TOOLS" -d -i "$IMAGE" >/dev/null 2>&1 \
    || die "kptools cannot read kallsyms from $IMAGE. A stripped or differently built Image will not work."

info "Patching $IMAGE"
# --skey-fd would be better than -s, but it needs the key on a file descriptor,
# and kptools reads it with read(2) on that fd. Here a private temp file stands
# in for the fd path so the key never enters argv.
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
chmod 600 "$KEY_FILE"
printf '%s' "$SUPERKEY" >"$KEY_FILE"

"$KPT_TOOLS" -p --skey-fd 3 -i "$IMAGE" -k "$KPIMG" -o "$OUT_IMAGE" 3<"$KEY_FILE" \
    || "$KPT_TOOLS" -p -s "$SUPERKEY" -i "$IMAGE" -k "$KPIMG" -o "$OUT_IMAGE" \
    || die "kptools failed to patch the Image"

[ -s "$OUT_IMAGE" ] || die "Patched image not produced"
[ "$(stat -c %s "$OUT_IMAGE")" -gt "$(stat -c %s "$IMAGE")" ] \
    || die "Patched image is not larger than the input; the payload was not appended"

info "Verifying the patch"
LISTING="$("$KPT_TOOLS" -l -i "$OUT_IMAGE")" || die "Cannot read patch metadata back"
printf '%s\n' "$LISTING" | grep -q 'patched=true' \
    || die "Patch metadata does not report patched=true"
printf '%s\n' "$LISTING" | grep -qi 'superkey' \
    || die "Patch metadata has no superkey field"

printf '%s\n' "$LISTING" | sed -n 's/^\(version\|arch\|patched\)=/\1=/p' | sed 's/^/  /'
info "Patched image: $OUT_IMAGE ($(du -h "$OUT_IMAGE" | cut -f1))"
info "Next: recompress and package with scripts/package-anykernel3.sh"
