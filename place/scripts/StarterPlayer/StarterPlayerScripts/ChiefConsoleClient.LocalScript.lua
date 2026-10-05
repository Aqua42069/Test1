-- ChiefConsoleClient (v212)
-- The Chief of Police command console. Shows a "CHIEF" button while you're on
-- the Chief of Police team (aquagaming22 only - the server checks too):
--   * pick a player
--   * set their wanted level (0-6 stars)
--   * issue a warrant with chosen charges (incl. 5 officer kills = Death Row) / clear it
--   * dispatch any unit type (patrol ... SWAT, riot, SEALs, juggernauts, army),
--     how many, in what vehicle, with how many helicopters
--   * authorize lethal force

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local console = ReplicatedStorage:WaitForChild("ChiefConsole") :: RemoteFunction

local CHIEF_TEAM = "Chief of Police"

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local obj = Instance.new(className)
	for k, v in props do
		(obj :: any)[k] = v
	end
	obj.Parent = parent
	return obj
end

local function corner(parent: Instance, px: number)
	make("UICorner", { CornerRadius = UDim.new(0, px) }, parent)
end

local gui = make("ScreenGui", { Name = "ChiefConsole", ResetOnSpawn = false, DisplayOrder = 30 }, player:WaitForChild("PlayerGui"))

local open = make("TextButton", {
	Name = "ChiefButton",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 10, 0.62, 0),
	Size = UDim2.fromOffset(92, 36),
	BackgroundColor3 = Color3.fromRGB(150, 25, 25),
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamBlack,
	TextSize = 14,
	Text = "CHIEF",
	Visible = false,
}, gui)
corner(open, 8)

local panel = make("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0, 560, 0, 400),
	BackgroundColor3 = Color3.fromRGB(16, 18, 24),
	BackgroundTransparency = 0.05,
	Visible = false,
}, gui)
corner(panel, 10)
make("UIStroke", { Color = Color3.fromRGB(150, 25, 25), Thickness = 2 }, panel)

make("TextLabel", {
	Position = UDim2.fromOffset(14, 8),
	Size = UDim2.new(1, -60, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextSize = 18,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(255, 90, 90),
	Text = "CHIEF OF POLICE - COMMAND",
}, panel)
local close = make("TextButton", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -8, 0, 8),
	Size = UDim2.fromOffset(28, 28),
	BackgroundColor3 = Color3.fromRGB(120, 30, 30),
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	Text = "X",
}, panel)
corner(close, 14)

-- players (left)
local list = make("ScrollingFrame", {
	Position = UDim2.fromOffset(12, 40),
	Size = UDim2.new(0.4, -12, 1, -80),
	BackgroundColor3 = Color3.fromRGB(26, 28, 36),
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, panel)
corner(list, 6)
make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)
make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8) }, list)

-- controls (right)
local right = make("Frame", {
	Position = UDim2.new(0.4, 8, 0, 40),
	Size = UDim2.new(0.6, -20, 1, -80),
	BackgroundTransparency = 1,
}, panel)
make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, right)

local status = make("TextLabel", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 14, 1, -8),
	Size = UDim2.new(1, -28, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(200, 220, 200),
	Text = "Select a player",
}, panel)

local selectedName: string? = nil
local selectedLabel = make("TextLabel", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "Target: none",
}, right)

local function row(order: number, height: number?): Frame
	local f = make("Frame", { LayoutOrder = order, Size = UDim2.new(1, 0, 0, height or 30), BackgroundTransparency = 1 }, right)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, f)
	return f
end

local function button(parent: Instance, text: string, width: number, color: Color3, order: number?): TextButton
	local b = make("TextButton", {
		LayoutOrder = order or 0,
		Size = UDim2.new(width, -4, 1, 0),
		BackgroundColor3 = color,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		Text = text,
	}, parent)
	corner(b, 6)
	make("UITextSizeConstraint", { MaxTextSize = 14 }, b)
	return b
end

local function call(...): (boolean, any)
	local ok, success, msg = pcall(console.InvokeServer, console, ...)
	if not ok then
		status.Text = "Error: " .. tostring(success)
		return false, nil
	end
	status.Text = tostring(msg or (if success then "Done" else "Failed"))
	status.TextColor3 = if success then Color3.fromRGB(170, 235, 170) else Color3.fromRGB(255, 150, 150)
	return success, msg
end

-- wanted level
make("TextLabel", { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(190, 190, 200), Text = "Wanted level" }, right)
local starsRow = row(3)
for n = 0, 6 do
	local b = button(starsRow, if n == 0 then "CLEAR" else string.rep("★", 1) .. n, 1 / 7, if n == 0 then Color3.fromRGB(60, 90, 60) elseif n == 6 then Color3.fromRGB(150, 30, 30) else Color3.fromRGB(120, 95, 30), n)
	b.Activated:Connect(function()
		if selectedName then
			call("setWanted", selectedName, n)
		end
	end)
end

-- warrant (v235: pick the crimes - they go on the suspect's record and decide
-- the case at booking; "5 police officers" means Death Row)
local warrantCrimes: { { key: string, charge: string, stars: number } } = {}
local pickedCrimes: { [string]: boolean } = {}

local warrantRow = row(4)
local openWarrant = button(warrantRow, "ISSUE WARRANT...", 0.7, Color3.fromRGB(150, 70, 20), 1)
button(warrantRow, "CLEAR", 0.3, Color3.fromRGB(60, 70, 80), 2).Activated:Connect(function()
	if selectedName then
		call("clearWarrant", selectedName)
	end
end)

local picker = make("Frame", {
	Name = "WarrantPicker",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(16, 18, 24),
	Visible = false,
	ZIndex = 20,
}, panel)
corner(picker, 10)
local pickerTitle = make("TextLabel", {
	Position = UDim2.fromOffset(14, 8),
	Size = UDim2.new(1, -28, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextSize = 16,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(255, 170, 90),
	Text = "WARRANT - select the charges",
	ZIndex = 21,
}, picker)
local crimeList = make("ScrollingFrame", {
	Position = UDim2.fromOffset(12, 38),
	Size = UDim2.new(1, -24, 1, -130),
	BackgroundColor3 = Color3.fromRGB(26, 28, 36),
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ZIndex = 21,
}, picker)
corner(crimeList, 6)
make("UIGridLayout", { CellSize = UDim2.new(0.5, -6, 0, 34), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }, crimeList)
make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8) }, crimeList)
local reason = make("TextBox", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 12, 1, -50),
	Size = UDim2.new(1, -24, 0, 30),
	BackgroundColor3 = Color3.fromRGB(34, 36, 46),
	TextColor3 = Color3.new(1, 1, 1),
	PlaceholderText = "Extra details (optional)",
	Text = "",
	Font = Enum.Font.Gotham,
	TextSize = 13,
	ClearTextOnFocus = false,
	ZIndex = 21,
}, picker)
corner(reason, 6)
local pickerButtons = make("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 12, 1, -10),
	Size = UDim2.new(1, -24, 0, 34),
	BackgroundTransparency = 1,
	ZIndex = 21,
}, picker)
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, pickerButtons)
local issue = button(pickerButtons, "ISSUE WARRANT", 0.4, Color3.fromRGB(170, 70, 20), 1)
-- v260: warrants are no-star by default (served when someone identifies them); a severity
-- (auto, 1 low-risk, 2, 3 felony stop) and an option to make them wanted right now too
local severity, alsoStars = 0, false
local sevButton = button(pickerButtons, "SEVERITY: AUTO", 0.22, Color3.fromRGB(70, 60, 110), 2)
local starButton = button(pickerButtons, "STARS NOW: OFF", 0.2, Color3.fromRGB(60, 70, 80), 3)
local cancel = button(pickerButtons, "CANCEL", 0.18, Color3.fromRGB(60, 70, 80), 4)
issue.ZIndex = 22
cancel.ZIndex = 22
sevButton.ZIndex = 22
starButton.ZIndex = 22
sevButton.Activated:Connect(function()
	severity = (severity + 1) % 4
	sevButton.Text = if severity == 0 then "SEVERITY: AUTO" else ("SEVERITY: %d%s"):format(severity, if severity == 3 then " FELONY" elseif severity == 1 then " LOW" else "")
end)
starButton.Activated:Connect(function()
	alsoStars = not alsoStars
	starButton.Text = if alsoStars then "STARS NOW: ON" else "STARS NOW: OFF"
	starButton.BackgroundColor3 = if alsoStars then Color3.fromRGB(150, 30, 30) else Color3.fromRGB(60, 70, 80)
end)

local function paintCrimes()
	for _, c in crimeList:GetChildren() do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	for i, crime in warrantCrimes do
		local on = pickedCrimes[crime.key] == true
		local deathRow = crime.key == "FiveCopKills"
		local b = make("TextButton", {
			LayoutOrder = i,
			BackgroundColor3 = if on then (if deathRow then Color3.fromRGB(170, 20, 20) else Color3.fromRGB(150, 80, 20))
				else Color3.fromRGB(40, 42, 54),
			TextColor3 = Color3.new(1, 1, 1),
			Font = if deathRow then Enum.Font.GothamBlack else Enum.Font.GothamMedium,
			TextScaled = true,
			Text = (if on then "✔ " else "") .. crime.charge .. "  " .. string.rep("★", crime.stars),
			ZIndex = 22,
		}, crimeList)
		corner(b, 5)
		make("UITextSizeConstraint", { MaxTextSize = 13 }, b)
		make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, b)
		b.Activated:Connect(function()
			pickedCrimes[crime.key] = not pickedCrimes[crime.key] or nil
			paintCrimes()
		end)
	end
end

openWarrant.Activated:Connect(function()
	if not selectedName then
		status.Text = "Select a player first"
		return
	end
	pickerTitle.Text = "WARRANT for " .. selectedName .. " - select the charges"
	table.clear(pickedCrimes)
	reason.Text = ""
	paintCrimes()
	picker.Visible = true
end)
cancel.Activated:Connect(function()
	picker.Visible = false
end)
issue.Activated:Connect(function()
	if not selectedName then
		return
	end
	local keys = {}
	for _, crime in warrantCrimes do
		if pickedCrimes[crime.key] then
			table.insert(keys, crime.key)
		end
	end
	local ok = call("warrant", selectedName, reason.Text, keys, alsoStars, severity)
	if ok then
		picker.Visible = false
	else
		pickerTitle.Text = status.Text -- the picker covers the status line
	end
end)

-- dispatch
make("TextLabel", { LayoutOrder = 5, Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(190, 190, 200), Text = "Dispatch units" }, right)
local units = { "Patrol", "Officer", "Shotgunner", "SWAT", "Riot", "Heavy", "SEAL", "Juggernaut", "Army" }
local unitIndex, count, vehicleIndex, helis = 4, 4, 3, 0
local vehicles = { "None", "Cruiser", "Van", "Armored" }
local vehicleIndexDefault = 4
vehicleIndex = vehicleIndexDefault

local dispatchRow = row(6)
local unitBtn = button(dispatchRow, "", 0.4, Color3.fromRGB(40, 60, 110), 1)
local minus = button(dispatchRow, "-", 0.12, Color3.fromRGB(50, 50, 60), 2)
local countLbl = button(dispatchRow, "", 0.16, Color3.fromRGB(30, 30, 38), 3)
local plus = button(dispatchRow, "+", 0.12, Color3.fromRGB(50, 50, 60), 4)
local heliBtn = button(dispatchRow, "", 0.2, Color3.fromRGB(40, 60, 110), 5)

local dispatchRow2 = row(7)
local vehicleBtn = button(dispatchRow2, "", 0.5, Color3.fromRGB(40, 60, 110), 1)
local lethalBtn = button(dispatchRow2, "LETHAL FORCE", 0.5, Color3.fromRGB(120, 20, 20), 2)

local sendRow = row(8, 38)
local send = button(sendRow, "DISPATCH", 1, Color3.fromRGB(170, 30, 30), 1)

local function refreshDispatch()
	unitBtn.Text = "Unit: " .. units[unitIndex]
	countLbl.Text = tostring(count)
	heliBtn.Text = "Heli: " .. helis
	vehicleBtn.Text = "Vehicle: " .. vehicles[vehicleIndex]
end
refreshDispatch()
unitBtn.Activated:Connect(function()
	unitIndex = unitIndex % #units + 1
	refreshDispatch()
end)
minus.Activated:Connect(function()
	count = math.max(1, count - 1)
	refreshDispatch()
end)
plus.Activated:Connect(function()
	count = math.min(20, count + 1)
	refreshDispatch()
end)
heliBtn.Activated:Connect(function()
	helis = (helis + 1) % 4
	refreshDispatch()
end)
vehicleBtn.Activated:Connect(function()
	vehicleIndex = vehicleIndex % #vehicles + 1
	refreshDispatch()
end)
send.Activated:Connect(function()
	if selectedName then
		call("dispatch", selectedName, units[unitIndex], count, vehicles[vehicleIndex], helis)
	end
end)
lethalBtn.Activated:Connect(function()
	if selectedName then
		call("lethal", selectedName)
	end
end)

local function refreshList()
	for _, c in list:GetChildren() do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	local ok, success, entries, serverUnits, crimes = pcall(console.InvokeServer, console, "list")
	if ok and type(crimes) == "table" and #crimes > 0 then
		warrantCrimes = crimes
	end
	if not ok or not success or type(entries) ~= "table" then
		status.Text = "Console unavailable"
		return
	end
	if type(serverUnits) == "table" and #serverUnits > 0 then
		units = serverUnits
		unitIndex = math.clamp(unitIndex, 1, #units)
		refreshDispatch()
	end
	for i, e in entries do
		local b = make("TextButton", {
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundColor3 = if e.name == selectedName then Color3.fromRGB(70, 40, 40) else Color3.fromRGB(40, 42, 54),
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.GothamMedium,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = ("  %s  %s\n  %s%s"):format(e.display, string.rep("★", e.stars or 0), e.team, if e.warrant then "  [WARRANT]" else ""),
		}, list)
		corner(b, 5)
		b.Activated:Connect(function()
			selectedName = e.name
			selectedLabel.Text = "Target: " .. e.display .. " (@" .. e.name .. ")"
			refreshList()
		end)
	end
end

local function isChief(): boolean
	return player.Team ~= nil and player.Team.Name == CHIEF_TEAM
end

local function refreshVisible()
	open.Visible = isChief()
	if not isChief() then
		panel.Visible = false
	end
end
player:GetPropertyChangedSignal("Team"):Connect(refreshVisible)
refreshVisible()

local function toggle()
	panel.Visible = not panel.Visible
	if panel.Visible then
		local vp = workspace.CurrentCamera.ViewportSize
		panel.Size = UDim2.fromOffset(math.min(560, vp.X - 24), math.min(400, vp.Y - 40))
		refreshList()
	end
end
open.Activated:Connect(toggle)
close.Activated:Connect(function()
	panel.Visible = false
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not isChief() then
		return
	end
	if input.KeyCode == Enum.KeyCode.F4 then
		toggle()
	end
end)

task.spawn(function()
	while true do
		task.wait(5)
		if panel.Visible then
			refreshList()
		end
	end
end)
