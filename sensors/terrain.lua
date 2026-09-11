-- 房间碰撞缓存：线性格子索引、圆形玩家足迹、真实房间边界。
local Terrain = {}
local CELL = 40
local C, G = GridCollisionClass, GridEntityType
-- 柱子（Rep+ GRID_PILLAR=24）: 飞行也不能飞过去。枚举缺失/为 0 时不参与比较
-- （离线 mock 会把未定义枚举的默认值当 0，否则会误伤所有空格的 GetType()）。
local PILLAR = G.GRID_PILLAR
-- 通行判定。飞行只对“地面障碍”豁免（wiki/Flight）:
--   飞行能飞过石头/方块/粪便(COLLISION_SOLID=3)、坑(COLLISION_PIT=1)、机器/盆火等(OBJECT=2)；
--   但不能穿房间墙(COLLISION_WALL=4)，Rep+ 也**不能飞过柱子**(GRID_PILLAR=24)。
-- 历史 bug: 旧实现只豁免 OBJECT/PIT，SOLID 在飞行时仍算墙 —— 飞行角色飞到石头上方
-- 就被 probe 判成“在墙里 10~30px”，规划器于是拼命把玩家推离石头（回放实测:
-- 会话 20260911_205153 的 101 个接管帧 100% 是 terrain 触发、0 个真实威胁，
-- 12 帧输出与玩家输入完全反向，即在“抢操作”）。
local function walkable(c, fly, typ)
    if c == C.COLLISION_WALL then return false end
    if fly then return not (PILLAR ~= nil and PILLAR ~= 0 and typ == PILLAR) end
    return c ~= C.COLLISION_SOLID and c ~= C.COLLISION_OBJECT and c ~= C.COLLISION_PIT
end
--- 门格豁免：门格位置在房间形状之外（IsPositionInRoom 为假），但玩家合法可站。
--- 旧实现把门格当墙 → 玩家进门洞就被判"在墙里 18px"，规划器在该状态整体失效。
--- 回放实测：门格被误判 5167 格次（collision=5 全部 walkable=0）；
--- 15 个受击快照里 9 个正处于这个状态。两个信号任一成立即豁免：
---   1) 碰撞类 = WALL_EXCEPT_PLAYER（引擎明确表示"只挡非玩家"）
---   2) Room:GetDoor(slot).Position 落在该格（部分房间门格报 COLLISION_WALL）
local function doorCellsOf(room, total)
    local cells
    if room.GetDoor and room.GetGridIndex then
        for slot = 0, 7 do
            local ok, door = pcall(function() return room:GetDoor(slot) end)
            if ok and door and door.Position then
                local okIdx, idx = pcall(function() return room:GetGridIndex(door.Position) end)
                if okIdx and type(idx) == "number" and idx >= 0 and idx < total then
                    cells = cells or {}
                    cells[idx] = true
                end
            end
        end
    end
    return cells
end

function Terrain.create()
    return setmetatable({valid=false, grid={}, sizeX=0, sizeY=0, revision=0, doorCells=nil},
        {__index=Terrain})
end
function Terrain.build(self, room, fly, config)
    if not room then return false end
    local total, width = room:GetGridSize(), room:GetGridWidth()
    if not total or not width or width <= 0 or total <= 0 then return false end
    local grid, changed = self.grid, not self.valid or self.canFly ~= fly
    local doorCells = doorCellsOf(room, total)
    for index = 0, total - 1 do
        local g = room:GetGridEntity(index)
        local collision = g and g.CollisionClass or C.COLLISION_NONE
        if room.GetGridCollision then collision = room:GetGridCollision(index) end
        local typ = g and g:GetType()
        local door = (doorCells and doorCells[index]) or collision == C.COLLISION_WALL_EXCEPT_PLAYER
        local inside = door or not room.IsPositionInRoom or room:IsPositionInRoom(room:GetGridPosition(index), 0)
        local pass = inside and walkable(collision, fly, typ)
        -- 飞行时石头/坑不再是硬地形，grid 只留 collision 供诊断。
        local danger
        -- 地刺: 飞行免疫（wiki/Flight: 不被 creep/spikes 伤害，献祭房地刺除外），
        -- 但尖刺岩石对飞行仍然造成伤害 → 即使飞行也作为软危险保留。
        if g and config.hazardSpikes then
            if (typ == G.GRID_SPIKES or typ == G.GRID_SPIKES_ONOFF) and (g.State or 0) == 0 then
                if not fly then danger = "spike" end
            elseif typ == G.GRID_ROCK_SPIKED and collision ~= C.COLLISION_NONE then
                danger = "spike"
            end
        end
        -- 已炸毁的 TNT 可能保留 State/VarData 与 GridEntity；无碰撞残骸不能重建障碍。
        -- 步行时 TNT 是硬障碍 + 软危险（推入火/刺岩/红便便会炸）；
        -- 飞行时只是可飞越的障碍物（wiki/TNT: 被摧毁才爆，接触不爆）→ 不再当危险，
        -- 否则飞行角色会被一块 TNT 持续推开。
        if g and config.hazardTnt and not fly and typ == G.GRID_TNT and collision ~= C.COLLISION_NONE
            and ((g.State or 0)>1 or (g.VarData or 0)>0) then
            danger, pass = "tnt", false
        end
        local old = grid[index+1]
        if not old or old.walkable ~= pass or old.danger ~= danger or old.collision ~= collision then changed = true end
        local cell = old or {}
        cell.walkable, cell.danger, cell.collision = pass, danger, collision
        grid[index+1] = cell
    end
    for i=total+1,#grid do grid[i]=nil end
    self.grid, self.sizeX, self.sizeY = grid, width, math.ceil(total/width)
    self.topLeft = room:GetGridPosition(0) - Vector(20,20)
    self.doorCells = doorCells
    self.room, self.canFly, self.valid = room, fly, true
    -- 贴墙接触裕量（见 probe 注释）；由 config 控制，便于回归测试与现场调参。
    self.slack = config and config.wallContactSlack or 0
    self.roomIndex = Game():GetLevel():GetCurrentRoomIndex()
    if changed then self.revision = self.revision + 1 end
    return true
end
function Terrain.refresh(self, room, fly, config, frame)
    -- 签名变化即重建（MCM 现场调参会改这些值）
    local signature = tostring(config.hazardSpikes)..tostring(config.hazardTnt)
        ..tostring(config.wallContactSlack)
    if not self.valid or fly ~= self.canFly or signature ~= self.signature
        or frame - (self.lastRefresh or -999) >= (config.terrainRefreshFrames or 3) then
        self.lastRefresh, self.signature = frame, signature
        return self:build(room, fly, config)
    end
    return false
end
function Terrain.cellAt(self, p)
    if not self.valid then return nil end
    local x,y = math.floor((p.X-self.topLeft.X)/CELL), math.floor((p.Y-self.topLeft.Y)/CELL)
    if x<0 or y<0 or x>=self.sizeX or y>=self.sizeY then return nil end
    return y*self.sizeX+x+1
end
function Terrain.cellCenter(self,x,y) return self.topLeft+Vector(x*CELL+20,y*CELL+20) end
function Terrain.isWalkableAt(self,p)
    if not self.valid then return true end
    local idx = self:cellAt(p)
    return idx ~= nil and self.grid[idx] ~= nil and self.grid[idx].walkable == true
end
function Terrain.dangerAt(self,p)
    local idx=self:cellAt(p)
    return idx and self.grid[idx] and self.grid[idx].danger or nil
end
--- 当前位置是否落在门格上（门洞是合法位置，不算穿墙）
function Terrain.isDoorAt(self,p)
    local idx = self:cellAt(p)
    if idx == nil then return false end
    if self.doorCells and self.doorCells[idx] then return true end
    local c = self.grid[idx]
    return c ~= nil and c.collision == C.COLLISION_WALL_EXCEPT_PLAYER
end
-- 一次扫描同时得到两个深度：硬地形（墙/坑/石头）与软危险（地刺/TNT）。
-- 拆开才能让地刺从"一击否决"变成"带代价可穿越"。
-- 返回 hardDepth, dangerDepth
-- 贴墙接触裕量（wallContactSlack）：引擎本身允许玩家贴墙走 —— 实测玩家中心距实心格
-- 最近可达 9.2px，而 player.radius=10，于是一贴墙就算出 0.5~1.2px 的"穿透"，
-- IsPositionInRoom(p,r) 在边界处又恒返 false 再加 1px。后果有两层：
--   1) initialDepth>0 → 拿不到 nominal_safe，且 triggerKind 永远是 terrain
--      （会话 220104 的 555 段避让里 327 段是这个假触发，占 59%）；
--   2) 更严重：peakDepth*10 让 base（玩家按向墙那侧）风险凭空高几十，
--      规划器于是把贴墙走的玩家推离墙；同时 depth>0 会短路"撞墙位置钉住"，
--      模型在墙附近会直接把候选路径开进石头里。
-- 小于裕量的硬穿透按 0 处理（软危险/地刺不动，踩刺本来就是真接触）。
function Terrain.probe(self,p,r)
    if not self.valid then return 0,0 end
    r = r or 0
    local left,top = self.topLeft.X,self.topLeft.Y
    local hard = math.max(0,left+r-p.X,top+r-p.Y,p.X+r-left-self.sizeX*CELL,p.Y+r-top-self.sizeY*CELL)
    local danger = 0
    if self.room and self.room.IsPositionInRoom and not self.room:IsPositionInRoom(p,r)
        and not self:isDoorAt(p) then
        -- 对 L 形房间仍使用引擎边界；避免只检查包围矩形。
        hard = math.max(hard, 1)
    end
    local x0,x1=math.floor((p.X-r-left)/CELL),math.floor((p.X+r-left)/CELL)
    local y0,y1=math.floor((p.Y-r-top)/CELL),math.floor((p.Y+r-top)/CELL)
    for y=math.max(0,y0),math.min(self.sizeY-1,y1) do
        for x=math.max(0,x0),math.min(self.sizeX-1,x1) do
            local c=self.grid[y*self.sizeX+x+1]
            if c and (not c.walkable or c.danger) then
                local ax,ay=left+x*CELL,top+y*CELL
                local dx=math.max(ax-p.X,0,p.X-ax-CELL)
                local dy=math.max(ay-p.Y,0,p.Y-ay-CELL)
                local d=math.sqrt(dx*dx+dy*dy)
                local pen=r-d
                if d==0 then pen=r+math.min(p.X-ax,ax+CELL-p.X,p.Y-ay,ay+CELL-p.Y) end
                if not c.walkable then hard=math.max(hard,pen) end
                if c.danger then danger=math.max(danger,pen) end
            end
        end
    end
    if hard<=self.slack then hard=0 end
    return hard, danger
end
-- 返回重叠深度。足迹与实心格子用圆-AABB，允许沿墙滑动。
-- includeDanger=true（默认行为）时地刺/TNT 也算在内。
function Terrain.penetration(self,p,r,includeDanger)
    local hard,danger=self:probe(p,r)
    if includeDanger then return math.max(hard,danger) end
    return hard
end
function Terrain.isSafeAt(self,p,r,includeDanger)
    local hard,danger=self:probe(p,r)
    if includeDanger==false then return hard<=0 end
    return hard<=0 and danger<=0
end
function Terrain.segmentSafe(self,a,b,r,includeDanger,startDepth,endDepth)
    local steps=math.max(1,math.ceil(a:Distance(b)/math.max(2,math.min(8,(r or 8)*0.5))))
    -- 规划器已算过两端足迹，复用结果避免每个候选重复调用引擎边界 API。
    if (startDepth or self:penetration(a,r,includeDanger))>0
        or (endDepth or self:penetration(b,r,includeDanger))>0 then return false end
    for i=1,steps-1 do
        if self:penetration(a+(b-a)*(i/steps),r,includeDanger)>0 then return false end
    end
    return true
end
function Terrain.distanceToWall(self,p,dir,r)
    if not self.valid then return 9999 end
    if self:penetration(p,r or 0,false)>0 then return -self:penetration(p,r or 0,false) end
    for d=4,400,4 do
        if self:penetration(p+dir*d,r or 0,false)>0 then return d-2 end
    end
    return 400
end
function Terrain.minWallDistance(self,p,r)
    local best=9999
    for _,d in ipairs({Vector(1,0),Vector(-1,0),Vector(0,1),Vector(0,-1)}) do
        best=math.min(best,self:distanceToWall(p,d,r))
    end
    return best
end
function Terrain.invalidate(self) self.valid=false; self.room=nil; self.doorCells=nil end
return Terrain
