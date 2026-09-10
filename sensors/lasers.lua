-- sensors/lasers.lua
-- 激光威胁采集（Phase 3.1 + 真几何版）
-- 激光 = 线段威胁，不同于弹幕的圆威胁
-- 几何模型：起点 Position → 终点 GetEndPoint() 的线段；
--   旋转激光记录角速度（RotationSpd 优先，LastAngleDegrees 差分兜底），
--   hazard_query 用角度外推未来帧的扫掠线段
-- API 全部来自 auto_dodge_helper 验证过的 EntityLaser 属性（pcall 包裹）

local LaserSensor = {}

local EntityType = EntityType

--- 是否为敌方激光（排除玩家/跟班发射；排除友方实体发射）
local function isHostileLaser(e)
    if e.Type ~= EntityType.ENTITY_LASER then return false end
    -- 玩家/跟班发射的跳过
    local st = e.SpawnerType or 0
    if st == EntityType.ENTITY_PLAYER or st == EntityType.ENTITY_FAMILIAR then
        return false
    end
    -- 友方实体（被魅惑/道具生成的友方怪物）发射的激光 → 非威胁
    local okF, isFriendly = pcall(function()
        return e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
    end)
    if okF and isFriendly then return false end
    -- 发射源是友方实体 → 非威胁
    local spawner = e.SpawnerEntity
    if spawner then
        local okSF, spawnerFriendly = pcall(function()
            return spawner:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
        end)
        if okSF and spawnerFriendly then return false end
    end
    return true
end

--- 安全读取属性（pcall 防御，出错返回 fallback）
local function safeGet(entity, getter, fallback)
    local ok, v = pcall(getter, entity)
    if ok and v ~= nil then return v end
    return fallback
end

--- 采集当帧敌方激光并喂给追踪器
-- 激光的几何信息存储在 entry 的特殊字段：
--   entry.kind = "laser"
--   entry.pos = 起点（实体 Position）
--   entry.endPos = 终点（GetEndPoint；读不到时用角度×长度合成）
--   entry.angle = 当前朝向（度）；entry.rotSpd = 旋转角速度（度/帧）
--   entry.radius = 激光碰撞宽度半径
--   entry.vel 仅保留实体速度（移动型激光整体平移用）
function LaserSensor.collect(player, tracker, frame, config)
    if not config.hazardLasers then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okFind, entities = pcall(Isaac.FindByType, EntityType.ENTITY_LASER, -1, -1, false)
    if not okFind or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        if isHostileLaser(e) then
            local isDead = safeGet(e, function(x) return x:IsDead() end, true)
            if not isDead then
                local laser = safeGet(e, function(x) return x:ToLaser() end, nil)
                count = count + 1
                if laser then
                    local radius = safeGet(laser, function(l) return l.Radius or 6 end, 6)
                    -- 终点：GetEndPoint 优先，EndPoint 属性兜底
                    local endPos = safeGet(laser, function(l) return l:GetEndPoint() end, nil)
                    if endPos == nil then
                        endPos = safeGet(laser, function(l) return l.EndPoint end, nil)
                    end
                    -- 朝向/角速度（度）。RotationSpd 直接读；读不到用相邻帧角度差分（LastAngleDegrees）
                    local angle = safeGet(laser, function(l) return l.AngleDegrees end, nil)
                    if angle == nil then
                        angle = safeGet(laser, function(l) return l.RotationDegrees end, 0)
                    end
                    local rotSpd = safeGet(laser, function(l) return l.RotationSpd end, nil)
                    if rotSpd == nil then
                        local lastAngle = safeGet(laser, function(l) return l.LastAngleDegrees end, nil)
                        if lastAngle ~= nil and angle ~= nil then
                            rotSpd = angle - lastAngle
                        else
                            rotSpd = 0
                        end
                    end
                    -- 长度：终点推算优先，MaxDistance/LaserLength 兜底，最终 400 默认
                    local length
                    if endPos then
                        local d = endPos - e.Position
                        length = d:Length()
                    else
                        length = safeGet(laser, function(l) return l.MaxDistance end, nil)
                            or safeGet(laser, function(l) return l.LaserLength end, nil)
                            or 400
                    end
                    entries[count] = {
                        index = e.Index, seed = e.InitSeed, entityType = e.Type, variant = e.Variant,
                        sourceIndex = e.SpawnerEntity and e.SpawnerEntity.Index,
                        pos = e.Position,
                        vel = e.Velocity,
                        speed = e.Velocity:Length(),
                        radius = radius,
                        kind = "laser",
                        endPos = endPos,
                        angle = angle or 0,
                        rotSpd = rotSpd or 0,
                        length = length,
                        damage = safeGet(laser, function(l) return l.CollisionDamage or 2 end, 2),
                    }
                else
                    -- ToLaser 读取失败（API 异常）：仍采集基础条目（威胁检测安全优先），
                    -- 几何退化为 pos 点 + vel 线段由 hazard_query 兜底处理
                    entries[count] = {
                        index = e.Index, seed = e.InitSeed, entityType = e.Type, variant = e.Variant,
                        sourceIndex = e.SpawnerEntity and e.SpawnerEntity.Index,
                        pos = e.Position,
                        vel = e.Velocity,
                        speed = e.Velocity:Length(),
                        radius = safeGet(e, function(x) return x.Size or 6 end, 6),
                        kind = "laser",
                        endPos = nil,
                        angle = 0,
                        rotSpd = 0,
                        length = 0,
                        damage = safeGet(e, function(x) return x.CollisionDamage or 2 end, 2),
                    }
                end
            end
        end
    end

    tracker:update(entries, frame, "laser")
end

return LaserSensor
