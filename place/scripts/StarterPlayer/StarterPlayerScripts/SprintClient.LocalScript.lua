-- SprintClient (v288i): hold Shift (or the RUN button on a phone) to sprint. Stamina drains while
-- you run and comes back when you stop; empty = you're winded until it's back to a third.
-- Never while cuffed, escorted, seated or slowed by the server (custody sets WalkSpeed itself).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local SPRINT_SCALE = 1.65
local DRAIN = 16 -- per second while sprinting
local REGEN = 11 -- per second after REGEN_DELAY
local REGEN_DELAY = 1.2
local MAX = 100

local stamina = MAX
local wantRun = false
local running = false
local winded = false
local baseSpeed: number? = nil
local lastRun = 0

-- the bar (bottom centre, only shows when it isn't full)
local gui = Instance.new("ScreenGui")
gui.Name = "Stamina"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")
local back = Instance.new("Frame")
back.AnchorPoint = Vector2.new(0.5, 1)
back.Position = UDim2.new(0.5, 0, 1, -18)
back.Size = UDim2.fromOffset(220, 8)
back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
back.BackgroundTransparency = 0.3
back.BorderSizePixel = 0
back.Visible = false
back.Parent = gui
Instance.new("UICorner").Parent = back
local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(1, 1)
fill.BackgroundColor3 = Color3.fromRGB(120, 210, 120)
fill.BorderSizePixel = 0
fill.Parent = back
Instance.new("UICorner").Parent = fill

local function humanoid(): Humanoid?
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function canRun(h: Humanoid): boolean
	if h.Health <= 0 or h.SeatPart or h:GetAttribute("PoliceCuffed") then return false end
	if player:GetAttribute("CustodyAutoMove") == true or player:GetAttribute("BeingEscorted") == true then return false end
	return true
end

local function stopRun(h: Humanoid?)
	if running and h and baseSpeed and math.abs(h.WalkSpeed - baseSpeed * SPRINT_SCALE) < 0.5 then
		h.WalkSpeed = baseSpeed
	end
	running = false
	baseSpeed = nil
end

RunService.Heartbeat:Connect(function(dt)
	local h = humanoid()
	if not h then return end
	local moving = h.MoveDirection.Magnitude > 0.1
	if wantRun and moving and not winded and stamina > 0 and canRun(h) then
		if not running then
			-- only speed up a normal walk (the server slows people in custody, injured, etc.)
			if h.WalkSpeed >= 12 and h.WalkSpeed <= 24 then
				baseSpeed = h.WalkSpeed
				h.WalkSpeed = h.WalkSpeed * SPRINT_SCALE
				running = true
			end
		elseif baseSpeed and math.abs(h.WalkSpeed - baseSpeed * SPRINT_SCALE) > 0.5 then
			-- the server changed the speed under us (cuffed, injured): give it back
			running = false
			baseSpeed = nil
		end
		if running then
			stamina = math.max(0, stamina - DRAIN * dt)
			lastRun = os.clock()
			if stamina <= 0 then
				winded = true
				stopRun(h)
			end
		end
	else
		if running then stopRun(h) end
		if os.clock() - lastRun > REGEN_DELAY then
			stamina = math.min(MAX, stamina + REGEN * dt)
		end
		if winded and stamina >= MAX / 3 then winded = false end
	end
	back.Visible = stamina < MAX
	fill.Size = UDim2.fromScale(stamina / MAX, 1)
	fill.BackgroundColor3 = if winded then Color3.fromRGB(220, 80, 70) elseif stamina < 35 then Color3.fromRGB(235, 180, 70) else Color3.fromRGB(120, 210, 120)
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if UserInputService:GetFocusedTextBox() then return end
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then wantRun = true end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then wantRun = false end
end)
-- phones / tablets: a RUN button (hold) beside jump, on foot only (a car puts HANDBRAKE there)
local Mobile = require(game:GetService("ReplicatedStorage"):WaitForChild("MobileControls"))
Mobile.button("Sprint", "RUN", Color3.fromRGB(40, 120, 60), "side", function() wantRun = true end, function() wantRun = false end)
task.spawn(function()
	while true do
		task.wait(0.3)
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		Mobile.show("Sprint", hum ~= nil and hum.Health > 0 and hum.SeatPart == nil)
	end
end)
player.CharacterAdded:Connect(function()
	running = false
	baseSpeed = nil
	stamina = MAX
	winded = false
end)
