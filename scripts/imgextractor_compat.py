#!/usr/bin/env python3
"""
imgextractor_compat.py - jalankan imgextractor.py toolkit dengan deteksi "MOTO" yang aman.

  imgextractor_compat.py <path imgextractor.py toolkit> <image.img> <out_dir>

imgextractor.py menganggap image berstruktur Motorola kalau 500 KB pertamanya memuat byte
"MOTO" di mana saja. Image ext4 biasa dari ROM Motorola / ROM yang memuat string itu ikut
terdeteksi, lalu fix_moto() tidak menemukan offset (superblock ext4 memang di 1080) dan tetap
MENGHAPUS image aslinya -> "FileNotFoundError: product.img_ -> product.img", ekstrak gagal.
Di sini perbaikan MOTO hanya dijalankan kalau superblock ext4 TIDAK ada di offset normal (1080).
"""
import os
import sys

OLD = "if re.search(b'\\x4d\\x4f\\x54\\x4f', data):\n                print(\".....MOTO structure! Fixing.....\")"
NEW = ("if re.search(b'\\x4d\\x4f\\x54\\x4f', data) and data[1080:1082] != b'\\x53\\xef':\n"
       "                print(\".....MOTO structure! Fixing.....\")")


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    path = os.path.realpath(sys.argv[1])
    src = open(path, encoding="utf-8").read()
    if OLD in src:
        src = src.replace(OLD, NEW, 1)
    else:
        print("imgextractor_compat: pola deteksi MOTO tidak ditemukan, dijalankan apa adanya", file=sys.stderr)
    sys.path.insert(0, os.path.dirname(path))      # import ext4 dari folder toolkit
    sys.argv = [path] + sys.argv[2:]
    glb = {"__name__": "__main__", "__file__": path}
    exec(compile(src, path, "exec"), glb)


if __name__ == "__main__":
    main()
