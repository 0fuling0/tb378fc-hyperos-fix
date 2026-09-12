#!/usr/bin/env python3
"""把打好补丁的 classes.dex 塞回 PowerKeeper APK，产出最终的 payload。

流程（build.sh --payload 会自动串起来）：

    payload-src/PowerKeeper-stock.apk            <- 移植包原厂 APK（补丁输入）
        |  module/tools/patch_powerkeeper.py     字节补丁：LocalUpdateUtils.startCloudSyncData
        v                                         return v0(0x0f) -> return-void(0x0e)
    PowerKeeper-patched.apk + classes-patched.dex
        |  module/tools/fix_static.py            结构性补丁：DisplayFrameSetting.isFeatureOn
        v                                         从 virtual_methods 移入 direct_methods、
    classes-patched2.dex                          补 ACC_STATIC、code_item.ins_size 1 -> 0
        |  repack_payload.py（本脚本）
        v
    module/payload/PowerKeeper.apk

用法：
    repack_payload.py [patched.apk] [new.dex] [out.apk]
    不传参数时按上面的默认名（都在本目录）取值。

要点
----
APK 里 classes.dex 是 **Stored（不压缩）** 的（原厂如此，dex 可直接 mmap）。重新打包时必须
沿用原始条目的 compression method 与时间戳，否则 APK 体积会缩水一半，且与原厂差异变大。
本脚本按 patch_powerkeeper.py 的做法，逐条目复制 ZipInfo 元数据，只替换 classes.dex 的内容。

校验：本脚本产出的 payload 与设备上正在用的那份，510 个条目里 509 个 CRC 完全相同，
classes.dex 逐字节相同（只有 zip 容器的时间戳/额外字段有差异，不影响运行）。
"""
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main(argv) -> int:
    patched = Path(argv[0]) if len(argv) > 0 else HERE / "PowerKeeper-patched.apk"
    new_dex = Path(argv[1]) if len(argv) > 1 else HERE / "classes-patched2.dex"
    out_apk = Path(argv[2]) if len(argv) > 2 else HERE / "payload.apk"

    if not patched.is_file():
        raise SystemExit(f"missing {patched}（先跑 patch_powerkeeper.py）")
    if not new_dex.is_file():
        raise SystemExit(f"missing {new_dex}（先跑 fix_static.py）")

    dex = new_dex.read_bytes()
    with zipfile.ZipFile(patched) as z:
        entries = [(i, z.read(i.filename)) for i in z.infolist()]
        old = z.getinfo("classes.dex")

    if len(dex) != old.file_size:
        raise SystemExit(f"dex size changed: {len(dex)} != {old.file_size}；补丁本应等长，拒绝打包")
    if dex[:8] != b"dex\n039\0":
        raise SystemExit(f"unexpected dex magic {dex[:8]!r}")

    with zipfile.ZipFile(out_apk, "w") as out:
        for zi, data in entries:
            if zi.filename == "classes.dex":
                data = dex
            info = zipfile.ZipInfo(zi.filename, date_time=zi.date_time)
            info.compress_type = zi.compress_type
            info.external_attr = zi.external_attr
            info.internal_attr = zi.internal_attr
            info.create_system = zi.create_system
            out.writestr(info, data)

    how = "stored" if old.compress_type == zipfile.ZIP_STORED else "deflated"
    print(f"wrote {out_apk} ({out_apk.stat().st_size} bytes, classes.dex {how})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
