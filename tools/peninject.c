/*
 * peninject —— 自检/排障用：伪造一个"联想笔的手势节点"，往里面发 consumer usage，
 * 用来验证 penring → type-8 虚拟笔 → MIUI 这条链（不需要真的笔、不需要动手势）。
 *
 * 它建立一个 uinput 设备，名字故意叫 "Lenovo Tab Pen Pro 2 Consumer Control"
 * （penring 就是按这个名字找节点的），然后每读一行 stdin 就往里发一次：
 *
 *     0c0619   -> MSC_SCAN 0x0c0619 + KEY_UNKNOWN down/up（捏下）
 *     0c0601   -> 双击        0c0613 上滑   0c0612 下滑
 *     0c0623   -> 笔尾按住    0c0624 笔尾松开
 *
 * 用法（root）：
 *     peninject &                       # 会打印自己的 /dev/input/eventN
 *     penring --dev /dev/input/eventNN --once &   # 让它读我们造的节点
 *     echo 0c0619 | peninject ...       # 触发一次捏
 *
 * 编译：和 penring 同一套 NDK clang（见 docs/stylus-gesture-bridge.md）。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void emit(int fd, int type, int code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    if (write(fd, &ev, sizeof(ev)) < 0) perror("write");
}

int main(void)
{
    struct uinput_setup us;
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    char line[64];

    if (fd < 0) { perror("open /dev/uinput"); return 1; }

    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_MSC);
    ioctl(fd, UI_SET_MSCBIT, MSC_SCAN);
    ioctl(fd, UI_SET_KEYBIT, KEY_UNKNOWN);

    memset(&us, 0, sizeof(us));
    us.id.bustype = BUS_BLUETOOTH;
    us.id.vendor = 0x17ef;
    us.id.product = 0x622e;
    us.id.version = 0x0001;
    snprintf(us.name, UINPUT_MAX_NAME_SIZE, "Lenovo Tab Pen Pro 2 Consumer Control");

    if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_SETUP/CREATE");
        return 1;
    }
    fprintf(stderr, "peninject: 已建立假手势节点，找它对应的 /dev/input/eventN：\n");
    fflush(stderr);
    system("grep -l 'Lenovo Tab Pen Pro 2 Consumer Control' /sys/class/input/event*/device/name 2>/dev/null | head -3");

    while (fgets(line, sizeof(line), stdin)) {
        unsigned long scan = strtoul(line, NULL, 16);
        if (scan == 0) continue;
        /* 联想笔的节奏：EV_MSC/MSC_SCAN → KEY_UNKNOWN down → SYN → up → SYN */
        emit(fd, EV_MSC, MSC_SCAN, (int)scan);
        emit(fd, EV_KEY, KEY_UNKNOWN, 1);
        emit(fd, EV_SYN, SYN_REPORT, 0);
        usleep(20000);
        emit(fd, EV_KEY, KEY_UNKNOWN, 0);
        emit(fd, EV_SYN, SYN_REPORT, 0);
        fprintf(stderr, "peninject: 已发 usage 0x%08lx\n", scan);
        fflush(stderr);
    }

    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
