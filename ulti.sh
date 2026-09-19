#!/bin/bash
# ============================================================
# ULTI.SH - Build vendor AOSP LineageOS 18.1 Samsung A02
# Full state dari Codespaces kosong sampai titik terakhir kita ngoprek.
# Idempotent: aman dijalanin ulang kalau ada bagian yang gagal di tengah
# (tinggal jalanin lagi dari awal, bagian yang udah fixed bakal no-op).
# ============================================================
set -e
cd /tmp/android_build 2>/dev/null || { mkdir -p /tmp/android_build && cd /tmp/android_build; }

# ============================================================
# BAGIAN 0: SETUP ENVIRONMENT (apt, git, repo tool)
# ============================================================
sudo apt-get update
sudo apt-get install -y \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib \
    git gnupg gperf imagemagick lib32readline-dev \
    lib32z1-dev liblz4-tool libsdl1.2-dev \
    libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool \
    squashfs-tools xsltproc zip zlib1g-dev python3 python3-pip openjdk-8-jdk \
    git-lfs

git config --global user.name "[ISI nama]"
git config --global user.email "[ISI email]"
git config --global color.ui true

mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH=~/bin:$PATH

# ============================================================
# BAGIAN 1: SYNC SOURCE (skip kalau .repo udah ada / udah pernah sync)
# ============================================================
if [ ! -d .repo ]; then
  repo init -u https://github.com/LineageOS/android.git -b lineage-18.1 --git-lfs

  mkdir -p .repo/local_manifests
  cat > .repo/local_manifests/roomservice.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="rdbckp" fetch="https://github.com/cipin23/" />
  <project name="vendor" path="_rdbckp_vendor" remote="rdbckp" revision="a02_vendor">
    <linkfile src="device/samsung/a02" dest="device/samsung/a02" />
    <linkfile src="vendor/samsung/a02" dest="vendor/samsung/a02" />
  </project>
  <project name="186_kernel" path="kernel/samsung/a02" remote="rdbckp" revision="186" />
</manifest>
EOF
fi

repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags

# ============================================================
# BAGIAN 2: GANTI SYMLINK device/vendor JADI FOLDER ASLI
# (Soong module_paths scanner gak follow symlink, bikin "lunch" gagal
# nemuin produk "lineage_a02")
# ============================================================
if [ -L device/samsung/a02 ] || [ -L vendor/samsung/a02 ]; then
  rm -f device/samsung/a02 vendor/samsung/a02
  cp -rL _rdbckp_vendor/device/samsung/a02 device/samsung/a02
  cp -rL _rdbckp_vendor/vendor/samsung/a02 vendor/samsung/a02
fi
# _rdbckp_vendor mesti dihapus - kalau masih ada, Android.bp di dalamnya
# ikut ke-scan Soong dan bentrok modul sama copy-annya di device/vendor
rm -rf _rdbckp_vendor

# Cache glob/module-path Soong bisa nyimpen state symlink lama -> bersihin
rm -rf out/soong/.bootstrap out/soong/.glob out/soong/build.ninja* out/.module_paths

source build/envsetup.sh
lunch lineage_a02-userdebug

VBP="vendor/samsung/a02/Android.bp"
VMK="vendor/samsung/a02/a02-vendor.mk"
DMK="device/samsung/a02/device.mk"

# ============================================================
# BAGIAN 3: FIX KONFLIK INSTALL PATH ("overriding commands for target")
# ============================================================

# 3.1 setprop (bentrok toolbox)
python3 -c "
import re
s=open('$VBP').read()
s=re.sub(r'cc_prebuilt_binary \{\s*name: \"setprop\",.*?\n\}\n', '', s, flags=re.S)
open('$VBP','w').write(s)
"

# 3.2 start (bentrok toolbox)
python3 -c "
import re
s=open('$VBP').read()
s=re.sub(r'cc_prebuilt_binary \{\s*name: \"start\",.*?\n\}\n', '', s, flags=re.S)
open('$VBP','w').write(s)
"

# 3.3 semua tool toolbox + toybox sekaligus
sudo grep -oP '"\K[a-z0-9_]+(?=",?$)' system/core/toolbox/Android.bp | sort -u > /tmp/toolbox_names.txt
python3 -c "
import re
s=open('external/toybox/Android.bp').read()
m=re.search(r'name: \"toybox-defaults-symlinks\".*?symlinks: \[(.*?)\]', s, re.S)
names=re.findall(r'\"([a-z0-9_]+)\"', m.group(1))
open('/tmp/toolbox_names.txt','a').write('\n'.join(names)+'\n')
"
sort -u -o /tmp/toolbox_names.txt /tmp/toolbox_names.txt
python3 -c "
import re
names=[l.strip() for l in open('/tmp/toolbox_names.txt') if l.strip()]
s=open('$VBP').read()
for name in names:
    s=re.sub(r'cc_prebuilt_binary \{\s*name: \"'+re.escape(name)+r'\",.*?\n\}\n', '', s, flags=re.S)
open('$VBP','w').write(s)
"

# 3.4 libwifi-hal.so
python3 -c "
import re
s=open('$VBP').read()
s=re.sub(r'cc_prebuilt_library_shared \{\s*name: \"libwifi-hal_vendor\",.*?\n\}\n', '', s, flags=re.S)
open('$VBP','w').write(s)
"
sed -i '/libwifi-hal_vendor \\/d' "$VMK"

# 3.5 init.a02.rc
python3 -c "
import re
s=open('$VBP').read()
s=re.sub(r'prebuilt_etc \{\s*name: \"init.a02.rc\",.*?\n\}\n', '', s, flags=re.S)
open('$VBP','w').write(s)
"
sed -i '\#rootdir/etc/init.a02.rc:\$(TARGET_COPY_OUT_VENDOR)/etc/init/init.a02.rc#d' "$DMK"

# 3.6 fstab.mt6739
python3 -c "
import re
s=open('$VBP').read()
s=re.sub(r'prebuilt_etc \{\s*name: \"fstab.mt6739\",.*?\n\}\n', '', s, flags=re.S)
open('$VBP','w').write(s)
"
sed -i '\#rootdir/etc/fstab.mt6739:\$(TARGET_COPY_OUT_VENDOR)/etc/fstab.mt6739#d' "$DMK"

# 3.7 semua prebuilt_etc "etc/vintf" (manifest, compatibility_matrix, dst):
#     sub_dir "etc/vintf..." -> "vintf..." + filename eksplisit biar gak
#     collide sama modul XSD-generated nama sama
python3 -c "
import re
p = '$VBP'
s = open(p).read()
s = re.sub(r'sub_dir: \"etc/vintf', 'sub_dir: \"vintf', s)

def add_filename(m):
    block = m.group(0)
    if 'filename:' in block:
        return block
    src_m = re.search(r'src: \"([^\"]*/)?([^\"/]+)\"', block)
    if not src_m:
        return block
    fname = src_m.group(2)
    return block[:-2] + f'    filename: \"{fname}\",\n}}\n'

s = re.sub(r'prebuilt_etc \{\s*name: \"[^\"]+\",\s*owner: \"samsung\",\s*src: \"proprietary/etc/vintf/[^\"]+\",\s*sub_dir: \"vintf[^\"]*\",\s*vendor: true,\s*\}\n', add_filename, s)
open(p, 'w').write(s)
"
rm -rf out/target/product/a02/vendor/etc/vintf/manifest out/target/product/a02/vendor/etc/etc

# 3.8 fs_config_dirs_vendor / fs_config_files_vendor / vendor_seapp_contexts
#     dan modul sepolicy/fs_config lain yang namanya di-generate dinamis
#     di AOSP core (gak kejaring dedup Bagian 4 karena bukan teks literal
#     di source aslinya) - rename semua yang ketemu, sekali jalan
for name in fs_config_dirs_vendor fs_config_files_vendor vendor_seapp_contexts \
            vendor_file_contexts vendor_property_contexts vendor_hwservice_contexts \
            plat_seapp_contexts odm_seapp_contexts vendor_default_prop; do
  if grep -q "name: \"$name\"," "$VBP" 2>/dev/null; then
    sed -i "s/name: \"$name\",/name: \"${name}_samsung\",/" "$VBP"
    sed -i "s/    $name \\\\/    ${name}_samsung \\\\/" "$VMK" "$DMK" 2>/dev/null
  fi
done

# 3.9 Modul cc_prebuilt_library_shared "android.hardware.audio.*" yang
#     bentrok install path sama HAL asli (dibangun dari
#     hardware/interfaces/audio + prebuilts/vndk) - hapus semua, biarin
#     yang asli dari AOSP yang jalan (pola sama kayak libwifi-hal)
for name in android.hardware.audio.common-util_vendor \
            android.hardware.audio.common@2.0-util_vendor \
            android.hardware.audio.common@6.0-util_vendor \
            android.hardware.audio.effect@2.0-impl_vendor \
            android.hardware.audio.effect@6.0-impl_vendor \
            android.hardware.audio@2.0-impl_vendor; do
  python3 -c "
import re
p='$VBP'
s=open(p).read()
s=re.sub(r'cc_prebuilt_library_shared \{\s*name: \"$name\",.*?\n\}\n', '', s, flags=re.S)
open(p,'w').write(s)
"
  sed -i "/$name \\\\/d" "$VMK"
done

# ============================================================
# BAGIAN 4: DEDUP SEMUA MODUL SOONG/MAKE YANG BENTROK NAMA SEKALIGUS
# (error tipe "module X already defined" - beda dari overriding-commands
# di atas, ini bentrok NAMA modul, bukan install path)
# ============================================================
python3 << 'PYEOF'
import re

VBP = 'vendor/samsung/a02/Android.bp'
VMK = 'vendor/samsung/a02/a02-vendor.mk'
DMK = 'device/samsung/a02/device.mk'

print("Scanning seluruh Android.bp + Android.mk di tree (agak lama)...")
proc = __import__('subprocess').run(
    ['bash', '-c', 'grep -rl --include=Android.bp --include=Android.mk -E "name:|LOCAL_MODULE" . 2>/dev/null | grep -v ^./out | grep -v "vendor/samsung/a02/Android.bp"'],
    capture_output=True, text=True)
files = proc.stdout.splitlines()

other_names = set()
for f in files:
    try:
        text = open(f, errors='ignore').read()
    except Exception:
        continue
    for n in re.findall(r'name:\s*"([a-zA-Z0-9_.\-@]+)"', text):
        other_names.add(n)
    for n in re.findall(r'LOCAL_MODULE\s*:=\s*([a-zA-Z0-9_.\-@]+)', text):
        other_names.add(n)

print(f"{len(other_names)} nama modul ditemukan di luar vendor bp")

vbp_text = open(VBP).read()
vbp_names = set(re.findall(r'name:\s*"([a-zA-Z0-9_.\-@]+)"', vbp_text))
conflicts = sorted(vbp_names & other_names)
print(f"{len(conflicts)} modul bentrok: {conflicts}")

for name in conflicts:
    pattern = re.compile(r'(\w+ \{\s*name: )"' + re.escape(name) + r'"(,\s*)')
    def repl(m, name=name):
        return m.group(1) + f'"{name}_vendor"' + m.group(2)
    new_text, count = pattern.subn(repl, vbp_text, count=1)
    if count == 0:
        continue
    vbp_text = new_text
    block_pat = re.compile(r'(name: "' + re.escape(name) + r'_vendor",.*?)(\n\})', re.S)
    bm = block_pat.search(vbp_text)
    if bm and 'filename:' not in bm.group(1) and 'stem:' not in bm.group(1):
        before = vbp_text[:bm.start()]
        type_m = re.search(r'(\w+) \{\s*$', before[-200:])
        field = 'stem' if (type_m and type_m.group(1).startswith('cc_prebuilt')) else 'filename'
        vbp_text = vbp_text[:bm.end(1)] + f'\n    {field}: "{name}",' + vbp_text[bm.end(1):]

open(VBP, 'w').write(vbp_text)

for mkfile in [VMK, DMK]:
    try:
        text = open(mkfile).read()
    except FileNotFoundError:
        continue
    changed = False
    for name in conflicts:
        newtext, n = re.subn(r'(?<![\w.-])' + re.escape(name) + r'(?![\w.-])', name + '_vendor', text)
        if n:
            text = newtext
            changed = True
    if changed:
        open(mkfile, 'w').write(text)

print("Selesai rename modul bentrok:", conflicts)
PYEOF

# 4.1 cc_prebuilt_* gak support "filename:" (cuma prebuilt_etc), harus
#     "stem:". Line-by-line biar gak kepeleset nested brace.
python3 -c "
import re
p = '$VBP'
lines = open(p).read().splitlines(keepends=True)
out = []
current_type = None
for line in lines:
    m = re.match(r'^(\w+) \{', line)
    if m:
        current_type = m.group(1)
    if current_type and current_type.startswith('cc_prebuilt') and 'filename:' in line:
        line = line.replace('filename:', 'stem:')
    out.append(line)
open(p, 'w').write(''.join(out))
"

rm -rf out/target/product/a02/vendor/etc/vintf/manifest out/target/product/a02/vendor/etc/etc
rm -rf out/soong/.bootstrap out/soong/.glob out/soong/build.ninja* out/.module_paths

# ============================================================
# BAGIAN 5: FIX libncurses.so.5 / libtinfo.so.5 (dibutuhin llvm-tblgen)
# ============================================================
sudo apt-get install -y libncurses5 libtinfo5 2>/dev/null || {
  sudo ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5
  sudo ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
}

# ============================================================
# BAGIAN 6: FIX modul "jsonlib" ilang (project cts di-remove tapi
# dibutuhin protologtool) - ambil cts/libs/json doang via sparse checkout
# ============================================================
if [ ! -f cts/libs/json/Android.bp ]; then
  git clone --filter=blob:none --no-checkout --depth 1 -b lineage-18.1 \
    https://github.com/LineageOS/android_cts /tmp/cts_sparse
  cd /tmp/cts_sparse
  git sparse-checkout init --cone
  git sparse-checkout set libs/json
  git checkout
  cd /tmp/android_build
  mkdir -p cts/libs
  cp -r /tmp/cts_sparse/libs/json cts/libs/json
  rm -rf /tmp/cts_sparse
fi

# ============================================================
# BAGIAN 7: PAKE zImage PREBUILT (skip kompilasi kernel dari source)
# [ISI] pastikan file zImage ada duluan di /workspaces/vendor/zImage
# ============================================================
mkdir -p device/samsung/a02/prebuilt
if [ -f /workspaces/vendor/zImage ]; then
  cp /workspaces/vendor/zImage device/samsung/a02/prebuilt/zImage
fi
grep -q "TARGET_PREBUILT_KERNEL" device/samsung/a02/BoardConfig.mk \
  && sed -i 's#TARGET_PREBUILT_KERNEL.*#TARGET_PREBUILT_KERNEL := device/samsung/a02/prebuilt/zImage#' device/samsung/a02/BoardConfig.mk \
  || echo 'TARGET_PREBUILT_KERNEL := device/samsung/a02/prebuilt/zImage' >> device/samsung/a02/BoardConfig.mk

# Arahin TARGET_KERNEL_SOURCE ke path yang gak ada (bukan cuma di-comment)
# biar dipastikan skip. HATI-HATI: ganti PER BARIS (bukan regex \s* lintas
# baris) biar gak numpuk sama baris komentar "# Kernel" di atasnya.
for f in device/samsung/a02/BoardConfig.mk device/samsung/a02/device.mk device/samsung/a02/configs/kernel.mk; do
  python3 -c "
import re
p = '$f'
lines = open(p).read().splitlines(keepends=True)
out = []
for line in lines:
    if re.match(r'^\s*#?\s*TARGET_KERNEL_SOURCE\s*:=\s*kernel/samsung/a02', line):
        out.append('TARGET_KERNEL_SOURCE := kernel/samsung/a02-DISABLED\n')
    else:
        out.append(line)
open(p, 'w').write(''.join(out))
"
done

# ============================================================
# BAGIAN 8: FIX BOARD_VENDOR_SEPOLICY_DIRS / DEVICE_PACKAGE_OVERLAYS
# ke-resolve jadi path absolut "/xxx" (LOCAL_PATH kosong di titik itu,
# bikin Soong panic "unexpected relative path outside directory") -
# hardcode langsung, jangan pake $(LOCAL_PATH) buat baris-baris ini
# ============================================================
sed -i \
  -e 's#BOARD_VENDOR_SEPOLICY_DIRS += \$(LOCAL_PATH)/sepolicy/vendor#BOARD_VENDOR_SEPOLICY_DIRS += device/samsung/a02/sepolicy/vendor#' \
  -e 's#SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += \$(LOCAL_PATH)/sepolicy/private#SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/samsung/a02/sepolicy/private#' \
  -e 's#DEVICE_PACKAGE_OVERLAYS += \$(LOCAL_PATH)/overlay#DEVICE_PACKAGE_OVERLAYS += device/samsung/a02/overlay#' \
  "$DMK"

source build/envsetup.sh
lunch lineage_a02-userdebug
rm -rf out/target/product/a02/obj/KERNEL_OBJ out/target/product/a02/kernel out/target/product/a02/obj/KERNEL*

echo "============================================================"
echo "Selesai sampai titik terakhir. LANJUT: mka vendorimage"
echo "============================================================"

# ============================================================
# TODO - BELUM KELAR (kalau masih muncul):
# ============================================================
# - Modul Soong "generated_kernel_includes" (vendor/lineage/build/soong)
#   sempet gagal manggil headers_install ke kernel/samsung/a02-DISABLED.
#   Kalau masih muncul, investigasi:
#     grep -rn "generated_kernel_includes" vendor/lineage/build/soong/
# - Kemungkinan masih ada modul lain yang "already defined" karena nama
#   di-generate dinamis (kayak fs_config_dirs_vendor kemarin) dan gak
#   kejaring dedup otomatis. Kalau muncul lagi, cari blok-nya manual:
#     grep -n 'name: "<nama_modul>"' vendor/samsung/a02/Android.bp
#   terus rename + cek referensinya di a02-vendor.mk/device.mk.
