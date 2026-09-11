# Tier 1 时空轨迹评分 + 动画库接入 — 开发指南

> **目标**: 让 AI 看见 28 帧外的未来——从"躲开眼前的子弹"升级为"移动到 0.8 秒后的安全区"。
> **依据**: 2026-09-08 六局 Greed 实测数据（归因统计 + 死亡回放 + jsonl 离线分析）。
> **读者**: 接手本阶段开发的任何人（人或 AI 会话）。阅读前先读 ANALYSIS.md 第〇节 7 条硬约束。
> **纪律**: 本文引用的代码状态截至 2026-09-08；以当前代码为准，冲突时先 `python tests/run_smoke.py` 确认基线（当前 47 用例）再动手。

---

## 一、为什么做（实测数据结论）

六局实测的死因分布与归因统计揭示了当前算法的两个结构性盲区：

| 盲区 | 实测证据 | 根因 |
|------|---------|------|
| **看不见 28 帧外的合围** | 多局死亡回放显示：`threat=0.50 hit=-1 w=0.21` 的"短期安全"帧之后 30-60 帧被敌人合围磨死；归因"反应时间不足"占比最大 | 预测窗口只有 28 帧，且 fallback 清晰度评分只有 8 帧窗口 + 全部线性外推 |
| **看不见"即将出现的新威胁"** | boss 落点/激光路径/射击走廊类死亡，前兆传感器（npc_attacks.lua）六局只触发过 1 次——覆盖仅 ~10 个类型且无前摇时机 | 动画检测覆盖面 10/366（老 GhostStep 有完整数据库没用上） |

其余问题（围殴性能、火堆判定、TAKE_DMG 静默、帧预算超标、anticipateStrength 死配置）已在 2026-09-08 修复，本文档不涉及。

---

## 二、现状快照（开工前必须知道的事）

### 2.1 当前决策管线

```
sensors (6类威胁→tracker) → threat_level (碰撞+密度) → pipeline:
  none < threatLow
  gradient < threatMedium        （密度质心方向）
  escape_lock (hit==0 且 threat≥high)  （5帧锁+45帧记忆+卡死检测）
  early_dodge (≤2威胁 且 hit≤12)       （垂直闪避）
  fallback (其余)                        （两阶段 DWA 候选评分 ★Tier 1 落点）
→ direction_smooth → input_synthesizer → MC_INPUT_ACTION
```

### 2.2 fallback 现有结构（decision/fallback.lua，2026-09-08 性能重构后）

- 两阶段：粗评 16 方向×1 中速（无清晰度）→ 排序 → top5 方向×3 速度精评（含清晰度）
- 清晰度评分：沿候选路径 **t=4, 8 帧**两档检查距威胁最小距离，威胁位置 **线性外推** `h.pos + h.vel*t`
- 预过滤 nearHazards（400px 内）+ 超时熔断（`budgetMs*0.8`，每 6 候选举检查一次）
- 实测帧耗时均值 1.22ms（重构前 6.97ms）——**这就是 Tier 1 可用的计算预算**

### 2.3 已就位的基础设施

| 组件 | 位置 | 对 Tier 1 的意义 |
|------|------|------------------|
| 威胁运动模型 | threat/projectile_predict.lua | 直线闭式解/三点圆弧/追踪趋势已有，缺统一的 `futurePos(entry, t)` |
| 激光旋转外推 | threat/hazard_query.lua `laserSegmentAt` | 未来线段计算现成 |
| 引信紧迫度 | threat_level.lua（bomb 的 fuseFrames→urgency） | 动画前摇 windup 可直接复用此机制 |
| 级别4录制 | recording/snapshot.lua（逐威胁明细 + 候选评分 trace） | 离线验证 Tier 1 决策质量的数据通道已通 |
| 离线分析 | tools/replay_viewer.py | 归因分布/死亡回放/统计 |
| 归因仪表盘 | main.lua attributeHit（六分类） | 验收指标的数据源 |

### 2.4 老动画库资产（references/GhostStep/）

- `data/animations.lua`：**366 个 id:variant 条目**，由 `tools/parse_animations.py` 从 anm2 离线生成。每条：`{name, totalFrames, windupFrames, category}`，category ∈ jumping/stomping/melee/...
- `scripts/constants.lua`：结构化 profile（laser/shooter windup 带 `pathEffect`/`pathLength`/`holdFrames`）——走廊型威胁的模板
- 数据可直接拷贝；生成管线在老项目 tools/ 下（更新数据时用）

---

## 三、Tier 1 设计：时空轨迹评分

### 3.1 核心思想

当前清晰度评分回答"**这条路径未来 8 帧离威胁多远**"。Tier 1 回答"**沿这条路径走 24 帧后，我在不在即将出现的空隙里**"。实现上是清晰度评分的纵向扩展：

1. **分级 horizon**：`{4, 8, 16, 24}` 四档（近期保命、远期择路）
2. **威胁按各自运动模型外推**（不再统一线性）：弧线弹幕走圆弧、追踪弹走趋势速度、旋转激光走扫掠线段、敌人走 history 平滑速度
3. **远期收敛奖励**：t=24 帧处 clearance > 60px 的候选给大额奖励——这就是"移动到未来的洞"
4. **前兆作为未来威胁参与外推**（第二里程碑接入）：妈妈脚的落点在 12 帧后才出现，但轨迹评分现在就要绕开它

### 3.2 新模块与接口

**新文件 `threat/future_motion.lua`**：

```lua
--- 统一的未来位置外推器：按 entry.kind 路由运动模型
--- 返回 t 帧后的位置（Vector）或 nil（该威胁届时已不存在/不确定）
local FutureMotion = {}

function FutureMotion.pos(entry, t)
    local kind = entry.kind or "projectile"
    if kind == "laser" then
        -- 旋转激光返回线段（复用 hazard_query.laserSegmentAt 的逻辑，
        -- 建议把该函数迁到本模块供两处共用）
        return segmentA, segmentB
    end
    if kind == "npc_attack" then
        -- 落点型：t >= 出现帧 才存在（entry.appearFrame），之前返回 nil
        --  → 轨迹评分会自动"提前绕开还没出现的位置"
    end
    -- 弹幕/敌人: isCurved → 圆弧外推(c.a0+c.omega*t)；isTracking → 趋势速度线性；
    -- 其余 → 线性 pos+vel*t。圆弧参数可从 Predict.fitCircle(entry.history…) 取，
    -- 注意缓存（每威胁每帧算一次，不在候选循环里重复拟合）
end
```

**改动 `decision/fallback.lua`**（清晰度评分段替换为轨迹评分）：

```lua
-- 现: for t = CLARITY_STEP, CLARITY_FRAMES, CLARITY_STEP（2档线性外推）
-- 改:
local HORIZONS = { 4, 8, 16, 24 }
local HORIZON_WEIGHT = { 1.0, 0.7, 0.5, 0.4 }   -- 近期重、远期轻
local CONVERGE_BONUS_T = 24                      -- 远期收敛奖励档
local CONVERGE_CLEARANCE = 60                    -- px

for hi = 1, #HORIZONS do
    local t = HORIZONS[hi]
    local futurePos = playerPos + simVel * t
    for i = 1, #hazards do
        local hp = FutureMotion.pos(hazards[i], t)   -- nil = 届时不存在，跳过
        if hp then
            local dist = futurePos:Distance(hp) - playerRadius - hazards[i].radius
            ...同现有 clearance 罚分，乘 HORIZON_WEIGHT[hi]...
        end
    end
end
-- 远期收敛奖励: t=24 处 minClearance > CONVERGE_CLEARANCE → score -= 12
```

**性能预算**（必须守住，原则4）：
- top5×3速度 = 15 候选 × 4 档 × nearHazards(≤10) = 600 次距离计算 + 每威胁每帧 1 次模型拟合缓存 ≈ **0.3-0.5ms**
- 熔断机制已有（预算 `budgetMs*0.8` 触发即用当前最优）——**不要移除**
- 若实测超预算：优先砍远期档数（24→20），其次砍精评方向数（5→4），**不许**降级回线性外推
- `budgetMs` 建议从 1.0 提到 1.5（defaults.lua），同步更新 ANALYSIS.md 口径

### 3.3 集成点清单（改哪里）

| 文件 | 改动 |
|------|------|
| `threat/future_motion.lua` | 新建（外推器 + 圆弧参数缓存表，房间切换时清空） |
| `decision/fallback.lua` | 清晰度段 → 分级轨迹评分；`CLARITY_*` 常量替换为 `HORIZONS` |
| `threat/hazard_query.lua` | `laserSegmentAt` 迁到 future_motion（或 require 共用），原调用点跟着改 |
| `main.lua` `onNewRoom` | 清空 future_motion 的圆弧缓存 |
| `config/defaults.lua` | `budgetMs` 1.0→1.5；新增 `trajectoryHorizons`（可调档位，调试用） |
| `tests/smoke_main.lua` | 新增用例（见 3.5） |

### 3.4 不做什么（边界）

- **不做完整轨迹搜索/A\***——仍是"候选评分"框架，只是评分变聪明。全路径搜索是将来的 Tier 2（势场）
- **不动 escape_lock/early_dodge 层**——它们处理的是 <5 帧的即时反应，与轨迹评分正交
- **不动 input_synthesizer**——权重合成逻辑无关预测视野

### 3.5 测试计划

冒烟测试新增（离线可验证的部分）：

1. `future_motion: arc projectile extrapolates on circle` —— 已知圆弧历史的弹幕，t 帧后位置落在圆上
2. `future_motion: tracking uses trend velocity` —— 转向中的弹幕用平均速度外推
3. `future_motion: npc_attack nonexistent before appearFrame` —— 前兆条目出现前返回 nil
4. `trajectory: converging candidate scores better` —— 构造"当前安全但 20 帧后 A 路被封 B 路开阔"场景，断言 B 候选分低（好）
5. `trajectory: near-term outweighs far-term` —— 近期档威胁的罚分 > 同等距离远期档

**游戏内验收**（数据说话，Greed 模式连打 5 局）：

| 指标 | 基线（当前） | 达标线 |
|------|-------------|--------|
| 帧耗时均值/峰值 | 1.22 / 3.0 ms | ≤ 2.0 / ≤ 4.0 ms |
| 归因 tooFast 占比 | ~50% | **下降 ≥ 50%** |
| 归因 blocked 占比 | 主要类之一 | 下降 ≥ 50% |
| 挂机存活（wave 7 起） | 参考 5 局基线 | 中位数提升 ≥ 1 个 wave |
| 死亡回放特征 | "短期安全帧后合围死" | 出现"提前移向空隙"的轨迹 |

验收数据从 tools/replay_viewer.py + log.txt 归因统计取，逐局对比。

---

## 四、动画库接入设计（Tier 1 第二批输入源）

### 4.1 分层接入（不全量）

366 条目按 category 分层，**只接高价值类**：

| category | 接入 | 威胁模型 | 理由 |
|----------|------|----------|------|
| stomping / jumping | ✅ 第一批 | 落点圆（复用现 falling_impact 逻辑） | 妈妈脚/DLL/Leaper 类，伤害高、有明确落点 |
| 激光前摇类 | ✅ 第一批 | 路径线段（生成 kind="laser" 条目带 endPos，复用旋转外推） | Brim/Vis/Maw 走廊 |
| shooter 前摇 | ✅ 第一批 | 走廊胶囊（老 GhostStep 的 pathEffect 模板，radius 收紧 ~22px） | Horf 类 |
| melee | ❌ 不接 | — | 敌人贴身早被接触威胁覆盖，接入只稀释威胁场 |
| 其余未分类 | ❌ 不接 | — | 等归因数据点名再补 |

### 4.2 数据与结构

**新文件 `data/npc_animdb.lua`**（从老 GhostStep 裁剪搬运，只留接入的条目）：

```lua
-- 自动生成自 references/GhostStep/data/animations.lua（裁剪版）
-- ["id:variant"] = { {name="Jump", totalFrames=38, windupFrames=19, category="jumping"}, ... }
return { ["213:0"] = {...}, ... }
```

**新文件 `data/npc_profiles.lua`**（category → 威胁生成规则，人写）：

```lua
-- category → { kind, radius, appearDelay, path? }
--   jumping/stomping: 落点圆，radius 按类型表（沿用现有 FALLING_IMPACT 等常量）
--   laser: kind="laser"，带 endPos（朝玩家方向 × LASER_WINDUP_LENGTH）
--   shooter: 走廊胶囊（起点=敌人 pos，方向=朝玩家，长 160px，半径 22）
return {
    stomping = { kind = "npc_attack", radiusFrom = "type_table", fuseFromWindup = true },
    jumping  = { kind = "npc_attack", radiusFrom = "type_table", fuseFromWindup = true },
    laser    = { kind = "laser", pathLength = 480 },
    shooter  = { kind = "laser", pathLength = 160, radius = 22 },
}
```

### 4.3 npc_attacks.lua 表驱动重构

现有 if-else（~10 类型）全部迁入 profile 表，**行为保持不变**（先有回归测试再动重构）。新流程：

```
扫描 NPC → 动画名(小写) → 查 animDB["id:variant"]（当前动画是否在攻击表）
→ 命中 → 查 profile[category] → 生成前兆条目:
    { kind=..., pos=落点/敌人pos, vel=0, radius=...,
      fuseFrames = windupFrames - 已播放帧数,     -- ★前摇倒计时
      appearFrame = frame + fuseFrames,            -- ★供 future_motion "还不存在"判定
      damage = 类型表值 }
```

关键映射——**windupFrames → fuseFrames**：threat_level.lua 已有引信紧迫度分支（`hitEntry.kind == "bomb" and fuseFrames`），把它通用化为 `hitEntry.fuseFrames ~= nil` 即可让前兆威胁共享"倒计时越近越紧急"逻辑，零新机制。

hazard_query 侧：kind="npc_attack" 走圆碰撞已有 ✓；laser 前兆生成的条目天然走激光线段路由 ✓。

### 4.4 测试与验收

- 冒烟：表驱动重构后现有 4 个 npc_attack 用例全绿（行为不变验证）；新增"windup 倒计时条目生成""laser 前兆走线段路由"两例
- 游戏内：MCM 调试页/快照的 `npcatk` 计数在 boss 房显著上升（基线：六局只出现 1 次）；归因 undetected 中 boss 攻击类消失
- 性能：animDB 是纯查询表，预算影响 <0.1ms，不单独设线

---

## 五、里程碑与依赖顺序

```
M1  Tier 1 主体                （§3.3 清单，~1 个会话）
     └─ future_motion + fallback 轨迹评分 + 测试
M2  实测验证                   （Greed 5 局，§3.5 验收表）
     └─ 不达标 → 调权重/档位，不达标原因写入本文档附录
M3  动画库数据层               （§4.2 搬运裁剪 + §4.3 表驱动重构）
     └─ 行为不变回归 + animDB 查询测试
M4  前兆喂 Tier 1              （fuseFrames 通用化 + future_motion 接 appearFrame）
     └─ 实测：npcatk 触发率↑ + boss 攻击类 undetected 消失
```

**为什么这个顺序**：M1/M2 先用现有传感器数据立起"未来视野"管线并验证收益；M3/M4 的前兆数据才有消费方（future_motion 的 appearFrame 逻辑）。反过来做会造出没人用的数据层。

---

## 六、已知坑（Rep+ 环境专项，新人必读）

1. **回调首参注入**：本机 Rep+ 所有 `AddCallback` 回调第 1 参数是注入对象（mod 实例），真实参数从第 2 位开始。判别法：`type(p1)` —— `userdata`=真实体，`table`=注入对象。取实体一律 `Isaac.GetPlayer(0)`（pcall 包裹）。
2. **API 可用性以本机为准**：文档（IsaacDocs /rep/ 即 Rep+）说存在 ≠ 本机存在。写新 API 前：a) grep `references/` 看有没有真人用过；b) 拿不准就在首帧打一次性探测日志（先例：GetHearts 探测）。
3. **Lua 5.4**：`math.atan2` 已并入 `math.atan(y,x)`（用 shim 兼容）；`goto` 可用但本项目风格是标志位 + break。
4. **`mathext.remap` 只支持递增区间**：`inMax <= inMin` 直接返回 outMin。倒序映射写成等价递增形式（先例：fuse 的 `remap(f, 0, 30, 1.0, 0.6)`）。
5. **tracker 全字段透传**：sensors 给 entry 加新字段（damage/fuseFrames/endPos/appearFrame...）自动进追踪器，无需改 tracker.lua；但**冒烟测试的 mock 实体要同步补字段**，否则测的不是新路径。
6. **测试 mock 不验证 API 形状**：离线 mock 是按想象写的。API 形状错误只能在游戏内暴露——重要路径要配"一次性探测日志"兜底。
7. **部署**：`python tools/gs.py 4`（或双击 `deploy.bat`，它转调同一条命令）——镜像同步到 mods/GhostStep3；
   排除清单的**唯一来源**是 `tools/gs.py` 的 `ROBOCOPY_XD` / `ROBOCOPY_XF`（`--dry-run` 可预览）。
   bat 文件**必须纯 ASCII**（GBK 代码页下 UTF-8 中文注释会炸出垃圾命令）。游戏内 Ctrl+R 重载 Lua。
8. **录制数据分析**：`--luadebug` 启动 + MCM 开录制 → `mods/GhostStep3/recordings/*.jsonl` → `python tools/replay_viewer.py <file> --seconds N`。快照级别 4 含逐威胁明细+候选评分（离线可重算决策）。
9. **并行开发协调**：改动前 `git status` + 重读目标文件（可能有并行会话的改动）；每轮收尾跑全量冒烟测试再部署。
10. **归因仪表盘是验收之本**：每局挨打都会打 `受击归因#N` 行（六分类+建议），MCM 调试页有局内统计。任何行为改动都要看归因分布有没有往预期方向走。

---

## 附录 A：六局实测死因存档（2026-09-08）

| 局 | 死因 | 归因 | 当轮修复 |
|----|------|------|---------|
| 1 | (10.1) 爆炸effect | 归因系统未通（TAKE_DMG 静默） | effect 伤害兜底 |
| 2 | (85.0) Greed 接触 | 同上（GetHearts 假可用） | HP 自检 |
| 3 | (10.0) 爆炸effect | 同上（首参注入实锤） | GetPlayer(0) 统一取实体 |
| 4 | (869.0) Ultra Greed | tooFast×3 lowWeight×2 | 被围钳制放宽+卡死检测 |
| 5 | (869.0) 围殴 | tooFast×3（w=0.30 钳制盲区） | hit≤1 放宽+性能重构 |
| 6 | (33.0) 火堆 | undetected×2（火焰范围>Size） | 火堆特判+radius 放大 |

## 附录 B：实体类型速查（本机验证过的）

- 伤害来源：33=火堆(接触,火焰~2.5×Size)、85=Greed类、869=Ultra Greed、10=爆炸effect、9=弹幕、7=激光
- 传感器特判已有：293=Ultra Greed硬币、219=Wizoob(appear免疫)、33=火堆
- 已验证可用 API：IsDead/ToNPC/IsActiveEnemy/HasEntityFlags/CollisionDamage/GetHearts/GetSoulHearts/GetDamageCooldown/IsInvincible/FindByType/GetRoomEntities/IsClear/GetSeeds/GetEndPoint(激光)/RotationSpd/AngleDegrees/LastAngleDegrees/MaxDistance/ExplosionDamage(bomb)/Damage(projectile)
- 未验证（勿直接用）：GetExplosionCountdown、EntityPlayer:IsDamageEnabled（不存在）、Room:GetAliveEnemiesCount、MC_POST_PLAYER_DEATH（nil）
