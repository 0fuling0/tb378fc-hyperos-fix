#!/usr/bin/env bash
# 构建 PenStylusHook.apk —— LSPosed 模块，把 system_server 里 NVTCapacitivePen 数字板
# 与联想蓝牙笔关联起来，让系统原生笔电量链路复活（低电量提醒 / SystemUI 电量状态）。
#
# 注意：v3.0 的模块包**没有**内置这个 hook（它需要手动在 LSPosed 里启用并勾选「系统框架」），
# 这里保留源码备查/复用。
#
# Xposed API 只是编译期桩：stub-patches/ 里的 de.robv.android.xposed.* 会被 d8 过滤掉，
# 运行时唯一的实现是 LSPosed 自己。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/android-sdk}}"
BT="${BT_DIR:-$SDK/build-tools/37.0.0}"
PLATFORM="${ANDROID_PLATFORM:-android-36}"
AJ="$SDK/platforms/$PLATFORM/android.jar"
STUB_SRC="$HERE/stub-patches"
KS="$HERE/penhook.jks"
OUT="$HERE/build"

[ -x "$BT/aapt2" ] || { echo "找不到 aapt2：$BT（用 BT_DIR= 指定）" >&2; exit 1; }
[ -f "$AJ" ] || { echo "找不到 android.jar：$AJ" >&2; exit 1; }
[ -d "$STUB_SRC" ] || { echo "找不到 Xposed 桩源码：$STUB_SRC" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/stub" "$OUT/gen"

if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias penhook -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass penhook -keypass penhook -dname "CN=PenStylusHook" >/dev/null 2>&1
fi

echo "== aapt2"
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$AJ" \
  --manifest "$HERE/AndroidManifest.xml" -R "$OUT/res.zip" --auto-add-overlay \
  --java "$OUT/gen" --min-sdk-version 31 --target-sdk-version 35 \
  --version-code 2 --version-name 2.0

echo "== stub classes"
javac -nowarn -classpath "$AJ" -d "$OUT/stub" \
  $(find "$STUB_SRC" -name '*.java')

echo "== javac"
javac -nowarn -classpath "$AJ:$OUT/stub:$OUT/gen" -d "$OUT/classes" \
  $(find "$HERE/src" -name '*.java') $(find "$OUT/gen" -name '*.java')

echo "== d8 (xposed API filtered out)"
CLASSES=()
while IFS= read -r f; do
  rel="${f#"$OUT"/classes/}"
  case "$rel" in
    de/robv/android/xposed/*) continue ;;
  esac
  CLASSES+=("$f")
done < <(find "$OUT/classes" -name '*.class')
"$BT/d8" --min-api 31 --lib "$AJ" --output "$OUT/dex" "${CLASSES[@]}" >/dev/null

echo "== assemble"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -0 "$OUT/unsigned.apk" classes.dex)
(cd "$HERE" && zip -q "$OUT/unsigned.apk" assets/xposed_init META-INF/xposed/scope.list)
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "== sign"
"$BT/apksigner" sign --ks "$KS" --ks-key-alias penhook \
  --ks-pass pass:penhook --key-pass pass:penhook --v4-signing-enabled false \
  --out "$HERE/PenStylusHook.apk" "$OUT/aligned.apk"

ls -l "$HERE/PenStylusHook.apk"
unzip -l "$HERE/PenStylusHook.apk" | tail -12
echo OK
