local History = require("entities/tracker")
-- threat/projectile_predict.lua
-- 弹幕轨迹预测
--   Phase 1: 直线闭式解（二次方程求根，无逐步模拟）
--   Phase 2: 弧线预测（三点圆拟合）+ 历史平均速度平滑
-- atan2 兼容: Lua 5.1 有 math.atan2，5.3 合并进 math.atan(y,x)
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local mathext = require("utils/math_ext")

local Predict = {}

--- 直线预测：t 帧后弹幕位置
--- entry: 追踪器条目 { pos, vel, ... }
function Predict.linearPos(entry, t)
    return entry.pos + entry.vel * t
end

--- 求解 |rel + closing*t|^2 = combined^2 的最小非负根（无根返回 nil）
--- closing: 相对接近速度（弹幕接近玩家方向的速度分量）
local function solveHit(rx, ry, cx, cy, combined, horizon)
    local a = cx * cx + cy * cy
    if a < 0.0001 then
        -- 无相对运动：看当前是否已重叠
        if rx * rx + ry * ry <= combined * combined then return 0 end
        return nil
    end
    local halfB = rx * cx + ry * cy
    local c = rx * rx + ry * ry - combined * combined
    if c <= 0 then return 0 end -- 已重叠
    -- 逼近条件: halfB < 0（相对速度朝向对方）
    local disc = halfB * halfB - a * c
    if disc < 0 then return nil end -- 永不相交
    local sq = math.sqrt(disc)
    local t = (-halfB - sq) / a -- 首次进入碰撞的时刻
    if t < 0 then
        -- 已在圆内：出口时刻（当前0重叠由 c<=0 处理，这里 t<0 且 c>0 不应出现）
        return nil
    end
    if t > horizon then return nil end
    return t
end

--- 静止玩家的碰撞检测
--- 弹幕位置 entry.pos + vel*t 与玩家 playerPos 的距离 <= combined
--- 等价于 |(playerPos - entry.pos) - vel*t| <= combined
function Predict.timeToHit(entry, playerPos, playerRadius, horizon)
    local rel = playerPos - entry.pos
    -- 接近速度: -vel（弹幕朝玩家方向的等效相对速度）
    return solveHit(rel.X, rel.Y, -entry.vel.X, -entry.vel.Y,
        entry.radius + playerRadius, horizon)
end

--- 玩家移动时的碰撞检测（用于路径模拟）
--- 相对位置 rel = playerPos - entry.pos，相对速度 = playerVel - entry.vel
function Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
    local rel = playerPos - entry.pos
    return solveHit(rel.X, rel.Y,
        playerVel.X - entry.vel.X, playerVel.Y - entry.vel.Y,
        entry.radius + playerRadius, horizon)
end

---------------------------------------------------------------
-- Phase 2: 弧线弹幕预测（三点圆拟合）
---------------------------------------------------------------

--- 三点圆拟合。p1/p2/p3: {pos=Vector, frame=N}
--- 返回 { cx, cy, r, omega(角速度,弧度/帧,带符号) } 或 nil（共线/退化）
local function fitCircle(p1, p2, p3)
    local ax, ay = p1.pos.X, p1.pos.Y
    local bx, by = p2.pos.X, p2.pos.Y
    local cx, cy = p3.pos.X, p3.pos.Y
    local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if math.abs(d) < 1e-9 then return nil end
    local a2 = ax * ax + ay * ay
    local b2 = bx * bx + by * by
    local c2 = cx * cx + cy * cy
    local ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    local uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    local r = math.sqrt((ax - ux) ^ 2 + (ay - uy) ^ 2)
    if r < 1 or r > 3000 then return nil end -- 半径过大≈直线，交给闭式解
    -- 角速度: 用相邻两帧相对圆心的角度差（短弧，无需处理回绕歧义）
    local a1 = atan2(by - uy, bx - ux)
    local a2_ = atan2(cy - uy, cx - ux)
    local dt = p3.frame - p2.frame
    if dt <= 0 then return nil end
    local dAng = a2_ - a1
    if dAng > math.pi then dAng = dAng - 2 * math.pi end
    if dAng < -math.pi then dAng = dAng + 2 * math.pi end
    return { cx = ux, cy = uy, r = r, omega = dAng / dt, a0 = a2_ }
end

--- entry 是否呈曲线运动（历史≥3 且拟合出小圆）
--- curvatureMinOmega: 角速度低于此视为直线
function Predict.isCurved(entry, minOmega)
    if not entry.history or entry.historyCount < 3 then return false end
    -- 脏样本（同一位置被记进相邻两帧）会让弧线/抛物线拟合把轨迹掰向反方向
    -- （回放 220104 受击2: 直线弹幕被预测成掉头 → 规划器判无威胁），必须先过滤
    if not History.motionConsistent(entry) then return false end
    local h = entry.history
    local n = entry.historyCount
    local c = fitCircle(History.recent(entry,2), History.recent(entry,1), History.recent(entry,0))
    if not c then return false end
    return math.abs(c.omega) >= (minOmega or 0.02)
end

---------------------------------------------------------------
-- Phase 2.1: 追踪型弹幕检测 + 预测
---------------------------------------------------------------

--- 从速度历史检测追踪型弹幕（速度方向持续变化 = 追踪/自导引）
--- 返回: true 如果速度方向在连续样本间有显著转向
local TRACKING_ANGLE_THRESHOLD = 0.05 -- 每帧转向角阈值（弧度，约3度）
function Predict.isTracking(entry)
    if not entry.history or entry.historyCount < 3 then return false end
    if not History.motionConsistent(entry) then return false end
    local h = entry.history
    local n = entry.historyCount
    -- 取最近3个样本的速度方向，检查是否持续转向
    local turns = 0
    for i = n - 2, n - 1 do
        local v1 = History.recent(entry,n-i).vel
        local v2 = History.recent(entry,n-i-1).vel
        local len1 = v1:Length()
        local len2 = v2:Length()
        if len1 > 0.5 and len2 > 0.5 then
            local dot = (v1.X * v2.X + v1.Y * v2.Y) / (len1 * len2)
            dot = mathext.clamp(dot, -1, 1)
            local angle = math.acos(dot)
            if angle > TRACKING_ANGLE_THRESHOLD then
                turns = turns + 1
            end
        end
    end
    return turns >= 2 -- 连续两帧都有转向 = 追踪型
end

--- 追踪型弹幕命中检测：用最近速度趋势线性外推（追踪弹通常朝玩家逼近）
--- 比纯直线闭式解更准（考虑了速度变化趋势），但不如完整弧线拟合
function Predict.timeToHitTracking(entry, playerPos, playerVel, playerRadius, horizon)
    if not entry.history or entry.historyCount < 2 then
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
    end
    local h = entry.history
    local n = entry.historyCount
    -- 用最近两帧的平均速度（趋势速度）代替瞬时速度
    local avgVelX = (History.recent(entry,1).vel.X + History.recent(entry,0).vel.X) / 2
    local avgVelY = (History.recent(entry,1).vel.Y + History.recent(entry,0).vel.Y) / 2
    local rel = playerPos - entry.pos
    local vrelX = playerVel.X - avgVelX
    local vrelY = playerVel.Y - avgVelY
    local combined = entry.radius + playerRadius
    return solveHit(rel.X, rel.Y, vrelX, vrelY, combined, horizon)
end

--- 弧线命中检测: 沿圆弧步进采样（步长2帧），返回首帧命中或 nil
function Predict.timeToHitArc(entry, playerPos, playerVel, playerRadius, horizon)
    if not entry.history or entry.historyCount < 3 then return nil end
    if not History.motionConsistent(entry) then return nil end
    local h = entry.history
    local n = entry.historyCount
    local c = fitCircle(History.recent(entry,2), History.recent(entry,1), History.recent(entry,0))
    if not c then return nil end

    local combined = entry.radius + playerRadius
    local combinedSq = combined * combined
    -- 玩家移动时相对采样: 弹幕圆弧位置 vs 玩家线性外推位置
    for t = 0, horizon, 2 do
        local ang = c.a0 + c.omega * t
        local px = c.cx + c.r * math.cos(ang)
        local py = c.cy + c.r * math.sin(ang)
        local plx = playerPos.X + playerVel.X * t
        local ply = playerPos.Y + playerVel.Y * t
        local dx, dy = px - plx, py - ply
        if dx * dx + dy * dy <= combinedSq then
            return t
        end
    end
    return nil
end

---------------------------------------------------------------
-- Phase 2.2: 抛物线弹幕检测 + 预测
-- 以撒中部分弹幕（爆炸弹丸等 ENTITY_PROJECTILE 变体）沿抛物线飞行：
-- 2D 阴影位置先减速（上升）再加速（下落），加速度近似恒定（重力投影）。
-- 三点圆拟合不适用（抛物线不是圆弧），直线外推误差大。
---------------------------------------------------------------

--- 恒定加速度阈值（像素/帧²）：低于此视为直线/噪声
local PARABOLIC_ACCEL_THRESHOLD = 0.3

--- 检测抛物线运动：二阶位置差分呈恒定加速度，且加速度方向与速度变化一致
--- 优先于圆弧检测：抛物线局部可近似圆弧，但物理特征（恒定加速度方向）更可靠
function Predict.isParabolic(entry)
    if not entry.history or (entry.historyCount or 0) < 3 then return false end
    if not History.motionConsistent(entry) then return false end
    local p0 = History.recent(entry,2)
    local p1 = History.recent(entry,1)
    local p2 = History.recent(entry,0)
    local dt01 = p1.frame - p0.frame
    local dt12 = p2.frame - p1.frame
    if dt01 <= 0 or dt12 <= 0 then return false end
    -- 二阶差分 = 恒定加速度（重力在2D平面的投影）
    local ax = (p2.pos.X - p1.pos.X) / dt12 - (p1.pos.X - p0.pos.X) / dt01
    local ay = (p2.pos.Y - p1.pos.Y) / dt12 - (p1.pos.Y - p0.pos.Y) / dt01
    local accelSq = ax * ax + ay * ay
    if accelSq < PARABOLIC_ACCEL_THRESHOLD * PARABOLIC_ACCEL_THRESHOLD then return false end
    -- 验证：加速度方向应与连续速度变化方向一致（排除随机噪声）
    local dvx1 = (p1.pos.X - p0.pos.X) / dt01
    local dvy1 = (p1.pos.Y - p0.pos.Y) / dt01
    local dvx2 = (p2.pos.X - p1.pos.X) / dt12
    local dvy2 = (p2.pos.Y - p1.pos.Y) / dt12
    local ddvx, ddvy = dvx2 - dvx1, dvy2 - dvy1
    return (ax * ddvx + ay * ddvy) > 0
end

--- 抛物线位置预测：pos + vel*t + 0.5*accel*t²
function Predict.predictParabolicPos(entry, t)
    if not entry.history or (entry.historyCount or 0) < 3 then
        return entry.pos + entry.vel * t
    end
    local p0 = History.recent(entry,2)
    local p1 = History.recent(entry,1)
    local p2 = History.recent(entry,0)
    local dt01 = p1.frame - p0.frame
    local dt12 = p2.frame - p1.frame
    if dt01 <= 0 or dt12 <= 0 then return entry.pos + entry.vel * t end
    local ax = (p2.pos.X - p1.pos.X) / dt12 - (p1.pos.X - p0.pos.X) / dt01
    local ay = (p2.pos.Y - p1.pos.Y) / dt12 - (p1.pos.Y - p0.pos.Y) / dt01
    return Vector(
        entry.pos.X + entry.vel.X * t + 0.5 * ax * t * t,
        entry.pos.Y + entry.vel.Y * t + 0.5 * ay * t * t
    )
end

--- 抛物线碰撞检测：逐步采样（步长2帧），返回首帧命中或 nil
--- 同时检测速度反向（抛物线最高点后下落），超过最高点+余量后截断
function Predict.timeToHitParabolic(entry, playerPos, playerVel, playerRadius, horizon)
    if not entry.history or (entry.historyCount or 0) < 3 then
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
    end
    if not History.motionConsistent(entry) then
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
    end
    local p0 = History.recent(entry,2)
    local p1 = History.recent(entry,1)
    local p2 = History.recent(entry,0)
    local dt01 = p1.frame - p0.frame
    local dt12 = p2.frame - p1.frame
    if dt01 <= 0 or dt12 <= 0 then
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
    end
    local ax = (p2.pos.X - p1.pos.X) / dt12 - (p1.pos.X - p0.pos.X) / dt01
    local ay = (p2.pos.Y - p1.pos.Y) / dt12 - (p1.pos.Y - p0.pos.Y) / dt01
    local accelSq = ax * ax + ay * ay
    if accelSq < 0.0001 then
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
    end
    -- 估算最高点帧（速度在加速度方向投影为0）
    local vDotA = entry.vel.X * ax + entry.vel.Y * ay
    local tApex = -vDotA / accelSq
    -- 最高点后给20帧余量（下落阶段仍可能命中），但不超过 horizon
    local maxT = math.min(horizon, math.max(horizon, math.ceil(tApex + 20)))
    local combined = entry.radius + playerRadius
    local combinedSq = combined * combined
    for t = 0, maxT, 2 do
        local ex = entry.pos.X + entry.vel.X * t + 0.5 * ax * t * t
        local ey = entry.pos.Y + entry.vel.Y * t + 0.5 * ay * t * t
        local px = playerPos.X + playerVel.X * t
        local py = playerPos.Y + playerVel.Y * t
        local dx, dy = ex - px, ey - py
        if dx * dx + dy * dy <= combinedSq then
            return t
        end
    end
    return nil
end
---------------------------------------------------------------

--- 弹幕命中路径的墙壁抽查：闭式解给出命中帧 t 后，抽查路径上 3 个点，
--- 任一点在不可通行格内 → 弹幕会先撞墙 → 该威胁对墙后玩家无效。
--- 比"沿路径逐步模拟"便宜一个数量级，闭式解仍保精度。
--- terrain: Terrain 实例（invalid 或 nil 时不截断）
function Predict.pathBlockedByWall(entry, t, terrain)
    if not terrain or not terrain.valid or t <= 0 then return false end
    local samples = 3
    for i = 1, samples do
        local ti = t * i / (samples + 1)
        local probe = entry.pos + entry.vel * ti
        if not terrain:isWalkableAt(probe) then
            return true
        end
    end
    return false
end

return Predict
