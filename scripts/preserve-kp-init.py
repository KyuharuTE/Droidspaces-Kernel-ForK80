#!/usr/bin/env python3
"""Add an opt-in compile guard to KP's init.rc redirect registration.

KernelSU identifies init.rc by its original path. Redirecting it to KP's
/dev/user_init.rc bypasses that recognition and prevents module boot stages.
Other Android hooks and the KPM supercall remain intact.
"""
import sys
from pathlib import Path

MARKER = "DROIDSPACES_PRESERVE_ROOT_INIT"
BLOCK = '''    rc = hook_syscalln(__NR_openat, 4, before_openat, after_openat, 0);
    log_boot("hook __NR_openat rc: %d\\n", rc);
    ret |= rc;'''


def patch(root):
    source = Path(root) / "kernel/patch/android/userd.c"
    text = source.read_text(encoding="utf-8")
    if MARKER in text:
        return
    if text.count(BLOCK) != 1:
        raise SystemExit("Unexpected KernelPatch init hook registration; refusing patch")
    guarded = (f"#ifndef {MARKER}\n" + BLOCK + '\n#else\n'
               '    log_boot("Droidspaces: preserve original init.rc for existing root\\n");\n#endif')
    source.write_text(text.replace(BLOCK, guarded), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: preserve-kp-init.py KERNELPATCH_ROOT")
    patch(sys.argv[1])
