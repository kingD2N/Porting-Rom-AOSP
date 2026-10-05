#!/usr/bin/env python3
"""
apk_index.py - baca nama package dari AndroidManifest.xml biner (AXML) di APK,
tanpa aapt. Dipakai untuk debloat berdasarkan nama package.

  apk_index.py <root>          -> "<package>\t<folder app relatif ke root>" per APK
  apk_index.py --apk <file>    -> nama package satu APK
  apk_index.py --info <file>   -> "<package>\t<sharedUserId atau ->" satu APK
"""
import os
import struct
import sys
import zipfile

RES_STRING_POOL = 0x0001
RES_XML_START_ELEMENT = 0x0102
UTF8_FLAG = 0x100


def _strings(buf, off):
    (_t, hsize, _size, count, _style, flags, str_start, _sty_start) = struct.unpack_from("<HHIIIIII", buf, off)
    offsets = struct.unpack_from("<%dI" % count, buf, off + hsize)
    base = off + str_start
    utf8 = bool(flags & UTF8_FLAG)
    out = []
    for o in offsets:
        p = base + o
        if utf8:
            n = buf[p]; p += 1
            if n & 0x80:
                p += 1
            ln = buf[p]; p += 1
            if ln & 0x80:
                ln = ((ln & 0x7F) << 8) | buf[p]; p += 1
            out.append(buf[p:p + ln].decode("utf-8", "replace"))
        else:
            ln = struct.unpack_from("<H", buf, p)[0]; p += 2
            if ln & 0x8000:
                ln = ((ln & 0x7FFF) << 16) | struct.unpack_from("<H", buf, p)[0]; p += 2
            out.append(buf[p:p + ln * 2].decode("utf-16-le", "replace"))
    return out


def manifest_package(data):
    """nama package dari AXML AndroidManifest.xml (atau None)"""
    return manifest_attrs(data).get("package")


def manifest_attrs(data):
    """atribut string elemen <manifest> (package, sharedUserId, ...) dari AXML"""
    if len(data) < 8:
        return {}
    _t, hsize, _size = struct.unpack_from("<HHI", data, 0)
    pos = hsize
    strings = []
    while pos + 8 <= len(data):
        ctype, chsize, csize = struct.unpack_from("<HHI", data, pos)
        if csize < 8:
            break
        if ctype == RES_STRING_POOL:
            strings = _strings(data, pos)
        elif ctype == RES_XML_START_ELEMENT:
            # header(16) + ns(4) name(4) attrStart(2) attrSize(2) attrCount(2) ...
            name_idx = struct.unpack_from("<I", data, pos + 20)[0]
            a_start, a_size, a_count = struct.unpack_from("<HHH", data, pos + 24)
            if name_idx < len(strings) and strings[name_idx] == "manifest":
                ap = pos + 16 + a_start
                attrs = {}
                for i in range(a_count):
                    _ns, an, raw = struct.unpack_from("<III", data, ap + i * a_size)
                    if an < len(strings) and raw < len(strings):
                        attrs[strings[an]] = strings[raw]
                return attrs
        pos += csize
    return {}


def apk_package(path):
    try:
        with zipfile.ZipFile(path) as z:
            return manifest_package(z.read("AndroidManifest.xml"))
    except Exception:
        return None


def apk_info(path):
    try:
        with zipfile.ZipFile(path) as z:
            return manifest_attrs(z.read("AndroidManifest.xml"))
    except Exception:
        return {}


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--info":
        a = apk_info(sys.argv[2])
        print("%s\t%s" % (a.get("package", ""), a.get("sharedUserId") or "-"))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--apk":
        print(apk_package(sys.argv[2]) or "")
        return
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    root = sys.argv[1]
    for dirpath, _dirs, files in os.walk(root):
        parent = os.path.basename(os.path.dirname(dirpath))
        if parent not in ("app", "priv-app", "data-app"):
            continue
        for f in files:
            if f.endswith(".apk"):
                pkg = apk_package(os.path.join(dirpath, f))
                if pkg:
                    print("%s\t%s" % (pkg, os.path.relpath(dirpath, root)))
                break


if __name__ == "__main__":
    main()
