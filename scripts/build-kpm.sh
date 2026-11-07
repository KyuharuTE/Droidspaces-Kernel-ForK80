#!/usr/bin/env bash
#
# Build a .kpm module from a source directory.
#
# A .kpm is not a kernel module and not a shared object: it is an arm64 ELF
# relocatable object (ET_REL), produced with `gcc -r`, that the KernelPatch
# runtime maps into kernel space and relocates itself. Undefined symbols are
# resolved against the running kernel's kallsyms at load time, which is why a
# KPM has no vermagic, no MODULE_SIG requirement and no CONFIG_MODULES
# dependency.
#
# The module must provide .kpm.init and .kpm.exit (the loader refuses to load a
# module without them) plus .kpm.info, which the KPM_* macros emit.
#
# Usage:
#   scripts/build-kpm.sh <source-dir> [output.kpm]
#
# The source dir needs a .c file and, optionally, a .lds. A minimal module:
#
#   #include <compiler.h>
#   #include <kpmodule.h>
#   #include <linux/printk.h>
#
#   KPM_NAME("my-module");
#   KPM_VERSION("1.0.0");
#   KPM_LICENSE("GPL v2");
#   KPM_AUTHOR("you");
#   KPM_DESCRIPTION("what it does");
#
#   static long my_init(const char *args, const char *event, void *__user reserved) {
#       pr_info("my-module: init event=%s args=%s\n", event, args);
#       return 0;
#   }
#   static long my_exit(void *__user reserved) { return 0; }
#   KPM_INIT(my_init);
#   KPM_EXIT(my_exit);
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KP_DIR="${KP_DIR:-$REPO_ROOT/.kp/KernelPatch}"
KP_REF="${KP_REF:-main}"
CROSS="${CROSS:-aarch64-linux-gnu-}"

SRC_DIR="${1:?usage: $0 <source-dir> [output.kpm]}"
SRC_DIR="$(cd "$SRC_DIR" && pwd)"

info() { printf '\n[INFO] %s\n' "$*"; }
die()  { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

# --- KernelPatch headers ----------------------------------------------------
if [ ! -d "$KP_DIR/.git" ]; then
    info "Cloning KernelPatch into $KP_DIR"
    mkdir -p "$(dirname "$KP_DIR")"
    git clone --depth 1 --branch "$KP_REF" \
        https://github.com/bmax121/KernelPatch.git "$KP_DIR" \
        || die "KernelPatch clone failed"
fi

command -v "${CROSS}gcc" >/dev/null \
    || die "${CROSS}gcc not found. Install gcc-aarch64-linux-gnu, or set CROSS."

# --- Sources ---------------------------------------------------------------
mapfile -t CSRC < <(find "$SRC_DIR" -maxdepth 1 -name '*.c' -type f | sort)
[ "${#CSRC[@]}" -gt 0 ] || die "No .c file in $SRC_DIR"

MODULE_NAME="$(basename "$SRC_DIR")"
OUT="${2:-$REPO_ROOT/dist/kpm/$MODULE_NAME.kpm}"
BUILD_DIR="$SRC_DIR/.build"
mkdir -p "$BUILD_DIR" "$(dirname "$OUT")"

# A module that declares .init.plt or .text.ftrace_trampoline would otherwise
# pull in a PLT the loader does not provide, so the section is zeroed by the
# linker script instead.
LDS="$SRC_DIR/module.lds"
if [ ! -f "$LDS" ]; then
    LDS="$BUILD_DIR/module.lds"
    cat >"$LDS" <<'EOF'
SECTIONS {
    .plt (NOLOAD) : { BYTE(0) }
    .init.plt (NOLOAD) : { BYTE(0) }
    .text.ftrace_trampoline (NOLOAD) : { BYTE(0) }
}
EOF
fi

# Header layout mirrors kpms/*/Makefile. -nostdinc because KPMs use the kernel's
# own headers, not the C library's.
INCLUDES=(
    -I"$SRC_DIR"
    -I"$KP_DIR/kernel/."
    -I"$KP_DIR/kernel/include"
    -I"$KP_DIR/kernel/patch/include"
    -I"$KP_DIR/kernel/linux/include"
    -I"$KP_DIR/kernel/linux/arch/arm64/include"
    -I"$KP_DIR/kernel/linux/tools/arch/arm64/include"
)

# No PIC, no PIE, no stack protector, no unwind tables: the object is relocated
# by hand into kernel memory and none of that machinery exists there.
CFLAGS=(
    -nostdinc
    -fno-pic -fno-PIC -fno-pie
    -fno-stack-protector
    -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-exceptions
    -O2
)

info "Building $MODULE_NAME from $SRC_DIR"
OBJS=()
for src in "${CSRC[@]}"; do
    obj="$BUILD_DIR/$(basename "${src%.c}").o"
    "${CROSS}gcc" "${CFLAGS[@]}" "${INCLUDES[@]}" -T"$LDS" -c -o "$obj" "$src" \
        || die "compiling $(basename "$src") failed"
    OBJS+=("$obj")
done

# -r: relocatable, so the sections and relocation entries survive for the loader.
"${CROSS}gcc" -r -o "$OUT" "${OBJS[@]}" || die "link failed"

# --- Verify ----------------------------------------------------------------
[ -s "$OUT" ] || die "no output produced"

if ! "${CROSS}readelf" -h "$OUT" | grep -q 'REL (Relocatable)'; then
    die "$OUT is not an ET_REL relocatable object"
fi
for section in .kpm.info .kpm.init .kpm.exit; do
    "${CROSS}readelf" -S "$OUT" | grep -q "$section" \
        || die "$OUT is missing $section; the loader will reject it"
done

# If kptools is available it can print the metadata the loader will read.
KPT="$KP_DIR/tools/kptools"
if [ -x "$KPT" ]; then
    info "Module metadata"
    "$KPT" -l -M "$OUT" 2>/dev/null | sed 's/^/  /' || true
fi

info "Built $OUT ($(du -h "$OUT" | cut -f1))"
info "Install it on the device, then load it from the manager app."
