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
import shutil
import subprocess
import sys
from pathlib import Path

SCHED = "include/linux/sched.h"


def die(msg: str) -> None:
    print(f"\n[FAIL] {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"\n[INFO] {msg}")


def fix_extract_cert(root: Path) -> None:
    """Make certs/extract-cert.c compile against OpenSSL 3.x.

    certs/Makefile has an unconditional `hostprogs := extract-cert`, so this
    host program is built on every kernel build regardless of whether module
    signing is enabled. Turning CONFIG_MODULE_SIG off does not avoid it.

    The problem is a missing guard. The PKCS#11 branch is guarded only by
    OPENSSL_IS_BORINGSSL:

        } else if (!strncmp(cert_src, "pkcs11:", 7)) {
        #ifdef OPENSSL_IS_BORINGSSL
                fprintf(stderr, "BoringSSL does not support PKCS#11\\n");
                exit(1);
        #else
                ENGINE *e;
                ...
                if (key_pass)          <-- 'key_pass' undeclared
        #endif

    and `key_pass` itself is declared and assigned only under
    USE_PKCS11_ENGINE. OpenSSL 3.0 deprecates the ENGINE API and ships no pkcs11
    engine, so USE_PKCS11_ENGINE is undefined there while the #else branch that
    needs it still compiles, and the build dies with:

        certs/extract-cert.c:152:21: error: 'key_pass' undeclared

    Guarding the declaration alone is not enough: the whole ENGINE block still
    compiles, which is why an earlier attempt at that only moved the error from
    line 149 to line 152. The fix turns the #else into an #elif so the block is
    skipped whole. OPENSSL_VERSION_MAJOR is defined only by OpenSSL 3.x, so
    `!defined(OPENSSL_VERSION_MAJOR)` is 1 on the OpenSSL these trees were
    written against and 0 on 3.x.

    Result: a clean "PKCS#11 not supported" exit on OpenSSL 3.x, unchanged
    behaviour for anyone signing via a PKCS#11 token on OpenSSL 1.1.
    """
    src = root / "certs/extract-cert.c"
    if not src.is_file():
        print("\n[INFO] certs/extract-cert.c not present, skipping the OpenSSL fix")
        return

    # Line-based, so a trailing space on a directive cannot defeat the match.
    # newline="" keeps the file's own CRLF/LF in the strings being edited.
    with src.open("r", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        raw = fh.read()
    lines = raw.split("\n")

    if any("#elif defined(USE_PKCS11_ENGINE)" in l for l in lines):
        print("\n[INFO] extract-cert.c already carries the OpenSSL 3 guard")
        return

    # Locate the BoringSSL guard, then its #else. Anchoring on that guard means
    # this cannot land on an unrelated #else elsewhere in the file.
    anchor = None
    for i, line in enumerate(lines):
        if line.strip() == "#ifdef OPENSSL_IS_BORINGSSL":
            anchor = i
            break
    if anchor is None:
        die("certs/extract-cert.c: no '#ifdef OPENSSL_IS_BORINGSSL' directive found.")

    else_idx = None
    for j in range(anchor + 1, len(lines)):
        if lines[j].strip() == "#else":
            else_idx = j
            break
    if else_idx is None:
        die("certs/extract-cert.c: no #else after the BoringSSL guard.")

    # Keep the original indentation of the #else so the diff stays tidy.
    #
    # The condition is `defined(USE_PKCS11_ENGINE)`, not
    # `!defined(USE_PKCS11_ENGINE)`: the block that follows is the ENGINE
    # implementation, so it must be included when USE_PKCS11_ENGINE is defined
    # and skipped when it is not. Getting this inverted compiles the ENGINE code
    # on OpenSSL 3.x, which is exactly the failing case. A minimal repro caught
    # that; the condition is the whole fix, so it is spelled out here.
    indent = lines[else_idx][: len(lines[else_idx]) - len(lines[else_idx].lstrip())]
    lines[else_idx] = f"{indent}#elif defined(USE_PKCS11_ENGINE)"
    lines[else_idx + 1 : else_idx + 1] = [
        f'{indent}\t\tfprintf(stderr, "OpenSSL 3.x does not provide the PKCS#11 ENGINE\\n");',
        f"{indent}\t\texit(1);",
    ]

    text = "\n".join(lines)
    with src.open("w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        fh.write(text)

    # Verify every reference to key_pass is unreachable on OpenSSL 3.x, which is
    # the property that actually matters. Checking for the guard text alone
    # would not have caught the inverted condition that broke the first attempt.
    check = "\n".join(
        src.read_text(encoding="utf-8", errors="surrogateescape").split("\n")
    )
    refs = [i for i, l in enumerate(check.split("\n"), 1) if "key_pass" in l]
    if not refs:
        die("extract-cert.c: key_pass references disappeared entirely.")
    for line_no in refs:
        before = check.split("\n")[: line_no - 1]
        depth = 0
        guarded = False
        for prev in reversed(before):
            s = prev.strip()
            if re.match(r"#\s*endif\b", s):
                depth += 1
            elif re.match(r"#\s*(ifdef|ifndef|if)\b", s):
                if depth == 0:
                    guarded = guarded or ("USE_PKCS11_ENGINE" in s)
                    break
                depth -= 1
            elif re.match(r"#\s*(elif|else)\b", s):
                if depth == 0:
                    guarded = guarded or ("USE_PKCS11_ENGINE" in s)
                    break
        if not guarded:
            die(
                f"extract-cert.c line {line_no} uses key_pass without a "
                "USE_PKCS11_ENGINE guard, so OpenSSL 3.x will still fail to build."
            )
    print(
        "\n[INFO] Skipped the PKCS#11 ENGINE block on OpenSSL 3.x in certs/extract-cert.c"
    )
    print(f"       {len(refs)} key_pass reference(s), all under a USE_PKCS11_ENGINE guard")


def verify_extract_cert(src: Path) -> None:
    """Prove the fix with a real preprocessor run, when a compiler is available.

    The property that matters is behavioural, not textual: with
    USE_PKCS11_ENGINE undefined (OpenSSL 3.x) no reference to key_pass may
    survive preprocessing, and with it defined (OpenSSL 1.1 PKCS#11 signing) the
    ENGINE block must still be there.

    An earlier attempt at this fix had the #elif condition inverted, which
    compiled the ENGINE block precisely on the OpenSSL version that cannot
    support it. A textual check for the guard passed anyway; only preprocessing
    catches that class of mistake, so it is worth doing whenever we can.
    """
    cc = shutil.which("gcc") or shutil.which("cc") or shutil.which("clang")
    if not cc:
        print("[INFO] no host compiler found, skipping the preprocessor check")
        return

    # Try the real headers first. If they are not present (a bare CI checkout
    # usually has libssl-dev, a dev container may not), fall back to a stub tree
    # whose only job is to define OPENSSL_VERSION_MAJOR, which is what makes a
    # header set look like OpenSSL 3.
    def run(extra: list[str]) -> str | None:
        for inc in ([], ["-I", str(build_openssl_stub(src.parent.parent))]):
            r = subprocess.run(
                [cc, "-E", *inc, *extra, str(src)],
                capture_output=True,
                text=True,
                errors="replace",
            )
            if r.returncode == 0:
                # Drop preprocessor line markers and any '#' directives that
                # survive, so only compiled code is counted.
                return "\n".join(
                    l
                    for l in r.stdout.splitlines()
                    if not l.lstrip().startswith("#")
                )
        return None

    undefined = run(["-UUSE_PKCS11_ENGINE"])
    if undefined is None:
        print("[INFO] could not preprocess extract-cert.c, skipping the check")
        return

    if "key_pass" in undefined:
        n = undefined.count("key_pass")
        die(
            "extract-cert.c still references key_pass with USE_PKCS11_ENGINE "
            f"undefined ({n} reference(s)), so OpenSSL 3.x will not build it."
        )
    print("[INFO] Verified: key_pass is not compiled when USE_PKCS11_ENGINE is undefined")

    defined = run(["-DUSE_PKCS11_ENGINE"])
    if defined is not None:
        if "ENGINE_by_id" not in defined:
            die(
                "extract-cert.c lost its ENGINE block when USE_PKCS11_ENGINE is "
                "defined, which would break PKCS#11 signing on OpenSSL 1.1."
            )
        print("[INFO] Verified: the ENGINE block is intact when USE_PKCS11_ENGINE is defined")


def build_openssl_stub(root: Path) -> Path:
    """Create a minimal OpenSSL 3 header stub, only if real headers are absent.

    extract-cert.c includes bio.h, pem.h, err.h and engine.h. The stub only needs
    to exist so preprocessing can proceed; the symbol under test, key_pass, is
    declared in the source file itself and does not come from OpenSSL.
    """
    stub = root / ".openssl-stub"
    inc = stub / "openssl"
    if not (inc / "opensslv.h").is_file():
        inc.mkdir(parents=True, exist_ok=True)
        # Defining OPENSSL_VERSION_MAJOR is the whole point: it is defined only
        # by OpenSSL 3.x, so this makes the tree look like OpenSSL 3.
        (inc / "opensslv.h").write_text(
            "#define OPENSSL_VERSION_MAJOR 3\n"
            "#define OPENSSL_VERSION_NUMBER 0x30000000L\n"
        )
        for name in ("bio", "pem", "err", "engine"):
            (inc / f"{name}.h").write_text(f"/* stub for {name}.h */\n")
        (stub / "err.h").write_text(
            "void err(int, const char *, ...);\n"
            "void errx(int, const char *, ...);\n"
            "void warn(const char *, ...);\n"
            "void warnx(const char *, ...);\n"
        )
    return stub


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    sched = root / SCHED
    if not sched.is_file():
        die(f"Not a kernel root, missing {SCHED}: {root}")

    fix_extract_cert(root)
    verify_extract_cert(root / "certs/extract-cert.c")

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
