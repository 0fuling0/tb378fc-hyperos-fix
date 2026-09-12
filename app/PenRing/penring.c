/*
 * penring —— 把联想 Tab Pen Pro 2 的手势桥成"小米焦点触控笔（带快捷环那支）"
 *
 * 背景（全部实测，见 docs/stylus-gesture-bridge.md）
 * ================================================
 * 联想笔的手势由笔内触控膜检测，经 BLE HID Report ID 2（consumer control）
 * 上报；内核把它翻成 `KEY_UNKNOWN(240)` + `MSC_SCAN = 0x000C06xx`，落在
 *   /dev/input/eventN  name="Lenovo Tab Pen Pro 2 Consumer Control"
 * 上（这台机器上是 event10）：
 *
 *   0x0c0619 捏下      0x0c0620 捏松
 *   0x0c0601 双击
 *   0x0c0613 上滑      0x0c0612 下滑
 *   0x0c0623 笔尾按住  0x0c0624 笔尾松开
 *
 * 而 HyperOS 只认"小米触控膜笔"：MIUI 的
 *   MiuiStylusTouchFilmManager / MiuiStylusShortcutManager
 * 要求事件来自 `InputDevice.isXiaomiStylus()` ∈ {8} 的设备
 * （vendor 0x0022 / product 0x5081），并且键码必须是
 *   194 轻捏（快捷环）· 195 双击 · 196 上滑 · 197 下滑
 *   92 截图键（按住+点屏=截图标注）· 93 速记键（按住+点屏=灵感速记）
 *
 * 所以这里做两件事：
 *   1. 造一支 type-8 虚拟笔（uinput），把上面 6 个键注进去；
 *   2. 在 /data/system/devices/keylayout/Vendor_0022_Product_5081.kl 里把
 *      注入用的 Linux 键码映射成 Android 键码：
 *        key 104 PAGE_UP(92) / 109 PAGE_DOWN(93)
 *        key 194..197 BUTTON_7..BUTTON_10  == Android 194..197
 *      （**这一步是关键**：本 ROM 的 Generic.kl 把 raw 194 映射成 F24=337，
 *        不是 194，MIUI 的拦截分支根本不会进）
 *
 * 于是联想笔在这台机器上的行为就跟小米焦点触控笔一样：
 *   捏     -> 快捷环（系统级，任何 App 都弹）
 *   双击   -> MIUI 双击（小米创作等自己开过触控膜的 App；否则被 MIUI 吞掉）
 *   上滑/下滑 -> MIUI 上滑/下滑（白名单 App 会被 MIUI 转成 92/93 翻页）
 *   笔尾按住 -> 截图键：按住约 0.4s 再点屏幕 = 截图标注（换成 93 = 灵感速记）
 * 遥控（短视频翻页）与"旋转笔身调笔刷方向"不做：前者要特定 App，
 * 后者需要笔里有陀螺仪，这支没有。
 *
 * 映射全部可以在 module/config 里改（GESTURE_* ），改完重启模块即可。
 *
 * 用法：penring [--moddir DIR] [--config FILE] [--log FILE] [--once]
 * 由 module/service.sh 以 root 常驻运行；笔不在时自己待机轮询。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* ---------- 联想笔的 consumer usage（evdev 的 MSC_SCAN 值） ---------- */
#define U_DOUBLE_TAP   0x0c0601
#define U_SLIDE_DOWN   0x0c0612
#define U_SLIDE_UP     0x0c0613
#define U_PINCH_DOWN   0x0c0619
#define U_PINCH_UP     0x0c0620
#define U_TAIL_DOWN    0x0c0623
#define U_TAIL_UP      0x0c0624

/* ---------- 注入用的 Linux 键码（由我们的 kl 映射成 Android 键码） ---------- */
#define K_PAGEUP   104   /* -> Android 92  KEYCODE_PAGE_UP   = 小米"截图键" */
#define K_PAGEDOWN 109   /* -> Android 93  KEYCODE_PAGE_DOWN = 小米"速记键" */
#define K_F24      194   /* -> Android 194 轻捏（快捷环） */
#define K_F25      195   /* -> Android 195 双击 */
#define K_F26      196   /* -> Android 196 上滑 */
#define K_F27      197   /* -> Android 197 下滑 */

#define DEF_MODDIR "/data/adb/modules/tb378fc_hyperos_fix"
#define KL_DIR     "/data/system/devices/keylayout"
#define KL_PATH    KL_DIR "/Vendor_0022_Product_5081.kl"
#define UI_NAME    "Xiaomi Pen"
#define UI_VENDOR  0x0022
#define UI_PRODUCT 0x5081

static const char KL_BODY[] =
    "# 由 tb378fc_hyperos_fix/penring 写入：联想笔手势桥的键位映射。\n"
    "# 作用：把注入的 Linux 键码翻成 HyperOS 认的 Android 键码\n"
    "#   194..197 -> BUTTON_7..10 == Android 194..197（轻捏/双击/上滑/下滑）\n"
    "#   104/109  -> PAGE_UP/PAGE_DOWN == Android 92/93（截图键/速记键）\n"
    "# 本 ROM 的 Generic.kl 是小米改过的（key 194 F24 → Android 337），\n"
    "# 所以这支虚拟笔必须有自己的 kl，否则 MIUI 收不到 194..197。\n"
    "key 104   PAGE_UP\n"
    "key 109   PAGE_DOWN\n"
    "key 194   BUTTON_7\n"
    "key 195   BUTTON_8\n"
    "key 196   BUTTON_9\n"
    "key 197   BUTTON_10\n";

/* ---------- 配置（module/config 里的 GESTURE_*） ---------- */
struct cfg {
    int ring;        /* 捏        -> Android 键码，-1 关 */
    int double_tap;  /* 双击      -> 键码 */
    int slide_up;    /* 上滑      -> 键码 */
    int slide_down;  /* 下滑      -> 键码 */
    int tail;        /* 笔尾按住  -> 键码（92 截图 / 93 速记 / -1 关） */
};

static struct cfg g_cfg = {194, 195, 196, 197, 92};
static const char *g_moddir = DEF_MODDIR;
static const char *g_log = NULL;
static const char *g_dev = NULL;   /* --dev：强制读某个 event 节点（自检/排障用） */
static char g_touch_path[256];     /* --watch --touch 的触控节点 */
static int g_ui = -1;
static volatile sig_atomic_t g_stop = 0;
static long g_tail_down_ms = 0;   /* 笔尾按下的时刻，用来过滤误触 */

/* ---------------------------------------------------------------- 日志 */
static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void logf_(const char *fmt, ...)
{
    char buf[512];
    char ts[32];
    time_t t = time(NULL);
    struct tm tm;
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%F %T", &tm);
    fprintf(stderr, "%s %s\n", ts, buf);
    fflush(stderr);

    if (g_log) {
        FILE *f = fopen(g_log, "a");
        if (f) {
            fprintf(f, "%s %s\n", ts, buf);
            fclose(f);
        }
    }
}

/* ---------------------------------------------------------------- 配置解析 */
static int parse_int(const char *s, int dflt)
{
    char *end;
    long v;
    if (s == NULL || *s == '\0') return dflt;
    v = strtol(s, &end, 0);
    if (end == s) return dflt;
    return (int)v;
}

/* Android 键码 -> 注入用的 Linux 键码（只差 92/93 这两个翻页键） */
static int raw_of(int android_key)
{
    switch (android_key) {
    case 92:  return K_PAGEUP;
    case 93:  return K_PAGEDOWN;
    default:  return android_key;
    }
}

static void load_config(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[512];
    if (!f) return;

    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        char *k = line;
        char *v;
        char *nl;
        if (line[0] == '#' || eq == NULL) continue;
        *eq = '\0';
        v = eq + 1;
        nl = strchr(v, '\n');
        if (nl) *nl = '\0';
        if (*k == '\0') continue;

        if      (!strcmp(k, "GESTURE_RING"))        g_cfg.ring = parse_int(v, g_cfg.ring);
        else if (!strcmp(k, "GESTURE_DOUBLE"))      g_cfg.double_tap = parse_int(v, g_cfg.double_tap);
        else if (!strcmp(k, "GESTURE_SLIDE_UP"))    g_cfg.slide_up = parse_int(v, g_cfg.slide_up);
        else if (!strcmp(k, "GESTURE_SLIDE_DOWN"))  g_cfg.slide_down = parse_int(v, g_cfg.slide_down);
        else if (!strcmp(k, "GESTURE_TAIL"))        g_cfg.tail = parse_int(v, g_cfg.tail);
    }
    fclose(f);
    logf_("config: ring=%d double=%d slideUp=%d slideDown=%d tail=%d",
          g_cfg.ring, g_cfg.double_tap, g_cfg.slide_up, g_cfg.slide_down, g_cfg.tail);
}

/* ---------------------------------------------------------------- 键位文件 */
static void write_keylayout(void)
{
    char cur[1024];
    size_t n = 0;
    FILE *f;
    int same = 0;

    mkdir("/data/system/devices", 0755);
    mkdir(KL_DIR, 0755);

    f = fopen(KL_PATH, "r");
    if (f) {
        n = fread(cur, 1, sizeof(cur) - 1, f);
        cur[n] = '\0';
        fclose(f);
        if (n == sizeof(KL_BODY) - 1 && memcmp(cur, KL_BODY, n) == 0) same = 1;
    }
    if (same) return;

    f = fopen(KL_PATH, "w");
    if (!f) {
        logf_("ERROR 写 %s 失败: %s", KL_PATH, strerror(errno));
        return;
    }
    fputs(KL_BODY, f);
    fclose(f);
    chmod(KL_PATH, 0644);
    logf_("keylayout 写入 %s（%u 字节）", KL_PATH, (unsigned)(sizeof(KL_BODY) - 1));
}

/* ---------------------------------------------------------------- uinput */
static void emit(int fd, int type, int code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    if (write(fd, &ev, sizeof(ev)) < 0) logf_("ERROR write uinput: %s", strerror(errno));
}

static void key_press(int fd, int raw)   { emit(fd, EV_MSC, MSC_SCAN, raw); emit(fd, EV_KEY, raw, 1); emit(fd, EV_SYN, SYN_REPORT, 0); }
static void key_release(int fd, int raw) { emit(fd, EV_KEY, raw, 0); emit(fd, EV_SYN, SYN_REPORT, 0); }
static void key_tap(int fd, int raw)     { key_press(fd, raw); key_release(fd, raw); }

static int ui_create(void)
{
    struct uinput_setup us;
    int keys[] = {K_PAGEUP, K_PAGEDOWN, K_F24, K_F25, K_F26, K_F27};
    unsigned i;
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);

    if (fd < 0) {
        logf_("ERROR open /dev/uinput: %s", strerror(errno));
        return -1;
    }
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_MSC);
    ioctl(fd, UI_SET_MSCBIT, MSC_SCAN);
    for (i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
        ioctl(fd, UI_SET_KEYBIT, keys[i]);

    memset(&us, 0, sizeof(us));
    us.id.bustype = BUS_BLUETOOTH;
    us.id.vendor = UI_VENDOR;
    us.id.product = UI_PRODUCT;
    us.id.version = 0x0100;
    snprintf(us.name, UINPUT_MAX_NAME_SIZE, "%s", UI_NAME);

    if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        logf_("ERROR UI_DEV_SETUP/CREATE: %s", strerror(errno));
        close(fd);
        return -1;
    }
    logf_("虚拟笔已建立：'%s' bus=0x0005 vendor=0x%04x product=0x%04x "
          "(isXiaomiStylus()==8 → MIUI 触控膜笔)", UI_NAME, UI_VENDOR, UI_PRODUCT);
    return fd;
}

static void ui_destroy(void)
{
    if (g_ui >= 0) {
        ioctl(g_ui, UI_DEV_DESTROY);
        close(g_ui);
        g_ui = -1;
        logf_("虚拟笔已销毁");
    }
}

/* ---------------------------------------------------------------- 找笔 */
static int find_pen(char *path, size_t pathlen)
{
    int i;
    if (g_dev != NULL) {
        int fd = open(g_dev, O_RDONLY | O_NONBLOCK);
        char name[256] = {0};
        if (fd < 0) return -1;
        ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
        logf_("按 --dev 使用 %s（'%s'）", g_dev, name);
        snprintf(path, pathlen, "%s", g_dev);
        return fd;
    }
    for (i = 0; i < 64; i++) {
        char name[256];
        int fd;
        snprintf(path, pathlen, "/dev/input/event%d", i);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        memset(name, 0, sizeof(name));
        if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) > 0 &&
            strstr(name, "Consumer Control") &&
            (strstr(name, "Pen") || strstr(name, "Tab"))) {
            logf_("找到笔的手势节点 %s（'%s'）", path, name);
            return fd;
        }
        close(fd);
    }
    return -1;
}

/* ---------------------------------------------------------------- 手势映射 */
static void on_usage(int scan)
{
    if (scan == U_PINCH_DOWN) {
        if (g_cfg.ring < 0) return;
        logf_("捏        → Android %d（快捷环）", g_cfg.ring);
        key_press(g_ui, raw_of(g_cfg.ring));
    } else if (scan == U_PINCH_UP) {
        if (g_cfg.ring < 0) return;
        key_release(g_ui, raw_of(g_cfg.ring));
    } else if (scan == U_DOUBLE_TAP) {
        if (g_cfg.double_tap < 0) return;
        logf_("双击      → Android %d", g_cfg.double_tap);
        key_tap(g_ui, raw_of(g_cfg.double_tap));
    } else if (scan == U_SLIDE_UP) {
        if (g_cfg.slide_up < 0) return;
        logf_("上滑      → Android %d", g_cfg.slide_up);
        key_tap(g_ui, raw_of(g_cfg.slide_up));
    } else if (scan == U_SLIDE_DOWN) {
        if (g_cfg.slide_down < 0) return;
        logf_("下滑      → Android %d", g_cfg.slide_down);
        key_tap(g_ui, raw_of(g_cfg.slide_down));
    } else if (scan == U_TAIL_DOWN) {
        if (g_cfg.tail < 0) return;
        g_tail_down_ms = now_ms();
        logf_("笔尾按住  → Android %d（%s）", g_cfg.tail,
              g_cfg.tail == 93 ? "速记键" : (g_cfg.tail == 92 ? "截图键" : "自定义"));
        key_press(g_ui, raw_of(g_cfg.tail));
    } else if (scan == U_TAIL_UP) {
        if (g_cfg.tail < 0) return;
        key_release(g_ui, raw_of(g_cfg.tail));
        if (g_tail_down_ms)
            logf_("笔尾松开（按住 %ldms）", now_ms() - g_tail_down_ms);
        g_tail_down_ms = 0;
    } else {
        logf_("未映射的 usage 0x%08x", scan);
    }
}

/* ---------------------------------------------------------------- main */
static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

/* ------------------------------------------------------------ --watch 模式 */
/*
 * penring --watch [--prefs DIR]... [--touch NODE]
 *
 * 给根侧 shell 用的**逐行、不缓冲**事件流：
 *     FILE <name>      prefs 被写（inotify：CLOSE_WRITE / MOVED_TO / CREATE）
 *     TAIL down|up     笔尾（橡皮端）进/出感应范围（BTN_TOOL_RUBBER）
 *
 * 为什么不用 getevent：它是 stdio 全缓冲，输出接管道时会攒到 4KB 才吐，
 * 切换手感就慢半拍；inotify 是内核直接通知，毫秒级。
 */
static void print_line(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

static int watch_mode(int argc, char **argv, int start)
{
    char dirs[8][512];
    int npref = 0;
    int ifd, i, tail_state = -1, touch_fd = -1;

    for (i = start; i < argc; i++) {
        if (!strcmp(argv[i], "--prefs") && i + 1 < argc && npref < 8)
            snprintf(dirs[npref++], sizeof(dirs[0]), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--touch") && i + 1 < argc)
            snprintf(g_touch_path, sizeof(g_touch_path), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--log") && i + 1 < argc)
            g_log = argv[++i];
    }
    if (npref == 0 && g_touch_path[0] == '\0') {
        fprintf(stderr, "watch: 需要 --prefs 或 --touch\n");
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    ifd = inotify_init1(IN_NONBLOCK);
    if (ifd < 0) { fprintf(stderr, "inotify_init1: %s\n", strerror(errno)); return 1; }
    for (i = 0; i < npref; i++) {
        int wd = inotify_add_watch(ifd, dirs[i],
                                   IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE);
        if (wd < 0) logf_("watch: inotify_add_watch(%s) 失败: %s", dirs[i], strerror(errno));
        else logf_("watch: 盯住 %s", dirs[i]);
    }
    if (g_touch_path[0] != '\0') {
        touch_fd = open(g_touch_path, O_RDONLY | O_NONBLOCK);
        logf_("watch: 触控节点 %s fd=%d", g_touch_path, touch_fd);
    }

    while (!g_stop) {
        struct pollfd pfd[2];
        int n = 0, wi = -1, ti = -1;

        if (ifd >= 0) { wi = n; pfd[n].fd = ifd; pfd[n].events = POLLIN; n++; }
        if (touch_fd >= 0) { ti = n; pfd[n].fd = touch_fd; pfd[n].events = POLLIN; n++; }
        if (n == 0) break;
        if (poll(pfd, n, 1000) <= 0) continue;

        if (wi >= 0 && (pfd[wi].revents & POLLIN)) {
            char buf[4096];
            ssize_t got = read(ifd, buf, sizeof(buf));
            ssize_t off = 0;
            while (got > 0 && off + (ssize_t)sizeof(struct inotify_event) <= got) {
                struct inotify_event *ev = (struct inotify_event *)(buf + off);
                if (ev->len > 0 && ev->name[0] != '.')
                    print_line("FILE %s", ev->name);
                off += sizeof(struct inotify_event) + ev->len;
            }
        }

        if (ti >= 0 && (pfd[ti].revents & (POLLIN | POLLERR | POLLHUP))) {
            struct input_event ev;
            while (read(touch_fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                int now;
                if (ev.type != EV_KEY || ev.code != BTN_TOOL_RUBBER) continue;
                now = ev.value ? 1 : 0;
                if (now != tail_state) {
                    tail_state = now;
                    print_line("TAIL %s", now ? "down" : "up");
                }
            }
        }
    }

    if (ifd >= 0) close(ifd);
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [--moddir DIR] [--config FILE] [--log FILE] [--dev /dev/input/eventN] [--once]\n"
            "       %s --watch [--prefs DIR]... [--touch NODE]\n"
            "  把联想 Tab Pen Pro 2 的捏/双击/上滑/下滑/笔尾桥成小米焦点触控笔的键。\n",
            argv0, argv0);
}

int main(int argc, char **argv)
{
    char cfgpath[512];
    char pidpath[512];
    const char *cfg_override = NULL;
    int once = 0;
    int i;

    for (i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--watch")) return watch_mode(argc, argv, i + 1);

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--moddir") && i + 1 < argc)       g_moddir = argv[++i];
        else if (!strcmp(argv[i], "--log") && i + 1 < argc)     g_log = argv[++i];
        else if (!strcmp(argv[i], "--config") && i + 1 < argc)  cfg_override = argv[++i];
        else if (!strcmp(argv[i], "--dev") && i + 1 < argc)     g_dev = argv[++i];
        else if (!strcmp(argv[i], "--once"))                    once = 1;
        else { usage(argv[0]); return 2; }
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGPIPE, SIG_IGN);

    if (g_log == NULL) {
        static char deflog[512];
        snprintf(deflog, sizeof(deflog), "%s/penring.log", g_moddir);
        g_log = deflog;
    }
    snprintf(cfgpath, sizeof(cfgpath), "%s", cfg_override ? cfg_override : "");
    if (cfgpath[0] == '\0') snprintf(cfgpath, sizeof(cfgpath), "%s/config", g_moddir);

    /* 每次启动都截断日志：只留本次会话，避免无限增长 */
    {
        FILE *f = fopen(g_log, "w");
        if (f) fclose(f);
    }

    snprintf(pidpath, sizeof(pidpath), "%s/penring.pid", g_moddir);
    {
        FILE *f = fopen(pidpath, "w");
        if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
    }

    logf_("penring 启动 pid=%d moddir=%s", (int)getpid(), g_moddir);
    write_keylayout();
    load_config(cfgpath);

    while (!g_stop) {
        char path[64];
        int src;
        int scan = 0;
        struct pollfd pfd;

        src = find_pen(path, sizeof(path));
        if (src < 0) {
            if (g_ui >= 0) ui_destroy();
            sleep(2);
            continue;
        }
        if (g_ui < 0) {
            g_ui = ui_create();
            if (g_ui < 0) { close(src); sleep(3); continue; }
        }

        pfd.fd = src;
        pfd.events = POLLIN;
        while (!g_stop) {
            struct input_event ev;
            int r = poll(&pfd, 1, 2000);
            if (r < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (r == 0) continue;                                  /* 空闲 */
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) break;

            if (read(src, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) break;   /* 节点没了 */

            if (ev.type == EV_MSC && ev.code == MSC_SCAN) {
                scan = ev.value;
                continue;
            }
            if (ev.type == EV_KEY && ev.code == KEY_UNKNOWN && ev.value == 1)
                on_usage(scan);
            /* value == 0 是内核为同一个 usage 自动补的抬起，忽略：
             * 联想笔是用两个不同 usage 表示按下/松开的（0x619→0x620）。 */
        }

        close(src);
        ui_destroy();
        if (once) break;
        sleep(1);
    }

    ui_destroy();
    logf_("penring 退出");
    unlink(pidpath);
    return 0;
}
