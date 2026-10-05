#!/usr/bin/env python3
"""
prop_effective.py - hitung nilai props yang BERLAKU saat boot, mengikuti urutan
load init Android (file belakangan menimpa yang duluan):

  system -> system_ext -> vendor -> odm (+ import sku) -> product  (AOSP; mi_ext hanya HyperOS)

  prop_effective.py --sku ingres --map /system=DIR ... label=FILE [label=FILE ...]

--map /odm=DIR   dipakai untuk mengikuti baris 'import /odm/etc/${ro.boot.product.hardware.sku}_build.prop'
Output:
  KEY  nilai  (sumber)           untuk daftar key penting
  OVERRIDE key: vendor 'a' -> product 'b'   props vendor/odm yang ditimpa partisi setelahnya
  RESULT <jumlah override key penting>
"""
import argparse
import os
import re

KEYS = [
    "ro.product.vendor.device", "ro.product.vendor.name", "ro.product.vendor.model",
    "ro.product.vendor.brand", "ro.product.vendor.manufacturer", "ro.product.vendor.marketname",
    "ro.product.vendor.cert", "ro.vendor.build.fingerprint", "ro.product.board", "ro.board.platform",
    "ro.vndk.version", "ro.product.odm.device", "ro.product.odm.model", "ro.product.odm.marketname",
    "ro.product.product.device", "ro.product.product.model", "ro.product.system.device",
    "ro.product.mod_device", "ro.build.product", "ro.product.device",
    # API level: first_api_level = Android saat HP rilis (ingres: 31 / Android 12)
    "ro.product.first_api_level", "ro.board.first_api_level", "ro.board.api_level", "ro.vendor.api_level",
    "ro.build.version.sdk", "ro.vendor.build.version.sdk",
    # ABI & zygote: vendor 32-bit butuh system yang masih punya lib 32-bit
    "ro.vendor.product.cpu.abilist", "ro.system.product.cpu.abilist", "ro.zygote",
    # patch level: keymint membandingkan patch level boot/vendor
    "ro.vendor.build.security_patch", "ro.build.version.security_patch",
]
# nilai ini milik hardware: kalau vendor/odm sudah mengisi, partisi lain tidak boleh mengubahnya
HW_KEYS = {"ro.product.board", "ro.board.platform", "ro.vndk.version", "ro.vendor.build.fingerprint"}
LINE = re.compile(r"^\s*([A-Za-z0-9_.\-]+)\s*=(.*)$")
IMPORT = re.compile(r"^\s*import\s+(\S+)")


def load(path, label, props, src, maps, sku, seen):
    if not path or not os.path.isfile(path) or path in seen:
        return
    seen.add(path)
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = IMPORT.match(line)
            if m:
                imp = m.group(1).replace("${ro.boot.product.hardware.sku}", sku).replace("${ro.boot.hardware.sku}", sku)
                if "$" in imp:
                    continue
                for mnt, d in maps.items():
                    if imp.startswith(mnt + "/"):
                        load(os.path.join(d, imp[len(mnt) + 1:]), label, props, src, maps, sku, seen)
                        break
                continue
            m = LINE.match(line)
            if m and not line.lstrip().startswith("#"):
                k, v = m.group(1), m.group(2).strip()
                hist = src.setdefault(k, [])
                if not hist or hist[-1] != (label, v):
                    hist.append((label, v))
                props[k] = v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sku", default="")
    ap.add_argument("--map", action="append", default=[])
    ap.add_argument("--get", default="", help="cetak nilai efektif satu key saja")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    maps = dict(m.split("=", 1) for m in a.map)
    props, src, seen = {}, {}, set()
    for item in a.files:
        label, path = item.split("=", 1)
        load(path, label, props, src, maps, a.sku, seen)

    if a.get:
        print(props.get(a.get, ""))
        return 0

    # ro.product.device: diturunkan init dari ro.product.<partisi>.device (urutan product,odm,vendor,system_ext,system)
    if "ro.product.device" not in props:
        for p in ("product", "odm", "vendor", "system_ext", "system"):
            v = props.get("ro.product.%s.device" % p)
            if v:
                props["ro.product.device"] = v
                src["ro.product.device"] = [("dari ro.product.%s.device" % p, v)]
                break

    for k in KEYS:
        if k in props:
            print("KEY  %-34s %-40s (%s)" % (k, props[k] or '""', src[k][-1][0]))
        else:
            print("KEY  %-34s %-40s" % (k, "- (tidak diset)"))
    bad = 0
    for k, hist in sorted(src.items()):
        hw = [h for h in hist if h[0] in ("vendor", "odm")]
        if not hw:
            continue
        last = hist[-1]
        if last[0] not in ("vendor", "odm") and last[1] != hw[-1][1]:
            important = k in HW_KEYS or k.startswith(("ro.product.vendor.", "ro.vendor."))
            print("OVERRIDE %s %s: %s '%s' -> %s '%s'" % ("!!" if important else "  ", k, hw[-1][0], hw[-1][1], last[0], last[1]))
            if important:
                bad += 1
    print("RESULT %d" % bad)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
