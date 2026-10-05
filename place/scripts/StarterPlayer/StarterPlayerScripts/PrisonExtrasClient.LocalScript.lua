-- PrisonExtrasClient (v212)
--   * Death row: choose the method (gas chamber, electric chair, lethal injection)
--   * C-SPAN LIVE: executions are broadcast from a camera in the execution room.
--     Watch from the banner or the C-SPAN phone app; any viewer can pay
--     $50,000,000 for the governor's pardon while the line is open.
--   * Visits phone app: request a visit (or a contact visit) with an inmate.
--   * Inmates get the request as a pop-up (they have no phone).
--   * Contact visits: sneak an item over - a quick-time event.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("PrisonExtras")
local ExecRE = remotes:WaitForChild("Execution") :: RemoteEvent
local VisitRE = remotes:WaitForChild("Visit") :: RemoteEvent
local VisitRF = remotes:WaitForChild("VisitQuery") :: RemoteFunction

local RED = Color3.fromRGB(200, 30, 30)
local DARK = Color3.fromRGB(16, 18, 22)

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

local function textButton(parent: Instance, text: string, color: Color3, props: { [string]: any }?): TextButton
	local b = make("TextButton", {
		BackgroundColor3 = color,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		Text = text,
		AutoButtonColor = true,
	}, parent)
	for k, v in props or {} do
		(b :: any)[k] = v
	end
	corner(b, 8)
	make("UITextSizeConstraint", { MaxTextSize = 18 }, b)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, b)
	return b
end

local gui = make("ScreenGui", { Name = "PrisonExtrasGui", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 40 }, playerGui)

local function fmtTime(secs: number): string
	secs = math.max(0, math.floor(secs))
	return ("%d:%02d"):format(secs // 60, secs % 60)
end

local function money(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

---------------------------------------------------------------------------
-- execution: method choice (the condemned)
---------------------------------------------------------------------------
local chooser = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.5, 0.42),
	BackgroundColor3 = DARK,
	BackgroundTransparency = 0.05,
	Visible = false,
}, gui)
corner(chooser, 12)
make("UIStroke", { Color = RED, Thickness = 2 }, chooser)
make("UISizeConstraint", { MinSize = Vector2.new(300, 220), MaxSize = Vector2.new(560, 360) }, chooser)
local chooserTitle = make("TextLabel", {
	Position = UDim2.fromScale(0.05, 0.04),
	Size = UDim2.fromScale(0.9, 0.2),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	TextColor3 = Color3.fromRGB(255, 90, 90),
	Text = "CHOOSE YOUR EXECUTION",
}, chooser)
make("UITextSizeConstraint", { MaxTextSize = 26 }, chooserTitle)
local chooserTimer = make("TextLabel", {
	Position = UDim2.fromScale(0.05, 0.23),
	Size = UDim2.fromScale(0.9, 0.1),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	TextScaled = true,
	TextColor3 = Color3.fromRGB(210, 210, 210),
	Text = "",
}, chooser)
make("UITextSizeConstraint", { MaxTextSize = 16 }, chooserTimer)
local chooserButtons = make("Frame", {
	Position = UDim2.fromScale(0.05, 0.38),
	Size = UDim2.fromScale(0.9, 0.56),
	BackgroundTransparency = 1,
}, chooser)
make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, chooserButtons)

local chooseToken: number? = nil
local chooseUntil = 0

ExecRE.OnClientEvent:Connect(function(kind: string, info: any)
	if kind == "choose" and type(info) == "table" then
		for _, c in chooserButtons:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		chooseToken = info.token
		chooseUntil = os.clock() + (info.seconds or 20)
		for i, option in info.options or {} do
			local b = textButton(chooserButtons, option, Color3.fromRGB(70, 30, 30), { LayoutOrder = i, Size = UDim2.new(1, 0, 0.3, -6) })
			b.Activated:Connect(function()
				if chooseToken then
					ExecRE:FireServer("choose", chooseToken, option)
					chooseToken = nil
					chooser.Visible = false
				end
			end)
		end
		chooser.Visible = true
	end
end)

---------------------------------------------------------------------------
-- C-SPAN LIVE
---------------------------------------------------------------------------
local live: any = nil

local banner = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 44),
	Size = UDim2.new(0.5, 0, 0, 40),
	BackgroundColor3 = Color3.fromRGB(20, 20, 24),
	BackgroundTransparency = 0.1,
	Visible = false,
}, gui)
corner(banner, 8)
make("UISizeConstraint", { MinSize = Vector2.new(300, 40), MaxSize = Vector2.new(620, 40) }, banner)
local bannerText = make("TextLabel", {
	Position = UDim2.fromOffset(10, 0),
	Size = UDim2.new(1, -120, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "",
}, banner)
make("UITextSizeConstraint", { MaxTextSize = 15 }, bannerText)
local watchBtn = textButton(banner, "WATCH", RED, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(100, 30) })

-- the viewer
local viewer = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, gui)
make("Frame", { Size = UDim2.new(1, 0, 0.1, 0), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0 }, viewer)
make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.14, 0), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0 }, viewer)
local liveDot = make("TextLabel", {
	Position = UDim2.new(0.02, 0, 0.02, 0),
	Size = UDim2.new(0.3, 0, 0.06, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(255, 60, 60),
	Text = "● LIVE   C-SPAN",
}, viewer)
local caption = make("TextLabel", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0.02, 0, 0.985, 0),
	Size = UDim2.new(0.6, 0, 0.1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "",
}, viewer)
make("UITextSizeConstraint", { MaxTextSize = 22 }, caption)
local pardonBtn = textButton(viewer, "", Color3.fromRGB(30, 110, 50), {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(0.98, 0, 0.985, 0),
	Size = UDim2.new(0.3, 0, 0.1, 0),
})
local closeViewer = textButton(viewer, "CLOSE", Color3.fromRGB(60, 60, 70), {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(0.98, 0, 0.02, 0),
	Size = UDim2.new(0.1, 0, 0.06, 0),
})
make("UISizeConstraint", { MinSize = Vector2.new(70, 28) }, closeViewer)

local watching = false
local savedType: Enum.CameraType? = nil

local function stopWatching()
	if not watching then
		return
	end
	watching = false
	viewer.Visible = false
	local cam = workspace.CurrentCamera
	cam.CameraType = savedType or Enum.CameraType.Custom
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraSubject = hum
	end
end

local function startWatching()
	if not live or watching then
		return
	end
	watching = true
	viewer.Visible = true
	local cam = workspace.CurrentCamera
	savedType = cam.CameraType
	cam.CameraType = Enum.CameraType.Scriptable
end

watchBtn.Activated:Connect(startWatching)
closeViewer.Activated:Connect(stopWatching)
pardonBtn.Activated:Connect(function()
	if live and live.state == "live" then
		ExecRE:FireServer("pardon", live.token)
	end
end)

local sway = 0
RunService.RenderStepped:Connect(function(dt)
	if watching and live and typeof(live.camera) == "CFrame" then
		sway += dt
		local cam = workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = live.camera * CFrame.Angles(math.sin(sway * 0.3) * 0.01, math.sin(sway * 0.21) * 0.015, 0)
		cam.FieldOfView = 60
	end
	if chooser.Visible then
		local left = chooseUntil - os.clock()
		chooserTimer.Text = ("Choose within %d seconds - otherwise the warden decides"):format(math.max(0, math.ceil(left)))
		if left <= 0 then
			chooser.Visible = false
		end
	end
end)

-- the C-SPAN phone app gets a LIVE button
local phoneLive: TextButton? = nil
local function hookPhone()
	local phone = playerGui:FindFirstChild("CellPhone")
	local frame = phone and phone:FindFirstChild("Outline")
	frame = frame and frame:FindFirstChild("ScreenFrame")
	local news = frame and frame:FindFirstChild("NewsFrame")
	if not news or news:FindFirstChild("LiveButton") then
		return
	end
	local b = textButton(news, "● LIVE", RED, {
		Name = "LiveButton",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 4),
		Size = UDim2.new(0.34, 0, 0, 22),
		ZIndex = 20,
		Visible = live ~= nil,
	})
	b.Activated:Connect(startWatching)
	phoneLive = b
end

local function refreshLive()
	banner.Visible = live ~= nil and live.state == "live"
	if phoneLive and phoneLive.Parent then
		phoneLive.Visible = live ~= nil
	end
	if not live then
		stopWatching()
		return
	end
	bannerText.Text = ("● LIVE on C-SPAN: execution of %s (%s)"):format(tostring(live.name), string.lower(tostring(live.method)))
	caption.Text = ("THE STATE vs %s  ·  %s"):format(string.upper(tostring(live.name)), string.upper(tostring(live.method)))
end

-- v219: lethal injection as the condemned player feels it: the sedative blurs
-- the screen (fuzzy, then very fuzzy), the paralytic locks everything up and
-- drains the colour, the potassium chloride fades it all to black.
local injectionFx: { Instance } = {}
local function clearInjection()
	for _, fx in injectionFx do
		if fx.Parent then
			fx:Destroy()
		end
	end
	table.clear(injectionFx)
end
player.CharacterAdded:Connect(clearInjection)
local TweenService = game:GetService("TweenService")
local function injectionStage(n: number)
	local lighting = game:GetService("Lighting")
	local blur = lighting:FindFirstChild("InjectionBlur") :: BlurEffect?
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "InjectionBlur"
		blur.Size = 0
		blur.Parent = lighting
		table.insert(injectionFx, blur)
	end
	local cc = lighting:FindFirstChild("InjectionCC") :: ColorCorrectionEffect?
	if not cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "InjectionCC"
		cc.Parent = lighting
		table.insert(injectionFx, cc)
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local screen = pg and pg:FindFirstChild("InjectionScreen") :: ScreenGui?
	if not screen and pg then
		screen = Instance.new("ScreenGui")
		screen.Name = "InjectionScreen"
		screen.IgnoreGuiInset = true
		screen.DisplayOrder = 50
		screen.ResetOnSpawn = true
		screen.Parent = pg
		table.insert(injectionFx, screen)
		local black = Instance.new("Frame")
		black.Name = "Black"
		black.Size = UDim2.fromScale(1, 1)
		black.BackgroundColor3 = Color3.new(0, 0, 0)
		black.BackgroundTransparency = 1
		black.BorderSizePixel = 0
		black.Parent = screen
		local text = Instance.new("TextLabel")
		text.Name = "Thought"
		text.AnchorPoint = Vector2.new(0.5, 0.5)
		text.Position = UDim2.fromScale(0.5, 0.62)
		text.Size = UDim2.new(0.8, 0, 0, 40)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.GothamMedium
		text.TextSize = 22
		text.TextColor3 = Color3.fromRGB(230, 230, 230)
		text.TextTransparency = 1
		text.ZIndex = 2
		text.Parent = screen
	end
	local black = screen and screen:FindFirstChild("Black") :: Frame?
	local thought = screen and screen:FindFirstChild("Thought") :: TextLabel?
	local function say(t: string)
		if thought then
			thought.Text = t
			thought.TextTransparency = 1
			TweenService:Create(thought, TweenInfo.new(0.8), { TextTransparency = 0.1 }):Play()
			task.delay(3.5, function()
				if thought.Parent and thought.Text == t then
					TweenService:Create(thought, TweenInfo.new(1), { TextTransparency = 1 }):Play()
				end
			end)
		end
	end
	if n == 1 then
		say("Your eyelids get heavy...")
		TweenService:Create(blur, TweenInfo.new(3), { Size = 8 }):Play()
		TweenService:Create(cc, TweenInfo.new(3), { Saturation = -0.25, Brightness = -0.05 }):Play()
		task.delay(3.5, function()
			if blur.Parent then
				TweenService:Create(blur, TweenInfo.new(3.5), { Size = 24 }):Play()
				TweenService:Create(cc, TweenInfo.new(3.5), { Saturation = -0.5, Brightness = -0.12, Contrast = -0.2 }):Play()
			end
		end)
	elseif n == 2 then
		say("You can't move. You can't breathe.")
		TweenService:Create(blur, TweenInfo.new(2), { Size = 40 }):Play()
		TweenService:Create(cc, TweenInfo.new(4), { Saturation = -0.9, Brightness = -0.25, Contrast = -0.3 }):Play()
		if black then
			TweenService:Create(black, TweenInfo.new(5), { BackgroundTransparency = 0.45 }):Play()
		end
	elseif n == 3 then
		say("...")
		TweenService:Create(blur, TweenInfo.new(4), { Size = 56 }):Play()
		TweenService:Create(cc, TweenInfo.new(5), { Saturation = -1, Brightness = -0.5 }):Play()
		if black then
			TweenService:Create(black, TweenInfo.new(6), { BackgroundTransparency = 0 }):Play()
		end
	end
end

ExecRE.OnClientEvent:Connect(function(kind: string, info: any)
	if kind == "injection" and type(info) == "table" then
		if not info.viewer then
			-- sent only to the condemned player
			injectionStage(tonumber(info.stage) or 1)
		elseif live then
			caption.Text = ("LETHAL INJECTION  ·  DRUG %d OF 3: %s"):format(tonumber(info.stage) or 1, string.upper(tostring(info.drug)))
		end
		return
	end
	if kind == "ended" then
		task.delay(4, clearInjection)
	end
	if kind == "live" or kind == "executing" then
		live = info
		refreshLive()
	elseif kind == "pardoned" then
		if info then
			live = info
			caption.Text = ("GOVERNOR'S PARDON - %s is spared (paid by %s)"):format(string.upper(tostring(info.name)), tostring(info.by))
		end
		banner.Visible = false
		task.delay(6, function()
			live = nil
			refreshLive()
		end)
	elseif kind == "ended" then
		task.delay(3, function()
			live = nil
			refreshLive()
		end)
	end
end)

task.spawn(function()
	while true do
		task.wait(0.5)
		if live then
			local left = (tonumber(live.pardonAt) or 0) - os.time()
			local own = live.subject == player.Name
			if live.state == "live" and left > 0 and not own then
				pardonBtn.Visible = true
				pardonBtn.Text = ("GOVERNOR'S PARDON  $%s  (%s)"):format(money(live.price or 50000000), fmtTime(left))
			else
				pardonBtn.Visible = false
			end
		end
		hookPhone()
	end
end)
ExecRE:FireServer("sync")

---------------------------------------------------------------------------
-- Visits phone app
---------------------------------------------------------------------------
local visitsFrame: Frame? = nil
local visitsList: ScrollingFrame? = nil
local visitsStatus: TextLabel? = nil

local function refreshVisits()
	if not visitsList or not visitsStatus then
		return
	end
	for _, c in visitsList:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local ok, data = pcall(VisitRF.InvokeServer, VisitRF, "list")
	if not ok or type(data) ~= "table" then
		visitsStatus.Text = "Visitation line unavailable"
		return
	end
	visitsStatus.Text = if data.hours then "Visiting hours: OPEN (08:00-20:00)" else "Visiting hours: CLOSED (08:00-20:00)"
	if #data.inmates == 0 then
		visitsStatus.Text ..= "\nNo inmates in the State Prison"
	end
	for i, e in data.inmates do
		local row = make("Frame", { LayoutOrder = i, Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = Color3.fromRGB(34, 36, 44) }, visitsList)
		corner(row, 6)
		local l = make("TextLabel", {
			Position = UDim2.fromOffset(6, 2),
			Size = UDim2.new(1, -12, 0, 22),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			Text = ("%s  ·  %s  ·  %s left"):format(e.display, e.class, fmtTime(e.remaining)),
		}, row)
		make("UITextSizeConstraint", { MaxTextSize = 13 }, l)
		if e.eligible then
			local v = textButton(row, "VISIT", Color3.fromRGB(40, 90, 150), { Position = UDim2.new(0, 6, 0, 26), Size = UDim2.new(0.45, -6, 0, 22) })
			v.Activated:Connect(function()
				VisitRE:FireServer("request", e.name, false)
			end)
			v.Text = "GLASS VISIT"
			if e.contact then
				local c = textButton(row, "CONTACT VISIT", Color3.fromRGB(150, 80, 25), { Position = UDim2.new(0.5, 0, 0, 26), Size = UDim2.new(0.5, -6, 0, 22) })
				c.Activated:Connect(function()
					VisitRE:FireServer("request", e.name, true)
					if visitsStatus then
						visitsStatus.Text = "Contact visit requested - waiting for " .. tostring(e.display)
					end
				end)
			else
				local c = textButton(row, "NO CONTACT (" .. tostring(e.class) .. ")", Color3.fromRGB(70, 70, 76), { Position = UDim2.new(0.5, 0, 0, 26), Size = UDim2.new(0.5, -6, 0, 22) })
				c.AutoButtonColor = false
			end
		else
			local w = make("TextLabel", {
				Position = UDim2.fromOffset(6, 26),
				Size = UDim2.new(1, -12, 0, 20),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextScaled = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Color3.fromRGB(190, 150, 150),
				Text = "No visits: " .. tostring(e.why),
			}, row)
			make("UITextSizeConstraint", { MaxTextSize = 12 }, w)
		end
	end
end

local function hookVisitsApp()
	local phone = playerGui:FindFirstChild("CellPhone")
	local outline = phone and phone:FindFirstChild("Outline")
	local screen = outline and outline:FindFirstChild("ScreenFrame")
	local home = screen and screen:FindFirstChild("HomeFrame")
	local news = screen and screen:FindFirstChild("NewsFrame")
	if not home or not news or home:FindFirstChild("VisitsApp") then
		return
	end
	-- a fourth row on the home screen
	local icons = {}
	for _, c in home:GetChildren() do
		if c:IsA("GuiButton") then
			table.insert(icons, c)
		end
	end
	table.sort(icons, function(a, b)
		if math.abs(a.Position.Y.Scale - b.Position.Y.Scale) > 0.05 then
			return a.Position.Y.Scale < b.Position.Y.Scale
		end
		return a.Position.X.Scale < b.Position.X.Scale
	end)
	local template = home:FindFirstChild("Calls") or icons[1]
	if not template then
		return
	end
	local icon = template:Clone()
	icon.Name = "VisitsApp"
	for _, d in icon:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	local note = icon:FindFirstChild("Notification")
	if note then
		note.Visible = false
	end
	make("TextLabel", {
		Name = "Caption",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.3),
		BackgroundColor3 = Color3.fromRGB(20, 60, 110),
		BackgroundTransparency = 0.1,
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		Text = "VISITS",
		ZIndex = (icon :: GuiObject).ZIndex + 1,
	}, icon)
	icon.Parent = home
	table.insert(icons, icon)
	for i, c in icons do
		local col = (i - 1) % 3
		local r = (i - 1) // 3
		c.Size = UDim2.new(0.3, 0, 0.23, 0)
		c.Position = UDim2.new(0.01 + col * 0.34, 0, 0.01 + r * 0.25, 0)
	end
	-- the app screen
	local frame = make("Frame", {
		Name = "VisitsAppFrame",
		Size = news.Size,
		Position = news.Position,
		AnchorPoint = news.AnchorPoint,
		BackgroundColor3 = news.BackgroundColor3,
		BackgroundTransparency = news.BackgroundTransparency,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = news.ZIndex,
	}, screen)
	local title = news:FindFirstChild("Title")
	if title then
		local t = title:Clone()
		t.Text = "Visits App"
		t.Parent = frame
	end
	local homeBtn = news:FindFirstChild("Home")
	local back: GuiButton
	if homeBtn then
		back = homeBtn:Clone()
		back.Parent = frame
	else
		back = textButton(frame, "HOME", Color3.fromRGB(60, 60, 70), { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(0.4, 0, 0, 24) })
	end
	local status = make("TextLabel", {
		Position = UDim2.new(0.04, 0, 0.12, 0),
		Size = UDim2.new(0.92, 0, 0.1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(40, 40, 40),
		Text = "",
	}, frame)
	make("UITextSizeConstraint", { MaxTextSize = 13 }, status)
	local scroll = make("ScrollingFrame", {
		Position = UDim2.new(0.04, 0, 0.24, 0),
		Size = UDim2.new(0.92, 0, 0.62, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, frame)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
	visitsFrame, visitsList, visitsStatus = frame, scroll, status
	icon.MouseButton1Click:Connect(function()
		home.Visible = false
		for _, f in screen:GetChildren() do
			if f:IsA("Frame") and f.Name:sub(-5) == "Frame" and f.Name ~= "PermFrame" and f.Name ~= "PayFrame" then
				f.Visible = false
			end
		end
		frame.Visible = true
		refreshVisits()
	end)
	back.MouseButton1Click:Connect(function()
		frame.Visible = false
		home.Visible = true
	end)
end

task.spawn(function()
	task.wait(4) -- after the phone's own FrameHandler wires its apps
	while true do
		pcall(hookVisitsApp)
		task.wait(3)
	end
end)

---------------------------------------------------------------------------
-- visits: requests, the visit HUD, smuggling
---------------------------------------------------------------------------
local popup = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.16, 0),
	Size = UDim2.new(0.4, 0, 0, 110),
	BackgroundColor3 = DARK,
	Visible = false,
}, gui)
corner(popup, 10)
make("UISizeConstraint", { MinSize = Vector2.new(280, 110), MaxSize = Vector2.new(460, 110) }, popup)
make("UIStroke", { Color = Color3.fromRGB(60, 120, 200), Thickness = 2 }, popup)
local popupText = make("TextLabel", {
	Position = UDim2.new(0.05, 0, 0, 8),
	Size = UDim2.new(0.9, 0, 0, 50),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextWrapped = true,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "",
}, popup)
make("UITextSizeConstraint", { MaxTextSize = 17 }, popupText)
local acceptBtn = textButton(popup, "ACCEPT", Color3.fromRGB(40, 130, 60), { Position = UDim2.new(0.05, 0, 0, 66), Size = UDim2.new(0.43, 0, 0, 34) })
local declineBtn = textButton(popup, "DECLINE", Color3.fromRGB(130, 40, 40), { Position = UDim2.new(0.52, 0, 0, 66), Size = UDim2.new(0.43, 0, 0, 34) })
local requestToken: number? = nil
acceptBtn.Activated:Connect(function()
	if requestToken then
		VisitRE:FireServer("answer", requestToken, true)
		requestToken = nil
		popup.Visible = false
	end
end)
declineBtn.Activated:Connect(function()
	if requestToken then
		VisitRE:FireServer("answer", requestToken, false)
		requestToken = nil
		popup.Visible = false
	end
end)

local visitHud = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 90),
	Size = UDim2.new(0.36, 0, 0, 40),
	BackgroundColor3 = DARK,
	BackgroundTransparency = 0.1,
	Visible = false,
}, gui)
corner(visitHud, 8)
make("UISizeConstraint", { MinSize = Vector2.new(260, 40), MaxSize = Vector2.new(460, 40) }, visitHud)
local visitText = make("TextLabel", {
	Position = UDim2.fromOffset(10, 0),
	Size = UDim2.new(0.62, 0, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "",
}, visitHud)
make("UITextSizeConstraint", { MaxTextSize = 15 }, visitText)
local sneakBtn = textButton(visitHud, "SNEAK ITEM", Color3.fromRGB(120, 70, 20), { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.new(0.34, 0, 0, 30), Visible = false })

local itemMenu = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 136),
	Size = UDim2.new(0.3, 0, 0, 130),
	BackgroundColor3 = DARK,
	Visible = false,
}, gui)
corner(itemMenu, 8)
make("UISizeConstraint", { MinSize = Vector2.new(220, 130), MaxSize = Vector2.new(360, 130) }, itemMenu)
make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, itemMenu)
make("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, itemMenu)

local visitEnds = 0
local visitWith = ""
local visitItems: { string }? = nil

sneakBtn.Activated:Connect(function()
	itemMenu.Visible = not itemMenu.Visible
end)

-- quick-time event: press the shown key (or tap it) in time, four times
local qte = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.55),
	Size = UDim2.fromOffset(240, 170),
	BackgroundColor3 = DARK,
	BackgroundTransparency = 0.05,
	Visible = false,
}, gui)
corner(qte, 12)
make("UIStroke", { Color = Color3.fromRGB(230, 170, 40), Thickness = 2 }, qte)
local qteTitle = make("TextLabel", {
	Position = UDim2.fromOffset(0, 6),
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = Color3.fromRGB(230, 170, 40),
	Text = "SLIP IT OVER",
}, qte)
local qteKey = textButton(qte, "", Color3.fromRGB(50, 52, 60), { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 36), Size = UDim2.fromOffset(90, 90) })
local qteBar = make("Frame", { Position = UDim2.new(0.1, 0, 0, 138), Size = UDim2.new(0.8, 0, 0, 10), BackgroundColor3 = Color3.fromRGB(230, 170, 40), BorderSizePixel = 0 }, qte)
local qteExpected: string? = nil
local qteHit = false

qteKey.Activated:Connect(function()
	if qteExpected then
		qteHit = true
	end
end)
UserInputService.InputBegan:Connect(function(input, _processed)
	if not qteExpected or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if input.KeyCode.Name == qteExpected then
		qteHit = true
	else
		qteExpected = "__WRONG__"
	end
end)

local function runQte(keys: { string }, window: number)
	qte.Visible = true
	local success = true
	for _, key in keys do
		qteExpected = key
		qteHit = false
		qteKey.Text = key
		local t0 = os.clock()
		while os.clock() - t0 < window and not qteHit and qteExpected == key do
			qteBar.Size = UDim2.new(0.8 * (1 - (os.clock() - t0) / window), 0, 0, 10)
			RunService.RenderStepped:Wait()
		end
		if not qteHit then
			success = false
			break
		end
		task.wait(0.15)
	end
	qteExpected = nil
	qte.Visible = false
	VisitRE:FireServer("qte", success)
end

VisitRE.OnClientEvent:Connect(function(kind: string, info: any)
	if kind == "request" then
		requestToken = info.token
		popupText.Text = ("%s wants to visit you%s. Accept?"):format(tostring(info.from), if info.contact then " (contact visit)" else "")
		popup.Visible = true
		task.delay(28, function()
			if requestToken == info.token then
				popup.Visible = false
				requestToken = nil
			end
		end)
	elseif kind == "visiting" then
		visitEnds = tonumber(info.endsAt) or (os.time() + 120)
		visitWith = tostring(info.with)
		visitItems = info.items
		visitHud.Visible = true
		sneakBtn.Visible = visitItems ~= nil
		for _, c in itemMenu:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		for i, item in visitItems or {} do
			local b = textButton(itemMenu, item, Color3.fromRGB(70, 60, 40), { LayoutOrder = i, Size = UDim2.new(1, 0, 0, 34) })
			b.Activated:Connect(function()
				itemMenu.Visible = false
				sneakBtn.Visible = false
				VisitRE:FireServer("smuggle", item)
			end)
		end
	elseif kind == "qte" then
		task.spawn(runQte, info.keys or {}, tonumber(info.window) or 1.4)
	elseif kind == "ended" then
		visitHud.Visible = false
		itemMenu.Visible = false
		qte.Visible = false
		qteExpected = nil
	end
end)

task.spawn(function()
	while true do
		task.wait(0.5)
		if visitHud.Visible then
			visitText.Text = ("Visit with %s  ·  %s"):format(visitWith, fmtTime(visitEnds - os.time()))
		end
	end
end)

---------------------------------------------------------------------------
-- v215: the prison schedule (only while you're serving a sentence)
---------------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")

local sched = make("Frame", {
	Name = "Schedule",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -10, 0, 150),
	Size = UDim2.fromOffset(250, 30),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = DARK,
	BackgroundTransparency = 0.2,
	Visible = false,
}, gui)
corner(sched, 8)
make("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, sched)
make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, sched)
local schedHeader = make("TextButton", {
	LayoutOrder = 0,
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(240, 200, 90),
	Text = "PRISON SCHEDULE",
}, sched)
local schedNow = make("TextLabel", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 13,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "",
}, sched)
local schedRows: { TextLabel } = {}
local schedCollapsed = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local function clockText(h: number): string
	local hh = math.floor(h) % 24
	local mm = math.floor((h - math.floor(h)) * 60 + 0.5)
	if mm == 60 then
		hh, mm = (hh + 1) % 24, 0
	end
	return ("%02d:%02d"):format(hh, mm)
end

local function readSchedule(): { any }?
	local class = player:GetAttribute("SecurityClass")
	if type(class) ~= "string" then
		return nil
	end
	local raw = remotes:GetAttribute("Regimen_" .. (string.gsub(class, "%W", "")))
	if type(raw) ~= "string" then
		return nil
	end
	local ok, rows = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok then rows else nil
end

local function refreshSchedule()
	local serving = player:GetAttribute("SentenceEnd") ~= nil and player:GetAttribute("CustodyOwner") == "INCARCERATED"
	local rows = if serving then readSchedule() else nil
	sched.Visible = rows ~= nil
	if not rows then
		return
	end
	local hour = Lighting.ClockTime
	local current: any = nil
	for _, r in rows do
		if hour >= r.s and hour < r.f then
			current = r
		end
	end
	schedHeader.Text = ("PRISON SCHEDULE · %s  %s"):format(tostring(player:GetAttribute("SecurityClass")), if schedCollapsed then "▸" else "▾")
	if current then
		local left = (current.f - hour) * 60 -- in-game minutes
		schedNow.Text = ("%s  NOW: %s - %s (%d min left)"):format(clockText(hour), current.b, current.w, math.max(0, math.floor(left)))
	else
		schedNow.Text = clockText(hour)
	end
	for i, r in rows do
		local row = schedRows[i]
		if not row then
			row = make("TextLabel", {
				LayoutOrder = 10 + i,
				Size = UDim2.new(1, 0, 0, 16),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, sched)
			schedRows[i] = row
		end
		row.Visible = not schedCollapsed
		row.Text = ("%s-%s  %s: %s"):format(clockText(r.s), clockText(r.f), r.b, r.w)
		row.TextColor3 = if r == current then Color3.fromRGB(255, 220, 110) else Color3.fromRGB(190, 190, 195)
		row.Font = if r == current then Enum.Font.GothamBold else Enum.Font.Gotham
	end
	for i = #rows + 1, #schedRows do
		schedRows[i].Visible = false
	end
end

schedHeader.Activated:Connect(function()
	schedCollapsed = not schedCollapsed
	refreshSchedule()
end)
task.spawn(function()
	while true do
		pcall(refreshSchedule)
		task.wait(1)
	end
end)
