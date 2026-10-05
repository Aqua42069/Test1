--[[
	Fountains of Bellagio - show controller (v259)
	Nozzles live in ../Nozzles; each has a ParticleEmitter "Jet" (+ "Mist", SpotLight "Uplight")
	and attributes Group (Line / Arc / Shooter), Index and Height (studs).
	A show runs every ShowSettings.IntervalSeconds for ShowSeconds; between shows the lake is still.
]]

local model = script.Parent
local settings = model:WaitForChild("ShowSettings")
local G = 60 -- particle gravity used by every jet (studs/s^2)

local groups = { Line = {}, Arc = {}, Shooter = {} }
for _, n in model:WaitForChild("Nozzles"):GetChildren() do
	local g = groups[n:GetAttribute("Group")]
	if g then
		g[(n:GetAttribute("Index") or 0) + 1] = n
	end
end

local function set(n, on, scale)
	local jet, mist, light = n:FindFirstChild("Jet"), n:FindFirstChild("Mist"), n:FindFirstChild("Uplight")
	if not jet then return end
	if on then
		local h = (n:GetAttribute("Height") or 15) * math.clamp(scale or 1, 0.15, 1.6)
		local v = math.sqrt(2 * G * h)
		jet.Speed = NumberRange.new(v * 0.97, v * 1.03)
		jet.Lifetime = NumberRange.new(2 * v / G * 0.95, 2 * v / G * 1.05)
	end
	jet.Enabled = on
	if mist then mist.Enabled = on end
	if light then light.Enabled = on end
end

local function all(on, scale)
	for _, g in groups do
		for _, n in g do set(n, on, scale) end
	end
end

local function timeLeft(t0, dur) return os.clock() - t0 < dur end

-- the choreography: a list of { seconds, function(t) end } played in order
local function show()
	local total = settings:GetAttribute("ShowSeconds") or 55
	local start = os.clock()
	local L, A, S = groups.Line, groups.Arc, groups.Shooter
	-- 1. a wave rolls down the front line and back
	local t0 = os.clock()
	while timeLeft(t0, 10) do
		local t = os.clock() - t0
		for i, n in L do
			local w = math.sin(t * 3 - i * 0.35)
			set(n, w > -0.2, 0.4 + 0.6 * (w + 1) / 2)
		end
		task.wait(0.15)
	end
	-- 2. the arc opens from the middle outwards
	for i = 0, #A // 2 do
		set(A[#A // 2 - i + 1] or A[1], true, 1)
		if A[#A // 2 + i + 1] then set(A[#A // 2 + i + 1], true, 1) end
		task.wait(0.12)
	end
	for _, n in L do set(n, true, 0.6) end
	task.wait(4)
	-- 3. shooters fire in sequence, left to right and back
	for pass = 1, 2 do
		local order = if pass == 1 then { 1, 2, 3, 4, 5, 6, 7, 8 } else { 8, 7, 6, 5, 4, 3, 2, 1 }
		for _, i in order do
			if S[i] then set(S[i], true, 0.8) task.wait(0.45) set(S[i], false) end
		end
	end
	-- 4. everything breathes together
	t0 = os.clock()
	while timeLeft(t0, 12) do
		local t = os.clock() - t0
		local s = 0.55 + 0.45 * math.sin(t * 2.2)
		for _, n in L do set(n, true, s) end
		for i, n in A do set(n, true, 0.5 + 0.5 * math.abs(math.sin(t * 2.2 + i * 0.2))) end
		task.wait(0.15)
	end
	-- 5. finale: every jet at full height, shooters roaring, then hold
	while timeLeft(start, total - 6) do task.wait(0.25) end
	all(true, 1.25)
	task.wait(6)
	all(false)
end

all(false)
task.wait(20) -- a first show shortly after the server starts
while true do
	local ok, err = pcall(show)
	if not ok then warn("[BellagioFountains] show error: " .. tostring(err)) all(false) end
	task.wait(math.max(10, (settings:GetAttribute("IntervalSeconds") or 120) - (settings:GetAttribute("ShowSeconds") or 55)))
end
