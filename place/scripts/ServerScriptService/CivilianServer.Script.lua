-- CivilianServer
-- Ambient pedestrians (the snapshot had 10 dressed character templates in
-- Workspace.AIHolder just standing frozen, with empty walk/jump/health
-- scripts). Clones them across the city with simple wander AI. A minority
-- wander as street dealers you can talk to for illegal drugs, since the
-- pharmacy on the phone only sells legal stuff now.
--
-- Dealers restock randomly and have randomised purity, so prices and effects
-- vary buy to buy - the same dealer might be a good deal or a rip-off.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local PathfindingService = game:GetService("PathfindingService")

local TOTAL_CIVILIANS = 24
local DEALER_CHANCE = 1 / 6 -- roughly one in six wanderers is a dealer
local WANDER_RADIUS = 45
local WALK_SPEED_RANGE = { 12, 16 }
local RESPAWN_DELAY = 25 -- seconds after death before a replacement appears

-- City-wide anchor points (from the map's own spawn point clusters), so
-- pedestrians spread across the whole city rather than clumping in one spot.
local ANCHORS = {
	Vector3.new(102, 2, 674), Vector3.new(-907, 17, -199), Vector3.new(241, -2, 28),
	Vector3.new(1118, 2, 262), Vector3.new(139, 1, 639), Vector3.new(247, 4, -787),
	Vector3.new(1321, 8, -1079), Vector3.new(-1625, 6, 854), Vector3.new(2749, 1, -1376),
	Vector3.new(1961, 1, 1793), Vector3.new(-21, 1, 545),
}

local function economy(action, player, amount)
	local fn = ServerStorage:WaitForChild("Economy", 10)
	return fn and fn:Invoke(action, player, amount)
end

local function notify(player, text, seconds)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local old = playerGui:FindFirstChild("DealerNotice")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "DealerNotice"
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.2, 0)
	label.Size = UDim2.new(0.42, 0, 0.045, 0)
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

---------------------------------------------------------------------------
-- Templates: move out of the live map into storage, so the original 10
-- don't just stand frozen where the developer left them.
---------------------------------------------------------------------------
local aiHolder = workspace:FindFirstChild("AIHolder")
local templates = {}
if aiHolder then
	for _, model in ipairs(aiHolder:GetChildren()) do
		if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") then
			table.insert(templates, model)
		end
	end
	local storage = Instance.new("Folder")
	storage.Name = "CivilianTemplates"
	for _, model in ipairs(templates) do
		model.Parent = storage
	end
	storage.Parent = ServerStorage
end
print(("[CivilianServer] %d pedestrian template(s) found"):format(#templates))

---------------------------------------------------------------------------
-- Dealer stock: randomised each time someone opens a dealer's menu.
---------------------------------------------------------------------------
local METH_GRAMS = { 1, 2, 3.5, 7, 8, 14 }
local PERCOCET_MG = { 5, 10 }
local OXYCODONE_MG = { 15, 30 }

local function round(n)
	return math.floor(n + 0.5)
end

-- Meth: price/effect scale with grams and a random purity (70-99%).
local function methOffer()
	local grams = METH_GRAMS[math.random(1, #METH_GRAMS)]
	local purity = math.random(70, 99)
	local price = round(grams * math.random(35, 55) * (purity / 85))
	local duration = round(grams * 18 * (purity / 85))
	local walkSpeed = 28 + math.min(8, math.floor(purity / 20))
	return {
		label = ("Meth - %sg (%d%% pure) - $%d"):format(tostring(grams), purity, price),
		item = ("Meth (%sg, %d%% pure)"):format(tostring(grams), purity),
		price = price, kind = "speed", strength = duration, walkSpeed = walkSpeed,
	}
end

-- Pills: price/effect scale with pill count x strength (mg).
local function pillOffer(name, strengths)
	local mg = strengths[math.random(1, #strengths)]
	local count = ({ 1, 2, 5, 10 })[math.random(1, 4)]
	local price = round(count * mg * math.random(12, 18) / 10)
	local heal = math.min(300, round(count * mg * 0.9))
	return {
		label = ("%s - %d x %dmg - $%d"):format(name, count, mg, price),
		item = ("%s (%dx %dmg)"):format(name, count, mg),
		price = price, kind = "heal", strength = heal,
	}
end

-- v252: the rest of the menu goes through the Drugs script (ServerStorage.Drugs)
local function drugOffer(substance, name, priceRange, potencyRange)
	local potency = math.random(potencyRange[1], potencyRange[2]) / 100
	local price = round(math.random(priceRange[1], priceRange[2]) * potency)
	return {
		label = ("%s (%d%% strength) - $%d"):format(name, round(potency * 100), price),
		item = name, price = price, substance = substance, potency = potency,
	}
end

local function rollStock()
	local stock = { methOffer(), pillOffer("Percocet", PERCOCET_MG), pillOffer("Oxycodone", OXYCODONE_MG) }
	table.insert(stock, drugOffer("Weed", "Joint", { 20, 40 }, { 70, 130 }))
	if math.random() < 0.7 then
		table.insert(stock, drugOffer("PartyPills", "Party Pills", { 40, 80 }, { 70, 140 }))
	end
	if math.random() < 0.4 then
		table.insert(stock, drugOffer("Heroin", "Black Tar", { 90, 160 }, { 60, 150 }))
	end
	return stock
end

local function drugsFn()
	local fn = ServerStorage:FindFirstChild("Drugs")
	return if fn and fn:IsA("BindableFunction") then fn else nil
end

local function sellTo(player, offer)
	if not economy("Charge", player, offer.price) then
		return false, "You're short on cash"
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "Try again in a second"
	end
	if offer.substance then
		local fn = drugsFn()
		if fn then
			pcall(function()
				fn:Invoke("Give", player, offer.substance, offer.item, offer.potency)
			end)
		end
		return true, "Got the " .. offer.item
	end
	local tool = Instance.new("Tool")
	tool.Name = offer.item
	tool.ToolTip = "Click to use"
	tool.CanBeDropped = false
	tool:SetAttribute("Kind", offer.kind)
	tool:SetAttribute("Strength", offer.strength)
	tool:SetAttribute("DisplayName", offer.item)
	if offer.walkSpeed then
		tool:SetAttribute("WalkSpeed", offer.walkSpeed)
	end
	-- The snapshot created drug Tools but never gave them an Activated handler,
	-- so clicking/equipping them did nothing. Make each purchase consumable.
	local consumed = false
	tool.Activated:Connect(function()
		if consumed then return end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or tool.Parent ~= character then return end
		consumed = true
		-- v252: it gets you high too (meth = stimulants, pills = opioids)
		local fn = drugsFn()
		if fn then
			pcall(function()
				fn:Invoke("Use", player, if offer.kind == "speed" then "Stims" else "Opioids",
					math.clamp((offer.strength or 20) / (if offer.kind == "speed" then 60 else 90), 0.4, 2.2))
			end)
		end
		if offer.kind == "heal" then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + (offer.strength or 0))
		elseif offer.kind == "speed" then
			local original = humanoid.WalkSpeed
			humanoid.WalkSpeed = math.max(original, offer.walkSpeed or 28)
			local duration = math.clamp(offer.strength or 20, 5, 180)
			task.delay(duration, function()
				if humanoid.Parent and humanoid.Health > 0 and humanoid.WalkSpeed >= (offer.walkSpeed or 28) then
					humanoid.WalkSpeed = original > 0 and original or 16
				end
			end)
		end
		tool:Destroy()
	end)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 0.2, 0.3)
	handle.Color = Color3.fromRGB(230, 230, 180)
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	tool.Parent = backpack
	return true, "Got the " .. offer.item
end

---------------------------------------------------------------------------
-- Dealer dialogue (reuses the Chatter-style speech remote every NPC uses).
---------------------------------------------------------------------------
local function bye()
	return { "bye", "Never mind." }
end

local say -- forward declaration
local conversations = {}

local function dealerTalk(player, npc)
	local stock = npc:GetAttribute("_stock")
	if type(stock) ~= "table" then
		stock = rollStock()
	end
	local options = {}
	for i, offer in ipairs(stock) do
		table.insert(options, {
			"buy" .. i,
			offer.label,
			function(p)
				local ok, message = sellTo(p, offer)
				say(p, npc, message, { bye() })
				if ok then
					npc:SetAttribute("_stock", nil) -- restock next conversation
				end
			end,
		})
	end
	table.insert(options, bye())
	return "You didn't hear it from me. What do you need?", options
end

-- Small self-contained copy of NPCServer's conversation plumbing, so
-- dynamically spawned dealers don't need to be registered anywhere else.
say = function(player, npc, line, options)
	local handlers, wire = {}, {}
	for _, option in ipairs(options) do
		handlers[option[1]] = option[3] or false
		table.insert(wire, { option[1], option[2] })
	end
	conversations[player] = { npc = npc, handlers = handlers }
	local speech = npc:FindFirstChild("Speech")
	if speech then
		speech:FireClient(player, line, wire, "Dealer")
	end
end

local function inRange(player, npc)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local npcRoot = npc.PrimaryPart or npc:FindFirstChild("Torso")
	return root and npcRoot and (root.Position - npcRoot.Position).Magnitude <= 16
end

local function attachDealer(npc)
	npc:SetAttribute("Dealer", true)
	local speech = Instance.new("RemoteEvent")
	speech.Name = "Speech"
	speech.Parent = npc
	speech.OnServerEvent:Connect(function(player, choice)
		if not inRange(player, npc) then
			return
		end
		if choice == "StartConversation" then
			local line, options = dealerTalk(player, npc)
			say(player, npc, line, options)
			return
		end
		local convo = conversations[player]
		if not convo or convo.npc ~= npc then
			return
		end
		local handler = convo.handlers[choice]
		conversations[player] = nil
		if handler then
			handler(player)
		end
	end)
	local torso = npc:FindFirstChild("Torso")
	if torso then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "TalkPrompt"
		prompt.ActionText = "Talk"
		prompt.ObjectText = "???"
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = torso
		prompt.Triggered:Connect(function(player)
			local line, options = dealerTalk(player, npc)
			say(player, npc, line, options)
		end)
	end
end

---------------------------------------------------------------------------
-- Wandering
---------------------------------------------------------------------------
local function standOn(model, position)
	-- PivotTo places the model's centre at `position`; lift it so the feet
	-- (the bottom of its bounding box) land there instead, or it spawns
	-- sunk into the ground by about half its height.
	local _, size = model:GetBoundingBox()
	model:PivotTo(CFrame.new(position + Vector3.new(0, size.Y / 2 + 0.05, 0)))
end

local function groundPoint(centre, radius)
	local offset = Vector3.new((math.random() - 0.5) * 2 * radius, 0, (math.random() - 0.5) * 2 * radius)
	local origin = centre + offset + Vector3.new(0, 40, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local hit = workspace:Raycast(origin, Vector3.new(0, -120, 0), params)
	return hit and hit.Position or (centre + offset)
end

local function wander(npc, humanoid, anchor)
	while npc.Parent and humanoid.Health > 0 and not npc:GetAttribute("PoliceArrested") do
		local target = groundPoint(anchor, WANDER_RADIUS)
		humanoid:MoveTo(target)
		local reached = false
		local conn
		conn = humanoid.MoveToFinished:Connect(function()
			reached = true
		end)
		local waited = 0
		while not reached and waited < 12 and npc.Parent and humanoid.Health > 0 do
			task.wait(0.5)
			waited += 0.5
		end
		conn:Disconnect()
		task.wait(math.random(3, 9)) -- stand around for a bit
	end
end

local activeCivilians = {}
local REPORT_RADIUS = 95
local PANIC_RADIUS = 125
local REPORT_COOLDOWN = 8
local lastGunfireReport = {}

-- Gunfire is a local stimulus for civilians and a dispatch stimulus for police.
-- Nearby civilians run away from the shooter; one witness reports the shot,
-- giving the shooter a wanted level and a temporary citywide dispatch marker.
local shotFired = ServerStorage:WaitForChild("ShotFired", 15)
if shotFired then
	shotFired.Event:Connect(function(shooter)
		local character = shooter.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return end
		local witnessed = false
		for npc, data in pairs(activeCivilians) do
			local humanoid = data.humanoid
			local npcRoot = npc.Parent and (npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") or npc:FindFirstChild("Torso"))
			if npcRoot and humanoid and humanoid.Health > 0 then
				local offset = npcRoot.Position - root.Position
				local distance = offset.Magnitude
				if distance <= PANIC_RADIUS then
					local away = distance > 0.1 and offset.Unit or Vector3.new(1,0,0)
					local flee = npcRoot.Position + Vector3.new(away.X,0,away.Z) * 70
					humanoid.WalkSpeed = math.max(humanoid.WalkSpeed, 20)
					humanoid:MoveTo(flee)
				end
				if distance <= REPORT_RADIUS then witnessed = true end
			end
		end
		if witnessed then
			local now = os.clock()
			if not lastGunfireReport[shooter] or now - lastGunfireReport[shooter] >= REPORT_COOLDOWN then
				lastGunfireReport[shooter] = now
				local reportCrime = ServerStorage:FindFirstChild("ReportCrime")
				if reportCrime then reportCrime:Invoke(shooter, "Discharging a firearm", 1) end
			end
			shooter:SetAttribute("PoliceDispatchUntil", os.time() + 35)
			shooter:SetAttribute("LastCrimeX", root.Position.X)
			shooter:SetAttribute("LastCrimeY", root.Position.Y)
			shooter:SetAttribute("LastCrimeZ", root.Position.Z)
		end
	end)
end

local spawnedCount = 0

-- Physical civilian drops. Cash is not silently credited to the killer:
-- anyone nearby can pick the drop up, and abandoned drops clean themselves up.
local function dropCivilianLoot(position)
	local economy = ServerStorage:FindFirstChild("Economy")
	local drop = Instance.new("Part")
	drop.Name = "CivilianLoot"
	drop.Size = Vector3.new(1.1, 0.25, 0.75)
	drop.Anchored = true
	drop.CanCollide = false
	drop.Material = Enum.Material.SmoothPlastic
	drop.Color = Color3.fromRGB(92, 170, 92)
	drop.CFrame = CFrame.new(position + Vector3.new(0, 0.55, 0))
	drop:SetAttribute("CashAmount", math.random(12, 85))
	drop.Parent = workspace

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LootPrompt"
	prompt.ActionText = "Take"
	prompt.ObjectText = "Dropped cash"
	prompt.HoldDuration = 0.15
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = drop

	local taken = false
	prompt.Triggered:Connect(function(player)
		if taken or not drop.Parent then return end
		taken = true
		local amount = drop:GetAttribute("CashAmount") or 0
		if economy and amount > 0 then
			economy:Invoke("AddDirtyCash", player, amount) -- v255: looted = dirty
		end
		drop:Destroy()
	end)
	task.delay(45, function()
		if drop.Parent then drop:Destroy() end
	end)
end

local function spawnOne(isDealer)
	if #templates == 0 then
		return
	end
	local template = templates[math.random(1, #templates)]
	local npc = template:Clone()
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	humanoid.WalkSpeed = math.random(WALK_SPEED_RANGE[1], WALK_SPEED_RANGE[2])
	humanoid.DisplayName = isDealer and "???" or ""

	local anchor = ANCHORS[math.random(1, #ANCHORS)]
	standOn(npc, groundPoint(anchor, WANDER_RADIUS))
	npc.Parent = workspace
	spawnedCount += 1
	activeCivilians[npc] = { humanoid = humanoid }
	-- PoliceSystem's NPC arrests pick city pedestrians (dealers more often).
	-- Once one is taken into custody it belongs to the prison; a replacement
	-- pedestrian spawns here in the city.
	npc:SetAttribute("CityCivilian", true)
	local replaced = false
	npc:GetAttributeChangedSignal("PoliceArrested"):Connect(function()
		if replaced or not npc:GetAttribute("PoliceArrested") then return end
		replaced = true
		activeCivilians[npc] = nil
		task.delay(RESPAWN_DELAY, function()
			spawnOne(isDealer)
		end)
	end)

	if isDealer then
		attachDealer(npc)
	end

	humanoid.Died:Connect(function()
		local deathRoot = npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart") or npc:FindFirstChild("Torso")
		if deathRoot then
			dropCivilianLoot(deathRoot.Position)
		end
		-- Whoever killed this civilian gets reported the same way killing a
		-- player would - WeaponsServer tags any humanoid it damages with who
		-- did it, this just wasn't being checked for NPCs before.
		local tag=humanoid:FindFirstChild("creator")
		local killer=tag and tag.Value
		if not (killer and killer:IsA("Player")) then
			local uid=tonumber(humanoid:GetAttribute("LastDamagerUserId"))
			local damagedAt=tonumber(humanoid:GetAttribute("LastDamagedAt")) or 0
			if uid and os.time()-damagedAt<=30 then
				killer=Players:GetPlayerByUserId(uid)
			end
		end
		activeCivilians[npc]=nil
		if killer and killer:IsA("Player") then
			local reportCrime = ServerStorage:FindFirstChild("ReportCrime")
			if reportCrime then
				reportCrime:Invoke(killer,"Murder",2)
				print(("[CivilianServer] MURDER REPORTED: %s killed %s"):format(killer.Name,npc.Name))
			else
				warn("[CivilianServer] ReportCrime missing; cannot dispatch murder")
			end
			local kroot = killer.Character and killer.Character:FindFirstChild("HumanoidRootPart")
			if kroot then
				killer:SetAttribute("PoliceDispatchUntil", os.time() + 60)
				killer:SetAttribute("LastCrimeX", kroot.Position.X)
				killer:SetAttribute("LastCrimeY", kroot.Position.Y)
				killer:SetAttribute("LastCrimeZ", kroot.Position.Z)
			end
		end
		if replaced then return end
		replaced = true
		task.delay(RESPAWN_DELAY, function()
			spawnOne(isDealer)
		end)
	end)

	task.spawn(wander, npc, humanoid, anchor)
end

for i = 1, TOTAL_CIVILIANS do
	task.spawn(spawnOne, math.random() < DEALER_CHANCE)
end
print(("[CivilianServer] spawning %d pedestrians (~%d%% dealers)"):format(TOTAL_CIVILIANS, math.floor(DEALER_CHANCE * 100)))
