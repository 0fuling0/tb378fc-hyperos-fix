#!/system/bin/sh
# ⑧c 让「设置 → 视觉感知/注视感知」那一页重新出现 —— 幂等。
#
# HyperOS 里三个 AON bool（config_aon_{gesture,screen_on,screen_off}_available）住在
# **com.miui.rom** 包里，移植包自带的 /product/overlay/MiuiFrameworkResOverlay.apk 把它们
# 写成了 false。我们挂一个只有这三个 bool 的 RRO（priority 999 压过它的 100）翻成 true。
#
# 为什么不能像普通 App 那样 pm install 成 data overlay：
#   INSTALL_FAILED_INTERNAL_ERROR: Overlay ... and target com.miui.rom signed with different
#   certificates, and the overlay lacks <overlay android:targetName>
# 也就是说 target 没把资源声明成 <overlayable>，异签名只能靠"装在系统分区"获得豁免。
# /product 是只读 erofs，所以这里 tmpfs 盖住 /product/overlay（该目录只有十来个几十 KB 的
# APK，全部原样拷回去，只多我们一个），PMS 在开机扫描时就会看到它。
#
# 关掉：disable-aonoverlay（或 disable-aon）。启用动作在 service.sh 里做（cmd overlay enable）。
MODDIR=${MODDIR:-${0%/*}/..}
APK="$MODDIR/payload/AonOverlay.apk"
DST=/product/overlay

[ -e "$MODDIR/disable-aonoverlay" ] && exit 0
[ -e "$MODDIR/disable-aon" ] && exit 0
[ -f "$APK" ] || { echo "[aonoverlay] 缺 $APK"; exit 0; }
[ -d "$DST" ] || { echo "[aonoverlay] $DST 不存在"; exit 0; }

mountpoint -q "$DST" && exit 0                      # 已经挂过
# tmpfs 一盖上去原内容就看不见了 → 先把该目录原有的 overlay 备份到模块目录，挂完再铺回去
STAGE="$MODDIR/.product_overlay"
rm -rf "$STAGE"; mkdir -p "$STAGE" || { echo "[aonoverlay] 备份目录建不了"; exit 0; }
cp -a "$DST"/. "$STAGE"/ 2>/dev/null
mount -t tmpfs tmpfs "$DST" 2>/dev/null || { echo "[aonoverlay] tmpfs $DST 失败"; exit 0; }
cp -a "$STAGE"/. "$DST"/ 2>/dev/null
cp -f "$APK" "$DST/AonOverlay.apk" || { echo "[aonoverlay] 拷贝失败"; exit 0; }
chmod 0644 "$DST/AonOverlay.apk" 2>/dev/null
chcon u:object_r:system_file:s0 "$DST/AonOverlay.apk" 2>/dev/null
echo "[aonoverlay] /product/overlay 就位：$(ls "$DST" | wc -l) 个 overlay（含本模块的 AonOverlay.apk）"
