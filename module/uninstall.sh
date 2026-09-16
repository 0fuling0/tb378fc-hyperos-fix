#!/system/bin/sh
# Lite 版卸载脚本。
#
# 本模块不装 App、不起守护，所以没有需要收尾的进程或包。
# 唯一需要交代的是 ④ 与 ③ 卸载后的行为。

# ④ 死电话栈：这里**故意不**恢复那三个包的启用状态。
# 恢复就等于立刻回到每秒数百次的崩溃重启循环（zygote/system_server 白烧、feature flags
# 被反复重置）—— 那是本机默认就有的坏状态，不是卸载模块的人想要的结果。所以维持停用。
# 确实要恢复（例如以后换到有 modem 的 ROM）就手动来，注意必须 root：
#     su -c 'pm enable --user 0 com.qti.phone'
#     su -c 'pm enable --user 0 com.qualcomm.qcrilmsgtunnel'
#     su -c 'pm enable --user 0 com.qualcomm.qti.telephonyservice'
echo '④ 提示：三个死电话包保持停用（恢复会立刻回到崩溃重启循环）。'
echo "   如需恢复：su -c 'pm enable --user 0 com.qti.phone' （另有 qcrilmsgtunnel / qti.telephonyservice）"

# ③ 不需要收尾：本模块只是每次开机把 dynbpfloader 停掉，没有做任何持久化的禁用
# （没有改 .rc、没有改属性）。卸载后重启，监视器会照常由 init 拉起 —— 也就是回到
# 「不开容器时忍着、用容器时可能重启进 recovery」的原始状态。
echo '③ 提示：卸载并重启后，hyper_bpfloader 的监视器会恢复由 init 拉起。'
echo '   即回到原始状态：不用 DroidSpaces 容器时通常无感，用容器时可能被重启进 recovery。'

# ② 不需要收尾：PowerKeeper 的 bind mount 只存在于本次开机，重启后自然消失。
echo '② 提示：PowerKeeper 的修补只在本次开机有效，重启后自动回到未修补状态。'
exit 0
