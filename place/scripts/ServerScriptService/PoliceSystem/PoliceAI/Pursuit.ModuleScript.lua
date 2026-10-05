--[[
	PoliceAI · Pursuit  (PursuitCoordinator)
	Vehicle pursuits as a coordinated operation instead of every cruiser driving at the
	suspect's current position:

	  PRIMARY    directly behind the suspect (follows his observed trail when close)
	  SECONDARY  backs the primary up at a longer gap; becomes PRIMARY if it falls behind
	  TAIL       extra followers at a bigger gap (no conga line)
	  INTERCEPT  uses the mapped roads to get ahead of the predicted route
	  PARALLEL   runs a neighbouring road to keep pace without joining the convoy
	  SPIKE      races ahead and lays a spike strip (Roadside)
	  ROADBLOCK  parks across the road further ahead (Roadside)
	  STOP       suspect stopped: park behind him (reserved slots) and deploy the crew
	  SEARCH     contact lost: drive the likely roads

	Cruisers only know what Knowledge knows: routes go to the known/predicted position,
	never to the suspect's live position. A car switched while unseen is not known until
	someone sees it; an abandoned car found empty starts a search around it.

	v114 - physical chases: cruisers behind the suspect are solid against his car (only),
	speed scales with heat, and close units run real maneuvers when they have eyes on him:
	  PIT      (3+ stars) pull alongside the rear quarter, tap it, back off
	  RAM      (4+ stars) shove a slowed / cornering suspect from behind
	  BOX-IN   (2+ stars) once he slows, the secondary gets in front (rolling roadblock)
	Spike / roadblock units are dispatched from side streets ahead when no car on the
	chase can get there in time.
]]

local Pursuit = {}
local Ctx, Tuning, Log, Util, RoadGraph, Van, Config, CopAI
local Knowledge, Perception, Parking, Driver, Roadside, Search, Voice

local claimed: { [any]: any } = {} -- van -> incident

function Pursuit.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, RoadGraph, Van, Config, CopAI = ctx.Tuning, ctx.Log, ctx.Util, ctx.RoadGraph, ctx.Van, ctx.Config, ctx.CopAI
	Knowledge, Perception, Parking, Driver = ctx.Knowledge, ctx.Perception, ctx.Parking, ctx.Driver
	Roadside, Search, Voice = ctx.Roadside, ctx.Search, ctx.Voice
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function carName(van: any): string
	local id = van.aiUnitId
	if not id then
		Pursuit.nextUnitId = (Pursuit.nextUnitId or 0) + 1
		id = Pursuit.nextUnitId
		van.aiUnitId = id
		if van.model then
			van.model:SetAttribute("PoliceUnit", "Unit " .. id)
		end
	end
	return "Unit " .. id
end

local LABELS = {
	PRIMARY = "PRIMARY", SECONDARY = "SECONDARY", TAIL = "BACKUP", INTERCEPT = "INTERCEPT",
	PARALLEL = "PARALLEL", STOP = "BOXING IN", SEARCH = "SEARCHING", DEPLOY = "DEPLOYING",
	SPIKE = "SPIKE UNIT", ROADBLOCK = "ROADBLOCK",
}

local function setRole(inc: any, van: any, e: any, role: string)
	if e.role ~= role then
		e.role = role
		e.since = os.clock()
		e.target = nil
		if van.model then
			van.model:SetAttribute("PursuitRole", role)
			van.model:SetAttribute("IncidentId", inc.id)
		end
	end
	if not e.man then
		Driver.setLabel(van, LABELS[role] or role)
	end
end

local function speedFor(inc: any): number
	local V = Tuning.Vehicles
	local stars = math.clamp(inc.pursuit.stars or 1, 1, if V.PursuitSpeedByStars then #V.PursuitSpeedByStars else 5)
	return (V.PursuitSpeedByStars and V.PursuitSpeedByStars[stars]) or V.PursuitSpeed
end

---------------------------------------------------------------------------
-- the suspect's real car: collision-tagged so pursuit cars can touch it
---------------------------------------------------------------------------
local tagged: { [Model]: { [BasePart]: string } } = {}
local massCache: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

local function untagCar(model: Model?)
	if not model then
		return
	end
	local saved = tagged[model]
	tagged[model] = nil
	if saved then
		for part, g in saved do
			if part.Parent then
				part.CollisionGroup = g
			end
		end
	end
end

local function tagCar(inc: any, model: Model?)
	if inc.contactCar == model then
		return
	end
	untagCar(inc.contactCar)
	inc.contactCar = model
	if not model or not Tuning.Contact.Enabled or not Driver.groupsReady then
		return
	end
	local saved = {}
	local mass = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			saved[d] = d.CollisionGroup
			d.CollisionGroup = "PoliceSuspectCar"
			mass += d:GetMass()
		end
	end
	tagged[model] = saved
	massCache[model] = math.max(mass, 50)
end

local function carMass(model: Model): number
	return massCache[model] or 800
end

-- live physical state of the suspect's car (only used by units that can SEE it)
local function suspectBody(inc: any): any?
	local model = inc.contactCar
	local _, hum = Util.charInfo(inc.player)
	local seat = hum and hum.SeatPart
	if not model or not model.Parent or not seat then
		return nil
	end
	local ok, bcf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok or not bcf then
		return nil
	end
	local fwd = Util.safeUnit(flat(seat.CFrame.LookVector), Vector3.zAxis)
	local vel = flat(seat.AssemblyLinearVelocity)
	return {
		center = bcf.Position,
		fwd = fwd,
		right = Vector3.new(-fwd.Z, 0, fwd.X),
		vel = vel,
		speed = vel.Magnitude,
		len = math.max(size.X, size.Z),
		wid = math.min(size.X, size.Z),
	}
end

function Pursuit.total(): number
	local n = 0
	for van in claimed do
		if not van.dead then
			n += 1
		else
			claimed[van] = nil
		end
	end
	return n
end

function Pursuit.isClaimed(van: any): boolean
	return claimed[van] ~= nil
end

local function claimable(van: any, inc: any): boolean
	if van.dead or van.transporting or van.aiClaim or claimed[van] or van.typeName ~= "Cruiser" then
		return false
	end
	if not van.body or not van.body.Parent then
		return false
	end
	if van.crewTotal - van.crewOut <= 0 or van.crewOut > 0 then
		return false
	end
	if van.mode == "patrol" then
		return true
	end
	if van.pursuit == inc.pursuit then
		return true -- a legacy responder to this incident: take it over
	end
	return van.pursuit == nil and van.parked == true
end

function Pursuit.claim(inc: any, van: any, why: string?): any
	van.aiClaim = inc.id
	van.pursuit = inc.pursuit
	claimed[van] = inc
	local e = { role = "TAIL", since = os.clock(), joined = os.clock() }
	inc.cars[van] = e
	Driver.take(van)
	Log.event("PURSUIT UNIT JOINED", "#%d %s (%s)", inc.id, carName(van), why or "nearest free")
	return e
end

-- how: "cruise" (back to patrol) | "keep" (parked with its crew out - legacy owns it now)
function Pursuit.release(inc: any, van: any, how: string)
	local e = inc.cars[van]
	inc.cars[van] = nil
	claimed[van] = nil
	if e and e.op then
		Roadside.cancel(e.op, "unit released")
	end
	if inc.primary == van then
		inc.primary = nil
	end
	if inc.secondary == van then
		inc.secondary = nil
	end
	Driver.release(van)
	Driver.setLabel(van, nil)
	Parking.release(van)
	if van.model then
		van.model:SetAttribute("PursuitRole", nil)
	end
	if van.aiClaim == inc.id then
		van.aiClaim = nil
	end
	if van.dead or van.transporting then
		return
	end
	if how == "cruise" then
		van.pursuit = nil
		van.aiParkedFor = nil
		if van.crewOut == 0 and van.crewTotal > 0 then
			van:cruise()
		end
	end
end

-- Crew bails out of a parked cruiser onto the incident (felony stop / suspect on foot).
function Pursuit.deploy(inc: any, van: any, e: any)
	if van.dead or van.transporting or not inc.cars[van] then
		return
	end
	local exits = Driver.park(van)
	van.aiParkedFor = inc.id
	local n = van.crewTotal - van.crewOut
	local made = 0
	for i = 1, n do
		local cf = exits[i] or exits[1]
		if not cf then
			break
		end
		van.crewOut += 1
		local cop = CopAI.new("Patrol", cf, {
			role = "Patrol",
			pursuit = inc.pursuit,
			homeCar = van,
			flank = if i % 2 == 0 then 1 else -1,
			onRemoved = function(_c, reason)
				if reason ~= "boarded" then
					van:crewLost()
				end
			end,
		})
		if cop then
			made += 1
			if i == 1 then
				local stopped = inc.knowledge.inVehicle
				local text = if stopped then "Police! Get out of the vehicle!" else "Police! Don't move!"
				Voice.say(cop, text, inc, { announce = true, style = "danger" })
			end
		else
			van.crewOut -= 1
		end
	end
	e.deployed = true
	e.deployedAt = os.clock()
	Log.event("CREW DEPLOYED", "#%d %s: %d officer(s) out", inc.id, carName(van), made)
end

---------------------------------------------------------------------------
-- breadcrumb path: exactly where the suspect was SEEN driving
---------------------------------------------------------------------------
local function trailPath(k: any, carPos: Vector3, heading: Vector3, eyes: boolean?): { Vector3 }?
	local trail = k.trail
	if #trail < 2 then
		return nil
	end
	local now = os.clock()
	if now - trail[#trail].t > Tuning.Knowledge.TrailBreak then
		return nil
	end
	local bestI, bestD = nil, math.huge
	for i, pt in trail do
		local d = flat(pt.pos - carPos).Magnitude
		if d < bestD then
			bestD, bestI = d, i
		end
	end
	if not bestI or bestD > 60 then
		return nil
	end
	local pts = { carPos }
	local startI = bestI
	if flat(trail[bestI].pos - carPos):Dot(heading) < 0 and bestI < #trail then
		startI = bestI + 1
	end
	for j = startI, #trail do
		table.insert(pts, trail[j].pos)
	end
	if (k.pos - pts[#pts]).Magnitude > 3 then
		table.insert(pts, k.pos)
	end
	local vel = flat(k.vel)
	if eyes then
		-- lead the car: where it is by now, not where it was last reported
		local lead = math.clamp(now - k.t + 0.15, 0, 0.5)
		if vel.Magnitude > 3 then
			table.insert(pts, pts[#pts] + vel * lead)
		end
	elseif vel.Magnitude > 8 and RoadGraph.ready and RoadGraph.predict then
		-- lost sight at a corner: keep going the way he was heading along the roads
		local ext = k.trailExt
		if not ext or ext.t ~= k.t then
			local pred = RoadGraph.predict(pts[#pts], vel, 260)
			ext = { t = k.t, pts = pred or {} }
			k.trailExt = ext
		end
		for i = 2, #ext.pts do
			table.insert(pts, ext.pts[i])
		end
	end
	if #pts < 2 then
		return nil
	end
	return pts
end

---------------------------------------------------------------------------
-- opportunity planning (async): intercept / spike / roadblock sites on the predicted route
---------------------------------------------------------------------------
local function roughEta(from: Vector3, to: Vector3): number
	return flat(to - from).Magnitude * 1.35 / (Tuning.Vehicles.PursuitSpeed * 0.8)
end

local function routeEta(from: Vector3, to: Vector3): number?
	local pts = RoadGraph.route(from, to)
	if not pts or #pts < 2 then
		return nil
	end
	local len = 0
	for i = 2, #pts do
		len += (pts[i] - pts[i - 1]).Magnitude
	end
	return len / (Tuning.Vehicles.PursuitSpeed * 0.75)
end

local function siteAt(path: { Vector3 }, ids: { number }, dists: { number }, i: number): any?
	local a, b = path[i], path[i + 1]
	if not b then
		return nil
	end
	local seg = flat(b - a)
	if seg.Magnitude < 10 then
		return nil
	end
	local dir = seg.Unit
	-- mid-block: never right on a junction node
	local pos = a:Lerp(b, 0.5)
	local lane = 3.25
	if ids[i] and ids[i + 1] and ids[i] > 0 and ids[i + 1] > 0 and RoadGraph.laneBetween then
		lane = RoadGraph.laneBetween(ids[i], ids[i + 1])
	end
	return { pos = pos, dir = dir, right = Vector3.new(-dir.Z, 0, dir.X), lane = lane, d = (dists[i] + dists[i + 1]) / 2 }
end

local function plan(inc: any)
	local V = Tuning.Vehicles
	local k = inc.knowledge
	local speed = flat(k.vel).Magnitude
	local out: any = { at = os.clock() }
	if speed < 16 or not Knowledge.fresh(inc) or not RoadGraph.ready or not RoadGraph.predict then
		inc.vplan = out
		return
	end
	local path, ids, dists = RoadGraph.predict(k.pos, flat(k.vel), math.min(speed * 16, 1300))
	if not path or #path < 3 then
		inc.vplan = out
		return
	end
	out.path = path
	-- the suspect's own road costs more for PARALLEL routing
	local penalty = {}
	for _, id in ids do
		if id > 0 then
			penalty[id] = 4
		end
	end
	out.penalty = penalty

	local free = {}
	for van, e in inc.cars do
		if van ~= inc.primary and van ~= inc.secondary and not e.op and not e.deployed and not van.dead then
			table.insert(free, van)
		end
	end
	if #free == 0 then
		inc.vplan = out
		return
	end
	local suspectSpeed = math.max(speed, 20)
	local stars = inc.pursuit.stars or 1
	local now = os.clock()

	local function bestFor(minLead: number, maxLead: number, setup: number, exclude: { [any]: boolean }?): (any?, any?)
		local bestVan, bestSite, bestMargin = nil, nil, -math.huge
		for i = 2, #path - 1 do
			local d = dists[i]
			if d >= minLead and d <= maxLead then
				local site = siteAt(path, ids, dists, i)
				if site then
					local tS = site.d / suspectSpeed
					for _, van in free do
						if not (exclude and exclude[van]) then
							local margin = tS - (roughEta(van.body.Position, site.pos) + setup)
							if margin > 1 and margin > bestMargin then
								bestVan, bestSite, bestMargin = van, site, margin
							end
						end
					end
				end
			end
		end
		if bestVan and bestSite then
			-- confirm with a real road route
			local eta = routeEta(bestVan.body.Position, bestSite.pos)
			if not eta or eta + setup + 0.5 > bestSite.d / suspectSpeed then
				return nil, nil
			end
		end
		return bestVan, bestSite
	end

	local S, R = Tuning.Spike, Tuning.Roadblock
	local used = {}
	if R.Enabled and stars >= R.MinStars and not inc.roadside.ROADBLOCK and now >= (inc.roadblockReadyAt or 0) then
		local van, site = bestFor(R.MinLead, R.MaxLead, R.SetupTime, used)
		if van and site then
			used[van] = true
			local vans = { van }
			if stars >= 4 then
				local second, secondSite = nil, nil
				for _, other in free do
					if not used[other] and roughEta(other.body.Position, site.pos) + R.SetupTime < site.d / suspectSpeed then
						second, secondSite = other, site
						break
					end
				end
				if second and secondSite then
					used[second] = true
					table.insert(vans, second)
				end
			end
			out.roadblock = { vans = vans, site = site }
		end
	end
	if S.Enabled and stars >= S.MinStars and not inc.roadside.SPIKE and now >= (inc.spikeReadyAt or 0) then
		local van, site = bestFor(S.MinLead, S.MaxLead, S.SetupTime, used)
		if van and site then
			used[van] = true
			out.spike = { van = van, site = site }
		end
	end
	local ivan, isite = bestFor(120, 700, 0.5, used)
	if ivan and isite then
		out.intercept = { van = ivan, pos = isite.pos + isite.right * isite.lane, site = isite }
	end

	-- nobody on the chase can get ahead in time: send a unit from a side street near a
	-- site further up the predicted route (hidden spawn, then it DRIVES to the site)
	local pathIds = {}
	for _, id in ids do
		if id > 0 then
			pathIds[id] = true
		end
	end
	local function findDispatch(minLead: number, maxLead: number, setup: number, count: number): any?
		-- sample up to 6 sites spread over the whole lead window, nearest first
		local inRange = {}
		for i = 2, #path - 1 do
			if dists[i] >= minLead and dists[i] <= maxLead then
				table.insert(inRange, i)
			end
		end
		local picks = {}
		local stride = math.max(1, math.ceil(#inRange / 6))
		for n = 1, #inRange, stride do
			table.insert(picks, inRange[n])
		end
		if #inRange > 0 and picks[#picks] ~= inRange[#inRange] then
			table.insert(picks, inRange[#inRange])
		end
		for _, i in picks do
			do
				local site = siteAt(path, ids, dists, i)
				if site then
					local tS = site.d / suspectSpeed
					local cands = {}
					for _, id in RoadGraph.nodesNear(site.pos, 340) do
						if not pathIds[id] then
							local pos = RoadGraph.nodePos(id)
							if pos then
								local away = flat(pos - site.pos).Magnitude
								local margin = tS - (roughEta(pos, site.pos) + setup)
								if away >= 110 and margin > 1.5 then
									table.insert(cands, { pos = pos, margin = margin })
								end
							end
						end
					end
					table.sort(cands, function(a, b)
						return a.margin > b.margin
					end)
					local spawns = {}
					for n, c in cands do
						if n > 10 or #spawns >= count then
							break
						end
						local clear = Ctx.Parking.clearForSpawn(c.pos, 26)
						for _, other in spawns do
							if flat(other - c.pos).Magnitude < 30 then
								clear = false
							end
						end
						if clear and not Util.visibleToAnyPlayer(c.pos + Vector3.new(0, 4, 0), 600) then
							table.insert(spawns, c.pos)
						end
					end
					if #spawns > 0 then
						return { site = site, spawns = spawns }
					end
				end
			end
		end
		return nil
	end
	if R.Enabled and R.DispatchUnits and stars >= R.MinStars and not out.roadblock and not inc.roadside.ROADBLOCK
		and not inc.roadblockDispatching and now >= (inc.roadblockReadyAt or 0) then
		out.roadblockSpawn = findDispatch(R.MinLead + 40, R.MaxLead, R.SetupTime, if stars >= 4 then 2 else 1)
	end
	if S.Enabled and S.DispatchUnits and stars >= S.MinStars and not out.spike and not inc.roadside.SPIKE
		and not inc.spikeDispatching and now >= (inc.spikeReadyAt or 0) then
		out.spikeSpawn = findDispatch(S.MinLead + 40, S.MaxLead, S.SetupTime, 1)
	end
	-- v116: a unit cuts in from a side street ahead every so often (2+ stars)
	if stars >= 2 and not out.intercept and not inc.interceptDispatching and now >= (inc.interceptDispatchAt or 0) then
		out.interceptSpawn = findDispatch(160, 650, 0.5, 1)
	end
	inc.vplan = out
end

local function dispatchRoadside(inc: any, kind: string, d: any)
	local flag = if kind == "SPIKE" then "spikeDispatching" else "roadblockDispatching"
	local ok, err = pcall(function()
		local vans = {}
		for _, pos in d.spawns do
			if Pursuit.total() >= Tuning.Vehicles.MaxPursuitCars then
				break
			end
			local okSpawn, car = pcall(Van.spawnPatrol, pos, Config.PatrolCars.Officers, true, flat(d.site.pos - pos))
			if okSpawn and car then
				local disp = Ctx.Dispatcher
				if disp and disp.adoptPatrolCar then
					disp.adoptPatrolCar(car)
				end
				if not inc.pursuit.active or inc.closed then
					break
				end
				Pursuit.claim(inc, car, "dispatched from a side street for a " .. string.lower(kind))
				table.insert(vans, car)
			end
		end
		if #vans == 0 or not inc.pursuit.active or inc.closed or inc.mode ~= "VEHICLE" then
			return
		end
		if kind == "SPIKE" and not inc.roadside.SPIKE then
			Roadside.startSpike(inc, vans[1], d.site)
		elseif kind == "ROADBLOCK" and not inc.roadside.ROADBLOCK then
			Roadside.startRoadblock(inc, vans, d.site)
		end
	end)
	inc[flag] = nil
	if not ok then
		Log.warn("roadside dispatch", err)
	end
end

local function parallelTarget(inc: any, van: any): Vector3?
	local k = inc.knowledge
	local heading = flat(k.vel)
	if heading.Magnitude < 3 or not RoadGraph.nodesNear then
		return nil
	end
	heading = heading.Unit
	local ahead = k.pos + heading * 130
	local path = inc.vplan and inc.vplan.path
	if path and #path >= 2 then
		local acc = 0
		for i = 2, #path do
			acc += (path[i] - path[i - 1]).Magnitude
			if acc >= 130 then
				ahead = path[i]
				break
			end
		end
	end
	local right = Vector3.new(-heading.Z, 0, heading.X)
	local mySide = if flat(van.body.Position - k.pos):Dot(right) >= 0 then 1 else -1
	local best, bestScore = nil, math.huge
	for _, id in RoadGraph.nodesNear(ahead, 180) do
		local pos = RoadGraph.nodePos(id)
		if pos then
			local rel = flat(pos - ahead)
			local lateral = rel:Dot(right)
			local along = rel:Dot(heading)
			local absLat = math.abs(lateral)
			if absLat >= 45 and absLat <= 175 and math.abs(along) < 100 then
				local score = math.abs(absLat - 90) + math.abs(along) * 0.5 + (if (lateral >= 0) == (mySide >= 0) then 0 else 60)
				if score < bestScore then
					best, bestScore = pos, score
				end
			end
		end
	end
	return best
end

---------------------------------------------------------------------------
-- roles
---------------------------------------------------------------------------
local function assignRoles(inc: any, now: number, stopped: boolean)
	local V = Tuning.Vehicles
	local k = inc.knowledge
	local cars = {}
	for van, e in inc.cars do
		if not e.op and not e.deployed and not van.dead then
			table.insert(cars, van)
		end
	end
	if #cars == 0 then
		return
	end
	local function dist(van: any): number
		return flat(van.body.Position - k.pos).Magnitude
	end
	table.sort(cars, function(a, b)
		return dist(a) < dist(b)
	end)

	if stopped then
		for _, van in cars do
			if dist(van) < 380 then
				setRole(inc, van, inc.cars[van], "STOP")
			end
		end
		if not inc.stopLogged then
			inc.stopLogged = true
			Log.event("VEHICLE STOP", "#%d suspect stopped - units boxing in", inc.id)
		end
		return
	end
	inc.stopLogged = nil

	-- PRIMARY (with hysteresis) and SECONDARY
	local prev = inc.primary
	local primary = nil
	if prev and inc.cars[prev] and table.find(cars, prev) then
		local dP, dBest = dist(prev), dist(cars[1])
		if not (dP > V.FallBehind and dBest < dP - 150) then
			primary = prev
		else
			Log.event("PRIMARY FELL BEHIND", "#%d %s", inc.id, carName(prev))
		end
	end
	if not primary then
		primary = cars[1]
		if primary ~= prev then
			if primary == inc.secondary then
				Log.event("SECONDARY -> PRIMARY", "#%d %s takes the lead", inc.id, carName(primary))
				inc.secondary = nil
			else
				Log.event("PRIMARY ASSIGNED", "#%d %s", inc.id, carName(primary))
			end
		end
	end
	inc.primary = primary
	local secondary = inc.secondary
	if not secondary or secondary == primary or not inc.cars[secondary] or not table.find(cars, secondary) then
		secondary = nil
		for _, van in cars do
			if van ~= primary then
				secondary = van
				break
			end
		end
		if secondary then
			Log.event("SECONDARY ASSIGNED", "#%d %s", inc.id, carName(secondary))
		end
	end
	inc.secondary = secondary
	setRole(inc, primary, inc.cars[primary], "PRIMARY")
	if secondary then
		setRole(inc, secondary, inc.cars[secondary], "SECONDARY")
	end

	-- everyone else: roadside tactics, intercept, parallel, tail
	local rest = {}
	for _, van in cars do
		if van ~= primary and van ~= secondary then
			table.insert(rest, van)
		end
	end
	local vp = inc.vplan or {}
	local function take(van: any): boolean
		local i = table.find(rest, van)
		if i then
			table.remove(rest, i)
			return true
		end
		return false
	end
	if vp.roadblock and not inc.roadside.ROADBLOCK then
		local ok = true
		for _, van in vp.roadblock.vans do
			if not table.find(rest, van) then
				ok = false
			end
		end
		if ok then
			for _, van in vp.roadblock.vans do
				take(van)
			end
			Roadside.startRoadblock(inc, vp.roadblock.vans, vp.roadblock.site)
		end
		vp.roadblock = nil
	end
	if vp.spike and not inc.roadside.SPIKE and table.find(rest, vp.spike.van) then
		take(vp.spike.van)
		Roadside.startSpike(inc, vp.spike.van, vp.spike.site)
		vp.spike = nil
	end
	if vp.roadblockSpawn and not inc.roadside.ROADBLOCK and not inc.roadblockDispatching then
		inc.roadblockDispatching = true
		task.spawn(dispatchRoadside, inc, "ROADBLOCK", vp.roadblockSpawn)
		vp.roadblockSpawn = nil
	end
	if vp.spikeSpawn and not inc.roadside.SPIKE and not inc.spikeDispatching then
		inc.spikeDispatching = true
		task.spawn(dispatchRoadside, inc, "SPIKE", vp.spikeSpawn)
		vp.spikeSpawn = nil
	end
	if vp.interceptSpawn and not inc.interceptDispatching and Pursuit.total() < Tuning.Vehicles.MaxPursuitCars then
		local d = vp.interceptSpawn
		vp.interceptSpawn = nil
		inc.interceptDispatching = true
		inc.interceptDispatchAt = now + (Tuning.Vehicles.InterceptDispatch or 14)
		task.spawn(function()
			local ok, err = pcall(function()
				local okSpawn, car = pcall(Van.spawnPatrol, d.spawns[1], Config.PatrolCars.Officers, true, flat(d.site.pos - d.spawns[1]))
				if okSpawn and car and inc.pursuit.active and not inc.closed then
					local disp = Ctx.Dispatcher
					if disp and disp.adoptPatrolCar then
						disp.adoptPatrolCar(car)
					end
					local e = Pursuit.claim(inc, car, "cutting in from a side street ahead")
					setRole(inc, car, e, "INTERCEPT")
					e.target = d.site.pos + d.site.right * (d.site.lane or 3)
					e.targetAt = os.clock()
					e.lockRole = os.clock() + 12
					Log.event("INTERCEPT DISPATCHED", "#%d unit coming out of a side street %.0f studs ahead", inc.id, d.site.d or 0)
				end
			end)
			inc.interceptDispatching = nil
			if not ok then
				Log.warn("intercept dispatch", err)
			end
		end)
	end
	if vp.intercept and table.find(rest, vp.intercept.van) then
		local van = vp.intercept.van
		take(van)
		local e = inc.cars[van]
		if e.role ~= "INTERCEPT" then
			Log.event("INTERCEPT ASSIGNED", "#%d %s cutting ahead %.0f studs", inc.id, carName(van), vp.intercept.site.d or 0)
		end
		setRole(inc, van, e, "INTERCEPT")
		e.target = vp.intercept.pos
		e.targetAt = now
	end
	local nPar = 0
	for _, van in rest do
		local e = inc.cars[van]
		if e.lockRole and now < e.lockRole then
			continue
		end
		if nPar < V.MaxParallel and (e.role == "PARALLEL" or flat(k.vel).Magnitude > 20) then
			nPar += 1
			if e.role ~= "PARALLEL" then
				Log.verbose("PARALLEL ASSIGNED", "#%d %s", inc.id, carName(van))
			end
			setRole(inc, van, e, "PARALLEL")
		else
			setRole(inc, van, e, "TAIL")
		end
	end
end

---------------------------------------------------------------------------
-- maneuvers: PIT / RAM / BOX-IN (steered at 10 Hz by Driver target mode)
---------------------------------------------------------------------------
local function endManeuver(van: any, e: any, drv: any)
	e.man = nil
	e.push = nil
	if drv then
		Driver.setTarget(drv, nil)
	end
	Driver.setLabel(van, LABELS[e.role] or e.role)
end

local function startPIT(inc: any, van: any, e: any, drv: any, b: any, now: number)
	local P = Tuning.PIT
	local side = if flat(van.body.Position - b.center):Dot(b.right) >= 0 then 1 else -1
	local man = { kind = "PIT", phase = "align", side = side, t0 = now, phaseT = now }
	e.man = man
	inc.pitAt = now
	Driver.setLabel(van, "PIT MANEUVER")
	Log.event("PIT ATTEMPT", "#%d %s lining up on the %s rear quarter", inc.id, van.aiUnitId and ("Unit " .. van.aiUnitId) or "unit", if side > 0 then "right" else "left")
	local Lc, Wc = van.cfg.Size.Z, van.cfg.Size.X
	Driver.setTarget(drv, function()
		local t = os.clock()
		if e.man ~= man or not inc.pursuit.active or inc.mode ~= "VEHICLE" then
			return nil
		end
		local s = suspectBody(inc)
		if not s then
			return nil
		end
		local lateral = s.wid * 0.5 + Wc * 0.5 + 1.2
		local alignPt = s.center - s.fwd * (s.len * 0.3 + Lc * 0.5) + s.right * man.side * lateral
		local lead = s.vel * 0.15
		if man.phase == "align" then
			local err = flat(van.body.Position - alignPt)
			local behind = -err:Dot(s.fwd)
			if err.Magnitude < 4.5 then
				man.phase = "tap"
				man.phaseT = t
				man.fwd0 = s.fwd
				man.speed0 = s.speed
				e.push = Tuning.Contact.ManeuverPush
				Log.event("PIT CONTACT", "#%d", inc.id)
			elseif t - man.t0 > P.AlignTimeout or s.speed < P.MinSpeed * 0.6 then
				return nil
			end
			return alignPt + lead, s.speed + math.clamp(behind * 1.3, -12, 16), s.fwd
		elseif man.phase == "tap" then
			if t - man.phaseT > P.TapTime then
				man.phase = "recover"
				man.phaseT = t
				e.push = Tuning.Contact.FollowPush
			end
			-- nose into the rear quarter
			return alignPt - s.right * man.side * (Wc * 0.75) + s.fwd * 3 + lead, s.speed + 5, s.fwd
		end
		if not man.judged and t - man.phaseT > 0.9 then
			man.judged = true
			local spun = man.fwd0 and s.fwd:Dot(man.fwd0) < 0.64
			local slowed = man.speed0 and s.speed < man.speed0 * 0.55
			Log.event(if spun or slowed then "PIT SUCCESS" else "PIT FAILED", "#%d", inc.id)
		end
		if t - man.phaseT > P.RecoverTime then
			return nil
		end
		return s.center - s.fwd * (s.len * 0.5 + Lc * 0.5 + 12), s.speed * 0.85, s.fwd
	end)
end

local function startRam(inc: any, van: any, e: any, drv: any, now: number)
	local man = { kind = "RAM", phase = "charge", t0 = now }
	e.man = man
	e.push = Tuning.Contact.ManeuverPush
	inc.ramAt = now
	Driver.setLabel(van, "RAMMING")
	Log.event("RAM", "#%d unit shoving the suspect", inc.id)
	local Lc = van.cfg.Size.Z
	Driver.setTarget(drv, function()
		local t = os.clock()
		if e.man ~= man or not inc.pursuit.active or inc.mode ~= "VEHICLE" then
			return nil
		end
		local s = suspectBody(inc)
		if not s then
			return nil
		end
		if man.phase == "charge" then
			if t - man.t0 > Tuning.Ram.Time then
				man.phase = "recover"
				man.phaseT = t
				e.push = Tuning.Contact.FollowPush
			end
			-- aim just inside his rear bumper
			return s.center - s.fwd * (s.len * 0.5 - 1.5) + s.vel * 0.1, s.speed + 14, s.fwd
		end
		if t - man.phaseT > 1.4 then
			return nil
		end
		return s.center - s.fwd * (s.len * 0.5 + Lc * 0.5 + 10), s.speed * 0.8, s.fwd
	end)
end

-- rolling roadblock: pass on the side, get in front, slow down
local function startBoxIn(inc: any, van: any, e: any, drv: any, b: any, now: number)
	local side = if flat(van.body.Position - b.center):Dot(b.right) >= 0 then 1 else -1
	local man = { kind = "BOX", side = side, t0 = now }
	e.man = man
	e.push = Tuning.Contact.FollowPush
	inc.boxAt = now
	Driver.setLabel(van, "BOXING IN")
	Log.event("BOX-IN", "#%d unit pulling in front of the suspect", inc.id)
	local Lc, Wc = van.cfg.Size.Z, van.cfg.Size.X
	Driver.setTarget(drv, function()
		local t = os.clock()
		if e.man ~= man or not inc.pursuit.active or inc.mode ~= "VEHICLE" then
			return nil
		end
		local s = suspectBody(inc)
		if not s or t - man.t0 > 14 or s.speed > Tuning.BoxIn.MaxSuspectSpeed + 12 then
			return nil
		end
		local rel = flat(van.body.Position - s.center)
		local along = rel:Dot(s.fwd)
		local ahead = s.center + s.fwd * (s.len * 0.5 + Lc * 0.5 + 5)
		if along < s.len * 0.5 + Lc * 0.3 then
			-- still beside / behind him: go around on our side
			local pass = s.center + s.right * man.side * (s.wid * 0.5 + Wc * 0.5 + 2.5) + s.fwd * (s.len * 0.6)
			return pass, s.speed + 12, s.fwd
		end
		return ahead, math.max(0, s.speed * 0.75 - 2), s.fwd
	end)
end

-- Should this car start a maneuver now? Only with eyes on the suspect, close, and in policy.
local function considerManeuver(inc: any, van: any, e: any, drv: any, sees: boolean, now: number): boolean
	if e.man then
		if not drv.targetFn then
			endManeuver(van, e, nil)
			return false
		end
		return true
	end
	if not sees or not Tuning.Contact.Enabled or not drv.contact then
		return false
	end
	local stars = inc.pursuit.stars or 1
	local b = suspectBody(inc)
	if not b then
		return false
	end
	local rel = flat(van.body.Position - b.center)
	local dist = rel.Magnitude
	local behind = -rel:Dot(b.fwd)
	-- let a spike strip / roadblock that's about to catch him do its job
	for _, op in inc.roadside do
		if (op.state == "deployed" or op.state == "set") and flat(op.site.pos - b.center).Magnitude < 260 then
			return false
		end
	end
	local P, R, B = Tuning.PIT, Tuning.Ram, Tuning.BoxIn
	if e.role == "PRIMARY" then
		if R.Enabled and stars >= R.MinStars and b.speed < R.MaxSuspectSpeed and b.speed > 6 and behind > 0 and dist < 32
			and now - (inc.ramAt or -math.huge) > R.Cooldown then
			startRam(inc, van, e, drv, now)
			return true
		end
		local k = inc.knowledge
		local steady = flat(k.vel).Magnitude > 1 and flat(k.vel).Unit:Dot(b.fwd) > 0.95
		if P.Enabled and stars >= P.MinStars and b.speed >= P.MinSpeed and dist < P.Range and behind > -4 and steady
			and now - (inc.pitAt or -math.huge) > P.Cooldown then
			startPIT(inc, van, e, drv, b, now)
			return true
		end
	elseif e.role == "SECONDARY" then
		if B.Enabled and stars >= B.MinStars and b.speed < B.MaxSuspectSpeed and b.speed > 4 and dist < 60
			and inc.primary and inc.primary.body and flat(inc.primary.body.Position - b.center).Magnitude < 45
			and now - (inc.boxAt or -math.huge) > 8 then
			startBoxIn(inc, van, e, drv, b, now)
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- per-car driving (4 Hz; the Driver interpolates at 30 Hz in between)
---------------------------------------------------------------------------
local function driveCar(inc: any, van: any, e: any, now: number)
	local V = Tuning.Vehicles
	local k = inc.knowledge
	if e.op then
		Perception.cruiser(van, inc, now)
		return
	end
	if e.deployed then
		-- crew is out; once they're all back aboard during a moving chase, resume
		if van.crewOut <= 0 and inc.mode == "VEHICLE" and not (k.stoppedSince and now - k.stoppedSince > 1) then
			e.deployed = false
			e.slot = nil
			van.aiParkedFor = nil
			Parking.release(van)
			setRole(inc, van, e, "TAIL")
			Log.event("UNIT REMOUNTED", "#%d %s rejoining pursuit", inc.id, carName(van))
		else
			return
		end
	end
	if now < (e.nextDrive or 0) then
		return
	end
	e.nextDrive = now + 0.15
	local drv = Driver.get(van) or Driver.take(van)
	local sees = Perception.cruiser(van, inc, now)
	local pos = van.body.Position
	local dist = flat(k.pos - pos).Magnitude
	local role = e.role
	local eyes = sees or Knowledge.hasEyes(inc)
	local speed = if Knowledge.fresh(inc) then flat(k.vel).Magnitude else 0
	local topSpeed = speedFor(inc)

	-- solid against the suspect's car for the units working behind him (armed only once
	-- the two aren't overlapping, so contact never starts inside his car)
	local car = inc.contactCar
	if car and car.Parent and (role == "PRIMARY" or role == "SECONDARY" or role == "TAIL") then
		local ok, bcf, size = pcall(function()
			return car:GetBoundingBox()
		end)
		if ok and bcf then
			local gap = flat(pos - bcf.Position).Magnitude - (math.max(size.X, size.Z) * 0.5 + van.cfg.Size.Z * 0.5)
			if drv.contact or gap > 3 then
				Driver.setContact(drv, e.push or Tuning.Contact.FollowPush, carMass(car))
			end
		end
	elseif drv.contact then
		Driver.clearContact(drv)
	end
	if considerManeuver(inc, van, e, drv, sees, now) then
		return
	end

	if role == "STOP" then
		if not e.slot then
			local fwd = flat(k.vel)
			if k.seat and k.seat.Parent then
				fwd = flat((k.seat :: BasePart).CFrame.LookVector)
			end
			local felony = van == inc.primary or van == inc.secondary
			e.slot = Parking.reserve(inc, van, k.pos, {
				felony = felony,
				behind = Util.safeUnit(fwd, Vector3.zAxis),
				preferred = if felony then nil else 45,
			})
			if e.slot then
				Driver.routeTo(drv, e.slot, {
					stopAtEnd = true,
					exact = true,
					endGap = 0,
					targetSpeed = 0,
					cap = 55,
					tolerance = 8,
					minInterval = 0,
					onArrive = function()
						if inc.cars[van] == e and e.role == "STOP" then
							Pursuit.deploy(inc, van, e)
						end
					end,
				}, now)
			else
				Driver.setOpts(drv, { holdStill = true })
			end
		end
		return
	end
	if e.slot then
		e.slot = nil
		Parking.release(van)
	end

	if role == "PRIMARY" or role == "SECONDARY" or role == "TAIL" then
		local gap = if role == "PRIMARY" then V.FollowGap elseif role == "SECONDARY" then V.SecondaryGap else V.TailGap
		local shift = if role == "SECONDARY" then 2.5 elseif role == "TAIL" then -2.5 else 0
		drv.ignoreSpacing = role == "PRIMARY"
		local recent = k.level == Knowledge.L.RECENT
		local canTrail = (eyes or recent) and dist < V.DirectRange
		if canTrail and e.trailRole == role and drv.pathFn then
			-- already locked on his trail at 10 Hz
		elseif canTrail and trailPath(k, drv.van.parts.ap.Position, drv.heading, eyes) then
			e.trailRole = role
			Driver.setPathFn(drv, function(d)
				if inc.closed or inc.mode ~= "VEHICLE" or e.role ~= role or e.man or e.op then
					return nil
				end
				local t = os.clock()
				local eyesNow = Knowledge.hasEyes(inc) or Perception.cruiserSaw(van, inc, t, 0.6)
				if not eyesNow and k.level ~= Knowledge.L.RECENT then
					return nil
				end
				local pts = trailPath(k, d.van.parts.ap.Position, d.heading, eyesNow)
				if not pts then
					return nil
				end
				local sp = if Knowledge.fresh(inc) then flat(k.vel).Magnitude else 0
				return pts, { endGap = gap, targetSpeed = sp, cap = speedFor(inc), stopAtEnd = false, laneShift = shift, holdStill = false }
			end)
			if role == "PRIMARY" and not e.directLogged then
				e.directLogged = true
				Log.verbose("PRIMARY ON TRAIL", "#%d %s", inc.id, carName(van))
			end
		else
			e.directLogged = nil
			e.trailRole = nil
			if drv.pathFn then
				Driver.setPathFn(drv, nil)
			end
			Driver.routeTo(drv, k.pos, {
				endGap = gap,
				targetSpeed = if eyes then speed else 0,
				cap = topSpeed,
				stopAtEnd = false,
				laneShift = shift,
				tolerance = math.clamp(dist * 0.1, 15, 60),
				holdStill = false,
			}, now)
		end
		-- the lead car talks to the suspect over the PA
		if role == "PRIMARY" and sees and dist < 90 and now - (inc.paAt or 0) > 9 then
			inc.paAt = now
			Ctx.State.announce(inc.player, "POLICE: PULL OVER NOW!", "warn")
		end
		return
	end

	e.trailRole = nil
	drv.ignoreSpacing = false
	if drv.pathFn then
		Driver.setPathFn(drv, nil)
	end
	if role == "INTERCEPT" then
		local target = e.target or k.pos
		local closing = dist < 170 and flat(k.vel).Magnitude > 5 and flat(pos - k.pos):Dot(flat(k.vel)) > 0
		if closing or flat(target - pos).Magnitude < 30 and dist < 250 then
			-- he's coming our way: turn in behind as a follower
			Driver.routeTo(drv, k.pos, { endGap = V.SecondaryGap, targetSpeed = speed, cap = topSpeed, tolerance = 30, stopAtEnd = false, holdStill = false }, now)
		else
			Driver.routeTo(drv, target, { endGap = 0, targetSpeed = 0, cap = topSpeed, stopAtEnd = false, tolerance = 25, holdStill = false }, now)
		end
		return
	end

	if role == "PARALLEL" then
		if not e.target or now >= (e.targetAt or 0) then
			e.target = parallelTarget(inc, van)
			e.targetAt = now + 3
		end
		local goal = e.target or k.pos
		local penalty = inc.vplan and inc.vplan.penalty
		Driver.routeTo(drv, goal, { endGap = 0, targetSpeed = speed * 0.8, cap = V.ParallelSpeed, penalty = penalty, tolerance = 35, stopAtEnd = false, holdStill = false }, now)
		return
	end
end

---------------------------------------------------------------------------
-- fleet: claim nearby cruisers, dispatch more (out of sight, on the road network)
---------------------------------------------------------------------------
local function spawnCar(inc: any)
	local V = Tuning.Vehicles
	local k = inc.knowledge
	local heading = flat(k.vel)
	local fromPt: Vector3? = nil
	for attempt = 1, 14 do
		local pt = RoadGraph.randomPoint(k.pos, V.SpawnMin, V.SpawnMax)
		if pt then
			local rel = flat(pt - k.pos)
			local ahead = heading.Magnitude < 3 or rel.Magnitude < 1 or rel.Unit:Dot(heading.Unit) > 0.15
			if (ahead or attempt > 8) and not Util.visibleToAnyPlayer(pt + Vector3.new(0, 4, 0), 520) and Ctx.Parking.clearForSpawn(pt, 26) then
				fromPt = pt
				break
			end
		end
	end
	if not fromPt then
		return
	end
	local ok, car = pcall(Van.spawnPatrol, fromPt, Config.PatrolCars.Officers, true, flat(k.pos - fromPt))
	if not ok or not car then
		return
	end
	local disp = Ctx.Dispatcher
	if disp and disp.adoptPatrolCar then
		disp.adoptPatrolCar(car)
	end
	if inc.pursuit.active and inc.mode == "VEHICLE" then
		Pursuit.claim(inc, car, string.format("dispatched %.0f studs out", flat(fromPt - k.pos).Magnitude))
	end
end

local function fleet(inc: any, now: number)
	local V = Tuning.Vehicles
	local k = inc.knowledge
	local stars = math.clamp(inc.pursuit.stars or 1, 1, #V.CarsPerStar)
	local desired = V.CarsPerStar[stars] or 3
	local have = 0
	for _ in inc.cars do
		have += 1
	end
	-- v215: every free cruiser within range joins, above the star quota
	if (have < desired or V.JoinAll) and now >= (inc.claimAt or 0) then
		inc.claimAt = now + 1
		local list = {}
		for van in Van.all do
			if claimable(van, inc) and flat(van.body.Position - k.pos).Magnitude <= V.ClaimRadius then
				table.insert(list, van)
			end
		end
		table.sort(list, function(a, b)
			return flat(a.body.Position - k.pos).Magnitude < flat(b.body.Position - k.pos).Magnitude
		end)
		for _, van in list do
			if (have >= desired and not V.JoinAll) or Pursuit.total() >= V.MaxPursuitCars then
				break
			end
			Pursuit.claim(inc, van)
			have += 1
		end
	end
	if have < desired and now >= (inc.spawnAt or 0) and Pursuit.total() < V.MaxPursuitCars and Ctx.Units.isReady() then
		inc.spawnAt = now + V.SpawnCooldown
		local burst = math.min(desired - have, V.SpawnBurst or 1, V.MaxPursuitCars - Pursuit.total())
		for _ = 1, math.max(burst, 1) do
			task.spawn(function()
				local ok, err = pcall(spawnCar, inc)
				if not ok then
					Log.warn("pursuit spawn", err)
				end
			end)
		end
	end
end

-- Did anyone find the car he was last seen in - empty?
local function checkAbandoned(inc: any, now: number)
	local k = inc.knowledge
	if not k.inVehicle or not k.vehicle or not k.vehicle.Parent or Knowledge.hasEyes(inc) then
		return
	end
	if now < (inc.abandonCheckAt or 0) then
		return
	end
	inc.abandonCheckAt = now + 1
	local ok, vpos = pcall(function()
		return (k.vehicle :: Model):GetPivot().Position
	end)
	if not ok then
		return
	end
	for van in inc.cars do
		if not van.dead and van.body and flat(van.body.Position - vpos).Magnitude < 110 then
			local eye = van.body.Position + Vector3.new(0, 4, 0)
			if Perception.canSeeModel(eye, k.vehicle, { van.model }) then
				local seat = k.seat
				local _, hum = Util.charInfo(inc.player)
				local occupied = seat ~= nil and seat.Parent ~= nil and (seat :: any).Occupant ~= nil and (seat :: any).Occupant == hum
				if not occupied then
					k.inVehicle = false
					k.abandoned = { vehicle = k.vehicle, pos = vpos, t = now }
					k.seat = nil
					k.pos = vpos
					k.obsPos = vpos
					k.vel = Vector3.zero
					k.t = now
					k.lastReportT = now
					k.predicted = nil
					Log.event("ABANDONED VEHICLE FOUND", "#%d %s found the car empty - searching the area", inc.id, carName(van))
				end
				return
			end
		end
	end
end

---------------------------------------------------------------------------
-- entry points
---------------------------------------------------------------------------
local function statusLog(inc: any, now: number)
	local SI = Tuning.StatusLogInterval
	if not SI or SI <= 0 or now < (inc.statusAt or 0) then
		return
	end
	inc.statusAt = now + SI
	local k = inc.knowledge
	local n = 0
	for _ in inc.cars do
		n += 1
	end
	local prim = inc.primary and inc.primary.body and flat(inc.primary.body.Position - k.pos).Magnitude
	local function opState(kind: string, flag: string): string
		local op = inc.roadside[kind]
		if op then
			return op.state
		end
		return if inc[flag] then "dispatching" else "-"
	end
	Log.event("PURSUIT STATUS", "#%d %s | %d unit(s) | primary %s | spike %s | roadblock %s | knowledge %s",
		inc.id, inc.player.Name, n, if prim then string.format("%.0f studs back", prim) else "none",
		opState("SPIKE", "spikeDispatching"), opState("ROADBLOCK", "roadblockDispatching"), k.level)
	if n == 0 and now - (inc.modeSince or now) > 6 then
		Log.event("NO PURSUIT UNITS", "#%d no free cruiser in range and no hidden road spawn found yet", inc.id)
	end
end

local function vehicleMode(inc: any, now: number)
	local V = Tuning.Vehicles
	local k = inc.knowledge
	-- his real car becomes touchable for pursuit cars (physics, not knowledge)
	local _, hum = Util.charInfo(inc.player)
	local seat = hum and hum.SeatPart
	tagCar(inc, if seat then Knowledge.vehicleModelOf(seat) else nil)
	statusLog(inc, now)
	if not inc.radioStart then
		inc.radioStart = true
		if Tuning.ScannerHints then
			Ctx.State.announce(inc.player, "RADIO: \"All units, vehicle pursuit in progress!\"", "warn")
		end
	end
	fleet(inc, now)
	checkAbandoned(inc, now)
	local stopped = k.stoppedSince ~= nil and now - k.stoppedSince >= V.StopTime and Knowledge.hasEyes(inc)
	if now >= (inc.vRoleAt or 0) or (stopped and not inc.stopLogged) or (not stopped and inc.stopLogged) then
		inc.vRoleAt = now + V.RoleRefresh
		assignRoles(inc, now, stopped)
	end
	if now >= (inc.vPlanAt or 0) and not inc.vPlanning then
		inc.vPlanAt = now + V.PlanInterval
		inc.vPlanning = true
		task.spawn(function()
			local ok, err = pcall(plan, inc)
			inc.vPlanning = false
			if not ok then
				Log.warn("pursuit plan", err)
			end
		end)
	end
	for van, e in inc.cars do
		local ok, err = pcall(driveCar, inc, van, e, now)
		if not ok then
			Log.warn("pursuit drive", err)
		end
	end
end

local function carSearch(inc: any, now: number)
	tagCar(inc, nil)
	checkAbandoned(inc, now)
	local n = 0
	for van, e in inc.cars do
		if e.op or e.deployed then
			continue
		end
		n += 1
		if n > 3 then
			Pursuit.release(inc, van, "cruise")
			continue
		end
		setRole(inc, van, e, "SEARCH")
		Perception.cruiser(van, inc, now)
		local drv = Driver.get(van) or Driver.take(van)
		local reached = e.target and flat(e.target - van.body.Position).Magnitude < 25
		if not e.target or reached or now > (e.targetUntil or 0) then
			if e.target then
				Search.carDone(inc, van)
			end
			e.target = Search.carPoint(inc, van) or inc.knowledge.pos
			e.targetUntil = now + 25
		end
		Driver.routeTo(drv, e.target, { endGap = 0, targetSpeed = 0, cap = Tuning.Vehicles.SearchSpeed, tolerance = 15, stopAtEnd = false, holdStill = false }, now)
	end
end

-- Not a vehicle pursuit any more (suspect on foot, in custody, critical, searching on foot).
local function wrapUp(inc: any, now: number)
	tagCar(inc, nil)
	local V = Tuning.Vehicles
	local k = inc.knowledge
	local deployedCount = 0
	for _, e in inc.cars do
		if e.deployed or e.role == "DEPLOY" then
			deployedCount += 1
		end
	end
	for van, e in inc.cars do
		if e.op then
			Roadside.cancel(e.op, "mode " .. inc.mode)
		end
		if e.deployed then
			if van.crewOut > 0 then
				-- scene car: its crew is working the incident; legacy lifecycle takes it home later
				Pursuit.release(inc, van, "keep")
			else
				Pursuit.release(inc, van, "cruise")
			end
		elseif inc.mode == "FOOT" and Knowledge.fresh(inc) and deployedCount < V.MaxDeployCars and flat(van.body.Position - k.pos).Magnitude < V.DeployRadius then
			if e.role ~= "DEPLOY" then
				deployedCount += 1
				setRole(inc, van, e, "DEPLOY")
				local drv = Driver.get(van) or Driver.take(van)
				local slot = Parking.reserve(inc, van, k.pos, {})
				if slot then
					Log.event("UNIT DEPLOYING", "#%d %s pulling up to the foot pursuit", inc.id, carName(van))
					Driver.routeTo(drv, slot, {
						stopAtEnd = true,
						exact = true,
						endGap = 0,
						targetSpeed = 0,
						cap = 60,
						tolerance = 10,
						minInterval = 0,
						onArrive = function()
							if inc.cars[van] == e then
								Pursuit.deploy(inc, van, e)
							end
						end,
						onFail = function()
							if inc.cars[van] == e then
								Pursuit.release(inc, van, "cruise")
							end
						end,
					}, now)
				else
					Pursuit.release(inc, van, "cruise")
				end
			end
		elseif e.role ~= "DEPLOY" then
			Pursuit.release(inc, van, "cruise")
		end
	end
end

function Pursuit.update(inc: any, now: number)
	-- prune cars that died / were taken for prisoner transport
	for van, e in inc.cars do
		if van.dead or van.transporting or not van.body or not van.body.Parent then
			if e.op then
				Roadside.cancel(e.op, "unit lost")
			end
			inc.cars[van] = nil
			claimed[van] = nil
			if inc.primary == van then
				inc.primary = nil
				Log.event("PRIMARY LOST", "#%d %s out of the pursuit", inc.id, carName(van))
			end
			if inc.secondary == van then
				inc.secondary = nil
			end
		end
	end
	local mode = inc.mode
	if mode == "VEHICLE" then
		vehicleMode(inc, now)
	elseif mode == "SEARCH" and inc.knowledge.inVehicle then
		carSearch(inc, now)
	elseif next(inc.cars) ~= nil then
		wrapUp(inc, now)
	else
		tagCar(inc, nil)
	end
	Roadside.step(inc, now)
end

-- Cruising patrol cars notice wanted drivers (forward-ish, line of sight).
function Pursuit.scanPatrols(now: number)
	local range = Tuning.Perception.PatrolCarDetect
	for van in Van.all do
		if van.mode ~= "patrol" or van.dead or claimed[van] or not van.body then
			continue
		end
		for inc in Ctx.Incidents.each() do
			local k = inc.knowledge
			local rel = flat(k.pos - van.body.Position)
			if rel.Magnitude < range and rel.Magnitude > 1 then
				local look = flat(van.body.CFrame.LookVector)
				if look.Magnitude > 0.1 and look.Unit:Dot(rel.Unit) > -0.2 and Perception.cruiser(van, inc, now, range) then
					if inc.mode == "VEHICLE" and Pursuit.total() < Tuning.Vehicles.MaxPursuitCars and claimable(van, inc) then
						Pursuit.claim(inc, van, "spotted the suspect")
					elseif inc.mode ~= "VEHICLE" and inc.mode ~= "CRITICAL" and inc.mode ~= "CUSTODY" then
						-- v191: a cruiser driving past a wanted suspect on foot stops
						-- and deploys (Dispatcher sends this car first).
						local pr = inc.pursuit
						if pr and (not pr.spottedAt or now - pr.spottedAt > 6 or pr.spottedBy ~= van) then
							pr.spottedBy, pr.spottedAt = van, now
							Log.event("PATROL CAR SPOTTED", "#%d suspect on foot %.0f studs away", inc.id, rel.Magnitude)
						end
					end
					break
				end
			end
		end
	end
end

-- A legacy responder arrived to find the suspect driving: hand it to the pursuit.
function Pursuit.offer(inc: any, van: any): boolean
	if claimed[van] or van.dead or van.transporting then
		return false
	end
	if van.crewOut > 0 or van.crewTotal <= 0 then
		return false
	end
	if Pursuit.total() >= Tuning.Vehicles.MaxPursuitCars then
		return false
	end
	Pursuit.claim(inc, van, "responder redirected")
	return true
end

function Pursuit.closeIncident(inc: any)
	tagCar(inc, nil)
	Roadside.cancelAll(inc, "incident closed")
	for van, e in inc.cars do
		if e.deployed and van.crewOut > 0 then
			Pursuit.release(inc, van, "keep")
		else
			Pursuit.release(inc, van, "cruise")
		end
	end
	inc.primary, inc.secondary = nil, nil
end

return Pursuit
