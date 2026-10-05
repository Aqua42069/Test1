-- Car spawn menu (rewritten). Shown by CarServer when you step on a spawn pad
-- while owning at least one set of car keys (player.CarStorage).
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local spawner = script.Parent
local gui = spawner.Parent
local padValue = gui:WaitForChild("Pad")
local example = spawner:WaitForChild("Example")
local storage = player:WaitForChild("CarStorage")
local spawnRemote = workspace:WaitForChild("SpawnPads"):WaitForChild("SpawnCar")

local cars = storage:GetChildren()
table.sort(cars, function(a, b)
	return a.Name < b.Name
end)

local count = math.max(#cars, 1)
local columns = math.max(1, math.ceil(count / 11))
local rows = math.ceil(count / columns)

local function place(button, i)
	button.Size = UDim2.new(1 / columns, 0, 1 / rows, 0)
	button.Position = UDim2.new(((i - 1) % columns) / columns, 0, math.floor((i - 1) / columns) / rows, 0)
	button.Visible = true
	button.Parent = spawner
end

if #cars == 0 then
	local button = example:Clone()
	button.Text = "You don't own any cars yet. Visit YBCN!"
	button.AutoButtonColor = false
	place(button, 1)
end

for i, car in ipairs(cars) do
	local button = example:Clone()
	button.Name = car.Name
	button.Text = car.Value == true and (car.Name .. " (Single use)") or car.Name
	place(button, i)
	button.MouseButton1Click:Connect(function()
		spawnRemote:FireServer(car.Name, padValue.Value, car.Value)
		gui:Destroy()
	end)
end

-- Close the menu once you walk off the pad.
while gui.Parent do
	task.wait(0.25)
	local pad = padValue.Value
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (pad and root) or (root.Position - pad.Position).Magnitude > 20 then
		gui:Destroy()
		break
	end
end
