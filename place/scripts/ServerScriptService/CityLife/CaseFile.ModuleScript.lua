--[[
	CityLife.CaseFile (v286) - the facts of a case, written down as the crimes happen, so the
	court can name the defendant and pin them to a time, a place, a victim, a car.

	Every crime that counts (PoliceAI.CrimeAdded) adds an entry: the charge, where (a named
	place), when (the game clock), who was around (witnesses, a security camera at the bank /
	casinos / stores / the HQ) and the specifics:
	  car theft       the car's colour, model, plate and registered owner
	  assault/murder  the victim by name, the weapon in hand
	  on police       the officer's unit
	  shots fired     the gun
	  evading / DUI / plates / burglary ...  the car, the plate, the BAC, the house
	Plate-reader hits, traffic stops, identifications and BOLOs add to it afterwards.
	The court asks for it (CityLifeApi "caseFile"); the file closes when the case is decided.
	Logs: [CaseFile]
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local C = {}
local Core: any
local files: { [Player]: { any } } = {}
local officers: { [Player]: string } = {}

local CAMERA_PLACES = { "the bank", "the Bellagio", "Caesars Palace", "Police HQ", "the courthouse", "the gas station", "the gun store", "the hospital" }

local function clock(): string
	local t = Core.clock()
	local h = math.floor(t)
	local m = math.floor((t - h) * 60)
	local ampm = if h >= 12 then "PM" else "AM"
	local h12 = h % 12
	if h12 == 0 then h12 = 12 end
	return ("%d:%02d %s"):format(h12, m, ampm)
end

local function officerFor(player: Player): string
	if not officers[player] then
		local last = Core.fakeName():match("%s(%S+)$") or "Reyes"
		local first = string.sub(Core.fakeName(), 1, 1)
		officers[player] = ("Officer %s. %s, Unit %d"):format(first, last, math.random(4, 38))
	end
	return officers[player]
end

-- who's around: non-player humanoids and players within range of the spot
local function witnesses(pos: Vector3, except: Player): (number, string?, number?)
	local n, named, namedId = 0, nil, nil
	local seen = {}
	for _, part in workspace:GetPartBoundsInRadius(pos, 60) do
		if part.Name == "HumanoidRootPart" then
			local m = part.Parent
			if m and not seen[m] then
				seen[m] = true
				local p = Players:GetPlayerFromCharacter(m)
				if p ~= except and m:FindFirstChildOfClass("Humanoid") and not CollectionService:HasTag(m, "Police") then
					n += 1
					if p and not named then named = (p:GetAttribute("CharacterName") or p.DisplayName); namedId = p.UserId end
				end
			end
		end
	end
	return n, named, namedId -- (v290i: a real player who saw it - the detectives can ask them to testify)
end

-- the nearest other person (the victim of an assault / murder)
local function nearestPerson(pos: Vector3, except: Player): (string?, boolean)
	local best, bd, isCop = nil, 16, false
	for _, part in workspace:GetPartBoundsInRadius(pos, 16) do
		if part.Name == "HumanoidRootPart" then
			local m = part.Parent
			local hum = m and m:FindFirstChildOfClass("Humanoid")
			if hum and (not except.Character or m ~= except.Character) then
				local d = (part.Position - pos).Magnitude
				if d < bd then
					local p = Players:GetPlayerFromCharacter(m)
					local name = if p then (p:GetAttribute("CharacterName") or p.DisplayName) elseif hum.DisplayName ~= "" then hum.DisplayName else m.Name
					if name == "Resident Traffic" or name == "Humanoid" or name == "" then name = Core.fakeName() end
					best, bd, isCop = name, d, CollectionService:HasTag(m, "Police")
				end
			end
		end
	end
	return best, isCop
end

local function carText(car: Model): (string, string?)
	local d = Core.Plates.describe(car)
	local plate = d.plate or Core.Plates.ensure(car)
	local rec = plate and Core.Plates.lookup(plate)
	local owner = rec and rec.owner
	return ("a %s %s, Nevada plate %s"):format(string.lower(d.colour), d.type, tostring(plate)), owner
end

local function add(player: Player, entry: any)
	local f = files[player] or {}
	files[player] = f
	table.insert(f, entry)
	while #f > 14 do table.remove(f, 1) end
end

local function onCrime(player: Player, key: string, charge: string, pos: Vector3?)
	local r = Core.root(player)
	pos = pos or (r and r.Position)
	if not pos then return end
	local place = Core.placeName(pos)
	local n, namedWitness, witnessId = witnesses(pos, player)
	local e = { key = key, charge = charge, place = place, at = clock(), witnesses = n, witness = namedWitness, witnessId = witnessId, os = os.time() }
	for _, c in CAMERA_PLACES do
		if string.find(place, c, 1, true) then e.camera = c end
	end
	local ch = player.Character
	local tool = ch and ch:FindFirstChildOfClass("Tool")
	if tool then e.weapon = tool.Name end
	if key == "VehicleTheft" then
		-- the car they're in a moment later
		task.delay(1.5, function()
			local car = Core.seatedCar(player)
			if car then
				e.car, e.owner = carText(car)
				-- v286q: their prints are all over it, and the owner saw their face
				task.defer(function()
					e.evidence = e.evidence or {}
					if math.random() < 0.7 then table.insert(e.evidence, { kind = "prints", weight = 0.1, text = "fingerprints on the steering wheel" }) end
					if e.owner then table.insert(e.evidence, { kind = "owner", weight = 0.15, text = ("%s, the owner, who saw your face"):format(e.owner) }) end
				end)
				print(("[CaseFile] %s: %s (%s) at %s"):format(player.Name, e.car, tostring(e.owner), place))
			end
		end)
	elseif key == "Assault" or key == "Murder" or key == "AssaultOnPress" then
		e.victim = nearestPerson(pos, player)
	elseif key == "AssaultOfficer" or key == "CopKilled" then
		e.victim = officerFor(player)
		e.victimOfficer = true
		-- v286s: the officer was wearing a body camera, and was on the radio when it happened;
		-- the casings match the gun they take off you
		e.evidence = { { kind = "bodycam", weight = 0.3, text = "the body camera the officer was wearing" } }
		if e.weapon then table.insert(e.evidence, { kind = "prints", weight = 0.15, text = ("shell casings from the %s taken off you at the arrest"):format(e.weapon) }) end
		if key == "CopKilled" then table.insert(e.evidence, { kind = "witness", weight = 0.1, text = "the officer's last radio call, describing you" }) end
	elseif key == "Murder" and e.weapon then
		e.evidence = { { kind = "prints", weight = 0.12, text = ("ballistics: the bullets match the %s taken off you"):format(e.weapon) } }
	elseif key == "EvadingPolice" or key == "DUI" or key == "DrivingSuspended" or key == "PlateTheft" or key == "SuspiciousVehicle" or key == "RecklessDriving" then
		local car = Core.seatedCar(player)
		if car then e.car = carText(car) end
		if key == "DUI" then e.bac = tonumber(player:GetAttribute("DUIBAC")) end
	elseif key == "Burglary" then
		e.house = place
	end
	add(player, e)
	-- v286q: who or what caught it
	task.defer(function()
		local list = C.gather(player, pos :: Vector3, e)
		for _, x in e.evidence or {} do table.insert(list, x) end
		e.evidence = list
	end)
end

-- the file for the court: the specifics, plus the people who'll testify
---------------------------------------------------------------------------
-- v286q: the evidence that really exists - who or what could have caught it
---------------------------------------------------------------------------
local LAW_TEAMS = { LVPD = true, SWAT = true, ["Chief of Police"] = true, ["Federal Bureau of Investigation"] = true,
	["U.S. Marshal Service"] = true, USM = true, ["Homeland Security"] = true }
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
local function sees(from: Vector3, to: Vector3, ignore: { Instance }): boolean
	losParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(from, to - from, losParams)
	return hit == nil or (hit.Position - to).Magnitude < 6
end
local function gather(player: Player, pos: Vector3, e: any): { any }
	local ev = {}
	local ch = player.Character
	local target = pos + Vector3.new(0, 2, 0)
	-- dash cameras: police cars (AI or police players driving) within 120 studs, line of sight
	local pa = workspace:FindFirstChild("PoliceAI")
	local pv = pa and pa:FindFirstChild("Vehicles")
	local dash = nil
	if pv then
		for _, m in pv:GetChildren() do
			if m:IsA("Model") then
				local ok, cf = pcall(m.GetPivot, m)
				if ok and (cf.Position - pos).Magnitude < 120 and sees(cf.Position + Vector3.new(0, 3, 0), target, { m, ch :: Instance }) then dash = "a patrol car" break end
			end
		end
	end
	for _, p in Players:GetPlayers() do
		local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		local seat = h and h.SeatPart
		if not dash and p ~= player and p.Team and LAW_TEAMS[p.Team.Name] and seat and (seat.Position - pos).Magnitude < 120 then dash = (p:GetAttribute("CharacterName") or p.DisplayName) .. "'s cruiser" end
	end
	if dash then table.insert(ev, { kind = "dashcam", weight = 0.25, text = ("dash-camera video from %s"):format(dash) }) end
	-- body cameras: an officer on foot within 70 studs, line of sight
	local body = nil
	for _, m in CollectionService:GetTagged("Police") do
		local head = m:IsA("Model") and m:FindFirstChild("Head")
		if head and head:IsA("BasePart") and (head.Position - pos).Magnitude < 70 and not CollectionService:HasTag(m, "PrisonCO")
			and sees(head.Position, target, { m, ch :: Instance }) then body = "a patrol officer" break end
	end
	if not body then
		for _, p in Players:GetPlayers() do
			local r = p ~= player and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
			if r and p.Team and LAW_TEAMS[p.Team.Name] and ((r :: BasePart).Position - pos).Magnitude < 70 then body = "Officer " .. (p:GetAttribute("CharacterName") or p.DisplayName) break end
		end
	end
	if body then table.insert(ev, { kind = "bodycam", weight = 0.3, text = ("body-camera video from %s"):format(body) }) end
	-- security cameras
	if e.camera then table.insert(ev, { kind = "cctv", weight = 0.25, text = ("security footage from %s"):format(e.camera) }) end
	-- the news
	local N = Core.News
	local L = N and N.live
	if L and not L.court and ((L.subject == player) or (L.pos and (L.pos - pos).Magnitude < 250)) then
		table.insert(ev, { kind = "news", weight = 0.3, text = "Channel 8's live broadcast" })
	end
	-- people
	if e.witness then table.insert(ev, { kind = "witness", weight = 0.15, text = ("%s, who saw it happen"):format(e.witness), playerId = e.witnessId })
	elseif (e.witnesses or 0) > 0 then
		table.insert(ev, { kind = "witness", weight = 0.05 * math.min(e.witnesses, 3), text = ("%d bystander%s"):format(e.witnesses, if e.witnesses == 1 then "" else "s") })
	end
	return ev
end

-- strength of the case 0..1 from the most serious count's evidence (plus anything that links)
local function strengthOf(file: { any }): (number, any?)
	local best, bestW = nil, -1
	for _, e in file do
		if e.charge then
			local w = 0
			for _, x in e.evidence or {} do w += x.weight end
			if w > bestW then best, bestW = e, w end
		end
	end
	if not best then return 0.4, nil end
	-- a plate reader or a BOLO that ties them to it later adds a little
	local extra = 0
	for _, e in file do
		if e.key == "ALPR" or e.key == "Identified" then extra += 0.05 end
	end
	-- v286s: every other count with its own evidence makes the pattern harder to explain away
	-- (five dead officers is five cases, not one)
	local counts = 0
	for _, e in file do
		if e ~= best and e.charge and e.evidence and #e.evidence > 0 then counts += 1 end
	end
	return math.clamp(0.15 + bestW + math.min(extra, 0.15) + math.min(0.06 * counts, 0.24), 0.1, 0.97), best
end
C.gather = gather
C.strengthOf = strengthOf
function C.deed(e: any): string
	local k = e.key
	if k == "VehicleTheft" then return if e.car then ("took %s%s"):format(e.car, if e.owner then " from " .. e.owner else "") else "stole a car" end
	if k == "Assault" or k == "AssaultOnPress" or k == "AssaultOfficer" then return ("attacked %s"):format(e.victim or "someone") end
	if k == "Murder" or k == "CopKilled" then return ("killed %s"):format(e.victim or "a man") end
	if k == "ShotsFired" then return ("fired %s"):format(if e.weapon then "a " .. e.weapon else "a gun") end
	if k == "EvadingPolice" then return ("ran from the police%s"):format(if e.car then " in " .. e.car else "") end
	if k == "BankRobbery" then return "robbed the bank" end
	if k == "Robbery" then return "committed an armed robbery" end
	return "committed " .. string.lower(e.charge or "a crime")
end

-- what the lawyer tells you: what happened, what they have, what they don't, the read
local ALL_KINDS = {
	dashcam = "No dash camera caught it.", bodycam = "No officer's body camera saw it.", cctv = "No security camera covers that spot.",
	news = "The news wasn't filming.", witness = "No witness has come forward.",
}
function C.brief(file: { any }, who: string): any
	local strength, e = strengthOf(file)
	if not e then return nil end
	local have, haveKinds = {}, {}
	for _, x in e.evidence or {} do
		table.insert(have, x.text)
		haveKinds[x.kind] = true
	end
	for _, x in file do
		if x.key == "ALPR" then table.insert(have, ("a plate reader logged %s near %s at %s"):format(x.car or "the car", x.place, x.at)) end
	end
	local haveNot = {}
	for kind, line in ALL_KINDS do
		if not haveKinds[kind] then table.insert(haveNot, line) end
	end
	local read = if strength >= 0.7 then "They have you cold. A plea is the smart play - I'll get you the best number I can."
		elseif strength >= 0.45 then "It's winnable, but it's a gamble. If the offer is fair, we think hard about it."
		else "Their case is thin. I'd fight this."
	return {
		strength = strength,
		happened = ("At %s near %s, they say you %s."):format(e.at, e.place, C.deed(e)),
		have = have, haveNot = haveNot, read = read,
		evidence = e.evidence or {},
	}
end

function C.forCourt(player: Player): any
	local f = files[player]
	if not f or #f == 0 then return nil end
	local b = C.brief(f, (player:GetAttribute("CharacterName") or player.DisplayName))
	return { entries = f, officer = officerFor(player), defendant = (player:GetAttribute("CharacterName") or player.DisplayName), strength = b and b.strength, brief = b }
end

function C.init(core: any)
	Core = core
	Core.CaseFile = C
	Core.onCrime(onCrime)
	-- what else put them somewhere
	Core.on("alpr", function(car: Model, driver: Player, hits: { any })
		if not driver then return end
		local d = Core.Plates.describe(car)
		local pp = car.PrimaryPart
		add(driver, { key = "ALPR", place = pp and Core.placeName(pp.Position) or "the city", at = clock(), os = os.time(),
			car = ("a %s %s, plate %s"):format(string.lower(d.colour), d.type, tostring(d.plate)), note = hits[1] and hits[1].text })
	end)
	Core.on("identified", function(player: Player, how: string)
		local r = Core.root(player)
		add(player, { key = "Identified", how = how, place = r and Core.placeName(r.Position) or "the city", at = clock(), os = os.time() })
	end)
	Core.on("bolo", function(b: any)
		if not b.subjectId then return end
		local p = Players:GetPlayerByUserId(b.subjectId)
		if p then add(p, { key = "BOLO", note = b.text, place = b.place or "the city", at = clock(), os = os.time() }) end
	end)
	-- the case is decided: the file closes
	Core.on("court", function(player: Player, data: any)
		if type(data) == "table" and data.verdict == "bail" then return end -- v286v: out on bail, the case goes on
		files[player] = nil
		officers[player] = nil
	end)
	-- v286q: arrested within two minutes of it = caught at the scene / in the car
	Core.onCleared(function(player: Player, reason: string)
		if reason ~= "Busted" then return end
		local f = files[player]
		if not f then return end
		local inCar = Core.seatedCar(player) ~= nil
		for _, e in f do
			if e.charge and os.time() - (e.os or 0) < 120 then
				e.evidence = e.evidence or {}
				table.insert(e.evidence, { kind = "caught", weight = 0.35, text = if inCar and e.key == "VehicleTheft" then "you were arrested still in the car" else "you were arrested at the scene" })
			end
		end
	end)
	Core.hook("caseFile", function(player: Player)
		return C.forCourt(player)
	end)
	Players.PlayerRemoving:Connect(function(p) files[p] = nil officers[p] = nil end)
	print("[CaseFile] v286 ready (named, placed, timed evidence for the courts)")
end

return C
