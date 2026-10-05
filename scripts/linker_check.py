#!/usr/bin/env python3
"""
linker_check.py - cek dependensi linker (DT_NEEDED) ELF vendor/odm terhadap
library yang tersedia di ROM port (vendor/odm sendiri, system/LLNDK, dan
library di dalam APEX seperti VNDK).

  linker_check.py --check DIR [--check DIR ...]
                  --provide DIR [--provide DIR ...]
                  --apex DIR [--apex DIR ...]
                  [--erofs-extract PATH] [--top N]

Output: ringkasan + daftar library yang dibutuhkan tapi tidak ditemukan,
dipisah 64-bit / 32-bit, dengan contoh file yang membutuhkan.
Exit code selalu 0 (informasi, bukan penentu build).
"""
import argparse
import io
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from collections import defaultdict

PT_LOAD, PT_DYNAMIC = 1, 2
EM_QDSP6 = 164          # Hexagon DSP (adsp/cdsp/HTP skel): dimuat di DSP, bukan oleh linker Android
DSP_SKIPPED = [0]
DT_NULL, DT_NEEDED, DT_STRTAB = 0, 1, 5


def elf_needed(path):
    """(bits, [needed]) atau None kalau bukan ELF dinamis"""
    try:
        with open(path, "rb") as f:
            ident = f.read(16)
            if len(ident) < 16 or ident[:4] != b"\x7fELF":
                return None
            cls, data = ident[4], ident[5]
            if data != 1:  # hanya little-endian
                return None
            e = "<"
            f.seek(18)
            if struct.unpack(e + "H", f.read(2))[0] == EM_QDSP6:
                DSP_SKIPPED[0] += 1
                return None
            if cls == 2:
                f.seek(0x20); phoff = struct.unpack(e + "Q", f.read(8))[0]
                f.seek(0x36); phentsize, phnum = struct.unpack(e + "HH", f.read(4))
                bits = 64
            elif cls == 1:
                f.seek(0x1C); phoff = struct.unpack(e + "I", f.read(4))[0]
                f.seek(0x2A); phentsize, phnum = struct.unpack(e + "HH", f.read(4))
                bits = 32
            else:
                return None
            loads, dyn = [], None
            for i in range(phnum):
                f.seek(phoff + i * phentsize)
                if bits == 64:
                    p_type, _fl, p_off, p_vaddr, _pa, p_filesz, _msz, _al = struct.unpack(e + "IIQQQQQQ", f.read(56))
                else:
                    p_type, p_off, p_vaddr, _pa, p_filesz, _msz, _fl, _al = struct.unpack(e + "IIIIIIII", f.read(32))
                if p_type == PT_LOAD:
                    loads.append((p_vaddr, p_off, p_filesz))
                elif p_type == PT_DYNAMIC:
                    dyn = (p_off, p_filesz)
            if dyn is None:
                return (bits, [])
            f.seek(dyn[0])
            raw = f.read(dyn[1])
            ent = 16 if bits == 64 else 8
            fmt = e + ("qQ" if bits == 64 else "iI")
            needed_off, strtab = [], None
            for i in range(0, len(raw) - ent + 1, ent):
                tag, val = struct.unpack(fmt, raw[i:i + ent])
                if tag == DT_NULL:
                    break
                if tag == DT_NEEDED:
                    needed_off.append(val)
                elif tag == DT_STRTAB:
                    strtab = val
            if strtab is None:
                return (bits, [])
            str_off = None
            for vaddr, off, sz in loads:
                if vaddr <= strtab < vaddr + sz:
                    str_off = off + (strtab - vaddr)
                    break
            if str_off is None:
                return (bits, [])
            out = []
            for o in needed_off:
                f.seek(str_off + o)
                s = f.read(256).split(b"\0", 1)[0].decode("utf-8", "replace")
                out.append(s)
            return (bits, out)
    except (OSError, struct.error):
        return None


def collect_provided(dirs, lib64, lib32):
    for d in dirs:
        for root, _dirs, files in os.walk(d):
            parts = os.path.relpath(root, d).replace("\\", "/").split("/")
            for fn in files:
                if not fn.endswith(".so"):
                    continue
                if "lib64" in parts:
                    lib64.add(fn)
                elif "lib" in parts:
                    lib32.add(fn)
                else:                       # di luar folder lib/lib64: anggap tersedia untuk keduanya
                    lib64.add(fn); lib32.add(fn)


def payload_libs(payload, extract_erofs, lib64, lib32):
    """isi library dari apex_payload.img (ext4 atau erofs)"""
    tmpd = tempfile.mkdtemp(prefix="apex_")
    try:
        img = os.path.join(tmpd, "payload.img")
        with open(img, "wb") as f:
            f.write(payload)
        is_ext = len(payload) > 1082 and payload[1080:1082] == b"\x53\xef"
        is_erofs = len(payload) > 1028 and struct.unpack("<I", payload[1024:1028])[0] == 0xE0F5E1E2
        for sub, target in (("lib64", lib64), ("lib", lib32)):
            names = []
            if is_ext:
                r = subprocess.run(["debugfs", "-R", "ls -p /" + sub, img],
                                   capture_output=True, text=True)
                for line in r.stdout.splitlines():
                    parts = line.strip("/").split("/")
                    if len(parts) >= 5 and parts[4].endswith(".so"):
                        names.append(parts[4])
            elif is_erofs and extract_erofs:
                out = os.path.join(tmpd, "x_" + sub)
                os.makedirs(out, exist_ok=True)
                subprocess.run([extract_erofs, "-i", img, "-X", sub, "-o", out],
                               capture_output=True)
                for root, _d, files in os.walk(out):
                    names += [fn for fn in files if fn.endswith(".so")]
            target.update(names)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def collect_apex(dirs, extract_erofs, lib64, lib32, found):
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            p = os.path.join(d, fn)
            if not (fn.endswith(".apex") or fn.endswith(".capex")) or not os.path.isfile(p):
                continue
            try:
                with zipfile.ZipFile(p) as z:
                    if fn.endswith(".capex"):
                        with zipfile.ZipFile(io.BytesIO(z.read("original_apex"))) as z2:
                            payload = z2.read("apex_payload.img")
                    else:
                        payload = z.read("apex_payload.img")
                payload_libs(payload, extract_erofs, lib64, lib32)
                found.append(fn)
            except (KeyError, zipfile.BadZipFile, OSError):
                continue


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="append", default=[])
    ap.add_argument("--provide", action="append", default=[])
    ap.add_argument("--apex", action="append", default=[])
    ap.add_argument("--erofs-extract", default="")
    ap.add_argument("--top", type=int, default=30)
    a = ap.parse_args()

    lib64, lib32, apexes = set(), set(), []
    collect_provided(a.provide + a.check, lib64, lib32)
    collect_apex(a.apex, a.erofs_extract, lib64, lib32, apexes)

    missing = {64: defaultdict(list), 32: defaultdict(list)}
    scanned = 0
    for d in a.check:
        for root, _dirs, files in os.walk(d):
            for fn in files:
                p = os.path.join(root, fn)
                if os.path.islink(p):
                    continue
                r = elf_needed(p)
                if not r:
                    continue
                scanned += 1
                bits, needed = r
                have = lib64 if bits == 64 else lib32
                for n in needed:
                    if n not in have:
                        missing[bits][n].append(os.path.relpath(p, os.path.dirname(d)))

    print("ELF diperiksa: %d (+%d ELF DSP Hexagon dilewati) | library tersedia: %d (64-bit) %d (32-bit) | APEX dibaca: %d"
          % (scanned, DSP_SKIPPED[0], len(lib64), len(lib32), len(apexes)))
    for bits in (64, 32):
        items = sorted(missing[bits].items(), key=lambda kv: -len(kv[1]))
        if not items:
            print("%d-bit: semua dependensi ditemukan" % bits)
            continue
        print("%d-bit: %d library TIDAK ditemukan" % (bits, len(items)))
        for name, users in items[:a.top]:
            ex = ", ".join(users[:2])
            print("  MISSING %-40s dipakai %3d file (mis. %s)" % (name, len(users), ex))
        if len(items) > a.top:
            print("  ... %d lainnya" % (len(items) - a.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
