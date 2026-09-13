#!/system/bin/sh
MODDIR=${0%/*}
old=$(cat "$MODDIR/.monitor.lock/pid" 2>/dev/null)
[ -n "$old" ] && kill "$old" 2>/dev/null
pm uninstall --user 0 dev.tb378fc.fix >/dev/null 2>&1
# 早期版本的包名，兼容从旧版升级后卸载的情况
pm uninstall --user 0 com.aclaniakea.penwake >/dev/null 2>&1
pm uninstall --user 0 dev.tb378fc.fix.hook >/dev/null 2>&1
pm uninstall --user 0 com.aclaniakea.penwake.hook >/dev/null 2>&1
# 早期版本为了 MIUI 灵动胶囊设过这个属性，这里恢复默认（MIUI 读取时的默认值就是 false）
setprop persist.sys.feature.xms.switcher false 2>/dev/null
rm -f "$MODDIR/.monitor.lock/pid" 2>/dev/null
rmdir "$MODDIR/.monitor.lock" 2>/dev/null
# ④ 死电话栈：这里**故意不**恢复那三个包的启用状态。
# 恢复就等于立刻回到每秒数百次的崩溃重启循环（zygote/system_server 白烧、feature flags
# 被反复重置）—— 那是本机默认就有的坏状态，不是卸载模块的人想要的结果。所以维持停用。
# 确实要恢复（例如以后换到有 modem 的 ROM）就手动来，注意必须 root：
#     su -c 'pm enable --user 0 com.qti.phone'
#     su -c 'pm enable --user 0 com.qualcomm.qcrilmsgtunnel'
#     su -c 'pm enable --user 0 com.qualcomm.qti.telephonyservice'
echo '④ 提示：三个死电话包保持停用（恢复会立刻回到崩溃重启循环）。'
echo "   如需恢复：su -c 'pm enable --user 0 com.qti.phone' （另有 qcrilmsgtunnel / qti.telephonyservice）"
exit 0
