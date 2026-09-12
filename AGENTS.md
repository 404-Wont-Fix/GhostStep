# AGENTS.md — GhostStep3（以撒的结合：忏悔+ / 预测式人机共驾避让）

> 给在本仓库工作的 AI 代理：先读完这份再动手。包含构建/测试/部署命令、目录职责、
> **10 条实测踩坑**、以及**已经验证过的设计决策（不要改回去）**。
> 所有结论都来自回放数据或离线复现，不要凭直觉推翻——先按第 8 节的口径复核。

---

## 1. 项目是什么

`RegisterMod("GhostStep3")`。玩法定位：**危险时在玩家输入上叠加偏移**，不接管视线/射击、
不锁死方向；ALT 键开关；全程录制回放 JSONL 供离线归因。

数据流：

```
sensors/*  →  main.lua getHazards(追踪器合并视图)  →  decision/predictive.lua  →  control/input_writer.lua
             (MC_POST_PLAYER_UPDATE)                  (候选滚动预测 + 代价评估)      (MC_INPUT_ACTION 输出)
```

`decision/pipeline.lua` 只调用 `Predictive.run`；`fallback / early_dodge / escape_lock /
direction_smooth / input_synthesizer / threat_level / spatial` **都是死代码**（0 处 require），
别以为它们在生效。

## 2. 常用命令

| 目的 | 命令 |
|---|---|
| 语法 + 行为 + 集成测试（需要 `pip install lupa`） | `python tests/run_smoke.py`（可加 `--lua 5.1/5.3`） |
| **部署到游戏**（镜像同步） | `python tools/gs.py 4`（`--dry-run` 预览；`--sync` 不弹菜单，供脚本调用）；双击 `deploy.bat` 等价于同一条命令 |
| 回放分析（中文 report.md/json + csv） | `python tools/analyze_replay.py <回放.jsonl> --output <目录>` |
| **玩后一条命令出全部报告**（备份最新回放 → 轨迹 → 跳蛛/动画核对 → 回放诊断 → 终端摘要） | `python tools/gs.py 5`（或 `5 --sessions 3` / `5 --dir <回放目录>`；等价于 `python tools/post_play.py`） |
| 单独核对跳跃预判（实测前摇/落点误差/节拍） | `python tools/analyze_hop.py <traces 目录>`（traces 由 `tools/extract_traces.py` 生成） |
| 回放可视化 | `python tools/replay_viewer.py --dir "<Steam>/mods/GhostStep3/recordings" --latest` |
| **用真实规划器离线复现回放场景** | `python tools/repro_planner.py`（真实网格 + 回放威胁） |
| **闭环运动复现**（逐帧重新决策 + 按 `maxDodgeWeight` 混合 + 运动模型积分，带 before/after 扫描） | `python tools/repro_fixes.py` |
| 生成 `config/build.lua` 指纹 | `python tools/package_mod.py` |

写代码前/后都跑一次测试：`run_smoke.py` 里有 5 条避让行为回归（ALT 键值、门格豁免、
地刺软代价、输入混合、地刺环+炸弹不得冻死）。

## 3. 目录职责（改哪里）

| 路径 | 职责 |
|---|---|
| `main.lua` | 装配、回调、ALT 开关、录制启动、`getHazards()` 合并视图、诊断事件 |
| `config/defaults.lua` | **所有阈值/魔数的唯一来源**（改行为先改这里） |
| `config/mcm.lua` | MCM 菜单注册、持久化（存档）、副作用（灵敏度联动） |
| `config/runtime.lua` | 运行时状态容器（`state`），`suspendThreat` / `isDodgeActive` |
| `sensors/*` | 采集威胁进追踪器：projectiles / enemies(含火堆) / lasers / bombs / effects / npc_attacks / terrain / player |
| `threat/geometry.lua` | 时空几何：`prepare` 缓存、`clearance`、`reachable`、`window` |
| `threat/future_motion.lua` | 按 kind 外推未来位置（弧线/抛物线/追踪/激光线段） |
| `decision/predictive.lua` | 候选生成 + 滚动预测 + 代价/风险评估 + 选择（**核心**） |
| `control/input_writer.lua` | `MC_INPUT_ACTION` 输出层，按 `blendWeight` 与玩家输入混合 |
| `recording/*` | 有界 JSONL 录制（快照/事件/环形缓冲/死亡回放） |
| `tools/*` | 离线分析工具（**不参与打包**，deploy 时排除） |
| `tests/*` | lupa 上的 mock 环境 + 行为回归（**不部署**） |

## 4. 硬约定

1. **不硬编码本机路径**（用户明确要求）。运行时数据只写 `recordings/`（用 `metadata.xml` 向上定位 mod 根目录）。
2. 离线工具放 `tools/`、测试放 `tests/`——两者都不会被部署同步进游戏。
   `analysis/` 是离线分析产物目录（已在 `.git/info/exclude` 里忽略），同样不部署。
   **部署的排除清单只写在 `tools/gs.py` 的 `ROBOCOPY_XD` / `ROBOCOPY_XF`**（唯一真相源）；
   `deploy.bat` 只是启动器，不要再往 bat 里加 robocopy 参数（历史上有过两份清单走偏的 bug —— 同一
   `AGENTS.md` 只加进 bat 没加进 Python，于是用 Python 工具同步时又被复制进游戏目录）。
3. 新增可调参数：先加进 `config/defaults.lua` 并写注释说明依据；需要现场调的再加进 `config/mcm.lua` 的 `SETTINGS`。
4. 所有 entity 字段/方法访问用 `pcall` 包（Rep+ 上 API 可能缺失，缺了要静默降级而不是崩）。
5. 改动决策层后必须跑 `tests/run_smoke.py`，并尽量在 `tests/shared_control.lua` 补一条能复现旧 bug 的回归。
6. 提交信息用中文 conventional-commits 风格（`fix:` / `feat:` / `refactor(模块):`），正文写清根因与证据。

## 5. 必读的坑（全是实测，别再踩）

1. **`Keyboard` 枚举是 GLFW 键码，不是顺序索引**。左Alt=**342**、空格=32、A=65、F1=290；`56` 是数字键 8。
   查表用游戏自带 `<游戏目录>/resources/scripts/enums.lua`。MCM 的 `KEYBIND_KEYBOARD` 扫 32..400 所以手绑没问题，
   **只有硬写的默认值会错**（历史上的 `toggleKey=56` 就是这么来的，导致按 Alt 从未生效过，回放里 `toggle` 事件数为 0）。
2. **`Entity.Size` 就是像素半径**：玩家 10、Gaper 13、火堆 ≈16.25、石块 ≈5。旧笔记"火焰范围 >> Size"是误判。
   （`entities2.xml` 的 `collisionRadius=13` 是**伤害半径**不是 `Entity.Size`：旧代码 `max(Size*2.0, 30)` 在回放里
   录到恒为 **32.5** → Size = 32.5/2 = 16.25；录到过 30 的那些才是被 MIN 钳死的，别再把 30 当成 Size。）
3. **`Room:GetGridPosition(i)` 返回格中心**，`Terrain.build` 再 `-Vector(20,20)` 才是 topLeft。
   离线造 room mock 必须按格中心给坐标，否则整张网格平移 20px，复现结果全错（踩过）。
4. **`Isaac.GetTime()` 只有 1ms 精度**。`deadline=begin+budgetMs` 实际是"跨过一个毫秒刻度就中止"，
   帧 18610 的搜索就是这样被掐断在最后一个候选之前。预算判定不要指望它精确。
5. **判断"避让范围过大"要算有效禁入半径**：`hazard.radius + player.radius + safetyMargin` 与 **40px 格距**比。
   >40 就会连相邻格一起封死（火堆 30+10+1.5=41.5 正是用户反馈"范围有点大"的原因）。
6. **`max(Size*scale, MIN)` 里 MIN 常把 scale 钳死** → 调 scale 是空改。火堆 2.5→2.0→1.6 三次调整里后两次完全无效。
   同理：`spikeCost` 之类挂在 `blocked` 提前返回之后的项，等于死代码。
7. **回放 `ioPaused` 会丢快照**：慢写盘（>8ms）后只保留关键事件 + 最近一小段普通快照——
   会话 28 的 66000+ 帧只剩 **40 条**快照，但 387 条 terrain / 552 条 avoidance 事件都在。
   分析前先看 `recording_io_paused` / `recordIoPaused` 字段，别以为"没数据"。
8. **飞行角色不能只豁免 OBJECT/PIT**：`walkable` 若把 `COLLISION_SOLID`(3) 也算墙，飞行时飞到石头上方
   就会被 `probe` 判成"在墙里 10~30px"，规划器于是拼命把玩家推离石头（会话 20260911_205153 的 101 个
   接管帧 100% 是 terrain 触发、0 个真实威胁，12 帧输出与玩家输入完全反向）。
   飞行例外按 wiki/Flight 同步：挡路的只剩房间墙 `COLLISION_WALL`(4) 和**柱子 `GRID_PILLAR`(24)**
   （Rep+ 明确不能飞过柱子）；地刺对飞行免疫，但**尖刺岩石仍伤害飞行角色** → 飞行时也算软危险；
   TNT 飞行时降级为软危险（不当硬墙把玩家推开）。比较 `GRID_PILLAR` 前必须排除 0
   （mock 的枚举 metatable 把未定义枚举当 0，否则会误伤所有空格；`tests/smoke.lua` 现已对齐真机枚举）。

9. **规划器必须评估"实际会执行的方向"**：`input_writer` 输出的是 `(1-w)*玩家 + w*AI`，只验证 AI 原始
   方向会让"验证过的安全方向"被剩余 15% 玩家输入拉回威胁（闭环复现：按住"右"冲向火堆，规划器选
   `(0.71,0.71)` 判安全，实际输出 `(0.75,0.60)` 仍是朝火堆推进，35% 的随机位姿会撞上）。

11. **玩家"贴着墙/贴着石头"时必然被算出 0.5~1.2px 假穿透**：引擎让玩家中心最近只到
    距实心格 **9.2px**，而 `player.radius=10` → 足印重叠 0.6px；`IsPositionInRoom(p,r)` 在可走区
    边界处又恒返 false 再加 1px。后果有两层：① 贴墙走就拿不到 `nominal_safe`、`triggerKind`
    永远显示 terrain（会话 220104 的 555 段避让里 **327 段**是这种假触发，占 59%）；
    ② `peakDepth*10` 让"按向墙"的 base 风险凭空高几十，规划器会把贴墙走的玩家**推离墙**
    （离线复现：10 个贴墙位姿旧代码 6 次接管、6 次全推离接触面 → 现在 0 次）。
    更隐蔽的是 `depth>0` 会短路"撞墙位置钉住"，模型在墙附近会把候选路径直接开进石头里。
    → `config.wallContactSlack`（默认 2.0px）把小于裕量的硬穿透当 0；软危险（地刺）不动。
12. **地面液体的敌我要按 variant + 生成者链判**：`EffectVariant.PLAYER_CREEP_*`（32/37/44/45/46/
    53/54/78/90/92）是游戏专为玩家侧 creep 定义的枚举，它们的 `SpawnerType/SpawnerEntity`
    常为 0/nil → 只按生成者链判会把玩家自己的水迹当敌方（用户 2026-09-11 反馈"分不清敌我
    地面液体"；离线复现：旧代码采集到 4 条含玩家/友方水迹 → 现在 2 条）。友方化 NPC
    （Friend Ball/魅惑）生成的水迹要查 `FLAG_FRIENDLY`。飞行时地面液体一律免疫（wiki/Flight），
    但**火堆仍然伤害飞行角色**（别顺手一起豁免）。

13. **tracker 历史里会出现"同一位置记进相邻两帧"的脏样本**（mod 回调频率高于游戏逻辑
    更新频率）→ 二阶差分看起来像每帧 ±5px 的巨大加速度 → `isParabolic` 命中，抛物线模型
    （0.5·a·t²）把**直线弹幕的轨迹掰向反方向**，规划器判"无威胁"，玩家贴脸挨打。
    回放 220104 受击2 就是实例（弹幕 vel=(0.36,-4.99) 直线上升，t=1 预测 y 反而 +2.5）。
    → `Tracker.motionConsistent()`：最近一步位移要与实体自报速度同量级（0.5~3 倍），
    否则 `isCurved/isTracking/isParabolic/timeToHit{Arc,Parabolic}` 与
    `future_motion.getArcParams` 全部退回直线外推。**别把采样间隔当逻辑帧数用**
    （同一逻辑帧可能被采集两次，`dt` 不可靠；只有实体自报的 `vel` 可信）。

10. **离线复现是杀手锏**：`python tools/repro_planner.py` 用 lupa 加载 `tests/smoke.lua` 的 Isaac mock +
   回放里**真实的房间网格**（terrain 事件的 cells），**直接跑改后的 `decision/predictive.lua`**。
   比人肉推理可靠。注意 mock 里的枚举现在已对齐真机（`tests/smoke.lua`）；若自己搭 mock 仍要注意
   `GridCollisionClass` = NONE 0 / PIT 1 / OBJECT 2 / SOLID 3 / WALL 4 / **WALL_EXCEPT_PLAYER 5**；
   `GridEntityType` = SPIKES 8 / SPIKES_ONOFF 9 / TNT 12 / **FIREPLACE 13（Rep+ 未使用，火堆是实体 33）** /
   DOOR 16 / **PILLAR 24** / ROCK_SPIKED 25。

14. **动画库（`data/npc_animdb.lua`）不是“有就万事大吉”**：它由 `tools/parse_animations.py`
    生成、唯一的老消费者是 `sensors/npc_attacks.lua`（把“type:variant + 当前动画名”映射成
    前摇/总帧数 → 再查 `data/npc_profiles.lua` 的类别形状 → `kind=npc_attack` 威胁）。
    实测覆盖很窄（三个会话：有 npc_attack 威胁的帧仅 **1.9%**、`forecast_match` 40 次、
    89 次受击里只有 1 次以它为触发）。两个典型洞：
    * **`hopping` 分类被 `--high-value-only` 过滤掉**：跳蛛/跳跳尸的跳跃动画叫 `Hop`
      （`029.001_Trite.anm2`），旧库里 `29:1` 只有 `BigJumpUp` → 运行时精灵播 `Hop`，
      库里查不到 → 整条链对跳蛛失效（现已把 `hopping` 加入 `HIGH_VALUE_CATEGORIES` 并重生成）。
    * **类别没有形状也不会生成威胁**（`buildEntry` 里 `if not profile then return nil`）：
      即使匹配上 `hopping`，`npc_profiles` 里也没这个 key → 不会造威胁。
    另：库里 `windupFrames` 是按关键字给的**启发值**（`windup_ratio`），不是实测；
    跳敏链现在改为实测“动画第几帧开始位移”（`hopWindup`），并在动画名带攻击关键字
    但库里查不到时打一条“动画库缺条目”日志（`NpcAttackSensor.resetRoom()` 按房间复位）。
    还有一类根本无解：`085.000_spider.anm2` 只有 `Idle/Walk/Appear/Death`，
    没有 Hop 动画——普通蜘蛛的“跳”是位置突变，只能靠速度/位移信号。

## 6. 已验证的设计决策（不要"修回去"）

| 决策 | 依据 |
|---|---|
| **地刺 = 可穿行 + 代价**（接触 55 + 停留 0.5/帧），不是硬墙 | 硬墙时咒术房地刺环+炸弹会让 18 个候选中 17 个 `terrainRejected`，唯一合法候选是零向量 → 玩家被钉死 5 秒（帧 18463–18609）|
| **玩家有输入时绝不输出零向量**（"停止"退化为混合后的轻微刹车） | 全回放 9246 个接管帧里 1405 帧(15.2%) 输出全零 = 玩家四个轴全被压死 |
| **输出是与玩家输入混合**（`out=(1-w)*玩家 + w*AI`，`w≤maxDodgeWeight`），不是 100% 替换 | 旧实现下 71% 的接管帧方向与玩家输入夹角 >45%，就是"抢操作" |
| **门格豁免**（`collision=WALL_EXCEPT_PLAYER` 或 `GetDoor(slot).Position` 所在格不算墙） | 旧实现用格锚点判 `IsPositionInRoom`，门格被判成墙（5167 格次）；玩家在门洞里被算成"在墙里 18px"，规划器整体失效（15 个受击快照里 9 个处于该状态） |
| **穿透按窗口内最深值扣分**，起点在硬地形内时不逐帧否决 | 所有候选共享同一初速度、第一帧位置相同；旧的"下一帧更深 0.01 即 blocked"会让全部候选同帧全灭 |
| **撞墙位置钉住 + 速度清零** | 长窗口（30 帧）按 6px/帧能跑 180px，而房间半高只有 140px → 否则纵向躲避会被远处的墙全判死 |
| **火堆危险半径 = 实体自身 `Size`**（MIN 12 仅兜底） | 与其他传感器一致；膨胀会封死相邻格（见坑 6） |
| **风险平手阈值 `riskTieEpsilon=5`**（差不超过它就按"更贴合玩家意图"选） | 旧值 0.05 太严：3.44 的边际收益就能把方向翻到意图反面（房间 36：按左→输出 (0.96,-0.29)） |
| **候选顺序**：旧命令(防抖) → 几何解 → 按玩家意图接近度排序的 8 方向 → 短脉冲 → 停住 | 旧的"几何解最前"让 60% 的接管只比了 1~3 个候选；但几何解不能推到最后，否则截断时连撤离方向都没算 |
| **大范围威胁（bomb/laser/半径≥32）动态扩窗 18→30 帧** | 18 帧 ≈ 73px 位移，跑不出 90px 爆圈 → 模型永远看不到可行解 |
| **ALT = 按一下切换**（`Input.IsButtonPressed` + 软件边缘检测） | `IsButtonTriggered` 在 `MC_POST_PLAYER_UPDATE` 不可靠；`tests/integration.lua` 就断言这个语义 |
| **机关（石像射手 Type 202）走廊**：半宽 8、长度按实际到墙距离、只在蓄力期生效 | 旧值半宽 22 + 固定长 160 → 离射线 34px 就判危险，把"从机关前经过"整条封死 |
| **飞行只挡房间墙与柱子**（SOLID/PIT/OBJECT 可飞越；地刺免疫、尖刺岩石仍伤害、TNT 降为软危险） | 闭环复现 48 例：旧代码 15 次"把飞行玩家推离石头"，新 0 次；步行对照 2/6 不变 |
| **火堆 = 方形危险体**（半边长 = MAX(Size,16)，角伸到 22.6） | 内切圆漏掉 4 个角（差 5px）→ "往火堆斜上方/斜下方躲却碰上"；随机位姿闭环：碰火 70/200 → **0/200** |
| **候选按"混合后的实际输出"评估** | 只验证 AI 原始方向时，15% 的玩家输入会把安全方向拉回威胁（斜向擦边 35% 撞上） |
| **脏轨迹样本不参与高阶拟合**（`Tracker.motionConsistent`） | mod 回调可能比游戏逻辑更新更快 → 同一位置进相邻两帧 → 抛物线拟合把直线弹幕掰成掉头（复现：`isParabolic=true`、规划器 `nominal_safe`；修后直线外推 + `reduce_exposure`） |
| **贴墙接触不算穿透**（`wallContactSlack=2.0`，只作用于硬地形） | 引擎允许玩家中心贴到距实心格 9.2px，`radius=10` → 贴墙恒有 0.6px 假穿透；抹掉后贴墙不再被推开、钉子逻辑在墙边恢复工作 |
| **冰雕像（EntityType 963 / ENTITY_FROZEN_ENEMY）不算威胁** | entities2.xml id=963 name="Frozen Enemy" `collisionDamage=0`：撞上去不扣血、玩家走进去把它踢滑（Uranus/Ice Cube 的冰雕），它只挡敌人子弹。用户 2026-09-12 反馈"冰冻住的敌人推不动、还触发避让" |
| **跳跃型敌人（Trite=跳蛛=29:1）用"节奏 + 动画前摇 + 瞄准落点"预判，不靠直线外推** | wiki/Trite："spider variant of the Hoppers. Leaps with less frequency, but at greater distances"；用户实测跳距随玩家距离、直线朝玩家、节奏固定。闭环 A/B（`tests/shared_control.lua`）：同样 200 帧、同样 PRNG，旧的首线外推被踩 5 次，新的 0 次 |
| **跳蛛的落点用"瞄准玩家"模型，不用 `npc_attacks` 的 `pos+vel*0.75*前摇`** | 后者在前摇时 vel≈0（跳蛛是朝玩家跳的）→ 算出来的落点就是它自己站着的位置，等于没用。正确分工：**动画（Hop 26 帧）管"要打了 + 前摇多久"，瞄准模型管"落在哪"**；跳蛛类型因此在 `npc_attacks` 里直接跳过，不重复建模 |
| **轨迹高阶模型（弧线/抛物线/追踪）改用"去重样本"，不再一刀切禁用** | mod 回调频率可高于逻辑帧 → 同一位置进相邻两帧。旧的 `motionConsistent` 看"最近两步"，一遇到重复样本就把弧线/抛物线/追踪全关掉（环形旋转弹幕因此退回直线外推）。改成去重后再校验"量级 + 方向"，并在剔除后仍有 ≥3 个不同位置时才做高阶拟合 |
| **玩家/友方地面液体永不算威胁**（`PLAYER_CREEP_*` + `FLAG_FRIENDLY` 链） | 这些 variant 的生成者常为空 → 旧实现把自己的水迹当敌方避让（复现 4 条 → 2 条） |
| **飞行免疫地面液体/地刺/TNT，但仍受火堆与尖刺岩石伤害** | wiki/Flight + wiki/TNT（TNT 只在被摧毁时爆炸）；飞行时 TNT 不再当危险 |
| **近失（擦边）只在平手时优先，且要差 ≥2 分才改写** | 擦边 2px 与从容 20px 同 risk → 平手按"贴近意图"选 → 选擦边；但阈值太小会为 0.1px 裕量把方向掰到意图外 |

## 7. 已知未修 / 下一步

1. **炸弹引信读不到**：`sensors/bombs.lua` 的 `ExplosionCountdown` 在回放里 408/408 全 nil
   （`confidence` 恒 0.3）→ `threat/geometry.lua` 的 `window()` 返回 `(0, math.huge)`，
   爆圈被当成"立刻且永久"。后果：从 ~172px 外就开始避让、且不会"炸完再回去"。
   （**与"被冻住"无关**，那是零向量 + 地刺硬墙导致的。）
2. **搜索仍可能被预算截断**：约 96 checks/ms，`budgetMs=5` ≈ 480 checks；而 19 候选 × 3 威胁 × 30 帧 ≈ 1700。
   候选顺序已保证先比重要的。彻底解决需要"廉价预排序 → 只对前几名做全量评估"的两段式重构。
3. **无时序规划**：候选是"整段固定方向"，不会"等弹幕过去再走"。机关走廊靠"缩窄 + 只在蓄力期"缓解。
4. `minHoldFrames` / `input_synthesizer` / `escape_lock` **不是**解决卡手的正确方向
   （混合已在 `input_writer` 内实现；保持时长会加重抢操作）。别再接入它们。
5. **环形/旋转弹幕（用户 2026-09-12 反馈 #2）现状只能算"部分改善"**：
   * 回放证据（session_20260912_000434，detail4 逐帧）：**没有一条弹幕在曲线飞行**（58 条轨迹最大每帧转角 < 10°），
     但存在"同一发射点、方向均分"的扇形/环形弹幕（room 83 帧 71091 起 4 发 90° 均分；room 97 帧 105702
     6 发 60° 均分、速度 12px/帧）。所以这不是"弹道弯了"，而是**多弹幕 + 时机**问题。
   * 实测那两例受击时的情形：玩家离发射点只有 **31.6px**、弹幕 12px/帧 → 2~3 帧内就穿身，
     规划器判 `reduce_exposure`/`no_improving_action`（不是选错方向，是**来不及**）；
     并且 `metrics.complete=false`、`checks=1056` ≈ 预算上限 → 稠密场景下**搜索被预算截断**（19 个候选只算了 10 个）。
   * 因此下一步要动的是：①让规划器更早意识到"站在环形发射者旁边"危险（发射者前摇/环形的预判）；
     ②**两段式搜索**（廉价预排序 → 只对前几名做全量评估）把稠密场景的覆盖补回来。
     单纯的弧线拟合在这两例里帮不上（弹道本来是直的）。

## 8. 回放数据与复核口径

**真实录制**：`D:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth\mods\GhostStep3\recordings\`
（种子是数字，`detail=3/4`）。仓库里的 `recordings/` 只是 `run_smoke.py` 的桩（种子 "ABCD 1234"），**无分析价值**。

拿到新回放先看这几项：

| 指标 | 期望 |
|---|---|
| `toggle` 事件 | 按 ALT 时应出现（历史记录 54 个会话全是 0） |
| 接管帧里零向量占比 | 接近 0（历史 15.2%） |
| `metrics.zeroBrakeReplaced` | 偶尔出现（说明有帧拦下了刹车） |
| `metrics.initialPenetration` | 绝大多数应为 0（门格不再假阳性） |
| `metrics.triggerKind` | 应开始出现 `spike` |
| `metrics.complete` 占比 | 应明显高于历史 22%（预算 1.5→5ms 后） |
| `perfPrevious.totalMs` | 中位 4~7ms；明显偏高就回调 `budgetMs` |
| **`avoidance_start` 里 terrain 占比** | 应大幅低于 59%（会话 220104 的量级）；仍高就检查 `wallContactSlack` 与 rooms 的 IsPositionInRoom |
| **每千帧避让段数** | 历史 7~13；贴墙假触发修掉后应明显回落（少插手） |
| **`avoidance_start` 里 effect 占比** | 若仍有玩家/友方水迹（看着是自己踩出来的液体）→ 查 `PLAYER_CREEP_*` 与 `FLAG_FRIENDLY` 链 |
| **`metrics.triggerKind` 出现 `hop`** | 说明跳蛛预判在生效；`detail=4` 快照里 `hopOn/hopIn/hopFlight/hopLX/hopLY` 可直接核对节奏与落点 |
| **敌人采集日志里不再出现 963** | 冰雕像（Frozen Enemy）应完全不被采集；若仍在，查 `skipFrozenStatues` |
| **`anim_gaps.csv` / 报告“动画库缺条目”** | 精灵在播攻击类动画但动画库里没条目 → 这就是动画预判覆盖不到的敌人；按 type/variant/动画 排序补 `tools/parse_animations.py` 的关键字或高价值分类 |
| **`hop_measured.csv` / 报告“跳跃型敌人实测”** | 跳蛛等的实测前摇/滞空/跳距/间隔/朝向误差。判断标准：**实测前摇 ≈ 库里的启发值**说明动画信号可用；**≈0** 说明该动画没有前摇（动画只能提前 1~2 帧，主力靠节拍模型）；朝向误差 >75° 会被自动放弃瞄准预测 |

## 9. 修复历史（近期，含根因与证据）

### 2026-09-12 夜 — 冰雕像误判、跳蛛（Trite）预判、脏样本不再关掉高阶轨迹模型

用户微信反馈 3 条（先复制日志 → 再分析 `analysis/20260912_pre_play/`）：

| 反馈 | 根因 | 证据 / 复现 |
|---|---|---|
| ① 被冰冻住的敌人推不动、还触发避让 | `sensors/enemies.lua` 把所有 NPC 当接触威胁；冰雕像 `Type=963`（entities2.xml `Frozen Enemy`）本无接触伤害（`collisionDamage=0`，玩家可踢走），却因为 `CollisionDamage or 1` 的兵底变成了“会伤害的敌人” | `entities2.xml` id=963；回归 `frozen statue (ENTITY_FROZEN_ENEMY 963) is not a contact threat`（关掉豁免必须重现旧行为） |
| ② 环形旋转弹幕（像卫星）躲得差 | 不是“弹道弯了”：逐帧 detail4 追迹里 58 条弹幕**没有一条在曲线飞行**（最大每帧转角 <10°）；真实情形是**多发射 + 时机**：受击时玩家离发射点只有 31.6px、弹幕 12px/帧（2~3 帧穿身），且稠密场景下 `complete=false / checks=1056`（19 候选只算了 10 个）。已做：高阶轨迹模型不再因重复样本被整体关掉（见下行）；未做：发射者/环形的提前预警、两段式搜索（见第 7 节） | 见第 7 节第 5 条 |
| ③ 跳蛛（Trite）容易被踩 | 待机时自报速度≈ 0 → 规划器只看到“一个不动的敌人”，`nominal_safe` 不介入；等到腾空（8~10px/帧）发现时只剩 3~4 帧 → 所有候选都负余量（`no_improving_action`），玩家被硬控 | 回放 20260912_221214 帧 47884（enemy:4 r=13 跳距 8.32px/帧、19 个候选全部 -8.9~-13.7）；闭环 A/B：旧 5 次被踩、新 0 次 |

改动：
- `sensors/enemies.lua`：`Type==963` 直接跳过（`skipFrozenStatues` 可关掉对照）；新增跳跃型敌人观测链
  （`hopTypes = {29 Hopper/Trite/Eggy, 34 Leaper, 54 Flaming Hopper, 85 Spider, 215 Spider_L2}`，
  只有“显著跳跃”（净位移 ≥ 30px）才计入节拍）
- `entities/hop_tracker.lua`（新）：用**实体自报速度**判腾空（位置差分会被“同一位置进相邻两帧”毁掉）→
  量起跳间隔/滞空/跳距/是否瞄准玩家 → 预测下一次起跳与落点（落点 = 玩家在起跳那一刻的位置，
  跳距 clamp 到 [30,340]）；随机的侧向跳鼠（平均夹角 >75°）不做预测
- `threat/future_motion.lua`：`kind=enemy` 且 `hopOn` 时按“待机 → 直线跳到落点 → 停住”外推
- `threat/geometry.lua`：跳蛛不进线性快路径（`c.linear=false`）；`reachable` 用跳距扩展
- `decision/predictive.lua`：有跳跃威胁时把窗口撑到“起跳+滞空+2”（否则落点永远在窗口外）；
  `triggerKind="hop"` 便于回放归因
- `entities/tracker.lua` + `threat/projectile_predict.lua` + `threat/future_motion.lua`：
  新增 `distinctSamples()`（去重采样）；`motionConsistent` 改成“去重后校验量级+方向”；
  弧线/抛物线/追踪改用去重样本 → 不再因为一次重复采样就把高阶模型全部关掉
- `config/defaults.lua`：`skipFrozenStatues` / `hop*` 一组参数
- `recording/snapshot.lua`：detail4 快照记 `hopOn/hopIn/hopFlight/hopLX/hopLY/hopLen/hopPeriod/hopAimErr`
- 测试：`tests/shared_control.lua` 新增 7 条（冰雕像 / 环形弹幕去重后仍判弧线 /
  节拍学习 + 落点 / 侧向跳不误报 / 规划器提前躲 + 闭环 A/B / 动画前摇预警 / 规划器响应预警），
  Lua 5.1+5.3 全绿（SHARED CONTROL 51 passed）

补充（同一晚，用户追问“动画库到底有没有用”）：
- 查清 `data/npc_animdb.lua` 的真实效果与洞（见第 5 节第 14 条）：**1.9% 帧、40 次
  `forecast_match`、89 次受击 1 次**；跳蛛的 `Hop` 动画被 `--high-value-only` 过滤掉了。
- 把 `hopping` 加入 `HIGH_VALUE_CATEGORIES` 并用参考资源重生成库（+76 行，纯新增）：
  `29:1 Trite = Hop 26 帧`、`29:2/29:3/34/54/76/246/303/305/810/840/872/884` 等补齐 Hop。
- `sensors/npc_attacks.lua`：跳蛛类型交给 hop 链（不再用 `pos+vel*0.75*前摇` 的空落点模型）；
  新增“动画名带攻击关键字但库里无条目”的缺库日志，按房间复位。
- `entities/hop_tracker.lua`：接入**精灵动画信号**（`config.hopAnimSignal` + `hopAnimKeywords`）——
  动画在播但还没位移（前摇段）就能预警（不再只靠学节奏，冷启动也好了一半），
  并用实测“动画第几帧开始位移”覆盖库里的启发前摇；`recording/snapshot.lua` 记
  `hopAnim/hopAnimFrame/hopWindup` 供回放校准。

### 6f0a1c1 之后 — 贴墙假穿透、敌我地面液体分辨、飞行地面免疫（2026-09-11 夜）

用户微信反馈：① 分不清敌方/友方单位的地面液体；② 躲避手感倒退了；③ 飞行时地刺/地面液体应无效。
用 `tools/repro_fixes.py`（闭环复现）`git stash` 前后各跑一次定位，根因与数据：

| 反馈 | 根因 | 前后对比（同 PRNG） |
|---|---|---|
| 手感倒退 / 爱插手 | 玩家贴墙走时恒有 0.5~1.2px **假穿透**（引擎让中心贴到距实心格 9.2px，`radius=10`），`peakDepth*10` 把玩家推离墙；会话 220104 的 555 段避让里 **327 段（59%）是这个假触发** | 贴墙/贴石 10 个位姿：接管 6 → **0**（旧代码 6 次全部推离接触面） |
| 敌我地面液体 | `PLAYER_CREEP_*`（玩家侧 creep 枚举）生成者常为 0/nil，只按生成者链判归属 → 自己的水迹被当敌方；友方 NPC 水迹同理 | 采集 4 条（含玩家/友方）→ **2 条**（只留敌方/敌对 NPC 生成） |
| 飞行仍避让地面液体 | `immuneGround` 只覆盖 `CREEP_VARIANTS`，玩家侧 creep 不在表里 | 飞行采集 1 → **0**；火堆仍采集 ✅ |

第三条根因（本轮最后定位，直接对应"躲避不好用"）：**tracker 脏样本把直线弹幕预测成掉头**。
mod 回调频率可高于游戏逻辑更新频率 → 历史里同一位置进相邻两帧 → 二阶差分像巨大减速 →
`isParabolic` 命中 → 轨迹被掰向反方向 → 规划器判"无威胁"（19 个受击里 8 个 `nominal_safe`）。
修：`Tracker.motionConsistent()` 用实体自报速度校验最近一步位移，不过关的退回直线外推；
`isCurved/isTracking/isParabolic/timeToHit{Arc,Parabolic}` 与 `future_motion.getArcParams` 同步接入。
复现（回放 220104 受击2 真实数据）：旧 `isParabolic=true`、t=1 预测 y 反向、原因 `nominal_safe` →
新 `isParabolic=false`、t=1 预测与直线一致、原因 `reduce_exposure`（接管闪开）。

改动：`config/defaults.lua`（`wallContactSlack=2.0`）、`sensors/terrain.lua`（probe 抹掉接触裕量内的
硬穿透；`self.slack` 记入 refresh 签名；飞行时 TNT 不再算危险）、`sensors/effects.lua`
（`PLAYER_CREEP_VARIANTS` + `FLAG_FRIENDLY` 链 + 飞行地面免疫）、`entities/tracker.lua` +
`threat/projectile_predict.lua` + `threat/future_motion.lua`（脏样本一致性校验）、`tests/*`（mock 的
`GridCollisionClass`/`GridEntityType`/`EntityType`/`EffectVariant` 全部对齐真机枚举值；
新增贴墙接触、敌我液体、飞行免疫 3 条回归；SHARED CONTROL 42 passed）。

### a7e6b41 — ALT 键值、地刺/火堆/机关避让、炸弹圈冻死与抢操作（2026-09-11）

用户报 4 件事 + 补充 1 件，全部先定位后用真实 Lua 复现确认再改：

| 反馈 | 根因 |
|---|---|
| 按 ALT 暂停无效 | `toggleKey=56` 是 GLFW 的"数字键 8"，左Alt 应为 **342**；回放 `toggle` 事件数 = 0 |
| 地刺避让不明显 | 地刺被当硬墙一击否决（risk 10000）；且原输入踩刺时走 `nominal_safe` 短路，从不进候选比较 |
| 火堆避让范围大 | `max(Size*1.6,30)` 被 MIN 钳死恒为 30 → 禁入 41.5px > 40px 格距，连相邻格一起封 |
| 卡手 / 抢操作 | 零向量按住(15.2%) + 100% 替换输入 + 预算饥饿(78% 搜不完，60% 只比 1~3 个候选) + 平手阈值 0.05 |
| 石像机关过不去 | 预测走廊固定 半宽22×长160，离射线 34px 即判危险 |
| 咒术房地刺环+炸弹"上下左右都不能动" | 环心四周全是地刺 → 全方向被 10000 否决 → 唯一合法候选 `(0,0)` → 帧 18463–18609 被钉死 5 秒 |

改动：`config/{defaults,mcm,runtime}`、`main.lua`、`sensors/{terrain,enemies,npc_attacks}`、
`decision/{predictive,local_escape}`、`data/npc_profiles`、`control/input_writer`、
`tests/{shared_control,smoke_main}`、新增 `tools/repro_planner.{py,lua}`。

验证：Lua 5.1/5.3 全绿（SHARED CONTROL 39 passed）；`repro_planner.py` 在真实网格上确认
地刺环+炸弹不再输出零向量（改选斜向逃逸 `(-0.71,-0.71)`）、门洞初始穿透 18px→0。

### 2026-09-11（第二次）— 飞行越障 / 火堆方形 / 评估实际输出（用户微信反馈 4 条）

会话 `session_20260911_205153_..._2`（3MB，canFly=true 整局）：650 段避让里 terrain 触发 408 段，
保留下来的 101 个接管帧 **100% 是 terrain 触发、0 个真实威胁**（`hazards=0`、`initialPenetration` 1~12px），
12 帧输出与玩家输入完全反向（weight=1.0）= "抢操作"；`metrics.spikeRiskScale=55` 说明是穿透惩罚在驱动。

| 反馈 | 根因 |
|---|---|
| 飞行角色靠近石墙也触发避让 | `walkable` 不豁免 `COLLISION_SOLID`(3) → 飞行站在石头上被判"在墙里 10~30px" → `peakDepth*10` 驱动强行推开 |
| 火堆躲避"往斜上/斜下躲却容易碰上" | (a) 火堆用内切圆（半径 16.25）代替方形，漏掉 4 个角约 5px；(b) 规划器只验证 AI 原始方向，实际输出 `(1-w)*玩家+w*AI` 又被玩家输入拉回火堆；(c) 平手阈值 5 让"差 2px 的擦边解"因更贴近意图而胜出 |
| 躲避手感不如上一版 | 飞行角色整局被推离石头（本条）+ 擦边解 + 局部搜索 `terrain.dangerAt(pos)` 点调用写错 → `Escape.suggest` 抛错被 SafeCall 吞掉（扫描里 12 次）→ 卡住帧完全没有救援 |
| 更喜欢斜向、直线倾向变小 | 上述 terrain 推开方向多为其"最省代价的斜向"；随机位姿火堆扫描：斜向输出 46% → 37% |

改动：`sensors/terrain.lua`（飞行只挡 WALL 与 GRID_PILLAR，SOLID/PIT/OBJECT/TNT 可飞越；
尖刺岩石对飞行仍算软危险）、`sensors/enemies.lua`（火堆 `box=true`，半边长 `MAX(Size,16)`）、
`threat/geometry.lua`（圆-方距离 `boxClearance`）、`decision/predictive.lua`
（候选按 `c.eff` 混合后方向评估、近失平手优先 `nearMiss*`）、`decision/local_escape.lua`（`terrain:dangerAt`）、
`config/defaults.lua`（`nearMissClearance/Risk/TieBreak`）、`tests/*`（新增 4 条回归；
`tests/smoke.lua` 的 `GridCollisionClass`/`GridEntityType` 改为真机枚举值），
新增 `tools/repro_fixes.{py,lua}`（闭环运动模拟：每帧重新决策 + 按 `maxDodgeWeight` 混合 + 运动模型积分）。

验证（`python tools/repro_fixes.py`，同一份确定性 PRNG，`git stash` 前后各跑一次）：

| 指标 | 旧 | 新 |
|---|---:|---:|
| 火堆随机位姿 200 例：碰火 | 70 (35%) | **0 (0%)** |
| 火堆最小间隙均值 | 10.17px | 12.48px |
| 火堆斜向输出占比 | 46% | **37%** |
| 飞行越障 48 例接管次数 | 15 | **0** |
| 步行对照（应仍脱出） | 2/6 | 2/6 |
| 规划器异常（被 SafeCall 吞掉） | 12 | **0** |
| 弹幕 200 例闭环命中 | 0 | 0 |

`python tests/run_smoke.py`：Lua 5.1/5.3 全绿（SHARED CONTROL 41 passed）。另修好 `tools/repro_planner.py`
里 `analysis/repro_ring.lua` 的失效路径（实际文件在 `tools/repro_planner.lua`）。

### 更早

- `30e51c7` 抛物线弹幕检测与避让；火堆范围 2.0（后被证明被 MIN 钳死，无效）
- `8799829` 敌方激光/弹幕检测重构、火堆判定修正
- `0788945` 火堆熄火状态过滤（`NoFire*` 动画）、按键上升沿检测
- 回放系统：时序修复、受击归因入 JSONL、级别 4 威胁明细 + 候选评分、`tools/analyze_replay.py`

> 历史遗留数据（供对照，勿当结论）：`collisionUrgency=0.9 但实体计数全 0` 的"异常"已解释——
> `threat.level`（`=collisionUrgency`）在 `predictive.lua` 里除了 `base.hit` 还有一条
> `initialDepth>0 → 0.9` 分支，即"玩家被判在硬地形里"；当时的推理误读了死代码
> `threat/threat_level.lua`。门格豁免后该状态基本消失。
