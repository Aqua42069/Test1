--[[
	HQDoors (v285) - doors for Police HQ (Workspace.PoliceStation). Built at server start from
	the measured doorways, then run by role:

	  public   the front entrance: automatic glass doors - open for anyone, but someone in
	           custody only gets through with an officer at their side
	  secure   everything behind the lobby counter (offices, the custody area, booking, interview,
	           legal visit, the video court, the sally port's inner doors): police, staff NPCs
	           (escorts, lawyers, judges) and escorted prisoners only
	  cell     the holding cells: barred sliding doors, same rule - a prisoner alone stays in
	  bars     a barred wall between booking and the cell corridor, with a barred gate
	  garage   the sally port's roll-up door: opens for police vehicles (AI or a police player
	           driving) and police on foot; nobody else
	Every door carries a PathfindingModifier (PassThrough) so escort routes go through doors.
	Logs: [HQDoors]
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local hq = workspace:WaitForChild("PoliceStation", 60)
if not hq then return end

local FLOOR = 1.05
local LAW = {
	["LVPD"] = true, ["SWAT"] = true, ["Federal Bureau of Investigation"] = true, ["U.S. Marshal Service"] = true,
	["USM"] = true, ["Secret Service"] = true, ["Homeland Security"] = true, ["Federal Protection Service"] = true,
	["Special Forces"] = true, ["Dept. of Justice"] = true, ["Prison Staff"] = true, ["National Security Agency"] = true,
	["Central Intelligence Agency"] = true, ["Chief of Police"] = true,
}

-- wall = "z" (the wall runs along X at this Z) or "x" (runs along Z at this X); a..b along the wall
local SPECS = {
	{ name = "FrontEntrance", wall = "z", at = 4, a = 264.5, b = 276, kind = "public" },
	{ name = "LobbySecure", wall = "z", at = 44, a = 266.5, b = 274, kind = "secure", sign = "AUTHORIZED PERSONNEL ONLY" },
	{ name = "Office1", wall = "z", at = 44, a = 228.5, b = 234, kind = "secure" },
	{ name = "Office3", wall = "z", at = 52, a = 236.5, b = 242, kind = "secure" },
	{ name = "Office6", wall = "z", at = 52, a = 310.5, b = 316, kind = "secure" },
	{ name = "Office3b", wall = "x", at = 262, a = 62.5, b = 68, kind = "secure" },
	{ name = "Office4", wall = "x", at = 262, a = 86.5, b = 92, kind = "secure" },
	{ name = "Office5", wall = "x", at = 270, a = 70.5, b = 76, kind = "secure" },
	{ name = "Office7", wall = "z", at = 100, a = 310.5, b = 316, kind = "secure" },
	{ name = "CustodyArea", wall = "z", at = 100, a = 262.5, b = 270, kind = "secure", sign = "CUSTODY - SECURE AREA" },
	{ name = "Booking", wall = "z", at = 108, a = 264.5, b = 276, kind = "secure" },
	{ name = "SallyInner", wall = "z", at = 108, a = 228.5, b = 236, kind = "secure" },
	{ name = "SallyBooking", wall = "x", at = 250, a = 120.5, b = 128, kind = "secure" },
	{ name = "BookingRear", wall = "z", at = 142, a = 268, b = 272.5, kind = "secure" },
	{ name = "CellCorridor", wall = "x", at = 290, a = 112.5, b = 138, kind = "bars", gateA = 122.5, gateB = 128.5 },
	{ name = "Interview1", wall = "x", at = 267, a = 147.5, b = 153, kind = "secure" },
	{ name = "Interview2", wall = "x", at = 267, a = 162.5, b = 168, kind = "secure" },
	{ name = "LegalVisit", wall = "x", at = 273, a = 147.5, b = 153, kind = "secure" },
	{ name = "VideoCourt", wall = "x", at = 273, a = 162.5, b = 168, kind = "secure" },
	{ name = "Cell1", wall = "x", at = 297, a = 120.5, b = 126, kind = "cell" },
	{ name = "Cell2", wall = "x", at = 297, a = 145.5, b = 150, kind = "cell" },
	{ name = "Cell3", wall = "x", at = 297, a = 161.5, b = 166, kind = "cell" },
	{ name = "SallyGarage", wall = "x", at = 214, a = 128.5, b = 152, kind = "garage" },
	-- v286f: the courthouse holding cells (barred gates between the posts; they used to be built
	-- permanently swung open). site = "court" builds them under Workspace.Courthouse.
	{ name = "CourtCellG1", site = "court", wall = "z", at = -1733, a = 1952.0, b = 1955.4, floor = 10.2, kind = "cell" },
	{ name = "CourtCellG2", site = "court", wall = "z", at = -1733, a = 1964.0, b = 1967.4, floor = 10.2, kind = "cell" },
	{ name = "CourtCellG3", site = "court", wall = "z", at = -1733, a = 1976.0, b = 1979.4, floor = 10.2, kind = "cell" },
	{ name = "CourtCellU1", site = "court", wall = "z", at = -1735, a = 1952.3, b = 1956.2, floor = 42.28, kind = "cell" },
	{ name = "CourtCellU2", site = "court", wall = "z", at = -1735, a = 1971.8, b = 1975.7, floor = 42.28, kind = "cell" },
}

local old = hq:FindFirstChild("Doors")
if old then old:Destroy() end
local folder = Instance.new("Folder")
folder.Name = "Doors"
folder.Parent = hq
-- v286f: the courthouse holding gates live with the courthouse; its swung-open decoration goes
local courthouse = workspace:WaitForChild("Courthouse", 30)
local courtFolder = Instance.new("Folder")
courtFolder.Name = "HoldingGates"
if courthouse then
	local oldG = courthouse:FindFirstChild("HoldingGates")
	if oldG then oldG:Destroy() end
	for _, m in courthouse:GetDescendants() do
		if m:IsA("Model") and m.Name == "CellGateOpen" then m:Destroy() end
	end
	courtFolder.Parent = courthouse
end

local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Include

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, colour: Color3, mat: Enum.Material, trans: number?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = mat
	p.Transparency = trans or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end
local function passThrough(p: BasePart)
	local m = Instance.new("PathfindingModifier")
	m.Label = "Door"
	m.PassThrough = true
	m.Parent = p
end

-- the height of the opening: up from the floor to the lintel / ceiling
local function openingHeight(center: Vector3): number
	local ex = { folder, courtFolder }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ex
	local h = workspace:Raycast(Vector3.new(center.X, center.Y + 1.5, center.Z), Vector3.new(0, 30, 0), params)
	if h then
		return math.clamp(h.Position.Y - center.Y, 6, 24)
	end
	return 10
end

type Door = { spec: any, panels: { { model: Model, closed: CFrame, open: CFrame } }, center: Vector3, along: Vector3, normal: Vector3,
	half: number, isOpen: boolean, lastWanted: number, value: NumberValue }
local doors: { Door } = {}

local STYLE = {
	public = { colour = Color3.fromRGB(150, 185, 205), mat = Enum.Material.Glass, trans = 0.45, frame = Color3.fromRGB(60, 62, 68) },
	secure = { colour = Color3.fromRGB(70, 82, 100), mat = Enum.Material.Metal, trans = 0, frame = Color3.fromRGB(40, 42, 48) },
	cell = { colour = Color3.fromRGB(80, 82, 88), mat = Enum.Material.Metal, trans = 0, frame = Color3.fromRGB(50, 52, 56) },
	bars = { colour = Color3.fromRGB(80, 82, 88), mat = Enum.Material.Metal, trans = 0, frame = Color3.fromRGB(50, 52, 56) },
	garage = { colour = Color3.fromRGB(190, 192, 196), mat = Enum.Material.CorrodedMetal, trans = 0, frame = Color3.fromRGB(70, 72, 76) },
}

-- a panel model: a solid slab, or a barred one (frame + bars)
local function panel(parent: Instance, name: string, width: number, height: number, cf: CFrame, style, barred: boolean, windowed: boolean): Model
	local m = Instance.new("Model")
	m.Name = name
	local slab
	if barred then
		-- an invisible blocker the size of the panel + visible bars and rails
		slab = part(m, "Blocker", Vector3.new(width, height, 0.3), cf, style.colour, Enum.Material.SmoothPlastic, 1)
		local n = math.max(2, math.floor(width / 0.75))
		for i = 0, n do
			local x = -width / 2 + i * (width / n)
			part(m, "Bar", Vector3.new(0.18, height, 0.18), cf * CFrame.new(x, 0, 0), style.colour, style.mat).CanCollide = false
		end
		for _, y in { -height / 2 + 0.2, 0, height / 2 - 0.2 } do
			part(m, "Rail", Vector3.new(width, 0.25, 0.3), cf * CFrame.new(0, y, 0), style.frame, Enum.Material.Metal).CanCollide = false
		end
	else
		slab = part(m, "Panel", Vector3.new(width, height, 0.35), cf, style.colour, style.mat, style.trans)
		if windowed then
			part(m, "Window", Vector3.new(math.min(1.6, width * 0.4), 1.6, 0.4), cf * CFrame.new(0, height * 0.18, 0), Color3.fromRGB(140, 170, 190), Enum.Material.Glass, 0.4).CanCollide = false
			part(m, "Handle", Vector3.new(0.15, 1, 0.55), cf * CFrame.new(width / 2 - 0.5, -height * 0.05, 0), Color3.fromRGB(200, 200, 205), Enum.Material.Metal).CanCollide = false
		end
	end
	m.PrimaryPart = slab
	passThrough(slab)
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") and p ~= slab then p.CanQuery = false end
	end
	m.Parent = parent
	return m
end

local function build(spec)
	local floorY = spec.floor or FLOOR -- v286f: per door (the courthouse cells are on two floors)
	local site = if spec.site == "court" then courtFolder else folder
	local style = STYLE[spec.kind]
	local along = if spec.wall == "z" then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
	local normal = if spec.wall == "z" then Vector3.new(0, 0, 1) else Vector3.new(1, 0, 0)
	local function point(t: number, y: number): Vector3
		if spec.wall == "z" then return Vector3.new(t, y, spec.at) end
		return Vector3.new(spec.at, y, t)
	end
	local a, b = spec.a, spec.b
	local mid = (a + b) / 2
	local width = b - a
	local center = point(mid, floorY)
	local height = openingHeight(center)
	if spec.kind == "garage" then height = math.min(height, 16) end
	local m = Instance.new("Model")
	m.Name = spec.name
	m.Parent = site
	local rot = CFrame.fromMatrix(Vector3.zero, along, Vector3.yAxis, along:Cross(Vector3.yAxis))
	local function at(t: number, y: number): CFrame
		return CFrame.new(point(t, y)) * rot
	end
	local d: Door = { spec = spec, panels = {}, center = center, along = along, normal = normal, half = width / 2, isOpen = false, lastWanted = 0, value = Instance.new("NumberValue") }
	if spec.kind == "bars" then
		-- the fixed barred wall either side of the gate
		for _, seg in { { a, spec.gateA }, { spec.gateB, b } } do
			local w = seg[2] - seg[1]
			if w > 0.3 then panel(m, "BarWall", w, height, at((seg[1] + seg[2]) / 2, floorY + height / 2), style, true, false) end
		end
		local gw = spec.gateB - spec.gateA
		local gc = (spec.gateA + spec.gateB) / 2
		local closed = at(gc, floorY + height / 2)
		local p = panel(m, "Gate", gw, height - 0.1, closed, style, true, false)
		table.insert(d.panels, { model = p, closed = closed, open = closed * CFrame.new(-gw * 0.95, 0, 0.35) })
		d.center = point(gc, floorY)
		d.half = gw / 2
	elseif spec.kind == "garage" then
		local closed = at(mid, floorY + height / 2)
		local p = panel(m, "RollUp", width, height, closed, style, false, false)
		-- ribs so it reads as a roll-up door
		for y = -height / 2 + 1, height / 2 - 0.5, 1.2 do
			local rib = part(p, "Rib", Vector3.new(width, 0.12, 0.45), closed * CFrame.new(0, y, 0), Color3.fromRGB(150, 152, 156), Enum.Material.Metal)
			rib.CanCollide = false
			rib.CanQuery = false
		end
		table.insert(d.panels, { model = p, closed = closed, open = closed * CFrame.new(0, height - 1.2, 0) })
		local sign = part(m, "Sign", Vector3.new(10, 1.6, 0.2), at(mid, floorY + height + 1.2) * CFrame.new(0, 0, -0.6), Color3.fromRGB(20, 40, 90), Enum.Material.SmoothPlastic)
		local g = Instance.new("SurfaceGui")
		g.Face = Enum.NormalId.Front
		g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		g.PixelsPerStud = 40
		g.Parent = sign
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromScale(1, 1)
		l.BackgroundTransparency = 1
		l.TextScaled = true
		l.Font = Enum.Font.GothamBold
		l.TextColor3 = Color3.new(1, 1, 1)
		l.Text = "POLICE VEHICLES ONLY"
		l.Parent = g
		local g2 = g:Clone()
		g2.Face = Enum.NormalId.Back
		g2.Parent = sign
	else
		local barred = spec.kind == "cell"
		local h2 = math.min(height, if spec.kind == "public" then 11 else 8.6)
		if width > 7 then
			-- double doors that part in the middle
			local w = width / 2
			for i, side in { -1, 1 } do
				local closed = at(mid + side * w / 2, floorY + h2 / 2)
				local p = panel(m, "Leaf" .. i, w, h2, closed, style, barred, spec.kind == "secure")
				table.insert(d.panels, { model = p, closed = closed, open = closed * CFrame.new(side * w * 0.95, 0, 0.3) })
			end
		else
			local closed = at(mid, floorY + h2 / 2)
			local p = panel(m, "Leaf", width, h2, closed, style, barred, spec.kind == "secure")
			table.insert(d.panels, { model = p, closed = closed, open = closed * CFrame.new(-width * 0.95, 0, 0.3) })
		end
		-- fill the gap above a door shorter than the opening
		if height - h2 > 0.4 then
			part(m, "Transom", Vector3.new(width, height - h2, 0.6), at(mid, floorY + h2 + (height - h2) / 2), style.frame, Enum.Material.SmoothPlastic)
		end
		if spec.sign then
			local sign = part(m, "Sign", Vector3.new(math.min(width, 8), 1.1, 0.15), at(mid, floorY + h2 + 0.75) * CFrame.new(0, 0, -0.45), Color3.fromRGB(150, 25, 25), Enum.Material.SmoothPlastic)
			sign.CanCollide = false
			for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
				local g = Instance.new("SurfaceGui")
				g.Face = face
				g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
				g.PixelsPerStud = 40
				g.Parent = sign
				local l = Instance.new("TextLabel")
				l.Size = UDim2.fromScale(1, 1)
				l.BackgroundTransparency = 1
				l.TextScaled = true
				l.Font = Enum.Font.GothamBold
				l.TextColor3 = Color3.new(1, 1, 1)
				l.Text = spec.sign
				l.Parent = g
			end
		end
	end
	d.value.Value = 0
	d.value.Changed:Connect(function(v)
		for _, pn in d.panels do
			if pn.model.Parent then pn.model:PivotTo(pn.closed:Lerp(pn.open, v)) end
		end
	end)
	table.insert(doors, d)
end

for _, spec in SPECS do
	local ok, err = pcall(build, spec)
	if not ok then warn("[HQDoors] " .. spec.name .. ": " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- who may open what
---------------------------------------------------------------------------
local function isLaw(p: Player): boolean
	if p:GetAttribute("Police") == true or p:GetAttribute("LawEnforcement") == true then return true end
	return p.Team ~= nil and LAW[p.Team.Name] == true
end
local function inCustody(p: Player): boolean
	return p:GetAttribute("PoliceCuffed") == true or p:GetAttribute("CustodyStage") ~= nil
		or (p:GetAttribute("CustodyPhase") ~= nil and p:GetAttribute("CustodyPhase") ~= "Escaped")
end

-- everyone around the building: { pos, role = "law" | "staffnpc" | "custody" | "public" }
local function people(): { any }
	local out = {}
	local npcs = {}
	for _, p in Players:GetPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		if r and h and h.Health > 0 then
			table.insert(out, { pos = (r :: BasePart).Position, player = p,
				-- v286c: a custody walk in progress (PoliceSystem hqWalk) is escorted, officer in view or not
				role = if isLaw(p) then "law" elseif p:GetAttribute("BeingEscorted") == true then "escorted" elseif inCustody(p) then "custody" else "public" })
		end
	end
	-- NPCs inside the HQ area: escorting officers, detectives, lawyers, the judge on the screen
	local box = workspace:GetPartBoundsInBox(CFrame.new(270, 8, 88), Vector3.new(170, 30, 210))
	local seen = {}
	for _, part in box do
		if part.Name == "HumanoidRootPart" then
			local m = part.Parent
			if m and not seen[m] and not Players:GetPlayerFromCharacter(m) then
				seen[m] = true
				local h = m:FindFirstChildOfClass("Humanoid")
				if h and h.Health > 0 then
					table.insert(npcs, part.Position)
					table.insert(out, { pos = part.Position, role = "staffnpc" })
				end
			end
		end
	end
	-- a prisoner with an officer (player or NPC) at their side is escorted
	for _, e in out do
		if e.role == "custody" then
			for _, o in out do
				if (o.role == "law" or o.role == "staffnpc") and (o.pos - e.pos).Magnitude < 14 then
					e.role = "escorted"
					break
				end
			end
		end
	end
	return out
end

local function policeVehicleNear(pos: Vector3, radius: number): boolean
	local pa = workspace:FindFirstChild("PoliceAI")
	local pv = pa and pa:FindFirstChild("Vehicles")
	if pv then
		for _, m in pv:GetChildren() do
			if m:IsA("Model") then
				local ok, cf = pcall(m.GetPivot, m)
				if ok and (Vector3.new(cf.Position.X, pos.Y, cf.Position.Z) - pos).Magnitude < radius then return true end
			end
		end
	end
	for _, p in Players:GetPlayers() do
		local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		local seat = h and h.SeatPart
		if seat and seat:IsA("VehicleSeat") and isLaw(p) and (Vector3.new(seat.Position.X, pos.Y, seat.Position.Z) - pos).Magnitude < radius then return true end
	end
	return false
end

local tweenInfo = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local garageInfo = TweenInfo.new(2.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local function setOpen(d: Door, open: boolean)
	if d.isOpen == open then return end
	d.isOpen = open
	TweenService:Create(d.value, if d.spec.kind == "garage" then garageInfo else tweenInfo, { Value = if open then 1 else 0 }):Play()
end

local function near(d: Door, pos: Vector3, reach: number): boolean
	local rel = pos - d.center
	if math.abs(rel.Y) > 9 then return false end
	local alongD = math.abs(rel:Dot(d.along))
	local across = math.abs(rel:Dot(d.normal))
	return alongD < d.half + 2 and across < reach
end

-- nobody gets crushed: someone standing in the doorway keeps it open
local function inDoorway(d: Door, list): boolean
	for _, e in list do
		if near(d, e.pos, 1.8) then return true end
	end
	return false
end

task.spawn(function()
	while true do
		task.wait(0.15)
		local list = people()
		local now = os.clock()
		for _, d in doors do
			local kind = d.spec.kind
			local want = false
			if kind == "garage" then
				want = policeVehicleNear(d.center, 34)
				if not want then
					for _, e in list do
						if e.player and e.player:GetAttribute("BeingEscorted") == true and (e.pos - d.center).Magnitude < 40 then want = true break end
						if (e.role == "law" or e.role == "staffnpc" or e.role == "escorted") and near(d, e.pos, 6) then want = true break end
					end
				end
			else
				local reach = if kind == "public" then 7 else 6
				for _, e in list do
					-- v286l: an escort walk in progress opens the doors around it first, so the route
					-- (worked out once, at the start) goes through open doorways
					if e.player and e.role == "escorted" and e.player:GetAttribute("BeingEscorted") == true and (e.pos - d.center).Magnitude < 40 then
						want = true
						break
					end
					if near(d, e.pos, reach) then
						if e.role == "law" or e.role == "staffnpc" or e.role == "escorted" then want = true break end
						if kind == "public" and e.role == "public" then want = true break end
					end
				end
			end
			if want then d.lastWanted = now end
			local hold = if kind == "garage" then 4 else 1.6
			if want then
				setOpen(d, true)
			elseif d.isOpen and now - d.lastWanted > hold and not inDoorway(d, list) then
				setOpen(d, false)
			end
		end
	end
end)

print(("[HQDoors] v285: %d door(s) built at Police HQ"):format(#doors))
