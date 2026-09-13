#!/system/bin/sh
# 重启本模块的看护进程（WebUI --set 与排障都用它）。
# 教训：以前用 `awk '$2=="service.sh" && $3=="--supervise"'` 匹配 —— ps 行其实是
#   <pid> sh /data/adb/modules/.../service.sh --supervise
# 所以 $2 是 "sh"、$3 是路径，条件永远不成立 → 旧看护根本没被杀 → 配置改了也不生效。
MODDIR=${MODDIR:-${0%/*}}
me=$$
sleep 1
for p in $(ps -A -o PID,ARGS | awk -v me="$me" '$1+0 != me+0 && /service\.sh --(supervise|monitor|brushwatch)/ {print $1}'); do
    kill -9 "$p" 2>/dev/null
done
for p in $(ps -A -o PID,ARGS | awk -v me="$me" '$1+0 != me+0 && /(^| )penring( |$)/ {print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 1
rm -rf "$MODDIR/brush.lock" 2>/dev/null
rm -f "$MODDIR"/brush.last.* 2>/dev/null      # 让首次扫描一定重设 base
setsid /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 </dev/null &
