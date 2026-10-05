--[[
	CarDamage (v284) - crashes leave marks, GTA style.

	Every real car (player cars in SpawnedCars, police cars, traffic cars made physical by a
	crash) is watched for impacts: a sudden change in velocity. The harder the hit, the more:
	  * DENTS: body panels around the impact are pushed in and twisted a little (the welds are
	    re-made at the new spot, so the car keeps driving with its damage)
	  * GLASS: windows and windscreens near the impact shatter (shards, then an empty frame)
	  * LIGHTS: headlights / tail lights smash and go dark
	  * DOORS: a door that's OPEN when it's hit hard enough comes off its hinge; a closed one
	    can be ripped off by a big side hit
	  * BUMPERS, mirrors, spoilers can come off in big hits
	  * HEALTH: the car loses health (VehicleHealth: at zero it burns and explodes)
	Loose parts fall away and are cleaned up. Logs: [CarDamage] (only big hits)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local CFG = {
	MinImpact = 20, -- studs/s of sudden velocity change
	DentFrom = 22,
	GlassFrom = 30,
	LightFrom = 24,
	OpenDoorFrom = 22,
	ClosedDoorFrom = 105, -- v290e: was 70 - every hard hit tore the doors off (1 per hit now)
	LooseFrom = 100, -- v290e: was 58
	MaxDent = 1.3, -- studs a panel can be pushed in, in total
	Cooldown = 0.18,
	HealthPerImpact = 3.2, -- health lost per stud/s over MinImpact
	Debris = 35,
}

local debrisFolder = workspace:FindFirstChild("CarDebris") or Instance.new("Folder")
debrisFolder.Name = "CarDebris"
debrisFolder.Parent = workspace

local tracked: { [Model]: { seat: BasePart, lastV: Vector3, lastPos: Vector3, hitAt: number, grace: number, collUntil: number?, collPeak: number? } } = {}

local function rootOf(car: Model): BasePart?
	local s = car.PrimaryPart
	if s and s:IsA("BasePart") then return s end
	local v = car:FindFirstChildWhichIsA("VehicleSeat", true)
	return v
end

local function isWheel(part: BasePart): boolean
	local p = part.Parent
	local n = part.Name
	if p and p.Name == "Essentials" and (n == "LF" or n == "RF" or n == "LB" or n == "RB" or n == "LR" or n == "RR") then return true end
	if n == "Pivot" or n:find("Wheel") or n:find("Tire") or n:find("Rim") or n:find("Axle") or n:find("Knuckle") then return true end
	return false
end
local function isGlass(part: BasePart): boolean
	local n = string.lower(part.Name)
	if part.Material == Enum.Material.Glass then return true end
	if n:find("window") or n:find("glass") or n:find("windshield") or n:find("windscreen") then return true end
	return part.Transparency >= 0.2 and part.Transparency <= 0.85 and part.Name == "Part"
end
local function isLight(part: BasePart): boolean
	local n = string.lower(part.Name)
	return n:find("light") ~= nil or n:find("lamp") ~= nil
end
local function isLoose(part: BasePart): boolean
	local n = string.lower(part.Name)
	return n:find("bumper") ~= nil or n:find("mirror") ~= nil or n:find("spoiler") ~= nil or n:find("hood") ~= nil or n:find("plate") ~= nil
end

-- every weld that holds this part
local function weldsOf(part: BasePart, car: Model): { Instance }
	local out = {}
	for _, d in car:GetDescendants() do
		if d:IsA("WeldConstraint") or d:IsA("Weld") then
			local w = d :: any
			if (w.Part0 == part or w.Part1 == part) and d.Name ~= "SeatWeld" and d.Name ~= "DoorHinge" then table.insert(out, d) end
		end
	end
	return out
end

local function shards(at: Vector3, colour: Color3, dir: Vector3)
	for _ = 1, 7 do
		local s = Instance.new("Part")
		s.Size = Vector3.new(0.3, 0.05, 0.3) * (0.6 + math.random())
		s.Color = colour
		s.Material = Enum.Material.Glass
		s.Transparency = 0.3
		s.CanCollide = true
		s.CanQuery = false
		s.CFrame = CFrame.new(at + Vector3.new(math.random() - 0.5, math.random() * 0.5, math.random() - 0.5)) * CFrame.Angles(math.random() * 6, math.random() * 6, 0)
		s.AssemblyLinearVelocity = dir * (6 + math.random() * 8) + Vector3.new(math.random(-6, 6), 6 + math.random() * 6, math.random(-6, 6))
		s.Parent = debrisFolder
		Debris:AddItem(s, 6)
	end
end

local function sparks(at: Vector3, power: number)
	local a = Instance.new("Part")
	a.Anchored = true
	a.CanCollide = false
	a.CanQuery = false
	a.Transparency = 1
	a.Size = Vector3.new(0.2, 0.2, 0.2)
	a.Position = at
	a.Parent = debrisFolder
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(Color3.fromRGB(255, 210, 120), Color3.fromRGB(255, 120, 30))
	e.LightEmission = 1
	e.Size = NumberSequence.new(0.25, 0)
	e.Lifetime = NumberRange.new(0.2, 0.5)
	e.Speed = NumberRange.new(10, 25)
	e.SpreadAngle = Vector2.new(70, 70)
	e.Rate = 0
	e.Parent = a
	e:Emit(math.clamp(math.floor(power / 4), 6, 30))
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxasset://sounds/collide.wav"
	snd.Volume = math.clamp(power / 60, 0.3, 1.2)
	snd.PlaybackSpeed = 0.7 + math.random() * 0.2
	snd.RollOffMaxDistance = 220
	snd.Parent = a
	pcall(function() snd:Play() end)
	Debris:AddItem(a, 2)
end

-- detach a part (or a whole door model) and let it fall
local function detach(things: { BasePart }, car: Model, push: Vector3)
	local holder = Instance.new("Model")
	holder.Name = "CarPart"
	for _, p in things do
		for _, w in weldsOf(p, car) do
			local ww = w :: any
			-- keep welds between the pieces we're taking together
			local other = if ww.Part0 == p then ww.Part1 else ww.Part0
			if not table.find(things, other) then w:Destroy() end
		end
	end
	for _, p in things do
		p.Anchored = false
		p.CanCollide = p.Transparency < 0.9
		p.Massless = false
		p.Parent = holder
	end
	holder.Parent = debrisFolder
	for _, p in things do
		pcall(function() p.AssemblyLinearVelocity = p.AssemblyLinearVelocity + push end)
	end
	Debris:AddItem(holder, CFG.Debris)
end

local function doorOpen(hinge: Weld): boolean
	local closed = hinge:GetAttribute("ClosedC0")
	if typeof(closed) ~= "CFrame" then return false end
	local a = hinge.C0.LookVector
	local b = closed.LookVector
	return a:Dot(b) < 0.97 -- more than ~14 degrees open
end

local function crashHealth(car: Model, amount: number)
	local fn = ServerStorage:FindFirstChild("VehicleCrash")
	if fn and fn:IsA("BindableFunction") then pcall(fn.Invoke, fn, car, amount) end
end

local function impact(car: Model, root: BasePart, power: number, dir: Vector3)
	-- v290d: no real crash here goes past ~140 studs/s of velocity change; anything above is a
	-- physics glitch (cars overlapping as they wake) - it mustn't wreck a car in one go
	power = math.min(power, 140)
	-- v290f: ONE collision is one hit. The scrape and bounce after the first contact read as a
	-- string of new impacts a few tenths apart (each one costing up to a fifth of the car) - a
	-- car died in a single crash. Inside 0.8 s only what goes past the hardest reading counts.
	local t = tracked[car]
	if t then
		local now = os.clock()
		if now < (t.collUntil or 0) then
			local peak = t.collPeak or 0
			t.collUntil = now + 0.8
			if power <= peak + CFG.MinImpact * 0.5 then return end
			t.collPeak = power
			power = CFG.MinImpact + (power - peak)
		else
			t.collUntil = now + 0.8
			t.collPeak = power
		end
	end
	-- where it hit: the side of the car opposite the velocity change
	local cf, size = car:GetBoundingBox()
	local dl = cf:VectorToObjectSpace(dir)
	local half = size / 2
	local t = math.huge
	for _, axis in { "X", "Y", "Z" } do
		local c = math.abs((dl :: any)[axis])
		if c > 1e-3 then t = math.min(t, (half :: any)[axis] / c) end
	end
	if t == math.huge then t = 0 end
	local at = cf.Position - dir * t
	local radius = 2.6 + math.min(power, 110) / 22 -- v290e: the damage stays round the point of impact
	if power >= 40 then
		print(("[CarDamage] %s hit at %.0f studs/s"):format(car.Name, power))
	end
	sparks(at, power)
	crashHealth(car, (power - CFG.MinImpact) * CFG.HealthPerImpact)
	local center = cf.Position

	-- doors first (they come off whole)
	local essentials = car:FindFirstChild("Essentials")
	local doors = essentials and essentials:FindFirstChild("Doors")
	if doors then
		local lostDoor = false
		for _, door in doors:GetChildren() do
			if door:IsA("Model") and not lostDoor then
				local pivot = door:FindFirstChild("Pivot") or door:FindFirstChildWhichIsA("BasePart", true)
				local hinge = pivot and pivot:FindFirstChild("DoorHinge")
				if pivot and hinge and hinge:IsA("Weld") then
					local dc = door:GetBoundingBox().Position
					if (dc - at).Magnitude < radius * 1.5 then
						local open = doorOpen(hinge)
						if (open and power >= CFG.OpenDoorFrom) or (power >= CFG.ClosedDoorFrom and math.random() < 0.3) then
							lostDoor = true
							local parts = {}
							for _, p in door:GetDescendants() do if p:IsA("BasePart") then table.insert(parts, p) end end
							hinge:Destroy()
							detach(parts, car, dir * power * 0.35 + Vector3.new(0, 8, 0))
							print(("[CarDamage] %s lost a door (%s)"):format(car.Name, if open then "open" else "ripped off"))
						end
					end
				end
			end
		end
	end

	for _, part in car:GetDescendants() do
		if not part:IsA("BasePart") or part == root or part:IsA("Seat") or part:IsA("VehicleSeat") then continue end
		if part.Transparency >= 0.95 or isWheel(part) then continue end
		if part:FindFirstAncestorOfClass("Model") and part:FindFirstAncestorOfClass("Model"):FindFirstChildOfClass("Humanoid") then continue end
		local dist = (part.Position - at).Magnitude
		if dist > radius * 1.3 then continue end
		local fall = math.clamp(1 - dist / (radius * 1.3), 0, 1)
		if isGlass(part) then
			if power >= CFG.GlassFrom and fall > 0.15 and not part:GetAttribute("Shattered") then
				part:SetAttribute("Shattered", true)
				shards(part.Position, part.Color, -dir)
				part.Transparency = 1
				part.CanCollide = false
			end
			continue
		end
		if isLight(part) then
			if power >= CFG.LightFrom and fall > 0.2 and not part:GetAttribute("Broken") then
				part:SetAttribute("Broken", true)
				part.Material = Enum.Material.SmoothPlastic
				part.Color = part.Color:Lerp(Color3.fromRGB(20, 20, 20), 0.75)
				for _, l in part:GetDescendants() do
					if l:IsA("Light") then l.Enabled = false end
				end
			end
			continue
		end
		if isLoose(part) and power >= CFG.LooseFrom and fall > 0.4 and math.random() < 0.45 then
			detach({ part }, car, dir * power * 0.3 + Vector3.new(0, 6, 0))
			continue
		end
		-- dent: push it in (toward where the car's centre is from the impact) and twist it a touch
		if power >= CFG.DentFrom and fall > 0 then
			local done = tonumber(part:GetAttribute("Dent")) or 0
			if done < CFG.MaxDent then
				local amount = math.min(CFG.MaxDent - done, math.clamp((power - CFG.DentFrom) / 55, 0, 0.75) * fall)
				if amount > 0.02 then
					local inward = (center - at)
					inward = if inward.Magnitude > 0.01 then inward.Unit else dir
					local welds = weldsOf(part, car)
					for _, w in welds do (w :: any).Enabled = false end
					local twist = CFrame.Angles((math.random() - 0.5) * 0.12 * fall, (math.random() - 0.5) * 0.08 * fall, (math.random() - 0.5) * 0.12 * fall)
					part.CFrame = (part.CFrame + inward * amount) * twist
					for _, w in welds do
						if w:IsA("Weld") then
							-- classic welds: rebuild C0 from the new placement
							local ww = w :: any
							if ww.Part0 and ww.Part1 then ww.C0 = ww.Part0.CFrame:ToObjectSpace(ww.Part1.CFrame) * ww.C1 end
						end
						(w :: any).Enabled = true
					end
					part:SetAttribute("Dent", done + amount)
					-- scraped paint
					if fall > 0.5 and power > 45 then part.Color = part.Color:Lerp(Color3.fromRGB(90, 90, 92), 0.12) end
				end
			end
		end
	end
end

local function watch(car: Model)
	if tracked[car] or not car:IsA("Model") then return end
	local root = rootOf(car)
	if not root then return end
	tracked[car] = { seat = root, lastV = root.AssemblyLinearVelocity, lastPos = root.Position, hitAt = 0, grace = os.clock() + 1 }
end

local function scan()
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then for _, m in sp:GetChildren() do watch(m) end end
	for _, m in CollectionService:GetTagged("TrafficWreck") do watch(m) end
	for car in tracked do
		if not car.Parent then tracked[car] = nil end
	end
end

local scanClock = 0
RunService.Heartbeat:Connect(function(dt)
	scanClock += dt
	if scanClock > 1 then
		scanClock = 0
		scan()
	end
	local now = os.clock()
	for car, t in tracked do
		local root = t.seat
		if not root.Parent or root.Anchored then
			-- frozen (traffic): when it becomes physics, the first velocity is not a crash
			t.lastV = Vector3.zero
			t.grace = now + 0.8
			continue
		end
		local v = root.AssemblyLinearVelocity
		local pos = root.Position
		-- v290d: a car a player's machine simulates (their own, a traffic car they rammed) is
		-- judged there (CarImpact below): what reaches the server is late and jumpy - it read
		-- 300-850 studs/s "hits" off 50 studs/s crashes and blew traffic up on the first touch
		local owner: Player? = nil
		pcall(function() owner = root:GetNetworkOwner() end)
		if owner then
			t.lastV = v
			t.lastPos = pos
			continue
		end
		local dv = v - t.lastV
		dv = Vector3.new(dv.X, dv.Y * 0.35, dv.Z) -- landings count a little
		-- a teleport / respawn / scripted move: the position jumped more than the speed explains
		local moved = (pos - t.lastPos).Magnitude
		local teleported = moved > (math.max(t.lastV.Magnitude, v.Magnitude) * dt + 6)
		t.lastV = v
		t.lastPos = pos
		if teleported then t.grace = now + 0.5 end
		local power = dv.Magnitude
		if power >= CFG.MinImpact and now > t.grace and now - t.hitAt > CFG.Cooldown and car:GetAttribute("VehicleDestroyed") ~= true then
			t.hitAt = now
			local ok, err = pcall(impact, car, root, power, dv.Unit)
			if not ok then warn("[CarDamage] " .. tostring(err)) end
		end
	end
end)

-- v284e: crashes are seen best where the physics runs - the driver's machine. The client
-- reports impacts on its own car and the physical cars near it; the server checks them.
do
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local remote = ReplicatedStorage:FindFirstChild("CarImpact") or Instance.new("RemoteEvent")
	remote.Name = "CarImpact"
	remote.Parent = ReplicatedStorage
	local budget: { [Player]: number } = {}
	remote.OnServerEvent:Connect(function(player, car, power, dir)
		if typeof(car) ~= "Instance" or not car:IsA("Model") or not car.Parent then return end
		if type(power) ~= "number" or power ~= power or typeof(dir) ~= "Vector3" or dir.Magnitude < 0.5 then return end
		power = math.clamp(power, 0, 220)
		if power < CFG.MinImpact then return end
		-- a few reports a second at most, and only about cars near them
		local now = os.clock()
		if (budget[player] or 0) > now + 1 then return end
		budget[player] = math.max(budget[player] or 0, now) + 0.2
		local root = rootOf(car)
		local ch = player.Character
		local pr = ch and ch:FindFirstChild("HumanoidRootPart")
		if not root or not pr or (root.Position - pr.Position).Magnitude > 150 or root.Anchored then return end
		if car:GetAttribute("VehicleDestroyed") == true then return end
		watch(car)
		local t = tracked[car]
		if not t or now - t.hitAt < CFG.Cooldown or now < t.grace then return end
		t.hitAt = now
		local ok, err = pcall(impact, car, root, power, dir.Unit)
		if not ok then warn("[CarDamage] " .. tostring(err)) end
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(p) budget[p] = nil end)
end

print("[CarDamage] v284 ready (dents, glass, lights, doors, loose parts)")
