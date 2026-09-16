# TB378FC HyperOS 修复 Lite

联想小新 Pad Pro GT 13（**TB378FC**）刷 HyperOS 移植包之后，**只靠 root 就能修的那部分**。

> **不含任何常驻守护进程，不安装任何 APK，不需要 LSPosed。**
> 每一项都是"开机后做一次就结束"，做完脚本自己退出 —— 不占内存、不耗电、不需要看护。

需要 App 的手写笔功能（唤醒 / 电量胶囊 / 手势桥 / 笔刷触感 / 注视感知等）在**同仓库 `Full` 分支**，
本分支（`Lite`）不包含。两个分支的关系见 [五、与 Full 分支的关系](#五与-full-分支的关系)。

---

## 一、修了什么（4 项）

| 编号 | 修什么 | 怎么做 | 什么时候做 |
|---|---|---|---|
| **②** | **PowerKeeper 字节码** | `post-fs-data.sh` 与 `service.sh` 把修补过的 APK `mount -o bind` 到 `/system_ext/app/PowerKeeper`（挂父目录） | `post-fs-data` 一次（供 PMS 扫描）+ **`boot_completed` 之后一次**（这一次才对 App 生效） |
| **③** | **停 BPF 监视器** | 等 `boot_completed` 后 `setprop ctl.stop dynbpfloader` | 每次开机一次 |
| **④** | **停死电话栈** | `pm disable-user --user 0` 那三个电话包 | 每次开机复查（停用状态写在 `packages.xml`，跨重启保持） |
| **⑭** | **开发者选项闪退** | `ksud sepolicy apply` 补两条最小权限 | `post-fs-data` 与开机后各一次 |

### ② PowerKeeper

移植者手工改过 MIUI 的 PowerKeeper，改坏了**两处**字节码：

- `LocalUpdateUtils.startCloudSyncData` —— 声明是 `void`，却在方法体里 `return v0`
  （`0x0f` 是 `return`，`0x0e` 才是 `return-void`）→ 整个类通不过校验，每次开机 `VerifyError`；
- `DisplayFrameSetting.isFeatureOn` —— 丢了 `static`（`access` 从 `0x0009` 变成 `0x0001`，
  `ins_size` 从 0 变成 1），而全部 4 个调用点都是 `invoke-static` → `IncompatibleClassChangeError`。

不修的话 `com.miui.powerkeeper` 开机即崩，MIUI 的省电管理整个不可用。
修好的 APK 放在 `module/payload/app/PowerKeeper.apk`，重建流程见
[docs/powerkeeper-patch.md](docs/powerkeeper-patch.md)。

#### 让补丁真正生效要绕开三个坑

这一项是本模块里最麻烦的一处。前后踩了三个坑，**都不是"脚本写错"，而是机制问题**，
而且前两个坑都会让模块**从任何 root 视角检查都显示"已生效"**，属于最难查的那一类：

**坑 1 — APK 签名块不能丢。** 用 Python `zipfile` 重建 zip 会把 **APK Signing Block**
（v2/v3 签名块，位于最后一个 local entry 与 central directory 之间）整个丢掉。
Android 11+ 对 `targetSdk>=30` 强制要求 v2 签名，PMS 直接拒绝扫描：

```
W PackageManager: Failed to scan /system_ext/app/PowerKeeper:
    No APK Signature Scheme v2 signature in package
```

结果是 `com.miui.powerkeeper` **根本没装上**，② 等于没做。
现在 payload 由 `payload-src/apk_inplace.py` 做**等长原地补丁**：只覆盖 `classes.dex` 的
数据段 + 回填两处 CRC-32（local header +14、central directory +16），容器其余部分逐字节
不动，签名块原样保留（本机 4096 字节）。产物 **6228160 字节，与原厂完全等长**。

> 顺带一个结论：**不能改用 `pm install` 装成"系统应用更新"**。补丁改了 `classes.dex`，
> v3 签名块里的内容摘要必然失效，而重签需要平台密钥。实测：
> `INSTALL_PARSE_FAILED_NO_CERTIFICATES: ... using APK Signature Scheme v3:
> SHA-256 digest of contents did not verify`。
> 开机扫描之所以接受它，是因为包尺寸与原厂等长 + 证书未变，命中 PMS 的缓存校验路径 ——
> 这也正是"必须等长"的另一个理由。

**坑 2 — KernelSU 会把模块挂载从 App 进程里卸掉。** 这是它隐藏 root/模块的设计。
实测 post-fs-data 阶段挂的那次：`init` 视角看得到、`sha256sum` 也是补丁版，
但 `com.miui.powerkeeper`（`android.uid.system` / uid 1000）**自己的 mount namespace 里
没有这条挂载**，读到的是 ROM 原件 → 照旧 `VerifyError`。
判据不能看 `/proc/mounts`（那是 init 视角），要看 `/proc/<pid>/mountinfo`。

**坑 3 — 同一路径、同一个 init namespace，只有"晚挂"才有效。** 实测把 `umount` + `mount`
挪到 **`boot_completed` 之后**，新起的 App 进程立刻就能看到补丁；放在 `late_start`
（`boot_completed` 之前）则看不到 —— 两次的 ns（`mnt:[4026532850]`）和 mnt_id（226，
Linux 的 `ida` 会复用最小空闲 id）都相同，所以这是**时机**问题，不是"挂错了地方"。

于是 `service.sh` 的做法是：

1. `late_start` 先挂一次（best effort，万一别的 KernelSU 版本上就能生效，那一次都不用崩）；
2. `boot_completed` 之后再 `umount` + `mount` 一次（`pk_visible` 不成立时最多重试 3 次）；
3. 显式把 `com.miui.powerkeeper` 拉起来 —— 开机早期它已经崩过几次，AMS 的崩溃退避会让它
   越来越久不再自动重试（1s → 11s → 30min → 1h → 2h），所以必须主动
   `am start-service -n com.miui.powerkeeper/.PowerKeeperBackgroundService`。

**已知副作用（无害）**：`boot_completed` 之前 powerkeeper 会崩几次，开机日志里能看到几条
`am_crash` / `VerifyError`；约 1.5 分钟后由模块自动恢复并常驻。这是"补丁生效窗口"的代价，
不影响最终状态。

挂的是**父目录** `/system_ext/app/PowerKeeper` 而不是那个 APK 文件：父目录一挂，
ROM 预编译的 `oat/` 也一起被盖掉，ART 不会再用那份基于坏字节码编出来的 odex。

> 为什么用 bind mount 而不是模块的 `system/` 目录：本机的 KernelSU 是 **ReSukiSU 4.x late-load LKM**
> 形态，**不做文件级 overlay** —— 模块里的 `system_ext/...` 不会被叠到真实路径上。

### ③ 停 BPF 监视器

`/system_ext/etc/init/hyper_bpfloader.rc` 里定义了**两个 service，用同一个二进制**：

- `hyper_bpfloader` —— **开机期的 BPF 加载器**（`on load-bpf-programs` 触发，加载约 50 个程序，
  含 netd 依赖的）。**本模块不动它。**
- `dynbpfloader` —— `hyper_bpfloader --monitor-mode`，**开机后的监视器**。**本模块停掉它。**

监视器检查 MIUI 私有 BPF 程序（`MiuiMmStat` / `MiuiMmTrace` 那套）有没有 pin 住。那套 `.o`
引用的是 **6.10+ 内核符号**，而本机内核是 **6.6.82** → 89 个程序**一个都加载不了** →
它判定"系统损坏"，往 recovery 引导块写标记并 `reboot,recovery`。
实测不开容器时能忍着，**一用 DroidSpaces 容器就触发**。

**为什么不用看护进程**：`dynbpfloader` 是 init 里的 **`disabled` 服务**（不随 class 自动起），
唯一的启动点是 `on property:sys.boot_completed=1 && property:ro.debuggable=1` 这一行。
这个属性触发器**每次开机只触发一次**，所以开机后 `ctl.stop` **一次即永久生效**。
实测停掉后连续观察 1 小时以上，`stopped again` 出现 **0 次**。

原理与三条走不通的路（覆盖 `.rc` / 改 `ro.debuggable` / `bootlist_disable` 属性）见
[docs/bpfmon-stop.md](docs/bpfmon-stop.md)。

### ④ 停死电话栈

本机 `ro.baseband=apq` 是纯应用处理器、**没有集成 modem**，框架没有 `FEATURE_TELEPHONY`，
而移植包搬来了声明成 `persistent` 的小米 / QTI 电话栈 →
`getSystemService` 返回 `null` → `NullPointerException` **每秒崩数百次**，白烧 zygote / `system_server`。

停用这三个包（本机实测**一个都不存在**，脚本会识别并跳过）：

```
com.qti.phone
com.qualcomm.qcrilmsgtunnel
com.qualcomm.qti.telephonyservice
```

**有 modem 的变体上不会误伤**：脚本先检查 `ro.radio.noril`，不是 `true` 就整个跳过。

### ⑭ 开发者选项

`com.android.settings` 以 `system_app` 域运行时，打开开发者选项会去写
`logd.logpersistd` / `persist.logd.logpersistd.buffer` 两个属性，而移植包的策略**没有**给
`system_app` 授予 `logpersistd_logging_prop` 的 `property_service set` → 抛
`RuntimeException` → Activity 崩溃。补两条最小权限即可。根因与防自欺验证见
[docs/devopts-selinux-fix.md](docs/devopts-selinux-fix.md)。

**这一项没有开关** —— 它是崩溃修复，不是可选功能。

---

## 二、为什么可以没有守护进程

三个"开机做一次"的项，各自的一次性成立理由不同：

| 项 | 为什么一次就够 |
|---|---|
| ② | bind mount 的挂载点**跨本次开机一直有效**，不会自己掉 |
| ③ | 服务的唯一启动点是**开机属性触发器**，只触发一次（实测） |
| ④ | 停用状态写在 `packages.xml`，**跨重启保持**；每次开机只是复查 |
| ⑭ | 策略注入内存，重启后由 `post-fs-data` 与开机动作自动重放 |

所以整个模块**运行期没有任何常驻进程**，也没有 `supervisor` / `monitor` / `penring` /
`brushwatch` / `stoprompen` 这类看护脚本。

---

## 三、安装

1. 把 `out/tb378fc_hyperos_fix_lite-v1.0.zip` 丢给 KernelSU 管理器安装
   （或 `magisk --install-module`）。
2. 重启。
3. 在 KernelSU 管理器的模块页打开 **WebUI**，可以逐项开关并看实时状态。

---

## 四、配置与开关

### WebUI（推荐）

KernelSU 管理器 → 模块页 → 本模块 → 打开 WebUI。三行开关 + ⑭ 的「重新应用（免重启）」按钮，
每行都显示实际状态（不是"配置里写了什么"，是**现在真的生效了没有**）。

### 配置文件

`/data/adb/modules/tb378fc_hyperos_fix_lite/config`

```sh
FIX_POWERKEEPER=1   # ②
FIX_BPFMON=1        # ③
FIX_TELEPHONY=1     # ④
# ⑭ 没有开关，永远生效
```

布尔值：`1`/`true`/`yes`/`on` = 开，其它 = 关。改完**重启**生效（没有守护进程需要重启）。

> 这个文件是**按行解析**的（不是 `source`），所以值里可以安全地出现空格、引号、`&`、`|`
> 这类字符 —— 不会被当成 shell 代码执行。

### 标记文件（优先级最高）

在模块目录下创建空文件即可**强制关闭**对应项，优先级高于 `config`：

| 标记文件 | 关掉 |
|---|---|
| `disable` | 整个模块的开机动作 |
| `disable-powerkeeper` | ② |
| `disable-bpfmon` | ③ |
| `disable-telephony` | ④ |

### 子命令

```sh
sh /data/adb/modules/tb378fc_hyperos_fix_lite/service.sh --status    # 人读的状态摘要
sh .../service.sh --json                                            # 机器读（WebUI 用）
sh .../service.sh --sepolicy                                        # 免重启重应用 ⑭
sh .../service.sh --set FIX_BPFMON 0                                # 改配置（按行重写，逐字写入）
```

---

## 五、与 Full 分支的关系

| | **Lite**（本分支） | **Full** |
|---|---|---|
| 模块 id | `tb378fc_hyperos_fix_lite` | `tb378fc_hyperos_fix` |
| 系统修复 ②③④⑭ | ✅ | ✅ |
| 手写笔 / 注视感知等（需 App + LSPosed） | ❌ | ✅ |
| 常驻守护进程 | **无** | supervisor / monitor / penring / brushwatch |
| 安装 APK | **不装** | 打开相关开关时自动装 `TbFix.apk` |
| 构建依赖 | 只要 bash + python3（无 Android SDK/NDK） | 需要 Android SDK / NDK |

两个模块 **id 不同、可以同时安装**，但**别同时开**：② 会争同一个 PowerKeeper 挂载点，
③ 会各自去停同一个 init 服务。**只开其中一个。**

---

## 六、验收与排障

仓库里带了一个**设备端验收脚本**，逐项断言四个修复的最终状态：

```bash
adb push tools/acceptance.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/acceptance.sh'   # 结尾打印「全部通过」或「有 N 项失败」
```

它刻意做了两件事，都是踩过坑之后加的：② 的判据是 **powerkeeper 自己的
mount namespace**（`/proc/<pid>/mountinfo`）而不是 `/proc/mounts`；
崩溃断言只统计**模块修好之后**的窗口（开机早期那几条是已知无害的）。

手工排查用的命令：

```bash
M=/data/adb/modules/tb378fc_hyperos_fix_lite

# 一眼看全部状态（等于管理器「执行」按钮的内容）
adb shell su -c "sh $M/service.sh --status"

# ② 挂上了没有 / powerkeeper 活没活 / 它自己能不能看到补丁
adb shell su -c "grep PowerKeeper /proc/1/mountinfo"      # init 视角
adb shell su -c "pidof com.miui.powerkeeper"
#   ↑ 这才是关键判据：App 自己的 namespace 里有没有这条挂载。
#     （只看 /proc/mounts 会误判 —— KernelSU 会把模块挂载从 App 进程里卸掉）
adb shell su -c 'p=$(pidof com.miui.powerkeeper); grep PowerKeeper /proc/$p/mountinfo'

# ③ 监视器停没停（期望 stopped；ps 那行期望为空）
adb shell su -c "getprop init.svc.dynbpfloader"
adb shell su -c "ps -A -o ARGS | grep [h]yper_bpfloader"

# ④ 三个电话包的状态
adb shell su -c "pm list packages -d | grep -E 'qti.phone|qcrilmsgtunnel|telephonyservice'"

# ⑭ 策略应用结果
adb shell su -c "grep 'sepolicy apply' $M/lite.log | tail"

# 本模块的日志
adb shell su -c "tail -20 $M/lite.log"

# 确认没有任何常驻进程（期望只有上面那条 grep 自己）
adb shell su -c "ps -A -o ARGS | grep -E 'supervise|brushwatch|penring|stoprompen'"
```

**常见问题**

- **`lite.log` 里一条日志都没有** → 模块脚本没跑起来。先确认模块在 KernelSU 里是启用状态，
  再确认 `post-fs-data.sh` / `service.sh` 有可执行位（`ls -l $M/*.sh`）。
  KernelSU 的安装器**没有** Magisk 的 `set_perm`，权限位就是包里带的那个 ——
  所以 `build.sh` 打包前会显式 `chmod 755 *.sh`，并且 `tools/verify_pack.py` 会拦下来。
- **② 日志说 `bind mount 失败`** → 看目标目录是否存在、payload 是否完整。
- **② 日志说「已挂载」但 powerkeeper 还是 `VerifyError`** → 挂载没落到 App 的 namespace 里。
  用上面那条 `grep /proc/$p/mountinfo` 确认。已知两种成因：
  ① 挂载发生在 `boot_completed` 之前（`late_start` 那次就是这样，属预期，等后面的重挂）；
  ② 挂载落到了别的 mount namespace（脚本 ns ≠ init ns，日志里会多一行 `脚本 ns(...) ≠ init ns(...)`，
  此时 `service.sh` 会自动用 `nsenter -t 1 -m` 切过去）。
- **② powerkeeper 一直在崩、AMS 也不再自动拉** → AMS 的崩溃退避会退到 1h/2h。
  手工补一次：`adb shell su -c 'am start-service -n com.miui.powerkeeper/.PowerKeeperBackgroundService'`
  （前提是挂载已经对 App 可见）。
- **③ 日志说监视器仍在运行** → 看 `getprop init.svc.dynbpfloader`。如果它是 `running` 且
  `ctl.stop` 三次都没停掉，说明这个 ROM 上该服务不是 `disabled` 的 —— 那就得回到
  [docs/bpfmon-stop.md](docs/bpfmon-stop.md) 重新评估。
- **⑭ 找不到 ksud** → 日志里会写。规则仍由 KernelSU 声明式加载，但那条路实测不可靠，
  建议确认 `/data/adb/ksud` 是否存在。

---

## 七、目录结构

```
module/                      ← 打包根（zip 根目录即模块根目录）
├── module.prop              id / name / version / description
├── config                   运行配置（3 个开关）
├── sepolicy.rule            ⑭ 的两条规则
├── customize.sh             安装期：权限位 + 升级时保住用户的 config
├── post-fs-data.sh          ② bind mount（供 PMS 扫描）+ ⑭ 显式应用策略
├── service.sh               ② boot_completed 后重挂并拉起进程 + ③④⑭ + --status/--json/--set/--sepolicy
├── uninstall.sh             卸载说明（不做恢复动作）
├── payload/app/PowerKeeper.apk  ② 的 payload（已入库；放在子目录里是为了能挂父目录）
└── webroot/index.html       精简 WebUI

payload-src/                 ← ② 的重建流程（原厂 APK 不入库）
├── patch_powerkeeper.py     坏点 a：return v0 → return-void（只产出 classes-patched.dex）
├── fix_static.py            坏点 b：移入 direct_methods + ACC_STATIC + ins_size 1→0
├── apk_inplace.py           等长原地替换条目 —— 保住 APK Signing Block 的关键
└── repack_payload.py        用 apk_inplace 把新 dex 塞回去（不做 zip 重建）

tools/
├── check-helpers.py         未定义函数检查（"调用了但没定义"会被 sh 静默忽略）
├── webui-selftest.js        WebUI 渲染与交互自检（极简 DOM 桩）
├── pack_zip.py              没装 `zip` 命令时的等价打包兜底（Windows）
└── verify_pack.py           产物校验：行尾 / 残留 / 权限位 / 版本 / payload 完整性

docs/                        原理与排障文档，见「十、文档」
```

**注意模块里没有 `system/` 目录** —— 本机的 KernelSU 不做文件级 overlay，
模块目录里的 `system/` 不会被叠上去，所以 ② 是靠脚本里显式 `mount -o bind` 做的。
别往模块里放 `system/`，那只会让人误以为生效了。

---

## 八、构建

```bash
./build.sh              # 自检 + 打包 + 校验产物
./build.sh --payload    # 额外从 payload-src/PowerKeeper-stock.apk 重建 ② 的 payload
./build.sh --clean      # 清 out/ 与 payload-src 中间产物
```

**不需要 Android SDK / NDK** —— 模块里没有 App、没有二进制，几秒出包。

产物：`out/tb378fc_hyperos_fix_lite-v1.0.zip`（zip 根目录即模块根目录）。

构建期会跑四道自检，这几类问题**在开发机上完全看不出来**，但装到设备上就是"模块静默不工作"：

1. `sh -n` —— 语法；
2. `tools/check-helpers.py` —— **调用了但没定义**的函数（sh 只会打一行 `not found` 继续跑）；
3. `tools/webui-selftest.js` —— WebUI 的渲染与交互（"拨开关必须只触发一次 `--set`"这类约束）；
4. `tools/verify_pack.py` —— 产物校验：**行尾**（mksh 不能执行 CRLF 脚本）、
   运行期产物有没有混进包、Full 分支残留、可执行位、版本一致性、payload 完整性。

### 两个容易踩的坑

- **CRLF**：本仓库在 Windows 上 checkout 是 CRLF（`core.autocrlf=true`，没有 `.gitattributes`），
  而 Android 的 sh（mksh）**不能执行 CRLF 脚本**。两条打包路径（`zip` / `pack_zip.py`）
  都在写进包之前把文本文件的行尾归一化成 LF，`verify_pack.py` 会兜底复查。
- **权限位**：Windows 上 `stat` 读不出执行位（NTFS 的 `st_mode` 一律 `0o666`，
  而 `os.access(X_OK)` 对任何存在的文件都返回 True），所以 `pack_zip.py` 从 **git index**
  读模式，读不到才按扩展名猜。

---

## 九、自动发布（GitHub Actions）

`.github/workflows/release.yml`。推一个 `v*` 的 tag 就自动：自检 → 打包 → 建 Release 并把 zip 挂上去。

```bash
# 版本号改完、提交推上去之后：
git tag v1.0 && git push origin v1.0
```

也可以手动跑：Actions 页面 →「构建并发布模块（Lite）」→ Run workflow
（tag 留空就用 `module.prop` 里的 `version`）。

工作流会**校验 tag 和 `module/module.prop` 里的 `version` 是否一致**，不一致直接失败 ——
否则会出现「tag 是 v1.0、包里却是 v0.9」这种发出去就不好回收的错位。

### 这个仓库是 fork 的话，两点必须注意

1. **Actions 可能没开**：到仓库 **Actions** 页看有没有「Workflows aren't being run on this
   forked repository」的横幅，有就点 **I understand my workflows, go ahead and enable them**。
2. **`GITHUB_TOKEN` 可能没有写权限**：GitHub 文档写得很直白 —— 派生仓库「通常无法授予写入权限」，
   所以建 Release 那一步可能报 403。两种解法任选其一：
   - 仓库 **Settings → Actions → General → Workflow permissions** 选
     **Read and write permissions**（最省事）；
   - 或建一个 PAT（classic 勾 `repo`；fine-grained 给本仓库 `Contents: Read and write`），
     存成仓库 secret **`RELEASE_TOKEN`**。workflow 里写的是
     `secrets.RELEASE_TOKEN || github.token`，配了就优先用它。

排障：Actions 里点开那次 run 看哪一步红；命令行用 `gh run list` / `gh run view <id> --log-failed`。
另外记住 **workflow 文件必须先在默认分支上**，`workflow_dispatch` 才会出现在 Actions 页面；
tag 触发用的则是「该 tag 指向的 commit」里的 workflow 文件 —— 所以顺序是：先推分支，再推 tag。

---

## 十、文档

- [docs/powerkeeper-patch.md](docs/powerkeeper-patch.md) — ② 两处字节码坏点的修法与重建流程
- [docs/bpfmon-stop.md](docs/bpfmon-stop.md) — ③ 监视器为什么会重启设备、三条走不通的路、零守护方案
- [docs/devopts-selinux-fix.md](docs/devopts-selinux-fix.md) — ⑭ 根因、两条通道、防自欺验证、7 条坑
