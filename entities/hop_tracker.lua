-- entities/hop_tracker.lua
-- 跳跃型敌人（Trite/Hopper/Leaper 等）的节拍跟踪 + 落点预判
--
-- 事实来源：
--   * 中文名对照（游戏 stringtable.sta）：TRITE = 跳蛛，TWITCHY = 跳蛛尸，BLISTER = 水疱跳蛛。
--     entities2.xml: id=29 variant=1 name="#TRITE" collisionRadius=13 collisionDamage=1，
--     与 29 variant=0（Hopper）共用 029.001_Trite.anm2。
--   * wiki（Trite）："a spider variant of the Hoppers. Leaps with less frequency,
--     but at greater distances." → 跳得远、间隔久。
--   * 用户实机（2026-09-12）：跳跃距离随玩家距离变化（远→跳得远），直线朝玩家，
--     节奏固定。
--   * 回放实测：腾空时实体自报速度 8~10px/帧，落地后 ≈0。位置差分不可靠
--     （mod 回调频率高于游戏逻辑更新频率，同一位置会进相邻两帧），所以
--     **用实体自报速度判腾空** 而不是用位移。
--
-- 模型：观测节奏（起跳间隔 / 滞空帧数 / 跳距 / 是否瞄准玩家）
--       → 预测下一次起跳时刻与落点 = 当前朝向玩家的 clamp(距离, 观测跳距范围)。
-- 为什么落点取“玩家当前所在”：跳蛛瞄准的是起跳瞬间玩家所在点，所以
-- “原地不动必被踩、持续移动才躲得开”正是它要求的行为；规划器对每条候选
-- 各自算 clearance，于是自然会选“移动”而不是“站桩”。
-- 防止误判：若实测朝向与“玩家方向”的平均夹角 > hopAimMaxDeg（例如蜘蛛是随机跳的），
-- 就不做瞄准预测（返回 nil），退回原来的直线外推。

local Hop = {}

--- 实体自报速度（px/帧）；读不到按 0（= 视为在地面）
local function safeSpeed(e)
    local ok, v = pcall(function() return e.Velocity end)
    if not ok or v == nil then return 0 end
    local ok2, len = pcall(function() return v:Length() end)
    if ok2 and type(len) == "number" then return len end
    return 0
end

--- 两个向量的夹角（度）；任一为零向量返回 nil
local function angleDeg(ax, ay, bx, by)
    local la = math.sqrt(ax * ax + ay * ay)
    local lb = math.sqrt(bx * bx + by * by)
    if la < 0.001 or lb < 0.001 then return nil end
    local dot = (ax * bx + ay * by) / (la * lb)
    if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
    return math.deg(math.acos(dot))
end

local function ewma(old, new, alpha)
    if not old then return new end
    return old * (1 - alpha) + new * alpha
end

--- 创建实例
function Hop.create(cfg)
    return setmetatable({ states = {}, cfg = cfg }, { __index = Hop })
end

--- 房间切换时清空（entity.Index 会在新房间复用）
function Hop.reset(self)
    self.states = {}
    self.observed = 0
    self.events = {}
end

--- 取出并清空诊断事件（实测前摇/节拍/跳距/朝向误差）
function Hop.takeEvents(self)
    local evs = self.events or {}
    self.events = {}
    return evs
end

--- 未再见到的状态清理（敌人死亡/离房后残留）
function Hop.expire(self, frame, ttl)
    ttl = ttl or 300
    for index, st in pairs(self.states) do
        if frame - (st.lastFrame or frame) > ttl then self.states[index] = nil end
    end
end

--- 每帧观测一个跳跃型敌人。返回预测提示或 nil
--- anim（可选，由传感器读精灵得到）: {name=小写动画名, frame=当前帧, hop=true, total=总帧数, windup=前摇帧数}
--- 返回: { inFrames, flight, lx, ly, len, period, aimErr, leaps, anim, animFrame, windup } 或 nil
function Hop.observe(self, e, player, frame, cfg, anim)
    cfg = cfg or self.cfg or {}
    local pos = e.Position
    if pos == nil then return nil end
    local st = self.states[e.Index]
    if not st or st.seed ~= e.InitSeed then
        st = { seed = e.InitSeed, air = false, leaps = 0 }
        self.states[e.Index] = st
    end
    st.lastFrame = frame
    local ppos = player and player.position
    local px = ppos and ppos.X or pos.X
    local py = ppos and ppos.Y or pos.Y
    local pvel = player and player.velocity
    local speed = safeSpeed(e)
    -- 腾空判定：实体自报速度（主）+ 精灵动画（辅）。
    -- 速度是引擎自报的、可信；动画只用来补“已在播跳跃动画但还没开始位移”的前摇段。
    local animHop = anim ~= nil and anim.hop == true
    local air = speed >= (cfg.hopAirSpeed or 3.0)
    local vel = e.Velocity

    -- 动画播了多久（用于量“前摇到位移开始”的帧数）
    if animHop then
        if st.animName ~= anim.name then st.animName, st.animStart = anim.name, frame end
    else
        st.animName = nil
    end

    if air and not st.air then
        -- 起跳沿（靠速度）：如果动画已经在播，就量到“动画第几帧开始位移”＝实测前摇
        st.airStart = frame
        st.airX, st.airY = pos.X, pos.Y
        st.aimX, st.aimY = px, py
        st.airAnim = animHop and anim.name or nil   -- 落地时精灵已切回 Idle，事件要的是起跳时的动画
        if animHop then
            local w = frame - (st.animStart or frame)
            if w >= 0 and w <= 60 then st.windupFrames = ewma(st.windupFrames, w, 0.5) end
        end
    elseif (not air) and st.air then
        -- 落地沿：量滞空帧数 / 跳距 / 朝向误差
        -- 只有“显著跳跃”（净位移 ≥ hopMinLeap）才计入节拍：
        -- 速度在阈值附近抖动（位置几乎不动）的噪声不能污染起跳间隔。
        local flight = frame - (st.airStart or frame)
        local lx, ly = pos.X - (st.airX or pos.X), pos.Y - (st.airY or pos.Y)
        local len = math.sqrt(lx * lx + ly * ly)
        if len >= (cfg.hopMinLeap or 30) then
            if st.lastTakeoff then
                local period = st.airStart - st.lastTakeoff
                if period >= (cfg.hopMinPeriod or 8) and period <= (cfg.hopMaxPeriod or 180) then
                    st.period = ewma(st.period, period, 0.5)
                end
            end
            st.lastTakeoff = st.airStart
            if flight >= 2 then st.flight = ewma(st.flight, flight, 0.5) end
            st.leapLen = st.leapLen and (st.leapLen * 0.5 + len * 0.5) or len
            if not st.minLeap or len < st.minLeap then st.minLeap = len end
            if not st.maxLeap or len > st.maxLeap then st.maxLeap = len end
            local err = angleDeg(lx, ly, (st.aimX or px) - (st.airX or pos.X), (st.aimY or py) - (st.airY or pos.Y))
            if err then st.aimErr = ewma(st.aimErr, err, 0.3) end
            st.leaps = (st.leaps or 0) + 1
            self.observed = (self.observed or 0) + 1
            -- 诊断事件（main.lua 落盘）：离线直接核对“实测前摇/节拍/跳距/朝向”。
            -- 有这行才能不靠 detail4 逐帧日志就拿到标定数据。
            self.events = self.events or {}
            if #self.events < 240 then
                self.events[#self.events + 1] = {
                    ev = "hop_measured", index = e.Index, entityType = e.Type,
                    variant = e.Variant, frame = frame, leap = len, flight = flight,
                    period = st.period, windup = st.windupFrames, aimErr = st.aimErr,
                    anim = st.airAnim,
                }
            end
        end
        st.airX, st.airY, st.aimX, st.aimY, st.airStart, st.airAnim = nil, nil, nil, nil, nil, nil
    end
    st.air = air

    -- 瞄准模型：落点 = clamp(到“玩家在起跳那一刻的位置”的距离, 30, 340)。
    -- 为什么要外推：敌人瞄的是它起跳瞬间玩家所在点；只用“现在”会漏掉“玩家继续前进
    -- → 正好撞上落点”的情形（那正是最容易被踩到的情况）。
    -- 为什么不再用“观测到的最大跳距”当上限：跳距随玩家距离变化（用户实测），
    -- 观测值只能说明“目前为止看到的那几次”，不是敌人的上限。卡太死会把落点画短，
    -- 于是站在真正落点上也判成安全（闭环复现：观测 50px → 上限 100px，
    -- 而实际跳了 123px → 规划器放手不动 → 被踩）。
    local function aimLanding(inFrames)
        if inFrames < 0 then inFrames = 0 end
        local ax, ay = px, py
        if pvel then
            ax, ay = px + (pvel.X or 0) * inFrames, py + (pvel.Y or 0) * inFrames
        end
        local sx, sy = pos.X + (vel and vel.X or 0) * inFrames, pos.Y + (vel and vel.Y or 0) * inFrames
        local ddx, ddy = ax - sx, ay - sy
        local d = math.sqrt(ddx * ddx + ddy * ddy)
        if d < 0.001 then return nil end
        local maxLeap = cfg.hopMaxLeap or 340
        local minLeap = math.min(cfg.hopMinLeap or 30, maxLeap)
        local leap = d
        if leap < minLeap then leap = minLeap elseif leap > maxLeap then leap = maxLeap end
        local inv = leap / d
        return sx + ddx * inv, sy + ddy * inv,
            math.sqrt((sx - pos.X) ^ 2 + (sy - pos.Y) ^ 2) + leap
    end

    -- 实测朝向与玩家方向差太多（随机跳的敌人）→ 不做瞄准预测
    local aimErr = st.aimErr or 0
    if aimErr > (cfg.hopAimMaxDeg or 75) then return nil end
    local flight = st.flight or (cfg.hopDefaultFlight or 12)

    -- ① 动画信号：跳跃动画已在播、但还没开始位移（前摇段）→ 提前预警。
    --    这是动画库真正有用的地方：旧的 npc_attacks 链只会拿“剩余前摇 × 当前速度”
    --    猜落点，而跳蛛前摇时速度≈ 0 → 猜出来的落点就是它自己站着的位置（等于没用）。
    --    windup 优先用实测（“动画第几帧开始位移”，Hop 开始时量到），
    --    没有实测值时用动画库的启发值（windup_ratio=0.45），再没有就当作立刻起跳。
    if animHop and not air then
        local windup = st.windupFrames or (anim and anim.windup) or 0
        local remain = math.max(0, windup - ((anim and anim.frame) or 0))
        -- 滞空估计：实测优先；否则用“动画总帧数 - 前摇帧数”（Hop 26 - 11 = 15）；
        -- 不能用总帧数（会把前摇重复算一遍 → remain+flight > 34 直接自我否决）。
        local animFlight = (anim and anim.total and anim.windup)
            and math.max(1, anim.total - anim.windup) or nil
        local fl = st.flight or animFlight or cfg.hopDefaultFlight or 12
        if remain + fl <= (cfg.hopMaxLeadTotal or 34) then
            local lx, ly, len = aimLanding(remain)
            if lx then
                return { inFrames = remain, flight = fl, lx = lx, ly = ly, len = len,
                    period = st.period, aimErr = aimErr, leaps = st.leaps or 0,
                    anim = anim.name, animFrame = anim.frame, windup = st.windupFrames }
            end
        end
    end

    -- ② 节奏信号：地面 + 已知节拍 + 起跳在预警窗口内 + 落点能落在可见窗口内
    if air or not st.period or not st.lastTakeoff then return nil end
    local inFrames = st.lastTakeoff + st.period - frame
    if inFrames < 0 or inFrames > (cfg.hopLeadFrames or 30) then return nil end
    if inFrames + flight > (cfg.hopMaxLeadTotal or 34) then return nil end
    local lx, ly, len = aimLanding(inFrames)
    if not lx then return nil end
    return {
        inFrames = inFrames,
        flight = flight,
        lx = lx,
        ly = ly,
        len = len,
        period = st.period,
        aimErr = aimErr,
        leaps = st.leaps or 0,
        anim = animHop and anim.name or nil,
        animFrame = animHop and anim.frame or nil,
        windup = st.windupFrames,
    }
end

--- 诊断用快照（只读）
function Hop.stats(self, index)
    return self.states[index]
end

return Hop
