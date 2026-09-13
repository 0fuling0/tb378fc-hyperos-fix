#!/usr/bin/env bash
# TB378FC HyperOS 修复 —— 一键构建（KernelSU 模块包）
#
#   ./build.sh              构建 TbFix.apk + penring（手势桥），并用仓库里现成的 payload 打包
#   ./build.sh --payload    额外从 payload-src/PowerKeeper-stock.apk 重建 PowerKeeper payload
#   ./build.sh --all        --payload（LSPosed 部分已并入 TbFix，见 app/TbFix）
#   ./build.sh --clean      删掉 out/ 与各构建中间目录
#
# 产物
#   app/TbFix/TbFix.apk          （同时拷进 module/bin/）
#   app/PenRing/penring                  （同时拷进 module/bin/）
#   extras/PenStylusHook/PenStylusHook.apk（--hook）
#   out/<id>-v<version>.zip              KernelSU 模块包（zip 根目录即模块根目录）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODULE="$HERE/module"
OUT="$HERE/out"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/android-sdk}}"
export ANDROID_SDK_ROOT="$SDK"

DO_PAYLOAD=0
for a in "$@"; do
  case "$a" in
    --payload) DO_PAYLOAD=1 ;;
    --all)     DO_PAYLOAD=1 ;;
    --clean)
      rm -rf "$OUT" "$HERE/app/TbFix/build" "$HERE/app/TbFix/TbFix.apk"
      echo "cleaned"; exit 0 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $a（-h 看用法）" >&2; exit 2 ;;
  esac
done

MOD_ID=$(sed -n 's/^id=//p' "$MODULE/module.prop")
MOD_VER=$(sed -n 's/^version=//p' "$MODULE/module.prop")

# ---------- ① TbFix.apk ----------
build_app() {
  echo "== [1/4] TbFix.apk"
  bash "$HERE/app/TbFix/build.sh"
  cp -f "$HERE/app/TbFix/TbFix.apk" "$MODULE/bin/TbFix.apk"
  sha256sum "$MODULE/bin/TbFix.apk" | cut -c1-16
}

# ---------- ①b penring（手势桥守护，NDK 直接编） ----------
build_penring() {
  echo "== [2/4] penring（手势桥）"
  bash "$HERE/app/PenRing/build.sh"
  cp -f "$HERE/app/PenRing/penring" "$MODULE/bin/penring"
  chmod 755 "$MODULE/bin/penring"
  sha256sum "$MODULE/bin/penring" | cut -c1-16
}

# ---------- ② PowerKeeper payload ----------
build_payload() {
  echo "== [3/4] PowerKeeper payload（从原厂 APK 重建）"
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
  echo "== [4/4] 打包模块 zip"
  mkdir -p "$OUT"
  local zip="$OUT/${MOD_ID}-${MOD_VER}.zip"
  rm -f "$zip"
  ( cd "$MODULE" && zip -q -r -X "$zip" . \
      -x '.apk.sha' -x 'wake.log*' -x '.monitor.lock/*' \
      -x 'disable' -x 'disable-*' -x '*.pyc' -x '__pycache__/*' )
  echo "-> $zip"
  unzip -l "$zip"
}

# ---------- ② 脚本自检 ----------
# 背景：脚本里"调用了但没定义"的函数（曾经整段丢失 brushwatch_ensure），sh 只会打一行
# not found 继续跑 —— 看护进程静默不启动，现象上极难定位。这里构建期直接拦下来。
check_scripts() {
  echo "== 脚本自检（未定义函数 / 语法）"
  sh -n "$MODULE/service.sh"
  sh -n "$MODULE/post-fs-data.sh"
  python3 "$HERE/tools/check-helpers.py" "$MODULE/service.sh" "$MODULE/post-fs-data.sh"
}

build_app
build_penring
check_scripts
[ "$DO_PAYLOAD" = 1 ] && build_payload
pack

echo
echo "完成：$OUT/${MOD_ID}-${MOD_VER}.zip"
echo "刷入：把 zip 丢给 KernelSU 管理器（或 magisk --install-module）；"
echo "      本模块的 payload/hook 细节见 README.md。"
