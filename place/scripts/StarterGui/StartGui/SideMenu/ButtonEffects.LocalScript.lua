-- Hover sound + slider under the side-menu buttons.
local sideMenu = script.Parent
local slider = sideMenu:WaitForChild("Slider")
local sound = sideMenu:WaitForChild("Sound")

local function hook(button)
	if not button:IsA("TextButton") then
		return
	end
	button.MouseEnter:Connect(function()
		sound:Play()
		slider:TweenPosition(
			UDim2.new(button.Position.X.Scale + 0.02, 0, 0.1, 0),
			Enum.EasingDirection.Out,
			Enum.EasingStyle.Quad,
			0.1,
			true
		)
	end)
end

for _, child in ipairs(sideMenu:GetChildren()) do
	hook(child)
end
sideMenu.ChildAdded:Connect(hook)
