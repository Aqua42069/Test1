-- VehicleHealthClient (v215)
-- A yellow car health bar just above the green health bar while you're in a car.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local gui = Instance.new("ScreenGui")
gui.Name = "VehicleHealthGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.Parent = player:WaitForChild("PlayerGui")

local holder = Instance.new("Frame")
holder.Name = "CarHealth"
holder.Position = UDim2.new(0.5, -85, 0.9, -48) -- the health bar sits at (0.5,-85, 0.9,-26), 170 wide
holder.Size = UDim2.fromOffset(170, 16)
holder.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
holder.BackgroundTransparency = 0.25
holder.BorderSizePixel = 0
holder.Visible = false
holder.Parent = gui
local c = Instance.new("UICorner")
c.CornerRadius = UDim.new(0, 4)
c.Parent = holder

local fill = Instance.new("Frame")
fill.Position = UDim2.fromOffset(2, 2)
fill.Size = UDim2.new(1, -4, 1, -4)
fill.BackgroundColor3 = Color3.fromRGB(245, 200, 30)
fill.BorderSizePixel = 0
fill.Parent = holder
local fc = Instance.new("UICorner")
fc.CornerRadius = UDim.new(0, 3)
fc.Parent = fill

local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextSize = 11
label.TextColor3 = Color3.fromRGB(20, 20, 20)
label.Text = "CAR"
label.ZIndex = 2
label.Parent = holder

local function carOf(): Model?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat then
		return nil
	end
	local model: Instance? = seat:FindFirstAncestorWhichIsA("Model")
	while model and model.Parent and model.Parent ~= workspace and model.Parent:IsA("Model") do
		model = model.Parent
	end
	return if model and model:IsA("Model") and model:GetAttribute("VehicleMaxHealth") then model else nil
end

RunService.Heartbeat:Connect(function()
	local car = carOf()
	if not car then
		holder.Visible = false
		return
	end
	local max = tonumber(car:GetAttribute("VehicleMaxHealth")) or 1
	local health = tonumber(car:GetAttribute("VehicleHealth")) or 0
	local frac = math.clamp(health / max, 0, 1)
	holder.Visible = true
	fill.Size = UDim2.new(frac, -4 * frac, 1, -4)
	fill.BackgroundColor3 = if frac > 0.3 then Color3.fromRGB(245, 200, 30) else Color3.fromRGB(245, 110, 30)
	label.Text = if car:GetAttribute("VehicleDestroyed") then "ON FIRE" else ("CAR  %d"):format(math.ceil(health))
end)
