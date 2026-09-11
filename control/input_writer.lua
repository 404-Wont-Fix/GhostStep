-- control/input_writer.lua
-- MC_INPUT_ACTION 输出层（7.5.1/7.5.2）
-- 关键策略: 只在介入时返回非 nil —— 无威胁时返回 nil，
-- 不与其他 mod 抢输入 hook（第一个返回非 nil 的胜出）

local InputWriter = {}

local ButtonAction = ButtonAction
local InputHook = InputHook
local EntityType = EntityType

--- 混合：把 AI 方向按权重叠到玩家输入上，而不是整根抽走玩家输入。
--- out = (1-w)*玩家输入 + w*AI方向，限幅到 1（不放大）。
--- w 来自 control.blendWeight（≤ maxDodgeWeight，原则2 永不 1.0）。
--- 玩家完全不动时 AI 方向也只占 w：保留"永不接管"语义，
--- 同时"停止"会退化为轻微刹车而不是硬锁方向（原则5 最小必要修正）。
--- blendWeight/playerDir 缺失时退回原始行为（纯 AI 方向）。
local function blend(control, dir)
    local w = control.blendWeight
    local playerDir = control.playerDir
    if not w or w <= 0 or not playerDir then return dir end
    local mixed = playerDir * (1 - w) + dir * w
    if mixed:Length() > 1 then mixed = mixed:Normalized() end
    return mixed
end

--- MC_INPUT_ACTION 回调主体
--- control: state.control 引用 { active, direction, weight, frame }
function InputWriter.onInputAction(control, observationMode, entity, inputHook, action)
    -- 只处理玩家移动动作
    if not entity or entity.Type ~= EntityType.ENTITY_PLAYER then return nil end
    -- 只拦截移动四轴
    if action ~= ButtonAction.ACTION_LEFT
        and action ~= ButtonAction.ACTION_RIGHT
        and action ~= ButtonAction.ACTION_UP
        and action ~= ButtonAction.ACTION_DOWN then
        return nil
    end
    -- 观察模式不干预
    if observationMode or control.readingRaw then return nil end

    -- 时效保护：决策超过2帧的旧数据不使用
    local frame = Isaac.GetFrameCount()
    if not control.active or (frame - control.frame) > 2 or frame < control.frame then return nil end

    local dir = control.direction
    if not dir then return nil end -- 零向量是有效的减速/停止命令。
    dir = blend(control, dir)

    -- 按轴提取分量（由 input_reader 提供统一的轴值函数）
    local InputReader = require("control/input_reader")
    local value = InputReader.actionValue(action, dir)

    if inputHook == InputHook.GET_ACTION_VALUE then
        control.hookSeen = true
        control.hookFrame = frame
        return value -- float [0,1]
    elseif inputHook == InputHook.IS_ACTION_PRESSED then
        return value > 0 -- boolean
    end
    -- 边沿触发留给硬件，避免把持续辅助变成每帧双击/冲刺。
    return nil -- 其他 hook 不拦截
end

return InputWriter
