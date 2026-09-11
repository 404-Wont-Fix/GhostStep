-- tests/smoke.lua
-- 离线冒烟测试：用模拟的 Isaac API 跑通核心数据流
-- 直接改写 _G（require 的模块共享同一全局环境）
-- 运行: python tests/run_smoke.py（lupa Lua 5.1，与 Isaac 一致）

-- ===== Vector 模拟 =====
local Vector = {}
Vector.__index = Vector
local function V(x, y) return setmetatable({ X = x or 0, Y = y or 0 }, Vector) end

function Vector:Length()
    return math.sqrt(self.X * self.X + self.Y * self.Y)
end
function Vector:Distance(o)
    local dx, dy = self.X - o.X, self.Y - o.Y
    return math.sqrt(dx * dx + dy * dy)
end
function Vector:Normalized()
    local l = self:Length()
    if l < 0.0001 then return V(0, 0) end
    return V(self.X / l, self.Y / l)
end
function Vector:DistanceTo(o)
    local dx, dy = self.X - o.X, self.Y - o.Y
    return math.sqrt(dx * dx + dy * dy)
end
Vector.__add = function(a, b) return V(a.X + b.X, a.Y + b.Y) end
Vector.__sub = function(a, b) return V(a.X - b.X, a.Y - b.Y) end
Vector.__mul = function(a, b)
    if type(a) == "number" then return V(a * b.X, a * b.Y) end
    if type(b) == "number" then return V(a.X * b, a.Y * b) end
    return V(a.X * b.X, a.Y * b.Y)
end
Vector.__div = function(a, n) return V(a.X / n, a.Y / n) end
Vector.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
Vector.__tostring = function(a) return "(" .. a.X .. "," .. a.Y .. ")" end

_G.Vector = V

-- ===== 测试可控状态 =====
SMOKE = {
    frameCount = 0,
    entities = {},      -- Isaac.GetEntities 返回值
    players = 1,
    logs = {},
}

local function G() return SMOKE end

_G.Isaac = {
    GetFrameCount = function() return SMOKE.frameCount end,
    GetTime = function() return SMOKE.frameCount * 33 end,
    DebugString = function(s) SMOKE.logs[#SMOKE.logs + 1] = s end,
    GetScreenHeight = function() return 720 end,
    GetScreenWidth = function() return 1280 end,
    WorldToScreen = function(v) return v end,
    RenderText = function() end,
    GetEntities = function() return SMOKE.entities end,
    GetRoomEntities = function() return SMOKE.entities end,
    GetPlayer = function() return nil end,
    -- FindByType: 按 type 过滤 SMOKE.entities（只支持 type 精确匹配，variant/subtype 忽略）
    FindByType = function(etype, variant, subtype, onlyFirst)
        local result = {}
        for _, e in ipairs(SMOKE.entities) do
            if e.Type == etype then
                if onlyFirst then return e end
                result[#result + 1] = e
            end
        end
        return result
    end,
}

_G.Input = {
    IsButtonTriggered = function() return false end,
    IsActionPressed = function() return false end,
    GetActionValue = function() return 0 end,
}

local mockRoom = {
    IsClear = function() return false end, -- false = 有敌人 = 战斗中
    GetGridSize = function() return 15 * 9 end, -- API 返回格子总数(单值)
    GetGridWidth = function() return 15 end,
    GetGridEntity = function() return nil end,
    GetGridPosition = function(i) return V(i * 40, 0) end,
}

_G.Game = function()
    return {
        GetNumPlayers = function() return SMOKE.players end,
        GetRoom = function() return mockRoom end,
        GetLevel = function()
            return { GetCurrentRoomIndex = function() return 1 end }
        end,
    }
end

_G.EntityType = setmetatable({
    ENTITY_PLAYER = 9, ENTITY_FAMILIAR = 3, ENTITY_TEAR = 2,
    ENTITY_BOMB = 4, ENTITY_LASER = 7, ENTITY_KNIFE = 8,
    ENTITY_PROJECTILE = 1000, ENTITY_EFFECT = 1000, ENTITY_NPC = 33,
}, { __index = function() return 0 end })
-- 真机值（游戏 resources/scripts/enums.lua）。历史 mock 用的是另一套编号，
-- 导致离线复现工具必须覆盖枚举；这里直接对齐真机，避免两套编号。
_G.GridEntityType = setmetatable({
    GRID_ROCK = 2, GRID_ROCK_ALT = 6, GRID_PIT = 7,
    GRID_SPIKES = 8, GRID_SPIKES_ONOFF = 9, GRID_SPIDERWEB = 10,
    GRID_TNT = 12, GRID_POOP = 14, GRID_WALL = 15, GRID_DOOR = 16,
    GRID_PILLAR = 24, GRID_ROCK_SPIKED = 25,
}, { __index = function() return 0 end })
_G.GridCollisionClass = setmetatable({
    COLLISION_NONE = 0, COLLISION_PIT = 1, COLLISION_OBJECT = 2,
    COLLISION_SOLID = 3, COLLISION_WALL = 4, COLLISION_WALL_EXCEPT_PLAYER = 5,
}, { __index = function() return 0 end })
_G.ButtonAction = setmetatable({
    ACTION_LEFT = 0, ACTION_RIGHT = 1, ACTION_UP = 2, ACTION_DOWN = 3,
    ACTION_SHOOTLEFT = 4,
}, { __index = function() return 99 end })
_G.InputHook = {
    GET_ACTION_VALUE = 0, IS_ACTION_PRESSED = 1, IS_TRIGGERED = 2,
}
_G.EntityFlag = setmetatable({
    FLAG_FRIENDLY = 64, -- 值无关紧要，mock 判等用
}, { __index = function() return 0 end })

_G.EffectVariant = setmetatable({
    CREEP_RED = 22, CREEP_GREEN = 23, CREEP_YELLOW = 24,
    CREEP_WHITE = 25, CREEP_BLACK = 26, CREEP_BROWN = 56,
    HOT_BOMB_FIRE = 51, RED_CANDLE_FLAME = 52,
    SHOCKWAVE = 61, SHOCKWAVE_DIRECTIONAL = 67, CRACKWAVE = 72,
    MOM_FOOT_STOMP = 29, TARGET = 30, ROCKET = 31, MOMS_HAND = 91,
    BULLET_POOF = 11, TEAR_POOF_A = 12, BOMB_CRATER = 18, DUST_CLOUD = 59,
}, { __index = function() return 0 end })
_G.ModCallbacks = {
    MC_POST_PLAYER_UPDATE = 1, MC_INPUT_ACTION = 2, MC_POST_NEW_ROOM = 3,
    MC_POST_RENDER = 4, MC_POST_PLAYER_DEATH = 5, MC_ENTITY_TAKE_DMG = 6,
    MC_PRE_GAME_EXIT = 7,
}
