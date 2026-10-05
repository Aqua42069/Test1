--[[
	CityTraffic (v284) - the traffic rebuild (replaces CivilianTrafficServer; set
	Workspace attribute TrafficV2 = false to go back to the old one).

	LANES from the mapped roads (RoadDriving's network: lanes per direction, one-ways, junctions).
	DRIVING: endless roaming - at every junction a weighted random choice (straight preferred,
	  main roads preferred, no U-turns, no dead ends) - with smooth Bezier turns. Following
	  uses the Intelligent Driver Model: smooth acceleration and braking, safe gaps, and
	  curve speeds. Cars never stop in the road without a reason.
	JUNCTIONS: controls are generated from the geometry, not hand-placed:
	    a bend / continuation (2 arms)            no control
	    a T or a crossing of small streets         all-way stop (first come, first go)
	    anything with a main road                  signals (two phases, real lights)
	  A car only enters when its exit has room ("don't block the box"), and only together with
	  cars from its own axis. A watchdog lets anything waiting too long through, and a car
	  stuck out of sight is recycled - nothing jams for good.
	REACTIONS:
	  * people in front of a car: it brakes and waits
	  * a gun pointed at a driver: they surrender and bail out (the car is yours to take),
	    floor it, or - the aggressive ones - try to run you over
	  * gunshots nearby: they panic and speed off
	  * sirens behind: pull to the kerb and slow down (never inside a junction)
	  * a traffic stop (CityLife PullOver): ease to the kerb and wait
	CRASHES: a traffic car becomes a REAL physics car just before something hits it (a player
	  car, a police car, another wreck), so crashes shove it, spin it and chain into others;
	  the dents, glass, lights and doors are CarDamage's job. After a crash the driver gets out.
	CARJACK: F at the driver's door (as before).
	Logs: [Traffic]
]]

if workspace:GetAttribute("TrafficV2") == false then
	print("[Traffic] TrafficV2 is off - the old CivilianTrafficServer runs")
	return
end
workspace:SetAttribute("TrafficV2", true)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")

-- v286i: traffic still under traffic control is moved by script (anchored, kinematic). It must
-- never physically touch people on foot - an anchored car shoves them through the road. It
-- stops for them (leaderAhead); the moment it becomes a real car (a crash, a carjack) it
-- collides like any other car again.
local KINEMATIC, ONFOOT = "TrafficKinematic", "OnFoot"
pcall(function() PhysicsService:RegisterCollisionGroup(KINEMATIC) end)
pcall(function() PhysicsService:RegisterCollisionGroup(ONFOOT) end)
-- OnFoot behaves exactly like Default against every other group (police pursuit ghosts,
-- passengers ...) - except kinematic traffic. Re-mirrored as other scripts register groups.
local function mirrorDefault()
	pcall(function()
		for _, g in PhysicsService:GetRegisteredCollisionGroups() do
			if g.name ~= ONFOOT and g.name ~= KINEMATIC then
				PhysicsService:CollisionGroupSetCollidable(ONFOOT, g.name, PhysicsService:CollisionGroupsAreCollidable("Default", g.name))
			end
		end
		PhysicsService:CollisionGroupSetCollidable(ONFOOT, ONFOOT, PhysicsService:CollisionGroupsAreCollidable("Default", "Default"))
		PhysicsService:CollisionGroupSetCollidable(KINEMATIC, ONFOOT, false)
	end)
end
mirrorDefault()
for _, t in { 3, 10, 30, 90 } do task.delay(t, mirrorDefault) end
local function onFoot(part: Instance)
	if part:IsA("BasePart") and part.CollisionGroup == "Default" then part.CollisionGroup = ONFOOT end
end
local function character(ch: Model)
	for _, d in ch:GetDescendants() do onFoot(d) end
	ch.DescendantAdded:Connect(onFoot)
end
for _, p in Players:GetPlayers() do
	if p.Character then character(p.Character) end
	p.CharacterAdded:Connect(character)
end
Players.PlayerAdded:Connect(function(p) p.CharacterAdded:Connect(character) end)

---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------
local CFG = {
	-- v290c: TargetMax 150 -> 70 and Density (studs of lane per car x Density): it piled up round
	-- the player, and wrecks / abandoned cars nearby now count against the target too
	TargetMax = 70, Base = 30, PerPlayer = 40, Density = 1.7,
	SpawnMin = 170, SpawnMax = 520, Despawn = 700,
	NearRadius = 360, NearTick = 1 / 12, FarTick = 0.6,
	PivotRadius = 600,
	CarHalf = 9.4, -- half a car length
	Accel = 13, Decel = 18, MinGap = 5, Headway = 1.15,
	LatAccel = 13,
	MaxSpeed = 38,
	SignalGreen = 13, SignalYellow = 3, SignalAllRed = 1.5,
	StopWait = 0.6,
	GateWatchdog = 8,
	StuckGhost = 7, StuckRecycle = 14,
	WreckLife = 240, MaxWrecks = 24,
	AimTime = 0.45, AimRange = 45, AimDot = 0.93,
	PanicRadius = 90,
	CarTypes = { "Sedan", "SUV", "Van" },
}

---------------------------------------------------------------------------
-- the network
---------------------------------------------------------------------------
local RD
for _ = 1, 200 do
	RD = _G.RoadDriving
	if RD then break end
	task.wait(0.1)
end
if not RD then
	warn("[Traffic] RoadDriving unavailable - no traffic")
	return
end
local network = RD.loadNetwork()
RD.buildGraph(network)
local graph = network._graph or {}
local junctions = network._junctions or {}
if #network == 0 then
	warn("[Traffic] no roads mapped")
	return
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end
local function unit(v: Vector3): Vector3?
	local m = v.Magnitude
	if m < 1e-4 then return nil end
	return v / m
end

-- residents don't drive out to the prison (same rule as before)
local restricted = {}
do
	local facility = workspace:FindFirstChild("CorrectionalFacility")
	local prisonPos = facility and facility:IsA("Model") and facility:GetPivot().Position
	if prisonPos then
		for idx, road in ipairs(network) do
			for _, p in road.points do
				if (flat(p) - flat(prisonPos)).Magnitude <= 600 then restricted[idx] = true break end
			end
		end
	end
	-- only the biggest connected piece of the city
	local comp, best, bestSize = {}, nil, 0
	for s = 1, #network do
		if not restricted[s] and not comp[s] then
			local members, q = { s }, 1
			comp[s] = s
			while q <= #members do
				local u = members[q]
				q += 1
				for _, e in graph[u] or {} do
					if not restricted[e.road] and not comp[e.road] then comp[e.road] = s table.insert(members, e.road) end
				end
			end
			if #members > bestSize then best, bestSize = s, #members end
		end
	end
	for i = 1, #network do
		if comp[i] ~= best then restricted[i] = true end
	end
end
_G.TrafficRestrictedRoads = restricted

---------------------------------------------------------------------------
-- lanes
---------------------------------------------------------------------------
type Lane = { id: number, road: number, dir: number, idx: number, n: number, pts: { Vector3 }, cum: { number }, len: number,
	nodeAt: { [number]: number }, sAtNode: { [number]: number }, juncs: { any }, speed: number, width: number, laneW: number }
local lanes: { Lane } = {}
local laneKey: { [string]: Lane } = {}

local function laneWidthOf(road): number
	local per = if road.oneWay then road.lanes else road.lanes * 2
	if road.width and road.width > 0 then return math.clamp(road.width / per, 5, 16) end
	return math.max(tonumber(road.laneWidth) or 4, 6.5)
end
local function offsetOf(road, idx: number): number
	local w = laneWidthOf(road)
	if road.oneWay then return -(road.lanes * w) / 2 + (idx - 0.5) * w end
	return math.max((idx - 0.5) * w, if idx == 1 then 5.8 else 0)
end

for r, road in ipairs(network) do
	if restricted[r] or #road.points < 2 then continue end
	local N = #road.points
	for _, d in (if road.oneWay then { 1 } else { 1, -1 }) do
		for idx = 1, road.lanes do
			local ordered, nodeOf = {}, {}
			if d == 1 then
				for i = 1, N do table.insert(ordered, road.points[i]) table.insert(nodeOf, i) end
			else
				for i = N, 1, -1 do table.insert(ordered, road.points[i]) table.insert(nodeOf, i) end
			end
			local off = offsetOf(road, idx)
			local pts = {}
			for i = 1, #ordered do
				local t1 = if i > 1 then unit(flat(ordered[i] - ordered[i - 1])) else nil
				local t2 = if i < #ordered then unit(flat(ordered[i + 1] - ordered[i])) else nil
				local t = unit((t1 or Vector3.zero) + (t2 or Vector3.zero)) or t1 or t2 or Vector3.new(0, 0, -1)
				local right = Vector3.new(-t.Z, 0, t.X)
				local scale = 1
				if t1 and t2 then
					local r2 = Vector3.new(-t2.Z, 0, t2.X)
					scale = 1 / math.max(0.6, right:Dot(r2))
				end
				pts[i] = ordered[i] + right * off * scale
			end
			local cum = { 0 }
			for i = 2, #pts do cum[i] = cum[i - 1] + (flat(pts[i] - pts[i - 1])).Magnitude end
			if cum[#pts] < 6 then continue end
			local lane: Lane = { id = #lanes + 1, road = r, dir = d, idx = idx, n = road.lanes, pts = pts, cum = cum, len = cum[#pts],
				nodeAt = {}, sAtNode = {}, juncs = {}, speed = math.min(CFG.MaxSpeed, road.speedLimit or 20), width = road.width or 30, laneW = laneWidthOf(road) }
			for i, node in nodeOf do
				lane.nodeAt[i] = node
				lane.sAtNode[node] = cum[i]
				local jid = road.junctionAtNode[node]
				if jid then table.insert(lane.juncs, { s = cum[i], jid = jid, node = node, i = i }) end
			end
			table.insert(lanes, lane)
			laneKey[r .. ":" .. d .. ":" .. idx] = lane
		end
	end
end

-- point and heading on a lane at distance s
local function lanePoint(lane: Lane, s: number, hint: number?): (Vector3, Vector3, number)
	s = math.clamp(s, 0, lane.len)
	local cum, pts = lane.cum, lane.pts
	local i = math.clamp(hint or 1, 1, #pts - 1)
	while i > 1 and cum[i] > s do i -= 1 end
	while i < #pts - 1 and cum[i + 1] < s do i += 1 end
	local segLen = cum[i + 1] - cum[i]
	local t = if segLen > 1e-4 then (s - cum[i]) / segLen else 0
	local p = pts[i]:Lerp(pts[i + 1], t)
	local h = unit(flat(pts[i + 1] - pts[i])) or Vector3.new(0, 0, -1)
	return p, h, i
end

---------------------------------------------------------------------------
-- junction controls (generated)
---------------------------------------------------------------------------
type JRT = { id: number, pos: Vector3, control: string, axis: Vector3, occupants: { [any]: string }, queue: { any }, offset: number, arms: number }
local jrt: { [number]: JRT } = {}
for _, j in ipairs(junctions) do
	local arms, primary, majorish = 0, 0, 0
	local axis = nil
	for roadIdx in j.roads do
		local road = network[roadIdx]
		if not road or restricted[roadIdx] then continue end
		for _, node in j.nodes[roadIdx] or {} do
			if node > 1 then arms += 1 end
			if node < #road.points then arms += 1 end
			if not axis then
				local a = road.points[math.max(1, node - 1)]
				local b = road.points[math.min(#road.points, node + 1)]
				axis = unit(flat(b - a))
			end
		end
		if road.roadType == "Primary" then primary += 1 end
		if road.roadType == "Primary" or road.roadType == "Secondary" then majorish += 1 end
	end
	local control = "None"
	if arms >= 3 then
		control = if primary >= 1 and majorish >= 2 then "Signal" elseif arms >= 4 and majorish >= 1 then "Signal" else "Stop"
	end
	jrt[j.id] = { id = j.id, pos = j.position, control = control, axis = axis or Vector3.new(1, 0, 0), occupants = {}, queue = {},
		offset = (j.id * 7.3) % 35, arms = arms }
end

local function axisOf(J: JRT, heading: Vector3): string
	local a = J.axis
	local b = Vector3.new(-a.Z, 0, a.X)
	return if math.abs(heading:Dot(a)) >= math.abs(heading:Dot(b)) then "A" else "B"
end
local CYCLE = 2 * (CFG.SignalGreen + CFG.SignalYellow + CFG.SignalAllRed)
-- "green" | "yellow" | "red" for an axis
local function signalState(J: JRT, axis: string): string
	local t = (os.clock() + J.offset) % CYCLE
	local half = CYCLE / 2
	local mine = if axis == "A" then t < half else t >= half
	if not mine then return "red" end
	local tt = t % half
	if tt < CFG.SignalGreen then return "green" end
	if tt < CFG.SignalGreen + CFG.SignalYellow then return "yellow" end
	return "red"
end

---------------------------------------------------------------------------
-- cars
---------------------------------------------------------------------------
local carTemplates = ServerStorage:WaitForChild("CarTemplates", 30)
local pedTemplates = ServerStorage:WaitForChild("CivilianTemplates", 30)
local pedPool = if pedTemplates then pedTemplates:GetChildren() else {}

local PROFILES = {
	{ name = "Cautious", speed = 0.86, gap = 1.35, accel = 0.85, aggressive = false },
	{ name = "Normal", speed = 0.98, gap = 1.15, accel = 1.0, aggressive = false },
	{ name = "Normal", speed = 1.02, gap = 1.1, accel = 1.0, aggressive = false },
	{ name = "Confident", speed = 1.1, gap = 0.95, accel = 1.15, aggressive = true },
}
local COLOURS = {
	Color3.fromRGB(180, 40, 40), Color3.fromRGB(40, 80, 170), Color3.fromRGB(230, 230, 230), Color3.fromRGB(30, 30, 35),
	Color3.fromRGB(200, 170, 40), Color3.fromRGB(60, 110, 70), Color3.fromRGB(110, 80, 150), Color3.fromRGB(165, 165, 170),
	Color3.fromRGB(120, 30, 30), Color3.fromRGB(20, 40, 80), Color3.fromRGB(200, 200, 205),
}

local cars: { [Model]: any } = {}
local carCount = 0
local wrecks: { [Model]: number } = {}
local physCars: { [Model]: any } = {} -- v286j: a car made physical, still with its driver (a carjack later)
local stolenCars: { [Model]: boolean } = {} -- v290: taken by a player - traffic must see them (they left wrecks on the theft)

-- the planned path: pieces { kind = "lane", lane, s0, s1 } | { kind = "curve", pts, cum, len }, each with a start distance
local function pieceLen(p): number
	return if p.kind == "lane" then p.s1 - p.s0 else p.len
end
local function bezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: number): ({ Vector3 }, { number })
	local pts, cum = {}, { 0 }
	for i = 0, n do
		local t = i / n
		local u = 1 - t
		pts[i + 1] = p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
		if i > 0 then cum[i + 1] = cum[i] + (flat(pts[i + 1] - pts[i])).Magnitude end
	end
	return pts, cum
end
local function curvePoint(p, d: number): (Vector3, Vector3)
	local pts, cum = p.pts, p.cum
	d = math.clamp(d, 0, p.len)
	local i = 1
	while i < #pts - 1 and cum[i + 1] < d do i += 1 end
	local seg = cum[i + 1] - cum[i]
	local t = if seg > 1e-4 then (d - cum[i]) / seg else 0
	return pts[i]:Lerp(pts[i + 1], t), unit(flat(pts[i + 1] - pts[i])) or Vector3.new(0, 0, -1)
end

-- where on the path (absolute distance) -> position, heading, piece
local function pathAt(car, dist: number): (Vector3, Vector3, any)
	local pieces = car.pieces
	for k = car.pi, #pieces do
		local p = pieces[k]
		local L = pieceLen(p)
		if dist <= p.start + L or k == #pieces then
			local d = dist - p.start
			if p.kind == "lane" then
				local pos, h, hint = lanePoint(p.lane, p.s0 + d, p.hint)
				p.hint = hint
				return pos, h, p
			end
			local pos, h = curvePoint(p, d)
			return pos, h, p
		end
	end
	local last = pieces[#pieces]
	return lanePoint(last.lane, last.s1)
end
local function pathEnd(car): number
	local last = car.pieces[#car.pieces]
	if not last then return car.dist end
	return last.start + pieceLen(last)
end

local function addPiece(car, p)
	local last = car.pieces[#car.pieces]
	p.start = if last then last.start + pieceLen(last) else car.dist
	table.insert(car.pieces, p)
end

-- a dead end: is there anywhere to go from the end of this lane?
local function laneExits(lane: Lane, j): { any }
	local out = {}
	local road = network[lane.road]
	local node = j.node
	-- straight on through the junction
	if j.i < #lane.pts and lane.len - j.s > 12 then
		table.insert(out, { kind = "straight", w = 4 })
	end
	for _, e in graph[lane.road] or {} do
		if e.fromNode == node and e.junctionId == j.jid and not restricted[e.road] and e.road ~= lane.road then
			local other = network[e.road]
			for _, d in (if other.oneWay then { 1 } else { 1, -1 }) do
				if (d == 1 and e.toNode < #other.points) or (d == -1 and e.toNode > 1) then
					-- the direction leaving the junction
					local a = other.points[e.toNode]
					local b = other.points[e.toNode + d]
					local outDir = unit(flat(b - a))
					local inDir = select(2, lanePoint(lane, j.s))
					if outDir and outDir:Dot(inDir) > -0.6 then -- not a U-turn
						local right = Vector3.new(-inDir.Z, 0, inDir.X)
						local isRight = outDir:Dot(right) > 0.3
						local isLeft = outDir:Dot(right) < -0.3
						local idx = if isRight then other.lanes elseif isLeft then 1 else math.min(lane.idx, other.lanes)
						local target = laneKey[e.road .. ":" .. d .. ":" .. idx]
						if target then
							local w = 1.6
							if other.roadType == "Primary" then w *= 1.5 end
							-- avoid lanes that end in a dead end soon with nothing after
							if #target.juncs == 0 or (target.juncs[#target.juncs].s < target.len - 5 and target.len - (target.sAtNode[e.toNode] or 0) < 60) then w *= 0.25 end
							table.insert(out, { kind = "turn", lane = target, node = e.toNode, w = w, right = isRight, left = isLeft })
						end
					end
				end
			end
		end
	end
	return out
end

local function pick(options)
	local total = 0
	for _, o in options do total += o.w end
	local r = math.random() * total
	for _, o in options do
		r -= o.w
		if r <= 0 then return o end
	end
	return options[#options]
end

-- extend the plan until there's 160 studs ahead
local function extend(car)
	local guard = 0
	while pathEnd(car) - car.dist < 160 and guard < 8 do
		guard += 1
		local cur = car.cursor
		local lane: Lane, s = cur.lane, cur.s
		-- the next junction along this lane
		local nextJ = nil
		for _, j in lane.juncs do
			if j.s > s + 0.5 then nextJ = j break end
		end
		if not nextJ then
			-- dead end: turn around onto the other side (or vanish at the end)
			addPiece(car, { kind = "lane", lane = lane, s0 = s, s1 = math.max(s, lane.len - 4) })
			local back = nil
			local road = network[lane.road]
			if not road.oneWay then
				back = laneKey[lane.road .. ":" .. (-lane.dir) .. ":" .. road.lanes]
			end
			if back then
				local p0, h0 = lanePoint(lane, lane.len - 4)
				local s2 = math.max(0, 4)
				local p3, h3 = lanePoint(back, s2)
				local k = math.max(6, (p3 - p0).Magnitude * 0.9)
				local pts, cum = bezier(p0, p0 + h0 * k, p3 - h3 * k, p3, 10)
				addPiece(car, { kind = "curve", pts = pts, cum = cum, len = cum[#cum], uturn = true })
				car.cursor = { lane = back, s = s2 }
			else
				car.vanishAt = pathEnd(car)
				return
			end
			continue
		end
		local J = jrt[nextJ.jid]
		local options = laneExits(lane, nextJ)
		if #options == 0 then
			-- the junction leads nowhere usable: treat like a dead end, go on along the lane
			addPiece(car, { kind = "lane", lane = lane, s0 = s, s1 = math.min(lane.len, nextJ.s + 1) })
			car.cursor = { lane = lane, s = math.min(lane.len, nextJ.s + 1) }
			continue
		end
		local choice = pick(options)
		local rIn = math.clamp((network[lane.road].width or 30) * 0.25 + 6, 8, 22)
		if choice.kind == "straight" then
			local sA = math.max(s, nextJ.s - rIn)
			local sB = math.min(lane.len, nextJ.s + rIn)
			addPiece(car, { kind = "lane", lane = lane, s0 = s, s1 = sA })
			local enterAt = pathEnd(car)
			addPiece(car, { kind = "lane", lane = lane, s0 = sA, s1 = sB })
			if J and J.control ~= "None" then
				local _, h = lanePoint(lane, sA)
				table.insert(car.gates, { J = J, enter = enterAt, exit = pathEnd(car), axis = axisOf(J, h) })
			end
			car.cursor = { lane = lane, s = sB }
		else
			local L2: Lane = choice.lane
			local otherW = network[L2.road].width or 30
			local rA = math.clamp(otherW * 0.5 + 2, 8, 30)
			local rB = math.clamp((network[lane.road].width or 30) * 0.5 + 2, 8, 30)
			local sA = math.max(s, nextJ.s - rA)
			local sNode = L2.sAtNode[choice.node] or 0
			local sB = math.min(L2.len - 1, sNode + rB)
			addPiece(car, { kind = "lane", lane = lane, s0 = s, s1 = sA })
			local enterAt = pathEnd(car)
			local p0, h0 = lanePoint(lane, sA)
			local p3, h3 = lanePoint(L2, sB)
			local k = (p3 - p0).Magnitude * 0.42
			local pts, cum = bezier(p0, p0 + h0 * k, p3 - h3 * k, p3, 10)
			-- the turn's radius sets its speed
			local turnAngle = math.acos(math.clamp(h0:Dot(h3), -1, 1))
			local radius = if turnAngle > 0.05 then cum[#cum] / turnAngle else 999
			addPiece(car, { kind = "curve", pts = pts, cum = cum, len = cum[#cum], vmax = math.sqrt(CFG.LatAccel * radius) })
			if J and J.control ~= "None" then
				table.insert(car.gates, { J = J, enter = enterAt, exit = pathEnd(car), axis = axisOf(J, h0) })
			end
			car.cursor = { lane = L2, s = sB }
		end
	end
end

---------------------------------------------------------------------------
-- the spatial grid (cars + obstacles)
---------------------------------------------------------------------------
local CELL = 40
local grid: { [number]: { any } } = {}
local obstacles: { any } = {}
local function cellKey(x: number, z: number): number
	return math.floor(x / CELL) * 100000 + math.floor(z / CELL)
end
local function rebuildGrid()
	table.clear(grid)
	for _, car in cars do
		local k = cellKey(car.pos.X, car.pos.Z)
		local c = grid[k]
		if not c then c = {} grid[k] = c end
		table.insert(c, car)
	end
	table.clear(obstacles)
	-- people
	for _, p in Players:GetPlayers() do
		local ch = p.Character
		local r = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if r and hum and hum.Health > 0 and not hum.SeatPart then
			table.insert(obstacles, { pos = r.Position, vel = r.AssemblyLinearVelocity, half = 1.2, lat = 7, person = true }) -- v284e: the whole width of the car
		end
	end
	-- vehicles that aren't simulated traffic: player cars, police cars, wrecks
	local function vehicle(m: Instance)
		if not m:IsA("Model") or cars[m :: Model] then return end
		local pp = (m :: Model).PrimaryPart or m:FindFirstChildWhichIsA("VehicleSeat", true)
		if pp and pp:IsA("BasePart") then
			table.insert(obstacles, { pos = pp.Position, vel = pp.AssemblyLinearVelocity, half = 8.5, lat = 9.5, model = m, static = pp.AssemblyLinearVelocity.Magnitude < 1.5 })
		end
	end
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then for _, m in sp:GetChildren() do vehicle(m) end end
	local pa = workspace:FindFirstChild("PoliceAI")
	local pv = pa and pa:FindFirstChild("Vehicles")
	if pv then for _, m in pv:GetChildren() do vehicle(m) end end
	for m in wrecks do if m.Parent then vehicle(m) end end
	for m in stolenCars do if m.Parent then vehicle(m) else stolenCars[m] = nil end end
end
local function nearbyCars(pos: Vector3, radius: number): { any }
	local out = {}
	local r = math.ceil(radius / CELL)
	local cx, cz = math.floor(pos.X / CELL), math.floor(pos.Z / CELL)
	for dx = -r, r do
		for dz = -r, r do
			local c = grid[(cx + dx) * 100000 + (cz + dz)]
			if c then for _, car in c do table.insert(out, car) end end
		end
	end
	return out
end

---------------------------------------------------------------------------
-- models
---------------------------------------------------------------------------
local function groundOffsetOf(model: Model): number
	local pivotY = model:GetPivot().Position.Y
	local lowest = math.huge
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.CanCollide and part.Transparency < 0.98 then
			local cf, s = part.CFrame, part.Size * 0.5
			local halfY = math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z
			lowest = math.min(lowest, part.Position.Y - halfY)
		end
	end
	if lowest == math.huge then return 2 end
	return math.clamp(pivotY - lowest, 0.35, 4.5)
end
local offsetCache: { [string]: number } = {}

local physicalize -- forward
local removeCar

local function report(player: Player, crime: string, stars: number)
	local rc = ServerStorage:FindFirstChild("ReportCrime")
	if rc and rc:IsA("BindableFunction") then pcall(rc.Invoke, rc, player, crime, stars) end
end

-- the driver climbs out and walks / runs off
local function driverOut(car, mood: string, from: Vector3?)
	local npc = car.npc
	if not npc or not npc.Parent then return end
	car.npc = nil
	local seat = car.seat
	local side = if seat and seat.Parent then seat.CFrame * CFrame.new(-4.8, 0, 0) else CFrame.new(npc:GetPivot().Position + Vector3.new(4, 0, 0))
	local runner = npc:Clone()
	npc:Destroy()
	for _, d in runner:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.Massless = false
			d.CanCollide = d.Name == "HumanoidRootPart" or d.Name == "Torso" or d.Name == "UpperTorso"
			d.CanQuery = true
			d.CanTouch = true
		elseif d:IsA("Weld") or d:IsA("WeldConstraint") then
			if d.Name ~= "RootJoint" and not d:IsA("Motor6D") then d:Destroy() end
		end
	end
	runner.Parent = workspace
	runner:PivotTo(CFrame.new(side.Position + Vector3.new(0, 2.5, 0)))
	local h = runner:FindFirstChildOfClass("Humanoid")
	if h then
		pcall(function() h.EvaluateStateMachine = true end)
		h.AutoRotate = true
		h.WalkSpeed = if mood == "panic" then 20 else 10
		h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		local away = unit(flat(side.Position - (from or (seat and seat.Position) or side.Position))) or Vector3.new(1, 0, 0)
		if mood == "surrender" then
			-- hands up, a few steps back, then off they go
			local root = runner:FindFirstChild("HumanoidRootPart")
			task.spawn(function()
				h:MoveTo(side.Position + away * 6)
				task.wait(1.6)
				h.WalkSpeed = 18
				h:MoveTo(side.Position + away * 60)
			end)
			if root then
				local bb = Instance.new("BillboardGui")
				bb.Size = UDim2.fromOffset(160, 30)
				bb.StudsOffset = Vector3.new(0, 3.2, 0)
				bb.MaxDistance = 60
				local t = Instance.new("TextLabel")
				t.Size = UDim2.fromScale(1, 1)
				t.BackgroundTransparency = 1
				t.Font = Enum.Font.GothamBold
				t.TextScaled = true
				t.TextColor3 = Color3.new(1, 1, 1)
				t.TextStrokeTransparency = 0.3
				t.Text = "\"Don't shoot! Take it!\""
				t.Parent = bb
				bb.Parent = root
				Debris:AddItem(bb, 3)
			end
		else
			h:MoveTo(side.Position + away * 50)
		end
	end
	Debris:AddItem(runner, 25)
end

-- v286j: did police see it? (an AI officer with line of sight within 70 studs, or a police
-- player within 50) - seen = the response is immediate; unseen = the owner phones it in later
local function copSees(pos: Vector3): boolean
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	for _, m in CollectionService:GetTagged("Police") do
		local head = m:IsA("Model") and m:FindFirstChild("Head")
		if head and head:IsA("BasePart") and (head.Position - pos).Magnitude < 70 then
			rp.FilterDescendantsInstances = { m }
			local hit = workspace:Raycast(head.Position, pos - head.Position, rp)
			if not hit or (hit.Position - pos).Magnitude < 6 then return true end
		end
	end
	for _, p in Players:GetPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		local team = p.Team and p.Team.Name or ""
		local law = team == "LVPD" or team == "SWAT" or team == "Chief of Police" or team:find("Marshal") ~= nil or team:find("Federal") ~= nil
		if law and r and ((r :: BasePart).Position - pos).Magnitude < 50 then return true end
	end
	return false
end

local function attachCarjack(car)
	-- (v286j: no prompt any more - F goes to CarServer, which hands traffic cars to carjack())
	local seat = car.seat
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local model = car.model
		if model:GetAttribute("TrafficStolen") then return end
		local occ = seat.Occupant
		local player = occ and Players:GetPlayerFromCharacter(occ.Parent)
		if not player then return end
		if workspace:GetServerTimeNow() - (tonumber(player:GetAttribute("CarEnterAt")) or 0) > 4 then
			task.defer(function() local w = seat:FindFirstChild("SeatWeld") if w then w:Destroy() end end)
			return
		end
		model:SetAttribute("TrafficStolen", true)
		stolenCars[model] = true
		model:SetAttribute("TrafficActive", false)
		if car.npc then driverOut(car, "panic", occ.Parent:GetPivot().Position) end
		if not model:GetAttribute("Physicalized") then physicalize(car, Vector3.zero, player, true) end
		wrecks[model] = nil
		-- v286j: police seeing it = an immediate response; otherwise the owner calls 911 a little later
		local at = (occ.Parent :: Model):GetPivot().Position
		if copSees(at) then
			report(player, "Grand theft auto", 1)
		else
			local delay = math.random(18, 40)
			print(("[Traffic] carjack by %s unseen - the owner calls it in in %ds"):format(player.Name, delay))
			task.delay(delay, function()
				if player.Parent then report(player, "Grand theft auto", 1) end
			end)
		end
		task.defer(function()
			local adopt = ServerStorage:FindFirstChild("AdoptStolenCar")
			if adopt and adopt:IsA("BindableFunction") and model.Parent then
				local ok, res = pcall(adopt.Invoke, adopt, player, model)
				if not ok or not res then warn("[Traffic] carjack hand-over failed: " .. tostring(res)) end
			end
		end)
	end)
end

local function spawnAt(lane: Lane, s: number): boolean
	if not carTemplates or #pedPool == 0 then return false end
	local carType = CFG.CarTypes[math.random(1, #CFG.CarTypes)]
	local template = carTemplates:FindFirstChild(carType)
	if not template then return false end
	local model = template:Clone()
	model.Name = "Resident Traffic"
	model:SetAttribute("TrafficCarType", carType)
	local seat = model:FindFirstChildWhichIsA("VehicleSeat", true)
	if not seat then model:Destroy() return false end
	model.PrimaryPart = seat
	seat.Disabled = true -- v286n: no touch-sitting a moving car (brushing it seated you, and the walk-in eject left a stale seat); the carjack enables it
	local colour = COLOURS[math.random(1, #COLOURS)]
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CollisionGroup = KINEMATIC
			if part.Name == "Primary" then part.Color = colour end
		end
	end
	local pos, h = lanePoint(lane, s)
	model:PivotTo(CFrame.lookAt(pos, pos + h))
	if not offsetCache[carType] then offsetCache[carType] = groundOffsetOf(model) end
	-- the driver (anchored, inside the model so the car carries them)
	local npc = pedPool[math.random(1, #pedPool)]:Clone()
	local nh = npc:FindFirstChildOfClass("Humanoid")
	if not nh then model:Destroy() npc:Destroy() return false end
	nh.WalkSpeed = 0
	pcall(function() nh.EvaluateStateMachine = false end)
	nh.AutoRotate = false
	nh.BreakJointsOnDeath = false
	nh.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	for _, part in npc:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Massless = true
		end
	end
	npc.Parent = model
	npc:PivotTo(model:GetPivot() * CFrame.new(0, 1.4, -0.2))
	CollectionService:AddTag(model, "SmoothResidentTraffic")
	model:SetAttribute("TrafficActive", true)
	local profile = PROFILES[math.random(1, #PROFILES)]
	local car = {
		model = model, seat = seat, npc = npc, npcHum = nh, type = carType,
		profile = profile, v = lane.speed * profile.speed * 0.6, dist = 0, pi = 1, pieces = {}, gates = {},
		cursor = { lane = lane, s = s }, pos = pos, heading = h, lat = 0, latTarget = 0,
		groundOffset = offsetCache[carType], lastMoveAt = os.clock(), lastPos = pos,
		nextTick = os.clock() + math.random() * 0.2, lastTick = os.clock(),
		aim = {}, mode = nil, modeUntil = 0, waitSince = nil,
	}
	extend(car)
	cars[model] = car
	carCount += 1
	model.Parent = workspace
	model:SetAttribute("TrafficPose", model:GetPivot())
	attachCarjack(car)
	-- v290e: set on fire (a blast next to it, VehicleHealth): it stops being traffic, the driver runs
	model:GetAttributeChangedSignal("VehicleDestroyed"):Connect(function()
		if model:GetAttribute("VehicleDestroyed") == true and cars[model] then
			physicalize(car, car.heading * car.v * 0.5, nil, true)
			if car.npc then driverOut(car, "panic", model:GetPivot().Position) end
		end
	end)
	-- the driver killed: the car coasts on
	nh.HealthChanged:Connect(function(hp)
		if hp <= 0 and cars[model] then
			local tag = nh:FindFirstChild("creator")
			local killer = tag and tag:IsA("ObjectValue") and tag.Value
			if killer and killer:IsA("Player") then report(killer, "Murder", 2) end
			car.npc = nil
			physicalize(car, car.heading * car.v, nil, false)
		end
	end)
	return true
end

function removeCar(car, destroy: boolean)
	local model = car.model
	if cars[model] then
		cars[model] = nil
		carCount -= 1
	end
	for _, g in car.gates do
		if g.J.occupants[car] then g.J.occupants[car] = nil end
		local q = table.find(g.J.queue, car)
		if q then table.remove(g.J.queue, q) end
	end
	if destroy and model.Parent then model:Destroy() end
end

-- the car becomes real physics (a crash coming, a carjack, a dead driver)
function physicalize(car, velocity: Vector3, owner: Player?, quiet: boolean?)
	local model = car.model
	if model:GetAttribute("Physicalized") then return end
	removeCar(car, false)
	CollectionService:RemoveTag(model, "SmoothResidentTraffic")
	model:SetAttribute("TrafficActive", false)
	model:SetAttribute("Physicalized", true)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.CollisionGroup == KINEMATIC then part.CollisionGroup = "Default" end
	end
	model:PivotTo(model:GetAttribute("TrafficPose") or model:GetPivot())
	local fn = ServerStorage:FindFirstChild("PhysicalizeTraffic")
	local ok = false
	if fn and fn:IsA("BindableFunction") then
		local okI, res = pcall(fn.Invoke, fn, model)
		ok = okI and res == true
	end
	if not ok then
		-- CarServer isn't there: weld everything to the seat ourselves
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part ~= car.seat then
				local w = Instance.new("WeldConstraint")
				w.Part0 = car.seat
				w.Part1 = part
				w.Parent = car.seat
			end
		end
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then part.Anchored = false end
		end
	end
	if car.npc then
		for _, part in car.npc:GetDescendants() do
			if part:IsA("BasePart") then part.Massless = true part.CanCollide = false end
		end
	end
	-- v286c: the server simulates it (CarServer keeps an empty GTA car on its suspension); a
	-- crashed car rolls free for a few seconds, then the handbrake goes on
	model:SetAttribute("CoastUntil", workspace:GetServerTimeNow() + 4)
	-- v290d: rammed by a player - THEIR machine simulates it through the crash, so the hit lands
	-- the instant their car touches it (server-owned, it was a wall on their screen until the
	-- unanchor came back a round trip later: all their speed gone, then the shove). The server
	-- takes it back once it's had a few seconds to settle.
	local rammer = if owner and not quiet and owner.Parent then owner else nil
	pcall(function()
		car.seat:SetNetworkOwner(rammer)
		car.seat.AssemblyLinearVelocity = velocity
	end)
	if rammer then
		task.delay(5, function()
			if not model.Parent or model:GetAttribute("TrafficStolen") then return end
			local occ = (car.seat :: VehicleSeat).Occupant
			if occ then return end
			pcall(function() car.seat:SetNetworkOwner(nil) end)
		end)
	end
	CollectionService:AddTag(model, "TrafficWreck")
	wrecks[model] = os.clock()
	physCars[model] = car
	-- the driver gets out once it settles
	if not quiet then
		task.spawn(function()
			local t0 = os.clock()
			local still = 0
			while model.Parent and os.clock() - t0 < 12 do
				task.wait(0.25)
				local v = car.seat.Parent and car.seat.AssemblyLinearVelocity.Magnitude or 0
				still = if v < 1.5 then still + 0.25 else 0
				if still >= 1.5 then break end
			end
			if model.Parent and car.npc and not model:GetAttribute("TrafficStolen") then
				driverOut(car, if math.random() < 0.5 then "panic" else "walk", nil)
			end
		end)
	end
	-- too many wrecks: the oldest out-of-sight one goes
	local n = 0
	for _ in wrecks do n += 1 end
	if n > CFG.MaxWrecks then
		local oldest, ot = nil, math.huge
		for m, t in wrecks do if t < ot and not m:GetAttribute("TrafficStolen") then oldest, ot = m, t end end
		if oldest then wrecks[oldest] = nil oldest:Destroy() end
	end
end

---------------------------------------------------------------------------
-- the sim
---------------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function minPlayerDistance(pos: Vector3): number
	local best = math.huge
	for _, p in Players:GetPlayers() do
		local ch = p.Character
		local r = ch and ch:FindFirstChild("HumanoidRootPart")
		if r then best = math.min(best, (flat((r :: BasePart).Position - pos)).Magnitude) end
	end
	return best
end

-- the nearest thing ahead on our path: gap (bumper to bumper) and its speed along our heading
local function leaderAhead(car, look: number, ghost: boolean): (number, number, any)
	local step = 3
	local samples = {}
	for d = 0, look, step do
		local p = pathAt(car, car.dist + d)
		table.insert(samples, p)
	end
	local bestGap, bestV, bestWhat = math.huge, 0, nil
	local function test(pos: Vector3, vel: Vector3, half: number, lat: number, what)
		for k, sp in samples do
			local d = (k - 1) * step
			if d > 0 or k == 1 then
				local dx, dz = pos.X - sp.X, pos.Z - sp.Z
				if dx * dx + dz * dz < lat * lat and math.abs(pos.Y - sp.Y) < 8 then
					local gap = d - CFG.CarHalf - half
					if k == 1 then
						-- alongside / overlapping: only if it's in front of us
						local rel = flat(pos - car.pos)
						local along = rel:Dot(car.heading)
						-- v284e: behind our middle = not in the way; anywhere in our footprint = stop
						if along < (if what and what.person then -CFG.CarHalf * 0.6 else 1) then return end
						gap = math.max(0, along - CFG.CarHalf - half)
					end
					if gap < bestGap then
						bestGap, bestV, bestWhat = gap, vel:Dot(car.heading), what
					end
					return
				end
			end
		end
	end
	if not ghost then
		for _, other in nearbyCars(car.pos, look + 20) do
			if other ~= car then test(other.pos, other.heading * other.v, CFG.CarHalf, 3.4, other) end
		end
	end
	for _, o in obstacles do
		local dx, dz = o.pos.X - car.pos.X, o.pos.Z - car.pos.Z
		if dx * dx + dz * dz < (look + 25) ^ 2 then test(o.pos, o.vel, o.half, o.lat, o) end
	end
	return bestGap, bestV, bestWhat
end

local function idm(v: number, v0: number, gap: number, vLead: number, profile): number
	local a = CFG.Accel * profile.accel
	local b = CFG.Decel
	local free = 1 - (v / math.max(v0, 0.1)) ^ 4
	if gap == math.huge then return a * free end
	local sStar = CFG.MinGap + v * CFG.Headway * profile.gap + v * (v - vLead) / (2 * math.sqrt(a * b))
	local acc = a * (free - (math.max(sStar, 0) / math.max(gap, 0.2)) ^ 2)
	return math.clamp(acc, -45, a)
end

-- may we enter this junction box now?
local function gateOpen(car, g, now: number): boolean
	local J: JRT = g.J
	if car.mode == "flee" or car.mode == "ram" then return true end
	g.arrived = g.arrived or now
	if now - g.arrived > CFG.GateWatchdog then return true end -- the watchdog
	if J.control == "Signal" then
		local st = signalState(J, g.axis)
		if st == "red" then return false end
		if st == "yellow" and (g.enter - car.dist) > CFG.CarHalf + car.v * 0.6 then return false end
	elseif J.control == "Stop" then
		if not g.stoppedAt then return false end
		if now - g.stoppedAt < CFG.StopWait then return false end
		-- first come, first go
		for other, ax in J.occupants do
			if other ~= car and ax ~= g.axis then return false end
		end
		for _, q in J.queue do
			if q ~= car and q.waitAt and q.waitAt < (car.waitAt or now) and cars[q.model] then
				return false
			end
		end
	end
	-- nobody from the other axis in the box
	for other, ax in J.occupants do
		if other ~= car and ax ~= g.axis and cars[other.model] then return false end
	end
	-- don't block the box: room past the exit
	local gap = leaderAhead(car, math.min(120, (g.exit - car.dist) + 2 * CFG.CarHalf + 6), false)
	if gap < (g.exit - car.dist) + 2 then return false end
	return true
end

local function step(car, now: number, dt: number, near: boolean)
	local model = car.model
	if not model.Parent then removeCar(car, false) return end
	if model:GetAttribute("TrafficRecycle") then removeCar(car, true) return end
	-- advance the piece pointer
	while car.pi < #car.pieces and car.dist > car.pieces[car.pi].start + pieceLen(car.pieces[car.pi]) do car.pi += 1 end
	if car.pi > 6 then
		for _ = 1, car.pi - 2 do table.remove(car.pieces, 1) end
		car.pi = 2
	end
	extend(car)
	if car.vanishAt and car.dist >= car.vanishAt - 1 then removeCar(car, true) return end

	local piece = car.pieces[car.pi]
	local laneSpeed = if piece.kind == "lane" then piece.lane.speed else (car.lastLaneSpeed or 20)
	if piece.kind == "lane" then car.lastLaneSpeed = piece.lane.speed end
	local v0 = laneSpeed * car.profile.speed
	-- modes
	if car.mode and now > car.modeUntil then car.mode = nil end
	if car.mode == "flee" then v0 *= 1.55 end
	if car.mode == "surrender" then v0 = 0 end
	local drunk = model:GetAttribute("DrunkDriver") == true
	if drunk then v0 *= 0.8 + 0.3 * math.sin(now * 0.7 + car.dist * 0.01) end
	-- curves ahead: brake in time
	local look = math.clamp(car.v * 2.8 + 26, 30, 90)
	for k = car.pi, #car.pieces do
		local p = car.pieces[k]
		if p.start > car.dist + look then break end
		if p.vmax then
			local d = math.max(0, p.start - car.dist)
			local allowed = math.sqrt(p.vmax * p.vmax + 2 * 10 * d)
			v0 = math.min(v0, allowed)
		end
	end
	-- pulled over by police (CityLife traffic stop)
	local pulled = model:GetAttribute("PullOver") == true
	car.latTarget = 0
	if pulled then
		v0 = 0
		car.latTarget = (if piece.kind == "lane" then piece.lane.laneW else 8) * 0.55
	end
	-- sirens behind: pull right and slow (not inside a junction)
	local inBox = false
	for _, g in car.gates do
		if car.dist >= g.enter and car.dist <= g.exit then inBox = true end
	end
	if car.yieldUntil and now < car.yieldUntil and not inBox and not pulled then
		v0 = math.min(v0, 7)
		car.latTarget = (if piece.kind == "lane" then piece.lane.laneW else 8) * 0.5
	end
	if drunk and not pulled then car.latTarget += 2.2 * math.sin(now * 0.9) end
	-- going around something parked in the lane
	if car.swingUntil and now < car.swingUntil then
		car.latTarget = -(if piece.kind == "lane" then piece.lane.laneW else 8) * 1.05
		v0 = math.min(v0, 10)
	end
	-- v290: backing up from something we can't get round (then try going round again)
	if car.backUntil and now < car.backUntil then
		v0 = 0
	end

	-- the thing ahead
	local ghost = car.ghostUntil ~= nil and now < car.ghostUntil
	local gap, vLead, what = leaderAhead(car, look, ghost)
	local acc = idm(car.v, v0, gap, vLead, car.profile)
	if pulled then acc = math.max(acc, -11) end -- ease to the kerb, no slamming
	-- the next junction gate
	for i = #car.gates, 1, -1 do
		local g = car.gates[i]
		if car.dist > g.exit then
			if g.J.occupants[car] then g.J.occupants[car] = nil end
			local q = table.find(g.J.queue, car)
			if q then table.remove(g.J.queue, q) end
			table.remove(car.gates, i)
		end
	end
	local g = car.gates[1]
	if g and not g.granted then
		local toLine = g.enter - car.dist
		if toLine < car.v * car.v / (2 * 9) + 14 then
			if not table.find(g.J.queue, car) then table.insert(g.J.queue, car) end
			car.waitAt = car.waitAt or now
			if toLine < CFG.MinGap + 5 and car.v < 0.8 and not g.stoppedAt then g.stoppedAt = now end
			if g.J.control ~= "Stop" or g.stoppedAt then
				if gateOpen(car, g, now) then
					g.granted = true
					g.J.occupants[car] = g.axis
					car.waitAt = nil
				end
			end
		end
		if not g.granted then
			local lineGap = toLine - CFG.CarHalf * 0.2
			acc = math.min(acc, idm(car.v, v0, math.max(0.05, lineGap), 0, car.profile))
		end
	end
	-- integrate
	car.v = math.clamp(car.v + acc * dt, 0, CFG.MaxSpeed * 1.6)
	if car.backUntil and now < car.backUntil then
		car.v = 0
		car.dist = math.max(car.pieces[1].start + 0.5, car.dist - 3.5 * dt)
	end
	if not g or g.granted or (g.enter - car.dist) > 0.2 then
		car.dist += car.v * dt
	else
		car.v = 0
	end

	-- stuck watchdog: not moving with no reason we know of
	local reasonToWait = pulled or (g and not g.granted and (g.enter - car.dist) < CFG.MinGap + 8) or (what and what.person)
	if car.v > 0.6 or reasonToWait then
		car.stuckSince = nil
	else
		car.stuckSince = car.stuckSince or now
		local t = now - car.stuckSince
		if what and what.static and t > 2.5 and not car.swingUntil and not car.backUntil then
			car.swingUntil = now + 4.5 -- go around the parked car / wreck
		end
		-- still stuck behind it (no room to swing out): reverse a few studs, then try again
		if what and what.static and t > 6 and not car.backUntil then
			car.backUntil = now + 2.5
			car.swingUntil = nil
		end
		if t > CFG.StuckGhost and not ghost then
			car.ghostUntil = now + 3
			car.stuckSince = now
		end
		if t > CFG.StuckRecycle * 0.5 and minPlayerDistance(car.pos) > 260 then
			removeCar(car, true)
			return
		end
	end
	if car.swingUntil and now > car.swingUntil then car.swingUntil = nil end
	if car.backUntil and now > car.backUntil then
		car.backUntil = nil
		car.swingUntil = now + 6
		car.stuckSince = now
	end

	-- pose
	local pos, h = pathAt(car, car.dist)
	local latStep = 4 * dt
	car.lat += math.clamp(car.latTarget - car.lat, -latStep, latStep)
	local right = Vector3.new(-h.Z, 0, h.X)
	pos += right * car.lat
	-- smooth heading (no snapping at segment joins)
	car.heading = (unit(car.heading:Lerp(h, math.min(1, dt * 8))) or h)
	car.pos = pos
	if near then
		car.groundAt = car.groundAt or 0
		if now > car.groundAt then
			car.groundAt = now + 0.3
			rayParams.FilterDescendantsInstances = { model }
			local hit = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), rayParams)
			car.groundY = if hit and math.abs(hit.Position.Y - pos.Y) < 4 then hit.Position.Y else nil
		end
	end
	local y = car.groundY or pos.Y
	local at = Vector3.new(pos.X, y + car.groundOffset, pos.Z)
	local cf = CFrame.lookAt(at, at + car.heading)
	model:SetAttribute("TrafficPose", cf)
	model:SetAttribute("TrafficVel", car.heading * car.v)
	if near or now > (car.farPivotAt or 0) then
		model:PivotTo(cf)
		car.farPivotAt = now + 2
	end
end

---------------------------------------------------------------------------
-- reactions
---------------------------------------------------------------------------
local function isGun(tool: Instance): boolean
	if not tool:IsA("Tool") then return false end
	if tool:GetAttribute("IsGun") ~= nil then return tool:GetAttribute("IsGun") == true end
	if tool:GetAttribute("GunName") ~= nil or tool:GetAttribute("Issued") ~= nil then return true end
	local n = string.lower(tool.Name)
	for _, k in { "gun", "pistol", "rifle", "shotgun", "smg", "uzi", "ak", "m4", "glock", "revolver", "deagle", "sniper", "mp5", "carbine", "taser" } do
		if n:find(k) then return true end
	end
	return false
end

local function rammed(car, player: Player)
	-- floor it at the player for a moment, then it's a crash
	car.mode = "ram"
	local model = car.model
	local ch = player.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end
	removeCar(car, false)
	CollectionService:RemoveTag(model, "SmoothResidentTraffic")
	model:SetAttribute("TrafficActive", false)
	print(("[Traffic] a driver tries to run %s over"):format(player.Name))
	task.spawn(function()
		local pos = car.pos
		local heading = car.heading
		local speed = math.max(car.v, 8)
		local hit = false
		local t0 = os.clock()
		local last = os.clock()
		while model.Parent and os.clock() - t0 < 3 do
			RunService.Heartbeat:Wait()
			local now = os.clock()
			local dt = now - last
			last = now
			local target = root.Parent and root.Position or (pos + heading * 30)
			local want = unit(flat(target - pos)) or heading
			-- turn toward them, at most ~100 degrees a second
			local ang = math.acos(math.clamp(heading:Dot(want), -1, 1))
			local maxTurn = math.rad(100) * dt
			heading = if ang > maxTurn then (unit(heading:Lerp(want, maxTurn / ang)) or want) else want
			speed = math.min(46, speed + 26 * dt)
			pos += heading * speed * dt
			rayParams.FilterDescendantsInstances = { model }
			local g = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), rayParams)
			local y = if g then g.Position.Y else pos.Y
			local at = Vector3.new(pos.X, y + car.groundOffset, pos.Z)
			model:PivotTo(CFrame.lookAt(at, at + heading))
			if not hit and root.Parent and (flat(root.Position - pos)).Magnitude < 7 then
				hit = true
				local hum = ch:FindFirstChildOfClass("Humanoid")
				if hum then hum:TakeDamage(45) end
				pcall(function() root.AssemblyLinearVelocity = heading * speed * 1.1 + Vector3.new(0, 35, 0) end)
				break
			end
		end
		car.pos = pos
		car.heading = heading
		car.v = speed
		model:SetAttribute("TrafficPose", model:GetPivot())
		model:SetAttribute("Physicalized", nil)
		cars[model] = nil
		physicalize(car, heading * speed, nil, false)
	end)
end

local function aimedAt(car, player: Player)
	if car.reacted then return end
	car.reacted = true
	local roll = math.random()
	local slow = car.v < 12
	local ch = player.Character
	local from = ch and ch:GetPivot().Position
	if car.profile.aggressive and roll < 0.35 then
		rammed(car, player)
	elseif (slow and roll < 0.75) or (not slow and roll < 0.3) then
		-- surrender: stop, out, hands up - the car is left for the taking
		car.mode = "surrender"
		car.modeUntil = os.clock() + 30
		local model = car.model
		print(("[Traffic] a driver surrenders the car to %s"):format(player.Name))
		task.spawn(function()
			local t0 = os.clock()
			while cars[model] and car.v > 0.6 and os.clock() - t0 < 4 do task.wait(0.1) end
			if not cars[model] then return end
			driverOut(car, "surrender", from)
			physicalize(car, Vector3.zero, nil, true)
		end)
	else
		car.mode = "flee"
		car.modeUntil = os.clock() + 10
	end
end

local aimClock = 0
local function reactions(dt: number)
	aimClock += dt
	if aimClock < 0.15 then return end
	local t = aimClock
	aimClock = 0
	for _, p in Players:GetPlayers() do
		local ch = p.Character
		local tool = ch and ch:FindFirstChildOfClass("Tool")
		local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not (tool and root and isGun(tool)) then continue end
		local head = ch:FindFirstChild("Head") :: BasePart?
		-- v284e: where the player is really aiming (their camera, sent by CityLifeClient while
		-- a tool is out); the body only faces the camera in shift-lock
		local look = (head or root).CFrame.LookVector
		local aim = p:GetAttribute("AimDir")
		if typeof(aim) == "Vector3" and os.clock() - (tonumber(p:GetAttribute("AimAtClock")) or 0) < 0.6 then look = aim end
		for _, car in nearbyCars(root.Position, CFG.AimRange) do
			if car.reacted then continue end
			local to = car.pos + Vector3.new(0, 3, 0) - (head or root).Position
			local d = to.Magnitude
			if d < CFG.AimRange and d > 2 and look:Dot(to / d) > CFG.AimDot then
				car.aim[p] = (car.aim[p] or 0) + t
				if car.aim[p] >= CFG.AimTime then aimedAt(car, p) end
			else
				car.aim[p] = nil
			end
		end
	end
	-- sirens: police cars moving fast make traffic ahead of them yield
	local pa = workspace:FindFirstChild("PoliceAI")
	local pv = pa and pa:FindFirstChild("Vehicles")
	local sources = {}
	if pv then for _, m in pv:GetChildren() do table.insert(sources, m) end end
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then
		for _, m in sp:GetChildren() do
			local seat = m:FindFirstChildWhichIsA("VehicleSeat", true)
			local occ = seat and seat.Occupant
			local pl = occ and Players:GetPlayerFromCharacter(occ.Parent)
			if pl and pl.Team and (pl.Team.Name == "LVPD" or pl.Team.Name == "SWAT" or pl.Team.Name:find("Marshal") or pl.Team.Name == "Chief of Police") then table.insert(sources, m) end
		end
	end
	for _, m in sources do
		local pp = m:IsA("Model") and (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true))
		if pp then
			local vel = pp.AssemblyLinearVelocity
			if vel.Magnitude > 18 then
				local dir = unit(flat(vel)) :: Vector3
				for _, car in nearbyCars(pp.Position, 80) do
					local rel = flat(car.pos - pp.Position)
					if rel.Magnitude < 75 and rel:Dot(dir) > 0 and car.heading:Dot(dir) > 0.5 then
						car.yieldUntil = os.clock() + 3
					end
				end
			end
		end
	end
end

-- a crash is coming: make the car real before the hit lands
local function wakeOnImpact()
	-- v284d: only a real predicted collision wakes a car: each car is two circles (front and
	-- back), and the two must actually overlap within the next ~0.35 s. Player cars and
	-- moving wrecks only - the AI police drive themselves around traffic.
	local movers = {}
	local seen: { [Instance]: boolean } = {}
	local function add(m: Instance, owner: Player?)
		if not m:IsA("Model") or seen[m] then return end
		seen[m] = true
		local pp = (m :: Model).PrimaryPart or m:FindFirstChildWhichIsA("VehicleSeat", true)
		if pp and pp:IsA("BasePart") and not pp.Anchored then
			local v = pp.AssemblyLinearVelocity
			-- v290c: 6 -> 2.5 studs/s, so pushing a car at walking pace shoves it too
			if flat(v).Magnitude > 2.5 then
				local fwd = unit(flat(pp.CFrame.LookVector)) or Vector3.new(0, 0, -1)
				-- v290d: a player's car is simulated on their machine: what the server sees is
				-- already old, and waking the traffic car takes a round trip to reach them. Look
				-- ahead by their lag (and start from where the car really is by now).
				local lag = 0
				if owner then
					local ok, ping = pcall(function() return owner:GetNetworkPing() end)
					lag = if ok and type(ping) == "number" then math.clamp(ping, 0, 0.4) else 0.1
				end
				table.insert(movers, {
					pos = pp.Position + flat(v) * lag,
					vel = flat(v),
					fwd = fwd,
					owner = owner,
					look = math.clamp(0.3 + lag * 2.5, 0.3, 0.9),
				})
			end
		end
	end
	-- v290c: whatever a player is driving - their own car, a stolen traffic car, a police car
	for _, p in Players:GetPlayers() do
		local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		if seat and seat:IsA("VehicleSeat") then
			local m: Instance? = seat
			while m and m.Parent ~= workspace and not (m.Parent and m.Parent.Name == "SpawnedCars") do m = m.Parent end
			if m then add(m, p) end
		end
	end
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then
		for _, m in sp:GetChildren() do
			local seat = m:FindFirstChildWhichIsA("VehicleSeat", true)
			local occ = seat and seat.Occupant
			add(m, occ and Players:GetPlayerFromCharacter(occ.Parent))
		end
	end
	-- a wreck knocked into the next car: whoever's machine runs it (the rammer) runs that one too
	for m in wrecks do
		if m.Parent and not m:GetAttribute("TrafficStolen") then
			local seat = m:FindFirstChildWhichIsA("VehicleSeat", true)
			local owner: Player? = nil
			if seat then pcall(function() owner = seat:GetNetworkOwner() end) end
			add(m, owner)
		end
	end
	local R = 5.2 -- circle radius (a car is ~10.5 wide, ~19 long)
	for _, mv in movers do
		local speed = mv.vel.Magnitude
		local steps = {}
		for t = 0, mv.look + 1e-3, 0.06 do table.insert(steps, t) end
		for _, car in nearbyCars(mv.pos, 30 + speed * (mv.look + 0.1)) do
			if math.abs(car.pos.Y - mv.pos.Y) > 10 then continue end
			local cv = car.heading * car.v
			local hit, touching = false, false
			for _, t in steps do
				local a = mv.pos + mv.vel * t
				local b = car.pos + cv * t
				for _, oa in { -4.6, 4.6 } do
					local pa = a + mv.fwd * oa
					for _, ob in { -4.6, 4.6 } do
						local pb = b + car.heading * ob
						local dx, dz = pa.X - pb.X, pa.Z - pb.Z
						if dx * dx + dz * dz < (2 * R) ^ 2 then hit = true touching = t == 0 break end
					end
					if hit then break end
				end
				if hit then break end
			end
			-- a hit coming (v290c: 7 -> 3 studs/s closing speed), or already bumper to bumper
			-- and pushing: either way it has to be a real car the player's car can shove (an
			-- anchored traffic car is a wall - it stopped you dead and never moved)
			local toward = unit(flat(car.pos - mv.pos))
			local closing = if toward then (mv.vel - cv):Dot(toward) else 0
			if hit and (closing > 3 or (touching and mv.owner ~= nil and closing > 1)) then
				physicalize(car, cv, mv.owner, false)
			end
		end
	end
end

---------------------------------------------------------------------------
-- signals and stop signs (built at start, lit by the sim)
---------------------------------------------------------------------------
local controlFolder = workspace:FindFirstChild("TrafficControl")
if controlFolder then controlFolder:Destroy() end
controlFolder = Instance.new("Folder")
controlFolder.Name = "TrafficControl"
controlFolder.Parent = workspace
local lamps: { [number]: { [string]: { red: BasePart, yellow: BasePart, green: BasePart } } } = {}
local LIT = { red = Color3.fromRGB(255, 40, 30), yellow = Color3.fromRGB(255, 190, 30), green = Color3.fromRGB(40, 255, 90) }
local DARK = { red = Color3.fromRGB(60, 15, 12), yellow = Color3.fromRGB(60, 45, 10), green = Color3.fromRGB(10, 50, 20) }
local function P(parent: Instance, size: Vector3, cf: CFrame, colour: Color3, mat: Enum.Material?, shape: Enum.PartType?): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = mat or Enum.Material.SmoothPlastic
	if shape then p.Shape = shape end
	p.Parent = parent
	return p
end
local function buildControls()
	local built = 0
	for _, lane in lanes do
		-- one post per approach: the outermost lane of each road direction
		if lane.idx ~= lane.n then continue end
		for _, j in lane.juncs do
			local J = jrt[j.jid]
			if not J or J.control == "None" or j.s < 20 then continue end
			local road = network[lane.road]
			local rIn = math.clamp((road.width or 30) * 0.25 + 6, 8, 22)
			local base, h = lanePoint(lane, math.max(0, j.s - rIn - 2))
			local right = Vector3.new(-h.Z, 0, h.X)
			local postAt = base + right * (lane.laneW * 0.5 + 4)
			rayParams.FilterDescendantsInstances = { controlFolder }
			local g = workspace:Raycast(postAt + Vector3.new(0, 20, 0), Vector3.new(0, -40, 0), rayParams)
			local gy = if g then g.Position.Y else postAt.Y
			local m = Instance.new("Model")
			m.Name = if J.control == "Signal" then "Signal" else "StopSign"
			local face = CFrame.lookAt(Vector3.new(postAt.X, gy, postAt.Z), Vector3.new(postAt.X, gy, postAt.Z) - h) -- faces the oncoming driver
			if J.control == "Signal" then
				P(m, Vector3.new(0.7, 18, 0.7), face * CFrame.new(0, 9, 0), Color3.fromRGB(55, 58, 62), Enum.Material.Metal)
				local armLen = lane.laneW * 0.9 + 4
				P(m, Vector3.new(armLen, 0.5, 0.5), face * CFrame.new(armLen / 2, 17.5, 0), Color3.fromRGB(55, 58, 62), Enum.Material.Metal)
				local head = face * CFrame.new(armLen - 1.5, 15.6, 0)
				P(m, Vector3.new(1.4, 4.2, 1.2), head, Color3.fromRGB(30, 30, 32), Enum.Material.Metal)
				local set = {}
				for i, c in { "red", "yellow", "green" } do
					set[c] = P(m, Vector3.new(0.95, 0.95, 0.95), head * CFrame.new(0, 1.35 - (i - 1) * 1.35, -0.6), DARK[c], Enum.Material.SmoothPlastic, Enum.PartType.Ball)
				end
				lamps[J.id] = lamps[J.id] or {}
				local axis = axisOf(J, h)
				lamps[J.id][axis .. "#" .. #m:GetChildren() .. built] = set
				set.axis = axis :: any
			else
				P(m, Vector3.new(0.4, 8, 0.4), face * CFrame.new(0, 4, 0), Color3.fromRGB(150, 150, 155), Enum.Material.Metal)
				local sign = P(m, Vector3.new(0.15, 3, 3), face * CFrame.new(0, 8.3, -0.25) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(190, 20, 20), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
				local gui = Instance.new("SurfaceGui")
				gui.Face = Enum.NormalId.Left
				gui.CanvasSize = Vector2.new(200, 200)
				gui.Parent = sign
				local t = Instance.new("TextLabel")
				t.Size = UDim2.fromScale(1, 1)
				t.BackgroundTransparency = 1
				t.Font = Enum.Font.GothamBlack
				t.TextScaled = true
				t.TextColor3 = Color3.new(1, 1, 1)
				t.Text = "STOP"
				t.Parent = gui
				local g2 = gui:Clone()
				g2.Face = Enum.NormalId.Right
				g2.Parent = sign
			end
			m.Parent = controlFolder
			built += 1
		end
	end
	return built
end
local function lightSignals()
	for jid, sets in lamps do
		local J = jrt[jid]
		for _, set in sets do
			local st = signalState(J, (set :: any).axis)
			for _, c in { "red", "yellow", "green" } do
				local lamp = (set :: any)[c] :: BasePart
				local on = c == st
				if (lamp.Material == Enum.Material.Neon) ~= on then
					lamp.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
					lamp.Color = if on then LIT[c] else DARK[c]
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- spawning
---------------------------------------------------------------------------
local spawnPoints = {}
for _, lane in lanes do
	for s = 10, lane.len - 10, 35 do table.insert(spawnPoints, { lane = lane, s = s }) end
end
-- v288c: realistic density. The target is the road actually near players (spawn points are
-- every 35 studs of lane) times a density for the hour - it used to be a flat 30 + 40 per player
-- packed round you whatever the time. Studs of lane per car:
local function studsPerCar(): number
	local t = game:GetService("Lighting").ClockTime
	if t < 5 then return 650 end -- dead of night
	if t < 7 then return 420 end -- early morning
	if t < 9.5 then return 200 end -- morning rush
	if t < 16 then return 320 end -- midday
	if t < 19 then return 200 end -- evening rush
	if t < 22 then return 380 end -- evening (the Strip stays busy-ish)
	return 520
end
local nearLane, nearLaneAt = 0, -1e9
local function targetCount(): number
	if #Players:GetPlayers() == 0 then return 0 end
	if os.clock() - nearLaneAt > 10 then
		nearLaneAt = os.clock()
		local n = 0
		for _, sp in spawnPoints do
			if minPlayerDistance(lanePoint(sp.lane, sp.s)) <= CFG.Despawn then n += 1 end
		end
		nearLane = n * 35
	end
	return math.min(CFG.TargetMax, math.floor(nearLane / (studsPerCar() * CFG.Density)))
end
-- v290c: crashed and abandoned traffic near players still fills the road - it counts
local function parkedNearPlayers(): number
	local n = 0
	for m in wrecks do
		if m.Parent and minPlayerDistance(m:GetPivot().Position) <= CFG.Despawn then n += 1 end
	end
	for m in stolenCars do
		if not m.Parent then stolenCars[m] = nil end
	end
	for m in physCars do
		if not m.Parent then physCars[m] = nil end
	end
	return n
end
local function trySpawn(): boolean
	if #spawnPoints == 0 then return false end
	for _ = 1, 25 do
		local sp = spawnPoints[math.random(1, #spawnPoints)]
		local pos = lanePoint(sp.lane, sp.s)
		local d = minPlayerDistance(pos)
		if #Players:GetPlayers() == 0 or (d >= CFG.SpawnMin and d <= CFG.SpawnMax) then
			local clear = true
			for _, other in nearbyCars(pos, 40) do
				if (other.pos - pos).Magnitude < 30 then clear = false break end
			end
			if clear then return spawnAt(sp.lane, sp.s) end
		end
	end
	return false
end

---------------------------------------------------------------------------
-- go
---------------------------------------------------------------------------
-- the old engine stands down
local old = script.Parent:FindFirstChild("CivilianTrafficServer")
if old and old:IsA("Script") then old.Enabled = false end

local controls = buildControls()
local nSignal, nStop = 0, 0
for _, J in jrt do
	if J.control == "Signal" then nSignal += 1 elseif J.control == "Stop" then nStop += 1 end
end
print(("[Traffic] v284 online: %d lanes, %d junctions (%d signals, %d all-way stops), %d posts placed"):format(#lanes, #junctions, nSignal, nStop, controls))

local gridClock, wakeClock, lightClock, spawnClock = 0, 0, 0, 0
RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	gridClock += dt
	if gridClock > 0.2 then
		gridClock = 0
		rebuildGrid()
	end
	wakeClock += dt
	if wakeClock > 0 then -- v290d: every frame (was 20 a second - a fast car covered 4 studs between looks)
		wakeClock = 0
		local ok, err = pcall(wakeOnImpact)
		if not ok then warn("[Traffic] wake: " .. tostring(err)) end
	end
	local okR, errR = pcall(reactions, dt)
	if not okR then warn("[Traffic] reactions: " .. tostring(errR)) end
	lightClock += dt
	if lightClock > 0.25 then
		lightClock = 0
		lightSignals()
	end
	for model, car in cars do
		if now >= car.nextTick then
			local near = minPlayerDistance(car.pos) < CFG.NearRadius
			local tick = if near then CFG.NearTick else CFG.FarTick
			local cdt = math.min(now - car.lastTick, 0.7)
			car.lastTick = now
			car.nextTick = now + tick
			local ok, err = pcall(step, car, now, cdt, near)
			if not ok then
				warn("[Traffic] car retired: " .. tostring(err))
				removeCar(car, true)
			end
		end
	end
end)

-- population: despawn far cars, refill near players; wrecks clean up out of sight
task.spawn(function()
	while true do
		task.wait(0.5)
		for model, car in cars do
			if #Players:GetPlayers() > 0 and minPlayerDistance(car.pos) > CFG.Despawn then removeCar(car, true) end
		end
		local missing = targetCount() - carCount - parkedNearPlayers()
		for _ = 1, math.min(4, math.max(0, missing)) do
			local ok, err = pcall(trySpawn)
			if not ok then warn("[Traffic] spawn: " .. tostring(err)) end
		end
		local now = os.clock()
		for m, t in wrecks do
			if not m.Parent or m:GetAttribute("TrafficStolen") then
				wrecks[m] = nil
			elseif now - t > CFG.WreckLife or (now - t > 30 and minPlayerDistance(m:GetPivot().Position) > 320) then
				wrecks[m] = nil
				m:Destroy()
			end
		end
	end
end)

-- v286j: the carjack (F at a traffic car, via CarServer): stop it, walk to the driver's door,
-- swing it open, drag the driver out, get in, door shut. A car doing more than ~10 studs/s
-- can't be taken.
do
	local cj = ServerStorage:FindFirstChild("TrafficCarjack") or Instance.new("BindableEvent")
	cj.Name = "TrafficCarjack"
	cj.Parent = ServerStorage
	local busy: { [Player]: boolean } = {}
	local function setDoor(model: Model, open: boolean)
		local fn = ServerStorage:FindFirstChild("SetCarDoor")
		if fn and fn:IsA("BindableFunction") then pcall(fn.Invoke, fn, model, "driver", open) end
	end
	local function carjack(player: Player, model: Model)
		if busy[player] then return end
		local car = cars[model] or physCars[model]
		local ch = player.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not car and hum and not hum.SeatPart then
			-- a traffic car we don't track any more: just get in
			local s = model:FindFirstChildWhichIsA("VehicleSeat", true)
			if s and not s.Occupant then
				player:SetAttribute("CarEnterAt", workspace:GetServerTimeNow())
				s.Disabled = false
				s:Sit(hum)
			end
			return
		end
		if not car or not hum or not root or hum.Health <= 0 or hum.SeatPart then
			print(("[Traffic] carjack %s refused: car=%s hum=%s seated=%s"):format(player.Name, tostring(car ~= nil), tostring(hum ~= nil), tostring(hum and hum.SeatPart ~= nil)))
			return
		end
		local seat = car.seat
		if not seat.Parent or seat.Occupant then
			print(("[Traffic] carjack %s refused: seat %s"):format(player.Name, if seat.Parent then "occupied" else "gone"))
			return
		end
		busy[player] = true
		local ok, err = pcall(function()
			-- 1. it has to stop
			if cars[model] then
				-- v286y: up to ~30 studs/s the driver panics and brakes when you grab for the door (GTA);
				-- only a car really moving gets away (was 10: cars rolling through traffic all refused)
				if car.v > 30 then
					busy[player] = nil
					print(("[Traffic] carjack %s refused: car moving %.1f studs/s"):format(player.Name, car.v))
					return
				end
				car.mode = "surrender"
				car.modeUntil = os.clock() + 15
				local t0 = os.clock()
				while cars[model] and car.v > 0.5 and os.clock() - t0 < 3.5 do task.wait(0.05) end
				physicalize(car, Vector3.zero, nil, true)
			end
			-- 2. to the driver's door (the left of the driver's seat)
			-- v286s: from wherever you pressed F you walk ROUND the car to that door (you used to
			-- stop after 1.6 s wherever you were - at the back - and get in from there)
			local side = Vector3.new(-seat.CFrame.RightVector.X, 0, -seat.CFrame.RightVector.Z).Unit
			local fwd = Vector3.new(seat.CFrame.LookVector.X, 0, seat.CFrame.LookVector.Z).Unit
			local boxCF, size = model:GetBoundingBox()
			local half, halfLen = math.min(size.X, size.Z) / 2, math.max(size.X, size.Z) / 2
			local mid = boxCF.Position
			local door = seat.Position + side * (half + 2.2)
			local function flatDist(p: Vector3): number
				return (Vector3.new(p.X, 0, p.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
			end
			local function walkTo(p: Vector3)
				local goal = Vector3.new(p.X, root.Position.Y, p.Z)
				local limit = math.clamp(flatDist(goal) / math.max(hum.WalkSpeed, 8) + 0.8, 0.8, 4)
				hum:MoveTo(goal)
				local t0 = os.clock()
				while os.clock() - t0 < limit and flatDist(goal) > 2.5 and hum.Health > 0 do task.wait(0.05) end
			end
			local rel = root.Position - mid
			local across = rel:Dot(side)
			if across < half + 0.5 then
				-- not on the driver's side yet: round the nearer end of the car
				local endSign = if rel:Dot(fwd) >= 0 then 1 else -1
				local endOff = fwd * endSign * (halfLen + 2.5)
				if across < -(half - 0.5) then walkTo(mid + endOff - side * (half + 2.2)) end
				walkTo(mid + endOff + side * (half + 2.2))
			end
			walkTo(door)
			hum:MoveTo(root.Position)
			if flatDist(door) > 3 then
				root.CFrame = CFrame.new(Vector3.new(door.X, root.Position.Y, door.Z)) -- blocked: at the door anyway
			end
			root.CFrame = CFrame.lookAt(root.Position, Vector3.new(seat.Position.X, root.Position.Y, seat.Position.Z))
			-- 3. the door, the driver
			setDoor(model, true)
			task.wait(0.4)
			if car.npc then
				local re = game:GetService("ReplicatedStorage"):FindFirstChild("CityLife")
				if re and re:IsA("RemoteEvent") then re:FireAllClients("bubble", seat, "Hey! HEY! Get off me!") end
				driverOut(car, "panic", root.Position)
			end
			task.wait(0.45)
			-- 4. in, and shut it
			if seat.Occupant or hum.Health <= 0 then
				print(("[Traffic] carjack %s failed at the door: seat %s, health %d"):format(player.Name, if seat.Occupant then "taken" else "free", hum.Health))
				return
			end
			player:SetAttribute("CarEnterAt", workspace:GetServerTimeNow())
			seat.Disabled = false
			seat:Sit(hum)
			task.delay(0.9, function() if model.Parent then setDoor(model, false) end end)
			print(("[Traffic] %s carjacked a %s"):format(player.Name, tostring(model:GetAttribute("TrafficCarType"))))
		end)
		busy[player] = nil
		if not ok then warn("[Traffic] carjack: " .. tostring(err)) end
	end
	cj.Event:Connect(function(player, model)
		if typeof(player) == "Instance" and player:IsA("Player") and typeof(model) == "Instance" and model:IsA("Model") then
			task.spawn(carjack, player, model)
		end
	end)
end

-- v284e: the driver's machine sees a crash coming before the server does (no lag): it asks
-- for the traffic car to become real physics, so you hit a car - not an anchored wall
do
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local wake = ReplicatedStorage:FindFirstChild("TrafficWake") or Instance.new("RemoteEvent")
	wake.Name = "TrafficWake"
	wake.Parent = ReplicatedStorage
	wake.OnServerEvent:Connect(function(player, model)
		if typeof(model) ~= "Instance" or not model:IsA("Model") then return end
		local car = cars[model :: Model]
		if not car then return end
		local ch = player.Character
		local r = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
		-- (v290d: 70 -> 170: a car the player knocked into the next one asks for it too)
		if not r or (flat(r.Position - car.pos)).Magnitude > 170 then return end
		physicalize(car, car.heading * car.v, player, false)
	end)
end

-- gunshots nearby: panic
task.spawn(function()
	local shot = ServerStorage:WaitForChild("ShotFired", 30)
	if shot and shot:IsA("BindableEvent") then
		shot.Event:Connect(function(player: any)
			local ch = typeof(player) == "Instance" and player:IsA("Player") and player.Character
			local r = ch and ch:FindFirstChild("HumanoidRootPart")
			if not r then return end
			for _, car in nearbyCars((r :: BasePart).Position, CFG.PanicRadius) do
				if not car.mode then
					car.mode = "flee"
					car.modeUntil = os.clock() + 8
				end
			end
		end)
	end
end)

-- debug: Workspace attribute TrafficDebug = true prints a summary every 10 s
task.spawn(function()
	while true do
		task.wait(10)
		if workspace:GetAttribute("TrafficDebug") then
			local waiting, moving, stuck = 0, 0, 0
			for _, car in cars do
				if car.v > 0.6 then moving += 1 elseif car.stuckSince then stuck += 1 else waiting += 1 end
			end
			local w = 0
			for _ in wrecks do w += 1 end
			print(("[Traffic] %d cars: %d moving, %d waiting, %d stuck, %d wrecks"):format(carCount, moving, waiting, stuck, w))
		end
	end
end)
