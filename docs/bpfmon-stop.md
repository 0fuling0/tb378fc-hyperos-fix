# ③ 停 BPF 监视器（hyper_bpfloader / dynbpfloader）

本文记录：这个监视器**为什么会把设备重启进 recovery**、三条"看起来能关掉它"的路为什么走不通、
以及 Lite 分支最终采用的**零守护进程**方案。

---

## 一、`hyper_bpfloader` 有两个身份，别混为一谈

`/system_ext/etc/init/hyper_bpfloader.rc` 里定义了**两个 service，用同一个二进制**：

```rc
service hyper_bpfloader /system_ext/bin/hyper_bpfloader
    class core
    user root
    group root system
    oneshot
    reboot_on_failure reboot,hyper-bpfloader-failed

service dynbpfloader /system_ext/bin/hyper_bpfloader --monitor-mode
    class late_start
    user root
    group root system
    disabled
```

| | `hyper_bpfloader` | `dynbpfloader` |
|---|---|---|
| 角色 | **开机期的 BPF 加载器** | **开机后的监视器** |
| 触发 | `on load-bpf-programs` | `on property:sys.boot_completed=1 && property:ro.debuggable=1` → `start dynbpfloader` |
| 行为 | 加载约 50 个 BPF 程序（含 netd 依赖的那些） | 检查 MIUI 私有 BPF 程序是否已 pin，失败就判定"系统损坏" |
| 本模块动它吗 | **不动** | **停掉** |

③ 只关第二个。加载器照常工作 —— 那是系统正常启动需要的东西，动它才是真把设备搞坏。

---

## 二、它为什么重启设备

监视器检查的是 `/sys/fs/bpf/miui/prog_MiuiMmTrace_*` 这类 **MIUI 私有 BPF 程序**有没有 pin 住。
本机（TB378FC + HyperOS 移植包）的情况是：

- 那套 `.o` 引用的是 **6.10+ 内核符号**，而本机内核是 **6.6.82** → 89 个程序**一个都加载不了**；
- 于是监视器打：

  ```text
  W BpfMonitor: open obj pinned failed: ... No such file or directory
  W BpfMonitor: Collect pinned obj info failed!
  ```

- 判定"系统损坏" → `Bpf monitor reboot to recovery` → 往 recovery 引导块写标记 + `reboot,recovery`。

实测的触发条件是**用 DroidSpaces 容器**：不开容器时它能忍着，一旦起容器就触发。
也就是说不修的话，这台设备**用不了容器**，而且失败方式是"重启进 recovery"这种最难排查的形态。

---

## 三、三条走不通的路（都实测过，别再试）

### 3.1 用模块覆盖 `hyper_bpfloader.rc` —— 不行，两条独立理由

**理由一：本机的 KernelSU 不做文件级 overlay。**
本机是 **ReSukiSU 4.2.0-rc1-52 late-load LKM** 形态，模块装到 `/data/adb/modules/<id>/` 里，
但模块目录里的 `system/` **不会**被叠到真实文件系统上（没有 magic mount）。
实测：往模块里放 `system_ext/etc/init/zzprobe.rc`，内容 `on boot / setprop zzprobe.rc_overlay 1`，
重启后 `/system_ext/etc/init/zzprobe.rc` **不存在**，`zzprobe.rc_overlay` 也是**空**的。

> 这也正是本模块**没有 `system/` 目录**、② 靠脚本里显式 `mount -o bind` 的原因。

**理由二：就算能覆盖也赶不上。**
init 在 second stage 的 `LoadBootScripts()` 里**一次性解析完所有 `.rc`**，
这件事发生在 `post-fs-data` 触发**之前**。而模块脚本最早只能在 `post-fs-data` 阶段跑 ——
那时候 `dynbpfloader` 这个 service 已经定义好了。

### 3.2 把 `ro.debuggable` 改成 0 —— 会顺带废掉 ②

触发器要求 `ro.debuggable=1`，改成 0 确实能让监视器不启动。**但 ② 能装上修补过的
PowerKeeper 正是靠 `ro.debuggable=1`**（这个移植包是 user 构建却标了它，PMS 才接受改过的 APK）。
关掉它 = 把 ② 废掉。所以不动。

### 3.3 `persist.sys.stability.bpfloader.bootlist_disable` —— 语义不对

二进制里确实有 `persist.sys.stability.bpfloader.bootlist_disable` 与
`..._whitelist_check_disable` 这两个开关属性，但它们的语义是"**跳过 elf 载入检查**"，
不是"**不重启**"。设了它监视器照样会走到 reboot 分支。

---

## 四、Lite 采用的方案：开机后 `ctl.stop` 一次，零守护

关键事实：`dynbpfloader` 是 **`disabled` 服务**（不随 class 自动起），
**唯一的启动点**是那一行 `on property:sys.boot_completed=1 && property:ro.debuggable=1`。
这个属性触发器**每次开机只触发一次**。

所以：

```sh
setprop ctl.stop dynbpfloader
```

开机后停一次就**永久生效**，init 不会把它拉回来。

**实测证据**（Full 分支当时还带看护进程，它的日志正好成了对照）：
停掉之后连续观察 **1 小时以上**，日志里 `stopped again` 出现 **0 次**，
`getprop init.svc.dynbpfloader` 一直是 `stopped`。

于是 Lite 的 `service.sh` 里 `do_bpfmon()` 就是：等 `boot_completed` → `ctl.stop` →
**脚本退出**。没有循环、没有看护、没有常驻进程。最多重试 3 轮（间隔 2s）纯属保险，
正常情况第一轮就成功。

```sh
# service.sh 里的核心（简化）
do_bpfmon() {
    i=0
    while [ "$i" -lt 3 ]; do
        i=$((i+1))
        if ! bpfmon_running && [ "$(getprop init.svc.dynbpfloader)" != "running" ]; then
            [ "$i" = 1 ] && log "③ 监视器未在运行，无需处理"
            break
        fi
        setprop ctl.stop dynbpfloader 2>/dev/null
        sleep 2
    done
}
```

判据用的是 **`ps -A -o ARGS | grep '[h]yper_bpfloader --monitor-mode'`**，
不能只用 `pidof hyper_bpfloader` —— 同一个二进制也是开机期那个 oneshot 加载器，会误判。
（`[h]` 这个写法是为了让 grep 自己的命令行不匹配到自己。）

---

## 五、验证

```bash
adb shell su -c 'getprop init.svc.dynbpfloader'      # 期望 stopped
adb shell su -c 'ps -A -o ARGS | grep [h]yper_bpfloader'   # 期望空（加载器早就退出了）
adb shell su -c 'logcat -d -s BpfMonitor'            # 期望重启后再无 reboot to recovery
```

再起一次 DroidSpaces 容器（这是原来能稳定触发的动作），观察设备**不再重启进 recovery**。

模块自己的日志：

```bash
adb shell su -c 'tail -20 /data/adb/modules/tb378fc_hyperos_fix_lite/lite.log'
```

期望看到 `③ 监视器已停（init.svc.dynbpfloader=stopped）`。

---

## 六、卸载后的行为

本模块**没有做任何持久化的禁用** —— 没改 `.rc`、没改属性、没改引导块。
卸载并重启后，监视器会照常由 init 拉起，也就是回到原始状态：
**不用容器时通常无感，用容器时可能被重启进 recovery。**

---

## 七、踩过的坑

1. **toybox 的 `grep` 不支持 BRE 的 `\|` 交替。**
   早期用 `grep -rl "dynbpfloader\|hyper_bpfloader" /system_ext` 搜，返回空，
   于是误判"标准 init 目录里没提到 dynbpfloader"。改成单模式 `grep -rl dynbpfloader` 立刻命中
   `/system_ext/etc/init/hyper_bpfloader.rc`、`/system_ext/bin/hyper_bpfloader`、
   `/system_ext/lib/libmiuibpf.so`。**在 toybox 上老老实实一次搜一个词。**
2. **别在全盘 `grep -r`。** 试过 `grep -rln "service dynbpfloader" /`，会遍历整个分区
   （含 6MB+ 的 jar），直接把 shell 卡死。要有界搜索：限定
   `/apex /system_ext /vendor /odm /product /system`，并且每个目录套 `timeout 25`。
3. **`reboot_on_failure` 只属于加载器那个 service。** 看到它别以为监视器也有 ——
   监视器的重启是自己 `reboot,recovery` 主动发的。
