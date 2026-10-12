#!/usr/bin/env python3
"""
kernel_crc.py - cek apakah kernel custom bisa memuat modul vendor (.ko) ROM base, tanpa
Module.symvers: CRC simbol (CONFIG_MODVERSIONS) dibaca langsung dari Image kernel lewat kallsyms,
lalu dibandingkan dengan CRC yang diminta tiap modul (section __versions).

  kernel_crc.py dump   KERNEL_IMAGE                     -> "<crc> <simbol>" semua simbol ekspor
  kernel_crc.py check  KERNEL_IMAGE [--base KERNEL_BASE] (DIR|.ko|.json)...
                                                        -> laporan kecocokan modul. Dengan --base:
                                                           yang dihitung gagal hanya modul yang bisa
                                                           dimuat kernel base tapi tidak oleh kernel ini
  kernel_crc.py vbmods VENDOR_BOOT_IMG OUTDIR           -> ekstrak *.ko dari ramdisk vendor_boot (v3/v4,
                                                           semua fragmen, lz4-legacy/gzip/raw)

KERNEL_IMAGE = Image mentah (hasil `magiskboot unpack` boot.img, file "kernel") atau boot.img.
.json = referensi CRC format verify_miui14_compat.py ({simbol: {crc, needed_by}}).
Butuh paket vmlinux-to-elf (kallsyms-finder). Exit 0 = cocok, 3 = ada modul yang gagal dimuat,
2 = tidak bisa dibaca (dianggap informasi, bukan vonis).

Aturan load modul kernel (CONFIG_MODVERSIONS): vermagic dibandingkan TANPA versi kernel
(5.10.81 vs 5.10.271 tidak masalah), tapi setiap simbol yang dipakai modul harus diekspor kernel
dengan CRC sama; beda = "disagrees about version of symbol" dan modul gagal dimuat.
"""
import json
import os
import re
import struct
import subprocess
import sys
import tempfile

SECT = ("__start___ksymtab", "__stop___ksymtab", "__start___ksymtab_gpl", "__stop___ksymtab_gpl",
        "__start___kcrctab", "__stop___kcrctab", "__start___kcrctab_gpl", "__stop___kcrctab_gpl")


def kernel_from(path):
    with open(path, "rb") as f:
        head = f.read(8)
    if head != b"ANDROID!":
        return path, None
    # boot.img v3/v4: header 4096 byte, kernel mulai di page berikutnya
    with open(path, "rb") as f:
        hdr = f.read(4096)
    ksize = struct.unpack_from("<I", hdr, 8)[0]
    ver = struct.unpack_from("<I", hdr, 40)[0]
    if ver < 3:
        page = struct.unpack_from("<I", hdr, 36)[0]
    else:
        page = 4096
    tmp = tempfile.NamedTemporaryFile(prefix="kernel_", delete=False)
    with open(path, "rb") as f:
        f.seek(page)
        tmp.write(f.read(ksize))
    tmp.close()
    return tmp.name, tmp.name


def kallsyms(image):
    try:
        out = subprocess.run(["kallsyms-finder", image], capture_output=True, text=True, timeout=900).stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        raise SystemExit("kallsyms-finder tidak bisa dijalankan (%s); pip install vmlinux-to-elf" % e)
    syms = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3 and p[2] in SECT + ("_text",):
            syms[p[2]] = int(p[0], 16)
    return syms


def exports(image):
    syms = kallsyms(image)
    miss = [s for s in SECT + ("_text",) if s not in syms]
    if miss:
        raise SystemExit("kallsyms tanpa %s (kernel tanpa CONFIG_KALLSYMS/MODVERSIONS?)" % ", ".join(miss))
    data = open(image, "rb").read()
    base = syms["_text"]
    out = {}
    for tab, crc in (("__ksymtab", "__kcrctab"), ("__ksymtab_gpl", "__kcrctab_gpl")):
        s0, s1 = syms["__start_" + tab] - base, syms["__stop_" + tab] - base
        c0, c1 = syms["__start_" + crc] - base, syms["__stop_" + crc] - base
        n = (c1 - c0) // 4
        if n <= 0 or (s1 - s0) % n:
            raise SystemExit("ukuran %s/%s tidak cocok" % (tab, crc))
        ent = (s1 - s0) // n          # 12 = PREL32 (value, name, namespace), 24 = alamat absolut
        for i in range(n):
            e = s0 + i * ent
            if ent == 12:
                noff = struct.unpack_from("<i", data, e + 4)[0]
                name_at = e + 4 + noff
            else:
                name_at = struct.unpack_from("<Q", data, e + 8)[0] - base
            if not 0 <= name_at < len(data):
                continue
            name = data[name_at:data.index(b"\0", name_at)].decode("ascii", "replace")
            out[name] = struct.unpack_from("<I", data, c0 + i * 4)[0]
    return out


def ko_versions(path):
    """CRC yang diminta modul: section __versions (struct modversion_info: u32/u64 crc + nama 56/60 byte)"""
    try:
        d = open(path, "rb").read()
    except OSError:
        return {}
    if d[:4] != b"\x7fELF" or d[4] != 2:
        return {}
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    secs = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shentsize) for i in range(shnum)]
    stroff = secs[shstrndx][4]
    for s in secs:
        name = d[stroff + s[0]:d.index(b"\0", stroff + s[0])]
        if name == b"__versions":
            off, size = s[4], s[5]
            req = {}
            for i in range(0, size, 64):   # arm64: unsigned long crc (8) + char name[56]
                crc = struct.unpack_from("<Q", d, off + i)[0] & 0xFFFFFFFF
                nm = d[off + i + 8:off + i + 64].split(b"\0", 1)[0].decode("ascii", "replace")
                if nm:
                    req[nm] = crc
            return req
    return {}


def ko_exports(path):
    """nama simbol yang diekspor modul sendiri (section __ksymtab_strings)"""
    try:
        d = open(path, "rb").read()
    except OSError:
        return set()
    if d[:4] != b"\x7fELF" or d[4] != 2:
        return set()
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    secs = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shentsize) for i in range(shnum)]
    stroff = secs[shstrndx][4]
    for s in secs:
        if d[stroff + s[0]:d.index(b"\0", stroff + s[0])] == b"__ksymtab_strings":
            return {x.decode("ascii", "replace") for x in d[s[4]:s[4] + s[5]].split(b"\0") if x}
    return set()


def wanted(paths):
    want = {}    # simbol -> (crc, set(modul))
    for p in paths:
        if p.endswith(".json"):
            for sym, info in json.load(open(p)).items():
                want.setdefault(sym, [int(info["crc"], 16), set()])[1].update(info.get("needed_by", []))
            continue
        files = [p] if os.path.isfile(p) else [os.path.join(r, f) for r, _d, fs in os.walk(p) for f in fs if f.endswith(".ko")]
        for f in files:
            MOD_EXPORTS.update(ko_exports(f))
            for sym, crc in ko_versions(f).items():
                w = want.setdefault(sym, [crc, set()])
                w[1].add(os.path.basename(f))
    return want


MOD_EXPORTS = set()


def failing(exp, want):
    bad, miss, mods_bad = [], [], set()
    for sym, (crc, mods) in sorted(want.items()):
        if sym not in exp:
            if sym in MOD_EXPORTS:      # diekspor modul lain (dimuat lebih dulu)
                continue
            miss.append((sym, mods)); mods_bad |= mods
        elif exp[sym] != crc:
            bad.append((sym, crc, exp[sym], mods)); mods_bad |= mods
    return bad, miss, mods_bad


def cpio_kos(blob, outdir):
    """ekstrak *.ko dari arsip cpio newc (boleh beberapa arsip bersambung)"""
    n, i = 0, 0
    while i + 110 <= len(blob):
        if blob[i:i + 6] not in (b"070701", b"070702"):
            j = blob.find(b"070701", i + 1)
            if j < 0:
                break
            i = j
            continue
        namesize = int(blob[i + 94:i + 102], 16)
        filesize = int(blob[i + 54:i + 62], 16)
        name = blob[i + 110:i + 110 + namesize - 1].decode("utf-8", "replace")
        i = (i + 110 + namesize + 3) & ~3
        data = blob[i:i + filesize]
        i = (i + filesize + 3) & ~3
        if name == "TRAILER!!!":
            continue
        if name.endswith(".ko") and data[:4] == b"\x7fELF":
            out = os.path.join(outdir, name.lstrip("/").replace("..", "_"))
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "wb").write(data)
            n += 1
    return n


def decompress(frag):
    import gzip
    if frag[:4] == b"\x02\x21\x4c\x18":       # lz4 legacy (bisa beberapa blok)
        p = subprocess.run(["lz4", "-dc"], input=frag, capture_output=True)
        return p.stdout
    if frag[:2] == b"\x1f\x8b":
        return gzip.decompress(frag)
    if frag[:4] == b"\x28\xb5\x2f\xfd":
        return subprocess.run(["zstd", "-dc"], input=frag, capture_output=True).stdout
    return frag


def vbmods(img, outdir):
    d = open(img, "rb").read()
    if d[:8] != b"VNDRBOOT":
        raise SystemExit("bukan vendor_boot (magic %r)" % d[:8])
    ver, page = struct.unpack_from("<II", d, 8)
    rsize = struct.unpack_from("<I", d, 24)[0]
    hsize, dsize = struct.unpack_from("<II", d, 2096)

    def al(x):
        return (x + page - 1) // page * page
    roff = al(hsize)
    frags = []
    if ver >= 4:
        tsize, tnum, tent = struct.unpack_from("<III", d, 2112)
        toff = roff + al(rsize) + al(dsize)
        for k in range(tnum):
            sz, off = struct.unpack_from("<II", d, toff + k * tent)
            frags.append(d[roff + off:roff + off + sz])
    else:
        frags.append(d[roff:roff + rsize])
    os.makedirs(outdir, exist_ok=True)
    n = 0
    for f in frags:
        n += cpio_kos(decompress(f), outdir)
    print("%d modul dari %d fragmen ramdisk vendor_boot" % (n, len(frags)))
    return 0


def load_exports(path):
    image, tmp = kernel_from(path)
    try:
        return exports(image)
    finally:
        if tmp:
            os.unlink(tmp)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("dump", "check", "vbmods"):
        print(__doc__)
        return 2
    if sys.argv[1] == "vbmods":
        return vbmods(sys.argv[2], sys.argv[3])
    exp = load_exports(sys.argv[2])
    if sys.argv[1] == "dump":
        for k in sorted(exp):
            print("0x%08x %s" % (exp[k], k))
        return 0
    args = sys.argv[3:]
    base_exp = None
    if len(args) >= 2 and args[0] == "--base":
        base_exp = load_exports(args[1])
        args = args[2:]
    want = wanted(args)
    if not want:
        print("tidak ada modul / referensi CRC yang bisa dibaca")
        return 2
    bad, miss, mods_bad = failing(exp, want)
    allmods = set().union(*(m for _c, m in want.values()))
    note = ""
    if base_exp is not None:
        _b, _m, base_bad = failing(base_exp, want)
        if base_bad:
            note = " (%d modul juga gagal dengan kernel base, tidak dihitung)" % len(base_bad & mods_bad)
        keep = mods_bad - base_bad
        bad = [x for x in bad if x[3] & keep]
        miss = [x for x in miss if x[1] & keep]
        mods_bad = keep
    ok = len(want) - len(bad) - len(miss)
    print("kernel: %d simbol diekspor | modul: %d, simbol diminta: %d | cocok/dari modul %d, CRC beda %d, tidak diekspor %d%s"
          % (len(exp), len(allmods), len(want), ok, len(bad), len(miss), note))
    for sym, w, g, mods in bad[:30]:
        print("  BEDA    %-40s modul 0x%08x kernel 0x%08x  (%s)" % (sym, w, g, ", ".join(sorted(mods))[:90]))
    for sym, mods in miss[:30]:
        print("  HILANG  %-40s (%s)" % (sym, ", ".join(sorted(mods))[:90]))
    if mods_bad:
        print("MODUL_GAGAL %d/%d: %s" % (len(mods_bad), len(allmods), " ".join(sorted(mods_bad))[:3000]))
    print("RESULT %d %d %d %d %d" % (ok, len(bad), len(miss), len(mods_bad), len(allmods)))
    return 3 if mods_bad else 0


if __name__ == "__main__":
    sys.exit(main())
