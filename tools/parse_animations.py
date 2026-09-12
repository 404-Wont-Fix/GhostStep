#!/usr/bin/env python3
"""
parse_animations.py - Parse gfx/*.anm2 files and extract attack animation windup data.
Outputs Lua format animation database for GhostStep runtime dodge prediction.

Usage:
    python tools/parse_animations.py [--resource-dir DIR] [--output data/npc_animdb.lua]
                                     [--high-value-only]

Flags:
    --high-value-only   Only include categories used by GhostStep threat generation:
                        stomping, jumping, laser, ranged (exclude melee/charge/summon/etc.)
    --resource-dir      Path to Isaac resources/ directory containing gfx/*.anm2
    --output            Output Lua file path (default: data/npc_animdb.lua)
"""

import xml.etree.ElementTree as ET
import argparse
import os
import sys
import logging
import glob

logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

# Attack keyword -> category + estimated windup ratio
# windup_ratio: approximate fraction of total frames that is "windup" (pre-attack)
ATTACK_CATEGORIES = {
    "attack":     {"category": "melee",   "windup_ratio": 0.45},
    "shoot":      {"category": "ranged",  "windup_ratio": 0.40},
    "spit":       {"category": "ranged",  "windup_ratio": 0.40},
    "throw":      {"category": "ranged",  "windup_ratio": 0.40},
    "fire":       {"category": "ranged",  "windup_ratio": 0.35},
    "laser":      {"category": "laser",   "windup_ratio": 0.30},
    "brimstone":  {"category": "laser",   "windup_ratio": 0.35},
    "beam":       {"category": "laser",   "windup_ratio": 0.30},
    "charge":     {"category": "charge",  "windup_ratio": 0.50},
    "cast":       {"category": "cast",    "windup_ratio": 0.35},
    "summon":     {"category": "summon",  "windup_ratio": 0.50},
}

# Impact/landing categories
IMPACT_CATEGORIES = {
    "jumpdown": {"category": "falling",   "windup_ratio": 0.60},
    "stomp":    {"category": "stomping",  "windup_ratio": 0.50},
    "jump":     {"category": "jumping",   "windup_ratio": 0.50},
    "hop":      {"category": "hopping",   "windup_ratio": 0.45},
    "land":     {"category": "landing",   "windup_ratio": 0.60},
}

# Categories included in --high-value-only mode (GhostStep threat generation uses these)
# "hopping" 必须算高价值：跳蛛/跳跳尸的跳跃动画就叫 Hop（029.001_Trite.anm2：
# Hop 26 帧 / BigJumpUp 12 帧）。旧表只收 jumping，于是 29:0/29:1 在库里只有
# "BigJumpUp"，运行时精灵播的是 "Hop" → 查不到条目 → 动画预判整条链对跳蛛失效。
HIGH_VALUE_CATEGORIES = {"stomping", "jumping", "hopping", "laser", "ranged"}

# Ignore keywords (pure visual/movement animations)
IGNORE_KEYWORDS = [
    "walk", "idle", "appear", "death", "fade", "sleep",
    "taunt", "body", "head", "float", "spider", "burrow",
    "stairs", "hole", "pit", "pickup", "lose", "sad",
    "happy", "grunt", "ouch", "hit", "boss", "portrait",
]

# Substring-based ignore (safe visual/state keywords)
IGNORE_SUBSTRINGS = [
    "idle", "shopidle", "sleep", "death", "appear", "fade", "portrait",
    "nofire",  # "NoFire" is fire extinguishing, not attack ("fire" substring false match)
]

# Windup phase keywords (e.g. ShootBegin)
WINDUP_KEYWORDS = [
    "begin", "windup", "wind", "charge", "pre", "start",
    "ready", "aim", "pull", "back",
]

# Attack execution phase keywords (e.g. ShootLoop, ShootEnd)
ATTACK_PHASE_KEYWORDS = [
    "loop", "end", "fire", "release", "burst",
]

# ===== Manual additions =====
# Entity types missing from the game's anm2 data or filtered out by the parser,
# but known to have attack animations relevant to GhostStep.
# Format: { "id:variant": [ {name, totalFrames, windupFrames, category}, ... ] }
MANUAL_ADDITIONS = {
    "213:0": [
        # Mom's Hand - "JumpDown" is the stomp-landing attack animation
        {"name": "JumpDown", "total_frames": 18, "windup_frames": 11, "category": "jumping"},
    ],
    "287:0": [
        # Mom's Dead Hand - "JumpDown" is the stomp-landing attack animation
        # (category changed from "falling" to "jumping" for GhostStep threat model)
        {"name": "JumpDown", "total_frames": 18, "windup_frames": 11, "category": "jumping"},
    ],
    "246:0": [
        # Vis - Brimstone laser charge (the laser entity itself is type 7,
        # but the Vis NPC has the charging animation we detect)
        {"name": "Laser", "total_frames": 25, "windup_frames": 22, "category": "laser"},
    ],
    "12:0": [
        # Horf - "Attack" is a ranged projectile attack (old animdb miscategorized as melee)
        {"name": "Attack", "total_frames": 20, "windup_frames": 9, "category": "ranged"},
    ],
}


def keyword_match(name, lower, kw):
    """关键字必须**从词首**开始 —— 防止 "hop" 命中 "Shopkeeper" 这类假阳性。

    只看起点（camelCase/数字感知，所以要看未小写的原名）：
      * 名字开头
      * 前一字符不是字母（含数字：Shoot1、Hop2）
      * 前一字符小写而当前字符大写（BigJump、OldJumping、HeadShoot）
    末尾不做限制："Shooting"、"ShootAndRotate1"、"Jump2" 这类后缀/数字都算合法。
    "Shopkeeper" 里 "hop" 前是 "S" 且当前是小写 "h" → 不是词首 → 正确拒绝。
    """
    start = 0
    while True:
        i = lower.find(kw, start)
        if i < 0:
            return False
        if (i == 0 or not name[i - 1].isalpha()
                or (name[i - 1].islower() and name[i].isupper())
                or name[i].isdigit()):
            return True
        start = i + 1


def classify_animation(name):
    """Classify animation by name. Returns (category, windup_ratio, is_attack)."""
    lower = name.lower()

    # Check if should ignore
    for kw in IGNORE_KEYWORDS:
        if lower == kw or lower.startswith(kw + "_") or lower.endswith("_" + kw):
            return None, 0, False
    for kw in IGNORE_SUBSTRINGS:
        if keyword_match(name, lower, kw):
            return None, 0, False

    # Detect windup vs execution phase
    is_windup_phase = any(kw in lower for kw in WINDUP_KEYWORDS)
    is_attack_phase = any(kw in lower for kw in ATTACK_PHASE_KEYWORDS)

    # Attack category match
    for keyword, info in ATTACK_CATEGORIES.items():
        if keyword_match(name, lower, keyword):
            if is_windup_phase and not is_attack_phase:
                return info["category"], 1.0, True
            if is_attack_phase and not is_windup_phase:
                return info["category"], 0.0, True
            return info["category"], info["windup_ratio"], True

    # Impact category match
    for keyword, info in IMPACT_CATEGORIES.items():
        if keyword_match(name, lower, keyword):
            if is_windup_phase and not is_attack_phase:
                return info["category"], 1.0, True
            if is_attack_phase and not is_windup_phase:
                return info["category"], 0.0, True
            return info["category"], info["windup_ratio"], True

    return None, 0, False


def calculate_frame_delay(anim_elem):
    """Calculate total delay frames from RootAnimation Frame elements."""
    total = 0
    for frame in anim_elem.findall(".//RootAnimation/Frame"):
        delay = int(frame.get("Delay", 1))
        total += delay
    return total


def calculate_event_frame(anim_elem):
    """Find the frame where an attack trigger occurs (visibility change in NullAnimations)."""
    for null_anim in anim_elem.findall(".//NullAnimations/NullAnimation"):
        frames = null_anim.findall("Frame")
        for i, frame in enumerate(frames):
            visible = frame.get("Visible", "false").lower() == "true"
            if visible and i > 0:
                prev_visible = frames[i - 1].get("Visible", "false").lower() == "true"
                if not prev_visible:
                    delay_sum = 0
                    for j in range(i):
                        delay_sum += int(frames[j].get("Delay", 1))
                    return delay_sum
    return None


def parse_anm2(anm2_path):
    """Parse a single anm2 file, return list of animation dicts."""
    animations = []
    try:
        tree = ET.parse(anm2_path)
        root = tree.getroot()

        for anim in root.iter("Animation"):
            name = anim.get("Name", "")
            frame_num = int(anim.get("FrameNum", 0))
            loop = anim.get("Loop", "false").lower() == "true"

            total_delay = calculate_frame_delay(anim)
            effective_frames = max(frame_num, total_delay) if total_delay > 0 else frame_num

            event_frame = calculate_event_frame(anim)

            animations.append({
                "name": name,
                "frames": effective_frames,
                "frame_num": frame_num,
                "loop": loop,
                "event_frame": event_frame,
            })

    except ET.ParseError as e:
        logger.warning("XML parse error: %s - %s", anm2_path, e)
    except Exception as e:
        logger.warning("Parse error: %s - %s", anm2_path, e)

    return animations


def estimate_windup_frames(anim, category, windup_ratio):
    """Estimate windup frame count."""
    total = anim["frames"]

    # Use event trigger frame if detected
    if anim.get("event_frame") is not None and anim["event_frame"] > 0:
        return min(anim["event_frame"], total)

    # Otherwise use ratio estimate
    windup = max(1, int(total * windup_ratio))

    # Windup should not exceed total - 1 (at least 1 frame for attack execution)
    return min(windup, max(1, total - 1))


def extract_entity_id_from_filename(filename):
    """Extract entity ID:Variant from filename, e.g. '020.000_monstro.anm2' -> (20, 0)."""
    basename = os.path.splitext(os.path.basename(filename))[0]
    parts = basename.split("_", 1)
    if len(parts) < 1:
        return None, None

    id_parts = parts[0].split(".")
    try:
        entity_id = int(id_parts[0])
        variant = int(id_parts[1]) if len(id_parts) > 1 else 0
        return entity_id, variant
    except ValueError:
        return None, None


def parse_all_animations(resource_dir):
    """Parse all anm2 files, return attack animation database dict."""
    gfx_dir = os.path.join(resource_dir, "gfx")
    if not os.path.isdir(gfx_dir):
        logger.error("gfx directory not found: %s", gfx_dir)
        return {}

    anm2_files = glob.glob(os.path.join(gfx_dir, "**", "*.anm2"), recursive=True)
    logger.info("Found %d anm2 files", len(anm2_files))

    # 非敌方实体类型（友方/弹幕/拾取物/特效/环境道具）——无伤害或由其他传感器处理，
    # 进入动画数据库只会污染威胁场，必须排除
    SKIP_ENTITY_TYPES = {
        1,    # Player（玩家）
        2,    # Tear（泪弹）
        3,    # Familiar（跟班，友方）
        4,    # Bomb（玩家炸弹）
        5,    # Pickup（拾取物：金币/钥匙/宝箱等）
        6,    # Slot（老虎机/乞丐，无攻击动画）
        7,    # Laser/Projectile（弹幕/激光实体，由 projectile sensor 处理）
        8,    # Knife（玩家近战武器）
        9,    # Player（重复定义，部分版本用 9 代替 1）
        33,   # Fireplace（火堆，由 enemy sensor 半径放大特判处理）
        44,   # Slot/Beggar（老虎机/乞丐变体）
        1000, # Effect（特效：爆炸/水坑/粒子，由 effect sensor 处理）
    }

    database = {}
    total_attacks = 0

    for anm2_path in anm2_files:
        entity_id, variant = extract_entity_id_from_filename(anm2_path)
        if entity_id is None:
            continue
        if entity_id in SKIP_ENTITY_TYPES:
            continue

        animations = parse_anm2(anm2_path)
        attacks = []

        for anim in animations:
            category, windup_ratio, is_attack = classify_animation(anim["name"])
            if is_attack:
                windup = estimate_windup_frames(anim, category, windup_ratio)

                # Merge duplicate animations for same entity (take longer one)
                existing = None
                for a in attacks:
                    if a["name"] == anim["name"]:
                        existing = a
                        break

                if existing is not None:
                    if anim["frames"] > existing["total_frames"]:
                        existing["total_frames"] = anim["frames"]
                        existing["windup_frames"] = windup
                else:
                    attacks.append({
                        "name": anim["name"],
                        "total_frames": anim["frames"],
                        "windup_frames": windup,
                        "category": category,
                    })
                    total_attacks += 1

        if attacks:
            key = f"{entity_id}:{variant}"
            if key in database:
                existing_names = {a["name"] for a in database[key]}
                for a in attacks:
                    if a["name"] not in existing_names:
                        database[key].append(a)
            else:
                database[key] = attacks

    logger.info("Extracted %d attack animations covering %d entities", total_attacks, len(database))
    return database


def merge_manual_additions(database):
    """Merge manually defined entries (for entities missing from anm2 data)."""
    added = 0
    for key, entries in MANUAL_ADDITIONS.items():
        if key not in database:
            database[key] = []
            added += len(entries)
        else:
            existing_names = {a["name"] for a in database[key]}
            for entry in entries:
                if entry["name"] not in existing_names:
                    added += 1
                else:
                    # Replace (manual entry may have corrected category)
                    database[key] = [a for a in database[key] if a["name"] != entry["name"]]
                    added += 1
        for entry in entries:
            database[key].append(entry)
    logger.info("Merged %d manual additions", added)


def write_lua_database(database, output_path, high_value_only):
    """Write animation database as Lua file."""
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    # Filter to high-value categories if requested
    if high_value_only:
        filtered = {}
        for key, attacks in database.items():
            kept = [a for a in attacks if a["category"] in HIGH_VALUE_CATEGORIES]
            if kept:
                filtered[key] = kept
        database = filtered
        logger.info("After high-value filter: %d entities", len(database))

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- data/npc_animdb.lua\n")
        f.write("-- NPC attack animation database\n")
        f.write("-- Auto-generated by tools/parse_animations.py\n")
        f.write("-- Do not edit manually; re-run the script to regenerate.\n")
        f.write("--\n")
        f.write("-- Usage: local animDB = require(\"data/npc_animdb\")\n")
        f.write("--        local entry = animDB[\"213:0\"]\n\n")
        f.write("return {\n")

        for key in sorted(database.keys()):
            attacks = database[key]
            f.write(f'  ["{key}"] = {{\n')
            for a in attacks:
                f.write(f'    {{name="{a["name"]}", totalFrames={a["total_frames"]}, ')
                f.write(f'windupFrames={a["windup_frames"]}, ')
                f.write(f'category="{a["category"]}"}},\n')
            f.write("  },\n")

        f.write("}\n")

    # Stats
    total = sum(len(v) for v in database.values())
    logger.info("Written %d entries across %d entities to %s", total, len(database), output_path)


def main():
    parser = argparse.ArgumentParser(description="Parse gfx/*.anm2 to generate attack animation database")
    parser.add_argument("--resource-dir", default=None,
                        help="Path to Isaac resources/ directory (default: auto-detect Steam install)")
    parser.add_argument("--output", default="data/npc_animdb.lua",
                        help="Output Lua file path (default: data/npc_animdb.lua)")
    parser.add_argument("--high-value-only", action="store_true", default=True,
                        help="Only include stomping/jumping/laser/ranged categories (default: true)")
    parser.add_argument("--all-categories", action="store_true",
                        help="Include all categories (overrides --high-value-only)")
    args = parser.parse_args()

    if args.all_categories:
        args.high_value_only = False

    # Auto-detect Steam install path if not specified
    resource_dir = args.resource_dir
    if resource_dir is None:
        # Common Steam library paths (game packs resources into archives;
        # extracted_resources/ has the unpacked gfx/*.anm2 files)
        candidates = [
            r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\extracted_resources\resources",
            r"C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth\extracted_resources\resources",
            # Fallback: resources/ itself (some installs keep unpacked files here)
            r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\resources",
            r"C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth\resources",
        ]
        for path in candidates:
            if os.path.isdir(os.path.join(path, "gfx")):
                resource_dir = path
                break
        if resource_dir is None:
            logger.error("Could not auto-detect Isaac resources/ directory.")
            logger.error("Please specify --resource-dir explicitly.")
            sys.exit(1)

    logger.info("Resource dir: %s", resource_dir)

    database = parse_all_animations(resource_dir)
    merge_manual_additions(database)
    write_lua_database(database, args.output, args.high_value_only)


if __name__ == "__main__":
    main()
