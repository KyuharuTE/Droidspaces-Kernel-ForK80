# KPM Manager

Version 1.0.1 has been verified on the zorn Android 17 device. It fixes client
extraction when native entries remain inside the APK, ARM64 static-TLS
alignment, and startup error handling. Keys reach the client through stdin.
The UI connects successfully to the verified KernelPatch 0.13.9 kernel.
See `../reports/manager-zygisk-repair.md` for evidence and the APK hash.

An Android app that loads and manages **KernelPatch Modules (`.kpm`)** on the
kernel built by this repository.

## What a .kpm is

Not a kernel module and not a shared library. A `.kpm` is an arm64 ELF
**relocatable object** (`ET_REL`, linked with `gcc -r`) that the KernelPatch
runtime maps into kernel space and relocates itself. Undefined symbols are
resolved against the running kernel's `kallsyms` at load time, so a KPM needs no
vermagic, no `MODULE_SIG` signature and no `CONFIG_MODULES`.

Because of that, KPM support is **not a kernel config option**. It comes from
patching the kernel image with KernelPatch (see the repo root README), which is
what `scripts/kpm-patch-image.sh` does.

## How the app talks to the kernel

KernelPatch exposes one multiplexed syscall, number 45 (`__NR3264_truncate`):

```
syscall(45, superkey, (kp_version << 32) | (0x1158 << 16) | cmd, a1, a2, a3, a4)
```

There is no device node and no ioctl at this layer. Every KPM command is gated on
the superkey the image was patched with.

The app does not issue that syscall itself. An ordinary Android app runs under a
seccomp filter that restricts which syscall numbers reach the kernel, and the
app then has no reliable way through. Instead the app ships a small static
binary, `kpctl`, extracts it to app-private storage, and runs it through `su`.
That is also the environment Droidspaces already needs: root.

```
app  --su-->  kpctl  --syscall 45-->  kernel (kpimg)
```

## Layout

```
app/src/main/cpp/kpctl.c            the syscall client, one command per argv
app/src/main/cpp/CMakeLists.txt     builds it static, named libkpctl.so
app/src/main/java/.../shell/        root shell, binary extraction, quoting
app/src/main/java/.../kpm/          repository: connect/list/load/unload/control
app/src/main/java/.../ui/           Compose UI and ViewModel
kpms/nbdemo/nbdemo.c                example module (in the repo root)
scripts/build-kpm.sh                builds a .kpm from a source dir
```

`libkpctl.so` keeps the `.so` name on purpose: Android packages `lib/<abi>/*.so`
uncompressed, and only those can be extracted and executed. The file is a plain
executable, not a library.

## Building

A local Android SDK is enough; no Codespace needed.

```bash
cd manager
echo "sdk.dir=$HOME/Android/Sdk" > local.properties
./gradlew :app:assembleDebug        # or assembleRelease
```

The APK lands in `app/build/outputs/apk/debug/`. It is arm64-v8a only, matching
the only ABI this kernel targets.

## Using it

1. Flash the KernelPatch-patched kernel (`scripts/kpm-patch-image.sh`).
2. Install the APK.
3. Enter the superkey you passed to the patch script, and connect.
4. **Load .kpm** picks a module file, stages a copy in app-private storage, and
   loads it. The module list shows each loaded module with its metadata, plus
   buttons to send a control string or unload it.

The superkey is stored in the app's private preferences, not in world-readable
storage. It is not encrypted: any process running as root, or with the app's
UID, can read it. That is the same trust level the kernel itself uses for it.

## Testing a module

`kpms/nbdemo` is the smallest useful module: it logs on load and echoes control
strings back.

```bash
scripts/build-kpm.sh kpms/nbdemo      # -> dist/kpm/nbdemo.kpm
adb push dist/kpm/nbdemo.kpm /sdcard/Download/
```

Then load it from the app and check `dmesg | grep kpm-nbdemo`.

## Risks

Loading a KPM runs arbitrary code in kernel context. A bad module panics the
device; recovery is a reboot, and if it loads at boot, a stock `boot.img`
restore. Only load modules whose source you have read.
