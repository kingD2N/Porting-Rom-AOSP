#!/usr/bin/env python3
"""
addon_tool.py - helper addon port (kamera MIUI, Dolby).

  addon_tool.py cil TEMPLATE --vendor-cil F --plat-pub F --ver V --tag T [--each NAME=a,b ...] [--plat-cil F ...]
        resolve {type} di template ke nama di policy vendor (type vendor), atau nama
        berversi (type publik plat, mis. platform_app_202504), atau atribut plat.
        Baris dengan type yang tidak dikenal dibuang (dilaporkan ke stderr).
        Output CIL (tiap baris + tag) ke stdout.
  addon_tool.py ctx CONFIG PART_ROOT PART REL[=LABEL] ...
        tambah label SELinux persis untuk file/folder baru ke config <part>_file_contexts
        (repack). Tanpa LABEL: label file saudara di folder yang sama (mayoritas), atau
        label folder induk. Mencegah contextpatch menebak label dari path yang mirip.
  addon_tool.py effects XML LIB=PATH ... --effect NAME=LIB:UUID ... [--drop-helpers]
        tambah <library>/<effect> ke audio_effects.xml (idempoten). --drop-helpers buang
        <apply effect="*_helper"> (kecuali voice) di <postprocess> (diganti volume listener Dolby).
  addon_tool.py allowlist PKG OUT REQ_FILE [XML ...]
        allowlist privapp-permissions = izin dari XML (paket PKG) + izin yang diminta APK.
  addon_tool.py soname SRC DST OLD NEW
        salin library dengan string SONAME diganti (panjang NEW <= OLD, sisa diisi NUL).
  addon_tool.py lfs POINTER
        cetak "<sha256> <size>" dari pointer git-lfs (kosong kalau bukan pointer).
"""
import os
import re
import sys
from collections import Counter

TYPE_DECL = re.compile(r'^\((?:type|typeattribute)\s+([A-Za-z0-9_.]+)\)', re.M)
PLACEHOLDER = re.compile(r'\{([A-Za-z0-9_]+)\}')


def cmd_cil(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="addon_tool.py cil")
    ap.add_argument("template")
    ap.add_argument("--vendor-cil", required=True)
    ap.add_argument("--plat-pub", required=True)
    ap.add_argument("--ver", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--each", action="append", default=[])
    ap.add_argument("--plat-cil", action="append", default=[],
                    help="CIL system/system_ext donor: type yang hanya ada di sana dipakai apa adanya "
                         "(mis. platform_app_36 Android 17, tidak punya versi di plat_pub_versioned)")
    a = ap.parse_args(argv)

    vend = set(TYPE_DECL.findall(open(a.vendor_cil, encoding="utf-8", errors="replace").read()))
    pub = set(TYPE_DECL.findall(open(a.plat_pub, encoding="utf-8", errors="replace").read()))
    plat = set()
    for f in a.plat_cil:
        try:
            plat |= set(TYPE_DECL.findall(open(f, encoding="utf-8", errors="replace").read()))
        except OSError:
            pass
    suffix = "_" + a.ver.replace(".", "_")
    tmpl = open(a.template, encoding="utf-8").read()
    # type/atribut baru yang dideklarasikan template sendiri
    own = set(TYPE_DECL.findall(tmpl))

    def resolve(name):
        if name in own or name in vend:
            return name
        if name + suffix in pub:
            return name + suffix
        if name in pub or name in plat:
            return name
        return None

    each = {}
    for e in a.each:
        k, _, v = e.partition("=")
        each[k] = [x for x in v.split(",") if x]

    out, dropped = [], []
    for line in tmpl.splitlines():
        s = line.strip()
        if not s or s.startswith(";"):
            continue
        variants = [s]
        for k, vals in each.items():
            nv = []
            for v in variants:
                if "{%s}" % k in v:
                    nv += [v.replace("{%s}" % k, "{%s}" % x) for x in vals]
                else:
                    nv.append(v)
            variants = nv
        for v in variants:
            bad = []

            def sub(m):
                r = resolve(m.group(1))
                if r is None:
                    bad.append(m.group(1))
                    return m.group(0)
                return r
            res = PLACEHOLDER.sub(sub, v)
            if bad:
                dropped.append("%s (type tidak ada: %s)" % (v, ", ".join(sorted(set(bad)))))
                continue
            if res not in out:
                out.append(res)
    for line in out:
        print("%s %s" % (line, a.tag))
    for d in dropped:
        print("dibuang: " + d, file=sys.stderr)
    return 0


def esc(path):
    return re.sub(r'([^-_/a-zA-Z0-9])', r'\\\1', path)


def cmd_ctx(argv):
    config, root, part = argv[:3]
    items = argv[3:]
    entries = {}
    order = []
    with open(config, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) < 2:
                continue
            k = p[0].replace("\\", "")
            if k not in entries:
                order.append(k)
            entries[k] = p[1]
    added = []
    for it in items:
        rel, _, label = it.partition("=")
        rel = rel.strip("/")
        key = "/%s/%s" % (part, rel)
        if not label:
            d = os.path.dirname(key)
            sib = Counter(v for k, v in entries.items()
                          if os.path.dirname(k) == d and k != key
                          and not os.path.isdir(os.path.join(root, os.path.relpath(k, "/" + part))))
            if sib:
                label = sib.most_common(1)[0][0]
            else:
                # folder baru: label folder induk terdekat yang tercatat
                while d not in entries and d not in ("/", ""):
                    d = os.path.dirname(d)
                label = entries.get(d, "u:object_r:%s_file:s0" % ("system" if part != "vendor" and part != "odm" else "vendor"))
        entries[key] = label
        added.append("%s %s" % (key, label))
    with open(config, "a", encoding="utf-8") as f:
        for line in added:
            k, lab = line.split(" ", 1)
            f.write("%s %s\n" % (esc(k), lab))
    for line in added:
        print("  ctx " + line)
    return 0


def cmd_effects(argv):
    path = argv[0]
    libs, effects, drop = [], [], False
    i = 1
    while i < len(argv):
        x = argv[i]
        if x == "--effect":
            n, _, rest = argv[i + 1].partition("=")
            lib, _, uuid = rest.partition(":")
            effects.append((n, lib, uuid))
            i += 2
            continue
        if x == "--drop-helpers":
            drop = True
        else:
            n, _, p = x.partition("=")
            libs.append((n, p))
        i += 1
    s = open(path, encoding="utf-8").read()
    if "<libraries>" not in s or "</libraries>" not in s or "</effects>" not in s:
        print("lewati %s: format tidak dikenal" % path, file=sys.stderr)
        return 2
    have_lib = set(re.findall(r'<library\s+name="([^"]+)"', s))
    have_eff = set(re.findall(r'<effect\s+name="([^"]+)"', s))
    add_l = "".join('        <library name="%s" path="%s"/>\n' % (n, p) for n, p in libs if n not in have_lib)
    add_e = "".join('        <effect name="%s" library="%s" uuid="%s"/>\n' % e for e in effects if e[0] not in have_eff)
    if add_l:
        s = s.replace("    </libraries>", "        <!-- Dolby (port addon) -->\n" + add_l + "    </libraries>", 1) \
            if "    </libraries>" in s else s.replace("</libraries>", add_l + "</libraries>", 1)
    if add_e:
        s = s.replace("    </effects>", "        <!-- Dolby (port addon) -->\n" + add_e + "    </effects>", 1) \
            if "    </effects>" in s else s.replace("</effects>", add_e + "</effects>", 1)
    removed = 0
    if drop:
        m = re.search(r'<postprocess>.*?</postprocess>', s, re.S)
        if m:
            block = m.group(0)
            nb, removed = re.subn(r'\s*<stream type="[^"]+">\s*<apply effect="(?!voice_)[a-z]+_helper"\s*/>\s*</stream>', '', block)
            s = s[:m.start()] + nb + s[m.end():]
    # validasi: harus tetap XML yang benar
    from xml.dom import minidom
    minidom.parseString(s.encode("utf-8"))
    open(path, "w", encoding="utf-8").write(s)
    print("%d library, %d effect ditambah, %d stream helper dibuang" % (add_l.count("<library"), add_e.count("<effect"), removed))
    return 0


def cmd_allowlist(argv):
    pkg, out, req = argv[:3]
    xmls = argv[3:]
    pat = re.compile(r'<privapp-permissions\s+package="%s"\s*>(.*?)</privapp-permissions>' % re.escape(pkg), re.S)
    allow, deny = set(), set()
    for f in xmls:
        try:
            s = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        s = re.sub(r'<!--.*?-->', '', s, flags=re.S)
        for body in pat.findall(s):
            for kind, name in re.findall(r'<(permission|deny-permission)\s+name="([^"]+)"', body):
                (allow if kind == "permission" else deny).add(name)
    try:
        for line in open(req, encoding="utf-8"):
            n = line.strip()
            if n and not n.startswith(pkg + ".") and n not in deny:
                allow.add(n)
    except OSError:
        pass
    deny -= allow
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<!-- allowlist addon port: izin bawaan + izin yang diminta APK -->\n<permissions>\n')
        f.write('    <privapp-permissions package="%s">\n' % pkg)
        for n in sorted(allow):
            f.write('        <permission name="%s"/>\n' % n)
        for n in sorted(deny):
            f.write('        <deny-permission name="%s"/>\n' % n)
        f.write('    </privapp-permissions>\n</permissions>\n')
    os.chmod(out, 0o644)
    print(len(allow) + len(deny))
    return 0


def cmd_soname(argv):
    src, dst, old, new = argv[:4]
    ob, nb = old.encode() + b"\0", new.encode() + b"\0"
    if len(nb) > len(ob):
        print("NEW lebih panjang dari OLD", file=sys.stderr)
        return 1
    data = open(src, "rb").read()
    if data.count(ob) != 1:
        print("string %s ditemukan %d kali (harus 1)" % (old, data.count(ob)), file=sys.stderr)
        return 1
    data = data.replace(ob, nb + b"\0" * (len(ob) - len(nb)))
    open(dst, "wb").write(data)
    return 0


def cmd_lfs(argv):
    try:
        with open(argv[0], "rb") as f:
            head = f.read(512)
    except OSError:
        return 0
    if not head.startswith(b"version https://git-lfs"):
        return 0
    t = head.decode("utf-8", "replace")
    oid = re.search(r'oid sha256:([0-9a-f]{64})', t)
    size = re.search(r'size (\d+)', t)
    if oid and size:
        print(oid.group(1), size.group(1))
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmds = {"cil": cmd_cil, "ctx": cmd_ctx, "effects": cmd_effects, "allowlist": cmd_allowlist,
            "soname": cmd_soname, "lfs": cmd_lfs}
    c = cmds.get(sys.argv[1])
    if not c:
        print(__doc__)
        return 1
    return c(sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
