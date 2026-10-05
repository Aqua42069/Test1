-- AssetFreeze (v255): dirty money, asset freezes at felony money arrests, and the
-- freeze-safe places to keep money (DESIGN.md section 7.1 / 7.2).
--
--   * Dirty money is tracked by EconomyServer (DirtyCash / DirtyBank attributes):
--     heists, robbery, street gang jobs and looting pay dirty cash; jobs, paydays and
--     casino wins are clean.
--   * A felony money arrest (robbery, heist, drugs, theft...) with dirty money on the
--     books FREEZES the player: the bank's dirty share goes into DA escrow and the
--     account pays nothing out (deposits still work), all cash on hand is seized (the
--     clean part is evidence, returned later), cars and helicopters are impounded, and
--     a home rented with dirty money is taken (lien).
--   * When the case is over (out of custody, no court date pending) the dirty escrow is
--     forfeited, clean seized cash is returned and the freeze and impound are lifted.
--   * Freeze-safe storage:
--       house safe        - inside your home (prompt by the front door), raid risk
--       safe deposit box  - bank vault, $500 to open; the DA drills it once it's known
--                           (money moved in while charged makes it known)
--       hidden stash      - bury up to 3 anywhere outdoors (B); only an informant finds it
--   * Raids follow a freeze: a search warrant on the house safe, a subpoena on a known
--     box, and now and then an informant gives up a stash.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")

local CFG = {
	BoxOpenFee = 500,
	MaxStashes = 3,
	StashMax = 5_000_000, -- per place
	RaidDelay = { 45, 120 }, -- seconds after a freeze until the warrants are served
	SafeRaidChance = 0.5, -- house safe holding dirty money
	SafeRaidChanceClean = 0.15,
	InformantChance = 0.12, -- per hidden stash
	CaseEndGrace = 20, -- seconds out of custody before the case closes
	-- charges that make it a money case (lower-case substrings)
	MoneyCrimes = { "robbery", "heist", "theft", "carjack", "drug", "dealing", "traffick", "smuggl", "launder", "fraud", "stolen", "burglary" },
}

local VAULT_CENTER = Vector3.new(799.1, -25.4, -2161.5) -- Workspace.Bank.FacilityMap.Zones.DepositVault_1

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function economy(action: string, player: Player, ...): any
	local fn = ServerStorage:FindFirstChild("Economy")
	if not fn then
		return nil
	end
	return fn:Invoke(action, player, ...)
end

local function cashValue(player: Player): IntValue?
	local v = player:FindFirstChild("Cash")
	return if v and v:IsA("IntValue") then v else nil
end

local function bankValue(player: Player): IntValue?
	local v = player:FindFirstChild("Money")
	return if v and v:IsA("IntValue") then v else nil
end

local function money(n: number): string
	local s = tostring(math.floor(n))
	while true do
		local r, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		s = r
		if k == 0 then
			break
		end
	end
	return "$" .. s
end

local function notify(player: Player, text: string, seconds: number?)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local old = playerGui:FindFirstChild("AssetNotice")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "AssetNotice"
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.26, 0)
	label.Size = UDim2.new(0.5, 0, 0.05, 0)
	label.BackgroundColor3 = Color3.fromRGB(90, 15, 15)
	label.BackgroundTransparency = 0.15
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Text = text
	label.Parent = gui
	gui.Parent = playerGui
	game:GetService("Debris"):AddItem(gui, seconds or 5)
end

local function inCustody(player: Player): boolean
	return player:GetAttribute("CustodyStage") ~= nil or player:GetAttribute("SentenceEnd") ~= nil
end

local function caseOpen(player: Player): boolean
	return player:GetAttribute("AssetsFrozen") == true or player:GetAttribute("CourtDateAt") ~= nil or inCustody(player)
end

---------------------------------------------------------------------------
-- saved state: { frozen = {...}?, safe = {amt, dirty}, box = {open, amt, dirty, known}, stashes = { ... }, houseDirty }
---------------------------------------------------------------------------
local store = nil
do
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, "LasVegas_Assets_v1")
	if ok then
		store = result
	end
end
local state: { [Player]: any } = {}
local loaded: { [Player]: boolean } = {}

local function blank(): any
	return { safe = { amt = 0, dirty = 0 }, box = { open = false, amt = 0, dirty = 0, known = false }, stashes = {} }
end

local function save(player: Player)
	local s = state[player]
	if not (store and s and loaded[player]) then
		return
	end
	s.houseDirty = player:GetAttribute("HouseDirty") == true
	local ok, err = pcall(function()
		store:SetAsync("p_" .. player.UserId, s)
	end)
	if not ok then
		warn("[AssetFreeze] save failed for " .. player.Name .. ": " .. tostring(err))
	end
end

---------------------------------------------------------------------------
-- remotes
---------------------------------------------------------------------------
local function remote(className: string, name: string): any
	local r = ReplicatedStorage:FindFirstChild(name)
	if not r then
		r = Instance.new(className)
		r.Name = name
		r.Parent = ReplicatedStorage
	end
	return r
end
local uiEvent: RemoteEvent = remote("RemoteEvent", "StashUI")
local actionFn: RemoteFunction = remote("RemoteFunction", "StashAction")

---------------------------------------------------------------------------
-- the freeze
---------------------------------------------------------------------------
local function isMoneyCase(charges: string): boolean
	local c = charges:lower()
	for _, k in CFG.MoneyCrimes do
		if c:find(k, 1, true) then
			return true
		end
	end
	return false
end

local function showFrozen(player: Player)
	local f = state[player] and state[player].frozen
	player:SetAttribute("AssetsFrozen", if f then true else nil)
	player:SetAttribute("VehiclesImpounded", if f then true else nil)
	player:SetAttribute("FrozenEscrow", if f then f.escrow else nil)
	player:SetAttribute("SeizedCash", if f then f.cleanCash else nil)
end

local raid -- (forward)

local function freeze(player: Player, charges: string)
	local s = state[player]
	if not s then
		return
	end
	local cash, bank = cashValue(player), bankValue(player)
	if not (cash and bank) then
		return
	end
	local f = s.frozen or { at = os.time(), escrow = 0, cleanCash = 0 }
	f.charges = charges
	-- bank: the dirty share goes to DA escrow
	local dirtyBank = math.min(tonumber(economy("TakeDirty", player, "Money", bank.Value)) or 0, bank.Value)
	-- (TakeDirty removed the whole dirty share; take that much out of the account)
	bank.Value -= dirtyBank
	-- cash on hand: everything is seized; its dirty part goes to escrow, the clean part is evidence
	local dirtyCash = math.min(tonumber(economy("TakeDirty", player, "Cash", cash.Value)) or 0, cash.Value)
	local cleanCash = cash.Value - dirtyCash
	cash.Value = 0
	f.escrow += dirtyBank + dirtyCash
	f.cleanCash += cleanCash
	s.frozen = f
	showFrozen(player)
	-- home rented with dirty money
	local lien = player:GetAttribute("HouseDirty") == true and player:GetAttribute("HouseId") ~= nil
	if lien then
		player:SetAttribute("HouseLien", true)
		task.delay(1, function()
			if player.Parent then
				player:SetAttribute("HouseLien", nil)
			end
		end)
	end
	print(("[AssetFreeze] FREEZE %s (%s): bank dirty %d -> escrow, cash seized %d (dirty %d, clean %d), vehicles impounded%s"):format(
		player.Name, charges, dirtyBank, dirtyCash + cleanCash, dirtyCash, cleanCash, if lien then ", house lien" else ""))
	notify(player, ("ACCOUNT FROZEN - Clark County DA. %s seized, vehicles impounded"):format(money(dirtyBank + dirtyCash + cleanCash)), 8)
	task.spawn(save, player)
	task.delay(math.random(CFG.RaidDelay[1], CFG.RaidDelay[2]), raid, player)
end

local function unfreeze(player: Player)
	local s = state[player]
	local f = s and s.frozen
	if not f then
		return
	end
	s.frozen = nil
	local cash = cashValue(player)
	if cash and f.cleanCash > 0 then
		cash.Value += f.cleanCash
	end
	showFrozen(player)
	print(("[AssetFreeze] CASE CLOSED %s: %d dirty forfeited, %d clean cash returned, freeze lifted"):format(player.Name, f.escrow, f.cleanCash))
	notify(player, ("Case closed: %s forfeited to the county, %s of seized cash returned. Account unfrozen"):format(money(f.escrow), money(f.cleanCash)), 8)
	task.spawn(save, player)
end

-- search warrants / subpoenas / informants after a freeze
function raid(player: Player)
	local s = state[player]
	if not (player.Parent and s and s.frozen) then
		return
	end
	local found = {}
	local function seize(where: string, amt: number, dirty: number)
		if amt <= 0 then
			return
		end
		s.frozen.escrow += amt
		table.insert(found, ("%s %s"):format(where, money(amt)))
		print(("[AssetFreeze] RAID %s: %s seized %d (dirty %d)"):format(player.Name, where, amt, dirty))
	end
	-- house safe: search warrant
	local safe = s.safe
	if safe.amt > 0 then
		local chance = if safe.dirty > 0 then CFG.SafeRaidChance else CFG.SafeRaidChanceClean
		if math.random() < chance then
			seize("house safe", safe.amt, safe.dirty)
			s.safe = { amt = 0, dirty = 0 }
		end
	end
	-- safe deposit box: subpoenaed and drilled once the DA knows about it
	local box = s.box
	if box.known and box.amt > 0 then
		seize("safe deposit box", box.amt, box.dirty)
		box.amt, box.dirty = 0, 0
	end
	-- hidden stashes: only if someone talks
	for i = #s.stashes, 1, -1 do
		local st = s.stashes[i]
		if math.random() < CFG.InformantChance then
			seize("buried stash (an informant talked)", st.amt, st.dirty)
			table.remove(s.stashes, i)
		end
	end
	if #found > 0 then
		notify(player, "DA search warrant served: " .. table.concat(found, ", ") .. " seized", 8)
		uiEvent:FireClient(player, "stashes", s.stashes)
	else
		print(("[AssetFreeze] RAID %s: warrants served, nothing found"):format(player.Name))
	end
	showFrozen(player)
	task.spawn(save, player)
end

---------------------------------------------------------------------------
-- storage places
---------------------------------------------------------------------------
local function place(player: Player, kind: string, id: any): any?
	local s = state[player]
	if not s then
		return nil
	end
	if kind == "safe" then
		return s.safe
	elseif kind == "box" then
		return s.box
	elseif kind == "stash" then
		for _, st in s.stashes do
			if st.id == id then
				return st
			end
		end
	end
	return nil
end

local LABEL = { safe = "House safe", box = "Safe deposit box", stash = "Buried stash" }

local function info(player: Player, kind: string, id: any): any
	local p = place(player, kind, id)
	local cash = cashValue(player)
	return {
		kind = kind,
		id = id,
		title = LABEL[kind] or kind,
		amount = p and p.amt or 0,
		cash = cash and cash.Value or 0,
		needsOpen = kind == "box" and p ~= nil and not p.open,
		openFee = CFG.BoxOpenFee,
		frozen = player:GetAttribute("AssetsFrozen") == true,
	}
end

local function near(player: Player, pos: Vector3, range: number): boolean
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root ~= nil and (root.Position - pos).Magnitude <= range
end

-- where each place is, for the distance check
local safeParts: { [Player]: BasePart } = {}
local boxPanel: BasePart? = nil

local function placePos(player: Player, kind: string, p: any): Vector3?
	if kind == "safe" then
		local part = safeParts[player]
		return part and part.Position
	elseif kind == "box" then
		return boxPanel and boxPanel.Position
	elseif kind == "stash" then
		return Vector3.new(p.x, p.y, p.z)
	end
	return nil
end

local function openUI(player: Player, kind: string, id: any)
	uiEvent:FireClient(player, "open", info(player, kind, id))
end

local function outdoorsSpot(player: Player): (Vector3?, string?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (root and hum) or hum.Health <= 0 or hum.SeatPart then
		return nil, "You can't dig here"
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	if workspace:Raycast(root.Position, Vector3.new(0, 80, 0), params) then
		return nil, "Bury it outdoors - there's a roof over you"
	end
	local ground = workspace:Raycast(root.Position, Vector3.new(0, -12, 0), params)
	if not ground then
		return nil, "Stand on the ground"
	end
	return ground.Position, nil
end

actionFn.OnServerInvoke = function(player: Player, action: any, kind: any, id: any, amount: any): (boolean, string?, any?)
	if not loaded[player] then
		return false, "Still loading"
	end
	if type(action) ~= "string" or type(kind) ~= "string" then
		return false, "?"
	end
	if inCustody(player) then
		return false, "Not while you're in custody"
	end
	local s = state[player]
	local cash = cashValue(player)
	if not cash then
		return false, "?"
	end
	amount = math.floor(tonumber(amount) or 0)

	if action == "bury" then
		if #s.stashes >= CFG.MaxStashes then
			return false, ("You already have %d stashes - dig one up first"):format(CFG.MaxStashes)
		end
		local pos, why = outdoorsSpot(player)
		if not pos then
			return false, why
		end
		if amount <= 0 or amount > cash.Value or amount > CFG.StashMax then
			return false, "Enter an amount you're carrying"
		end
		local dirty = tonumber(economy("TakeDirty", player, "Cash", amount)) or 0
		cash.Value -= amount
		local st = { id = tostring(os.time()) .. tostring(math.random(100, 999)), x = pos.X, y = pos.Y, z = pos.Z, amt = amount, dirty = dirty }
		table.insert(s.stashes, st)
		print(("[AssetFreeze] %s buried %d (dirty %d) at %.0f, %.0f, %.0f"):format(player.Name, amount, dirty, pos.X, pos.Y, pos.Z))
		uiEvent:FireClient(player, "stashes", s.stashes)
		task.spawn(save, player)
		return true, ("Buried %s - only you know where"):format(money(amount)), info(player, "stash", st.id)
	end

	local p = place(player, kind, id)
	if not p then
		return false, "Not found"
	end
	local pos = placePos(player, kind, p)
	if not pos or not near(player, pos, 14) then
		return false, "Too far away"
	end

	if action == "info" then
		return true, nil, info(player, kind, id)
	elseif action == "openbox" then
		if kind ~= "box" or p.open then
			return false, "?"
		end
		if not economy("Charge", player, CFG.BoxOpenFee) then
			return false, ("Opening a box costs %s"):format(money(CFG.BoxOpenFee))
		end
		p.open = true
		task.spawn(save, player)
		return true, "Box opened in your name", info(player, kind, id)
	elseif action == "deposit" then
		if kind == "box" and not p.open then
			return false, "Open a box first"
		end
		if amount <= 0 or amount > cash.Value then
			return false, "You don't have that much cash"
		end
		if p.amt + amount > CFG.StashMax then
			return false, ("It holds at most %s"):format(money(CFG.StashMax))
		end
		local dirty = tonumber(economy("TakeDirty", player, "Cash", amount)) or 0
		cash.Value -= amount
		p.amt += amount
		p.dirty += dirty
		-- moving money after charges looks like hiding assets: the DA learns of the box
		if kind == "box" and caseOpen(player) and not p.known then
			p.known = true
			print(("[AssetFreeze] %s moved money into a box while charged - the DA knows about it"):format(player.Name))
		end
		print(("[AssetFreeze] %s put %d (dirty %d) in their %s"):format(player.Name, amount, dirty, LABEL[kind]))
		task.spawn(save, player)
		return true, ("Stored %s"):format(money(amount)), info(player, kind, id)
	elseif action == "withdraw" then
		if amount <= 0 or amount > p.amt then
			return false, "There isn't that much in it"
		end
		local dirty = if p.amt > 0 then math.floor(p.dirty * amount / p.amt + 0.5) else 0
		p.amt -= amount
		p.dirty = math.max(0, p.dirty - dirty)
		cash.Value += amount
		economy("AddDirty", player, "Cash", dirty)
		local msg = ("Took %s"):format(money(amount))
		if kind == "stash" and p.amt <= 0 then
			for i, st in s.stashes do
				if st == p then
					table.remove(s.stashes, i)
					break
				end
			end
			uiEvent:FireClient(player, "stashes", s.stashes)
			msg ..= " - the stash is dug up"
		end
		print(("[AssetFreeze] %s took %d (dirty %d) from their %s"):format(player.Name, amount, dirty, LABEL[kind]))
		task.spawn(save, player)
		return true, msg, info(player, kind, id)
	end
	return false, "?"
end

---------------------------------------------------------------------------
-- world: the bank's box wall and each home's safe
---------------------------------------------------------------------------
local function prompt(parent: Instance, action: string, object: string, onTrigger: (Player) -> ())
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = 0.4
	pp.RequiresLineOfSight = false
	pp.MaxActivationDistance = 8
	pp.Parent = parent
	pp.Triggered:Connect(onTrigger)
	return pp
end

do
	local panel = Instance.new("Part")
	panel.Name = "SafeDepositBoxes"
	panel.Anchored = true
	panel.CanCollide = false
	panel.Size = Vector3.new(6, 6, 0.6)
	panel.Color = Color3.fromRGB(150, 140, 110)
	panel.Material = Enum.Material.DiamondPlate
	panel.CFrame = CFrame.new(VAULT_CENTER + Vector3.new(0, 3.2, 0))
	local bank = workspace:FindFirstChild("Bank")
	panel.Parent = bank or workspace
	boxPanel = panel
	prompt(panel, "Safe deposit box", "Bank vault", function(player)
		if loaded[player] then
			openUI(player, "box", nil)
		end
	end)
end

local function findSafeSpot(house: Model): CFrame?
	local door: BasePart? = nil
	for _, d in house:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "FrontDoor" then
			door = d
			break
		end
	end
	if not door then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { house }
	-- the inside is the side of the door with a roof over it
	for _, dir in { door.CFrame.LookVector, -door.CFrame.LookVector, door.CFrame.RightVector, -door.CFrame.RightVector } do
		local flat = Vector3.new(dir.X, 0, dir.Z)
		if flat.Magnitude > 0.5 then
			local spot = door.Position + flat.Unit * 5
			local roof = workspace:Raycast(spot, Vector3.new(0, 40, 0), params)
			local floor = workspace:Raycast(spot + Vector3.new(0, 2, 0), Vector3.new(0, -20, 0), params)
			if roof and floor then
				local at = floor.Position + Vector3.new(0, 1.25, 0)
				return CFrame.lookAt(at, at - flat.Unit)
			end
		end
	end
	return nil
end

local function placeSafe(player: Player)
	local old = safeParts[player]
	if old then
		old:Destroy()
		safeParts[player] = nil
	end
	local fn = ServerStorage:FindFirstChild("HouseOf")
	local house = fn and fn:Invoke(player)
	if not house then
		return
	end
	local cf = findSafeSpot(house)
	if not cf then
		warn("[AssetFreeze] no spot for a safe in " .. house:GetFullName())
		return
	end
	local safe = Instance.new("Part")
	safe.Name = "HouseSafe"
	safe.Anchored = true
	safe.Size = Vector3.new(2.2, 2.5, 2)
	safe.Color = Color3.fromRGB(45, 45, 50)
	safe.Material = Enum.Material.Metal
	safe.CFrame = cf
	safe:SetAttribute("Owner", player.UserId)
	safe.Parent = house
	safeParts[player] = safe
	prompt(safe, "Open safe", player.Name .. "'s safe", function(who)
		if who == player then
			openUI(player, "safe", nil)
		else
			notify(who, "It's locked")
		end
	end)
end

---------------------------------------------------------------------------
-- players
---------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	local t0 = os.clock()
	while player.Parent and not player:GetAttribute("EconomyLoaded") and os.clock() - t0 < 60 do
		task.wait(0.5)
	end
	if not player.Parent then
		return
	end
	local data, ok = nil, store == nil
	if store then
		for attempt = 1, 3 do
			ok, data = pcall(function()
				return store:GetAsync("p_" .. player.UserId)
			end)
			if ok then
				break
			end
			task.wait(attempt)
		end
	end
	local s = blank()
	if type(data) == "table" then
		s.safe = type(data.safe) == "table" and data.safe or s.safe
		s.box = type(data.box) == "table" and data.box or s.box
		s.stashes = type(data.stashes) == "table" and data.stashes or s.stashes
		s.frozen = type(data.frozen) == "table" and data.frozen or nil
		if data.houseDirty then
			player:SetAttribute("HouseDirty", true)
		end
	end
	state[player] = s
	loaded[player] = ok == true
	showFrozen(player)
	uiEvent:FireClient(player, "stashes", s.stashes)
	print(("[AssetFreeze] %s: safe %d, box %s %d, %d stash(es)%s"):format(player.Name, s.safe.amt,
		if s.box.open then "open" else "none", s.box.amt, #s.stashes, if s.frozen then ", FROZEN" else ""))

	-- arrests
	player:GetAttributeChangedSignal("LastArrestAt"):Connect(function()
		local charges = tostring(player:GetAttribute("LastArrestCharges") or "")
		local dc, db = economy("Dirty", player)
		local dirty = (tonumber(dc) or 0) + (tonumber(db) or 0)
		if isMoneyCase(charges) and (dirty > 0 or charges:lower():find("robbery", 1, true)) then
			freeze(player, charges)
		else
			print(("[AssetFreeze] %s arrested (%s) - not a money case%s, no freeze"):format(player.Name, charges, if dirty > 0 then "" else " / no dirty money"))
		end
	end)
	-- the house safe follows the home
	player:GetAttributeChangedSignal("HouseId"):Connect(function()
		placeSafe(player)
	end)
	placeSafe(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	task.spawn(onPlayerAdded, p)
end
Players.PlayerRemoving:Connect(function(player)
	save(player)
	if safeParts[player] then
		safeParts[player]:Destroy()
	end
	safeParts[player] = nil
	state[player] = nil
	loaded[player] = nil
end)
game:BindToClose(function()
	for _, p in Players:GetPlayers() do
		task.spawn(save, p)
	end
	task.wait(2)
end)

-- case watch: frozen and fully out of the system for a while = case over
do
	local outSince: { [Player]: number } = {}
	task.spawn(function()
		while true do
			task.wait(5)
			for _, player in Players:GetPlayers() do
				local s = state[player]
				if s and s.frozen and not inCustody(player) and player:GetAttribute("CourtDateAt") == nil then
					outSince[player] = outSince[player] or os.clock()
					if os.clock() - outSince[player] >= CFG.CaseEndGrace then
						outSince[player] = nil
						unfreeze(player)
					end
				else
					outSince[player] = nil
				end
			end
			-- autosave
			for _, player in Players:GetPlayers() do
				if math.random() < 0.1 then
					task.spawn(save, player)
				end
			end
		end
	end)
end

print("[AssetFreeze] v255 online: dirty money, freezes, house safes, safe deposit boxes, buried stashes")
