-- recording/snapshot.lua
-- 帧快照采集（详情级别: 1最小 2标准 3详细 4全量诊断）
--
-- 两阶段采集（修时序错位：旧版在决策管线前一次性采集，录到的威胁/决策/控制
-- 是上一帧的值而位置是本帧值，离线对齐分析会被误导一帧）：
--   capture  — 管线前调用，只采传感器当帧就绪的字段（位置/速度/血量）
--   finalize — 决策+合成后调用，采威胁/决策/控制字段（本帧值）
-- 两个阶段在 main.lua 中间夹着威胁评估与决策管线；ALT 关闭等提前退出分支
-- 也走 finalize+push（清零后定稿），保证录制连续不断流

local Snapshot = {}

-- 级别4 hz 条目的 kind 单字母代号（省 JSONL 体积；replay_viewer 反查）
local KIND_CODE = {
    projectile = "p",
    enemy = "e",
    laser = "l",
    bomb = "b",
    effect = "f",
    npc_attack = "n",
}

--- 阶段1: 采集管线前就绪的字段（返回平铺表）
function Snapshot.capture(state, frame, detailLevel)
    local snap = {
        frame = frame,
        schemaVersion = 2,
        tick = state.logicTick,
        decisionId = state.logicTick,
        phase = "post_player_update",
        enabled = state.config and state.config.enabled and state.userEnabled,
        observation = state.config and state.config.observationMode,
        radius = state.player.radius,
        controlsEnabled = state.player.controlsEnabled,
        detail = detailLevel,
        room = state.currentRoomIndex,
    }

    local player = state.player

    if detailLevel >= 1 then
        -- 最小
        snap.px = player.position.X
        snap.py = player.position.Y
        snap.hp = player.hp -- 受伤时刻判定（回放对齐掉血帧）
    end
    if detailLevel >= 2 then
        -- 标准
        snap.vx = player.velocity.X
        snap.vy = player.velocity.Y
        snap.cmb = state.inCombat and 1 or 0
    end
    if detailLevel >= 3 then
        -- 详细
        snap.canFly = player.canFly
    end

    return snap
end

--- 阶段2: 定稿管线后才有的字段（威胁评估/决策/输入合成/性能统计的输出）
--- hazards/config: 级别4逐威胁明细用（可省略）
function Snapshot.finalize(snap, state, detailLevel, hazards, config)
    local player = state.player
    local threat = state.threat
    local decision = state.decision
    local control = state.control

    snap.budgetMs = decision.usedBudgetMs
    snap.active = control.active
    snap.commandValid = control.active
    snap.reason = decision.reason
    snap.feedback = state.feedback
    snap.episodeId=state.avoidanceEpisode and state.avoidanceEpisode.episodeId
    snap.metrics = decision.metrics
    snap.cx, snap.cy = control.direction.X, control.direction.Y
    snap.perfPrevious = state.profiler.previous
    snap.stages = state.profiler.stages
    if state.sessionRecorder then
        snap.recordQueueBytes = state.sessionRecorder.queuedBytes
        snap.recordDropped = state.sessionRecorder.dropped
        snap.recordError = state.sessionRecorder.lastError
        snap.recordIoPaused = state.sessionRecorder.ioPaused or false
        snap.recordMaxWriteMs = state.sessionRecorder.maxWriteMs or 0
    end
    if state.motion then snap.model={a=state.motion.a,b=state.motion.b,samples=state.motion.samples,error=state.motion.error,
        positionError=state.motion.positionError,velocityError=state.motion.velocityError} end
    if detailLevel >= 1 then
        snap.threat = threat.level
    end
    if detailLevel >= 2 then
        snap.ix = player.inputDir.X
        snap.iy = player.inputDir.Y
        snap.proj = threat.projectileCount
        snap.enemy = threat.enemyCount
        snap.laser = threat.laserCount or 0
        snap.bomb = threat.bombCount or 0
        snap.effect = threat.effectCount or 0
        snap.npcatk = threat.npcAttackCount or 0
        snap.layer = decision.layer
        snap.weight = control.weight
        local dd = decision.dodgeDir
        if dd then
            snap.dx = dd.X
            snap.dy = dd.Y
        end
    end
    if detailLevel >= 3 then
        snap.collision = threat.collisionUrgency
        snap.density = threat.densityScore
        snap.hitFrame = threat.framesUntilHit
        snap.budgetMs = decision.usedBudgetMs
        -- 命中威胁明细（受击归因离线分析用）
        if threat.hitKind then
            snap.hitKind = threat.hitKind
            snap.hitDmg = threat.hitDamage
            snap.hitDist = threat.hitDist
        end
        -- 合成输出（诊断"AI 是否压制玩家"的关键三元组：P/D/输出）
        snap.cx = control.direction.X
        snap.cy = control.direction.Y
        -- 调参补充: 墙距（blocked/lowWeight 归因离线复核）/ 全程帧耗时 /
        -- 采样降级标记 / 方向保持剩余帧
        snap.wallDist = control.wallDist or -1
        snap.frameMs = state.profiler.lastFrameMs
        snap.degraded = decision.degraded and 1 or 0
        snap.holdFrames = decision.holdFramesLeft
    end
    if detailLevel >= 4 then
        local source=decision.hazards or hazards or {}
        if not decision.hazards then
            local ordered={}
            for i=1,#source do ordered[i]=source[i] end
            table.sort(ordered,function(a,b) return a.pos:Distance(player.position)<b.pos:Distance(player.position) end)
            source=ordered
        end
        -- 先保留候选实际碰撞过的对象，再补其他近场威胁。
        local wanted,prioritized,seen={},{},{}
        local plan=decision.lastTrace
        if plan and plan.candidates then
            for _,c in ipairs(plan.candidates) do if c.hitId then wanted[c.hitId]=true end end
        end
        for i=1,#source do if source[i].id and wanted[source[i].id] then prioritized[#prioritized+1]=source[i];seen[source[i]]=true end end
        for i=1,#source do if not seen[source[i]] then prioritized[#prioritized+1]=source[i] end end
        source=prioritized
        local maxN=(config and config.traceHazardMax) or 16
        local hz,objects={},{}
        for i=1,math.min(#source,maxN) do
            local h=source[i]
            hz[i]={KIND_CODE[h.kind] or "p",h.variant or -1,h.pos.X-player.position.X,h.pos.Y-player.position.Y,
                h.vel.X,h.vel.Y,h.radius or 0,h.damage or 1}
            objects[i]={id=h.id,index=h.index,seed=h.seed,kind=h.kind,sourceIndex=h.sourceIndex,
                x=h.pos.X,y=h.pos.Y,vx=h.vel.X,vy=h.vel.Y,r=h.radius,
                ex=h.endPos and h.endPos.X,ey=h.endPos and h.endPos.Y,length=h.length,angle=h.angle,rotSpd=h.rotSpd,
                appearFrame=h.appearFrame,endFrame=h.endFrame,fuseFrames=h.fuseFrames,lastFrame=h.lastFrame,
                predicted=h.predicted,confidence=h.confidence,uncertainty=h.uncertainty,rule=h.rule,animationFrame=h.animationFrame}
            local History=require("entities/tracker")
            local history={}
            for offset=2,0,-1 do
                local sample=History.recent(h,offset)
                if sample then history[#history+1]={sample.frame,sample.pos.X,sample.pos.Y,sample.vel.X,sample.vel.Y} end
            end
            objects[i].history=history
        end
        snap.hz,snap.hazards=hz,objects
        snap.hazardTotal=#source; snap.hazardOmitted=math.max(0,#source-#objects)
        snap.plan=decision.lastTrace
        if decision.lastTrace then snap.cand=decision.lastTrace.cand; snap.bestScore=decision.lastTrace.best end

    end

    return snap
end

return Snapshot
