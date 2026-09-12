# pad8p 原生「吸附胶囊」的触发链（含 TB378FC 实测）

目标：把小米平板原生那条**吸附/连接手写笔时弹出的电量胶囊**接过来。v3.0 模块没有内置胶囊，
这份文档是逆向 + 实机验证的结果，照它接即可，**不需要**再自己发 `miui.focus.param` 假灵动岛。

---

## 1. 胶囊是谁画的

不是 SystemUI，而是 **SecurityCoreAdd.apk（`com.miui.securitycore`）里的 `com.miui.miinput.stylus`**：

```
MiuiStylusReceiver                     (manifest 声明, exported=true, 无 permission 限制)
   │  监听 3 个 action（第 4 个 STYLUS_STATE_ATT 全 ROM 没有接收方）
   ├── com.android.settings.stylus.STYLUS_STATE_SOC        (battery / state / connect)
   ├── com.android.settings.stylus.STYLUS_BATTERY_NOTIFY   (battery / state)
   └── com.android.settings.stylus.STYLUS_PLACE_ERROR      (penPlaceErr)
   v
MiuiStylusBatteryManager               (混淆类 j5.g)
   v
j5.f = 浮窗 "StylusBattery"
   layoutParams.gravity = TOP|CENTER, type = 2024, title = "StylusBattery"
   windowAnimations     = stylus_battery_anim
   layout               = stylus_info_layout
   size                 = R.dimen.stylus_battery_window_width/height
```

`stylus_info_layout` 里是 5 个子状态（视图绑定 `j5.a`）：

| info type | 子布局 | 内容 | 自动消失 |
|---|---|---|---|
| 0 | `stylus_info_press_connect` | "点击连接" | 5 s |
| 1 | `stylus_info_connecting` | "正在连接中…" + 转圈动画 | — |
| 2 | `stylus_info_battery` | **笔形电量条**（`MiuiStylusLevelsView`）+ `stylus_battery` 百分比 + 充电闪电 | 2 s |
| 3 | `stylus_info_connect_fail` | "连接失败，请重新磁吸 / 请重试 / 与平板不匹配 / 开启位置服务后重连" | — |
| 4 | `stylus_info_ota` | 固件升级进度窗（尺寸换成 `stylus_firmware_window_width`） | 10 min |

`connect` 值 → info type 的映射（`u0/a.java` 的 `a(Message)`）：

```
0 -> 0(点击连接)   1 -> 1(连接中)   5 -> 2(电量胶囊)
2 -> 只有当前正显示 type 1 时才升级成 2，否则什么都不做
3 / 4 / 7 -> 3(失败，文案按 7=不匹配 / 4=连接失败 / 3=无原因，未开定位则提示开定位)
8 -> 4(OTA)        9 -> 关闭反向无线充电（不弹窗）
6 -> 复位"摆放错误"提示计数
```

`state`：**4 = 充电中**（显示 ⚡），**2 = 未充电**（`MiuiBleOobHelperService` 里由 MIPP 的充电 notify 赋值）。

---

## 2. 原生是谁在发这些广播

`system_ext/app/BluetoothExtension`（`com.xiaomi.bluetooth`）的 **`MiuiBleOobHelperService`** ——
小米笔的 MIPP/BLE 协议栈，framework 侧
`com.miui.server.input.stylus.MiuiStylusBleHelper` 通过 `bindService` 连它：

```
L2() -> STYLUS_STATE_ATT          M2() -> STYLUS_BATTERY_NOTIFY
N2() -> STYLUS_STATE_SOC          O2() -> STYLUS_PLACE_ERROR
```

所以 pad8p 上的完整链路是：

```
笔吸附/唤醒 → BLE MIPP 连上 → oobhelper 上报 SOC / 充电 / 连接状态 → 广播
   → SecurityCoreAdd 弹「笔形电量条 + ⚡xx%」胶囊
```

TB378FC 上这支联想笔走的是普通 BT HID（HOGP），不说 MIPP，所以 oobhelper 永远不发这些广播
→ 胶囊永远不出现。**缺口就在这里，补法就是替它发广播。**

---

## 3. 实测：直接发广播就能出原生胶囊

```bash
adb shell am broadcast \
  -a com.android.settings.stylus.STYLUS_STATE_SOC \
  -n com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver \
  --ei battery 88 --ei state 4 --ei connect 5
```

实测（TB378FC / HyperOS `OS3.0.307.0.WPYCNM`）：

- logcat：`MiuiStylusBatteryManager: From source: bluetooth batteryLevel : 88 stylusState : 4 connectState : 5`
  然后 `Battery window attached`
- `dumpsys window windows` 出现
  `Window{… StylusBattery} pkg=com.miui.securitycore ty=NAVIGATION_BAR_PANEL gr=TOP CENTER (0,93)(495x172)`
- 截图就是原生胶囊：圆角底 + **笔形绿色电量条** + `⚡ 88%`
- 2 秒后自动消失（type 2 的定时器）

### 前置条件（缺一不可）

1. `settings put secure stylus_first_connect 1`
   （`touch_film_stylus_first_connect 1` 同理）。否则走「首次连接引导」分支，只会打日志
   `First time connect ,let user look instruction`，不弹电量胶囊。
2. `settings get secure setting_stylus_version` **非 0**（本机是 `1`）。为 0 时代码会判定
   "stylus input device has not been created"，把事件延后 50 ms 重投，实际不会弹。

### 踩坑

- **`connect=2` 不弹**，只有 `connect=5` 直接弹电量胶囊。
- **别发 `STYLUS_BATTERY_NOTIFY` 的 `battery=80`**：`battery==80` 会走
  `d0.h(80, true)` → `miui.util.IMiCharge.setWirelessChargingEnabled(true)`，**真的会开反向无线充电**。
- **别发 `connect=9`**：会 `setWirelessChargingEnabled(false)`。这两个是唯一会碰充电硬件的路径。
- 低电量分支（`STYLUS_BATTERY_NOTIFY`）：`battery=0/5` → "连接失败，无电量"；
  `battery=10/20` → 低电量胶囊；`battery=80` → 见上，别碰。
- 宿主进程是 `com.miui.securitycore`（系统应用），窗口 type 2024 需要系统权限；普通应用只能发广播，
  不能自己画这个窗口 —— 这也正是"让原生去画"的意义。

---

## 4. 接到模块里的建议做法

在 `app/PenBridge` 里加一条（它本来就跑在 root 守护拉起的流程里，且已经有 BLE/GATT 电量读取）：

```
wls_tx/attached  0 -> 1（吸附）
    └─ 读电量（GATT battery / 蓝牙栈 BATTERY_LEVEL）
       └─ am broadcast -a com.android.settings.stylus.STYLUS_STATE_SOC \
            -n com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver \
            --ei battery <0..100> --ei state <充电?4:2> --ei connect 5
```

- `state` 取 4/2：吸附时笔在无线充电，一般就是 4；不确定时给 2 也只是少个闪电图标。
- 安装期顺手写一次 `settings put secure stylus_first_connect 1`（`service.sh` 的 `install_apk` 旁边）。
- 想做得更"原生"也可以让守护在取下时兜底发 `connect=4`（连接失败文案），但没必要。
- 相关 action 与 receiver 组件名固定为：
  `com.android.settings.stylus.STYLUS_STATE_SOC` /
  `com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver`。
