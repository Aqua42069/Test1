-- StashClient (v255): the window for house safes, safe deposit boxes and buried
-- stashes (AssetFreeze), B to bury cash where you stand, and your own buried
-- stashes marked for you alone (nobody else's client knows where they are).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local uiEvent = ReplicatedStorage:WaitForChild("StashUI")
local actionFn = ReplicatedStorage:WaitForChild("StashAction")

local function money(n)
	local s = tostring(math.floor(n or 0))
	while true do
		local r, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		s = r
		if k == 0 then
			break
		end
	end
	return "$" .. s
end

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "StashGui"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 320, 0, 230)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
frame.Parent = gui
Instance.new("UICorner").Parent = frame

local function label(y, h, size, bold)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.new(0, 14, 0, y)
	l.Size = UDim2.new(1, -28, 0, h)
	l.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.Parent = frame
	return l
end

local title = label(10, 26, 20, true)
local contents = label(40, 20, 15)
local carrying = label(62, 20, 15)
local status = label(178, 40, 14)
status.TextColor3 = Color3.fromRGB(255, 210, 120)

local box = Instance.new("TextBox")
box.Position = UDim2.new(0, 14, 0, 92)
box.Size = UDim2.new(1, -28, 0, 32)
box.BackgroundColor3 = Color3.fromRGB(50, 50, 58)
box.TextColor3 = Color3.new(1, 1, 1)
box.PlaceholderText = "Amount"
box.Text = ""
box.Font = Enum.Font.Gotham
box.TextSize = 16
box.ClearTextOnFocus = false
box.Parent = frame
Instance.new("UICorner").Parent = box

local function button(x, w, text, color)
	local b = Instance.new("TextButton")
	b.Position = UDim2.new(0, x, 0, 134)
	b.Size = UDim2.new(0, w, 0, 36)
	b.BackgroundColor3 = color
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 15
	b.Text = text
	b.Parent = frame
	Instance.new("UICorner").Parent = b
	return b
end

local putButton = button(14, 92, "Put in", Color3.fromRGB(40, 120, 60))
local takeButton = button(114, 92, "Take out", Color3.fromRGB(40, 80, 140))
local closeButton = button(214, 92, "Close", Color3.fromRGB(90, 40, 40))

local current = nil -- info table from the server, or { kind = "bury" }

local function show(info, msg)
	current = info
	gui.Enabled = true
	status.Text = msg or ""
	if info.kind == "bury" then
		title.Text = "Bury a stash here"
		contents.Text = "Only you will know where it is."
		carrying.Text = "Carrying " .. money(player:FindFirstChild("Cash") and player.Cash.Value or 0)
		putButton.Text = "Bury"
		takeButton.Visible = false
		return
	end
	title.Text = info.title
	contents.Text = "Inside: " .. money(info.amount)
	carrying.Text = "Carrying " .. money(info.cash)
	takeButton.Visible = true
	if info.needsOpen then
		putButton.Text = "Open (" .. money(info.openFee) .. ")"
		takeButton.Visible = false
	else
		putButton.Text = "Put in"
	end
end

local busy = false
local function act(action)
	if busy or not current then
		return
	end
	busy = true
	local amount = tonumber((box.Text:gsub("[^%d]", ""))) or 0
	local ok, msg, info
	if current.kind == "bury" then
		ok, msg, info = actionFn:InvokeServer("bury", "stash", nil, amount)
	elseif action == "deposit" and current.needsOpen then
		ok, msg, info = actionFn:InvokeServer("openbox", current.kind, current.id, 0)
	else
		ok, msg, info = actionFn:InvokeServer(action, current.kind, current.id, amount)
	end
	if info then
		show(info, msg)
	else
		status.Text = msg or (if ok then "Done" else "Can't do that")
	end
	if ok then
		box.Text = ""
	end
	busy = false
end

putButton.MouseButton1Click:Connect(function()
	act("deposit")
end)
takeButton.MouseButton1Click:Connect(function()
	act("withdraw")
end)
closeButton.MouseButton1Click:Connect(function()
	gui.Enabled = false
	current = nil
end)

---------------------------------------------------------------------------
-- your buried stashes: a little mound and a prompt only you can see
---------------------------------------------------------------------------
local markers = Instance.new("Folder")
markers.Name = "MyStashes"
markers.Parent = workspace

local function drawStashes(list)
	markers:ClearAllChildren()
	for _, st in list or {} do
		local mound = Instance.new("Part")
		mound.Name = "Stash"
		mound.Anchored = true
		mound.CanCollide = false
		mound.CanQuery = false
		mound.Shape = Enum.PartType.Cylinder
		mound.Size = Vector3.new(0.4, 3, 3)
		mound.CFrame = CFrame.new(st.x, st.y + 0.1, st.z) * CFrame.Angles(0, 0, math.rad(90))
		mound.Color = Color3.fromRGB(95, 70, 45)
		mound.Material = Enum.Material.Ground
		mound.Parent = markers
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = "Dig up"
		pp.ObjectText = "Your stash (" .. money(st.amt) .. ")"
		pp.HoldDuration = 1
		pp.RequiresLineOfSight = false
		pp.MaxActivationDistance = 8
		pp.Parent = mound
		pp.Triggered:Connect(function()
			local ok, msg, info = actionFn:InvokeServer("info", "stash", st.id, 0)
			if ok and info then
				show(info, msg)
			end
		end)
	end
end

uiEvent.OnClientEvent:Connect(function(what, data)
	if what == "open" then
		show(data)
	elseif what == "stashes" then
		drawStashes(data)
	end
end)

-- B: bury cash where you stand
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.B then
		return
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.SeatPart or player:GetAttribute("CustodyStage") then
		return
	end
	show({ kind = "bury" })
end)
