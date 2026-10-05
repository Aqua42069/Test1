-- (v290: the National Trial Firm office uses the Luxor elevator script as-is - one bank, its DirectoryTitle on the panel)
-- Premier Counsel elevators (v287): every "ElevatorCall" panel carries Level, FloorName and
-- Arrive (Vector3, where you step out). Pressing one opens the floor directory on your screen
-- (StarterPlayerScripts.TowerElevatorClient); pick a floor - the doors close, a short ride,
-- and you step out on that floor's landing. The interior is built by tools/build_premier_interior.luau.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local model = script.Parent
local remote = ReplicatedStorage:FindFirstChild("TowerElevator") :: RemoteEvent?
if not remote then
	local r = Instance.new("RemoteEvent")
	r.Name = "TowerElevator"
	r.Parent = ReplicatedStorage
	remote = r
end
local REMOTE = remote :: RemoteEvent

-- v290 (Luxor): panels also carry Bank ("Pyramid", "NorthTower", "SouthTower"); each bank has its
-- own directory, and a floor can have several landings (the pyramid's inclinators are in its four
-- corners) - you step out at the one nearest the corner you rode from.
local floors: { [string]: { [number]: { name: string, stops: { Vector3 } } } } = {}
local panels: { BasePart } = {}
local busy: { [Player]: boolean } = {}
local lastPanel: { [Player]: { bank: string, level: number } } = {}

local function canRide(player: Player): (BasePart?, Humanoid?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return nil, nil end
	if hum:GetAttribute("PoliceCuffed") or player:GetAttribute("CustodyStage") ~= nil then return nil, nil end
	return root, hum
end

local function directory(bank: string): { any }
	local list = {}
	for level, f in floors[bank] or {} do table.insert(list, { level = level, name = f.name }) end
	table.sort(list, function(a, b) return a.level > b.level end)
	return list
end

local function hook(panel: BasePart)
	local level = panel:GetAttribute("Level")
	local arrive = panel:GetAttribute("Arrive")
	if type(level) ~= "number" or typeof(arrive) ~= "Vector3" then return end
	local bank = tostring(panel:GetAttribute("Bank") or "Pyramid")
	floors[bank] = floors[bank] or {}
	local f = floors[bank][level] or { name = tostring(panel:GetAttribute("FloorName") or ("Floor " .. level)), stops = {} }
	floors[bank][level] = f
	table.insert(f.stops, arrive)
	table.insert(panels, panel)
	local prompt = panel:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then return end
	prompt.Triggered:Connect(function(player)
		if busy[player] or not canRide(player) then return end
		lastPanel[player] = { bank = bank, level = level }
		REMOTE:FireClient(player, "open", { current = level, floors = directory(bank), title = tostring(model:GetAttribute("DirectoryTitle") or "PREMIER COUNSEL") .. (if bank ~= "Pyramid" then " " .. (if bank == "NorthTower" then "NORTH TOWER" else "SOUTH TOWER") else "") })
	end)
end

REMOTE.OnServerEvent:Connect(function(player, action, level)
	if action ~= "go" or type(level) ~= "number" or busy[player] then return end
	local from = lastPanel[player]
	if not from or from.level == level then return end
	local f = floors[from.bank] and floors[from.bank][level]
	local root = canRide(player)
	if not f or not root then return end
	-- they have to be standing at a landing
	local near = false
	for _, p in panels do
		if p.Parent and (p.Position - root.Position).Magnitude < 14 then near = true break end
	end
	if not near then return end
	-- the landing on that floor nearest (across the ground) to where they got in
	local here = Vector3.new(root.Position.X, 0, root.Position.Z)
	local arrive, best = f.stops[1], math.huge
	for _, s in f.stops do
		local d = (Vector3.new(s.X, 0, s.Z) - here).Magnitude
		if d < best then arrive, best = s, d end
	end
	busy[player] = true
	REMOTE:FireClient(player, "riding", { level = level, name = f.name })
	-- a ride that feels like a ride: longer for more floors, never long
	task.wait(math.clamp(1.2 + 0.12 * math.abs(level - from.level), 1.4, 3.2))
	local r = canRide(player)
	if r then
		r.AssemblyLinearVelocity = Vector3.zero
		r.CFrame = CFrame.new(arrive)
	end
	REMOTE:FireClient(player, "arrived", { level = level, name = f.name })
	lastPanel[player] = { bank = from.bank, level = level }
	task.wait(1)
	busy[player] = nil
end)

game:GetService("Players").PlayerRemoving:Connect(function(p)
	busy[p] = nil
	lastPanel[p] = nil
end)

for _, d in model:GetDescendants() do
	if d.Name == "ElevatorCall" and d:IsA("BasePart") then hook(d) end
end
model.DescendantAdded:Connect(function(d)
	if d.Name == "ElevatorCall" and d:IsA("BasePart") then task.defer(hook, d) end
end)
print(("[Elevators] Premier Counsel: %d panels"):format(#panels))

-- v288b: privacy glass. After dark the lit floors showed straight through the curtain wall:
-- from dusk to dawn the glass goes to a dark mirror tint, by day it's clear again.
do
	local Lighting = game:GetService("Lighting")
	local panes: { BasePart } = {}
	for _, n in { "CurtainE", "CurtainN", "CurtainS", "CurtainW" } do
		local p = model:FindFirstChild("Tower") and model.Tower:FindFirstChild(n)
		if p and p:IsA("BasePart") then table.insert(panes, p) end
	end
	local DAY = { Transparency = 0.35, Reflectance = 0.05, Color = Color3.fromRGB(70, 110, 140) }
	local NIGHT = { Transparency = 0.02, Reflectance = 0.35, Color = Color3.fromRGB(14, 22, 34) }
	local night: boolean? = nil
	task.spawn(function()
		while true do
			local t = Lighting.ClockTime
			local isNight = t >= 18.5 or t < 6.5
			if isNight ~= night then
				night = isNight
				local s = if isNight then NIGHT else DAY
				for _, p in panes do
					p.Transparency = s.Transparency
					p.Reflectance = s.Reflectance
					p.Color = s.Color
				end
			end
			task.wait(5)
		end
	end)
end
