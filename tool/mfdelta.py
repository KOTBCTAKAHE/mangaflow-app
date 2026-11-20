"""MFDELTA1: bsdiff control/diff/extra blocks, each zlib-compressed (Android inflates them natively).

Layout (little-endian): b"MFDELTA1", new_size:i64, n_ctrl:i64, len_ctrl:i64, len_diff:i64, len_extra:i64,
then zlib(ctrl: n_ctrl × (x, y, z) in bsdiff's sign-magnitude int64), zlib(diff), zlib(extra).
"""
import struct
import sys
import zlib

import bsdiff4.core as core

MAGIC = b"MFDELTA1"


def diff(old: bytes, new: bytes) -> bytes:
    ctrl, bdiff, bextra = core.diff(old, new)
    c = zlib.compress(ctrl, 9)
    d = zlib.compress(bdiff, 9)
    e = zlib.compress(bextra, 9)
    return MAGIC + struct.pack("<qqqqq", len(new), len(ctrl) // 24, len(c), len(d), len(e)) + c + d + e


def patch(old: bytes, p: bytes) -> bytes:
    assert p[:8] == MAGIC
    new_size, n, lc, ld, le = struct.unpack("<qqqqq", p[8:48])
    o = 48
    ctrl = zlib.decompress(p[o:o + lc]); o += lc
    d = zlib.decompress(p[o:o + ld]); o += ld
    e = zlib.decompress(p[o:o + le])
    out = bytearray(new_size)
    op = np_ = dp = ep = 0
    for i in range(n):
        x, y, z = (core.decode_int64(ctrl[i * 24 + j:i * 24 + j + 8]) for j in (0, 8, 16))
        for k in range(x):
            ov = old[op + k] if 0 <= op + k < len(old) else 0
            out[np_ + k] = (d[dp + k] + ov) & 0xFF
        np_ += x; op += x; dp += x
        out[np_:np_ + y] = e[ep:ep + y]
        np_ += y; ep += y; op += z
    return bytes(out)


if __name__ == "__main__":
    old, new, out = sys.argv[1:4]
    open(out, "wb").write(diff(open(old, "rb").read(), open(new, "rb").read()))
