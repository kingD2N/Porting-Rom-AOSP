# devices/ingres

File di sini ditimpa ke hasil ekstrak sebelum dipack, dengan susunan folder sama seperti di ROM:

```
devices/ingres/product/...      -> /product
devices/ingres/system_ext/...   -> /system_ext
devices/ingres/system/system/... -> /system (image system = system-as-root, jadi /system/etc ada di system/system/etc)
devices/ingres/vendor/...       -> /vendor (vendor ROM base)
devices/ingres/odm/...          -> /odm
```

Sudah terisi: `product/overlay/*.apk` = 15 RRO ingres hasil `scripts/build_rro.sh` (sumber di `rro/`, lihat README utama).

Contoh lain:

- `product/etc/displayconfig/display_id_XXXX.xml` - displayconfig panel ingres
- `vendor/etc/fstab.qcom` - fstab yang sudah diedit manual

File `.gitkeep` dan `README*` diabaikan.
