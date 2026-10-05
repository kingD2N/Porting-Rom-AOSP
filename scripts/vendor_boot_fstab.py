#!/usr/bin/env python3
"""
vendor_boot_fstab.py - patch first-stage fstab di dalam vendor_boot (header v3/v4) dengan
benar untuk vendor ramdisk BERFRAGMEN (v4: platform + dlkm + recovery).

  vendor_boot_fstab.py <vendor_boot.img> -- <argumen fstab_patch.py ...>

Kenapa tidak magiskboot: magiskboot toolkit membaca semua fragmen v4 sebagai SATU
ramdisk.cpio lalu repack tanpa memperbarui tabel fragmen -> ukuran total & tabel tidak
cocok, fragmen dlkm (modul kernel first-stage) rusak -> bootloop. LineageOS/AxionOS
sm8450-common memakai BOARD_VENDOR_RAMDISK_FRAGMENTS := dlkm.

Langkah: parse header + tabel fragmen -> tiap fragmen didekompres (lz4 legacy / gzip / raw),
file fstab.* di cpio newc dipatch lewat fstab_patch.py, dikompres ulang dengan format sama
-> fragmen disusun ulang, ukuran/offset di tabel & header diperbarui -> image ditulis
dengan alignment page, ukuran file asli dipertahankan (padding nol; footer AVB dibiarkan,
vbmeta sudah dimatikan verifikasinya).

Output: log per fstab; baris "RECOVERY_FRAGMENT <nama>" kalau ada fragmen recovery.
Exit: 0 dipatch, 4 tidak ada fstab, 2 format tidak dikenal / gagal.
"""
import gzip
import os
import struct
import subprocess
import sys
import tempfile

LZ4_LEGACY = b"\x02\x21\x4c\x18"
TYPES = {0: "none", 1: "platform", 2: "recovery", 3: "dlkm"}
HERE = os.path.dirname(os.path.abspath(__file__))


def align(n, page):
    return (n + page - 1) // page * page


# ---------------------------------------------------------------- kompresi
def decompress(data):
    if data[:4] == LZ4_LEGACY:
        out = subprocess.run(["lz4", "-dc"], input=data, stdout=subprocess.PIPE, check=True).stdout
        return out, "lz4_legacy"
    if data[:2] == b"\x1f\x8b":
        return gzip.decompress(data), "gzip"
    if data[:6] in (b"070701", b"070702"):
        return data, "raw"
    raise ValueError("format ramdisk tidak dikenal (magic %s)" % data[:4].hex())


def compress(data, fmt):
    if fmt == "lz4_legacy":
        return subprocess.run(["lz4", "-l", "-9", "-c"], input=data, stdout=subprocess.PIPE, check=True).stdout
    if fmt == "gzip":
        return gzip.compress(data, 9, mtime=0)
    return data


# ---------------------------------------------------------------- cpio newc
FIELDS = ["ino", "mode", "uid", "gid", "nlink", "mtime", "filesize", "devmajor", "devminor",
          "rdevmajor", "rdevminor", "namesize", "check"]


def cpio_parse(data):
    ents, p = [], 0
    while p + 110 <= len(data):
        magic = data[p:p + 6]
        if magic not in (b"070701", b"070702"):
            break
        h = {k: int(data[p + 6 + i * 8:p + 14 + i * 8], 16) for i, k in enumerate(FIELDS)}
        name = data[p + 110:p + 110 + h["namesize"] - 1].decode("utf-8", "surrogateescape")
        p = (p + 110 + h["namesize"] + 3) & ~3
        body = data[p:p + h["filesize"]]
        p = (p + h["filesize"] + 3) & ~3
        ents.append([magic, h, name, body])
        if name == "TRAILER!!!":
            break
    return ents, data[p:]


def cpio_build(ents, tail):
    out = bytearray()
    for magic, h, name, body in ents:
        nb = name.encode("utf-8", "surrogateescape") + b"\0"
        h = dict(h, namesize=len(nb), filesize=len(body))
        out += magic + b"".join(b"%08X" % h[k] for k in FIELDS) + nb
        out += b"\0" * ((-len(out)) % 4)
        out += body
        out += b"\0" * ((-len(out)) % 4)
    return bytes(out) + tail


def patch_fragment(raw, fstab_args, label):
    ents, tail = cpio_parse(raw)
    if not ents:
        raise ValueError("%s: bukan cpio newc" % label)
    changed = found = 0
    for e in ents:
        name, h = e[2], e[1]
        base = os.path.basename(name)
        if not base.startswith("fstab.") or (h["mode"] & 0o170000) != 0o100000:
            continue
        with tempfile.NamedTemporaryFile("wb", delete=False, suffix="." + base) as t:
            t.write(e[3])
            tp = t.name
        try:
            r = subprocess.run([sys.executable, os.path.join(HERE, "fstab_patch.py"), tp] + fstab_args,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
            print("  [vendor_boot] %s: %s" % (label, name))
            sys.stdout.write(r.stdout.decode("utf-8", "replace"))
            new = open(tp, "rb").read()
        finally:
            os.unlink(tp)
        found += 1
        if new != e[3]:
            e[3] = new
            changed += 1
    return (cpio_build(ents, tail) if changed else None), found


# ---------------------------------------------------------------- vendor_boot
def main():
    if len(sys.argv) < 3 or sys.argv[2] != "--":
        raise SystemExit(__doc__)
    path, fstab_args = sys.argv[1], sys.argv[3:]
    img = open(path, "rb").read()
    if img[:8] != b"VNDRBOOT":
        print("bukan vendor_boot (magic %r)" % img[:8])
        return 2
    ver, page = struct.unpack_from("<II", img, 8)
    vrd_size = struct.unpack_from("<I", img, 24)[0]
    hdr_size, dtb_size = struct.unpack_from("<II", img, 2096)
    if ver not in (3, 4):
        print("header vendor_boot v%d tidak didukung" % ver)
        return 2
    tbl_size = n_ent = ent_size = bc_size = 0
    if ver >= 4:
        tbl_size, n_ent, ent_size, bc_size = struct.unpack_from("<IIII", img, 2112)

    o_rd = align(hdr_size, page)
    o_dtb = o_rd + align(vrd_size, page)
    o_tbl = o_dtb + align(dtb_size, page)
    o_bc = o_tbl + align(tbl_size, page)
    ramdisk = img[o_rd:o_rd + vrd_size]
    dtb = img[o_dtb:o_dtb + dtb_size]
    bootconfig = img[o_bc:o_bc + bc_size] if ver >= 4 else b""
    used_end = (o_bc + align(bc_size, page)) if ver >= 4 else o_dtb + align(dtb_size, page)

    # fragmen: (size, offset, type, name[32], board_id[64]) per entri v4; v3 = satu ramdisk
    frags = []
    if ver >= 4 and n_ent:
        for i in range(n_ent):
            e = img[o_tbl + i * ent_size:o_tbl + (i + 1) * ent_size]
            size, off, typ = struct.unpack_from("<III", e, 0)
            frags.append({"size": size, "off": off, "type": typ, "raw_entry": bytearray(e),
                          "name": e[12:44].split(b"\0", 1)[0].decode("ascii", "replace")})
        total = sum(f["size"] for f in frags)
        if total != vrd_size or any(f["off"] + f["size"] > vrd_size for f in frags):
            print("tabel fragmen tidak konsisten (total %d, header %d) - image base sudah rusak?" % (total, vrd_size))
            return 2
    else:
        frags.append({"size": vrd_size, "off": 0, "type": 1, "raw_entry": None, "name": ""})

    print("vendor_boot v%d, page %d, ramdisk %d byte, %d fragmen: %s" % (
        ver, page, vrd_size, len(frags),
        ", ".join("%s(%s,%d)" % (f["name"] or "-", TYPES.get(f["type"], f["type"]), f["size"]) for f in frags)))

    found_total, changed_total = 0, 0
    new_parts = []
    for f in frags:
        label = "fragmen %s/%s" % (f["name"] or "-", TYPES.get(f["type"], f["type"]))
        if f["type"] == 2:
            print("RECOVERY_FRAGMENT %s" % (f["name"] or "recovery"))
        data = ramdisk[f["off"]:f["off"] + f["size"]]
        try:
            raw, fmt = decompress(data)
        except (ValueError, subprocess.CalledProcessError) as ex:
            print("  %s: dilewati (%s)" % (label, ex))
            new_parts.append(data)
            continue
        new_raw, found = patch_fragment(raw, fstab_args, label + " " + fmt)
        found_total += found
        if new_raw is None:
            new_parts.append(data)
        else:
            new_parts.append(compress(new_raw, fmt))
            changed_total += 1

    if found_total == 0:
        print("tidak ada fstab.* di vendor ramdisk")
        return 4
    if changed_total == 0:
        print("fstab sudah sesuai, vendor_boot tidak diubah")
        return 0

    # susun ulang ramdisk + tabel
    new_ramdisk = b"".join(new_parts)
    table = bytearray()
    off = 0
    for f, part in zip(frags, new_parts):
        if f["raw_entry"] is not None:
            e = f["raw_entry"]
            struct.pack_into("<II", e, 0, len(part), off)
            table += e
        off += len(part)

    hdr = bytearray(img[:hdr_size])
    struct.pack_into("<I", hdr, 24, len(new_ramdisk))
    if ver >= 4:
        struct.pack_into("<I", hdr, 2112, len(table))

    def padded(b):
        return bytes(b) + b"\0" * (align(len(b), page) - len(b))

    out = padded(hdr) + padded(new_ramdisk) + padded(dtb)
    if ver >= 4:
        out += padded(table) + padded(bootconfig)

    if len(out) > len(img):
        print("vendor_boot baru (%d) lebih besar dari image asli (%d)" % (len(out), len(img)))
        return 2
    tail = bytearray(len(img) - len(out))
    # footer AVB (64 byte terakhir "AVBf") + blob vbmeta-nya dipertahankan di posisi asli
    if img[-64:-60] == b"AVBf":
        vb_off = struct.unpack_from(">Q", img, len(img) - 64 + 20)[0]
        if len(out) <= vb_off < len(img):
            tail[vb_off - len(out):] = img[vb_off:]
        else:
            tail[-64:] = img[-64:]
    new = out + bytes(tail)
    with open(path, "wb") as fo:
        fo.write(new)
    print("vendor_boot ditulis ulang: ramdisk %d -> %d byte, %d fragmen dipatch (data asli s/d %d byte)"
          % (vrd_size, len(new_ramdisk), changed_total, used_end))
    return 0


if __name__ == "__main__":
    sys.exit(main())
