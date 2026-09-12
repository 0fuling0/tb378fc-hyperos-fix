#!/system/bin/sh
# 在 zygote 之前运行 —— 也就是早于 PackageManager 扫描包。
#
# 本模块只做一件事（②）：把修好的 PowerKeeper 覆盖移植包里那个坏的。
# （另两项 ①手写笔唤醒、③停 BPF 监视器 在 service.sh 里。）
#
# 移植者手工改过 MIUI 的 PowerKeeper，改坏了**两处**：
#
#   a. LocalUpdateUtils.startCloudSyncData —— void 方法里 return 了值
#        type   : (Landroid/content/Context;Z)V      ← 声明是 void
#        0001: 0f00  return v0                       ← 0x0f 是 return（0x0e 才是 return-void）
#      原意是"让这个方法直接返回、禁用云同步"，但写成 return v0 → 整个类通不过校验
#      → 每次开机 VerifyError。
#
#   b. DisplayFrameSetting.isFeatureOn —— 丢了 static
#        原厂应为   access=0x0009 (PUBLIC STATIC)  ins=0     （同类的 DebugLabelSetting 就是这个值）
#        被改成     access=0x0001 (PUBLIC)         ins=1     （多了 this）
#        而全部 4 个调用点都是 invoke-static                        → IncompatibleClassChangeError
#      这一处**不能只改一个字节**：dex 规定静态方法必须位于 class_data_item.direct_methods，
#      而它在 virtual_methods 里。修补器把该条目移到了 direct 列表、补上 ACC_STATIC，
#      并把 code_item 的 ins_size 从 1 改成 0；**改写是等长的（1639 → 1639 字节），
#      文件内所有偏移不变**，只重算了 dex 头部的 adler32 与 SHA-1。
#
# 两处都在 payload/PowerKeeper.apk 里逐字节修好（重建脚本见 tools/），APK 其余部分完全一致。
# PMS 接受这个改过的 APK，是因为这个移植包是 user 构建却标了 ro.debuggable=1。
#
# 效果：com.miui.powerkeeper 能起来并常驻（PowerStateMachineService /
# PowerKeeperBackgroundService / FeedbackControlService），不再开机即崩。
#
# 复现：tools/patch_powerkeeper.py（字节补丁）+ tools/fix_static.py（结构性补丁），
# 对着原始 PowerKeeper.apk 跑一遍即可重建 payload。

MODDIR=${0%/*}
LOG="$MODDIR/wake.log"
PAYLOAD="$MODDIR/payload/PowerKeeper.apk"
TARGET=/system_ext/app/PowerKeeper/PowerKeeper.apk

log_msg() { echo "$(date '+%F %T') [post-fs-data] $*" >> "$LOG"; }

# ---- 开机清锁。必须放在本脚本任何一处 exit 0 之前，否则可能被前面的分支跳过。----
# service.sh 的 setup 靠 .monitor.lock/pid 判断"supervisor 是不是已经在跑"，判据是 kill -0。
# 但 supervisor 不可能跨重启存活，这个 pid 文件开机时必然是上一轮的残留，而 pid 会被复用：
# 实测重启后 2914 被 vendor.qti.hardware.soter-service 占用，setup 于是误判
# "supervisor already alive pid=2914" 并提前 exit 0 —— 而那句 exit 0 在 ③④① 的启动之前，
# 结果 BPF 拆弹、死电话栈、唤醒守护一个都没起来，整个模块等于没跑（只有 ② 因为走
# post-fs-data 这条独立路径幸免）。post-fs-data 严格早于 service.sh，在这里清锁即可
# 彻底消掉这个跨重启竞态。
LOCK="$MODDIR/.monitor.lock"
if [ -e "$LOCK/pid" ]; then
    log_msg "cleared stale supervisor lock (was pid $(cat "$LOCK/pid" 2>/dev/null))"
    rm -rf "$LOCK" 2>/dev/null
fi

[ -e "$MODDIR/disable-powerkeeper" ] && { log_msg "PowerKeeper patch disabled by marker"; exit 0; }
[ -f "$PAYLOAD" ] || { log_msg "PowerKeeper payload missing"; exit 0; }
[ -f "$TARGET" ] || { log_msg "PowerKeeper target missing"; exit 0; }

chown 0:0 "$PAYLOAD" 2>/dev/null
chmod 0644 "$PAYLOAD" 2>/dev/null
chcon u:object_r:system_file:s0 "$PAYLOAD" 2>/dev/null

if grep -q " $TARGET " /proc/mounts 2>/dev/null; then
    log_msg "PowerKeeper patch already mounted"
    exit 0
fi

if mount -t none -o bind "$PAYLOAD" "$TARGET" 2>/dev/null; then
    log_msg "PowerKeeper patch mounted ($(sha256sum "$PAYLOAD" 2>/dev/null | cut -c1-16))"
else
    log_msg "ERROR PowerKeeper bind mount failed"
fi

exit 0
