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

## 4. 移植 ROM 自带的老笔桥要停掉

`/system/etc/init/init.lwky.rc` 里有一个 `lwky_pen` 服务（`/system/lwky/penbridge_hyperos`），
在 `sys.boot_completed=1` 时启动，是移植 ROM 作者写的旧桥：

* 造的是 **type 1**（`0x1915/0xEAEA`）虚拟笔 → HyperOS 的触控膜分支根本不认；
* 按它自己的映射往笔上灌 **PAGEUP/PAGEDOWN(92/93)** → 92/93 在 MIUI 里是"截图键/速记键"，
  于是会出现"一捏就待命截图"这类怪行为，还会和 penring 抢着注入。

所以模块的 setup 阶段会额外拉起一个 `--stoprompen` 看护：`setprop ctl.stop lwky_pen` +
`pkill -x penbridge_hyperos`，并且每 30 秒复查一次。不想要这个行为就建 `disable-rompen` 标记文件。

（`lwky_touchfeature` 那个假 HAL **不要停**：MIUI 的 `ITouchFeature.setTouchMode()` 需要它返回成功。）

## 5. 构建 / 安装 / 自检

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
