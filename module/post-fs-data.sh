#!/system/bin/sh
# 在 zygote 之前运行 —— 也就是早于 PackageManager 扫描包。
#
# Lite 版只做两件事：
#   ② 把修好的 PowerKeeper 覆盖移植包里那个坏的（让 PMS 在包扫描阶段就看到补丁版；
#      **真正让补丁对 com.miui.powerkeeper 生效的是 service.sh 里那次 remount**，原因见下）
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
# 两处都在 payload/app/PowerKeeper.apk 里逐字节修好（重建脚本见 payload-src/，用法见 build.sh --payload）。
#
# ⚠️ payload 必须**保留 APK Signing Block**（v2/v3 签名块，位于最后一个 local entry 与
# central directory 之间）。用 Python `zipfile` 重建 zip 会把它整个丢掉，Android 11+ 对
# targetSdk>=30 强制要求 v2 签名，于是 PMS 直接拒绝扫描：
#     W PackageManager: Failed to scan /system_ext/app/PowerKeeper:
#         No APK Signature Scheme v2 signature in package
# 结果是 com.miui.powerkeeper 根本没装上，② 等于没做。
# （注意：本机 ro.debuggable=1，但**不会**因此放过缺 v2 签名的 APK —— 实测照报。
#  Full 分支注释里"靠 ro.debuggable 才让 PMS 接受"的说法是错的。）
# 所以 payload-src/apk_inplace.py 做的是**等长原地补丁**：只覆盖 classes.dex 的数据段 +
# 回填两处 CRC-32，容器其余部分逐字节不动，签名块原样保留（本机 4096 字节）。
# 产物 6228160 字节，与原厂完全等长。tools/verify_pack.py 里有守卫。
#
# 效果：com.miui.powerkeeper 能起来并常驻（PowerStateMachineService /
# PowerKeeperBackgroundService / FeedbackControlService），不再开机即崩。

MODDIR=${0%/*}
LOG="$MODDIR/lite.log"
# ⚠️ 挂的是**目录**不是文件 —— 原因见下面「为什么必须挂父目录」。
PK_STAGE="$MODDIR/payload/app"
PK_DIR=/system_ext/app/PowerKeeper
PK_FILE="$PK_DIR/PowerKeeper.apk"
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
# 为什么这里挂了还不够（真正生效的那次在 service.sh）
# --------------------------------------------------
# KernelSU 会把「模块建立的挂载」从 **App 进程** 的 mount namespace 里卸载掉 ——
# 这是它隐藏模块/root 的设计。实测（本机 ReSukiSU 4.2.0-rc1-52 late-load LKM）：
#
#     init / su 视角      : 有这条挂载，sha256 = 我们的补丁
#     com.miui.powerkeeper: **没有这条挂载**，读到 ROM 原件
#                           （它是 android.uid.system/1000，一样躲不过）
#       → 开机必崩 java.lang.VerifyError: Verifier rejected class
#          com.miui.powerkeeper.cloudcontrol.LocalUpdateUtils ...
#          [0x1] unexpected non-category 1 return type
#
# 也就是说：**post-fs-data 这一次挂载对 App 是隐形的**，补丁等于没打 —— 但模块自己的
# 日志会写「② PowerKeeper 已挂载」，PMS 也确实按补丁后的 APK 扫描成功，**看起来一切正常**。
# （这就是为什么这个 bug 能蹲很久：从任何"root 视角"检查都是对的。）
#
# 进一步实测（2026-09-17）：KernelSU 记录的是 **post-fs-data 阶段建立的那个挂载实例**，
# App 进程创建时把它卸掉。所以「事后在原地重挂一次」就能拿到一个 App 可见的挂载 ——
# 这正是 service.sh 里 do_pk_mount() 做的事（先 umount 再 mount）。
# 实测 remount 之后，init(1) / zygote64 / com.miui.powerkeeper 三个 namespace 读到的
# 都是补丁版，且 powerkeeper 不再崩。
#
# 所以：**本脚本这一次挂载的意义是让 PMS 在包扫描阶段就看到补丁版 APK**
# （记录下来的 dex checksum 与运行时一致）；真正让补丁对 App 生效的是 service.sh。
#
# 为什么挂**父目录**而不是那个 APK 文件：父目录一挂，ROM 预编译的 `oat/` 也一起被盖掉，
# ART 不会再用那份基于坏字节码编出来的 odex。service.sh 里同样挂父目录。
#
# 注意：这一段**不能 exit 0**。早期版本每个失败分支都直接 exit，结果只要 payload 缺失
# 或已挂载，后面的 ⑭ 就整段被跳过（跨修复项的隐蔽耦合）。现在改成条件分支，
# 脚本只有一个结尾 exit 0。
pk_mount() {
    [ -d "$PK_STAGE" ] || { log_msg "ERROR ② payload 目录缺失: $PK_STAGE"; return 1; }
    [ -f "$PK_STAGE/PowerKeeper.apk" ] || { log_msg "ERROR ② payload 缺失: $PK_STAGE/PowerKeeper.apk"; return 1; }
    [ -d "$PK_DIR" ] || { log_msg "ERROR ② 目标目录缺失: $PK_DIR"; return 1; }
    if grep -q " $PK_DIR " /proc/mounts 2>/dev/null; then
        log_msg "② PowerKeeper 目录已挂载（跳过）"
        return 0
    fi
    chown -R 0:0 "$PK_STAGE" 2>/dev/null
    chmod 0755 "$PK_STAGE" 2>/dev/null
    chmod 0644 "$PK_STAGE/PowerKeeper.apk" 2>/dev/null
    # 标签必须是 system_file，否则 PMS / ART 读不到（bind mount 用的是源文件的标签）
    chcon -R u:object_r:system_file:s0 "$PK_STAGE" 2>/dev/null
    if mount -t none -o bind "$PK_STAGE" "$PK_DIR" 2>/dev/null; then
        log_msg "② PowerKeeper 目录已挂载 ($(sha256sum "$PK_STAGE/PowerKeeper.apk" 2>/dev/null | cut -c1-16))"
        return 0
    fi
    # 退路：目录挂不上就退回文件级（至少 PMS / system_server 视角是对的）
    chcon u:object_r:system_file:s0 "$PK_STAGE/PowerKeeper.apk" 2>/dev/null
    if mount -t none -o bind "$PK_STAGE/PowerKeeper.apk" "$PK_FILE" 2>/dev/null; then
        log_msg "WARN ② 目录挂载失败，退回文件级挂载（App 进程看不到，靠 service.sh 补救）"
        return 0
    fi
    log_msg "ERROR ② bind mount 失败"
    return 1
}

if [ -e "$MODDIR/disable-powerkeeper" ]; then
    log_msg "② PowerKeeper 补丁被标记文件 disable-powerkeeper 关闭"
elif ! pk_enabled; then
    log_msg "② PowerKeeper 补丁已关闭（config FIX_POWERKEEPER=0）"
else
    pk_mount
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
