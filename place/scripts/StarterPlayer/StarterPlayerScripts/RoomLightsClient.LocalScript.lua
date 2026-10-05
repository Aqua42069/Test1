--[[
  RoomLightsClient (v295b) - the Luxor's hotel windows at night, lit the way a real hotel's are.

  Windows: every tower room's "RoomGlow" panel (tools/build_luxor_real.luau puts one at each
  window), and a panel made here behind the slanted glass of every pyramid room and corner suite
  (from its HotelDoor - the pyramid rooms were built without one). Streamed-in parts are picked up
  as they arrive.

  Each window draws its own night from (its position, Lighting's CityDay): the same pattern on
  every client, a new one every night (individual windows don't repeat their times night to
  night - Dobler et al. 2015, "Dynamics of the urban lightscape"). The shape of a night:
    * ~84% of rooms are taken (Las Vegas Strip occupancy); an empty room stays dark, bar a
      housekeeping turndown light now and then
    * guests in for the evening: on from dusk / their return, off late - lights-off peaks after
      midnight (residential windows peak near 23:00; the Strip runs later)
    * guests going out: on while they get ready, dark through the evening, on again for a while
      when they come back in the small hours
    * a few rooms on all night, dim (the bathroom light left on as a nightlight / curtains shut -
      LBNL 1998 hotel guestroom study), a few night owls, and early risers before dawn
    * curtains: some lit windows are dim (sheers drawn); a few flicker blue with the TV
  Purely local (no server traffic). Lighting.ClockTime drives it; daytime is all dark.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

-- the true-scale Luxor as placed (build_luxor_real: B 551.6, H 299.6 at (-6067, -706))
local CX, CZ = -6067, -706
local HALF, H = 551.6 / 2, 299.6
local function w(y: number): number return HALF * (1 - y / H) end

local OCCUPANCY = 0.84
local DUSK, DAWN = 18.0, 30.5 -- night-hours (past 24 = after midnight): when windows can show

local folder = Instance.new("Folder")
folder.Name = "RoomLightsLocal"
folder.Parent = workspace

type Win = { part: BasePart, seed: number, made: boolean?, plan: any? }
local windows: { [BasePart]: Win } = {}

local function hash(v: Vector3): number
	return (math.floor(v.X * 7.1) * 73856093 + math.floor(v.Y * 3.3) * 19349663 + math.floor(v.Z * 5.7) * 83492791) % 2147483629
end

local function addWindow(p: BasePart, made: boolean?)
	if windows[p] then return end
	windows[p] = { part = p, seed = hash(p.Position), made = made }
	p.Transparency = 1
end

-- a pyramid room's window: a panel just inside the glass, across the room's width, lying in
-- the plane of the slope from just above the floor to the ceiling
local madeFor: { [string]: boolean } = {}
local SLOPE_DIR_V = H / math.sqrt(H * H + HALF * HALF) -- vertical share of a step up the glass
local function pyramidWindow(door: BasePart)
	local kind = door:GetAttribute("RoomType")
	if kind ~= "Pyramid" and kind ~= "PyramidSuite" then return end
	local id = tostring(door:GetAttribute("RoomId"))
	if madeFor[id] then return end
	local look = door.CFrame.LookVector
	local n = Vector3.new(look.X, 0, look.Z)
	if n.Magnitude < 0.5 then return end
	n = n.Unit -- outward, toward the glass
	local along = Vector3.new(-n.Z, 0, n.X)
	local yf = door.Position.Y - door.Size.Y / 2 -- the floor
	local yw = yf + 4.3
	local reach = w(yw) - 1.9
	if reach < 4 then return end
	local t = (door.Position - Vector3.new(CX, door.Position.Y, CZ)):Dot(along)
	local width = 13.6
	if kind == "PyramidSuite" then
		-- the suite runs on from its door round the corner: the glass along this side to the corner
		local sign = if t >= 0 then 1 else -1
		local t1 = sign * (reach - 1)
		t, width = (t - 4 * sign + t1) / 2, math.abs(t1 - (t - 4 * sign))
	end
	local lim = reach - 1
	local a, b = math.max(t - width / 2, -lim), math.min(t + width / 2, lim)
	if b - a < 3 then return end
	t, width = (a + b) / 2, b - a
	local slope = (Vector3.yAxis * H - n * HALF).Unit
	local pos = Vector3.new(CX, yw, CZ) + n * reach + along * t
	local p = Instance.new("Part")
	p.Name = "RoomGlow"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Size = Vector3.new(width, 7.4 / SLOPE_DIR_V, 0.1)
	p.CFrame = CFrame.fromMatrix(pos, along, slope)
	p.Transparency = 1
	p.Parent = folder
	madeFor[id] = true
	addWindow(p, true)
end

local function consider(d: Instance)
	if d:IsA("BasePart") then
		if d.Name == "RoomGlow" and d.Parent ~= folder then
			addWindow(d)
		elseif d.Name == "HotelDoor" then
			pyramidWindow(d)
		end
	end
end

-- the Luxor streams in and out; watch it arrive
local function watch(lux: Instance)
	for _, d in lux:GetDescendants() do consider(d) end
	lux.DescendantAdded:Connect(consider)
end
local lux = workspace:FindFirstChild("Luxor")
if lux then watch(lux) end
workspace.ChildAdded:Connect(function(c) if c.Name == "Luxor" then watch(c) end end)

---------------------------------------------------------------- a window's night
local WARM = { Color3.fromRGB(255, 214, 160), Color3.fromRGB(255, 200, 140), Color3.fromRGB(250, 226, 190), Color3.fromRGB(255, 190, 120) }
local COOL = Color3.fromRGB(215, 228, 255)
local TV = { Color3.fromRGB(120, 160, 255), Color3.fromRGB(170, 200, 255), Color3.fromRGB(90, 120, 220), Color3.fromRGB(200, 215, 255) }

local function normal(r: Random, mean: number, sd: number): number
	-- Box-Muller
	local u1, u2 = math.max(r:NextNumber(), 1e-6), r:NextNumber()
	return mean + sd * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

local function planFor(win: Win, night: number): any
	local r = Random.new((win.seed * 131 + night * 7919) % 2147483629)
	local spans = {}
	local forceDim = false
	local function on(a: number, b: number)
		if b > a then table.insert(spans, { math.max(a, DUSK - 0.5), math.min(b, DAWN) }) end
	end
	if r:NextNumber() < OCCUPANCY then
		local kind = r:NextNumber()
		if kind < 0.45 then
			-- in for the evening
			local a = math.clamp(normal(r, 19.6, 1.3), DUSK - 0.3, 23.5)
			on(a, math.clamp(normal(r, 24.2, 1.4), a + 0.7, 28))
		elseif kind < 0.82 then
			-- out on the Strip: getting ready, then back in the small hours
			local a = r:NextNumber(DUSK - 0.2, 20.2)
			on(a, a + r:NextNumber(0.4, 1.4))
			local back = math.clamp(normal(r, 25.6, 1.3), 23, 29.5)
			on(back, back + r:NextNumber(0.3, 1.3))
		elseif kind < 0.91 then
			-- the bathroom light all night (dim through the curtains)
			on(DUSK, DAWN)
			forceDim = true
		else
			-- night owls
			local a = r:NextNumber(19.5, 22.5)
			on(a, math.clamp(normal(r, 27.6, 0.9), 25.5, 30))
		end
		-- up before dawn
		if r:NextNumber() < 0.12 then
			local a = math.clamp(normal(r, 29.6, 0.5), 28.5, 30.2)
			on(a, DAWN)
		end
	elseif r:NextNumber() < 0.04 then
		-- an empty room: housekeeping's turndown light
		local a = r:NextNumber(18, 21)
		on(a, a + 0.25)
	end
	local dim = forceDim or r:NextNumber() < 0.35
	return {
		spans = spans,
		color = if r:NextNumber() < 0.1 then COOL else WARM[r:NextInteger(1, #WARM)],
		trans = if dim then r:NextNumber(0.5, 0.65) else r:NextNumber(0.12, 0.3),
		tv = r:NextNumber() < 0.12,
		tvPhase = r:NextNumber() * 10,
	}
end

local function lit(plan: any, h: number): boolean
	for _, s in plan.spans do
		if h >= s[1] and h < s[2] then return true end
	end
	return false
end

---------------------------------------------------------------- the loop
local currentNight = nil
local tvOn: { [Win]: boolean } = {}
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.5 then return end
	acc = 0
	local clock = Lighting.ClockTime
	local h = if clock < 12 then clock + 24 else clock
	local night = (tonumber(Lighting:GetAttribute("CityDay")) or 1) - (if clock < 12 then 1 else 0)
	local newNight = night ~= currentNight
	currentNight = night
	local nowSec = os.clock()
	for p, win in windows do
		if not p.Parent then
			windows[p] = nil
			tvOn[win] = nil
		else
			if newNight or not win.plan then win.plan = planFor(win, night) end
			local plan = win.plan
			if lit(plan, h) then
				local tv = plan.tv and h > 21 and h < 27
				if tv then
					-- the TV's light: the colour jumps every half second or so
					local k = math.floor(nowSec * 1.7 + plan.tvPhase)
					p.Color = TV[k % #TV + 1]
					p.Transparency = 0.45 + (k % 3) * 0.08
					tvOn[win] = true
				else
					if tvOn[win] or p.Transparency == 1 or newNight then
						p.Color = plan.color
						tvOn[win] = nil
					end
					p.Transparency = plan.trans
				end
			elseif p.Transparency ~= 1 then
				p.Transparency = 1
				tvOn[win] = nil
			end
		end
	end
end)
