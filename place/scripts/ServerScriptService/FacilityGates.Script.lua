--!strict
-- FacilityGates (v245a): vehicle gates of every building mapped with the Facility
-- Mapper (<Building>.FacilityMap, DoorType "Gate"). The prison's own GATE1/GATE2
-- logic in PoliceSystem is left alone (CorrectionalFacility is skipped).
--
-- A gate opens by sliding its wide parts (panels + rails) sideways out of the
-- opening, half to each side, and closes again on its own. It opens for:
--   · police / staff cars (AI cruisers in the PoliceVehicle collision group, custody
--     transports, or a VehicleSeat driven by a law player)
--   · players in custody being walked through it (CustodySite attribute set)
-- Each gate also gets a "VehicleGateFront" attribute on its door marker: the ground
-- point on the road side, where a custody ride stops (or is teleported to).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local OPEN_RADIUS = 45 -- studs from the gate centre
local OPEN_SECONDS = 10
local SLIDE_TIME = 1.6
local LAW_WORDS = { "police", "swat", "sheriff", "officer", "trooper", "fbi", "correction", "staff", "guard" }

type Gate = {
	name: string,
	center: Vector3,
	leaves: { { part: BasePart, closed: CFrame, open: CFrame } },
	openUntil: number,
	isOpen: boolean,
	flag: BoolValue?,
}

local gates: { Gate } = {}

local function isLaw(player: Player): boolean
	if player:GetAttribute("Police") == true or player:GetAttribute("LawEnforcement") == true then
		return true
	end
	local team = player.Team
	if not team then
		return false
	end
	local n = string.lower(team.Name)
	for _, w in LAW_WORDS do
		if string.find(n, w, 1, true) then
			return true
		end
	end
	return false
end

-- the container holding the moving panels: the mapped object, or its parent when
-- that is itself a "...gate..." model (Workspace.City Jail.PrisonGates.Gate -> PrisonGates)
local function gateContainer(target: Instance): Instance
	local parent = target.Parent
	if parent and parent ~= workspace and string.find(string.lower(parent.Name), "gate", 1, true) then
		return parent
	end
	return target
end

local function buildGate(marker: Instance, target: Instance, facilityModel: Instance): Gate?
	local container = gateContainer(target)
	local parts: { BasePart } = {}
	for _, d in container:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	if container:IsA("BasePart") then
		table.insert(parts, container)
	end
	if #parts == 0 then
		return nil
	end
	-- horizontal extent of the whole gate decides its axis
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	local sumY = 0
	for _, p in parts do
		minX, maxX = math.min(minX, p.Position.X), math.max(maxX, p.Position.X)
		minZ, maxZ = math.min(minZ, p.Position.Z), math.max(maxZ, p.Position.Z)
		sumY += p.Position.Y
	end
	local axis = if (maxX - minX) >= (maxZ - minZ) then Vector3.xAxis else Vector3.zAxis
	local center = Vector3.new((minX + maxX) / 2, sumY / #parts, (minZ + maxZ) / 2)
	local halfSpan = (if axis == Vector3.xAxis then maxX - minX else maxZ - minZ) / 2
	local leaves = {}
	for _, p in parts do
		local cf = p.CFrame
		local extent = math.abs(cf.RightVector:Dot(axis)) * p.Size.X
			+ math.abs(cf.UpVector:Dot(axis)) * p.Size.Y
			+ math.abs(cf.LookVector:Dot(axis)) * p.Size.Z
		local offset = (p.Position - center):Dot(axis)
		-- panels and rails slide, and so does anything inside the opening (the posts
		-- where the two leaves meet); only the outer frame posts stay
		if extent > 4 or math.abs(offset) < halfSpan - 3 then
			local side = if offset >= 0 then 1 else -1
			table.insert(leaves, { part = p, closed = cf, open = cf + axis * side * (halfSpan + 0.5) })
		end
	end
	if #leaves == 0 then
		return nil
	end
	-- road side: away from the building's centre, on the ground
	local normal = Vector3.new(axis.Z, 0, axis.X)
	local mcf = (facilityModel :: Model):GetBoundingBox()
	if (center - mcf.Position):Dot(normal) < 0 then
		normal = -normal
	end
	local front = center + normal * 22
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { container }
	local hit = workspace:Raycast(front + Vector3.new(0, 30, 0), Vector3.new(0, -120, 0), params)
	front = if hit then hit.Position else Vector3.new(front.X, center.Y - 15, front.Z)
	marker:SetAttribute("VehicleGateFront", front)
	marker:SetAttribute("VehicleGateCenter", center)
	local flag = container:FindFirstChild("Open")
	return {
		name = container:GetFullName(),
		center = center,
		leaves = leaves,
		openUntil = 0,
		isOpen = false,
		flag = if flag and flag:IsA("BoolValue") then flag else nil,
	}
end

local function slide(g: Gate, open: boolean)
	g.isOpen = open
	if g.flag then
		g.flag.Value = open
	end
	for _, l in g.leaves do
		TweenService:Create(l.part, TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ CFrame = if open then l.open else l.closed }):Play()
	end
	print(("[FacilityGates] %s %s"):format(if open then "OPEN" else "CLOSED", g.name))
end

local function openGate(g: Gate, secs: number)
	g.openUntil = math.max(g.openUntil, os.clock() + secs)
	if not g.isOpen then
		slide(g, true)
	end
end

local function scan()
	table.clear(gates)
	for _, model in workspace:GetChildren() do
		local map = model:FindFirstChild("FacilityMap")
		local doors = map and map:FindFirstChild("DoorMarkers")
		if doors and model.Name ~= "CorrectionalFacility" then
			for _, marker in doors:GetChildren() do
				local ov = marker:FindFirstChild("DoorObject")
				local target = ov and ov:IsA("ObjectValue") and ov.Value
				local dtype = tostring(marker:GetAttribute("DoorType") or "")
				if target and (dtype == "Gate" or dtype == "VehicleGate") then
					local ok, g = pcall(buildGate, marker, target, model)
					if ok and g then
						table.insert(gates, g)
						print(("[FacilityGates] %s: %d sliding parts, road side %s"):format(g.name, #g.leaves,
							tostring(marker:GetAttribute("VehicleGateFront"))))
					elseif not ok then
						warn("[FacilityGates] " .. marker:GetFullName() .. ": " .. tostring(g))
					end
				end
			end
		end
	end
end

local function wantsOpen(g: Gate): boolean
	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInRadius(g.center, OPEN_RADIUS)
	end)
	if ok then
		for _, part in parts do
			if part.CollisionGroup == "PoliceVehicle" then
				return true
			end
			local car = part:FindFirstAncestorWhichIsA("Model")
			if car and car:GetAttribute("CustodyTransport") == true then
				return true
			end
			if part:IsA("VehicleSeat") then
				local occ = part.Occupant
				local driver = occ and Players:GetPlayerFromCharacter(occ.Parent)
				if driver and isLaw(driver) then
					return true
				end
			end
		end
	end
	for _, p in Players:GetPlayers() do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root and p:GetAttribute("CustodySite") ~= nil and ((root :: BasePart).Position - g.center).Magnitude < 30 then
			return true
		end
	end
	return false
end

-- PoliceSystem (custody) can open a gate directly
local bindable = Instance.new("BindableFunction")
bindable.Name = "OpenFacilityGates"
bindable.OnInvoke = function(near: Vector3, radius: number?, secs: number?): number
	local n = 0
	for _, g in gates do
		if (g.center - near).Magnitude <= (radius or 80) then
			openGate(g, secs or OPEN_SECONDS)
			n += 1
		end
	end
	return n
end
bindable.Parent = script

task.wait(3) -- let the place settle
scan()
while true do
	for _, g in gates do
		if wantsOpen(g) then
			openGate(g, OPEN_SECONDS)
		elseif g.isOpen and os.clock() > g.openUntil then
			slide(g, false)
		end
	end
	task.wait(0.4)
end
