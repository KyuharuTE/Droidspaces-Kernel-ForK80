#!/usr/bin/env python3
"""Verify an already-booted zorn candidate. Never writes device partitions.

Read the superkey from stdin. Test files use /dev tmpfs; only this script's
demo KPM is unloaded. Requires root adb and prebuilt local test tools.
"""
import argparse
import json
import re
import shlex
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--su", action="store_true", help="Run shell checks through the device's existing su")
    parser.add_argument("--expected-boot-sha256", default="98a3636a69015c688b74ddd92fe40d5fd0abeabdf2d69416f39525f71ef5736a")
    parser.add_argument("--report", type=Path, default=Path("reports/device-kpm-verification.json"))
    args = parser.parse_args()
    key = input().strip()
    if not 0 < len(key) <= 64:
        raise SystemExit("Invalid superkey input")
    root = Path(__file__).resolve().parent.parent
    adb = [args.adb, "-s", args.serial]
    report = {"passed": False, "checks": {}}
    loaded = False
    directory = "/dev/droidspaces-kpm-test"

    def shell(label, command, require=True):
        if args.su:
            command = "su -c " + shlex.quote(command)
        proc = subprocess.run(adb + ["shell", command], capture_output=True, timeout=30)
        output = (proc.stdout + proc.stderr).decode(errors="replace").replace(key, "<redacted>").replace("\r", "").strip()
        report["checks"][label] = {"exit_code": proc.returncode, "output": output}
        print(label + ": " + output, flush=True)
        if require and proc.returncode:
            raise RuntimeError(label + " failed")
        return proc.returncode, output

    def ctl(label, *arguments, require=True):
        return shell(label, " ".join(shlex.quote(s) for s in [directory + "/kpctl", key, *arguments]), require)

    try:
        _, boot = shell("boot_completed", "getprop sys.boot_completed")
        assert boot == "1", "Android has not completed boot"
        _, identity = shell("identity", "getprop ro.product.device; uname -r; getprop ro.build.fingerprint; id")
        assert identity.startswith("zorn\n") or identity.startswith("zorn\r\n"), "Unexpected device"
        assert "uid=0(root)" in identity, "Root adb required"
        _, boot_hash = shell("boot_a_hash", "sha256sum /dev/block/by-name/boot_a")
        assert boot_hash.split()[0] == args.expected_boot_sha256, "Unexpected boot image"
        shell("tmpfs", "grep ' /dev ' /proc/mounts")
        assert "tmpfs /dev tmpfs" in report["checks"]["tmpfs"]["output"]
        shell("prepare", "mkdir -p " + directory)
        # Files remain in tmpfs. Label only this temporary directory so adb's
        # shell uid can transfer the tools while SELinux stays enforcing.
        shell("transfer_permissions", f"chown 2000:2000 {directory}; chmod 700 {directory}; chcon u:object_r:shell_data_file:s0 {directory}")
        for local, remote in [("kpctl-glibc", "kpctl"), ("nbdemo.kpm", "nbdemo.kpm"), ("nscheck", "nscheck")]:
            subprocess.run(adb + ["push", str(root / ".cache/device-test" / local), directory + "/" + remote], check=True)
        shell("permissions", f"chmod 700 {directory}/kpctl {directory}/nscheck")
        ctl("hello", "hello")
        ctl("versions", "version")
        _, before = ctl("nums_before", "nums")
        before = int(re.search(r"OK nums (\d+)", before).group(1))
        _, listing = ctl("list_before", "list")
        assert "kpm-nbdemo" not in listing, "Demo name already in use; refusing to replace it"
        ctl("load", "load", directory + "/nbdemo.kpm", "device-smoke")
        loaded = True
        _, listing = ctl("list_loaded", "list")
        assert "kpm-nbdemo" in listing
        ctl("info", "info", "kpm-nbdemo")
        _, count = ctl("nums_loaded", "nums")
        assert int(re.search(r"OK nums (\d+)", count).group(1)) == before + 1
        _, response = ctl("control", "control", "kpm-nbdemo", "device-smoke")
        assert "echo: device-smoke" in response
        ctl("unload", "unload", "kpm-nbdemo")
        loaded = False
        _, count = ctl("nums_after", "nums")
        assert int(re.search(r"OK nums (\d+)", count).group(1)) == before
        shell("namespaces", directory + "/nscheck")
        _, filesystems = shell("filesystems", "cat /proc/filesystems")
        assert all(name in filesystems for name in ("cgroup2", "devtmpfs", "overlay"))
        report["passed"] = True
    except Exception as exc:
        report["error"] = str(exc).replace(key, "<redacted>")
        raise
    finally:
        if loaded:
            try:
                ctl("cleanup_unload", "unload", "kpm-nbdemo", require=False)
            except Exception as exc:
                report["cleanup_error"] = str(exc).replace(key, "<redacted>")
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
