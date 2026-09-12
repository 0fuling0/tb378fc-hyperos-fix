package dev.tb378fc.stylus;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * 根侧守护进程的入口。两个 action：
 *
 *   dev.tb378fc.stylus.WAKE    取下笔（磁吸 1→0）：发那条 BLE 唤醒命令
 *   dev.tb378fc.stylus.ATTACH  吸附笔（磁吸 0→1）：弹 HyperOS 原生电量胶囊
 *
 * 用显式广播打到 manifest 里声明的 receiver，是这台 ROM 上后台应用唯一被允许的启动方式
 * （`am startservice` 会被拒绝："app is in background uid null"）。
 * goAsync() 让进程在整个 BLE 事务（约 1-3 秒）期间保持存活。
 *
 * ATTACH 的电量走两段：
 *   1. 根侧守护已经把 `/sys/class/power_supply/wls_tx/level`（线圈看到的笔电量）放进
 *      `battery` extra —— 先拿它**立刻**弹一次，胶囊零延迟出现；
 *   2. 再连一次笔用标准 GATT 电池服务（0x180F/0x2A19）读真实值，**不一样就补发一条**
 *      （每发一条都会重置胶囊的 2 秒定时器并刷新数字）。
 *   线圈值不可用时只走第 2 段；两段都拿不到就不弹（不能拿 -1 去弹，窗口会显示 "-1"）。
 */
public final class WakeReceiver extends BroadcastReceiver {
    public static final String ACTION_WAKE = "dev.tb378fc.stylus.WAKE";
    public static final String ACTION_ATTACH = "dev.tb378fc.stylus.ATTACH";
    /** 手势触感：让笔按某个波形振一下（by penring） */
    public static final String ACTION_HAPTIC = "dev.tb378fc.stylus.HAPTIC";

    @Override
    public void onReceive(Context context, Intent intent) {
        final PendingResult pending = goAsync();
        final Context app = context.getApplicationContext();
        final String action = intent == null ? "" : String.valueOf(intent.getAction());
        final String mac = intent == null ? null : intent.getStringExtra("mac");

        if (ACTION_ATTACH.equals(action)) {
            // battery：要立刻弹的电量（守护直发模式下传 -1，表示"已经弹过了，别重复弹"）
            // coil   ：守护已用线圈值弹过的那个数字，用来判断 GATT 真值要不要补一条
            final int battery = intent.getIntExtra("battery", -1);
            final int coil = intent.getIntExtra("coil", battery);
            final int state = intent.getIntExtra("state", Capsule.STATE_CHARGING);
            new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        attach(app, mac, battery, coil, state);
                    } catch (Throwable t) {
                        Log.e(PenBle.TAG, "attach failed", t);
                    } finally {
                        try { pending.finish(); } catch (Throwable ignored) { }
                    }
                }
            }, "pencapsule-rx").start();
            return;
        }

        if (!ACTION_WAKE.equals(action)) {
            if (ACTION_HAPTIC.equals(action)) {
                // 手势触感：根侧守护（penring）把捏/双击/滑动/笔尾映射成波形 id 发过来
                final int type = intent.getIntExtra("type", 0);       // 0=IMP 冲击, 1=CON 连续
                final int wave = intent.getIntExtra("wave", PenBle.WAVE_CLICK);
                final int level = intent.getIntExtra("level", 3);      // 0..5
                final int friction = intent.getIntExtra("friction", 1);
                final int ms = intent.getIntExtra("ms", 120);
                new Thread(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            PenBle.Result r = PenBle.quickHaptic(app, mac, type, wave, level, friction, ms);
                            Log.i(PenBle.TAG, "HAPTIC " + r);
                        } catch (Throwable t) {
                            Log.e(PenBle.TAG, "haptic failed", t);
                        } finally {
                            try { pending.finish(); } catch (Throwable ignored) { }
                        }
                    }
                }, "penhaptic-rx").start();
                return;
            }
            Log.i(PenBle.TAG, "ignored action " + action);
            try { pending.finish(); } catch (Throwable ignored) { }
            return;
        }

        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    // touchfilm：{8,6,mask} 笔端手势功能位（默认全开 0x3F，-1 = 这次不写）
                    // squeeze  ：{8,5,level} 捏合力度 1..5（默认 -1 = 这次不写）
                    // wake     ：0 = 只改设置，不唤醒（根侧守护同步"小米设置"时用）
                    final int touchfilm = intent.getIntExtra("touchfilm", PenBle.TOUCHFILM_ALL);
                    final int squeeze = intent.getIntExtra("squeeze", -1);
                    final boolean wake = intent.getIntExtra("wake", 1) != 0;
                    PenBle.Result r = PenBle.sendCmds(app, mac, wake, touchfilm, squeeze);
                    Log.i(PenBle.TAG, "WAKE " + r);
                } catch (Throwable t) {
                    Log.e(PenBle.TAG, "wake failed", t);
                } finally {
                    try { pending.finish(); } catch (Throwable ignored) { }
                }
            }
        }, "penwake-rx").start();
    }

    /**
     * 吸附时的胶囊。按"越来越贵"的顺序取值：
     *   1. `InputDevice.getBatteryState()` —— 公开 API、0 ms、自带充电状态；
     *      只有装了 LSPosed hook（把数字板与蓝牙笔关联）才有值，没装就是 null
     *   2. 守护传进来的线圈电量（root 读 sysfs，也是 0 ms，但只是线圈的读数）
     *   3. 都拿不到才连一次 BLE 读标准电池服务（1~3 s）
     *
     * @param battery 守护要我们立刻弹的数字；&lt;0 表示"守护已经直发弹过了，别重复弹"
     * @param coil    守护已用它弹过的线圈电量；最终值等于它就不补弹
     */
    static void attach(Context app, String mac, int battery, int coil, int state) {
        int st = (state == Capsule.STATE_CHARGING) ? Capsule.STATE_CHARGING : Capsule.STATE_IDLE;

        PenSystemBattery.Sample sys = PenSystemBattery.read(app);
        int show = battery;
        if (sys != null && sys.capacity >= 0) {
            // 系统自己知道，就用它的（还带充电状态，比我们猜的 state 准）
            show = sys.capacity;
            st = sys.charging ? Capsule.STATE_CHARGING : Capsule.STATE_IDLE;
        }
        boolean shown = Capsule.show(app, show, st);
        Log.i(PenBle.TAG, "ATTACH coil=" + coil + " battery=" + battery + " sys=" + sys
                + " state=" + st + " shown=" + shown);

        // 系统没给值 → 退回 GATT 读一次（装 hook 后这条路基本不会走到）
        if (sys == null || sys.capacity < 0) {
            PenBle.Result r = null;
            try {
                r = PenBle.readBattery(app, mac);
            } catch (Throwable t) {
                Log.e(PenBle.TAG, "battery read failed", t);
            }
            if (r == null) return;
            Log.i(PenBle.TAG, "ATTACH gatt " + r);
            if (r.battery >= 0 && r.battery != coil && r.battery != show) {
                Capsule.show(app, r.battery, st);      // 真值不同，补一条校正
            }
        }
    }
}
