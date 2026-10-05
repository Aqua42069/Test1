-- MenuServer
-- Minimal server side for the start menu. The client snapshot shipped with no
-- server code, so this rebuilds just what the menu talks to:
--   * creates the Teams from ReplicatedStorage.TeamInfo
--   * gives every player a starting team
--   * Functions.GetUpdates      -> text for the "Recent updates" box
--   * Functions.TeamChangeRequest
--   * Events.PromptPurchase      (other GUIs still fire this)
--   * Events.TopBarColor         (fired after a team change)

local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local UPDATES_TEXT = [[
Welcome to Las Vegas!

- Start menu rebuilt
- Edit this text in ServerScriptService.MenuServer]]

local MAIN_GROUP = 758071
-- v288m: in custody or serving: no team changes (the group check on join ran AFTER a restored
-- sentence and put an inmate on Americans - "free" - and the escape check fired)
local function inCustody(p: Player): boolean
	return p:GetAttribute("SentenceEnd") ~= nil or p:GetAttribute("CustodyStage") ~= nil or p:GetAttribute("BookingState") ~= nil
end
local VISITORS = "Bright yellow"
local AMERICANS = "Bright green"

local functions = ReplicatedStorage:WaitForChild("Functions")
local events = ReplicatedStorage:WaitForChild("Events")

local function readJson(name)
	local value = ReplicatedStorage:FindFirstChild(name)
	if not value or value.Value == "" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, value.Value)
	return ok and decoded or {}
end

local teamInfo = readJson("TeamInfo")
local admins = readJson("AdminInfo")

-- v212: Chief of Police - only aquagaming22 can join (from the Teams menu).
-- Carries the command console (PoliceSystem "ChiefConsole").
local CHIEF = "Chief of Police"
local hasChief = false
for _, info in ipairs(teamInfo) do
	if info[1] == CHIEF then
		hasChief = true
	end
end
if not hasChief then
	table.insert(teamInfo, {
		CHIEF, "Really red", { "aquagaming22" }, 255,
		{ "Radio", "Body Armour", "Arrest", "Info Tool", "DoorOpener", "Tazer", "TAR-21", "M4A1", "M9", "Spike Strip" },
		{ "Police Car", "Police SUV" },
	})
	local value = ReplicatedStorage:FindFirstChild("TeamInfo")
	if value then
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, teamInfo)
		if ok then
			value.Value = encoded
		end
	end
end

-- Build the Team objects
local teamsByColor = {}
for _, info in ipairs(teamInfo) do
	local team = Teams:FindFirstChild(info[1]) or Instance.new("Team")
	team.Name = info[1]
	team.TeamColor = BrickColor.new(info[2])
	team.AutoAssignable = false
	team.Parent = Teams
	teamsByColor[info[2]] = { info = info, team = team }
end

local function safeCall(fn, ...)
	local ok, result = pcall(fn, ...)
	return ok and result or nil
end

local function isDev(player)
	return RunService:IsStudio() or player.UserId == game.CreatorId
end

local function isAdmin(player)
	local lower = player.Name:lower()
	for _, name in ipairs(admins) do
		if name == lower then
			return true
		end
	end
	return false
end

local function canJoin(player, info)
	local color, requirement = info[2], info[3]
	if color == "Deep orange" then
		return false
	end
	if isDev(player) then
		return true
	end
	if color == VISITORS then
		return false
	end
	if isAdmin(player) then
		return true
	end
	if type(requirement) == "number" then
		return requirement > 0 and safeCall(player.IsInGroup, player, requirement) == true
	elseif type(requirement) == "string" then
		return safeCall(player.GetRoleInGroup, player, MAIN_GROUP) == info[1]
	elseif type(requirement) == "table" then
		local lower = player.Name:lower()
		for _, name in ipairs(requirement) do
			if name == lower then
				return true
			end
		end
	end
	return false
end

local function findSpawn(teamColor)
	local matches = {}
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("SpawnLocation") and not obj.Neutral and obj.TeamColor == teamColor then
			table.insert(matches, obj)
		end
	end
	return #matches > 0 and matches[math.random(1, #matches)] or nil
end

local function setTeam(player, color, moveCharacter)
	local entry = teamsByColor[color]
	if not entry then
		return false
	end
	player.Neutral = false
	player.Team = entry.team
	local topBar = events:FindFirstChild("TopBarColor")
	if topBar then
		topBar:FireClient(player)
	end
	if moveCharacter and player.Character then
		-- the Chief works out of the LVPD station
		local spawnPart = findSpawn(entry.team.TeamColor) or (entry.info[1] == CHIEF and findSpawn(BrickColor.new("Sand blue")) or nil)
		if spawnPart then
			player.Character:PivotTo(spawnPart.CFrame + Vector3.new(0, 4, 0))
		end
	end
	return true
end

Players.PlayerAdded:Connect(function(player)
	setTeam(player, VISITORS, false)
	task.spawn(function()
		if safeCall(player.IsInGroup, player, MAIN_GROUP) and not inCustody(player) then
			setTeam(player, AMERICANS, false)
		end
	end)
end)
for _, player in ipairs(Players:GetPlayers()) do
	if player.Neutral then
		setTeam(player, VISITORS, false)
	end
end

local getUpdates = functions:FindFirstChild("GetUpdates")
if getUpdates then
	getUpdates.OnServerInvoke = function()
		return UPDATES_TEXT
	end
end

local teamChange = functions:FindFirstChild("TeamChangeRequest")
if teamChange then
	local lastChange = {}
	teamChange.OnServerInvoke = function(player, color)
		if type(color) ~= "string" then
			return false
		end
		local now = os.clock()
		if lastChange[player] and now - lastChange[player] < 1 then
			return false
		end
		lastChange[player] = now
		if inCustody(player) then return false end -- v288m: inmates and prisoners keep their custody team
		local entry = teamsByColor[color]
		if not entry or not canJoin(player, entry.info) then
			return false
		end
		local dev=isDev(player)
		if player.TeamColor.Name=="Deep orange" then
			if not dev then
				return false -- live prisoners must be released normally
			end
			-- Studio Team Test: perform a real justice release first so sentenceEnd,
			-- custody, facility, cuffs and held weapons are not left behind.
			local hook=ServerStorage:FindFirstChild("JusticeReleasePlayer")
			if hook and hook:IsA("BindableFunction") then
				local ok,result=pcall(function() return hook:Invoke(player,"Team Test") end)
				if not ok then warn("[MenuServer] Team Test release hook failed:",result) end
			else
				-- Fallback for startup races; attributes are cleared and the team
				-- change can proceed. The justice hook should normally exist.
				player:SetAttribute("SentenceEnd",nil)
				player:SetAttribute("Facility",nil)
				player:SetAttribute("Charges",nil)
			end
		end
		if not dev and ((player:GetAttribute("WantedStars") or 0)>0 or player:GetAttribute("SentenceEnd")) then
			return false -- no live team switching to shake off police/sentence
		end
		local changed=setTeam(player,color,true)
		if changed and dev then
			print(("[MenuServer] TEAM TEST: %s -> %s"):format(player.Name,entry.team.Name))
		end
		return changed
	end
	Players.PlayerRemoving:Connect(function(player)
		lastChange[player] = nil
	end)
end

local promptPurchase = events:FindFirstChild("PromptPurchase")
if promptPurchase then
	promptPurchase.OnServerEvent:Connect(function(player, isProduct, id)
		if type(id) ~= "number" then
			return
		end
		pcall(function()
			if isProduct then
				MarketplaceService:PromptProductPurchase(player, id)
			else
				MarketplaceService:PromptGamePassPurchase(player, id)
			end
		end)
	end)
end


---------------------------------------------------------------------------
-- Spawn protection. The map's spawns give a 100000-second ForceField (menu protection from the
-- original game). The start menu used to delete it only on the player's own screen, so on the
-- server every player stayed immune to ALL gunfire. The menu now tells us when Play is pressed.
---------------------------------------------------------------------------
local SPAWN_PROTECTION = 5
local startPlaying = events:FindFirstChild("StartPlaying") or Instance.new("RemoteEvent")
startPlaying.Name = "StartPlaying"
startPlaying.Parent = events

local function dropForceField(character)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("ForceField") then
			child:Destroy()
		end
	end
end

startPlaying.OnServerEvent:Connect(function(player)
	player:SetAttribute("InGame", true)
	if player.Character then
		dropForceField(player.Character)
	end
end)

local function watchSpawns(player)
	player.CharacterAdded:Connect(function(character)
		if player:GetAttribute("InGame") then
			task.delay(SPAWN_PROTECTION, function()
				if character.Parent then
					dropForceField(character)
				end
			end)
		end
	end)
end
Players.PlayerAdded:Connect(watchSpawns)
for _, player in ipairs(Players:GetPlayers()) do
	watchSpawns(player)
end
