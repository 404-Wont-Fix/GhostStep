#!/usr/bin/env python3
"""
GhostStep3 工具箱 — 项目工具统一 CLI 入口

用法:
    python tools/gs.py              # 交互菜单（数字键选择）
    python tools/gs.py 1            # 直接: 录制回放分析器（列出会话）
    python tools/gs.py 1 --latest   # 直接: 录制回放分析器（分析最新会话）
    python tools/gs.py 2            # 直接: 生成动画数据库
    python tools/gs.py 3            # 直接: 运行冒烟测试
    python tools/gs.py 4                  # 直接: 部署到游戏目录
    python tools/gs.py 4 --sync           # 直接: 部署（不弹菜单，deploy.bat 用的就是这条）
    python tools/gs.py 4 --dry-run        # 直接: 预览会变化的文件（不写入）
    python tools/gs.py 5                  # 直接: 玩后一键报告（最新会话）
    python tools/gs.py 5 --sessions 3     # 直接: 最近 3 个会话
    python tools/gs.py 5 --dir <回放目录>  # 直接: 指定回放目录（默认自动找 Steam）
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path

# 项目根目录（tools/ 的上级）
PROJECT_ROOT = Path(__file__).resolve().parent.parent

# 游戏录制目录（Steam 默认安装路径）
GAME_RECORDINGS = Path(r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\GhostStep3\recordings")


def force_utf8():
    """强制 UTF-8 输出（Windows 控制台默认 GBK 会乱码）"""
    try:
        if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
            sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def read_choice(prompt="请选择> "):
    """读取用户输入，EOF 时返回 None（管道/非交互模式）"""
    try:
        return input(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        return None


def clear_screen():
    os.system("cls" if os.name == "nt" else "clear")


def pause(msg="按回车继续..."):
    try:
        input(f"\n{msg}")
    except (EOFError, KeyboardInterrupt):
        pass


def terminal_width():
    try:
        return shutil.get_terminal_size().columns
    except Exception:
        return 80


def recordings_dir():
    """返回可用的录制目录（优先游戏内目录，回退仓库目录）"""
    if GAME_RECORDINGS.is_dir():
        return GAME_RECORDINGS
    return PROJECT_ROOT / "recordings"


# =====================================================================
# 工具 1: 录制回放分析器
# =====================================================================

def tool_replay(args=None):
    script = PROJECT_ROOT / "tools" / "replay_viewer.py"
    if not script.exists():
        print(f"  ✗ 找不到 {script}")
        return 1

    if args:
        return subprocess.run([sys.executable, str(script)] + args).returncode

    while True:
        print("\n--- 录制回放分析器 ---")
        print("  1) 列出所有录制会话")
        print("  2) 分析最新会话")
        print("  3) 分析指定文件")
        print("  4) 跨会话受击归因汇总（调参仪表盘）")
        print("  5) 渲染弹幕场快照图（--frame N）")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            return subprocess.run([sys.executable, str(script), "--dir", str(recordings_dir())]).returncode
        elif choice == "2":
            return subprocess.run([sys.executable, str(script), "--dir", str(recordings_dir()), "--latest"]).returncode
        elif choice == "3":
            path = read_choice("  文件路径 (.jsonl)> ")
            if path:
                return subprocess.run([sys.executable, str(script), path.strip('"')]).returncode
        elif choice == "4":
            return subprocess.run([sys.executable, str(script), "--dir", str(recordings_dir()), "--summary"]).returncode
        elif choice == "5":
            path = read_choice("  文件路径 (.jsonl)> ")
            frame = read_choice("  帧号> ")
            if path and frame:
                return subprocess.run([sys.executable, str(script), path.strip('"'), "--frame", frame]).returncode
        else:
            print("  无效选项")


# =====================================================================
# 工具 2: 动画数据库生成器
# =====================================================================

def tool_animdb(args=None):
    script = PROJECT_ROOT / "tools" / "parse_animations.py"
    if not script.exists():
        print(f"  ✗ 找不到 {script}")
        return 1

    if args:
        return subprocess.run([sys.executable, str(script)] + args).returncode

    while True:
        print("\n--- 动画数据库生成器 ---")
        print("  1) 生成（仅高价值分类，自动检测 Steam 路径）")
        print("  2) 生成（全部分类，调试用）")
        print("  3) 指定资源目录生成")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            out = str(PROJECT_ROOT / "data" / "npc_animdb.lua")
            return subprocess.run([sys.executable, str(script), "--output", out]).returncode
        elif choice == "2":
            out = str(PROJECT_ROOT / "data" / "npc_animdb.lua")
            return subprocess.run([sys.executable, str(script), "--output", out, "--all-categories"]).returncode
        elif choice == "3":
            res = read_choice("  资源目录路径> ")
            out = str(PROJECT_ROOT / "data" / "npc_animdb.lua")
            if res:
                return subprocess.run([sys.executable, str(script), "--resource-dir", res.strip('"'), "--output", out]).returncode
        else:
            print("  无效选项")


# =====================================================================
# 工具 3: 冒烟测试
# =====================================================================

def tool_test(args=None):
    runner = PROJECT_ROOT / "tests" / "run_smoke.py"
    if not runner.exists():
        print(f"  ✗ 找不到 {runner}")
        return 1

    if args:
        return subprocess.run([sys.executable, str(runner)] + args, cwd=str(PROJECT_ROOT)).returncode

    while True:
        print("\n--- 冒烟测试 ---")
        print("  1) 运行全部测试")
        print("  2) 详细输出模式")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            return subprocess.run([sys.executable, str(runner)], cwd=str(PROJECT_ROOT)).returncode
        elif choice == "2":
            return subprocess.run([sys.executable, str(runner), "-v"], cwd=str(PROJECT_ROOT)).returncode
        else:
            print("  无效选项")


# =====================================================================
# 工具 4: 部署
# =====================================================================

# 同步排除清单：**唯一真相源**。deploy.bat 只是启动器，不再自己拼 robocopy 参数，
# 所以新增开发用文件（文档/工具/测试）只需要改这里一处。
ROBOCOPY_XD = ["tests", "recordings", "analysis", ".git", ".claude", "references", "tools"]
ROBOCOPY_XF = ["deploy.bat", ".gitignore", "ANALYSIS.md", "AGENTS.md"]
ROBOCOPY_QUIET = ["/NFL", "/NDL", "/NJH", "/NJS", "/NP"]

DEPLOY_DST = Path(r"D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\GhostStep3")


def deploy_command(extra=None, dry=False):
    """拼出 robocopy 命令（排除清单来自本模块的常量）
    dry=True 时保留 robocopy 自己的文件清单汇总（预览要看这个），只去掉进度刷屏；
    正常同步则全部静默（与旧 deploy.bat 的 >nul 行为一致）。"""
    cmd = ["robocopy", str(PROJECT_ROOT), str(DEPLOY_DST), "/MIR",
           "/XD"] + ROBOCOPY_XD + ["/XF"] + ROBOCOPY_XF
    if dry:
        cmd.extend(["/L", "/NP"])
    else:
        cmd.extend(ROBOCOPY_QUIET)
    if extra:
        cmd.extend(extra)
    return cmd


def tool_deploy(args=None):
    src = PROJECT_ROOT
    dst = DEPLOY_DST

    if not (src / "main.lua").exists():
        print(f"  ✗ 源目录不存在: {src}")
        return 16  # robocopy 风格的失败码（>=8），便于 deploy.bat 用 ERRORLEVEL 判定

    # 命令行模式: python tools/gs.py 4 [--sync] [--dry-run]
    #   --sync    直接部署（供 deploy.bat 调用，不弹菜单）
    #   --dry-run 只列出会变化的文件
    #   其余参数原样透传给 robocopy（例如 /L）
    if args is not None:
        flags = [a for a in args if a not in ("--sync", "--dry-run")]
        dry = ("--dry-run" in args) or ("/L" in flags)
        print(f"  源: {src}")
        print(f"  目标: {dst}")
        result = subprocess.run(deploy_command(flags, dry))
        rc = result.returncode
        ok = rc < 8   # robocopy: 0..7 均为成功（0=无变化，1=有文件复制...）
        if ok:
            print("  ✓ 镜像同步完成（镜像目录 = mods/GhostStep3）。游戏内按 Ctrl+R 重载 Lua。"
                  if not dry else "  （预览模式 /L：以上为将要变化的文件）")
        else:
            print(f"  ✗ robocopy 失败，错误码 {rc}")
        # 归一化退出码：成功→0（robocopy 的 0..7 会让 shell 的 && 误判），失败保留原码
        return 0 if ok else rc

    while True:
        print(f"\n--- 部署 ---")
        print(f"  源: {src}")
        print(f"  目标: {dst}")
        print()
        print("  1) 部署（镜像同步）")
        print("  2) 预览（只显示会改变的文件）")
        print("  0) 返回主菜单")

        choice = read_choice()
        if choice is None or choice == "0":
            return None
        elif choice == "1":
            result = subprocess.run(deploy_command())
            if result.returncode < 8:
                print("\n  ✓ 部署完成。游戏内按 Ctrl+R 重载 Lua。")
            else:
                print(f"\n  ✗ robocopy 失败，错误码 {result.returncode}")
            return result.returncode
        elif choice == "2":
            return subprocess.run(deploy_command(dry=True)).returncode
        else:
            print("  无效选项")


def tool_postplay(args=None):
    """玩后一键报告：挑最新会话 → 备份 → 抽轨迹 → 跳蛛/动画核对 → 回放诊断 → 摘要。

    真正的实现在 tools/post_play.py（也能单独跑），这里只做菜单封装与参数透传。
    """
    script = PROJECT_ROOT / "tools" / "post_play.py"
    if not script.exists():
        print(f"  ✗ 找不到 {script}")
        return 1

    if args:
        return subprocess.run([sys.executable, str(script)] + args, cwd=str(PROJECT_ROOT)).returncode

    while True:
        print("\n--- 玩后一键报告 ---")
        print("  1) 最新会话")
        print("  2) 最近 3 个会话")
        print(f"  3) 指定回放目录（默认 {GAME_RECORDINGS}）")
        print("  0) 返回主菜单")
        choice = read_choice()
        if choice in (None, "0"):
            return None
        if choice == "1":
            return subprocess.run([sys.executable, str(script)], cwd=str(PROJECT_ROOT)).returncode
        if choice == "2":
            return subprocess.run([sys.executable, str(script), "--sessions", "3"],
                                  cwd=str(PROJECT_ROOT)).returncode
        if choice == "3":
            path = read_choice("回放目录> ")
            if not path:
                continue
            return subprocess.run([sys.executable, str(script), "--dir", path.strip('"')],
                                  cwd=str(PROJECT_ROOT)).returncode
        print("  无效选项")


# =====================================================================
# 主菜单
# =====================================================================

TOOLS = [
    ("1", "录制回放分析器", "会话分析 / 归因汇总 / 弹幕场快照", tool_replay),
    ("2", "动画数据库生成器", "解析 anm2 → npc_animdb.lua", tool_animdb),
    ("3", "冒烟测试", "运行全部单元/集成测试", tool_test),
    ("4", "部署", "镜像同步到 Isaac mods 目录", tool_deploy),
    ("5", "玩后一键报告", "备份回放 + 跳蛛/动画核对 + 回放诊断", tool_postplay),
]


def print_banner():
    w = terminal_width()
    print("=" * min(w, 60))
    print("  GhostStep3 工具箱")
    print("=" * min(w, 60))


def print_menu():
    print()
    for num, name, desc, _ in TOOLS:
        print(f"  {num}) {name:<16s} {desc}")
    print(f"  0) 退出")
    print()


def main():
    force_utf8()

    # 直接调用: python tools/gs.py <工具编号> [参数...]
    if len(sys.argv) >= 2 and sys.argv[1].isdigit():
        tool_num = sys.argv[1]
        rest = sys.argv[2:]
        for num, _, _, fn in TOOLS:
            if num == tool_num:
                return fn(rest if rest else None)
        print(f"未知工具: {tool_num}")
        return 1

    # 交互模式
    while True:
        clear_screen()
        print_banner()
        print_menu()

        choice = read_choice()
        if choice is None or choice == "0":
            print("再见。")
            return 0

        matched = False
        for num, name, _, fn in TOOLS:
            if choice == num:
                matched = True
                result = fn()
                if result is not None:
                    pause()
                break

        if not matched:
            print("  无效选项")
            pause()


if __name__ == "__main__":
    sys.exit(main() or 0)
