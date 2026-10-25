#!/usr/bin/env bash
#
# Build a Droidspaces-capable Android GKI kernel without an integrated root driver.
#
# Target: Linux 6.1 (android14-6.1), arm64, KMI generation 11, zorn (Redmi K80).
#
# Config is merged from a fragment to keep gki_defconfig unchanged. CFI and
# LTO retain the source tree defaults; module signing is configured below.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

KERNEL_ROOT="${KERNEL_ROOT:-$PWD}"
OUT_DIR="${OUT_DIR:-$KERNEL_ROOT/out}"
CONFIG_FRAGMENT="${CONFIG_FRAGMENT:-}"

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
# 1. Confirm the kABI patch is in place.
#
# Applying it is a separate step (scripts/fix-tree.py) because the
# upstream static variants do not match this tree. By the time we get here it
# must already be applied, and we verify rather than re-apply, so a missing
# patch fails here instead of after a 40 minute build.
# ---------------------------------------------------------------------------
info "Verifying the SYSVIPC kABI patch is present"
if grep -qE 'ANDROID_KABI_USE\([0-9]+, struct sysv_sem sysvsem\)' include/linux/sched.h; then
    info "sysvsem/sysvshm are in the ABI reserve slots"
elif grep -qE '^\s*struct\s+sysv_sem\s+sysvsem\s*;' include/linux/sched.h; then
    die "The kABI patch is NOT applied and sysvsem is still a plain task_struct field. Enabling CONFIG_SYSVIPC now would shift struct offsets and bootloop the device on the stock vendor modules. Run scripts/fix-tree.py first."
else
    info "No unconditional sysvsem field found; assuming the patch is applied or the tree differs"
fi

# ---------------------------------------------------------------------------
# 2. Reject cached source trees that still integrate KernelSU.
# ---------------------------------------------------------------------------
if [ -e drivers/kernelsu ] || [ -L drivers/kernelsu ] || \
   grep -qi 'kernelsu' drivers/Makefile drivers/Kconfig; then
    die "KernelSU is still integrated in this source tree. Remove its driver and Kconfig/Makefile entries before building."
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

# Module signing is turned off, for two independent reasons.
#
# 1. It does not build here. certs/extract-cert.c fails against OpenSSL 3.x with
#    "'key_pass' undeclared", which is a known break in these trees and kills
#    the build at the signing step, ~40 minutes in.
# 2. It is not needed, and disabling it is what lets the stock vendor modules
#    load. CONFIG_MODULE_SIG_PROTECT (set by this tree) already hardcodes
#    sig_enforce to false, and the separate protected-exports allowlist that
#    rejects modules with -EACCES depends on MODULE_SIG, so turning MODULE_SIG
#    off removes that rejection path as well.
info "Disabling module signing"
for sym in CONFIG_MODULE_SIG CONFIG_MODULE_SIG_ALL CONFIG_MODULE_SIG_FORCE \
           CONFIG_MODULE_SIG_SHA1 CONFIG_MODULE_SIG_SHA224 CONFIG_MODULE_SIG_SHA256 \
           CONFIG_MODULE_SIG_SHA384 CONFIG_MODULE_SIG_SHA512 \
           CONFIG_MODULE_SIG_KEY_TYPE_RSA CONFIG_MODULE_SIG_KEY_TYPE_ECDSA \
           CONFIG_MODULE_SIG_PROTECT CONFIG_SYSTEM_TRUSTED_KEYRING \
           CONFIG_SECONDARY_TRUSTED_KEYRING CONFIG_SYSTEM_BLACKLIST_KEYRING; do
    set_config "$sym" n "$OUT_DIR/.config"
done

info "Resolving the config with olddefconfig"
make "${MAKE_COMMON[@]}" olddefconfig >/dev/null || die "olddefconfig failed"
if grep -qE '^CONFIG_KSU[A-Z0-9_]*=(y|m)$' "$OUT_DIR/.config"; then
    die "KernelSU options must not be enabled in this build"
fi

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
#    40 minutes to produce a kernel the app rejects wastes build time, so this
#    fails before the compile starts.
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
[ "$FAILED" = "0" ] || die "Required symbols missing. Stopping before compilation."

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
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be a positive integer"
info "Compiling with $BUILD_JOBS jobs"
make "${MAKE_COMMON[@]}" -j"$BUILD_JOBS" Image || die "Kernel build failed"

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "Image not produced at $IMAGE"

printf '%s\n' "$IMAGE" >"$RUNNER_TEMP/image-path.txt"
info "Built $(du -h "$IMAGE" | cut -f1) Image at $IMAGE"
