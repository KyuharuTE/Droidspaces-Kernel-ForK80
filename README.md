# Droidspaces kernel for Redmi K80 (zorn)

An Android GKI kernel for the Redmi K80 / POCO F7 Pro that runs
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) containers, compiled
in a GitHub Codespace and delivered as a
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
| Integrated root | None |

Built kernels append `-nbkernel` to the complete release string, after the
Android/KMI, Git and build-number fields. For example:
`6.1.176-android14-11-g0b76321acf29-dirty-ab14529422-nbkernel`.
`scripts/fix-tree.py` applies this change to the version generator, and the
build checks enforce the suffix and the kernel's 64-character release limit.

## Why the kABI patch is required

Droidspaces needs `CONFIG_SYSVIPC` and `CONFIG_IPC_NS`.
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

## Why a config fragment and not `gki_defconfig`

The Droidspaces options are merged from `kernel-configs/droidspaces-gki.config`
after generating the base GKI config. This keeps the source tree's
`gki_defconfig` unchanged and makes the container-specific options easy to review.
`olddefconfig` resolves dependencies before the build checks required symbols.

KernelSU-Next is not integrated. The build rejects an existing source tree that
still wires in its driver, and both build and artifact checks reject enabled
`CONFIG_KSU*` options. Droidspaces operations that require root need a separately
provided root environment.

## What is deliberately left alone

These look like they need changing and do not. Each one was verified against the
tree rather than assumed:

- **`CONFIG_CFI_CLANG`** stays on. 6.1 uses kCFI (`-fsanitize=kcfi`), which does
  not depend on LTO. Turning CFI
  off changes struct layouts the vendor modules were built against. AOSP disables
  CFI in its `gki_kprobes` variant, but that is for ftrace tracing, not for root.
- **Module signing** is disabled by `scripts/build-kernel.sh` to work around
  this tree's OpenSSL 3 build path and protected-exports handling. Read the
  resulting `.config` before flashing.
- **LTO** stays off. That is already the GKI default on `android14-6.1`.
- **`CONFIG_TRIM_UNUSED_KSYMS`** is absent from GKI and must stay absent. Turning
  it on is the classic way to make vendor modules fail with `Unknown symbol`.

If vendor modules fail with `-EACCES`, inspect the device logs and build config
before changing the protected-exports list.

## Layout

```
.github/workflows/build-kernel.yml     optional manual CI build
scripts/codespace-build.sh             Codespace setup, build, package, checks
scripts/fix-tree.py            mandatory ABI fix, anchor-based
scripts/build-kernel.sh                configure and compile
scripts/kpm-patch-image.sh             add KernelPatch so the kernel loads .kpm
scripts/build-kpm.sh                   build a .kpm module from a source dir
scripts/package-anykernel3.sh          wrap Image into a flashable zip
kernel-configs/droidspaces-gki.config  the Droidspaces option set
kpms/nbdemo/                           example KPM
manager/                               Android app that loads and manages KPMs
```

## Loading .kpm modules

A `.kpm` is not a kernel module and not a kernel config option. It is an arm64
ELF relocatable object that a runtime maps into kernel space, and that runtime is
KernelPatch, which is a **binary patch** of the kernel image: `kptools` appends a
payload (`kpimg`), redirects `primary_entry` to it, and fixes the arm64 header.
Nothing in the kernel source changes, no exported symbol moves, and the kABI is
untouched, so the stock vendor modules keep loading.

```bash
export SUPERKEY='choose-a-key'
bash scripts/kpm-patch-image.sh        # out/arch/arm64/boot/Image -> dist/Image.kp
```

`dist/Image.kp` replaces `Image` as the AnyKernel3 payload. Package it the usual
way; the packaging script gzips whatever it is given.

Then build a module and install the manager:

```bash
bash scripts/build-kpm.sh kpms/nbdemo     # -> dist/kpm/nbdemo.kpm
cd manager && ./gradlew :app:assembleDebug
```

The app needs root, because it runs a small static `kpctl` binary through `su` to
issue KernelPatch's supercall (syscall 45). The superkey must match the one the
image was patched with. See [manager/README.md](manager/README.md).

`.kpm` loading requires `CONFIG_KALLSYMS=y` on the target kernel, since the
runtime resolves kernel functions by name; the patch script checks for it before
patching rather than producing an image that hangs later.

## Build and test in Codespaces

Open this repository in a Linux Codespace and run these commands in its terminal:

```bash
bash scripts/codespace-build.sh setup   # dependencies, pinned clang, source, ABI patch
bash scripts/codespace-build.sh build   # compile; rerun after edits to reuse objects
bash scripts/codespace-build.sh package # create the flashable zip from the Image
bash scripts/codespace-build.sh check   # verify config, Image and zip structure
```

`bash scripts/codespace-build.sh all` performs the entire sequence. The source
checkout is `kernel/`; its changes remain available for the next build. Objects
are stored in `.cache/droidspaces/out`, and the pinned Clang toolchain is cached
in `.cache/droidspaces/clang-r487747c`. These paths are inside `/workspaces` in
Codespaces, so they survive stopping, restarting, changing machine type and
rebuilding the container. `/tmp` is only used for disposable staging files.

Use a 4-core / 16 GB Codespace for development. `BUILD_JOBS` defaults to the CPU
count (4 on that machine) and can be lowered if memory is tight. `CACHE_DIR`,
`OUT_DIR` and `TOOLCHAIN_DIR` can override the defaults; keep them under
`/workspaces` for persistence. After a container rebuild, run `setup` again to
restore system dependencies; it reuses the cached source and toolchain.
Changes to sources, config or compiler can still require recompilation.

The outputs are:

- `dist/AnyKernel3_zorn_droidspaces.zip` — flashable package
- `.cache/droidspaces/out/arch/arm64/boot/Image` — raw kernel (default `OUT_DIR`)
- `.cache/droidspaces/out/.config` — resolved configuration

The `kernel/`, `.cache/droidspaces/` and `dist/` paths are ignored by Git. Review source changes in
`kernel/` separately; they are not part of this configuration repository.

GitHub Actions no longer builds on push. **Actions → Build Droidspaces kernel →
Run workflow** is available for an optional clean build
and artifact upload. The separate publish workflow still accepts artifacts
from an existing Actions run; it does not publish Codespace files.

Flash the AnyKernel3 zip from a custom recovery or Kernel Flasher. It replaces
only `boot.img`, so `vendor_dlkm` keeps the stock modules.

After booting, verify container support in your root environment:

```bash
su -c droidspaces check     # namespaces, cgroups, devtmpfs
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
