#!/system/bin/sh
# TB378FC HyperOS 修复 —— 服务脚本
#
# 本模块做五件事：
#   ① 手写笔唤醒   —— 否则笔闲置后 MCU 休眠、蓝牙却仍显示已连接，笔看起来"死了"
#   ② PowerKeeper  —— 见 post-fs-data.sh（修补移植包改坏的两处字节码）
#   ③ 停 BPF 监视器 —— 否则开 DroidSpaces 容器后会被 hyper_bpfloader 重启进 recovery
#   ④ 停死电话栈   —— 否则移植包自带的 persistent 电话组件每秒崩几百次，
#                     白烧 zygote / system_server，并连带把系统 feature flags 反复重置
#   ⑤ 手写笔胶囊   —— 吸附时弹 HyperOS 原生的电量胶囊（否则这支联想笔在系统眼里不存在）
#
# ① 的原理
# --------
# 笔闲置后 MCU 休眠，但蓝牙控制器继续维持 HOGP 连接 —— 所以"蓝牙还连着"是假象。
# 休眠期间笔尖不出信号、滑条不响应、马达不振动。只有线圈（磁吸）能唤醒它。
# 联想自己的软件（ZUX）会在磁吸"取下"的边沿发一条 BLE 唤醒命令：
#     service        0000fe40-cc7a-482a-984a-7f2ed5b3e512
#     characteristic 0000fe41-cc7a-482a-984a-7f2ed5b3e512
#     payload        {0x05, 0x05}
# HyperOS 没有手写笔软件栈，没人发这条命令，所以本模块补上。
#
# 触发源只认吸附状态（/sys/class/power_supply/wls_tx/attached），与屏幕状态无关：
#     1 -> 0  取下笔      发唤醒命令
#     0 -> 1  吸附笔      弹原生电量胶囊（见 ⑤）
#     启动时若笔已取下    补发一次唤醒
#
# ⑤ 的原理
# --------
# 胶囊不是 SystemUI 画的，而是 SecurityCoreAdd（com.miui.securitycore）里
# com.miui.miinput.stylus 那套；原生由小米笔的 MIPP/BLE 协议栈
# （BluetoothExtension 的 MiuiBleOobHelperService）发广播驱动：
#     com.android.settings.stylus.STYLUS_STATE_SOC   extras: battery / state / connect
# 联想笔走普通 BT HID，不说 MIPP，所以谁都不发。这里在吸附边沿读反向无线充电线圈看到的
# 笔电量（/sys/class/power_supply/wls_tx/level），把 ATTACH 广播交给 PenBridge，
# 由它转成上面那条原生广播；GATT 能读到真值时再补一条校正。
# 参数语义、前置条件与踩坑见 docs/native-stylus-capsule.md。
#
# ③ 的原理
# --------
# hyper_bpfloader 的监视器（dynbpfloader，boot_completed 后由 init 启动）会检查 MIUI
# 私有 BPF 程序 MiuiMmStat / MiuiMmTrace 是否已 pin。这套 .o 带 min_kver/max_kver
# 检查并引用 6.10+ 的内核符号，而本机内核是 6.6.82，89 个程序一个都加载不了。
# 监视器据此判定"系统损坏"，于是写 recovery 引导块并 reboot,recovery ——
# 实测：不开容器时它会一直忍着，一旦使用 DroidSpaces 容器就会触发（已复现 3 次）。
# 那 89 个程序是内存遥测数据，缺了不影响使用；监视器在本内核上唯一还在干的事就是重启设备。
# 所以这里在开机后把它停掉。开机期由 hyper_bpfloader 本体加载的约 50 个 BPF 不受影响。
#
# ④ 的原理
# --------
# 本机 ro.baseband=apq —— 纯应用处理器，没有集成 modem，是 Wi-Fi 版。厂商的
# init.class_main.sh 正是对 apq|sda|qcs 置 ro.vendor.radio.noril=yes，再经
# init.qcom.rc 传播成 ro.radio.noril。框架因此**没有 FEATURE_TELEPHONY**。
#
# 但移植包原样搬来了小米/QTI 的电话栈，而且声明成 persistent：
#     /system_ext/priv-app/QtiTelephony/QtiTelephony.apk   → com.qti.phone
# 没有 telephony 特性 → CarrierConfigManager 根本不注册 → getSystemService 返回 null：
#     ExtTelephonyServiceImpl.<init>(ExtTelephonyServiceImpl.java:178)
#       → new NrUwbConfigsController(...)
#         → NrUwbConfigsController.java:67 对 null 调 registerCarrierConfigChangeListener
#         → NullPointerException → FATAL EXCEPTION: main，进程当场死
#
# 而 com.android.phone 和 com.android.systemui 各持一条到
# com.qti.phone/.ExtTelephonyService 的活绑定（dumpsys activity 里 connections=3，
# 服务本身 app=null 但客户端不松手），服务又是 persistent，AMS 便以 0ms 延迟
# 无限重启它。实测约 670 次/秒：
#     Start proc ...:com.qti.phone for restart → has died: pers PER
#     → Re-adding persistent process → Scheduling restart of crashed service in 0ms
#     → has crashed too many times, killing! → 再来一遍
#
# 代价全记在 zygote 和 system_server 头上（静置时尤其明显，因为别的负载都停了）：
#     每次循环 fork 一个新进程    → zygote64 11~15% CPU（主线程除了 fork 什么都不干）
#     每次循环走一遍 AMS 进程管理 → system_server 30~46% CPU，其中内核态约 22%
#     异常栈写日志               → logd 7%，约 440 KB/s，开机 11 分钟 703 MB
# 连带 init 的 flags_health_check 每秒被触发几十次，反复重置系统 feature flags；
# RescueParty 持续为这三个 persistent 包评估 remediation。
#
# 硬件上 modem 分区虽然在（modem_a/modem_b/fsg/fsc/modemst1/2），但 ro.baseband=apq
# 说明没有可用 modem，电话功能永远起不来 —— 这三个包在本机是纯死代码，停掉零损失。
#
# 三个坑：
#   1. 必须 root。HyperOS 的 PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange
#      会拒绝 shell 改系统包的启用状态（SecurityException: Cannot disable system packages），
#      以 shell UID 跑 pm disable-user 一定失败。本脚本由 KernelSU 以 root 启动，正好可用。
#   2. pm suspend 没用。实测 suspend 之后 persistent 进程照样被拉起，崩溃数纹丝不动；
#      只有 package disable 才真正切断这条重启链。组件级 disable 在 root 下也可行，
#      但包级更彻底（连 persistent 进程本身都不再启动）。
#   3. 停用不会杀掉已经在跑的 persistent 进程，而且**手动 kill 也压不住**：实测 kill 之后
#      AMS 立刻重新拉起一个新的（就是日志里那句 Re-adding persistent process），换一次
#      kill 得一次重启，之后稳定成一个空转进程（约 131 MB RSS，0% CPU）。组件级 enabled
#      设成 default 也一样。所以本模块不做这个无用的 kill —— 残留进程不烧 CPU，
#      不影响修复效果；真正要命的那条崩溃重启链已经被 package disable 掐断了。
#
# 停用状态落在 /data/system/packages.xml，本身就跨重启保持。这里每次开机仍复查一次，
# 以防 ROM 更新或包重装把状态冲掉；已是 disabled 的包不会重复处理。
#
# 进程模型
# --------
#   service.sh                  一次性 setup，由 KernelSU 启动
#     service.sh --supervise    用 setsid 脱离，持有锁，负责重启 monitor
#     service.sh --monitor      实际的吸附状态机
#     service.sh --stopbpfmon   等 boot_completed 后停掉 BPF 监视器
#     service.sh --fixtelephony 等 boot_completed 后停掉死电话栈（一次即可，不需看护）
#
# 单独关闭某一项：在模块目录下建对应的标记文件即可，四项互不影响。
#     disable              ① 手写笔守护
#     disable-powerkeeper  ② PowerKeeper 补丁（见 post-fs-data.sh）
#     disable-bpfmon       ③ BPF 监视器拆弹
#     disable-telephony    ④ 死电话栈
#     disable-capsule      ⑤ 吸附胶囊（只关胶囊，唤醒照常）

MODDIR=${0%/*}
LOG="$MODDIR/wake.log"
LOCK="$MODDIR/.monitor.lock"
DISABLE="$MODDIR/disable"
DISABLE_BPFMON="$MODDIR/disable-bpfmon"
DISABLE_TELEPHONY="$MODDIR/disable-telephony"
DISABLE_CAPSULE="$MODDIR/disable-capsule"
CFG="$MODDIR/config"
ATT=/sys/class/power_supply/wls_tx/attached
# ⑤ 胶囊：反向无线充电线圈看到的笔电量/充电状态（root 才读得到）
WLS_LEVEL=/sys/class/power_supply/wls_tx/level
WLS_CHG=/sys/class/power_supply/wls_tx/charge_state
PKG=dev.tb378fc.stylus
RCV="$PKG/.WakeReceiver"
APK="$MODDIR/bin/PenBridge.apk"
A_WAKE=dev.tb378fc.stylus.WAKE
A_ATTACH=dev.tb378fc.stylus.ATTACH

# ④：本机无 modem（ro.baseband=apq），这三个包是移植包原样带过来的死代码
TELEPHONY_PKGS="com.qti.phone com.qualcomm.qcrilmsgtunnel com.qualcomm.qti.telephonyservice"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 可选配置项；未知键自然被忽略
REFRESH_SECONDS=0
CAPSULE=1
[ -f "$CFG" ] && . "$CFG" 2>/dev/null

refresh_seconds() {
    local v="$REFRESH_SECONDS"
    case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

# ⑤ 是否要弹胶囊：config CAPSULE=1（默认）且没有 disable-capsule 标记
capsule_enabled() {
    [ -e "$DISABLE_CAPSULE" ] && return 1
    case "$CAPSULE" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

# 读一个 sysfs 整数，非法时回落到默认值
read_int() {
    local v
    v=$(cat "$1" 2>/dev/null)
    case "$v" in ''|*[!0-9-]*) echo "$2" ;; *) echo "$v" ;; esac
}

read_att() {
    local v
    v=$(cat "$ATT" 2>/dev/null)
    case "$v" in 0|1) echo "$v" ;; *) echo "$1" ;; esac
}

install_apk() {
    local old new
    old=$(sha256sum "$APK" 2>/dev/null | cut -c1-16)
    new="$old"
    if [ ! -f "$MODDIR/.apk.sha" ] || [ "$(cat "$MODDIR/.apk.sha" 2>/dev/null)" != "$old" ] \
            || [ -z "$(pm path $PKG 2>/dev/null)" ]; then
        if pm install --user 0 -r "$APK" >/dev/null 2>&1; then
            echo "$new" > "$MODDIR/.apk.sha"
            log "control apk installed ($new)"
        else
            log "ERROR apk install failed"
        fi
    fi
    pm grant --user 0 $PKG android.permission.BLUETOOTH_CONNECT >/dev/null 2>&1
    pm grant --user 0 $PKG android.permission.BLUETOOTH_SCAN >/dev/null 2>&1
}

send() {
    if am broadcast --user 0 -n "$RCV" -a "$1" >/dev/null 2>&1; then
        log "$2 sent"
    else
        log "ERROR $2 failed"
    fi
}

# ⑤ 前置：SecurityCoreAdd 的胶囊代码只在"不是首次连接"时才弹电量胶囊，否则走首次引导。
# 这两个 key 是"首次连接引导已看过"的标记（未设置时 getIntForUser 取 0 → 判定为首次）。
prepare_stylus_settings() {
    local cur
    cur=$(settings get secure stylus_first_connect 2>/dev/null)
    if [ "$cur" != "1" ]; then
        if settings put secure stylus_first_connect 1 >/dev/null 2>&1; then
            log "stylus_first_connect 1 (was ${cur:-unset})"
        else
            log "ERROR stylus_first_connect write failed"
        fi
    fi
    cur=$(settings get secure touch_film_stylus_first_connect 2>/dev/null)
    if [ "$cur" != "1" ]; then
        if settings put secure touch_film_stylus_first_connect 1 >/dev/null 2>&1; then
            log "touch_film_stylus_first_connect 1 (was ${cur:-unset})"
        fi
    fi
}

# ⑤ 吸附边沿：把线圈读到的笔电量/充电状态交给 PenBridge，由它去发
#    com.android.settings.stylus.STYLUS_STATE_SOC（参数语义见 docs/native-stylus-capsule.md）。
#    battery 非法（非 0..100）时传 -1，让 App 自己走 GATT 读。
send_attach() {
    local batt state chg
    batt=$(read_int "$WLS_LEVEL" -1)
    case "$batt" in ''|*[!0-9]*) batt=-1 ;; esac
    if [ "$batt" -lt 0 ] || [ "$batt" -gt 100 ]; then batt=-1; fi
    # 吸附边沿上笔就是在充电线圈上，state=4（图标带闪电）；coil_chg 只写进日志备查
    state=4
    chg=$(read_int "$WLS_CHG" -1)
    if am broadcast --user 0 -n "$RCV" -a "$A_ATTACH" \
            --ei battery "$batt" --ei state "$state" >/dev/null 2>&1; then
        log "attach-capsule sent (battery=$batt state=$state coil_chg=$chg)"
    else
        log "ERROR attach-capsule failed"
    fi
}

# ④ 停死电话栈。原理见文件头 ④。
# 幂等：已经是 disabled 的包不动，全部已停就不写日志刷屏。
fix_telephony() {
    local noril p out already new

    # 只在确实没有电话硬件时才动手 —— 有 modem 的变体上这几个包是正常功能，别误伤。
    noril=$(getprop ro.radio.noril)
    case "$noril" in
        true|yes|1) ;;
        *)
            log "telephony fix skipped (ro.radio.noril='$noril', radio present)"
            return 0
            ;;
    esac

    already=0
    new=0
    for p in $TELEPHONY_PKGS; do
        if pm list packages -d 2>/dev/null | grep -qx "package:$p"; then
            already=$((already+1))
            continue
        fi
        # 必须 root（本脚本由 KernelSU 以 root 启动）。以 shell UID 跑会被
        # shouldRestrictEnabledSettingsChange 拦下。
        if out=$(pm disable-user --user 0 "$p" 2>&1); then
            log "telephony disabled: $p"
            new=$((new+1))
        else
            log "ERROR telephony disable failed: $p: $out"
        fi
    done

    [ "$new" -eq 0 ] && log "telephony stack already disabled ($already pkg)"
    return 0
}

# 判断记录的 pid 是不是**我们自己的** supervisor。
# 只做 kill -0 是不够的：pid 会被复用。重启后新进程占住同一个号，setup 就会误判
# "supervisor 还活着" 并提前 exit 0，而那句 exit 0 在 ③④① 启动之前 —— 整个模块静默不跑。
# 实测 2914 被 vendor.qti.hardware.soter-service 占用即触发。
# 所以再核对一次 /proc/<pid>/cmdline，确认确实是本脚本的 --supervise。
supervisor_alive() {
    local pid="$1" cl
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cl" in
        *service.sh*--supervise*) return 0 ;;
    esac
    return 1
}

case "$1" in

--stopbpfmon)
    # 见文件头 ③。监视器由 init 在 boot_completed 后启动；ctl.stop 会让 init 不再自动拉起它，
    # 但实测本机它会被别的东西重新拉起来（观察到一次：开机很久之后又出现一个
    # hyper_bpfloader --monitor-mode），所以只停一次不够，要一直看护。
    [ -e "$DISABLE_BPFMON" ] && exit 0
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 300 ]; do
        sleep 2
        i=$((i+1))
    done
    sleep 20
    log "bpf monitor watchdog up (will keep dynbpfloader down)"
    was=0
    while [ ! -e "$DISABLE_BPFMON" ]; do
        if pidof hyper_bpfloader >/dev/null 2>&1; then
            setprop ctl.stop dynbpfloader 2>/dev/null
            sleep 2
            if pidof hyper_bpfloader >/dev/null 2>&1; then
                log "WARN bpf monitor survived ctl.stop; rescue reboot remains possible"
            elif [ "$was" = 0 ]; then
                log "bpf monitor stopped (hyper_bpfloader rescue reboot defused)"
                was=1
            else
                log "bpf monitor stopped again (something had restarted it)"
            fi
        fi
        sleep 60
    done
    exit 0
    ;;

--fixtelephony)
    # 见文件头 ④。这是一次性动作，不需要常驻看护：停用状态本身写在 packages.xml 里
    # 跨重启保持，这里只是每次开机复查一遍，防止 ROM 更新/包重装把状态冲掉。
    [ -e "$DISABLE_TELEPHONY" ] && exit 0

    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 300 ]; do
        sleep 2
        i=$((i+1))
    done
    sleep 10

    fix_telephony
    exit 0
    ;;

--supervise)
    echo $$ > "$LOCK/pid"
    log "supervisor up pid=$$"
    while [ ! -e "$DISABLE" ]; do
        /system/bin/sh "$0" --monitor
        [ -e "$DISABLE" ] && break
        log "monitor exited; respawning in 5s"
        sleep 5
    done
    log "supervisor exit"
    rm -rf "$LOCK" 2>/dev/null
    exit 0
    ;;

--monitor)
    [ -e "$DISABLE" ] && exit 0

    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 300 ]; do
        sleep 1
        i=$((i+1))
    done
    sleep 10

    install_apk

    REFRESH=$(refresh_seconds)
    last_att=$(read_att 1)
    tick=0
    if capsule_enabled; then
        prepare_stylus_settings
        log "monitor start attached=$last_att refresh=${REFRESH}s capsule=on"
    else
        log "monitor start attached=$last_att refresh=${REFRESH}s capsule=off"
    fi

    if [ "$last_att" = 0 ]; then
        send "$A_WAKE" "startup-wake"
    fi

    while [ ! -e "$DISABLE" ]; do
        sleep 1
        tick=$((tick+1))
        att=$(read_att "$last_att")

        if [ "$last_att" = 1 ] && [ "$att" = 0 ]; then
            send "$A_WAKE" "detach-wake"
            tick=0
        elif [ "$last_att" = 0 ] && [ "$att" = 1 ]; then
            # ⑤ 吸附：等线圈跟笔握上手（约 1~2 秒）再读 wls_tx/level，然后弹原生胶囊
            if capsule_enabled; then
                sleep 2
                send_attach
            fi
            tick=0
        elif [ "$att" = 0 ] && [ "$REFRESH" -gt 0 ] && [ "$tick" -ge "$REFRESH" ]; then
            send "$A_WAKE" "refresh-wake"
            tick=0
        fi

        last_att=$att

        if [ $((tick % 600)) -eq 0 ] && [ -f "$LOG" ] &&
                [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 262144 ]; then
            mv -f "$LOG" "$LOG.1" 2>/dev/null
        fi
    done

    log "monitor exit (disable file present)"
    exit 0
    ;;

*)
    # ---- setup（一次性）----
    # 硬性递归保护：脱离出去的子进程绝不能再次进入这个分支。
    if [ -n "$PENWAKE_CHILD" ]; then
        log "refusing to re-enter setup stage (PENWAKE_CHILD set)"
        exit 0
    fi

    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 262144 ]; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi

    # 只允许一个 supervisor：记录的 pid 必须确实是**我们自己的**活进程，否则可以接管。
    # 见 supervisor_alive()：单靠 kill -0 会被 pid 复用骗到。
    if [ -f "$LOCK/pid" ]; then
        old=$(cat "$LOCK/pid" 2>/dev/null)
        if supervisor_alive "$old"; then
            log "supervisor already alive pid=$old"
            exit 0
        fi
    fi

    rm -rf "$LOCK" 2>/dev/null
    mkdir -p "$LOCK" 2>/dev/null || exit 0

    # ③ BPF 监视器拆弹、④ 死电话栈、① 唤醒守护三者各自独立，互不依赖。
    if [ ! -e "$DISABLE_BPFMON" ]; then
        setsid /system/bin/sh "$0" --stopbpfmon >/dev/null 2>&1 </dev/null &
    fi

    if [ ! -e "$DISABLE_TELEPHONY" ]; then
        setsid /system/bin/sh "$0" --fixtelephony >/dev/null 2>&1 </dev/null &
    fi

    # setsid：KernelSU 通过 init 运行本脚本，普通的 "&" 子进程活不过脚本本身。
    PENWAKE_CHILD=1 setsid /system/bin/sh "$0" --supervise >/dev/null 2>&1 </dev/null &
    sleep 2
    log "setup done; supervisor pid=$(cat "$LOCK/pid" 2>/dev/null)"
    exit 0
    ;;
esac
