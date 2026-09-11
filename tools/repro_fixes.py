#!/usr/bin/env python3
"""离线复现 2026-09-11 反馈的 4 个问题（飞行越障 / 火堆方形 / 躲避手感）。

用 lupa 加载 tests/smoke.lua 的 Isaac API mock，再跑真实的 sensors/terrain.lua 与
decision/predictive.lua，做闭环运动模拟（每帧重新决策 + 按 maxDodgeWeight 混合 + 运动模型积分），
比人肉推理可靠。不改任何 mod 文件。

用法: python tools/repro_fixes.py
"""
import sys
from pathlib import Path

from lupa import lua51, lua53

ROOT = Path(__file__).resolve().parents[1]


def main(version="5.1"):
    module = {"5.1": lua51, "5.3": lua53}[version]
    lua = module.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().mod_root = str(ROOT)
    lua.execute('package.path = mod_root .. "/?.lua;" .. package.path')
    lua.execute((ROOT / "tests" / "smoke.lua").read_text(encoding="utf-8"))
    print(f"==== Lua {version} ====", flush=True)
    lua.execute((ROOT / "tools" / "repro_fixes.lua").read_text(encoding="utf-8"))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "5.1")
