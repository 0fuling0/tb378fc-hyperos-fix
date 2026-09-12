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

    @Override
    public void onReceive(Context context, Intent intent) {
        final PendingResult pending = goAsync();
        final Context app = context.getApplicationContext();
        final String action = intent == null ? "" : String.valueOf(intent.getAction());
        final String mac = intent == null ? null : intent.getStringExtra("mac");

        if (ACTION_ATTACH.equals(action)) {
            final int battery = intent.getIntExtra("battery", -1);
            final int state = intent.getIntExtra("state", Capsule.STATE_CHARGING);
            new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        attach(app, mac, battery, state);
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
            Log.i(PenBle.TAG, "ignored action " + action);
            try { pending.finish(); } catch (Throwable ignored) { }
            return;
        }

        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    PenBle.Result r = PenBle.run(app, mac);
                    Log.i(PenBle.TAG, "WAKE " + r);
                } catch (Throwable t) {
                    Log.e(PenBle.TAG, "wake failed", t);
                } finally {
                    try { pending.finish(); } catch (Throwable ignored) { }
                }
            }
        }, "penwake-rx").start();
    }

    /** 吸附：先用线圈电量立刻弹，再用 GATT 真值校正。 */
    static void attach(Context app, String mac, int battery, int state) {
        int st = (state == Capsule.STATE_CHARGING) ? Capsule.STATE_CHARGING : Capsule.STATE_IDLE;
        boolean shown = Capsule.show(app, battery, st);
        Log.i(PenBle.TAG, "ATTACH coil battery=" + battery + " state=" + st
                + " shown=" + shown);

        PenBle.Result r = null;
        try {
            r = PenBle.readBattery(app, mac);
        } catch (Throwable t) {
            Log.e(PenBle.TAG, "battery read failed", t);
        }
        if (r == null) return;
        Log.i(PenBle.TAG, "ATTACH gatt " + r);
        if (r.battery >= 0 && r.battery != battery) {
            Capsule.show(app, r.battery, st);
        }
    }
}
