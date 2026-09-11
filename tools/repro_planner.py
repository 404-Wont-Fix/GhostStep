#!/usr/bin/env python3
"""用真实 Lua 规划器复现回放里的具体场景（离线验证，不改任何 mod 文件）。

原理: 用 lupa 加载 tests/smoke.lua 的 Isaac API mock，再把回放 JSONL 里记录的
真实房间网格（terrain 事件）和威胁参数喂给 decision/predictive.lua，
直接调用改后的代码看它选什么方向。比“人肉推理”可靠：跑的就是游戏里那份 Lua。

依赖: pip install lupa（需要 tests/smoke.lua 存在）
用法: python tools/repro_planner.py

覆盖场景:
  A 房间 83 咒术房地刺环 + 帧18610 真实炸弹（旧行为: 17/18 候选被地形一票否决 → (0,0) 冻住）
  B 同房间无炸弹（地刺避让是否可见）
  D 沿墙直行会踩刺但斜向可绕开（应产生可见修正）
  C 房间 84 门洞（旧行为: 初始硬穿透 18px、规划器完全瞎掉）
  E 恒定石像射手（Type 202）预测走廊几何（半宽/长度）
"""
import json
import os
import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]
REC = Path(r"D:/SteamLibrary/steamapps/common/The Binding of Isaac Rebirth/mods/GhostStep3/recordings")
SESSION = REC / "session_20260911_170035_3231274721_26526593_28.jsonl"


def terrain_for(room_index, max_tick=10**9):
    best = None
    for line in SESSION.open(encoding="utf-8", errors="replace"):
        if '"terrain"' not in line:
            continue
        r = json.loads(line)
        if r.get("ev") != "terrain" or r.get("room") != room_index:
            continue
        if (r.get("tick") or 0) <= max_tick:
            if best is None or (r.get("tick") or 0) >= (best.get("tick") or 0):
                best = r
    return best


def cols(ev):
    w = ",".join("1" if c[0] == 1 else "0" for c in ev["cells"])
    s = ",".join("1" if (len(c) > 1 and c[1] == "spike") else "0" for c in ev["cells"])
    c = ",".join(str(c[2]) for c in ev["cells"])
    return w, c, s


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().mod_root = str(ROOT)
    lua.execute('package.path = mod_root .. "/?.lua;" .. package.path')
    lua.execute((ROOT / "tests" / "smoke.lua").read_text(encoding="utf-8"))

    ring = terrain_for(83, 20000)
    door = terrain_for(84, 15360)
    assert ring and door, "缺少回放地形"
    print(f"房间83 rev={ring['revision']} tick={ring.get('tick')} "
          f"地刺格={sum(1 for c in ring['cells'] if len(c) > 1 and c[1] == 'spike')}")
    print(f"房间84 rev={door['revision']} tick={door.get('tick')} "
          f"collision=5 格={sum(1 for c in door['cells'] if c[2] == 5)}")

    w, c, s = cols(ring)
    dw, dc, ds = cols(door)
    lua.globals().REPRO_W, lua.globals().REPRO_C, lua.globals().REPRO_S = w, c, s
    lua.globals().REPRO_DW, lua.globals().REPRO_DC, lua.globals().REPRO_DS = dw, dc, ds
    lua.execute((ROOT / "analysis" / "repro_ring.lua").read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
