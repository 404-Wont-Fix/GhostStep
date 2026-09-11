-- tests/smoke_main.lua
-- 冒烟测试主体：加载各模块并模拟数据流
-- 前置: tests/smoke.lua 已注入模拟 Isaac 环境

local results = {}
local failures = 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        results[#results + 1] = "PASS " .. name
    else
        failures = failures + 1
        results[#results + 1] = "FAIL " .. name .. " :: " .. tostring(err)
    end
end

-- ===== Vector 基础 =====
check("vector ops", function()
    local a = Vector(3, 4)
    assert(a:Length() == 5, "length")
    local n = a:Normalized()
    assert(math.abs(n.X - 0.6) < 0.001 and math.abs(n.Y - 0.8) < 0.001, "normalized")
    assert((Vector(1, 0) + Vector(0, 1)):Length() == math.sqrt(2), "add")
    assert((Vector(1, 2) * 3).X == 3, "mul")
end)

-- ===== math_ext =====
local mathext = require("utils/math_ext")
check("math_ext", function()
    assert(mathext.clamp(5, 0, 1) == 1)
    assert(mathext.clamp(-1, 0, 1) == 0)
    assert(mathext.remap(0.5, 0, 1, 0, 10) == 5)
    assert(mathext.smoothstep(0) == 0 and mathext.smoothstep(1) == 1)
    assert(mathext.dot(Vector(1, 0), Vector(0, 1)) == 0)
    assert(mathext.cross(Vector(1, 0), Vector(0, 1)) == 1)
end)

-- ===== tracker =====
local Tracker = require("entities/tracker")
check("tracker update+expiry+history", function()
    local t = Tracker.create()
    t:update({ { index = 1, pos = Vector(0, 0), vel = Vector(1, 0), speed = 1, radius = 5 } }, 100, "projectile")
    assert(t.count == 1, "count after add")
    t:update({ { index = 1, pos = Vector(10, 0), vel = Vector(1, 0), speed = 1, radius = 5 } }, 101, "projectile")
    local hist = t:getHistory(1)
    assert(hist and #hist == 2, "history len=" .. tostring(hist and #hist))
    assert(hist[1].pos.X == 0 and hist[2].pos.X == 10, "history order")
    -- 过期: 6帧未见
    t:update({}, 108, "projectile")
    assert(t.count == 0, "expired")
end)

check("tracker ring history >10", function()
    local t = Tracker.create()
    for f = 1, 15 do
        t:update({ { index = 1, pos = Vector(f, 0), vel = Vector(1, 0), speed = 1, radius = 5 } }, f, "projectile")
    end
    local hist = t:getHistory(1)
    assert(#hist == 10, "capped at 10, got " .. #hist)
    assert(hist[1].pos.X == 6, "oldest kept = frame6, got " .. hist[1].pos.X)
    assert(hist[10].pos.X == 15, "newest = frame15")
end)

-- ===== ring buffer =====
local RingBuffer = require("recording/ring_buffer")
check("ring buffer", function()
    local rb = RingBuffer.create(5)
    for i = 1, 8 do
        rb:push({ frame = i, threat = i / 10 })
    end
    assert(rb.count == 5, "count capped: " .. rb.count)
    local recent = rb:getRecent(3)
    assert(#recent == 3 and recent[1].frame == 6 and recent[3].frame == 8, "recent order")
    assert(rb:getFrame(7) ~= nil and rb:getFrame(2) == nil, "getFrame")
end)

-- ===== spatial =====
local Spatial = require("threat/spatial")
check("spatial buckets", function()
    local grid = Spatial.build({
        { pos = Vector(0, 0), vel = Vector(1, 0), speed = 1, radius = 5 },
        { pos = Vector(500, 500), vel = Vector(0, 1), speed = 1, radius = 5 },
    })
    local near = Spatial.queryNear(grid, Vector(10, 10))
    assert(#near == 1, "near count: " .. #near)
    local near2 = Spatial.queryNear(grid, Vector(490, 490))
    assert(#near2 == 1, "far bucket: " .. #near2)
end)

-- ===== predict =====
local Predict = require("threat/projectile_predict")
check("predict timeToHit", function()
    -- 弹幕从(100,0)向左飞行 v=(-5,0)，玩家在(50,0) r=10, 弹幕r=5 → combined=15
    -- 相对距离50, 相对速度+5/s朝玩家 → t = (50-15)/5 = 7
    local t = Predict.timeToHit(
        { pos = Vector(100, 0), vel = Vector(-5, 0), radius = 5 },
        Vector(50, 0), 10, 28)
    assert(math.abs(t - 7) < 0.01, "t=" .. tostring(t))
    -- 不相交
    local t2 = Predict.timeToHit(
        { pos = Vector(100, 100), vel = Vector(0, 5), radius = 5 },
        Vector(50, 0), 10, 28)
    assert(t2 == nil, "no hit")
end)

-- ===== threat level（模拟弹幕接近场景）=====
local mock = mock or {}
local ThreatLevel = require("threat/threat_level")
local HazardQuery = require("threat/hazard_query")
local Tracker2 = require("entities/tracker")
local Terrain = require("sensors/terrain")

check("threat level collision urgency", function()
    local tracker = Tracker2.create()
    -- 弹幕朝玩家飞来，4帧后命中 → urgency > 0.8
    tracker:update({ { index = 1, pos = Vector(100, 0), vel = Vector(-20, 0), speed = 20, radius = 8 } }, 0, "projectile")
    local hq = HazardQuery.create()
    local hazards = tracker:getActive(2, 0)
    hq:update(hazards)

    local config = require("config/defaults").get()
    local state = {
        player = { position = Vector(20, 0), velocity = Vector(0, 0), radius = 10 },
        threat = {},
    }
    local terrain = Terrain.create()
    local emptyTracker = Tracker2.create()
    ThreatLevel.evaluate(state, {
        config = config, tracker = tracker, trackerEnemies = emptyTracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = hq, terrain = terrain,
    }, 0)
    assert(state.threat.collisionUrgency >= 0.8,
        "urgency=" .. tostring(state.threat.collisionUrgency))
    assert(state.threat.level >= 0.8, "level=" .. tostring(state.threat.level))
end)

check("threat level gradient", function()
    local tracker = Tracker2.create()
    -- 弹幕集中在玩家右侧 → 梯度规避方向应朝左
    tracker:update({
        { index = 1, pos = Vector(60, 0), vel = Vector(0, 0), speed = 0, radius = 8 },
        { index = 2, pos = Vector(70, 10), vel = Vector(0, 0), speed = 0, radius = 8 },
        { index = 3, pos = Vector(65, -10), vel = Vector(0, 0), speed = 0, radius = 8 },
    }, 0, "projectile")
    local hq = HazardQuery.create()
    local config = require("config/defaults").get()
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 },
        threat = {},
    }
    ThreatLevel.evaluate(state, {
        config = config, tracker = tracker, trackerEnemies = Tracker2.create(),
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = hq,
        terrain = Terrain.create(),
    }, 0)
    local g = state.threat.gradientDir
    assert(g, "gradient should exist")
    assert(g.X < -0.5, "avoidance points left, got " .. tostring(g.X))
    assert(state.threat.densityScore > 0, "density > 0")
end)

-- ===== input synthesizer（核心公式）=====
local InputSynthesizer = require("control/input_synthesizer")
local config = require("config/defaults").get()

check("synth: no threat returns player input", function()
    local out, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(0, 1), 0.1, config, 999)
    assert(out.X == 1 and w == 0, "passthrough")
end)

check("synth: max threat respects 0.85 cap", function()
    local out, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(-1, 0), 1.0, config, 999)
    assert(w <= 0.85 + 0.0001, "w=" .. tostring(w))
    -- P=(1,0) w=0.85 D=(-1,0): combined = 0.15*(1,0) + 0.85*(-1,0) = (-0.7, 0) → 归一化(-1,0)
    assert(math.abs(out.X+0.7)<0.001, "preserve blend amplitude=" .. tostring(out.X))
end)

check("synth: wall escape clamps to wallEscapeWeight", function()
    local _, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(-1, 0), 1.0, config, 10)
    -- wallEscapeWeight=0.5（默认值）：靠墙时 AI 权重上限降到 0.5
    assert(w <= 0.5 + 0.0001, "w=" .. tostring(w))
end)

check("synth: embedded wall skips clamping (wallDist<0)", function()
    -- wallDist<0 = 玩家嵌入墙壁碰撞体 → 跳过墙角钳制，全力推离
    local _, w = InputSynthesizer.synthesize(Vector(0, 0), Vector(1, 0), 1.0, config, -5)
    assert(math.abs(w - 0.85) < 0.001, "embedded wall w=maxDodgeWeight, got " .. tostring(w))
end)

check("synth: standing player gets pure dodge", function()
    local out, w = InputSynthesizer.synthesize(Vector(0, 0), Vector(0, 1), 0.9, config, 999)
    assert(w > 0, "weight")
    assert(math.abs(out.Y-w)<0.001, "standing input preserves weight: " .. tostring(out.Y))
end)

check("synth: partial threat partial weight", function()
    local _, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(0, 1), 0.45, config, 999)
    assert(w > 0 and w < 0.85, "middle weight w=" .. tostring(w))
end)

-- ===== direction smooth =====
local DirectionSmooth = require("decision/direction_smooth")
check("direction smooth anti-flip", function()
    local decision = { dodgeDir = nil, holdFramesLeft = 0 }
    local d1 = DirectionSmooth.process(decision, config, Vector(1, 0), 1)
    assert(d1.X > 0.9, "first dir")
    -- 试图翻转到反方向 → 保持期内仍用旧方向
    local d2 = DirectionSmooth.process(decision, config, Vector(-1, 0), 2)
    assert(d2.X>0 and d2.X<0.9, "smooth transition starts immediately")
    for f=3,20 do DirectionSmooth.process(decision,config,Vector(-1,0),f) end
    assert(decision.dodgeDir.X< -0.99, "reversal must converge")
end)

-- ===== fallback =====
local Fallback = require("decision/fallback")
check("fallback avoids incoming projectile", function()
    local tracker = Tracker2.create()
    tracker:update({ { index = 1, pos = Vector(60, 0), vel = Vector(-10, 0), speed = 10, radius = 8 } }, 0, "projectile")
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10,
                   inputDir = Vector(1, 0) },
        decision = {},
        threat = {}, -- 新版 fallback 读取 threat.gradientDir
    }
    local terrain = Terrain.create()
    local dir = Fallback.compute(state, {
        config = config, tracker = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = nil, terrain = terrain,
    }, 0)
    assert(dir, "produced direction")
    -- 弹幕从右飞来：应该垂直逃离（向上或向下），而不是朝右迎弹
    assert(math.abs(dir.Y) > 0.7 or dir.X < 0, "escape dir: " .. tostring(dir.X) .. "," .. tostring(dir.Y))
end)

-- ===== early dodge =====
local EarlyDodge = require("decision/early_dodge")
check("early dodge perpendicular", function()
    local dir = EarlyDodge.compute(
        { pos = Vector(100, 5), vel = Vector(-20, 0), radius = 8 },
        Vector(0, 0))
    assert(dir, "computed")
    assert(math.abs(dir.X) < 0.1, "perpendicular X~0: " .. tostring(dir.X))
    assert(dir.Y > 0.9 or dir.Y < -0.9, "vertical: " .. tostring(dir.Y))
end)

-- ===== pipeline end-to-end =====
local Pipeline = require("decision/pipeline")
check("pipeline: safe stationary player does not drift from density", function()
    local tracker = Tracker2.create()
    tracker:update({
        { index = 1, pos = Vector(70, 0), vel = Vector(0, 0), speed = 0, radius = 8 },
        { index = 2, pos = Vector(75, 5), vel = Vector(0, 0), speed = 0, radius = 8 },
    }, 0, "projectile")
    local hq = HazardQuery.create()
    hq:update(tracker:getActive(2, 0))
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10,
                   inputDir = Vector(0, 0) },
        threat = { level = 0.3, gradientDir = Vector(-1, 0), projectileCount = 2,
                   hazardCount = 2, framesUntilHit = -1 },
        decision = { holdFramesLeft = 0 },
    }
    local layer, dir = Pipeline.run(state, {
        config = config, tracker = tracker, hazardQuery = hq, terrain = Terrain.create(),
    }, 0)
    assert(layer == "none" and dir==nil, "safe input passes through")
end)

check("pipeline: none layer when safe", function()
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 },
        threat = { level = 0.05, gradientDir = nil, projectileCount = 0, framesUntilHit = -1 },
        decision = { holdFramesLeft = 0 },
    }
    local layer = Pipeline.run(state, {
        config = config, tracker = Tracker2.create(),
        hazardQuery = HazardQuery.create(), terrain = Terrain.create(),
    }, 0)
    assert(layer == "none", "layer=" .. tostring(layer))
end)

-- ===== registry =====
local Registry = require("sensors/registry")
check("registry throttle combat/idle", function()
    local collected = {}
    local reg = Registry.create({
        config = { combatFrameInterval = 1, idleFrameInterval = 15 },
        isCombat = function() return false end,
    })
    reg:register({ name = "test", collect = function() collected[#collected + 1] = 1 end })
    reg:collectAll({}, 1) -- 首帧立即采集（设计如此）
    for f = 2, 15 do reg:collectAll({}, f) end
    assert(#collected == 1, "idle: only initial, got " .. #collected)
    reg:collectAll({}, 16) -- 距上次(帧1)已15帧
    assert(#collected == 2, "interval 15 collected, got " .. #collected)
    reg:force("test")
    reg:collectAll({}, 17)
    assert(#collected == 3, "force trigger works, got " .. #collected)
end)

-- ===== input reader =====
local InputReader = require("control/input_reader")
check("input reader axis values", function()
    assert(InputReader.actionValue(0, Vector(-0.5, 0)) == 0.5, "left half")
    assert(InputReader.actionValue(0, Vector(-0.001, 0)) == 0, "deadzone")
    assert(InputReader.actionValue(1, Vector(1, 0)) == 1, "right full")
    assert(InputReader.actionValue(2, Vector(0, -0.7)) == 0.7, "up")
end)

-- ===== projectile sensor 采集路径（GetRoomEntities 过滤 + 归属分类）=====
local ProjSensor = require("sensors/projectiles")
check("projectile sensor collect filters+classifies", function()
    local tracker2 = Tracker.create()
    SMOKE.entities = {
        { -- 敌方弹幕(NPC发射) → 采集
            Type = 1000, Index = 100, Position = Vector(50, 0),
            Velocity = Vector(-5, 0), Size = 8, SpawnerType = 33,
            IsDead = function() return false end },
        { -- 未知归属弹幕 → 默认敌方 → 采集
            Type = 1000, Index = 101, Position = Vector(60, 0),
            Velocity = Vector(-5, 0), Size = 8, SpawnerType = 0,
            IsDead = function() return false end },
        { -- 已死亡弹幕 → 跳过
            Type = 1000, Index = 102, Position = Vector(0, 0),
            Velocity = Vector(0, 0), Size = 8, SpawnerType = 0,
            IsDead = function() return true end },
        { -- 玩家发射 → 友方 → 跳过
            Type = 1000, Index = 103, Position = Vector(70, 0),
            Velocity = Vector(5, 0), Size = 8, SpawnerType = 9,
            IsDead = function() return false end },
        { -- 非弹幕实体 → 跳过
            Type = 33, Index = 104, Position = Vector(80, 0),
            Velocity = Vector(0, 0), Size = 10, SpawnerType = 0,
            IsDead = function() return false end },
    }
    ProjSensor.collect(nil, tracker2, 10, {
        hazardProjectiles = true, maxProjectiles = 300, ownershipCacheTtl = 180 })
    assert(tracker2.count == 2, "count=" .. tracker2.count)
    assert(tracker2.tracked[100], "npc-spawned tracked")
    assert(tracker2.tracked[101], "unknown default-hostile tracked")
    assert(not tracker2.tracked[102], "dead skipped")
    assert(not tracker2.tracked[103], "player-spawned skipped")
    assert(not tracker2.tracked[104], "non-projectile skipped")
    SMOKE.entities = {}
    ProjSensor.clearOwnership()
end)

-- ===== escape lock =====
local EscapeLock = require("decision/escape_lock")
check("escape lock holds direction", function()
    local el = EscapeLock.create()
    local dir = el:process(100, function() return Vector(1, 0) end)
    assert(dir and dir.X > 0.9, "initial dir")
    -- 锁定期内(初始+5帧=6次评估)即使 baseDirFn 想反转，仍保持原方向
    for f = 101, 105 do
        dir = el:process(f, function() return Vector(-1, 0) end)
        assert(dir.X > 0.9, "locked at frame " .. f .. ", got X=" .. tostring(dir.X))
    end
    -- 锁过期后重新评估 → 用新方向与记忆混合
    dir = el:process(106, function() return Vector(-1, 0) end)
    assert(dir.X < 0, "after lock expires, flips (with memory blend): X=" .. tostring(dir.X))
end)

check("escape lock memory blends nearby re-locks", function()
    local el = EscapeLock.create()
    el:process(100, function() return Vector(0, 1) end) -- 锁定向下
    for f = 101, 105 do el:process(f, function() return Vector(0, 1) end) end
    el:process(106, function() return Vector(1, 0) end) -- 重锁: 0.7*(0,1)+0.3*(1,0)后归一化
    local dir = el.lockedDir
    local len = math.sqrt(0.3 * 0.3 + 0.7 * 0.7)
    assert(math.abs(dir.X - 0.3 / len) < 0.01 and math.abs(dir.Y - 0.7 / len) < 0.01,
        "blend normalized (0.3,0.7)/" .. len .. ", got (" .. dir.X .. "," .. dir.Y .. ")")
end)

check("escape lock reset", function()
    local el = EscapeLock.create()
    el:process(100, function() return Vector(1, 0) end)
    el:reset()
    assert(el.framesLeft == 0 and el.lockedDir == nil and el.lastDir == nil)
    -- reset 后无记忆，立即接受新方向
    local dir = el:process(101, function() return Vector(-1, 0) end)
    assert(dir.X < -0.9, "fresh after reset")
end)

check("escape lock: embedded wall probes terrain for escape", function()
    local el = EscapeLock.create()
    -- 先锁定一个朝右方向（正常路径）
    el:process(100, function() return Vector(1, 0) end)
    assert(el.lockedDir and el.lockedDir.X > 0.9, "locked right")
    -- 创建 mock terrain: isWalkableAt 对左侧(540,210)返回true，其余返回false
    -- 这样探测8方向时只有朝左的方向可通行
    local mockTerrain = {
        valid = true,
        isWalkableAt = function(self, pos)
            -- 只有左侧30px处(540,210)可通行
            if pos.X < 550 and pos.Y > 190 and pos.Y < 230 then return true end
            return false
        end,
    }
    local ctx = { wallDist = -10, roomCenter = Vector(0, 0),
                  wallStuckThreshold = 60, terrain = mockTerrain }
    local dir = el:process(101, function() return Vector(1, 0) end, Vector(570, 210), ctx)
    assert(dir and dir.X < -0.5, "escape toward walkable direction, got X=" .. tostring(dir.X))
    assert(el.lockedDir == nil, "lock cleared after embedded wall override")
end)

check("escape lock: embedded wall with no walkable path returns nil", function()
    local el = EscapeLock.create()
    el:process(200, function() return Vector(1, 0) end)
    -- mock terrain: 所有方向都不通行
    local mockTerrain = {
        valid = true,
        isWalkableAt = function(self, pos) return false end,
    }
    local ctx = { wallDist = -10, roomCenter = Vector(0, 0),
                  wallStuckThreshold = 60, terrain = mockTerrain }
    local dir = el:process(201, function() return Vector(1, 0) end, Vector(570, 210), ctx)
    assert(dir == nil, "no walkable path -> nil, player controls")
end)

-- ===== 弧线弹幕预测（三点圆拟合）=====
local Predict2 = require("threat/projectile_predict")
check("arc prediction detects curved shot and hits", function()
    -- 构造圆弧运动历史: 圆心(0,0) 半径100, 每3帧转5度
    local history = {}
    local entry = {
        pos = nil, vel = nil, radius = 5,
        history = history, historyCount = 10,
    }
    for i = 1, 10 do
        local ang = (i - 1) * math.rad(5) * 3 -- 每3帧+15度? 简化: 每帧5度
        ang = (i - 1) * math.rad(5)
        history[i] = { pos = Vector(100 * math.cos(ang), 100 * math.sin(ang)), frame = i }
    end
    -- 最新点
    entry.pos = history[10].pos
    entry.vel = Vector(0, 0) -- 直线闭式解用不到（isCurved 先行）
    assert(Predict2.isCurved(entry), "curvature detected")
    -- 玩家站在弧线路径前方某点: 圆心(0,0) r=100, 角速度5度/帧
    -- 最新样本角度 = 9*5度=45度，未来 t 帧角度 = 45°+5°*t；取 95 度处 ≈ t=10
    local targetAng = math.rad(95)
    local pPos = Vector(100 * math.cos(targetAng), 100 * math.sin(targetAng))
    local t = Predict2.timeToHitArc(entry, pPos, Vector(0, 0), 8, 28)
    assert(t and t <= 12, "arc hit within horizon, t=" .. tostring(t))
end)

check("tracking projectile detected from velocity trend", function()
    -- 模拟追踪型弹幕：速度方向持续变化（每帧转向5度）
    local history = {}
    for i = 1, 6 do
        local ang = (i - 1) * math.rad(5)
        history[i] = {
            pos = Vector(i * 5, 0),
            vel = Vector(10 * math.cos(ang), 10 * math.sin(ang)),
            frame = i,
        }
    end
    local entry = {
        pos = history[6].pos, vel = history[6].vel, radius = 5,
        history = history, historyCount = 6,
    }
    assert(Predict2.isTracking(entry), "curved velocity detected as tracking")
    -- 直线弹幕不误判
    local straightHistory = {}
    for i = 1, 6 do
        straightHistory[i] = { pos = Vector(i * 10, 0), vel = Vector(10, 0), frame = i }
    end
    local straight = {
        pos = Vector(60, 0), vel = Vector(10, 0), radius = 5,
        history = straightHistory, historyCount = 6,
    }
    assert(not Predict2.isTracking(straight), "straight not tracking")
end)

check("arc prediction: straight shot not flagged curved", function()
    local history = {}
    for i = 1, 10 do
        history[i] = { pos = Vector(i * 10, 0), frame = i }
    end
    local entry = { pos = Vector(100, 0), vel = Vector(10, 0), radius = 5,
                    history = history, historyCount = 10 }
    assert(not Predict2.isCurved(entry), "straight = not curved")
    -- 直线弹幕走闭式解路径正常
    local t = Predict2.timeToHitMoving(entry, Vector(150, 0), Vector(0, 0), 8, 28)
    assert(t and t > 0, "linear solve still works, t=" .. tostring(t))
end)

-- ===== 抛物线弹幕预测（恒定加速度模型）=====
check("parabolic detection from constant acceleration", function()
    -- 模拟抛物线运动：水平速度恒定，垂直先减速再加速（重力投影）
    -- 加速度 = (0, 0.5) px/frame²（向下）
    local history = {}
    local ax, ay = 0, 0.5  -- 恒定加速度
    local vx0, vy0 = 8, -6  -- 初速度（向上抛）
    local px0, py0 = 100, 200
    for i = 1, 5 do
        local t = i - 1
        local px = px0 + vx0 * t + 0.5 * ax * t * t
        local py = py0 + vy0 * t + 0.5 * ay * t * t
        local vx = vx0 + ax * t
        local vy = vy0 + ay * t
        history[i] = { pos = Vector(px, py), vel = Vector(vx, vy), frame = i }
    end
    local entry = {
        pos = history[5].pos, vel = history[5].vel, radius = 5,
        history = history, historyCount = 5,
    }
    assert(Predict2.isParabolic(entry), "parabolic motion detected")
    -- 直线弹幕不误判
    local straightHistory = {}
    for i = 1, 5 do
        straightHistory[i] = { pos = Vector(i * 10, 0), vel = Vector(10, 0), frame = i }
    end
    local straight = {
        pos = Vector(50, 0), vel = Vector(10, 0), radius = 5,
        history = straightHistory, historyCount = 5,
    }
    assert(not Predict2.isParabolic(straight), "straight not parabolic")
end)

check("parabolic prediction extrapolates correctly", function()
    -- 构造已知抛物线，验证预测位置精度
    local history = {}
    local ax, ay = 0, 0.4
    local vx0, vy0 = 10, -8
    local px0, py0 = 50, 300
    for i = 1, 4 do
        local t = i - 1
        history[i] = {
            pos = Vector(px0 + vx0 * t + 0.5 * ax * t * t, py0 + vy0 * t + 0.5 * ay * t * t),
            vel = Vector(vx0 + ax * t, vy0 + ay * t),
            frame = i,
        }
    end
    local entry = {
        pos = history[4].pos, vel = history[4].vel, radius = 5,
        history = history, historyCount = 4,
    }
    -- 预测 t=5 后的位置（从帧3到帧8，dt=5）
    local predicted = Predict2.predictParabolicPos(entry, 5)
    -- 理论值: x = 50+10*7+0.5*0*49=120, y = 300-8*7+0.5*0.4*49=253.8
    -- 从帧4位置外推5帧: x = (50+10*3)+10*5 = 130, y = (300-8*3+0.5*0.4*9)+(-8+0.4*3)*5+0.5*0.4*25
    local expectedX = entry.pos.X + entry.vel.X * 5 + 0.5 * ax * 25
    local expectedY = entry.pos.Y + entry.vel.Y * 5 + 0.5 * ay * 25
    local errX = math.abs(predicted.X - expectedX)
    local errY = math.abs(predicted.Y - expectedY)
    assert(errX < 0.01, "parabolic X accurate, err=" .. errX)
    assert(errY < 0.01, "parabolic Y accurate, err=" .. errY)
end)

check("parabolic hit detection finds collision", function()
    -- 抛物线弹幕飞向玩家位置
    -- 弹幕从左侧低处向上抛，经过 (60,200) 附近后下落
    local history = {}
    local ax, ay = 0, 0.3
    local vx0, vy0 = 6, -2  -- 水平速度6，略微上抛
    local px0, py0 = 0, 200
    for i = 1, 4 do
        local t = i - 1
        history[i] = {
            pos = Vector(px0 + vx0 * t + 0.5 * ax * t * t, py0 + vy0 * t + 0.5 * ay * t * t),
            vel = Vector(vx0 + ax * t, vy0 + ay * t),
            frame = i,
        }
    end
    local entry = {
        pos = history[4].pos, vel = history[4].vel, radius = 8,
        history = history, historyCount = 4,
    }
    -- 玩家站在弹幕路径附近（弹幕在 t≈10 经过 x=60, y≈195）
    local playerPos = Vector(60, 200)
    local hitT = Predict2.timeToHitParabolic(entry, playerPos, Vector(0, 0), 10, 30)
    assert(hitT ~= nil, "parabolic hit detected, t=" .. tostring(hitT))
    assert(hitT >= 0 and hitT <= 30, "hit within horizon")
end)

-- ===== enemy sensor 采集（接触威胁）=====
local EnemySensor = require("sensors/enemies")
local function mockNpc(overrides)
    local e = {
        Type = 42, Index = 500, Position = Vector(40, 0), -- 42=普通敌型（勿用33=火堆，会走特判分支）
        Velocity = Vector(-3, 0), Size = 12, SpawnerType = 0,
        ToNPC = function() return {} end,
        IsDead = function() return false end,
        IsActiveEnemy = function() return true end,
        HasEntityFlags = function() return false end,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

check("enemy sensor collect filters contact threats", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpc({}),                                        -- 活敌 → 采集
        mockNpc({ Index = 501, IsDead = function() return true end }),        -- 死亡 → 跳过
        mockNpc({ Index = 502, HasEntityFlags = function() return true end }), -- 友方 → 跳过
        mockNpc({ Index = 503, IsActiveEnemy = function() return false end }), -- 非活跃 → 跳过
        mockNpc({ Index = 504, ToNPC = function() return nil end }),          -- 非NPC → 跳过
        { Type = 9, Index = 505, Position = Vector(0, 0), Velocity = Vector(0, 0),
          Size = 10, IsDead = function() return false end }, -- 玩家(无ToNPC) → 跳过
    }
    EnemySensor.collect(nil, trk, 10, { hazardContact = true })
    assert(trk.count == 1, "count=" .. trk.count)
    assert(trk.tracked[500], "living enemy tracked")
    SMOKE.entities = {}
end)

check("enemy sensor respects hazardContact=false", function()
    local trk = Tracker.create()
    trk:update({ { index = 999, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5 } }, 5, "enemy")
    EnemySensor.collect(nil, trk, 10, { hazardContact = false })
    assert(trk.count == 0, "cleared when disabled")
end)

-- ===== 混合威胁：敌人+弹幕进入同一威胁评估 =====
check("merged hazards: chasing enemy triggers collision urgency", function()
    local trkProj = Tracker2.create()
    local trkEnemy = Tracker2.create()
    -- 追踪型敌人从右侧逼近: 速度3px/f, 距玩家50px, combined=12+10=22 → t≈(50-22)/3≈9.3帧
    trkEnemy:update({ { index = 1, pos = Vector(50, 0), vel = Vector(-3, 0), speed = 3, radius = 12 } }, 0, "enemy")
    local hq = HazardQuery.create()
    local merged = trkProj:getActive(2, 0)
    for _, e in ipairs(trkEnemy:getActive(2, 0)) do merged[#merged + 1] = e end
    hq:update(merged)
    local cfg = require("config/defaults").get()
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 },
        threat = {},
    }
    ThreatLevel.evaluate(state, {
        config = cfg, tracker = trkProj, trackerEnemies = trkEnemy,
        getHazards = function() return merged end,
        hazardQuery = hq, terrain = Terrain.create(),
    }, 0)
    assert(state.threat.enemyCount == 1, "enemyCount=" .. tostring(state.threat.enemyCount))
    assert(state.threat.hazardCount == 1, "hazardCount=" .. tostring(state.threat.hazardCount))
    assert(state.threat.collisionUrgency > 0.3,
        "urgency=" .. tostring(state.threat.collisionUrgency))
    assert(state.threat.level > cfg.threatLow, "level=" .. tostring(state.threat.level))
    -- 梯度也应指向远离敌人的左侧
    local g = state.threat.gradientDir
    assert(g and g.X < -0.5, "avoid enemy leftward, got " .. (g and tostring(g.X) or "nil"))
end)

-- ===== session recorder（文件输出，io 不可用时优雅降级）=====
local SessionRecorder = require("recording/session_recorder")
check("session recorder degrades without io/debug path", function()
    local sr = SessionRecorder.create()
    -- lupa 环境有 io 但 chunk 名非 @路径 → scriptDirectory nil → available=false
    -- 无论降级与否，所有操作都应无错
    sr:startSession("ABCD 1234")
    sr:push({ frame = 1, threat = 0.5 }, function(t) return "{}" end)
    sr:event({ ev = "hit", dmg = 1 })
    sr:flush()
    sr:closeFile()
    local text = sr:statusText()
    assert(type(text) == "string" and #text > 0, "statusText ok")
    -- 不带 jsonEncoder 的 push（json 加载失败场景）也不崩
    sr:push({ frame = 2 }, nil)
end)

-- ===== snapshot 两阶段采集（时序修复回归: 决策字段必须是 finalize 时刻的值）=====
local Snapshot = require("recording/snapshot")
check("snapshot two-phase capture/finalize", function()
    local st = {
        currentRoomIndex = 5, inCombat = true,
        player = { position = Vector(10, 20), velocity = Vector(1, 2),
            inputDir = Vector(0, 0), hp = 6, canFly = false },
        threat = { level = 0, projectileCount = 0, enemyCount = 0, framesUntilHit = -1,
            collisionUrgency = 0, densityScore = 0 },
        decision = { layer = "none", dodgeDir = nil, holdFramesLeft = 0,
            usedBudgetMs = 0, degraded = false, lastTrace = nil },
        control = { weight = 0, direction = Vector(0, 0), wallDist = -1 },
        profiler = { lastFrameMs = 0 },
    }
    local snap = Snapshot.capture(st, 100, 3)
    assert(snap.px == 10 and snap.py == 20 and snap.hp == 6, "capture: 位置/血量")
    assert(snap.vx == 1 and snap.vy == 2 and snap.cmb == 1, "capture: 速度/战斗标志")
    assert(snap.canFly == false, "capture: canFly")
    assert(snap.threat == nil, "threat 必须由 finalize 填（管线后才有本帧值）")
    assert(snap.layer == nil, "决策字段必须由 finalize 填")
    -- 模拟 capture 与 finalize 之间运行的威胁评估+决策管线
    st.threat.level = 0.8
    st.threat.projectileCount = 3
    st.threat.framesUntilHit = 4
    st.threat.collisionUrgency = 0.9
    st.player.inputDir = Vector(1, 0)
    st.decision.layer = "escape_lock"
    st.decision.dodgeDir = Vector(1, 0)
    st.control.weight = 0.7
    st.control.direction = Vector(0.5, 0)
    st.control.wallDist = 42
    st.profiler.lastFrameMs = 0.55
    Snapshot.finalize(snap, st, 3, nil, {})
    assert(snap.threat == 0.8 and snap.proj == 3, "finalize: 本帧威胁值")
    assert(snap.layer == "escape_lock" and snap.weight == 0.7, "finalize: 本帧决策值")
    assert(snap.dx == 1 and snap.dy == 0, "finalize: 闪避方向")
    assert(snap.ix == 1 and snap.iy == 0, "finalize: 本帧输入")
    assert(snap.wallDist == 42 and snap.frameMs == 0.55, "finalize: 墙距/帧耗时")
    assert(snap.cx == 0.5 and snap.cy == 0, "finalize: 合成输出")
    assert(snap.degraded == 0 and snap.holdFrames == 0, "finalize: 降级/保持帧")
end)

check("snapshot detail4 hazard trace (排序/截断/相对坐标)", function()
    local st = {
        currentRoomIndex = 1, inCombat = true,
        player = { position = Vector(100, 100), velocity = Vector(0, 0),
            inputDir = Vector(0, 0), hp = 3, canFly = false },
        threat = { level = 0.5, projectileCount = 1, enemyCount = 1, framesUntilHit = -1 },
        decision = { layer = "fallback", dodgeDir = Vector(0, 1), holdFramesLeft = 2,
            lastTrace = { cand = { { a = 90, s = -1.5 } }, best = -1.5 } },
        control = { weight = 0.5, direction = Vector(0, 0.5), wallDist = 50 },
        profiler = { lastFrameMs = 0.4 },
    }
    -- 距离: 炸弹20 < 敌人30 < 弹幕50 < 远弹320(超出半径排除)；cap=2 只留前两个
    local hazards = {
        { pos = Vector(150, 100), vel = Vector(-5, 0), radius = 8, kind = "projectile" },
        { pos = Vector(120, 100), vel = Vector(0, 0), radius = 18, kind = "bomb",
          variant = 0, damage = 12 },
        { pos = Vector(100, 130), vel = Vector(1, -1), radius = 12, kind = "enemy" },
        { pos = Vector(420, 100), vel = Vector(0, 0), radius = 8, kind = "projectile" },
    }
    local snap = Snapshot.capture(st, 200, 4)
    Snapshot.finalize(snap, st, 4, hazards,
        { traceHazardMax = 2, traceHazardRadius = 300 })
    assert(snap.hz and #snap.hz == 2, "hz 数量(cap=2): " .. tostring(snap.hz and #snap.hz))
    assert(snap.hz[1][1] == "b", "最近的是炸弹")
    assert(snap.hz[1][3] == 20 and snap.hz[1][4] == 0, "炸弹相对坐标(20,0)")
    assert(snap.hz[1][7] == 18 and snap.hz[1][8] == 12, "炸弹半径/伤害透传")
    assert(snap.hz[2][1] == "e", "第二近的是敌人")
    assert(snap.hz[2][2] == -1, "无 variant 默认 -1")
    assert(snap.cand and snap.cand[1].a == 90, "候选评分复制")
    assert(snap.bestScore == -1.5, "最优分复制")
end)

check("fallback trace out (级别4候选评分留痕)", function()
    local tracker = Tracker2.create()
    tracker:update({ { index = 1, pos = Vector(60, 0), vel = Vector(-10, 0), speed = 10, radius = 8 } }, 0, "projectile")
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10,
                   inputDir = Vector(1, 0) },
        decision = {}, threat = {},
    }
    local trace = {}
    local dir = Fallback.compute(state, {
        config = config, tracker = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = nil, terrain = Terrain.create(),
    }, 0, trace)
    assert(dir, "produced direction")
    assert(trace.cand and #trace.cand == 6, "top6 候选: " .. tostring(trace.cand and #trace.cand))
    for i = 1, #trace.cand do
        local c = trace.cand[i]
        assert(type(c.a) == "number" and type(c.s) == "number", "候选字段 a/s")
    end
    assert(trace.cand[1].s <= trace.cand[6].s, "候选按分数升序")
    assert(type(trace.best) == "number", "最优分已填")
    -- 不传 traceOut（旧调用方式）依然正常
    local dir2 = Fallback.compute(state, {
        config = config, tracker = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = nil, terrain = Terrain.create(),
    }, 0)
    assert(dir2, "无 traceOut 兼容")
end)

check("ring buffer nested hz tables", function()
    local rb = RingBuffer.create(3)
    rb:push({ frame = 1, hz = { { "p", 9, 1, 2, -5, 0, 8, 1 } }, cand = { { a = 90, s = -1 } } })
    local recent = rb:getRecent(1)
    assert(recent[1].hz[1][1] == "p" and recent[1].hz[1][3] == 1, "嵌套 hz 表保留")
    assert(recent[1].cand[1].a == 90, "嵌套 cand 表保留")
end)

-- ===== laser/bomb/effect sensor 采集 + 碰撞分流 =====
local LaserSensor = require("sensors/lasers")
local BombSensor = require("sensors/bombs")
local EffectSensor = require("sensors/effects")
local HazardQuery = require("threat/hazard_query")

check("laser sensor filters hostile vs friendly", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        { Type = 7, Index = 800, Position = Vector(0, 0), Velocity = Vector(0, 0),
          Size = 8, SpawnerType = 0, IsDead = function() return false end },
        { Type = 7, Index = 801, Position = Vector(10, 0), Velocity = Vector(0, 0),
          Size = 8, SpawnerType = 9, IsDead = function() return false end }, -- 玩家发射
    }
    LaserSensor.collect(nil, trk, 10, { hazardLasers = true })
    assert(trk.count == 1, "hostile only: count=" .. trk.count)
    assert(trk.tracked[800], "hostile tracked")
    assert(not trk.tracked[801], "player-owned skipped")
    SMOKE.entities = {}
end)

check("bomb sensor keeps unknown fuse as explicitly unknown", function()
    local trk = Tracker.create()
    -- 玩家炸弹跳过
    SMOKE.entities = {
        { Type = 4, Index = 810, Position = Vector(50, 0), Velocity = Vector(0, 0),
          Size = 10, SpawnerType = 0, FrameCount = 150, -- 已到危险时间
          IsDead = function() return false end },
        { Type = 4, Index = 811, Position = Vector(60, 0), Velocity = Vector(0, 0),
          Size = 10, SpawnerType = 0, FrameCount = 50, -- 还早
          IsDead = function() return false end },
    }
    BombSensor.collect(nil, trk, 10, { hazardBombs = true })
    assert(trk.count == 2, "both bombs tracked; fuse availability explicit")
    assert(trk.tracked[810], "mature bomb tracked")
    assert(trk.tracked[811].timingKnown==false and trk.tracked[811].fuseFrames==nil, "FrameCount cannot establish fuse time")
    SMOKE.entities = {}
end)

check("effect sensor classifies creep vs visual-only", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        { Type = 1000, Index = 820, Position = Vector(40, 0), Velocity = Vector(0, 0),
          Size = 12, Variant = 22, IsDead = function() return false end }, -- CREEP_RED
        { Type = 1000, Index = 821, Position = Vector(50, 0), Velocity = Vector(0, 0),
          Size = 5, Variant = 61, IsDead = function() return false end },  -- SHOCKWAVE
        { Type = 1000, Index = 822, Position = Vector(60, 0), Velocity = Vector(0, 0),
          Size = 2, Variant = 11, IsDead = function() return false end },  -- BULLET_POOF (visual)
    }
    EffectSensor.collect(nil, trk, 10, { hazardCreep = true })
    assert(trk.count == 2, "creep+shockwave: count=" .. trk.count)
    assert(trk.tracked[820], "creep_red tracked")
    assert(trk.tracked[821], "shockwave tracked")
    assert(not trk.tracked[822], "bullet_poof filtered")
    SMOKE.entities = {}
end)

check("hazard_query routes laser by segment distance", function()
    -- 激光水平从左到右，玩家在激光上方近距离
    local hz = {
        { index = 1, pos = Vector(0, 10), endPos = Vector(100,10), vel = Vector(0, 0), speed = 0,
          radius = 5, kind = "laser" },
    }
    local hq = HazardQuery.create()
    hq:update(hz)
    -- 玩家在激光正上方距离5px（恰好重叠），静止
    local t, entry = hq:firstCollision(Vector(50, 5), Vector(0, 0), 3, 10)
    assert(t == 0, "laser hit at frame 0, got t=" .. tostring(t))
    -- 玩家远离激光下方
    local t2 = hq:firstCollision(Vector(50, 100), Vector(0, 0), 3, 10)
    assert(t2 == nil, "far from laser: no hit")
end)

-- ===== NPC attack sensor 检测 =====
local NpcAttackSensor = require("sensors/npc_attacks")

local function mockNpcAttack(overrides)
    local e = {
        Type = 33, Index = 900, Position = Vector(50, 0),
        Velocity = Vector(0, 0), Size = 12, SpawnerType = 0,
        ToNPC = function() return {} end,
        IsDead = function() return false end,
        IsActiveEnemy = function() return true end,
        HasEntityFlags = function() return false end,
        GetSprite = function() return { GetAnimation = function() return "idle" end } end,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

check("npc_attack sensor detects Mom's Hand jumpdown", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpcAttack({ Type = 213, -- MOMS_HAND
            GetSprite = function() return { GetAnimation = function() return "JumpDown" end } end }),
        mockNpcAttack({ Index = 901, Type = 213, -- same NPC but idle
            GetSprite = function() return { GetAnimation = function() return "idle" end } end }),
    }
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = true })
    assert(trk.count == 1, "jumpdown detected: count=" .. trk.count)
    -- 落点半径应>=60
    for _, entry in pairs(trk.tracked) do
        assert(entry.radius >= 60, "radius=" .. entry.radius)
    end
    SMOKE.entities = {}
end)

check("npc_attack sensor detects Horf attack windup", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpcAttack({ Type = 12, -- HORF
            GetSprite = function() return { GetAnimation = function() return "Attack" end } end }),
    }
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = true })
    assert(trk.count == 0, "missing target is unknown; do not invent an aiming direction")
    SMOKE.entities = {}
end)

check("npc_attack sensor detects laser windup (Vis/Brimstone)", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpcAttack({ Type = 246, -- VIS
            GetSprite = function() return { GetAnimation = function() return "Laser" end } end }),
        mockNpcAttack({ Index = 901, Type = 246, -- VIS death anim (excluded)
            GetSprite = function() return { GetAnimation = function() return "Death" end } end }),
    }
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = true })
    assert(trk.count == 0, "target unavailable; death excluded")
    SMOKE.entities = {}
end)

check("npc_attack sensor disabled by config", function()
    local trk = Tracker.create()
    trk:update({ { index = 999, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5 } }, 5, "npc_attack")
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = false })
    assert(trk.count == 0, "cleared when disabled")
end)

check("npc_attack windup countdown entry has fuseFrames and appearFrame", function()
    local trk = Tracker.create()
    -- Mom's Hand (213) "JumpDown": windupFrames=11, GetFrame=3 → fuseFrames=8
    SMOKE.entities = {
        mockNpcAttack({ Type = 213,
            GetSprite = function() return {
                GetAnimation = function() return "JumpDown" end,
                GetFrame = function() return 3 end,
            } end }),
    }
    NpcAttackSensor.collect(nil, trk, 20, { hazardNpcAttacks = true })
    assert(trk.count == 1, "entry tracked")
    local entry = trk.tracked[next(trk.tracked)]
    assert(entry.kind == "npc_attack", "kind=" .. tostring(entry.kind))
    assert(entry.fuseFrames == 8, "fuseFrames=11-3=8, got " .. tostring(entry.fuseFrames))
    assert(entry.appearFrame == 28, "appearFrame=20+8=28, got " .. tostring(entry.appearFrame))
    assert(entry.radius == 62, "Mom's Hand radius=62, got " .. tostring(entry.radius))
    SMOKE.entities = {}
end)

check("npc_attack laser windup generates laser kind with endPos", function()
    local trk = Tracker.create()
    -- Vis (246) "Laser": category=laser, kind=laser, endPos = pos + dir*480
    -- Mock player at (200,0), Vis at (50,0) → direction = (150,0).Normalized() = (1,0)
    -- endPos should be pos + (1,0)*480 = (530,0)
    SMOKE.entities = {
        mockNpcAttack({ Type = 246, Position = Vector(50, 0),
            GetSprite = function() return {
                GetAnimation = function() return "Laser" end,
                GetFrame = function() return 0 end,
            } end }),
    }
    -- Override Isaac.GetPlayer for this test to return known position
    local origGetPlayer = Isaac.GetPlayer
    Isaac.GetPlayer = function() return { Position = Vector(200, 0) } end
    NpcAttackSensor.collect(nil, trk, 5, { hazardNpcAttacks = true })
    Isaac.GetPlayer = origGetPlayer -- restore
    assert(trk.count == 1, "laser entry tracked")
    local entry = trk.tracked[next(trk.tracked)]
    assert(entry.kind == "laser", "kind=laser, got " .. tostring(entry.kind))
    assert(entry.radius == 28, "laser radius=28, got " .. tostring(entry.radius))
    -- endPos should be along direction from (50,0) toward (200,0), length480
    -- direction = (1,0), endPos = (50,0) + (1,0)*480 = (530,0)
    -- vel = direction * pathLength = (480,0) (vel carries endPos offset)
    assert(entry.vel:Length()==0 and entry.endPos.X==530, "beam length must not become translation speed")
    -- fuseFrames: windup=22, GetFrame=0 → fuse=22
    assert(entry.fuseFrames == 22, "fuseFrames=22-0=22, got " .. tostring(entry.fuseFrames))
    SMOKE.entities = {}
end)

-- ===== 第一批改进回归：伤害加权 / 墙壁截断 / 旋转激光 / 引信紧迫度 =====

-- 手工构造带墙地形: 5x1 格（每格40px），x=2 格（80-120px）为墙
local function walledTerrain()
    local ter = Terrain.create()
    ter.valid = true
    ter.sizeX = 5
    ter.sizeY = 1
    ter.topLeft = Vector(0, 0)
    ter.grid = {}
    for x = 0, 4 do
        ter.grid[x + 1] = { walkable = (x ~= 2), danger = nil }
    end
    return ter
end

check("damage weighting: high damage raises urgency (3.6)", function()
    local function urgencyFor(dmg)
        local tracker = Tracker2.create()
        -- 弹幕从右向左 3.5 帧后命中玩家
        tracker:update({ { index = 1, pos = Vector(90, 0), vel = Vector(-20, 0), speed = 20, radius = 8,
                           damage = dmg } }, 0, "projectile")
        local hq = HazardQuery.create()
        hq:update(tracker:getActive(2, 0))
        local cfg = require("config/defaults").get()
        local state = { player = { position = Vector(20, 0), velocity = Vector(0, 0), radius = 10 }, threat = {} }
        ThreatLevel.evaluate(state, {
            config = cfg, tracker = tracker, trackerEnemies = Tracker2.create(),
            getHazards = function() return tracker:getActive(2, 0) end,
            hazardQuery = hq, terrain = Terrain.create(),
        }, 0)
        return state.threat.collisionUrgency, state.threat.hitDamage
    end
    local u1, hd1 = urgencyFor(1)
    local u3, hd3 = urgencyFor(3)
    assert(u1 >= 0.8, "base urgency=" .. tostring(u1))
    assert(u3 > u1 + 0.05, "damage weighting: u3=" .. tostring(u3) .. " u1=" .. tostring(u1))
    assert(hd3 == 3 and hd1 == 1, "hitEntry damage passed through")
end)

check("wall truncation: projectile behind wall is not a threat (3.5)", function()
    local hz = { { index = 1, kind="projectile", blocksOnGrid=true, pos = Vector(0, 0), vel = Vector(3, 0), speed = 3, radius = 5 } }
    local hq = HazardQuery.create()
    hq:update(hz)
    local ter = walledTerrain()
    -- 玩家在墙后 x=130（墙格 80-120px）：命中路径穿墙 → 截断为 nil
    local tWall = hq:firstCollision(Vector(130, 0), Vector(0, 0), 5, 50, ter)
    assert(tWall == nil, "wall should truncate, got t=" .. tostring(tWall))
    -- 无墙地形（invalid）同几何 → 正常解出
    local tOpen = hq:firstCollision(Vector(130, 0), Vector(0, 0), 5, 50, Terrain.create())
    assert(tOpen ~= nil and tOpen > 0, "no wall: should hit, got " .. tostring(tOpen))
end)

check("rotating laser: sweep predicts future hit", function()
    -- 激光起点(0,0)，终点(100,0)，顺时针旋转2度/帧；玩家在(70,20)静止
    -- 激光扫过玩家方位角 atan2(20,70)≈15.9° → 约8帧后扫到
    local hz = { { index = 1, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5,
                   kind = "laser", endPos = Vector(100, 0), angle = 0, rotSpd = 2, length = 100 } }
    local hq = HazardQuery.create()
    hq:update(hz)
    local t = hq:firstCollision(Vector(70, 20), Vector(0, 0), 3, 28)
    assert(t ~= nil and t <= 12, "sweep should hit within 12 frames, got " .. tostring(t))
    -- 不旋转的激光永远指向 +x，玩家在上方 20px 外 → 无命中
    local hz2 = { { index = 1, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5,
                    kind = "laser", endPos = Vector(100, 0), angle = 0, rotSpd = 0, length = 100 } }
    local hq2 = HazardQuery.create()
    hq2:update(hz2)
    local t2 = hq2:firstCollision(Vector(70, 20), Vector(0, 0), 3, 28)
    assert(t2 == nil, "static laser pointing away should not hit")
end)

check("bomb fuse urgency: imminent explosion dominates (batch1)", function()
    -- 炸弹距玩家80px、以2px/帧逼近（约15帧后进入爆炸半径，基础 urgency≈0.37），
    -- 但引信只剩 5 帧 → fuse urgency≈0.93 应占主导
    local tracker = Tracker2.create()
    tracker:update({ { index = 1, pos = Vector(80, 0), vel = Vector(-2, 0), speed = 2, radius = 40,
                       kind = "bomb", damage = 1, fuseFrames = 5 } }, 0, "enemy")
    local hq = HazardQuery.create()
    hq:update(tracker:getActive(2, 0))
    local cfg = require("config/defaults").get()
    local state = { player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 }, threat = {} }
    ThreatLevel.evaluate(state, {
        config = cfg, tracker = Tracker2.create(), trackerEnemies = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = hq, terrain = Terrain.create(),
    }, 0)
    assert(state.threat.collisionUrgency >= 0.9,
        "fuse urgency=" .. tostring(state.threat.collisionUrgency))
    assert(state.threat.hitKind == "bomb", "hitKind=" .. tostring(state.threat.hitKind))
end)

check("npc_attack fuse urgency: imminent stomp dominates (M4 generalization)", function()
    -- NPC attack 前兆: fuseFrames=5, radius=64, 静止, 距玩家60px
    -- 合并 radius=64+10=74, dist=60 < 74 → 重叠 → t=0 → collisionUrgency≈0.98
    -- fuseUrgency: remap(5, 0, 30, 1.0, 0.6) ≈ 0.916 → max(0.98, 0.916) ≈ 0.98
    -- 核心验证: npc_attack kind 的 fuseFrames 也走引信紧迫度逻辑（旧版只走 bomb）
    local tracker = Tracker2.create()
    tracker:update({ { index = 1, pos = Vector(60, 0), vel = Vector(0, 0), speed = 0, radius = 64,
                       kind = "npc_attack", fuseFrames = 5 } }, 0, "enemy")
    local hq = HazardQuery.create()
    hq:update(tracker:getActive(2, 0))
    local cfg = require("config/defaults").get()
    local state = { player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 }, threat = {} }
    ThreatLevel.evaluate(state, {
        config = cfg, tracker = Tracker2.create(), trackerEnemies = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = hq, terrain = Terrain.create(),
    }, 0)
    assert(state.threat.collisionUrgency >= 0.9,
        "npc_attack fuse urgency=" .. tostring(state.threat.collisionUrgency))
    assert(state.threat.hitKind == "npc_attack", "hitKind=" .. tostring(state.threat.hitKind))
end)

-- ===== 实测分析修复回归：effect 伤害兜底 + 被围钳制放宽 =====

check("effect sensor: unclassified variant with CollisionDamage captured", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        -- variant 1 (未分类，如爆炸特效) 但有伤害 → 必须采集（"Killed by (10.1)" 兜底）
        { Type = 1000, Index = 830, Position = Vector(70, 0), Velocity = Vector(0, 0),
          Size = 10, Variant = 1, CollisionDamage = 3, IsDead = function() return false end },
        -- variant 99 无伤害无分类 → 忽略
        { Type = 1000, Index = 831, Position = Vector(80, 0), Velocity = Vector(0, 0),
          Size = 10, Variant = 99, IsDead = function() return false end },
    }
    EffectSensor.collect(nil, trk, 10, { hazardCreep = true })
    assert(trk.count == 1, "damage fallback: count=" .. trk.count)
    assert(trk.tracked[830], "damaging effect tracked")
    assert(not trk.tracked[831], "harmless unknown variant skipped")
    assert(trk.tracked[830].damage == 3, "damage field carried")
    SMOKE.entities = {}
end)

check("synth: wall cap relaxed when in danger zone", function()
    local cfg = require("config/defaults").get()
    -- 靠墙 + 高威胁：正常钳到 wallEscapeWeight=0.5
    local _, w1 = InputSynthesizer.synthesize(Vector(0, 0), Vector(1, 0), 1.0, cfg, 10)
    assert(math.abs(w1 - 0.5) < 0.001, "normal wall cap=0.5, got " .. tostring(w1))
    -- 靠墙 + 高威胁 + 被围（hit=0）：放宽到 min(0.85, 0.5*2)=0.85（逃命优先）
    local _, w2 = InputSynthesizer.synthesize(Vector(0, 0), Vector(1, 0), 1.0, cfg, 10, true)
    assert(math.abs(w2 - 0.85) < 0.001, "danger zone wall cap=0.85, got " .. tostring(w2))
end)

check("enemy sensor: fireplace uses its own collision size (no inflation)", function()
    local trk = Tracker.create()
    local function makeSprite(anim)
        return { GetAnimation = function() return anim end }
    end
    SMOKE.entities = {
        -- 火堆: 判定圈 = 实体自身 Size（与其他传感器一致），不再 ×2.5/×2.0/×1.6。
        -- 回归背景: 旧实现 max(Size*1.6, 30) 被 MIN=30 钳死，实际半径恒为 30，
        -- 禁入圈 = 30+10+1.5 = 41.5px > 40px 格距 → 连相邻格一起封死。
        { Type = 33, Index = 840, Position = Vector(100, 0), Velocity = Vector(0, 0),
          Size = 16.25, IsDead = function() return false end,
          GetSprite = function() return makeSprite("Flickering") end },
        -- Size 读不到时的兜底下限（不允许半径 0 → 完全不避）
        { Type = 33, Index = 845, Position = Vector(150, 0), Velocity = Vector(0, 0),
          Size = 0, IsDead = function() return false end,
          GetSprite = function() return makeSprite("Flickering") end },
        -- 灰烬火堆（IsDead=true）排除
        { Type = 33, Index = 841, Position = Vector(110, 0), Velocity = Vector(0, 0),
          Size = 11, IsDead = function() return true end,
          GetSprite = function() return makeSprite("Flickering") end },
        -- 熄灭火堆（NoFire 动画，火焰已灭但实体仍在）排除
        { Type = 33, Index = 842, Position = Vector(120, 0), Velocity = Vector(0, 0),
          Size = 11, IsDead = function() return false end,
          GetSprite = function() return makeSprite("NoFire") end },
        -- 熄灭火堆变体（NoFire2）排除
        { Type = 33, Index = 843, Position = Vector(130, 0), Velocity = Vector(0, 0),
          Size = 11, IsDead = function() return false end,
          GetSprite = function() return makeSprite("NoFire2") end },
        -- 销毁中火堆（Dissapear 动画）排除
        { Type = 33, Index = 844, Position = Vector(140, 0), Velocity = Vector(0, 0),
          Size = 11, IsDead = function() return false end,
          GetSprite = function() return makeSprite("Dissapear") end },
    }
    EnemySensor.collect(nil, trk, 10, { hazardContact = true })
    assert(trk.count == 2, "fireplace tracked: count=" .. trk.count)
    local fp = trk.tracked[840]
    assert(fp.radius == 16.25, "fireplace radius must equal entity Size, got " .. tostring(fp.radius))
    local fpMin = trk.tracked[845]
    assert(fpMin.radius == 12, "radius floor for missing Size, got " .. tostring(fpMin.radius))
    assert(not trk.tracked[841], "dead fireplace excluded")
    assert(not trk.tracked[842], "extinguished fireplace (NoFire) excluded")
    assert(not trk.tracked[843], "extinguished fireplace (NoFire2) excluded")
    assert(not trk.tracked[844], "destroying fireplace (Dissapear) excluded")
    SMOKE.entities = {}
end)

-- ===== Tier 1: future_motion 外推器 =====
local FutureMotion = require("threat/future_motion")

check("future_motion: arc projectile extrapolates on circle", function()
    -- 构造圆弧运动历史: 圆心(0,0) 半径100, 每帧转5度
    local history = {}
    for i = 1, 10 do
        local ang = (i - 1) * math.rad(5)
        history[i] = { pos = Vector(100 * math.cos(ang), 100 * math.sin(ang)), frame = i }
    end
    local entry = {
        pos = history[10].pos, vel = Vector(0, 0), radius = 5,
        kind = "projectile",
        history = history, historyCount = 10,
    }
    -- t=10 帧后: 最新帧角度=45°，+50°=95°
    local fp = FutureMotion.pos(entry, 10, 10)
    assert(fp, "should produce position")
    local expectedAng = math.rad(95)
    local expectedX = 100 * math.cos(expectedAng)
    local expectedY = 100 * math.sin(expectedAng)
    assert(math.abs(fp.X - expectedX) < 5, "arc X off: " .. tostring(fp.X) .. " vs " .. expectedX)
    assert(math.abs(fp.Y - expectedY) < 5, "arc Y off: " .. tostring(fp.Y) .. " vs " .. expectedY)
    -- 清缓存
    FutureMotion.clearCache()
end)

check("future_motion: tracking uses trend velocity", function()
    -- 追踪型弹幕: 速度方向持续变化
    local history = {}
    for i = 1, 6 do
        local ang = (i - 1) * math.rad(5)
        history[i] = {
            pos = Vector(i * 5, 0),
            vel = Vector(10 * math.cos(ang), 10 * math.sin(ang)),
            frame = i,
        }
    end
    local entry = {
        pos = history[6].pos, vel = history[6].vel, radius = 5,
        kind = "projectile",
        history = history, historyCount = 6,
    }
    local fp = FutureMotion.pos(entry, 5, 6)
    assert(fp, "tracking should produce position")
    -- 平均速度 ≈ (v5+v6)/2 → 位置应偏移 5*avgVel
    local avgX = (history[5].vel.X + history[6].vel.X) / 2
    local avgY = (history[5].vel.Y + history[6].vel.Y) / 2
    local expectedX = entry.pos.X + avgX * 5
    local expectedY = entry.pos.Y + avgY * 5
    assert(math.abs(fp.X - expectedX) < 1, "tracking X: " .. tostring(fp.X))
    assert(math.abs(fp.Y - expectedY) < 1, "tracking Y: " .. tostring(fp.Y))
    FutureMotion.clearCache()
end)

check("future_motion: npc_attack nonexistent before appearFrame", function()
    local entry = {
        pos = Vector(100, 100), vel = Vector(0, 0), radius = 60,
        kind = "npc_attack",
        appearFrame = 30, -- 30帧后才出现
    }
    -- t=5（距 frame=10 还有 15 帧才到 appearFrame=30）→ 应返回 nil
    local fp = FutureMotion.pos(entry, 5, 10)
    assert(fp == nil, "before appearFrame should be nil, got " .. tostring(fp))
    -- t=25（frame=10+25=35 >= appearFrame=30）→ 应返回位置
    local fp2 = FutureMotion.pos(entry, 25, 10)
    assert(fp2 ~= nil, "after appearFrame should have position")
    assert(fp2.X == 100 and fp2.Y == 100, "stationary npc_attack stays at pos")
end)

check("trajectory: converging candidate scores better", function()
    -- 构造"向右走 t=8 撞弹幕，向左走安全且 t=24 收敛"场景:
    -- 弹幕从正右方 (200,0) 静止不动；玩家朝右走 t=8 到达 (40,0)
    -- → dist = |200-40| - 10 - 8 = 142 (大距离,无碰撞) → 不够近
    -- 改: 弹幕从右方 (60,0) 静止, 玩家朝右 8*5=40 → dist = |60-40|-18 = 2 < 40 → 罚分!
    -- 朝左: t=8 到 (-40,0) → dist = |60-(-40)|-18 = 82 > 60 → 收敛奖励
    local tracker = Tracker2.create()
    tracker:update({ {
        index = 1, pos = Vector(60, 0), vel = Vector(0, 0),
        speed = 0, radius = 8,
    } }, 0, "projectile")
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10,
                   inputDir = Vector(0, 0) },
        decision = {}, threat = {},
    }
    local terrain = Terrain.create()
    local cfg = require("config/defaults").get()
    local dir = Fallback.compute(state, {
        config = cfg, tracker = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        terrain = terrain,
    }, 0)
    assert(dir, "produced direction")
    -- 威胁在右侧(60,0)，向右走会越走越近（t=8 dist=2, 罚分大），
    -- 向左走远离+t=24收敛奖励 → 应偏向左侧
    assert(dir.X < 0, "should prefer left (away from stationary threat), got X=" .. tostring(dir.X))
end)

check("trajectory: near-term outweighs far-term", function()
    -- 场景: 两个威胁
    -- 威胁A: 距玩家60px，静止，t=4 时仍近 → 近期威胁
    -- 威胁B: 距玩家300px，快速接近，t=24 时才近 → 远期威胁
    local tracker = Tracker2.create()
    tracker:update({
        { index = 1, pos = Vector(60, 0), vel = Vector(0, 0), speed = 0, radius = 8 },  -- 近
        { index = 2, pos = Vector(400, 0), vel = Vector(-15, 0), speed = 15, radius = 8 }, -- 远但快速接近
    }, 0, "projectile")
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10,
                   inputDir = Vector(0, 0) },
        decision = {}, threat = {},
    }
    local terrain = Terrain.create()
    local cfg = require("config/defaults").get()
    local dir = Fallback.compute(state, {
        config = cfg, tracker = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        terrain = terrain,
    }, 0)
    assert(dir, "produced direction")
    -- 近期威胁在右侧(60,0) → 应偏向左侧或上下逃避
    assert(dir.X < 0 or math.abs(dir.Y) > 0.5,
        "should avoid near-term threat, got (" .. tostring(dir.X) .. "," .. tostring(dir.Y) .. ")")
end)

-- ===== 输出结果 =====
print("========== SMOKE RESULTS ==========")
for i = 1, #results do
    print(results[i])
end
print(string.format("========== %d pass, %d fail ==========", #results - failures, failures))
if failures > 0 then
    error("SMOKE TEST FAILED")
end
