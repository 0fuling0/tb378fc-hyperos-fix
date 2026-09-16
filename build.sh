#!/usr/bin/env bash
# TB378FC HyperOS 修复 Lite —— 一键构建（KernelSU 模块包）
#
#   ./build.sh              自检 + 打包。**不需要** Android SDK / NDK —— 本模块不含 App、
#                           不含二进制，几秒就能出包。
#   ./build.sh --pack       同上（保留这个写法是为了 CI 兼容，.github/workflows/release.yml 用它）
#   ./build.sh --payload    额外从 payload-src/PowerKeeper-stock.apk 重建 ② 的 payload
#                           （module/payload/app/PowerKeeper.apk 已入库，平时不需要重建）
#   ./build.sh --clean      删掉 out/ 与 payload-src 下的中间产物
#
# 产物
#   module/payload/app/PowerKeeper.apk  ② 的 bind mount payload（已入库；--payload 才重建）
#   out/<id>-<version>.zip           KernelSU 模块包（zip 根目录即模块根目录）
#
# 与 Full 分支的差别：这里没有 app/（TbFix.apk + LSPosed 模块）、没有 module/bin/
# （penring 手势桥守护）、没有 action.sh / restart.sh（看护循环的入口）。整个模块只有
# 5 个 shell 脚本 + 1 个 payload + 1 个 WebUI，且**运行期不产生任何常驻进程**。
set -euo pipefail

# git-bash（MSYS）下 pwd 返回 /c/Users/... 这种 POSIX 路径，而 Windows 原生的 python 认不出来
# —— 会把 /c/Users/... 当成 C:\c\Users\...，报 "No such file or directory"。
# 有 pwd -W 就拿盘符路径（C:/Users/...），这样本地 Windows 和 CI 的 Linux 都能跑。
if HERE_TMP="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null)"; then
  HERE="$HERE_TMP"
else
  HERE="$(cd "$(dirname "$0")" && pwd)"
fi
MODULE="$HERE/module"
OUT="$HERE/out"

# python3 在 Windows 上常常只叫 python（Git-Bash 里也没有 python3.exe 这个 shim）
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done

DO_PAYLOAD=0
for a in "$@"; do
  case "$a" in
    --payload) DO_PAYLOAD=1 ;;
    --pack)    : ;;   # 默认行为就是"自检 + 打包"，这个参数只为 CI 兼容保留
    --clean)
      rm -rf "$OUT" \
        "$HERE/payload-src/PowerKeeper-patched.apk" \
        "$HERE/payload-src/classes-patched.dex" \
        "$HERE/payload-src/classes-patched2.dex"
      echo "cleaned"; exit 0 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $a（-h 看用法）" >&2; exit 2 ;;
  esac
done

MOD_ID=$(sed -n 's/^id=//p'      "$MODULE/module.prop" | head -1)
MOD_VER=$(sed -n 's/^version=//p' "$MODULE/module.prop" | head -1)
[ -n "$MOD_ID" ]  || { echo "module.prop 里读不到 id" >&2; exit 1; }
[ -n "$MOD_VER" ] || { echo "module.prop 里读不到 version" >&2; exit 1; }

# ---------- ② PowerKeeper payload ----------
# 输入是移植包原厂 APK（payload-src/PowerKeeper-stock.apk，**不入库**，体积太大），
# 两步等长补丁后**原地**替换 classes.dex —— 绝不重建 zip（重建会丢 APK Signing Block，
# Android 11+ 的 PMS 会直接拒绝扫描，详见 payload-src/apk_inplace.py）。
build_payload() {
  echo "== 重建 PowerKeeper payload（从原厂 APK，原地等长补丁）"
  local stock="$HERE/payload-src/PowerKeeper-stock.apk"
  [ -f "$stock" ] || { echo "缺少 $stock（原厂 APK 不入库，需要自行从移植包提取）" >&2; exit 1; }
  [ -n "$PY" ] || { echo "需要 python3 才能重建 payload" >&2; exit 1; }
  local tmp
  tmp=$(mktemp -d)
  # 清理失败不能拖垮构建（有些环境会用安全删除包装 rm，可能直接失败）
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' >/dev/null 2>&1 || true" RETURN
  cp "$stock" "$tmp/PowerKeeper.apk"
  cp "$HERE/payload-src/patch_powerkeeper.py" "$HERE/payload-src/fix_static.py" \
     "$HERE/payload-src/apk_inplace.py" "$tmp/"
  ( cd "$tmp" && "$PY" patch_powerkeeper.py && "$PY" fix_static.py >/dev/null )
  "$PY" "$HERE/payload-src/repack_payload.py" \
    "$tmp/PowerKeeper.apk" "$tmp/classes-patched2.dex" "$MODULE/payload/app/PowerKeeper.apk"
}

# ---------- 脚本自检 ----------
# 背景：脚本里"调用了但没定义"的函数，sh 只会打一行 not found 继续跑 —— 静默失效，
# 现象上极难定位（曾经整段丢过一个看护函数）。这里构建期直接拦下来。
check_scripts() {
  echo "== 脚本自检（语法 / 未定义函数 / WebUI 渲染与交互）"
  sh -n "$MODULE/service.sh"
  sh -n "$MODULE/post-fs-data.sh"
  sh -n "$MODULE/customize.sh"
  sh -n "$MODULE/uninstall.sh"
  # 设备端验收脚本不进包，但同样要能跑 —— 语法错了只有拿到设备上才发现太晚
  sh -n "$HERE/tools/acceptance.sh"

  if [ -n "$PY" ]; then
    "$PY" "$HERE/tools/check-helpers.py" \
      "$MODULE/service.sh" "$MODULE/post-fs-data.sh" \
      "$MODULE/customize.sh" "$MODULE/uninstall.sh" "$HERE/tools/acceptance.sh"
    # payload 的原地补丁解析器自检（签名块识别 / 等长替换 / 只改该改的地方）
    "$PY" "$HERE/payload-src/apk_inplace.py"
  else
    echo "跳过未定义函数检查（没找到 python3）"
  fi

  # WebUI 自检：用极简 DOM 桩把 webroot/index.html 的渲染与交互真跑一遍
  # （"拨开关必须只触发一次 --set" 这类约束就在里面断言）。没装 node 就跳过。
  if command -v node >/dev/null 2>&1; then
    node "$HERE/tools/webui-selftest.js" >/dev/null || {
      echo "WebUI 自检失败，重跑看细节：node tools/webui-selftest.js" >&2
      exit 1
    }
    echo "webroot/index.html 自检通过"
  else
    echo "跳过 WebUI 自检（没找到 node）"
  fi

  # 模块必需文件齐不齐 —— 少一个装到设备上就是静默不工作
  local f
  for f in module.prop config sepolicy.rule customize.sh post-fs-data.sh \
           service.sh uninstall.sh payload/app/PowerKeeper.apk webroot/index.html; do
    [ -f "$MODULE/$f" ] || { echo "模块里缺少 $f" >&2; exit 1; }
  done
  echo "模块必需文件齐全"
}

# ---------- 打包 ----------
pack() {
  echo "== 打包模块 zip"
  # 打包前把权限位摆正（KernelSU 的 customize.sh 里 set_perm 对目录树无效，这里兜一层）
  chmod 755 "$MODULE"/*.sh 2>/dev/null || true
  chmod 644 "$MODULE"/*.prop "$MODULE"/config "$MODULE"/sepolicy.rule 2>/dev/null || true
  mkdir -p "$OUT"
  local zip="$OUT/${MOD_ID}-${MOD_VER}.zip"
  rm -f "$zip"

  # 为什么必须归一化行尾：本仓库在 Windows 上 checkout 是 CRLF（core.autocrlf=true，
  # 仓库里没有 .gitattributes），而 Android 的 sh（mksh）**不能执行 CRLF 脚本** ——
  # 会报 "syntax error: unexpected 'newline'"，装到设备上整个模块静默不工作。
  # 两条打包路径（zip / python 兜底）都在归一化后再写进包；对本来就是 LF 的文件是空操作。
  #
  # 排除表：设备上的运行期产物（日志、pid、disable 标记）不能进包 —— 否则用户装完
  # 打开一看"怎么是关着的"，或者把上一个设备的状态带过来。
  if command -v zip >/dev/null 2>&1; then
    # 在**暂存副本**上归一化 + 打包，不动工作区
    local stage
    stage="$(mktemp -d)"
    cp -a "$MODULE"/. "$stage"/
    find "$stage" -type f \( -name '*.sh' -o -name '*.prop' -o -name '*.rule' \
        -o -name '*.html' -o -name 'config' \) -exec sed -i 's/\r$//' {} +
    ( cd "$stage" && zip -q -r -X "$zip" . \
        -x '.apk.sha' -x '*.log' -x '*.pid' -x 'brush.*' -x 'wake.log*' \
        -x '.monitor.lock/*' -x 'disable' -x 'disable-*' -x '*.pyc' -x '__pycache__/*' )
    rm -rf "$stage"
  else
    # Windows / git-bash 通常没有 zip 命令，走 Python 兜底（行为与上面一致，
    # 连条目顺序都固定，好让本地与 CI 的产物可比对）。
    [ -n "$PY" ] || { echo "既没有 zip 也没有 python3，无法打包" >&2; exit 1; }
    "$PY" "$HERE/tools/pack_zip.py" "$MODULE" "$zip"
  fi

  echo "-> $zip"
  unzip -l "$zip"
}

echo "== $MOD_ID $MOD_VER"
check_scripts
[ "$DO_PAYLOAD" = 1 ] && build_payload
pack

# 产物校验：行尾、运行期产物、Full 分支残留、可执行位、版本一致性、payload 完整性。
# 这几类问题在开发机上完全看不出来，但装到设备上就是"模块静默不工作"。
if [ -n "$PY" ]; then
  echo
  "$PY" "$HERE/tools/verify_pack.py" "$OUT/${MOD_ID}-${MOD_VER}.zip"
else
  echo
  echo "跳过产物校验（没找到 python3）"
fi

echo
echo "完成：$OUT/${MOD_ID}-${MOD_VER}.zip"
echo "刷入：把 zip 丢给 KernelSU 管理器（或 magisk --install-module），然后重启。"
echo "      装完在 KernelSU 管理器的模块页打开 WebUI 可以逐项开关；详情见 README.md。"
