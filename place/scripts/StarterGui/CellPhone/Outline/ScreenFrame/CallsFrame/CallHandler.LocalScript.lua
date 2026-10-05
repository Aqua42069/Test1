-- Messaging app (rewritten). Pick a player, type in the box at the bottom and
-- press Enter. Messages are filtered and delivered by EconomyServer.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local frame = script.Parent
local example = script:WaitForChild("Example")
local scroller = frame:WaitForChild("Scroller")
local chat = frame:WaitForChild("CurrentChat")
local back = frame:WaitForChild("Back")
local homeIcon = frame.Parent:WaitForChild("HomeFrame"):WaitForChild("Calls")
local privateChat = ReplicatedStorage:WaitForChild("Events"):WaitForChild("PrivateChat")

local ROW = 30
local LINE = 22
local current = nil

back.Text = "Back"

-- Input box under the conversation
chat.Size = UDim2.new(1, 0, 0.7, -48)
local input = Instance.new("TextBox")
input.Name = "MessageBox"
input.PlaceholderText = "Type a message, press Enter"
input.Text = ""
input.ClearTextOnFocus = false
input.TextScaled = true
input.Font = Enum.Font.SourceSans
input.TextXAlignment = Enum.TextXAlignment.Left
input.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
input.TextColor3 = Color3.new(0, 0, 0)
input.Position = UDim2.new(0, 0, 1, -26)
input.Size = UDim2.new(1, 0, 0, 26)
input.Visible = false
input.ZIndex = back.ZIndex
input.Parent = frame

local function bump(notification)
	notification.Visible = true
	notification.Number.Text = tostring(math.min(99, (tonumber(notification.Number.Text) or 0) + 1))
end

local function showConversation(lines)
	chat:ClearAllChildren()
	for i, text in ipairs(lines) do
		local label = example.PersonName:Clone()
		label.Name = "Line" .. i
		label.Text = text
		label.Font = Enum.Font.SourceSans
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextWrapped = true
		label.Position = UDim2.new(0, 4, 0, (i - 1) * LINE)
		label.Size = UDim2.new(1, -20, 0, LINE)
		label.Parent = chat
	end
	chat.CanvasSize = UDim2.new(0, 0, 0, LINE * #lines)
	chat.CanvasPosition = Vector2.new(0, math.max(0, LINE * #lines - chat.AbsoluteSize.Y))
end

local function openChat(name)
	current = name
	scroller.Visible = false
	chat.Visible = true
	back.Visible = true
	input.Visible = true
	showConversation({})
	local row = scroller:FindFirstChild(name)
	if row then
		row.Notification.Visible = false
		row.Notification.Number.Text = "0"
	end
	privateChat:FireServer(nil, name) -- ask for the conversation so far
end

local function closeChat()
	current = nil
	scroller.Visible = true
	chat.Visible = false
	back.Visible = false
	input.Visible = false
end

local function rebuildList()
	for _, child in ipairs(scroller:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local row = example:Clone()
			row.Name = other.Name
			row.PersonName.Text = "Message " .. other.Name
			row.PersonImage.Image = "rbxthumb://type=AvatarHeadShot&id=" .. other.UserId .. "&w=150&h=150"
			row.Position = UDim2.new(0, 0, 0, ROW * count)
			row.Size = UDim2.new(1, -16, 0, ROW)
			row.Notification.Visible = false
			row.Visible = true
			row.Parent = scroller
			row.Call.MouseButton1Click:Connect(function()
				openChat(other.Name)
			end)
			count += 1
		end
	end
	if count == 0 then
		local row = example:Clone()
		row.Name = "Empty"
		row.PersonName.Text = "Nobody else is online"
		row.PersonImage.Visible = false
		row.Call.Visible = false
		row.Size = UDim2.new(1, -16, 0, ROW)
		row.Visible = true
		row.Parent = scroller
	end
	scroller.CanvasSize = UDim2.new(0, 0, 0, ROW * math.max(count, 1))
	if current and not Players:FindFirstChild(current) then
		closeChat()
	end
end

privateChat.OnClientEvent:Connect(function(lines, otherName)
	if type(lines) ~= "table" then
		return
	end
	if otherName == current and frame.Visible then
		showConversation(lines)
		return
	end
	-- Message for a conversation that isn't open: show badges.
	if #lines > 0 and not lines[#lines]:find("^" .. player.Name .. ": ") then
		local row = scroller:FindFirstChild(tostring(otherName))
		if row then
			bump(row.Notification)
		end
		if not frame.Visible then
			bump(homeIcon.Notification)
		end
	end
end)

input.FocusLost:Connect(function(enterPressed)
	if enterPressed and current and input.Text:match("%S") then
		privateChat:FireServer(input.Text, current)
		input.Text = ""
	end
end)

back.MouseButton1Click:Connect(closeChat)
frame:WaitForChild("Home").MouseButton1Click:Connect(closeChat)
Players.PlayerAdded:Connect(rebuildList)
Players.PlayerRemoving:Connect(function()
	task.defer(rebuildList)
end)
closeChat()
rebuildList()
