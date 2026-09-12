#!/usr/bin/env bash
# TB378FC HyperOS 修复 —— 一键构建（KernelSU 模块包）
#
#   ./build.sh              构建 PenBridge.apk，并用仓库里现成的 payload 打包
#   ./build.sh --payload    额外从 payload-src/PowerKeeper-stock.apk 重建 PowerKeeper payload
#   ./build.sh --hook       额外构建 extras/PenStylusHook（LSPosed，v3.0 模块不含）
#   ./build.sh --all        --payload + --hook
#   ./build.sh --clean      删掉 out/ 与各构建中间目录
#
# 产物
#   app/PenBridge/PenBridge.apk          （同时拷进 module/bin/）
#   extras/PenStylusHook/PenStylusHook.apk（--hook）
#   out/<id>-v<version>.zip              KernelSU 模块包（zip 根目录即模块根目录）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODULE="$HERE/module"
OUT="$HERE/out"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/android-sdk}}"
export ANDROID_SDK_ROOT="$SDK"

DO_PAYLOAD=0
DO_HOOK=0
for a in "$@"; do
  case "$a" in
    --payload) DO_PAYLOAD=1 ;;
    --hook)    DO_HOOK=1 ;;
    --all)     DO_PAYLOAD=1; DO_HOOK=1 ;;
    --clean)
      rm -rf "$OUT" "$HERE/app/PenBridge/build" "$HERE/app/PenBridge/PenBridge.apk" \
             "$HERE/extras/PenStylusHook/build" "$HERE/extras/PenStylusHook/PenStylusHook.apk"
      echo "cleaned"; exit 0 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $a（-h 看用法）" >&2; exit 2 ;;
  esac
done

MOD_ID=$(sed -n 's/^id=//p' "$MODULE/module.prop")
MOD_VER=$(sed -n 's/^version=//p' "$MODULE/module.prop")

# ---------- ① PenBridge.apk ----------
build_app() {
  echo "== [1/3] PenBridge.apk"
  bash "$HERE/app/PenBridge/build.sh"
  cp -f "$HERE/app/PenBridge/PenBridge.apk" "$MODULE/bin/PenBridge.apk"
  sha256sum "$MODULE/bin/PenBridge.apk" | cut -c1-16
}

# ---------- ② PowerKeeper payload ----------
build_payload() {
  echo "== [2/3] PowerKeeper payload（从原厂 APK 重建）"
  local stock="$HERE/payload-src/PowerKeeper-stock.apk"
  [ -f "$stock" ] || { echo "缺少 $stock" >&2; exit 1; }
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  cp "$stock" "$tmp/PowerKeeper.apk"
  cp "$MODULE"/tools/patch_powerkeeper.py "$MODULE"/tools/fix_static.py "$tmp/"
  ( cd "$tmp" && python3 patch_powerkeeper.py && python3 fix_static.py >/dev/null )
  python3 "$HERE/payload-src/repack_payload.py" \
    "$tmp/PowerKeeper-patched.apk" "$tmp/classes-patched2.dex" "$MODULE/payload/PowerKeeper.apk"
  sha256sum "$MODULE/payload/PowerKeeper.apk" | cut -c1-16
}

# ---------- ③ 打包 ----------
pack() {
  echo "== [3/3] 打包模块 zip"
  mkdir -p "$OUT"
  local zip="$OUT/${MOD_ID}-${MOD_VER}.zip"
  rm -f "$zip"
  ( cd "$MODULE" && zip -q -r -X "$zip" . \
      -x '.apk.sha' -x 'wake.log*' -x '.monitor.lock/*' \
      -x 'disable' -x 'disable-*' -x '*.pyc' -x '__pycache__/*' )
  echo "-> $zip"
  unzip -l "$zip"
}

# ---------- ④ 可选 hook ----------
build_hook() {
  echo "== [extra] PenStylusHook.apk（LSPosed，v3.0 模块不含）"
  bash "$HERE/extras/PenStylusHook/build.sh"
}

build_app
[ "$DO_PAYLOAD" = 1 ] && build_payload
[ "$DO_HOOK" = 1 ] && build_hook
pack

echo
echo "完成：$OUT/${MOD_ID}-${MOD_VER}.zip"
echo "刷入：把 zip 丢给 KernelSU 管理器（或 magisk --install-module）；"
echo "      本模块的 payload/hook 细节见 README.md。"
