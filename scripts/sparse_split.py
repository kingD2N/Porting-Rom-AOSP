#!/usr/bin/env python3
"""
sparse_split.py - pecah Android sparse image menjadi N potongan sparse yang
masing-masing valid (gaya "sparsechunk" fastboot / super.img.0..N xiaomi.eu).
Setiap potongan menutupi seluruh ukuran image: blok di luar bagiannya diisi
chunk DONT_CARE, jadi potongan bisa di-flash berurutan ke partisi yang sama,
dan `simg2img part.0 part.1 ... out.img` menghasilkan image utuh.

  sparse_split.py <sparse.img> <prefix_output> <jumlah_potongan>
  -> <prefix>.0 <prefix>.1 ... <prefix>.(N-1)
"""
import struct
import sys

MAGIC = 0xED26FF3A
RAW, FILL, DONT_CARE, CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
HDR = struct.Struct("<IHHHHIIII")   # 28 byte
CHDR = struct.Struct("<HHII")        # 12 byte


def read_chunks(f):
    h = HDR.unpack(f.read(HDR.size))
    magic, major, minor, fhs, chs, blk_sz, total_blks, total_chunks, _crc = h
    if magic != MAGIC:
        raise SystemExit("bukan sparse image")
    f.seek(fhs)
    chunks = []  # (type, blocks, data_offset, data_len)
    for _ in range(total_chunks):
        ctype, _r, cblks, tsize = CHDR.unpack(f.read(CHDR.size))
        if chs > CHDR.size:
            f.seek(chs - CHDR.size, 1)
        dlen = tsize - chs
        chunks.append((ctype, cblks, f.tell(), dlen))
        f.seek(dlen, 1)
    return blk_sz, total_blks, chunks


def write_part(src, out, blk_sz, total_blks, start_blk, part):
    body = []
    if start_blk:
        body.append((DONT_CARE, start_blk, None, 0))
    covered = start_blk
    for c in part:
        if c[0] == CRC32:
            continue
        body.append(c)
        covered += c[1]
    if covered < total_blks:
        body.append((DONT_CARE, total_blks - covered, None, 0))
    with open(out, "wb") as o:
        o.write(HDR.pack(MAGIC, 1, 0, HDR.size, CHDR.size, blk_sz, total_blks, len(body), 0))
        for ctype, cblks, off, dlen in body:
            o.write(CHDR.pack(ctype, 0, cblks, CHDR.size + dlen))
            if dlen:
                src.seek(off)
                left = dlen
                while left:
                    buf = src.read(min(left, 16 << 20))
                    o.write(buf)
                    left -= len(buf)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    path, prefix, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(path, "rb") as f:
        blk_sz, total_blks, chunks = read_chunks(f)
        data_total = sum(c[3] for c in chunks) or 1
        target = data_total / n
        parts, cur, cur_bytes = [], [], 0
        for c in chunks:
            if cur and cur_bytes + c[3] > target and len(parts) < n - 1:
                parts.append(cur)
                cur, cur_bytes = [], 0
            cur.append(c)
            cur_bytes += c[3]
        parts.append(cur)
        while len(parts) < n:          # image kecil: potongan kosong (DONT_CARE semua)
            parts.append([])
        start = 0
        for i, part in enumerate(parts):
            write_part(f, "%s.%d" % (prefix, i), blk_sz, total_blks, start, part)
            start += sum(c[1] for c in part if c[0] != CRC32)
    print(n)


if __name__ == "__main__":
    main()
