#!/usr/bin/env python3
"""静态检查 shell 脚本里"被调用但未定义"的内部函数。

背景：module/service.sh 曾被一次误操作整段删掉 brushwatch_ensure/brushwatch_alive，
而 sh 对未定义函数的反应只是打印一行 "xxx: not found" 继续跑 —— 看护进程静默不启动，
很难从现象上定位。这里在构建时把这类问题拦下来。

用法: tools/check-helpers.py module/service.sh [更多脚本...]
"""
import re
import sys

# 常见的 busybox/toybox 命令与 shell 关键字，不算内部函数
BUILTINS = set("""
if then else elif fi for while until do done case esac in return exit local export
set unset shift break continue echo printf read eval exec trap true false test : source
sh ash busybox toybox mksh env command type time let expr seq basename dirname
cat cp mv rm rmdir mkdir ln touch chmod chown stat readlink realpath ls find xargs
grep egrep fgrep sed awk cut tr sort uniq wc head tail tee od xxd hexdump cmp diff
kill killall pkill pgrep pidof ps id whoami date sleep usleep timeout nohup setsid
getprop setprop resetprop start stop dumpsys pm am cmd svc settings input wm screencap
service logcat getevent sendevent log df du free mount umount mountpoint sync
insmod rmmod lsmod modprobe dmesg sysctl getenforce setenforce restorecon chcon
applypatch reboot svc tar gzip unzip which mktemp flock truncate fallocate strings
sha256sum md5sum base64 uuidgen uptime watchprops nandread ionice nice renice
""".split())

# 安装器（KernelSU / Magisk）在 customize.sh 运行时**注入**的函数。
# 它们不在本仓库里定义，所以不能算"未定义"——否则 customize.sh 永远报一行假失败，
# 检查结果有噪音之后大家就不看了，真正的问题反而会被忽略。
INSTALLER_API = set("""
ui_print abort set_perm set_perm_recursive set_metadata set_metadata_recursive
mount_image umount_image is_mounted grep_prop get_top_volume
""".split())


def strip_quotes(line: str) -> str:
    """去掉单/双引号内容（含 heredoc 文本），避免日志里的词被当成命令。"""
    out, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c in "'\"":
            q = c
            i += 1
            while i < n and line[i] != q:
                i += 2 if line[i] == "\\" and q == '"' else 1
            i += 1
            out.append('""')
        else:
            out.append(c)
            i += 1
    return "".join(out)


def strip_arith(line: str) -> str:
    """去掉 $((...)) 算术表达式（里面是变量名，不是命令）。"""
    out, i, n = [], 0, len(line)
    while i < n:
        if line.startswith("$((", i):
            depth, i = 1, i + 3
            while i < n and depth:
                if line.startswith("((", i):
                    depth += 1
                    i += 2
                elif line.startswith("))", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            out.append("0")
        else:
            out.append(line[i])
            i += 1
    return "".join(out)


def strip_case(lines):
    """去掉 case 分支的模式行（yes|no|on) 之类不是命令）。"""
    out, in_case = [], False
    for line in lines:
        if in_case:
            if "esac" in line:
                in_case = False
                line = line.split("esac", 1)[1]
            else:
                continue
        if re.search(r"\bcase\b", line) and "esac" not in line:
            line, in_case = line.split("case", 1)[0], True
        elif re.search(r"\bcase\b.*\besac\b", line):
            line = re.sub(r"\bcase\b.*\besac\b", "", line)
        out.append(line)
    return out


def check(path: str) -> int:
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        # 路径写错时不要抛栈 —— 抛栈看起来像"检查器自己坏了"，
        # 容易被当成工具问题忽略掉，其实只是文件没找到。
        print(f"[check-helpers] {path}: 无法读取: {e}")
        return 1
    defined = set(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)", src, re.M))

    calls = set()
    for raw in strip_case(src.splitlines()):
        line = strip_arith(strip_quotes(raw)).split("#")[0]
        line = re.sub(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?", "X", line)
        # 把 "; then / ; do / ; else" 折成 "; "。
        # 为什么：扫名字的前缀分支里 [;&|(]\s* 会先吃掉分号后面的 then/do/else 本身，
        # 扫描位置随之跳过它们，于是 "if x; then foo; fi" 这种**单行**写法的 foo 永远扫不到
        # （多行写法因为 foo 独占一行、由 ^\s* 分支兜住，所以一直没暴露）。折一下就能扫到。
        line = re.sub(r";\s*(?:then|do|else)\b\s*", "; ", line)
        # 末尾的 (?!-) 很重要：紧跟着连字符的名字是"连字符 token"（disable-gesture 这类
        # 文件名/参数），不是函数调用。少了它，for 列表里用反斜杠续行写的一串
        # disable-xxx 会被逐行当成命令，误报 "调用了未定义的函数: disable"。
        for m in re.finditer(
            r"(?:^\s*|[;&|(]\s*|\bthen\s+|\bdo\s+|\belse\s+|\bif\s+|\bwhile\s+|!\s*)"
            r"([a-z][a-z0-9_]*)\b(?!\s*[=()])(?!-)",
            line,
        ):
            calls.add(m.group(1))

    missing = sorted(c for c in calls
                     if c not in defined and c not in BUILTINS and c not in INSTALLER_API)
    if missing:
        print(f"[check-helpers] {path}: 调用了未定义的函数: {' '.join(missing)}")
        return 1
    print(f"[check-helpers] {path}: ok (定义 {len(defined)} 个函数)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(max(check(p) for p in sys.argv[1:]))
