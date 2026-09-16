#!/system/bin/sh
# 安装期脚本（KernelSU / Magisk 在刷入时执行；设备上的 /data/adb/modules 里不会保留它，
# 这份是从 v2.0 的安装包里恢复出来、按 v3.1 的文件清单更新过的）。
ui_print " "
ui_print "- TB378FC HyperOS 修复 v3.6"
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
