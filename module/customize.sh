#!/system/bin/sh
# 安装期脚本（KernelSU / Magisk 在刷入时执行；设备上的 /data/adb/modules 里不会保留它）。
ui_print " "
ui_print "- TB378FC HyperOS 修复 Lite v1.0"
ui_print "- 只做系统修复：② PowerKeeper  ③ 停 BPF 监视器  ④ 停死电话栈  ⑭ 开发者选项"
ui_print "- 不含任何常驻守护进程，不安装任何 APK，不需要 LSPosed"
ui_print "- 开关可在 KernelSU 管理器的 WebUI 里改，或用模块目录下的 disable-* 标记文件强制关"
ui_print "- 需要 App 的手写笔功能（唤醒/胶囊/手势桥/笔刷触感/注视感知）见同仓库 Full 分支"
ui_print "- 作者: ACLaniakea, fuling"
ui_print " "

chmod 0755 "$MODPATH"
chmod 0644 "$MODPATH"/*.prop "$MODPATH"/config 2>/dev/null

# ⚠️ KernelSU 的安装器**没有** Magisk 的 set_perm/set_perm_recursive（会静默失效），
# 所以必须用普通 chmod。曾经就因为这个：ksud 装完后可执行位丢了 → 脚本根本跑不起来。
chmod 755 "$MODPATH"/*.sh 2>/dev/null
chmod 644 "$MODPATH"/payload/*.apk "$MODPATH"/webroot/* "$MODPATH"/sepolicy.rule 2>/dev/null

# ---- 升级时保住用户已经调好的开关 ----
# ksud module install 会把包里的 config 原样写进 /data/adb/modules_update/<id>/，
# 重启时用它覆盖现行目录 —— 也就是**每次升级都会把用户在 WebUI 里点过的开关全部重置回默认**。
# 实测（v3.8，Full 分支）：往现行 config 里加一行 MARKER_TEST，装一次同一个 zip 再重启，
# 那行就没了；同时被手动打开的开关也回到了默认值。用户视角就是"升级一次，设置全没了"。
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
