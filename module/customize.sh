#!/system/bin/sh
# 安装期脚本（KernelSU / Magisk 在刷入时执行；设备上的 /data/adb/modules 里不会保留它，
# 这份是从 v2.0 的安装包里恢复出来、按 v3.0 的文件清单更新过的）。
ui_print " "
ui_print "- TB378FC HyperOS 修复 v3.0"
ui_print "- ① 手写笔休眠唤醒  ② PowerKeeper 修复"
ui_print "- ③ 停 BPF 监视器    ④ 停死电话栈"
ui_print "- 作者: ACLaniakea"
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/config" 0 0 0644
set_perm "$MODPATH/bin/PenBridge.apk" 0 0 0644
set_perm "$MODPATH/payload/PowerKeeper.apk" 0 0 0644
set_perm "$MODPATH/tools/patch_powerkeeper.py" 0 0 0644
set_perm "$MODPATH/tools/fix_static.py" 0 0 0644
