#!/usr/bin/env bash
# 构建 penring —— 联想笔手势 → 小米焦点触控笔键 的桥（模块 bin/ 里的常驻守护）。
# 用 NDK 的 clang 直接编 aarch64 静态可执行文件，不依赖 Gradle。
#
# 产物：app/PenRing/penring（同时拷进 module/bin/）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-/opt/android-ndk}}"
API="${API:-30}"

case "$(uname -m)" in
  x86_64)         HOST=linux-x86_64 ;;
  aarch64|arm64)  HOST=linux-aarch64 ;;
  *) echo "未知构建机架构：$(uname -m)" >&2; exit 1 ;;
esac

CLANG="$NDK/toolchains/llvm/prebuilt/$HOST/bin/aarch64-linux-android$API-clang"
[ -x "$CLANG" ] || { echo "找不到 $CLANG（用 ANDROID_NDK_HOME= 指定 NDK）" >&2; exit 1; }

echo "== clang ($CLANG)"
"$CLANG" -O2 -Wall -Wextra -static -s -o "$HERE/penring" "$HERE/penring.c"

file "$HERE/penring" | sed 's/^/   /'
ls -l "$HERE/penring"
echo OK
