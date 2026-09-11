-- 卡住/局部无解时才运行的有界格子搜索。路点建议仍需通过预测控制的全路径检查。
local Escape={}
local Geometry=require("threat/geometry")
local DIR={{1,0},{-1,0},{0,1},{0,-1}}
function Escape.suggest(p,terrain,hazards,frame,limit,deadline,prepared)
    if not terrain.valid then return nil,0 end
    local start=terrain:cellAt(p.position)
    if not start then return nil,0 end
    local queue,seen={{index=start,pos=p.position,depth=0}},{[start]=true}
    local head,best,bestScore=1,nil,-math.huge
    while head<=#queue and head<=limit and Isaac.GetTime()<deadline do
        local node=queue[head]; head=head+1
        local x,y=(node.index-1)%terrain.sizeX,math.floor((node.index-1)/terrain.sizeX)
        for _,d in ipairs(DIR) do
            local nx,ny=x+d[1],y+d[2]
            local idx=ny*terrain.sizeX+nx+1
            if nx>=0 and ny>=0 and nx<terrain.sizeX and ny<terrain.sizeY and not seen[idx] then
                seen[idx]=true
                local pos=terrain:cellCenter(nx,ny)
                -- 只按硬地形连通性搜索（地刺现在是代价而不是墙），
                -- 否则地刺环/地刺带内部会被当成"无出口"。踩刺格降分但仍可达。
                if terrain:isSafeAt(pos,p.radius,false) and terrain:segmentSafe(node.pos,pos,p.radius,false) then
                    local first=node.first or pos
                    queue[#queue+1]={index=idx,pos=pos,first=first,depth=node.depth+1}
                    local t=math.min(24,(node.depth+1)*40/math.max(1,(p.moveSpeed or 1)*6))
                    local clearance=120
                    for i=1,#hazards do
                        if i%8==0 and Isaac.GetTime()>=deadline then
                            return best and (best-p.position):Normalized(),head-1
                        end
                        local e=hazards[i]
                        clearance=math.min(clearance,Geometry.clearance(e,pos.X,pos.Y,pos.X,pos.Y,p.radius,t,t,frame,prepared and prepared[i]))
                    end
                    local exits=0
                    for _,v in ipairs(DIR) do
                        if terrain:isSafeAt(pos+Vector(v[1]*24,v[2]*24),p.radius) then exits=exits+1 end
                    end
                    local intent=p.inputDir or Vector(0,0)
                    local delta=first-p.position
                    -- 踩刺格降分但仍可达。注意 dangerAt 是方法调用
                    local costCell=terrain:dangerAt(pos) and -12 or 0
                    local score=clearance+exits*3-node.depth*2+costCell+(delta:Normalized().X*intent.X+delta:Normalized().Y*intent.Y)*4
                    if score>bestScore then best,bestScore=first,score end
                end
            end
        end
    end
    return best and (best-p.position):Normalized(),head-1
end
return Escape
