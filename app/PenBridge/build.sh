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

STUB="$HERE/stub-patches"
if [ -d "$STUB" ]; then
  echo "== javac (Xposed 桩：编译用，不进 dex)"
  mkdir -p "$OUT/stub"
  javac -nowarn -encoding UTF-8 -classpath "$AJ" -d "$OUT/stub" $(find "$STUB" -name '*.java')
  STUB_CP="$OUT/stub:"
else
  STUB_CP=""
fi

echo "== javac"
javac -nowarn -encoding UTF-8 -classpath "$AJ:$STUB_CP$OUT/gen" -d "$OUT/classes" \
  $(find "$HERE/src" -name '*.java') $(find "$OUT/gen" -name '*.java')

echo "== d8（过滤掉 de/robv/android/xposed 桩）"
CLASSES=()
while IFS= read -r f; do
  rel="${f#"$OUT"/classes/}"
  case "$rel" in de/robv/android/xposed/*) continue ;; esac
  CLASSES+=("$f")
done < <(find "$OUT/classes" -name '*.class')
"$BT/d8" --min-api 30 --lib "$AJ" --output "$OUT/dex" "${CLASSES[@]}" >/dev/null

echo "== assemble"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -0 "$OUT/unsigned.apk" classes.dex)
# LSPosed 入口 + 作用域（只有模块才需要，普通应用多这两个文件也无害）
[ -d "$HERE/assets" ] && (cd "$HERE" && zip -q "$OUT/unsigned.apk" assets/xposed_init)
[ -d "$HERE/META-INF/xposed" ] && (cd "$HERE" && zip -q "$OUT/unsigned.apk" META-INF/xposed/scope.list)
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "== sign"
"$BT/apksigner" sign --ks "$KS" --ks-key-alias penwake \
  --ks-pass pass:penwake --key-pass pass:penwake --v4-signing-enabled false \
  --out "$HERE/PenBridge.apk" "$OUT/aligned.apk"

ls -l "$HERE/PenBridge.apk"
echo OK
