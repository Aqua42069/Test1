--[[
	PoliceAI · Search
	When the police lose contact they search where the suspect most likely went, not where
	he actually is. A search plan is built from the last observation + travel direction:
	points along the running direction weigh most, then the surroundings, then roads ahead
	(for a vehicle) and around an abandoned car. Officers claim points, go there, look
	around, and move on. Anyone who regains line of sight reports it and the plan is dropped.
]]

local Search = {}
local Ctx, Tuning, Log, Util, RoadGraph, Knowledge

function Search.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, RoadGraph, Knowledge = ctx.Tuning, ctx.Log, ctx.Util, ctx.RoadGraph, ctx.Knowledge
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function build(inc: any, now: number): any
	local S = Tuning.Search
	local k = inc.knowledge
	local stars = math.clamp(inc.pursuit.stars or 1, 1, 5)
	local radius = S.Radius[stars] or 100
	local center = k.pos
	local heading = flat(k.vel)
	local hasHeading = heading.Magnitude > 2
	local ha = if hasHeading then math.atan2(heading.Z, heading.X) else 0
	local pts = {}
	local function add(pos: Vector3?, score: number, road: boolean?)
		if not pos then
			return
		end
		for _, q in pts do
			if (q.pos - pos).Magnitude < 14 then
				return
			end
		end
		table.insert(pts, { pos = pos, score = score, road = road == true, taken = nil, done = false })
	end
	add(Util.groundAt(center, 12, 40), 1.0)
	-- abandoned car: search around it first
	local ab = k.abandoned
	if ab and now - ab.t < 90 then
		for i = 0, 3 do
			local a = i / 4 * math.pi * 2
			add(Util.groundAt(ab.pos + Vector3.new(math.cos(a), 0, math.sin(a)) * 22, 12, 40), 0.95)
		end
	end
	for i = 1, S.Points do
		local a, r, score
		if hasHeading and i <= math.ceil(S.Points * 0.6) then
			-- cone along the direction of travel
			a = ha + (math.random() * 2 - 1) * math.rad(70)
			r = radius * (0.3 + math.random() * 0.7)
			score = 0.9 - math.abs(a - ha) / math.pi * 0.4
		else
			a = math.random() * math.pi * 2
			r = radius * (0.25 + math.random() * 0.75)
			score = 0.45
		end
		add(Util.groundAt(center + Vector3.new(math.cos(a), 0, math.sin(a)) * r, 14, 50), score - r / radius * 0.2)
	end
	-- vehicles: likely roads ahead
	if k.inVehicle and RoadGraph.ready and RoadGraph.predict and hasHeading then
		local path = RoadGraph.predict(k.obsPos, heading, radius * 3)
		if path then
			local step = math.max(1, math.floor(#path / 4))
			for i = step, #path, step do
				add(path[i], 0.85, true)
			end
		end
		if RoadGraph.nodesNear then
			for _, id in RoadGraph.nodesNear(center, radius) do
				add(RoadGraph.nodePos(id), 0.4, true)
				if #pts > S.Points + 10 then
					break
				end
			end
		end
	end
	table.sort(pts, function(a, b)
		return a.score > b.score
	end)
	return { points = pts, center = center, anchorT = k.t, created = now }
end

function Search.update(inc: any, now: number)
	if inc.mode ~= "SEARCH" then
		inc.search = nil
		return
	end
	local k = inc.knowledge
	local plan = inc.search
	local remaining = 0
	if plan then
		for _, pt in plan.points do
			if not pt.done then
				remaining += 1
			end
		end
	end
	if not plan or plan.anchorT ~= k.t or remaining == 0 or now - plan.created > Tuning.Search.ReplanAfter then
		inc.search = build(inc, now)
		Log.event(if plan then "SEARCH REPLAN" else "SEARCH PLAN", "#%d %d points (confidence %.2f)", inc.id, #inc.search.points, k.conf)
	end
end

local function claimPoint(plan: any, cop: any, road: boolean?): any
	local best, bestScore = nil, -math.huge
	local from = if cop.root then cop.root.Position elseif cop.body then cop.body.Position else plan.center
	for _, pt in plan.points do
		if not pt.done and (pt.taken == nil or pt.taken == cop or (typeof(pt.taken) == "table" and (pt.taken.alive == false or pt.taken.dead == true))) then
			if road == nil or pt.road == road or not road then
				local score = pt.score * 100 - (pt.pos - from).Magnitude * 0.25
				if score > bestScore then
					best, bestScore = pt, score
				end
			end
		end
	end
	if best then
		best.taken = cop
	end
	return best
end

-- Foot officers: most search, a couple hold the likely exits.
function Search.assign(inc: any, units: { any }, now: number, setRole: (any, any, string, Vector3?, number) -> ())
	local plan = inc.search
	if not plan then
		for _, c in units do
			setRole(inc, c, "SEARCH", inc.knowledge.pos, now)
		end
		return
	end
	local watchers = if #units >= 4 then 1 else 0
	for i, c in units do
		local entry = inc.units[c]
		if i <= watchers then
			-- hold the most likely escape point and watch
			local pt = plan.points[math.min(2, #plan.points)]
			setRole(inc, c, "PERIMETER", pt and pt.pos or plan.center, now)
		else
			local current = entry and entry.searchPoint
			if not current or current.done then
				current = claimPoint(plan, c)
			end
			setRole(inc, c, "SEARCH", current and current.pos or plan.center, now)
			inc.units[c].searchPoint = current
		end
	end
end

-- An officer reached his point and looked around.
function Search.complete(inc: any, cop: any)
	local entry = inc.units[cop]
	local pt = entry and entry.searchPoint
	if pt then
		pt.done = true
		entry.searchPoint = nil
		local plan = inc.search
		if plan then
			local nextPt = claimPoint(plan, cop)
			if nextPt then
				entry.searchPoint = nextPt
				entry.slot = nextPt.pos
			end
		end
	end
end

-- Cruisers searching for a lost car: next road point.
function Search.carPoint(inc: any, van: any): Vector3?
	local plan = inc.search
	if not plan then
		return nil
	end
	local pt = claimPoint(plan, van, true) or claimPoint(plan, van)
	return pt and pt.pos or nil
end

function Search.carDone(inc: any, van: any)
	local plan = inc.search
	if not plan then
		return
	end
	for _, pt in plan.points do
		if pt.taken == van and not pt.done then
			pt.done = true
		end
	end
end

return Search
