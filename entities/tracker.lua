-- entities/tracker.lua
-- 跨帧实体追踪器（SocketBridge 模式3：按 entity.Index 追踪、按类型过期、历史环形缓冲）
-- 没有跨帧追踪就无法预测弹幕轨迹；历史缓冲直接支持弧线预测（Phase 2 三点圆拟合）

local Tracker = {}

local HISTORY_MAX = 10 -- 每实体历史条数上限

-- 按类型配置过期帧数（弹幕移动极快，短暂未见即过期）
local EXPIRY = {
    projectile = 5,
    enemy = 10,
    pickup = 30,
}

--- 创建追踪器实例（方法通过模块元表挂载，实例:method() 可用）
function Tracker.create()
    local self = {
        tracked = {},  -- [entity.Index] = { pos, vel, speed, radius, firstFrame, lastFrame, history }
        count = 0,
    }
    return setmetatable(self, { __index = Tracker })
end

local function newEntry(entry, frame)
    -- 全字段复制（pos/vel 之外 sensors 提供的 damage/fuseFrames/endPos/angle/kind 等都要带上）
    local t = {}
    for k, v in pairs(entry) do
        t[k] = v
    end
    t._fields = {}
    for k in pairs(entry) do t._fields[k] = true end
    t.id = tostring(entry.kind or "projectile") .. ":" .. tostring(entry.index) .. ":" .. tostring(entry.seed or frame)
    t.firstFrame = frame
    t.lastFrame = frame
    t.historyCount = 1
    -- 历史环形缓冲：定长数组复用，避免 table.remove 的 O(n) 与 GC 压力
    t.history = { { pos = entry.pos, vel = entry.vel, frame = frame } }
    t.historyHead = 2 -- 初始条目在 slot 1，下一条写入 slot 2
    return t
end

--- 用当帧实体列表更新追踪器。entries: {{index, pos, vel, speed, radius, kind}}
function Tracker.update(self, entries, frame, expiryKind)
    local expiry = EXPIRY[expiryKind] or 10
    local tracked = self.tracked
    local seen = {}

    for i = 1, #entries do
        local e = entries[i]
        local t = tracked[e.index]
        seen[e.index] = true
        if t and e.seed ~= nil and t.seed ~= e.seed then
            tracked[e.index] = nil
            self.count = self.count - 1
            t = nil
        end
        if t then
            for k in pairs(t._fields) do
                if e[k] == nil then t[k] = nil; t._fields[k] = nil end
            end
            for k in pairs(e) do t._fields[k] = true end
            -- 已追踪：同步全部数据字段（pos/vel 之外的 kind/damage/endPos/angle 等每帧可变），
            -- 再追加历史
            for k, v in pairs(e) do
                t[k] = v
            end
            t.lastFrame = frame
            local head = t.historyHead
            local slot = t.history[head]
            if slot then
                slot.pos = e.pos
                slot.vel = e.vel
                slot.frame = frame
            else
                t.history[head] = { pos = e.pos, vel = e.vel, frame = frame }
            end
            t.historyHead = head % HISTORY_MAX + 1
            if t.historyCount < HISTORY_MAX then t.historyCount = t.historyCount + 1 end
        else
            tracked[e.index] = newEntry(e, frame)
            self.count = self.count + 1
        end
    end

    -- 过期清理：帧数未见的实体移除
    for index, t in pairs(tracked) do
        if not seen[index] and (frame - t.lastFrame) > expiry then
            tracked[index] = nil
            self.count = self.count - 1
        end
    end
end

--- 获取一个实体的历史（旧→新）。返回数组（调用方只读）
function Tracker.getHistory(self, index)
    local t = self.tracked[index]
    if not t or t.historyCount == 0 then return nil end
    local ordered = {}
    local n = t.historyCount
    for i = 1, n do
        local idx
        if n < HISTORY_MAX then
            idx = i -- 未满：按写入顺序 1..n
        else
            -- 已满：head 是最旧（即将被覆盖）的位置
            idx = (t.historyHead + i - 2) % HISTORY_MAX + 1
        end
        ordered[#ordered + 1] = t.history[idx]
    end
    return ordered
end

--- 实体新鲜度：距上次见过了几帧；不存在返回 nil
function Tracker.getStaleness(self, index, frame)
    local t = self.tracked[index]
    if not t then return nil end
    return frame - t.lastFrame
end

--- 清空
function Tracker.clear(self)
    self.tracked = {}
    self.count = 0
end

--- 获取 N 帧内见过的活跃实体（用于决策时的宽容读取）
function Tracker.getActive(self, maxStale, frame)
    local result = {}
    for _, t in pairs(self.tracked) do
        if (frame - t.lastFrame) <= maxStale then
            result[#result + 1] = t
        end
    end
    return result
end

-- offset=0 为最新样本，直接访问环形槽位，不分配有序副本。
function Tracker.recent(entry, offset)
    local n=entry.historyCount or 0
    if n<=offset then return nil end
    if not entry.historyHead then return entry.history[n-offset] end
    local idx=(entry.historyHead-2-offset)%HISTORY_MAX+1
    return entry.history[idx]
end

--- 最近 n 个“位置彼此不同”的样本（旧→新）。重复样本（同一位置被记进相邻两帧）
--- 会让一阶/二阶差分得到 0 位移或虚假的巨大加速度，三点圆拟合也会退化，
--- 所以所有高阶模型（弧线/抛物线/追踪）都必须建立在**去重后的样本**上。
--- 历史不足 n 个不同位置时返回较短数组（调用方按 #ret 判断）。
function Tracker.distinctSamples(entry, n)
    n = n or 3
    local newest = {}
    local count = entry.historyCount or 0
    local lastX, lastY
    for offset = 0, count - 1 do
        local s = Tracker.recent(entry, offset)
        if s then
            local x, y = s.pos.X, s.pos.Y
            if lastX == nil or math.abs(x - lastX) > 1e-6 or math.abs(y - lastY) > 1e-6 then
                newest[#newest + 1] = s
                lastX, lastY = x, y
                if #newest >= n then break end
            end
        end
    end
    local ordered = {}
    for i = #newest, 1, -1 do ordered[#ordered + 1] = newest[i] end
    return ordered
end

--- 历史样本与“实体自报速度”的一致性校验（供弧线/抛物线/追踪型预测器使用）。
--- 为什么要这个：mod 的回调频率可能高于游戏逻辑更新频率（双帧计数器），
--- tracker 会把**同一位置记进相邻两帧**。那时二阶差分看起来像“每帧减速 5px/帧²”的
--- 巨大加速度，抛物线拟合会把轨迹掰向反方向 ——
--- 回放 220104 受击2 就是实例：直线下落的弹幕被预测成掉头向下，规划器判“无威胁”，玩家挨打。
--- 判据（只去重后校验最近一步，不反推速度）：
---   ① 量级：|步长/dt| 与自报速度同量级（0.3~3 倍）。dt 不可靠（同一逻辑帧可能被采两次），
---      所以区间放宽，只挡“0 位移 / 反向 / 数量级不符”的脏样本；
---   ② 方向：步进方向与自报速度夹角 ≤ ~72°，这是抛物线误判的直接特征。
--- 剔除后仍有 ≥3 个不同位置的样本时，才允许弧线/抛物线拟合。
function Tracker.motionConsistent(entry)
    local d = Tracker.distinctSamples(entry, 2)
    if #d < 2 then return false end
    local p1, p2 = d[1], d[2]
    local dt = p2.frame - p1.frame
    if dt <= 0 then return false end
    local vx, vy = entry.vel and entry.vel.X or 0, entry.vel and entry.vel.Y or 0
    local velLen = math.sqrt(vx * vx + vy * vy)
    if velLen <= 1 then return true end -- 慢速：位置差本来就不准，不做高阶拟合更有意义
    local sx, sy = (p2.pos.X - p1.pos.X) / dt, (p2.pos.Y - p1.pos.Y) / dt
    local stepLen = math.sqrt(sx * sx + sy * sy)
    if stepLen < velLen * 0.3 or stepLen > velLen * 3 then return false end
    return (sx * vx + sy * vy) >= 0.3 * stepLen * velLen
end
return Tracker
