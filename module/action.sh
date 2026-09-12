#!/system/bin/sh
MODDIR=${0%/*}
ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
echo "TB378FC HyperOS 修复 ${ver:-v?}"
echo ' '
# ④ 统计三个死电话包里有几个已停用（0~3）
n_tele=$(pm list packages -d 2>/dev/null | grep -cxE 'package:(com\.qti\.phone|com\.qualcomm\.qcrilmsgtunnel|com\.qualcomm\.qti\.telephonyservice)')
# ⑤ 胶囊开关（config CAPSULE / disable-capsule 标记）
cap=on
[ -e "$MODDIR/disable-capsule" ] && cap=off
grep -q '^CAPSULE=0' "$MODDIR/config" 2>/dev/null && cap=off
echo "① 手写笔守护 : $(cat $MODDIR/.monitor.lock/pid 2>/dev/null || echo '未运行')$([ -e $MODDIR/disable ] && echo ' (已禁用)')"
echo "   磁吸状态   : $(cat /sys/class/power_supply/wls_tx/attached 2>/dev/null)  (1=吸附 0=取下)"
echo "   线圈笔电量 : $(cat /sys/class/power_supply/wls_tx/level 2>/dev/null)  charge_state=$(cat /sys/class/power_supply/wls_tx/charge_state 2>/dev/null)"
echo "② PowerKeeper: $([ -e $MODDIR/disable-powerkeeper ] && echo '已禁用' || echo -n '已挂载 ')$(mount 2>/dev/null | grep -c 'PowerKeeper/PowerKeeper.apk') 处，进程 $(pidof com.miui.powerkeeper || echo '未运行')"
echo "③ BPF 监视器 : $([ -e $MODDIR/disable-bpfmon ] && echo '已禁用' || echo -n '已停 ') $(pidof hyper_bpfloader >/dev/null 2>&1 && echo '仍在运行(异常)' || echo 'hyper_bpfloader 未运行')"
echo "④ 死电话栈   : $([ -e $MODDIR/disable-telephony ] && echo '已禁用' || echo -n '已停 ')$n_tele/3 个包$(pidof com.qti.phone >/dev/null 2>&1 && echo "，残留空转进程 $(pidof com.qti.phone)" || echo '，无残留进程')"
echo "⑤ 吸附胶囊   : $cap  (引导标记 stylus_first_connect=$(settings get secure stylus_first_connect 2>/dev/null))"
echo ' '
echo '最近日志:'
tail -n 14 "$MODDIR/wake.log" 2>/dev/null
