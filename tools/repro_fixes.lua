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

-- ============================================================
print()
print('===== F8: 追踪炸弹（用户 2026-09-13 反馈 1）—— 爆圈是定时事件，不是永久禁区 =====')
-- 真实回放数据：
--   * session_20260913_220304 帧 225882（宝箱开出的 Megatroll Bomb，variant=4）：
--     炸弹 (196.57,295.98) vel=(-0.98,-0.11)、玩家 (125.4,290.7)，
--     距离 71px < 爆圈 90 + 玩家 10 → 已在爆圈内，实测挨了 100 伤害（dmg=100）。
--   * session_20260911_000240 帧 17249~17251（同类追踪炸弹的长寿场景）：
--     录像里 mod 先 2 帧 180° 反向猛推（dodge=(0.98,-0.20) 而玩家按左），
--     之后 ~150 帧全是 budget_no_improving_action（一次都没介入）。
-- 根因：EntityBomb 只有 SetExplosionCountdown，没有只读引信（IsaacDocs/rep/EntityBomb），
--       旧实现 window() 退回 (0, math.huge) → 90px 爆圈被当成“立刻且永久”，所有候选都“在圈里”。
do
    local map = {
        '###############', '#.............#', '#.............#', '#.............#',
        '#.............#', '#.............#', '#.............#', '#.............#', '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    local ter = Terrain.create(); ter:build(room, false, cfg)
    local BX, BY, BVX, BVY = 196.57, 295.98, -0.98, -0.11
    local PX, PY = 125.4, 290.7
    local BASE = 225882
    -- appearFrame/endFrame 是绝对帧号（回放时间轴）
    local function bombHazard(appearFrame, endFrame)
        return { id = 'bomb:24:1773849412', index = 24, seed = 1773849412, kind = 'bomb',
            entityType = 4, variant = 4, pos = Vector(BX, BY), vel = Vector(BVX, BVY),
            speed = math.sqrt(BVX * BVX + BVY * BVY), radius = 90, damage = 100,
            appearFrame = appearFrame and (BASE + appearFrame) or nil,
            endFrame = endFrame and (BASE + endFrame) or nil }
    end
    local function run(label, hazard, ix, iy)
        local st = newState(cfg, PX, PY, 0, 0, ix, iy, false)
        local u = plan(st, ter, { hazard }, BASE)
        local m = st.decision.metrics or {}
        print(string.format('  %-36s 原因=%-26s 首碰撞=%-5s 风险 %.1f→%.1f 输出=%s',
            label, tostring(st.decision.reason), tostring(m.nominalHit),
            m.nominalRisk or 0, m.selectedRisk or 0, u and dirName(u) or '不接管'))
        return st, u
    end
    -- ① 旧行为：没有引信 → (0, math.huge) → 90px 永久禁区（玩家只要往炸弹那边走就被掰开）
    run('旧(引信未知→永久爆圈) 玩家按左', bombHazard(nil, nil), -1, 0)
    -- ② 新行为：引信估计 45 帧（Megatroll 1.5~2.5s 取下限）→ 离爆炸还早 → 不抢操作
    run('新(预估 45 帧后炸)   玩家按左', bombHazard(45, 47), -1, 0)
    -- ③ 新行为：快炸了（12 帧）+ 玩家站着不动 → 必须跑出爆圈
    local st3, u3 = run('新(预估 12 帧后炸)   玩家不动', bombHazard(12, 14), 0, 0)
    local m3 = st3.decision.metrics or {}
    if m3.selectedEndX then
        print(string.format('     选中终点 (%.1f,%.1f) 距炸弹 %.1fpx（爆圈 90+10=100）输出=%s',
            m3.selectedEndX, m3.selectedEndY,
            math.sqrt((m3.selectedEndX - BX) ^ 2 + (m3.selectedEndY - BY) ^ 2),
            u3 and dirName(u3) or '不接管'))
    end
end

-- ============================================================
print()
print('===== F9: Mother（妈腿）战 133px 站位的“规划器判安全”到底差多少 =====')
-- 真实回放 session_20260913_223945：16 次 srcT=912 受击的（本体位置, 玩家位置, 玩家输入）配对。
-- 本体 912:10 的 collisionRadius/Entity.Size = 110，玩家 10 → 接触圈 120。
-- 8 次受击时规划器判 nominal_safe（站位 131~168px，刚好在 120 圈外一点点）。
-- 这里用当帧真实坐标跑当前规划器：旧接触圈(110) vs 攻击期扩圈(110+48)。
do
    local map = {
        '###############', '#.............#', '#.............#', '#.............#',
        '#.............#', '#.............#', '#.............#', '#.............#', '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 200
    local ter = Terrain.create(); ter:build(room, false, cfg)
    local HITS = {
        { 440, 362, 569.6, 393.6,  0,  0, 'nominal_safe' },
        { 440, 248, 517.3, 318.6, -1,  0, 'disabled' },
        { 320, 420, 147.8, 501.1, -1,  0, 'disabled' },
        { 439, 363, 563.5, 397.8, -1, -1, 'disabled' },
        { 320, 420, 452.2, 543.8, -1,  1, 'disabled' },
        { 200, 645, 320.2, 690.8,  0,  0, 'budget_no_improving_action' },
        { 440, 628, 569.9, 597.5, -1,  0, 'nominal_safe' },
        { 200, 280,  70.0, 261.1, -1,  0, 'nominal_safe' },
        { 320, 420, 143.1, 477.0,  1,  0, 'safe_evasion' },
        { 200, 434,  74.8, 475.0,  1,  1, 'nominal_safe' },
        { 320, 420, 223.0, 451.4,  1,  0, 'reduce_exposure' },
        { 440, 606, 570.0, 575.3,  1, -1, 'nominal_safe' },
        { 320, 420, 459.8, 427.7,  0,  1, 'nominal_safe' },
        { 440, 503, 564.4, 550.4,  0, -1, 'nominal_safe' },
        { 200, 350, 329.9, 329.8, -1, -1, 'reduce_exposure' },
        { 320, 420, 454.4, 318.8,  0,  1, 'nominal_safe' },
    }
    local FRAME = 338462
    -- endFrame: 真机里"攻击期扩圈"的窗口 = 动画剩余帧数（WristAttack 66 帧、起手时 66），
    -- 旧接触圈（enemy 传感器）则是无期限的（敌人本体一直在那儿）。
    local function entry(bx, by, radius, endFrame)
        return { id = 'enemy:912:1', index = 10, seed = 1, kind = 'enemy', entityType = 912,
            variant = 10, pos = Vector(bx, by), vel = Vector(0, 0), speed = 0,
            radius = radius, damage = 1, confidence = 1, endFrame = endFrame }
    end
    local blindOld, blindNew, seenOld, seenNew, actedNew = 0, 0, 0, 0, 0
    for i = 1, #HITS do
        local h = HITS[i]
        local stOld = newState(cfg, h[3], h[4], 0, 0, h[5], h[6], false)
        local uOld = plan(stOld, ter, { entry(h[1], h[2], 110) }, FRAME)
        local stNew = newState(cfg, h[3], h[4], 0, 0, h[5], h[6], false)
        local uNew = plan(stNew, ter, { entry(h[1], h[2], 158, FRAME + 40) }, FRAME)
        if stOld.decision.reason == 'nominal_safe' then blindOld = blindOld + 1 end
        if stNew.decision.reason == 'nominal_safe' then blindNew = blindNew + 1 end
        if (stOld.decision.metrics or {}).nominalHit then seenOld = seenOld + 1 end
        if (stNew.decision.metrics or {}).nominalHit then seenNew = seenNew + 1 end
        if uNew then actedNew = actedNew + 1 end
        print(string.format('  #%2d 本体→玩家 %5.0fpx  旧(110): %-24s %-8s  新(158): %-24s %-8s',
            i, math.sqrt((h[3] - h[1]) ^ 2 + (h[4] - h[2]) ^ 2),
            tostring(stOld.decision.reason), uOld and dirName(uOld) or '不接管',
            tostring(stNew.decision.reason), uNew and dirName(uNew) or '不接管'))
    end
    print(string.format('  合计: 判安全(盲区) 旧 %d → 新 %d；识别到危险(hit 预测) 旧 %d → 新 %d；新模型介入 %d',
        blindOld, blindNew, seenOld, seenNew, actedNew))
    print('  说明: 本体贴墙角落时 18 帧内跑不出 168px 圈 → no_improving_action（至少已经“看见了”，')
    print('        不再是 nominal_safe）；开阔位置的逃逸方向会真的把玩家带出攻击范围。')

    -- 真正的机制：砸击动画给出 46 帧前摇 → 落点锁在起手时的玩家位置，闭环跑一下就出圈
    print()
    print('  --- 瞄准型砸击闭环（WristAttackLeft：impact=第 46 帧、落点锁在起手玩家位置、半径 100）---')
    local slam = { id = 'npc_attack:10050:1', index = 10050, seed = 1, kind = 'npc_attack',
        pos = Vector(320, 300), vel = Vector(0, 0), speed = 0, radius = 100, damage = 1,
        appearFrame = 46, endFrame = 66, aimLocked = true }
    local st = newState(cfg, 320, 300, 0, 0, 0, 0, false)
    local p, v = Vector(320, 300), Vector(0, 0)
    local W = cfg.maxDodgeWeight or 0.85
    local frames, dirs = 0, {}
    for frame = 0, 45 do
        st.player.position = Vector(p.X, p.Y); st.player.velocity = Vector(v.X, v.Y)
        local u = plan(st, ter, { slam }, frame)
        if u then dirs[#dirs + 1] = dirName(u) end
        local mix = u and u * W or Vector(0, 0)
        v = Vector(0.75 * v.X + 1.5 * mix.X, 0.75 * v.Y + 1.5 * mix.Y)
        p = p + v
        frames = frames + 1
    end
    print(string.format('    46 帧后玩家离落点 %.1fpx（爆圈 100+10=110），期间 AI 方向 %d 次，末次=%s',
        p:Distance(Vector(320, 300)), #dirs, #dirs > 0 and dirs[#dirs] or '不接管'))
end

-- ============================================================
print()
print('===== F8b: 追踪炸弹闭环 —— “等快爆炸再跑” vs “从现在就开始拉开距离” =====')
-- 用户 2026-09-13 补充：那种追着你跑、然后自爆的炸弹，站着等它快爆炸再跑是跑不开的
-- （它会一直跟着你，玩家速度有限）。
-- 炸弹运动按回放 bomb:655（session_20260911_000240）实测轮廓：朝玩家扑过来（峰值 10px/帧、
-- 直线扑、不会中途拐弯），贴到 ~45px 就停下来等着炸；玩家最快 ~6px/帧。
-- 关键差别在于“引信只能估”：默认引信从“第一次看到这颗炸弹”起算，而第一眼看到时它
-- 可能已经点着了一段时间（房间切换 / 屏幕外生成 / 追踪炸弹引信本身随机 1.5~2.5s）——
-- 只按估出来的爆炸帧躲会晚。下面的场景就是：真实爆炸在 18 帧后，估算写在 39 帧后。
do
    local map = {
        '###############', '#.............#', '#.............#', '#.............#',
        '#.............#', '#.............#', '#.............#', '#.............#', '###############',
    }
    local room = makeRoom(map)
    local cfg = Defaults.get(); cfg.budgetMs = 100000
    local ter = Terrain.create(); ter:build(room, false, cfg)
    local W = cfg.maxDodgeWeight or 0.85
    local BLAST, EST = 18, 39        -- 真实爆炸帧 / 插件估算爆炸帧（首次看到 + 45 - 6）
    local STOP, CLEAR = 45, 100      -- 扑到离“起扑点”45px 停下；判定线 = 爆圈 90 + 玩家 10

    local function simulate(liveNow)
        local p, v = Vector(320, 300), Vector(0, 0)
        local bomb = Vector(320 - 150, 300)
        local target = Vector(320, 300)   -- 起扑时锁定的落点（扑出去就不拐弯）
        local st = newState(cfg, p.X, p.Y, 0, 0, 0, 0, false)
        local firstAct
        for frame = 0, BLAST do
            -- 炸弹：朝锁定的落点直线扑，离落点 45px 处停下（回放 bomb:655 的落点是玩家当时的位置）
            local dx, dy = target.X - bomb.X, target.Y - bomb.Y
            local dist = math.max(0.001, math.sqrt(dx * dx + dy * dy))
            local speed = math.max(0, math.min(10, (dist - STOP) / 8))
            local step = Vector(dx / dist * speed, dy / dist * speed)
            bomb = bomb + step
            local hazard = { id = 'bomb:655:1', index = 24, kind = 'bomb', entityType = 4, variant = 4,
                pos = bomb, vel = step, speed = speed,
                radius = 90, damage = 100, chasing = liveNow,
                -- 传感器在“判定在追我”那一帧锁定的玩家位置（future_motion 用它做“到位就停”外推）
                chaseTargetX = liveNow and p.X or nil, chaseTargetY = liveNow and p.Y or nil,
                appearFrame = liveNow and frame or EST, endFrame = (liveNow and EST or EST) + 2 }
            st.player.position = Vector(p.X, p.Y); st.player.velocity = Vector(v.X, v.Y)
            local u = plan(st, ter, { hazard }, frame)
            if u and not firstAct then firstAct = frame end
            local mix = u and u * W or Vector(0, 0)
            v = Vector(0.75 * v.X + 1.5 * mix.X, 0.75 * v.Y + 1.5 * mix.Y)
            p = p + v
            if frame == BLAST then return p:Distance(bomb), firstAct end
        end
        return p:Distance(bomb), firstAct
    end

    local dTimed, actTimed = simulate(false)
    local dLive, actLive = simulate(true)
    print(string.format('  只盖估算爆炸帧（等快炸再跑）: 首次出手 = 第 %s 帧，爆炸时距炸弹 %6.1fpx → %s',
        tostring(actTimed), dTimed, dTimed >= CLEAR and '刚好躲开' or '**被炸到**'))
    print(string.format('  追踪中就一直危险（现在就拉开）: 首次出手 = 第 %s 帧，爆炸时距炸弹 %6.1fpx → %s',
        tostring(actLive), dLive, dLive >= CLEAR and '躲开了' or '**被炸到**'))
    print(string.format('  （判定线 %.0fpx = 爆圈 90 + 玩家 10；场地 640x280，玩家最快 ~6px/帧）', CLEAR))
end
