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
BRUSH_LOCK="$MODDIR/brush.lock"    # 单实例锁（mkdir 原子；防止多个 brushwatch 各跑一份老代码）
PENSTATE_LIST="/data/data/com.miui.creation/files/penstate /data/data/com.miui.notes/files/penstate /data/data/dev.tb378fc.stylus/files/penstate"
BRUSH_LOG="$MODDIR/brush.log"
PENRING_BIN="$MODDIR/bin/penring"
PENRING_PID="$MODDIR/penring.pid"
CFG="$MODDIR/config"
ATT=/sys/class/power_supply/wls_tx/attached
# ⑤ 胶囊：反向无线充电线圈看到的笔电量/充电状态（root 才读得到）
WLS_LEVEL=/sys/class/power_supply/wls_tx/level
WLS_CHG=/sys/class/power_supply/wls_tx/charge_state
# ⑨ 休眠档状态文件（brushwatch 是另一个进程，看不见 monitor 的变量，靠这个文件判断）
PEN_REST_FILE="$MODDIR/pen.rest"
PKG=dev.tb378fc.stylus
RCV="$PKG/.WakeReceiver"
APK="$MODDIR/bin/PenBridge.apk"
A_WAKE=dev.tb378fc.stylus.WAKE
A_HAPTIC=dev.tb378fc.stylus.HAPTIC
A_ATTACH=dev.tb378fc.stylus.ATTACH
# ⑤ 原生胶囊广播（发给 SecurityCoreAdd）
A_SOC=com.android.settings.stylus.STYLUS_STATE_SOC
# ⑨ 休眠档广播：告诉 App 断掉"留给下一条手势"的缓存 BLE 连接
A_REST=dev.tb378fc.stylus.REST
SOC_RCV=com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver

# ④：本机无 modem（ro.baseband=apq），这三个包是移植包原样带过来的死代码
TELEPHONY_PKGS="com.qti.phone com.qualcomm.qcrilmsgtunnel com.qualcomm.qti.telephonyservice"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 进程表匹配（排除自己）：$1 是 awk 正则。
# 为什么不用 pid 文件：看护是 setsid 出来的，supervisor 被重启/杀掉后它们变成孤儿继续活着，
# 此时 pid 文件已被覆盖/删除，只看 pid 文件会误判成"没有实例"→ 再拉一个 → 两个实例各发一份波形。
# 为什么不用逐个读 /proc/<pid>/cmdline：300+ 进程时每次调用要 600+ 次 fork，几秒一轮就把 pid 耗尽。
# 只认"shell 直接跑本脚本 --brushwatch"的进程：排除 timeout/setsid 这类包装进程
# （它们的 cmdline 里也含同样的字符串，曾因此把自己人误判成"已有实例"）
brushwatch_pids() {
    ps -A -o PID,ARGS 2>/dev/null | awk -v me="$$" -v pat="$MODDIR/service[.]sh --brushwatch" '
        NR>1 && $1+0 != me+0 && $2 ~ /(^|\/)(sh|mksh|bash)$/ && $0 ~ pat { print $1 }'
}

penring_pids() {
    ps -A -o PID,ARGS 2>/dev/null | awk -v me="$$" '
        NR>1 && $1+0 != me+0 && ($2 == "penring" || $2 ~ /\/penring$/) { print $1 }'
}

# penring --watch（笔刷看护的 inotify 子进程）
penring_watch_pids() {
    ps -A -o PID,ARGS 2>/dev/null | awk -v me="$$" '
        NR>1 && $1+0 != me+0 && $2 ~ /(^|\/)penring$/ && $0 ~ /--watch/ { print $1 }'
}

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
# 工具栏工具值（select_state_save）实测：8 AI 笔 / 6 框选笔 / 7 橡皮
BRUSH_AI_STATES="8"
BRUSH_AI_WAVE=36
# 框选笔：同样不改 current_brush，用 select_state_save 的值标识（看日志填，逗号分隔）
BRUSH_LASSO_STATES="6"
BRUSH_LASSO_WAVE=36
# 认不出的编号统一用这个波形
BRUSH_DEFAULT_WAVE=36
BRUSH_EXIT_CHECK=1                           # 退出应用后自动停波形
# ⑨ 休眠档：吸附在平板上且已充满 → 停掉一切对笔的主动动作（唤醒/胶囊/GATT 校正/波形），
#    并让 App 断掉缓存 BLE 连接，让笔真正睡下去；取下或电量掉到 REST_RESUME 以下立刻恢复。
PEN_REST=1
REST_FULL=99          # 线圈报的电量 ≥ 此值且吸附 → 进入休眠
REST_POLL=60          # 休眠期间线圈电量轮询间隔（秒）
REST_IDLE=20          # charge_state 由 1 变 0 后，持续这么多秒就认定"充完了"
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
    # 手势守护：/proc 扫描（pid 文件会被孤儿进程/pid 复用骗到）
    [ -n "$(penring_pids)" ]
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
sync_last_mask=""
sync_last_lvl=""

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
    # 休眠档：笔在平板上待机，别发任何东西去吵它。这里**故意不记账** —— 恢复后下一次
    # 调用会看到"和上次不一致"从而补发一次真值。
    pen_rest_on && return 1
    # 注意：状态变量必须独立命名。曾经这里用 last_mask/last_lvl，而 monitor 主循环里
    # last_lvl 是"无线线圈电量"（0..100）→ pen_lvl(1..5) 与它永远不相等 → 每 3 秒重发一次
    # 唤醒广播（实测 1100+ 次），既费电又和胶囊/看护抢 BLE。
    if [ "$pen_mask" != "$sync_last_mask" ] || [ "$pen_lvl" != "$sync_last_lvl" ]; then
        log "settings->pen mask=$pen_mask squeeze=$pen_lvl (双击=$([ $((pen_mask & 1)) -ne 0 ] && echo on || echo off) 轻捏=$([ $((pen_mask & 16)) -ne 0 ] && echo on || echo off))"
        sync_last_mask="$pen_mask"
        sync_last_lvl="$pen_lvl"
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

    # select_state_save 是"工具栏当前工具"，**优先** —— 选 AI 笔/框选笔/橡皮时
    # current_brush 还停在上一支真笔刷上（实测：AI 时 current_brush=4 但 select=8），
    # 先查 current_brush 就会一直沿用上一支的手感。
    # 实测值：8 AI 笔 / 6 框选笔 / 7 橡皮（普通笔刷时它等于 current_brush，不冲突）
    # 三个特殊工具先按 select_state_save 精确匹配（用户实测值，优先级最高：
    # current_ai_brush 是残留标记，选橡皮时它可能还是 true，不能让它抢答）
    for w in $BRUSH_ERASER_STATES; do
        [ "$sel" = "$w" ] && { echo "$BRUSH_ERASER"; return 0; }
    done
    for w in $BRUSH_AI_STATES; do
        [ "$sel" = "$w" ] && { echo "$BRUSH_AI_WAVE"; return 0; }
    done
    for w in $BRUSH_LASSO_STATES; do
        [ "$sel" = "$w" ] && { echo "$BRUSH_LASSO_WAVE"; return 0; }
    done
    for w in $BRUSH_ERASER_STATES; do
        [ "$cur" = "$w" ] && { echo "$BRUSH_ERASER"; return 0; }
    done
    if [ "$(brush_tool_val "$sig" current_ai_brush)" = "true" ]; then
        echo "$BRUSH_AI_WAVE"; return 0
    fi

    # 普通笔刷：查表（select_state_save 与 current_brush 一致，用哪个都行）
    w=$(brush_wave_of "$cur")
    [ -n "$w" ] && { echo "$w"; return 0; }
    w=$(brush_wave_of "$sel")
    [ -n "$w" ] && { echo "$w"; return 0; }
    w=$(brush_tool_val "$sig" ai_type)
    [ -n "$w" ] && [ "$w" != "0" ] && { echo "$BRUSH_AI_WAVE"; return 0; }
    # 认不出的编号：联想笔刷
    echo "$BRUSH_DEFAULT_WAVE"
}

# 应用里的工具换了：更新基准；不在橡皮态就立刻切过去
brush_now()   { cat "$BRUSH_STATE" 2>/dev/null; }
brush_base()  { cat "$BRUSH_BASE" 2>/dev/null; }
brush_tail_in() { [ "$(cat "$BRUSH_TAIL" 2>/dev/null)" = "1" ]; }

# 画布是否可写（hook 写的 penstate；优先读"前台那个 App"的文件，避免读到另一边的旧状态）
brush_canvas() {
    local f v fg order
    fg=$(cat "$MODDIR/brush.fg" 2>/dev/null)
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
brush_tell_hooks() { am broadcast --user 0 -a dev.tb378fc.stylus.TAIL --ei down "$1" >/dev/null 2>&1 & }

# $1 波形（0 = 停）；$2 原因；$3 非空表示"这是当前笔刷的基准波形"
brush_send() {
    local wave="$1" why="$2" setbase="$3" now tailin
    [ -n "$wave" ] || return 0
    # 休眠档：笔在平板上，别发波形（wave=0 的停止帧仍允许，用来清掉可能 latch 住的波形）
    if [ "$wave" != "0" ] && pen_rest_on; then
        brush_log "skip wave=$wave ($why)：休眠档（吸附已充满）"
        return 0
    fi
    now=$(brush_now)
    tailin=$(cat "$BRUSH_TAIL" 2>/dev/null)
    brush_log "send? wave=$wave now=${now:-空} base=$([ -n "$setbase" ] && echo yes || echo no) tail=${tailin:-0} why=$why"

    if [ "$wave" = "0" ]; then
        # 停止帧无条件发：本地记录可能是空的（守护重启过），但笔里可能还 latch 着波形
        send_extra "$A_HAPTIC" "brush stop ($why)" --ei type 1 --ei wave 0 --ei level 0 \
            --ei friction "$BRUSH_FRICTION" --ei ms 80
        : > "$BRUSH_STATE"
        brush_log "stop ($why)"
        return 0
    fi

    [ -n "$setbase" ] && echo "$wave" > "$BRUSH_BASE"
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
    # hook 说画布还在（canvas=1）就别停 —— 这条比 dumpsys 可靠
    if brush_canvas; then BRUSH_MISS=0; return 0; fi
    fg=$(pen_fg)
    # dumpsys 偶尔拿不到前台包（空串），这种情况不计入"离开"，否则会误杀波形
    [ -n "$fg" ] || return 0
    if brush_is_fg "$fg"; then
        BRUSH_MISS=0
        return 0
    fi
    BRUSH_MISS=$((BRUSH_MISS+1))
    if [ "$BRUSH_MISS" -ge 3 ]; then
        brush_send 0 "app left ($fg)"
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
    local line pkg miss=0
    # 每轮先对齐一次现状（App 可能已经在前台且选好了笔刷）
    brush_scan_apps
    while [ ! -e "$DISABLE" ] && [ ! -e "$DISABLE_BRUSH" ]; do
        # 2>/dev/null：penring 的 logf_ 已经自己写 --log 指定的文件，而 stderr 也会被本进程
        # （其 stderr 已经指向同一个 brush.log）接住 → 不屏蔽的话每条日志都出现两遍。
        "$PENRING_BIN" --watch 2>/dev/null \
            --prefs /data/data/com.miui.notes/shared_prefs \
            --prefs /data/data/com.miui.creation/shared_prefs \
            --prefs /data/data/dev.tb378fc.stylus/files \
            --prefs /data/data/com.miui.notes/files \
            --prefs /data/data/com.miui.creation/files \
            --touch "$PEN_TOUCH_NODE" --log "$BRUSH_LOG" \
        | while :; do
            if IFS= read -r -t 2 line; then
                miss=0
                case "$line" in
                    FILE*)
                        # FILE <dir> <name>：只读事件所属的那个 App
                        set -- $line
                        case "$2" in
                            */com.miui.notes/*)    pkg=com.miui.notes ;;
                            */com.miui.creation/*) pkg=com.miui.creation ;;
                            *) pkg="" ;;
                        esac
                        fg=$(pen_fg)
                        [ -n "$fg" ] && echo "$fg" > "$MODDIR/brush.fg"
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
                # read 超时或管道断了。若 penring --watch 已经没了，必须立刻跳出内层让外层重建：
                # 否则 read 会立刻返回失败 → 空转，而且每轮都跑 brush_exit_check（里面有 dumpsys）
                # → 几秒内几千次 fork（实测把 pid 都耗到绕回）。
                # 每 3 次超时才做一次进程表扫描（守卫本身也要花 fork，别每 2 秒都扫）
                miss=$((miss+1))
                if [ $((miss % 3)) -eq 0 ] && [ -z "$(penring_watch_pids)" ]; then
                    brush_log "watch: penring --watch 已退出，重建看护"
                    break
                fi
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

# 单实例判定：直接扫 /proc（pid 文件在孤儿进程场景下不可靠，见 pids_of 注释）
brushwatch_alive() { [ -n "$(brushwatch_pids)" ]; }

brushwatch_ensure() {
    [ -e "$DISABLE" ] && return 0
    [ -e "$DISABLE_BRUSH" ] && return 0
    case "$BRUSH" in 0|false|no|off) return 0 ;; esac
    # 等 CE 存储解锁挂载：开机早期 /data/data/<pkg> 还不存在，此时起的看护挂不上 inotify，
    # 进程活着却收不到任何事件（"mon 没活"的真身之一）。penring 现在会自己补挂，
    # 但这里也等一等，省掉一轮无效工作 + 日志噪声。
    _ce_ok=0
    for _p in $BRUSH_APPS; do [ -d "/data/data/$_p" ] && _ce_ok=1; done
    [ "$_ce_ok" = 1 ] || return 0
    brushwatch_alive && return 0
    # 陈旧锁（上次会话留下的 brush.lock/brush.pid）由 --brushwatch 自己清理
    setsid /system/bin/sh "$0" --brushwatch >>"$BRUSH_LOG" 2>&1 </dev/null &
    sleep 1
    log "brushwatch started pid=$(cat "$MODDIR/brush.pid" 2>/dev/null)"
}

# ⑨ 休眠档：pen_rest_on 读状态文件（任何进程都能问"现在是不是休眠档"）
pen_rest_on()      { [ "$(cat "$PEN_REST_FILE" 2>/dev/null)" = "1" ]; }
pen_rest_mark()    { echo "$1" > "$PEN_REST_FILE" 2>/dev/null; }
pen_rest_enabled() {
    [ -e "$MODDIR/disable-rest" ] && return 1
    case "$PEN_REST" in 0|false|no|off) return 1 ;; *) return 0 ;; esac
}
# 休眠档开着时不允许别的动作误判：显式提供"现在该不该静默"
pen_quiet() { pen_rest_enabled && pen_rest_on; }

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
    # 休眠档：直发（本地广播，不碰笔）已经弹过了，就别再让 App 去连笔读电量（那会把笔吵醒）
    if pen_rest_on; then
        log "capsule: 休眠档跳过 GATT 校正 battery=$batt"
        return 0
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
    # 单实例：已有活着的实例就直接退出（否则会有多个实例各发一份波形、还各按自己那份代码判定）
    # 原子抢锁：mkdir 成功者才是实例。
    # 不能用"先扫描全表、发现有别人就退出"——两个并发的 ensure（supervisor 和 monitor 都会拉）
    # 会互相谦让，结果两个都退出，看护静默消失（实测：mon 一直不启动的真身）。
    tries=0
    while :; do
        if mkdir "$BRUSH_LOCK" 2>/dev/null; then break; fi
        other=$(brushwatch_pids | tr '\n' ' ')
        tries=$((tries+1))
        if [ -n "$other" ]; then
            log "brushwatch already running pid=$other, exit"
            exit 0
        fi
        if [ "$tries" -ge 5 ]; then
            log "brushwatch lock busy but no live instance (stale?), give up"
            exit 0
        fi
        rm -rf "$BRUSH_LOCK"          # 陈旧锁（持有者已死）：清掉重抢
        sleep 0.3
    done
    trap 'rmdir "$BRUSH_LOCK" 2>/dev/null; rm -f "$MODDIR/brush.pid"' EXIT INT TERM
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
    # 启动先清一次：上一轮守护可能被重启过，笔里还挂着 CON 波形
    brush_send 0 "watch start"

    brush_watch_loop
    rmdir "$BRUSH_LOCK" 2>/dev/null
    exit 0
    ;;

--rest)
    # 手工强制休眠档（排障/测试用）：sh service.sh --rest 1 | --rest 0
    case "$2" in 1|on) pen_rest_mark 1 ;; *) pen_rest_mark 0 ;; esac
    send_extra "$A_REST" "rest $2" --ei on "$([ "$2" = 1 ] && echo 1 || echo 0)"
    log "rest 手工置为 $(cat "$PEN_REST_FILE" 2>/dev/null)"
    exit 0
    ;;

--restcheck)
    # 用给定的 att/lvl 走一遍休眠判定（不改状态）：sh service.sh --restcheck 1 100
    # 用法：--restcheck <att> <lvl> [chg] [距上次 chg=1 的秒数]
    pen_rest_enabled || { echo "PEN_REST=0：休眠档关闭"; exit 0; }
    _att="$2"; _lvl="$3"; _chg="${4:-0}"; _idle="${5:-0}"
    if [ "$_att" = 0 ]; then
        echo "→ 不休眠（已取下）"
    elif [ "$_lvl" -ge "$REST_FULL" ]; then
        echo "→ 进入休眠（兜底判据：电量 $_lvl ≥ $REST_FULL）"
    elif [ "$_chg" = 1 ]; then
        echo "→ 不休眠（正在充电 chg=1，电量 $_lvl）"
    elif [ "$_idle" -ge "$REST_IDLE" ]; then
        echo "→ 进入休眠（主判据：充电已停 ${_idle}s ≥ $REST_IDLE，电量 $_lvl）"
    elif [ "$_att" = 0 ]; then
        echo "→ 不休眠（已取下）"
    else
        echo "→ 保持现状（吸附，chg=0 但只停了 ${_idle}s < $REST_IDLE，电量 $_lvl）"
    fi
    exit 0
    ;;

--syncsettings)
    # ⑥ 手动跑一次"设置 → 笔"同步（排障用；monitor 每 2 秒自己也会跑）
    pen_sync_read
    sync_last_mask=""; sync_last_lvl=""
    if sync_pen_settings; then
        log "syncsettings: mask=$pen_mask squeeze=$pen_lvl sent"
    else
        log "syncsettings: mask=$pen_mask squeeze=$pen_lvl（未下发：SETTINGS_SYNC=0 / penring 不在 / 正处于⑨休眠档）"
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
    lvl_win=0          # "全速读线圈电量"的剩余秒数（吸附边沿后开窗）
    pen_rest=0         # ⑨ 休眠档当前状态（文件里也写一份，给别的进程看）
    chg_seen=0         # ⑨ 本次吸附期间有没有见过 chg=1（见过才算"充过电"）
    chg_last=0         # ⑨ 最后一次见到 chg=1 的时刻（now_sec）
    pen_rest_enabled && [ "$REST_POLL" -ge 5 ] 2>/dev/null || REST_POLL=5
    [ "$REST_IDLE" -ge 5 ] 2>/dev/null || REST_IDLE=5
    pen_rest_mark 0
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
            # 看护自愈：monitor 是唯一常驻不退出的循环，penring / brushwatch 若被杀掉/崩溃
            # （历史事故：函数整段丢失导致开机后静默不启动）在这里两秒内重生一次。
            if [ $((tick % 2)) -eq 1 ]; then penring_ensure; brushwatch_ensure; fi
            [ "$lvl_win" -gt 0 ] && lvl_win=$((lvl_win-1))
        fi
        # attached 每轮都读（边沿检测靠它）。用内建 read 直接写变量：原来写成 $(read_att) 会让
        # 每轮 fork 一个子 shell，而"读一次 wls_tx 属性"本身就会让内核 Qi 驱动重发属性。
        att=""
        read -r att < "$ATT" 2>/dev/null
        case "$att" in 0|1) ;; *) att=$last_att ;; esac

        # 线圈电量按需读：每次读 wls_tx/level 都会触发内核 Qi 属性重发 →
        # MiuiChargeManager 再 notify 一次电池状态 → 电池图标闪（实测每 200ms 一读时每秒十几次）。
        #   lvl_win>0（刚吸附/线圈启动后 8 秒）：每 ~1 秒一次，尽快拿到真值弹胶囊
        #   吸附稳定：每 ~2 秒一次
        #   未吸附：每 ~10 秒兜底一次（认线圈启动边沿）
        lvl_read=0; chg=0
        if [ "$pen_rest" = 1 ]; then
            # 休眠档：降到 REST_POLL 秒一次（只是用来发现"该醒了"）
            [ $((sub % $((REST_POLL * 5)))) -eq 0 ] && lvl_read=1
        elif [ "$lvl_win" -gt 0 ]; then
            [ $((sub % 5)) -eq 0 ] && lvl_read=1
        elif [ "$att" = 1 ]; then
            [ $((sub % 10)) -eq 0 ] && lvl_read=1
        else
            [ $((sub % 50)) -eq 0 ] && lvl_read=1
        fi
        if [ "$lvl_read" = 1 ]; then
            lvl=$(read_level)
            chg=$(read_int "$WLS_CHG" 0)     # 0/1：线圈报的"是否正在给笔充电"
        else
            lvl=$last_lvl
        fi
        if [ "$lvl_read" = 1 ] && [ "$lvl" -ge 1 ] && [ "$lvl" -le 100 ]; then last_good=$lvl; fi

        # ⑨ 休眠档状态机：吸附且"充完了" → 让笔休眠；取下、或线圈重新开始充电 → 恢复
        #
        # 判据用 **charge_state**（线圈驱动报的"是否正在给笔充电"）而不是拍一个电量阈值：
        #   1) 本轮读到 chg=1 → 说明确实在充，记下时间（刚吸上那几秒 chg 也是 0 —— 握手还没起来，
        #      所以不能只看 chg=0，否则一吸上就误判成"充满"）；
        #   2) 之后读到 chg=0 且距上次 chg=1 已 ≥ REST_IDLE 秒 → 充完了（笔端 Qi 接收芯片终止取电
        #      就是这么体现的），进休眠档；
        #   3) 兜底：电量 ≥ REST_FULL（有的笔端在 100% 之前就停充、或 chg 读不到时用）。
        if pen_rest_enabled; then
            if [ "$att" = 0 ]; then
                chg_seen=0; chg_last=0
            elif [ "$lvl_read" = 1 ] && [ "$chg" = 1 ]; then
                chg_seen=1; chg_last=$now_sec
            fi
            if [ "$pen_rest" != 1 ]; then
                rested=0
                if [ "$lvl_read" = 1 ] && [ "$att" = 1 ] && [ "$lvl" -ge "$REST_FULL" ]; then
                    rested=1; rest_why="电量=$lvl ≥ $REST_FULL"
                elif [ "$att" = 1 ] && [ "$chg_seen" = 1 ] && [ "$lvl_read" = 1 ] && [ "$chg" = 0 ] \
                        && [ $((now_sec - chg_last)) -ge "$REST_IDLE" ]; then
                    rested=1; rest_why="充完静默 $((now_sec - chg_last))s（chg 1→0，电量=$lvl）"
                fi
                if [ "$rested" = 1 ]; then
                    pen_rest=1; pen_rest_mark 1; lvl_win=0
                    log "pen rest ON: 吸附且 $rest_why → 停唤醒/停胶囊/断 BLE"
                    /system/bin/sh "$0" --brushstop >/dev/null 2>&1   # 清掉可能 latch 住的 CON 波形
                    send_extra "$A_REST" "rest-on" --ei on 1
                fi
            else
                # 出档：取下，或线圈**重新开始充电**（说明笔又要用电了 → 恢复唤醒/胶囊）。
                # 这里不能用"电量低于某个阈值"来出档：进档主判据是"停充"，两者会来回打架
                # （90% 停充 → 进档 → 立刻因 <95 出档 → 再进档，实测会 20 秒一跳）。
                if [ "$att" = 0 ]; then
                    pen_rest=0; pen_rest_mark 0
                    log "pen rest OFF: 已取下 → 恢复唤醒/胶囊"
                    send_extra "$A_REST" "rest-off" --ei on 0
                elif [ "$lvl_read" = 1 ] && [ "$chg" = 1 ] && [ "$lvl" -lt "$REST_FULL" ]; then
                    # 注意要带 lvl < REST_FULL：本机实测**笔满 100% 时 chg 仍然是 1**
                    # （线圈持续 ~300mA 送电），只按 chg=1 出档会和"电量兜底进档"60 秒一跳。
                    pen_rest=0; pen_rest_mark 0
                    log "pen rest OFF: 线圈重新给笔补电 (电量=$lvl < $REST_FULL) → 恢复唤醒/胶囊"
                    send_extra "$A_REST" "rest-off" --ei on 0
                fi
            fi
        fi

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
            if [ "$last_att" = 0 ] && [ "$att" = 0 ] && [ "$lvl_read" = 1 ] \
                    && [ "$last_lvl" -ge 1 ] && [ "$lvl" = 0 ] \
                    && [ "$refresh_deadline" = 0 ]; then
                log "coil-start edge (cached=$last_good)"
                lvl_win=8                            # 线圈刚启动 → 开窗全速读电量
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
                    lvl_win=8                        # 吸附成功 → 开窗全速读电量
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

    # 接管：上一轮会话（或旧版本模块）用 setsid 拉起的看护不会被 init 收走，
    # supervisor 死后它们还活着 —— 必须清掉，否则新旧两份同时往笔里写波形。
    for p in $(brushwatch_pids) $(penring_pids); do
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$BRUSH_LOCK" 2>/dev/null
    rm -f "$MODDIR/brush.pid" "$PENRING_PID" 2>/dev/null

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
