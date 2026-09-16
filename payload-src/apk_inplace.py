#!/usr/bin/env python3
"""在原厂 APK 上做**等长原地补丁** —— 保住 APK Signing Block（v2/v3 签名块）。

为什么不能用 `zipfile` 重建 APK（这是本仓库踩过的最贵的一个坑）
----------------------------------------------------------------
用 Python 的 `zipfile.ZipFile(out, "w")` 重写一遍 APK，产物看起来完全正常 ——
条目齐、CRC 对、能被 `unzip` 解开、dex 也是对的。但它**丢掉了 APK Signing Block**：
签名块位于「最后一个 local entry 结束」与「central directory 开始」之间，
而 `zipfile` 只会写出「条目 + central directory + EOCD」，那块东西它根本不认识。

后果在 Android 11+ 上是**硬失败**（`targetSdk >= 30` 时 v2 签名是强制的）：

    W PackageManager: Failed to scan /system_ext/app/PowerKeeper:
        No APK Signature Scheme v2 signature in package .../PowerKeeper.apk

于是包根本不会被 PMS 接受、`com.miui.powerkeeper` 压根不在已安装列表里，
而模块自己的日志只会写"② PowerKeeper 补丁已挂载"—— **看起来一切正常，功能却是死的**。

正确做法：既然补丁本身是**等长**的（`return v0`→`return-void` 改一个字节；
静态方法搬列表是等长重编码），那就不该重建容器，只该**覆盖那一段字节**：

  * 所有 offset 不变（central directory 的 `local header offset` 全部仍然成立）
  * central directory / EOCD 原样保留
  * **APK Signing Block 原样保留** ← 关键
  * 只需回填 `classes.dex` 的 CRC-32（local header +14、central directory +16 两处）

注：dex 内容变了，v2 签名的 digest 自然对不上。本机能跑通是因为移植包是 user 构建
却标了 `ro.debuggable=1`，PMS 在 debuggable 构建上跳过校验 —— 但**前提是签名块得在**，
签名块缺失会在"找签名"这一步就失败，根本走不到 debuggable 那条路。
"""
import struct
import zlib
from pathlib import Path

EOCD_SIG = b"PK\x05\x06"
CD_SIG = b"PK\x01\x02"
LFH_SIG = b"PK\x03\x04"
SIG_BLOCK_MAGIC = b"APK Sig Block 42"

ZIP_STORED = 0


def _u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def _u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def find_eocd(data: bytes) -> int:
    """返回 EOCD 的偏移。从尾部往前找（注释最多 65535 字节）。"""
    start = max(0, len(data) - 65557)
    i = data.rfind(EOCD_SIG, start)
    if i < 0:
        raise ValueError("不是 zip：找不到 EOCD")
    return i


def cd_range(data: bytes):
    """返回 (central directory 起始, 长度)。"""
    i = find_eocd(data)
    return _u32(data, i + 16), _u32(data, i + 12)


def has_signing_block(data: bytes) -> bool:
    """签名块紧邻 central directory 之前，最后 16 字节是 magic。"""
    cd_off, _ = cd_range(data)
    return cd_off >= 16 and data[cd_off - 16:cd_off] == SIG_BLOCK_MAGIC


def signing_block_size(data: bytes) -> int:
    """签名块总字节数；没有就返回 0。"""
    if not has_signing_block(data):
        return 0
    cd_off, _ = cd_range(data)
    # 块开头 8 字节 = 块长度（不含这 8 字节），末尾 8 字节 = 同样的长度 + magic
    size_field = _u64(data, cd_off - 24)
    return size_field + 8


def _u64(d, o):
    return struct.unpack_from("<Q", d, o)[0]


def entries(data: bytes):
    """从 central directory 解析条目，返回 [{name, method, crc, csize, usize, lfh_off, cd_off}]。"""
    cd_off, cd_size = cd_range(data)
    out = []
    p = cd_off
    end = cd_off + cd_size
    while p < end and data[p:p + 4] == CD_SIG:
        name_len = _u16(data, p + 28)
        extra_len = _u16(data, p + 30)
        comment_len = _u16(data, p + 32)
        out.append({
            "name": data[p + 46:p + 46 + name_len].decode("utf-8", "replace"),
            "method": _u16(data, p + 10),
            "crc": _u32(data, p + 16),
            "csize": _u32(data, p + 20),
            "usize": _u32(data, p + 24),
            "lfh_off": _u32(data, p + 42),
            "cd_off": p,
        })
        p += 46 + name_len + extra_len + comment_len
    return out


def find_entry(data: bytes, name: str) -> dict:
    for e in entries(data):
        if e["name"] == name:
            return e
    raise KeyError(f"APK 里没有 {name}")


def data_offset(data: bytes, e: dict) -> int:
    """条目数据的起始偏移（= local header 起点 + 30 + 文件名 + extra）。"""
    o = e["lfh_off"]
    if data[o:o + 4] != LFH_SIG:
        raise ValueError(f"local file header 签名不对 @0x{o:x}")
    name_len = _u16(data, o + 26)
    extra_len = _u16(data, o + 28)
    return o + 30 + name_len + extra_len


def replace_entry(data: bytes, name: str, new_bytes: bytes) -> bytes:
    """把条目内容替换成 new_bytes（**必须等长**），并回填两处 CRC-32。

    等长是硬要求：不等长会让后面所有 offset 失效、签名块位置也失效。
    """
    buf = bytearray(data)
    e = find_entry(buf, name)
    off = data_offset(buf, e)

    if e["method"] != ZIP_STORED:
        raise ValueError(f"{name} 是压缩存储的（method={e['method']}），无法原地等长替换")
    if e["csize"] != e["usize"]:
        raise ValueError(f"{name} 压缩/未压缩长度不一致（{e['csize']} vs {e['usize']}）")
    if len(new_bytes) != e["usize"]:
        raise ValueError(
            f"{name} 长度变了：{len(new_bytes)} != {e['usize']}。"
            f"补丁本应等长 —— 不等长就说明偏移全乱了，拒绝产出坏包"
        )

    buf[off:off + len(new_bytes)] = new_bytes

    crc = zlib.crc32(new_bytes) & 0xFFFFFFFF
    # local file header 的 CRC 在 +14，central directory 的 CRC 在 +16
    struct.pack_into("<I", buf, e["lfh_off"] + 14, crc)
    struct.pack_into("<I", buf, e["cd_off"] + 16, crc)
    return bytes(buf)


def diff_ranges(a: bytes, b: bytes):
    """返回两份等长字节串里不同的 (起始, 长度) 列表 —— 用来证明"只改了该改的地方"。"""
    if len(a) != len(b):
        raise ValueError(f"长度不同：{len(a)} vs {len(b)}")
    out = []
    start = None
    for i in range(len(a)):
        if a[i] != b[i]:
            if start is None:
                start = i
        elif start is not None:
            out.append((start, i - start))
            start = None
    if start is not None:
        out.append((start, len(a) - start))
    return out


def self_test():
    """跑一遍解析器自检 —— build.sh --payload 会调用。"""
    import io
    import zipfile

    # 造一个带"假签名块"的 zip：stored 条目 + 签名块 + central dir + EOCD
    body = io.BytesIO()
    with zipfile.ZipFile(body, "w") as z:
        info = zipfile.ZipInfo("classes.dex", date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED
        z.writestr(info, b"dex\n039\0" + b"A" * 100)

    base = body.getvalue()
    cd_off, cd_size = cd_range(base)
    payload = b"FAKE-SIGNATURE-BLOCK"
    # size_field 计的是"这 8 字节之后"的全部内容 = payload + 尾部 size + magic
    size_field = len(payload) + 8 + 16
    block = (struct.pack("<Q", size_field) + payload
             + struct.pack("<Q", size_field) + SIG_BLOCK_MAGIC)
    assert len(block) == size_field + 8, "自检：构造的签名块自身不自洽"
    # 把签名块插到 central directory 之前，并修正 EOCD 的 cd_off
    out = bytearray(base[:cd_off] + block + base[cd_off:])
    i = find_eocd(out)
    struct.pack_into("<I", out, i + 16, cd_off + len(block))

    assert has_signing_block(out), "自检：签名块没被识别"
    assert signing_block_size(out) == len(block), "自检：签名块长度算错"

    new_dex = b"dex\n039\0" + b"B" * 100
    patched = replace_entry(bytes(out), "classes.dex", new_dex)
    assert len(patched) == len(out), "自检：等长被破坏"
    assert has_signing_block(patched), "自检：替换后签名块丢了"

    # 用 zipfile 再读一遍，确认容器结构仍然合法
    with zipfile.ZipFile(io.BytesIO(patched)) as z:
        assert z.read("classes.dex") == new_dex, "自检：读回来的内容不对"
        assert z.testzip() is None, "自检：CRC 校验失败"

    rng = diff_ranges(bytes(out), patched)
    # 期望：只改 dex 数据段 + 两处 CRC
    assert len(rng) <= 3, f"自检：改动范围过多 {rng}"
    print(f"apk_inplace 自检通过（签名块 {len(block)} 字节保留，改动 {len(rng)} 段）")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(self_test())
