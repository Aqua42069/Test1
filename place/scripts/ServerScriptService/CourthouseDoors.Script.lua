--[[
	CourthouseDoors (v286v) - real doors in the Clark County Courthouse, and the bar.

	The courthouse (tools/build_courthouse.luau) was built with doorways and no doors. Every
	doorway the generator made has a pair of "<wall>Jamb" frame parts, one each side: this script
	finds those pairs at startup and hangs a door in each (one leaf up to 7 studs wide, a pair of
	leaves above that), plus the courtroom's public double doors (RearDoorCasing) and a swinging
	gate in the bar between the gallery and the well (BarNewel posts).
	The front entrance (FrontWallLow - its bronze leaves stand folded open) and the grand opening
	into the rotunda (VestibuleBack, 28 studs) stay open, as built.

	Doors open by themselves for anyone who walks up (players, the court NPCs, escorts), swing
	away from them, and close when the doorway is clear. PathfindingModifier PassThrough = the
	escort walks and NPC routes path straight through a closed door (it opens as they arrive).

	Also: the bar rail panels were built turned 90 degrees (running from the gallery to the bench
	instead of across the room) - they're turned the right way here.
	Logs: [CourthouseDoors]
]]

local TweenService = game:GetService("TweenService")

local building = workspace:WaitForChild("Courthouse", 60)
if not building then return end
task.wait(1) -- let the model finish streaming in

local SKIP = { FrontWallLowJamb = true, VestibuleBackJamb = true }
local OPEN_RADIUS = 7
local CLOSE_AFTER = 1.5
local SWING = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local folder = Instance.new("Folder")
folder.Name = "Doors"
folder.Parent = building

type Leaf = { part: BasePart, hinge: CFrame, offset: CFrame, mirror: boolean }
type Door = { centre: Vector3, normal: Vector3, leaves: { Leaf }, open: boolean, side: number, lastNear: number }
local doors: { Door } = {}

local WOOD = Color3.fromRGB(92, 60, 38)
local BRASS = Color3.fromRGB(181, 148, 72)

-- a door across the doorway: floor = the floor centre of the opening, along = unit along the wall
local function makeDoor(name: string, floor: Vector3, along: Vector3, width: number, height: number, gate: boolean?)
	local up = Vector3.yAxis
	along = Vector3.new(along.X, 0, along.Z).Unit
	local normal = along:Cross(up)
	local count = if width > 7 then 2 else 1
	local leafW = width / count - 0.1
	local h = height - 0.25
	local d: Door = { centre = floor + up * math.min(3, h / 2), normal = normal, leaves = {}, open = false, side = 1, lastNear = 0 }
	local model = Instance.new("Model")
	model.Name = name
	for i = 1, count do
		local mirror = i == 2
		local x = if mirror then -along else along
		local hingePos = floor + up * 0.12 + (if mirror then along else -along) * (width / 2)
		local hinge = CFrame.fromMatrix(hingePos, x, up)
		local offset = CFrame.new(leafW / 2, h / 2, 0)
		local p = Instance.new("Part")
		p.Name = if gate then "GateLeaf" else "DoorLeaf"
		p.Size = Vector3.new(leafW, h, if gate then 0.25 else 0.35)
		p.CFrame = hinge * offset
		p.Anchored = true
		p.CanCollide = true
		p.Material = Enum.Material.Wood
		p.Color = WOOD
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		local mod = Instance.new("PathfindingModifier")
		mod.PassThrough = true
		mod.Parent = p
		p.Parent = model
		if not gate then
			-- a brass push plate on each face, near the free edge
			for _, s in { 1, -1 } do
				local plate = Instance.new("Part")
				plate.Name = "PushPlate"
				plate.Size = Vector3.new(0.5, 1.6, 0.05)
				plate.CFrame = p.CFrame * CFrame.new(leafW / 2 - 0.6, 0, s * 0.2)
				plate.Anchored = true
				plate.CanCollide = false
				plate.CanQuery = false
				plate.Material = Enum.Material.Metal
				plate.Color = BRASS
				plate.Parent = model
				local w = Instance.new("WeldConstraint")
				w.Part0, w.Part1 = p, plate
				w.Parent = plate
				plate.Anchored = false
			end
		end
		table.insert(d.leaves, { part = p, hinge = hinge, offset = offset, mirror = mirror })
	end
	model.Parent = folder
	table.insert(doors, d)
end

local function swing(d: Door, open: boolean, side: number)
	d.open = open
	d.side = side
	for _, l in d.leaves do
		-- +90 about the hinge turns the leaf toward its own -Z; the mirrored leaf's Z is -normal
		local s = if l.mirror then -side else side
		local goal = if open then l.hinge * CFrame.Angles(0, math.rad(if s > 0 then 90 else -90), 0) * l.offset else l.hinge * l.offset
		l.part.CanCollide = not open
		TweenService:Create(l.part, SWING, { CFrame = goal }):Play()
	end
end

---------------------------------------------------------------------------
-- find the doorways
---------------------------------------------------------------------------
local jambs = {}
for _, p in building:GetDescendants() do
	if p:IsA("BasePart") and p.Name:sub(-4) == "Jamb" and not SKIP[p.Name] then table.insert(jambs, p) end
end
local used = {}
for _, a in jambs do
	if used[a] then continue end
	local along = if a.Size.X < a.Size.Z then a.CFrame.RightVector else a.CFrame.LookVector
	local best, bd = nil, math.huge
	for _, b in jambs do
		if b ~= a and not used[b] and b.Name == a.Name and math.abs(b.Position.Y - a.Position.Y) < 0.5 then
			local dv = b.Position - a.Position
			local ax = math.abs(dv:Dot(along))
			if (dv - along * dv:Dot(along)).Magnitude < 0.5 and ax > 2 and ax < 40 and ax < bd then best, bd = b, ax end
		end
	end
	if best then
		used[a], used[best] = true, true
		local width = bd - 0.7
		if width <= 16 then
			local c = (a.Position + best.Position) / 2
			makeDoor(a.Name:sub(1, -5) .. "Door", c - Vector3.new(0, a.Size.Y / 2, 0), (best.Position - a.Position).Unit, width, a.Size.Y)
		end
	end
end

-- the courtroom's public double doors (built with their own casings)
do
	local cs = {}
	for _, p in building:GetDescendants() do
		if p:IsA("BasePart") and p.Name == "RearDoorCasing" then table.insert(cs, p) end
	end
	local a, b, far = nil, nil, 0
	for i = 1, #cs do
		for j = i + 1, #cs do
			local dv = cs[j].Position - cs[i].Position
			local m = Vector3.new(dv.X, 0, dv.Z).Magnitude
			if m > far then a, b, far = cs[i], cs[j], m end
		end
	end
	if a and b and far > 4 then
		local dv = b.Position - a.Position
		local along = Vector3.new(dv.X, 0, dv.Z).Unit
		local mid = Vector3.zero
		for _, p in cs do mid += p.Position end
		mid /= #cs
		-- the casings are 0.8 wide: the opening is between their inner faces
		makeDoor("CourtroomDoors", Vector3.new(mid.X, a.Position.Y - a.Size.Y / 2, mid.Z), along, far - 0.8 - 0.8, a.Size.Y - 1)
	end
end

-- the bar: panels turned the right way, and the gate between the two newel posts
do
	local posts = {}
	for _, p in building:GetDescendants() do
		if p:IsA("BasePart") and p.Name == "BarNewel" then table.insert(posts, p) end
	end
	-- each panel must run the way the bar runs (newel to newel), measured in the WORLD - the
	-- panels are turned 90 degrees inside the model, so their own Size says the opposite
	if #posts == 2 then
		local dv = posts[2].Position - posts[1].Position
		local across = Vector3.new(dv.X, 0, dv.Z).Unit
		for _, n in { "BarRailN", "BarRailS" } do
			local r = building:FindFirstChild(n, true)
			if r and r:IsA("BasePart") then
				local longLocal = if r.Size.X >= r.Size.Z then Vector3.xAxis else Vector3.zAxis
				local longWorld = r.CFrame:VectorToWorldSpace(longLocal)
				if math.abs(longWorld:Dot(across)) < 0.7 then
					r.Size = Vector3.new(r.Size.Z, r.Size.Y, r.Size.X)
					print(("[CourthouseDoors] %s turned to run across the room"):format(n))
				end
			end
		end
	end
	if #posts == 2 then
		local a, b = posts[1], posts[2]
		local dv = b.Position - a.Position
		local gap = Vector3.new(dv.X, 0, dv.Z).Magnitude - math.min(a.Size.X, a.Size.Z)
		local c = (a.Position + b.Position) / 2
		makeDoor("BarGate", Vector3.new(c.X, a.Position.Y - a.Size.Y / 2, c.Z), dv, gap, a.Size.Y - 1, true)
	end
end
print(("[CourthouseDoors] %d doors hung"):format(#doors))

---------------------------------------------------------------------------
-- open for whoever walks up
---------------------------------------------------------------------------
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.FilterDescendantsInstances = { building }
while true do
	task.wait(0.2)
	local now = os.clock()
	for _, d in doors do
		local near, side = nil, d.side
		for _, part in workspace:GetPartBoundsInRadius(d.centre, OPEN_RADIUS, overlap) do
			if part.Name == "HumanoidRootPart" then
				local hum = part.Parent and part.Parent:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					near = part
					break
				end
			end
		end
		if near then
			d.lastNear = now
			if not d.open then
				-- swing away from whoever is coming through
				swing(d, true, if (near.Position - d.centre):Dot(d.normal) >= 0 then 1 else -1)
			end
		elseif d.open and now - d.lastNear > CLOSE_AFTER then
			swing(d, false, d.side)
		end
	end
end
