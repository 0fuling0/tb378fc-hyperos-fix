#!/system/bin/sh
# 管理器「执行」按钮：状态面板。
# 这里只做**只读**的状态汇报 —— 开关本身在 config（WebUI 里改），不在这里改。
MODDIR=${0%/*}
CFG="$MODDIR/config"
ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
echo "TB378FC HyperOS 修复 ${ver:-v?}"
echo ' '

# ---- 小工具 ----
# cv KEY DEFAULT：读 config 里的一个键，没写就用默认值
cv() {
    _v=$(sed -n "s/^$1=//p" "$CFG" 2>/dev/null | head -1 | tr -d '\r')
    [ -n "$_v" ] || _v="$2"
    echo "$_v"
}
# 开/关（config 语义：1/true/yes/on = 开）
sw() {
    case "$(cv "$1" "$2")" in 1|true|yes|on) echo '开' ;; *) echo '关' ;; esac
}
# 某个 disable-* 标记文件在不在
mk() { [ -e "$MODDIR/$1" ] && echo '1' || echo '0'; }
# 有效开关 = config 开 且 没有标记（标记强制关）
eff() {
    [ "$(mk "$2")" = 1 ] && { echo '关(标记)'; return; }
    sw "$1" "$3"
}

# ---- APK 状态 ----
if [ -n "$(pm path dev.tb378fc.fix 2>/dev/null)" ]; then apk=已安装; else apk=未安装; fi
need=0
for k in PEN_WAKE CAPSULE BRUSH AON PEN_REST SETTINGS_SYNC SCREEN_CMD; do
    case "$(cv "$k" 0)" in 1|true|yes|on) need=1 ;; esac
done
[ "$need" = 1 ] && needtxt=是 || needtxt=否
echo "App / APK    : $apk   (需要=$needtxt)"
echo "               「需要 App」那一组里任意一项开着就会自动装；全关会自动卸"
echo ' '

# ---- 一、系统修复 ----
# ④ 只统计**本机真实存在**的包。实测 HyperOS 3 的 TB378FC 上这三个包一个都没有，
# 此时 ④ 的目标（无空转 persistent 进程）天然达成，若照旧显示「0/3 个包已停用」
# 会读成"修复失败"。所以分两种写法：包不在就明说不需要处理。
_tele_re='package:(com\.qti\.phone|com\.qualcomm\.qcrilmsgtunnel|com\.qualcomm\.qti\.telephonyservice)'
tele_all=$(pm list packages    2>/dev/null | grep -cxE "$_tele_re")
tele_off=$(pm list packages -d 2>/dev/null | grep -cxE "$_tele_re")
if [ "$tele_all" -eq 0 ]; then
    tele_txt='本机不存在这三个包（无需处理）'
else
    tele_txt="$tele_off/$tele_all 个包已停用"
fi
echo "一、系统修复（不需要 App）"
echo "  ② PowerKeeper : $(eff FIX_POWERKEEPER disable-powerkeeper 1)   已挂载 $(mount 2>/dev/null | grep -c 'PowerKeeper/PowerKeeper.apk') 处，进程 $(pidof com.miui.powerkeeper || echo '未运行')"
echo "  ③ BPF 监视器  : $(eff FIX_BPFMON disable-bpfmon 1)   $(pidof hyper_bpfloader >/dev/null 2>&1 && echo 'hyper_bpfloader 仍在运行(异常)' || echo 'hyper_bpfloader 未运行')"
echo "  ④ 死电话栈    : $(eff FIX_TELEPHONY disable-telephony 1)   $tele_txt$(pidof com.qti.phone >/dev/null 2>&1 && echo "，残留空转进程 $(pidof com.qti.phone)" || echo '，无残留进程')"
# ⑭ 开发者选项：判据是"开机以来有没有 logpersistd 相关的 AVC 拒绝"（0 = 正常）
#    有拒绝说明规则没生效，跑 `sh service.sh --sepolicy` 即可免重启救回来。
n_lp=$(dmesg 2>/dev/null | grep -c 'logpersistd_logging_prop')
n_ap=$(grep -c '⑭ sepolicy apply rc=0' "$MODDIR/wake.log" 2>/dev/null)
[ -n "$n_ap" ] || n_ap=0
echo "  ⑭ 开发者选项  : 始终启用（崩溃修复）   $([ "$n_lp" = 0 ] && echo '正常' || echo "异常，$n_lp 条 logpersistd 拒绝")，开机以来 sepolicy apply 成功 $n_ap 次"
echo ' '

# ---- 二、手写笔连接 ----
echo "二、手写笔连接（需要 App）"
echo "  ① 唤醒      : $(eff PEN_WAKE disable 0)"
echo "     磁吸状态  : $(cat /sys/class/power_supply/wls_tx/attached 2>/dev/null)  (1=吸附 0=取下)"
echo "     线圈电量  : $(cat /sys/class/power_supply/wls_tx/level 2>/dev/null)  charge_state=$(cat /sys/class/power_supply/wls_tx/charge_state 2>/dev/null)"
echo "  ⑤ 电量胶囊  : $(eff CAPSULE disable-capsule 0)   (引导标记 stylus_first_connect=$(settings get secure stylus_first_connect 2>/dev/null))"
echo "  ⑨ 休眠档    : $(eff PEN_REST disable-rest 0)   当前 $([ "$(cat "$MODDIR/pen.rest" 2>/dev/null)" = 1 ] && echo '已进档' || echo '未进档')"
echo "  ⑬ 屏幕指令  : $(eff SCREEN_CMD disable-screen 0)"
echo ' '

# ---- 三、手势与书写 ----
echo "三、手势与书写"
ge=$(eff GESTURE disable-gesture 1)
gp=$(cat "$MODDIR/penring.pid" 2>/dev/null)
echo "  ⑥ 手势桥    : $ge   penring $(kill -0 "$gp" 2>/dev/null && echo "运行中 pid=$gp" || echo '未运行')"
echo "     虚拟笔    : $(grep -c 'Xiaomi Pen' /proc/bus/input/devices 2>/dev/null) 个 (0x0022/0x5081, type 8)"
echo "     ROM 笔桥  : $(pidof penbridge_hyperos >/dev/null 2>&1 && echo 'lwky_pen 仍在运行' || echo 'lwky_pen 已停')"
bp=$(cat "$MODDIR/brush.pid" 2>/dev/null)
echo "  ⑦ 笔刷触感  : $(eff BRUSH disable-brush 0)   brushwatch $(kill -0 "$bp" 2>/dev/null && echo "运行中 pid=$bp" || echo '未运行')"
echo "  ⑫ 设置→笔   : $(sw SETTINGS_SYNC 0)"
echo ' '

# ---- 四、注视感知 ----
echo "四、注视感知（需要 App + LSPosed）"
aon=$(eff AON disable-aon 0)
echo "  ⑧ AON       : $aon"
if [ "$aon" = 开 ]; then
    echo "     服务      : $(service check attention 2>/dev/null | tr -d '\r' | head -1)"
    echo "     mifaced   : $(pidof mifaced >/dev/null 2>&1 && echo '运行中' || echo '未运行')   aon app $(pidof com.xiaomi.aon >/dev/null 2>&1 && echo '运行中' || echo '未运行')"
fi
echo ' '

# ---- 标记文件 ----
marks=""
for m in disable disable-powerkeeper disable-bpfmon disable-telephony disable-capsule \
         disable-gesture disable-brush disable-aon disable-aonlib disable-rest \
         disable-screen disable-rompen; do
    [ -e "$MODDIR/$m" ] && marks="$marks$m "
done
echo "标记文件: $([ -n "$marks" ] && echo "${marks% }（这些功能被强制关）" || echo '无')"
echo ' '
echo '最近日志:'
tail -n 14 "$MODDIR/wake.log" 2>/dev/null
