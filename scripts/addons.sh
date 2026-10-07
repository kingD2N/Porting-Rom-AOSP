# shellcheck shell=bash
# =============================================================================
#  addons.sh - fitur tambahan opsional untuk ROM port (di-source port.sh)
#
#  miuicamera : MiuiCamera khusus ingres (Gurinbone/android_{device,vendor}_xiaomi_miuicamera-ingres)
#               -> system/priv-app/MiuiCamera + library JNI kamera + sepolicy app kamera.
#               Sisi vendor (campostproc, libmialgo) sudah ada di vendor LineageOS ingres.
#  dolby      : Dolby Atmos DAX (Gurinbone/hardware_dolby) -> HAL vendor.dolby.hardware.dms@2.0,
#               efek audio (dap, volume leveler, game, vqe), UI DaxUI + daxService.
#  touchrate  : mode laporan sentuh tinggi panel (bump_sample_rate touchfeature Xiaomi = 1) sejak boot.
#
#  Semua addon: bahan di-stage dulu, dependensi library dicek terhadap ROM hasil port.
#  Kalau ada yang kurang -> addon dilewati (ROM tetap aman, hanya tanpa fitur itu).
#  Sepolicy addon ditandai ADDON_CIL_TAG; kalau sepolicy gabungan gagal di-compile
#  karena addon, seluruh addon dibatalkan (addon_rollback) supaya tidak bootloop.
# =============================================================================

ADDONS=${ADDONS-"miuicamera dolby touchrate"}   # kosong = tanpa addon
ADDON_CIL_TAG="; [port-addon]"
ADDON_DATA_DIR=${ADDON_DATA_DIR:-$SCRIPT_DIR/../addons}
MIUICAMERA_DEVICE_REPO=${MIUICAMERA_DEVICE_REPO:-https://github.com/Gurinbone/android_device_xiaomi_miuicamera-ingres}
MIUICAMERA_VENDOR_REPO=${MIUICAMERA_VENDOR_REPO:-https://github.com/Gurinbone/android_vendor_xiaomi_miuicamera-ingres}
MIUICAMERA_BRANCH=${MIUICAMERA_BRANCH:-lineage-23.2}
DOLBY_REPO=${DOLBY_REPO:-https://github.com/Gurinbone/hardware_dolby}
DOLBY_BRANCH=${DOLBY_BRANCH:-Dolby-Vision-2.1}

MIUICAMERA_LIBS="libcamera_algoup_jni.xiaomi.so libcamera_mianode_jni.xiaomi.so libmicampostproc_client.so vendor.xiaomi.hardware.campostproc@1.0.so"
# blob Dolby DAX (tanpa Dolby Vision, codec2 Dolby & spatializer: butuh lib codec2/head-tracker
# yang tidak ada di vendor LineageOS ingres)
DOLBY_VENDOR_FILES="bin/hw/vendor.dolby.hardware.dms@2.0-service
lib64/libdapparamstorage.so lib64/libdapparamstorage-dolby.so lib64/libdlbdsservice.so lib64/libdlbpreg.so
lib64/liboem_specific.so lib64/libdeccfg.so lib64/vendor.dolby.hardware.dms@2.0.so
lib64/vendor.dolby.hardware.dms@2.0-impl.so lib64/vendor.dolby.hardware.dms@2.0-dolby.so
lib64/vendor.dolby.hardware.dms@2.0-atmos.so.so lib64/libstagefright_foundation-atmos.so
lib64/libstagefright_foundation-dolby.so
lib64/soundfx/libswdap.so lib64/soundfx/libdlbvol.so lib64/soundfx/libswgamedap.so lib64/soundfx/libswvqe.so
etc/dolby/dax-default.xml etc/dolby/dax-moto_1.xml etc/dolby/dax-moto_2.xml etc/dolby/dax-moto_3.xml
etc/init/vendor.dolby.hardware.dms@2.0-service.rc
etc/vintf/manifest/vendor.dolby.hardware.dms@2.0-service.xml"
DOLBY_APPS="DaxUI:com.dolby.daxappui daxService:com.dolby.daxservice"
# UI Dolby (hanya satu yang dipasang: dua pengontrol efek DAP yang sama saling menimpa)
# lunaris = Lunaris Dolby (org.lunaris.dolby, default). Urutan:
#           1. donor sudah punya org.lunaris.dolby (mis. AfterLife) -> dipakai apa adanya
#           2. APK Lunaris (LUNARIS_DOLBY_APK) ditandatangani kunci platform donor -> dipasang.
#              Lunaris memakai sharedUserId=android.uid.system, jadi WAJIB kunci platform donor:
#              hanya bisa kalau donor ditandatangani test-key AOSP
#           3. selain itu: UI Dolby bawaan donor (kalau ada), terakhir DaxUI + daxService
# dax     = selalu DaxUI + daxService
DOLBY_UI=${DOLBY_UI:-lunaris}
LUNARIS_DOLBY_PKG=org.lunaris.dolby
# URL/path APK Lunaris Dolby (APK utuh berisi classes.dex). Kosong = addons/dolby/LunarisDolby.apk di repo
LUNARIS_DOLBY_APK=${LUNARIS_DOLBY_APK:-}
# AudioFX/MusicFX bentrok dengan DAX (sama-sama memasang efek global) -> dibuang (RemovePackagesDolby)
DOLBY_REMOVE_PKGS="org.lineageos.audiofx com.android.musicfx"

ADDON_CUR=""          # addon yang sedang dipasang
ADDON_FILES=()        # "addon|path" file/folder baru dari addon (untuk rollback)
ADDON_BACKUPS=()      # "addon|asli|cadangan" file yang diubah addon (keadaan sebelum addon itu)
ADDON_DONE=()         # addon yang terpasang

addon_clone() { # url branch dest
    local url=$1 br=$2 dst=$3 try
    for try in 1 2 3; do
        rm -rf "$dst"
        if GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0 timeout 900 \
                git clone -q --depth 1 -b "$br" "$url" "$dst" >/dev/null 2>"$WORK/addon_git.log"; then
            return 0
        fi
        sleep $((try * 5))
    done
    warn "addon: git clone $url ($br) gagal: $(tail -n1 "$WORK/addon_git.log")"
    return 1
}

addon_backup() { # file -> salinan keadaan sebelum addon ini (sekali per addon)
    local f=$1 b
    [[ -e $f ]] || return 0
    for b in "${ADDON_BACKUPS[@]}"; do [[ $b == "$ADDON_CUR|$f|"* ]] && return 0; done
    b="$WORK/addons/backup/$ADDON_CUR-$(printf '%s' "$f" | md5sum | cut -c1-12)"
    mkdir -p "$WORK/addons/backup"
    cp -a "$f" "$b"
    ADDON_BACKUPS+=("$ADDON_CUR|$f|$b")
}

addon_new() { # path baru (belum ada) -> dicatat untuk rollback
    [[ -e $1 ]] || ADDON_FILES+=("$ADDON_CUR|$1")
}

addon_mkdir() { # buat folder (dicatat kalau baru)
    local p=$1 top=$1
    while [[ ! -e $(dirname "$top") ]]; do top=$(dirname "$top"); done
    addon_new "$top"
    mkdir -p "$p"
}

addon_install() { # src dst -> salin + catat untuk rollback
    local src=$1 dst=$2
    addon_mkdir "$(dirname "$dst")"
    if [[ -e $dst ]]; then addon_backup "$dst"; else addon_new "$dst"; fi
    cp -a "$src" "$dst"
}

# label SELinux persis untuk file baru di config repack (bukan tebakan contextpatch)
addon_ctx() { # root part rel[=label]...
    local root=$1 part=$2 cfg
    shift 2
    case $root in "$B_FS") cfg="$B_FS/config/${part}_file_contexts" ;; *) cfg="$P_FS/config/${part}_file_contexts" ;; esac
    if [[ ! -f $cfg ]]; then warn "addon: $cfg tidak ada, label file baru ditebak contextpatch"; return 0; fi
    addon_backup "$cfg"
    python3 "$SCRIPT_DIR/addon_tool.py" ctx "$cfg" "$root/$part" "$part" "$@" > "$WORK/addon_ctx.log" || {
        warn "addon: label SELinux gagal ditulis ke $cfg"; return 1; }
    sed 's/^/  /' "$WORK/addon_ctx.log"
}

# sepolicy addon (template CIL) -> vendor_sepolicy.cil base
addon_sepolicy() { # template [--each NAME=a,b]...
    local tmpl=$1 vs="$B_FS/vendor/etc/selinux" ver out
    shift
    ver=$(tr -d '[:space:]' < "$vs/plat_sepolicy_vers.txt" 2>/dev/null || true)
    if [[ -z $ver || ! -f $vs/vendor_sepolicy.cil || ! -f $vs/plat_pub_versioned.cil ]]; then
        warn "addon: sepolicy vendor tidak lengkap (vendor_sepolicy.cil/plat_pub_versioned.cil/plat_sepolicy_vers.txt)"
        return 1
    fi
    out="$WORK/addons/$(basename "$(dirname "$tmpl")").cil"
    local pc=() f
    for f in "$P_FS/system/system/etc/selinux/plat_sepolicy.cil" "$P_FS/system_ext/etc/selinux/system_ext_sepolicy.cil" \
             "$P_FS/product/etc/selinux/product_sepolicy.cil"; do
        [[ -f $f ]] && pc+=(--plat-cil "$f")
    done
    python3 "$SCRIPT_DIR/addon_tool.py" cil "$tmpl" --vendor-cil "$vs/vendor_sepolicy.cil" \
        --plat-pub "$vs/plat_pub_versioned.cil" --ver "$ver" --tag "$ADDON_CIL_TAG" "${pc[@]}" "$@" \
        > "$out" 2> "$out.log" || { warn "addon: template sepolicy $tmpl gagal diproses"; return 1; }
    if [[ -s $out.log ]]; then sed 's/^/    sepolicy /' "$out.log"; fi
    addon_backup "$vs/vendor_sepolicy.cil"
    if [[ -n $(tail -c1 "$vs/vendor_sepolicy.cil") ]]; then echo >> "$vs/vendor_sepolicy.cil"; fi
    cat "$out" >> "$vs/vendor_sepolicy.cil"
    # policy precompiled vendor (kalau ada) tidak memuat baris baru -> buang, init compile ulang saat boot
    for f in "$vs"/precompiled_sepolicy*; do
        [[ -e $f ]] || continue
        addon_backup "$f"; rm -f "$f"; log "  addon: ${f#"$B_FS"/} dibuang (sepolicy vendor berubah, init compile ulang)"
    done
    log "  sepolicy: $(wc -l < "$out") baris CIL $(basename "$(dirname "$tmpl")") -> vendor_sepolicy.cil"
}

addon_append_line() { # file line  (contexts runtime vendor)
    local f=$1 l=$2
    [[ -f $f ]] || return 0
    grep -qxF "$l" "$f" && return 0
    addon_backup "$f"
    if [[ -n $(tail -c1 "$f") ]]; then echo >> "$f"; fi
    printf '%s\n' "$l" >> "$f"
}

# dependensi DT_NEEDED file stage terhadap ROM hasil port. 0 = lengkap
addon_deps() { # label check_dir provide_dir...
    local label=$1 chk=$2 args=() d log="$WORK/addons/deps_$1.log"
    shift 2
    for d in "$@"; do [[ -d $d ]] && args+=(--provide "$d"); done
    for d in "$P_FS/system/system/apex" "$P_FS/system_ext/apex"; do [[ -d $d ]] && args+=(--apex "$d"); done
    timeout 900 python3 "$SCRIPT_DIR/linker_check.py" --check "$chk" "${args[@]}" \
        --apex-cache "$WORK/addons/apex_system.cache" \
        --erofs-extract "${EXTRACT_EROFS:-$BIN/extract.erofs}" > "$log" 2>&1 || true
    if grep -q '^64-bit: semua dependensi ditemukan' "$log" && ! grep -q 'MISSING' "$log"; then
        ok "addon $label: semua dependensi library tersedia"
        return 0
    fi
    sed 's/^/    /' "$log" >&2
    return 1
}

# tanda tangan APK: kunci platform donor (test-key AOSP) kalau bisa, selain itu testkey AOSP
# -> 0 = platform_app, 2 = priv_app (testkey), 1 = gagal
addon_sign() { # dir_app [force]  (force = tanda tangan wajib diganti, mis. APK yang sudah rusak)
    local dir=$1 force=${2:-} apk kd="$WORK/aosp_testkey"
    if platform_resign "$dir"; then return 0; fi
    [[ -n $force ]] || return 2
    apk=$(find "$dir" -maxdepth 1 -name '*.apk' | head -n1)
    command -v apksigner >/dev/null || { warn "apksigner tidak ada"; return 1; }
    aosp_key testkey "$AOSP_TESTKEY_SHA256" || return 1
    if ! apksigner sign --key "$kd/testkey.pk8" --cert "$kd/testkey.x509.pem" --out "$apk.signed" "$apk" >/dev/null 2>"$WORK/apksigner.log"; then
        warn "apksigner gagal: $(head -n1 "$WORK/apksigner.log")"; rm -f "$apk.signed"; return 1
    fi
    mv "$apk.signed" "$apk"; rm -f "$apk.signed.idsig"; chmod 644 "$apk"
    return 2
}

addon_remove_pkgs() { # label pkg...
    local label=$1 pkg dir
    shift
    while IFS=$'\t' read -r pkg dir; do
        [[ -n $dir && -d $P_FS/$dir ]] || continue
        in_list "$pkg" "$@" || continue
        addon_backup "$P_FS/$dir"      # dikembalikan kalau addon dibatalkan
        rm -rf "${P_FS:?}/$dir"
        ok "$label: $dir ($pkg) dibuang"
    done < <(python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" || true)
}

# ------------------------------------------------------------------ MiuiCamera
addon_miuicamera() {
    local d="$WORK/addons/miuicamera" sys="$P_FS/system/system" ven apk st oid size lfs_info got lib rc url f pkg n
    ADDON_CUR=miuicamera
    log "addon MiuiCamera: sumber $MIUICAMERA_VENDOR_REPO ($MIUICAMERA_BRANCH)"
    if [[ ! -d $sys ]]; then warn "addon MiuiCamera: system donor tidak diekstrak"; return 1; fi
    if [[ ! -f $ADDON_DATA_DIR/miuicamera/libgui_shim_miuicamera.so ]]; then warn "addon MiuiCamera: shim libgui tidak ada di repo"; return 1; fi
    rm -rf "$d"; mkdir -p "$d"
    addon_clone "$MIUICAMERA_DEVICE_REPO" "$MIUICAMERA_BRANCH" "$d/dev" || return 1
    addon_clone "$MIUICAMERA_VENDOR_REPO" "$MIUICAMERA_BRANCH" "$d/ven" || return 1
    ven="$d/ven/proprietary/system"
    apk="$ven/priv-app/MiuiCamera/MiuiCamera.apk"
    [[ -f $apk ]] || { warn "addon MiuiCamera: MiuiCamera.apk tidak ada di repo vendor"; return 1; }
    # APK disimpan di git LFS (~200 MB): unduh isi aslinya, cek sha256 sesuai pointer
    oid=""; size=""
    lfs_info=$(python3 "$SCRIPT_DIR/addon_tool.py" lfs "$apk" || true)
    if [[ -n $lfs_info ]]; then read -r oid size <<< "$lfs_info"; fi
    if [[ -n ${oid:-} ]]; then
        url="https://media.githubusercontent.com/media/${MIUICAMERA_VENDOR_REPO#https://github.com/}/$MIUICAMERA_BRANCH/proprietary/system/priv-app/MiuiCamera/MiuiCamera.apk"
        log "  unduh MiuiCamera.apk ($(( size / 1048576 )) MB, git LFS)"
        dl_curl "$url" "$apk.dl" || { warn "addon MiuiCamera: unduh APK gagal"; return 1; }
        got=$(sha256sum "$apk.dl" | cut -d' ' -f1)
        if [[ $got != "$oid" ]]; then warn "addon MiuiCamera: sha256 APK tidak cocok dengan pointer LFS"; return 1; fi
        mv -f "$apk.dl" "$apk"
    fi
    pkg=$(python3 "$SCRIPT_DIR/apk_index.py" --apk "$apk" || true)
    [[ $pkg == com.android.camera ]] || { warn "addon MiuiCamera: package APK '$pkg', bukan com.android.camera"; return 1; }

    # stage: system/lib64 + shim + APK
    st="$d/stage/system"
    mkdir -p "$st/lib64" "$st/priv-app/MiuiCamera"
    for lib in $MIUICAMERA_LIBS; do
        [[ -f $ven/lib64/$lib ]] || { warn "addon MiuiCamera: $lib tidak ada di repo vendor"; return 1; }
        cp "$ven/lib64/$lib" "$st/lib64/"
    done
    cp "$ADDON_DATA_DIR/miuicamera/libgui_shim_miuicamera.so" "$st/lib64/"
    if ! addon_deps miuicamera "$d/stage" "$sys" "$P_FS/system_ext" "$P_FS/product"; then
        warn "addon MiuiCamera DILEWATI: library JNI kamera butuh library system yang tidak ada di ROM donor (daftar MISSING di atas)"
        return 1
    fi
    cp "$apk" "$st/priv-app/MiuiCamera/"
    # tanda tangan bawaan APK sudah rusak (APK di-patch) -> wajib ditandatangani ulang
    rc=0; addon_sign "$st/priv-app/MiuiCamera" force || rc=$?
    case $rc in
        0) ok "MiuiCamera: ditandatangani kunci platform donor (test-key AOSP) -> platform_app" ;;
        2) warn "MiuiCamera: donor memakai kunci privat -> ditandatangani testkey AOSP, jalan sebagai priv_app (izin signature-only seperti INJECT_EVENTS/DEVICE_POWER tidak didapat; fitur dasar kamera tetap jalan)" ;;
        *) warn "addon MiuiCamera DILEWATI: APK gagal ditandatangani"; return 1 ;;
    esac
    if command -v zipalign >/dev/null && ! zipalign -c -p 4 "$st/priv-app/MiuiCamera/MiuiCamera.apk" >/dev/null 2>&1; then
        warn "addon MiuiCamera DILEWATI: APK hasil tanda tangan tidak ter-align (library native tidak bisa dimuat langsung)"
        return 1
    fi

    # pasang
    replace_donor_camera "MiuiCamera ingres (addon)"
    for f in "$st"/lib64/*.so; do addon_install "$f" "$sys/lib64/$(basename "$f")"; done
    rm -rf "$sys/priv-app/MiuiCamera"
    addon_install "$st/priv-app/MiuiCamera" "$sys/priv-app/MiuiCamera"
    # public.libraries-xiaomi.txt: library JNI kamera boleh dimuat app (digabung kalau sudah ada)
    f="$sys/etc/public.libraries-xiaomi.txt"
    addon_backup "$f"; addon_new "$f"; touch "$f"
    while IFS= read -r lib; do
        lib=${lib%%#*}; lib=${lib//[[:space:]]/}
        [[ -n $lib ]] || continue
        grep -qxF "$lib" "$f" || printf '%s\n' "$lib" >> "$f"
    done < "$d/dev/configs/public.libraries-xiaomi.txt"
    chmod 644 "$f"
    python3 "$SCRIPT_DIR/apk_index.py" --perms "$st/priv-app/MiuiCamera/MiuiCamera.apk" > "$d/perms.txt" 2>/dev/null || true
    addon_mkdir "$sys/etc/permissions"; addon_mkdir "$sys/etc/sysconfig"
    f="$sys/etc/permissions/privapp-permissions-miuicamera.xml"
    addon_backup "$f"; addon_new "$f"
    n=$(python3 "$SCRIPT_DIR/addon_tool.py" allowlist com.android.camera "$f" "$d/perms.txt" "$d/dev/configs/privapp-permissions-miuicamera.xml")
    log "  allowlist privapp com.android.camera: $n izin"
    addon_install "$d/dev/configs/miuicamera-hiddenapi-package-allowlist.xml" "$sys/etc/sysconfig/miuicamera-hiddenapi-package-allowlist.xml"
    # props (device/xiaomi/miuicamera-ingres/system.prop)
    addon_backup "$sys/build.prop"
    set_prop "$sys/build.prop" ro.com.google.lens.oem_camera_package com.android.camera
    set_prop "$sys/build.prop" persist.vendor.camera.privapp.list com.android.camera
    set_prop "$sys/build.prop" ro.miui.notch 1
    # label SELinux file baru
    local rels=()
    for f in "$st"/lib64/*.so; do rels+=("system/lib64/$(basename "$f")"); done
    rels+=(system/priv-app/MiuiCamera system/priv-app/MiuiCamera/MiuiCamera.apk system/etc/public.libraries-xiaomi.txt
           system/etc/permissions/privapp-permissions-miuicamera.xml system/etc/sysconfig/miuicamera-hiddenapi-package-allowlist.xml)
    addon_ctx "$P_FS" system "${rels[@]}" || true
    local appdoms
    appdoms=$(app_domains); appdoms=${appdoms// /,}
    addon_sepolicy "$ADDON_DATA_DIR/miuicamera/sepolicy.cil" --each "APP=$appdoms" || {
        warn "addon MiuiCamera: sepolicy kamera tidak bisa ditambahkan -> dibatalkan"; addon_rollback; return 1; }
    ADDON_DONE+=(miuicamera)
    ok "addon MiuiCamera terpasang (system/priv-app/MiuiCamera, $(du -sm "$sys/priv-app/MiuiCamera" | cut -f1) MB). Aperture tetap ada sebagai cadangan"
}

# ------------------------------------------------------------------ Dolby
addon_dolby() {
    local d="$WORK/addons/dolby" src st vend="$B_FS/vendor" f rel rels=() serels=() n=0 x app pkg rc donor_pkgs donor_ui="" se="$P_FS/system_ext"
    ADDON_CUR=dolby
    log "addon Dolby: sumber $DOLBY_REPO ($DOLBY_BRANCH)"
    if [[ ! -d $vend ]]; then warn "addon Dolby: vendor base tidak diekstrak"; return 1; fi
    rm -rf "$d"; mkdir -p "$d"
    addon_clone "$DOLBY_REPO" "$DOLBY_BRANCH" "$d/src" || return 1
    src="$d/src/proprietary"
    local have_hal=false
    if [[ -e $vend/bin/hw/vendor.dolby.hardware.dms@2.0-service ]]; then
        have_hal=true
        log "  vendor base sudah punya HAL Dolby (dms@2.0) -> hanya UI yang dipasang"
    fi

    if ! is_true "$have_hal"; then
        # stage vendor
        st="$d/stage/vendor"
        for rel in $DOLBY_VENDOR_FILES; do
            [[ -f $src/vendor/$rel ]] || { warn "addon Dolby: $rel tidak ada di repo"; return 1; }
            mkdir -p "$st/$(dirname "$rel")"; cp "$src/vendor/$rel" "$st/$rel"
        done
        [[ -f $d/src/rootdir/etc/init.dolby.rc ]] || { warn "addon Dolby: rootdir/etc/init.dolby.rc tidak ada"; return 1; }
        cp "$d/src/rootdir/etc/init.dolby.rc" "$st/etc/init/init.dolby.rc"
        # libstagefright_foundation-v33 (VNDK v33 lama, dipakai libswdap/libdlbdsservice) tidak ada di
        # vendor LineageOS 23 -> dibuat dari libstagefright_foundation-dolby (biner sama, beda SONAME)
        python3 "$SCRIPT_DIR/addon_tool.py" soname "$st/lib64/libstagefright_foundation-dolby.so" \
            "$st/lib64/libstagefright_foundation-v33.so" libstagefright_foundation-dolby.so libstagefright_foundation-v33.so \
            || { warn "addon Dolby: libstagefright_foundation-v33 gagal dibuat"; return 1; }
        chmod 755 "$st/bin/hw/vendor.dolby.hardware.dms@2.0-service"
        if ! addon_deps dolby "$d/stage" "$vend" "$B_FS/odm" "$P_FS/system/system" "$P_FS/system_ext"; then
            warn "addon Dolby DILEWATI: blob Dolby butuh library yang tidak ada di vendor base (daftar MISSING di atas)"
            return 1
        fi
        # audio_effects.xml: efek Dolby + volume listener (ganti *_helper bawaan)
        local fx=()
        while IFS= read -r -d '' f; do fx+=("$f"); done < <(find "$vend/etc" "$B_FS/odm/etc" -name 'audio_effects*.xml' -print0 2>/dev/null || true)
        if [[ ${#fx[@]} -eq 0 ]]; then warn "addon Dolby DILEWATI: audio_effects.xml tidak ditemukan di vendor/odm"; return 1; fi
        for f in "${fx[@]}"; do
            cp "$f" "$d/fx.tmp"
            if ! python3 "$SCRIPT_DIR/addon_tool.py" effects "$d/fx.tmp" dap=libswdap.so dvl=libdlbvol.so \
                    gamedap=libswgamedap.so vqe=libswvqe.so \
                    --effect dap=dap:9d4921da-8225-4f29-aefa-39537a04bcaa \
                    --effect dlb_music_listener=dvl:40f66c8b-5aa5-4345-8919-53ec431aaa98 \
                    --effect dlb_ring_listener=dvl:21d14087-558a-4f21-94a9-5002dce64bce \
                    --effect dlb_alarm_listener=dvl:6aff229c-30c6-4cc8-9957-dbfe5c1bd7f6 \
                    --effect dlb_system_listener=dvl:874db4d8-051d-4b7b-bd95-a3bebc837e9e \
                    --effect dlb_notification_listener=dvl:1f0091e3-6ad8-40fe-9b09-5948f9a26e7e \
                    --effect dlb_voice_call_listener=dvl:58d13383-b41d-05df-d94e-bb23db293260 \
                    --effect gamedap=gamedap:3783c334-d3a0-4d13-874f-0032e5fb80e2 \
                    --effect vqe=vqe:64a0f614-7fa4-48b8-b081-d59dc954616f \
                    --drop-helpers > "$d/fx.log" 2>&1; then
                warn "addon Dolby: ${f#"$B_FS"/} tidak bisa diubah ($(tail -n1 "$d/fx.log")), dilewati"
                continue
            fi
            addon_backup "$f"; cat "$d/fx.tmp" > "$f"; n=$((n + 1))
            log "  ${f#"$B_FS"/}: $(tail -n1 "$d/fx.log")"
        done
        [[ $n -gt 0 ]] || { warn "addon Dolby DILEWATI: tidak ada audio_effects.xml yang bisa diubah"; addon_rollback; return 1; }

        # pasang vendor
        while IFS= read -r -d '' f; do
            rel=${f#"$st"/}
            addon_install "$f" "$vend/$rel"
        done < <(find "$st" -type f -print0)
        rels=(etc/dolby)
        while IFS= read -r -d '' f; do
            rel=${f#"$st"/}
            case $rel in bin/hw/vendor.dolby.hardware.dms@2.0-service) rels+=("$rel=u:object_r:hal_dms_default_exec:s0") ;; *) rels+=("$rel") ;; esac
        done < <(find "$st" -type f -print0 | sort -z)
        addon_ctx "$B_FS" vendor "${rels[@]}" || true
        addon_backup "$vend/build.prop"
        set_prop "$vend/build.prop" ro.vendor.dolby.dax.version DAX3_3.7.0.8_r1
        set_prop "$vend/build.prop" vendor.audio.dolby.ds2.hardbypass false
        set_prop "$vend/build.prop" vendor.audio.dolby.ds2.enabled false
        # sepolicy + contexts runtime
        addon_sepolicy "$ADDON_DATA_DIR/dolby/sepolicy.cil" \
            --each "CLIENT=audioserver,hal_audio_default,mediacodec,system_server,$(app_domains | tr ' ' ',')" || {
            warn "addon Dolby: sepolicy tidak bisa ditambahkan -> dibatalkan"; addon_rollback; return 1; }
        addon_append_line "$vend/etc/selinux/vendor_file_contexts" '/(vendor|system/vendor)/bin/hw/vendor\.dolby\.hardware\.dms@2\.0-service u:object_r:hal_dms_default_exec:s0'
        addon_append_line "$vend/etc/selinux/vendor_file_contexts" '/data/vendor/dolby(/.*)? u:object_r:vendor_data_file:s0'
        addon_append_line "$vend/etc/selinux/vendor_hwservice_contexts" 'vendor.dolby.hardware.dms::IDms u:object_r:hal_dms_hwservice:s0'
    fi

    # UI: DaxUI + daxService (LunarisDolby hanya ada sebagai source Kotlin/Compose, butuh build AOSP)
    if [[ ! -d $se ]]; then
        warn "addon Dolby: system_ext donor tidak diekstrak -> UI Dolby tidak dipasang"
    else
        donor_pkgs=$(python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" | cut -f1 || true)
        # shellcheck disable=SC2086  # daftar package dipisah spasi
        addon_remove_pkgs "addon Dolby" $DOLBY_REMOVE_PKGS
        local apps=$DOLBY_APPS
        donor_ui=$(grep -i 'dolby' <<< "$donor_pkgs" | grep -vxF -e com.dolby.daxappui -e com.dolby.daxservice | head -n1 || true)
        if [[ ${DOLBY_UI,,} == dax ]]; then
            log "  DOLBY_UI=dax: DaxUI + daxService dipasang"
        elif grep -qxF "$LUNARIS_DOLBY_PKG" <<< "$donor_pkgs"; then
            donor_ui=$LUNARIS_DOLBY_PKG
            ok "addon Dolby: ROM donor sudah punya Lunaris Dolby ($LUNARIS_DOLBY_PKG) -> dipakai, DaxUI/daxService tidak dipasang"
            apps=""
        elif addon_lunaris "$d"; then
            if [[ -n $donor_ui ]]; then
                # shellcheck disable=SC2046  # daftar package UI Dolby donor lain
                addon_remove_pkgs "addon Dolby (UI Dolby donor diganti Lunaris)" $(grep -i 'dolby' <<< "$donor_pkgs" \
                    | grep -vxF -e com.dolby.daxappui -e com.dolby.daxservice -e "$LUNARIS_DOLBY_PKG" || true)
            fi
            donor_ui="$LUNARIS_DOLBY_PKG (Lunaris Dolby)"
            apps=""
            serels+=("${LUNARIS_RELS[@]}")
        elif [[ -n $donor_ui ]]; then
            ok "addon Dolby: Lunaris tidak bisa dipasang, UI Dolby bawaan donor ($donor_ui) yang dipakai"
            apps=""
        else
            warn "addon Dolby: Lunaris Dolby tidak bisa dipasang (lihat pesan di atas) -> pakai DaxUI + daxService"
        fi
        for x in $apps; do
            app=${x%%:*}; pkg=${x#*:}
            if grep -qxF "$pkg" <<< "$donor_pkgs"; then log "  $pkg sudah ada di ROM donor, tidak disalin"; continue; fi
            mkdir -p "$d/stage/se/priv-app/$app"
            cp "$src/system_ext/priv-app/$app/$app.apk" "$d/stage/se/priv-app/$app/"
            rc=0; addon_sign "$d/stage/se/priv-app/$app" || rc=$?
            case $rc in
                0) log "  $app: kunci platform donor (test-key AOSP) -> platform_app" ;;
                2) log "  $app: kunci asli dipertahankan, jalan sebagai priv_app (donor memakai kunci privat)" ;;
                *) warn "  $app: gagal ditandatangani, dilewati"; continue ;;
            esac
            rm -rf "$se/priv-app/$app"
            addon_install "$d/stage/se/priv-app/$app" "$se/priv-app/$app"
            python3 "$SCRIPT_DIR/apk_index.py" --perms "$se/priv-app/$app/$app.apk" > "$d/perms_$app.txt" 2>/dev/null || true
            f="$se/etc/permissions/privapp-$pkg.xml"
            addon_backup "$f"; addon_new "$f"; addon_mkdir "$(dirname "$f")"
            python3 "$SCRIPT_DIR/addon_tool.py" allowlist "$pkg" "$f" "$d/perms_$app.txt" "$src/system_ext/etc/permissions/privapp-$pkg.xml" >/dev/null
            serels+=("priv-app/$app" "priv-app/$app/$app.apk" "etc/permissions/privapp-$pkg.xml")
            for f in "$src/system_ext/etc/sysconfig/"*"-$pkg.xml"; do
                [[ -f $f ]] || continue
                addon_install "$f" "$se/etc/sysconfig/$(basename "$f")"
                serels+=("etc/sysconfig/$(basename "$f")")
            done
        done
        if [[ ${#serels[@]} -gt 0 ]]; then addon_ctx "$P_FS" system_ext "${serels[@]}" || true; fi
    fi
    ADDON_DONE+=(dolby)
    if is_true "$have_hal"; then ok "addon Dolby: UI terpasang (HAL dari vendor base)"
    else ok "addon Dolby terpasang: HAL dms@2.0 + efek DAP/volume leveler/game/VQE + UI ${donor_ui:-DaxUI}"; fi
}

# Lunaris Dolby (org.lunaris.dolby, sharedUserId=android.uid.system) -> system_ext/priv-app/LunarisDolby.
# 0 = terpasang (LUNARIS_RELS berisi path untuk label SELinux), 1 = tidak bisa (alasan sudah dicetak)
LUNARIS_RELS=()
addon_lunaris() { # workdir
    local d=$1 src=$LUNARIS_DOLBY_APK apk st se="$P_FS/system_ext" pkg uid f
    LUNARIS_RELS=()
    if [[ -z $src ]]; then src="$ADDON_DATA_DIR/dolby/LunarisDolby.apk"; fi
    mkdir -p "$d/lunaris"
    if [[ $src =~ ^https?:// ]]; then
        apk="$d/lunaris/LunarisDolby.apk"
        dl_curl "$src" "$apk" || { warn "addon Dolby: unduh Lunaris Dolby gagal ($src)"; return 1; }
    else
        apk=$src
        [[ -f $apk ]] || { warn "addon Dolby: APK Lunaris Dolby tidak ada ($apk). Isi env LUNARIS_DOLBY_APK atau taruh di addons/dolby/LunarisDolby.apk"; return 1; }
    fi
    pkg=$(python3 "$SCRIPT_DIR/apk_index.py" --info "$apk" 2>/dev/null || true)
    uid=${pkg#*$'\t'}; pkg=${pkg%%$'\t'*}
    if [[ $pkg != "$LUNARIS_DOLBY_PKG" ]]; then warn "addon Dolby: APK Lunaris berisi package '$pkg', bukan $LUNARIS_DOLBY_PKG"; return 1; fi
    # APK system yang di-dexpreopt sering tanpa classes.dex (oat-nya terikat framework ROM asal) -> tidak bisa dipakai
    if ! python3 -c 'import sys,zipfile; sys.exit(0 if "classes.dex" in zipfile.ZipFile(sys.argv[1]).namelist() else 1)' "$apk"; then
        warn "addon Dolby: APK Lunaris tanpa classes.dex (dex di-strip saat build ROM asal), tidak bisa dipakai di ROM lain"
        return 1
    fi
    st="$d/stage/lunaris/LunarisDolby"
    rm -rf "$st"; mkdir -p "$st"; cp "$apk" "$st/LunarisDolby.apk"
    # sharedUserId=android.uid.system: PackageManager menolak APK yang kuncinya beda dengan kunci platform
    if ! platform_resign "$st"; then
        warn "addon Dolby: Lunaris Dolby butuh kunci platform ROM donor (sharedUserId=$uid), donor ditandatangani kunci privat ($DONOR_PLATFORM_CERT) -> tidak bisa dipasang"
        return 1
    fi
    rm -rf "$se/priv-app/LunarisDolby"
    addon_install "$st" "$se/priv-app/LunarisDolby"
    for f in privapp-permissions-dolby.xml:permissions preinstalled-packages-platform-dolby.xml:sysconfig; do
        [[ -f $ADDON_DATA_DIR/dolby/${f%%:*} ]] || continue
        addon_install "$ADDON_DATA_DIR/dolby/${f%%:*}" "$se/etc/${f#*:}/${f%%:*}"
        LUNARIS_RELS+=("etc/${f#*:}/${f%%:*}")
    done
    LUNARIS_RELS+=(priv-app/LunarisDolby priv-app/LunarisDolby/LunarisDolby.apk)
    ok "addon Dolby: Lunaris Dolby dipasang (system_ext/priv-app/LunarisDolby, kunci platform donor -> system_app)"
    return 0
}

# batalkan addon: tanpa argumen = addon yang sedang dipasang ($ADDON_CUR), "all" = semua addon
# (dipanggil sepolicy_compile_check kalau sepolicy gabungan gagal di-compile karena baris addon).
# Urutan mundur: file baru dihapus, file yang diubah dikembalikan ke keadaan sebelum addon.
# touch sampling rate tinggi: driver fts_spi + xiaomi_touch dari vendor_dlkm LineageOS ingres.
# Mode tinggi = bump_sample_rate 1 (fts_set_report_rate 0x01); Hz-nya ditentukan firmware panel.
addon_touchrate() {
    local vs="$B_FS/vendor/etc/selinux" rc="$B_FS/vendor/etc/init/port-touch-rate.rc"
    ADDON_CUR=touchrate
    if ! grep -qs '"/devices/virtual/touch/touch_dev/bump_sample_rate" (u object_r vendor_sysfs_touch ' "$vs/vendor_sepolicy.cil"; then
        warn "addon touchrate: vendor base tidak punya node bump_sample_rate (vendor_sysfs_touch), dilewati"
        return 1
    fi
    addon_install "$ADDON_DATA_DIR/touchrate/port-touch-rate.rc" "$rc"
    chmod 644 "$rc"
    addon_ctx "$B_FS" vendor etc/init/port-touch-rate.rc || true
    addon_sepolicy "$ADDON_DATA_DIR/touchrate/sepolicy.cil" || { addon_rollback touchrate; return 1; }
    ADDON_DONE+=(touchrate)
    ok "addon touchrate: mode sampling sentuh tinggi aktif saat boot"
}

addon_rollback() {
    local who=${1:-$ADDON_CUR} i x name f b keepf=() keepb=() done=()
    for (( i=${#ADDON_BACKUPS[@]}-1; i>=0; i-- )); do
        x=${ADDON_BACKUPS[$i]}; name=${x%%|*}; x=${x#*|}; f=${x%%|*}; b=${x#*|}
        if [[ $who == all || $name == "$who" ]]; then
            if [[ -e $b ]]; then rm -rf "$f"; cp -a "$b" "$f"; fi
        else keepb=("${ADDON_BACKUPS[$i]}" "${keepb[@]}"); fi
    done
    for (( i=${#ADDON_FILES[@]}-1; i>=0; i-- )); do
        x=${ADDON_FILES[$i]}; name=${x%%|*}; f=${x#*|}
        if [[ $who == all || $name == "$who" ]]; then rm -rf "$f"
        else keepf=("${ADDON_FILES[$i]}" "${keepf[@]}"); fi
    done
    for x in "${ADDON_DONE[@]}"; do
        if [[ $who != all && $x != "$who" ]]; then done+=("$x"); fi
    done
    ADDON_BACKUPS=("${keepb[@]}"); ADDON_FILES=("${keepf[@]}"); ADDON_DONE=("${done[@]}")
}

run_addons() {
    local a list
    list=${ADDONS//,/ }
    if [[ -z ${list// /} || ${list,,} == none ]]; then log "addons: tidak ada (ADDONS=none)"; return 0; fi
    mkdir -p "$WORK/addons"
    for a in $list; do
        case ${a,,} in
            none) ;;
            miuicamera|miui-camera|miui_camera) addon_miuicamera || warn "addon MiuiCamera tidak dipasang (lihat pesan di atas)" ;;
            dolby|dolby-atmos|dax) addon_dolby || warn "addon Dolby tidak dipasang (lihat pesan di atas)" ;;
            touchrate|touch-rate|htpr) addon_touchrate || warn "addon touchrate tidak dipasang (lihat pesan di atas)" ;;
            *) warn "ADDONS: '$a' tidak dikenal (pilihan: miuicamera dolby touchrate none)" ;;
        esac
    done
    if [[ ${#ADDON_DONE[@]} -gt 0 ]]; then ok "addons terpasang: ${ADDON_DONE[*]}"; fi
}
