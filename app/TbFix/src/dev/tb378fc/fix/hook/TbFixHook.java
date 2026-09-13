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
    /** 手写笔设置页所在的另一个进程（com.miui.securitycore = SecurityCoreAdd） */
    private static final String SECURITY_PKG = "com.miui.securitycore";
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
        // 设置页可能由系统设置或 com.miui.securitycore 承载（手写笔那两个 fragment 的资源在后者里），
        // 两个进程都挂，改笔参数才能即时下发。
        if (SETTINGS_PKG.equals(pkg) || SECURITY_PKG.equals(pkg)) {
            hookAonSettingsBool(pkg);
            hookStylusSettingsWrite(lpparam);
            return;
        }
        if (!"com.miui.notes".equals(pkg) && !"com.miui.creation".equals(pkg)) return;

        hookTouchTarget(lpparam);
        hookLifecycle(lpparam);
        // 注意：这里还没有 Context（ActivityThread 的 Application 可能还没建好），
        // 真正的注册放到第一次 onResume（见 updateCanvas/tryRegisterReceiver）。
        tryRegisterReceiver();
        Log.i(TAG, "hooked " + pkg + " (api=" + Build.VERSION.SDK_INT + ")");
    }

    /**
     * ⑪ 探测：一笔"落"在哪个 View 上。
     *
     * 目的：同一支笔在画布里点工具栏按钮/滑颜色条时 BTN_TOUCH 也是按下 —— 光看"笔在不在屏幕上"
     * 分不出"在写字"还是"在点控件"。真正的判据是**这一下触摸的目标 View 是不是画布**。
     * 这里先把 ACTION_DOWN 的 View 类名打出来（每个类名首见一条 + 前 30 条明细），
     * 认出画布类名后就能用它做闸门（只对落在画布上的笔迹开触感）。
     */
    private static final java.util.Set<String> sSeenView = new java.util.HashSet<>();
    private static boolean sTreeDumped = false;

    /** 把 View 树打出来（类名 / 尺寸 / id / 可见性），用来认出画布与工具栏 */
    private static void dumpTree(android.view.View v, int depth, String pad) {
        if (v == null || depth > 8) return;
        try {
            int w = v.getWidth(), h = v.getHeight();
            if (w > 40 && h > 40) {          // 跳过装饰性小 View，日志别太吵
                Log.i(TAG, "⑪ tree" + pad + v.getClass().getName()
                        + " " + w + "x" + h
                        + " @" + v.getLeft() + "," + v.getTop()
                        + " id=" + v.getId()
                        + " vis=" + (v.getVisibility() == android.view.View.VISIBLE ? "V" : "x"));
            }
            if (v instanceof android.view.ViewGroup) {
                android.view.ViewGroup g = (android.view.ViewGroup) v;
                for (int i = 0; i < g.getChildCount(); i++) {
                    dumpTree(g.getChildAt(i), depth + 1, pad + "  ");
                }
            }
        } catch (Throwable ignored) { }
    }
    private static int sTouchLogs = 0;
    private void hookTouchTarget(XC_LoadPackage.LoadPackageParam lp) {
        try {
            // 钩叶子 View 的 onTouchEvent：ViewGroup 会覆盖 dispatchTouchEvent，
            // 真正"吃掉"这一下触摸的是实现 onTouchEvent 的那个 View（画布 / 按钮 / 色条）。
            XposedBridge.hookAllMethods(android.view.View.class, "onTouchEvent",
                    new XC_MethodHook() {
                        @Override protected void beforeHookedMethod(MethodHookParam p) {
                            try {
                                MotionEvent e = (MotionEvent) p.args[0];
                                if (e == null) return;
                                int act = e.getActionMasked();
                                if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                                    return;                 // 抬手交给静音窗口决定何时恢复
                                }
                                // DOWN 与 MOVE 都记：在色条/工具栏上滑动时不断续期静音
                                if (act != MotionEvent.ACTION_DOWN && act != MotionEvent.ACTION_MOVE) return;
                                android.view.View v = (android.view.View) p.thisObject;
                                String cn = v.getClass().getName();
                                if (sSeenView.add(cn) || sTouchLogs < 40) {
                                    sTouchLogs++;
                                    Log.i(TAG, "⑪ touch DOWN view=" + cn
                                            + " tool=" + e.getToolType(0)
                                            + " size=" + v.getWidth() + "x" + v.getHeight()
                                            + " id=" + v.getId());
                                }
                                noteControlTouch(v);
                                // 第一次触摸时把整棵 View 树 dump 一次 —— 用来认出"画布"那一个
                                // （手指事件常被 App 拒掉、不落到画布上，所以光看 DOWN 的类名认不出来）
                                if (!sTreeDumped) {
                                    sTreeDumped = true;
                                    dumpTree(v.getRootView(), 0, "  ");
                                }
                            } catch (Throwable ignored) { }
                        }
                    });
            Log.i(TAG, "⑪ 触摸目标探测钩子已装");
        } catch (Throwable t) {
            Log.w(TAG, "⑪ hook touch target failed", t);
        }
    }

    /**
     * ⑫ 设置里改笔参数 → **立刻**让 App 下发 {8,6,mask} / {8,5,level}（原来要等根侧 2 秒轮询）。
     *
     * 在设置进程里按方法名钩 Settings.System 的写入（putInt/putString/...ForUser，
     * 不关心重载签名），key 是 stylus_* 就 150ms 去抖后读三个键 → 显式组件广播给 App
     * （不需要权限）。App 收到后只改 bit0/bit4，保住模块算好的上滑/下滑/笔尾位。
     */
    private static final String A_CFG = "dev.tb378fc.fix.CFG";
    private static final String APP_PKG = "dev.tb378fc.fix";
    private static final String APP_RCV = "dev.tb378fc.fix.WakeReceiver";
    private static volatile long sCfgPushAt = 0;

    private void pushStylusCfg(android.content.ContentResolver cr) {
        long now = android.os.SystemClock.uptimeMillis();
        if (now - sCfgPushAt < 150) return;           // 去抖：一次操作写多个键只发一次
        sCfgPushAt = now;
        try {
            android.content.Context ctx = currentApp();   // 复用自己的取 Context 助手（旧 API 桩里没有 AndroidAppHelper）
            if (ctx == null || cr == null) return;
            int dbl = android.provider.Settings.System.getInt(cr, "stylus_double_click_status", 1);
            int pinch = android.provider.Settings.System.getInt(cr, "stylus_pinch_status", 5);
            int adj = android.provider.Settings.System.getInt(cr, "stylus_pinch_pressure_adjust", 2);
            int level = adj + 1;
            if (level > 5) level = 5;
            if (level < 1) level = 1;
            android.content.Intent i = new android.content.Intent(A_CFG);
            i.setComponent(new android.content.ComponentName(APP_PKG, APP_RCV));
            i.putExtra("dbl", dbl != 0 ? 1 : 0);
            i.putExtra("pinch", pinch != 0 ? 1 : 0);
            i.putExtra("level", level);
            ctx.sendBroadcast(i);
            Log.i(TAG, "⑫ 设置变了 → 即时下发 dbl=" + (dbl != 0 ? 1 : 0)
                    + " pinch=" + (pinch != 0 ? 1 : 0) + " level=" + level);
        } catch (Throwable t) {
            Log.w(TAG, "⑫ push cfg failed", t);
        }
    }

    private void hookStylusSettingsWrite(XC_LoadPackage.LoadPackageParam lp) {
        String[] names = {"putInt", "putString", "putIntForUser", "putStringForUser"};
        for (String n : names) {
            try {
                XposedBridge.hookAllMethods(android.provider.Settings.System.class, n,
                        new XC_MethodHook() {
                            @Override protected void beforeHookedMethod(MethodHookParam p) {
                                try {
                                    if (p.args == null || p.args.length < 2) return;
                                    Object k = p.args[1];
                                    if (k instanceof String && ((String) k).startsWith("stylus_")) {
                                        pushStylusCfg((android.content.ContentResolver) p.args[0]);
                                    }
                                } catch (Throwable ignored) { }
                            }
                        });
            } catch (Throwable ignored) { }
        }
        Log.i(TAG, "⑫ 设置写入钩子已装（改笔参数即时下发）");
    }

    /**
     * ⑪ "这一下是不是落在控件上"。
     *
     * 实测（真笔 + dumpsys activity top）：
     *   画布 com.miui.handwirting.common.MiuiHandWritingView / SurfaceView **不经过 Java 触摸回调**
     *   —— 真笔在画布上画时，onTouchEvent 一条都不打；能打出来的只有控件（工具栏 ImageView/
     *   LinearLayout、色条上的 ColorSelectView）。
     * 所以反过来判：**凡是能在这个钩子里看到的笔触摸，就是控件触摸** → 立刻"静音"，
     * 静音窗口（MUTE_MS，滑动会不断续期）内不发触感；窗口过后恢复"在落笔"。
     * 画布笔迹因此天然落在"没有控件触摸"的时间段里。
     *
     * 加一个尺寸保险：万一某个 App 的画布也走 onTouchEvent，它通常占大半屏 → 不算控件。
     */
    private static final long CTRL_MUTE_MS = 1500;
    private static volatile long sMuteUntil = 0;
    private static final android.os.Handler sHandler =
            new android.os.Handler(android.os.Looper.getMainLooper());
    private static final Runnable sUnmute = new Runnable() {
        @Override public void run() {
            if (android.os.SystemClock.uptimeMillis() >= sMuteUntil) writeStroke(true);
        }
    };

    private static boolean looksLikeControl(android.view.View v) {
        try {
            int sw = v.getRootView() == null ? 0 : v.getRootView().getWidth();
            int sh = v.getRootView() == null ? 0 : v.getRootView().getHeight();
            if (sw <= 0 || sh <= 0) return true;
            return v.getWidth() < sw * 3 / 5 && v.getHeight() < sh * 3 / 5;
        } catch (Throwable t) {
            return true;
        }
    }

    private static void noteControlTouch(android.view.View v) {
        if (!looksLikeControl(v)) return;             // 大半屏的视图当画布，不静音
        sMuteUntil = android.os.SystemClock.uptimeMillis() + CTRL_MUTE_MS;
        writeStroke(false);
        sHandler.removeCallbacks(sUnmute);
        sHandler.postDelayed(sUnmute, CTRL_MUTE_MS + 50);
    }

    /** 把"正在落笔"写进 penstate（模块读它 + BTN_TOUCH 一起决定要不要开触感） */
    private static volatile boolean sStroke = false;
    private static void writeStroke(boolean stroke) {
        if (stroke == sStroke) return;
        sStroke = stroke;
        Log.i(TAG, "⑪ stroke=" + stroke);
        writePenState();
    }

    private static void writePenState() {
        try {
            Context c = sApp;
            if (c == null) return;
            File f = new File(c.getFilesDir(), "penstate");
            FileOutputStream out = new FileOutputStream(f, false);
            out.write((sCanvas ? "canvas=1" : "canvas=0").getBytes());
            out.write(("\nstroke=" + (sStroke ? 1 : 0) + "\n").getBytes());
            out.close();
        } catch (Throwable t) {
            Log.w(TAG, "write penstate failed", t);
        }
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
        if (canvas) {
            // 进画布先假定"在落笔"；真去点控件时 noteControlTouch 会把它压下去又恢复
            sMuteUntil = 0;
            sHandler.removeCallbacks(sUnmute);
            sHandler.postDelayed(new Runnable() {
                @Override public void run() { writeStroke(true); }
            }, 400);
        } else {
            writeStroke(false);
        }
        try {
            Context c = sApp;
            if (c == null) return;
            writePenState();
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
