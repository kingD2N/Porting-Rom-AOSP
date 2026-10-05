# Sumber RRO ingres

Disalin apa adanya (res/ + AndroidManifest.xml) dari:

- https://github.com/Ingres-Centre/android_device_xiaomi_ingres (branch lineage-23.2, commit 5dfea0b) -> overlay/Frameworks, SystemUI, SettingsProvider, Wifi, Nfc
- https://github.com/LineageOS/android_device_xiaomi_sm8450-common (branch lineage-23.2, commit 6783fcf) -> overlay/*ResCommon, FrameworksResTarget, *ResXiaomi

Tidak diambil: FrameworksResUdfps (ingres pakai sidik jari samping), Aperture & Lineage (khusus app/SDK Lineage).
Lisensi sumber: Apache-2.0 (The LineageOS Project).

Build ulang: `TOOLS_DIR=<toolkit> bash scripts/build_rro.sh` -> devices/ingres/product/overlay/*.apk
