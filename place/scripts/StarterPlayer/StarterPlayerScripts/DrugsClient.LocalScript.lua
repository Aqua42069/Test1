-- DrugsClient (v252, v253 hallucinations): what being high / drunk looks like. Reads the Intox_* attributes
-- the server's Drugs script keeps on the player. Everything here is local to you.
--   light:  blur, colour shift, a gentle sway
--   medium: tunnel vision, wobble, muffled sound
--   heavy:  warped colours, breathing screen edges, slow-motion feel
-- Each substance has its own look: alcohol = blurry and swaying, weed = soft and warm,
-- party pills = bright and saturated, stims = sharp and twitchy, heavy = dark and slow,
-- spice = sickly green, warped and pulsing. Also: Comedown (grey and dull), Overdosed.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local blur = Instance.new("BlurEffect")
blur.Name = "DrugBlur"
blur.Size = 0
blur.Parent = Lighting
local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "DrugColor"
cc.Parent = Lighting

-- tunnel vision: four dark edges whose thickness breathes
local gui = Instance.new("ScreenGui")
gui.Name = "DrugVignette"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = -5
gui.Parent = player:WaitForChild("PlayerGui")
local edges = {}
for i, spec in { { 0, 0, 1, 0, 90 }, { 0, 1, 1, 0, -90 }, { 0, 0, 0, 1, 0 }, { 1, 0, 0, 1, 180 } } do
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BorderSizePixel = 0
	f.BackgroundTransparency = 0
	f.AnchorPoint = Vector2.new(spec[1], spec[2])
	f.Position = UDim2.fromScale(spec[1], spec[2])
	local g = Instance.new("UIGradient")
	g.Rotation = spec[5]
	g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	g.Parent = f
	f.Parent = gui
	edges[i] = { frame = f, horizontal = spec[3] == 1 }
end

local function lvl(name: string): number
	return tonumber(player:GetAttribute("Intox_" .. name)) or 0
end

local defaultFov = camera.FieldOfView
local swayOffset = CFrame.new()
local baseReverb = SoundService.AmbientReverb
local touching = false

RunService:BindToRenderStep("DrugsCamera", Enum.RenderPriority.Camera.Value + 1, function()
	local t = os.clock()
	local alcohol, weed, party, stims, heavy, spice = lvl("Alcohol"), lvl("Weed"), lvl("Party"), lvl("Stims"), lvl("Heavy"), lvl("Spice")
	local comedown = (tonumber(player:GetAttribute("Comedown")) or 0) > 0
	local od = player:GetAttribute("Overdosed") == true
	local total = math.clamp(alcohol + weed * 0.6 + party * 0.7 + stims * 0.5 + heavy + spice * 1.3, 0, 2)

	-- blur: alcohol and heavy drugs smear everything; spice pulses
	local b = alcohol * 9 + weed * 4 + heavy * 10 + spice * (8 + math.sin(t * 3) * 5) + (if od then 18 else 0)
	blur.Size = math.clamp(b, 0, 28)

	-- colour: each drug has its own tint
	local sat = party * 0.9 + stims * 0.3 - heavy * 0.5 - (if comedown then 0.45 else 0) + spice * math.sin(t * 1.7) * 0.6
	local contrast = stims * 0.35 + party * 0.2 + spice * 0.3 - weed * 0.1
	local bright = party * 0.08 - heavy * 0.12 - (if od then 0.3 else 0)
	local tint = Color3.new(1, 1, 1)
	if spice > 0.05 then
		tint = Color3.new(1 - spice * 0.35, 1, 1 - spice * 0.5) -- sickly green
	elseif party > 0.05 then
		local h = (t * 0.15) % 1
		tint = Color3.new(1, 1, 1):Lerp(Color3.fromHSV(h, 0.5, 1), math.clamp(party, 0, 0.6))
	elseif weed > 0.05 then
		tint = Color3.new(1, 1 - weed * 0.08, 1 - weed * 0.2) -- warm
	elseif heavy > 0.05 then
		tint = Color3.new(1 - heavy * 0.2, 1 - heavy * 0.2, 1 - heavy * 0.05) -- cold and dark
	end
	cc.Saturation = math.clamp(sat, -0.9, 1)
	cc.Contrast = math.clamp(contrast, -0.3, 0.6)
	cc.Brightness = math.clamp(bright, -0.4, 0.2)
	cc.TintColor = tint

	-- tunnel vision that breathes (medium and up)
	local tunnel = math.clamp((total - 0.35) * 0.4 + (if od then 0.35 else 0), 0, 0.42)
	local breath = 1 + math.sin(t * (if stims > 0.2 then 4 else 1.4)) * 0.18 * math.clamp(total, 0, 1)
	for _, e in edges do
		local s = tunnel * breath
		e.frame.Size = if e.horizontal then UDim2.fromScale(1, s) else UDim2.fromScale(s, 1)
		e.frame.Visible = s > 0.005
	end

	-- sway / wobble: alcohol rolls, stims jitter, spice warps the field of view
	-- v253 withdrawal: the shakes
	local shakes = if player:GetAttribute("Withdrawal") then 0.006 else 0
	local roll = math.sin(t * 0.9) * alcohol * 0.06 + math.sin(t * 0.6) * heavy * 0.03 + (math.random() - 0.5) * shakes
	local yaw = math.sin(t * 0.55) * alcohol * 0.025 + math.sin(t * 0.4) * weed * 0.01
	local jitter = stims * 0.004
	swayOffset = CFrame.Angles((math.random() - 0.5) * jitter, yaw + (math.random() - 0.5) * jitter, roll)
	if total > 0.02 then
		camera.CFrame = camera.CFrame * swayOffset
	end
	-- field of view and sound are only touched while something is in your system, so
	-- other scripts (scopes, cutscenes) keep control the rest of the time
	if shakes > 0 then
		camera.CFrame = camera.CFrame * CFrame.Angles((math.random() - 0.5) * shakes, (math.random() - 0.5) * shakes, 0)
		cc.Saturation = math.min(cc.Saturation, -0.25)
	end
	local active = total > 0.02 or od
	if active then
		if not touching then
			touching = true
			defaultFov = camera.FieldOfView
		end
		camera.FieldOfView = defaultFov + spice * math.sin(t * 2.3) * 12 + party * 4 - heavy * 4
		local muffle = heavy + spice + (if od then 1 else 0)
		SoundService.AmbientReverb = if muffle > 0.4 then Enum.ReverbType.UnderWater elseif alcohol > 0.5 then Enum.ReverbType.Hallway else baseReverb
	elseif touching then
		touching = false
		camera.FieldOfView = defaultFov
		SoundService.AmbientReverb = baseReverb
	end
end)

---------------------------------------------------------------------------
-- v253 HALLUCINATIONS (spice, heavy drugs, a lot of party pills). All local:
-- nobody else sees any of it.
--   * people look wrong (a CO turns into something else, everyone gets the same dark skin)
--   * things that aren't there: a figure at the edge of your view, a wall, yourself
--   * whispers and fake notices
--   * the blackout: being cuffed / dragged to solitary / overdosing while far gone
--     dissolves the screen into a haze until it's over - you wake up where they put you
---------------------------------------------------------------------------
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local function hallucinationLevel(): number
	return math.clamp(lvl("Spice") * 1.2 + lvl("Heavy") * 0.7 + lvl("Party") * 0.5 + lvl("Weed") * 0.15 - 0.25, 0, 1)
end

local WHISPERS = {
	"they know what you did", "don't turn around", "he's lying to you", "you're not alone in here",
	"they can hear you", "it's in the walls", "nobody's coming", "you left the door open",
	"he's been following you", "look behind you", "they're watching from the towers", "run",
}
local FAKE_NOTICES = {
	"Police are on their way", "Someone put a hit on you", "Your bank account has been frozen",
	"A CO is coming to search your cell", "You are being followed", "WANTED",
}

local hgui = Instance.new("ScreenGui")
hgui.Name = "Hallucinations"
hgui.IgnoreGuiInset = true
hgui.ResetOnSpawn = false
hgui.DisplayOrder = 20
hgui.Parent = player:WaitForChild("PlayerGui")

local function floatingText(text: string, color: Color3, big: boolean?)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(0.5, 0.06)
	l.Position = UDim2.fromScale(math.random(10, 50) / 100, math.random(15, 80) / 100)
	l.Font = Enum.Font.GothamMedium
	l.TextScaled = true
	l.TextColor3 = color
	l.TextTransparency = 1
	l.TextStrokeTransparency = 0.6
	l.Text = text
	if big then
		l.Size = UDim2.fromScale(0.6, 0.09)
		l.Font = Enum.Font.GothamBlack
	end
	l.Parent = hgui
	TweenService:Create(l, TweenInfo.new(1.2), { TextTransparency = 0.15 }):Play()
	task.delay(2.6, function()
		TweenService:Create(l, TweenInfo.new(1.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
	Debris:AddItem(l, 4.5)
end

local function nearbyHumanoidModels(radius: number): { Model }
	local out = {}
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return out
	end
	for _, d in workspace:GetDescendants() do
		if d:IsA("Humanoid") and d.Parent ~= player.Character and d.Parent:IsA("Model") then
			local r = d.Parent:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") and (r.Position - root.Position).Magnitude < radius then
				table.insert(out, d.Parent)
			end
		end
		if #out >= 12 then
			break
		end
	end
	return out
end

-- someone looks wrong for a few seconds
local function wrongFace()
	local list = nearbyHumanoidModels(80)
	if #list == 0 then
		return
	end
	local m = list[math.random(1, #list)]
	local saved = {}
	local tint = if math.random() < 0.5 then Color3.fromRGB(30, 60, 25) else Color3.fromRGB(15, 15, 18)
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
			saved[p] = { p.Color, p.Material }
			p.Color = tint
			p.Material = Enum.Material.SmoothPlastic
		elseif p:IsA("Decal") and p.Name == "face" then
			saved[p] = { p.Transparency }
			p.Transparency = 1
		end
	end
	local head = m:FindFirstChild("Head")
	local eyes = nil
	if head and head:IsA("BasePart") then
		eyes = Instance.new("PointLight")
		eyes.Color = Color3.fromRGB(255, 30, 30)
		eyes.Range = 6
		eyes.Brightness = 4
		eyes.Parent = head
	end
	task.delay(math.random(5, 9), function()
		for p, v in saved do
			if p.Parent then
				if p:IsA("BasePart") then
					p.Color, p.Material = v[1], v[2]
				else
					p.Transparency = v[1]
				end
			end
		end
		if eyes then
			eyes:Destroy()
		end
	end)
end

-- a local copy of something, somewhere it shouldn't be; it vanishes if you look straight at it
local function apparition(source: Model?, distance: number)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not source or not root then
		return
	end
	local okClone, copy = pcall(function()
		local was = source.Archivable
		source.Archivable = true
		local c = source:Clone()
		source.Archivable = was
		return c
	end)
	if not okClone or not copy then
		return
	end
	for _, d in copy:GetDescendants() do
		if d:IsA("BaseScript") or d:IsA("Sound") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	local h = copy:FindFirstChildOfClass("Humanoid")
	if h then
		h.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	-- at the edge of your view
	local look = camera.CFrame.LookVector
	local side = camera.CFrame.RightVector * (if math.random() < 0.5 then -1 else 1)
	local spot = root.Position + (Vector3.new(look.X, 0, look.Z).Unit * 0.6 + side * 0.8).Unit * distance
	copy:PivotTo(CFrame.lookAt(spot, Vector3.new(root.Position.X, spot.Y, root.Position.Z)))
	copy.Parent = workspace.CurrentCamera -- local only
	local t0 = os.clock()
	task.spawn(function()
		while copy.Parent and os.clock() - t0 < 6 do
			local dir = (spot - camera.CFrame.Position).Unit
			if dir:Dot(camera.CFrame.LookVector) > 0.97 then
				break -- you looked right at it: gone
			end
			task.wait(0.1)
		end
		copy:Destroy()
	end)
end

local function fakeWall()
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z).Unit
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Size = Vector3.new(40, 22, 2)
	p.Material = Enum.Material.Brick
	p.Color = Color3.fromRGB(90, 60, 50)
	p.Transparency = 1
	p.CFrame = CFrame.lookAt(root.Position + look * 30 + Vector3.new(0, 8, 0), root.Position + Vector3.new(0, 8, 0))
	p.Parent = workspace.CurrentCamera
	TweenService:Create(p, TweenInfo.new(1.5), { Transparency = 0.1 }):Play()
	task.delay(4, function()
		TweenService:Create(p, TweenInfo.new(1), { Transparency = 1 }):Play()
	end)
	Debris:AddItem(p, 5.2)
end

task.spawn(function()
	while true do
		task.wait(3 + math.random() * 4)
		local h = hallucinationLevel()
		if h <= 0 or math.random() > h + 0.15 then
			continue
		end
		local roll = math.random()
		if roll < 0.25 then
			wrongFace()
		elseif roll < 0.45 then
			local list = nearbyHumanoidModels(120)
			apparition(if #list > 0 then list[math.random(1, #list)] else nil, 28 + math.random() * 20)
		elseif roll < 0.55 and player.Character then
			apparition(player.Character, 22) -- yourself, watching you
		elseif roll < 0.65 then
			fakeWall()
		elseif roll < 0.85 then
			floatingText(WHISPERS[math.random(1, #WHISPERS)], Color3.fromRGB(220, 220, 220))
		else
			floatingText(FAKE_NOTICES[math.random(1, #FAKE_NOTICES)], Color3.fromRGB(255, 70, 70), true)
		end
	end
end)

-- the blackout dreamscape
local dream = Instance.new("Frame")
dream.Size = UDim2.fromScale(1, 1)
dream.BackgroundColor3 = Color3.fromRGB(40, 10, 60)
dream.BackgroundTransparency = 1
dream.BorderSizePixel = 0
dream.ZIndex = 10
dream.Parent = hgui
local dreamGrad = Instance.new("UIGradient")
dreamGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(60, 20, 90)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(20, 80, 90)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 30, 40)),
})
dreamGrad.Parent = dream
local dreaming = false

local DREAM_LINES = { "...where am I...", "the floor is breathing", "someone's carrying me", "so warm...", "don't let go",
	"voices... far away", "is this a dream", "...wake up..." }

local function blackout(seconds: number)
	if dreaming then
		return
	end
	dreaming = true
	print("[DrugsClient] blackout")
	TweenService:Create(dream, TweenInfo.new(2), { BackgroundTransparency = 0.05 }):Play()
	local t0 = os.clock()
	while os.clock() - t0 < seconds and (player:GetAttribute("Overdosed") or os.clock() - t0 < seconds) do
		dreamGrad.Rotation = (os.clock() * 25) % 360
		dreamGrad.Offset = Vector2.new(math.sin(os.clock() * 0.7) * 0.3, math.cos(os.clock() * 0.5) * 0.3)
		if math.random() < 0.03 then
			local l = Instance.new("TextLabel")
			l.BackgroundTransparency = 1
			l.Size = UDim2.fromScale(0.5, 0.06)
			l.Position = UDim2.fromScale(math.random(10, 50) / 100, math.random(20, 75) / 100)
			l.Font = Enum.Font.Gotham
			l.TextScaled = true
			l.TextColor3 = Color3.fromRGB(230, 220, 255)
			l.TextTransparency = 0.3
			l.ZIndex = 11
			l.Text = DREAM_LINES[math.random(1, #DREAM_LINES)]
			l.Parent = hgui
			TweenService:Create(l, TweenInfo.new(3), { TextTransparency = 1 }):Play()
			Debris:AddItem(l, 3.2)
		end
		task.wait(1 / 30)
	end
	-- an overdose stays dark until someone saves you
	while player:GetAttribute("Overdosed") do
		dreamGrad.Rotation = (os.clock() * 10) % 360
		task.wait(1 / 30)
	end
	TweenService:Create(dream, TweenInfo.new(2.5), { BackgroundTransparency = 1 }):Play()
	task.wait(2.5)
	dreaming = false
end

-- far gone + something happens to you = it happens in a dream
player:GetAttributeChangedSignal("Overdosed"):Connect(function()
	if player:GetAttribute("Overdosed") then
		task.spawn(blackout, 4)
	end
end)
player:GetAttributeChangedSignal("CustodyStage"):Connect(function()
	if player:GetAttribute("CustodyStage") and hallucinationLevel() > 0.35 then
		task.spawn(blackout, 14)
	end
end)
player:GetAttributeChangedSignal("Solitary"):Connect(function()
	if player:GetAttribute("Solitary") and hallucinationLevel() > 0.3 then
		task.spawn(blackout, 14)
	end
end)