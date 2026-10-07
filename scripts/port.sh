#!/usr/bin/env bash
# =============================================================================
#  port.sh - Port ROM AOSP (LineageOS / AxionOS / crDroid / dll) dari device
#            donor ke ingres (POCO F4 GT / Redmi K50 Gaming, SM8450)
#
#  Konsep: firmware + boot/vendor_boot/dtbo + vendor/odm/vendor_dlkm dari BASE
#  (ROM ingres: ROM AOSP untuk ingres, mis. AxionOS, ATAU stock MIUI/HyperOS ingres),
#  system/system_ext/product dari PORT (ROM AOSP donor, OTA payload.bin).
#  Output: zip flashable recovery (META-INF/ + images/), untuk OrangeFox/TWRP.
#
#  Diadaptasi dari TEST-BUILD-Porting-HyperOS-Marble (port.sh HyperOS -> marble).
#  Semua setting lewat env (key=value), default di bawah.
# =============================================================================
set -Eeuo pipefail

# ------------------------------------------------------------------ config
BASE_ROM=${BASE_ROM:?BASE_ROM wajib (URL / path ROM ingres: OTA AOSP ingres, fastboot MIUI/HyperOS, atau zip xiaomi.eu)}
PORT_ROM=${PORT_ROM:?PORT_ROM wajib (URL / path ROM AOSP donor, OTA zip berisi payload.bin)}
TOOLS_DIR=${TOOLS_DIR:?TOOLS_DIR wajib (root toolkit berisi bin/)}

TARGET_DEVICE=${TARGET_DEVICE:-ingres}
PORT_PARTITIONS=${PORT_PARTITIONS:-"system system_ext product"}
EXT4_PARTITIONS=${EXT4_PARTITIONS:-"vendor odm system vendor_dlkm product system_ext"}
DISABLE_ENCRYPTION=${DISABLE_ENCRYPTION:-true}
RW_MOUNT=${RW_MOUNT:-true}
DISABLE_AVB=${DISABLE_AVB:-true}
DEBUG_ADB=${DEBUG_ADB:-true}
SUPER_SIZE=${SUPER_SIZE:-auto}
BASE_TYPE=${BASE_TYPE:-auto}                # auto | aosp (ROM AOSP ingres) | hyperos (stock MIUI/HyperOS ingres)
# yang diambil dari base ke partisi port:
#   overlay       = RRO khas device (AOSP base: *ingres* / pola DEVICE_OVERLAY_GLOBS; HyperOS base: AospFrameworkResOverlay)
#   displayconfig = product/etc/displayconfig (kurva brightness / nits per panel)
#   fcm           = system/etc/vintf/compatibility_matrix.device.xml base (HAL khas device dikenali framework)
REPLACE_FROM_BASE=${REPLACE_FROM_BASE:-"overlay displayconfig fcm"}
# path tambahan (relatif root partisi) yang disalin apa adanya dari base, pisah spasi,
# mis. "product/overlay/FooIngres.apk system_ext/priv-app/XiaomiDolby". APK sharedUserId=system
# TIDAK bisa dipindah ke ROM lain (beda kunci platform) -> dilewati dengan warning.
COPY_FROM_BASE=${COPY_FROM_BASE:-""}
# fitur khas ingres di ROM base LineageOS yang ikut hilang karena system_ext/product diganti donor.
# Disalin otomatis kalau ADA di base dan package-nya BELUM ada di donor (path yang tidak ada dilewati diam-diam):
#   GameKeys = tombol bahu (shoulder trigger) POCO F4 GT -> HAL vendor.lineage.gamekeys + touchinjector
#   Leds     = LED RGB belakang (aw22xxx) -> HAL vendor.lineage.leds
#   Aperture = aplikasi kamera LineageOS (Camera2 standar, cocok dengan vendor kamera base)
BASE_EXTRAS=${BASE_EXTRAS:-true}
BASE_EXTRA_PATHS=${BASE_EXTRA_PATHS:-"system_ext/priv-app/GameKeys system_ext/priv-app/Leds product/app/Aperture product/etc/sysconfig/preinstalled-packages-org.lineageos.aperture.xml product/etc/sysconfig/initial-package-stopped-states-org.lineageos.aperture.xml"}
# nama overlay (glob, tanpa .apk) yang dianggap RRO khas device: milik donor dibuang, milik base (AOSP) disalin.
# overlay yang nama/package-nya memuat codename donor selalu dibuang.
DEVICE_OVERLAY_GLOBS=${DEVICE_OVERLAY_GLOBS:-"*ResCommon* *ResTarget*"}
FIRST_API_LEVEL=${FIRST_API_LEVEL:-auto}   # auto = dari base; ingres rilis Android 12 -> 31
FIRST_API_LEVEL_FALLBACK=31
LCD_DENSITY=${LCD_DENSITY:-auto}           # auto = dari base (product/vendor); angka = paksa
DEBLOAT=${DEBLOAT:-""}
EROFS_COMP=${EROFS_COMP:-"lz4hc,9"}
EXT4_HEADROOM_MB=${EXT4_HEADROOM_MB:-128}
DEBLOAT_KEEP=""
VNDK_COMPAT=${VNDK_COMPAT:-true}           # vendor butuh VNDK APEX versi lama -> salin dari system/system_ext base
LINKER_CHECK=${LINKER_CHECK:-true}         # laporan dependensi linker ELF vendor/odm (info)
VINTF_COMPAT=${VINTF_COMPAT:-true}         # level FCM vendor tidak dikenal framework donor -> salin matrix dari system base
VINTF_TOOL_CHECK=${VINTF_TOOL_CHECK:-true} # checkvintf --check-compat (toolkit) framework donor vs vendor base (info)
SEPOLICY_CHECK=${SEPOLICY_CHECK:-true}     # compile sepolicy gabungan (secilc, seperti init saat boot) - deteksi bootloop sepolicy
SEPOLICY_STRICT=${SEPOLICY_STRICT:-false}  # true = build GAGAL kalau sepolicy gabungan tidak bisa di-compile
PROP_MERGE=${PROP_MERGE:-true}             # salin props hardware (allowlist) dari product/etc/build.prop base
# props base yang boleh disalin ke product donor (regex, dipisah spasi). Props ROM base (ro.lineage.*, ro.miui.*) tidak ikut.
PROP_MERGE_ALLOW=${PROP_MERGE_ALLOW:-'ro\.sf\.lcd_density ro\.surface_flinger\..* debug\.sf\..* persist\.sys\.sf\..* ro\.vendor\..* persist\.vendor\..* vendor\..* ro\.hardware\..* ro\.opengles\.version ro\.hwui\..* ro\.config\..*_vol_steps ro\.charger\..* bluetooth\..* persist\.bluetooth\..* ro\.bluetooth\..* ro\.telephony\.default_network persist\.radio\..* ro\.audio\..* audio\..* persist\.audio\..* dalvik\.vm\.heap.* ro\.media\..* media\..*'}
OVERLAY_FIX=${OVERLAY_FIX:-true}           # buang overlay khas donor, salin overlay khas ingres
# ota      = zip OTA A/B gaya AOSP/LineageOS: payload.bin + payload_properties.txt + META-INF/com/android
#            (dipasang update_engine recovery ke slot tidak aktif, layout super diurus update_engine)
# recovery = zip installer shell: images/super.img(.zst) ditulis dd ke partisi super (cara lama)
PACKAGE_TYPE=${PACKAGE_TYPE:-ota}
INSTALLER=${INSTALLER:-auto}                # auto | base (META-INF dari ROM base, mis. xiaomi.eu) | ours (PACKAGE_TYPE=recovery)
RECOVERY_SUPER=${RECOVERY_SUPER:-zst}      # hanya INSTALLER=ours: raw = images/super.img | zst = images/super.img.zst
RECOVERY_IMG=${RECOVERY_IMG:-}              # opsional: URL/path recovery.img custom (OrangeFox dll)
BOOT_IMG=${BOOT_IMG:-}                      # opsional: URL/path boot.img custom (kernel), menggantikan boot.img base
ROM_MAINTAINER=${ROM_MAINTAINER-KingD2N}     # identitas build ROM port: maintainer (kosong = tidak diubah)
ROM_RELEASE_TYPE=${ROM_RELEASE_TYPE:-UNOFFICIAL} # OFFICIAL di prop versi/jenis rilis ROM donor diganti ini
GBOARD_APK=${GBOARD_APK:-}                  # opsional: URL/path Gboard (LatinImeGoogle.apk) -> jadi keyboard sistem
GBOARD_DIR=${GBOARD_DIR:-product/app/LatinImeGoogle}
GBOARD_PACKAGE=${GBOARD_PACKAGE:-com.google.android.inputmethod.latin}   # package yang diharapkan dari GBOARD_APK
ZIP_LEVEL=${ZIP_LEVEL:-1}
KEEP_DOWNLOADS=${KEEP_DOWNLOADS:-false}
DEBLOAT_PACKAGES_FILE=${DEBLOAT_PACKAGES_FILE:-}   # default: <repo>/debloat_packages.txt
DEBLOAT_PRESET=${DEBLOAT_PRESET:-none}     # none | safe (= + hapus semua data-app)
DEBLOAT_SAFE_KEEP=${DEBLOAT_SAFE_KEEP:-""}  # folder data-app yang tidak ikut dihapus preset safe
FIT_FALLBACK_EROFS=${FIT_FALLBACK_EROFS:-true}  # super tidak muat -> vendor/odm otomatis EROFS
EXTRACT_EROFS=${EXTRACT_EROFS:-}           # opsional: extract.erofs versi baru (dicoba duluan)
# partisi yang TIDAK PERNAH di-flash walau ada di ROM base (kalibrasi/IMEI/data user)
NEVER_FLASH=${NEVER_FLASH:-"persist persistbak modemst1 modemst2 fsg fsc frp misc devinfo keystore secdata userdata metadata cache"}
ALLOW_OTHER_BASE=${ALLOW_OTHER_BASE:-false} # true = izinkan ro.product.vendor.device base != TARGET_DEVICE (bahaya)
WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}

FIXED_TS=1230768000
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEVICE_FILES_DIR=${DEVICE_FILES_DIR:-$SCRIPT_DIR/../devices/$TARGET_DEVICE}
DEBLOAT_PACKAGES_FILE=${DEBLOAT_PACKAGES_FILE:-$SCRIPT_DIR/../debloat_packages.txt}
BIN="$TOOLS_DIR/bin/Linux/x86_64"
PYBIN="$TOOLS_DIR/bin"
export PATH="$BIN:$PATH"
export LD_LIBRARY_PATH="$BIN/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ------------------------------------------------------------------ util
c_blue=$'\e[1;34m'; c_yel=$'\e[1;33m'; c_red=$'\e[1;31m'; c_grn=$'\e[1;32m'; c_off=$'\e[0m'
log()  { printf '%s[port]%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_off" "$*" >&2
         [[ -n ${GITHUB_ACTIONS:-} ]] && printf '::warning::%s\n' "$*"; return 0; }
die()  { printf '%s[fail]%s %s\n' "$c_red" "$c_off" "$*" >&2
         [[ -n ${GITHUB_ACTIONS:-} ]] && printf '::error::%s\n' "$*"; exit 1; }
trap 'die "gagal di baris $LINENO: $BASH_COMMAND"' ERR

is_true()   { [[ ${1,,} == true || $1 == 1 || ${1,,} == yes ]]; }
# in_list KATA "daftar dipisah spasi" (daftar sengaja di-word-split)
# shellcheck disable=SC2048,SC2086
in_list()   { local x=$1 i; shift; for i in $*; do if [[ $i == "$x" ]]; then return 0; fi; done; return 1; }
group_start(){ [[ -n ${GITHUB_ACTIONS:-} ]] && echo "::group::$*"; log "== $* =="; }
group_end()  { [[ -n ${GITHUB_ACTIONS:-} ]] && echo "::endgroup::"; return 0; }
dfree()      { df -h "$WORK" | awk 'NR==2{print "disk bebas: "$4}'; }

get_prop() { # file key -> value (baris terakhir menang)
    [[ -f $1 ]] || return 0
    grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

set_prop() { # file key value (replace atau append)
    local f=$1 k=$2 v=$3 ek ev
    [[ -f $f ]] || return 0
    ek=$(printf '%s' "$k" | sed 's/[.[\*^$/]/\\&/g')
    ev=$(printf '%s' "$v" | sed 's/[&/\]/\\&/g')
    if grep -qE "^${ek}=" "$f"; then
        sed -i "s/^${ek}=.*/${k}=${ev}/" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

need() { local t; for t in "$@"; do command -v "$t" >/dev/null || die "tool tidak ada: $t"; done; }

# fungsi khusus AOSP: overlay, updater, displayconfig, FCM, sepolicy/VINTF check, identitas ROM
# shellcheck source-path=SCRIPTDIR source=aosp_extras.sh
source "$SCRIPT_DIR/aosp_extras.sh"
# addon opsional: MiuiCamera ingres, Dolby Atmos (ADDONS)
# shellcheck source-path=SCRIPTDIR source=addons.sh
source "$SCRIPT_DIR/addons.sh"

# ------------------------------------------------------------------ fetch
# link "halaman web" (Google Drive /view, SourceForge, Pixeldrain /u/, MediaFire) diubah ke link
# unduh langsung lewat dl_helper.py. Hasil download yang ternyata HTML ditolak dengan alasan jelas.
dl_tool() { python3 "$SCRIPT_DIR/dl_helper.py" "$@"; }

dl_curl() { # url out
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
         -A "${DL_UA:-Wget/1.21.4}" -c "$WORK/cookies.txt" -b "$WORK/cookies.txt" -o "$2" "$1" >&2
}

dl_raw() { # url out
    # aria2c multi-koneksi untuk host biasa; kalau gagal (mirror menolak multi-koneksi / UA aria2,
    # mis. SourceForge "ERR 0B/s") otomatis diulang pakai curl satu koneksi.
    # Google Drive & MediaFire selalu curl (butuh cookie + halaman konfirmasi).
    local url=$1 out=$2 h final
    h=$(dl_tool host "$url")
    rm -f "$out" "$out.aria2"
    if [[ $h == sourceforge ]]; then
        # /download -> redirect ke mirror bertoken; ambil URL final supaya aria2c langsung ke mirror
        final=$(curl -sSIL -o /dev/null -w '%{url_effective}' --max-time 120 -A "${DL_UA:-Wget/1.21.4}" "$url" 2>/dev/null || true)
        if [[ $final =~ ^https?:// && $final != *sourceforge.net/projects/* ]]; then
            log "  sourceforge mirror: ${final%%\?*}" >&2
            url=$final
        fi
    fi
    if command -v aria2c >/dev/null && [[ $h != gdrive && $h != mediafire ]]; then
        if aria2c -x8 -s8 -k1M --file-allocation=none --console-log-level=warn --allow-overwrite=true \
               --max-tries=5 --retry-wait=5 -U "${DL_UA:-Wget/1.21.4}" \
               --summary-interval=60 -d "$(dirname "$out")" -o "$(basename "$out")" "$url" >&2; then
            return 0
        fi
        warn "aria2c gagal untuk $(basename "$out"), diulang pakai curl (satu koneksi, lebih lambat)"
        rm -f "$out" "$out.aria2"
        url=${final:-$1}
    fi
    dl_curl "$url" "$out"
}

fetch() { # src dest_dir name -> echo path
    local src=$1 dir=$2 name=$3 url h out kind next try
    if [[ ! $src =~ ^https?:// ]]; then
        [[ -f $src ]] || die "file tidak ditemukan: $src"
        readlink -f "$src"; return 0
    fi
    mkdir -p "$dir"; out="$dir/$name"
    url=$(dl_tool normalize "$src"); h=$(dl_tool host "$src")
    log "download $name: $src" >&2
    if [[ $url != "$src" ]]; then log "  link $h -> unduh langsung: $url" >&2; fi
    for try in 1 2 3; do
        dl_raw "$url" "$out" || die "download $name gagal: $url"
        kind=$(dl_tool sniff "$out")
        [[ $kind == html ]] || break
        next=""
        case $h in
            gdrive)    next=$(dl_tool gdrive-form "$out" || true) ;;   # halaman konfirmasi file besar
            mediafire) next=$(dl_tool mediafire "$out" || true) ;;
        esac
        if [[ -z $next || $try -eq 3 ]]; then
            die "download $name menghasilkan halaman HTML, bukan file: $(dl_tool html-reason "$out"). URL: $src"
        fi
        log "  $h: halaman konfirmasi, lanjut ke $next" >&2
        url=$next
    done
    log "  $name: $(( $(stat -c%s "$out") / 1048576 )) MB, format $kind" >&2
    echo "$out"
}

check_url() { # label url  (cek cepat: bisa diakses + bukan halaman HTML, sebelum download besar)
    local label=$1 src=$2 url h code tmp kind name
    [[ $src =~ ^https?:// ]] || return 0
    url=$(dl_tool normalize "$src"); h=$(dl_tool host "$src")
    name=${src%%\?*}; name=${name##*/}
    # link bertanda tangan sementara (mis. tombol download AfterLife = DigitalOcean Spaces, berlaku
    # 1 jam): cek masa berlakunya dulu supaya pesan error jelas dan tidak gagal di tengah download
    local sg left until valid
    sg=$(dl_tool signed "$src" || true)
    if [[ -n $sg ]]; then
        read -r left until valid <<< "$sg"; until=${until//_/ }
        if (( left <= 0 )); then
            die "$label: link unduh bertanda tangan sementara sudah KEDALUWARSA sejak $until (berlaku $(( valid / 60 )) menit sejak dibuat). Ambil link baru dari halaman download lalu jalankan workflow segera, atau unggah ROM ke tempat permanen (GitHub Release / Google Drive / SourceForge): ${src%%\?*}"
        fi
        log "$label: link bertanda tangan sementara, masih berlaku $(( left / 60 )) menit (sampai $until)"
        if (( left < 900 )); then warn "$label: sisa masa berlaku link < 15 menit, download bisa gagal kalau antre lama"; fi
    fi
    tmp="$WORK/check_$label.bin"
    # cuma 512 byte pertama: head menutup pipe, jadi server yang mengabaikan Range tidak
    # membuat file ROM penuh ikut terunduh di sini. Kode HTTP dibaca dari header (redirect terakhir).
    curl -sL -r 0-511 --retry 2 --connect-timeout 30 --max-time 120 -A "${DL_UA:-Wget/1.21.4}" \
         -D "$tmp.hdr" "$url" 2>/dev/null | head -c 512 > "$tmp" || true
    code=$(grep -E '^HTTP/' "$tmp.hdr" 2>/dev/null | tail -n1 | awk '{print $2}' || true)
    code=${code:-000}; rm -f "$tmp.hdr"
    case $code in
        200|206) ;;
        404) die "$label: file tidak ditemukan (HTTP 404): $src" ;;
        403) die "$label: akses ditolak (HTTP 403). Link private / kedaluwarsa? $src" ;;
        *)   die "$label: URL tidak bisa diakses (HTTP $code): $src" ;;
    esac
    kind=$(dl_tool sniff "$tmp")
    if [[ $kind == html ]]; then
        if [[ $h == gdrive || $h == mediafire ]]; then
            ok "$label: URL bisa diakses ($h, halaman konfirmasi akan dilewati saat download)"
        else
            die "$label: URL membalas halaman HTML, bukan file ($(dl_tool html-reason "$tmp")). Pakai link unduh langsung: $src"
        fi
    else
        ok "$label: URL bisa diakses (${name:-file}, format $kind)"
    fi
    rm -f "$tmp"
}

# ------------------------------------------------------------------ unpack ROM
# unpack_rom <rom_file> <out_images_dir> <prefix> [partisi,dipisah,koma|all]
unpack_rom() {
    local rom=$1 dst=$2 pfx=$3 want=${4:-all}
    local tmp="$WORK/tmp_$pfx" magic
    rm -rf "$tmp"; mkdir -p "$dst" "$tmp"
    magic=$(head -c 4 "$rom" | od -An -tx1 | tr -d ' \n')

    case $magic in
        504b0304) # zip
            if unzip -l "$rom" payload.bin >/dev/null 2>&1; then
                log "[$pfx] OTA zip -> payload.bin"
                unzip -p "$rom" payload.bin > "$tmp/payload.bin"
                unpack_payload "$tmp/payload.bin" "$dst" "$pfx" "$want"
            else
                log "[$pfx] zip fastboot -> images/"
                unzip -q "$rom" -d "$tmp"
                collect_images "$tmp" "$dst" "$pfx"
            fi ;;
        43724155) # CrAU
            unpack_payload "$rom" "$dst" "$pfx" "$want" ;;
        1f8b*|fd377a58|28b52ffd) # tgz / txz / tar.zst
            log "[$pfx] fastboot tar -> images/"
            tar -xf "$rom" -C "$tmp"
            collect_images "$tmp" "$dst" "$pfx" ;;
        *)
            die "[$pfx] format ROM tidak dikenal (magic $magic)" ;;
    esac

    if ! is_true "$KEEP_DOWNLOADS" && [[ $rom == "$WORK/dl/"* ]]; then rm -f "$rom"; fi
    rm -rf "$tmp"
    unpack_super "$dst" "$pfx"
}

env_get() { # file KEY -> value (dari output lp_tool.py)
    sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1" | tail -n1
}

load_base_env() { # muat info base (super/payload/anti) ke variabel global
    unset SUPER_LAYOUT SUPER_LAYOUT_MAGIC LP_SUPER_SIZE LP_METADATA_MAX LP_METADATA_SLOTS LP_BLOCK_SIZE LP_VIRTUAL_AB \
          LP_GROUPS LP_PARTITIONS LP_PARTITION_SIZES PAYLOAD_PARTITIONS \
          PAYLOAD_DYN_PARTITIONS PAYLOAD_DYN_GROUPS PAYLOAD_SNAPSHOT PAYLOAD_VABC ANTI_VER FLASHALL_PARTS
    local f
    for f in "$WORK/base.env" "$WORK/base_lp.env" "$WORK/base_payload.env"; do
        # shellcheck disable=SC1090
        if [[ -f $f ]]; then source "$f"; fi
    done
}

unpack_payload() { # payload dst pfx want
    local pl=$1 dst=$2 pfx=$3 want=$4 list="" p avail
    python3 "$SCRIPT_DIR/lp_tool.py" payload "$pl" > "$WORK/${pfx}_payload.env"
    avail=$(env_get "$WORK/${pfx}_payload.env" PAYLOAD_PARTITIONS)
    log "[$pfx] isi payload: $avail"
    if [[ $want != all ]]; then
        for p in ${want//,/ }; do
            if in_list "$p" "$avail"; then list+="${list:+,}$p"; fi
        done
        [[ -n $list ]] || die "[$pfx] tidak ada partisi $want di payload"
        list="-p $list"
    fi
    log "[$pfx] payload-dumper-go ${list:-(semua partisi)}"
    # shellcheck disable=SC2086  # list sengaja di-split (kosong = semua)
    if ! payload-dumper-go -c "$(nproc)" $list -o "$dst" "$pl" > "$WORK/pdg_$pfx.log" 2>&1; then
        tail -n 30 "$WORK/pdg_$pfx.log" >&2; die "[$pfx] payload-dumper-go gagal"
    fi
    rm -f "$pl"
}

# gabungkan super dari 1..n file (raw / sparse / zstd, boleh split) -> dst/super.img(.zst)
assemble_super() { # dst_dir part...
    local dst=$1 magic; shift
    magic=$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')
    log "super ditemukan: $(printf '%s ' "${@##*/}")(magic $magic)"
    if [[ $# -eq 1 ]]; then
        if [[ $magic == 28b52ffd ]]; then mv -f "$1" "$dst/super.img.zst"; else mv -f "$1" "$dst/super.img"; fi
        return 0
    fi
    case $magic in
        28b52ffd) cat "$@" | zstd -d -q -o "$dst/super.img" ;;
        3aff26ed) simg2img "$@" "$dst/super.img" ;;
        *)        cat "$@" > "$dst/super.img" ;;
    esac
    rm -f "$@"
}

collect_images() { # src_tree dst pfx
    local src=$1 dst=$2 pfx=$3 dir anti f sparts=()
    log "[$pfx] isi ROM (maks 60 file terbesar):"
    find "$src" -type f -printf '%s %P\n' | sort -rn | head -n 60 | \
        awk '{printf "    %10.1f MB  %s\n", $1/1048576, $2}'
    dir=$(dirname "$(find "$src" -type f -name 'boot.img' | head -n1)")
    [[ -d $dir && $dir != . ]] || die "[$pfx] boot.img / folder images tidak ditemukan di ROM"
    f=$(find "$src" -maxdepth 3 -name 'flash_all*.sh' | head -n1)
    if [[ -n $f ]]; then
        anti=$(grep -oE 'CURRENT_ANTI_VER=[0-9]+' "$f" | head -n1 | cut -d= -f2 || true)
        if [[ -n $anti ]]; then echo "ANTI_VER=$anti" >> "$WORK/${pfx}.env"; fi
        # partisi yang benar-benar di-flash flash_all.sh (fastboot $* flash abl_ab ...) -> whitelist
        local fparts
        fparts=$(grep -oE 'flash[[:space:]]+[A-Za-z0-9_]+' "$f" | awk '{print $2}' \
            | sed -E 's/_(ab|a|b)$//' | sort -u | tr '\n' ' ' || true)
        if [[ -n ${fparts// /} ]]; then
            echo "FLASHALL_PARTS=\"$fparts\"" >> "$WORK/${pfx}.env"
            log "[$pfx] flash_all.sh mem-flash: $fparts"
        fi
    fi
    # simpan META-INF (installer recovery) ROM base untuk INSTALLER=base
    local meta
    meta=$(find "$src" -maxdepth 3 -type d -name META-INF | head -n1)
    if [[ -n $meta && -e $meta/com/google/android/update-binary ]]; then
        rm -rf "$WORK/${pfx}_META-INF"; cp -a "$meta" "$WORK/${pfx}_META-INF"
        log "[$pfx] META-INF disimpan ($(find "$meta" -type f | wc -l) file)"
    fi
    # super bisa bernama super.img / super.img.zst / super.zst / split .0 .1 ... di folder mana pun
    mapfile -t sparts < <(find "$src" -type f -iname 'super*' ! -iname 'super_empty*' \
        ! -iname '*.txt' ! -iname '*.sh' ! -iname '*.bat' ! -iname '*.md5' ! -iname '*.sha*' | sort -V)
    if [[ ${#sparts[@]} -gt 0 ]]; then
        # path relatif ke root zip (induk META-INF, atau induk folder images)
        local zroot
        if [[ -n $meta ]]; then zroot=$(dirname "$meta"); else zroot=$(dirname "$dir"); fi
        {
            echo "SUPER_LAYOUT=\"$(for f in "${sparts[@]}"; do printf '%s ' "${f#"$zroot"/}"; done)\""
            echo "SUPER_LAYOUT_MAGIC=$(head -c 4 "${sparts[0]}" | od -An -tx1 | tr -d ' \n')"
        } >> "$WORK/${pfx}.env"
        assemble_super "$dst" "${sparts[@]}"
    else
        warn "[$pfx] tidak ada file super* di ROM"
    fi
    find "$dir" -maxdepth 1 -type f -name '*.img' -exec mv -t "$dst" {} +
}

unpack_super() { # dst pfx  (kalau ada super.img: pecah jadi partisi logical)
    local dst=$1 pfx=$2 sup="$1/super.img" n sz base
    if [[ -f $sup.zst ]]; then log "[$pfx] dekompres super.img.zst"; zstd -d --rm -q "$sup.zst" -o "$sup"; fi
    [[ -f $sup ]] || return 0
    if python3 "$SCRIPT_DIR/lp_tool.py" sparse "$sup"; then
        log "[$pfx] simg2img super.img"
        simg2img "$sup" "$sup.raw" && mv -f "$sup.raw" "$sup"
    fi
    python3 "$SCRIPT_DIR/lp_tool.py" super "$sup" > "$WORK/${pfx}_lp.env"
    cat "$WORK/${pfx}_lp.env"
    mkdir -p "$dst/lp"
    log "[$pfx] lpunpack super.img"
    # lewat lpunpack_compat.py: lpunpack.py toolkit rusak di Python 3.13+
    python3 "$SCRIPT_DIR/lpunpack_compat.py" "$PYBIN/lpunpack.py" "$sup" "$dst/lp" >/dev/null
    rm -f "$sup"
    for n in $(env_get "$WORK/${pfx}_lp.env" LP_PARTITION_SIZES); do
        sz=${n##*:}; n=${n%:*}
        [[ $sz -gt 0 && -f $dst/lp/$n.img ]] || continue
        base=${n%_a}; base=${base%_b}
        mv -f "$dst/lp/$n.img" "$dst/$base.img"
    done
    rm -rf "$dst/lp"
}

# ------------------------------------------------------------------ fs extract / repack
sanity_file() { # partisi -> file yang wajib ada setelah ekstrak
    case $1 in
        system) echo system/build.prop ;;
        vendor) echo build.prop ;;
        product|system_ext|mi_ext) echo etc/build.prop ;;
        *) echo "" ;;
    esac
}

verify_extract() { # root name -> 0 kalau lengkap
    local root=$1 name=$2 cfg got key res
    cfg="$root/config/${name}_fs_config"
    [[ -d $root/$name && -s $cfg ]] || { warn "$name: folder/config hasil ekstrak tidak ada"; return 1; }
    got=$(find "$root/$name" | wc -l)
    key=$(sanity_file "$name")
    if [[ -n $key && ! -e $root/$name/$key ]]; then
        warn "$name: $key tidak ada setelah ekstrak"; return 1
    fi
    # dicek per PATH: setiap entri asli fs_config harus ada di disk. Entri sintetis ("/",
    # lost+found, slot "odm/lost+found/" dari imgextractor) diabaikan.
    if res=$(python3 "$SCRIPT_DIR/fsconfig_check.py" check "$root" "$name"); then
        log "  $name: $got file/folder, $(head -n1 <<< "$res")"
        if grep -q 'HILANG' <<< "$res"; then
            warn "$name: beberapa entri fs_config tidak terbentuk (dalam toleransi):"
            grep 'HILANG' <<< "$res" | while IFS= read -r key; do printf '    %s\n' "$key" >&2; done
        fi
        return 0
    fi
    log "  $name: $got file/folder"
    warn "$name: ekstrak tidak lengkap"
    while IFS= read -r key; do printf '    %s\n' "$key" >&2; done <<< "$res"
    return 1
}

extract_img() { # img out_root
    local img=$1 root=$2 t name lg thr tl ok=0 tools=()
    name=$(basename "$img" .img)
    lg="$WORK/extract_$name.log"
    if python3 "$SCRIPT_DIR/lp_tool.py" sparse "$img"; then simg2img "$img" "$img.raw"; mv -f "$img.raw" "$img"; fi
    t=$(gettype -i "$img" 2>/dev/null || true)
    mkdir -p "$root"
    case $t in
        erofs)
            thr=$(nproc); if [[ $thr -gt 4 ]]; then thr=4; fi
            if [[ -n ${EXTRACT_EROFS:-} ]]; then tools+=("$EXTRACT_EROFS"); fi
            tools+=("$BIN/extract.erofs")
            for tl in "${tools[@]}"; do
                rm -rf "${root:?}/$name" "$root/config/${name}_"*
                # timeout: extractor yang macet dianggap gagal -> coba extractor berikutnya
                if timeout "${EXTRACT_TIMEOUT:-1800}" "$tl" -x -i "$img" -o "$root" -T"$thr" > "$lg" 2>&1 \
                        && verify_extract "$root" "$name"; then
                    ok=1; log "  $name diekstrak dengan $tl"; break
                fi
                warn "$name: extractor $tl gagal/tidak lengkap, log:"
                tail -n 15 "$lg" >&2
            done ;;
        ext)
            python3 "$PYBIN/imgextractor/imgextractor.py" "$img" "$root" > "$lg" 2>&1 || true
            if [[ -s $root/config/${name}_fs_config ]]; then
                python3 "$SCRIPT_DIR/fsconfig_check.py" sanitize "$root" "$name" >> "$lg" 2>&1 || true
            fi
            if verify_extract "$root" "$name"; then ok=1; else tail -n 15 "$lg" >&2; fi ;;
        *)  die "tipe fs tidak dikenal untuk $name.img: '$t'" ;;
    esac
    [[ $ok == 1 ]] || die "ekstrak $name.img gagal/tidak lengkap (tipe $t). Lihat log di atas."
}

prep_config() { # root name
    local root=$1 name=$2
    mkdir -p "$root/$name/lost+found"
    touch -t 200901010000.00 "$root/$name/lost+found"
    python3 "$PYBIN/fspatch.py"     "$root/$name" "$root/config/${name}_fs_config"    >/dev/null
    python3 "$PYBIN/contextpatch.py" "$root/$name" "$root/config/${name}_file_contexts" >/dev/null
}

repack_erofs() { # root name out_img
    local root=$1 name=$2 img=$3
    prep_config "$root" "$name"
    mkfs.erofs -z"$EROFS_COMP" -T"$FIXED_TS" --mount-point "/$name" \
        --fs-config-file "$root/config/${name}_fs_config" \
        --file-contexts  "$root/config/${name}_file_contexts" \
        "$img" "$root/$name" >/dev/null
}

repack_ext4() { # root name out_img rw(true/false)
    local root=$1 name=$2 img=$3 rw=$4 inodes blocks try=0 share=(-s)
    prep_config "$root" "$name"
    inodes=$(( $(wc -l < "$root/config/${name}_fs_config") + 64 ))
    blocks=$(du -s --block-size=4096 "$root/$name" | cut -f1)
    blocks=$(( blocks * 110 / 100 + inodes / 16 + 2048 ))
    if is_true "$rw"; then
        share=()
        blocks=$(( blocks + EXT4_HEADROOM_MB * 256 ))
    fi
    while :; do
        rm -f "$img"
        mke2fs -q -O ^has_journal -L "$name" -I 256 -N "$inodes" -M "/$name" -m 0 \
               -t ext4 -b 4096 "$img" "$blocks" >/dev/null
        if e2fsdroid -e -T "$FIXED_TS" "${share[@]}" \
               -C "$root/config/${name}_fs_config" \
               -S "$root/config/${name}_file_contexts" \
               -f "$root/$name" -a "/$name" "$img" >/dev/null 2>"$WORK/e2fsdroid.log"; then
            break
        fi
        try=$((try + 1))
        [[ $try -lt 4 ]] || { cat "$WORK/e2fsdroid.log" >&2; die "e2fsdroid $name gagal"; }
        warn "$name: ruang ext4 kurang, perbesar 20% (percobaan $try)"
        blocks=$(( blocks * 120 / 100 ))
    done
    if ! is_true "$rw"; then
        resize2fs -f -M "$img" >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------ cek VINTF
# target-level manifest vendor/odm harus ada di compatibility matrix FRAMEWORK
# (/system/etc/vintf/compatibility_matrix.<level>.xml). Kalau tidak ada, matrix level itu
# disalin dari system base ke /system/etc/vintf port. File vintf vendor/odm tidak disentuh.
check_vintf() {
    local levels="" lv f matrices sysd="$P_FS/system/system/etc/vintf" missing="" plat
    plat=$(get_prop "$B_FS/vendor/build.prop" ro.board.platform)
    while IFS= read -r -d '' f; do
        lv=$(grep -oE 'target-level="[0-9]+"' "$f" | grep -oE '[0-9]+' | head -n1 || true)
        [[ -n $lv ]] && levels+=" $lv"
    done < <(find "$B_FS/vendor/etc/vintf" "$B_FS/odm/etc/vintf" -maxdepth 2 -type f -name 'manifest*.xml' -print0 2>/dev/null || true)
    levels=$(tr ' ' '\n' <<< "$levels" | grep -v '^$' | sort -u | tr '\n' ' ' || true)
    if [[ ! -d $sysd ]]; then warn "VINTF: $sysd tidak ada"; return 0; fi
    matrices=$(find "$sysd" -maxdepth 1 -name 'compatibility_matrix.[0-9]*.xml' -printf '%f ' | sed 's/compatibility_matrix\.//g; s/\.xml//g')
    log "VINTF: vendor/odm target-level: ${levels:-?} (platform ${plat:-?}, sku $TARGET_DEVICE)"
    log "VINTF: framework donor mendukung level: $matrices"
    if [[ -z ${levels// /} ]]; then warn "VINTF: target-level vendor tidak ditemukan"; return 0; fi
    for lv in $levels; do
        if in_list "$lv" "$matrices"; then ok "VINTF: level $lv didukung framework donor"; else missing+=" $lv"; fi
    done
    [[ -n $missing ]] || return 0

    if ! is_true "$VINTF_COMPAT"; then
        warn "VINTF: level$missing TIDAK ada di framework donor -> risiko bootloop / dialog 'internal problem'"
        return 0
    fi
    # ambil compatibility_matrix.<level>.xml dari system ROM base (Android lama masih punya)
    local img="$B_IMG/system.img" tmp="$WORK/base_vintf" t src
    if [[ ! -f $img ]]; then warn "VINTF: system.img base tidak ada, level$missing tidak bisa ditambal"; return 0; fi
    rm -rf "$tmp"; mkdir -p "$tmp"
    t=$(gettype -i "$img" 2>/dev/null || true)
    if [[ $t == erofs ]]; then
        "${EXTRACT_EROFS:-$BIN/extract.erofs}" -i "$img" -X system/etc/vintf -o "$tmp" >/dev/null 2>&1 \
            || "$BIN/extract.erofs" -i "$img" -X system/etc/vintf -o "$tmp" >/dev/null 2>&1 || true
    else
        python3 "$PYBIN/imgextractor/imgextractor.py" "$img" "$tmp" >/dev/null 2>&1 || true
    fi
    for lv in $missing; do
        src=$(find "$tmp" -type f -path "*/etc/vintf/compatibility_matrix.$lv.xml" | head -n1)
        if [[ -n $src ]]; then
            cp -f "$src" "$sysd/compatibility_matrix.$lv.xml"
            chmod 0644 "$sysd/compatibility_matrix.$lv.xml"
            ok "VINTF: compatibility_matrix.$lv.xml disalin dari system base (level $lv jadi dikenali)"
        else
            warn "VINTF: level $lv TIDAK ada di framework donor maupun system base -> risiko bootloop"
        fi
    done
    rm -rf "$tmp"
    warn "VINTF: vendor level$missing lebih tua dari yang didukung Android donor. Matrix sudah ditambal, tapi HAL lama tetap bisa tidak dikenali framework baru - cek logcat setelah boot"
}

# ------------------------------------------------------------------ VNDK / linker
# vendor lama (ro.vndk.version <= 34) me-link library VNDK dari APEX com.android.vndk.vNN
# di system_ext/system. Android baru tidak lagi membawanya -> ambil dari ROM base.
vndk_compat() {
    local ver apexd have f tmp="$WORK/base_apex" t img sub found
    ver=$(get_prop "$B_FS/vendor/build.prop" ro.vndk.version)
    if [[ ! $ver =~ ^[0-9]+$ ]]; then log "VNDK: ro.vndk.version vendor '${ver:-kosong}' (tidak memakai VNDK), dilewati"; return 0; fi
    have=$(find "$P_FS/system_ext/apex" "$P_FS/system/system/apex" -maxdepth 1 -name "com.android.vndk.v$ver.*apex" -printf '%f ' 2>/dev/null || true)
    if [[ -n ${have// /} ]]; then ok "VNDK: vendor butuh v$ver, sudah ada di port ($have)"; vndk_declare "$ver"; return 0; fi
    warn "VNDK: vendor butuh VNDK v$ver tapi APEX-nya tidak ada di system donor -> HAL vendor gagal load kalau tidak ditambah"
    rm -rf "$tmp"; mkdir -p "$tmp"
    for img in system_ext system; do
        [[ -f $B_IMG/$img.img ]] || continue
        if [[ $img == system ]]; then sub=system/apex; else sub=apex; fi
        t=$(gettype -i "$B_IMG/$img.img" 2>/dev/null || true)
        if [[ $t == erofs ]]; then
            "${EXTRACT_EROFS:-$BIN/extract.erofs}" -i "$B_IMG/$img.img" -X "$sub" -o "$tmp/$img" >/dev/null 2>&1 \
                || "$BIN/extract.erofs" -i "$B_IMG/$img.img" -X "$sub" -o "$tmp/$img" >/dev/null 2>&1 || true
        else
            python3 "$PYBIN/imgextractor/imgextractor.py" "$B_IMG/$img.img" "$tmp/$img" >/dev/null 2>&1 || true
        fi
    done
    found=$(find "$tmp" -type f -name "com.android.vndk.v$ver.*apex" | head -n1)
    if [[ -z $found ]]; then
        warn "VNDK: com.android.vndk.v$ver tidak ada juga di ROM base -> kemungkinan besar bootloop / HAL mati"
        rm -rf "$tmp"; return 0
    fi
    apexd="$P_FS/system_ext/apex"; mkdir -p "$apexd"
    cp -f "$found" "$apexd/"; chmod 0644 "$apexd/$(basename "$found")"
    ok "VNDK: $(basename "$found") ($(( $(stat -c%s "$found") / 1048576 )) MB) disalin dari base ke system_ext/apex"
    rm -rf "$tmp"
    vndk_declare "$ver"
}

# framework manifest harus mendeklarasikan <vendor-ndk> versi yang diminta device matrix vendor.
# Android baru tidak lagi menulis vendor-ndk lama -> tambah fragment manifest framework.
vndk_declare() {
    local ver=$1 d f
    for d in "$P_FS/system/system" "$P_FS/system_ext" "$P_FS/product"; do
        [[ -d $d/etc/vintf ]] || continue
        if grep -lsE "<version>[[:space:]]*${ver}[[:space:]]*</version>" "$d"/etc/vintf/manifest.xml "$d"/etc/vintf/manifest/*.xml 2>/dev/null \
            | xargs -r grep -l '<vendor-ndk>' 2>/dev/null | grep -q .; then
            ok "VINTF: vendor-ndk $ver sudah dideklarasikan framework ($(basename "$d"))"
            return 0
        fi
    done
    d="$P_FS/system/system/etc/vintf/manifest"
    if [[ ! -d $P_FS/system/system/etc/vintf ]]; then warn "VINTF: system/etc/vintf port tidak ada, vendor-ndk $ver tidak bisa dideklarasikan"; return 0; fi
    mkdir -p "$d"; f="$d/vendor_ndk_v$ver.xml"
    printf '<manifest version="1.0" type="framework">\n    <vendor-ndk>\n        <version>%s</version>\n    </vendor-ndk>\n</manifest>\n' "$ver" > "$f"
    chmod 0644 "$f"; chmod 0755 "$d"
    ok "VINTF: vendor-ndk $ver dideklarasikan di system/etc/vintf/manifest/$(basename "$f")"
}

# arah sebaliknya: yang DIMINTA device matrix vendor/odm (vendor-ndk, system-sdk,
# HAL framework wajib) harus disediakan framework manifest port.
vintf_device_check() {
    local args=() f d n
    while IFS= read -r -d '' f; do args+=(--device-matrix "$f"); done \
        < <(find "$B_FS/vendor/etc/vintf" "$B_FS/odm/etc/vintf" -maxdepth 1 -type f -name 'compatibility_matrix*.xml' -print0 2>/dev/null || true)
    if [[ ${#args[@]} -eq 0 ]]; then warn "VINTF: device compatibility matrix vendor/odm tidak ditemukan, cek dilewati"; return 0; fi
    for d in "$P_FS/system/system" "$P_FS/system_ext" "$P_FS/product"; do
        if [[ -d $d ]]; then args+=(--framework "$d"); fi
    done
    # device manifest vendor/odm (termasuk manifest_<sku>.xml & manifest/*.xml) untuk cek versi sepolicy
    while IFS= read -r -d '' f; do args+=(--device-manifest "$f"); done \
        < <(find "$B_FS/vendor/etc/vintf" "$B_FS/odm/etc/vintf" -maxdepth 2 -type f -name 'manifest*.xml' -print0 2>/dev/null || true)
    python3 "$SCRIPT_DIR/vintf_check.py" "${args[@]}" > "$WORK/vintf_device.log" 2>&1 || true
    while IFS= read -r d; do printf '    %s\n' "$d"; done < "$WORK/vintf_device.log"
    # HAL framework yang diminta vendor tapi tidak ada di donor (mis. sigma_miracast Qualcomm WFD):
    # dijadikan optional di device matrix vendor/odm -> tidak ada dialog "internal problem";
    # fiturnya sendiri memang tidak tersedia di ROM donor.
    local relax_hals=() hal mats=()
    while IFS= read -r hal; do relax_hals+=(--hal "$hal"); done < <(sed -n 's/^MISSING HAL framework \([^ ]*\) .*/\1/p' "$WORK/vintf_device.log")
    if [[ ${#relax_hals[@]} -gt 0 ]] && is_true "${VINTF_RELAX:-true}"; then
        while IFS= read -r -d '' f; do mats+=("$f"); done \
            < <(find "$B_FS/vendor/etc/vintf" "$B_FS/odm/etc/vintf" -maxdepth 1 -type f -name 'compatibility_matrix*.xml' -print0 2>/dev/null || true)
        python3 "$SCRIPT_DIR/vintf_relax.py" "${relax_hals[@]}" "${mats[@]}" > "$WORK/vintf_relax.log" 2>&1 || true
        grep -v '^RESULT' "$WORK/vintf_relax.log" || true
        ok "VINTF: HAL framework yang tidak ada di donor dijadikan optional di device matrix vendor: $(printf '%s ' "${relax_hals[@]}" | sed 's/--hal //g')(fitur HAL itu tidak tersedia di ROM port)"
        python3 "$SCRIPT_DIR/vintf_check.py" "${args[@]}" > "$WORK/vintf_device.log" 2>&1 || true
    fi
    # yang dicek VintfObject.verifyBuildAtBoot (Android 16) = vendor-ndk, system-sdk, sepolicy-version,
    # kernel-sepolicy-version. Gagal di sini = dialog "There's an internal problem with your device".
    local dlg hal_miss
    dlg=$(grep -cE '^MISSING (vendor-ndk|system-sdk|sepolicy-version|kernel-sepolicy-version)' "$WORK/vintf_device.log" || true)
    hal_miss=$(grep -cE '^MISSING HAL' "$WORK/vintf_device.log" || true)
    if [[ ${dlg:-0} -gt 0 ]]; then
        warn "VINTF: $dlg syarat verifyBuildAtBoot TIDAK terpenuhi -> dialog 'internal problem' saat boot (lihat MISSING di atas)"
    else
        ok "VINTF: syarat verifyBuildAtBoot (vendor-ndk, system-sdk, sepolicy) terpenuhi -> tanpa dialog 'internal problem'"
    fi
    if [[ ${hal_miss:-0} -gt 0 ]]; then
        warn "VINTF: $hal_miss HAL framework yang diminta vendor tidak ada di donor -> fitur terkait tidak jalan (bukan penyebab dialog)"
    else
        ok "VINTF: semua HAL framework yang diminta vendor/odm ada di framework port"
    fi
}

linker_check() {
    local args=() d
    for d in vendor odm; do
        if [[ -d $B_FS/$d ]]; then args+=(--check "$B_FS/$d" --apex "$B_FS/$d/apex"); fi
    done
    for d in "$P_FS/system/system" "$P_FS/system_ext" "$P_FS/product"; do
        if [[ -d $d ]]; then args+=(--provide "$d"); fi
    done
    for d in "$P_FS/system/system/apex" "$P_FS/system_ext/apex"; do
        if [[ -d $d ]]; then args+=(--apex "$d"); fi
    done
    log "linker: cek dependensi ELF vendor/odm (DT_NEEDED) ..."
    timeout 900 python3 "$SCRIPT_DIR/linker_check.py" "${args[@]}" \
        --erofs-extract "${EXTRACT_EROFS:-$BIN/extract.erofs}" > "$WORK/linker_check.log" 2>&1 || true
    while IFS= read -r d; do printf '    %s\n' "$d"; done < "$WORK/linker_check.log"
    if grep -q 'MISSING' "$WORK/linker_check.log"; then
        if grep -q '64-bit: semua dependensi ditemukan' "$WORK/linker_check.log" && [[ ! -f $P_FS/system/system/lib/libc.so ]]; then
            log "linker: yang hilang hanya library 32-bit (system donor 64-bit only) -> lihat cek ABI: masalah hanya kalau vendor punya proses 32-bit"
        else
            warn "linker: ada library yang dibutuhkan vendor/odm tapi tidak ada di ROM (lihat daftar MISSING) -> HAL terkait bisa gagal start"
        fi
    fi
}

# ------------------------------------------------------------------ props device
merge_device_props() {
    local bp="$B_FS/product/etc/build.prop" pp="$P_FS/product/etc/build.prop" n allow=() args=() r
    if [[ ! -f $bp || ! -f $pp ]]; then warn "props: build.prop product base/port tidak ada, dilewati"; return 0; fi
    read -r -a allow <<< "$PROP_MERGE_ALLOW"
    for r in "${allow[@]}"; do args+=(--allow "$r"); done
    python3 "$SCRIPT_DIR/prop_merge.py" "$bp" "$pp" "${args[@]}" > "$WORK/prop_merge.log"
    n=$(wc -l < "$WORK/prop_merge.log")
    ok "props: $n props hardware (allowlist) dari product base disalin ke product port"
    if [[ $n -gt 0 ]]; then sed 's/^/    /' "$WORK/prop_merge.log" | head -n 80; fi
    if [[ $n -gt 80 ]]; then log "    ... ($((n - 80)) lainnya di log kerja)"; fi
}

# ------------------------------------------------------------------ patch: port
# ROM hasil port bukan rilis official maintainer donor: maintainer -> ROM_MAINTAINER, OFFICIAL ->
# ROM_RELEASE_TYPE di build.prop system/system_ext/product (dipakai halaman "Tentang ponsel" ROM)
rom_branding() {
    local f files=() res
    [[ -n $ROM_MAINTAINER ]] || { log "branding: ROM_MAINTAINER kosong, identitas build donor tidak diubah"; return 0; }
    for f in "${PORT_PROP_FILES[@]}"; do [[ -f $P_FS/$f ]] && files+=("$P_FS/$f"); done
    [[ ${#files[@]} -gt 0 ]] || return 0
    res=$(python3 "$SCRIPT_DIR/rom_branding.py" --maintainer "$ROM_MAINTAINER" --type "$ROM_RELEASE_TYPE" "${files[@]}")
    grep -v '^RESULT' <<< "$res" | sed "s|$P_FS/||; s/^/    /" || true
    res=$(sed -n 's/^RESULT //p' <<< "$res")
    if [[ ${res%% *} -gt 0 ]]; then ok "branding: maintainer -> $ROM_MAINTAINER (${res%% *} prop), $ROM_RELEASE_TYPE (${res#* } prop)"
    else warn "branding: ROM donor tidak punya prop maintainer (ro.<rom>.maintainer); teks maintainer di Tentang ponsel mungkin berasal dari resource app dan tidak berubah. $ROM_RELEASE_TYPE: ${res#* } prop"; fi
    branding_overlays
}

# RRO branding khusus ROM (overlays/<rom>/<Nama>/: AndroidManifest.xml + res/), mis. kartu maintainer
# AfterLife di Tentang ponsel tanpa foto & link sosial media maintainer asli. Dipakai kalau build.prop
# donor punya ro.<rom>.version. Dibangun saat port (apktool/aapt2), ditandatangani testkey, dipasang
# ke product/overlay (RRO statis, aktif sendiri).
BRANDING_OVERLAYS=${BRANDING_OVERLAYS:-true}    # false = jangan pasang RRO overlays/<rom>/
branding_overlays() {
    local d rom name src w jar out kd="$WORK/aosp_testkey" n=0 rels=()
    if ! is_true "$BRANDING_OVERLAYS"; then
        [[ -d $SCRIPT_DIR/../overlays ]] && log "branding overlay: dimatikan (BRANDING_OVERLAYS=false)"
        return 0
    fi
    [[ -n $ROM_MAINTAINER ]] || { log "branding overlay: ROM_MAINTAINER kosong, tampilan maintainer donor dipertahankan"; return 0; }
    [[ -d $SCRIPT_DIR/../overlays && -d $P_FS/product ]] || return 0
    for d in "$SCRIPT_DIR"/../overlays/*/; do
        rom=$(basename "$d")
        grep -qsE "^ro\.${rom}\.version=" "${PORT_PROP_FILES[@]/#/$P_FS/}" || continue
        for src in "$d"*/; do
            name=$(basename "$src")
            [[ -f $src/AndroidManifest.xml && -d $src/res ]] || continue
            jar=$(apktool_jar) || { warn "branding overlay: apktool gagal diunduh, $name dilewati"; return 0; }
            aosp_key testkey "$AOSP_TESTKEY_SHA256" || { warn "branding overlay: testkey tidak ada, $name dilewati"; return 0; }
            w="$WORK/rro_$name"; rm -rf "$w"; mkdir -p "$w"; cp -a "$src" "$w/src"
            printf '%s\n' "version: 2.12.1" "apkFileName: $name.apk" "isFrameworkApk: false" "usesFramework:" "  ids:" "  - 1" \
                "  tag: null" "sdkInfo:" "  minSdkVersion: 31" "  targetSdkVersion: 34" "packageInfo:" "  forcedPackageId: 127" \
                "  renameManifestPackage: null" "versionInfo:" "  versionCode: 1" "  versionName: '1'" "doNotCompress:" "- resources.arsc" \
                > "$w/src/apktool.yml"
            if ! java -jar "$jar" b "$w/src" -o "$w/u.apk" > "$w/log" 2>&1; then
                warn "branding overlay $name: build gagal: $(tail -n1 "$w/log")"; continue
            fi
            zipalign -f -p 4 "$w/u.apk" "$w/a.apk" >/dev/null || { warn "branding overlay $name: zipalign gagal"; continue; }
            out="$P_FS/product/overlay/$name.apk"; mkdir -p "$(dirname "$out")"
            apksigner sign --key "$kd/testkey.pk8" --cert "$kd/testkey.x509.pem" --out "$out" "$w/a.apk" >/dev/null 2>>"$w/log" \
                || { warn "branding overlay $name: apksigner gagal"; rm -f "$out"; continue; }
            rm -f "$out.idsig"; chmod 644 "$out"; rm -rf "$w"
            rels+=("overlay/$name.apk"); n=$((n + 1))
            ok "branding overlay: product/overlay/$name.apk ($rom)"
        done
    done
    if [[ $n -gt 0 && -f $P_FS/config/product_file_contexts ]]; then
        python3 "$SCRIPT_DIR/addon_tool.py" ctx "$P_FS/config/product_file_contexts" "$P_FS/product" product "${rels[@]}" >/dev/null || true
    fi
}

# codename donor: dari props device ROM AOSP; lewati nama generik
detect_donor() {
    local c v hint t
    for c in "$(get_prop "$P_FS/product/etc/build.prop" ro.product.product.device)" \
             "$(get_prop "$P_FS/system_ext/etc/build.prop" ro.product.system_ext.device)" \
             "$(get_prop "$P_FS/system/system/build.prop" ro.product.system.device)" \
             "$(cat "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop" "$P_FS/product/etc/build.prop" 2>/dev/null \
                | grep -E '^ro\.[a-z0-9]+\.device=' | grep -vE '^ro\.(product|build|vendor|odm|boot)\.' | head -n1 | cut -d= -f2 || true)" \
             "$(get_prop "$P_FS/system/system/build.prop" ro.build.product)"; do
        v=${c%%_*}
        case ${v,,} in ""|generic*|mainline|aosp*|gsi*|sdk*|qssi*|missi*|miproduct|mi_ext|xiaomi*|"$TARGET_DEVICE") continue ;; esac
        echo "$v"; return 0
    done
    # cadangan: token nama file OTA (mis. lineage-23.0-20260101-nightly-cupid-signed.zip)
    hint=${PORT_ROM%%\?*}; hint=${hint##*/}; hint=${hint%.zip}
    for t in ${hint//[-_]/ }; do
        case ${t,,} in *[0-9]*|lineage|axion|crdroid|evolution*|nightly|unofficial|official|signed|ota|gapps|vanilla|user*|release|community|"$TARGET_DEVICE") continue ;; esac
        if [[ ${#t} -ge 3 ]]; then echo "${t,,}"; return 0; fi
    done
    echo ""
}

base_hw_prop() { # key -> nilai efektif di vendor+odm base (ikut import SKU odm)
    python3 "$SCRIPT_DIR/prop_effective.py" --sku "$TARGET_DEVICE" --map "/odm=$B_FS/odm" --map "/vendor=$B_FS/vendor" \
        --get "$1" vendor="$B_FS/vendor/build.prop" odm="$B_FS/odm/etc/build.prop" 2>/dev/null || true
}

PORT_PROP_FILES=(system/system/build.prop system_ext/etc/build.prop product/etc/build.prop)

patch_props() {
    local donor=$1 base=$2 f model brand market manuf dens rel
    # nilai efektif vendor + odm (termasuk file SKU odm, mis. model 21121210G / POCO F4 GT)
    model=$(base_hw_prop ro.product.vendor.model)
    brand=$(base_hw_prop ro.product.vendor.brand)
    market=$(base_hw_prop ro.product.vendor.marketname)
    manuf=$(base_hw_prop ro.product.vendor.manufacturer)
    for rel in "${PORT_PROP_FILES[@]}"; do
        f="$P_FS/$rel"
        [[ -f $f ]] || continue
        log "props: $rel"
        if [[ -n $donor && $donor != "$base" ]]; then
            # codename donor -> ingres di props identitas device & ROM (ro.lineage.device, flavor, versi ROM)
            # batas nama: bukan huruf/angka (garis bawah ikut dihitung, mis. lineage_cupid-userdebug)
            sed -i -E "/^(ro\.product\.[a-z_]*\.(device|name)|ro\.product\.mod_device|ro\.build\.product|ro\.product\.board|ro\.[a-z0-9_]+\.device|ro\.([a-z0-9_]+\.)?build\.flavor|ro\.build\.description|ro\.build\.display\.id|ro\.[a-z0-9_]+\.(display\.)?version|ro\.modversion)=/ s/(^[^=]*=|[^A-Za-z0-9])${donor}([^A-Za-z0-9]|\$)/\1${base}\2/g" "$f"
        fi
        if [[ -n $model ]]; then
            sed -i -E "s/^(ro\.product\.(system|system_ext|product|odm)\.model)=.*/\1=${model//\//\\/}/" "$f"
        fi
        if [[ -n $brand ]]; then
            sed -i -E "s/^(ro\.product\.(system|system_ext|product|odm)\.brand)=.*/\1=${brand//\//\\/}/" "$f"
        fi
        if [[ -n $market ]]; then
            sed -i -E "s/^(ro\.product\.(system|system_ext|product|odm)\.marketname)=.*/\1=${market//\//\\/}/" "$f"
        fi
        if [[ -n $manuf ]]; then
            sed -i -E "s/^(ro\.product\.(system|system_ext|product|odm)\.manufacturer)=.*/\1=${manuf//\//\\/}/" "$f"
        fi
    done

    # density layar ingres (donor membawa density panelnya sendiri)
    local pp="$P_FS/product/etc/build.prop"
    dens=$LCD_DENSITY
    if [[ $dens == auto ]]; then
        dens=$(get_prop "$B_FS/product/etc/build.prop" ro.sf.lcd_density)
        [[ -n $dens ]] || dens=$(base_hw_prop ro.sf.lcd_density)
    fi
    if [[ -n $dens ]]; then
        for f in "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop"; do
            if [[ -f $f ]]; then sed -i '/^ro\.sf\.lcd_density=/d' "$f"; fi
        done
        set_prop "$pp" ro.sf.lcd_density "$dens"
        ok "props: ro.sf.lcd_density=$dens"
    else
        warn "props: density ingres tidak ditemukan di base, density donor dipakai (isi LCD_DENSITY kalau UI kebesaran/kekecilan)"
    fi

    if is_true "$DEBUG_ADB"; then
        local sp="$P_FS/system/system/build.prop"
        log "debug: adb aktif sejak boot (matikan DEBUG_ADB untuk build rilis)"
        set_prop "$sp" ro.adb.secure 0
        set_prop "$sp" persist.sys.usb.config mtp,adb
        set_prop "$sp" persist.service.adb.enable 1
        set_prop "$sp" persist.service.debuggable 1
    fi
}

# props milik hardware (diisi vendor/odm ingres) tidak boleh ditimpa build.prop donor:
# init memuat system -> system_ext -> vendor -> odm -> product, yang belakangan menang.
PROPS_HW_FIXED="ro.product.board ro.board.platform ro.vndk.version"
props_effective() {
    local vkeys k f n=0 files=() lbl rel
    vkeys=$(cat "$B_FS/vendor/build.prop" "$B_FS"/odm/etc/*build.prop 2>/dev/null \
        | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.-]*\)=.*/\1/p' \
        | grep -E '^(ro\.product\.vendor\.|ro\.vendor\.)' | sort -u || true)
    vkeys+=" $PROPS_HW_FIXED"
    # identitas hardware product sama dengan ROM base (nama product donor sudah diganti codename)
    local bp="$B_FS/product/etc/build.prop" pp="$P_FS/product/etc/build.prop" v
    if [[ -f $bp && -f $pp ]]; then
        for k in ro.product.product.device ro.product.product.model ro.product.product.brand \
                 ro.product.product.manufacturer ro.product.product.marketname; do
            v=$(get_prop "$bp" "$k")
            if [[ -n $v && $(get_prop "$pp" "$k") != "$v" ]]; then
                log "props: $k = $v (sama dengan product base)"
                set_prop "$pp" "$k" "$v"
            fi
        done
    fi
    # props yang diisi vendor/odm tapi ditimpa product DONOR (base product tidak menimpanya):
    # buang, supaya nilainya sama seperti di ingres stock (mis. aaudio.mmap_policy)
    local allv bk
    allv=$(cat "$B_FS/vendor/build.prop" "$B_FS"/odm/etc/*build.prop 2>/dev/null \
        | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.-]*\)=.*/\1/p' | sort -u || true)
    bk=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_.-]*\)=.*/\1/p' "$bp" 2>/dev/null | sort -u || true)
    if [[ -f $pp ]]; then
        for k in $(comm -23 <(printf '%s\n' "$allv") <(printf '%s\n' "$bk")); do
            [[ $k == ro.product.first_api_level || $k == ro.sf.lcd_density ]] && continue
            in_list "$k" "${PROPS_PORT_FORCED:-}" && continue   # sengaja diisi port (mis. ro.zygote)
            if grep -q "^${k//./\\.}=" "$pp"; then
                sed -i "/^${k//./\\.}=/d" "$pp"
                log "props: $k dihapus dari product (ingres memakai nilai vendor/odm)"
                n=$((n + 1))
            fi
        done
    fi
    for rel in "${PORT_PROP_FILES[@]}"; do
        f="$P_FS/$rel"
        [[ -f $f ]] || continue
        for k in $vkeys; do
            if grep -q "^${k//./\\.}=" "$f"; then
                sed -i "/^${k//./\\.}=/d" "$f"
                log "props: $k dihapus dari $rel (nilai vendor/odm ingres yang dipakai)"
                n=$((n + 1))
            fi
        done
    done
    # ro.product.first_api_level = Android saat HP rilis (ingres: Android 12 = 31). Nilai donor
    # (mis. 33/34) membuat framework menuntut fitur vendor yang tidak ada -> pakai nilai ingres.
    local bfal pfal
    bfal=$FIRST_API_LEVEL
    if [[ $bfal == auto ]]; then
        bfal=$(get_prop "$B_FS/product/etc/build.prop" ro.product.first_api_level)
        [[ -n $bfal ]] || bfal=$(base_hw_prop ro.product.first_api_level)
        [[ -n $bfal ]] || { bfal=$FIRST_API_LEVEL_FALLBACK; log "props: first_api_level tidak ada di base, pakai $bfal (ingres rilis Android 12)"; }
    fi
    if [[ -f $pp ]]; then
        pfal=$(cat "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop" "$pp" 2>/dev/null \
            | sed -n 's/^ro\.product\.first_api_level=//p' | tail -n1)
        for f in "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop"; do
            if [[ -f $f ]]; then sed -i '/^ro\.product\.first_api_level=/d' "$f"; fi
        done
        set_prop "$pp" ro.product.first_api_level "$bfal"
        if [[ -n $pfal && $pfal != "$bfal" ]]; then
            ok "props: ro.product.first_api_level $pfal (donor) -> $bfal ($TARGET_DEVICE)"
        fi
    fi
    files=(system="$P_FS/system/system/build.prop" system_ext="$P_FS/system_ext/etc/build.prop"
           vendor="$B_FS/vendor/build.prop" odm="$B_FS/odm/etc/build.prop"
           product="$P_FS/product/etc/build.prop")
    python3 "$SCRIPT_DIR/prop_effective.py" --sku "$TARGET_DEVICE" --map "/odm=$B_FS/odm" --map "/vendor=$B_FS/vendor" \
        "${files[@]}" > "$WORK/prop_effective.log" 2>&1 || true
    log "props yang berlaku saat boot (urutan load init):"
    while IFS= read -r lbl; do
        case $lbl in RESULT*) ;; *) printf '    %s\n' "${lbl#KEY  }" ;; esac
    done < "$WORK/prop_effective.log"
    if grep -q '^OVERRIDE !!' "$WORK/prop_effective.log"; then
        warn "props: masih ada props hardware vendor/odm yang ditimpa partisi donor (baris OVERRIDE !!)"
    else
        if [[ $n -gt 0 ]]; then ok "props: semua props hardware (vendor/odm) memakai nilai $TARGET_DEVICE, $n baris donor dibuang"
        else ok "props: semua props hardware (vendor/odm) memakai nilai $TARGET_DEVICE"; fi
    fi
}

# priv-app yang diambil dari base butuh allowlist privapp-permissions versi base juga.
# Tanpa ini, izin privileged yang tidak tercatat di allowlist donor bikin system_server
# crash saat boot (ro.control_privapp_permissions=enforce) -> bootloop.
base_privapp_perms() { # <rel dir app di base, mis. product/priv-app/MiuiCamera>
    local rel=$1 part apk pkg out n
    [[ $rel == */priv-app/* ]] || return 0
    part=${rel%%/*}
    # APK yang benar-benar dipasang (hasil salinan di port, bisa sudah di-patch: GameKeys + REAL_GET_TASKS)
    apk=$(find "$P_FS/$rel" -maxdepth 1 -name '*.apk' 2>/dev/null | head -n1)
    [[ -n $apk ]] || apk=$(find "$B_FS/$rel" -maxdepth 1 -name '*.apk' | head -n1)
    [[ -n $apk ]] || return 0
    pkg=$(python3 "$SCRIPT_DIR/apk_index.py" --apk "$apk" || true)
    if [[ -z $pkg ]]; then warn "privapp: package $(basename "$apk") tidak terbaca, allowlist tidak disalin"; return 0; fi
    out="$P_FS/$part/etc/permissions/privapp-permissions-${TARGET_DEVICE}-base-${pkg//./_}.xml"
    # izin yang diminta APK: di base app ini mungkin bertanda tangan platform (izin signature|privileged
    # tidak perlu allowlist), di ROM donor kuncinya beda -> izin itu jatuh ke jalur "privileged" dan
    # wajib ada di allowlist. Semua uses-permission ikut dimasukkan (izin non-privileged diabaikan
    # PackageManager, jadi aman).
    python3 "$SCRIPT_DIR/apk_index.py" --perms "$apk" > "$WORK/privapp_req.txt" 2>/dev/null || true
    n=$(python3 - "$pkg" "$out" "$B_FS/$part/etc/permissions" "$WORK/privapp_req.txt" <<'PY'
import glob, os, re, sys
pkg, out, d, req = sys.argv[1:5]
pat = re.compile(r'<privapp-permissions\s+package="%s"\s*>(.*?)</privapp-permissions>' % re.escape(pkg), re.S)
allow, deny = [], []
for f in sorted(glob.glob(os.path.join(d, "*.xml"))):
    try:
        s = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    s = re.sub(r'<!--.*?-->', '', s, flags=re.S)
    for body in pat.findall(s):
        for kind, name in re.findall(r'<(permission|deny-permission)\s+name="([^"]+)"', body):
            (allow if kind == "permission" else deny).append(name)
from_base = len(set(allow))
try:
    wanted = [l.strip() for l in open(req, encoding="utf-8") if l.strip()]
except OSError:
    wanted = []
for name in wanted:
    if name.startswith(pkg + ".") or name in deny:
        continue
    allow.append(name)
allow = sorted(set(allow))
deny = sorted(set(deny) - set(allow))
if allow or deny:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<!-- allowlist dari ROM base + izin yang diminta APK (port.sh) -->\n<permissions>\n')
        f.write('    <privapp-permissions package="%s">\n' % pkg)
        for name in allow:
            f.write('        <permission name="%s"/>\n' % name)
        for name in deny:
            f.write('        <deny-permission name="%s"/>\n' % name)
        f.write('    </privapp-permissions>\n</permissions>\n')
    os.chmod(out, 0o644)
print("%d %d" % (len(allow) + len(deny), from_base))
PY
)
    rm -f "$WORK/privapp_req.txt"
    if [[ ${n%% *} -gt 0 ]]; then
        ok "privapp: ${n%% *} izin $pkg (${n##* } dari allowlist base, sisanya dari manifest APK) -> ${out#"$P_FS"/}"
    else
        warn "privapp: $pkg tidak punya izin yang bisa di-allowlist (allowlist base & manifest kosong)"
    fi
}

patch_port_resources() { # base_type base_codename
    local btype=$1 base=$2 item
    DEBLOAT_KEEP=$(debloat_keep)
    if [[ -n $GBOARD_APK ]]; then
        add_gboard
        DEBLOAT_KEEP+=" $GBOARD_DIR ${GBOARD_DIR##*/} $GBOARD_PACKAGE ${GBOARD_PKG_REAL:-}"
    fi
    if [[ -n ${DEBLOAT_KEEP// /} ]]; then log "debloat keep: $DEBLOAT_KEEP"; fi
    for item in $REPLACE_FROM_BASE; do
        case $item in
            overlay)       base_device_overlays "$btype" "$base" ;;
            displayconfig) displayconfig_from_base ;;
            fcm)           fcm_from_base ;;
            *) warn "REPLACE_FROM_BASE: item tidak dikenal '$item' (pilihan: overlay displayconfig fcm)" ;;
        esac
    done
    copy_from_base

    if [[ $DEBLOAT_PRESET == safe ]]; then
        local d freed=0 sz
        # isi semua folder data-app dihapus, kecuali yang ada di DEBLOAT_SAFE_KEEP
        while IFS= read -r -d '' d; do
            if in_list "$(basename "$d")" "$DEBLOAT_SAFE_KEEP" || is_kept "${d#"$P_FS"/}" "$(basename "$d")"; then
                log "debloat (safe): ${d#"$P_FS"/} dipertahankan"; continue
            fi
            sz=$(du -sb "$d" | cut -f1); freed=$(( freed + sz ))
            log "debloat (safe): ${d#"$P_FS"/} ($(( sz / 1048576 )) MB)"
            rm -rf "$d"
        done < <(find "$P_FS" -mindepth 3 -maxdepth 5 -type d -path '*/data-app/*' -prune -print0)
        ok "debloat safe: data-app dihapus, hemat $(( freed / 1048576 )) MB"
    fi

    debloat_packages

    # path (ada '/'), dari debloat_packages.txt dan input debloat, relatif ke root partisi port
    local sz
    while IFS= read -r item; do
        item=${item#/}
        case $item in *..*|"") warn "debloat: path '$item' tidak valid, dilewati"; continue ;; esac
        if [[ -e $P_FS/$item ]]; then
            if is_kept "$item" "$(basename "$item")"; then log "debloat: $item dipertahankan (keep/dilindungi)"; continue; fi
            sz=$(du -sb "$P_FS/$item" | cut -f1)
            rm -rf "${P_FS:?}/$item"; ok "debloat: $item ($(( sz / 1048576 )) MB)"
        else
            log "debloat: $item tidak ada, dilewati"
        fi
    done < <(debloat_tokens | grep -v '^!' | grep '/' | sort -u || true)

    check_ime_left
    report_google
}

# Gboard sebagai aplikasi sistem. Jadi keyboard default kalau keyboard sistem lain
# (Sogou/Baidu) di-debloat: Android memilih IME sistem yang tersisa saat boot pertama.
add_gboard() {
    local src dst="$P_FS/$GBOARD_DIR" name pkg n
    name=${GBOARD_DIR##*/}
    if [[ ! -d $P_FS/${GBOARD_DIR%%/*} ]]; then warn "Gboard: partisi ${GBOARD_DIR%%/*} tidak ada, dilewati"; return 0; fi
    src=$(fetch "$GBOARD_APK" "$WORK/dl" "$name.apk")
    pkg=$(python3 "$SCRIPT_DIR/apk_index.py" --apk "$src")
    [[ -n $pkg ]] || die "GBOARD_APK bukan APK valid (AndroidManifest tidak terbaca)"
    if [[ $pkg != "$GBOARD_PACKAGE" ]]; then
        warn "Gboard: package APK '$pkg', bukan $GBOARD_PACKAGE (tetap dipasang)"
    fi
    GBOARD_PKG_REAL=$pkg
    rm -rf "$dst"; mkdir -p "$dst"
    cp -f "$src" "$dst/$name.apk"
    chmod 0644 "$dst/$name.apk"
    # lib native diekstrak ke lib/arm64 supaya jalan walau lib di APK terkompres
    # (pakai python zipfile: unzip keluar kode 1 pada APK yang punya blok signature v2/v3)
    n=$(python3 - "$src" "$dst" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
abis = {"arm64-v8a": "arm64", "armeabi-v7a": "arm"}
n = 0
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        parts = info.filename.split("/")
        if len(parts) == 3 and parts[0] == "lib" and parts[1] in abis and parts[2].endswith(".so"):
            out = os.path.join(dst, "lib", abis[parts[1]])
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, parts[2]), "wb") as f:
                f.write(z.read(info))
            os.chmod(os.path.join(out, parts[2]), 0o644)
            n += 1
print(n)
PY
)
    log "Gboard: $n library native diekstrak ke $GBOARD_DIR/lib"
    ok "Gboard: $pkg -> $GBOARD_DIR/$name.apk ($(( $(stat -c%s "$src") / 1048576 )) MB)"
}

# info: aplikasi Google yang ada di ROM hasil port (ROM donor CN biasanya tanpa Play Store/GMS lengkap)
report_google() {
    local list core p have=""
    list=$(python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" | awk -F'\t' '$1 ~ /^com\.google\.|^com\.android\.vending$/ {print $1"\t"$2}' | sort -u || true)
    for core in com.google.android.gms com.google.android.gsf com.android.vending; do
        if grep -q "^$core"$'\t' <<< "$list"; then have+=" $core"; fi
    done
    if [[ -n $list ]]; then
        log "Google: aplikasi Google di ROM port:"
        while IFS=$'\t' read -r p d; do printf '    %-45s %s\n' "$p" "$d"; done <<< "$list"
    else
        log "Google: tidak ada aplikasi Google di ROM port"
    fi
    for core in com.google.android.gms com.google.android.gsf com.android.vending; do
        in_list "$core" "$have" || warn "Google: $core tidak ada -> Play Store/login Google perlu dipasang sendiri setelah boot"
    done
}

# peringatan kalau semua keyboard terhapus (setup awal butuh keyboard untuk password Wi-Fi)
IME_PACKAGES="com.android.inputmethod.latin com.google.android.inputmethod.latin com.charlie.android.inputmethod.latin \
com.touchtype.swiftkey org.futo.inputmethod.latin rkr.simplekeyboard.inputmethod com.sohu.inputmethod.sogou.xiaomi \
com.baidu.input_mi com.iflytek.inputmethod.miui"
check_ime_left() {
    local left
    local gb=${GBOARD_PKG_REAL:-$GBOARD_PACKAGE}
    left=$(python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" | cut -f1 | while read -r p; do
        if in_list "$p" "$IME_PACKAGES $gb"; then echo "$p"; fi; done | sort -u | tr '\n' ' ')
    if [[ -n ${left// /} ]]; then
        ok "keyboard tersisa: $left"
        if [[ -n $GBOARD_APK && $(wc -w <<< "$left") -gt 1 ]] && in_list "$gb" "$left"; then
            warn "masih ada keyboard sistem lain selain Gboard ($left). Default saat boot pertama bisa bukan Gboard"
        fi
    else
        warn "TIDAK ADA keyboard tersisa di ROM. Setup awal tidak bisa mengetik password Wi-Fi. Pertahankan LatinIME/Gboard di debloat_packages.txt atau isi GBOARD_APK"
    fi
}

# package yang tidak boleh dihapus walau ada di daftar (bisa bikin bootloop / ROM tidak bisa dipakai)
PROTECTED_PACKAGES="android com.android.systemui com.android.settings com.android.phone com.android.server.telecom \
com.android.providers.settings com.android.providers.telephony com.android.providers.contacts com.android.providers.downloads \
com.android.providers.media.module com.android.shell com.android.externalstorage com.android.documentsui \
com.android.launcher3 com.google.android.apps.nexuslauncher com.android.permissioncontroller com.google.android.permissioncontroller \
com.google.android.webview com.android.webview com.google.android.trichromelibrary \
com.google.android.gms com.google.android.gsf com.android.vending \
com.android.packageinstaller com.google.android.packageinstaller com.android.inputmethod.latin com.google.android.inputmethod.latin \
org.codeaurora.ims org.lineageos.platform org.lineageos.lineagesettings org.lineageos.lineageparts"

# folder APK yang tidak boleh dihapus walau ada di daftar
PROTECTED_APPS="SystemUI Settings SettingsProvider TeleService Telecom TelephonyProvider ContactsProvider DownloadProvider \
PermissionController GooglePermissionController Launcher3 Launcher3QuickStep NexusLauncherRelease TrebuchetQuickStep \
GmsCore PrebuiltGmsCore PrebuiltGmsCoreSc Phonesky GoogleServicesFramework WebViewGoogle WebViewGoogle64 webview \
TrichromeLibrary TrichromeWebView Shell ExternalStorageProvider DocumentsUI DocumentsUIGoogle \
PackageInstaller GooglePackageInstaller framework-res LatinIME LatinIMEGooglePrebuilt ims \
LineageSettingsProvider LineageParts"

# token daftar debloat: pisah koma / baris / spasi; label setelah '|' atau '#' dibuang
debloat_tokens() {
    { if [[ -f $DEBLOAT_PACKAGES_FILE ]]; then cat "$DEBLOAT_PACKAGES_FILE"; fi; printf '\n%s\n' "$DEBLOAT"; } \
        | sed -e 's/#.*//' | tr ',' '\n' | sed -e 's/|.*//' | tr -s '[:space:]' '\n' | grep -v '^$' || true
}

# daftar keep: token berawalan '!' di debloat_packages.txt / input debloat (package, folder, atau path)
debloat_keep() { debloat_tokens | grep '^!' | sed 's/^!//' | sort -u | tr '\n' ' ' || true; }

is_kept() { # nilai... -> 0 kalau salah satu ada di keep list / proteksi bawaan
    local v
    for v in "$@"; do
        [[ -n $v ]] || continue
        if in_list "$v" "$DEBLOAT_KEEP $PROTECTED_APPS $PROTECTED_PACKAGES"; then return 0; fi
    done
    return 1
}

# debloat berdasarkan nama package (com.xxx) dan nama folder APK (MiuiCompass).
# Yang tidak ada di ROM dilewati, build tidak dibatalkan.
debloat_packages() {
    local toks pkgs apps idx="$WORK/apk_index.tsv" pkg app dir d sz freed=0 hit=0 miss=""
    toks=$(debloat_tokens | grep -v '^!' || true)
    pkgs=$(grep -E '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$' <<< "$toks" | sort -u | tr '\n' ' ' || true)
    apps=$(grep -E '^[A-Za-z][A-Za-z0-9_-]*$' <<< "$toks" | sort -u | tr '\n' ' ' || true)
    [[ -n ${pkgs// /}${apps// /} ]] || return 0
    log "debloat: $(wc -w <<< "$pkgs") nama package + $(wc -w <<< "$apps") nama folder APK"

    # --- nama package
    if [[ -n ${pkgs// /} ]]; then
        python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" > "$idx"
        log "  $(wc -l < "$idx") APK terindeks di ROM port"
        for pkg in $pkgs; do
            dir=$(awk -F'\t' -v p="$pkg" '$1 == p {print $2; exit}' "$idx")
            if is_kept "$pkg" "$dir" "${dir##*/}"; then log "debloat: $pkg dipertahankan (keep/dilindungi)"; continue; fi
            if [[ -z $dir || ! -d $P_FS/$dir ]]; then miss+=" $pkg"; continue; fi
            sz=$(du -sb "$P_FS/$dir" | cut -f1); freed=$(( freed + sz )); hit=$((hit + 1))
            rm -rf "${P_FS:?}/$dir"
            ok "debloat: $pkg -> $dir ($(( sz / 1048576 )) MB)"
        done
    fi

    # --- nama folder APK (di app/, priv-app/, data-app/ semua partisi port)
    for app in $apps; do
        if is_kept "$app"; then log "debloat: $app dipertahankan (keep/dilindungi)"; continue; fi
        local found=0
        while IFS= read -r -d '' d; do
            sz=$(du -sb "$d" | cut -f1); freed=$(( freed + sz )); hit=$((hit + 1)); found=1
            rm -rf "$d"
            ok "debloat: $app -> ${d#"$P_FS"/} ($(( sz / 1048576 )) MB)"
        done < <(find "$P_FS" -mindepth 3 -maxdepth 6 -type d \
                    \( -path "*/app/$app" -o -path "*/priv-app/$app" -o -path "*/data-app/$app" \) -prune -print0)
        if [[ $found == 0 ]]; then miss+=" $app"; fi
    done

    ok "debloat: $hit dihapus, hemat $(( freed / 1048576 )) MB"
    if [[ -n $miss ]]; then log "  tidak ada di ROM (dilewati):$miss"; fi
}

report_app_sizes() { # 25 aplikasi terbesar di partisi port (bahan debloat manual)
    log "25 aplikasi/folder terbesar di ROM port (untuk input debloat):"
    local rep="$WORK/app_sizes.txt"
    find "$P_FS" -mindepth 2 -maxdepth 5 -type d \( -path '*/app/*' -o -path '*/priv-app/*' -o -path '*/data-app/*' \) \
        -prune -print0 2>/dev/null | xargs -0 -r du -sm 2>/dev/null > "$rep.raw" || true
    sort -rn "$rep.raw" > "$rep" || true
    local n=0 sz d
    while read -r sz d; do
        n=$((n + 1)); [[ $n -le 25 ]] || break
        printf '    %6s MB  %s\n' "$sz" "${d#"$P_FS"/}"
    done < "$rep"
}

# file tambahan dari repo: devices/<device>/<partisi>/... ditimpa ke hasil ekstrak
apply_device_files() {
    local dir=$DEVICE_FILES_DIR part root n
    if [[ ! -d $dir ]]; then log "devices: $dir tidak ada, dilewati"; return 0; fi
    for part in system system_ext product mi_ext vendor odm; do
        [[ -d $dir/$part ]] || continue
        case $part in vendor|odm) root=$B_FS ;; *) root=$P_FS ;; esac
        if [[ ! -d $root/$part ]]; then warn "devices: $part tidak diekstrak, $dir/$part dilewati"; continue; fi
        n=$(find "$dir/$part" -type f ! -name '.gitkeep' ! -name 'README*' | wc -l)
        [[ $n -gt 0 ]] || continue
        (cd "$dir/$part" && find . -type f ! -name '.gitkeep' ! -name 'README*' -print0 | \
            while IFS= read -r -d '' f; do
                mkdir -p "$root/$part/$(dirname "$f")"
                cp -f "$f" "$root/$part/$f"
            done)
        ok "devices: $n file ditimpa ke $part"
    done
}

# ------------------------------------------------------------------ patch: vendor
# FSTAB_FLAGS: string argumen fstab_patch.py (list pakai koma, sengaja word-split)
build_fstab_flags() {
    FSTAB_FLAGS=""
    if is_true "$DISABLE_AVB"; then FSTAB_FLAGS+=" --no-avb"; fi
    if is_true "$DISABLE_ENCRYPTION"; then FSTAB_FLAGS+=" --no-encrypt"; fi
    FSTAB_FLAGS+=" --ext4=${EXT4_PARTITIONS// /,}"
    # semua partisi yang dibangun ulang bisa jadi EROFS (port selalu; vendor/odm kalau fit_super
    # menurunkannya ke EROFS) -> fstab wajib punya baris erofs untuk semuanya
    local erofs_parts
    # shellcheck disable=SC2086  # daftar partisi sengaja di-split
    erofs_parts=$(printf '%s\n' $PORT_PARTITIONS vendor odm | awk '!s[$0]++' | tr '\n' ',')
    FSTAB_FLAGS+=" --erofs=${erofs_parts%,}"
    if is_true "$RW_MOUNT"; then
        # rw HANYA untuk partisi yang dibangun ulang di sini (repack_ext4 rw = tanpa shared_blocks).
        # Image base yang dipakai apa adanya (vendor_dlkm, ...) bisa ext4 shared_blocks /
        # tanpa ruang: kernel menolak mount rw -> first-stage mount gagal = bootloop
        local p rw_parts="" asis=""
        for p in $EXT4_PARTITIONS; do
            # shellcheck disable=SC2086
            if in_list "$p" $PORT_PARTITIONS vendor odm; then rw_parts+="$p,"; else asis+="$p "; fi
        done
        if [[ -n $rw_parts ]]; then FSTAB_FLAGS+=" --rw=${rw_parts%,}"; fi
        if [[ -n $asis ]]; then
            log "rw: ${asis% } dipakai dari base apa adanya (tidak dibangun ulang) -> tetap read-only di fstab"
        fi
    fi
}

patch_fstab_file() {
    # shellcheck disable=SC2086
    python3 "$SCRIPT_DIR/fstab_patch.py" "$1" $FSTAB_FLAGS
}

patch_vendor_fstab() {
    local f found=0
    while IFS= read -r -d '' f; do
        log "fstab vendor: ${f#"$B_FS"/}"
        patch_fstab_file "$f"; found=1
    done < <(if [[ -d $B_FS/vendor/etc ]]; then find "$B_FS/vendor/etc" -maxdepth 1 -type f -name 'fstab.*' -print0; fi)
    if [[ $found != 1 ]]; then
        warn "fstab di vendor/etc tidak ditemukan"
    fi
}

patch_vendor_boot() {
    # first-stage fstab (dipakai init untuk mount system/vendor/odm) ada di vendor ramdisk.
    # vendor_boot v4 LineageOS/AxionOS punya beberapa fragmen (platform + dlkm): dipatch per
    # fragmen oleh vendor_boot_fstab.py, tabel fragmen ikut diperbarui (magiskboot toolkit
    # merusak tabel ini -> modul dlkm hilang -> bootloop).
    local img="$B_IMG/vendor_boot.img" lg="$WORK/vendor_boot_fstab.log" rc=0
    [[ -f $img ]] || { warn "vendor_boot.img tidak ada, first-stage fstab tidak dipatch"; return 0; }
    command -v lz4 >/dev/null || die "lz4 tidak ada (dibutuhkan untuk vendor ramdisk lz4): apt install lz4"
    rm -f "$WORK/vendor_boot_recovery"
    # shellcheck disable=SC2086  # FSTAB_FLAGS sengaja di-split
    python3 "$SCRIPT_DIR/vendor_boot_fstab.py" "$img" -- $FSTAB_FLAGS > "$lg" 2>&1 || rc=$?
    while IFS= read -r line; do
        case $line in
            RECOVERY_FRAGMENT*) echo "${line#RECOVERY_FRAGMENT }" > "$WORK/vendor_boot_recovery" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$lg"
    case $rc in
        0) ok "vendor_boot: first-stage fstab dipatch (tabel fragmen konsisten)" ;;
        4) warn "tidak ada fstab di vendor_boot ramdisk: first-stage fstab mungkin di boot ramdisk/dtb, pastikan tipe fs system/vendor/odm cocok" ;;
        *) die "patch vendor_boot gagal (rc=$rc). Tanpa ini fstab first-stage tidak cocok dengan partisi yang dibangun ulang -> bootloop. Lihat log di atas" ;;
    esac
}

vendor_boot_recovery_warn() {
    if [[ -f $WORK/vendor_boot_recovery ]]; then
        warn "vendor_boot base berisi ramdisk recovery ($(cat "$WORK/vendor_boot_recovery")) -> flash zip ini MENGGANTI recovery (OrangeFox) dengan recovery ROM base. Flash ulang OrangeFox setelahnya kalau perlu"
    fi
}

patch_vbmeta() {
    local v
    is_true "$DISABLE_AVB" || return 0
    for v in vbmeta vbmeta_system vbmeta_vendor; do
        [[ -f $B_IMG/$v.img ]] || continue
        python3 "$PYBIN/patch-vbmeta.py" "$B_IMG/$v.img" >/dev/null
        ok "$v: flag disable-verity+verification di-set"
    done
}

# ------------------------------------------------------------------ super
resolve_super() { # set SUPER_SIZE (angka), SUPER_GROUP, SUPER_GMAX
    [[ -z ${SUPER_GMAX:-} ]] || return 0
    if [[ $SUPER_SIZE == auto ]]; then
        if [[ -n ${LP_SUPER_SIZE:-} && $LP_SUPER_SIZE -gt 0 ]]; then
            SUPER_SIZE=$LP_SUPER_SIZE
            log "super_size dari super.img base: $SUPER_SIZE"
        elif [[ -n ${PAYLOAD_DYN_GROUPS:-} ]]; then
            # Xiaomi VAB: group qti_dynamic_partitions = super - 4 MiB
            local g0=${PAYLOAD_DYN_GROUPS%% *}
            SUPER_SIZE=$(( ${g0##*:} + 4194304 ))
            warn "super_size diturunkan dari payload (group ${g0##*:} + 4 MiB) = $SUPER_SIZE. Installer akan membatalkan flash kalau tidak sama dengan partisi super HP."
        else
            die "SUPER_SIZE=auto tapi ukuran tidak bisa dibaca dari base. Isi super_size manual: adb shell su -c 'blockdev --getsize64 /dev/block/by-name/super'"
        fi
    fi
    [[ $SUPER_SIZE =~ ^[0-9]+$ ]] || die "super_size harus angka byte, bukan '$SUPER_SIZE'"

    if [[ -n ${LP_GROUPS:-} ]]; then
        SUPER_GROUP=${LP_GROUPS%% *}; SUPER_GROUP=${SUPER_GROUP%:*}; SUPER_GROUP=${SUPER_GROUP%_a}
    elif [[ -n ${PAYLOAD_DYN_GROUPS:-} ]]; then
        SUPER_GROUP=${PAYLOAD_DYN_GROUPS%% *}; SUPER_GROUP=${SUPER_GROUP%:*}
    else
        SUPER_GROUP=qti_dynamic_partitions
    fi
    # metadata super ditulis ulang total, jadi batas group = ukuran super - 4 MiB
    # (group bawaan ROM base bisa lebih kecil, mis. xiaomi.eu 8 GiB)
    SUPER_GMAX=$(( SUPER_SIZE - 4194304 ))

}

sum_images() { # total byte semua image di OUT_IMG_TMP
    local t=0 f
    for f in "$OUT_IMG_TMP"/*.img; do [[ -f $f ]] && t=$(( t + $(stat -c%s "$f") )); done
    echo "$t"
}

# kalau tidak muat di super: vendor/odm EXT4 dibangun ulang sebagai EROFS (lebih kecil)
fit_super() {
    local total p new="" sz cand=() root
    resolve_super
    total=$(sum_images)
    log "cek muat: $(( total / 1048576 )) MB / $(( SUPER_GMAX / 1048576 )) MB"
    [[ $total -gt $SUPER_GMAX ]] || return 0
    if ! is_true "$FIT_FALLBACK_EROFS"; then return 0; fi
    # partisi EXT4 terbesar dulu dibangun ulang sebagai EROFS, berhenti begitu muat
    for p in $EXT4_PARTITIONS; do
        sz=$(stat -c%s "$OUT_IMG_TMP/$p.img" 2>/dev/null || echo 0)
        cand+=("$sz $p")
    done
    while read -r sz p; do
        [[ -n $p ]] || continue
        if [[ $total -le $SUPER_GMAX ]]; then new+="${new:+ }$p"; continue; fi
        case $p in vendor|odm) root=$B_FS ;; *) root=$P_FS ;; esac
        if [[ -d $root/$p ]]; then
            warn "super tidak muat: $p ($(( sz / 1048576 )) MB) dibangun ulang sebagai EROFS (read-only, tidak bisa rw)"
            repack_erofs "$root" "$p" "$OUT_IMG_TMP/$p.img"
            total=$(sum_images)
        else
            new+="${new:+ }$p"
        fi
    done < <(printf '%s\n' "${cand[@]}" | sort -rn)
    EXT4_PARTITIONS=$new
    log "setelah fallback EROFS: $(( total / 1048576 )) MB / $(( SUPER_GMAX / 1048576 )) MB (masih EXT4: ${EXT4_PARTITIONS:-tidak ada})"
}

build_super() {
    local parts=$1 out=$2 total=0 p img sz attr grp gmax meta slots args=()
    meta=${LP_METADATA_MAX:-65536}
    slots=3

    resolve_super
    grp=$SUPER_GROUP; gmax=$SUPER_GMAX
    log "super: size=$SUPER_SIZE group=${grp}_a/_b max=$gmax"
    args=(--metadata-size "$meta" --super-name super --metadata-slots "$slots"
          --device "super:$SUPER_SIZE"
          --group "${grp}_a:$gmax" --group "${grp}_b:$gmax")
    # Virtual A/B (ingres: ya). Dimatikan hanya kalau base jelas bukan VAB.
    if [[ ${LP_VIRTUAL_AB:-${PAYLOAD_SNAPSHOT:-1}} != 0 ]]; then args+=(--virtual-ab); else warn "base bukan Virtual A/B"; fi
    for p in $parts; do
        img="$OUT_IMG_TMP/$p.img"
        [[ -f $img ]] || continue
        sz=$(stat -c%s "$img")
        total=$(( total + sz ))
        attr="readonly"
        if in_list "$p" "$EXT4_PARTITIONS" && is_true "$RW_MOUNT"; then attr=none; fi
        printf '  %-14s %12d bytes  (%s)\n' "$p" "$sz" "$attr"
        args+=(--partition "${p}_a:$attr:$sz:${grp}_a" --image "${p}_a=$img"
               --partition "${p}_b:$attr:0:${grp}_b")
    done
    printf '  %-14s %12d / %d bytes (%d%%)\n' TOTAL "$total" "$gmax" $(( total * 100 / gmax ))
    [[ $total -le $gmax ]] || die "partisi melebihi kapasitas super ($(( total / 1048576 )) MB > $(( gmax / 1048576 )) MB). Tambah path di input debloat (lihat daftar '25 aplikasi terbesar' di tahap 4) atau kosongkan ext4_partitions."
    # installer kita menulis super pakai dd -> raw; installer base (xiaomi.eu) memakai sparse
    if [[ ${SUPER_SPARSE:-false} == true ]]; then args+=(--sparse); fi
    if ! lpmake "${args[@]}" --output "$out" >"$WORK/lpmake.log" 2>&1; then
        tail -n 30 "$WORK/lpmake.log" >&2; die "lpmake gagal"
    fi
    ok "super.img dibuat ($(du -h "$out" | cut -f1))"
}

# ------------------------------------------------------------------ boot custom
replace_boot() { # path boot.img base di paket
    local dst=$1 src magic ssz dsz hv
    src=$(fetch "$BOOT_IMG" "$WORK/dl" boot_custom.img)
    magic=$(head -c 8 "$src" | od -An -c | tr -d ' ')
    [[ $magic == "ANDROID!" ]] || die "BOOT_IMG bukan boot image Android (8 byte awal: $(head -c 8 "$src" | od -An -tx1 | tr -d '\n'))"
    ssz=$(stat -c%s "$src")
    if [[ -f $dst ]]; then
        dsz=$(stat -c%s "$dst")
        if [[ $ssz -gt $dsz ]]; then
            die "boot.img custom ($ssz byte) lebih besar dari boot.img base ($dsz byte = ukuran partisi)"
        fi
    fi
    hv=$(od -An -tu4 -j40 -N4 "$src" | tr -d ' ')
    if [[ -f $dst ]]; then boot_compat "$dst" "$src"; fi
    cp -f "$src" "$dst"
    ok "boot.img diganti: ${BOOT_IMG##*/} ($(( ssz / 1048576 )) MB, header v$hv)"
}

boot_ramdisk_size() { # boot.img -> ukuran ramdisk (byte) dari header
    local hv off
    hv=$(od -An -tu4 -j40 -N4 "$1" | tr -d ' ')
    if [[ $hv -ge 3 ]]; then off=12; else off=16; fi
    od -An -tu4 -j"$off" -N4 "$1" | tr -d ' '
}

boot_kver() { # boot.img -> "5.10.xxx-android12-9-..." (kosong kalau tidak terbaca)
    local d img
    img=$(realpath "$1")
    d=$(mktemp -d "$WORK/kv.XXXX")
    (cd "$d" && magiskboot unpack "$img" >/dev/null 2>&1) || true
    if [[ -f $d/kernel ]]; then
        strings -a "$d/kernel" | grep -m1 -oE 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^ ]*' | sed 's/^Linux version //' || true
    fi
    rm -rf "$d"
}

# boot.img custom harus punya ramdisk (first-stage init, ingres rilis Android 12 = tanpa init_boot) dan
# versi kernel mayor.minor sama dengan base: modul kernel di vendor_boot & vendor_dlkm
# dibuat untuk kernel base. Beda -> modul gagal load / tidak ada init -> bootloop.
boot_compat() { # base.img custom.img
    local base=$1 new=$2 rb rn kb kn
    rb=$(boot_ramdisk_size "$base"); rn=$(boot_ramdisk_size "$new")
    if [[ ${rb:-0} -gt 0 && ${rn:-0} -eq 0 ]]; then
        die "boot.img custom TIDAK punya ramdisk (base punya ${rb} byte). ingres tidak punya init_boot, jadi first-stage init ada di ramdisk boot -> pasti bootloop. Pakai boot.img lengkap, bukan kernel-only"
    fi
    log "boot: ramdisk base ${rb:-?} byte, custom ${rn:-?} byte"
    kb=$(boot_kver "$base"); kn=$(boot_kver "$new")
    log "boot: kernel base   ${kb:-tidak terbaca}"
    log "boot: kernel custom ${kn:-tidak terbaca}"
    if [[ -n $kb && -n $kn ]]; then
        if [[ $(cut -d. -f1,2 <<< "$kb") != "$(cut -d. -f1,2 <<< "$kn")" ]]; then
            die "versi kernel custom (${kn%%-*}) beda seri dengan base (${kb%%-*}). Modul di vendor_boot/vendor_dlkm tidak akan load -> bootloop"
        fi
        if [[ ${kb%%-*} != "${kn%%-*}" ]]; then
            warn "sublevel kernel beda (base ${kb%%-*}, custom ${kn%%-*}). GKI biasanya tetap load modul vendor, tapi kalau layar/touch mati setelah boot, cek dmesg 'disagrees about version'"
        elif [[ $kb != "$kn" ]]; then
            warn "build kernel beda (base $kb, custom $kn). Modul di vendor_boot (dlkm) & vendor_dlkm dibuat untuk kernel base: kalau CRC simbol beda, modul gagal load (layar/touch/wifi mati). Cek dmesg 'disagrees about version' / 'Unknown symbol'"
        else
            ok "boot: kernel custom sama persis dengan kernel base ($kn)"
        fi
    else
        warn "versi kernel tidak bisa dibaca dari salah satu boot.img, kecocokan kernel tidak dicek"
    fi
}

# ------------------------------------------------------------------ installer base (xiaomi.eu)
installer_mode() { # -> base | ours
    case $INSTALLER in
        base) [[ -d $WORK/base_META-INF ]] || die "INSTALLER=base tapi ROM base tidak punya META-INF"; echo base ;;
        ours) echo ours ;;
        *)    if [[ -d $WORK/base_META-INF ]]; then echo base; else echo ours; fi ;;
    esac
}

# samakan bentuk super dengan ROM base: images/super.img.0..N (sparse) / super.img / .zst
match_super_layout() { # pkg
    local pkg=$1 sup="$1/images/super.img" first n prefix f
    [[ -n ${SUPER_LAYOUT:-} ]] || { warn "layout super base tidak diketahui, super.img sparse tunggal"; return 0; }
    read -r -a SL <<< "$SUPER_LAYOUT"
    first=${SL[0]}; n=${#SL[@]}
    log "layout super base: ${SUPER_LAYOUT}"
    if [[ $n -gt 1 && $first =~ ^(.+)\.0$ ]]; then
        prefix=${BASH_REMATCH[1]}
        for f in "${SL[@]}"; do
            [[ $f == "$prefix".* ]] || die "layout super base tidak dikenal: $SUPER_LAYOUT"
        done
        mkdir -p "$pkg/$(dirname "$prefix")"
        python3 "$SCRIPT_DIR/sparse_split.py" "$sup" "$pkg/$prefix" "$n" >/dev/null
        rm -f "$sup"
        ok "super dipecah jadi $n potongan sparse: $prefix.0 .. $prefix.$((n - 1))"
    elif [[ $n -eq 1 && ${SUPER_LAYOUT_MAGIC:-} == 28b52ffd ]]; then
        mkdir -p "$pkg/$(dirname "$first")"
        zstd -q -T0 -"${ZSTD_LEVEL:-3}" --rm "$sup" -o "$pkg/$first"
        ok "super dikompres zstd: $first"
    elif [[ $n -eq 1 ]]; then
        if [[ $first != images/super.img ]]; then mkdir -p "$pkg/$(dirname "$first")"; mv -f "$sup" "$pkg/$first"; fi
        ok "super sparse tunggal: $first"
    fi
}

# hapus perintah flash recovery.img dari installer base (recovery HP dipertahankan)
strip_recovery_refs() { # pkg
    local pkg=$1 f changed
    for f in "$pkg/META-INF/com/google/android/updater-script" "$pkg/META-INF/com/google/android/update-binary"; do
        [[ -f $f ]] || continue
        grep -q 'recovery\.img' "$f" 2>/dev/null || continue
        if ! grep -Iq . "$f"; then
            die "$(basename "$f") (biner) merujuk recovery.img dan tidak bisa diedit. Isi RECOVERY_IMG atau pakai INSTALLER=ours"
        fi
        changed=$(python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="surrogateescape").read()
n = 0
# edify: package_extract_file("...recovery.img", "...") -> ui_print (ekspresi tetap valid di dalam ifelse)
s, k = re.subn(r'package_extract_file\(\s*"[^"]*recovery\.img"\s*,\s*"[^"]*"\s*\)',
               'ui_print("- recovery dilewati (recovery HP dipertahankan)")', s)
n += k
# shell: baris yang memakai recovery.img -> no-op
out = []
for line in s.split("\n"):
    if "recovery.img" in line and "ui_print(" not in line:
        out.append(": # recovery.img dilewati (recovery HP dipertahankan)")
        n += 1
    else:
        out.append(line)
open(p, "w", encoding="utf-8", errors="surrogateescape").write("\n".join(out))
print(n)
PY
)
        ok "installer: $changed perintah flash recovery.img dihapus dari $(basename "$f")"
    done
}

# jaminan: META-INF cuma flash. Perintah format / wipe / hapus data dinetralkan,
# build gagal kalau masih ada yang tersisa.
installer_no_wipe() { # pkg
    local pkg=$1 res fixed left line
    python3 "$SCRIPT_DIR/installer_sanitize.py" "$pkg/META-INF" > "$WORK/installer_sanitize.log"
    while IFS= read -r line; do
        case $line in RESULT*) ;; *) printf '    %s\n' "$line" ;; esac
    done < "$WORK/installer_sanitize.log"
    res=$(sed -n 's/^RESULT //p' "$WORK/installer_sanitize.log" | tail -n1)
    fixed=${res%% *}; left=${res##* }
    if [[ ! ${fixed:-x} =~ ^[0-9]+$ || ! ${left:-x} =~ ^[0-9]+$ ]]; then die "installer: cek hapus-data gagal dijalankan"; fi
    if (( left > 0 )); then die "installer: masih ada $left perintah hapus/format data di META-INF (lihat LEFT di atas)"; fi
    if (( fixed > 0 )); then
        ok "installer: $fixed perintah hapus/format data dinetralkan -> zip cuma flash, data tidak disentuh"
    else
        ok "installer: tidak ada perintah format/wipe/hapus data -> zip cuma flash, data tidak disentuh"
    fi
}

# pakai META-INF ROM base apa adanya, lalu cek semua file yang dirujuk installer ada di paket
apply_base_installer() { # pkg
    local pkg=$1 ref missing="" unref="" f n=0
    local us="$pkg/META-INF/com/google/android/updater-script" ub="$pkg/META-INF/com/google/android/update-binary"
    log "installer: META-INF dari ROM base ($( { file -b "$ub" 2>/dev/null || echo "?"; } | cut -c1-60))"
    if [[ -f $us ]] && grep -qiE 'sha1_check|sha256|apply_patch|block_image_verify' "$us"; then
        warn "updater-script base mengecek hash/patch - file yang diubah (super, boot, vbmeta) bisa ditolak installer"
    fi
    if [[ -f $us ]]; then
        local other
        other=$(grep -nvE '^[[:space:]]*(#|$)|package_extract_file|ui_print|show_progress|set_progress' "$us" || true)
        if [[ -n $other ]]; then
            log "installer: perintah selain flash image:"
            while IFS= read -r f; do printf '    %s\n' "$f"; done <<< "$other"
        fi
    fi
    # file yang dirujuk (teks updater-script + string di update-binary)
    ref=$( { [[ -f $us ]] && cat "$us"; strings -n 6 "$ub" 2>/dev/null; } \
        | grep -oE '(images|firmware-update)/[A-Za-z0-9_.+-]+' | sort -u || true)
    for f in $ref; do
        n=$((n + 1))
        if [[ ! -e $pkg/$f ]]; then
            # file ada tapi di folder lain -> pindahkan ke path yang dirujuk
            if [[ -e $pkg/images/${f##*/} ]]; then
                mkdir -p "$pkg/$(dirname "$f")"; mv -f "$pkg/images/${f##*/}" "$pkg/$f"
            else
                missing+=" $f"
            fi
        fi
    done
    for f in "$pkg"/images/*; do
        [[ -e $f ]] || continue
        if ! grep -qx "images/${f##*/}" <<< "$ref"; then unref+=" ${f##*/}"; fi
    done
    log "installer merujuk $n file"
    if [[ -n $unref ]]; then log "  tidak dirujuk installer (tidak di-flash):$unref"; fi
    if [[ -n $missing ]]; then
        die "installer base merujuk file yang tidak ada di paket:$missing"
    fi
    ok "installer base: semua file yang dirujuk ada"
}

# image base yang ikut di-flash: tanpa partisi kalibrasi/data (NEVER_FLASH), dan untuk fastboot ROM
# Xiaomi hanya yang memang di-flash flash_all.sh (persist.img dll di folder images tidak pernah di-flash).
prune_base_images() {
    local f p keep_always="boot vendor_boot dtbo vbmeta vbmeta_system recovery init_boot"
    for f in "$B_IMG"/*.img; do
        [[ -f $f ]] || continue
        p=$(basename "$f" .img)
        if in_list "$p" "$NEVER_FLASH"; then
            rm -f "$f"; log "tidak di-flash: $p.img (NEVER_FLASH)"; continue
        fi
        if [[ -n ${FLASHALL_PARTS:-} ]] && ! in_list "$p" "$FLASHALL_PARTS $keep_always"; then
            rm -f "$f"; log "tidak di-flash: $p.img (tidak ada di flash_all.sh base)"
        fi
    done
}

# ------------------------------------------------------------------ recovery zip
# write_recovery_pkg <pkg_dir> <port_ver> <rom_name>
#   isi zip: META-INF/com/google/android/{update-binary,updater-script}
#            images/*.img (+ super.img / super.img.zst), META-INF/zstd (mode zst)
write_recovery_pkg() {
    local dir=$1 ver=$2 rname=${3:-AOSP} f p ab=() nonab="cust rescue" late="boot init_boot vendor_boot dtbo recovery vbmeta_system vbmeta" ub
    for f in "$dir"/images/*.img; do
        p=$(basename "$f" .img)
        if [[ $p == super ]] || in_list "$p" "$late $nonab"; then continue; fi
        ab+=("$p")
    done
    for p in $late; do
        if [[ -f $dir/images/$p.img ]]; then ab+=("$p"); fi
    done
    local nonab_found=""
    for p in $nonab; do
        if [[ -f $dir/images/$p.img ]]; then nonab_found+="${nonab_found:+ }$p"; fi
    done

    local flash_rec=false
    if [[ -n $RECOVERY_IMG ]]; then flash_rec=true; fi

    mkdir -p "$dir/META-INF/com/google/android"
    ub="$dir/META-INF/com/google/android/update-binary"
    sed -e "s|@TARGET_DEVICE@|$TARGET_DEVICE|g" \
        -e "s|@PORT_VERSION@|$ver|g" \
        -e "s|@PORT_NAME@|$rname|g" \
        -e "s|@ANTI_VER@|${ANTI_VER:-}|g" \
        -e "s|@SUPER_FORMAT@|$RECOVERY_SUPER|g" \
        -e "s|@SUPER_BYTES@|$SUPER_SIZE|g" \
        -e "s|@FLASH_RECOVERY@|$flash_rec|g" \
        -e "s|@AB_IMAGES@|${ab[*]}|g" \
        -e "s|@NONAB_IMAGES@|$nonab_found|g" \
        "$SCRIPT_DIR/update-binary.in" > "$ub"
    if grep -q '@[A-Z_]*@' "$ub"; then die "placeholder update-binary belum terisi"; fi
    chmod 0755 "$ub"
    echo '# dummy - instalasi dijalankan oleh update-binary (shell)' \
        > "$dir/META-INF/com/google/android/updater-script"

    if [[ $RECOVERY_SUPER == zst ]]; then
        [[ -f $TOOLS_DIR/bin/flash/zstd ]] || die "zstd arm64 (bin/flash/zstd) tidak ada di toolkit"
        cp "$TOOLS_DIR/bin/flash/zstd" "$dir/META-INF/zstd"
        chmod 0755 "$dir/META-INF/zstd"
    fi
    log "slot A+B : ${ab[*]}"
    log "non-AB   : ${nonab_found:-(tidak ada)}"
    log "recovery : $( [[ $flash_rec == true ]] && echo "diganti (RECOVERY_IMG)" || echo "tidak di-flash (recovery HP dipertahankan)")"
}

# recovery.img custom (TWRP/OrangeFox) menggantikan recovery base. Dicek: image boot Android
# (magic ANDROID!) dan tidak lebih besar dari partisi recovery (= recovery.img base).
put_recovery() { # dest (berisi recovery.img base kalau ada)
    local dest=$1 rec magic sz max=""
    rec=$(fetch "$RECOVERY_IMG" "$WORK/dl" recovery_custom.img)
    magic=$(head -c 8 "$rec" | tr -d '\0')
    [[ $magic == "ANDROID!" ]] || die "recovery custom bukan image boot Android (magic '$magic'): $RECOVERY_IMG"
    sz=$(stat -c%s "$rec")
    if [[ -f $dest ]]; then max=$(stat -c%s "$dest"); fi
    if [[ -n $max ]] && (( sz > max )); then
        die "recovery custom ($sz byte) lebih besar dari partisi recovery ($max byte)"
    fi
    cp -f "$rec" "$dest"
    ok "recovery diganti: $(basename "$RECOVERY_IMG") ($(( sz / 1048576 )) MB, header v$(od -An -tu4 -j40 -N4 "$rec" | tr -d ' '))"
}

# ================================================================== OTA A/B
# Data yang hanya ada sebelum folder port dihapus (tahap 5): apex_info.pb + identitas build.
ota_prepare() {
    local d dirs=() bp="$P_FS/system/system/build.prop"
    for d in "$P_FS/system/system/apex" "$P_FS/system_ext/apex" "$P_FS/product/apex"; do
        if [[ -d $d ]]; then dirs+=("$d"); fi
    done
    if [[ ${#dirs[@]} -gt 0 ]]; then
        python3 "$SCRIPT_DIR/make_ota.py" apex-info --out "$WORK/apex_info.pb" "${dirs[@]}" | sed 's/^/  /' || rm -f "$WORK/apex_info.pb"
    fi
    OTA_FINGERPRINT=$(get_prop "$bp" ro.system.build.fingerprint)
    OTA_FINGERPRINT=${OTA_FINGERPRINT:-$(get_prop "$bp" ro.build.fingerprint)}
    OTA_INCREMENTAL=$(get_prop "$bp" ro.build.version.incremental)
    OTA_SPL=$(get_prop "$bp" ro.build.version.security_patch)
    OTA_SDK=$(get_prop "$bp" ro.build.version.sdk)
    log "OTA: fingerprint ${OTA_FINGERPRINT:-?}, SPL ${OTA_SPL:-?}, SDK ${OTA_SDK:-?}"
}

ota_info_file() { # file port_ver port_name donor btype
    {
        echo "device=$TARGET_DEVICE"; echo "donor=$4"; echo "rom=$3"; echo "port_version=$2"
        echo "base_type=$5"; echo "port_partitions=$PORT_PARTITIONS"; echo "ext4_partitions=$EXT4_PARTITIONS"
        echo "disable_encryption=$DISABLE_ENCRYPTION"; echo "rw_mount=$RW_MOUNT"
        echo "disable_avb=$DISABLE_AVB"; echo "debug_adb=$DEBUG_ADB"; echo "package_type=$PACKAGE_TYPE"
        echo "boot_img=${BOOT_IMG:-base}"; echo "anti_ver=${ANTI_VER:-unknown}"; echo "build_date=$(date +%Y%m%d)"
    } > "$1"
}

package_ota() { # "partisi logical" name port_ver port_name donor btype
    local logical_parts=$1 name=$2 imgd="$WORK/ota_images" args=() f p dyn="" gname gsize kd="$WORK/aosp_testkey"
    prune_base_images
    mkdir -p "$imgd"
    mv "$B_IMG"/* "$imgd/" 2>/dev/null || true
    rm -f "$imgd/super.img"
    if [[ -n $RECOVERY_IMG ]]; then
        put_recovery "$imgd/recovery.img"
        log "recovery custom ikut di payload -> ditulis ke slot tujuan OTA"
    else
        rm -f "$imgd/recovery.img"
        log "recovery tidak dimasukkan ke payload (recovery di HP tidak ditimpa)"
    fi
    if [[ -n $BOOT_IMG ]]; then replace_boot "$imgd/boot.img"; fi
    if [[ -n ${ANTI_VER:-} ]]; then
        warn "ROM base membawa firmware (anti-rollback $ANTI_VER) yang ikut di payload: pastikan 'fastboot getvar anti' HP <= $ANTI_VER"
    fi

    # partisi non-dinamis (boot, vendor_boot, dtbo, vbmeta, firmware) + partisi logical
    for f in "$imgd"/*.img; do
        [[ -f $f ]] || continue
        p=$(basename "$f" .img)
        case $p in
            cust|rescue|persist*|misc|userdata|metadata|cache|super)
                warn "OTA: $p bukan partisi A/B, tidak bisa masuk payload (dilewati)"; continue ;;
        esac
        args+=(--partition "$p=$f")
    done
    for p in $logical_parts; do
        f="$OUT_IMG_TMP/$p.img"
        [[ -f $f ]] || continue
        args+=(--partition "$p=$f")
        dyn+="${dyn:+,}$p"
    done
    [[ -n $dyn ]] || die "OTA: tidak ada partisi logical"

    resolve_super
    gname=$SUPER_GROUP; gsize=$SUPER_GMAX
    if [[ -n ${PAYLOAD_DYN_GROUPS:-} ]]; then
        # ukuran group persis seperti payload ROM base (update_engine membandingkan dengan super HP)
        gsize=${PAYLOAD_DYN_GROUPS%% *}; gsize=${gsize##*:}
    fi
    log "OTA: group $gname ($gsize byte): ${dyn//,/ }"

    aosp_key testkey "$AOSP_TESTKEY_SHA256" || die "test-key AOSP untuk tanda tangan payload tidak bisa diunduh"
    openssl pkcs8 -inform DER -nocrypt -in "$kd/testkey.pk8" -out "$kd/testkey.pem" 2>/dev/null \
        || die "konversi testkey.pk8 gagal"
    ota_info_file "$WORK/port_info.txt" "$3" "$4" "$5" "$6"

    local extra=(--extra "META-INF/port_info.txt=$WORK/port_info.txt")
    if [[ -s $WORK/apex_info.pb ]]; then extra+=(--apex-info "$WORK/apex_info.pb"); fi
    python3 "$SCRIPT_DIR/make_ota.py" build --out "$OUT/$name.zip" \
        --key "$kd/testkey.pem" --cert "$kd/testkey.x509.pem" \
        "${args[@]}" --group "$gname:$gsize:$dyn" --device "$TARGET_DEVICE" \
        --snapshot "${PAYLOAD_SNAPSHOT:-${LP_VIRTUAL_AB:-1}}" --vabc 0 \
        --fingerprint "${OTA_FINGERPRINT:-}" --incremental "${OTA_INCREMENTAL:-}" \
        --spl "${OTA_SPL:-}" --sdk "${OTA_SDK:-}" --xz-preset "${OTA_XZ_PRESET:-6}" \
        --tmpdir "$WORK" "${extra[@]}" || die "pembuatan OTA gagal"
    rm -rf "$imgd" "$OUT_IMG_TMP"
    (cd "$OUT" && sha256sum "$name.zip" > "$name.zip.sha256")
    ok "SELESAI: $OUT/$name.zip ($(du -h "$OUT/$name.zip" | cut -f1)) - OTA A/B: flash di recovery, lalu Format Data"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
        { echo "zip=$OUT/$name.zip"; echo "name=$name"; echo "port_version=$3"; echo "donor=$5"; echo "rom=$4"; echo "base_type=$6"; } >> "$GITHUB_OUTPUT"
    fi
}

# ================================================================== MAIN
main() {
    [[ $RECOVERY_SUPER == raw || $RECOVERY_SUPER == zst ]] || die "RECOVERY_SUPER harus raw atau zst"
    [[ $PACKAGE_TYPE == ota || $PACKAGE_TYPE == recovery ]] || die "PACKAGE_TYPE harus ota atau recovery, bukan '$PACKAGE_TYPE'"
    if [[ $PACKAGE_TYPE == ota ]]; then need openssl; fi
    need curl python3 unzip zip zstd tar lz4 gettype extract.erofs mkfs.erofs mke2fs e2fsdroid \
         resize2fs lpmake simg2img magiskboot payload-dumper-go
    rm -rf "$WORK" "$OUT"
    mkdir -p "$WORK/dl" "$OUT"
    WORK=$(readlink -f "$WORK"); OUT=$(readlink -f "$OUT")
    : > "$WORK/base.env"
    build_fstab_flags

    B_IMG="$WORK/base/images"; P_IMG="$WORK/port/images"
    B_FS="$WORK/base/fs";      P_FS="$WORK/port/fs"
    OUT_IMG_TMP="$WORK/super_parts"
    mkdir -p "$OUT_IMG_TMP"

    # ---------------- 0. INPUT
    group_start "0/7 Cek input & URL"
    if [[ $SUPER_SIZE != auto ]]; then
        [[ $SUPER_SIZE =~ ^[0-9]+$ ]] || die "super_size harus angka byte atau 'auto', bukan '$SUPER_SIZE'"
        if [[ $(( SUPER_SIZE % 4096 )) -ne 0 ]]; then
            die "super_size $SUPER_SIZE bukan kelipatan 4096. Pakai 'auto', atau angka persis dari: adb shell su -c 'blockdev --getsize64 /dev/block/by-name/super'"
        fi
    fi
    # kernel ingres GKI 5.10: driver EROFS hanya bisa baca LZ4 (lz4 & lz4hc menghasilkan format yang sama).
    # lzma butuh kernel 5.16+, deflate 6.6+, zstd 6.10+ -> partisi gagal mount -> bootloop
    case ${EROFS_COMP%%,*} in
        lz4|lz4hc) ;;
        *) die "EROFS_COMP '${EROFS_COMP}' tidak bisa dibaca kernel 5.10 ingres (partisi gagal mount = bootloop). Pakai lz4hc atau lz4" ;;
    esac
    check_url BASE_ROM "$BASE_ROM"
    check_url PORT_ROM "$PORT_ROM"
    if [[ -n $RECOVERY_IMG ]]; then check_url RECOVERY_IMG "$RECOVERY_IMG"; fi
    if [[ -n $BOOT_IMG ]]; then check_url BOOT_IMG "$BOOT_IMG"; fi
    if [[ -n $GBOARD_APK ]]; then check_url GBOARD_APK "$GBOARD_APK"; fi
    group_end

    # ---------------- 1. BASE
    local base_file port_file=""
    # link port bertanda tangan sementara (berlaku ~1 jam): unduh duluan, sebelum base diunduh &
    # diekstrak, supaya tidak keburu kedaluwarsa
    if [[ $PORT_ROM =~ ^https?:// && -n $(dl_tool signed "$PORT_ROM" || true) ]]; then
        group_start "Port ROM: unduh duluan (link sementara)"
        port_file=$(fetch "$PORT_ROM" "$WORK/dl" port_rom)
        group_end
    fi
    group_start "1/7 Base ROM ($TARGET_DEVICE)"
    base_file=$(fetch "$BASE_ROM" "$WORK/dl" base_rom)
    unpack_rom "$base_file" "$B_IMG" base all
    load_base_env
    ls -la "$B_IMG"; dfree
    group_end

    local logical p
    if [[ -n ${LP_PARTITIONS:-} ]]; then
        logical=$(for p in $LP_PARTITIONS; do p=${p%_a}; echo "${p%_b}"; done | awk '!s[$0]++' | tr '\n' ' ')
    elif [[ -n ${PAYLOAD_DYN_PARTITIONS:-} ]]; then
        logical=$PAYLOAD_DYN_PARTITIONS
    else
        logical="system system_ext product vendor odm mi_ext vendor_dlkm system_dlkm odm_dlkm"
    fi
    log "partisi logical base: $logical"
    # tanpa vendor/odm dari base, ROM pasti tidak bisa boot -> hentikan di sini
    for p in vendor odm; do
        if [[ ! -f $B_IMG/$p.img ]]; then
            die "base ROM tidak menghasilkan $p.img (super/payload tidak ditemukan/tidak terbaca). Pakai OTA zip ROM ingres (payload.bin), fastboot ROM .tgz ingres, atau zip xiaomi.eu ingres. Lihat daftar 'isi ROM' di atas."
        fi
    done
    if [[ $INSTALLER == base && ! -d $WORK/base_META-INF ]]; then
        die "INSTALLER=base tapi ROM base tidak punya META-INF (OTA payload / fastboot .tgz tidak punya installer recovery). Pakai INSTALLER: ours"
    fi

    # ---------------- 2. PORT
    group_start "2/7 Port ROM (donor AOSP)"
    [[ -n $port_file ]] || port_file=$(fetch "$PORT_ROM" "$WORK/dl" port_rom)
    unpack_rom "$port_file" "$P_IMG" port "${PORT_PARTITIONS// /,}"
    for p in $PORT_PARTITIONS; do
        [[ -f $P_IMG/$p.img ]] || { warn "port tidak punya $p.img, pakai milik base"; continue; }
    done
    ls -la "$P_IMG"; dfree
    group_end

    # ---------------- 3. EXTRACT
    group_start "3/7 Ekstrak filesystem"
    for p in vendor odm product; do
        [[ -f $B_IMG/$p.img ]] || continue
        log "ekstrak base $p"; extract_img "$B_IMG/$p.img" "$B_FS"
    done
    local btype
    btype=$(detect_base_type)
    log "tipe ROM base: $btype"
    # system_ext base: sumber RRO khas device (base AOSP) / COPY_FROM_BASE system_ext/...
    if [[ -f $B_IMG/system_ext.img ]] && { [[ $btype == aosp ]] || [[ " $COPY_FROM_BASE" == *" system_ext/"* ]]; }; then
        log "ekstrak base system_ext"; extract_img "$B_IMG/system_ext.img" "$B_FS"
    fi
    rm -f "$B_IMG/vendor.img" "$B_IMG/odm.img"   # dibangun ulang
    for p in $PORT_PARTITIONS; do
        [[ -f $P_IMG/$p.img ]] || continue
        log "ekstrak port $p"; extract_img "$P_IMG/$p.img" "$P_FS"; rm -f "$P_IMG/$p.img"
    done
    dfree
    group_end

    # ---------------- 4. PATCH
    group_start "4/7 Patch"
    local donor base_dev rid port_name port_ver
    base_dev=$(get_prop "$B_FS/vendor/build.prop" ro.product.vendor.device)
    [[ -n $base_dev ]] || base_dev=$TARGET_DEVICE
    if [[ $base_dev != "$TARGET_DEVICE" ]]; then
        # firmware (xbl, abl, modem, ...) dari base ikut di-flash: base device lain = hard brick
        is_true "$ALLOW_OTHER_BASE" || die "base vendor device=$base_dev, bukan $TARGET_DEVICE. Firmware base ikut di-flash -> salah base = brick. Cek BASE_ROM (set ALLOW_OTHER_BASE=true hanya kalau yakin)"
        warn "base vendor device=$base_dev, bukan $TARGET_DEVICE (ALLOW_OTHER_BASE=true)"
    fi
    donor=$(detect_donor)
    rom_branding
    rid=$(rom_identity); port_name=${rid%% *}; port_ver=${rid#* }
    log "donor=${donor:-?}  base=$base_dev ($btype)  ROM=$port_name  versi=$port_ver"
    [[ -n $donor ]] || warn "codename donor tidak terdeteksi -> RRO khas donor hanya dibuang lewat DEVICE_OVERLAY_GLOBS"
    if is_miui_tree "$P_FS"; then
        warn "ROM donor terlihat seperti MIUI/HyperOS, bukan AOSP. Untuk port HyperOS pakai repo port HyperOS"
    fi

    # kompatibilitas: sepolicy mapping & VINTF
    local sver sp
    sver=""
    if [[ -f $B_FS/vendor/etc/selinux/plat_sepolicy_vers.txt ]]; then
        sver=$(tr -d '[:space:]' < "$B_FS/vendor/etc/selinux/plat_sepolicy_vers.txt")
    fi
    if [[ -n $sver ]]; then
        if [[ -f $P_FS/system/system/etc/selinux/mapping/$sver.cil ]]; then ok "sepolicy mapping $sver.cil ada"
        else warn "system donor TIDAK punya selinux/mapping/$sver.cil -> kemungkinan besar bootloop"; fi
        for sp in system_ext product; do
            ls "$P_FS/$sp/etc/selinux/"*_sepolicy.cil >/dev/null 2>&1 || continue
            if [[ -f $P_FS/$sp/etc/selinux/mapping/$sver.cil ]]; then ok "sepolicy mapping $sp/$sver.cil ada"
            else warn "$sp donor punya sepolicy tapi tanpa mapping/$sver.cil -> kalau type vendor merujuk type $sp, sepolicy gagal compile (bootloop ke recovery)"; fi
        done
    fi
    check_vintf
    if is_true "$VNDK_COMPAT"; then vndk_compat; fi
    vintf_device_check
    if is_true "$LINKER_CHECK"; then linker_check; fi
    abi_check
    zygote_check
    mediaserver_check
    rc_imports_check
    ims_check
    rc_reboot_check

    DEBLOAT_KEEP=$(debloat_keep)
    if is_true "$PROP_MERGE"; then merge_device_props; fi
    patch_props "$donor" "$base_dev"
    props_effective
    if is_true "$OVERLAY_FIX"; then fix_overlays "$donor"; fi
    report_app_sizes
    patch_port_resources "$btype" "$base_dev"
    run_addons
    apply_device_files
    remove_updater
    vintf_tool_check
    sepolicy_compile_check
    rm -rf "${B_FS:?}/product" "$B_FS/config/product_"* "${B_FS:?}/system_ext" "$B_FS/config/system_ext_"*
    rm -f "$B_IMG/product.img"
    patch_vendor_fstab
    patch_vendor_boot
    vendor_boot_recovery_warn
    patch_vbmeta
    if [[ $PACKAGE_TYPE == ota ]]; then ota_prepare; fi
    group_end

    # ---------------- 5. REPACK
    group_start "5/7 Repack partisi"
    for p in $PORT_PARTITIONS; do
        [[ -d $P_FS/$p ]] || continue
        if in_list "$p" "$EXT4_PARTITIONS"; then
            log "repack port $p (ext4)"; repack_ext4 "$P_FS" "$p" "$OUT_IMG_TMP/$p.img" "$RW_MOUNT"
        else
            log "repack port $p (erofs)"; repack_erofs "$P_FS" "$p" "$OUT_IMG_TMP/$p.img"
            rm -rf "${P_FS:?}/$p"
        fi
    done
    for p in vendor odm; do
        [[ -d $B_FS/$p ]] || continue
        if in_list "$p" "$EXT4_PARTITIONS"; then
            log "repack base $p (ext4, rw=$RW_MOUNT)"; repack_ext4 "$B_FS" "$p" "$OUT_IMG_TMP/$p.img" "$RW_MOUNT"
        else
            log "repack base $p (erofs)"; repack_erofs "$B_FS" "$p" "$OUT_IMG_TMP/$p.img"
        fi
    done
    # partisi logical base lain dipakai apa adanya (vendor_dlkm, system_dlkm, mi_ext HyperOS, ...)
    for p in $logical; do
        [[ -f $OUT_IMG_TMP/$p.img ]] && continue
        if [[ -f $B_IMG/$p.img ]]; then
            mv "$B_IMG/$p.img" "$OUT_IMG_TMP/$p.img"; log "pakai base apa adanya: $p"
            if [[ $p == mi_ext ]]; then log "  mi_ext (HyperOS) tidak dibaca init AOSP, disimpan supaya fstab vendor stock tetap bisa mount"; fi
        fi
    done
    for p in $logical; do rm -f "$B_IMG/$p.img"; done
    fit_super
    # folder EXT4 disimpan sampai fit_super (bisa dibangun ulang sebagai EROFS), baru dibuang
    for p in $PORT_PARTITIONS; do rm -rf "${P_FS:?}/$p"; done
    rm -rf "${B_FS:?}/vendor" "${B_FS:?}/odm"
    ls -la "$OUT_IMG_TMP"; dfree
    group_end

    # ---------------- 6. SUPER
    local super_list
    # shellcheck disable=SC2086  # daftar sengaja di-split
    super_list=$(printf '%s\n' $logical $PORT_PARTITIONS | awk '!s[$0]++' | tr '\n' ' ')
    local pkg="$OUT/pkg" mode stamp name
    stamp=$(date +%Y%m%d)
    name="${port_name}_${port_ver}_${TARGET_DEVICE}_port_${stamp}"
    if [[ $PACKAGE_TYPE == ota ]]; then
        group_start "6/7 Partisi logical -> payload"
        log "PACKAGE_TYPE=ota: super.img tidak dibuat, partisi logical masuk payload.bin (update_engine yang menyusun super)"
        group_end
        group_start "7/7 Paket OTA A/B (payload.bin)"
        package_ota "$super_list" "$name" "$port_ver" "$port_name" "$donor" "$btype"
        group_end
        return 0
    fi
    group_start "6/7 Build super.img"
    mkdir -p "$pkg/images"
    mode=$(installer_mode)
    log "installer: $mode"
    if [[ $mode == base ]]; then SUPER_SPARSE=true; fi
    build_super "$super_list" "$pkg/images/super.img"
    rm -rf "$OUT_IMG_TMP"
    group_end

    # ---------------- 7. PACKAGE
    group_start "7/7 Paket recovery flashable"
    prune_base_images
    mv "$B_IMG"/* "$pkg/images/" 2>/dev/null || true
    if [[ -n $RECOVERY_IMG ]]; then
        put_recovery "$pkg/images/recovery.img"
    fi
    if [[ -n $BOOT_IMG ]]; then replace_boot "$pkg/images/boot.img"; fi
    if [[ -z $RECOVERY_IMG ]]; then
        rm -f "$pkg/images/recovery.img"
        log "recovery.img tidak dimasukkan (recovery di HP tidak ditimpa)"
    fi
    if [[ $mode == base ]]; then
        match_super_layout "$pkg"
        rm -rf "$pkg/META-INF"; cp -a "$WORK/base_META-INF" "$pkg/META-INF"
        if [[ -z $RECOVERY_IMG ]]; then strip_recovery_refs "$pkg"; fi
        apply_base_installer "$pkg"
    else
        if [[ $RECOVERY_SUPER == zst ]]; then
            log "kompres super.img -> super.img.zst"
            zstd -q -T0 -"${ZSTD_LEVEL:-3}" --rm "$pkg/images/super.img" -o "$pkg/images/super.img.zst"
        fi
        write_recovery_pkg "$pkg" "$port_ver" "$port_name"
    fi
    installer_no_wipe "$pkg"
    {
        echo "device=$TARGET_DEVICE"; echo "donor=$donor"; echo "rom=$port_name"; echo "port_version=$port_ver"
        echo "base_type=$btype"; echo "port_partitions=$PORT_PARTITIONS"; echo "ext4_partitions=$EXT4_PARTITIONS"
        echo "disable_encryption=$DISABLE_ENCRYPTION"; echo "rw_mount=$RW_MOUNT"
        echo "disable_avb=$DISABLE_AVB"; echo "debug_adb=$DEBUG_ADB"
        echo "super_size=$SUPER_SIZE"; echo "super_format=$RECOVERY_SUPER"
        echo "boot_img=${BOOT_IMG:-base}"; echo "installer=$mode"
        echo "anti_ver=${ANTI_VER:-unknown}"; echo "build_date=$stamp"
    } > "$pkg/META-INF/port_info.txt"
    ls -la "$pkg/images"
    (cd "$pkg" && zip -q -r -"$ZIP_LEVEL" -n .zst "$OUT/$name.zip" .)
    rm -rf "$pkg"
    (cd "$OUT" && sha256sum "$name.zip" > "$name.zip.sha256")
    ok "SELESAI: $OUT/$name.zip ($(du -h "$OUT/$name.zip" | cut -f1))"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
        { echo "zip=$OUT/$name.zip"; echo "name=$name"; echo "port_version=$port_ver"; echo "donor=$donor"; echo "rom=$port_name"; echo "base_type=$btype"; } >> "$GITHUB_OUTPUT"
    fi
    group_end
}

main "$@"
