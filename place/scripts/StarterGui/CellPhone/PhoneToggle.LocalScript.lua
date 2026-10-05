-- PhoneToggle (v196, mobile mode v207)
-- Slides the cell phone off-screen and back. The phone keeps working while
-- hidden (timers, notifications).
--   Desktop: button under the phone at the bottom of the screen, or press N.
--   Touch (phones/tablets): the bottom corners belong to the thumbstick and the
--   jump button, so the phone starts put away, a round phone button sits on the
--   right edge above the jump button, and the open phone is centred on screen
--   (sized to the screen) with its own close button.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local gui = script.Parent
local outline = gui:WaitForChild("Outline")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local KEY = Enum.KeyCode.N
local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local mobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- desktop layout, as authored
local DESK_POS = outline.Position
local DESK_SIZE = outline.Size
local DESK_ANCHOR = outline.AnchorPoint

local hidden = if player:GetAttribute("PhoneHidden") ~= nil then player:GetAttribute("PhoneHidden") == true else mobile

local function corner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

-- desktop: "Hide phone [N]" bar under the phone
local button = Instance.new("TextButton")
button.Name = "PhoneToggleButton"
button.AnchorPoint = Vector2.new(0.5, 1)
button.Size = UDim2.new(0, 120, 0, 26)
button.BackgroundColor3 = Color3.fromRGB(24, 26, 30)
button.BackgroundTransparency = 0.15
button.TextColor3 = Color3.fromRGB(235, 235, 235)
button.Font = Enum.Font.GothamBold
button.TextSize = 13
button.AutoButtonColor = true
button.ZIndex = 10
button.Parent = gui
corner(button, UDim.new(0, 8))

-- touch: round phone button on the right edge, clear of the jump button
local icon = Instance.new("TextButton")
icon.Name = "PhoneMobileButton"
icon.AnchorPoint = Vector2.new(1, 0.5)
icon.Position = UDim2.new(1, -12, 0.38, 0)
icon.Size = UDim2.fromOffset(54, 54)
icon.BackgroundColor3 = Color3.fromRGB(24, 26, 30)
icon.BackgroundTransparency = 0.1
icon.TextColor3 = Color3.fromRGB(240, 240, 240)
icon.Font = Enum.Font.GothamBold
icon.TextScaled = true
icon.Text = "📱"
icon.AutoButtonColor = true
icon.ZIndex = 10
icon.Parent = gui
corner(icon, UDim.new(1, 0))
local iconPad = Instance.new("UIPadding")
iconPad.PaddingTop = UDim.new(0, 9)
iconPad.PaddingBottom = UDim.new(0, 9)
iconPad.Parent = icon
local iconStroke = Instance.new("UIStroke")
iconStroke.Color = Color3.fromRGB(255, 255, 255)
iconStroke.Transparency = 0.6
iconStroke.Thickness = 1.5
iconStroke.Parent = icon

-- touch: close button on the open phone's top-right corner
local close = Instance.new("TextButton")
close.Name = "PhoneCloseButton"
close.AnchorPoint = Vector2.new(0.5, 0.5)
close.Position = UDim2.new(1, -4, 0, 4)
close.Size = UDim2.fromOffset(40, 40)
close.BackgroundColor3 = Color3.fromRGB(190, 45, 45)
close.TextColor3 = Color3.new(1, 1, 1)
close.Font = Enum.Font.GothamBlack
close.TextSize = 20
close.Text = "X"
close.ZIndex = 20
close.Parent = outline
corner(close, UDim.new(1, 0))

local function mobileLayout()
	-- a portrait phone that fits a landscape phone screen with room to spare
	local vp = camera.ViewportSize
	local h = math.floor(math.min(vp.Y * 0.82, 560))
	local w = math.floor(math.min(h * 0.62, vp.X * 0.5))
	outline.AnchorPoint = Vector2.new(0.5, 0.5)
	outline.Size = UDim2.fromOffset(w, h)
end

local function shownPos(): UDim2
	return if mobile then UDim2.new(0.5, 0, 0.5, 0) else DESK_POS
end

local function hiddenPos(): UDim2
	if mobile then
		return UDim2.new(0.5, 0, 1.6, 0)
	end
	return UDim2.new(DESK_POS.X.Scale, DESK_POS.X.Offset, 1.02, 0)
end

local function place()
	if mobile then
		button.Visible = false
		close.Visible = not hidden
		icon.Visible = outline.Visible
		icon.BackgroundColor3 = if hidden then Color3.fromRGB(24, 26, 30) else Color3.fromRGB(40, 90, 160)
	else
		close.Visible = false
		icon.Visible = false
		-- sits centred under the phone, at the bottom edge of the screen
		local x = DESK_POS.X.Scale + DESK_SIZE.X.Scale / 2
		button.Position = UDim2.new(x, DESK_POS.X.Offset + DESK_SIZE.X.Offset / 2, 1, -4)
		button.Text = if hidden then "Phone  [N]" else "Hide phone  [N]"
		button.Visible = outline.Visible
	end
end

local function apply(animate: boolean)
	if mobile then
		mobileLayout()
	else
		outline.AnchorPoint = DESK_ANCHOR
		outline.Size = DESK_SIZE
	end
	local goal = if hidden then hiddenPos() else shownPos()
	if animate then
		TweenService:Create(outline, tweenInfo, { Position = goal }):Play()
	else
		outline.Position = goal
	end
	player:SetAttribute("PhoneHidden", hidden)
	place()
end

local function toggle()
	hidden = not hidden
	apply(true)
end

button.MouseButton1Click:Connect(toggle)
icon.MouseButton1Click:Connect(toggle)
close.MouseButton1Click:Connect(function()
	if not hidden then
		toggle()
	end
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= KEY then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	if outline.Visible then
		toggle()
	end
end)
-- The start menu reveals the phone after "Play"; show the buttons with it.
outline:GetPropertyChangedSignal("Visible"):Connect(place)
camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
	if mobile then
		apply(false)
	end
end)
-- A tablet with a keyboard attached (or detached) switches modes.
local function refreshMode()
	local nowMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	if nowMobile ~= mobile then
		mobile = nowMobile
		apply(false)
	end
end
UserInputService.LastInputTypeChanged:Connect(refreshMode)

apply(false)

-- v212: from the moment you're arrested until you're released there is no
-- cell phone (arrest, transport, intake, booking, prison).
local function inCustody(): boolean
	if player:GetAttribute("BookingState") ~= nil or player:GetAttribute("CustodyPhase") ~= nil
		or player:GetAttribute("SentenceEnd") ~= nil or player:GetAttribute("CustodyOwner") ~= nil then
		return true
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum:GetAttribute("PoliceCuffed") == true
end
local function refreshCustody()
	gui.Enabled = not inCustody()
end
player.AttributeChanged:Connect(function(name)
	if name == "BookingState" or name == "CustodyPhase" or name == "SentenceEnd" or name == "CustodyOwner" then
		refreshCustody()
	end
end)
local function watchCharacter(char: Model)
	local hum = char:WaitForChild("Humanoid", 10)
	if hum then
		hum:GetAttributeChangedSignal("PoliceCuffed"):Connect(refreshCustody)
	end
	refreshCustody()
end
if player.Character then
	task.spawn(watchCharacter, player.Character)
end
player.CharacterAdded:Connect(watchCharacter)
refreshCustody()
