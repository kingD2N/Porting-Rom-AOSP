#!/usr/bin/env python3
"""
fsconfig_check.py - cek hasil ekstrak image (extract.erofs / imgextractor) berdasarkan PATH,
bukan jumlah baris, dan bersihkan entri sintetis fs_config.

  fsconfig_check.py check    <root> <name>   -> cetak ringkasan; exit 1 kalau ada file asli yang hilang
  fsconfig_check.py sanitize <root> <name>   -> buang baris rusak/duplikat dari <root>/config/<name>_fs_config

Entri sintetis yang diabaikan:
  "/"  "/lost+found"  "<name>/lost+found/..."  dan baris berpath diakhiri "/"
  (imgextractor menulis slot direktori kosong lost+found sebagai "odm/lost+found/ 0 0 0000").
Partisi kecil (mis. odm ext4 AxionOS: 29 file, 5 entri sintetis) gagal di cek lama "2 + 3%".
"""
import bisect
import os
import sys


def entries(cfg):
    out = []
    with open(cfg, encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            out.append((line.split(" ", 1)[0], line))
    return out


def synthetic(path, name):
    if path in ("/", "/lost+found") or path.endswith("/"):
        return True
    if path == name + "/lost+found" or path.startswith(name + "/lost+found/"):
        return True
    return False


TOLERANCE = 2   # entri khusus (device node, nama aneh) yang boleh tidak terbentuk, tetap dicetak


def existing_paths(root, name):
    have = set()
    top = os.path.join(root, name)
    for dp, dns, fns in os.walk(top):
        rel = os.path.relpath(dp, root)
        have.add(rel)
        for n in dns + fns:
            have.add(os.path.join(rel, n))
    return have


def check(root, name):
    cfg = os.path.join(root, "config", name + "_fs_config")
    ents = entries(cfg)
    real = sorted({p for p, _ in ents if not synthetic(p, name)})
    have = existing_paths(root, name)
    srt = sorted(have)
    missing = []
    for p in real:
        if p in have:
            continue
        # nama berspasi: kolom pertama fs_config terpotong di spasi -> cocokkan awalan "p "
        i = bisect.bisect_left(srt, p + " ")
        if i < len(srt) and srt[i].startswith(p + " "):
            continue
        missing.append(p)
    print("fs_config %d entri, %d path asli, %d sintetis, hilang %d"
          % (len(ents), len(real), len(ents) - len(real), len(missing)))
    for p in missing[:15]:
        print("  HILANG " + p)
    if len(missing) > 15:
        print("  ... %d lainnya" % (len(missing) - 15))
    return 1 if len(missing) > TOLERANCE else 0


def sanitize(root, name):
    cfg = os.path.join(root, "config", name + "_fs_config")
    seen = set()
    keep = []
    dropped = 0
    for path, line in entries(cfg):
        if path.endswith("/") and path != "/":
            dropped += 1
            continue
        if path in seen:
            dropped += 1
            continue
        seen.add(path)
        keep.append(line)
    with open(cfg, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("\n".join(keep) + "\n")
    print("fs_config: %d baris rusak/duplikat dibuang" % dropped)
    return 0


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("check", "sanitize"):
        raise SystemExit(__doc__)
    fn = check if sys.argv[1] == "check" else sanitize
    return fn(sys.argv[2], sys.argv[3])


if __name__ == "__main__":
    sys.exit(main())
