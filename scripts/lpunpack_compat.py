#!/usr/bin/env python3
"""
lpunpack_compat.py - jalankan lpunpack.py toolkit di Python mana pun.

  lpunpack_compat.py <path lpunpack.py toolkit> <super_raw.img> <out_dir> [opsi lpunpack lain]

lpunpack.py toolkit memakai "@classmethod" + "@property" bertumpuk, yang dihapus di
Python 3.13 (TypeError: slice indices must be integers). Di sini dekorator itu diganti
descriptor classproperty lalu skrip dijalankan apa adanya. Binary lpunpack toolkit tidak
dipakai karena lebih tua dari lpmake (menolak metadata Virtual A/B: "invalid checksum").
"""
import re
import sys


class _classproperty:
    def __init__(self, f):
        self.f = f

    def __get__(self, obj, cls):
        return self.f(cls)


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    src = open(path, encoding="utf-8").read()
    src = re.sub(r"@classmethod\s*\n\s*@property", "@_classproperty", src)
    sys.argv = [path] + sys.argv[2:]
    glb = {"__name__": "__main__", "__file__": path, "_classproperty": _classproperty}
    exec(compile(src, path, "exec"), glb)


if __name__ == "__main__":
    main()
