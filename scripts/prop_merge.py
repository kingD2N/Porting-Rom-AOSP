#!/usr/bin/env python3
"""
prop_merge.py - salin props khas device dari build.prop base (ingres) ke
build.prop port (donor AOSP), tanpa menyentuh props identitas/versi build donor.

  prop_merge.py <base.prop> <port.prop> [--allow REGEX ...] [--dry-run]

Aturan:
- key identitas/versi build (ID_DENY) tidak pernah disentuh
- tanpa --allow : semua key lain dari base disalin (mode lama, + DENY tambahan)
- dengan --allow: HANYA key yang cocok salah satu REGEX yang disalin
  (dipakai untuk port AOSP: build.prop product base berisi props ROM base
   seperti ro.lineage.* / ro.miui.* yang tidak boleh ikut ke ROM donor)
- key base: ditimpa kalau ada di port dengan nilai berbeda, ditambah kalau belum ada
- baris 'import', komentar dan key yang cuma ada di port dibiarkan
Output: satu baris per perubahan ("~ key: lama -> baru" / "+ key=nilai").
"""
import re
import sys

# identitas & versi ROM donor: tidak pernah ditimpa
ID_DENY = [
    r"ro\.build\..*", r"ro\.[a-z_]+\.build\..*", r"ro\.product\.build\..*",
    r"ro\.system\..*", r"ro\.system_ext\..*", r"ro\.com\.google\..*",
    r"ro\.apex\..*", r"ro\.boot\..*", r"ro\.adb\..*", r"ro\.debuggable", r"ro\.secure",
    r"ro\.control_privapp_permissions", r"ro\.postinstall\..*",
    r"ro\.product\.(product|system|system_ext|odm)\.(device|name|model|brand|manufacturer|marketname)",
    r"ro\.product\.mod_device", r"ro\.product\.cert", r"ro\.build\.product",
    r"ro\.[a-z_]*\.api_level", r"ro\.product\.first_api_level", r"ro\.vndk\..*",
    r"ro\.zygote.*",
    # versi/identitas ROM custom (lineage, axion, crdroid, evolution, ...)
    r"ro\.[a-z0-9_]+\.(version|display\.version|build\.version|releasetype|device|maintainer|build_type)(\..*)?",
    r"ro\.modversion", r"ro\.mi\.os\..*", r"ro\.miui\..*",
]
# mode lama (tanpa --allow): tambahan yang tidak disalin
DENY = [
    r"dalvik\..*", r"persist\.sys\.dalvik\..*", r"ro\.dalvik\..*",
    r"ro\.surface_flinger\.supports_background_blur",
]
ID_DENY_RE = re.compile("^(" + "|".join(ID_DENY) + ")$")
DENY_RE = re.compile("^(" + "|".join(DENY) + ")$")
LINE_RE = re.compile(r"^\s*([A-Za-z0-9_.\-]+)\s*=(.*)$")


def read_props(path):
    props = {}
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            m = LINE_RE.match(line.rstrip("\n"))
            if m:
                props[m.group(1)] = m.group(2)
    return props


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    base_path, port_path = args[0], args[1]
    dry = "--dry-run" in args[2:]
    allow = []
    i = 2
    while i < len(args):
        if args[i] == "--allow" and i + 1 < len(args):
            allow.append(args[i + 1])
            i += 2
        else:
            i += 1
    allow_re = re.compile("^(" + "|".join(allow) + ")$") if allow else None

    def wanted(key):
        if ID_DENY_RE.match(key):
            return False
        if allow_re is not None:
            return bool(allow_re.match(key))
        return not DENY_RE.match(key)

    base = read_props(base_path)
    with open(port_path, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().split("\n")

    seen = set()
    changes = []
    out = []
    for line in lines:
        m = LINE_RE.match(line)
        if m:
            key, val = m.group(1), m.group(2)
            seen.add(key)
            if key in base and wanted(key) and base[key] != val:
                changes.append("~ %s: %s -> %s" % (key, val, base[key]))
                line = "%s=%s" % (key, base[key])
        out.append(line)

    added = [k for k in base if k not in seen and wanted(k)]
    if added:
        if out and out[-1] == "":
            out.pop()
        out.append("")
        out.append("# ---- props device dari base (prop_merge.py)")
        for k in added:
            out.append("%s=%s" % (k, base[k]))
            changes.append("+ %s=%s" % (k, base[k]))
        out.append("")

    if not dry:
        with open(port_path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write("\n".join(out))
    for c in changes:
        print(c)


if __name__ == "__main__":
    main()
