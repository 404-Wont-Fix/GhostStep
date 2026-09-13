-- sensors/npc_attacks.lua
-- NPC attack pre-fire detection (Phase 3.4 + Tier 1 table-driven refactor)
-- Scans NPCs for known attack animations (from data/npc_animdb.lua),
-- generates threat entries using category profiles (from data/npc_profiles.lua).
--
-- Tier 1 additions:
--   - fuseFrames: windup countdown → feeds into threat_level urgency (reuse bomb fuse mechanism)
--   - appearFrame: when the attack actually hits → future_motion "not yet existing" logic
--   - Table-driven: all NPC type + animation mappings in data/npc_animdb.lua
--
-- Coverage: stomping (Daddy Long Legs), jumping (Mom's Hand, Widow, Leaper),
--   laser windup (Vis, Maw, Bloat, Adversary), ranged (Horf, Gatling Gurdy)

local NpcAttackSensor = {}

local EntityType = EntityType
local Profiles = require("data/npc_profiles")

-- Load animation database (pcall: file missing = no coverage = graceful degradation)
local okAnimDB, animDB = pcall(require, "data/npc_animdb")
if not okAnimDB then animDB = nil end

-- ===== Animation lookup =====

--- Safe lowercase animation name read
--- 安全读动画名（小写）
local function safeAnimationLower(entity)
    local okSprite, sprite = pcall(function() return entity:GetSprite() end)
    if not okSprite or sprite == nil then return "" end
    local okAnim, anim = pcall(function() return sprite:GetAnimation() end)
    if not okAnim or type(anim) ~= "string" then return "" end
    return string.lower(anim)
end

--- Find attack animation entry from animDB for this entity + current animation
--- Returns {name, totalFrames, windupFrames, category} or nil
local function findAttackEntry(entityType, entityVariant, animLower)
    if not animDB then return nil end
    local key = tostring(entityType) .. ":" .. tostring(entityVariant or 0)
    local entries = animDB[key]
    if not entries then return nil end
    -- Check if current animation matches any attack animation (case-insensitive)
    for i = 1, #entries do
        local e = entries[i]
        if string.lower(e.name) == animLower then
            return e
        end
    end
    return nil
end

--- Animations to exclude (death/appear transitions are not attacks)
local EXCLUDE_TOKENS = { "death", "appear" }
local function isExcludedAnimation(anim)
    for i = 1, #EXCLUDE_TOKENS do
        if string.find(anim, EXCLUDE_TOKENS[i], 1, true) then return true end
    end
    return false
end

-- 缺库诊断：敌人正在播一个“看起来像攻击”的动画，但动画库里没有对应条目。
-- 这是“动画库到底有没有用、缺什么”的直接答案（log.txt 里可查）。
-- 例：29:1 Trite 的跳跃动画叫 Hop，旧库里因为 "hopping" 被 --high-value-only
-- 过滤掉而只剩 BigJumpUp → 永远匹配不上 → 整条链对跳蛛失效（已修）。
local ATTACK_HINT_WORDS = { "attack", "shoot", "spit", "throw", "fire", "laser",
    "brimstone", "beam", "charge", "cast", "summon", "stomp", "jump", "hop", "leap",
    -- 近战/砸击类关键字：Mother 的 wristattack/scrapeattack/groundpound/swipe 就属于这一类，
    -- 旧表没收录 → 既不会进 anim_missing 清单，也拿不到"大体积敌人攻击期扩圈"的兜底。
    "smash", "slam", "punch", "swipe", "scrape", "wrist", "chomp", "pound", "kick", "slash" }
local _missingLogged = {}
local _missingCount = 0
local _missingEvents = {}
local MISSING_LOG_MAX = 40
local function looksLikeAttackAnim(animLower)
    for i = 1, #ATTACK_HINT_WORDS do
        if string.find(animLower, ATTACK_HINT_WORDS[i], 1, true) then return true end
    end
    return false
end
local function noteMissingAnim(e, animLower, frame)
    if _missingCount >= MISSING_LOG_MAX then return end
    local key = tostring(e.Type) .. ":" .. tostring(e.Variant or 0) .. ":" .. animLower
    if _missingLogged[key] then return end
    _missingLogged[key] = true
    _missingCount = _missingCount + 1
    _missingEvents[#_missingEvents + 1] = { ev = "anim_missing", frame = frame,
        entityType = e.Type, variant = e.Variant, animation = animLower }
    Isaac.DebugString(string.format(
        "[GhostStep3] 动画库缺条目: type=%d variant=%s anim=%s（需重跑 tools/parse_animations.py）帧=%d",
        e.Type, tostring(e.Variant or 0), animLower, frame))
end

--- Get entity-specific jump radius from profile table
local function getJumpRadius(entityType)
    return Profiles.jumpRadiusByType[entityType] or Profiles.defaultJumpRadius
end

--- 砸击落点半径（kind=slam）：按实体类型查表，缺省 defaultSlamRadius
local function getSlamRadius(entityType)
    return Profiles.slamRadiusByType[entityType] or Profiles.defaultSlamRadius
end

-- ===== 砸击落点锁定 =====
-- 回放教训（Mother 战，session_20260913_223945）：
--   落点必须在"起手那一刻"锁死。每帧重算成当前玩家位置 = 禁区跟着玩家跑 =
--   玩家永远逃不出去（炸弹爆圈被当成永久禁区那次就是这个病）。
-- 同一实体连续放同一套动画时，用动画帧回退（重新起播）判定"新一次砸击"。
local _aim = {}

--- 精灵动画帧（读不到就 0；用于“动画剩余帧数”窗口）
local function spriteFrameOf(entity)
    local ok, f = pcall(function() return entity:GetSprite():GetFrame() end)
    return (ok and type(f) == 'number') and f or 0
end

--- 大体积敌人"未建模攻击动画"的安全网：
--- 精灵在播攻击类动画、但动画库里查不到条目时，至少把危险半径撑大
--- （回放证据：Mother 本体 Size=110，玩家在 128~140px 处被挥臂/刮地打到，
---   而 110+10=120 的接触圈判"安全"）。杂兵（Size < bossAttackReachMinSize）不扩圈。
local function buildUnknownAttackEntry(entity, frame, config, attackEntry)
    local reach = config and config.bossAttackReach
    if not reach or reach <= 0 then return nil end
    local minSize = (config and config.bossAttackReachMinSize) or 40
    local okSize, size = pcall(function() return entity.Size end)
    size = (okSize and type(size) == 'number') and size or 0
    if size < minSize then return nil end
    local vel = entity.Velocity or Vector(0, 0)
    -- 危险窗口要够长，否则“逃出去”和“站着不动”在所有候选里都算命中（窗口只有 1~2 帧时
    -- 谁都没法在窗口内离开），风险差被抹平 → 平手 → 退化成不介入。
    -- 已建模的动画按“动画剩余帧数”，未建模的用 bossAttackReachFrames。
    local span
    if attackEntry then
        local animFrame = spriteFrameOf(entity)
        span = math.max(1, (attackEntry.totalFrames or animFrame + 6) - animFrame)
    else
        span = (config and config.bossAttackReachFrames) or 18
    end
    return { index = entity.Index + 20000, seed = entity.InitSeed, sourceIndex = entity.Index,
        entityType = entity.Type, variant = entity.Variant, kind = 'enemy',
        pos = entity.Position, vel = vel, speed = vel:Length(),
        radius = size + reach, damage = 1,
        appearFrame = frame, endFrame = frame + span,   -- 每帧续期；动画停下就不再生效
        predicted = true, animation = (attackEntry and attackEntry.name) or 'unknown',
        unknownAttack = true,
        rule = tostring(entity.Type) .. ":" .. tostring(entity.Variant or 0) .. ":guard",
        confidence = 0.4 }
end

--- Get player position (for laser direction calculation)
local function getPlayerPosition()
    local ok, player = pcall(Isaac.GetPlayer, 0)
    if ok and player then return player.Position end
    return nil
end

--- 砸击落点 = 起手帧的玩家位置（锁死，不跟随；见 _aim 注释）
local function aimPoint(entity, attackEntry, animFrame, frame)
    local key = entity.Index
    local prev = _aim[key]
    if prev and prev.anim == attackEntry.name and animFrame >= (prev.animFrame or 0) then
        return prev.x, prev.y
    end
    local target = getPlayerPosition() or entity.Position
    _aim[key] = { anim = attackEntry.name, animFrame = animFrame, x = target.X, y = target.Y, frame = frame }
    return target.X, target.Y
end

--- 走廊长度：沿 dir 采样到房间外（墙）为止。
--- 旧实现固定 pathLength=160 直接把整条射线当致死区；按实际到墙距离缩短后
--- 才能"在机关面前穿过去"（间隔大时留出可穿越窗口）。
local function corridorLength(room, pos, dir, maxLen)
    if not room or not room.IsPositionInRoom or not dir then return maxLen end
    local step = 16
    local d = step
    while d <= maxLen do
        local ok, inside = pcall(function() return room:IsPositionInRoom(pos + dir * d, 0) end)
        if not ok or not inside then return d end
        d = d + step
    end
    return maxLen
end

--- 近战类分类：危险集中在"身体附近"，因此除了精确形状，还要给大体积敌人一个扩圈兜底。
--- 回放依据（Mother 912:0）：她的双手在 anm2 里左右各摊到 ±206px，玩家站在离她中心
--- 130px 处仍在手部 hitbox 范围内；瞄准型砸击只覆盖"起手时玩家站的那个点"，
--- 玩家一旦走动就可能又落回手部范围 → 两个模型合起来才盖得上实测的 128~140px 挨打点。
local CLOSE_QUARTERS = { slam = true, melee = true, stomping = true, jumping = true,
    hopping = true, charge = true }
local function isCloseQuartersCategory(cat)
    return CLOSE_QUARTERS[cat] == true
end

--- Build tracker entry from attack detection
--- Returns {pos, vel, speed, radius, kind, fuseFrames?, appearFrame?, ...} or nil
local function buildEntry(entity, attackEntry, frame, config)
    local cat=attackEntry.category
    local profile=Profiles.categories[cat]
    if not profile then return nil end
    local okFrame,animFrame=pcall(function() return entity:GetSprite():GetFrame() end)
    animFrame=okFrame and type(animFrame)=="number" and animFrame or 0
    local remaining=math.max(0,(attackEntry.windupFrames or 0)-animFrame)
    local radius=profile.radius or (profile.radiusFrom=="slamRadius" and getSlamRadius(entity.Type)) or getJumpRadius(entity.Type)
    if cat=="ranged" and config and config.rangedCorridorRadius then
        radius=config.rangedCorridorRadius
    end
    local entry={index=entity.Index+10000,seed=entity.InitSeed,sourceIndex=entity.Index,
        entityType=entity.Type,variant=entity.Variant,kind=profile.kind,
        pos=entity.Position,vel=Vector(0,0),speed=0,radius=radius,
        fuseFrames=remaining,appearFrame=frame+remaining,
        endFrame=frame+math.max(1,(attackEntry.totalFrames or animFrame+6)-animFrame),
        predicted=true,animation=attackEntry.name,animationFrame=animFrame,
        rule=tostring(entity.Type)..":"..tostring(entity.Variant or 0)..":"..attackEntry.name,
        confidence=0.55,uncertainty=3}
    if cat=="jumping" then
        -- 落点按剩余前摇外推；着地后不继续漂移。记录模型来源供实机校准。
        entry.pos=entity.Position+entity.Velocity*(profile.velScale or 0)*remaining
    elseif cat=="slam" then
        -- 瞄准型砸击：落点锁在起手帧的玩家位置（见 aimPoint 的注释）
        local ax,ay=aimPoint(entity,attackEntry,animFrame,frame)
        entry.pos=Vector(ax,ay)
        entry.aimLocked=true
        entry.aimSource="player_start"
    elseif cat=="laser" or cat=="ranged" then
        local name=string.lower(attackEntry.name)
        local dir
        for token,v in pairs({up=Vector(0,-1),down=Vector(0,1),left=Vector(-1,0),right=Vector(1,0)}) do
            if string.find(name,token,1,true) then dir=v; entry.confidence=0.75; break end
        end
        if not dir then
            local target=getPlayerPosition()
            if not target then return nil end
            dir=(target-entry.pos):Normalized()
        end
        local maxLen=profile.pathLength or 480
        if config and config.rangedCorridorMaxLen and cat=="ranged" then
            maxLen=config.rangedCorridorMaxLen
        end
        local room
        local okGame, game = pcall(Game)
        if okGame and game then
            local okGet, r = pcall(function() return game:GetRoom() end)
            if okGet then room = r end
        end
        entry.length=(cat=="ranged") and corridorLength(room,entry.pos,dir,maxLen) or maxLen
        entry.endPos=entry.pos+dir*entry.length
        entry.targetMode=entry.confidence>0.6 and "animation_direction" or "player_estimate"
    end
    return entry
end

-- ===== Public API =====

--- Collect active NPC attack precursors into tracker
function NpcAttackSensor.collect(player, tracker, frame, config)
    if not config.hazardNpcAttacks then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    -- If animDB failed to load, no coverage: clear and return
    if not animDB then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okAll, entities = pcall(Isaac.GetRoomEntities)
    if not okAll or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        local okNpc, isNpc = pcall(function()
            return e.ToNPC ~= nil and e:ToNPC() ~= nil and e:IsActiveEnemy() and not e:IsDead()
                and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
        end)
        if okNpc and isNpc then
            local animLower = safeAnimationLower(e)
            if animLower ~= "" and not isExcludedAnimation(animLower) then
                -- 跳跃型敌人交给 entities/hop_tracker.lua 的“瞄准落点”模型：
                -- npc_attacks 的 jumping 形状是 pos + vel*0.75*剩余前摇，而跳蛛前摇时
                -- 速度≈ 0（它是朝玩家跳的）→ 算出来的落点就是它站着的位置，等于没用。
                local handledByHop = config.hopPredict and config.hopTypes and config.hopTypes[e.Type]
                if handledByHop then
                    -- 但“精灵播着跳跃动画”这件事仍有用：hop 链自己会读（见 entities/hop_tracker）
                else
                    local attackEntry = findAttackEntry(e.Type, e.Variant, animLower)
                    if not attackEntry then
                        if looksLikeAttackAnim(animLower) then
                            noteMissingAnim(e, animLower, frame)
                            -- 缺条目也要有兜底：大体积敌人播攻击类动画时先把危险半径撑大
                            local okRaw, raw = pcall(buildUnknownAttackEntry, e, frame, config)
                            if okRaw and raw then
                                count = count + 1
                                entries[count] = raw
                            end
                        end
                    else
                        local okBuild, entry = pcall(buildEntry, e, attackEntry, frame, config)
                        if okBuild and entry then
                            count = count + 1
                            entries[count] = entry
                            -- 近战/砸击类即使有精确模型，再给一份"攻击期扩圈"（见 CLOSE_QUARTERS）
                            if isCloseQuartersCategory(attackEntry.category) then
                                local okRaw, raw = pcall(buildUnknownAttackEntry, e, frame, config, attackEntry)
                                if okRaw and raw then
                                    count = count + 1
                                    entries[count] = raw
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 动画结束即撤销旧前兆，避免历史预测继续制造虚假危险。
    local seen={}
    for i=1,#entries do seen[entries[i].index]=true end
    for index in pairs(tracker.tracked) do
        if not seen[index] then tracker.tracked[index]=nil; tracker.count=tracker.count-1 end
    end
    tracker:update(entries, frame, "npc_attack")
end

function NpcAttackSensor.resetRoom()
    -- 房间切换复位（缺库诊断每房间重新记）；砸击落点锁定也不能跨房间用
    _missingLogged = {}
    _missingCount = 0
    _aim = {}
end

--- 取出并清空“动画库缺条目”事件（main.lua 写入回放，供离线列缺口清单）
function NpcAttackSensor.takeEvents()
    local evs = _missingEvents
    _missingEvents = {}
    return evs
end

return NpcAttackSensor
