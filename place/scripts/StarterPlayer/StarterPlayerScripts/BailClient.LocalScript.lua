-- BailClient (v254): the bail decision at Police HQ booking.
-- Pay it yourself, call a bondsman (10% fee, not refunded) or stay in custody.
-- Shows the court date countdown after release.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local folder = ReplicatedStorage:WaitForChild("BailRemotes", 60)
if not folder then
	return
end
local remote = folder:WaitForChild("Offer") :: RemoteEvent

local gui = Instance.new("ScreenGui")
gui.Name = "Bail"
gui.ResetOnSpawn = false
gui.DisplayOrder = 30
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.55)
panel.Size = UDim2.fromOffset(380, 230)
panel.BackgroundColor3 = Color3.fromRGB(22, 26, 34)
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
local pad = Instance.new("UIPadding", panel)
pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 14), UDim.new(0, 14), UDim.new(0, 12), UDim.new(0, 12)

local function label(text: string, y: number, size: number, bold: boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromOffset(0, y)
	l.Size = UDim2.new(1, 0, 0, size)
	l.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	l.TextSize = size - 4
	l.TextColor3 = Color3.fromRGB(235, 235, 240)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.Text = text
	l.Parent = panel
	return l
end

local title = label("BAIL HEARING", 0, 24, true)
local body = label("", 30, 40)
local timer = label("", 72, 20)
timer.TextColor3 = Color3.fromRGB(255, 190, 90)

local function button(text: string, y: number, color: Color3, choice: string): TextButton
	local b = Instance.new("TextButton")
	b.Position = UDim2.fromOffset(0, y)
	b.Size = UDim2.new(1, 0, 0, 34)
	b.BackgroundColor3 = color
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 15
	b.Text = text
	b.Parent = panel
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	b.Activated:Connect(function()
		remote:FireServer(choice)
	end)
	return b
end

local payBtn = button("", 100, Color3.fromRGB(40, 140, 80), "self")
local bondBtn = button("", 140, Color3.fromRGB(60, 90, 160), "bondsman")
button("Stay in custody", 180, Color3.fromRGB(110, 50, 50), "stay")

local closesAt = 0
remote.OnClientEvent:Connect(function(offer)
	if type(offer) ~= "table" then
		panel.Visible = false
		return
	end
	body.Text = ("Bail is set at $%d for: %s"):format(offer.amount, tostring(offer.charges or "your charges"))
	payBtn.Text = ("Pay $%d (refunded when you show up for court)"):format(offer.amount)
	bondBtn.Text = ("Bail bondsman - $%d fee, not refunded"):format(offer.fee)
	closesAt = os.clock() + (offer.seconds or 30)
	panel.Visible = true
end)

-- court date countdown, top of the screen
local court = Instance.new("TextLabel")
court.AnchorPoint = Vector2.new(0.5, 0)
court.Position = UDim2.new(0.5, 0, 0, 6)
court.Size = UDim2.fromOffset(420, 24)
court.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
court.BackgroundTransparency = 0.25
court.TextColor3 = Color3.fromRGB(255, 220, 140)
court.Font = Enum.Font.GothamMedium
court.TextSize = 15
court.Visible = false
court.Parent = gui
Instance.new("UICorner", court).CornerRadius = UDim.new(0, 6)

RunService.Heartbeat:Connect(function()
	if panel.Visible then
		timer.Text = ("Decide in %ds - or someone can post it for you at the HQ front desk"):format(math.max(0, math.ceil(closesAt - os.clock())))
	end
	local due = tonumber(player:GetAttribute("CourtDateAt"))
	if due then
		local left = due - os.time()
		court.Visible = true
		court.Text = if left > 0 then ("Court date in %d:%02d - Police HQ front desk"):format(left // 60, left % 60)
			else "COURT IS NOW - go to the Police HQ front desk"
	else
		court.Visible = false
	end
end)
