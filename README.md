# tb378fc-hyperos-fix

联想小新 Pad Pro GT 13（**TB378FC**）刷 **HyperOS 移植包**（`OS3.0.307.0.WPYCNXM`）后的适配修复：
手写笔（联想 Tab Pen Pro 2）、手写笔电量胶囊、注视感知（AON）、以及移植包自身的几个坑。

> 个人自用项目，只对上述机型 + 该移植包验证过。刷机/root 有风险，自行评估。

---

## 一、修了什么（①–⑬）

| # | 功能 | 主要实现方 | 开关 |
|---|---|---|---|
| ① | **手写笔休眠唤醒**：磁吸取下时经 BLE 发 `{5,5}` 叫醒睡死的笔 | 模块（轮询 `wls_tx/attached`）→ App（发 BLE） | `disable` |
| ② | **PowerKeeper 修复**：修补移植包改坏的两处字节码，恢复 MIUI 省电管理 | 模块 `post-fs-data`（bind mount 修好的 APK） | `disable-powerkeeper` |
| ③ | **停 BPF 监视器**：避免 `hyper_bpfloader` 判定"系统损坏"写 recovery 引导块 | 模块 | `disable-bpfmon` |
| ④ | **停死电话栈**：本机无 modem，停掉每秒崩数百次的三件套 | 模块 | `disable-telephony` |
| ⑤ | **吸附电量胶囊**：读反向无线充电线圈看到的笔电量，弹 HyperOS 原生胶囊（再用 GATT 真值校正） | 模块 + App | `CAPSULE=0` / `disable-capsule` |
| ⑥ | **手势桥**：联想笔的捏/双击/上滑/下滑/笔尾桥成"小米触控膜笔"（type-8 虚拟笔 + 自定义 kl） | `bin/penring`（模块） | `GESTURE=0` / `disable-gesture` |
| ⑦ | **笔刷触感**：笔记/小米创作切笔刷 → 给笔发对应 CON 波形；只在画布前台时开，离开就停 | 模块看护 + App | `BRUSH=0` / `disable-brush` |
| ⑧ | **注视感知（AON）**：让 `AttentionManagerService` 真正拿到"有没有人在看"（真实前摄 + 人脸检测） | 模块（HAL/权限/库）+ 钩子（框架两道门） | `disable-aon` / `disable-aonlib` |
| ⑨ | **笔休眠档**：吸在平板上且充满 → 停掉一切主动动作、断开缓存 BLE 连接 | 模块 + App | `PEN_REST=0` |
| ⑫ | **设置→笔 即时下发**：设置里改双击/轻捏/力度，几十毫秒写进笔 | 钩子（设置进程）+ App | `SETTINGS_SYNC=0` |
| ⑬ | **屏幕亮/灭告诉笔**：亮发 `{5,2}`、灭发 `{5,1}`（ZUX `buildScreenOnOffCmd`） | 模块（读 `debug.tracing.screen_state`）+ App | `SCREEN_CMD=0` |
| — | **KernelSU WebUI**：上面这些开关 + 每种笔刷的波形选择 | 模块（`webroot/`） | — |

细节都在 `docs/` 里（尤其 AON 的完整排查过程和踩过的坑）。

## 二、三方分工（重要）

```
KernelSU 模块(module/)             App(dev.tb378fc.fix)                LSPosed 钩子(同一个 APK)
  root：挂载/权限/定时/状态机    ┃   唯一有 BLE 栈的一方，负责"动手"   ┃   只能改框架/别的 App 内部状态
  ────────────────────────────  ┃  ────────────────────────────────  ┃  ──────────────────────────────
  post-fs-data：② PowerKeeper    ┃  {5,5} 唤醒 / {8,6,mask} / {8,5,lvl}┃  android(system_server)：⑧ AON 两道门
  ⑧ cust_features / ⑧b 补库      ┃  {5,2}/{5,1} 屏幕状态               ┃  com.android.settings +
  service.sh：①③④⑤⑥⑦⑧⑨⑬ 看护  ┃  振动波形（CON/IMP）                ┃  com.miui.securitycore：⑧c 设置页
  penring：手势→type-8 虚拟笔     ┃  GATT 读真电量（0x180F/0x2A19）    ┃  com.miui.notes / com.miui.creation：
  sepolicy.rule：AON HAL 三条    ┃  收 REST 断连 / 收 CFG 即时下发     ┃    画布焦点 → files/penstate
```

模块 → App 只用**显式广播**；App → 模块只用**状态文件**（`files/penstate`，模块 inotify 监听）。

## 三、安装

1. 刷模块：把 `out/tb378fc_hyperos_fix-*.zip` 交给 KernelSU 管理器（或 `ksud module install`），重启。
2. 装 App：模块开机会自动安装 `bin/TbFix.apk`（`dev.tb378fc.fix`）。
3. **LSPosed**：启用模块「**TB378FC 修复**」，作用域勾 **系统框架 / 设置 / com.miui.securitycore / 笔记 / 小米创作**，
   然后**完整重启**（不是只重启 zygote）。少了这步：AON、设置页可见性、画布状态、即时下发都不生效，
   但手势桥/胶囊/唤醒/波形这些不依赖它的部分仍然工作。
4. WebUI：KernelSU 管理器 → 模块 → TB378FC → 「打开 WebUI」（若看不到，下拉刷新一次管理器）。

## 四、配置

- **WebUI**（推荐）：手势使能、写字触感总开关与每种笔刷波形、屏幕指令、胶囊/休眠档/设置同步。
  改动写入 `module/config` 并重启一次守护（约 20 秒）生效。
- 直接改 `module/config`（KernelSU 模块目录下同名文件）也可以；键的说明都写在文件里。
- 命令行辅助：`sh service.sh --json`（读生效值）、`--set KEY VALUE`（写一项并重启）、
  `--brushsend <波形id>`、`bin/penring --key <原始键>`（排障注入）。

标记文件（放进模块目录即生效）：`disable`、`disable-gesture`、`disable-brush`、`disable-capsule`、
`disable-rompen`、`disable-aon`、`disable-aonlib`、`disable-rest`。

## 五、验收与排障

```sh
M=/data/adb/modules/tb378fc_hyperos_fix

# 模块在不在跑（正常：supervise/monitor/brushwatch 各 1，penring + penring --watch）
ps -A -o PID,ARGS | grep -E "service\.sh --|[p]enring"

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

## 六、已知取舍 / 没做的

- **笔尾当橡皮**：小米笔记/小米创作里**没有"橡皮端"这条原生路径**（小米触控膜笔本身没有笔尾橡皮，
  只有侧键/快捷键）。试过 ERASER tool type、伪造 `BUTTON_STYLUS_PRIMARY`、复用 MIUI 的"切笔/橡皮"
  快捷键动作，都被否掉了（细节与实测数据见 `docs/stylus-gesture-bridge.md` §6）。目前只在**触感**上
  让笔尾切到橡皮波形（35）。
- **遥控 / 旋转笔刷**：不支持（联想笔没有陀螺仪，6DOF 通道回的是固定描述符）。
- **AON**：依赖移植包里那份 `mifaced`（含联想 Y700 的 shim）+ 三条 SELinux 规则 + `/odm/lib64` 补
  `libcamera2ndk.so`；`/odm` 与 `/` 是只读 erofs，所以都走 tmpfs + bind（开机自动，卸载即恢复）。
- **App 里的 `PenBle.DEFAULT_MAC`**：是找不到笔时的兜底 MAC，请改成**你自己那支笔**的地址
  （或留空让它走扫描）。
- 本仓库含移植包里的第三方材料（PowerKeeper 字节码补丁 payload、图标等），仅供个人研究，权利归原厂。

## 七、目录结构

```
tb378fc-hyperos-fix/
├── build.sh                  一键构建（App + penring + 打包模块 zip）
├── app/
│   ├── TbFix/                App + LSPosed 钩子（同时是笔的 BLE 代理）
│   │   ├── src/dev/tb378fc/fix/{PenBle,WakeReceiver,Capsule,...}.java
│   │   └── src/dev/tb378fc/fix/hook/TbFixHook.java
│   └── PenRing/penring.c     手势桥守护（静态 aarch64）
├── module/
│   ├── post-fs-data.sh       ② PowerKeeper / ⑧ cust_features / ⑧b 补 libcamera2ndk
│   ├── service.sh            看护主循环（①③④⑤⑥⑦⑧⑨⑬ + WebUI 用的 --json/--set）
│   ├── sepolicy.rule         AON HAL（hal_miface_default）三条规则
│   ├── webroot/index.html    KernelSU WebUI
│   ├── bin/{penring,TbFix.apk}
│   └── payload/PowerKeeper.apk
├── tools/                    peninject / patch_powerkeeper / check-helpers 等
└── docs/                     AON、胶囊、手势桥、ZUX 协议等完整文档
```

## 八、构建

```bash
./build.sh            # App + penring + 打包（用仓库里现成的 payload）
./build.sh --payload  # 额外从 payload-src/PowerKeeper-stock.apk 重建 PowerKeeper payload
```

需要 JDK 17、Android SDK（build-tools 37 + platform android-36）、`python3`、`zip`；
SDK 路径默认 `/opt/android-sdk`，可用 `ANDROID_SDK_ROOT=` / `BT_DIR=` / `ANDROID_PLATFORM=` 覆盖。
构建期会跑 `sh -n` 与 `tools/check-helpers.py`（检查"调用了但没定义的函数"——脚本里这类问题会静默）。

## 九、文档

- `docs/stylus-gesture-bridge.md` — 手势桥：手势表、type-8/kl、映射、看护的启动/自愈、笔尾橡皮的结论
- `docs/aon-attention.md` — 注视感知：四个卡点、SELinux 三条、验收命令、踩过的坑
- `docs/native-stylus-capsule.md` — 原生电量胶囊的触发链与参数
- `docs/zuxos-pen-protocol.md` — ZUX 笔协议帧表（`{5,5}`/`{5,3}`/`{5,2}`/`{5,1}`/`{8,6,..}`…）
