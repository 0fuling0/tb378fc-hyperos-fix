#!/usr/bin/env python3
"""校验打出来的模块 zip —— build.sh --verify / CI 用。

为什么需要它
------------
装到设备上的模块有几类问题**在开发机上完全看不出来**，但现象上极难定位：

  1. **CRLF**：Windows 上 checkout 是 CRLF，Android 的 sh（mksh）不能执行 CRLF 脚本，
     整个模块静默不工作。所以包里的文本文件必须是纯 LF。
  2. **运行期产物混进包**：`disable`、`disable-*` 标记或上一台设备的 `*.log` 被一起打进去，
     用户装完一看"怎么是关着的"。
  3. **Full 分支的残留引用**：脚本里还写着 `bin/penring`、`TbFix.apk`、`action.sh` 这类
     Lite 已经删掉的东西 —— sh 只会打一行 not found 继续跑。
  4. **可执行位丢失**：KernelSU 的安装器没有 Magisk 的 set_perm（会静默失效），
     包里 `*.sh` 的权限位就是设备上最终的权限位。
  5. **版本错位**：zip 文件名、module.prop、payload 内容互相对不上。

用法
----
    verify_pack.py [zip]     不给参数就取 out/ 下最新（按 mtime）的那个 zip
退出码 0 = 全部通过；非 0 = 有问题（逐条打印）。
"""
import hashlib
import os
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
MODULE = REPO / "module"

# 模块里必须有的文件（少一个装到设备上就是静默不工作）
REQUIRED = [
    "module.prop",
    "config",
    "sepolicy.rule",
    "customize.sh",
    "post-fs-data.sh",
    "service.sh",
    "uninstall.sh",
    "payload/app/PowerKeeper.apk",
    "webroot/index.html",
]

# 需要保证纯 LF 的文件（按 basename / 后缀判断）
LF_EXTS = {".sh", ".prop", ".rule", ".html", ".htm", ".js", ".css", ".json"}
LF_BARE = {"config"}

# 运行期产物：绝不能进包
RUNTIME_RE = [
    re.compile(r"\.log$"),
    re.compile(r"\.pid$"),
    re.compile(r"\.pyc$"),
    re.compile(r"(^|/)__pycache__/"),
    re.compile(r"(^|/)disable$"),
    re.compile(r"(^|/)disable-"),
    re.compile(r"\.apk\.sha$"),
    re.compile(r"(^|/)wake\.log"),
    re.compile(r"(^|/)brush\."),
]

# Full 分支专属：Lite 里不该出现（不管是文件还是脚本里的引用）
# 注意锚定到 **zip 根**：`payload/app/...` 是 Lite 自己的目录结构，不是 Full 的 `app/`。
FULL_ONLY_FILES = re.compile(r"^(bin/|app/)|(^|/)(action|restart)\.sh$")
FULL_ONLY_TOKENS = [
    "bin/penring", "penring", "TbFix", "aonlib.sh", "action.sh", "restart.sh",
    "brushwatch", "stoprompen", "PenRing",
]
# 上面这些词允许出现在注释/文档里做对比说明，但不允许出现在**会被执行的语句**里。
# 判定方式：只看不含注释符的行（粗筛，足够拦住真问题）。
TOKEN_SCAN = ["service.sh", "post-fs-data.sh", "customize.sh", "uninstall.sh"]


def fail(msg: str) -> None:
    print(f"  ✗ {msg}")


def ok(msg: str) -> None:
    print(f"  ✓ {msg}")


def needs_lf(name: str) -> bool:
    return Path(name).suffix.lower() in LF_EXTS or Path(name).name in LF_BARE


def strip_comments(text: str) -> str:
    out = []
    for line in text.splitlines():
        s = line.lstrip()
        if s.startswith("#"):
            continue
        out.append(line)
    return "\n".join(out)


def main(argv) -> int:
    if argv:
        zpath = Path(argv[0])
    else:
        cands = sorted((REPO / "out").glob("*.zip"), key=lambda p: p.stat().st_mtime)
        if not cands:
            print("out/ 下没有 zip，先跑 ./build.sh", file=sys.stderr)
            return 1
        zpath = cands[-1]

    if not zpath.is_file():
        print(f"找不到 {zpath}", file=sys.stderr)
        return 1

    print(f"校验 {zpath}（{zpath.stat().st_size} bytes）")
    bad = 0
    z = zipfile.ZipFile(zpath)
    names = z.namelist()
    name_set = set(names)

    # --- 1. 必需文件 ---
    missing = [f for f in REQUIRED if f not in name_set]
    if missing:
        bad += 1
        fail(f"缺少必需文件: {', '.join(missing)}")
    else:
        ok(f"必需文件齐全（{len(REQUIRED)} 个）")

    # --- 2. 行尾 ---
    crlf = []
    for n in names:
        if needs_lf(n) and b"\r\n" in z.read(n):
            crlf.append(n)
    if crlf:
        bad += 1
        fail(f"这些文本文件里还有 CRLF（mksh 会执行失败）: {', '.join(crlf)}")
    else:
        ok("文本文件全部是纯 LF")

    # --- 3. 运行期产物 ---
    leaked = [n for n in names if any(r.search(n) for r in RUNTIME_RE)]
    if leaked:
        bad += 1
        fail(f"包里混进了运行期产物: {', '.join(leaked)}")
    else:
        ok("没有运行期产物混入（日志 / pid / disable 标记）")

    # --- 4. Full 分支残留 ---
    leftovers = [n for n in names if FULL_ONLY_FILES.search(n)]
    if leftovers:
        bad += 1
        fail(f"包里还有 Full 分支专属文件: {', '.join(leftovers)}")
    else:
        ok("没有 Full 分支专属文件（app/、bin/、action.sh、restart.sh）")

    hits = []
    for n in TOKEN_SCAN:
        if n not in name_set:
            continue
        code = strip_comments(z.read(n).decode("utf-8", "replace"))
        for t in FULL_ONLY_TOKENS:
            if t in code:
                hits.append(f"{n}: {t}")
    if hits:
        bad += 1
        fail("脚本正文里还引用着 Lite 已删掉的东西: " + "; ".join(hits))
    else:
        ok("脚本正文没有引用 Lite 已删掉的组件")

    # --- 5. 可执行位 ---
    # 注意括号：`not X & Y` 在 Python 里是 `(not X) & Y` —— 少一层括号就永远判不出问题。
    noexec = []
    for n in names:
        if not n.endswith(".sh"):
            continue
        info = z.getinfo(n)
        if not ((info.external_attr >> 16) & 0o111):
            noexec.append(n)
    if noexec:
        bad += 1
        fail(f"这些脚本在包里没有可执行位: {', '.join(noexec)}")
    else:
        ok("所有 *.sh 都带可执行位")

    # --- 6. 版本一致性 ---
    if "module.prop" in name_set:
        prop = z.read("module.prop").decode("utf-8", "replace")
        mid = re.search(r"^id=(.+)$", prop, re.M)
        mver = re.search(r"^version=(.+)$", prop, re.M)
        mid = mid.group(1).strip() if mid else ""
        mver = mver.group(1).strip() if mver else ""
        expect = f"{mid}-{mver}.zip"
        if zpath.name != expect:
            bad += 1
            fail(f"zip 文件名与 module.prop 不一致：{zpath.name} != {expect}")
        else:
            ok(f"版本一致（id={mid} version={mver}）")
        # versionCode 必须比 Full 分支的规则一致 —— 只要求是纯数字
        vc = re.search(r"^versionCode=(.+)$", prop, re.M)
        if not vc or not vc.group(1).strip().isdigit():
            bad += 1
            fail("module.prop 的 versionCode 缺失或不是纯数字")
        else:
            ok(f"versionCode={vc.group(1).strip()}")

    # --- 7. payload 与仓库里的那份逐字节一致 ---
    disk = MODULE / "payload" / "app" / "PowerKeeper.apk"
    if "payload/app/PowerKeeper.apk" in name_set and disk.is_file():
        a = hashlib.sha256(disk.read_bytes()).hexdigest()
        b = hashlib.sha256(z.read("payload/app/PowerKeeper.apk")).hexdigest()
        if a != b:
            bad += 1
            fail(f"包里的 payload 与 module/payload/ 下的不一致（{a[:12]} != {b[:12]}）")
        else:
            ok(f"payload 与仓库一致（sha256 {a[:16]}）")

    # --- 8. payload 必须带 APK Signing Block ---
    # 这是最贵的一个坑：用 `zipfile` 重建 APK 会丢掉 v2/v3 签名块，产物看着完全正常，
    # 但 Android 11+ 的 PMS 直接拒绝扫描（"No APK Signature Scheme v2 signature in package"）
    # —— 包不进已安装列表，而模块日志照样写"补丁已挂载"。看起来一切正常，功能是死的。
    if "payload/app/PowerKeeper.apk" in name_set:
        import struct
        apk = z.read("payload/app/PowerKeeper.apk")
        i = apk.rfind(b"PK\x05\x06")
        if i < 0:
            bad += 1
            fail("payload 不是合法 zip（找不到 EOCD）")
        else:
            cd_off = struct.unpack_from("<I", apk, i + 16)[0]
            if cd_off < 16 or apk[cd_off - 16:cd_off] != b"APK Sig Block 42":
                bad += 1
                fail("payload 丢了 APK Signing Block —— PMS 会拒绝扫描，② 是死的")
            else:
                size = struct.unpack_from("<Q", apk, cd_off - 24)[0] + 8
                ok(f"payload 带 APK Signing Block（{size} bytes）")

    print()
    if bad:
        print(f"✗ 校验失败：{bad} 项问题")
        return 1
    print("✓ 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
