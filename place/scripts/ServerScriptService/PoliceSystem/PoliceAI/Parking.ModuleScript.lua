--[[
	PoliceAI · Parking
	Stop-slot reservation so responding cruisers pick different, sensible places along the
	mapped roads near an incident instead of piling onto one coordinate. Slots sit in real
	lanes (RoadGraph lane offsets), keep Spacing studs apart from every other reserved slot
	and every parked police vehicle, and avoid the suspect's own car.
]]

local Parking = {}
local Ctx, Tuning, Log, RoadGraph, Van, Util

-- key (van or any token) -> { pos, facing, inc }
local reserved: { [any]: any } = {}

function Parking.bind(ctx)
	Ctx = ctx
	Tuning, Log, RoadGraph, Van, Util = ctx.Tuning, ctx.Log, ctx.RoadGraph, ctx.Van, ctx.Util
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function clearOf(pos: Vector3, key: any, spacing: number): boolean
	for other, slot in reserved do
		if other ~= key and (slot.pos - pos).Magnitude < spacing then
			return false
		end
	end
	for van in Van.all do
		if van ~= key and not van.dead and van.body and van.body.Parent then
			if (van.body.Position - pos).Magnitude < spacing then
				-- a moving cruiser will move on; a parked one is a real obstacle
				if van.parked or van.aiParkedFor then
					return false
				end
			end
		end
	end
	return true
end

-- Reserve a stop near `center`. opts: { felony = bool, behind = Vector3 (suspect car forward), min, max, preferred }
function Parking.reserve(inc: any, key: any, center: Vector3, opts: any?): (Vector3?, Vector3?)
	local o = opts or {}
	local P = Tuning.Parking
	local existing = reserved[key]
	if existing and existing.inc == inc and (existing.center - center).Magnitude < 25 then
		return existing.pos, existing.facing
	end
	reserved[key] = nil
	local minD = o.min or (if o.felony then P.FelonyMin else P.MinDistance)
	local maxD = o.max or P.MaxDistance
	local pref = o.preferred or (if o.felony then P.FelonyPreferred else P.Preferred)
	local best, bestScore, bestFacing = nil, math.huge, nil
	local k = inc and inc.knowledge
	local avoidCar = k and k.vehicle and k.vehicle.Parent and k.vehicle:GetPivot().Position or nil

	if RoadGraph.ready and RoadGraph.segmentsNear then
		for _, seg in RoadGraph.segmentsNear(center, maxD) do
			local a, b = seg.a, seg.b
			local dir = flat(b - a)
			local len = dir.Magnitude
			if len < 1 then
				continue
			end
			dir = dir.Unit
			local right = Vector3.new(-dir.Z, 0, dir.X)
			local n = math.max(1, math.floor(len / 9))
			for i = 0, n do
				local pt = a:Lerp(b, i / n) + right * seg.lane
				local d = flat(pt - center).Magnitude
				if d < minD or d > maxD then
					continue
				end
				if avoidCar and flat(pt - avoidCar).Magnitude < 13 then
					continue
				end
				if not clearOf(pt, key, P.Spacing) then
					continue
				end
				local score = math.abs(d - pref)
				if o.behind then
					-- felony stop: stay behind the suspect's car
					local rel = flat(pt - center)
					if rel.Magnitude > 0.1 and rel.Unit:Dot(o.behind) > 0.2 then
						score += 40
					end
				end
				if score < bestScore then
					bestScore, best = score, pt
					-- face the incident along the lane direction that points at it
					local toward = flat(center - pt)
					bestFacing = if toward.Magnitude > 0.1 and toward.Unit:Dot(dir) < 0 then -dir else dir
				end
			end
		end
	end

	if not best then
		-- no road nearby: spread on a ring (legacy behaviour, but still de-conflicted)
		for i = 0, 11 do
			local a = i / 12 * math.pi * 2
			local pt = center + Vector3.new(math.cos(a), 0, math.sin(a)) * pref
			local g = Util.groundAt(pt, 12, 40)
			if g and clearOf(g, key, P.Spacing) then
				best = g
				bestFacing = Util.safeUnit(flat(center - g), Vector3.zAxis)
				break
			end
		end
	end
	if best then
		reserved[key] = { pos = best, facing = bestFacing, inc = inc, center = center, at = os.clock() }
		Log.verbose("PARKING", "#%s slot %.0f studs from incident", if inc then tostring(inc.id) else "-", flat(best - center).Magnitude)
	end
	return best, bestFacing
end

function Parking.get(key: any): any
	return reserved[key]
end

function Parking.release(key: any)
	reserved[key] = nil
end

function Parking.releaseIncident(inc: any)
	for key, slot in reserved do
		if slot.inc == inc then
			reserved[key] = nil
		end
	end
end

-- Housekeeping: drop reservations of vehicles that are gone.
function Parking.sweep()
	local now = os.clock()
	for key, slot in reserved do
		local dead = type(key) == "table" and key.dead == true
		local isVehicle = type(key) == "table" and key.body ~= nil
		if dead or now - slot.at > (if isVehicle then 240 else 90) then
			reserved[key] = nil
		end
	end
end

-- Is `pos` clear of other police vehicles (spawn / placement check)?
function Parking.clearForSpawn(pos: Vector3, spacing: number?): boolean
	return clearOf(pos, nil, spacing or Tuning.Parking.Spacing)
end

return Parking
