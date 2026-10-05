--[[
	CityLife.News (v280-v282) - Channel 8 News (spec 16)

	STORIES (v280) - automatic, into the phone News app: pursuits, bank jobs, officers killed,
	  warrants / BOLOs / manhunts, arrests after a chase, escapes, court (charged, plea, verdict,
	  sentence, appeal), executions, corruption (DAVID, Elite Representation), jury tampering,
	  plate rings, offshore networks... Newsworthiness sets the level:
	    1 ticker line . 2 article . 3 BREAKING (banner for everyone, crews, live)
	  Repeats escalate into running stories ("third bank robbery this hour").
	  Being in the news raises your FAME - and fame raises recognition (Recognition reads it).
	  Coverage raises underground scrutiny (Underground listens).
	CREWS (v281) - a news van (dish, reporter, camera operator) parks near the scene, the
	  courthouse or the prison; the news helicopter orbits pursuits from a safe distance.
	  Shooting at a crew is a crime (the police watch every humanoid) and makes headlines.
	LIVE (v282) - "WATCH LIVE" in the News app: the client's auto-director cuts between the
	  helicopter orbit, a ground camera, the reporter's shoulder, low and long-lens angles, or
	  the courtroom cameras, with the LIVE bug, a ticker and lower-thirds.
	Logs: [News]
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local N = {}
local Core: any

local CFG = {
	MaxStories = 40,
	RunningWindow = 30 * 60,
	CrewDelay = { 15, 30 },
	CrewLinger = 150,
	HeliRadius = 115,
	HeliHeight = 85,
	LiveMax = 6 * 60,
	FameDecayEvery = 20 * 60,
}

N.stories = {} :: { any }
N.live = nil :: any
local nextId = 0
local recentKinds: { [string]: { number } } = {}
local crewFolder: Folder
local lastPursuitLevel: { [Player]: number } = {}

local ORDINAL = { "", "Second", "Third", "Fourth", "Fifth", "Sixth" }

local function snapshot(s: any): any
	return { id = s.id, headline = s.headline, body = s.body, level = s.level, kind = s.kind, at = s.at, live = s.live == true,
		subjects = s.subjectIds, place = s.place }
end

-- spec = { headline, body, level 1-3, kind, subjects = { Player }?, pos?, live? }
function N.post(spec: any): any
	local now = os.time()
	-- the same headline twice in a minute is one story
	for _, s in N.stories do
		if s.headline == spec.headline and now - s.at < 60 then return s end
	end
	local kind = spec.kind or "general"
	local list = recentKinds[kind] or {}
	recentKinds[kind] = list
	local fresh = {}
	for _, t in list do if now - t < CFG.RunningWindow then table.insert(fresh, t) end end
	table.insert(fresh, now)
	recentKinds[kind] = fresh
	local headline = spec.headline
	if #fresh >= 2 and (kind == "bankjob" or kind == "pursuit" or kind == "copkilled" or kind == "escape" or kind == "robbery") then
		headline = ("%s %s this hour: %s"):format(ORDINAL[math.min(#fresh, #ORDINAL)] or "Another", kind == "bankjob" and "bank robbery" or kind, headline)
	end
	nextId += 1
	local s = {
		id = nextId, headline = headline, body = spec.body or "", level = math.clamp(spec.level or 1, 1, 3), kind = kind, at = now,
		live = spec.live == true, place = spec.pos and Core.placeName(spec.pos) or spec.place,
		subjectIds = {},
	}
	for _, p in spec.subjects or {} do
		if typeof(p) == "Instance" and p:IsA("Player") then
			table.insert(s.subjectIds, p.UserId)
			-- elite clients' stories get buried: softened to a ticker line
			if p:GetAttribute("EliteQuiet") and s.level > 1 and kind ~= "corruption" then
				s.level = 1
				s.body = "Details were not released."
			end
			local prof = Core.Profile.peek(p)
			if prof then
				prof.news.fame = math.min(20, (prof.news.fame or 0) + s.level)
				Core.Profile.dirty(p)
			end
		end
	end
	table.insert(N.stories, 1, s)
	while #N.stories > CFG.MaxStories do table.remove(N.stories) end
	Core.fireAll("news", snapshot(s))
	if s.level >= 3 then Core.fireAll("breaking", s.headline) end
	Core.log("News", "L%d %s%s", s.level, s.headline, if s.place then " (" .. s.place .. ")" else "")
	Core.emit("coverage", s, spec.subjects or {}, spec.live == true)
	return s
end

---------------------------------------------------------------------------
-- crews
---------------------------------------------------------------------------
local function part(props: any, parent: Instance): BasePart
	local p = Instance.new(props.Class or "Part")
	props.Class = nil
	for k, v in props do (p :: any)[k] = v end
	p.Anchored = true
	p.CanCollide = props.CanCollide == true
	p.Parent = parent
	return p :: BasePart
end
local function logo(p: BasePart, face: Enum.NormalId, text: string)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.CanvasSize = Vector2.new(400, 160)
	g.Parent = p
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = Color3.fromRGB(200, 20, 30)
	l.Text = text
	l.Parent = g
end

local function roadNear(pos: Vector3, minD: number, maxD: number): Vector3?
	local rn = workspace:FindFirstChild("RoadNetwork")
	if not rn then return nil end
	local best, bd = nil, math.huge
	for _, road in rn:GetChildren() do
		for _, n in road:GetChildren() do
			if n:IsA("BasePart") then
				local d = (n.Position - pos).Magnitude
				if d >= minD and d <= maxD and d < bd then best, bd = n.Position, d end
			end
		end
	end
	return best
end

local function npc(name: string, at: CFrame, shirt: Color3): Model?
	local ok, m = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		local skin = ({ Color3.fromRGB(234, 184, 146), Color3.fromRGB(161, 108, 72), Color3.fromRGB(245, 205, 175) })[math.random(1, 3)]
		desc.HeadColor, desc.LeftArmColor, desc.RightArmColor, desc.LeftLegColor, desc.RightLegColor = skin, skin, skin, skin, skin
		desc.TorsoColor = shirt
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not m then return nil end
	m.Name = name
	m:PivotTo(at)
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart
	if root then root.Anchored = true end
	local hum = m:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayName = name
		hum.Died:Connect(function()
			-- who did it (most weapon kits tag the victim)
			local tag = hum:FindFirstChild("creator")
			local killer = tag and tag:IsA("ObjectValue") and tag.Value
			N.post({ kind = "press", level = 3, headline = "Channel 8 news crew attacked on live television",
				body = "Our crew was hit while covering a story. Police are looking for the shooter.", subjects = if killer and killer:IsA("Player") then { killer } else nil })
			if killer and killer:IsA("Player") then Core.report(killer, "AssaultOnPress", root and root.Position) end
		end)
	end
	m.Parent = crewFolder
	return m
end

-- a van with a dish, a reporter and a camera operator, parked near pos facing it
function N.van(pos: Vector3): Model?
	local spot = roadNear(pos, 45, 160)
	if not spot then spot = pos + Vector3.new(50, 0, 0) end
	local ground = workspace:Raycast(spot + Vector3.new(0, 40, 0), Vector3.new(0, -100, 0))
	local gy = if ground then ground.Position.Y else spot.Y
	local look = Vector3.new(pos.X - spot.X, 0, pos.Z - spot.Z)
	if look.Magnitude < 1 then look = Vector3.new(1, 0, 0) end
	look = look.Unit
	local side = Vector3.new(-look.Z, 0, look.X)
	local base = CFrame.lookAt(Vector3.new(spot.X, gy, spot.Z), Vector3.new(spot.X, gy, spot.Z) + side) -- parked side-on to the scene
	local m = Instance.new("Model")
	m.Name = "NewsVan"
	local body = part({ Name = "Body", Size = Vector3.new(6.4, 6, 14), CFrame = base * CFrame.new(0, 3.6, 0), Color = Color3.fromRGB(240, 240, 240), Material = Enum.Material.SmoothPlastic, CanCollide = true }, m)
	part({ Name = "Cab", Size = Vector3.new(6.2, 3, 3.5), CFrame = base * CFrame.new(0, 2.1, -8.6), Color = Color3.fromRGB(235, 235, 235), CanCollide = true }, m)
	part({ Name = "Windshield", Size = Vector3.new(5.6, 2, 0.2), CFrame = base * CFrame.new(0, 3.7, -10.2), Color = Color3.fromRGB(30, 40, 50), Material = Enum.Material.Glass, Transparency = 0.2 }, m)
	part({ Name = "Stripe", Size = Vector3.new(6.5, 1, 14.1), CFrame = base * CFrame.new(0, 2.2, 0), Color = Color3.fromRGB(190, 20, 30) }, m)
	for _, z in { -8, 4.5 } do
		for _, x in { -3.1, 3.1 } do
			part({ Class = "Part", Name = "Wheel", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1, 2.4, 2.4), CFrame = base * CFrame.new(x, 1.2, z), Color = Color3.fromRGB(25, 25, 25) }, m)
		end
	end
	part({ Name = "Mast", Shape = Enum.PartType.Cylinder, Size = Vector3.new(9, 0.4, 0.4), CFrame = base * CFrame.new(0, 11, 3) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(160, 160, 160) }, m)
	local dish = part({ Name = "Dish", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 4.4, 4.4), CFrame = base * CFrame.new(0, 15.2, 3) * CFrame.Angles(0, math.rad(90), math.rad(35)), Color = Color3.fromRGB(245, 245, 245) }, m)
	dish.Name = "Dish"
	logo(body, Enum.NormalId.Left, "8 NEWS")
	logo(body, Enum.NormalId.Right, "8 NEWS")
	m.PrimaryPart = body
	m.Parent = crewFolder
	local standAt = base.Position + look * 9 + Vector3.new(0, 3, 0)
	local reporter = npc("Channel 8 Reporter", CFrame.lookAt(standAt, standAt - look), Color3.fromRGB(30, 50, 110))
	local camAt = standAt - look * 6
	local camera = npc("Camera Operator", CFrame.lookAt(camAt + side * 1.5, standAt), Color3.fromRGB(40, 40, 40))
	if camera then
		local cam = part({ Name = "NewsCamera", Size = Vector3.new(0.8, 1, 2), Color = Color3.fromRGB(20, 20, 20) }, camera)
		local head = camera:FindFirstChild("Head") :: BasePart?
		if head then cam.CFrame = head.CFrame * CFrame.new(0.9, 0.2, -0.6) end
	end
	if reporter then reporter:SetAttribute("NewsReporter", true) end
	m:SetAttribute("Scene", pos)
	return m, reporter, camera
end

-- the helicopter that orbits a subject or a point
local function heli(origin: Vector3): Model
	local m = Instance.new("Model")
	m.Name = "NewsChopper"
	local body = part({ Name = "Body", Shape = Enum.PartType.Ball, Size = Vector3.new(7, 7, 7), CFrame = CFrame.new(origin), Color = Color3.fromRGB(240, 240, 245) }, m)
	part({ Name = "Cabin", Size = Vector3.new(5.6, 4.4, 7), CFrame = CFrame.new(origin + Vector3.new(0, -0.3, 1.6)), Color = Color3.fromRGB(240, 240, 245) }, m)
	part({ Name = "Glass", Shape = Enum.PartType.Ball, Size = Vector3.new(6, 5, 5), CFrame = CFrame.new(origin + Vector3.new(0, 0.3, -2.2)), Color = Color3.fromRGB(40, 60, 80), Material = Enum.Material.Glass, Transparency = 0.25 }, m)
	part({ Name = "Boom", Size = Vector3.new(1, 1, 11), CFrame = CFrame.new(origin + Vector3.new(0, 0.6, 9.5)), Color = Color3.fromRGB(200, 20, 30) }, m)
	part({ Name = "Fin", Size = Vector3.new(0.3, 3, 1.6), CFrame = CFrame.new(origin + Vector3.new(0, 1.8, 14.6)), Color = Color3.fromRGB(200, 20, 30) }, m)
	part({ Name = "Rotor", Size = Vector3.new(22, 0.2, 1), CFrame = CFrame.new(origin + Vector3.new(0, 4.4, 0)), Color = Color3.fromRGB(30, 30, 30) }, m)
	part({ Name = "Rotor2", Size = Vector3.new(1, 0.2, 22), CFrame = CFrame.new(origin + Vector3.new(0, 4.4, 0)), Color = Color3.fromRGB(30, 30, 30) }, m)
	for _, x in { -2.4, 2.4 } do
		part({ Name = "Skid", Size = Vector3.new(0.3, 0.3, 8), CFrame = CFrame.new(origin + Vector3.new(x, -4.2, 1)), Color = Color3.fromRGB(60, 60, 60) }, m)
	end
	logo(body :: BasePart, Enum.NormalId.Left, "NEWS 8")
	logo(body :: BasePart, Enum.NormalId.Right, "NEWS 8")
	m.PrimaryPart = body
	m.Parent = crewFolder
	return m
end

---------------------------------------------------------------------------
-- live coverage
---------------------------------------------------------------------------
local function liveInfo(): any?
	local L = N.live
	if not L then return nil end
	return { id = L.id, headline = L.headline, subject = L.subject and L.subject.UserId, pos = L.pos, heli = L.heli, van = L.van, reporter = L.reporter,
		court = L.court == true, at = L.at }
end
function N.endLive(why: string)
	local L = N.live
	if not L then return end
	N.live = nil
	Core.fireAll("live", nil)
	Core.log("News", "LIVE ended: %s", why)
	task.delay(CFG.CrewLinger, function()
		for _, m in { L.heli, L.van, L.reporter, L.camera } do
			if m and m.Parent then m:Destroy() end
		end
	end)
end
-- spec = { headline, subject = Player?, pos, court? }
function N.goLive(spec: any)
	if N.live then
		if N.live.subject == spec.subject and spec.subject then return end
		N.endLive("a bigger story")
	end
	local L = { id = os.clock(), headline = spec.headline, subject = spec.subject, pos = spec.pos, court = spec.court, at = os.time() }
	N.live = L
	Core.fireAll("live", liveInfo())
	Core.log("News", "LIVE: %s", spec.headline)
	if spec.court then return end
	-- crews arrive after the action starts (v291: already on the scene for a perp walk - quick)
	task.delay(if spec.quick then math.random(2, 5) else math.random(CFG.CrewDelay[1], CFG.CrewDelay[2]), function()
		if N.live ~= L then return end
		local where = L.pos
		if L.subject and Core.root(L.subject) then where = (Core.root(L.subject) :: BasePart).Position end
		if not where then return end
		local station = workspace:FindFirstChild("NewsStation")
		local origin = where + Vector3.new(300, CFG.HeliHeight + 40, 300)
		if station and station:IsA("Model") then origin = station:GetPivot().Position + Vector3.new(0, 60, 0) end
		L.heli = heli(origin)
		local okV, van, rep, cam = pcall(N.van, where)
		if okV then L.van, L.reporter, L.camera = van, rep, cam end
		Core.fireAll("live", liveInfo())
		-- orbit (smoothly: the server moves it every frame it can)
		task.spawn(function()
			local angle = math.random() * math.pi * 2
			local center = where
			local heliPos = origin
			local lastT = os.clock()
			while N.live == L and L.heli and L.heli.Parent do
				local now = os.clock()
				local dt = math.min(0.2, now - lastT)
				lastT = now
				if L.subject and Core.root(L.subject) then
					local target = (Core.root(L.subject) :: BasePart).Position
					center = center:Lerp(target, math.min(1, dt * 1.5))
				end
				angle += dt * 0.16
				local want = center + Vector3.new(math.cos(angle) * CFG.HeliRadius, CFG.HeliHeight, math.sin(angle) * CFG.HeliRadius)
				heliPos = heliPos:Lerp(want, math.min(1, dt * 0.6))
				local face = Vector3.new(center.X, heliPos.Y - 8, center.Z)
				local cf = CFrame.lookAt(heliPos, face) * CFrame.Angles(math.rad(-6), 0, 0)
				L.heli:PivotTo(cf)
				local r1, r2 = L.heli:FindFirstChild("Rotor") :: BasePart?, L.heli:FindFirstChild("Rotor2") :: BasePart?
				if r1 and r2 then
					local spin = CFrame.Angles(0, now * 18 % (math.pi * 2), 0)
					local hub = cf * CFrame.new(0, 4.4, 0)
					r1.CFrame = hub * spin
					r2.CFrame = hub * spin
				end
				L.pos = center
				RunService.Heartbeat:Wait()
			end
		end)
	end)
	task.delay(CFG.LiveMax, function()
		if N.live == L then N.endLive("time") end
	end)
end

---------------------------------------------------------------------------
-- the wanted board
---------------------------------------------------------------------------
local function wantedBoard(): { any }
	local out = {}
	for _, p in Players:GetPlayers() do
		local stars = Core.stars(p)
		local w = Core.Warrants.active(p)
		if stars > 0 or w then
			table.insert(out, { name = (p:GetAttribute("CharacterName") or p.DisplayName), user = p.Name, userId = p.UserId, stars = stars, warrant = w and w.reason,
				bolo = Core.Warrants.boloFor(p) and Core.Warrants.boloFor(p).text })
		end
	end
	table.sort(out, function(a, b) return (a.stars or 0) > (b.stars or 0) end)
	return out
end

---------------------------------------------------------------------------
function N.init(core: any)
	Core = core
	crewFolder = workspace:FindFirstChild("NewsCrews") :: Folder
	if not crewFolder then
		crewFolder = Instance.new("Folder")
		crewFolder.Name = "NewsCrews"
		crewFolder.Parent = workspace
	end
	Core.News = N

	Core.app("news.list", function(player: Player)
		local out = {}
		for _, s in N.stories do table.insert(out, snapshot(s)) end
		return out, liveInfo(), wantedBoard()
	end)

	-- pursuits
	Core.onStars(function(player: Player, stars: number, old: number)
		local lvl = lastPursuitLevel[player] or 0
		local r = Core.root(player)
		local pos = r and r.Position
		if stars >= 4 and lvl < 4 then
			lastPursuitLevel[player] = 4
			N.post({ kind = "pursuit", level = 3, live = true, headline = ("LIVE: Police chase %s through %s"):format((player:GetAttribute("CharacterName") or player.DisplayName), pos and Core.placeName(pos) or "the city"),
				body = ("A %d-star manhunt is underway. Police are asking the public to stay clear."):format(stars), subjects = { player }, pos = pos })
			N.goLive({ headline = "POLICE PURSUIT - " .. (player:GetAttribute("CharacterName") or player.DisplayName), subject = player, pos = pos })
		elseif stars >= 3 and lvl < 3 then
			lastPursuitLevel[player] = 3
			N.post({ kind = "pursuit", level = 2, headline = ("Police pursue suspect near %s"):format(pos and Core.placeName(pos) or "downtown"),
				body = ("Officers are chasing %s. Air support has been requested."):format((player:GetAttribute("CharacterName") or player.DisplayName)), subjects = { player }, pos = pos })
		end
	end)
	Core.onCleared(function(player: Player, reason: string)
		local lvl = lastPursuitLevel[player] or 0
		lastPursuitLevel[player] = nil
		if N.live and N.live.subject == player then N.endLive(reason) end
		if lvl < 3 then return end
		if reason == "Busted" then
			N.post({ kind = "arrest", level = 2, headline = ("%s in custody after police chase"):format((player:GetAttribute("CharacterName") or player.DisplayName)), body = "The suspect was taken to Police HQ for booking.", subjects = { player } })
		elseif reason == "Evaded" then
			N.post({ kind = "pursuit", level = 2, headline = ("%s slips away from police"):format((player:GetAttribute("CharacterName") or player.DisplayName)), body = "Police have issued a description. Anyone who sees the suspect should call 911.", subjects = { player } })
		elseif reason == "Died" then
			N.post({ kind = "pursuit", level = 2, headline = "Police chase ends in deadly shootout", body = ("%s was killed after a standoff with officers."):format((player:GetAttribute("CharacterName") or player.DisplayName)), subjects = { player } })
		end
	end)
	-- crimes
	local CRIMES = {
		BankRobbery = { 3, "bankjob", "BREAKING: Armed robbery at the bank", "Witnesses describe masked gunmen and a breached vault.", true },
		CopKilled = { 3, "copkilled", "BREAKING: Officer killed in the line of duty", "The department is in mourning. A manhunt is underway.", true },
		HelicopterDown = { 3, "copkilled", "BREAKING: Police helicopter shot down", "The aircraft went down over the city.", true },
		Murder = { 2, "murder", "Homicide investigation underway", "Police are canvassing the area.", false },
		Kidnapping = { 2, "kidnap", "Kidnapping reported", "A victim was forced into a vehicle.", false },
		Robbery = { 1, "robbery", "Armed robbery reported", nil, false },
		PrisonEscape = { 3, "escape", "BREAKING: Inmate escapes custody", "A statewide manhunt has begun.", true },
	}
	local cool: { [string]: number } = {}
	Core.onCrime(function(player: Player, crime: string, _charge: string, pos: Vector3?)
		local c = CRIMES[crime]
		if not c then return end
		local key = player.UserId .. crime
		if cool[key] and os.clock() - cool[key] < 120 then return end
		cool[key] = os.clock()
		N.post({ kind = c[2], level = c[1], headline = c[3] .. (if pos then " near " .. Core.placeName(pos) else ""), body = c[4] or "", subjects = { player }, pos = pos, live = c[5] })
		if c[5] then N.goLive({ headline = c[3], subject = player, pos = pos }) end
	end)
	-- warrants, BOLOs, tips
	Core.on("warrant", function(player: Player, w: any)
		local lvl = if (w.severity or 1) >= 3 then 2 else 1
		N.post({ kind = "warrant", level = lvl, headline = (if lvl >= 2 then "Manhunt: warrant issued for %s" else "Warrant issued for %s"):format((player:GetAttribute("CharacterName") or player.DisplayName)),
			body = ("Charge: %s. Anyone with information should contact LVPD."):format(w.reason), subjects = { player } })
	end)
	Core.on("bolo", function(b: any)
		N.post({ kind = "bolo", level = 1, headline = "Police looking for: " .. string.sub(b.text, 1, 70), pos = b.pos })
	end)
	-- court (the Court module reports every verdict)
	Core.on("court", function(player: Player, data: any)
		if data.video and data.minor then return end
		local t = data.text or "charges"
		local mins = math.floor((data.secs or 0) / 60)
		local secs = (data.secs or 0) % 60
		local sentence = ("%d:%02d"):format(mins, secs)
		local who = player:GetAttribute("CharacterName") or player.DisplayName
		-- v286v: death / life sentences, a mistrial-free bail release
		if data.death then
			N.post({ kind = "court", level = 3, headline = ("%s SENTENCED TO DEATH"):format(who),
				body = ("%s handed down the death penalty after a %s trial. Charges: %s. %s will be held on Death Row."):format(tostring(data.judge), tostring(data.trial or "short"), t, who), subjects = { player } })
			if N.live and N.live.court and N.live.subject == player then N.endLive("verdict") end
			return
		elseif data.life then
			N.post({ kind = "court", level = 3, headline = ("%s gets LIFE without parole"):format(who),
				body = ("%s: life in the State Prison. Charges: %s"):format(tostring(data.judge), t), subjects = { player } })
			if N.live and N.live.court and N.live.subject == player then N.endLive("verdict") end
			return
		elseif data.verdict == "bail" then
			N.post({ kind = "court", level = 2, headline = ("%s released on bail - trial date set"):format(who), body = "Charges: " .. t, subjects = { player } })
			if N.live and N.live.court and N.live.subject == player then N.endLive("verdict") end
			return
		end
		if data.verdict == "plea" then
			N.post({ kind = "court", level = 1, headline = ("%s pleads guilty - %s"):format((player:GetAttribute("CharacterName") or player.DisplayName), sentence), body = "Charges: " .. t, subjects = { player } })
		elseif data.verdict == "not guilty" or data.verdict == "dismissed" then
			local rich = (Core.Profile.peek(player) and (Core.Profile.peek(player) :: any).news.fame or 0) > 6
			N.post({ kind = "court", level = 2, headline = if rich then ("%s walks again"):format((player:GetAttribute("CharacterName") or player.DisplayName)) else ("%s found not guilty"):format((player:GetAttribute("CharacterName") or player.DisplayName)),
				body = ("%s presided. The defendant left the courthouse a free person."):format(tostring(data.judge)), subjects = { player } })
		else
			N.post({ kind = "court", level = if data.capital then 3 else 2, headline = ("%s GUILTY - sentenced to %s"):format((player:GetAttribute("CharacterName") or player.DisplayName), sentence),
				body = ("%s handed down the sentence after a %s trial. Charges: %s"):format(tostring(data.judge), tostring(data.trial or "short"), t), subjects = { player } })
		end
		if N.live and N.live.court and N.live.subject == player then N.endLive("verdict") end
	end)
	-- v291: THE PERP WALK - sentenced and led out of the courthouse in handcuffs to the transport.
	-- Channel 8 stays live for it (the crew is already at the courthouse), and what the defendant
	-- says to the reporter on the way to the van is the story.
	Core.hook("perpWalkStart", function(player: Player, info: any)
		local who = player:GetAttribute("CharacterName") or player.DisplayName
		if N.live and N.live.subject == player then N.endLive("perp walk") end
		N.goLive({ headline = ("LIVE: %s led out of court in handcuffs"):format(who), subject = player, pos = info.pos, quick = true })
		return true
	end)
	Core.hook("perpWalk", function(player: Player, info: any)
		local who = player:GetAttribute("CharacterName") or player.DisplayName
		local where = if info.death then "to Death Row" elseif info.life then "to serve life" else "to the prison transport"
		local level = if info.death or info.life or info.capital then 3 elseif info.big then 2 else 1
		local said = info.said
		N.post({ kind = "court", level = level, subjects = { player },
			headline = if said then ("%s, led away %s: %s"):format(who, where, said) else ("%s led away %s - head down, no comment"):format(who, where),
			body = if said then ("Asked \"%s\" as officers walked %s to the van outside the courthouse, %s said: %s"):format(tostring(info.question), who, who, said)
				else ("%s kept their head down and said nothing to reporters as officers walked them out of the courthouse."):format(who) })
		return true
	end)
	Core.on("courtStart", function(player: Player, info: any)
		if info.minor then return end
		N.post({ kind = "court", level = if info.capital then 3 else 2, live = true, headline = ("ON TRIAL: The State of Nevada v. %s"):format((player:GetAttribute("CharacterName") or player.DisplayName)),
			body = "Charges: " .. tostring(info.text), subjects = { player } })
		N.goLive({ headline = "COURTROOM: State v. " .. (player:GetAttribute("CharacterName") or player.DisplayName), subject = player, court = true })
	end)
	-- executions, escapes (PoliceSystem attributes)
	local function watch(player: Player)
		player:GetAttributeChangedSignal("CustodyPhase"):Connect(function()
			local ph = player:GetAttribute("CustodyPhase")
			if ph == "Executed" then
				N.post({ kind = "execution", level = 3, headline = ("%s executed at the state prison"):format((player:GetAttribute("CharacterName") or player.DisplayName)), body = "The sentence was carried out tonight.", subjects = { player } })
			end
		end)
	end
	for _, p in Players:GetPlayers() do watch(p) end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(p)
		lastPursuitLevel[p] = nil
		if N.live and N.live.subject == p then N.endLive("subject left") end
	end)
	-- fame fades
	task.spawn(function()
		while true do
			task.wait(CFG.FameDecayEvery)
			for _, p in Players:GetPlayers() do
				local prof = Core.Profile.peek(p)
				if prof and (prof.news.fame or 0) > 0 then
					prof.news.fame = math.max(0, math.floor(prof.news.fame * 0.85))
					Core.Profile.dirty(p)
				end
			end
		end
	end)
	print("[News] v280-v282 ready (stories, crews, live coverage)")
end

return N
