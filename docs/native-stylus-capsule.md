# 手写笔吸附胶囊：原生触发链 + 模块里的实现与参数

模块 v3.1 的 ⑤ 就是这条。本文记录**怎么触发**、**参数语义**、**实现落在哪**、**怎么排障**。
逆向对象：小米平板 8 Pro 官方包（`pad8p`，代号 piano，`OS3.0.308.0.WPYCNXM`）+ 本机 TB378FC 实测。

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

`stylus_info_layout` 里的 5 个子状态（视图绑定 `j5.a`）：

| info type | 子布局 | 内容 | 自动消失 |
|---|---|---|---|
| 0 | `stylus_info_press_connect` | "点击连接" | 5 s |
| 1 | `stylus_info_connecting` | "正在连接中…" + 转圈 | — |
| 2 | `stylus_info_battery` | **笔形电量条**（`MiuiStylusLevelsView`）+ `stylus_battery` 百分比 + 充电闪电 | 2 s |
| 3 | `stylus_info_connect_fail` | "连接失败，请重新磁吸 / 请重试 / 与平板不匹配 / 开启位置服务后重连" | — |
| 4 | `stylus_info_ota` | 固件升级进度窗 | 10 min |

`connect` → info type 的映射（`u0/a.java` 的 `a(Message)`）：

```
0 -> 0(点击连接)   1 -> 1(连接中)   5 -> 2(电量胶囊)
2 -> 只有当前正显示 type 1 时才升级成 2，否则什么都不做
3 / 4 / 7 -> 3(失败：7=不匹配 / 4=连接失败 / 3=无原因；未开定位则提示开定位)
8 -> 4(OTA)        9 -> 关闭反向无线充电（不弹窗）      6 -> 复位"摆放错误"提示计数
```

## 2. 原生是谁在发

`system_ext/app/BluetoothExtension`（`com.xiaomi.bluetooth`）的 **`MiuiBleOobHelperService`** ——
小米笔的 MIPP/BLE 协议栈；framework 侧 `com.miui.server.input.stylus.MiuiStylusBleHelper` 用
`bindService` 连它。收到笔的上报后：

```
L2() -> STYLUS_STATE_ATT          M2() -> STYLUS_BATTERY_NOTIFY
N2() -> STYLUS_STATE_SOC          O2() -> STYLUS_PLACE_ERROR
```

pad8p 完整链路：

```
笔吸附/唤醒 → BLE MIPP 连上 → oobhelper 上报 SOC / 充电 / 连接状态 → 广播
   → SecurityCoreAdd 弹「笔形电量条 + ⚡xx%」胶囊
```

TB378FC 上这支联想笔走普通 BT HID（HOGP），不说 MIPP，oobhelper 永远不发 → 胶囊永远不出现。
**缺口就在这，补法就是替它发广播。**

---

## 3. 触发方法（三种，从底层到模块）

### 3.1 手动直接发（验证/调试用，root 或 shell 均可）

```bash
adb shell am broadcast \
  -a com.android.settings.stylus.STYLUS_STATE_SOC \
  -n com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver \
  --ei battery 88 --ei state 4 --ei connect 5
```

### 3.2 触发模块那条路径（等于把笔吸上去时守护做的事）

```bash
# root 侧守护 → PenBridge（会读线圈电量，再补一次 GATT 真值）
adb shell su -c 'am broadcast --user 0 \
  -n dev.tb378fc.stylus/.WakeReceiver -a dev.tb378fc.stylus.ATTACH \
  --ei battery 88 --ei state 4'
# 或者直接把磁吸状态机的边沿走一遍：吸附笔即可（attached 0 -> 1）
```

### 3.3 模块自动触发（正常使用，v3.1 的快路径）

```
/sys/class/power_supply/wls_tx/attached  0 -> 1（吸附）
  └─ service.sh --monitor：POLL_MS=200 轮询（shell 内建 read，几乎零成本）
       └─ 立刻读 wls_tx/level（最多重试 4×0.2s 等线圈握手）
            └─ 守护**直接**发原生广播（CAPSULE_DIRECT=1，省掉 App 一跳）：
                 am broadcast -a com.android.settings.stylus.STYLUS_STATE_SOC \
                   -n com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver \
                   --ei battery <线圈值> --ei state 4 --ei connect 5
                 → 原生胶囊立刻出现
            └─ 再转发 dev.tb378fc.stylus.ATTACH（battery=-1, coil=<线圈值>）给 PenBridge
                 └─ PenBle.readBattery()（GATT 0x180F/0x2A19）
                      └─ 真值 != coil 才补一条校正（相同不重复弹）
```

### 3.4 延迟都花在哪（实测分解）

| 环节 | 第一版 | v3.1 | 能不能再省 |
|---|---|---|---|
| **线圈硬件握手**：`attached` 0→1 | 2.0 s | 2.0 s | ❌ 硬件，笔放上去后线圈要启动+握手，实测固定 ~2 s |
| 检测到边沿 | 主循环 `sleep 1` → 最坏 1.0 s | `POLL_MS=200` + 内建 `read` → 最坏 0.2 s | ✅ 可调 `POLL_MS=100/50` |
| 等线圈读出电量（`level` 变有效） | 被固定 `sleep 2` 掩盖 | ~0.5 s（`level` 在 `attached` 之后约 0.5 s 才有效） | ⚠️ 用缓存值可跳过 |
| 发广播 | 先冷启动 PenBridge 再转发 → 0.3~1 s | 守护直发（`CAPSULE_DIRECT=1`）→ 0.2~0.4 s | ✅ 已优化 |
| **合计（从笔放上去算）** | **≈4~5 s**（用户感知 ~3 s） | **≈2.9 s** | 见下 |

**想更快只剩两条路**（都还没做，见 README 的选项）：

1. **线圈启动边沿 + 缓存电量**：笔一放上去线圈会先 `online` 1→0 / `level` 归 0（比 `attached=1` **早约 2 s**）。
   在那一刻就用**上一次的 `level`** 先弹一条，真值到了再刷新 → 感知延迟 **≈0.3 s**，代价是
   第一眼可能是旧数字（例如上次 100%、这次其实 60%）。
2. **装回 LSPosed hook**：`InputDevice.getBatteryState()` 是公开 API，装好 hook 后 0 ms 就能拿到
   真实电量 + 充电状态，连 GATT 都不需要（也就不需要"补一条校正"）。但它救不了那 2 s 硬件握手。

---

## 4. 参数表

发往 `com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver` 的
`com.android.settings.stylus.STYLUS_STATE_SOC`：

| extra | 类型 | 取值 | 默认/非法值 | 说明 |
|---|---|---|---|---|
| `battery` | int | `0..100` | — | 胶囊里显示的电量数字。**非法值（<0 或 >100）本模块不发**，否则窗口会渲染 "-1" |
| `state` | int | `4` = 充电中（图标带⚡）；`2` = 未充电 | 本模块吸附时固定 `4` | 来自 MIPP 的充电 notify（`f11787A`：4/2） |
| `connect` | int | `5` = 已连接 → **直接弹电量胶囊**；`0/1/3/4/7/8/9` 见 §1 映射表 | `5` | **只有 5 会直接弹**；`2` 仅在当前正显示"连接中"时才升级 |

本模块内部还多一层 `dev.tb378fc.stylus.ATTACH`（守护 → App），参数：

| extra | 类型 | 取值 | 说明 |
|---|---|---|---|
| `battery` | int | `0..100` 或 `-1` | 要立刻弹的数字；`-1` = "别弹"（守护直发模式下已弹过，或线圈值不可用） |
| `coil` | int | `0..100` 或 `-1` | 守护已用线圈值弹过的数字；GATT 真值等于它就不补弹（避免重复弹窗） |
| `state` | int | `4` / `2` | 透传给 `STYLUS_STATE_SOC` |
| `mac`（可选） | string | 笔的蓝牙地址 | 不传则 App 按已配对名含 `Tab Pen` 或 `/data/adb/penwake/mac` 找 |

### 相关 config 开关

| 键 | 默认 | 作用 |
|---|---|---|
| `CAPSULE` | `1` | 吸附是否弹胶囊（也可用 `disable-capsule` 标记单独关） |
| `POLL_MS` | `200` | 吸附检测轮询间隔；直接决定"吸上去多久才弹" |
| `CAPSULE_DIRECT` | `1` | 守护直发原生广播（少一跳）；`0` = 只发 ATTACH 交给 App |
| `CAPSULE_GATT` | `1` | 直发后再用 GATT 读真值，**不同**才补一条校正；`0` = 只信线圈值，不补弹 |

### 电量从哪来

| 来源 | 谁读 | 取值 | 特点 |
|---|---|---|---|
| `wls_tx/level` | `service.sh`（root） | 0..100 | 反向无线充电线圈看到的笔电量，**零延迟**；**取下时保留上一次的值**（实测吸附前读 100），握手瞬间会短暂为 0 |
| `InputDevice.getBatteryState()` | PenBridge（公开 API，无需权限） | `isPresent/getCapacity/getStatus` | 最快最准且自带充电状态，**但依赖 LSPosed hook**（PenStylusHook 把数字板与蓝牙笔关联起来）。没装 hook 时 `dumpsys input` 里是 `NativeBattery=State{<not present>}, BluetoothState=null` |
| GATT `0x180F/0x2A19` | PenBridge（普通 App） | 0..100 | 标准电池服务，真实但要连一次 BLE（1~3 s）；读到不同值会补发一条校正 |
| `dumpsys bluetooth_manager` | — | 只有 `BatteryStateMachine state=Connected` | **没有电量数字**，不能当来源 |

### 吸附时的实测时间线（0.5 s 采样，`wls_tx/*`）

| 时刻 | `attached` | `level` | `charge_state` | `online` | 含义 |
|---|---|---|---|---|---|
| 放置前 | 0 | 100 | 2 | 1 | 取下状态：level 是**上次的值** |
| t≈+0 s | 0 | 0 | 0 | 0 | 线圈启动、开始握手 |
| t≈+2.0 s | **1** | 0 | 0 | 1 | `attached` 才置 1 —— **这 2 秒是硬件握手，软件省不掉** |
| t≈+2.5 s | 1 | **100** | 0→1 | 1 | 线圈读到电量；`charge_state=1` |
| t≈+42 s | 1 | 100 | 2 | 1 | 充满/涓流，`charge_state` 回到 2 |
| 取下 | 0 | 100 | 2 | 1 | — |

`charge_state` **线圈自己的枚举**：`1` = 充电中，`2` = 未充电/充满
（MIUI 那边 `state` 用的是 `4` = 充电中 / `2` = 未充电，**不是同一套编号**，别混用）。

### 前置条件（缺一不可，模块自动处理）

1. `settings put secure stylus_first_connect 1`（`touch_film_stylus_first_connect 1` 同理）
   —— 否则走"首次连接引导"分支，只打日志 `First time connect ,let user look instruction`，不弹电量胶囊。
   模块在 `service.sh --monitor` 启动时（`prepare_stylus_settings`）自动补写，只写没设过的那次。
2. `settings get secure setting_stylus_version` **非 0**（本机为 `1`）。为 0 时代码判定
   "stylus input device has not been created"，事件延后 50 ms 再投，实际不会弹。

---

## 5. 代码落在哪

| 文件 | 作用 |
|---|---|
| `module/service.sh` | `--monitor` 里按 `POLL_MS` 轮询 `attached` 的 0→1 边沿；`send_attach()` 读 `wls_tx/level` 后**直发** `STYLUS_STATE_SOC`（`CAPSULE_DIRECT=1`），再按需转发 `ATTACH` 做 GATT 校正；`prepare_stylus_settings()` 补两个引导标记 |
| `app/PenBridge/src/…/WakeReceiver.java` | `ACTION_ATTACH`：`coil`/`battery` 两个 extra 决定"要不要立刻弹"，GATT 真值不同才补一条 |
| `app/PenBridge/src/…/Capsule.java` | 组装并发送 `STYLUS_STATE_SOC`（`battery/state/connect=5`），带范围校验 |
| `app/PenBridge/src/…/PenBle.java` | `readBattery()`：GATT 连笔 → 读 `0x180F/0x2A19` → 断开，返回 `-1` 表示读不到 |
| `module/config` | `CAPSULE` / `POLL_MS` / `CAPSULE_DIRECT` / `CAPSULE_GATT`；`disable-capsule` 标记只关胶囊、保留唤醒 |

---

## 6. 排障

```bash
# 1) 广播到底发了没有（模块侧）
tail -n 20 /data/adb/modules/tb378fc_hyperos_fix/wake.log
#    正常应看到： attach-capsule sent (battery=88 state=4 coil_chg=2)
#                ATTACH coil battery=88 state=4 shown=true
#                ATTACH gatt … battery=86 …

# 2) 原生侧收没收、弹没弹
adb logcat -s MiuiStylusBatteryManager:* PenCapsule:* PenWake:*
#    关键行： From source: bluetooth batteryLevel : 88 stylusState : 4 connectState : 5
#            Battery window attached

# 3) 窗口在不在
adb shell dumpsys window windows | grep -A3 StylusBattery
#    pkg=com.miui.securitycore ty=NAVIGATION_BAR_PANEL gr=TOP CENTER (0,y)(w x h)

# 4) 模块状态总览（KernelSU 的「操作」按钮也是这个）
su -c 'sh /data/adb/modules/tb378fc_hyperos_fix/action.sh'

# 5) 单独验胶囊（绕过守护）
adb shell am broadcast -a com.android.settings.stylus.STYLUS_STATE_SOC \
  -n com.miui.securitycore/com.miui.miinput.stylus.MiuiStylusReceiver \
  --ei battery 66 --ei state 2 --ei connect 5
```

常见现象：

| 现象 | 原因 |
|---|---|
| logcat 只有 `First time connect ,let user look instruction` | 两个引导标记没写（§4 前置条件 1） |
| 什么都不打，logcat 也没有 `From source:` | 广播没送到：组件名写错 / `connect` 不是 5 且当前没有"连接中"窗口 |
| 胶囊显示 `-1` | `battery` 非法还硬发；本模块会跳过 |
| `ATTACH … shown=false` | 线圈值是 `-1`，且 GATT 没读到电池服务（笔不支持或不在附近） |

---

## 7. 踩坑（别踩）

- **别发 `STYLUS_BATTERY_NOTIFY` 的 `battery=80`**：走 `d0.h(80, true)` →
  `miui.util.IMiCharge.setWirelessChargingEnabled(true)`，**真的会开反向无线充电**。
- **别发 `connect=9`**：会 `setWirelessChargingEnabled(false)`。这两个是唯一会碰充电硬件的路径。
- `connect=2` 不弹胶囊（只在已有"连接中"窗口时升级），要弹就用 `5`。
- 低电量分支（`STYLUS_BATTERY_NOTIFY`）：`battery=0/5` → "连接失败，无电量"；`battery=10/20` → 低电量胶囊；
  `battery=80` → 见上，别碰。
- 宿主必须是 `com.miui.securitycore`（系统应用），窗口 type 2024 需要系统权限；普通应用只能发广播，
  这正是"让原生去画"的意义。
