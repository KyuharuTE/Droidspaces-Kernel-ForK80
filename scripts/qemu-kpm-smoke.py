#!/usr/bin/env python3
"""Boot existing arm64 images in QEMU and exercise real KPM supercalls.

Runs entirely in disposable initramfs; never flashes a device. QEMU success
does not establish vendor hardware compatibility. Keys are redacted from logs.
"""
import argparse
import gzip
import hashlib
import json
import re
import stat
import subprocess
from pathlib import Path

INIT = r'''
static long call(long n,long a,long b,long c,long d,long e,long f) {
 register long x0 asm("x0")=a,x1 asm("x1")=b,x2 asm("x2")=c;
 register long x3 asm("x3")=d,x4 asm("x4")=e,x5 asm("x5")=f,x8 asm("x8")=n;
 asm volatile("svc #0":"+r"(x0):"r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x5),"r"(x8):"memory");return x0;
}
static void say(const char *s) {long n=0;while(s[n])n++;call(64,1,(long)s,n,0,0,0);}
static void number(long v) {char b[24];int n=0;if(v<0){say("-");v=-v;}do{b[n++]='0'+v%10;v/=10;}while(v);while(n)call(64,1,(long)&b[--n],1,0,0,0);say("\n");}
static char key[65],control[256],rcbuf[4096];static unsigned long version=0xd09;
static long sc(long cmd,long a,long b,long c,long d) {return call(45,(long)key,(version<<32)|(0x1158UL<<16)|cmd,a,b,c,d);}
void _start(void) {
 say("SMOKE_INIT_REACHED\n");
 long rcf=call(56,-100,(long)"/system/etc/init/hw/init.rc",0,0,0,0);
 long rcn=call(63,rcf,(long)rcbuf,sizeof(rcbuf),0,0,0);call(57,rcf,0,0,0,0,0);
 say("SMOKE_INIT_RC_BYTES=");number(rcn);
 const char expected_rc[]="DROIDSPACES_ORIGINAL_INIT_RC_OK\n";
 int rc_ok=rcn==sizeof(expected_rc)-1;
 for(long i=0;i<rcn && i<sizeof(expected_rc)-1;i++)if(rcbuf[i]!=expected_rc[i])rc_ok=0;
 if(rc_ok)say("SMOKE_ORIGINAL_INIT_PASS\n");
 long fd=call(56,-100,(long)"/key",0,0,0,0);call(63,fd,(long)key,64,0,0,0);call(57,fd,0,0,0,0,0);
 long hello=sc(0x1000,0,0,0,0);say("SMOKE_HELLO=");number(hello);
 if(hello==0x11581158){version=sc(0x1008,0,0,0,0);say("SMOKE_VERSION=");number(version);
 long load=sc(0x1020,(long)"/demo.kpm",(long)"qemu",0,0);say("SMOKE_LOAD=");number(load);
 long nums=sc(0x1030,0,0,0,0);say("SMOKE_NUMS=");number(nums);
 long ctl=sc(0x1022,(long)"kpm-nbdemo",(long)"smoke",(long)control,sizeof(control));say("SMOKE_CONTROL=");number(ctl);say(control);say("\n");
 long unload=sc(0x1021,(long)"kpm-nbdemo",0,0,0);say("SMOKE_UNLOAD=");number(unload);
 long finalnums=sc(0x1030,0,0,0,0);say("SMOKE_FINAL_NUMS=");number(finalnums);
 if(load==0 && nums==1 && ctl==0 && control[0]=='e' && unload==0 && finalnums==0)say("SMOKE_KPM_PASS\n");}
 long ns=call(97,0x20000|0x04000000|0x08000000|0x20000000,0,0,0,0,0);say("SMOKE_NAMESPACES=");number(ns);
 call(34,-100,(long)"/cgroup",0755,0,0,0);
 long cg=call(40,(long)"cgroup2",(long)"/cgroup",(long)"cgroup2",0,0,0);say("SMOKE_CGROUP2=");number(cg);
 long dev=call(40,(long)"devtmpfs",(long)"/dev",(long)"devtmpfs",0,0,0);say("SMOKE_DEVTMPFS=");number(dev);
 if(ns==0 && cg==0 && dev==0)say("SMOKE_CONTAINER_PASS\n");
 say("SMOKE_DONE\n");call(142,0xfee1dead,672274793,0x4321fedc,0,0,0);for(;;)asm volatile("wfe");
}
'''


def archive(entries):
    result = bytearray()
    for inode, (name, data, mode, major, minor) in enumerate(entries, 1):
        encoded = name.encode() + b"\0"
        fields = [inode, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(encoded), 0]
        result += b"070701" + b"".join(f"{v:08x}".encode() for v in fields) + encoded
        result += b"\0" * (-len(result) % 4)
        result += data
        result += b"\0" * (-len(result) % 4)
    return gzip.compress(result, mtime=0)


def run(root, images, timeout, memory=1536, el1=False, kaslr=False):
    work = root / ".cache/qemu-kpm"
    work.mkdir(parents=True, exist_ok=True)
    (work / "init.c").write_text(INIT)
    subprocess.run(["aarch64-linux-gnu-gcc", "-O2", "-fno-builtin", "-nostdlib", "-static", "-fno-pie", "-no-pie",
                    "-fno-stack-protector", "-Wl,-e,_start", "-o", str(work / "init"), str(work / "init.c")], check=True)
    demo = root / "dist/kpm/nbdemo.kpm"
    subprocess.run(["bash", "scripts/build-kpm.sh", "kpms/nbdemo", str(demo)], cwd=root, check=True,
                   stdout=subprocess.DEVNULL)
    results = []
    for index, image in enumerate(images):
        listing = subprocess.run([str(root / ".kp/KernelPatch/tools/kptools"), "-l", "--show-secrets", "-i", str(image)],
                                 capture_output=True).stdout.decode(errors="replace")
        match = re.search(r"^superkey=(.*)$", listing, re.M)
        key = match.group(1).strip() if match else "invalid-test-key"
        if key == "<redacted>":
            raise RuntimeError("Tool redacts key; use a test-key image or an explicit key file")
        initrd = work / f"initrd-{index}.gz"
        initrd.write_bytes(archive([
            ("dev", b"", stat.S_IFDIR | 0o755, 0, 0),
            ("dev/console", b"", stat.S_IFCHR | 0o600, 5, 1),
            ("system", b"", stat.S_IFDIR | 0o755, 0, 0),
            ("system/etc", b"", stat.S_IFDIR | 0o755, 0, 0),
            ("system/etc/init", b"", stat.S_IFDIR | 0o755, 0, 0),
            ("system/etc/init/hw", b"", stat.S_IFDIR | 0o755, 0, 0),
            ("system/etc/init/hw/init.rc", b"DROIDSPACES_ORIGINAL_INIT_RC_OK\n", stat.S_IFREG | 0o644, 0, 0),
            ("init", (work / "init").read_bytes(), stat.S_IFREG | 0o755, 0, 0),
            ("key", key.encode(), stat.S_IFREG | 0o600, 0, 0),
            ("demo.kpm", demo.read_bytes(), stat.S_IFREG | 0o644, 0, 0),
            ("TRAILER!!!", b"", 0, 0, 0)]))
        initrd.chmod(0o600)
        cmd = ["qemu-system-aarch64", "-machine", f"virt,virtualization={'off' if el1 else 'on'},gic-version=3", "-cpu", "max",
               "-m", str(memory), "-smp", "2", "-nic", "none", "-nographic", "-no-reboot", "-kernel", str(image),
               "-initrd", str(initrd), "-append", "console=ttyAMA0 earlycon=pl011,0x9000000 rdinit=/init panic=-1" + ("" if kaslr else " nokaslr")]
        print(f"Booting {image.name}", flush=True)
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
            log, code = proc.stdout, proc.returncode
        except subprocess.TimeoutExpired as exc:
            log, code = exc.stdout or b"", "timeout"
        text = log.decode(errors="replace").replace(key, "<redacted>")
        logpath = work / f"{image.name}-{hashlib.sha256(image.read_bytes()).hexdigest()[:12]}-{memory}-el{1 if el1 else 2}-kaslr{int(kaslr)}.log"
        logpath.write_text(text)
        item = dict(image=str(image), memory=memory, el=1 if el1 else 2, kaslr=kaslr, returncode=code, init_reached="SMOKE_INIT_REACHED" in text,
                    kpm_pass="SMOKE_KPM_PASS" in text, container_pass="SMOKE_CONTAINER_PASS" in text,
                    original_init_pass="SMOKE_ORIGINAL_INIT_PASS" in text, log=str(logpath))
        results.append(item)
        logpath.with_suffix(".json").write_text(json.dumps(item, indent=2))
        print(json.dumps(item), flush=True)
        print("\n".join(text.splitlines()[-25:]), flush=True)
    (work / "results.json").write_text(json.dumps(results, indent=2))
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="+", type=Path)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--memory", type=int, default=1536, help="Guest RAM in MiB")
    parser.add_argument("--el1", action="store_true")
    parser.add_argument("--kaslr", action="store_true")
    parser.add_argument("--require-kpm", action="store_true", help="Return failure unless every image boots and passes KPM and container probes")
    parser.add_argument("--require-original-init", action="store_true")
    args = parser.parse_args()
    results = run(args.root.resolve(), [p.resolve() for p in args.images], args.timeout, args.memory, args.el1, args.kaslr)
    if args.require_kpm and not all(item['returncode'] == 0 and item['kpm_pass'] and item['container_pass'] for item in results):
        raise SystemExit(1)
    if args.require_original_init and not all(item['original_init_pass'] for item in results):
        raise SystemExit(1)
