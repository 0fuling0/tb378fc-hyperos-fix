#!/system/bin/sh
# TB378FC HyperOS 修复 Lite —— 服务脚本
#
# 与 Full 分支最大的区别：**这里没有任何常驻进程**。
# 四个修复都是"开机后做一次就完"：② 换一次 PowerKeeper 挂载并拉起它、
# ③ 停 BPF 监视器、④ 停死电话栈、⑭ 补一次 sepolicy。
# 做完脚本自己退出 —— 没有 supervisor、没有 monitor、没有 penring、没有看护循环。
#
# 调用方式
# --------
#   service.sh                 开机自动调用（KernelSU 在 late_start 阶段跑本脚本）。
#                              它把自己放到后台等 boot_completed，**立刻返回**，不阻塞开机。
#   service.sh --boot          上面那个后台动作的本体（等 boot_completed → ③④⑭ → 退出）
#   service.sh --status        人读的状态摘要
#   service.sh --json          机器读的状态（WebUI 用）
#   service.sh --set K V [...] 改 config（按行重写；值逐字写入，不经过 shell）
#   service.sh --sepolicy      只重打一遍 sepolicy（免重启修「开发者选项」闪退）
#
# 为什么 ③ 不需要看护进程
# ----------------------
# hyper_bpfloader.rc 里 dynbpfloader 是 `disabled` 服务，唯一的启动点是
#     on property:sys.boot_completed=1 && property:ro.debuggable=1
#         start dynbpfloader
# 这个属性触发器每次开机只触发一次，所以开机后 `setprop ctl.stop dynbpfloader`
# 一次就永久生效，init 不会把它拉回来。实测（Full 分支的看护日志）：停掉之后连续
# 观察 1 小时以上，`stopped again` 一次都没出现。
#
# 为什么不能改用"覆盖 .rc 删掉这个服务"
# ------------------------------------
# 1) init 在 second stage 的 LoadBootScripts() 里一次性解析完所有 .rc，
#    早于 post-fs-data 阶段的模块挂载 —— 覆盖上去也赶不上解析。
# 2) 本机的 KernelSU 是 ReSukiSU 4.x late-load LKM 形态，模块文件**根本不会**被叠到
#    真实文件系统上。实测：往模块里放 system_ext/etc/init/zzprobe.rc，重启后
#    /system_ext/etc/init/zzprobe.rc 不存在，里面那个 `on boot / setprop` 也没生效。
#    （这也正是本模块没有 system/ 目录、② 靠脚本里显式 mount -o bind 的原因。）
#
# 为什么不能动 ro.debuggable
# -------------------------
# 上面那个触发器要求 ro.debuggable=1；把它改成 0 确实能让监视器不启动，但 ② 能装上
# 修补过的 PowerKeeper 正是靠 ro.debuggable=1（这个移植包是 user 构建却标了它，
# PMS 才接受改过的 APK）。关掉它等于把 ② 废掉。所以不动。

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || MODDIR=${0%/*}
CFG="$MODDIR/config"
LOG="$MODDIR/lite.log"

DISABLE_BPFMON="$MODDIR/disable-bpfmon"
DISABLE_TELEPHONY="$MODDIR/disable-telephony"
TELEPHONY_PKGS="com.qti.phone com.qualcomm.qcrilmsgtunnel com.qualcomm.qti.telephonyservice"
PK_STAGE="$MODDIR/payload/app"
PK_PAYLOAD="$PK_STAGE/PowerKeeper.apk"
PK_DIR=/system_ext/app/PowerKeeper
PK_TARGET="$PK_DIR/PowerKeeper.apk"

VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# ---------------------------------------------------------------- 配置读取
# 为什么**不用** `. "$CFG"`：那样 config 会被当 shell 代码执行 —— 值里出现
# 空格、& | ` $ 或引号就会破坏解析（空格让后半段被当成命令，& 变成后台分隔符，
# 反引号 / $( ) 会真的执行）。--set 是逐字写入的，所以这条路迟早会踩到。
# 这里只按行取键值，不执行任何东西。
cfg_raw() { [ -f "$CFG" ] && sed -n "s/^$1=//p" "$CFG" 2>/dev/null | tail -1; }
cfg_on()  { case "$1" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
key_on()  { cfg_on "$(cfg_raw "$1")"; }

# 每一项 = config 键 AND 没有对应 disable-* 标记文件（标记优先级更高）
fix_powerkeeper_enabled() { [ -e "$MODDIR/disable-powerkeeper" ] && return 1; key_on FIX_POWERKEEPER; }
fix_bpfmon_enabled()      { [ -e "$DISABLE_BPFMON" ]           && return 1; key_on FIX_BPFMON; }
fix_telephony_enabled()   { [ -e "$DISABLE_TELEPHONY" ]        && return 1; key_on FIX_TELEPHONY; }

# 给 JSON 用：函数为真输出 1，否则 0
_b() { if "$@" >/dev/null 2>&1; then printf 1; else printf 0; fi; }

# ---------------------------------------------------------------- 状态探测
bpfmon_running() {
    # 只认监视器那个进程。不能只用 pidof hyper_bpfloader —— 同一个二进制也是开机期
    # 那个 oneshot 加载器（service hyper_bpfloader），会误判。
    # [h] 这个写法是为了让 grep 自己的命令行不匹配到自己。
    ps -A -o ARGS 2>/dev/null | grep -q '[h]yper_bpfloader --monitor-mode'
}

pk_mounted() { grep -q " $PK_DIR " /proc/1/mountinfo 2>/dev/null; }

# ---------------------------------------------------------------- ② 必须在 init 的 mount ns 里操作
# KernelSU 执行 service.sh 时给的是一个**独立 mount namespace**（≠ init 的 4026532850）。
# 在那里 mount 只影响脚本自己：日志会写「已挂载」、脚本视角 sha256 也对，
# 但 init / zygote / App 的 ns 里根本没有这条挂载 —— powerkeeper 照旧读 ROM 原件并崩。
# （实测：手工在 init ns 里跑同一个 `service.sh --boot`，powerkeeper 立刻正常起来 pid=17548；
#  而 KernelSU 自己跑出来的那次，日志同样写「已挂载」，进程却仍然 VerifyError。
#  对照组：post-fs-data.sh 那次挂载**确实**落在 init ns —— 所以两个阶段的 ns 不同。）
#
# 所以 ② 的 mount/umount 一律显式切到 init 的 ns：
#   - 判据用 /proc/1/mountinfo（init 的 ns 快照，不受当前 ns 影响）
#   - 操作走 nsenter -t 1 -m --（挂载带 shared:44 传播属性，在 init ns 里建立后
#     会传播到 zygote 与后续 App 的 ns）
PK_SELF_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
PK_INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
PK_NEED_NS=0
if [ -n "$PK_SELF_NS" ] && [ "$PK_SELF_NS" != "$PK_INIT_NS" ] && command -v nsenter >/dev/null 2>&1; then
    PK_NEED_NS=1
fi

pk_ns() {
    if [ "$PK_NEED_NS" = 1 ]; then nsenter -t 1 -m -- "$@"; else "$@"; fi
}

# powerkeeper 进程自己能不能看到补丁 —— 判据是它自己的 mount namespace 里有没有这条挂载。
# 不能只看 /proc/mounts（那是脚本/init 视角）：KernelSU 会把模块挂载从 App 进程的 ns 里
# 卸掉，于是"init 视角有、App 视角没有"这种状态完全可能出现（见上面 do_pk_mount 的注释）。
pk_visible() {
    local p
    p=$(pidof com.miui.powerkeeper 2>/dev/null | awk '{print $1}')
    [ -n "$p" ] || return 1
    grep -q " $PK_DIR " "/proc/$p/mountinfo" 2>/dev/null
}

# ---------------------------------------------------------------- ② PowerKeeper 挂载
# 为什么要在 service.sh 里**再挂一次**（而且必须先 umount）
# ------------------------------------------------------
# KernelSU 会把「模块建立的挂载」从 **App 进程** 的 mount namespace 里卸载掉 ——
# 这是它隐藏 root/模块的设计。实测（本机 ReSukiSU 4.2.0-rc1-52 late-load LKM）：
#
#   post-fs-data 阶段挂的那次
#     → init 视角：挂载在，sha256 = 我们的补丁
#     → com.miui.powerkeeper（uid 1000）视角：**没有这条挂载**，读到 ROM 原件
#       → 开机必崩：java.lang.VerifyError: Verifier rejected class
#          com.miui.powerkeeper.cloudcontrol.LocalUpdateUtils ...
#          [0x1] unexpected non-category 1 return type
#   post-fs-data **之后**重新建立的挂载
#     → init / zygote / 新起的 App 进程都能看到补丁 ✓
#
# 所以这里先 umount 掉 post-fs-data 那次，再原地挂一遍 —— 新挂载实例不在 KernelSU 的
# 记录里，App 就能看到。实测 remount 之后：
#   init(1) / su : mnt ns 4026532850 → 279592be…  ✓
#   zygote64     : 4026534865        → 279592be…  ✓
#   powerkeeper  : 4026535201        → 279592be…  ✓
#
# 为什么挂**父目录**而不是那个 APK 文件：父目录一挂，ROM 预编译的 `oat/` 也一起被盖掉，
# ART 不会再用那份基于坏字节码编出来的 odex。
#
# 代价：umount 与 mount 之间有个极短窗口，那期间路径上是 ROM 原件。
# 这个窗口里没有 App 会去加载它（powerkeeper 由 SystemServer 拉起，比本脚本晚）。
do_pk_mount() {
    [ -f "$PK_PAYLOAD" ] || { log "ERROR ② payload 缺失: $PK_PAYLOAD"; return 1; }
    [ -d "$PK_DIR" ]     || { log "ERROR ② 目标目录不存在: $PK_DIR"; return 1; }

    chown -R 0:0 "$PK_STAGE" 2>/dev/null
    chmod 0755 "$PK_STAGE" 2>/dev/null
    chmod 0644 "$PK_PAYLOAD" 2>/dev/null
    # bind mount 用的是**源文件**的 SELinux 标签，必须是 system_file，
    # 否则 PMS / ART 读到会报 avc denied。
    chcon -R u:object_r:system_file:s0 "$PK_STAGE" 2>/dev/null

    if pk_mounted; then
        pk_ns umount "$PK_DIR" 2>/dev/null || pk_ns umount -l "$PK_DIR" 2>/dev/null
    fi

    if pk_ns mount -t none -o bind "$PK_STAGE" "$PK_DIR" 2>/dev/null; then
        [ "$PK_NEED_NS" = 1 ] && log "② 脚本 ns($PK_SELF_NS) ≠ init ns($PK_INIT_NS)，已用 nsenter 切到 init ns 挂载"
        log "② PowerKeeper 目录已挂载（App 可见）($(sha256sum "$PK_PAYLOAD" 2>/dev/null | cut -c1-16)) ns: self=$PK_SELF_NS init=$PK_INIT_NS need=$PK_NEED_NS"
        return 0
    fi
    # 退路：目录挂不上就退回文件级（至少 PMS / system_server 视角是对的）
    if pk_ns mount -t none -o bind "$PK_PAYLOAD" "$PK_TARGET" 2>/dev/null; then
        log "WARN ② 目录挂载失败，退回文件级挂载（App 进程可能看不到，补丁不生效）"
        return 0
    fi
    log "ERROR ② bind mount 失败（self ns=$PK_SELF_NS init ns=$PK_INIT_NS nsenter=$PK_NEED_NS）"
    return 1
}

# 让 powerkeeper 用新的 mount namespace 重新加载补丁版 APK。
# 时序实测：本脚本 05:41:33 跑到，而 powerkeeper 05:41:19 就已经被 SystemServer 拉起并崩掉，
# 之后 AMS 的崩溃退避会让它越来越久不再重试（1s → 11s → 30min → 1h → 2h）。
# 所以必须**显式拉一次**，不能等它自己起来。
PK_DONE=0
do_pk_restart() {
    [ "$PK_DONE" = 1 ] && return 0
    if pk_visible; then
        log "② powerkeeper 已看到补丁 (pid=$(pidof com.miui.powerkeeper))"
        PK_DONE=1
        return 0
    fi
    # 有进程但看不到 → 它加载的是 ROM 原件，杀掉让它换个 namespace 重来
    local pids
    pids=$(pidof com.miui.powerkeeper 2>/dev/null)
    if [ -n "$pids" ]; then
        log "② powerkeeper 跑在旧 APK 上，重启它（pid=$pids）"
        kill -9 $pids 2>/dev/null
        sleep 1
    fi
    # 显式拉一次：崩过几次之后 AMS 的退避可能已经不再自动重启它
    am start-service -n com.miui.powerkeeper/.PowerKeeperBackgroundService >/dev/null 2>&1
    sleep 3
    if pk_visible; then
        log "② powerkeeper 已用补丁版启动 (pid=$(pidof com.miui.powerkeeper))"
        PK_DONE=1
    else
        log "WARN ② powerkeeper 仍未看到补丁（pid=$(pidof com.miui.powerkeeper)）"
    fi
}

telephony_summary() {
    local p exist disabled n
    exist=$(pm list packages 2>/dev/null)
    disabled=$(pm list packages -d 2>/dev/null)
    n=""
    for p in $TELEPHONY_PKGS; do
        printf '%s\n' "$disabled" | grep -qx "package:$p" && { n="$n $p:disabled"; continue; }
        printf '%s\n' "$exist"    | grep -qx "package:$p" && { n="$n $p:enabled"; continue; }
        n="$n $p:absent"
    done
    printf '%s' "$n"
}

telephony_done_from() {
    # 输入是 telephony_summary 的输出；只要还有 :enabled 的包就算没做完
    case "$1" in
        *":enabled"*) return 1 ;;
        *)            return 0 ;;
    esac
}

# ---------------------------------------------------------------- ③ 停 BPF 监视器
do_bpfmon() {
    if [ -e "$DISABLE_BPFMON" ]; then
        log "③ 被标记文件 disable-bpfmon 关闭"
        return 0
    fi
    if ! fix_bpfmon_enabled; then
        log "③ 已关闭（config FIX_BPFMON=0）"
        return 0
    fi

    local i
    i=0
    while [ "$i" -lt 3 ]; do
        i=$((i+1))
        if ! bpfmon_running && [ "$(getprop init.svc.dynbpfloader)" != "running" ]; then
            [ "$i" = 1 ] && log "③ 监视器未在运行，无需处理"
            break
        fi
        setprop ctl.stop dynbpfloader 2>/dev/null
        sleep 2
    done

    if bpfmon_running; then
        log "WARN ③ 监视器仍在运行（init.svc.dynbpfloader=$(getprop init.svc.dynbpfloader)）"
    else
        log "③ 监视器已停（init.svc.dynbpfloader=$(getprop init.svc.dynbpfloader)）"
    fi
}

# ---------------------------------------------------------------- ④ 停死电话栈
do_telephony() {
    if [ -e "$DISABLE_TELEPHONY" ]; then
        log "④ 被标记文件 disable-telephony 关闭"
        return 0
    fi
    if ! fix_telephony_enabled; then
        log "④ 已关闭（config FIX_TELEPHONY=0）"
        return 0
    fi

    # 只在确实没有电话硬件时才动手 —— 有 modem 的变体上这几个包是正常功能，别误伤。
    local noril p out already new absent fail exist disabled
    noril=$(getprop ro.radio.noril)
    case "$noril" in
        true|yes|1) ;;
        *)
            log "telephony fix skipped (ro.radio.noril='$noril', radio present)"
            return 0
            ;;
    esac

    # 包列表只查一次：pm 每次调用都要起一个 app_process（几百 ms），
    # 三个包各查两遍就是 6 次 pm 调用，开机期没必要。
    exist=$(pm list packages 2>/dev/null)
    disabled=$(pm list packages -d 2>/dev/null)

    already=0; new=0; absent=0; fail=0
    for p in $TELEPHONY_PKGS; do
        printf '%s\n' "$disabled" | grep -qx "package:$p" && { already=$((already+1)); continue; }
        # 包根本不在本机 → 跳过（实测 HyperOS 3 的 TB378FC 上这三个包一个都不存在；
        # 对不存在的包 pm disable-user 会抛 IllegalArgumentException 并以非 0 退出，
        # 于是每次开机刷 3 行 ERROR + 一段 Java 栈，而 ④ 要保证的东西本来就天然达成）。
        printf '%s\n' "$exist"    | grep -qx "package:$p" || { absent=$((absent+1)); continue; }
        # 必须 root（本脚本由 KernelSU 以 root 启动）。以 shell UID 跑会被
        # shouldRestrictEnabledSettingsChange 拦下。
        if out=$(pm disable-user --user 0 "$p" 2>&1); then
            log "telephony disabled: $p"
            new=$((new+1))
        else
            log "ERROR telephony disable failed: $p: $out"
            fail=$((fail+1))
        fi
    done

    # 汇总一行。注意别把"失败"说成"没事"。
    if [ "$fail" -gt 0 ]; then
        log "telephony summary: $new disabled, $already already, $absent absent, $fail FAILED"
    elif [ "$new" -eq 0 ]; then
        if [ "$already" -eq 0 ] && [ "$absent" -gt 0 ]; then
            log "telephony stack n/a ($absent pkg absent on this ROM, nothing to do)"
        else
            log "telephony stack already disabled ($already pkg, $absent absent)"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------- ⑭ sepolicy
do_sepolicy() {
    # 规则已经写在 sepolicy.rule 里（KernelSU 开机会自动加载），但实测在 ReSukiSU 4.x
    # late-load LKM 上**纯声明式加载并不可靠** —— 出现过"删掉模块重启后原始 denial 又回来了"。
    # 所以用 ksud 的运行时通道显式再应用一遍：它会触发一次策略重载，顺带刷新内核 AVC 与
    # init 用户态 libselinux 里的陈旧拒绝缓存。
    # 注意：ksud sepolicy apply 是"按传入文件重新推导并应用"，**不会跨调用累积**，
    # 所以必须传**完整**的 sepolicy.rule。本项没有开关：它是崩溃修复，不是可选功能。
    local KSUD="" c
    for c in /data/adb/ksud /data/adb/ksu/bin/ksud; do
        if [ -x "$c" ]; then KSUD="$c"; break; fi
    done
    if [ -n "$KSUD" ]; then
        "$KSUD" sepolicy apply "$MODDIR/sepolicy.rule" >/dev/null 2>&1
        log "⑭ sepolicy apply rc=$? ($KSUD)"
    else
        log "⑭ 找不到 ksud，跳过显式应用（规则仍由 KernelSU 声明式加载）"
    fi
}

# ---------------------------------------------------------------- 开机动作
wait_boot_completed() {
    local i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 300 ]; do
        sleep 2
        i=$((i+1))
    done
    # 再等一会儿：dynbpfloader 由 `on property:sys.boot_completed=1` 触发启动，
    # 属性置位与服务真正起来之间有一小段间隔。
    sleep 15
}

boot_actions() {
    [ -e "$MODDIR/disable" ] && { log "模块已被 disable 标记停用，跳过"; return 0; }

    # ② 第一次尝试（late_start 阶段，boot_completed 之前）：
    # 能成就最好（那样 powerkeeper 一次都不用崩），成不了下面还会重来。
    if fix_powerkeeper_enabled; then
        do_pk_mount
        do_pk_restart
    fi

    wait_boot_completed
    log "--- Lite 开机动作开始（$VERSION）---"

    # ② 关键的一次：**必须在 boot_completed 之后重挂**。
    # 实测（本机 ReSukiSU 4.2.0-rc1-52）：同样是 init ns 里的 umount + mount 同一路径，
    #   late_start 阶段做 → App 进程仍然读到 ROM 原件，powerkeeper 照旧 VerifyError；
    #   系统完全起来之后做 → 新起的 App 进程立刻读到补丁版。
    # 日志里两次的 ns 与 mnt_id 都相同（mnt_id 226 —— Linux 的 ida 会复用最小空闲 id），
    # 所以这不是"挂错了地方"，而是**挂载生效的时机**问题。早期那次挂载本身不算白做：
    # 万一别的 KernelSU 版本/机型上它就能生效，那就一次都不用崩。
    if fix_powerkeeper_enabled && ! pk_visible; then
        log "② boot_completed 之后重挂一次（late_start 那次对 App 不可见）"
        local i=0
        while [ "$i" -lt 3 ]; do
            i=$((i+1))
            do_pk_mount
            PK_DONE=0
            do_pk_restart
            pk_visible && break
            [ "$i" -lt 3 ] && { log "② 第 $i 次重挂后仍不可见，等 10s 再试"; sleep 10; }
        done
    fi

    do_bpfmon
    do_telephony
    do_sepolicy
    log "--- Lite 开机动作结束，本脚本退出（无任何常驻进程）---"
}

# ---------------------------------------------------------------- 改配置
set_cfg() {
    local _k="$1" _v="$2" _tmp _found _line
    shift 2
    [ -n "$_k" ] || return 1
    # 键名白名单：避免键名里混进 shell 元字符去影响下面的 sed/case
    case "$_k" in *[!A-Za-z0-9_]*) return 1 ;; esac
    _tmp="$CFG.tmp.$$"
    _found=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            "$_k="*) printf '%s=%s\n' "$_k" "$_v"; _found=1 ;;
            *)       printf '%s\n' "$_line" ;;
        esac
    done < "$CFG" > "$_tmp"
    [ "$_found" = 1 ] || printf '%s=%s\n' "$_k" "$_v" >> "$_tmp"
    mv -f "$_tmp" "$CFG" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    chmod 600 "$CFG" 2>/dev/null
    chown 0:0 "$CFG" 2>/dev/null
    log "config: $_k=$_v"
    return 0
}

# ---------------------------------------------------------------- 状态输出
markers_list() {
    local m out=""
    for m in disable disable-powerkeeper disable-bpfmon disable-telephony; do
        [ -e "$MODDIR/$m" ] && out="$out $m"
    done
    printf '%s' "$out"
}

json_out() {
    local mk ts td
    mk=$(markers_list)
    # telephony_summary 要跑两次 pm（每次几百 ms），所以只算一次，两处共用。
    ts=$(telephony_summary)
    if telephony_done_from "$ts"; then td=1; else td=0; fi
    printf '{"FIX_POWERKEEPER":%s,"FIX_BPFMON":%s,"FIX_TELEPHONY":%s,' \
        "$(_b fix_powerkeeper_enabled)" "$(_b fix_bpfmon_enabled)" "$(_b fix_telephony_enabled)"
    printf '"NEED_APP":0,"VERSION":"%s",' "$VERSION"
    printf '"BPFMON_SVC":"%s","BPFMON_RUNNING":%s,' \
        "$(getprop init.svc.dynbpfloader)" "$(_b bpfmon_running)"
    printf '"POWERKEEPER_MOUNTED":%s,' "$(_b pk_mounted)"
    printf '"POWERKEEPER_SEEN":%s,' "$(_b pk_visible)"
    printf '"POWERKEEPER_PAYLOAD":%s,' "$([ -f "$PK_PAYLOAD" ] && printf 1 || printf 0)"
    printf '"TELEPHONY_DONE":%s,"TELEPHONY_STATE":"%s",' "$td" "$ts"
    printf '"MARKERS":"%s"}\n' "$mk"
}

status_out() {
    echo "TB378FC HyperOS 修复 Lite  $VERSION"
    echo "模块目录: $MODDIR"
    echo
    echo "② PowerKeeper 补丁     : $(_b fix_powerkeeper_enabled)   已挂载: $(_b pk_mounted)   App 可见: $(_b pk_visible)   pid=$(pidof com.miui.powerkeeper)"
    echo "③ 停 BPF 监视器        : $(_b fix_bpfmon_enabled)   dynbpfloader=$(getprop init.svc.dynbpfloader)  监视器进程: $(_b bpfmon_running)"
    echo "④ 停死电话栈           : $(_b fix_telephony_enabled)   $(telephony_summary)"
    echo "⑭ 开发者选项 sepolicy  : 常开（无开关）"
    echo
    echo "标记文件:$(markers_list)"
    echo
    echo "常驻进程: 本模块不产生任何常驻进程（开机动作执行一次即退出）"
    echo "日志: $LOG"
    if [ -f "$LOG" ]; then
        echo "--- 日志尾部 ---"
        tail -12 "$LOG"
    fi
}

# ---------------------------------------------------------------- 入口
case "${1:-}" in
    "")
        # KernelSU 在 late_start 阶段跑本脚本。用 setsid 放后台后立刻返回：
        # KernelSU 通过 init 运行本脚本，普通的 "&" 子进程活不过脚本本身；
        # 而且**必须立刻返回** —— 我们要等 boot_completed，而 boot_completed 是在
        # late_start 之后才置位的，同步等待会把开机卡死。
        setsid /system/bin/sh "$0" --boot >/dev/null 2>&1 </dev/null &
        exit 0
        ;;

    --boot)
        boot_actions
        exit 0
        ;;

    --sepolicy)
        do_sepolicy
        exit 0
        ;;

    --status)
        status_out
        exit 0
        ;;

    --json)
        json_out
        exit 0
        ;;

    --set)
        shift
        [ -n "${1:-}" ] || { echo "用法: service.sh --set KEY VALUE [KEY VALUE ...]" >&2; exit 2; }
        rc=0
        while [ -n "${1:-}" ]; do
            k="$1"; v="${2:-}"
            [ -n "${2:-}" ] || { echo "缺少 $k 的值" >&2; rc=2; break; }
            set_cfg "$k" "$v" || { echo "写入失败: $k" >&2; rc=2; }
            shift 2
        done
        exit "$rc"
        ;;

    -h|--help)
        sed -n '5,20p' "$0"
        exit 0
        ;;

    *)
        echo "未知参数: $1（-h 看用法）" >&2
        exit 2
        ;;
esac
