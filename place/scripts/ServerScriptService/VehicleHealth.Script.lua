-- VehicleHealth (v215)
-- While a player sits in a car, the CAR takes the hits instead of the player:
--   * the car has 20x the occupant's max health (2,000 for a normal player)
--   * police bullets and player guns hit the car (ServerStorage.VehicleDamage,
--     called by PoliceSystem.Weapons and WeaponsServer), and any other damage a
--     seated player takes (crashes, explosions...) is moved onto the car
--   * at zero the car catches fire, burns for a few seconds and explodes
-- Car health is on the car model: VehicleHealth / VehicleMaxHealth attributes
-- (the client draws a yellow bar next to the green health bar).

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local HEALTH_MULTIPLIER = 20
local BURN_TIME = 4.5
local WRECK_TIME = 25

-- the car a seated humanoid is in: the top model under Workspace that holds the seat
local function carOf(hum: Humanoid): Model?
	local seat = hum.SeatPart
	if not seat or not (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
		return nil
	end
	local model: Instance? = seat:FindFirstAncestorWhichIsA("Model")
	while model and model.Parent and model.Parent ~= Workspace and model.Parent:IsA("Model") do
		model = model.Parent
	end
	if not model or not model:IsA("Model") then
		return nil
	end
	-- a car has a driver's seat somewhere
	if not model:FindFirstChildWhichIsA("VehicleSeat", true) then
		return nil
	end
	-- police / resident traffic NPC cars are not player cars
	if model:GetAttribute("TrafficActive") == true then
		return nil
	end
	-- v218: only a real vehicle. A chair (or the execution chair) inside a
	-- building used to make the WHOLE building the "car" - taking damage while
	-- seated there wrecked and deleted the correctional facility.
	local isCar = model:FindFirstChild("Owner") ~= nil
		or model:GetAttribute("StolenVehicle") == true
		or model:GetAttribute("CarName") ~= nil
		or seat:IsA("VehicleSeat")
	if not isCar then
		return nil
	end
	local ok, size = pcall(model.GetExtentsSize, model)
	if not ok or size.Magnitude > 80 then
		return nil
	end
	local parts = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
			if parts > 800 then
				return nil
			end
		end
	end
	return model
end

local function ensureHealth(car: Model, hum: Humanoid)
	if car:GetAttribute("VehicleMaxHealth") == nil then
		local max = math.max(100, hum.MaxHealth) * HEALTH_MULTIPLIER
		car:SetAttribute("VehicleMaxHealth", max)
		car:SetAttribute("VehicleHealth", max)
	end
end

local wrecked: { [Model]: boolean } = {}

local function occupants(car: Model): { Humanoid }
	local out = {}
	for _, seat in car:GetDescendants() do
		if (seat:IsA("VehicleSeat") or seat:IsA("Seat")) and seat.Occupant then
			table.insert(out, seat.Occupant)
		end
	end
	return out
end

local damageCar: (Model, number, number?) -> () -- (below: crash / blast damage to any car)

-- v290e: the blast hurts: people round it (falling off with distance) and the cars next to
-- it, which catch fire and go up in turn - a chain down a line of parked cars
local BLAST_RADIUS = 26
local function topCar(part: BasePart): Model?
	local m: Instance? = part:FindFirstAncestorWhichIsA("Model")
	while m and m.Parent and m.Parent ~= Workspace and m.Parent.Name ~= "SpawnedCars" and m.Parent:IsA("Model") do
		m = m.Parent
	end
	if m and m:IsA("Model") and m:FindFirstChildWhichIsA("VehicleSeat", true) then
		local ok, size = pcall(m.GetExtentsSize, m)
		if ok and size.Magnitude < 80 then return m end
	end
	return nil
end
local function blastDamage(source: Model, at: Vector3)
	local hitPeople: { [Humanoid]: boolean } = {}
	local hitCars: { [Model]: number } = {}
	for _, p in Workspace:GetPartBoundsInRadius(at, BLAST_RADIUS) do
		local m = p:FindFirstAncestorWhichIsA("Model")
		local hum = m and m:FindFirstChildOfClass("Humanoid")
		if hum and not hitPeople[hum] and hum.Health > 0 then
			hitPeople[hum] = true
			local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
			local d = ((root and root.Position) or p.Position) - at
			local f = math.clamp(1 - d.Magnitude / BLAST_RADIUS, 0, 1)
			if f > 0 then
				-- someone sitting in a car: the car takes it (absorb), otherwise the person does
				local car = carOf(hum)
				if car and car ~= source and not wrecked[car] then
					damageCar(car, 1400 * f)
				elseif not car or car == source then
					hum:TakeDamage(110 * f)
					if root and f > 0.3 and not hum.Sit then
						root.AssemblyLinearVelocity += (d.Unit + Vector3.new(0, 0.8, 0)) * 55 * f
					end
				end
			end
		elseif not hum then
			local car = topCar(p)
			if car and car ~= source and not wrecked[car] then
				local cf = car:GetBoundingBox()
				hitCars[car] = math.clamp(1 - (cf.Position - at).Magnitude / BLAST_RADIUS, 0, 1)
			end
		end
	end
	-- the cars around it: a heavy dose close up (a car alongside is wrecked and burns), less
	-- further out
	for car, f in hitCars do
		if f > 0 and not wrecked[car] then damageCar(car, 2400 * f, 1.4 + math.random() * 2.2) end
	end
end

local function wreck(car: Model, burnTime: number?)
	if wrecked[car] then
		return
	end
	wrecked[car] = true
	car:SetAttribute("VehicleHealth", 0)
	car:SetAttribute("VehicleDestroyed", true)
	local seat = car:FindFirstChildWhichIsA("VehicleSeat", true)
	if seat then
		seat:SetAttribute("VehicleDestroyed", true)
	end
	local core: BasePart? = car.PrimaryPart or seat
	if not core then
		for _, d in car:GetDescendants() do
			if d:IsA("BasePart") then
				core = d
				break
			end
		end
	end
	if not core then
		return
	end
	-- the engine catches fire
	local fire = Instance.new("Fire")
	fire.Size = 10
	fire.Heat = 14
	fire.Parent = core
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(40, 40, 40)
	smoke.Opacity = 0.6
	smoke.Size = 12
	smoke.RiseVelocity = 8
	smoke.Parent = core
	for _, hum in occupants(car) do
		local plr = Players:GetPlayerFromCharacter(hum.Parent)
		if plr then
			local r = game:GetService("ReplicatedStorage"):FindFirstChild("PrisonSociety")
			local notice = r and r:FindFirstChild("Notice")
			if notice then
				notice:FireClient(plr, "YOUR CAR IS ON FIRE - GET OUT!")
			end
		end
	end
	task.delay(burnTime or BURN_TIME, function()
		if not car.Parent then
			return
		end
		local at = core.Position
		local blast = Instance.new("Explosion")
		blast.Position = at
		blast.BlastRadius = 14
		blast.BlastPressure = 250000
		blast.DestroyJointRadiusPercent = 0 -- never break the map around the wreck
		blast.Parent = Workspace
		-- the burnt-out shell keeps burning
		fire.Size = 16
		fire.Heat = 20
		smoke.Size = 18
		pcall(blastDamage, car, at)
		-- and the wreck leaps
		pcall(function()
			if core:IsA("BasePart") and not core.Anchored then
				core.AssemblyLinearVelocity += Vector3.new(math.random(-8, 8), 38, math.random(-8, 8))
				core.AssemblyAngularVelocity += Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 3
			end
		end)
		for _, d in car:GetDescendants() do
			if d:IsA("BasePart") then
				d.Color = d.Color:Lerp(Color3.fromRGB(25, 22, 20), 0.85)
				d.Material = Enum.Material.CorrodedMetal
			elseif d:IsA("VehicleSeat") then
				d.Disabled = true
			end
		end
		if seat then
			seat.Disabled = true
			seat.MaxSpeed = 0
		end
		Debris:AddItem(car, WRECK_TIME)
	end)
end

-- apply `amount` damage to the car this humanoid sits in; returns what's left for the humanoid
local function absorb(hum: Humanoid, amount: number): number
	if amount <= 0 then
		return amount
	end
	local car = carOf(hum)
	if not car or wrecked[car] then
		return amount
	end
	ensureHealth(car, hum)
	local health = tonumber(car:GetAttribute("VehicleHealth")) or 0
	health -= amount
	car:SetAttribute("VehicleHealth", math.max(0, health))
	if health <= 0 then
		wreck(car)
	end
	return 0
end

local fn = ServerStorage:FindFirstChild("VehicleDamage") or Instance.new("BindableFunction")
fn.Name = "VehicleDamage"
fn.OnInvoke = function(hum: any, amount: any): number
	if typeof(hum) ~= "Instance" or not hum:IsA("Humanoid") then
		return tonumber(amount) or 0
	end
	return absorb(hum, tonumber(amount) or 0)
end
fn.Parent = ServerStorage

-- v284: crash damage (CarDamage) - the car itself takes it, driver or not
local crash = ServerStorage:FindFirstChild("VehicleCrash") or Instance.new("BindableFunction")
crash.Name = "VehicleCrash"
function damageCar(car: Model, amount: number, burnTime: number?)
	if wrecked[car] or amount <= 0 then return end
	if car:GetAttribute("VehicleMaxHealth") == nil then
		car:SetAttribute("VehicleMaxHealth", 100 * HEALTH_MULTIPLIER)
		car:SetAttribute("VehicleHealth", 100 * HEALTH_MULTIPLIER)
	end
	local health = (tonumber(car:GetAttribute("VehicleHealth")) or 0) - amount
	car:SetAttribute("VehicleHealth", math.max(0, health))
	if amount >= 100 or health <= 0 then
		print(("[VehicleHealth] %s took %.0f -> %.0f left%s"):format(car.Name, amount, math.max(0, health), if health <= 0 then " - ON FIRE" else ""))
	end
	-- a badly smashed car smokes
	local max = tonumber(car:GetAttribute("VehicleMaxHealth")) or 2000
	if health < max * 0.3 and health > 0 then
		local core = car.PrimaryPart or car:FindFirstChildWhichIsA("VehicleSeat", true)
		if core and not core:FindFirstChild("DamageSmoke") then
			local s = Instance.new("Smoke")
			s.Name = "DamageSmoke"
			s.Color = Color3.fromRGB(60, 60, 60)
			s.Opacity = 0.35
			s.Size = 6
			s.RiseVelocity = 5
			s.Parent = core
		end
	end
	if health <= 0 then wreck(car, burnTime) end
end
crash.OnInvoke = function(car: any, amount: any)
	if typeof(car) ~= "Instance" or not car:IsA("Model") or wrecked[car] then return false end
	amount = tonumber(amount) or 0
	if amount <= 0 then return true end
	damageCar(car, amount)
	return true
end
crash.Parent = ServerStorage

-- anything else that hurts a seated player (crashes, explosions, other weapons)
-- is moved onto the car as long as the car is alive
local function watch(player: Player, char: Model)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if not hum then
		return
	end
	local last = hum.Health
	hum:GetPropertyChangedSignal("SeatPart"):Connect(function()
		local car = carOf(hum)
		if car then
			ensureHealth(car, hum)
		end
		last = hum.Health
	end)
	hum.HealthChanged:Connect(function(health)
		if health < last and health > 0 then
			local car = carOf(hum)
			if car and not wrecked[car] then
				local lost = last - health
				absorb(hum, lost)
				hum.Health = last -- the car took it
				return
			end
		end
		last = health
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		watch(player, char)
	end)
	if player.Character then
		watch(player, player.Character)
	end
end)
for _, player in Players:GetPlayers() do
	player.CharacterAdded:Connect(function(char)
		watch(player, char)
	end)
	if player.Character then
		task.spawn(watch, player, player.Character)
	end
end

print("[VehicleHealth] cars take the hits (x" .. HEALTH_MULTIPLIER .. " health), burn and explode at zero")
