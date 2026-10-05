--[[
	PoliceAI  (tactical police brain for PoliceSystem)

	Started by the PoliceSystem script after its own modules boot:
	    require(script.PoliceAI).start(__require)
	If anything here fails to load, PoliceSystem keeps running its legacy behaviour.

	Architecture (each is a child ModuleScript):
	  Tuning      every number
	  Log         [PoliceAI] transition logging (no per-frame spam)
	  Incidents   IncidentManager - one shared incident per wanted suspect
	  Knowledge   what police KNOW (sources, confidence, prediction, LOST)
	  Perception  cached / LOD line-of-sight checks for officers and cruisers
	  Threat      shared threat assessment (armed, firing, aiming, fleeing)
	  Arrest      compliance states + the single arrest owner + less-lethal lock
	  Tactics     foot roles and positions (contact / cover / perimeter / intercept...)
	  Search      search plans when contact is lost
	  Brain       per-officer decisions (called from CopAI)
	  Voice       officer commands
	  Parking     cruiser stop-slot reservation
	  Pursuit     vehicle pursuit coordination (primary / secondary / intercept ...)
	  Driver      pursuit driving on the mapped roads / the suspect's observed trail
	  Roadside    spike strips + roadblocks

	Existing systems it hands off to (unchanged): Heat.bust -> Justice.jail (booking,
	transport, intake, housing), State.criticalHook -> Justice.medicalCustody (EMS).
]]

local RunService = game:GetService("RunService")

local PoliceAI = {}
PoliceAI.started = false

local CHILDREN = {
	"Tuning", "Log", "Knowledge", "Threat", "Perception", "Parking", "Voice", "Tactics",
	"Arrest", "Search", "Driver", "Roadside", "Pursuit", "Incidents", "Brain",
}
local LEGACY = { "Config", "State", "Util", "Heat", "CopAI", "Van", "RoadGraph", "Weapons", "Units", "Dispatcher" }

function PoliceAI.start(req: (string) -> any): any?
	if PoliceAI.started then
		return PoliceAI.ctx
	end
	local ctx: any = { req = req }
	for _, name in LEGACY do
		ctx[name] = req(name)
	end
	for _, name in CHILDREN do
		local m = script:FindFirstChild(name)
		if not m then
			error("PoliceAI." .. name .. " ModuleScript is missing")
		end
		ctx[name] = require(m)
	end
	for _, name in CHILDREN do
		local m = ctx[name]
		if type(m) == "table" and m.bind then
			m.bind(ctx)
		end
	end
	local Tuning, Log = ctx.Tuning, ctx.Log
	if not Tuning.Enabled then
		warn("[PoliceAI] tactical AI disabled in PoliceAI.Tuning - legacy police behaviour active")
		return nil
	end
	local Heat, State = ctx.Heat, ctx.State
	local Incidents = ctx.Incidents

	-- knowledge instead of distance
	Heat.sightingHook = function(player: Player, p: any, pos: Vector3, source: string, observer: any?): boolean
		local ok, r = pcall(ctx.Knowledge.heatSighting, player, p, pos, source, observer)
		if not ok then
			Log.warn("sighting", r)
			return false
		end
		return r
	end
	Heat.evadeHook = function(player: Player, p: any, dt: number, now: number): string?
		local ok, r = pcall(ctx.Knowledge.heatEvade, player, p, dt, now)
		if not ok then
			Log.warn("evade", r)
			return nil
		end
		return r
	end
	Heat.onCleared(function(player: Player, p: any, reason: string)
		local inc = Incidents.get(player)
		if inc and inc.pursuit == p then
			Incidents.close(inc, reason)
		end
	end)
	Heat.onCrime(function(player: Player, crimeName: string)
		local inc = Incidents.get(player)
		if inc then
			ctx.Threat.noteCrime(inc, crimeName)
		end
	end)

	State.ai = {
		think = ctx.Brain.think,
		knownPos = function(p: any): Vector3?
			local inc = Incidents.forPursuit(p)
			return if inc then inc.knowledge.pos else p.lastSeenPos
		end,
		vehicleMode = function(p: any): boolean
			local inc = Incidents.forPursuit(p)
			return inc ~= nil and inc.mode == "VEHICLE"
		end,
		ownsVehicles = true,
		parkingPoint = function(p: any, key: any): Vector3?
			local inc = Incidents.forPursuit(p) or (p.active and Incidents.ensure(p))
			if not inc then
				return nil
			end
			local pos = ctx.Parking.reserve(inc, key, inc.knowledge.pos, {})
			return pos
		end,
		releaseParking = function(key: any)
			ctx.Parking.release(key)
		end,
		offerCar = function(p: any, van: any): boolean
			local inc = Incidents.forPursuit(p)
			if inc and inc.mode == "VEHICLE" then
				return ctx.Pursuit.offer(inc, van)
			end
			return false
		end,
		isClaimed = function(van: any): boolean
			return ctx.Pursuit.isClaimed(van)
		end,
	}

	local accum = 0
	local lastGlobal = 0
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < Tuning.Tick then
			return
		end
		local stepDt = accum
		accum = 0
		local now = os.clock()
		local ok, err = pcall(Incidents.step, stepDt, now)
		if not ok then
			Log.warn("incident step", err)
		end
		if now - lastGlobal >= 1 then
			lastGlobal = now
			pcall(ctx.Parking.sweep)
			local ok2, err2 = pcall(ctx.Pursuit.scanPatrols, now)
			if not ok2 then
				Log.warn("patrol scan", err2)
			end
		end
	end)

	PoliceAI.started = true
	PoliceAI.ctx = ctx
	Log.event("READY", "tactical police AI online (%d modules)", #CHILDREN)
	return ctx
end

return PoliceAI
