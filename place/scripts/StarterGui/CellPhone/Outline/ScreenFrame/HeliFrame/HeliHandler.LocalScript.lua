-- Helicopter app (v228). Buy a helicopter once and keep it; SPAWN puts it on
-- open ground next to you, STORE puts it away. Everything (prices, money,
-- ownership, where it can land) is decided by ServerScriptService.HelicopterServer.
-- Big rows and buttons so it works with a thumb on a phone.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local frame = script.Parent
for _, child in ipairs(frame:GetChildren()) do
	if child:IsA("GuiObject") and child.Name ~= "Title" and child.Name ~= "Home" then
		child.Visible = false
	end
end

local shop = ReplicatedStorage:WaitForChild("Helicopters"):WaitForChild("Shop") :: RemoteFunction

local list = Instance.new("ScrollingFrame")
list.Name = "HeliList"
list.Position = UDim2.new(0.03, 0, 0.16, 0)
list.Size = UDim2.new(0.94, 0, 0.66, 0)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 6
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.ScrollingDirection = Enum.ScrollingDirection.Y
list.Parent = frame
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

local status = Instance.new("TextLabel")
status.Name = "HeliStatus"
status.Position = UDim2.new(0.03, 0, 0.83, 0)
status.Size = UDim2.new(0.94, 0, 0.06, 0)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(255, 255, 255)
status.TextScaled = true
status.Font = Enum.Font.GothamMedium
status.Text = ""
status.Parent = frame

local storeButton = Instance.new("TextButton")
storeButton.Name = "StoreHeli"
storeButton.Position = UDim2.new(0.2, 0, 0.9, 0)
storeButton.Size = UDim2.new(0.6, 0, 0.07, 0)
storeButton.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
storeButton.TextColor3 = Color3.new(1, 1, 1)
storeButton.Font = Enum.Font.GothamBold
storeButton.TextScaled = true
storeButton.Text = "STORE HELICOPTER"
storeButton.Visible = false
storeButton.Parent = frame
Instance.new("UICorner").Parent = storeButton

local busy = false
local refresh -- forward

local function say(text: string)
	status.Text = text
	task.delay(4, function()
		if status.Text == text then
			status.Text = ""
		end
	end)
end

local function act(action: string, name: string?)
	if busy then
		return
	end
	busy = true
	say("...")
	local ok, success, message = pcall(shop.InvokeServer, shop, action, name)
	say(if ok then tostring(message) else "Hangar is offline")
	busy = false
	refresh()
end

local function row(h, order: number)
	local r = Instance.new("Frame")
	r.Name = h.name
	r.LayoutOrder = order
	r.Size = UDim2.new(1, -8, 0, 58)
	r.BackgroundColor3 = Color3.fromRGB(30, 34, 40)
	r.BackgroundTransparency = 0.1
	r.Parent = list
	Instance.new("UICorner").Parent = r
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Position = UDim2.new(0.04, 0, 0.06, 0)
	name.Size = UDim2.new(0.58, 0, 0.5, 0)
	name.Font = Enum.Font.GothamBold
	name.TextScaled = true
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = Color3.new(1, 1, 1)
	name.Text = h.name
	name.Parent = r
	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.new(0.04, 0, 0.56, 0)
	sub.Size = UDim2.new(0.58, 0, 0.36, 0)
	sub.Font = Enum.Font.Gotham
	sub.TextScaled = true
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextColor3 = Color3.fromRGB(190, 200, 210)
	sub.Text = ("%d mph  -  %d seats  -  %s"):format(math.floor(h.speed * 0.7), h.seats, if h.owned then "OWNED" else "$" .. h.price)
	sub.Parent = r
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(0.97, 0, 0.5, 0)
	b.Size = UDim2.new(0.32, 0, 0.74, 0)
	b.Font = Enum.Font.GothamBlack
	b.TextScaled = true
	b.TextColor3 = Color3.new(1, 1, 1)
	if h.out then
		b.Text = "OUT"
		b.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
		b.AutoButtonColor = false
	elseif h.owned then
		b.Text = "SPAWN"
		b.BackgroundColor3 = Color3.fromRGB(40, 130, 70)
		b.Activated:Connect(function()
			act("spawn", h.name)
		end)
	else
		b.Text = "BUY"
		b.BackgroundColor3 = Color3.fromRGB(30, 90, 170)
		local armed = false
		b.Activated:Connect(function()
			-- tap once to see the price, again to pay
			if not armed then
				armed = true
				b.Text = "$" .. h.price .. "?"
				task.delay(3, function()
					if armed and b.Parent then
						armed = false
						b.Text = "BUY"
					end
				end)
				return
			end
			armed = false
			act("buy", h.name)
		end)
	end
	b.Parent = r
	Instance.new("UICorner").Parent = b
	local pad = Instance.new("UITextSizeConstraint")
	pad.MaxTextSize = 18
	pad.Parent = b
end

refresh = function()
	local ok, catalog = pcall(shop.InvokeServer, shop, "catalog")
	if not ok or type(catalog) ~= "table" then
		return
	end
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local anyOut = false
	for i, h in ipairs(catalog) do
		row(h, i)
		anyOut = anyOut or h.out
	end
	storeButton.Visible = anyOut
end

storeButton.Activated:Connect(function()
	act("store")
end)

frame:GetPropertyChangedSignal("Visible"):Connect(function()
	if frame.Visible then
		refresh()
	end
end)
task.spawn(refresh)
