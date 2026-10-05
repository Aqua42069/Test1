-- One tumbler's bar sweeping up and down. Speed comes from the tumbler's
-- SweepTime attribute (set by the Lock script), so every tumbler differs.
local RunService = game:GetService("RunService")

local tumbler = script.Parent
local slider = tumbler:WaitForChild("Slider")
local sweep = tumbler:GetAttribute("SweepTime") or 1
local t = 0

while script.Parent and not script.Disabled do
	t += RunService.RenderStepped:Wait()
	local phase = (t / sweep) % 2 -- 0..1 going up, 1..2 coming down
	local height = phase <= 1 and phase or (2 - phase)
	slider.Size = UDim2.new(1, 0, -height, 0)
end
