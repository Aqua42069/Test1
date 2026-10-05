-- HelicopterServer (v228)
-- Player-owned helicopters, sold through the phone's Helicopter app.
--   * The original helicopter models aren't in this copy of the map, so every
--     helicopter is built here out of parts (like the police helicopter).
--   * Buy once, keep it (saved). Spawn it from the app onto open ground near
--     you; one helicopter out at a time. "Store" puts it away.
--   * The pilot flies it on their own machine (HeliClient) - the server hands
--     them physics ownership while they sit in the pilot seat. With no pilot it
--     settles gently to the ground instead of dropping out of the sky.
--   * The "Aircraft Discount" pass takes 20% off.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DATASTORE_NAME = "LasVegas_Helicopters_v1"
local AIRCRAFT_DISCOUNT_PASS = 233309004

-- name, price, top speed, climb speed, scale, body colour, trim colour, seats, label
local CATALOG = {
	{ name = "Robinson R22", price = 12000, speed = 70, climb = 26, scale = 0.85,
		body = Color3.fromRGB(200, 40, 40), trim = Color3.fromRGB(240, 240, 240), seats = 2 },
	{ name = "Bell 206 JetRanger", price = 25000, speed = 88, climb = 30, scale = 1,
		body = Color3.fromRGB(30, 60, 140), trim = Color3.fromRGB(235, 235, 235), seats = 4 },
	{ name = "News Chopper", price = 32000, speed = 90, climb = 30, scale = 1,
		body = Color3.fromRGB(235, 235, 235), trim = Color3.fromRGB(0, 110, 200), seats = 4, label = "NEWS 7" },
	{ name = "Airbus H125", price = 48000, speed = 105, climb = 36, scale = 1.05,
		body = Color3.fromRGB(245, 170, 20), trim = Color3.fromRGB(30, 30, 30), seats = 4 },
	{ name = "Sikorsky S-76 Executive", price = 95000, speed = 120, climb = 40, scale = 1.25,
		body = Color3.fromRGB(20, 20, 24), trim = Color3.fromRGB(200, 170, 90), seats = 6, label = "VIP" },
}
local byName = {}
for _, h in CATALOG do
	byName[h.name] = h
end

---------------------------------------------------------------------------
-- remotes
---------------------------------------------------------------------------
local folder = ReplicatedStorage:FindFirstChild("Helicopters") or Instance.new("Folder")
folder.Name = "Helicopters"
folder.Parent = ReplicatedStorage
local shopRF = folder:FindFirstChild("Shop") or Instance.new("RemoteFunction")
shopRF.Name = "Shop"
shopRF.Parent = folder

-- v233: the pilot's client also reports its flight targets so the server can
-- apply them if physics ownership never reached the pilot (seen on phones)
local flyRE = folder:FindFirstChild("Fly") or Instance.new("RemoteEvent")
flyRE.Name = "Fly"
flyRE.Parent = folder

local heliFolder = Workspace:FindFirstChild("PlayerHelicopters") or Instance.new("Folder")
heliFolder.Name = "PlayerHelicopters"
heliFolder.Parent = Workspace

---------------------------------------------------------------------------
-- ownership (saved)
---------------------------------------------------------------------------
local store = nil
do
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, DATASTORE_NAME)
	if ok then
		store = result
	end
end
local owned: { [Player]: { [string]: boolean } } = {}
local loaded: { [Player]: boolean } = {}

local function save(player: Player)
	if not (store and loaded[player]) then
		return
	end
	local list = {}
	for name in owned[player] or {} do
		table.insert(list, name)
	end
	pcall(function()
		store:SetAsync("player_" .. player.UserId, list)
	end)
end

local function load(player: Player)
	owned[player] = {}
	if store then
		local ok, data = pcall(function()
			return store:GetAsync("player_" .. player.UserId)
		end)
		if ok and type(data) == "table" then
			for _, name in data do
				if type(name) == "string" and byName[name] then
					owned[player][name] = true
				end
			end
		end
	end
	loaded[player] = true
end

local discountCache: { [Player]: boolean } = {}
local function hasDiscount(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	if discountCache[player] == nil then
		local ok, has = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, AIRCRAFT_DISCOUNT_PASS)
		discountCache[player] = ok and has == true
	end
	return discountCache[player]
end

local function priceFor(player: Player, h): number
	return if hasDiscount(player) then math.floor(h.price * 0.8) else h.price
end

local function money(player: Player): (IntValue?, IntValue?)
	local cash = player:FindFirstChild("Cash")
	local bank = player:FindFirstChild("Money")
	return (if cash and cash:IsA("ValueBase") then cash else nil) :: any, (if bank and bank:IsA("ValueBase") then bank else nil) :: any
end

local function charge(player: Player, amount: number): boolean
	local cash, bank = money(player)
	if not cash or not bank then
		return false
	end
	if (cash :: any).Value + (bank :: any).Value < amount then
		return false
	end
	local fromCash = math.min((cash :: any).Value, amount)
	;(cash :: any).Value -= fromCash
	;(bank :: any).Value -= amount - fromCash
	return true
end

local function inCustody(player: Player): boolean
	local team = player.Team and player.Team.Name or ""
	return player:GetAttribute("CustodyOwner") ~= nil
		or player:GetAttribute("SentenceEnd") ~= nil
		or string.find(team, "Prison") ~= nil
		or string.find(team, "Intake") ~= nil
end

---------------------------------------------------------------------------
-- building a helicopter
---------------------------------------------------------------------------
local function build(h, owner: Player): (Model, BasePart, VehicleSeat)
	local s = h.scale
	local model = Instance.new("Model")
	model.Name = owner.Name .. "'s " .. h.name
	model:SetAttribute("HeliName", h.name)
	model:SetAttribute("HeliOwner", owner.UserId)

	local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, collide: boolean?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size * s
		p.CFrame = CFrame.new(cf.Position * s) * cf.Rotation
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CanCollide = collide == true
		p.Massless = true
		p.Anchored = true
		p.Parent = model
		return p
	end

	local metal = Color3.fromRGB(55, 55, 60)
	local body = part("Fuselage", Vector3.new(5.2, 4.8, 9), CFrame.new(0, 0.4, 1), h.body, nil, true)
	body.Massless = false
	model.PrimaryPart = body
	local canopy = part("Canopy", Vector3.new(5.4, 5.2, 6.4), CFrame.new(0, 0.5, -5.4), Color3.fromRGB(60, 90, 110), Enum.Material.Glass)
	canopy.Transparency = 0.45
	local cmesh = Instance.new("SpecialMesh")
	cmesh.MeshType = Enum.MeshType.Sphere
	cmesh.Parent = canopy
	part("Floor", Vector3.new(5, 0.4, 6), CFrame.new(0, -2, -4.6), h.body, nil, true)
	part("Stripe", Vector3.new(5.26, 1, 8.6), CFrame.new(0, -0.5, 1), h.trim)
	part("Boom", Vector3.new(1.1, 1.2, 11), CFrame.new(0, 1.2, 10.6), h.body)
	part("Fin", Vector3.new(0.3, 3.4, 2), CFrame.new(0, 2.6, 15.6), h.trim)
	part("Stabilizer", Vector3.new(4, 0.25, 1.2), CFrame.new(0, 1.3, 14.6), h.body)
	part("Mast", Vector3.new(0.6, 1.2, 0.6), CFrame.new(0, 3.3, -0.2), metal, Enum.Material.Metal)
	for _, x in { -1, 1 } do
		part("Skid", Vector3.new(0.4, 0.4, 11), CFrame.new(x * 2.8, -3.4, -1.4), metal, Enum.Material.Metal, true)
		part("Strut", Vector3.new(0.3, 1.5, 0.3), CFrame.new(x * 2.7, -2.6, -4), metal, Enum.Material.Metal)
		part("Strut", Vector3.new(0.3, 1.5, 0.3), CFrame.new(x * 2.7, -2.6, 1.6), metal, Enum.Material.Metal)
	end
	if h.label then
		local side = part("Label", Vector3.new(5.28, 1.4, 5), CFrame.new(0, 1.5, 1.4), h.body)
		for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
			local gui = Instance.new("SurfaceGui")
			gui.Face = face
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 40
			gui.Parent = side
			local t = Instance.new("TextLabel")
			t.BackgroundTransparency = 1
			t.Size = UDim2.fromScale(1, 1)
			t.Font = Enum.Font.GothamBlack
			t.Text = h.label
			t.TextColor3 = h.trim
			t.TextScaled = true
			t.Parent = gui
		end
	end
	local light = part("NavLight", Vector3.new(0.4, 0.3, 0.4), CFrame.new(0, -2.3, 3), Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
	local pl = Instance.new("PointLight")
	pl.Color = light.Color
	pl.Range = 10
	pl.Brightness = 1.5
	pl.Parent = light

	-- seats: the pilot flies from the front left
	local seat = Instance.new("VehicleSeat")
	seat.Name = "PilotSeat"
	seat.Size = Vector3.new(2, 0.6, 2) * s
	seat.CFrame = CFrame.new(Vector3.new(-1.2, -1.5, -5.2) * s)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.Massless = true
	seat.Anchored = true
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.HeadsUpDisplay = false
	seat:SetAttribute("HeliPilot", true)
	seat.Parent = model
	local passengerSpots = {
		Vector3.new(1.2, -1.5, -5.2), Vector3.new(-1.2, -1.5, -1.6), Vector3.new(1.2, -1.5, -1.6),
		Vector3.new(-1.2, -1.5, 1.8), Vector3.new(1.2, -1.5, 1.8),
	}
	for i = 1, math.min(h.seats - 1, #passengerSpots) do
		local p = Instance.new("Seat")
		p.Name = "PassengerSeat"
		p.Size = Vector3.new(2, 0.6, 2) * s
		p.CFrame = CFrame.new(passengerSpots[i] * s)
		p.Transparency = 1
		p.CanCollide = false
		p.Massless = true
		p.Anchored = true
		p.Parent = model
	end
	-- the rear cabin is open at the sides so passengers can get in: the body
	-- box is see-through there
	if h.seats > 2 then
		body.Size = Vector3.new(5.2, 4.8, 3) * s
		body.CFrame = CFrame.new(Vector3.new(0, 0.4, 4) * s)
		part("Roof", Vector3.new(5.2, 0.4, 7), CFrame.new(0, 2.6, 0.5), h.body, nil, true)
		part("CabinFloor", Vector3.new(5.2, 0.4, 6), CFrame.new(0, -2, 0), h.body, nil, true)
		part("Pillar", Vector3.new(5.2, 4.4, 0.4), CFrame.new(0, 0.4, -2.3), h.body)
	end

	-- rotors (spun locally by clients through the PoliceRotor tag)
	local rotor = part("MainRotor", Vector3.new(28, 0.15, 0.9), CFrame.new(0, 4, -0.2), Color3.fromRGB(30, 30, 32))
	local blade2 = part("MainRotor2", Vector3.new(0.9, 0.15, 28), CFrame.new(0, 4, -0.2), Color3.fromRGB(30, 30, 32))
	local tail = part("TailRotor", Vector3.new(0.15, 4, 0.5), CFrame.new(0.5, 2.2, 15.8), Color3.fromRGB(30, 30, 32))

	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p ~= body then
			if p == rotor or p == tail then
				local w = Instance.new("Weld")
				w.Name = "RotorWeld"
				w.Part0 = body
				w.Part1 = p
				w.C0 = body.CFrame:ToObjectSpace(p.CFrame)
				w:SetAttribute("BaseC0", w.C0)
				w:SetAttribute("Spin", if p == rotor then 22 else 38)
				w:SetAttribute("Axis", if p == rotor then "Y" else "X")
				w.Parent = p
				CollectionService:AddTag(w, "PoliceRotor")
			else
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = if p == blade2 then rotor else body
				wc.Part1 = p
				wc.Parent = p
			end
		end
	end

	-- flight: a velocity target and an orientation target, both driven by the
	-- pilot's client (or by the server's gentle auto-land with no pilot)
	local att = Instance.new("Attachment")
	att.Name = "Fly"
	att.Parent = body
	local lv = Instance.new("LinearVelocity")
	lv.Name = "HeliFly"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = 4e5 * s * s
	lv.VectorVelocity = Vector3.zero
	lv.Enabled = false
	lv.Parent = body
	local ao = Instance.new("AlignOrientation")
	ao.Name = "HeliAlign"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.MaxTorque = 2e6 * s * s
	ao.Responsiveness = 14
	ao.CFrame = CFrame.new()
	ao.Parent = body

	seat:SetAttribute("MaxSpeed", h.speed)
	seat:SetAttribute("ClimbSpeed", h.climb)
	seat:SetAttribute("YawRate", if h.scale > 1.1 then 1.0 else 1.35)
	return model, body, seat
end

---------------------------------------------------------------------------
-- spawning
---------------------------------------------------------------------------
type Active = { model: Model, body: BasePart, seat: VehicleSeat, owner: Player, pilot: Player? }
local active: { [Player]: Active } = {}

local function despawn(player: Player)
	local a = active[player]
	active[player] = nil
	if a and a.model.Parent then
		for _, d in a.model:GetDescendants() do
			if d:IsA("Seat") or d:IsA("VehicleSeat") then
				local occ = d.Occupant
				if occ then
					occ.Sit = false
				end
			end
		end
		a.model:Destroy()
	end
end

-- open ground near the player with room for the rotor and clear sky above
local function findSpot(player: Player, scale: number): (CFrame?, string?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil, "You need to be standing somewhere"
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, heliFolder }
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { char }
	local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)
	local right = look:Cross(Vector3.yAxis)
	local reach = 30 * scale
	local tries = { look * 22, look * 34, -look * 22, right * 24, -right * 24, look * 48, -look * 40 }
	for _, offset in tries do
		local probe = root.Position + offset
		local down = Workspace:Raycast(probe + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), params)
		if down and down.Normal.Y > 0.85 then
			local ground = down.Position
			local up = Workspace:Raycast(ground + Vector3.new(0, 1, 0), Vector3.new(0, 90, 0), params)
			if not up then
				local box = CFrame.new(ground + Vector3.new(0, 6 * scale + 1, 0))
				local blocking = 0
				for _, p in Workspace:GetPartBoundsInBox(box, Vector3.new(reach, 10 * scale, reach), overlap) do
					if p.CanCollide and p.Transparency < 1 and not p:IsA("Terrain") and not p:IsDescendantOf(heliFolder) then
						local m = p:FindFirstAncestorOfClass("Model")
						if not (m and m:FindFirstChildOfClass("Humanoid")) then
							blocking += 1
						end
					end
				end
				if blocking == 0 then
					local yaw = math.atan2(-look.X, -look.Z)
					return CFrame.new(ground + Vector3.new(0, 3.8 * scale, 0)) * CFrame.Angles(0, yaw, 0), nil
				end
			end
		end
	end
	return nil, "No room here - go to an open lot, field, beach or rooftop"
end

local function spawnHeli(player: Player, name: string): (boolean, string)
	local h = byName[name]
	if not h then
		return false, "Unknown helicopter"
	end
	if not (owned[player] and owned[player][name]) then
		return false, "You don't own that"
	end
	if inCustody(player) then
		return false, "Not while you're in custody"
	end
	if player:GetAttribute("VehiclesImpounded") then
		return false, "Impounded - Clark County DA"
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return false, "You're down"
	end
	if hum.SeatPart then
		return false, "Get out of your vehicle first"
	end
	local spot, why = findSpot(player, h.scale)
	if not spot then
		return false, why or "No room here"
	end
	despawn(player)
	local model, body, seat = build(h, player)
	model:PivotTo(spot)
	model.Parent = heliFolder
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
		end
	end
	local ao = body:FindFirstChild("HeliAlign") :: AlignOrientation
	local _, yaw, _ = spot:ToOrientation()
	ao.CFrame = CFrame.Angles(0, yaw, 0)
	local a: Active = { model = model, body = body, seat = seat, owner = player }
	active[player] = a

	-- v231: tap-to-board prompts (climbing into the cabin was awkward on phones)
	for _, s in model:GetDescendants() do
		if s:IsA("VehicleSeat") or s:IsA("Seat") then
			local isPilot = s == seat
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "BoardHeli"
			prompt.ActionText = if isPilot then "Fly" else "Ride"
			prompt.ObjectText = h.name
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = 14
			prompt.RequiresLineOfSight = false
			prompt.KeyboardKeyCode = if isPilot then Enum.KeyCode.F else Enum.KeyCode.G
			prompt.Parent = s
			prompt.Triggered:Connect(function(who: Player)
				local c = who.Character
				local hum = c and c:FindFirstChildOfClass("Humanoid")
				if not hum or hum.Health <= 0 or hum.SeatPart or s.Occupant then
					return
				end
				if inCustody(who) then
					return
				end
				(s :: any):Sit(hum)
			end)
			s:GetPropertyChangedSignal("Occupant"):Connect(function()
				prompt.Enabled = s.Occupant == nil
			end)
		end
	end

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occ = seat.Occupant
		local pilot = occ and Players:GetPlayerFromCharacter(occ.Parent)
		a.pilot = pilot
		local lv = body:FindFirstChild("HeliFly") :: LinearVelocity?
		if pilot then
			if inCustody(pilot) then
				occ.Sit = false
				return
			end
			if lv then
				lv.VectorVelocity = Vector3.zero
				lv.Enabled = true
			end
			pcall(body.SetNetworkOwner, body, pilot)
		else
			pcall(body.SetNetworkOwner, body, nil)
		end
	end)
	return true, h.name .. " is ready - hop in the pilot seat"
end

-- with no pilot: settle to the ground at a gentle rate, then switch off
task.spawn(function()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	while true do
		task.wait(0.2)
		for player, a in active do
			if not a.model.Parent or not a.body.Parent then
				active[player] = nil
				continue
			end
			if a.pilot and a.seat.Occupant then
				continue
			end
			local lv = a.body:FindFirstChild("HeliFly") :: LinearVelocity?
			local ao = a.body:FindFirstChild("HeliAlign") :: AlignOrientation?
			if not lv or not ao then
				continue
			end
			params.FilterDescendantsInstances = { a.model }
			local hit = Workspace:Raycast(a.body.Position, Vector3.new(0, -12, 0), params)
			local _, yaw, _ = a.body.CFrame:ToOrientation()
			ao.CFrame = CFrame.Angles(0, yaw, 0)
			if hit then
				lv.Enabled = false
			else
				lv.VectorVelocity = Vector3.new(0, -14, 0)
				lv.Enabled = true
			end
		end
	end
end)

flyRE.OnServerEvent:Connect(function(player: Player, vel: any, rot: any)
	if typeof(vel) ~= "Vector3" or typeof(rot) ~= "CFrame" then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat or not seat:IsA("VehicleSeat") or not seat:GetAttribute("HeliPilot") then
		return
	end
	local body = seat.Parent and seat.Parent:FindFirstChild("Fuselage")
	local lv = body and body:FindFirstChild("HeliFly") :: LinearVelocity?
	local ao = body and body:FindFirstChild("HeliAlign") :: AlignOrientation?
	if not lv or not ao then
		return
	end
	local top = (seat:GetAttribute("MaxSpeed") or 80) + 5
	local climb = (seat:GetAttribute("ClimbSpeed") or 30) + 5
	local flat = Vector3.new(vel.X, 0, vel.Z)
	if flat.Magnitude > top then
		flat = flat.Unit * top
	end
	lv.VectorVelocity = Vector3.new(flat.X, math.clamp(vel.Y, -climb, climb), flat.Z)
	lv.Enabled = true
	ao.CFrame = rot.Rotation
	-- keep handing the pilot the physics in case it was lost
	local ok, owner = pcall(body.GetNetworkOwner, body)
	if ok and owner ~= player then
		pcall(body.SetNetworkOwner, body, player)
	end
end)

---------------------------------------------------------------------------
-- the app
---------------------------------------------------------------------------
shopRF.OnServerInvoke = function(player: Player, action: any, name: any)
	if action == "catalog" then
		local list = {}
		for _, h in CATALOG do
			table.insert(list, {
				name = h.name,
				price = priceFor(player, h),
				speed = h.speed,
				seats = h.seats,
				owned = owned[player] ~= nil and owned[player][h.name] == true,
				out = active[player] ~= nil and active[player].model:GetAttribute("HeliName") == h.name,
			})
		end
		return list
	elseif action == "buy" and type(name) == "string" then
		local h = byName[name]
		if not h then
			return false, "Unknown helicopter"
		end
		if not loaded[player] then
			return false, "Still loading your hangar"
		end
		if inCustody(player) then
			return false, "We don't sell to inmates"
		end
		if owned[player][name] then
			return false, "You already own this"
		end
		local price = priceFor(player, h)
		if not charge(player, price) then
			return false, "Not enough money ($" .. price .. ")"
		end
		owned[player][name] = true
		task.spawn(save, player)
		return true, "Bought! Tap SPAWN to fly it"
	elseif action == "spawn" and type(name) == "string" then
		return spawnHeli(player, name)
	elseif action == "store" then
		if not active[player] then
			return false, "No helicopter out"
		end
		despawn(player)
		return true, "Helicopter stored"
	end
	return false, "?"
end

Players.PlayerAdded:Connect(load)
for _, p in Players:GetPlayers() do
	task.spawn(load, p)
end
Players.PlayerRemoving:Connect(function(player)
	save(player)
	despawn(player)
	owned[player] = nil
	loaded[player] = nil
	discountCache[player] = nil
end)
game:BindToClose(function()
	for _, p in Players:GetPlayers() do
		save(p)
	end
end)

-- v255: an asset freeze impounds the player's helicopter
local function watchImpound(player: Player)
	player:GetAttributeChangedSignal("VehiclesImpounded"):Connect(function()
		if player:GetAttribute("VehiclesImpounded") then
			despawn(player)
		end
	end)
end
Players.PlayerAdded:Connect(watchImpound)
for _, p in Players:GetPlayers() do
	watchImpound(p)
end

print("[HelicopterServer] ready: " .. #CATALOG .. " helicopters for sale")
