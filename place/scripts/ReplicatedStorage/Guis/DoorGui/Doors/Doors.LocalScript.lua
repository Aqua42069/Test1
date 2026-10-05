-- Car control panel (rewritten). CarServer gives this to the car's owner as
-- soon as the car spawns (and to passengers while they're seated).
-- Buttons open/close each door; the label shows speed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local frame = script.Parent
local gui = frame.Parent
local example = frame:WaitForChild("Example")
local speedLabel = frame:FindFirstChild("Speed")
local remote = ReplicatedStorage:WaitForChild("Events"):WaitForChild("CarDoorOpener")

local LABELS = { LF = "Front Left", RF = "Front Right", LB = "Back Left", RB = "Back Right" }
local ORDER = { LF = 1, RF = 2, LB = 3, RB = 4 }
local STUDS_TO_MPH = 0.5682

frame.Position = UDim2.new(0.02, 0, 0.35, 0)
frame.Size = UDim2.new(0.18, 0, 0.16, 0)
frame.Active = false

-- Only one panel at a time.
for _, other in ipairs(gui.Parent:GetChildren()) do
	if other ~= gui and other.Name == gui.Name then
		other:Destroy()
	end
end

local function message(text)
	local label = example:Clone()
	label.Text = text
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Position = UDim2.new(0, 0, 0, 0)
	label.AutoButtonColor = false
	label.Visible = true
	label.Parent = frame
	return label
end

-- The car can arrive on this machine a moment after the panel does, so wait for it.
local carValue = gui:WaitForChild("Car")
local car = carValue.Value
if not car then
	local waiting = message("Loading car...")
	local started = os.clock()
	while not carValue.Value and os.clock() - started < 15 do
		carValue.Changed:Wait()
	end
	car = carValue.Value
	waiting:Destroy()
end
if not car then
	message("Car not found")
	warn("[DoorGui] panel has no car")
	return
end

local essentials = car:WaitForChild("Essentials", 10)
local doorsFolder = essentials and essentials:WaitForChild("Doors", 10)

local doorNames = {}
if doorsFolder then
	for _, door in ipairs(doorsFolder:GetChildren()) do
		if door:IsA("Model") then
			table.insert(doorNames, door.Name)
		end
	end
end
table.sort(doorNames, function(a, b)
	return (ORDER[a] or 9) < (ORDER[b] or 9)
end)

if #doorNames == 0 then
	message("This car has no doors")
	warn("[DoorGui] no doors found in", car:GetFullName())
end

local hasBack = false
for _, name in ipairs(doorNames) do
	if name:sub(2, 2) == "B" then
		hasBack = true
	end
end
local rows = hasBack and 2 or 1

for _, name in ipairs(doorNames) do
	local button = example:Clone()
	button.Name = name
	local column = name:sub(1, 1) == "R" and 1 or 0
	local row = (hasBack and name:sub(2, 2) == "B") and 1 or 0
	button.Size = UDim2.new(0.5, 0, 1 / rows, 0)
	button.Position = UDim2.new(column * 0.5, 0, row / rows, 0)
	button.Visible = true
	button.Parent = frame

	local state = doorsFolder:WaitForChild(name .. "Open", 10)
	local doorModel = doorsFolder:FindFirstChild(name)
	local pivot = doorModel and doorModel:FindFirstChild("Pivot")
	local hinge = pivot and pivot:WaitForChild("DoorHinge", 5)

	-- Also swing the door on this machine. If you're driving, your computer runs
	-- the car's physics, so this makes the door move instantly for you.
	local animation = 0
	local function swing(open)
		if not (hinge and hinge:GetAttribute("OpenC0")) then
			return
		end
		animation += 1
		local mine = animation
		local from = hinge.C0
		local to = open and hinge:GetAttribute("OpenC0") or hinge:GetAttribute("ClosedC0")
		local started = os.clock()
		while animation == mine and hinge.Parent do
			local alpha = math.min((os.clock() - started) / 0.35, 1)
			hinge.C0 = from:Lerp(to, 1 - (1 - alpha) ^ 2)
			if alpha >= 1 then
				break
			end
			RunService.Heartbeat:Wait()
		end
	end

	local pending = false
	local function refresh()
		pending = false
		button.Text = (LABELS[name] or name) .. ": " .. ((state and state.Value) and "Open" or "Closed")
	end
	refresh()
	if state then
		state.Changed:Connect(function()
			refresh()
			task.spawn(swing, state.Value)
		end)
	end
	button.MouseButton1Click:Connect(function()
		pending = true
		button.Text = (LABELS[name] or name) .. ": ..."
		remote:FireServer(car, name)
		task.delay(2, function()
			if pending then
				button.Text = "No reply from server"
				warn("[DoorGui] server didn't answer the door request for", name)
				task.wait(2)
				refresh()
			end
		end)
	end)
end

-- Speedometer
local seat = essentials and essentials:FindFirstChildOfClass("VehicleSeat")
if speedLabel and seat then
	local connection
	connection = RunService.RenderStepped:Connect(function()
		if not (gui.Parent and seat.Parent) then
			connection:Disconnect()
			return
		end
		local mph = seat.AssemblyLinearVelocity.Magnitude * STUDS_TO_MPH
		speedLabel.Text = ("Speed: %d MPH"):format(math.floor(mph + 0.5))
	end)
end
