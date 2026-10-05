--[[
	PoliceAI · Roadside  (spike strips + roadblocks)
	Both are physical, avoidable tactics:
	  SPIKE     a unit races ahead on the mapped roads to a point on the suspect's predicted
	            route, parks at the curb, an officer walks out and lays the strip across the
	            suspect's side of the road, then takes cover. Change route / swerve to the
	            other half of the road and it fails; the officer picks it back up.
	  ROADBLOCK one or two units park angled across the lanes further ahead, leaving the
	            curbs open. Cars can be shoved by a hard hit (Tuning.Roadblock.Breakable).
	Nothing is ever placed closer than MinLead / AbortDistance to the suspect.

	v114: the spike officer carries the rolled strip to the curb, PULLS it across the lane
	walking backwards, stands at the curb holding the cord, and YANKS it back after the
	suspect hits or passes it (so following cruisers don't run over it). A hit is any overlap
	between the car's footprint and the strip, and the damage works on every car: the tyres
	lose grip, a drag force pulls the car down to ~FlatSpeedCap, sparks fly from the rims,
	and rebuilt cars also get the steering wobble (TireDamage seat attribute).
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Roadside = {}
local Ctx, Tuning, Log, Util, State, CopAI, Driver, Knowledge, Voice

function Roadside.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, State, CopAI = ctx.Tuning, ctx.Log, ctx.Util, ctx.State, ctx.CopAI
	Driver, Knowledge, Voice = ctx.Driver, ctx.Knowledge, ctx.Voice
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function stripSpan(site: any): (number, number)
	local lane = math.max(site.lane or 0, 0)
	if lane >= 2 then
		return -2, lane * 2 + 1 -- the suspect's half of a two-way road
	end
	return -7, 7 -- one-way / unknown width: middle of the road
end

local function spawnOfficer(op: any, van: any, exits: { CFrame }, near: Vector3): any?
	local p = op.inc.pursuit
	local best = exits[1]
	for _, cf in exits do
		if (cf.Position - near).Magnitude < (best.Position - near).Magnitude then
			best = cf
		end
	end
	if not best then
		return nil
	end
	van.crewOut += 1
	local cop = CopAI.new("Patrol", best, {
		role = "Patrol",
		pursuit = p,
		homeCar = van,
		onRemoved = function(_c, reason)
			if reason ~= "boarded" then
				van:crewLost()
			end
		end,
	})
	if not cop then
		van.crewOut -= 1
		return nil
	end
	return cop
end

local function walk(cop: any, goal: Vector3, maxTime: number, alive: () -> boolean): boolean
	local deadline = os.clock() + maxTime
	while cop.alive and alive() and os.clock() < deadline do
		if flat(goal - cop.root.Position).Magnitude < 2.6 then
			cop:stop()
			return true
		end
		cop:moveTo(goal, true)
		task.wait(0.12)
	end
	cop:stop()
	return cop.alive and flat(goal - cop.root.Position).Magnitude < 5
end

---------------------------------------------------------------------------
-- spike strip model (spans between two offsets across the road)
---------------------------------------------------------------------------
local function newStrip(op: any): (Model, BasePart)
	local site = op.site
	local model = Instance.new("Model")
	model.Name = "PoliceSpikeStrip"
	local base = Instance.new("Part")
	base.Name = "Strip"
	base.Anchored = true
	base.CanCollide = false
	base.CanQuery = false
	base.CanTouch = false
	base.Material = Enum.Material.DiamondPlate
	base.Color = Color3.fromRGB(46, 46, 50)
	base.Size = Vector3.new(0.6, 0.28, 1.3)
	base.Parent = model
	local att = Instance.new("Attachment")
	att.Name = "CurbEnd"
	att.Parent = base
	model.Parent = State.folders.Props
	local g = Util.groundAt(site.pos, 8, 20)
	op.stripY = (if g then g.Y else site.pos.Y) + 0.14
	return model, base
end

-- lay the strip between offsets a (curb end) and b along site.right
local function spanStrip(op: any, a: number, b: number)
	local base = op.stripBase
	if not base or not base.Parent then
		return
	end
	local site = op.site
	local len = math.max(math.abs(b - a), 0.6)
	local mid = site.pos + site.right * ((a + b) / 2)
	mid = Vector3.new(mid.X, op.stripY, mid.Z)
	base.Size = Vector3.new(len, 0.28, 1.3)
	base.CFrame = CFrame.lookAt(mid, mid + site.dir)
	local att = base:FindFirstChild("CurbEnd") :: Attachment?
	if att then
		-- local +X is site.right for a lookAt(dir) frame
		att.Position = Vector3.new((a - (a + b) / 2), 0.1, 0)
	end
	op.spanA, op.spanB = a, b
	op.stripCenter = mid
	op.stripLen = len
end

local function dressStrip(op: any)
	local model, base = op.strip, op.stripBase
	if not model or not base or not base.Parent then
		return
	end
	local len = op.stripLen
	local cf = base.CFrame
	for _, side in { -1, 1 } do
		local cap = Instance.new("Part")
		cap.Name = "Cap"
		cap.Anchored = true
		cap.CanCollide = false
		cap.CanQuery = false
		cap.CanTouch = false
		cap.Material = Enum.Material.Neon
		cap.Color = Color3.fromRGB(255, 196, 30)
		cap.Size = Vector3.new(0.6, 0.34, 1.35)
		cap.CFrame = cf * CFrame.new(side * (len / 2 - 0.3), 0.02, 0)
		cap.Parent = model
	end
	local n = math.clamp(math.floor(len / 1.6), 4, 14)
	for i = 1, n do
		local x = -len / 2 + (i - 0.5) * len / n
		local tooth = Instance.new("WedgePart")
		tooth.Name = "Tooth"
		tooth.Anchored = true
		tooth.CanCollide = false
		tooth.CanQuery = false
		tooth.CanTouch = false
		tooth.Material = Enum.Material.Metal
		tooth.Color = Color3.fromRGB(190, 190, 196)
		tooth.Size = Vector3.new(0.3, 0.4, 0.45)
		tooth.CFrame = cf * CFrame.new(x, 0.32, if i % 2 == 0 then 0.3 else -0.3)
		tooth.Parent = model
	end
end

local function clearDressing(op: any)
	if op.strip then
		for _, c in op.strip:GetChildren() do
			if c.Name == "Cap" or c.Name == "Tooth" then
				c:Destroy()
			end
		end
	end
end

local function handOf(cop: any): BasePart?
	local m = cop.model
	if not m then
		return nil
	end
	local h = m:FindFirstChild("RightHand") or m:FindFirstChild("Right Arm") or m:FindFirstChild("RightLowerArm")
	return if h and h:IsA("BasePart") then h else nil
end

local function carryRoll(cop: any): BasePart?
	local hand = handOf(cop)
	if not hand then
		return nil
	end
	local roll = Instance.new("Part")
	roll.Name = "SpikeRoll"
	roll.Size = Vector3.new(0.7, 0.7, 1.5)
	roll.Material = Enum.Material.DiamondPlate
	roll.Color = Color3.fromRGB(46, 46, 50)
	roll.CanCollide = false
	roll.CanQuery = false
	roll.CanTouch = false
	roll.Massless = true
	roll.CFrame = hand.CFrame * CFrame.new(0, -1, -0.4)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = roll
	weld.Parent = roll
	roll.Parent = cop.model
	return roll
end

-- the cord from the officer's hand to the strip's curb end (what he yanks it back with)
local function attachCord(op: any, cop: any)
	local hand = handOf(cop)
	local base = op.stripBase
	if not hand or not base then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "SpikeCord"
	a0.Parent = hand
	local a1 = base:FindFirstChild("CurbEnd") :: Attachment?
	if not a1 then
		return
	end
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = 0.12
	beam.Width1 = 0.12
	beam.Color = ColorSequence.new(Color3.fromRGB(20, 20, 20))
	beam.FaceCamera = true
	beam.Segments = 6
	beam.CurveSize0 = -1.5
	beam.Parent = base
	op.cordAtt = a0
end

---------------------------------------------------------------------------
-- tyre damage (works for any car: grip + drag + sparks; rebuilt cars also wobble)
---------------------------------------------------------------------------
local function isWheel(part: BasePart): boolean
	local n = string.lower(part.Name)
	if string.find(n, "wheel", 1, true) or string.find(n, "tire", 1, true) or string.find(n, "tyre", 1, true) then
		return not string.find(n, "steering", 1, true)
	end
	return part:IsA("Part") and (part :: Part).Shape == Enum.PartType.Cylinder and part.Size.Magnitude > 2
end

function Roadside.puncture(model: Model?, seat: BasePart?)
	if not seat or not seat.Parent then
		return
	end
	local S = Tuning.Spike
	model = model or Knowledge.vehicleModelOf(seat)
	local token = (tonumber(seat:GetAttribute("TireDamageToken")) or 0) + 1
	seat:SetAttribute("TireDamageToken", token)
	seat:SetAttribute("TireDamage", S.FlatTire) -- CarDriveClient: lower top speed + wobble
	seat:SetAttribute("TirePull", if math.random() < 0.5 then -1 else 1) -- v215: which way the wreckage pulls
	if not model then
		return
	end
	if model:GetAttribute("PoliceTiresSpiked") then
		return -- already on its rims; the timer above was refreshed
	end
	model:SetAttribute("PoliceTiresSpiked", true)

	local mass = 0
	local wheels = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			mass += d:GetMass()
			if isWheel(d) then
				table.insert(wheels, d)
			end
		end
	end
	-- shredded tyres: much less grip
	local saved = {}
	for _, w in wheels do
		saved[w] = w.CustomPhysicalProperties or false -- false = had default physics
		local cur = w.CurrentPhysicalProperties
		w.CustomPhysicalProperties = PhysicalProperties.new(cur.Density, S.WheelFriction, 0.05, 6, 1)
	end
	-- sparks off the rims
	local emitters = {}
	for _, w in wheels do
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "RimSparks"
		pe.Color = ColorSequence.new(Color3.fromRGB(255, 200, 90), Color3.fromRGB(255, 110, 20))
		pe.LightEmission = 1
		pe.Size = NumberSequence.new(0.18, 0)
		pe.Lifetime = NumberRange.new(0.15, 0.35)
		pe.Speed = NumberRange.new(8, 16)
		pe.SpreadAngle = Vector2.new(35, 35)
		pe.Rate = 30
		pe.Enabled = false
		pe.Parent = w
		table.insert(emitters, pe)
	end
	-- drag: pulls the car down toward FlatSpeedCap (simulated by the driver's client)
	local root = seat.AssemblyRootPart or seat
	local att = Instance.new("Attachment")
	att.Name = "SpikeDrag"
	att.Parent = root
	local vf = Instance.new("VectorForce")
	vf.Name = "SpikeDrag"
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Force = Vector3.zero
	vf.Parent = root
	local expires = os.clock() + S.FlatDuration
	task.spawn(function()
		while model.Parent and root.Parent and os.clock() < expires and seat:GetAttribute("TireDamageToken") == token do
			local v = flat(root.AssemblyLinearVelocity)
			local speed = v.Magnitude
			local decel = 0
			if speed > S.FlatSpeedCap then
				decel = math.min((speed - S.FlatSpeedCap) * S.DragGain, S.MaxDragDecel)
			end
			decel += math.min(speed, 40) * 0.25 -- rolling on rims
			vf.Force = if speed > 0.5 then -v.Unit * mass * decel else Vector3.zero
			for _, pe in emitters do
				pe.Enabled = speed > 8
			end
			task.wait(1 / 15)
		end
		-- repaired / expired
		if vf.Parent then
			vf:Destroy()
		end
		if att.Parent then
			att:Destroy()
		end
		for _, pe in emitters do
			if pe.Parent then
				pe:Destroy()
			end
		end
		for w, props in saved do
			if w.Parent then
				w.CustomPhysicalProperties = if props == false then nil else props
			end
		end
		if model.Parent then
			model:SetAttribute("PoliceTiresSpiked", nil)
		end
		if seat.Parent and seat:GetAttribute("TireDamageToken") == token then
			seat:SetAttribute("TireDamage", nil)
		end
	end)
end

---------------------------------------------------------------------------
-- op lifecycle
---------------------------------------------------------------------------
local function entryOf(op: any, van: any): any
	return op.inc.cars[van]
end

local function finish(op: any, why: string)
	if op.done then
		return
	end
	op.done = true
	if op.conn then
		op.conn:Disconnect()
		op.conn = nil
	end
	if op.strip and op.strip.Parent then
		op.strip:Destroy()
	end
	if op.cordAtt and op.cordAtt.Parent then
		op.cordAtt:Destroy()
	end
	local inc = op.inc
	for _, van in op.vans do
		local e = entryOf(op, van)
		if e and e.op == op then
			e.op = nil
			e.role = "TAIL"
		end
		if van.aiRoadblock then
			van.aiRoadblock = nil
		end
	end
	for _, cop in op.officers do
		if cop.alive then
			cop.aiScripted = nil
			if cop.aiFixedRole == "SPIKE" or cop.aiFixedRole == "ROADBLOCK" then
				cop.aiFixedRole = nil
			end
			cop.aiHoldPos = nil
			cop.aiFacePos = nil
		end
	end
	if inc.roadside[op.kind] == op then
		inc.roadside[op.kind] = nil
	end
	local now = os.clock()
	if op.kind == "SPIKE" then
		inc.spikeReadyAt = now + Tuning.Spike.Cooldown
	else
		inc.roadblockReadyAt = now + Tuning.Roadblock.Cooldown
	end
	Log.verbose(op.kind .. " FINISHED", "#%d %s", inc.id, why)
end

-- Officers walk back to their cars and board; the op ends once everyone is aboard.
local function teardown(op: any, why: string, logTag: string?)
	if op.state == "teardown" or op.done then
		return
	end
	op.state = "teardown"
	op.teardownAt = os.clock()
	if logTag then
		Log.event(logTag, "#%d %s", op.inc.id, why)
	end
	local strip = op.strip
	for _, cop in op.officers do
		if cop.alive then
			cop.aiFixedRole = "BOARD"
			cop.aiScripted = nil
		end
	end
	if op.kind == "SPIKE" and strip and strip.Parent then
		local cop = op.officers[1]
		if cop and cop.alive then
			cop.aiScripted = true
		end
		task.spawn(function()
			Roadside.pullBack(op)
			if cop and cop.alive then
				-- coil it up, then back to the car
				cop:face(op.site.pos)
				task.wait(0.7)
				cop.aiScripted = nil
				cop.aiFixedRole = "BOARD"
			end
		end)
	end
end

function Roadside.cancel(op: any, why: string)
	if op.done then
		return
	end
	-- mid-deployment officers become normal officers on the incident
	for _, cop in op.officers do
		if cop.alive then
			cop.aiScripted = nil
			cop.aiFixedRole = nil
		end
	end
	for _, van in op.vans do
		local e = entryOf(op, van)
		if e and van.crewOut > 0 then
			e.deployed = true -- crew is out: treat like a scene car
		end
	end
	finish(op, why)
end

---------------------------------------------------------------------------
-- SPIKE
---------------------------------------------------------------------------
function Roadside.startSpike(inc: any, van: any, site: any): boolean
	local e = inc.cars[van]
	if not e then
		return false
	end
	local inner, outer = stripSpan(site)
	local op = {
		inner = inner,
		outer = outer,
		kind = "SPIKE",
		inc = inc,
		vans = { van },
		site = site,
		state = "driving",
		started = os.clock(),
		officers = {},
		minDist = math.huge,
		minAt = os.clock(),
		stripCenter = site.pos + site.right * ((inner + outer) / 2),
		stripEnd = site.pos + site.right * (outer + 0.5),
	}
	inc.roadside.SPIKE = op
	e.op = op
	e.role = "SPIKE"
	local park = site.pos + site.right * (outer + 3) + site.dir * 16
	op.park = park
	local drv = Driver.take(van)
	Driver.routeTo(drv, park, {
		stopAtEnd = true,
		exact = true,
		endGap = 0,
		targetSpeed = 0,
		cap = Tuning.Vehicles.PursuitSpeed,
		tolerance = 6,
		minInterval = 0,
		laneShift = 0,
		onArrive = function()
			Roadside.spikeArrived(op)
		end,
		onFail = function()
			if not op.done and op.state == "driving" then
				Log.event("SPIKE ATTEMPT FAILED", "#%d no road route to the site", inc.id)
				finish(op, "no route")
			end
		end,
	}, os.clock())
	Log.event("SPIKE UNIT ASSIGNED", "#%d site %.0f studs ahead of suspect", inc.id, site.d or 0)
	return true
end

function Roadside.spikeArrived(op: any)
	if op.done or op.state ~= "driving" then
		return
	end
	local inc = op.inc
	local van = op.vans[1]
	local k = inc.knowledge
	if flat(k.pos - op.site.pos).Magnitude < Tuning.Spike.AbortDistance then
		Log.event("SPIKE ATTEMPT FAILED", "#%d suspect already too close - not deploying", inc.id)
		finish(op, "too late")
		return
	end
	op.state = "deploying"
	local exits = Driver.park(van)
	local site = op.site
	local curbPoint = site.pos + site.right * (op.outer + 1.6)
	local innerPoint = site.pos + site.right * (op.inner - 0.8)
	local cop = spawnOfficer(op, van, exits, curbPoint)
	if not cop then
		Log.event("SPIKE ATTEMPT FAILED", "#%d no officer could deploy", inc.id)
		finish(op, "no officer")
		return
	end
	table.insert(op.officers, cop)
	cop.aiScripted = true
	cop:setGunOut(false)
	local roll = carryRoll(cop)
	task.spawn(function()
		local alive = function()
			return not op.done and op.state == "deploying"
		end
		-- 1) carry the rolled strip to the curb
		local ok = walk(cop, curbPoint, 9, alive)
		if not alive() then
			if roll and roll.Parent then
				roll:Destroy()
			end
			return
		end
		if not ok then
			if roll and roll.Parent then
				roll:Destroy()
			end
			Log.event("SPIKE ATTEMPT FAILED", "#%d officer couldn't reach the road", inc.id)
			teardown(op, "unreachable")
			return
		end
		if flat(inc.knowledge.pos - site.pos).Magnitude < Tuning.Spike.AbortDistance * 0.7 then
			if roll and roll.Parent then
				roll:Destroy()
			end
			Log.event("SPIKE ATTEMPT FAILED", "#%d suspect arrived before the strip was down", inc.id)
			teardown(op, "too late")
			return
		end
		-- 2) pull it across the lane: the strip unrolls behind the officer as he walks
		cop:face(innerPoint)
		task.wait(0.35)
		if roll and roll.Parent then
			roll:Destroy()
		end
		local model, base = newStrip(op)
		op.strip, op.stripBase = model, base
		spanStrip(op, op.outer, op.outer - 0.6)
		Log.event("SPIKE STRIP PULLED", "#%d officer pulling the strip across the lane", inc.id)
		local deadline = os.clock() + 5
		while alive() and cop.alive and os.clock() < deadline do
			local off = (cop.root.Position - site.pos):Dot(site.right)
			local b = math.clamp(off, op.inner, op.outer - 0.6)
			spanStrip(op, op.outer, b)
			if off <= op.inner + 0.6 then
				break
			end
			cop:moveTo(innerPoint, false)
			task.wait(0.05)
		end
		if not alive() then
			return
		end
		spanStrip(op, op.outer, op.inner)
		dressStrip(op)
		op.state = "deployed"
		op.deployedAt = os.clock()
		Log.event("SPIKE DEPLOYED", "#%d strip %.0f studs across the lane", inc.id, op.stripLen)
		if Tuning.ScannerHints then
			State.announce(inc.player, "RADIO: \"Spikes are down up ahead!\"", "warn")
		end
		Roadside.watchStrip(op)
		-- 3) back to the curb, holding the cord, ready to yank it
		local hold = site.pos + site.right * (op.outer + 2.2) - site.dir * 1.5
		walk(cop, hold, 5, function()
			return not op.done
		end)
		if op.done or not cop.alive then
			return
		end
		attachCord(op, cop)
		cop.aiScripted = nil
		cop.aiFixedRole = "SPIKE"
		cop.aiHoldPos = Util.groundAt(hold, 8, 20) or hold
		cop.aiFacePos = site.pos - site.dir * 60
	end)
end

-- Yank the strip back to the curb (after a hit, a miss, or when the op is called off).
function Roadside.pullBack(op: any)
	if op.pulled then
		return
	end
	op.pulled = true
	if op.conn then
		op.conn:Disconnect()
		op.conn = nil
	end
	local strip = op.strip
	if not strip or not strip.Parent then
		return
	end
	clearDressing(op)
	local a, b = op.spanA or op.outer, op.spanB or op.inner
	local t0 = os.clock()
	while strip.Parent and os.clock() - t0 < 0.45 do
		local t = (os.clock() - t0) / 0.45
		spanStrip(op, a, b + (a - b) * t)
		task.wait()
	end
	if strip.Parent then
		strip:Destroy()
	end
	if op.cordAtt and op.cordAtt.Parent then
		op.cordAtt:Destroy()
	end
end

-- The suspect's car right now (physical contact, not police knowledge).
local function suspectCar(inc: any): (Model?, BasePart?)
	local _, hum = Util.charInfo(inc.player)
	local seat = hum and hum.SeatPart
	if not seat then
		return nil, nil
	end
	return Knowledge.vehicleModelOf(seat), seat
end

-- 2D oriented-box overlap (separating axis test on the ground plane)
local function overlaps(c1: Vector3, a1: Vector3, b1: Vector3, h1a: number, h1b: number, c2: Vector3, a2: Vector3, b2: Vector3, h2a: number, h2b: number): boolean
	local d = flat(c2 - c1)
	for _, axis in { a1, b1, a2, b2 } do
		local r = math.abs(d:Dot(axis))
		local e1 = h1a * math.abs(a1:Dot(axis)) + h1b * math.abs(b1:Dot(axis))
		local e2 = h2a * math.abs(a2:Dot(axis)) + h2b * math.abs(b2:Dot(axis))
		if r > e1 + e2 then
			return false
		end
	end
	return true
end

-- Any part of the car's footprint over the strip = puncture. Checked every frame against
-- the suspect's actual car (physical contact).
function Roadside.watchStrip(op: any)
	local inc = op.inc
	local dir, right = op.site.dir, op.site.right
	op.conn = RunService.Heartbeat:Connect(function(dt)
		if op.done or op.state ~= "deployed" then
			if op.conn then
				op.conn:Disconnect()
				op.conn = nil
			end
			return
		end
		local car, seat = suspectCar(inc)
		if not car or not seat then
			op.prevLong = nil
			return
		end
		local ok, bcf, size = pcall(function()
			return car:GetBoundingBox()
		end)
		if not ok or not bcf then
			return
		end
		local center = bcf.Position
		-- v226: as the suspect closes in, the officer drags the strip further out
		-- into the car's path (it only ever grows from the curb, up to 30 studs)
		do
			local toSite = (center - op.site.pos):Dot(dir)
			local closing = (seat.AssemblyLinearVelocity):Dot(dir)
			if math.abs(toSite) < 140 and toSite * closing < 0 then
				local lat = (center - op.site.pos):Dot(right)
				local want = math.clamp(math.min(op.inner, lat - size.X / 2 - 1.5), op.outer - 30, op.outer - 0.6)
				local cur = op.spanB or op.inner
				if math.abs(want - cur) > 0.2 then
					local step = math.clamp(want - cur, -45 * dt, 45 * dt)
					spanStrip(op, op.outer, cur + step)
					if not op.dragged then
						op.dragged = true
						Log.event("SPIKE STRIP DRAGGED", "#%d officer drags the strip toward the suspect", inc.id)
					end
					op.redressAt = os.clock() + 0.25
				elseif op.redressAt and os.clock() > op.redressAt then
					op.redressAt = nil
					clearDressing(op)
					dressStrip(op)
				end
			end
		end
		local long = (center - op.stripCenter):Dot(dir)
		local prev = op.prevLong
		op.prevLong = long
		local bottom = center.Y - size.Y / 2
		if math.abs(bottom - op.stripY) > 6 then
			return
		end
		local ax = Util.safeUnit(flat(bcf.RightVector), right)
		local az = Util.safeUnit(flat(bcf.LookVector), dir)
		local hit = overlaps(op.stripCenter, right, dir, op.stripLen / 2, 0.9, center, ax, az, size.X / 2, size.Z / 2)
		if hit then
			Roadside.puncture(car, seat)
			Log.event("SPIKE HIT", "#%d %s's tyres are shredded", inc.id, inc.player.Name)
			State.announce(inc.player, "TYRES SPIKED!", "danger")
			op.hit = true
			op.state = "hit"
			for _, cop in op.officers do
				if cop.alive then
					Voice.say(cop, "Got him! Pulling the strip!", inc, { command = false, force = true })
				end
			end
			task.delay(0.35, function()
				teardown(op, "hit")
			end)
		elseif prev and ((prev < 0 and long >= 0) or (prev > 0 and long <= 0)) and (center - op.stripCenter).Magnitude < 40 then
			Log.event("SPIKE MISSED", "#%d suspect swerved around the strip", inc.id)
			teardown(op, "missed")
		end
	end)
end

---------------------------------------------------------------------------
-- ROADBLOCK
---------------------------------------------------------------------------
function Roadside.startRoadblock(inc: any, vans: { any }, site: any): boolean
	local op = {
		kind = "ROADBLOCK",
		inc = inc,
		vans = vans,
		site = site,
		state = "driving",
		started = os.clock(),
		officers = {},
		arrived = {},
		minDist = math.huge,
		minAt = os.clock(),
	}
	inc.roadside.ROADBLOCK = op
	local lane = math.max(site.lane or 0, 3)
	for i, van in vans do
		local e = inc.cars[van]
		if not e then
			continue
		end
		e.op = op
		e.role = "ROADBLOCK"
		local side = if #vans == 1 then 1 elseif i == 1 then 1 else -1
		local lateral = if #vans == 1 then lane * 0.8 else lane * 1.05 * side
		local slot = site.pos + site.right * lateral + site.dir * (if i == 2 then 9 else 0)
		-- angled across the lane, nose toward the centre line
		local yaw = math.rad(62) * side
		local facing = CFrame.fromAxisAngle(Vector3.yAxis, yaw):VectorToWorldSpace(site.dir)
		op["slot" .. i] = { pos = slot, facing = facing }
		local drv = Driver.take(van)
		Driver.routeTo(drv, slot, {
			stopAtEnd = true,
			exact = true,
			endGap = 0,
			targetSpeed = 0,
			cap = Tuning.Vehicles.PursuitSpeed,
			tolerance = 6,
			minInterval = 0,
			onArrive = function()
				Roadside.roadblockArrived(op, van, i)
			end,
			onFail = function()
				if not op.done and op.state == "driving" then
					Log.event("ROADBLOCK FAILED", "#%d no road route to the site", inc.id)
					finish(op, "no route")
				end
			end,
		}, os.clock())
	end
	Log.event("ROADBLOCK ASSIGNED", "#%d %d unit(s), %.0f studs ahead of suspect", inc.id, #vans, site.d or 0)
	return true
end

local function settle(van: any, pos: Vector3, facing: Vector3)
	-- swing the car into its angled position using the chassis itself (no teleport)
	local body = van.body
	local ap, ao = van.parts.ap, van.parts.ao
	body.Anchored = false
	ap.Enabled = true
	ao.Enabled = true
	local g = Util.groundAt(pos, 8, 20)
	local target = Vector3.new(pos.X, (if g then g.Y else body.Position.Y - van.rideHeight) + van.rideHeight, pos.Z)
	local startPos = ap.Position
	local startRot = ao.CFrame
	local goalRot = CFrame.lookAt(Vector3.zero, facing)
	local t0 = os.clock()
	while os.clock() - t0 < 1.3 and not van.dead and body.Parent do
		local a = math.clamp((os.clock() - t0) / 1.3, 0, 1)
		local e = a * a * (3 - 2 * a)
		ap.Position = startPos:Lerp(target, e)
		ao.CFrame = startRot:Lerp(goalRot, e)
		task.wait()
	end
end

local function hold(van: any)
	local body = van.body
	for _, p in van.model:GetDescendants() do
		if p:IsA("BasePart") and p.Name ~= "Hub" and p.Name ~= "Lamp" then
			p.CanCollide = true
		end
	end
	van.parked = true
	van.parkedAt = os.clock()
	van.aiRoadblock = true
	if van.parts.siren then
		van.parts.siren:Stop()
	end
	if Tuning.Roadblock.Breakable then
		-- heavy and sprung: a hard ram can shove it, it doesn't flip or fling
		body.Anchored = false
		body.CustomPhysicalProperties = PhysicalProperties.new(2.2, 0.6, 0.1)
		van.parts.ap.MaxForce = Tuning.Roadblock.HoldForce
		van.parts.ao.MaxTorque = Tuning.Roadblock.HoldForce * 4
		van.parts.ap.Responsiveness = 8
		van.parts.ao.Responsiveness = 8
	else
		body.Anchored = true
	end
end

function Roadside.roadblockArrived(op: any, van: any, i: number)
	if op.done or op.state ~= "driving" then
		return
	end
	local inc = op.inc
	if flat(inc.knowledge.pos - op.site.pos).Magnitude < Tuning.Roadblock.AbortDistance then
		Log.event("ROADBLOCK FAILED", "#%d suspect already too close", inc.id)
		finish(op, "too late")
		return
	end
	Driver.release(van)
	local slot = op["slot" .. i]
	task.spawn(function()
		settle(van, slot.pos, slot.facing)
		if op.done then
			return
		end
		hold(van)
		op.arrived[van] = true
		-- one officer takes cover on the far side of each car
		local cf = van.body.CFrame
		local rear = cf:PointToWorldSpace(Vector3.new(0, 0, van.cfg.Size.Z / 2 + 2))
		local rg = Util.groundAt(rear, 6, 20) or (rear - Vector3.new(0, van.rideHeight, 0))
		local exits = { CFrame.lookAt(rg, rg + op.site.dir) }
		local cover = slot.pos + op.site.dir * 8
		local cop = spawnOfficer(op, van, exits, cover)
		if cop then
			table.insert(op.officers, cop)
			cop.aiFixedRole = "ROADBLOCK"
			cop.aiHoldPos = Util.groundAt(cover, 8, 20) or cover
			cop.aiFacePos = op.site.pos - op.site.dir * 80
		end
		local all = true
		for _, v in op.vans do
			if not op.arrived[v] then
				all = false
			end
		end
		if all and op.state == "driving" then
			op.state = "set"
			op.setAt = os.clock()
			Log.event("ROADBLOCK SET", "#%d %d car(s) across the road", inc.id, #op.vans)
			if Tuning.ScannerHints then
				State.announce(inc.player, "RADIO: \"Roadblock is set up ahead!\"", "warn")
			end
		end
	end)
end

---------------------------------------------------------------------------
-- monitoring (called from Pursuit.update)
---------------------------------------------------------------------------
local function suspectPassed(op: any, k: any): boolean
	local rel = k.pos - op.site.pos
	return rel:Dot(op.site.dir) > 35 and math.abs(rel:Dot(op.site.right)) < 90
end

function Roadside.step(inc: any, now: number)
	for kind, op in inc.roadside do
		if op.done then
			inc.roadside[kind] = nil
			continue
		end
		local k = inc.knowledge
		local d = flat(k.pos - op.site.pos).Magnitude
		if d < op.minDist - 3 then
			op.minDist = d
			op.minAt = now
		end
		local cfg = if kind == "SPIKE" then Tuning.Spike else Tuning.Roadblock

		if op.state == "teardown" then
			-- finished once every officer is back aboard (or gone)
			local aboard = true
			for _, cop in op.officers do
				if cop.alive then
					aboard = false
				end
			end
			if aboard or now - (op.teardownAt or now) > 25 then
				finish(op, "torn down")
				for _, van in op.vans do
					local e = inc.cars[van]
					if e and van.crewOut > 0 then
						e.deployed = true
					end
				end
			end
			continue
		end

		if inc.mode ~= "VEHICLE" then
			if op.state == "set" and kind == "ROADBLOCK" and d < 90 then
				-- he bailed out at the roadblock: officers are already there
				Log.event("ROADBLOCK STOPPED SUSPECT", "#%d", inc.id)
			end
			Roadside.cancel(op, "suspect no longer driving")
			continue
		end

		local age = now - op.started
		local diverged = op.minDist < math.huge and d > op.minDist + 70 and now - op.minAt > 4
		if op.state == "driving" or op.state == "deploying" then
			if d < cfg.AbortDistance and not (op.state == "deploying" and kind == "SPIKE") then
				Log.event(kind .. " ATTEMPT FAILED", "#%d suspect got there first", inc.id)
				if op.state == "deploying" or #op.officers > 0 then
					teardown(op, "too late")
				else
					finish(op, "too late")
				end
			elseif diverged or age > cfg.Timeout then
				Log.event(kind .. " ATTEMPT FAILED", "#%d %s", inc.id, if diverged then "suspect changed route" else "timed out")
				if #op.officers > 0 then
					teardown(op, "diverged")
				else
					finish(op, "diverged")
				end
			end
		elseif op.state == "deployed" or op.state == "set" then
			local stopped = k.stoppedSince ~= nil and now - k.stoppedSince > 1.5 and d < 80
			if kind == "ROADBLOCK" and stopped then
				Log.event("ROADBLOCK STOPPED SUSPECT", "#%d felony stop", inc.id)
				for _, cop in op.officers do
					if cop.alive then
						cop.aiFixedRole = nil
						cop.aiHoldPos = nil
					end
				end
				for _, van in op.vans do
					local e = inc.cars[van]
					if e then
						e.deployed = true
						e.role = "STOP"
					end
				end
				finish(op, "stopped suspect")
			elseif suspectPassed(op, k) and not op.hit then
				teardown(op, "passed", if kind == "SPIKE" then "SPIKE MISSED" else "ROADBLOCK BYPASSED")
			elseif diverged then
				teardown(op, "route change", if kind == "SPIKE" then "SPIKE ATTEMPT FAILED" else "ROADBLOCK ABANDONED")
			elseif age > cfg.Timeout + 15 then
				teardown(op, "timed out", kind .. " TIMED OUT")
			end
		end
	end
end

function Roadside.cancelAll(inc: any, why: string)
	for _, op in inc.roadside do
		Roadside.cancel(op, why)
	end
end

return Roadside
