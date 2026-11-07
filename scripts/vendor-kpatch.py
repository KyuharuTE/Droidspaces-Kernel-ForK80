#!/usr/bin/env python3
"""
Vendor KernelPatch's LKM sources into the kernel tree as an in-tree driver.

Why this and not kptools
------------------------
The offline route (kptools appends kpimg to the built Image) works, but it is a
post-build step outside the kernel build: the Image has to be patched, and
compressed only afterwards. Vendoring the LKM sources instead makes KPM support
part of the kernel build itself, so `make Image` produces a kernel that already
has the supercall and the KPM loader. There is nothing to patch afterwards and
the packaging step is unchanged.

What is vendored
----------------
  drivers/kpatch/            the LKM sources, from KernelPatch/lkm
  drivers/kpatch/kpinclude/  the headers its Kbuild expects at ../kernel/*
  drivers/kpatch/version     the version file the Kbuild parses

The Kbuild resolves `$(src)/../kernel/patch/include/uapi`, so the header layout
is preserved under kpinclude/ and the Kbuild is rewritten to point there.

Authentication
--------------
Upstream authenticates by trusted-manager UID: it scans /data/app for an APatch
APK and verifies its signing certificate. A self-built kernel belongs to its
builder, not to APatch, and this repository ships its own manager, so the check
is replaced with a superkey comparison. The key is written here at vendor time
and must match what the manager sends.

SPDX-License-Identifier: GPL-2.0-or-later
"""

import json
import os
import re
import sys
import urllib.request
from pathlib import Path

KP_REPO = "bmax121/KernelPatch"
KP_REF = os.environ.get("KP_REF", "main")
API = "https://api.github.com/repos"
RAW = "https://raw.githubusercontent.com"

# Auth replacement injected into kp_supercall_handler.
# Upstream logic (lkm/supercall/supercall.c):
#     bool manager = kp_is_manager_uid(uid);
#     if (!manager && !kp_is_su_allow_uid(uid)) { ...return orig truncate... }
#     if (!manager && !kp_supercall_allowed_for_su(cmd)) return -EPERM;
# The replacement keeps the EPERM semantics but authorises by superkey instead.
SUPERKEY_CHECK = r"""
	/*
	 * Authorise by superkey rather than by manager UID.
	 *
	 * Upstream scans /data/app for an APatch manager APK and verifies its
	 * certificate, which ties the kernel to a specific third-party app. This
	 * build ships its own manager instead, so the key that was compiled in is
	 * compared against the first syscall argument.
	 *
	 * strncmp, not a length leak: the stored key is the full literal and both
	 * sides are kernel memory. Timing is not a concern for a local syscall.
	 */
	const char __user *ukey = (const char __user *)regs->regs[0];
	char key[KP_SUPERKEY_MAX];
	long klen = strncpy_from_user(key, ukey, sizeof(key));
	key[sizeof(key) - 1] = '\0';
	bool key_ok = klen > 0 && strncmp(key, kp_build_superkey, klen) == 0;
	if (!key_ok) {
		logkd("supercall: bad superkey\n");
		if (kp_orig_truncate)
			return kp_orig_truncate(regs);
		return -ENOSYS;
	}
	(void)uid;
	(void)manager;
"""


def die(msg: str) -> None:
    print(f"\n[FAIL] {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"\n[INFO] {msg}")


def fetch(url: str, timeout: int = 60) -> bytes:
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return r.read()
        except Exception as exc:  # noqa: BLE001 - surfaced to the user either way
            if attempt == 2:
                raise
            print(f"  retry ({exc})")
    raise RuntimeError("unreachable")


def list_tree(path: str) -> list[tuple[str, int]]:
    """Recursively list a directory through the contents API."""
    data = json.loads(fetch(f"{API}/{KP_REPO}/contents/{path}?ref={KP_REF}"))
    out: list[tuple[str, int]] = []
    for entry in data:
        if entry["type"] == "dir":
            out.extend(list_tree(entry["path"]))
        else:
            out.append((entry["path"], entry["size"]))
    return out


def rewrite_supercall(source: bytes, superkey: str) -> bytes:
    """Replace the UID authorisation block with a superkey comparison."""
    text = source.decode("utf-8")

    if "kp_build_superkey" in text:
        return source  # already patched

    # Locate the manager/allow-list gate and the per-command permission check and
    # replace both with the key check, keeping the rest of the handler intact.
    gate = (
        r"\tbool manager = kp_is_manager_uid\(uid\);\r?\n"
        r"\tif \(!manager && !kp_is_su_allow_uid\(uid\)\) \{.*?\r?\n\t\}\r?\n"
    )
    m = re.search(gate, text, re.S)
    if not m:
        die(
            "cannot find the UID authorisation block in supercall.c; "
            "kernelpatch changed its handler and the patch needs re-reading.",
        )
    text = text[: m.start()] + SUPERKEY_CHECK + text[m.end() :]

    # The per-command allow-list no longer applies: the key is the authority.
    text = re.sub(
        r"\tif \(!manager && !kp_supercall_allowed_for_su\(cmd\)\)\r?\n"
        r"\t\treturn -EPERM;\r?\n",
        "",
        text,
    )
    # Drop any remaining check that references the removed `manager`, line by
    # line rather than by regex: this source is upstream and its whitespace is
    # not ours to depend on, and a missed reference is a compile error.
    kept: list[str] = []
    skip_next = False
    for line in text.split("\n"):
        if skip_next:
            skip_next = False
            if line.strip().startswith("return -EPERM"):
                continue
        stripped = line.strip()
        if stripped.startswith("if (") and "manager" in stripped:
            # A guarded return on the following line goes with it.
            skip_next = True
            continue
        if stripped.startswith("bool manager =") or stripped.startswith("(void)manager"):
            continue
        kept.append(line)
    text = "\n".join(kept)

    # Declare the compiled-in key and its length bound.
    decl = (
        f'#define KP_SUPERKEY_MAX 64\n'
        f'static const char kp_build_superkey[] = "{superkey}";\n'
    )
    anchor = "#define KP_SUPERCALL_NR 45"
    if anchor not in text:
        die("cannot find KP_SUPERCALL_NR in supercall.c")
    text = text.replace(anchor, decl + "\n" + anchor, 1)

    return text.encode("utf-8")


def main() -> None:
    if len(sys.argv) < 2:
        die("usage: vendor-kpatch.py <kernel-root> [superkey]")

    kernel_root = Path(sys.argv[1]).resolve()
    superkey = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("SUPERKEY", "")
    if not superkey:
        die(
            "no superkey. Pass it as the second argument or set SUPERKEY.\n"
            "It must match the key the manager app will send.",
        )
    if len(superkey) > 64:
        die("superkey is longer than 64 bytes")
    if re.search(r'["\\\n]', superkey):
        die('superkey contains a quote, backslash or newline; pick another')

    if not (kernel_root / "Makefile").is_file() or not (kernel_root / "arch/arm64").is_dir():
        die(f"not a kernel root: {kernel_root}")

    dest = kernel_root / "drivers/kpatch"
    info(f"Vendoring {KP_REPO}@{KP_REF} into {dest}")

    # --- sources -----------------------------------------------------------
    lkm_files = list_tree("lkm")
    info(f"{len(lkm_files)} files from lkm/")
    (dest / "kpinclude").mkdir(parents=True, exist_ok=True)

    for path, _size in lkm_files:
        rel = path[len("lkm/") :]
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        data = fetch(f"{RAW}/{KP_REPO}/{KP_REF}/{path}")
        if rel == "supercall/supercall.c":
            data = rewrite_supercall(data, superkey)
            info("Rewrote supercall.c to authorise by superkey")
        target.write_bytes(data)

    # --- headers the Kbuild reaches for -----------------------------------
    # Kbuild uses $(src)/../kernel/{include,patch/include}/..., so mirror that
    # layout under kpinclude/ and rewrite the paths below.
    for path, _size in list_tree("kernel/include") + list_tree("kernel/patch/include"):
        rel = path[len("kernel/") :]
        target = dest / "kpinclude" / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(fetch(f"{RAW}/{KP_REPO}/{KP_REF}/{path}"))

    (dest / "version").write_bytes(fetch(f"{RAW}/{KP_REPO}/{KP_REF}/version"))

    # --- rewrite the Kbuild include paths ---------------------------------
    kbuild = (dest / "Kbuild").read_text(encoding="utf-8")
    kbuild = kbuild.replace("$(KP_LKM_DIR)/../kernel/", "$(KP_LKM_DIR)/kpinclude/")
    kbuild = kbuild.replace(
        "$(KP_VERSION_FILE)",
        "$(KP_LKM_DIR)/version",
    ).replace(
        "KP_VERSION_FILE := $(KP_LKM_DIR)/../version",
        "KP_VERSION_FILE := $(KP_LKM_DIR)/version",
    )

    # Upstream builds as an out-of-tree DDK module; in-tree it needs an explicit
    # object directory or Kbuild will not descend into it.
    if "obj-$(CONFIG_KP_LKM)" not in kbuild:
        kbuild = "obj-$(CONFIG_KP_LKM) += kernelpatch.o\n\n" + kbuild
    (dest / "Kbuild").write_text(kbuild, encoding="utf-8")

    # --- register with the kernel build -----------------------------------
    info("Registering drivers/kpatch")
    drv_kconfig = kernel_root / "drivers/Kconfig"
    text = drv_kconfig.read_text(encoding="utf-8")
    if "drivers/kpatch" not in text:
        text = text.rstrip("\n") + '\nsource "drivers/kpatch/Kconfig"\n'
        drv_kconfig.write_text(text, encoding="utf-8")

    drv_makefile = kernel_root / "drivers/Makefile"
    text = drv_makefile.read_text(encoding="utf-8")
    if "kpatch/" not in text:
        text = text.rstrip("\n") + "\nobj-$(CONFIG_KP_LKM) += kpatch/\n"
        drv_makefile.write_text(text, encoding="utf-8")

    # In-tree objects compile with the kernel's own sanitizer settings, and CFI
    # rewriting of indirect calls is exactly what breaks a hook engine.
    kconfig = (dest / "Kconfig").read_text(encoding="utf-8")
    kconfig = kconfig.replace("depends on MODULES && ARM64", "depends on ARM64")
    kconfig = kconfig.replace("default n", "default y")
    kconfig = kconfig.replace("tristate ", "bool ")
    # Rewrite the whole help body: upstream's describes a DDK-built .ko and
    # APatch-uid authentication, neither of which is true here.
    kconfig = re.sub(
        r"\thelp\n(?:\t  .*\n)+",
        "\thelp\n"
        "\t  KernelPatch built into the kernel image instead of a patched boot\n"
        "\t  image. Provides the supercall channel on syscall 45 (truncate), the\n"
        "\t  inline hook engine and the KPM loader, so .kpm modules can be loaded\n"
        "\t  at runtime.\n"
        "\t  Authenticates by superkey compiled in at vendor time, not by\n"
        "\t  manager uid. Vendored by scripts/vendor-kpatch.py; build with\n"
        "\t  CONFIG_KP_LKM=y.\n",
        kconfig,
    )
    (dest / "Kconfig").write_text(kconfig, encoding="utf-8")

    info(f"Done. {len(list(dest.rglob('*')))} files under {dest}")
    print(
        "\nNext: the fragment must enable it.\n"
        "  CONFIG_KP_LKM=y\n"
        "  CONFIG_MODULES=y   (Kbuild objects, not a loadable module here)\n",
    )


if __name__ == "__main__":
    main()
