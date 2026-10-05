-- NPC conversations (rewritten).
-- Talk to an NPC by clicking them or with the "Talk" prompt (E) when close.
-- The server drives the conversation through each NPC's "Speech" RemoteEvent:
--   server -> client: FireClient(player, line, options, displayName)
--                     options = { {id, text}, ... }
--   client -> server: FireServer("StartConversation") or FireServer(optionId)
-- The old format (FireClient(player, options)) is still understood.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local chatGui = script.Parent:WaitForChild("Chatter")
local holder = chatGui:WaitForChild("Holder")
local example = chatGui:WaitForChild("Example")

local CHAT_DIST = 12
local ROW_HEIGHT = 0.06

holder.AnchorPoint = Vector2.new(0.5, 1)
holder.Position = UDim2.new(0.5, 0, 0.85, 0)

local function myRoot()
	local character = player.Character
	return character and (character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso"))
end

local function rootOf(model)
	return model:FindFirstChild("Torso")
		or model:FindFirstChild("HumanoidRootPart")
		or model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart", true)
end

local function distanceTo(part)
	local root = myRoot()
	return (root and part) and (root.Position - part.Position).Magnitude or math.huge
end

local function npcFrom(target)
	local node = target
	while node and node ~= workspace do
		local speech = node:FindFirstChild("Speech")
		if node:IsA("Model") and speech and speech:IsA("RemoteEvent") then
			return node, speech
		end
		node = node.Parent
	end
	return nil
end

local activeNpc = nil

local function clear()
	holder:ClearAllChildren()
	activeNpc = nil
end

local function addRow(text, index, rows, clickable)
	local row = example:Clone()
	row.Text = text
	row.TextWrapped = true
	row.Size = UDim2.new(1, 0, 1 / rows, 0)
	row.Position = UDim2.new(0, 0, (index - 1) / rows, 0)
	row.Visible = true
	if not clickable then
		row.AutoButtonColor = false
		row.Active = false
		row.Font = Enum.Font.SourceSansItalic
	end
	row.Parent = holder
	return row
end

local function show(npc, speech, line, options, displayName)
	clear()
	activeNpc = npc
	local rows = #options + (line and 1 or 0)
	if rows == 0 then
		return
	end
	holder.Size = UDim2.new(0.4, 0, ROW_HEIGHT * rows, 0)

	local index = 0
	if line then
		index += 1
		addRow((displayName or npc.Name) .. ': "' .. line .. '"', index, rows, false)
	end
	for _, option in ipairs(options) do
		index += 1
		local button = addRow(option[2], index, rows, true)
		button.MouseButton1Click:Connect(function()
			clear()
			speech:FireServer(option[1])
		end)
	end

	-- Close the conversation if you walk away.
	local npcRoot = rootOf(npc)
	task.spawn(function()
		while activeNpc == npc do
			task.wait(0.2)
			if activeNpc == npc and distanceTo(npcRoot) > CHAT_DIST + 6 then
				clear()
			end
		end
	end)
end

local bound = {}
local function bind(speech)
	if bound[speech] or not speech:IsA("RemoteEvent") then
		return
	end
	local npc = speech.Parent
	if not (npc and npc:IsA("Model")) then
		return
	end
	bound[speech] = true
	speech.OnClientEvent:Connect(function(a, b, c)
		if type(a) == "table" then
			show(npc, speech, nil, a) -- old format: just the options
		else
			show(npc, speech, a, type(b) == "table" and b or {}, c)
		end
	end)
end

for _, obj in ipairs(workspace:GetDescendants()) do
	if obj.Name == "Speech" then
		bind(obj)
	end
end
workspace.DescendantAdded:Connect(function(obj)
	if obj.Name == "Speech" then
		task.defer(bind, obj)
	end
end)

local deb = false
mouse.Button1Down:Connect(function()
	if deb then
		return
	end
	local target = mouse.Target
	if not target or distanceTo(target) > CHAT_DIST then
		return
	end
	deb = true

	local activate = target.Parent and target.Parent:FindFirstChild("Activate")
	if activate and activate:IsA("RemoteEvent") then
		activate:FireServer(target.Name)
	else
		local npc, speech = npcFrom(target)
		if npc then
			bind(speech)
			speech:FireServer("StartConversation")
			task.wait(1)
		end
	end

	deb = false
end)
