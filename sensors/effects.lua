-- sensors/effects.lua
-- 水坑/火焰/冲击波威胁采集（Phase 3.3）
-- 效果 = 静态或移动的区域威胁，按 EffectVariant 分类
-- 分类表移植自 auto_dodge_helper 的验证实现（社区成熟的 variant 枚举）
-- 黑名单：视觉特效（poof/尘云等）不算威胁

local EffectSensor = {}

local EntityType = EntityType
local EffectVariant = EffectVariant
local playerType = EntityType.ENTITY_PLAYER
local familiarType = EntityType.ENTITY_FAMILIAR

-- ===== 威胁分类表（EffectVariant 枚举，来自 auto_dodge 验证实现）=====

-- creep 水坑：持续地面伤害，静态危险圆
local CREEP_VARIANTS = {
    [EffectVariant.CREEP_RED] = true,     -- 22
    [EffectVariant.CREEP_GREEN] = true,   -- 23
    [EffectVariant.CREEP_YELLOW] = true,  -- 24
    [EffectVariant.CREEP_WHITE] = true,   -- 25
    [EffectVariant.CREEP_BLACK] = true,   -- 26
    [EffectVariant.CREEP_BROWN] = true,   -- 56
}

-- 火焰：静态危险圆
local FIRE_VARIANTS = {
    [51] = true, -- HOT_BOMB_FIRE
    [52] = true, -- RED_CANDLE_FLAME
}

-- 冲击波：有路径的移动威胁
local SHOCKWAVE_VARIANTS = {
    [61] = true, -- SHOCKWAVE
    [67] = true, -- SHOCKWAVE_DIRECTIONAL
    [72] = true, -- CRACKWAVE
}

-- Boss 落点：扩大中的圆（妈妈的手/脚等）
local IMPACT_VARIANTS = {
    [29] = true, -- MOM_FOOT_STOMP
    [30] = true, -- TARGET
    [31] = true, -- ROCKET
    [91] = true, -- MOMS_HAND
}

-- 默认危险半径（像素）—— creep/火焰用 Size，冲击波/落点用这个
local DEFAULT_RADIUS = 26

-- 视觉特效黑名单（不是威胁，排除采集）
local VISUAL_BLACKLIST = {
    [11] = true, -- BULLET_POOF
    [12] = true, -- TEAR_POOF_A
    [18] = true, -- BOMB_CRATER
    [59] = true, -- DUST_CLOUD
}

--- 链式归属追踪：向上遍历 SpawnerEntity→Parent 链，检查是否为玩家/跟班相关
--- 解决跟班生成的地面效果 SpawnerType==0（默认值）导致误判为敌方的问题
--- 参考 sensors/projectiles.lua 的 hasNpcOwnerInChain 模式
local function isPlayerRelated(entity, depth)
    if not entity or (depth or 0) > 3 then return false end
    local okT, t = pcall(function() return entity.Type end)
    if okT and (t == playerType or t == familiarType) then return true end
    return isPlayerRelated(entity.SpawnerEntity, (depth or 0) + 1)
        or isPlayerRelated(entity.Parent, (depth or 0) + 1)
end

--- 是否为威胁效果
local function isThreatEffect(variant)
    if VISUAL_BLACKLIST[variant] then return false end
    return CREEP_VARIANTS[variant] or FIRE_VARIANTS[variant]
        or SHOCKWAVE_VARIANTS[variant] or IMPACT_VARIANTS[variant]
end

local function safeGet(entity, getter, fallback)
    local ok, v = pcall(getter, entity)
    if ok and v ~= nil then return v end
    return fallback
end

--- 采集当帧威胁效果并喂给追踪器
function EffectSensor.collect(player, tracker, frame, config)
    local okFind, entities = pcall(Isaac.FindByType, EntityType.ENTITY_EFFECT, -1, -1, false)
    if not okFind or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        local variant = safeGet(e, function(x) return x.Variant end, -1)
        -- 伤害值（auto_dodge 模式: effect.CollisionDamage or entity.CollisionDamage or 0）
        local damage = safeGet(e, function(x) return x.CollisionDamage or 0 end, 0)
        local creep=CREEP_VARIANTS[variant]
        -- 链式友方检测：跟班生成的水渍 SpawnerType 可能为0（默认值），
        -- 仅检查 SpawnerType 会漏判，需遍历 SpawnerEntity/Parent 链
        local playerOwned=e.SpawnerType==playerType or e.SpawnerType==familiarType
            or isPlayerRelated(e.SpawnerEntity, 0) or isPlayerRelated(e.Parent, 0)
        local immuneGround=creep and player and player.canFly
        local enabled=not creep or config.hazardCreep
        if enabled and not immuneGround and not (creep and playerOwned)
            and (isThreatEffect(variant) or damage > 0) then
            -- 兜底：未分类 variant 但带 CollisionDamage 的效果也算威胁
            -- （"Killed by (10.1)" 类爆炸特效就在这层被接住，避免漏判）
            local isDead = safeGet(e, function(x) return x:IsDead() end, true)
            if not isDead then
                count = count + 1
                -- 半径：优先用 Size（creep/火焰适配），冲击波/落点用默认半径
                local radius = safeGet(e, function(x) return x.Size end, DEFAULT_RADIUS)
                if SHOCKWAVE_VARIANTS[variant] or IMPACT_VARIANTS[variant] then
                    radius = math.max(radius, DEFAULT_RADIUS)
                end
                entries[count] = {
                    index = e.Index, seed = e.InitSeed, entityType = e.Type, variant = e.Variant,
                        sourceIndex = e.SpawnerEntity and e.SpawnerEntity.Index,
                    pos = e.Position,
                    vel = e.Velocity,
                    speed = e.Velocity:Length(),
                    radius = radius,
                    kind = "effect",
                    variant = variant,
                    damage = damage > 0 and damage or 1,
                }
            end
        end
    end

    tracker:update(entries, frame, "effect")
end

return EffectSensor
