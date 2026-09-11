-- tools/repro_fixes.lua
-- 离线复现 2026-09-11 用户反馈的 4 个问题（不改任何 mod 文件）。
-- 由 tools/repro_fixes.py 加载（先跑 tests/smoke.lua 注入 Isaac mock）。
--
-- 场景:
--   F1 飞行角色站在/贴着石块 —— 期望完全不接管（旧行为: 判"在墙里"并反向推开）
--   F2 地面角色站在石块上 —— 期望仍会脱出（回归保护）
--   F3 火堆正撞（闭环模拟）—— 期望不碰到火堆，且不做 45° 擦边
--   F4 弹幕斜向接近（闭环模拟）—— 观察选中方向与是否真的躲开

-- 用真机枚举值覆盖 smoke mock
GridCollisionClass.COLLISION_NONE = 0
GridCollisionClass.COLLISION_PIT = 1
GridCollisionClass.COLLISION_OBJECT = 2
GridCollisionClass.COLLISION_SOLID = 3
GridCollisionClass.COLLISION_WALL = 4
GridCollisionClass.COLLISION_WALL_EXCEPT_PLAYER = 5
GridEntityType.GRID_SPIKES = 8
GridEntityType.GRID_SPIKES_ONOFF = 9
GridEntityType.GRID_TNT = 12
GridEntityType.GRID_DOOR = 16
GridEntityType.GRID_ROCK_SPIKED = 25
GridEntityType.GRID_PILLAR = 24

local Defaults = require('config/defaults')
local Runtime = require('config/runtime')
local Terrain = require('sensors/terrain')
local Planner = require('decision/predictive')
local ReadI = require('control/input_reader')
local Motion = require('control/motion_model')

local CELL, LEFT, TOP = 40, 20, 100
local LEGEND = {
    ['#'] = { GridCollisionClass.COLLISION_WALL, 0 },
    ['.'] = { GridCollisionClass.COLLISION_NONE, 0 },
    ['R'] = { GridCollisionClass.COLLISION_SOLID, 0 },
    ['P'] = { GridCollisionClass.COLLISION_PIT, 0 },
    ['O'] = { GridCollisionClass.COLLISION_OBJECT, 0 },
    ['D'] = { GridCollisionClass.COLLISION_WALL_EXCEPT_PLAYER, 0 },
    ['^'] = { GridCollisionClass.COLLISION_NONE, GridEntityType.GRID_SPIKES },
}

--- 15x9 标准房间：外圈墙，内部自由。map 为 9 行字符串
local function makeRoom(map, strict)
    local cells = {}
    local h = #map
    local w = #map[1]
    for y = 1, h do
        for x = 1, w do
            local ch = map[y]:sub(x, x)
            local spec = LEGEND[ch] or LEGEND['.']
            cells[(y - 1) * w + x] = { coll = spec[1], typ = spec[2] }
        end
    end
    return {
        _cells = cells,
        GetGridWidth = function() return w end,
        GetGridSize = function() return w * h end,
        GetGridPosition = function(_, i)
            return Vector(LEFT + 20 + (i % w) * CELL, TOP + 20 + math.floor(i / w) * CELL)
        end,
        GetGridEntity = function(_, i)
            local c = cells[i + 1]
            -- 真机: 空格返回 nil（不是"GetType()==0 的实体"）
            if not c or (c.coll == GridCollisionClass.COLLISION_NONE and c.typ == 0) then return nil end
            return { CollisionClass = c.coll, State = 0, VarData = 0,
                GetType = function() return c.typ end }
        end,
        GetGridCollision = function(_, i)
            local c = cells[i + 1]
            return c and c.coll or GridCollisionClass.COLLISION_WALL
        end,
        -- 真机标准可走区域: x∈[60,580] y∈[140,420]
        -- strict=true 时按"足迹（r=10）必须完全落在可走区内"解释 margin
        -- （回放 220104 的贴墙假触发里有 105/327 段只能由这一项解释）
        IsPositionInRoom = function(_, p)
            if strict then
                return p.X >= 70 and p.X <= 570 and p.Y >= 150 and p.Y <= 410
            end
            return p.X >= 60 and p.X <= 580 and p.Y >= 140 and p.Y <= 420
        end,
        GetType = function() return 1 end,
    }
end

local FIRE_R = 16.25
local PLAYER_R = 10

local function fireAt(x, y)
    return { id = 'enemy:9:777', index = 9, seed = 777, kind = 'enemy', entityType = 33,
        pos = Vector(x, y), vel = Vector(0, 0), speed = 0, radius = FIRE_R, damage = 1,
        box = true, confidence = 1 }
end
local function tearAt(x, y, vx, vy, id)
    return { id = id or 'projectile:1:1', index = 1, seed = 1, kind = 'projectile',
        pos = Vector(x, y), vel = Vector(vx, vy), speed = math.sqrt(vx * vx + vy * vy),
        radius = 5, damage = 1, confidence = 1 }
end

local function newState(cfg, x, y, vx, vy, ix, iy, fly)
    local st = Runtime.create(cfg)
    st.player.valid = true
    st.player.moveSpeed = 1
    st.player.radius = PLAYER_R
    st.player.canFly = fly and true or false
    st.player.position = Vector(x, y)
    st.player.velocity = Vector(vx, vy)
    st.player.inputDir = Vector(ix, iy)
    return st
end

local planErrors = 0
local function plan(st, terrain, hz, frame)
    SMOKE.frameCount = 0 -- mock 的 Isaac.GetTime 按帧号走；避免预算判定被模拟帧号干扰
    local ok, cmd = pcall(Planner.run, st, { config = st.config, terrain = terrain,
        getHazards = function() return hz end }, frame or 18610)
    if not ok then planErrors = planErrors + 1; return nil end
    return cmd
end

--- 复刻 main.lua + input_writer 的实际输出：out=(1-w)*玩家 + w*AI（限幅 1）
local function blend(cfg, playerDir, cmd)
    if not cmd then return playerDir end
    local w = cfg.maxDodgeWeight or 0.85
    local mixed = playerDir * (1 - w) + cmd * w
    if mixed:Length() > 1 then mixed = mixed:Normalized() end
    return mixed
end

--- 圆-方接触：玩家中心到火堆 AABB 的距离 ≤ 玩家半径
local function boxContact(px, py, cx, cy, half, r)
    local dx = math.max(math.abs(px - cx) - half, 0)
    local dy = math.max(math.abs(py - cy) - half, 0)
    return math.sqrt(dx * dx + dy * dy) <= r
end

local function dirName(u)
    if not u or u:Length() < 0.05 then return '零(刹车)' end
    local a = math.atan2(u.Y, u.X) * 180 / math.pi
    local names = { '右', '右下', '下', '左下', '左', '左上', '上', '右上' }
    local i = (math.floor((a + 22.5) / 45) % 8) + 1
    return string.format('%s(%.2f,%.2f)', names[i], u.X, u.Y)
end

local function report(label, st, out)
    local m = st.decision.metrics or {}
    print(string.format('  [%s] 原因=%-24s 输出=%-22s 接管=%s',
        label, tostring(st.decision.reason), dirName(out), tostring(st.decision.command ~= nil)))
    print(string.format('        候选=%-3s 评估=%-3s 触发源=%-8s 初始硬穿透=%.2f 名义风险=%.1f 选中风险=%.1f 收益=%.1f',
        tostring(m.candidates), tostring(m.evaluated), tostring(m.triggerKind),
        tonumber(m.initialPenetration) or -1, tonumber(m.nominalRisk) or -1,
        tonumber(m.selectedRisk) or -1, tonumber(m.riskImprovement) or -1))
end

-- ============================================================
print('===== F1: 飞行角色站在石头上（期望: 不接管）=====')
do
    local map = {
        '###############',
        '#.............#',
        '#.............#',
        '#.............#',
        '#....R........#',
        '#.............#',
        '#.............#',
        '#.............#',
        '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    -- 石块格中心 (5,4)→(240,280)
    for _, fly in ipairs({ true, false }) do
        for _, off in ipairs({ { 0, 0 }, { -12, 0 }, { -20, -8 } }) do
            local st = newState(cfg, 240 + off[1], 280 + off[2], 0, 0, 1, 0, fly)
            local ter = Terrain.create()
            ter:build(room, fly, cfg)
            local out = plan(st, ter, {}, 18610)
            local h = select(1, ter:probe(st.player.position, PLAYER_R))
            report(string.format('%s 偏移(%d,%d) 硬穿透=%.1f', fly and '飞行' or '步行', off[1], off[2], h), st, out)
        end
    end
end

-- ============================================================
print()
print('===== F2: 火堆 —— 闭环模拟（玩家一直按住方向，看是否真的躲开）=====')
do
    local map = {
        '###############',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    local ter = Terrain.create(); ter:build(room, false, cfg)
    local FX, FY = 240, 280
    local cases = {
        { '正左 40px 按右', -40, 0, 1, 0 },
        { '正左 30px 按右', -30, 0, 1, 0 },
        { '左上 40,40 按右下', -40, -40, 1, 1 },
        { '正左 60px 按右', -60, 0, 1, 0 },
    }
    for _, c in ipairs(cases) do
        local st = newState(cfg, FX + c[2], FY + c[3], 0, 0, c[4], c[5], false)
        local px, py = st.player.position.X, st.player.position.Y
        local vx, vy = 0, 0
        local firstOut, firstReason, contact = nil, nil, nil
        local minGap = math.huge
        for f = 1, 40 do
            SMOKE.frameCount = 0
            local cmd = Planner.run(st, { config = st.config, terrain = ter,
                getHazards = function() return { fireAt(FX, FY) } end }, 18610 + f)
            local playerDir = ReadI.executable(st.player.inputDir)
            local out = blend(cfg, playerDir, cmd)
            if f == 1 then firstOut, firstReason = out, st.decision.reason end
            local m = Motion.ensure(st)
            local nx, ny, nvx, nvy = Motion.step(m, px, py, vx, vy, out)
            px, py, vx, vy = nx, ny, nvx, nvy
            st.player.position = Vector(px, py)
            st.player.velocity = Vector(vx, vy)
            local dx = math.max(math.abs(px - FX) - FIRE_R, 0)
            local dy = math.max(math.abs(py - FY) - FIRE_R, 0)
            local gap = math.sqrt(dx * dx + dy * dy) - PLAYER_R
            if gap < minGap then minGap = gap end
            if not contact and gap <= 0 then contact = f end
        end
        print(string.format('  [%s] 首帧输出=%-22s(%s) 最小间隙=%.2f 接触帧=%s 末位置=(%.0f,%.0f)',
            c[1], dirName(firstOut), tostring(firstReason), minGap,
            contact and tostring(contact) or '无接触', px, py))
    end
end

-- ============================================================
print()
print('===== F3: 斜向弹幕 —— 闭环模拟（弹幕朝玩家飞）=====')
do
    local map = {
        '###############',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    local ter = Terrain.create(); ter:build(room, false, cfg)
    -- 玩家 (240,280) 静止；弹幕从右上 (300,220) 朝左下飞，速度 (~ -3.5,3.5)
    for _, spec in ipairs({
        { '斜向弹幕 按右', 1, 0, 304, 216, -3.4, 3.4 },
        { '斜向弹幕 按住不动', 0, 0, 304, 216, -3.4, 3.4 },
    }) do
        local st = newState(cfg, 240, 280, 0, 0, spec[2], spec[3], false)
        local px, py = 240, 280
        local vx, vy = 0, 0
        local ox, oy = spec[4], spec[5]
        local ovx, ovy = spec[6], spec[7]
        local firstOut, firstReason, hit = nil, nil, nil
        for f = 1, 25 do
            SMOKE.frameCount = 0
            local cmd = plan(st, ter, { tearAt(ox, oy, ovx, ovy) }, 18610 + f)
            local playerDir = ReadI.executable(st.player.inputDir)
            local out = blend(cfg, playerDir, cmd)
            if f == 1 then firstOut, firstReason = out, st.decision.reason end
            local m = Motion.ensure(st)
            local nx, ny, nvx, nvy = Motion.step(m, px, py, vx, vy, out)
            px, py, vx, vy = nx, ny, nvx, nvy
            ox, oy = ox + ovx, oy + ovy
            if not hit and math.sqrt((px - ox) ^ 2 + (py - oy) ^ 2) <= PLAYER_R + 5 then hit = f end
        end
        print(string.format('  [%s] 首帧输出=%-22s(%s) 命中帧=%s 末位置=(%.0f,%.0f)',
            spec[1], dirName(firstOut), tostring(firstReason),
            hit and tostring(hit) or '未命中', px, py))
    end
end

-- ============================================================
print()
print('===== F4: 随机扫描（确定性 PRNG，200 例/类）=====')
do
    local map = {
        '###############',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '#.............#',
        '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    local ter = Terrain.create(); ter:build(room, false, cfg)
    local seed = 12345
    local function rnd()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    local DIRS = {}
    for i = 0, 7 do DIRS[#DIRS + 1] = Vector(math.cos(i * math.pi / 4), math.sin(i * math.pi / 4)) end
    local function idx(v)
        if v:Length() < 0.05 then return 0 end
        return (math.floor((math.atan2(v.Y, v.X) * 180 / math.pi + 22.5) / 45) % 8) + 1
    end

    -- (1) 火堆：玩家按住某方向、火堆在其前方 ±60°、距离 35~110px
    local contact, sumGap, diag, rev, cases = 0, 0, 0, 0, 0
    for i = 1, 200 do
        local d = DIRS[1 + math.floor(rnd() * 8)]
        local ang = (rnd() * 2 - 1) * (math.pi / 3)
        local ca, sa = math.cos(ang), math.sin(ang)
        local ox, oy = d.X * ca - d.Y * sa, d.X * sa + d.Y * ca
        local dist = 35 + rnd() * 75
        local fx, fy = 240 + ox * dist, 280 + oy * dist
        if fx > 70 and fx < 570 and fy > 150 and fy < 410 then
            cases = cases + 1
            local st = newState(cfg, 240, 280, 0, 0, d.X, d.Y, false)
            local px, py, vx, vy = 240, 280, 0, 0
            local minGap, first = math.huge, nil
            for f = 1, 30 do
                SMOKE.frameCount = 0
                local cmd = plan(st, ter, { fireAt(fx, fy) }, 18610 + f)
                local out = blend(cfg, ReadI.executable(st.player.inputDir), cmd)
                if f == 1 then first = out end
                local m = Motion.ensure(st)
                local nx, ny, nvx, nvy = Motion.step(m, px, py, vx, vy, out)
                px, py, vx, vy = nx, ny, nvx, nvy
                st.player.position, st.player.velocity = Vector(px, py), Vector(vx, vy)
                local dx = math.max(math.abs(px - fx) - FIRE_R, 0)
                local dy = math.max(math.abs(py - fy) - FIRE_R, 0)
                local gap = math.sqrt(dx * dx + dy * dy) - PLAYER_R
                if gap < minGap then minGap = gap end
            end
            sumGap = sumGap + minGap
            if minGap <= 0 then contact = contact + 1 end
            local a, b = idx(d), idx(first)
            if b > 0 and (b % 2 == 0) then diag = diag + 1 end
            if a > 0 and b > 0 and (a - b) % 8 == 4 then rev = rev + 1 end
        end
    end
    print(string.format('  [火堆] 样本=%d 碰火=%d (%.0f%%) 平均最小间隙=%.2fpx 斜向输出=%d (%.0f%%) 反向=%d (%.0f%%)',
        cases, contact, 100 * contact / math.max(1, cases), sumGap / math.max(1, cases),
        diag, 100 * diag / math.max(1, cases), rev, 100 * rev / math.max(1, cases)))

    -- (2) 弹幕：从随机方向直线飞向玩家，距离 50~110px
    local hit, cases2, firstRev = 0, 0, 0
    for i = 1, 200 do
        local d = DIRS[1 + math.floor(rnd() * 8)]
        local dist = 50 + rnd() * 60
        local sp = 3 + rnd() * 3
        local ox, oy = -d.X * dist, -d.Y * dist
        cases2 = cases2 + 1
        local st = newState(cfg, 240, 280, 0, 0, d.X, d.Y, false)
        local px, py, vx, vy = 240, 280, 0, 0
        local tx, ty, tvx, tvy = 240 + ox, 280 + oy, -ox / dist * sp, -oy / dist * sp
        local got, first = nil, nil
        for f = 1, 25 do
            SMOKE.frameCount = 0
            local cmd = plan(st, ter, { tearAt(tx, ty, tvx, tvy) }, 18610 + f)
            local out = blend(cfg, ReadI.executable(st.player.inputDir), cmd)
            if f == 1 then first = out end
            local m = Motion.ensure(st)
            local nx, ny, nvx, nvy = Motion.step(m, px, py, vx, vy, out)
            px, py, vx, vy = nx, ny, nvx, nvy
            tx, ty = tx + tvx, ty + tvy
            st.player.position, st.player.velocity = Vector(px, py), Vector(vx, vy)
            if not got and math.sqrt((px - tx) ^ 2 + (py - ty) ^ 2) <= PLAYER_R + 5 then got = f end
        end
        if got then hit = hit + 1 end
        local a, b = idx(d), idx(first)
        if a > 0 and b > 0 and (a - b) % 8 == 4 then firstRev = firstRev + 1 end
    end
    print(string.format('  [弹幕] 样本=%d 命中=%d (%.0f%%) 首帧反向=%d (%.0f%%)',
        cases2, hit, 100 * hit / math.max(1, cases2), firstRev, 100 * firstRev / math.max(1, cases2)))

    -- (3) 飞行角色站在石头上（期望: 0 次接管）
    -- 石块在格 (5,4) → 格中心 (240,280)（与 F1 同一布局）
    local rockMap = { '###############', '#.............#', '#.............#', '#.............#',
        '#....R........#', '#.............#', '#.............#', '#.............#', '###############' }
    local rockRoom = makeRoom(rockMap)
    local terFly = Terrain.create(); terFly:build(rockRoom, true, cfg)
    local taken, flyCases, walkCases, walkTaken = 0, 0, 0, 0
    local OFFS = { { 0, 0 }, { -12, 0 }, { 12, 0 }, { -20, -8 }, { 16, 12 }, { -8, 16 } }
    for i = 1, 8 do
        for _, off in ipairs(OFFS) do
            flyCases = flyCases + 1
            local st = newState(cfg, 240 + off[1], 280 + off[2], 0, 0, DIRS[i].X, DIRS[i].Y, true)
            if plan(st, terFly, {}, 18610) then taken = taken + 1 end
        end
    end
    local terWalk = Terrain.create(); terWalk:build(rockRoom, false, cfg)
    for _, off in ipairs(OFFS) do
        walkCases = walkCases + 1
        local st = newState(cfg, 240 + off[1], 280 + off[2], 0, 0, 1, 0, false)
        if plan(st, terWalk, {}, 18610) then walkTaken = walkTaken + 1 end
    end
    print(string.format('  [飞行越障] %d 例（8 方向 x %d 偏移）接管 %d 次（期望 0）; 步行对照 %d/%d 接管（期望 >0）',
        flyCases, #OFFS, taken, walkTaken, walkCases))
    print(string.format('  [规划器异常] 全扫描共 %d 次（main.lua 用 SafeCall 吞掉 → 该帧不接管）', planErrors))
end

-- ============================================================
print()
print('===== F5: 贴墙/贴石接触（旧代码把 0.6px 足印重叠当穿透并把玩家推开）=====')
do
    local rockMap = { '###############', '#.............#', '#.............#', '#.............#',
        '#....R........#', '#.............#', '#.............#', '#.............#', '###############' }
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    local total, taken, shoved = 0, 0, 0
    local rows = {}
    for _, strict in ipairs({ false, true }) do
        local room = makeRoom(rockMap, strict)
        local ter = Terrain.create(); ter:build(room, false, cfg)
        -- 石块格 (5,4) AABB = [220,260]x[260,300]；玩家中心距它 9.4px → 足印重叠 0.6px
        local cases = {
            { '贴石按向石(右)', 210.6, 280, 0, 0, 1, 0 },
            { '贴石沿墙(上)', 210.6, 280, 0, 0, 0, -1 },
            { '贴房间左墙按左', 69.4, 200, 0, 0, -1, 0 },
            { '贴房间上墙按上', 300, 149.4, 0, 0, 0, -1 },
            { '空旷处按右(对照)', 240, 200, 0, 0, 1, 0 },
        }
        for _, c in ipairs(cases) do
            total = total + 1
            local st = newState(cfg, c[2], c[3], c[4], c[5], c[6], c[7], false)
            local u = plan(st, ter, {}, 18610)
            if u then
                taken = taken + 1
                -- 输出是否把玩家推离接触面（与输入反向或垂直）
                local dot = u.X * c[6] + u.Y * c[7]
                if dot < 0.5 then shoved = shoved + 1 end
                rows[#rows + 1] = string.format('      %s%s → %s', strict and '[strict]' or '', c[1], dirName(u))
            else
                rows[#rows + 1] = string.format('      %s%s → 不接管(%s)', strict and '[strict]' or '', c[1], tostring(st.decision.reason))
            end
        end
    end
    print(string.format('  贴墙/贴石 %d 例：接管 %d 次（期望 0），其中把玩家推离接触面 %d 次', total, taken, shoved))
    for _, l in ipairs(rows) do print(l) end
    -- 真实穿透仍要处理：飞行站在石头正中（旧代码在这里会接管并把玩家推开）
    local room = makeRoom(rockMap)
    local terFly = Terrain.create(); terFly:build(room, true, cfg)
    local st = newState(cfg, 240, 280, 0, 0, 1, 0, true)
    local u = plan(st, terFly, {}, 18610)
    print(string.format('  飞行站在石头正中 → %s（期望不接管）', u and dirName(u) or '不接管(' .. tostring(st.decision.reason) .. ')'))
end

-- ============================================================
print()
print('===== F6: 地面液体归属（玩家/友方 creep 不该被当成威胁）=====')
do
    local EffectSensor = require('sensors/effects')
    local Tracker = require('entities/tracker')
    local function eff(index, variant, extra)
        -- 真机的 creep 效果常带 CollisionDamage（旧代码的"未分类但带伤害即威胁"兜底路径
        -- 正是把自己/友方的水迹也收进来的入口）
        local e = { Type = EntityType.ENTITY_EFFECT, Index = index, Variant = variant,
            Position = Vector(0, 0), Velocity = Vector(0, 0), Size = 12, CollisionDamage = 1,
            IsDead = function() return false end }
        for k, v in pairs(extra or {}) do e[k] = v end
        return e
    end
    SMOKE.entities = {
        eff(850, 22),                                                  -- 敌方 CREEP_RED
        eff(851, 46),                                                  -- 玩家 PLAYER_CREEP_RED（无生成者）
        eff(852, 22, { SpawnerType = 3 }),                             -- 跟班生成
        eff(853, 22, { SpawnerEntity = { Type = 33, HasEntityFlags = function() return true end } }),  -- 友方 NPC 生成
        eff(854, 22, { SpawnerEntity = { Type = 33, HasEntityFlags = function() return false end } }), -- 敌对 NPC 生成
    }
    local trk = Tracker.create()
    EffectSensor.collect(nil, trk, 10, { hazardCreep = true })
    local ids = {}
    for i in pairs(trk.tracked) do ids[#ids + 1] = i end
    table.sort(ids)
    print(string.format('  采集到 %d 条（期望 2 = 850 敌方 + 854 敌对NPC生成）：%s', trk.count, table.concat(ids, ',')))
    local trk2 = Tracker.create()
    EffectSensor.collect({ canFly = true }, trk2, 10, { hazardCreep = true })
    print(string.format('  飞行时采集到 %d 条（期望 0：飞行免疫地面液体）', trk2.count))
    SMOKE.entities = {}
end

-- ============================================================
print()
print('===== F7: 脏轨迹样本（同一位置记进相邻两帧）不能让直线弹幕掉头 =====')
do
    local map = {
        '###############', '#.............#', '#.............#', '#.............#',
        '#.............#', '#.............#', '#.............#', '#.............#', '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    local ter = Terrain.create(); ter:build(room, false, cfg)
    -- 回放 220104 受击2 的真实数据：玩家(290.2,221.2) 静止；弹幕(284.6,240.2) vel=(0.36,-4.99)
    -- 即贴脸 19px 且每帧接近 5px；但 tracker 历史里第 23051/23052 帧位置相同。
    local pts = { { 23050, 284.3, 245.2 }, { 23051, 284.6, 240.2 }, { 23052, 284.6, 240.2 } }
    local e = { id = 'projectile:321:3840938311', index = 321, seed = 3840938311, kind = 'projectile',
        pos = Vector(284.6, 240.2), vel = Vector(0.36, -4.99), speed = 5, radius = 5, damage = 1,
        lastFrame = 23052, historyCount = 3, history = {} }
    for i, p in ipairs(pts) do
        e.history[i] = { pos = Vector(p[2], p[3]), vel = Vector(0.36, -4.99), frame = p[1] }
    end
    local st = newState(cfg, 290.2, 221.2, 0.09, -0.09, 0, 0, false)
    local u = plan(st, ter, { e }, 23052)
    local m = st.decision.metrics or {}
    local Predict = require('threat/projectile_predict')
    local Future = require('threat/future_motion')
    local p1 = Future.pos(e, 1, e.lastFrame)
    print(string.format('  分类: isParabolic=%s isCurved=%s isTracking=%s',
        tostring(Predict.isParabolic(e)), tostring(Predict.isCurved(e)), tostring(Predict.isTracking(e))))
    print(string.format('  t=1 预测位置 y=%.1f（真值 %.1f，向上逼近玩家）', p1.Y, e.pos.Y - 4.99))
    print(string.format('  规划器: 原因=%-24s 预测首碰撞=%s（旧代码 = -1 即“无威胁”） 输出=%s',
        tostring(st.decision.reason), tostring(m.nominalHit), u and dirName(u) or '不接管'))
end
