# 手势桥：把联想 Tab Pen Pro 2 变成"小米焦点触控笔"

目标：在这台跑了 HyperOS 的联想平板上，让联想笔的**捏 / 双击 / 上滑 / 下滑 / 笔尾键**
跟小米焦点触控笔（P81C，带快捷环那支）一样工作。

不做：**遥控**（要特定短视频 App 配合）与**旋转笔身调笔刷方向**（需要笔里带陀螺仪，
Tab Pen Pro 2 没有 —— 那条 BLE 6DOF 通道回的是固定 21 字节描述符，不是姿态）。

- 守护进程：`bin/penring`（源码 `app/PenRing/penring.c`，NDK 直接编的静态 aarch64）
- 启动：`service.sh --supervise` 看护（笔不在时它自己每 2 秒轮询，几乎不占 CPU）
- 日志：`/data/adb/modules/tb378fc_hyperos_fix/penring.log`
- 关掉：`config` 里 `GESTURE=0`，或建标记文件 `disable-gesture`

---

## 1. 联想笔的手势在哪

笔内触控膜检测手势 → BLE HID（Report ID 2，consumer control 集合）→ 内核 `hid-input`
认不出这些非标准 usage，全部翻成 `KEY_UNKNOWN(240)`，**手势身份保留在 `MSC_SCAN` 里**：

```
/dev/input/eventN   name="Lenovo Tab Pen Pro 2 Consumer Control"   （本机 event10）
```

| MSC_SCAN | 手势 | 备注 |
|---|---|---|
| `0x000c0619` | 捏下 | MIUI 侧对应"轻捏"按下 |
| `0x000c0620` | 捏松 | 和捏下是**两个不同的 usage**，不是 up 事件 |
| `0x000c0601` | 双击 | |
| `0x000c0613` | 上滑 | |
| `0x000c0612` | 下滑 | |
| `0x000c0623` | 笔尾按住 | |
| `0x000c0624` | 笔尾松开 | |

三击位（`{8,6}` 的 bit1）在固件里没有对应的 usage，试不出来，忽略。

另外：`Generic.kl` 里没有 `key 240`，所以这些事件到 Android 层就是 keyCode 0 被丢掉 ——
**普通 App 拿不到手势**，必须自己读 evdev（root）。这也解释了为什么 BLE 侧"看起来什么都没有"：
手势走的是 HID over GATT 的 Report 特征，它的 CCCD 被系统 HID Host profile 占着，App 订不到；
要看原始字节就 `su -c 'cat /dev/hidraw0 | od -An -tx1 -w5'`。

## 2. HyperOS 只认"小米触控膜笔"

`MiuiStylusTouchFilmManager.interceptKeyBeforeQueueing()` 的三个条件：

1. **设备身份**：`MiuiStylusUtils.TOUCH_FILM_STYLUS = Set.of(8)`，
   即 `InputDevice.isXiaomiStylus()` 必须等于 8 → `input_id` 的
   **vendor `0x0022` / product `0x5081`**（框架表 `android.view.InputDevice.isXiaomiStylus`）。
   框架自带的 `0x1915/0xEAEA` 只映射成 type 1（"小米灵感笔"），永远进不了这个分支。
2. **键码**：`194 轻捏 / 195 双击 / 196 上滑 / 197 下滑`
   （`TOUCH_FILM_KEYCODES`），以及 `MiuiStylusShortcutManager` 的
   **`92` = 截图键 / `93` = 速记键**（"按住它 + 点屏幕"）。
3. **键位映射**：本 ROM 的 `/system/usr/keylayout/Generic.kl` 被小米改过，
   `key 194 F24` 而小米把 `KEYCODE_F24` 定成 **337** —— 直接报 raw 194 得到的
   Android 键码是 337，MIUI 拦不到。所以**必须给这支虚拟笔一份自己的 kl**：

```
/data/system/devices/keylayout/Vendor_0022_Product_5081.kl   ← penring 启动时自己写
    key 104   PAGE_UP      -> Android 92
    key 109   PAGE_DOWN    -> Android 93
    key 194   BUTTON_7     -> Android 194（轻捏）
    key 195   BUTTON_8     -> Android 195（双击）
    key 196   BUTTON_9     -> Android 196（上滑）
    key 197   BUTTON_10    -> Android 197（下滑）
```

## 3. 映射表（默认，可在 `config` 里改）

| 联想笔手势 | penring 注入 | HyperOS 里的行为 |
|---|---|---|
| 捏（0x619/0x620） | **194** 按下/抬起 | **快捷环**（`showStylusPinchShortcutPanel`，SystemUI `QuickAppPanelView`，系统级，任何 App 都弹） |
| 双击（0x601） | **195** | MIUI"双击"：小米创作、或自己调过 `enableStylusTouchFilmForApp` 的 App 才有反应；否则被 MIUI 吞掉 |
| 上滑（0x613） | **196** | MIUI"上滑"：`NEED_TOUCHFLIM_KEY_APP` 白名单 App 会被 MIUI 转成 `92` 注入给 App（翻页） |
| 下滑（0x612） | **197** | 同上 → 转成 `93` |
| 笔尾按住/松开（0x623/0x624） | **92** 按下/抬起 | **截图键**：按住约 0.4 秒再点屏幕 = 截图标注（可以改成 93 = 灵感速记） |

`config` 里对应 `GESTURE_RING / GESTURE_DOUBLE / GESTURE_SLIDE_UP / GESTURE_SLIDE_DOWN /
GESTURE_TAIL`，值是 **Android 键码**，`-1` 表示关掉这一条。

想把上滑/下滑变成"任何 App 都能翻页"，把那两项改成 `92`/`93` —— 等于直接发
PAGE_UP/PAGE_DOWN（代价：380ms 内它们会被 MIUI 当成截图/速记键待命）。

顺带：笔端"上报哪些手势"还有一个总开关 `{8,6,mask}`，见
[`zuxos-pen-protocol.md` §2.1](zuxos-pen-protocol.md)。笔重启/睡死会把它清零，
模块在 `startup-wake` 和每次取下的 `detach-wake` 都会补写 `{8,6,63}`（`TOUCHFILM`）。

## 4. 把"设置 → 手写笔"里的开关/力度路由给笔

MIUI 的设置页（`stylus_pinch_status` / `stylus_double_click_status` / `stylus_pinch_pressure_adjust` …）
本来是给**小米自家笔**用的：框架只把阈值丢给 `MiuiStylusBleHelper`（它自己的 BLE 服务），
联想笔的固件听不懂。等价物在 ZUX 协议里，所以模块的守护每 2 秒看一次这几个 key，
一变就发对应的 FE41 帧：

| MIUI 设置（`Settings.System`） | 默认 | 下发给笔 | 说明 |
|---|---|---|---|
| `stylus_double_click_status` | 1 | `{8,6,mask}` **bit0** | 0 = 关，非 0（含功能号 1..N）= 开 |
| `stylus_pinch_status` | 5 | `{8,6,mask}` **bit4** | 0 = 轻捏关；5 = 轻捏=快捷环（功能号本身由 MIUI 主机侧处理） |
| `stylus_pinch_pressure_adjust` | 2 | `{8,5,level}`，`level = adjust + 1` | MIUI 是 0 基（0..4，对应 `pinch_trigger_pressure_*` 五档），笔端是 1..5（1 轻…5 重） |

上滑/下滑（bit2|3）与笔尾（bit5）没有对应的 MIUI 开关，按本模块的 `GESTURE_*` 常开。
实测（改设置 → 笔）：

```
settings put system stylus_double_click_status 0     → {8,6,0x3C}  (bit0 清掉)
settings put system stylus_pinch_pressure_adjust 4   → {8,5,5}     (力度 5)
settings put system stylus_pinch_pressure_adjust 1   → {8,5,2}
```

开关/力度都走 `bin/penring` 的存在性做前置判断；关掉这个行为：`config` 里 `SETTINGS_SYNC=0`。
手动跑一次：`sh /data/adb/modules/tb378fc_hyperos_fix/service.sh --syncsettings`，
结果看 `wake.log` 的 `settings->pen mask=.. squeeze=..` 一行。

"双击功能选择"（橡皮擦/截图/…）**没法路由**：那是 MIUI 对自家触控膜下发的功能码
（`bundle 3001`），联想笔没有这个概念 —— 那个功能只能在 App 侧实现（App 收到 195 自己切橡皮擦）。

## 5. 手势触感（马达）：小米的"触感优化"接到了联想笔上

**小米那边有什么**：框架里没有"随书写压力/速度连续变化的笔刷摩擦触感"，它的触控膜笔触感
就是 `/product/etc/device_features/<机型>.xml` 里这几个调校值（本机 `piano.xml`）：

```xml
<double  name="double_tap_haptic_feedback">128</double>       <!-- 0~255 -->
<double  name="sliding_up_haptic_feedback">128</double>
<double  name="sliding_down_haptic_feedback">128</double>
<integer-array name="pinch_trigger_pressure_medium">
    <item>600</item> <item>300</item>   <!-- 捏合触发/释放阈值（克） -->
    <item>172</item> <item>172</item>   <!-- 按下/松开触感强度（0~255） -->
</integer-array>
```

它把这四个事件丢给自己的 BLE 服务，协议是 Messenger（不是 AIDL）：

```
MiuiStylusBleHelper → com.xiaomi.bluetooth
                        com.android.bluetooth.ble.app.oobhelper.MiuiBleOobHelperService
   3000 (trigger, release)   捏合阈值        3001 (doubleTap, 0)  双击开关
   3002 (type, amplitude)    振动 ← 就是它   3005 (3, 0)          捏合马达
   3006 bundle               初始化
   type: 1 捏下 / 2 捏松 / 3 双击 / 4 滑动
```

这个服务是给**小米笔**的私有协议用的，联想笔听不懂（实测 logcat 里 `Prepare to send cmd to
ble service, cmd:3002, value:4, extend value:128` 一直在发，但没有任何效果）。

**联想笔那边有什么**（ZUX 马达通道 `00000000-000f-11e1-…`）：

| 特征 | 帧 | 含义 |
|---|---|---|
| IMP `…0008` | `{id, level, repeatLo, repeatHi, 0, 0}` | 冲击式（离散） |
| CON `…0006` | `{id, level, b2, friction}` / 停 `{0,0,0,0}` | **连续式（连续振动，带摩擦感字节）** |
| SWITCH `…000e` | `{0|1}` | 马达总开关 |

波形：`1 CLICK / 3 HAPTIC_ENABLED / 6 RECOG_FINISHED / 7 PRESS / 32 圆珠笔 / 33 铅笔 /
34 马克笔 / 35 橡皮 / 36 联想笔刷 / 37..41 同上的无音效版`。

**模块怎么接的**：penring 读到手势 → 按下面的表发 `dev.tb378fc.stylus.HAPTIC` 广播 →
PenBridge 用 GATT 写马达帧；**强度直接用小米那份 xml 换算**（`level = round(amp/255*5)`，
128→3、172→3），所以振感跟小米的调校一致。

| 手势 | 波形 | 类型 |
|---|---|---|
| 捏下 | `HAPTIC_PINCH=3`（HAPTIC_ENABLED） | IMP |
| 捏松 | `HAPTIC_PINCH_UP=0`（默认不振） | IMP |
| 双击 | `HAPTIC_DOUBLE=1`（CLICK） | IMP |
| **上滑/下滑** | `HAPTIC_SLIDE=41`（联想笔刷·无音效） | **CON 连续振动**，`HAPTIC_SLIDE_MS=120` 后自动停 |
| 笔尾按住 | `HAPTIC_TAIL=6`（RECOG_FINISHED） | IMP |

`HAPTIC=0` 关掉全部；某一条设 0 就是那条不振；`HAPTIC_LEVEL=1..5` 可以固定强度
（默认 -1 = 按小米 xml 换算）。

**延迟**：空口 connect+discover 要 0.3~1s，所以 PenBridge 把连接**缓存**住（空闲 12 秒才断），
第一条手势慢一点，后面每条都在 20ms 内写出去（日志里能看到 `cached write …`）。
实测（用户现场手势）：

```
05:05:00.888 haptic CON wave=41 level=3 friction=1 ms=120 -> true
             write 29 03 03 01 rc=0            ← 下滑：连续振动
05:05:01.753 HAPTIC … {cached write 01 03 01 00 00 00 rc=0   ← 双击：CLICK
```

**想要"完全跟随 MIUI"**（含它未来调校）：可以再挂一个 LSPosed hook 到
`MiuiStylusBleHelper.sendCmdToBleServiceAsync(int,int,int)`，把 `cmd==3002` 的
`(type, amplitude)` 直接转成同一套 `HAPTIC` 广播（`extras/stylus-pen-hook` 已有架子）。
现在这一版不依赖 LSPosed。

## 6. 移植 ROM 自带的老笔桥要停掉

`/system/etc/init/init.lwky.rc` 里有一个 `lwky_pen` 服务（`/system/lwky/penbridge_hyperos`），
在 `sys.boot_completed=1` 时启动，是移植 ROM 作者写的旧桥：

* 造的是 **type 1**（`0x1915/0xEAEA`）虚拟笔 → HyperOS 的触控膜分支根本不认；
* 按它自己的映射往笔上灌 **PAGEUP/PAGEDOWN(92/93)** → 92/93 在 MIUI 里是"截图键/速记键"，
  于是会出现"一捏就待命截图"这类怪行为，还会和 penring 抢着注入。

所以模块的 setup 阶段会额外拉起一个 `--stoprompen` 看护：`setprop ctl.stop lwky_pen` +
`pkill -x penbridge_hyperos`，并且每 30 秒复查一次。不想要这个行为就建 `disable-rompen` 标记文件。

（`lwky_touchfeature` 那个假 HAL **不要停**：MIUI 的 `ITouchFeature.setTouchMode()` 需要它返回成功。）

## 7. 构建 / 安装 / 自检

```bash
./build.sh                 # 会同时构建 PenBridge.apk 与 bin/penring
# 单独构建：
bash app/PenRing/build.sh  # 需要 ANDROID_NDK_HOME（默认 /opt/android-ndk）
```

自检（不需要真笔、不需要动手势）——伪造成"联想笔的手势节点"再喂 usage：

```bash
aarch64-linux-android30-clang -O2 -static -s -o /tmp/peninject tools/peninject.c
adb push /tmp/peninject /data/local/tmp/ && adb shell su -c 'chmod 755 /data/local/tmp/peninject'
adb shell su -c 'mkfifo /data/local/tmp/pififo; setsid sh -c "exec /data/local/tmp/peninject < /data/local/tmp/pififo" &'
# peninject 会打印它建的 /dev/input/eventN，然后：
adb shell su -c 'setsid /data/local/tmp/penring --dev /dev/input/eventNN --moddir /data/local/tmp &'
adb shell su -c 'echo 0c0619 > /data/local/tmp/pififo'     # 应该弹快捷环
```

排障：

```bash
adb shell su -c 'cat /data/adb/modules/tb378fc_hyperos_fix/penring.log'   # 每个手势一行
adb shell su -c 'cat /proc/bus/input/devices | grep -A4 "Xiaomi Pen"'      # 虚拟笔在不在
adb logcat -s MiuiStylusDeviceListener MiuiStylusTouchFilmManager QuickAppPanelView
```
