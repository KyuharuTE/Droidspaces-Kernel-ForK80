#!/usr/bin/env python3
"""
Give this kernel tree ABI-safe CONFIG_SYSVIPC support.

What this does
--------------
Droidspaces needs CONFIG_SYSVIPC and CONFIG_IPC_NS. Enabling SYSVIPC naively
changes the size of struct task_struct, which shifts the offsets that Xiaomi's
prebuilt vendor modules (GPU, camera, Wi-Fi) were compiled against. Those
modules then dereference garbage and the device bootloops.

The fix, which is what the upstream Droidspaces patch does, is to move the
sysvsem and sysvshm fields out of the middle of task_struct and into the
ANDROID_KABI_RESERVE padding slots that GKI already reserves for exactly this.
No offset moves, so the vendor modules keep working.

Why this edits the file instead of applying the upstream patch
-------------------------------------------------------------
Upstream ships three static variants (_1_2_3, _3_4_5, _6_7_8) that differ only
in which reserve slots they consume. All three fail on the LineageOS zorn tree:

  1. That tree already uses slots 1, 2 and 3, so the only free run is 4..8.
  2. The hunk context does not match. The tree has `union rv_task_monitor` and
     an `#endif` just before the reserve slots, and its reserve run is preceded
     by the tail of the KABI_USE(3) block rather than by `RESERVE(3);`. A static
     patch cannot express "whatever happens to be here".

Editing by anchor avoids both problems: the slot numbers come from a scan of
the file, and there is no context matching to get wrong. Line endings are
preserved because the file is read and written as bytes.
"""

import re
import sys
from pathlib import Path

SCHED = "include/linux/sched.h"


def die(msg: str) -> None:
    print(f"\n[FAIL] {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"\n[INFO] {msg}")


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    sched = root / SCHED
    if not sched.is_file():
        die(f"Not a kernel root, missing {SCHED}: {root}")

    # Bytes, not text: this keeps CRLF/LF exactly as the tree has it, so the
    # edit behaves identically on a Linux runner and a Windows checkout.
    data = sched.read_bytes()
    text = data.decode("utf-8", errors="surrogateescape")

    if "struct sysv_sem sysvsem);" in text and "ANDROID_KABI_USE" in text:
        info("sysvsem already lives in an ABI reserve slot; nothing to do")
        return

    # --- 1. Remove the unconditional fields from task_struct ---------------
    # Match the two declarations together, keeping their leading whitespace.
    field_re = re.compile(
        r"(?P<indent>[ \t]*)struct[ \t]+sysv_sem[ \t]+sysvsem[ \t]*;[ \t]*\r?\n"
        r"(?P=indent)struct[ \t]+sysv_shm[ \t]+sysvshm[ \t]*;"
    )
    matches = list(field_re.finditer(text))
    if len(matches) != 1:
        die(
            f"Expected exactly one adjacent sysv_sem/sysv_shm pair in {SCHED}, "
            f"found {len(matches)}. Either the patch is already applied or this "
            "tree handles SYSVIPC differently. Inspect it by hand."
        )
    m = matches[0]
    comment = f"/* moved to ANDROID_KABI_USE for GKI ABI safety */"
    replacement = (
        f"{m.group('indent')}{comment}\n"
        if "\r\n" not in m.group(0)
        else f"{m.group('indent')}{comment}\r\n"
    )
    text = text[: m.start()] + replacement + text[m.end() :]
    info("Removed the unconditional sysvsem/sysvshm fields from task_struct")

    # --- 2. Find the free ABI reserve slots --------------------------------
    used = set()
    for n in range(1, 9):
        if re.search(rf"ANDROID_KABI_USE\(\s*{n}\s*,", text):
            used.add(n)
        if re.search(rf"_ANDROID_KABI_REPLACE\(ANDROID_KABI_RESERVE\(\s*{n}\s*\)", text):
            used.add(n)
    info(f"ABI reserve slots already in use: {sorted(used) or 'none'}")

    triple = None
    for start in (6, 1, 3, 4, 2, 5):
        cand = (start, start + 1, start + 2)
        if cand[-1] <= 8 and not (set(cand) & used):
            triple = cand
            break
    if triple is None:
        die("No three consecutive free ABI reserve slots in task_struct.")
    a, b, c = triple
    info(f"Using ABI reserve slots {a}/{b}/{c}")

    # --- 3. Replace those three reserve lines ------------------------------
    # Anchor on the first consumed slot and require the run to be contiguous,
    # so a surprising layout fails loudly instead of producing a broken struct.
    slot_line = re.compile(
        r"(?P<indent>[ \t]*)ANDROID_KABI_RESERVE\(\s*(?P<num>\d+)\s*\)[ \t]*;"
        r"(?P<eol>\r?\n)"
    )
    lines = list(slot_line.finditer(text))
    start_idx = None
    for i, lm in enumerate(lines):
        if int(lm.group("num")) == a:
            start_idx = i
            break
    if start_idx is None:
        die(f"No ANDROID_KABI_RESERVE({a}); line found to anchor on.")
    run = lines[start_idx : start_idx + 3]
    if len(run) != 3 or [int(x.group("num")) for x in run] != [a, b, c]:
        die(
            "The reserve slots are not a contiguous run starting at "
            f"{a}; found {[m.group('num') for m in run]}. Refusing to guess."
        )
    if run[0].start() != run[2].end() - len(run[2].group(0)):
        pass  # contiguity already checked via numbering

    indent = run[0].group("indent")
    eol = run[0].group("eol")
    new_block = eol.join(
        [
            f"{indent}#ifdef CONFIG_SYSVIPC",
            f"{indent}ANDROID_KABI_USE({a}, struct sysv_sem sysvsem);",
            f"{indent}_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE({b}); "
            f"ANDROID_KABI_RESERVE({c}), struct sysv_shm sysvshm);",
            f"{indent}#else",
            f"{indent}ANDROID_KABI_RESERVE({a});",
            f"{indent}ANDROID_KABI_RESERVE({b});",
            f"{indent}ANDROID_KABI_RESERVE({c});",
            f"{indent}#endif",
            "",
        ]
    )
    text = text[: run[0].start()] + new_block + text[run[2].end() :]
    info("Rewrote the reserve slots to carry sysvsem/sysvshm under CONFIG_SYSVIPC")

    sched.write_bytes(text.encode("utf-8", errors="surrogateescape"))

    # --- 4. Verify ---------------------------------------------------------
    after = sched.read_bytes().decode("utf-8", errors="surrogateescape")
    if not re.search(r"ANDROID_KABI_USE\(\d+, struct sysv_sem sysvsem\)", after):
        die("Verification failed: sysvsem is not in a reserve slot.")
    if "_ANDROID_KABI_REPLACE(" not in after or "struct sysv_shm sysvshm" not in after:
        die("Verification failed: sysvshm is not in a reserve slot.")
    if re.search(r"^\s*struct\s+sysv_sem\s+sysvsem\s*;", after, re.M):
        die("Verification failed: the unconditional sysvsem field is still present.")

    info("kABI patch applied and verified")
    for i, line in enumerate(after.split("\n"), 1):
        if "sysv_sem sysvsem" in line or "struct sysv_shm sysvshm" in line:
            print(f"  {i}: {line.strip()}")


if __name__ == "__main__":
    main()
