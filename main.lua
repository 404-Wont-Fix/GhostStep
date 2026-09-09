-- main.lua
-- GhostStep3 — 预测式人机共驾
-- 架构: Sensors → Threat Engine → Decision Pipeline → Input Synthesizer → MC_INPUT_ACTION
--
-- 玩家输入优先；危险时进行最小必要修正；Alt 关闭后完全释放移动 hook。
-- 规划、采集和写盘均记录预算/覆盖范围，不把模型预测作为无伤保证。

local GhostStep3 = RegisterMod("GhostStep3", 1)
_G.GhostStep3 = GhostStep3

-- ===== 模块加载（require 路径以 mod 根目录为基准）=====
local Defaults          = require("config/defaults")
local Presets           = require("config/presets")
local Runtime           = require("config/runtime")
local SafeCall          = require("utils/safe_call")
local Tracker           = require("entities/tracker")
local Registry          = require("sensors/registry")
local Terrain           = require("sensors/terrain")
local ProjectileSensor  = require("sensors/projectiles")
local EnemySensor       = require("sensors/enemies")
local LaserSensor       = require("sensors/lasers")
local BombSensor        = require("sensors/bombs")
local EffectSensor      = require("sensors/effects")
local NpcAttackSensor   = require("sensors/npc_attacks")
local PlayerSensor      = require("sensors/player")
local HazardQuery       = require("threat/hazard_query")
local FutureMotion      = require("threat/future_motion")
local Pipeline          = require("decision/pipeline")
local InputReader       = require("control/input_reader")
local Motion = require("control/motion_model")
local AvoidanceDiagnostics=require("control/avoidance_diagnostics")
local EventBuffer = require("recording/event_buffer")
local InputWriter       = require("control/input_writer")
local Overlay           = require("render/overlay")
local RingBuffer        = require("recording/ring_buffer")
local Snapshot          = require("recording/snapshot")
local DeathReplay       = require("recording/death_replay")
local SessionRecorder   = require("recording/session_recorder")
local MCM               = require("config/mcm")

-- json 为游戏内置模块；加载失败则文件录制自动禁用
local hasJson, json = pcall(require, "json")
local jsonEncode = hasJson and json.encode or require("utils/json_encode")

-- ===== 全局装配 =====
local okBuild, buildInfo = pcall(require,"config/build")
local Config = Defaults.get()
local state = Runtime.create(Config)

local tracker = Tracker.create()
local trackerEnemies = Tracker.create() -- 敌人接触威胁（独立过期周期）
local trackerLasers = Tracker.create()  -- 激光威胁（kind=laser）
local trackerBombs = Tracker.create()   -- 炸弹威胁（kind=bomb）
local trackerEffects = Tracker.create() -- 效果威胁（kind=effect）
local trackerNpcAttacks = Tracker.create() -- NPC攻击前兆（kind=npc_attack）
local terrain = Terrain.create()
local hazardQuery = HazardQuery.create()

-- 战斗状态（动态节流用，模式2）
-- 注: Room:GetAliveEnemiesCount 在 Rep+ 未验证，用社区通用 IsClear()
local wasCombat = false
local function isCombat()
    local ok, room = pcall(function() return Game():GetRoom() end)
    if not ok or room == nil then return false end
    local okClear, isClear = pcall(function() return room:IsClear() end)
    if not okClear then return false end
    return not isClear
end

-- 传感器注册表（模式1+2+5）
local registry = Registry.create({
    config = Config,
    isCombat = isCombat,
})

-- 威胁合并视图：弹幕 + 敌人 + 激光 + 炸弹 + 效果 + NPC攻击前兆
-- 同帧 memoize：threat_level / hazard_query / fallback / 级别4快照各取一次，
-- 只构建一次合并列表（旧版同帧重复构建 3 次、每次全量分配新表）
local hazardSources = { trackerEnemies, trackerLasers, trackerBombs, trackerEffects, trackerNpcAttacks }
local hazardsCache, hazardsCacheFrame = nil, -1
local function getHazards(frame)
    if hazardsCacheFrame == frame then return hazardsCache end
    local hz = tracker:getActive(0, frame)
    for _, src in ipairs(hazardSources) do
        local items = src:getActive(0, frame)
        for i = 1, #items do hz[#hz + 1] = items[i] end
    end
    -- 实际攻击生成后撤销对应前兆。只有本次前摇期间生成的实体才可匹配。
    local live={}
    for i=1,#hz do
        local h=hz[i]
        if not h.predicted and h.sourceIndex then
            live[h.sourceIndex]=math.max(live[h.sourceIndex] or -1,h.firstFrame or frame)
        end
    end
    local merged={}
    state.forecastMatches={}
    state.forecastMatched=state.forecastMatched or {}
    for i=1,#hz do
        local h=hz[i]
        local spawned=h.predicted and live[h.sourceIndex]
        if not spawned or spawned<math.max(h.firstFrame or frame,(h.appearFrame or frame)-3) then
            merged[#merged+1]=h
        else
            local key=tostring(h.id)..":"..tostring(spawned)
            if not state.forecastMatched[key] then
                state.forecastMatched[key]=true
                state.forecastMatches[#state.forecastMatches+1]={ev="forecast_match",frame=frame,rule=h.rule,
                    sourceIndex=h.sourceIndex,observed="entity_first_seen",association="source_and_time",
                    predictedFrame=h.appearFrame,observedFrame=spawned,timingErrorFrames=h.appearFrame and spawned-h.appearFrame}
            end
        end
    end
    hz=merged
    hazardsCache, hazardsCacheFrame = hz, frame
    return hz
end

registry:register({
    name = "player",
    combatInterval = 1,
    idleInterval = 1, -- 玩家状态永远每帧
    collect = function(st, frame)
        PlayerSensor.collect(st, frame)
    end,
})
registry:register({
    name = "projectiles", idleInterval = 1,
    collect = function(st, frame)
        ProjectileSensor.collect(st.player, tracker, frame, Config)
    end,
})
registry:register({
    name = "enemies", idleInterval = 1,
    collect = function(st, frame)
        EnemySensor.collect(st.player, trackerEnemies, frame, Config)
    end,
})
registry:register({
    name = "lasers", idleInterval = 1,
    collect = function(st, frame)
        LaserSensor.collect(st.player, trackerLasers, frame, Config)
    end,
})
registry:register({
    name = "bombs", idleInterval = 1,
    collect = function(st, frame)
        BombSensor.collect(st.player, trackerBombs, frame, Config)
    end,
})
registry:register({
    name = "effects", idleInterval = 1,
    collect = function(st, frame)
        EffectSensor.collect(st.player, trackerEffects, frame, Config)
    end,
})
registry:register({
    name = "npc_attacks", idleInterval = 1,
    collect = function(st, frame)
        NpcAttackSensor.collect(st.player, trackerNpcAttacks, frame, Config)
    end,
})

-- 录制
local ringBuffer = RingBuffer.create(Config.replayBufferSeconds * 30)
state.ringBuffer = ringBuffer -- MCM 调试页只读展示用
local sessionRecorder = SessionRecorder.create(Config)
local eventBuffer = EventBuffer.create(Config)
local lastDiagnosticFrame = -9999
state.sessionRecorder = sessionRecorder -- MCM 录制页只读展示用

-- MCM（未安装时静默降级）
MCM.register({ mod = GhostStep3, state = state, presets = Presets })
MCM.loadSettings()

-- 开局或局中开启录制时都写版本、配置和下一帧地形关键帧。
local function startRecording()
    if not sessionRecorder.available or sessionRecorder.failed then return end
    local meta={}
    if okBuild and type(buildInfo)=="table" then meta.build=buildInfo
    else meta.buildError=tostring(buildInfo) end
    local okSeed,seed=pcall(function() return Game():GetSeeds():GetStartSeed() end)
    local okChar,char=pcall(function() return Isaac.GetPlayer(0):GetPlayerType() end)
    local okStage,stage=pcall(function() return Game():GetLevel():GetStage() end)
    if okChar then meta.char=char end
    if okStage then meta.stage=stage end
    if sessionRecorder:startSession(okSeed and seed or "",meta) then
        local cfg={ev="cfg"}
        for k,v in pairs(Config) do
            if type(v)~="table" and type(v)~="function" then cfg[k]=v end
        end
        sessionRecorder:event(cfg)
        state.lastMapRevision=nil
    end
end

-- ===== 房间切换（模式6 延迟提交 + 7.5.6 重置）=====
-- 注: 过渡期 Game():GetRoom() 本身可能返回 nil（SocketBridge 已知问题），
-- Room 对象没有 GetRoom() 方法
local function rebuildTerrain()
    local ok, room = pcall(function() return Game():GetRoom() end)
    if not ok or room == nil then return end
    Terrain.build(terrain, room, state.player.canFly, Config)
end

local function onNewRoom()
    if state.avoidanceEpisode then state.avoidanceEpisode.incomplete=true end
    AvoidanceDiagnostics.finish(state,sessionRecorder,"room_change")
    Runtime.onNewRoom(state)
    state.forecastMatched={}
    Terrain.invalidate(terrain)
    ProjectileSensor.clearOwnership()
    tracker:clear()
    trackerEnemies:clear()
    trackerLasers:clear()
    trackerBombs:clear()
    trackerEffects:clear()
    trackerNpcAttacks:clear()
    EnemySensor.resetRoom()
    FutureMotion.clearCache() -- Tier 1: 圆弧参数缓存按房间隔离
    -- 延迟提交：先验证房间数据有效，无效下一帧重试
    local ok, room = pcall(function() return Game():GetRoom() end)
    if ok and room ~= nil then
        state.currentRoomIndex = Game():GetLevel():GetCurrentRoomIndex()
        rebuildTerrain()
        state.roomCommitPending = false
    else
        state.roomCommitPending = true
    end
    hazardsCacheFrame = -1 -- 追踪器已清空，作废同帧缓存（房间过渡帧号可能不变）
    -- 保留跨房间前后文；每条快照均带 room 标签。
    -- 房间类型（boss房/宝藏房等，离线"哪类房间受击率最高"分析用）
    local rtype = -1
    if ok and room ~= nil then
        local okT, rt = pcall(function() return room:GetType() end)
        if okT and type(rt) == "number" then rtype = rt end
    end
    sessionRecorder:event({ ev = "room", frame = state.updateCount,
        idx = state.currentRoomIndex, rtype = rtype })
    -- 配置持久化（MCM SaveHelper 策略：菜单里 SaveData 不可靠，随游戏存档点重存）
    MCM.saveSettings()
end

-- ===== 死亡回放（MC_POST_UPDATE 检测，Rep+ MC_POST_PLAYER_UPDATE 在死后停发）=====
local deathHandled = false
local function onPlayerDeath()
    if state.avoidanceEpisode then state.avoidanceEpisode.incomplete=true end
    AvoidanceDiagnostics.finish(state,sessionRecorder,"death")
    if not Config.deathReplayEnabled then return end
    if not Config.recordingEnabled then
        Isaac.DebugString("[GhostStep3] 死亡回放跳过: 录制功能未开启 (MCM→GhostStep3→录制)")
        return
    end
    if ringBuffer.count > 0 then
        Isaac.DebugString("[GhostStep3] === 死亡回放 ===")
        DeathReplay.dump(ringBuffer, Config.replayBufferSeconds, Isaac.DebugString)
    end
    sessionRecorder:event({ ev = "death", frame = state.updateCount })
    eventBuffer:trigger("death",state.updateCount,sessionRecorder)
    for _=1,math.ceil(eventBuffer.count/2) do eventBuffer:drain(state.updateCount,sessionRecorder) end
    sessionRecorder:tickWriter()
end

-- ===== 主更新（MC_POST_PLAYER_UPDATE, 30fps）=====
local onHpLost -- 前向声明（HP 轮询受伤兜底，定义见下方受伤诊断段）


local function onPlayerUpdate(player)
    local startTime=Isaac.GetTime()
    local frame=Isaac.GetFrameCount()
    if state.lastPlayerUpdate==frame then return end
    state.lastPlayerUpdate=frame
    state.updateCount=frame
    state.logicTick=state.logicTick+1
    sessionRecorder.frame,sessionRecorder.tick=frame,state.logicTick
    local okReal,realPlayer=pcall(Isaac.GetPlayer,0)
    if not okReal or not realPlayer or Game():GetNumPlayers()>1 then
        Runtime.suspendThreat(state); state.player.valid=false; return
    end
    player=realPlayer
    if Config.recordingEnabled and not sessionRecorder.file then startRecording()
    elseif not Config.recordingEnabled and sessionRecorder.file then
        if state.avoidanceEpisode then state.avoidanceEpisode.incomplete=true end
        AvoidanceDiagnostics.finish(state,sessionRecorder,"recording_disabled")
        sessionRecorder:closeFile()
    end
    if player:IsDead() then Runtime.suspendThreat(state); return end
    local stages={}
    state.profiler.stages=stages
    stages.lifecycleMs=Isaac.GetTime()-startTime
    local sensorsStart=Isaac.GetTime()
    registry:collectAll(state,frame)
    stages.sensorsMs=Isaac.GetTime()-sensorsStart
    local okHp,hp=pcall(function() return player:GetHearts()+player:GetSoulHearts() end)
    if okHp and type(hp)=="number" then
        local prev=state.player.hp; state.player.hp=hp
        if prev and hp<prev then SafeCall.call("hpPollHit",onHpLost,prev-hp) end
    end
    -- 无敌可能由道具/护盾触发，不能当成受伤事实。
    if state.roomCommitPending then onNewRoom() end
    local terrainStart=Isaac.GetTime()
    local room=Game():GetRoom()
    terrain:refresh(room,state.player.canFly,Config,frame)
    if Config.recordingEnabled and terrain.valid and state.lastMapRevision~=terrain.revision then
        local cells={}
        for i=1,#terrain.grid do
            local c=terrain.grid[i]
            cells[i]={c.walkable and 1 or 0,c.danger or false,c.collision or -1}
        end
        sessionRecorder:event({ev="terrain",room=state.currentRoomIndex,revision=terrain.revision,
            width=terrain.sizeX,height=terrain.sizeY,x=terrain.topLeft.X,y=terrain.topLeft.Y,cells=cells})
        state.lastMapRevision=terrain.revision
    end
    stages.terrainMs=Isaac.GetTime()-terrainStart
    Motion.observe(state,frame,terrain)
    state.control.active=false
    state.control.readingRaw=true
    local okInput,raw=pcall(InputReader.readMoveVector,state.player.controllerIndex)
    state.control.readingRaw=false
    state.player.inputDir=okInput and raw or Vector(0,0)
    if Input.IsButtonTriggered(Config.toggleKey,0) then
        state.userEnabled=not state.userEnabled
        Runtime.suspendThreat(state)
        sessionRecorder:event({ev="toggle",on=state.userEnabled,frame=frame})
        state.statusToastUntil=state.renderCount+90
    end
    local combat=isCombat(); state.inCombat=combat
    if combat~=wasCombat then wasCombat=combat; registry:onCombatChanged() end
    local hz=getHazards(frame)
    if Config.recordingEnabled then
        for _,event in ipairs(state.forecastMatches or {}) do sessionRecorder:event(event) end
    end
    hazardQuery:update(hz,frame)
    local active=state.player.valid and state.player.controlsEnabled~=false and Runtime.isDodgeActive(state) and okInput
    if active then
        local t=state.threat
        t.projectileCount=tracker.count; t.enemyCount=trackerEnemies.count
        t.laserCount=trackerLasers.count; t.bombCount=trackerBombs.count
        t.effectCount=trackerEffects.count; t.npcAttackCount=trackerNpcAttacks.count
        t.hazardCount=#hz; t.densityScore=0; t.gradientDir=nil
        state.control.wallDist=terrain.valid and terrain:minWallDistance(state.player.position,state.player.radius) or 9999
        local _,command=Pipeline.run(state,{config=Config,tracker=tracker,hazardQuery=hazardQuery,
            terrain=terrain,getHazards=getHazards,omittedCount=tracker.omittedCount or 0},frame)
        state.control.direction=command or Vector(0,0)
        state.control.weight=command and math.min(1,(command-InputReader.executable(state.player.inputDir)):Length()/2) or 0
        state.control.active=command~=nil and not Config.observationMode
        state.control.frame=frame
    else
        Runtime.suspendThreat(state)
    end
    stages.decisionMs=state.decision.usedBudgetMs
    if Config.recordingEnabled then AvoidanceDiagnostics.update(state,frame,sessionRecorder)
    else state.avoidanceEpisode=nil end
    Motion.commit(state,frame)
    if (state.motion.blockedFrames==Config.stuckFrames or (state.feedback and state.feedback.error>8))
        and frame-lastDiagnosticFrame>=30 then
        lastDiagnosticFrame=frame
        eventBuffer:trigger(state.motion.blockedFrames>=Config.stuckFrames and "blocked" or "prediction_error",frame,sessionRecorder)
    end
    local preRecord=Isaac.GetTime()
    state.profiler.lastFrameMs=preRecord-startTime
    if Config.recordingEnabled then
        if ringBuffer.maxSize~=Config.replayBufferSeconds*30 then
            ringBuffer=RingBuffer.create(Config.replayBufferSeconds*30); state.ringBuffer=ringBuffer
        end
        local detail=Config.eventRecording and 4 or Config.snapshotDetail
        local snap=Snapshot.capture(state,frame,detail)
        Snapshot.finalize(snap,state,detail,hz,Config)
        -- 环形详细快照由字节有界的事件缓冲保留；普通回放只保留轻量字段。
        snap.eventDropped=eventBuffer.dropped
        local light={}
        for k,v in pairs(snap) do if type(v)~="table" then light[k]=v end end
        light.metrics,light.feedback,light.model=snap.metrics,snap.feedback,snap.model
        light.perfPrevious=snap.perfPrevious
        RingBuffer.push(ringBuffer,light)
        local line
        if Config.eventRecording then
            line=sessionRecorder:encode(snap,jsonEncode)
            eventBuffer:record(line,frame)
            sessionRecorder:push(light,jsonEncode)
        else
            line=sessionRecorder:push(snap,jsonEncode)
        end
        eventBuffer:drain(frame,sessionRecorder)
    else
        eventBuffer:reset()
    end
    stages.recordPrepareMs=Isaac.GetTime()-preRecord
    local writerStart=Isaac.GetTime()
    sessionRecorder:tickWriter()
    stages.writerMs=Isaac.GetTime()-writerStart
    stages.recordingMs=Isaac.GetTime()-preRecord
    local total=Isaac.GetTime()-startTime
    state.profiler.lastFrameMs=total
    state.profiler.avgFrameMs=state.profiler.avgFrameMs*0.95+total*0.05
    -- 总耗时要包含编码/写盘；在下一条快照按 tick 明确关联。
    state.profiler.previous={tick=state.logicTick,frame=frame,totalMs=total,sensorsMs=stages.sensorsMs,
        terrainMs=stages.terrainMs,decisionMs=stages.decisionMs,recordingMs=stages.recordingMs,
        recordPrepareMs=stages.recordPrepareMs,writerMs=stages.writerMs,lifecycleMs=stages.lifecycleMs}
    if total>math.max(5,Config.budgetMs*3) and frame-lastDiagnosticFrame>=90 then
        lastDiagnosticFrame=frame; eventBuffer:trigger("slow_update",frame,sessionRecorder)
    end
end

-- 伤害回调发生在伤害结算前，记录尝试；HP 下降单独记录观察事实。
-- 防止护盾/其他 mod 取消伤害后仍把回调当成“实际掉血”。
local function onHpLostImpl(amount)
    local pending=state.pendingDamage
    local linked=pending and state.updateCount-pending.frame<=2 and pending or nil
    local kind="unresolved"
    if not Runtime.isDodgeActive(state) then kind="protection_off"
    elseif state.motion and state.motion.blockedFrames>=Config.stuckFrames then kind="blocked"
    elseif (state.threat.framesUntilHit or -1)<0 then kind="undetected" end
    if Runtime.isDodgeActive(state) then
        state.hitAttribution.total=state.hitAttribution.total+1
        state.hitAttribution[kind]=(state.hitAttribution[kind] or 0)+1
    end
    sessionRecorder:event({ev="hit",frame=state.updateCount,dmg=amount,via="hp_poll",observed="hp_decrease",
        kind=kind,diagnostic="hypothesis",protection=Runtime.isDodgeActive(state),
        attemptId=linked and linked.attemptId,sourceAssociation=linked and "recent_callback" or "unknown",
        srcT=linked and linked.srcT,srcV=linked and linked.srcV,sourceIndex=linked and linked.sourceIndex,
        threat=state.threat.level,layer=state.decision.layer,reason=state.decision.reason})
    state.pendingDamage=nil
    if Config.recordingEnabled then eventBuffer:trigger("hp_decrease",state.updateCount,sessionRecorder) end
end
onHpLost=onHpLostImpl
local function onEntityTakeDmg(entity,amount,flags,source)
    if not entity or entity.Type~=EntityType.ENTITY_PLAYER then return end
    state.damageSequence=(state.damageSequence or 0)+1
    local e=source and source.Entity
    local ev={ev="damage_attempt",attemptId=state.damageSequence,frame=Isaac.GetFrameCount(),
        decisionId=state.logicTick,episodeId=state.avoidanceEpisode and state.avoidanceEpisode.episodeId,dmg=tonumber(amount),flags=tonumber(flags),phase="pre_damage",
        srcT=source and source.Type,srcV=source and source.Variant,
        sourceIndex=e and e.Index,sourceSeed=e and e.InitSeed,
        sourceX=e and e.Position and e.Position.X,sourceY=e and e.Position and e.Position.Y,
        hpBefore=state.player.hp,protection=Runtime.isDodgeActive(state),layer=state.decision.layer,
        predictedHit=state.threat.framesUntilHit,reason=state.decision.reason}
    state.pendingDamage=ev
    sessionRecorder:event(ev)
    if Config.recordingEnabled then
        -- 与伤害回调明确关联，保留上一决策的几何/候选证据；不是伤害发生后的精确实体快照。
        local context=Snapshot.capture(state,state.updateCount,4)
        Snapshot.finalize(context,state,4,getHazards(state.updateCount),Config)
        sessionRecorder:event({ev="damage_context",attemptId=ev.attemptId,frame=ev.frame,
            phase="last_decision_before_damage",snapshot=context})
        eventBuffer:trigger("damage_callback",ev.frame,sessionRecorder)
    end
end

-- ===== 控制台命令（gs，用法: 游戏~键开控制台 → gs / gs status / gs replay / gs on|off）=====
local function onCommand(cmd, params)
    if cmd ~= "gs" then return nil end -- 只响应 gs，其他命令放行
    local arg = (params or ""):match("^%s*(%S+)") or "help"

    if arg == "status" then
        local t = state.threat
        return string.format(
            "[GhostStep3] enabled=%s(ALT开关:%s) threat=%.2f hit=%d layer=%s 权重=%.0f%% | 弹幕=%d 敌=%d | 帧耗时=%.2fms 录制缓冲=%d帧",
            tostring(Runtime.isDodgeActive(state)), tostring(state.userEnabled),
            t.level or 0, t.framesUntilHit or -1, state.decision.layer or "?",
            (state.control.weight or 0) * 100,
            t.projectileCount or 0, t.enemyCount or 0,
            state.profiler.lastFrameMs or 0,
            (state.ringBuffer and state.ringBuffer.count) or 0)
    elseif arg == "replay" or arg == "record" then
        if not Config.recordingEnabled then
            return "[GhostStep3] 录制未开启（MCM→GhostStep3→录制→录制功能），开启后进房间打几秒再试"
        end
        local lines = DeathReplay.dumpLines(ringBuffer, Config.replayBufferSeconds)
        for i = 1, #lines do Isaac.DebugString(lines[i]) end
        return table.concat(lines, "\n")
    elseif arg == "mark" then
        sessionRecorder:event({ev="manual_marker",frame=state.updateCount,detail=Config.snapshotDetail})
        if not Config.eventRecording then
            return "[GhostStep3] 已记录标记；详细前后文需预先在 MCM→录制→事件诊断开启"
        end
        eventBuffer:trigger("manual",state.updateCount,sessionRecorder)
        return "[GhostStep3] 已标记走位问题，保存事件前后文"
    elseif arg == "on" then
        state.userEnabled = true
        Runtime.suspendThreat(state)
        state.statusToastUntil = state.renderCount + 90
        return "[GhostStep3] 开启自动躲避"
    elseif arg == "off" then
        state.userEnabled = false
        Runtime.suspendThreat(state)
        return "[GhostStep3] 关闭自动躲避"
    end
    return "[GhostStep3] 命令: gs status 状态 | gs replay 导出回放(也写log.txt) | gs on/off 开关 | gs mark 标记问题 | ALT键同效"
end

-- ===== 受伤诊断 + 受击自动回放（MC_ENTITY_TAKE_DMG）=====
-- 防御: Rep+ 回调常量可能缺失/更名——nil 时跳过注册而不是让整个 mod 加载失败
-- （教训: MC_POST_PLAYER_DEATH 为 nil 时 AddCallback 在游戏引导脚本里
--   callbacks[nil] = {} → "table index is nil" → main.lua 中途夭折）
local function safeAddCallback(cb, fn)
    if cb == nil then
        Isaac.DebugString("[GhostStep3] WARN: callback constant is nil, skipped")
        return
    end
    GhostStep3:AddCallback(cb, fn)
end

safeAddCallback(ModCallbacks.MC_POST_PLAYER_UPDATE, function(_, player)
    SafeCall.call("playerUpdate", onPlayerUpdate, player)
end)

safeAddCallback(ModCallbacks.MC_INPUT_ACTION, function(_, entity, inputHook, action)
    return SafeCall.callOr("inputAction",
        InputWriter.onInputAction, nil,
        state.control, Config.observationMode, entity, inputHook, action)
end)

safeAddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    SafeCall.call("newRoom", onNewRoom)
end)

safeAddCallback(ModCallbacks.MC_POST_RENDER, function()
    state.renderCount = state.renderCount + 1
    SafeCall.call("render", Overlay.render, state, GhostStep3, state.renderCount)
end)

safeAddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, function(_, tookDamage, amount, flags, source)
    SafeCall.call("takeDmg", onEntityTakeDmg, tookDamage, amount, flags, source)
    return nil -- 不修改伤害
end)

safeAddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    -- 开局重载配置（上一局存档点写入的数据此时可读）并立即回存（MCM OnGameStarted 同款）
    SafeCall.call("gameStarted", function()
        if state.avoidanceEpisode then state.avoidanceEpisode.incomplete=true end
        AvoidanceDiagnostics.finish(state,sessionRecorder,"new_game")
        MCM.loadSettings()
        MCM.saveSettings()
        state.lastPlayerUpdate=nil; state.logicTick=0; state.player.hp=nil
        state.pendingDamage=nil; state.damageSequence=0
        state.avoidanceEpisode=nil;state.avoidanceSequence=0
        state.profiler.previous=nil
        sessionRecorder.frame=Isaac.GetFrameCount();sessionRecorder.tick=0
        Runtime.onNewRoom(state); eventBuffer:reset(); ringBuffer:clear()
        state.lastMapRevision=nil
        Runtime.resetHitStats(state) -- 归因统计按局累积，新对局清零
        sessionRecorder:closeFile()
        if Config.recordingEnabled then startRecording() end
    end)
end)

safeAddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
    SafeCall.call("newLevel", function()
        MCM.saveSettings()
        -- 层数事件: 离线"哪一层的受击率最高"分析
        local okStage, stage = pcall(function()
            return Game():GetLevel():GetStage()
        end)
        sessionRecorder:event({ ev = "level", frame = state.updateCount,
            stage = okStage and stage or -1 })
    end)
end)

-- 死亡检测（全局回调，死亡后仍触发；Rep+ 的 MC_POST_PLAYER_UPDATE 玩家死后停发）
safeAddCallback(ModCallbacks.MC_POST_UPDATE, function()
    SafeCall.call("deathDetect", function()
        local ok, player = pcall(Isaac.GetPlayer, 0)
        if not ok or player == nil then return end
        local okDead, isDead = pcall(function() return player:IsDead() end)
        if okDead and isDead then
            if not deathHandled then
                deathHandled = true
                onPlayerDeath()
            end
        else
            deathHandled = false
        end
    end)
end)

safeAddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function()
    SafeCall.call("preExit", function()
        if state.avoidanceEpisode then state.avoidanceEpisode.incomplete=true end
        AvoidanceDiagnostics.finish(state,sessionRecorder,"game_exit")
        MCM.saveSettings()
        sessionRecorder:closeFile()
    end)
end)

safeAddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, cmd, params)
    -- 注: 首参为注入对象（同 MC_INPUT_ACTION），真实 cmd 从第 2 位开始
    return SafeCall.callOr("execCmd", onCommand, nil, cmd, params)
end)

-- 导出供 MCM/外部调试
GhostStep3.State = state
GhostStep3.Config = Config

Isaac.DebugString("[GhostStep3] predictive-shared-control loaded — 预测式闪避辅助")
