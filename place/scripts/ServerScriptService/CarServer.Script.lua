-- CarServer
-- Rebuilt car ownership, spawning, seating, driving and doors.
-- (The snapshot had no server code; the car templates in the map are anchored
-- and every seat is Disabled, because the original game seated you from a script.)
--
--   * Keys live in player.CarStorage as BoolValues named after the car
--     (Value = true means single use). Each key also shows up as a tool.
--   * Keys tool: click -> the car spawns on the nearest free blue spawn pad.
--     Stepping on a pad also opens the spawn menu.
--   * Walk into a seat and Roblox seats you automatically. Jump to get out.
--   * Doors are not exposed through an on-screen/manual door-control UI.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")

-- v200: seated characters (R6 and R15) are welded to the car. R15 legs hang
-- below the floor and used to scrape/push the road, and the avatar's mass
-- sat high on the chassis: cars bucked, clipped into the ground and flipped.
-- Seated bodies join a group that ignores the world and are massless.
local PASSENGER_GROUP = "CarPassengers"
pcall(function() PhysicsService:RegisterCollisionGroup(PASSENGER_GROUP) end)
pcall(function() PhysicsService:CollisionGroupSetCollidable(PASSENGER_GROUP, "Default", false) end)
pcall(function() PhysicsService:CollisionGroupSetCollidable(PASSENGER_GROUP, PASSENGER_GROUP, false) end)

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
-- Cars that can be spawned: where the model sits in Workspace, and top speed
-- (studs/second). The Van, SUV and Sedan are the display cars at the dealership.
local CARS = {
	["Sports Car"] = { path = { "Sports Car" }, topSpeed = 95 },
	["Muscle Car"] = { path = { "Muscle Car" }, topSpeed = 85 },
	["Van"] = { path = { "Car Dealership", "Van" }, topSpeed = 65 },
	["SUV"] = { path = { "Car Dealership", "SUV" }, topSpeed = 75 },
	["Sedan"] = { path = { "Car Dealership", "CarStand", "Car" }, topSpeed = 75 },
}

-- v164: supplemental legacy catalog. These NEVER replace or alter the five proven
-- base templates above. A legacy model is exposed only when an exact-name source
-- passes compatibility checks for this rebuilt chassis system.
local EXTRA_CARS = {
	["Pickup"] = 72, ["Lawn Mower"] = 35, ["Quad"] = 60, ["Golf Caddy"] = 45,
	["Ice-Cream Van"] = 58, ["Lowrider"] = 72, ["Limo"] = 68,
	["RV - Class A"] = 58, ["RV - Class B"] = 62, ["Luxury Coupe"] = 92,
	["Luxury Sedan"] = 86, ["Routemaster Bus"] = 55, ["MG"] = 88,
	["Box Truck"] = 60, ["Flatbed"] = 62, ["Flatbed Transport"] = 58,
}

-- Free keys on join (cars are normally bought on the phone or from the YBCN dealer).
local STARTER_KEYS = { "Sports Car" }
-- true = every player gets STARTER_KEYS; false = only the place owner / Studio testing.
local STARTER_KEYS_FOR_EVERYONE = false

-- If W drives the car backwards, change this to -1.
local DRIVE_DIRECTION = 1
-- Steering: front wheels turn up to MAX_STEER_ANGLE degrees when slow and
-- MIN_STEER_ANGLE_AT_TOP_SPEED at top speed. If A/D steer the wrong way, set STEER_DIRECTION to -1.
local MAX_STEER_ANGLE = 32
local MIN_STEER_ANGLE_AT_TOP_SPEED = 10
local STEER_RATE = 5 -- how fast the wheels turn (radians/second)
local STEER_DIRECTION = 1

-- Acceleration and braking in studs/second^2, reverse speed as a share of top speed.
local ACCELERATION = 60 -- v259: was 35 (legacy hinge cars)
local BRAKING = 70
local REVERSE_SHARE = 0.4

-- The key tool uses the nearest free pad within this distance.
local MAX_PAD_DISTANCE = 400

local DOOR_OPEN_ANGLE = 70 -- degrees

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local templates = Instance.new("Folder")
templates.Name = "CarTemplates"
for name, info in pairs(CARS) do
	local source = workspace
	for _, step in ipairs(info.path) do
		source = source and source:FindFirstChild(step)
	end
	if source and source:IsA("Model") then
		local copy = source:Clone()
		copy.Name = name
		copy.Parent = templates
	else
		warn("[CarServer] car template not found in Workspace:", name)
	end
end
-- v164: add legacy vehicles as a supplemental registry AFTER the original five
-- are safely cloned. Recursive discovery is exact-name only and never changes a
-- working base entry. Requiring the same Essentials/wheel layout prevents an old
-- decorative/display model from poisoning the spawn registry.
local function compatibleLegacySource(model)
	if not (model and model:IsA("Model")) then return false end
	local seat=model:FindFirstChildWhichIsA("VehicleSeat",true)
	local essentials=model:FindFirstChild("Essentials")
	if not (seat and essentials) then return false end
	local wheels=0
	for _,n in ipairs({"LF","RF","LB","RB"}) do
		local w=essentials:FindFirstChild(n)
		if w and w:IsA("BasePart") then wheels+=1 end
	end
	return wheels>=4
end

local function findLegacySource(name)
	local best,bestScore=nil,-1
	for _,obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("Model") and obj.Name==name and compatibleLegacySource(obj) then
			local score=0
			for _,d in ipairs(obj:GetDescendants()) do if d:IsA("BasePart") then score+=1 end end
			if score>bestScore then best,bestScore=obj,score end
		end
	end
	return best
end

for name,topSpeed in pairs(EXTRA_CARS) do
	if not templates:FindFirstChild(name) then
		local source=findLegacySource(name)
		if source then
			local copy=source:Clone();copy.Name=name;copy.Parent=templates
			CARS[name]={topSpeed=topSpeed}
			print(("[CarServer] added legacy vehicle %s from %s"):format(name,source:GetFullName()))
		else
			warn("[CarServer] compatible legacy vehicle not found:",name)
		end
	end
end

templates.Parent = ServerStorage
print(("[CarServer] loaded %d car template(s), including compatible legacy vehicles"):format(#templates:GetChildren()))

-- The Sports Car and Muscle Car also exist as stray leftover copies parked
-- out in the city (separate from the dealership's display cars) - remove
-- those now that we've cloned what we need.
for _, name in ipairs({ "Sports Car", "Muscle Car" }) do
	local stray = workspace:FindFirstChild(name)
	if stray and stray:IsA("Model") then
		stray:Destroy()
	end
end

local activeCars = {} -- [player] = the car they spawned

local spawnedFolder = workspace:FindFirstChild("SpawnedCars") or Instance.new("Folder")
spawnedFolder.Name = "SpawnedCars"
spawnedFolder.Parent = workspace

local spawnPads = workspace:WaitForChild("SpawnPads")
local spawnRemote = spawnPads:WaitForChild("SpawnCar")
local guis = ReplicatedStorage:WaitForChild("Guis")
local events = ReplicatedStorage:WaitForChild("Events")

local pads = {}
for _, pad in ipairs(spawnPads:GetChildren()) do
	if pad:IsA("BasePart") and pad.Name == "SpawnPlate" then
		table.insert(pads, pad)
	end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function notify(player, text)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local old = playerGui:FindFirstChild("CarNotice")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CarNotice"
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.12, 0)
	label.Size = UDim2.new(0.4, 0, 0.05, 0)
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.BackgroundTransparency = 0.3
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Text = text
	label.Parent = gui
	gui.Parent = playerGui
	Debris:AddItem(gui, 3)
end

local function isDev(player)
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		return ok and rank == 255
	end
	return player.UserId == game.CreatorId
end

local function rootOf(player)
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart"), character and character:FindFirstChildOfClass("Humanoid")
end

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------
local function getStorage(player)
	local storage = player:FindFirstChild("CarStorage")
	if not storage then
		storage = Instance.new("Folder")
		storage.Name = "CarStorage"
		storage.Parent = player
	end
	return storage
end

local function giveKeys(player, carName, singleUse)
	if not templates:FindFirstChild(carName) then
		return false
	end
	local storage = getStorage(player)
	local key = storage:FindFirstChild(carName)
	if not key then
		key = Instance.new("BoolValue")
		key.Name = carName
		key.Parent = storage
	end
	key.Value = singleUse == true
	return true
end

-- Other scripts (NPCServer) give keys through this.
local giveKeysFn = ServerStorage:FindFirstChild("GiveCarKeys") or Instance.new("BindableFunction")
giveKeysFn.Name = "GiveCarKeys"
giveKeysFn.OnInvoke = giveKeys
giveKeysFn.Parent = ServerStorage

---------------------------------------------------------------------------
-- Building a car
---------------------------------------------------------------------------
local WHEEL_NAMES = { LF = true, RF = true, LB = true, RB = true }

local function hingeFrame(position, axis)
	local helper = math.abs(axis:Dot(Vector3.yAxis)) > 0.9 and Vector3.xAxis or Vector3.yAxis
	return CFrame.fromMatrix(position, axis, axis:Cross(helper).Unit)
end

local function placeAt(car, seat, groundPos, look)
	-- Face the car along `look`, then lift it so the wheels sit on the ground.
	local relative = seat.CFrame:ToObjectSpace(car:GetPivot())
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = flatLook.Magnitude > 0.01 and flatLook.Unit or Vector3.zAxis
	car:PivotTo(CFrame.lookAt(groundPos, groundPos + flatLook) * relative)

	local boxCF, boxSize = car:GetBoundingBox()
	local bottom = boxCF.Position.Y - boxSize.Y / 2
	car:PivotTo(car:GetPivot() + Vector3.new(0, groundPos.Y - bottom + 0.5, 0))
end

-- Returns wheel data and door data.
local function prepareDoors(car, seat)
	local essentials = car:FindFirstChild("Essentials")
	local doorsFolder = essentials and essentials:FindFirstChild("Doors")
	local seatCF = seat.CFrame
	local boxCF = car:GetBoundingBox()
	local centerLocal = seatCF:PointToObjectSpace(boxCF.Position)

	-- Doors: each door is welded to the car by one Weld at its Pivot. Opening
	-- a door just rotates that Weld's C0, so the door stays part of the car
	-- (solid, no physics joints that can jam or flop around).
	local doors = {}
	if doorsFolder then
		for _, door in ipairs(doorsFolder:GetChildren()) do
			if door:IsA("Model") then
				local pivot = door:FindFirstChild("Pivot") or door:FindFirstChildWhichIsA("BasePart", true)
				if pivot then
					for _, part in ipairs(door:GetDescendants()) do
						if part:IsA("BasePart") then
							part.CanCollide = part ~= pivot -- panels are solid
							if part ~= pivot then
								local w = Instance.new("WeldConstraint")
								w.Part0 = pivot
								w.Part1 = part
								w.Parent = pivot
							end
						end
					end

					local hinge = Instance.new("Weld")
					hinge.Name = "DoorHinge"
					hinge.Part0 = seat
					hinge.Part1 = pivot
					hinge.C0 = seatCF:ToObjectSpace(pivot.CFrame)
					hinge.C1 = CFrame.identity
					hinge.Parent = pivot

					-- Swing direction that moves the door away from the car. This
					-- is a heuristic (which rotation moves the door's centre
					-- farther from the car's midline), not a real simulation -
					-- it can pick the wrong side for an unusual door shape. The
					-- Van's doors were reported opening inward, so they're
					-- flipped here rather than trusting the heuristic blind.
					local FLIP_SWING = { Van = true }
					local closed = hinge.C0
					local hingeLocal = closed.Position
					local doorCenter = seatCF:PointToObjectSpace(door:GetBoundingBox().Position) - hingeLocal
					local bestSign, bestOut = 1, -math.huge
					for _, sign in ipairs({ 1, -1 }) do
						local rot = CFrame.Angles(0, math.rad(DOOR_OPEN_ANGLE) * sign, 0)
						local moved = hingeLocal + rot:VectorToWorldSpace(doorCenter)
						local out = math.abs(moved.X - centerLocal.X)
						if out > bestOut then
							bestSign, bestOut = sign, out
						end
					end
					if FLIP_SWING[car:GetAttribute("CarName")] then
						bestSign = -bestSign
					end
					local bestRot = CFrame.Angles(0, math.rad(DOOR_OPEN_ANGLE) * bestSign, 0)

					local state = Instance.new("BoolValue")
					state.Name = door.Name .. "Open"
					state.Value = false
					state.Parent = doorsFolder

					hinge:SetAttribute("ClosedC0", closed)
					hinge:SetAttribute("OpenC0", CFrame.new(hingeLocal) * bestRot * closed.Rotation)
					doors[door.Name] = {
						hinge = hinge,
						closed = closed,
						opened = CFrame.new(hingeLocal) * bestRot * closed.Rotation,
						state = state,
						model = door,
						pivot = pivot,
						seat = seat,
					}
				end
			end
		end
	end

	return doors, centerLocal
end

local function prepareCar(car, seat)
	local essentials = car:FindFirstChild("Essentials")
	local doorsFolder = essentials and essentials:FindFirstChild("Doors")

	local wheels, skip = {}, {}
	if essentials then
		for _, child in ipairs(essentials:GetChildren()) do
			if WHEEL_NAMES[child.Name] and child:IsA("BasePart") then
				table.insert(wheels, child)
				skip[child] = true
			end
		end
	end
	if doorsFolder then
		for _, part in ipairs(doorsFolder:GetDescendants()) do
			if part:IsA("BasePart") then
				skip[part] = true
			end
		end
	end

	-- Strip old joints / movers; they either don't work any more or fight the new setup.
	for _, obj in ipairs(car:GetDescendants()) do
		if (obj:IsA("JointInstance") or obj:IsA("BodyMover") or obj:IsA("WeldConstraint")) and obj.Name ~= "SeatWeld" then
			-- v218: never strip the weld holding a seated player (carjacked traffic cars)
			obj:Destroy()
		elseif obj:IsA("BaseScript") then
			obj.Disabled = true
		end
	end

	-- Body: weld to the driver's seat, and make sure it's actually solid -
	-- some of the source models have body panels with collision switched
	-- off, which let players walk straight through what should be a car.
	for _, part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") and part ~= seat and not skip[part] then
			part.CanCollide = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = seat
			weld.Part1 = part
			weld.Parent = seat
		end
	end

	local doors, centerLocal = prepareDoors(car, seat)
	local seatCF = seat.CFrame

	-- Wheels. Each wheel is a ball with a flattened CylinderMesh, so the part's
	-- Y axis is its axle.
	--   Rear wheels: motor hinge straight to the chassis.
	--   Front wheels: a steering knuckle on a servo hinge (turns left/right),
	--   with the wheel's motor hinge on the knuckle. All four wheels drive.
	local up = seatCF.UpVector
	local rollDirection = up:Cross(seatCF.LookVector)
	local driven, steered = {}, {}

	local function spinHinge(holder, wheel, axle, motorised)
		local frame = hingeFrame(wheel.Position, axle)
		local a0 = Instance.new("Attachment")
		a0.Name = "Axle_" .. wheel.Name
		a0.Parent = holder
		a0.WorldCFrame = frame
		local a1 = Instance.new("Attachment")
		a1.Name = "Axle"
		a1.Parent = wheel
		a1.WorldCFrame = frame
		local hinge = Instance.new("HingeConstraint")
		hinge.Name = "Spin"
		hinge.Attachment0 = a0
		hinge.Attachment1 = a1
		hinge.ActuatorType = motorised and Enum.ActuatorType.Motor or Enum.ActuatorType.None
		-- v200: finite spin-up. Instant (math.huge) wheel acceleration made cars
		-- twitch and hop when network ownership changed in live servers.
		hinge.MotorMaxAcceleration = 400
		hinge.Parent = wheel
		return hinge
	end

	for _, wheel in ipairs(wheels) do
		local axle = wheel.CFrame.UpVector
		-- Front = ahead of the car's middle in the direction the driver faces.
		local isFront = seatCF:PointToObjectSpace(wheel.Position).Z < centerLocal.Z
		wheel.CustomPhysicalProperties = PhysicalProperties.new(1.5, 1.6, 0.2, 1, 1)

		if isFront then
			local knuckle = Instance.new("Part")
			knuckle.Name = "Knuckle_" .. wheel.Name
			knuckle.Size = Vector3.new(0.6, 0.6, 0.6)
			knuckle.Transparency = 1
			knuckle.CanCollide = false
			knuckle.CanTouch = false
			knuckle.CanQuery = false
			knuckle.CustomPhysicalProperties = PhysicalProperties.new(20, 0.3, 0.5)
			knuckle.CFrame = CFrame.new(wheel.Position) * seatCF.Rotation
			knuckle.Anchored = true
			knuckle.Parent = wheel.Parent

			local frame = hingeFrame(wheel.Position, up)
			local s0 = Instance.new("Attachment")
			s0.Name = "Steer_" .. wheel.Name
			s0.Parent = seat
			s0.WorldCFrame = frame
			local s1 = Instance.new("Attachment")
			s1.Name = "Steer"
			s1.Parent = knuckle
			s1.WorldCFrame = frame
			local steer = Instance.new("HingeConstraint")
			steer.Name = "SteerHinge"
			steer.Attachment0 = s0
			steer.Attachment1 = s1
			steer.ActuatorType = Enum.ActuatorType.Servo
			steer.AngularSpeed = STEER_RATE
			steer.ServoMaxTorque = 1e7
			steer.LimitsEnabled = true
			steer.LowerAngle = -MAX_STEER_ANGLE - 5
			steer.UpperAngle = MAX_STEER_ANGLE + 5
			steer.Parent = knuckle

			local spin = spinHinge(knuckle, wheel, axle, true)
			table.insert(steered, steer)
			table.insert(driven, {
				hinge = spin,
				sign = (axle:Dot(rollDirection) >= 0 and 1 or -1) * DRIVE_DIRECTION,
				radius = math.max(math.min(wheel.Size.X, wheel.Size.Y, wheel.Size.Z) / 2, 0.5),
			})
		else
			local hinge = spinHinge(seat, wheel, axle, true)
			table.insert(driven, {
				hinge = hinge,
				sign = (axle:Dot(rollDirection) >= 0 and 1 or -1) * DRIVE_DIRECTION,
				radius = math.max(math.min(wheel.Size.X, wheel.Size.Y, wheel.Size.Z) / 2, 0.5),
			})
		end
	end

	-- Ballast: a heavy invisible block low in the middle of the car keeps it
	-- from rolling over in corners.
	local lowest = math.huge
	for _, wheel in ipairs(wheels) do
		lowest = math.min(lowest, seatCF:PointToObjectSpace(wheel.Position).Y)
	end
	if lowest < math.huge then
		local ballast = Instance.new("Part")
		ballast.Name = "Ballast"
		ballast.Size = Vector3.new(3, 0.4, 5)
		ballast.Transparency = 1
		ballast.CanCollide = false
		ballast.CanTouch = false
		ballast.CanQuery = false
		ballast.CustomPhysicalProperties = PhysicalProperties.new(40, 0.3, 0.5)
		ballast.CFrame = seatCF * CFrame.new(centerLocal.X, lowest, centerLocal.Z)
		ballast.Anchored = true
		ballast.Parent = car
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = seat
		weld.Part1 = ballast
		weld.Parent = ballast
	end

	return { driven = driven, steered = steered }, doors
end

---------------------------------------------------------------------------
-- GTA IV handling (side build, 2026-10-01) (ReplicatedStorage.GTAHandlingData + GTAVehicle).
-- A car with a handling line gets raycast suspension and GTA tyre physics: the
-- driver's machine simulates it while driving (CarDriveClient), the server holds
-- it on its suspension while parked. Cars without a line keep the old hinges.
---------------------------------------------------------------------------
local GTA = { cars = {}, data = nil, lines = nil }

function GTA.load()
	if GTA.lines then
		return
	end
	GTA.lines = {}
	local okM, Vehicle = pcall(require, ReplicatedStorage:WaitForChild("GTAVehicle", 10))
	local okD, data = pcall(require, ReplicatedStorage:WaitForChild("GTAHandlingData", 10))
	if not okM or not okD or type(data) ~= "table" then
		warn("[GTAHandling] couldn't load GTAVehicle / GTAHandlingData - cars keep the old driving")
		return
	end
	GTA.Vehicle, GTA.data = Vehicle, data
	Vehicle.configure(data)
	GTA.lines = Vehicle.parse(tostring(data.Text or ""), data.Columns)
	local n = 0
	for _, h in GTA.lines do
		n += 1
		print("[GTAHandling] " .. Vehicle.describe(h))
	end
	print(("[GTAHandling] %d handling line(s) read, %.2f studs per metre"):format(n, data.MetersToStuds or 2.8))
end

function GTA.lineFor(carName)
	GTA.load()
	local data = GTA.data
	local key = data and data.Cars and data.Cars[carName]
	return key and GTA.lines[string.upper(key)]
end

function GTA.setup(car, seat)
	local carName = car:GetAttribute("CarName")
	local h = carName and GTA.lineFor(carName)
	if not h then
		return
	end
	seat:SetAttribute("GTAHandling", h.name)
	-- wheels become visual only: the suspension rays carry the car
	for _, d in car:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "LF" or d.Name == "RF" or d.Name == "LB" or d.Name == "RB" or string.sub(d.Name, 1, 8) == "Knuckle_") then
			d.CanCollide = false
			d.Massless = true
			-- measured bug fix: hinged wheels are their own assemblies, where Massless is
			-- ignored - at full Roblox gravity they overloaded the springs ~2.5x
			d.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0.3, 0, 1, 1)
		end
	end
	local att = seat:FindFirstChild("GTAAntiGravityAttachment") or Instance.new("Attachment")
	att.Name = "GTAAntiGravityAttachment"
	att.Parent = seat
	local vf = seat:FindFirstChild("GTAAntiGravity") or Instance.new("VectorForce")
	vf.Name = "GTAAntiGravity"
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Force = Vector3.zero
	vf.Parent = seat
	-- IV weight -> Roblox weight: AssemblyMass = handling.dat mass (kg) x MassScale, so every
	-- car keeps IV's weight ratios (a 2,500 kg van shoves a 1,700 kg sedan like in IV). The
	-- ballast is stretched along the wheelbase (weight spread front to back like a real
	-- car) and its density makes up the difference to the target.
	do
		local massScale = tonumber(GTA.data.MassScale) or 0.15
		local target = math.max(50, h.mass * massScale)
		local ballast = car:FindFirstChild("Ballast")
		local essentials = car:FindFirstChild("Essentials")
		if ballast and ballast:IsA("BasePart") and essentials then
			local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
			for _, n in { "LF", "RF", "LB", "RB" } do
				local w = essentials:FindFirstChild(n)
				if w and w:IsA("BasePart") then
					local lp = seat.CFrame:PointToObjectSpace(w.Position)
					minX, maxX, minZ, maxZ = math.min(minX, lp.X), math.max(maxX, lp.X), math.min(minZ, lp.Z), math.max(maxZ, lp.Z)
				end
			end
			if minX < math.huge then
				ballast.Size = Vector3.new(math.max(maxX - minX, 1.5), 1, math.max(maxZ - minZ, 3))
			end
			local others = seat.AssemblyMass - ballast:GetMass()
			-- v290d: a body heavier than the whole target on its own (the van: 683 against 375)
			-- couldn't be brought down by the ballast - a player's car bounced off it, it never
			-- moved and never felt a hit. Its panels get lighter (their weight ratio kept).
			if others > target * 0.8 then
				local k = (target * 0.6) / others
				for _, d in car:GetDescendants() do
					if d:IsA("BasePart") and d ~= ballast and not d.Massless and d.AssemblyRootPart == seat.AssemblyRootPart then
						local pp = d.CurrentPhysicalProperties
						d.CustomPhysicalProperties = PhysicalProperties.new(math.max(pp.Density * k, 0.01), pp.Friction, pp.Elasticity, pp.FrictionWeight, pp.ElasticityWeight)
					end
				end
				others = seat.AssemblyMass - ballast:GetMass()
			end
			local density = math.clamp((target - others) / (ballast.Size.X * ballast.Size.Y * ballast.Size.Z), 0.01, 100)
			ballast.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0.5)
			print(("[GTAHandling] %s weight: IV %d kg -> %.0f (target %.0f)"):format(car.Name, h.mass, seat.AssemblyMass, target))
		end
	end
	local st = GTA.Vehicle.new(car, seat, h, GTA.data.MetersToStuds or 2.8)
	if not st then
		seat:SetAttribute("GTAHandling", nil)
		return
	end
	GTA.cars[car] = st
	car.Destroying:Connect(function()
		GTA.cars[car] = nil
	end)
	print(("[GTAHandling] %s uses %s"):format(car.Name, h.name))
end

-- F to get in / out (CarDriveClient). Driver's seat first, else the nearest free seat.
do
	local remote = ReplicatedStorage:FindFirstChild("CarEnterExit") or Instance.new("RemoteEvent")
	remote.Name = "CarEnterExit"
	remote.Parent = ReplicatedStorage
	local busy = {}
	-- the car a seat belongs to: the model directly under Workspace / SpawnedCars
	local function carOf(seat)
		local m = seat:FindFirstAncestorWhichIsA("Model")
		-- v286b: Workspace is a Model too - stop below it (stolen traffic cars live in Workspace)
		while m and m.Parent and m.Parent ~= workspace and m.Parent:IsA("Model") do
			m = m.Parent
		end
		return m
	end

	local enter -- (below)
	remote.OnServerEvent:Connect(function(player, target)
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not hum or not root or hum.Health <= 0 then
			return
		end
		-- v295d: getting OUT never waits on anything (it used to be refused while "busy")
		if target ~= nil and busy[player] then
			return
		end
		if target ~= nil then
			-- the walk to the door and the sit run protected: an error part-way used to leave the
			-- player "busy" for the rest of the session - every F, in or out, ignored after that
			busy[player] = true
			local ok, err = pcall(enter, player, target, char, hum, root)
			busy[player] = nil
			if not ok then warn(("[CarServer] F (get in) failed for %s: %s"):format(player.Name, tostring(err))) end
			return
		end
		do
			-- out: break the seat weld (Sit = false from the server doesn't always take);
			-- the seat's own Occupant code then puts them beside the door
			local seat = hum.SeatPart
			if seat then
				local weld = seat:FindFirstChild("SeatWeld")
				if weld then
					weld:Destroy()
				end
				hum.Sit = false
			end
			return
		end
	end)
	enter = function(player, target, char, hum, root)
		if typeof(target) ~= "Instance" or not (target:IsA("VehicleSeat") or target:IsA("Seat") or target:IsA("Model"))
			or not target:IsDescendantOf(workspace) or hum:GetAttribute("PoliceCuffed") or player:GetAttribute("CustodyStage") ~= nil then
			print(("[CarServer] F from %s ignored: target=%s cuffed=%s custody=%s"):format(player.Name, tostring(target), tostring(hum:GetAttribute("PoliceCuffed")), tostring(player:GetAttribute("CustodyStage"))))
			return
		end
		local car = if target:IsA("Model") then target else carOf(target)
		if not car then
			return
		end
		-- v286j: already sitting somewhere = nothing (F raced the carjack and put people in the passenger seat)
		if hum.SeatPart then
			return
		end
		-- a traffic car that hasn't been taken yet: CityTraffic's carjack (door, driver dragged out)
		if car:GetAttribute("TrafficCarType") ~= nil and not car:GetAttribute("TrafficStolen") then
			local cj = ServerStorage:FindFirstChild("TrafficCarjack")
			if cj and cj:IsA("BindableEvent") then
				cj:Fire(player, car)
				return
			end
		end
		local seats = {}
		local driver = if car.PrimaryPart and car.PrimaryPart:IsA("VehicleSeat") then car.PrimaryPart else car:FindFirstChildWhichIsA("VehicleSeat", true)
		if driver and (driver:IsA("VehicleSeat") or driver:IsA("Seat")) then
			table.insert(seats, driver)
		end
		for _, s in car:GetDescendants() do
			if (s:IsA("VehicleSeat") or s:IsA("Seat")) and s ~= driver then
				table.insert(seats, s)
			end
		end
		local target = nil
		for _, s in seats do
			if not s.Occupant and not s.Disabled then
				target = s
				break
			end
		end
		if not target or (target.Position - root.Position).Magnitude > 16 then
			return
		end
		-- walk to the door, then in
		local side = target.CFrame.RightVector * (if target.CFrame:PointToObjectSpace(root.Position).X < 0 then -1 else 1)
		local door = target.Position + side * 3.5
		hum:MoveTo(Vector3.new(door.X, root.Position.Y, door.Z))
		local t0 = os.clock()
		while os.clock() - t0 < 1.2 and (root.Position - door).Magnitude > 3 and hum.Health > 0 do
			task.wait(0.05)
		end
		if hum.Health > 0 and not target.Occupant and (target.Position - root.Position).Magnitude < 30 then
			-- v259: cancel the walk first. The door is inside the solid body, so the walk never
			-- arrived; the leftover MoveTo auto-jumped ~0.8 s after sitting and threw you out
			hum:MoveTo(root.Position)
			hum.Jump = false
			allowCarEntry(player)
			target:Sit(hum)
		end
	end
	Players.PlayerRemoving:Connect(function(p) busy[p] = nil end)
end

-- parked GTA cars: the server keeps them standing on their suspension, handbrake on
RunService.PreSimulation:Connect(function(dt)
	for car, st in GTA.cars do
		if not car.Parent or not st.seat.Parent then
			GTA.cars[car] = nil
			continue
		end
		local occ = st.seat.Occupant
		local driver = occ and Players:GetPlayerFromCharacter(occ.Parent)
		if not driver then
			-- v286c: a car just knocked loose in a crash rolls free for a moment (CityTraffic)
			local coast = (tonumber(car:GetAttribute("CoastUntil")) or 0) > workspace:GetServerTimeNow()
			GTA.Vehicle.step(st, dt, { throttle = 0, steer = 0, handbrake = not coast })
		end
	end
end)

---------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------
local function hookDrive(car, seat, wheels, topSpeed)
	-- Total weight of everything in the car (wheels and doors are separate
	-- assemblies, so AssemblyMass alone would be too low).
	local mass = 0
	for _, part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") then
			mass += part:GetMass()
		end
	end

	-- Torque per wheel for the wanted acceleration: F = m*a spread over 4 wheels, T = F*r.
	local radius = wheels.driven[1] and wheels.driven[1].radius or 1.5
	local count = math.max(#wheels.driven, 1)
	local driveTorque = mass * ACCELERATION * radius / count
	local brakeTorque = mass * BRAKING * radius / count

	for _, w in ipairs(wheels.driven) do
		w.hinge:SetAttribute("Sign", w.sign)
		w.hinge:SetAttribute("Radius", w.radius)
	end
	seat:SetAttribute("TopSpeed", topSpeed)
	seat:SetAttribute("ReverseSpeed", topSpeed * REVERSE_SHARE)
	seat:SetAttribute("DriveTorque", driveTorque)
	seat:SetAttribute("BrakeTorque", brakeTorque)
	seat:SetAttribute("CoastTorque", brakeTorque * 0.08)
	seat:SetAttribute("MaxSteerAngle", MAX_STEER_ANGLE)
	seat:SetAttribute("MinSteerAngle", MIN_STEER_ANGLE_AT_TOP_SPEED)
	seat:SetAttribute("SteerDirection", STEER_DIRECTION)

	local function park()
		for _, w in ipairs(wheels.driven) do
			w.hinge.AngularVelocity = 0
			w.hinge.MotorMaxTorque = brakeTorque
		end
		for _, hinge in ipairs(wheels.steered) do
			hinge.TargetAngle = 0
		end
	end
	park()
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if not seat.Occupant then
			park()
		end
	end)
	GTA.setup(car, seat)
end

---------------------------------------------------------------------------
-- Doors
---------------------------------------------------------------------------
local carDoors = {} -- [car] = doors table from prepareCar

local DOOR_TIME = 0.35

-- Animates one door entry (the {hinge, closed, opened, state, ...} table
-- prepareDoors returns) open or closed. Exposed via ServerStorage.AnimateCarDoor
-- too, so anything holding a doors table from PrepareCarDoors (like AI-driven
-- cars, which aren't registered in this script's own carDoors lookup) can
-- open/close doors exactly the way the player does.
local function animateDoor(car, door, doorName, open)
	if open == nil then
		open = not door.state.Value
	end
	door.state.Value = open
	door.animation = (door.animation or 0) + 1
	local myAnimation = door.animation
	local from = door.hinge.C0
	local to = open and door.opened or door.closed
	print(("[CarServer] %s door %s -> %s"):format(car.Name, doorName, open and "open" or "closed"))

	task.spawn(function()
		local started = os.clock()
		while door.animation == myAnimation and door.hinge.Parent do
			local alpha = math.min((os.clock() - started) / DOOR_TIME, 1)
			alpha = 1 - (1 - alpha) ^ 2 -- ease out
			door.hinge.C0 = from:Lerp(to, alpha)
			if alpha >= 1 then
				break
			end
			RunService.Heartbeat:Wait()
		end
		-- Sanity check: is the door actually where the weld says it should be?
		task.wait(0.3)
		if door.animation == myAnimation and door.pivot.Parent then
			local expected = (door.seat.CFrame * door.hinge.C0).Position
			local off = (door.pivot.Position - expected).Magnitude
			if off > 1 then
				warn(("[CarServer] door %s is %.1f studs from where it should be (weld not holding?)"):format(doorName, off))
			end
		end
	end)
end

local function setDoor(car, doorName, open)
	local door = carDoors[car] and carDoors[car][doorName]
	if not door then
		warn("[CarServer] no door", doorName, "on", car.Name)
		return
	end
	animateDoor(car, door, doorName, open)
end

-- Lets other scripts (AI-driven cars, which don't go through prepareCar's
-- physics/wheel setup) give a car the same working doors a player's car has,
-- and open/close them the identical way.
local prepareDoorsFn = ServerStorage:FindFirstChild("PrepareCarDoors") or Instance.new("BindableFunction")
prepareDoorsFn.Name = "PrepareCarDoors"
prepareDoorsFn.OnInvoke = prepareDoors
prepareDoorsFn.Parent = ServerStorage

local animateDoorFn = ServerStorage:FindFirstChild("AnimateCarDoor") or Instance.new("BindableFunction")
animateDoorFn.Name = "AnimateCarDoor"
animateDoorFn.OnInvoke = function(car, door, doorName, open)
	animateDoor(car, door, doorName, open)
end
animateDoorFn.Parent = ServerStorage

-- v286j: SetCarDoor:Invoke(car, doorName | "driver", open) - "driver" = the door nearest the
-- driver's seat (CityTraffic's carjack swings it open, pulls the driver out, closes it)
local setDoorFn = ServerStorage:FindFirstChild("SetCarDoor") or Instance.new("BindableFunction")
setDoorFn.Name = "SetCarDoor"
setDoorFn.OnInvoke = function(car, doorName, open)
	local doors = carDoors[car]
	if not doors then return false end
	if doorName == "driver" then
		-- v286s: the door BESIDE the driver's seat - measured from the door's middle, on the
		-- driver's side. (Measuring to the hinge picked the rear door: its hinge sits right
		-- behind the driver, closer to the seat than the front door's hinge at the windscreen.)
		local seat = if car.PrimaryPart and car.PrimaryPart:IsA("VehicleSeat") then car.PrimaryPart else car:FindFirstChildWhichIsA("VehicleSeat", true)
		local best, bd = nil, math.huge
		for name, d in pairs(doors) do
			local s = seat or d.seat
			if d.pivot and d.pivot.Parent and s then
				local okB, cf = pcall(function() return (d.model :: Model):GetBoundingBox() end)
				local mid = if okB and cf then cf.Position else d.pivot.Position
				local rel = s.CFrame:PointToObjectSpace(mid)
				local score = math.abs(rel.Z) + (if rel.X < 0 then 0 else 100)
				if score < bd then best, bd = name, score end
			end
		end
		doorName = best
	end
	local door = doorName and doors[doorName]
	if not door or not door.hinge.Parent then return false end
	animateDoor(car, door, doorName, open)
	return true
end
setDoorFn.Parent = ServerStorage

local function playerInCar(player, car)
	local _, humanoid = rootOf(player)
	return humanoid and humanoid.SeatPart and humanoid.SeatPart:IsDescendantOf(car)
end

local doorRemote = events:FindFirstChild("CarDoorOpener")
if doorRemote then
	doorRemote.OnServerEvent:Connect(function(player,car,doorName)
		if typeof(car)~="Instance" or not car:IsA("Model") or not car.Parent then return end
		if typeof(doorName)~="string" then return end
		if not playerInCar(player,car) and activeCars[player]~=car then return end
		local door=carDoors[car] and carDoors[car][doorName]
		if door then animateDoor(car,door,doorName,nil) end
	end)
end

---------------------------------------------------------------------------
-- Seating (all seats in these cars are Disabled so you don't sit by bumping
-- into them; the prompts enable a seat just long enough to sit you down).
---------------------------------------------------------------------------
local doorGuiTemplate = guis:FindFirstChild("DoorGui")


local function doorGuiCar(player)
	local playerGui = player and player:FindFirstChild("PlayerGui")
	local gui = playerGui and playerGui:FindFirstChild("DoorGui")
	local value = gui and gui:FindFirstChild("Car")
	return value and value.Value, gui
end

local function giveDoorGui(player,car)
	if not (player and car and car.Parent and doorGuiTemplate) then return end
	local playerGui=player:FindFirstChild("PlayerGui")
	if not playerGui then return end
	local old=playerGui:FindFirstChild("DoorGui")
	if old then
		local ov=old:FindFirstChild("Car")
		if ov and ov.Value==car then return end
		old:Destroy()
	end
	local gui=doorGuiTemplate:Clone()
	gui.Name="DoorGui"
	local cv=gui:FindFirstChild("Car")
	if not cv then cv=Instance.new("ObjectValue");cv.Name="Car";cv.Parent=gui end
	cv.Value=car
	gui.Parent=playerGui
	print(("[CarServer] door controls -> %s for %s"):format(player.Name,car.Name))
end

-- Removes the panel for `car`. If the player still owns a car, their own
-- car's panel comes back (it's meant to stay on screen permanently).
local function removeDoorGui(player, car)
	if not player then
		return
	end
	local current, gui = doorGuiCar(player)
	if gui and (car == nil or current == car) then
		gui:Destroy()
	end
	local own = activeCars[player]
	if own and own ~= car and own.Parent then
		giveDoorGui(player, own)
	end
end

local function exitPosition(car, rootSeat, seat, character)
	local boxCF, boxSize = car:GetBoundingBox()
	local seatCF = rootSeat.CFrame
	local centerLocal = seatCF:PointToObjectSpace(boxCF.Position)
	local seatLocal = seatCF:PointToObjectSpace(seat.Position)
	local side = seatLocal.X < centerLocal.X and -1 or 1
	local exitLocal = Vector3.new(centerLocal.X + side * (boxSize.X / 2 + 3), seatLocal.Y + 2, seatLocal.Z)
	local pos = seatCF:PointToWorldSpace(exitLocal)
	-- v200: stand the character ON the ground (R15 hip height differs from R6;
	-- the old "seat + 2" put R15 legs into the road).
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { car, character }
	local hit = workspace:Raycast(pos + Vector3.new(0, 6, 0), Vector3.new(0, -30, 0), params)
	if hit and character then
		local hum = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		local lift = if hum and hum.RigType == Enum.HumanoidRigType.R15 then hum.HipHeight + (root and root.Size.Y / 2 or 1) else 3
		pos = Vector3.new(pos.X, hit.Position.Y + lift + 0.15, pos.Z)
	end
	return pos
end

-- Seated-body physics: store originals so they're restored exactly on exit.
local passengerSaved = setmetatable({}, { __mode = "k" })
local function setPassenger(character, seated)
	if not character then return end
	if seated then
		if passengerSaved[character] then return end
		local saved = {}
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				saved[part] = { group = part.CollisionGroup, massless = part.Massless }
				part.CollisionGroup = PASSENGER_GROUP
				part.Massless = true
			end
		end
		passengerSaved[character] = saved
	else
		local saved = passengerSaved[character]
		if not saved then return end
		passengerSaved[character] = nil
		for part, s in pairs(saved) do
			if part.Parent then
				part.CollisionGroup = s.group
				part.Massless = s.massless
			end
		end
	end
end

-- The driver owns the WHOLE car. Wheels/knuckles are separate assemblies
-- joined by hinges; owning only the seat's assembly left them server-owned
-- and the two fought over the network in live servers (jitter / snapping).
local function setCarOwner(car, player)
	for _, part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") and not part.Anchored then
			if player then pcall(part.SetNetworkOwner, part, player)
			else pcall(part.SetNetworkOwnershipAuto, part) end
		end
	end
end

-- GTA: you only get into a car with F (CarEnterExit / the traffic carjack). Whatever
-- seats a player on purpose stamps CarEnterAt first; a seat taken without a fresh
-- stamp (walking into it) throws them straight back out.
function allowCarEntry(player)
	player:SetAttribute("CarEnterAt", workspace:GetServerTimeNow())
end
local function carEntryAllowed(player)
	local at = tonumber(player:GetAttribute("CarEnterAt")) or 0
	return workspace:GetServerTimeNow() - at < 4
end
local function ejectWalkIn(seat)
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
end

local function setupSeat(car, rootSeat, seat, isDriver)
	-- v41: leave seats enabled so touching the actual seat automatically sits
	-- the character. No E/F proximity prompt is required.
	seat.Disabled = false
	local lastPlayer, lastRoot, lastCharacter = nil, nil, nil

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant
		if occupant then
			local character = occupant.Parent
			local player = Players:GetPlayerFromCharacter(character)
			if player and not carEntryAllowed(player) then
				task.defer(ejectWalkIn, seat) -- walked into it: GTA cars are entered with F
				return
			end
			lastPlayer, lastRoot, lastCharacter = player, character:FindFirstChild("HumanoidRootPart"), character
			setPassenger(character, true)
			-- no tripping / ragdolling while buckled in
			pcall(function()
				occupant:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
				occupant:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			end)
			if player then
				giveDoorGui(player,car)
				local pr=character:FindFirstChild("HumanoidRootPart")
				if pr then pr.Anchored=false end
				if isDriver then setCarOwner(car, player) end
			end
		else
			if not lastCharacter then
				return -- a walk-in that was thrown out never really got in
			end
			if isDriver then
				setCarOwner(car, nil)
			end
			local exitingRoot, exitingCharacter = lastRoot, lastCharacter
			setPassenger(exitingCharacter, false)
			local hum = exitingCharacter and exitingCharacter:FindFirstChildOfClass("Humanoid")
			if hum then
				pcall(function()
					hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
					hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
				end)
			end
			if exitingRoot and exitingRoot.Parent and car.Parent then
				local pos = exitPosition(car, rootSeat, seat, exitingCharacter)
				task.defer(function()
					if exitingRoot.Parent then
						exitingRoot.AssemblyLinearVelocity = Vector3.zero
						exitingRoot.CFrame = CFrame.new(pos) * exitingRoot.CFrame.Rotation
					end
				end)
			end
			lastPlayer, lastRoot, lastCharacter = nil, nil, nil
		end
	end)
end

---------------------------------------------------------------------------
-- Spawning
---------------------------------------------------------------------------

local function destroyCar(car)
	if not car then
		return
	end
	carDoors[car] = nil
	local owner = car:FindFirstChild("Owner") and car.Owner.Value
	if owner and activeCars[owner] == car then
		activeCars[owner] = nil
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local current = doorGuiCar(player)
		if current == car then
			removeDoorGui(player, car)
		end
	end
	car:Destroy()
end

local function spawnCar(player, carName, groundPos, look)
	local template = templates:FindFirstChild(carName)
	if not template then
		return
	end
	destroyCar(activeCars[player])
	activeCars[player] = nil

	local car = template:Clone()
	car.Name = player.Name .. "'s " .. carName
	car:SetAttribute("CarName", carName)
	local essentials = car:FindFirstChild("Essentials")
	local rootSeat = essentials and essentials:FindFirstChildOfClass("VehicleSeat") or car:FindFirstChildWhichIsA("VehicleSeat", true)
	if not rootSeat then
		warn("[CarServer] no VehicleSeat in", carName)
		return
	end
	car.PrimaryPart = rootSeat

	placeAt(car, rootSeat, groundPos, look)
	local driven, doors = prepareCar(car, rootSeat)
	carDoors[car] = doors

	-- v41: no manual ClickDetector/ProximityPrompt door controls.
	-- Door animation remains server-only for AI and prison transport.

	local owner = Instance.new("ObjectValue")
	owner.Name = "Owner"
	owner.Value = player
	owner.Parent = car

	car.Parent = spawnedFolder
	for _, part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end

	for _, seat in ipairs(car:GetDescendants()) do
		if seat:IsA("VehicleSeat") or seat:IsA("Seat") then
			setupSeat(car, rootSeat, seat, seat == rootSeat)
		end
	end
	hookDrive(car, rootSeat, driven, (CARS[carName] or {}).topSpeed or 80)

	activeCars[player]=car
	task.defer(function() giveDoorGui(player,car) end)
	giveDoorGui(player, car) -- removes any legacy DoorGui; v41 shows none
	-- If the car falls out of the world, clean up (and drop its panel).
	rootSeat.AncestryChanged:Connect(function()
		if not rootSeat:IsDescendantOf(workspace) and car.Parent then
			destroyCar(car)
		end
	end)
	print(("[CarServer] spawned %s for %s"):format(carName, player.Name))
	return car
end

-- v164: traffic-car theft is a separate handoff layer; it does not participate
-- in template discovery and therefore cannot break normal owned-car spawning.
local physDriven={} -- v284d: [car] = wheel data from PhysicalizeTraffic
local adoptStolen=ServerStorage:FindFirstChild("AdoptStolenCar") or Instance.new("BindableFunction")
adoptStolen.Name="AdoptStolenCar"
adoptStolen.OnInvoke=function(player,car)
	if typeof(player)~="Instance" or not player:IsA("Player") or typeof(car)~="Instance" or not car:IsA("Model") or not car.Parent then return false end
	local rootSeat=car:FindFirstChildWhichIsA("VehicleSeat",true)
	if not rootSeat then return false end
	-- v221: converting the animated traffic model in place left it frozen. Swap it
	-- for a fresh, normally built car of the same type in the same spot instead
	-- (exactly what a spawned car is) and put the thief in the driver's seat.
	-- v284: a traffic car that is already real physics (CityTraffic crash / surrender) is
	-- kept as it is - dents, broken glass and all - and adopted in place below.
	if not car:GetAttribute("Physicalized") then
		local carType=car:GetAttribute("TrafficCarType")
		local name=if type(carType)=="string" and templates:FindFirstChild(carType) then carType else nil
		if not name then
			for _,n in {"Sedan","SUV","Van","Muscle Car","Sports Car"} do
				if templates:FindFirstChild(n) then name=n;break end
			end
		end
		if name then
			local seatCF=rootSeat.CFrame
			local boxCF,boxSize=car:GetBoundingBox()
			local groundPos=Vector3.new(seatCF.Position.X,boxCF.Position.Y-boxSize.Y/2,seatCF.Position.Z)
			local params=RaycastParams.new();params.FilterType=Enum.RaycastFilterType.Exclude;params.FilterDescendantsInstances={car,player.Character}
			local hit=workspace:Raycast(seatCF.Position+Vector3.new(0,2,0),Vector3.new(0,-30,0),params)
			if hit then groundPos=hit.Position end
			local look=seatCF.LookVector
			local occ=rootSeat.Occupant
			if occ then occ.Sit=false end
			car:Destroy()
			-- keep the thief's own car where it is (spawnCar replaces activeCars[player])
			local own=activeCars[player];activeCars[player]=nil
			local stolen=spawnCar(player,name,groundPos,look)
			if not stolen then activeCars[player]=own;return false end
			stolen.Name="Stolen "..name
			stolen:SetAttribute("StolenVehicle",true);stolen:SetAttribute("StolenByUserId",player.UserId)
			local newSeat=stolen.PrimaryPart
			local hum=player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum and newSeat and newSeat:IsA("VehicleSeat") then
				task.defer(function()
					if hum.Parent and newSeat.Parent then
						pcall(function() hum.Parent:PivotTo(newSeat.CFrame+Vector3.new(0,2,0)) end)
						allowCarEntry(player)
						newSeat:Sit(hum)
					end
				end)
			end
			print(("[CarServer] %s carjacked a %s - respawned as a drivable car"):format(player.Name,name))
			return true
		end
	end
	car.PrimaryPart=rootSeat
	car:SetAttribute("TrafficActive",false);car:SetAttribute("StolenVehicle",true);car:SetAttribute("StolenByUserId",player.UserId)
	-- v284c: a traffic car has a type but no CarName - hookDrive / GTA handling / top speed read CarName
	if not car:GetAttribute("CarName") and type(car:GetAttribute("TrafficCarType"))=="string" then car:SetAttribute("CarName",car:GetAttribute("TrafficCarType")) end
	-- v284d: a car CityTraffic already made physical keeps its joints - preparing it again
	-- doubled the wheel hinges and knuckles and the physics flung the car away
	local hooked=car:GetAttribute("Physicalized") and physDriven[car]~=nil
	if not hooked then
		local driven,doors=prepareCar(car,rootSeat);carDoors[car]=doors
		for _,part in ipairs(car:GetDescendants()) do if part:IsA("BasePart") then part.Anchored=false end end
		for _,seat in ipairs(car:GetDescendants()) do if seat:IsA("VehicleSeat") or seat:IsA("Seat") then setupSeat(car,rootSeat,seat,seat==rootSeat) end end
		hookDrive(car,rootSeat,driven,(CARS[car:GetAttribute("CarName") or car.Name] or {}).topSpeed or 72)
	end
	physDriven[car]=nil
	local oldOwner=car:FindFirstChild("Owner");if oldOwner then oldOwner:Destroy() end
	local owner=Instance.new("ObjectValue");owner.Name="Owner";owner.Value=player;owner.Parent=car
	activeCars[player]=car
	-- v218: the thief sat down before CarServer set the seat up, so the seat's own
	-- Occupant hook never ran for them: hand them the car's physics and controls now.
	local occ=rootSeat.Occupant
	if occ and occ.Parent==player.Character then
		setPassenger(occ.Parent,true)
		pcall(function()
			occ:SetStateEnabled(Enum.HumanoidStateType.FallingDown,false)
			occ:SetStateEnabled(Enum.HumanoidStateType.Ragdoll,false)
		end)
		setCarOwner(car,player)
		giveDoorGui(player,car)
	end
	print(("[CarServer] %s stole and took control of %s"):format(player.Name,car.Name))
	return true
end
adoptStolen.Parent=ServerStorage

-- v284: CityTraffic turns a resident traffic car into real physics in place (a crash is
-- about to happen, the driver surrendered it, the driver was shot): welded body, door
-- hinges, free wheels. No owner and no drive until someone takes it (AdoptStolenCar).
local physicalizeFn=ServerStorage:FindFirstChild("PhysicalizeTraffic") or Instance.new("BindableFunction")
physicalizeFn.Name="PhysicalizeTraffic"
physicalizeFn.OnInvoke=function(car)
	if typeof(car)~="Instance" or not car:IsA("Model") or not car.Parent then return false end
	local rootSeat=car:FindFirstChildWhichIsA("VehicleSeat",true)
	if not rootSeat then return false end
	car.PrimaryPart=rootSeat
	-- v284e: a full car, exactly like a spawned one (GTA weight and suspension, seats, the
	-- drive hookup) - only no owner. A carjack later just hands it over (AdoptStolenCar).
	if not car:GetAttribute("CarName") and type(car:GetAttribute("TrafficCarType"))=="string" then
		car:SetAttribute("CarName",car:GetAttribute("TrafficCarType"))
	end
	local driven,doors=prepareCar(car,rootSeat)
	carDoors[car]=doors
	physDriven[car]=driven
	for _,part in ipairs(car:GetDescendants()) do if part:IsA("BasePart") then part.Anchored=false end end
	for _,seat in ipairs(car:GetDescendants()) do
		if seat:IsA("VehicleSeat") or seat:IsA("Seat") then setupSeat(car,rootSeat,seat,seat==rootSeat) end
	end
	hookDrive(car,rootSeat,driven,(CARS[car:GetAttribute("CarName")] or {}).topSpeed or 72)
	car.AncestryChanged:Connect(function() if not car.Parent then physDriven[car]=nil end end)
	return true
end
physicalizeFn.Parent=ServerStorage

local function padSpot(pad)
	local look = pad.Size.X > pad.Size.Z and pad.CFrame.RightVector or pad.CFrame.LookVector
	return pad.Position + pad.CFrame.UpVector * (pad.Size.Y / 2), look
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
overlap.FilterDescendantsInstances = { spawnedFolder }

local function padIsFree(pad, ignoreCar)
	local size = pad.Size + Vector3.new(0, 10, 0)
	for _, part in ipairs(workspace:GetPartBoundsInBox(pad.CFrame + Vector3.new(0, 5, 0), size, overlap)) do
		if not (ignoreCar and part:IsDescendantOf(ignoreCar)) then
			return false
		end
	end
	return true
end

local function nearestFreePad(position, ignoreCar)
	local best, bestDist = nil, MAX_PAD_DISTANCE
	for _, pad in ipairs(pads) do
		local dist = (pad.Position - position).Magnitude
		if dist < bestDist and padIsFree(pad, ignoreCar) then
			best, bestDist = pad, dist
		end
	end
	return best
end

-- Move the player off the pad so the car doesn't land on them.
local function clearPad(player, pad)
	local root = rootOf(player)
	if not root then
		return
	end
	local rel = pad.CFrame:PointToObjectSpace(root.Position)
	if math.abs(rel.X) < pad.Size.X / 2 + 2 and math.abs(rel.Z) < pad.Size.Z / 2 + 2 then
		local side = pad.Size.X <= pad.Size.Z and pad.CFrame.RightVector * (pad.Size.X / 2 + 4)
			or pad.CFrame.LookVector * (pad.Size.Z / 2 + 4)
		root.CFrame = CFrame.new(pad.Position + side + Vector3.new(0, 4, 0))
	end
end

local lastSpawn = {}

local function trySpawnOnPad(player, carName, pad)
	if player:GetAttribute("VehiclesImpounded") then
		notify(player, "Your vehicles are impounded - Clark County DA")
		return false
	end
	local key = getStorage(player):FindFirstChild(carName)
	if not key then
		notify(player, "You don't have the keys to that car.")
		return false
	end
	local now = os.clock()
	if lastSpawn[player] and now - lastSpawn[player] < 3 then
		return false
	end
	if not padIsFree(pad, activeCars[player]) then
		notify(player, "That pad is taken.")
		return false
	end
	lastSpawn[player] = now
	clearPad(player, pad)
	spawnCar(player, carName, padSpot(pad))
	if key.Value == true then
		key:Destroy() -- single-use keys are used up
	end
	return true
end

spawnRemote.OnServerEvent:Connect(function(player, carName, pad)
	if type(carName) ~= "string" or typeof(pad) ~= "Instance" then
		return
	end
	if not (pad:IsA("BasePart") and pad.Name == "SpawnPlate" and pad:IsDescendantOf(spawnPads)) then
		return
	end
	local root = rootOf(player)
	if not root or (root.Position - pad.Position).Magnitude > 30 then
		return
	end
	trySpawnOnPad(player, carName, pad)
end)

-- Spawn menu when someone steps on a pad
local spawnGuiTemplate = guis:WaitForChild("CarSpawnGui")
local padCooldown = {}

local function onPadTouched(pad, hit)
	local character = hit.Parent
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.SeatPart or #getStorage(player):GetChildren() == 0 then
		return
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui or playerGui:FindFirstChild("CarSpawnGui") then
		return
	end
	local now = os.clock()
	if padCooldown[player] and now - padCooldown[player] < 2 then
		return
	end
	padCooldown[player] = now

	local gui = spawnGuiTemplate:Clone()
	gui.Pad.Value = pad
	gui.Parent = playerGui
end

for _, pad in ipairs(pads) do
	pad.Touched:Connect(function(hit)
		onPadTouched(pad, hit)
	end)
end

-- Buying cars (phone YBCN app, dealer) is handled by EconomyServer.

---------------------------------------------------------------------------
-- Key tools: equip and click to spawn the car on the nearest free spawn pad.
---------------------------------------------------------------------------
local function makeKeyTool(player, carName)
	local tool = Instance.new("Tool")
	tool.Name = carName .. " Keys"
	tool.ToolTip = "Click to spawn your " .. carName .. " at the nearest spawn pad"
	tool.CanBeDropped = false
	tool:SetAttribute("CarName", carName)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.3, 0.8, 0.15)
	handle.Color = Color3.fromRGB(212, 175, 55)
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	tool.Activated:Connect(function()
		local root, humanoid = rootOf(player)
		if not (root and humanoid) or humanoid.SeatPart or humanoid.Health <= 0 then
			return
		end
		local pad = nearestFreePad(root.Position, activeCars[player])
		if not pad then
			notify(player, "No free spawn pad nearby. Find one of the blue pads.")
			return
		end
		if trySpawnOnPad(player, carName, pad) then
			notify(player, ("Your %s is on the nearest spawn pad (%d studs away)."):format(carName, (pad.Position - root.Position).Magnitude))
		end
	end)
	return tool
end

local function syncKeyTools(player)
	local storage = getStorage(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	for _, key in ipairs(storage:GetChildren()) do
		local toolName = key.Name .. " Keys"
		local owned = (backpack and backpack:FindFirstChild(toolName)) or (character and character:FindFirstChild(toolName))
		if backpack and not owned then
			makeKeyTool(player, key.Name).Parent = backpack
		end
	end
	for _, container in ipairs({ backpack, character }) do
		if container then
			for _, item in ipairs(container:GetChildren()) do
				local carName = item:IsA("Tool") and item:GetAttribute("CarName")
				if carName and not storage:FindFirstChild(carName) then
					item:Destroy()
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Players
---------------------------------------------------------------------------
local function onPlayerAdded(player)
	local storage = getStorage(player)
	storage.ChildAdded:Connect(function()
		syncKeyTools(player)
	end)
	storage.ChildRemoved:Connect(function()
		syncKeyTools(player)
	end)
	player.CharacterAdded:Connect(function()
		task.wait(0.5) -- the backpack is rebuilt on every spawn
		syncKeyTools(player)
	end)

	if STARTER_KEYS_FOR_EVERYONE or isDev(player) then
		for _, name in ipairs(STARTER_KEYS) do
			if giveKeys(player, name, false) then
				print(("[CarServer] gave %s keys to %s"):format(name, player.Name))
			else
				warn(("[CarServer] couldn't give %s keys: no car template with that name"):format(name))
			end
		end
	end
	syncKeyTools(player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	destroyCar(activeCars[player])
	activeCars[player] = nil
	lastSpawn[player] = nil
	padCooldown[player] = nil
end)

-- v255: an asset freeze impounds the player's car (AssetFreeze sets VehiclesImpounded)
local function watchImpound(player)
	player:GetAttributeChangedSignal("VehiclesImpounded"):Connect(function()
		if player:GetAttribute("VehiclesImpounded") and activeCars[player] then
			destroyCar(activeCars[player])
			activeCars[player] = nil
			print(("[CarServer] %s's car impounded"):format(player.Name))
		end
	end)
end
Players.PlayerAdded:Connect(watchImpound)
for _, player in ipairs(Players:GetPlayers()) do
	watchImpound(player)
end
