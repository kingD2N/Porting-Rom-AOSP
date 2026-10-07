#!/usr/bin/env python3
"""
rom_branding.py - ubah identitas build ROM donor di build.prop: maintainer & status official.

  rom_branding.py --maintainer NAMA --type UNOFFICIAL PROPFILE...

- prop maintainer ROM (ro.<rom>.maintainer, ro.<rom>.build.maintainer, ...) -> NAMA
- prop jenis rilis ROM (ro.<rom>.releasetype, ro.<rom>.build.type, ro.<rom>.release_type, ...)
  bernilai OFFICIAL -> UNOFFICIAL (ro.build.type = user/userdebug TIDAK disentuh)
- kata OFFICIAL di nilai prop versi/nama tampilan (mis. ro.afterlife.version=8.4-Ophelia-OFFICIAL_...)
  -> UNOFFICIAL. Prop fingerprint/description tidak disentuh.
Huruf besar-kecil mengikuti aslinya (OFFICIAL/Official/official).
Output: satu baris per perubahan "file: key: lama -> baru", lalu "RESULT <maintainer> <official>".
"""
import argparse
import re

MAINT_KEY = re.compile(r'^ro\.(?!build\.|product\.|system\.|vendor\.|odm\.)[a-z0-9_.]*maintainer[a-z0-9_.]*$', re.I)
TYPE_KEY = re.compile(r'^ro\.(?!build\.|product\.|system\.|vendor\.|odm\.|system_ext\.)[a-z0-9_]+\.'
                      r'(?:[a-z0-9_]+\.)*(?:releasetype|release_type|release\.type|build\.type|buildtype|build_type|type)$', re.I)
SKIP_KEY = re.compile(r'fingerprint|description|\.build\.date|\.build\.id$', re.I)
WORD = re.compile(r'(?<![A-Za-z])(official)(?![A-Za-z])', re.I)


def unofficial(word, kind):
    k = kind.upper()
    if word.isupper():
        return k
    if word[0].isupper():
        return k.capitalize()
    return k.lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--maintainer", default="")
    ap.add_argument("--type", default="UNOFFICIAL")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    nm = no = 0
    for f in a.files:
        try:
            lines = open(f, encoding="utf-8", errors="surrogateescape").read().split("\n")
        except OSError:
            continue
        changed = False
        for i, line in enumerate(lines):
            if not line or line.lstrip().startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            nv = v
            if a.maintainer and MAINT_KEY.match(k):
                nv = a.maintainer
                if nv != v:
                    nm += 1
            elif TYPE_KEY.match(k) and v.strip().lower() == "official":
                nv = unofficial(v.strip(), a.type)
                no += 1
            elif not SKIP_KEY.search(k) and WORD.search(v):
                nv = WORD.sub(lambda m: unofficial(m.group(1), a.type), v)
                if nv != v:
                    no += 1
            if nv != v:
                print("%s: %s: %s -> %s" % (f, k, v, nv))
                lines[i] = "%s=%s" % (k, nv)
                changed = True
        if changed:
            open(f, "w", encoding="utf-8", errors="surrogateescape").write("\n".join(lines))
    print("RESULT %d %d" % (nm, no))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
