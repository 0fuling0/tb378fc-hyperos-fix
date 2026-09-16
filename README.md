# tb378fc-hyperos-fix

联想小新 Pad Pro GT 13（**TB378FC**）刷 **HyperOS 移植包**（`OS3.0.307.0.WPYCNXM`）后的适配修复：
手写笔（联想 Tab Pen Pro 2）、手写笔电量胶囊、注视感知（AON）、以及移植包自身的几个坑。

> 个人自用项目，只对上述机型 + 该移植包验证过。刷机/root 有风险，自行评估。

---

## 一、修了什么（①–⑭）

| 分类 | # | 功能 | 主要实现方 | config 键（默认） |
|---|---|---|---|---|
| **系统修复** | ② | **PowerKeeper 修复**：修补移植包改坏的两处字节码，恢复 MIUI 省电管理 | 模块 `post-fs-data`（bind mount 修好的 APK） | `FIX_POWERKEEPER=1` |
| | ③ | **停 BPF 监视器**：避免 `hyper_bpfloader` 判定"系统损坏"写 recovery 引导块 | 模块 | `FIX_BPFMON=1` |
| | ④ | **停死电话栈**：本机无 modem，停掉每秒崩数百次的三件套 | 模块 | `FIX_TELEPHONY=1` |
| | ⑭ | **开发者选项**：补 `system_app → logpersistd_logging_prop` 两条最小权限，否则 Enforcing 下打开必闪退 | 模块（`sepolicy.rule` + 开机 `ksud sepolicy apply`） | — （崩溃修复，无开关） |
| **手写笔连接** | ① | **手写笔休眠唤醒**：磁吸取下时经 BLE 发 `{5,5}` 叫醒睡死的笔 | 模块（轮询 `wls_tx/attached`）→ App（发 BLE） | `PEN_WAKE=0` |
| | ⑤ | **吸附电量胶囊**：读反向无线充电线圈看到的笔电量，弹 HyperOS 原生胶囊（再用 GATT 真值校正） | 模块 + App | `CAPSULE=0` |
| | ⑨ | **笔休眠档**：吸在平板上且充满 → 停掉一切主动动作、断开缓存 BLE 连接 | 模块 + App | `PEN_REST=0` |
| | ⑬ | **屏幕亮/灭告诉笔**：亮发 `{5,2}`、灭发 `{5,1}`（ZUX `buildScreenOnOffCmd`） | 模块（读 `debug.tracing.screen_state`）+ App | `SCREEN_CMD=0` |
| **手势与书写** | ⑥ | **手势桥**：联想笔的捏/双击/上滑/下滑/笔尾桥成"小米触控膜笔"（type-8 虚拟笔 + 自定义 kl） | `bin/penring`（模块） | `GESTURE=1` |
| | ⑦ | **笔刷触感**：笔记/小米创作切笔刷 → 给笔发对应 CON 波形；只在画布前台时开，离开就停 | 模块看护 + App | `BRUSH=0` |
| | ⑫ | **设置→笔 即时下发**：设置里改双击/轻捏/力度，几十毫秒写进笔 | 钩子（设置进程）+ App | `SETTINGS_SYNC=0` |
| **注视感知** | ⑧ | **注视感知（AON）**：让 `AttentionManagerService` 真正拿到"有没有人在看"（真实前摄 + 人脸检测） | 模块（HAL/权限/库）+ 钩子（框架两道门） | `AON=0` |
| — | — | **KernelSU WebUI**：上面这些开关（含每类总开关）+ 每种笔刷的波形选择 | 模块（`webroot/`） | — |

细节都在 `docs/` 里（尤其 AON 的完整排查过程和踩过的坑）。
⑭ 是本仓库 v3.6 并入的（之前是个独立模块），完整说明见 `docs/devopts-selinux-fix.md`。

## 二、功能开关与分组（重要）

**每一项功能都是一个独立的开关**，都能在 KernelSU 管理器的 WebUI 里改（写进 `module/config`），
按"需不需要那个 App"分成两组，**默认值也按这两组区分**：

| 组 | 内容 | 默认 | 说明 |
|---|---|---|---|
| **A 纯模块功能** | ②③④⑥ | **全开** | 只靠 root + 内核/属性/包管理，不需要 App |
| **B 需要 App 的功能** | ①⑤⑦⑧⑨⑫⑬ | **全关** | 依赖 `dev.tb378fc.fix`（它同时是 LSPosed 钩子） |

WebUI 里按功能域分成四类（**系统修复 / 手写笔连接 / 手势与书写 / 注视感知**），
**每类头部有一个总开关**，一键把该类下所有项设为开或关（状态混合时显示为"-"，点一下 = 全部打开）。
总开关是界面上的批量操作，会**合并成一次** `service.sh --set` 调用，只触发一次守护重启。

### 关于那个 APK（`dev.tb378fc.fix`）

它一身两职：**既是笔的 BLE 代理**（①⑤⑦⑨⑬ 的"动手"那半边），**又同时是 LSPosed 钩子**
（⑧ AON、⑧c 设置页可见性、⑦ 画布状态、⑫ 即时下发）。

- **默认不安装它。** 开机时模块按 `need_app()` 判定：B 组七项**全为 0 就不装**，
  也**不会去碰你已经装好的版本**。
- **只有你手动打开 B 组里的任意一项**，才会自动安装 `bin/TbFix.apk`。
- **B 组全部关掉后会自动卸载它**（不留残包；但 LSPosed 作用域列表里会留一条失效条目，需要你手动清）。
- 想手动对齐一次：`sh service.sh --apksync`；只想查状态：`sh service.sh --appstat`。

### 与旧标记文件的关系

每一项还都能用模块目录下的 `disable-*` 标记文件强制关掉，**标记的优先级高于 config**。
WebUI 顶部会把当前存在的标记文件列出来。已支持的标记：
`disable`、`disable-powerkeeper`、`disable-bpfmon`、`disable-telephony`、`disable-capsule`、
`disable-gesture`、`disable-brush`、`disable-aon`、`disable-aonlib`、`disable-rest`、
`disable-screen`、`disable-rompen`。

## 三、三方分工

```
KernelSU 模块(module/)             App(dev.tb378fc.fix)                LSPosed 钩子(同一个 APK)
  root：挂载/权限/定时/状态机    ┃   唯一有 BLE 栈的一方，负责"动手"   ┃   只能改框架/别的 App 内部状态
  ────────────────────────────  ┃  ────────────────────────────────  ┃  ──────────────────────────────
  post-fs-data：② PowerKeeper    ┃  {5,5} 唤醒 / {8,6,mask} / {8,5,lvl}┃  android(system_server)：⑧ AON 两道门
  ⑧ cust_features / ⑧b 补库      ┃  {5,2}/{5,1} 屏幕状态               ┃  com.android.settings +
  service.sh：①③④⑤⑥⑦⑧⑨⑬ 看护  ┃  振动波形（CON/IMP）                ┃  com.miui.securitycore：⑧c 设置页
  penring：手势→type-8 虚拟笔     ┃  GATT 读真电量（0x180F/0x2A19）    ┃  com.miui.notes / com.miui.creation：
  sepolicy.rule：AON HAL 三条 + ⑭ 两条    ┃  收 REST 断连 / 收 CFG 即时下发     ┃    画布焦点 → files/penstate
```

模块 → App 只用**显式广播**；App → 模块只用**状态文件**（`files/penstate`，模块 inotify 监听）。

> 注意：⑥ 手势桥本身只靠模块（penring 注入虚拟笔），但**笔要上报手势，得先有人用 BLE 把笔端
> 触控膜功能位 `{8,6,mask}` 写进去** —— 那一步只有 App 能做。所以 ⑥ 虽然不需要 App 常驻，
> 但至少要被 B 组开过一次（笔会记住这个位，直到它重启/睡死）。

## 四、安装

1. 刷模块：把 `out/tb378fc_hyperos_fix-*.zip` 交给 KernelSU 管理器（或 `ksud module install`），重启。
2. **开功能**：打开 WebUI，按需打开 B 组的功能。**打开任一项后模块才会自动安装那个 App**
   （`dev.tb378fc.fix`）—— 默认不装。
3. **LSPosed**（只在你要用 AON / 画布状态 / 即时下发时才需要）：启用模块「**TB378FC 修复**」，
   作用域勾 **系统框架 / 设置 / com.miui.securitycore / 笔记 / 小米创作**，
   然后**完整重启**（不是只重启 zygote）。
4. WebUI：KernelSU 管理器 → 模块 → TB378FC → 「打开 WebUI」（若看不到，下拉刷新一次管理器）。

## 五、配置

- **WebUI**（推荐）：四类功能域的逐项开关 + 每类总开关、⑥ 的手势映射、⑦ 的每种笔刷波形、
  ⑤/⑬ 的子选项、以及 App/APK 的安装状态与手动对齐按钮。
  改动写入 `module/config`，并触发**一次**守护重启（约 20 秒）生效。
- 直接改 `module/config`（KernelSU 模块目录下同名文件）也可以；键的说明都写在文件里。
- 命令行辅助：`sh service.sh --json`（读生效值，布尔项已经过标记文件过滤）、
  `--set KEY VALUE [KEY VALUE ...]`（写一项或多项并重启一次）、
  `--appstat` / `--apksync`（查/对齐 APK 状态）、
  `--sepolicy`（重应用 ⑭ 的 SELinux 规则）、`--brushsend <波形id>`、
  `bin/penring --key <原始键>`（排障注入）。

## 六、验收与排障

```sh
M=/data/adb/modules/tb378fc_hyperos_fix

# 模块在不在跑（正常：supervise/monitor/brushwatch 各 1，penring + penring --watch）
ps -A -o PID,ARGS | grep -E "service\.sh --|[p]enring"

# 一眼看全部开关的生效状态 + APK 状态 + 最近日志（等于管理器「执行」按钮的内容）
sh $M/action.sh

# 手势桥：虚拟笔 + 自定义 kl + 注入日志
grep -c 'Xiaomi Pen' /proc/bus/input/devices          # 1
ls /data/system/devices/keylayout/Vendor_0022_Product_5081.kl
tail -f $M/wake.log.ring                              # 捏/双击/上滑/下滑/笔尾 各映射成什么键

# 笔刷触感
tail -f $M/brush.log                                  # send? wave=NN why=... / stop (canvas lost)

# 注视感知（需要 LSPosed 那半边在）
service check attention                               # Service attention: found
dumpsys attention | head -12                          # AttentionServicePackageName=com.xiaomi.aon
logcat -d | grep Y700AonShim | tail                   # open front camera id=1 / callback present=1
logcat -d | grep AttentionDetector | tail             # onSuccess: 1
dmesg | grep -c 'avc:.*hal_miface'                    # 0

# 钩子在不在（应有 hooked com.miui.notes / ⑧c / ⑫ 之类）
logcat -d | grep TbFixHook | tail
```

日志都在模块目录：`wake.log`（主日志）、`wake.log.ring`（手势桥）、`brush.log`（笔刷/波形）、
`service.sh --json` 可看当前生效配置。

## 七、已知取舍 / 没做的

- **笔尾当橡皮**：小米笔记/小米创作里**没有"橡皮端"这条原生路径**（小米触控膜笔本身没有笔尾橡皮，
  只有侧键/快捷键）。试过 ERASER tool type、伪造 `BUTTON_STYLUS_PRIMARY`、复用 MIUI 的"切笔/橡皮"
  快捷键动作，都被否掉了（细节与实测数据见 `docs/stylus-gesture-bridge.md` §6）。目前只在**触感**上
  让笔尾切到橡皮波形（35）。
- **遥控 / 旋转笔刷**：不支持（联想笔没有陀螺仪，6DOF 通道回的是固定描述符）。
- **AON**：依赖移植包里那份 `mifaced`（含联想 Y700 的 shim）+ 三条 SELinux 规则 + `/odm/lib64` 补
  `libcamera2ndk.so`；`/odm` 与 `/` 是只读 erofs，所以都走 tmpfs + bind（开机自动，卸载即恢复）。
- **App 里的 `PenBle.DEFAULT_MAC`**：是找不到笔时的兜底 MAC，请改成**你自己那支笔**的地址
  （或留空让它走扫描）。
- **默认不装 App 的代价**：B 组全关时，①⑤⑦⑨⑬ 这半边没有 App 就没有 BLE 可发 —— 这正是"默认关"
  的本意。⑥ 手势桥在**全新安装**且从未开过 B 组时，笔端可能还没收到过 `{8,6,mask}`，
  表现为"手势没反应"；开一次 B 组的任一项让它写进去即可（笔会记住）。
- 本仓库含移植包里的第三方材料（PowerKeeper 字节码补丁 payload、图标等），仅供个人研究，权利归原厂。

## 八、目录结构

```
tb378fc-hyperos-fix/
├── build.sh                  一键构建（App + penring + 打包模块 zip）
├── app/
│   ├── TbFix/                App + LSPosed 钩子（同时是笔的 BLE 代理）
│   │   ├── src/dev/tb378fc/fix/{PenBle,WakeReceiver,Capsule,...}.java
│   │   └── src/dev/tb378fc/fix/hook/TbFixHook.java
│   └── PenRing/penring.c     手势桥守护（静态 aarch64）
├── module/                   KernelSU 模块（zip 根目录就是这里）
│   ├── post-fs-data.sh       ② PowerKeeper / ⑧ cust_features / ⑧b 补 libcamera2ndk / ⑭ 打一次 sepolicy
│   ├── service.sh            看护主循环（①③④⑤⑥⑦⑧⑨⑬ + ⑭ --sepolicy + WebUI 用的 --json/--set/--appstat/--apksync）
│   ├── sepolicy.rule         AON HAL（hal_miface_default）三条 + ⑭ 开发者选项两条
│   ├── action.sh             管理器「执行」按钮：按四类功能域汇报开关状态 + APK 状态
│   ├── config                运行配置（分组结构，键的说明都在里面）
│   ├── webroot/index.html    KernelSU WebUI（MUI 风格，无外部依赖）
│   ├── bin/{penring,TbFix.apk}
│   └── payload/PowerKeeper.apk
├── tools/                    peninject / patch_powerkeeper / check-helpers / webui-selftest
└── docs/                     AON、胶囊、手势桥、ZUX 协议、开发者选项 SELinux 等完整文档
```

## 九、构建

```bash
./build.sh            # App + penring + 打包（用仓库里现成的 payload）
./build.sh --payload  # 额外从 payload-src/PowerKeeper-stock.apk 重建 PowerKeeper payload
./build.sh --pack     # 只自检 + 打包，不编 apk/penring（CI 走这条，不需要 SDK/NDK）
```

需要 JDK 17、Android SDK（build-tools 37 + platform android-36）、`python3`、`zip`；
SDK 路径默认 `/opt/android-sdk`，可用 `ANDROID_SDK_ROOT=` / `BT_DIR=` / `ANDROID_PLATFORM=` 覆盖。
构建期会跑自检：

- `sh -n` 三个脚本
- `tools/check-helpers.py`（检查"调用了但没定义的函数"——脚本里这类问题会静默）
- `tools/webui-selftest.js`（用极简 DOM 桩把 WebUI 真跑一遍；装了 node 才跑）

单独跑 WebUI 自检：`node tools/webui-selftest.js`。它断言了四个场景：默认状态、
全开+标记文件、单项开关、**分类总开关必须只触发一次 `--set`**。

## 十、自动发布（GitHub Actions）

`.github/workflows/release.yml`。推一个 `v*` 的 tag 就自动：自检 → 打包 → 建 Release 并把 zip 挂上去。

```bash
# 版本号改完、提交推上去之后：
git tag v3.8 && git push origin v3.8
```

也可以手动跑：Actions 页面 →「构建并发布模块」→ Run workflow（tag 留空就用 `module.prop` 里的 `version`）。

**为什么用 `--pack` 而不是完整构建**：`module/bin/TbFix.apk` 和 `module/bin/penring` 已经入库，
所以 CI 不需要 Android SDK / NDK，几秒钟出包。要改 App 或 penring 的代码，仍然得本地 `./build.sh` 出包再提交。

工作流会**校验 tag 和 `module/module.prop` 里的 `version` 是否一致**，不一致直接失败 ——
否则会出现「tag 是 v3.6、包里却是 v3.5」这种发出去就不好回收的错位。

### 这个仓库是 fork，两点必须注意

1. **Actions 可能没开**：fork 出来的仓库，Actions 不一定跑。到仓库 **Actions** 页看有没有
   「Workflows aren't being run on this forked repository」的横幅，有就点
   **I understand my workflows, go ahead and enable them**。
2. **`GITHUB_TOKEN` 可能没有写权限**：GitHub 文档写得很直白 ——「您可以使用 `permissions` 密钥
   为派生仓库添加和删除读取权限，但**通常您无法授予写入权限**」。所以建 Release 那一步可能报 403。
   两种解法任选其一：
   - 仓库 **Settings → Actions → General → Workflow permissions** 选
     **Read and write permissions**（最省事）；
   - 或建一个 PAT（classic 勾 `repo`；fine-grained 给本仓库 `Contents: Read and write`），
     存成仓库 secret **`RELEASE_TOKEN`**。workflow 里写的是
     `secrets.RELEASE_TOKEN || github.token`，配了就优先用它。

排障：Actions 里点开那次 run 看哪一步红；命令行用 `gh run list` /
`gh run view <id> --log-failed`。
另外记住 **workflow 文件必须先在默认分支上**，`workflow_dispatch` 才会出现在 Actions 页面；
tag 触发用的则是「该 tag 指向的 commit」里的 workflow 文件 —— 所以顺序是：先推 master，再推 tag。

## 十一、文档

- `docs/stylus-gesture-bridge.md` — 手势桥：手势表、type-8/kl、映射、看护的启动/自愈、笔尾橡皮的结论
- `docs/aon-attention.md` — 注视感知：四个卡点、SELinux 三条、验收命令、踩过的坑
- `docs/native-stylus-capsule.md` — 原生电量胶囊的触发链与参数
- `docs/zuxos-pen-protocol.md` — ZUX 笔协议帧表（`{5,5}`/`{5,3}`/`{5,2}`/`{5,1}`/`{8,6,..}`…）
- `docs/devopts-selinux-fix.md` — ⑭ 开发者选项 SELinux 修复：根因、两条通道、防自欺验证、7 条坑

## 十二、⑭ 开发者选项（SELinux）

移植包在 **SELinux Enforcing** 下「设置 → 开发者选项」**必现闪退**（`setenforce 0` 就正常）。
根因是 `system_app` 域（`com.android.settings`，uid 1000）缺
`logpersistd_logging_prop` 上的 `property_service set` 与 `file read`，
`onResume` 里写 `logd.logpersistd` / `persist.logd.logpersistd.buffer` 抛异常没被接住。
（`mLogpersistCleared` 是在失败的 `set()` **之后**才赋值的 → 标志位永远锁不上 → 必现，不是偶发。）

只补两条最小权限，写在 `module/sepolicy.rule` 里：

```
allow system_app logpersistd_logging_prop file { getattr open read map }
allow system_app logpersistd_logging_prop property_service set
```

- **开机应用**：`post-fs-data.sh` 与 `service.sh` 的 setup 各用 `ksud sepolicy apply` 显式应用一次
  （实测本机 ReSukiSU late-load LKM 上**纯声明式加载不可靠**，会静默不生效）
- **免重启手动重应用**：`sh /data/adb/modules/tb378fc_hyperos_fix/service.sh --sepolicy`
- **状态**：管理器「执行」按钮（`action.sh`）里有一行 ⑭，判据是"开机以来有没有 logpersistd 拒绝"
- **无 disable 标记**：这是崩溃修复，不是可选功能
- **完整说明**：`docs/devopts-selinux-fix.md`
