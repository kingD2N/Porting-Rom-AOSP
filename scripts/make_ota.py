#!/usr/bin/env python3
"""
make_ota.py - bangun zip OTA A/B gaya AOSP (seperti zip LineageOS/AOSP biasa) tanpa
delta_generator / ota_from_target_files:

  payload.bin              full payload (update_engine, format v2, REPLACE / REPLACE_XZ)
  payload_properties.txt   FILE_HASH, FILE_SIZE, METADATA_HASH, METADATA_SIZE
  apex_info.pb             (opsional) versi APEX di system
  META-INF/com/android/metadata, metadata.pb, otacert

Dipasang lewat recovery (OrangeFox/TWRP/LineageOS recovery) dengan update_engine_sideload:
recovery membaca payload_properties.txt + offset payload.bin (STORED) dan META-INF/com/android/
metadata (ota-type=AB, pre-device). Format diikuti dari update_engine (payload_signer.cc,
full_update_generator.cc, xz_android.cc) dan bootable/recovery (install.cpp).

  make_ota.py build --out OTA.zip --key KEY.pem --cert CERT.pem \\
      --partition boot=boot.img [--partition ...] \\
      --group qti_dynamic_partitions:9122611200:system,system_ext,product,vendor,odm \\
      --device ingres [--snapshot 1] [--vabc 0] [--fingerprint FP] [--incremental X] \\
      [--spl 2026-09-05] [--sdk 36] [--timestamp N] [--apex-info apex_info.pb] [--workers N]
      [--extra META-INF/port_info.txt=port_info.txt]
  make_ota.py apex-info --out apex_info.pb DIR [DIR ...]   (DIR berisi *.apex / *.capex)
  make_ota.py verify OTA.zip                                (cek ulang struktur & hash)
"""
import argparse
import base64
import hashlib
import io
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from multiprocessing import Pool

BLOCK = 4096
CHUNK = 2 * 1024 * 1024      # 512 blok per op, sama dengan payload LineageOS/AOSP (--chunk_size 2 MiB)
OP_REPLACE = 0
OP_REPLACE_XZ = 8
MAGIC = b"CrAU"
MAJOR = 2                    # brillo major payload version
HEADER_SIZE = 4 + 8 + 8 + 4  # magic, version, manifest_size, metadata_signature_size


# ------------------------------------------------------------------ protobuf (encode)
def _vi(n):
    out = bytearray()
    n &= (1 << 64) - 1
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pv(no, v):                      # varint (uint/int/bool/enum)
    return _vi(no << 3) + _vi(int(v))


def pb(no, b):                      # length-delimited
    if isinstance(b, str):
        b = b.encode()
    return _vi((no << 3) | 2) + _vi(len(b)) + b


def pf32(no, v):                    # fixed32
    return _vi((no << 3) | 5) + struct.pack("<I", v)


# ------------------------------------------------------------------ protobuf (decode, verify)
def _rvi(buf, pos):
    shift = val = 0
    while True:
        b = buf[pos]
        pos += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, pos
        shift += 7


def pfields(buf):
    pos = 0
    while pos < len(buf):
        key, pos = _rvi(buf, pos)
        no, wt = key >> 3, key & 7
        if wt == 0:
            v, pos = _rvi(buf, pos)
        elif wt == 2:
            ln, pos = _rvi(buf, pos)
            v = buf[pos:pos + ln]
            pos += ln
        elif wt == 5:
            v = struct.unpack_from("<I", buf, pos)[0]
            pos += 4
        elif wt == 1:
            v = struct.unpack_from("<Q", buf, pos)[0]
            pos += 8
        else:
            raise ValueError("wire type %d" % wt)
        yield no, v


# ------------------------------------------------------------------ RSA (openssl)
def sign_hash(digest, key_pem):
    """RSASSA-PKCS1-v1_5 SHA-256 = PadRSASHA256Hash + RSA_private_encrypt (payload_signer.cc)"""
    with tempfile.NamedTemporaryFile(delete=False) as t:
        t.write(digest)
        tp = t.name
    try:
        r = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", key_pem,
                            "-pkeyopt", "digest:sha256", "-in", tp],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    finally:
        os.unlink(tp)
    return r.stdout


def key_size(key_pem):
    r = subprocess.run(["openssl", "rsa", "-in", key_pem, "-noout", "-text"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, text=True)
    for line in r.stdout.splitlines():
        if "Private-Key:" in line:
            return int(line.split("(")[1].split()[0]) // 8
    raise SystemExit("ukuran kunci RSA tidak terbaca")


def signatures_msg(sig, padded_size):
    """Signatures { Signature { data, unpadded_signature_size } } (ConvertSignaturesToProtobuf)"""
    data = sig + b"\0" * (padded_size - len(sig))
    return pb(1, pb(2, data) + pf32(3, len(sig)))


# ------------------------------------------------------------------ payload
def _compress(args):
    data, preset = args
    xz = lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_NONE, preset=preset)
    if len(xz) < len(data):
        return OP_REPLACE_XZ, xz
    return OP_REPLACE, data


def _chunks(path, size, preset, h):
    """baca image per CHUNK; hash partisi (image + padding nol) dihitung sekalian"""
    with open(path, "rb") as f:
        done = 0
        while done < size:
            data = f.read(min(CHUNK, size - done))
            if not data:
                raise SystemExit("%s terpotong" % path)
            done += len(data)
            if len(data) % BLOCK:
                data += b"\0" * (BLOCK - len(data) % BLOCK)
            h.update(data)
            yield data, preset


def _bounded_map(pool, gen):
    """seperti pool.imap tapi membaca image per batch (Pool.imap menyedot seluruh generator
    ke antrean -> image GB-an masuk RAM sekaligus)"""
    batch_len = max(4, (pool._processes or 2) * 4)
    while True:
        batch = []
        for item in gen:
            batch.append(item)
            if len(batch) >= batch_len:
                break
        if not batch:
            return
        for res in pool.map(_compress, batch, chunksize=1):
            yield res


def build_partition(name, path, blob, pool, preset, log):
    size = os.path.getsize(path)
    if size == 0:
        raise SystemExit("%s kosong" % path)
    pad = (-size) % BLOCK
    if pad:
        log("  %s: ukuran %d bukan kelipatan %d, diisi nol %d byte" % (name, size, BLOCK, pad))
    full = size + pad
    h = hashlib.sha256()
    ops = []
    start = 0
    left = full // BLOCK
    t0 = time.time()
    n_xz = 0
    for typ, data in _bounded_map(pool, _chunks(path, size, preset, h)):
        nb = min(CHUNK // BLOCK, left)
        off = blob.tell()
        blob.write(data)
        ops.append(pv(1, typ) + pv(2, off) + pv(3, len(data))
                   + pb(6, pv(1, start) + pv(2, nb)) + pb(8, hashlib.sha256(data).digest()))
        n_xz += typ == OP_REPLACE_XZ
        start += nb
        left -= nb
    if left:
        raise SystemExit("%s: %d blok tidak tertulis" % (name, left))
    info = pv(1, full) + pb(2, h.digest())
    msg = pb(1, name) + pb(7, info) + b"".join(pb(8, o) for o in ops)
    log("  %-14s %6d MB  %5d op (xz %d, raw %d)  %.0fs" % (
        name, full >> 20, len(ops), n_xz, len(ops) - n_xz, time.time() - t0))
    return msg, full, h.hexdigest()


def write_payload(a, out_dir, log):
    key_bytes = key_size(a.key)
    sig_dummy = signatures_msg(b"\0" * key_bytes, key_bytes)
    blob_path = os.path.join(out_dir, "blobs.tmp")
    parts = []
    with open(blob_path, "w+b") as blob, Pool(a.workers) as pool:
        for spec in a.partition:
            name, path = spec.split("=", 1)
            parts.append(build_partition(name, path, blob, pool, a.xz_preset, log))
        blob_len = blob.tell()

    groups = []
    for g in a.group:
        gname, gsize, gparts = g.split(":", 2)
        groups.append(pb(1, gname) + pv(2, int(gsize)) + b"".join(pb(3, p) for p in gparts.split(",") if p))
    dpm = b"".join(pb(1, g) for g in groups) + pv(2, a.snapshot) + pv(3, a.vabc)

    manifest = pv(3, BLOCK) + pv(4, blob_len) + pv(5, len(sig_dummy)) + pv(12, 0)
    manifest += b"".join(pb(13, p[0]) for p in parts)
    manifest += pv(14, a.timestamp) + pb(15, dpm)
    if a.apex_info:
        with open(a.apex_info, "rb") as f:
            for no, v in pfields(f.read()):
                if no == 1:
                    manifest += pb(17, v)
    if a.spl:
        manifest += pb(18, a.spl)

    header = MAGIC + struct.pack(">QQI", MAJOR, len(manifest), len(sig_dummy))
    metadata = header + manifest
    meta_hash = hashlib.sha256(metadata).digest()
    meta_sig = signatures_msg(sign_hash(meta_hash, a.key), key_bytes)
    assert len(meta_sig) == len(sig_dummy)

    # hash payload = metadata + blob data (tanpa metadata signature & payload signature)
    ph = hashlib.sha256(metadata)
    with open(blob_path, "rb") as f:
        while True:
            d = f.read(8 << 20)
            if not d:
                break
            ph.update(d)
    pay_sig = signatures_msg(sign_hash(ph.digest(), a.key), key_bytes)
    assert len(pay_sig) == len(sig_dummy)

    payload_path = os.path.join(out_dir, "payload.bin")
    fh = hashlib.sha256()
    with open(payload_path, "wb") as out:
        for piece in (metadata, meta_sig):
            out.write(piece)
            fh.update(piece)
        with open(blob_path, "rb") as f:
            while True:
                d = f.read(8 << 20)
                if not d:
                    break
                out.write(d)
                fh.update(d)
        out.write(pay_sig)
        fh.update(pay_sig)
        fsize = out.tell()
    os.unlink(blob_path)
    props = "FILE_HASH=%s\nFILE_SIZE=%d\nMETADATA_HASH=%s\nMETADATA_SIZE=%d\n" % (
        base64.b64encode(fh.digest()).decode(), fsize,
        base64.b64encode(meta_hash).decode(), len(metadata))
    props_path = os.path.join(out_dir, "payload_properties.txt")
    with open(props_path, "w") as f:
        f.write(props)
    log("payload.bin %d MB, metadata %d byte (+ tanda tangan %d)" % (fsize >> 20, len(metadata), len(meta_sig)))
    return payload_path, props_path, len(metadata) + len(meta_sig)


# ------------------------------------------------------------------ zip + metadata
def _data_offset(zpath, name):
    with zipfile.ZipFile(zpath) as z:
        zi = z.getinfo(name)
    with open(zpath, "rb") as f:
        f.seek(zi.header_offset)
        h = f.read(30)
        n, e = struct.unpack_from("<HH", h, 26)
    return zi.header_offset + 30 + n + e, zi.file_size


def _metadata_text(a, prop, sprop):
    lines = {
        "ota-property-files": prop,
        "ota-required-cache": "0",
        "ota-streaming-property-files": sprop,
        "ota-type": "AB",
        "post-sdk-level": str(a.sdk or ""),
        "post-security-patch-level": a.spl or "",
        "post-timestamp": str(a.timestamp),
        "pre-device": a.device,
    }
    if a.fingerprint:
        lines["post-build"] = a.fingerprint
    if a.incremental:
        lines["post-build-incremental"] = a.incremental
    return "".join("%s=%s\n" % (k, v) for k, v in sorted(lines.items()) if v != "")


def _metadata_pb(a, prop, sprop):
    pre = pb(1, a.device)
    post = b""
    if a.fingerprint:
        post += pb(2, a.fingerprint)
    if a.incremental:
        post += pb(3, a.incremental)
    post += pv(4, a.timestamp)
    if a.sdk:
        post += pb(5, str(a.sdk))
    if a.spl:
        post += pb(6, a.spl)
    m = pv(1, 1)                                     # type = AB
    for k, v in (("ota-property-files", prop), ("ota-streaming-property-files", sprop)):
        m += pb(4, pb(1, k) + pb(2, v))              # map<string,string> property_files
    m += pb(5, pre) + pb(6, post) + pv(8, 0)
    # spl_downgrade: recovery AOSP menolak kalau SPL paket < SPL recovery; ROM port tidak bisa
    # menjamin urutan itu, data tetap di-format sesudahnya
    m += pv(9, 1)
    return m


def write_zip(a, payload, props, meta_len):
    out = a.out
    with open(a.cert, "rb") as f:
        cert = f.read()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        z.write(payload, "payload.bin")
        z.write(props, "payload_properties.txt")
        if a.apex_info:
            z.write(a.apex_info, "apex_info.pb")
        z.writestr(zipfile.ZipInfo("META-INF/com/android/otacert", (2009, 1, 1, 0, 0, 0)), cert)
        for spec in a.extra:
            name, path = spec.split("=", 1)
            z.write(path, name)

    toks = []
    off, size = _data_offset(out, "payload.bin")
    toks.append("payload_metadata.bin:%d:%d" % (off, meta_len))
    stoks = []
    for n in ["payload.bin", "payload_properties.txt"] + (["apex_info.pb"] if a.apex_info else []):
        o, s = _data_offset(out, n)
        toks.append("%s:%d:%d" % (n, o, s))
        stoks.append("%s:%d:%d" % (n, o, s))

    # metadata.pb lalu metadata ditambahkan di akhir; offset & ukurannya ikut dicatat di dalam
    # keduanya -> nilai dibuat lebar tetap (padding spasi) lalu dihitung ulang sampai stabil
    with zipfile.ZipFile(out) as z:
        start = z.start_dir
    PB, TXT = "META-INF/com/android/metadata.pb", "META-INF/com/android/metadata"
    width = None
    est = {PB: (0, 0), TXT: (0, 0)}
    for _ in range(6):
        def ptok(base):
            t = list(base) + ["metadata:%d:%d" % est[TXT], "metadata.pb:%d:%d" % est[PB]]
            return ",".join(t)
        prop, sprop = ptok(toks), ptok(stoks)
        if width is None:
            width = (len(prop) + 40, len(sprop) + 40)
        prop, sprop = prop.ljust(width[0]), sprop.ljust(width[1])
        mpb = _metadata_pb(a, prop, sprop)
        mtxt = _metadata_text(a, prop, sprop).encode()
        pb_off = start + 30 + len(PB)
        txt_off = pb_off + len(mpb) + 30 + len(TXT)
        new = {PB: (pb_off, len(mpb)), TXT: (txt_off, len(mtxt))}
        if new == est:
            break
        est = new
    else:
        raise SystemExit("offset metadata tidak stabil")
    with zipfile.ZipFile(out, "a", zipfile.ZIP_STORED, allowZip64=True) as z:
        z.writestr(zipfile.ZipInfo(PB, (2009, 1, 1, 0, 0, 0)), mpb)
        z.writestr(zipfile.ZipInfo(TXT, (2009, 1, 1, 0, 0, 0)), mtxt)
    for n, (o, s) in est.items():
        ro, rs = _data_offset(out, n)
        if (ro, rs) != (o, s):
            raise SystemExit("offset %s salah: dihitung %d:%d, nyata %d:%d" % (n, o, s, ro, rs))
    return mtxt.decode()


# ------------------------------------------------------------------ apex_info
def apex_info(out, dirs):
    infos = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith((".apex", ".capex")):
                continue
            p = os.path.join(d, fn)
            try:
                with zipfile.ZipFile(p) as z:
                    man = z.read("apex_manifest.pb")
                    comp = fn.endswith(".capex")
                    dsz = z.getinfo("original_apex").file_size if comp else 0
            except (zipfile.BadZipFile, KeyError, OSError):
                continue
            name, ver = None, 0
            for no, v in pfields(man):
                if no == 1:
                    name = v.decode()
                elif no == 2:
                    ver = v
            if not name:
                continue
            msg = pb(1, name) + pv(2, ver) + pv(3, 1 if comp else 0)
            if comp:
                msg += pv(4, dsz)
            infos.append((name, msg))
    with open(out, "wb") as f:
        f.write(b"".join(pb(1, m) for _n, m in sorted(infos)))
    print("apex_info.pb: %d APEX" % len(infos))


# ------------------------------------------------------------------ verify
def verify(path):
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        for need in ("payload.bin", "payload_properties.txt", "META-INF/com/android/metadata"):
            if need not in names:
                raise SystemExit("tidak ada %s" % need)
        zi = z.getinfo("payload.bin")
        if zi.compress_type != zipfile.ZIP_STORED:
            raise SystemExit("payload.bin harus STORED")
        props = dict(l.split("=", 1) for l in z.read("payload_properties.txt").decode().split())
        meta = z.read("META-INF/com/android/metadata").decode()
    off, size = _data_offset(path, "payload.bin")
    with open(path, "rb") as f:
        f.seek(off)
        head = f.read(HEADER_SIZE)
        if head[:4] != MAGIC:
            raise SystemExit("magic payload salah")
        ver, msize, ssize = struct.unpack(">QQI", head[4:])
        f.seek(off)
        md = f.read(HEADER_SIZE + msize)
        f.seek(off)
        fh = hashlib.sha256()
        left = size
        while left:
            d = f.read(min(8 << 20, left))
            fh.update(d)
            left -= len(d)
    ok = (base64.b64encode(fh.digest()).decode() == props["FILE_HASH"] and int(props["FILE_SIZE"]) == size
          and base64.b64encode(hashlib.sha256(md).digest()).decode() == props["METADATA_HASH"]
          and int(props["METADATA_SIZE"]) == len(md))
    print("payload v%d manifest %d byte, signature %d byte, properties %s" % (ver, msize, ssize, "OK" if ok else "SALAH"))
    print(meta, end="")
    for tok in [t for l in meta.splitlines() if l.startswith("ota-property-files=") for t in l.split("=", 1)[1].strip().split(",")]:
        n, o, s = tok.rsplit(":", 2)
        if n == "payload_metadata.bin":
            continue
        zname = "META-INF/com/android/" + n if n in ("metadata", "metadata.pb") else n
        ro, rs = _data_offset(path, zname)
        if (ro, rs) != (int(o), int(s)):
            raise SystemExit("ota-property-files %s salah" % n)
    if not ok:
        raise SystemExit("payload_properties.txt tidak cocok dengan payload.bin")
    print("VERIFY OK")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", required=True)
    b.add_argument("--key", required=True)
    b.add_argument("--cert", required=True)
    b.add_argument("--partition", action="append", required=True)
    b.add_argument("--group", action="append", default=[])
    b.add_argument("--device", required=True)
    b.add_argument("--snapshot", type=int, default=1)
    b.add_argument("--vabc", type=int, default=0)
    b.add_argument("--fingerprint", default="")
    b.add_argument("--incremental", default="")
    b.add_argument("--spl", default="")
    b.add_argument("--sdk", default="")
    b.add_argument("--timestamp", type=int, default=int(time.time()))
    b.add_argument("--apex-info", default="")
    b.add_argument("--workers", type=int, default=os.cpu_count() or 2)
    b.add_argument("--xz-preset", type=int, default=6)
    b.add_argument("--tmpdir", default="")
    b.add_argument("--extra", action="append", default=[], help="file tambahan di zip: nama=path")
    x = sub.add_parser("apex-info")
    x.add_argument("--out", required=True)
    x.add_argument("dirs", nargs="+")
    v = sub.add_parser("verify")
    v.add_argument("zip")
    a = ap.parse_args()

    if a.cmd == "apex-info":
        apex_info(a.out, a.dirs)
        return 0
    if a.cmd == "verify":
        verify(a.zip)
        return 0

    def log(s):
        print(s, flush=True)

    tmp = a.tmpdir or os.path.dirname(os.path.abspath(a.out))
    work = tempfile.mkdtemp(prefix="ota_", dir=tmp)
    try:
        log("payload: %d partisi, chunk %d KiB, xz preset %d, %d proses" % (
            len(a.partition), CHUNK >> 10, a.xz_preset, a.workers))
        payload, props, meta_len = write_payload(a, work, log)
        write_zip(a, payload, props, meta_len)
    finally:
        for f in os.listdir(work):
            os.unlink(os.path.join(work, f))
        os.rmdir(work)
    verify(a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
