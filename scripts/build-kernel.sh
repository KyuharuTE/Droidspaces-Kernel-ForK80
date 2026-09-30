#!/usr/bin/env bash
#
# Build a Droidspaces-capable, KernelSU-Next rooted Android GKI kernel.
#
# Target: Linux 6.1 (android14-6.1), arm64, KMI generation 11, zorn (Redmi K80).
#
# Design notes, each one learned the hard way:
#
# 1. Config goes in a fragment merged with merge_config.sh, never appended to
#    gki_defconfig. AOSP's check_defconfig runs savedefconfig and diffs the
#    result against gki_defconfig, and CONFIG_KSU is "default y" so
#    savedefconfig deletes it, guaranteeing a diff and a failed build. Raw
#    make never runs that check, and a fragment keeps gki_defconfig pristine.
#
# 2. CFI and LTO are left exactly as the tree set them. KernelSU handles KCFI
#    on 6.1 through symbol_resolver.c, and turning CFI off changes struct
#    layouts that the stock vendor modules were compiled against. Disabling it
#    would trade a working root for a bootloop.
#
# 3. Module signing is not touched. CONFIG_MODULE_SIG=y is fine because
#    CONFIG_MODULE_SIG_FORCE is unset, and this tree's own Kconfig makes
#    MODULE_SIG_PROTECT depend on !MODULE_SIG_FORCE.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

KERNEL_ROOT="${KERNEL_ROOT:-$PWD}"
OUT_DIR="${OUT_DIR:-$KERNEL_ROOT/out}"
CONFIG_FRAGMENT="${CONFIG_FRAGMENT:-}"

# Root solution: ksu-next | none
ROOT_SOLUTION="${ROOT_SOLUTION:-ksu-next}"
# KernelSU-Next has no "main" branch. "dev" is the default branch; "next" was
# renamed to "legacy". A wrong ref does NOT fail loudly because setup.sh ends in
# `git checkout "$1" || echo fallback`, so the ref is validated below instead.
KSU_REF="${KSU_REF:-dev}"

# The kABI patch is mandatory. Enabling SYSVIPC without it bootloops the device
# because task_struct offsets shift away from what the vendor modules expect.
APPLY_KABI_PATCH="${APPLY_KABI_PATCH:-1}"

RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

info() { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# Set a symbol in .config, whether it is currently "=y", "is not set", or
# absent. Appending is not enough on its own: a later definition in the same
# file wins, so an existing "is not set" has to be rewritten in place.
set_config() {
    local sym="$1" val="$2" file="$3"
    if grep -qE "^${sym}=" "$file"; then
        sed -i -E "s|^${sym}=.*|${sym}=${val}|" "$file"
    elif grep -qE "^# ${sym} is not set" "$file"; then
        sed -i -E "s|^# ${sym} is not set|${sym}=${val}|" "$file"
    else
        printf '%s=%s\n' "$sym" "$val" >> "$file"
    fi
}

cd "$KERNEL_ROOT"
[ -f Makefile ] && [ -d arch/arm64 ] || die "Not a kernel source root: $KERNEL_ROOT"
info "Kernel version: $(make kernelversion 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# 1. kABI patch.
# ---------------------------------------------------------------------------
if [ "$APPLY_KABI_PATCH" = "1" ]; then
    PATCH_FILE="${KABI_PATCH_FILE:-$RUNNER_TEMP/patches/001-gki-sysvipc-kabi.patch}"
    [ -f "$PATCH_FILE" ] || die "kABI patch not found at $PATCH_FILE"

    info "Applying SYSVIPC kABI patch"
    if git apply --check "$PATCH_FILE" 2>/dev/null; then
        git apply "$PATCH_FILE"
        info "Applied cleanly with git apply"
    elif patch -p1 --dry-run <"$PATCH_FILE" >/dev/null 2>&1; then
        patch -p1 <"$PATCH_FILE"
        info "Applied with patch(1)"
    else
        warn "Patch did not apply. Checking whether it is already present."
    fi

    grep -q 'ANDROID_KABI_USE(6, struct sysv_sem sysvsem)' include/linux/sched.h \
        || die "kABI patch is NOT in include/linux/sched.h. Refusing to enable SYSVIPC, this would bootloop the device."
    info "Verified: sysvsem/sysvshm now live in the KABI reserve slots"
fi

# ---------------------------------------------------------------------------
# 2. KernelSU-Next.
# ---------------------------------------------------------------------------
if [ "$ROOT_SOLUTION" = "ksu-next" ]; then
    SETUP_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/${KSU_REF}/kernel/setup.sh"
    info "Validating KernelSU-Next ref '$KSU_REF'"
    curl -LSsf -o "$RUNNER_TEMP/ksu-setup.sh" "$SETUP_URL" \
        || die "No setup.sh at ref '$KSU_REF'. KernelSU-Next uses 'dev', not 'main'."

    info "Installing KernelSU-Next ($KSU_REF)"
    [ -d KernelSU-Next ] || bash "$RUNNER_TEMP/ksu-setup.sh" "$KSU_REF" \
        || die "KernelSU-Next setup failed"

    # setup.sh checks common/drivers first (GKI 2.0 layout) and falls back to
    # drivers/. It symlinks drivers/kernelsu and edits drivers/Makefile and
    # drivers/Kconfig. Verify all three landed.
    [ -d KernelSU-Next ] || die "KernelSU-Next directory missing"
    [ -e drivers/kernelsu ] || die "drivers/kernelsu symlink missing"
    grep -q 'kernelsu' drivers/Makefile || die "drivers/Makefile not patched"
    grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || die "drivers/Kconfig not patched"
    info "KernelSU-Next wired into drivers/"
fi

# ---------------------------------------------------------------------------
# 3. Configure.
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
MAKE_COMMON=(
    -C "$KERNEL_ROOT"
    O="$OUT_DIR"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    HOSTCC=gcc
    HOSTCXX=g++
)

info "Generating .config from gki_defconfig"
make "${MAKE_COMMON[@]}" gki_defconfig || die "gki_defconfig failed"

if [ -n "$CONFIG_FRAGMENT" ]; then
    info "Merging Droidspaces fragment: $CONFIG_FRAGMENT"
    [ -f "$CONFIG_FRAGMENT" ] || die "Config fragment not found: $CONFIG_FRAGMENT"
    "$KERNEL_ROOT/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
        "$OUT_DIR/.config" "$CONFIG_FRAGMENT" >/dev/null || die "merge_config failed"
fi

# CONFIG_KSU depends on KPROBES && EXT4_FS, both already =y in GKI 6.1, and the
# symbol is "default y", so it enables itself. Set it explicitly anyway so the
# resulting .config can be read as a statement of intent.
if [ "$ROOT_SOLUTION" != "none" ]; then
    info "Enabling CONFIG_KSU"
    set_config CONFIG_KSU y "$OUT_DIR/.config"
fi

info "Resolving the config with olddefconfig"
make "${MAKE_COMMON[@]}" olddefconfig >/dev/null || die "olddefconfig failed"

# Surface any fragment symbol the tree does not know about, rather than
# silently shipping a kernel with the option missing.
if [ -n "$CONFIG_FRAGMENT" ]; then
    info "Checking every fragment symbol survived"
    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        if grep -qE "^${sym}=" "$OUT_DIR/.config"; then
            printf '  \033[1;32mset\033[0m   %s\n' "$sym"
        elif grep -qE "^# ${sym} is not set" "$OUT_DIR/.config"; then
            printf '  \033[1;33mn\033[0m     %s\n' "$sym"
        else
            printf '  \033[1;31mGONE\033[0m  %s\n' "$sym"
        fi
    done < <(grep -E '^CONFIG_[A-Z0-9_]+=' "$CONFIG_FRAGMENT" | sed -E 's/=.*//')
fi

# ---------------------------------------------------------------------------
# 4. Gate on the symbols Droidspaces actually probes at runtime. Building for
#    40 minutes to produce a kernel the app rejects is a waste of everyone's CI
#    minutes, so this fails before the compile starts.
# ---------------------------------------------------------------------------
info "Verifying Droidspaces requirements"
FAILED=0
check_y() {
    local sym="$1" desc="$2"
    if grep -qE "^${sym}=y" "$OUT_DIR/.config"; then
        printf '  \033[1;32mOK\033[0m      %-34s %s\n' "$sym" "$desc"
    else
        printf '  \033[1;31mMISSING\033[0m %-34s %s\n' "$sym" "$desc"
        FAILED=1
    fi
}

check_y CONFIG_SYSVIPC     "IPC namespace depends on it (FATAL)"
check_y CONFIG_IPC_NS      "containers cannot start without it"
check_y CONFIG_PID_NS      "containers cannot start without it"
check_y CONFIG_UTS_NS      "containers cannot start without it"
check_y CONFIG_NAMESPACES  "containers cannot start without it"
check_y CONFIG_DEVTMPFS    "Droidspaces sets up /dev from this"
check_y CONFIG_CGROUPS     "container resource isolation"
check_y CONFIG_EXT4_FS     "KernelSU depends on it"
check_y CONFIG_KPROBES     "KernelSU depends on it"
[ "$ROOT_SOLUTION" != "none" ] && check_y CONFIG_KSU "KernelSU"

[ "$FAILED" = "0" ] || die "Required symbols missing. Not wasting CI time on this build."

info "Optional symbols (report only)"
for sym in CONFIG_USER_NS CONFIG_OVERLAY_FS CONFIG_NET_NS CONFIG_VETH \
           CONFIG_BRIDGE CONFIG_SECCOMP CONFIG_SECCOMP_FILTER \
           CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_TMPFS_POSIX_ACL \
           CONFIG_TMPFS_XATTR CONFIG_CFI_CLANG CONFIG_MODULE_SIG_FORCE; do
    if grep -qE "^${sym}=y" "$OUT_DIR/.config"; then
        printf '  \033[1;32mon\033[0m      %s\n' "$sym"
    else
        printf '  \033[1;33moff\033[0m     %s\n' "$sym"
    fi
done
grep -qE '^CONFIG_MODULE_SIG_FORCE=y' "$OUT_DIR/.config" \
    && warn "MODULE_SIG_FORCE is on, stock vendor modules will not load"

# ---------------------------------------------------------------------------
# 5. Build.
# ---------------------------------------------------------------------------
info "Compiling with $(nproc) jobs"
make "${MAKE_COMMON[@]}" -j"$(nproc)" Image || die "Kernel build failed"

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "Image not produced at $IMAGE"

printf '%s\n' "$IMAGE" >"$RUNNER_TEMP/image-path.txt"
info "Built $(du -h "$IMAGE" | cut -f1) Image at $IMAGE"
