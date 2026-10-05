--[[ CityLife.Profile (was PlayerExtras v251-v256, extended v266+)
	One saved profile per player for the CityLife systems. DataStore "LasVegas_Extras_v1".
	X.get(player) / X.peek / X.isLoaded / X.dirty / X.saveNow / X.onLoaded(fn) / X.wipe
]]
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local X = {}
X.VERSION = 266
local store = nil
do local ok, s = pcall(DataStoreService.GetDataStore, DataStoreService, "LasVegas_Extras_v1") if ok then store = s else warn("[Profile] DataStores unavailable: " .. tostring(s)) end end
local profiles, loadOk, loading, isDirty, listeners = {}, {}, {}, {}, {}
local function blank()
	return {
		version = 2,
		gangs = { rep = {}, feuds = {} },
		drugs = { tolerance = {}, debt = 0, debtTo = nil, dirtyTests = 0 },
		bail = nil, warrant = nil,
		money = { frozenBank = 0, seizedCash = 0, dirty = 0, frozenAt = nil, frozenCase = nil },
		safe = 0, box = 0, boxKnown = false, stashes = {}, missedCalls = {}, courtDates = {},
		-- v260+
		warrants = {},        -- list of { id, reason, severity (1-3), source, at }
		licence = { status = "valid", points = 0, suspendedUntil = 0, reason = nil },
		cars = {},            -- [carName] = { plate, colour, registeredAt }
		plates = {},          -- spare plates owned: list of { plate, kind = "stolen"|"cold", colour?, type? }
		citations = {},       -- list of { what, fine, at }
		flags = {},           -- officer-safety flags: armed / violent / copkiller
		connections = { pi = 0, jury = nil, judge = nil, bribes = 0, sting = 0 },
		underground = { referral = false, coldPlates = 0 },
		elite = { standing = false, since = 0, uses = 0 },
		metals = { gold = 0, silver = 0 },
		offshore = { balance = 0, pending = {} },
		appeal = { used = false, pendingAt = nil },
		news = { fame = 0 },
	}
end
local function upgrade(p)
	local b = blank()
	for k, v in b do if p[k] == nil then p[k] = v end end
	for _, sub in { "gangs", "drugs", "money", "licence", "connections", "underground", "elite", "metals", "offshore", "appeal", "news" } do
		if type(p[sub]) == "table" then for k, v in b[sub] do if p[sub][k] == nil then p[sub][k] = v end end end
	end
	return p
end
local function withRetries(what, fn)
	local lastErr
	for attempt = 1, 4 do local ok, res = pcall(fn) if ok then return true, res end lastErr = res task.wait(attempt) end
	warn("[Profile] " .. what .. " failed after retries: " .. tostring(lastErr)) return false, lastErr
end
local function load(player)
	if loading[player] or profiles[player] then return end
	loading[player] = true
	local data, ok = nil, false
	if store then ok, data = withRetries("load for " .. player.Name, function() return store:GetAsync("x_" .. player.UserId) end) if not ok then data = nil end end
	local p = upgrade(if type(data) == "table" then data else blank())
	profiles[player] = p
	loadOk[player] = store ~= nil and ok
	loading[player] = nil
	print(("[Profile] %s loaded (%s)"):format(player.Name, if not store then "no DataStore - session only" elseif not ok then "load failed - session only" elseif data then "saved profile" else "new profile"))
	for _, fn in listeners do task.spawn(fn, player, p) end
end
local function save(player)
	local p = profiles[player]
	if not (store and p and loadOk[player]) then return false end
	isDirty[player] = nil
	return withRetries("save for " .. player.Name, function() store:UpdateAsync("x_" .. player.UserId, function() return p end) end)
end
function X.peek(player) return profiles[player] end
function X.get(player)
	local t0 = os.clock()
	while not profiles[player] and player.Parent and os.clock() - t0 < 10 do if not loading[player] then task.spawn(load, player) end task.wait(0.2) end
	if not profiles[player] then profiles[player] = blank() end
	return profiles[player]
end
function X.isLoaded(player) return loadOk[player] == true end
function X.dirty(player) isDirty[player] = true end
function X.saveNow(player) task.spawn(save, player) end
function X.onLoaded(fn) table.insert(listeners, fn) for player, p in profiles do task.spawn(fn, player, p) end end
function X.wipe(player)
	local p = blank() profiles[player] = p isDirty[player] = true
	if store then loadOk[player] = true end -- (v290: a wipe always saves, even after a failed load - or the old profile comes back)
	print("[Profile] WIPE " .. player.Name)
	for _, fn in listeners do task.spawn(fn, player, p) end
	task.spawn(save, player)
end
do local fn = ServerStorage:FindFirstChild("ExtrasWipe") or Instance.new("BindableFunction") fn.Name = "ExtrasWipe" fn.OnInvoke = function(player) X.wipe(player) return true end fn.Parent = ServerStorage end
Players.PlayerAdded:Connect(function(p) task.spawn(load, p) end)
for _, p in Players:GetPlayers() do task.spawn(load, p) end
Players.PlayerRemoving:Connect(function(p) task.wait(0.5) save(p) profiles[p] = nil loadOk[p] = nil isDirty[p] = nil end)
game:BindToClose(function()
	local n = 0
	for p in profiles do n += 1 task.spawn(function() save(p) n -= 1 end) end
	local t0 = os.clock() while n > 0 and os.clock() - t0 < 20 do task.wait(0.2) end
end)
task.spawn(function() while true do task.wait(60) for p in profiles do if isDirty[p] then task.spawn(save, p) end end end end)
return X
