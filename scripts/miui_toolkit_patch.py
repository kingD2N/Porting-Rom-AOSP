#!/usr/bin/env python3
"""
miui_toolkit_patch.py - tambal port.sh toraidl/hyperos_port supaya bisa port MIUI 14 (Android 13)
ke ingres, bukan hanya HyperOS (Android 14/15). Dipakai workflow port-miui-ingres.yml.

  miui_toolkit_patch.py TOOLKIT_DIR

Perubahan (idempoten, gagal kalau baris acuan tidak ditemukan = versi toolkit berubah):
1. MIUI 14 tidak punya partisi mi_ext -> versi ROM donor diambil dari build.prop product/system
   (ro.product.build.version.incremental / ro.system.build.version.incremental), bukan
   ro.mi.os.version.incremental.
2. Kode device di versi (mis. V14.0.4.0.TLJxxXM): Android 13 = T, 16 = W, 17 = X (toolkit hanya kenal U/V).
3. Cek arah Treble: system donor lebih tua dari vendor base -> berhenti (pasti bootloop).
4. Nama paket: "miui" untuk donor MIUI 14 (toolkit selalu menulis "hyperos").
5. Base zip gaya xiaomi.eu dari ROM custom (mis. RYUUI ingres) yang berisi images/super.img.zst
   atau super.img utuh, bukan potongan sparse super.img.0..N: dibuka dulu jadi super.img.
6. Donor zip gaya xiaomi.eu / ROM custom MIUI (images/super.img*, mis. LUXE, RYUUI) diterima walau
   nama file tanpa "xiaomi.eu" (toolkit asli juga salah mengecek isi zip base, bukan donor), dan
   super.img utuh / .zst / potongan sparse dibuka seperti base.
7. Kernel custom (env PORT_BOOT_IMG): sebelum paket dibangun, scripts/miui_boot_hook.sh memasang
   kernel itu ke boot.img base HANYA kalau CRC simbolnya cocok dengan modul vendor base.
"""
import sys

MARK = "# [ingres-patch]"


def patch(path):
    s = open(path, encoding="utf-8").read()
    if MARK in s:
        print("port.sh sudah ditambal")
        return 0

    def rep(old, new):
        nonlocal s
        if s.count(old) != 1:
            raise SystemExit("baris acuan tidak ditemukan tepat 1x (toolkit berubah?): %r" % old[:80])
        s = s.replace(old, new)

    old = ('port_mios_version_incremental=$(< build/portrom/images/mi_ext/etc/build.prop grep '
           '"ro.mi.os.version.incremental" | awk \'NR==1\' | cut -d \'=\' -f 2)\n')
    rep(old, old + (
        MARK + " MIUI 14 (Android 13): tanpa mi_ext, versi dari product/system\n"
        "port_is_miui=false\n"
        "if [[ -z $port_mios_version_incremental ]]; then\n"
        "    port_is_miui=true\n"
        "    port_mios_version_incremental=$(< build/portrom/images/product/etc/build.prop grep "
        "\"ro.product.build.version.incremental\" | awk 'NR==1' | cut -d '=' -f 2)\n"
        "    [[ -n $port_mios_version_incremental ]] || port_mios_version_incremental=$(< "
        "build/portrom/images/system/system/build.prop grep \"ro.system.build.version.incremental\" "
        "| awk 'NR==1' | cut -d '=' -f 2)\n"
        "    green \"Donor MIUI (tanpa mi_ext): versi $port_mios_version_incremental\" "
        "\"MIUI port ROM (no mi_ext): version $port_mios_version_incremental\"\n"
        "fi\n"))

    rep('elif [[ $port_android_version == "15" ]];then\n'
        '    base_device_code=V$(echo $base_rom_version | cut -d "." -f 5 | cut -c 2-)\n',
        'elif [[ $port_android_version == "15" ]];then\n'
        '    base_device_code=V$(echo $base_rom_version | cut -d "." -f 5 | cut -c 2-)\n'
        'elif [[ $port_android_version == "13" ]];then  ' + MARK + '\n'
        '    base_device_code=T$(echo $base_rom_version | cut -d "." -f 5 | cut -c 2-)\n'
        'elif [[ $port_android_version == "16" ]];then  ' + MARK + ' HyperOS 3\n'
        '    base_device_code=W$(echo $base_rom_version | cut -d "." -f 5 | cut -c 2-)\n'
        'elif [[ $port_android_version == "17" ]];then  ' + MARK + '\n'
        '    base_device_code=X$(echo $base_rom_version | cut -d "." -f 5 | cut -c 2-)\n')

    old = ('port_android_sdk=$(< build/portrom/images/system/system/build.prop grep '
           '"ro.system.build.version.sdk" |awk \'NR==1\' |cut -d \'=\' -f 2)\n')
    rep(old, old + (
        MARK + " Treble satu arah: system donor tidak boleh lebih tua dari vendor base\n"
        "if [[ -n $base_android_sdk && -n $port_android_sdk && $port_android_sdk -lt $base_android_sdk ]]; then\n"
        "    error \"移植包安卓版本低于底包\" \"PORTROM (SDK $port_android_sdk) is OLDER than BASEROM vendor "
        "(SDK $base_android_sdk): pasti bootloop. Pakai base MIUI/HyperOS dengan Android <= donor\"\n"
        "    exit 1\n"
        "fi\n"))

    rep('os_type="hyperos"\n',
        'os_type="hyperos"\n'
        'if [[ ${port_is_miui:-false} == true ]]; then os_type="miui"; fi  ' + MARK + '\n')

    def super_block(r):
        d = "build/%s/images" % r
        return ('    ' + MARK + ' super.img.zst / super.img utuh (ROM custom) selain super.img.N sparse (xiaomi.eu)\n'
                '    if [[ -f %(d)s/super.img.zst ]]; then\n'
                '        zstd -d --rm -q %(d)s/super.img.zst -o %(d)s/super.img.whole\n'
                '    elif [[ -f %(d)s/super.img ]]; then\n'
                '        mv %(d)s/super.img %(d)s/super.img.whole\n'
                '    fi\n'
                '    if [[ -f %(d)s/super.img.whole ]]; then\n'
                '        if [[ $(head -c4 %(d)s/super.img.whole | od -An -tx1 | tr -d " \\n") == 3aff26ed ]]; then\n'
                '            simg2img %(d)s/super.img.whole %(d)s/super.img\n'
                '            rm -f %(d)s/super.img.whole\n'
                '        else\n'
                '            mv %(d)s/super.img.whole %(d)s/super.img\n'
                '        fi\n'
                '    else\n'
                '        simg2img %(d)s/super.img.* %(d)s/super.img\n'
                '    fi\n'
                '    rm -rf %(d)s/super.img.*\n') % {"d": d}

    rep('    simg2img build/baserom/images/super.img.* build/baserom/images/super.img\n'
        '    rm -rf build/baserom/images/super.img.*\n', super_block("baserom"))

    # 6. donor zip gaya xiaomi.eu / ROM custom
    rep('        elif [[ "${portrom}" == *"xiaomi.eu"* ]] && (unzip -l ${baserom} | grep -q "images/super.img*") ; then\n',
        '        elif unzip -l "${portrom}" | grep -q "images/super.img"; then  ' + MARK + ' zip gaya xiaomi.eu / ROM custom MIUI\n')
    rep("    unzip ${portrom} 'images/super.img.*' -d build/portrom",
        "    unzip ${portrom} 'images/super.img*' -d build/portrom")
    rep('    simg2img build/portrom/images/super.img.* build/portrom/images/super.img\n'
        '    rm -rf build/portrom/images/super.img.*\n', super_block("portrom"))

    rep('if [[ $pack_method == "aosp" ]];then\n',
        MARK + ' kernel custom (dicek CRC vs modul vendor base) sebelum paket dibangun\n'
        'if [[ -n ${PORT_BOOT_IMG:-} && -n ${PORT_BOOT_HOOK:-} ]]; then\n'
        '    bash "$PORT_BOOT_HOOK" "$(pwd)" "$PORT_BOOT_IMG" || true\n'
        'fi\n'
        'if [[ $pack_method == "aosp" ]];then\n')

    open(path, "w", encoding="utf-8").write(s)
    print("port.sh ditambal: MIUI 14 (tanpa mi_ext), kode versi Android 13, cek versi Treble, nama paket, "
          "super.img utuh/.zst (base & donor), donor zip ROM custom MIUI, hook kernel custom")
    return 0


def patch_imgextractor(tk):
    """8. imgextractor.py: deteksi MOTO hanya kalau superblock ext4 tidak di offset normal
    (lihat scripts/imgextractor_compat.py; image ext4 yang memuat byte "MOTO" ikut terhapus)."""
    import os
    p = os.path.join(tk, "bin", "imgextractor", "imgextractor.py")
    if not os.path.isfile(p):
        return
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from imgextractor_compat import OLD, NEW
    s = open(p, encoding="utf-8").read()
    if NEW in s:
        return
    if OLD not in s:
        print("imgextractor.py: pola MOTO tidak ditemukan, tidak ditambal")
        return
    open(p, "w", encoding="utf-8").write(s.replace(OLD, NEW, 1))
    print("imgextractor.py ditambal: deteksi MOTO aman untuk image ext4 biasa")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    tk = sys.argv[1].rstrip("/")
    patch_imgextractor(tk)
    sys.exit(patch(tk + "/port.sh"))
