--[[
	PoliceAI · Incidents  (IncidentManager)
	One incident per wanted suspect (per Heat pursuit), shared by every responding unit:

	  perception -> knowledge -> threat -> compliance / arrest ownership -> mode
	             -> unit roles + positions (Tactics / Search) -> vehicle pursuit (Pursuit)
	             -> custody hand-off to the existing Justice / EMS pipelines

	Each subsystem runs protected: one failing (a bad route, a missing part) is logged and
	skipped for that tick, the rest of the incident keeps working.

	Modes: FOOT, VEHICLE, SEARCH, CUSTODY (complying/controlled), CRITICAL
]]

local Incidents = {}
local Ctx, Tuning, Log, Util, Heat, Knowledge, Threat, Arrest, Tactics, Search, Pursuit, Parking

local byPlayer: { [Player]: any } = {}
local serial = 0

function Incidents.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, Heat = ctx.Tuning, ctx.Log, ctx.Util, ctx.Heat
	Knowledge, Threat, Arrest, Tactics = ctx.Knowledge, ctx.Threat, ctx.Arrest, ctx.Tactics
	Search, Pursuit, Parking = ctx.Search, ctx.Pursuit, ctx.Parking
end

local function run(inc: any, label: string, fn: (...any) -> (), ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		Log.warn(string.format("incident #%d %s", inc.id, label), err)
	end
end

function Incidents.get(player: Player): any?
	return byPlayer[player]
end

function Incidents.forPursuit(p: any): any?
	if not p or not p.player then
		return nil
	end
	local inc = byPlayer[p.player]
	if inc and inc.pursuit == p then
		return inc
	end
	return nil
end

function Incidents.each(): () -> any?
	local list = {}
	for _, inc in byPlayer do
		table.insert(list, inc)
	end
	local i = 0
	return function()
		i += 1
		return list[i]
	end
end

function Incidents.ensure(p: any): any?
	local player = p.player
	if not player or not p.active then
		return nil
	end
	local inc = byPlayer[player]
	if inc and inc.pursuit == p then
		return inc
	end
	if inc then
		Incidents.close(inc, "replaced")
	end
	if not p.lastSeenPos then
		-- dispatch always gets at least the reported location
		local _, _, root = Util.charInfo(player)
		p.lastSeenPos = if root then root.Position else Vector3.zero
	end
	serial += 1
	local now = os.clock()
	inc = {
		id = serial,
		player = player,
		pursuit = p,
		created = now,
		knowledge = Knowledge.new(p),
		threat = Threat.new(),
		compliance = "Noncompliant",
		complianceSince = now,
		comply = {},
		units = {},
		cars = {},
		roadside = {},
		mode = "FOOT",
		roleAt = 0,
		threatAt = 0,
		ownerAt = 0,
		searchAt = 0,
		attrAt = 0,
	}
	byPlayer[player] = inc
	player:SetAttribute("PoliceIncidentId", serial)
	Log.event("INCIDENT CREATED", "#%d %s %d star(s)", serial, player.Name, p.stars or 0)
	return inc
end

local function computeMode(inc: any): string
	local comp = inc.compliance
	if comp == "Critical" then
		return "CRITICAL"
	end
	if comp == "Complying" or comp == "Controlled" or comp == "Cuffed" then
		return "CUSTODY"
	end
	local k = inc.knowledge
	local rank = Knowledge.rank[k.level]
	local L = Knowledge.L
	if k.inVehicle then
		if rank <= Knowledge.rank[L.PREDICTED] then
			return "VEHICLE"
		end
		return "SEARCH"
	end
	if rank <= Knowledge.rank[L.RECENT] then
		return "FOOT"
	end
	return "SEARCH"
end

local function mirror(inc: any, now: number)
	if not Tuning.DebugAttributes or now < inc.attrAt then
		return
	end
	inc.attrAt = now + 1
	local player = inc.player
	if not player.Parent then
		return
	end
	player:SetAttribute("PoliceKnowledge", inc.knowledge.level)
	player:SetAttribute("PoliceConfidence", math.floor(inc.knowledge.conf * 100 + 0.5) / 100)
	player:SetAttribute("PoliceThreat", inc.threat.level)
	player:SetAttribute("PoliceCompliance", inc.compliance)
	player:SetAttribute("PoliceIncidentMode", inc.mode)
end

local function stepIncident(inc: any, dt: number, now: number)
	run(inc, "knowledge", Knowledge.update, inc, dt, now)
	run(inc, "compliance", Arrest.updateCompliance, inc, now)
	if now >= inc.threatAt then
		inc.threatAt = now + 0.4
		run(inc, "threat", Threat.update, inc, now)
	end

	local mode = computeMode(inc)
	if mode ~= inc.mode then
		local old = inc.mode
		inc.mode = mode
		inc.modeSince = now
		inc.roleAt = 0 -- re-plan roles right away
		if old == "VEHICLE" and mode == "FOOT" then
			Log.event("VEHICLE ABANDONED", "#%d vehicle pursuit -> foot pursuit", inc.id)
		elseif old == "FOOT" and mode == "VEHICLE" then
			Log.event("VEHICLE PURSUIT", "#%d suspect took a vehicle", inc.id)
		else
			Log.event("MODE", "#%d %s -> %s", inc.id, old, mode)
		end
	end

	if now >= inc.roleAt then
		inc.roleAt = now + Tuning.Tactics.RoleRefresh
		inc.ownerAt = now + 0.4
		run(inc, "arrest owner", Arrest.updateOwner, inc, now)
		run(inc, "tactics", Tactics.assign, inc, now)
	elseif now >= inc.ownerAt then
		inc.ownerAt = now + 0.4
		run(inc, "arrest owner", Arrest.updateOwner, inc, now)
	end
	if now >= inc.searchAt then
		inc.searchAt = now + 0.5
		run(inc, "search", Search.update, inc, now)
	end
	run(inc, "pursuit", Pursuit.update, inc, now)
	mirror(inc, now)
end

function Incidents.step(dt: number, now: number)
	for player, p in Heat.pursuits do
		if p.active and player.Parent then
			local inc = Incidents.ensure(p)
			if inc then
				stepIncident(inc, dt, now)
			end
		end
	end
	for player, inc in byPlayer do
		if not inc.pursuit.active or Heat.pursuits[player] ~= inc.pursuit or not player.Parent then
			Incidents.close(inc, "ended")
		end
	end
end

function Incidents.close(inc: any, reason: string)
	if byPlayer[inc.player] == inc then
		byPlayer[inc.player] = nil
	end
	if inc.closed then
		return
	end
	inc.closed = true
	local player = inc.player
	local critical = player:GetAttribute("PoliceCritical") == true or inc.compliance == "Critical"
	run(inc, "close pursuit", Pursuit.closeIncident, inc)
	Parking.releaseIncident(inc)
	for cop in inc.units do
		if cop.model and cop.model.Parent then
			cop.model:SetAttribute("IncidentRole", nil)
			cop.model:SetAttribute("IncidentId", nil)
			cop.model:SetAttribute("ArrestOwner", nil)
		end
		cop.aiFixedRole = nil
		cop.aiHoldPos = nil
		cop.aiFacePos = nil
		cop.aiScripted = nil
	end
	inc.arrestOwner = nil
	if player.Parent then
		for _, name in { "PoliceIncidentId", "PoliceKnowledge", "PoliceConfidence", "PoliceThreat", "PoliceCompliance", "PoliceIncidentMode" } do
			player:SetAttribute(name, nil)
		end
	end
	if reason == "Busted" then
		if critical then
			Log.event("CUSTODY HANDOFF", "#%d %s -> critical medical custody (EMS)", inc.id, player.Name)
		else
			Log.event("CUSTODY HANDOFF", "#%d %s -> arrest / prison transport", inc.id, player.Name)
		end
	end
	Log.event("INCIDENT CLOSED", "#%d %s (%s)", inc.id, player.Name, reason)
end

return Incidents
