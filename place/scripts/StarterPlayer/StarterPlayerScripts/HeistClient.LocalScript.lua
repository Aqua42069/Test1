-- HeistClient: the robber's side of a bank job (BankServer runs the rules).
--   * Lockpick tool: click a staff door to start picking it
--   * Computer hack: letter columns scroll; press Unlock (or Space) when the
--     RED letter sits in the bright band. Beat every column to get the code.
--   * Vault keypad: type the code
--   * Inside the open vault: choose how much to rob; stay inside until done
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local heist = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Heist")

local DARK = Color3.fromRGB(28, 34, 44)
local LIGHT = Color3.fromRGB(215, 218, 222)
local GREEN = Color3.fromRGB(60, 150, 70)
local RED = Color3.fromRGB(220, 40, 40)

local screen = Instance.new("ScreenGui")
screen.Name = "HeistGui"
screen.ResetOnSpawn = false
screen.DisplayOrder = 15
screen.Parent = player:WaitForChild("PlayerGui")

local function make(className, props, parent)
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function panel(width, height)
	return make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(width, 0, height, 0),
		BackgroundColor3 = DARK,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
	}, screen)
end

local function textButton(text, parent, props)
	local b = make("TextButton", {
		Text = text,
		Font = Enum.Font.SourceSansBold,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = GREEN,
		BorderSizePixel = 0,
		AutoButtonColor = true,
	}, parent)
	for k, v in pairs(props or {}) do
		b[k] = v
	end
	return b
end

local function closeButton(parent, onClose)
	local x = textButton("X", parent, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 4),
		Size = UDim2.new(0, 28, 0, 28),
		BackgroundColor3 = RED,
	})
	x.MouseButton1Click:Connect(onClose)
	return x
end

---------------------------------------------------------------------------
-- Lockpick: click the door you want to pick
---------------------------------------------------------------------------
local bound = {}
local function bindTool(tool)
	if bound[tool] or tool.Name ~= "Lockpick" then
		return
	end
	bound[tool] = true
	tool.Activated:Connect(function()
		local target = mouse.Target
		if target then
			heist:FireServer("UseLockpick", target)
		end
	end)
end
local function watch(container)
	for _, c in ipairs(container:GetChildren()) do
		if c:IsA("Tool") then
			bindTool(c)
		end
	end
	container.ChildAdded:Connect(function(c)
		if c:IsA("Tool") then
			bindTool(c)
		end
	end)
end
local function onCharacter(character)
	watch(character)
	watch(player:WaitForChild("Backpack"))
end
if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

---------------------------------------------------------------------------
-- Code display (after a successful hack)
---------------------------------------------------------------------------
local codeLabel = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.06, 0),
	Size = UDim2.new(0.3, 0, 0.05, 0),
	BackgroundColor3 = DARK,
	BackgroundTransparency = 0.15,
	TextColor3 = Color3.fromRGB(120, 255, 120),
	Font = Enum.Font.Code,
	TextScaled = true,
	Visible = false,
}, screen)
local codes = {}
local function refreshCode()
	local parts = {}
	for _, info in pairs(codes) do
		table.insert(parts, info.name .. " vault code: " .. info.code)
	end
	codeLabel.Text = table.concat(parts, "   ")
	codeLabel.Visible = #parts > 0
end

---------------------------------------------------------------------------
-- Computer hack minigame
---------------------------------------------------------------------------
local hackOpen = nil

-- One letter cell at a time "spins" through random letters (plain text
-- cycling - no scrolling reel, no offset math, nothing that can render
-- invisible). Press Unlock/Space while it's showing the right letter.
local function startHack(bankId, word)
	if hackOpen then
		hackOpen:Destroy()
	end
	word = tostring(word):upper()
	local length = #word
	local frame = panel(math.clamp(0.08 + length * 0.05, 0.4, 0.75), 0.34)
	hackOpen = frame

	make("TextLabel", {
		Position = UDim2.new(0, 0, 0.04, 0), Size = UDim2.new(1, 0, 0.16, 0),
		BackgroundTransparency = 1, Text = "DECODE THE PASSWORD",
		TextColor3 = Color3.fromRGB(150, 255, 150), Font = Enum.Font.Code, TextScaled = true,
	}, frame)

	local bar = make("Frame", {
		Position = UDim2.new(0.06, 0, 0.38, 0), Size = UDim2.new(0.88, 0, 0.26, 0),
		BackgroundColor3 = LIGHT, BorderSizePixel = 0,
	}, frame)
	local cellWidth = 1 / length
	local cells = {}
	for i = 1, length do
		cells[i] = make("TextLabel", {
			Position = UDim2.new((i - 1) * cellWidth, 0, 0, 0), Size = UDim2.new(cellWidth, 0, 1, 0),
			BackgroundTransparency = 1, Text = "", TextColor3 = Color3.fromRGB(30, 30, 30),
			Font = Enum.Font.SourceSansBold, TextScaled = true,
		}, bar)
	end

	local unlock = textButton("Unlock", frame, {
		Position = UDim2.new(0.06, 0, 0.78, 0), Size = UDim2.new(0.88, 0, 0.16, 0),
		BackgroundColor3 = DARK, TextColor3 = Color3.fromRGB(60, 220, 60),
	})
	make("UIStroke", { Color = Color3.fromRGB(60, 200, 60), Thickness = 1 }, unlock)

	local solved = 0
	local finished = false
	local spinToken = 0

	-- Same loop shape as the lockpick tumblers (RenderStepped:Wait in a plain
	-- while loop) since that one is proven to actually render.
	local WHITE = Color3.new(1, 1, 1)
	local GREEN = Color3.fromRGB(60, 230, 90)
	local SPIN_INTERVAL = 0.28 -- seconds per letter - slow enough to actually read
	local POOL_SIZE = 7 -- how many letters it cycles through before repeating

	local function spinCell(index, target)
		spinToken += 1
		local myToken = spinToken
		local cell = cells[index]

		-- A small fixed pool that always contains the target letter, shuffled,
		-- then cycled through in order - so the target shows up at a steady,
		-- learnable rhythm instead of vanishing into 26 random letters.
		local pool = { target }
		while #pool < POOL_SIZE do
			local letter = string.char(math.random(65, 90))
			if letter ~= target then
				table.insert(pool, letter)
			end
		end
		for i = #pool, 2, -1 do
			local j = math.random(1, i)
			pool[i], pool[j] = pool[j], pool[i]
		end

		local slot = 1
		local elapsed = 0
		while frame.Parent and spinToken == myToken and not finished do
			elapsed += RunService.RenderStepped:Wait()
			if elapsed >= SPIN_INTERVAL then
				elapsed = 0
				local letter = pool[slot]
				slot = slot % #pool + 1
				cell.Text = letter
				cell.TextColor3 = (letter == target) and GREEN or WHITE
			end
		end
	end

	local function press()
		if finished then
			return
		end
		local index = solved + 1
		local shown = cells[index].Text
		if shown == word:sub(index, index) and shown ~= "" then
			solved += 1
			cells[index].TextColor3 = Color3.fromRGB(30, 30, 30)
			if solved >= length then
				finished = true
				spinToken += 1 -- stop any running spin loop
				unlock.Text = "ACCESS GRANTED"
				heist:FireServer("HackDone", bankId)
				task.wait(1.5)
				frame:Destroy()
				hackOpen = nil
			else
				task.spawn(spinCell, solved + 1, word:sub(solved + 1, solved + 1))
			end
		else
			unlock.Text = "Missed"
			task.wait(0.25)
			if frame.Parent and not finished then
				unlock.Text = "Unlock"
			end
		end
	end

	task.spawn(spinCell, 1, word:sub(1, 1))
	unlock.MouseButton1Click:Connect(press)
	local keyConn
	keyConn = UserInputService.InputBegan:Connect(function(input, processed)
		if not frame.Parent then
			keyConn:Disconnect()
			return
		end
		if not processed and input.KeyCode == Enum.KeyCode.Space then
			press()
		end
	end)
	closeButton(frame, function()
		finished = true
		spinToken += 1
		heist:FireServer("HackFailed", bankId)
		frame:Destroy()
		hackOpen = nil
	end)
end

---------------------------------------------------------------------------
-- Vault keypad
---------------------------------------------------------------------------
local keypadOpen = nil
local function openKeypad(bankId, bankName)
	if keypadOpen then
		keypadOpen:Destroy()
	end
	local frame = panel(0.22, 0.45)
	keypadOpen = frame
	make("TextLabel", {
		Size = UDim2.new(1, -36, 0.1, 0),
		Position = UDim2.new(0, 6, 0, 4),
		BackgroundTransparency = 1,
		Text = bankName .. " vault",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.SourceSansBold,
		TextScaled = true,
	}, frame)
	local CODE_LENGTH = 5
	local display = make("TextLabel", {
		Position = UDim2.new(0.05, 0, 0.13, 0),
		Size = UDim2.new(0.9, 0, 0.14, 0),
		BackgroundColor3 = Color3.fromRGB(10, 20, 10),
		TextColor3 = Color3.fromRGB(120, 255, 120),
		Font = Enum.Font.Code,
		TextScaled = true,
		Text = string.rep("_", CODE_LENGTH),
	}, frame)
	local entry = ""
	local function show()
		display.Text = entry .. string.rep("_", CODE_LENGTH - #entry)
		display.TextColor3 = Color3.fromRGB(120, 255, 120)
	end
	local keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "OK" }
	for i, k in ipairs(keys) do
		local r, c = (i - 1) // 3, (i - 1) % 3
		local b = textButton(k, frame, {
			Position = UDim2.new(0.05 + c * 0.305, 0, 0.31 + r * 0.17, 0),
			Size = UDim2.new(0.28, 0, 0.15, 0),
			BackgroundColor3 = k == "OK" and GREEN or (k == "C" and RED or Color3.fromRGB(70, 75, 85)),
		})
		b.MouseButton1Click:Connect(function()
			if k == "C" then
				entry = ""
			elseif k == "OK" then
				if #entry == CODE_LENGTH then
					heist:FireServer("Code", bankId, entry)
				end
				return
			elseif #entry < CODE_LENGTH then
				entry ..= k
			end
			show()
		end)
	end
	closeButton(frame, function()
		frame:Destroy()
		keypadOpen = nil
	end)
	frame:SetAttribute("BankId", bankId)
	frame:SetAttribute("Wrong", false)
	frame.AttributeChanged:Connect(function(attr)
		if attr == "Wrong" and frame:GetAttribute("Wrong") then
			display.Text = "DENIED"
			display.TextColor3 = RED
			entry = ""
			frame:SetAttribute("Wrong", false)
			task.delay(1, function()
				if frame.Parent then
					show()
				end
			end)
		end
	end)
end

---------------------------------------------------------------------------
-- Choose an amount + robbing progress
---------------------------------------------------------------------------
local robOpen = nil
local function openRobChoice(bankId, amounts, times)
	if robOpen then
		robOpen:Destroy()
	end
	local frame = panel(0.5, 0.36)
	robOpen = frame
	make("TextLabel", {
		Position = UDim2.new(0, 0, 0.06, 0),
		Size = UDim2.new(1, 0, 0.2, 0),
		BackgroundTransparency = 1,
		Text = "Choose an amount",
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.5,
		Font = Enum.Font.SourceSansBold,
		TextScaled = true,
	}, frame)
	for i, amount in ipairs(amounts) do
		local b = textButton(("Rob $%d"):format(amount), frame, {
			Position = UDim2.new(0.04 + (i - 1) * 0.32, 0, 0.42, 0),
			Size = UDim2.new(0.28, 0, 0.26, 0),
			BackgroundTransparency = 1,
			TextColor3 = Color3.fromRGB(230, 70, 70),
		})
		make("TextLabel", {
			Position = UDim2.new(0.04 + (i - 1) * 0.32, 0, 0.7, 0),
			Size = UDim2.new(0.28, 0, 0.12, 0),
			BackgroundTransparency = 1,
			Text = ("takes %ds"):format(times[i]),
			TextColor3 = Color3.fromRGB(200, 200, 200),
			Font = Enum.Font.SourceSans,
			TextScaled = true,
		}, frame)
		b.MouseButton1Click:Connect(function()
			heist:FireServer("RobPick", bankId, i)
			frame:Destroy()
			robOpen = nil
		end)
	end
	closeButton(frame, function()
		heist:FireServer("RobCancel", bankId)
		frame:Destroy()
		robOpen = nil
	end)
end

local progress = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.72, 0),
	Size = UDim2.new(0.3, 0, 0.04, 0),
	BackgroundColor3 = DARK,
	Visible = false,
}, screen)
local fill = make("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = GREEN, BorderSizePixel = 0 }, progress)
local progressText = make("TextLabel", {
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundTransparency = 1,
	TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.SourceSansBold,
	TextScaled = true,
	ZIndex = 2,
}, progress)
local robToken = 0
local function showProgress(seconds)
	robToken += 1
	local mine = robToken
	progress.Visible = true
	local started = os.clock()
	while robToken == mine do
		local t = os.clock() - started
		fill.Size = UDim2.new(math.clamp(t / seconds, 0, 1), 0, 1, 0)
		progressText.Text = ("Robbing... %ds (stay in the vault!)"):format(math.max(0, math.ceil(seconds - t)))
		if t >= seconds + 2 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	if robToken == mine then
		progress.Visible = false
	end
end

---------------------------------------------------------------------------
-- Server -> client
---------------------------------------------------------------------------
local errorLabel = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0.95, 0), Size = UDim2.new(0.6, 0, 0.05, 0),
	BackgroundColor3 = Color3.fromRGB(60, 0, 0), TextColor3 = Color3.new(1, 1, 1), TextScaled = true,
	Font = Enum.Font.Code, Visible = false,
}, screen)

heist.OnClientEvent:Connect(function(action, id, a, b)
	if action == "Hack" then
		local ok, err = pcall(startHack, id, a)
		if ok then
			heist:FireServer("HackShown", id)
		else
			errorLabel.Text = "HeistClient error: " .. tostring(err)
			errorLabel.Visible = true
			warn("[HeistClient]", err)
		end
	elseif action == "Code" then
		codes[id] = { code = a, name = b }
		refreshCode()
	elseif action == "Keypad" then
		openKeypad(id, a)
	elseif action == "WrongCode" then
		if keypadOpen then
			keypadOpen:SetAttribute("Wrong", true)
		end
	elseif action == "VaultOpened" then
		if keypadOpen and keypadOpen:GetAttribute("BankId") == id then
			keypadOpen:Destroy()
			keypadOpen = nil
		end
		codes[id] = nil
		refreshCode()
	elseif action == "VaultReset" then
		codes[id] = nil
		refreshCode()
	elseif action == "RobChoice" then
		openRobChoice(id, a, b)
	elseif action == "RobStarted" then
		task.spawn(showProgress, a)
	elseif action == "RobCancelled" or action == "RobDone" then
		robToken += 1
		progress.Visible = false
	end
end)
print("[HeistClient] ready")
