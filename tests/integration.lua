-- 用真实回调参数顺序运行 main.lua，验证接线及 Alt 生命周期。
local callbacks={}
local mod={AddCallback=function(self,id,fn) callbacks[id]=fn end,HasData=function() return false end,
    SaveData=function() end,LoadData=function() return '{}' end}
RegisterMod=function() return mod end
ModConfigMenu=nil
ModCallbacks.MC_POST_GAME_STARTED=8;ModCallbacks.MC_POST_NEW_LEVEL=9
ModCallbacks.MC_POST_UPDATE=10;ModCallbacks.MC_EXECUTE_CMD=11
local position,velocity=Vector(160,160),Vector(0,0)
local player={Type=EntityType.ENTITY_PLAYER,ControllerIndex=0,CanFly=false,MoveSpeed=1,Size=10,
    ControlsEnabled=true,GetHearts=function() return 6 end,GetSoulHearts=function() return 0 end,
    GetDamageCooldown=function() return 0 end,IsDead=function() return false end,
    IsFlying=function() return false end,GetPlayerType=function() return 0 end}
setmetatable(player,{__index=function(_,k) if k=='Position' then return position elseif k=='Velocity' then return velocity end end})
Isaac.GetPlayer=function() return player end
local level={GetCurrentRoomIndex=function() return 1 end,GetStage=function() return 1 end}
local room={GetGridSize=function() return 135 end,GetGridWidth=function() return 15 end,
    GetGridEntity=function() return nil end,GetGridPosition=function(_,i) return Vector(i%15*40,math.floor(i/15)*40) end,
    IsClear=function() return false end,GetType=function() return 1 end}
Game=function() return {GetRoom=function() return room end,GetLevel=function() return level end,
    GetNumPlayers=function() return 1 end,GetSeeds=function() return {GetStartSeed=function() return 123 end} end} end
local left,toggle=0,false
Input.GetActionValue=function(action) return action==ButtonAction.ACTION_LEFT and left or 0 end
Input.IsButtonPressed=function() return toggle end
Input.IsButtonTriggered=function() return false end
local oldIO=io;io=nil -- 测试不向真实 recordings 目录写入。
local before=#SMOKE.logs
require('main')
io=oldIO
callbacks[8](mod,false);callbacks[ModCallbacks.MC_POST_NEW_ROOM](mod)
local st=mod.State; st.config.budgetMs=1000
SMOKE.entities={{Type=EntityType.ENTITY_PROJECTILE,Index=77,InitSeed=88,
    Position=Vector(225,160),Velocity=Vector(-5,0),Size=5,SpawnerType=0,
    IsDead=function() return false end}}
SMOKE.frameCount=1;callbacks[ModCallbacks.MC_POST_PLAYER_UPDATE](mod,player)
assert(st.logicTick==1 and st.player.valid and st.control.active,'main should activate predicted correction')
local command=st.control.direction
local value=callbacks[ModCallbacks.MC_INPUT_ACTION](mod,player,InputHook.GET_ACTION_VALUE,ButtonAction.ACTION_UP)
assert(type(value)=='number' and st.control.hookSeen)
left=1;toggle=true;SMOKE.frameCount=2
callbacks[ModCallbacks.MC_POST_PLAYER_UPDATE](mod,player)
assert(not st.userEnabled and not st.control.active and st.control.weight==0 and st.player.inputDir.X==-1)
assert(callbacks[ModCallbacks.MC_INPUT_ACTION](mod,player,InputHook.GET_ACTION_VALUE,ButtonAction.ACTION_LEFT)==nil)
callbacks[ModCallbacks.MC_POST_NEW_ROOM](mod)
toggle=false;SMOKE.frameCount=3;callbacks[ModCallbacks.MC_POST_PLAYER_UPDATE](mod,player)
assert(not st.userEnabled,'room transition must not re-enable protection')
toggle=true;left=0;SMOKE.frameCount=4
callbacks[ModCallbacks.MC_POST_PLAYER_UPDATE](mod,player)
assert(st.userEnabled,'Alt re-enables')
-- damage 的首参是 mod，真实实体是第二参；记录器替身接收事件。
local events={}
st.sessionRecorder.event=function(self,e) events[#events+1]=e end
callbacks[ModCallbacks.MC_ENTITY_TAKE_DMG](mod,player,1,0,{Type=10,Variant=2,Entity={Position=Vector(170,160)}})
local found=false
for _,e in ipairs(events) do if e.ev=='hit' or e.ev=='damage_attempt' then found=true;assert(e.dmg==1) end end
assert(found,'damage callback arguments must be correctly forwarded')
for i=before+1,#SMOKE.logs do
    assert(not SMOKE.logs[i]:find('失败',1,true) and not SMOKE.logs[i]:find('ERROR',1,true),SMOKE.logs[i])
end
assert(callbacks[ModCallbacks.MC_INPUT_ACTION](mod,player,InputHook.GET_ACTION_VALUE,ButtonAction.ACTION_SHOOTLEFT)==nil)
print('INTEGRATION: main callbacks, Alt transitions, raw input, damage source and shooting passed')
-- 提供给离线整帧 CPU 探针；实体不执行游戏 AI，不用于衡量避伤率。
function INTEGRATION_STEP(frame,entities)
    SMOKE.frameCount=frame;SMOKE.entities=entities
    callbacks[ModCallbacks.MC_POST_PLAYER_UPDATE](mod,player)
    return st.profiler.previous
end

-- 开局录制启动耗时必须与实际传感器计时隔离。
do
    local recorder=st.sessionRecorder
    local oldStart,oldAvailable=recorder.startSession,recorder.available
    local oldClock=Isaac.GetTime; local now=0
    Isaac.GetTime=function() return now end
    recorder.available=true
    recorder.startSession=function(self)
        now=now+1200
        self.file={write=function(self) return self end,flush=function() return true end,close=function() return true end}
        return true
    end
    local perf=INTEGRATION_STEP(100,{})
    recorder:closeFile()
    recorder.startSession,recorder.available=oldStart,oldAvailable
    Isaac.GetTime=oldClock
    assert(perf.lifecycleMs==1200 and perf.sensorsMs==0,'startup must not be attributed to sensors')
    local contextFound=false
    for _,e in ipairs(events) do
        if e.ev=='damage_context' then
            contextFound=true; assert(e.attemptId==1 and e.snapshot and e.phase=='last_decision_before_damage')
        end
    end
    assert(contextFound,'damage must retain its bounded decision context')
end
