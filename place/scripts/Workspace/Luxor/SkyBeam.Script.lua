-- SkyBeam (v294b): the Luxor Sky Beam - a column of light straight up from the apex, on from dusk
-- to dawn (the real one is the brightest beam on Earth). Built by tools/build_luxor_real.luau: Beams
-- (core + halo) on an anchor at the tip, in the Persistent Pyramid.SkyBeam model.
local Lighting = game:GetService("Lighting")

local model = script.Parent
local pyramid = model:WaitForChild("Pyramid", 30)
if not pyramid then return end
local sky = pyramid:WaitForChild("SkyBeam", 30)
if not sky then return end

local on: boolean? = nil
while true do
	local t = Lighting.ClockTime
	local night = t >= 18.75 or t < 6.25
	if night ~= on then
		on = night
		for _, d in sky:GetDescendants() do
			if d:IsA("Beam") then d.Enabled = night end
			if d:IsA("PointLight") then d.Brightness = if night then 5 else 0 end
		end
	end
	task.wait(5)
end
