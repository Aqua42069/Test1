-- Drugs (v252) - substances, intoxication, overdoses, impaired driving and DUI.
--
-- Every substance feeds an intoxication channel on the player (attributes, 0..~1.5):
--   Intox_Alcohol  beer, whiskey, prison hooch         legal (but not behind the wheel)
--   Intox_Weed     joints                               mellow
--   Intox_Party    party pills                          bright, then a crash
--   Intox_Stims    meth / stimulants                    fast and twitchy, hard comedown
--   Intox_Heavy    heroin, oxy/percocet in big doses    heavy; overdose risk
--   Intox_Spice    prison synthetic                     the most intense and dangerous
-- Plus: Impairment (0..1, what driving and the screen use), Comedown (seconds left),
-- DrugUsedAt (os.time of the last dose - v253 drug tests read it), Overdosed.
-- The client (DrugsClient) draws the screen effects; CarDriveClient makes driving sloppy.
--
-- Other scripts: ServerStorage.Drugs:Invoke("Give", player, substance, label?, potency?)
--                ServerStorage.Drugs:Invoke("Use", player, substance, potency?)
--                ServerStorage.Drugs:Invoke("Impairment", player) -> number

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local VERSION = 253 -- v253: tolerance, withdrawal, pharmacy meds

-- dose = how much one use adds to its channel; decay = per second
local SUBSTANCES = {
	Beer = { channel = "Alcohol", dose = 0.12, label = "Beer", color = Color3.fromRGB(200, 150, 50), legal = true },
	Whiskey = { channel = "Alcohol", dose = 0.25, label = "Whiskey", color = Color3.fromRGB(140, 80, 30), legal = true },
	Hooch = { channel = "Alcohol", dose = 0.35, label = "Prison Hooch", color = Color3.fromRGB(190, 190, 120), contraband = true },
	Weed = { channel = "Weed", dose = 0.3, label = "Joint", color = Color3.fromRGB(90, 140, 60) },
	PartyPills = { channel = "Party", dose = 0.4, label = "Party Pills", color = Color3.fromRGB(240, 120, 220) },
	Stims = { channel = "Stims", dose = 0.35, label = "Meth", color = Color3.fromRGB(200, 230, 255) },
	Opioids = { channel = "Heavy", dose = 0.18, label = "Painkillers", color = Color3.fromRGB(240, 240, 230) }, -- the dealer's pills heal on their own
	Heroin = { channel = "Heavy", dose = 0.5, label = "Black Tar", color = Color3.fromRGB(60, 40, 30) },
	Spice = { channel = "Spice", dose = 0.55, label = "Spice", color = Color3.fromRGB(120, 200, 90), contraband = true },
	-- v253: legal pharmacy meds - ease withdrawal, bring tolerance down faster, no high
	Meds = { channel = nil, dose = 0, label = "Pharmacy Meds", color = Color3.fromRGB(120, 180, 255), legal = true, meds = true },
}
-- v253 tolerance: each use builds Tolerance_<channel>; a tolerant user feels less from the
-- same dose. Tolerance high + the drug gone = Withdrawal (shaky screen, irritable).
local TOLERANCE = { gain = 0.35, decay = 0.0015, withdrawalAt = 0.6, clearAt = 0.35 }
local CHANNELS = {
	Alcohol = { decay = 0.0035, impair = 1.0, od = 1.6 },
	Weed = { decay = 0.004, impair = 0.45, od = nil },
	Party = { decay = 0.005, impair = 0.6, od = 1.5, crash = 40 },
	Stims = { decay = 0.0045, impair = 0.35, od = 1.4, crash = 60 },
	Heavy = { decay = 0.003, impair = 0.9, od = 1.05 },
	Spice = { decay = 0.004, impair = 1.0, od = 0.95 },
}
local CHANNEL_ORDER = { "Alcohol", "Weed", "Party", "Stims", "Heavy", "Spice" }
local CFG = {
	OverdoseSeconds = 30, -- collapsed: drains to death unless someone helps
	OverdoseDrain = 3.2, -- health per second while collapsed
	ReviveHold = 3,
	DUIImpairment = 0.35, -- driving above this, seen by police = DUI
	DUISpeed = 18,
	DUIChance = 0.25, -- per check while a cruiser / officer is near
	DUIRange = 160,
}

local function level(player: Player, channel: string): number
	return tonumber(player:GetAttribute("Intox_" .. channel)) or 0
end

local function setLevel(player: Player, channel: string, v: number)
	player:SetAttribute("Intox_" .. channel, if v > 0.005 then math.floor(v * 1000) / 1000 else nil)
end

local function impairment(player: Player): number
	local total = 0
	for _, ch in CHANNEL_ORDER do
		total += level(player, ch) * CHANNELS[ch].impair
	end
	return math.clamp(total, 0, 1)
end

local function notice(player: Player, text: string)
	local rs = game:GetService("ReplicatedStorage")
	local f = rs:FindFirstChild("PrisonSociety")
	local re = f and f:FindFirstChild("Notice")
	if re and re:IsA("RemoteEvent") then
		re:FireClient(player, text)
	end
end

local function humanoidOf(player: Player): (Humanoid?, BasePart?)
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local r = c and c:FindFirstChild("HumanoidRootPart")
	if h and r and r:IsA("BasePart") and h.Health > 0 then
		return h, r
	end
	return nil, nil
end

local function isInmate(player: Player): boolean
	return player:GetAttribute("CustodyOwner") == "INCARCERATED"
end

---------------------------------------------------------------------------
-- overdose
---------------------------------------------------------------------------
local overdosing: { [Player]: boolean } = {}

local function overdose(player: Player, channel: string)
	if overdosing[player] then
		return
	end
	local hum, root = humanoidOf(player)
	if not hum or not root then
		return
	end
	overdosing[player] = true
	player:SetAttribute("Overdosed", true)
	hum.PlatformStand = true
	notice(player, "You're overdosing - someone has to help you (hold E on you)")
	print(("[Drugs] OVERDOSE %s (%s %.2f)"):format(player.Name, channel, level(player, channel)))
	-- anyone nearby can help: CPR / Narcan
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ODHelp"
	prompt.ActionText = "Help"
	prompt.ObjectText = (player:GetAttribute("CharacterName") or player.DisplayName) .. " is overdosing"
	prompt.HoldDuration = CFG.ReviveHold
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	local saved = false
	prompt.Triggered:Connect(function(helper)
		if helper ~= player then
			saved = true
			print(("[Drugs] %s saved %s from an overdose"):format(helper.Name, player.Name))
			notice(helper, "You saved " .. (player:GetAttribute("CharacterName") or player.DisplayName))
		end
	end)
	-- in prison a drug death is a prison death (profile wipe rules, v237)
	if isInmate(player) then
		player:SetAttribute("PrisonKilledBy", "Overdose")
	end
	local t0 = os.clock()
	while player.Parent and hum.Parent and hum.Health > 0 and not saved and os.clock() - t0 < CFG.OverdoseSeconds do
		hum:TakeDamage(CFG.OverdoseDrain)
		task.wait(1)
	end
	if prompt.Parent then
		prompt:Destroy()
	end
	if saved and hum.Parent and hum.Health > 0 then
		for _, ch in CHANNEL_ORDER do
			setLevel(player, ch, level(player, ch) * 0.4)
		end
		hum.Health = math.max(hum.Health, 25)
		notice(player, "You came round. That was close.")
	elseif hum.Parent and hum.Health > 0 and not saved then
		-- nobody came: the body gives out
		hum.Health = 0
	end
	if player:GetAttribute("PrisonKilledBy") == "Overdose" and hum.Health > 0 then
		player:SetAttribute("PrisonKilledBy", nil)
	end
	if hum.Parent then
		hum.PlatformStand = false
	end
	player:SetAttribute("Overdosed", nil)
	overdosing[player] = nil
end

---------------------------------------------------------------------------
-- using
---------------------------------------------------------------------------
local function use(player: Player, substance: string, potency: number?): boolean
	local s = SUBSTANCES[substance]
	local hum = humanoidOf(player)
	if not s or not hum or overdosing[player] then
		return false
	end
	if s.meds then
		-- v253: meds take the edge off withdrawal and speed up getting clean
		player:SetAttribute("Withdrawal", nil)
		player:SetAttribute("MedsUntil", os.time() + 300)
		for _, c in CHANNEL_ORDER do
			local t = tonumber(player:GetAttribute("Tolerance_" .. c)) or 0
			if t > 0 then
				player:SetAttribute("Tolerance_" .. c, math.floor(t * 0.6 * 100) / 100)
			end
		end
		notice(player, "The meds take the edge off")
		return true
	end
	local ch = s.channel
	-- v253: tolerance blunts the dose (but not the overdose risk of a big one)
	local tol = tonumber(player:GetAttribute("Tolerance_" .. ch)) or 0
	local amount = s.dose * math.clamp(potency or 1, 0.3, 2.5) / (1 + tol)
	player:SetAttribute("Tolerance_" .. ch, math.min(2, math.floor((tol + s.dose * TOLERANCE.gain) * 100) / 100))
	player:SetAttribute("Withdrawal", nil)
	setLevel(player, ch, level(player, ch) + amount)
	player:SetAttribute("DrugUsedAt", os.time())
	player:SetAttribute("LastSubstance", substance)
	if s.heal then
		hum.Health = math.min(hum.MaxHealth, hum.Health + s.heal * math.clamp(potency or 1, 0.3, 2.5))
	end
	print(("[Drugs] %s used %s -> %s %.2f (impairment %.2f)"):format(player.Name, substance, ch, level(player, ch), impairment(player)))
	-- too much of one thing, or a dangerous mix
	local cfg = CHANNELS[ch]
	local mix = level(player, "Heavy") + level(player, "Alcohol") * 0.5 + level(player, "Spice")
	if (cfg.od and level(player, ch) >= cfg.od) or mix >= 1.3 then
		task.spawn(overdose, player, ch)
	end
	return true
end

local function makeTool(player: Player, substance: string, label: string?, potency: number?): Tool?
	local s = SUBSTANCES[substance]
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not s or not backpack then
		return nil
	end
	local tool = Instance.new("Tool")
	tool.Name = label or s.label
	tool.ToolTip = "Click to use"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("Substance", substance)
	tool:SetAttribute("Potency", potency or 1)
	if s.contraband or not s.legal then
		tool:SetAttribute("Contraband", true) -- prison searches take it
	end
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = if s.channel == "Alcohol" then Vector3.new(0.5, 1.1, 0.5) else Vector3.new(0.4, 0.25, 0.3)
	handle.Color = s.color
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	local used = false
	tool.Activated:Connect(function()
		if used or tool.Parent ~= player.Character then
			return
		end
		used = true
		if use(player, substance, potency) then
			tool:Destroy()
		else
			used = false
		end
	end)
	tool.Parent = backpack
	return tool
end

---------------------------------------------------------------------------
-- legal alcohol: shops (petrol station stores) and the casino bars
---------------------------------------------------------------------------
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

local function addShop(model: Instance, items: { { string } })
	local cf, size
	if model:IsA("Model") then
		cf, size = model:GetBoundingBox()
	elseif model:IsA("BasePart") then
		cf, size = model.CFrame, model.Size
	else
		return
	end
	local part = Instance.new("Part")
	part.Name = "LiquorCounter"
	part.Size = Vector3.new(2, 4, 2)
	part.Transparency = 1
	part.Anchored, part.CanCollide, part.CanQuery = true, false, false
	-- on the ground at the front of the building
	local hit = Workspace:Raycast(cf.Position + Vector3.new(0, size.Y, 0), Vector3.new(0, -size.Y * 2 - 20, 0))
	part.CFrame = CFrame.new((if hit then hit.Position else cf.Position) + Vector3.new(0, 2, 0))
	part.Parent = model
	for i, it in items do
		local substance, price = it[1], tonumber(it[2]) or 10
		local p = Instance.new("ProximityPrompt")
		p.Name = "Buy" .. substance
		p.ActionText = ("Buy %s ($%d)"):format(SUBSTANCES[substance].label, price)
		p.ObjectText = "Liquor"
		p.KeyboardKeyCode = ({ Enum.KeyCode.E, Enum.KeyCode.R, Enum.KeyCode.T })[i] or Enum.KeyCode.E
		p.HoldDuration = 0.3
		p.MaxActivationDistance = 14
		p.RequiresLineOfSight = false
		p.UIOffset = Vector2.new(0, (i - 1) * 70)
		p.Parent = part
		p.Triggered:Connect(function(player)
			if isInmate(player) then
				return
			end
			if economy("Charge", player, price) then
				makeTool(player, substance)
				notice(player, "Bought a " .. SUBSTANCES[substance].label)
			else
				notice(player, "Not enough cash")
			end
		end)
	end
end

local function setupShops(): number
	local n = 0
	for _, c in Workspace:GetChildren() do
		local name = string.lower(c.Name)
		if name == "petrolshop" then
			addShop(c, { { "Beer", "15" }, { "Whiskey", "45" }, { "Meds", "60" } })
			n += 1
		end
	end
	-- v253: the hospital's pharmacy sells meds too
	local hospital = Workspace:FindFirstChild("Hospital")
	if hospital then
		addShop(hospital, { { "Meds", "40" } })
		n += 1
	end
	-- the casino buildings serve drinks
	for _, name in { "BellagioBuilding", "Caesars Palace", "MGMGrand", "Luxor" } do
		local c = Workspace:FindFirstChild(name)
		if c then
			addShop(c, { { "Beer", "25" }, { "Whiskey", "70" } })
			n += 1
		end
	end
	-- mapped City points: Bar / LiquorStore
	local map = Workspace:FindFirstChild("CityMap")
	local points = map and map:FindFirstChild("Points")
	if points then
		for _, p in points:GetChildren() do
			local t = p:GetAttribute("PointType")
			if p:IsA("BasePart") and (t == "Bar" or t == "LiquorStore") then
				addShop(p, { { "Beer", "15" }, { "Whiskey", "45" } })
				n += 1
			end
		end
	end
	return n
end

---------------------------------------------------------------------------
-- the loop: wear-off, crashes, combat edges, DUI
---------------------------------------------------------------------------
local lastDUI: { [Player]: number } = {}
local baseMax: { [Player]: number } = {}

local function policeNear(pos: Vector3): boolean
	local ok, parts = pcall(function()
		return Workspace:GetPartBoundsInRadius(pos, CFG.DUIRange)
	end)
	if not ok then
		return false
	end
	for _, p in parts do
		if p.CollisionGroup == "PoliceVehicle" then
			return true
		end
		local m = p.Parent
		if m and m:IsA("Model") and (m:GetAttribute("PoliceUnit") or m:GetAttribute("PoliceOfficer") or m:GetAttribute("UnitType")) then
			return true
		end
	end
	return false
end

local function step(player: Player, dt: number)
	local hum, root = humanoidOf(player)
	local any = false
	for _, ch in CHANNEL_ORDER do
		local v = level(player, ch)
		if v > 0 then
			any = true
			local nv = math.max(0, v - CHANNELS[ch].decay * dt)
			setLevel(player, ch, nv)
			-- party pills / stims: when they wear off you crash
			local crash = CHANNELS[ch].crash
			if crash and v >= 0.2 and nv < 0.2 then
				player:SetAttribute("Comedown", crash)
				notice(player, "You're crashing hard...")
			end
		end
	end
	-- v253: tolerance fades slowly; a hooked user with nothing in them goes into withdrawal
	local hooked = false
	for _, ch in CHANNEL_ORDER do
		local t = tonumber(player:GetAttribute("Tolerance_" .. ch)) or 0
		if t > 0 then
			local medsOn = (tonumber(player:GetAttribute("MedsUntil")) or 0) > os.time()
			local nt = math.max(0, t - TOLERANCE.decay * dt * (if medsOn then 3 else 1))
			player:SetAttribute("Tolerance_" .. ch, if nt > 0.01 then math.floor(nt * 1000) / 1000 else nil)
			if nt >= TOLERANCE.withdrawalAt and level(player, ch) < 0.05 and not medsOn then
				hooked = true
			end
		end
	end
	local inWithdrawal = player:GetAttribute("Withdrawal") == true
	if hooked and not inWithdrawal then
		player:SetAttribute("Withdrawal", true)
		notice(player, "You're shaking... you need something")
		print(("[Drugs] WITHDRAWAL %s"):format(player.Name))
	elseif inWithdrawal and not hooked then
		local still = false
		for _, ch in CHANNEL_ORDER do
			if (tonumber(player:GetAttribute("Tolerance_" .. ch)) or 0) >= TOLERANCE.clearAt and level(player, ch) < 0.05 then
				still = true
			end
		end
		if not still or (tonumber(player:GetAttribute("MedsUntil")) or 0) > os.time() then
			player:SetAttribute("Withdrawal", nil)
		end
	end
	local come = tonumber(player:GetAttribute("Comedown")) or 0
	if come > 0 then
		player:SetAttribute("Comedown", if come - dt > 0 then come - dt else nil)
	end
	local imp = impairment(player)
	player:SetAttribute("Impairment", if imp > 0.01 then math.floor(imp * 100) / 100 else nil)
	if not hum or not root then
		return
	end
	-- combat edges: alcohol = you feel less (more max health); stims = faster punches
	local drunk = level(player, "Alcohol")
	if drunk > 0.15 then
		if not baseMax[player] then
			baseMax[player] = hum.MaxHealth
			hum.MaxHealth = baseMax[player] + 20
		end
	elseif baseMax[player] then
		hum.MaxHealth = baseMax[player]
		hum.Health = math.min(hum.Health, hum.MaxHealth)
		baseMax[player] = nil
	end
	-- (walk speed is left to the systems that own it - custody, cuffs, meth's own boost)
	player:SetAttribute("StimPunch", if level(player, "Stims") > 0.25 then true else nil) -- PrisonSociety: faster punches
	-- DUI: driving impaired where police can see
	local seat = hum.SeatPart
	if seat and seat:IsA("VehicleSeat") and imp >= CFG.DUIImpairment
		and seat.AssemblyLinearVelocity.Magnitude > CFG.DUISpeed and os.clock() - (lastDUI[player] or 0) > 20 then
		if policeNear(root.Position) and math.random() < CFG.DUIChance then
			lastDUI[player] = os.clock()
			local rc = ServerStorage:FindFirstChild("ReportCrime")
			if rc and rc:IsA("BindableFunction") then
				pcall(function()
					rc:Invoke(player, "Driving under the influence", 1)
				end)
			end
			-- breathalyzer result goes on the record with the arrest; the licence goes
			player:SetAttribute("DUIPending", true)
			player:SetAttribute("DUIBAC", math.floor(level(player, "Alcohol") * 0.2 * 1000) / 1000)
			notice(player, "Police saw you swerving - pull over!")
			print(("[Drugs] DUI %s impairment %.2f"):format(player.Name, imp))
		end
	end
	-- arrested with a DUI pending: licence suspended (DAVID / Records read LicenceSuspendedUntil)
	if player:GetAttribute("DUIPending") and player:GetAttribute("CustodyStage") ~= nil then
		player:SetAttribute("DUIPending", nil)
		player:SetAttribute("LicenceSuspendedUntil", os.time() + 3600)
		notice(player, ("Breathalyzer: %.3f BAC - DUI. Your licence is suspended."):format(tonumber(player:GetAttribute("DUIBAC")) or 0.08))
		print(("[Drugs] DUI ARREST %s - licence suspended 1h"):format(player.Name))
	end
	if not any and not player:GetAttribute("Impairment") then
		return
	end
end

---------------------------------------------------------------------------
-- start
---------------------------------------------------------------------------
local fn = ServerStorage:FindFirstChild("Drugs") or Instance.new("BindableFunction")
fn.Name = "Drugs"
fn.OnInvoke = function(action: string, player: Player, a: any, b: any, c: any): any
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	if action == "Give" then
		return makeTool(player, tostring(a), if type(b) == "string" then b else nil, tonumber(c)) ~= nil
	elseif action == "Use" then
		return use(player, tostring(a), tonumber(b))
	elseif action == "Impairment" then
		return impairment(player)
	end
	return nil
end
fn.Parent = ServerStorage

Players.PlayerRemoving:Connect(function(p)
	overdosing[p] = nil
	lastDUI[p] = nil
	baseMax[p] = nil
end)
-- a new character starts sober-ish (death clears the high, not the record)
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function()
		for _, ch in CHANNEL_ORDER do
			setLevel(p, ch, 0)
		end
		p:SetAttribute("Comedown", nil)
		p:SetAttribute("Overdosed", nil)
		baseMax[p] = nil
	end)
end)

task.spawn(function()
	task.wait(5)
	local shops = setupShops()
	print(("[Drugs] v%d ready: %d substance(s), %d liquor counter(s)"):format(VERSION, #CHANNEL_ORDER, shops))
	local last = os.clock()
	while true do
		task.wait(1)
		local now = os.clock()
		local dt = now - last
		last = now
		for _, p in Players:GetPlayers() do
			local ok, err = pcall(step, p, dt)
			if not ok then
				warn("[Drugs] " .. tostring(err))
			end
		end
	end
end)
