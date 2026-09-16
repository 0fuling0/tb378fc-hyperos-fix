# ⑭ 开发者选项 SELinux 修复

`TB378FC` + HyperOS 移植包在 **SELinux Enforcing** 下，「设置 → 开发者选项」**必现闪退**；
`setenforce 0` 就正常。这里是根因、在模块里的接法、以及验证方法。

> 本项在 **v3.6 并入 Full 分支的主模块**（之前是个独立模块 `devopts-selinux-fix`），
> **v1.0 起 Lite 分支也包含它**。没有单独的包，也没有 disable 标记 ——
> 它是崩溃修复，不是可选功能。

---

## 一、根因

`com.android.settings` 以 **uid 1000** 运行在 **`system_app`** 域。打开开发者选项时，
`AbstractLogpersistPreferenceController.updateLogpersistValues()` 在 `onResume` 里依次写两个系统属性：

| 属性 | SELinux 类型 |
|---|---|
| `logd.logpersistd` | `logpersistd_logging_prop` |
| `persist.logd.logpersistd.buffer` | `logpersistd_logging_prop` |

移植包的策略**没有**给 `system_app` 授予该类型的 `property_service set`（以及 `file read`），
于是 `SystemProperties.native_set()` 抛 `RuntimeException`，`onResume` 没接住 → Activity 崩溃。

```text
avc: denied { set } for property=logd.logpersistd scontext=u:r:system_app:s0
     tcontext=u:object_r:logpersistd_logging_prop:s0 tclass=property_service permissive=0
avc: denied { read } ... tcontext=u:object_r:logpersistd_logging_prop:s0 tclass=file
```

一个容易误判的细节：`mLogpersistCleared` 是在失败的 `set()` **之后**才赋值的，
所以标志位永远锁不上 —— 这是**必现**崩溃，不是偶发，也不是"有时候能开"。

**修法只补两条最小权限，不放开别的任何东西**（见 `module/sepolicy.rule` 尾部）：

```
allow system_app logpersistd_logging_prop file { getattr open read map }
allow system_app logpersistd_logging_prop property_service set
```

语法是 magiskpolicy 风格：`allow <scontext> <tcontext> <tclass> <perms>`，
字段之间是**空格**，**不能写成 `a b:c d`**。

---

## 二、在模块里怎么接的

| 位置 | 做了什么 |
|---|---|
| `module/sepolicy.rule` | 只有两条规则（KernelSU 开机声明式加载） |
| `module/post-fs-data.sh` | 末尾用 `ksud sepolicy apply "$MODDIR/sepolicy.rule"` **显式再应用一次**，结果写 `lite.log` |
| `module/service.sh` 的 `do_sepolicy` | 等 `boot_completed` 后再跑一次（刷掉开机期可能被缓存的拒绝） |
| `module/service.sh --sepolicy` | 子命令：**免重启手动重应用** |
| `module/webroot/index.html` | ⑭ 那一行带「重新应用（免重启）」按钮，走的就是上面这条子命令 |

手动重应用：

```sh
sh /data/adb/modules/tb378fc_hyperos_fix_lite/service.sh --sepolicy
```

原理：`ksud sepolicy apply` 把规则注入**内存中的运行时策略**并触发一次策略重载，
同时刷掉**内核 AVC** 与 **init 用户态 libselinux** 两边的陈旧拒绝缓存 → **立即生效、无需重启**。
代价是只在内存里，重启后由 `post-fs-data.sh` 与开机动作自动重放。

---

## 三、为什么不只靠 `sepolicy.rule`

KernelSU 开机会自动加载模块的 `sepolicy.rule`，但实测在 **ReSukiSU 4.2.0-rc1 + late-load LKM** 上
**纯声明式加载并不可靠** —— 出现过"删掉模块重启后，最原始的 `logd.logpersistd` 拒绝又回来了"。
所以两个开机脚本里各用 ksud 的运行时通道显式再应用一遍（实测开机 `rc=0`，稳定生效）。

顺带一个**重要边界**：`ksud sepolicy apply` 是"按传入文件重新推导并应用"，**不跨调用累积**。
所以传给它的必须是**完整**的 `sepolicy.rule`。Lite 分支里这个文件就只有 ⑭ 这两条
（Full 分支还含 ⑧b AON 的三条 —— 如果你从 Full 切过来，注意别把两边混用）。
同理，**如果还有别的模块也用 `ksud sepolicy apply`，两个模块会互相覆盖**；
正确做法是把规则合并进同一个文件，只留一个应用方。

---

## 四、验证（防自欺，别只看"能打开"）

`persist.logd.logpersistd.buffer` 本来就是空值时，代码会**跳过写入** ——
只看"页面能打开"会得到**假阳性**。用「强制写入 + 冷启动」验证：

```bash
adb shell su -c "
/data/adb/ksu/bin/resetprop persist.logd.logpersistd.buffer 1M
/data/adb/ksu/bin/resetprop logd.logpersistd logpersistd
am force-stop com.android.settings
am start -W -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS
dumpsys activity activities | grep -m1 topResumedActivity
getprop logd.logpersistd; getprop persist.logd.logpersistd.buffer
"
```

**通过标准**：

- `LaunchState: COLD` 且 `Status: ok`
- `topResumedActivity=...Settings$DevelopmentSettingsActivity`
- 启动后 `logd.logpersistd` = `clear`、`persist.logd.logpersistd.buffer` = 空
  （说明**两次写入都真的成功了**，而不是被跳过）
- `dmesg | grep logpersistd` **无**新的 `avc: denied`

看开机是否应用成功：

```bash
adb shell su -c "grep '⑭ sepolicy apply' /data/adb/modules/tb378fc_hyperos_fix/wake.log | tail"
```

期望 `⑭ sepolicy apply rc=0 (...)`。

---

## 五、踩过的坑

1. **`ksud sepolicy apply` 不是增量的。** 对同一份规则文件连跑三次，三次都打印同样的
   `NormalPerm(...)` 行 —— 它每次都针对该文件重新推导并应用一遍。
   所以**别把它当"是否已生效"的探针**（输出为空 + `rc=0` 意味着文件为空/没解析，是警报不是成功）；
   也**别假设多次 apply 会累积**，传入的文件应包含**完整**规则集。
2. **`ksud module install` 不保留可执行位。** 装好后模块目录里所有文件都是 `0644`。
   KernelSU 自己用 `sh` 调用所以开机脚本不受影响，但手动跑必须 `sh <路径>`，不能 `./<路径>`。
3. **模块脚本可能整段被跳过。** 遇到过"一次开机 `post-fs-data.sh` 和 `service.sh` 一条日志都没有"，
   那次开发者选项又闪退了。原因没定论（怀疑 late-load LKM 的加载时机）。
   兜底就是 `service.sh --sepolicy`（或管理器「执行」按钮看状态）。
4. **策略体积不能当判据。** 本机开了 `selinux_hide`，`/sys/fs/selinux/policy` 的读数会被净化
   （同机两次读数都不一样：2565076 / 2540543）。只能看行为。
5. **`su -c` 传多行命令偶尔会打印一段 su usage**（`Argument to option 'c' missing`）但命令照常执行，
   是噪音。另外 `su -c` 里用 shell 变量赋值再引用（`R=/path; ... $R`）会丢，直接写绝对路径最稳；
   也别在 `su -c` 里 `cd X && cmd *`（cd 不生效，glob 会在错误目录展开）。
6. **`/`、`/vendor`、`/system_ext`、`/odm`、`/product` 都是 `super`(sda10) 的 EROFS 只读 dm 映射**，
   `mount -o remount,rw /` 返回 0 但写入仍报 `Read-only file system` —— 在线改不了、也改不持久。
   本 ROM 没有 `precompiled_sepolicy`，`init` 开机用 `secilc` 现编 CIL，所以离线改镜像里的 CIL
   理论上是可持久的，但属镜像级工程，不建议。
7. **移植包的 property_contexts 值得看一眼。** `/system/etc/selinux/plat_property_contexts` 里
   `logd.` 与 `persist.logd.` 都映射到 `logd_prop`，只有 `logd.logpersistd` /
   `persist.logd.logpersistd` 这两条**精确条目**映射到 `logpersistd_logging_prop`。
   所以出问题时先确认 `tcontext` 到底是哪个类型，别照着属性名前缀猜。
