#!/bin/bash
# fetch_rom.sh URL DIR -> unduh ROM ke DIR dengan nama file asli, cetak path-nya di stdout.
# Link "halaman web" (Google Drive, SourceForge, Pixeldrain, MediaFire) diubah ke link unduh
# langsung (scripts/dl_helper.py); halaman konfirmasi Google Drive / MediaFire dilewati; hasil
# berupa halaman HTML = gagal. Nama file diambil dari Content-Disposition (Google Drive memberi
# nama asli, mis. RYUUI_INGRES_V14.0.11.0.TLJCNXM_EU261003.zip), kalau tidak ada dari URL.
set -euo pipefail
url=$1 dir=$2
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dl() { python3 "$here/dl_helper.py" "$@"; }
UA=${DL_UA:-Wget/1.21.4}
mkdir -p "$dir"
jar="$dir/.cookies.txt"
h=$(dl host "$url")
u=$(dl normalize "$url")

name=$(curl -sSIL --max-time 120 -A "$UA" -c "$jar" -b "$jar" "$u" 2>/dev/null \
       | tr -d '\r' | grep -i '^content-disposition:' | tail -n1 \
       | sed -nE "s/.*filename\*=UTF-8''([^;]+).*/\1/ip; t; s/.*filename=\"?([^\";]+)\"?.*/\1/ip" || true)
name=$(python3 -c 'import sys,urllib.parse as u; print(u.unquote(sys.argv[1]))' "${name:-}")
if [[ -z $name ]]; then
    name=$(basename "${url%%\?*}")
    case $name in download|view|uc|""|*=*) name=rom.zip ;; esac
fi
name=${name//\//_}
out="$dir/$name"
echo "unduh $name ($h)" >&2

get() { # url
    rm -f "$out" "$out.aria2"
    if [[ $h != gdrive && $h != mediafire ]] && command -v aria2c >/dev/null \
        && aria2c -x8 -s8 -k1M --file-allocation=none --console-log-level=warn --summary-interval=60 \
                  --allow-overwrite=true -U "$UA" -d "$dir" -o "$name" "$1" >&2; then
        return 0
    fi
    curl -fL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 -A "$UA" \
         -c "$jar" -b "$jar" -o "$out" "$1" >&2
}

for try in 1 2 3; do
    get "$u"
    kind=$(dl sniff "$out")
    [[ $kind == html ]] || break
    next=""
    case $h in
        gdrive) next=$(dl gdrive-form "$out" || true) ;;
        mediafire) next=$(dl mediafire "$out" || true) ;;
    esac
    if [[ -z $next || $try -eq 3 ]]; then
        echo "::error::$name: server mengirim halaman HTML, bukan ROM ($(dl html-reason "$out")). URL: $url" >&2
        exit 1
    fi
    echo "  halaman konfirmasi $h, lanjut" >&2
    u=$next
done
rm -f "$jar"
echo "  $name: $(( $(stat -c%s "$out") / 1048576 )) MB, format $kind" >&2
echo "$out"
