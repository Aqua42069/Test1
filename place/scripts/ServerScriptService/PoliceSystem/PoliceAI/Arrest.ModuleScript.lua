--[[
	PoliceAI · Arrest
	Compliance states and single arrest ownership.

	  Noncompliant  default: fleeing, armed, fighting, ignoring commands
	  Complying     hands up (H), or stood still, unarmed, after an officer's command
	  Controlled    stunned (taser / beanbag / gas) or complying with the arrest officer hands-on
	  Cuffed        custody has them (existing Justice pipeline)
	  Critical      police-caused critical injury (existing medical custody pipeline)

	Only ONE officer - the arrest owner - may go hands-on and tick Heat.arrestTick.
	Everyone else covers. Ownership transfers if the owner dies, leaves, gets stuck or
	falls too far behind.
]]

local Arrest = {}
local Ctx, Tuning, Log, Util, Knowledge, Config

function Arrest.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, Knowledge, Config = ctx.Tuning, ctx.Log, ctx.Util, ctx.Knowledge, ctx.Config
end

---------------------------------------------------------------------------
-- v116: pulling a suspect out of a stopped vehicle
---------------------------------------------------------------------------
function Arrest.doorPoint(inc: any): (Vector3?, BasePart?)
	local _, hum = Util.charInfo(inc.player)
	local seat = hum and hum.SeatPart
	if not seat then
		return nil, nil
	end
	if Util.vehicleDoorPoint then
		return Util.vehicleDoorPoint(seat), seat
	end
	local r = seat.CFrame.RightVector
	return seat.Position - Vector3.new(r.X, 0, r.Z).Unit * 5, seat
end

function Arrest.extract(cop: any, inc: any): boolean
	local player = inc.player
	local _, hum, root = Util.charInfo(player)
	if not hum or not root or not hum.SeatPart then
		return false
	end
	local E = Tuning.Extraction
	if Util.exitVehicle then
		Util.exitVehicle(hum, E.DownTime + 2)
	else
		local weld = hum.SeatPart:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		hum.Sit = false
	end
	Ctx.Heat.stun(player, E.DownTime)
	inc.stunExploitUntil = os.clock() + E.DownTime + 1
	Knowledge.observe(inc, "VISUAL", root.Position, Vector3.zero, cop, nil)
	Ctx.Voice.say(cop, "Out of the car! On the ground!", inc, { force = true, announce = true, style = "danger" })
	Log.event("SUSPECT EXTRACTED", "#%d %s pulled out of the vehicle by %s", inc.id, player.Name, cop.model and cop.model.Name or "officer")
	return true
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function nearestUnitDistance(inc: any, pos: Vector3): number
	local best = math.huge
	for cop in inc.units do
		if cop.alive and cop.root then
			best = math.min(best, flat(cop.root.Position - pos).Magnitude)
		end
	end
	return best
end

function Arrest.updateCompliance(inc: any, now: number)
	local C = Tuning.Compliance
	local p = inc.pursuit
	local player = inc.player
	local char, hum, root = Util.charInfo(player)
	local c = inc.comply
	local state = inc.compliance

	if player:GetAttribute("PoliceCritical") == true then
		state = "Critical"
	elseif hum and hum:GetAttribute("PoliceCuffed") == true then
		state = "Cuffed"
	elseif char and hum and root then
		local stunned = p.stunnedUntil ~= nil and now < p.stunnedUntil
		local surrendered = p.surrendered == true
		local eyes = inc.knowledge.level == Knowledge.L.DIRECT
		local speed = flat(root.AssemblyLinearVelocity).Magnitude
		local inCar = hum.SeatPart ~= nil
		local armedNow = Util.holdingGun(char)
		local t = inc.threat
		local fighting = t.fired or now - t.assaultAt < 6
		if speed < C.StillSpeed and not inCar then
			c.stillSince = c.stillSince or now
		else
			c.stillSince = nil
		end
		local commanded = inc.lastCommandAt ~= nil and now - inc.lastCommandAt <= 12 and inc.firstCommandAt ~= nil and now - inc.firstCommandAt >= C.CommandLead
		local close = nearestUnitDistance(inc, root.Position) <= C.MaxCommandDistance
		local passive = eyes and commanded and close and c.stillSince ~= nil and now - c.stillSince >= C.StillTime and not armedNow and not fighting and not inCar

		local owner = inc.arrestOwner
		local handsOn = owner ~= nil and owner.alive and owner.root ~= nil and flat(owner.root.Position - root.Position).Magnitude <= Config.Arrest.Range + 1.5

		-- v137: once force has actually controlled the suspect, give the arrest owner
		-- a protected cuffing window.  The old code immediately re-read the recent
		-- assault timer and flipped Controlled -> Noncompliant every 1-2 seconds.
		local controlLocked = state == "Controlled" and c.controlledUntil ~= nil and now < c.controlledUntil
		if stunned then
			state = "Controlled"
			c.controlledUntil = math.max(c.controlledUntil or 0, now + 10)
		elseif controlLocked and not inCar then
			-- v155: a stun/tackle control lock is authoritative. Merely still having a gun
			-- equipped must not flip the suspect back to Noncompliant while an officer is
			-- physically subduing them.
			state = "Controlled"
		elseif surrendered then
			state = if handsOn then "Controlled" else "Complying"
		elseif (state == "Complying" or state == "Controlled") and c.anchor then
			-- keep complying unless they move off, arm up, get in a car or fight
			local moved = flat(root.Position - c.anchor).Magnitude > C.BreakDistance
			if moved or armedNow or inCar or fighting then
				state = "Noncompliant"
			else
				state = if handsOn then "Controlled" else "Complying"
			end
		elseif passive then
			state = "Complying"
		else
			state = "Noncompliant"
		end
		if state == "Complying" and inc.compliance ~= "Complying" and inc.compliance ~= "Controlled" then
			c.anchor = root.Position
		elseif state == "Noncompliant" then
			c.anchor = nil
		end
	end

	if state ~= inc.compliance then
		local old = inc.compliance
		inc.compliance = state
		inc.complianceSince = now
		if state == "Complying" then
			Log.event("SUSPECT COMPLYING", "#%d %s%s", inc.id, player.Name, if p.surrendered then " (hands up)" else " (stopped on command)")
		elseif state == "Controlled" then
			c.controlledUntil = math.max(c.controlledUntil or 0, now + 10)
			Log.event("SUSPECT CONTROLLED", "#%d %s - cuff window locked", inc.id, if p.stunnedUntil and now < p.stunnedUntil then "stunned" else "hands-on")
		elseif state == "Critical" then
			Log.event("SUSPECT CRITICAL", "#%d all force stopped - medical custody", inc.id)
		elseif state == "Cuffed" then
			Log.event("SUSPECT CUFFED", "#%d", inc.id)
		elseif state == "Noncompliant" and (old == "Complying" or old == "Controlled") then
			Log.event("COMPLIANCE BROKEN", "#%d %s", inc.id, player.Name)
		end
	end
	-- Everything that can hurt the suspect checks this (CopAI shots, helicopter gunner).
	p.holdFire = state ~= "Noncompliant"
	p.complying = state == "Complying" or state == "Controlled"
end

local function canOwn(cop: any, inc: any): boolean
	return cop.alive and cop.active and cop.root ~= nil and cop.pursuit == inc.pursuit and cop.state ~= "leave" and not cop.aiScripted
end

-- Who goes hands-on? Only needed when an arrest is actually possible.
function Arrest.updateOwner(inc: any, now: number)
	local A = Tuning.Arrest
	local k = inc.knowledge
	local comp = inc.compliance
	local lv = inc.threat.level
	local stoppedCar = Tuning.Extraction.Enabled and k.inVehicle and k.stoppedSince ~= nil and now - k.stoppedSince >= Tuning.Extraction.StopTime
	local need = comp == "Complying" or comp == "Controlled" or stoppedCar
		or (comp == "Noncompliant" and (lv == "LOW" or lv == "ELEVATED") and not k.inVehicle and Knowledge.fresh(inc))
	if comp == "Critical" or comp == "Cuffed" then
		need = false
	end
	local owner = inc.arrestOwner
	if not need then
		if owner then
			inc.arrestOwner = nil
			if owner.model and owner.model.Parent then
				owner.model:SetAttribute("ArrestOwner", nil)
			end
		end
		return
	end

	local target = k.pos
	local valid = owner ~= nil and canOwn(owner, inc) and flat(owner.root.Position - target).Magnitude <= A.OwnerMaxDistance
	if valid and inc.tackle and inc.tackle.cop == owner and now < (inc.tackle.untilT or 0) then
		return -- committed hands-on tackle/cuff; do not transfer ownership mid-contact
	end
	if valid then
		-- stuck / no progress toward the suspect -> hand over
		local d = flat(owner.root.Position - target).Magnitude
		local track = inc.ownerTrack
		if not track or track.owner ~= owner then
			inc.ownerTrack = { owner = owner, best = d, at = now }
		elseif d < track.best - 2 or d <= Config.Arrest.Range + 1 then
			track.best = math.min(track.best, d)
			track.at = now
		elseif now - track.at > A.OwnerStuckTime then
			valid = false
			Log.event("ARREST OWNER STUCK", "#%d transferring", inc.id)
		end
	end
	if valid then
		return
	end

	-- v191: the current owner stays a candidate unless he is stuck. Before, a
	-- replacement could be picked from any distance while the owner was dropped
	-- for being >OwnerMaxDistance away, so two far officers swapped ownership
	-- every tick ("ARREST OWNER TRANSFER" 170 / 306 / 170 ...).
	local ownerStuck = owner ~= nil and inc.ownerTrack ~= nil and inc.ownerTrack.owner == owner and now - inc.ownerTrack.at > A.OwnerStuckTime
	local best, bestD = nil, math.huge
	for cop in inc.units do
		if (cop ~= owner or not ownerStuck) and canOwn(cop, inc) and not cop.marksman then
			local d = flat(cop.root.Position - target).Magnitude
			-- prefer an officer who can actually see the suspect
			if Ctx.Perception.sawRecently(cop, inc, now, 1.5) then
				d *= 0.75
			end
			if cop.shield then
				d *= 1.6 -- shield officers lead, they don't cuff unless nobody else can
			end
			if d < bestD then
				best, bestD = cop, d
			end
		end
	end
	if best ~= nil and best == owner then
		return -- still the best placed officer: keep him, keep his progress track
	end
	if owner and owner.model and owner.model.Parent then
		owner.model:SetAttribute("ArrestOwner", nil)
	end
	inc.arrestOwner = best
	inc.ownerTrack = nil
	if best then
		if best.model then
			best.model:SetAttribute("ArrestOwner", true)
		end
		Log.event(if owner then "ARREST OWNER TRANSFER" else "ARREST OWNER", "#%d %s (%.0f studs)", inc.id, best.model and best.model.Name or "officer", bestD)
	end
end

function Arrest.isOwner(cop: any, inc: any): boolean
	return inc.arrestOwner == cop
end

-- v151: after a real less-lethal stun, the arrest owner commits instead of
-- hovering at cuff range. He sprints the last few studs, physically knocks the
-- suspect into the reversible ragdoll, then stays hands-on while cuffs go on.
-- Only the single arrest owner can do this; the rest of the squad remains cover.
function Arrest.tackle(cop: any, inc: any, now: number): boolean
	if inc.arrestOwner ~= cop or not cop.alive or not cop.root then return false end
	local p = inc.pursuit
	local stunWindow = if p then math.max(p.stunnedUntil or 0, inc.stunExploitUntil or 0) else 0
	if not p or now >= stunWindow then return false end
	local player = inc.player
	local char, hum, root = Util.charInfo(player)
	if not char or not hum or not root or hum.Health <= 0 or hum.SeatPart then return false end
	if hum:GetAttribute("PoliceCuffed") then return false end

	local active = inc.tackle
	if active and active.cop == cop and now < (active.untilT or 0) then
		Ctx.Heat.arrestTick(player, cop.homeCar)
		return true
	end
	if active and active.doneForStun and active.doneForStun >= (p.stunnedUntil - 0.05) then
		return false
	end

	local delta = flat(root.Position - cop.root.Position)
	local d = delta.Magnitude
	if d > 45 then return false end
	if d > 6.5 then
		cop:setGunOut(false)
		cop:unface()
		cop:moveTo(root.Position, true)
		return true
	end

	local dir = if d > 0.1 then delta.Unit else flat(cop.root.CFrame.LookVector).Unit
	local downFor = math.clamp(math.max(1.45, p.stunnedUntil - now + 0.35), 1.45, 2.4)
	inc.tackle = { cop = cop, at = now, untilT = now + downFor, doneForStun = p.stunnedUntil }
	if inc.comply then
		inc.comply.controlledUntil = math.max(inc.comply.controlledUntil or 0, now + downFor + 2)
	end
	player:SetAttribute("PoliceTackleCuff", true)
	char:SetAttribute("PoliceTackleSubdued", true)
	hum:UnequipTools()

	-- The officer actually lunges into the contact instead of stopping beside the
	-- player. The player's knock is modest so the pair stay together for cuffing.
	pcall(function() cop.root:ApplyImpulse((dir * 16 + Vector3.new(0, 1.5, 0)) * cop.root.AssemblyMass) end)
	Util.temporaryRagdoll(char, downFor, dir * 11 + Vector3.new(0, 1.2, 0))
	Ctx.Heat.arrestTick(player, cop.homeCar)
	Log.event("ARREST TACKLE", "#%d %s tackled by %s - ground cuff", inc.id, player.Name, cop.model and cop.model.Name or "officer")

	task.delay(downFor + 0.4, function()
		if player.Parent then player:SetAttribute("PoliceTackleCuff", nil) end
		if char.Parent then char:SetAttribute("PoliceTackleSubdued", nil) end
	end)
	return true
end

-- Called by the owner only, when in cuffing range.
function Arrest.tick(cop: any, inc: any)
	if inc.arrestOwner ~= cop or not Ctx.Tactics.canArrest(inc,cop,os.clock()) then
		return
	end
	-- Keep hands-on control sticky while the owner is actively cuffing.
	if inc.comply then
		inc.comply.controlledUntil = math.max(inc.comply.controlledUntil or 0, os.clock() + 4)
	end
	Ctx.Heat.arrestTick(inc.player, cop.homeCar)
end

-- Less-lethal lock: one taser / beanbag deployment at a time per incident.
function Arrest.takeLessLethalLock(cop: any, inc: any, now: number): boolean
	local lock = inc.lessLethalLock
	if lock and lock.cop ~= cop and now < lock.untilT and lock.cop.alive then
		return false
	end
	inc.lessLethalLock = { cop = cop, untilT = now + 0.8 }
	return true
end

function Arrest.onStun(inc: any, cop: any, secs: number)
	local now = os.clock()
	-- v155: a real less-lethal hit creates a decisive arrest window. Disarm the
	-- character animation/tool state and keep control sticky while the nearest
	-- arrest owner closes the final distance.
	inc.stunExploitUntil = now + secs + math.max(Tuning.LessLethal.ExploitWindow, 2.5)
	inc.comply = inc.comply or {}
	inc.comply.controlledUntil = math.max(inc.comply.controlledUntil or 0, now + secs + 8)
	local char, hum = Util.charInfo(inc.player)
	if hum then pcall(function() hum:UnequipTools() end) end
	Log.event("SUSPECT STUNNED", "#%d by %s - decisive arrest window", inc.id, cop.model and cop.model.Name or "officer")
end

return Arrest
