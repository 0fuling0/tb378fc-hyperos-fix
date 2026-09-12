# ZUXOS（联想原厂）手写笔协议 + 官方唤醒时机

对象：`TB378_ZUXOS_2.0.10.252`（`/nosnap/gt13/gt13-zuxos/`）。
解包注意：`image/super_*.img` **不是** super 分区切片，而是各逻辑分区镜像本身
（`super_2=odm`、`super_3=product`、`super_4=system`、`super_5=system_dlkm`、`super_6=system_ext`、
`super_7=vendor`、`super_8=vendor_dlkm`，都是 ext4，`super_1` 才是 LP 元数据），
所以直接用 `debugfs` 读，不需要 `lpunpack`：

```bash
debugfs -R "dump /system/framework/services.jar /tmp/framework.jar" image/super_4.img
```

笔逻辑在 **`system/framework/services.jar` → `com.zui.server.input.styluspen.*`**（105 个类，跑在 system_server），
外加 `/system/priv-app/PenService`（`com.lenovo.penservice`）、`ZuiAIStylus`。

---

## 1. 三条 GATT 通道

| 通道 | Service / Characteristic | 用途 |
|---|---|---|
| 控制 | `0000fe40-cc7a-482a-984a-7f2ed5b3e512` / `0000fe41-…`（代码名 `PARKER_SENSOR`，也复用成 6DOF switch） | 唤醒/睡眠/屏幕开关/捏合/笔尾等配置 |
| 马达 | `00000000-000f-11e1-9ab4-0002a5d5c51b`：REQ_INF `…0002`、CON `…0006`、IMP `…0008`、INF_NOTIFY `…000a`、SWITCH `…000e` | 笔内振动/音效 |
| 6DOF | `00000000-699b-404a-a48e-6254941b956b` / `00000001-699b-…` + CCCD `0x2902` | 笔的空间姿态数据 |

## 2. FE41 控制帧（`BluetoothPenUtils`，格式 `{组, 命令, 参数…}`）

| 帧 | 构建方法 | 含义 |
|---|---|---|
| `{5,5}` | （`wakeupOrSleepParker` 直接写） | **唤醒笔** |
| `{5,3}` | `buildPadCloseTxValues` | **深睡 / 关线圈 TX** |
| `{5,2}` / `{5,1}` | `buildScreenOnOffCmd` | 告诉笔"平板屏幕亮/灭"（Parker2 多一字节 `0`） |
| `{5,6,x}` | `buildQuickNoteCmd` | 息屏速记开关 |
| `{8,4}` / `{8,5}` | `buildTouchfilmModeCmd` | 触控膜模式 A/B |
| `{8,5,1..5}` | `buildSqueezeForceCmd` | **捏合力度**（1 轻…5 重） |
| `{8,4,3,0/1}` | `buildSqueezeEnableCmd` | 捏合使能 |
| `{8,6,mask}` | `buildTouchfilmEnable` | **触控膜功能位：笔上报哪些手势的总开关**（见 §2.1） |
| `{8,7,x}` | `buildTailConfigCmd` | **笔尾按钮功能配置** |
| `{10,0/1}` | `buildEraserBackCmd` | 笔尾橡皮擦回传（267 切橡皮→`{10,1}`，11 切回笔→`{10,0}`） |
| `{12,0}` | `buildPadIdCmd` | 取 ID |
| `{3,1,1,1}` | `writeActiveInfoFlag` | active info |
| `{6,1}` / `{6,0}` | `setParker6DofSwitch` | 6DOF 通知开关（开时连带写 CCCD） |
| `{2,2}` | `forceRebootParkerPen` | **强制重启笔**（设置项 `reboot_connected_parker_pen`） |

### 2.1 `{8,6,mask}` 触控膜功能位（手势总开关）

`BluetoothPenUtils.buildTouchfilmEnable(double, triple, slide, remote, squeeze, tail)`
（从 `services.jar` 字节码逐条解出来的，`or-int/lit8` 常量如下）：

| 位 | 值 | 手势 |
|---|---|---|
| bit0 | `0x01` | 双击 |
| bit1 | `0x02` | 三击 |
| bit2 | `0x04` | 上滑 |
| bit3 | `0x08` | 下滑 |
| bit4 | `0x10` | 捏合 |
| bit5 | `0x20` | 笔尾 |

- `slideEnable` 一次把 **0x04|0x08** 都置上（两个方向各一位）；
- `remoteEnable`（遥控模式）置 **0x0D** = 双击|上滑|下滑；
- **全开 = `{8,6,0x3F}`**；**全关 = `{8,6,0x00}`** → 笔从此不再上报双击/上滑/下滑/捏合
  （笔尖写字、按键不受影响），现象就是"手势突然全都没反应"，只能重发 mask 恢复。

**原厂什么时候发**：`BluetoothPenInputManager.setPenSwitchCmd()` —— 连接建立时（`BluetoothPenInputManager:99`）
以及每次相关设置变化时（`:146-166`）都发一次**全量 mask**。来源设置项：

| 设置 | 默认 | 位 |
|---|---|---|
| `Settings.Global pen_touch_film_tap_two` | 1 | 双击 |
| `Settings.Global pen_touch_film_copy_paste` | **0** | 上滑/下滑 |
| `Settings.Global pen_touch_film_squeeze` | **0** | 捏合 |
| `Settings.Secure pen_set_remote_control_on` | 关 | 0x0D 遥控 |
| `Settings.Global pen_click_tail_action`(1) / `pen_click_twice_tail_action`(0) | 1 / 0 | 笔尾 |
| `Settings.System touchfilm_mode_config` | — | 触控膜模式 A/B |

也就是说原厂默认只开"双击 + 笔尾"，上滑/下滑和捏合要在设置里打开。**HyperOS 上没有 ZUX 栈，
没人发这一帧**，所以要么模块自己在唤醒/吸附流程里补发（建议 `{8,6,0x3F}`），要么用试验台手动发。


## 3. 马达帧（`ZuiPenHapticUtils`）

| 帧 | 特征 | 含义 |
|---|---|---|
| `{1}` | REQ_INF `…0002` | 请求笔信息 |
| `{type, level, lo, hi, 0, 0}` | IMP `…0008` | 冲击式振动 |
| 4 字节（含摩擦感开关位） | CON `…0006` | 连续式振动 |
| `{0,0,0,0}` | IMP | 停止 |
| `{i}` | SWITCH `…000e` | 振动总开关 |
| `{6,0/1}` | 6DOF switch char | 6DOF 数据流开关 |

波形 ID：`0 STOP / 1 CLICK / 2 CONNECTED / 3 HAPTIC_ENABLED / 4 BRUSH_CHANGE / 5 TEXT_INPUT_FOCUS /
6 RECOG_FINISHED / 7 PRESS / 32 BALLPEN / 33 PENCIL / 34 CHISEL_MARKER / 35 ERASER / 36 LENOVO_BRUSH /
37–41 为同名 "NS"（无音效）变体 / 42 EDGE_WARNING`。
参数范围：level 0–5、repeat 1–10、cutoff 0–300ms、type `0=IMPACT / 1=CONTINUOUS`。

## 4. 官方什么时候主动唤醒笔

```
UEventObserver(match "UEVENT_TO=PEN_FRAMEWORK")      ← BluetoothPenConnectPolicy.getUEventObserverPath()
   ↑ 注册于 StylusPenInputManager:248
onUeventReceved(uevent)                              ← 字段：TYPE(QI/NFC/TP)、ATTACHED、MAC、LEVEL、
   │                                                          PEN_TYPE、CHARGING_STATE、WRITEPENDATA、WRONGLOCATION
   └─ checkChargeStateFull(mac, chargeState, connectState, attached)
        ├─ attached == 0（笔离开线圈）且 MAC 与已连接笔一致 → 写 {5,5} 唤醒（mParkerDeepSleep=false）
        └─ chargeState == 3（充满）且 MAC 一致            → 写 {5,3} 深睡（mParkerDeepSleep=true）
```

充电状态枚举：`0 未知 / 1 充电中 / 2 未充电 / 3 充满 / 4 高温停充 / 5 低温停充 / 6 低电量`。
笔型号：`1 Tab Pen Plus(Picasso) / 2 Tab Pen Pro(Parker) / 3 Precision Pen 3(Sheaffer) / 4 Tab Pen Pro 2(Parker2)`。

**结论：官方就是"笔从磁吸/线圈上取下的那一刻"主动发 `{5,5}` 唤醒；充满后发 `{5,3}` 让它深睡。**
这正是本模块 ①（取下边沿发 `{5,5}`）的做法；官方靠内核 uevent，我们用轮询 `wls_tx/attached`。

## 5. 那条 uevent 是谁发的、为什么我们没收到

- `qi_battery_charger.ko`（`vendor_dlkm`，与移植包里的**逐字节相同**）里就是 Lenovo 的笔链路代码：
  `nm` 显示它调用 `kobject_uevent_env`；反汇编 `qi_uevent_report()`（0x2f00–0x3508）确认：
  先 `_dev_info("[LENOVO_PEN]pen_uevent:…")`，再 `kobject_uevent_env(kobj, KOBJ_CHANGE, envp)`（0x34f4）。
- 实测内核日志（`dmesg`）每 ~0.8 s 一条，字段齐全：
  ```
  [LENOVO_PEN]qi_uevent_report tx:1 hall1:1 hall2:0 hall3:1
  [LENOVO_PEN]pen_uevent:UEVENT_TO=PEN_FRAMEWORK, mac:MAC=DC:EB:4D:06:E0:95, level:LEVEL=100,
      attach:ATTACHED=1, charging_state:CHARGING_STATE=Charging, type:TYPE=QI, pen_type:PEN_TYPE=2,
      qi_pen_location_string: , qi_pen_foreign_string:FOREIGN=0
  ```
  （`attached` 由 **hall1/hall2/hall3** 三个霍尔判定。）
- 但是！用标准 netlink（`NETLINK_KOBJECT_UEVENT`，group 1，和 Android `UEventObserver` 同样的绑法）
  抓了整轮吸附/取下，**只收到 `power_supply/wls_tx` 的心跳事件**（内容只有 `POWER_SUPPLY_ONLINE=1`），
  `PEN_FRAMEWORK` 一条都没有 —— 也就是说这条 uevent 在本机没有真正广播出来
  （`kobject_uevent_env` 的 `kobj` 为空 / `uevent_suppress`，或只在特定条件下才发）。
  `nvt_36xxx.ko` 里还有另一条 `UEVENT_TO=PEN_FRAMEWORK TYPE=TP`（触控板侧），同样没抓到。
- `/dev/lenovo_penraw`（major 492）是 **只读 + 只能 ioctl** 的字符设备（`cat` 直接 `EINVAL`），
  实现就在 `nvt_36xxx.ko`（符号 `penraw_open/penraw_ioctl/penraw_fops`），由联想触控 HAL 使用，
  不是能直接读的数据源。

**对我们的意义**：换不成事件驱动，继续用 200 ms 轮询 `wls_tx/attached|level`（值一样）；
但官方还有两件我们能照抄的事：

1. **充满后发 `{5,3}` 让笔深睡**（省笔的电）——目前模块只做唤醒，没做这个。
2. `charge_state` 语义对齐：线圈的 `charge_state` 1=充电中 / 2=未充电（充满后回 2），
   与官方的 `CHARGING_STATE` 字符串（Charging/Full/Not charging…）是两套表示。
