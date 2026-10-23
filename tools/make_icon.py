#!/usr/bin/env python3
"""生成 Legado iOS App 图标（1024x1024，纯标准库，无第三方依赖）。

设计：legado 蓝底 + 三条白色圆角横条（书页/文本意象）。
用法：python3 tools/make_icon.py
"""
import os
import struct
import zlib

W = H = 1024
BG = (0x18, 0x5F, 0xA5)
FG = (0xFF, 0xFF, 0xFF)

# (center_x, center_y, width, height, corner_radius)
BARS = [
    (512, 402, 560, 76, 38),
    (512, 512, 430, 76, 38),
    (512, 622, 300, 76, 38),
]


def inside_any_bar(px: int, py: int) -> bool:
    for cx, cy, w, h, r in BARS:
        hw, hh = w / 2.0, h / 2.0
        if abs(px - cx) <= hw and abs(py - cy) <= hh:
            qx = max(abs(px - cx) - hw + r, 0.0)
            qy = max(abs(py - cy) - hh + r, 0.0)
            if qx * qx + qy * qy <= r * r:
                return True
    return False


def build_png() -> bytes:
    rows = []
    for y in range(H):
        row = bytearray(b"\x00")
        fg_row = inside_any_bar
        for x in range(W):
            row += bytes(FG if fg_row(x, y) else BG)
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    return png


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(
        here, "..", "Legado", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png"
    )
    png = build_png()
    with open(out, "wb") as handle:
        handle.write(png)
    print(f"wrote {os.path.abspath(out)} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
