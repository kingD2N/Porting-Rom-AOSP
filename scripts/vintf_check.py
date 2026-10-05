#!/usr/bin/env python3
"""
vintf_check.py - cek arah sebaliknya dari VINTF: apa yang DIMINTA vendor
(device compatibility matrix di vendor/odm) harus disediakan framework
(framework manifest di system/system_ext/product).

  vintf_check.py --device-matrix FILE [...] --framework DIR [...]

Yang dicek: <vendor-ndk> versi, <system-sdk> versi, dan HAL framework wajib
(optional != "true"). Output teks untuk log. Exit code selalu 0.
"""
import argparse
import os
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device-matrix", action="append", default=[])
    ap.add_argument("--framework", action="append", default=[])
    a = ap.parse_args()

    fw_hals, fw_ndk, fw_sdk, nfw = set(), set(), set(), 0
    for f in framework_manifests(a.framework):
        r = load(f)
        if r is None or r.tag != "manifest" or r.get("type") != "framework":
            continue
        nfw += 1
        for h in r.findall("hal"):
            n = h.findtext("name")
            if n:
                fw_hals.add(n.strip())
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
                req_hals[n.strip()] = os.path.basename(f)
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
    for n, src in sorted(req_hals.items()):
        if n in fw_hals:
            print("OK      HAL framework %s" % n)
        else:
            print("MISSING HAL framework %s (diminta %s)" % (n, src))
            problems += 1
    print("RESULT %d" % problems)
    return 0


if __name__ == "__main__":
    sys.exit(main())
