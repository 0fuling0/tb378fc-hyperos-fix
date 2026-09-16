#!/system/bin/sh
# 在 zygote 之前运行 —— 也就是早于 PackageManager 扫描包。
#
# Lite 版只做两件事：
#   ② 把修好的 PowerKeeper 覆盖移植包里那个坏的（**必须**在 PMS 扫描之前做）
#   ⑭ 显式再应用一次 sepolicy（「设置 → 开发者选项」崩溃修复）
#
# ③④ 不在这里：它们要等 boot_completed（init 的 dynbpfloader 服务在那之后才被拉起），
# 见 service.sh。本脚本跑完就退出，不留任何进程。
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
# 两处都在 payload/PowerKeeper.apk 里逐字节修好（重建脚本见 payload-src/，用法见 build.sh --payload），
# APK 其余部分完全一致。PMS 接受这个改过的 APK，是因为这个移植包是 user 构建却标了 ro.debuggable=1。
#
# 效果：com.miui.powerkeeper 能起来并常驻（PowerStateMachineService /
# PowerKeeperBackgroundService / FeedbackControlService），不再开机即崩。

MODDIR=${0%/*}
LOG="$MODDIR/lite.log"
PAYLOAD="$MODDIR/payload/PowerKeeper.apk"
TARGET=/system_ext/app/PowerKeeper/PowerKeeper.apk
CFG="$MODDIR/config"

log_msg() { echo "$(date '+%F %T') [post-fs-data] $*" >> "$LOG"; }

# ---------------------------------------------------------------- 配置读取
# 为什么**不用** `. "$CFG"`：那样 config 会被当 shell 代码执行 —— 值里出现
# 空格、& | ` $ 或引号就会破坏解析（空格会让后半段被当成命令，& 会变成后台分隔符，
# 反引号 / $( ) 会真的执行）。WebUI 的 --set 是逐字写入的，所以这条路迟早会踩到。
# 这里只按行取键值，不执行任何东西。
cfg_raw() { [ -f "$CFG" ] && sed -n "s/^$1=//p" "$CFG" 2>/dev/null | tail -1; }
cfg_on()  { case "$1" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
key_on()  { cfg_on "$(cfg_raw "$1")"; }
pk_enabled() { [ -e "$MODDIR/disable-powerkeeper" ] && return 1; key_on FIX_POWERKEEPER; }

# ---------------------------------------------------------------- ② PowerKeeper
# 注意：这一段**不能 exit 0**。早期版本每个失败分支都直接 exit，结果只要 payload 缺失
# 或已挂载，后面的 ⑭ 就整段被跳过（跨修复项的隐蔽耦合）。现在改成条件分支，
# 脚本只有一个结尾 exit 0。
if [ -e "$MODDIR/disable-powerkeeper" ]; then
    log_msg "② PowerKeeper 补丁被标记文件 disable-powerkeeper 关闭"
elif ! pk_enabled; then
    log_msg "② PowerKeeper 补丁已关闭（config FIX_POWERKEEPER=0）"
elif [ ! -f "$PAYLOAD" ]; then
    log_msg "ERROR ② payload 缺失: $PAYLOAD"
elif [ ! -f "$TARGET" ]; then
    log_msg "ERROR ② 目标缺失: $TARGET"
elif grep -q " $TARGET " /proc/mounts 2>/dev/null; then
    log_msg "② PowerKeeper 补丁已挂载（跳过）"
else
    chown 0:0 "$PAYLOAD" 2>/dev/null
    chmod 0644 "$PAYLOAD" 2>/dev/null
    chcon u:object_r:system_file:s0 "$PAYLOAD" 2>/dev/null
    if mount -t none -o bind "$PAYLOAD" "$TARGET" 2>/dev/null; then
        log_msg "② PowerKeeper 补丁已挂载 ($(sha256sum "$PAYLOAD" 2>/dev/null | cut -c1-16))"
    else
        log_msg "ERROR ② PowerKeeper bind mount 失败"
    fi
fi

# ---------------------------------------------------------------- ⑭ sepolicy
# 规则已经写在 sepolicy.rule 里（KernelSU 开机会自动加载），但实测在 ReSukiSU 4.x
# late-load LKM 上**纯声明式加载并不可靠** —— 出现过"删掉模块重启后原始 denial 又回来了"的情况。
# 所以这里用 ksud 的运行时通道显式再应用一遍：它会触发一次策略重载，顺带刷新内核 AVC 与
# init 用户态 libselinux 里的陈旧拒绝缓存。service.sh 开机后还会补一次。
#
# 注意：ksud sepolicy apply 是"按传入文件重新推导并应用"，**不会跨调用累积**，
# 所以必须传**完整**的 sepolicy.rule。
KSUD=""
for c in /data/adb/ksud /data/adb/ksu/bin/ksud; do
    if [ -x "$c" ]; then KSUD="$c"; break; fi
done
if [ -n "$KSUD" ]; then
    "$KSUD" sepolicy apply "$MODDIR/sepolicy.rule" >/dev/null 2>&1
    log_msg "⑭ sepolicy apply rc=$? ($KSUD)"
else
    log_msg "⑭ 找不到 ksud，跳过显式应用（规则仍由 KernelSU 声明式加载）"
fi

exit 0
