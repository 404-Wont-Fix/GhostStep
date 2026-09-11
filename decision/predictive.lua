-- 有限动作的滚动预测共享控制。所有候选都是最终可执行输入；
-- 完整评估后选正常力度的安全动作，只执行第一步。预算未完成的候选永不获选。
local Planner={}
local Reader=require("control/input_reader")
local Motion=require("control/motion_model")
local Geometry=require("threat/geometry")
local Escape=require("decision/local_escape")
local function distance(a,b) return math.sqrt((a.X-b.X)^2+(a.Y-b.Y)^2) end
local function isZero(u) return u==nil or u:Length()<0.05 end
local function traceRow(c)
    return {id=c.id,x=c.u.X,y=c.u.Y,duration=c.duration,risk=c.risk,cost=c.cost,
        hit=c.hit,hitId=c.hitId,terrain=c.blocked,complete=c.complete,clearance=c.clearance,
        exposure=c.exposure,exitTime=c.exitTime,terminalRisk=c.terminalRisk,terrainRejected=c.terrainRejected,
        spikeTicks=c.spikeTicks,
        endX=c.endX,endY=c.endY,plannedDisplacement=c.plannedDisplacement}
end
function Planner.run(state,deps,frame)
    local cfg,p,d=deps.config,state.player,state.decision
    local terrain=deps.terrain
    local begin=Isaac.GetTime()
    local deadline=begin+(cfg.budgetMs or 5)
    local maxHorizon=cfg.plannerHorizonMax or 34
    local horizon=math.max(6,math.min(cfg.plannerHorizon or 18,maxHorizon))
    local m=Motion.ensure(state)
    local nominal=Reader.executable(p.inputDir or Vector(0,0))
    local memory=d.planner or {failed=0}
    d.planner=memory
    d.command,d.dodgeDir,d.lastTrace=nil,nil,nil
    d.layer,d.reason,d.degraded,d.holdFramesLeft="none","nominal_safe",false,0
    local all=deps.getHazards and deps.getHazards(frame) or (deps.hazardQuery and deps.hazardQuery.hazards) or {}
    local requestedHorizon=horizon
    local wide=false
    for i=1,#all do
        local e=all[i]
        if e.kind=="bomb" or e.kind=="laser" or (e.radius or 0)>=32 then wide=true; break end
    end
    -- 密集圆形弹幕优先保住近期候选搜索。大范围攻击保留提前撤离窗口。
    -- 实测: 最大速度 ≈4px/帧 → 18 帧只能跑 ≈73px，而炸弹要跑出 ≈100px。
    -- 炸弹/激光/大体积威胁时动态扩窗（只扩不缩），否则模型永远看不到可行解。
    if wide then
        horizon=math.max(horizon,math.min(cfg.plannerHorizonWide or 30,maxHorizon))
    elseif #all>160 then horizon=math.min(horizon,10)
    elseif #all>64 then horizon=math.min(horizon,14) end
    local hazards,caches={},{}
    for i=1,#all do
        if Geometry.reachable(all[i],p.position,p.radius+5,math.max(m.speed,m.b/(1-m.a)),horizon) then
            hazards[#hazards+1]=all[i]
        end
    end
    -- 排序键只算一次，避免比较器中反复开方/向量分配。
    local ranked={}
    for i=1,#hazards do
        local e=hazards[i]
        ranked[i]={e=e,key=e.pos:Distance(p.position)-(e.radius or 0)-(e.length or 0),id=tostring(e.id or e.index or i)}
    end
    table.sort(ranked,function(a,b) if a.key==b.key then return a.id<b.id end return a.key<b.key end)
    for i=1,#ranked do hazards[i]=ranked[i].e end
    local prepared=0
    for i=1,#hazards do
        if i%16==0 and Isaac.GetTime()>=deadline then break end
        caches[i]=Geometry.prepare(hazards[i],frame,horizon); prepared=i
    end
    d.hazards=hazards
    local metrics={hazards=#hazards,totalHazards=#all,evaluated=0,checks=0,candidates=0,
        complete=prepared==#hazards,prepared=prepared,horizon=horizon,requestedHorizon=requestedHorizon,denseHorizon=horizon<requestedHorizon,searchNodes=0,modelSamples=m.samples,modelError=m.error}
    d.metrics=metrics
    local rows={}
    local workLimit=cfg.plannerMaxChecks or 80000
    local initialDepth=0
    local initialDanger=0
    if terrain.valid then initialDepth,initialDanger=terrain:probe(p.position,p.radius) end
    local margin=(cfg.safetyMargin or 1.5)+math.min(3,m.error*0.2)
    -- 地刺不再硬否决（见 evaluate）：一次性接触代价 + 每帧停留代价。
    -- 参考量级：命中惩罚 100；踩刺接触 55 + 0.5×帧数。
    -- 接触代价一次性收取（对齐游戏无敌帧：一次穿过只掉一次血），
    -- 停留代价要小，否则"地刺环里所有方向都踩刺"时，几个帧数的差异
    -- 会盖过玩家意图、把方向掰到 135° 之外（实测按左被推到右下）。
    local spikeContactRisk=cfg.spikeContactRisk or 55
    local spikeRiskPerTick=cfg.spikeRiskPerTick or 0.5
    local nominalLen=nominal:Length()
    local originalRisk,originalHit
    local function evaluate(c,mandatory)
        c.complete=true; c.risk=0; c.exposure=0; c.clearance=nil; c.blocked=false
        local x,y,vx,vy=p.position.X,p.position.Y,p.velocity.X,p.velocity.Y
        local points,danger={{x,y}},{}
        local deviation,depth=0,initialDepth
        local peakDepth,spikeTicks=initialDepth,0
        local minX,maxX,minY,maxY=x,x,y,y
        for t=1,horizon do
            local u=t<=c.duration and c.u or nominal
            local nx,ny,nvx,nvy=Motion.step(m,x,y,vx,vy,u)
            if terrain.valid then
                local pos=Vector(nx,ny)
                local hard,soft=terrain:probe(pos,p.radius)
                -- 撞墙：引擎里玩家中心不会进入实心格，位置钉在上一帧、速度清零。
                -- 否则"跑向墙"会被 segmentSafe 当成穿墙否决；窗口拉长到 30 帧后，
                -- 按 6px/帧 能跑 180px，房间半高只有 140px → 纵向躲避会被远处的墙全判死。
                if depth<=0 and hard>0 then
                    nx,ny,nvx,nvy=x,y,0,0
                    hard,soft=terrain:probe(Vector(x,y),p.radius)
                end
                -- 只在"上一步在硬地形外"时判穿墙。玩家已经在墙里/门洞里时，
                -- 所有候选共享同一初速度、第一帧位置完全相同；旧的 nextDepth>depth+0.01
                -- 会让全部候选同帧被判死（实测房间 84：18 个候选在 t=1 全灭）。
                -- 起点已在硬地形内时改用 peakDepth 计价，驱动"尽快脱出"。
                if depth<=0 and not terrain:segmentSafe(Vector(x,y),Vector(nx,ny),p.radius,false,depth,hard) then
                    c.blocked=true
                end
                depth=hard
                if hard>peakDepth then peakDepth=hard end
                -- 地刺/TNT：足迹重叠即计入暴露帧数（软代价，不封路）
                if soft>0 then spikeTicks=spikeTicks+1 end
            end
            if c.blocked and not mandatory then
                -- 不可执行的路径无需再扫描弹幕；把预算留给其他方向。
                c.risk=10000; c.cost=0; c.terminalRisk=0; c.terrainRejected=true
                metrics.evaluated=metrics.evaluated+1
                rows[#rows+1]=traceRow(c)
                return c
            end
            deviation=deviation+distance(u,nominal)^2
            x,y,vx,vy=nx,ny,nvx,nvy
            points[t+1]={x,y}
            minX,maxX,minY,maxY=math.min(minX,x),math.max(maxX,x),math.min(minY,y),math.max(maxY,y)
        end
        c.endX,c.endY=x,y
        c.plannedDisplacement=math.sqrt((x-p.position.X)^2+(y-p.position.Y)^2)
        local r=p.radius+margin
        local inInitial=false
        for i=1,#hazards do
            local e,cache=hazards[i],caches[i]
            if not cache then c.complete=false;metrics.complete=false;return nil end
            metrics.checks=metrics.checks+1
            if metrics.checks>workLimit or (metrics.checks%32==0 and Isaac.GetTime()>=deadline) then
                c.complete=false; metrics.complete=false; return nil
            end
            local relevant=cache.start<=horizon and cache.ending>=0 and (not cache.linear
                or (cache.maxX>=minX-r and cache.minX<=maxX+r and cache.maxY>=minY-r and cache.minY<=maxY+r))
            if relevant then
                if Geometry.clearance(e,p.position.X,p.position.Y,p.position.X,p.position.Y,r,0,0,frame,cache)<=0 then inInitial=true end
                for t=1,horizon do
                    metrics.checks=metrics.checks+1
                    if metrics.checks>workLimit or (metrics.checks%32==0 and Isaac.GetTime()>=deadline) then
                        c.complete=false; metrics.complete=false; return nil
                    end
                    local a,b=points[t],points[t+1]
                    local clear=Geometry.clearance(e,a[1],a[2],b[1],b[2],r,t-1,t,frame,cache)
                    if not c.clearance or clear<c.clearance then c.clearance=clear end
                    if clear<=0 then
                        danger[t]=math.max(danger[t] or 0,math.min(3,e.damage or 1))
                        local time=math.max(t-1,cache.start)
                        if not c.hit or time<c.hit then c.hit=time; c.hitId=e.id; c.hitEntry=e end
                    end
                end
            end
        end
        local escaping,terminalRisk=inInitial,0
        for t=1,horizon do
            local severity=danger[t] or 0
            if escaping and severity==0 then c.exitTime=t; escaping=false end
            c.exposure=c.exposure+severity*(1-0.5*t/horizon)
            if t>horizon-3 and severity>0 then terminalRisk=terminalRisk+1 end
        end
        c.terminalRisk=terminalRisk
        c.spikeTicks=spikeTicks
        c.risk=(c.hit and 100 or 0)+c.exposure*4+terminalRisk*4+(c.blocked and 10000 or 0)
        -- 硬地形穿透：按窗口内最深穿透扣分
        if peakDepth>0 then c.risk=c.risk+peakDepth*10 end
        -- 地刺/TNT：接触 + 停留计价，而不是一击否决
        if spikeTicks>0 then c.risk=c.risk+spikeContactRisk+spikeTicks*spikeRiskPerTick end
        local smooth=memory.last and distance(c.u,memory.last)^2 or 0
        local exits=0
        if terrain.valid then
            -- 出口数只看硬地形（地刺现在是可穿行的代价，不算"没有出口"）
            for _,v in ipairs({Vector(20,0),Vector(-20,0),Vector(0,20),Vector(0,-20)}) do
                if terrain:isSafeAt(Vector(x,y)+v,p.radius,false) then exits=exits+1 end
            end
        end
        local enemyCost=0
        for i=1,#hazards do
            local e=hazards[i]
            if e.kind=="enemy" then
                local dist=math.sqrt((x-e.pos.X)^2+(y-e.pos.Y)^2)-(e.radius or 0)-p.radius
                enemyCost=enemyCost+math.max(0,1-dist/80)
            end
        end
        local spikeCost=0
        if terrain.valid then
            local left,top=terrain.topLeft.X,terrain.topLeft.Y
            local cx,cy=math.floor((x-left)/40),math.floor((y-top)/40)
            -- 扫描 5×5 格（半径2格≈100px），覆盖高速移动时路径穿过的地刺
            for dy=-2,2 do for dx=-2,2 do
                local gx,gy=cx+dx,cy+dy
                if gx>=0 and gy>=0 and gx<terrain.sizeX and gy<terrain.sizeY then
                    local cell=terrain.grid[gy*terrain.sizeX+gx+1]
                    if cell and cell.danger=="spike" then
                        local sx,sy=left+gx*40+20,top+gy*40+20
                        local dist=math.sqrt((x-sx)^2+(y-sy)^2)-p.radius
                        spikeCost=spikeCost+math.max(0,1-dist/80)
                    end
                end
            end end
        end
        c.cost=deviation*(cfg.intentPenalty or 3)/horizon
            +smooth*(cfg.smoothPenalty or 0.2)+enemyCost*0.06+spikeCost*0.5-exits*0.025
        metrics.evaluated=metrics.evaluated+1
        rows[#rows+1]=traceRow(c)
        return c
    end
    local base={id=0,u=nominal,duration=horizon}
    evaluate(base,true)
    originalRisk,originalHit=base.risk,base.hit
    metrics.nominalRisk,metrics.nominalHit=originalRisk,originalHit
    metrics.nominalComplete=base.complete
    local best=base
    local bestNonZero=base
    -- 风险差不超过 eps 就当作平手，改由 cost（含玩家意图偏离度 deviation）决定。
    -- 旧实现 eps=0.05，导致 3.44 的边际收益就能把方向翻成玩家意图的反面
    -- （实测房间 36：按左、输出 (0.96,-0.29)，下一帧再翻回来 = 手感抽抽）。
    local riskEps=cfg.riskTieEpsilon or 5
    local function better(c,b)
        return not c.blocked and (b.blocked or c.risk<b.risk-riskEps
            or (math.abs(c.risk-b.risk)<=riskEps and c.cost<b.cost))
    end
    local function finish(reason)
        d.reason=reason
        d.degraded=metrics.denseHorizon or not metrics.complete or Isaac.GetTime()>=deadline
        d.usedBudgetMs=Isaac.GetTime()-begin
        metrics.selectedRisk=best.risk; metrics.selectedId=best.id
        metrics.triggerId=base.hitEntry and base.hitEntry.id
        metrics.triggerKind=base.hitEntry and base.hitEntry.kind
            or (initialDepth>0 and "terrain")
            or ((initialDanger>0 or (base.spikeTicks or 0)>0) and "spike" or nil)
        metrics.initialPenetration=initialDepth
        metrics.initialSpikeDepth=initialDanger
        metrics.spikeRiskScale=spikeContactRisk
        metrics.riskImprovement=base.risk-best.risk
        metrics.selectedSafe=best.complete and not best.hit and not best.blocked
        metrics.triggerX=base.hitEntry and base.hitEntry.pos.X
        metrics.triggerY=base.hitEntry and base.hitEntry.pos.Y
        metrics.selectedEndX,metrics.selectedEndY=best.endX,best.endY
        metrics.plannedDisplacement=best.plannedDisplacement
        metrics.selectedDuration=best.duration; metrics.selectedAmplitude=best.u:Length()
        metrics.selectedHit=best.hit; metrics.stuckFrames=m.blockedFrames
        metrics.sensorOmitted=deps.omittedCount or 0
        metrics.coverageComplete=(deps.omittedCount or 0)==0 and metrics.nominalComplete
        d.lastTrace={candidates=rows,selected=best.id,metrics=metrics}
        local t=state.threat
        t.framesUntilHit=base.hit or -1
        t.hitKind=base.hitEntry and base.hitEntry.kind or nil
        t.hitDamage=base.hitEntry and base.hitEntry.damage or nil
        t.hitDist=base.hitEntry and base.hitEntry.pos:Distance(p.position) or nil
        t.level=base.hit and math.max(0.3,1-base.hit/horizon)
            or (initialDepth>0 and 0.9 or (initialDanger>0 and 0.6 or 0))
        t.collisionUrgency=t.level
        return d.command
    end
    if not base.complete then return finish("baseline_budget_incomplete") end
    -- 单纯顶着无危险的墙，保持玩家输入（允许正常出门、贴墙射击）。
    -- 地刺现在是软代价：玩家自愿踩刺时仍不接管，但原输入路径会碰上地刺时必须进入候选比较
    -- （否则 spikes 完全不会被避让 —— 这正是"地刺避让不明显"的原因之一）。
    if not base.hit and initialDepth<=0 and (base.spikeTicks or 0)==0 then
        memory.failed=0; memory.last=nil; return finish("nominal_safe")
    end
    local candidates,seen={},{}
    local function add(u,duration)
        u=Reader.executable(u)
        if distance(u,nominal)<0.001 then return end
        local key=string.format("%.3f,%.3f,%d",u.X,u.Y,duration)
        if not seen[key] and #candidates<(cfg.plannerMaxCandidates or 64) then
            seen[key]=true
            candidates[#candidates+1]={id=#candidates+1,u=u,duration=duration}
        end
    end
    -- 候选顺序 = 预算不够时先比谁。
    -- 旧顺序把"侧向/反向"排在 8 方向之前，实测 60% 的接管只比了 1~3 个候选就下手。
    -- 但几何解（垂直于来袭速度）本身就是代价最低的撤离方向，不能推到后面 —— 
    -- 否则搜寻被截断时会连撤离方向都没算。
    -- 因此：旧命令(防抖) → 几何解 → 8 方向(按与玩家输入接近度排序) → 短脉冲 → 停住。
    -- "不要为了边际收益把方向掰到玩家意图之外"由 better() 的 riskTieEpsilon 负责。
    if memory.last and memory.last:Length()>0.99 then add(memory.last,horizon) end
    local hit=base.hitEntry
    local axis=hit and hit.vel or p.velocity
    if axis:Length()<0.01 and hit then axis=hit.pos-p.position end
    if axis:Length()>0.01 then
        axis=axis:Normalized()
        local side=Vector(-axis.Y,axis.X)
        add(side,horizon); add(side*-1,horizon)
    end
    if hit and (hit.pos-p.position):Length()>0.01 then
        add((p.position-hit.pos):Normalized(),horizon)
    end
    local directions={}
    for i=0,7 do
        local angle=i*math.pi/4
        directions[#directions+1]=Vector(math.cos(angle),math.sin(angle))
    end
    if nominalLen>0.01 then
        -- 贴近玩家意图的方向先比：被截断时优先给最小偏离的选项
        table.sort(directions,function(a,b) return distance(a,nominal)<distance(b,nominal) end)
    end
    -- 完整撤离与较早恢复原输入都使用全力度，兼顾狭小空间。
    for _,u in ipairs(directions) do add(u,horizon) end
    for _,u in ipairs(directions) do add(u,math.min(6,horizon)) end
    -- 零向量仍保留（有效刹车），但提交时受"玩家有输入就不许按住"约束
    add(Vector(0,0),horizon)
    metrics.candidates=#candidates
    for i=1,#candidates do
        if Isaac.GetTime()>=deadline or metrics.checks>=workLimit then metrics.complete=false; break end
        local c=evaluate(candidates[i],false)
        if not c then break end
        if better(c,best) then best=c end
        if not isZero(c.u) and better(c,bestNonZero) then bestNonZero=c end
    end
    -- 玩家有输入时不允许用零向量把玩家按住（回放实测 15.2% 的接管帧输出全零，
    -- 就是"上下左右都不能动"）。零向量只在"没有任何非零且非硬否决的候选"时才可用。
    if nominalLen>0.05 and isZero(best.u) then
        if not isZero(base.u) and not base.blocked then best=base end
        if bestNonZero.id~=0 and not bestNonZero.blocked and better(bestNonZero,best) then
            best=bestNonZero
        end
        if not isZero(best.u) then metrics.zeroBrakeReplaced=true end
    end
    if best.id==0 and (m.blockedFrames>=(cfg.stuckFrames or 6) or memory.failed>=3)
        and Isaac.GetTime()<deadline then
        local dir,nodes=Escape.suggest(p,terrain,hazards,frame,cfg.escapeMaxNodes or 48,deadline,caches)
        metrics.searchNodes=nodes
        if dir and Isaac.GetTime()<deadline then
            local c=evaluate({id=#candidates+1,u=Reader.executable(dir),duration=horizon},false)
            metrics.candidates=metrics.candidates+1
            if c and better(c,best) then best=c end
        end
    end
    -- 必须带来可观的风险下降；禁止仅为密度/终点偏好而接管。
    local improvement=base.risk-best.risk
    if best.id~=0 and improvement>=math.max(0.5,(base.exposure or 0)*0.1) then
        d.command=best.u; d.dodgeDir=best.u; d.layer="predictive"
        memory.last=best.u; memory.failed=best.hit and memory.failed+1 or 0
        return finish(best.hit and "reduce_exposure" or "safe_evasion")
    end
    memory.failed=memory.failed+1
    memory.last=nil
    return finish(metrics.complete and "no_improving_action" or "budget_no_improving_action")
end
return Planner
