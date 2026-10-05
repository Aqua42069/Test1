-- MovingWalkways (v294): the moving walkways in the Luxor's enclosed walkway to Excalibur. Each
-- "MovingWalkway" belt carries ConveyorSpeed (studs/s); an anchored part with a velocity moves
-- whatever stands on it, along the belt's LookVector. Built by tools/build_luxor_real.luau.
local model = script.Parent

local function run(belt: Instance)
	if belt:IsA("BasePart") and belt.Name == "MovingWalkway" then
		local speed = tonumber(belt:GetAttribute("ConveyorSpeed")) or 9
		belt.AssemblyLinearVelocity = belt.CFrame.LookVector * speed
	end
end
for _, d in model:GetDescendants() do run(d) end
model.DescendantAdded:Connect(run)
