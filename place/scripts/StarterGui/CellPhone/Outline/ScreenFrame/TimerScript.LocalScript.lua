-- Phone status bar: cash, bank balance and payday countdown (rewritten).
-- Payday itself is paid by ServerScriptService.EconomyServer.
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local screen = script.Parent
local payFrame = screen:WaitForChild("PayFrame")
local permFrame = screen:WaitForChild("PermFrame")
local timerLabel = permFrame:WaitForChild("Timer")
local Lighting = game:GetService("Lighting")

-- v218: a real clock (the in-game time of day) in the middle of the status bar;
-- the payday countdown moves to the right third, the carrier name to the left.
local network = permFrame:FindFirstChild("CellNetwork")
if network then
	network.Size = UDim2.fromScale(0.24, 1)
end
timerLabel.Position = UDim2.fromScale(0.64, 0)
timerLabel.Size = UDim2.fromScale(0.35, 1)
local clockLabel = permFrame:FindFirstChild("Clock") or timerLabel:Clone()
clockLabel.Name = "Clock"
clockLabel.Position = UDim2.fromScale(0.37, 0)
clockLabel.Size = UDim2.fromScale(0.26, 1)
clockLabel.TextXAlignment = Enum.TextXAlignment.Center
clockLabel.Parent = permFrame

local function updateClock()
	local t = Lighting.ClockTime
	local h = math.floor(t)
	local m = math.floor((t - h) * 60)
	local h12 = h % 12
	if h12 == 0 then
		h12 = 12
	end
	clockLabel.Text = ("%d:%02d %s"):format(h12, m, if h < 12 then "AM" else "PM")
end
Lighting:GetPropertyChangedSignal("ClockTime"):Connect(updateClock)
updateClock()

local cash = player:WaitForChild("Cash")
local bank = player:WaitForChild("Money")
local timer = player:WaitForChild("PaydayTimer")

local function update()
	payFrame.MoneyHeld.Text = "$" .. cash.Value .. " on hand"
	payFrame.CashHeld.Text = "$" .. bank.Value .. " in bank"
	local seconds = math.max(timer.Value, 0)
	local amount = player:GetAttribute("PaydayAmount") or 0
	timerLabel.Text = ("%s$%d in %d:%02d"):format(amount >= 0 and "+" or "-", math.abs(amount), seconds // 60, seconds % 60)
end

cash.Changed:Connect(update)
bank.Changed:Connect(update)
timer.Changed:Connect(update)
player:GetAttributeChangedSignal("PaydayAmount"):Connect(update)
update()
