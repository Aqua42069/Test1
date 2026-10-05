--[[
	GTAVehicle - GTA IV style car physics driven by handling.dat values.

	The car's driver seat is the chassis. Each wheel (Essentials.LF/RF/LB/RB) is a
	suspension ray: spring + compression / rebound damping hold the body up; a tyre
	model turns slip into grip. Visual wheels stay on their hinges but don't touch the
	world (CarServer makes them massless and non-colliding).

	Units: handling.dat is in metres, km/h and multiples of g. One metre is
	Data.MetersToStuds studs, and the car feels real gravity (9.81 m/s2 in studs) - an
	upward force cancels the rest of Roblox's much stronger gravity - so every value
	means what it means in GTA.

	handling.dat (GTA IV) columns, in order (Data.Columns can override):
	  name mass dragMult percentSubmerged comX comY comZ driveBiasFront gears driveForce
	  driveInertia maxVel brakeForce brakeBiasFront steeringLock tractionMax tractionMin
	  tractionLateral tractionLongitudinal tractionSpringDeltaMax tractionBiasFront
	  suspForce suspCompDamp suspReboundDamp suspUpper suspLower suspRaise suspBiasFront
	  collisionDamage weaponDamage deformationDamage engineDamage seatOffset value
	  modelFlags handlingFlags
]]

local M = {}

-- tuning knobs (GTAHandlingData.TopSpeedScale / AccelScale override these)
M.TopSpeedScale = 1.2 -- real top speed vs handling.dat Tv (IV runs ~20% past it)
M.AccelScale = 1.0 -- 1.0 = GTA IV 0-100 times
M.GripScale = 1.45 -- tyre grip vs raw handling.dat (1.0 slid everywhere on Roblox roads)
M.SlideGrip = 0.85 -- grip left once a tyre slides past its peak, as a share of peak grip
M.MaxStep = 2.2 -- v259: kerbs / ledges up to this tall (studs) are driven over, taller ones stop the car

function M.configure(data: any)
	if type(data) == "table" then
		M.TopSpeedScale = tonumber(data.TopSpeedScale) or M.TopSpeedScale
		M.AccelScale = tonumber(data.AccelScale) or M.AccelScale
		M.GripScale = tonumber(data.GripScale) or M.GripScale
		M.SlideGrip = tonumber(data.SlideGrip) or M.SlideGrip
	end
end

-- GTA IV handling.dat (the real file): A B C D E F G | Tt Tg Tf Ti Tv | Tb Tbb Thb | Ts |
-- Wc+ Wc- Wc-(lat) Ws+ Wbias | Sf Scd Srd Su Sl Sr Sb | Dc Dw Dd De | Ms Mv Mmf Mhf Ma
M.COLUMNS_IV = {
	"name", "mass", "dragMult", "percentSubmerged", "comX", "comY", "comZ",
	"driveBiasFront", "gears", "driveForce", "driveInertia", "maxVel",
	"brakeForce", "brakeBiasFront", "handbrakeForce", "steeringLock",
	"tractionMax", "tractionMin", "tractionLateral", "tractionSpringDeltaMax", "tractionBiasFront",
	"suspForce", "suspCompDamp", "suspReboundDamp", "suspUpper", "suspLower", "suspRaise", "suspBiasFront",
	"collisionDamage", "weaponDamage", "deformationDamage", "engineDamage",
	"seatOffset", "value", "modelFlags", "handlingFlags", "animGroup",
}

local DEFAULTS = {
	mass = 1500, dragMult = 6.0, comX = 0, comY = 0, comZ = 0, driveBiasFront = 0, gears = 5, driveForce = 0.18,
	driveInertia = 1, maxVel = 140, brakeForce = 0.22, brakeBiasFront = 0.65, handbrakeForce = 0.7, steeringLock = 35, tractionMax = 2.0,
	tractionMin = 1.8, tractionLateral = 20, tractionLongitudinal = 1, tractionSpringDeltaMax = 0.15,
	tractionBiasFront = 0.5, suspForce = 2.0, suspCompDamp = 1.0, suspReboundDamp = 1.4, suspUpper = 0.1,
	suspLower = -0.15, suspRaise = 0, suspBiasFront = 0.5,
}

-- Parse handling.dat text (any number of lines; ";" "#" "//" start comments).
-- Returns { [NAME] = handling table }. Unknown / short lines are skipped.
function M.parse(text: string, columns: { string }?): { [string]: any }
	local cols = columns or M.COLUMNS_IV
	local out = {}
	for line in string.gmatch(text .. "\n", "([^\r\n]*)\r?\n") do
		local clean = string.gsub(line, "^%s+", "")
		-- vehicle lines start with a letter; ; # comments and the % boat / ! bike /
		-- $ flying / ^ anim-group tables are skipped
		if string.match(clean, "^%a") then
			local tokens = {}
			for tok in string.gmatch(clean, "%S+") do
				table.insert(tokens, tok)
			end
			if #tokens >= 20 and not tonumber(tokens[1]) then
				local h = {}
				for k, v in DEFAULTS do
					h[k] = v
				end
				for i, key in cols do
					local tok = tokens[i]
					if tok then
						h[key] = if key == "name" or key == "modelFlags" or key == "handlingFlags" then tok else (tonumber(tok) or h[key])
					end
				end
				h.name = string.upper(tostring(h.name))
				out[h.name] = h
			end
		end
	end
	return out
end

-- one-line summary for the Output
function M.describe(h: any): string
	return ("%s: %.0fkg drag %.1f, drive %.2f x%d gears %s, top %.0fkm/h, brake %.2f hb %.2f, lock %.0f, grip %.2f/%.2f @%.1f deg, susp %.2f"):format(
		h.name, h.mass, h.dragMult, h.driveForce, h.gears,
		if h.driveBiasFront >= 0.99 then "FWD" elseif h.driveBiasFront <= 0.01 then "RWD" else "AWD",
		h.maxVel, h.brakeForce, h.handbrakeForce, h.steeringLock, h.tractionMax, h.tractionMin, h.tractionLateral, h.suspForce)
end

local WHEEL_NAMES = { "LF", "RF", "LB", "RB" }

-- builds the per-car state; `seat` is the driver's VehicleSeat (the chassis root)
function M.new(car: Model, seat: BasePart, h: any, metersToStuds: number): any
	local essentials = car:FindFirstChild("Essentials")
	local wheels = {}
	local sumZ = 0
	for _, name in WHEEL_NAMES do
		local w = essentials and essentials:FindFirstChild(name)
		if w and w:IsA("BasePart") then
			-- measured bug fix: the server stamps each wheel's place on the car when it
			-- builds it; a driver measuring the moment they sit in a fresh car got it wrong
			local stamped = w:GetAttribute("GTAOffset")
			local lp = if typeof(stamped) == "Vector3" then stamped else seat.CFrame:PointToObjectSpace(w.Position)
			if typeof(stamped) ~= "Vector3" and game:GetService("RunService"):IsServer() then
				w:SetAttribute("GTAOffset", lp)
			end
			table.insert(wheels, { part = w, offset = lp, radius = math.max(math.min(w.Size.X, w.Size.Y, w.Size.Z) / 2, 0.5),
				lastComp = nil, contact = false, spin = 0 })
			sumZ += lp.Z
		end
	end
	if #wheels < 3 then
		return nil
	end
	local midZ = sumZ / #wheels
	local fronts, rears = 0, 0
	for _, w in wheels do
		w.front = w.offset.Z < midZ -- the seat looks down -Z
		if w.front then fronts += 1 else rears += 1 end
	end
	local spins, steers = {}, {}
	for _, obj in car:GetDescendants() do
		if obj:IsA("HingeConstraint") then
			if obj.Name == "Spin" and obj:GetAttribute("Sign") then
				-- the spin hinge lives in its wheel
				for _, w in wheels do
					if obj.Parent == w.part then
						w.hinge = obj
					end
				end
			elseif obj.Name == "SteerHinge" then
				table.insert(steers, obj)
			end
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { car }
	params.RespectCanCollide = true

	-- Yaw inertia (measured: the Sports Car resisted spinning only 0.48x as much as a real
	-- car its size - its mass sits in the middle). The server measures what Roblox has
	-- against m (L^2 + W^2) / 12 and stamps the ratio; the turning part of every tyre
	-- force is scaled by it, so handbrake turns and steering rotate the car like a real one.
	local yawScale = 1
	local stamped = seat:GetAttribute("GTAYawScale")
	if type(stamped) == "number" then
		yawScale = stamped
	elseif game:GetService("RunService"):IsServer() then
		local com = seat.AssemblyCenterOfMass
		local upV = seat.CFrame.UpVector
		local iRb = 0
		for _, p in car:GetDescendants() do
			if p:IsA("BasePart") and not p.Massless and p.AssemblyRootPart == seat.AssemblyRootPart then
				local m = p:GetMass()
				local d = p.Position - com
				d -= upV * d:Dot(upV)
				iRb += m * d:Dot(d) + m * (p.Size.X * p.Size.X + p.Size.Z * p.Size.Z) / 12
			end
		end
		local _, size = car:GetBoundingBox()
		local L, W = math.max(size.X, size.Z), math.min(size.X, size.Z)
		local iReal = seat.AssemblyMass * (L * L + W * W) / 12
		if iRb > 0 and iReal > 0 then
			yawScale = math.clamp(iRb / iReal, 0.1, 1)
		end
		seat:SetAttribute("GTAYawScale", yawScale)
		print(("[GTAHandling] %s: turning resistance %.2fx a real car -> turning forces x%.2f"):format(car.Name, iRb / math.max(iReal, 1), yawScale))
	end
	-- v259 kerb step: how far the solid body reaches ahead of / behind the seat
	local minZ, maxZ = math.huge, -math.huge
	for _, p in car:GetDescendants() do
		if p:IsA("BasePart") and p.CanCollide and not p.Massless then
			local lp = seat.CFrame:PointToObjectSpace(p.Position)
			local r = p.Size.Magnitude / 2
			minZ = math.min(minZ, lp.Z - r)
			maxZ = math.max(maxZ, lp.Z + r)
		end
	end
	if minZ == math.huge then minZ, maxZ = -6, 6 end
	return {
		frontZ = minZ, rearZ = maxZ,
		car = car, seat = seat, h = h, S = metersToStuds, wheels = wheels, fronts = math.max(1, fronts), rears = math.max(1, rears),
		spins = spins, steers = steers, params = params, steer = 0, gear = 1, rpm = 0, yawScale = yawScale,
		anti = seat:FindFirstChild("GTAAntiGravity"), steerDirection = seat:GetAttribute("SteerDirection") or 1,
	}
end

-- add players / dropped things to the ray ignore list
function M.ignore(st: any, list: { Instance })
	local f = { st.car }
	for _, i in list do
		table.insert(f, i)
	end
	st.params.FilterDescendantsInstances = f
end

local function sign(x: number): number
	return if x > 0 then 1 elseif x < 0 then -1 else 0
end

-- a tyre impulse: the push through the centre of mass in full, its spin around the car's
-- up axis scaled to a real car's inertia (roll and pitch untouched)
local function push(st: any, impulse: Vector3, at: Vector3, up: Vector3)
	local seat = st.seat
	local angular = (at - seat.AssemblyCenterOfMass):Cross(impulse)
	local yaw = up * angular:Dot(up)
	seat:ApplyImpulse(impulse)
	seat:ApplyAngularImpulse((angular - yaw) + yaw * st.yawScale)
end

-- input = { throttle = -1..1 (S = brake / reverse), steer = -1..1, handbrake = bool }
function M.step(st: any, dt: number, input: any): any
	local seat, h, S = st.seat, st.h, st.S
	-- the real frame time: gravity pulled for the whole frame, so the springs must push for
	-- all of it too (clamping a hitchy frame to 1/20 s let the car sink, then spring-hop)
	dt = math.clamp(dt, 1 / 240, 0.25)
	local G = 9.81 * S -- real gravity, in studs
	local mass = seat.AssemblyMass
	local cf = seat.CFrame
	local up, fwd = cf.UpVector, cf.LookVector
	-- measured bug fix: a VectorForce the driver's client changes isn't honoured in the
	-- client's physics (the car weighed ~7x too much and sank) - push with an impulse instead
	if st.anti then
		st.anti.Force = Vector3.zero
	end
	-- WEIGHT: the car keeps full Roblox gravity (Gw) - planted, not paper. The springs hold
	-- that weight; the tyres grip as if gravity were real 1 g, so IV's numbers still hold.
	local Gw = workspace.Gravity
	local gripScale = G / Gw
	local vel = seat.AssemblyLinearVelocity
	local fwdSpeed = vel:Dot(fwd)
	local speed = vel.Magnitude
	-- IV cars run ~20% past their handling.dat velocity (Infernus 160 -> ~192 km/h)
	local maxV = math.max(h.maxVel, 10) * M.TopSpeedScale / 3.6 * S

	-- steering: GTA IV turns in slowly, centres quicker, and locks less at speed
	local speedFrac = math.clamp(math.abs(fwdSpeed) / maxV, 0, 1)
	local lockRad = math.rad(h.steeringLock) * (1 - 0.6 * speedFrac)
	local target = math.clamp(input.steer or 0, -1, 1) * lockRad
	local rate = (if math.abs(target) < math.abs(st.steer) then 4.5 else 2.6) * dt
	st.steer += math.clamp(target - st.steer, -rate, rate)

	-- throttle / brake / reverse (S brakes while rolling forward, then reverses)
	local thr = math.clamp(input.throttle or 0, -1, 1)
	local drive, brake = 0, 0
	if thr > 0 then
		if fwdSpeed < -1.5 then brake = thr else drive = thr end
	elseif thr < 0 then
		if fwdSpeed > 1.5 then brake = -thr else drive = thr end
	end
	-- automatic gearbox: higher gears pull less
	local gears = math.max(1, math.floor(h.gears))
	local frac = math.clamp(math.abs(fwdSpeed) / maxV, 0, 1.2)
	local gear = math.clamp(math.floor(frac * gears) + 1, 1, gears)
	st.gear = if fwdSpeed < -1 and drive < 0 then -1 else gear
	local gearMult = 1.25 - 0.5 * (gear - 1) / math.max(1, gears - 1)
	st.rpm = math.clamp((frac * gears) % 1 * 0.8 + 0.2, 0, 1)
	local accel
	-- GTA IV performance: launch acceleration (in g) = 4.25 x driveForce^1.5. Simulated:
	--   Infernus 0.25 -> 0-100 km/h ~4.7 s, top ~187 km/h;  Sabre GT -> ~6.3 s, ~168;
	--   Admiral 0.17 -> ~9 s, ~161;  Bus 0.12 -> ~15 s, ~157;  Mule -> ~23 s, ~111.
	-- Power holds until near top speed, then runs out (no hard wall)
	local launch = 4.25 * math.max(h.driveForce, 0) ^ 1.5 * M.AccelScale
	if drive >= 0 then
		local taper = math.clamp(1 - frac ^ 4, 0, 1)
		accel = launch * G * gearMult * taper
	else
		local revMax = maxV * 0.28
		accel = launch * G * 0.9 * math.clamp((revMax + fwdSpeed) / (revMax * 0.15), 0, 1)
	end
	local driveTotal = mass * accel * drive
	local brakeTotal = mass * h.brakeForce * 3.6 * G * brake

	-- the springs push at most one normal frame's worth at once; a hitch's extra is paid over
	-- the next frames (one big up-front kick for a 100 ms frame launched the car)
	local springDt = math.min(dt + (st.springDebt or 0), 1 / 25) -- normal frames (to 40 ms) in full
	st.springDebt = math.min(dt + (st.springDebt or 0) - springDt, 0.1)
	local nW = #st.wheels
	local upper, lower = h.suspUpper * S, h.suspLower * S
	local travel = math.max(upper - lower, 0.1)
	local contacts = 0
	for _, w in st.wheels do
		local attach = cf:PointToWorldSpace(w.offset) + up * (h.suspRaise * S)
		local origin = attach + up * upper
		local rayLen = travel + w.radius
		local hit = workspace:Raycast(origin, -up * rayLen, st.params)
		if not hit then
			w.contact = false
			w.hitPos = nil -- skid marks: no ground under this tyre
			-- forget the old compression: landing again from 0 read as a huge compression
			-- speed, the damper fired a spike and the car hopped
			w.lastComp = nil
			w.spin = w.spin * 0.99
			continue
		end
		contacts += 1
		w.contact = true
		w.hitPos = hit.Position -- skid marks are laid here (CarDriveClient)
		w.hitNormal = hit.Normal
		local dist = (hit.Position - origin).Magnitude
		local comp = math.clamp((rayLen - dist) / travel, 0, 1.6)
		-- spring: at rest a wheel sits about half way through its travel (suspForce 2)
		local share = mass * Gw / nW
		local bias = (if w.front then h.suspBiasFront else 1 - h.suspBiasFront) * 2
		local k = share / 0.5 * (h.suspForce / 2) * bias
		local compVel = ((comp - (w.lastComp or comp)) * travel) / dt
		w.lastComp = comp
		local kPerStud = k / travel
		local crit = 2 * math.sqrt(kPerStud * (mass / nW))
		local dampValue = if compVel > 0 then h.suspCompDamp else h.suspReboundDamp
		-- damper capped at about the wheel's own weight: a road seam / kerb edge reads as
		-- a sudden compression and an uncapped damper kicked the car into the air
		local damper = math.clamp(compVel * crit * math.clamp(dampValue * 0.3, 0.05, 2.5), -share * bias, share * bias)
		local N = math.max(0, comp * k + damper)
		if comp >= 1 then
			N += (comp - 1) * k * 2 -- bump stop
		end
		-- never more than ~3 g through one wheel: enough to catch a landing, never a launch
		N = math.min(N, share * bias * 3)
		local Nspring = N -- holds the real weight
		N = N * gripScale -- tyre load at real-gravity scale

		-- tyre
		local n = hit.Normal
		local steerA = if w.front then st.steer else 0
		local wf = CFrame.fromAxisAngle(up, -steerA) * fwd
		wf = (wf - n * wf:Dot(n))
		wf = if wf.Magnitude > 1e-3 then wf.Unit else fwd
		local wr = wf:Cross(n)
		local pv = seat:GetVelocityAtPosition(hit.Position)
		local vf, vr = pv:Dot(wf), pv:Dot(wr)
		local tBias = (if w.front then h.tractionBiasFront else 1 - h.tractionBiasFront) * 2
		local muMax = h.tractionMax * tBias * M.GripScale
		local muMin = math.max(h.tractionMin * tBias * M.GripScale, muMax * M.SlideGrip)
		local handbrake = input.handbrake == true and not w.front
		-- lateral: grip builds with slip angle to the peak, then falls to the sliding grip
		local slip = math.atan2(math.abs(vr), math.max(math.abs(vf), 3))
		local peak = math.rad(math.max(h.tractionLateral, 2))
		local mu = if slip <= peak then muMax * (slip / peak)
			else muMax + (muMin - muMax) * math.clamp((slip - peak) / (peak * 1.5), 0, 1)
		local wheelMass = mass / nW
		local fLat = -sign(vr) * math.min(mu * N, math.abs(vr) * wheelMass / dt)
		local planarSpeed = math.sqrt(vf * vf + vr * vr)
		if handbrake and planarSpeed > 0.5 then
			-- GTA IV handbrake: the rear wheels LOCK. A locked tyre slides on its sliding
			-- grip (tractionMin) against the direction it's actually moving - so it still
			-- holds the car sideways, the back steps out and the drift settles instead of
			-- spinning. Thb (handbrakeForce) = how much grip the locked tyre loses.
			local muLock = muMin * (1 - 0.35 * math.clamp(h.handbrakeForce, 0, 1))
			local f = muLock * N
			local fl = -vf / planarSpeed * f
			local fr = -vr / planarSpeed * f
			-- never more than it takes to stop that wheel's share this frame
			fl = sign(fl) * math.min(math.abs(fl), math.abs(vf) * wheelMass / dt)
			fr = sign(fr) * math.min(math.abs(fr), math.abs(vr) * wheelMass / dt)
			w.slipping = true
			w.locked = true
			w.spin = 0
			local at = hit.Position + up * (w.radius * 0.5)
			push(st, up * Nspring * springDt + (wf * fl + wr * fr) * dt, at, up)
			continue
		end
		-- longitudinal: engine (by drive bias), brakes (by brake bias), rolling
		local driveShare = if w.front then h.driveBiasFront / st.fronts else (1 - h.driveBiasFront) / st.rears
		local fLong = driveTotal * driveShare
		local brakeShare = if w.front then h.brakeBiasFront / st.fronts else (1 - h.brakeBiasFront) / st.rears
		local fBrake = brakeTotal * brakeShare
		if drive == 0 and brake == 0 then
			fBrake += mass * G * 0.02 / nW -- rolling resistance / engine braking
		end
		local cancel = math.abs(vf) * wheelMass / dt
		fLong += -sign(vf) * math.min(fBrake, cancel)
		-- friction circle: more than the tyre can give = wheelspin / lockup / slide
		local gripLimit = math.max(muMax, 0.1) * N
		local total = math.sqrt(fLong * fLong + fLat * fLat)
		w.slipping = false
		w.locked = false
		w.slipSpeed = math.abs(vr) -- sideways slide speed (skid marks)
		w.rollSpeed = math.abs(vf) -- v284h: rolling speed (skid marks use the slip angle)
		if total > gripLimit and total > 0 then
			local s = gripLimit / total
			fLong *= s
			fLat *= s * 0.85
			w.slipping = true
		end
		w.spin = vf / w.radius + (if w.slipping and drive ~= 0 and fLong * drive > 0 then drive * 25 else 0)
		-- forces act a little above the contact patch (GTA IV's body roll, without tipping every corner)
		local at = hit.Position + up * (w.radius * 0.5)
		push(st, up * Nspring * springDt + (wf * fLong + wr * fLat) * dt, at, up)
	end

	-- v259 kerb step: the wheels are rays and only the body collides, so a kerb caught the
	-- bumper and stopped the car dead. The leading wheels look ahead at bumper height; a low
	-- ledge (<= MaxStep) is climbed - the car is lifted over it and keeps its speed. A wall
	-- (taller than MaxStep) still stops you.
	if drive ~= 0 and contacts > 0 and os.clock() >= (st.stepUntil or 0) then
		local dir = if drive > 0 then 1 else -1
		local look = fwd * dir
		local flat = look - up * look:Dot(up)
		if flat.Magnitude > 0.5 then
			flat = flat.Unit
			local climb = 0
			for _, w in st.wheels do
				if w.hitPos and w.front == (dir > 0) then
					local reach = math.abs((if dir > 0 then st.frontZ else st.rearZ) - w.offset.Z) + 2.5
					local low = workspace:Raycast(w.hitPos + up * 0.3, flat * reach, st.params)
					if low and low.Normal:Dot(up) < 0.7 then
						local high = workspace:Raycast(w.hitPos + up * M.MaxStep, flat * reach, st.params)
						if not high then
							local top = workspace:Raycast(low.Position + flat * 0.5 + up * (M.MaxStep + 0.5), -up * (M.MaxStep + 1), st.params)
							local hgt = if top then (top.Position - w.hitPos):Dot(up) else M.MaxStep
							if hgt > 0.1 and hgt <= M.MaxStep then
								climb = math.max(climb, hgt)
							end
						end
					end
				end
			end
			if climb > 0 then
				local v = seat.AssemblyLinearVelocity
				local needUp = math.sqrt(2 * Gw * (climb + 0.35))
				local keep = math.max(v:Dot(flat), 10)
				local side = v - flat * v:Dot(flat) - up * v:Dot(up)
				seat.AssemblyLinearVelocity = side + flat * keep + up * math.max(v:Dot(up), needUp)
				st.stepUntil = os.clock() + 0.35
			end
		end
	end

	-- planted: on four wheels, suspension alone never throws the body up faster than ~3 studs/s
	-- (not while climbing a kerb)
	if contacts == nW and os.clock() >= (st.stepUntil or 0) then
		local v = seat.AssemblyLinearVelocity
		local rise = v:Dot(up)
		if rise > 3 then
			seat:ApplyImpulse(-up * (rise - 3) * mass)
		end
	end

	-- aerodynamic drag: grows with speed squared
	if speed > 1 then
		-- IV drag runs ~3 (slippery) .. 9 (bricks), 6 typical; small next to the engine,
		-- it mostly shapes how fast speed bleeds off when you lift
		local k = 0.04 * G / (maxV * maxV) * (h.dragMult / 6)
		seat:ApplyImpulse(-vel.Unit * k * speed * speed * mass * dt)
	end
	-- a touch of air control and self-righting when all wheels are off the ground (IV lets you rock the car)
	if contacts == 0 then
		local yaw = (input.steer or 0) * mass * 2
		seat:ApplyAngularImpulse(up * -yaw * dt)
	end

	-- wheels on screen
	for _, w in st.wheels do
		local hinge = w.hinge
		if hinge then
			hinge.MotorMaxTorque = 200
			hinge.AngularVelocity = w.spin * (hinge:GetAttribute("Sign") or 1)
		end
	end
	for _, hinge in st.steers do
		hinge.TargetAngle = -math.deg(st.steer) * st.steerDirection
	end
	return { speed = fwdSpeed, kmh = math.abs(fwdSpeed) / S * 3.6, gear = st.gear, rpm = st.rpm, contacts = contacts }
end

return M
