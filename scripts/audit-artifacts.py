#!/usr/bin/env python3
"""Read-only artifact inventory. Never prints KernelPatch keys or metadata."""
import argparse
import datetime
import gzip
import hashlib
import json
import struct
import subprocess
import zipfile
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    return result.stdout.decode("utf-8", errors="replace").strip() if result.returncode == 0 else None


def image_info(data):
    if len(data) < 64 or data[56:60] != b"ARM\x64":
        raise ValueError("Not an arm64 Image")
    # EFI kernels put MZ in code0: the branch is code1 at offset 4.
    branch_offset = 4 if data[:2] == b"MZ" else 0
    branch = struct.unpack_from("<I", data, branch_offset)[0]
    imm = branch & 0x3ffffff
    if imm & 0x2000000:
        imm -= 0x4000000
    return dict(bytes=len(data), sha256=sha(data),
                entry_branch=f"0x{branch:08x}", branch_offset=branch_offset,
                branch_target=branch_offset + imm * 4 if branch >> 26 == 5 else None,
                image_size=struct.unpack_from("<Q", data, 16)[0])


def audit(root, out):
    baseline_path = out / "arch/arm64/boot/Image"
    baseline = baseline_path.read_bytes()
    result = dict(captured_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  repository_commit=git(root, "rev-parse", "HEAD"),
                  repository_status=git(root, "status", "--short"),
                  kernel_commit=git(root / "kernel", "rev-parse", "HEAD"),
                  kernel_diff_sha256=sha((git(root / "kernel", "diff", "--binary") or "").encode()),
                  baseline=image_info(baseline),
                  config_sha256=sha((out / ".config").read_bytes()),
                  kernel_release=(out / "include/config/kernel.release").read_text().strip(),
                  kernelpatch={}, packages=[])
    for checkout in sorted((root / ".kp").glob("*")):
        if (checkout / ".git").exists():
            result["kernelpatch"][checkout.name] = git(checkout, "rev-parse", "HEAD")
    for path in sorted((root / "dist").glob("*.zip")):
        package = dict(name=path.name, sha256=sha(path.read_bytes()))
        try:
            with zipfile.ZipFile(path) as z:
                package["crc_ok"] = z.testzip() is None
                member = next(n for n in ("Image.gz", "Image") if n in z.namelist())
                data = z.read(member)
                if member.endswith(".gz"):
                    data = gzip.decompress(data)
                package["image"] = image_info(data)
                package["matches_baseline"] = data == baseline
                package["partition_settings"] = [line for line in z.read("anykernel.sh").decode().splitlines()
                                                 if line.lower().startswith(("block=", "is_slot_device="))]
        except (ValueError, KeyError, StopIteration, OSError, zipfile.BadZipFile) as exc:
            package["error"] = str(exc)
        result["packages"].append(package)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    print(json.dumps(audit(root, args.out or root / ".cache/droidspaces/out"), indent=2))
