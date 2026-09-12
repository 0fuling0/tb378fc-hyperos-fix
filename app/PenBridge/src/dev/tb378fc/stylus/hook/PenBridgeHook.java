package dev.tb378fc.stylus.hook;

import android.app.Activity;
import android.app.Application;
import android.app.Dialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.util.Log;
import android.view.MotionEvent;
import android.widget.PopupWindow;

import java.io.File;
import java.io.FileOutputStream;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * PenBridge 的 LSPosed 部分（作用域：笔记 / 小米创作）。
 *
 * 为什么需要在 App 进程里挂钩子：这两件事只有 App 自己知道 ——
 *
 * 1) 笔尾（橡皮端）靠近时，"是不是橡皮"是 MIUI 下发给 App 的状态
 *    （App 里能看到 `MiuiStylusPosture` / `isEraser=`，框架里是 `isEraserType`），
 *    联想笔永远进不了那个状态，所以 App 从不切成橡皮。
 *    这里把 {@code MotionEvent.getToolType(int)} 改成：只要笔尾在感应范围内就报
 *    {@code TOOL_TYPE_ERASER} → App 自己的橡皮逻辑生效，翻回笔尖自然又切回笔刷。
 *    笔尾状态由根侧守护广播 {@link #ACTION_TAIL} 送进来（penring 读 BTN_TOOL_RUBBER）。
 *
 * 2) "焦点在画布才开波形"：画布是否可写只有 App 知道（弹窗/面板打开时不该振）。
 *    这里盯 Activity 的窗口焦点 + Dialog/PopupWindow 的显示隐藏，把结论写进
 *    files/penstate（根侧守护读它决定要不要继续发 CON 波形）。
 *
 * 一切都包在 try/catch 里：hook 挂了也绝不能让 App 崩。
 */
public class PenBridgeHook implements IXposedHookLoadPackage {

    static final String TAG = "PenBridgeHook";
    /** 根侧守护 → hook：笔尾（橡皮端）进/出感应范围，extra "down"=1/0 */
    static final String ACTION_TAIL = "dev.tb378fc.stylus.TAIL";
    /** 根侧守护 → hook：笔尖也离开了（可选，用于收尾） */
    static final String ACTION_FORCE_FOCUS = "dev.tb378fc.stylus.FOCUS";

    /** 笔尾是否在感应范围内（由广播维护） */
    private static volatile boolean sTailDown = false;
    /** 当前 App 是否处于"可以写字"的状态（前台 + 没有弹窗/面板） */
    private static volatile boolean sCanvas = false;
    private static volatile Context sApp;
    private static int sDialogs = 0;
    private static int sPopups = 0;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        final String pkg = lpparam.packageName;
        if (!"com.miui.notes".equals(pkg) && !"com.miui.creation".equals(pkg)) return;

        hookToolType(lpparam);
        hookLifecycle(lpparam);
        registerStateReceiver();
        Log.i(TAG, "hooked " + pkg + " (api=" + Build.VERSION.SDK_INT + ")");
    }

    /** 1) 笔尾靠近 → 对 App 来说就是"橡皮工具" */
    private void hookToolType(XC_LoadPackage.LoadPackageParam lp) {
        try {
            XposedHelpers.findAndHookMethod(MotionEvent.class, "getToolType", int.class,
                    new XC_MethodHook() {
                        @Override
                        protected void afterHookedMethod(MethodHookParam param) {
                            if (!sTailDown) return;
                            int orig = (Integer) param.getResult();
                            if (orig == MotionEvent.TOOL_TYPE_STYLUS || orig == MotionEvent.TOOL_TYPE_ERASER) {
                                param.setResult(MotionEvent.TOOL_TYPE_ERASER);
                            }
                        }
                    });
            Log.i(TAG, "hook getToolType ok");
        } catch (Throwable t) {
            Log.e(TAG, "hook getToolType failed", t);
        }
    }

    /** 2) 画布焦点：前台 Activity + 没有弹窗/面板 → 可写 */
    private void hookLifecycle(XC_LoadPackage.LoadPackageParam lp) {
        try {
            XposedHelpers.findAndHookMethod(Activity.class, "onResume", new XC_MethodHook() {
                @Override protected void afterHookedMethod(MethodHookParam p) {
                    try { sApp = ((Activity) p.thisObject).getApplicationContext(); } catch (Throwable ignored) { }
                    updateCanvas(true, "activity resume");
                }
            });
            XposedHelpers.findAndHookMethod(Activity.class, "onPause", new XC_MethodHook() {
                @Override protected void beforeHookedMethod(MethodHookParam p) {
                    updateCanvas(false, "activity pause");
                }
            });
        } catch (Throwable t) {
            Log.e(TAG, "hook activity failed", t);
        }
        try {
            XposedHelpers.findAndHookMethod(Dialog.class, "show", new XC_MethodHook() {
                @Override protected void afterHookedMethod(MethodHookParam p) {
                    sDialogs++;
                    updateCanvas(false, "dialog show");
                }
            });
            XposedHelpers.findAndHookMethod(Dialog.class, "dismiss", new XC_MethodHook() {
                @Override protected void beforeHookedMethod(MethodHookParam p) {
                    if (sDialogs > 0) sDialogs--;
                    updateCanvas(sDialogs == 0 && sPopups == 0, "dialog dismiss");
                }
            });
        } catch (Throwable t) {
            Log.e(TAG, "hook dialog failed", t);
        }
        try {
            XposedHelpers.findAndHookMethod(PopupWindow.class, "showAsDropDown",
                    "android.view.View", int.class, int.class, int.class, new XC_MethodHook() {
                        @Override protected void afterHookedMethod(MethodHookParam p) {
                            sPopups++;
                            updateCanvas(false, "popup show");
                        }
                    });
            XposedHelpers.findAndHookMethod(PopupWindow.class, "dismiss", new XC_MethodHook() {
                @Override protected void beforeHookedMethod(MethodHookParam p) {
                    if (sPopups > 0) sPopups--;
                    updateCanvas(sDialogs == 0 && sPopups == 0, "popup dismiss");
                }
            });
        } catch (Throwable t) {
            Log.e(TAG, "hook popup failed", t);
        }
    }

    /** 把"可写/不可写"写进 files/penstate，根侧守护（root）读它决定要不要继续发波形 */
    private static void updateCanvas(boolean canvas, String why) {
        boolean changed = (canvas != sCanvas);
        sCanvas = canvas;
        if (!changed) return;
        Log.i(TAG, "canvas=" + canvas + " (" + why + ")");
        try {
            Context c = sApp;
            if (c == null) return;
            File f = new File(c.getFilesDir(), "penstate");
            FileOutputStream out = new FileOutputStream(f, false);
            out.write((canvas ? "canvas=1" : "canvas=0").getBytes());
            out.write(("\ntail=" + (sTailDown ? 1 : 0) + "\n").getBytes());
            out.close();
        } catch (Throwable t) {
            Log.w(TAG, "write penstate failed", t);
        }
    }

    /** 根侧守护用广播告诉我们笔尾状态（动态注册的接收器能收到隐式广播） */
    private void registerStateReceiver() {
        try {
            Context ctx = currentApp();
            if (ctx == null) { Log.w(TAG, "no app context yet, tail state disabled"); return; }
            IntentFilter filter = new IntentFilter();
            filter.addAction(ACTION_TAIL);
            filter.addAction(ACTION_FORCE_FOCUS);
            ctx.registerReceiver(new BroadcastReceiver() {
                @Override public void onReceive(Context context, Intent intent) {
                    String a = intent == null ? "" : String.valueOf(intent.getAction());
                    if (ACTION_TAIL.equals(a)) {
                        boolean down = intent.getIntExtra("down", 0) != 0;
                        if (down != sTailDown) {
                            sTailDown = down;
                            Log.i(TAG, "tail=" + down + " -> " + (down ? "TOOL_TYPE_ERASER" : "笔刷"));
                            updateCanvas(sCanvas, "tail change");
                        }
                    } else if (ACTION_FORCE_FOCUS.equals(a)) {
                        updateCanvas(intent.getIntExtra("canvas", 0) != 0, "forced");
                    }
                }
            }, filter);
            Log.i(TAG, "tail receiver registered");
        } catch (Throwable t) {
            Log.e(TAG, "register receiver failed", t);
        }
    }

    private static Context currentApp() {
        if (sApp != null) return sApp;
        try {
            Object at = XposedHelpers.callStaticMethod(
                    Class.forName("android.app.ActivityThread"), "currentActivityThread");
            Object app = XposedHelpers.callMethod(at, "getApplication");
            if (app instanceof Application) sApp = (Application) app;
        } catch (Throwable ignored) { }
        return sApp;
    }
}
