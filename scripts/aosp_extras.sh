#!/usr/bin/env bash
# =============================================================================
#  aosp_extras.sh - fungsi khusus port AOSP -> ingres (di-source oleh port.sh)
#
#  Memakai helper dan variabel dari port.sh:
#    log ok warn die is_true in_list get_prop set_prop is_kept base_privapp_perms
#    P_FS B_FS B_IMG BIN TOOLS_DIR WORK SCRIPT_DIR TARGET_DEVICE EXTRACT_EROFS PYBIN
#
#  Fungsi:
#    detect_base_type        aosp | hyperos (ROM base ingres)
#    base_extract_sub        ekstrak sebagian isi image base (mis. system/etc/vintf)
#    fix_overlays            buang RRO khas device donor (codename / DEVICE_OVERLAY_GLOBS)
#    base_device_overlays    salin RRO khas ingres dari base
#    displayconfig_from_base displayconfig panel ingres (punya donor dibuang)
#    fcm_from_base           compatibility_matrix.device.xml dari system base
#    copy_from_base          COPY_FROM_BASE (path bebas, cek sharedUserId)
#    remove_updater          aplikasi OTA donor dibuang (anti brick)
#    abi_check / ims_check   cek 32-bit vendor & IMS Qualcomm (VoLTE)
#    vintf_tool_check        checkvintf --check-compat (toolkit)
#    sepolicy_compile_check  compile sepolicy gabungan pakai secilc seperti init
#    rom_identity            nama & versi ROM donor untuk nama zip
# =============================================================================

# ------------------------------------------------------------------ helper
# glob_any <nama> : 0 kalau nama cocok salah satu DEVICE_OVERLAY_GLOBS
# (read -a supaya pola glob tidak di-expand ke file di direktori kerja)
glob_any() {
    local name=$1 g globs=()
    read -r -a globs <<< "$DEVICE_OVERLAY_GLOBS"
    for g in "${globs[@]}"; do
        # shellcheck disable=SC2053  # $g sengaja pola glob
        if [[ $name == $g ]]; then return 0; fi
    done
    return 1
}

# has_codename <teks> <codename> : codename (min 3 huruf) muncul di teks (case-insensitive)
has_codename() {
    local t=${1,,} c=${2,,}
    [[ ${#c} -ge 3 && $t == *"$c"* ]]
}

# MIUI/HyperOS asli: punya versi UI MIUI/HyperOS atau framework MIUI. Props ro.miui.* lain
# (mis. ro.miui.notch, dipakai port MiuiCamera di ROM AOSP) tidak dihitung.
is_miui_tree() { # root (berisi system/system, product, vendor, ...)
    local r=$1
    grep -qsE '^ro\.(miui\.ui\.version\.(code|name)|mi\.os\.version\.(name|incremental))=' \
        "$r/system/system/build.prop" "$r/product/etc/build.prop" "$r/mi_ext/etc/build.prop" \
        "$r/vendor/build.prop" "$r"/odm/etc/*build.prop && return 0
    [[ -f $r/system_ext/framework/miui-services.jar || -f $r/system/system/framework/miui-framework.jar ]]
}

detect_base_type() {
    case ${BASE_TYPE,,} in
        aosp|hyperos) echo "${BASE_TYPE,,}"; return 0 ;;
    esac
    if [[ -f $B_IMG/mi_ext.img ]] || is_miui_tree "$B_FS"; then
        echo hyperos
    else
        echo aosp
    fi
}

# base_extract_sub <partisi> <subpath di dalam image> <out_dir>
#   system: subpath relatif root image (system-as-root, mis. system/etc/vintf)
base_extract_sub() {
    local part=$1 sub=$2 out=$3 img t
    img="$B_IMG/$part.img"
    rm -rf "$out"; mkdir -p "$out"
    [[ -f $img ]] || return 1
    t=$(gettype -i "$img" 2>/dev/null || true)
    if [[ $t == erofs ]]; then
        "${EXTRACT_EROFS:-$BIN/extract.erofs}" -i "$img" -X "$sub" -o "$out" >/dev/null 2>&1 \
            || "$BIN/extract.erofs" -i "$img" -X "$sub" -o "$out" >/dev/null 2>&1 || true
    else
        python3 "$PYBIN/imgextractor/imgextractor.py" "$img" "$out" >/dev/null 2>&1 || true
    fi
    return 0
}

# ------------------------------------------------------------------ overlay
# RRO di /product dan /system_ext MENANG atas RRO /vendor (urutan prioritas overlay statis),
# jadi RRO khas device donor (kecerahan, cutout, sensor, power profile) harus dibuang supaya
# RRO ingres di vendor/odm base yang dipakai.
fix_overlays() { # donor
    local donor=$1 d f rel name pkg removed=0 left=""
    for d in "$P_FS/product/overlay" "$P_FS/system_ext/overlay"; do
        [[ -d $d ]] || continue
        while IFS= read -r -d '' f; do
            rel=${f#"$P_FS"/}; name=$(basename "$f" .apk)
            pkg=$(python3 "$SCRIPT_DIR/apk_index.py" --apk "$f")
            if has_codename "$name $pkg" "$donor" || glob_any "$name"; then
                if is_kept "$rel" "$name" "$pkg"; then log "overlay donor dipertahankan (keep): $rel"; continue; fi
                rm -f "$f"; rmdir "$(dirname "$f")" 2>/dev/null || true
                removed=$((removed + 1)); ok "overlay donor dibuang: $rel ($pkg)"
            else
                left+=" $rel|$pkg"
            fi
        done < <(find "$d" -maxdepth 3 -type f -name '*.apk' -print0)
    done
    ok "overlay donor: $removed RRO khas device dibuang"
    if [[ -n $left ]]; then
        log "overlay donor yang dipertahankan (cek manual; kalau khas device donor, tambahkan ke debloat atau DEVICE_OVERLAY_GLOBS):"
        tr ' ' '\n' <<< "$left" | grep -v '^$' | awk -F'|' '{printf "    %-60s %s\n", $1, $2}'
    fi
}

base_device_overlays() { # base_type base_codename
    local btype=$1 base=$2 d f rel name pkg added=0
    if [[ $btype == hyperos ]]; then
        # MIUI/HyperOS: AospFrameworkResOverlay berisi config AOSP framework-res milik panel ingres
        # (brightness, cutout, rounded corner). Overlay Miui*/Devices* menarget komponen MIUI -> tidak dipakai.
        for f in ${HYPEROS_BASE_OVERLAYS:-AospFrameworkResOverlay}; do
            rel=$(cd "$B_FS" && find product/overlay -maxdepth 2 -type f -name "$f.apk" 2>/dev/null | head -n1 || true)
            if [[ -z $rel ]]; then warn "overlay: base HyperOS tidak punya $f.apk"; continue; fi
            mkdir -p "$P_FS/$(dirname "$rel")"; cp -f "$B_FS/$rel" "$P_FS/$rel"
            added=$((added + 1)); ok "overlay dari base HyperOS: $rel"
        done
        log "overlay: RRO framework-res di vendor/overlay ingres (stock) tetap dipakai apa adanya"
        return 0
    fi
    for d in product/overlay system_ext/overlay; do
        [[ -d $B_FS/$d ]] || continue
        while IFS= read -r -d '' f; do
            rel=${f#"$B_FS"/}; name=$(basename "$f" .apk)
            pkg=$(python3 "$SCRIPT_DIR/apk_index.py" --apk "$f")
            if has_codename "$name $pkg" "$base" || glob_any "$name"; then
                mkdir -p "$(dirname "$P_FS/$rel")"; cp -f "$f" "$P_FS/$rel"
                added=$((added + 1)); ok "overlay ingres dari base: $rel ($pkg)"
            fi
        done < <(find "$B_FS/$d" -maxdepth 3 -type f -name '*.apk' -print0)
    done
    ok "overlay base: $added RRO khas $base disalin (RRO di vendor/odm base otomatis ikut)"
}

# DisplayManager membaca product/etc/displayconfig dulu, lalu vendor. displayconfig donor = panel lain.
displayconfig_from_base() {
    local dst="$P_FS/product/etc/displayconfig" src
    if [[ -d $B_FS/product/etc/displayconfig ]]; then
        rm -rf "$dst"; mkdir -p "$(dirname "$dst")"
        cp -a "$B_FS/product/etc/displayconfig" "$dst"
        ok "displayconfig: dari base product/etc/displayconfig ($(find "$dst" -type f | wc -l) file)"
        return 0
    fi
    for src in vendor/etc/displayconfig odm/etc/displayconfig; do
        if [[ -d $B_FS/$src ]]; then
            if [[ -d $dst ]]; then rm -rf "$dst"; fi
            ok "displayconfig: ingres memakai $src (base), punya donor di product dihapus"
            return 0
        fi
    done
    if [[ -d $dst ]]; then
        rm -rf "$dst"
        ok "displayconfig: base tidak punya, displayconfig donor (panel lain) dihapus -> pakai config_screenBrightness* overlay"
    else
        log "displayconfig: tidak ada di base maupun donor"
    fi
}

# compatibility_matrix.device.xml = HAL khas device yang boleh dipakai framework. Versi donor
# menyebut HAL device donor; versi base menyebut HAL ingres (mis. vendor.xiaomi.*, vendor.lineage.*).
fcm_from_base() {
    local tmp="$WORK/base_fcm" src dst="$P_FS/system/system/etc/vintf/compatibility_matrix.device.xml"
    if [[ ! -d $P_FS/system/system/etc/vintf ]]; then warn "FCM: system/etc/vintf port tidak ada"; return 0; fi
    base_extract_sub system system/etc/vintf "$tmp" || { warn "FCM: system.img base tidak ada"; return 0; }
    src=$(find "$tmp" -type f -path '*/etc/vintf/compatibility_matrix.device.xml' | head -n1 || true)
    if [[ -n $src ]]; then
        cp -f "$src" "$dst"; chmod 0644 "$dst"
        ok "FCM: compatibility_matrix.device.xml dari system base (HAL khas ingres dikenali framework)"
    elif [[ -f $dst ]]; then
        log "FCM: base tidak punya compatibility_matrix.device.xml, punya donor dipertahankan"
    fi
    rm -rf "$tmp"
}

# COPY_FROM_BASE: path bebas dari base (product/..., system_ext/..., system/...)
copy_from_base() {
    local items=() rel part sub src dst tmp apk info uid n=0
    read -r -a items <<< "$COPY_FROM_BASE"
    [[ ${#items[@]} -gt 0 ]] || return 0
    for rel in "${items[@]}"; do
        rel=${rel#/}; part=${rel%%/*}; sub=${rel#*/}
        case $rel in *..*|"") warn "COPY_FROM_BASE: path '$rel' tidak valid"; continue ;; esac
        case $part in
            product|system_ext)
                src="$B_FS/$rel"; dst="$P_FS/$rel" ;;
            system)
                tmp="$WORK/base_copy_$n"
                base_extract_sub system "system/$sub" "$tmp" || true
                src=$(find "$tmp" -path "*/system/$sub" -prune -print 2>/dev/null | head -n1 || true)
                dst="$P_FS/system/system/$sub" ;;
            *) warn "COPY_FROM_BASE: '$rel' - hanya product/, system_ext/, system/ (vendor/odm sudah dari base)"; continue ;;
        esac
        if [[ -z $src || ! -e $src ]]; then warn "COPY_FROM_BASE: $rel tidak ada di base"; continue; fi
        apk=$(find "$src" -maxdepth 1 -name '*.apk' 2>/dev/null | head -n1 || true)
        if [[ -n $apk ]]; then
            info=$(python3 "$SCRIPT_DIR/apk_index.py" --info "$apk")
            uid=${info#*$'\t'}
            if [[ $uid == android.uid.* ]]; then
                warn "COPY_FROM_BASE: $rel (${info%%$'\t'*}) memakai sharedUserId=$uid -> wajib kunci platform ROM base, PackageManager ROM donor akan menolaknya. Dilewati"
                continue
            fi
        fi
        rm -rf "$dst"; mkdir -p "$(dirname "$dst")"; cp -a "$src" "$dst"
        n=$((n + 1)); ok "COPY_FROM_BASE: $rel disalin"
        if [[ $rel == */priv-app/* && $part != system ]]; then base_privapp_perms "$rel"; fi
    done
    rm -rf "$WORK"/base_copy_*
    ok "COPY_FROM_BASE: $n path disalin"
}

# ------------------------------------------------------------------ updater
# aplikasi OTA bawaan ROM donor menawarkan update untuk device DONOR. Payload itu
# berisi firmware/boot device lain -> kalau ter-install di ingres = brick. Selalu dibuang.
UPDATER_DIRS="Updater MiuiUpdater Updates SystemUpdater SystemUpdate OTAUpdater OtaUpdater"
UPDATER_PKG_RE='(^|[.])(updater|ota|otaupdater|updates|systemupdate|systemupdater)$'
remove_updater() {
    local d n=0 pkg dir
    # (filter nama di loop utama: pipeline "while ... && printf" mengembalikan 1 untuk item
    #  terakhir yang bukan updater -> trap ERR di subshell -> "[fail]" palsu di log)
    while IFS= read -r -d '' d; do
        in_list "$(basename "$d")" "$UPDATER_DIRS" || continue
        rm -rf "$d"; n=$((n + 1))
        ok "updater: ${d#"$P_FS"/} dihapus (OTA donor tidak boleh ter-install di ingres)"
    done < <(find "$P_FS/product" "$P_FS/system_ext" "$P_FS/system/system" -mindepth 2 -maxdepth 2 -type d \
                \( -path '*/app/*' -o -path '*/priv-app/*' \) -print0 2>/dev/null || true)
    while IFS=$'\t' read -r pkg dir; do
        [[ -n $pkg && -d $P_FS/$dir ]] || continue
        case $pkg in com.google.*|com.android.vending) continue ;; esac
        rm -rf "${P_FS:?}/$dir"; n=$((n + 1))
        ok "updater: $dir ($pkg) dihapus"
    done < <(python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" | awk -F'\t' -v re="$UPDATER_PKG_RE" '$1 ~ re' || true)
    if [[ $n -eq 0 ]]; then log "updater: tidak ada aplikasi OTA di ROM donor"; fi
}

# ------------------------------------------------------------------ cek tambahan
abi_check() {
    local v32 s32 res n
    v32=$(find "$B_FS/vendor/lib" "$B_FS/odm/lib" -maxdepth 1 -name '*.so' -print -quit 2>/dev/null || true)
    s32=$(find "$P_FS/system/system/lib" -maxdepth 1 -name 'libc.so' -print -quit 2>/dev/null || true)
    if [[ -z $v32 ]]; then ok "ABI: vendor base 64-bit only"; return 0; fi
    if [[ -n $s32 ]]; then
        ok "ABI: vendor base punya library 32-bit, system donor juga punya /system/lib (32-bit) -> cocok"
        return 0
    fi
    # system donor 64-bit only: library 32-bit vendor cuma bermasalah kalau ada proses 32-bit vendor
    res=$(python3 "$SCRIPT_DIR/elf_scan.py" "$B_FS/vendor" "$B_FS/odm" 2>/dev/null || echo "RESULT ?")
    n=$(sed -n 's/^RESULT //p' <<< "$res" | tail -n1)
    if [[ $n == 0 ]]; then
        ok "ABI: system donor 64-bit only, vendor ingres tidak punya daemon/HAL 32-bit (library 32-bit vendor tidak terpakai)"
    elif [[ ! $n =~ ^[0-9]+$ ]]; then
        warn "ABI: scan executable 32-bit vendor gagal, cek manual vendor/bin"
    else
        # binary 32-bit tidak bisa jalan sama sekali (tanpa linker/libc 32-bit). Service-nya
        # dinonaktifkan di rc vendor/odm: tanpa ini service ber-"critical"/"reboot_on_failure"
        # (mis. boringssl_self_test32) memicu reboot berulang.
        local exes=() rel rcres
        while IFS= read -r rel; do
            [[ -n $rel && $rel != RESULT* ]] || continue
            exes+=(--exe "/$rel")
            if [[ $rel == odm/* ]]; then exes+=(--exe "/vendor/$rel"); fi
        done <<< "$res"
        log "ABI: system donor 64-bit only, vendor ingres punya $n executable 32-bit (tidak bisa jalan):"
        grep -v '^RESULT' <<< "$res" | head -n 20 | while IFS= read -r line; do printf '    %s\n' "$line"; done
        if is_true "${DISABLE_32BIT_SERVICES:-true}"; then
            rcres=$(python3 "$SCRIPT_DIR/rc_disable32.py" "${exes[@]}" "$B_FS/vendor/etc/init" "$B_FS/odm/etc/init" 2>&1 || true)
            grep -vE '^(RESULT|SERVICE) ' <<< "$rcres" | while IFS= read -r line; do printf '%s\n' "$line"; done
            ok "ABI: service 32-bit dinonaktifkan di rc vendor/odm ($(sed -n 's/^RESULT //p' <<< "$rcres" | awk '{print $1" service, "$2" baris"}')): $(sed -n 's/^SERVICE \([^ ]*\).*/\1/p' <<< "$rcres" | tr '\n' ' ')- fitur terkait tidak tersedia, tapi tidak lagi memicu reboot/restart berulang"
        else
            warn "ABI: $n executable 32-bit vendor dibiarkan (DISABLE_32BIT_SERVICES=false) -> gagal start; yang ber-reboot_on_failure bisa bootloop"
        fi
    fi
    # vendor mengiklankan ABI 32-bit (ro.vendor.product.cpu.abilist32). init memakai partisi
    # prioritas tertinggi yang mengisi abilist (product > odm > vendor > system) -> paksa 64-bit
    # di product supaya framework tidak mengira 32-bit didukung (app 32-bit / zygote_secondary).
    local pp="$P_FS/product/etc/build.prop"
    if [[ -f $pp ]]; then
        set_prop "$pp" ro.product.product.cpu.abilist arm64-v8a
        set_prop "$pp" ro.product.product.cpu.abilist64 arm64-v8a
        set_prop "$pp" ro.product.product.cpu.abilist32 ""
        # kalau ada partisi yang mengisi ro.product.cpu.abilist langsung, init melewati penurunan
        # per partisi -> isi juga yang global (product dimuat terakhir, menang)
        set_prop "$pp" ro.product.cpu.abilist arm64-v8a
        set_prop "$pp" ro.product.cpu.abilist64 arm64-v8a
        set_prop "$pp" ro.product.cpu.abilist32 ""
        ok "ABI: abilist = arm64-v8a, abilist32 kosong (product), cocok dengan system donor 64-bit only"
    fi
}

ims_check() {
    local idx
    idx=$(python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" | cut -f1 || true)
    if grep -qxE 'org\.codeaurora\.ims|com\.qualcomm\.qti\.ims|org\.lineageos\.ims' <<< "$idx"; then
        ok "IMS: stack IMS Qualcomm ada di donor (VoLTE/VoWiFi bisa jalan dengan vendor ingres)"
    else
        warn "IMS: donor tidak membawa IMS Qualcomm (org.codeaurora.ims) -> VoLTE/VoWiFi kemungkinan tidak jalan. Pilih donor ROM Qualcomm (idealnya SM8450/taro)"
    fi
}

vintf_tool_check() {
    local cv="$BIN/checkvintf" args=() p fal rc=0
    is_true "$VINTF_TOOL_CHECK" || return 0
    if [[ ! -x $cv ]]; then log "checkvintf: tidak ada di toolkit, dilewati"; return 0; fi
    args=(--check-compat --dirmap "/system:$P_FS/system/system" --dirmap "/vendor:$B_FS/vendor")
    for p in system_ext product; do
        if [[ -d $P_FS/$p ]]; then args+=(--dirmap "/$p:$P_FS/$p"); fi
    done
    if [[ -d $B_FS/odm ]]; then args+=(--dirmap "/odm:$B_FS/odm"); fi
    fal=$(get_prop "$P_FS/product/etc/build.prop" ro.product.first_api_level)
    if [[ -n $fal ]]; then args+=(--property "ro.product.first_api_level=$fal"); fi
    args+=(--property "ro.boot.product.hardware.sku=$TARGET_DEVICE")
    # tanpa /apex/apex-info-list.xml checkvintf gagal membaca manifest device -> daftar APEX kosong
    mkdir -p "$WORK/vintf_apex"
    printf '<?xml version="1.0" encoding="utf-8"?>\n<apex-info-list></apex-info-list>\n' > "$WORK/vintf_apex/apex-info-list.xml"
    args+=(--dirmap "/apex:$WORK/vintf_apex" --property apex.all.ready=true)
    timeout 300 "$cv" "${args[@]}" > "$WORK/checkvintf.log" 2>&1 || rc=$?
    rm -rf "$WORK/vintf_apex"
    if grep -qE 'Unrecognized (manifest|compatibility-matrix)\.version' "$WORK/checkvintf.log"; then
        local why
        why=$(grep -oE 'Unrecognized [a-z.-]+version [0-9.]+ \(libvintf@[0-9.]+\)' "$WORK/checkvintf.log" | head -n1 || true)
        log "checkvintf: libvintf di toolkit lebih tua dari Android donor (${why:-format VINTF baru}), cek dilewati. Cek VINTF di atas (vintf_check) tetap berlaku"
        return 0
    fi
    if [[ $rc -eq 0 ]]; then
        ok "checkvintf: framework donor COMPATIBLE dengan vendor/odm ingres"
    else
        warn "checkvintf: TIDAK compatible (rc=$rc). Biasanya cuma dialog 'internal problem', tapi HAL yang hilang bisa bikin fitur mati. checkvintf toolkit bisa lebih tua dari Android donor (level FCM baru tak dikenal) - detail:"
        grep -vE "^(Fetch|List|Get modified|Sysprop|getDevice|getFramework)|NAME_NOT_FOUND|^[[:space:]]*$" "$WORK/checkvintf.log" \
            | tail -n 25 | sed 's/^/    /' >&2 || true
    fi
}

# init meng-compile sepolicy saat boot kalau hash precompiled vendor tidak cocok dengan
# system/system_ext/product (selalu terjadi di ROM port). Gagal compile = reboot ke recovery.
# Di sini dijalankan perintah yang sama (secilc) supaya ketahuan sebelum flash.
sepolicy_compile_check() {
    local ver sys="$P_FS/system/system/etc/selinux" vs="$B_FS/vendor/etc/selinux" args=() d n rc=0
    is_true "$SEPOLICY_CHECK" || return 0
    local sc=${SECILC:-secilc}
    if ! command -v "$sc" >/dev/null; then warn "sepolicy: secilc tidak terpasang, cek compile dilewati"; return 0; fi
    log "sepolicy: compiler $sc"
    ver=$(tr -d '[:space:]' < "$vs/plat_sepolicy_vers.txt" 2>/dev/null || true)
    if [[ -z $ver ]]; then warn "sepolicy: vendor/etc/selinux/plat_sepolicy_vers.txt tidak ada, cek dilewati"; return 0; fi
    if [[ ! -f $sys/plat_sepolicy.cil || ! -f $sys/mapping/$ver.cil || ! -f $vs/vendor_sepolicy.cil ]]; then
        warn "sepolicy: file cil wajib tidak lengkap (plat_sepolicy.cil / mapping/$ver.cil / vendor_sepolicy.cil) -> hampir pasti bootloop"
        if is_true "$SEPOLICY_STRICT"; then die "sepolicy tidak lengkap (SEPOLICY_STRICT)"; fi
        return 0
    fi
    # urutan sama dengan system/core/init/selinux.cpp (CompilePolicy)
    args=("$sys/plat_sepolicy.cil" -m -M true -G -N -c 33 "$sys/mapping/$ver.cil")
    if [[ -f $sys/mapping/$ver.compat.cil ]]; then args+=("$sys/mapping/$ver.compat.cil"); fi
    for n in system_ext product; do
        d="$P_FS/$n/etc/selinux"
        if [[ -f $d/${n}_sepolicy.cil ]]; then args+=("$d/${n}_sepolicy.cil"); fi
        if [[ -f $d/mapping/$ver.cil ]]; then args+=("$d/mapping/$ver.cil"); fi
        if [[ -f $d/mapping/$ver.compat.cil ]]; then args+=("$d/mapping/$ver.compat.cil"); fi
    done
    if [[ -f $vs/plat_pub_versioned.cil ]]; then args+=("$vs/plat_pub_versioned.cil"); fi
    args+=("$vs/vendor_sepolicy.cil")
    if [[ -f $B_FS/odm/etc/selinux/odm_sepolicy.cil ]]; then args+=("$B_FS/odm/etc/selinux/odm_sepolicy.cil"); fi
    log "sepolicy: secilc ${#args[@]} argumen, vendor plat version $ver"
    timeout 600 "$sc" "${args[@]}" -o "$WORK/sepolicy.compiled" -f /dev/null > "$WORK/secilc.log" 2>&1 || rc=$?
    rm -f "$WORK/sepolicy.compiled"
    if [[ $rc -eq 0 ]]; then
        ok "sepolicy: gabungan system donor + vendor ingres BERHASIL di-compile (seperti init saat boot)"
        return 0
    fi
    sed 's/^/    /' "$WORK/secilc.log" | tail -n 30 >&2
    if grep -qiE 'Failed to resolve|undeclared|not declared|Unknown (type|role|attribute|class)' "$WORK/secilc.log"; then
        warn "sepolicy: GAGAL compile - vendor/odm ingres merujuk type yang tidak ada di system/system_ext/product donor -> init gagal load sepolicy = bootloop ke recovery. Biasanya karena ROM base & donor beda basis (mis. LineageOS vs AOSP murni): pakai donor dengan basis sama dengan base"
        if is_true "$SEPOLICY_STRICT"; then die "sepolicy gabungan tidak bisa di-compile (SEPOLICY_STRICT=true)"; fi
    else
        if grep -qiE 'Unknown permissionx kind|Invalid syntax|Unknown keyword|Unexpected' "$WORK/secilc.log"; then
            warn "sepolicy: secilc ($sc) terlalu tua untuk CIL Android donor (sintaks baru tak dikenal), cek dilewati. Workflow membangun secilc terbaru di step 'Build secilc'; cek step itu"
        else
            warn "sepolicy: secilc gagal (rc=$rc) dengan error yang bukan resolve type - anggap informasi, bukan vonis"
        fi
    fi
}

# ------------------------------------------------------------------ identitas ROM donor
# echo "<nama_rom> <versi>" (sudah disanitasi untuk nama file)
rom_identity() {
    local files=() f rom="" ver="" k cand
    for f in "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop" "$P_FS/product/etc/build.prop"; do
        if [[ -f $f ]]; then files+=("$f"); fi
    done
    # ro.<rom>.version (axion, crdroid, evolution, lineage, ...), utamakan selain lineage
    cand=$(cat "${files[@]}" 2>/dev/null | sed -n 's/^ro\.\([a-z0-9]*\)\.version=.*/\1/p' \
        | grep -vxE 'build|product|vendor|system|system_ext|odm|boot|vndk|opengles|gsid|apex|kernel|mi|miui|com|treble|config|hwui|sf|modversion' \
        | awk '!s[$0]++' || true)
    for k in $cand; do
        if [[ $k != lineage ]]; then rom=$k; break; fi
    done
    if [[ -z $rom && -n $cand ]]; then rom=${cand%%$'\n'*}; fi
    if [[ -n $rom ]]; then
        ver=$(cat "${files[@]}" 2>/dev/null | sed -n "s/^ro\.${rom}\.version=//p" | tail -n1)
    fi
    if [[ -z $rom ]]; then
        rom=$(cat "${files[@]}" 2>/dev/null | sed -n 's/^ro\.build\.flavor=//p' | tail -n1)
        rom=${rom%%_*}; rom=${rom%%-*}
    fi
    [[ -n $rom ]] || rom=AOSP
    if [[ -z $ver ]]; then
        ver="A$(get_prop "$P_FS/system/system/build.prop" ro.build.version.release)_$(get_prop "$P_FS/system/system/build.prop" ro.build.version.incremental)"
    fi
    rom=$(tr -c 'A-Za-z0-9._-' '_' <<< "$rom" | sed 's/_*$//')
    ver=$(tr -c 'A-Za-z0-9._-' '_' <<< "$ver" | sed 's/_*$//')
    echo "${rom:-AOSP} ${ver:-unknown}"
}
