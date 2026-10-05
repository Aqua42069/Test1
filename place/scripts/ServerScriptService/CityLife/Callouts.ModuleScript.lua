--[[
	CityLife.Callouts (v279) - dispatch offers jobs to police players (spec 15)

	Sources: real crimes (robbery in progress, shots fired, stolen vehicle, a bank job), a
	pursuit that needs backup, a warrant subject sighted (tips), and AMBIENT AI crimes when
	police players are on duty: muggings, fights, drunk drivers, stolen cars.
	Every on-duty officer gets the offer (Respond / Decline). Respond = a GPS waypoint and
	you're attached to the incident; resolving it pays (to the bank).
	Ambient suspects are NPCs: some give up, most run, a few fight. Hold "Detain" on them.
	Backup (the MDT): more units, a K9 unit, air support, a roadblock.
	Logs: [Callout]
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local C = {}
local Core: any

local CFG = {
	AmbientEvery = { 110, 210 },
	OfferTimeout = 14,
	SuspectLife = 240,
	Pay = { ambient = 350, pursuit = 500, crime = 400 },
}

local nextId = 0
C.active = {} :: { [number]: any }
local attached: { [Player]: number } = {}
local pursuitCalled: { [Player]: number } = {}
local folder: Folder

local function onDuty(): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		if Core.isLaw(p) and Core.alive(p) and p.Team and p.Team.Name ~= "Prison Staff" then table.insert(out, p) end
	end
	return out
end

local function close(id: number, why: string)
	local c = C.active[id]
	if not c then return end
	C.active[id] = nil
	for _, o in c.officers do
		if attached[o] == id then attached[o] = nil end
		if o.Parent then Core.UI.waypoint(o, "callout", nil) end
	end
	for _, m in c.models or {} do
		if m.Parent then m:Destroy() end
	end
	Core.log("Callout", "#%d closed: %s", id, why)
end

local function reward(c: any, kind: string, text: string)
	for _, o in c.officers do
		if o.Parent then
			local n = CFG.Pay[kind] or 300
			Core.pay(o, n, "bank")
			Core.UI.notice(o, ("%s  +%s"):format(text, Core.UI.money(n)), 5, Color3.fromRGB(20, 90, 40))
		end
	end
end

-- spec = { title, text, pos, kind, suspect (Player)?, ambient? }
function C.offer(spec: any): number?
	local cops = onDuty()
	if #cops == 0 then return nil end
	nextId += 1
	local id = nextId
	local c = { id = id, title = spec.title, text = spec.text, pos = spec.pos, kind = spec.kind or "crime", suspect = spec.suspect,
		officers = {}, models = spec.models or {}, at = os.clock() }
	C.active[id] = c
	Core.log("Callout", "#%d %s - %s", id, spec.title, spec.text)
	for _, cop in cops do
		if attached[cop] then
			Core.UI.notice(cop, ("DISPATCH: %s - %s"):format(spec.title, spec.text), 6, Color3.fromRGB(20, 40, 90))
			continue
		end
		task.spawn(function()
			local pick = Core.UI.ask(cop, { title = "CALLOUT: " .. spec.title, body = spec.text .. (if spec.pos then "\n" .. Core.placeName(spec.pos) else ""),
				options = { "Respond (code 3)", "Decline" }, timeout = CFG.OfferTimeout })
			if pick == 1 and C.active[id] then
				attached[cop] = id
				table.insert(c.officers, cop)
				if spec.pos then Core.UI.waypoint(cop, "callout", spec.pos, spec.title) end
				Core.UI.notice(cop, "Responding to " .. spec.title, 3)
				Core.radio(("%s responding to %s"):format(cop.Name, spec.title))
			end
		end)
	end
	task.delay(spec.life or 300, function() close(id, "expired") end)
	return id
end

---------------------------------------------------------------------------
-- ambient incidents
---------------------------------------------------------------------------
local function roadPoints(): { Vector3 }
	local out = {}
	local rn = workspace:FindFirstChild("RoadNetwork")
	if not rn then return out end
	for _, road in rn:GetChildren() do
		for _, n in road:GetChildren() do
			if n:IsA("BasePart") then table.insert(out, n.Position) end
		end
	end
	return out
end
local cachedRoads: { Vector3 }? = nil
local function spotNear(pos: Vector3, minD: number, maxD: number): Vector3?
	cachedRoads = cachedRoads or roadPoints()
	local roads = cachedRoads :: { Vector3 }
	if #roads == 0 then return nil end
	for _ = 1, 40 do
		local p = roads[math.random(1, #roads)]
		local d = (p - pos).Magnitude
		if d >= minD and d <= maxD then
			-- the pavement, not the lane
			local side = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
			if side.Magnitude > 0 then side = side.Unit * 14 end
			return p + side
		end
	end
	return nil
end

local function spawnNpc(name: string, pos: Vector3, colour: Color3?): Model?
	local ok, m = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		local skin = ({ Color3.fromRGB(234, 184, 146), Color3.fromRGB(161, 108, 72), Color3.fromRGB(105, 64, 40), Color3.fromRGB(245, 205, 175) })[math.random(1, 4)]
		desc.HeadColor, desc.LeftArmColor, desc.RightArmColor, desc.LeftLegColor, desc.RightLegColor, desc.TorsoColor = skin, skin, skin, skin, skin, colour or skin
		return game:GetService("Players"):CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not m then return nil end
	m.Name = name
	local ground = workspace:Raycast(pos + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0))
	local at = if ground then ground.Position + Vector3.new(0, 3, 0) else pos + Vector3.new(0, 3, 0)
	m:PivotTo(CFrame.new(at))
	local torso = m:FindFirstChild("UpperTorso")
	if torso and colour then (torso :: BasePart).Color = colour end
	m.Parent = folder
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then pcall(function() root:SetNetworkOwner(nil) end) end
	return m
end

-- a suspect who runs / fights until detained
local function suspectBrain(c: any, m: Model, style: string)
	local hum = m:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart
	hum.WalkSpeed = if style == "run" then 14.5 else 12
	local detained = false
	local pr = Instance.new("ProximityPrompt")
	pr.ActionText = "Detain"
	pr.ObjectText = "Suspect"
	pr.HoldDuration = 1.2
	pr.MaxActivationDistance = 8
	pr.RequiresLineOfSight = false
	pr:SetAttribute("LawOnly", true)
	pr.Parent = root
	pr.Triggered:Connect(function(who: Player)
		if detained or not Core.isLaw(who) then return end
		detained = true
		pr:Destroy()
		hum.WalkSpeed = 0
		hum.Sit = true
		if not table.find(c.officers, who) then table.insert(c.officers, who) end
		reward(c, "ambient", ("Suspect detained (%s)"):format(c.title))
		Core.log("Callout", "#%d suspect detained by %s", c.id, who.Name)
		Core.emit("calloutResolved", c, who)
		task.delay(6, function() close(c.id, "suspect detained") end)
	end)
	hum.Died:Connect(function()
		if not detained then
			detained = true
			Core.radio(("%s: suspect down"):format(c.title))
			task.delay(8, function() close(c.id, "suspect down") end)
		end
	end)
	task.spawn(function()
		local lastHit = 0
		while not detained and m.Parent and hum.Health > 0 do
			local near, nd = nil, math.huge
			for _, p in Players:GetPlayers() do
				local r = Core.isLaw(p) and Core.root(p)
				if r then
					local d = (r.Position - root.Position).Magnitude
					if d < nd then near, nd = p, d end
				end
			end
			if near and nd < 30 then
				local r = Core.root(near) :: BasePart
				if style == "fight" and nd < 7 then
					hum:MoveTo(r.Position)
					if os.clock() - lastHit > 1.4 then
						lastHit = os.clock()
						local h = near.Character and near.Character:FindFirstChildOfClass("Humanoid")
						if h then h:TakeDamage(7) end
					end
				elseif style == "run" or style == "fight" then
					local away = root.Position - r.Position
					away = Vector3.new(away.X, 0, away.Z)
					if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
					hum:MoveTo(root.Position + away.Unit * 25)
				end
			end
			task.wait(0.4)
		end
	end)
end

local AMBIENT = {
	{ title = "Mugging", text = "A caller reports a man robbing a pedestrian at knifepoint", style = "run" },
	{ title = "Fight in progress", text = "Two men fighting in the street, one is armed", style = "fight" },
	{ title = "Suspicious person", text = "Someone trying car door handles", style = "comply" },
	{ title = "Drunk driver", text = "A caller reports a car weaving across the lanes", car = "drunk" },
	{ title = "Stolen vehicle", text = "A vehicle was just reported stolen", car = "stolen" },
	{ title = "Shoplifter", text = "Store security is holding a shoplifter who keeps trying to leave", style = "run" },
}

local function ambient()
	local cops = onDuty()
	if #cops == 0 then return end
	local anchor = Core.root(cops[math.random(1, #cops)])
	if not anchor then return end
	local kind = AMBIENT[math.random(1, #AMBIENT)]
	if kind.car then
		local cars = {}
		for _, m in CollectionService:GetTagged("SmoothResidentTraffic") do
			local pp = m:IsA("Model") and m:GetAttribute("TrafficActive") and m.PrimaryPart
			if pp and (pp.Position - anchor.Position).Magnitude < 600 then table.insert(cars, m) end
		end
		if #cars == 0 then return end
		local car = cars[math.random(1, #cars)]
		local plate = Core.Plates.ensure(car)
		local rec = Core.Plates.lookup(plate)
		if kind.car == "drunk" then car:SetAttribute("DrunkDriver", true)
		elseif rec then rec.stolenAt = os.time() - 1 end
		local d = Core.Plates.describe(car)
		local pos = (car.PrimaryPart :: BasePart).Position
		local id = C.offer({ title = kind.title, text = ("%s - %s %s, plate %s"):format(kind.text, string.lower(d.colour), d.type, tostring(plate)), pos = pos, kind = "ambient", life = 240 })
		-- the waypoint follows the car for a while
		task.spawn(function()
			for _ = 1, 40 do
				task.wait(5)
				local c = id and C.active[id]
				if not c or not car.Parent then break end
				local pp = car.PrimaryPart
				if pp then
					for _, o in c.officers do Core.UI.waypoint(o, "callout", pp.Position, kind.title) end
				end
			end
		end)
		-- resolved when someone stops it (the stop module emits npcArrest)
		return
	end
	local pos = spotNear(anchor.Position, 150, 550)
	if not pos then return end
	local shirt = Color3.fromHSV(math.random(), 0.6, 0.7)
	local suspect = spawnNpc("Suspect", pos, shirt)
	if not suspect then return end
	local models = { suspect }
	if kind.title == "Fight in progress" then
		local other = spawnNpc("Bystander", pos + Vector3.new(4, 0, 0), Color3.fromRGB(200, 200, 200))
		if other then table.insert(models, other) end
	end
	local id = C.offer({ title = kind.title, text = kind.text .. " - suspect in a " .. (string.lower(BrickColor.new(shirt).Name)) .. " shirt", pos = pos, kind = "ambient", models = models, life = CFG.SuspectLife })
	if not id then
		for _, m in models do m:Destroy() end
		return
	end
	suspectBrain(C.active[id], suspect, kind.style)
end

---------------------------------------------------------------------------
-- backup
---------------------------------------------------------------------------
local function backup(officer: Player, kind: string)
	if not Core.isLaw(officer) then return false end
	local id = attached[officer]
	local c = id and C.active[id]
	local r = Core.root(officer)
	local pos = (c and c.pos) or (r and r.Position)
	if c and c.suspect and Core.root(c.suspect) then pos = (Core.root(c.suspect) :: BasePart).Position end
	if not pos then return false end
	if kind == "units" then
		local n = Core.policeFn("SpawnUnits", pos, "Officer", 3, 150)
		Core.radio(("%s requests backup - %d units en route"):format(officer.Name, tonumber(n) or 0))
	elseif kind == "k9" then
		local n = Core.policeFn("SpawnUnits", pos, "Patrol", 1, 150)
		Core.radio(officer.Name .. " requests a K9 unit - en route")
		return (tonumber(n) or 0) > 0
	elseif kind == "air" then
		if c and c.suspect and Core.stars(c.suspect) > 0 then
			Core.setStars(c.suspect, math.max(Core.stars(c.suspect), 3))
			Core.radio(officer.Name .. " requests air support on " .. c.suspect.Name .. " - the helicopter is up")
		else
			Core.radio(officer.Name .. " requests air support - denied, no active pursuit")
			Core.UI.notice(officer, "Air support needs an active pursuit", 3)
			return false
		end
	elseif kind == "roadblock" then
		C.roadblock(pos, officer)
	else
		return false
	end
	return true
end

function C.roadblock(near: Vector3, officer: Player?)
	cachedRoads = cachedRoads or roadPoints()
	local best, bd = nil, math.huge
	for _, p in cachedRoads :: { Vector3 } do
		local d = (p - near).Magnitude
		if d > 80 and d < bd then best, bd = p, d end
	end
	if not best then return end
	local model = Instance.new("Model")
	model.Name = "Roadblock"
	for i = -1, 1 do
		local b = Instance.new("Part")
		b.Name = "Barrier"
		b.Anchored = true
		b.Size = Vector3.new(8, 3.2, 1)
		b.Color = if i == 0 then Color3.fromRGB(240, 240, 240) else Color3.fromRGB(220, 40, 40)
		b.Material = Enum.Material.SmoothPlastic
		local dir = Vector3.new(1, 0, 0)
		if near ~= best then
			local f = (best - near)
			f = Vector3.new(f.X, 0, f.Z)
			if f.Magnitude > 0 then dir = Vector3.new(-f.Z, 0, f.X).Unit end
		end
		local p = best + dir * (i * 8.5) + Vector3.new(0, 1.6, 0)
		b.CFrame = CFrame.lookAt(p, p + Vector3.new(-dir.Z, 0, dir.X))
		b.Parent = model
	end
	model.Parent = folder
	Core.policeFn("SpawnUnits", best, "Officer", 2, 120)
	Core.radio(("Roadblock set up near %s"):format(Core.placeName(best)))
	if officer then Core.UI.waypoint(officer, "roadblock", best, "Roadblock") end
	task.delay(150, function()
		model:Destroy()
		if officer then Core.UI.waypoint(officer, "roadblock", nil) end
	end)
end

---------------------------------------------------------------------------
local CRIME_CALLS = {
	BankRobbery = { "Bank robbery in progress", "Alarm at the bank - multiple armed suspects" },
	Robbery = { "Armed robbery", "A store clerk reports an armed robbery" },
	ShotsFired = { "Shots fired", "Multiple callers report gunshots" },
	Murder = { "Homicide", "A body was found - the shooter fled" },
	VehicleTheft = { "Carjacking", "A driver was pulled out of their car" },
	CopKilled = { "OFFICER DOWN", "An officer has been shot - all units" },
	Burglary = { "Burglary", "A homeowner reports a break-in" },
	Kidnapping = { "Kidnapping", "A caller saw someone forced into a car" },
}
local crimeCooldown: { [string]: number } = {}

function C.init(core: any)
	Core = core
	folder = workspace:FindFirstChild("CityLifeIncidents") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CityLifeIncidents"
		folder.Parent = workspace
	end
	Core.onCrime(function(player: Player, crime: string, _charge: string, pos: Vector3?)
		local call = CRIME_CALLS[crime]
		if not call then return end
		local key = player.UserId .. crime
		if crimeCooldown[key] and os.clock() - crimeCooldown[key] < 90 then return end
		crimeCooldown[key] = os.clock()
		local p = pos or (Core.root(player) and (Core.root(player) :: BasePart).Position)
		C.offer({ title = call[1], text = call[2], pos = p, kind = "crime", suspect = player })
	end)
	Core.onStars(function(player: Player, stars: number, old: number)
		if stars >= 2 and old < 2 then
			if pursuitCalled[player] and os.clock() - pursuitCalled[player] < 120 then return end
			pursuitCalled[player] = os.clock()
			local r = Core.root(player)
			C.offer({ title = "Pursuit - backup needed", text = ("Units in pursuit of %s (%d stars)"):format((player:GetAttribute("CharacterName") or player.DisplayName), stars), pos = r and r.Position, kind = "pursuit", suspect = player, life = 240 })
		end
	end)
	-- an attached officer's suspect is busted: everyone attached gets paid
	Core.onCleared(function(player: Player, reason: string)
		if reason ~= "Busted" then return end
		for id, c in C.active do
			if c.suspect == player and #c.officers > 0 then
				reward(c, if c.kind == "pursuit" then "pursuit" else "crime", "Suspect in custody - " .. c.title)
				close(id, "suspect busted")
			end
		end
	end)
	Core.on("tip", function(player: Player, pos: Vector3)
		C.offer({ title = "Warrant subject sighted", text = ("A caller saw %s"):format((player:GetAttribute("CharacterName") or player.DisplayName)), pos = pos, kind = "crime", suspect = player, life = 180 })
	end)
	Core.on("npcArrest", function(officer: Player)
		for id, c in C.active do
			if c.kind == "ambient" and table.find(c.officers, officer) and not c.models[1] then
				reward(c, "ambient", "Callout resolved - " .. c.title)
				close(id, "driver arrested")
			end
		end
	end)
	Core.app("callout.backup", function(player: Player, kind: any)
		return backup(player, tostring(kind))
	end)
	Core.app("callout.list", function(player: Player)
		if not Core.isLaw(player) then return {} end
		local out = {}
		for id, c in C.active do
			table.insert(out, { id = id, title = c.title, text = c.text, place = c.pos and Core.placeName(c.pos), mine = attached[player] == id, officers = #c.officers })
		end
		return out
	end)
	Core.app("callout.respond", function(player: Player, id: any)
		local c = C.active[tonumber(id) or -1]
		if not c or not Core.isLaw(player) then return false end
		attached[player] = c.id
		if not table.find(c.officers, player) then table.insert(c.officers, player) end
		if c.pos then Core.UI.waypoint(player, "callout", c.pos, c.title) end
		return true
	end)
	Players.PlayerRemoving:Connect(function(p) attached[p] = nil; pursuitCalled[p] = nil end)
	task.spawn(function()
		while true do
			task.wait(math.random(CFG.AmbientEvery[1], CFG.AmbientEvery[2]))
			local ok, err = pcall(ambient)
			if not ok then warn("[Callout] ambient: " .. tostring(err)) end
		end
	end)
	Core.Callouts = C
	print("[Callout] v279 ready (dispatch callouts, ambient crimes, backup)")
end

return C
