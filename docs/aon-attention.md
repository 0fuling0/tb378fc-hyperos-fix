# 注视感知（AON）在这台 HyperOS 移植包上怎么修通的

目标：让 HyperOS 的 **AttentionManagerService** 真正拿到"人在不在看屏幕"的结论，
从而"注视不息屏"（`secure adaptive_sleep=1`）这类功能可用。

> 本机实测链路是**真实前摄帧 + 真实人脸检测**，没有 CPU 兜底、也没有伪造结果。

## 链条

```
PowerKeeper / SmartDim（屏幕快超时）
  └─ AttentionManagerService.checkAttention()
       └─ bind com.xiaomi.aon.AonAttentionService            （标准 android.service.attention.AttentionService）
            └─ AONFaceEnpuV2（APK 里的 Java 类，注册 type=4 的 face/gaze 监听）
                 └─ AIDL vendor.xiaomi.hardware.aon.IAlwaysOn/miaonservicehal
                      └─ /odm/bin/hw/mifaced  ← 里面的 Y700AonShim（针对联想平板的 shim）
                           └─ fork/exec 自己 --camera-worker
                                └─ camera2 NDK 打开前摄( id=1 ) → 人脸检测 → 回调 present=1
```

## 四个卡点与修法（按被发现的顺序）

### ① 客户特性开关：`config_supported_aon_devices`

HyperOS 的客户特性解析器写死读 `/mi_ext/product/etc/cust_features/device_features.xml`，
移植包把那份配置放在 `/product/etc/cust_features/`，而联想机型没有 `mi_ext` 分区。
→ `module/post-fs-data.sh` 把配置目录用 tmpfs + bind mount 盖到 `/mi_ext/...`，
并把 `config_supported_aon_devices=true` 注入两个 xml。关掉：`disable-aon`，
或把 `config` 里的 `AON` 设为 `0`（**v3.7 起默认就是 0** —— ⑧ 属于"需要 App"那一组，
打开它才会自动安装 `bin/TbFix.apk`）。

### ② binder 服务 `HyperOSCustFeatureResolve` 没注册

移植包的 system_server 里这个服务不存在，所有 `getBoolean()` 调用都抛异常 → 一律取默认值 false。
光有 ① 没用，因为读配置那一步本身就炸。
→ TbFix 的 LSPosed 钩子（作用域必须包含 **`android` 系统框架**）接管
`HyperOSCustFeatureResolve.getBoolean` 与 PMS 的 `getSupportAonServicePackageName` /
`getAttentionServicePackageName`，返回 `com.xiaomi.aon`。

### ③ mifaced 起不来：`/odm/lib64` 里没有 `libcamera2ndk.so`

```
CANNOT LINK EXECUTABLE "/odm/bin/hw/mifaced": library "libcamera2ndk.so" not found
```

- `/system/lib64/libcamera2ndk.so` 存在，但**不在 vendor 命名空间的允许路径里**；
  硬拷到 `/odm/lib64` 会引出它的依赖链（`libandroid_runtime` → `libart` 一整片），不可行。
- 本 ROM 的 linker 配置是 **protobuf**（`/apex/com.android.runtime/etc/linker.config.pb`），
  不是文本 `ld.config.*.txt`，所以"给 sphal 加个搜索路径"这种常规移植手法用不上。
- **解法**：`/vendor/lib64/libcamera2ndk_vendor.so` 的依赖全是 vendor 库
  （`libstagefright_foundation` / `libhidlbase` / `libcamera_metadata` …），
  把它按需要的名字拷成 `libcamera2ndk.so` —— bionic 接受 soname 不一致（实测）。
  `/odm` 是只读 erofs，所以 `module/bin/aonlib.sh` 先把原内容备份到模块目录、
  用 tmpfs 盖住 `/odm/lib64`，再把备份 + 这个库铺回去并统一 `chcon vendor_file`。关掉：`disable-aonlib`。

### ④ SELinux：三条规则（最隐蔽的一条是 camera worker）

前三条是逐条从 `dmesg | grep avc` 里挖出来的：

| 现象 | 规则 |
|---|---|
| 读不到 `/mi_ext/.../cust_features.xml`（`getattr` denied） | `allow hal_miface_default system_file file { getattr open read map }` |
| **camera worker 子进程 exit(127)** —— shim 用"重新 exec 自己 + `--camera-worker`"起 worker，而 HAL 域没有自我 exec 权限 | `allow hal_miface_default hal_miface_default_exec file { execute execute_no_trans }` |
| 相机 worker 线程读 vendor 属性文件（frc） | `allow hal_miface_default vendor_frc_prop file { getattr open read map }` |

第二条是最关键的：**没有它，HAL 能起来、能注册、attention 检查也能"完成"，但前摄永远不开，
结果恒为"无人注视"（result=0）** —— 从表面完全看不出问题，只有 `Y700AonShim: camera worker exited
pid=... status=32512`（127）这一行会暴露它。
规则写在 `module/sepolicy.rule`（KernelSU 开机应用；也可热打 `ksud sepolicy patch '...'`，
注意是 magiskpolicy 语法，没有冒号也没有分号）。

## 验收（实测输出）

```sh
M=/data/adb/modules/tb378fc_hyperos_fix
# HAL 在不在
service list | grep -i aon                     # → vendor.xiaomi.hardware.aon.IAlwaysOn/miaonservicehal
# 感知链路（最关键的三行）
logcat -d | grep Y700AonShim | tail
#   open front camera id=1 status=0
#   metadata frame=2 faces=1 score=92 rect=[632,1387,1187,2131]
#   callback present=1 faces=1 score=92 status=0
# 框架侧结论
logcat -d | grep -E "AttentionDetector|ATTENTION_SUCCESS" | tail
#   AonAttentionService AttentionClient: onSuccess -->ATTENTION_SUCCESS_PRESENT
#   AttentionDetector: onSuccess: 1, ID: 7
dumpsys attention | sed -n '/attention check cache/,+8p'   # result=1 = 有人注视（修之前恒为 0）
dmesg | grep -c 'avc:.*hal_miface'             # → 0
```

## 两个坑

- **HAL 起来之后必须重启一次 AON app**：`com.xiaomi.aon` 在开机时（mifaced 还没起来）会
  把 `mIAlwaysOn` 缓存成 null，之后即使 HAL 上来了也一直用那个 null → 恒返回"无人注视"。
  实测 `am force-stop com.xiaomi.aon` 一次即恢复（之后框架按需重新绑定）。
- 检查是**按需**触发的（SmartDim 在屏幕快超时时请求），不是常轮询。
  想手动看效果：把 `screen_off_timeout` 调短（如 20 秒），盯着屏幕别碰 —— 屏幕不该熄灭；
  盯着别处/离开，则按超时熄灭。看完记得把超时改回去。

## 第三步：让「设置 → 视觉感知/注视感知」那一页出现

HyperOS 里这一页的可见性由 **`com.miui.rom`** 里三个 bool 决定，而移植包自带的
`/product/overlay/MiuiFrameworkResOverlay.apk`（target `com.miui.rom`、priority 100、isStatic）
把它们写成了 false：

```
config_aon_gesture_available / config_aon_screen_on_available / config_aon_screen_off_available
```

**做法**：在**设置进程**里钩 `android.content.res.Resources.getBoolean(int)`，按资源名
（先把三个名字解析成 id 缓存起来，热路径只比 int）把这三个 bool 放行成 true。
作用域要加 `com.android.settings`（`scope.list` 与 `res/values/arrays.xml` 都要加 —— 见下面那条坑）。

功能本身不依赖它（`secure adaptive_sleep=1` 本来就是开的，检查照常触发），这一步只是让用户在
UI 上能看见、能切换。

### ⚠️ 走过的弯路：千万不要用 tmpfs 覆盖系统 overlay 目录

一开始做的是正经 RRO（`target com.miui.rom`、`priority 999`、只覆盖这三个 bool）。装成
data overlay 被签名校验挡住：

```
INSTALL_FAILED_INTERNAL_ERROR: Overlay dev.tb378fc.aonoverlay and target com.miui.rom
signed with different certificates, and the overlay lacks <overlay android:targetName>
```

（target 没声明 `<overlayable>`，异签名只能靠"装在系统分区"豁免。）于是改成
`tmpfs 盖 /product/overlay` → 把原有 overlay 全部 `cp -a` 回去 → 再 `chcon` 自己的那个。
**结果把 UI 弄坏了**：`cp -a` 不保留 SELinux 标签，83 个原有 overlay 全变成 `u:object_r:tmpfs:s0`，
system_server 读不了它们（`avc: denied { getattr } path="/product/overlay/...apk" tcontext=u:object_r:tmpfs:s0`），
而那个目录里正是 `MiuiDefaultLockscreenOverlay.apk` / `MiuiSystemUIResOverlay.apk` 这批
锁屏与 SystemUI 的 overlay —— 表现就是**锁屏时钟消失、下拉通知栏出不来控制中心**。

结论：**系统 overlay 目录不要用 tmpfs + cp 去镜像**（标签、fs-verity 都不是拷过来的）。
真要用 RRO，就得整目录逐个 `chcon` 成原标签，而且要先验证 `ls -Z` 一致；
更省事、风险更低的替代就是上面这个"在读取方进程里按资源名放行"的钩子。
