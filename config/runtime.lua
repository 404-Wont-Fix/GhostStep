-- config/runtime.lua
-- 运行时状态容器。唯一的全局状态入口，由 main.lua 持有并显式传递给各模块
-- （糟粕#3 的替代方案：局部状态 + 显式参数传递）

local Runtime = {}

--- 创建运行时状态表
function Runtime.create(config)
    return {
        config = config,        -- 配置引用（defaults + MCM/存档覆盖后的实例）

        -- 双帧计数器（模式7：update 30fps 暂停停止 / render 60fps 暂停继续）
        updateCount = 0,
        logicTick = 0,
        renderCount = 0,

        -- 开关
        userEnabled = true,     -- ALT 键切换的运行时开关（与 Config.enabled 是 AND 关系）
        statusToastUntil = 0,   -- 状态提示显示截止（renderCount）

        -- 房间
        currentRoomIndex = -1,
        roomCommitPending = false, -- 房间切换延迟提交标记（模式6）
        inCombat = false,          -- 当前房间是否有活敌（录制 cmb 字段用）

        -- 玩家
        player = {
            valid = false,
            controllerIndex = 0,
            canFly = false,
            position = Vector(0, 0),
            velocity = Vector(0, 0),
            inputDir = Vector(0, 0),   -- 本帧玩家原始输入方向（归一化前）
            radius = 10,
            hp = nil,                  -- 红心+魂心总量（HP 轮询受伤兜底基线）
            wasInvincible = false,     -- 上帧无敌状态（上升沿=刚受伤）
        },

        -- 威胁评估输出
        threat = {
            level = 0,          -- 综合威胁等级 [0,1]
            collisionUrgency = 0, -- 碰撞紧急度 [0,1]
            densityScore = 0,   -- 弹幕场密度分数 [0,1]
            framesUntilHit = -1, -- 沿当前路径首次碰撞帧数（-1 无碰撞）
            gradientDir = nil,  -- 弹幕场梯度规避方向（Vector 或 nil）
            hitKind = nil,      -- 当前预测命中的威胁类型（受击归因用）
            hitDamage = nil,    -- 命中威胁的伤害值
            hitDist = nil,      -- 命中威胁的距离（像素）
            projectileCount = 0,
            enemyCount = 0,     -- 接触威胁敌人数
            laserCount = 0,     -- 激光威胁数
            bombCount = 0,      -- 炸弹威胁数
            effectCount = 0,    -- 效果/水坑/火焰数
            npcAttackCount = 0, -- NPC攻击前兆数
            hazardCount = 0,    -- 活跃威胁实体总数（所有类型）
        },

        -- 受击归因统计（按局累积，新对局重置；MCM 调试页显示）
        -- 调参仪表盘：哪类失败多就知道该调哪组参数
        hitAttribution = {
            undetected = 0, -- 未检测：受击时威胁低于介入阈值（传感器覆盖缺口）
            late = 0,       -- 检测太晚：威胁中等但介入不足（灵敏度/提前量）
            wrongDir = 0,   -- 方向错误：闪避方向朝伤害来源（评分权重问题）
            lowWeight = 0,  -- 权重不足：方向对但被墙角钳制（原则5权衡）
            blocked = 0,    -- 位移受阻：AI输出满速但实际不动（墙/人墙，需中期规划）
            tooFast = 0,    -- 反应时间不足：高威胁高权重仍被打（预测窗口）
            total = 0,
        },

        -- 决策输出
        decision = {
            layer = "none",     -- none / gradient / early_dodge / escape / fallback
            dodgeDir = nil,     -- 本帧闪避方向（Vector，归一化）
            dodgeDirPrev = nil, -- 上帧方向（平滑用）
            holdFramesLeft = 0, -- 方向保持剩余帧
            usedBudgetMs = 0,   -- 本帧决策耗时
            degraded = false,   -- 本帧是否采样降级
            lastTrace = nil,    -- 候选评分 trace（级别4录制用，Fallback 填充）
        },

        -- 控制（MC_INPUT_ACTION 读取）
        control = {
            active = false,     -- 本帧是否介入
            direction = Vector(0, 0), -- 合成后的输出方向
            weight = 0,         -- 本帧权重（诊断：AI 方向与玩家输入的偏离度）
            blendWeight = 0,    -- AI 方向在最终输入中的占比（≤ maxDodgeWeight）
            playerDir = nil,    -- 本帧玩家原始输入（限幅后），混合层用
            frame = -1,         -- 决策帧号（超时失效保护）
            wallDist = -1,      -- 本帧玩家离墙距离（9999=地形无效；录制/归因共用）
        },

        -- 性能
        profiler = {
            lastFrameMs = 0,
            avgFrameMs = 0,
        },
    }
end

--- 房间切换时重置状态（7.5.6）
function Runtime.onNewRoom(state)
    Runtime.suspendThreat(state)
    state.motion = nil
    state.feedback = nil
    state.control.active = false
    state.control.direction = Vector(0, 0)
    state.control.weight = 0
    state.control.wallDist = -1
    state.threat.level = 0
    state.threat.collisionUrgency = 0
    state.threat.densityScore = 0
    state.threat.framesUntilHit = -1
    state.threat.gradientDir = nil
    state.decision.layer = "none"
    state.decision.dodgeDir = nil
    state.decision.dodgeDirPrev = nil
    state.decision.holdFramesLeft = 0
    state.decision.lastTrace = nil
end

--- 闪避挂起（ALT 关/总开关关/玩家无效）时清威胁与决策残影
--- 威胁评估不运行的帧，录制快照必须记零值而不是上一帧残影
function Runtime.suspendThreat(state)
    local t = state.threat
    t.level = 0
    t.collisionUrgency = 0
    t.densityScore = 0
    t.framesUntilHit = -1
    t.gradientDir = nil
    t.hitKind, t.hitDamage, t.hitDist = nil, nil, nil
    t.projectileCount, t.enemyCount, t.hazardCount = 0, 0, 0
    t.laserCount, t.bombCount, t.effectCount, t.npcAttackCount = 0, 0, 0, 0
    state.decision.layer = "none"
    state.decision.dodgeDir = nil
    state.decision.dodgeDirPrev = nil
    state.decision.holdFramesLeft = 0
    state.decision.command = nil
    state.decision.reason = "disabled"
    state.decision.usedBudgetMs = 0
    state.decision.degraded = false
    state.decision.metrics = nil
    state.decision.hazards = nil
    state.decision.planner = nil
    state.decision.lastTrace = nil
    state.control.active = false
    state.control.direction = Vector(0, 0)
    state.control.weight = 0
    state.control.blendWeight = 0
    state.control.frame = -1
    state.control.hookSeen = false
    state.control.wallDist = -1
end

--- 判定是否真正启用（总开关 AND ALT 开关 AND 非观察模式）
function Runtime.isDodgeActive(state)
    return state.config.enabled and state.userEnabled
end

--- 重置受击归因统计（MC_POST_GAME_STARTED 新对局时调用）
function Runtime.resetHitStats(state)
    local a = state.hitAttribution
    for k in pairs(a) do a[k] = 0 end
end

return Runtime
