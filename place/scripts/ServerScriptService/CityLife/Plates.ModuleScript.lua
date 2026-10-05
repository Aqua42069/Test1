--[[
	CityLife.Plates (v262) - plates, registration, plate readers, plate theft (spec 10.3)

	REGISTRATION: every car has a plate on the back and a record: owner, type, colour.
	  Your own cars register the first time they're spawned (saved in your profile; the same
	  plate every time). Traffic cars get an NPC owner when someone looks at them. A carjacked
	  car stays registered to its real owner and is reported stolen a minute or two later.
	THE RECORD MUST MATCH THE CAR: right type and colour = clean. A respray (the spray shops)
	  changes the colour but not the record - "plate doesn't match vehicle" - until you
	  re-register at the DMV counter (the courthouse clerk, $250, logged).
	PLATE READERS (ALPR) on every cruiser, AI or player-driven: ~60 studs and line of sight.
	  Hits go on the radio: stolen car, stolen plate, plate/vehicle mismatch, registered owner
	  with a warrant (served if the owner is driving), suspended licence, BOLO match.
	PLATE THEFT: hold the prompt on the back of a parked car (not yours) - a few seconds, a
	  crime if a cop sees it. Stolen plates are reported a few minutes later. Shady dealers
	  sell stolen plates (Connections). Cold plates (Underground) pass every check.
	  Fit a plate: the "Change plates" prompt on your own parked car.
	Logs: [Plates]
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local P = {}
local Core: any

local CFG = {
	ReaderRange = 60,
	ReaderTick = 1,
	HitCooldown = 40,
	StolenReportDelay = { 50, 120 },
	StolenPlateReportDelay = { 150, 360 },
	ReRegisterFee = 250,
}

-- plate -> record { plate, owner = name, ownerId = userId?, kind = "player"|"npc"|"cold",
--                   type, colour, stolenAt (car reported stolen at), plateStolenAt, burned }
P.registry = {} :: { [string]: any }
local hitAt: { [string]: number } = {}

---------------------------------------------------------------------------
-- what a car is
---------------------------------------------------------------------------
local SKIP = { "wheel", "tire", "tyre", "rim", "glass", "window", "light", "lamp", "seat", "mirror", "plate", "interior", "hub", "exhaust", "grill" }
local function colourName(c: Color3): string
	local h, s, v = c:ToHSV()
	if v < 0.18 then return "Black" end
	if s < 0.15 then
		if v > 0.85 then return "White" end
		if v > 0.55 then return "Silver" end
		return "Grey"
	end
	local deg = h * 360
	if s < 0.35 and v < 0.55 then return "Brown" end
	if deg < 15 or deg >= 345 then return "Red" end
	if deg < 40 then return if v < 0.6 then "Brown" else "Orange" end
	if deg < 70 then return "Yellow" end
	if deg < 165 then return "Green" end
	if deg < 200 then return "Teal" end
	if deg < 255 then return "Blue" end
	if deg < 290 then return "Purple" end
	return "Pink"
end
function P.colourOf(car: Model): string
	local votes: { [string]: number } = {}
	for _, d in car:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.5 and d.Material ~= Enum.Material.Glass and d.Material ~= Enum.Material.Neon then
			local n = string.lower(d.Name)
			local skip = false
			for _, s in SKIP do if n:find(s) then skip = true break end end
			if not skip and not d:IsA("VehicleSeat") then
				local vol = d.Size.X * d.Size.Y * d.Size.Z
				local cn = colourName(d.Color)
				votes[cn] = (votes[cn] or 0) + vol
			end
		end
	end
	local best, bv = "Grey", -1
	for k, v in votes do
		-- black trim is everywhere: only call a car black when it really is
		local w = if k == "Black" then v * 0.45 else v
		if w > bv then best, bv = k, w end
	end
	return best
end
function P.typeOf(car: Model): string
	return tostring(car:GetAttribute("CarName") or car:GetAttribute("TrafficCarType") or car:GetAttribute("RegType") or "Car")
end
function P.isTraffic(car: Model): boolean
	return car.Name == "Resident Traffic" or car:GetAttribute("TrafficCarType") ~= nil and car:GetAttribute("CarName") == nil
end
function P.describe(car: Model): any
	return { type = P.typeOf(car), colour = P.colourOf(car), plate = car:GetAttribute("Plate") }
end

---------------------------------------------------------------------------
-- the plate on the back
---------------------------------------------------------------------------
local function seatOf(car: Model): BasePart?
	if car.PrimaryPart then return car.PrimaryPart end
	return car:FindFirstChildWhichIsA("VehicleSeat", true)
end
local function plateText(part: BasePart, plate: string)
	local gui = part:FindFirstChild("PlateGui") :: SurfaceGui?
	if not gui then
		local g = Instance.new("SurfaceGui")
		g.Name = "PlateGui"
		g.Face = Enum.NormalId.Back
		g.CanvasSize = Vector2.new(200, 70)
		g.LightInfluence = 0.6
		g.Parent = part
		local top = Instance.new("TextLabel")
		top.Name = "State"
		top.BackgroundTransparency = 1
		top.Size = UDim2.new(1, 0, 0.3, 0)
		top.Font = Enum.Font.GothamBold
		top.TextScaled = true
		top.TextColor3 = Color3.fromRGB(30, 60, 140)
		top.Text = "NEVADA"
		top.Parent = g
		local t = Instance.new("TextLabel")
		t.Name = "Number"
		t.BackgroundTransparency = 1
		t.Position = UDim2.new(0, 0, 0.28, 0)
		t.Size = UDim2.new(1, 0, 0.72, 0)
		t.Font = Enum.Font.GothamBlack
		t.TextScaled = true
		t.TextColor3 = Color3.fromRGB(25, 25, 30)
		t.Parent = g
		gui = g
	end
	((gui :: SurfaceGui):FindFirstChild("Number") :: TextLabel).Text = plate
end
-- a plate part welded at the rear (rear = against the driver seat's look direction)
function P.attachPlate(car: Model, plate: string): BasePart?
	local seat = seatOf(car)
	if not seat then return nil end
	local part = car:FindFirstChild("LicensePlate") :: BasePart?
	if not part then
		local look = seat.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		if flatLook.Magnitude < 0.1 then return nil end
		flatLook = flatLook.Unit
		local minD, minY, maxY = math.huge, math.huge, -math.huge
		local center = seat.Position
		for _, d in car:GetDescendants() do
			if d:IsA("BasePart") and d.Transparency < 0.9 and d.Name ~= "LicensePlate" then
				local cf, sz = d.CFrame, d.Size
				for _, sx in { -0.5, 0.5 } do
					for _, sy in { -0.5, 0.5 } do
						for _, sz2 in { -0.5, 0.5 } do
							local wp = cf * Vector3.new(sx * sz.X, sy * sz.Y, sz2 * sz.Z)
							local dd = (wp - center):Dot(flatLook)
							if dd < minD then minD = dd end
							if wp.Y < minY then minY = wp.Y end
							if wp.Y > maxY then maxY = wp.Y end
						end
					end
				end
			end
		end
		if minD == math.huge then return nil end
		local y = minY + (maxY - minY) * 0.3
		local rearCenter = Vector3.new(center.X, y, center.Z) + flatLook * (minD - 0.06)
		local p = Instance.new("Part")
		p.Name = "LicensePlate"
		p.Size = Vector3.new(1.9, 0.62, 0.08)
		p.Color = Color3.fromRGB(235, 235, 225)
		p.Material = Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.CanQuery = true
		p.CanTouch = false
		p.Massless = true
		p.Anchored = seat.Anchored
		-- the part's Back face points backwards out of the car
		p.CFrame = CFrame.lookAt(rearCenter, rearCenter + flatLook)
		local w = Instance.new("WeldConstraint")
		w.Part0 = p
		w.Part1 = seat
		w.Parent = p
		p.Parent = car
		part = p
	end
	plateText(part :: BasePart, plate)
	return part
end

---------------------------------------------------------------------------
-- registry
---------------------------------------------------------------------------
local function newPlate(): string
	local p = Core.code()
	while P.registry[p] do p = Core.code() end
	return p
end
function P.register(rec: any): any
	P.registry[rec.plate] = rec
	return rec
end
function P.lookup(plate: string?): any?
	if not plate then return nil end
	return P.registry[string.upper(plate)]
end

-- traffic and unregistered cars get an NPC owner the first time anyone checks
function P.ensure(car: Model): string?
	local plate = car:GetAttribute("Plate")
	if type(plate) == "string" then return plate end
	if not car.Parent then return nil end
	plate = newPlate()
	local rec = P.register({ plate = plate, owner = Core.fakeName(), kind = "npc", type = P.typeOf(car), colour = P.colourOf(car), at = os.time() })
	if car:GetAttribute("StolenVehicle") then
		rec.stolenAt = os.time() + math.random(CFG.StolenReportDelay[1], CFG.StolenReportDelay[2])
	end
	car:SetAttribute("Plate", plate)
	car:SetAttribute("RegType", rec.type)
	return plate
end

-- a player's own car (CarServer, SpawnedCars)
local function onPlayerCar(car: Model)
	task.wait(0.4)
	if not car.Parent then return end
	local ownerV = car:FindFirstChild("Owner")
	local owner = ownerV and ownerV:IsA("ObjectValue") and ownerV.Value
	if not (owner and owner:IsA("Player")) then return end
	local carName = tostring(car:GetAttribute("CarName") or "Car")
	if car:GetAttribute("StolenVehicle") then
		-- carjacked from traffic: it's still somebody else's car
		local plate = P.ensure(car)
		if plate then P.attachPlate(car, plate) end
		Core.log("Plates", "%s's stolen %s carries %s (reported later)", owner.Name, carName, tostring(plate))
		return
	end
	local prof = Core.Profile.get(owner)
	local reg = prof.cars[carName]
	if not reg then
		reg = { plate = newPlate(), colour = P.colourOf(car), registeredAt = os.time() }
		prof.cars[carName] = reg
		Core.Profile.dirty(owner)
		Core.log("Plates", "REGISTERED %s's %s: %s (%s)", owner.Name, carName, reg.plate, reg.colour)
	end
	P.register({ plate = reg.plate, owner = owner.Name, ownerId = owner.UserId, kind = "player", type = carName, colour = reg.colour, at = reg.registeredAt })
	local fitted = reg.fitted or reg.plate
	car:SetAttribute("Plate", fitted)
	car:SetAttribute("RegPlate", reg.plate)
	P.attachPlate(car, fitted)
	-- "Change plates" (owner only, parked)
	local seat = seatOf(car)
	if seat and not seat:FindFirstChild("PlatePrompt") then
		local pr = Instance.new("ProximityPrompt")
		pr.Name = "PlatePrompt"
		pr.ActionText = "Change plates"
		pr.ObjectText = carName
		pr.HoldDuration = 2
		pr.MaxActivationDistance = 9
		pr.RequiresLineOfSight = false
		pr.KeyboardKeyCode = Enum.KeyCode.G
		pr.Enabled = true
		pr:SetAttribute("OwnerOnly", owner.UserId)
		pr.Parent = car:FindFirstChild("LicensePlate") or seat
		pr.Triggered:Connect(function(who: Player)
			if who ~= owner then return end
			P.changePlates(who, car)
		end)
	end
end

function P.changePlates(player: Player, car: Model)
	local prof = Core.Profile.get(player)
	local carName = tostring(car:GetAttribute("CarName") or "Car")
	local reg = prof.cars[carName]
	if not reg then return end
	local opts, picks = {}, {}
	table.insert(opts, "Your registered plate (" .. reg.plate .. ")")
	table.insert(picks, { plate = reg.plate, own = true })
	for i, sp in prof.plates do
		table.insert(opts, ("%s - %s%s"):format(sp.plate, sp.kind, if sp.kind == "cold" then (" (made for a " .. string.lower(sp.colour or "") .. " " .. (sp.type or "car") .. ")") else ""))
		table.insert(picks, { plate = sp.plate, index = i })
	end
	table.insert(opts, "Cancel")
	local idx = Core.UI.ask(player, { title = "Change plates", body = ("On the car now: %s"):format(tostring(car:GetAttribute("Plate"))), options = opts, timeout = 30 })
	if not idx or idx > #picks then return end
	local pick = picks[idx]
	local old = car:GetAttribute("Plate")
	-- the plate coming off goes back in the bag (unless it's the registered one)
	if old and old ~= reg.plate then
		local r = P.lookup(old)
		table.insert(prof.plates, { plate = old, kind = if r and r.kind == "cold" then "cold" else "stolen", type = r and r.type, colour = r and r.colour })
	end
	if pick.index then table.remove(prof.plates, pick.index) end
	reg.fitted = if pick.own then nil else pick.plate
	car:SetAttribute("Plate", pick.plate)
	P.attachPlate(car, pick.plate)
	Core.Profile.dirty(player)
	Core.UI.notice(player, "Plates swapped: " .. pick.plate, 4)
	Core.log("Plates", "%s fitted %s to their %s", player.Name, pick.plate, carName)
	-- seen doing it?
	local r = Core.root(player)
	if r and not pick.own and P.copWatching(r.Position, 50) then
		Core.report(player, "PlateTheft", r.Position)
	end
end

-- any officer (AI or player) with line of sight within range?
function P.copWatching(pos: Vector3, range: number): boolean
	for _, m in Core.aiCops() do
		local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - pos).Magnitude < range then return true end
	end
	for _, p in Players:GetPlayers() do
		local r = Core.isLaw(p) and Core.root(p)
		if r and (r.Position - pos).Magnitude < range * 0.7 then return true end
	end
	return false
end

-- steal a plate off a parked car
function P.stealPlate(player: Player, car: Model)
	if Core.seatedCar(player) then return end
	local plate = P.ensure(car)
	if not plate then return end
	local ownerV = car:FindFirstChild("Owner")
	if ownerV and ownerV.Value == player then return end
	local rec = P.lookup(plate)
	local prof = Core.Profile.get(player)
	table.insert(prof.plates, { plate = plate, kind = "stolen", type = rec and rec.type, colour = rec and rec.colour })
	Core.Profile.dirty(player)
	if rec then rec.plateStolenAt = os.time() + math.random(CFG.StolenPlateReportDelay[1], CFG.StolenPlateReportDelay[2]) end
	-- the car now has no plate (a fresh one is issued to its owner)
	local part = car:FindFirstChild("LicensePlate")
	if part then part:Destroy() end
	car:SetAttribute("Plate", nil)
	if rec and rec.kind == "player" and rec.ownerId then
		local owner = Players:GetPlayerByUserId(rec.ownerId)
		if owner then
			local p2 = Core.Profile.get(owner)
			for name, reg in p2.cars do
				if reg.plate == plate then
					reg.plate = newPlate()
					reg.fitted = nil
					P.register({ plate = reg.plate, owner = owner.Name, ownerId = owner.UserId, kind = "player", type = name, colour = reg.colour, at = os.time() })
					car:SetAttribute("Plate", reg.plate)
					P.attachPlate(car, reg.plate)
					Core.UI.notice(owner, ("Someone stole the plate off your %s - the DMV issued %s"):format(name, reg.plate), 6)
				end
			end
			Core.Profile.dirty(owner)
		end
	end
	Core.UI.notice(player, "Took plate " .. plate .. " - fit it at your car (Change plates)", 5)
	Core.log("Plates", "%s stole plate %s", player.Name, plate)
	local r = Core.root(player)
	if r and P.copWatching(r.Position, 45) then Core.report(player, "PlateTheft", r.Position) end
	Core.emit("plateStolen", player, plate)
end

-- re-register (DMV counter): the record takes the car's current colour; a fitted plate
-- becomes your registered plate again
function P.reregister(player: Player): boolean
	local car = nil
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then
		for _, m in sp:GetChildren() do
			local o = m:FindFirstChild("Owner")
			if o and o.Value == player and not m:GetAttribute("StolenVehicle") then car = m end
		end
	end
	if not car then
		Core.UI.notice(player, "Bring your car out first (spawn it) - the clerk needs to see it", 5)
		return false
	end
	local prof = Core.Profile.get(player)
	local carName = tostring(car:GetAttribute("CarName") or "Car")
	local reg = prof.cars[carName]
	if not reg then return false end
	if not Core.chargeOrSay(player, CFG.ReRegisterFee, "re-registering your " .. carName) then return false end
	local old = reg.colour
	reg.colour = P.colourOf(car)
	reg.registeredAt = os.time()
	reg.reregisteredFrom = old
	Core.Profile.dirty(player)
	P.register({ plate = reg.plate, owner = player.Name, ownerId = player.UserId, kind = "player", type = carName, colour = reg.colour, at = reg.registeredAt })
	Core.UI.notice(player, ("%s re-registered: %s (was %s). It's in the log."):format(carName, reg.colour, old), 5)
	Core.log("Plates", "RE-REGISTER %s's %s %s -> %s", player.Name, carName, tostring(old), reg.colour)
	return true
end

---------------------------------------------------------------------------
-- checks (readers, stops, the MDT)
---------------------------------------------------------------------------
-- -> list of hits { kind, text, severity }
function P.check(car: Model, driver: Player?): { any }
	local hits = {}
	local plate = car:GetAttribute("Plate")
	local ctype, colour = P.typeOf(car), P.colourOf(car)
	if not plate then
		table.insert(hits, { kind = "noplate", text = ("%s %s with no plate"):format(colour, ctype), severity = 1 })
		return hits
	end
	local rec = P.lookup(plate)
	local now = os.time()
	if not rec then
		table.insert(hits, { kind = "unknown", text = ("plate %s not on file"):format(plate), severity = 1 })
		return hits
	end
	if rec.burned then
		table.insert(hits, { kind = "stolenplate", text = ("plate %s flagged - seen in a crime"):format(plate), severity = 2 })
	end
	if rec.stolenAt and now >= rec.stolenAt then
		table.insert(hits, { kind = "stolen", text = ("%s %s, plate %s - REPORTED STOLEN"):format(rec.colour, rec.type, plate), severity = 2 })
	end
	if rec.plateStolenAt and now >= rec.plateStolenAt then
		table.insert(hits, { kind = "stolenplate", text = ("plate %s reported stolen (registered to a %s %s)"):format(plate, string.lower(rec.colour or ""), rec.type or "car"), severity = 2 })
	elseif rec.type ~= ctype or string.lower(rec.colour or "") ~= string.lower(colour) then
		table.insert(hits, { kind = "mismatch", text = ("plate %s doesn't match vehicle: registered to a %s %s, on a %s %s"):format(plate,
			string.lower(rec.colour or "?"), rec.type or "?", string.lower(colour), ctype), severity = 1 })
	end
	if rec.kind == "player" and rec.ownerId then
		local owner = Players:GetPlayerByUserId(rec.ownerId)
		if owner then
			local w = Core.Warrants.active(owner)
			if w then
				table.insert(hits, { kind = "warrant", owner = owner, text = ("registered owner %s has an ACTIVE WARRANT: %s"):format(owner.Name, w.reason), severity = w.severity or 2 })
			end
			if driver == owner and Core.Licence and Core.Licence.suspended(owner) then
				table.insert(hits, { kind = "suspended", owner = owner, text = ("registered owner %s - licence SUSPENDED"):format(owner.Name), severity = 1 })
			end
		end
	end
	local b = Core.Warrants.boloForCar(ctype, colour, plate)
	if b then table.insert(hits, { kind = "bolo", bolo = b, text = "matches BOLO: " .. b.text, severity = 2 }) end
	return hits
end

-- the plate reader on one cruiser saw one car
local function readerHit(cruiser: Model, car: Model, driver: Player)
	local key = cruiser:GetDebugId() .. "|" .. car:GetDebugId()
	local now = os.clock()
	if hitAt[key] and now - hitAt[key] < CFG.HitCooldown then return end
	local hits = P.check(car, driver)
	if #hits == 0 then return end
	hitAt[key] = now
	local d = P.describe(car)
	local cop = Core.driver(cruiser)
	local copIsPlayer = cop ~= nil and Core.isLaw(cop)
	local pos = (car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart", true) :: BasePart).Position
	local lines = {}
	for _, h in hits do table.insert(lines, h.text) end
	local msg = ("ALPR hit: %s %s, plate %s - %s"):format(d.colour, d.type, tostring(d.plate), table.concat(lines, "; "))
	if copIsPlayer then
		Core.UI.notice(cop :: Player, msg, 8, Color3.fromRGB(20, 40, 90))
		Core.UI.waypoint(cop :: Player, "alpr", pos, "ALPR hit")
	end
	Core.radio(msg)
	Core.emit("alpr", car, driver, hits)
	-- a cold plate seen while its driver is wanted is burned
	local rec = P.lookup(d.plate)
	if rec and rec.kind == "cold" and Core.stars(driver) > 0 then rec.burned = true end
	-- AI cruisers act on it themselves; police players decide (they get the waypoint)
	if copIsPlayer or Core.inCustody(driver) then return end
	for _, h in hits do
		if h.kind == "warrant" and h.owner == driver then
			Core.Warrants.identify(driver, "ALPR", "a cruiser's plate reader")
			return
		end
	end
	for _, h in hits do
		if h.kind == "stolen" then Core.report(driver, "VehicleTheft", pos) return end
	end
	for _, h in hits do
		if h.kind == "bolo" and h.bolo.subjectId == driver.UserId then
			if Core.Warrants.active(driver) then Core.Warrants.identify(driver, "BOLO", "a cruiser") else Core.report(driver, "BOLOStop", pos, 10) end
			return
		end
	end
	for _, h in hits do
		if h.kind == "stolenplate" then Core.report(driver, "PlateTheft", pos) return end
		if h.kind == "suspended" then Core.report(driver, "DrivingSuspended", pos, 8) return end
	end
	-- mismatch / no plate: a stop (1 star - pull over and talk, or run)
	if Core.stars(driver) == 0 then Core.report(driver, "SuspiciousVehicle", pos, 8) end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function readers()
	local cars = {}
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then
		for _, car in sp:GetChildren() do
			if car:IsA("Model") then
				local d = Core.driver(car)
				if d and not Core.isLaw(d) then table.insert(cars, { car = car, driver = d }) end
			end
		end
	end
	if #cars == 0 then return end
	for _, cruiser in Core.cruisers() do
		local cp = cruiser.PrimaryPart or cruiser:FindFirstChildWhichIsA("BasePart", true)
		if not cp then continue end
		for _, c in cars do
			if c.car == cruiser then continue end
			local tp = c.car.PrimaryPart
			if not tp then continue end
			local dist = (tp.Position - cp.Position).Magnitude
			if dist <= CFG.ReaderRange then
				rayParams.FilterDescendantsInstances = { cruiser, c.car }
				local from = cp.Position + Vector3.new(0, 3, 0)
				local hit = workspace:Raycast(from, tp.Position + Vector3.new(0, 1, 0) - from, rayParams)
				if not hit or hit.Instance.Transparency > 0.5 then
					P.ensure(c.car)
					readerHit(cruiser, c.car, c.driver)
				end
			end
		end
	end
end

-- plate-steal prompts on parked cars (players' parked cars + stopped traffic)
local function addStealPrompt(car: Model)
	if car:FindFirstChild("PlateStealPrompt", true) then return end
	local plate = P.ensure(car)
	if not plate then return end
	local part = P.attachPlate(car, plate)
	if not part then return end
	local pr = Instance.new("ProximityPrompt")
	pr.Name = "PlateStealPrompt"
	pr.ActionText = "Steal plate"
	pr.ObjectText = "License plate"
	pr.HoldDuration = 3.5
	pr.MaxActivationDistance = 6
	pr.RequiresLineOfSight = false
	pr.KeyboardKeyCode = Enum.KeyCode.T
	pr.Style = Enum.ProximityPromptStyle.Default
	pr.Parent = part
	pr.Triggered:Connect(function(who: Player)
		if Core.isLaw(who) then return end
		if Core.driver(car) then return end
		P.stealPlate(who, car)
		pr:Destroy()
	end)
end

function P.init(core: any)
	Core = core
	local sp = workspace:FindFirstChild("SpawnedCars") or workspace:WaitForChild("SpawnedCars", 60)
	if sp then
		sp.ChildAdded:Connect(function(car)
			if car:IsA("Model") then
				task.spawn(onPlayerCar, car)
				task.delay(1, function()
					if car.Parent and not car:FindFirstChild("PlateStealPrompt", true) then
						local plate = car:GetAttribute("Plate")
						local part = car:FindFirstChild("LicensePlate")
						if plate and part then
							-- the steal prompt lives on every player car; the owner can't use it
							local pr = Instance.new("ProximityPrompt")
							pr.Name = "PlateStealPrompt"
							pr.ActionText = "Steal plate"
							pr.ObjectText = "License plate"
							pr.HoldDuration = 3.5
							pr.MaxActivationDistance = 6
							pr.RequiresLineOfSight = false
							pr.KeyboardKeyCode = Enum.KeyCode.T
							pr.Parent = part
							pr:SetAttribute("NotOwner", (car:FindFirstChild("Owner") :: any).Value and (car:FindFirstChild("Owner") :: any).Value.UserId or 0)
							pr.Triggered:Connect(function(who: Player)
								local o = car:FindFirstChild("Owner")
								if (o and o.Value == who) or Core.isLaw(who) or Core.driver(car) then return end
								P.stealPlate(who, car)
								pr:Destroy()
							end)
						end
					end
				end)
			end
		end)
		for _, car in sp:GetChildren() do task.spawn(onPlayerCar, car) end
	end
	-- traffic stopped by police / parked: a plate (and the steal prompt) appears
	task.spawn(function()
		while true do
			task.wait(3)
			for _, car in CollectionService:GetTagged("SmoothResidentTraffic") do
				if car:IsA("Model") and car.Parent and car:GetAttribute("PullOver") and not car:FindFirstChild("LicensePlate") then
					addStealPrompt(car)
				end
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(CFG.ReaderTick)
			local ok, err = pcall(readers)
			if not ok then warn("[Plates] reader: " .. tostring(err)) end
		end
	end)
	-- a carjacking (CarServer) reports the car stolen later: handled in ensure()
	Core.Plates = P
	print("[Plates] v262 ready (registration, plate readers, plate theft)")
end

return P
