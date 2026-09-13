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

## 5. 移植 ROM 自带的老笔桥要停掉

`/system/etc/init/init.lwky.rc` 里有一个 `lwky_pen` 服务（`/system/lwky/penbridge_hyperos`），
在 `sys.boot_completed=1` 时启动，是移植 ROM 作者写的旧桥：

* 造的是 **type 1**（`0x1915/0xEAEA`）虚拟笔 → HyperOS 的触控膜分支根本不认；
* 按它自己的映射往笔上灌 **PAGEUP/PAGEDOWN(92/93)** → 92/93 在 MIUI 里是"截图键/速记键"，
  于是会出现"一捏就待命截图"这类怪行为，还会和 penring 抢着注入。

所以模块的 setup 阶段会额外拉起一个 `--stoprompen` 看护：`setprop ctl.stop lwky_pen` +
`pkill -x penbridge_hyperos`，并且每 30 秒复查一次。不想要这个行为就建 `disable-rompen` 标记文件。

（`lwky_touchfeature` 那个假 HAL **不要停**：MIUI 的 `ITouchFeature.setTouchMode()` 需要它返回成功。）

## 6. 笔尾 = 橡皮：结论是"小米这两个 App 里做不到"，已放弃

**目标**：翻到橡皮端时 App 自己也把工具切成橡皮。

**今天查到的真相**（早先那版"判定在 native 层、Java 钩子不可行"的说法不准确，已作废）：

| 事实 | 证据 |
|---|---|
| 内核/框架**本来就报**橡皮端 | `getevent`：`BTN_TOOL_RUBBER DOWN/UP`；App 里 `MotionEvent.getToolType()` 实测返回 **4 = TOOL_TYPE_ERASER** |
| App 是**在 Java 层**读 tool type 的 | 钩子里能收到 `getToolType` 调用（`com.miui.notes`），"无条件改成 ERASER 会把绘制搞坏"也说明它确实按这个值决定工具 |
| 但**笔记不吃这一套** | 框架报 ERASER(4) 时笔记照样出墨（它认的是别的约定） |
| **创作更糟** | 框架报 ERASER(4) 时它进了橡皮分支但绘制管线卡住 —— 既不画也不擦 |
| 伪造 `BUTTON_STYLUS_PRIMARY(32)`（含 `getActionButton`） | 两个 App 依旧出墨 —— 绘制在 native 里读原始 InputEvent，Java 层改的位到不了 |
| MIUI 自己的"笔快捷键动作表"存在 | `com.miui.securitycore` 的 integer 资源（中文串是 UTF-16，`strings` 查不到，要 `aapt dump --values`）：`0=关闭触控膜 1=笔刷/橡皮切换 2=切回上一支笔 3=调色盘 4=笔刷参数 5=快捷功能` |
| 但那条动作**只能被"笔快捷键"触发** | `stylus_double_click_status` 由框架(`miui-services.jar`)＋**App 自己**读；执行方是 App。想用它就得把双击设置改成 1 —— 那会破坏用户原本的双击功能（当前是 4=笔刷参数），用户明确不接受 |

**试过并已全部撤掉的方案**（代码已清理干净）：

1. `getToolType` 无条件/按笔尾报 `ERASER` —— 笔记不理、创作卡住
2. 伪造 `getButtonState/getActionButton = BUTTON_STYLUS_PRIMARY(32)` —— 两个 App 都照画出墨
3. 笔尾靠近 → 注入双击键（195）＋把双击设置改成 1 —— 能借用 App 的切橡皮代码，但**破坏双击**，用户否掉
4. 注入瞬间只在 App 进程里把 `stylus_double_click_status` 伪装成 1（1.2 秒窗口）—— 用户叫停，未验证，代码已撤

**结论**：小米焦点触控笔本身**没有笔尾橡皮**，MIUI 只为它实现了"侧键/快捷键→切笔"，所以笔记/创作里没有"橡皮端"这条路径可走。

**保留的**：笔尾靠近 → 我们自己给笔发波形 35（橡皮手感）、翻回笔尖恢复当前笔刷（见 §7），
以及排障用的注入原语：

```bash
M=/data/adb/modules/tb378fc_hyperos_fix
$M/bin/penring --moddir $M --key 195     # 往 type-8 虚拟笔注入一次原始键（195=双击/194=轻捏/196,197=上下滑/92=笔尾键）
```

**如果将来要重开这条线**，两个候选方向：

1. **输入层**：penring 抓住 `/dev/input/event5`（`EVIOCGRAB`），造一个同能力的虚拟数字化器
   （ABS_X/Y/PRESSURE/TILT、`INPUT_PROP_DIRECT`）把事件原样转发，并在笔尾感应时附加 `BTN_STYLUS`
   —— 这是唯一能让 native 绘制路径看到"侧键按下"的办法；代价：可能影响笔迹/压感/防误触，必须做成可一键回退。
2. **继续挖 App 内部**：找到笔记里"切橡皮"那段（它读 `stylus_double_click_status` 后执行），
   直接调用它 —— 需要在 App 进程里定位那个方法（混淆，得靠 jadx + 运行时探测）。

## 7. 构建 / 安装 / 自检

```bash
./build.sh                 # 会同时构建 TbFix.apk 与 bin/penring
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

---

## 8. 看护进程（brushwatch）为什么会"没自动启动"

症状：开机后笔刷触感/笔尾切橡皮完全没反应，`ps` 里看不到 `service.sh --brushwatch`，
但 supervisor / monitor / penring 都在。三个独立的坑，任何一个都能让它静默消失：

1. **函数整段丢失 → 静默 not found。**
   一次误操作把 `brushwatch_ensure()` / `brushwatch_alive()` 两个定义删掉了，只留下调用点。
   `sh` 对未定义函数的反应是打一行 `brushwatch_ensure: not found` 继续往下跑 —— 于是
   monitor 每轮都"调用成功"，看护永远起不来，日志里看不出任何异常。
   → 现在构建期跑 `tools/check-helpers.py`（剥离引号与 `$(( ))` 后比对"被调用 vs 已定义"），
   并 `sh -n` 语法检查，这类问题在打包前就报错。

2. **"先扫描、后谦让"的竞态 → 两个都退出。**
   supervisor 和 monitor 都会调 `brushwatch_ensure`。原实现是"扫描全表，发现有别的
   brushwatch 就退出"——两个并发实例各自看到对方，双双退出，看护静默消失。
   → 改成 **`mkdir $BRUSH_LOCK` 原子抢锁**：抢到的人才是实例，永不反悔；抢不到的人再扫进程表，
   有活人就退出，没活人（陈旧锁，持有者被 `kill -9` 过、trap 没执行）就清掉重抢，最多 5 次。

3. **只看 pid 文件 → 孤儿进程骗过判定。**
   看护是 `setsid` 出来的，supervisor/monitor 被重启后它们变成孤儿继续活着；此时 pid 文件
   已被覆盖或删除，`kill -0` + pid 文件会误判成"没有实例"，于是又拉一份 → 两份各按自己
   那份代码判定、各往笔里写波形（实测出现过）。
   → 存活判定改成 **扫进程表** `ps -A -o PID,ARGS`（一次 fork），并且必须同时满足
   `$2` 是 shell **且** cmdline 命中 `$MODDIR/service.sh --brushwatch` —— 否则
   `timeout 8 /system/bin/sh service.sh --brushwatch` 这类包装进程也会被当成实例。
   启动阶段（`service.sh` 无参分支）再加一次**接管**：清掉上一轮遗留的 brushwatch / penring 孤儿。

另外两处随之修掉的健壮性问题：

- **内层循环空转。** 内层 `while :; do read -t 2 ...; done` 在 `penring --watch`
  死掉后 `read` 会立刻返回失败 → 空转，而且每轮都跑 `brush_exit_check`（里面有 `dumpsys`），
  几秒内几千次 fork。现在 read 失败时每 3 次做一次进程表检查，`--watch` 没了就跳出内层让外层重建。
- **监控自愈。** monitor 是唯一常驻不退出的循环，现在每 2 秒跑一次
  `penring_ensure; brushwatch_ensure`，看护被杀/崩溃后 ≤2 秒重生。

### 排障速查

```sh
M=/data/adb/modules/tb378fc_hyperos_fix
# 实例与子进程（正常：1 个 --brushwatch 父 + 1 个 fork 子（cmdline 相同）+ 1 个 penring --watch）
ps -A -o PID,PPID,ARGS | grep -E "service\.sh --|penring"
cat $M/brush.pid; ls -d $M/brush.lock          # pid / 锁
tail -f $M/wake.log                            # 启动与自愈：brushwatch started / already running
tail -f $M/brush.log                           # 波形判定：send? ... / wave=NN

# 真实 fork 压力（归属测试：模块全停 vs 运行）
awk '/^processes/{print $2}' /proc/stat        # 前后各读一次，差值 / 秒
```

**不要用"逐个 `/proc/<pid>/cmdline` 去 tr+grep"判活**：300+ 进程时每次调用要 600+ 次 fork，
两秒一轮就能把 pid 耗尽（实测 pid 从 30000 绕回到 663、load 12）—— 必须用一次 `ps` 全表 + `awk`。

### 8.1 第四个坑：开机太早 → 监听挂不上，看护"活着但瞎"

改完上面三条后，重启仍表现为"没反应"，但这次 `ps` 里看护明明在跑。看 `brush.log` 才发现：

```
06:53:16 watch: inotify_add_watch(/data/data/com.miui.notes/files) 失败: No such file or directory
06:53:16 watch: inotify_add_watch(/data/data/com.miui.creation/files) 失败: No such file or directory
```

**KernelSU 的 `service.sh` 在 CE 存储解锁挂载之前就跑了**（这次开机 20 秒），
`/data/data/<pkg>` 还不存在 → `inotify_add_watch` 全部失败，而老实现失败后**永不重试**：
进程活着、poll 循环照跑，但一个事件都收不到。上层 `brush_watch_loop` 因为收不到 `FILE ...`
自然也不发波形 —— 现象和"看护没启动"完全一样，所以前三次都猜错了方向。

两层修复：

1. `penring --watch`：失败的目录记在 `wds[i] = -1`，poll 的 1 秒超时分支里每 ~3 秒补挂一次
   （日志出现 `watch: 补挂 <dir>`）；触控节点 `open` 失败也一起补开。
2. `brushwatch_ensure`：等 `BRUSH_APPS` 里任一 `/data/data/<pkg>` 出现才启动看护（省掉一轮无效工作）。
   实测现在开机能看到 5 个目录全部 `watch: 盯住 ...`。

顺带清掉一个日志噪声：`penring` 的 `logf_` 既写 stderr 又写 `--log` 指定的文件，而看护进程的
stderr 也重定向到同一个 `brush.log` → 每条日志重复两遍。现在管道里给 `penring --watch` 加了
`2>/dev/null`。

### 8.2 排障时最容易看错的地方

- `penring.log` 是**旧版**的日志名，现在手势桥写的是 `$MODDIR/wake.log.ring`。
- `action.sh`（KernelSU「操作」）里的 ① 是 **supervisor** 的 pid，不反映 brushwatch。
- 判断看护是否"真活着"要看两处：`ps` 里有 `service.sh --brushwatch` + `penring --watch`，
  并且 `brush.log` 里有 `watch: 盯住 /data/data/com.miui.creation/files`（挂上了监听才算活）。

---

## 9. 休眠档：吸附在平板上且充满 → 让笔真睡

### 起因

实测夜里把笔吸在平板上，早上电量掉到 83%。日志量化到原因：

```
settings-sync 2687 次 / 2.5 小时 ≈ 每 3.3 秒一次     ← 每次都是一条 BLE {5,5} 唤醒命令
```

那个 spam 本身是另一个 bug（`sync_pen_settings` 把 `last_lvl` 当成"上次轻捏力度"，
而 monitor 主循环里 `last_lvl` 是无线线圈电量 0..100，两者永不相等 → 每次都判定"设置变了"，
见 §8.3 的命名教训）。修完之后周期性唤醒只剩"开机一次"和"取下时一次"，
但**只要笔还吸在平板上，就没有理由让它一直保持可唤醒状态** —— 于是加了这一档。

### 行为

| 条件 | 动作 |
|---|---|
| **主判据**：`attached=1` 且 `charge_state` 曾为 1、现在为 0 且持续 ≥ `REST_IDLE`（默认 20）秒 | 进入休眠档：写 `pen.rest=1`；发一次 `--brushstop` 清掉可能 latch 的 CON 波形；广播 `dev.tb378fc.fix.REST --ei on 1` |
| **兜底判据**：`attached=1` 且线圈电量 ≥ `REST_FULL`（默认 99） | 同上（有的笔端在 100% 之前就停充，或 `charge_state` 读不到时用） |
| 休眠档中 | 不发任何唤醒/设置同步；胶囊只走本地直发、不再让 App 走 GATT 读笔；`brush_send` 跳过非停止帧；线圈电量/充电状态轮询降到 `REST_POLL`（60）秒 |
| 笔取下，或线圈**重新给笔补电**（`charge_state=1` 且电量 < `REST_FULL`） | 退出休眠档：`pen.rest=0`，广播 `REST on 0`，下一次设置同步会把真值补发一次 |

为什么用 `charge_state` 而不是拍一个电量阈值：它就是"充满/停充"的权威信号（笔端 Qi 接收芯片
充满后自己终止取电，驱动随即报 0），不用猜某个机型的"满"是 99 还是 100。但**不能只看
`chg=0`** —— 刚吸上去那几秒握手还没起来、`chg` 也是 0（实测采样第一条就是
`att=1 lvl=0 chg=0 tx_iin=0`），只看 0 会一吸上就误判成"充满"。所以要求"这一轮吸附期间
先见到过 `chg=1`"。出档同理不能用"电量低于阈值"：进档判据是"停充"，两者会互相打架
（90% 停充 → 进档 → 立刻因 <95 出档 → 再进档，20 秒一跳）。

**本机实测的一个反例**（所以两种判据都得留着）：笔已经 100% 时线圈报的仍是
`att=1 lvl=100 chg=1 tx_iin=296` —— 驱动在满电后依然保持 `chg=1` 持续补电，
"chg 1→0"这个事件根本不会出现，真正让它进档的是电量兜底判据（≥99）。
反过来，出档条件里也必须带 `lvl < REST_FULL`，否则"满电 chg=1"会每 60 秒把休眠档踢掉再进。

App 侧（`PenBle.restMode`）收到广播后**立刻断掉"留给下一条手势"的那条缓存 GATT 连接**
（`sHGatt`）—— 那条连接平时是为了让下一条手势 ~20ms 就能写下去才留着的，
但笔都躺在平板上充电了，留着它只会让笔的控制器进不了最深那档低功耗。之后有手势/波形时
`quickHaptic` 会自然重连，用户无感。

开关：`config` 里 `PEN_REST=0`，或标记文件 `disable-rest`。

### 配置与排障

```sh
M=/data/adb/modules/tb378fc_hyperos_fix
# 判定逻辑自测（不改状态、不发广播）
sh $M/service.sh --restcheck 1 100     # → 进入休眠（吸附且 100 ≥ 99）
sh $M/service.sh --restcheck 1 97      # → 保持现状（95~98 之间）
sh $M/service.sh --restcheck 0 100     # → 不休眠（已取下）
# 手工强制/解除（真机验证 App 断连、波形停止用）
sh $M/service.sh --rest 1 ; cat $M/pen.rest ; sh $M/service.sh --rest 0
# 看它有没有真的进档（自动进入时）
grep "pen rest" $M/wake.log | tail
logcat -d | grep -E "PenWake.*rest" | tail    # 期望：rest: dropped idle gatt link=true/false
```

### 为什么不做"把线圈关掉"

笔的充电线圈由**联想 vendor 的充电驱动**管（`wls_tx` 挂在 `qcom,pmic_glink` 的
`battery_charger` 下，内核日志里的 `Lenovo Qi get property` 就是它），HyperOS 只通过
`vendor.xiaomi.hardware.micharge.IMiCharge` 读状态。所以"充满后断线圈"不该由我们盲写
`wls_tx/cmd` 去做（写坏要重启才恢复）；这一档只关掉**我们自己**制造的活动，
让驱动和笔固件按它原本的逻辑收尾。
