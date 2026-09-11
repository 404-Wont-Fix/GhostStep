-- config/mcm.lua
-- Mod Config Menu 集成（mod_config_menu_cn_2494192799）
-- MCM 未安装时静默降级为代码默认值，不崩溃（确认决策）
-- 数据流: MCM菜单 → OnChange → Config + 副作用 → 运行时生效
-- 持久化: mod:SaveData(json.encode(settings))，MCM 不自动保存

local MCM = {}

local CAT = "GhostStep3"
-- 引擎 Keyboard 枚举（GLFW 码）常用键 → 中文名（菜单可读性）
local KEY_NAMES = {
    [342] = "左Alt", [346] = "右Alt", [340] = "左Shift", [341] = "左Ctrl",
    [32] = "空格", [258] = "Tab", [96] = "~", [256] = "Esc",
}
-- 旧版把键盘值写成"顺序索引"：56 在 GLFW 码里是数字键 8，实际指向左Alt。
-- 存档里可能残留该错误值，加载时一次性纠正（否则只改默认值无效）。
local LEGACY_KEY_FIX = { [56] = 342 }
-- json 为 Isaac 内置模块（游戏自带，无需随 mod 分发）
local hasJson, json = pcall(require, "json")
if not hasJson then json = nil end

-- 设置定义表: {子分类, 属性名, 类型, 默认值, 参数/说明}
local SETTINGS = {
    -- 常规
    { "常规", "enabled",            "bool",   true,  "自动躲避总开关" },
    { "常规", "toggleKey",          "key",    342,   "开启/关闭快捷键 (默认左Alt)" },
    { "常规", "preset",             "number", 2,     min = 1, max = 3, step = 1,
      names = { "低", "适中", "高" }, info = "辅助强度：适中为默认；高档更早、更明显地修正输入" },
    -- 危险源
    { "危险源", "hazardProjectiles", "bool",  true, "躲避敌方弹幕" },
    { "危险源", "hazardContact",      "bool",  true, "躲避敌人接触伤害" },
    { "危险源", "hazardLasers",       "bool",  true, "躲避激光 (Phase 3)" },
    { "危险源", "hazardBombs",       "bool",  true, "躲避炸弹爆炸 (Phase 3)" },
    { "危险源", "hazardCreep",       "bool",  true, "躲避水坑/火焰 (Phase 3)" },
    { "危险源", "hazardNpcAttacks",  "bool",  true, "躲避NPC攻击前兆 (Phase 3)" },
    { "危险源", "hazardSpikes",      "bool",  true, "躲避地刺" },
    { "危险源", "hazardTnt",         "bool",  true, "躲避TNT爆炸" },
    { "躲避", "maxDodgeWeight",    "percent", 85,   "AI 输入权重上限(%): 越高 AI 介入越强，越低越容易掰回" },
    -- 显示
    { "显示", "renderEnabled",    "bool", false, "视觉反馈总开关" },
    { "显示", "renderThreatBar",  "bool", true,  "威胁等级指示器" },
    { "显示", "renderDodgeArrow", "bool", true,  "闪避方向箭头" },
    { "显示", "renderWeight",     "bool", true,  "输入修正幅度显示" },
    { "显示", "renderGradient",   "bool", false, "旧梯度显示（预测控制不使用）" },
    { "显示", "pureMode",         "bool", false, "纯净模式: 关闭所有视觉效果" },
    -- 录制
    { "录制", "recordingEnabled",   "bool",   true, "录制功能" },
    { "录制", "deathReplayEnabled", "bool",   true,  "死亡自动回放" },
    { "录制", "replayBufferSeconds", "number", 30,   min = 10, max = 120, step = 10,
      suffix = " 秒", info = "回放缓冲大小" },
    { "录制", "snapshotDetail",      "number", 2,    min = 1, max = 4, step = 1,
      names = { "最小", "标准", "详细", "全量" }, info = "快照详情级别（全量=逐威胁明细+候选评分，文件较大）" },
    { "录制", "eventRecording", "bool", false, "事件诊断：开启后预采集详细前后文（增加采集开销，内存有上限）" },
    -- 调试
    { "调试", "observationMode",    "bool", false, "观察模式: 只采集不控制" },
    { "调试", "profilerEnabled",    "bool", false, "性能分析器" },
    { "调试", "diagnosticsEnabled", "bool", false, "诊断事件日志" },
}

-- MCM 属性名 → Config 属性名映射（单位换算等在 onChange 处理）

-- 副作用表
local SIDE_EFFECTS = {
    pureMode = function(state) end,
    observationMode = function(state)
        state.control.active = false
        state.control.direction = Vector(0, 0)
    end,
    enabled = function(state, val)
        if not val then
            state.control.active = false
            state.control.direction = Vector(0, 0)
        end
    end,
    replayBufferSeconds = function(state) end, -- main 重建缓冲
    -- 威胁感知灵敏度 → 缩放三个介入阈值（越高越早介入）
    threatSensitivity = function(state, val)
        local mult = ({ [1] = 1.25, [2] = 1.0, [3] = 0.8 })[val] or 1.0
        local c = state.config
        c.threatLow = 0.25 * mult
        c.threatMedium = 0.45 * mult
        c.threatHigh = 0.65 * mult
    end,
    -- 墙角挣脱灵敏度 → 靠墙降权触发距离（越高越早进入挣脱模式）
    wallEscapeSensitivity = function(state, val)
        state.config.wallStuckThreshold = ({ [1] = 30, [2] = 40, [3] = 55 })[val] or 40
    end,
    preset = nil, -- applyPreset 由 main 处理
}

local mod          -- RegisterMod 实例
local stateRef     -- Runtime 状态引用
local presetsRef   -- Presets 模块

---------------------------------------------------------------
-- 持久化
---------------------------------------------------------------

function MCM.saveSettings()
    if not mod or not json then return end
    local data = {}
    -- 保存 Config 中的持久化字段
    for i = 1, #SETTINGS do
        local attr = SETTINGS[i][2]
        if attr == "maxDodgeWeight" then
            data[attr] = math.floor((stateRef.config.maxDodgeWeight or 0.85) * 100 + 0.5)
        else
            data[attr] = stateRef.config[attr]
        end
    end
    mod:SaveData(json.encode(data))
end

function MCM.loadSettings()
    if not mod or not json or not mod:HasData() then return end
    local ok, data = pcall(json.decode, mod:LoadData())
    if not ok or type(data) ~= "table" then return end
    local config = stateRef.config
    for k, v in pairs(data) do
        -- maxDodgeWeight 特殊处理：存档里是百分比整数(如85)，需要÷100得到0-1权重
        -- 必须在通用 type-match 之前处理，否则85会被直接赋给 config（应为0.85），
        -- 下次 saveSettings 又会 ×100 存回去，每个 save/load 循环膨胀×100
        -- （这个 bug 导致 AI 权重指数爆炸到8e13，原则2完全失效）
        if k == "maxDodgeWeight" and type(v) == "number" then
            config.maxDodgeWeight = math.min(0.95, math.max(0.5, v / 100))
        elseif k == "toggleKey" and LEGACY_KEY_FIX[v] ~= nil then
            config.toggleKey = LEGACY_KEY_FIX[v]
        elseif config[k] ~= nil and type(v) == type(config[k]) then
            config[k] = v
        end
    end
    if presetsRef then presetsRef.apply(config, config.preset) end
    -- 派生参数需重放副作用（灵敏度联动阈值等，存档只存旋钮本身）
    local reapply = { "threatSensitivity", "wallEscapeSensitivity" }
    for _, attr in ipairs(reapply) do
        local effect = SIDE_EFFECTS[attr]
        if effect and config[attr] ~= nil then
            effect(stateRef, config[attr])
        end
    end
end

---------------------------------------------------------------
-- 注册
---------------------------------------------------------------

local function onChange(attr, value)
    local config = stateRef.config
    local prev = config[attr]
    -- MCM 值 → Config 值
    if attr == "maxDodgeWeight" then
        config.maxDodgeWeight = value / 100
    elseif attr == "preset" then
        config.preset = value
        if presetsRef then presetsRef.apply(config, value) end
    else
        if config[attr] ~= nil then config[attr] = value end
    end
    require("config/runtime").suspendThreat(stateRef)
    -- 副作用
    local effect = SIDE_EFFECTS[attr]
    if effect then effect(stateRef, value) end
    -- 配置变更事件: 录制文件中留痕（离线 A/B 对比把差异归因到参数变更；
    -- preset 会级联改多个参数，按 preset 单键记录即可复现）
    if config[attr] ~= prev then
        local sr = stateRef.sessionRecorder
        if sr and sr.file then
            sr:event({ ev = "cfg", k = attr, v = config[attr] })
        end
    end
    -- 持久化
    MCM.saveSettings()
end

local function addBoolean(sub, attr, default, info)
    ModConfigMenu.AddSetting(CAT, sub, {
        Type = ModConfigMenu.OptionType.BOOLEAN,
        CurrentSetting = function()
            return stateRef.config[attr]
        end,
        Display = function()
            local on = stateRef.config[attr]
            return attr .. ": " .. (on and "开启" or "关闭")
        end,
        OnChange = function(v) onChange(attr, v) end,
        Info = { info },
    })
end

local function addNumber(sub, attr, default, s)
    local names = s.names
    ModConfigMenu.AddSetting(CAT, sub, {
        Type = ModConfigMenu.OptionType.NUMBER,
        CurrentSetting = function()
            return stateRef.config[attr]
        end,
        Minimum = s.min,
        Maximum = s.max,
        ModifyBy = s.step or 1,
        Display = function()
            local v = stateRef.config[attr]
            if names then
                return attr .. ": " .. (names[v] or tostring(v))
            end
            return attr .. ": " .. tostring(v) .. (s.suffix or "")
        end,
        OnChange = function(v) onChange(attr, v) end,
        Info = { s.info or "" },
    })
end

local function addScroll(sub, attr, default, info)
    ModConfigMenu.AddSetting(CAT, sub, {
        Type = ModConfigMenu.OptionType.SCROLL,
        CurrentSetting = function()
            -- scroll 0-10 共11档
            return stateRef.config[attr]
        end,
        Display = function()
            -- MCM 约定: SCROLL 的 Display 必须包含 "$scrollN" 标记(0-10)，
            -- 否则其滑块渲染 SetFrame 收到字符串 → 每帧报错
            local v = stateRef.config[attr]
            return attr .. ": $scroll" .. v .. " " .. string.rep("I", v)
        end,
        OnChange = function(v) onChange(attr, v) end,
        Info = { info },
    })
end

local function addKeybind(sub, attr, default, info)
    ModConfigMenu.AddSetting(CAT, sub, {
        Type = ModConfigMenu.OptionType.KEYBIND_KEYBOARD,
        CurrentSetting = function()
            return stateRef.config[attr]
        end,
        Display = function()
            local v = stateRef.config[attr]
            return attr .. ": " .. (KEY_NAMES[v] or tostring(v))
        end,
        OnChange = function(v) onChange(attr, v) end,
        Info = { info },
    })
end

local function addPercent(sub, attr, default, info)
    ModConfigMenu.AddSetting(CAT, sub, {
        Type = ModConfigMenu.OptionType.NUMBER,
        CurrentSetting = function()
            return math.floor((stateRef.config[attr] or 0.85) * 100 + 0.5)
        end,
        Minimum = 50,
        Maximum = 95,
        ModifyBy = 5,
        Display = function()
            return attr .. ": " .. math.floor((stateRef.config[attr] or 0.85) * 100 + 0.5) .. "%"
        end,
        OnChange = function(v) onChange(attr, v) end,
        Info = { info },
    })
end

--- 注册菜单（游戏启动时调用一次）
--- deps = { mod, state, presets }
function MCM.register(deps)
    mod = deps.mod
    stateRef = deps.state
    presetsRef = deps.presets

    if ModConfigMenu == nil then return end -- 未安装 MCM：静默降级

    ModConfigMenu.UpdateCategory(CAT, {
        Info = {
            "GhostStep3 — 叠加偏移式自动闪避",
            "危险时在输入方向上叠加偏移，不打断操作",
            "按 ALT 键开关",
        },
    })

    for i = 1, #SETTINGS do
        local s = SETTINGS[i]
        local sub, attr, typ, default = s[1], s[2], s[3], s[4]
        if typ == "bool" then
            addBoolean(sub, attr, default, s[5])
        elseif typ == "number" then
            addNumber(sub, attr, default, s)
        elseif typ == "scroll" then
            addScroll(sub, attr, default, s[5])
        elseif typ == "key" then
            addKeybind(sub, attr, default, s[5])
        elseif typ == "percent" then
            addPercent(sub, attr, default, s[5])
        end
    end

    -- 调试页: 只读运行时统计
    ModConfigMenu.AddSpace(CAT, "调试")
    ModConfigMenu.AddText(CAT, "调试", "── 运行时统计 (只读) ──")
    ModConfigMenu.AddText(CAT, "调试", function()
        return "帧耗时: " .. string.format("%.2fms", stateRef.profiler.lastFrameMs or 0)
    end)
    ModConfigMenu.AddText(CAT, "调试", function()
        return "威胁等级: " .. string.format("%.2f", stateRef.threat.level or 0)
    end)
    ModConfigMenu.AddText(CAT, "调试", function()
        return "决策层: " .. (stateRef.decision.layer or "无")
    end)
    ModConfigMenu.AddText(CAT, "调试", function()
        local t = stateRef.threat
        local parts = {}
        if (t.projectileCount or 0) > 0 then parts[#parts+1] = "弹幕" .. t.projectileCount end
        if (t.enemyCount or 0) > 0 then parts[#parts+1] = "敌" .. t.enemyCount end
        if (t.laserCount or 0) > 0 then parts[#parts+1] = "激光" .. t.laserCount end
        if (t.bombCount or 0) > 0 then parts[#parts+1] = "炸弹" .. t.bombCount end
        if (t.effectCount or 0) > 0 then parts[#parts+1] = "效果" .. t.effectCount end
        if (t.npcAttackCount or 0) > 0 then parts[#parts+1] = "前兆" .. t.npcAttackCount end
        return "威胁实体: " .. (t.hazardCount or 0) .. " (" .. (#parts > 0 and table.concat(parts, "/") or "无") .. ")"
    end)
    -- 录制状态（录制功能打开时可见缓冲进度）
    ModConfigMenu.AddText(CAT, "调试", function()
        if not stateRef.config.recordingEnabled then
            return "录制: 关闭"
        end
        local n = (stateRef.ringBuffer and stateRef.ringBuffer.count) or 0
        return "录制: 缓冲 " .. n .. " 帧 (约" .. math.floor(n / 30) .. "秒, 死亡时输出到日志)"
    end)
    -- 受击归因统计（按局累积，调参仪表盘：哪类失败多就调哪组参数）
    ModConfigMenu.AddText(CAT, "调试", function()
        local a = stateRef.hitAttribution
        if not a or a.total == 0 then return "受击归因: 本局无受击" end
        return string.format(
            "掉血诊断(%d次): 无命中预测%d 疑似受阻%d 待复核%d",
            a.total, a.undetected, a.blocked, a.unresolved or 0)
    end)
    -- 文件输出状态（--luadebug 说明）
    ModConfigMenu.AddText(CAT, "录制", function()
        local sr = stateRef.sessionRecorder
        if not sr then return "文件输出: 未初始化" end
        return sr:statusText()
    end)
    ModConfigMenu.AddText(CAT, "录制", function()
        local sr = stateRef.sessionRecorder
        if sr and sr.available then
            return "路径: " .. tostring(sr.filePath or (sr.dir .. "\\recordings\\"))
        end
        return "独立文件录制需要 --luadebug，未开启时仍可用内存录制+日志回放"
    end)
end

--- 退出前保存
function MCM.onPreGameExit()
    MCM.saveSettings()
end

return MCM
