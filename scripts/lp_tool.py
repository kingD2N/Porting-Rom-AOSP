#!/usr/bin/env python3
"""
lp_tool.py - baca metadata super.img (liblp) dan payload.bin (update_engine)
tanpa dependensi eksternal. Output berupa key=value yang bisa di-source shell.

  lp_tool.py super   <super_raw.img>
  lp_tool.py payload <payload.bin>
  lp_tool.py sparse  <file>          -> exit 0 kalau Android sparse image
"""
import struct
import sys

# ---------------------------------------------------------------- liblp
LP_PARTITION_RESERVED_BYTES = 4096
LP_METADATA_GEOMETRY_SIZE = 4096
LP_GEOMETRY_MAGIC = 0x616C4467
LP_HEADER_MAGIC = 0x414C5030
LP_HEADER_FLAG_VIRTUAL_AB = 0x1
SPARSE_MAGIC = 0xED26FF3A


def _cstr(b):
    return b.split(b"\0", 1)[0].decode("ascii", "replace")


def is_sparse(path):
    with open(path, "rb") as f:
        head = f.read(4)
    return len(head) == 4 and struct.unpack("<I", head)[0] == SPARSE_MAGIC


def super_info(path):
    with open(path, "rb") as f:
        f.seek(LP_PARTITION_RESERVED_BYTES)
        geo = f.read(52)
        magic, _size = struct.unpack_from("<II", geo, 0)
        if magic != LP_GEOMETRY_MAGIC:
            raise SystemExit("bukan super image (geometry magic salah) - sudah simg2img?")
        meta_max, slots, block_size = struct.unpack_from("<III", geo, 40)

        meta_off = LP_PARTITION_RESERVED_BYTES + LP_METADATA_GEOMETRY_SIZE * 2
        f.seek(meta_off)
        hdr = f.read(256)
        (hmagic, major, minor, header_size) = struct.unpack_from("<IHHI", hdr, 0)
        if hmagic != LP_HEADER_MAGIC:
            raise SystemExit("metadata header magic salah")
        # 0:magic 4:major 6:minor 8:header_size 12:checksum[32] 44:tables_size 48:checksum[32]
        descs = struct.unpack_from("<12I", hdr, 80)
        flags = 0
        if minor >= 2 and header_size >= 128:
            flags = struct.unpack_from("<I", hdr, 128)[0]
        tables_size = struct.unpack_from("<I", hdr, 44)[0]
        f.seek(meta_off + header_size)
        tables = f.read(tables_size)

    p_off, p_num, p_sz, e_off, e_num, e_sz, g_off, g_num, g_sz, b_off, b_num, b_sz = descs

    groups = []
    for i in range(g_num):
        base = g_off + i * g_sz
        name = _cstr(tables[base:base + 36])
        _gflags, gmax = struct.unpack_from("<IQ", tables, base + 36)
        groups.append((name, gmax))

    extents = []
    for i in range(e_num):
        base = e_off + i * e_sz
        nsec, _ttype, _tdata, _tsrc = struct.unpack_from("<QIQI", tables, base)
        extents.append(nsec)

    parts = []
    for i in range(p_num):
        base = p_off + i * p_sz
        name = _cstr(tables[base:base + 36])
        attrs, first_ext, n_ext, gidx = struct.unpack_from("<IIII", tables, base + 36)
        size = sum(extents[first_ext:first_ext + n_ext]) * 512
        parts.append((name, attrs, size, groups[gidx][0] if gidx < len(groups) else ""))

    devs = []
    for i in range(b_num):
        base = b_off + i * b_sz
        _first, _align, _aoff, dsize = struct.unpack_from("<QIIQ", tables, base)
        dname = _cstr(tables[base + 24:base + 60])
        devs.append((dname, dsize))

    print("LP_SUPER_SIZE=%d" % (devs[0][1] if devs else 0))
    print("LP_METADATA_MAX=%d" % meta_max)
    print("LP_METADATA_SLOTS=%d" % slots)
    print("LP_BLOCK_SIZE=%d" % block_size)
    print("LP_VIRTUAL_AB=%d" % (1 if flags & LP_HEADER_FLAG_VIRTUAL_AB else 0))
    print('LP_GROUPS="%s"' % " ".join("%s:%d" % g for g in groups if g[0] != "default"))
    print('LP_PARTITIONS="%s"' % " ".join(p[0] for p in parts))
    print('LP_PARTITION_SIZES="%s"' % " ".join("%s:%d" % (p[0], p[2]) for p in parts))


# ---------------------------------------------------------------- payload
def _varint(buf, pos):
    shift = 0
    val = 0
    while True:
        b = buf[pos]
        pos += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, pos
        shift += 7


def _fields(buf):
    """yield (field_no, wire_type, value) dari protobuf message mentah"""
    pos = 0
    end = len(buf)
    while pos < end:
        key, pos = _varint(buf, pos)
        fno, wt = key >> 3, key & 7
        if wt == 0:
            val, pos = _varint(buf, pos)
        elif wt == 1:
            val = buf[pos:pos + 8]
            pos += 8
        elif wt == 2:
            ln, pos = _varint(buf, pos)
            val = buf[pos:pos + ln]
            pos += ln
        elif wt == 5:
            val = buf[pos:pos + 4]
            pos += 4
        else:
            raise SystemExit("wire type protobuf tidak dikenal: %d" % wt)
        yield fno, wt, val


def payload_info(path):
    with open(path, "rb") as f:
        head = f.read(24)
        if head[:4] != b"CrAU":
            raise SystemExit("bukan payload.bin (magic CrAU tidak ada)")
        version, man_size = struct.unpack_from(">QQ", head, 4)
        start = 24 if version >= 2 else 20
        f.seek(start)
        manifest = f.read(man_size)

    parts = []
    groups = []
    dyn_parts = []
    vabc = 0
    snapshot = 0
    for fno, _wt, val in _fields(manifest):
        if fno == 13:  # PartitionUpdate
            for pf, _pw, pv in _fields(val):
                if pf == 1:
                    parts.append(pv.decode())
        elif fno == 15:  # DynamicPartitionMetadata
            for df, _dw, dv in _fields(val):
                if df == 1:
                    gname, gsize, gparts = "", 0, []
                    for gf, _gw, gv in _fields(dv):
                        if gf == 1:
                            gname = gv.decode()
                        elif gf == 2:
                            gsize = gv
                        elif gf == 3:
                            gparts.append(gv.decode())
                    groups.append((gname, gsize))
                    dyn_parts.extend(gparts)
                elif df == 2:
                    snapshot = dv
                elif df == 3:
                    vabc = dv

    print('PAYLOAD_PARTITIONS="%s"' % " ".join(parts))
    print('PAYLOAD_DYN_PARTITIONS="%s"' % " ".join(dyn_parts))
    print('PAYLOAD_DYN_GROUPS="%s"' % " ".join("%s:%d" % g for g in groups))
    print("PAYLOAD_SNAPSHOT=%d" % snapshot)
    print("PAYLOAD_VABC=%d" % vabc)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    cmd, target = sys.argv[1], sys.argv[2]
    if cmd == "super":
        super_info(target)
    elif cmd == "payload":
        payload_info(target)
    elif cmd == "sparse":
        sys.exit(0 if is_sparse(target) else 1)
    else:
        raise SystemExit(__doc__)
