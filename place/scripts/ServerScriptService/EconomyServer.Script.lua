-- EconomyServer
-- Rebuilt money system (the snapshot had no server code).
--   * player.Cash (on hand) and player.Money (in the bank), saved with DataStores
--     along with your car keys
--   * Payday every 5 minutes, paid into the bank, based on your team's income
--   * Phone apps: YBCN car shop, Banking (transfers), Messaging, Meds
--   * ATMs: walk up to a bank machine and press E
-- Everything that costs money is checked and charged here, never on the client.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local TextService = game:GetService("TextService")
local RunService = game:GetService("RunService")

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local PlayerDefaults = require(script.Parent:WaitForChild("PlayerDefaults"))
local STARTING_CASH = PlayerDefaults.STARTING_CASH
local STARTING_BANK = PlayerDefaults.STARTING_BANK
local PAYDAY_SECONDS = 300
local DATASTORE_NAME = "LasVegas_PlayerData_v1"
local MESSAGE_HISTORY = 10

-- Game passes from the original game (the Pass Shop list). Ownership is checked
-- against these IDs; in Studio every pass counts as owned so you can test.
local PASS_IDS = {
	["Support Sign"] = 331263718, ["Tax Avoidance"] = 163868289, ["Street Racer"] = 163870680,
	["Body Armour"] = 163870271, ["Aircraft Discount"] = 233309004, ["Dealership Discount"] = 163872567,
	["Marksman Discount"] = 163868735, ["Advertiser"] = 163869634, ["Casino Access"] = 152908304,
	["Airport Access"] = 163874000, ["Sidearm"] = 152909903, ["Spray Can"] = 240988085,
	["Pilot License"] = 233311030, ["Novelty Car Package"] = 152925921, ["Luxury Car Package"] = 170982772,
	["Posh Car Package"] = 445823461, ["British Car Package"] = 445822584, ["Commercial Car Package"] = 445823012,
	["RV Package"] = 346581454, ["RV Car Package"] = 346581454, ["Permanent Sedan"] = 163872015,
	["Permanent SUV"] = 163867182, ["Permanent Pickup"] = 163871571, ["Permanent Van"] = 152919633,
	["Permanent Sports Car"] = 154605834,
}

-- The YBCN catalog (prices are the original base price x 2.5).
-- Only cars whose model exists in this copy of the map can actually be bought.
local CAR_CATALOG = {
	{ "Sedan", 400, nil, 137550300 }, { "Van", 350, nil, 137550340 }, { "SUV", 450, nil, 137550321 },
	{ "Pickup", 380, nil, 137550355 }, { "Sports Car", 550, nil, 137550367 },
	{ "Lawn Mower", 150, nil, 137550380 }, { "Quad", 220, nil, 152587966 },
	{ "Golf Caddy", 250, nil, 137550398 }, { "Ice-Cream Van", 350, nil, 147853532 },
	{ "Lowrider", 470, nil, 170985182 }, { "Muscle Car", 560, nil, 170986787 },
	{ "Limo", 540, nil, 170986715 }, { "RV - Class A", 1750, nil, 346687071 },
	{ "RV - Class B", 1000, nil, 346687100 }, { "Luxury Coupe", 550, nil, 447407995 },
	{ "Luxury Sedan", 570, nil, 447406337 }, { "Routemaster Bus", 480, nil, 447403047 },
	{ "MG", 650, nil, 447401799 }, { "Box Truck", 450, nil, 447407816 },
	{ "Flatbed", 420, nil, 447406473 }, { "Flatbed Transport", 600, nil, 447401721 },
}
local PRICE_MULTIPLIER = 2.5

-- name, price, description, kind, strength, [walk speed for "speed" items]
-- Legal only - the pharmacy won't sell anything a street dealer should be
-- selling instead (see ServerScriptService.CivilianServer for that).
local MEDICINES = {
	{ "Ibruprofen", 50, "Provides light relief from pain", "heal", 25 },
	{ "Co-codamol", 90, "Provides medium relief from pain", "heal", 50 },
	{ "Caffeine pills", 100, "Provides short lasting speed boost", "speed", 20, 26 },
	{ "Vitamins", 80, "Provides small health regeneration", "regen", 20 },
	{ "Statins", 150, "Provides medium health regeneration", "regen", 45 },
	{ "Medikit", 250, "Provides large health regeneration", "regen", 90 },
}

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local functions = ReplicatedStorage:WaitForChild("Functions")
local events = ReplicatedStorage:WaitForChild("Events")

local function notify(player, text, seconds)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local old = playerGui:FindFirstChild("EconomyNotice")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "EconomyNotice"
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.2, 0)
	label.Size = UDim2.new(0.4, 0, 0.045, 0)
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Text = text
	label.Parent = gui
	gui.Parent = playerGui
	game:GetService("Debris"):AddItem(gui, seconds or 3)
end

local function remote(folder, className, name)
	local obj = folder:FindFirstChild(name)
	if not (obj and obj:IsA(className)) then
		obj = Instance.new(className)
		obj.Name = name
		obj.Parent = folder
	end
	return obj
end

local teamInfo = {}
pcall(function()
	teamInfo = HttpService:JSONDecode(ReplicatedStorage.TeamInfo.Value)
end)

local function isDev(player)
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		return ok and rank == 255
	end
	return player.UserId == game.CreatorId
end

---------------------------------------------------------------------------
-- Passes
---------------------------------------------------------------------------
local passCache = {}
local function ownsPass(player, passName)
	if not passName then
		return true
	end
	if isDev(player) then
		return true
	end
	local id = PASS_IDS[passName]
	if not id then
		return false
	end
	passCache[player] = passCache[player] or {}
	if passCache[player][id] == nil then
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, id)
		passCache[player][id] = ok and owns or false
	end
	return passCache[player][id]
end
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, id, purchased)
	if purchased and passCache[player] then
		passCache[player][id] = true
	end
end)

remote(functions, "RemoteFunction", "CheckPass").OnServerInvoke = function(player, passName)
	return type(passName) == "string" and ownsPass(player, passName) or false
end
remote(functions, "RemoteFunction", "GetPaydayKey").OnServerInvoke = function()
	return 0 -- kept for old scripts; payday is paid by the server now
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------
local function intValue(player, name, default)
	local v = player:FindFirstChild(name)
	if not v then
		v = Instance.new("IntValue")
		v.Name = name
		v.Value = default
		v.Parent = player
	end
	return v
end

local function total(player)
	return player.Cash.Value + player.Money.Value
end

-- v255 dirty money: how much of Cash / Money (bank) is crime money, as the
-- attributes DirtyCash / DirtyBank. Spending takes clean and dirty in proportion;
-- moving money (deposit, withdraw, transfer) carries its dirty share along.
local DIRTY_ATTR = { Cash = "DirtyCash", Money = "DirtyBank" }

local function dirtyOf(player, pool)
	return math.max(0, math.floor(tonumber(player:GetAttribute(DIRTY_ATTR[pool])) or 0))
end

local function setDirty(player, pool, amount)
	local cap = player[pool].Value
	amount = math.clamp(math.floor(amount), 0, math.max(cap, 0))
	player:SetAttribute(DIRTY_ATTR[pool], if amount > 0 then amount else nil)
end

-- the dirty part of `amount` taken out of `pool` (removed from that pool's dirty total)
local function takeDirty(player, pool, amount)
	local have = player[pool].Value
	if amount <= 0 or have <= 0 then
		return 0
	end
	local d = dirtyOf(player, pool)
	local share = math.floor(d * math.min(amount, have) / have + 0.5)
	player:SetAttribute(DIRTY_ATTR[pool], if d - share > 0 then d - share else nil)
	return share
end

local function addDirty(player, pool, amount)
	if amount > 0 then
		player:SetAttribute(DIRTY_ATTR[pool], dirtyOf(player, pool) + amount)
	end
end

-- Takes money, cash first then bank. Returns true if paid.
local function charge(player, amount)
	amount = math.floor(amount)
	if amount < 0 or total(player) < amount then
		return false
	end
	local fromCash = math.min(player.Cash.Value, amount)
	takeDirty(player, "Cash", fromCash)
	takeDirty(player, "Money", amount - fromCash)
	player.Cash.Value -= fromCash
	player.Money.Value -= amount - fromCash
	return true
end

local function refreshLeaderstats(player)
	local stats = player:FindFirstChild("leaderstats")
	if stats and stats:FindFirstChild("Money") then
		stats.Money.Value = total(player)
	end
end

local function teamIncome(player)
	for _, t in ipairs(teamInfo) do
		if player.Team and t[1] == player.Team.Name then
			return tonumber(t[4]) or 100
		end
	end
	return 100
end

local function paydayAmount(player)
	local income = teamIncome(player)
	if ownsPass(player, "Tax Avoidance") then
		income = math.ceil(income * 1.3)
	end
	return income - player.Rent.Value
end

---------------------------------------------------------------------------
-- Saving
---------------------------------------------------------------------------
local store = nil
do
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, DATASTORE_NAME)
	if ok then
		store = result
	else
		warn("[EconomyServer] DataStores unavailable, progress won't save:", result)
	end
end
local loaded = {} -- only true once this player's saved data was read successfully
local saving = {} -- a save in flight per player (BindToClose waits on these)

-- v236: retry DataStore calls (they fail now and then under load)
local function withRetries(what, fn)
	local lastErr
	for attempt = 1, 4 do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(attempt)
	end
	warn("[EconomyServer] " .. what .. " failed after retries:", lastErr)
	return false, lastErr
end

local function snapshot(player)
	local cars = {}
	local storage = player:FindFirstChild("CarStorage")
	if storage then
		for _, key in ipairs(storage:GetChildren()) do
			if key.Value ~= true then -- single-use keys aren't saved
				table.insert(cars, key.Name)
			end
		end
	end
	local cash = player:FindFirstChild("Cash")
	local bank = player:FindFirstChild("Money")
	return {
		cash = cash and cash.Value or 0,
		bank = bank and bank.Value or 0,
		cars = cars,
		dirtyCash = dirtyOf(player, "Cash"),
		dirtyBank = dirtyOf(player, "Money"),
		house = player:GetAttribute("HouseId"),
		savedAt = os.time(),
	}
end

local function saveData(player)
	-- never save before the real data was loaded: that would overwrite a
	-- player's balance with the starting money (v236 data-loss fix)
	if not (store and loaded[player]) then
		return false
	end
	local data = snapshot(player)
	saving[player] = (saving[player] or 0) + 1
	local ok = withRetries("save for " .. player.Name, function()
		store:UpdateAsync("player_" .. player.UserId, function()
			return data
		end)
	end)
	saving[player] = math.max(0, (saving[player] or 1) - 1)
	if saving[player] == 0 then
		saving[player] = nil
	end
	return ok
end

-- (cash, bank) -> topped up so the TOTAL is at least the player's floor
-- (aquagaming22: always at least $50M; more than that is kept as saved)
local function applyFloor(player)
	local floor = PlayerDefaults.bankFloor(player)
	if floor <= 0 then
		return
	end
	local have = player.Cash.Value + player.Money.Value
	if have < floor then
		player.Money.Value += floor - have
	end
end

local function loadData(player)
	local data = nil
	local ok = false
	if store then
		ok, data = withRetries("load for " .. player.Name, function()
			return store:GetAsync("player_" .. player.UserId)
		end)
		if not ok then
			data = nil
			warn("[EconomyServer] couldn't read " .. player.Name .. "'s save - their progress won't be saved this session (so it isn't overwritten)")
		end
	end
	data = if type(data) == "table" then data else {}
	if type(data.house) == "string" then
		player:SetAttribute("SavedHouse", data.house) -- HousingServer moves you back in
	end
	local startCash, startBank = PlayerDefaults.start(player)
	player.Cash.Value = tonumber(data.cash) or startCash
	player.Money.Value = tonumber(data.bank) or startBank
	setDirty(player, "Cash", tonumber(data.dirtyCash) or 0)
	setDirty(player, "Money", tonumber(data.dirtyBank) or 0)
	applyFloor(player)
	player:SetAttribute("EconomyLoaded", true) -- v255: AssetFreeze waits for this
	-- only a successful read (a returning player OR a genuinely new one) may be saved over
	loaded[player] = store ~= nil and ok
	print(("[EconomyServer] %s loaded: cash=%d bank=%d (%s)"):format(
		player.Name, player.Cash.Value, player.Money.Value,
		if not store then "NO DATASTORE - publish the place and enable Studio API access"
			elseif not ok then "load failed"
			elseif data.savedAt then "saved profile"
			else "new profile"))

	if type(data.cars) == "table" then
		local give = ServerStorage:WaitForChild("GiveCarKeys", 15)
		if give then
			for _, carName in ipairs(data.cars) do
				if type(carName) == "string" then
					give:Invoke(player, carName, false)
				end
			end
		end
	end
end

-- other scripts (e.g. the Death Row wipe) can force a save right away
do
	local fn = ServerStorage:FindFirstChild("SavePlayerData") or Instance.new("BindableFunction")
	fn.Name = "SavePlayerData"
	fn.OnInvoke = function(player)
		if typeof(player) == "Instance" and player:IsA("Player") then
			return saveData(player)
		end
		return false
	end
	fn.Parent = ServerStorage
end

---------------------------------------------------------------------------
-- Players
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Death drops: cash on hand scatters as pickups anyone can grab. Bank money
-- is safe (it wasn't "on hand"). More cash means more bricks, up to a cap,
-- and past that cap each brick is just worth more instead of spawning more.
---------------------------------------------------------------------------
local MAX_BRICKS = 75
local BRICK_DESPAWN = 180 -- seconds before an unclaimed brick disappears

local function scatterPoint(centre, radius)
	local offset = Vector3.new((math.random() - 0.5) * 2 * radius, 0, (math.random() - 0.5) * 2 * radius)
	local origin = centre + offset + Vector3.new(0, 8, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local hit = workspace:Raycast(origin, Vector3.new(0, -30, 0), params)
	return (hit and hit.Position or (centre + offset)) + Vector3.new(0, 1, 0)
end

local function makeBrick(position, value)
	local brick = Instance.new("Part")
	brick.Name = "CashBrick"
	brick.Size = Vector3.new(1.2, 0.5, 0.7)
	brick.Color = Color3.fromRGB(60, 150, 70)
	brick.Material = Enum.Material.SmoothPlastic
	brick.CFrame = CFrame.new(position) * CFrame.Angles(0, math.random() * math.pi, 0)

	local sign = Instance.new("BillboardGui")
	sign.Size = UDim2.new(0, 60, 0, 24)
	sign.StudsOffset = Vector3.new(0, 1.1, 0)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "$" .. value
	label.TextColor3 = Color3.fromRGB(120, 255, 120)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.SourceSansBold
	label.TextScaled = true
	label.Parent = sign
	sign.Parent = brick

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick up"
	prompt.ObjectText = "$" .. value
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 8
	prompt.Parent = brick
	prompt.Triggered:Connect(function(player)
		if not brick.Parent then
			return
		end
		brick:Destroy()
		player.Cash.Value += value
	end)

	brick.Parent = workspace
	game:GetService("Debris"):AddItem(brick, BRICK_DESPAWN)
end

local function dropCash(character, amount)
	amount = math.floor(amount)
	if amount <= 0 then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso")
	if not root then
		return
	end
	local centre = root.Position
	local count = math.clamp(math.floor(math.sqrt(amount) + 0.5), 1, MAX_BRICKS)

	-- Split the total into `count` uneven shares (not perfectly even, for
	-- variety) that still add up to exactly `amount`.
	local weights, total = {}, 0
	for i = 1, count do
		weights[i] = 0.5 + math.random()
		total += weights[i]
	end
	local given = 0
	for i = 1, count do
		local share = (i == count) and (amount - given) or math.floor(amount * weights[i] / total)
		given += share
		if share > 0 then
			makeBrick(scatterPoint(centre, 10), share)
		end
	end
end

local function onPlayerAdded(player)
	local cash = intValue(player, "Cash", 0)
	local bank = intValue(player, "Money", 0)
	intValue(player, "Rent", 0)
	local timer = intValue(player, "PaydayTimer", PAYDAY_SECONDS)
	timer.Value = PAYDAY_SECONDS
	if not player:FindFirstChild("RecentTransfers") then
		local rt = Instance.new("StringValue")
		rt.Name = "RecentTransfers"
		rt.Parent = player
	end

	local stats = player:FindFirstChild("leaderstats") or Instance.new("Folder")
	stats.Name = "leaderstats"
	local shown = stats:FindFirstChild("Money") or Instance.new("IntValue")
	shown.Name = "Money"
	shown.Parent = stats
	stats.Parent = player
	cash.Changed:Connect(function()
		refreshLeaderstats(player)
	end)
	bank.Changed:Connect(function()
		refreshLeaderstats(player)
	end)

	task.spawn(function()
		loadData(player)
		refreshLeaderstats(player)
		player:SetAttribute("PaydayAmount", paydayAmount(player))
	end)
	player:GetPropertyChangedSignal("Team"):Connect(function()
		player:SetAttribute("PaydayAmount", paydayAmount(player))
	end)

	local function onCharacter(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			humanoid.Died:Connect(function()
				local dropped = player.Cash.Value
				player.Cash.Value = 0
				player:SetAttribute("DirtyCash", nil)
				dropCash(character, dropped)
			end)
		end
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	saveData(player)
	loaded[player] = nil
	passCache[player] = nil
end)
game:BindToClose(function()
	-- save everyone in parallel, then wait (up to ~25s) for every save to finish
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(saveData, player)
	end
	local deadline = os.clock() + 25
	task.wait(0.5)
	while next(saving) and os.clock() < deadline do
		task.wait(0.25)
	end
end)

-- Payday clock + autosave
task.spawn(function()
	local sinceSave = 0
	while true do
		task.wait(1)
		sinceSave += 1
		for _, player in ipairs(Players:GetPlayers()) do
			-- v255: scripts that change Cash / Money directly can't leave more dirty than there is
			if loaded[player] then
				for pool, attr in DIRTY_ATTR do
					if player:GetAttribute(attr) and dirtyOf(player, pool) > player[pool].Value then
						setDirty(player, pool, player[pool].Value)
					end
				end
			end
			local timer = player:FindFirstChild("PaydayTimer")
			if timer and loaded[player] then
				timer.Value -= 1
				if timer.Value <= 0 then
					timer.Value = PAYDAY_SECONDS
					local amount = paydayAmount(player)
					player:SetAttribute("PaydayAmount", amount)
					if amount >= 0 then
						player.Money.Value += amount
					else
						charge(player, math.min(-amount, total(player)))
					end
				end
			end
		end
		if sinceSave >= 60 then -- v236: autosave every minute
			sinceSave = 0
			for _, player in ipairs(Players:GetPlayers()) do
				task.spawn(saveData, player)
			end
		end
	end
end)

-- The old client payday / meds scripts fired this with amounts. Never trust them.
remote(events, "RemoteEvent", "MoneyRequest").OnServerEvent:Connect(function() end)

---------------------------------------------------------------------------
-- Bank: deposit, withdraw, transfer (phone Banking app + ATMs)
---------------------------------------------------------------------------
local moneyRequest = events:FindFirstChild("MoneyRequest")

local function bank(player, action, amount, target)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 or not loaded[player] then
		return false
	end
	-- v255: a frozen account (felony money case) takes deposits but pays nothing out
	if player:GetAttribute("AssetsFrozen") and action ~= "Deposit" then
		notify(player, "ACCOUNT FROZEN - Clark County DA", 5)
		return false
	end
	if action == "Deposit" then
		if player.Cash.Value < amount then
			return false
		end
		local d = takeDirty(player, "Cash", amount)
		player.Cash.Value -= amount
		player.Money.Value += amount
		addDirty(player, "Money", d)
		return true
	elseif action == "Withdraw" then
		if player.Money.Value < amount then
			return false
		end
		local d = takeDirty(player, "Money", amount)
		player.Money.Value -= amount
		player.Cash.Value += amount
		addDirty(player, "Cash", d)
		return true
	elseif action == "Transfer" then
		if typeof(target) ~= "Instance" or not target:IsA("Player") or target == player or not loaded[target] then
			return false
		end
		if player.Money.Value < amount then
			return false
		end
		-- dirty money stays dirty in someone else's account; a frozen friend gets it as cash
		local d = takeDirty(player, "Money", amount)
		player.Money.Value -= amount
		local pool = if target:GetAttribute("AssetsFrozen") then "Cash" else "Money"
		target[pool].Value += amount
		addDirty(target, pool, d)
		if moneyRequest then
			moneyRequest:FireClient(target, player, amount)
		end
		return true
	end
	return false
end
remote(functions, "RemoteFunction", "BankDeposit").OnServerInvoke = bank

-- Other server scripts (ATMs in NPCServer) use this.
local economyFn = ServerStorage:FindFirstChild("Economy") or Instance.new("BindableFunction")
economyFn.Name = "Economy"
economyFn.OnInvoke = function(action, player, amount, ...)
	if action == "Charge" then
		return charge(player, amount)
	elseif action == "OwnsPass" then
		return ownsPass(player, amount)
	elseif action == "AddBank" then
		amount = math.floor(tonumber(amount) or 0)
		if amount > 0 then
			player.Money.Value += amount
		end
		return true
	elseif action == "AddCash" then
		amount = math.floor(tonumber(amount) or 0)
		if amount > 0 then
			player.Cash.Value += amount
		end
		return true
	elseif action == "AddDirtyCash" then
		-- v255: crime money (heists, robbery, street jobs, looting)
		amount = math.floor(tonumber(amount) or 0)
		if amount > 0 then
			player.Cash.Value += amount
			addDirty(player, "Cash", amount)
		end
		return true
	elseif action == "Dirty" then
		return dirtyOf(player, "Cash"), dirtyOf(player, "Money")
	elseif action == "TakeDirty" then
		-- (pool, amount) -> the dirty part of that amount, removed from the pool's dirty total
		local pool, n = amount, math.floor(tonumber(select(1, ...)) or 0)
		return takeDirty(player, pool, n)
	elseif action == "AddDirty" then
		local pool, n = amount, math.floor(tonumber(select(1, ...)) or 0)
		addDirty(player, pool, n)
		return true
	elseif action == "Balance" then
		return player.Cash.Value, player.Money.Value
	else
		return bank(player, action, amount)
	end
end
economyFn.Parent = ServerStorage

---------------------------------------------------------------------------
-- YBCN car shop
---------------------------------------------------------------------------
local function carPrice(player, entry)
	local price = math.floor(entry[2] * PRICE_MULTIPLIER)
	if ownsPass(player, "Dealership Discount") then
		price = math.floor(price * 0.8)
	end
	return price
end

local function templateExists(name)
	local folder = ServerStorage:FindFirstChild("CarTemplates")
	return folder and folder:FindFirstChild(name) ~= nil
end

remote(functions, "RemoteFunction", "GetCarCatalog").OnServerInvoke = function(player)
	local list = {}
	for _, entry in ipairs(CAR_CATALOG) do
		local storage = player:FindFirstChild("CarStorage")
		table.insert(list, {
			name = entry[1],
			price = carPrice(player, entry),
			package = entry[3],
			unlocked = ownsPass(player, entry[3]),
			available = templateExists(entry[1]),
			owned = storage and storage:FindFirstChild(entry[1]) ~= nil or false,
			image = "rbxassetid://" .. entry[4],
		})
	end
	return list
end

local function buyCar(player, carName)
	local entry
	for _, e in ipairs(CAR_CATALOG) do
		if e[1] == carName then
			entry = e
		end
	end
	if not entry then
		return false, "Unknown car"
	end
	if player.Team and player.Team.Name == "Prisoners" then
		return false, "We don't sell to inmates"
	end
	if not templateExists(carName) then
		return false, "Out of stock"
	end
	if not ownsPass(player, entry[3]) then
		return false, "Needs the " .. entry[3]
	end
	local storage = player:FindFirstChild("CarStorage")
	if storage and storage:FindFirstChild(carName) then
		return false, "You already own this"
	end
	if not charge(player, carPrice(player, entry)) then
		return false, "Not enough money"
	end
	local give = ServerStorage:FindFirstChild("GiveCarKeys")
	if not (give and give:Invoke(player, carName, false)) then
		player.Money.Value += carPrice(player, entry) -- refund
		return false, "Something went wrong"
	end
	task.spawn(saveData, player)
	return true, "Keys added! Find a blue pad."
end
remote(functions, "RemoteFunction", "BuyCar").OnServerInvoke = buyCar


-- Let the NPC dealer sell cars with the same prices.
local carShopFn = ServerStorage:FindFirstChild("CarShop") or Instance.new("BindableFunction")
carShopFn.Name = "CarShop"
carShopFn.OnInvoke = function(action, player, carName)
	if action == "Price" then
		for _, e in ipairs(CAR_CATALOG) do
			if e[1] == carName then
				return carPrice(player, e)
			end
		end
		return nil
	elseif action == "Buy" then
		return buyCar(player, carName)
	end
end
carShopFn.Parent = ServerStorage

---------------------------------------------------------------------------
-- Meds
---------------------------------------------------------------------------
remote(functions, "RemoteFunction", "GetMedicines").OnServerInvoke = function()
	local list = {}
	for _, m in ipairs(MEDICINES) do
		table.insert(list, { name = m[1], price = math.floor(m[2] * PRICE_MULTIPLIER), desc = m[3] })
	end
	return list
end

-- Meds are Tools you carry and use whenever you want (click / Activate),
-- the same way guns and car keys work - not consumed the instant you pay.
local function makeMedTool(medName)
	local tool = Instance.new("Tool")
	tool.Name = medName
	tool.ToolTip = "Click to use"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute("MedName", medName)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.6, 0.9, 0.4)
	handle.Color = Color3.fromRGB(235, 235, 240)
	handle.Material = Enum.Material.Plastic
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	return tool
end

remote(functions, "RemoteFunction", "BuyMedicine").OnServerInvoke = function(player, medName)
	local med
	for _, m in ipairs(MEDICINES) do
		if m[1] == medName then
			med = m
		end
	end
	if not med then
		return false, "Unknown medicine"
	end
	if player.Team and player.Team.Name == "Prisoners" then
		return false, "Not available in prison"
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "Try again in a second"
	end
	if not charge(player, math.floor(med[2] * PRICE_MULTIPLIER)) then
		return false, "Not enough money"
	end
	makeMedTool(medName).Parent = backpack
	return true, "Got it - check your backpack"
end

-- Using a med tool: fired by StarterPlayerScripts.MedsClient when you click it equipped.
local useMedicine = remote(events, "RemoteEvent", "UseMedicine")
useMedicine.OnServerEvent:Connect(function(player, tool)
	if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then
		return
	end
	local character = player.Character
	if tool.Parent ~= character then
		return
	end
	local medName, kind, strength, walkOverride
	if tool:GetAttribute("Kind") then
		-- Dealer-sold item: describes its own effect.
		medName = tool:GetAttribute("DisplayName") or tool.Name
		kind = tool:GetAttribute("Kind")
		strength = tool:GetAttribute("Strength")
		walkOverride = tool:GetAttribute("WalkSpeed")
	else
		medName = tool:GetAttribute("MedName")
		local med
		for _, m in ipairs(MEDICINES) do
			if m[1] == medName then
				med = m
			end
		end
		if not med then
			return
		end
		kind, strength, walkOverride = med[4], med[5], med[6]
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local hurt = humanoid.Health < humanoid.MaxHealth - 0.5
	if (kind == "heal" or kind == "regen") and not hurt then
		notify(player, "You're already at full health - save it for later.")
		return
	end
	if kind == "speed" and player:GetAttribute("SpeedBoostUntil") and player:GetAttribute("SpeedBoostUntil") > os.clock() then
		notify(player, "You're already boosted.")
		return
	end
	tool:Destroy() -- used up

	if kind == "heal" then
		local before = humanoid.Health
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + strength)
		notify(player, ("%s: +%d health"):format(medName, math.floor(humanoid.Health - before + 0.5)))
	elseif kind == "speed" then
		local walkSpeed = walkOverride or 28
		local untilTime = os.clock() + strength
		player:SetAttribute("SpeedBoostUntil", untilTime)
		humanoid.WalkSpeed = walkSpeed
		local root = humanoid.Parent:FindFirstChild("HumanoidRootPart")
		local sparkles
		if root then
			sparkles = Instance.new("Sparkles")
			sparkles.Name = "SpeedBoost"
			sparkles.SparkleColor = Color3.fromRGB(255, 220, 90)
			sparkles.Parent = root
		end
		task.delay(strength, function()
			if player:GetAttribute("SpeedBoostUntil") == untilTime then
				player:SetAttribute("SpeedBoostUntil", nil)
				if humanoid.Parent and humanoid.WalkSpeed == walkSpeed then
					humanoid.WalkSpeed = 16
				end
			end
			if sparkles then
				sparkles:Destroy()
			end
		end)
		notify(player, ("%s: speed boost for %d seconds"):format(medName, strength))
	else -- regen
		notify(player, ("%s: healing %d health over time"):format(medName, strength))
		task.spawn(function()
			for _ = 1, strength do
				if humanoid.Health <= 0 or not humanoid.Parent then
					break
				end
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 1)
				task.wait(0.5)
			end
		end)
	end
end)

---------------------------------------------------------------------------
-- Messaging (phone Messaging app)
---------------------------------------------------------------------------
local privateChat = remote(events, "RemoteEvent", "PrivateChat")
local conversations = {} -- ["a|b"] = { lines }

local function convoKey(a, b)
	local x, y = tostring(a.UserId), tostring(b.UserId)
	if x > y then
		x, y = y, x
	end
	return x .. "|" .. y
end

local lastMessage = {}
privateChat.OnServerEvent:Connect(function(player, message, receiverName)
	if type(receiverName) ~= "string" then
		return
	end
	local receiver = Players:FindFirstChild(receiverName)
	if not receiver or receiver == player then
		return
	end
	local key = convoKey(player, receiver)
	local lines = conversations[key] or {}
	conversations[key] = lines

	if type(message) == "string" and message ~= "" then
		local now = os.clock()
		if lastMessage[player] and now - lastMessage[player] < 0.7 then
			return
		end
		lastMessage[player] = now
		message = message:sub(1, 150)

		-- Roblox requires filtering player-to-player text.
		local ok, filtered = pcall(function()
			local result = TextService:FilterStringAsync(message, player.UserId, Enum.TextFilterContext.PrivateChat)
			return result:GetChatForUserAsync(receiver.UserId)
		end)
		if not ok then
			return
		end
		table.insert(lines, player.Name .. ": " .. filtered)
		while #lines > MESSAGE_HISTORY do
			table.remove(lines, 1)
		end
		privateChat:FireClient(receiver, lines, player.Name)
	end
	-- The sender always gets the current conversation back.
	privateChat:FireClient(player, lines, receiver.Name)
end)

Players.PlayerRemoving:Connect(function(player)
	lastMessage[player] = nil
end)
