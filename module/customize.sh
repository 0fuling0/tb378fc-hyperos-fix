#!/system/bin/sh
# 安装期脚本（KernelSU / Magisk 在刷入时执行；设备上的 /data/adb/modules 里不会保留它，
# 这份是从 v2.0 的安装包里恢复出来、按 v3.1 的文件清单更新过的）。
ui_print " "
ui_print "- TB378FC HyperOS 修复 v3.1"
ui_print "- ① 手写笔休眠唤醒  ② PowerKeeper 修复"
ui_print "- ③ 停 BPF 监视器    ④ 停死电话栈"
ui_print "- ⑤ 手写笔吸附胶囊"
ui_print "- 作者: ACLaniakea"
ui_print " "

chmod 0755 "$MODPATH"
chmod 0644 "$MODPATH"/*.prop "$MODPATH"/config 2>/dev/null

# ⚠️ KernelSU 的安装器**没有** Magisk 的 set_perm/set_perm_recursive（静默失效），
# 所以必须用普通 chmod。曾经就因为这个：ksud 装完后 bin/penring 是 644 → penring 根本
# 起不来 → 手势桥全死、"卸载重装后笔刷触感没了"。
chmod 755 "$MODPATH"/*.sh "$MODPATH"/bin/penring "$MODPATH"/bin/*.sh 2>/dev/null
chmod 644 "$MODPATH"/bin/TbFix.apk "$MODPATH"/payload/*.apk "$MODPATH"/webroot/* "$MODPATH"/sepolicy.rule 2>/dev/null
