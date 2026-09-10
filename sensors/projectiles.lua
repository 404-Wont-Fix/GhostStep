-- sensors/projectiles.lua
-- 弹幕采集与分类（Phase 1：直线弹幕；Phase 2 扩展运动模式）
-- 含归属判定链式追踪（7.5.5：Parent→ParentNPC→SpawnerEntity，深度≤4，NPC优先，缓存180帧）
-- 所有 entity 访问均 pcall 包裹防崩溃

local ProjectileSensor = {}
local Priority = require("threat/priority")

local EntityType = EntityType
local playerType = EntityType.ENTITY_PLAYER
local familiarType = EntityType.ENTITY_FAMILIAR

--- 归属缓存（房间级重置）。[index] = { hostile=bool, frame=确认帧 }
local ownershipCache = {}

--- NPC 归属检测：递归向上追踪（7.5.5）
--- 跳过友方实体（FLAG_FRIENDLY）：道具生成的友方怪物是 NPC 但不应视为威胁源
local function hasNpcOwnerInChain(entity, depth)
    if not entity or depth > 4 then return false end
    local t = entity.Type
    if t == playerType or t == familiarType then return false end -- 玩家/跟班不是NPC
    -- 友方实体（被魅惑/道具生成的友方怪物）→ 非威胁，停止追踪此分支
    local okF, isFriendly = pcall(function()
        return entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
    end)
    if okF and isFriendly then return false end
    -- 是否为敌对 NPC
    local ok, result = pcall(function()
        return (entity.ToNPC ~= nil and entity:ToNPC() ~= nil) or (entity.IsEnemy ~= nil and entity:IsEnemy())
    end)
    if ok and result == true then return true end
    -- 递归向上：Parent → ParentNPC → SpawnerEntity
    if hasNpcOwnerInChain(entity.Parent, depth + 1) then return true end
    if hasNpcOwnerInChain(entity.ParentNPC, depth + 1) then return true end
    return hasNpcOwnerInChain(entity.SpawnerEntity, depth + 1)
end

--- 分类弹幕：NPC优先 → 玩家次之 → 默认敌方（安全优先）
--- 返回 true=敌方（需躲避）
local function classify(proj, frame, cacheTtl)
    local idx = proj.Index
    local cached = ownershipCache[idx]
    if cached and cached.seed == proj.InitSeed and (frame - cached.frame) < cacheTtl then
        return cached.hostile
    end

    local hostile
    -- 弹幕自身带 FLAG_FRIENDLY → 直接判定为友方（最快路径）
    local okPF, projFriendly = pcall(function()
        return proj:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
    end)
    if okPF and projFriendly then
        hostile = false
    else
        local ok, chainResult = pcall(hasNpcOwnerInChain, proj, 0)
        if ok and chainResult then
            hostile = true
        else
            local spawnerType = proj.SpawnerType or 0
            if spawnerType == playerType or spawnerType == familiarType then
                hostile = false
            else
                hostile = true -- 未知归属 → 默认敌方
            end
        end
    end

    -- NPC 归属一旦确认不可覆盖为友方
    if cached and cached.seed == proj.InitSeed and cached.hostile and not hostile then
        return true
    end

    ownershipCache[idx] = { hostile = hostile, frame = frame, seed = proj.InitSeed }
    return hostile
end

--- 安全读取实体属性（死亡判定等），出错返回 fallback
local function safeProp(proj, getter, fallback)
    local ok, v = pcall(getter, proj)
    if ok then return v end
    return fallback
end

--- 诊断日志状态（须声明在 clearOwnership 之前，否则重置的是全局变量）
local _projLoggedThisRoom = false
local _projLastCount = -1

--- 清空归属缓存（房间切换时由 main 调用）
function ProjectileSensor.clearOwnership()
    ownershipCache = {}
    _projLoggedThisRoom = false
    _projLastCount = -1
end

--- 采集当帧敌方弹幕并喂给追踪器
function ProjectileSensor.collect(player, tracker, frame, config)
    if not config.hazardProjectiles then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    -- 先尝试 FindByType 精准查询弹幕（autoaim 模式，比遍历全房间更稳）
    -- 再退回 GetRoomEntities 做兜底
    local entities
    local okFind, result = pcall(Isaac.FindByType, EntityType.ENTITY_PROJECTILE, -1, -1, false)
    if okFind and result ~= nil then
        entities = result
    else
        local okAll, result2 = pcall(Isaac.GetRoomEntities)
        if not okAll or result2 == nil then return end
        -- 过滤只保留 PROJECTILE 类型
        local filtered = {}
        for i = 1, #result2 do
            local e = result2[i]
            local okType, etype = pcall(function() return e.Type end)
            if okType and etype == EntityType.ENTITY_PROJECTILE then
                filtered[#filtered + 1] = e
            end
        end
        entities = filtered
    end

    -- 首次/进房后诊断日志（打一行，确认采集链在工作）
    if not _projLoggedThisRoom then
        _projLoggedThisRoom = true
        Isaac.DebugString(string.format(
            "[GhostStep3] 弹幕采集: FindByType=%s 总=%d 帧=%d",
            tostring(okFind), entities and #entities or 0, frame))
    end

    local entries, heap = {}, {}
    local count = 0
    local max = math.max(1, config.maxProjectiles or 300)
    local cacheTtl = config.ownershipCacheTtl

    for i = 1, #entities do
        local proj = entities[i]

        local isDead = safeProp(proj, function(e) return e:IsDead() end, true)
        if not isDead then
            local okClass, hostile = pcall(classify, proj, frame, cacheTtl)
            if okClass and hostile then
                count = count + 1
                local entry = {
                    kind = "projectile", seed = proj.InitSeed,
                    entityType = proj.Type, variant = proj.Variant,
                    index = proj.Index,
                        sourceIndex = proj.SpawnerEntity and proj.SpawnerEntity.Index,
                    pos = proj.Position,
                    vel = proj.Velocity,
                    speed = proj.Velocity:Length(),
                    radius = proj.Size,
                    -- 伤害值（auto_dodge 模式: projectile.Damage 优先，CollisionDamage 兜底）
                    damage = safeProp(proj, function(p) return p.Damage or p.CollisionDamage or 1 end, 1),
                }
                Priority.offer(heap, entry, Priority.projectileKey(entry, player, config.plannerHorizon or 18), max)
            end
        end
    end

    for i=1,#heap do entries[i]=heap[i].value end
    tracker.observedCount, tracker.omittedCount = count, math.max(0,count-#entries)
    -- 弹幕结果：只在首次检测到/数量变化时打，避免刷屏
    if config.diagnosticsEnabled and count ~= (_projLastCount or 0) then
        Isaac.DebugString(string.format(
            "[GhostStep3] 弹幕结果: FindByType=%s 总=%d 敌方=%d",
            tostring(okFind), #entities, count))
        _projLastCount = count
    end
    _projLoggedThisRoom = true

    tracker:update(entries, frame, "projectile")
end

return ProjectileSensor
