#!/usr/bin/env bash
#
# Build a kernel that can load .kpm modules, and hand back a patched Image.
#
# This is the kpimg route: compile normally, then have kptools append the
# KernelPatch payload to the finished Image and redirect primary_entry to it.
#
# Why not compile KernelPatch into the kernel instead
# ---------------------------------------------------
# That was tried and it bootlooped on the first screen. The vendored `lkm/` tree
# is a skeleton, not a deliverable: its own README lists the inline-hook infra
# and sucompat as unimplemented, and it is written to be insmod'd into a running
# system. As an initcall it runs during early boot, where it hooks the syscall
# table and LSM before /data exists and before the executable-memory allocator it
# needs is ready. Spreading that code into vmlinux also drags in the image-patch
# hook engine without the base/ runtime that engine expects.
#
# kpimg exists for exactly this job, and it runs at the point the kernel is ready
# for it, not at initcall time.
#
# Requirements on the Image, checked rather than assumed:
#   CONFIG_KALLSYMS=y     kpimg resolves kernel functions by name at boot
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_ROOT="${KERNEL_ROOT:-$REPO_ROOT/kernel}"
OUT_DIR="${OUT_DIR:-$KERNEL_ROOT/out}"
SUPERKEY="${SUPERKEY:-}"
KP_DIR="${KP_DIR:-$REPO_ROOT/.kp/KernelPatch}"
KP_REF="${KP_REF:-main}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
OUT_IMAGE="${OUT_IMAGE:-$REPO_ROOT/dist/Image.kpm}"

info() { printf '\n[INFO] %s\n' "$*"; }
die()  { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

[ -f "$KERNEL_ROOT/Makefile" ] || die "no kernel source at $KERNEL_ROOT"
[ -n "$SUPERKEY" ] || die "SUPERKEY is not set; it is compiled into the payload"
[ "${#SUPERKEY}" -le 64 ] || die "SUPERKEY exceeds the 64-byte KernelPatch limit"

MAKE_ARGS=(-C "$KERNEL_ROOT" O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 HOSTCC=gcc)

# --- 1. Kernel ------------------------------------------------------------
#
# build-kernel.sh owns the config work: it applies the Droidspaces fragment,
# checks every symbol Droidspaces probes at runtime, and gates the build on them.
# Doing it here as well would risk the two drifting apart, which is how the
# bootlooping kernel ended up with module signing on again.
info "Configuring and compiling the kernel"
KERNEL_ROOT="$KERNEL_ROOT" OUT_DIR="$OUT_DIR" \
CONFIG_FRAGMENT="$REPO_ROOT/kernel-configs/droidspaces-gki.config" \
    bash "$REPO_ROOT/scripts/build-kernel.sh" || die "kernel build failed"

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "no Image at $IMAGE"

grep -qE '^CONFIG_KALLSYMS=y' "$OUT_DIR/.config" \
    || die "CONFIG_KALLSYMS is off; kpimg cannot resolve symbols and the kernel will hang"

# --- 2. KernelPatch host tool and payload ---------------------------------
if [ ! -d "$KP_DIR/.git" ]; then
    info "Cloning KernelPatch into $KP_DIR"
    mkdir -p "$(dirname "$KP_DIR")"
    git clone --depth 1 --branch "$KP_REF" \
        https://github.com/bmax121/KernelPatch.git "$KP_DIR" || die "clone failed"
fi

KPT="$KP_DIR/tools/kptools"
KPIMG="$KP_DIR/kernel/kpimg"

if [ ! -x "$KPT" ]; then
    info "Building kptools"
    command -v cc >/dev/null || die "no host C compiler for kptools"
    ( cd "$KP_DIR/tools" && ANDROID=1 make -j"$(nproc)" ) || die "kptools build failed"
fi

# The payload is freestanding, and modern distro GCC turns on the stack protector
# and PIC by default, so the link fails with __stack_chk_guard and GOT/PLT
# entries. Command line CFLAGS beats the Makefile's +=, which is what lets the
# defaults be turned back off.
KP_CFLAGS="-Wall -fno-builtin -std=gnu11 -nostdinc -mgeneral-regs-only \
-ffixed-x18 -fno-stack-protector -fno-stack-clash-protection \
-fno-asynchronous-unwind-tables -fno-pic -mcmodel=large"

if [ ! -f "$KPIMG" ]; then
    info "Building kpimg with $CROSS"
    command -v "${CROSS}gcc" >/dev/null \
        || die "${CROSS}gcc not found; install gcc-aarch64-linux-gnu or set CROSS"
    ( cd "$KP_DIR/kernel" && TARGET_COMPILE="$CROSS" ANDROID=1 \
      make -j"$(nproc)" "CFLAGS=$KP_CFLAGS" ) || die "kpimg build failed"
fi
info "kpimg: $(du -h "$KPIMG" | cut -f1)"

# --- 3. Patch -------------------------------------------------------------
mkdir -p "$(dirname "$OUT_IMAGE")"

info "Confirming kptools can read kallsyms from the Image"
"$KPT" -d -i "$IMAGE" >/dev/null 2>&1 \
    || die "kptools cannot parse $IMAGE; a stripped Image will not work"

# The key goes in over a file descriptor so it stays out of the process list.
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
chmod 600 "$KEY_FILE"
printf '%s' "$SUPERKEY" >"$KEY_FILE"

info "Patching the Image with kpimg"
"$KPT" -p --skey-fd 3 -i "$IMAGE" -k "$KPIMG" -o "$OUT_IMAGE" 3<"$KEY_FILE" \
    || "$KPT" -p -s "$SUPERKEY" -i "$IMAGE" -k "$KPIMG" -o "$OUT_IMAGE" \
    || die "kptools failed to patch the Image"

LISTING="$("$KPT" -l -i "$OUT_IMAGE")" || die "cannot read the patch metadata back"
printf '%s\n' "$LISTING" | grep -q 'patched=true' || die "patch did not take"
printf '%s\n' "$LISTING" | sed -n 's/^\(version\|arch\)=/  \1=/p'

info "Patched image: $OUT_IMAGE ($(du -h "$OUT_IMAGE" | cut -f1))"
info "Package it with scripts/package-anykernel3.sh, IMAGE=$OUT_IMAGE"
