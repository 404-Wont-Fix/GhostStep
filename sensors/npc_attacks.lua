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

--- Get entity-specific jump radius from profile table
local function getJumpRadius(entityType)
    return Profiles.jumpRadiusByType[entityType] or Profiles.defaultJumpRadius
end

--- Get player position (for laser direction calculation)
local function getPlayerPosition()
    local ok, player = pcall(Isaac.GetPlayer, 0)
    if ok and player then return player.Position end
    return nil
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

--- Build tracker entry from attack detection
--- Returns {pos, vel, speed, radius, kind, fuseFrames?, appearFrame?, ...} or nil
local function buildEntry(entity, attackEntry, frame, config)
    local cat=attackEntry.category
    local profile=Profiles.categories[cat]
    if not profile then return nil end
    local okFrame,animFrame=pcall(function() return entity:GetSprite():GetFrame() end)
    animFrame=okFrame and type(animFrame)=="number" and animFrame or 0
    local remaining=math.max(0,(attackEntry.windupFrames or 0)-animFrame)
    local radius=profile.radius or getJumpRadius(entity.Type)
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
                local attackEntry = findAttackEntry(e.Type, e.Variant, animLower)
                if attackEntry then
                    local okBuild, entry = pcall(buildEntry, e, attackEntry, frame, config)
                    if okBuild and entry then
                        count = count + 1
                        entries[count] = entry
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
    -- No state to reset (stateless sensor)
end

return NpcAttackSensor
