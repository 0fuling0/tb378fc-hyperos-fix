#!/system/bin/sh
# 重启本模块的看护进程（WebUI --set 与排障都用它）。
# 教训：以前用 `awk '$2=="service.sh" && $3=="--supervise"'` 匹配 —— ps 行其实是
#   <pid> sh /data/adb/modules/.../service.sh --supervise
# 所以 $2 是 "sh"、$3 是路径，条件永远不成立 → 旧看护根本没被杀 → 配置改了也不生效。
MODDIR=${MODDIR:-${0%/*}}
me=$$
sleep 1

# 杀掉旧一代，并且**杀到真的没有了为止**。
# 为什么不能"快照一次 ps 然后 kill"：--supervise 每 5 秒会把死掉的 --monitor 重新拉起来，
# 快照之后被它拉起来的那个 monitor 会活下来；接着 setup 看到 supervisor 还活着就走
# "接管"分支 —— 于是旧一代继续按**旧配置**看护（实测：WebUI 关掉 ⑥/⑦ 后 penring /
# --brushwatch 还在跑）。循环杀能消掉这个竞态，最多 10 轮（约 10 秒）。
kill_gen() {
    local i p left
    i=0
    while [ "$i" -lt 10 ]; do
        left=$(ps -A -o PID,ARGS 2>/dev/null | awk -v me="$me" \
            '$1+0 != me+0 && /service\.sh --(supervise|monitor|brushwatch)/ {print $1}')
        [ -n "$left" ] || break
        for p in $left; do kill -9 "$p" 2>/dev/null; done
        sleep 1
        i=$((i+1))
    done
}
kill_gen

# penring 是 --supervise 的孩子，可能还在退出过程中；同样循环确认。
i=0
while [ "$i" -lt 5 ]; do
    left=$(ps -A -o PID,ARGS 2>/dev/null | awk -v me="$me" '$1+0 != me+0 && /(^| )penring( |$)/ {print $1}')
    [ -n "$left" ] || break
    for p in $left; do kill -9 "$p" 2>/dev/null; done
    sleep 1
    i=$((i+1))
done

rm -rf "$MODDIR/brush.lock" 2>/dev/null
rm -f "$MODDIR"/brush.last.* 2>/dev/null      # 让首次扫描一定重设 base
setsid /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 </dev/null &
