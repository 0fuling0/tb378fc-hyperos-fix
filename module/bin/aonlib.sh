#!/system/bin/sh
# ⑧b AON HAL（mifaced）缺 libcamera2ndk.so —— 幂等补上。
#
# 背景：/odm/bin/hw/mifaced 的 DT_NEEDED 里有 libcamera2ndk.so，但本机 /odm/lib64 里没有；
# /system/lib64 那个不在 vendor 命名空间的允许路径里，硬拷进去会连带
# libandroid_runtime → libart 一整片（不可行）。而 /vendor/lib64/libcamera2ndk_vendor.so
# 的依赖全是 vendor 库（libstagefright_foundation / libhidlbase / libcamera_metadata …），
# 按需要的名字拷过去 bionic 会接受（实测 mifaced 正常起来并注册 IAlwaysOn）。
#
# /odm 是只读 erofs：先把原内容备份到模块目录，再用 tmpfs 盖住 /odm/lib64，
# 把备份 + 这个库铺回去，最后统一 chcon 成 vendor_file（否则 hal_miface_default 读不了）。
#
# 关掉：建 marker 文件 disable-aonlib（或 disable-aon）。
MODDIR=${MODDIR:-${0%/*}/..}
SRC=/vendor/lib64/libcamera2ndk_vendor.so
STAGE="$MODDIR/.odmlib64"

[ -e "$MODDIR/disable-aonlib" ] && exit 0
[ -e "$MODDIR/disable-aon" ] && exit 0
[ -e /odm/lib64/libcamera2ndk.so ] && exit 0          # 已经在位（上次已挂或 ROM 自带）
[ -f "$SRC" ] || { echo "[aonlib] 缺 $SRC，跳过"; exit 0; }
[ -d /odm/lib64 ] || { echo "[aonlib] /odm/lib64 不存在，跳过"; exit 0; }

rm -rf "$STAGE"; mkdir -p "$STAGE" || exit 0
cp -a /odm/lib64/. "$STAGE"/ 2>/dev/null || { echo "[aonlib] 备份 /odm/lib64 失败"; exit 0; }
cp -f "$SRC" "$STAGE/libcamera2ndk.so" || { echo "[aonlib] 拷贝 libcamera2ndk.so 失败"; exit 0; }
mount -t tmpfs tmpfs /odm/lib64 2>/dev/null || { echo "[aonlib] tmpfs /odm/lib64 失败"; exit 0; }
cp -a "$STAGE"/. /odm/lib64/ 2>/dev/null
chcon u:object_r:vendor_file:s0 /odm/lib64/* 2>/dev/null
echo "[aonlib] /odm/lib64 镜像就绪：$(ls /odm/lib64 | tr '\n' ' ')"
