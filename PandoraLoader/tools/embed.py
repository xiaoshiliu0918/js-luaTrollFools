#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 payload/prelude.js 嵌成 C 数组（payload/PdPrelude.h）。

为什么不用「运行时读文件」：attach 注入时 dylib 被单独拷进目标 App 的容器，
旁边没有 prelude.js。嵌进二进制最省事，代价是改 prelude 要重编译。

用法：  python3 tools/embed.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "payload", "prelude.js")
DST = os.path.join(ROOT, "payload", "PdPrelude.h")


def main() -> int:
    if not os.path.exists(SRC):
        print("找不到", SRC, file=sys.stderr)
        return 1

    data = open(SRC, "rb").read()
    lines = []
    lines.append("// 自动生成，不要手改 —— 改 payload/prelude.js 然后跑 python3 tools/embed.py")
    lines.append("// 源文件 %d 字节" % len(data))
    lines.append("#ifndef PD_PRELUDE_H")
    lines.append("#define PD_PRELUDE_H")
    lines.append("")
    lines.append("static const unsigned char g_pd_prelude_js[] = {")
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        lines.append("    " + ",".join("0x%02x" % b for b in chunk) + ",")
    lines.append("    0x00")
    lines.append("};")
    lines.append("")
    lines.append("#endif")
    lines.append("")

    open(DST, "w", encoding="utf-8").write("\n".join(lines))
    print("已生成 %s（%d 字节源）" % (DST, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
