#!/usr/bin/env python3
"""
rom_branding.py - ubah identitas build ROM donor di build.prop: maintainer & status official.

  rom_branding.py --maintainer NAMA --type UNOFFICIAL [--cpu X] [--camera-rear X] [--camera-front X]
                  [--battery X] [--screen X] PROPFILE...

- prop maintainer ROM (ro.<rom>.maintainer, ro.<rom>.build.maintainer, ...) -> NAMA; prop data
  maintainer lama lainnya (ro.<rom>.maintainer.photo/.github/.telegram/... ) dikosongkan
- prop jenis rilis ROM (ro.<rom>.releasetype, ro.<rom>.build.type, ro.<rom>.release_type, ...)
  bernilai OFFICIAL -> UNOFFICIAL (ro.build.type = user/userdebug TIDAK disentuh)
- kata OFFICIAL di nilai prop versi/nama tampilan (mis. ro.afterlife.version=8.4-Ophelia-OFFICIAL_...)
  -> UNOFFICIAL. Prop fingerprint/description tidak disentuh.
- prop spesifikasi device di halaman Tentang ponsel yang diisi build ROM donor dengan data HP donor
  (mis. AxionOS: persist.sys.axion_cpu_info, persist.sys.device_camera_info_rear/front) -> data device
  target. Hanya prop yang sudah ada di donor yang diubah; tidak ada prop baru.
Prop maintainer juga dikenali di persist.sys.* (AxionOS: persist.sys.axion_maintainer).
Huruf besar-kecil mengikuti aslinya (OFFICIAL/Official/official).
Output: satu baris per perubahan "file: key: lama -> baru", lalu "RESULT <maintainer> <official>".
"""
import argparse
import re

MAINT_KEY = re.compile(r'^(?:ro|persist\.sys)\.(?!build\.|product\.|system\.|vendor\.|odm\.)[a-z0-9_.]*maintainer[a-z0-9_.]*$', re.I)
# prop teks spesifikasi (bukan prop hardware asli seperti ro.soc.model/ro.board.platform)
SPEC_PREFIX = re.compile(r'^(?:ro|persist\.sys)\.(?!soc\.|board\.|hardware|product\.|build\.|vendor\.|odm\.|boot\.)', re.I)
SPEC_KEYS = (
    ("cpu", re.compile(r'(?:cpu[._]?info|cpu[._]name|cpu[._]model|processor|chipset|soc[._]name)$', re.I)),
    ("camera_rear", re.compile(r'camera[._]?info[._](?:rear|back|main)$|(?:rear|back)[._]camera[._]?info$', re.I)),
    ("camera_front", re.compile(r'camera[._]?info[._](?:front|selfie)$|front[._]camera[._]?info$', re.I)),
    ("battery", re.compile(r'battery[._]?(?:info|capacity)$', re.I)),
    ("screen", re.compile(r'(?:screen|display)[._]?(?:info|resolution)$', re.I)),
)
TYPE_KEY = re.compile(r'^ro\.(?!build\.|product\.|system\.|vendor\.|odm\.|system_ext\.)[a-z0-9_]+\.'
                      r'(?:[a-z0-9_]+\.)*(?:releasetype|release_type|release\.type|build\.type|buildtype|build_type|type)$', re.I)
EXTRA_KEY = re.compile(r'photo|avatar|image|picture|pic|icon|github|git|telegram|tg|facebook|fb|instagram|insta|ig|'
                       r'twitter|tiktok|youtube|yt|xda|link|url|uri|web|site|donat|paypal|support|social|contact|mail|email', re.I)
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
    for k, _ in SPEC_KEYS:
        ap.add_argument("--" + k.replace("_", "-"), default="")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    nm = no = ns = 0
    spec = {k: getattr(a, k) for k, _ in SPEC_KEYS}
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
            kind = None
            if SPEC_PREFIX.match(k) and "maintainer" not in k.lower():
                kind = next((n for n, rx in SPEC_KEYS if rx.search(k)), None)
            if kind and spec.get(kind) and v.strip() and v.strip().lower() not in ("true", "false", "0", "1"):
                nv = spec[kind]
                if nv != v:
                    ns += 1
            elif a.maintainer and MAINT_KEY.match(k):
                # data maintainer lama selain nama (foto, link sosial media, donasi) dikosongkan
                nv = "" if EXTRA_KEY.search(k.split("maintainer", 1)[-1]) else a.maintainer
                if nv != v:
                    nm += 1
            elif a.type and TYPE_KEY.match(k) and v.strip().lower() == "official":
                nv = unofficial(v.strip(), a.type)
                no += 1
            elif a.type and not SKIP_KEY.search(k) and WORD.search(v):
                nv = WORD.sub(lambda m: unofficial(m.group(1), a.type), v)
                if nv != v:
                    no += 1
            if nv != v:
                print("%s: %s: %s -> %s" % (f, k, v, nv))
                lines[i] = "%s=%s" % (k, nv)
                changed = True
        if changed:
            open(f, "w", encoding="utf-8", errors="surrogateescape").write("\n".join(lines))
    print("RESULT %d %d %d" % (nm, no, ns))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
