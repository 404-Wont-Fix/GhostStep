-- analysis/repro_ring.lua
-- 用回放里的真实房间网格 + 真实炸弹参数，跑改后的 decision/predictive.lua。
-- 目的: 验证"地刺环 + 炸弹"不再把所有候选一票否决（旧行为: 17/18 terrainRejected）。
-- 由 analysis/run_repro.py 加载（先跑 tests/smoke.lua 注入 Isaac mock）。
-- 输入数据由 Python 通过全局字符串传入: REPRO_W / REPRO_C / REPRO_S（逗号分隔）

-- 用真机枚举值覆盖 smoke mock（mock 里的碰撞类/网格类型编号与真机不同）
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

local Defaults = require('config/defaults')
local Runtime = require('config/runtime')
local Terrain = require('sensors/terrain')
local Planner = require('decision/predictive')

local function split(s)
    local t = {}
    for v in string.gmatch(s or '', '([^,]+)') do t[#t + 1] = tonumber(v) end
    return t
end

local function decode(w, c, s)
    local W, C, S = split(w), split(c), split(s)
    local cells = {}
    for i = 1, #W do
        cells[i] = { walk = W[i], coll = C[i], spike = (S[i] or 0) == 1 }
    end
    return cells
end

local function makeRoom(cells, W, LEFT, TOP)
    local H = math.floor(#cells / W)
    return {
        IsClear = function() return true end,
        GetGridSize = function() return W * H end,
        GetGridWidth = function() return W end,
        GetGridPosition = function(_, i)
            -- 真机 API 返回格中心（Terrain.build 会再减 20 得到格角）
            return Vector(LEFT + 20 + (i % W) * 40, TOP + 20 + math.floor(i / W) * 40)
        end,
        GetGridEntity = function(_, i)
            local c = cells[i + 1]
            if not c then return nil end
            if c.spike then
                return { CollisionClass = c.coll, State = 0, VarData = 0,
                         GetType = function() return GridEntityType.GRID_SPIKES end }
            end
            return { CollisionClass = c.coll, State = 0, VarData = 0,
                     GetType = function() return 0 end }
        end,
        GetGridCollision = function(_, i)
            local c = cells[i + 1]
            return c and c.coll or 4
        end,
        -- 标准 13x7 可走区域: x∈[60,580], y∈[140,420]
        IsPositionInRoom = function(_, p)
            return p.X >= 60 and p.X <= 580 and p.Y >= 140 and p.Y <= 420
        end,
        GetType = function() return 1 end,
    }
end

local RINGS = decode(REPRO_W, REPRO_C, REPRO_S)
local DOORS = decode(REPRO_DW, REPRO_DC, REPRO_DS)

local function makeState()
    local cfg = Defaults.get()
    local st = Runtime.create(cfg)
    st.player.valid = true
    st.player.moveSpeed = 1
    st.player.radius = 10
    return st
end

local function run(label, room, px, py, vx, vy, ix, iy, hazards)
    local st = makeState()
    st.player.position = Vector(px, py)
    st.player.velocity = Vector(vx, vy)
    st.player.inputDir = Vector(ix, iy)
    local terrain = Terrain.create()
    terrain:build(room, false, st.config)
    local hz = hazards or {}
    local u = Planner.run(st, { config = st.config, terrain = terrain,
        getHazards = function() return hz end }, 18610)
    local m = st.decision.metrics or {}
    local rows = (st.decision.lastTrace and st.decision.lastTrace.candidates) or {}
    local rejected = 0
    for _, c in ipairs(rows) do if c.terrainRejected then rejected = rejected + 1 end end
    print(string.format('[%s] 输入=(%.2f,%.2f) 输出=%s', label, ix, iy,
        u and string.format('(%.2f,%.2f) 长度=%.2f', u.X, u.Y, u:Length()) or 'nil(不接管，放行玩家输入)'))
    print(string.format('     原因=%-26s 候选=%-3s 评估=%-3s 完整=%-5s 窗口=%-3s',
        tostring(st.decision.reason), tostring(m.candidates), tostring(m.evaluated),
        tostring(m.complete), tostring(m.horizon)))
    print(string.format('     地形一票否决候选=%d/%d  初始硬穿透=%.2f 初始刺穿透=%.2f  触发源=%s',
        rejected, #rows, tonumber(m.initialPenetration) or -1,
        tonumber(m.initialSpikeDepth) or -1, tostring(m.triggerKind)))
    for i = 1, math.min(8, #rows) do
        local c = rows[i]
        print(string.format('       cand%-3s u=(%6.2f,%6.2f) dur=%-3s risk=%-10.1f 刺帧=%-3s 地形拒绝=%s',
            tostring(c.id), c.x or 0, c.y or 0, tostring(c.duration), c.risk or 0,
            tostring(c.spikeTicks), tostring(c.terrainRejected)))
    end
end

print('===== 场景 A: 房间 83 地刺环环心 + 帧18610 真实炸弹 =====')
print('真实数据: 玩家(321.87,283.64) v=(-0.269,-0.269) 输入=(-1,-1) 炸弹(321.57,282.46) r=90')
local bomb = { id = 'bomb:62:131441024', index = 62, kind = 'bomb',
    pos = Vector(321.565, 282.4595), vel = Vector(1.1495, 1.8857), speed = 2.2,
    radius = 90, damage = 12, confidence = 0.3, lastFrame = 18610 }
local ring = makeRoom(RINGS, 15, 20, 100)
run('原地被爆圈覆盖', ring, 321.87, 283.64, -0.269, -0.269, -1, -1, { bomb })
run('按左（要离开环心）', ring, 321.87, 283.64, 0, 0, -1, 0, { bomb })
run('按右', ring, 321.87, 283.64, 0, 0, 1, 0, { bomb })
run('按上', ring, 321.87, 283.64, 0, 0, 0, -1, { bomb })
run('按下', ring, 321.87, 283.64, 0, 0, 0, 1, { bomb })
print()
print('===== 场景 B: 同房间无炸弹（纯地刺避让是否可见）=====')
run('环心按左（会踩刺）', ring, 320, 280, 0, 0, -1, 0, {})
run('环心按上（会踩刺）', ring, 320, 280, 0, 0, 0, -1, {})
run('站在刺格上不动', ring, 300, 280, 0, 0, 0, 0, {})
print()
print('===== 场景 D: 房间 83 沿墙走，直行会踩刺但斜向可绕开（地刺避让是否真的可见）=====')
print('玩家在(280,240)（自由格 6,3），按右直行会穿过 (7,3) 地刺格')
run('按右（直行踩刺）', ring, 280, 240, 0, 0, 1, 0, {})
run('按右，但已被地刺包围无处可绕', ring, 320, 240, 0, 0, 1, 0, {})
print()
print('===== 场景 C: 房间 84 门洞（旧行为: 初始硬穿透 18px 且全候选被否决）=====')
print('真实数据: 玩家(52.0,275.15) v=(-3.12,-0.37) 输入=(-1,0) wallDist=-18')
local door = makeRoom(DOORS, 15, 20, 100)
-- 诊断: 门格豁免是否生效
local probeTerrain = Terrain.create()
probeTerrain:build(door, false, Defaults.get())
local pp = Vector(52.0, 275.15)
local idx = probeTerrain:cellAt(pp)
local h, dg = probeTerrain:probe(pp, 10)
print(string.format('  诊断: cellAt=%s cellWalkable=%s cellCollision=%s doorCells=%s isDoorAt=%s probe=(%0.2f,%0.2f)',
    tostring(idx),
    tostring(idx and probeTerrain.grid[idx] and probeTerrain.grid[idx].walkable),
    tostring(idx and probeTerrain.grid[idx] and probeTerrain.grid[idx].collision),
    tostring(probeTerrain.doorCells ~= nil),
    tostring(probeTerrain:isDoorAt(pp)), h, dg))
run('门洞里按左（要出房间）', door, 52.0, 275.15, -3.12, -0.37, -1, 0, {})
run('门洞里按上', door, 52.0, 275.15, 0, 0, 0, -1, {})
run('门洞里静止', door, 52.0, 275.15, 0, 0, 0, 0, {})

print()
print('===== 场景 E: 恒定石像射手（Type 202）预测走廊几何 =====')
do
    local Sensor = require('sensors/npc_attacks')
    local Tracker = require('entities/tracker')
    local cfg = Defaults.get()
    -- 石像在房间左边墙，朝右开火（动画 ShootRight）
    local shooter = {
        Type = 202, Variant = 0, Index = 7, InitSeed = 4242,
        Position = Vector(80, 280), Velocity = Vector(0, 0), Size = 20,
        IsDead = function() return false end,
        IsActiveEnemy = function() return true end,
        HasEntityFlags = function() return false end,
        ToNPC = function() return {} end,
        GetSprite = function()
            return { GetAnimation = function() return 'ShootRight' end,
                     GetFrame = function() return 2 end }
        end,
    }
    SMOKE.entities = { shooter }
    local trk = Tracker.create()
    Sensor.collect(nil, trk, 100, cfg)
    local e = trk.tracked[10007]
    if e then
        print(string.format('  走廊: kind=%s 半宽=%.1f 长度=%.1f 起点=(%.0f,%.0f) 终点=(%.0f,%.0f)',
            tostring(e.kind), e.radius, e.length or -1, e.pos.X, e.pos.Y,
            e.endPos and e.endPos.X or -1, e.endPos and e.endPos.Y or -1))
        print(string.format('  旧值对比: 半宽 22（含玩家 10 + margin = 34px 侧向禁入）、长度固定 160'));
        print(string.format('  新值: 半宽 %.0f → 侧向禁入 ≈ %.1fpx；长度 %s（到右边墙 580）',
            e.radius, e.radius + 10 + 1.5, tostring(math.floor(e.length or -1))))
        print(string.format('  引信: fuseFrames=%s appearFrame=%s endFrame=%s 规则=%s',
            tostring(e.fuseFrames), tostring(e.appearFrame), tostring(e.endFrame), tostring(e.rule)))
    else
        print('  ✗ 未生成走廊（动画库缺少 202:0:ShootRight 条目或异常）')
    end
    SMOKE.entities = {}
end
