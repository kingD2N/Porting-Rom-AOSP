#!/usr/bin/env python3
"""
vintf_check.py - cek arah sebaliknya dari VINTF: apa yang DIMINTA vendor
(device compatibility matrix di vendor/odm) harus disediakan framework
(framework manifest di system/system_ext/product).

  vintf_check.py --device-matrix FILE [...] --framework DIR [...]
                 [--device-manifest FILE ...]

Yang dicek: <vendor-ndk> versi, <system-sdk> versi, dan HAL framework wajib
(optional != "true"). Dengan --device-manifest juga arah satunya yang ikut dicek
VintfObject.verifyBuildAtBoot (penyebab dialog "There's an internal problem"):
versi <sepolicy> vendor harus ada di <sepolicy-version> framework compatibility matrix
donor (matrix ber-level = target-level vendor + matrix tanpa level). HAL di matrix
framework TIDAK dicek saat boot (HalManifest::checkCompatibility hanya vendor-ndk,
system-sdk, sepolicy; RuntimeInfo: kernel-sepolicy-version; cek kernel dimatikan oleh
verifyBuildAtBoot). Jadi cek ini = isi verifyBuildAtBoot Android 16.
Output teks untuk log. Exit code selalu 0.
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET


def load(path):
    try:
        return ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return None


def framework_manifests(dirs):
    files = []
    for d in dirs:
        for sub in ("etc/vintf", "etc/vintf/manifest"):
            p = os.path.join(d, sub)
            if not os.path.isdir(p):
                continue
            for fn in sorted(os.listdir(p)):
                f = os.path.join(p, fn)
                if fn.endswith(".xml") and os.path.isfile(f) and "compatibility_matrix" not in fn:
                    files.append(f)
    return files


def _ver(text, fmt):
    """'1.0' -> (1, 0); AIDL '2' -> (0, 2). Range 'a.b-c' / 'a-b' -> (min, max)."""
    t = (text or "").strip()
    lo, _, hi = t.partition("-")
    if fmt == "aidl":
        lo_v = int(lo or 1)
        return (0, lo_v), (0, int(hi) if hi else lo_v)
    maj, _, mi = lo.partition(".")
    maj, mi = int(maj or 0), int(mi or 0)
    return (maj, mi), (maj, int(hi) if hi else mi)


def provided(h):
    """[(format, (major, minor), interface, instance)] dari <hal> framework manifest"""
    fmt = h.get("format", "hidl")
    out = []
    vers = [v.text for v in h.findall("version")] or (["1"] if fmt == "aidl" else [])
    for fq in h.findall("fqname"):
        t = (fq.text or "").strip()
        v = None
        if t.startswith("@"):
            v, _, t = t[1:].partition("::")
        iface, _, inst = t.partition("/")
        for vv in ([v] if v else vers):
            out.append((fmt, _ver(vv, fmt)[0], iface, inst))
    for itf in h.findall("interface"):
        iface = (itf.findtext("name") or "").strip()
        for inst in itf.findall("instance"):
            for vv in vers:
                out.append((fmt, _ver(vv, fmt)[0], iface, (inst.text or "").strip()))
    if not out:
        for vv in vers:
            out.append((fmt, _ver(vv, fmt)[0], "", ""))
    return out


def hal_compatible(req, prov):
    """None kalau cocok, kalau tidak: alasan singkat. Aturan libvintf (disederhanakan):
    HIDL: major sama dan minor >= minimum; AIDL: versi >= minimum; semua instance wajib ada."""
    fmt = req.get("format", "hidl")
    rv = [v.text for v in req.findall("version")] or (["1"] if fmt == "aidl" else [])
    pv = [p for p in prov if p[0] == fmt]
    if not pv:
        return "format %s tidak disediakan" % fmt
    if rv:
        ok_ver = []
        for r in rv:
            (mn, _mx) = _ver(r, fmt)
            ok_ver += [p for p in pv if p[1][0] == mn[0] and p[1][1] >= mn[1]]
        if not ok_ver:
            have = sorted({"%d.%d" % p[1] if fmt != "aidl" else str(p[1][1]) for p in pv})
            return "versi diminta %s, framework punya %s" % (" ".join(r.strip() for r in rv), " ".join(have))
        pv = ok_ver
    for itf in req.findall("interface"):
        iface = (itf.findtext("name") or "").strip()
        insts = [(i.text or "").strip() for i in itf.findall("instance")]
        rx = [(i.text or "").strip() for i in itf.findall("regex-instance")]
        have = {p[3] for p in pv if p[2] == iface or not p[2]}
        for i in insts:
            if i not in have:
                return "instance %s/%s tidak ada" % (iface, i)
        for pat in rx:
            if not any(re.fullmatch(pat, x) for x in have):
                return "regex-instance %s/%s tidak cocok" % (iface, pat)
    return None


def ver_match(dev, entry):
    """versi sepolicy device (mis. 202504 / 34.0) cocok dengan entri matrix (202504 / 34.0 / 30.0-2)"""
    dev, entry = dev.strip(), entry.strip()
    if dev == entry:
        return True
    try:
        dmaj, _, dmin = dev.partition(".")
        emaj, _, erest = entry.partition(".")
        if dmaj != emaj:
            return False
        lo, _, hi = erest.partition("-")
        d = int(dmin or 0)
        return int(lo or 0) <= d <= int(hi or lo or 0)
    except ValueError:
        return False


KERNEL_POLICYVERS = 33   # POLICYDB_VERSION_MAX kernel 5.10 (ingres)


def framework_matrices(dirs):
    files = []
    for d in dirs:
        p = os.path.join(d, "etc/vintf")
        if os.path.isdir(p):
            files += [os.path.join(p, fn) for fn in sorted(os.listdir(p))
                      if fn.startswith("compatibility_matrix") and fn.endswith(".xml")]
    return files


def sepolicy_check(manifests, fw_dirs):
    dev_ver, level = None, None
    for f in manifests:
        r = load(f)
        if r is None or r.tag != "manifest" or r.get("type") != "device":
            continue
        level = level or r.get("target-level")
        v = r.findtext("sepolicy/version")
        if v and not dev_ver:
            dev_ver = v.strip()
    if not manifests:
        return 0
    if not dev_ver:
        print("INFO    sepolicy: versi vendor tidak ada di device manifest, cek dilewati")
        return 0
    vers, used, ksv = [], [], []
    for f in framework_matrices(fw_dirs):
        r = load(f)
        if r is None or r.tag != "compatibility-matrix" or r.get("type") != "framework":
            continue
        lv = r.get("level")
        if lv and level and lv != level:
            continue
        ksv += [int(e.text) for e in r.findall("sepolicy/kernel-sepolicy-version") if (e.text or "").strip().isdigit()]
        found = [(e.text or "").strip() for e in r.findall("sepolicy/sepolicy-version")]
        if found:
            vers += found
            used.append(os.path.basename(f))
    if not vers:
        print("INFO    sepolicy: framework matrix level %s tanpa <sepolicy-version>, cek dilewati" % level)
        return 0
    # RuntimeInfo: policyvers kernel >= kernel-sepolicy-version matrix (kernel 5.10 = 33)
    if ksv and max(ksv) > KERNEL_POLICYVERS:
        print("MISSING kernel-sepolicy-version %d diminta framework, kernel 5.10 hanya %d -> dialog 'internal problem'"
              % (max(ksv), KERNEL_POLICYVERS))
        return 1
    if any(ver_match(dev_ver, e) for e in vers):
        print("OK      sepolicy-version vendor %s didukung framework (%s)" % (dev_ver, ", ".join(used)))
        return 0
    print("MISSING sepolicy-version vendor %s TIDAK ada di framework matrix donor (%s: %s) -> dialog 'internal problem'"
          % (dev_ver, ", ".join(used), " ".join(sorted(set(vers)))))
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device-matrix", action="append", default=[])
    ap.add_argument("--framework", action="append", default=[])
    ap.add_argument("--device-manifest", action="append", default=[])
    a = ap.parse_args()

    fw_hals, fw_ndk, fw_sdk, nfw = {}, set(), set(), 0
    for f in framework_manifests(a.framework):
        r = load(f)
        if r is None or r.tag != "manifest" or r.get("type") != "framework":
            continue
        nfw += 1
        for h in r.findall("hal"):
            n = h.findtext("name")
            if n:
                fw_hals.setdefault(n.strip(), []).extend(provided(h))
        for v in r.findall("vendor-ndk/version"):
            fw_ndk.add((v.text or "").strip())
        for v in r.findall("system-sdk/version"):
            fw_sdk.add((v.text or "").strip())

    req_hals, req_ndk, req_sdk, ndm = {}, set(), set(), 0
    for f in a.device_matrix:
        r = load(f)
        if r is None or r.tag != "compatibility-matrix" or r.get("type") != "device":
            continue
        ndm += 1
        for h in r.findall("hal"):
            if h.get("optional", "false") == "true":
                continue
            n = h.findtext("name")
            if n:
                req_hals[n.strip()] = (os.path.basename(f), h)
        for v in r.findall("vendor-ndk/version"):
            req_ndk.add((v.text or "").strip())
        for v in r.findall("system-sdk/version"):
            req_sdk.add((v.text or "").strip())

    print("device matrix vendor/odm: %d file | framework manifest: %d file" % (ndm, nfw))
    problems = 0
    for v in sorted(req_ndk):
        if v in fw_ndk:
            print("OK      vendor-ndk %s disediakan framework" % v)
        else:
            print("MISSING vendor-ndk %s (framework menyediakan: %s)" % (v, " ".join(sorted(fw_ndk)) or "-"))
            problems += 1
    miss_sdk = sorted(v for v in req_sdk if v not in fw_sdk)
    if req_sdk:
        if miss_sdk:
            print("MISSING system-sdk %s (framework: %s)" % (" ".join(miss_sdk), " ".join(sorted(fw_sdk)) or "-"))
            problems += 1
        else:
            print("OK      system-sdk %s" % " ".join(sorted(req_sdk)))
    for n, (src, h) in sorted(req_hals.items()):
        if n not in fw_hals:
            print("MISSING HAL framework %s (diminta %s)" % (n, src))
            problems += 1
            continue
        why = hal_compatible(h, fw_hals[n])
        if why:
            # nama sama tapi versi/instance tidak cocok: sama fatalnya dengan tidak ada
            print("MISSING HAL framework %s (diminta %s): %s" % (n, src, why))
            problems += 1
        else:
            print("OK      HAL framework %s" % n)
    problems += sepolicy_check(a.device_manifest, a.framework)
    print("RESULT %d" % problems)
    return 0


if __name__ == "__main__":
    sys.exit(main())
