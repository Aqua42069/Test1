-- StreetGangs (v251)
-- The four prison gangs exist in the city too, and your standing is ONE standing:
--   * Saved (DataStore LasVegas_Gangs_v1): Rep_EK/IS/DS/TL, PrisonGang, GangRank,
--     GangPoints, the Skill* / Contact_* lessons, EscapeIntel, SnitchedOn and street
--     feuds. A feud from prison follows you out, and a street feud follows you in
--     (PrisonSociety reads the same attributes).
--   * Territories: zones mapped with the Facility Mapper as City > TerritoryEK / IS /
--     DS / TL (Workspace.CityMap). Each gets a few members hanging around their turf.
--   * Friendly (in the gang, or respect >= 40): they greet you, back you up when
--     another gang's members jump you on their turf, and give you street jobs.
--   * At war (respect <= -40, a feud, you snitched on them, or you ride with their
--     rival and they don't like you): members recognise you and attack on sight.
--     Deep enough (respect <= -70, a feud, snitched) they come to kill - and every so
--     often a hit crew finds you anywhere in the city.
--   * Killing a member: -40 respect, a 30-minute feud (saved) and a murder report.
-- Load failures never save (so a bad load can't wipe anyone's standing).

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Workspace = game:GetService("Workspace")

local VERSION = 251
local GANGS = {
	EK = { name = "Eastside Kings", color = Color3.fromRGB(200, 28, 28), rival = "IS" },
	IS = { name = "Iron Syndicate", color = Color3.fromRGB(22, 22, 24), rival = "EK" },
	DS = { name = "Desert Saints", color = Color3.fromRGB(240, 130, 20), rival = "TL" },
	TL = { name = "The Lifers", color = Color3.fromRGB(30, 80, 205), rival = "DS" },
}
local ORDER = { "EK", "IS", "DS", "TL" }
local CFG = {
	MembersPerTurf = 4,
	HostileRep = -40,
	DeadlyRep = -70,
	FriendlyRep = 40,
	RivalHostileRep = -20,
	SightRange = 70,
	PunchRange = 5,
	PunchDamage = 9,
	KillDamage = 18,
	FeudSeconds = 1800,
	HitCrewEvery = { 360, 720 }, -- seconds between hit-crew rolls for someone a gang wants dead
	HitCrewChance = 0.35,
	JobPay = { 1200, 2500 },
	JobSeconds = 240,
	SaveEvery = 60,
}
-- attributes that make up a player's gang standing (saved)
local SAVED = {
	"Rep_EK", "Rep_IS", "Rep_DS", "Rep_TL", "PrisonGang", "GangRank", "GangPoints",
	"SkillShivCraft", "SkillHideContraband", "SkillLockpicking", "SkillVisitSmuggling",
	"Contact_PlateMaker", "Contact_Fixer", "Contact_ChopShop", "EscapeIntel", "BribableCO", "SnitchedOn",
	"StreetFeud_EK", "StreetFeud_IS", "StreetFeud_DS", "StreetFeud_TL",
}

local NAMES = { "Lil Ray", "Dutch", "Spook", "Rocco", "Jules", "Benny", "Q", "Smoke", "Tank", "Juice", "Mookie", "Paco",
	"Trigger", "Slim", "Bones", "Kilo", "Zeke", "Rook", "Vince", "Echo" }
local LINES = {
	friendly = { "You good, fam.", "Anybody bothers you round here, they deal with us.", "Respect.", "Our block, your block." },
	neutral = { "Who's this?", "Keep walking.", "You lost?" },
	hostile = { "That's them! Get 'em!", "You got a lot of nerve coming round here.", "Wrong block!", "We heard about you." },
	hit = { "Word came down from inside. Nothing personal.", "You should've stayed locked up.", "This is for my people." },
}

local function pick<T>(list: { T }): T
	return list[math.random(1, #list)]
end

local function notice(player: Player, text: string)
	local folder = ReplicatedStorage:FindFirstChild("PrisonSociety")
	local re = folder and folder:FindFirstChild("Notice")
	if re and re:IsA("RemoteEvent") then
		re:FireClient(player, text)
	end
end

local function economy(action: string, player: Player, amount: number?): any
	local fn = ServerStorage:FindFirstChild("Economy")
	if not fn or not fn:IsA("BindableFunction") then
		return nil
	end
	local ok, res = pcall(function()
		return fn:Invoke(action, player, amount)
	end)
	return ok and res
end

local function getRep(player: Player, key: string): number
	return tonumber(player:GetAttribute("Rep_" .. key)) or 0
end

local function addRep(player: Player, key: string, delta: number, why: string?)
	local v = math.clamp(math.floor(getRep(player, key) + delta + 0.5), -100, 100)
	player:SetAttribute("Rep_" .. key, v)
	-- gaining with a gang costs a little with its rival (same rule as inside)
	if delta > 0 then
		local r = GANGS[key].rival
		player:SetAttribute("Rep_" .. r, math.clamp(getRep(player, r) - math.ceil(delta / 3), -100, 100))
	end
	if why then
		notice(player, ("%s %s%d respect (%s)"):format(GANGS[key].name, if delta > 0 then "+" else "", delta, why))
	end
end

local function isInmate(player: Player): boolean
	return player:GetAttribute("CustodyOwner") == "INCARCERATED" or player:GetAttribute("CustodyStage") ~= nil
end

local function feudActive(player: Player, key: string): boolean
	return (tonumber(player:GetAttribute("StreetFeud_" .. key)) or 0) > os.time()
end

local function snitchedOn(player: Player, key: string): boolean
	local s = player:GetAttribute("SnitchedOn")
	return type(s) == "string" and string.find(s, key, 1, true) ~= nil
end

-- "friendly" | "hostile" | "deadly" | "neutral"
local function standing(player: Player, key: string): string
	if player:GetAttribute("PrisonGang") == key then
		return "friendly"
	end
	local rep = getRep(player, key)
	if feudActive(player, key) or snitchedOn(player, key) or rep <= CFG.DeadlyRep then
		return "deadly"
	end
	if rep <= CFG.HostileRep then
		return "hostile"
	end
	if player:GetAttribute("PrisonGang") == GANGS[key].rival and rep <= CFG.RivalHostileRep then
		return "hostile"
	end
	if rep >= CFG.FriendlyRep then
		return "friendly"
	end
	return "neutral"
end

---------------------------------------------------------------------------
-- saving
---------------------------------------------------------------------------
local store: DataStore? = nil
pcall(function()
	store = DataStoreService:GetDataStore("LasVegas_Gangs_v1")
end)
local loaded: { [Player]: boolean } = {}

local function load(player: Player)
	if not store then
		return
	end
	local data, ok = nil, false
	for attempt = 1, 3 do
		ok = pcall(function()
			data = (store :: DataStore):GetAsync("u" .. player.UserId)
		end)
		if ok then
			break
		end
		task.wait(2 * attempt)
	end
	if not ok then
		warn(("[StreetGangs] couldn't load %s's gang standing - not saving it this session"):format(player.Name))
		return
	end
	if type(data) == "table" then
		for _, name in SAVED do
			local v = data[name]
			if v ~= nil then
				player:SetAttribute(name, v)
			end
		end
	end
	loaded[player] = true
	print(("[StreetGangs] %s standing loaded (%s)"):format(player.Name, if type(data) == "table" then "saved data" else "new"))
end

local function save(player: Player)
	if not store or not loaded[player] then
		return
	end
	local data = {}
	for _, name in SAVED do
		local v = player:GetAttribute(name)
		if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
			data[name] = v
		end
	end
	pcall(function()
		(store :: DataStore):SetAsync("u" .. player.UserId, data)
	end)
end

---------------------------------------------------------------------------
-- territories (Workspace.CityMap, ZoneType TerritoryEK ...)
---------------------------------------------------------------------------
type Turf = { key: string, name: string, poly: { Vector3 }, center: Vector3, minY: number, maxY: number }
local turfs: { Turf } = {}

local function pointInPoly(x: number, z: number, poly: { Vector3 }): boolean
	local inside = false
	local j = #poly
	for i = 1, #poly do
		local a, b = poly[i], poly[j]
		if ((a.Z > z) ~= (b.Z > z)) and (x < (b.X - a.X) * (z - a.Z) / (b.Z - a.Z) + a.X) then
			inside = not inside
		end
		j = i
	end
	return inside
end

local function loadTurfs()
	table.clear(turfs)
	local map = Workspace:FindFirstChild("CityMap")
	local zones = map and map:FindFirstChild("Zones")
	if not zones then
		return
	end
	for _, z in zones:GetChildren() do
		local zt = tostring(z:GetAttribute("ZoneType") or z:GetAttribute("Category") or "")
		local key = string.match(zt, "^Territory(%u%u)$")
		local cp = z:FindFirstChild("ControlPoints")
		if key and GANGS[key] and cp then
			local poly = {}
			for _, p in cp:GetChildren() do
				if p:IsA("BasePart") then
					table.insert(poly, p.Position)
				end
			end
			if #poly >= 3 then
				local c = Vector3.zero
				for _, p in poly do c += p end
				c /= #poly
				local bottom = tonumber(z:GetAttribute("BottomY")) or (c.Y - 10)
				table.insert(turfs, { key = key, name = z.Name, poly = poly, center = c, minY = bottom - 20,
					maxY = (tonumber(z:GetAttribute("TopY")) or (bottom + 40)) + 20 })
			end
		end
	end
end

-- v251b: until territories are mapped, each gang claims a neighbourhood around
-- existing buildings (the apartment projects, the houses, the trailer park, the motel).
-- Mapped TerritoryXX zones replace all of these.
local DEFAULT_TURFS = {
	{ key = "EK", anchor = "Apartments", center = Vector3.new(2350, 0, 1050), half = 260 },
	{ key = "IS", anchor = "Houses", center = Vector3.new(242, 0, -1932), half = 280 },
	{ key = "DS", anchor = "Trailers", center = Vector3.new(3857, 0, 1513), half = 200 },
	{ key = "TL", anchor = "MotelRooms", center = Vector3.new(1660, 0, -2187), half = 160 },
}

local function defaultTurfs()
	for _, d in DEFAULT_TURFS do
		local anchor = Workspace:FindFirstChild(d.anchor)
		if anchor and anchor:IsA("Model") then
			local cf = anchor:GetBoundingBox()
			local c, h = Vector3.new(d.center.X, cf.Position.Y, d.center.Z), d.half
			local poly = { c + Vector3.new(-h, 0, -h), c + Vector3.new(h, 0, -h), c + Vector3.new(h, 0, h), c + Vector3.new(-h, 0, h) }
			table.insert(turfs, { key = d.key, name = d.anchor .. " (default turf)", poly = poly, center = c,
				minY = c.Y - 80, maxY = c.Y + 120 })
		end
	end
end

local function turfAt(pos: Vector3): Turf?
	for _, t in turfs do
		if pos.Y >= t.minY and pos.Y <= t.maxY and pointInPoly(pos.X, pos.Z, t.poly) then
			return t
		end
	end
	return nil
end

local function groundAt(x: number, z: number, fromY: number): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	local folder = Workspace:FindFirstChild("StreetGangMembers")
	if folder then table.insert(ignore, folder) end
	params.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(Vector3.new(x, fromY + 60, z), Vector3.new(0, -200, 0), params)
	return hit and hit.Position
end

local function randomPointIn(t: Turf): Vector3?
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in t.poly do
		minX, maxX, minZ, maxZ = math.min(minX, p.X), math.max(maxX, p.X), math.min(minZ, p.Z), math.max(maxZ, p.Z)
	end
	for _ = 1, 20 do
		local x, z = minX + math.random() * (maxX - minX), minZ + math.random() * (maxZ - minZ)
		if pointInPoly(x, z, t.poly) then
			local g = groundAt(x, z, t.center.Y)
			if g and g.Y < t.center.Y + 8 then -- street level, not a rooftop
				return g
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- members
---------------------------------------------------------------------------
type Member = { model: Model, hum: Humanoid, root: BasePart, gang: string, turf: Turf?, name: string,
	target: Player?, lethal: boolean, nextHit: number, nextWander: number, hitCrew: boolean?, expires: number? }
local members: { [Model]: Member } = {}
local folder = Instance.new("Folder")
folder.Name = "StreetGangMembers"
folder.Parent = Workspace

local function templates(): { Model }
	local out = {}
	local f = ServerStorage:FindFirstChild("CivilianTemplates")
	if f then
		for _, m in f:GetChildren() do
			if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
				table.insert(out, m)
			end
		end
	end
	return out
end

local function bandana(model: Model, key: string)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local p = Instance.new("Part")
	p.Name = "GangBandana"
	p.Size = Vector3.new(head.Size.X * 1.04, head.Size.Y * 0.26, head.Size.Z * 1.06)
	p.Color = GANGS[key].color
	p.Material = Enum.Material.Fabric
	p.CanCollide, p.CanTouch, p.CanQuery, p.Massless = false, false, false, true
	p.CFrame = head.CFrame * CFrame.new(0, head.Size.Y * 0.24, 0)
	local w = Instance.new("WeldConstraint")
	w.Part0, w.Part1 = head, p
	w.Parent = p
	p.Parent = head
end

local function say(model: Model, text: string)
	local head = model:FindFirstChild("Head")
	if not head then
		return
	end
	local old = head:FindFirstChild("StreetBubble")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "StreetBubble"
	gui.Size = UDim2.fromOffset(200, 40)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.MaxDistance = 60
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundColor3 = Color3.new(1, 1, 1)
	l.TextColor3 = Color3.new(0.1, 0.1, 0.1)
	l.TextScaled = true
	l.Font = Enum.Font.GothamMedium
	l.Text = text
	l.Parent = gui
	gui.Parent = head
	task.delay(4, function()
		gui:Destroy()
	end)
end

local onMemberDied: (Member) -> () -- forward
local jobFor: (Player, Member) -> () -- forward
local watchDamage: (Member) -> () -- forward

local function spawnMember(key: string, at: Vector3, turf: Turf?): Member?
	local list = templates()
	if #list == 0 then
		return nil
	end
	local model = pick(list):Clone()
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not hum or not root or not root:IsA("BasePart") then
		model:Destroy()
		return nil
	end
	local name = pick(NAMES)
	model.Name = "StreetGang_" .. key
	model:SetAttribute("StreetGang", key)
	model:SetAttribute("CityCivilian", nil)
	hum.DisplayName = "[" .. key .. "] " .. name
	hum.WalkSpeed = 14
	model:PivotTo(CFrame.new(at + Vector3.new(0, 3, 0)))
	model.Parent = folder
	bandana(model, key)
	local m: Member = { model = model, hum = hum, root = root, gang = key, turf = turf, name = name, target = nil,
		lethal = false, nextHit = 0, nextWander = 0 }
	members[model] = m
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StreetTalk"
	prompt.ActionText = "Talk"
	prompt.ObjectText = name .. " · " .. GANGS[key].name
	prompt.KeyboardKeyCode = Enum.KeyCode.T
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(player)
		jobFor(player, m)
	end)
	hum.Died:Connect(function()
		onMemberDied(m)
	end)
	watchDamage(m)
	return m
end

-- who killed a member (WeaponsServer tags "creator" / LastDamagerUserId, our punches tag too)
local function killerOf(hum: Humanoid): Player?
	local tag = hum:FindFirstChild("creator")
	local v = tag and tag:IsA("ObjectValue") and tag.Value
	if v and v:IsA("Player") then
		return v
	end
	local uid = tonumber(hum:GetAttribute("LastDamagerUserId"))
	local at = tonumber(hum:GetAttribute("LastDamagedAt")) or 0
	if uid and os.time() - at <= 30 then
		return Players:GetPlayerByUserId(uid)
	end
	return nil
end

onMemberDied = function(m: Member)
	members[m.model] = nil
	local killer = killerOf(m.hum)
	if killer then
		addRep(killer, m.gang, -40, "killed one of theirs")
		killer:SetAttribute("StreetFeud_" .. m.gang, os.time() + CFG.FeudSeconds)
		notice(killer, "The " .. GANGS[m.gang].name .. " want you dead")
		local rc = ServerStorage:FindFirstChild("ReportCrime")
		if rc and rc:IsA("BindableFunction") then
			pcall(function()
				rc:Invoke(killer, "Murder", 2)
			end)
		end
		print(("[StreetGangs] %s killed %s (%s) - feud %ds"):format(killer.Name, m.name, m.gang, CFG.FeudSeconds))
		-- the crew nearby comes for the killer
		for _, o in members do
			if o.gang == m.gang and (o.root.Position - m.root.Position).Magnitude < 90 then
				o.target, o.lethal = killer, true
			end
		end
	end
	task.delay(8, function()
		if m.model.Parent then
			m.model:Destroy()
		end
	end)
	-- a replacement shows up on the turf later
	if m.turf and not m.hitCrew then
		local turf = m.turf
		task.delay(90, function()
			local at = randomPointIn(turf)
			if at then
				spawnMember(turf.key, at, turf)
			end
		end)
	end
end

---------------------------------------------------------------------------
-- street jobs (friendly gangs): run a package to a drop point in time
---------------------------------------------------------------------------
local jobs: { [Player]: { gang: string, drop: BasePart, deadline: number, pay: number } } = {}

local function endJob(player: Player, ok: boolean)
	local j = jobs[player]
	if not j then
		return
	end
	jobs[player] = nil
	if j.drop.Parent then
		j.drop:Destroy()
	end
	if ok then
		economy("AddDirtyCash", player, j.pay) -- v255: dirty
		addRep(player, j.gang, 6, "street job done")
		notice(player, ("Drop made - $%d"):format(j.pay))
	else
		addRep(player, j.gang, -5, "blew the job")
	end
	print(("[StreetGangs] JOB %s %s"):format(player.Name, if ok then "DONE" else "FAILED"))
end

jobFor = function(player: Player, m: Member)
	if isInmate(player) or m.hum.Health <= 0 then
		return
	end
	local st = standing(player, m.gang)
	if st == "hostile" or st == "deadly" then
		say(m.model, pick(LINES.hostile))
		m.target, m.lethal = player, st == "deadly"
		return
	end
	if st == "neutral" then
		say(m.model, pick({ "I don't know you.", "Earn some respect first.", "We ain't got nothing for strangers." }))
		return
	end
	if jobs[player] then
		say(m.model, "You already got something to drop. Go.")
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	-- a drop 300-700 studs away, on the ground
	local drop: Vector3? = nil
	for _ = 1, 15 do
		local ang = math.random() * math.pi * 2
		local dist = 300 + math.random() * 400
		local x, z = root.Position.X + math.cos(ang) * dist, root.Position.Z + math.sin(ang) * dist
		local g = groundAt(x, z, root.Position.Y + 40)
		if g and math.abs(g.Y - root.Position.Y) < 60 then
			drop = g
			break
		end
	end
	if not drop then
		say(m.model, "Nothing right now. Come back later.")
		return
	end
	local beacon = Instance.new("Part")
	beacon.Name = "GangDrop"
	beacon.Size = Vector3.new(4, 0.4, 4)
	beacon.Anchored, beacon.CanCollide, beacon.CanQuery = true, false, false
	beacon.Material = Enum.Material.Neon
	beacon.Color = GANGS[m.gang].color
	beacon.Transparency = 0.3
	beacon.CFrame = CFrame.new(drop + Vector3.new(0, 0.2, 0))
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 30)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundTransparency = 0.3
	l.BackgroundColor3 = Color3.new(0, 0, 0)
	l.TextColor3 = GANGS[m.gang].color
	l.TextScaled = true
	l.Font = Enum.Font.GothamBold
	l.Text = "DROP"
	l.Parent = gui
	gui.Parent = beacon
	beacon.Parent = folder
	local pay = math.random(CFG.JobPay[1], CFG.JobPay[2])
	jobs[player] = { gang = m.gang, drop = beacon, deadline = os.clock() + CFG.JobSeconds, pay = pay }
	say(m.model, "Take this to the drop. Don't get stopped.")
	notice(player, ("Job for the %s: get the package to the DROP in %d minutes ($%d)"):format(GANGS[m.gang].name, CFG.JobSeconds // 60, pay))
	print(("[StreetGangs] JOB %s for %s -> %s"):format(player.Name, m.gang, tostring(drop)))
end

---------------------------------------------------------------------------
-- behaviour
---------------------------------------------------------------------------
local lastTurf: { [Player]: string? } = {}
local nextHitCrew: { [Player]: number } = {}

local function hitPlayer(m: Member, player: Player, hum: Humanoid)
	local dmg = if m.lethal then CFG.KillDamage else CFG.PunchDamage
	if not m.lethal then
		dmg = math.min(dmg, math.max(0, hum.Health - 15)) -- a beating, not a killing
	end
	if dmg > 0 then
		hum:TakeDamage(dmg)
	end
end

local function memberStep(m: Member, now: number)
	if not m.model.Parent or m.hum.Health <= 0 then
		return
	end
	local target = m.target
	local troot: BasePart? = nil
	local thum: Humanoid? = nil
	if target then
		local c = target.Character
		thum = c and c:FindFirstChildOfClass("Humanoid")
		local r = c and c:FindFirstChild("HumanoidRootPart")
		troot = if r and r:IsA("BasePart") then r else nil
		if not target.Parent or not thum or thum.Health <= 0 or not troot or isInmate(target)
			or (troot.Position - m.root.Position).Magnitude > 220 then
			m.target, target, troot = nil, nil, nil
		end
	end
	if target and troot and thum then
		local d = (troot.Position - m.root.Position).Magnitude
		if d > CFG.PunchRange - 1 then
			m.hum:MoveTo(troot.Position)
		else
			m.hum:MoveTo(m.root.Position)
			m.root.CFrame = CFrame.lookAt(m.root.Position, Vector3.new(troot.Position.X, m.root.Position.Y, troot.Position.Z))
		end
		if d <= CFG.PunchRange and now >= m.nextHit then
			m.nextHit = now + 0.9 + math.random() * 0.4
			hitPlayer(m, target, thum)
		end
		return
	end
	if m.hitCrew then
		-- a hit crew that lost its target leaves
		if not m.expires or now > m.expires then
			m.model:Destroy()
			members[m.model] = nil
		end
		return
	end
	if now >= m.nextWander and m.turf then
		m.nextWander = now + 8 + math.random() * 10
		local p = randomPointIn(m.turf)
		if p then
			m.hum:MoveTo(p)
		end
	end
end

local function spawnHitCrew(player: Player, key: string, near: Vector3)
	for i = 1, 2 do
		local ang = math.random() * math.pi * 2
		local x, z = near.X + math.cos(ang) * 45, near.Z + math.sin(ang) * 45
		local g = groundAt(x, z, near.Y + 30)
		if g then
			local m = spawnMember(key, g, nil)
			if m then
				m.hitCrew, m.target, m.lethal, m.expires = true, player, true, os.clock() + 120
				if i == 1 then
					say(m.model, pick(LINES.hit))
				end
			end
		end
	end
	notice(player, "Something's wrong... the " .. GANGS[key].name .. " found you")
	print(("[StreetGangs] HIT CREW %s sent after %s"):format(key, player.Name))
end

local function playerStep(player: Player, now: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or not root:IsA("BasePart") or hum.Health <= 0 or isInmate(player) then
		lastTurf[player] = nil
		return
	end
	local turf = turfAt(root.Position)
	local key = turf and turf.key
	player:SetAttribute("OnTurf", key)
	if key ~= lastTurf[player] then
		lastTurf[player] = key
		if key then
			local st = standing(player, key)
			notice(player, ("%s turf - %s"):format(GANGS[key].name,
				if st == "friendly" then "you're welcome here" elseif st == "neutral" then "watch yourself"
				else "they don't like you here"))
		end
	end
	-- members who can see you react to your standing with their gang
	for _, m in members do
		if m.hitCrew or m.target or m.hum.Health <= 0 then
			continue
		end
		local d = (m.root.Position - root.Position).Magnitude
		if d > CFG.SightRange then
			continue
		end
		local st = standing(player, m.gang)
		if st == "hostile" or st == "deadly" then
			m.target, m.lethal = player, st == "deadly"
			say(m.model, pick(LINES.hostile))
			print(("[StreetGangs] %s recognised by %s (%s)"):format(player.Name, m.gang, st))
		elseif st == "friendly" and d < 25 and math.random() < 0.02 then
			say(m.model, pick(LINES.friendly))
		end
	end
	-- friendly members back you up against another gang jumping you on their turf
	if key and standing(player, key) == "friendly" then
		for _, enemy in members do
			if enemy.target == player and enemy.gang ~= key and (enemy.root.Position - root.Position).Magnitude < 50 then
				for _, ally in members do
					if ally.gang == key and not ally.target and (ally.root.Position - root.Position).Magnitude < 70 then
						ally.hum:MoveTo(enemy.root.Position)
						if (ally.root.Position - enemy.root.Position).Magnitude < CFG.PunchRange and math.random() < 0.5 then
							enemy.hum:TakeDamage(10)
						end
					end
				end
			end
		end
	end
	-- a gang that wants you dead sends a crew, anywhere in the city
	for _, k in ORDER do
		if standing(player, k) == "deadly" then
			nextHitCrew[player] = nextHitCrew[player] or (now + math.random(CFG.HitCrewEvery[1], CFG.HitCrewEvery[2]))
			if now >= nextHitCrew[player] then
				nextHitCrew[player] = now + math.random(CFG.HitCrewEvery[1], CFG.HitCrewEvery[2])
				if math.random() < CFG.HitCrewChance then
					spawnHitCrew(player, k, root.Position)
				end
			end
			break
		end
	end
	-- street job delivery
	local j = jobs[player]
	if j then
		if (root.Position - j.drop.Position).Magnitude < 8 then
			endJob(player, true)
		elseif now > j.deadline then
			endJob(player, false)
			notice(player, "Too slow - the drop's off")
		end
	end
end

-- a player hitting a member makes that crew come for them
watchDamage = function(m: Member)
	m.hum.HealthChanged:Connect(function(h)
		if h <= 0 or m.target then
			return
		end
		local attacker = killerOf(m.hum)
		if attacker then
			m.target = attacker
			addRep(attacker, m.gang, -8, "hit one of theirs")
			for _, o in members do
				if o.gang == m.gang and not o.target and (o.root.Position - m.root.Position).Magnitude < 60 then
					o.target = attacker
				end
			end
		end
	end)
end

---------------------------------------------------------------------------
-- start
---------------------------------------------------------------------------
Players.PlayerAdded:Connect(function(p)
	task.spawn(load, p)
end)
for _, p in Players:GetPlayers() do
	task.spawn(load, p)
end
Players.PlayerRemoving:Connect(function(p)
	save(p)
	loaded[p] = nil
	lastTurf[p] = nil
	nextHitCrew[p] = nil
	if jobs[p] then
		endJob(p, false)
	end
end)
game:BindToClose(function()
	for _, p in Players:GetPlayers() do
		save(p)
	end
end)
task.spawn(function()
	while true do
		task.wait(CFG.SaveEvery)
		for _, p in Players:GetPlayers() do
			task.spawn(save, p)
		end
	end
end)

task.spawn(function()
	-- CivilianServer moves the pedestrian templates into ServerStorage first
	local t0 = os.clock()
	while #templates() == 0 and os.clock() - t0 < 30 do
		task.wait(1)
	end
	loadTurfs()
	local mapped = #turfs > 0
	if not mapped then
		defaultTurfs()
	end
	local spawned = 0
	for _, t in turfs do
		for _ = 1, CFG.MembersPerTurf do
			local at = randomPointIn(t)
			local m = at and spawnMember(t.key, at, t)
			if m then
				spawned += 1
			end
		end
	end
	print(("[StreetGangs] v%d: %d territor%s (%s), %d member(s)"):format(VERSION, #turfs, if #turfs == 1 then "y" else "ies",
		if mapped then "mapped" else "default neighbourhoods - map City > TerritoryEK/IS/DS/TL to replace them", spawned))
	for _, t in turfs do
		print(("[StreetGangs]   %s: %s"):format(GANGS[t.key].name, t.name))
	end
	while true do
		local now = os.clock()
		for _, m in members do
			memberStep(m, now)
		end
		for _, p in Players:GetPlayers() do
			playerStep(p, now)
		end
		task.wait(0.4)
	end
end)
