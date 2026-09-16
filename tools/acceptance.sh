#!/system/bin/sh
# TB378FC HyperOS 修复 Lite —— 设备端验收脚本
#
# 在**设备上**跑（不是在 PC 上），逐项断言四个修复的最终状态，并把结论汇总成
# 「全部通过 / 有 N 项失败」。任何一项不通过都会明确说清是哪一项、期望什么。
#
# 用法（PC 上）：
#     adb push tools/acceptance.sh /data/local/tmp/
#     adb shell su -c 'sh /data/local/tmp/acceptance.sh'
#
# 设计上刻意做了两件事，都是踩过坑之后加的：
#
#   1. ② 的判据是 **powerkeeper 自己的 mount namespace** 里有没有那条挂载
#      （/proc/<pid>/mountinfo），不是 /proc/mounts。KernelSU 会把模块挂载从 App
#      进程里卸掉，只看 init 视角会得出"已生效"的错误结论。
#
#   2. 崩溃断言只统计「模块修好之后」的窗口。开机早期 powerkeeper 必然要崩几次
#      （boot_completed 之前的挂载对 App 不可见），那是已知且无害的，
#      所以这里先清 logcat、杀掉进程让 AMS 重启，再看这段干净窗口。

MODDIR=${MODDIR:-/data/adb/modules/tb378fc_hyperos_fix_lite}
PK=com.miui.powerkeeper
PKAPK=/system_ext/app/PowerKeeper/PowerKeeper.apk
LOG="$MODDIR/lite.log"
WANT=279592be00a95a6ee9d6b46effda35c93b4553263fa4f307966e9cb53343a8fc

FAIL=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -d "$MODDIR" ]; then echo "找不到模块目录 $MODDIR"; exit 2; fi

echo "=========== ② PowerKeeper 补丁 ==========="
h=$(sha256sum "$PKAPK" 2>/dev/null | cut -d' ' -f1)
[ "$h" = "$WANT" ] && ok "init 视角读到补丁版" || bad "init 视角不是补丁版 ($h)"

P=$(pidof $PK 2>/dev/null | awk '{print $1}')
if [ -n "$P" ]; then
  ok "powerkeeper 存活 pid=$P uid=$(grep -m1 '^Uid:' /proc/$P/status 2>/dev/null | awk '{print $2}')"
  ph=$(nsenter -t "$P" -m -- sha256sum "$PKAPK" 2>/dev/null | cut -d' ' -f1)
  [ "$ph" = "$WANT" ] && ok "它自己的 namespace 读到补丁版" || bad "它看到的是 $ph"
  grep -q " /system_ext/app/PowerKeeper " "/proc/$P/mountinfo" 2>/dev/null \
    && ok "它的 mountinfo 里有 PowerKeeper 挂载" || bad "它的 mountinfo 里没有挂载"
else
  bad "powerkeeper 没在跑"
fi
echo "  pm path: $(pm path $PK 2>&1)"

echo ""
echo "  --- 稳定性：清日志 → 杀掉 → 让 AMS 自动重启 → 观察 ---"
logcat -b all -c 2>/dev/null
P0=$(pidof $PK 2>/dev/null | awk '{print $1}')
[ -n "$P0" ] && kill -9 $P0 2>/dev/null
sleep 12
P2=$(pidof $PK 2>/dev/null | awk '{print $1}')
[ -n "$P2" ] && ok "重启后仍存活 pid=$P2" || bad "杀掉之后没能重新起来"
c=$(logcat -d -b events 2>/dev/null | grep -c "am_crash.*$PK")
[ "$c" = "0" ] && ok "重启窗口内没有 am_crash" || bad "重启窗口内有 $c 条 am_crash"
v=$(logcat -d -b all 2>/dev/null | grep -c "VerifyError")
[ "$v" = "0" ] && ok "重启窗口内没有 VerifyError" || bad "重启窗口内有 $v 条 VerifyError"
if [ -n "$P2" ]; then
  [ "$(nsenter -t $P2 -m -- sha256sum "$PKAPK" 2>/dev/null | cut -d' ' -f1)" = "$WANT" ] \
    && ok "重启后的进程仍读到补丁版" || bad "重启后的进程看不到补丁"
fi
s=$(logcat -d -b all 2>/dev/null | grep "Failed to scan" | grep -c PowerKeeper)
[ "$s" = "0" ] && ok "PMS 没有针对 PowerKeeper 的 Failed to scan" || bad "有 $s 条"

echo ""
echo "=========== ③ 停 BPF 监视器 ==========="
echo "  init.svc.dynbpfloader=$(getprop init.svc.dynbpfloader)"
ps -A -o ARGS 2>/dev/null | grep -q '[h]yper_bpfloader --monitor-mode' \
  && bad "BPF 监视器仍在运行" || ok "没有 --monitor-mode 进程"

echo ""
echo "=========== ④ 停死电话栈 ==========="
echo "  ro.radio.noril=$(getprop ro.radio.noril)"
for p in com.qti.phone com.qualcomm.qcrilmsgtunnel com.qualcomm.qti.telephonyservice; do
  if pm list packages 2>/dev/null | grep -qx "package:$p"; then
    pm list packages -d 2>/dev/null | grep -qx "package:$p" \
      && ok "$p 已停用" || bad "$p 存在但未停用"
  else
    ok "$p 本机不存在（跳过）"
  fi
done

echo ""
echo "=========== ⑭ sepolicy ==========="
grep -q "⑭ sepolicy apply rc=0" "$LOG" 2>/dev/null && ok "sepolicy 已显式应用" || bad "没有 apply 记录"

echo ""
echo "=========== 零常驻进程 ==========="
n=$(ps -A -o ARGS 2>/dev/null | grep -cE '[t]b378fc|[s]upervisor|[m]onitor\.sh|[p]enring|[b]rushwatch|[s]toprompen')
[ "$n" = "0" ] && ok "没有任何模块相关的常驻进程" || bad "有 $n 个疑似常驻进程"

echo ""
echo "=========== 模块日志尾部 ==========="
tail -16 "$LOG" 2>/dev/null

echo ""
if [ "$FAIL" = "0" ]; then echo "########## 全部通过 ##########"; else echo "########## 有 $FAIL 项失败 ##########"; fi
exit "$FAIL"
