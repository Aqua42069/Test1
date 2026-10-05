--[[
	CharacterNames (v286s) - your in-game name.

	The first time you play you name your character (first + last name). The name is used
	everywhere the game talks about you: over your head, in court ("The People v. ..."), the
	case file, the news, the lawyer, traffic stops, visits.
	A prison death (executed on Death Row, shot by a tower, killed inside - the profile wipe in
	PoliceSystem fires ServerStorage.CharacterDied) ends that character: you pick a NEW name,
	and it can never be one you've used before.

	DataStore LasVegas_Names_v1, key names_<UserId> = { current = "Name"|nil, used = { "Name", ... } }
	(merged with UpdateAsync: a name, once used, is never forgotten; a failed load never saves).
	Player attribute CharacterName; NeedsCharacterName = true while the prompt is up;
	PastCharacterNames = JSON list for the prompt. Remote: ReplicatedStorage.CharacterName (RemoteFunction).
	Logs: [Names]
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local store = DataStoreService:GetDataStore("LasVegas_Names_v1")
local data: { [Player]: { current: string?, used: { string }, loaded: boolean } } = {}

local remote = ReplicatedStorage:FindFirstChild("CharacterName") or Instance.new("RemoteFunction")
remote.Name = "CharacterName"
remote.Parent = ReplicatedStorage

local died = ServerStorage:FindFirstChild("CharacterDied") or Instance.new("BindableEvent")
died.Name = "CharacterDied"
died.Parent = ServerStorage

local function key(p: Player): string
	return "names_" .. p.UserId
end

local function usedSet(d: any): { [string]: boolean }
	local s = {}
	for _, n in d.used do s[string.lower(n)] = true end
	return s
end

local function applyToCharacter(p: Player)
	local name = p:GetAttribute("CharacterName")
	local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
	if hum and type(name) == "string" then hum.DisplayName = name end
end

local function publish(p: Player)
	local d = data[p]
	if not d then return end
	p:SetAttribute("CharacterName", d.current)
	p:SetAttribute("PastCharacterNames", HttpService:JSONEncode(d.used))
	p:SetAttribute("NeedsCharacterName", if d.current then nil else true)
	if d.current then applyToCharacter(p) end
end

local function save(p: Player)
	local d = data[p]
	if not d or not d.loaded then return end
	local ok, err = pcall(function()
		store:UpdateAsync(key(p), function(old)
			old = type(old) == "table" and old or {}
			local all, seen = {}, {}
			for _, list in { old.used or {}, d.used } do
				for _, n in list do
					if type(n) == "string" and not seen[string.lower(n)] then
						seen[string.lower(n)] = true
						table.insert(all, n)
					end
				end
			end
			d.used = all
			return { current = d.current, used = all }
		end)
	end)
	if not ok then warn("[Names] save failed for " .. p.Name .. ": " .. tostring(err)) end
end

local function load(p: Player)
	local d = { current = nil, used = {}, loaded = false }
	data[p] = d
	for attempt = 1, 3 do
		local ok, res = pcall(store.GetAsync, store, key(p))
		if ok then
			if type(res) == "table" then
				d.current = if type(res.current) == "string" then res.current else nil
				d.used = if type(res.used) == "table" then res.used else {}
			end
			d.loaded = true
			break
		end
		warn(("[Names] load attempt %d failed for %s: %s"):format(attempt, p.Name, tostring(res)))
		task.wait(2 * attempt)
	end
	if not p.Parent then return end
	-- the name can't belong to someone else in this server already
	if d.current then
		for _, o in Players:GetPlayers() do
			if o ~= p and o:GetAttribute("CharacterName") and string.lower(o:GetAttribute("CharacterName")) == string.lower(d.current) then
				d.current = nil
			end
		end
	end
	print(("[Names] %s: %s (%d used before)%s"):format(p.Name, tostring(d.current or "no name yet"), #d.used, if d.loaded then "" else " - LOAD FAILED, session only"))
	publish(p)
end

local function tidy(raw: string): string
	local s = raw:gsub("%s+", " ")
	s = s:match("^%s*(.-)%s*$") or s
	-- each word starts with a capital (the rest as typed: McKenzie stays McKenzie)
	s = s:gsub("(%a)([%w'%-]*)", function(a, b) return string.upper(a) .. b end)
	return s
end

local function validate(p: Player, raw: any): (string?, string?)
	if type(raw) ~= "string" then return nil, "Type a name." end
	local name = tidy(raw)
	if #name < 3 or #name > 24 then return nil, "Between 3 and 24 letters." end
	if not name:match("^[%a][%a '%-%.]*$") then return nil, "Letters, spaces, apostrophes and hyphens only." end
	if not name:find(" ", 1, true) then return nil, "First and last name, please (e.g. Tony Marino)." end
	local d = data[p]
	if d and usedSet(d)[string.lower(name)] then return nil, "You've used that name before. Pick a new one." end
	for _, o in Players:GetPlayers() do
		local n = o:GetAttribute("CharacterName")
		if o ~= p and type(n) == "string" and string.lower(n) == string.lower(name) then return nil, "Someone in this city already goes by that name." end
	end
	-- Roblox text filter: a name everyone will see
	local okF, filtered = pcall(function()
		local r = TextService:FilterStringAsync(name, p.UserId, Enum.TextFilterContext.PublicChat)
		return r:GetNonChatStringForBroadcastAsync()
	end)
	if not okF then return nil, "Couldn't check that name right now - try again." end
	if filtered ~= name then return nil, "That name isn't allowed." end
	return name, nil
end

remote.OnServerInvoke = function(p: Player, raw: any)
	local d = data[p]
	if not d then return false, "Still loading - try again in a second." end
	if d.current then return false, "You already have a name." end
	local name, why = validate(p, raw)
	if not name then return false, why end
	d.current = name
	table.insert(d.used, name)
	publish(p)
	task.spawn(save, p)
	print(("[Names] %s is now %s"):format(p.Name, name))
	return true, name
end

-- a prison death: that character is gone
died.Event:Connect(function(p: Player)
	local d = data[p]
	if not d or not p.Parent then return end
	print(("[Names] %s's character %s died in prison - new name needed"):format(p.Name, tostring(d.current)))
	d.current = nil
	publish(p)
	task.spawn(save, p)
end)

Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function()
		task.defer(applyToCharacter, p)
	end)
	task.spawn(load, p)
end)
for _, p in Players:GetPlayers() do
	p.CharacterAdded:Connect(function() task.defer(applyToCharacter, p) end)
	task.spawn(load, p)
end
Players.PlayerRemoving:Connect(function(p)
	save(p)
	data[p] = nil
end)
game:BindToClose(function()
	for _, p in Players:GetPlayers() do task.spawn(save, p) end
	task.wait(2)
end)
print("[Names] v286s ready")
