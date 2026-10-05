-- OneWayGlassClient (v290): one-way glass for the Premier Counsel building. The server keeps the
-- exterior glass (parts tagged with the "OneWayGlass" attribute) a dark mirror tint, so from
-- outside you can't see in. While your camera is inside the building, this turns that glass
-- see-through on your screen only, so you can see out.
local Players = game:GetService("Players")

local building = workspace:WaitForChild("PremierCounsel", 120)
if not building then return end
local player = Players.LocalPlayer

local SEE_THROUGH = 0.8 -- LocalTransparencyModifier while inside

-- the glass, and the region it encloses (the tower plus the lobby glass, in the tower's frame)
local panes: { BasePart } = {}
local frame: CFrame, lo: Vector3, hi: Vector3
local function scan()
	table.clear(panes)
	for _, p in building:GetDescendants() do
		if p:IsA("BasePart") and p:GetAttribute("OneWayGlass") then table.insert(panes, p) end
	end
	local tower = building:FindFirstChild("Tower")
	local cf, size
	if tower and tower:IsA("Model") then cf, size = tower:GetBoundingBox() else cf, size = building:GetBoundingBox() end
	frame = cf
	lo, hi = -size / 2, size / 2
	-- stretch the region to take in every pane (the lobby glass can sit outside the tower's box)
	for _, p in panes do
		local half = p.Size / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local c = frame:PointToObjectSpace(p.CFrame:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)))
					lo = Vector3.new(math.min(lo.X, c.X), math.min(lo.Y, c.Y), math.min(lo.Z, c.Z))
					hi = Vector3.new(math.max(hi.X, c.X), math.max(hi.Y, c.Y), math.max(hi.Z, c.Z))
				end
			end
		end
	end
end

local function inside(pos: Vector3): boolean
	local c = frame:PointToObjectSpace(pos)
	return c.X > lo.X + 0.5 and c.X < hi.X - 0.5 and c.Y > lo.Y and c.Y < hi.Y and c.Z > lo.Z + 0.5 and c.Z < hi.Z - 0.5
end

task.wait(3) -- the server tags the glass when its script starts
scan()
if #panes == 0 then
	task.wait(10)
	scan()
end

local was: boolean? = nil
while true do
	local cam = workspace.CurrentCamera
	if cam and frame then
		local now = inside(cam.CFrame.Position)
		if now ~= was then
			was = now
			for _, p in panes do
				if p.Parent then p.LocalTransparencyModifier = if now then SEE_THROUGH else 0 end
			end
		end
	end
	task.wait(0.2)
end
