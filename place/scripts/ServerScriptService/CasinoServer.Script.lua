-- CasinoServer
-- Rebuilt Bellagio casino (the snapshot had the machines and tables but no code).
--   * 16 slot machines, 16 keno machines, 5 blackjack tables
--   * Three limit tiers; each machine/table shows its tier on a sign above it:
--       Standard          $10 - $5,000
--       High Limit        $1,000 - $250,000
--       Ultra High Limit  $100,000 - $10,000,000
--   * Bets come out of cash first, then bank. Winnings go to your bank.
-- All dealing, spinning and drawing happens here; CasinoClient only shows it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local TIERS = {
	Standard = { name = "Standard", min = 10, max = 5000, color = Color3.fromRGB(80, 170, 90) },
	High = { name = "High Limit", min = 1000, max = 250000, color = Color3.fromRGB(70, 130, 220) },
	Ultra = { name = "Ultra High Limit", min = 100000, max = 10000000, color = Color3.fromRGB(235, 185, 40) },
}
-- How many of each game get the higher tiers (the rest are Standard).
local HIGH_COUNT = { Slots = 4, Keno = 2, BlackJack = 1 }
local ULTRA_COUNT = { Slots = 2, Keno = 2, BlackJack = 1 }
local MAX_MULTIPLIER = 10000 -- biggest possible win is 10,000x the bet
local PLAY_DISTANCE = 16

-- Slots: reel weights and three-of-a-kind payouts (about 96% return).
local SLOT_GAMES={
 NeonWild={title="NEON WILD",reels=3,color=Color3.fromRGB(125,65,190),
  symbols={{"CHERRY",32},{"LEMON",24},{"BELL",18},{"BAR",12},{"SEVEN",8},{"DIAMOND",4},{"WILD",2}},
  pays={CHERRY=8,LEMON=12,BELL=20,BAR=40,SEVEN=100,DIAMOND=230,WILD=400},
  rules="3 matching symbols pay. WILD substitutes. Three WILDs pay 400x."},
 LuckySevens={title="LUCKY SEVENS",reels=3,color=Color3.fromRGB(180,45,55),
  symbols={{"CHERRY",30},{"LEMON",24},{"BELL",20},{"BAR",14},{"SEVEN",10},{"DIAMOND",2}},
  pays={CHERRY=7,LEMON=9,BELL=16,BAR=33,SEVEN=155,DIAMOND=400},
  rules="3 matching symbols pay. Otherwise one 7 pays 0.5x; two 7s pay 4x."},
 GemRush={title="GEM RUSH",reels=5,color=Color3.fromRGB(25,125,145),
  symbols={{"RUBY",30},{"EMERALD",27},{"SAPPHIRE",22},{"DIAMOND",16},{"WILD",5}},
  pays={RUBY={2,8,35},EMERALD={3,11,45},SAPPHIRE={3,14,60},DIAMOND={5,24,110},WILD={8,35,175}},
  rules="One payline: match 3+ from the LEFT. WILD substitutes. Best match pays."},
}

local function slotMultiplier(kind,reels)
 local config=SLOT_GAMES[kind];local best=0
 for symbol,payout in config.pays do
  local run=0
  for _,value in reels do
   if value==symbol or (kind~="LuckySevens" and value=="WILD") then run+=1 else break end
  end
  if kind=="GemRush" then if run>=3 then best=math.max(best,payout[math.min(run,5)-2]) end
  elseif run==3 then best=math.max(best,payout) end
 end
 if kind=="LuckySevens" and best==0 then
  local sevens=0;for _,value in reels do if value=="SEVEN" then sevens+=1 end end
  best=if sevens==2 then 4 elseif sevens==1 then 0.5 else 0
 end
 return best
end

local SYMBOLS = {
	{ "CHERRY", 30, 4 }, { "LEMON", 24, 5 }, { "ORANGE", 20, 8 }, { "GRAPE", 16, 10 },
	{ "BELL", 10, 15 }, { "BAR", 7, 30 }, { "SEVEN", 4, 80 }, { "DIAMOND", 2, 200 },
}
-- Keno payouts by number of picks -> hits -> multiplier.
local KENO_PAY = {
	[1] = { [1] = 3.6 }, [2] = { [2] = 14 }, [3] = { [2] = 1, [3] = 45 }, [4] = { [2] = 1, [3] = 6, [4] = 120 },
	[5] = { [3] = 2, [4] = 20, [5] = 600 }, [6] = { [3] = 1, [4] = 6, [5] = 90, [6] = 1800 },
	[7] = { [3] = 1, [4] = 3, [5] = 25, [6] = 350, [7] = 5000 },
	[8] = { [4] = 2, [5] = 12, [6] = 100, [7] = 1500, [8] = 10000 },
	[9] = { [4] = 1, [5] = 5, [6] = 50, [7] = 400, [8] = 4000, [9] = 10000 },
	[10] = { [5] = 3, [6] = 25, [7] = 150, [8] = 1000, [9] = 5000, [10] = 10000 },
}

local functions = ReplicatedStorage:WaitForChild("Functions")
local casinoFn = functions:FindFirstChild("Casino") or Instance.new("RemoteFunction")
casinoFn.Name = "Casino"
casinoFn.Parent = functions
local casinoEvent = ReplicatedStorage.Events:FindFirstChild("CasinoOpen") or Instance.new("RemoteEvent")
casinoEvent.Name = "CasinoOpen"
casinoEvent.Parent = ReplicatedStorage.Events

local function economy(action, player, amount)
	local fn = ServerStorage:WaitForChild("Economy", 10)
	return fn and fn:Invoke(action, player, amount)
end

local building = workspace:WaitForChild("BellagioBuilding")
local machines = {} -- id -> { kind, tier, focus }

---------------------------------------------------------------------------
-- Setting up machines, tables and signs
---------------------------------------------------------------------------
local function sign(part, tier, label)
	local gui = Instance.new("BillboardGui")
	gui.Name = "LimitSign"
	gui.Size = UDim2.new(0, 170, 0, 44)
	gui.StudsOffset = Vector3.new(0, 4.5, 0)
	gui.MaxDistance = 60
	gui.AlwaysOnTop = false
	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	text.BackgroundTransparency = 0.25
	text.TextColor3 = tier.color
	text.Font = Enum.Font.SourceSansBold
	text.TextScaled = true
	local function money(n)
		if n >= 1000000 then
			return "$" .. (n / 1000000) .. "M"
		elseif n >= 1000 then
			return "$" .. (n / 1000) .. "K"
		end
		return "$" .. n
	end
	text.Text = ("%s\n%s  %s - %s"):format(tier.name:upper(), label, money(tier.min), money(tier.max))
	text.Parent = gui
	gui.Parent = part
end

local function registerMachine(kind, id, model, tier, label, focusPart)
		local focus = focusPart or model:FindFirstChild("Focus", true) or model:FindFirstChild("Focus1", true)
			or model:FindFirstChildWhichIsA("BasePart", true)
		machines[id] = { id = id, kind = kind, tier = tier, focus = focus, model = model }
		sign(focus, tier, label)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "PlayPrompt"
		prompt.ActionText = "Play " .. label
		prompt.ObjectText = tier.name
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 9
		prompt.Parent = focus
		prompt.Triggered:Connect(function(player)
			-- Look this up fresh rather than using the closure's kind/tier: a
			-- machine can be relabelled after registration (see the Cleopatra
			-- reservation below), and this needs to see that change.
			local current = machines[id]
			casinoEvent:FireClient(player, current.kind, id, current.tier.name, current.tier.min, current.tier.max, current.tableCamera)
		end)
end

local function register(kind, list)
	local count = #list
	for i, model in ipairs(list) do
		local tierKey = "Standard"
		if i > count - ULTRA_COUNT[kind] then
			tierKey = "Ultra"
		elseif i > count - ULTRA_COUNT[kind] - HIGH_COUNT[kind] then
			tierKey = "High"
		end
		local label = kind == "Slots" and "Slots" or (kind == "Keno" and "Keno" or "Blackjack")
		registerMachine(kind, kind .. i, model, TIERS[tierKey], label)
	end
end

local function collect(folderName, childName)
	local folder = building:FindFirstChild(folderName)
	local list = {}
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child.Name == childName and child:IsA("Model") then
				table.insert(list, child)
			end
		end
	end
	-- Stable order so the same machines are always the high-limit ones.
	table.sort(list, function(a, b)
		local pa, pb = a:GetPivot().Position, b:GetPivot().Position
		return pa.X + pa.Z * 0.001 < pb.X + pb.Z * 0.001
	end)
	return list
end

register("Slots", collect("Slots", "Slots"))

-- Reserve one Standard-tier slot machine as the Cleopatra video slot instead
-- of a regular 3-reel one, so it's a distinct thing to find in the casino.
-- The id stays "Slots1" - only `kind` changes - because the ProximityPrompt
-- created back in register() already captured that id in its Triggered
-- closure, and it looks the machine up fresh by id every time it fires.
do
	local machine = machines["Slots1"]
	if machine then
		machine.kind = "Cleopatra"
		if machine.focus then
			local oldSign = machine.focus:FindFirstChild("LimitSign")
			if oldSign then
				oldSign:Destroy()
			end
			sign(machine.focus, machine.tier, "Cleopatra")
			local prompt = machine.focus:FindFirstChild("PlayPrompt")
			if prompt then
				prompt.ActionText = "Play Cleopatra"
			end
		end
		print("[CasinoServer] Slots1 reserved as the Cleopatra machine")
	else
		warn("[CasinoServer] couldn't find a Slots1 machine to make into the Cleopatra slot")
	end
end
-- Spread distinct slot games across the existing cabinets and limit tiers.
for i=2,16 do
 local machine=machines["Slots"..i]
 local kind=({"NeonWild","LuckySevens","GemRush","Slots"})[(i-2)%4+1]
 if machine and SLOT_GAMES[kind] then
  machine.kind=kind
  local old=machine.focus:FindFirstChild("LimitSign");if old then old:Destroy() end
  sign(machine.focus,machine.tier,SLOT_GAMES[kind].title)
  local prompt=machine.focus:FindFirstChild("PlayPrompt");if prompt then prompt.ActionText="Play "..SLOT_GAMES[kind].title end
 end
end
register("Keno", collect("KenoMachines", "Keno"))
register("BlackJack", collect("BlackJackTables", "BlackJack"))

---------------------------------------------------------------------------
-- v208: Baccarat, No-Limit Hold'em, Roulette, Dragon Fortune and extra
-- Ultra High Limit slot cabinets (rules live in CasinoTables).
---------------------------------------------------------------------------
local CasinoTables = require(script.Parent:WaitForChild("CasinoTables"))
TIERS.NoLimit = { name = "No Limit", min = 1, max = 1e12, color = Color3.fromRGB(230, 90, 60) }
TIERS.Roulette = { name = "Roulette", min = 10, max = 10000000, color = Color3.fromRGB(200, 60, 60) }
TIERS.Craps = { name = "Craps", min = 5, max = 10000000, color = Color3.fromRGB(220, 60, 60) } -- (the chip rack: $5 to $10M)
TIERS.CrapsHigh = { name = "Private Craps", min = 5, max = 10000000, color = Color3.fromRGB(235, 185, 40) }

local function retitle(id, kind, label, tier, signText)
	local machine = machines[id]
	if not machine then
		warn("[CasinoServer] no machine " .. id .. " to turn into " .. label)
		return
	end
	machine.kind = kind
	machine.tier = tier
	if machine.focus then
		local old = machine.focus:FindFirstChild("LimitSign")
		if old then
			old:Destroy()
		end
		sign(machine.focus, tier, label)
		if signText then
			local gui = machine.focus:FindFirstChild("LimitSign")
			local text = gui and gui:FindFirstChildOfClass("TextLabel")
			if text then
				text.Text = signText
			end
		end
		local prompt = machine.focus:FindFirstChild("PlayPrompt")
		if prompt then
			prompt.ActionText = "Play " .. label
			prompt.ObjectText = tier.name
		end
	end
	print(("[CasinoServer] %s is now %s"):format(id, label))
end

-- The three Standard blackjack tables upstairs: one stays blackjack, one deals
-- baccarat, one hosts no-limit hold'em (players choose the blinds).
TIERS.Baccarat = { name = "Baccarat", min = 10, max = 10000000, color = Color3.fromRGB(200, 170, 70) }
retitle("BlackJack2", "Baccarat", "Baccarat", TIERS.Baccarat)
retitle("BlackJack3", "Holdem", "Texas Hold'em", TIERS.NoLimit, "NO LIMIT\nTEXAS HOLD'EM - you set the blinds")

-- Slot floor mix: fewer Standard machines, more High / Ultra High Limit, every
-- game type (including the new Dragon Fortune) at more than one limit.
-- Slots are numbered by position (see collect()): 1-10 are the two long rows,
-- 11-15 the diagonal row.
local SLOT_LAYOUT = {
	{ "Cleopatra", "Standard" }, { "Slots", "Standard" }, { "DragonFortune", "Standard" }, { "NeonWild", "Standard" },
	{ "LuckySevens", "High" }, { "GemRush", "High" }, { "Slots", "High" }, { "DragonFortune", "High" },
	{ "Slots", "Ultra" }, { "DragonFortune", "Ultra" }, { "Cleopatra", "Ultra" }, { "NeonWild", "Ultra" },
	{ "Slots", "Ultra" }, { "GemRush", "Ultra" }, { "LuckySevens", "Ultra" },
}
local SLOT_TITLES = { Slots = "Slots", Cleopatra = "Cleopatra", DragonFortune = "Dragon Fortune", NeonWild = "NEON WILD", LuckySevens = "LUCKY SEVENS", GemRush = "GEM RUSH" }
for i, spec in ipairs(SLOT_LAYOUT) do
	if machines["Slots" .. i] then
		retitle("Slots" .. i, spec[1], SLOT_TITLES[spec[1]] or spec[1], TIERS[spec[2]])
	end
end

-- Roulette: built on clear casino floor.
do
	-- Put a Part named "RouletteSpot" on the casino floor (anywhere in
	-- BellagioBuilding) where the table should stand; its front faces the players.
	local marker = building:FindFirstChild("RouletteSpot", true)
	local id = "Roulette1"
	local spot = nil
	if marker and marker:IsA("BasePart") then
		marker.Transparency = 1
		marker.CanCollide = false
		spot = CFrame.new(marker.Position - Vector3.new(0, marker.Size.Y / 2, 0)) * marker.CFrame.Rotation
	end
	if spot then
		local machine = { id = id, kind = "Roulette", tier = TIERS.Roulette }
		machines[id] = machine
		local focus = CasinoTables.buildRoulette(machine, spot, building)
		machines[id] = nil
		registerMachine("Roulette", id, machine.model, TIERS.Roulette, "Roulette", focus)
		local registered = machines[id]
		for k, v in machine do
			if registered[k] == nil then
				registered[k] = v
			end
		end
		print("[CasinoServer] roulette table built at " .. tostring(spot.Position))
	else
		print("[CasinoServer] roulette: add a Part named RouletteSpot to BellagioBuilding to place the table")
	end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local lastAction = {}

local function validBet(player, machine, bet)
	bet=tonumber(bet)
	if not bet or bet~=bet or math.abs(bet)==math.huge then return nil,"Enter a valid bet" end
	bet=math.floor(bet)
	if bet < machine.tier.min or bet > machine.tier.max then
		return nil, ("Bets here are $%d - $%d"):format(machine.tier.min, machine.tier.max)
	end
	if not economy("Charge", player, bet) then
		return nil, "Not enough money"
	end
	return bet
end

-- Winnings are held, not paid immediately - crediting them the instant you
-- spin lets the player just watch their balance number for the outcome
-- instead of the reels, which defeats the point of the animation. The
-- client calls "Reveal" once its spin/draw animation finishes; a timeout
-- auto-pays it regardless, so a closed window never eats a win.
local pendingWins = {}
local REVEAL_TIMEOUT = 8

local function holdWin(player, id, amount)
	local previous=pendingWins[player]
    if previous and not previous.paid then previous.paid=true;economy("AddBank",player,previous.amount) end
    if amount <= 0 then return end
    local token = { id = id, amount = amount, paid = false }
	pendingWins[player] = token
	task.delay(REVEAL_TIMEOUT, function()
		if pendingWins[player] == token and not token.paid then
			token.paid = true
			economy("AddBank", player, amount)
		end
	end)
end

local function pay(player, amount)
	if amount > 0 then
		economy("AddBank", player, amount)
	end
end

local function nearMachine(player, machine)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and machine.focus and (root.Position - machine.focus.Position).Magnitude <= PLAY_DISTANCE
end

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------
local totalWeight = 0
for _, s in ipairs(SYMBOLS) do
	totalWeight += s[2]
end
local function spinReel()
	local roll = math.random() * totalWeight
	for _, s in ipairs(SYMBOLS) do
		roll -= s[2]
		if roll <= 0 then
			return s
		end
	end
	return SYMBOLS[1]
end

local function playSlots(player, machine, bet)
	local reels = { spinReel(), spinReel(), spinReel() }
	local multiplier = 0
	if reels[1][1] == reels[2][1] and reels[2][1] == reels[3][1] then
		multiplier = reels[1][3]
	else
		local cherries = 0
		for _, r in ipairs(reels) do
			if r[1] == "CHERRY" then
				cherries += 1
			end
		end
		multiplier = cherries == 2 and 2 or (cherries == 1 and 1 or 0)
	end
	local win = math.floor(bet * math.min(multiplier, MAX_MULTIPLIER))
	holdWin(player, machine.id, win)
	return { ok = true, reels = { reels[1][1], reels[2][1], reels[3][1] }, win = win, multiplier = multiplier }
end

---------------------------------------------------------------------------
local function playVariant(player,machine,bet)
 local config=SLOT_GAMES[machine.kind];local weight=0
 for _,symbol in config.symbols do weight+=symbol[2] end
 local reels={}
 for i=1,config.reels do
  local roll=math.random()*weight;local chosen=config.symbols[#config.symbols][1]
  for _,symbol in config.symbols do roll-=symbol[2];if roll<=0 then chosen=symbol[1];break end end
  reels[i]=chosen
 end
 local multiplier=slotMultiplier(machine.kind,reels)
 local win=math.floor(bet*math.min(multiplier,MAX_MULTIPLIER))
 holdWin(player,machine.id,win)
 return {ok=true,reels=reels,win=win,multiplier=multiplier}
end

-- Cleopatra - a real 3-row, 5-reel, 20-payline video slot with wilds,
-- scatters, and a free-spins bonus (landing 3+ scatters anywhere on the
-- grid triggers 10-20 free spins at a 3x multiplier, the same idea the real
-- IGT Cleopatra slot is known for). The 20 lines are the standard straight/
-- V/zigzag pattern set used across this whole genre of slot - I don't have
-- verified data for the real machine's exact line layout, so this isn't a
-- byte-for-byte reproduction of it, just the same kind of machine.
--
-- Your bet is the total amount at risk (same as every other game in this
-- casino) - it's split evenly across the 20 lines internally, rather than
-- multiplying your cost by 20 the way a real slot's "bet per line" would.
---------------------------------------------------------------------------
local CLEO_SYMBOLS = {
	{ "QUEEN", 30, { 0, 0, 5, 15, 60 } }, { "KING", 26, { 0, 0, 5, 20, 70 } },
	{ "ACE", 22, { 0, 0, 8, 25, 90 } }, { "ANKH", 16, { 0, 0, 12, 40, 150 } },
	{ "EYE", 12, { 0, 0, 18, 60, 250 } }, { "SCARAB", 8, { 0, 0, 25, 100, 400 } },
	{ "SPHINX", 3, { 0, 0, 0, 0, 0 } }, -- scatter: pays nothing itself, triggers the bonus
	{ "CLEOPATRA", 4, { 0, 0, 40, 200, 1000 } }, -- wild
}
local CLEO_SCATTER_SPINS = { [3] = 10, [4] = 15, [5] = 20 }
local CLEO_BONUS_MULTIPLIER = 3
local CLEO_ROWS = 3

-- The 20 standard paylines for a 3-row x 5-reel slot (row 1 = top, 3 = bottom).
local CLEO_LINES = {
	{ 2, 2, 2, 2, 2 }, { 1, 1, 1, 1, 1 }, { 3, 3, 3, 3, 3 }, { 1, 2, 3, 2, 1 }, { 3, 2, 1, 2, 3 },
	{ 1, 1, 2, 3, 3 }, { 3, 3, 2, 1, 1 }, { 2, 1, 1, 1, 2 }, { 2, 3, 3, 3, 2 }, { 1, 2, 1, 2, 1 },
	{ 3, 2, 3, 2, 3 }, { 2, 1, 2, 1, 2 }, { 2, 3, 2, 3, 2 }, { 1, 2, 2, 2, 1 }, { 3, 2, 2, 2, 3 },
	{ 2, 2, 1, 2, 2 }, { 2, 2, 3, 2, 2 }, { 1, 3, 1, 3, 1 }, { 3, 1, 3, 1, 3 }, { 1, 1, 3, 3, 1 },
}

local cleoWeight = 0
for _, s in ipairs(CLEO_SYMBOLS) do
	cleoWeight += s[2]
end
local function cleoSymbol()
	local roll = math.random() * cleoWeight
	for _, s in ipairs(CLEO_SYMBOLS) do
		roll -= s[2]
		if roll <= 0 then
			return s[1]
		end
	end
	return CLEO_SYMBOLS[1][1]
end

-- grid[col][row], col 1-5, row 1-3.
local function cleoGrid()
	local grid = {}
	for col = 1, 5 do
		grid[col] = {}
		for row = 1, CLEO_ROWS do
			grid[col][row] = cleoSymbol()
		end
	end
	return grid
end

-- Left-to-right run along one line, wild substitutes for anything except scatter.
local function linePayout(symbols, betPerLine)
	local firstSymbol = symbols[1]
	if firstSymbol == "SPHINX" then
		return 0 -- a scatter on reel 1 doesn't start a payline
	end
	local target = nil -- nil = still undecided (reel 1 was a wild)
	if firstSymbol ~= "CLEOPATRA" then
		target = firstSymbol
	end
	local run = 1
	for i = 2, 5 do
		local sym = symbols[i]
		if sym == "SPHINX" then
			break
		elseif sym == "CLEOPATRA" then
			run += 1
		elseif not target then
			target = sym
			run += 1
		elseif sym == target then
			run += 1
		else
			break
		end
	end
	if run < 3 then
		return 0
	end
	local symbolName = target or "CLEOPATRA"
	local def
	for _, s in ipairs(CLEO_SYMBOLS) do
		if s[1] == symbolName then
			def = s
		end
	end
	return math.floor(betPerLine * (def[3][run] or 0))
end

-- Returns: total win across all 20 lines, scatter count, which lines paid
-- (for the client to highlight), and the full grid (for display).
local function cleoSpin(betTotal)
	local betPerLine = betTotal / #CLEO_LINES
	local grid = cleoGrid()
	local win, hitLines = 0, {}
	for lineIndex, line in ipairs(CLEO_LINES) do
		local symbols = {}
		for col = 1, 5 do
			symbols[col] = grid[col][line[col]]
		end
		local lineWin = linePayout(symbols, betPerLine)
		if lineWin > 0 then
			win += lineWin
			table.insert(hitLines, { line = lineIndex, win = lineWin })
		end
	end
	local scatters = 0
	for col = 1, 5 do
		for row = 1, CLEO_ROWS do
			if grid[col][row] == "SPHINX" then
				scatters += 1
			end
		end
	end
	-- Flatten the grid to {col1row1, col1row2, col1row3, col2row1, ...} for the client.
	local flat = {}
	for col = 1, 5 do
		for row = 1, CLEO_ROWS do
			table.insert(flat, grid[col][row])
		end
	end
	return flat, win, scatters, hitLines
end

local function playCleopatra(player, machine, bet)
	local stake, err = validBet(player, machine, bet)
	if not stake then
		return { ok = false, message = err }
	end
	local grid, win, scatters, hitLines = cleoSpin(stake)

	local bonus = nil
	local spinCount = CLEO_SCATTER_SPINS[math.min(scatters, 5)]
	if spinCount then
		local freeSpins, bonusTotal = {}, 0
		for i = 1, spinCount do
			local fGrid, fWin = cleoSpin(stake)
			fWin *= CLEO_BONUS_MULTIPLIER
			bonusTotal += fWin
			freeSpins[i] = { grid = fGrid, win = fWin }
		end
		bonus = { spins = spinCount, results = freeSpins, total = bonusTotal }
		win += bonusTotal
	end

	holdWin(player, machine.id, win)
	return { ok = true, grid = grid, win = win, scatters = scatters, hitLines = hitLines, bonus = bonus }
end

---------------------------------------------------------------------------
-- Keno
---------------------------------------------------------------------------
local function playKeno(player, machine, bet, picks)
	if type(picks) ~= "table" or #picks < 1 or #picks > 10 then
		return { ok = false, message = "Pick 1 to 10 numbers" }
	end
	local chosen = {}
	for _, n in ipairs(picks) do
		n = tonumber(n)
		if not n or n % 1 ~= 0 or n < 1 or n > 80 or chosen[n] then
			return { ok = false, message = "Invalid numbers" }
		end
		chosen[n] = true
	end
	local stake, err = validBet(player, machine, bet)
	if not stake then
		return { ok = false, message = err }
	end
	local pool = {}
	for i = 1, 80 do
		pool[i] = i
	end
	local drawn, hits = {}, 0
	for i = 1, 20 do
		local j = math.random(i, 80)
		pool[i], pool[j] = pool[j], pool[i]
		drawn[i] = pool[i]
		if chosen[pool[i]] then
			hits += 1
		end
	end
	local multiplier = (KENO_PAY[#picks] or {})[hits] or 0
	local win = math.floor(stake * math.min(multiplier, MAX_MULTIPLIER))
	holdWin(player, machine.id, win)
	return { ok = true, drawn = drawn, hits = hits, win = win, multiplier = multiplier }
end

---------------------------------------------------------------------------
-- Blackjack (v88): shared physical-table round, built on the original v82
-- casino implementation. Slots, Cleopatra and Keno are completely untouched.
-- Players at the same BlackJack table bet during one short betting window,
-- receive separate hands, and all play against ONE shared dealer hand.
---------------------------------------------------------------------------
local SUITS = { "S", "H", "D", "C" }
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local BJ_BETTING_SECONDS = 7
local BJ_PLAY_SECONDS = 30
local BJ_FINISHED_SECONDS = 6
local blackjackTables = {} -- [machineId] = table state
local shoes = {} -- [machineId] = six-deck shoe

local function newShoe()
	local shoe = {}
	for _ = 1, 6 do
		for _, s in ipairs(SUITS) do
			for _, r in ipairs(RANKS) do
				table.insert(shoe, r .. s)
			end
		end
	end
	for i = #shoe, 2, -1 do
		local j = math.random(1, i)
		shoe[i], shoe[j] = shoe[j], shoe[i]
	end
	return shoe
end

local function getTable(id)
	local state = blackjackTables[id]
	if not state then
		shoes[id] = shoes[id] or newShoe()
		state = {
			id = id,
			shoe = shoes[id],
			phase = "Idle",
			dealer = {},
			players = {},
			order = {},
			round = 0,
			bettingEnds = 0,
			playEnds = 0,
			finishedEnds = 0,
		}
		blackjackTables[id] = state
	end
	return state
end

local function draw(state)
	if #state.shoe < 52 then
		state.shoe = newShoe()
		shoes[state.id] = state.shoe
	end
	return table.remove(state.shoe)
end

local function total(cards)
	local sum, aces = 0, 0
	for _, card in ipairs(cards) do
		local r = card:sub(1, -2)
		if r == "A" then
			sum += 11
			aces += 1
		elseif r == "J" or r == "Q" or r == "K" then
			sum += 10
		else
			sum += tonumber(r)
		end
	end
	while sum > 21 and aces > 0 do
		sum -= 10
		aces -= 1
	end
	return sum
end

local function participantCount(state)
	local n = 0
	for _, p in ipairs(state.order) do
		if state.players[p] then n += 1 end
	end
	return n
end

local function snapshot(state, player)
	local ps = state.players[player]
	local revealDealer = state.phase == "Finished" or state.phase == "Dealer"
	local dealerCards = {}
	if #state.dealer > 0 then
		for i, card in ipairs(state.dealer) do
			dealerCards[i] = (revealDealer or i == 1) and card or "??"
		end
	end
	local cards = ps and ps.cards or {}
	local visiblePlayers = {}
	for seat, p in ipairs(state.order) do
		local other = state.players[p]
		if other then
			table.insert(visiblePlayers, {
				seat = seat,
				userId = p.UserId,
				name = (p:GetAttribute("CharacterName") or p.DisplayName),
				username = p.Name,
				isYou = p == player,
				cards = table.clone(other.cards),
				total = #other.cards > 0 and total(other.cards) or nil,
				bet = other.bet,
				done = other.done,
				result = other.result,
				win = other.win,
			})
		end
	end
	return {
		ok = true,
		phase = state.phase,
		player = cards,
		playerTotal = #cards > 0 and total(cards) or nil,
		players = visiblePlayers,
		dealer = dealerCards,
		dealerTotal = revealDealer and #state.dealer > 0 and total(state.dealer) or nil,
		bet = ps and ps.bet or 0,
		canDouble = state.phase == "Playing" and ps ~= nil and not ps.done and #cards == 2,
		finished = state.phase == "Finished",
		result = ps and ps.result or "",
		win = ps and ps.win or 0,
		joined = ps ~= nil,
		canAct = state.phase == "Playing" and ps ~= nil and not ps.done,
		playersCount = participantCount(state),
		bettingSeconds = state.phase == "Betting" and math.max(0, math.ceil(state.bettingEnds - os.clock())) or 0,
		actionSeconds = state.phase == "Playing" and math.max(0, math.ceil(state.playEnds - os.clock())) or 0,
		restartSeconds = state.phase == "Finished" and math.max(0, math.ceil(state.finishedEnds - os.clock())) or 0,
	}
end

-- Physical blackjack cards. Only public snapshots reach replicated instances;
-- the unrevealed hole card never appears in card names, attributes or labels.
local TweenService=game:GetService("TweenService")
local function prepareTable(machine)
 local model=machine.model
 local felt,area=nil,0
 for _,part in model:GetDescendants() do
  if part:IsA("BasePart") and part.Color.G>part.Color.R*1.3 and part.Size.Y<0.6 then
   local size=part.Size.X*part.Size.Z
   if size>area then felt,area=part,size end
  end
 end
 if not felt then return end
 local right=Vector3.new(felt.CFrame.RightVector.X,0,felt.CFrame.RightVector.Z).Unit
 local forward=Vector3.new(-right.Z,0,right.X)
 local focus=machine.focus.Position
 if (focus-felt.Position):Dot(right)<0 then right=-right;forward=-forward end
 -- The long felt strip is the dealer edge, next to the chip tray.
 -- Place cards toward the clear curved half, not at that strip or prompt markers.
 local top=felt.Position.Y+felt.Size.Y/2
 for _,part in model:GetDescendants() do
  if part:IsA("BasePart") and part.Color.G>part.Color.R*1.3 and part.Size.Y<0.6 then
   top=math.max(top,part.Position.Y+part.Size.Y/2)
  end
 end
 top+=0.08
 local origin=Vector3.new(felt.Position.X,top,felt.Position.Z)
 local center=origin+right*2
 machine.tableCenter=center
 machine.tableCamera=CFrame.lookAt(center+Vector3.new(0,10.5,0)-right*0.5,center,right)
 machine.dealerAnchor=CFrame.lookAt(origin+right*1.15,origin+right*0.15)
 machine.handAnchors={}
 for i=1,3 do
  local at=origin+right*(i==2 and 3.15 or 2.75)+forward*((i-2)*1.85)
  machine.handAnchors[i]=CFrame.lookAt(at,at-right)
 end
 local folder=Instance.new("Folder");folder.Name="LiveBlackjackCards";folder.Parent=model
 machine.cardFolder=folder;machine.visibleCards={}
end

local cardSuits={S="♠",H="♥",D="♦",C="♣"}
local function physicalCard(machine,key,value,anchor,index,count)
 local record=machine.visibleCards[key]
 local playerHand=key:sub(1,4)=="Seat"
 local spacing=math.min(playerHand and 0.39 or 0.52,(playerHand and 0.8 or 2.4)/math.max(1,count-1))
 local goal=anchor*CFrame.new(((index-1)-(count-1)/2)*spacing,0.007*index,0)*CFrame.Angles(math.pi/2,0,0)
 if not record then
  local part=Instance.new("Part");part.Name=key;part.Size=Vector3.new(0.70,0.96,0.025)
  part.Anchored=true;part.CanCollide=false;part.CanTouch=false;part.CanQuery=false
  part.Material=Enum.Material.SmoothPlastic;part.CFrame=(machine.dealerAnchor+Vector3.new(0,0.15,0))*CFrame.Angles(math.pi/2,0,0)
  local gui=Instance.new("SurfaceGui");gui.Face=Enum.NormalId.Front;gui.SizingMode=Enum.SurfaceGuiSizingMode.FixedSize;gui.CanvasSize=Vector2.new(210,288);gui.LightInfluence=0;gui.Parent=part
  local face=Instance.new("TextLabel");face.Size=UDim2.fromScale(1,1);face.Font=Enum.Font.GothamBold;face.TextScaled=true;face.BorderSizePixel=0;face.Parent=gui
  local corner=Instance.new("TextLabel");corner.Name="CornerRank";corner.BackgroundTransparency=1
  corner.Position=UDim2.fromScale(0.03,0.03);corner.Size=UDim2.fromScale(0.30,0.26)
  corner.Font=Enum.Font.GothamBold;corner.TextScaled=true;corner.ZIndex=2;corner.Parent=gui
  part.Parent=machine.cardFolder;record={part=part,face=face,gui=gui,corner=corner};machine.visibleCards[key]=record
  TweenService:Create(part,TweenInfo.new(0.3,Enum.EasingStyle.Quad,Enum.EasingDirection.Out,0,false,(index-1)*0.09),{CFrame=goal}):Play()
 elseif record.goal~=goal then record.part.CFrame=goal end
 record.goal=goal
 if record.value~=value then
  record.value=value
  local hidden=value=="??";local suit=value:sub(-1)
  record.face.BackgroundColor3=hidden and Color3.fromRGB(35,57,110) or Color3.fromRGB(250,246,235)
  record.face.TextColor3=hidden and Color3.new(1,1,1) or ((suit=="H" or suit=="D") and Color3.fromRGB(185,35,45) or Color3.fromRGB(25,30,38))
  record.corner.Text=hidden and "" or value:sub(1,-2);record.corner.TextColor3=record.face.TextColor3
  record.face.Text=hidden and "◆\n◆" or (value:sub(1,-2).."\n"..(cardSuits[suit] or ""))
 end
end

for _,machine in machines do if machine.kind=="BlackJack" or machine.kind=="Baccarat" or machine.kind=="Holdem" then prepareTable(machine) end end
task.spawn(function()
 while true do
  for id,state in blackjackTables do
   local machine=machines[id]
   if machine and machine.cardFolder then
    local view=snapshot(state,nil);local keep={}
    for i,value in view.dealer do
     local key="Dealer"..i;keep[key]=true
     physicalCard(machine,key,value,machine.dealerAnchor,i,#view.dealer)
    end
    if #view.dealer>0 then
     keep.DealerLabel=true
     physicalCard(machine,"DealerLabel","??",machine.dealerAnchor*CFrame.new(0,0,0.65),1,1)
     local tag=machine.visibleCards.DealerLabel;tag.part.Size=Vector3.new(1.5,0.3,0.025);tag.gui.CanvasSize=Vector2.new(600,120)
     tag.face.BackgroundColor3=Color3.fromRGB(15,65,43);tag.face.TextColor3=Color3.fromRGB(240,204,100)
     tag.corner.Text=""
     tag.face.Text="DEALER"..(view.dealerTotal and (" | "..view.dealerTotal) or "")
    end
    for _,hand in view.players do
     local anchor=machine.handAnchors[hand.seat]
     if anchor then for i,value in hand.cards do
      local key="Seat"..hand.seat.."Card"..i;keep[key]=true
     physicalCard(machine,key,value,anchor,i,#hand.cards)
     end end
     if anchor then
      local key="Seat"..hand.seat.."Label";keep[key]=true
      physicalCard(machine,key,"??",anchor*CFrame.new(0,0,0.65),1,1)
      local label=machine.visibleCards[key];label.part.Size=Vector3.new(1.5,0.3,0.025)
      label.gui.CanvasSize=Vector2.new(520,120)
      label.face.BackgroundColor3=Color3.fromRGB(15,65,43);label.face.TextColor3=Color3.fromRGB(240,204,100)
      label.corner.Text=""
      label.face.Text=hand.name.."\n$"..hand.bet..(hand.total and (" | "..hand.total) or "")
     end
    end
    for key,record in machine.visibleCards do if not keep[key] then record.part:Destroy();machine.visibleCards[key]=nil end end
   end
  end
  task.wait(0.15)
 end
end)

CasinoTables.init({
	economy = economy, validBet = validBet, pay = pay, holdWin = holdWin, machines = machines,
	physicalCard = physicalCard, MAX_MULTIPLIER = MAX_MULTIPLIER,
})

local function settle(ps, result, multiplier)
	if ps.settled then return end
	ps.done = true
	ps.settled = true
	ps.result = result
	ps.win = math.floor(ps.bet * multiplier)
	pay(ps.player, ps.win)
end

local function allDone(state)
	if #state.order == 0 then return false end
	for _, p in ipairs(state.order) do
		local ps = state.players[p]
		if ps and not ps.done then return false end
	end
	return true
end

local function finishRound(state)
	state.phase = "Finished"
	state.finishedEnds = os.clock() + BJ_FINISHED_SECONDS
	local token = state.round
	task.spawn(function()
		task.wait(BJ_FINISHED_SECONDS)
		if state.round == token and state.phase == "Finished" then
			state.phase = "Idle"
			state.dealer = {}
			state.players = {}
			state.order = {}
			state.bettingEnds = 0
			state.playEnds = 0
			state.finishedEnds = 0
		end
	end)
end

local function dealerPlayAll(state)
	if state.phase ~= "Playing" then return end
	state.phase = "Dealer"
	task.wait(0.65)
	while total(state.dealer) < 17 do
		table.insert(state.dealer, draw(state))
		task.wait(0.65)
	end
	local dealerTotal = total(state.dealer)
	for _, p in ipairs(state.order) do
		local ps = state.players[p]
		if ps and not ps.settled then
			local pt = total(ps.cards)
			if dealerTotal > 21 then
				settle(ps, "Dealer busts - you win!", 2)
			elseif pt > dealerTotal then
				settle(ps, "You win!", 2)
			elseif pt == dealerTotal then
				settle(ps, "Push - bet returned", 1)
			else
				settle(ps, "Dealer wins", 0)
			end
		end
	end
	finishRound(state)
end

local function beginRound(state, roundToken)
	if state.phase ~= "Betting" or state.round ~= roundToken then return end
	if participantCount(state) == 0 then
		state.phase = "Idle"
		return
	end

	state.dealer = {}
	-- Real table deal order: one card around, dealer up-card, one card around,
	-- dealer hole-card. Everyone therefore shares exactly the same dealer hand.
	for _, p in ipairs(state.order) do
		local ps = state.players[p]
		if ps then table.insert(ps.cards, draw(state)) end
	end
	table.insert(state.dealer, draw(state))
	for _, p in ipairs(state.order) do
		local ps = state.players[p]
		if ps then table.insert(ps.cards, draw(state)) end
	end
	table.insert(state.dealer, draw(state))
	state.phase = "Playing"
	state.playEnds = os.clock() + BJ_PLAY_SECONDS

	local dealerBlackjack = total(state.dealer) == 21
	for _, p in ipairs(state.order) do
		local ps = state.players[p]
		if ps then
			local pt = total(ps.cards)
			if dealerBlackjack then
				if pt == 21 then settle(ps, "Both blackjack - push", 1)
				else settle(ps, "Dealer has blackjack", 0) end
			elseif pt == 21 then
				settle(ps, "BLACKJACK! Pays 3:2", 2.5)
			end
		end
	end
	if dealerBlackjack then
		finishRound(state)
	elseif allDone(state) then
		dealerPlayAll(state)
	else
		-- A player closing the UI or walking away must never freeze the table.
		local token = state.round
		task.spawn(function()
			task.wait(BJ_PLAY_SECONDS)
			if state.round ~= token or state.phase ~= "Playing" then return end
			for _, p in ipairs(state.order) do
				local waiting = state.players[p]
				if waiting and not waiting.done then
					waiting.done = true
					waiting.result = "Auto-stand - action timer expired"
				end
			end
			dealerPlayAll(state)
		end)
	end
end

local function startBetting(state)
	state.round += 1
	state.phase = "Betting"
	state.dealer = {}
	state.players = {}
	state.order = {}
	state.bettingEnds = os.clock() + BJ_BETTING_SECONDS
	state.playEnds = 0
	state.finishedEnds = 0
	local token = state.round
	task.spawn(function()
		task.wait(BJ_BETTING_SECONDS)
		beginRound(state, token)
	end)
end

local function blackjack(player, machine, id, action, bet)
	local state = getTable(id)

	if action == "View" then
		return snapshot(state, player)
	end

	if action == "Deal" then
		if state.phase == "Idle" or state.phase == "Finished" then
			startBetting(state)
		elseif state.phase ~= "Betting" then
			return { ok = false, message = "This table is already playing - join the next hand" }
		end
		if state.players[player] then
			return snapshot(state, player)
		end
		if participantCount(state)>=3 then return {ok=false,message="This table has three seats. Join another table or the next hand."} end
		local stake, err = validBet(player, machine, bet)
		if not stake then return { ok = false, message = err } end
		state.players[player] = {
			player = player,
			bet = stake,
			cards = {},
			done = false,
			settled = false,
			result = "",
			win = 0,
		}
		table.insert(state.order, player)
		return snapshot(state, player)
	end

	local ps = state.players[player]
	if not ps then
		return { ok = false, message = "Place a bet and join the next hand first" }
	end
	if state.phase ~= "Playing" then
		return snapshot(state, player)
	end
	if ps.done then
		return snapshot(state, player)
	end

	if action == "Hit" then
		table.insert(ps.cards, draw(state))
		local pt = total(ps.cards)
		if pt > 21 then
			settle(ps, "Bust! Over 21", 0)
		elseif pt == 21 then
			ps.done = true
			ps.result = "21 - waiting for dealer"
		end
	elseif action == "Stand" then
		ps.done = true
		ps.result = "Standing - waiting for dealer"
	elseif action == "Double" then
		if #ps.cards ~= 2 then
			return { ok = false, message = "You can only double on your first two cards" }
		end
		if not economy("Charge", player, ps.bet) then
			return { ok = false, message = "Not enough money to double" }
		end
		ps.bet *= 2
		table.insert(ps.cards, draw(state))
		if total(ps.cards) > 21 then
			settle(ps, "Bust! Over 21", 0)
		else
			ps.done = true
			ps.result = "Doubled - waiting for dealer"
		end
	else
		return { ok = false, message = "?" }
	end

	if allDone(state) then dealerPlayAll(state) end
	return snapshot(state, player)
end

---------------------------------------------------------------------------
-- Remote
---------------------------------------------------------------------------
casinoFn.OnServerInvoke = function(player, action, id, a, b)
	if action == "Reveal" then
		local token = pendingWins[player]
		if token and token.id == id and not token.paid then
			token.paid = true
			economy("AddBank", player, token.amount)
		end
		return true
	end

	local machine = machines[id]
	if type(action) ~= "string" or not machine then
		return { ok = false, message = "Unknown machine" }
	end
	if not nearMachine(player, machine) then
		return { ok = false, message = "Walk up to the machine" }
	end
	if machine.kind == "BlackJack" and action == "View" then
		return blackjack(player, machine, id, "View", a)
	end
	if CasinoTables.isTable(machine.kind) and action == "View" then
		return CasinoTables.handle(player, machine, "View", a, b)
	end
	local now = os.clock()
	if lastAction[player] and now - lastAction[player] < 0.25 then
		return { ok = false, message = "Slow down" }
	end
	lastAction[player] = now

	local handled = CasinoTables.handle(player, machine, action, a, b)
	if handled then
		return handled
	end
	if SLOT_GAMES[machine.kind] and action=="Spin" then
        local stake,err=validBet(player,machine,a)
        if not stake then return {ok=false,message=err} end
        return playVariant(player,machine,stake)
    elseif machine.kind == "Slots" and action == "Spin" then
		local stake, err = validBet(player, machine, a)
		if not stake then
			return { ok = false, message = err }
		end
		return playSlots(player, machine, stake)
	elseif machine.kind == "Cleopatra" and action == "Spin" then
		return playCleopatra(player, machine, a)
	elseif machine.kind == "Keno" and action == "Play" then
		return playKeno(player, machine, a, b)
	elseif machine.kind == "BlackJack" then
		return blackjack(player, machine, id, action, a)
	end
	return { ok = false, message = "?" }
end

Players.PlayerRemoving:Connect(function(player)
	pcall(CasinoTables.playerRemoving, player)
	for _, state in pairs(blackjackTables) do
		local ps = state.players[player]
		if ps then
			if state.phase == "Betting" then
				state.players[player] = nil
				for i = #state.order, 1, -1 do
					if state.order[i] == player then table.remove(state.order, i) end
				end
			elseif not ps.settled then
				ps.done = true
				ps.settled = true
				ps.result = "Left table - bet forfeited"
				ps.win = 0
				if state.phase == "Playing" and allDone(state) then dealerPlayAll(state) end
			end
		end
	end
	lastAction[player] = nil
end)

-- (Security gates are handled by ServerScriptService.SecurityGates.)

local counts = {}
for _, m in pairs(machines) do
	counts[m.kind] = (counts[m.kind] or 0) + 1
end
-- v289: the Luxor casino floor (tools/build_luxor.luau tags its games "LuxorCasino" with a
-- CasinoKind attribute): the same games, playable there - slots (every title), keno, blackjack,
-- baccarat, hold'em, and roulette built on the "Roulette" markers
do
	local CollectionService = game:GetService("CollectionService")
	local n = 0
	local TITLES = { "Slots", "Cleopatra", "DragonFortune", "NeonWild", "LuckySevens", "GemRush" }
	local LABEL = { Slots = "Slots", Keno = "Keno", BlackJack = "Blackjack", Baccarat = "Baccarat", Holdem = "Texas Hold'em" }
	local function add(model)
		local kind = model:GetAttribute("CasinoKind")
		n += 1
		local id = "Luxor" .. tostring(kind) .. n
		if kind == "Craps" and model:IsA("BasePart") then
			-- v295: a craps table built on the marker (like roulette)
			model.Transparency = 1
			model.CanCollide = false
			local spot = CFrame.new(model.Position - Vector3.new(0, model.Size.Y / 2, 0)) * model.CFrame.Rotation
			local tier = if model:GetAttribute("HighLimit") then TIERS.CrapsHigh else TIERS.Craps
			local machine = { id = id, kind = "Craps", tier = tier }
			machines[id] = machine
			local ok, err = pcall(function()
				local focus = CasinoTables.buildCraps(machine, spot, model.Parent)
				machines[id] = nil
				registerMachine("Craps", id, machine.model, tier, "Craps", focus)
				for k, v in machine do if machines[id][k] == nil then machines[id][k] = v end end
			end)
			if not ok then machines[id] = nil warn("[CasinoServer] Luxor craps: " .. tostring(err)) end
			return
		end
		if kind == "Roulette" and model:IsA("BasePart") then
			model.Transparency = 1
			model.CanCollide = false
			local spot = CFrame.new(model.Position - Vector3.new(0, model.Size.Y / 2, 0)) * model.CFrame.Rotation
			local machine = { id = id, kind = "Roulette", tier = TIERS.Roulette }
			machines[id] = machine
			local ok, err = pcall(function()
				local focus = CasinoTables.buildRoulette(machine, spot, model.Parent)
				machines[id] = nil
				registerMachine("Roulette", id, machine.model, TIERS.Roulette, "Roulette", focus)
				for k, v in machine do if machines[id][k] == nil then machines[id][k] = v end end
			end)
			if not ok then machines[id] = nil warn("[CasinoServer] Luxor roulette: " .. tostring(err)) end
			return
		end
		if not model:IsA("Model") then return end
		local k = if kind == "Blackjack" then "BlackJack" else kind
		if not LABEL[k] then return end
		local tier = if k == "Baccarat" then TIERS.Baccarat elseif k == "Holdem" then TIERS.NoLimit
			elseif model:GetAttribute("HighLimit") then TIERS.Ultra else TIERS.Standard
		local ok, err = pcall(registerMachine, if k == "Baccarat" or k == "Holdem" then "BlackJack" else k, id, model, tier, LABEL[k])
		if ok and k ~= "BlackJack" and k ~= "Slots" and k ~= "Keno" then pcall(retitle, id, k, LABEL[k], tier) end
		if ok and k == "Slots" then
			local t = TITLES[(n % #TITLES) + 1]
			if t ~= "Slots" then pcall(retitle, id, t, SLOT_TITLES[t] or t, tier) end
		end
		if ok and (k == "BlackJack" or k == "Baccarat" or k == "Holdem") and machines[id] then pcall(prepareTable, machines[id]) end
		if not ok then warn("[CasinoServer] Luxor " .. id .. ": " .. tostring(err)) end
	end
	for _, m in CollectionService:GetTagged("LuxorCasino") do add(m) end
	CollectionService:GetInstanceAddedSignal("LuxorCasino"):Connect(add)
	print(("[CasinoServer] Luxor casino: %d games"):format(n))
end

local summary = {}
for kind, n in pairs(counts) do
	table.insert(summary, ("%d %s"):format(n, kind))
end
print(("[CasinoServer] v89 ready: %s | original casino + visible multiplayer hands + automatic blackjack restart"):format(table.concat(summary, ", ")))
