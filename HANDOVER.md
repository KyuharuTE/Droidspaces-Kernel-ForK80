# Handover

State of this project as of 2026-11-08, written after KernelPatch was found not
to boot on this device. Everything below is either verified on the device or
verified in the build; where it is neither, it says so.

## TL;DR

- **Works**: a GKI 6.1 kernel for `zorn` with the Droidspaces container runtime
  support. It boots, confirmed by flashing.
- **Does not work**: KernelPatch, and therefore `.kpm` module loading. Three
  builds were flashed and all three failed to reach the boot animation. The
  kernel without KernelPatch boots from the same source and config.
- **Built but unproven**: the KPM Manager Android app. It compiles and the
  published APK is intact, but it has never talked to a working KPM kernel,
  because there has never been one.

If you only want working containers on this device, use the `base` zip and stop
reading. The rest is the KernelPatch investigation.

## Target

| | |
| --- | --- |
| Device | Redmi K80 / POCO F7 Pro, codename `zorn` |
| Reported kernel | `6.1.157-android14-11-g2de7246565ac-mi` |
| Kernel built here | `6.1.176-android14-11-<git describe>-nbkernel` |
| ABI | arm64, KMI generation 11 |
| Source tree | `cnmrlin/android_kernel_xiaomi_sm8650`, branch `lineage-24.0` |

Two things about the target were never independently confirmed and both matter:

1. **`uname -r` was never captured from the device.** The device identity was
   inferred from the version string and the project's own name. The string is
   consistent with `zorn` on a 6.1 kernel, but a wrong device means every flash
   is a brick risk.
2. **The ROM was never established.** The requested answer was "don't worry
   about it". `cnmrlin` is a LineageOS tree; the vendor modules on a stock
   HyperOS install are what the kABI work protects, but a ROM mismatch is a
   variable nobody eliminated.

The `-nbkernel` suffix exists so a custom build is identifiable in `uname -r`.
It is appended by `scripts/fix-tree.py`, which edits `scripts/setlocalversion`.
`same_magic()` skips the version-string portion of vermagic when CRCs are
present, so the suffix does not break the stock vendor modules.

## Repository

```
kernel-configs/droidspaces-gki.config   the config fragment; read its comments
scripts/fix-tree.py                     kABI patch + -nbkernel + extract-cert fix
scripts/build-kernel.sh                 configure, gate on symbols, compile
scripts/package-anykernel3.sh           Image -> flashable AnyKernel3 zip
scripts/codespace-build.sh              Codespace setup / build / package / check
scripts/build-kpm.sh                    build a .kpm from a source dir
scripts/kpm-integrated-build.sh         build + append the KernelPatch payload
scripts/kpm-patch-image.sh              append the payload to an existing Image
scripts/vendor-kpatch.py                in-tree KernelPatch (EXPERIMENT, see below)
kpms/nbdemo/                            minimal example .kpm
manager/                                Android manager app (Compose + native CLI)
.github/workflows/                      manual CI build, publish-only workflow
```

## The kernel build

### Config fragment, not `gki_defconfig`

AOSP's `build.config.gki` runs `POST_DEFCONFIG_CMDS="check_defconfig"`, which
runs `make savedefconfig` and diffs the result against `gki_defconfig`;
`scripts/kconfig/confdata.c` skips any symbol whose value equals its default, so
a would-be-appended `CONFIG_KSU=y` is deleted and the diff fails the build. Raw
`make` never runs that check, and a fragment keeps `gki_defconfig` pristine.

### The kABI patch, and why it is mandatory

Droidspaces needs `CONFIG_SYSVIPC` and `CONFIG_IPC_NS`. Enabling them naively
moves fields inside `struct task_struct`, which shifts offsets the stock vendor
modules were compiled against, and the device bootloops on the GPU or camera
module initialising.

`scripts/fix-tree.py` parks `sysvsem`/`sysvshm` in the `ANDROID_KABI_RESERVE`
slots instead, so no offset moves. Upstream ships three static variants and all
three fail on this tree, for two independent reasons:

- the tree already uses reserve slots 1, 2 and 3 (`saved_state`,
  `task_dma_buf_info`, an anonymous struct), so the free run starts at 4;
- the hunk context does not match either: the tree has `union rv_task_monitor`
  and an `#endif` immediately before the reserve slots.

So the script scans which slots are free and rewrites the lines by anchor. It
refuses to continue if it cannot verify the result. The observed outcome is
slots 6/7/8 in use.

### Three config traps, in the order they bit

1. **`CONFIG_MODULE_SIG_PROTECT`.** Turning this on (its default in GKI) enables
   the protected-exports allowlist. The list is generated from the build config,
   so a kernel built with a different config than stock produces a different
   list, and the stock vendor modules start failing to load with `-EACCES`. The
   fragment turns `CONFIG_MODULE_SIG` off, which removes the allowlist with it.
   This was lost once by reconfiguring by hand instead of through
   `build-kernel.sh`, and cost a flash.
2. **`CONFIG_CFI_CLANG=n` breaks module loading.** `lib/cfi.c` is only built when
   CFI is on, so `__cfi_slowpath` stops existing, and the stock vendor modules
   reference it. They fail to load with an unknown symbol. CFI must stay at the
   tree default. This cost a flash.
3. **`certs/extract-cert.c` does not build against OpenSSL 3.x.** Its
   `key_pass` declaration is guarded by `USE_PKCS11_ENGINE` but the use is
   guarded only by `OPENSSL_IS_BORINGSSL`, so the block is half-compiled. And
   `certs/Makefile` has an unconditional `hostprogs := extract-cert`, so
   disabling module signing does not avoid it. `fix-tree.py` turns the `#else`
   into `#elif defined(USE_PKCS11_ENGINE)` and verifies with a real preprocessor
   run, because a textual check passed even with the condition inverted.

The lesson from 1 and 2: change one variable at a time, and anchor the config to
something already proven to boot.

### Config that the running kernel has

```
CONFIG_SYSVIPC=y  CONFIG_IPC_NS=y  CONFIG_PID_NS=y  CONFIG_UTS_NS=y
CONFIG_NAMESPACES=y  CONFIG_DEVTMPFS=y  CONFIG_CGROUPS=y
CONFIG_USER_NS=y  CONFIG_OVERLAY_FS=y  CONFIG_NET_NS=y
CONFIG_VETH=y  CONFIG_BRIDGE=y  CONFIG_KALLSYMS=y  CONFIG_KALLSYMS_ALL=y
# CONFIG_MODULE_SIG is not set
CONFIG_CFI_CLANG=y            (tree default, do not disable)
CONFIG_SHADOW_CALL_STACK=y    (tree default, do not disable)
```

## KernelPatch: tried and failed

KernelPatch is what provides `.kpm` loading. It is not a config option; there are
two delivery mechanisms, and both were tried.

### Attempt 1: vendor the LKM sources in-tree (`scripts/vendor-kpatch.py`)

`bmax121/KernelPatch`'s `lkm/` tree is ordinary Kbuild objects with a KPM loader
(`kpm/module.c`, `relo.c`, `insn.c`, `symbols.c`). It was vendored into
`drivers/kpatch` and built with `CONFIG_KP_LKM=y`.

Result: **bootlooped on the first screen**, while the same kernel without it
booted. Cause, visible in upstream's own `lkm/README.md`: the tree is a skeleton
("Not implemented yet: ... inline-hook infra, ksucompat"), designed to be
`insmod`'d into a running system, not to run as an initcall. As a builtin,
`kernelpatch_init` runs at `device_initcall` and calls `kp_manager_init()` against
`/data` before it is mounted, hooks the rename LSM hook, and drags in the
image-patch hook engine without the `base/` runtime that engine expects.

Incidental problems solved along the way, in case the route is revived:
- upstream authenticates by trusted-manager UID (APatch APK certificate); the
  script replaces that with a compiled-in superkey
- `hook/hook_engine.c` `#include`s `../../kernel/base/hook.c`, so `kernel/base/`
  must be vendored too
- the GitHub contents API rate-limits at 60 requests/hour and this tree needs
  >140, so vendoring must use a single shallow clone
- `modules` collides with `kernel/module/main.c`, and `sha256_*` with
  `lib/crypto/sha256.c`; the vendored copies need renaming, including the header
  and the caller in `manager/apk_sign.c`

### Attempt 2: kpimg payload, with CFI and SCS disabled

`kptools` appends `kpimg` to the finished `Image`, bumps `image_size`, and
redirects the entry branch. This is the mechanism KernelPatch is built and
tested around.

Result: **stuck on the first screen** (not a reboot). This one was self-inflicted:
`CONFIG_CFI_CLANG` and `CONFIG_SHADOW_CALL_STACK` had also been disabled "for
safety", which is what breaks vendor module loading. See trap 2 above.

### Attempt 3: kpimg payload, CFI restored to tree default

Same as the booting baseline in every respect except the appended payload.

Result: **still stuck on the first screen.** This is the informative failure:
the only remaining difference from a kernel that boots is KernelPatch itself.

Both KernelPatch 0.13.9 and 0.12.2 payloads were tried. Structural check on the
patched Images:

```
BASE       entry branch 0x1470a934   image_size 36,634,624
KP-0.13.9  entry branch 0x148907ff   image_size 36,999,168   bumped by the payload
KP-0.12.2  entry branch 0x148907ff   image_size 36,634,624   NOT bumped
```

`image_size` is what the bootloader uses to decide how much to load. 0.12.2's
`kptools` does not grow it (upstream added that in 0.13.x), so its payload can
fall outside the loaded region. 0.13.9 does grow it, so its payload should be
present. Neither boots.

### Conclusion

KernelPatch is not compatible with this kernel as built. The evidence does not
distinguish between "this tree" and "this device", because the device was never
independently identified. Before spending more flashes:

- confirm `uname -r` on the device and confirm the ROM
- if the goal is only Droidspaces, drop KernelPatch
- if KPM is required, the honest options are: build from the official
  `MiCode` zorn tree instead of the LineageOS one, or use a kernel/ROM
  combination that KernelPatch users report working

## No logs were obtainable

`kpimg` takes over at `primary_entry`, before any console, `pstore` or logging
backend exists, so a failure there leaves no software trace. `PSTORE_RAM` and
`PSTORE_CONSOLE` are enabled in the kernel, so a failure occurring *after* pstore
init would be readable. It never was, which is itself consistent with a failure
before that point.

If this is picked up again, the only way to see an early failure is a UART
console, which needs hardware access. The alternative is to stop patching the
entry point and load KernelPatch as a module after boot, accepting a manual
`insmod` per boot.

## The manager app

`manager/` is a Compose app that loads, unloads, lists and controls `.kpm`
modules. It builds against SDK 36, `minSdk` 26, arm64-v8a only.

Design note worth keeping: it does not issue the supercall itself. An ordinary
Android app runs under a seccomp filter that restricts which syscall numbers
reach the kernel, so the app ships `kpctl`, a static arm64 binary, extracts it to
private storage and runs it through `su`. `kpctl` keeps the `.so` name because
Android packages `lib/<abi>/*.so` uncompressed and only those can be extracted
and executed; it is a plain executable, verified `ELF64 AArch64 EXEC` with no
`NEEDED` entries.

The protocol it speaks, for whoever revives this:

```
syscall(45, superkey, (kp_version << 32) | (0x1158 << 16) | cmd, a1..a4)
```

KPM commands: load `0x1020`, unload `0x1021`, control `0x1022`, nums `0x1030`,
list `0x1031`, info `0x1032`. `sc_kpm_load` takes `(path, args, &kpm_load_result)`
and fills `{magic 0x4b504d52, size, code, message[160]}` on failure.

Only the `Image` was ever built and flashed; the app's kernel interaction is
untested.

## Build and publish

Codespaces, because a full build is ~20 minutes and needs ~25 GB.

```bash
# inside the Codespace
git clone https://github.com/KyuharuTE/Droidspaces-Kernel-ForK80
cd Droidspaces-Kernel-ForK80
bash scripts/codespace-build.sh setup     # deps, pinned clang, source, kABI patch
bash scripts/codespace-build.sh build
bash scripts/codespace-build.sh package
bash scripts/codespace-build.sh check
```

Toolchain: `clang-r487747c`, the version this tree pins. It lives on
`main-kernel-build-2023` in the AOSP prebuilt branches; `-2024` only has
`r510928`, and asking for r487747c there returns HTTP 400 (which surfaces as a
bare `exit code 22` from curl).

`kpimg` needs help from modern GCC: the in-tree CFLAGS predate the stack
protector and PIC defaults, so the link fails on `__stack_chk_guard` and
"Unexpected GOT/PLT entries". Passing the fixed set on the command line works
because command-line CFLAGS beats the Makefile's `+=`.

### Getting artifacts out of a Codespace

The Codespace cannot authenticate to GitHub by default, and `gh cs cp` stalls on
large files over a slow link. What works:

- the local `gh` token can be handed over on stdin, but PowerShell appends `\r`,
  so strip it: `read -r T; T=$(printf "%s" "$T" | tr -d "\r\n")`
- then the Codespace can create and upload a release itself, which keeps the
  bytes inside GitHub instead of crossing a slow connection twice
- `.github/workflows/publish-release.yml` does the same thing for a finished
  Actions run, by run id, without rebuilding

### Releases

`https://github.com/KyuharuTE/Droidspaces-Kernel-ForK80/releases/tag/kpm-6.1-zorn`

| Asset | What it is |
| --- | --- |
| `AnyKernel3_zorn_droidspaces-base.zip` | no KernelPatch; the config that boots |
| `AnyKernel3_zorn_droidspaces_kpm.zip` | KernelPatch 0.13.9 payload; does not boot |
| `AnyKernel3_zorn_droidspaces_kpm-0.12.2.zip` | KernelPatch 0.12.2 payload; does not boot |
| `KPM-Manager-debug.apk` | manager app, debug-signed |

All three zips come from the same `Image`. The only difference between `base`
and the others is the appended payload.

## Flashing notes

- The package targets `boot`. `block=boot` is set explicitly in `anykernel.sh`,
  and the packaging script verifies it. Do not target `init_boot`: on GKI it is
  an 8 MB ramdisk-only partition with `KERNEL_SZ 0` by design, and writing a
  kernel there cannot succeed at any size. AnyKernel3's `block=auto` tries
  `init_boot` first, which is exactly how that failure happened once.
- Ship `Image.gz`, not a raw `Image`. The raw image is ~35 MB, magiskboot writes
  what it is given, and the boot partition does not fit it.
- Keep the stock `boot.img`. `fastboot flash boot` restores it.

## Do not repeat these

1. Do not disable `CONFIG_CFI_CLANG` or `CONFIG_SHADOW_CALL_STACK`. It breaks
   vendor module loading.
2. Do not leave `CONFIG_MODULE_SIG_PROTECT` on.
3. Do not reconfigure by hand; go through `scripts/build-kernel.sh` so the
   module-signing block and the symbol gate always apply.
4. Do not build KernelPatch in-tree with `CONFIG_KP_LKM=y`. `vendor-kpatch.py`
   leaves it at `default n` for this reason.
5. Do not change more than one variable per flash. Two of the three failed
   builds were caused by a second, unrelated change riding along.
