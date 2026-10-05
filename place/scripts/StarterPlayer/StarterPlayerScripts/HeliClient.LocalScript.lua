-- HeliClient (v228)
-- Flies the player helicopter you're piloting (ServerScriptService.HelicopterServer
-- hands you its physics while you sit in the pilot seat).
--   W / S (or the thumbstick)  forward / back
--   A / D                      turn
--   E / Q  (R1 / L1)           climb / descend      (on-screen buttons on touch)
--   Space                      get out

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local flyRE: RemoteEvent? = nil
task.spawn(function()
	local f = ReplicatedStorage:WaitForChild("Helicopters", 30)
	flyRE = f and f:WaitForChild("Fly", 30) :: RemoteEvent?
end)

local gui = Instance.new("ScreenGui")
gui.Name = "HeliHud"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.DisplayOrder = 60 -- above the other HUDs so the UP/DOWN buttons always get the touch
gui.Parent = player:WaitForChild("PlayerGui")

local info = Instance.new("TextLabel")
info.AnchorPoint = Vector2.new(0.5, 1)
info.Position = UDim2.new(0.5, 0, 1, -12)
info.Size = UDim2.new(0.9, 0, 0, 44)
local maxW = Instance.new("UISizeConstraint")
maxW.MaxSize = Vector2.new(480, 44)
maxW.Parent = info
info.BackgroundColor3 = Color3.fromRGB(15, 18, 22)
info.BackgroundTransparency = 0.25
info.TextColor3 = Color3.fromRGB(235, 240, 245)
info.Font = Enum.Font.GothamMedium
info.TextScaled = true
local ts = Instance.new("UITextSizeConstraint")
ts.MaxTextSize = 14
ts.Parent = info
info.Parent = gui
local c = Instance.new("UICorner")
c.CornerRadius = UDim.new(0, 8)
c.Parent = info

local held = { up = false, down = false }
local function holdButton(text: string, pos: UDim2, key: string)
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 1)
	b.Position = pos
	b.Size = UDim2.fromOffset(86, 70)
	b.BackgroundColor3 = Color3.fromRGB(40, 70, 110)
	b.BackgroundTransparency = 0.15
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBlack
	b.TextSize = 18
	b.Text = text
	b.Parent = gui
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 10)
	bc.Parent = b
	-- v233: follow the actual touch/click. MouseLeave fires as soon as a finger
	-- lands on a phone, which used to cancel UP instantly (the heli never lifted).
	local presses: { [InputObject]: boolean } = {}
	local function refresh()
		local any = false
		for input in presses do
			if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
				presses[input] = nil
			else
				any = true
			end
		end
		held[key] = any
	end
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			presses[input] = true
			refresh()
		end
	end)
	b.InputEnded:Connect(function(input)
		presses[input] = nil
		refresh()
	end)
	UserInputService.InputEnded:Connect(function(input)
		if presses[input] then
			presses[input] = nil
			refresh()
		end
	end)
	RunService.Heartbeat:Connect(function()
		if held[key] then
			refresh()
		end
	end)
	return b
end
local upButton = holdButton("UP", UDim2.new(1, -20, 1, -250), "up")
local downButton = holdButton("DOWN", UDim2.new(1, -20, 1, -172), "down")

-- v231: the touch thumbstick (and gamepad stick) straight from the control
-- module - a VehicleSeat doesn't always pick up the thumbstick on phones
local controls: any = nil
task.spawn(function()
	local ok, mod = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10) :: ModuleScript)
	end)
	if ok and mod then
		local ok2, c = pcall(function()
			return mod:GetControls()
		end)
		if ok2 then
			controls = c
		end
	end
end)
local function stick(): Vector3
	if controls then
		local ok, v = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	return Vector3.zero
end

local function keyDown(...: Enum.KeyCode): boolean
	for _, k in { ... } do
		if UserInputService:IsKeyDown(k) then
			return true
		end
	end
	return false
end

local function fly(humanoid: Humanoid, seat: VehicleSeat)
	local model = seat.Parent
	local body = model and model:FindFirstChild("Fuselage") :: BasePart?
	local lv = body and body:FindFirstChild("HeliFly") :: LinearVelocity?
	local ao = body and body:FindFirstChild("HeliAlign") :: AlignOrientation?
	if not body or not lv or not ao then
		return
	end
	local maxSpeed = seat:GetAttribute("MaxSpeed") or 80
	local climb = seat:GetAttribute("ClimbSpeed") or 30
	local yawRate = seat:GetAttribute("YawRate") or 1.3
	local _, yaw, _ = body.CFrame:ToOrientation()
	local fwd, vert, turn = 0, 0, 0
	local touch = UserInputService.TouchEnabled
	upButton.Visible = touch
	downButton.Visible = touch
	gui.Enabled = true
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model, humanoid.Parent }

	local sendTimer = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if humanoid.SeatPart ~= seat or not body.Parent or humanoid.Health <= 0 then
			conn:Disconnect()
			gui.Enabled = false
			held.up, held.down = false, false
			return
		end
		local throttle = seat.ThrottleFloat
		local steer = seat.SteerFloat
		if math.abs(throttle) < 0.05 then
			throttle = if keyDown(Enum.KeyCode.W, Enum.KeyCode.Up) then 1 elseif keyDown(Enum.KeyCode.S, Enum.KeyCode.Down) then -1 else 0
		end
		if math.abs(steer) < 0.05 then
			steer = if keyDown(Enum.KeyCode.A, Enum.KeyCode.Left) then -1 elseif keyDown(Enum.KeyCode.D, Enum.KeyCode.Right) then 1 else 0
		end
		if math.abs(throttle) < 0.05 and math.abs(steer) < 0.05 then
			local mv = stick()
			if mv.Magnitude > 0.1 then
				throttle = math.clamp(-mv.Z, -1, 1)
				steer = math.clamp(mv.X, -1, 1)
			end
		end
		local lift = 0
		if held.up or keyDown(Enum.KeyCode.E, Enum.KeyCode.ButtonR1) then
			lift += 1
		end
		if held.down or keyDown(Enum.KeyCode.Q, Enum.KeyCode.ButtonL1) then
			lift -= 1
		end
		if seat:GetAttribute("VehicleDestroyed") then
			throttle, steer, lift = 0, 0, -1
		end

		local ground = Workspace:Raycast(body.Position, Vector3.new(0, -9, 0), params)
		local landed = ground ~= nil
		-- v233 take-off assist: pushing forward (stick or W) on the ground lifts off
		if landed and lift == 0 and throttle > 0.5 then
			lift = 1
		end
		-- the skids stay on the ground until you climb
		if landed and lift <= 0 then
			throttle *= 0.15
			steer *= 0.6
		end

		local k = math.min(1, dt * 1.6)
		fwd += ((throttle * (if throttle < 0 then maxSpeed * 0.4 else maxSpeed)) - fwd) * k
		vert += ((lift * climb) - vert) * math.min(1, dt * 3)
		turn += ((-steer * yawRate) - turn) * math.min(1, dt * 4)
		yaw += turn * dt
		local alt = body.Position.Y
		if alt > 900 and vert > 0 then
			vert = 0
		end

		local heading = CFrame.Angles(0, yaw, 0)
		local look = heading.LookVector
		lv.Enabled = true
		lv.VectorVelocity = Vector3.new(look.X * fwd, if landed and lift <= 0 then math.min(vert, -2) else vert, look.Z * fwd)
		local pitch = -(fwd / maxSpeed) * 0.22
		local roll = turn / yawRate * 0.2 * math.clamp(math.abs(fwd) / maxSpeed + 0.2, 0, 1)
		ao.CFrame = heading * CFrame.Angles(pitch, 0, roll)
		sendTimer += dt
		if sendTimer >= 0.1 and flyRE then
			sendTimer = 0
			flyRE:FireServer(lv.VectorVelocity, ao.CFrame)
		end

		local agl = ground and (body.Position.Y - ground.Position.Y) or nil
		info.Text = ("%s   |   %d mph   |   ALT %s   |   "):format(
			tostring(model:GetAttribute("HeliName") or "Helicopter"),
			math.floor(math.abs(fwd) * 0.7 + 0.5),
			if agl then ("%d ft"):format(math.floor(agl)) else ("%d"):format(math.floor(alt))
		) .. (if touch then "UP/DOWN to climb" else "E climb  Q descend  Space exit")
	end)
end

local function onCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Seated:Connect(function(active, seatPart)
		if active and seatPart and seatPart:IsA("VehicleSeat") and seatPart:GetAttribute("HeliPilot") then
			fly(humanoid, seatPart)
		end
	end)
end
if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)
