#!/usr/bin/env python3
"""
rc_disable32.py - nonaktifkan service init vendor/odm yang binary-nya ELF 32-bit, untuk
ROM donor 64-bit only (tidak ada /system/lib, linker32, libc 32-bit -> binary 32-bit
tidak bisa jalan sama sekali).

  rc_disable32.py --exe /vendor/bin/foo [--exe ...] <dir rc> [<dir rc> ...]

Untuk setiap "service <nama> <exe 32-bit>":
  - tambah "disabled" (tidak ikut start lewat class)
  - "critical" dan "reboot_on_failure ..." dijadikan komentar (gagal start TIDAK boleh
    memicu reboot / bootloop; contoh boringssl_self_test32 punya reboot_on_failure)
Di semua rc: baris "start|restart|exec_start <nama>" dan "exec ... <exe 32-bit>" dijadikan komentar.
Baris yang diubah diberi penanda "# [port-64only]". Output satu baris per perubahan, lalu
"RESULT <service> <baris>".
"""
import argparse
import os
import re
import sys

TAG = "# [port-64only] "
SECTION = re.compile(r"^(service|on|import)\s")


def rc_files(dirs):
    for d in dirs:
        for dp, _dns, fns in os.walk(d):
            for fn in sorted(fns):
                if fn.endswith(".rc"):
                    yield os.path.join(dp, fn)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", action="append", default=[])
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    exes = set(a.exe)
    files = list(rc_files(a.dirs))

    # 1) cari service yang menjalankan exe 32-bit
    services = {}
    for f in files:
        for line in open(f, encoding="utf-8", errors="surrogateescape"):
            p = line.split()
            if len(p) >= 3 and p[0] == "service" and p[2] in exes:
                services[p[1]] = p[2]

    n_lines = 0
    for f in files:
        lines = open(f, encoding="utf-8", errors="surrogateescape").read().split("\n")
        out, cur, changed, has_disabled = [], None, False, {}
        for i, line in enumerate(lines):
            s = line.strip()
            p = s.split()
            if SECTION.match(line):
                cur = p[1] if p[0] == "service" and len(p) > 1 and p[1] in services else None
                out.append(line)
                if cur:
                    nxt = [l.strip() for l in lines[i + 1:]]
                    block = []
                    for l2 in nxt:
                        if SECTION.match(l2) and not l2.startswith("#"):
                            break
                        block.append(l2)
                    if not any(l.split()[:1] == ["disabled"] for l in block):
                        out.append("    " + TAG + "binary 32-bit, system donor 64-bit only")
                        out.append("    disabled")
                        print("  %s: service %s -> disabled" % (f, cur))
                        changed = True
                        n_lines += 1
                continue
            if cur and p and p[0] in ("critical", "reboot_on_failure"):
                out.append(TAG + line.lstrip())
                print("  %s: service %s: '%s' dimatikan" % (f, cur, s))
                changed = True
                n_lines += 1
                continue
            if not cur and p and (
                (p[0] in ("start", "restart", "exec_start") and len(p) > 1 and p[1] in services)
                or (p[0] == "exec" and any(x in exes for x in p))
            ):
                out.append(TAG + line.lstrip())
                print("  %s: '%s' dimatikan" % (f, s))
                changed = True
                n_lines += 1
                continue
            out.append(line)
        if changed:
            with open(f, "w", encoding="utf-8", errors="surrogateescape") as fo:
                fo.write("\n".join(out))
    for name, exe in sorted(services.items()):
        print("SERVICE %s %s" % (name, exe))
    print("RESULT %d %d" % (len(services), n_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
