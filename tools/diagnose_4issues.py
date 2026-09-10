#!/usr/bin/env python3
"""针对用户反馈的4个问题做定向分析：
1. 操作卡手（频繁接管/释放抖动）
2. 地刺避让不明显（spike terrain未被检测）
3. 火堆避让范围过大（fireplace srcT=33 检测距离）
4. 抛物线弹幕未避让（bomb类 srcT 未被关联）

用法: python tools/diagnose_4issues.py <dir>
"""
import json
import math
import sys
from pathlib import Path
from collections import Counter, defaultdict


def analyze_session(path):
    """分析单个session，提取4个问题相关的数据"""
    frames = []
    events = []
    context_frames = {}  # damage_context 的 snapshot 详情

    with open(path, encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(rec, dict):
                continue
            rec["_line"] = lineno
            ev = rec.get("ev")

            if ev == "context" and isinstance(rec.get("snapshot"), dict):
                detail = rec["snapshot"]
                key = (detail.get("tick", detail.get("frame")), detail.get("room"))
                context_frames[key] = detail
            elif ev and ev != "snapshot":
                events.append(rec)
            elif "frame" in rec:
                frames.append(rec)

    # Merge context
    for record in frames:
        key = (record.get("tick", record.get("frame")), record.get("room"))
        if key in context_frames:
            record.update(context_frames.pop(key))
    frames.sort(key=lambda r: (r.get("tick", r["frame"]), r["frame"]))

    result = {
        "file": path.name,
        "total_frames": len(frames),
        "total_events": len(events),
    }

    # ===== 问题1: 操作卡手 —— 频繁 avoidance_start/end 切换 =====
    avoid_starts = [e for e in events if e.get("ev") == "avoidance_start"]
    avoid_ends = [e for e in events if e.get("ev") == "avoidance_end"]
    result["avoidance_start_count"] = len(avoid_starts)
    result["avoidance_end_count"] = len(avoid_ends)

    # 计算连续 active 帧 vs 非 active 帧
    active_frames = [f for f in frames if f.get("active")]
    result["active_frames"] = len(active_frames)
    result["active_ratio"] = len(active_frames) / max(len(frames), 1)

    # 检测接管抖动：连续的 active->inactive->active 切换
    jitter_count = 0
    prev_active = None
    for f in frames:
        curr = bool(f.get("active"))
        if prev_active is not None and curr != prev_active:
            jitter_count += 1
        prev_active = curr
    result["control_jitter_transitions"] = jitter_count

    # active 连续段长度分布
    run_lengths = []
    current_run = 0
    for f in frames:
        if f.get("active"):
            current_run += 1
        else:
            if current_run > 0:
                run_lengths.append(current_run)
            current_run = 0
    if current_run > 0:
        run_lengths.append(current_run)
    result["active_run_lengths"] = run_lengths
    result["avg_active_run"] = sum(run_lengths) / max(len(run_lengths), 1)

    # ===== 问题2: 地刺（terrain hit）=====
    terrain_events = [e for e in events if e.get("ev") == "terrain"]
    hit_events = [e for e in events if e.get("ev") == "hit"]
    undetected_hits = [h for h in hit_events if h.get("kind") == "undetected"]
    unresolved_hits = [h for h in hit_events if h.get("kind") == "unresolved"]

    result["terrain_count"] = len(terrain_events)
    result["total_hits"] = len(hit_events)
    result["undetected_hits"] = len(undetected_hits)
    result["unresolved_hits"] = len(unresolved_hits)

    # 检查 undetected hit 的来源
    undetected_sources = Counter()
    for h in undetected_hits:
        src = f"type{h.get('srcT', '?')}/{h.get('srcV', '?')}"
        undetected_sources[src] += 1
    result["undetected_sources"] = dict(undetected_sources)

    # ===== 问题3: 火堆（fireplace, srcT=33）=====
    # 查看 damage_context 里火堆相关
    fireplace_hits = [h for h in hit_events if h.get("srcT") == 33]
    result["fireplace_hits"] = len(fireplace_hits)

    # 查看 hz 数据中火堆的检测距离
    fire_distances = []
    for f in frames:
        for hz in (f.get("hz") or []):
            if hz[0] == "f":  # kind code for effects/fireplace
                dist = math.hypot(hz[2], hz[3])
                fire_distances.append(dist)
    result["fire_hz_distances"] = fire_distances
    result["fire_avg_distance"] = (sum(fire_distances) / len(fire_distances)) if fire_distances else None

    # 查看 snapshots 中 enemy 计数里的 fireplace (type 33)
    fire_entity_frames = 0
    for f in frames:
        if f.get("enemy", 0) > 0:
            fire_entity_frames += 1
    result["frames_with_enemies"] = fire_entity_frames

    # ===== 问题4: 抛物线弹幕（bomb类）=====
    # srcT=4 是 projectile, srcT=13 是 bomb?
    # 查看 unresolved hits 的来源类型
    unresolved_sources = Counter()
    for h in unresolved_hits:
        src = f"type{h.get('srcT', '?')}/{h.get('srcV', '?')}"
        unresolved_sources[src] += 1
    result["unresolved_sources"] = dict(unresolved_sources)

    # 查看所有 hit 来源
    all_hit_sources = Counter()
    for h in hit_events:
        src = f"type{h.get('srcT', '?')}/{h.get('srcV', '?')}"
        all_hit_sources[src] += 1
    result["all_hit_sources"] = dict(all_hit_sources)

    # 检查 hz 数据中是否有 bomb 类 (kind='b')
    bomb_hz_count = 0
    for f in frames:
        for hz in (f.get("hz") or []):
            if hz[0] == "b":
                bomb_hz_count += 1
    result["bomb_hz_detections"] = bomb_hz_count

    # 检查 forecast_match 事件（可能是炸弹预测）
    forecast_events = [e for e in events if e.get("ev") == "forecast_match"]
    result["forecast_match_count"] = len(forecast_events)

    # 详细 hit 事件上下文
    hit_details = []
    for h in hit_events:
        detail = {
            "frame": h.get("frame"),
            "srcT": h.get("srcT"),
            "srcV": h.get("srcV"),
            "kind": h.get("kind"),
            "dmg": h.get("dmg"),
            "via": h.get("via"),
        }
        # 找 damage_context
        for e in events:
            if e.get("ev") == "damage_context" and e.get("attemptId") == h.get("attemptId"):
                snap = e.get("snapshot", {})
                detail["reason"] = snap.get("reason")
                detail["wallDist"] = snap.get("wallDist")
                detail["hazards"] = snap.get("hazards")
                detail["plan"] = snap.get("plan")
                metrics = snap.get("metrics", {})
                detail["evaluated"] = metrics.get("evaluated")
                detail["selectedRisk"] = metrics.get("selectedRisk")
                break
        hit_details.append(detail)
    result["hit_details"] = hit_details

    return result


def main():
    if len(sys.argv) < 2:
        print("用法: python tools/diagnose_4issues.py <录制目录>")
        sys.exit(1)

    directory = Path(sys.argv[1])
    if not directory.is_dir():
        print(f"✗ 目录不存在: {directory}")
        sys.exit(1)

    files = sorted(directory.glob("*.jsonl"), reverse=True)
    # 只分析有实际数据的大文件 (>5KB)
    big_files = [f for f in files if f.stat().st_size > 5000]
    print(f"分析 {len(big_files)} 个有效录制会话（>5KB）...\n")

    results = []
    for f in big_files[:20]:  # 最多分析20个
        r = analyze_session(f)
        if r["total_frames"] > 0:
            results.append(r)

    if not results:
        print("没有有效录制数据")
        return

    # ===== 问题1: 操作卡手分析 =====
    print("=" * 70)
    print("问题1: 操作卡手（控制抖动分析）")
    print("=" * 70)
    for r in results:
        if r["total_frames"] < 10:
            continue
        print(f"\n  {r['file'][:60]}")
        print(f"    总帧数={r['total_frames']}  活跃帧={r['active_frames']}  "
              f"活跃率={r['active_ratio']:.1%}")
        print(f"    avoidance_start={r['avoidance_start_count']}  "
              f"avoidance_end={r['avoidance_end_count']}")
        print(f"    控制切换次数={r['control_jitter_transitions']}  "
              f"平均连续活跃段={r['avg_active_run']:.1f}帧")
        if r['active_run_lengths']:
            print(f"    活跃段长度分布: {sorted(r['active_run_lengths'])[:20]}"
                  f"{'...' if len(r['active_run_lengths']) > 20 else ''}")

    # ===== 问题2: 地刺分析 =====
    print("\n" + "=" * 70)
    print("问题2: 地刺避让（未检测来源分析）")
    print("=" * 70)
    for r in results:
        if r["undetected_hits"] == 0:
            continue
        print(f"\n  {r['file'][:60]}")
        print(f"    未检测受击={r['undetected_hits']}  来源={r['undetected_sources']}")

    # ===== 问题3: 火堆分析 =====
    print("\n" + "=" * 70)
    print("问题3: 火堆避让范围")
    print("=" * 70)
    for r in results:
        if r["fireplace_hits"] or r["fire_hz_distances"]:
            print(f"\n  {r['file'][:60]}")
            if r["fireplace_hits"]:
                print(f"    火堆受击={r['fireplace_hits']}")
            if r["fire_hz_distances"]:
                print(f"    火堆hz检测距离: 样本数={len(r['fire_hz_distances'])} "
                      f"平均={r['fire_avg_distance']:.0f}px "
                      f"最小={min(r['fire_hz_distances']):.0f}px "
                      f"最大={max(r['fire_hz_distances']):.0f}px")

    # ===== 问题4: 抛物线弹幕 =====
    print("\n" + "=" * 70)
    print("问题4: 抛物线弹幕（炸弹类）避让")
    print("=" * 70)
    for r in results:
        if r["unresolved_hits"] == 0 and r["bomb_hz_detections"] == 0 and r["forecast_match_count"] == 0:
            continue
        print(f"\n  {r['file'][:60]}")
        print(f"    待复核受击={r['unresolved_hits']}  来源={r['unresolved_sources']}")
        print(f"    bomb类hz检测={r['bomb_hz_detections']}  "
              f"forecast_match事件={r['forecast_match_count']}")

    # ===== 全局 hit 详情表 =====
    print("\n" + "=" * 70)
    print("所有受击事件详情")
    print("=" * 70)
    print(f"{'文件':<45} {'帧':>8} {'srcT/V':>10} {'kind':<10} {'dmg':>3} {'原因':<15}")
    print("-" * 100)
    for r in results:
        for h in r["hit_details"]:
            src = f"{h.get('srcT', '?')}/{h.get('srcV', '?')}"
            kind = h.get("kind", "?") or "?"
            reason = h.get("reason", "?") or "?"
            print(f"  {r['file'][:43]:<45} {h.get('frame', '?'):>8} {src:>10} "
                  f"{kind:<10} {h.get('dmg', '?'):>3} {reason:<15}")

    # ===== 全局来源汇总 =====
    all_sources = Counter()
    for r in results:
        for src, cnt in r["all_hit_sources"].items():
            all_sources[src] += cnt
    if all_sources:
        print(f"\n受击来源全局汇总: {dict(all_sources)}")

    # Isaac Entity Type 参考:
    # 0=none, 1=player, 2=tear, 3=familiar, 4=projectile, 5=knife
    # 6=slot/beggar, 8=bomb, 9=laser, 10=knockback, 13=leech
    # 33=fireplace, 219=wizoob, 807=?
    print("\nIsaac Entity Type 参考: "
          "0=none 2=tear 4=projectile 8=bomb 9=laser 13=leech 33=fireplace")


if __name__ == "__main__":
    main()
