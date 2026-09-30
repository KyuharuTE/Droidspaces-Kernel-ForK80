# Droidspaces kernel for Redmi K80 (zorn)

An Android GKI kernel for the Redmi K80 / POCO F7 Pro that runs
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) containers, built
with KernelSU-Next for root, compiled by GitHub Actions and delivered as a
flashable AnyKernel3 zip.

## What this actually is

Droidspaces is a **userspace** container runtime. It does not ship a kernel and
it does not compile one. What it needs is a kernel with the right options, plus
a small patch that makes those options ABI-safe. That is what this repo does.

The target kernel reports `6.1.157-android14-11-g2de7246565ac-mi`:

| Piece | Value |
| --- | --- |
| Linux | 6.1, arm64 |
| ACK branch | `android14-6.1` |
| KMI generation | 11 (the `-android14-11-` in the string) |
| Device | zorn, Redmi K80 / POCO F7 Pro, Snapdragon 8 Gen 3 |
| Root | KernelSU-Next |

## Why two things have to be patched

**1. The kABI problem.** Droidspaces needs `CONFIG_SYSVIPC` and `CONFIG_IPC_NS`.
Enabling them naively moves fields inside `struct task_struct`, which changes the
offsets that Xiaomi's prebuilt vendor modules (GPU, camera, Wi-Fi) were compiled
against. Those modules then dereference garbage and the device bootloops.

`scripts/fix-tree.py` does this by moving `sysvsem` and `sysvshm` into
the `ANDROID_KABI_RESERVE` padding slots that GKI already reserves for exactly
this purpose, so **no offset moves**. This patch is mandatory.

It edits the file by anchor rather than applying a static patch, for two
reasons. Upstream ships three static variants (`_1_2_3`, `_3_4_5`, `_6_7_8`)
that differ only in which reserve slots they consume, and all three assume slots
1 and 2 are free. This tree already uses 1, 2 and 3:

```
ANDROID_KABI_USE(1, unsigned int saved_state);
ANDROID_KABI_USE(2, struct task_dma_buf_info *dmabuf_info);
ANDROID_KABI_USE(3, struct { ... });
ANDROID_KABI_RESERVE(4);   <-- first free slot
```

so the only free run is 4..8 and the first available triple is 6/7/8. On top of
that, the tree has `union rv_task_monitor` and an `#endif` immediately before the
reserve slots, so the upstream hunk context does not match either. A static patch
cannot express "whatever happens to be here", so the script scans which slots are
free and rewrites those lines. It refuses to continue if it cannot verify the
result.

**2. KernelSU needs `CONFIG_KSU`.** That symbol is `default y` and depends on
`KPROBES && EXT4_FS`, both already enabled in GKI, so it largely enables itself.

## Why a config fragment and not `gki_defconfig`

The Droidspaces docs say to edit `arch/arm64/configs/gki_defconfig` directly.
That advice is correct for a Droidspaces-only build, but it breaks as soon as
KernelSU is involved, and the reason is non-obvious:

AOSP's `build.config.gki` runs `POST_DEFCONFIG_CMDS="check_defconfig"`, which
does `make savedefconfig` and diffs the result against `gki_defconfig`. And
`scripts/kconfig/confdata.c` skips any symbol whose value equals its default:

```c
/* If symbol equals to default value - skip */
if (strcmp(sym_get_string_value(sym), sym_get_string_default(sym)) == 0)
        goto next_menu;
```

`CONFIG_KSU` is `default y`, so `savedefconfig` **deletes the line you added**,
the diff is non-empty, and the build fails with `savedefconfig does not match`.
A raw `make` build never runs that check, and a merged fragment never touches
`gki_defconfig` at all. This repo does the latter.

## What is deliberately left alone

These look like they need changing and do not. Each one was verified against the
tree rather than assumed:

- **`CONFIG_CFI_CLANG`** stays on. 6.1 uses kCFI (`-fsanitize=kcfi`), which does
  not depend on LTO, and KernelSU ships `USE_KCFI` handling for it. Turning CFI
  off changes struct layouts the vendor modules were built against. AOSP disables
  CFI in its `gki_kprobes` variant, but that is for ftrace tracing, not for root.
- **`CONFIG_MODULE_SIG`** stays on. `CONFIG_MODULE_SIG_PROTECT=y` hardcodes
  `sig_enforce` to `false` and makes `module_sig_check()` return `0` for unsigned
  modules, so vendor modules already load. Disabling `MODULE_SIG` solves nothing
  and loses a mitigation.
- **LTO** stays off. That is already the GKI default on `android14-6.1`.
- **`CONFIG_TRIM_UNUSED_KSYMS`** is absent from GKI and must stay absent. Turning
  it on is the classic way to make vendor modules fail with `Unknown symbol`.

The real vendor-module risk besides kABI drift is `CONFIG_MODULE_SIG_PROTECT`'s
GKI protected-exports allowlist, which is separate from signing and fails with
`-EACCES` at `insmod`. If Wi-Fi or Bluetooth break, re-run the workflow with
`remove_protected_exports` enabled.

## Layout

```
.github/workflows/build-kernel.yml     the CI build
scripts/fix-tree.py            mandatory ABI fix, anchor-based
scripts/build-kernel.sh                integrate KernelSU, configure, compile
scripts/package-anykernel3.sh          wrap Image into a flashable zip
kernel-configs/droidspaces-gki.config  the Droidspaces option set
```

## Usage

Push this to GitHub, then **Actions → Build Droidspaces + KernelSU-Next kernel →
Run workflow**. Artifacts:

- `AnyKernel3-zorn-droidspaces-ksu-next` — flash this
- `Image-zorn-droidspaces-ksu-next` — the raw kernel, for manual packing
- `kernel-config-zorn` — the resolved `.config`, worth reading when something fails

Flash the AnyKernel3 zip from a custom recovery or Kernel Flasher. It replaces
only `boot.img`, so `vendor_dlkm` keeps the stock modules.

After booting, verify both halves:

```bash
su -c droidspaces check     # namespaces, cgroups, devtmpfs
su -c ksu --version         # or open the KernelSU-Next manager
```

`droidspaces check` probes the running kernel by calling `unshare()` rather than
reading flags, so it reports the truth. A red cross on IPC, PID, MNT or UTS
namespace means the build did not take.

## Source tree

Default is `cnmrlin/android_kernel_xiaomi_sm8650@lineage-24.0` (6.1.176, keeps
the `-android14-11` KMI tag, plain-make buildable).

The official `MiCode/Xiaomi_Kernel_OpenSource@bsp-zorn-v-oss` is also 6.1 but is
frozen at 6.1.68, and it has no `build/` directory and no `tools/bazel`, so it
needs a full Kleaf workspace (CodeLinaro prebuilts, `repo` manifest, Bazel) to
build. That is why it is not the default. The kABI patch applies cleanly to
either tree, since both carry the same `task_struct` reserve layout.

## Risks

Flashing a kernel can brick the device. Keep the stock `boot.img` extracted and
handy before flashing anything, so you can restore it over fastboot. KMI
mismatch is an instant bootloop, so confirm `uname -r` on the device first.

## Licences

Kernel patches and configs follow the kernel's GPL-2.0. Build scripts here are
GPL-2.0-or-later. Droidspaces is GPL-3.0-or-later.
