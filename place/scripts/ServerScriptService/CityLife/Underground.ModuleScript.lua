--[[
	CityLife.Underground (v271) - underground scrutiny and cold plates (spec 13.2, 13.3)

	SCRUTINY: a hidden, server-wide heat level per trade - cold plates, fences, chop shops,
	fixers, fiduciaries. It rises with busts of people who used the trade, news coverage
	(ticker < article < breaking / live - live spikes hard), snitches and stings, and fades
	slowly. PR helps. High scrutiny: prices up, more stings, and above ~85% the contacts go
	dark for a while. One sloppy player's live-TV getaway makes it harder for everyone.

	COLD PLATES: no shop. You need a referral (Sal's introduction in Connections, or real
	standing with a prison gang, or a clean record of big jobs - never snitched). The plate
	maker ("Lenny") works from one of three hidden spots, moves every so often, and only
	deals after dark (22:00-04:00 game time). Bring the car; pay up front; the plates are
	ready 10 minutes later. Very limited stock. Cold plates come back clean everywhere - until
	they're burned (seen on a car in a crime). Lenny can be an informant.
	Logs: [Underground]
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local U = {}
local Core: any

local TRADES = { "coldplates", "fences", "chopshops", "fixers", "fiduciaries" }
local CFG = {
	DarkAt = 0.85,
	DarkFor = 10 * 60,
	DecayEvery = 120,
	Decay = 0.02,
	ColdPrice = 150000,
	MakeSeconds = 10 * 60,
	StockPerHour = 3,
	MoveEvery = 20 * 60,
	StingBase = 0.08,
}

local level: { [string]: number } = {}
local darkUntil: { [string]: number } = {}
for _, t in TRADES do level[t] = 0.1 end
local store = nil
pcall(function() store = DataStoreService:GetDataStore("LasVegas_Underground_v1") end)

local spots: { BasePart } = {}
local activeSpot = 1
local lenny: Model? = nil
local stockHour, stockUsed = -1, 0
local orders: { [number]: any } = {}

function U.level(trade: string): number
	return level[trade] or 0
end
function U.dark(trade: string?): boolean
	return trade ~= nil and (darkUntil[trade] or 0) > os.time()
end
function U.bump(trade: string, amount: number, why: string?)
	if not level[trade] then return end
	level[trade] = math.clamp(level[trade] + amount, 0, 1)
	Core.log("Underground", "%s scrutiny %.2f (+%.2f %s)", trade, level[trade], amount, why or "")
	if level[trade] >= CFG.DarkAt and not U.dark(trade) then
		darkUntil[trade] = os.time() + CFG.DarkFor
		level[trade] = 0.55
		Core.log("Underground", "%s contacts GO DARK for %ds", trade, CFG.DarkFor)
		if trade == "coldplates" then U.moveLenny() end
		if trade == "fiduciaries" and Core.Money then Core.Money.exposure() end
	end
end
function U.cool(amount: number)
	for t in level do level[t] = math.max(0, level[t] - amount) end
end
function U.priceScale(trade: string?): number
	return 1 + (if trade then level[trade] or 0 else 0)
end
-- note that a player used a trade (their busts and fame heat it up)
function U.used(player: Player, trade: string)
	local prof = Core.Profile.get(player)
	prof.underground.used = prof.underground.used or {}
	prof.underground.used[trade] = true
	Core.Profile.dirty(player)
end

---------------------------------------------------------------------------
-- the plate maker
---------------------------------------------------------------------------
local function open(): boolean
	local t = Core.clock()
	return t >= 22 or t < 4
end

local function pickSpots()
	local folder = workspace:FindFirstChild("PlateMakerSpots")
	if folder then
		for _, p in folder:GetChildren() do
			if p:IsA("BasePart") then table.insert(spots, p) end
		end
	end
	if #spots >= 3 then return end
	-- none mapped: three quiet spots off the road network, far apart
	local rn = workspace:FindFirstChild("RoadNetwork")
	if not rn then return end
	local pts = {}
	for _, road in rn:GetChildren() do
		for _, n in road:GetChildren() do
			if n:IsA("BasePart") then table.insert(pts, n.Position) end
		end
	end
	if #pts == 0 then return end
	local rng = Random.new(4242)
	folder = Instance.new("Folder")
	folder.Name = "PlateMakerSpots"
	local chosen = {}
	for _ = 1, 200 do
		if #chosen >= 3 then break end
		local p = pts[rng:NextInteger(1, #pts)]
		local far = true
		for _, c in chosen do if (c - p).Magnitude < 500 then far = false end end
		if far then table.insert(chosen, p) end
	end
	for i, p in chosen do
		local off = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
		if off.Magnitude < 0.1 then off = Vector3.new(1, 0, 0) end
		local at = p + off.Unit * 26
		local ground = workspace:Raycast(at + Vector3.new(0, 40, 0), Vector3.new(0, -100, 0))
		local part = Instance.new("Part")
		part.Name = "PlateMakerSpot" .. i
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.Transparency = 1
		part.Size = Vector3.new(4, 1, 4)
		part.Position = if ground then ground.Position + Vector3.new(0, 0.5, 0) else at
		part.Parent = folder
		table.insert(spots, part)
	end
	folder.Parent = workspace
end

function U.tip(): string
	local s = spots[activeSpot]
	if not s then return "After midnight." end
	return ("He works " .. Core.placeName(s.Position) .. ", after midnight. Don't bring company.")
end

local function lennyTalk(player: Player)
	local prof = Core.Profile.get(player)
	local u = prof.underground
	if not u.referral then
		Core.UI.notice(player, "Lenny: \"Never seen you before. Beat it.\"", 4)
		return
	end
	local order = orders[player.UserId]
	if order and os.time() >= order.ready then
		orders[player.UserId] = nil
		table.insert(prof.plates, { plate = order.plate, kind = "cold", type = order.type, colour = order.colour })
		Core.Profile.dirty(player)
		Core.UI.notice(player, ("Lenny hands over %s - made for a %s %s. No receipts."):format(order.plate, string.lower(order.colour), order.type), 7)
		Core.log("Underground", "%s collected cold plate %s", player.Name, order.plate)
		return
	elseif order then
		Core.UI.notice(player, ("Lenny: \"Not ready. Come back in %d minutes.\""):format(math.ceil((order.ready - os.time()) / 60)), 5)
		return
	end
	local car = Core.seatedCar(player)
	local sp = workspace:FindFirstChild("SpawnedCars")
	if not car and sp then
		local r = Core.root(player)
		for _, m in sp:GetChildren() do
			local o = m:FindFirstChild("Owner")
			local pp = m:IsA("Model") and m.PrimaryPart
			if o and o.Value == player and pp and r and (pp.Position - r.Position).Magnitude < 40 then car = m end
		end
	end
	if not car then
		Core.UI.notice(player, "Lenny: \"Bring the car. I don't guess.\"", 4)
		return
	end
	local hour = math.floor(os.time() / 3600)
	if hour ~= stockHour then stockHour, stockUsed = hour, 0 end
	if stockUsed >= CFG.StockPerHour then
		Core.UI.notice(player, "Lenny: \"I'm out of blanks. Next week.\"", 4)
		return
	end
	local d = Core.Plates.describe(car)
	local price = math.floor(CFG.ColdPrice * U.priceScale("coldplates"))
	local pick = Core.UI.ask(player, { title = "Lenny", body = ("\"A clean set for a %s %s. %s up front, ready in %d minutes.\""):format(string.lower(d.colour), d.type, Core.UI.money(price), CFG.MakeSeconds // 60),
		options = { "Pay him", "Walk away" }, timeout = 25 })
	if pick ~= 1 then return end
	if not Core.charge(player, price) then Core.UI.notice(player, "Lenny: \"Cash. All of it.\"", 4) return end
	stockUsed += 1
	U.used(player, "coldplates")
	-- Lenny might be wearing a wire
	if math.random() < CFG.StingBase + level.coldplates * 0.25 then
		Core.log("Underground", "COLD PLATE STING on %s", player.Name)
		Core.report(player, "Fraud", (Core.root(player) :: BasePart).Position, 30)
		Core.setStars(player, math.max(Core.stars(player), 3))
		U.bump("coldplates", 0.3, "sting")
		darkUntil.coldplates = os.time() + 20 * 60
		if lenny then lenny:Destroy() lenny = nil end
		if Core.News then Core.News.post({ kind = "plates", level = 2, headline = "Cloned-plate ring busted in police sting", body = "An undercover operation caught a buyer in the act.", subjects = { player } }) end
		return
	end
	local plate = Core.code()
	Core.Plates.register({ plate = plate, owner = Core.fakeName(), kind = "cold", type = d.type, colour = d.colour, at = os.time() - 86400 * 400 })
	orders[player.UserId] = { plate = plate, type = d.type, colour = d.colour, ready = os.time() + CFG.MakeSeconds }
	U.bump("coldplates", 0.03, "an order")
	Core.UI.notice(player, ("Lenny: \"Come back in %d minutes. Same place - if I'm still here.\""):format(CFG.MakeSeconds // 60), 6)
	Core.log("Underground", "%s ordered cold plate %s", player.Name, plate)
end

function U.moveLenny()
	if lenny then lenny:Destroy() lenny = nil end
	if #spots > 0 then activeSpot = math.random(1, #spots) end
end

local function lennyLoop()
	local s = spots[activeSpot]
	local should = s ~= nil and open() and not U.dark("coldplates")
	if should and not lenny then
		local ok, m = pcall(function()
			local desc = Instance.new("HumanoidDescription")
			local skin = Color3.fromRGB(200, 160, 130)
			desc.HeadColor, desc.LeftArmColor, desc.RightArmColor, desc.LeftLegColor, desc.RightLegColor = skin, skin, skin, skin, skin
			desc.TorsoColor = Color3.fromRGB(60, 50, 40)
			return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
		end)
		if ok and m then
			m.Name = "Lenny"
			m:PivotTo(CFrame.new((s :: BasePart).Position + Vector3.new(0, 3, 0)))
			local root = m:FindFirstChild("HumanoidRootPart") :: BasePart
			root.Anchored = true
			local hum = m:FindFirstChildOfClass("Humanoid")
			if hum then hum.DisplayName = "Lenny"; hum.NameDisplayDistance = 12 end
			local pr = Instance.new("ProximityPrompt")
			pr.ActionText = "Talk"
			pr.ObjectText = "Lenny"
			pr.MaxActivationDistance = 8
			pr.RequiresLineOfSight = false
			pr.Parent = root
			pr.Triggered:Connect(lennyTalk)
			m.Parent = workspace:FindFirstChild("CityLifeIncidents") or workspace
			lenny = m
			Core.log("Underground", "Lenny is out (%s)", Core.placeName((s :: BasePart).Position))
		end
	elseif not should and lenny then
		lenny:Destroy()
		lenny = nil
	end
end

---------------------------------------------------------------------------
function U.init(core: any)
	Core = core
	Core.Underground = U
	if store then
		local ok, data = pcall(function() return store:GetAsync("scrutiny") end)
		if ok and type(data) == "table" then
			for t, v in data do if level[t] then level[t] = math.clamp(tonumber(v) or 0.1, 0, 1) end end
		end
	end
	pickSpots()
	U.moveLenny()
	-- coverage heats the trades the subjects used
	Core.on("coverage", function(story: any, subjects: { Player }, live: boolean)
		local amount = ({ 0.01, 0.03, 0.06 })[story.level] or 0.01
		if live then amount *= 3 end
		for _, p in subjects do
			local prof = Core.Profile.peek(p)
			local used = prof and prof.underground.used
			if used then for t in used do U.bump(t, amount, "news: " .. story.headline) end end
		end
	end)
	Core.onCleared(function(player: Player, reason: string)
		if reason ~= "Busted" then return end
		local prof = Core.Profile.peek(player)
		local used = prof and prof.underground.used
		if used then for t in used do U.bump(t, 0.05, player.Name .. " busted") end end
	end)
	Core.on("snitch", function(snitch: Player)
		U.bump("fixers", 0.08, snitch.Name .. " talked")
		local prof = Core.Profile.get(snitch)
		prof.underground.referral = false
		Core.Profile.dirty(snitch)
	end)
	-- a referral from standing (a prison gang shot-caller or a clean big-job record)
	local function checkReferral(player: Player)
		local prof = Core.Profile.peek(player)
		if not prof or prof.underground.referral or player:GetAttribute("UndergroundBurned") or player:GetAttribute("SnitchJacket") then return end
		local rank = player:GetAttribute("GangRank")
		local points = tonumber(player:GetAttribute("GangPoints")) or 0
		if (type(rank) == "string" and (rank:find("Shot") or rank:find("Boss") or rank:find("Lieutenant"))) or points >= 150 then
			prof.underground.referral = true
			Core.Profile.dirty(player)
			Core.UI.notice(player, "Word gets around: someone says you can be trusted with Lenny. (" .. U.tip() .. ")", 8)
		end
	end
	-- Connections: where's the plate maker
	Core.Connections.extraLists["underground"] = function(player: Player)
		local prof = Core.Profile.get(player)
		if not prof.underground.referral then return {} end
		return { { id = "ug_lenny", cat = "Street", who = "Lenny (the plate maker)", title = "Where's Lenny tonight?",
			desc = "Cold plates, made to order. Only after midnight.", price = 0, available = not U.dark("coldplates"),
			why = if U.dark("coldplates") then "Lenny's gone quiet" else nil } }
	end
	Core.Connections.extraRun["ug_lenny"] = function(player: Player)
		local s = spots[activeSpot]
		if not s or U.dark("coldplates") then return false, "Nobody's answering" end
		Core.UI.waypoint(player, "lenny", s.Position, "?")
		return true, U.tip()
	end
	task.spawn(function()
		local lastMove = os.clock()
		local lastSave = os.clock()
		local lastDecay = os.clock()
		while true do
			task.wait(5)
			pcall(lennyLoop)
			for _, p in Players:GetPlayers() do pcall(checkReferral, p) end
			if os.clock() - lastMove > CFG.MoveEvery and not lenny then
				lastMove = os.clock()
				U.moveLenny()
			end
			if os.clock() - lastDecay > CFG.DecayEvery then
				lastDecay = os.clock()
				for t in level do level[t] = math.max(0.05, level[t] - CFG.Decay) end
			end
			if store and os.clock() - lastSave > 300 then
				lastSave = os.clock()
				task.spawn(pcall, function() store:SetAsync("scrutiny", level) end)
			end
		end
	end)
	print("[Underground] v271 ready (scrutiny, cold plates)")
end

return U
