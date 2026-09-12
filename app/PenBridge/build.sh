#!/usr/bin/env bash
# 构建 PenBridge.apk —— 手写笔 BLE 唤醒 + 电量读取 + 吸附胶囊转发（模块 bin/ 里那个应用）。
# 直接用 aapt2 + javac + d8 + zipalign + apksigner，不依赖 Gradle。
#
# 产物：app/PenBridge/PenBridge.apk（versionCode 11 / versionName 3.1）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/android-sdk}}"
BT="${BT_DIR:-$SDK/build-tools/37.0.0}"
PLATFORM="${ANDROID_PLATFORM:-android-36}"
AJ="$SDK/platforms/$PLATFORM/android.jar"
KS="$HERE/penwake.jks"
OUT="$HERE/build"
VERSION_CODE=11
VERSION_NAME=3.1

[ -x "$BT/aapt2" ] || { echo "找不到 aapt2：$BT（用 BT_DIR= 指定 build-tools 目录）" >&2; exit 1; }
[ -f "$AJ" ] || { echo "找不到 android.jar：$AJ（用 ANDROID_PLATFORM= 指定平台）" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/gen"

if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias penwake -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass penwake -keypass penwake -dname "CN=PenStylus" >/dev/null 2>&1
fi

echo "== aapt2"
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$AJ" \
  --manifest "$HERE/AndroidManifest.xml" -R "$OUT/res.zip" --auto-add-overlay \
  --java "$OUT/gen" --min-sdk-version 30 --target-sdk-version 30 \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME"

echo "== javac"
javac -nowarn -classpath "$AJ:$OUT/gen" -d "$OUT/classes" \
  $(find "$HERE/src" -name '*.java') $(find "$OUT/gen" -name '*.java')

echo "== d8"
"$BT/d8" --min-api 30 --lib "$AJ" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class') >/dev/null

echo "== assemble"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -0 "$OUT/unsigned.apk" classes.dex)
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "== sign"
"$BT/apksigner" sign --ks "$KS" --ks-key-alias penwake \
  --ks-pass pass:penwake --key-pass pass:penwake --v4-signing-enabled false \
  --out "$HERE/PenBridge.apk" "$OUT/aligned.apk"

ls -l "$HERE/PenBridge.apk"
echo OK
