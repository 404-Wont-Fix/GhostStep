#!/usr/bin/env python3
"""analyze_hop.py — 核对“跳跃型敌人（跳蛛 Trite 等）预判”准不准

用法:
    python tools/extract_traces.py <回放.jsonl> <目录>      # 先抽轨迹（含 hop.csv）
    python tools/analyze_hop.py <目录>                      # 再核对

回答三个问题（这是“动画/节奏预判到底有没有用”的直接验收）:
  1. 动画前摇：库里给的 windupFrames（启发值 45%） vs 实机实测 hopWindup
  2. 落点精度：预测落点 (hopLX,hopLY) 与该次跳跃的“真实落点”差多少 px
  3. 起跳时刻：预测的起跳帧（frame + hopIn）与实际开始位移的帧差多少帧
另附：观测到的跳跃间隔/跳距，用来判断 hopPredict 的节拍是否被正确学到。
"""
import csv
import os
import sys
from collections import defaultdict


def load(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    d = sys.argv[1]
    hoppath = os.path.join(d, "hop.csv")
    if not os.path.exists(hoppath):
        print("没有 hop.csv —— 先用 tools/extract_traces.py <回放.jsonl> %s 抽一份" % d)
        return 1
    hop = load(hoppath)
    haz = load(os.path.join(d, "haz.csv")) if os.path.exists(os.path.join(d, "haz.csv")) else []
    if not hop:
        print("hop.csv 里没有跳跃预判记录：")
        print("  * 要么这局没有跳蛛/跳跳尸（hopTypes）")
        print("  * 要么用的是旧版本 mod（本轮改动前的回放不会有 hopOn 字段）")
        return 0

    # 敌人的逐帧位置/速度（用于找“真实起跳/落地”）
    trace = defaultdict(list)
    for h in haz:
        if h.get("kind") != "enemy":
            continue
        trace[(h["room"], h["id"])].append(
            (int(h["frame"]), num(h["x"]), num(h["y"]), num(h.get("vx") or 0), num(h.get("vy") or 0)))
    for k in trace:
        trace[k].sort()

    print("== 1) 动画前摇：库里启发值 vs 实测 ==")
    windups = defaultdict(list)
    for r in hop:
        w = num(r.get("hopWindup"))
        if w is not None:
            windups[(r.get("type"), r.get("variant"), r.get("hopAnim"))].append(w)
    if not windups:
        print("   （还没有测到前摇：需要“动画在播但还没位移”的那一段被观测到）")
    for k, vs in sorted(windups.items()):
        print("   type=%s variant=%s anim=%s 实测前摇=%.1f 帧（样本 %d）" % (k[0], k[1], k[2], sum(vs) / len(vs), len(vs)))

    print("\n== 2) 落点精度：预测落点 vs 真实落点 ==")
    # 每次预测（hopIn 最小、连续同 id 取一段）→ 在 hopIn+hopFlight 帧后看敌人实际位置
    # 每个“预测落点帧”只核一次：取每次预测中 hopIn 最小的那帧（最接近起跳的判断）
    best = {}
    for r in hop:
        f, room, hid = int(r["frame"]), r["room"], r["id"]
        inF, fl = num(r.get("hopIn")), num(r.get("hopFlight"))
        if inF is None or fl is None:
            continue
        land0 = f + round(inF) + round(fl)
        key = (room, hid, round(land0 / 10))     # 同一次跳跃的预测聚在一起
        if key not in best or inF < best[key][0]:
            best[key] = (inF, f, fl, num(r.get("hopLX")), num(r.get("hopLY")), hid, room)
    if not best:
        print("   （没有可核对的预测）")
    errs = []
    for key, (inF, f, fl, lx, ly, hid, room) in sorted(best.items()):
        land = f + inF + fl
        series = trace.get((room, hid))
        if not series:
            continue
        got = None
        for fr, x, y, vx, vy in series:
            if abs(fr - land) <= 1:
                got = (x, y)
                break
        if got is None or lx is None:
            continue
        e = ((got[0] - lx) ** 2 + (got[1] - ly) ** 2) ** 0.5
        errs.append(e)
        print("   %s f=%d 起跳+%d帧→滞空%df：预测(%.0f,%.0f) 实际(%.0f,%.0f) 误差 %.1fpx"
              % (hid, f, inF, fl, lx, ly, got[0], got[1], e))
    if errs:
        errs.sort()
        print("   落点误差中位 %.1fpx（样本 %d；<25px 内算“落在致命圈里”，会被规划器判命中）"
              % (errs[len(errs) // 2], len(errs)))

    print("\n== 3) 观测到的真实节奏（用来判断节拍学习是否靠谱） ==")
    for (room, hid), series in sorted(trace.items()):
        starts = []
        air = False
        for fr, x, y, vx, vy in series:
            v = (vx * vx + vy * vy) ** 0.5
            if v >= 3 and not air:
                air, starts.append(True, fr)
            elif v < 3 and air:
                air = False
        if len(starts) >= 2:
            gaps = [b - a for a, b in zip(starts, starts[1:])]
            print("   %s 起跳 %d 次，间隔=%s" % (hid, len(starts), gaps[:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
