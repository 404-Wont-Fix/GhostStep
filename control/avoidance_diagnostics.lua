-- 每次接管的有界累计，不保存逐帧数组。距离是观测轨迹，不声称由 mod 单独造成。
local D={}
function D.finish(state,recorder,reason)
    local e=state.avoidanceEpisode
    if not e then return end
    e.ev='avoidance_end';e.endReason=reason
    e.netDisplacement=math.sqrt((e.endX-e.startX)^2+(e.endY-e.startY)^2)
    recorder:event(e)
    state.avoidanceEpisode=nil
end
function D.update(state,frame,recorder)
    local e,f=state.avoidanceEpisode,state.feedback
    if e then
        if f and f.decisionId==e.lastDecisionId and f.dt==1 then
            e.pathDistance=e.pathDistance+f.progress
            e.observedSteps=e.observedSteps+1
            if f.hookSeen then e.hookSteps=e.hookSteps+1 end
            e.endX,e.endY=state.player.position.X,state.player.position.Y
            e.frame=frame
        else
            e.incomplete=true
            D.finish(state,recorder,'observation_gap');e=nil
        end
    end
    if not state.control.active then D.finish(state,recorder,state.decision.reason or 'released');return end
    if not e then
        state.avoidanceSequence=(state.avoidanceSequence or 0)+1
        local m=state.decision.metrics or {}
        e={episodeId=state.avoidanceSequence,startFrame=frame,frame=frame,room=state.currentRoomIndex,
            startX=state.player.position.X,startY=state.player.position.Y,
            endX=state.player.position.X,endY=state.player.position.Y,
            triggerId=m.triggerId,triggerKind=m.triggerKind,startReason=state.decision.reason,
            pathDistance=0,observedSteps=0,hookSteps=0,commands=0}
        state.avoidanceEpisode=e
        recorder:event({ev='avoidance_start',episodeId=e.episodeId,frame=frame,
            reason=e.startReason,triggerId=e.triggerId,triggerKind=e.triggerKind,
            x=e.startX,y=e.startY,cx=state.control.direction.X,cy=state.control.direction.Y})
    end
    e.commands=e.commands+1;e.lastDecisionId=state.logicTick
    e.lastCommandX,e.lastCommandY=state.control.direction.X,state.control.direction.Y
end
return D
