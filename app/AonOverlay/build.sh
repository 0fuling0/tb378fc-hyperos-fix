#!/bin/bash
# 构建 ⑧c 的 RRO（AonOverlay.apk）—— 只覆盖 com.miui.rom 里三个 AON bool。
# 用和 TbFix 同一把签名密钥（penwake.jks），省得再管一份。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SDK="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
BT="${BT_DIR:-$SDK/build-tools/37.0.0}"
PLATFORM="${ANDROID_PLATFORM:-android-36}"
AJ="$SDK/platforms/$PLATFORM/android.jar"
KS="$HERE/../TbFix/penwake.jks"
OUT="$HERE/build"

[ -x "$BT/aapt2" ] || { echo "找不到 aapt2：$BT" >&2; exit 1; }
[ -f "$AJ" ] || { echo "找不到 android.jar：$AJ" >&2; exit 1; }
[ -f "$KS" ] || { echo "找不到签名密钥：$KS" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
echo "== aapt2 compile"
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
echo "== aapt2 link"
"$BT/aapt2" link -o "$OUT/unsigned.apk" -I "$AJ" --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 30 --target-sdk-version 36 --auto-add-overlay "$OUT/res.zip"
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
echo "== sign"
"$BT/apksigner" sign --ks "$KS" --ks-key-alias penwake --ks-pass pass:penwake \
    --key-pass pass:penwake --out "$HERE/AonOverlay.apk" "$OUT/aligned.apk"
"$BT/aapt2" dump badging "$HERE/AonOverlay.apk" | head -2
ls -l "$HERE/AonOverlay.apk"
