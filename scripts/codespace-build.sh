#!/usr/bin/env bash
# Prepare a Codespace once, then rebuild and package the kernel in place.
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_ROOT="${KERNEL_ROOT:-$REPO_ROOT/kernel}"
# Keep both objects and downloaded tools under the workspace. /tmp is cleared
# when a Codespace stops; the home directory is reset on container rebuilds.
CACHE_DIR="${CACHE_DIR:-$REPO_ROOT/.cache/droidspaces}"
OUT_DIR="${OUT_DIR:-$CACHE_DIR/out}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$CACHE_DIR/clang-r487747c}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/cnmrlin/android_kernel_xiaomi_sm8650.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-24.0}"
CLANG_VERSION=r487747c
RUNNER_TEMP="${RUNNER_TEMP:-/tmp/droidspaces-build}"
IMAGE="$OUT_DIR/arch/arm64/boot/Image"
OUT_ZIP="$REPO_ROOT/dist/AnyKernel3_zorn_droidspaces.zip"

info() { printf '[codespace] %s\n' "$*"; }
die() { printf '[codespace] ERROR: %s\n' "$*" >&2; exit 1; }

dependencies() {
    sudo apt-get update
    sudo apt-get install -y \
        build-essential bc bison flex patch pkg-config git curl tar xz-utils \
        zip unzip cpio rsync kmod perl python3 python-is-python3 \
        libssl-dev libelf-dev libncurses-dev zlib1g-dev libyaml-dev \
        lz4 zstd device-tree-compiler dwarves
    pahole --version
}

toolchain() {
    if [ -x "$TOOLCHAIN_DIR/bin/clang" ]; then
        info "Using cached $TOOLCHAIN_DIR/bin/clang"
        return
    fi
    mkdir -p "$(dirname "$TOOLCHAIN_DIR")" "$RUNNER_TEMP"
    local work ref url
    work="$(mktemp -d "$RUNNER_TEMP/clang.XXXXXXXX")"
    for ref in main-kernel-build-2023 main-kernel-build-2024; do
        url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/$ref/clang-$CLANG_VERSION.tar.gz"
        info "Fetching clang-$CLANG_VERSION from $ref"
        if curl -LSsf --retry 3 -o "$work/clang.tar.gz" "$url" && \
           tar -tzf "$work/clang.tar.gz" >/dev/null 2>&1; then
            break
        fi
        rm -f "$work/clang.tar.gz"
    done
    [ -f "$work/clang.tar.gz" ] || die "Could not download clang-$CLANG_VERSION"
    mkdir -p "$work/clang"
    tar -xzf "$work/clang.tar.gz" -C "$work/clang"
    [ -x "$work/clang/bin/clang" ] || die "Clang archive has no executable"
    mv "$work/clang" "$TOOLCHAIN_DIR"
    rm -rf "$work"
    "$TOOLCHAIN_DIR/bin/clang" --version | head -1
}

source_tree() {
    if [ ! -d "$KERNEL_ROOT/.git" ]; then
        [ ! -e "$KERNEL_ROOT" ] || die "$KERNEL_ROOT exists but is not a Git checkout"
        info "Cloning kernel source into $KERNEL_ROOT"
        git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_ROOT"
    fi
    [ -f "$KERNEL_ROOT/Makefile" ] || die "No kernel Makefile in $KERNEL_ROOT"
    local version
    version="$(make -s -C "$KERNEL_ROOT" kernelversion)"
    [[ "$version" == 6.1.* ]] || die "Expected Linux 6.1 source, found $version"
    info "Kernel source: $version"
}

prepare() {
    source_tree
    python3 "$REPO_ROOT/scripts/fix-tree.py" "$KERNEL_ROOT"
}

preflight() {
    [ -x "$TOOLCHAIN_DIR/bin/clang" ] || die "Run: bash scripts/codespace-build.sh setup"
    [ -d "$KERNEL_ROOT/.git" ] || die "Run: bash scripts/codespace-build.sh setup"
    for command in make gcc pahole flex bc cpio dtc zip; do
        command -v "$command" >/dev/null || die "Missing $command; run setup"
    done
    mkdir -p "$OUT_DIR" "$RUNNER_TEMP"
    info "Build storage: $(df -h "$OUT_DIR" | tail -1)"
}

build() {
    preflight
    prepare
    export PATH="$TOOLCHAIN_DIR/bin:$PATH"
    info "Building into $OUT_DIR; existing objects will be reused"
    KERNEL_ROOT="$KERNEL_ROOT" OUT_DIR="$OUT_DIR" \
        CONFIG_FRAGMENT="$REPO_ROOT/kernel-configs/droidspaces-gki.config" \
        RUNNER_TEMP="$RUNNER_TEMP" \
        bash "$REPO_ROOT/scripts/build-kernel.sh"
}

package() {
    [ -f "$IMAGE" ] || die "No built Image at $IMAGE; run build first"
    mkdir -p "$RUNNER_TEMP"
    IMAGE="$IMAGE" OUT_ZIP="$OUT_ZIP" DEVICE_CODENAME=zorn \
        KERNEL_STRING="Droidspaces (6.1)" \
        RUNNER_TEMP="$RUNNER_TEMP" \
        bash "$REPO_ROOT/scripts/package-anykernel3.sh"
}

check() {
    [ -s "$IMAGE" ] || die "Missing kernel Image: $IMAGE"
    [ -s "$OUT_ZIP" ] || die "Missing AnyKernel3 zip: $OUT_ZIP"
    [ -s "$OUT_DIR/.config" ] || die "Missing resolved kernel config"
    for symbol in CONFIG_SYSVIPC CONFIG_IPC_NS CONFIG_PID_NS CONFIG_UTS_NS \
                  CONFIG_NAMESPACES CONFIG_DEVTMPFS CONFIG_CGROUPS; do
        grep -qx "$symbol=y" "$OUT_DIR/.config" || die "$symbol is not enabled"
    done
    if grep -qE '^CONFIG_KSU[A-Z0-9_]*=(y|m)$' "$OUT_DIR/.config"; then
        die "KernelSU must not be enabled"
    fi
    unzip -tq "$OUT_ZIP" >/dev/null || die "Package is corrupt"
    unzip -Z1 "$OUT_ZIP" | grep -qx 'Image.gz' || die "Package lacks Image.gz"
    if ! unzip -p "$OUT_ZIP" Image.gz | gzip -dc | cmp -s "$IMAGE" -; then
        die "Packaged kernel differs from the built Image; run package again"
    fi
    info "Image: $IMAGE"
    info "Package: $OUT_ZIP"
    info "Config and archive checks passed"
}

case "${1:-}" in
    setup) dependencies; toolchain; prepare ;;
    build) build ;;
    package) package ;;
    check) check ;;
    all) dependencies; toolchain; build; package; check ;;
    *) die "Usage: bash scripts/codespace-build.sh {setup|build|package|check|all}" ;;
esac
