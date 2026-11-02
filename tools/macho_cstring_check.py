#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Mach-O 二进制内容核验工具（legado-ios 构建产物自检用）。

重要结论（2026-11-02 实测）：
  - Swift release 构建对【中文/非 ASCII 字面量字符串】采用混合存储：
      短串走 small-string 内联（不在二进制里连成连续字节）、部分走 UTF-16、
      拼接/长串才落 __TEXT,__cstring(UTF-8)。因此「按字节找中文字面量」是
      **不可靠**的存活判据——全 app 必备的「取消」按钮文案都可能扫不到。
  - 可靠的存活判据是【ASCII 标识符】：Swift 类型元数据里保留完整类型名
      （如 SubscriptionSourceListView、BookSourceStore），以及持久化文件名
      等 ASCII 常量。这些在二进制里稳定可查，缺失=真没编入。本工具以「整包
      二进制子串扫描」实现，避开易出错的 Mach-O 段解析。

用法:
    python3 macho_cstring_check.py <binary|ipa|app-dir> [--cjk] [tokens...]

  --cjk   附加按 UTF-8/UTF-16 子串扫中文字面量（仅供参考，可能漏报）
  无参时默认核验一组 legado-ios 特征类型名（ASCII，可靠）。
"""
import sys
import zipfile
import os
import tempfile
import shutil


def find_main_binary(target):
    if os.path.isdir(target):
        for root, dirs, _ in os.walk(target):
            for d in dirs:
                if d.endswith(".app"):
                    cand = os.path.join(root, d, d[:-4])
                    if os.path.exists(cand):
                        return cand
        raise SystemExit("no app binary found in dir")
    if target.endswith(".ipa"):
        tmp = tempfile.mkdtemp(prefix="ipa_")
        with zipfile.ZipFile(target) as z:
            names = z.namelist()
            main = None
            for n in names:
                if not n.startswith("Payload/") or "/Frameworks/" in n:
                    continue
                if n.endswith("/"):
                    continue
                parts = n.split("/")
                exe = parts[-1]
                if "." in exe:
                    continue
                appname = [p[:-4] for p in parts if p.endswith(".app")]
                if appname and exe == appname[0]:
                    main = n
                    break
            if main is None:
                raise SystemExit("no main binary inside ipa")
            with z.open(main) as src, open(os.path.join(tmp, "Legado"), "wb") as dst:
                shutil.copyfileobj(src, dst)
        return os.path.join(tmp, "Legado")
    return target


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    target = args[0]
    rest = args[1:]
    mode_cjk = "--cjk" in rest
    tokens = [a for a in rest if not a.startswith("--")]

    binpath = find_main_binary(target)
    with open(binpath, "rb") as f:
        data = f.read()
    print(f"binary : {binpath}")
    print(f"size   : {len(data)} bytes")
    print("=" * 52)

    # ---- 可靠：ASCII 标识符 / 类型名 ----
    default_types = tokens or [
        "SourceListView", "SourceExportSheet", "SubscriptionSourceListView",
        "ImportSubscriptionSourceView", "QRSubscriptionScanSheet",
        "SubscriptionExportSheet", "SubscriptionSourceStore", "BookSourceStore",
        "SubscriptionSource", "DocumentImporter", "rss_sources",
        "subscriptionStore",
    ]
    print("[ASCII 标识符 / 类型名 — 可靠判据]")
    allok = True
    for tok in default_types:
        present = tok.encode("ascii") in data
        allok = allok and present
        print(f"  [{'OK' if present else 'XX'}] {tok}")
    print("-" * 52)

    # ---- 参考：CJK 字面量（可能漏报，仅供参考）----
    if mode_cjk:
        cjk = ["从文件导入", "书源导入", "订阅源导入", "保存到本地", "订阅源",
               "扫描订阅源二维码", "取消", "好", "成功导入", "导入失败"]
        print("[CJK 字面量子串 — 仅供参考，release 下可能漏报]")
        for lit in cjk:
            u8 = lit.encode("utf-8")
            u16 = lit.encode("utf-16-le")
            u16b = lit.encode("utf-16-be")
            if u8 in data:
                where = "utf-8"
            elif u16 in data:
                where = "utf-16le"
            elif u16b in data:
                where = "utf-16be"
            else:
                where = "MISSING(可能漏报)"
            print(f"  {lit!r:22} -> {where}")
        print("-" * 52)

    print("TYPE RESULT:", "ALL PRESENT" if allok else "SOME MISSING")
    sys.exit(0 if allok else 1)


if __name__ == "__main__":
    main()
