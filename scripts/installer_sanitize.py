#!/usr/bin/env python3
"""
installer_sanitize.py - pastikan META-INF cuma FLASH: semua perintah yang
menghapus / memformat data (userdata, metadata, cache, /data) dinetralkan.

  installer_sanitize.py <META-INF dir>

- updater-script (edify): format(), wipe_cache(), wipe_block_device(),
  delete()/delete_recursive() dan run_program() yang menyentuh data
  -> diganti ui_print(...) (ekspresi tetap valid di dalam ifelse / ||).
- skrip shell (update-binary teks, *.sh): baris yang menghapus / memformat data
  -> diganti ':' (no-op, sintaks if/then tetap valid).
- update-binary ELF (interpreter edify) tidak diubah: dia cuma menjalankan updater-script.
Output: satu baris per perubahan + "RESULT <dinetralkan> <tersisa>".
Exit 0; <tersisa> > 0 berarti masih ada perintah hapus data (pemanggil harus gagal).
"""
import os
import re
import sys

DATA_RE = re.compile(r'userdata|by-name/metadata|by-name/cache|"/data\b|/data/|"/metadata|"/cache\b', re.I)
SH_WIPE_RE = re.compile(
    r'\btwrp\s+(wipe|format)\b|\bmke2fs\b|\bmake_f2fs\b|\bmkfs\.|\bblkdiscard\b|\bsgdisk\b'
    r'|\brm\s+-[a-z]*r[a-z]*\s+[^;#]*(/data|/metadata|/cache)\b'
    r'|\bdd\b[^;#]*of=[^;#]*(userdata|metadata)'
    r'|--wipe[_-]data|\brecovery\b[^;#]*--wipe', re.I)
ALWAYS = ("format", "wipe_cache", "wipe_data")
IF_DATA = ("wipe_block_device", "delete", "delete_recursive", "run_program", "set_metadata_recursive",
           "mount", "unmount")
RISKY_CMD = re.compile(r'\b(rm|mke2fs|make_f2fs|mkfs|blkdiscard|dd|wipe|format|erase|twrp)\b', re.I)
MSG = 'ui_print("- langkah hapus data dilewati (data tetap aman)")'


def call_end(s, i):
    """i menunjuk '(' -> index setelah ')' penutup (menghormati string)"""
    depth, q = 0, False
    while i < len(s):
        c = s[i]
        if q:
            if c == "\\":
                i += 1
            elif c == '"':
                q = False
        elif c == '"':
            q = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def dangerous_edify(name, text):
    if name in ALWAYS:
        return True
    if name in ("mount", "unmount"):
        return False                      # mount /data tidak menghapus apa pun
    if name == "run_program":
        return bool(SH_WIPE_RE.search(text) or (DATA_RE.search(text) and RISKY_CMD.search(text)))
    return bool(DATA_RE.search(text))


def sanitize_edify(s):
    names = ALWAYS + IF_DATA
    pat = re.compile(r'\b(' + "|".join(names) + r')\s*\(')
    out, pos, done = [], 0, []
    for m in pat.finditer(s):
        if m.start() < pos:
            continue                      # di dalam panggilan yang sudah diganti
        end = call_end(s, m.end() - 1)
        if end < 0:
            continue
        text = s[m.start():end]
        if dangerous_edify(m.group(1), text):
            out.append(s[pos:m.start()])
            out.append(MSG)
            done.append(" ".join(text.split())[:160])
            pos = end
    out.append(s[pos:])
    return "".join(out), done


def remaining_edify(s):
    left = []
    for m in re.finditer(r'\b(' + "|".join(ALWAYS + IF_DATA) + r')\s*\(', s):
        end = call_end(s, m.end() - 1)
        if end > 0 and dangerous_edify(m.group(1), s[m.start():end]):
            left.append(" ".join(s[m.start():end].split())[:160])
    return left


def sanitize_shell(s):
    out, done = [], []
    for line in s.split("\n"):
        code = line.split("#", 1)[0] if not line.lstrip().startswith("#!") else ""
        if code.strip() and SH_WIPE_RE.search(code):
            indent = line[:len(line) - len(line.lstrip())]
            out.append(indent + ": # langkah hapus data dilewati (data tetap aman)")
            done.append(line.strip()[:160])
        else:
            out.append(line)
    return "\n".join(out), done


def is_text(path):
    with open(path, "rb") as f:
        head = f.read(4096)
    return b"\0" not in head and not head.startswith(b"\x7fELF")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    meta = sys.argv[1]
    fixed, left = 0, 0
    for root, _d, files in os.walk(meta):
        for fn in sorted(files):
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, os.path.dirname(meta))
            if not is_text(p):
                if fn == "update-binary":
                    print("INFO  %s: biner (interpreter edify), cuma menjalankan updater-script" % rel)
                continue
            with open(p, encoding="utf-8", errors="surrogateescape") as f:
                s = f.read()
            if fn == "updater-script":
                if s.startswith("#!"):
                    new, done = sanitize_shell(s)       # updater-script dummy / shell
                else:
                    new, done = sanitize_edify(s)
                    left_items = remaining_edify(new)
                    for t in left_items:
                        print("LEFT  %s: %s" % (rel, t))
                    left += len(left_items)
            elif fn == "update-binary" or fn.endswith(".sh"):
                new, done = sanitize_shell(s)
                for line in new.split("\n"):
                    code = line.split("#", 1)[0]
                    if code.strip() and SH_WIPE_RE.search(code):
                        print("LEFT  %s: %s" % (rel, line.strip()[:160]))
                        left += 1
            else:
                continue
            for t in done:
                print("FIX   %s: %s" % (rel, t))
            if done:
                with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(new)
                fixed += len(done)
    print("RESULT %d %d" % (fixed, left))
    return 0


if __name__ == "__main__":
    sys.exit(main())
