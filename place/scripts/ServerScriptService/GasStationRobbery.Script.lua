--[[
	GasStationRobbery (v290) - the clerk at the Gas & Go Mart (Workspace.GasStation, built by
	tools/build_gasstation.luau) and the hold-up.

	The clerk stands behind the counter (the ClerkSpot marker) by the register. Walk up with a
	GUN OUT (a tool with the GunName attribute) and use the prompt: the clerk's hands go up and
	they empty the till while you keep the gun on them - stay within reach with the gun out
	for EMPTY_SECONDS. Walk off or put the gun away and it's over (the clerk ducks).
	  * the take: $MIN..$MAX in CLEAN cash (EconomyServer "AddCash") - a store doesn't record
	    the notes' serial numbers the way a bank does, so nothing marks the money
	  * the police: armed robbery (PoliceSystem "Robbery"). The clerk sometimes hits the silent
	    alarm the moment the gun comes out; they always call it in once you're gone
	  * the till is empty for COOLDOWN seconds afterwards ("it's empty, I swear!")
	  * shoot the clerk and they're gone for a while (CLERK_RESPAWN), then a new one starts
	No gun out: the clerk just asks if they can help you.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local EMPTY_SECONDS = 8
local REACH = 18
local MIN_TAKE, MAX_TAKE = 350, 1200
local COOLDOWN = 300
local ALARM_AT_START = 0.35
local CLERK_RESPAWN = 90

local function economy(action: string, player: Player, amount: number): any
	local fn = ServerStorage:WaitForChild("Economy", 10)
	return fn and fn:Invoke(action, player, amount)
end
local function reportRobbery(player: Player, pos: Vector3)
	local ai = ServerStorage:FindFirstChild("PoliceAI")
	local ev = ai and ai:FindFirstChild("ReportCrime")
	if ev and ev:IsA("BindableEvent") then
		ev:Fire(player, "Robbery", pos)
		return
	end
	local fn = ServerStorage:FindFirstChild("ReportCrime")
	if fn and fn:IsA("BindableFunction") then pcall(fn.Invoke, fn, player, "Robbery", 2) end
end
local function notify(player: Player, text: string, secs: number?)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then return end
	local old = pg:FindFirstChild("GasStationNotice")
	if old then old:Destroy() end
	local g = Instance.new("ScreenGui")
	g.Name = "GasStationNotice"
	g.ResetOnSpawn = false
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = UDim2.new(0.5, 0, 0.22, 0)
	l.Size = UDim2.fromOffset(420, 44)
	l.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	l.BackgroundTransparency = 0.2
	l.TextColor3 = Color3.fromRGB(255, 220, 150)
	l.Font = Enum.Font.GothamBold
	l.TextSize = 18
	l.Text = text
	Instance.new("UICorner").Parent = l
	l.Parent = g
	g.Parent = pg
	task.delay(secs or 4, function() if g.Parent then g:Destroy() end end)
end
local function gunOut(player: Player): Tool?
	local ch = player.Character
	local tool = ch and ch:FindFirstChildOfClass("Tool")
	if tool and tool:GetAttribute("GunName") ~= nil then return tool end
	return nil
end

-- v290: every Gas & Go Mart (Workspace.GasStation, GasStation2, ...) has its own clerk, till and cooldown
local function runStore(store: Model)
local spot = store:WaitForChild("ClerkSpot", 30) :: BasePart?
local register = store:WaitForChild("Register", 30) :: BasePart?
if not (spot and register) then
	warn("[GasStation] no ClerkSpot / Register in " .. store:GetFullName())
	return
end
local holdUp: (Player) -> () -- (defined below; the clerk's prompt calls it)

---------------------------------------------------------------- the clerk
local clerk: Model? = nil
local hum: Humanoid? = nil
local bubbleGui: BillboardGui? = nil
local arms: { { m: Motor6D, rest: CFrame } } = {}

local function say(text: string, secs: number?)
	if not (clerk and clerk.Parent) then return end
	local head = clerk:FindFirstChild("Head") :: BasePart?
	if not head then return end
	if bubbleGui then bubbleGui:Destroy() end
	local b = Instance.new("BillboardGui")
	b.Name = "ClerkSpeech"
	b.Adornee = head
	b.Size = UDim2.fromOffset(240, 50)
	b.StudsOffset = Vector3.new(0, 2.6, 0)
	b.MaxDistance = 60
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Color3.new(1, 1, 1)
	t.BackgroundTransparency = 0.1
	t.TextColor3 = Color3.fromRGB(20, 20, 24)
	t.Font = Enum.Font.GothamMedium
	t.TextScaled = true
	t.Text = text
	Instance.new("UICorner").Parent = t
	t.Parent = b
	b.Parent = head
	bubbleGui = b
	task.delay(secs or 3, function() if b.Parent then b:Destroy() end end)
end

local function handsUp(up: boolean)
	for _, a in arms do
		if a.m.Parent then
			-- R15 shoulders: swing the arm up past the head
			a.m.C0 = if up then a.rest * CFrame.Angles(math.rad(170), 0, 0) else a.rest
		end
	end
end

local function spawnClerk()
	if clerk then clerk:Destroy() end
	local desc = Instance.new("HumanoidDescription")
	desc.HeadColor = Color3.fromRGB(198, 150, 110)
	desc.LeftArmColor, desc.RightArmColor = desc.HeadColor, desc.HeadColor
	desc.LeftLegColor, desc.RightLegColor = Color3.fromRGB(40, 40, 50), Color3.fromRGB(40, 40, 50)
	desc.TorsoColor = Color3.fromRGB(196, 40, 36) -- the store's red polo
	local ok, model = pcall(function() return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15) end)
	if not ok or not model then
		warn("[GasStation] couldn't make the clerk: " .. tostring(model))
		return
	end
	local m = model :: Model
	m.Name = "Clerk"
	local h = m:FindFirstChildOfClass("Humanoid") :: Humanoid
	h.DisplayName = "Clerk"
	h.NameDisplayDistance = 30
	h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart
	m:PivotTo(CFrame.lookAt(spot.Position, spot.Position + Vector3.new(0, 0, -1)))
	root.Anchored = true
	m.Parent = store
	clerk, hum = m, h
	arms = {}
	for _, n in { "RightShoulder", "LeftShoulder" } do
		local mo = m:FindFirstChild(n, true)
		if mo and mo:IsA("Motor6D") then table.insert(arms, { m = mo, rest = mo.C0 }) end
	end
	-- the prompt: hold up the clerk
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "HoldUp"
	pp.ActionText = "Hold up the store"
	pp.ObjectText = "Clerk (gun out)"
	pp.HoldDuration = 0.4
	pp.MaxActivationDistance = 14
	pp.RequiresLineOfSight = false
	pp.Parent = root
	h.Died:Connect(function()
		pp:Destroy()
		print("[GasStation] the clerk was shot")
		task.delay(CLERK_RESPAWN, spawnClerk)
	end)
	pp.Triggered:Connect(function(player) task.spawn(holdUp, player) end)
end

---------------------------------------------------------------- the hold-up
local busy = false
local emptyUntil = 0

local progressGui: BillboardGui? = nil
local function progress(text: string?)
	if progressGui then progressGui:Destroy() progressGui = nil end
	if not text then return end
	local b = Instance.new("BillboardGui")
	b.Adornee = register
	b.Size = UDim2.fromOffset(220, 36)
	b.StudsOffset = Vector3.new(0, 3, 0)
	b.AlwaysOnTop = true
	b.MaxDistance = 40
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	t.BackgroundTransparency = 0.2
	t.TextColor3 = Color3.fromRGB(120, 230, 140)
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.Text = text
	Instance.new("UICorner").Parent = t
	t.Parent = b
	b.Parent = register
	progressGui = b
end

holdUp = function(player: Player)
	if busy or not (clerk and hum and hum.Health > 0) then return end
	local ch = player.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end
	if not gunOut(player) then
		say(({ "Hey there - what can I get you?", "Pump number? Cash or card?", "Can I help you with something?" })[math.random(1, 3)])
		notify(player, "Pull a gun out to rob the store", 3)
		return
	end
	if os.clock() < emptyUntil then
		handsUp(true)
		say("It's EMPTY, I swear! Somebody already got it!", 3)
		task.delay(3, function() handsUp(false) end)
		return
	end
	busy = true
	print(("[GasStation] HOLD-UP by %s"):format(player.Name))
	handsUp(true)
	say(({ "Okay, okay! Don't shoot!", "Whoa - take it, just take it!", "Please! I've got kids!" })[math.random(1, 3)], 3)
	local alarmed = false
	if math.random() < ALARM_AT_START then
		alarmed = true
		reportRobbery(player, register.Position)
		print(("[GasStation] the clerk hit the silent alarm (%s)"):format(player.Name))
	end
	local t0 = os.clock()
	local ok = true
	while os.clock() - t0 < EMPTY_SECONDS do
		task.wait(0.25)
		local c = player.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if not (player.Parent and r and h and h.Health > 0 and hum and hum.Health > 0) then ok = false break end
		if (r.Position - register.Position).Magnitude > REACH or not gunOut(player) then ok = false break end
		progress(("Emptying the register... %d%%"):format(math.floor((os.clock() - t0) / EMPTY_SECONDS * 100)))
	end
	progress(nil)
	if ok then
		local take = math.random(MIN_TAKE, MAX_TAKE)
		economy("AddCash", player, take)
		emptyUntil = os.clock() + COOLDOWN
		say("That's all of it! Now get out!", 3)
		notify(player, ("+$%d from the register"):format(take), 4)
		print(("[GasStation] %s took $%d"):format(player.Name, take))
	else
		say(if hum and hum.Health > 0 then "Get away from me!" else "...", 2)
		print(("[GasStation] hold-up by %s broken off"):format(player.Name))
	end
	-- once the robber's gone, the clerk calls it in
	task.delay(if alarmed then 0 else 6, function()
		if not alarmed and player.Parent then reportRobbery(player, register.Position) end
	end)
	task.wait(2)
	handsUp(false)
	busy = false
end

spawnClerk()
print("[GasStation] the clerk is on shift at " .. store.Name)
end

local running: { [Instance]: boolean } = {}
local function consider(m: Instance)
	if m:IsA("Model") and string.match(m.Name, "^GasStation%d*$") and not running[m] then
		running[m] = true
		task.spawn(runStore, m)
	end
end
for _, m in workspace:GetChildren() do consider(m) end
workspace.ChildAdded:Connect(consider)
