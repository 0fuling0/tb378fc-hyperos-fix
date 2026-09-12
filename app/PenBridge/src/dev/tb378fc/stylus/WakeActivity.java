package dev.tb378fc.stylus;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

/**
 * 手动测试入口，无界面：
 *
 *     adb shell am start -n dev.tb378fc.stylus/.WakeActivity
 *
 * 用来在不依赖根侧守护的情况下单独验证那条 BLE 唤醒命令能不能发出去。
 */
public final class WakeActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        new Thread(new Runnable() {
            @Override public void run() {
                PenBle.Result r = PenBle.run(WakeActivity.this, null);
                Log.i(PenBle.TAG, "ACTIVITY " + r);
                runOnUiThread(new Runnable() { @Override public void run() { finish(); } });
            }
        }, "penwake-act").start();
    }
}
