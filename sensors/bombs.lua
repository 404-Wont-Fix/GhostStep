-- 炸弹采集：爆圈是一个"定时一次性事件"，不是长期存在的实心禁区。
--
-- 为什么不再用 EntityBomb.ExplosionCountdown：
--   Isaac 的 Lua API 里 EntityBomb 只有写接口 SetExplosionCountdown，没有只读引信
--   （https://wofsauge.github.io/IsaacDocs/rep/EntityBomb.html 变量只有 ExplosionDamage /
--    Flags / IsFetus / RadiusMultiplier）。回放里 408/408 录到 nil，于是
--   threat/geometry.lua 的 window() 退回 (0, math.huge) → 90px 爆圈被当成"立刻且永久"，
--   所有候选都判"在爆圈里" → 搜索完不成、没有更优解 → 输出在"不动"与"180° 反向猛推"间抽抽。
--
-- 现在的模型：
--   引信可读 → 直接用（appearFrame = frame + countdown）
--   引信不可读 → 按变体给默认值（普通 90 帧；巨魔/追踪 45 帧，取 wiki 1.5~2.5s 的下限），
--                 从"第一次看到这颗炸弹的帧"倒计时（tracker 的 firstFrame 就是它），
--                 并把预估爆炸帧往前提 bombFuseSafetyLead 帧（炸弹可能在观测前就已经点着）。
--   预估已过期但炸弹还在 → 按 bombFuseStaleLead 帧内必炸处置（重新武装，不复活 (0,∞)）。
-- 爆圈只在 [appearFrame, endFrame] 生效 → 玩家可以先站着、到点再离开 90px 圈，
-- 巨魔炸弹追着玩家跑时也只会给出一个明确的"往哪边跑出爆圈"方向。
local Bombs = {}

local function get(e, fn, fallback)
    local ok, v = pcall(fn, e)
    if ok and v ~= nil then return v end
    return fallback
end

-- 巨魔炸弹家族（entities2.xml id=4）：
--   3 Troll Bomb / 4 Megatroll Bomb / 8 Hot Troll Bomb / 18 Golden Troll Bomb
-- 它们会追着玩家跑，且引信是随机的（wiki: Megatroll 1.5~2.5s）。
local TROLL_VARIANTS = { [3] = true, [4] = true, [8] = true, [18] = true }

-- 自身在移动的炸弹（追着玩家跑/正在飞）
-- 回放实测（session_20260911_000240，bomb:655）：追踪炸弹以 **10px/帧** 扑向玩家，
-- 而玩家只有 3~4px/帧 → **“站着等到快爆炸再跑”是躲不掉的**（用户 2026-09-13 反馈）。
-- 所以这类炸弹的危险窗口必须从“现在”开始，而不是只盖爆炸帧；反过来说，
-- 停止不动地在玩家身边等着炸的炸弹（speed≈0）仍然走“定时爆炸”模型。
--- 是否需要“现在就躲”（而不是等到快爆炸再躲）：
---   ① 正在朝玩家移动（自报速度≥阈值且方向对着玩家）——它比你快，等爆炸就来不及了；
---   ② 巨魔炸弹家族只要靠得够近就算——它们的引信是随机的（wiki 1.5~2.5s），而且会
---      “扑一下 → 停 → 再扑”，停住时速度≈ 0，只靠速度判会漏掉“歇口气再扑”的那一段；
---      停下来之前它会先跳到离你 ~45px 的地方（回放 bomb:655 实测），所以近身就得离开。
local function isChasing(pos, vel, speed, playerPos, variant, radius, config)
    if not playerPos then return false end
    local dx, dy = playerPos.X - pos.X, playerPos.Y - pos.Y
    local dist = math.sqrt(dx * dx + dy * dy)
    local minSpeed = (config and config.bombChaseMinSpeed) or 0.5
    if speed >= minSpeed then
        if dist < 0.001 then return true end
        local cos = (dx * vel.X + dy * vel.Y) / (dist * speed)
        if cos >= ((config and config.bombChaseCos) or 0.5) then return true end
    end
    if TROLL_VARIANTS[variant] then
        local alert = radius + ((config and config.bombTrollAlertRadius) or 40)
        if dist <= alert then return true end
    end
    return false
end

function Bombs.fuseFramesFor(variant, config)
    if TROLL_VARIANTS[variant] then
        return (config and config.bombTrollFuseFrames) or 45
    end
    return (config and config.bombFuseFrames) or 90
end

--- 预估爆炸帧：把"第一次看到"当成"刚点着"是最保守的可计算假设；
--- 预估已经过期（炸弹却还活着）时给一个很短的重新武装窗口，避免爆圈再次变成永久禁区。
--- @return appearFrame, fuseSource
function Bombs.explosionFrame(frame, firstSeen, variant, config, countdown)
    if type(countdown) == 'number' and countdown >= 0 then
        return frame + countdown, 'engine'
    end
    local fuse = Bombs.fuseFramesFor(variant, config)
    local lead = (config and config.bombFuseSafetyLead) or 6
    local estimated = (firstSeen or frame) + fuse - lead
    local staleLead = (config and config.bombFuseStaleLead) or 6
    if estimated < frame + staleLead then
        return frame + staleLead, 'stale'
    end
    return estimated, 'variant'
end

function Bombs.collect(player, tracker, frame, config)
    if not config.hazardBombs then tracker:clear(); return end
    -- 追踪炸弹这一类（巨魔炸弹家族：会追着玩家跑、然后自爆）单独开关：
    -- 关闭 = **完全不处理**（不采集、不躲，也不会退化成"普通炸弹"再套一遍机制）——
    -- 用户 2026-09-13 明确要求：“关掉那就不处理，普通炸弹的躲避机制也别套上去，
    -- 否则跟没关没区别”。普通炸弹（以及玩家自己扔的炸弹）不受影响。
    local chasingEnabled = config.dodgeChasingBombs ~= false
    local ok, entities = pcall(Isaac.FindByType, EntityType.ENTITY_BOMB, -1, -1, false)
    if not ok or not entities then return end
    local tracked = tracker.tracked or {}
    local entries = {}
    for i = 1, #entities do
        local e = entities[i]
        if (not get(e, function(x) return x:IsDead() end, true))
            and not (not chasingEnabled and TROLL_VARIANTS[e.Variant]) then
            local bomb = get(e, function(x) return x:ToBomb() end, e)
            local countdown = get(bomb, function(x) return x.ExplosionCountdown end, nil)
            if type(countdown) ~= 'number' or countdown < 0 then countdown = nil end
            local damage = get(bomb, function(x) return x.ExplosionDamage end, 12)
            if damage > 0 then
                -- tracker.tracked[index].firstFrame = 这颗炸弹第一次被看到的帧
                -- （房间切换 tracker:clear() 会自动复位，不需要额外的传感器状态）
                local previous = tracked[e.Index]
                local firstSeen = (previous and previous.firstFrame) or frame
                local speed = e.Velocity:Length()
                local est, fuseSource = Bombs.explosionFrame(frame, firstSeen, e.Variant, config, countdown)
                local radius = 90 * get(bomb, function(x) return x.RadiusMultiplier end, 1)
                -- 追踪炸弹单独开关（MCM 危险源 → “躲避追踪炸弹”）：关掉时上面的
                -- 巨魔炸弹家族已经被整个跳过（连普通炸弹机制都不套）；这里再关掉
                -- “动态判定在追我”的通道，其它变体也就不会拿到“从现在就开始躲”的待遇。
                local chasing = chasingEnabled
                    and isChasing(e.Position, e.Velocity, speed, player and player.position,
                        e.Variant, radius, config)
                local appearFrame, endFrame = est, est + 2
                if chasing then
                    -- 追着跑的炸弹：危险从“现在”开始，一直盖到预估爆炸帧。
                    -- 等到爆炸再跑就来不及了（它比你快），必须现在就拉开距离/侧向脱离。
                    local staleLead = (config and config.bombFuseStaleLead) or 6
                    if est < frame + staleLead then est = frame + staleLead end
                    appearFrame, endFrame, fuseSource = frame, est + 2, fuseSource .. '+chase'
                end
                entries[#entries + 1] = {
                    index = e.Index, seed = e.InitSeed, kind = 'bomb', entityType = e.Type, variant = e.Variant,
                    sourceIndex = e.SpawnerEntity and e.SpawnerEntity.Index, ownerType = e.SpawnerType,
                    pos = e.Position, vel = e.Velocity, speed = speed,
                    radius = radius, damage = damage,
                    -- 接触伤害为 0（entities2.xml id=4 全部 collisionDamage=0）→ 只有爆圈会伤人。
                    -- 静止炸弹：危险窗口 = 预估爆炸帧（可以先路过、到点再走）。
                    -- 追踪炸弹：危险窗口 = [现在, 预估爆炸帧]（必须一直拉开距离）。
                    fuseFrames = appearFrame - frame,
                    appearFrame = appearFrame,
                    endFrame = endFrame,
                    firstSeenFrame = firstSeen,
                    fuseSource = fuseSource,
                    chasing = chasing,
                    -- “在追我”那一刻锁定的玩家位置：future_motion 用它做“到位就停”的外推
                    chaseTargetX = chasing and player and player.position and player.position.X or nil,
                    chaseTargetY = chasing and player and player.position and player.position.Y or nil,
                    timingKnown = countdown ~= nil,
                    confidence = countdown and 1 or 0.5,
                }
            end
        end
    end
    tracker:update(entries, frame, 'bomb')
end

return Bombs
