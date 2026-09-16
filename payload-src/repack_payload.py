#!/usr/bin/env python3
"""把打好两处补丁的 classes.dex 塞回原厂 PowerKeeper APK —— **原地等长替换，不重建 zip**。

流程（build.sh --payload 自动串起来）：

    payload-src/PowerKeeper-stock.apk            <- 移植包原厂 APK（补丁输入，不入库）
        |  patch_powerkeeper.py                 字节补丁：LocalUpdateUtils.startCloudSyncData
        v                                         return v0(0x0f) -> return-void(0x0e)
    classes-patched.dex
        |  fix_static.py                        结构性补丁：DisplayFrameSetting.isFeatureOn
        v                                         从 virtual_methods 移入 direct_methods、
    classes-patched2.dex                          补 ACC_STATIC、code_item.ins_size 1 -> 0
        |  repack_payload.py（本脚本）            原地替换 classes.dex 内容 + 回填 CRC-32
        v
    module/payload/app/PowerKeeper.apk

**为什么是"原地替换"而不是"重新打包"**
--------------------------------------
早期版本用 `zipfile` 重建 APK，产物看着没问题，但**丢掉了 APK Signing Block**
（v2/v3 签名块在「最后一个 local entry」与「central directory」之间，`zipfile` 不认这块）。
Android 11+ 对 `targetSdk >= 30` 强制要求 v2 签名，于是 PMS 直接拒绝：

    W PackageManager: Failed to scan /system_ext/app/PowerKeeper:
        No APK Signature Scheme v2 signature in package .../PowerKeeper.apk

`com.miui.powerkeeper` 根本不会进已安装列表，而模块日志照样写"补丁已挂载" ——
**看起来一切正常，功能却是死的**（这个坑在设备上蹲了很久才被抓到）。

两处补丁本来都是**等长**的，所以正确做法是只覆盖那一段字节：所有 offset 不变、
central directory 与 EOCD 原样保留、**签名块原样保留**。

用法
----
    repack_payload.py [原厂.apk] [补丁后的.dex] [输出.apk]

校验
----
产出后本脚本会自己断言：
  * 长度与原厂**完全一致**；
  * **签名块仍在**；
  * 与原厂的差异只落在 classes.dex 数据段 + 两处 CRC-32 字段（不多改一个字节）。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apk_inplace as A  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def main(argv) -> int:
    stock = Path(argv[0]) if len(argv) > 0 else HERE / "PowerKeeper-stock.apk"
    new_dex_p = Path(argv[1]) if len(argv) > 1 else HERE / "classes-patched2.dex"
    out_apk = Path(argv[2]) if len(argv) > 2 else REPO / "module" / "payload" / "app" / "PowerKeeper.apk"

    if not stock.is_file():
        raise SystemExit(f"missing {stock}（原厂 APK 不入库，需自行从移植包提取）")
    if not new_dex_p.is_file():
        raise SystemExit(f"missing {new_dex_p}（先跑 patch_powerkeeper.py 与 fix_static.py）")

    src = stock.read_bytes()
    dex = new_dex_p.read_bytes()

    if not A.has_signing_block(src):
        raise SystemExit(
            f"{stock} 里没有 APK Signing Block —— 这不是一份带 v2 签名的原厂 APK，"
            f"拿它当补丁输入产出的一定是装不上的包"
        )
    blk = A.signing_block_size(src)

    entry = A.find_entry(src, "classes.dex")
    dex_off = A.data_offset(src, entry)

    patched = A.replace_entry(src, "classes.dex", dex)

    # ---- 自证：容器里除了 classes.dex 的数据与它两处 CRC，别的字节一个都没动 ----
    # 这正是"原地补丁"要保证的东西：所有 offset 不变 → central directory 里的
    # `local header offset` 仍然成立 → 签名块位置不变 → PMS 还能找到签名块。
    if len(patched) != len(src):
        raise SystemExit("长度变了 —— 等长被破坏")
    if not A.has_signing_block(patched):
        raise SystemExit("签名块丢了 —— 产物会被 PMS 拒绝")

    allowed = [
        (dex_off, len(dex)),              # classes.dex 的数据段
        (entry["lfh_off"] + 14, 4),       # local file header 的 CRC-32
        (entry["cd_off"] + 16, 4),        # central directory 的 CRC-32
    ]
    rng = A.diff_ranges(src, patched)
    stray = [(o, n) for o, n in rng
             if not any(o >= s and o + n <= s + ln for s, ln in allowed)]
    if stray:
        raise SystemExit(
            f"改动溢出到 classes.dex 数据段之外（{len(stray)} 段），"
            f"说明容器结构被动过：{[(hex(o), n) for o, n in stray[:5]]}"
        )

    out_apk.write_bytes(patched)

    inside_dex = sum(1 for o, _ in rng if dex_off <= o < dex_off + len(dex))
    print(f"wrote {out_apk} ({len(patched)} bytes)")
    print(f"  classes.dex  {len(dex)} bytes（原厂 {entry['usize']} bytes，等长 ✓）")
    print(f"  签名块      {blk} bytes 保留 ✓")
    print(f"  改动        {len(rng)} 段 / {sum(n for _, n in rng)} 字节，"
          f"其中 {inside_dex} 段在 dex 内、{len(rng) - inside_dex} 段是 CRC-32")
    print(f"  容器其余部分逐字节未动 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
