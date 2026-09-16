# ② PowerKeeper 字节码补丁

移植者手工改过 MIUI 的 **PowerKeeper**，改坏了**两处**。两处都让类通不过校验，
`com.miui.powerkeeper` 开机即崩，MIUI 的省电管理整个不可用。

本文记录：坏在哪、怎么修的、为什么这么修、以及为什么 PMS 会接受一个被改过的 APK。

---

## 一、坏点 a：`void` 方法里 `return` 了值

类 `LocalUpdateUtils`，方法 `startCloudSyncData`：

```text
type   : (Landroid/content/Context;Z)V      ← 声明返回 void
0001: 0f00  return v0                       ← 0x0f 是 return（0x0e 才是 return-void）
```

移植者的**本意**是"让这个方法直接返回、禁用云同步"，但写成了 `return v0`。
`0x0f`（`return`，带返回值）用在返回类型为 `V` 的方法里 —— 整个类**通不过校验** →
每次开机 `VerifyError`。

**修法**：`0x0f` → `0x0e`（`return-void`），单字节。语义正是移植者想要的"直接返回"。

---

## 二、坏点 b：静态方法丢了 `static`

类 `DisplayFrameSetting`，方法 `isFeatureOn`：

| | access flags | `ins_size` |
|---|---|---|
| 原厂应为 | `0x0009` = `PUBLIC \| STATIC` | 0 |
| 被改成 | `0x0001` = `PUBLIC` | 1（多了 `this`） |

而**全部 4 个调用点都是 `invoke-static`** → `IncompatibleClassChangeError`。

**这一处不能只改一个字节。** dex 规定静态方法必须位于 `class_data_item.direct_methods`，
而它现在在 `virtual_methods` 里。所以修补器要同时做三件事：

1. 把该 `encoded_method` 条目从 `virtual_methods` 移到 `direct_methods`；
2. 给它补上 `ACC_STATIC`（`0x0001` → `0x0009`）；
3. 把 `code_item.ins_size` 从 1 改成 0。

**关键约束：改写必须是等长的。** 实测 `1639 → 1639` 字节，**文件内所有偏移不变**，
只需要重算 dex 头部的 `adler32` 与 `SHA-1`。这也正是 `repack_payload.py` 里
`if len(dex) != old.file_size: raise SystemExit(...)` 那道断言在守的东西 ——
长度一变说明偏移全乱了，直接拒绝打包而不是产出一个坏包。

---

## 三、重建流程

```text
payload-src/PowerKeeper-stock.apk          ← 移植包原厂 APK（补丁输入，**不入库**，体积大）
    │  payload-src/patch_powerkeeper.py    字节补丁：坏点 a
    │                                       0x0f return v0 → 0x0e return-void
    ├── PowerKeeper-patched.apk
    └── classes-patched.dex
    │  payload-src/fix_static.py           结构性补丁：坏点 b
    │                                       移入 direct_methods + ACC_STATIC + ins_size 1→0
    └── classes-patched2.dex
    │  payload-src/repack_payload.py       重新塞回 zip 容器
    v
module/payload/PowerKeeper.apk             ← 入库的产物（设备上 bind mount 的就是它）
```

一条命令跑完：

```bash
./build.sh --payload
```

`module/payload/PowerKeeper.apk` **已经入库**，日常构建（`./build.sh`）不会碰它 ——
只有需要改补丁逻辑时才跑 `--payload`。

### 打包时的两个要点

1. **APK 里 `classes.dex` 是 Stored（不压缩）的**（原厂如此，dex 可以直接 mmap）。
   重新打包必须沿用原始条目的 `compress_type` 与时间戳，否则 APK 体积会缩水一半、
   与原厂差异变大。`repack_payload.py` 的做法是逐条目复制 `ZipInfo` 元数据，只换
   `classes.dex` 的内容。
2. **校验方式**：本脚本产出的 payload 与设备上正在用的那份，**510 个条目里 509 个 CRC 完全相同**，
   `classes.dex` 逐字节相同（只有 zip 容器的时间戳 / 额外字段有差异，不影响运行）。

---

## 四、为什么 PMS 会接受一个被改过的 APK

改过的 APK 签名跟原厂对不上，正常会被 PackageManager 拒掉。这里能装上的原因是：
**这个移植包是 user 构建，却标了 `ro.debuggable=1`** —— PMS 对 debuggable 构建放宽了校验。

> 这也是为什么 ③ 不能靠"把 `ro.debuggable` 改成 0"来解决：那样 ② 就装不上了。
> 两处是**同一个属性**在兜着，见 [bpfmon-stop.md](bpfmon-stop.md) 的 3.2。

---

## 五、为什么用 bind mount 而不是模块的 `system/` 目录

本机的 KernelSU 是 **ReSukiSU 4.2.0-rc1 late-load LKM** 形态，**不做文件级 overlay** ——
模块里的 `system_ext/app/PowerKeeper/PowerKeeper.apk` **不会**被叠到真实路径上。

所以 `post-fs-data.sh` 里显式来：

```sh
chown 0:0 "$PAYLOAD"; chmod 0644 "$PAYLOAD"
chcon u:object_r:system_file:s0 "$PAYLOAD"
mount -t none -o bind "$PAYLOAD" /system_ext/app/PowerKeeper/PowerKeeper.apk
```

**必须在 `post-fs-data` 阶段做**（zygote 之前、PMS 扫描包之前）。晚一步 PMS 已经把
那个坏的 APK 读进内存了，再挂也没用。

---

## 六、验证

```bash
# 1) 挂上了没有
adb shell su -c 'grep PowerKeeper /proc/mounts'

# 2) 进程活没活（期望看到三个 service 都在）
adb shell su -c 'ps -A -o NAME | grep powerkeeper'

# 3) 还有没有开机期的 VerifyError / IncompatibleClassChangeError
adb shell su -c 'logcat -d | grep -E "VerifyError|IncompatibleClassChange" | grep -i powerkeeper'

# 4) 模块自己的日志
adb shell su -c 'grep PowerKeeper /data/adb/modules/tb378fc_hyperos_fix_lite/lite.log'
```

期望：`② PowerKeeper 补丁已挂载 (e696d3695681ec6b)`，并且
`PowerStateMachineService` / `PowerKeeperBackgroundService` / `FeedbackControlService` 常驻。

---

## 七、卸载后的行为

bind mount **只存在于本次开机**，重启后自然消失，也就是回到未修补状态
（`com.miui.powerkeeper` 又会开机即崩）。没有别的收尾动作。
