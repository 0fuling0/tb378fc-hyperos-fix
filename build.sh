#!/usr/bin/env bash
# TB378FC HyperOS 修复 —— 一键构建（KernelSU 模块包）
#
#   ./build.sh              构建 TbFix.apk + penring（手势桥），并用仓库里现成的 payload 打包
#   ./build.sh --payload    额外从 payload-src/PowerKeeper-stock.apk 重建 PowerKeeper payload
#   ./build.sh --all        --payload（LSPosed 部分已并入 TbFix，见 app/TbFix）
#   ./build.sh --pack       只自检 + 打包，**不**编 apk/penring —— 直接用 module/bin/ 里已入库的
#                           产物。CI（.github/workflows/release.yml）走的就是这条路：不需要
#                           Android SDK / NDK，几秒就能出包。
#   ./build.sh --clean      删掉 out/ 与各构建中间目录
#
# 产物
#   app/TbFix/TbFix.apk          （同时拷进 module/bin/）
#   app/PenRing/penring                  （同时拷进 module/bin/）
#   extras/PenStylusHook/PenStylusHook.apk（--hook）
#   out/<id>-v<version>.zip              KernelSU 模块包（zip 根目录即模块根目录）
set -euo pipefail

# git-bash（MSYS）下 pwd 返回 /c/Users/... 这种 POSIX 路径，而 Windows 原生的 python3 / zip
# 认不出来 —— 会把 /c/Users/... 当成 C:\c\Users\...，报 "No such file or directory"。
# 有 pwd -W 就拿盘符路径（C:/Users/...），这样本地 Windows 和 CI 的 Linux 都能跑。
if HERE_TMP="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null)"; then
  HERE="$HERE_TMP"
else
  HERE="$(cd "$(dirname "$0")" && pwd)"
fi
MODULE="$HERE/module"
OUT="$HERE/out"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/android-sdk}}"
export ANDROID_SDK_ROOT="$SDK"

DO_PAYLOAD=0
DO_PACK_ONLY=0
for a in "$@"; do
  case "$a" in
    --payload) DO_PAYLOAD=1 ;;
    --all)     DO_PAYLOAD=1 ;;
    --pack)    DO_PACK_ONLY=1 ;;
    --clean)
      rm -rf "$OUT" "$HERE/app/TbFix/build" "$HERE/app/TbFix/TbFix.apk"
      echo "cleaned"; exit 0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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
  # 打包前把可执行位摆正（KernelSU 的 customize.sh 里 set_perm 无效，这里也兜一层）
  chmod 755 "$MODULE"/*.sh "$MODULE"/bin/penring "$MODULE"/bin/*.sh 2>/dev/null
  chmod 644 "$MODULE"/*.prop "$MODULE"/config "$MODULE"/sepolicy.rule 2>/dev/null
  mkdir -p "$OUT"
  local zip="$OUT/${MOD_ID}-${MOD_VER}.zip"
  rm -f "$zip"

  # 在**暂存副本**上打包，并把文本文件的行尾统一成 LF。
  # 为什么必须做：Android 的 sh（mksh）不能执行 CRLF 脚本 —— 会报
  #   "syntax error: unexpected 'newline'" 或 "xxx: inaccessible or not found"，
  # 而本仓库在 Windows 上 checkout 时是 CRLF（core.autocrlf=true），直接 zip 就会把 CR
  # 打进包里，装到设备上整个模块静默不工作（现象上极难定位）。
  # 对本来就是 LF 的文件，这一步是空操作。
  local stage
  stage="$(mktemp -d)"
  cp -a "$MODULE"/. "$stage"/
  find "$stage" -type f \( -name '*.sh' -o -name '*.prop' -o -name '*.rule' \
      -o -name '*.html' -o -name '*.xml' -o -name 'config' \) \
      -exec sed -i 's/\r$//' {} +

  ( cd "$stage" && zip -q -r -X "$zip" . \
      -x '.apk.sha' -x 'wake.log*' -x '.monitor.lock/*' \
      -x 'disable' -x 'disable-*' -x '*.pyc' -x '__pycache__/*' )
  rm -rf "$stage"
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
  sh -n "$MODULE/action.sh"
  python3 "$HERE/tools/check-helpers.py" "$MODULE/service.sh" "$MODULE/post-fs-data.sh" "$MODULE/action.sh"
  # WebUI 自检：用极简 DOM 桩把 webroot/index.html 的渲染与交互真跑一遍
  # （分类总开关必须只触发一次 --set 这类约束就在里面断言）。没装 node 就跳过。
  if command -v node >/dev/null 2>&1; then
    node "$HERE/tools/webui-selftest.js" >/dev/null || {
      echo "WebUI 自检失败，重跑看细节：node tools/webui-selftest.js" >&2
      exit 1
    }
    echo "webroot/index.html 自检通过"
  else
    echo "跳过 WebUI 自检（没找到 node）"
  fi
}

if [ "$DO_PACK_ONLY" = 1 ]; then
  # CI 路径：完全不碰 Android 工具链，只自检 + 打包。
  # 前提是 module/bin/ 里的 TbFix.apk 和 penring 已经入库（本仓库就是这样）。
  echo "== --pack：跳过 apk/penring 构建，直接用 module/bin/ 里已入库的产物"
  check_scripts
  pack
else
  build_app
  build_penring
  check_scripts
  [ "$DO_PAYLOAD" = 1 ] && build_payload
  pack
fi

echo
echo "完成：$OUT/${MOD_ID}-${MOD_VER}.zip"
echo "刷入：把 zip 丢给 KernelSU 管理器（或 magisk --install-module）；"
echo "      本模块的 payload/hook 细节见 README.md。"
