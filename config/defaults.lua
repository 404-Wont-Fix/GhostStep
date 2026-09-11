-- config/defaults.lua
-- 分组默认配置。所有可调参数收归此处，杜绝魔法数字（糟粕#8）
-- 运行时实例为 Config 表，由 main.lua 创建并传递给各模块

local Defaults = {}

--- 全部默认配置（按分组）
function Defaults.get()
    return {
        ---------------------------------------------------------------
        -- 常规
        ---------------------------------------------------------------
        enabled = true,
        -- 键盘键值 = 引擎 Keyboard 枚举（GLFW 键码），不是顺序索引。
        -- 左Alt = 342（游戏自带 resources/scripts/enums.lua）。
        -- 历史 bug: 旧默认 56 在 GLFW 码里是数字键 8，所以按 Alt 从未生效。
        toggleKey = 342,
        preset = 2,                 -- 1低 2适中 3高

        ---------------------------------------------------------------
        -- 危险源（威胁类型开关）
        ---------------------------------------------------------------
        hazardProjectiles = true,   -- 敌方弹幕
        hazardContact = true,       -- 敌人接触伤害
        hazardLasers = true,        -- 激光（Phase 3 实装，先占位）
        hazardBombs = true,         -- 炸弹（Phase 3 实装，先占位）
        hazardCreep = true,         -- 水坑/火焰（Phase 3 实装，先占位）
        hazardNpcAttacks = true,    -- NPC攻击前兆（Phase 3 实装，先占位）
        hazardSpikes = true,        -- 地刺
        hazardTnt = true,           -- TNT 爆炸

        ---------------------------------------------------------------
        -- 躲避（算法核心参数）
        ---------------------------------------------------------------
        plannerHorizon = 18,        -- 引擎帧；需通过实机运动日志校准
        plannerHorizonWide = 30,    -- 存在炸弹/激光/大半径威胁时的窗口（帧）
                                    -- 实测: 18 帧 ≈ 73px 位移，跑不出 90px 爆圈 → 看不到可行解
        plannerMaxCandidates = 64,
        plannerMaxChecks = 80000,   -- 几何检查次数硬上限
        -- 地刺代价（不再硬否决；见 decision/predictive.lua）
        -- 一次性接触代价 + 停留代价（每帧）。停留代价故意取小值：
        -- 地刺环里所有方向都踩刺时，帧数差异不应盖过玩家意图。
        spikeContactRisk = 55,
        spikeRiskPerTick = 0.5,
        -- 射击前摇走廊（npc_attacks ranged 类）几何：
        -- 实测原半宽 22 + 长 160 会把"从机关前经过"整条封死
        rangedCorridorRadius = 8,
        rangedCorridorMaxLen = 240,
        intentPenalty = 3,
        smoothPenalty = 0.2,
        riskTieEpsilon = 5,         -- 风险平手阈值：差不超过它就按"更贴合玩家意图"选
                                    -- 旧值 0.05 太严：3.44 的边际收益就能把方向翻到意图反面
        -- 近失（擦边）平手中的优先项：风险差在 riskTieEpsilon 内时，先比擦边程度再比代价。
        -- 没有它时“夹缝擦过”与“从容通过”风险相同，平手阈值会把方向交给擦边解，
        -- 体感就是“往威胁斜上方/斜下方躲却呕上”（2026-09-11 用户反馈）。
        -- 不能计入 risk：riskTieEpsilon=5 会把 12 分的擦边扣分当成平手，又被意图代价盖掉。
        nearMissClearance = 8,      -- 从容距离（px，已含 hazard 半径+玩家半径+margin）
        nearMissRisk = 1.5,         -- 每 px 擦边的等值分
        nearMissTieBreak = 2,       -- 擦边分差至少这么大才改写选择
                                    -- （≈1.3px 裕量）。阈值太小会为了 0.1px 裕量
                                    -- 把方向掰到玩家意图之外（实测 (0,1)→(-0.71,0.71)）
        safetyMargin = 1.5,
        stuckFrames = 6,
        escapeMaxNodes = 48,
        terrainRefreshFrames = 3,
        eventRecording = false,    -- 可选详细前后文；日常使用轻量记录
        eventPreFrames = 60,
        eventPostFrames = 30,
        eventMaxBytes = 2097152,
        recorderMaxBytes = 1048576,
        recorderBatchBytes = 32768,
        recorderSlowWriteMs = 8, -- 单次慢写后暂停本局磁盘输出，内存回放继续
        maxDodgeWeight = 0.85,      -- AI 权重上限（原则2：永不 1.0）
        threatLow = 0.25,           -- 低威胁阈值：低于此完全不介入（灵敏度联动：高=0.20 平衡=0.25 低=0.31）
        threatMedium = 0.45,        -- 中威胁阈值：提前规避阶段上限
        threatHigh = 0.65,          -- 高威胁阈值：紧急闪避
        threatSensitivity = 2,      -- 威胁感知灵敏度 1低/2平衡/3高（联动上面三个阈值）
        anticipateStrength = 5,     -- 提前规避强度 0-10（弹幕场梯度权重）
        gradientRadius = 120,       -- 弹幕场梯度采样半径（像素）
        gradientBins = 8,           -- 梯度方向 bin 数
        enemyProximityRadius = 200, -- 敌人接近威胁半径（像素，80→200，覆盖中距离敌人保持AI持续介入）
        wallStuckThreshold = 60,    -- 靠墙判定距离（像素），低于此降权（含房间边界检测）
        wallEscapeSensitivity = 2,  -- 墙角挣脱灵敏度 1低/2中/3高（联动 wallStuckThreshold）
        wallEscapeWeight = 0.5,     -- 挣脱模式下的 AI 权重上限（原则5；0.3→0.5，escape_lock提前触发后需更大推力）
        wallPenaltyBase = 1.0,      -- 候选方向墙壁惩罚基数
        wallPenaltyThreshold = 100, -- 墙壁惩罚衰减距离（像素）
        directionSmoothFrames = 3,  -- 方向平滑帧数
        minHoldFrames = 3,          -- 最小方向保持帧数（防抖）

        ---------------------------------------------------------------
        -- 传感器
        ---------------------------------------------------------------
        combatFrameInterval = 1,    -- 战斗中采集间隔（帧）
        idleFrameInterval = 15,     -- 空闲时采集间隔（帧）
        projectileExpiry = 5,       -- 弹幕追踪过期帧数
        enemyExpiry = 10,           -- 敌人追踪过期帧数
        ownershipCacheTtl = 180,    -- 弹幕归属缓存帧数
        maxProjectiles = 300,       -- 弹幕采集上限（防御）
        degradeThreshold = 50,      -- 弹幕数超过此值 → 采样降级
        budgetMs = 5,               -- 每帧决策预算（毫秒，原则4）
                                    -- 实测: 1.5ms 时 78% 的帧搜不完（13k 帧样本），
                                    -- 帧总耗时中位 3ms / p99 6ms（33ms 帧预算）→ 5ms 安全

        ---------------------------------------------------------------
        -- 显示
        ---------------------------------------------------------------
        renderEnabled = false,      -- 视觉反馈总开关
        renderThreatBar = true,     -- 威胁等级条
        renderDodgeArrow = true,    -- 闪避方向箭头
        renderWeight = true,        -- AI 权重显示
        renderGradient = false,     -- 弹幕场梯度可视化
        pureMode = false,           -- 纯净模式：关闭所有视觉

        ---------------------------------------------------------------
        -- 录制
        ---------------------------------------------------------------
        recordingEnabled = true,    -- 环形缓冲录制（默认开：玩的过程发现问题要能回查数据；
                                    --   无 --luadebug 时自动降级为纯内存，无副作用）
        deathReplayEnabled = true,  -- 死亡时输出回放
        replayBufferSeconds = 30,   -- 缓冲时长（秒）
        snapshotDetail = 2,         -- 1最小 2标准 3详细 4全量诊断（逐威胁明细+候选评分）
        traceHazardMax = 16,        -- 级别4逐威胁明细条数上限
        traceHazardRadius = 300,    -- 级别4逐威胁纳入半径（像素，相对玩家）

        ---------------------------------------------------------------
        -- 调试
        ---------------------------------------------------------------
        observationMode = false,    -- 观察模式：只采集不控制
        profilerEnabled = false,    -- 性能分析
        diagnosticsEnabled = false, -- 诊断事件日志
        logEnabled = false,         -- 控制台日志
    }
end

return Defaults
