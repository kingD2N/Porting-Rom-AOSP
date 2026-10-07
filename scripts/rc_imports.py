#!/usr/bin/env python3
"""
rc_imports.py - cek import rc system yang bergantung pada property, seperti yang dilakukan
init saat boot:

    import /system/etc/init/hw/init.${ro.zygote}.rc
    import /system/etc/init/hw/mediaserver.64bit_${ro.mediaserver.64b.enable:-false}.rc   (QTI)

Nilai property diambil dari build.prop (urutan muat init: yang belakangan menang). Untuk tiap
import: file tujuan harus ada, dan binary service di dalamnya harus ada di system.

  rc_imports.py SYSTEM_ROOT PROPFILE... [--set KEY=VAL ...]
    SYSTEM_ROOT = folder isi /system (mis. work/port/fs/system/system)

Output per baris:
  OK      <rc> -> <tujuan>
  MISSING <rc> -> <tujuan>                    (file import tidak ada)
  NOEXEC  <rc> -> <tujuan> service <nama> <binary>   (binary service tidak ada)
  RESULT <jumlah_import> <jumlah_masalah>
"""
import os
import re
import sys

VAR = re.compile(r'\$\{([A-Za-z0-9_.\-]+)(?::-([^}]*))?\}')


def load_props(files, sets):
    props = {}
    for f in files:
        try:
            for line in open(f, encoding="utf-8", errors="replace"):
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
        except OSError:
            pass
    props.update(sets)
    return props


def expand(s, props):
    def sub(m):
        v = props.get(m.group(1), "")
        if v == "" and m.group(2) is not None:
            v = m.group(2)
        return v
    return VAR.sub(sub, s)


def to_local(sysroot, path):
    if path.startswith("/system/"):
        return os.path.join(sysroot, path[len("/system/"):])
    return None


def main():
    args = sys.argv[1:]
    sets = {}
    files = []
    i = 0
    while i < len(args):
        if args[i] == "--set":
            k, _, v = args[i + 1].partition("=")
            sets[k] = v
            i += 2
            continue
        files.append(args[i])
        i += 1
    sysroot, files = files[0], files[1:]
    props = load_props(files, sets)
    total = bad = 0
    initdir = os.path.join(sysroot, "etc", "init")
    for root, _d, names in os.walk(initdir):
        for n in sorted(names):
            if not n.endswith(".rc"):
                continue
            rc = os.path.join(root, n)
            rel = os.path.relpath(rc, sysroot)
            try:
                lines = open(rc, encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                continue
            for line in lines:
                s = line.strip()
                if not s.startswith("import ") or "${" not in s:
                    continue
                tgt = expand(s.split(None, 1)[1].strip(), props)
                local = to_local(sysroot, tgt)
                if local is None:
                    continue
                total += 1
                if not os.path.isfile(local):
                    bad += 1
                    print("MISSING %s -> %s" % (rel, tgt))
                    continue
                ok = True
                for l2 in open(local, encoding="utf-8", errors="replace"):
                    p = l2.split()
                    if len(p) >= 3 and p[0] == "service":
                        exe = to_local(sysroot, p[2])
                        if exe and not os.path.exists(exe):
                            ok = False
                            bad += 1
                            print("NOEXEC %s -> %s service %s %s" % (rel, tgt, p[1], p[2]))
                if ok:
                    print("OK %s -> %s" % (rel, tgt))
    print("RESULT %d %d" % (total, bad))
    return 0


if __name__ == "__main__":
    sys.exit(main())
