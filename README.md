# Port AOSP untuk POCO F4 GT (ingres)

Workflow GitHub Actions untuk quick-port ROM **AOSP** (LineageOS, AxionOS, crDroid, Evolution X, dll) dari device lain ke **POCO F4 GT / Redmi K50 Gaming (ingres, SM8450)**. Semua jalan di runner GitHub, jadi cukup dari HP: tempel link ROM, Run workflow, tunggu, download zip.

Diadaptasi dari repo *TEST-BUILD-Porting-HyperOS-Marble* (port HyperOS -> POCO F5). Mesin dasarnya sama (unpack payload/super, ekstrak EROFS/EXT4, patch fstab/vbmeta, cek VINTF/VNDK/linker, bangun super, zip recovery), bagian khusus MIUI diganti logika AOSP.

> **TEST build.** Port lintas device selalu berisiko bootloop atau fitur mati. Backup dulu (mis. pakai modul backup partisi), dan pastikan bisa balik ke ROM sebelumnya lewat OrangeFox.

## Cara kerja

ROM hasil port disusun dari dua ROM:

- **Base (ingres):** semua yang terikat hardware: firmware, `boot`, `vendor_boot`, `dtbo`, `vbmeta`, `vendor`, `odm`, `vendor_dlkm`. Bisa salah satu:
  - **OTA ROM AOSP untuk ingres** (zip berisi `payload.bin`, mis. AxionOS ingres). **Disarankan**: vendor-nya memang dibangun untuk framework AOSP dan biasanya sudah membawa RRO ingres.
  - **Stock MIUI/HyperOS ingres** (fastboot `.tgz`, OTA, atau zip xiaomi.eu). Mirip pasang GSI di vendor stock.
- **Donor (AOSP):** OTA ROM AOSP device lain (zip `payload.bin`). Diambil `system`, `system_ext`, `product`.

Tipe base dideteksi otomatis (`BASE_TYPE: auto`; ada `mi_ext`/props `ro.miui.*` = hyperos).

Lalu `scripts/port.sh` mem-patch bagian yang biasanya bikin port gagal boot:

- **Props:** codename donor diganti `ingres` di props identitas (termasuk `ro.lineage.device`, flavor, versi ROM). Model/brand/manufacturer dari vendor/odm ingres. `ro.product.first_api_level` = ingres (31, rilis Android 12). Density dari base. Props hardware milik vendor/odm yang ditimpa product donor dibuang. Props hardware dari product base disalin lewat allowlist (`PROP_MERGE_ALLOW`), jadi props ROM base (`ro.lineage.*`, `ro.miui.*`) tidak ikut.
- **RRO overlay:** RRO di `/product` dan `/system_ext` menang atas RRO `/vendor`. RRO khas device donor (nama/package memuat codename donor, atau cocok `DEVICE_OVERLAY_GLOBS` = `*ResCommon* *ResTarget*`) dibuang. RRO ingres dari base disalin (base AOSP: yang memuat `ingres` / pola yang sama; base HyperOS: `AospFrameworkResOverlay.apk`). RRO di vendor base otomatis ikut. Overlay donor yang tersisa didaftar di log untuk dicek manual.
- **displayconfig:** kurva brightness panel ingres dari base. Kalau base tidak punya, punya donor (panel lain) dibuang.
- **FCM device:** `compatibility_matrix.device.xml` dari system base, supaya HAL khas ingres dikenali framework donor.
- **Updater dibuang:** app OTA donor (Updater Lineage, dll) menawarkan update untuk device donor. Kalau ter-install di ingres = firmware/boot device lain = brick.
- **VINTF, VNDK, linker:** sama seperti repo asal: matrix FCM level vendor disalin kalau donor tidak kenal, VNDK APEX dari base, `vendor-ndk` dideklarasikan, semua library vendor/odm dicek satu-satu.
- **Cek tambahan (baru):**
  - **sepolicy**: kebijakan gabungan (system donor + vendor ingres) di-compile pakai `secilc` dengan urutan yang sama seperti `init` saat boot. Ini penyebab bootloop-ke-recovery paling umum saat base & donor beda basis (mis. vendor LineageOS + donor AOSP murni). `sepolicy_strict` = build gagal kalau tidak bisa di-compile.
  - **checkvintf** `--check-compat` framework donor vs vendor ingres.
  - **ABI**: vendor ingres masih 32+64-bit; donor 64-bit-only (tanpa `/system/lib`) ditandai.
  - **IMS**: donor tanpa IMS Qualcomm (`org.codeaurora.ims`) ditandai (VoLTE/VoWiFi mati).
- **Flash aman:** partisi kalibrasi/data (`persist`, `modemst1/2`, `fsg`, `frp`, ...) tidak pernah di-flash. Base fastboot Xiaomi: hanya image yang memang di-flash `flash_all.sh`.
- **fstab & vbmeta:** enkripsi `/data` dimatikan (opsional), vendor/odm bisa rw, verity off. Partisi port selalu EROFS, jadi kalau fstab base cuma punya baris `ext4` untuk system/system_ext/product (umum di build AOSP), baris `erofs` ditambahkan otomatis. Sama untuk vendor/odm, karena bisa diturunkan ke EROFS kalau super tidak muat.
- **Pengaman base:** kalau `ro.product.vendor.device` base bukan `ingres`, build dihentikan. Firmware base ikut di-flash, jadi salah base = brick.
- **boot.img:** default memakai boot.img D2N ([`ALL-PROJECT-D2N` release `TES`](https://github.com/kingD2N/ALL-PROJECT-D2N/releases/download/TES/boot.img), kernel `5.10.271-gki-MIX`, header v4). Kosongkan `boot_img_url` untuk memakai kernel ROM base. Boot custom dicek punya ramdisk (ingres tanpa `init_boot`) dan seri kernel sama (5.10), karena modul di `vendor_boot`/`vendor_dlkm` dibuat untuk kernel itu.

## Memilih donor & base

Peluang boot paling besar kalau:

1. **Donor SM8450 (taro)**, mis. ROM untuk Xiaomi 12 (cupid) atau 12 Pro (zeus). SM8475 (12S/mayfly, 12T Pro/diting) masih dekat. Device Qualcomm lain juga bisa, tapi makin banyak HAL yang beda.
2. **Base dan donor sebasis** (sama-sama LineageOS-based, versi Android sama). Vendor LineageOS memakai type sepolicy dari `system_ext` LineageOS; donor non-Lineage sering gagal di cek sepolicy.
3. **Versi Android donor <= versi yang didukung vendor base** (lihat log VINTF).

Donor GSI (satu `system.img`) tidak didukung di sini, flash GSI dengan cara biasa saja.

## Isi zip

```
META-INF/                       installer (cuma flash, tanpa wipe)
images/*.img                    firmware + boot, vendor_boot, dtbo, vbmeta (slot A+B)
images/super.img.zst            super (system/system_ext/product donor + vendor/odm ingres)
```

- **recovery.img tidak ikut**, OrangeFox di HP tetap. (Kalau `vendor_boot` base ternyata membawa ramdisk recovery, log memberi warning.)
- Zip ini **bukan** payload.bin, jadi tidak kena masalah OrangeFox yang gagal flash OTA AOSP (`kInstallDeviceOpenError`); isinya ditulis langsung pakai `dd`.
- Perintah format/wipe di META-INF dinetralkan; kalau masih ada yang lolos, build sengaja gagal.

## Build

1. Fork / upload repo ini ke GitHub.
2. Tab **Actions** -> **Port AOSP -> ingres (Recovery)** -> **Run workflow**.
3. Isi input:

| Input | Isi |
|---|---|
| `base_rom_url` | OTA ROM AOSP ingres (`.zip` payload.bin), atau fastboot MIUI/HyperOS ingres (`.tgz`), atau zip xiaomi.eu ingres |
| `port_rom_url` | OTA ROM AOSP donor (`.zip` berisi `payload.bin`) |
| `super_size` | `9126805504` (super ingres). Cek di HP: `su -c blockdev --getsize64 /dev/block/by-name/super` |
| `ext4_partitions` | `vendor odm` (bisa diedit langsung di HP) |
| `debloat` | path/package tambahan, pisah spasi. Boleh kosong |
| `copy_from_base` | path dari base yang ikut disalin, mis. `product/overlay/FooIngres.apk`. APK `sharedUserId=android.uid.system` dilewati (beda kunci platform) |
| `boot_img_url` | default boot.img D2N (5.10.271-gki-MIX); kosongkan = kernel ROM base |
| `disable_encryption` | `true` untuk test build pertama |
| `rw_mount` | `true` |
| `debug_adb` | `true` selama testing (adb hidup sejak boot) |
| `sepolicy_strict` | `false` = cuma warning; `true` = gagalkan build kalau sepolicy gabungan error |
| `recovery_img_url` | kosongkan |
| `release_repo` | kosong = Artifacts. `owner/repo` = GitHub Release (secret `RELEASE_TOKEN`) |
| `gdrive_upload` | `true` = upload juga ke Google Drive lewat rclone (secret `RCLONE_CONFIG` = isi `rclone.conf`, folder di env `GDRIVE_REMOTE`) |

4. Ambil zip dari **Artifacts** (atau Release / Google Drive).

Kalau gagal, buka step **Port ROM**. Tiap tahap punya header (0/7 sampai 7/7); baris `[warn]`/`[fail]` biasanya langsung menunjuk masalahnya. **Baca hasil cek sepolicy, checkvintf, linker, ABI, IMS sebelum flash.**

## Flash

1. Boot ke OrangeFox.
2. Install zip.
3. **Format Data** (Wipe -> Format Data -> ketik `yes`). Wajib di instalasi pertama.
4. Reboot System. Boot pertama bisa sampai 10 menit (sepolicy di-compile di HP, dexopt).

Slot aktif otomatis diset ke A (semua partisi logical diisi slot A).

## Kalau bootloop

Dengan `debug_adb` aktif, adb hidup sejak awal boot:

```
adb wait-for-device logcat -b all > boot.log
adb shell dmesg > dmesg.log
grep -iE "FATAL|vintf|avc: denied|init: .*failed|hidl|aidl|sepolicy|secilc" boot.log
```

Balik ke recovery sendiri setelah logo = biasanya sepolicy (`init: ... Failed to compile`) atau partisi gagal mount. Cek juga `/sys/fs/pstore/` dari OrangeFox.

## Atur lebih jauh (env di workflow)

| Env | Fungsi |
|---|---|
| `BASE_TYPE` | `auto` / `aosp` / `hyperos` |
| `REPLACE_FROM_BASE` | `overlay displayconfig fcm` |
| `DEVICE_OVERLAY_GLOBS` | pola nama RRO khas device |
| `PROP_MERGE_ALLOW` | regex props base yang disalin (di `scripts/port.sh`) |
| `FIRST_API_LEVEL`, `LCD_DENSITY` | `auto` atau angka |
| `NEVER_FLASH` | partisi yang tidak pernah di-flash (di `scripts/port.sh`) |
| `RECOVERY_SUPER` | `zst` (default) / `raw` |
| `HYPEROS_BASE_OVERLAYS` | RRO yang disalin dari base HyperOS (default `AospFrameworkResOverlay`) |
| `ALLOW_OTHER_BASE` | `true` = izinkan base yang bukan ingres (bahaya, firmware ikut di-flash) |

File yang mau dipaksa ke versi ingres: taruh di `devices/ingres/<partisi>/...` (lihat `devices/ingres/README.md`).

## RRO overlay ingres (`devices/ingres/product/overlay/`)

15 RRO siap pakai, di-build dari device tree [Ingres-Centre/android_device_xiaomi_ingres](https://github.com/Ingres-Centre/android_device_xiaomi_ingres) dan [LineageOS/android_device_xiaomi_sm8450-common](https://github.com/LineageOS/android_device_xiaomi_sm8450-common) (branch `lineage-23.2`):

| APK | Target | Isi |
|---|---|---|
| `FrameworksResIngres` | android | kurva auto-brightness (nits), min/default brightness, cutout kamera, rounded corner, tinggi status bar, `power_profile` |
| `SystemUIResIngres` | SystemUI | padding rounded corner, posisi tombol power (sidik jari samping), pixel pitch |
| `FrameworksResCommon` / `Target` / `Xiaomi` | android | config SM8450: refresh rate 120 Hz, doze/AOD, VoLTE/VoWiFi/5G, color mode, pinner, dll |
| `SystemUIResCommon`, `SettingsResCommon`, `SettingsResXiaomi`, `SettingsProviderResIngres/Xiaomi` | SystemUI, Settings, SettingsProvider | default UI/setting |
| `TelephonyResCommon`, `CarrierConfigResCommon` | phone, carrierconfig | IMS/VoLTE, carrier config |
| `WifiResCommon`, `WifiResIngres`, `NfcResIngres` | wifi.resources, nfc | Wi-Fi 5/6 GHz, SoftAP, NFC |

- Package diberi akhiran `.port` (mis. `android.overlay.ingres.port`), jadi tidak bentrok dengan RRO yang sama di vendor/odm ROM AOSP ingres. Untuk **base HyperOS** RRO ini wajib (vendor stock tidak punya overlay AOSP ini); untuk **base AOSP** ini pengaman, karena RRO di `/product` menang atas sisa overlay donor.
- Tidak diambil: `FrameworksResUdfps` (ingres pakai sidik jari samping), `Aperture`, `LineageResXiaomi`.
- Ditandatangani kunci uji `rro/rro-test.jks`. RRO statis pre-install tidak butuh kunci platform.
- Build ulang dari sumber `rro/` (kalau device tree update): `TOOLS_DIR=<toolkit> bash scripts/build_rro.sh` (butuh java, zipalign, apksigner). Kalau ada RRO yang bikin masalah, hapus APK-nya dari folder ini.

## Susunan repo

```
.github/workflows/port-aosp-ingres.yml   workflow utama
scripts/port.sh                          proses port
scripts/aosp_extras.sh                   overlay, updater, displayconfig, FCM, cek sepolicy/checkvintf/ABI/IMS
scripts/lp_tool.py                       metadata super & payload.bin
scripts/lpunpack_compat.py               jalankan lpunpack.py toolkit di Python 3.13+
scripts/fstab_patch.py                   patch fstab
scripts/prop_merge.py                    salin props hardware (allowlist)
scripts/prop_effective.py                props yang berlaku saat boot (urutan load init)
scripts/vintf_check.py                   cek VINTF vendor vs framework
scripts/linker_check.py                  cek library yang dibutuhkan vendor
scripts/installer_sanitize.py            pastikan installer tidak wipe data
scripts/sparse_split.py                  pecah super (mode installer base)
scripts/apk_index.py                     baca package & sharedUserId APK
scripts/build_rro.sh                     build RRO dari rro/ -> devices/ingres/product/overlay/
rro/                                     sumber RRO ingres (res/ + manifest, dari device tree)
scripts/update-binary.in                 installer recovery
debloat_packages.txt                     daftar debloat
devices/ingres/                          file khusus ingres
```

## Kredit

- Repo asal port HyperOS -> marble
- [toraidl/hyperos_port](https://github.com/toraidl/hyperos_port) (toolkit: lpmake, extract.erofs, magiskboot, checkvintf, ...)
- [sekaiacg/erofs-utils](https://github.com/sekaiacg/erofs-utils)

---

Gunakan dengan risiko sendiri. Kalau bootloop: OrangeFox -> flash ROM sebelumnya / fastboot ROM.
