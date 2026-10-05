--[[
	CityLife.Core (v260-v282) - shared plumbing for the CityLife systems:
	warrants, recognition, plates & DAVID, the MDT, traffic stops, callouts, Connections,
	jury tampering, the underground, Elite Representation, metals & offshore, appeals, news.

	  Core.Profile / Core.UI             saved profile (DataStore) and the shared menus / notices
	  Core.on(name, fn) / Core.emit       an event bus between the CityLife modules
	  Core.app(name, fn)                  a client request handler (ReplicatedStorage.CityLifeFn)
	  Core.fire(player, kind, ...)        server -> one client (ReplicatedStorage.CityLife)
	  Core.hook(name, fn)                 answers PoliceSystem / Court questions
	                                      (ServerStorage.CityLifeApi:Invoke(name, ...))
	  Core.isLaw / isChief / report / setStars / stars / charge / pay / radio / placeName
	Logs: [CityLife]
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Core = {}
Core.VERSION = 282
Core.Profile = require(script.Parent.Profile)
Core.UI = require(script.Parent.UI)

-- the same list PoliceSystem's Config.Law.Teams uses
Core.LAW_TEAMS = {
	["LVPD"] = true, ["SWAT"] = true, ["Federal Bureau of Investigation"] = true, ["U.S. Marshal Service"] = true,
	["USM"] = true, ["Secret Service"] = true, ["Homeland Security"] = true, ["Federal Protection Service"] = true,
	["Special Forces"] = true, ["Dept. of Justice"] = true, ["Prison Staff"] = true,
	["National Security Agency"] = true, ["Central Intelligence Agency"] = true, ["Chief of Police"] = true,
}
-- who can use DAVID / the MDT (spec 10.4: LVPD, SWAT, Marshals, FBI, Chief)
Core.MDT_TEAMS = {
	["LVPD"] = true, ["SWAT"] = true, ["Federal Bureau of Investigation"] = true, ["U.S. Marshal Service"] = true,
	["USM"] = true, ["Chief of Police"] = true, ["Dept. of Justice"] = true, ["Homeland Security"] = true,
}

---------------------------------------------------------------------------
-- remotes
---------------------------------------------------------------------------
local function remote(class: string, name: string): Instance
	local r = ReplicatedStorage:FindFirstChild(name)
	if not r then
		r = Instance.new(class)
		r.Name = name
		r.Parent = ReplicatedStorage
	end
	return r
end
local RE = remote("RemoteEvent", "CityLife") :: RemoteEvent
local RF = remote("RemoteFunction", "CityLifeFn") :: RemoteFunction

local apps: { [string]: (Player, ...any) -> ...any } = {}
local lastCall: { [Player]: { [string]: number } } = {}
function Core.app(name: string, fn: (Player, ...any) -> ...any)
	apps[name] = fn
end
RF.OnServerInvoke = function(player: Player, name: any, ...: any)
	if type(name) ~= "string" or not apps[name] then return nil end
	local t = lastCall[player] or {}
	lastCall[player] = t
	local now = os.clock()
	if t[name] and now - t[name] < 0.15 then return nil end -- spam guard
	t[name] = now
	local ok, a, b, c, d = pcall(apps[name], player, ...)
	if not ok then
		warn("[CityLife] app " .. name .. " failed: " .. tostring(a))
		return nil
	end
	return a, b, c, d
end
local events: { [string]: (Player, ...any) -> () } = {}
function Core.clientEvent(name: string, fn: (Player, ...any) -> ())
	events[name] = fn
end
RE.OnServerEvent:Connect(function(player, name, ...)
	local fn = type(name) == "string" and events[name]
	if fn then
		local ok, err = pcall(fn, player, ...)
		if not ok then warn("[CityLife] event " .. name .. " failed: " .. tostring(err)) end
	end
end)
-- v284e: where a player is aiming (their camera, while a tool is out) - CityTraffic reads it
-- for "a gun pointed at the driver"
events["aim"] = function(player: Player, dir: any)
	if typeof(dir) ~= "Vector3" or dir.Magnitude < 0.5 or dir.Magnitude > 1.5 then return end
	player:SetAttribute("AimDir", dir.Unit)
	player:SetAttribute("AimAtClock", os.clock())
end

function Core.fire(player: Player, kind: string, ...: any)
	if player.Parent then RE:FireClient(player, kind, ...) end
end
function Core.fireAll(kind: string, ...: any)
	RE:FireAllClients(kind, ...)
end
Players.PlayerRemoving:Connect(function(p) lastCall[p] = nil end)

---------------------------------------------------------------------------
-- hooks other scripts call (PoliceSystem, Court): ServerStorage.CityLifeApi
---------------------------------------------------------------------------
local hooks: { [string]: (...any) -> ...any } = {}
function Core.hook(name: string, fn: (...any) -> ...any)
	hooks[name] = fn
end
do
	local fn = ServerStorage:FindFirstChild("CityLifeApi") or Instance.new("BindableFunction")
	fn.Name = "CityLifeApi"
	fn.OnInvoke = function(name: any, ...: any)
		local h = type(name) == "string" and hooks[name]
		if not h then return nil end
		local ok, a, b, c = pcall(h, ...)
		if not ok then
			warn("[CityLife] hook " .. tostring(name) .. " failed: " .. tostring(a))
			return nil
		end
		return a, b, c
	end
	fn.Parent = ServerStorage
end

---------------------------------------------------------------------------
-- event bus
---------------------------------------------------------------------------
local bus: { [string]: { (...any) -> () } } = {}
function Core.on(name: string, fn: (...any) -> ())
	bus[name] = bus[name] or {}
	table.insert(bus[name], fn)
end
function Core.emit(name: string, ...: any)
	for _, fn in bus[name] or {} do
		task.spawn(fn, ...)
	end
end

---------------------------------------------------------------------------
-- people
---------------------------------------------------------------------------
function Core.isLaw(player: Player): boolean
	if player:GetAttribute("Police") == true or player:GetAttribute("LawEnforcement") == true then return true end
	local team = player.Team
	return team ~= nil and Core.LAW_TEAMS[team.Name] == true and not player.Neutral
end
function Core.canMDT(player: Player): boolean
	local team = player.Team
	return team ~= nil and Core.MDT_TEAMS[team.Name] == true
end
function Core.isChief(player: Player): boolean
	if not player.Team or player.Team.Name ~= "Chief of Police" then return false end
	return player.Name == "aquagaming22" or RunService:IsStudio() or player.UserId == game.CreatorId
end
function Core.chief(): Player?
	for _, p in Players:GetPlayers() do
		if Core.isChief(p) then return p end
	end
	return nil
end
function Core.root(player: Player): BasePart?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end
function Core.alive(player: Player): boolean
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	return h ~= nil and h.Health > 0
end
-- in police custody, in prison or being processed: CityLife leaves them alone
function Core.inCustody(player: Player): boolean
	if player:GetAttribute("PoliceCuffed") == true or player:GetAttribute("PoliceArrested") == true then return true end
	if player:GetAttribute("SentenceEnd") ~= nil or player:GetAttribute("CustodyStage") ~= nil then return true end
	if player:GetAttribute("CustodyPhase") ~= nil and player:GetAttribute("CustodyPhase") ~= "Escaped" then return true end
	local team = player.Team
	return team ~= nil and (team.Name == "Prisoners" or team.Name:find("Inmate") ~= nil)
end
function Core.byName(name: any): Player?
	if type(name) ~= "string" then return nil end
	local lower = string.lower(name)
	for _, p in Players:GetPlayers() do
		if string.lower(p.Name) == lower or string.lower((p:GetAttribute("CharacterName") or p.DisplayName)) == lower then return p end
	end
	for _, p in Players:GetPlayers() do
		if string.sub(string.lower(p.Name), 1, #lower) == lower then return p end
	end
	return nil
end
function Core.seatedCar(player: Player): Model?
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local seat = h and h.SeatPart
	if not seat then return nil end
	local m = seat:FindFirstAncestorOfClass("Model")
	while m and m.Parent and m.Parent ~= workspace and m.Parent.Name ~= "SpawnedCars" and m.Parent:IsA("Model") do
		m = m.Parent :: any
	end
	return m
end
function Core.driver(car: Model): Player?
	for _, s in car:GetDescendants() do
		if s:IsA("VehicleSeat") and s.Occupant then
			return Players:GetPlayerFromCharacter(s.Occupant.Parent)
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- police (ServerStorage.PoliceAI)
---------------------------------------------------------------------------
local function policeApi(name: string): Instance?
	local f = ServerStorage:FindFirstChild("PoliceAI")
	return f and f:FindFirstChild(name)
end
function Core.report(player: Player, crime: string, pos: Vector3?, heat: number?)
	local r = policeApi("ReportCrime")
	if r and r:IsA("BindableEvent") then r:Fire(player, crime, pos, heat) end
end
-- every crime that counted (PoliceAI.CrimeAdded): fn(player, crimeKey, charge, pos)
-- and every star change (PoliceAI.StarsChanged): fn(player, stars, oldStars, reason)
local function connectPolice(name: string, fn: (...any) -> ())
	task.spawn(function()
		for _ = 1, 120 do
			local e = policeApi(name)
			if e and e:IsA("BindableEvent") then
				e.Event:Connect(function(...) local ok, err = pcall(fn, ...) if not ok then warn("[CityLife] " .. name .. ": " .. tostring(err)) end end)
				return
			end
			task.wait(1)
		end
		warn("[CityLife] PoliceAI." .. name .. " never appeared")
	end)
end
function Core.onCrime(fn: (Player, string, string, Vector3?) -> ())
	connectPolice("CrimeAdded", fn)
end
function Core.onStars(fn: (Player, number, number, string?) -> ())
	connectPolice("StarsChanged", fn)
end
function Core.onCleared(fn: (Player, string) -> ())
	connectPolice("Cleared", fn)
end
function Core.setStars(player: Player, stars: number)
	local r = policeApi("SetWanted")
	if r and r:IsA("BindableEvent") then r:Fire(player, stars) end
end
function Core.stars(player: Player): number
	return tonumber(player:GetAttribute("WantedStars")) or 0
end
function Core.policeEvent(name: string): BindableEvent?
	local e = policeApi(name)
	return if e and e:IsA("BindableEvent") then e else nil
end
function Core.policeFn(name: string, ...: any): ...any
	local f = policeApi(name)
	if f and f:IsA("BindableFunction") then
		local ok, a, b = pcall(f.Invoke, f, ...)
		if ok then return a, b end
		warn("[CityLife] PoliceAI." .. name .. " failed: " .. tostring(a))
	end
	return nil
end
-- AI officers (tagged Police by PoliceSystem; prison COs excluded)
local CollectionService = game:GetService("CollectionService")
function Core.aiCops(): { Model }
	local out = {}
	for _, m in CollectionService:GetTagged("Police") do
		if m:IsA("Model") and m.Parent and not CollectionService:HasTag(m, "PrisonCO") then
			local h = m:FindFirstChildOfClass("Humanoid")
			if h and h.Health > 0 and m:FindFirstChild("HumanoidRootPart") then table.insert(out, m) end
		end
	end
	return out
end
function Core.cruisers(): { Model }
	local out = {}
	local root = workspace:FindFirstChild("PoliceAI")
	local v = root and root:FindFirstChild("Vehicles")
	if v then
		for _, m in v:GetChildren() do
			if m:IsA("Model") and m.PrimaryPart then table.insert(out, m) end
		end
	end
	-- police players' own cars count too
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then
		for _, m in sp:GetChildren() do
			local d = m:IsA("Model") and Core.driver(m)
			if d and Core.isLaw(d) then table.insert(out, m) end
		end
	end
	return out
end

-- dispatch radio: every police player gets it (and the log)
function Core.radio(text: string, pos: Vector3?, label: string?)
	print("[Radio] " .. text)
	for _, p in Players:GetPlayers() do
		if Core.isLaw(p) then
			Core.UI.notice(p, "RADIO: " .. text, 7, Color3.fromRGB(20, 40, 90))
			if pos and label then Core.UI.waypoint(p, "radio", pos, label) end
		end
	end
	Core.emit("radio", text, pos)
end

---------------------------------------------------------------------------
-- money (ServerStorage.Economy)
---------------------------------------------------------------------------
local function economy(action: string, player: Player, ...: any): ...any
	local f = ServerStorage:FindFirstChild("Economy")
	if not (f and f:IsA("BindableFunction")) then return nil end
	local ok, a, b = pcall(f.Invoke, f, action, player, ...)
	if ok then return a, b end
	warn("[CityLife] Economy " .. action .. " failed: " .. tostring(a))
	return nil
end
Core.economy = economy
function Core.balance(player: Player): (number, number)
	local cash, bank = economy("Balance", player)
	return tonumber(cash) or 0, tonumber(bank) or 0
end
function Core.charge(player: Player, amount: number): boolean
	amount = math.floor(amount)
	if amount <= 0 then return true end
	return economy("Charge", player, amount) == true
end
-- pay out: "bank" (clean), "cash" (clean), "dirty" (crime money in cash)
function Core.pay(player: Player, amount: number, kind: string?)
	amount = math.floor(amount)
	if amount <= 0 then return end
	if kind == "dirty" then economy("AddDirtyCash", player, amount)
	elseif kind == "cash" then economy("AddCash", player, amount)
	else economy("AddBank", player, amount) end
end
function Core.dirty(player: Player): number
	local c, b = economy("Dirty", player)
	return (tonumber(c) or 0) + (tonumber(b) or 0)
end
-- charge, or tell them they can't afford it
function Core.chargeOrSay(player: Player, amount: number, what: string): boolean
	if Core.charge(player, amount) then
		Core.UI.notice(player, ("Paid %s - %s"):format(Core.UI.money(amount), what), 4)
		return true
	end
	Core.UI.notice(player, ("You can't afford %s (%s)"):format(what, Core.UI.money(amount)), 4, Color3.fromRGB(120, 30, 30))
	return false
end

---------------------------------------------------------------------------
-- time and places
---------------------------------------------------------------------------
function Core.clock(): number
	return Lighting.ClockTime
end
function Core.isNight(): boolean
	local t = Lighting.ClockTime
	return t >= 20 or t < 6
end
-- 0 (pitch dark) .. 1 (noon)
function Core.daylight(): number
	local t = Lighting.ClockTime
	if t >= 7 and t <= 18 then return 1 end
	if t >= 20 or t < 5 then return 0.25 end
	if t < 7 then return 0.25 + 0.75 * (t - 5) / 2 end
	return 1 - 0.75 * (t - 18) / 2
end

local landmarks: { { name: string, pos: Vector3 } }? = nil
local LANDMARKS = {
	{ "Bellagio", "the Bellagio" }, { "BellagioBuilding", "the Bellagio" }, { "Caesars Palace", "Caesars Palace" },
	{ "Courthouse", "the courthouse" }, { "PoliceStation", "Police HQ" }, { "Hospital", "the hospital" },
	{ "BankBuilding", "the bank" }, { "Bank", "the bank" }, { "City Jail", "the city jail" },
	{ "CorrectionalFacility", "the state prison" }, { "PremierCounsel", "the Premier Counsel tower" },
	{ "FireHouse", "the fire station" }, { "AirportGates", "the airport" }, { "PetrolPump", "the gas station" },
	{ "Houses", "the residential area" }, { "SprayShop", "the spray shop" }, { "BB&B", "the gun store" },
	{ "EstateAgency", "the estate agency" }, { "Warehouse", "the warehouse" },
}
local function buildLandmarks()
	landmarks = {}
	for _, l in LANDMARKS do
		local m = workspace:FindFirstChild(l[1])
		if m then
			local ok, cf = pcall(function()
				if m:IsA("Model") then return (m :: Model):GetBoundingBox() end
				if m:IsA("BasePart") then return m.CFrame end
				return nil
			end)
			if ok and cf then table.insert(landmarks :: any, { name = l[2], pos = cf.Position }) end
		end
	end
end
function Core.placeName(pos: Vector3): string
	if not landmarks then buildLandmarks() end
	local best, bd = nil, math.huge
	for _, l in landmarks :: any do
		local d = (Vector3.new(l.pos.X, 0, l.pos.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
		if d < bd then best, bd = l.name, d end
	end
	if not best then return "downtown" end
	if bd < 120 then return best end
	return "near " .. best
end

---------------------------------------------------------------------------
-- PoliceSystem modules (Records etc.)
---------------------------------------------------------------------------
local cachedMods: { [string]: any } = {}
function Core.policeModule(name: string): any
	if cachedMods[name] then return cachedMods[name] end
	local ps = ServerScriptService:FindFirstChild("PoliceSystem")
	local m = ps and ps:FindFirstChild(name)
	if m and m:IsA("ModuleScript") then
		local ok, mod = pcall(require, m)
		if ok then cachedMods[name] = mod; return mod end
	end
	return nil
end
function Core.records(): any
	return Core.policeModule("Records")
end

-- a short random id: "7KX-221" style
local LETTERS = "ABCDEFGHJKLMNPRSTUVWXYZ"
function Core.code(): string
	local function l() local i = math.random(1, #LETTERS); return string.sub(LETTERS, i, i) end
	return ("%d%s%s-%03d"):format(math.random(1, 9), l(), l(), math.random(0, 999))
end
local FIRST = { "James", "Maria", "Robert", "Linda", "Michael", "Sarah", "David", "Karen", "Carlos", "Ashley", "Tyrone", "Mei",
	"Daniel", "Rosa", "Kevin", "Brenda", "Luis", "Tanya", "Brian", "Nicole", "Frank", "Angela", "Victor", "Denise" }
local LAST = { "Smith", "Garcia", "Johnson", "Nguyen", "Brown", "Martinez", "Davis", "Lopez", "Wilson", "Anderson", "Thomas",
	"Moore", "Jackson", "White", "Harris", "Clark", "Lewis", "Walker", "Young", "King", "Wright", "Hill", "Green", "Baker" }
function Core.fakeName(): string
	return FIRST[math.random(1, #FIRST)] .. " " .. LAST[math.random(1, #LAST)]
end

function Core.log(tag: string, fmt: string, ...: any)
	print(("[%s] " .. fmt):format(tag, ...))
end

return Core
