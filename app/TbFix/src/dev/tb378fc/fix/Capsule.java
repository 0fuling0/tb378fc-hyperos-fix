package dev.tb378fc.fix;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * 让 HyperOS 原生那条「手写笔电量胶囊」动起来。
 *
 * 逆向结论（细节见 docs/native-stylus-capsule.md）
 * ------------------------------------------------
 * 胶囊不是 SystemUI 画的，而是 SecurityCoreAdd.apk（com.miui.securitycore）里
 * com.miui.miinput.stylus 那套：
 *
 *     MiuiStylusReceiver          (exported=true，无 permission 限制)
 *       └─ com.android.settings.stylus.STYLUS_STATE_SOC   extras: battery / state / connect
 *            v
 *     MiuiStylusBatteryManager -> 浮窗 "StylusBattery"
 *            layout=stylus_info_layout  gravity=TOP|CENTER  type=2024
 *
 * 原生这条广播来自小米笔的 MIPP 协议栈（BluetoothExtension 的 MiuiBleOobHelperService）。
 * 联想笔走的是普通 BT HID，不说 MIPP，所以谁都不发 → 胶囊永远不出现。本类就是替它发。
 *
 * 参数语义（实测）
 * --------------
 *   battery : 0..100，胶囊里显示的电量数字；非法值直接不发（否则窗口会显示 "-1"）
 *   state   : 4 = 充电中（图标带闪电），2 = 未充电
 *   connect : 5 = 已连接（**只有 5 会直接弹电量胶囊**；2 仅在当前正显示"连接中"时才升级）
 *
 * 不需要任何权限：receiver 是 exported 且没挂 permission，显式组件广播即可送到。
 * （系统服务发的时候带了 miui.permission.USE_INTERNAL_GENERAL_API 作为 receiverPermission，
 *   那是对"接收方"的要求 —— SecurityCoreAdd 是系统应用本来就有；发送方不受影响。）
 */
public final class Capsule {
    public static final String TAG = "PenCapsule";

    public static final String ACTION_SOC = "com.android.settings.stylus.STYLUS_STATE_SOC";
    public static final String TARGET_PKG = "com.miui.securitycore";
    public static final String TARGET_CLS = "com.miui.miinput.stylus.MiuiStylusReceiver";

    /** state：正在充电（胶囊图标带闪电） */
    public static final int STATE_CHARGING = 4;
    /** state：未充电 */
    public static final int STATE_IDLE = 2;
    /** connect：已连接 —— 唯一会直接弹电量胶囊的值 */
    public static final int CONNECT_DONE = 5;

    private Capsule() { }

    /**
     * 弹一次原生电量胶囊。
     *
     * @param battery 0..100；超出范围视为未知，返回 false（不弹）
     * @param state   {@link #STATE_CHARGING} 或 {@link #STATE_IDLE}
     * @return 是否发出
     */
    public static boolean show(Context ctx, int battery, int state) {
        if (battery < 0 || battery > 100) {
            Log.i(TAG, "skip capsule: bad battery=" + battery);
            return false;
        }
        int st = (state == STATE_CHARGING) ? STATE_CHARGING : STATE_IDLE;
        Intent i = new Intent(ACTION_SOC);
        i.setComponent(new ComponentName(TARGET_PKG, TARGET_CLS));
        i.putExtra("battery", battery);
        i.putExtra("state", st);
        i.putExtra("connect", CONNECT_DONE);
        try {
            ctx.sendBroadcast(i);
            Log.i(TAG, "capsule sent: battery=" + battery + " state=" + st
                    + " connect=" + CONNECT_DONE);
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "capsule send failed", t);
            return false;
        }
    }
}
