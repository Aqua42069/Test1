--[[
	PoliceAI · Knowledge
	What the police department KNOWS about a suspect, per incident. Nothing here reads the
	suspect's live position unless a real observer (officer LOS, cruiser LOS, helicopter LOS)
	or a real report (911 call / crime report / gunshots heard) supplied it.

	Levels (best first):
	  DIRECT_VISUAL        a ground unit has eyes on the suspect right now
	  HELICOPTER_REPORTED  only the helicopter has eyes on
	  UNIT_REPORTED        position from a report (crime report, shots heard)
	  RECENT_VISUAL        visual just broke: short dead reckoning
	  PREDICTED            extrapolated along the road network / running direction
	  SEARCHING            no idea beyond "around here" - confidence decays
	  LOST                 confidence 0 -> the suspect evaded (Heat clears "Evaded")
]]

local Knowledge = {}
local Ctx, Tuning, Log, Util, RoadGraph, Config

Knowledge.L = {
	DIRECT = "DIRECT_VISUAL",
	HELI = "HELICOPTER_REPORTED",
	UNIT = "UNIT_REPORTED",
	RECENT = "RECENT_VISUAL",
	PREDICTED = "PREDICTED",
	SEARCHING = "SEARCHING",
	LOST = "LOST",
}
local L = Knowledge.L

local RANK = {
	[L.DIRECT] = 1, [L.HELI] = 2, [L.UNIT] = 3, [L.RECENT] = 4, [L.PREDICTED] = 5, [L.SEARCHING] = 6, [L.LOST] = 7,
}
Knowledge.rank = RANK

function Knowledge.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, RoadGraph, Config = ctx.Tuning, ctx.Log, ctx.Util, ctx.RoadGraph, ctx.Config
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- The car a seat belongs to: the largest ancestor Model that is still car-sized
-- (so a folder/model full of cars is never mistaken for one car).
local function vehicleModelOf(seat: BasePart?): Model?
	if not seat then
		return nil
	end
	local best: Model? = nil
	local node: Instance? = seat.Parent
	while node and node ~= workspace do
		if node:IsA("Model") then
			local ok, _, size = pcall(function()
				return (node :: Model):GetBoundingBox()
			end)
			if ok and size and size.Magnitude < 75 then
				best = node :: Model
			elseif best then
				break
			end
		end
		node = node.Parent
	end
	return best
end
Knowledge.vehicleModelOf = vehicleModelOf

function Knowledge.new(p: any): any
	local now = os.clock()
	local pos = p.lastSeenPos or Vector3.zero
	return {
		pos = pos, -- best estimate of where the suspect is
		obsPos = pos, -- last position actually observed / reported
		vel = Vector3.zero,
		t = now, -- time of last observation of any kind
		lastVisualT = -math.huge, -- ground unit LOS
		lastHeliT = -math.huge,
		lastReportT = now,
		visualBy = nil,
		conf = Tuning.Knowledge.ReportConfidence,
		level = L.UNIT,
		inVehicle = false,
		vehicle = nil :: Model?,
		seat = nil :: BasePart?,
		trail = {} :: { { pos: Vector3, t: number } },
		predicted = nil :: { pts: { Vector3 }, acc: { number } }?,
		stoppedSince = nil :: number?,
		abandoned = nil :: any,
	}
end

function Knowledge.level(inc: any): string
	return inc.knowledge.level
end

function Knowledge.hasEyes(inc: any): boolean
	local lv = inc.knowledge.level
	return lv == L.DIRECT or lv == L.HELI
end

function Knowledge.fresh(inc: any): boolean
	return RANK[inc.knowledge.level] <= RANK[L.RECENT]
end

local function pushTrail(k: any, pos: Vector3, now: number)
	local trail = k.trail
	local last = trail[#trail]
	if last and now - last.t > Tuning.Knowledge.TrailBreak then
		table.clear(trail) -- visual broke: never follow a line we didn't see
		last = nil
	end
	if not last or (last.pos - pos).Magnitude >= Tuning.Knowledge.TrailSpacing then
		table.insert(trail, { pos = pos, t = now })
		if #trail > Tuning.Knowledge.TrailMax then
			table.remove(trail, 1)
		end
	else
		last.t = now
	end
end

-- source: "VISUAL" (officer) | "CRUISER" | "HELI" | "REPORT" | "HEARD"
function Knowledge.observe(inc: any, source: string, pos: Vector3, vel: Vector3?, observer: any?, seat: BasePart?)
	local k = inc.knowledge
	local now = os.clock()
	local visual = source == "VISUAL" or source == "CRUISER" or source == "HELI"
	local prevRank = RANK[k.level]

	if visual then
		if source == "HELI" then
			k.lastHeliT = now
		else
			k.lastVisualT = now
			k.visualBy = observer
		end
		-- velocity: what the observer actually sees
		local v = vel or Vector3.zero
		if vel == nil and now - k.t < 1.5 and now - k.t > 0.05 then
			v = (pos - k.obsPos) / (now - k.t)
		end
		k.vel = k.vel:Lerp(v, 0.6)
		local vehicle = vehicleModelOf(seat)
		if (seat ~= nil) ~= k.inVehicle or vehicle ~= k.vehicle then
			if seat and not k.inVehicle then
				Log.event("SUSPECT IN VEHICLE", "#%d %s", inc.id, if vehicle then vehicle.Name else "?")
			elseif not seat and k.inVehicle then
				Log.event("SUSPECT ON FOOT", "#%d left vehicle", inc.id)
				k.abandoned = { vehicle = k.vehicle, pos = if k.vehicle and k.vehicle.Parent then k.vehicle:GetPivot().Position else pos, t = now }
			elseif seat and vehicle ~= k.vehicle then
				Log.event("SUSPECT VEHICLE CHANGED", "#%d now in %s", inc.id, if vehicle then vehicle.Name else "?")
			end
		end
		k.inVehicle = seat ~= nil
		k.seat = seat
		k.vehicle = vehicle
		k.conf = 1
		pushTrail(k, pos, now)
		k.predicted = nil
	else
		k.lastReportT = now
		k.conf = math.max(k.conf, Tuning.Knowledge.ReportConfidence)
		if source == "REPORT" and seat ~= nil then
			-- a 911 caller can describe the car
			k.inVehicle = true
			k.seat = seat
			k.vehicle = vehicleModelOf(seat)
		end
		k.vel = Vector3.zero
		k.predicted = nil
	end
	k.pos = pos
	k.obsPos = pos
	k.t = now

	-- reacquisition logging (the level itself is recomputed in update)
	if visual and prevRank >= RANK[L.PREDICTED] then
		Log.event("SUSPECT REACQUIRED", "#%d by %s after %s", inc.id, source, k.level)
	end
end

-- Dead-reckon a vehicle along the road graph from the last observation.
local function predictAlongRoad(k: any, elapsed: number): Vector3
	local speed = flat(k.vel).Magnitude
	if speed < 4 then
		return k.obsPos
	end
	if not k.predicted then
		local pts = nil
		if RoadGraph.ready and RoadGraph.predict then
			pts = RoadGraph.predict(k.obsPos, flat(k.vel), Tuning.Knowledge.PredictCarMax + 40)
		end
		if not pts or #pts < 2 then
			pts = { k.obsPos, k.obsPos + flat(k.vel).Unit * Tuning.Knowledge.PredictCarMax }
		end
		local acc = { 0 }
		for i = 2, #pts do
			acc[i] = acc[i - 1] + (pts[i] - pts[i - 1]).Magnitude
		end
		k.predicted = { pts = pts, acc = acc }
	end
	-- assume they keep going, slowing a little (junctions, traffic)
	local travelled = math.min(speed * 0.85 * elapsed, Tuning.Knowledge.PredictCarMax)
	local pr = k.predicted
	for i = 2, #pr.pts do
		if pr.acc[i] >= travelled then
			local seg = pr.acc[i] - pr.acc[i - 1]
			local t = if seg > 0 then (travelled - pr.acc[i - 1]) / seg else 0
			return pr.pts[i - 1]:Lerp(pr.pts[i], t)
		end
	end
	return pr.pts[#pr.pts]
end

function Knowledge.predictedPath(inc: any): { Vector3 }?
	local k = inc.knowledge
	return if k.predicted then k.predicted.pts else nil
end

-- v258: last seen inside a mapped building (bank vault, store...) and still in it = contained.
-- The perimeter would see them leave, so police keep searching the building instead of
-- extrapolating a getaway; confidence drains far slower.
local Fac: any = nil
local function facilities(): any?
	if Fac == nil then
		Fac = false
		local mod = script.Parent and script.Parent.Parent and script.Parent.Parent:FindFirstChild("Facilities")
		if mod then
			local ok, F = pcall(require, mod)
			if ok then Fac = F end
		end
	end
	return Fac or nil
end

local function containedIn(inc: any, k: any): any?
	local F = facilities()
	if not F or not k.obsPos then return nil end
	local ok, b = pcall(F.buildingAt, k.obsPos)
	if not ok or not b or b.type == "City" then return nil end
	local char = inc.player and inc.player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	local ok2, cur = pcall(F.buildingAt, root.Position)
	return if ok2 and cur == b then b else nil
end

function Knowledge.update(inc: any, dt: number, now: number)
	local k = inc.knowledge
	local T = Tuning.Knowledge
	local old = k.level
	local sinceVisual = now - k.lastVisualT
	local sinceHeli = now - k.lastHeliT
	local sinceSeen = math.min(sinceVisual, sinceHeli)
	local sinceAny = now - k.t
	local stars = math.clamp(inc.pursuit.stars or 1, 1, 5)

	local level
	if sinceVisual <= T.DirectWindow then
		level = L.DIRECT
		k.conf = 1
	elseif sinceHeli <= T.DirectWindow then
		level = L.HELI
		k.conf = 1
	elseif now - k.lastReportT <= T.ReportWindow and k.lastReportT >= k.t - 0.01 then
		level = L.UNIT
	elseif sinceSeen <= T.RecentWindow or sinceAny <= T.RecentWindow then
		level = L.RECENT
		k.conf = math.max(k.conf - dt * 0.02, 0.8)
		k.pos = k.obsPos + flat(k.vel) * math.min(sinceAny, 1.5)
	elseif containedIn(inc, k) then
		-- v258: building contained - search it, no getaway extrapolation
		level = if sinceAny <= T.PredictWindow then L.PREDICTED else L.SEARCHING
		k.pos = k.obsPos
		if inc.player:GetAttribute("BankScene") then
			-- active bank robbery scene: full response until the building is cleared
			k.conf = math.max(k.conf, 0.6)
		else
			k.conf = math.max(0, k.conf - (T.SearchDecay[stars] or 0.04) * (T.ContainedDecayScale or 0.1) * dt)
		end
	elseif sinceAny <= T.PredictWindow then
		level = L.PREDICTED
		k.conf = math.max(0, k.conf - T.PredictDecay * dt)
		if k.inVehicle then
			k.pos = predictAlongRoad(k, sinceAny)
		else
			local drift = flat(k.vel) * math.min(sinceAny, 4)
			if drift.Magnitude > T.PredictFootMax then
				drift = drift.Unit * T.PredictFootMax
			end
			k.pos = k.obsPos + drift
		end
	else
		level = L.SEARCHING
		k.conf = math.max(0, k.conf - (T.SearchDecay[stars] or 0.04) * dt)
	end
	if k.conf <= 0 and RANK[level] >= RANK[L.SEARCHING] then
		level = L.LOST
	end

	-- vehicle stop tracking (only meaningful while someone is watching)
	if k.inVehicle and (level == L.DIRECT or level == L.HELI) and flat(k.vel).Magnitude < Tuning.Vehicles.StopSpeed then
		k.stoppedSince = k.stoppedSince or now
	elseif level == L.DIRECT or level == L.HELI then
		k.stoppedSince = nil
	end

	if level ~= old then
		k.level = level
		k.levelSince = now
		local was, is = RANK[old], RANK[level]
		if was <= RANK[L.HELI] and is >= RANK[L.RECENT] then
			Log.event("LOST VISUAL", "#%d %s (last seen %.0f studs %s)", inc.id, inc.player.Name, flat(k.vel).Magnitude, if k.inVehicle then "driving" else "on foot")
		end
		if level == L.HELI then
			Log.event("HELICOPTER HAS VISUAL", "#%d", inc.id)
		elseif level == L.PREDICTED then
			Log.event("PREDICTING", "#%d %s", inc.id, if k.inVehicle then "along road network" else "along heading")
		elseif level == L.SEARCHING then
			Log.event("SEARCH START", "#%d around (%.0f, %.0f)", inc.id, k.pos.X, k.pos.Z)
		elseif level == L.LOST then
			Log.event("SUSPECT LOST", "#%d %s evaded", inc.id, inc.player.Name)
		end
	end

	-- keep the legacy pursuit table meaningful for everything else (HUD, waves, helicopter focus)
	local p = inc.pursuit
	p.lastSeenPos = k.pos
	local searching = RANK[level] >= RANK[L.PREDICTED]
	p.searching = searching
	p.outside = searching
	local evadeTime = Config.Heat.EvadeTime[stars] or 20
	p.evade = if searching then (1 - k.conf) * evadeTime else 0
end

-- Heat.step evasion hook: the suspect is only "lost" when knowledge says so.
function Knowledge.heatEvade(player: Player, p: any, _dt: number, _now: number): string?
	local inc = Ctx.Incidents.get(player)
	if not inc or inc.pursuit ~= p then
		return "handled" -- the incident is created on the next AI tick; don't let distance clear it meanwhile
	end
	if inc.knowledge.level == L.LOST then
		Ctx.Heat.clear(player, "Evaded")
		return "cleared"
	end
	return "handled"
end

-- Heat.spotted / Heat.addCrime hook.
function Knowledge.heatSighting(player: Player, p: any, pos: Vector3, source: string, observer: any?): boolean
	local inc = Ctx.Incidents.ensure(p)
	if not inc then
		return false
	end
	local seat, vel = nil, nil
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if source == "VISUAL" or source == "CRUISER" or source == "HELI" or source == "REPORT" then
		seat = hum and hum.SeatPart or nil
		if root and root:IsA("BasePart") and source ~= "REPORT" then
			vel = root.AssemblyLinearVelocity
		end
	end
	Knowledge.observe(inc, source, pos, vel, observer, seat)
	local now = os.clock()
	p.lastSeenPos = pos
	p.lastSeenTime = now
	p.searching = false
	p.evade = 0
	return true
end

return Knowledge
