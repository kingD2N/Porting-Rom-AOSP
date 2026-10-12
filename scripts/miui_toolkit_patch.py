#!/usr/bin/env python3
"""
miui_toolkit_patch.py - tambal port.sh toraidl/hyperos_port supaya bisa port MIUI 14 (Android 13)
ke ingres, bukan hanya HyperOS (Android 14/15). Dipakai workflow port-miui-ingres.yml.

  miui_toolkit_patch.py TOOLKIT_DIR

Perubahan (idempoten, gagal kalau baris acuan tidak ditemukan = versi toolkit berubah):
1. MIUI 14 tidak punya partisi mi_ext -> versi ROM donor diambil dari build.prop product/system
   (ro.product.build.version.incremental / ro.system.build.version.incremental), bukan
   ro.mi.os.version.incremental.
2. Kode device di versi (mis. V14.0.4.0.TLJxxXM): Android 13 = awalan T (toolkit hanya kenal U/V).
3. Cek arah Treble: system donor lebih tua dari vendor base -> berhenti (pasti bootloop).
4. Nama paket: "miui" untuk donor MIUI 14 (toolkit selalu menulis "hyperos").
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
        '    base_device_code=T$(echo $base_rom_version | cut -d "." -f 5 | cut -c 2-)\n')

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

    open(path, "w", encoding="utf-8").write(s)
    print("port.sh ditambal: MIUI 14 (tanpa mi_ext), kode versi Android 13, cek versi Treble, nama paket")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    sys.exit(patch(sys.argv[1].rstrip("/") + "/port.sh"))
