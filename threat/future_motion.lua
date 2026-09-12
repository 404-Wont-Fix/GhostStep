local History = require("entities/tracker")
-- threat/future_motion.lua
-- 统一未来位置外推器：按 entry.kind 路由运动模型
-- Tier 1 核心：让轨迹评分"看见"不同运动模式的威胁在未来的位置
--
-- 接口:
--   FutureMotion.pos(entry, t) → Vector, Vector|nil
--     弹幕/敌人/效果/npc_attack → 返回单个位置
--     laser → 返回线段两端 (a, b)
--     npc_attack 且 t < appearFrame → 返回 nil（届时还不存在）
--   FutureMotion.clearCache() → 房间切换时调用，清空圆弧参数缓存
--   FutureMotion.laserSegmentAt(entry, t) → Vector, Vector  (公开接口，供外部复用)

local FutureMotion = {}

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

---------------------------------------------------------------
-- 圆弧参数缓存（每威胁每帧拟合一次，候选循环内直接查表）
-- key: entry 的内存地址（tostring），val: { circle = {...}, frame = N }
---------------------------------------------------------------
local arcCache = {}
local arcCacheFrame = -1

--- 清空缓存（房间切换时调用）
function FutureMotion.clearCache()
    arcCache = {}
    arcCacheFrame = -1
end

---------------------------------------------------------------
-- 三点圆拟合（复用 projectile_predict 的逻辑，此处独立副本避免循环依赖）
---------------------------------------------------------------
local function fitCircle3(p1, p2, p3)
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
    if r < 1 or r > 3000 then return nil end
    local a1 = atan2(by - uy, bx - ux)
    local a2_ = atan2(cy - uy, cx - ux)
    local dt = p3.frame - p2.frame
    if dt <= 0 then return nil end
    local dAng = a2_ - a1
    if dAng > math.pi then dAng = dAng - 2 * math.pi end
    if dAng < -math.pi then dAng = dAng + 2 * math.pi end
    return { cx = ux, cy = uy, r = r, omega = dAng / dt, a0 = a2_ }
end

--- 获取圆弧参数（带缓存，同帧同 entry 不重复拟合）
local function getArcParams(entry, frame)
    -- 每帧清一次缓存（新帧 = 新历史数据，必须重新拟合）
    if arcCacheFrame ~= frame then
        arcCache = {}
        arcCacheFrame = frame
    end
    local key = tostring(entry)
    local cached = arcCache[key]
    if cached and cached.frame == frame then
        return cached.circle
    end
    -- 拟合
    local circle = nil
    -- 只用去重样本：重复样本（同一位置被记进相邻两帧）会让三点圆拟合退化，
    -- 环形旋转弹幕就因此退回直线外推（用户 2026-09-12 反馈“环转弹幕躲得差”）。
    local d = History.distinctSamples(entry, 3)
    if #d >= 3 and History.motionConsistent(entry) then
        -- 脏样本过滤（同一位置被记进相邻两帧会让拟合把轨迹掰向反方向，
        -- 见 entities/tracker.lua motionConsistent 注释）
        circle = fitCircle3(d[1], d[2], d[3])
        if circle and math.abs(circle.omega) < 0.02 then
            circle = nil -- 角速度太低视为直线
        end
    end
    arcCache[key] = { circle = circle, frame = frame }
    return circle
end

---------------------------------------------------------------
-- 点到线段距离平方（激光碰撞）
---------------------------------------------------------------
local function pointSegmentDistSq(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local lenSq = dx * dx + dy * dy
    if lenSq < 0.01 then
        local ex, ey = px - ax, py - ay
        return ex * ex + ey * ey
    end
    local apx, apy = px - ax, py - ay
    local t = (apx * dx + apy * dy) / lenSq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local cx, cy = ax + t * dx, ay + t * dy
    local ex, ey = px - cx, py - cy
    return ex * ex + ey * ey
end
-- exported for tests
FutureMotion._pointSegmentDistSq = pointSegmentDistSq

---------------------------------------------------------------
-- laserSegmentAt：t 帧后激光线段（复用 hazard_query 的逻辑）
-- 公开方法，供 hazard_query 和 future_motion 共用
---------------------------------------------------------------
function FutureMotion.laserSegmentAt(entry, t)
    local a = entry.pos + entry.vel * t
    local b
    if entry.endPos then
        b = entry.endPos + entry.vel * t
    elseif (entry.length or 0) > 0 then
        local ang = math.rad(entry.angle or 0)
        b = a + Vector(math.cos(ang) * entry.length, math.sin(ang) * entry.length)
    else
        b = entry.pos + entry.vel
    end
    local rot = (entry.rotSpd or 0) * t
    if rot ~= 0 then
        local rel = b - a
        local len = rel:Length()
        if len > 0.01 then
            local ang = atan2(rel.Y, rel.X) + math.rad(rot)
            b = a + Vector(math.cos(ang) * len, math.sin(ang) * len)
        end
    end
    return a, b
end

---------------------------------------------------------------
-- 追踪型弹幕：平均速度外推
---------------------------------------------------------------
local function trackingPos(entry, t)
    -- 趋势速度 = 最近两个「自报速度」的平均（自报 vel 可信；位置差分会被重复样本毁掉）
    local d = History.distinctSamples(entry, 2)
    if #d >= 2 and d[#d - 1].vel and d[#d].vel then
        local va, vb = d[#d - 1].vel, d[#d].vel
        local avgVelX, avgVelY = (va.X + vb.X) / 2, (va.Y + vb.Y) / 2
        return Vector(entry.pos.X + avgVelX * t, entry.pos.Y + avgVelY * t)
    end
    return entry.pos + entry.vel * t
end

---------------------------------------------------------------
-- 核心接口：t 帧后威胁的位置
-- 返回值:
--   kind=laser: segmentA, segmentB (两个 Vector)
--   其他: single Vector 或 nil (届时不存在)
---------------------------------------------------------------
function FutureMotion.pos(entry, t, frame)
    local kind = entry.kind or "projectile"
    local now = frame or entry.lastFrame or 0
    local start = entry.appearFrame or (entry.fuseFrames and ((entry.lastFrame or now)+entry.fuseFrames))
    if start and now+t < start then return nil end
    if entry.endFrame and now+t > entry.endFrame then return nil end

    -- 激光: 返回线段两端
    if kind == "laser" then
        return FutureMotion.laserSegmentAt(entry, t)
    end

    -- NPC 攻击前兆: appearFrame 之前不存在
    if kind == "npc_attack" then
        if entry.appearFrame and t < entry.appearFrame - (frame or 0) then
            return nil
        end
        -- 已出现或无 appearFrame → 圆碰撞外推
        return entry.pos + entry.vel * t
    end

    -- 跳跃型敌人（Trite=跳蛛 等）: 地面待跳 → 直线跳到“玩家当前所在”（跳距 clamp 到观测范围）
    -- → 落地后停在落点。模型依据：跳蛛瞄准起跳瞬间玩家所在、跳距随玩家距离变化，
    -- 节奏固定（entities/hop_tracker.lua 里按实测速度/位置标定）。
    if entry.hopOn then
        local inF = entry.hopIn or 0
        local sx = entry.pos.X + entry.vel.X * inF
        local sy = entry.pos.Y + entry.vel.Y * inF
        if t <= inF then
            return Vector(entry.pos.X + entry.vel.X * t, entry.pos.Y + entry.vel.Y * t)
        end
        local flight = entry.hopFlight or 12
        if flight < 1 then flight = 1 end
        local k = (t - inF) / flight
        if k > 1 then k = 1 end
        local lx = entry.hopLX or sx
        local ly = entry.hopLY or sy
        return Vector(sx + (lx - sx) * k, sy + (ly - sy) * k)
    end

    -- 弹幕类: 检查运动模式
    if kind == "projectile" then
        -- 圆弧弹幕
        local circle = getArcParams(entry, frame or 0)
        if circle then
            local ang = circle.a0 + circle.omega * t
            return Vector(
                circle.cx + circle.r * math.cos(ang),
                circle.cy + circle.r * math.sin(ang)
            )
        end
        -- 抛物线弹幕（爆炸弹丸等：2D阴影先减速再加速，恒定加速度）
        local Predict = require("threat/projectile_predict")
        if #History.distinctSamples(entry, 3) >= 3 then
            if Predict.isParabolic(entry) then
                return Predict.predictParabolicPos(entry, t)
            end
            -- 追踪型弹幕
            if Predict.isTracking(entry) then
                return trackingPos(entry, t)
            end
        end
    end

    -- 默认: 线性外推（敌人/effect/bomb/直线弹幕）
    return entry.pos + entry.vel * t
end

return FutureMotion
