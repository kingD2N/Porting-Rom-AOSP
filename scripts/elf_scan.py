#!/usr/bin/env python3
"""
elf_scan.py - daftar executable ELF 32-bit (EI_CLASS=1) di folder bin/ vendor/odm.

  elf_scan.py <dir> [<dir> ...]   -> satu path per baris (relatif ke induk dir), lalu "RESULT <n>"

Library 32-bit di vendor/lib cuma dimuat proses 32-bit. Kalau tidak ada daemon/HAL 32-bit
di */bin, system donor 64-bit only tetap aman untuk vendor itu.
"""
import os
import sys


def main():
    n = 0
    for top in sys.argv[1:]:
        base = os.path.dirname(top.rstrip("/"))
        for sub in ("bin",):
            d = os.path.join(top, sub)
            for dp, _dns, fns in os.walk(d):
                for fn in fns:
                    p = os.path.join(dp, fn)
                    if os.path.islink(p) or not os.path.isfile(p):
                        continue
                    try:
                        with open(p, "rb") as f:
                            h = f.read(18)
                    except OSError:
                        continue
                    # ELF, 32-bit, e_type ET_EXEC(2)/ET_DYN(3), bukan Hexagon (e_machine 164)
                    if len(h) == 18 and h[:4] == b"\x7fELF" and h[4] == 1:
                        mach = int.from_bytes(h[16:18], "little")
                        if mach == 164:
                            continue
                        print(os.path.relpath(p, base))
                        n += 1
    print("RESULT %d" % n)


if __name__ == "__main__":
    main()
