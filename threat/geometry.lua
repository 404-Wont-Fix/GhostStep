-- 所有决策共用的时空几何。圆体使用相对运动的连续线段最近点；
-- 激光使用时段中点线段及端点扫掠上界（保守覆盖一帧内的旋转/平移）。
local G={}
local Future=require("threat/future_motion")
local Predict=require("threat/projectile_predict")
local function pointSeg(px,py,ax,ay,bx,by)
    local dx,dy=bx-ax,by-ay
    local d=dx*dx+dy*dy
    local t=d>1e-9 and math.max(0,math.min(1,((px-ax)*dx+(py-ay)*dy)/d)) or 0
    return math.sqrt((px-ax-t*dx)^2+(py-ay-t*dy)^2)
end
-- 敌人与玩家的更新不保证同时积分。除同步相对轨迹外，覆盖敌人先移动、
-- 玩家随后移动的两段接触过程；不改变弹体、炸弹和激光的时序。
local function circleClearance(kind,px,py,qx,qy,ex,ey,fx,fy,r)
    local clear=pointSeg(0,0,px-ex,py-ey,qx-fx,qy-fy)-r
    if kind=="enemy" and clear>0 then
        clear=math.min(clear,pointSeg(px,py,ex,ey,fx,fy)-r,
            pointSeg(fx,fy,px,py,qx,qy)-r)
    end
    return clear
end
-- 静态方形碰撞体（火堆等格实体）: 玩家中心到 AABB 的距离 - (玩家半径+margin)。
-- 必须用方形而不能用内切圆: 方形 4 个角伸到 Size*√2 ≈ 1.41×Size，内切圆漏掉
-- 这部分，于是“斜向擦着角过去”被判成安全（回放/闭环复现里就是这种碰撞）。
-- 一段位移只有几像素（≤6px/帧），取两端点+中点的最小值即可覆盖。
local function boxClearance(px,py,qx,qy,cx,cy,half,r)
    -- 一段位移只有几像素（≤6px/帧），取两端点+中点覆盖；不构造临时表（每帧要算几十万次）
    local best
    do
        local dx,dy=math.abs(px-cx)-half,math.abs(py-cy)-half
        if dx<0 then dx=0 end
        if dy<0 then dy=0 end
        best=math.sqrt(dx*dx+dy*dy)
    end
    do
        local mx,my=(px+qx)*0.5,(py+qy)*0.5
        local dx,dy=math.abs(mx-cx)-half,math.abs(my-cy)-half
        if dx<0 then dx=0 end
        if dy<0 then dy=0 end
        local d=math.sqrt(dx*dx+dy*dy)
        if d<best then best=d end
    end
    do
        local dx,dy=math.abs(qx-cx)-half,math.abs(qy-cy)-half
        if dx<0 then dx=0 end
        if dy<0 then dy=0 end
        local d=math.sqrt(dx*dx+dy*dy)
        if d<best then best=d end
    end
    return best-r
end
G.pointSegmentDistance=pointSeg
function G.window(e,frame)
    local start=e.appearFrame or (e.fuseFrames and ((e.lastFrame or frame)+e.fuseFrames))
    return start and start-frame or 0, e.endFrame and e.endFrame-frame or math.huge
end
function G.sample(e,t,frame,cache)
    local k=t
    if cache and cache[k]~=nil then return cache[k] or nil end
    -- 运动基准从最后观测外推；生效判断仍基于当前时间。
    local age=math.max(0,frame-(e.lastFrame or frame))
    local a,b=Future.pos(e,t+age,e.lastFrame or frame)
    local v=a and {a.X,a.Y,b and b.X,b and b.Y} or false
    if cache then cache[k]=v end
    return v or nil
end
function G.prepare(e,frame,horizon)
    local c={}
    local age=math.max(0,frame-(e.lastFrame or frame))
    c.start,c.ending=G.window(e,frame)
    c.radius=(e.radius or 0)+(e.uncertainty or 0)
    c.linear=e.kind~="laser" and not e.hopOn and not ((e.kind or "projectile")=="projectile"
        and ((e.historyCount or 0)>=3) and (Predict.isCurved(e) or Predict.isTracking(e) or Predict.isParabolic(e)))
    if c.linear then
        c.x,c.y=e.pos.X+e.vel.X*age,e.pos.Y+e.vel.Y*age
        c.vx,c.vy=e.vel.X,e.vel.Y
        local lo,hi=math.max(0,c.start),math.min(horizon,c.ending)
        local ax,ay,bx,by=c.x+c.vx*lo,c.y+c.vy*lo,c.x+c.vx*hi,c.y+c.vy*hi
        c.minX,c.maxX=math.min(ax,bx)-c.radius,math.max(ax,bx)+c.radius
        c.minY,c.maxY=math.min(ay,by)-c.radius,math.max(ay,by)+c.radius
    end
    return c
end
function G.clearance(e,ax,ay,bx,by,r,t0,t1,frame,cache)
    local active,ending
    if cache and cache.start then active,ending=cache.start,cache.ending else active,ending=G.window(e,frame) end
    local lo,hi=math.max(t0,active),math.min(t1,ending)
    if lo>hi then return math.huge end
    local dt=t1-t0
    local p0x,p0y,p1x,p1y=ax,ay,bx,by
    if dt>0 then
        p0x,p0y=ax+(bx-ax)*(lo-t0)/dt,ay+(by-ay)*(lo-t0)/dt
        p1x,p1y=ax+(bx-ax)*(hi-t0)/dt,ay+(by-ay)*(hi-t0)/dt
    end
    if cache and cache.linear then
        -- 方形危险体（火堆）: 静止，忽略外推速度，按 AABB 算
        if e.box then
            local half=(e.radius or 0)+(e.uncertainty or 0)
            return boxClearance(p0x,p0y,p1x,p1y,cache.x,cache.y,half,r)
        end
        return circleClearance(e.kind,p0x,p0y,p1x,p1y,
            cache.x+cache.vx*lo,cache.y+cache.vy*lo,
            cache.x+cache.vx*hi,cache.y+cache.vy*hi,r+cache.radius)
    end
    local a,b=G.sample(e,lo,frame,cache),G.sample(e,hi,frame,cache)
    if not a or not b then return math.huge end
    local radius=r+(e.radius or 0)+(e.uncertainty or 0)
    if a[3] then
        local mid=G.sample(e,(lo+hi)/2,frame,cache)
        local moveA=math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2)*0.5
        local moveB=math.sqrt((a[3]-b[3])^2+(a[4]-b[4])^2)*0.5
        local sweep=math.max(moveA,moveB)
        local playerSweep=math.sqrt((p1x-p0x)^2+(p1y-p0y)^2)*0.5
        return pointSeg((p0x+p1x)/2,(p0y+p1y)/2,mid[1],mid[2],mid[3],mid[4])-radius-sweep-playerSweep
    end
    return circleClearance(e.kind,p0x,p0y,p1x,p1y,a[1],a[2],b[1],b[2],radius)
end
-- 包围可达区域筛选。长激光按长度扩展，不能只拿光源附近的九宫格。
function G.reachable(e,p,r,speed,horizon)
    local extent=e.endPos and e.pos:Distance(e.endPos) or (e.length or 0)
    -- 跳跃威胁：待跳时自报速度≈0，但伤害发生在跳距之外的落点 → 用跳距扩展可达范围，
    -- 否则安静的跳蛛会被“reachable”预筛掉，预测永远不会生效。
    local leap=(e.hopOn and (e.hopLen or 0)) or 0
    local reach=r+(e.radius or 0)+(e.uncertainty or 0)+extent+leap+((e.speed or e.vel:Length())+speed)*horizon
    return e.pos:Distance(p)<=reach
end
return G
