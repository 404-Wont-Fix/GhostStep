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

    -- 瞄准型砸击/挥击（Mother 的 WristAttack / ScrapeAttack / GroundPound / Swipe / Chomp，
    -- 以及 JumpDown 这类"朝玩家落下来"的冲击）。
    --
    -- 与 jumping 的关键区别：落点锁在"起手那一刻的玩家位置"，不跟速度走、也不跟着玩家漂。
    --   * 旧 jumping 形状 pos + vel*0.75*前摇 对这种攻击无效：起手时本体/玩家相对速度≈0，
    --     算出来的落点就是它自己站着的地方（跳蛛那次的教训，见 AGENTS.md）。
    --   * 落点如果每帧重算成"当前玩家位置"，禁区就跟着玩家跑，玩家永远逃不出去
    --     （炸弹爆圈变成永久禁区那次就是这个病）。
    -- 回放依据（session_20260913_223945，Mother 战）：17 次受击里 8 次规划器判 nominal_safe，
    -- 玩家站位离她中心 128~140px（本体 110 + 玩家 10 = 120 的接触圈差 8~20px），
    -- 她的挥臂/刮地动画全部落进 anim_missing（库里没有条目）→ 完全没有预判。
    slam = {
        kind        = "npc_attack",
        radiusFrom  = "slamRadius",
        aimLock     = true,         -- 落点 = 起手帧的玩家位置（锁死，不跟随）
        velScale    = 0,            -- 静止冲击点
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

-- 砸击落点半径（kind=slam）：
--   Mother 912: 本体 collisionRadius=110、双手在 anm2 里左右各摊到 ±206px，
--   挥臂类动画（WristAttack 66 帧 / ScrapeAttack 26 帧 / GroundPound 42 帧 / Swipe 34 帧）
--   的落点用 100px 半径——前摇 12~28 帧 × 5px/帧 ≈ 60~140px 位移，够走出这个圈。
Profiles.slamRadiusByType = {
    [912] = 100,  -- Mother（挥臂/刮地/踏地/横扫）
    [74]  = 70,   -- Blastocyst 跳压
    [75]  = 60,
    [76]  = 50,
}
Profiles.defaultSlamRadius = 80

return Profiles
