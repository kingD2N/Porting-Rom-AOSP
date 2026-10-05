#!/usr/bin/env bash
# =============================================================================
#  build_rro.sh - build RRO overlay ingres dari rro/<Nama>/ (res/ + AndroidManifest.xml)
#                 menjadi devices/ingres/product/overlay/<Nama>.apk
#
#  Sumber res/ diambil dari device tree ingres & sm8450-common (lihat rro/SOURCE.md).
#  Butuh: java, apktool.jar (toolkit toraidl: bin/apktool/apktool.jar, sudah membawa aapt2
#  + framework Android), zipalign, apksigner, keytool.
#
#    TOOLS_DIR=/path/toolkit bash scripts/build_rro.sh            # semua
#    TOOLS_DIR=/path/toolkit bash scripts/build_rro.sh FrameworksResIngres
#
#  Env:
#    PKG_SUFFIX   akhiran nama package (default .port). RRO yang sama sudah ada di vendor/odm
#                 ROM AOSP ingres dengan package asli; nama beda = tidak bentrok di PackageManager.
#    KEYSTORE     keystore penanda tangan (default rro/rro-test.jks, dibuat kalau belum ada).
#                 RRO statis pre-install tidak butuh kunci platform; kunci cukup konsisten antar build.
# =============================================================================
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RRO_DIR=${RRO_DIR:-$ROOT/rro}
OUT_DIR=${OUT_DIR:-$ROOT/devices/ingres/product/overlay}
PKG_SUFFIX=${PKG_SUFFIX:-.port}
KEYSTORE=${KEYSTORE:-$RRO_DIR/rro-test.jks}
KS_PASS=${KS_PASS:-android}
MIN_SDK=${MIN_SDK:-31}
TARGET_SDK=${TARGET_SDK:-34}
VERSION_CODE=${VERSION_CODE:-$(date +%Y%m%d)}
APKTOOL=${APKTOOL:-${TOOLS_DIR:+$TOOLS_DIR/bin/apktool/apktool.jar}}

die() { echo "[fail] $*" >&2; exit 1; }
[[ -n $APKTOOL && -f $APKTOOL ]] || die "apktool.jar tidak ada. Set TOOLS_DIR=<toolkit> atau APKTOOL=<path apktool.jar>"
for t in java zipalign apksigner keytool python3; do command -v "$t" >/dev/null || die "tool tidak ada: $t"; done

if [[ ! -f $KEYSTORE ]]; then
    keytool -genkeypair -keystore "$KEYSTORE" -storepass "$KS_PASS" -keypass "$KS_PASS" -alias rro \
        -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=ingres-port-rro" >/dev/null 2>&1
    echo "[ ok ] keystore baru: $KEYSTORE"
fi

mkdir -p "$OUT_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [[ $# -gt 0 ]]; then names=("$@"); else
    mapfile -t names < <(find "$RRO_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
fi

n=0
for name in "${names[@]}"; do
    src="$RRO_DIR/$name"
    [[ -f $src/AndroidManifest.xml && -d $src/res ]] || die "$name: butuh $src/AndroidManifest.xml dan $src/res/"
    w="$TMP/$name"; mkdir -p "$w"
    cp -a "$src/res" "$w/res"
    # manifest: package + akhiran, hasCode=false (RRO tanpa dex; Soong menambahkannya lewat manifest_fixer)
    python3 - "$src/AndroidManifest.xml" "$w/AndroidManifest.xml" "$PKG_SUFFIX" "$VERSION_CODE" <<'PY'
import re, sys
src, dst, suffix, vcode = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
m = re.search(r'package="([^"]+)"', s)
if not m:
    raise SystemExit("package tidak ada di manifest")
pkg = m.group(1)
if suffix and not pkg.endswith(suffix):
    s = s.replace('package="%s"' % pkg, 'package="%s%s"' % (pkg, suffix), 1)
if "android:versionCode" not in s:
    s = re.sub(r"<manifest\b", '<manifest android:versionCode="%s" android:versionName="%s"' % (vcode, vcode), s, count=1)
if "<application" not in s:
    s = s.replace("</manifest>", '    <application android:hasCode="false"/>\n</manifest>')
open(dst, "w", encoding="utf-8").write(s.strip() + "\n")
PY
    cat > "$w/apktool.yml" <<EOF
version: 2.9.0
apkFileName: $name.apk
isFrameworkApk: false
usesFramework:
  ids:
  - 1
  tag: null
sdkInfo:
  minSdkVersion: $MIN_SDK
  targetSdkVersion: $TARGET_SDK
packageInfo:
  forcedPackageId: 127
  renameManifestPackage: null
versionInfo:
  versionCode: $VERSION_CODE
  versionName: '$VERSION_CODE'
doNotCompress:
- resources.arsc
EOF
    if ! java -jar "$APKTOOL" b "$w" -o "$TMP/$name.unsigned.apk" >"$TMP/$name.log" 2>&1; then
        cat "$TMP/$name.log" >&2; die "$name: apktool build gagal"
    fi
    zipalign -p -f 4 "$TMP/$name.unsigned.apk" "$TMP/$name.aligned.apk"
    apksigner sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" --ks-key-alias rro \
        --min-sdk-version "$MIN_SDK" --out "$OUT_DIR/$name.apk" "$TMP/$name.aligned.apk"
    rm -f "$OUT_DIR/$name.apk.idsig"
    pkg=$(python3 "$ROOT/scripts/apk_index.py" --apk "$OUT_DIR/$name.apk")
    echo "[ ok ] $name.apk  ($pkg, $(stat -c%s "$OUT_DIR/$name.apk") byte)"
    n=$((n + 1))
done
echo "[ ok ] $n RRO -> ${OUT_DIR#"$ROOT"/}"
