#!/usr/bin/env python3
# tools/replay_viewer.py
# GhostStep3 回放数据离线分析器：解析 recordings/*.jsonl（SessionRecorder 输出格式）
#
# 用法:
#   python tools/replay_viewer.py                          # 列出 ./recordings 会话
#   python tools/replay_viewer.py --dir <path>             # 指定录制目录（如游戏 mods 下的 recordings）
#   python tools/replay_viewer.py <file.jsonl>             # 直接分析单个文件
#   python tools/replay_viewer.py --dir <path> --latest    # 分析目录中最新会话
#   python tools/replay_viewer.py <file> --seconds 10      # 死亡回放窗口改为10秒
#   python tools/replay_viewer.py --dir <path> --summary   # 跨会话受击归因汇总（调参仪表盘）
#   python tools/replay_viewer.py <file> --frame 12345     # 渲染某帧弹幕场快照（需 matplotlib）
#
# 输出: 会话列表 / 事件时间线 / 威胁曲线(ASCII) / 死亡回放(镜像游戏内 gs replay 格式) /
#       受击归因聚合 / 配置回显 / 弹幕场快照图（级别4 hz 数据）
# 数据格式见 recording/session_recorder.lua + recording/snapshot.lua（detail 1/2/3/4 字段）

import argparse
import json
import math
import sys
from pathlib import Path

FPS = 30  # Isaac 逻辑帧率，录制帧号即游戏帧

# 单序列威胁曲线用 8 级分块字符（基线对齐，宽度1字符=细标记）
BAR_CHARS = " ▁▂▃▄▅▆▇█"

# 级别4 hz 条目 kind 代号（snapshot.lua KIND_CODE 的反查）
KIND_NAMES = {"p": "弹幕", "e": "敌人", "l": "激光", "b": "炸弹", "f": "效果", "n": "前兆"}

# hit 事件归因 kind → 中文名（main.lua ATTR_KIND_NAMES 镜像）
ATTR_NAMES = {
    "undetected": "未检测", "unresolved": "待复核", "late": "检测太晚", "wrongDir": "方向错误",
    "lowWeight": "权重不足", "blocked": "位移受阻", "tooFast": "反应不足",
}

# 常见 Isaac 实体类型 ID → 可读名（受击来源 srcT 映射，仅用于显示；未知类型不列出）
# 只收录已确认的类型，不确定的不猜
ENTITY_TYPE_NAMES = {
    0: "none", 6: "slot/beggar", 9: "laser", 13: "leech", 33: "fireplace",
    219: "wizoob", 293: "ultra_greed_coin",
}

# cfg 回显挑的调参关键参数（其余参数全量在 jsonl 里，不在终端刷屏）
CFG_KEYS = [
    "preset", "threatSensitivity", "anticipateStrength", "maxDodgeWeight",
    "threatLow", "threatMedium", "threatHigh", "gradientRadius",
    "wallEscapeSensitivity", "wallStuckThreshold", "wallPenaltyBase",
    "directionSmoothFrames", "minHoldFrames", "budgetMs", "snapshotDetail",
]

# 弹幕场快照图配色（dataviz 校验通过的分类色，相邻 CVD ΔE 9.1 / 常规 19.6；
# kind↔颜色固定顺序，marker 形状双编码，图例必有——对比度 WARN 的救济）
HZ_STYLE = {  # 代码 → (中文名, 颜色, marker)
    "p": ("弹幕", "#2a78d6", "o"),
    "e": ("敌人", "#eb6834", "s"),
    "l": ("激光", "#1baf7a", "^"),
    "b": ("炸弹", "#eda100", "D"),
    "f": ("效果", "#e87ba4", "v"),
    "n": ("前兆", "#008300", "P"),
}
INK = "#0b0b0b"          # 玩家/闪避方向箭头（主墨色）
INK_2 = "#52514e"        # 玩家输入箭头（次级墨色）
CTRL_C = "#d03b3b"       # 合成输出箭头（状态色 critical，配文字标签）
MUTED = "#898781"        # 候选刻度/坐标轴
GRID = "#e1e0d9"         # 网格线
SURFACE = "#fcfcfb"      # 图表面色


def force_utf8():
    # Windows 控制台默认 GBK，块字符/中文会炸；Git Bash 与重定向均安全通过
    try:
        if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
            sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def parse_session(path):
    """解析一个 jsonl → (seed, frames, events)；坏行跳过并计数"""
    seed = None
    frames = []
    events = []
    bad = 0
    context = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                bad += 1
                continue
            if not isinstance(rec, dict):
                bad += 1
                continue
            if rec.get("ev") == "context" and isinstance(rec.get("snapshot"), dict):
                detail = rec["snapshot"]
                key = (detail.get("tick", detail.get("frame")), detail.get("room"))
                detail["_line"] = lineno
                context[key] = detail
            elif "ev" in rec:
                rec["_line"] = lineno
                events.append(rec)
                if rec["ev"] == "session_start":
                    seed = rec.get("seed", "")
            elif "frame" in rec:
                rec["_line"] = lineno
                frames.append(rec)
            else:
                # 无 frame 无 ev 的行（旧版本录出的 "{}" 桩）计入坏行
                bad += 1
    for record in frames:
        key = (record.get("tick", record.get("frame")), record.get("room"))
        record.update(context.pop(key, {}))
    frames.extend(context.values())
    frames.sort(key=lambda r: (r.get("tick", r["frame"]), r["frame"]))
    return seed, frames, events, bad


def detail_level(sample):
    """按 snapshot.lua 的字段判断录制详情级别"""
    if "hz" in sample or "cand" in sample:
        return 4
    if "cx" in sample:
        return 3
    if "vx" in sample:
        return 2
    return 1


def detail_level_scan(frames):
    """级别4字段（hz/cand）可能只出现在部分帧，从末尾回扫判断"""
    for f in reversed(frames[-90:]):  # 最多回看3秒
        lv = detail_level(f)
        if lv >= 4:
            return 4
    return detail_level(frames[-1])


def fmt_duration(seconds):
    m, s = divmod(int(seconds), 60)
    return f"{m}m{s:02d}s"


# ===== 会话列表 =====

def list_sessions(directory):
    rows = []
    for p in sorted(Path(directory).glob("*.jsonl"), reverse=True):  # 最新在前（文件名含时间戳）
        seed, frames, events, bad = parse_session(p)
        if not frames and not events:
            continue
        span = (frames[-1]["frame"] - frames[0]["frame"]) if len(frames) >= 2 else 0
        deaths = sum(1 for e in events if e["ev"] == "death")
        # 受击归因聚合（hit 事件 kind 字段；旧版录制无 kind 记 "?"）
        kinds = {}
        for e in events:
            if e["ev"] == "hit":
                k = e.get("kind") or "?"
                kinds[k] = kinds.get(k, 0) + 1
        hits = sum(kinds.values())
        rooms = sorted({f.get("room") for f in frames if f.get("room") is not None})
        rows.append({
            "path": p, "seed": seed or "?", "frames": len(frames),
            "span": span, "deaths": deaths, "hits": hits, "kinds": kinds,
            "rooms": len(rooms), "bad": bad,
        })
    return rows


def print_session_list(rows):
    print(f"找到 {len(rows)} 个会话:")
    print(f"{'文件名':<48} {'种子':<12} {'帧数':>6} {'时长':>7} {'房间':>4} {'受击':>4} {'死亡':>4}")
    for r in rows:
        name = r["path"].name
        if len(name) > 46:
            name = name[:43] + "..."
        print(f"{name:<48} {str(r['seed'])[:10]:<12} {r['frames']:>6} "
              f"{fmt_duration(r['span'] / FPS):>7} {r['rooms']:>4} {r['hits']:>4} {r['deaths']:>4}")


# ===== 跨会话归因汇总（调参仪表盘: 哪类失败多就知道该调哪组参数）=====

def print_summary(rows):
    SHORT_THRESHOLD = 60  # <60帧视为短会话（房间切换即断）
    short_count = sum(1 for r in rows if r["frames"] < SHORT_THRESHOLD and r["hits"] == 0)
    print(f"{'会话':<44} {'受击':>4} {'死亡':>4}  归因分布")
    total = {}
    hits_all = deaths_all = 0
    for r in rows:
        name = r["path"].name
        if len(name) > 42:
            name = name[:39] + "..."
        dist = " ".join(f"{ATTR_NAMES.get(k, k)}{v}" for k, v in
                        sorted(r["kinds"].items(), key=lambda kv: -kv[1])) or "—"
        print(f"{name:<44} {r['hits']:>4} {r['deaths']:>4}  {dist}")
        for k, v in r["kinds"].items():
            total[k] = total.get(k, 0) + v
        hits_all += r["hits"]
        deaths_all += r["deaths"]
    print("-" * 72)
    dist = " ".join(f"{ATTR_NAMES.get(k, k)}{v}" for k, v in
                    sorted(total.items(), key=lambda kv: -kv[1])) or "—"
    print(f"{'合计 (' + str(len(rows)) + ' 会话)':<44} {hits_all:>4} {deaths_all:>4}  {dist}")
    if short_count:
        print(f"  （其中 {short_count} 个短会话 <{SHORT_THRESHOLD} 帧、无受击，多为房间切换录制）")
    if total:
        worst = max(total, key=total.get)
        pct = total[worst] / max(hits_all, 1)
        print(f"\n最大失败类别: {ATTR_NAMES.get(worst, worst)} "
              f"({total[worst]}/{hits_all} = {pct:.0%})")
        hints = {
            "undetected": "→ 检查危险源开关/传感器覆盖（sensors/*）",
            "unresolved": "→ damage_callback 存在但无法关联已知威胁传感器；"
                          "检查 srcT/srcV 是否是传感器未覆盖的来源类型（如环境伤害、新敌人）",
            "late": "→ threatSensitivity↑ 或 anticipateStrength↑",
            "wrongDir": "→ fallback 弹道线逃逸惩罚权重↑/候选加密",
            "lowWeight": "→ wallEscapeSensitivity↑ 或远离墙壁偏向加强",
            "blocked": "→ 逃逸通道被封，需中期规划（Tier 1）提前避围",
            "tooFast": "→ 需更长预测视野（时空轨迹评分/Tier 1）",
        }
        if worst in hints:
            print(hints[worst])


# ===== 威胁曲线（ASCII sparkline，单序列无图例，标题即系列名）=====

def sparkline(values, width, markers=None):
    """values → width 列分块字符行 + 事件标记行；markers: [(col, '▲'|'✕')]"""
    n = len(values)
    if n == 0 or width < 4:
        return "", ""
    vmax = max(values)
    if vmax <= 0:
        vmax = 1.0
    step = n / width
    row_chars = []
    mark_slots = [[] for _ in range(width)]
    for i in range(width):
        lo, hi = int(i * step), int((i + 1) * step)
        bucket = values[lo:max(hi, lo + 1)]
        peak = max(bucket) if bucket else 0.0
        frac = peak / vmax
        row_chars.append(BAR_CHARS[min(int(frac * (len(BAR_CHARS) - 1)) + (1 if frac > 0 else 0),
                                       len(BAR_CHARS) - 1)])
        if markers:
            for idx, ch in markers:
                col = min(int(idx / n * width), width - 1)
                if i == col:
                    mark_slots[i].append(ch)
    mark_row = "".join(slots[0] if slots else " " for slots in mark_slots)
    return "".join(row_chars), mark_row


# ===== 弹幕场快照（--frame，级别4 hz 数据；玩家为原点，坐标=相对玩家）=====

def find_frame(frames, target):
    """精确匹配或最近的前一帧"""
    rec = None
    for f in frames:
        if f["frame"] == target:
            return f
        if f["frame"] < target:
            rec = f
        else:
            break
    return rec


def frame_text_dump(rec, requested):
    """无 matplotlib 时的文本表格（同时是对比度 WARN 的表格救济）"""
    if rec["frame"] != requested:
        print(f"(帧 {requested} 不存在，显示最近的前一帧 f{rec['frame']})")
    print(f"\n帧 f{rec['frame']} room{rec.get('room', -1)} | "
          f"threat={rec.get('threat') or 0:.2f} hit={rec.get('hitFrame', -1)} "
          f"layer={rec.get('layer') or '?'} w={rec.get('weight') or 0:.2f} "
          f"wall={rec.get('wallDist', '?')}")
    hz = rec.get("hz") or []
    if not hz:
        print("  本帧无 hz 明细（需 MCM 详情级别=4 且周围有威胁）")
    else:
        print(f"  {'威胁':<6} {'var':>4} {'相对位置':>14} {'速度':>14} {'r':>4} {'dmg':>4} {'距':>5}")
        for e in sorted(hz, key=lambda h: (h[2] ** 2 + h[3] ** 2)):
            kind = KIND_NAMES.get(e[0], e[0])
            dist = (e[2] ** 2 + e[3] ** 2) ** 0.5
            print(f"  {kind:<6} {e[1]:>4} ({e[2]:>6.0f},{e[3]:>6.0f}) "
                  f"({e[4]:>6.1f},{e[5]:>6.1f}) {e[6]:>4.0f} {e[7]:>4.1f} {dist:>4.0f}")
    for name, keys in (("闪避D", ("dx", "dy")), ("输出C", ("cx", "cy")), ("输入P", ("ix", "iy"))):
        if rec.get(keys[0]) is not None:
            print(f"  {name}=({rec[keys[0]]:.2f},{rec[keys[1]]:.2f})")
    cand = rec.get("cand")
    if cand:
        best = rec.get("bestScore")
        ctxt = "  ".join(f"{c['a']:.0f}°/{c['s']:.1f}" for c in cand)
        print(f"  候选(角度/分): {ctxt}  最优分={best:.1f}" if best is not None
              else f"  候选(角度/分): {ctxt}")


def render_frame(rec, requested):
    """matplotlib 渲染: 玩家原点 + 威胁（色+形状双编码）+ 速度箭头 + P/D/C 方向 + 候选刻度"""
    try:
        import matplotlib
        matplotlib.use("Agg")  # 无显示环境也能出 PNG
        import matplotlib.pyplot as plt
        from matplotlib.lines import Line2D
        # Windows 中文标签: DejaVu 无 CJK 字形（会渲染成方框），优先雅黑
        plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "Noto Sans CJK SC",
                                           "PingFang SC", "DejaVu Sans"]
        plt.rcParams["axes.unicode_minus"] = False
    except ImportError:
        print("✗ 未安装 matplotlib，改用文本表格（装了可出图: pip install matplotlib）")
        frame_text_dump(rec, requested)
        return 0

    fig, ax = plt.subplots(figsize=(8, 8), facecolor=SURFACE)
    ax.set_facecolor(SURFACE)

    # 威胁: 散点（大小∝半径）+ 速度箭头（×8 放大可见性）
    legend_handles = []
    by_kind = {}
    for e in rec.get("hz") or []:
        by_kind.setdefault(e[0], []).append(e)
    for code, entries in by_kind.items():
        name, color, marker = HZ_STYLE.get(code, (code, MUTED, "x"))
        xs = [e[2] for e in entries]
        ys = [e[3] for e in entries]
        sizes = [max(3.14159 * (e[6] or 8) ** 2 * 0.15, 20) for e in entries]
        ax.scatter(xs, ys, s=sizes, c=color, marker=marker, alpha=0.85,
                   edgecolors=SURFACE, linewidths=1, zorder=3)
        # 速度箭头
        vx = [e[4] for e in entries]
        vy = [e[5] for e in entries]
        if any(abs(v) > 0.1 for v in vx + vy):
            ax.quiver(xs, ys, vx, vy, color=color, angles="xy", scale_units="xy",
                      scale=1 / 8, width=0.004, alpha=0.7, zorder=2)
        legend_handles.append(Line2D([0], [0], color=color, marker=marker, linestyle="",
                                     markersize=8, label=f"{name}×{len(entries)}"))

    # 玩家: 原点实心圆（主墨色）
    ax.add_patch(plt.Circle((0, 0), 10, color=INK, zorder=4))
    legend_handles.append(Line2D([0], [0], color=INK, marker="o", linestyle="",
                                 markersize=8, label="玩家"))

    # 方向箭头: D=闪避方向(墨色) C=合成输出(红) P=玩家输入(次级墨色)，各带文字标签
    for keys, color, label, off in ((("dx", "dy"), INK, "D 闪避", 46),
                                    (("cx", "cy"), CTRL_C, "C 输出", 40),
                                    (("ix", "iy"), INK_2, "P 输入", 52)):
        x, y = rec.get(keys[0]), rec.get(keys[1])
        if x is None or y is None:
            continue
        n = (x * x + y * y) ** 0.5
        if n < 0.05:
            continue
        ax.annotate("", xy=(x, y), xytext=(0, 0),
                    arrowprops=dict(arrowstyle="-|>", color=color, lw=2.2), zorder=5)
        ax.text(x / n * off, y / n * off, label, color=color, fontsize=9,
                ha="center", va="center", zorder=5)
        legend_handles.append(Line2D([0], [0], color=color, lw=2.2, label=label))

    # 候选方向刻度（60px 参考圆上，分数越优刻度越大）
    cand = rec.get("cand")
    if cand:
        scores = [c["s"] for c in cand]
        lo, hi = min(scores), max(scores)
        for c in cand:
            a = math.radians(c["a"])
            size = 14 if hi == lo else 14 + 26 * (1 - (c["s"] - lo) / (hi - lo))
            ax.scatter([math.cos(a) * 60], [math.sin(a) * 60], s=size, c=MUTED,
                       marker="|", zorder=2)
        best = rec.get("bestScore")
        legend_handles.append(Line2D([0], [0], color=MUTED, marker="|", linestyle="",
                                     markersize=8,
                                     label=f"候选×{len(cand)}" + (f"(最优{best:.0f})" if best is not None else "")))

    # 版面
    ax.set_aspect("equal")
    # hz 为空时坐标轴默认 (0,1)×(0,1)：玩家圆和箭头会被 bbox_inches=crop 掉——
    # 设合理默认范围让原点玩家+方向箭头有足够显示空间
    if not rec.get("hz"):
        ax.set_xlim(-200, 200)
        ax.set_ylim(-200, 200)
    ax.grid(True, color=GRID, linewidth=0.8, zorder=0)
    ax.axhline(0, color=GRID, linewidth=1, zorder=0)
    ax.axvline(0, color=GRID, linewidth=1, zorder=0)
    ax.tick_params(colors=MUTED, labelsize=8)
    for spine in ax.spines.values():
        spine.set_color(GRID)
    wall = rec.get("wallDist")
    wall_txt = f" wall={wall:.0f}" if wall is not None and 0 <= wall < 9000 else ""
    ax.set_title(f"f{rec['frame']} room{rec.get('room', -1)} | "
                 f"threat={rec.get('threat') or 0:.2f} layer={rec.get('layer') or '?'} "
                 f"w={rec.get('weight') or 0:.2f}{wall_txt}",
                 color=INK, fontsize=10)
    ax.set_xlabel("相对玩家 X (px)", color=MUTED, fontsize=9)
    ax.set_ylabel("相对玩家 Y (px)", color=MUTED, fontsize=9)
    ax.legend(handles=legend_handles, loc="upper right", fontsize=8, framealpha=0.9,
              edgecolor=GRID)

    out = Path(f"gs_frame_{rec['frame']}.png")
    fig.savefig(out, dpi=150, bbox_inches="tight", facecolor=SURFACE)
    plt.close(fig)
    print(f"✓ 已渲染 {out}" + ("" if rec["frame"] == requested
                              else f"（请求帧 {requested} 不存在，用了最近前一帧）"))
    return 0


# ===== 死亡回放（镜像 recording/death_replay.lua 的 gs replay 输出格式）=====

def dump_death_replay(frames, death_frame, seconds):
    take = min(int(seconds * FPS), len(frames))
    recent = [f for f in frames if f["frame"] <= death_frame][-take:]
    if not recent:
        print("  [回放缓冲为空]")
        return

    def wall_txt(s):
        w = s.get("wallDist")
        if w is None or w < 0 or w >= 9000:
            return ""
        return f" wall={w:.0f}"

    print(f"  ===== 回放 (死亡 f{death_frame} 前最近 {len(recent)} 帧) =====")
    step = max(1, len(recent) // 60)  # 采样输出避免刷屏，与游戏内一致
    danger_peak = 0.0
    active = 0
    last_printed = None
    for i in range(0, len(recent), step):
        s = recent[i]
        last_printed = s
        t = s.get("threat") or 0
        if t > danger_peak:
            danger_peak = t
        layer = s.get("layer") or "?"
        if layer != "none":
            active += 1
        print("  f{:<6} room{:<3} | threat={:<5.2f} hit={:<6} proj={:<3} enemy={:<3} "
              "layer={:<12} w={:.2f} pos=({:.0f},{:.0f}){}".format(
                  s.get("frame", -1), s.get("room", -1), t,
                  f"{s.get('hitFrame', -1):.0f}" if isinstance(s.get("hitFrame"), (int, float)) else "-1",
                  s.get("proj", 0), s.get("enemy", 0), layer,
                  s.get("weight") or 0, s.get("px") or 0, s.get("py") or 0, wall_txt(s)))
    # 末帧（死亡瞬间）总是输出（采样步长>1 时可能没被上面覆盖）
    s = recent[-1]
    if s is not last_printed:
        print("  f{:<6} room{:<3} | threat={:<5.2f} hit={:<6} proj={:<3} enemy={:<3} "
              "layer={:<12} w={:.2f} pos=({:.0f},{:.0f}){}  ← 死亡帧".format(
                  s.get("frame", -1), s.get("room", -1), s.get("threat") or 0,
                  f"{s.get('hitFrame', -1):.0f}" if isinstance(s.get("hitFrame"), (int, float)) else "-1",
                  s.get("proj", 0), s.get("enemy", 0), s.get("layer") or "?",
                  s.get("weight") or 0, s.get("px") or 0, s.get("py") or 0, wall_txt(s)))
    print(f"  回放统计: 峰值威胁={danger_peak:.2f} 决策活跃帧(采样)={active}/{len(range(0, len(recent), step))}")
    if s.get("hitKind"):
        print(f"  死亡归因: 来源={s.get('hitKind')} 距离={s.get('hitDist', 0):.0f}px "
              f"预计命中={s.get('hitFrame', -1):.1f}帧后 伤害={s.get('hitDmg', '?')}")


# ===== 统计 =====

def print_stats(frames, events):
    threats = [f.get("threat") or 0 for f in frames]
    layers = {}
    budget = [f.get("budgetMs") for f in frames if f.get("budgetMs") is not None]
    for f in frames:
        layer = f.get("layer") or "?"
        layers[layer] = layers.get(layer, 0) + 1
    proj_peak = max((f.get("proj") or 0) for f in frames) if frames else 0
    enemy_peak = max((f.get("enemy") or 0) for f in frames) if frames else 0
    active_ratio = (len(frames) - layers.get("none", 0)) / max(len(frames), 1)
    cmb_frames = sum(1 for f in frames if f.get("cmb"))

    print("\n会话统计:")
    print(f"  威胁: 峰值={max(threats) if threats else 0:.2f} "
          f"均值={sum(threats) / max(len(threats), 1):.3f}")
    print(f"  决策层分布: " + " ".join(f"{k}={v}" for k, v in
                                       sorted(layers.items(), key=lambda kv: -kv[1])))
    print(f"  决策活跃率: {active_ratio:.1%}  弹幕峰值={proj_peak}  敌人峰值={enemy_peak}"
          + (f"  战斗帧={cmb_frames}" if "cmb" in frames[-1] else ""))
    if budget:
        print(f"  帧预算: 峰值={max(budget):.1f}ms 均值={sum(budget) / len(budget):.2f}ms "
              f"(原则4 上限2ms参考)")
    frame_ms = [f.get("frameMs") for f in frames if f.get("frameMs") is not None]
    if frame_ms:
        print(f"  全程帧耗时(detail3+): 峰值={max(frame_ms):.2f}ms 均值={sum(frame_ms) / len(frame_ms):.2f}ms")
    wall = [f.get("wallDist") for f in frames
            if f.get("wallDist") is not None and 0 <= f.get("wallDist") < 9000]
    if wall:
        print(f"  墙距: 最近={min(wall):.0f}px 均值={sum(wall) / len(wall):.0f}px "
              f"(<60贴墙帧={sum(1 for w in wall if w < 60)})")

    # 闪避方向8方向分布
    DIR8 = ['右', '右下', '下', '左下', '左', '左上', '上', '右上']
    dir_counts = [0] * 8
    for f in frames:
        ddx, ddy = f.get("dx") or 0, f.get("dy") or 0
        if abs(ddx) < 1e-6 and abs(ddy) < 1e-6:
            continue
        idx = int((math.degrees(math.atan2(ddy, ddx)) % 360 + 22.5) % 360 // 45)
        dir_counts[idx] += 1
    dir_total = sum(dir_counts)
    if dir_total:
        print(f"  闪避方向分布 ({dir_total}次):")
        for i, name in enumerate(DIR8):
            cnt = dir_counts[i]
            bar = '█' * max(1, round(cnt / max(dir_counts) * 12)) if cnt else ''
            print(f"    {name:>4} {cnt:>4} ({cnt/dir_total*100:5.1f}%) {bar}")

    # 受击归因分布（本会话 hit 事件聚合；无 kind 字段的旧录制计 "?"）
    kinds = {}
    for e in events:
        if e["ev"] == "hit":
            k = e.get("kind") or "?"
            kinds[k] = kinds.get(k, 0) + 1
    if kinds:
        hits = sum(kinds.values())
        dist = "  ".join(f"{ATTR_NAMES.get(k, k)}={v}" for k, v in
                         sorted(kinds.items(), key=lambda kv: -kv[1]))
        print(f"\n受击归因（{hits} 次）: {dist}")
        # 来源明细（undetected 归因查传感器用）
        srcs = {}
        for e in events:
            if e["ev"] == "hit" and e.get("srcT") not in (None, "?"):
                src_key = f"{e.get('srcT')}/{e.get('srcV')}"
                srcs[src_key] = srcs.get(src_key, 0) + 1
        if srcs:
            top = sorted(srcs.items(), key=lambda kv: -kv[1])[:5]
            def fmt_src(key, cnt):
                t_str, _, v_str = key.partition("/")
                try:
                    t = int(t_str)
                except ValueError:
                    return f"type{key}×{cnt}"
                name = ENTITY_TYPE_NAMES.get(t)
                if name:
                    return f"type{key}({name})×{cnt}"
                return f"type{key}×{cnt}"
            print("  受击来源 top: " + "  ".join(fmt_src(k, c) for k, c in top))


def print_timeline(events, frames):
    TERRAIN_COLLAPSE = 5  # 连续 >=N 个 terrain 折叠显示
    print("\n事件时间线:")
    terrain_run = []  # 累积连续 terrain 的 _line 值
    def flush_terrain():
        if not terrain_run:
            return
        if len(terrain_run) < TERRAIN_COLLAPSE:
            for ln in terrain_run:
                print(f"  [行{ln:>5}] terrain")
        else:
            print(f"  [行{terrain_run[0]:>5}–{terrain_run[-1]:>5}] terrain ×{len(terrain_run)}（连续）")
        terrain_run.clear()

    for e in events:
        ev = e["ev"]
        ftxt = f"f{e.get('frame')}" if e.get("frame") is not None else ""
        if ev == "terrain":
            terrain_run.append(e["_line"])
            continue
        flush_terrain()
        if ev == "session_start":
            extra = ""
            if e.get("char") is not None:
                extra += f" 角色={e.get('char')}"
            if e.get("stage") is not None:
                extra += f" 层={e.get('stage')}"
            print(f"  [行{e['_line']:>5}] session_start  种子={e.get('seed', '?')}{extra}")
        elif ev == "cfg":
            if "k" in e:  # 增量变更事件；完整 dump 由 print_config 回显
                print(f"  [行{e['_line']:>5}] cfg           {e.get('k')} = {e.get('v')}  {ftxt}")
        elif ev == "level":
            print(f"  [行{e['_line']:>5}] level         进入第{e.get('stage')}层  {ftxt}")
        elif ev == "room":
            print(f"  [行{e['_line']:>5}] room          进入房间 idx={e.get('idx')} "
                  f"type={e.get('rtype', '?')}  {ftxt}")
        elif ev == "hit":
            kind = ATTR_NAMES.get(e.get("kind"), e.get("kind") or "?")
            src = f"来源={e.get('srcT')}/{e.get('srcV')}" if e.get("srcT") else ""
            via = f" via={e.get('via')}" if e.get("via") else ""
            print(f"  [行{e['_line']:>5}] hit           ✕ 受击 dmg={e.get('dmg')} "
                  f"归因={kind} {src}  {ftxt}{via}")
        elif ev == "death":
            print(f"  [行{e['_line']:>5}] death         ★ 死亡  {ftxt}")
        elif ev == "toggle":
            state_txt = "开" if e.get("on") else "关"
            print(f"  [行{e['_line']:>5}] toggle        ALT 闪避开关 → {state_txt}  {ftxt}")
        else:
            print(f"  [行{e['_line']:>5}] {ev}")
    flush_terrain()


# ===== 配置回显（A/B 对比的前提：知道录制时参数是什么）=====

def print_config(events):
    dump = None
    changes = []
    for e in events:
        if e["ev"] == "cfg":
            if "k" in e:
                changes.append(e)
            elif dump is None:
                dump = e  # 第一条无 k 的是开局完整 dump
    if dump is None and not changes:
        return
    if dump:
        shown = [f"{k}={dump[k]}" for k in CFG_KEYS if k in dump]
        if shown:
            print("\n录制配置(开局): " + "  ".join(shown))
    if changes:
        print("录制中变更: " + "  ".join(f"{c.get('k')}→{c.get('v')}" for c in changes))


def analyze(path, seconds, width, frame_target=None):
    seed, frames, events, bad = parse_session(path)
    if not frames and not events:
        print(f"✗ {path} 中没有可解析数据")
        return 1
    print("=" * 72)
    print(f"会话: {path.name}")
    print(f"种子: {seed}    坏行: {bad}")
    if frames:
        span = frames[-1]["frame"] - frames[0]["frame"]
        rooms = sorted({f.get("room") for f in frames if f.get("room") is not None})
        print(f"录制: {len(frames)} 帧  实时跨度 {span} 帧 ≈ {fmt_duration(span / FPS)}  "
              f"详情级别 {detail_level_scan(frames)}  房间 {rooms}")
    print("=" * 72)

    # --frame: 只渲染指定帧的弹幕场快照，其余输出跳过
    if frame_target is not None and frames:
        rec = find_frame(frames, frame_target)
        if rec is None:
            print(f"✗ 帧 {frame_target} 之前没有任何帧（首帧 f{frames[0]['frame']}）")
            return 1
        try:
            return render_frame(rec, frame_target)
        except SystemExit:
            raise
        except Exception as ex:  # matplotlib 环境问题等 → 文本兜底
            print(f"✗ 渲染失败({ex})，改用文本模式:")
            frame_text_dump(rec, frame_target)
            return 0

    print_timeline(events, frames)
    print_config(events)

    if frames:
        # 标记行: 死亡/受击事件映射到曲线列（toggle 等其他带 frame 事件不标）
        fmin, fmax = frames[0]["frame"], frames[-1]["frame"]
        markers = []
        for e in events:
            ef = e.get("frame")
            if ef is None or e["ev"] not in ("death", "hit"):
                continue
            if not (fmin <= ef <= fmax):
                continue
            markers.append((ef - fmin, "▲" if e["ev"] == "death" else "✕"))
        threats = [f.get("threat") or 0 for f in frames]
        t_row, m_row = sparkline(threats, width, markers)
        print(f"\n威胁曲线 (峰值 {max(threats):.2f}):")
        print(f"  {fmin:>6}f {t_row} {fmax:>6}f")
        if m_row.strip():
            print(f"          {m_row}  ▲=死亡 ✕=受击")

        weights = [f.get("weight") or 0 for f in frames]
        if max(weights) > 0:
            w_row, _ = sparkline(weights, width)
            print(f"\n闪避权重曲线 (峰值 {max(weights):.2f}):")
            print(f"  {'':>7}{w_row}")

        print_stats(frames, events)

        deaths = [e for e in events if e["ev"] == "death" and e.get("frame") is not None]
        for i, e in enumerate(deaths, 1):
            print(f"\n===== 死亡回放 #{i} (frame {e['frame']}) =====")
            dump_death_replay(frames, int(e["frame"]), seconds)
        if not deaths:
            print("\n(本会话无死亡事件，无死亡回放)")
    return 0


def main():
    force_utf8()
    ap = argparse.ArgumentParser(description="GhostStep3 回放数据分析器")
    ap.add_argument("file", nargs="?", help="jsonl 文件路径（省略则列出会话）")
    ap.add_argument("--dir", "-d", default=None,
                    help="录制目录（默认: 仓库 recordings/，可指向游戏 mods 下目录）")
    ap.add_argument("--latest", "-l", action="store_true", help="分析目录中最新会话")
    ap.add_argument("--seconds", "-s", type=int, default=5, help="死亡回放窗口秒数 (默认 5)")
    ap.add_argument("--width", "-w", type=int, default=None, help="曲线宽度（默认取终端宽度）")
    ap.add_argument("--summary", action="store_true",
                    help="跨会话受击归因汇总（调参仪表盘）")
    ap.add_argument("--frame", "-f", type=int, default=None, metavar="N",
                    help="渲染第 N 帧弹幕场快照（需级别4录制；matplotlib 出图，缺库时文本表格）")
    args = ap.parse_args()

    width = args.width
    if width is None:
        try:
            import shutil
            width = max(shutil.get_terminal_size().columns - 20, 60)
        except Exception:
            width = 80

    if args.file:
        p = Path(args.file)
        if not p.is_file():
            print(f"✗ 文件不存在: {p}")
            return 1
        return analyze(p, args.seconds, width, frame_target=args.frame)

    directory = Path(args.dir) if args.dir else Path(__file__).resolve().parent.parent / "recordings"
    if not directory.is_dir():
        print(f"✗ 目录不存在: {directory}")
        return 1
    rows = list_sessions(directory)
    if not rows:
        print(f"✗ 在 {directory} 中没有找到录制会话")
        return 1
    if args.summary:
        print_summary(rows)
        return 0
    if args.latest:
        return analyze(rows[0]["path"], args.seconds, width, frame_target=args.frame)  # glob 降序→首个最新
    print_session_list(rows)
    print("\n提示: python tools/replay_viewer.py <文件> 查看详情，--latest 直接分析最新会话，"
          "--summary 归因汇总，--frame N 弹幕场快照")
    return 0


if __name__ == "__main__":
    sys.exit(main())
