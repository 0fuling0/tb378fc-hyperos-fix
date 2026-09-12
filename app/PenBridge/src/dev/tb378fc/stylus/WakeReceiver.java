package dev.tb378fc.stylus;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * 根侧守护进程的入口：收到 WAKE 广播就去发那条 BLE 唤醒命令。
 *
 * 用显式广播打到 manifest 里声明的 receiver，是这台 ROM 上后台应用唯一被允许的启动方式
 * （`am startservice` 会被拒绝："app is in background uid null"）。
 * goAsync() 让进程在整个 BLE 事务（约 1-2 秒）期间保持存活。
 */
public final class WakeReceiver extends BroadcastReceiver {
    public static final String ACTION_WAKE = "dev.tb378fc.stylus.WAKE";

    @Override
    public void onReceive(Context context, Intent intent) {
        final PendingResult pending = goAsync();
        final Context app = context.getApplicationContext();
        final String action = intent == null ? "" : String.valueOf(intent.getAction());
        final String mac = intent == null ? null : intent.getStringExtra("mac");

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
}
