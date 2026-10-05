-- RoadDriving (ModuleScript)
-- Road graph / lane / intersection controller shared by civilian traffic and police.
-- v64 rebuild:
--   * Detects real same-elevation crossings between traced road segments, even
--     when the mapper did not drop a node exactly at the intersection.
--   * Converts those crossings into routable junctions.
--   * Uses right-hand lanes, destination routing, congestion costs and
--     per-intersection traffic control.
--   * Primary/major junctions behave like traffic signals; smaller junctions
--     behave like four-way stops.
--   * Emergency drivers can request priority, but still slow for an occupied
--     junction rather than teleporting through other traffic.

local RoadDriving = {}

local SNAP_RADIUS = 14
local JUNCTION_CLUSTER_RADIUS = 12
local MAX_INTERSECTION_Y_DELTA = 5
local PARALLEL_DOT_LIMIT = 0.94
local ARRIVE_RADIUS = 8
local MAX_TURN_RATE = math.rad(125)
local ACCEL = 15
local BRAKE = 34
local TURN_SLOWDOWN = 0.48
local SURFACE_CLEARANCE = 0.08
local MAX_VERTICAL_SPEED = 16
local DEFAULT_LANE_WIDTH = 3.25
local ROUTE_CONGESTION_COST = 58

local ROAD_PRIORITY = {Primary=0.78, Secondary=1.0, Local=1.34}
local EMERGENCY_PRIORITY = {Primary=0.58, Secondary=0.78, Local=1.02}
local DEFAULT_SPEED_LIMIT = {Primary=32, Secondary=25, Local=18}

local prepareNetwork
local sharedNetwork=nil
local topologyCache=setmetatable({}, {__mode="k"})
local intersectionRuntime={}

local function flatDistance(a,b)
	local dx=a.X-b.X
	local dz=a.Z-b.Z
	return math.sqrt(dx*dx+dz*dz)
end

local function roadLength(road)
	local total=0
	for i=2,#road.points do
		total+=(road.points[i]-road.points[i-1]).Magnitude
	end
	return math.max(total,1)
end

-- Kerb-to-kerb width of the asphalt under a traced road (used when the road has no Width set).
local function measureWidth(pts)
	local params=RaycastParams.new()
	params.FilterType=Enum.RaycastFilterType.Exclude
	local rn=workspace:FindFirstChild("RoadNetwork")
	params.FilterDescendantsInstances=rn and {rn} or {}
	local widths={}
	for i=1,#pts-1 do
		local a,b=pts[i],pts[i+1]
		local dir=Vector3.new(b.X-a.X,0,b.Z-a.Z)
		if dir.Magnitude>4 then
			dir=dir.Unit
			local perp=Vector3.new(-dir.Z,0,dir.X)
			for _,f in ipairs({0.3,0.5,0.7}) do
				local m=a:Lerp(b,f)
				-- look through anything that isn't road surface (sidewalks, props) up to a few times
				local filter={rn}
				local hit=nil
				for _=1,4 do
					params.FilterDescendantsInstances=filter
					local h=workspace:Raycast(m+Vector3.new(0,15,0),Vector3.new(0,-40,0),params)
					if not h then break end
					if string.find(string.lower(h.Instance.Name),"road",1,true) then hit=h break end
					table.insert(filter,h.Instance)
				end
				if hit and hit.Instance:IsA("BasePart") then
					local cf,size=hit.Instance.CFrame,hit.Instance.Size
					local half=math.abs(perp:Dot(cf.RightVector))*size.X/2+math.abs(perp:Dot(cf.LookVector))*size.Z/2+math.abs(perp:Dot(cf.UpVector))*size.Y/2
					if half>4 and half<60 then table.insert(widths,half*2) end
				end
			end
		end
	end
	if #widths==0 then return nil end
	table.sort(widths)
	return widths[math.ceil(#widths/2)]
end
RoadDriving.measureWidth=measureWidth

local function roadTypeOf(folder)
	return folder:GetAttribute("RoadType") or folder.Name:match("^(%a+)_") or "Local"
end

function RoadDriving.loadNetwork()
	if sharedNetwork and #sharedNetwork>0 then return sharedNetwork end
	local folder=workspace:WaitForChild("RoadNetwork",10)
	local roads={}
	if not folder then return roads end
	-- RoadMapperServer builds the auto-generated roads at startup; wait for it to finish
	local waited=0
	while folder:GetAttribute("AutoRoadCount")==nil and waited<12 do
		task.wait(0.1)
		waited+=0.1
	end

	for _,roadFolder in ipairs(folder:GetChildren()) do
		if roadFolder:IsA("Folder") then
			local raw={}
			local i=1
			while true do
				local node=roadFolder:FindFirstChild(tostring(i))
				if not node then break end
				table.insert(raw,node.Position)
				i+=1
			end
			if #raw>=2 then
				local roadType=roadTypeOf(roadFolder)
				table.insert(roads,{
					name=roadFolder.Name,
					roadType=roadType,
					rawPoints=raw,
					points=table.clone(raw),
					junctionAtNode={},
					laneWidth=tonumber(roadFolder:GetAttribute("LaneWidth")) or DEFAULT_LANE_WIDTH,
					oneWay=roadFolder:GetAttribute("OneWay")==true, -- traffic only drives node 1 -> last
					lanes=math.clamp(math.floor(tonumber(roadFolder:GetAttribute("Lanes")) or 1),1,4), -- per direction
					width=tonumber(roadFolder:GetAttribute("Width")), -- kerb to kerb; splits into lanes (0 = single lane)
					speedLimit=tonumber(roadFolder:GetAttribute("SpeedLimit")) or DEFAULT_SPEED_LIMIT[roadType] or DEFAULT_SPEED_LIMIT.Local,
				})
			end
		end
	end

	-- roads without a Width: measure the asphalt and split it into lanes automatically
	for _,road in ipairs(roads) do
		if road.width==nil then
			local w=measureWidth(road.rawPoints)
			if w then
				road.width=w
				road.lanes=if w>=70 then 3 elseif w>=44 then 2 else 1
			end
		end
	end

	if prepareNetwork then prepareNetwork(roads) end
	if #roads>0 then sharedNetwork=roads end
	return roads
end

function RoadDriving.invalidateNetwork()
	sharedNetwork=nil
end

local function cross2(ax,az,bx,bz)
	return ax*bz-az*bx
end

local function segmentIntersection(a,b,c,d)
	local rx=b.X-a.X
	local rz=b.Z-a.Z
	local sx=d.X-c.X
	local sz=d.Z-c.Z
	local den=cross2(rx,rz,sx,sz)
	if math.abs(den)<0.0001 then return nil end

	local qx=c.X-a.X
	local qz=c.Z-a.Z
	local t=cross2(qx,qz,sx,sz)/den
	local u=cross2(qx,qz,rx,rz)/den
	if t<-0.015 or t>1.015 or u<-0.015 or u>1.015 then return nil end

	local rmag=math.sqrt(rx*rx+rz*rz)
	local smag=math.sqrt(sx*sx+sz*sz)
	if rmag<0.1 or smag<0.1 then return nil end
	local dot=math.abs((rx*sx+rz*sz)/(rmag*smag))
	if dot>PARALLEL_DOT_LIMIT then return nil end

	local yA=a.Y+(b.Y-a.Y)*t
	local yB=c.Y+(d.Y-c.Y)*u
	if math.abs(yA-yB)>MAX_INTERSECTION_Y_DELTA then return nil end

	return Vector3.new(a.X+rx*t,(yA+yB)*0.5,a.Z+rz*t),math.clamp(t,0,1),math.clamp(u,0,1)
end

local function appendUnique(list,item)
	for _,v in ipairs(list) do
		if v==item then return end
	end
	table.insert(list,item)
end

local function buildTopology(network)
	local cached=topologyCache[network]
	if cached then return cached end

	local junctions={}
	local inserts={}
	local rawMarks={}
	for i=1,#network do
		inserts[i]={}
		rawMarks[i]={}
	end

	-- v293: a grid broadphase. With the real-scale OSM roads (hundreds of lines, thousands of
	-- segments) the all-pairs segment test and the linear junction search took far too long.
	local CELL=64
	local function cellKey(cx,cz) return (cx+20000)*100000+(cz+20000) end
	local junctionCells={}
	local function findOrCreateJunction(position)
		local cx,cz=math.floor(position.X/CELL),math.floor(position.Z/CELL)
		local best=nil
		for dx=-1,1 do
			for dz=-1,1 do
				for _,j in ipairs(junctionCells[cellKey(cx+dx,cz+dz)] or {}) do
					if flatDistance(j.position,position)<=JUNCTION_CLUSTER_RADIUS and math.abs(j.position.Y-position.Y)<=MAX_INTERSECTION_Y_DELTA then
						if not best or j.id<best.id then best=j end
					end
				end
			end
		end
		if best then return best end
		local j={
			id=#junctions+1,
			position=position,
			roads={},
			nodes={},
			control="Stop",
			signalOffset=(#junctions*3.7)%22,
		}
		table.insert(junctions,j)
		local key=cellKey(cx,cz)
		junctionCells[key]=junctionCells[key] or {}
		table.insert(junctionCells[key],j)
		return j
	end
	-- every segment, filed under the grid cells its bounding box touches
	local segCells={}
	local segList={}
	for r=1,#network do
		local raw=network[r].rawPoints or network[r].points
		for s=1,#raw-1 do
			local p,q=raw[s],raw[s+1]
			local id=#segList+1
			segList[id]={road=r,seg=s}
			for cx=math.floor(math.min(p.X,q.X)/CELL),math.floor(math.max(p.X,q.X)/CELL) do
				for cz=math.floor(math.min(p.Z,q.Z)/CELL),math.floor(math.max(p.Z,q.Z)/CELL) do
					local key=cellKey(cx,cz)
					local list=segCells[key]
					if not list then list={} segCells[key]=list end
					table.insert(list,id)
				end
			end
		end
	end
	local nodeCells={}
	for r=1,#network do
		local raw=network[r].rawPoints or network[r].points
		for n,p in ipairs(raw) do
			local key=cellKey(math.floor(p.X/CELL),math.floor(p.Z/CELL))
			local list=nodeCells[key]
			if not list then list={} nodeCells[key]=list end
			table.insert(list,{road=r,node=n})
		end
	end

	local function markRoadUse(j,roadIndex)
		j.roads[roadIndex]=true
	end

	local function addInsert(roadIndex,segmentIndex,t,junction)
		inserts[roadIndex][segmentIndex]=inserts[roadIndex][segmentIndex] or {}
		table.insert(inserts[roadIndex][segmentIndex],{
			t=t,
			position=junction.position,
			junctionId=junction.id,
		})
		markRoadUse(junction,roadIndex)
	end

	local function markRaw(roadIndex,nodeIndex,junction)
		rawMarks[roadIndex][nodeIndex]=junction.id
		markRoadUse(junction,roadIndex)
	end

	-- True geometric crossings. This is the important change for the existing
	-- Las Vegas map because several traced roads contain very long segments
	-- that cross other streets without a node at the crossing.
	-- (pairs of segments sharing a grid cell, each pair once, lower road index first as before)
	local testedPair={}
	local nSeg=#segList
	for _,list in pairs(segCells) do
		for i=1,#list-1 do
			for k=i+1,#list do
				local idA,idB=list[i],list[k]
				local A,B=segList[idA],segList[idB]
				if A.road~=B.road then
					if A.road>B.road or (A.road==B.road and A.seg>B.seg) then A,B=B,A; idA,idB=idB,idA end
					local pairKey=idA*(nSeg+1)+idB
					if not testedPair[pairKey] then
						testedPair[pairKey]=true
						local a,b,sa,sb=A.road,B.road,A.seg,B.seg
						local rawA=network[a].rawPoints or network[a].points
						local rawB=network[b].rawPoints or network[b].points
						local position,t,u=segmentIntersection(rawA[sa],rawA[sa+1],rawB[sb],rawB[sb+1])
						if position then
							local j=findOrCreateJunction(position)
							if t<=0.035 then markRaw(a,sa,j)
							elseif t>=0.965 then markRaw(a,sa+1,j)
							else addInsert(a,sa,t,j) end
							if u<=0.035 then markRaw(b,sb,j)
							elseif u>=0.965 then markRaw(b,sb+1,j)
							else addInsert(b,sb,u,j) end
						end
					end
				end
			end
		end
	end

	-- Also support roads that terminate onto another traced road without
	-- geometrically crossing it. Only endpoints may create this kind of snap.
	for a,roadA in ipairs(network) do
		local rawA=roadA.rawPoints or roadA.points
		for _,nodeA in ipairs({1,#rawA}) do
			local pa=rawA[nodeA]
			local bestRoad,bestNode,bestDist=nil,nil,SNAP_RADIUS
			local pcx,pcz=math.floor(pa.X/CELL),math.floor(pa.Z/CELL)
			for dx=-1,1 do
				for dz=-1,1 do
					for _,nb in ipairs(nodeCells[cellKey(pcx+dx,pcz+dz)] or {}) do
						if nb.road~=a then
							local rawB=network[nb.road].rawPoints or network[nb.road].points
							local pb=rawB[nb.node]
							local d=flatDistance(pa,pb)
							if d<bestDist and math.abs(pa.Y-pb.Y)<=MAX_INTERSECTION_Y_DELTA then
								bestRoad,bestNode,bestDist=nb.road,nb.node,d
							end
						end
					end
				end
			end
			if bestRoad then
				local rawB=network[bestRoad].rawPoints or network[bestRoad].points
				local pos=(pa+rawB[bestNode])*0.5
				local j=findOrCreateJunction(pos)
				markRaw(a,nodeA,j)
				markRaw(bestRoad,bestNode,j)
			else
				-- T-joint: this end sits on the middle of another road's segment (no node there)
				local segRoad,segIdx,segT,segPos,segDist=nil,nil,0,nil,SNAP_RADIUS
				local near={}
				local pcx,pcz=math.floor(pa.X/CELL),math.floor(pa.Z/CELL)
				for dx=-1,1 do
					for dz=-1,1 do
						for _,id in ipairs(segCells[cellKey(pcx+dx,pcz+dz)] or {}) do near[id]=true end
					end
				end
				for id in pairs(near) do
					local b,sIdx=segList[id].road,segList[id].seg
					if b~=a then
						local rawB=network[b].rawPoints or network[b].points
						do
							local p1,p2=rawB[sIdx],rawB[sIdx+1]
							local dx,dz=p2.X-p1.X,p2.Z-p1.Z
							local L2=dx*dx+dz*dz
							if L2>0.01 then
								local t=math.clamp(((pa.X-p1.X)*dx+(pa.Z-p1.Z)*dz)/L2,0,1)
								local q=p1:Lerp(p2,t)
								local dist=flatDistance(pa,q)
								if dist<segDist and math.abs(pa.Y-q.Y)<=MAX_INTERSECTION_Y_DELTA then
									segRoad,segIdx,segT,segPos,segDist=b,sIdx,t,q,dist
								end
							end
						end
					end
				end
				if segRoad and segPos then
					local j=findOrCreateJunction(segPos)
					markRaw(a,nodeA,j)
					if segT<=0.035 then markRaw(segRoad,segIdx,j)
					elseif segT>=0.965 then markRaw(segRoad,segIdx+1,j)
					else addInsert(segRoad,segIdx,segT,j) end
				end
			end
		end
	end

	-- Expand each traced road so every inferred crossing becomes a real node.
	for roadIndex,road in ipairs(network) do
		local raw=road.rawPoints or road.points
		local expanded={}
		local junctionAtNode={}

		local function push(position,jid)
			if #expanded>0 and flatDistance(expanded[#expanded],position)<0.75 then
				if jid then junctionAtNode[#expanded]=jid end
				return
			end
			table.insert(expanded,position)
			if jid then junctionAtNode[#expanded]=jid end
		end

		for seg=1,#raw-1 do
			if seg==1 then push(raw[seg],rawMarks[roadIndex][seg]) end
			local list=inserts[roadIndex][seg] or {}
			table.sort(list,function(x,y) return x.t<y.t end)
			for _,ins in ipairs(list) do
				push(ins.position,ins.junctionId)
			end
			push(raw[seg+1],rawMarks[roadIndex][seg+1])
		end

		road.points=expanded
		road.junctionAtNode=junctionAtNode
	end

	-- Now that expanded node indices are known, populate the junction lookup.
	for roadIndex,road in ipairs(network) do
		for nodeIndex,jid in pairs(road.junctionAtNode) do
			local j=junctions[jid]
			if j then
				j.nodes[roadIndex]=j.nodes[roadIndex] or {}
				appendUnique(j.nodes[roadIndex],nodeIndex)
				j.roads[roadIndex]=true
			end
		end
	end

	-- Auto-classify crossings first.
	for _,j in ipairs(junctions) do
		local roadCount=0
		local primaryCount=0
		local secondaryCount=0
		for roadIndex in pairs(j.roads) do
			roadCount+=1
			local rt=network[roadIndex] and network[roadIndex].roadType
			if rt=="Primary" then primaryCount+=1
			elseif rt=="Secondary" then secondaryCount+=1 end
		end
		if primaryCount>=1 and roadCount>=2 then
			j.control="Signal"
		elseif roadCount>=3 or secondaryCount>=2 then
			j.control="Signal"
		else
			j.control="Stop"
		end
	end

	-- ROAD MAPPER V2 can place an explicit control marker at a crossing.
	-- "Auto" leaves the inferred behavior alone.
	local roadRoot=workspace:FindFirstChild("RoadNetwork")
	local hintRoot=roadRoot and roadRoot:FindFirstChild("Junctions")
	if hintRoot then
		for _,hint in ipairs(hintRoot:GetChildren()) do
			if hint:IsA("BasePart") then
				local control=tostring(hint:GetAttribute("ControlType") or "Auto")
				if control~="Auto" then
					local best,bestD=nil,60 -- markers often sit on the stop line, a node before the junction
					for _,j in ipairs(junctions) do
						local d=flatDistance(j.position,hint.Position)
						if d<bestD and math.abs(j.position.Y-hint.Position.Y)<=MAX_INTERSECTION_Y_DELTA then
							best,bestD=j,d
						end
					end
					if best then
						best.control=control
						best.explicitControl=true
					end
				end
			end
		end
	end

	local graph={}
	for i=1,#network do graph[i]={} end
	for _,j in ipairs(junctions) do
		local roads={}
		for r in pairs(j.roads) do table.insert(roads,r) end
		for _,a in ipairs(roads) do
			for _,b in ipairs(roads) do
				if a~=b then
					for _,nodeA in ipairs(j.nodes[a] or {}) do
						for _,nodeB in ipairs(j.nodes[b] or {}) do
							-- one-way: can't enter at the far end or leave from the start
							local wrongWay=(network[b].oneWay and nodeB>=#network[b].points) or (network[a].oneWay and nodeA<=1)
							if not wrongWay then table.insert(graph[a],{
								road=b,
								fromNode=nodeA,
								toNode=nodeB,
								junctionId=j.id,
								snapDistance=0,
							}) end
						end
					end
				end
			end
		end
	end

	local topology={junctions=junctions,graph=graph}
	topologyCache[network]=topology
	network._junctions=junctions
	network._graph=graph
	return topology
end

prepareNetwork=buildTopology

function RoadDriving.buildGraph(network)
	return buildTopology(network).graph
end

function RoadDriving.getJunctions(network)
	return buildTopology(network).junctions
end

function RoadDriving.nearestNode(network,position)
	local bestRoad,bestNode,bestDist=nil,nil,math.huge
	for roadIndex,road in ipairs(network) do
		for nodeIndex,point in ipairs(road.points) do
			local d=(point-position).Magnitude
			if d<bestDist then
				bestRoad,bestNode,bestDist=roadIndex,nodeIndex,d
			end
		end
	end
	return bestRoad,bestNode,bestDist
end

function RoadDriving.newDriver(network,roadIndex,nodeIndex,direction,startPos)
	local profileJitter=0.94+math.random()*0.12
	return {
		network=network,
		road=roadIndex,
		node=nodeIndex,
		dir=direction or 1,
		heading=Vector3.new(0,0,-1),
		speed=0,
		pos=startPos,
		y=startPos and startPos.Y or nil,
		groundOffset=nil,
		laneOffset=DEFAULT_LANE_WIDTH,
		baseLaneOffset=DEFAULT_LANE_WIDTH,
		speedFactor=profileJitter,
		resident=false,
		emergency=false,
		vehicleKey=nil,
		route=nil,
		routePos=1,
		destinationRoad=nil,
		destinationNode=nil,
		nextConnection=nil,
		tripComplete=false,
		recentRoads={},
		intersectionWait={},
		lastPassedJunction=nil,
	}
end

-- Offset (right of the centre line) of lane `lane` on `road`. Lane 1 = next to the centre
-- (fast / passing lane), the highest lane = kerb side. One-way roads spread lanes across the width.
local function laneCenter(road,lane)
	local lanes=road.lanes or 1
	lane=math.clamp(lane or lanes,1,lanes)
	if road.width and road.width>0 then
		if road.oneWay then
			local lw=road.width/lanes
			return -road.width/2+(lane-0.5)*lw
		end
		return (lane-0.5)*(road.width/2/lanes)
	end
	return road.laneWidth or DEFAULT_LANE_WIDTH
end
RoadDriving.laneCenter=laneCenter

-- Faster drivers and emergency vehicles use the inside lane; everyone else mostly keeps right.
local function pickLane(driver,road)
	local lanes=road.lanes or 1
	if lanes<=1 then return 1 end
	if driver.emergency then return 1 end
	if (driver.speedFactor or 1)>1.03 then return math.random(1,math.max(1,lanes-1)) end
	return if math.random()<0.7 then lanes else math.random(1,lanes)
end

local function snapToGround(position,car,referenceY)
	local refY=referenceY or position.Y
	local origin=Vector3.new(position.X,refY+2.0,position.Z)
	local params=RaycastParams.new()
	params.FilterType=Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances=car and {car} or {}
	params.RespectCanCollide=true
	local hit=workspace:Raycast(origin,Vector3.new(0,-24,0),params)
	if not hit then return nil end
	if hit.Position.Y>refY+1.25 or hit.Position.Y<refY-14 then return nil end
	return hit.Position.Y
end

local function pivotGroundOffset(driver,car)
	if driver.groundOffset then return driver.groundOffset end
	local pivotY=car:GetPivot().Position.Y
	local lowestY=math.huge
	for _,part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide and part.Transparency<0.98 then
			local cf=part.CFrame
			local s=part.Size*0.5
			local halfY=math.abs(cf.RightVector.Y)*s.X+math.abs(cf.UpVector.Y)*s.Y+math.abs(cf.LookVector.Y)*s.Z
			lowestY=math.min(lowestY,part.Position.Y-halfY)
		end
	end
	if lowestY==math.huge then
		local seat=car:FindFirstChildWhichIsA("VehicleSeat",true)
		lowestY=seat and (seat.Position.Y-seat.Size.Y*0.5-1.2) or (pivotY-1.5)
	end
	driver.groundOffset=math.clamp(pivotY-lowestY,0.35,4.5)
	return driver.groundOffset
end

local function occupancyValue(occupancy,network,roadIndex)
	if not occupancy then return 0 end
	local road=network[roadIndex]
	return tonumber(occupancy[roadIndex] or (road and occupancy[road.name]) or 0) or 0
end

local function rememberRoad(driver,roadIndex)
	table.insert(driver.recentRoads,roadIndex)
	while #driver.recentRoads>5 do table.remove(driver.recentRoads,1) end
end

local function recentlyUsed(driver,roadIndex)
	for _,r in ipairs(driver.recentRoads) do
		if r==roadIndex then return true end
	end
	return false
end

local function connectionBetween(network,fromRoad,toRoad,fromNode)
	local graph=buildTopology(network).graph
	local best,bestScore=nil,math.huge
	for _,edge in ipairs(graph[fromRoad] or {}) do
		if edge.road==toRoad then
			local score=math.abs((fromNode or edge.fromNode)-edge.fromNode)
			if score<bestScore then
				best,bestScore=edge,score
			end
		end
	end
	return best
end

function RoadDriving.chooseDestinationRoad(network,currentRoad,occupancy)
	if #network<=1 then return currentRoad end
	local graph=buildTopology(network).graph
	local reachable={}
	local seen={[currentRoad]=true}
	local queue={currentRoad}
	local q=1
	while q<=#queue do
		local u=queue[q]
		q+=1
		for _,edge in ipairs(graph[u] or {}) do
			if not seen[edge.road] then
				seen[edge.road]=true
				table.insert(queue,edge.road)
				table.insert(reachable,edge.road)
			end
		end
	end
	if #reachable==0 then return currentRoad end

	local choices={}
	local total=0
	for _,i in ipairs(reachable) do
		local r=network[i]
		local classWeight=(r.roadType=="Primary" and 1.45) or (r.roadType=="Secondary" and 1.1) or 0.6
		local congestion=occupancyValue(occupancy,network,i)
		local weight=classWeight/(1+congestion*0.5)
		total+=weight
		table.insert(choices,{road=i,ceiling=total})
	end
	local roll=math.random()*total
	for _,choice in ipairs(choices) do
		if roll<=choice.ceiling then return choice.road end
	end
	return choices[#choices].road
end

function RoadDriving.planTrip(driver,destinationRoad,occupancy,options)
	if not driver or not driver.network[driver.road] or not driver.network[destinationRoad] then return nil end
	options=options or {}
	local network=driver.network
	local graph=buildTopology(network).graph
	local dist,prev,open={},{},{}
	for i=1,#network do
		dist[i]=math.huge
		open[i]=true
	end
	dist[driver.road]=0

	while true do
		local u,best=nil,math.huge
		for i=1,#network do
			if open[i] and dist[i]<best then
				u,best=i,dist[i]
			end
		end
		if not u or u==destinationRoad then break end
		open[u]=nil

		for _,edge in ipairs(graph[u] or {}) do
			local v=edge.road
			if open[v] then
				local r=network[v]
				local priorities=options.emergency and EMERGENCY_PRIORITY or ROAD_PRIORITY
				local classCost=priorities[r.roadType] or priorities.Local
				local congestion=occupancyValue(occupancy,network,v)
				local congestionCost=congestion*(options.emergency and 12 or ROUTE_CONGESTION_COST)
				local repeatCost=recentlyUsed(driver,v) and 55 or 0
				local jitter=options.emergency and 0 or math.random()*10
				local alt=dist[u]+roadLength(r)*classCost+congestionCost+repeatCost+jitter
				if alt<dist[v] then
					dist[v]=alt
					prev[v]=u
				end
			end
		end
	end

	if destinationRoad~=driver.road and not prev[destinationRoad] then
		driver.route=nil
		driver.nextConnection=nil
		driver.destinationRoad=nil
		return nil
	end

	local reverse={destinationRoad}
	local cur=destinationRoad
	while cur~=driver.road do
		cur=prev[cur]
		if not cur then break end
		table.insert(reverse,cur)
	end
	local route={}
	for i=#reverse,1,-1 do table.insert(route,reverse[i]) end

	driver.route=route
	driver.routePos=1
	driver.destinationRoad=destinationRoad
	driver.destinationNode=math.clamp(tonumber(options.destinationNode) or math.random(1,#network[destinationRoad].points),1,#network[destinationRoad].points)
	driver.tripComplete=false
	driver.occupancy=occupancy

	if #route>=2 then
		local edge=connectionBetween(network,route[1],route[2],driver.node)
		driver.nextConnection=edge
		if edge then
			if edge.fromNode>driver.node then driver.dir=1
			elseif edge.fromNode<driver.node then driver.dir=-1 end
		end
	else
		driver.nextConnection=nil
		if driver.destinationNode>driver.node then driver.dir=1
		elseif driver.destinationNode<driver.node then driver.dir=-1
		else driver.tripComplete=true end
	end
	return route
end

local function setNextConnection(driver)
	if not driver.route or driver.routePos>=#driver.route then
		driver.nextConnection=nil
		return
	end
	local nextRoad=driver.route[driver.routePos+1]
	local edge=connectionBetween(driver.network,driver.road,nextRoad,driver.node)
	driver.nextConnection=edge
	if edge then
		if edge.fromNode>driver.node then driver.dir=1
		elseif edge.fromNode<driver.node then driver.dir=-1 end
	end
end

local function switchRoad(driver,edge)
	driver.lastPassedJunction=edge.junctionId
	driver.road=edge.road
	driver.node=edge.toNode
	driver.routePos=math.min((driver.routePos or 1)+1,driver.route and #driver.route or 1)
	rememberRoad(driver,driver.road)

	if driver.route and driver.routePos<#driver.route then
		setNextConnection(driver)
	elseif driver.route and driver.routePos==#driver.route then
		driver.nextConnection=nil
		local r=driver.network[driver.road]
		if r and r.oneWay and driver.destinationNode<driver.node then
			driver.destinationNode=#r.points
		end
		if driver.destinationNode>driver.node then driver.dir=1
		elseif driver.destinationNode<driver.node then driver.dir=-1
		else driver.tripComplete=true end
	else
		driver.nextConnection=nil
	end
end

local function junctionForNode(driver,nodeIndex)
	local road=driver.network[driver.road]
	return road and road.junctionAtNode and road.junctionAtNode[nodeIndex]
end

local function releaseQueue(driver,jid)
	local runtime=intersectionRuntime[jid]
	local key=driver.vehicleKey or driver
	if runtime then
		if runtime.queue then runtime.queue[key]=nil end
		if runtime.seen then runtime.seen[key]=nil end
		if runtime.reservation==key then
			runtime.reservationUntil=math.min(runtime.reservationUntil or math.huge,os.clock()+0.65)
		end
	end
	driver.intersectionWait[jid]=nil
end

local function advance(driver)
	local road=driver.network[driver.road]
	if not road then return end

	if driver.nextConnection and driver.node==driver.nextConnection.fromNode then
		releaseQueue(driver,driver.nextConnection.junctionId)
		switchRoad(driver,driver.nextConnection)
		return
	end

	if driver.route and driver.routePos==#driver.route and driver.destinationNode and driver.node==driver.destinationNode then
		driver.tripComplete=true
		return
	end

	local currentJunction=junctionForNode(driver,driver.node)
	if currentJunction then
		driver.lastPassedJunction=currentJunction
		releaseQueue(driver,currentJunction)
	end

	local nextIndex=driver.node+driver.dir
	if nextIndex>=1 and nextIndex<=#road.points then
		driver.node=nextIndex
		return
	end

	-- At a dead end, turn around. Destination routing will select another road
	-- on the next trip rather than sending the vehicle off-road.
	driver.dir=-driver.dir
	driver.node=math.clamp(driver.node+driver.dir,1,#road.points)
	driver.route=nil
	driver.nextConnection=nil
	driver.destinationRoad=nil
	driver.destinationNode=nil
	driver.tripComplete=true
end

local function upcomingJunction(driver)
	local road=driver.network[driver.road]
	if not road then return nil,nil,nil end
	local pos=driver.pos
	local total=0
	local node=driver.node
	local previous=pos or road.points[math.clamp(node-driver.dir,1,#road.points)]
    if driver.resident and pos then
        local a=road.points[math.clamp(node-driver.dir,1,#road.points)]
        local b=road.points[node]
        local segment=b and Vector3.new(b.X-a.X,0,b.Z-a.Z)
        if segment and segment.Magnitude>0.1 then
            local along=math.clamp((pos-a):Dot(segment.Unit),0,segment.Magnitude)
            previous=a+segment.Unit*along
        end
    end
	local safety=0
	while node>=1 and node<=#road.points and safety<12 do
		safety+=1
		local p=road.points[node]
		total+=flatDistance(previous,p)
		local jid=road.junctionAtNode and road.junctionAtNode[node]
		if jid and not (jid==driver.lastPassedJunction and total<12) then
			return jid,total,node
		end
		previous=p
		node+=driver.dir
	end
	return nil,nil,nil
end

local function approachAxis(driver,junctionNode)
	local road=driver.network[driver.road]
	if not road then return "NS" end
	local before=junctionNode-driver.dir
	local a=(before>=1 and before<=#road.points) and road.points[before] or driver.pos
	local b=road.points[junctionNode]
	if not (a and b) then return "NS" end
	local dx=b.X-a.X
	local dz=b.Z-a.Z
	return math.abs(dx)>math.abs(dz) and "EW" or "NS"
end

local function runtimeFor(jid)
	local r=intersectionRuntime[jid]
	if not r then
		r={queue={},seen={},reservation=nil,reservationUntil=0}
		intersectionRuntime[jid]=r
	end
	local now=os.clock()
	if r.reservation and r.reservationUntil<=now then
		r.reservation=nil
	end
	-- A queued car refreshes `seen` every tick it is still approaching. Entries
	-- from cars that rerouted, turned around or were despawned used to stay
	-- "first in line" for 12s and hold every other car at the stop line.
	for key,arrival in pairs(r.queue) do
		if now-arrival>12 or now-(r.seen[key] or arrival)>1.5 then r.queue[key]=nil;r.seen[key]=nil end
	end
	return r
end

local function queueWinner(runtime)
	local winner,best=nil,math.huge
	for key,arrival in pairs(runtime.queue) do
		if arrival<best then
			winner,best=key,arrival
		end
	end
	return winner
end

local function signalGreen(junction,axis)
	local phase=(os.clock()+(junction.signalOffset or 0))%22
	if axis=="NS" then return phase<9 end
	return phase>=11 and phase<20
end

local function intersectionControlledSpeed(driver,requestedSpeed)
	local jid,dist,node=upcomingJunction(driver)
	if not jid or not dist or dist>38 then return requestedSpeed end
	local junction=buildTopology(driver.network).junctions[jid]
	if not junction then return requestedSpeed end

	local key=driver.vehicleKey or driver
	local runtime=runtimeFor(jid)
	if runtime.queue[key] then runtime.seen[key]=os.clock() end
	local emergency=driver.emergency==true
	local turnSpeed=emergency and 28 or 13
	local approachSpeed=emergency and 24 or 11

	if runtime.reservation==key then
		return math.min(requestedSpeed,turnSpeed)
	end

	if emergency then
		-- Emergency units pre-empt the signal, but never enter a junction that
		-- another vehicle currently owns.
		if runtime.reservation==nil and dist<=18 then
			runtime.reservation=key
			runtime.reservationUntil=os.clock()+2.6
			runtime.queue[key]=nil
			return math.min(requestedSpeed,turnSpeed)
		end
		if dist<=8 then return 0 end
		return math.min(requestedSpeed,approachSpeed)
	end

	if junction.control=="Uncontrolled" then
		if dist<=14 then
			if runtime.reservation==nil then
				runtime.reservation=key
				runtime.reservationUntil=os.clock()+1.8
			elseif runtime.reservation~=key then
				return 0
			end
		end
		return requestedSpeed
	end

	if junction.control=="Yield" then
		if dist<=18 then
			if runtime.reservation==nil then
				runtime.reservation=key
				runtime.reservationUntil=os.clock()+1.95
				return math.min(requestedSpeed,turnSpeed)
			elseif runtime.reservation~=key then
				if dist<=9 then return 0 end
				return math.min(requestedSpeed,7)
			end
		end
		return math.min(requestedSpeed,approachSpeed)
	end

	if junction.control=="Signal" then
		if not runtime.queue[key] and dist<=28 then runtime.queue[key]=os.clock() end
		local axis=approachAxis(driver,node)
		local green=signalGreen(junction,axis)
		if not green then
			if dist<=11 then return 0 end
			return math.min(requestedSpeed,approachSpeed)
		end

		if dist<=15 then
			if runtime.reservation==nil then
				runtime.reservation=key
				runtime.reservationUntil=os.clock()+2.35
				runtime.queue[key]=nil
				return math.min(requestedSpeed,turnSpeed)
			end
			if runtime.reservation~=key then return 0 end
		end
		return math.min(requestedSpeed,math.max(turnSpeed,approachSpeed))
	end

	-- Four-way stop / unsignalized junction.
	if dist<=13 and not runtime.queue[key] then runtime.queue[key]=os.clock() end
	if dist<=11 then
		local started=driver.intersectionWait[jid]
		if not started then
			driver.intersectionWait[jid]=os.clock()
			return 0
		end
		local waitNeeded=0.65+((tonumber(string.match(tostring(jid),"(%d+)")) or 1)%4)*0.08
		if os.clock()-started<waitNeeded then return 0 end
		local winner=queueWinner(runtime)
		if runtime.reservation==nil and (winner==nil or winner==key) then
			runtime.reservation=key
			runtime.reservationUntil=os.clock()+2.15
			runtime.queue[key]=nil
			return math.min(requestedSpeed,turnSpeed)
		end
		if runtime.reservation~=key then return 0 end
	end
	return math.min(requestedSpeed,approachSpeed)
end

function RoadDriving.speedLimit(driver)
	local road=driver and driver.network and driver.network[driver.road]
	return road and road.speedLimit or DEFAULT_SPEED_LIMIT.Local
end

function RoadDriving.upcomingIntersection(driver)
	local jid,dist,node=upcomingJunction(driver)
	if not jid then return nil end
	local junction=buildTopology(driver.network).junctions[jid]
	return jid,dist,junction and junction.control or nil,node
end

-- Project onto the current lane and pursue a speed-scaled point ahead.
-- This corrects lateral drift gradually instead of aiming only at far nodes.
local function residentTarget(driver,road,carPos,baseTarget,dt)
 local previous=road.points[driver.node-driver.dir] or baseTarget
 local segment=Vector3.new(baseTarget.X-previous.X,0,baseTarget.Z-previous.Z)
 if segment.Magnitude<0.1 then return baseTarget,baseTarget.Y,1 end
 local forward=segment.Unit
 local right=Vector3.new(-forward.Z,0,forward.X)
 if driver.laneRoad~=driver.road then
  driver.laneRoad=driver.road;driver.lane=pickLane(driver,road)
 end
 local offset=laneCenter(road,driver.lane)+(driver.laneOffset or DEFAULT_LANE_WIDTH)-DEFAULT_LANE_WIDTH
 driver.smoothLaneOffset=driver.smoothLaneOffset or offset
 driver.smoothLaneOffset+=math.clamp(offset-driver.smoothLaneOffset,-2.5*dt,2.5*dt)
 local along=math.clamp((carPos-previous):Dot(forward),0,segment.Magnitude)
 local look=math.clamp(7+(driver.speed or 0)*0.38,7,20)
 local targetAlong=math.min(segment.Magnitude,along+look)
 local target=previous:Lerp(baseTarget,targetAlong/segment.Magnitude)+right*driver.smoothLaneOffset
 local surface=previous.Y+(baseTarget.Y-previous.Y)*(along/segment.Magnitude)
 local nextPoint=road.points[driver.node+driver.dir]
 local factor=1
 if nextPoint and segment.Magnitude-along<math.max(18,(driver.speed or 0)*1.1) then
  local nextDirection=Vector3.new(nextPoint.X-baseTarget.X,0,nextPoint.Z-baseTarget.Z)
  if nextDirection.Magnitude>0.1 then factor=math.clamp((forward:Dot(nextDirection.Unit)+1)*0.5,0.3,1) end
 end
 return target,surface,factor
end


local function moveToward(driver,car,dt,targetPos,cruiseSpeed,spinWheels,roadSurfaceY)
	local carPos=driver.pos or car:GetPivot().Position
	local toTarget=targetPos-carPos
	local flatToTarget=Vector3.new(toTarget.X,0,toTarget.Z)
	local desired=flatToTarget.Magnitude>0.1 and flatToTarget.Unit or driver.heading

	local angle=math.acos(math.clamp(driver.heading:Dot(desired),-1,1))
	if angle>0.001 then
		local t=math.min(1,(MAX_TURN_RATE*dt)/angle)
		if driver.resident then
            local yaw=math.atan2(driver.heading.X,driver.heading.Z)
            local goal=math.atan2(desired.X,desired.Z)
            local delta=math.atan2(math.sin(goal-yaw),math.cos(goal-yaw))
            yaw+=math.clamp(delta,-MAX_TURN_RATE*dt,MAX_TURN_RATE*dt)
            driver.heading=Vector3.new(math.sin(yaw),0,math.cos(yaw))
        else driver.heading=(driver.heading:Lerp(desired,t)).Unit end
	end

	local turnFactor=math.clamp(driver.heading:Dot(desired),0,1)
	local targetSpeed=cruiseSpeed*(TURN_SLOWDOWN+(1-TURN_SLOWDOWN)*turnFactor)
	if driver.speed<targetSpeed then
		driver.speed=math.min(targetSpeed,driver.speed+ACCEL*dt)
	else
		driver.speed=math.max(targetSpeed,driver.speed-BRAKE*dt)
	end

	local moveDist=math.min(driver.speed*dt,if driver.resident then flatToTarget.Magnitude else math.huge)
	local newFlat=Vector3.new(carPos.X+driver.heading.X*moveDist,0,carPos.Z+driver.heading.Z*moveDist)
	local referenceY=roadSurfaceY or targetPos.Y
	local desiredY
	if driver.resident then
		-- v106: raycast ONCE when a resident enters a mapped road, then cache the
		-- vertical correction between mapper Y and the actual physical road surface.
		-- This keeps the v105 performance win without assuming every road surface is
		-- exactly 3 studs below its mapper points (which phased cars into some roads).
		if driver.surfaceRoad~=driver.road or driver.surfaceCorrection==nil then
			local groundY=snapToGround(Vector3.new(newFlat.X,referenceY,newFlat.Z),car,referenceY)
			driver.surfaceRoad=driver.road
			driver.surfaceCorrection=if groundY then groundY-referenceY else -3.0
		end
		desiredY=referenceY+(driver.surfaceCorrection or -3.0)+pivotGroundOffset(driver,car)+SURFACE_CLEARANCE
	else
		local groundY=snapToGround(Vector3.new(newFlat.X,referenceY,newFlat.Z),car,referenceY)
		if groundY then
			desiredY=groundY+pivotGroundOffset(driver,car)+SURFACE_CLEARANCE
		else
			desiredY=referenceY-3.0+pivotGroundOffset(driver,car)+SURFACE_CLEARANCE
		end
	end

	if driver.y==nil or math.abs(driver.y-desiredY)>3 then
		driver.y=desiredY
	else
		local maxStep=MAX_VERTICAL_SPEED*dt
		driver.y+=math.clamp(desiredY-driver.y,-maxStep,maxStep)
	end

	local newPos=Vector3.new(newFlat.X,driver.y,newFlat.Z)
	driver.pos=newPos
	if not driver.deferPivot then
        car:PivotTo(CFrame.lookAt(newPos,newPos+driver.heading))
    end
	if spinWheels then spinWheels(driver.speed>0.5) end
	return flatToTarget.Magnitude
end

function RoadDriving.step(driver,car,dt,cruiseSpeed,spinWheels)
	local road=driver.network[driver.road]
	if not road then return end
	local carPos=driver.pos or car:GetPivot().Position
	local baseTarget=road.points[driver.node]
	if not baseTarget then
		driver.tripComplete=true
		return
	end

	local flat=Vector3.new(baseTarget.X-carPos.X,0,baseTarget.Z-carPos.Z)
	local arrived=flat.Magnitude<=ARRIVE_RADIUS
    if driver.resident then
        local previous=road.points[driver.node-driver.dir]
        if previous then
            local seg=Vector3.new(baseTarget.X-previous.X,0,baseTarget.Z-previous.Z)
            if seg.Magnitude>0.1 then
                local right=Vector3.new(-seg.Unit.Z,0,seg.Unit.X)
                local endpoint=baseTarget+right*(driver.smoothLaneOffset or laneCenter(road,driver.lane))
                local delta=Vector3.new(endpoint.X-carPos.X,0,endpoint.Z-carPos.Z)
                arrived=delta.Magnitude<=math.clamp(3+(driver.speed or 0)*0.12,3,6)
                    or (delta:Dot(seg.Unit)<0 and math.abs(delta:Dot(right))<7)
            end
        end
    end
    if arrived then
		advance(driver)
		road=driver.network[driver.road]
		baseTarget=road and road.points[driver.node]
		if not baseTarget then return end
	end

	local previousIndex=driver.node-driver.dir
	local previous=(previousIndex>=1 and previousIndex<=#road.points) and road.points[previousIndex] or carPos
	local segment=Vector3.new(baseTarget.X-previous.X,0,baseTarget.Z-previous.Z)
	local target=baseTarget
	if segment.Magnitude>0.1 then
		local forward=segment.Unit
		local right=Vector3.new(-forward.Z,0,forward.X)
		-- pick a lane whenever we turn onto a new road; laneOffset nudges (yielding) stay relative
		if driver.laneRoad~=driver.road then
			driver.laneRoad=driver.road
			driver.lane=pickLane(driver,road)
		end
		target=baseTarget+right*((driver.laneOffset or DEFAULT_LANE_WIDTH)-DEFAULT_LANE_WIDTH+laneCenter(road,driver.lane))
	end

	local surfaceY=baseTarget.Y
    local cornerFactor=1
    if driver.resident then target,surfaceY,cornerFactor=residentTarget(driver,road,carPos,baseTarget,dt) end
    local desired=cruiseSpeed
    if driver.resident then
		desired=math.min(desired,(road.speedLimit or DEFAULT_SPEED_LIMIT.Local)*(driver.speedFactor or 1))
	end
	if driver.resident then desired*=cornerFactor end
	desired=intersectionControlledSpeed(driver,desired)
	moveToward(driver,car,dt,target,desired,spinWheels,surfaceY)
end

function RoadDriving.approach(driver,car,dt,targetPos,cruiseSpeed,spinWheels)
	return moveToward(driver,car,dt,targetPos,cruiseSpeed,spinWheels)
end

local junctionCount,signalCount,stopCount=0,0,0
local preview=RoadDriving.loadNetwork()
if preview and preview._junctions then
	junctionCount=#preview._junctions
	for _,j in ipairs(preview._junctions) do
		if j.control=="Signal" then signalCount+=1 else stopCount+=1 end
	end
end
_G.RoadDriving=RoadDriving
print(("[RoadDriving] v106 cached-surface road graph ready - %d road(s), %d inferred intersection(s): %d signal / %d stop"):format(
	#preview,junctionCount,signalCount,stopCount))
