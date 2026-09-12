#!/usr/bin/env python3
"""post_play.py — 玩完一条命令出全部报告

它会依次做：
  1. 从游戏录目录挑最近的会话，复制到 analysis/<时间>_play/（先备份，避免被后续覆盖）
  2. 抽逐帧威胁轨迹（tools/extract_traces.py）
  3. 核对跳跃预判（tools/analyze_hop.py：实测前摇 / 落点误差 / 节拍）
  4. 出回放诊断（tools/analyze_replay.py：受击归因 + 动画库缺口 + 跳蛛实测量）
  5. 在终端打印摘要（受击、触发类型、跳蛛实测、动画缺条目 top5）

用法:
    python tools/post_play.py                    # 最新一个会话
    python tools/post_play.py --sessions 3       # 最近 3 个会话
    python tools/post_play.py --dir <回放目录>    # 手动指定
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIN_BYTES = 50_000          # 小于这个的多半只是会话头，没有分析价值
STEAM_CANDIDATES = [
    r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth",
    r"C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth",
    r"C:\Program Files\Steam\steamapps\common\The Binding of Isaac Rebirth",
]


def find_recordings(explicit=None):
    if explicit:
        return Path(explicit)
    env = os.environ.get("GS_RECORDINGS")
    if env and Path(env).is_dir():
        return Path(env)
    for base in STEAM_CANDIDATES:
        p = Path(base) / "mods" / "GhostStep3" / "recordings"
        if p.is_dir():
            return p
    # 兜底：仓库里的桩目录（run_smoke 用的）
    stub = ROOT / "recordings"
    return stub if stub.is_dir() else None


def run(cmd):
    print("  $", " ".join(str(c) for c in cmd), flush=True)
    r = subprocess.run([sys.executable] + [str(c) for c in cmd], cwd=str(ROOT))
    return r.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", type=int, default=1, help="取最近几个会话（按文件时间）")
    ap.add_argument("--dir", default=None, help="回放目录（默认自动找 Steam mod 目录）")
    ap.add_argument("--min-kb", type=int, default=MIN_BYTES // 1000, help="低于这个大小的文件跳过")
    args = ap.parse_args()

    src = find_recordings(args.dir)
    if src is None or not src.is_dir():
        print("找不到回放目录：用 --dir 指定（或设环境变量 GS_RECORDINGS）")
        return 1
    files = [Path(p) for p in glob.glob(str(src / "session_*.jsonl"))]
    files = [p for p in files if p.stat().st_size >= args.min_kb * 1000]
    if not files:
        print(f"{src} 里没有 >= {args.min_kb}KB 的回放（小文件多半只有会话头，没分析价值）")
        return 1
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    picked = files[:max(1, args.sessions)]
    print(f"回放目录：{src}")
    for p in picked:
        print(f"  选中 {p.name}  ({p.stat().st_size/1e6:.1f} MB, {time.strftime('%H:%M', time.localtime(p.stat().st_mtime))})")

    stamp = time.strftime("%Y%m%d_%H%M")
    out = ROOT / "analysis" / f"{stamp}_play"
    out.mkdir(parents=True, exist_ok=True)
    print(f"\n[1/4] 备份到 {out}")
    local = []
    for p in picked:
        dst = out / p.name
        shutil.copy2(p, dst)
        local.append(dst)

    traces = []
    print("\n[2/4] 抽逐帧威胁轨迹")
    for p in local:
        d = out / ("traces_" + p.stem.split("_")[-3] + "_" + p.stem.split("_")[-1])
        if run([ROOT / "tools" / "extract_traces.py", p, d]) != 0:
            print("  （抽取失败，跳过）")
            continue
        traces.append(d)

    print("\n[3/4] 核对跳跃预判")
    for d in traces:
        run([ROOT / "tools" / "analyze_hop.py", d])

    print("\n[4/4] 回放诊断")
    report_dir = out / "report"
    run([ROOT / "tools" / "analyze_replay.py"] + local + ["--output", report_dir])

    # ---- 终端摘要 ----
    rj = report_dir / "report.json"
    print("\n" + "=" * 70)
    if not rj.exists():
        print("没生成 report.json，请把上面最后的报错发给我")
        return 1
    reports = json.loads(rj.read_text(encoding="utf-8"))
    for r in reports:
        ev = Counter(r.get("events", {}))
        reasons = Counter(r.get("reasons", {}))
        names = [x for x in ("hop_measured", "anim_missing", "forecast_match", "toggle", "damage_attempt", "hit") if ev.get(x)]
        print(f"\n## {Path(r['file']).name}")
        print(f"  快照 {r['counts'].get('snapshots',0)} 帧；事件：" + "，".join(f"{k}={ev[k]}" for k in names))
        print(f"  原因分布 top3：" + "，".join(f"{k}={v}" for k, v in reasons.most_common(3)))
        hits = [d for d in r.get("damage", []) if "observedHpLoss" in d]
        if hits:
            print(f"  实际受击 {len(hits)} 次；当时原因：" +
                  "，".join(f"{k}={v}" for k, v in Counter(h.get("reason") for h in hits).items()))
            kinds = [h.get("context", {}).get("metrics", {}).get("triggerKind") for h in hits]
            print("  受击触发类型：" + "，".join(f"{k}={v}" for k, v in Counter(x or 'unknown' for x in kinds).items()))
        hops = r.get("hopMeasured") or []
        if hops:
            def med(vals):
                vals = sorted(v for v in vals if isinstance(v, (int, float)))
                return vals[len(vals) // 2] if vals else None
            per = Counter((h.get("entityType"), h.get("variant")) for h in hops)
            print(f"  跳蛛/跳跃实测 {len(hops)} 次：")
            for (t, v), n in per.most_common(5):
                sub = [h for h in hops if (h.get("entityType"), h.get("variant")) == (t, v)]
                print(f"    type {t}:{v}  n={n}  滞空={med([x.get('flight') for x in sub])}  跳距={med([x.get('leap') for x in sub])}"
                      f"  间隔={med([x.get('period') for x in sub])}  实测前摇={med([x.get('windup') for x in sub])}"
                      f"  朝向误差={med([x.get('aimErr') for x in sub])}")
        gaps = r.get("animMissing") or []
        if gaps:
            t = Counter((g.get("entityType"), g.get("variant"), g.get("animation")) for g in gaps)
            print(f"  动画库缺条目 {len(gaps)} 次 / {len(t)} 种，top5：" +
                  "，".join(f"{a}@{ty}({n})" for (ty, va, a), n in t.most_common(5)))
    print("=" * 70)
    print(f"\n详细报告：{report_dir/'report.md'}")
    print(f"跳蛛/动画：{report_dir/'hop_measured.csv'}、{report_dir/'anim_gaps.csv'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
