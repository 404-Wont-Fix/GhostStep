#!/usr/bin/env python3
"""extract_traces.py — 从 detail=4 回放里抽出逐帧威胁轨迹（离线建模用）

用法: python tools/extract_traces.py <回放.jsonl> <输出目录>

产出:
  frames.csv  frame,room,px,py,vx,vy,enabled,reason   （玩家状态）
  haz.csv     frame,room,kind,id,x,y,vx,vy,r,damage   （每个威胁每帧一行）

用途:
  * 量敌人的跳跃节奏（Trite/Hopper 的跳跃间隔、滞空帧数、落点 vs 玩家位置）
  * 量弹幕的曲线/环形行为（速度方向随时间的转角）
"""
import json
import os
import sys


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    fh = open(os.path.join(outdir, "haz.csv"), "w", encoding="utf-8", newline="")
    ff = open(os.path.join(outdir, "frames.csv"), "w", encoding="utf-8", newline="")
    fh.write("frame,room,kind,id,x,y,vx,vy,r,damage\n")
    ff.write("frame,room,px,py,vx,vy,reason\n")
    nframes = nhaz = 0
    with open(src, encoding="utf-8") as f:
        for line in f:
            if '"hazards":[' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("snapshot") is not None:
                o = o["snapshot"]          # ev=context 的嵌套快照
            if not isinstance(o.get("hazards"), list):
                continue
            frame, room = o.get("frame"), o.get("room")
            ff.write("%s,%s,%s,%s,%s,%s,%s\n" % (
                frame, room, o.get("px"), o.get("py"), o.get("vx"), o.get("vy"),
                o.get("reason")))
            nframes += 1
            for h in o.get("hazards") or []:
                fh.write("%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" % (
                    frame, room, h.get("kind"), h.get("id"),
                    h.get("x"), h.get("y"), h.get("vx"), h.get("vy"),
                    h.get("r"), h.get("damage")))
                nhaz += 1
    fh.close()
    ff.close()
    print("frames=%d hazards=%d -> %s" % (nframes, nhaz, outdir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
