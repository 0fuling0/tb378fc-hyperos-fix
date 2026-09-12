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
 * 手写笔 BLE：唤醒命令 + 电量读取。
 *
 * 唤醒
 * ----
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
 * 电量
 * ----
 * 胶囊要一个 0..100 的数字。两条来源：
 *   1. 根侧守护读 `/sys/class/power_supply/wls_tx/level`（反向无线充电线圈看到的笔电量）
 *      —— 随 ATTACH 广播一起送进来，零延迟；
 *   2. 这里用标准 GATT 电池服务读 `0x180F/0x2A19` —— 准确但要连一次 BLE（1~3 秒）。
 * 上层两段都用：先拿线圈值立刻弹，再用 GATT 的真实值补一条（见 WakeReceiver）。
 *
 * 依赖的蓝牙 API 是最普通的那几支（getDefaultAdapter / connectGatt / read|writeCharacteristic），
 * 不需要 system 权限，也不需要 LSPosed —— 但**必须是安装过的应用**：实测在 root 的
 * app_process 环境里 BluetoothAdapter.getDefaultAdapter() 直接返回 null。
 */
public final class PenBle {
    public static final String TAG = "PenWake";
    public static final UUID SVC_FE40 = UUID.fromString("0000fe40-cc7a-482a-984a-7f2ed5b3e512");
    public static final UUID CH_FE41 = UUID.fromString("0000fe41-cc7a-482a-984a-7f2ed5b3e512");
    /** 标准 GATT 电池服务 / 电量特征 */
    public static final UUID SVC_BATTERY = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb");
    public static final UUID CH_BATTERY = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb");
    public static final String DEFAULT_MAC = "DC:EB:4D:06:E0:95";

    /** 马达服务：IMP 冲击（…0008）/ CON 连续（…0006）/ SWITCH 总开关（…000e） */
    public static final UUID SVC_HAPTIC = UUID.fromString("00000000-000f-11e1-9ab4-0002a5d5c51b");
    public static final UUID CH_HAPTIC_CON = UUID.fromString("00000006-000f-11e1-9ab4-0002a5d5c51b");
    public static final UUID CH_HAPTIC_IMP = UUID.fromString("00000008-000f-11e1-9ab4-0002a5d5c51b");

    /**
     * 波形 id（ZUX `ZuiPenHapticConstants`）：
     *   0 停 / 1 CLICK / 2 CONNECTED / 3 HAPTIC_ENABLED / 4 BRUSH_CHANGE / 5 TEXT_INPUT_FOCUS /
     *   6 RECOG_FINISHED / 7 PRESS / 32 BALLPEN / 33 PENCIL / 34 CHISEL_MARKER / 35 ERASER /
     *   36 LENOVO_BRUSH / 37..41 同上的无音效版本 / 42 EDGE_WARNING
     */
    public static final int WAVE_CLICK = 1;
    public static final int WAVE_HAPTIC_ENABLED = 3;
    public static final int WAVE_PRESS = 7;
    public static final int WAVE_BRUSH_NS = 41;   // 联想笔刷（无音效），连续振动的书写摩擦感

    /**
     * `{8,6,mask}` 触控膜功能位：笔上报哪些手势的总开关（ZUX `buildTouchfilmEnable`）。
     *   0x01 双击 / 0x02 三击 / 0x04 上滑 / 0x08 下滑 / 0x10 捏合 / 0x20 笔尾
     * 发 0x00 会让笔彻底不再上报双击/上滑/下滑/捏合（笔尖写字不受影响），
     * 现象就是"手势突然全没了"——联想原厂每次连接都会重发一次全量 mask，
     * HyperOS 上没有那个栈，所以这里替他发。
     */
    public static final int TOUCHFILM_ALL = 0x3F;
    public static final int TOUCHFILM_REMOTE = 0x0D;   // 双击|上滑|下滑（原厂"遥控"组合）

    /** 一次 GATT 会话的目的 */
    static final int MODE_WAKE = 0;
    static final int MODE_BATTERY = 1;
    static final int MODE_HAPTIC = 2;

    /* ---- 手势触感：连接缓存 ----
     * 每次振动都重新 connect+discover 要 0.3~1s，振感就迟了；所以第一次连上之后
     * 把连接与两个特征缓存住，后面的手势直接写（~20ms），空闲 12 秒才断开。 */
    private static final long HAPTIC_IDLE_MS = 12000;
    /** 停止帧之后多久断开（波形在响的时候连接一直留着，避免每次切换都重连 0.3~1s） */
    private static final long HAPTIC_IDLE_AFTER_STOP_MS = 800;
    private static BluetoothGatt sHGatt;
    private static BluetoothGattCharacteristic sHCon;
    private static BluetoothGattCharacteristic sHImp;
    private static long sHIdleAt;
    private static HandlerThread sHThread;
    private static Handler sHHandler;

    /** 一次振动请求：type 0 = IMP 冲击，1 = CON 连续（连续振动在 ms 后自动写停止帧） */
    static final class Haptic {
        final int type, wave, level, friction, ms;
        Haptic(int type, int wave, int level, int friction, int ms) {
            this.type = type; this.wave = wave; this.level = level;
            this.friction = friction; this.ms = ms;
        }
        @Override public String toString() {
            return (type == 1 ? "CON" : "IMP") + " wave=" + wave + " level=" + level
                    + " friction=" + friction + " ms=" + ms;
        }
    }

    public static final class Result {
        public boolean wakeSent;
        public boolean sawFe41;
        /** `{8,6,mask}` 是否写成功 */
        public boolean touchfilmSent;
        /** `{8,5,level}` 捏合力度是否写成功 */
        public boolean squeezeSent;
        /** 振动帧是否写成功 */
        public boolean hapticSent;
        /** GATT 读到的电量；-1 = 没读到（无电池服务 / 读失败 / 超时） */
        public int battery = -1;
        public String detail = "";
        @Override public String toString() {
            return "wakeSent=" + wakeSent + " touchfilm=" + touchfilmSent
                    + " squeeze=" + squeezeSent + " fe41=" + sawFe41
                    + " battery=" + battery + " {" + detail + "}";
        }
    }

    private PenBle() { }

    /** 连上笔 → 写唤醒命令 + 触控膜功能位全开 → 断开。最长阻塞 12 秒。 */
    public static Result run(Context ctx, String wantMac) {
        return sendCmds(ctx, wantMac, true, TOUCHFILM_ALL, -1);
    }

    /** @param touchfilmMask 要写的 `{8,6,mask}`；&lt;0 表示这次不写 */
    public static Result run(Context ctx, String wantMac, int touchfilmMask) {
        return sendCmds(ctx, wantMac, true, touchfilmMask, -1);
    }

    /**
     * 一次 GATT 会话里按顺序写几帧（写成功一帧就够本，失败会重试一次）：
     *   wake          → `{5,5}` 唤醒
     *   touchfilmMask → `{8,6,mask}` 手势功能位（&lt;0 不写）
     *   squeezeLevel  → `{8,5,level}` 捏合力度 1..5（&lt;1 不写）
     * 根侧守护用它把"小米设置里的手写笔开关/力度"路由给笔。
     */
    public static Result sendCmds(Context ctx, String wantMac, boolean wake,
                                  int touchfilmMask, int squeezeLevel) {
        return session(ctx, wantMac, MODE_WAKE, wake, touchfilmMask, squeezeLevel);
    }

    /**
     * 让笔振一下：type 0 = IMP 冲击式，1 = CON 连续式（ms 后自动补一条停止帧）。
     * 根侧守护把手势（捏/双击/滑动/笔尾）映射成这里的波形 id。
     */
    public static Result haptic(Context ctx, String wantMac, int type, int wave, int level,
                                int friction, int ms) {
        return session(ctx, wantMac, MODE_HAPTIC, false, -1, -1,
                new Haptic(type, wave, level, friction, ms), true);
    }

    /** 优先走缓存连接：命中就立刻写（~20ms），否则老老实实连一次并缓存下来。 */
    public static Result quickHaptic(Context ctx, String wantMac, int type, int wave, int level,
                                     int friction, int ms) {
        final Result res = new Result();
        long now = SystemClock.uptimeMillis();
        if (sHGatt != null && now < sHIdleAt && sHImp != null && sHCon != null) {
            StringBuilder log = new StringBuilder();
            if (hapticWriteFrame(log, sHGatt, type, wave, level, friction)) {
                res.hapticSent = true;
                res.detail = "cached " + log;
                /* 波形还在响（wave != 0）就一直留着连接，只有停了才准备断 */
                sHIdleAt = (type == 1 && wave != 0)
                        ? Long.MAX_VALUE / 2
                        : now + HAPTIC_IDLE_AFTER_STOP_MS;
                scheduleHapticStop(type, ms);
                scheduleIdleClose();
                return res;
            }
            clearHapticCache();
        }
        return session(ctx, wantMac, MODE_HAPTIC, false, -1, -1,
                new Haptic(type, wave, level, friction, ms), true);
    }

    static void clearHapticCache() {
        sHGatt = null;
        sHCon = null;
        sHImp = null;
        sHIdleAt = 0;
    }

    private static void scheduleIdleClose() {
        if (sHHandler == null) return;
        sHHandler.removeCallbacksAndMessages(null);
        sHHandler.postDelayed(new Runnable() {
            @Override public void run() {
                if (sHGatt != null && SystemClock.uptimeMillis() >= sHIdleAt) {
                    try { sHGatt.disconnect(); } catch (Throwable ignored) { }
                }
            }
        }, Math.max(HAPTIC_IDLE_MS, HAPTIC_IDLE_AFTER_STOP_MS) + 500);
    }

    private static void scheduleHapticStop(int type, int ms) {
        if (type != 1 || sHHandler == null) return;
        sHHandler.postDelayed(new Runnable() {
            @Override public void run() {
                if (sHGatt != null && sHCon != null) {
                    StringBuilder log = new StringBuilder();
                    writeCmd(log, sHGatt, sHCon, new byte[]{0, 0, 0, 0});
                }
            }
        }, Math.max(60, Math.min(2000, ms)));
    }

    /** 写一帧振动（IMP 或 CON 起始帧）；返回是否成功。 */
    static boolean hapticWriteFrame(StringBuilder log, BluetoothGatt g, int type, int wave,
                                    int level, int friction) {
        BluetoothGattService svc = g.getService(SVC_HAPTIC);
        if (svc == null) { say(log, "no haptic service"); return false; }
        if (type == 1) {
            BluetoothGattCharacteristic c = svc.getCharacteristic(CH_HAPTIC_CON);
            if (c == null) { say(log, "no CON char"); return false; }
            /* 连续式 4 字节 {id, level, b2, friction}；停 = {0,0,0,0} */
            if (wave == 0) return writeCmd(log, g, c, new byte[]{0, 0, 0, 0});
            return writeCmd(log, g, c,
                    new byte[]{(byte) wave, (byte) level, (byte) level, (byte) friction});
        }
        BluetoothGattCharacteristic c = svc.getCharacteristic(CH_HAPTIC_IMP);
        if (c == null) { say(log, "no IMP char"); return false; }
        /* 冲击式 6 字节 {id, level, repeatLo, repeatHi, 0, 0} */
        return writeCmd(log, g, c, new byte[]{(byte) wave, (byte) level, 1, 0, 0, 0});
    }

    /** 连上笔 → 读标准电池服务的电量 → 断开。最长阻塞 12 秒；读不到时 battery = -1。 */
    public static Result readBattery(Context ctx, String wantMac) {
        return session(ctx, wantMac, MODE_BATTERY, false, -1, -1);
    }

    static Result session(Context ctx, String wantMac, final int mode) {
        return session(ctx, wantMac, mode, mode == MODE_WAKE, mode == MODE_WAKE ? TOUCHFILM_ALL : -1, -1);
    }

    static Result session(Context ctx, String wantMac, final int mode, final int touchfilmMask) {
        return session(ctx, wantMac, mode, mode == MODE_WAKE, touchfilmMask, -1);
    }

    static Result session(Context ctx, String wantMac, final int mode, final boolean wake,
                          final int touchfilmMask, final int squeezeLevel) {
        return session(ctx, wantMac, mode, wake, touchfilmMask, squeezeLevel, null);
    }

    static Result session(Context ctx, String wantMac, final int mode, final boolean wake,
                          final int touchfilmMask, final int squeezeLevel, final Haptic haptic) {
        return session(ctx, wantMac, mode, wake, touchfilmMask, squeezeLevel, haptic, false);
    }

    static Result session(Context ctx, String wantMac, final int mode, final boolean wake,
                          final int touchfilmMask, final int squeezeLevel, final Haptic haptic,
                          final boolean keepAlive) {
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
                        if (sHGatt == g) clearHapticCache();
                        try { g.close(); } catch (Throwable ignored) { }
                        done.countDown();
                    }
                }

                @Override
                public void onServicesDiscovered(BluetoothGatt g, int status) {
                    say(log, "svc st=" + status);
                    if (mode == MODE_BATTERY) {
                        if (!requestBattery(log, g)) {
                            say(log, "no battery service");
                            g.disconnect();
                        }
                        /* 有电池服务就等 onCharacteristicRead 回来再断 */
                        return;
                    }
                    if (mode == MODE_HAPTIC) {
                        res.hapticSent = hapticWriteFrame(log, g, haptic.type, haptic.wave,
                                haptic.level, haptic.friction);
                        say(log, "haptic " + haptic + " -> " + res.hapticSent);
                        if (res.hapticSent && keepAlive) {
                            /* 把连接留下来给下一条手势用：不 disconnect，直接返回 */
                            if (sHThread == null) {
                                sHThread = new HandlerThread("penhaptic");
                                sHThread.start();
                                sHHandler = new Handler(sHThread.getLooper());
                            }
                            sHGatt = g;
                            sHCon = null;
                            sHImp = null;
                            BluetoothGattService hs = g.getService(SVC_HAPTIC);
                            if (hs != null) {
                                sHCon = hs.getCharacteristic(CH_HAPTIC_CON);
                                sHImp = hs.getCharacteristic(CH_HAPTIC_IMP);
                            }
                            sHIdleAt = (haptic.type == 1 && haptic.wave != 0)
                                    ? Long.MAX_VALUE / 2
                                    : SystemClock.uptimeMillis() + HAPTIC_IDLE_AFTER_STOP_MS;
                            scheduleHapticStop(haptic.type, haptic.ms);
                            scheduleIdleClose();
                            done.countDown();
                            return;
                        }
                        SystemClock.sleep(Math.max(60, Math.min(2000, haptic.ms)));
                        if (haptic.type == 1) {
                            hapticWriteFrame(log, g, 1, 0, 0, 0);   // 停
                        }
                        SystemClock.sleep(100);
                        g.disconnect();
                        return;
                    }
                    BluetoothGattService s = g.getService(SVC_FE40);
                    BluetoothGattCharacteristic c = s == null ? null : s.getCharacteristic(CH_FE41);
                    res.sawFe41 = c != null;
                    if (c == null) { say(log, "no fe41"); g.disconnect(); return; }
                    if (wake) res.wakeSent = writeWake(log, g, c);
                    if (touchfilmMask >= 0) {
                        SystemClock.sleep(200);
                        // {8,6,mask}：笔端手势功能位（双击/三击/上滑/下滑/捏合/笔尾）
                        res.touchfilmSent = writeCmd(log, g, c,
                                new byte[]{8, 6, (byte) (touchfilmMask & 0xFF)});
                    }
                    if (squeezeLevel >= 1) {
                        SystemClock.sleep(200);
                        // {8,5,level}：捏合力度 1(轻)..5(重)，对应设置里"轻捏力度"
                        res.squeezeSent = writeCmd(log, g, c,
                                new byte[]{8, 5, (byte) (squeezeLevel & 0xFF)});
                    }
                    SystemClock.sleep(400);
                    g.disconnect();
                }

                @Override
                public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic ch,
                                                 byte[] value, int status) {
                    // Android 13+ 的新重载（带 value）
                    takeBattery(res, log, ch, value, status);
                    SystemClock.sleep(300);
                    g.disconnect();
                }

                @Override
                @SuppressWarnings("deprecation")
                public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic ch,
                                                 int status) {
                    // 老重载（Android 12 及以前，值在 characteristic 里）
                    if (res.battery >= 0) return;      // 新重载已经处理过
                    takeBattery(res, log, ch, ch == null ? null : ch.getValue(), status);
                    SystemClock.sleep(300);
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
            try {
                if (gatt != null && gatt != sHGatt) gatt.close();
            } catch (Throwable ignored) { }
            if (ht != null) ht.quitSafely();
            res.detail = log.toString().replace('\n', '|') + (res.detail.isEmpty() ? "" : " " + res.detail);
        }
        return res;
    }

    /** 发起一次 0x2A19 读；返回 false 表示这支笔没有标准电池服务。 */
    static boolean requestBattery(StringBuilder log, BluetoothGatt g) {
        BluetoothGattService s = g.getService(SVC_BATTERY);
        BluetoothGattCharacteristic c = s == null ? null : s.getCharacteristic(CH_BATTERY);
        if (c == null) return false;
        /* Android 13 起 readCharacteristic 有新重载（返回状态码）；先试新的，再退老的。 */
        try {
            java.lang.reflect.Method m = BluetoothGatt.class.getMethod("readCharacteristic",
                    BluetoothGattCharacteristic.class);
            Object r = m.invoke(g, c);
            if (r instanceof Integer) {
                int code = (Integer) r;
                say(log, "read rc=" + code);
                return code == 0;
            }
            if (r instanceof Boolean) {
                boolean b = (Boolean) r;
                say(log, "read=" + b);
                return b;
            }
        } catch (Throwable t) {
            say(log, "read newAPI n/a " + t);
        }
        try {
            boolean b = g.readCharacteristic(c);
            say(log, "read legacy=" + b);
            return b;
        } catch (Throwable t) {
            say(log, "read legacy failed " + t);
            return false;
        }
    }

    /** 从回调里取值：只认 0..100 的合法字节。 */
    static void takeBattery(Result res, StringBuilder log, BluetoothGattCharacteristic ch,
                            byte[] value, int status) {
        byte[] v = value;
        if ((v == null || v.length == 0) && ch != null) {
            try { v = ch.getValue(); } catch (Throwable ignored) { }
        }
        if (status != 0 || v == null || v.length == 0) {
            say(log, "batt st=" + status + " v=" + (v == null ? "null" : v.length));
            return;
        }
        int b = v[0] & 0xFF;
        if (b < 0 || b > 100) { say(log, "batt out of range " + b); return; }
        res.battery = b;
        say(log, "battery=" + b);
    }

    @SuppressWarnings("deprecation")
    static boolean writeWake(StringBuilder log, BluetoothGatt g, BluetoothGattCharacteristic c) {
        return writeCmd(log, g, c, new byte[]{5, 5});
    }

    /** 往 FE41 写一帧（写类型 2，带响应；失败 200ms 后重试一次）。 */
    @SuppressWarnings("deprecation")
    static boolean writeCmd(StringBuilder log, BluetoothGatt g, BluetoothGattCharacteristic c,
                            byte[] v) {
        /* Android 13 起 setValue+writeCharacteristic 被弃用，改用带 value 的新重载；
         * 这里优先走新 API（返回状态码），不行再退回老 API。 */
        try {
            java.lang.reflect.Method m = BluetoothGatt.class.getMethod("writeCharacteristic",
                    BluetoothGattCharacteristic.class, byte[].class, int.class);
            Object r = m.invoke(g, c, v, 2);
            if (r instanceof Integer) {
                int code = (Integer) r;
                say(log, "write " + hex(v) + " rc=" + code);
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
            say(log, "legacy write " + hex(v) + "=" + b);
            return b;
        } catch (Throwable t) {
            say(log, "legacy failed " + t);
            return false;
        }
    }

    static String hex(byte[] v) {
        StringBuilder sb = new StringBuilder();
        for (byte b : v) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(String.format("%02x", b & 0xFF));
        }
        return sb.toString();
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
