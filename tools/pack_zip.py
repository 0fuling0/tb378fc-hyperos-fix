#!/usr/bin/env python3
"""打包模块 zip —— build.sh 在**没有 `zip` 命令**时的等价兜底（Windows / git-bash 常见）。

为什么要单独有这个脚本
----------------------
本仓库在 Windows 上 checkout 时是 CRLF（core.autocrlf=true，仓库里没有 .gitattributes），
而 Android 的 sh（mksh）**不能执行 CRLF 脚本** —— 会报
    "syntax error: unexpected 'newline'"  或  "xxx: inaccessible or not found"
装到设备上整个模块静默不工作，现象上极难定位。CI（ubuntu-latest）checkout 出来是 LF，
所以这个坑只在本地 Windows 打包时出现。

build.sh 的做法是在**暂存副本**上把文本文件的行尾统一成 LF 再 zip。本脚本把同一件事
放在内存里做：读进来 → 归一化 → 写出去，不落暂存目录。两条路径的产物内容必须一致
（tools/verify_pack.py 就是拿来比对这一点的）。

用法
----
    pack_zip.py <源目录> <输出.zip>

行为对齐 `zip -q -r -X` + build.sh 的排除表：
  * 目录名 __pycache__ / .monitor.lock 整棵跳过
  * 排除 .apk.sha、*.log、*.pid、*.pyc、brush.*、disable、disable-*
  * 文本文件（*.sh *.prop *.rule *.html *.xml 以及无扩展名的 `config`）行尾归一化为 LF
  * 权限位取自 **git index**（见 _git_modes 的注释 —— Windows 上 stat 读不出执行位）
  * 条目顺序按路径排序 —— 让同一份源码在 CI 和本地打出**逐字节相同**的 zip
    （zip 里没有全局时间戳，条目时间统一用 1980-01-01）
"""
import os
import subprocess
import sys
import zipfile
from pathlib import Path

# 整棵跳过的目录名
SKIP_DIRS = {"__pycache__", ".monitor.lock", ".git", "out"}

# 按文件名（basename）精确排除
SKIP_NAMES = {".apk.sha", "disable"}

# 按文件名通配排除
SKIP_GLOBS = ("*.log", "*.pid", "*.pyc", "disable-*", "brush.*", "wake.log*", "*.idsig")

# 需要把行尾归一化成 LF 的文件（按扩展名 + 无扩展名的 config）
LF_EXTS = {".sh", ".prop", ".rule", ".html", ".htm", ".xml", ".js", ".css", ".json"}
LF_BARE = {"config"}

# 固定时间戳，保证可复现（zip 的最小可表示时间）
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def _skip(name: str) -> bool:
    if name in SKIP_NAMES:
        return True
    for pat in SKIP_GLOBS:
        if Path(name).match(pat):
            return True
    return False


def _needs_lf(name: str) -> bool:
    p = Path(name)
    return p.suffix.lower() in LF_EXTS or p.name in LF_BARE


def _iter_files(src: Path):
    """按路径排序产出 (相对路径, 绝对路径)。排序是为了让产物可复现。"""
    out = []
    for root, dirs, files in os.walk(src):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for f in sorted(files):
            if _skip(f):
                continue
            full = Path(root) / f
            out.append((full.relative_to(src).as_posix(), full))
    out.sort(key=lambda t: t[0])
    return out


def _git_modes(src: Path) -> dict:
    """从 git index 读每个文件记录的模式（0o755 / 0o644）。

    为什么不能信 os.stat：本仓库主要在 Windows 上开发，NTFS 下 st_mode 一律是 0o666
    —— 读写位被映射到"只读"属性，根本没有 Unix 执行位；而 os.access(X_OK) 在 Windows 上
    对任何存在的文件都返回 True（MSYS 的 `ls -l` 显示 755 是它自己按扩展名猜的）。
    两者都读不出真实权限，**git index 才是权威**（core.filemode=false 只影响"检测变更"，
    index 里存的那份模式仍然是对的）。

    读不到 git（比如导出的 tarball）就返回空表，由调用方退回按扩展名猜。
    """
    try:
        r = subprocess.run(["git", "-C", str(src), "ls-files", "-s"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return {}
    if r.returncode != 0:
        return {}
    modes = {}
    for line in r.stdout.splitlines():
        meta, tab, path = line.partition("\t")
        parts = meta.split()
        if not tab or len(parts) < 3:
            continue
        try:
            modes[path] = int(parts[0], 8)
        except ValueError:
            continue
    return modes


def _mode_for(rel: str, git_modes: dict) -> int:
    m = git_modes.get(rel)
    if m in (0o755, 0o644):
        return m
    # 退回按扩展名猜：模块里只有 *.sh 需要可执行位
    return 0o755 if rel.endswith(".sh") else 0o644


def main(argv) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("用法: pack_zip.py <源目录> <输出.zip>", file=sys.stderr)
        return 2
    src = Path(argv[0]).resolve()
    out_zip = Path(argv[1]).resolve()
    if not src.is_dir():
        print(f"源目录不存在: {src}", file=sys.stderr)
        return 1

    out_zip.parent.mkdir(parents=True, exist_ok=True)
    if out_zip.exists():
        out_zip.unlink()

    git_modes = _git_modes(src)
    n_lf = 0
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for rel, full in _iter_files(src):
            data = full.read_bytes()
            if _needs_lf(rel) and b"\r\n" in data:
                data = data.replace(b"\r\n", b"\n")
                n_lf += 1
            info = zipfile.ZipInfo(rel, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3  # Unix，这样下面的权限位才会被解包器采用
            info.external_attr = (0o100000 | _mode_for(rel, git_modes)) << 16
            z.writestr(info, data)

    src_note = "git index" if git_modes else "按扩展名推断（读不到 git）"
    print(f"wrote {out_zip} ({out_zip.stat().st_size} bytes, 行尾归一化 {n_lf} 个文件, 权限位来自{src_note})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
