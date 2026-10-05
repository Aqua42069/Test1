-- CityUIClient (v251-v256): the shared choice menu, notices and HUD tags used by
-- street gangs, bail, stashes / safes and the jail phones. Big touch targets, and
-- a UIScale so it fits a phone screen. Keys 1-9 pick options on keyboard.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("CityUI")

local gui = Instance.new("ScreenGui")
gui.Name = "CityUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 40
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local scale = Instance.new("UIScale")
scale.Parent = gui
local function fit()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	-- designed for ~1280x720; small phones shrink, but never below 0.6
	scale.Scale = math.clamp(math.min(vp.X / 1100, vp.Y / 650), 0.6, 1.25)
end
fit()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end

local function corner(p: Instance, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 10)
	c.Parent = p
end

---------------------------------------------------------------------------
-- notices (stacked, top centre)
---------------------------------------------------------------------------
local stack = Instance.new("Frame")
stack.Name = "Notices"
stack.BackgroundTransparency = 1
stack.AnchorPoint = Vector2.new(0.5, 0)
stack.Position = UDim2.new(0.5, 0, 0, 70)
stack.Size = UDim2.new(0, 560, 0, 300)
stack.Parent = gui
local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 6)
list.HorizontalAlignment = Enum.HorizontalAlignment.Center
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = stack
local order = 0

local function notice(text: string, seconds: number?, color: Color3?)
	order += 1
	local l = Instance.new("TextLabel")
	l.LayoutOrder = order
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.BackgroundColor3 = color or Color3.fromRGB(18, 20, 26)
	l.BackgroundTransparency = 0.15
	l.TextColor3 = Color3.new(1, 1, 1)
	l.Font = Enum.Font.GothamMedium
	l.TextSize = 18
	l.TextWrapped = true
	l.Text = text
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = l
	corner(l, 8)
	l.Parent = stack
	-- keep at most 5
	local labels = {}
	for _, c in stack:GetChildren() do if c:IsA("TextLabel") then table.insert(labels, c) end end
	table.sort(labels, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	while #labels > 5 do table.remove(labels, 1):Destroy() end
	task.delay(seconds or 4, function()
		if not l.Parent then return end
		local t = TweenService:Create(l, TweenInfo.new(0.4), { BackgroundTransparency = 1, TextTransparency = 1 })
		t:Play()
		t.Completed:Wait()
		l:Destroy()
	end)
end

---------------------------------------------------------------------------
-- HUD tags (top left, persistent until removed)
---------------------------------------------------------------------------
local tags = Instance.new("Frame")
tags.Name = "Tags"
tags.BackgroundTransparency = 1
tags.Position = UDim2.new(0, 12, 0, 120)
tags.Size = UDim2.new(0, 330, 0, 200)
tags.Parent = gui
local tagList = Instance.new("UIListLayout")
tagList.Padding = UDim.new(0, 4)
tagList.Parent = tags

local function setTag(name: string, text: string?)
	local l = tags:FindFirstChild(name) :: TextLabel?
	if not text then
		if l then l:Destroy() end
		return
	end
	if not l then
		local n = Instance.new("TextLabel")
		n.Name = name
		n.Size = UDim2.new(1, 0, 0, 26)
		n.BackgroundColor3 = Color3.fromRGB(120, 20, 20)
		n.BackgroundTransparency = 0.2
		n.TextColor3 = Color3.new(1, 1, 1)
		n.Font = Enum.Font.GothamBold
		n.TextSize = 15
		n.TextXAlignment = Enum.TextXAlignment.Left
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 8)
		pad.Parent = n
		corner(n, 6)
		n.Parent = tags
		l = n
	end
	(l :: TextLabel).Text = text
end

---------------------------------------------------------------------------
-- choice menu (one at a time; newer replaces older)
---------------------------------------------------------------------------
local current: { id: number, frame: Frame, options: number }? = nil

local function answer(id: number, index: number?, text: string?)
	remote:FireServer("answer", id, index, text)
	if current and current.id == id then
		current.frame:Destroy()
		current = nil
	end
end

local function ask(id: number, spec: any)
	if current then current.frame:Destroy(); current = nil end
	local options = spec.options or {}
	local frame = Instance.new("Frame")
	frame.Name = "Menu"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, 0, 0.55, 0)
	frame.Size = UDim2.new(0, 520, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
	frame.BackgroundTransparency = 0.05
	corner(frame, 14)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 196, 64)
	stroke.Thickness = 2
	stroke.Parent = frame
	local pad = Instance.new("UIPadding")
	for _, k in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(pad :: any)[k] = UDim.new(0, 14)
	end
	pad.Parent = frame
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 8)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = frame

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 22
	title.TextColor3 = Color3.fromRGB(255, 196, 64)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = tostring(spec.title or "")
	title.Parent = frame

	if spec.body and spec.body ~= "" then
		local body = Instance.new("TextLabel")
		body.LayoutOrder = 2
		body.Size = UDim2.new(1, 0, 0, 0)
		body.AutomaticSize = Enum.AutomaticSize.Y
		body.BackgroundTransparency = 1
		body.Font = Enum.Font.Gotham
		body.TextSize = 17
		body.TextWrapped = true
		body.TextColor3 = Color3.fromRGB(225, 228, 235)
		body.TextXAlignment = Enum.TextXAlignment.Left
		body.Text = tostring(spec.body)
		body.Parent = frame
	end

	local box: TextBox? = nil
	if type(spec.input) == "table" then
		local b = Instance.new("TextBox")
		b.LayoutOrder = 3
		b.Size = UDim2.new(1, 0, 0, 44)
		b.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.PlaceholderText = tostring(spec.input.placeholder or "")
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 20
		b.Text = ""
		b.ClearTextOnFocus = false
		corner(b, 8)
		b.Parent = frame
		box = b
	end

	for i, text in options do
		local btn = Instance.new("TextButton")
		btn.LayoutOrder = 10 + i
		btn.Size = UDim2.new(1, 0, 0, 48) -- big enough for a thumb
		btn.BackgroundColor3 = Color3.fromRGB(44, 50, 66)
		btn.AutoButtonColor = true
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 18
		btn.TextWrapped = true
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Text = (if UserInputService.KeyboardEnabled and i <= 9 then ("[%d]  "):format(i) else "") .. tostring(text)
		corner(btn, 8)
		btn.Parent = frame
		btn.Activated:Connect(function()
			answer(id, i, if box then box.Text else nil)
		end)
	end

	if spec.timeout then
		local bar = Instance.new("Frame")
		bar.LayoutOrder = 99
		bar.Size = UDim2.new(1, 0, 0, 5)
		bar.BackgroundColor3 = Color3.fromRGB(255, 196, 64)
		bar.BorderSizePixel = 0
		bar.Parent = frame
		TweenService:Create(bar, TweenInfo.new(tonumber(spec.timeout) or 30, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 5) }):Play()
	end
	frame.Parent = gui
	current = { id = id, frame = frame, options = #options }
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not current then return end
	local n = input.KeyCode.Value - Enum.KeyCode.One.Value + 1
	if n >= 1 and n <= 9 and n <= current.options then
		local box = current.frame:FindFirstChildOfClass("TextBox")
		answer(current.id, n, if box then box.Text else nil)
	end
end)

---------------------------------------------------------------------------
-- waypoints (local-only anchor parts with a billboard + distance)
---------------------------------------------------------------------------
local waypoints: { [string]: { part: BasePart, label: TextLabel, text: string } } = {}
local function setWaypoint(name: string, pos: Vector3?, text: string?)
	local w = waypoints[name]
	if w then w.part:Destroy(); waypoints[name] = nil end
	if typeof(pos) ~= "Vector3" then return end
	local part = Instance.new("Part")
	part.Name = "Waypoint_" .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.Position = pos + Vector3.new(0, 4, 0)
	local bb = Instance.new("BillboardGui")
	bb.AlwaysOnTop = true
	bb.Size = UDim2.new(0, 190, 0, 50)
	bb.MaxDistance = 1e5
	bb.Parent = part
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextSize = 16
	l.TextColor3 = Color3.fromRGB(255, 210, 80)
	l.TextStrokeTransparency = 0.3
	l.Parent = bb
	part.Parent = workspace
	waypoints[name] = { part = part, label = l, text = text or "Objective" }
end
task.spawn(function()
	while true do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		for _, w in waypoints do
			local d = if root then (w.part.Position - root.Position).Magnitude else 0
			w.label.Text = ("▼ %s\n%d studs"):format(w.text, math.floor(d))
		end
		task.wait(0.3)
	end
end)

remote.OnClientEvent:Connect(function(kind, a, b, c)
	if kind == "waypoint" then
		setWaypoint(tostring(a), b, if c ~= nil then tostring(c) else nil)
		return
	end
	if kind == "notice" then
		notice(tostring(a), tonumber(b), if typeof(c) == "Color3" then c else nil)
	elseif kind == "ask" then
		ask(a, b)
	elseif kind == "close" then
		if current and current.id == a then current.frame:Destroy(); current = nil end
	elseif kind == "tag" then
		setTag(tostring(a), if b ~= nil then tostring(b) else nil)
	end
end)
