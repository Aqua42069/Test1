--[[
	Records  (child ModuleScript of PoliceSystem)   v242

	Permanent criminal + court record per player, saved across sessions in the
	DataStore "LasVegas_Records_v1" (key "rec_<UserId>"). Every arrest is kept,
	whatever the outcome: cited, held at HQ, sent to prison, escaped ...

	A failed load never overwrites the save (same rule as EconomyServer): the
	record is then kept in memory for the session only. In Studio without API
	access everything still works, it just isn't saved.

	API
	  R.get(player)                 -> record table (always a table)
	  R.addArrest(player, entry)    -> index; entry = { charges, stars, route, complied, turnedIn, where }
	  R.setOutcome(player, i, outcome, extra?)   outcome = "Cited", "HeldHQ", "Prison", "Escaped", ...
	  R.priorArrests(player)        arrests before the current one
	  R.note(player, field)         bumps a counter: "escapes", "failuresToAppear", "turnedIn"
	  R.summary(player)             "3 prior arrests, 1 escape"
	  R.wipe(player)                a clean record (a new character after an execution / prison death)
	Mirrors PriorArrests / RecordEscapes on the player for UIs.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local R = {}
R.VERSION = 242

local STORE_NAME = "LasVegas_Records_v1"
local MAX_ENTRIES = 60 -- oldest entries are folded into the counters

local store: DataStore? = nil
do
	local ok, s = pcall(DataStoreService.GetDataStore, DataStoreService, STORE_NAME)
	if ok then store = s end
end

local records: { [Player]: any } = {}
local loadOk: { [Player]: boolean } = {}
local dirty: { [Player]: boolean } = {}

local function blank(): any
	return { version = 1, arrests = {}, totalArrests = 0, escapes = 0, failuresToAppear = 0, turnedIn = 0 }
end

local function mirror(player: Player)
	local rec = records[player]
	if not rec or not player.Parent then return end
	player:SetAttribute("PriorArrests", rec.totalArrests)
	player:SetAttribute("RecordEscapes", rec.escapes)
end

local function load(player: Player)
	local rec, ok = nil, false
	if store then
		for attempt = 1, 3 do
			local success, data = pcall(function()
				return (store :: DataStore):GetAsync("rec_" .. player.UserId)
			end)
			if success then
				rec = data
				ok = true
				break
			end
			task.wait(attempt)
		end
	end
	if type(rec) ~= "table" then rec = blank() end
	rec.arrests = rec.arrests or {}
	rec.totalArrests = rec.totalArrests or #rec.arrests
	rec.escapes = rec.escapes or 0
	rec.failuresToAppear = rec.failuresToAppear or 0
	rec.turnedIn = rec.turnedIn or 0
	records[player] = rec
	loadOk[player] = ok
	mirror(player)
	print(("[Records] %s loaded: %d arrest(s)%s"):format(player.Name, rec.totalArrests, if ok then "" else " (not saved this session - load failed)"))
end

local function save(player: Player)
	local rec = records[player]
	if not rec or not store or not loadOk[player] or not dirty[player] then return end
	dirty[player] = nil
	local ok, err = pcall(function()
		(store :: DataStore):UpdateAsync("rec_" .. player.UserId, function()
			return rec
		end)
	end)
	if not ok then
		dirty[player] = true
		warn("[Records] save failed for " .. player.Name .. ": " .. tostring(err))
	end
end

function R.get(player: Player): any
	local rec = records[player]
	if not rec then
		rec = blank()
		records[player] = rec
	end
	return rec
end

function R.addArrest(player: Player, entry: any): number
	local rec = R.get(player)
	entry.t = os.time()
	entry.outcome = entry.outcome or "Pending"
	table.insert(rec.arrests, entry)
	rec.totalArrests += 1
	while #rec.arrests > MAX_ENTRIES do
		table.remove(rec.arrests, 1)
	end
	dirty[player] = true
	mirror(player)
	task.spawn(save, player)
	print(("[Records] %s arrest #%d: %s (%s)"):format(player.Name, rec.totalArrests, tostring(entry.charges), tostring(entry.route)))
	return #rec.arrests
end

function R.setOutcome(player: Player, index: number?, outcome: string, extra: any?)
	local rec = R.get(player)
	local entry = rec.arrests[index or #rec.arrests]
	if not entry then return end
	entry.outcome = outcome
	if type(extra) == "table" then
		for k, v in extra do entry[k] = v end
	end
	if outcome == "Escaped" then rec.escapes += 1 end
	dirty[player] = true
	mirror(player)
	task.spawn(save, player)
	print(("[Records] %s outcome: %s"):format(player.Name, outcome))
end

function R.note(player: Player, field: string)
	local rec = R.get(player)
	rec[field] = (tonumber(rec[field]) or 0) + 1
	dirty[player] = true
	mirror(player)
	task.spawn(save, player)
end

-- v254: something else changed the record table (Bail's court date): save it
function R.touch(player: Player)
	dirty[player] = true
	task.spawn(save, player)
end

-- v290: a character's life is over (executed, killed in prison): the next one is a stranger to
-- the courts - no arrests, no prison file, no judge who remembers them
function R.wipe(player: Player)
	records[player] = blank()
	dirty[player] = true
	-- a wipe always saves, even when this session's load failed (that rule protects a record from
	-- being overwritten by a blank one - here the blank one is the point; otherwise the old record
	-- and the judge who remembers it would come back on the next join)
	loadOk[player] = true
	mirror(player)
	task.spawn(save, player)
	print("[Records] WIPE " .. player.Name .. " - a new character, a clean record")
end

-- arrests before the one being processed now
function R.priorArrests(player: Player): number
	return math.max(0, R.get(player).totalArrests - 1)
end

function R.summary(player: Player): string
	local rec = R.get(player)
	local parts = { ("%d arrest(s)"):format(rec.totalArrests) }
	if rec.escapes > 0 then table.insert(parts, ("%d escape(s)"):format(rec.escapes)) end
	if rec.failuresToAppear > 0 then table.insert(parts, ("%d failure(s) to appear"):format(rec.failuresToAppear)) end
	return table.concat(parts, ", ")
end

Players.PlayerAdded:Connect(function(p) task.spawn(load, p) end)
for _, p in Players:GetPlayers() do task.spawn(load, p) end
Players.PlayerRemoving:Connect(function(p)
	save(p)
	records[p] = nil
	loadOk[p] = nil
	dirty[p] = nil
end)
game:BindToClose(function()
	for _, p in Players:GetPlayers() do save(p) end
end)
task.spawn(function()
	while true do
		task.wait(60)
		for _, p in Players:GetPlayers() do pcall(save, p) end
	end
end)

return R
