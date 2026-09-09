-- 局部运动模型 v'=a*v+b*u。初值是待实机标定的近似；只在可用观测上做有界拟合。
local Motion={}
local Reader=require("control/input_reader")
function Motion.ensure(state)
    local speed=math.max(0.1,(state.player.moveSpeed or 1))*6
    local m=state.motion
    if not m or math.abs(m.speed-speed)>0.1 then
        m={speed=speed,a=0.75,b=speed*0.25,error=0,samples=0,vv=0,uu=0,vu=0,vy=0,uy=0,blockedFrames=0}
        state.motion=m
    end
    return m
end
function Motion.step(m,x,y,vx,vy,u)
    -- MC_POST_PLAYER_UPDATE 的速度在下一次位置积分中生效；输入再更新随后速度。
    local nx,ny=x+vx,y+vy
    vx,vy=m.a*vx+m.b*u.X,m.a*vy+m.b*u.Y
    return nx,ny,vx,vy
end
function Motion.observe(state,frame,terrain)
    local m=Motion.ensure(state)
    local prev=m.pending
    state.feedback=nil
    if not prev then return end
    local p=state.player
    local dt=frame-prev.frame
    local moved=p.position:Distance(prev.position)
    local expected=prev.nextPos:Distance(prev.position)
    local err=p.position:Distance(prev.nextPos)
    local velocityError=dt==1 and prev.nextVel and p.velocity:Distance(prev.nextVel) or nil
    local issued=prev.active and state.control.hookSeen==true
    state.feedback={decisionId=prev.id,dt=dt,error=err,progress=moved,expected=expected,hookSeen=issued,velocityError=velocityError,
        deltaX=p.position.X-prev.position.X,deltaY=p.position.Y-prev.position.Y,
        commandX=prev.input.X,commandY=prev.input.Y,commandActive=prev.active,
        predictedVelocityX=prev.nextVel and prev.nextVel.X,predictedVelocityY=prev.nextVel and prev.nextVel.Y}
    if dt~=1 then m.pending=nil; m.blockedFrames=0; return end
    local blocked=issued and expected>0.5 and moved<math.max(0.15,expected*0.15)
    m.blockedFrames=blocked and m.blockedFrames+1 or 0
    m.positionError=(m.positionError or 0)*0.9+math.min(err,20)*0.1
    m.velocityError=(m.velocityError or 0)*0.9+math.min(velocityError or 0,20)*0.1
    m.error=math.max(m.positionError,m.velocityError)
    if not blocked and p.controlsEnabled~=false and (p.damageCooldown or 0)==0
        and (not prev.active or issued) and err<8
        and (not terrain.valid or terrain:isSafeAt(p.position,p.radius+2)) then
        local u=prev.input
        m.vv=m.vv*0.97; m.uu=m.uu*0.97; m.vu=m.vu*0.97; m.vy=m.vy*0.97; m.uy=m.uy*0.97
        local axes={{prev.velocity.X,u.X,p.velocity.X},{prev.velocity.Y,u.Y,p.velocity.Y}}
        for _,v in ipairs(axes) do
            m.vv=m.vv+v[1]^2; m.uu=m.uu+v[2]^2; m.vu=m.vu+v[1]*v[2]
            m.vy=m.vy+v[1]*v[3]; m.uy=m.uy+v[2]*v[3]
        end
        m.samples=m.samples+1
        local det=m.vv*m.uu-m.vu*m.vu
        if m.samples>=12 and det>0.05 then
            local a=(m.vy*m.uu-m.uy*m.vu)/det
            local b=(m.uy*m.vv-m.vy*m.vu)/det
            if a>=0 and a<0.98 and b>0.05 and b<20 and b/(1-a)<m.speed*2 then
                m.a=m.a*0.9+a*0.1; m.b=m.b*0.9+b*0.1
            end
        end
    end
end
function Motion.commit(state,frame)
    local m=Motion.ensure(state)
    local u=state.control.active and state.control.direction or Reader.executable(state.player.inputDir)
    local p=state.player
    local x,y,vx,vy=Motion.step(m,p.position.X,p.position.Y,p.velocity.X,p.velocity.Y,u)
    m.pending={frame=frame,id=state.logicTick,position=p.position,velocity=p.velocity,input=u,
        active=state.control.active,nextPos=Vector(x,y),nextVel=Vector(vx,vy)}
    state.control.hookSeen=false
end
return Motion
