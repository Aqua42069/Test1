-- RoadMapperClient
-- ROAD MAPPER V2 / fresh-map edition
-- F6 toggles the mapper.
--
-- Mapping workflow:
--   1. Pick Primary / Secondary / Local.
--   2. Set speed and lane offset.
--   3. START AUTO TRACE, then drive/walk the road CENTERLINE.
--   4. Finish at the end of the logical road segment.
--   5. At important intersections, stand at the center and MARK JUNCTION.
--
-- Auto tracing samples the developer's movement every few studs and saves
-- invisible route points. The visible neon overlay exists only on this client.

local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local UserInputService=game:GetService("UserInputService")
local RunService=game:GetService("RunService")

local player=Players.LocalPlayer
local mapper=ReplicatedStorage:WaitForChild("Events"):WaitForChild("RoadMapper")
local mapperQuery=ReplicatedStorage:WaitForChild("Functions"):WaitForChild("RoadMapperQuery")

local TYPE_COLOR={
	Primary=Color3.fromRGB(235,70,70),
	Secondary=Color3.fromRGB(235,205,70),
	Local=Color3.fromRGB(80,220,115),
}
local JUNCTION_COLOR={
	Auto=Color3.fromRGB(210,210,210),
	Signal=Color3.fromRGB(80,170,255),
	Stop=Color3.fromRGB(255,80,80),
	Yield=Color3.fromRGB(255,185,70),
	Uncontrolled=Color3.fromRGB(185,110,255),
}
local TYPE_DEFAULT_SPEED={Primary=32,Secondary=25,Local=18}
local TYPE_DEFAULT_LANE={Primary=3.75,Secondary=3.4,Local=3.05}
local TRACE_SPACING=8

local function make(className,props,parent)
	local obj=Instance.new(className)
	for k,v in pairs(props or {}) do obj[k]=v end
	obj.Parent=parent
	return obj
end

local function label(parent,text,props)
	local obj=make("TextLabel",{
		BackgroundTransparency=1,Text=text,TextColor3=Color3.new(1,1,1),
		Font=Enum.Font.SourceSansBold,TextScaled=true,
	},parent)
	for k,v in pairs(props or {}) do obj[k]=v end
	return obj
end

local function button(parent,text,color,props)
	local obj=make("TextButton",{
		Text=text,TextColor3=Color3.new(1,1,1),Font=Enum.Font.SourceSansBold,
		TextScaled=true,BackgroundColor3=color,BorderSizePixel=0,
	},parent)
	make("UICorner",{CornerRadius=UDim.new(0,6)},obj)
	for k,v in pairs(props or {}) do obj[k]=v end
	return obj
end

local function textBox(parent,placeholder,props)
	local obj=make("TextBox",{
		Text="",PlaceholderText=placeholder,TextColor3=Color3.new(1,1,1),
		PlaceholderColor3=Color3.fromRGB(145,145,155),Font=Enum.Font.SourceSans,
		TextSize=16,BackgroundColor3=Color3.fromRGB(32,34,42),BorderSizePixel=0,
		ClearTextOnFocus=false,
	},parent)
	make("UICorner",{CornerRadius=UDim.new(0,5)},obj)
	for k,v in pairs(props or {}) do obj[k]=v end
	return obj
end

local screen=Instance.new("ScreenGui")
screen.Name="RoadMapperV2Gui"
screen.ResetOnSpawn=false
screen.Enabled=false

local panel=make("Frame",{
	Position=UDim2.new(0.01,0,0.08,0),Size=UDim2.new(0.31,0,0.84,0),
	BackgroundColor3=Color3.fromRGB(18,20,26),BackgroundTransparency=0.05,BorderSizePixel=0,
},screen)
make("UICorner",{CornerRadius=UDim.new(0,9)},panel)

label(panel,"ROAD MAPPER V2 — FRESH MAP",{
	Position=UDim2.new(0.03,0,0.012,0),Size=UDim2.new(0.94,0,0.055,0),
	TextColor3=Color3.fromRGB(145,205,255),TextXAlignment=Enum.TextXAlignment.Left,
})
local status=label(panel,"Ready. Map road centerlines from scratch.",{
	Position=UDim2.new(0.03,0,0.068,0),Size=UDim2.new(0.94,0,0.052,0),
	Font=Enum.Font.SourceSans,TextSize=15,TextScaled=false,TextWrapped=true,
	TextXAlignment=Enum.TextXAlignment.Left,
})

local roadType="Primary"
local roadTypeBtn=button(panel,"TYPE: PRIMARY",TYPE_COLOR.Primary,{
	Position=UDim2.new(0.03,0,0.13,0),Size=UDim2.new(0.30,0,0.055,0)
})
local roadName=textBox(panel,"Optional road name",{
	Position=UDim2.new(0.35,0,0.13,0),Size=UDim2.new(0.62,0,0.055,0)
})

local speed=TYPE_DEFAULT_SPEED.Primary
local laneWidth=TYPE_DEFAULT_LANE.Primary
-- V2.1 lane model: trace direction defines FORWARD.  Cars may only use the
-- explicitly declared lanes in each direction.  0 lanes makes that direction illegal.
local forwardLanes=1
local reverseLanes=1
local medianWidth=0
local flyEnabled=false
local flySpeed=70
local flyConn=nil
local speedBtn=button(panel,"SPEED 32",Color3.fromRGB(58,82,120),{
	Position=UDim2.new(0.03,0,0.195,0),Size=UDim2.new(0.30,0,0.052,0)
})
local laneBtn=button(panel,"LANE 3.75",Color3.fromRGB(58,82,120),{
	Position=UDim2.new(0.35,0,0.195,0),Size=UDim2.new(0.30,0,0.052,0)
})
local manualBtn=button(panel,"ADD POINT",Color3.fromRGB(75,100,135),{
	Position=UDim2.new(0.67,0,0.195,0),Size=UDim2.new(0.30,0,0.052,0)
})

local traceBtn=button(panel,"START AUTO TRACE",Color3.fromRGB(45,150,85),{
	Position=UDim2.new(0.03,0,0.26,0),Size=UDim2.new(0.46,0,0.065,0)
})
local finishBtn=button(panel,"FINISH ROAD",Color3.fromRGB(45,115,185),{
	Position=UDim2.new(0.51,0,0.26,0),Size=UDim2.new(0.46,0,0.065,0)
})
local undoBtn=button(panel,"UNDO LAST POINT",Color3.fromRGB(85,85,95),{
	Position=UDim2.new(0.03,0,0.335,0),Size=UDim2.new(0.46,0,0.052,0)
})
local cancelBtn=button(panel,"CANCEL ROAD",Color3.fromRGB(145,55,55),{
	Position=UDim2.new(0.51,0,0.335,0),Size=UDim2.new(0.46,0,0.052,0)
})

label(panel,"INTERSECTIONS",{
	Position=UDim2.new(0.03,0,0.405,0),Size=UDim2.new(0.94,0,0.035,0),
	TextColor3=Color3.fromRGB(225,225,235),TextXAlignment=Enum.TextXAlignment.Left,
})
local junctionModes={"Auto","Signal","Stop","Yield","Uncontrolled"}
local junctionIndex=1
local junctionBtn=button(panel,"CONTROL: AUTO",JUNCTION_COLOR.Auto,{
	Position=UDim2.new(0.03,0,0.448,0),Size=UDim2.new(0.45,0,0.055,0)
})
local markJunctionBtn=button(panel,"MARK JUNCTION HERE",Color3.fromRGB(105,75,165),{
	Position=UDim2.new(0.51,0,0.448,0),Size=UDim2.new(0.46,0,0.055,0)
})

local exportBtn=button(panel,"EXPORT ROAD SNAPSHOT",Color3.fromRGB(55,105,145),{
	Position=UDim2.new(0.03,0,0.515,0),Size=UDim2.new(0.46,0,0.052,0)
})
local clearJunctionBtn=button(panel,"CLEAR JUNCTIONS",Color3.fromRGB(105,75,105),{
	Position=UDim2.new(0.51,0,0.515,0),Size=UDim2.new(0.46,0,0.052,0)
})
local resetBtn=button(panel,"RESET ALL ROADS",Color3.fromRGB(150,45,45),{
	Position=UDim2.new(0.03,0,0.578,0),Size=UDim2.new(0.94,0,0.052,0)
})


-- V2.1 explicit lane + mapper flight controls.
local fwdLaneBtn=button(panel,"FWD LANES: 1",Color3.fromRGB(45,125,165),{
	Position=UDim2.new(0.03,0,0.642,0),Size=UDim2.new(0.30,0,0.048,0)
})
local revLaneBtn=button(panel,"REV LANES: 1",Color3.fromRGB(45,125,165),{
	Position=UDim2.new(0.35,0,0.642,0),Size=UDim2.new(0.30,0,0.048,0)
})
local medianBtn=button(panel,"MEDIAN: 0",Color3.fromRGB(70,95,125),{
	Position=UDim2.new(0.67,0,0.642,0),Size=UDim2.new(0.30,0,0.048,0)
})
local flyBtn=button(panel,"FLY: OFF",Color3.fromRGB(80,80,95),{
	Position=UDim2.new(0.03,0,0.697,0),Size=UDim2.new(0.46,0,0.048,0)
})
local flySpeedBtn=button(panel,"FLY SPEED: 70",Color3.fromRGB(70,95,125),{
	Position=UDim2.new(0.51,0,0.697,0),Size=UDim2.new(0.46,0,0.048,0)
})

label(panel,"Map one logical street/segment at a time. Cross centerlines cleanly at intersections. T-junction endpoints auto-snap.",{
	Position=UDim2.new(0.03,0,0.750,0),Size=UDim2.new(0.94,0,0.045,0),
	Font=Enum.Font.SourceSans,TextSize=14,TextScaled=false,TextWrapped=true,
	TextColor3=Color3.fromRGB(200,205,215),TextXAlignment=Enum.TextXAlignment.Left,
})

label(panel,"MAPPED ROADS",{
	Position=UDim2.new(0.03,0,0.798,0),Size=UDim2.new(0.94,0,0.03,0),
	TextXAlignment=Enum.TextXAlignment.Left,
})
local roadList=make("ScrollingFrame",{
	Position=UDim2.new(0.03,0,0.832,0),Size=UDim2.new(0.94,0,0.155,0),
	BackgroundColor3=Color3.fromRGB(10,11,15),BorderSizePixel=0,
	ScrollBarThickness=5,CanvasSize=UDim2.new(0,0,0,0),
},panel)

-- Visual overlay
local overlay=Instance.new("Folder")
overlay.Name="RoadMapperV2Overlay"
local currentOverlay=Instance.new("Folder")
currentOverlay.Name="RoadMapperV2Current"

local function marker(pos,color,parent,size)
	local p=Instance.new("Part")
	p.Shape=Enum.PartType.Ball
	p.Size=Vector3.new(size or 1.25,size or 1.25,size or 1.25)
	p.Anchored=true;p.CanCollide=false;p.CanQuery=false;p.CanTouch=false
	p.Material=Enum.Material.Neon;p.Color=color;p.CFrame=CFrame.new(pos);p.Parent=parent
	return p
end
local function line(a,b,color,parent,width)
	local delta=b-a
	if delta.Magnitude<0.05 then return end
	local p=Instance.new("Part")
	p.Size=Vector3.new(width or 0.24,width or 0.24,delta.Magnitude)
	p.Anchored=true;p.CanCollide=false;p.CanQuery=false;p.CanTouch=false
	p.Material=Enum.Material.Neon;p.Color=color
	p.CFrame=CFrame.lookAt((a+b)/2,b)
	p.Parent=parent
end
local function drawRoad(nodes,color,parent)
	for i,pos in ipairs(nodes or {}) do
		marker(pos,color,parent,i==1 and 1.65 or 1.05)
		if i>1 then line(nodes[i-1],pos,color,parent,0.22) end
	end
end

local currentName=nil
local currentNodes={}
local tracing=false
local lastTracePos=nil

local function redrawCurrent()
	currentOverlay:ClearAllChildren()
	drawRoad(currentNodes,TYPE_COLOR[roadType] or Color3.new(1,1,1),currentOverlay)
end

local function refresh()
	overlay:ClearAllChildren()
	roadList:ClearAllChildren()
	local data=mapperQuery:InvokeServer("ListV2")
	if not data then return end

	local roads=data.roads or {}
	local junctions=data.junctions or {}
	local y=0
	for _,r in ipairs(roads) do
		drawRoad(r.nodes,TYPE_COLOR[r.roadType] or Color3.new(1,1,1),overlay)
		local row=make("Frame",{
			Position=UDim2.new(0,0,0,y),Size=UDim2.new(1,-4,0,34),
			BackgroundTransparency=1,
		},roadList)
		label(row,("%s [%s] %dpt  %d | F%d/R%d"):format(r.name,r.roadType,#r.nodes,r.speedLimit or 0,r.forwardLanes or 1,r.reverseLanes or 1),{
			Position=UDim2.new(0.01,0,0,0),Size=UDim2.new(0.76,0,1,0),
			Font=Enum.Font.SourceSans,TextSize=14,TextScaled=false,
			TextXAlignment=Enum.TextXAlignment.Left,
			TextColor3=TYPE_COLOR[r.roadType] or Color3.new(1,1,1),
		})
		local del=button(row,"X",Color3.fromRGB(135,45,45),{
			Position=UDim2.new(0.82,0,0.08,0),Size=UDim2.new(0.16,0,0.84,0)
		})
		del.Activated:Connect(function() mapper:FireServer("DeleteRoadV2",r.name) end)
		y+=34
	end
	for _,j in ipairs(junctions) do
		marker(j.position,JUNCTION_COLOR[j.control] or JUNCTION_COLOR.Auto,overlay,2.0)
	end
	roadList.CanvasSize=UDim2.new(0,0,0,math.max(y,1))
end

local typeOrder={"Primary","Secondary","Local"}
local function cycleType()
	local i=table.find(typeOrder,roadType) or 1
	roadType=typeOrder[i%#typeOrder+1]
	speed=TYPE_DEFAULT_SPEED[roadType]
	laneWidth=TYPE_DEFAULT_LANE[roadType]
	roadTypeBtn.Text="TYPE: "..string.upper(roadType)
	roadTypeBtn.BackgroundColor3=TYPE_COLOR[roadType]
	speedBtn.Text="SPEED "..tostring(speed)
	laneBtn.Text=("LANE %.2f"):format(laneWidth)
end
roadTypeBtn.Activated:Connect(cycleType)

speedBtn.Activated:Connect(function()
	local values={15,18,22,25,28,32,36,40}
	local current=table.find(values,speed) or 1
	speed=values[current%#values+1]
	speedBtn.Text="SPEED "..tostring(speed)
end)

laneBtn.Activated:Connect(function()
	local values={2.75,3.05,3.25,3.4,3.75,4.1,4.5}
	local best=1
	for i,v in ipairs(values) do if math.abs(v-laneWidth)<math.abs(values[best]-laneWidth) then best=i end end
	laneWidth=values[best%#values+1]
	laneBtn.Text=("LANE %.2f"):format(laneWidth)
end)

fwdLaneBtn.Activated:Connect(function()
	forwardLanes=(forwardLanes+1)%5
	fwdLaneBtn.Text="FWD LANES: "..forwardLanes
end)
revLaneBtn.Activated:Connect(function()
	reverseLanes=(reverseLanes+1)%5
	revLaneBtn.Text="REV LANES: "..reverseLanes
end)
medianBtn.Activated:Connect(function()
	local vals={0,2,4,6,8,12,16}
	local idx=table.find(vals,medianWidth) or 1
	medianWidth=vals[idx%#vals+1]
	medianBtn.Text="MEDIAN: "..medianWidth
end)
flySpeedBtn.Activated:Connect(function()
	local vals={35,55,70,100,150,220}
	local idx=table.find(vals,flySpeed) or 1
	flySpeed=vals[idx%#vals+1]
	flySpeedBtn.Text="FLY SPEED: "..flySpeed
end)

local function setFly(on)
	flyEnabled=on
	flyBtn.Text=on and "FLY: ON" or "FLY: OFF"
	flyBtn.BackgroundColor3=on and Color3.fromRGB(45,150,85) or Color3.fromRGB(80,80,95)
	local char=player.Character
	local root=char and char:FindFirstChild("HumanoidRootPart")
	local hum=char and char:FindFirstChildOfClass("Humanoid")
	if not root then return end
	if flyConn then flyConn:Disconnect();flyConn=nil end
	if not on then
		root.Anchored=false
		if hum then hum.AutoRotate=true end
		return
	end
	root.Anchored=true
	if hum then hum.AutoRotate=false end
	flyConn=RunService.RenderStepped:Connect(function(dt)
		if not flyEnabled or not root.Parent then return end
		local cam=workspace.CurrentCamera
		if not cam then return end
		local move=Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then move+=cam.CFrame.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then move-=cam.CFrame.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then move+=cam.CFrame.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then move-=cam.CFrame.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move+=Vector3.yAxis end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.C) then move-=Vector3.yAxis end
		local mult=UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and 2 or 1
		if move.Magnitude>0 then
			root.CFrame=root.CFrame+move.Unit*flySpeed*mult*dt
		end
	end)
end
flyBtn.Activated:Connect(function() setFly(not flyEnabled) end)

junctionBtn.Activated:Connect(function()
	junctionIndex=junctionIndex%#junctionModes+1
	local mode=junctionModes[junctionIndex]
	junctionBtn.Text="CONTROL: "..string.upper(mode)
	junctionBtn.BackgroundColor3=JUNCTION_COLOR[mode]
end)

local function playerPosition()
	local char=player.Character
	local root=char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function startTrace()
	if currentName then
		tracing=not tracing
		traceBtn.Text=tracing and "PAUSE AUTO TRACE" or "RESUME AUTO TRACE"
		traceBtn.BackgroundColor3=tracing and Color3.fromRGB(185,120,45) or Color3.fromRGB(45,150,85)
		return
	end
	mapper:FireServer("NewRoadV2",{
		roadType=roadType,
		name=roadName.Text,
		speedLimit=speed,
		laneWidth=laneWidth,
		forwardLanes=forwardLanes,
		reverseLanes=reverseLanes,
		medianWidth=medianWidth,
	})
end
traceBtn.Activated:Connect(startTrace)

manualBtn.Activated:Connect(function()
	local pos=playerPosition()
	if not currentName then
		mapper:FireServer("NewRoadV2",{
			roadType=roadType,name=roadName.Text,speedLimit=speed,laneWidth=laneWidth,
			forwardLanes=forwardLanes,reverseLanes=reverseLanes,medianWidth=medianWidth,
		})
		task.wait(0.08)
	end
	if pos then mapper:FireServer("AddNodeV2",pos) end
end)

finishBtn.Activated:Connect(function()
	if currentName then
		local pos=playerPosition()
		if pos and (not lastTracePos or (pos-lastTracePos).Magnitude>2) then
			mapper:FireServer("AddNodeV2",pos)
		end
		mapper:FireServer("FinishRoadV2")
	end
end)
undoBtn.Activated:Connect(function() mapper:FireServer("UndoNodeV2") end)
cancelBtn.Activated:Connect(function() mapper:FireServer("CancelRoadV2") end)

markJunctionBtn.Activated:Connect(function()
	local pos=playerPosition()
	if pos then
		mapper:FireServer("AddJunctionV2",{
			position=pos,
			control=junctionModes[junctionIndex],
		})
	end
end)

exportBtn.Activated:Connect(function()
	mapper:FireServer("ExportRoadsV2")
	status.Text="Snapshot printed to Studio Output. Send me the ROADMAP_V2 block."
end)

clearJunctionBtn.Activated:Connect(function()
	mapper:FireServer("ClearJunctionsV2")
end)

local resetArmedUntil=0
resetBtn.Activated:Connect(function()
	if os.clock()>resetArmedUntil then
		resetArmedUntil=os.clock()+4
		resetBtn.Text="CLICK AGAIN TO CONFIRM RESET"
		status.Text="Reset armed for 4 seconds."
		return
	end
	mapper:FireServer("ResetRoadsV2")
	resetArmedUntil=0
	resetBtn.Text="RESET ALL ROADS"
end)

RunService.Heartbeat:Connect(function()
	if not tracing or not currentName then return end
	local pos=playerPosition()
	if not pos then return end
	if not lastTracePos or (pos-lastTracePos).Magnitude>=TRACE_SPACING then
		lastTracePos=pos
		mapper:FireServer("AddNodeV2",pos)
	end
end)

-- Footstep route recorder retained for the Prison Mapper.
local escortRecording=false
local escortLastPos=nil
local ESCORT_SPACING=2.5
local function setEscortRecording(on)
	escortRecording=on
	escortLastPos=nil
	mapper:FireServer(on and "NewEscort" or "FinishEscort")
end
RunService.Heartbeat:Connect(function()
	if not escortRecording then return end
	local pos=playerPosition()
	if pos and (not escortLastPos or (pos-escortLastPos).Magnitude>=ESCORT_SPACING) then
		escortLastPos=pos
		mapper:FireServer("AddEscortNode",pos)
	end
end)

UserInputService.InputBegan:Connect(function(input,processed)
	if processed then return end
	if input.KeyCode==Enum.KeyCode.F6 then
		screen.Enabled=not screen.Enabled
		if screen.Enabled then refresh() elseif flyEnabled then setFly(false) end
	elseif screen.Enabled and input.KeyCode==Enum.KeyCode.N then
		local pos=playerPosition()
		if pos then mapper:FireServer("AddNodeV2",pos) end
	elseif screen.Enabled and input.KeyCode==Enum.KeyCode.Backspace then
		mapper:FireServer("UndoNodeV2")
	elseif screen.Enabled and input.KeyCode==Enum.KeyCode.Return then
		mapper:FireServer("FinishRoadV2")
	end
end)

mapper.OnClientEvent:Connect(function(action,a,b,c,d)
	if action=="Enable" then
		if not screen.Parent then screen.Parent=player:WaitForChild("PlayerGui") end
		if not overlay.Parent then overlay.Parent=workspace end
		if not currentOverlay.Parent then currentOverlay.Parent=workspace end
	elseif action=="RoadSessionV2" then
		currentName=a
		roadType=b
		currentNodes={}
		tracing=true
		lastTracePos=nil
		traceBtn.Text="PAUSE AUTO TRACE"
		traceBtn.BackgroundColor3=Color3.fromRGB(185,120,45)
		status.Text=("Tracing %s [%s] — drive/walk centerline"):format(tostring(a),tostring(b))
		local pos=playerPosition()
		if pos then mapper:FireServer("AddNodeV2",pos) end
	elseif action=="RoadNodeV2" then
		if a==currentName and typeof(c)=="Vector3" then
			table.insert(currentNodes,c)
			lastTracePos=c
			status.Text=("%s — %d points"):format(currentName,#currentNodes)
			redrawCurrent()
		end
	elseif action=="RoadUndoV2" then
		if a==currentName and #currentNodes>0 then
			table.remove(currentNodes)
			lastTracePos=currentNodes[#currentNodes]
			redrawCurrent()
		end
	elseif action=="RoadFinishedV2" then
		status.Text=("Saved %s — %d points%s"):format(tostring(a),tonumber(b) or 0,c and " (endpoint snapped)" or "")
		currentName=nil;currentNodes={};tracing=false;lastTracePos=nil
		traceBtn.Text="START AUTO TRACE";traceBtn.BackgroundColor3=Color3.fromRGB(45,150,85)
		roadName.Text=""
		redrawCurrent();refresh()
	elseif action=="RoadCancelledV2" then
		status.Text="Road cancelled."
		currentName=nil;currentNodes={};tracing=false;lastTracePos=nil
		traceBtn.Text="START AUTO TRACE";traceBtn.BackgroundColor3=Color3.fromRGB(45,150,85)
		redrawCurrent();refresh()
	elseif action=="RoadChangedV2" or action=="JunctionChangedV2" then
		refresh()
	elseif action=="RoadResetV2" then
		status.Text="Fresh road network: EMPTY."
		currentName=nil;currentNodes={};tracing=false;lastTracePos=nil
		traceBtn.Text="START AUTO TRACE";resetBtn.Text="RESET ALL ROADS"
		redrawCurrent();refresh()
	elseif action=="EscortSession" or action=="EscortStart" then
		escortRecording=true
	elseif action=="EscortFinished" or action=="EscortDiscarded" or action=="EscortCancelled" then
		escortRecording=false
		escortLastPos=nil
	end
end)


---------------------------------------------------------------------------
-- PRISON MAPPER - simplified task-based mapper
-- P/F7 opens it. The tool is organized around jobs instead of abstract modes:
-- Area, Cell, Door, Marker, and Walk Path.
---------------------------------------------------------------------------
local mouse = player:GetMouse()
local prisonGui = Instance.new("ScreenGui")
prisonGui.Name = "PrisonMapperGui"
prisonGui.ResetOnSpawn = false
prisonGui.Enabled = true
prisonGui.Parent = player:WaitForChild("PlayerGui")

local prisonToggle = button(prisonGui, "PRISON MAP [P]", Color3.fromRGB(50,125,190), {
    AnchorPoint=Vector2.new(1,0), Position=UDim2.new(0.99,0,0.055,0), Size=UDim2.new(0.19,0,0.048,0)
})

local prisonPanel = make("Frame", {
    AnchorPoint = Vector2.new(1,0), Position = UDim2.new(0.99,0,0.11,0), Size = UDim2.new(0.36,0,0.82,0),
    BackgroundColor3 = Color3.fromRGB(18,20,25), BackgroundTransparency = 0.05, BorderSizePixel = 0,
}, prisonGui)
prisonPanel.Visible = false
make("UICorner", {CornerRadius=UDim.new(0,8)}, prisonPanel)

label(prisonPanel, "PRISON MAPPER", {Position=UDim2.new(0.04,0,0.012,0), Size=UDim2.new(0.92,0,0.045,0), TextColor3=Color3.fromRGB(130,205,255), TextXAlignment=Enum.TextXAlignment.Left})
local prisonStatus = label(prisonPanel, "Choose what you want to add.", {Position=UDim2.new(0.04,0,0.057,0), Size=UDim2.new(0.92,0,0.065,0), Font=Enum.Font.SourceSans, TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left, TextColor3=Color3.fromRGB(225,230,240)})

local taskHelp = label(prisonPanel, "", {Position=UDim2.new(0.04,0,0.123,0), Size=UDim2.new(0.92,0,0.075,0), Font=Enum.Font.SourceSans, TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top, TextColor3=Color3.fromRGB(180,190,205)})

local taskRow1 = make("Frame", {Position=UDim2.new(0.04,0,0.205,0), Size=UDim2.new(0.92,0,0.055,0), BackgroundTransparency=1}, prisonPanel)
local taskRow2 = make("Frame", {Position=UDim2.new(0.04,0,0.265,0), Size=UDim2.new(0.92,0,0.055,0), BackgroundTransparency=1}, prisonPanel)
local taskButtons={}
local function taskButton(parent,text,x,w)
    local b=button(parent,text,Color3.fromRGB(62,67,78),{Position=UDim2.new(x,0,0,0),Size=UDim2.new(w,0,1,0)})
    taskButtons[text]=b
    return b
end
taskButton(taskRow1,"AREA",0,0.32)
taskButton(taskRow1,"CELL",0.34,0.32)
taskButton(taskRow1,"DOOR",0.68,0.32)
taskButton(taskRow2,"MARKER",0,0.49)
taskButton(taskRow2,"WALK PATH",0.51,0.49)

local nameLabel = label(prisonPanel, "Name (optional)", {Position=UDim2.new(0.04,0,0.33,0), Size=UDim2.new(0.92,0,0.035,0), Font=Enum.Font.SourceSans, TextXAlignment=Enum.TextXAlignment.Left})
local nameBox = make("TextBox", {Position=UDim2.new(0.04,0,0.365,0), Size=UDim2.new(0.92,0,0.052,0), BackgroundColor3=Color3.fromRGB(36,39,48), TextColor3=Color3.new(1,1,1), PlaceholderText="Example: Intake_A / Cell_L1_01 / WestExit", Text="", Font=Enum.Font.SourceSans, TextScaled=true, ClearTextOnFocus=false, BorderSizePixel=0}, prisonPanel)
make("UICorner", {CornerRadius=UDim.new(0,5)}, nameBox)

local areaTypes={"IntakeArea","BookingArea","ClassificationArea","ProtectiveCustody","Medical","LowSecurity","MediumSecurity","HighSecurity","MaximumSecurity","Supermax","Solitary","DeathRow","StaffOnly","ControlRoom","Yard","Visitation","Chow","WalkableCorridor"}
local cellTypes={"IntakeCell","BookingCell","ProtectiveCustody","Medical","LowSecurity","MediumSecurity","HighSecurity","MaximumSecurity","Supermax","Solitary","DeathRow"}
local markerTypes={"BookingDesk","BookingOfficerPost","ClassificationPoint","ClassificationOfficerPost","HousingOfficerPost","OfficerPost","IntakeOfficerPost","PoliceHandoff","Handoff","IntakeVehicleStop","MedicalDesk","YardEntry","DoorInside","DoorOutside","Checkpoint","FloorConnector","StairConnector","ElevatorConnector","ControlPoint"}
local doorTypes={"Normal","CellDoor","StaffOnly","SallyPort","VehicleGate","IntakeEntrance","Exit","EmergencyExit","HighSecurity","Supermax","Medical"}
local securityTypes={"General","Low","Medium","High","Supermax","DeathRow"}
local accessTypes={"Everyone","PrisonStaff","PoliceAndPrisonStaff","MedicalStaff","CommandOnly","EmergencyOnly"}
local directionTypes={"BothWays","ExitOnly","EntryOnly"}

local prisonTask="AREA"
local typeIndex,securityIndex,accessIndex,directionIndex=1,1,1,1
local typeBtn=button(prisonPanel,"Area type: Intake",Color3.fromRGB(55,90,130),{Position=UDim2.new(0.04,0,0.43,0),Size=UDim2.new(0.92,0,0.055,0)})
local securityBtn=button(prisonPanel,"Security: General",Color3.fromRGB(95,75,125),{Position=UDim2.new(0.04,0,0.49,0),Size=UDim2.new(0.92,0,0.05,0)})
local accessBtn=button(prisonPanel,"Who can open: Everyone",Color3.fromRGB(95,75,125),{Position=UDim2.new(0.04,0,0.545,0),Size=UDim2.new(0.92,0,0.05,0)})
local directionBtn=button(prisonPanel,"Direction: Both ways",Color3.fromRGB(95,75,125),{Position=UDim2.new(0.04,0,0.60,0),Size=UDim2.new(0.92,0,0.05,0)})

local captureA=button(prisonPanel,"1. SET FIRST CORNER",Color3.fromRGB(85,100,165),{Position=UDim2.new(0.04,0,0.66,0),Size=UDim2.new(0.44,0,0.055,0)})
local captureB=button(prisonPanel,"2. SET OPPOSITE CORNER",Color3.fromRGB(85,100,165),{Position=UDim2.new(0.52,0,0.66,0),Size=UDim2.new(0.44,0,0.055,0)})
local capturePos=button(prisonPanel,"SET LOCATION",Color3.fromRGB(85,100,165),{Position=UDim2.new(0.04,0,0.72,0),Size=UDim2.new(0.92,0,0.055,0)})
local captureDoor=button(prisonPanel,"SELECT DOOR / GATE",Color3.fromRGB(115,85,155),{Position=UDim2.new(0.04,0,0.78,0),Size=UDim2.new(0.92,0,0.055,0)})
local pathBtn=button(prisonPanel,"START WALK RECORDING",Color3.fromRGB(145,70,185),{Position=UDim2.new(0.04,0,0.72,0),Size=UDim2.new(0.92,0,0.115,0)})
local savePrison=button(prisonPanel,"SAVE",Color3.fromRGB(50,155,85),{Position=UDim2.new(0.04,0,0.845,0),Size=UDim2.new(0.66,0,0.065,0)})
local clearPrison=button(prisonPanel,"CLEAR",Color3.fromRGB(145,55,55),{Position=UDim2.new(0.72,0,0.845,0),Size=UDim2.new(0.24,0,0.065,0)})
local selectionLabel=label(prisonPanel,"Nothing selected yet.",{Position=UDim2.new(0.04,0,0.915,0),Size=UDim2.new(0.92,0,0.07,0),Font=Enum.Font.SourceSans,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,TextColor3=Color3.fromRGB(190,215,190)})

local selection={a=nil,b=nil,position=nil,door=nil}
local captureKind=nil
local prisonOverlay=Instance.new("Folder")
prisonOverlay.Name="PrisonMapperOverlay"
prisonOverlay.Parent=workspace

-- v140: hide ONLY temporary mapper visualization. Keep the overlay parented so
-- normal place instances/assets are never reparented or altered.
local mapperOverlayVisible=false
local function applyMapperOverlayVisibility(inst)
    if inst:IsA("BasePart") then
        inst.LocalTransparencyModifier=mapperOverlayVisible and 0 or 1
    elseif inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
        inst.Enabled=mapperOverlayVisible
    end
end
local function setMapperOverlayVisible(visible)
    mapperOverlayVisible=visible
    for _,inst in ipairs(prisonOverlay:GetDescendants()) do applyMapperOverlayVisibility(inst) end
end
prisonOverlay.DescendantAdded:Connect(function(inst)
    task.defer(function() if inst.Parent then applyMapperOverlayVisibility(inst) end end)
end)

local function cycle(list,index)
    index=index%#list+1
    return index,list[index]
end
local function pretty(s)
    return tostring(s):gsub("([a-z])([A-Z])","%1 %2")
end
local function currentType()
    if prisonTask=="AREA" then return areaTypes[typeIndex]
    elseif prisonTask=="CELL" then return cellTypes[typeIndex]
    elseif prisonTask=="MARKER" then return markerTypes[typeIndex]
    elseif prisonTask=="DOOR" then return doorTypes[typeIndex] end
    return "WalkPath"
end
local function selText(v)
    if not v then return "not set" end
    if typeof(v)=="Vector3" then return ("%.1f, %.1f, %.1f"):format(v.X,v.Y,v.Z) end
    if typeof(v)=="Instance" then return v:GetFullName() end
    return tostring(v)
end
local function updateSelectionText()
    if prisonTask=="AREA" then
        selectionLabel.Text="Corner 1: "..selText(selection.a).."\nCorner 2: "..selText(selection.b)
    elseif prisonTask=="CELL" then
        selectionLabel.Text="Cell position: "..selText(selection.position).."\nDoor: "..selText(selection.door)
    elseif prisonTask=="DOOR" then
        selectionLabel.Text="Selected door/gate: "..selText(selection.door)
    elseif prisonTask=="MARKER" then
        selectionLabel.Text="Marker position: "..selText(selection.position)
    else
        selectionLabel.Text=escortRecording and "Recording your footsteps now..." or "Walk recording is stopped."
    end
end
local function clearSelection()
    selection={a=nil,b=nil,position=nil,door=nil}
    captureKind=nil
    updateSelectionText()
end
local function beginCapture(kind)
    captureKind=kind
    if kind=="door" then
        prisonStatus.Text="Now click the physical door or gate in the world."
    else
        prisonStatus.Text="Now click the exact location in the 3D world."
    end
end
local function updateTaskUI()
    for name,b in pairs(taskButtons) do b.BackgroundColor3=(name==prisonTask) and Color3.fromRGB(50,125,190) or Color3.fromRGB(62,67,78) end
    typeIndex=1
    securityIndex=1
    accessIndex=1
    directionIndex=1
    securityBtn.Visible=(prisonTask=="DOOR")
    accessBtn.Visible=(prisonTask=="DOOR")
    directionBtn.Visible=(prisonTask=="DOOR")
    captureA.Visible=(prisonTask=="AREA")
    captureB.Visible=(prisonTask=="AREA")
    capturePos.Visible=(prisonTask=="CELL" or prisonTask=="MARKER")
    captureDoor.Visible=(prisonTask=="CELL" or prisonTask=="DOOR")
    pathBtn.Visible=(prisonTask=="WALK PATH")
    savePrison.Visible=(prisonTask~="WALK PATH")
    clearPrison.Visible=(prisonTask~="WALK PATH")
    nameLabel.Visible=(prisonTask~="WALK PATH")
    nameBox.Visible=(prisonTask~="WALK PATH")
    typeBtn.Visible=(prisonTask~="WALK PATH")
    if prisonTask=="AREA" then
        typeBtn.Text="Area type: "..pretty(areaTypes[1])
        taskHelp.Text="AREA: outline a whole room/block. Click First Corner, click in the world, then Opposite Corner and click again."
    elseif prisonTask=="CELL" then
        typeBtn.Text="Cell type: "..pretty(cellTypes[1])
        taskHelp.Text="CELL: set the exact spot where the inmate should stand, then optionally select that cell's physical door."
    elseif prisonTask=="DOOR" then
        typeBtn.Text="Door type: "..pretty(doorTypes[1])
        securityBtn.Text="Security: "..securityTypes[1]
        accessBtn.Text="Who can open: "..pretty(accessTypes[1])
        directionBtn.Text="Direction: Both ways"
        taskHelp.Text="DOOR: independent of room type. Select any door/gate, then classify its purpose, security, access, and travel direction."
    elseif prisonTask=="MARKER" then
        typeBtn.Text="Marker type: "..pretty(markerTypes[1])
        taskHelp.Text="MARKER: place important AI destinations such as Booking Desk, Officer Post, Handoff, stairs, or control points."
    elseif prisonTask=="WALK PATH" then
        taskHelp.Text="WALK PATH: press Start, physically walk the hallway route, then press Stop. The route prints to Output for permanent baking."
        pathBtn.Text=escortRecording and "STOP & SAVE WALK ROUTE" or "START WALK RECORDING"
    end
    clearSelection()
end

for name,b in pairs(taskButtons) do
    b.MouseButton1Click:Connect(function() prisonTask=name; updateTaskUI() end)
end

typeBtn.MouseButton1Click:Connect(function()
    local list=(prisonTask=="AREA" and areaTypes) or (prisonTask=="CELL" and cellTypes) or (prisonTask=="MARKER" and markerTypes) or doorTypes
    typeIndex=typeIndex%#list+1
    local prefix=(prisonTask=="AREA" and "Area type: ") or (prisonTask=="CELL" and "Cell type: ") or (prisonTask=="MARKER" and "Marker type: ") or "Door type: "
    typeBtn.Text=prefix..pretty(list[typeIndex])
end)
securityBtn.MouseButton1Click:Connect(function() securityIndex=securityIndex%#securityTypes+1; securityBtn.Text="Security: "..securityTypes[securityIndex] end)
accessBtn.MouseButton1Click:Connect(function() accessIndex=accessIndex%#accessTypes+1; accessBtn.Text="Who can open: "..pretty(accessTypes[accessIndex]) end)
directionBtn.MouseButton1Click:Connect(function()
    directionIndex=directionIndex%#directionTypes+1
    local d=directionTypes[directionIndex]
    directionBtn.Text="Direction: "..(d=="BothWays" and "Both ways" or pretty(d))
end)

captureA.MouseButton1Click:Connect(function() beginCapture("corner A") end)
captureB.MouseButton1Click:Connect(function() beginCapture("corner B") end)
capturePos.MouseButton1Click:Connect(function() beginCapture("position") end)
captureDoor.MouseButton1Click:Connect(function() beginCapture("door") end)
clearPrison.MouseButton1Click:Connect(function() clearSelection(); prisonStatus.Text="Selection cleared." end)
pathBtn.MouseButton1Click:Connect(function()
    setEscortRecording(not escortRecording)
    prisonTask.wait(0.05)
    pathBtn.Text=(not escortRecording) and "START WALK RECORDING" or "STOP & SAVE WALK ROUTE"
end)

mouse.Button1Down:Connect(function()
    if not prisonPanel.Visible or not captureKind then return end
    if captureKind=="door" then
        if mouse.Target then
            selection.door=mouse.Target
            captureKind=nil
            prisonStatus.Text="Door selected. Set its type/access, then press SAVE."
            updateSelectionText()
        end
        return
    end
    local p=mouse.Hit.Position
    if captureKind=="corner A" then selection.a=p
    elseif captureKind=="corner B" then selection.b=p
    else selection.position=p end
    captureKind=nil
    prisonStatus.Text="Location captured."
    updateSelectionText()
end)

savePrison.MouseButton1Click:Connect(function()
    local data={name=nameBox.Text,category=currentType()}
    if prisonTask=="AREA" then
        if not selection.a or not selection.b then prisonStatus.Text="AREA needs both corners." return end
        data.a,data.b=selection.a,selection.b
        mapper:FireServer("PrisonSaveZone",data)
    elseif prisonTask=="CELL" then
        if not selection.position then prisonStatus.Text="CELL needs a stand position." return end
        data.position,data.door=selection.position,selection.door
        mapper:FireServer("PrisonSaveCell",data)
    elseif prisonTask=="MARKER" then
        if not selection.position then prisonStatus.Text="MARKER needs a position." return end
        data.position=selection.position
        mapper:FireServer("PrisonSavePoint",data)
    elseif prisonTask=="DOOR" then
        if not selection.door then prisonStatus.Text="DOOR needs a selected physical door/gate." return end
        data.door=selection.door
        data.doorType=doorTypes[typeIndex]
        data.security=securityTypes[securityIndex]
        data.access=accessTypes[accessIndex]
        data.direction=directionTypes[directionIndex]
        mapper:FireServer("PrisonSaveDoor",data)
    end
end)

local function prisonMarker(pos,color)
    local p=Instance.new("Part"); p.Shape=Enum.PartType.Ball; p.Size=Vector3.new(1,1,1); p.Anchored=true; p.CanCollide=false; p.CanQuery=false; p.Material=Enum.Material.Neon; p.Color=color; p.CFrame=CFrame.new(pos); p.Parent=prisonOverlay
end
local function prisonZone(minV,maxV)
    local p=Instance.new("Part"); p.Size=Vector3.new(math.max(.5,maxV.X-minV.X),math.max(.5,maxV.Y-minV.Y),math.max(.5,maxV.Z-minV.Z)); p.Anchored=true; p.CanCollide=false; p.CanQuery=false; p.Transparency=.72; p.Material=Enum.Material.ForceField; p.Color=Color3.fromRGB(70,155,230); p.CFrame=CFrame.new((minV+maxV)/2); p.Parent=prisonOverlay
end

local function togglePrisonMapper()
    prisonPanel.Visible=not prisonPanel.Visible
    setMapperOverlayVisible(prisonPanel.Visible)
    if prisonPanel.Visible then prisonStatus.Text="Choose AREA, CELL, DOOR, MARKER, or WALK PATH." end
end
setMapperOverlayVisible(false)
-- v212: no on-screen mapper button; F7 opens it for the developer only
prisonToggle.Visible=false
prisonToggle.MouseButton1Click:Connect(togglePrisonMapper)
UserInputService.InputBegan:Connect(function(input,processed)
    if processed then return end
    if input.KeyCode==Enum.KeyCode.F7 and player.Name=="aquagaming22" then togglePrisonMapper() end
end)

mapper.OnClientEvent:Connect(function(action,a,b,c,d,e)
    if action=="Enable" then
        if not prisonGui.Parent then prisonGui.Parent=player:WaitForChild("PlayerGui") end
        if not prisonOverlay.Parent then prisonOverlay.Parent=workspace end
    elseif action=="EscortStart" then
        if prisonTask=="WALK PATH" then pathBtn.Text="STOP & SAVE WALK ROUTE"; updateSelectionText() end
    elseif action=="EscortFinished" or action=="EscortCancelled" then
        if prisonTask=="WALK PATH" then pathBtn.Text="START WALK RECORDING"; updateSelectionText() end
    elseif action=="PrisonSaved" then
        local kind,name,category=a,b,c
        if kind=="Zone" and typeof(d)=="Vector3" and typeof(e)=="Vector3" then prisonZone(d,e)
        elseif typeof(d)=="Vector3" then prisonMarker(d,Color3.fromRGB(120,220,255)) end
        nameBox.Text=""
        clearSelection()
        prisonStatus.Text=("Saved %s '%s'. Output has the permanent [PrisonMapper] definition."):format(kind,tostring(name))
    end
end)

updateTaskUI()
print("[PrisonMapperClient] ready - click PRISON MAP [P], or press P/F7")


---------------------------------------------------------------------------
-- POLICE SENSORY EFFECTS v67
-- Client-owned camera/UI effects for taser and flashbang. Kept here because
-- RoadMapperClient is an existing StarterPlayer client script in this place.
---------------------------------------------------------------------------
do
	local TweenService=game:GetService("TweenService")
	local Lighting=game:GetService("Lighting")
	local effects=ReplicatedStorage:WaitForChild("PoliceEffects",20)
	local effectSerial=0
	local function cleanupNamed(name)
		local pg=player:FindFirstChildOfClass("PlayerGui")
		local old=pg and pg:FindFirstChild(name)
		if old then old:Destroy() end
		local l=Lighting:FindFirstChild(name)
		if l then l:Destroy() end
	end
	local function taserEffect(duration)
		effectSerial+=1; local serial=effectSerial
		cleanupNamed("PoliceTaserFX")
		local pg=player:WaitForChild("PlayerGui")
		local gui=Instance.new("ScreenGui"); gui.Name="PoliceTaserFX";gui.IgnoreGuiInset=true;gui.DisplayOrder=10000;gui.ResetOnSpawn=false;gui.Parent=pg
		local flash=Instance.new("Frame");flash.Size=UDim2.fromScale(1,1);flash.BackgroundColor3=Color3.new(1,1,1);flash.BackgroundTransparency=.42;flash.Parent=gui
		TweenService:Create(flash,TweenInfo.new(.22),{BackgroundTransparency=1}):Play()
		local cam=workspace.CurrentCamera
		task.spawn(function()
			local untilT=os.clock()+math.min(duration or 4,1.2)
			while gui.Parent and os.clock()<untilT and serial==effectSerial do
				if cam then cam.CFrame=cam.CFrame*CFrame.Angles(math.rad(math.random(-2,2)),0,math.rad(math.random(-2,2))) end
				task.wait(.055)
			end
		end)
		task.delay(duration or 4,function() if gui.Parent then gui:Destroy() end end)
	end
	local function flashbangEffect(duration)
		effectSerial+=1;local serial=effectSerial
		cleanupNamed("PoliceFlashFX");cleanupNamed("PoliceFlashBlur");cleanupNamed("PoliceFlashColor")
		local pg=player:WaitForChild("PlayerGui")
		local cam=workspace.CurrentCamera
		local frozen=cam and cam.CFrame
		local gui=Instance.new("ScreenGui");gui.Name="PoliceFlashFX";gui.IgnoreGuiInset=true;gui.DisplayOrder=11000;gui.ResetOnSpawn=false;gui.Parent=pg
		local white=Instance.new("Frame");white.Size=UDim2.fromScale(1,1);white.BackgroundColor3=Color3.new(1,1,1);white.BackgroundTransparency=0;white.Parent=gui
		local blur=Instance.new("BlurEffect");blur.Name="PoliceFlashBlur";blur.Size=34;blur.Parent=Lighting
		local cc=Instance.new("ColorCorrectionEffect");cc.Name="PoliceFlashColor";cc.Brightness=.65;cc.Contrast=-.25;cc.Saturation=-1;cc.Parent=Lighting
		-- Hold the impact frame briefly: camera input can continue internally, but
		-- the rendered camera is pinned, producing the MW-style visual disorientation.
		task.spawn(function()
			local holdUntil=os.clock()+.55
			while gui.Parent and frozen and os.clock()<holdUntil and serial==effectSerial do
				if workspace.CurrentCamera then workspace.CurrentCamera.CFrame=frozen end
				RunService.RenderStepped:Wait()
			end
		end)
		task.wait(.48)
		TweenService:Create(white,TweenInfo.new(math.max(2.8,(duration or 4.8)-.5),Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency=1}):Play()
		TweenService:Create(blur,TweenInfo.new(math.max(3,(duration or 4.8)-.4)),{Size=0}):Play()
		TweenService:Create(cc,TweenInfo.new(math.max(3,(duration or 4.8)-.4)),{Brightness=0,Contrast=0,Saturation=0}):Play()
		task.delay(duration or 4.8,function()
			if gui and gui.Parent then gui:Destroy() end
			if blur and blur.Parent then blur:Destroy() end
			if cc and cc.Parent then cc:Destroy() end
		end)
		-- Hard failsafe: no sensory effect is allowed to survive indefinitely.
		task.delay((duration or 4.8)+1.0,function()
			cleanupNamed("PoliceFlashFX")
			cleanupNamed("PoliceFlashBlur")
			cleanupNamed("PoliceFlashColor")
		end)
	end
	if effects then effects.OnClientEvent:Connect(function(kind,duration)
		if kind=="Taser" then taserEffect(duration)
		elseif kind=="Flashbang" then flashbangEffect(duration) end
	end) end
end
