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
OUT_DIR="${OUT_DIR:-${CACHE_DIR:-$REPO_ROOT/.cache/droidspaces}/out}"
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

# Use one payload builder and patch verifier for both entry points. In
# particular, never reuse a cached payload compiled with the large code model.
KERNEL_ROOT="$KERNEL_ROOT" OUT_DIR="$OUT_DIR" IMAGE="$IMAGE" \
OUT_IMAGE="$OUT_IMAGE" KP_DIR="$KP_DIR" KP_REF="$KP_REF" \
CROSS="$CROSS" SUPERKEY="$SUPERKEY" \
    bash "$REPO_ROOT/scripts/kpm-patch-image.sh"
