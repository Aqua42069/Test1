-- CourtFeedClient (v290h): the live transcript of a trial (Court.feed -> ReplicatedStorage.CourtFeed).
-- Shown when you're in the courthouse, or - in a big case - to the whole city as Channel 8's live
-- coverage. The defendant never gets it (they have the cards). Hides itself after a quiet spell;
-- the button collapses it to the header.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("CourtFeed", 60)
if not (remote and remote:IsA("RemoteEvent")) then return end

local NEAR = 320 -- studs from the courtroom = in the building
local KEEP = 9 -- lines on screen
local QUIET = 60 -- seconds of silence before it hides

local gui = Instance.new("ScreenGui")
gui.Name = "CourtFeed"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.DisplayOrder = 4
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0, 1)
frame.Position = UDim2.new(0, 12, 1, -150)
frame.Size = UDim2.new(0, 360, 0, 230)
frame.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
frame.BackgroundTransparency = 0.18
frame.Visible = false
frame.Parent = gui
Instance.new("UICorner").Parent = frame
do
	local c = Instance.new("UISizeConstraint")
	c.MaxSize = Vector2.new(360, 230)
	c.Parent = frame
end

local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, -44, 0, 26)
header.Position = UDim2.fromOffset(10, 4)
header.BackgroundTransparency = 1
header.Font = Enum.Font.GothamBold
header.TextSize = 14
header.TextXAlignment = Enum.TextXAlignment.Left
header.TextTruncate = Enum.TextTruncate.AtEnd
header.TextColor3 = Color3.new(1, 1, 1)
header.Parent = frame

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.fromOffset(30, 22)
toggle.Position = UDim2.new(1, -36, 0, 6)
toggle.BackgroundColor3 = Color3.fromRGB(45, 47, 58)
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 14
toggle.Text = "-"
toggle.Parent = frame
Instance.new("UICorner").Parent = toggle

local list = Instance.new("Frame")
list.Position = UDim2.fromOffset(10, 32)
list.Size = UDim2.new(1, -20, 1, -40)
list.BackgroundTransparency = 1
list.ClipsDescendants = true
list.Parent = frame
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
layout.Padding = UDim.new(0, 3)
layout.Parent = list

local collapsed = false
toggle.Activated:Connect(function()
	collapsed = not collapsed
	toggle.Text = if collapsed then "+" else "-"
	list.Visible = not collapsed
	frame.Size = if collapsed then UDim2.new(0, 360, 0, 34) else UDim2.new(0, 360, 0, 230)
end)

local COLORS = {
	narration = Color3.fromRGB(150, 156, 172),
	choice = Color3.fromRGB(255, 214, 120), -- the defendant
	verdict = Color3.fromRGB(255, 120, 110),
	line = Color3.fromRGB(228, 230, 238),
}
local order = 0
local lastAt = 0
local current: string? = nil

local function add(speaker: string, text: string, kind: string)
	order += 1
	local l = Instance.new("TextLabel")
	l.LayoutOrder = order
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextWrapped = true
	l.RichText = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Font = if kind == "verdict" then Enum.Font.GothamBlack else Enum.Font.Gotham
	l.TextSize = 13
	l.TextColor3 = COLORS[kind] or COLORS.line
	local function esc(s: string): string
		return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
	end
	l.Text = if kind == "narration" or kind == "verdict" then esc(text) else ("<b>%s:</b> %s"):format(esc(speaker), esc(text))
	l.TextTransparency = 1
	l.Parent = list
	TweenService:Create(l, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
	local kids = {}
	for _, c in list:GetChildren() do if c:IsA("TextLabel") then table.insert(kids, c) end end
	table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	for i = 1, #kids - KEEP do kids[i]:Destroy() end
end

remote.OnClientEvent:Connect(function(p: any)
	if type(p) ~= "table" then return end
	-- (v291: in the case yourself - the case board has the room's log)
	local cr = player.PlayerGui:FindFirstChild("CourtRoom")
	if cr and cr:IsA("ScreenGui") and cr.Enabled then frame.Visible = false return end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local near = typeof(p.at) == "Vector3" and root ~= nil and (root.Position - p.at).Magnitude < NEAR
	if not (near or p.big) then return end
	if current ~= p.case then
		-- a different case: a fresh page
		current = p.case
		for _, c in list:GetChildren() do if c:IsA("TextLabel") then c:Destroy() end end
	end
	header.Text = (if near then "COURTROOM  |  " else "CHANNEL 8 LIVE  |  ") .. tostring(p.case)
	header.TextColor3 = if near then Color3.new(1, 1, 1) else Color3.fromRGB(255, 120, 110)
	for _, line in (if type(p.lines) == "table" then p.lines else {}) do
		add(tostring(p.speaker), tostring(line), tostring(p.kind))
	end
	frame.Visible = true
	lastAt = os.clock()
	local stamp = lastAt
	task.delay(if p.kind == "verdict" then 25 else QUIET, function()
		if lastAt == stamp then frame.Visible = false end
	end)
end)
