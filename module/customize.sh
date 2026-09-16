#!/system/bin/sh
# 安装期脚本（KernelSU / Magisk 在刷入时执行；设备上的 /data/adb/modules 里不会保留它，
# 这份是从 v2.0 的安装包里恢复出来、按 v3.1 的文件清单更新过的）。
ui_print " "
ui_print "- TB378FC HyperOS 修复 v3.8"
ui_print "- 系统修复  : ② PowerKeeper  ③ 停 BPF 监视器  ④ 停死电话栈  ⑭ 开发者选项"
ui_print "- 手势与书写: ⑥ 手势桥  ⑦ 笔刷触感  ⑫ 设置→笔 下发"
ui_print "- 手写笔连接: ① 唤醒  ⑤ 电量胶囊  ⑨ 休眠档  ⑬ 屏幕指令"
ui_print "- 注视感知  : ⑧ AON"
ui_print "- 以上每一项都能在 KernelSU WebUI 里单独开关（四类各有总开关）"
ui_print "- 「需要 App」的那组默认全关，所以默认**不会**安装任何 APK"
ui_print "- 作者: ACLaniakea, fuling"
ui_print " "

chmod 0755 "$MODPATH"
chmod 0644 "$MODPATH"/*.prop "$MODPATH"/config 2>/dev/null

# ⚠️ KernelSU 的安装器**没有** Magisk 的 set_perm/set_perm_recursive（静默失效），
# 所以必须用普通 chmod。曾经就因为这个：ksud 装完后 bin/penring 是 644 → penring 根本
# 起不来 → 手势桥全死、"卸载重装后笔刷触感没了"。
chmod 755 "$MODPATH"/*.sh "$MODPATH"/bin/penring "$MODPATH"/bin/*.sh 2>/dev/null
chmod 644 "$MODPATH"/bin/TbFix.apk "$MODPATH"/payload/*.apk "$MODPATH"/webroot/* "$MODPATH"/sepolicy.rule 2>/dev/null

# ---- 升级时保住用户已经调好的开关 ----
# ksud module install 会把包里的 config 原样写进 /data/adb/modules_update/<id>/，
# 重启时用它覆盖现行目录 —— 也就是**每次升级都会把用户在 WebUI 里点过的开关全部重置回默认**。
# 实测（v3.8）：往现行 config 里加一行 MARKER_TEST，装一次同一个 zip 再重启，那行就没了；
# 同时被手动打开的 AON=1 也回到了默认的 0。用户视角就是"升级一次，设置全没了"。
# 这里在安装期把设备上已有的 config 搬回来 —— 包里的那份只当"出厂默认"。
MODID="$(sed -n 's/^id=//p' "$MODPATH/module.prop" 2>/dev/null | head -1)"
[ -n "$MODID" ] || MODID="$(basename "$MODPATH")"
OLD_CFG="/data/adb/modules/$MODID/config"
# 只认"看起来确实是一份 config"的旧文件（非空、且有 KEY=VALUE 行）。
# 为什么要挑：把半截/损坏的文件搬过来，比直接用默认值还糟 —— 用户会得到一个
# 部分键缺失的 config，而缺键的语义在各处并不一致。
if [ -f "$OLD_CFG" ] && [ -s "$OLD_CFG" ] && grep -q '^[A-Za-z_][A-Za-z0-9_]*=' "$OLD_CFG" 2>/dev/null; then
    if cp -f "$OLD_CFG" "$MODPATH/config" 2>/dev/null; then
        ui_print "- 已保留你之前的开关设置（沿用设备上的 config）"
    else
        ui_print "- 提示: 旧 config 读取失败，本次用默认设置"
    fi
else
    ui_print "- 全新安装：使用默认设置"
fi
