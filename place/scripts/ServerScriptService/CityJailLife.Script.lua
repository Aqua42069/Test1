--[[
	CityJailLife (v290g) - the Clark County Detention Center (Workspace["City Jail"]) is lived in.

	  * INMATES in orange: a handful in the cafeteria (some sat eating at the tables), some out in
	    the yard, a few in the cell block - each keeps to their area (the FacilityMap zones) and
	    wanders it. Walk up and talk to one (prompt) and they say something back.
	  * DETENTION OFFICERS: one at the booking desk, one at the lobby, one walking the cell block.
	The cast is topped up if one is removed. Purely atmosphere: no player is touched by it.
	Logs: [JailLife]
]]

local Players = game:GetService("Players")

local JAIL_NAME = "City Jail"
local ORANGE = Color3.fromRGB(232, 112, 32)
local SKIN = { Color3.fromRGB(234, 192, 160), Color3.fromRGB(198, 146, 110), Color3.fromRGB(141, 95, 64), Color3.fromRGB(92, 60, 40) }

-- where the inmates are, and how many
local AREAS = {
	{ zone = "cafeteria", count = 6, sit = 3 },
	{ zone = "Prison_Yard", count = 5 },
	{ zone = "Cell_Block", count = 3 },
}
local OFFICERS = {
	{ name = "Detention Officer Ruiz", at = "BookingDesk_1" },
	{ name = "Detention Officer Park", zone = "City_Jail_Lobby" },
	{ name = "Detention Officer Haines", zone = "Cell_Block", patrol = true },
}

local LINES = {
	"What you in for?",
	"Don't look at me like that. I'm innocent. Ask anybody.",
	"Food's worse than the prison, and that's saying something.",
	"Thirty days for a parking ticket. Okay, a lot of parking tickets.",
	"My lawyer's a public defender. He's met me once. In the hallway.",
	"They're moving me up state next week. Pray for me.",
	"Keep your head down, do your time, don't owe nobody nothing.",
	"You got any commissary? No? Then keep walking.",
	"I was just holding it for a friend. The car, I mean.",
	"Court's Monday. Judge Voss. I'm already packing.",
	"Lights out at ten. Nobody sleeps though.",
	"The guy in cell four snores like a leaf blower.",
}
local OFFICER_LINES = {
	"Keep moving.",
	"Visiting hours are posted in the lobby.",
	"No contact with the inmates.",
	"Booking's through the sally port, not the front door.",
}

local jail = workspace:WaitForChild(JAIL_NAME, 60)
if not jail then
	warn("[JailLife] no " .. JAIL_NAME)
	return
end
local map = jail:WaitForChild("FacilityMap", 30)
local folder = Instance.new("Folder")
folder.Name = "JailLife"
folder.Parent = jail

-- a zone's polygon and floor
local function zoneOf(name: string): any
	local z = map and map:FindFirstChild("Zones") and map.Zones:FindFirstChild(name)
	if not z then return nil end
	local pts = {}
	local cp = z:FindFirstChild("ControlPoints")
	for _, p in (cp and cp:GetChildren() or {}) do
		if p:IsA("BasePart") then table.insert(pts, p.Position) end
	end
	if #pts < 3 then return nil end
	local mn, mx = pts[1], pts[1]
	for _, p in pts do mn, mx = mn:Min(p), mx:Max(p) end
	return { name = name, min = mn, max = mx, bottom = tonumber(z:GetAttribute("BottomY")) or mn.Y, poly = pts }
end
local function inPoly(poly: { Vector3 }, x: number, z: number): boolean
	local inside = false
	local j = #poly
	for i = 1, #poly do
		local a, b = poly[i], poly[j]
		if (a.Z > z) ~= (b.Z > z) and x < (b.X - a.X) * (z - a.Z) / (b.Z - a.Z) + a.X then inside = not inside end
		j = i
	end
	return inside
end
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { folder }
local function spotIn(z: any): Vector3?
	for _ = 1, 20 do
		local x = z.min.X + 5 + math.random() * math.max(1, z.max.X - z.min.X - 10)
		local zz = z.min.Z + 5 + math.random() * math.max(1, z.max.Z - z.min.Z - 10)
		if inPoly(z.poly, x, zz) then
			local hit = workspace:Raycast(Vector3.new(x, z.bottom + 6, zz), Vector3.new(0, -9, 0), rayParams)
			-- a floor near the zone's floor (not a table top, not a wall top)
			if hit and math.abs(hit.Position.Y - z.bottom) < 2 then return hit.Position end
		end
	end
	return nil
end

local function bubble(m: Model, text: string)
	local head = m:FindFirstChild("Head")
	if not head then return end
	local old = head:FindFirstChild("JailSpeech")
	if old then old:Destroy() end
	local b = Instance.new("BillboardGui")
	b.Name = "JailSpeech"
	b.Size = UDim2.fromOffset(260, 56)
	b.StudsOffset = Vector3.new(0, 2.8, 0)
	b.MaxDistance = 50
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Color3.new(1, 1, 1)
	t.BackgroundTransparency = 0.1
	t.TextColor3 = Color3.fromRGB(20, 20, 24)
	t.Font = Enum.Font.GothamMedium
	t.TextScaled = true
	t.Text = text
	Instance.new("UICorner").Parent = t
	t.Parent = b
	b.Parent = head
	task.delay(4, function() if b.Parent then b:Destroy() end end)
end

local inmateNo = 1040
local function person(name: string, top: Color3, legs: Color3, at: Vector3): Model?
	local ok, model = pcall(function()
		local d = Instance.new("HumanoidDescription")
		d.TorsoColor, d.LeftArmColor, d.RightArmColor = top, top, top
		d.LeftLegColor, d.RightLegColor = legs, legs
		d.HeadColor = SKIN[math.random(1, #SKIN)]
		return Players:CreateHumanoidModelFromDescription(d, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		warn("[JailLife] couldn't make " .. name .. ": " .. tostring(model))
		return nil
	end
	local m = model :: Model
	m.Name = name
	local h = m:FindFirstChildOfClass("Humanoid") :: Humanoid
	h.DisplayName = name
	h.NameDisplayDistance = 25
	h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	h.WalkSpeed = 6 + math.random() * 3
	m:PivotTo(CFrame.new(at + Vector3.new(0, 3, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
	m.Parent = folder
	return m
end
local function talkPrompt(m: Model, lines: { string }, label: string)
	local root = m:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "TalkPrompt"
	pp.ActionText = "Talk"
	pp.ObjectText = label
	pp.MaxActivationDistance = 9
	pp.RequiresLineOfSight = false
	pp.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	pp.KeyboardKeyCode = Enum.KeyCode.T
	pp.Parent = root
	pp.Triggered:Connect(function(player)
		local hum = m:FindFirstChildOfClass("Humanoid")
		local pr = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hum and pr then
			hum:MoveTo((root :: BasePart).Position) -- stop
			local r = root :: BasePart
			r.CFrame = CFrame.lookAt(r.Position, Vector3.new(pr.Position.X, r.Position.Y, pr.Position.Z))
		end
		bubble(m, lines[math.random(1, #lines)])
	end)
end

-- wander a zone: short walks to points in it, pauses, an occasional remark
local function wander(m: Model, z: any, chatty: number)
	task.spawn(function()
		local hum = m:FindFirstChildOfClass("Humanoid")
		while m.Parent and hum and hum.Health > 0 do
			if not hum.Sit then
				local goal = spotIn(z)
				if goal then
					hum:MoveTo(goal)
					local t0 = os.clock()
					while m.Parent and os.clock() - t0 < 8 do
						local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
						if not r or (r.Position - goal).Magnitude < 4 then break end
						task.wait(0.5)
					end
				end
				if math.random() < chatty then
					local lines = if m:GetAttribute("JailRole") == "officer" then OFFICER_LINES else LINES
					bubble(m, lines[math.random(1, #lines)])
				end
			end
			task.wait(4 + math.random() * 8)
		end
	end)
end

-- the cafeteria seats (chairs inside the zone)
local function seatsIn(z: any): { Seat }
	local out = {}
	for _, s in jail:GetDescendants() do
		if s:IsA("Seat") and not s.Occupant and inPoly(z.poly, s.Position.X, s.Position.Z) and math.abs(s.Position.Y - z.bottom) < 5 then
			table.insert(out, s)
		end
	end
	return out
end

local cast: { [Model]: any } = {}
local function spawnInmate(area: any, z: any, sitIn: Seat?)
	local at = spotIn(z)
	if not at then return end
	inmateNo += math.random(1, 9)
	local m = person(("Inmate #%d"):format(inmateNo), ORANGE, ORANGE, at)
	if not m then return end
	m:SetAttribute("JailRole", "inmate")
	cast[m] = area
	talkPrompt(m, LINES, "Inmate")
	local hum = m:FindFirstChildOfClass("Humanoid") :: Humanoid
	if sitIn then
		task.delay(1, function()
			if m.Parent and not sitIn.Occupant then
				m:PivotTo(sitIn.CFrame + Vector3.new(0, 2, 0))
				sitIn:Sit(hum)
			end
		end)
		-- they get up after a while and someone else sits down
		task.delay(60 + math.random() * 90, function()
			if m.Parent then hum.Sit = false; wander(m, z, 0.15) end
		end)
	else
		wander(m, z, 0.12)
	end
	hum.Died:Connect(function() task.delay(5, function() if m.Parent then m:Destroy() end end) end)
	m.AncestryChanged:Connect(function()
		if not m.Parent then
			cast[m] = nil
			task.delay(30, function() spawnInmate(area, z, nil) end) -- topped up
		end
	end)
end

task.wait(5)
local made = 0
for _, area in AREAS do
	local z = zoneOf(area.zone)
	if not z then
		warn("[JailLife] no zone " .. area.zone)
		continue
	end
	local seats = if area.sit then seatsIn(z) else {}
	for i = 1, area.count do
		spawnInmate(area, z, if area.sit and i <= area.sit then seats[i] else nil)
		made += 1
	end
end
for _, o in OFFICERS do
	local at: Vector3? = nil
	local z = if o.zone then zoneOf(o.zone) else nil
	if o.at then
		local p = map and map:FindFirstChild("Points") and map.Points:FindFirstChild(o.at)
		if p and p:IsA("BasePart") then
			local hit = workspace:Raycast(p.Position + Vector3.new(0, 2, 0), Vector3.new(0, -9, 0), rayParams)
			at = if hit then hit.Position else p.Position
		end
	elseif z then
		at = spotIn(z)
	end
	if at then
		local m = person(o.name, Color3.fromRGB(70, 82, 110), Color3.fromRGB(36, 40, 56), at)
		if m then
			m:SetAttribute("JailRole", "officer")
			talkPrompt(m, OFFICER_LINES, "Detention Officer")
			if o.patrol and z then wander(m, z, 0.05) end
			made += 1
		end
	end
end
print(("[JailLife] the detention center is open: %d people inside"):format(made))
