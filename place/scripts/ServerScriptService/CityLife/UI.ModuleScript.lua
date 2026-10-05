--[[
	CityUI  (ModuleScript)   v251-v256

	Server side of the shared choice menu + notices (client: StarterPlayerScripts/CityUIClient).
	One RemoteEvent ReplicatedStorage.CityUI:
	  server -> client  ("notice", text, seconds, color?)
	                    ("ask", id, { title, body, options = { string }, timeout, input = { placeholder, numeric } })
	                    ("close", id)
	                    ("tag", name, text?)          small persistent HUD line (e.g. "BAIL - court in 4:10"); nil text removes it
	                    ("waypoint", name, pos?, label?)   a world marker with the distance; nil pos removes it
	  client -> server  ("answer", id, index?, text?)
	UI.ask yields -> (index or nil on timeout / close, typed text)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = {}

local remote = ReplicatedStorage:FindFirstChild("CityUI") :: RemoteEvent?
if not remote then
	local r = Instance.new("RemoteEvent")
	r.Name = "CityUI"
	r.Parent = ReplicatedStorage
	remote = r
end
local R = remote :: RemoteEvent

local nextId = 0
local waiting: { [number]: { player: Player, done: boolean, index: number?, text: string? } } = {}
local openFor: { [Player]: { [number]: boolean } } = {}

R.OnServerEvent:Connect(function(player, kind, id, index, text)
	if kind ~= "answer" or type(id) ~= "number" then return end
	local w = waiting[id]
	if not w or w.player ~= player or w.done then return end
	w.done = true
	w.index = if type(index) == "number" then math.floor(index) else nil
	w.text = if type(text) == "string" then string.sub(text, 1, 60) else nil
end)

function UI.notice(player: Player, text: string, seconds: number?, color: Color3?)
	if player.Parent then R:FireClient(player, "notice", text, seconds or 4, color) end
end

function UI.noticeAll(text: string, seconds: number?, color: Color3?)
	R:FireAllClients("notice", text, seconds or 5, color)
end

function UI.tag(player: Player, name: string, text: string?)
	if player.Parent then R:FireClient(player, "tag", name, text) end
end

-- a marker in the world for this player only (nil pos removes it)
function UI.waypoint(player: Player, name: string, pos: Vector3?, label: string?)
	if player.Parent then R:FireClient(player, "waypoint", name, pos, label) end
end

-- blocks until answered / timeout / player left -> index?, text?
function UI.ask(player: Player, spec: any): (number?, string?)
	if not player.Parent then return nil, nil end
	nextId += 1
	local id = nextId
	local w = { player = player, done = false, index = nil, text = nil }
	waiting[id] = w
	openFor[player] = openFor[player] or {}
	openFor[player][id] = true
	R:FireClient(player, "ask", id, spec)
	local deadline = os.clock() + (tonumber(spec.timeout) or 30)
	while not w.done and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	waiting[id] = nil
	if openFor[player] then openFor[player][id] = nil end
	if not w.done and player.Parent then R:FireClient(player, "close", id) end
	local idx = w.index
	if idx and (idx < 1 or idx > #(spec.options or {})) then idx = nil end
	return idx, w.text
end

-- close every open menu for a player (e.g. arrested mid-menu)
function UI.closeAll(player: Player)
	local open = openFor[player]
	if not open then return end
	for id in open do
		local w = waiting[id]
		if w then w.done = true end
		if player.Parent then R:FireClient(player, "close", id) end
	end
	openFor[player] = nil
end

Players.PlayerRemoving:Connect(function(p) openFor[p] = nil end)

function UI.money(n: number): string
	n = math.floor(n)
	local s = tostring(math.abs(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then out = out:sub(2) end
	return (if n < 0 then "-$" else "$") .. out
end

return UI
