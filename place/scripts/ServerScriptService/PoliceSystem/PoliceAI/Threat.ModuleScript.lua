--[[
	PoliceAI · Threat
	Shared threat assessment per incident (computed ~2x a second, not per officer).
	Armed / aiming are only updated while someone can actually see the suspect;
	otherwise the last known picture is kept for a while.

	LOW       unarmed, not fighting
	ELEVATED  fleeing / resisting / hostile but unarmed
	HIGH      armed, fired recently, aiming at officers or assaulted an officer
	LETHAL    HIGH and the department has authorized lethal force (existing 5-star policy)
]]

local Threat = {}
local Ctx, Tuning, Log, Util, State

function Threat.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, State = ctx.Tuning, ctx.Log, ctx.Util, ctx.State
end

function Threat.new(): any
	return {
		level = "LOW",
		armed = false,
		armedSeen = -math.huge,
		fired = false,
		aiming = false,
		aimAt = nil,
		fleeing = false,
		assaultAt = -math.huge,
	}
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function Threat.update(inc: any, now: number)
	local t = inc.threat
	local T = Tuning.Threat
	local p = inc.pursuit
	local k = inc.knowledge
	local player = inc.player
	local char, hum, root = Util.charInfo(player)
	local eyes = Ctx.Knowledge.hasEyes(inc)

	if char and hum and root and eyes then
		local armedNow = Util.holdingGun(char)
		t.armed = armedNow
		if armedNow then
			t.armedSeen = now
		end
		t.aiming = false
		t.aimAt = nil
		if armedNow and not hum.SeatPart then
			local look = flat(root.CFrame.LookVector)
			if look.Magnitude > 0.1 then
				look = look.Unit
				for cop in inc.units do
					if cop.alive and cop.root then
						local d = flat(cop.root.Position - root.Position)
						local dist = d.Magnitude
						if dist > 1 and dist < T.AimRange and look:Dot(d.Unit) > T.AimCone then
							t.aiming = true
							t.aimAt = cop
							break
						end
					end
				end
			end
		end
	else
		t.armed = now - t.armedSeen < T.ArmedMemory
		t.aiming = false
		t.aimAt = nil
	end

	local lastFire = State.lastFire[player]
	t.fired = lastFire ~= nil and now - lastFire < T.FireMemory
	if t.fired then
		t.armed = true
		t.armedSeen = math.max(t.armedSeen, lastFire)
	end

	-- fleeing: moving fast and away from the nearest officer / cruiser
	local speed = flat(k.vel).Magnitude
	t.fleeing = false
	if speed > T.FleeSpeed and Ctx.Knowledge.fresh(inc) then
		local nearest, nd = nil, math.huge
		for cop in inc.units do
			if cop.alive and cop.root then
				local d = (cop.root.Position - k.pos).Magnitude
				if d < nd then
					nd, nearest = d, cop.root.Position
				end
			end
		end
		for van in inc.cars do
			if not van.dead and van.body then
				local d = (van.body.Position - k.pos).Magnitude
				if d < nd then
					nd, nearest = d, van.body.Position
				end
			end
		end
		if nearest then
			local away = flat(k.pos - nearest)
			t.fleeing = away.Magnitude < 1 or flat(k.vel).Unit:Dot(away.Unit) > -0.2
		else
			t.fleeing = true
		end
	end

	local assaultive = now - t.assaultAt < T.AssaultMemory
	local level
	if p.lethal == true and (t.armed or t.fired or assaultive) then
		level = "LETHAL"
	elseif t.armed or t.fired or t.aiming or assaultive then
		level = "HIGH"
	elseif t.fleeing or p.hostile or (p.stars or 0) >= 2 then
		level = "ELEVATED"
	else
		level = "LOW"
	end
	if level ~= t.level then
		local why = if t.aiming then "aiming at officers" elseif t.fired then "shots fired" elseif t.armed then "armed" elseif assaultive then "assaulted officer" elseif t.fleeing then "fleeing" else "calm"
		Log.event("THREAT", "#%d %s -> %s (%s)", inc.id, t.level, level, why)
		t.level = level
	end
end

function Threat.noteCrime(inc: any, crimeName: string)
	if crimeName == "AssaultOfficer" or crimeName == "CopKilled" or crimeName == "HelicopterDown" then
		inc.threat.assaultAt = os.clock()
	end
end

-- Is this a suspect officers should treat as dangerous (cautious approach, cover, spacing)?
function Threat.dangerous(inc: any): boolean
	local lv = inc.threat.level
	return lv == "HIGH" or lv == "LETHAL"
end

return Threat
