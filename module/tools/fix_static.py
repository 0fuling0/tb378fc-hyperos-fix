#!/usr/bin/env python3
"""Move DisplayFrameSetting.isFeatureOn into the dex's direct-method list and mark it static.

The ported ROM neutered `isFeatureOn()` to `return false`, but dropped its `static`
modifier.  All four call sites (including the original DisplayFrameSetting.init) use
invoke-static, so the verifier/linker rejects them with
IncompatibleClassChangeError: "expected to be of type static but ... found to be of type virtual".

The dex format keeps static/private/constructor methods in `class_data_item.direct_methods`
and everything else in `virtual_methods`, so flipping the ACC_STATIC bit alone is not
enough - the entry has to move lists.  This rewrites only that one class_data_item, and
only if the new encoding is the same length, so no offset in the file changes.
"""
import hashlib
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "classes-patched.dex"
DST = HERE / "classes-patched2.dex"

TARGET_CLASS = "Lcom/miui/powerkeeper/statemachine/DisplayFrameSetting;"
TARGET_METHOD = "isFeatureOn"
TARGET_PROTO = "()Z"
ACC_STATIC = 0x0008
ACC_PUBLIC = 0x0001


def uleb(data, off):
    """returns (value, next_off, raw_bytes)"""
    result = 0
    shift = 0
    start = off
    while True:
        b = data[off]
        off += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, off, data[start:off]


def enc_uleb(value):
    out = bytearray()
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_uleb_list(data, off, count, kind):
    """kind: 'field' -> (idx_diff, access); 'method' -> (idx_diff, access, code_off)"""
    items = []
    for _ in range(count):
        idx, off, raw_idx = uleb(data, off)
        acc, off, raw_acc = uleb(data, off)
        if kind == "method":
            code, off, raw_code = uleb(data, off)
            items.append([idx, acc, code, raw_idx + raw_acc + raw_code])
        else:
            items.append([idx, acc, raw_idx + raw_acc])
    return items, off


def rencode(items, kind):
    out = bytearray()
    for it in items:
        out += enc_uleb(it[0])
        out += enc_uleb(it[1])
        if kind == "method":
            out += enc_uleb(it[2])
    return bytes(out)


def main():
    dex = bytearray(SRC.read_bytes())
    if dex[:8] != b"dex\n039\0":
        raise SystemExit("unexpected dex magic")

    string_ids_size, string_ids_off = struct.unpack_from("<II", dex, 56)
    type_ids_size, type_ids_off = struct.unpack_from("<II", dex, 64)
    proto_ids_size, proto_ids_off = struct.unpack_from("<II", dex, 72)
    method_ids_size, method_ids_off = struct.unpack_from("<II", dex, 88)
    class_defs_size, class_defs_off = struct.unpack_from("<II", dex, 96)

    def string(idx):
        off = struct.unpack_from("<I", dex, string_ids_off + 4 * idx)[0]
        _, off, _ = uleb(dex, off)        # skip the utf16 length prefix
        end = dex.index(b"\0", off)
        return dex[off:end].decode()

    def type_name(idx):
        return string(struct.unpack_from("<I", dex, type_ids_off + 4 * idx)[0])

    # find method_ids triple for (class, name, proto)
    target_method_idx = None
    for i in range(method_ids_size):
        cls, proto, name = struct.unpack_from("<HHI", dex, method_ids_off + 8 * i)
        if string(name) != TARGET_METHOD:
            continue
        if type_name(cls) != TARGET_CLASS:
            continue
        # proto: shorty_idx, return_type_idx, parameters_off
        shorty, ret, params_off = struct.unpack_from("<III", dex, proto_ids_off + 12 * proto)
        if type_name(ret) == "Z" and params_off == 0:
            target_method_idx = i
            break
    if target_method_idx is None:
        raise SystemExit("target method not found")
    print(f"target method_idx = {target_method_idx} ({TARGET_CLASS}.{TARGET_METHOD}{TARGET_PROTO})")

    for ci in range(class_defs_size):
        base = class_defs_off + 32 * ci
        (cls_idx, access, super_idx, interfaces_off, source_idx,
         annotations_off, class_data_off, static_values_off) = struct.unpack_from("<IIIIIIII", dex, base)
        if type_name(cls_idx) != TARGET_CLASS:
            continue
        print(f"class_def #{ci} class_data_off=0x{class_data_off:x}")
        off = class_data_off
        sf, off, _ = uleb(dex, off)
        inf, off, _ = uleb(dex, off)
        dm, off, _ = uleb(dex, off)
        vm, off, _ = uleb(dex, off)
        print(f"  static_fields={sf} instance_fields={inf} direct_methods={dm} virtual_methods={vm}")

        static_fields, off = read_uleb_list(dex, off, sf, "field")
        instance_fields, off = read_uleb_list(dex, off, inf, "field")
        direct, off = read_uleb_list(dex, off, dm, "method")
        virtual, off = read_uleb_list(dex, off, vm, "method")
        old_end = off
        old_len = old_end - class_data_off

        # absolute index of each entry
        def abs_idx(items):
            out, cur = [], 0
            for it in items:
                cur += it[0]
                out.append(cur)
            return out

        d_abs, v_abs = abs_idx(direct), abs_idx(virtual)
        print(f"  direct idxs: {d_abs}")
        print(f"  virtual contains target: {target_method_idx in v_abs}")

        # collect true absolute indices, then rebuild both lists from scratch
        direct_items = [(ai, it[1], it[2]) for ai, it in zip(d_abs, direct)]
        virtual_items = [(ai, it[1], it[2]) for ai, it in zip(v_abs, virtual)]

        # pull the target out of the virtual list
        moved_item = None
        remaining = []
        for item in virtual_items:
            if item[0] == target_method_idx:
                moved_item = (item[0], item[1] | ACC_STATIC, item[2])
            else:
                remaining.append(item)
        if moved_item is None:
            raise SystemExit("target not in virtual_methods")
        virtual_items = remaining

        direct_items.append(moved_item)
        direct_items.sort(key=lambda x: x[0])
        virtual_items.sort(key=lambda x: x[0])

        def enc_method_list(items):
            out = bytearray()
            prev = 0
            for ai, acc, code in items:
                out += enc_uleb(ai - prev)
                out += enc_uleb(acc)
                out += enc_uleb(code)
                prev = ai
            return bytes(out)

        new = bytearray()
        new += enc_uleb(sf) + enc_uleb(inf) + enc_uleb(len(direct_items)) + enc_uleb(len(virtual_items))
        # field lists re-encode identically (unchanged)
        new += rencode(static_fields, "field")
        new += rencode(instance_fields, "field")
        new += enc_method_list(direct_items)
        new += enc_method_list(virtual_items)

        print(f"  old class_data len={old_len}  new len={len(new)}")
        if len(new) != old_len:
            raise SystemExit("REFUSING: encoding length changed; offsets would shift")
        dex[class_data_off:class_data_off + old_len] = new

        # a static method has no `this`, so its code_item ins_size must drop 1 -> 0
        code_off = moved_item[2]
        old_ins = struct.unpack_from("<H", dex, code_off + 2)[0]
        struct.pack_into("<H", dex, code_off + 2, 0)
        print(f"  code_item @0x{code_off:x}: ins_size {old_ins} -> 0")
        break
    else:
        raise SystemExit("class not found")

    dex[12:32] = hashlib.sha1(bytes(dex[32:])).digest()
    dex[8:12] = struct.pack("<I", zlib.adler32(bytes(dex[12:])) & 0xFFFFFFFF)
    DST.write_bytes(dex)
    print(f"wrote {DST}")


if __name__ == "__main__":
    sys.exit(main())
