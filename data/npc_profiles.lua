-- data/npc_profiles.lua
-- NPC attack threat profiles: category -> threat generation rules
-- Used by sensors/npc_attacks.lua (table-driven approach)
--
-- Each category defines how to create a tracker entry from a detected attack animation.
-- The sensor looks up entity type + animation name in npc_animdb.lua,
-- gets the category, then looks up this profile to generate the threat entry.

local Profiles = {}

-- Per-category threat generation rules
Profiles.categories = {
    -- Stomping attacks (Daddy Long Legs, Triachnid, etc.)
    -- Predictable ground impact at entity position
    stomping = {
        kind        = "npc_attack",
        radius      = 64,   -- STOMP_IMPACT_RADIUS
        velScale    = 0,    -- stationary impact point
    },

    -- Jumping attacks (Widow, Leaper, Hopper, Mom's Hand, etc.)
    -- Landing impact, velocity predicts landing position
    jumping = {
        kind        = "npc_attack",
        radiusFrom  = "type_table", -- uses jumpRadiusByType below
        velScale    = 0.75,         -- JUMP_VELOCITY_SCALE
    },

    -- Laser windup (Vis, Maw, Bloat, Adversary, etc.)
    -- Generates a laser path segment toward the player
    laser = {
        kind        = "laser",
        radius      = 28,   -- LASER_WINDUP_RADIUS
        pathLength  = 480,  -- LASER_WINDUP_LENGTH (pixels)
    },

    -- Shooter windup (Horf, Gatling Gurdy, 恒定石像 Constant Stone Shooter...)
    -- Corridor capsule toward the player
    -- 半宽 22 → 8：实测石块半径只有 ~5px，旧值 22 加上玩家 10 + margin 后
    -- 离射线 34px 就判危险，会把"从机关前经过"整条封死（玩家反馈）。
    -- 长度改为运行时按"到墙距离"计算（见 sensors/npc_attacks.lua），这里只留上限。
    ranged = {
        kind        = "laser",      -- uses laser collision geometry (line segment)
        radius      = 8,            -- corridor half-width
        pathLength  = 240,          -- corridor length upper bound
    },
}

-- Per-entity-type radius overrides for jumping category
-- Falls back to _defaultJumpRadius if type not listed
Profiles.jumpRadiusByType = {
    [213] = 62,   -- Mom's Hand
    [287] = 66,   -- Mom's Dead Hand (slightly larger)
    [101] = 64,   -- Daddy Long Legs
    [100] = 54,   -- Widow
    [34]  = 54,   -- Leaper
    [29]  = 42,   -- Hopper (smaller)
}
Profiles.defaultJumpRadius = 62  -- FALLING_IMPACT_RADIUS

return Profiles
