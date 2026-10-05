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

local floors: { [number]: { name: string, arrive: Vector3 } } = {}
local panels: { BasePart } = {}
local busy: { [Player]: boolean } = {}
local lastPanel: { [Player]: number } = {}

local function canRide(player: Player): (BasePart?, Humanoid?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return nil, nil end
	if hum:GetAttribute("PoliceCuffed") or player:GetAttribute("CustodyStage") ~= nil then return nil, nil end
	return root, hum
end

local function directory(): { any }
	local list = {}
	for level, f in floors do table.insert(list, { level = level, name = f.name }) end
	table.sort(list, function(a, b) return a.level > b.level end)
	return list
end

local function hook(panel: BasePart)
	local level = panel:GetAttribute("Level")
	local arrive = panel:GetAttribute("Arrive")
	if type(level) ~= "number" or typeof(arrive) ~= "Vector3" then return end
	floors[level] = floors[level] or { name = tostring(panel:GetAttribute("FloorName") or ("Floor " .. level)), arrive = arrive }
	table.insert(panels, panel)
	local prompt = panel:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then return end
	prompt.Triggered:Connect(function(player)
		if busy[player] or not canRide(player) then return end
		lastPanel[player] = level
		REMOTE:FireClient(player, "open", { current = level, floors = directory(), title = tostring(model:GetAttribute("DirectoryTitle") or "PREMIER COUNSEL") })
	end)
end

REMOTE.OnServerEvent:Connect(function(player, action, level)
	if action ~= "go" or type(level) ~= "number" or busy[player] then return end
	local f = floors[level]
	local root = canRide(player)
	if not f or not root then return end
	-- they have to be standing at a landing
	local near = false
	for _, p in panels do
		if p.Parent and (p.Position - root.Position).Magnitude < 14 then near = true break end
	end
	if not near then return end
	local from = lastPanel[player] or level
	if from == level then return end
	busy[player] = true
	REMOTE:FireClient(player, "riding", { level = level, name = f.name })
	-- a ride that feels like a ride: longer for more floors, never long
	task.wait(math.clamp(1.2 + 0.12 * math.abs(level - from), 1.4, 3.2))
	local r = canRide(player)
	if r then
		r.AssemblyLinearVelocity = Vector3.zero
		-- step out facing away from the doors (into the floor)
		r.CFrame = CFrame.lookAt(f.arrive, f.arrive + Vector3.new(0, 0, 1))
	end
	REMOTE:FireClient(player, "arrived", { level = level, name = f.name })
	lastPanel[player] = level
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

-- v288b: privacy glass. v290: one-way - from outside it's a dark mirror tint day and night (you
-- can't see in); from inside each player's client turns it see-through (StarterPlayerScripts.
-- OneWayGlassClient), so you can see out. Day is a lighter blue-grey mirror, night darker.
do
	local Lighting = game:GetService("Lighting")
	local panes: { BasePart } = {}
	local ONE_WAY = { CurtainE = true, CurtainN = true, CurtainS = true, CurtainW = true, FrontGlass = true, SideGlassE = true, SideGlassW = true }
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and ONE_WAY[p.Name] then
			table.insert(panes, p)
			p:SetAttribute("OneWayGlass", true)
		end
	end
	local DAY = { Transparency = 0.02, Reflectance = 0.45, Color = Color3.fromRGB(40, 62, 84) }
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
