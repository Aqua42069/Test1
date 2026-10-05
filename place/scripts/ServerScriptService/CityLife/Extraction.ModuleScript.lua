--[[
	CityLife.Extraction (v286k) - police pull a wanted driver out of a stopped car.

	A wanted player sitting in a car that has been stopped ~2 s (boxed in, crashed, given up):
	  * an AI officer at the driver's door smashes the window (~1.2 s) and drags them out
	    (~3.5 s) - then the normal on-foot arrest takes over
	  * a police player gets "Break window & pull out" on that car (hold 3 s)
	Get moving before it's done and it's cancelled. Logs: [Extraction]
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local E = {}
local Core: any

local CFG = { StillFor = 2, Reach = 14, BreakAt = 1.2, PullAt = 3.5, MoveCancel = 4, PlayerHold = 3 }

local still: { [Player]: number } = {}
local active: { [Player]: { start: number, broke: boolean, car: Model } } = {}
local prompts: { [Player]: ProximityPrompt } = {}

local function speedOf(car: Model): number
	local pp = car.PrimaryPart
	return if pp then pp.AssemblyLinearVelocity.Magnitude else 0
end

local function smashWindow(car: Model, seat: BasePart)
	for _, p in car:GetDescendants() do
		if p:IsA("BasePart") and not p:GetAttribute("Shattered") and (p.Position - seat.Position).Magnitude < 5
			and (p.Material == Enum.Material.Glass or (p.Transparency >= 0.2 and p.Transparency <= 0.85 and p.Name == "Part") or string.lower(p.Name):find("window")) then
			p:SetAttribute("Shattered", true)
			for _ = 1, 6 do
				local s = Instance.new("Part")
				s.Size = Vector3.new(0.3, 0.05, 0.3)
				s.Material = Enum.Material.Glass
				s.Color = p.Color
				s.Transparency = 0.3
				s.CanQuery = false
				s.CFrame = CFrame.new(p.Position + Vector3.new(math.random() - 0.5, math.random() * 0.5, math.random() - 0.5))
				s.AssemblyLinearVelocity = Vector3.new(math.random(-8, 8), 8, math.random(-8, 8))
				s.Parent = workspace
				Debris:AddItem(s, 5)
			end
			p.Transparency = 1
			p.CanCollide = false
		end
	end
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxasset://sounds/glassbreak.wav"
	snd.Volume = 1
	snd.Parent = seat
	pcall(function() snd:Play() end)
	Debris:AddItem(snd, 3)
end

local function pullOut(player: Player, car: Model, seat: BasePart, by: string)
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root then return end
	local w = seat:FindFirstChild("SeatWeld")
	if w then w:Destroy() end
	hum.Sit = false
	local side = seat.CFrame * CFrame.new(-6, 1, 0)
	task.defer(function()
		if root.Parent then
			root.CFrame = CFrame.new(side.Position + Vector3.new(0, 2, 0))
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	player:SetAttribute("PulledFromCar", os.time())
	Core.UI.notice(player, "You're dragged out of the car!", 4, Color3.fromRGB(120, 20, 20))
	Core.log("Extraction", "%s pulled out of %s by %s", player.Name, car.Name, by)
end

local function nearestCop(pos: Vector3): Model?
	for _, m in Core.aiCops() do
		local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and (r.Position - pos).Magnitude < CFG.Reach then return m end
	end
	return nil
end

local function clearPrompt(p: Player)
	local pr = prompts[p]
	if pr then pr:Destroy() prompts[p] = nil end
end

local function tick(dt: number)
	for _, p in Players:GetPlayers() do
		local car = Core.stars(p) > 0 and Core.seatedCar(p)
		local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		if not car or not seat or not seat:IsA("VehicleSeat") then
			still[p] = nil
			active[p] = nil
			clearPrompt(p)
			continue
		end
		local moving = speedOf(car) > CFG.MoveCancel
		if moving then
			if active[p] then Core.UI.notice(p, "You floored it - the officer lost their grip!", 3) end
			still[p] = nil
			active[p] = nil
			clearPrompt(p)
			continue
		end
		still[p] = (still[p] or 0) + dt
		if still[p] < CFG.StillFor then continue end
		-- police players: the prompt on this car
		if not prompts[p] then
			local pr = Instance.new("ProximityPrompt")
			pr.Name = "ExtractPrompt"
			pr.ActionText = "Break window & pull out"
			pr.ObjectText = (p:GetAttribute("CharacterName") or p.DisplayName)
			pr.HoldDuration = CFG.PlayerHold
			pr.MaxActivationDistance = 10
			pr.RequiresLineOfSight = false
			pr.KeyboardKeyCode = Enum.KeyCode.E
			pr:SetAttribute("LawOnly", true)
			pr.Parent = seat
			prompts[p] = pr
			pr.Triggered:Connect(function(cop: Player)
				if not Core.isLaw(cop) or Core.seatedCar(p) ~= car then return end
				smashWindow(car, seat)
				pullOut(p, car, seat, cop.Name)
				clearPrompt(p)
			end)
		end
		-- AI officers
		local a = active[p]
		if not a then
			if nearestCop(seat.Position) then
				active[p] = { start = os.clock(), broke = false, car = car }
				Core.UI.notice(p, "An officer is at your window!", 3, Color3.fromRGB(120, 20, 20))
			end
		else
			local t = os.clock() - a.start
			if t >= CFG.BreakAt and not a.broke then
				a.broke = true
				smashWindow(car, seat)
				Core.UI.notice(p, "CRASH - the officer smashes the window!", 3, Color3.fromRGB(120, 20, 20))
			elseif t >= CFG.PullAt then
				active[p] = nil
				if nearestCop(seat.Position) then
					pullOut(p, car, seat, "an officer")
					clearPrompt(p)
				end
			end
		end
	end
end

function E.init(core: any)
	Core = core
	Players.PlayerRemoving:Connect(function(p) still[p] = nil active[p] = nil clearPrompt(p) end)
	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(0.25)
			local now = os.clock()
			local ok, err = pcall(tick, now - last)
			last = now
			if not ok then warn("[Extraction] " .. tostring(err)) end
		end
	end)
	print("[Extraction] v286k ready (police pull wanted drivers out of stopped cars)")
end

return E
