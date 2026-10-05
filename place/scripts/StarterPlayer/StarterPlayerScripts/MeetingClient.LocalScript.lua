-- MeetingClient (v257b): a lawyer's in-person meeting (LawFirms sets MeetingAt /
-- MeetingPlace / MeetingWith) - a marker over the office, a guide line from you to
-- it, and a countdown.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local anchor: Part? = nil
local beam: Beam? = nil
local fromAttach: Attachment? = nil
local label: TextLabel? = nil
local conn: RBXScriptConnection? = nil

local function clear()
	if conn then conn:Disconnect(); conn = nil end
	if anchor then anchor:Destroy(); anchor = nil end
	if fromAttach then fromAttach:Destroy(); fromAttach = nil end
	beam, label = nil, nil
end

local function show()
	clear()
	local place = player:GetAttribute("MeetingPlace")
	local due = tonumber(player:GetAttribute("MeetingAt"))
	if typeof(place) ~= "Vector3" or not due then
		return
	end
	local part = Instance.new("Part")
	part.Name = "LawyerMeeting"
	part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = place + Vector3.new(0, 4, 0)
	part.Parent = workspace
	anchor = part
	local toAttach = Instance.new("Attachment")
	toAttach.Parent = part
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(0, 220, 0, 50)
	gui.AlwaysOnTop = true
	gui.Parent = part
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(20, 30, 60)
	text.BackgroundTransparency = 0.2
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.Parent = gui
	label = text
	local b = Instance.new("Beam")
	b.Attachment1 = toAttach
	b.Width0, b.Width1 = 0.4, 0.4
	b.Color = ColorSequence.new(Color3.fromRGB(90, 160, 255))
	b.Transparency = NumberSequence.new(0.35)
	b.FaceCamera = true
	b.Parent = part
	beam = b
	conn = RunService.Heartbeat:Connect(function()
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and beam and (not fromAttach or fromAttach.Parent ~= root) then
			if fromAttach then fromAttach:Destroy() end
			fromAttach = Instance.new("Attachment")
			fromAttach.Parent = root
			beam.Attachment0 = fromAttach
		end
		if label then
			local left = due - workspace:GetServerTimeNow()
			local who = tostring(player:GetAttribute("MeetingWith") or "Lawyer")
			label.Text = if left > 0 then ("%s meeting\nin %d:%02d"):format(who, left // 60, math.floor(left % 60))
				else ("%s - you're LATE"):format(who)
		end
	end)
end

player:GetAttributeChangedSignal("MeetingPlace"):Connect(show)
player:GetAttributeChangedSignal("MeetingAt"):Connect(show)
show()
