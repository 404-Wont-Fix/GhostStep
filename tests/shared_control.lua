-- 行为回归：使用公开 API 形状；不依赖旧错误输出作为期望值。
local checks,failures=0,0
local function test(name,fn)
    checks=checks+1
    local ok,err=pcall(fn)
    print((ok and 'PASS ' or 'FAIL ')..name..(ok and '' or ': '..tostring(err)))
    if not ok then failures=failures+1 end
end
local Defaults=require('config/defaults')
local Runtime=require('config/runtime')
local Planner=require('decision/predictive')
local Terrain=require('sensors/terrain')
local Tracker=require('entities/tracker')
local Query=require('threat/hazard_query')
local Future=require('threat/future_motion')
local Motion=require('control/motion_model')
local function state()
    local cfg=Defaults.get(); cfg.budgetMs=1000
    local st=Runtime.create(cfg); st.player.valid=true; st.player.moveSpeed=1
    return st
end
local function run(st,hz,ter,frame)
    return Planner.run(st,{config=st.config,terrain=ter or Terrain.create(),getHazards=function() return hz end},frame or 0)
end
local function shot(x,y,vx,vy,r)
    return {id='p:1',index=1,kind='projectile',pos=Vector(x,y),vel=Vector(vx,vy),speed=math.sqrt(vx*vx+vy*vy),radius=r or 5}
end
local function room()
    local solids={}
    return {solids=solids,GetGridWidth=function() return 9 end,GetGridSize=function() return 81 end,
        GetGridPosition=function(_,i) return Vector(i%9*40,math.floor(i/9)*40) end,
        GetGridEntity=function(_,i)
            if solids[i] then return {CollisionClass=solids[i],GetType=function() return 1 end} end
        end}
end

test('terrain uses every linear index, radius and closed outside boundary',function()
    local r=room(); local seen={}; local getter=r.GetGridEntity
    r.GetGridEntity=function(self,i,extra) assert(extra==nil); seen[i]=true; return getter(self,i) end
    r.solids[40]=GridCollisionClass.COLLISION_SOLID
    local t=Terrain.create(); t:build(r,false,Defaults.get())
    local count=0; for _ in pairs(seen) do count=count+1 end
    assert(count==81 and not t:isWalkableAt(Vector(160,160)))
    assert(not t:isWalkableAt(Vector(-1000,0)))
    assert(not t:isSafeAt(Vector(134,160),10),'radius clips rock although center is outside')
    assert(t:isSafeAt(Vector(125,160),10))
    r.solids[40]=nil; t:refresh(r,false,Defaults.get(),3)
    assert(t:isSafeAt(Vector(160,160),10),'destroyed rock refresh')
    r.solids[40]=GridCollisionClass.COLLISION_PIT; t:refresh(r,false,Defaults.get(),6)
    assert(not t:isSafeAt(Vector(160,160),10))
    t:refresh(r,true,Defaults.get(),7); assert(t:isSafeAt(Vector(160,160),10),'flight refresh immediate')
end)
test('destroyed TNT residue cannot recreate an invisible terrain obstacle',function()
    local r=room()
    -- 爆炸后 GridEntity 仍存在，State/VarData 未清零；Room 碰撞值才是当前结果。
    local collision=GridCollisionClass.COLLISION_OBJECT
    r.GetGridEntity=function(_,index)
        if index==40 then return {CollisionClass=GridCollisionClass.COLLISION_OBJECT,
            State=4,VarData=1,GetType=function() return GridEntityType.GRID_TNT end} end
    end
    r.GetGridCollision=function(_,index)
        return index==40 and collision or GridCollisionClass.COLLISION_NONE
    end
    local cfg=Defaults.get();local t=Terrain.create(); t:build(r,false,cfg)
    assert(not t:isSafeAt(Vector(160,160),10),'intact TNT still blocks movement')
    local revision=t.revision
    collision=GridCollisionClass.COLLISION_NONE
    t:refresh(r,false,cfg,3)
    assert(t.grid[41].walkable and t.grid[41].danger==nil,'exploded residue is passable')
    assert(t:isSafeAt(Vector(160,160),10) and t.revision>revision)
    local cleanRevision=t.revision
    for frame=6,30,3 do
        t:refresh(r,false,cfg,frame)
        assert(t.revision==cleanRevision and t:isSafeAt(Vector(160,160),10),'no ghost recreation')
    end
    local st=state();st.player.position=Vector(160,160)
    assert(run(st,{},t,30)==nil and st.decision.reason=='nominal_safe',
        'empty destroyed TNT cell must not trigger escape planning')
    t:refresh(r,true,cfg,33)
    assert(t:isSafeAt(Vector(160,160),10),'flight also ignores residue')
end)
test('missing physical entity is excluded from live hazards before history expires',function()
    local tr=Tracker.create()
    tr:update({{index=1,seed=1,kind='bomb',pos=Vector(0,0),vel=Vector(0,0),radius=90}},1,'bomb')
    tr:update({},2,'bomb')
    assert(tr.count==1,'history retained until expiry')
    assert(#tr:getActive(0,2)==0,'historical entity cannot enter the current hazard view')
end)
test('ring-history prediction starts at current position after wrap',function()
    local tr=Tracker.create()
    for f=1,25 do
        local a=f*0.1
        tr:update({{index=1,seed=77,kind='projectile',pos=Vector(100*math.cos(a),100*math.sin(a)),vel=Vector(-10*math.sin(a),10*math.cos(a)),radius=5,speed=10}},f,'projectile')
    end
    local h=tr.tracked[1]
    assert(Future.pos(h,0,25):Distance(h.pos)<0.001)
    tr:update({{index=1,seed=78,kind='projectile',pos=Vector(0,0),vel=Vector(0,0),radius=5,speed=0}},26,'projectile')
    assert(tr.tracked[1].historyCount==1,'reused Index gets new identity')
end)
test('tracker removes expired optional geometry fields',function()
    local tr=Tracker.create()
    tr:update({{index=1,pos=Vector(0,0),vel=Vector(0,0),endPos=Vector(100,0),fuseFrames=10}},1,'laser')
    tr:update({{index=1,pos=Vector(0,0),vel=Vector(0,0)}},2,'laser')
    assert(tr.tracked[1].endPos==nil and tr.tracked[1].fuseFrames==nil)
end)
test('long laser, activation time and single rotation',function()
    local q=Query.create()
    local e={kind='laser',pos=Vector(0,0),vel=Vector(0,0),length=500,angle=0,rotSpd=0,radius=5,appearFrame=20}
    q:update({e},10)
    assert(q:firstCollision(Vector(400,0),Vector(0,0),10,5)==nil)
    assert(q:firstCollision(Vector(400,0),Vector(0,0),10,12)==10)
    e.appearFrame=nil; e.rotSpd=10
    local _,b=Future.laserSegmentAt(e,1)
    assert(math.abs(b.Y-500*math.sin(math.rad(10)))<0.001)
end)
test('continuous geometry catches a fast crossing between sample endpoints',function()
    local q=Query.create(); q:update({shot(-80,0,160,0,2)},0)
    assert(q:firstCollision(Vector(0,0),Vector(0,0),3,1)==0)
end)
test('recorded frame 3204 catches enemy movement before the next player integration',function()
    local g=require('threat/geometry')
    local e={kind='enemy',pos=Vector(314.04907226563,650.78216552734),
        vel=Vector(-0.035662323236465,4.7933955192566),radius=13,lastFrame=3204}
    local x,y=299.541015625,673.57489013672
    local nx,ny=x-3.4485132694244,y+0.31305766105652
    local cache=g.prepare(e,3204,18)
    assert(g.clearance(e,x,y,nx,ny,11.5,0,1,3204,cache)<=0,
        'enemy can collide before the player reaches the next predicted position')
    assert(g.clearance(e,x,y,nx,ny,11.5,0,1,3204,{})<=0,'uncached geometry must agree')
    local st=state();st.player.position=Vector(x,y);st.player.velocity=Vector(nx-x,ny-y)
    run(st,{e},nil,3204)
    assert(st.decision.metrics.nominalHit==0,'planner must report immediate contact, not seven frames away')
end)
test('phase protection keeps moving bullets and stationary enemies unchanged',function()
    local g=require('threat/geometry')
    -- 两者同向等速，弹体相对距离恒定；敌人则可能先经过玩家旧位置。
    local e={kind='projectile',pos=Vector(0,0),vel=Vector(20,0),radius=2}
    assert(g.clearance(e,10,0,30,0,2,0,1,0,g.prepare(e,0,1))>0)
    e.kind='enemy'
    assert(g.clearance(e,10,0,30,0,2,0,1,0,g.prepare(e,0,1))<=0)
    e.vel=Vector(0,0)
    assert(g.clearance(e,10,0,30,0,2,0,1,0,g.prepare(e,0,1))>0)
end)
test('zero position residual does not hide incorrect predicted acceleration',function()
    local st=state();st.player.inputDir=Vector(1,0)
    st.control.active=true;st.control.direction=Vector(1,0)
    Motion.commit(st,0)
    st.control.hookSeen=true
    st.player.position=Vector(0,0);st.player.velocity=Vector(0,0)
    Motion.observe(st,1,Terrain.create())
    assert(st.feedback.error==0 and st.feedback.velocityError>1)
    assert(st.motion.positionError==0 and st.motion.velocityError>0 and st.motion.error>0)
end)
test('closed loop avoids a chasing enemy that moves before the player',function()
    local st=state();local pos,vel,enemy=Vector(0,0),Vector(0,0),Vector(80,0)
    st.motion={a=0.85,b=0.6,speed=6,error=0,samples=0,blockedFrames=0}
    local g=require('threat/geometry');local closest=9999
    for frame=0,119 do
        st.player.position,st.player.velocity=pos,vel
        local ev=(pos-enemy):Normalized()*2.2
        local h={id='e:1',kind='enemy',pos=enemy,vel=ev,radius=13,speed=2.2}
        local u=run(st,{h},nil,frame) or Vector(0,0)
        local movedEnemy=enemy+ev
        closest=math.min(closest,g.pointSegmentDistance(pos.X,pos.Y,enemy.X,enemy.Y,movedEnemy.X,movedEnemy.Y))
        local nextPos=pos+vel
        closest=math.min(closest,g.pointSegmentDistance(movedEnemy.X,movedEnemy.Y,pos.X,pos.Y,nextPos.X,nextPos.Y))
        pos,enemy,vel=nextPos,movedEnemy,vel*0.85+u*0.6
    end
    assert(closest>23,'contact in enemy-first simulation: '..closest)
    assert(pos:Length()>20,'standing protection must actually move')
end)
test('avoidance summary links previous command movement without counting gaps',function()
    local D=require('control/avoidance_diagnostics');local st=state();local events={}
    local recorder={event=function(_,e) events[#events+1]=e end}
    st.logicTick=1;st.control.active=true;st.control.direction=Vector(1,0)
    st.player.position=Vector(0,0);st.decision.reason='safe_evasion'
    D.update(st,1,recorder)
    st.logicTick=2;st.feedback={decisionId=1,dt=1,progress=5,hookSeen=true}
    st.player.position=Vector(3,4);st.control.active=false
    D.update(st,2,recorder)
    assert(events[2].ev=='avoidance_end' and events[2].pathDistance==5 and events[2].netDisplacement==5)
    assert(events[2].hookSteps==1 and events[2].commands==1)
    st.control.active=true;D.update(st,3,recorder)
    st.feedback=nil;st.player.position=Vector(500,500);st.control.active=false
    D.update(st,20,recorder)
    assert(events[4].incomplete and events[4].pathDistance==0)
end)
test('safe player intent is untouched even in a dense distant cluster',function()
    local st=state(); st.player.inputDir=Vector(-1,0)
    local hz={}; for i=1,80 do hz[i]=shot(200+i,80,0,0) end
    assert(run(st,hz)==nil and st.decision.reason=='nominal_safe')
    st.player.inputDir=Vector(0,0); assert(run(st,hz)==nil)
end)
test('standing incoming shot is avoided with full movement input',function()
    local st=state(); local u=run(st,{shot(65,0,-5,0)})
    assert(u and math.abs(u.Y)>0.1,'must sidestep')
    assert(u:Length()>0.99,'dodge must use normal movement strength')
    assert(st.decision.metrics.selectedRisk<st.decision.metrics.nominalRisk)
    assert(st.decision.metrics.triggerKind=='projectile' and st.decision.metrics.triggerId=='p:1')
    assert(st.decision.metrics.plannedDisplacement>0 and st.decision.metrics.selectedSafe)
end)
test('recorded post-update movement integrates old velocity before new input',function()
    -- 附件 frame 6987 -> 6988：位置增量为 6987 的速度。
    local m={a=0.75,b=1.5}
    local x,y=Motion.step(m,289.14682006836,365.0940246582,
        0.43763017654419,-0.32838302850723,Vector(-0.18005627393723,-0.23995776474476))
    assert(math.abs(x-289.58444213867)<0.0001)
    assert(math.abs(y-364.76565551758)<0.0001)
    local sx,sy=Motion.step(m,0,0,0,0,Vector(1,0))
    assert(sx==0 and sy==0,'new input cannot move post-update position immediately')
end)
test('limited search reaches a full-strength escape before braking candidates',function()
    local st=state();st.config.plannerMaxCandidates=2
    local u=run(st,{shot(65,0,-5,0)})
    assert(u and u:Length()>0.99 and math.abs(u.Y)>0.99)
    assert(st.decision.metrics.selectedDuration==st.config.plannerHorizon)
    assert(st.decision.metrics.selectedRisk==0)
end)
test('braking command can suppress movement axes while preserving trigger and shooting',function()
    local Writer=require('control/input_writer')
    local c={active=true,direction=Vector(0,0),frame=0}
    SMOKE.frameCount=0; local p={Type=EntityType.ENTITY_PLAYER}
    assert(Writer.onInputAction(c,false,p,InputHook.GET_ACTION_VALUE,ButtonAction.ACTION_RIGHT)==0)
    assert(Writer.onInputAction(c,false,p,InputHook.IS_ACTION_PRESSED,ButtonAction.ACTION_RIGHT)==false)
    assert(Writer.onInputAction(c,false,p,2,ButtonAction.ACTION_RIGHT)==nil)
    assert(Writer.onInputAction(c,false,p,InputHook.GET_ACTION_VALUE,ButtonAction.ACTION_SHOOTLEFT)==nil)
    c.readingRaw=true; assert(Writer.onInputAction(c,false,p,0,ButtonAction.ACTION_RIGHT)==nil)
end)
test('large delayed area attack permits a longer retreat',function()
    local st=state()
    local u=run(st,{{kind='bomb',id='b:1',pos=Vector(0,0),vel=Vector(0,0),radius=65,speed=0,appearFrame=17,endFrame=18}})
    assert(u and u:Length()>0.9,'must move enough to leave the blast')
    assert(st.decision.metrics.selectedRisk==0,'reachable blast escape should be found')
end)
test('overlap chooses decreasing exposure instead of freezing at TTC zero',function()
    local st=state(); local u=run(st,{{kind='enemy',id='e:1',pos=Vector(5,0),vel=Vector(0,0),radius=18,speed=0}})
    assert(u and u.X<0,'escape away from overlapping enemy')
    assert(st.decision.metrics.selectedRisk<st.decision.metrics.nominalRisk)
end)
test('corner escape path does not drive through a rock',function()
    local r=room(); r.solids[40]=GridCollisionClass.COLLISION_SOLID
    local ter=Terrain.create();ter:build(r,false,Defaults.get())
    local st=state();st.player.position=Vector(124,160)
    local u=run(st,{shot(70,160,5,0)},ter)
    assert(u and math.abs(u.Y)>0.1,'must use a reachable lateral route')
    local x,y=Motion.step(Motion.ensure(st),124,160,0,0,u)
    assert(ter:segmentSafe(st.player.position,Vector(x,y),10,true))
end)
test('hard budget never selects a partially checked candidate',function()
    local st=state();st.config.plannerMaxChecks=1
    local u=run(st,{shot(65,0,-5,0)})
    assert(u==nil and not st.decision.metrics.nominalComplete)
    assert(st.decision.reason=='baseline_budget_incomplete')
end)
test('Alt suspension clears commands, locks, diagnostics and keeps raw input',function()
    local st=state();st.player.inputDir=Vector(-1,0)
    st.control.active=true;st.control.weight=0.8;st.control.direction=Vector(1,0)
    st.decision.dodgeDir=Vector(1,0);st.decision.planner={last=Vector(1,0)}
    st.userEnabled=false;Runtime.suspendThreat(st)
    local snap=require('recording/snapshot').capture(st,1,4)
    require('recording/snapshot').finalize(snap,st,4,{},st.config)
    assert(not snap.active and not snap.enabled and snap.weight==0 and snap.cx==0 and snap.ix==-1)
    assert(st.decision.planner==nil)
end)
test('projectile 301 approaching player survives budgeted selection',function()
    SMOKE.entities={}
    for i=1,301 do
        local x=i<=300 and 1000+i or 20
        SMOKE.entities[i]={Type=EntityType.ENTITY_PROJECTILE,Index=i,InitSeed=i,SpawnerType=0,
            Position=Vector(x,0),Velocity=Vector(-4,0),Size=4,IsDead=function() return false end}
    end
    local tr=Tracker.create();local st=state()
    require('sensors/projectiles').collect(st.player,tr,1,st.config)
    assert(tr.tracked[301] and tr.count==300 and tr.omittedCount==1)
    SMOKE.entities={}
end)
test('recorder write and flush failures remain visible without dropping buffered events',function()
    for _,method in ipairs({'write','flush'}) do
        local sr=require('recording/session_recorder').create()
        sr.file={write=function(self) return self end,flush=function() return true end,close=function() return true end}
        sr.file[method]=function() return nil,'disk full' end
        sr:writeLine('{"ev":"hit"}',true)
        assert(sr:flush()==false and sr.failed and sr.lineCount==1)
        assert(sr:flush()==false and sr.lastError=='disk full')
    end
end)
test('live recorder buffers writes without forcing a flush each frame',function()
    local sr=require('recording/session_recorder').create()
    local writes,flushes=0,0
    sr.file={write=function(self) writes=writes+1;return self end,
        flush=function() flushes=flushes+1;return true end,close=function() return true end}
    for frame=1,3 do sr:writeLine('{}');sr:tickWriter() end
    assert(writes==3 and flushes==0 and sr.lineCount==0)
    sr:writeLine('{}');sr:flush()
    assert(flushes==1,'explicit flush still supported for lifecycle durability')
end)
test('slow synchronous write pauses subsequent I/O while preserving a bounded queue',function()
    local sr=require('recording/session_recorder').create({recorderSlowWriteMs=8,recorderMaxBytes=256})
    local oldClock=Isaac.GetTime;local now,writes=0,0
    Isaac.GetTime=function() return now end
    sr.file={write=function(self) writes=writes+1;now=now+45;return self end,
        flush=function() error('live frames must not force flush') end}
    sr:writeLine('{}');sr:tickWriter()
    local paused,latency=sr.ioPaused,sr.lastWriteMs
    for frame=1,100 do sr:writeLine('0123456789');sr:tickWriter() end
    Isaac.GetTime=oldClock
    assert(paused and latency==45 and sr.maxWriteMs==45)
    assert(writes==1 and sr.queuedBytes<=256 and sr.dropped>0)
    assert(sr:statusText():find('暂停',1,true))
end)
test('paused recorder keeps newest snapshots and critical events in sequence at close',function()
    local sr=require('recording/session_recorder').create({recorderMaxBytes=512})
    local writes,output=0,''
    sr.file={write=function(self,s) writes=writes+1;output=output..s;return self end,
        flush=function() return true end,close=function() return true end}
    sr.ioPaused=true
    sr:event({ev='hit',frame=1})
    for frame=2,100 do sr:push({frame=frame,px=frame});sr:tickWriter() end
    assert(writes==0 and sr.queuedBytes<=512 and sr.dropped>0)
    sr:closeFile()
    assert(output:find('"hit"',1,true) and output:find('"frame":100',1,true))
    local previous=0
    for seq in output:gmatch('"seq"%s*:%s*(%d+)') do
        assert(tonumber(seq)>previous,'retained records must preserve sequence order');previous=tonumber(seq)
    end
    assert(sr.queuedBytes==0 and sr.file==nil)
end)
test('existing recording directory does not spawn a mkdir process on session start',function()
    local sr=require('recording/session_recorder').create()
    local oldOpen,oldExecute=io.open,os.execute
    local spawned=0
    sr.available=true;sr.dir='mock'
    io.open=function() return {write=function(self) return self end,
        flush=function() return true end,close=function() return true end} end
    os.execute=function() spawned=spawned+1 end
    local ok=sr:startSession('seed',{})
    sr:closeFile()
    io.open,os.execute=oldOpen,oldExecute
    assert(ok and spawned==0)
end)
test('recorder queue and flush batch are bounded; JSON escapes user strings',function()
    local sr=require('recording/session_recorder').create({recorderMaxBytes=128,recorderBatchBytes=16})
    local out={}
    sr.file={write=function(self,s) out[#out+1]=s;return self end,flush=function() return true end}
    for i=1,100 do sr:writeLine('12345678') end
    assert(sr.queuedBytes<=128 and sr.dropped>0)
    sr:flush(16);assert(#out[1]==9)
    local json=require('utils/json_encode')
    assert(json({s='a"\n\\',enabled=false}):find('a\\"\\n\\\\',1,true))
end)
test('event prehistory is immutable, bounded, and overlapping triggers merge',function()
    local cfg=Defaults.get();cfg.eventRecording=true;cfg.eventPreFrames=3;cfg.eventPostFrames=2;cfg.eventMaxBytes=100
    local ev=require('recording/event_buffer').create(cfg)
    local sr={event=function() end,context=function() return true end}
    for i=1,5 do ev:record('{"frame":'..i..'}',i) end
    ev:trigger('damage',5,sr);local id=ev.id
    ev:trigger('blocked',6,sr);assert(ev.id==id)
    for i=6,30 do ev:record('{"frame":'..i..'}',i);ev:drain(i,sr) end
    assert(ev.bytes<=100 and ev.count<=6 and ev.nextExport==nil)
end)
test('death replay stats use all frames, not display sampling',function()
    local rb=require('recording/ring_buffer').create(120)
    for i=1,120 do rb:push({frame=i,threat=i==2 and 1 or 0.1,layer='predictive'}) end
    local lines=require('recording/death_replay').dumpLines(rb,4)
    assert(lines[#lines-1]:find('峰值威胁=1.00',1,true) and lines[#lines-1]:find('120/120',1,true))
end)
test('closed loop avoids projectile with post-update position timing',function()
    local st=state();local pos,vel=Vector(0,0),Vector(0,0)
    local closest,maxDistance=9999,0
    for frame=0,59 do
        st.player.position,st.player.velocity=pos,vel
        local h=shot(65-5*frame,0,-5,0)
        local u=run(st,{h},nil,frame) or Vector(0,0)
        local nextVel=vel*0.75+u*1.5
        local nextPos=pos+vel
        -- 独立相对线段检测，验证实际执行的每一小步，没有复用规划评分。
        local ax,ay=pos.X-h.pos.X,pos.Y-h.pos.Y
        local dx,dy=vel.X+5,vel.Y
        local d=dx*dx+dy*dy
        local t=d>0 and math.max(0,math.min(1,-(ax*dx+ay*dy)/d)) or 0
        closest=math.min(closest,math.sqrt((ax+dx*t)^2+(ay+dy*t)^2))
        pos,vel=nextPos,nextVel
        maxDistance=math.max(maxDistance,pos:Length())
    end
    assert(closest>=15,'execution hit the projectile: '..closest)
    assert(vel:Length()<0.01,'must brake after the shot passes')
end)
test('new safe keyboard intent releases an old avoidance direction',function()
    local st=state();run(st,{shot(65,0,-5,0)})
    st.player.inputDir=Vector(-1,0)
    local u=run(st,{shot(65,0,5,0)},nil,1)
    assert(u==nil and st.decision.reason=='nominal_safe')
end)
test('own bomb uses actual countdown and flight only filters ground creep',function()
    local st=state();local tr=Tracker.create()
    SMOKE.entities={{Type=EntityType.ENTITY_BOMB,Index=42,Position=Vector(20,0),Velocity=Vector(0,0),Size=10,
        SpawnerType=EntityType.ENTITY_PLAYER,IsDead=function() return false end,
        ToBomb=function() return {ExplosionCountdown=7,ExplosionDamage=12,RadiusMultiplier=1} end}}
    require('sensors/bombs').collect(st.player,tr,10,st.config)
    assert(tr.tracked[42].appearFrame==17 and tr.tracked[42].timingKnown)
    SMOKE.entities={{Type=EntityType.ENTITY_EFFECT,Index=43,Variant=22,Position=Vector(0,0),Velocity=Vector(0,0),Size=10,IsDead=function() return false end},
        {Type=EntityType.ENTITY_EFFECT,Index=44,Variant=61,Position=Vector(0,0),Velocity=Vector(0,0),Size=10,IsDead=function() return false end}}
    tr=Tracker.create();st.player.canFly=true;st.config.hazardCreep=false
    require('sensors/effects').collect(st.player,tr,10,st.config)
    assert(not tr.tracked[43] and tr.tracked[44])
    SMOKE.entities={}
end)
test('default toggle key is the engine Keyboard code for left Alt',function()
    -- 旧值 56 在 GLFW 键盘码里是数字键 8 → 按 Alt 从未触发过（回放里 toggle 事件数=0）
    assert(Defaults.get().toggleKey==342,'left Alt must be 342, got '..tostring(Defaults.get().toggleKey))
end)
test('door cell (WALL_EXCEPT_PLAYER) is not treated as a wall',function()
    -- 回归: 门格锚点在房间形状之外 → 旧实现判成不可行走，玩家进门洞被判"在墙里 18px"
    local old=GridCollisionClass.COLLISION_WALL_EXCEPT_PLAYER
    GridCollisionClass.COLLISION_WALL_EXCEPT_PLAYER=5
    local r={GetGridWidth=function() return 3 end,GetGridSize=function() return 9 end,
        GetGridPosition=function(_,i) return Vector(i%3*40,math.floor(i/3)*40) end,
        GetGridEntity=function(_,i)
            return {CollisionClass=(i==0 and 5 or 0),GetType=function() return 0 end}
        end,
        -- 房间形状从 (0,0) 起；门格(0,0)的锚点在 (-20,-20) 之外
        IsPositionInRoom=function(_,p) return p.X>=0 and p.Y>=0 end}
    local t=Terrain.create(); t:build(r,false,Defaults.get())
    assert(t.grid[1].walkable,'door cell must be walkable')
    local hard,danger=t:probe(Vector(0,0),10)
    assert(hard==0 and danger==0,'doorway must not report penetration, got '..hard..'/'..danger)
    GridCollisionClass.COLLISION_WALL_EXCEPT_PLAYER=old
end)
test('spike cells are graded danger instead of hard walls',function()
    local r={GetGridWidth=function() return 3 end,GetGridSize=function() return 9 end,
        GetGridPosition=function(_,i) return Vector(i%3*40,math.floor(i/3)*40) end,
        GetGridEntity=function(_,i)
            if i==4 then return {CollisionClass=0,State=0,GetType=function() return GridEntityType.GRID_SPIKES end} end
            return {CollisionClass=0,GetType=function() return 0 end}
        end}
    local t=Terrain.create(); t:build(r,false,Defaults.get())
    local hard,danger=t:probe(Vector(20,20),10)
    assert(hard==0,'spike must not block movement (got hard='..hard..')')
    assert(danger>0,'spike must report danger depth')
    assert(t:isSafeAt(Vector(20,20),10,false),'hard-only safety ignores spikes')
    assert(not t:isSafeAt(Vector(20,20),10),'default safety still counts spikes')
end)
test('ai command is blended with player input, never fully overrides',function()
    local Writer=require('control/input_writer')
    local c={active=true,direction=Vector(0,0),frame=0,blendWeight=0.85,playerDir=Vector(1,0)}
    SMOKE.frameCount=0
    local p={Type=EntityType.ENTITY_PLAYER}
    -- AI 要停 + 玩家按右 → 只压到 15%（刹车），不是把玩家按住
    local v=Writer.onInputAction(c,false,p,InputHook.GET_ACTION_VALUE,ButtonAction.ACTION_RIGHT)
    assert(math.abs(v-0.15)<0.001,'brake must keep 15% of player input, got '..tostring(v))
    c.direction=Vector(1,0)
    v=Writer.onInputAction(c,false,p,InputHook.GET_ACTION_VALUE,ButtonAction.ACTION_RIGHT)
    assert(math.abs(v-1)<0.001,'same direction keeps full amplitude, got '..tostring(v))
end)
test('spike ring with bomb: planner escapes instead of freezing the player',function()
    -- 回放房93/房间83诅咒房格局: 十地刺环 + 宝箱开出的炸弹（引信读不到→窗口无限）
    local W=5
    local spikes={[5*1+2]=true,[5*2+1]=true,[5*2+3]=true,[5*3+2]=true} -- (2,1)(1,2)(3,2)(2,3)
    local r={GetGridWidth=function() return W end,GetGridSize=function() return W*W end,
        GetGridPosition=function(_,i) return Vector(i%W*40,math.floor(i/W)*40) end,
        GetGridEntity=function(_,i)
            if spikes[i] then
                return {CollisionClass=0,State=0,GetType=function() return GridEntityType.GRID_SPIKES end}
            end
            return {CollisionClass=0,GetType=function() return 0 end}
        end}
    local ter=Terrain.create(); ter:build(r,false,Defaults.get())
    local st=state()
    st.player.position=Vector(80,80)   -- 环心 (2,2)
    st.player.velocity=Vector(0,0)
    st.player.inputDir=Vector(-1,0)    -- 玩家按左（正对着地刺）
    local bomb={kind='bomb',id='b:9',pos=Vector(80,80),vel=Vector(0,0),speed=0,radius=90,damage=12}
    local u=run(st,{bomb},ter)
    assert(u,'trapped in blast + spike ring must not produce a stop/freeze')
    assert(u:Length()>0.9,'escape must be full strength, got '..tostring(u:Length()))
    assert(not (math.abs(u.X)<0.05 and math.abs(u.Y)<0.05),'command must point somewhere')
end)
test('flying player is not shoved off ground obstacles',function()
    -- 回放 20260911_205153: 飞行角色整局都带 canFly=true，101 个接管帧 100% 是
    -- terrain 触发、0 个真实威胁，12 帧输出与玩家输入完全反向（old walkable 只豁免
    -- OBJECT/PIT，SOLID 仍算墙 → 飞石头就被判“在墙里 10~30px”）。
    local cfg=Defaults.get()
    local r=room(); r.solids[40]=GridCollisionClass.COLLISION_SOLID
    local tFly=Terrain.create(); tFly:build(r,true,cfg)
    assert(tFly:isSafeAt(Vector(160,160),10),'rock must be passable while flying')
    local st=state(); st.player.canFly=true
    st.player.position=Vector(160,160); st.player.inputDir=Vector(1,0)
    local u=run(st,{},tFly,10)
    assert(u==nil and st.decision.reason=='nominal_safe','flying over a rock must not trigger a takeover, got '..tostring(st.decision.reason))
    assert(st.decision.metrics.initialPenetration==0,'no hard penetration while flying')
    -- 步行时石头仍然是硬地形（回归保护）
    local tWalk=Terrain.create(); tWalk:build(r,false,cfg)
    assert(not tWalk:isSafeAt(Vector(160,160),10),'rock still blocks a walking player')
    local st2=state(); st2.player.position=Vector(178,160); st2.player.inputDir=Vector(1,0)
    run(st2,{},tWalk,10)
    assert(st2.decision.metrics.initialPenetration>0,'walking into a rock still registers penetration')
    -- 飞行例外（wiki/Flight）: 柱子飞不过去；尖刺岩石/ TNT 能飞过但仍会受伤；地刺免疫
    local function gridRoom(coll,typ)
        return {GetGridWidth=function() return 3 end,GetGridSize=function() return 9 end,
            GetGridPosition=function(_,i) return Vector(i%3*40,math.floor(i/3)*40) end,
            GetGridEntity=function(_,i)
                if i==4 then return {CollisionClass=coll,State=0,VarData=1,GetType=function() return typ end} end
                return nil
            end}
    end
    local function centre(coll,typ,fly)
        local t=Terrain.create(); t:build(gridRoom(coll,typ),fly,cfg); return t
    end
    local tPillar=centre(GridCollisionClass.COLLISION_SOLID,24,true)
    assert(not tPillar:isSafeAt(Vector(40,40),10,false),'flight cannot pass over a pillar (GRID_PILLAR=24)')
    local tRockSpike=centre(GridCollisionClass.COLLISION_SOLID,GridEntityType.GRID_ROCK_SPIKED,true)
    assert(tRockSpike:isSafeAt(Vector(40,40),10,false),'flight passes over a spiked rock')
    assert(not tRockSpike:isSafeAt(Vector(40,40),10),'spiked rock still damages a flying player')
    local tTnt=centre(GridCollisionClass.COLLISION_OBJECT,GridEntityType.GRID_TNT,true)
    -- wiki/TNT: TNT 只在被摧毁时爆炸（接触不爆）→ 飞行时它只是可飞越障碍，不再算危险
    assert(tTnt:isSafeAt(Vector(40,40),10),'flying over TNT is safe (TNT only explodes when destroyed)')
    local tTntWalk=centre(GridCollisionClass.COLLISION_OBJECT,GridEntityType.GRID_TNT,false)
    assert(not tTntWalk:isSafeAt(Vector(40,40),10,false) and not tTntWalk:isSafeAt(Vector(40,40),10),
        'walking: TNT still blocks and stays a hazard')
    local tSpike=centre(GridCollisionClass.COLLISION_NONE,GridEntityType.GRID_SPIKES,true)
    assert(tSpike:isSafeAt(Vector(40,40),10),'flight is immune to spikes')
end)
test('fireplace corner is dangerous and the planner evaluates the blended output',function()
    -- 火堆是方形（半边长 = MAX(Size,16)），4 个角伸到约 23px；只用内切圆会把这些角
    -- 当成安全区 —— 用户反馈的“往火堆斜上方/斜下方躲却呕上”就是这里。
    -- 同时归定: 规划器评估的方向必须等于 input_writer 实际输出的混合方向。
    local cfg=Defaults.get()
    local fire={id='f:1',index=1,seed=1,kind='enemy',entityType=33,box=true,
        pos=Vector(240,280),vel=Vector(0,0),speed=0,radius=16.25,damage=1}
    local function plan(nearMissClearance)
        local st=state()
        st.config.nearMissClearance=nearMissClearance
        st.player.position=Vector(200,280)   -- 火堆左侧 40px
        st.player.velocity=Vector(0,0)
        st.player.inputDir=Vector(1,0)       -- 玩家按住“右”，直冲火堆
        local u=run(st,{fire},nil,10)
        local trace=st.decision.lastTrace
        assert(trace and #trace.candidates>2,'must evaluate candidates')
        local selected
        for _,c in ipairs(trace.candidates) do if c.id==st.decision.metrics.selectedId then selected=c end end
        return st,u,trace,selected
    end
    local st,u,trace,selected=plan(cfg.nearMissClearance)
    assert(u and selected,'a head-on run at a fireplace must plan something')
    local function nearOf(c,floor)
        if c.hit or not c.clearance or c.clearance>=floor then return 0 end
        return (floor-c.clearance)*cfg.nearMissRisk
    end
    -- 归定 1: 规划器评估的方向 = input_writer 实际输出的混合方向
    local w,nominal=cfg.maxDodgeWeight,Vector(1,0)
    for _,c in ipairs(trace.candidates) do
        assert(c.effX,'candidate trace must record the executed (blended) direction')
        local ex,ey=(1-w)*nominal.X+w*c.x,(1-w)*nominal.Y+w*c.y
        local len=math.sqrt(ex*ex+ey*ey)
        if len>1 then ex,ey=ex/len,ey/len end
        assert(math.abs(ex-c.effX)<0.001 and math.abs(ey-c.effY)<0.001,
            'evaluated direction must equal the blended output')
    end
    -- 归定 2: 近失（擦边）优先 —— 不能为了“更贴合玩家意图”选只差几 px 的擦边解
    local grazing
    for _,c in ipairs(trace.candidates) do
        if not c.terrain and math.abs(c.risk-selected.risk)<=cfg.riskTieEpsilon then
            assert(nearOf(c,cfg.nearMissClearance)>=nearOf(selected,cfg.nearMissClearance)-0.001,
                'a lighter-graze candidate was skipped')
            if nearOf(c,cfg.nearMissClearance)>0 then grazing=true end
        end
    end
    assert(grazing,'scenario must contain a grazing peer so the rule is exercised')
    assert(nearOf(selected,cfg.nearMissClearance)==0,'the comfortable direction must be chosen over the graze')
    assert(selected.clearance and selected.clearance>=cfg.nearMissClearance,'selected path must keep a real margin')
    -- 关掉近失规则必须退回“擦边但省代价”的选择 → 证明这条规则真的在起作用
    local _,_,_,selectedOff=plan(0)
    assert(selectedOff.clearance and selectedOff.clearance>0 and selectedOff.clearance<cfg.nearMissClearance,
        'without the rule the cheaper graze must win, got clearance '..tostring(selectedOff.clearance))
end)
test('hugging a wall is contact, not penetration (no wall-shoving)',function()
    -- 回放 220104: 555 段避让里 327 段（59%）是贴墙走的假触发。
    -- 实测玩家中心距实心格最近 9.2px（player.radius=10）→ 贴墙恒有 0.5~1.2px 假穿透，
    -- IsPositionInRoom(p,r) 在边界处又加 1px。不抹掉就会：拿不到 nominal_safe、
    -- peakDepth*10 把玩家推离墙、且 depth>0 短路“撞墙位置钉住”。
    local cfg=Defaults.get()
    -- 3x3 小房，中心格 (1,1) 为石头，玩家站在它左侧 9.4px 处（足迹刚好碰到）
    local r={GetGridWidth=function() return 3 end,GetGridSize=function() return 9 end,
        GetGridPosition=function(_,i) return Vector(i%3*40,math.floor(i/3)*40) end,
        GetGridEntity=function(_,i)
            if i==4 then return {CollisionClass=GridCollisionClass.COLLISION_SOLID,State=0,GetType=function() return GridEntityType.GRID_ROCK end} end
            if i==0 or i==2 or i==6 or i==8 then return {CollisionClass=GridCollisionClass.COLLISION_WALL,State=0,GetType=function() return 0 end} end
            return nil
        end}
    local ter=Terrain.create(); ter:build(r,false,cfg)
    -- 格(1,1) 的 AABB: topLeft=(-20,-20) → [20,60]x[20,60]；玩家在 (69.4,40) → 距离 9.4 → 足印重叠 0.6
    local hard,danger=ter:probe(Vector(69.4,40),10)
    assert(hard==0,'0.6px footprint overlap on a rock must not count as penetration, got '..tostring(hard))
    local deep=ter:probe(Vector(69.4-4,40),10)
    assert(deep>2,'a real penetration must still be reported, got '..tostring(deep))
    -- 规划器：贴墙按向石头（基对）不得因假穿透而接管
    local st=state(); st.config.wallContactSlack=cfg.wallContactSlack
    st.player.position=Vector(69.4,40); st.player.velocity=Vector(-6,0)
    st.player.inputDir=Vector(-1,0)
    local u=run(st,{},ter,10)
    assert(u==nil and st.decision.reason=='nominal_safe',
        'walking into a wall you are already touching must not trigger avoidance, got '..tostring(st.decision.reason))
    assert(st.decision.metrics.initialPenetration==0,'no phantom initial penetration')
    -- 关掉裕量（旧行为）必须重现假穿透 → 证明这条修改真的在起作用
    local cfgOld=Defaults.get(); cfgOld.wallContactSlack=0
    local terOld=Terrain.create(); terOld:build(r,false,cfgOld)
    local stOld=state()
    stOld.player.position=Vector(69.4,40); stOld.player.velocity=Vector(-6,0)
    stOld.player.inputDir=Vector(-1,0)
    run(stOld,{},terOld,10)
    assert(stOld.decision.metrics.initialPenetration>0,'legacy behaviour must report the phantom penetration')
end)
print(string.format('SHARED CONTROL: %d passed, %d failed',checks-failures,failures))
assert(failures==0,'shared control regressions failed')
