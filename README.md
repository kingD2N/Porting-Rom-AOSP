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
  - **sepolicy** (secilc 3.11 dibangun di workflow; secilc Ubuntu terlalu tua untuk CIL Android 16. Policycap yang belum dikenal secilc diabaikan khusus untuk cek ini): kebijakan gabungan (system donor + vendor ingres) di-compile pakai `secilc` dengan urutan yang sama seperti `init` saat boot. Ini penyebab bootloop-ke-recovery paling umum saat base & donor beda basis (mis. vendor LineageOS + donor AOSP murni). `sepolicy_strict` = build gagal kalau tidak bisa di-compile.
  - **checkvintf** `--check-compat` framework donor vs vendor ingres.
  - **ABI**: vendor ingres masih membawa library 32-bit. Kalau donor 64-bit only (tanpa `/system/lib`, mis. AOSPA/PenguinOS), dicari daemon/HAL 32-bit nyata di `vendor/bin` & `odm/bin` (cuma itu yang gagal start), dan `ro.product.product.cpu.abilist*` dipaksa 64-bit supaya framework tidak mengira 32-bit didukung. Service rc vendor/odm yang binary-nya 32-bit dinonaktifkan (`disabled`, `critical`/`reboot_on_failure` dan `start`/`exec_start`-nya dikomentari, ditandai `# [port-64only]`), karena binary itu tidak bisa jalan dan sebagian (mis. `boringssl_self_test32`) memicu reboot kalau gagal. Matikan dengan env `DISABLE_32BIT_SERVICES=false`.
  - **Zygote**: vendor ingres mengisi `ro.zygote=zygote64_32` (zygote kedua memakai `app_process32`). Kalau system donor tidak punya `app_process32`, `ro.zygote=zygote64` ditulis di product (dimuat terakhir oleh init), karena dengan `zygote64_32` zygote kedua gagal terus dan me-restart zygote utama (atau tidak start sama sekali kalau `init.zygote64_32.rc` tidak ada) = bootloop. Kalau `init.<ro.zygote>.rc` tidak ada di system donor, build dihentikan (`sepolicy_strict`).
  - **VINTF / dialog "internal problem"**: dialog itu muncul kalau `VintfObject.verifyBuildAtBoot()` gagal. Di Android 16 yang dicek hanya `vendor-ndk`, `system-sdk`, versi `sepolicy` vendor vs `sepolicy-version` framework matrix, dan `kernel-sepolicy-version` (cek kernel config dimatikan, keberadaan HAL tidak dicek). `vintf_check.py` meniru persis cek itu (sumber: `HalManifest::checkCompatibility`, `VintfObject::checkCompatibility`, `android_os_VintfObject.cpp`), jadi `checkvintf` toolkit yang terlalu tua untuk manifest 9.0 tidak dibutuhkan. HAL framework yang diminta vendor tapi tidak ada di donor (mis. `vendor.qti.hardware.sigma_miracast` WFD Qualcomm) dilaporkan terpisah (fiturnya tidak jalan) dan dijadikan `optional="true"`; matikan dengan `VINTF_RELAX=false`.
  - **IMS**: donor tanpa IMS Qualcomm (`org.codeaurora.ims`) ditandai (VoLTE/VoWiFi mati).
  - **Service donor yang bisa me-reboot HP**: service di rc system/system_ext/product donor yang bertanda `critical` / `reboot_on_failure` dan bukan service AOSP standar (biasanya khas device donor) didaftar di log, lengkap dengan binary-nya ada atau tidak. Kalau bootloop setelah logo, cek daftar ini dulu.
- **Fitur khas ingres dari base (`base_extras`, default aktif):** karena system_ext & product diganti donor, aplikasi khas ingres di ROM base LineageOS ikut hilang. Yang disalin balik otomatis (kalau ada di base dan belum ada di donor): **GameKeys** (tombol bahu / shoulder trigger, lewat HAL `vendor.lineage.gamekeys` + `touchinjector` di vendor), **Leds** (LED RGB belakang aw22xxx, lewat HAL `vendor.lineage.leds`) dan **Aperture** (kamera LineageOS, cocok dengan HAL kamera vendor base). Kalau Aperture tersalin, kamera MIUI bawaan donor (`MiuiCamera` / `com.android.camera`, dikalibrasi untuk device donor dan butuh dukungan kamera MIUI di vendor yang tidak ada di LineageOS ingres) beserta overlay & allowlist-nya dibuang otomatis, jadi Aperture menjadi kamera bawaan. Matikan dengan env `DEBLOAT_DONOR_CAMERA=false`. GameKeys dan Leds bertanda tangan kunci platform ROM base, yang berbeda dengan kunci donor:
  - `priv_app`/`platform_app` (plus varian per target SDK di Android 17, mis. `platform_app_36`/`priv_app_36`, dibaca dari policy donor) ditambahkan sebagai client HAL-nya di `system_ext_sepolicy.cil` donor (ikut dicek secilc; kalau bikin compile gagal, baris itu dibuang otomatis).
  - Kalau `framework-res.apk` donor ditandatangani **test-key AOSP publik** (umum di build unofficial), GameKeys & Leds ditandatangani ulang dengan kunci itu -> jadi `platform_app`, semua izinnya terpenuhi.
  - Kalau donor memakai kunci privat: **Leds tetap disalin** (cukup HAL, berjalan sebagai `priv_app`), **GameKeys tidak disalin**. GameKeys memanggil `registerTaskStackListener` (izin `MANAGE_ACTIVITY_TASKS`, hanya untuk kunci platform) saat start tanpa penanganan error, jadi tanpa kunci platform donor app itu crash berulang dan tombol bahu tetap tidak jalan. Fitur yang memakai aplikasi LineageOS lain (LiveDisplay, touch polling rate di LineageParts, Wi-Fi Display/`wfdservice`) tidak ikut dan tidak tersedia di ROM port.
- **Addon MIUI Camera & Dolby Atmos (`addons`, default `miuicamera dolby`):** bahan diambil saat build dari repo Gurinbone (sama dengan yang dipakai build LineageOS ingres), dipasang setelah debloat, lalu ikut dicek secilc.
  - **`miuicamera`**: [android_device_xiaomi_miuicamera-ingres](https://github.com/Gurinbone/android_device_xiaomi_miuicamera-ingres) + [android_vendor_xiaomi_miuicamera-ingres](https://github.com/Gurinbone/android_vendor_xiaomi_miuicamera-ingres) (`lineage-23.2`). `MiuiCamera.apk` (git LFS, ~195 MB, sha256 dicek) -> `system/priv-app/MiuiCamera`, library JNI kamera + `libgui_shim_miuicamera.so` (prebuilt dari `addons/miuicamera/`, source ikut) -> `system/lib64`, `public.libraries-xiaomi.txt`, allowlist privapp, hiddenapi, props `persist.vendor.camera.privapp.list` dkk, dan sepolicy kamera (`addons/miuicamera/sepolicy.cil`) untuk `platform_app` + `priv_app`. Sisi vendor (campostproc, libmialgo) sudah ada di vendor LineageOS ingres. Kamera MIUI bawaan donor (dikalibrasi untuk device donor) selalu dibuang dulu karena package-nya sama. APK di repo sudah di-patch (tanda tangan rusak), jadi ditandatangani ulang: kunci platform donor kalau donor test-key AOSP, selain itu testkey AOSP (jalan sebagai `priv_app`; izin signature-only seperti `INJECT_EVENTS` tidak didapat, fungsi kamera tetap jalan). Aperture tetap ada sebagai cadangan.
  - **`dolby`**: [hardware_dolby](https://github.com/Gurinbone/hardware_dolby) (`Dolby-Vision-2.1`). Ke vendor: HAL `vendor.dolby.hardware.dms@2.0-service` + library DAX, `libstagefright_foundation-v33` (dibuat dari `-dolby`, hanya SONAME beda), efek `libswdap`/`libdlbvol`/`libswgamedap`/`libswvqe` ditambahkan ke semua `audio_effects.xml` SKU (volume helper music/ring/alarm/notification diganti volume listener Dolby, hasilnya sama persis dengan tree Gurinbone), init rc, manifest VINTF, props `ro.vendor.dolby.dax.version`, sepolicy `hal_dms` (`addons/dolby/sepolicy.cil`) + `vendor_file_contexts`/`vendor_hwservice_contexts`. UI Dolby (`dolby_ui`, default `lunaris`), hanya satu yang dipasang karena dua pengontrol efek DAP yang sama saling menimpa: (1) donor sudah punya **Lunaris Dolby** (`org.lunaris.dolby`, mis. AfterLife) -> dipakai apa adanya; (2) APK Lunaris (`lunaris_apk_url`, kosong = `addons/dolby/LunarisDolby.apk`) ditandatangani ulang dengan kunci platform donor lalu dipasang ke `system_ext/priv-app/LunarisDolby` (+ allowlist & sysconfig dari `packages_apps_DolbyUI`). Lunaris memakai `sharedUserId=android.uid.system`, jadi ini **hanya bisa kalau donor ditandatangani test-key AOSP** (mis. PinguinOS); UI Dolby donor lain diganti Lunaris; (3) selain itu UI Dolby bawaan donor, terakhir **DaxUI** + **daxService**. `dolby_ui: dax` = selalu DaxUI. AudioFX/MusicFX donor dibuang (bentrok efek global). Tidak ikut: Dolby Vision, codec2 Dolby, spatializer (butuh library codec2/head-tracker yang tidak ada di vendor LineageOS ingres). `packages_apps_DolbyUI` hanya berupa source Kotlin/Compose (butuh build AOSP), jadi Lunaris dipakai dalam bentuk APK jadi.
  - Pengaman: semua library addon dicek dependensinya (DT_NEEDED) terhadap ROM hasil port; kalau ada yang kurang, addon itu dilewati. Label SELinux file baru ditulis persis (bukan ditebak). Kalau sepolicy gabungan gagal di-compile karena baris addon, **semua addon dibatalkan otomatis** (file, contexts, sepolicy, audio_effects kembali seperti semula) sehingga ROM tetap bisa boot tanpa addon.
- **vendor_boot v4 berfragmen:** first-stage fstab dipatch per fragmen (platform/dlkm/recovery) oleh `scripts/vendor_boot_fstab.py`, tabel fragmen & ukuran ikut diperbarui. (magiskboot toolkit menggabung semua fragmen jadi satu dan tidak memperbarui tabel -> modul dlkm rusak -> bootloop; LineageOS/AxionOS sm8450 memakai fragmen `dlkm`.)
- **Cek ekstrak per path:** setiap entri `fs_config` dicek ada di disk; entri sintetis `lost+found` dari imgextractor (ext4) diabaikan, jadi partisi kecil seperti `odm` ext4 tidak gagal palsu.
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

Input `package_type` memilih format (default `ota`).

**`ota`** - seperti zip ROM AOSP/LineageOS biasa:

```
payload.bin                     full payload A/B (update_engine): boot, vendor_boot, dtbo, vbmeta,
                                vbmeta_system + system/system_ext/product donor + vendor/odm/vendor_dlkm ingres
payload_properties.txt          FILE_HASH / FILE_SIZE / METADATA_HASH / METADATA_SIZE
apex_info.pb                    versi APEX di system donor
META-INF/com/android/metadata   ota-type=AB, pre-device=ingres, post-timestamp, property-files
META-INF/com/android/metadata.pb
META-INF/com/android/otacert
META-INF/port_info.txt          ringkasan build port
```

- Dibuat oleh `scripts/make_ota.py` (tanpa delta_generator): format v2, op `REPLACE_XZ`/`REPLACE` per 2 MiB, group dinamis & ukuran sama dengan payload ROM base, ditandatangani test-key AOSP (recovery memeriksa ada tidaknya tanda tangan, bukan kuncinya). Setelah dibuat, zip dicek ulang (hash, offset, metadata).
- Recovery memasang payload ke **slot tidak aktif** lalu memindah slot; susunan super diatur update_engine dan status OTA lama dibatalkan otomatis.
- `care_map.pb` tidak ada karena hanya dipakai untuk dm-verity, dan verity sengaja dimatikan di ROM port.
- **recovery**: default TWRP D2N ikut di payload dan ditulis ke slot tujuan, jadi sesudah pindah slot HP tetap punya TWRP. Kalau `recovery_img_url` dikosongkan, recovery tidak ikut; pastikan recovery custom terpasang di **kedua slot**.
- Sebagian build OrangeFox/TWRP gagal memasang payload OTA (`kInstallDeviceOpenError` / error 7). Kalau itu terjadi, build ulang dengan `package_type: recovery`.

**`recovery`** - installer shell (cara lama):

```
META-INF/                       installer (cuma flash, tanpa wipe)
images/*.img                    firmware + boot, vendor_boot, dtbo, vbmeta (slot A+B)
images/super.img.zst            super (system/system_ext/product donor + vendor/odm ingres)
```

- recovery: TWRP D2N (default `recovery_img_url`) ditulis ke slot A dan B; kosongkan input itu untuk mempertahankan recovery di HP. Isi ditulis langsung pakai `dd`, slot aktif diset A, status OTA lama dibatalkan.
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
| `package_type` | `ota` (default, zip payload.bin seperti ROM AOSP) atau `recovery` (images + super.img.zst, ditulis dd) |
| `ext4_partitions` | `vendor odm system vendor_dlkm product system_ext` (bisa diedit langsung di HP). Kalau super tidak muat, partisi EXT4 terbesar otomatis jadi EROFS. `vendor_dlkm` dipakai apa adanya dari base (read-only) |
| `debloat` | path/package tambahan, pisah spasi. Boleh kosong |
| `copy_from_base` | path dari base yang ikut disalin, mis. `product/overlay/FooIngres.apk`. APK `sharedUserId=android.uid.system` dilewati (beda kunci platform). priv-app: allowlist izin base + semua izin yang diminta APK ditulis ulang (APK base bertanda tangan platform base, di donor izinnya lewat jalur privileged) |
| `base_extras` | `true` = GameKeys (tombol bahu) + Leds (LED RGB) + Aperture (kamera) dari base LineageOS |
| `dolby_ui` | `lunaris` (default) / `dax`. Lihat addon Dolby di atas |
| `lunaris_apk_url` | URL `LunarisDolby.apk` (APK utuh berisi `classes.dex`). Kosong = `addons/dolby/LunarisDolby.apk` |
| `addons` | `miuicamera dolby` (default). `miuicamera` = MIUI Camera ingres, `dolby` = Dolby Atmos DAX. Kosong / `none` = tanpa addon |
| `boot_img_url` | default boot.img D2N (5.10.271-gki-MIX); kosongkan = kernel ROM base |
| `disable_encryption` | `true` untuk test build pertama |
| `rw_mount` | `true` (hanya partisi EXT4 yang dibangun ulang: system, system_ext, product, vendor, odm. `vendor_dlkm` dari base tetap read-only) |
| `debug_adb` | `true` selama testing (adb hidup sejak boot) |
| `sepolicy_strict` | `true` (default) = build gagal kalau sepolicy gabungan error (pasti bootloop); `false` = cuma warning |
| `recovery_img_url` | default TWRP D2N (`ALL-PROJECT-D2N` release `ingres`, `TWRP_PROJECT_recovery_A16_A17_.img`). Dicek: image boot Android dan tidak lebih besar dari partisi recovery. Kosongkan = recovery HP tidak disentuh |
| `release_repo` | kosong = Artifacts. `owner/repo` = GitHub Release (secret `RELEASE_TOKEN`) |
| `gdrive_upload` | `true` = upload juga ke Google Drive lewat rclone (secret `RCLONE_CONFIG` = isi `rclone.conf`, folder di env `GDRIVE_REMOTE`) |

Link ROM yang didukung: link unduh langsung (GitHub release, server sendiri), **Google Drive** (link `.../file/d/<id>/view` boleh langsung ditempel; file harus *Anyone with the link*), **SourceForge** (link `downloads.sourceforge.net/...?ts=...` yang kedaluwarsa otomatis diubah ke link `/download` yang stabil), **Pixeldrain** (`/u/<id>`), dan **MediaFire**. Sebelum download besar, isi URL dicek: kalau server membalas halaman HTML (link salah, private, kuota Drive habis), build langsung berhenti dengan alasannya.

4. Ambil zip dari **Artifacts** (atau Release / Google Drive).

Kalau gagal, buka step **Port ROM**. Tiap tahap punya header (0/7 sampai 7/7); baris `[warn]`/`[fail]` biasanya langsung menunjuk masalahnya. **Baca hasil cek sepolicy, checkvintf, linker, ABI, IMS sebelum flash.**

## Flash

1. Boot ke OrangeFox.
2. Install zip.
3. **Format Data** (Wipe -> Format Data -> ketik `yes`). Wajib di instalasi pertama.
4. Reboot System. Boot pertama bisa sampai 10 menit (sepolicy di-compile di HP, dexopt).

Zip `ota`: recovery memasang ke slot tidak aktif lalu pindah slot. Zip `recovery`: slot aktif otomatis diset ke A (semua partisi logical diisi slot A), dan status update Virtual A/B lama ikut dibatalkan (setara `fastboot snapshot-update cancel`): isi `/metadata/ota` dihapus (kunci enkripsi `/metadata/vold` tidak disentuh) dan `merge_status` pesan virtual A/B di `misc` direset ke NONE kalau masih menyimpan OTA yang belum selesai. Tanpa ini, OTA lama yang belum selesai merge bisa membuat init memetakan snapshot ke layout super lama -> bootloop.

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
| `MIUICAMERA_DEVICE_REPO`, `MIUICAMERA_VENDOR_REPO`, `MIUICAMERA_BRANCH` | sumber addon MiuiCamera (default Gurinbone, `lineage-23.2`) |
| `DOLBY_REPO`, `DOLBY_BRANCH` | sumber addon Dolby (default Gurinbone/hardware_dolby, `Dolby-Vision-2.1`) |
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
scripts/addons.sh                        addon MIUI Camera & Dolby Atmos (stage, cek dependensi, pasang, rollback)
scripts/addon_tool.py                    helper addon: CIL template -> policy vendor, label SELinux, audio_effects.xml, allowlist
addons/miuicamera/                       sepolicy kamera (CIL) + shim libgui (prebuilt + source)
addons/dolby/                            sepolicy hal_dms (CIL)
scripts/make_ota.py                      bangun zip OTA A/B (payload.bin, payload_properties.txt, apex_info.pb, metadata)
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
scripts/vendor_boot_fstab.py             patch fstab first-stage di vendor_boot v3/v4 (per fragmen)
scripts/fsconfig_check.py                cek hasil ekstrak per path + bersihkan fs_config
scripts/elf_scan.py                      cari executable 32-bit di vendor/odm (donor 64-bit only)
scripts/vintf_relax.py                   jadikan optional HAL framework yang tidak ada di donor (device matrix vendor)
scripts/rc_disable32.py                  nonaktifkan service rc vendor/odm yang binary-nya 32-bit (donor 64-bit only)
scripts/dl_helper.py                     link Google Drive/SourceForge/Pixeldrain/MediaFire -> unduh langsung, tolak HTML
scripts/build_rro.sh                     build RRO dari rro/ -> devices/ingres/product/overlay/
rro/                                     sumber RRO ingres (res/ + manifest, dari device tree)
scripts/update-binary.in                 installer recovery
debloat_packages.txt                     daftar debloat
devices/ingres/                          file khusus ingres
```

## Kredit

- Repo asal port HyperOS -> marble
- [toraidl/hyperos_port](https://github.com/toraidl/hyperos_port) (toolkit: lpmake, extract.erofs, magiskboot, checkvintf, ...)
- [Gurinbone](https://github.com/Gurinbone) (MiuiCamera ingres, hardware_dolby), [Ingres-Centre](https://github.com/Ingres-Centre) (LineageOS ingres)
- [sekaiacg/erofs-utils](https://github.com/sekaiacg/erofs-utils)

---

Gunakan dengan risiko sendiri. Kalau bootloop: OrangeFox -> flash ROM sebelumnya / fastboot ROM.
