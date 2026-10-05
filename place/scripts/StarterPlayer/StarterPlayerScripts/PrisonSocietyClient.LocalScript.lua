-- PrisonSocietyClient (v211)
--   * Fist fighting: left click (or the PUNCH button on touch screens) with
--     no tool out throws a punch (server: PrisonSociety).
--   * Dialogue box when an inmate talks to you / you talk to them.
--   * Crew respect panel while you're an inmate.
--   * Short notices ("Iron Syndicate -12 respect (hit a member)").

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()

local folder = ReplicatedStorage:WaitForChild("PrisonSociety")
local DialogueRE = folder:WaitForChild("Dialogue") :: RemoteEvent
local PunchRE = folder:WaitForChild("Punch") :: RemoteEvent
local NoticeRE = folder:WaitForChild("Notice") :: RemoteEvent
local gangInfo = folder:WaitForChild("Gangs")

local function isMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function corner(parent: Instance, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = parent
end

local gui = Instance.new("ScreenGui")
gui.Name = "PrisonSocietyGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.DisplayOrder = 20
gui.Parent = playerGui

---------------------------------------------------------------------------
-- punching
---------------------------------------------------------------------------
local function canPunch(): boolean
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum or hum.Health <= 0 or hum.Sit then
		return false
	end
	if char:FindFirstChildOfClass("Tool") then
		return false
	end
	return true
end

local function clickingSomething(): boolean
	-- don't punch the air when clicking a button in the world
	local target = mouse.Target
	local node: Instance? = target
	for _ = 1, 3 do
		if not node then
			break
		end
		if node:FindFirstChildOfClass("ClickDetector") then
			return true
		end
		node = node.Parent
	end
	return false
end

local function whyNoPunch(): string?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum or hum.Health <= 0 then
		return "You're down"
	end
	if hum.Sit then
		return "Stand up to fight"
	end
	if char:FindFirstChildOfClass("Tool") then
		return "Put your item away to use your fists"
	end
	return nil
end

-- v227: the punch shows on your own screen right away (the button flashes and a
-- hit marker says whether you connected) instead of silently doing nothing
local hitMarker = Instance.new("TextLabel")
hitMarker.Name = "PunchMarker"
hitMarker.AnchorPoint = Vector2.new(0.5, 0.5)
hitMarker.Position = UDim2.new(0.5, 0, 0.42, 0)
hitMarker.Size = UDim2.fromOffset(320, 30)
hitMarker.BackgroundTransparency = 1
hitMarker.Font = Enum.Font.GothamBlack
hitMarker.TextSize = 20
hitMarker.TextStrokeTransparency = 0.4
hitMarker.TextColor3 = Color3.new(1, 1, 1)
hitMarker.Text = ""
hitMarker.Visible = false
hitMarker.Parent = gui
local markerSerial = 0
local function flashMarker(text: string, color: Color3)
	markerSerial += 1
	local mine = markerSerial
	hitMarker.Text = text
	hitMarker.TextColor3 = color
	hitMarker.Visible = true
	task.delay(0.7, function()
		if markerSerial == mine then
			hitMarker.Visible = false
		end
	end)
end

local punchButton: TextButton -- forward
local lastPunch = 0
local function punch()
	if os.clock() - lastPunch < 0.45 then
		return
	end
	local why = whyNoPunch()
	if why then
		flashMarker(why, Color3.fromRGB(255, 200, 90))
		return
	end
	lastPunch = os.clock()
	if punchButton then
		punchButton.BackgroundColor3 = Color3.fromRGB(230, 70, 70)
		task.delay(0.15, function()
			punchButton.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
		end)
	end
	PunchRE:FireServer()
end

PunchRE.OnClientEvent:Connect(function(kind, a, hp, maxHp)
	if kind == "hit" then
		local pct = if typeof(hp) == "number" and typeof(maxHp) == "number" and maxHp > 0
			then math.floor(math.max(0, hp) / maxHp * 100 + 0.5)
			else nil
		flashMarker(
			if pct then ("HIT  %s  (%d%%)"):format(tostring(a), pct) else "HIT",
			Color3.fromRGB(255, 90, 90)
		)
	elseif kind == "miss" then
		flashMarker("miss", Color3.fromRGB(200, 200, 200))
	elseif kind == "blocked" then
		flashMarker(tostring(a), Color3.fromRGB(255, 200, 90))
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not clickingSomething() then
		punch()
	elseif input.KeyCode == Enum.KeyCode.F and player:GetAttribute("SentenceEnd") then
		punch() -- v226: F punches while you're an inmate
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		punch()
	end
end)

punchButton = Instance.new("TextButton")
punchButton.Name = "PunchButton"
punchButton.AnchorPoint = Vector2.new(1, 1)
punchButton.Position = UDim2.new(1, -110, 1, -150)
punchButton.Size = UDim2.fromOffset(64, 64)
punchButton.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
punchButton.BackgroundTransparency = 0.2
punchButton.TextColor3 = Color3.new(1, 1, 1)
punchButton.Font = Enum.Font.GothamBlack
punchButton.TextSize = 13
punchButton.Text = "PUNCH"
punchButton.Visible = false
punchButton.Parent = gui
corner(punchButton, 32)
punchButton.ZIndex = 5
punchButton.Active = true
punchButton.AutoButtonColor = true
-- v227: fire on press (Activated can be swallowed when the thumb drifts off the button)
punchButton.MouseButton1Down:Connect(punch)
punchButton.TouchTap:Connect(punch)

---------------------------------------------------------------------------
-- notices
---------------------------------------------------------------------------
local noticeList = Instance.new("Frame")
noticeList.Name = "Notices"
noticeList.AnchorPoint = Vector2.new(0.5, 0)
noticeList.Position = UDim2.new(0.5, 0, 0, 56)
noticeList.Size = UDim2.new(0.5, 0, 0, 120)
noticeList.BackgroundTransparency = 1
noticeList.Parent = gui
local noticeLayout = Instance.new("UIListLayout")
noticeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
noticeLayout.Padding = UDim.new(0, 4)
noticeLayout.Parent = noticeList

NoticeRE.OnClientEvent:Connect(function(text)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 26)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.fromRGB(240, 240, 240)
	label.Font = Enum.Font.GothamMedium
	label.TextScaled = true
	label.Text = tostring(text)
	label.Parent = noticeList
	corner(label, 6)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 16
	limit.Parent = label
	task.delay(3.5, function()
		label:Destroy()
	end)
	local shown = noticeList:GetChildren()
	local labels = 0
	for _, c in shown do
		if c:IsA("TextLabel") then
			labels += 1
		end
	end
	if labels > 4 then
		for _, c in shown do
			if c:IsA("TextLabel") and c ~= label then
				c:Destroy()
				break
			end
		end
	end
end)

---------------------------------------------------------------------------
-- crew respect panel
---------------------------------------------------------------------------
local panel = Instance.new("Frame")
panel.Name = "CrewRespect"
panel.AnchorPoint = Vector2.new(0, 0.5)
panel.Position = UDim2.new(0, 10, 0.42, 0)
panel.Size = UDim2.fromOffset(190, 30)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
panel.BackgroundTransparency = 0.25
panel.Visible = false
panel.Parent = gui
corner(panel, 8)
local panelPad = Instance.new("UIPadding")
panelPad.PaddingTop = UDim.new(0, 6)
panelPad.PaddingBottom = UDim.new(0, 6)
panelPad.PaddingLeft = UDim.new(0, 8)
panelPad.PaddingRight = UDim.new(0, 8)
panelPad.Parent = panel
local panelLayout = Instance.new("UIListLayout")
panelLayout.Padding = UDim.new(0, 4)
panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
panelLayout.Parent = panel

local header = Instance.new("TextButton")
header.Size = UDim2.new(1, 0, 0, 18)
header.BackgroundTransparency = 1
header.TextColor3 = Color3.fromRGB(230, 230, 230)
header.Font = Enum.Font.GothamBold
header.TextSize = 14
header.TextXAlignment = Enum.TextXAlignment.Left
header.Text = "Crew respect  ▾"
header.LayoutOrder = 0
header.Parent = panel

type Row = { frame: Frame, fill: Frame, value: TextLabel, key: string }
local rows: { Row } = {}
local collapsed = false

local function makeRow(labelText: string, color: Color3, key: string, order: number)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 30)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = panel
	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(0.75, 0, 0, 14)
	name.BackgroundTransparency = 1
	name.TextColor3 = Color3.fromRGB(215, 215, 215)
	name.Font = Enum.Font.GothamMedium
	name.TextSize = 12
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = labelText
	name.Parent = row
	local swatch = Instance.new("Frame")
	swatch.AnchorPoint = Vector2.new(1, 0)
	swatch.Position = UDim2.new(1, 0, 0, 1)
	swatch.Size = UDim2.fromOffset(18, 10)
	swatch.BackgroundColor3 = color
	swatch.BorderSizePixel = 0
	swatch.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(200, 200, 200)
	stroke.Thickness = 1
	stroke.Parent = swatch
	local bar = Instance.new("Frame")
	bar.Position = UDim2.new(0, 0, 0, 17)
	bar.Size = UDim2.new(0.78, 0, 0, 9)
	bar.BackgroundColor3 = Color3.fromRGB(55, 55, 60)
	bar.BorderSizePixel = 0
	bar.Parent = row
	corner(bar, 4)
	local mid = Instance.new("Frame")
	mid.AnchorPoint = Vector2.new(0.5, 0)
	mid.Position = UDim2.new(0.5, 0, 0, 0)
	mid.Size = UDim2.new(0, 1, 1, 0)
	mid.BackgroundColor3 = Color3.fromRGB(150, 150, 150)
	mid.BorderSizePixel = 0
	mid.ZIndex = 3
	mid.Parent = bar
	local fill = Instance.new("Frame")
	fill.BorderSizePixel = 0
	fill.ZIndex = 2
	fill.Parent = bar
	corner(fill, 4)
	local value = Instance.new("TextLabel")
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, 0, 0, 14)
	value.Size = UDim2.new(0.2, 0, 0, 14)
	value.BackgroundTransparency = 1
	value.TextColor3 = Color3.fromRGB(230, 230, 230)
	value.Font = Enum.Font.GothamBold
	value.TextSize = 12
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row
	table.insert(rows, { frame = row, fill = fill, value = value, key = key })
end
for _, v in gangInfo:GetChildren() do
	if v:IsA("Color3Value") then
		makeRow(tostring(v:GetAttribute("GangName") or v.Name), v.Value, v.Name, tonumber(v:GetAttribute("Order")) or 9)
	end
end
-- v226: what the correctional officers think of you
makeRow("Correctional Officers", Color3.fromRGB(70, 130, 220), "CO", 99)

local function refreshPanel()
	local inmate = player:GetAttribute("CustodyOwner") == "INCARCERATED"
	panel.Visible = inmate
	local mine = player:GetAttribute("PrisonGang")
	for _, r in rows do
		r.frame.Visible = not collapsed
		local rep = tonumber(player:GetAttribute(if r.key == "CO" then "CORespect" else "Rep_" .. r.key)) or 0
		local frac = math.abs(rep) / 100 * 0.5
		if rep >= 0 then
			r.fill.Position = UDim2.new(0.5, 0, 0, 0)
		else
			r.fill.Position = UDim2.new(0.5 - frac, 0, 0, 0)
		end
		r.fill.Size = UDim2.new(frac, 0, 1, 0)
		r.fill.BackgroundColor3 = if rep >= 25 then Color3.fromRGB(70, 190, 90)
			elseif rep <= -40 then Color3.fromRGB(215, 50, 50)
			elseif rep < 0 then Color3.fromRGB(220, 150, 50)
			else Color3.fromRGB(170, 170, 170)
		r.value.Text = (if mine == r.key then "★ " else "") .. tostring(rep)
	end
	header.Text = "Respect  " .. (if collapsed then "▸" else "▾")
end

header.Activated:Connect(function()
	collapsed = not collapsed
	refreshPanel()
end)

-- v229: the prison's mood (how close it is to a riot) and a riot banner
local mood = Instance.new("TextLabel")
mood.Name = "PrisonMood"
mood.Size = UDim2.new(1, 0, 0, 30)
mood.BackgroundTransparency = 1
mood.Font = Enum.Font.GothamBold
mood.TextSize = 12
mood.TextWrapped = true
mood.TextXAlignment = Enum.TextXAlignment.Left
mood.LayoutOrder = 100
mood.Parent = panel

local banner = Instance.new("TextLabel")
banner.Name = "RiotBanner"
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.new(0.5, 0, 0, 12)
banner.Size = UDim2.new(0.8, 0, 0, 40)
banner.BackgroundColor3 = Color3.fromRGB(150, 15, 15)
banner.BackgroundTransparency = 0.15
banner.TextColor3 = Color3.new(1, 1, 1)
banner.Font = Enum.Font.GothamBlack
banner.TextScaled = true
banner.Text = "RIOT IN PROGRESS"
banner.Visible = false
banner.Parent = gui
corner(banner, 8)
local bannerMax = Instance.new("UISizeConstraint")
bannerMax.MaxSize = Vector2.new(560, 40)
bannerMax.Parent = banner
local bannerText = Instance.new("UITextSizeConstraint")
bannerText.MaxTextSize = 22
bannerText.Parent = banner

local function refreshMood()
	local t = tonumber(folder:GetAttribute("PrisonTension")) or 0
	local co = tonumber(folder:GetAttribute("COAnger")) or 0
	local gang = 0
	for _, k in { "EK", "IS", "DS", "TL" } do
		gang = math.max(gang, tonumber(folder:GetAttribute("GangAnger_" .. k)) or 0)
	end
	local level = math.floor(t * 0.45 + co * 0.35 + gang * 0.2 + 0.5)
	local riot = folder:GetAttribute("Riot") == true
	local lockdown = (tonumber(folder:GetAttribute("RiotLockdownUntil")) or 0) > os.time()
	local word, color
	if riot then
		word, color = "RIOT", Color3.fromRGB(255, 60, 60)
	elseif lockdown then
		word, color = "LOCKDOWN", Color3.fromRGB(120, 170, 255)
	elseif level >= 55 then
		word, color = "About to blow", Color3.fromRGB(255, 80, 60)
	elseif level >= 40 then
		word, color = "Tense", Color3.fromRGB(255, 160, 60)
	elseif level >= 25 then
		word, color = "Uneasy", Color3.fromRGB(230, 210, 90)
	else
		word, color = "Calm", Color3.fromRGB(120, 210, 120)
	end
	mood.Text = ("Prison mood: %s (%d)\nCOs %d  -  gangs %d"):format(word, level, math.floor(co), math.floor(gang))
	mood.TextColor3 = color
	banner.Visible = riot and player:GetAttribute("CustodyOwner") == "INCARCERATED"
end
folder.AttributeChanged:Connect(refreshMood)
refreshMood()
task.spawn(function()
	local on = false
	while true do
		task.wait(0.5)
		if banner.Visible then
			on = not on
			banner.BackgroundColor3 = if on then Color3.fromRGB(190, 20, 20) else Color3.fromRGB(110, 10, 10)
		end
		refreshMood()
	end
end)
player.AttributeChanged:Connect(function(name)
	if name == "CustodyOwner" or name == "PrisonGang" or name == "CORespect" or string.sub(name, 1, 4) == "Rep_" then
		refreshPanel()
	end
end)
if isMobile() then
	collapsed = true
end
refreshPanel()

---------------------------------------------------------------------------
-- dialogue
---------------------------------------------------------------------------
local box = Instance.new("Frame")
box.Name = "Dialogue"
box.AnchorPoint = Vector2.new(0.5, 1)
box.Position = UDim2.new(0.5, 0, 1, -24)
box.Size = UDim2.new(0, 460, 0, 0)
box.AutomaticSize = Enum.AutomaticSize.Y
box.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
box.BackgroundTransparency = 0.1
box.Visible = false
box.Parent = gui
corner(box, 10)
local boxStroke = Instance.new("UIStroke")
boxStroke.Thickness = 2
boxStroke.Parent = box
local boxPad = Instance.new("UIPadding")
boxPad.PaddingTop = UDim.new(0, 10)
boxPad.PaddingBottom = UDim.new(0, 10)
boxPad.PaddingLeft = UDim.new(0, 12)
boxPad.PaddingRight = UDim.new(0, 12)
boxPad.Parent = box
local boxLayout = Instance.new("UIListLayout")
boxLayout.Padding = UDim.new(0, 6)
boxLayout.SortOrder = Enum.SortOrder.LayoutOrder
boxLayout.Parent = box

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 18)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.LayoutOrder = 1
title.Parent = box

local said = Instance.new("TextLabel")
said.Size = UDim2.new(1, 0, 0, 0)
said.AutomaticSize = Enum.AutomaticSize.Y
said.BackgroundTransparency = 1
said.TextColor3 = Color3.fromRGB(240, 240, 240)
said.Font = Enum.Font.Gotham
said.TextSize = 15
said.TextWrapped = true
said.TextXAlignment = Enum.TextXAlignment.Left
said.LayoutOrder = 2
said.Parent = box

local timerBar = Instance.new("Frame")
timerBar.Size = UDim2.new(1, 0, 0, 4)
timerBar.BackgroundColor3 = Color3.fromRGB(230, 170, 40)
timerBar.BorderSizePixel = 0
timerBar.LayoutOrder = 3
timerBar.Parent = box

local optionFrame = Instance.new("Frame")
optionFrame.Size = UDim2.new(1, 0, 0, 0)
optionFrame.AutomaticSize = Enum.AutomaticSize.Y
optionFrame.BackgroundTransparency = 1
optionFrame.LayoutOrder = 4
optionFrame.Parent = box
local optionGrid = Instance.new("UIGridLayout")
optionGrid.CellPadding = UDim2.fromOffset(6, 6)
optionGrid.CellSize = UDim2.new(0.5, -3, 0, 34)
optionGrid.SortOrder = Enum.SortOrder.LayoutOrder
optionGrid.Parent = optionFrame

local currentToken: number? = nil
local timerEnd: number? = nil
local timerTotal = 1
local forcedChoice = false
local sceneButtons: { TextButton } = {}

-- v218: forced-choice scenes - a big countdown under the line, no way out
local countdown = Instance.new("TextLabel")
countdown.Size = UDim2.new(1, 0, 0, 18)
countdown.BackgroundTransparency = 1
countdown.Font = Enum.Font.GothamBlack
countdown.TextSize = 14
countdown.TextColor3 = Color3.fromRGB(255, 90, 80)
countdown.TextXAlignment = Enum.TextXAlignment.Left
countdown.LayoutOrder = 3
countdown.Visible = false
countdown.Parent = box

local TONES = {
	calm = Color3.fromRGB(45, 95, 70),
	bold = Color3.fromRGB(40, 70, 130),
	risky = Color3.fromRGB(150, 100, 25),
	hostile = Color3.fromRGB(135, 35, 35),
}

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not forcedChoice or not box.Visible then
		return
	end
	local keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
	for i, k in keys do
		if input.KeyCode == k and sceneButtons[i] then
			local b = sceneButtons[i]
			local token = b:GetAttribute("Token")
			local id = b:GetAttribute("OptionId")
			if currentToken == token then
				DialogueRE:FireServer(token, id)
			end
		end
	end
end)

local function layoutBox()
	local vp = workspace.CurrentCamera.ViewportSize
	local w = math.min(460, vp.X - 32)
	box.Size = UDim2.new(0, w, 0, 0)
	-- clear of the thumbstick/jump button on phones
	box.Position = if isMobile() then UDim2.new(0.5, 0, 1, -130) else UDim2.new(0.5, 0, 1, -24)
end

DialogueRE.OnClientEvent:Connect(function(data)
	for _, c in optionFrame:GetChildren() do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	table.clear(sceneButtons)
	if type(data) ~= "table" then
		box.Visible = false
		currentToken = nil
		timerEnd = nil
		forcedChoice = false
		countdown.Visible = false
		return
	end
	forcedChoice = data.forced == true
	countdown.Visible = forcedChoice
	timerBar.BackgroundColor3 = if forcedChoice then Color3.fromRGB(230, 60, 50) else Color3.fromRGB(230, 170, 40)
	timerBar.LayoutOrder = if forcedChoice then 3 else 3
	layoutBox()
	currentToken = data.token
	title.Text = ("%s  ·  %s"):format(tostring(data.name), tostring(data.gang))
	local color = if typeof(data.color) == "Color3" then data.color else Color3.fromRGB(150, 150, 150)
	-- black bandana crew: keep the name readable
	local lum = color.R * 0.3 + color.G * 0.59 + color.B * 0.11
	title.TextColor3 = if lum < 0.2 then Color3.fromRGB(190, 190, 200) else color
	boxStroke.Color = color
	said.Text = '"' .. tostring(data.text) .. '"'
	if type(data.seconds) == "number" then
		timerEnd = os.clock() + data.seconds
		timerTotal = data.seconds
		timerBar.Visible = true
	else
		timerEnd = nil
		timerBar.Visible = false
	end
	for i, opt in data.options or {} do
		local b = Instance.new("TextButton")
		b.LayoutOrder = i
		b.BackgroundColor3 = if opt.tone and TONES[opt.tone] then TONES[opt.tone]
			elseif opt.id == "trash" then Color3.fromRGB(120, 35, 35)
			elseif opt.id == "leave" or opt.id == "back" then Color3.fromRGB(55, 55, 62)
			else Color3.fromRGB(40, 70, 110)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamMedium
		b.TextScaled = true
		b.Text = if forcedChoice then ("%d. %s"):format(i, tostring(opt.text)) else tostring(opt.text)
		b:SetAttribute("Token", data.token)
		b:SetAttribute("OptionId", opt.id)
		if forcedChoice then
			table.insert(sceneButtons, b)
		end
		b.Parent = optionFrame
		corner(b, 6)
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = 14
		limit.Parent = b
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = b
		local token = data.token
		b.Activated:Connect(function()
			if currentToken == token then
				DialogueRE:FireServer(token, opt.id)
			end
		end)
	end
	box.Visible = true
end)

---------------------------------------------------------------------------
-- per-frame bits
---------------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(0.1)
		-- v227: inmates always see it (it explains why when you can't swing); free
		-- players on touch screens only get it when they can actually punch
		punchButton.Visible = player:GetAttribute("SentenceEnd") ~= nil or (isMobile() and canPunch())
		if timerEnd and box.Visible then
			local left = math.max(0, timerEnd - os.clock())
			timerBar.Size = UDim2.new(left / timerTotal, 0, 0, if forcedChoice then 6 else 4)
			if forcedChoice then
				countdown.Text = ("CHOOSE  -  %.1fs  (no backing out)"):format(left)
			end
		end
	end
end)
