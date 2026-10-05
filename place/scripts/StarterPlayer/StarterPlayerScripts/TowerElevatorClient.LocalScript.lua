-- TowerElevatorClient (v287): the Premier Counsel floor directory. The server (Workspace.
-- PremierCounsel.Elevators) opens it when you press an elevator call panel; pick a floor, the
-- screen dims for the ride and you step out on that floor.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("TowerElevator", 60) :: RemoteEvent?
if not remote then return end

local GOLD = Color3.fromRGB(201, 163, 82)
local INK = Color3.fromRGB(18, 18, 22)

local gui = Instance.new("ScreenGui")
gui.Name = "TowerElevator"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 50
gui.Parent = player:WaitForChild("PlayerGui")

local panel: Frame? = nil
local function closePanel()
	if panel then panel:Destroy() panel = nil end
end

local function openPanel(data: any)
	closePanel()
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.new(0.9, 0, 0.8, 0)
	f.BackgroundColor3 = INK
	f.BorderSizePixel = 0
	f.Parent = gui
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(380, 620)
	cap.Parent = f
	Instance.new("UICorner").Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = GOLD
	stroke.Thickness = 1.5
	stroke.Parent = f
	panel = f

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 54)
	title.Font = Enum.Font.Garamond
	title.TextSize = 26
	title.TextColor3 = GOLD
	title.Text = tostring(data.title or "PREMIER COUNSEL") .. "\nSelect a floor"
	title.Parent = f

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -8, 0, 8)
	close.Size = UDim2.fromOffset(32, 32)
	close.BackgroundTransparency = 1
	close.Font = Enum.Font.GothamBold
	close.TextSize = 20
	close.TextColor3 = GOLD
	close.Text = "X"
	close.Parent = f
	close.Activated:Connect(closePanel)

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.new(0, 12, 0, 62)
	list.Size = UDim2.new(1, -24, 1, -74)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = GOLD
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = f
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 6)
	lay.Parent = list

	for i, fl in data.floors or {} do
		local here = fl.level == data.current
		local b = Instance.new("TextButton")
		b.LayoutOrder = i
		b.Size = UDim2.new(1, -6, 0, 40)
		b.BackgroundColor3 = if here then Color3.fromRGB(60, 50, 30) else Color3.fromRGB(34, 34, 40)
		b.AutoButtonColor = not here
		b.Font = Enum.Font.Gotham
		b.TextSize = 16
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.TextColor3 = if here then GOLD else Color3.fromRGB(230, 228, 222)
		b.Text = ("   %2d    %s%s"):format(fl.level, fl.name, if here then "   (you are here)" else "")
		Instance.new("UICorner").Parent = b
		b.Parent = list
		if not here then
			b.Activated:Connect(function()
				closePanel()
				remote:FireServer("go", fl.level)
			end)
		end
	end
end

-- the ride: the screen dims, the floor's name, then back
local veil = Instance.new("Frame")
veil.Size = UDim2.fromScale(1, 1)
veil.BackgroundColor3 = Color3.new(0, 0, 0)
veil.BackgroundTransparency = 1
veil.Visible = false
veil.Parent = gui
local veilText = Instance.new("TextLabel")
veilText.Size = UDim2.fromScale(1, 1)
veilText.BackgroundTransparency = 1
veilText.Font = Enum.Font.Garamond
veilText.TextSize = 30
veilText.TextColor3 = GOLD
veilText.TextTransparency = 1
veilText.Parent = veil

remote.OnClientEvent:Connect(function(action, data)
	if action == "open" then
		openPanel(data)
	elseif action == "riding" then
		veil.Visible = true
		veilText.Text = ("Going to %d  ·  %s"):format(data.level, data.name)
		TweenService:Create(veil, TweenInfo.new(0.5), { BackgroundTransparency = 0.15 }):Play()
		TweenService:Create(veilText, TweenInfo.new(0.5), { TextTransparency = 0 }):Play()
	elseif action == "arrived" then
		veilText.Text = ("%d  ·  %s"):format(data.level, data.name)
		task.wait(0.4)
		TweenService:Create(veil, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
		local t = TweenService:Create(veilText, TweenInfo.new(0.6), { TextTransparency = 1 })
		t:Play()
		t.Completed:Wait()
		veil.Visible = false
	end
end)
