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
    /** 当前 Activity 是不是编辑器/画布（只有它算"可写"，首页/列表一律禁） */
    private static volatile boolean sEditorActivity = false;
    private static volatile Context sApp;
    private static int sDialogs = 0;
    private static int sPopups = 0;
    /** 广播接收器只能注册一次；注册时机推迟到拿到 Context（第一次 onResume） */
    private static volatile boolean sReceiverReady = false;
    private static BroadcastReceiver sTailReceiver;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        final String pkg = lpparam.packageName;
        if (!"com.miui.notes".equals(pkg) && !"com.miui.creation".equals(pkg)) return;

        hookToolType(lpparam);
        hookStylusState(lpparam);
        hookLifecycle(lpparam);
        // 注意：这里还没有 Context（ActivityThread 的 Application 可能还没建好），
        // 真正的注册放到第一次 onResume（见 updateCanvas/tryRegisterReceiver）。
        tryRegisterReceiver();
        Log.i(TAG, "hooked " + pkg + " (api=" + Build.VERSION.SDK_INT + ")");
    }

    /** 1) 笔尾靠近 → 对 App 来说就是"橡皮工具" */
    private void hookToolType(XC_LoadPackage.LoadPackageParam lp) {
        try {
            XposedHelpers.findAndHookMethod(MotionEvent.class, "getToolType", int.class,
                    new XC_MethodHook() {
                        @Override
                        protected void afterHookedMethod(MethodHookParam param) {
                            int orig = (Integer) param.getResult();
                            // 只在"框架报的不是 STYLUS"时记一条（排查用；2=STYLUS 4=ERASER）
                            if (orig != MotionEvent.TOOL_TYPE_STYLUS && sToolLogs < 5) {
                                sToolLogs++;
                                Log.i(TAG, "getToolType orig=" + orig + " tail=" + sTailDown);
                            }
                            if (!sTailDown) return;
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

    /**
     * 1b) 小米创作/笔记的"笔状态"数据类 `fc.I11lii`：
     *     混淆后字段名不可读，但它的 toString 里能对上 isEraser / isTouchEraser / postureDegree，
     *     构造参数里还有 `gc.Iiliill touchType`（工具类型枚举，常量名也是混淆的）。
     *     笔尾在感应范围内时，把这个对象的两个 eraser 布尔强制为 true —— App 的橡皮逻辑就会生效。
     *     顺便打日志（前若干次 + 笔尾按下时）以便校准：能看出 touchType 到底是什么。
     */
    private static int sStateLogs = 0;
    /** 是否强制改写 eraser 布尔：默认关（实测会破坏 App 绘制管线）
     *  实测强制打开会破坏 App 的绘制管线（笔尾滑动既不画也不擦、抬手才按轨迹补一笔），
     *  因为 isEraser 要与"橡皮端的坐标/几何"配套，光改标志位状态机就错乱了。
     *  这里保留开关，等找到上游 producer（真正的橡皮判定）再用。 */
    private static final boolean FORCE_ERASER = false;
    private static int sToolLogs = 0;
    private void hookStylusState(XC_LoadPackage.LoadPackageParam lp) {
        // 注意：真实类名里有希腊字母 ι（U+03B9），jadx 输出到文件名时会变成 ASCII 的 "I"
        Class<?> cls = null;
        String hit = null;
        for (String name : new String[]{"fc.I\u03b911lii", "fc.I11lii"}) {
            cls = XposedHelpers.findClassIfExists(name, lp.classLoader);
            if (cls != null) { hit = name; break; }
        }
        if (cls == null) { Log.i(TAG, "fc.I\u03b911lii 不存在（版本不同？）"); return; }
        Log.i(TAG, "找到笔状态类 " + hit);
        for (java.lang.reflect.Constructor<?> ctor : cls.getDeclaredConstructors()) {
            try {
                XposedBridge.hookMethod(ctor, new XC_MethodHook() {
                    @Override protected void beforeHookedMethod(MethodHookParam p) {
                        try {
                            Object[] a = p.args;
                            if (a == null || a.length < 10) return;
                            boolean logIt = sTailDown || sStateLogs < 5;
                            if (logIt) {
                                sStateLogs++;
                                Log.i(TAG, "I11lii ctor touchType=" + a[5]
                                        + " bool7=" + a[6] + " posture=" + a[7]
                                        + " int9=" + a[8] + " bool10=" + a[9]
                                        + " tail=" + sTailDown);
                            }
                            if (FORCE_ERASER && sTailDown) {
                                a[6] = Boolean.TRUE;
                                a[9] = Boolean.TRUE;
                            }
                        } catch (Throwable ignored) { }
                    }
                });
            } catch (Throwable t) {
                Log.w(TAG, "hook I11lii ctor failed", t);
            }
        }
        Log.i(TAG, "hook fc.I11lii ok");
    }

    /** 2) 画布焦点：前台 Activity + 没有弹窗/面板 → 可写 */
    private void hookLifecycle(XC_LoadPackage.LoadPackageParam lp) {
        try {
            XposedHelpers.findAndHookMethod(Activity.class, "onResume", new XC_MethodHook() {
                @Override protected void afterHookedMethod(MethodHookParam p) {
                    Object a = p.thisObject;
                    try { sApp = ((Activity) a).getApplicationContext(); } catch (Throwable ignored) { }
                    tryRegisterReceiver();
                    String cls = a == null ? "?" : a.getClass().getName();
                    sEditorActivity = isEditorActivity(cls);
                    Log.i(TAG, "resume " + cls + " editor=" + sEditorActivity);
                    recomputeCanvas("resume " + cls);
                }
            });
            XposedHelpers.findAndHookMethod(Activity.class, "onPause", new XC_MethodHook() {
                @Override protected void beforeHookedMethod(MethodHookParam p) {
                    // 切 Activity 时先按"离开画布"处理；紧接着的 onResume 会按新 Activity 修正
                    sEditorActivity = false;
                    recomputeCanvas("activity pause");
                }
            });
        } catch (Throwable t) {
            Log.e(TAG, "hook activity failed", t);
        }
        try {
            XposedHelpers.findAndHookMethod(Dialog.class, "show", new XC_MethodHook() {
                @Override protected void afterHookedMethod(MethodHookParam p) {
                    sDialogs++;
                    recomputeCanvas("dialog show");
                }
            });
            XposedHelpers.findAndHookMethod(Dialog.class, "dismiss", new XC_MethodHook() {
                @Override protected void beforeHookedMethod(MethodHookParam p) {
                    if (sDialogs > 0) sDialogs--;
                    // 注意：不能无脑 canvas=true —— 弹窗关掉时当前 Activity 可能早就不是编辑器了
                    recomputeCanvas("dialog dismiss");
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
                            recomputeCanvas("popup show");
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

    /** 状态机唯一出口：画布可写 = 当前是编辑器 Activity 且没有弹窗/面板 */
    private static void recomputeCanvas(String why) {
        boolean canvas = sEditorActivity && sDialogs == 0 && sPopups == 0;
        updateCanvas(canvas, why + " [editor=" + sEditorActivity
                + " dialogs=" + sDialogs + " popups=" + sPopups + "]");
    }

    /**
     * 只有真正的编辑器/画布 Activity 才算"可写"。
     * 首页/列表/设置页不算 —— 否则一进 App 就振，而真正进画布时状态没变反而不振
     * （用户实测：进画布第一次不振、画布外反而振）。
     * 类名里带 Edit / Canvas / Draw / Paint / Note 的都当画布，日志会把实际类名打出来便于校准。
     */
    private static boolean isEditorActivity(String cls) {
        if (cls == null) return false;
        if (cls.contains("Setting") || cls.contains("Home") || cls.contains("Main")
                || cls.contains("List") || cls.contains("Launcher")) return false;
        return cls.contains("Edit") || cls.contains("Canvas") || cls.contains("Draw")
                || cls.contains("Paint") || cls.contains("Note");
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
    private static void tryRegisterReceiver() {
        if (sReceiverReady) return;
        try {
            Context ctx = currentApp();
            if (ctx == null) { Log.w(TAG, "no app context yet, will retry on resume"); return; }
            IntentFilter filter = new IntentFilter();
            filter.addAction(ACTION_TAIL);
            filter.addAction(ACTION_FORCE_FOCUS);
            sTailReceiver = new BroadcastReceiver() {
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
                        recomputeCanvas("forced");
                    }
                }
            };
            /* API 33+ 注册非系统广播必须显式声明导出与否；这里要收 shell/root 发来的广播 → EXPORTED(2)。
             * 用反射调 3 参重载，免得在旧 API 上 NoSuchMethod。 */
            boolean ok = false;
            if (Build.VERSION.SDK_INT >= 33) {
                try {
                    java.lang.reflect.Method m = Context.class.getMethod("registerReceiver",
                            BroadcastReceiver.class, IntentFilter.class, int.class);
                    m.invoke(ctx, sTailReceiver, filter, 2 /* RECEIVER_EXPORTED */);
                    ok = true;
                } catch (Throwable t) {
                    Log.w(TAG, "registerReceiver(flags) failed, fallback", t);
                }
            }
            if (!ok) ctx.registerReceiver(sTailReceiver, filter);
            sReceiverReady = true;
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
