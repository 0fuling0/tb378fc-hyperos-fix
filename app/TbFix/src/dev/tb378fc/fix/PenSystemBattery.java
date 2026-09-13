package dev.tb378fc.fix;

import android.content.Context;
import android.hardware.BatteryState;
import android.hardware.input.InputManager;
import android.util.Log;
import android.view.InputDevice;

/**
 * 直接问系统要手写笔电量 —— 不走 BLE，不用 GATT，0 毫秒。
 *
 * 原理
 * ----
 * `InputDevice.getBatteryState()` 与 `android.hardware.BatteryState` 都是**公开 API**
 * （android-36 的 android.jar 里就有，不需要任何权限、不需要反射）。系统的手写笔输入设备
 * （本机是 NVTCapacitivePen）如果能关联到蓝牙设备，`getBatteryState()` 就会返回
 * `isPresent()=true` + `getCapacity()` + `getStatus()`（含"正在充电"）。
 *
 * 前提：这个关联来自 system_server 的 `com.android.server.input.BatteryController` ——
 * 它用输入设备的 `uniq`（蓝牙地址）去找蓝牙设备，而本机数字板的 uniq 是空的，
 * 所以**默认关联不上**（`dumpsys input` 里是 `NativeBattery=State{<not present>}, BluetoothState=null`）。
 * 装上并启用 LSPosed hook（extras/PenStylusHook，作用域「系统框架」）之后就能关联上，
 * 这条路径也就活了 —— 那时本类返回的就是真值 + 充电状态，比连一次 BLE 快得多。
 *
 * 没装 hook 时本类返回 null，调用方按老路走（线圈值 / GATT）。
 */
public final class PenSystemBattery {
    private static final String TAG = "PenSysBattery";

    public static final class Sample {
        /** 0..100；-1 = 无效 */
        public int capacity = -1;
        public boolean charging;
        public String source = "";

        @Override public String toString() {
            return "capacity=" + capacity + " charging=" + charging + " via=" + source;
        }
    }

    private PenSystemBattery() { }

    /** 在所有 STYLUS 输入设备里找第一个"电池存在"的，返回它的电量与充电状态；没有则 null。 */
    public static Sample read(Context ctx) {
        try {
            InputManager im = (InputManager) ctx.getSystemService(Context.INPUT_SERVICE);
            if (im == null) return null;
            for (int id : im.getInputDeviceIds()) {
                InputDevice dev = im.getInputDevice(id);
                if (dev == null) continue;
                if ((dev.getSources() & InputDevice.SOURCE_STYLUS) == 0) continue;
                BatteryState bs;
                try {
                    bs = dev.getBatteryState();
                } catch (Throwable t) {
                    continue;
                }
                if (bs == null || !bs.isPresent()) continue;
                float cap = bs.getCapacity();               // 0.0 ~ 1.0
                if (cap < 0f) continue;
                Sample s = new Sample();
                s.capacity = Math.max(0, Math.min(100, Math.round(cap * 100f)));
                int status = bs.getStatus();
                s.charging = (status == BatteryState.STATUS_CHARGING);
                s.source = "InputDevice#" + id + " " + safeName(dev);
                Log.i(TAG, "system battery: " + s);
                return s;
            }
        } catch (Throwable t) {
            Log.w(TAG, "read failed", t);
        }
        return null;
    }

    static String safeName(InputDevice dev) {
        try { return String.valueOf(dev.getName()); } catch (Throwable t) { return "?"; }
    }
}
