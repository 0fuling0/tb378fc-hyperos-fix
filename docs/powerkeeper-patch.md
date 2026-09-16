# ② PowerKeeper 字节码补丁

移植者手工改过 MIUI 的 **PowerKeeper**，改坏了**两处**。两处都让类通不过校验，
`com.miui.powerkeeper` 开机即崩，MIUI 的省电管理整个不可用。

本文记录：坏在哪、怎么修的、**为什么"改对了字节码"还远远不够**（有三个独立的坑会让补丁
静默失效），以及怎么验证。

---

## 一、坏点 a：`void` 方法里 `return` 了值

类 `LocalUpdateUtils`，方法 `startCloudSyncData`：

```text
type   : (Landroid/content/Context;Z)V      ← 声明返回 void
0001: 0f00  return v0                       ← 0x0f 是 return（0x0e 才是 return-void）
```

移植者的**本意**是"让这个方法直接返回、禁用云同步"，但写成了 `return v0`。
`0x0f`（`return`，带返回值）用在返回类型为 `V` 的方法里 —— 整个类**通不过校验** →
每次开机 `VerifyError`：

```
java.lang.VerifyError: Verifier rejected class
  com.miui.powerkeeper.cloudcontrol.LocalUpdateUtils:
  void ...startCloudSyncData(android.content.Context, boolean) failed to verify:
  [0x1] unexpected non-category 1 return type
```

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
只需要重算 dex 头部的 `adler32` 与 `SHA-1`。
（搬列表会引起 ULEB128 重编码，所以补丁不是"3 段改动"，实测是 93 段 / 332 字节 ——
但全部落在 `classes.dex` 的数据段内，文件长度不变。）

---

## 三、重建流程

```text
payload-src/PowerKeeper-stock.apk          ← 移植包原厂 APK（补丁输入，**不入库**，体积大）
    │  payload-src/patch_powerkeeper.py    字节补丁：坏点 a
    │                                       0x0f return v0 → 0x0e return-void
    └── classes-patched.dex
    │  payload-src/fix_static.py           结构性补丁：坏点 b
    │                                       移入 direct_methods + ACC_STATIC + ins_size 1→0
    └── classes-patched2.dex
    │  payload-src/repack_payload.py       等长原地塞回（调用 apk_inplace.py，**不做 zip 重建**）
    v
module/payload/app/PowerKeeper.apk         ← 入库的产物（设备上 bind mount 的就是它）
```

一条命令跑完：

```bash
./build.sh --payload
```

`module/payload/app/PowerKeeper.apk` **已经入库**，日常构建（`./build.sh`）不会碰它 ——
只有需要改补丁逻辑时才跑 `--payload`。

### 3.1 必须做"等长原地补丁"，不能重建 zip

这是本项目最贵的一个教训。用 Python `zipfile` 逐条目重建 zip 会把
**APK Signing Block**（v2/v3 签名块，位于「最后一个 local entry」与「central directory」之间）
**整个丢掉** —— 它不是 zip 条目，`zipfile` 看不见它。

Android 11+ 对 `targetSdk>=30` 强制要求 v2 签名，PMS 于是直接拒绝扫描：

```
W PackageManager: Failed to scan /system_ext/app/PowerKeeper:
    No APK Signature Scheme v2 signature in package
```

结果是 `com.miui.powerkeeper` **根本没装上** —— 而模块日志照样写"已挂载"，
从任何 root 视角检查都是对的，非常难查。

`payload-src/apk_inplace.py` 因此改成**原地等长替换**：

- 只覆盖 `classes.dex` 的**数据段**（`ZIP_STORED`，长度不变）；
- 回填两处 CRC-32：local file header 的 `+14`、central directory 的 `+16`；
- **容器其余部分逐字节不动** → 所有 offset 仍然成立，central directory / EOCD /
  签名块原样保留（本机 4096 字节）。

产物 **6228160 字节，与原厂完全等长**。`repack_payload.py` 会断言「改动只能落在
`classes.dex` 数据段 + 两处 CRC-32 之内」，越界就拒绝打包；
`tools/verify_pack.py` 里另有一道「payload 必须带 APK Signing Block」的守卫。

### 3.2 顺带一个结论：不能改用 `pm install`

既然挂载这么麻烦，能不能干脆 `pm install` 把补丁 APK 装成"系统应用更新"（落在 `/data/app`，
真实文件，不需要任何 mount）？**不行。** 补丁改了 `classes.dex`，v3 签名块里的内容摘要
必然失效，而重签需要平台密钥。实测：

```
Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES: Failed to collect certificates from
  /data/app/vmdl336137160.tmp/base.apk using APK Signature Scheme v3:
  SHA-256 digest of contents did not verify]
```

---

## 四、为什么 PMS 会接受一个被改过的 APK

**不是**因为 `ro.debuggable=1`（这个说法是错的，实测在 `ro.debuggable=1` 的设备上，
缺 v2 签名的 APK 照样被拒）。真正的原因是两条叠加：

1. **签名块还在、证书没变** → PMS 能从签名块里取到证书，与 `packages.xml` 里记录的
   原厂证书**一致**；
2. **APK 尺寸与原厂完全等长** → PMS 认为这个包"没变过"，走**缓存校验路径**，
   不做完整的内容摘要校验。

两条缺一不可。所以"等长 + 保签名块"不只是为了好看，是**功能必需**。

> 反过来说，这也意味着：如果哪天 PMS 因为别的原因走了完整校验（例如换了尺寸、或者
> `packages.xml` 被清），这个包就会被拒。这是本方案已知的脆弱点，
> 但"用平台密钥重签"这条路走不通，只能接受。
>
> 另外注意：这也解释了为什么 ③ **不能**靠"把 `ro.debuggable` 改成 0"来解决 ——
> 不是因为 ② 依赖它（② 不依赖），而是因为 `dynbpfloader` 的启动触发器
> `on property:sys.boot_completed=1 && property:ro.debuggable=1` 需要它为 1。
> 见 [bpfmon-stop.md](bpfmon-stop.md) 的 3.2。

---

## 五、为什么用 bind mount，以及"挂上了"为什么还不够

本机的 KernelSU 是 **ReSukiSU 4.2.0-rc1-52 late-load LKM** 形态，**不做文件级 overlay** ——
模块里的 `system_ext/app/PowerKeeper/...` **不会**被叠到真实路径上。所以只能在脚本里显式挂。

挂的时候踩了三个坑，**每一个都会让补丁静默失效**：

### 坑 1：KernelSU 会把模块挂载从 App 进程里卸掉

这是它隐藏 root/模块的设计。实测 post-fs-data 阶段挂的那次：

| 视角 | 读到的 `PowerKeeper.apk` |
|---|---|
| `init` / `su` | `279592be…`（补丁版） |
| `com.miui.powerkeeper`（`android.uid.system` / uid **1000**） | `dd3d422e…`（**ROM 原件**） |

也就是说 **App 自己的 mount namespace 里根本没有这条挂载**。
判据不能看 `/proc/mounts`（那是 init 视角），要看 `/proc/<pid>/mountinfo`。

> 注意 uid 1000 也一样躲不过 —— 它不是"只对普通 App 生效"。

### 坑 2：同一个 init namespace、同一条路径，只有"晚挂"才有效

把 `umount` + `mount` 挪到 **`boot_completed` 之后**，新起的 App 进程立刻就能看到补丁；
放在 `late_start`（`boot_completed` 之前）则看不到。两次的
ns（`mnt:[4026532850]`）和 mnt_id（226，Linux 的 `ida` 会复用最小空闲 id）**完全相同**，
所以这是**时机**问题，不是"挂错了地方"。

### 坑 3：脚本自己的 mount namespace 可能不是 init 的

`service.sh` 由 KernelSU 执行，实测某些情况下拿到的 ns 与 init 不同 —— 在那里 `mount`
只影响脚本自己：日志写"已挂载"、脚本视角 `sha256sum` 也对，但 init / zygote / App
全都看不到。`service.sh` 会在启动时比对 `readlink /proc/self/ns/mnt` 与
`/proc/1/ns/mnt`，不一致就自动用 `nsenter -t 1 -m --` 切到 init 的 ns 再操作。

### 最终做法

```sh
# post-fs-data.sh：挂一次（让 PMS 在包扫描阶段就看到补丁版）
mount -t none -o bind "$MODDIR/payload/app" /system_ext/app/PowerKeeper

# service.sh：late_start 先挂一次（best effort），
#             boot_completed 之后再 umount + mount 一次（最多重试 3 次）——
#             这一次才对 App 生效
#             然后显式拉起进程（开机早期它已崩过几次，AMS 的崩溃退避会退到 1h/2h）
am start-service -n com.miui.powerkeeper/.PowerKeeperBackgroundService
```

挂的是**父目录** `/system_ext/app/PowerKeeper` 而不是那个 APK 文件：
父目录一挂，ROM 预编译的 `oat/` 也一起被盖掉，ART 不会再用那份基于坏字节码编出来的 odex。

**已知副作用（无害）**：`boot_completed` 之前 powerkeeper 会崩几次，开机日志里能看到几条
`am_crash` / `VerifyError`；约 1.5 分钟后由模块自动恢复并常驻。这是"补丁生效窗口"的代价。

---

## 六、验证

```bash
M=/data/adb/modules/tb378fc_hyperos_fix_lite

# 1) init 视角挂上了没有
adb shell su -c 'grep PowerKeeper /proc/1/mountinfo'

# 2) 进程活没活（关键）
adb shell su -c 'pidof com.miui.powerkeeper'

# 3) **最关键**：App 自己的 namespace 里有没有这条挂载
adb shell su -c 'p=$(pidof com.miui.powerkeeper); grep PowerKeeper /proc/$p/mountinfo'
adb shell su -c 'p=$(pidof com.miui.powerkeeper); nsenter -t $p -m -- sha256sum /system_ext/app/PowerKeeper/PowerKeeper.apk'

# 4) 有没有针对 PowerKeeper 的崩溃 / 扫描失败
adb shell su -c 'logcat -b all -c'
adb shell su -c 'kill -9 $(pidof com.miui.powerkeeper)'   # AMS 会自动重启它
sleep 12
adb shell su -c 'logcat -d -b all | grep -E "am_crash.*powerkeeper|VerifyError|Failed to scan.*PowerKeeper"'

# 5) 模块日志
adb shell su -c "grep PowerKeeper $M/lite.log"
```

期望：

- 第 3 步 `sha256sum` = `279592be00a95a6ee9d6b46effda35c93b4553263fa4f307966e9cb53343a8fc`；
- 第 4 步清日志之后**一条都不该有**（开机早期那几条是修复窗口内的，属预期）；
- 第 5 步能看到
  `② boot_completed 之后重挂一次（late_start 那次对 App 不可见）` →
  `② powerkeeper 已用补丁版启动 (pid=…)`。

---

## 七、卸载后的行为

bind mount **只存在于本次开机**，重启后自然消失，也就是回到未修补状态
（`com.miui.powerkeeper` 又会开机即崩）。没有别的收尾动作。
