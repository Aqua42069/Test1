--[[
	PoliceAI · Driver  (PursuitDriver / VehicleAI)
	Drives a police cruiser along a polyline that the pursuit coordinator keeps updating:
	a mapped-road route, or the suspect's own observed breadcrumb trail when the car is
	close behind him. Same server-owned AlignPosition "ghost car" chassis the rest of the
	PoliceSystem uses (no flipping, no flinging), but with pursuit physics:
	  - acceleration / braking limits
	  - cornering speed from path curvature (lateral grip), braking early for corners
	  - speed matching to the car it is chasing, following gap
	  - spacing from other cruisers on the same line (no conga-line pile-ups)
	It never teleports: the car only ever moves along its path at its current speed.
	Transport (Justice) cancels it the same way it cancels Van:drive (driveToken).

	v114 - physical pursuit:
	  - contact mode: the cruiser's body becomes solid against the suspect's car only
	    (collision group PolicePursuit <-> PoliceSuspectCar), with a finite horizontal
	    force and a mass matched to the suspect car, so it can bump / PIT / box in
	  - closed loop: the target never runs more than a few studs ahead of where the car
	    really is (a blocked car stops pushing instead of snapping forward later)
	  - target mode: a 10 Hz callback steers straight at a moving point (maneuvers)
]]

local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

local Driver = {}
local Ctx, Tuning, Log, Util, RoadGraph, Van, State

local active: { [any]: any } = {}

function Driver.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, RoadGraph, Van, State = ctx.Tuning, ctx.Log, ctx.Util, ctx.RoadGraph, ctx.Van, ctx.State
	-- collision groups: pursuit cars touch the suspect's car and nothing else
	local ok, err = pcall(function()
		for _, name in { "PolicePursuit", "PoliceSuspectCar" } do
			if not PhysicsService:IsCollisionGroupRegistered(name) then
				PhysicsService:RegisterCollisionGroup(name)
			end
		end
		for _, g in PhysicsService:GetRegisteredCollisionGroups() do
			if g.name ~= "PoliceSuspectCar" then
				PhysicsService:CollisionGroupSetCollidable("PolicePursuit", g.name, false)
			end
		end
		PhysicsService:CollisionGroupSetCollidable("PolicePursuit", "PoliceSuspectCar", true)
		-- the suspect's car keeps colliding with everything exactly as a Default part would
		for _, g in PhysicsService:GetRegisteredCollisionGroups() do
			if g.name ~= "PolicePursuit" and g.name ~= "PoliceSuspectCar" then
				PhysicsService:CollisionGroupSetCollidable("PoliceSuspectCar", g.name, PhysicsService:CollisionGroupsAreCollidable("Default", g.name))
			end
		end
		PhysicsService:CollisionGroupSetCollidable("PoliceSuspectCar", "PoliceSuspectCar", true)
	end)
	Driver.groupsReady = ok
	if not ok then
		Log.warn("collision groups (pursuit contact disabled)", err)
	end
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	if v.Magnitude < 1e-3 then
		return fallback
	end
	return v.Unit
end

---------------------------------------------------------------------------
-- polyline helpers
---------------------------------------------------------------------------
local function lengths(pts: { Vector3 }): ({ number }, number)
	local acc = { 0 }
	for i = 2, #pts do
		acc[i] = acc[i - 1] + (pts[i] - pts[i - 1]).Magnitude
	end
	return acc, acc[#pts]
end

local function pointAt(drv: any, s: number): Vector3
	local pts, acc = drv.pts, drv.acc
	local n = #pts
	if s <= 0 then
		return pts[1]
	end
	if s >= acc[n] then
		return pts[n]
	end
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if acc[mid] < s then
			lo = mid
		else
			hi = mid
		end
	end
	local seg = acc[hi] - acc[lo]
	local t = if seg > 0 then (s - acc[lo]) / seg else 0
	return pts[lo]:Lerp(pts[hi], t)
end

local function tangent(drv: any, s: number): Vector3
	return safeUnit(flat(pointAt(drv, s + 4) - pointAt(drv, s - 2)), drv.heading)
end

-- closest point on the polyline to `pos` -> distance along, lateral error
local function project(pts: { Vector3 }, acc: { number }, pos: Vector3): (number, number)
	local bestS, bestD = 0, math.huge
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local ab = flat(b - a)
		local L2 = ab:Dot(ab)
		local t = 0
		if L2 > 1e-4 then
			t = math.clamp(flat(pos - a):Dot(ab) / L2, 0, 1)
		end
		local q = a:Lerp(b, t)
		local d = flat(pos - q).Magnitude
		if d < bestD then
			bestD = d
			bestS = acc[i] + (acc[i + 1] - acc[i]) * t
		end
	end
	return bestS, bestD
end

-- Put `goal` at the end of a road route when it's (nearly) on that road.
local function finishAt(pts: { Vector3 }, goal: Vector3, maxGap: number?): { Vector3 }
	local n = #pts
	local last = pts[n]
	if flat(goal - last).Magnitude > (maxGap or 45) then
		return pts
	end
	if n >= 2 then
		local a = pts[n - 1]
		local ab = flat(last - a)
		local L2 = ab:Dot(ab)
		if L2 > 1 then
			local t = flat(goal - a):Dot(ab) / L2
			if t >= 0 and t <= 1 then
				pts[n] = goal -- goal sits on the last segment: stop there instead of overshooting
				return pts
			end
		end
	end
	table.insert(pts, goal)
	return pts
end
Driver.finishAt = finishAt

---------------------------------------------------------------------------
-- ground following that ignores cars (civilian traffic, the suspect's car)
---------------------------------------------------------------------------
local skipCache: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isVehiclePart(inst: Instance): boolean
	local cached = skipCache[inst]
	if cached ~= nil then
		return cached
	end
	local top: Instance? = nil
	local node: Instance? = inst.Parent
	while node and node ~= workspace do
		if node:IsA("Model") then
			top = node
		end
		node = node.Parent
	end
	local skip = false
	if top then
		skip = top:FindFirstChildWhichIsA("VehicleSeat", true) ~= nil or top:FindFirstChildOfClass("Humanoid") ~= nil
	end
	skipCache[inst] = skip
	return skip
end

local function groundY(drv: any, x: number, z: number, nearY: number): number
	local params = drv.params
	for _ = 1, 4 do
		local hit = workspace:Raycast(Vector3.new(x, nearY + 10, z), Vector3.new(0, -40, 0), params)
		if not hit then
			return drv.lastY or nearY
		end
		local inst = hit.Instance
		if inst:IsA("BasePart") and not inst:IsA("Terrain") and (inst.Transparency >= 0.6 or isVehiclePart(inst)) then
			params:AddToFilter(inst)
			continue
		end
		drv.lastY = hit.Position.Y
		return hit.Position.Y
	end
	return drv.lastY or nearY
end

---------------------------------------------------------------------------
-- speed limits
---------------------------------------------------------------------------
local LOOKS = { 10, 24, 44, 70 }
local function curveLimit(drv: any, s: number): number
	local V = Tuning.Vehicles
	local h0 = tangent(drv, s)
	local best = math.huge
	for _, L in LOOKS do
		if s + L > drv.total then
			break
		end
		local hL = tangent(drv, s + L)
		local ang = math.acos(math.clamp(h0:Dot(hL), -1, 1))
		if ang > 0.09 then
			local radius = math.max(12, 22 / ang)
			local corner = math.sqrt(V.Grip * radius)
			local allowed = math.sqrt(corner * corner + 2 * V.Brake * math.max(0, L - 8))
			if allowed < best then
				best = allowed
			end
		end
	end
	return best
end

local function spacingLimit(drv: any): number
	local V = Tuning.Vehicles
	local body = drv.van.body
	local myPos = body.Position
	local best = math.huge
	for other, od in active do
		if other ~= drv.van and not other.dead and other.body and other.body.Parent then
			local rel = flat(other.body.Position - myPos)
			local d = rel.Magnitude
			if d < 70 and d > 0.1 then
				if drv.heading:Dot(rel / d) > 0.86 and drv.heading:Dot(od.heading) > 0.3 then
					best = math.min(best, math.max(0, od.speed + (d - V.CarSpacing) * 0.9))
				end
			end
		end
	end
	-- parked police cars on the line (roadblock / scene) are obstacles too
	return best
end

---------------------------------------------------------------------------
-- control loop
---------------------------------------------------------------------------
local function stopLoop(drv: any)
	if drv.conn then
		drv.conn:Disconnect()
		drv.conn = nil
	end
	if active[drv.van] == drv then
		active[drv.van] = nil
	end
end

local function step(drv: any, dt: number)
	local van = drv.van
	local body = van.body
	if van.dead or not body or not body.Parent or van.driveToken ~= drv.token or van.transporting then
		stopLoop(drv)
		return
	end
	drv.accum += dt
	if drv.accum < 1 / 30 then
		return
	end
	dt = math.min(drv.accum, 0.08)
	drv.accum = 0
	local V = Tuning.Vehicles
	local L = van.cfg.Size.Z
	drv.frame += 1

	-- target mode (maneuvers): re-aim at the moving point 10x a second
	if drv.targetFn and drv.frame % 3 == 0 then
		local ok, tpos, tspeed, tdir = pcall(drv.targetFn, drv)
		if ok and tpos then
			local here = van.parts.ap.Position
			local dir = safeUnit(flat(tdir or (tpos - here)), drv.heading)
			local pts = { here, tpos, tpos + dir * 25 }
			local acc, total = lengths(pts)
			drv.pts, drv.acc, drv.total, drv.s = pts, acc, total, 0
			drv.endGap = 25
			drv.targetSpeed = tspeed or 0
			drv.actualS = nil
		elseif not ok or tpos == nil then
			drv.targetFn = nil
		end
	end

	-- path mode (close pursuit): rebuild the trail path 10x a second
	if drv.pathFn and not drv.targetFn and drv.frame % 3 == 2 then
		local ok, pts, opts = pcall(drv.pathFn, drv)
		if ok and pts and #pts >= 2 then
			Driver.setPath(drv, pts, opts, true)
		else
			drv.pathFn = nil
		end
	end

	-- closed loop: never let the target run away from a car that is blocked / shoved
	if drv.frame % 3 == 1 then
		local aS, lat = project(drv.pts, drv.acc, body.Position)
		drv.actualS, drv.actualLat = aS, lat
	end
	if drv.actualS and drv.s - drv.actualS > 12 then
		drv.s = math.max(drv.actualS + 12, 0)
		local real = flat(body.AssemblyLinearVelocity).Magnitude
		drv.speed = math.min(drv.speed, real + 6)
	end

	local limitEnd = drv.total - drv.endGap
	local remaining = limitEnd - drv.s
	local ts = drv.targetSpeed or 0
	local vEnd
	if remaining > 0 then
		vEnd = math.sqrt(2 * V.Brake * remaining) + ts * 0.95
	else
		vEnd = math.max(0, ts * 0.9 + remaining * 1.5)
	end
	local target = math.min(drv.cap, vEnd, curveLimit(drv, drv.s), if drv.ignoreSpacing then math.huge else spacingLimit(drv))
	if drv.holdStill then
		target = 0
	end
	local accel = if target > drv.speed then V.Accel else V.Brake
	drv.speed = math.max(0, drv.speed + math.clamp(target - drv.speed, -accel * dt, accel * dt))
	local maxS = math.max(limitEnd, drv.s)
	drv.s = math.min(drv.s + drv.speed * dt, maxS)

	local pos = pointAt(drv, drv.s)
	local look = flat(pointAt(drv, drv.s + 7) - pos)
	if look.Magnitude > 0.3 then
		drv.heading = safeUnit(drv.heading:Lerp(look.Unit, math.clamp(dt * 6, 0, 1)), look.Unit)
	end
	local heading = drv.heading
	if drv.laneShift and drv.laneShift ~= 0 then
		pos += Vector3.new(-heading.Z, 0, heading.X) * drv.laneShift
	end
	if drv.frame % 2 == 0 or not drv.frontY then
		drv.frontY = groundY(drv, pos.X + heading.X * L * 0.35, pos.Z + heading.Z * L * 0.35, pos.Y)
		drv.backY = groundY(drv, pos.X - heading.X * L * 0.35, pos.Z - heading.Z * L * 0.35, pos.Y)
	end
	local frontY, backY = drv.frontY, drv.backY
	local midY = (frontY + backY) / 2
	van.parts.ap.Position = Vector3.new(pos.X, midY + van.rideHeight, pos.Z)
	local forward = safeUnit(heading * (L * 0.7) + Vector3.new(0, frontY - backY, 0), heading)
	van.parts.ao.CFrame = CFrame.lookAt(Vector3.zero, forward)

	if drv.stopAtEnd and not drv.arrived and remaining <= 1.5 and drv.speed < 1.5 then
		drv.arrived = true
		if drv.onArrive then
			task.spawn(drv.onArrive, drv)
		end
	end
end

---------------------------------------------------------------------------
-- physical contact with the suspect's car
---------------------------------------------------------------------------
local function setForces(van: any, xz: number?)
	local ap = van.parts.ap
	if xz then
		local ok = pcall(function()
			ap.ForceLimitMode = Enum.ForceLimitMode.PerAxis
			ap.ForceRelativeTo = Enum.ActuatorRelativeTo.World
			ap.MaxAxesForce = Vector3.new(xz, 1e8, xz)
		end)
		if not ok then
			ap.MaxForce = xz * 1.5
		end
	else
		pcall(function()
			ap.ForceLimitMode = Enum.ForceLimitMode.Magnitude
		end)
		ap.MaxForce = 1e8
	end
end

-- pushFactor: max horizontal shove as a share of the suspect car's weight.
function Driver.setContact(drv: any, pushFactor: number, suspectMass: number)
	local van = drv.van
	local body = van.body
	if not Tuning.Contact.Enabled or not Driver.groupsReady or not body or not body.Parent then
		return
	end
	local vol = body.Size.X * body.Size.Y * body.Size.Z
	local wantMass = math.clamp(suspectMass * Tuning.Contact.MassMatch, 150, 25000)
	local density = math.clamp(wantMass / math.max(vol, 1), 0.4, 100)
	if not drv.contact then
		drv.contact = true
		body.CollisionGroup = "PolicePursuit"
		body.CanCollide = true
		body.CustomPhysicalProperties = PhysicalProperties.new(density, 0.35, 0.05, 1, 1)
	end
	local mass = density * vol
	local push = math.max(mass * 170, suspectMass * workspace.Gravity * pushFactor)
	if drv.push ~= push then
		drv.push = push
		setForces(van, push)
	end
end

function Driver.clearContact(drv: any)
	if not drv.contact then
		return
	end
	drv.contact = false
	drv.push = nil
	local van = drv.van
	local body = van.body
	if body and body.Parent then
		body.CollisionGroup = "PoliceVehicle"
		body.CanCollide = false
		body.CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.3, 0.2)
	end
	setForces(van, nil)
end

function Driver.hasContact(drv: any): boolean
	return drv.contact == true
end

-- Steer straight at a moving point (maneuvers). fn(drv) -> (pos, speed, forwardDir) or nil to stop.
-- Follow a path that is rebuilt 10x a second. fn(drv) -> (points, opts) or nil to stop.
function Driver.setPathFn(drv: any, fn: ((any) -> ({ Vector3 }?, any?))?)
	drv.pathFn = fn
	if fn then
		drv.routeGoal = nil
	end
end

function Driver.setTarget(drv: any, fn: ((any) -> (Vector3?, number?, Vector3?))?)
	drv.targetFn = fn
	if fn then
		drv.pathFn = nil
		drv.stopAtEnd = false
		drv.onArrive = nil
		drv.holdStill = false
		drv.routeGoal = nil
	end
end

function Driver.setLabel(van: any, text: string?)
	if not Tuning.UnitLabels then
		text = nil
	end
	local body = van.body
	if not body or not body.Parent then
		return
	end
	local gui = body:FindFirstChild("PursuitRoleTag")
	if not text then
		if gui then
			gui:Destroy()
		end
		return
	end
	if not gui then
		local g = Instance.new("BillboardGui")
		g.Name = "PursuitRoleTag"
		g.Size = UDim2.fromOffset(150, 26)
		g.StudsOffset = Vector3.new(0, van.cfg.Size.Y + 2.5, 0)
		g.MaxDistance = 260
		g.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = Color3.fromRGB(10, 20, 60)
		label.BackgroundTransparency = 0.3
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.Parent = g
		g.Parent = body
		gui = g
	end
	local label = (gui :: Instance):FindFirstChild("Text") :: TextLabel?
	if label and label.Text ~= text then
		label.Text = text
	end
end

function Driver.get(van: any): any?
	local drv = active[van]
	if drv and drv.token == van.driveToken and drv.conn then
		return drv
	end
	return nil
end

-- Take control of a cruiser (cancels any legacy Van:drive route).
function Driver.take(van: any): any
	local existing = Driver.get(van)
	if existing then
		return existing
	end
	local body = van.body
	van.driveToken += 1
	local token = van.driveToken
	van.mode = "respond" -- keeps legacy dispatch / custody transport from grabbing a car mid-chase
	van.parked = false
	van.aiParkedFor = nil
	for _, part in van.model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			if part ~= body then
				part.Anchored = false
			end
		end
	end
	body.Anchored = false
	body.CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.3, 0.2) -- undo roadblock weighting
	body.CollisionGroup = "PoliceVehicle"
	setForces(van, nil)
	van.aiRoadblock = nil
	local ap, ao = van.parts.ap, van.parts.ao
	ap.Enabled = true
	ao.Enabled = true
	ap.MaxForce = 1e8
	ao.MaxTorque = 1e8
	ap.Responsiveness = 35
	ao.Responsiveness = 22
	pcall(function()
		body:SetNetworkOwner(nil)
	end)
	ap.Position = body.Position
	ao.CFrame = body.CFrame.Rotation
	van:setEmergency(true)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = table.clone(Util.ignoreRoots)
	local rn = workspace:FindFirstChild("RoadNetwork")
	if rn then
		table.insert(ignore, rn)
	end
	for _, c in Util.playerCharacters() do
		table.insert(ignore, c)
	end
	params.FilterDescendantsInstances = ignore

	local look = safeUnit(flat(body.CFrame.LookVector), Vector3.zAxis)
	local drv = {
		van = van,
		token = token,
		speed = flat(body.AssemblyLinearVelocity).Magnitude,
		heading = look,
		s = 0,
		pts = { body.Position, body.Position + look * 2 },
		acc = { 0, 2 },
		total = 2,
		endGap = 0,
		cap = Tuning.Vehicles.PursuitSpeed,
		targetSpeed = 0,
		stopAtEnd = false,
		arrived = false,
		laneShift = 0,
		accum = 0,
		frame = 0,
		params = params,
		routeAt = -math.huge,
		routeFails = 0,
	}
	drv.conn = RunService.Heartbeat:Connect(function(dt)
		step(drv, dt)
	end)
	active[van] = drv
	return drv
end

-- Stop controlling the car (it keeps its current AlignPosition target).
function Driver.release(van: any)
	local drv = active[van]
	if drv then
		drv.targetFn = nil
		Driver.clearContact(drv)
		stopLoop(drv)
	end
end

local function applyOpts(drv: any, o: any)
	if o.endGap ~= nil then
		drv.endGap = o.endGap
	end
	if o.cap ~= nil then
		drv.cap = o.cap
	end
	if o.targetSpeed ~= nil then
		drv.targetSpeed = o.targetSpeed
	end
	if o.laneShift ~= nil then
		drv.laneShift = o.laneShift
	end
	if o.stopAtEnd ~= nil then
		if o.stopAtEnd ~= drv.stopAtEnd then
			drv.arrived = false
		end
		drv.stopAtEnd = o.stopAtEnd
		if o.stopAtEnd == false then
			drv.onArrive = nil
		end
	end
	if o.onArrive ~= nil then
		drv.onArrive = o.onArrive
	end
	drv.holdStill = o.holdStill == true
end

-- Replace the path. The car is projected onto it, so switching paths never jumps.
function Driver.setPath(drv: any, pts: { Vector3 }, opts: any?, keepFn: boolean?)
	if #pts < 2 then
		return
	end
	drv.targetFn = nil
	if not keepFn then
		drv.pathFn = nil
	end
	local body = drv.van.body
	local here = drv.van.parts.ap.Position
	local acc, total = lengths(pts)
	local s, lateral = project(pts, acc, here)
	if lateral > 12 then
		-- not on this path yet: blend in from where we actually are
		local copy = { here }
		local startIdx = 1
		for i = 1, #pts - 1 do
			if acc[i + 1] >= s then
				startIdx = i + 1
				break
			end
		end
		for i = startIdx, #pts do
			table.insert(copy, pts[i])
		end
		if #copy < 2 then
			table.insert(copy, pts[#pts])
		end
		pts = copy
		acc, total = lengths(pts)
		s = 0
	end
	drv.pts, drv.acc, drv.total, drv.s = pts, acc, total, s
	drv.pathSetAt = os.clock()
	if body then
		drv.lastY = body.Position.Y - drv.van.rideHeight
	end
	if opts then
		applyOpts(drv, opts)
	end
end

function Driver.setOpts(drv: any, opts: any)
	applyOpts(drv, opts)
end

-- Road route to `goal` (async, throttled, cached). opts: endGap, cap, targetSpeed, stopAtEnd,
-- onArrive, tolerance (keep the current route if the goal moved less), minInterval,
-- penalty (RoadGraph node cost multipliers), exact (end exactly on goal), onFail.
function Driver.routeTo(drv: any, goal: Vector3, opts: any, now: number)
	local o = opts or {}
	if drv.routing then
		applyOpts(drv, o)
		return
	end
	local tol = o.tolerance or 25
	local left = drv.total - drv.s
	if drv.routeGoal and (drv.routeGoal - goal).Magnitude < tol and left > math.min(60, (drv.routeGoal - drv.van.body.Position).Magnitude * 0.5) then
		applyOpts(drv, o)
		return
	end
	if now - drv.routeAt < (o.minInterval or Tuning.Vehicles.ReplanInterval) then
		applyOpts(drv, o)
		return
	end
	drv.routing = true
	drv.routeAt = now
	local token = drv.token
	local van = drv.van
	task.spawn(function()
		local from = van.parts.ap.Position
		local pts: { Vector3 }? = nil
		local ok, err = pcall(function()
			if o.penalty and RoadGraph.ready then
				pts = RoadGraph.route(from, goal, o.penalty)
			end
			if not pts then
				pts = Van.computeRoute(van.cfg, from, goal)
			end
		end)
		drv.routing = false
		if van.dead or van.driveToken ~= token or active[van] ~= drv then
			return
		end
		if not ok or not pts or #pts < 2 then
			drv.routeFails += 1
			if not ok then
				Log.warn("pursuit route", err)
			end
			if o.onFail then
				task.spawn(o.onFail, drv)
			end
			return
		end
		drv.routeFails = 0
		drv.routeGoal = goal
		if drv.targetFn or drv.pathFn then
			return -- a maneuver / close pursuit took over while the route was computing
		end
		local path = table.clone(pts :: { Vector3 })
		path = finishAt(path, goal, if o.exact then 60 else 40)
		Driver.setPath(drv, path, o)
	end)
end

-- Bring the car to a halt and park it like Van:drive's finish() does. Returns door exits.
function Driver.park(van: any): { CFrame }
	Driver.release(van)
	local body = van.body
	local cfg = van.cfg
	van.parked = true
	van.parkedAt = os.clock()
	body.AssemblyLinearVelocity = Vector3.zero
	body.AssemblyAngularVelocity = Vector3.zero
	body.Anchored = true
	for _, p in van.model:GetDescendants() do
		if p:IsA("BasePart") and p.Name ~= "Hub" and p.Name ~= "Lamp" then
			p.CanCollide = true
		end
	end
	if van.parts.siren then
		van.parts.siren:Stop()
	end
	local cf = body.CFrame
	local W, L = cfg.Size.X, cfg.Size.Z
	local exits = {}
	local function exitAt(offset: Vector3)
		local world = cf:PointToWorldSpace(offset)
		local g = Util.groundAt(world, 6, 20)
		local p = g or (world - Vector3.new(0, van.rideHeight, 0))
		table.insert(exits, CFrame.lookAt(p, p + cf.LookVector))
	end
	exitAt(Vector3.new(-(W / 2 + 1.6), 0, -L * 0.05))
	exitAt(Vector3.new(W / 2 + 1.6, 0, -L * 0.05))
	return exits
end

function Driver.speedOf(van: any): number
	local drv = active[van]
	return if drv then drv.speed else 0
end

function Driver.activeCount(): number
	local n = 0
	for _ in active do
		n += 1
	end
	return n
end

return Driver
