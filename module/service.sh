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
DISABLE_GESTURE="$MODDIR/disable-gesture"
DISABLE_ROMPEN="$MODDIR/disable-rompen"
DISABLE_BRUSH="$MODDIR/disable-brush"
PEN_TOUCH_NODE=/dev/input/event5        # NVTCapacitivePen（笔尖/笔尾都在这个节点上）
BRUSH_STATE="$MODDIR/brush.state"       # 当前已经发给笔的波形（空 = 无）
BRUSH_BASE="$MODDIR/brush.base"         # 当前笔刷对应的波形（笔尾离开时恢复它）
BRUSH_TAIL="$MODDIR/brush.tail"         # 1 = 笔尾（橡皮端）在感应范围内
# 由 LSPosed hook 写在**被 hook 的 App** 自己的 files 目录里（canvas=1/0），按顺序找
PENSTATE_LIST="/data/data/com.miui.creation/files/penstate /data/data/com.miui.notes/files/penstate /data/data/dev.tb378fc.stylus/files/penstate"
BRUSH_LOG="$MODDIR/brush.log"
PENRING_BIN="$MODDIR/bin/penring"
PENRING_PID="$MODDIR/penring.pid"
CFG="$MODDIR/config"
ATT=/sys/class/power_supply/wls_tx/attached
# ⑤ 胶囊：反向无线充电线圈看到的笔电量/充电状态（root 才读得到）
WLS_LEVEL=/sys/class/power_supply/wls_tx/level
WLS_CHG=/sys/class/power_supply/wls_tx/charge_state
PKG=dev.tb378fc.stylus
RCV="$PKG/.WakeReceiver"
APK="$MODDIR/bin/PenBridge.apk"
A_WAKE=dev.tb378fc.stylus.WAKE
A_HAPTIC=dev.tb378fc.stylus.HAPTIC
A_ATTACH=dev.tb378fc.stylus.ATTACH
# ⑤ 原生胶囊广播（发给 SecurityCoreAdd）
A_SOC=com.android.settings.stylus.STYLUS_STATE_SOC
SOC_RCV=com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver

# ④：本机无 modem（ro.baseband=apq），这三个包是移植包原样带过来的死代码
TELEPHONY_PKGS="com.qti.phone com.qualcomm.qcrilmsgtunnel com.qualcomm.qti.telephonyservice"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 可选配置项；未知键自然被忽略
REFRESH_SECONDS=0
CAPSULE=1
# 吸附检测的轮询间隔（毫秒）。检测靠轮询 sysfs，间隔越小弹得越快：
#   200 = 默认，最坏 0.2s 发现吸附；500/1000 更省电但更迟钝
POLL_MS=200
# 1 = 守护自己直接发原生 STYLUS_STATE_SOC（省掉 App 一跳，最快）
# 0 = 只发 ATTACH 给 PenBridge，由 App 组装（多一跳）
CAPSULE_DIRECT=1
# 1 = 直发之后，再让 PenBridge 走 GATT 读一次真电量，不同则补一条校正
CAPSULE_GATT=1
# 1（默认）= 边沿一到就先用**上一次的线圈电量**弹一条（~0.2s 出胶囊），1~2 秒后拿新值刷新；
# 0 = 不抢跑，等线圈报出新值再弹（慢 1~2 秒，但第一眼就是本次的电量）
CAPSULE_FAST=0
# ⑥ 笔端触控膜功能位 {8,6,mask}：63=0x3F 全开（双击/三击/上滑/下滑/捏合/笔尾）；
#    -1 = 只唤醒不改位。位定义见 docs/zuxos-pen-protocol.md §2.1
TOUCHFILM=63
# ⑥ 手势桥开关：1 = 起 penring（默认），0 = 不起；也可以建 disable-gesture 标记文件
GESTURE=1
# ⑥ 手势 → Android 键码映射（改完重启模块生效；-1 = 关掉这一条）
#   194 轻捏=快捷环 · 195 双击 · 196 上滑 · 197 下滑
#   92 截图键 / 93 速记键（"按住 + 点屏幕"那套），笔尾那个键默认映射成截图键
GESTURE_RING=194
GESTURE_DOUBLE=195
GESTURE_SLIDE_UP=196
GESTURE_SLIDE_DOWN=197
GESTURE_TAIL=92
# ⑥ 把"设置 → 手写笔"里的双击开关/轻捏开关/轻捏力度实时路由给笔（1 = 开，默认）
SETTINGS_SYNC=1
# ⑦ 笔刷触感：读笔记/小米创作的当前笔刷，给笔发一次 CON 波形（笔自己就持续按这个手感振）
BRUSH=1
BRUSH_APPS="com.miui.notes com.miui.creation"
BRUSH_LEVEL=3
BRUSH_FRICTION=1
# current_brush 编号（小米创作/笔记实测）-> CON 波形
#   1 钢笔 / 2 圆珠笔 / 3 铅笔 / 4 马克笔 / 10 毛笔
#   波形：32 圆珠笔 / 33 铅笔 / 34 马克笔 / 35 橡皮 / 36 联想笔刷 / 37..41 无音效版
BRUSH_MAP="1:32,2:32,3:33,4:34,10:36"
# 工具状态 select_state_save 取这些值时当作"橡皮"（UI 里选橡皮时 current_brush 不变）
# 用一个新值就把它加进来，多个用空格分隔
BRUSH_ERASER_STATES=""
BRUSH_STATE_KEYS="current_brush select_state_save ai_type current_ai_brush"
BRUSH_ERASER=35                              # 笔尾（橡皮端）靠近时用的波形
# AI 笔：它不改 current_brush（用 current_ai_brush=true 标识）
BRUSH_AI_WAVE=36
# 框选笔：同样不改 current_brush，用 select_state_save 的值标识（看日志填，逗号分隔）
BRUSH_LASSO_STATES=""
BRUSH_LASSO_WAVE=36
# 认不出的编号统一用这个波形
BRUSH_DEFAULT_WAVE=36
BRUSH_EXIT_CHECK=1                           # 退出应用后自动停波形
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

# ⑥ 手势桥 penring：把联想笔的捏/双击/上滑/下滑/笔尾桥成小米焦点触控笔的键。
#    由 supervisor 看护（笔不在时它自己每 2 秒轮询，不占 CPU）。见 docs/stylus-gesture-bridge.md
gesture_enabled() {
    [ -e "$DISABLE_GESTURE" ] && return 1
    case "$GESTURE" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

penring_alive() {
    local p
    p=$(cat "$PENRING_PID" 2>/dev/null)
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    # 只认 cmdline 里确实是我们的二进制，防止 pid 复用
    grep -qa "penring" "/proc/$p/cmdline" 2>/dev/null
}

# ⑥ 把"设置 → 手写笔"里的开关/力度翻译成笔端命令：
#     双击开/关   -> {8,6,mask} bit0（0x01）
#     轻捏开/关   -> {8,6,mask} bit4（0x10）
#     轻捏力度    -> {8,5,level}，level = stylus_pinch_pressure_adjust + 1（1 轻..5 重）
#   上滑/下滑（bit2|3）和笔尾（bit5）由本模块的 GESTURE_* 决定，一直开着。
#   MIUI 自己那份设置是给"小米笔"用的：它只会把阈值丢给自己的 BLE 服务，
#   联想笔听不懂，所以得我们把等价的 ZUX 帧发过去。
SLIDE_BITS=$(( (GESTURE_SLIDE_UP >= 0 ? 4 : 0) + (GESTURE_SLIDE_DOWN >= 0 ? 8 : 0) ))
pen_mask=0
pen_lvl=3
last_mask=""
last_lvl=""

pen_sync_read() {
    local dbl pinch adj lvl
    dbl=$(settings get system stylus_double_click_status 2>/dev/null)
    pinch=$(settings get system stylus_pinch_status 2>/dev/null)
    adj=$(settings get system stylus_pinch_pressure_adjust 2>/dev/null)
    case "$dbl"   in ''|null|*[!0-9]*) dbl=1 ;; esac     # 缺省按 MIUI 默认：双击开
    case "$pinch" in ''|null|*[!0-9]*) pinch=5 ;; esac   # 0 = 轻捏关，其它 = 功能号（5=快捷环）
    case "$adj"   in ''|null|*[!0-9]*) adj=2 ;; esac

    pen_mask=$SLIDE_BITS
    [ "$GESTURE_TAIL" -ge 0 ] 2>/dev/null && pen_mask=$((pen_mask | 32))
    [ "$dbl" != "0" ]   && pen_mask=$((pen_mask | 1))
    [ "$pinch" != "0" ] && pen_mask=$((pen_mask | 16))

    lvl=$((adj + 1))
    [ "$lvl" -gt 5 ] && lvl=5
    [ "$lvl" -lt 1 ] && lvl=1
    pen_lvl=$lvl
}

# 设置变了就下发（1 秒最多查一次，由 monitor 的秒级分支调用）
sync_pen_settings() {
    case "$SETTINGS_SYNC" in 0|false|no|off) return 0 ;; esac
    [ -x "$PENRING_BIN" ] || return 0
    pen_sync_read
    if [ "$pen_mask" != "$last_mask" ] || [ "$pen_lvl" != "$last_lvl" ]; then
        log "settings->pen mask=$pen_mask squeeze=$pen_lvl (双击=$([ $((pen_mask & 1)) -ne 0 ] && echo on || echo off) 轻捏=$([ $((pen_mask & 16)) -ne 0 ] && echo on || echo off))"
        last_mask="$pen_mask"
        last_lvl="$pen_lvl"
        send_extra "$A_WAKE" "settings-sync" --ei wake 0 --ei touchfilm "$pen_mask" --ei squeeze "$pen_lvl"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------- ⑦ 笔刷触感
# 联想笔的 CON（连续振动）波形 id：
#   32 圆珠笔 / 33 铅笔 / 34 马克笔 / 35 橡皮 / 36 联想笔刷 / 37..41 同上的"无音效"版
#
# 事件来源全部是"内核级、毫秒级"的，不用轮询：
#   * 笔记/小米创作把当前工具写在 /data/data/<pkg>/shared_prefs/creation_shpref.xml
#     （current_brush / select_state_save / ai_type / current_ai_brush）→ inotify 盯目录
#   * 笔尾（橡皮端）进/出感应范围 → 直接读 /dev/input/event5 的 BTN_TOOL_RUBBER
#     （getevent 走管道会全缓冲，慢半拍，所以用 penring --watch 自己读）
# 波形基准（base）记在 brush.base：切笔刷时更新它；笔尾进范围发橡皮波形，
# 笔尾离开就恢复 base。
# 日志带毫秒（date +%s%3N 是可用的），方便量"谁慢"：inotify 收到的时间 vs prefs 的 mtime
brush_log() { echo "$(date '+%F %T.%3N' | cut -c1-23) $*" >> "$BRUSH_LOG"; }

# 当前前台包（本 ROM 打的是 topResumedActivity）
pen_fg() {
    dumpsys activity activities 2>/dev/null \
        | sed -n 's/.*[Rr]esumedActivity=ActivityRecord{[^}]* \([a-zA-Z0-9._]*\)\/.*/\1/p' \
        | head -1
}

brush_is_fg() {
    case " $BRUSH_APPS " in *" $1 "*) return 0 ;; esac
    return 1
}

brush_wave_of() {
    local v="$1" pair
    [ -n "$v" ] || return 0
    for pair in $(echo "$BRUSH_MAP" | tr ',' ' '); do
        case "$pair" in
            "$v":*) echo "${pair#*:}"; return 0 ;;
        esac
    done
    echo ""
}

# 读工具状态串：current_brush / select_state_save / ai_type / current_ai_brush
brush_tool_sig() {
    local f="$1"
    # 一次 grep 读完所有键（原来是每个键一个 sed，事件多的时候会排队）
    grep -oE 'name="(current_brush|select_state_save|ai_type|current_ai_brush)" value="[^"]*"' "$f" 2>/dev/null \
        | sed 's/name="//; s/" value="/=/; s/"$//' | tr '\n' ' '
}

brush_tool_val() {
    echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}

# 该发哪个波形：橡皮状态 > current_brush > select_state_save
brush_decide_wave() {
    local sig="$1" cur sel w
    cur=$(brush_tool_val "$sig" current_brush)
    sel=$(brush_tool_val "$sig" select_state_save)

    # 1) AI 笔：它不改 current_brush（实测 current_ai_brush=true 时 current_brush 还是上一支），
    #    所以必须最先判，否则会沿用上一支笔的波形
    if [ "$(brush_tool_val "$sig" current_ai_brush)" = "true" ]; then
        echo "$BRUSH_AI_WAVE"; return 0
    fi
    # 2) 橡皮（UI 里选橡皮时 current_brush 不变，只有 select_state_save 变）
    for w in $BRUSH_ERASER_STATES; do
        [ "$sel" = "$w" ] && { echo "$BRUSH_ERASER"; return 0; }
        [ "$cur" = "$w" ] && { echo "$BRUSH_ERASER"; return 0; }
    done
    # 3) 正常笔刷
    w=$(brush_wave_of "$cur")
    [ -n "$w" ] && { echo "$w"; return 0; }
    w=$(brush_wave_of "$sel")
    [ -n "$w" ] && { echo "$w"; return 0; }
    # 4) 框选笔（也是不改 current_brush 的一类；值看日志填）
    for w in $BRUSH_LASSO_STATES; do
        [ "$sel" = "$w" ] && { echo "$BRUSH_LASSO_WAVE"; return 0; }
    done
    w=$(brush_tool_val "$sig" ai_type)
    [ -n "$w" ] && [ "$w" != "0" ] && { echo "$BRUSH_AI_WAVE"; return 0; }
    # 5) 兜底：认不出的编号一律联想笔刷
    echo "$BRUSH_DEFAULT_WAVE"
}

brush_now()  { cat "$BRUSH_STATE" 2>/dev/null; }
brush_base() { cat "$BRUSH_BASE" 2>/dev/null; }
brush_tail_in() { [ "$(cat "$BRUSH_TAIL" 2>/dev/null)" = "1" ]; }

# 画布是否可写（hook 写的 penstate；文件不存在时按"可写"处理，保持旧行为）
brush_canvas() {
    local f v fg order
    fg=$(cat "$MODDIR/brush.fg" 2>/dev/null)
    # 优先读前台那个 App 的 penstate（两个 App 都会写，读错了会用到旧状态）
    order="$PENSTATE_LIST"
    case "$fg" in
        com.miui.notes)    order="/data/data/com.miui.notes/files/penstate $PENSTATE_LIST" ;;
        com.miui.creation) order="/data/data/com.miui.creation/files/penstate $PENSTATE_LIST" ;;
    esac
    for f in $order; do
        v=$(sed -n 's/^canvas=//p' "$f" 2>/dev/null | head -1)
        [ -n "$v" ] && { [ "$v" = "1" ]; return $?; }
    done
    return 0
}

# 把笔尾状态广播给 App 里的 hook（动态注册的接收器能收到隐式广播）
brush_tell_hooks() {
    am broadcast --user 0 -a dev.tb378fc.stylus.TAIL --ei down "$1" >/dev/null 2>&1 &
}

brush_send() {
    # $1 = 波形 id（0 = 停）；$2 = 原因；$3 = 非空表示"这是笔刷基准值"
    local wave="$1" why="$2" setbase="$3" now
    [ -n "$wave" ] || return 0
    now=$(brush_now)
    if [ "$wave" = "0" ]; then
        [ -z "$now" ] && return 0
        send_extra "$A_HAPTIC" "brush stop ($why)" --ei type 1 --ei wave 0 --ei level 0 \
            --ei friction "$BRUSH_FRICTION" --ei ms 80
        : > "$BRUSH_STATE"
        brush_log "stop ($why)"
        return 0
    fi
    [ -n "$setbase" ] && echo "$wave" > "$BRUSH_BASE"
    # 画布没聚焦（弹窗/面板打开、App 不在前台）就先不响，等 penstate 说 canvas=1 再放
    if [ -z "$setbase" ] && ! brush_canvas; then
        brush_log "skip wave=$wave ($why)：画布未聚焦"
        return 0
    fi
    [ "$wave" = "$now" ] && return 0
    send_extra "$A_HAPTIC" "brush wave=$wave ($why)" --ei type 1 --ei wave "$wave" \
        --ei level "$BRUSH_LEVEL" --ei friction "$BRUSH_FRICTION" --ei ms 80
    echo "$wave" > "$BRUSH_STATE"
    brush_log "wave=$wave ($why)"
}

# 应用里的工具换了：更新基准；不在橡皮态就立刻切过去
brush_on_tool_change() {
    local pkg="$1" sig="$2" wave
    echo "$pkg" > "$MODDIR/brush.fg"
    wave=$(brush_decide_wave "$sig")
    brush_log "$pkg 工具 [$sig] -> ${wave:-未映射}"
    [ -n "$wave" ] || return 0
    echo "$wave" > "$BRUSH_BASE"
    if brush_tail_in; then
        brush_log "（笔尾在感应范围内，先不切）"
    else
        brush_send "$wave" "$pkg 工具切换" base
    fi
}

# 应用退到后台/退出：停波形（只在有波形时查前台，避免白烧 dumpsys）
BRUSH_MISS=0
brush_exit_check() {
    local fg
    [ -n "$(brush_now)" ] || return 0
    case "$BRUSH_EXIT_CHECK" in 0|false|no|off) return 0 ;; esac
    fg=$(pen_fg)
    if brush_is_fg "$fg"; then
        BRUSH_MISS=0
        return 0
    fi
    BRUSH_MISS=$((BRUSH_MISS+1))
    if [ "$BRUSH_MISS" -ge 2 ]; then
        brush_send 0 "app left (${fg:-?})"
        BRUSH_MISS=0
        : > "$BRUSH_BASE"
    fi
}

# 只扫一个 App
brush_scan_one() {
    local pkg="$1" f sig lastf last
    f="/data/data/$pkg/shared_prefs/creation_shpref.xml"
    [ -r "$f" ] || return 0
    sig=$(brush_tool_sig "$f")
    lastf="$MODDIR/brush.last.$(echo "$pkg" | tr . _)"
    last=$(cat "$lastf" 2>/dev/null)
    [ "$sig" = "$last" ] && return 0
    echo "$sig" > "$lastf"
    brush_on_tool_change "$pkg" "$sig"
}

# 扫描一遍两个 App 的工具状态，变了就处理
brush_scan_apps() {
    local pkg f sig lastf last
    for pkg in $BRUSH_APPS; do
        f="/data/data/$pkg/shared_prefs/creation_shpref.xml"
        [ -r "$f" ] || continue
        sig=$(brush_tool_sig "$f")
        lastf="$MODDIR/brush.last.$(echo "$pkg" | tr . _)"
        last=$(cat "$lastf" 2>/dev/null)
        [ "$sig" = "$last" ] && continue
        echo "$sig" > "$lastf"
        brush_on_tool_change "$pkg" "$sig"
    done
}

brush_watch_loop() {
    local line pkg
    # 每轮先对齐一次现状（App 可能已经在前台且选好了笔刷）
    brush_scan_apps
    while [ ! -e "$DISABLE" ] && [ ! -e "$DISABLE_BRUSH" ]; do
        "$PENRING_BIN" --watch \
            --prefs /data/data/com.miui.notes/shared_prefs \
            --prefs /data/data/com.miui.creation/shared_prefs \
            --prefs /data/data/dev.tb378fc.stylus/files \
            --prefs /data/data/com.miui.notes/files \
            --prefs /data/data/com.miui.creation/files \
            --touch "$PEN_TOUCH_NODE" --log "$BRUSH_LOG" \
        | while :; do
            if IFS= read -r -t 2 line; then
                case "$line" in
                    FILE*)
                        # FILE <dir> <name>：只读事件所属的那个 App
                        set -- $line
                        case "$2" in
                            */com.miui.notes/*)    pkg=com.miui.notes ;;
                            */com.miui.creation/*) pkg=com.miui.creation ;;
                            *) pkg="" ;;
                        esac
                        [ -n "$pkg" ] && brush_scan_one "$pkg"
                        case "$line" in
                            *" penstate")
                                if brush_canvas; then
                                    brush_tell_hooks "$(brush_tail_in && echo 1 || echo 0)"
                                    # 每次进入画布都重扫一遍（不同笔记本可能记着不同笔刷），
                                    # 然后按当前笔刷下发波形
                                    brush_scan_apps
                                    [ -n "$(brush_base)" ] && brush_send "$(brush_base)" "canvas focused"
                                else
                                    brush_send 0 "canvas lost"
                                fi ;;
                        esac ;;
                    "TAIL down")
                        echo 1 > "$BRUSH_TAIL"
                        brush_tell_hooks 1
                        if [ -n "$(brush_base)" ]; then
                            brush_send "$BRUSH_ERASER" "tail(eraser) in range"
                        fi ;;
                    "TAIL up")
                        echo 0 > "$BRUSH_TAIL"
                        brush_tell_hooks 0
                        if [ -n "$(brush_base)" ]; then
                            brush_send "$(brush_base)" "tip back"
                        fi ;;
                esac
            else
                brush_exit_check
            fi
        done
        sleep 1
    done
}

penring_ensure() {
    gesture_enabled || return 0
    [ -x "$PENRING_BIN" ] || return 0
    penring_alive && return 0
    setsid "$PENRING_BIN" --moddir "$MODDIR" >>"$LOG.ring" 2>&1 </dev/null &
    sleep 1
    log "penring started pid=$(cat "$PENRING_PID" 2>/dev/null)"
}

capsule_direct() {
    case "$CAPSULE_DIRECT" in 0|false|no|off) return 1 ;; *) return 0 ;; esac
}

capsule_gatt() {
    case "$CAPSULE_GATT" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

capsule_fast() {
    case "$CAPSULE_FAST" in 0|false|no|off) return 1 ;; *) return 0 ;; esac
}

# 轮询间隔：把 POLL_MS 变成 sleep 的参数 + tick 折算（tick 仍按秒，供 REFRESH/日志轮转用）
case "$POLL_MS" in
    50)  SLEEP=0.05; PER_SEC=20 ;;
    100) SLEEP=0.1;  PER_SEC=10 ;;
    200) SLEEP=0.2;  PER_SEC=5 ;;
    250) SLEEP=0.25; PER_SEC=4 ;;
    500) SLEEP=0.5;  PER_SEC=2 ;;
    *)   SLEEP=1;    PER_SEC=1 ;;
esac

# 读一个 sysfs 整数，非法时回落到默认值
read_int() {
    local v
    v=$(cat "$1" 2>/dev/null)
    case "$v" in ''|*[!0-9-]*) echo "$2" ;; *) echo "$v" ;; esac
}

read_att() {
    local v=""
    # 用 shell 内建 read，不起 cat 进程 —— 200ms 轮一次也几乎不花钱
    # （注意别写成 `read ... || v=""`：sysfs 若没有结尾换行，read 会返回非零但值是有效的）
    read -r v < "$ATT" 2>/dev/null
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

# 带 extra 的广播（例如 --ei touchfilm 63）
send_extra() {
    local action="$1" what="$2" t0 t1; shift 2
    t0=$(date +%s%3N)
    if am broadcast --user 0 -n "$RCV" -a "$action" "$@" >/dev/null 2>&1; then
        t1=$(date +%s%3N)
        log "$what sent ($*) dispatch=$((t1-t0))ms"
    else
        log "ERROR $what failed ($*)"
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

# ⑤ 直发一条原生电量胶囊。
#
# 为什么要"先用缓存值弹"：笔放上去到线圈把 `attached` 置 1 要 **2 秒**（实测硬件握手），
# 而线圈报出新的 `level` 还要再等 1~2 秒 —— 傻等真值的话胶囊要 4 秒才出来。
# 所以边沿一到就用**上一次的 level** 先弹（线圈在取下时保留上一次的值），
# 1~2 秒后拿到新值再补一条刷新（同样是原生胶囊，会替换掉旧的）。
#
#   1. CAPSULE_DIRECT=1（默认）：守护**自己**发原生 STYLUS_STATE_SOC —— 少一跳（不起 App 进程）
#      否则只发 ATTACH 给 PenBridge，由 App 组装并弹
#   2. CAPSULE_GATT=1：再叫 PenBridge 用系统 API / GATT 读真值，与已显示的值不同才补一条校正
sensor_capsule() {
    local batt="$1" fb
    [ "$batt" -ge 1 ] && [ "$batt" -le 100 ] || return 1
    if capsule_direct; then
        if am broadcast --user 0 -a "$A_SOC" -n "$SOC_RCV" \
                --ei battery "$batt" --ei state 4 --ei connect 5 >/dev/null 2>&1; then
            shown="$batt"
            log "capsule sent battery=$batt (coil_chg=$(read_int "$WLS_CHG" -1))"
        else
            log "ERROR capsule send failed battery=$batt"
        fi
    fi
    # 交给 PenBridge：
    #   a) 直发成功 + 开了 GATT 校正 → battery=-1（"已弹过，别重复弹"）+ coil=已显示值
    #   b) 直发没成功（或 CAPSULE_DIRECT=0）→ battery=本值，让 App 立刻弹
    if capsule_gatt || [ "$shown" != "$batt" ]; then
        if [ "$shown" = "$batt" ]; then fb=-1; else fb="$batt"; fi
        if am broadcast --user 0 -n "$RCV" -a "$A_ATTACH" \
                --ei battery "$fb" --ei coil "$batt" --ei state 4 >/dev/null 2>&1; then
            log "attach forwarded (battery=$fb coil=$batt)"
        fi
    fi
    return 0
}

# 读线圈电量（内建 read，不起进程）；非 0..100 一律返回 -1
read_level() {
    local v=""
    read -r v < "$WLS_LEVEL" 2>/dev/null
    case "$v" in ''|*[!0-9]*) echo -1 ;; *) echo "$v" ;; esac
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

--brushsend)
    # 手动发一个波形：sh service.sh --brushsend 33   （33 = 铅笔，见 ZuxPen 波形表）
    brush_send "$2" "manual"
    exit 0
    ;;

--brushstop)
    brush_send 0 "manual"
    exit 0
    ;;

--brushwatch)
    echo $$ > "$MODDIR/brush.pid"
    # ⑦ 笔刷触感看护：两条子循环并跑
    #   A) 轮询笔记/小米创作的 creation_shpref.xml 里 current_brush（笔刷切换）
    #   B) 读笔触控节点，BTN_TOOL_RUBBER 按下=笔尾（橡皮端）靠近，抬起=回笔尖
    #   状态写在 $BRUSH_STATE："<波形id> <包名>"；退出应用后由 A 负责停波形。
    [ -e "$DISABLE_BRUSH" ] && exit 0
    case "$BRUSH" in 0|false|no|off) exit 0 ;; esac
    log "brushwatch up (apps=$BRUSH_APPS level=$BRUSH_LEVEL map=$BRUSH_MAP eraser=$BRUSH_ERASER)"
    : > "$BRUSH_STATE"
    : > "$BRUSH_BASE"

    brush_watch_loop
    exit 0
    ;;

--syncsettings)
    # ⑥ 手动跑一次"设置 → 笔"同步（排障用；monitor 每 2 秒自己也会跑）
    pen_sync_read
    last_mask=""; last_lvl=""
    if sync_pen_settings; then
        log "syncsettings: mask=$pen_mask squeeze=$pen_lvl sent"
    else
        log "syncsettings: mask=$pen_mask squeeze=$pen_lvl（未下发：可能 SETTINGS_SYNC=0 或 penring 不在）"
    fi
    exit 0
    ;;

--stoprompen)
    # ⑥ 移植 ROM 自带的笔桥（/system/etc/init/init.lwky.rc 里的 lwky_pen =
    #    /system/lwky/penbridge_hyperos）是"老一套"：它造的是 type-1（0x1915/0xEAEA）虚拟笔，
    #    并且在 boot_completed 时启动、按自己的映射往笔上灌 PAGEUP/PAGEDOWN(92/93)。
    #    在 HyperOS 上 type-1 永远进不了 MIUI 的触控膜分支（只认 type 8），而 92/93 又会被
    #    MiuiStylusShortcutManager 当成"截图键/速记键"乱触发 —— 和我们 penring 抢着注入。
    #    这里把它停掉（init 的 oneshot 服务，ctl.stop 之后不会自己回来；真回来就再停）。
    [ -e "$DISABLE_ROMPEN" ] && exit 0
    was=0
    while [ ! -e "$DISABLE_ROMPEN" ]; do
        if pidof penbridge_hyperos >/dev/null 2>&1; then
            setprop ctl.stop lwky_pen 2>/dev/null
            sleep 1
            pkill -x penbridge_hyperos 2>/dev/null
            sleep 1
            if pidof penbridge_hyperos >/dev/null 2>&1; then
                log "WARN ROM 笔桥 lwky_pen 停不掉（还在跑）"
            elif [ "$was" = 0 ]; then
                log "ROM 笔桥 lwky_pen 已停（老 type-1 桥不再注入 92/93）"
                was=1
            else
                log "ROM 笔桥 lwky_pen 又被拉起来了，已再停"
            fi
        fi
        sleep 30
    done
    exit 0
    ;;

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
    penring_ensure
    brushwatch_ensure
    while [ ! -e "$DISABLE" ]; do
        /system/bin/sh "$0" --monitor
        penring_ensure
        brushwatch_ensure
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
    last_lvl=$(read_level)
    last_good=-1
    [ "$last_lvl" -ge 1 ] && [ "$last_lvl" -le 100 ] && last_good=$last_lvl
    shown=""
    tick=0
    sub=0
    now_sec=0
    refresh_at=0
    refresh_deadline=0
    if capsule_enabled; then
        prepare_stylus_settings
        log "monitor start attached=$last_att level=$last_lvl refresh=${REFRESH}s capsule=on poll=${POLL_MS}ms direct=$CAPSULE_DIRECT gatt=$CAPSULE_GATT fast=$CAPSULE_FAST"
    else
        log "monitor start attached=$last_att level=$last_lvl refresh=${REFRESH}s capsule=off poll=${POLL_MS}ms"
    fi

    if [ "$last_att" = 0 ]; then
        # 开机时笔不在线圈上：唤醒它，并同步一次 {8,6,mask} 手势位（见 detach 处说明）
        pen_sync_read
        send_extra "$A_WAKE" "startup-wake" --ei touchfilm "$pen_mask" --ei squeeze "$pen_lvl"
    fi

    while [ ! -e "$DISABLE" ]; do
        sleep "$SLEEP"
        sub=$((sub+1))
        if [ $((sub % PER_SEC)) -eq 0 ]; then
            tick=$((tick+1))
            now_sec=$((now_sec+1))
            # ⑥ 每 2 秒看一次"设置→手写笔"有没有变（双击/轻捏开关、轻捏力度）
            if [ $((tick % 2)) -eq 0 ]; then sync_pen_settings || true; fi
        fi
        att=$(read_att "$last_att")
        lvl=$(read_level)
        if [ "$lvl" -ge 1 ] && [ "$lvl" -le 100 ]; then last_good=$lvl; fi

        # 取下：发唤醒 + 同步笔端手势位/力度，并把胶囊调度清掉。
        # **必须同时清空 shown** —— 否则下一次吸附时"新电量 == 上次显示过的值"（比如笔一直是 100%），
        # 刷新逻辑会以为"这条已经弹过了"而整次都不弹（实测：连吸 3 次只有第 1 次出胶囊）。
        if [ "$last_att" = 1 ] && [ "$att" = 0 ]; then
            # touchfilm=63(0x3F)：顺便把笔端触控膜功能位全开（双击/三击/上滑/下滑/捏合/笔尾）。
            # 笔重启或睡死会把这位清零 → 手势全部消失；联想原厂每次连接都重发，这里替他发。
            # 只要唤醒不改位就传 --ei touchfilm -1。
            pen_sync_read
            send_extra "$A_WAKE" "detach-wake" --ei touchfilm "$pen_mask" --ei squeeze "$pen_lvl"
            tick=0
            refresh_at=0
            refresh_deadline=0
            shown=""
        fi

        if capsule_enabled; then
            # 边沿 A：线圈刚启动（level 1..100 -> 0）—— 实测比 attached 早约 2 秒
            if [ "$last_att" = 0 ] && [ "$att" = 0 ] && [ "$last_lvl" -ge 1 ] && [ "$lvl" = 0 ] \
                    && [ "$refresh_deadline" = 0 ]; then
                log "coil-start edge (cached=$last_good)"
                if capsule_fast && [ "$last_good" -ge 1 ]; then
                    sensor_capsule "$last_good"      # 抢跑：先用上次的值弹一条
                fi
                refresh_at=$now_sec                  # 真值一到就补/刷新
                refresh_deadline=$((now_sec + 8))    # 最多等 8 秒
            fi
            # 边沿 B：attached 0 -> 1（硬件握手完成）
            if [ "$last_att" = 0 ] && [ "$att" = 1 ]; then
                if [ "$refresh_deadline" = 0 ]; then
                    if capsule_fast && [ "$last_good" -ge 1 ]; then
                        sensor_capsule "$last_good"
                    fi
                    refresh_at=$now_sec
                    refresh_deadline=$((now_sec + 8))
                fi
                tick=0
            fi
            # 等线圈报出本次真值：每轮（POLL_MS）重试，拿到就发；超时放弃
            if [ "$refresh_deadline" -gt 0 ] && [ "$att" = 1 ] && [ "$now_sec" -ge "$refresh_at" ]; then
                if [ "$lvl" -ge 1 ] && [ "$lvl" -le 100 ]; then
                    if [ "$lvl" != "$shown" ]; then
                        sensor_capsule "$lvl"
                    fi
                    refresh_at=0
                    refresh_deadline=0
                elif [ "$now_sec" -ge "$refresh_deadline" ]; then
                    log "capsule give up (level still '$lvl' after 8s)"
                    refresh_at=0
                    refresh_deadline=0
                fi
            fi
            # 笔取下来了就别再等
            if [ "$att" = 0 ] && [ "$refresh_deadline" -gt 0 ]; then
                refresh_at=0
                refresh_deadline=0
            fi
        fi

        if [ "$att" = 0 ] && [ "$REFRESH" -gt 0 ] && [ "$tick" -ge "$REFRESH" ]; then
            send "$A_WAKE" "refresh-wake"
            tick=0
        fi

        last_att=$att
        last_lvl=$lvl

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

    # ⑥ 把移植 ROM 自带的旧笔桥（lwky_pen / penbridge_hyperos）停掉，避免和 penring 抢注入
    if [ ! -e "$DISABLE_ROMPEN" ]; then
        setsid /system/bin/sh "$0" --stoprompen >/dev/null 2>&1 </dev/null &
    fi

    # setsid：KernelSU 通过 init 运行本脚本，普通的 "&" 子进程活不过脚本本身。
    PENWAKE_CHILD=1 setsid /system/bin/sh "$0" --supervise >/dev/null 2>&1 </dev/null &
    sleep 2
    log "setup done; supervisor pid=$(cat "$LOCK/pid" 2>/dev/null)"
    exit 0
    ;;
esac
