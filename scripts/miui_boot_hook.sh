#!/bin/bash
# miui_boot_hook.sh TOOLKIT_DIR CUSTOM_BOOT_IMG
# Dipanggil port.sh hyperos_port (lewat miui_toolkit_patch.py) tepat sebelum paket dibangun.
# Kernel dari boot.img custom dimasukkan ke boot.img ROM base (ramdisk base tetap) HANYA kalau
# CRC simbol kernel cocok dengan modul vendor ROM base (vendor_boot + vendor_dlkm), dicek
# scripts/kernel_crc.py. Tidak cocok = boot.img base tidak diubah (kernel bawaan base dipakai),
# karena modul vendor yang gagal dimuat (UFS, layar, touch, Wi-Fi) = bootloop / HP tanpa fungsi.
# Exit selalu 0: hook tidak boleh menggagalkan port.
set -uo pipefail
tk=$1 custom=$(realpath "$2" 2>/dev/null || echo "$2")
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin="$tk/bin/Linux/x86_64"
export PATH="$bin:$PATH"
log() { echo "[kernel] $*"; }
warn() { echo "[kernel] PERINGATAN: $*"; [[ -n ${GITHUB_ACTIONS:-} ]] && echo "::warning::$*"; return 0; }
note() { [[ -n ${KERNEL_REPORT:-} ]] && echo "$*" > "$KERNEL_REPORT"; return 0; }

cd "$tk" || exit 0
[[ -f $custom ]] || { warn "boot.img custom tidak ada ($custom), kernel base dipakai"; note "base (boot custom tidak ada)"; exit 0; }
base=$(find build/baserom -name boot.img | head -n1)
[[ -n $base ]] || { warn "boot.img base tidak ditemukan di build/baserom, kernel custom dilewati"; note "base"; exit 0; }
vb=$(find build/baserom -name vendor_boot.img | head -n1)
w=$(mktemp -d)
mods="$w/mods"; mkdir -p "$mods"
if [[ -n $vb ]]; then python3 "$here/kernel_crc.py" vbmods "$vb" "$mods/vendor_boot" || true; fi
if [[ -d build/portrom/images/vendor_dlkm/lib/modules ]]; then
    cp -a build/portrom/images/vendor_dlkm/lib/modules "$mods/vendor_dlkm"
elif [[ -f build/portrom/images/vendor_dlkm.img ]]; then
    img=build/portrom/images/vendor_dlkm.img
    # image hasil repack toolkit bisa sparse (e2fsdroid -s) -> raw dulu
    if [[ $(head -c4 "$img" | od -An -tx1 | tr -d ' \n') == 3aff26ed ]]; then
        simg2img "$img" "$w/vendor_dlkm.raw" 2>/dev/null && img="$w/vendor_dlkm.raw"
    fi
    if [[ $(gettype -i "$img" 2>/dev/null) == erofs ]]; then
        extract.erofs -i "$img" -X lib/modules -o "$mods/vendor_dlkm" >/dev/null 2>&1 || true
    else
        mkdir -p "$mods/vendor_dlkm"; debugfs -R "rdump /lib/modules $mods/vendor_dlkm" "$img" >/dev/null 2>&1 || true
    fi
fi
n=$(find "$mods" -name '*.ko' | wc -l)
if [[ $n -eq 0 ]]; then
    warn "modul vendor base tidak terbaca, kecocokan kernel tidak bisa dicek -> kernel base dipakai"
    note "base (modul vendor tidak terbaca)"; rm -rf "$w"; exit 0
fi
log "kernel custom: $(strings -a "$custom" | grep -m1 -oE 'Linux version [0-9.]+[^ ]*' || echo '?')"
log "kernel base  : $(strings -a "$base" | grep -m1 -oE 'Linux version [0-9.]+[^ ]*' || echo '?')"
rc=0
python3 "$here/kernel_crc.py" check "$custom" --base "$base" "$mods" > "$w/crc.log" 2>&1 || rc=$?
sed -n '1,25p' "$w/crc.log"
if [[ $rc -ne 0 ]]; then
    if [[ $rc -eq 3 ]]; then
        warn "kernel custom TIDAK cocok dengan modul vendor ROM base ($(sed -n 's/^MODUL_GAGAL \([0-9/]*\).*/\1/p' "$w/crc.log") modul gagal dimuat) -> boot.img base tidak diubah"
        note "base (kernel custom tidak cocok: $(sed -n 's/^MODUL_GAGAL \([0-9/]*\).*/\1/p' "$w/crc.log") modul gagal)"
    else
        warn "cek CRC kernel tidak bisa dijalankan ($(tail -n1 "$w/crc.log")) -> boot.img base tidak diubah"
        note "base (cek kernel gagal)"
    fi
    rm -rf "$w"; exit 0
fi
# cocok: ganti kernel saja, ramdisk & header boot base tetap
mkdir -p "$w/b" "$w/c"
(cd "$w/c" && magiskboot unpack "$custom" >/dev/null 2>&1) || true
(cd "$w/b" && magiskboot unpack "$tk/$base" >/dev/null 2>&1) || true
if [[ -s $w/c/kernel && -s $w/b/kernel ]] && cp -f "$w/c/kernel" "$w/b/kernel" \
        && (cd "$w/b" && magiskboot repack "$tk/$base" "$w/new.img" >/dev/null 2>&1) && [[ -s $w/new.img ]]; then
    cp -f "$w/new.img" "$base"
    log "kernel custom dipasang ke $base (ramdisk base dipertahankan)"
    note "kernel custom + ramdisk base"
else
    warn "gagal mengganti kernel di boot.img base -> boot.img base tidak diubah"
    note "base (ganti kernel gagal)"
fi
rm -rf "$w"
exit 0
