-- sensors/enemies.lua
-- 敌人接触威胁采集（用户点名的"碰撞"伤害）
-- 敌人本体 = 移动威胁圆：喂给追踪器后，闭式碰撞解与密度梯度场直接复用
-- 判定模式参考 autoaim（IsActiveEnemy/IsDead/FLAG_FRIENDLY 为已验证 API），
-- 但不做 IsVulnerable/IsInvincible 过滤——无敌敌人（龟缩Host等）仍可能有接触伤害，
-- 威胁检测安全优先

local EnemySensor = {}

local HopTracker = require("entities/hop_tracker")

-- 攻击动画库（tools/parse_animations.py 生成）：用来判断精灵是不是在播“跳跃类”动画，
-- 以及拿它的总帧数/前摇帧数当滞空/预警的初始估计。库缺失时静默降级。
local okAnimDB, animDB = pcall(require, "data/npc_animdb")
if not okAnimDB then animDB = nil end

-- 跳跃型敌人节拍跟踪（房间切换时 reset；entity.Index 会在新房间复用）
local hop = HopTracker.create({})

local _enemyLoggedThisRoom = false
local _enemyLastCount = -1

-- 特殊实体类型（auto_dodge 验证值）
local TYPE_ULTRA_GREED_COIN = 293 -- Ultra Greed 扔的硬币，有接触伤害
local TYPE_WIZOOB = 219           -- 幽灵敌人，appear 动画时无接触伤害
local TYPE_FIREPLACE = 33         -- 火堆：静态接触伤害，火焰范围 >> entity.Size
-- ENTITY_FROZEN_ENEMY（enums.lua / entities2.xml id=963 name="Frozen Enemy"）：
-- 被冰冻打死的敌人变成的冰雕：collisionDamage=0（撞上去不扣血），
-- 玩家可以走进去把它踢滑、它只挡敌人子弹。用户 2026-09-12 反馈：
-- “被冰冻住的敌人无法推动、还会触发避让” → 它不是接触威胁，必须整个跳过。
local TYPE_FROZEN_ENEMY = 963

-- 火堆危险形状：火堆是静态格实体（Type 33），碰撞体是方形，不是圆。
-- 两个独立事实：
--   1) entities2.xml / references/GhostStep/data/entities.lua：collisionRadius = 13（所有变体）。
--      历史注释“回放里恒为 30”其实是旧代码 MAX(Size*2.0, MIN=30) 里 MIN 的值（坑 6）。
--   2) 绘制火焰约 32px 宽（半宽 16）。只按碰撞半径 13 判会让玩家“看着烧到了却不算”。
-- 因此方形半边长 = MAX(实体尺寸, 16)，禁入面距 = 16 + 10 + 1.5 = 27.5px < 40px 格距，
-- 不会连相邻格一起封死；而方形的 4 个角伸到 16√2 ≈ 22.6，正是旧图模型漏掉、
-- 导致“往火堆斜上方/斜下方躲却呕上”的地方（用户 2026-09-11 反馈）。
local FIREPLACE_HALF = 16

--- 安全读取动画名（小写）
local function safeAnimLower(entity)
    local ok, sprite = pcall(function() return entity:GetSprite() end)
    if not ok or sprite == nil then return "" end
    local ok2, anim = pcall(function() return sprite:GetAnimation() end)
    if ok2 and type(anim) == "string" then return string.lower(anim) end
    return ""
end

--- 读精灵动画（小写名 + 当前帧），失败返回 nil
local function readSpriteAnim(entity)
    local ok, sprite = pcall(function() return entity:GetSprite() end)
    if not ok or sprite == nil then return nil end
    local ok2, anim = pcall(function() return sprite:GetAnimation() end)
    if not ok2 or type(anim) ~= "string" or anim == "" then return nil end
    local ok3, frame = pcall(function() return sprite:GetFrame() end)
    return string.lower(anim), (ok3 and tonumber(frame)) or 0
end

--- 动画信号：精灵在播“跳跃类”动画时返回 {name, frame, hop=true, total, windup}，否则 nil。
--- 中文名对照（游戏 stringtable.sta）：TRITE=跳蛛、BLISTER=水疱跳蛛。
--- 动画事实（029.001_Trite.anm2）：Hop 26 帧 / Idle 2 / Appear 26 / BigJumpUp 12。
--- 注意：普通蜘蛛（085.000_spider.anm2）只有 Idle/Walk/Appear/Death，
--- 没有 Hop 动画——它的“跳”是位置突变而不是动画，所以它走速度信号那条路。
local function hopAnimInfo(entity, config)
    if not (config.hopPredict and config.hopAnimSignal) then return nil end
    local name, frame = readSpriteAnim(entity)
    if not name then return nil end
    local matched = false
    local keywords = config.hopAnimKeywords or { "hop", "jump", "leap" }
    for i = 1, #keywords do
        if string.find(name, keywords[i], 1, true) then matched = true; break end
    end
    if not matched then return nil end
    local total, windup
    if animDB then
        local list = animDB[tostring(entity.Type) .. ":" .. tostring(entity.Variant or 0)]
        if list then
            for i = 1, #list do
                local it = list[i]
                if it.name and string.lower(it.name) == name then
                    total, windup = it.totalFrames, it.windupFrames
                    break
                end
            end
        end
    end
    return { name = name, frame = frame, hop = true, total = total, windup = windup }
end

--- 是否为接触威胁（活着且有敌意的 NPC 本体）
--- 返回: true/false，或 "fireplace"（火堆特判，radius 需放大）
local function isContactThreat(e, config)
    -- 特殊类型：Ultra Greed 硬币直接视为接触威胁（可能没有 ToNPC）
    if e.Type == TYPE_ULTRA_GREED_COIN then
        local okDead, dead = pcall(function() return e:IsDead() end)
        return not (okDead and dead)
    end

    -- 冰雕像：无接触伤害、可被玩家踢走（entities2.xml collisionDamage=0）
    if e.Type == TYPE_FROZEN_ENEMY then
        if config == nil or config.skipFrozenStatues ~= false then return false end
    end

    -- 特殊类型：火堆——静态接触伤害源。不走 ToNPC/IsActiveEnemy 通道
    -- （火堆可能两者都不满足）；radius 在采集处放大
    -- 熄灭火堆（动画 NoFire*）无接触伤害，必须排除
    -- 注意：State/HitPoints 对火堆不可靠，唯一可靠信号是动画名称
    if e.Type == TYPE_FIREPLACE then
        local okDead, dead = pcall(function() return e:IsDead() end)
        if okDead and dead then return false end
        local anim = safeAnimLower(e)
        if string.find(anim, "nofire", 1, true) or string.find(anim, "dissapear", 1, true) then
            return false
        end
        return "fireplace"
    end

    if not e.ToNPC then return false end
    local okNpc, npc = pcall(function() return e:ToNPC() end)
    if not okNpc or npc == nil then return false end

    local okDead, dead = pcall(function() return e:IsDead() end)
    if okDead and dead then return false end

    -- Wizoob 出现动画免疫（幽灵传送出现时不造成接触伤害）
    if e.Type == TYPE_WIZOOB then
        local anim = safeAnimLower(e)
        if string.find(anim, "appear", 1, true) then return false end
    end

    -- 非活跃敌人（死亡动画/被清除中）排除；API 不可用时不过滤（安全优先）
    local okActive, active = pcall(function() return e:IsActiveEnemy() end)
    if okActive and active == false then return false end

    -- 被魅惑/友方化的敌人不具威胁
    local okFriendly, friendly = pcall(function()
        return e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
    end)
    if okFriendly and friendly then return false end

    return true
end

--- 采集当帧接触威胁并喂给追踪器（kind=enemy，过期10帧）
function EnemySensor.collect(player, tracker, frame, config)
    if not config.hazardContact then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okAll, entities = pcall(Isaac.GetRoomEntities)
    if not okAll or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        local threatKind = isContactThreat(e, config)
        if threatKind then
            count = count + 1
            local radius = e.Size
            local box = false
            if threatKind == "fireplace" then
                -- 火堆：方形碰撞体（半边长 = MAX(实体尺寸, 视觉火焰半宽 16)）
                radius = math.max(radius or 0, FIREPLACE_HALF)
                box = true
            end
            local entry = {
                index = e.Index,
                seed = e.InitSeed,
                kind = "enemy",
                entityType = e.Type,
                box = box,
                variant = e.Variant,
                pos = e.Position,
                vel = e.Velocity,
                speed = e.Velocity:Length(),
                radius = radius,
                -- 接触伤害值（auto_dodge: entity.CollisionDamage or 1；读不到按 1 保守处理）
                damage = (function()
                    local okCd, cd = pcall(function() return e.CollisionDamage end)
                    if okCd and type(cd) == "number" and cd > 0 then return cd end
                    return 1
                end)(),
            }
            -- 跳跃型敌人（跳蛛 Trite 等）：测节奏 + 读精灵动画 → 预测起跳与落点
            if config.hopPredict and config.hopTypes and config.hopTypes[e.Type] then
                local okHop, hint = pcall(HopTracker.observe, hop, e, player, frame, config, hopAnimInfo(e, config))
                if okHop and hint then
                    entry.hopOn = true
                    -- 取整：Lua 5.3 的 string.format("%d") 不接受浮点（会直接报错），
                    -- 而节奏/滞空都是 EWMA 出来的浮点数
                    entry.hopIn = math.floor(hint.inFrames + 0.5)
                    entry.hopFlight = math.floor(hint.flight + 0.5)
                    entry.hopLX, entry.hopLY = hint.lx, hint.ly
                    entry.hopLen = hint.len
                    entry.hopPeriod = hint.period
                    entry.hopAimErr = hint.aimErr
                    -- 动画侧诊断（回放里校准“动画第几帧开始位移”= 实测前摇）
                    entry.hopAnim, entry.hopAnimFrame = hint.anim, hint.animFrame
                    entry.hopWindup = hint.windup
                end
            end
            entries[count] = entry
        end
    end
    pcall(HopTracker.expire, hop, frame)

    -- 诊断：只在敌人数变化时打日志（0→N，N→0），避免刷屏
    if config.diagnosticsEnabled and (not _enemyLoggedThisRoom or count ~= (_enemyLastCount or 0)) then
        Isaac.DebugString(string.format(
            "[GhostStep3] 敌人采集: GetRoomEntities=%d 接触威胁=%d 帧=%d",
            #entities, count, frame))
        -- 火堆专项诊断：列出所有火堆实体的动画/状态（排查熄灭误判）
        if config.diagnosticsEnabled then
            for i = 1, #entities do
                local e = entities[i]
                if e.Type == TYPE_FIREPLACE then
                    local anim = safeAnimLower(e)
                    local okS, st = pcall(function() return e.State end)
                    local okH, hp = pcall(function() return e.HitPoints end)
                    local okD, dead = pcall(function() return e:IsDead() end)
                    Isaac.DebugString(string.format(
                        "[GhostStep3]   火堆 idx=%d anim=%s State=%s HP=%s IsDead=%s pos=(%.0f,%.0f)",
                        e.Index, anim,
                        okS and tostring(st) or "?",
                        okH and string.format("%.1f", hp) or "?",
                        okD and tostring(dead) or "?",
                        e.Position.X, e.Position.Y))
                end
            end
        end
        _enemyLoggedThisRoom = true
        _enemyLastCount = count
    end

    tracker:update(entries, frame, "enemy")
end

function EnemySensor.resetRoom()
    _enemyLoggedThisRoom = false
    _enemyLastCount = -1
    pcall(HopTracker.reset, hop)
end

return EnemySensor
