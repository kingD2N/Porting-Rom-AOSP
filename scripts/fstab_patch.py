#!/usr/bin/env python3
"""
fstab_patch.py - patch fstab Android (vendor/etc/fstab.* dan first-stage fstab
di ramdisk vendor_boot) untuk ROM port.

  fstab_patch.py <fstab> [--no-avb] [--no-encrypt]
                         [--ext4 "vendor odm"] [--erofs "system product"] [--rw "vendor odm"]

--no-avb      hapus flag avb, avb=*, avb_keys=*
--no-encrypt  hapus fileencryption=, metadata_encryption=, keydirectory=,
              forceencrypt=, forcefdeorfbe=, encryptable=, inlinecrypt
--ext4 LIST   pastikan mount point di LIST punya baris ext4 (dibuat dari baris
              erofs kalau belum ada, diletakkan paling atas supaya dicoba dulu)
--erofs LIST  pastikan mount point di LIST punya baris erofs (dibuat dari baris
              ext4/f2fs kalau belum ada, opsi mount "ro", diletakkan setelahnya).
              Partisi port dibangun EROFS; fstab ROM base yang cuma kenal ext4 = gagal mount
--rw LIST     baris ext4 untuk mount point di LIST di-mount rw (bukan ro)
"""
import argparse
import sys

ENCRYPT_PREFIXES = ("fileencryption", "metadata_encryption", "keydirectory",
                    "forceencrypt", "forcefdeorfbe", "encryptable", "inlinecrypt")


def mount_name(mnt):
    return mnt.strip("/") or "/"


def patch(path, no_avb, no_encrypt, ext4_set, rw_set, erofs_set=frozenset()):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().splitlines()

    entries = []  # (is_entry, raw_or_fields)
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            entries.append((False, line))
            continue
        fields = s.split()
        if len(fields) < 4:
            entries.append((False, line))
            continue
        if len(fields) == 4:
            fields.append("defaults")
        entries.append((True, fields))

    changes = []

    # 1. flag fsmgr
    for is_entry, fields in entries:
        if not is_entry:
            continue
        flags = fields[4].split(",")
        new = []
        for fl in flags:
            key = fl.split("=", 1)[0]
            if no_avb and (key == "avb" or key.startswith("avb_") or key.startswith("avb=")):
                continue
            if no_encrypt and key.startswith(ENCRYPT_PREFIXES):
                continue
            new.append(fl)
        if not new:
            new = ["defaults"]
        if new != flags:
            changes.append("%s: fsmgr %s -> %s" % (fields[1], fields[4], ",".join(new)))
            fields[4] = ",".join(new)

    # 2. baris ext4 untuk partisi yang dikonversi
    out = []
    has_ext4 = {}
    has_erofs = {}
    for is_entry, fields in entries:
        if is_entry and fields[2] == "ext4":
            has_ext4[mount_name(fields[1])] = True
        if is_entry and fields[2] == "erofs":
            has_erofs[mount_name(fields[1])] = True
    added = set()
    added_erofs = set()
    for is_entry, fields in entries:
        if is_entry:
            name = mount_name(fields[1])
            if (name in ext4_set and not has_ext4.get(name) and name not in added
                    and fields[2] in ("erofs", "f2fs")):
                clone = list(fields)
                clone[2] = "ext4"
                clone[3] = "ro,barrier=1,discard"
                out.append((True, clone))
                added.add(name)
                changes.append("%s: tambah baris ext4 (dari %s)" % (fields[1], fields[2]))
        out.append((is_entry, fields))
        if is_entry:
            name = mount_name(fields[1])
            if (name in erofs_set and not has_erofs.get(name) and name not in added_erofs
                    and fields[2] in ("ext4", "f2fs")):
                clone = list(fields)
                clone[2] = "erofs"
                clone[3] = "ro"
                out.append((True, clone))
                added_erofs.add(name)
                changes.append("%s: tambah baris erofs (dari %s)" % (fields[1], fields[2]))

    # 3. rw untuk baris ext4
    for is_entry, fields in out:
        if not is_entry or fields[2] != "ext4":
            continue
        if mount_name(fields[1]) not in rw_set:
            continue
        opts = fields[3].split(",")
        if "ro" in opts:
            opts = ["rw" if o == "ro" else o for o in opts]
            changes.append("%s: ro -> rw" % fields[1])
            fields[3] = ",".join(opts)

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        for is_entry, item in out:
            if is_entry:
                f.write("%-56s %-24s %-8s %-40s %s\n"
                        % (item[0], item[1], item[2], item[3], " ".join(item[4:])))
            else:
                f.write(item + "\n")

    for c in changes:
        print("  [fstab] " + c)
    if not changes:
        print("  [fstab] tidak ada perubahan: " + path)


def _set(value):
    return {x for x in value.replace(",", " ").split() if x}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fstab")
    ap.add_argument("--no-avb", action="store_true")
    ap.add_argument("--no-encrypt", action="store_true")
    ap.add_argument("--ext4", default="", help="daftar mount point (spasi/koma)")
    ap.add_argument("--erofs", default="", help="daftar mount point (spasi/koma)")
    ap.add_argument("--rw", default="", help="daftar mount point (spasi/koma)")
    a = ap.parse_args()
    patch(a.fstab, a.no_avb, a.no_encrypt, _set(a.ext4), _set(a.rw), _set(a.erofs))


if __name__ == "__main__":
    sys.exit(main())
