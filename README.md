# TB378FC HyperOS 修复 —— 源码树

联想小新 Pad Pro GT 13（**TB378FC**）刷 HyperOS 移植包（`OS3.0.307.0.WPYCNXM` / Android 16）之后的四项修复。
本目录是**可构建的源码树**：模块脚本 + PenBridge 应用源码 + PowerKeeper payload 的重建工具链。

> 说明：`module/` 里的文件是从设备上**已安装的 v3.0 模块**原样拉下来的
> （`adb exec-out su -c "tar -cf - -C /data/adb/modules tb378fc_hyperos_fix"`），
> 只去掉了运行期状态（`wake.log` / `.monitor.lock/` / `.apk.sha`），并补回了安装期才用到的 `customize.sh`。

---

## 四项修复

| # | 修复 | 做法 | 关掉的标记文件 |
|---|---|---|---|
| ① | **手写笔休眠唤醒** | root 守护按 `wls_tx/attached` 的**取下边沿**，让 PenBridge.apk 往笔的 BLE 特征 `fe41` 写 `{05,05}` 叫醒睡死的笔 | `module/disable` |
| ② | **PowerKeeper 修复** | 用打好两处字节补丁的 `PowerKeeper.apk` 在 `post-fs-data` 阶段 bind mount 覆盖 `/system_ext/app/PowerKeeper/PowerKeeper.apk` | `module/disable-powerkeeper` |
| ③ | **停 BPF 监视器** | 开机后看护并 `ctl.stop dynbpfloader`，避免 `hyper_bpfloader` 判定"系统损坏"写 recovery 引导块重启进 recovery | `module/disable-bpfmon` |
| ④ | **停死电话栈** | `ro.radio.noril=yes`（`ro.baseband=apq`，无 modem）时 `pm disable-user` 掉 `com.qti.phone` / `com.qualcomm.qcrilmsgtunnel` / `com.qualcomm.qti.telephonyservice`，掐断每秒数百次的崩溃重启链 | `module/disable-telephony` |

原理细节都写在脚本文件头：`module/service.sh`（①③④）、`module/post-fs-data.sh`（②）。

---

## 目录结构

```
tb378fc-hyperos-fix/
├── build.sh                     # 一键构建 + 打包（KernelSU 模块 zip）
├── module/                      # 打进 zip 的内容（= 设备上那份 v3.0）
│   ├── module.prop              # id / 版本 / 四项描述
│   ├── customize.sh             # 安装期权限设置（从 v2.0 安装包恢复，按 v3.0 清单更新）
│   ├── post-fs-data.sh          # ② PowerKeeper 覆盖 + 开机清锁
│   ├── service.sh               # ①③④ 的状态机 / 看护进程
│   ├── action.sh                # KernelSU「操作」按钮里显示四项状态
│   ├── uninstall.sh             # 卸载：停守护、卸 APK、**故意不**恢复死电话包
│   ├── config                   # REFRESH_SECONDS 等可调项
│   ├── tools/
│   │   ├── patch_powerkeeper.py # 字节补丁：startCloudSyncData 的 return v0 -> return-void
│   │   └── fix_static.py        # 结构补丁：isFeatureOn 移入 direct_methods + ACC_STATIC
│   ├── bin/PenBridge.apk        # ① 的载体（构建产物，见 app/PenBridge）
│   └── payload/PowerKeeper.apk  # ② 的载体（构建产物，见 payload-src）
├── app/PenBridge/               # PenBridge.apk 源码（BLE 唤醒 / 电量读取）
│   ├── AndroidManifest.xml      # dev.tb378fc.stylus，versionCode 10 / 3.0
│   ├── src/dev/tb378fc/stylus/  # PenBle.java, WakeReceiver.java, WakeActivity.java
│   ├── res/                     # 图标
│   ├── tools/make_icons.py      # 图标生成
│   ├── penwake.jks              # 签名密钥（store/key pass 都是 penwake）
│   └── build.sh                 # aapt2 + javac + d8 + zipalign + apksigner（无 Gradle）
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
out/tb378fc_hyperos_fix-v3.0.zip         KernelSU 模块包（zip 根 = module/ 的内容）
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
