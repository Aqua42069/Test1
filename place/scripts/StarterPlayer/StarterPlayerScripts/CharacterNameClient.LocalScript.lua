-- CharacterNameClient (v286s): the "who are you?" screen - on your first visit, and again after
-- your character dies in prison (a new name, never one you've used). Server: CharacterNames.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("CharacterName", 60)
if not remote then return end

local gui: ScreenGui? = nil

local function close()
	if gui then gui:Destroy() gui = nil end
end

local function open()
	if gui then return end
	local past = {}
	pcall(function() past = HttpService:JSONDecode(player:GetAttribute("PastCharacterNames") or "[]") end)
	local again = #past > 0

	local g = Instance.new("ScreenGui")
	g.Name = "CharacterNameGui"
	g.ResetOnSpawn = false
	g.DisplayOrder = 1000
	g.IgnoreGuiInset = true
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui = g

	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.25
	shade.Active = true
	shade.Parent = g

	local box = Instance.new("Frame")
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.new(0.9, 0, 0, 260)
	box.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	box.Parent = shade
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(440, 260)
	cap.Parent = box
	Instance.new("UICorner").Parent = box
	local pad = Instance.new("UIPadding")
	for _, k in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do (pad :: any)[k] = UDim.new(0, 16) end
	pad.Parent = box
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = box

	local function label(text: string, size: number, order: number, color: Color3?): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, 0, 0, size + 8)
		l.Font = Enum.Font.GothamBold
		l.TextSize = size
		l.TextWrapped = true
		l.TextColor3 = color or Color3.new(1, 1, 1)
		l.Text = text
		l.LayoutOrder = order
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.Parent = box
		return l
	end
	label(if again then "Your character is dead." else "Welcome to Las Vegas.", 22, 1)
	label(if again then ("%s is gone. Who are you now? (You can't use a name you've had before.)"):format(tostring(past[#past]))
		else "What's your name? First and last - it's who you are in this city.", 15, 2, Color3.fromRGB(200, 200, 210)).Font = Enum.Font.Gotham

	local input = Instance.new("TextBox")
	input.Size = UDim2.new(1, 0, 0, 40)
	input.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	input.TextColor3 = Color3.new(1, 1, 1)
	input.PlaceholderText = "e.g. Tony Marino"
	input.Text = ""
	input.ClearTextOnFocus = false
	input.Font = Enum.Font.Gotham
	input.TextSize = 18
	input.LayoutOrder = 3
	Instance.new("UICorner").Parent = input
	input.Parent = box

	local err = label("", 14, 4, Color3.fromRGB(255, 110, 110))
	err.Font = Enum.Font.Gotham

	local go = Instance.new("TextButton")
	go.Size = UDim2.new(1, 0, 0, 40)
	go.BackgroundColor3 = Color3.fromRGB(60, 140, 80)
	go.TextColor3 = Color3.new(1, 1, 1)
	go.Font = Enum.Font.GothamBold
	go.TextSize = 18
	go.Text = "That's me"
	go.LayoutOrder = 5
	Instance.new("UICorner").Parent = go
	go.Parent = box

	local busy = false
	local function submit()
		if busy then return end
		busy = true
		go.Text = "Checking..."
		local ok, res, msg = pcall(remote.InvokeServer, remote, input.Text)
		busy = false
		go.Text = "That's me"
		if ok and res == true then
			close()
		else
			err.Text = if ok then tostring(msg or "Try another name.") else "Couldn't reach the server - try again."
		end
	end
	go.Activated:Connect(submit)
	input.FocusLost:Connect(function(enter) if enter then submit() end end)
	g.Parent = player:WaitForChild("PlayerGui")
end

local function check()
	if player:GetAttribute("NeedsCharacterName") == true then open() else close() end
end
player:GetAttributeChangedSignal("NeedsCharacterName"):Connect(check)
check()
