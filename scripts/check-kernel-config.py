#!/usr/bin/env python3
"""Reject configurations outside the boot-tested zorn baseline."""
import sys
from pathlib import Path


def check(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line[2:-11]] = "n"
    errors = []
    for name in ("SYSVIPC", "IPC_NS", "PID_NS", "UTS_NS", "NAMESPACES",
                 "DEVTMPFS", "CGROUPS", "CFI_CLANG", "SHADOW_CALL_STACK"):
        if values.get("CONFIG_" + name) != "y":
            errors.append(f"CONFIG_{name} must be y")
    for name in ("MODULE_SIG", "MODULE_SIG_PROTECT", "MODULE_SIG_FORCE", "KP_LKM"):
        if values.get("CONFIG_" + name, "n") != "n":
            errors.append(f"CONFIG_{name} must be disabled")
    for key, value in values.items():
        if key.startswith("CONFIG_KSU") and value in ("y", "m"):
            errors.append(f"{key} must be disabled")
    return errors


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: check-kernel-config.py PATH_TO_CONFIG")
    try:
        errors = check(sys.argv[1])
    except OSError as exc:
        sys.exit(f"Cannot read kernel configuration: {exc}")
    if errors:
        sys.exit("Unsafe kernel configuration:\n  " + "\n  ".join(errors))
    print("Boot baseline config checks passed")
