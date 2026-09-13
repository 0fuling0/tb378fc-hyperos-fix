package dev.tb378fc.fix.hook;

import android.app.Activity;
import android.app.Application;
import android.app.Dialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.res.Resources;
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
 * TbFix 的 LSPosed 部分。作用域与各自职责：
 *
 *   笔记 / 小米创作（App 进程）
 *     "焦点在画布才开波形"：画布是否可写只有 App 自己知道（弹窗/面板打开时不该振）。
 *     这里盯 Activity 的窗口焦点 + Dialog/PopupWindow 的显示隐藏，把结论写进
 *     files/penstate —— 根侧守护读它决定要不要继续发 CON 波形。
 *
 *   设置 com.android.settings
 *     「视觉感知 / 注视感知」那一页的可见性：移植包把 com.miui.rom 里三个 AON bool
 *     写成 false，这里按资源名放行 getBoolean（不动系统分区，详见 docs/aon-attention.md）。
 *
 *   android（system_server）
 *     注视感知的两道门：接管移植包里没注册的 HyperOSCustFeatureResolve，
 *     以及 PMS 的 getSupportAonServicePackageName / getAttentionServicePackageName。
 *
 * 一切都包在 try/catch 里：hook 挂了也绝不能让 App 崩。
 */
public class TbFixHook implements IXposedHookLoadPackage {

    static final String TAG = "TbFixHook";
    /** 根侧守护 → hook：强制重算一次画布焦点 */
    static final String ACTION_FORCE_FOCUS = "dev.tb378fc.fix.FOCUS";

    /** 当前 App 是否处于"可以写字"的状态（前台 + 没有弹窗/面板） */
    private static volatile boolean sCanvas = false;
    /** 当前 Activity 是不是编辑器/画布（只有它算"可写"，首页/列表一律禁） */
    private static volatile boolean sEditorActivity = false;
    private static volatile Context sApp;
    private static int sDialogs = 0;
    private static int sPopups = 0;
    /** 广播接收器只能注册一次；注册时机推迟到拿到 Context（第一次 onResume） */
    private static volatile boolean sReceiverReady = false;
    private static BroadcastReceiver sFocusReceiver;

    /** 注视感知（AON）：这个移植包没注册 HyperOSCustFeatureResolve 服务，
     *  所有 getBoolean 都会抛异常→返回默认 false→PMS 的 config_supported_aon_devices 门永远过不去。
     *  这里在 system_server（作用域 "android"）里把这个 key 短路成 true。 */
    private static final String ACTION_AON = "config_supported_aon_devices";
    private static final String SYS_PKG = "android";

    /** AON 服务的包名（覆盖层里 config_defaultAttentionService 的值就是它） */
    private static final String AON_PKG = "com.xiaomi.aon";

    /** ⑧c 设置里那一页「视觉感知 / 注视感知」的可见性开关。
     *
     *  移植包自带的 /product/overlay/MiuiFrameworkResOverlay.apk 把 com.miui.rom 里这三个
     *  bool 写成了 false，设置 App 读到就 removePreference 掉那一页：
     *      config_aon_gesture_available / config_aon_screen_on_available / config_aon_screen_off_available
     *  这里在设置进程里按"资源名"放行（不改任何系统分区、不改资源本身）。
     *
     *  ⚠️ 曾经试过用 RRO 覆盖层改这三个资源：tmpfs 盖住 /product/overlay 再 cp 回来，结果那
     *  83 个 MIUI/SystemUI overlay 全丢了 SELinux 标签（变成 tmpfs:s0）被 system_server 拒读，
     *  锁屏时钟、控制中心整批消失。**别再走那条路。** */
    private static final String SETTINGS_PKG = "com.android.settings";
    private static final String[] AON_BOOLS = {
            "config_aon_gesture_available",
            "config_aon_screen_on_available",
            "config_aon_screen_off_available",
    };
    private static final java.util.Set<Integer> sAonBoolIds = new java.util.HashSet<>();
    private static volatile boolean sAonResolved = false;

    /** 资源 id 缓存：getBoolean 是热路径，不能每次都拿名字去比。 */
    private static boolean isAonBool(Resources res, int id) {
        if (!sAonResolved) {
            synchronized (sAonBoolIds) {
                if (!sAonResolved) {
                    for (String b : AON_BOOLS) {
                        try {
                            int rid = res.getIdentifier(b, "bool", "com.miui.rom");
                            if (rid != 0) sAonBoolIds.add(rid);
                        } catch (Throwable ignored) { }
                    }
                    sAonResolved = true;
                    Log.i(TAG, "⑧c AON bool ids = " + sAonBoolIds);
                }
            }
        }
        if (!sAonBoolIds.isEmpty()) return sAonBoolIds.contains(id);
        /* 解析不到 id（包里没有那份资源表）时的退路：按名字比，但只试有限次，避免热路径开销 */
        try {
            String n = res.getResourceName(id);
            if (n == null) return false;
            for (String b : AON_BOOLS) if (n.endsWith("bool/" + b)) return true;
        } catch (Throwable ignored) { }
        return false;
    }

    private void hookAonSettingsBool(String pkg) {
        try {
            XposedHelpers.findAndHookMethod(Resources.class, "getBoolean", int.class,
                    new XC_MethodHook() {
                        @Override protected void afterHookedMethod(MethodHookParam p) {
                            try {
                                if (Boolean.TRUE.equals(p.getResult())) return;
                                int id = (Integer) p.args[0];
                                Resources res = (Resources) p.thisObject;
                                if (isAonBool(res, id)) {
                                    p.setResult(Boolean.TRUE);
                                    Log.i(TAG, "⑧c " + res.getResourceName(id) + " -> true");
                                }
                            } catch (Throwable ignored) { }
                        }
                    });
            Log.i(TAG, "⑧c hook Resources.getBoolean ok (" + pkg + ")");
        } catch (Throwable t) {
            Log.w(TAG, "⑧c hook settings getBoolean failed", t);
        }
    }

    /**
     * 直接接管 system_server 里"注视服务配好了没"的最终判断：
     *   PackageManagerServiceImpl.getSupportAonServicePackageName()  ← 上游开关不满足时返回 ""
     *   PackageManagerService.getAttentionServicePackageName()       ← AOSP 侧读的就是它
     * 哪个存在钩哪个：直接返回 com.xiaomi.aon（其余逻辑不影响）。
     */
    private void hookAonPackageName(String pkg) {
        String[] classes = {
                "com.android.server.pm.PackageManagerServiceImpl",
                "com.android.server.pm.PackageManagerService",
        };
        String[] methods = {"getSupportAonServicePackageName", "getAttentionServicePackageName"};
        for (String cn : classes) {
            Class<?> c = XposedHelpers.findClassIfExists(cn, ClassLoader.getSystemClassLoader());
            if (c == null) continue;
            for (String mn : methods) {
                try {
                    XposedHelpers.findAndHookMethod(c, mn, new XC_MethodHook() {
                        @Override protected void afterHookedMethod(MethodHookParam p) {
                            Object r = p.getResult();
                            if (r == null || String.valueOf(r).isEmpty()) {
                                p.setResult(AON_PKG);
                                Log.i(TAG, "AON pkg -> " + AON_PKG + " (" + p.method.getName() + ")");
                            }
                        }
                    });
                    Log.i(TAG, "hook " + cn + "." + mn + " ok");
                } catch (Throwable ignored) { }
            }
        }
    }

    private void hookCustFeature(String pkg) {
        try {
            Class<?> c = XposedHelpers.findClassIfExists("miui.os.HyperOSCustFeatureResolve",
                    ClassLoader.getSystemClassLoader());
            if (c == null) { Log.i(TAG, "HyperOSCustFeatureResolve 不存在"); return; }
            XposedHelpers.findAndHookMethod(c, "getBoolean", String.class, boolean.class,
                    new XC_MethodHook() {
                        @Override protected void afterHookedMethod(MethodHookParam p) {
                            try {
                                Object k = p.args == null || p.args.length < 1 ? null : p.args[0];
                                if (ACTION_AON.equals(k) && Boolean.FALSE.equals(p.getResult())) {
                                    p.setResult(Boolean.TRUE);
                                    Log.i(TAG, "cust " + ACTION_AON + " -> true (served locally)");
                                }
                            } catch (Throwable ignored) { }
                        }
                    });
            Log.i(TAG, "hook HyperOSCustFeatureResolve.getBoolean ok (" + pkg + ")");
        } catch (Throwable t) {
            Log.w(TAG, "hook cust feature failed", t);
        }
    }

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        final String pkg = lpparam.packageName;
        if (SYS_PKG.equals(pkg)) {          // system_server：注视感知的两道门
            hookCustFeature(pkg);
            hookAonPackageName(pkg);
            return;
        }
        if (SETTINGS_PKG.equals(pkg)) {     // 设置：让「视觉感知/注视感知」那一页别被 removePreference
            hookAonSettingsBool(pkg);
            return;
        }
        if (!"com.miui.notes".equals(pkg) && !"com.miui.creation".equals(pkg)) return;

        hookLifecycle(lpparam);
        // 注意：这里还没有 Context（ActivityThread 的 Application 可能还没建好），
        // 真正的注册放到第一次 onResume（见 updateCanvas/tryRegisterReceiver）。
        tryRegisterReceiver();
        Log.i(TAG, "hooked " + pkg + " (api=" + Build.VERSION.SDK_INT + ")");
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
            out.close();
        } catch (Throwable t) {
            Log.w(TAG, "write penstate failed", t);
        }
    }

    /** 根侧守护用广播让我们强制重算一次画布焦点（动态注册的接收器能收到隐式广播） */
    private static void tryRegisterReceiver() {
        if (sReceiverReady) return;
        try {
            Context ctx = currentApp();
            if (ctx == null) { Log.w(TAG, "no app context yet, will retry on resume"); return; }
            IntentFilter filter = new IntentFilter();
            filter.addAction(ACTION_FORCE_FOCUS);
            sFocusReceiver = new BroadcastReceiver() {
                @Override public void onReceive(Context context, Intent intent) {
                    String a = intent == null ? "" : String.valueOf(intent.getAction());
                    if (ACTION_FORCE_FOCUS.equals(a)) {
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
                    m.invoke(ctx, sFocusReceiver, filter, 2 /* RECEIVER_EXPORTED */);
                    ok = true;
                } catch (Throwable t) {
                    Log.w(TAG, "registerReceiver(flags) failed, fallback", t);
                }
            }
            if (!ok) ctx.registerReceiver(sFocusReceiver, filter);
            sReceiverReady = true;
            Log.i(TAG, "focus receiver registered");
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
