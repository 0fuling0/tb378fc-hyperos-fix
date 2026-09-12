# TB378FC HyperOS 修复 —— 源码树

联想小新 Pad Pro GT 13（**TB378FC**）刷 HyperOS 移植包（`OS3.0.307.0.WPYCNXM` / Android 16）之后的五项修复。
本目录是**可构建的源码树**：模块脚本 + PenBridge 应用源码 + PowerKeeper payload 的重建工具链。

> 说明：`module/` 里的文件最初是从设备上**已安装的 v3.0 模块**原样拉下来的
> （`adb exec-out su -c "tar -cf - -C /data/adb/modules tb378fc_hyperos_fix"`），
> 只去掉了运行期状态（`wake.log` / `.monitor.lock/` / `.apk.sha`），并补回了安装期才用到的 `customize.sh`。
> 当前版本 **v3.1** 在此基础上加了 ⑤ 吸附胶囊：`service.sh` / `config` / `action.sh` / `module.prop` /
> `app/PenBridge`（`Capsule.java` + `WakeReceiver` 的 ATTACH 分支 + `PenBle.readBattery`）。

---

## 五项修复

| # | 修复 | 做法 | 关掉的标记文件 |
|---|---|---|---|
| ① | **手写笔休眠唤醒** | root 守护按 `wls_tx/attached` 的**取下边沿**，让 PenBridge.apk 往笔的 BLE 特征 `fe41` 写 `{05,05}` 叫醒睡死的笔 | `module/disable` |
| ② | **PowerKeeper 修复** | 用打好两处字节补丁的 `PowerKeeper.apk` 在 `post-fs-data` 阶段 bind mount 覆盖 `/system_ext/app/PowerKeeper/PowerKeeper.apk` | `module/disable-powerkeeper` |
| ③ | **停 BPF 监视器** | 开机后看护并 `ctl.stop dynbpfloader`，避免 `hyper_bpfloader` 判定"系统损坏"写 recovery 引导块重启进 recovery | `module/disable-bpfmon` |
| ④ | **停死电话栈** | `ro.radio.noril=yes`（`ro.baseband=apq`，无 modem）时 `pm disable-user` 掉 `com.qti.phone` / `com.qualcomm.qcrilmsgtunnel` / `com.qualcomm.qti.telephonyservice`，掐断每秒数百次的崩溃重启链 | `module/disable-telephony` |
| ⑤ | **手写笔吸附胶囊** | 吸附边沿读反向无线充电线圈看到的笔电量（`wls_tx/level`），让 PenBridge 发原生 `STYLUS_STATE_SOC` 广播给 `com.miui.securitycore`，由 HyperOS 自己弹电量胶囊；再用 GATT 真值补一条校正 | `module/disable-capsule` 或 `config` 里 `CAPSULE=0` |
| ⑥ | **手势桥：变成小米焦点触控笔** | `bin/penring` 常驻：读联想笔手势节点（`eventN` 的 `MSC_SCAN 0x0c06xx`），造一支 **type-8**（`0x0022/0x5081`）虚拟笔并注入 `194 捏 / 195 双击 / 196 上滑 / 197 下滑 / 92 笔尾(截图键)`，同时给这支笔写一份 kl（本 ROM 的 Generic.kl 把 raw 194 映射成 337，不写 kl 就进不了 MIUI 的触控膜分支）；另外把"设置 → 手写笔"里的**双击开关/轻捏开关/轻捏力度**实时路由给笔（`{8,6,mask}` bit0/bit4、`{8,5,level}`）、把手势映射成笔的马达波形（捏/双击/笔尾=IMP 冲击；**上滑/下滑=CON 连续振动**，强度按小米 `device_features` 的幅度值换算）、停掉移植 ROM 自带的旧桥 `lwky_pen` | `config` 里 `GESTURE=0` / `HAPTIC=0` / `TOUCHFILM=-1` / `SETTINGS_SYNC=0`，或标记文件 `disable-gesture` / `disable-rompen` |

原理细节都写在脚本文件头：`module/service.sh`（①③④⑤⑥）、`module/post-fs-data.sh`（②）；
⑤ 的完整触发链与参数表见 **`docs/native-stylus-capsule.md`**，
⑥ 的完整说明（手势表、键位映射、配置项、自检方法）见 **`docs/stylus-gesture-bridge.md`**，
笔端 `{8,6,mask}` 功能位的位定义见 **`docs/zuxos-pen-protocol.md` §2.1**。

---

## 目录结构

```
tb378fc-hyperos-fix/
├── build.sh                     # 一键构建 + 打包（KernelSU 模块 zip）
├── module/                      # 打进 zip 的内容（设备上那份 v3.0 + ⑤ 胶囊）
│   ├── module.prop              # id / 版本 / 六项描述
│   ├── customize.sh             # 安装期权限设置（从 v2.0 安装包恢复，按 v3.1 清单更新）
│   ├── post-fs-data.sh          # ② PowerKeeper 覆盖 + 开机清锁
│   ├── service.sh               # ①③④⑤⑥ 的状态机 / 看护进程（含 penring 与旧桥 lwky_pen）
│   ├── action.sh                # KernelSU「操作」按钮里显示五项状态
│   ├── uninstall.sh             # 卸载：停守护、卸 APK、**故意不**恢复死电话包
│   ├── config                   # REFRESH_SECONDS / CAPSULE / TOUCHFILM / GESTURE_* 等可调项
│   ├── tools/
│   │   ├── patch_powerkeeper.py # 字节补丁：startCloudSyncData 的 return v0 -> return-void
│   │   └── fix_static.py        # 结构补丁：isFeatureOn 移入 direct_methods + ACC_STATIC
│   ├── bin/PenBridge.apk        # ① 的载体（构建产物，见 app/PenBridge）
│   ├── bin/penring              # ⑥ 手势桥守护（构建产物，见 app/PenRing）
│   └── payload/PowerKeeper.apk  # ② 的载体（构建产物，见 payload-src）
├── app/PenBridge/               # PenBridge.apk 源码（BLE 唤醒 / 电量读取 / 胶囊转发）
│   ├── AndroidManifest.xml      # dev.tb378fc.stylus，versionCode 11 / 3.1
│   ├── src/dev/tb378fc/stylus/  # PenBle.java, WakeReceiver.java, WakeActivity.java, Capsule.java
│   ├── res/                     # 图标
│   ├── tools/make_icons.py      # 图标生成
│   ├── penwake.jks              # 签名密钥（store/key pass 都是 penwake）
│   └── build.sh                 # aapt2 + javac + d8 + zipalign + apksigner（无 Gradle）
├── app/PenRing/                 # ⑥ penring：联想笔手势 → type-8 虚拟笔（NDK 静态 aarch64）
│   ├── penring.c                # 读 MSC_SCAN、造虚拟笔、写 kl、注入 194/195/196/197/92
│   └── build.sh                 # aarch64-linux-android30-clang，无 Gradle
├── tools/peninject.c            # 自检：伪造"联想笔手势节点"喂 usage（不需要真笔）
├── payload-src/
│   ├── PowerKeeper-stock.apk    # 移植包**原厂** APK（补丁输入，来自 system_ext/app/PowerKeeper）
│   └── repack_payload.py        # 把打好补丁的 dex 塞回 APK（保持 stored + 原条目元数据）
├── extras/PenStylusHook/        # 【可选，v3.0 模块不含】LSPosed：让系统读到笔电量
│   ├── src/…/PenStylusHook.java # hook BatteryController#getBluetoothDevice
│   ├── stub-patches/            # Xposed API 编译桩（d8 时过滤掉）
│   └── build.sh
└── out/                         # 构建产物：<id>-v<version>.zip
```

---

## 构建

依赖：JDK 17、Android SDK（`build-tools/37.0.0` + `platforms/android-36`）、`python3`、`zip`。
SDK 路径默认 `/opt/android-sdk`，可用 `ANDROID_SDK_ROOT=` / `BT_DIR=` / `ANDROID_PLATFORM=` 覆盖。

```bash
./build.sh              # 只构建 PenBridge.apk + 打包（payload 用仓库里现成的那份）
./build.sh --payload    # 额外从 payload-src/PowerKeeper-stock.apk 重建 payload
./build.sh --hook       # 额外构建 extras/PenStylusHook
./build.sh --all        # 上面两个都做
./build.sh --clean
```

产物：

```
app/PenBridge/PenBridge.apk              （同时拷进 module/bin/）
extras/PenStylusHook/PenStylusHook.apk   （--hook）
out/tb378fc_hyperos_fix-v3.1.zip         KernelSU 模块包（zip 根 = module/ 的内容）
```

刷入：把 zip 交给 KernelSU 管理器，或 `su -c "magisk --install-module out/tb378fc_hyperos_fix-v3.0.zip"`，
重启后 `action.sh` 的状态可以在 KernelSU 的「操作」里看到。

### 可复现性（实测）

- `PenBridge.apk`：重新构建的产物与设备上那份 **9 个 zip 条目名/CRC/大小/压缩方式全部相同**，
  `classes.dex` 逐字节相同；整包 sha256 不同只来自签名块/时间戳，功能等价。
- `PowerKeeper.apk`：`--payload` 从原厂 APK 走完 `patch_powerkeeper.py` → `fix_static.py` → `repack_payload.py`
  后，510 个条目里 **509 个条目 CRC 完全相同**，`classes.dex` 逐字节相同（补丁本身等长：1639 → 1639 字节，
  dex 的 adler32/SHA-1 已重算）；只有 zip 容器的时间戳/额外字段有差异。

### ② 的两个前提

- payload 靠 **bind mount** 覆盖系统包；`PMS` 之所以接受这个改过的 APK，是因为该移植包
  `ro.debuggable=1`（user 构建却打了 debuggable）。换 ROM 要重新确认。
- 必须 `post-fs-data`（早于 PackageManager 扫描包）阶段覆盖；`service.sh` 阶段太晚。

---

### ⑤ 胶囊：触发方法与参数（详版见 docs/native-stylus-capsule.md）

触发链（v3.1 快路径，实测"笔放上去 → 胶囊出现"里只有 ~0.3s 是软件）：

```
wls_tx 边沿（POLL_MS=200 轮询，内建 read）
  ├─ 边沿 A：level 1..100 -> 0（线圈刚启动，比 attached 早 ~2s）
  │     └─ CAPSULE_FAST=1：先用上一次的线圈电量弹一条（~0.2s 出胶囊），2s 后拿新值刷新
  └─ 边沿 B：attached 0 -> 1（硬件握手完成）
  └─ 两条边都：守护直发 am broadcast … STYLUS_STATE_SOC（battery/state=4/connect=5）
        → com.miui.securitycore/…MiuiStylusReceiver → 原生胶囊（实测 +0.3s 内出现）
     并转发 ATTACH(battery=-1, coil=<已显示值>) 给 PenBridge 做兜底校正
```

发往 `SecurityCoreAdd` 的参数（`STYLUS_STATE_SOC`）：

| extra | 取值 | 说明 |
|---|---|---|
| `battery` | `0..100` | 胶囊显示的电量；非法值本模块直接不发（否则显示 "-1"） |
| `state` | `4`=充电中（⚡）/ `2`=未充电 | 吸附时固定 `4` |
| `connect` | **`5`=已连接（唯一会直接弹电量胶囊的值）**；`0/1/3/4/7/8/9` 见文档 | 本模块固定 `5` |

前置条件：`settings put secure stylus_first_connect 1`（否则只走"首次连接引导"不弹胶囊）——
`service.sh` 的 `prepare_stylus_settings()` 会自动补写；`setting_stylus_version` 需非 0（本机为 1）。

响应速度相关的 config（都在 `module/config`）：

| 键 | 默认 | 作用 |
|---|---|---|
| `POLL_MS` | `200` | 吸附检测轮询间隔，决定"吸上去多久才弹"（第一版 `sleep 1`+`sleep 2` ≈ 3s，现在 ~0.5s） |
| `CAPSULE_DIRECT` | `1` | 守护直发原生广播，省掉"叫醒 App 进程"一跳 |
| `CAPSULE_GATT` | `1` | 直发后再用系统 API / GATT 读真值，**不同**才补弹一条校正 |
| `CAPSULE_FAST` | `1` | 边沿一到就用上次的线圈电量先弹（~0.2s），1~2s 后刷新为新值；`0` = 等本次真值（慢 1~2s） |

手动验证（绕过守护直接弹）：

```bash
adb shell am broadcast -a com.android.settings.stylus.STYLUS_STATE_SOC \
  -n com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver \
  --ei battery 88 --ei state 4 --ei connect 5
```

**不要**发 `STYLUS_BATTERY_NOTIFY` 的 `battery=80`、也不要发 `connect=9`：这两个会调用
`IMiCharge.setWirelessChargingEnabled(...)`，真的会开关反向无线充电。

## 已知取舍

- ④ 卸载时**故意不**恢复那三个电话包的启用状态（恢复就等于立刻回到每秒数百次的崩溃循环；
  那是本机默认的坏状态，不是卸载模块的人想要的结果）。要恢复见 `module/uninstall.sh` 末尾的提示。
- ③ 停掉的只是**开机后**由 init 拉起的监视器（`dynbpfloader`）；开机期 `hyper_bpfloader`
  本体加载的约 50 个 BPF 不受影响。
- `extras/PenStylusHook` 需要手动在 LSPosed 里启用并勾选作用域「系统框架」，模块本身无法自动写
  LSPosed 数据库（`app_process` 的 linker namespace 里没有 `libandroidicu.so`）。

---

## 相关文档

- `docs/native-stylus-capsule.md` —— pad8p 原生「吸附胶囊」的触发链，以及在本机上**实测可用**的
  触发命令（v3.0 模块没有内置胶囊；要做的话照这份文档接）。
