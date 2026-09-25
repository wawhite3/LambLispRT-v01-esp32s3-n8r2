#!/usr/bin/env bash
# Copyright 2026 by Frobenius Norm LLC 2026-09-21
#
##$fetch_docs.sh.  Re-download the ESP32-4848S040 (AITRIP/Guition 480x480) documentation set.
##$  vendor/ and factory_firmware/ come from the MANUFACTURER's own file host; community/ and web/
##$  from third parties.  Rewrites MANIFEST.tsv with a sha256 per file.  Idempotent.  Needs network.
##$  --keep-zip leaves the 87 MB archive in /tmp for inspection.  Nothing in the build depends on it.
#
#! THE MANUFACTURER'S HOST IS SCRIPTABLE.  AN EARLIER VERSION OF THIS FILE ASSERTED IT WAS NOT.
#! That claim ("a .zip behind a JS download page -- no stable URL, not fetchable by script") was
#! written from looking at the page and never tested, and it was wrong in the expensive direction:
#! it justified sourcing the vendor files from two GitHub repos that had unpacked an OLDER revision.
#! pan.jczn1688.com serves a JSON manifest and content-addressed shards:
#!
#!     GET /api/manifest/<path>        -> {size, shard_count, shards:[{seq,sha256,size,url}]}
#!     GET /s/<sha256>                 -> that shard, with header 'X-Gdisk-Fetch: 1'
#!
#! Every shard is named by its own sha256, so the download is self-verifying -- strictly better
#! provenance than a mirror, which can only be trusted, not checked.
#!
#! WHAT THE MIRROR COST US, MEASURED 2026-09-21 by diffing the two:
#!   * NO SCHEMATIC.  '5-IO pin distribution/1.png' and '2.png' are Jingcai's 2-sheet circuit
#!     diagram and are ABSENT from both GitHub repos.  On their strength two statements in our own
#!     board JSON were wrong -- see vendor/5-IO_pin_distribution/SCHEMATIC_FINDINGS.md.
#!   * OLDER FIRMWARE.  The archive ships 86Switch_onoff_v1.3.bin and JC4848W540C_I_W-V2.1-NEWUI.bin;
#!     the mirror has neither, only an older 86switch_onoff.bin.
#!   * MANGLED TEXT.  4 of 22 mirrored files differ from the factory originals -- all text, sizes
#!     consistent with CRLF->LF conversion in transit.  All 18 binaries were identical, which is why
#!     "byte-identical" looked true until someone diffed the text.
#!
#! DELIBERATELY NOT EXTRACTED: flash_download_tool_3.9.3 (a 16 MB Windows .exe plus ~150 stale burn
#! logs carrying third-party MAC addresses), the WinHex/CH340/sscom .rar bundles, the LVGL font and
#! image C blobs, and the bundled Arduino Libraries tree.  ~55 MB documenting nothing.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
KEEP_ZIP=0; [ "${1:-}" = "--keep-zip" ] && KEEP_ZIP=1

PAN=https://pan.jczn1688.com
REL='ESP32 module/4.0inch_ESP32-4848S040.zip'
ZIP=/tmp/4.0inch_ESP32-4848S040.zip
NM=https://raw.githubusercontent.com/NorthernMan54/ESP32-4848S040/main
FS=https://raw.githubusercontent.com/FigueiredoStable/LovyanGFX-GUITION-ESP32-4848S040/main

#! Fail loud.  A GitHub 404 body is ~14 bytes of text; without this check it lands where a
#! datasheet should be and nothing ever notices.
get() {
  local url="$1" out="$2" code
  local enc; enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=":/"))' "$url")
  mkdir -p "$(dirname "$out")"
  code=$(curl -sS -L -m 180 --retry 3 -w '%{http_code}' -o "$out" "$enc") || { echo "FAIL curl  $out" >&2; return 1; }
  [ "$code" = 200 ] || { echo "FAIL http $code  $out" >&2; rm -f "$out"; return 1; }
  [ "$(stat -c%s "$out")" -ge 64 ] || echo "WARN tiny ($(stat -c%s "$out")B)  $out" >&2
  printf '  ok %9sB  %s\n' "$(stat -c%s "$out")" "$out"
}

rm -rf vendor community web factory_firmware

echo "== manufacturer archive: manifest, shards, sha256 =="
PAN="$PAN" REL="$REL" ZIP="$ZIP" python3 - <<'PY'
import json,os,subprocess,hashlib,urllib.parse,sys
PAN,REL,ZIP=os.environ['PAN'],os.environ['REL'],os.environ['ZIP']
if os.path.exists(ZIP):
    print("  cached %s (%s B)" % (ZIP, f"{os.path.getsize(ZIP):,}")); sys.exit(0)
mu="%s/api/manifest/%s" % (PAN, urllib.parse.quote(REL, safe=":/"))
m=json.loads(subprocess.run(["curl","-sS","-L","-m","60",mu],capture_output=True,check=True).stdout)
print("  %s  %s B  %d shards" % (m['name'], f"{m['size']:,}", m['shard_count']))
parts=[]
for s in m['shards']:
    p="/tmp/_gdisk_%s.part" % s['sha256'][:16]
    if not (os.path.exists(p) and os.path.getsize(p)==s['size']):
        subprocess.run(["curl","-sS","-L","--retry","3","-m","900","-H","X-Gdisk-Fetch: 1","-o",p,s['url']],check=True)
    h=hashlib.sha256(open(p,'rb').read()).hexdigest()
    if h!=s['sha256']:
        sys.exit("  FAIL shard %d sha256 mismatch -- refusing to assemble" % s['seq'])
    print("    shard %d  %12s B  sha256 ok" % (s['seq'], f"{s['size']:,}"))
    parts.append(p)
with open(ZIP,'wb') as o:
    for p in parts: o.write(open(p,'rb').read())
if os.path.getsize(ZIP)!=m['size']:
    os.remove(ZIP); sys.exit("  FAIL assembled size != manifest size")
for p in parts: os.remove(p)
print("  assembled %s B, verified" % f"{os.path.getsize(ZIP):,}")
PY

echo "== extracting the documentation subset =="
ZIP="$ZIP" python3 - <<'PY'
import zipfile,os
z=zipfile.ZipFile(os.environ['ZIP']); R='4.0inch_ESP32-4848S040/'
#! (archive path, local path).  Local names replace spaces with _ so shell use needs no quoting.
WANT=[
 ('2-Specification/ESP32-4848S040 Specifications-EN.pdf','vendor/2-Specification/ESP32-4848S040_Specifications-EN.pdf'),
 ('3-Structure_Diagram/03.jpg','vendor/3-Structure_Diagram/03.jpg'),
 ('3-Structure_Diagram/Dimensions.jpg','vendor/3-Structure_Diagram/Dimensions.jpg'),
 ('4-Driver_IC_Data_Sheet/Nsiway-NS4168.pdf','vendor/4-Driver_IC_Data_Sheet/Nsiway-NS4168.pdf'),
 ('4-Driver_IC_Data_Sheet/esp32-s3-wroom-1_wroom-1u_datasheet_en.pdf','vendor/4-Driver_IC_Data_Sheet/esp32-s3-wroom-1_wroom-1u_datasheet_en.pdf'),
 ('4-Driver_IC_Data_Sheet/esp32-s3_datasheet_en.pdf','vendor/4-Driver_IC_Data_Sheet/esp32-s3_datasheet_en.pdf'),
 # THE SCHEMATIC -- absent from every mirror.  Named 1.png/2.png by the vendor; renamed here so
 # nobody has to open them to find out what they are.
 ('5-IO pin distribution/1.png','vendor/5-IO_pin_distribution/schematic_sheet1_power_usb_sd_backlight.png'),
 ('5-IO pin distribution/2.png','vendor/5-IO_pin_distribution/schematic_sheet2_esp32_panel_touch_audio.png'),
 ('5-IO pin distribution/4.0 inches IO pin distribution.xlsx','vendor/5-IO_pin_distribution/4.0_inches_IO_pin_distribution.xlsx'),
 ('5-IO pin distribution/ESP32-S3-WROOM-1 Pin definition.png','vendor/5-IO_pin_distribution/ESP32-S3-WROOM-1_Pin_definition_DEVKITC_NOT_THIS_BOARD.png'),
 ('6-User_Manual/Getting started 4.0 Inch.pdf','vendor/6-User_Manual/Getting_started_4.0_Inch.pdf'),
 ('1-Demo/Operating instructions/Operating instructions.txt','vendor/1-Demo/Operating_instructions.txt'),
 ('1-Demo/Operating instructions/huge_app.csv','vendor/1-Demo/huge_app.csv'),
 ('8-Burn operation/Burn operation instructions/Burn operation-1.png','vendor/8-Burn_operation/Burn_operation-1.png'),
 ('8-Burn operation/Burn operation instructions/Burn operation-2.png','vendor/8-Burn_operation/Burn_operation-2.png'),
 ('8-Burn operation/Burn operation instructions/Burn operation-3.png','vendor/8-Burn_operation/Burn_operation-3.png'),
 # demo sources that DECLARE pins -- the factory's own numbers, in code
 ('1-Demo/Demo_Arduino/1_2_4.0_LvglWidgets/4.0_LvglWidgets/4.0_LvglWidgets.ino','vendor/1-Demo/4.0_LvglWidgets.ino'),
 ('1-Demo/Demo_Arduino/1_2_4.0_LvglWidgets/4.0_LvglWidgets/touch.h','vendor/1-Demo/touch.h'),
 ('1-Demo/Demo_Arduino/1_3_switch86_lvgl_music/switch86_lvgl_music/switch86_lvgl_music.ino','vendor/1-Demo/switch86_lvgl_music.ino'),
 ('1-Demo/Demo_Arduino/3_8_WIFI Web Servers Relay/WIFI Web Servers Relay.ino','vendor/1-Demo/WIFI_Web_Servers_Relay.ino'),
 # THE APP THE BOARD SHIPS RUNNING.  The first LambLisp flash destroys it; these are the way back.
 ('8-Burn operation/Burn files/JC4848W540C_I_W-V2.1-NEWUI.bin','factory_firmware/JC4848W540C_I_W-V2.1-NEWUI.bin'),
 ('8-Burn operation/Burn files/86Switch_onoff_v1.3.bin','factory_firmware/86Switch_onoff_v1.3.bin'),
 ('8-Burn operation/Burn files/switch86_lvgl_music.bin','factory_firmware/switch86_lvgl_music.bin'),
 ('8-Burn operation/Burn files/4.0_LvglWidgets.bin','factory_firmware/4.0_LvglWidgets.bin'),
 ('1-Demo/Demo_Arduino/1_1_86switch_onoff/86switch_onoff/build/esp32.esp32.esp32s3/86switch_onoff.ino.bootloader.bin','factory_firmware/86switch_onoff.ino.bootloader.bin'),
 ('1-Demo/Demo_Arduino/1_1_86switch_onoff/86switch_onoff/build/esp32.esp32.esp32s3/86switch_onoff.ino.partitions.bin','factory_firmware/86switch_onoff.ino.partitions.bin'),
]
miss=0
for src,dst in WANT:
    try: data=z.read(R+src)
    except KeyError: print("  MISSING IN ARCHIVE  %s" % src); miss+=1; continue
    os.makedirs(os.path.dirname(dst),exist_ok=True)
    open(dst,'wb').write(data)
    print("  ok %9s B  %s" % (f"{len(data):,}", dst))
if miss: raise SystemExit("  %d wanted file(s) not in the archive -- the vendor revision changed" % miss)
PY

echo "== community: independent pin derivations (corroboration only) =="
get "$NM/README.md"                                   community/NorthernMan54_README.md
get "$NM/platformio.ini"                              community/NorthernMan54_platformio.ini
get "$NM/boards/4848S040.json"                        community/NorthernMan54_board_4848S040.json
get "$NM/lib/Touch_GT911/Touch_GT911.h"               community/NorthernMan54_Touch_GT911.h
get "$NM/lib/Touch_GT911/Touch_GT911.cpp"             community/NorthernMan54_Touch_GT911.cpp
get "$FS/src/LGFX_ESP32S3_RGB_TFT_SPI_ST7701_GT911.h" community/FigueiredoStable_LGFX_ST7701_GT911.h
get "$FS/platformio.ini"                              community/FigueiredoStable_platformio.ini
get "https://raw.githubusercontent.com/esp-arduino-libs/ESP32_Display_Panel/master/docs/board/board_jingcai.md" \
                                                      community/esp-arduino-libs_board_jingcai.md

echo "== web: pages saved as served =="
get "https://devices.esphome.io/devices/guition-esp32-s3-4848s040/" web/esphome_guition-esp32-s3-4848s040.html
get "https://homeding.github.io/boards/esp32s3/panel-4848S040.htm"  web/homeding_panel-4848S040.html
get "https://alaltitov.github.io/Guition-ESP32-S3-4848S040-DOCS/"   web/alaltitov_Guition-4848S040-DOCS.html

echo "== manifest =="
{
  printf '#\tsha256\tbytes\tpath\n'
  find vendor community web factory_firmware -type f | sort | while read -r f; do
    printf '\t%s\t%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$f"
  done
} > MANIFEST.tsv
[ "$KEEP_ZIP" = 1 ] || rm -f "$ZIP"
printf 'fetched %s files\n' "$(($(wc -l < MANIFEST.tsv) - 1))"
du -sh vendor community web factory_firmware
