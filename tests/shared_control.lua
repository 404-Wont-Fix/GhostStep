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
print(string.format('SHARED CONTROL: %d passed, %d failed',checks-failures,failures))
assert(failures==0,'shared control regressions failed')
