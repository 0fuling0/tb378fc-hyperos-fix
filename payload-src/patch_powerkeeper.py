#!/usr/bin/env python3
"""Repair the one malformed byte in PowerKeeper.apk's LocalUpdateUtils.startCloudSyncData.

The ported ROM neutered MIUI's cloud sync by making this method return immediately,
but the smali was written as `return v0` (opcode 0x0f) inside a `(Landroid/content/Context;Z)V`
method instead of `return-void` (opcode 0x0e).  The verifier refuses the whole class, so
com.miui.powerkeeper dies on every boot (VerifyError) and MIUI power management is dead.

Fix: flip opcode 0x0f -> 0x0e at the instruction, then recompute the dex header's
adler32 checksum and SHA-1 signature (the dex spec covers bytes [12:] and [32:]).

This step only produces `classes-patched.dex`.  The dex is spliced back into the original
APK **in place** by repack_payload.py — do NOT rebuild the zip here: rewriting the archive
with `zipfile` drops the APK Signing Block, and Android 11+ then refuses to scan the package
("No APK Signature Scheme v2 signature in package").  See apk_inplace.py for the full story.
"""
import hashlib
import struct
import sys
import zipfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC_APK = HERE / "PowerKeeper.apk"
PATCHED_DEX = HERE / "classes-patched.dex"
# file offset of the `return v0` instruction (0x0f 0x00), from `dexdump -d`
PATCH_OFFSET = 0x172ECA
OLD = 0x0F
NEW = 0x0E


def main() -> None:
    with zipfile.ZipFile(SRC_APK) as z:
        info = z.getinfo("classes.dex")
        dex = bytearray(z.read("classes.dex"))

    if dex[:8] != b"dex\n039\0":
        raise SystemExit(f"unexpected dex magic {dex[:8]!r}")
    got = dex[PATCH_OFFSET]
    if got != OLD:
        raise SystemExit(f"expected 0x{OLD:02x} at 0x{PATCH_OFFSET:x}, found 0x{got:02x}")
    if dex[PATCH_OFFSET + 1] != 0x00:
        raise SystemExit("unexpected operand byte")

    dex[PATCH_OFFSET] = NEW

    # header: checksum over [12:], signature over [32:]
    dex[12:32] = hashlib.sha1(bytes(dex[32:])).digest()
    dex[8:12] = struct.pack("<I", zlib.adler32(bytes(dex[12:])) & 0xFFFFFFFF)
    if len(dex) != info.file_size:
        raise SystemExit(f"dex 长度变了：{len(dex)} != {info.file_size} —— 补丁本应等长")
    PATCHED_DEX.write_bytes(dex)
    print(f"dex patched: 0x{OLD:02x} -> 0x{NEW:02x} at 0x{PATCH_OFFSET:x}, "
          f"size unchanged={len(dex) == info.file_size}")
    print(f"wrote {PATCHED_DEX}")


if __name__ == "__main__":
    sys.exit(main())
