--[[
	PoliceAI · Brain  (OfficerBrain)
	Per-officer decisions. CopAI still owns the body (pathfinding, animation, weapons,
	stuck recovery); this module decides WHAT the officer does each think, using:
	  - his own line of sight (Perception, cached with LOD)
	  - the incident's shared knowledge / threat / compliance
	  - the role + position TacticalCoordinator assigned him
	Officers never use the suspect's live position unless they can see him.
]]

local Brain = {}
local Ctx, Tuning, Log, Util, Config, Heat, Weapons
local Knowledge, Perception, Tactics, Arrest, Voice, Search, Threat

function Brain.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, Config, Heat, Weapons = ctx.Tuning, ctx.Log, ctx.Util, ctx.Config, ctx.Heat, ctx.Weapons
	Knowledge, Perception, Tactics, Arrest = ctx.Knowledge, ctx.Perception, ctx.Tactics, ctx.Arrest
	Voice, Search, Threat = ctx.Voice, ctx.Search, ctx.Threat
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function tactical(cop: any): boolean
	local u = cop.unitType
	return u == "Shotgunner" or u == "SWAT" or u == "Riot" or u == "Heavy" or u == "SEAL" or u == "Juggernaut" or u == "Army"
end

---------------------------------------------------------------------------
-- small motor helpers
---------------------------------------------------------------------------
local function goTo(cop: any, pos: Vector3?, run: boolean, faceAt: Vector3?): string
	if not pos then
		cop:stop()
		return "arrived"
	end
	local d = flat(pos - cop.root.Position).Magnitude
	if faceAt and d < 14 then
		cop:face(faceAt)
	else
		cop:unface()
	end
	if d < 2.5 then
		cop:stop()
		if faceAt then
			cop:face(faceAt)
		end
		return "arrived"
	end
	return cop:moveTo(pos, run)
end

local function holdAt(cop: any, faceAt: Vector3?)
	cop:stop()
	if faceAt then
		cop:face(faceAt)
	end
end

local function posture(cop: any, inc: any)
	local comp = inc.compliance
	if comp == "Critical" then
		cop:setGunOut(false)
		return
	end
	local lv = inc.threat.level
	local out = lv == "HIGH" or lv == "LETHAL" or ((inc.pursuit.stars or 0) >= 2 and comp == "Noncompliant")
	cop:setGunOut(out)
end

local function command(cop: any, inc: any, visible: boolean, dist: number, stopped: boolean?)
	if not visible or dist > Tuning.Compliance.MaxCommandDistance then
		return
	end
	local text, style = Voice.commandFor(inc, cop, stopped)
	if text then
		local important = style == "danger" or inc.firstCommandAt == nil
		if Voice.say(cop, text, inc, { announce = important, style = style }) then
			cop.voiceCount = (cop.voiceCount or 0) + 1
		end
	end
end

-- Lethal force: only under the department's lethal authorization, only at a LETHAL threat,
-- never at a complying / controlled / critical suspect, never through another officer.
local function mayShoot(cop: any, inc: any, visible: boolean, targetPos: Vector3): boolean
	if not visible then
		return false
	end
	local p = inc.pursuit
	if inc.compliance~="Noncompliant" or p.surrendered or os.clock()<(p.stunnedUntil or 0) then return false end
	if p.holdFire or p.lethal ~= true or inc.threat.level ~= "LETHAL" then
		return false
	end
	if inc.player:GetAttribute("PoliceCritical") == true then
		return false
	end
	return Tactics.clearShot(cop, inc, cop.head.Position, targetPos)
end

-- Suspect is aiming at this officer, or fired within the self-defence window.
local function selfDefense(cop: any, inc: any, now: number): boolean
	if inc.threat.aimAt == cop then
		return true
	end
	local State = Ctx.State
	local last = State and State.lastFire and State.lastFire[inc.player]
	return last ~= nil and now - last < Tuning.Force.SelfDefenseWindow
end

local function shoot(cop: any, inc: any, visible: boolean, targetPos: Vector3, now: number, moving: boolean?)
	-- The alternating fire window only covers officers holding a slot; one on
	-- the move fires whenever he has a clear lane (still hold-fire aware).
	if mayShoot(cop, inc, visible, targetPos) and (moving or inc.mode~="FOOT" or cop.aiFixedRole or Tactics.fireWindow(cop,inc,now)) then
		cop:face(targetPos)
		cop:tryShoot(inc.player, now)
	end
end

-- Less-lethal is for someone who is running, fighting, armed, or who ignored commands -
-- never the first thing a calm, unarmed suspect gets.
local function lessLethalJustified(inc: any, now: number): boolean
	local t = inc.threat
	if t.fleeing or t.fired or t.armed or now - t.assaultAt < Tuning.Threat.AssaultMemory then
		return true
	end
	return inc.firstCommandAt ~= nil and now - inc.firstCommandAt > 4 and inc.compliance == "Noncompliant"
end

-- Taser / beanbag. Returns true if the officer spent this think deploying it.
local function tryLessLethal(cop: any, inc: any, now: number, visible: boolean, char: Model?, hum: Humanoid?, root: BasePart?): boolean
	if not visible or not char or not hum or not root or hum.SeatPart then
		return false
	end
	if inc.compliance ~= "Noncompliant" then
		return false -- never on a complying / stunned / critical suspect
	end
	if not lessLethalJustified(inc, now) then
		return false
	end
	local p = inc.pursuit
	if p.holdFire or inc.player:GetAttribute("PoliceCritical")==true or hum.Health<=0 or hum:GetAttribute("PoliceCuffed") then return false end
	if now < (p.rubberRecoveryUntil or 0) or (p.stunnedUntil and now < p.stunnedUntil + 1) then
		return false
	end
	if now < (cop.pauseUntil or 0) then
		return false
	end
	local t = inc.threat
	local dist = flat(root.Position - cop.root.Position).Magnitude
	local player = inc.player

 if dist<=10 and now>=(cop.pepperAt or 0) and Tactics.clearShot(cop,inc,cop.head.Position,root.Position) then
  if not Arrest.takeLessLethalLock(cop,inc,now) then return false end
  cop.pepperAt=now+7;cop:setGunOut(false);cop:face(root.Position)
  Weapons.pepperSpray(cop.head,root.Position)
  inc.player:SetAttribute("LastPoliceLessLethal","PEPPER")
  Voice.say(cop,"Pepper spray!",inc,{command=false})
  Heat.stun(player,1.4);Arrest.onStun(inc,cop,1.4)
  return true
 end
	if Config.Taser.Enabled and dist>=Config.Taser.MinRange and dist<=Config.Taser.Range and now>=(cop.nextTase or 0) then
	-- A clear close-range probe is allowed even while the suspect is aiming.
	local tcfg = Config.Taser
	if not tcfg.Enabled or now < (cop.nextTase or 0) or dist < tcfg.MinRange or dist > tcfg.Range then
		return false
	end
	if not Tactics.clearShot(cop,inc,cop.head.Position,root.Position) then
		return false
	end
	if not Arrest.takeLessLethalLock(cop, inc, now) then
		return false
	end
	inc.player:SetAttribute("LastPoliceLessLethal","TASER")
	cop.nextTase = now + tcfg.Cooldown * (0.9 + math.random() * 0.4)
	cop:stop()
	cop:face(root.Position)
	local aimPart = Util.aimPart(char) or root
	if Weapons.fireTaserProbe(cop.head.Position, char, aimPart, { cop.model }) then
		Heat.stun(player, tcfg.Stun)
		Arrest.onStun(inc, cop, tcfg.Stun)
	end
	cop.pauseUntil = now + 0.6
	Voice.say(cop, "Taser! Taser!", inc, { command = false })
	return true
	end
	-- v142 rubber-ball launcher: selected officers can knock a resisting suspect
	-- into a temporary physics ragdoll without turning every cop into a less-lethal gunner.
	local rcfg = Config.Weapons.Rubber
	if cop.rubber and dist >= 10 and dist <= rcfg.Range and cop.rubber:ready() then
		if not Tactics.clearShot(cop, inc, cop.head.Position, root.Position) then return false end
		if not Arrest.takeLessLethalLock(cop, inc, now) then return false end
		cop:setGunOut(true); cop:face(root.Position)
		inc.player:SetAttribute("LastPoliceLessLethal","RUBBER")
		cop.rubber:fire(function()
			if not cop.alive or p.holdFire or inc.compliance~="Noncompliant" or os.clock()<(p.stunnedUntil or 0) then return nil end
			local c, h, r = Util.charInfo(player)
			if not c or not h or not r or h.SeatPart or h.Health<=0 or h:GetAttribute("PoliceCuffed") or player:GetAttribute("PoliceCritical")==true then return nil end
			local part = c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso") or r
			if not Util.canSee(cop.head.Position, c, part, { cop.model }) then return nil end
			return { part = part, hum = h, spread = rcfg.Spread / math.max(Config.Difficulty.Accuracy, 0.05), damageMul = 1, ignore = { cop.model }, eye = cop.head.Position,
				onHit = function(_, hitPart)
					local headshot = hitPart ~= nil and hitPart.Name == "Head"
					local knock = Util.safeUnit(flat(r.Position - cop.root.Position), Vector3.zAxis) * rcfg.Knockback + Vector3.new(0, 7, 0)
					local stunFor = if headshot then rcfg.HeadStun else rcfg.Stun
					if Heat.rubberStun(player, stunFor, headshot, knock) then Arrest.onStun(inc, cop, stunFor) end
				end }
		end, function() return cop.alive end)
		Voice.say(cop, "Less lethal!", inc, { command = false })
		return true
	end

	-- beanbag rounds (long guns)
	local bcfg = Config.Weapons.Beanbag
	if cop.beanbag and dist >= 7 and dist <= bcfg.Range and cop.beanbag:ready() then
		if not Tactics.clearShot(cop, inc, cop.head.Position, root.Position) then
			return false
		end
		if not Arrest.takeLessLethalLock(cop, inc, now) then
			return false
		end
		cop:setGunOut(true)
		cop:face(root.Position)
		local stunFor = bcfg.Stun or 1.5
		cop.beanbag:fire(function()
			if not cop.alive or p.holdFire or inc.compliance~="Noncompliant" or os.clock()<(p.stunnedUntil or 0) then
				return nil
			end
			local c, h, r = Util.charInfo(player)
			if not c or not h or not r or h.SeatPart or h.Health<=0 or h:GetAttribute("PoliceCuffed") or player:GetAttribute("PoliceCritical")==true then
				return nil
			end
			local part = Util.aimPart(c) or r
			if not Util.canSee(cop.head.Position, c, part, { cop.model }) then
				return nil
			end
			return {
				part = part,
				hum = h,
				spread = bcfg.Spread / math.max(Config.Difficulty.Accuracy, 0.05),
				damageMul = 1,
				ignore = { cop.model },
				eye = cop.head.Position,
				onHit = function()
					Heat.stun(player, stunFor)
					Arrest.onStun(inc, cop, stunFor)
				end,
			}
		end, function()
			return cop.alive
		end)
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- v116: the arrest owner walks up to a stopped car, orders the driver out, then pulls him out
---------------------------------------------------------------------------
local function behaveExtract(cop: any, inc: any, now: number, visible: boolean, hum: Humanoid?): boolean
	local E = Tuning.Extraction
	if not E.Enabled or not visible or not hum or not hum.SeatPart or not Arrest.isOwner(cop, inc) then
		return false
	end
	local k = inc.knowledge
	local p = inc.pursuit
	local subdued = (p.stunnedUntil ~= nil and now < p.stunnedUntil) or inc.compliance == "Complying" or inc.compliance == "Controlled"
	local stopped = k.stoppedSince ~= nil and now - k.stoppedSince >= E.StopTime
	if not stopped and not subdued then
		inc.extractOrderAt = nil
		return false
	end
	local t = inc.threat
	if t.aiming or (t.fired and not subdued) then
		return false -- armed and fighting from the car: stand off (contact / cover handle it)
	end
	local door, seat = Arrest.doorPoint(inc)
	if not door or not seat then
		return false
	end
	cop:setGunOut(t.armed and not subdued)
	local d = flat(door - cop.root.Position).Magnitude
	if d > E.Reach then
		cop:unface()
		cop:moveTo(door, d > 12)
		if d < 30 then
			Voice.say(cop, "Driver! Hands where I can see them!", inc, { announce = true, style = "danger" })
		end
		return true
	end
	cop:stop()
	cop:face(seat.Position)
	inc.extractOrderAt = inc.extractOrderAt or now
	if not subdued and now - inc.extractOrderAt < E.OrderTime then
		Voice.say(cop, "Get out of the vehicle! Now!", inc, { announce = true, style = "danger" })
		return true
	end
	inc.extractOrderAt = nil
	Arrest.extract(cop, inc)
	return true
end

---------------------------------------------------------------------------
-- behaviours
---------------------------------------------------------------------------
local function behaveCritical(cop: any, inc: any, now: number, slot: Vector3?)
	cop:setGunOut(false)
	local k = inc.knowledge
	if slot and flat(slot - cop.root.Position).Magnitude > 3 then
		goTo(cop, slot, false, k.pos)
	else
		holdAt(cop, k.pos)
	end
	if not inc.criticalCallAt then
		inc.criticalCallAt = now
		Voice.say(cop, "Suspect down! Hold fire - get EMS here!", inc, { force = true, command = false })
	end
end

local function behaveCustody(cop: any, inc: any, now: number, visible: boolean, hum: Humanoid?, root: BasePart?, slot: Vector3?)
	local k = inc.knowledge
	local tpos = if visible and root then root.Position else k.pos
	local d = flat(tpos - cop.root.Position).Magnitude
	if Arrest.isOwner(cop, inc) and Tactics.canArrest(inc,cop,now) then
		cop:setGunOut(false)
		-- v151: a stunned suspect gets a decisive single-officer tackle. This also
		-- owns the approach, so cover officers do not dogpile the player.
		if Arrest.tackle(cop, inc, now) then return end
		local exploit = inc.stunExploitUntil ~= nil and now < inc.stunExploitUntil
		local dy = math.abs(tpos.Y - cop.root.Position.Y)
		if d <= Config.Arrest.Range and dy < 4 and hum and not hum.SeatPart then
			holdAt(cop, tpos)
			Arrest.tick(cop, inc)
			if not inc.cuffCallAt or now - inc.cuffCallAt > 6 then
				inc.cuffCallAt = now
				Voice.say(cop, "Stay still - you're under arrest.", inc, { command = false })
			end
		else
			cop:unface()
			cop:moveTo(tpos, exploit or d > 25)
			command(cop, inc, visible, d)
		end
		return
	end
	-- cover: weapons ready only if he was armed; hold fire either way (p.holdFire)
	cop:setGunOut(inc.threat.armed)
	if slot and flat(slot - cop.root.Position).Magnitude > 3 then
		goTo(cop, slot, d > 40, tpos)
	else
		holdAt(cop, tpos)
	end
end

local function behaveSearch(cop: any, inc: any, now: number, role: string, slot: Vector3?)
	local k = inc.knowledge
	cop:setGunOut(Threat.dangerous(inc) or (inc.pursuit.stars or 0) >= 2)
	if role == "PERIMETER" then
		goTo(cop, slot, false, k.pos)
		return
	end
	local entry = inc.units[cop]
	if not slot then
		goTo(cop, k.pos, true, nil)
		return
	end
	local d = flat(slot - cop.root.Position).Magnitude
	if d > 6 then
		cop.aiLookUntil = nil
		local r = cop:moveTo(slot, (inc.pursuit.stars or 0) >= 2 or k.conf > 0.5)
		if r == "failed" then
			cop.aiFailCount = (cop.aiFailCount or 0) + 1
			if cop.aiFailCount > 4 then
				cop.aiFailCount = 0
				Search.complete(inc, cop) -- unreachable point: skip it
			end
		end
		return
	end
	-- look around, then take the next point
	cop:stop()
	if not cop.aiLookUntil then
		cop.aiLookUntil = now + Tuning.Search.LookTime
		local a = math.random() * math.pi * 2
		cop:face(cop.root.Position + Vector3.new(math.cos(a), 0, math.sin(a)) * 10)
	elseif now >= cop.aiLookUntil then
		cop.aiLookUntil = nil
		cop:unface()
		if entry then
			Search.complete(inc, cop)
		end
	end
end

local function behaveMount(cop: any, inc: any)
	local car = cop.homeCar
	if not car or car.dead or car.transporting or not car.body or not car.body.Parent then
		holdAt(cop, inc.knowledge.pos)
		return
	end
	cop:setGunOut(false)
	local door = car.body.Position
	if flat(door - cop.root.Position).Magnitude < 8 then
		car:crewBoard(cop)
		cop:despawn("boarded")
		return
	end
	cop:unface()
	cop:moveTo(door, true)
end

local function behaveFixed(cop: any, inc: any, now: number, visible: boolean, root: BasePart?)
	-- spike / roadblock officers hold their spot unless the suspect is right there on foot
	local k = inc.knowledge
	local tpos = if visible and root then root.Position else k.pos
	posture(cop, inc)
	local hold = cop.aiHoldPos
	if hold and flat(hold - cop.root.Position).Magnitude > 3 then
		goTo(cop, hold, true, cop.aiFacePos or tpos)
	else
		holdAt(cop, if visible then tpos else (cop.aiFacePos or tpos))
	end
	local d = flat(tpos - cop.root.Position).Magnitude
	if visible then
		local stopped = k.stoppedSince ~= nil and now - k.stoppedSince > 1
		command(cop, inc, visible, d, stopped)
		shoot(cop, inc, visible, tpos, now)
	end
end

local function behaveFoot(cop,inc,now,role,slot,visible,char,hum,root)
 local target=if visible and root then root.Position else inc.knowledge.pos
 local distance=flat(target-cop.root.Position).Magnitude
 posture(cop,inc)
 local entry=inc.units[cop]
 local inPosition=slot and flat(slot-cop.root.Position).Magnitude<6
 if role=="RESERVE" then
  Tactics.sniperLaser(cop,target,false)
  if slot then goTo(cop,slot,true,nil) else holdAt(cop,target) end
  return
 end
 if Tactics.breachStep(cop,inc,now) then return end
 if role=="SNIPER" then
  local ready=inPosition and math.abs(slot.Y-cop.root.Position.Y)<6
  Tactics.sniperLaser(cop,target,visible and ready)
  if not ready then
   cop.sniperAimAt=nil
   if Tactics.canMove(cop,inc,slot,now) then goTo(cop,slot,false,nil) else holdAt(cop,target) end
   return
  end
  holdAt(cop,target)
  if visible and mayShoot(cop,inc,true,target) then
   cop.sniperAimAt=cop.sniperAimAt or now
   if now-cop.sniperAimAt>=2.5 and Tactics.fireWindow(cop,inc,now) then shoot(cop,inc,true,target,now);cop.sniperAimAt=now end
  else cop.sniperAimAt=nil end
  return
 end
 Tactics.sniperLaser(cop,target,false)
 if role=="CONTACT" then command(cop,inc,visible,distance) end
 local F=Tuning.Force
 local lethalPosture=inc.pursuit.lethal==true and inc.threat.level=="LETHAL"
 local close=distance<=F.CloseRange
 -- Only assigned support throws. Close self-defence is available to everyone,
 -- but reserve/perimeter officers do not all rush into taser range. v191: under
 -- lethal authorization anyone inside CloseRange goes less-lethal first.
 if visible and (role=="LESSLETHAL" or (role=="CONTACT" and Tactics.coverReady(inc,cop,now)) or distance<=10 or (lethalPosture and close)) then
  if tryLessLethal(cop,inc,now,visible,char,hum,root) then return end
 end
 if role=="SUPPORT" and visible and inPosition and ((inc.pursuit.stars or 0)>=2 or inc.threat.fired) then
  if Tactics.supportDevice(cop,inc,now,target,false) then holdAt(cop,target);return end
 end
 if Arrest.isOwner(cop,inc) and visible and Tactics.canArrest(inc,cop,now) then
  if distance<=Config.Arrest.Range and math.abs(target.Y-cop.root.Position.Y)<4 then holdAt(cop,target);Arrest.tick(cop,inc)
  else goTo(cop,target,true,target) end
  return
 end
 if slot and not inPosition then
  if Tactics.canMove(cop,inc,slot,now) then
   local result=goTo(cop,slot,distance>35,target)
   if result=="failed" and now>=(cop.planFailureAt or 0) then cop.planFailureAt=now+4;inc.footPlan=nil end
  else holdAt(cop,target) end
 else holdAt(cop,target) end
 -- v191 fire and manoeuvre: with lethal force authorized every non-reserve
 -- officer with a clear shot engages from range, also while moving to his
 -- slot. Inside CloseRange live fire is self-defence only.
 if visible then
  local canFire=(inPosition and (role=="COVER" or role=="SHIELD" or role=="CONTACT")) or (lethalPosture and role~="RESERVE")
  if canFire and (not close or selfDefense(cop,inc,now)) then shoot(cop,inc,visible,target,now,lethalPosture and not inPosition) end
 end
end

---------------------------------------------------------------------------
-- entry points
---------------------------------------------------------------------------
-- Uninvolved patrol officer: does he notice a wanted suspect?
function Brain.patrolScan(cop: any, now: number)
	if cop.role ~= "Patrol" or cop.aiNoJoin or not cop.active then
		return
	end
	if now < (cop.aiScanAt or 0) then
		return
	end
	cop.aiScanAt = now + 0.5
	for inc in Ctx.Incidents.each() do
		if inc.mode ~= "CRITICAL" and Perception.detect(cop, inc, now) then
			cop:assign(inc.pursuit)
			Log.event("UNIT JOINED", "#%d %s saw the suspect", inc.id, cop.model and cop.model.Name or "officer")
			return
		end
	end
end

-- Called from Cop:think. Returns true when the brain handled this think.
function Brain.think(cop: any, now: number): boolean
	if not Tuning.Enabled then
		return false
	end
	if cop.state == "leave" then
		return false -- legacy: walk back to the car / station
	end
	if cop.aiScripted then
		return true -- Roadside is driving this officer (spike deployment etc.)
	end
	local p = cop.pursuit
	if not p then
		Brain.patrolScan(cop, now)
		p = cop.pursuit
		if not p then
			cop.thinkInterval = 0.3
			return false -- legacy patrol
		end
	end
	if not p.active then
		return false
	end
	local inc = Ctx.Incidents.forPursuit(p)
	if not inc then
		return false
	end
	local visible = Perception.officer(cop, inc, now)
	cop.state = if visible then "engage" else "hunt"
	cop.target = if visible then inc.player else nil
	local char, hum, root = nil, nil, nil
	if visible then
		char, hum, root = Util.charInfo(inc.player)
	end
	if cop.aimLaser and (inc.mode~="FOOT" or not visible) then Tactics.sniperLaser(cop,inc.knowledge.pos,false) end
	local entry = inc.units[cop]
	local role = if entry then entry.role else (if visible then "COVER" else "SEARCH")
	local slot = entry and entry.slot

	-- LOD: officers far from the action think less often
	local d = flat(inc.knowledge.pos - cop.root.Position).Magnitude
	cop.thinkInterval = if visible or d < 120 then 0.2 elseif d < 400 then 0.3 else 0.5

	local mode = inc.mode
	if mode ~= "CRITICAL" and behaveExtract(cop, inc, now, visible, hum) then
		return true
	end
	if mode == "CRITICAL" or inc.compliance == "Critical" then
		behaveCritical(cop, inc, now, slot)
	elseif mode == "CUSTODY" then
		behaveCustody(cop, inc, now, visible, hum, root, slot)
	elseif cop.aiFixedRole == "BOARD" or role == "MOUNT" then
		behaveMount(cop, inc)
	elseif cop.aiFixedRole then
		behaveFixed(cop, inc, now, visible, root)
	elseif mode == "VEHICLE" and role == "PERIMETER" then
		-- on foot, no car nearby: don't chase a moving vehicle; watch, report, hold the road
		local tpos = if visible and root then root.Position else inc.knowledge.pos
		posture(cop, inc)
		if visible then
			holdAt(cop, tpos)
			shoot(cop, inc, visible, tpos, now)
		elseif flat(inc.knowledge.pos - cop.root.Position).Magnitude < 90 then
			goTo(cop, inc.knowledge.pos, false, nil)
		else
			holdAt(cop, nil)
		end
	elseif mode == "SEARCH" then
		if visible then
			behaveFoot(cop, inc, now, "CONTACT", nil, visible, char, hum, root)
		else
			behaveSearch(cop, inc, now, role, slot)
		end
	else
		behaveFoot(cop, inc, now, role, slot, visible, char, hum, root)
	end
	return true
end

return Brain
