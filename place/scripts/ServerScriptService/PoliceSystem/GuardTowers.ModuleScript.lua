--[[
	GuardTowers  (child ModuleScript of PoliceSystem)   v245

	One sniper + one spotlight per mapped GuardTower zone (or SniperPost / Spotlight
	points when mapped). Targets are ONLY:
	  * escapees (EscapeInProgress) and inmates OUTSIDE the prison walls  -> Perimeter rules
	  * inmates inside a mapped KillZone (between the fences)               -> KillZone rules
	Never anyone in the yard or other normal areas.

	Perimeter: alarm, "STOP! Get on the ground!", a warning shot, then fire to kill.
	KillZone:  alarm, one shout, then fire.
	StunZone:  (v245b) a KillZone whose Description says STUN / NON LETHAL, or ZoneType StunZone:
	           alarm, shout, then rubber bullets (never lethal, knock down for a few seconds)
	           and troops dispatched to the spot.
	Hands up (surrender) = hold fire. Spotlights sweep at night and lock onto targets.
	The alarm sets Workspace attribute PrisonLockdown for 2 minutes and calls ctx.alarm
	(radio + police response). A sniper kill of an escaping inmate calls ctx.sniperKill
	(counts as a prison death: profile wipe).

	init(ctx) ctx = { F, Util, outside(pos)->bool, isInmate(player)->bool, surrendered(player)->bool,
	                  tell(player, kind, text), notifyAll(text), alarm(player, pos), sniperKill(player) }
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local T = {}
T.VERSION = "245d" -- v245b: stun zones

local CFG = {
	Range = 450, -- studs a tower covers
	ShoutDelay = 3, -- after the shout, before the warning shot
	WarnDelay = 2.5, -- after the warning shot, before firing to kill
	KillZoneDelay = 2, -- kill zone: shout, then fire
	FireInterval = 2.4, -- slow, aimed shots
	Damage = 45,
	HitChanceNear = 0.7, -- under 150 studs
	HitChanceFar = 0.4, -- at max range
	AlarmCooldown = 60,
	LockdownSeconds = 120,
	SweepDegrees = 70,
	SweepSeconds = 9,
	-- v245b non-lethal stun zone
	StunDelay = 2.5, -- shout, then rubber bullets
	StunInterval = 3,
	StunDamage = 8,
	StunMinHealth = 15, -- rubber bullets never take you below this
	StunKnockdown = 3, -- seconds on the ground
	StunHitChance = 0.75,
	GuardsPerTower = nil :: number?, -- nil = 3 on a big cab, else 2
}
T.CFG = CFG

local ctx: any = nil
local towers: { any } = {}
local guards: { any } = {} -- v245d: 2-3 per tower
local targets: { [Player]: any } = {}
local lastAlarm = -math.huge
local folder: Folder? = nil

local function night(): boolean
	local t = Lighting.ClockTime
	return t < 6.5 or t > 18.5
end

local function rayParams(ignore: { Instance }): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = ignore
	return p
end

local function part(parent: Instance, name: string, size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = parent
	return p
end

local UNIFORM = Color3.fromRGB(28, 38, 58)
local PANTS = Color3.fromRGB(22, 24, 28)
local SKIN = Color3.fromRGB(204, 160, 120)

-- v245d: a tower guard - an R6-shaped anchored figure (torso, head, legs, both arms
-- raised holding a scoped rifle). It never moves its feet; aimAt turns it and the rifle.
local function makeGuard(i: number, floor: Vector3, look: Vector3): any
	local m = Instance.new("Model")
	m.Name = "TowerGuard_" .. i
	local torso = part(m, "Torso", Vector3.new(2, 2, 1), UNIFORM)
	local head = part(m, "Head", Vector3.new(1.2, 1.2, 1.2), SKIN)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
	mesh.Parent = head
	local cap = part(m, "Cap", Vector3.new(1.3, 0.35, 1.4), UNIFORM)
	local lleg = part(m, "Left Leg", Vector3.new(1, 2, 1), PANTS)
	local rleg = part(m, "Right Leg", Vector3.new(1, 2, 1), PANTS)
	local larm = part(m, "Left Arm", Vector3.new(1, 2, 1), UNIFORM)
	local rarm = part(m, "Right Arm", Vector3.new(1, 2, 1), UNIFORM)
	local rifle = Instance.new("Model")
	rifle.Name = "Rifle"
	local stock = part(rifle, "Stock", Vector3.new(0.35, 0.6, 1.4), Color3.fromRGB(60, 45, 30), Enum.Material.Wood)
	local body = part(rifle, "Receiver", Vector3.new(0.3, 0.45, 1.6), Color3.fromRGB(25, 25, 25), Enum.Material.Metal)
	local barrel = part(rifle, "Barrel", Vector3.new(0.15, 0.15, 2.4), Color3.fromRGB(18, 18, 18), Enum.Material.Metal)
	local scope = part(rifle, "Scope", Vector3.new(0.22, 0.22, 1.1), Color3.fromRGB(10, 10, 10), Enum.Material.Metal)
	rifle.PrimaryPart = body
	rifle.Parent = m
	m.PrimaryPart = torso
	m.Parent = folder
	local g = {
		i = i, floor = floor, look = look, model = m, torso = torso, head = head, cap = cap, lleg = lleg, rleg = rleg,
		larm = larm, rarm = rarm, rifle = rifle, stock = stock, body = body, barrel = barrel, scope = scope,
		nextShot = 0,
	}
	return g
end

-- pose the guard facing `at` (rifle pointed straight at it)
local function aimAt(g: any, at: Vector3)
	local base = g.floor + Vector3.new(0, 3, 0) -- torso centre (legs are 2 tall)
	local flat = Vector3.new(at.X, base.Y, at.Z)
	if (flat - base).Magnitude < 0.1 then flat = base + g.look end
	local cf = CFrame.lookAt(base, flat)
	g.torso.CFrame = cf
	g.head.CFrame = cf * CFrame.new(0, 1.6, 0)
	g.cap.CFrame = cf * CFrame.new(0, 2.25, -0.05)
	g.lleg.CFrame = cf * CFrame.new(-0.5, -2, 0)
	g.rleg.CFrame = cf * CFrame.new(0.5, -2, 0)
	-- arms raised forward from the shoulders, holding the rifle at eye level
	local raise = CFrame.Angles(math.rad(90), 0, 0)
	g.rarm.CFrame = cf * CFrame.new(1.5, 0.5, 0) * raise * CFrame.Angles(0, 0, math.rad(-12)) * CFrame.new(0, -1, 0)
	g.larm.CFrame = cf * CFrame.new(-1.5, 0.5, 0) * raise * CFrame.Angles(0, 0, math.rad(30)) * CFrame.new(0, -1, 0)
	local grip = (cf * CFrame.new(0.55, 1.05, -1.6)).Position
	local rcf = CFrame.lookAt(grip, at)
	g.body.CFrame = rcf
	g.stock.CFrame = rcf * CFrame.new(0, -0.08, 1.4)
	g.barrel.CFrame = rcf * CFrame.new(0, 0.05, -2)
	g.scope.CFrame = rcf * CFrame.new(0, 0.35, -0.1)
	g.eye = g.head.Position
	g.muzzle = (rcf * CFrame.new(0, 0.05, -3.2)).Position
end

local function tracer(from: Vector3, to: Vector3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 220, 140)
	local d = (to - from).Magnitude
	p.Size = Vector3.new(0.12, 0.12, d)
	p.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -d / 2)
	p.Parent = folder
	Debris:AddItem(p, 0.08)
end

-- v245d: the guard's own tower cab (walls, railings, glass) never blocks its view
local function canSee(g: any, char: Model, target: BasePart): boolean
	local dir = target.Position - g.eye
	local hit = Workspace:Raycast(g.eye, dir, g.params)
	return hit == nil or hit.Instance:IsDescendantOf(char) or (hit.Position - g.eye).Magnitude >= dir.Magnitude - 2
end

-- v245b: a mapped kill zone marked non-lethal (description) or a StunZone
local function isStunZone(z: any): boolean
	local inst = z.instance
	if not inst then return false end
	if inst:GetAttribute("ZoneType") == "StunZone" then return true end
	local d = string.upper(tostring(inst:GetAttribute("Description") or "") .. " " .. inst.Name)
	return string.find(d, "STUN", 1, true) ~= nil or string.find(d, "NON LETHAL", 1, true) ~= nil
		or string.find(d, "NON-LETHAL", 1, true) ~= nil or string.find(d, "RUBBER", 1, true) ~= nil
end

-- what rules apply to this player right now: "Perimeter", "KillZone", "StunZone" or nil
local function ruleFor(player: Player, pos: Vector3): string?
	local escaping = player:GetAttribute("EscapeInProgress") == true
	local inmate = ctx.isInmate(player)
	local feet = pos - Vector3.new(0, 3, 0)
	-- v245f: cuffed / in custody = handled, the towers hold fire
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local stage = player:GetAttribute("CustodyStage")
	local inCustody = stage ~= nil and stage ~= "Free" and stage ~= "Serving" and stage ~= "Release"
	if (hum and hum:GetAttribute("PoliceCuffed")) or (inCustody and not escaping) then
		return nil
	end
	-- v245c: kill / stun zones are restricted ground for EVERYONE except police and
	-- staff (a citizen climbing the fences gets the same treatment as an inmate)
	local law = false
	pcall(function() law = (ctx.isStaff and ctx.isStaff(player)) or ctx.Util.isLaw(player) end)
	if not law or escaping or inmate then
		-- lethal zones win where a lethal and a stun zone overlap
		local stun = false
		for _, z in ctx.F.zones("Prison", "KillZone") do
			if ctx.F.inZone(z, feet, 2) then
				if isStunZone(z) then stun = true else return "KillZone" end
			end
		end
		for _, z in ctx.F.zones("Prison", "StunZone") do
			if ctx.F.inZone(z, feet, 2) then stun = true end
		end
		if stun then return "StunZone" end
	end
	-- the perimeter (outside the walls) only concerns inmates and escapees
	if not escaping and not inmate then return nil end
	if ctx.outside(pos) then return "Perimeter" end
	for _, z in ctx.F.zones("Prison", "Perimeter") do
		if ctx.F.inZone(z, feet, 2) then return "Perimeter" end
	end
	return nil
end

local function raiseAlarm(player: Player, pos: Vector3, rule: string)
	if os.clock() - lastAlarm < CFG.AlarmCooldown then return end
	lastAlarm = os.clock()
	Workspace:SetAttribute("PrisonLockdown", true)
	task.delay(CFG.LockdownSeconds, function() Workspace:SetAttribute("PrisonLockdown", nil) end)
	print(("[GuardTowers] ALARM %s in the %s - lockdown %ds"):format(player.Name, rule, CFG.LockdownSeconds))
	pcall(ctx.notifyAll, "PRISON ALARM - escape attempt! The prison is in lockdown.")
	pcall(ctx.alarm, player, pos)
end

local function shoot(t: any, player: Player, char: Model, hum: Humanoid, part: BasePart, warning: boolean)
	local from = t.muzzle
	local dist = (part.Position - from).Magnitude
	if warning then
		-- into the ground a few studs in front of them
		local miss = part.Position + Vector3.new(math.random(-4, 4), -3, math.random(-4, 4))
		tracer(from, miss)
		return
	end
	local chance = CFG.HitChanceFar + (CFG.HitChanceNear - CFG.HitChanceFar) * math.clamp(1 - (dist - 150) / (CFG.Range - 150), 0, 1)
	if math.random() < chance then
		tracer(from, part.Position)
		-- v245c: only an inmate / escapee's death is a prison death (profile wipe);
		-- a trespassing citizen just dies
		local prisoner = player:GetAttribute("EscapeInProgress") == true or ctx.isInmate(player)
		if prisoner and hum.Health - CFG.Damage <= 0 then
			player:SetAttribute("PrisonKilledBy", "Tower sniper")
			player:SetAttribute("TowerSniperKill", true)
		end
		hum:TakeDamage(CFG.Damage)
		if hum.Health <= 0 then
			print(("[GuardTowers] %s shot dead by tower %d%s"):format(player.Name, t.i, if prisoner then "" else " (trespasser)"))
			if prisoner then pcall(ctx.sniperKill, player) end
		end
	else
		tracer(from, part.Position + Vector3.new(math.random(-6, 6), math.random(-2, 4), math.random(-6, 6)))
	end
end

-- v245b: rubber bullet - hurts, never kills, knocks them down
local function stunShot(t: any, player: Player, hum: Humanoid, part: BasePart)
	local from = t.muzzle
	if math.random() >= CFG.StunHitChance then
		tracer(from, part.Position + Vector3.new(math.random(-5, 5), math.random(-2, 3), math.random(-5, 5)))
		return
	end
	tracer(from, part.Position)
	local dmg = math.min(CFG.StunDamage, math.max(0, hum.Health - CFG.StunMinHealth))
	if dmg > 0 then hum:TakeDamage(dmg) end
	-- v245e: the police rubber-round ragdoll, so responding officers treat them as downed
	local okR, ragdolled = false, false
	if ctx.rubberStun then okR, ragdolled = pcall(ctx.rubberStun, player, CFG.StunKnockdown) end
	if not (okR and ragdolled) then
		hum.PlatformStand = true
		task.delay(CFG.StunKnockdown, function()
			if hum.Parent and not hum:GetAttribute("PoliceCuffed") then hum.PlatformStand = false end
		end)
	end
	player:SetAttribute("TowerStunned", true)
	task.delay(CFG.StunKnockdown, function() player:SetAttribute("TowerStunned", nil) end)
	pcall(ctx.tell, player, "Custody", "TOWER: Rubber rounds! Stay down - officers are on the way.")
	print(("[GuardTowers] %s hit with a rubber round by tower %d guard %d"):format(player.Name, t.tower and t.tower.i or 0, t.i))
end

local function lampAt(tw: any, at: Vector3)
	tw.lamp.CFrame = CFrame.lookAt(tw.lamp.Position, at)
	tw.spot.Position = at
end

local function step(now: number)
	local isNight = night()
	local sweep = math.sin(now / CFG.SweepSeconds * math.pi * 2) * math.rad(CFG.SweepDegrees)
	-- v245d: every guard who can see a target engages it (2-3 per tower)
	local engaged: { [any]: { player: Player, char: Model, hum: Humanoid, part: BasePart, rule: string } } = {}
	local towerTarget: { [any]: Vector3 } = {}
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local st = targets[player]
		if hum and root and root:IsA("BasePart") and hum.Health > 0 then
			local rule = ruleFor(player, root.Position)
			if rule then
				local first, firstD = nil, math.huge
				for _, g in guards do
					local d = (root.Position - g.eye).Magnitude
					if d < CFG.Range and not engaged[g] and canSee(g, char, root) then
						engaged[g] = { player = player, char = char, hum = hum, part = root, rule = rule }
						towerTarget[g.tower] = towerTarget[g.tower] or root.Position
						if d < firstD then first, firstD = g, d end
					end
				end
				if first then
					if not st or st.rule ~= rule then
						st = { rule = rule, stage = "seen", at = now }
						targets[player] = st
						raiseAlarm(player, root.Position, rule)
						if rule == "StunZone" then
							pcall(ctx.tell, player, "Custody", "TOWER: Restricted area! Get on the ground or we fire rubber rounds!")
						elseif rule == "KillZone" then
							pcall(ctx.tell, player, "Custody", "TOWER: You are in the kill zone! Get down!")
						else
							pcall(ctx.tell, player, "Custody", "TOWER: STOP! Get on the ground!")
						end
						print(("[GuardTowers] %s spotted by tower %d guard %d (%s, %.0f studs)"):format(player.Name, first.tower.i, first.i, rule, firstD))
						-- v245e: being in a zone is a crime for anyone who isn't already in custody
						local prisoner = player:GetAttribute("EscapeInProgress") == true or ctx.isInmate(player)
						if not prisoner and ctx.crime and rule ~= "Perimeter" then
							local crime = if rule == "StunZone" then "PrisonTrespass" else "PrisonFenceBreach"
							local okC, counted = pcall(ctx.crime, player, crime, root.Position)
							print(("[GuardTowers] %s charged with %s (%s)"):format(player.Name, crime, if okC and counted then "wanted" else "not counted"))
						end
					end
					-- keep dispatch on them while a tower has eyes on them
					if ctx.spotted and now - (st.reported or 0) > 1.5 then
						st.reported = now
						pcall(ctx.spotted, player, root.Position)
					end
				end
			else
				targets[player] = nil
			end
		else
			targets[player] = nil
		end
	end
	for _, tw in towers do
		local at = towerTarget[tw]
		tw.light.Enabled = isNight or at ~= nil
		tw.beam.Enabled = tw.light.Enabled
		if at then
			lampAt(tw, at)
		else
			-- idle: sweep the ground outward
			local dir = CFrame.fromAxisAngle(Vector3.yAxis, sweep) * tw.look
			lampAt(tw, tw.lamp.Position + dir * 45 - Vector3.new(0, tw.lamp.Position.Y - tw.groundY, 0))
		end
	end
	for _, g in guards do
		local e = engaged[g]
		if e then
			local st = targets[e.player]
			aimAt(g, e.part.Position)
			if ctx.surrendered(e.player) then
				st.held = true
			elseif now >= g.nextShot then
				local since = now - st.at
				if e.rule == "StunZone" then
					-- v245f: rubber rounds only from the 2 closest guards, and never at
					-- someone already down - they stay down for the officers to cuff
					local down = e.hum:GetAttribute("PoliceStunned") == true or e.hum.PlatformStand
					local rank = 0
					for g2, e2 in engaged do
						if e2.player == e.player and g2 ~= g and (g2.eye - e.part.Position).Magnitude < (g.eye - e.part.Position).Magnitude then
							rank += 1
						end
					end
					if not down and rank < 2 and since >= CFG.StunDelay then
						g.nextShot = now + CFG.StunInterval + math.random() -- guards don't fire in unison
						stunShot(g, e.player, e.hum, e.part)
					end
				elseif e.rule == "KillZone" then
					if since >= CFG.KillZoneDelay then
						g.nextShot = now + CFG.FireInterval + math.random()
						shoot(g, e.player, e.char, e.hum, e.part, false)
					end
				elseif st.stage == "seen" and since >= CFG.ShoutDelay then
					st.stage = "warned"
					st.at = now
					g.nextShot = now + CFG.WarnDelay
					pcall(ctx.tell, e.player, "Custody", "TOWER: Warning shot! Next one won't miss.")
					shoot(g, e.player, e.char, e.hum, e.part, true)
				elseif st.stage == "warned" and since >= CFG.WarnDelay then
					g.nextShot = now + CFG.FireInterval + math.random()
					shoot(g, e.player, e.char, e.hum, e.part, false)
				end
			end
		elseif g.aimedIdle ~= true then
			aimAt(g, g.eye + g.look * 50 - Vector3.new(0, 12, 0))
			g.aimedIdle = true
		end
		if e then g.aimedIdle = false end
	end
end

-- corners of a mapped zone
local function corners(z: any): { Vector3 }
	local out = {}
	local cp = z.instance and z.instance:FindFirstChild("ControlPoints")
	if cp then
		for _, p in cp:GetChildren() do
			if p:IsA("BasePart") then table.insert(out, p.Position) end
		end
	end
	return out
end

-- one tower: 2-3 guards spread around the cab, one spotlight on top
local function buildTower(i: number, z: any, prisonCenter: Vector3)
	local pts = corners(z)
	local c = z.center
	local bottom = tonumber(z.bottom) or c.Y
	local top = tonumber(z.top) or (bottom + 20)
	-- the cab's own parts (walls, railings, roof posts) are ignored for line of sight
	local minX, maxX, minZ, maxZ = c.X - 6, c.X + 6, c.Z - 6, c.Z + 6
	for _, p in pts do
		minX, maxX, minZ, maxZ = math.min(minX, p.X), math.max(maxX, p.X), math.min(minZ, p.Z), math.max(maxZ, p.Z)
	end
	local boxCF = CFrame.new((minX + maxX) / 2, (bottom + top) / 2, (minZ + maxZ) / 2)
	local boxSize = Vector3.new(maxX - minX + 6, top - bottom + 6, maxZ - minZ + 6)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { folder :: Instance }
	local ignore: { Instance } = { folder :: Instance }
	for _, p in Workspace:GetPartBoundsInBox(boxCF, boxSize, overlap) do
		if not p:IsA("Terrain") then table.insert(ignore, p) end
	end
	local params = rayParams(ignore)
	local floorParams = rayParams({ folder :: Instance })
	local outward = ctx.Util.safeUnit(Vector3.new(c.X - prisonCenter.X, 0, c.Z - prisonCenter.Z), Vector3.zAxis)
	-- ground below the tower, for the spotlight sweep
	local g0 = Workspace:Raycast(Vector3.new(c.X, bottom - 2, c.Z) + outward * 30, Vector3.new(0, -200, 0), floorParams)
	local tw = { i = i, look = outward, groundY = if g0 then g0.Position.Y else bottom - 30 }
	-- guards: 3 on a big cab, else 2, at opposite sides
	local area = (maxX - minX) * (maxZ - minZ)
	local n = math.clamp(CFG.GuardsPerTower or (if area > 150 then 3 else 2), 1, 4)
	table.sort(pts, function(a, b)
		return math.atan2(a.Z - c.Z, a.X - c.X) < math.atan2(b.Z - c.Z, b.X - c.X)
	end)
	for k = 1, n do
		local spot: Vector3
		if #pts >= 3 then
			local corner = pts[math.floor((k - 1) * #pts / n) + 1]
			spot = c + (Vector3.new(corner.X, c.Y, corner.Z) - c) * 0.55
		else
			local ang = (k - 1) / n * math.pi * 2
			spot = c + Vector3.new(math.cos(ang), 0, math.sin(ang)) * 3
		end
		local hit = Workspace:Raycast(Vector3.new(spot.X, bottom + 2.5, spot.Z), Vector3.new(0, -8, 0), floorParams)
		local floor = if hit then hit.Position else Vector3.new(spot.X, bottom, spot.Z)
		local look = ctx.Util.safeUnit(Vector3.new(spot.X - c.X, 0, spot.Z - c.Z) + outward, outward)
		local g = makeGuard(#guards + 1, floor, look)
		g.tower = tw
		g.params = params
		aimAt(g, floor + Vector3.new(0, 4.6, 0) + look * 50 - Vector3.new(0, 12, 0))
		g.aimedIdle = true
		table.insert(guards, g)
	end
	-- spotlight on a post in the middle of the cab
	local hit = Workspace:Raycast(Vector3.new(c.X, bottom + 2.5, c.Z), Vector3.new(0, -8, 0), floorParams)
	local floor = if hit then hit.Position else Vector3.new(c.X, bottom, c.Z)
	part(folder :: Instance, "SpotlightPost_" .. i, Vector3.new(0.4, 5.5, 0.4), Color3.fromRGB(40, 40, 40), Enum.Material.Metal).CFrame =
		CFrame.new(floor + Vector3.new(0, 2.75, 0))
	local lamp = part(folder :: Instance, "TowerSpotlight_" .. i, Vector3.new(1.6, 1.6, 2), Color3.fromRGB(30, 30, 30), Enum.Material.Metal)
	lamp.CFrame = CFrame.lookAt(floor + Vector3.new(0, 6.3, 0), floor + Vector3.new(0, 6.3, 0) + outward)
	local lens = part(lamp, "Lens", Vector3.new(1.4, 1.4, 0.1), Color3.fromRGB(255, 245, 215), Enum.Material.Neon)
	local weld = Instance.new("WeldConstraint")
	lens.Anchored = false
	lens.CFrame = lamp.CFrame * CFrame.new(0, 0, -1.02)
	weld.Part0, weld.Part1 = lamp, lens
	weld.Parent = lens
	local light = Instance.new("SpotLight")
	light.Range = 90
	light.Angle = 22
	light.Brightness = 8
	light.Face = Enum.NormalId.Front
	light.Shadows = true
	light.Enabled = false
	light.Parent = lens
	-- a visible beam down to where the light points
	local spot = part(folder :: Instance, "SpotlightTarget_" .. i, Vector3.new(0.2, 0.2, 0.2), Color3.new(1, 1, 1))
	spot.Transparency = 1
	local a0 = Instance.new("Attachment")
	a0.Parent = lens
	local a1 = Instance.new("Attachment")
	a1.Parent = spot
	local beam = Instance.new("Beam")
	beam.Attachment0, beam.Attachment1 = a0, a1
	beam.Width0, beam.Width1 = 1.4, 9
	beam.Color = ColorSequence.new(Color3.fromRGB(255, 245, 215))
	beam.Transparency = NumberSequence.new(0.55, 0.92)
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Enabled = false
	beam.Parent = lens
	tw.lamp, tw.light, tw.beam, tw.spot = lamp, light, beam, spot
	table.insert(towers, tw)
end

function T.init(c: any): number
	ctx = c
	local F = ctx.F
	local old = Workspace:FindFirstChild("GuardTowerPosts")
	if old then old:Destroy() end
	local f = Instance.new("Folder")
	f.Name = "GuardTowerPosts"
	f.Parent = Workspace
	folder = f
	towers = {}
	guards = {}
	local prison = F.get("Prison")
	if not prison then return 0 end
	local center = Vector3.zero
	for _, z in prison.zones do center += z.center end
	center /= math.max(1, #prison.zones)
	local posts = F.points("Prison", "SniperPost")
	if #posts > 0 then
		-- mapped SniperPost points: one guard each, grouped as their own "towers"
		for i, p in posts do
			local look = ctx.Util.safeUnit(Vector3.new(p.cframe.LookVector.X, 0, p.cframe.LookVector.Z), Vector3.zAxis)
			local fake = { center = p.position, bottom = p.position.Y - 1, top = p.position.Y + 12, instance = nil }
			local saved = CFG.GuardsPerTower
			CFG.GuardsPerTower = 1
			buildTower(i, fake, p.position - look * 50)
			CFG.GuardsPerTower = saved
		end
	else
		for i, z in F.zones("Prison", "GuardTower") do
			local ok, err = pcall(buildTower, i, z, center)
			if not ok then warn(("[GuardTowers] tower %d (%s) failed: %s"):format(i, tostring(z.name), tostring(err))) end
		end
	end
	task.spawn(function()
		while folder and folder.Parent do
			local ok, err = pcall(step, os.clock())
			if not ok then warn("[GuardTowers] " .. tostring(err)) end
			task.wait(0.4)
		end
	end)
	local lethal, stun = 0, #F.zones("Prison", "StunZone")
	for _, z in F.zones("Prison", "KillZone") do
		if isStunZone(z) then stun += 1 else lethal += 1 end
	end
	print(("[GuardTowers] v%s: %d tower(s), %d guard(s) (%s), lethal zones=%d stun zones=%d perimeter zones=%d"):format(
		tostring(T.VERSION), #towers, #guards, if #posts > 0 then "SniperPost points" else "GuardTower zones",
		lethal, stun, #F.zones("Prison", "Perimeter")))
	return #guards
end

-- debugging: the live guard list
function T.guards(): { any }
	return guards
end

return T
