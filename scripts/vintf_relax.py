#!/usr/bin/env python3
"""
vintf_relax.py - tandai HAL framework yang TIDAK disediakan ROM donor sebagai optional
di device compatibility matrix vendor/odm.

  vintf_relax.py --hal NAMA [--hal NAMA ...] <compatibility_matrix.xml> [...]

Device matrix vendor menyebut HAL framework yang dibutuhkan vendor (mis.
vendor.qti.hardware.sigma_miracast dari stack WFD Qualcomm di system_ext ROM base).
Kalau framework donor tidak menyediakannya, cek VINTF saat boot gagal -> dialog
"There's an internal problem with your device". Fiturnya tetap tidak ada; yang
diubah hanya status "wajib" -> "opsional" supaya cek lain tetap valid.

Edit berbasis teks (format & komentar file dipertahankan). Output satu baris per perubahan,
lalu "RESULT <jumlah>".
"""
import argparse
import re
import sys

HAL_RE = re.compile(r"<hal\b([^>]*)>(.*?)</hal>", re.S)
NAME_RE = re.compile(r"<name>\s*([^<\s]+)\s*</name>")


def relax(path, names):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    changes = 0

    def repl(m):
        nonlocal changes
        attrs, body = m.group(1), m.group(2)
        nm = NAME_RE.search(body)
        if not nm or nm.group(1) not in names:
            return m.group(0)
        if re.search(r'\boptional\s*=\s*"true"', attrs):
            return m.group(0)
        if re.search(r'\boptional\s*=\s*"[^"]*"', attrs):
            attrs = re.sub(r'\boptional\s*=\s*"[^"]*"', 'optional="true"', attrs)
        else:
            attrs = attrs.rstrip() + ' optional="true"'
            if not attrs.startswith(" "):
                attrs = " " + attrs
        changes += 1
        print("  optional=\"true\": %s (%s)" % (nm.group(1), path))
        return "<hal%s>%s</hal>" % (attrs, body)

    new = HAL_RE.sub(repl, text)
    if changes:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
    return changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hal", action="append", default=[])
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    names = set(a.hal)
    total = sum(relax(f, names) for f in a.files) if names else 0
    print("RESULT %d" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
