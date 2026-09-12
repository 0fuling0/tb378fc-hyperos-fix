package dev.tb378fc.stylus.hook;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.Set;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * Reconnects the two halves of the stylus battery path in system_server.
 *
 * Why this is needed on this port
 * ------------------------------
 * Android's stylus UI (SystemUI StylusManager / StylusUsiPowerUI) only listens to the
 * battery of the *input device* that carries SOURCE_STYLUS -- here NVTCapacitivePen,
 * the NVT digitizer.  com.android.server.input.BatteryController resolves that device's
 * Bluetooth counterpart through the native InputDevice bluetooth address, which the
 * kernel fills from the input device's `uniq`.  On this device the digitizer's uniq is
 * empty (and /sys/class/input/inputN/uniq is read-only at runtime), while the pen's
 * Bluetooth HID devices -- which do carry uniq=dc:eb:4d:06:e0:95 -- are not stylus
 * devices.  So:
 *
 *     dumpsys input -> DeviceId=7, Name='NVTCapacitivePen',
 *                      NativeBattery=State{<not present>}, BluetoothState=null
 *
 * and the whole native stylus feature set stays dark, even though the Bluetooth stack
 * already holds the pen's battery (`Profile: BatteryService  BatteryStateMachine
 * state=Connected`, BATTERY=100).
 *
 * What this hook does
 * -------------------
 * Hooks BatteryController#getBluetoothDevice(int) -- the single call site that maps an
 * input device to its Bluetooth device -- and, only when the framework found nothing,
 * answers with the Lenovo pen.  Everything downstream then runs natively:
 *
 *     DeviceMonitor.mBluetoothDevice  ->  updateBluetoothBatteryMonitoring()
 *     ->  BluetoothBatteryManager.getBatteryLevel()  ->  BluetoothState set
 *     ->  METADATA_MAIN_BATTERY(18) / METADATA_MAIN_CHARGING(19) listeners
 *     ->  SystemUI native stylus capsule + low-battery notification + charging UI
 *
 * The hook never overrides a real association and never touches devices that are not
 * stylus-capable, so a device with a working native path keeps it.
 */
public final class PenStylusHook implements IXposedHookLoadPackage {
    private static final String TAG = "PenStylusHook";
    private static final String TARGET_CLASS = "com.android.server.input.BatteryController";
    private static final String TARGET_METHOD = "getBluetoothDevice";
    private static final String DEFAULT_MAC = "DC:EB:4D:06:E0:95";
    private static final String MAC_FILE = "/data/adb/penwake/mac";
    /** SOURCE_CLASS_POINTER | SOURCE_STYLUS */
    private static final int STYLUS_SOURCES = 0x00000002 | 0x00004000;

    private static volatile BluetoothDevice cachedPen;
    private static volatile long cachedAt;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        if (!"android".equals(lpparam.packageName)) {
            return;
        }
        log("loaded in " + lpparam.packageName + "/" + lpparam.processName);
        try {
            Class<?> target = XposedHelpers.findClass(TARGET_CLASS, lpparam.classLoader);
            Set<XC_MethodHook.Unhook> hooks = XposedBridge.hookAllMethods(target, TARGET_METHOD,
                    new XC_MethodHook() {
                        @Override
                        protected void afterHookedMethod(MethodHookParam param) {
                            try {
                                if (param.getResult() != null) {
                                    return;                     // a real association exists
                                }
                                Object arg = (param.args == null || param.args.length == 0)
                                        ? null : param.args[0];
                                if (!(arg instanceof Integer)) {
                                    return;
                                }
                                int deviceId = (Integer) arg;
                                if (!isStylusCapable(deviceId)) {
                                    return;
                                }
                                BluetoothDevice pen = penDevice();
                                if (pen == null) {
                                    return;
                                }
                                param.setResult(pen);
                                log("input device " + deviceId + " -> pen " + pen.getAddress());
                            } catch (Throwable t) {
                                log("hook body failed: " + t);
                            }
                        }
                    });
            log("hooked " + (hooks == null ? 0 : hooks.size()) + " method(s): "
                    + TARGET_CLASS + "#" + TARGET_METHOD);
        } catch (Throwable t) {
            log("install failed: " + t);
        }
    }

    /**
     * Only claim devices that can actually carry a stylus.  If the input device cannot be
     * inspected we allow the association: BatteryController only ever calls this for devices
     * some client registered a battery listener on, i.e. stylus/battery devices.
     */
    private static boolean isStylusCapable(int deviceId) {
        try {
            Class<?> imClass = Class.forName("android.hardware.input.InputManager");
            Object im = imClass.getMethod("getInstance").invoke(null);
            if (im == null) {
                return true;
            }
            Object device = imClass.getMethod("getInputDevice", int.class).invoke(im, deviceId);
            if (device == null) {
                return false;
            }
            Class<?> devClass = Class.forName("android.hardware.input.InputDevice");
            int sources = (Integer) devClass.getMethod("getSources").invoke(device);
            boolean stylus = (sources & STYLUS_SOURCES) == STYLUS_SOURCES;
            if (!stylus) {
                log("device " + deviceId + " is not stylus-capable (sources=0x"
                        + Integer.toHexString(sources) + "); leaving alone");
            }
            return stylus;
        } catch (Throwable t) {
            log("stylus check unavailable (" + t + "); allowing association");
            return true;
        }
    }

    private static BluetoothDevice penDevice() {
        long now = android.os.SystemClock.uptimeMillis();
        BluetoothDevice cached = cachedPen;
        if (cached != null && now - cachedAt < 60_000L) {
            return cached;
        }
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            return null;
        }
        String mac = configuredMac(adapter);
        if (mac == null) {
            return null;
        }
        try {
            BluetoothDevice device = adapter.getRemoteDevice(mac);
            cachedPen = device;
            cachedAt = now;
            return device;
        } catch (Throwable t) {
            log("bad pen address " + mac + ": " + t);
            return null;
        }
    }

    /** configured file first, then a bonded Lenovo pen, then the known default. */
    private static String configuredMac(BluetoothAdapter adapter) {
        try {
            File f = new File(MAC_FILE);
            if (f.canRead()) {
                BufferedReader r = new BufferedReader(new FileReader(f));
                String line = r.readLine();
                r.close();
                if (line != null && line.trim().length() > 0) {
                    return line.trim();
                }
            }
        } catch (Throwable t) {
            log("mac file unreadable: " + t);
        }
        try {
            for (BluetoothDevice d : adapter.getBondedDevices()) {
                String name = d.getName();
                if (name == null) {
                    continue;
                }
                String n = name.toLowerCase();
                if (n.contains("lenovo") && (n.contains("pen") || n.contains("stylus")
                        || n.contains("pencil"))) {
                    log("found bonded pen by name: " + name);
                    return d.getAddress();
                }
            }
        } catch (Throwable t) {
            log("bonded scan failed: " + t);
        }
        return DEFAULT_MAC;
    }

    private static void log(String message) {
        try {
            XposedBridge.log(TAG + ": " + message);
        } catch (Throwable ignored) { }
        try {
            android.util.Log.i(TAG, message);
        } catch (Throwable ignored) { }
    }
}
