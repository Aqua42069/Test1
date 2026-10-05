-- CivilianTrafficServer
-- v64 resident traffic rebuild.
-- Cars now behave as independent city drivers rather than identical waypoint
-- followers. Each driver has a temperament, destination, following distance,
-- road-class speed preference, traffic-signal/stop compliance, congestion
-- rerouting, emergency yielding and stuck recovery.

-- v284: replaced by CityTraffic. This only runs with Workspace attribute TrafficV2 = false.
if workspace:GetAttribute("TrafficV2") ~= false then return end

local ServerStorage=game:GetService("ServerStorage")
local Players=game:GetService("Players")
local CollectionService=game:GetService("CollectionService")

local TRAFFIC_COUNT=180 -- dense city traffic, reduced from 360 after live congestion/performance testing
local CRUISE_CAP=36
local RESPAWN_DELAY=4 -- keep wrecks briefly; refill loop owns replacements (prevents population creep)
local SPAWN_MIN_GAP=42
local SENSOR_INTERVAL=0.34
local OBSTACLE_SENSOR_INTERVAL=999 -- v105: grid spacing replaces per-car obstacle raycasts
local SIM_STEP=1/10 -- v105 near-player traffic; farther traffic uses cheaper LOD ticks
local GRID_REBUILD_INTERVAL=0.34
local EMERGENCY_INDEX_INTERVAL=0.80
local GRID_SIZE=90
local MAX_SPAWNS_PER_TICK=3
local CAR_TYPES={"Sedan","SUV","Van"}

local RoadDriving
do
	local waited=0
	while not _G.RoadDriving and waited<15 do
		task.wait(0.1)
		waited+=0.1
	end
	RoadDriving=_G.RoadDriving
	if not RoadDriving then
		warn("[CivilianTrafficServer] RoadDriving unavailable")
		return
	end
end

local network=RoadDriving.loadNetwork()

-- v210: residents don't drive out to the prison. Roads within PRISON_RADIUS of
-- the CorrectionalFacility, plus anything only reachable through them (the
-- dead-end spur out there), are left to police transports.
local PRISON_RADIUS=600
local restrictedRoads={}
do
	local facility=workspace:FindFirstChild("CorrectionalFacility")
	local prisonPos=facility and facility:IsA("Model") and facility:GetPivot().Position
	if prisonPos then
		for idx,road in ipairs(network) do
			for _,p in ipairs(road.points or {}) do
				if Vector3.new(p.X-prisonPos.X,0,p.Z-prisonPos.Z).Magnitude<=PRISON_RADIUS then
					restrictedRoads[idx]=true
					break
				end
			end
		end
		-- whatever is cut off from the main (largest) city network by those
		-- roads is part of the spur too
		local graph=RoadDriving.buildGraph(network)
		local component,best,bestSize={},nil,0
		for start=1,#network do
			if not restrictedRoads[start] and not component[start] then
				local members={start};component[start]=start
				local q=1
				while q<=#members do
					local u=members[q];q+=1
					for _,edge in ipairs(graph[u] or {}) do
						local v=edge.road
						if not restrictedRoads[v] and not component[v] then component[v]=start;table.insert(members,v) end
					end
				end
				if #members>bestSize then best,bestSize=start,#members end
			end
		end
		local count=0
		for idx=1,#network do
			if not restrictedRoads[idx] and component[idx]~=best then restrictedRoads[idx]=true end
			if restrictedRoads[idx] then count+=1 end
		end
		print(("[CivilianTrafficServer] %d prison-area road(s) closed to resident traffic"):format(count))
	end
end
_G.TrafficRestrictedRoads=restrictedRoads

local trafficRegistry={}
local roadOccupancy={}
local trafficGrid={}
_G.CityRoadOccupancy=roadOccupancy

local function gridKey(position)
	return math.floor(position.X/GRID_SIZE)..":"..math.floor(position.Z/GRID_SIZE)
end

local function rebuildTrafficGrid()
	table.clear(trafficGrid)
	for car,state in pairs(trafficRegistry) do
		if car.Parent and state.driver then
			local position=state.position or state.driver.pos or car:GetPivot().Position
			state.position=position
			local key=gridKey(position)
			local bucket=trafficGrid[key]
			if not bucket then
				bucket={}
				trafficGrid[key]=bucket
			end
			table.insert(bucket,state)
		end
	end
end

local function nearbyTraffic(position)
	local gx=math.floor(position.X/GRID_SIZE)
	local gz=math.floor(position.Z/GRID_SIZE)
	local result={}
	for x=gx-1,gx+1 do
		for z=gz-1,gz+1 do
			local bucket=trafficGrid[x..":"..z]
			if bucket then
				for _,state in ipairs(bucket) do
					table.insert(result,state)
				end
			end
		end
	end
	return result
end

task.spawn(function()
	while true do
		rebuildTrafficGrid()
		task.wait(GRID_REBUILD_INTERVAL)
	end
end)

local PROFILES={
	{name="Cautious",speed=0.86,follow=34,accelMood=0.9},
	{name="Normal",speed=0.98,follow=28,accelMood=1.0},
	{name="Normal",speed=1.02,follow=27,accelMood=1.0},
	{name="Confident",speed=1.08,follow=24,accelMood=1.08},
}

local function randomProfile()
	local p=PROFILES[math.random(1,#PROFILES)]
	return {
		name=p.name,
		speed=p.speed*(0.97+math.random()*0.06),
		follow=p.follow+(math.random()-0.5)*3,
		accelMood=p.accelMood,
	}
end

local function changeOccupancy(state,newRoad)
	if state.lastRoad and network[state.lastRoad] then
		local oldName=network[state.lastRoad].name
		roadOccupancy[oldName]=math.max(0,(roadOccupancy[oldName] or 1)-1)
	end
	state.lastRoad=newRoad
	if newRoad and network[newRoad] then
		local name=network[newRoad].name
		roadOccupancy[name]=(roadOccupancy[name] or 0)+1
	end
end

local roadSpawnInfo={}
for roadIdx,road in ipairs(network) do
	local segments={}
	local totalLength=0
	for i=1,#road.points-1 do
		local length=(road.points[i+1]-road.points[i]).Magnitude
		if length>8 then
			totalLength+=length
			table.insert(segments,{index=i,length=length,cumulative=totalLength})
		end
	end
	-- Capacity is intentionally conservative. Long roads can absorb more resident
	-- cars; tiny connector roads and intersection stubs cannot.
	local usefulLanes=math.max(1,math.min(tonumber(road.lanes) or 1,2))
	roadSpawnInfo[roadIdx]={segments=segments,length=totalLength,capacity=math.max(1,math.floor(totalLength/95)*usefulLanes)}
end

local function chooseSpawnRoad()
	if #network==0 then return nil end
	local best,bestScore=nil,math.huge
	for _=1,math.min(40,#network*4) do
		local idx=math.random(1,#network)
		local road=network[idx]
		local info=roadSpawnInfo[idx]
		if info and info.length>20 and #info.segments>0 and not restrictedRoads[idx] then
			local occupancy=roadOccupancy[road.name] or 0
			local fill=occupancy/math.max(1,info.capacity)
			local classPenalty=(road.roadType=="Primary" and 0) or (road.roadType=="Secondary" and 0.15) or 0.55
			-- Fill ratio instead of raw car count stops short roads from competing
			-- equally with long arterials and spreads the population city-wide.
			local score=fill*8+classPenalty+math.random()*0.9
			if score<bestScore then
				best,bestScore=idx,score
			end
		end
	end
	return best
end

local function spawnClear(position)
	for _,state in ipairs(nearbyTraffic(position)) do
		local car=state.car
		if car and car.Parent then
			local otherPos=state.position or state.driver.pos or car:GetPivot().Position
			local d=(otherPos-position).Magnitude
			if d<SPAWN_MIN_GAP then return false end
		end
	end
	return true
end

local function chooseSpawn()
	if #network==0 then return nil,nil,nil,nil end
	for _=1,45 do
		local roadIdx=chooseSpawnRoad()
		local road=roadIdx and network[roadIdx]
		local info=roadIdx and roadSpawnInfo[roadIdx]
		if road and info and info.length>20 and #info.segments>0 then
			-- Pick a segment proportional to physical length, then place the car well
			-- inside the segment. The old node-based spawning concentrated cars at
			-- intersections/corners and caused instant traffic knots.
			local roll=math.random()*info.length
			local chosen=info.segments[#info.segments]
			for _,segment in ipairs(info.segments) do
				if roll<=segment.cumulative then chosen=segment break end
			end
			local a=road.points[chosen.index]
			local b=road.points[chosen.index+1]
			local t=0.18+math.random()*0.64
			local position=a:Lerp(b,t)
			if spawnClear(position) then
				local dir=road.oneWay and 1 or ((math.random()<0.5) and 1 or -1)
				local nodeIdx=if dir==1 then chosen.index+1 else chosen.index
				return roadIdx,nodeIdx,dir,position
			end
		end
	end
	return nil,nil,nil,nil
end

local function nearestTrafficAhead(state)
	local car=state.car
	local driver=state.driver
	local pos=state.position or driver.pos or car:GetPivot().Position
	local heading=driver.heading
	local best,leadSpeed=math.huge,0
	for _,other in ipairs(nearbyTraffic(pos)) do
		local otherCar=other.car
		if otherCar~=car and otherCar and otherCar.Parent and other.driver then
			-- Registered road traffic only blocks this lane when travelling the same road/direction.
			local sameRoad=(other.driver.road==driver.road)
			local sameLane=(other.driver.lane==nil or driver.lane==nil or other.driver.lane==driver.lane)
			if sameRoad and sameLane and other.driver.dir==driver.dir then
				local otherPos=other.position or other.driver.pos or otherCar:GetPivot().Position
				local delta=Vector3.new(otherPos.X-pos.X,0,otherPos.Z-pos.Z)
				local d=delta.Magnitude
				if d>0.1 and d<70 and heading:Dot(delta.Unit)>0.55 then
					local longitudinal=delta:Dot(heading)
					if longitudinal<best then best=longitudinal;leadSpeed=other.driver.speed or 0 end
				end
			end
		end
	end
	return best,leadSpeed
end

local function laneClear(state,lane)
	local driver=state.driver
	local road=network[driver.road]
	if not road or lane<1 or lane>(road.lanes or 1) then return false end
	local pos=state.position or driver.pos or state.car:GetPivot().Position
	local heading=driver.heading
	for _,other in ipairs(nearbyTraffic(pos)) do
		if other~=state and other.car and other.car.Parent and other.driver
			and other.driver.road==driver.road and other.driver.lane==lane then
			local otherPos=other.position or other.driver.pos or other.car:GetPivot().Position
			local delta=Vector3.new(otherPos.X-pos.X,0,otherPos.Z-pos.Z)
			local longitudinal=delta:Dot(heading)
			if longitudinal>-15 and longitudinal<30 then
				return false
			end
		end
	end
	return true
end

local function tryLaneChange(state)
	local now=os.clock()
	if state.nextLaneChange and now<state.nextLaneChange then return false end
	state.nextLaneChange=now+2.5+math.random()*1.5
	local driver=state.driver
	local road=network[driver.road]
	if not road or (road.lanes or 1)<=1 then return false end
	local current=driver.lane or 1
	local candidates={}
	if current>1 then table.insert(candidates,current-1) end
	if current<(road.lanes or 1) then table.insert(candidates,current+1) end
	if #candidates==2 and math.random()<0.5 then
		candidates[1],candidates[2]=candidates[2],candidates[1]
	end
	for _,lane in ipairs(candidates) do
		if laneClear(state,lane) then
			driver.lane=lane
			state.blockedSince=nil
			return true
		end
	end
	return false
end

local function vehicleObstacleAhead(state)
	local car=state.car
	local basePos=state.position or state.driver.pos or car:GetPivot().Position
	local pos=basePos+Vector3.new(0,1.4,0)
	local heading=state.driver.heading
	local params=state.obstacleParams
    if not params then
        params=RaycastParams.new();params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances={car};state.obstacleParams=params
    end
	local hit=workspace:Raycast(pos,heading*34,params)
	if not hit then return math.huge end
	local model=hit.Instance:FindFirstAncestorOfClass("Model")
	if model and model~=car and model:FindFirstChildWhichIsA("VehicleSeat",true) then
		return (hit.Position-pos).Magnitude
	end
	return math.huge
end

local emergencyVehicles={}

-- v164: PoliceSystem vehicles live inside its runtime folders, not necessarily as
-- direct Workspace children. The old index therefore missed them completely and
-- resident traffic would PivotTo straight through a custody cruiser. Index nested
-- priority vehicles and include non-siren custody/medical transports explicitly.
-- v191: each entry also carries a measured ground speed. Police cruisers keep
-- Emergency=true after they park at a scene; the old index treated a parked
-- cruiser like one running code, so every resident car within 30 studs "ahead"
-- (any lane, even across the road) braked to 0 and - because its desired speed
-- was 0 - the stuck recovery never fired. Those cars waited forever and the
-- whole block piled up behind them.
local emergencyLast=setmetatable({},{__mode="k"})
local EMERGENCY_MOVING_SPEED=3
task.spawn(function()
	while true do
		local now=os.clock()
		local list={}
		-- v195 perf: every priority vehicle is a PoliceSystem van under
		-- Workspace.PoliceAI.Vehicles. Walking all ~90k workspace instances every
		-- 0.8s here was a major server stutter source.
		local policeRoot=workspace:FindFirstChild("PoliceAI")
		local vehicles=policeRoot and policeRoot:FindFirstChild("Vehicles")
		for _,obj in ipairs(if vehicles then vehicles:GetChildren() else {}) do
			if obj:IsA("Model") then
				local emergency=obj:GetAttribute("Emergency")
				if emergency==true or obj:GetAttribute("CustodyTransport") or obj:GetAttribute("MedicalTransport") or obj:GetAttribute("IncidentResponse") then
					if obj:FindFirstChildWhichIsA("BasePart",true) then
						local pos=obj:GetPivot().Position
						local last=emergencyLast[obj]
						local velocity=Vector3.zero
						if last and now-last.t>0.05 then
							local v=(pos-last.pos)/(now-last.t)
							velocity=Vector3.new(v.X,0,v.Z)
						end
						emergencyLast[obj]={pos=pos,t=now}
						table.insert(list,{model=obj,pos=pos,velocity=velocity,moving=velocity.Magnitude>EMERGENCY_MOVING_SPEED})
					end
				end
			end
		end
		emergencyVehicles=list
		task.wait(EMERGENCY_INDEX_INTERVAL)
	end
end)

-- Relations:
--   overlap   a priority vehicle is on top of us (ghosted transport)
--   ahead     moving, in our road corridor, travelling our way
--   oncoming  moving, in our road corridor, coming toward us
--   behind    moving, in our corridor behind us -> pull aside, keep clearing
--   parked    stationary and physically in OUR lane ahead -> a lane obstacle
-- A stationary priority vehicle that is not in our lane is ignored.
local function emergencyNearby(state)
	local now=os.clock()
	if state.nextEmergencyCheck and now<state.nextEmergencyCheck then
		return state.emergencyNear,state.emergencyRelation,state.emergencyDistance or math.huge,state.emergencySpeed or 0
	end
	state.nextEmergencyCheck=now+0.30+math.random()*0.10
	state.emergencyNear=false;state.emergencyRelation=nil;state.emergencyDistance=math.huge;state.emergencySpeed=0
	local pos=state.position or state.driver.pos or state.car:GetPivot().Position
	local heading=state.driver.heading
	local right=Vector3.new(-heading.Z,0,heading.X)
	for _,info in ipairs(emergencyVehicles) do
		local obj=info.model
		if obj.Parent and obj~=state.car then
			local delta=Vector3.new(info.pos.X-pos.X,0,info.pos.Z-pos.Z)
			local d=delta.Magnitude
			if d<70 and d<state.emergencyDistance then
				local along=delta:Dot(heading)
				local lateral=math.abs(delta:Dot(right))
				local relation=nil
				if d<16 and info.moving then
					relation="overlap"
				elseif info.moving then
					if lateral<12 then
						if along>0 then
							relation=if info.velocity:Dot(heading)<-EMERGENCY_MOVING_SPEED then "oncoming" else "ahead"
						else
							relation="behind"
						end
					end
				elseif along>0 and along<45 and lateral<5.5 then
					relation="parked";d=along
				end
				if relation then
					state.emergencyNear=true;state.emergencyDistance=d;state.emergencyRelation=relation
					state.emergencySpeed=math.max(0,info.velocity:Dot(heading));state.emergencyPos=info.pos
				end
			end
		end
	end
	return state.emergencyNear,state.emergencyRelation,state.emergencyDistance,state.emergencySpeed
end

local function desiredTrafficSpeed(state)
	local driver=state.driver
	local road=driver and network[driver.road]
	local profile=state.profile
	local speed=(road and road.speedLimit or 20)*(profile.speed or 1)
	local now=os.clock()

	if not state.nextSenseAt or now>=state.nextSenseAt then
		state.nextSenseAt=now+SENSOR_INTERVAL+(math.random()*0.05)
		state.cachedTrafficGap,state.leadSpeed=nearestTrafficAhead(state)
	end
	-- v105: resident-vs-resident spacing is already represented by the spatial grid.
	-- Per-car forward raycasts duplicated that work and scaled badly at 180 cars.
	local gap=state.cachedTrafficGap or math.huge
    if (state.simStep or SIM_STEP)<=0.1 then
        if now>=(state.nextObstacleSenseAt or 0) then
            state.nextObstacleSenseAt=now+0.5+math.random()*0.15
            state.cachedObstacleGap=vehicleObstacleAhead(state)
        end
        -- While easing around a parked priority vehicle its body is expected
        -- in the forward ray; the pass itself is speed-capped below.
        if (state.cachedObstacleGap or math.huge)<gap and not state.passingParked then gap=state.cachedObstacleGap;state.leadSpeed=0 end
    end
	local follow=profile.follow or 28
	local pos=state.position or driver.pos or state.car:GetPivot().Position
	local heading=driver.heading

	local priorityNear,relation,priorityDist,prioritySpeed=emergencyNearby(state)
	-- Easing around a parked priority vehicle continues until it is behind us.
	if state.passingParked then
		local target=state.passingParked
		local along=Vector3.new(target.X-pos.X,0,target.Z-pos.Z):Dot(heading)
		if along<-8 or now-(state.passingStarted or now)>20 or not network[driver.road] or driver.road~=state.passingRoad then
			state.passingParked=nil;state.passingStarted=nil;state.passingRoad=nil;state.parkedBlockSince=nil
		end
	end
	if priorityNear and relation=="parked" and not state.passingParked then
		-- Queue behind it like any stopped car, then try a free adjacent lane,
		-- then ease around it at walking pace. Never wait on it indefinitely.
		gap=math.min(gap,priorityDist);state.leadSpeed=0
		state.parkedBlockSince=state.parkedBlockSince or now
		if now-state.parkedBlockSince>2 then
			if tryLaneChange(state) then
				state.parkedBlockSince=nil
			elseif now-state.parkedBlockSince>3.5 then
				state.passingParked=state.emergencyPos;state.passingStarted=now;state.passingRoad=driver.road
			end
		end
	elseif not (priorityNear and relation=="parked") and not state.passingParked then
		state.parkedBlockSince=nil
	end

	if gap<follow*0.72 then
		state.blockedSince=state.blockedSince or now
		-- Dense traffic should feel like traffic, not ghosts: cars queue first,
		-- then attempt a legal adjacent-lane pass when the road has room.
		if now-state.blockedSince>1.25 and tryLaneChange(state) then
			gap=math.huge
			state.cachedTrafficGap=math.huge
			gap=math.min(gap,state.cachedObstacleGap or math.huge)
		end
	else
		state.blockedSince=nil
	end

    if gap<math.huge then
        local standstill=14
        local desiredGap=standstill+math.max(driver.speed or 0,0)*0.85
        local followSpeed=math.max(0,(state.leadSpeed or 0)+(gap-desiredGap)*0.65)
        local safeSpeed=math.sqrt(2*22*math.max(0,gap-standstill))
        speed=math.min(speed,followSpeed,safeSpeed)
        if gap<=standstill then speed=0 end
    end

	-- v278: a traffic stop (CityLife.Stops sets PullOver): ease to the kerb and stop until released
	if state.car:GetAttribute("PullOver") then
		state.pullStart=state.pullStart or now
		driver.laneOffset=driver.baseLaneOffset+4.5
		state.car:SetAttribute("TrafficYielding",true)
		return math.max(0,math.min(speed,12-(now-state.pullStart)*4))
	elseif state.pullStart then
		state.pullStart=nil
	end
	if state.passingParked then
		-- Swing toward the centre line past the parked unit, at walking pace.
		driver.laneOffset=driver.baseLaneOffset-6.5
		state.car:SetAttribute("TrafficYielding",true)
		-- The lane offset eases over ~2.5s; creep while swinging out.
		speed=math.min(speed,if now-(state.passingStarted or now)<2.5 then 2.5 else 6)
	elseif priorityNear and relation~="parked" then
		-- Give moving police/EMS a real corridor: pull toward the kerb. Traffic
		-- in front of a unit running code keeps moving aside at a reduced speed
		-- (it no longer brakes to a dead stop in the unit's path).
		driver.laneOffset=driver.baseLaneOffset+3.4
		state.car:SetAttribute("TrafficYielding",true)
		if relation=="ahead" then
			speed=math.min(speed,math.max(6,(prioritySpeed or 0)*0.9))
		elseif relation=="oncoming" then
			speed=math.min(speed,10)
		elseif relation=="overlap" then
			-- If an anchored resident car has already visually overlapped a ghost
			-- transport, let it clear forward as soon as its own lane has room.
			if (state.cachedTrafficGap or math.huge)>22 then speed=math.max(speed,7) end
			speed=math.min(speed,12)
		else
			speed=math.min(speed,14)
		end
	else
		driver.laneOffset=driver.baseLaneOffset
		state.car:SetAttribute("TrafficYielding",nil)
	end
	return math.clamp(speed,0,CRUISE_CAP)
end

local function standOn(model,position)
	local _,size=model:GetBoundingBox()
	model:PivotTo(CFrame.new(position+Vector3.new(0,size.Y/2+0.05,0)))
end

local WHEEL_RADIUS=1.5
local function collectWheelHinges(car)
	local hinges={}
	for _,obj in ipairs(car:GetDescendants()) do
		if obj:IsA("HingeConstraint") and obj.Name=="Spin" then
			table.insert(hinges,obj)
		end
	end
	return hinges
end

local function spinWheels(state,moving,speed)
	local angular=moving and (speed/WHEEL_RADIUS) or 0
	if state.lastWheelAngular and math.abs(state.lastWheelAngular-angular)<0.2 then return end
	state.lastWheelAngular=angular
	for _,hinge in ipairs(state.wheelHinges) do
		if hinge.Parent then hinge.AngularVelocity=angular end
	end
end

local function reportMurder(killer)
	local reportCrime=ServerStorage:FindFirstChild("ReportCrime")
	if reportCrime and killer and killer:IsA("Player") then
		reportCrime:Invoke(killer,"Murder",2)
	end
end

local pedTemplates=ServerStorage:WaitForChild("CivilianTemplates",15)
local pedPool=pedTemplates and pedTemplates:GetChildren() or {}
local carTemplates=ServerStorage:WaitForChild("CarTemplates",15)

local function paint(car)
	local colors={
		Color3.fromRGB(180,40,40),Color3.fromRGB(40,80,170),Color3.fromRGB(230,230,230),
		Color3.fromRGB(30,30,35),Color3.fromRGB(200,170,40),Color3.fromRGB(60,110,70),
		Color3.fromRGB(110,80,150),Color3.fromRGB(165,165,170),
	}
	local color=colors[math.random(1,#colors)]
	for _,part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") and part.Name=="Primary" then part.Color=color end
	end
end

-- v191 destination spreading. The shared chooser weighted roads only by class
-- and current occupancy, so over time the whole population converged on the
-- same few arterials and queued there. Each resident now prefers a destination
-- across town, avoids its own last few destinations, and avoids roads that
-- many other residents are already heading to.
local destinationClaims={}
local roadMidpoints={}
local function roadMidpoint(roadIdx)
	local mid=roadMidpoints[roadIdx]
	if not mid then
		local pts=network[roadIdx].points
		mid=pts[math.max(1,math.ceil(#pts/2))]
		roadMidpoints[roadIdx]=mid
	end
	return mid
end

local function claimDestination(state,roadIdx)
	if state.destination then
		destinationClaims[state.destination]=math.max(0,(destinationClaims[state.destination] or 1)-1)
	end
	state.destination=roadIdx
	if roadIdx then destinationClaims[roadIdx]=(destinationClaims[roadIdx] or 0)+1 end
end

local function chooseTripDestination(state,tried)
	local driver=state.driver
	local graph=RoadDriving.buildGraph(network)
	local seen={[driver.road]=true}
	local queue={driver.road}
	local q=1
	local choices,total={},0
	local pos=state.position or driver.pos or state.car:GetPivot().Position
	local recent=state.recentDestinations or {}
	while q<=#queue do
		local u=queue[q];q+=1
		for _,edge in ipairs(graph[u] or {}) do
			local i=edge.road
			if not seen[i] then
				seen[i]=true
				table.insert(queue,i)
				-- v215: never a dead end as a destination - cars that end a trip where
				-- they can't continue sit there and the whole city piles up behind them
				if not tried[i] and not restrictedRoads[i] and #(graph[i] or {})>0 then
					local r=network[i]
					local classWeight=(r.roadType=="Primary" and 1.3) or (r.roadType=="Secondary" and 1.1) or 0.75
					local congestion=roadOccupancy[r.name] or 0
					local claims=destinationClaims[i] or 0
					local mid=roadMidpoint(i)
					local distance=math.clamp(Vector3.new(mid.X-pos.X,0,mid.Z-pos.Z).Magnitude/350,0.25,1.6)
					local repeatPenalty=if table.find(recent,i) then 0.15 else 1
					local weight=classWeight*distance*repeatPenalty/(1+congestion*0.5+claims*0.9)
					total+=weight
					table.insert(choices,{road=i,ceiling=total})
				end
			end
		end
	end
	if #choices==0 then return nil end
	local roll=math.random()*total
	for _,choice in ipairs(choices) do
		if roll<=choice.ceiling then return choice.road end
	end
	return choices[#choices].road
end

local function newTrip(state)
	local driver=state.driver
	if not driver or not network[driver.road] then return false end
	-- v154: resident traffic is continuous. A car that reaches one destination must
	-- immediately be able to choose another instead of becoming a permanent parked
	-- obstacle when one randomly selected route cannot be planned.
	local tried={}
	for _=1,math.min(10,math.max(2,#network)) do
		local destination=chooseTripDestination(state,tried) or RoadDriving.chooseDestinationRoad(network,driver.road,roadOccupancy)
		if destination and restrictedRoads[destination] then tried[destination]=true;destination=nil end
		if destination and not tried[destination] then
			tried[destination]=true
			local route=RoadDriving.planTrip(driver,destination,roadOccupancy,{emergency=false})
			if route then
				driver.tripComplete=false
				claimDestination(state,destination)
				state.recentDestinations=state.recentDestinations or {}
				table.insert(state.recentDestinations,destination)
				while #state.recentDestinations>3 do table.remove(state.recentDestinations,1) end
				state.nextTripCheck=os.clock()+math.random(20,38)
				state.tripFailures=0
				state.tripSerial=(state.tripSerial or 0)+1
				state.car:SetAttribute("TrafficTrip",state.tripSerial)
				return true
			end
		end
	end
	state.tripFailures=(state.tripFailures or 0)+1
	return false
end

local function trafficSimStep(state)
	local now=os.clock()
	if state.nextLodAt and now<state.nextLodAt then return state.simStep or SIM_STEP end
	state.nextLodAt=now+0.9+math.random()*0.25
	local pos=state.position or state.driver.pos or state.car:GetPivot().Position
	local nearest=math.huge
	for _,plr in Players:GetPlayers() do
		local char=plr.Character;local root=char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then nearest=math.min(nearest,(root.Position-pos).Magnitude) end
	end
	if nearest<=500 then state.simStep=1/10
	elseif nearest<=1050 then state.simStep=1/4
	else state.simStep=1/2 end
	return state.simStep
end

local function runCar(car,driverNpc,driverHumanoid,driveSeat,driver)
	local state={
		car=car,
		driverNpc=driverNpc,
		driver=driver,
		profile=randomProfile(),
		lastRoad=driver and driver.road or nil,
		emergencyNear=false,
		nextTripCheck=0,
		dwellUntil=0,
		lastProgressPos=car:GetPivot().Position,
		lastProgressAt=os.clock(),
		stuckSince=nil,
		blockedSince=nil,
		nextLaneChange=0,
		nextSenseAt=0,
		cachedTrafficGap=math.huge,
		cachedObstacleGap=math.huge,
		nextObstacleSenseAt=0,
		position=driver and driver.pos or car:GetPivot().Position,
		wheelHinges=collectWheelHinges(car),
		lastWheelAngular=nil,
		simStep=SIM_STEP,
		nextLodAt=0,
	}
	trafficRegistry[car]=state

	driver.resident=true
	driver.vehicleKey=car
	driver.emergency=false
	driver.speedFactor=state.profile.speed
	car:SetAttribute("TrafficDriverProfile",state.profile.name)

	if state.lastRoad and network[state.lastRoad] then
		local name=network[state.lastRoad].name
		roadOccupancy[name]=(roadOccupancy[name] or 0)+1
	end

	newTrip(state)

    state.humanoid=driverHumanoid
    state.nextStep=os.clock()+math.random()*SIM_STEP
    state.lastStep=os.clock()
end

local function updateTraffic(state,now,dt)
    local car,driver,driverHumanoid=state.car,state.driver,state.humanoid
    if not car.Parent or driverHumanoid.Health<=0 then return false end
		if car:GetAttribute("TrafficStolen") then return false end
		if car:GetAttribute("TrafficRecycle") then return false end -- v278: driver arrested / towed
		if not network[driver.road] then return false end
		if driver.road~=state.lastRoad then changeOccupancy(state,driver.road) end

		
		if driver.tripComplete then
			if state.dwellUntil==0 then
				state.dwellUntil=now+math.random(1,3)
				driver.speed=math.min(driver.speed,4)
			elseif now>=state.dwellUntil then
				if newTrip(state) then
					state.dwellUntil=0
				elseif (state.tripFailures or 0)>=4 then
					-- Topology can temporarily reject every destination (for example while
					-- an intersection connection is being rebuilt). Keep driving the current
					-- mapped road instead of parking forever, then ask for a new trip again.
					driver.route=nil;driver.nextConnection=nil;driver.destinationRoad=nil;driver.destinationNode=nil
					driver.tripComplete=false;state.dwellUntil=0;state.tripFailures=0
					state.nextTripCheck=now+2
				else
					state.dwellUntil=now+1.25
				end
			end
		elseif now>=state.nextTripCheck and not driver.route then
			if not newTrip(state) then state.nextTripCheck=now+1.5 end
		end

		local desired=state.dwellUntil>now and 0 or desiredTrafficSpeed(state)
		dt=math.min(dt,0.5)
        if not car.Parent or driverHumanoid.Health<=0 then return false end
        driver.deferPivot=true
        local count=math.max(1,math.ceil(dt/0.05))
        for _=1,count do RoadDriving.step(driver,car,dt/count,desired) end
        driver.deferPivot=nil
        local pose=CFrame.lookAt(driver.pos,driver.pos+driver.heading)
        -- v195 perf: cars far from every player (LOD tick >= 1/4s) still simulate
        -- but only move their model every ~2s; PivotTo on an anchored car moves
        -- and replicates every part. The next near tick snaps them into place.
        local farAway=(state.simStep or SIM_STEP)>=0.25
        if farAway and now<(state.nextFarPivotAt or 0) then
            -- skip the visual update this tick
        elseif not state.lastPose or (pose.Position-state.lastPose.Position).Magnitude>0.015 or pose.LookVector:Dot(state.lastPose.LookVector)<0.99999 then
            car:PivotTo(pose);car:SetAttribute("TrafficPose",pose);state.lastPose=pose
            if farAway then state.nextFarPivotAt=now+2 end
        end
        spinWheels(state,(driver.speed or 0)>0.5,driver.speed or 0)
		state.position=driver.pos or car:GetPivot().Position


		-- Stuck recovery never drives off-road. First re-route; only after a
		-- prolonged failure is the car recycled by normal cleanup.
		if now-state.lastProgressAt>=4 then
			local current=state.position or driver.pos or car:GetPivot().Position
			local moved=(current-state.lastProgressPos).Magnitude
			if moved<2.5 and desired>5 then
				state.stuckSince=state.stuckSince or now
				if now-state.stuckSince>8 then
					driver.route=nil
					driver.nextConnection=nil
					driver.tripComplete=true
					state.dwellUntil=now+1
				end
				if now-state.stuckSince>45 then
					driverHumanoid.Health=0
					return false
				end
			else
				state.stuckSince=nil
			end
			-- v191 stationary watchdog. The check above only counts time when the
			-- car WANTS to move (desired>5); a car held at 0 (queued behind a
			-- blockage, a stale junction queue, a parked unit) could wait forever.
			-- Legitimate waits (a red light is at most ~13s) are far shorter.
			if moved<2.5 and state.dwellUntil<=now then
				state.stillSince=state.stillSince or now
				local still=now-state.stillSince
				if still>12 and not state.stillRerouted then
					-- Pick a new trip from here; planTrip may turn the car around.
					state.stillRerouted=true
					driver.route=nil;driver.nextConnection=nil;driver.tripComplete=true
					state.dwellUntil=now+1
					state.passingParked=nil;state.parkedBlockSince=nil
				end
				if still>40 then
					-- Recycle only out of sight (or after a very long hold) so the
					-- refill loop respawns it elsewhere in the city.
					local nearestPlayer=math.huge
					for _,plr in Players:GetPlayers() do
						local root=plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
						if root and root:IsA("BasePart") then nearestPlayer=math.min(nearestPlayer,(root.Position-current).Magnitude) end
					end
					if nearestPlayer>150 or still>150 then
						driverHumanoid.Health=0
						return false
					end
				end
			else
				state.stillSince=nil;state.stillRerouted=nil
			end
			state.lastProgressPos=current
			state.lastProgressAt=now
		end
    return true
end

local function retireTraffic(state)
    local car=state.car

	if state.lastRoad and network[state.lastRoad] then
		local name=network[state.lastRoad].name
		roadOccupancy[name]=math.max(0,(roadOccupancy[name] or 1)-1)
	end
	trafficRegistry[car]=nil
	claimDestination(state,nil)
	if car.Parent then car:SetAttribute("TrafficActive",false) end
	spinWheels(state,false,0)
	-- A retired car ALWAYS leaves the road. The drivers run with EvaluateStateMachine
	-- off, so Humanoid.Died never fires for them and the old "wait for Died" cleanup
	-- left dead cars parked on the road forever - they piled up into city-wide jams.
	if car.Parent and state.humanoid.Health>0 then car:Destroy()
	else
		task.delay(RESPAWN_DELAY,function()
			if car.Parent and not car:GetAttribute("TrafficStolen") then car:Destroy() end
		end)
	end
end

game:GetService("RunService").Heartbeat:Connect(function()
    local now=os.clock()
    for car,state in trafficRegistry do
        if state.humanoid and now>=state.nextStep then
            local dt=now-state.lastStep
            state.lastStep=now;state.nextStep=now+trafficSimStep(state)
            local ok,alive=pcall(updateTraffic,state,now,dt)
            if not ok then warn("[CivilianTrafficServer] driver retired: "..tostring(alive)) end
            if not ok or not alive then retireTraffic(state) end
        end
    end
end)

local spawnCar
spawnCar=function()
	if #pedPool==0 or not carTemplates or #network==0 then return end
	local roadIdx,nodeIdx,dir,spawnPos=chooseSpawn()
	if not roadIdx or not spawnPos then return end
	local road=network[roadIdx]

	local carType=CAR_TYPES[math.random(1,#CAR_TYPES)]
	local template=carTemplates:FindFirstChild(carType)
	if not template then return end

	local car=template:Clone()
	car.Name="Resident Traffic"
	car:SetAttribute("TrafficCarType",carType) -- v221: carjacking respawns this type as a real player car
	local seat=car:FindFirstChildWhichIsA("VehicleSeat",true)
	if not seat then car:Destroy(); return end
	car.PrimaryPart=seat
	paint(car)

	local driver=RoadDriving.newDriver(network,roadIdx,nodeIdx,dir,spawnPos+Vector3.new(0,2,0))
	driver.vehicleKey=car
	driver.resident=true
	local from=road.points[math.clamp(nodeIdx-dir,1,#road.points)]
    local to=road.points[nodeIdx]
    local tangent=Vector3.new(to.X-from.X,0,to.Z-from.Z)
    if tangent.Magnitude<0.1 then car:Destroy();return end
    driver.heading=tangent.Unit;driver.lane=math.max(1,road.lanes or 1);driver.laneRoad=roadIdx
    driver.smoothLaneOffset=RoadDriving.laneCenter(road,driver.lane)
    driver.pos=spawnPos+Vector3.new(-driver.heading.Z,0,driver.heading.X)*driver.smoothLaneOffset+Vector3.new(0,2,0)
    if not spawnClear(driver.pos) then car:Destroy();return end
    car:PivotTo(CFrame.lookAt(driver.pos,driver.pos+driver.heading))
    car:SetAttribute("TrafficPose",car:GetPivot());car:SetAttribute("TrafficActive",true)
    CollectionService:AddTag(car,"SmoothResidentTraffic")

	for _,part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") then part.Anchored=true end
	end
	car.Parent=workspace
	-- v158: resident traffic can be carjacked. The visual NPC is not a real seat
	-- occupant, so the player can take the driver's seat directly. Once occupied,
	-- traffic simulation relinquishes the model, GTA is reported, and CarServer
	-- converts the same physical car into normal player-drive physics.
	seat.Disabled=false
	-- v215: press E at the driver's door to pull the driver out and take the car
	local jack=Instance.new("ProximityPrompt")
	jack.Name="Carjack"
	jack.ActionText="Carjack"
	jack.ObjectText="Car"
	-- GTA: F at the driver's door, nothing on screen
	jack.KeyboardKeyCode=Enum.KeyCode.F
	jack.GamepadKeyCode=Enum.KeyCode.ButtonY
	jack.Style=Enum.ProximityPromptStyle.Custom
	jack.HoldDuration=0
	jack.MaxActivationDistance=9
	jack.RequiresLineOfSight=false
	jack.Parent=seat
	jack.Triggered:Connect(function(player)
		if car:GetAttribute("TrafficStolen") or seat.Occupant then return end
		local char=player.Character
		local hum=char and char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health<=0 or hum.SeatPart then return end
		-- the driver is thrown out onto the street and runs off
		local npc=nil
		for _,c in car:GetChildren() do
			if c:IsA("Model") and c:FindFirstChildOfClass("Humanoid") then npc=c;break end
		end
		if npc then
			local door=seat.CFrame*CFrame.new(-4.5,0,0)
			local runner=npc:Clone()
			for _,d in runner:GetDescendants() do if d:IsA("BasePart") then d.Anchored=false;d.CanCollide=(d.Name=="HumanoidRootPart" or d.Name=="Torso") end end
			runner.Parent=workspace
			runner:PivotTo(CFrame.new(door.Position+Vector3.new(0,2,0)))
			local rh=runner:FindFirstChildOfClass("Humanoid")
			if rh then
				pcall(function() rh.EvaluateStateMachine=true end)
				rh.WalkSpeed=18;rh.AutoRotate=true
				rh:MoveTo(door.Position+(door.Position-seat.Position).Unit*40)
			end
			game:GetService("Debris"):AddItem(runner,8)
		end
		player:SetAttribute("CarEnterAt",workspace:GetServerTimeNow()) -- CarServer: entered with F
		seat:Sit(hum)
		jack:Destroy()
	end)

	local driverNpc=pedPool[math.random(1,#pedPool)]:Clone()
	local driverHumanoid=driverNpc:FindFirstChildOfClass("Humanoid")
	if not driverHumanoid then
		car:Destroy()
		driverNpc:Destroy()
		return
	end
	driverHumanoid.WalkSpeed=0
	pcall(function() driverHumanoid.EvaluateStateMachine=false end)
	driverHumanoid.AutoRotate=false
	driverHumanoid.BreakJointsOnDeath=false
	driverHumanoid.DisplayDistanceType=Enum.HumanoidDisplayDistanceType.None
	local driveSeat=CFrame.new(0,1.4,-0.2)
	for _,part in ipairs(driverNpc:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored=true
			part.CanCollide=false
			part.CanTouch=false
			part.CanQuery=false
		end
	end
	-- Keep the driver inside the car model so car:PivotTo() carries the visual
	-- along for free instead of replicating a second model pivot every tick.
	driverNpc.Parent=car
	driverNpc:PivotTo(car:GetPivot()*driveSeat)

	local stolen=false
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if stolen or car:GetAttribute("TrafficStolen") then return end
		local occ=seat.Occupant
		local player=occ and Players:GetPlayerFromCharacter(occ.Parent)
		if not player then return end
		-- walked into it instead of pressing F: out you go, the car isn't stolen
		if workspace:GetServerTimeNow()-(tonumber(player:GetAttribute("CarEnterAt")) or 0)>4 then
			task.defer(function() local w=seat:FindFirstChild("SeatWeld");if w then w:Destroy() end end)
			return
		end
		stolen=true;car:SetAttribute("TrafficStolen",true);car:SetAttribute("TrafficActive",false)
		-- Remove this car from the resident simulation before handing physics ownership over.
		local state=trafficRegistry[car]
		if state then
			if state.lastRoad and network[state.lastRoad] then local rn=network[state.lastRoad].name;roadOccupancy[rn]=math.max(0,(roadOccupancy[rn] or 1)-1) end
			claimDestination(state,nil)
			trafficRegistry[car]=nil
		end
		CollectionService:RemoveTag(car,"SmoothResidentTraffic")
		if driverNpc.Parent then driverNpc:Destroy() end
		local report=ServerStorage:FindFirstChild("ReportCrime")
		if report and report:IsA("BindableFunction") then pcall(function() report:Invoke(player,"Grand theft auto",1) end) end
		-- v218: hand over after this Occupant event finishes (rebuilding the car's
		-- joints inside the event fought the new SeatWeld and left the car undrivable)
		task.defer(function()
			local adopt=ServerStorage:FindFirstChild("AdoptStolenCar")
			if adopt and adopt:IsA("BindableFunction") and car.Parent then
				local ok,result=pcall(function() return adopt:Invoke(player,car) end)
				if not ok or not result then warn("[CivilianTrafficServer] failed to hand stolen traffic car to CarServer: "..tostring(result)) end
			end
		end)
	end)

	local cleanedUp=false
	local function cleanup()
		if cleanedUp then return end
		cleanedUp=true
		car:SetAttribute("TrafficActive",false)
		local tag=driverHumanoid:FindFirstChild("creator")
		reportMurder(tag and tag.Value)
		task.delay(RESPAWN_DELAY,function()
			if car.Parent then car:Destroy() end
			if driverNpc.Parent then driverNpc:Destroy() end
			-- Do not spawn here. The population refill loop is the single owner of
			-- replacement spawns; the old dual replacement path could creep past
			-- the target population after repeated cleanup/recovery cycles.
		end)
	end

	driverHumanoid.Died:Connect(cleanup)
	-- Died never fires with the state machine off: watch the health itself
	driverHumanoid.HealthChanged:Connect(function(hp)
		if hp<=0 then cleanup() end
	end)
	car.AncestryChanged:Connect(function()
		if not car:IsDescendantOf(workspace) and driverHumanoid.Health>0 then
			driverHumanoid.Health=0
		end
	end)

	task.spawn(runCar,car,driverNpc,driverHumanoid,driveSeat,driver)
end

for i=1,TRAFFIC_COUNT do
	task.spawn(function()
		task.wait((i-1)*0.11)
		spawnCar()
	end)
end

local function activeTrafficCount()
	local n=0
	for car in pairs(trafficRegistry) do
		if car.Parent then n+=1 end
	end
	return n
end

-- Some spawn attempts are intentionally rejected when a road is crowded.
-- This refill loop keeps working toward the requested population without
-- spawning cars on top of each other.
task.spawn(function()
	task.wait(TRAFFIC_COUNT*0.11+4)
	while true do
		local missing=TRAFFIC_COUNT-activeTrafficCount()
		for _=1,math.min(MAX_SPAWNS_PER_TICK,math.max(0,missing)) do
			spawnCar()
		end
		task.wait(1.0)
	end
end)

local junctions=RoadDriving.getJunctions(network)
print(("[CivilianTrafficServer] v144 interpolated traffic online: target %d cars, %d roads, %d controlled intersections"):format(
	TRAFFIC_COUNT,#network,#junctions))
