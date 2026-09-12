package dev.tb378fc.stylus;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothProfile;
import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.util.Log;

import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * 手写笔 BLE 唤醒。
 *
 * 这支笔（Lenovo Tab Pen Pro 2）闲置后 MCU 会休眠，但蓝牙控制器继续维持 HOGP 连接 ——
 * 所以"蓝牙还连着"是假象：休眠期间笔尖不出信号、滑条不响应、马达不振动。只有磁吸线圈
 * 能唤醒它。联想自己的软件（ZUX / ColorOS 移植包里的 android.bluetooth.StylusCompat）
 * 会在**取下的边沿**往笔的私有特征值写一条命令把它叫醒：
 *
 *     service        0000fe40-cc7a-482a-984a-7f2ed5b3e512
 *     characteristic 0000fe41-cc7a-482a-984a-7f2ed5b3e512
 *     payload        {0x05, 0x05}      写类型 2（带响应），失败 200ms 后重试一次
 *
 * HyperOS 没有手写笔软件栈，没人发这条命令。这个类就是替它发。
 *
 * 依赖的蓝牙 API 是最普通的那几支（getDefaultAdapter / connectGatt / writeCharacteristic），
 * 不需要 system 权限，也不需要 LSPosed —— 但**必须是安装过的应用**：实测在 root 的
 * app_process 环境里 BluetoothAdapter.getDefaultAdapter() 直接返回 null。
 */
public final class PenBle {
    public static final String TAG = "PenWake";
    public static final UUID SVC_FE40 = UUID.fromString("0000fe40-cc7a-482a-984a-7f2ed5b3e512");
    public static final UUID CH_FE41 = UUID.fromString("0000fe41-cc7a-482a-984a-7f2ed5b3e512");
    public static final String DEFAULT_MAC = "DC:EB:4D:06:E0:95";

    public static final class Result {
        public boolean wakeSent;
        public boolean sawFe41;
        public String detail = "";
        @Override public String toString() {
            return "wakeSent=" + wakeSent + " fe41=" + sawFe41 + " {" + detail + "}";
        }
    }

    private PenBle() { }

    /** 连上笔 → 写唤醒命令 → 断开。最长阻塞 12 秒。 */
    public static Result run(Context ctx, String wantMac) {
        final Result res = new Result();
        final StringBuilder log = new StringBuilder();
        HandlerThread ht = null;
        BluetoothGatt gatt = null;
        try {
            BluetoothAdapter ad = BluetoothAdapter.getDefaultAdapter();
            if (ad == null || !ad.isEnabled()) { res.detail = "no adapter/bt off"; return res; }
            String mac = resolveMac(ad, wantMac, log);
            if (mac == null) { res.detail = "no pen"; return res; }
            BluetoothDevice dev = ad.getRemoteDevice(mac);

            ht = new HandlerThread("penble");
            ht.start();
            Handler h = new Handler(ht.getLooper());
            final CountDownLatch done = new CountDownLatch(1);

            BluetoothGattCallback cb = new BluetoothGattCallback() {
                @Override
                public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
                    say(log, "conn st=" + status + " new=" + newState);
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        g.discoverServices();
                    } else {
                        try { g.close(); } catch (Throwable ignored) { }
                        done.countDown();
                    }
                }

                @Override
                public void onServicesDiscovered(BluetoothGatt g, int status) {
                    say(log, "svc st=" + status);
                    BluetoothGattService s = g.getService(SVC_FE40);
                    BluetoothGattCharacteristic c = s == null ? null : s.getCharacteristic(CH_FE41);
                    res.sawFe41 = c != null;
                    if (c == null) { say(log, "no fe41"); g.disconnect(); return; }
                    res.wakeSent = writeWake(log, g, c);
                    SystemClock.sleep(500);
                    g.disconnect();
                }
            };

            gatt = dev.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE,
                    BluetoothDevice.PHY_LE_1M_MASK, h);
            if (gatt == null) { res.detail = "gatt null"; return res; }

            if (!done.await(12, TimeUnit.SECONDS)) {
                say(log, "timeout");
                try { gatt.disconnect(); gatt.close(); } catch (Throwable ignored) { }
            }
        } catch (Throwable t) {
            say(log, "fatal " + t);
            Log.e(TAG, "fatal", t);
        } finally {
            try { if (gatt != null) gatt.close(); } catch (Throwable ignored) { }
            if (ht != null) ht.quitSafely();
            res.detail = log.toString().replace('\n', '|');
        }
        return res;
    }

    @SuppressWarnings("deprecation")
    static boolean writeWake(StringBuilder log, BluetoothGatt g, BluetoothGattCharacteristic c) {
        byte[] v = new byte[]{5, 5};
        /* Android 13 起 setValue+writeCharacteristic 被弃用，改用带 value 的新重载；
         * 这里优先走新 API（返回状态码），不行再退回老 API。 */
        try {
            java.lang.reflect.Method m = BluetoothGatt.class.getMethod("writeCharacteristic",
                    BluetoothGattCharacteristic.class, byte[].class, int.class);
            Object r = m.invoke(g, c, v, 2);
            if (r instanceof Integer) {
                int code = (Integer) r;
                say(log, "write rc=" + code);
                if (code == 0) return true;
                SystemClock.sleep(200);
                Object r2 = m.invoke(g, c, v, 2);
                say(log, "write retry rc=" + r2);
                return (r2 instanceof Integer) && ((Integer) r2) == 0;
            }
        } catch (Throwable t) {
            say(log, "newAPI n/a " + t);
        }
        try {
            c.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            c.setValue(v);
            boolean b = g.writeCharacteristic(c);
            if (!b) { SystemClock.sleep(200); c.setValue(v); b = g.writeCharacteristic(c); }
            say(log, "legacy write=" + b);
            return b;
        } catch (Throwable t) {
            say(log, "legacy failed " + t);
            return false;
        }
    }

    /** 找这支笔：优先根侧写入的 MAC，其次已配对设备里名字含 "Tab Pen" 的那个。 */
    static String resolveMac(BluetoothAdapter ad, String wantMac, StringBuilder log) {
        if (wantMac != null && wantMac.length() > 0) return wantMac;
        try {
            for (BluetoothDevice d : ad.getBondedDevices()) {
                String n = safeName(d).toLowerCase();
                if (n.contains("tab pen")) {
                    say(log, "bonded: " + safeName(d) + " " + d.getAddress());
                    return d.getAddress();
                }
            }
        } catch (Throwable t) {
            say(log, "bonded scan failed " + t);
        }
        try {
            java.io.File f = new java.io.File("/data/adb/penwake/mac");
            if (f.canRead()) {
                java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f));
                String line = r.readLine();
                r.close();
                if (line != null && line.trim().length() > 0) return line.trim();
            }
        } catch (Throwable ignored) { }
        return DEFAULT_MAC;
    }

    static String safeName(BluetoothDevice d) {
        try { return String.valueOf(d.getName()); } catch (Throwable t) { return "?"; }
    }

    static void say(StringBuilder log, String s) {
        log.append(s).append('\n');
        Log.i(TAG, s);
    }
}
