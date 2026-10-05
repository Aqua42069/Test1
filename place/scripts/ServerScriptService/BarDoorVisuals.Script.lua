--[[
	BarDoorVisuals (v288j) - the sliding bar doors in the prison (solitary, overflow and long-term
	holding: CorrectionalFacility ... Bars.door.Door, 22 of them) are UnionOperations whose mesh
	no longer renders - they still collide and slide, but players saw an empty doorway.
	Each one gets real bars: a steel frame and vertical rods, welded to the door so they slide
	with it. The union stays the collider; it's left as it is.
]]

local facility = workspace:WaitForChild("CorrectionalFacility", 60)
if not facility then return end
task.wait(2)

local STEEL = Color3.fromRGB(70, 72, 78)

local function bar(door: BasePart, size: Vector3, offset: CFrame)
	local p = Instance.new("Part")
	p.Name = "BarVisual"
	p.Size = size
	p.CFrame = door.CFrame * offset
	p.Color = STEEL
	p.Material = Enum.Material.Metal
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local w = Instance.new("WeldConstraint")
	w.Part0 = door
	w.Part1 = p
	w.Parent = p
	p.Parent = door
end

local n = 0
for _, d in facility:GetDescendants() do
	if d:IsA("UnionOperation") and d.Name == "Door" and d.Parent and d.Parent.Name == "door"
		and d.Parent.Parent and d.Parent.Parent.Name == "Bars" and not d:FindFirstChild("BarVisual") then
		local w, h, t = d.Size.X, d.Size.Y, d.Size.Z
		-- the frame: top, bottom, both stiles, a mid rail
		bar(d, Vector3.new(w, 0.3, t + 0.1), CFrame.new(0, h / 2 - 0.15, 0))
		bar(d, Vector3.new(w, 0.3, t + 0.1), CFrame.new(0, -h / 2 + 0.15, 0))
		bar(d, Vector3.new(w, 0.25, t + 0.1), CFrame.new(0, -h / 2 + h * 0.45, 0))
		for _, s in { -1, 1 } do bar(d, Vector3.new(0.3, h, t + 0.1), CFrame.new(s * (w / 2 - 0.15), 0, 0)) end
		-- the rods
		local rods = math.max(3, math.floor(w / 0.55))
		for i = 1, rods - 1 do
			local x = -w / 2 + i * w / rods
			bar(d, Vector3.new(0.14, h - 0.4, 0.14), CFrame.new(x, 0, 0))
		end
		n += 1
	end
end
print(("[BarDoorVisuals] bars added to %d sliding doors"):format(n))
