--[[
	PoliceAI · client
	Wanted stars HUD, banners, BUSTED screen, arrest bar, gunfire tracers/sounds,
	flashbang blindness, and the local animation of police lightbars, wheels, rotors
	and the helicopter searchlight. The server clones this into each player's PlayerGui.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer

-- Server Humanoid:MoveTo cannot own an escort while PlayerModule keeps issuing
-- player movement. Suspend only the movement controller during automatic custody.
task.spawn(function()
	local scripts=player:WaitForChild("PlayerScripts",15)
	local module=scripts and scripts:WaitForChild("PlayerModule",15)
	if not module then warn("[CustodyDiag] CONTROLS: PlayerModule missing"); return end
	local ok,controls=pcall(function() return require(module):GetControls() end)
	if not ok or not controls then warn("[CustodyDiag] CONTROLS: unable to load PlayerModule"); return end
	local suspended=false
	local function sync()
		local wanted=player:GetAttribute("CustodyAutoMove")==true
		if wanted==suspended then return end
		suspended=wanted
		if suspended then controls:Disable() else controls:Enable() end
		print("[CustodyDiag] PLAYER CONTROLS "..(if suspended then "SUSPENDED for server escort" else "RESTORED").." owner="..tostring(player:GetAttribute("CustodyOwner")))
	end
	local changed=player:GetAttributeChangedSignal("CustodyAutoMove"):Connect(sync)
	local respawned=player.CharacterAdded:Connect(function() task.defer(sync) end)
	script.Destroying:Connect(function()
		changed:Disconnect(); respawned:Disconnect()
		if suspended then controls:Enable() end
	end)
	sync()
end)
-- Humanoid state enablement is local to each simulation owner.
do
 local guarded,previous
 local function syncSeating()
  local h=player.Character and player.Character:FindFirstChildOfClass("Humanoid")
  -- v239: also while a CO walks you (line-ups, being returned) - NoSit
  local active=player:GetAttribute("CustodyAutoMove")==true or player:GetAttribute("NoSit")==true
  if guarded and (guarded~=h or not active) then
   guarded:SetStateEnabled(Enum.HumanoidStateType.Seated,previous);guarded=nil
  end
  if active and h and not guarded then
   guarded=h;previous=h:GetStateEnabled(Enum.HumanoidStateType.Seated)
   h:SetStateEnabled(Enum.HumanoidStateType.Seated,false);h.Sit=false
  end
 end
 local changed=player:GetAttributeChangedSignal("CustodyAutoMove"):Connect(syncSeating)
 local noSitChanged=player:GetAttributeChangedSignal("NoSit"):Connect(syncSeating)
 local heartbeat=RunService.Heartbeat:Connect(syncSeating)
 script.Destroying:Connect(function()
  changed:Disconnect();noSitChanged:Disconnect();heartbeat:Disconnect()
  if guarded then guarded:SetStateEnabled(Enum.HumanoidStateType.Seated,previous) end
 end)
 syncSeating()
end
local remotes = ReplicatedStorage:WaitForChild("PoliceAIRemotes")
local R = {
	Wanted = remotes:WaitForChild("Wanted") :: RemoteEvent,
	Announce = remotes:WaitForChild("Announce") :: RemoteEvent,
	Flash = remotes:WaitForChild("Flash") :: RemoteEvent,
	Gas = remotes:WaitForChild("Gas") :: RemoteEvent,
	Shots = remotes:WaitForChild("Shots") :: RemoteEvent,
	Debug = remotes:WaitForChild("Debug") :: RemoteEvent,
	Justice = remotes:WaitForChild("Justice") :: RemoteEvent,
}

local gui: ScreenGui
if script.Parent and script.Parent:IsA("ScreenGui") then
	gui = script.Parent
else
	gui = Instance.new("ScreenGui")
	gui.Name = "PoliceAI_HUD"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")
end

local GOLD = Color3.fromRGB(255, 204, 58)
local STYLE_COLORS = {
	info = Color3.fromRGB(245, 245, 245),
	wave = Color3.fromRGB(255, 72, 72),
	danger = Color3.fromRGB(255, 72, 72),
	warn = Color3.fromRGB(255, 168, 48),
	good = Color3.fromRGB(96, 230, 124),
	bad = Color3.fromRGB(255, 72, 72),
}

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function stroke(parent: Instance, thickness: number?, transparency: number?)
	return make("UIStroke", {
		Thickness = thickness or 1.5,
		Transparency = transparency or 0,
		Color = Color3.new(0, 0, 0),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
	}, parent)
end

---------------------------------------------------------------------------
-- HUD layout
---------------------------------------------------------------------------
local topRight = remotes:GetAttribute("HudAnchor") == "TopRight"
local panel = make("Frame", {
	Name = "Wanted",
	BackgroundTransparency = 1,
	AnchorPoint = if topRight then Vector2.new(1, 0) else Vector2.new(0.5, 0),
	Position = if topRight then UDim2.new(1, -12, 0, 4) else UDim2.new(0.5, 0, 0, 4),
	Size = UDim2.fromOffset(250, 86),
	Visible = false,
}, gui)

local starRow = make("Frame", {
	Name = "Stars",
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 34),
}, panel)
make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = if topRight then Enum.HorizontalAlignment.Right else Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 2),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, starRow)

local stars = {}
for i = 1, 6 do -- v212: six stars (the sixth is the military response)
	local holder = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(34, 34),
		LayoutOrder = i,
	}, starRow)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBlack,
		Text = "★",
		TextScaled = true,
		TextColor3 = Color3.fromRGB(45, 45, 45),
		TextTransparency = 0.35,
	}, holder)
	local s = stroke(label, 2, 0.4)
	local scale = make("UIScale", { Scale = 1 }, label)
	stars[i] = { label = label, stroke = s, scale = scale }
end

local status = make("TextLabel", {
	Name = "Status",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 36),
	Size = UDim2.new(1, 0, 0, 18),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextColor3 = Color3.new(1, 1, 1),
	TextXAlignment = if topRight then Enum.TextXAlignment.Right else Enum.TextXAlignment.Center,
	Text = "",
}, panel)
stroke(status, 1.2, 0.2)

local waveText = make("TextLabel", {
	Name = "Wave",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 54),
	Size = UDim2.new(1, 0, 0, 16),
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = Color3.fromRGB(255, 120, 120),
	TextXAlignment = status.TextXAlignment,
	Text = "",
}, panel)
stroke(waveText, 1.2, 0.2)

local evadeBack = make("Frame", {
	Name = "Evade",
	AnchorPoint = if topRight then Vector2.new(1, 0) else Vector2.new(0.5, 0),
	Position = if topRight then UDim2.new(1, 0, 0, 74) else UDim2.new(0.5, 0, 0, 74),
	Size = UDim2.fromOffset(170, 6),
	BackgroundColor3 = Color3.fromRGB(20, 20, 20),
	BackgroundTransparency = 0.3,
	BorderSizePixel = 0,
	Visible = false,
}, panel)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, evadeBack)
local evadeFill = make("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = Color3.fromRGB(96, 200, 255),
	BorderSizePixel = 0,
}, evadeBack)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, evadeFill)

-- arrest bar (bottom-centre, big and obvious)
local arrestFrame = make("Frame", {
	Name = "Arrest",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 0.78, 0),
	Size = UDim2.fromOffset(280, 46),
	BackgroundTransparency = 1,
	Visible = false,
}, gui)
local arrestLabel = make("TextLabel", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 24),
	Font = Enum.Font.GothamBlack,
	TextSize = 18,
	TextColor3 = Color3.fromRGB(255, 90, 90),
	Text = "BEING ARRESTED — RUN!",
}, arrestFrame)
stroke(arrestLabel, 1.5, 0)
local arrestBack = make("Frame", {
	Position = UDim2.fromOffset(20, 30),
	Size = UDim2.new(1, -40, 0, 10),
	BackgroundColor3 = Color3.fromRGB(20, 20, 20),
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
}, arrestFrame)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, arrestBack)
local arrestFill = make("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = Color3.fromRGB(255, 70, 70),
	BorderSizePixel = 0,
}, arrestBack)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, arrestFill)

-- banners
local banner = make("TextLabel", {
	Name = "Banner",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.17, 0),
	Size = UDim2.new(0.9, 0, 0, 40),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	TextColor3 = Color3.new(1, 1, 1),
	TextTransparency = 1,
	Text = "",
}, gui)
make("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 14 }, banner)
local bannerStroke = stroke(banner, 2, 1)

-- BUSTED screen (own gui so it covers the top bar too)
local overlayGui = make("ScreenGui", {
	Name = "PoliceAI_Overlay",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 200,
}, gui.Parent)
local bustedFrame = make("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	Visible = false,
}, overlayGui)
local bustedTitle = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.45),
	Size = UDim2.new(0.8, 0, 0.16, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Text = "BUSTED",
	TextTransparency = 1,
}, bustedFrame)
local bustedStroke = stroke(bustedTitle, 3, 1)
local bustedSub = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromScale(0.5, 0.54),
	Size = UDim2.new(0.8, 0, 0, 30),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextColor3 = Color3.fromRGB(255, 120, 120),
	Text = "",
	TextTransparency = 1,
}, bustedFrame)
make("UITextSizeConstraint", { MaxTextSize = 26 }, bustedSub)

-- flashbang white-out
local whiteout = make("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ZIndex = 10,
}, overlayGui)

---------------------------------------------------------------------------
-- wanted state
---------------------------------------------------------------------------
local hud: any = { s = 0, searching = false, outside = false, evade = 0, arrest = 0, wave = nil, hostile = false, surrendered = false }
local shownStars = 0

local function pop(i: number)
	local st = stars[i]
	st.scale.Scale = 1.9
	TweenService:Create(st.scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function refreshStars()
	for i, st in stars do
		local on = i <= hud.s
		-- v290: prison stars (a CO incident inside the walls, or your standing prison record) are orange
		st.label.TextColor3 = if on then (if hud.prison then Color3.fromRGB(255, 140, 40) elseif i == 6 then Color3.fromRGB(235, 40, 40) else GOLD) else Color3.fromRGB(45, 45, 45)
		st.label.TextTransparency = if on then 0 else 0.35
		st.stroke.Transparency = if on then 0 else 0.4
	end
end

local function refreshStatus()
	if hud.s <= 0 then
		status.Text = ""
		evadeBack.Visible = false
		return
	end
	if hud.prison then
		evadeBack.Visible = false
		if hud.idle then
			status.Text = "PRISON STARS"
			status.TextColor3 = Color3.fromRGB(255, 170, 90)
		elseif hud.surrendered then
			status.Text = "SURRENDERED - STAY STILL"
			status.TextColor3 = Color3.fromRGB(150, 215, 255)
		elseif hud.lethal then
			status.Text = "LETHAL FORCE AUTHORIZED"
			status.TextColor3 = Color3.fromRGB(255, 80, 80)
		else
			status.Text = "PRISON ALERT - COs RESPONDING"
			status.TextColor3 = Color3.fromRGB(255, 170, 90)
		end
		return
	end
	if hud.searching and hud.outside then
		status.Text = "STAY HIDDEN"
		status.TextColor3 = Color3.fromRGB(150, 215, 255)
		evadeBack.Visible = true
		evadeFill.Size = UDim2.fromScale(math.clamp(hud.evade or 0, 0, 1), 1)
	elseif hud.searching then
		status.Text = "SEARCHING — LEAVE THE AREA"
		status.TextColor3 = Color3.fromRGB(255, 220, 120)
		evadeBack.Visible = false
	elseif hud.surrendered then
		status.Text = "SURRENDERED - STAY STILL"
		status.TextColor3 = Color3.fromRGB(150, 215, 255)
		evadeBack.Visible = false
	elseif hud.lethal then
		status.Text = "LETHAL FORCE AUTHORIZED"
		status.TextColor3 = Color3.fromRGB(255, 80, 80)
		evadeBack.Visible = false
	elseif hud.armed then
		status.Text = "DROP THE WEAPON!"
		status.TextColor3 = Color3.fromRGB(255, 170, 50)
		evadeBack.Visible = false
	else
		status.Text = "WANTED ALIVE - NON-LETHAL"
		status.TextColor3 = Color3.new(1, 1, 1)
		evadeBack.Visible = false
	end
end

-- v290: while serving, your prison stars stay on the HUD (they never come off inside)
local function idlePrison(p: any): any
	if (tonumber(p.s) or 0) > 0 then return p end
	local ps = tonumber(player:GetAttribute("PrisonStars")) or 0
	if ps > 0 and player:GetAttribute("CustodyStage") == "Serving" then
		return { s = math.min(ps, 6), prison = true, idle = true }
	end
	return p
end

local function applyHud(payload: any)
	local old = hud.s
	hud = idlePrison(payload)
	hud.s = tonumber(hud.s) or 0
	refreshStars()
	if hud.s > old then
		for i = old + 1, hud.s do
			pop(i)
		end
	end
	shownStars = hud.s
	panel.Visible = hud.s > 0
	waveText.Text = if hud.s > 0 and hud.wave then string.upper(tostring(hud.wave)) else ""
	refreshStatus()

	local a = tonumber(hud.arrest) or 0
	arrestFrame.Visible = hud.s > 0 and a > 0.02
	arrestFill.Size = UDim2.fromScale(math.clamp(a, 0, 1), 1)
end

local lastPayload: any = { s = 0 }
R.Wanted.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	lastPayload = payload
	applyHud(payload)
end)
for _, a in { "PrisonStars", "CustodyStage" } do
	player:GetAttributeChangedSignal(a):Connect(function() applyHud(lastPayload) end)
end
task.defer(applyHud, lastPayload)

---------------------------------------------------------------------------
-- banners / BUSTED
---------------------------------------------------------------------------
local bannerQueue: { { text: string, style: string } } = {}
local bannerBusy = false

local function showBanners()
	if bannerBusy then
		return
	end
	bannerBusy = true
	task.spawn(function()
		while #bannerQueue > 0 do
			local item = table.remove(bannerQueue, 1) :: { text: string, style: string }
			banner.Text = string.upper(item.text)
			banner.TextColor3 = STYLE_COLORS[item.style] or STYLE_COLORS.info
			banner.Position = UDim2.new(0.5, 0, 0.17, -12)
			local info = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(banner, info, { TextTransparency = 0, Position = UDim2.new(0.5, 0, 0.17, 0) }):Play()
			TweenService:Create(bannerStroke, info, { Transparency = 0.1 }):Play()
			task.wait(if #bannerQueue > 0 then 1.8 else 2.8)
			local out = TweenInfo.new(0.35)
			TweenService:Create(banner, out, { TextTransparency = 1 }):Play()
			TweenService:Create(bannerStroke, out, { Transparency = 1 }):Play()
			task.wait(0.35)
		end
		bannerBusy = false
	end)
end

local function showBusted(text: string)
	local parts = string.split(text, "|")
	bustedTitle.Text = parts[1] or "BUSTED"
	bustedSub.Text = parts[2] or ""
	bustedFrame.Visible = true
	bustedFrame.BackgroundTransparency = 1
	local fadeIn = TweenInfo.new(0.4)
	TweenService:Create(bustedFrame, fadeIn, { BackgroundTransparency = 0.35 }):Play()
	TweenService:Create(bustedTitle, fadeIn, { TextTransparency = 0 }):Play()
	TweenService:Create(bustedStroke, fadeIn, { Transparency = 0 }):Play()
	TweenService:Create(bustedSub, fadeIn, { TextTransparency = 0 }):Play()
	task.delay(3.2, function()
		local fadeOut = TweenInfo.new(0.8)
		TweenService:Create(bustedFrame, fadeOut, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(bustedTitle, fadeOut, { TextTransparency = 1 }):Play()
		TweenService:Create(bustedStroke, fadeOut, { Transparency = 1 }):Play()
		TweenService:Create(bustedSub, fadeOut, { TextTransparency = 1 }):Play()
		task.wait(0.85)
		bustedFrame.Visible = false
	end)
end

R.Announce.OnClientEvent:Connect(function(text, style)
	if type(text) ~= "string" then
		return
	end
	if style == "busted" then
		showBusted(text)
		return
	end
	-- drop duplicates / keep the queue short
	for _, q in bannerQueue do
		if q.text == text then
			return
		end
	end
	if #bannerQueue >= 3 then
		table.remove(bannerQueue, 1)
	end
	table.insert(bannerQueue, { text = text, style = if type(style) == "string" then style else "info" })
	showBanners()
end)

---------------------------------------------------------------------------
-- gunfire: tracers, muzzle flash, impacts, 3D sound
---------------------------------------------------------------------------
local fx = Workspace:FindFirstChild("PoliceAI_FX_Local") or make("Folder", { Name = "PoliceAI_FX_Local" }, Workspace)
local terrain = Workspace.Terrain
local SOUND_KEYS = { "SoundPistol", "SoundShotgun", "SoundRifle" }

local function fxPart(size: Vector3, color: Color3, cf: CFrame, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	if shape then
		p.Shape = shape
	end
	p.CFrame = cf
	p.Parent = fx
	return p
end

local function playAt(pos: Vector3, id: string, volume: number, speed: number, maxDist: number)
	if id == "" then
		return
	end
	local att = Instance.new("Attachment")
	att.WorldPosition = pos
	att.Parent = terrain
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = speed
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 14
	s.RollOffMaxDistance = maxDist
	s.Parent = att
	s:Play()
	Debris:AddItem(att, 5)
end

R.Shots.OnClientEvent:Connect(function(batch)
	if type(batch) ~= "table" then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local tracers = remotes:GetAttribute("ShowTracers") ~= false
	local sounds = 0
	for _, shot in batch do
		local origin, hitPos, snd, didHit = shot[1], shot[2], shot[3], shot[4]
		if typeof(origin) ~= "Vector3" or typeof(hitPos) ~= "Vector3" then
			continue
		end
		if (origin - camPos).Magnitude > 700 and (hitPos - camPos).Magnitude > 700 then
			continue
		end
		local delta = hitPos - origin
		local dist = delta.Magnitude
		if dist < 0.5 then
			continue
		end
		local dir = delta / dist

		if snd == -1 then
			-- taser: two thin wires that crackle for a moment
			for _, off in { Vector3.new(0, 0.12, 0), Vector3.new(0, -0.12, 0) } do
				local wire = fxPart(Vector3.new(0.05, 0.05, dist), Color3.fromRGB(150, 220, 255), CFrame.lookAt(origin + off + delta / 2, hitPos + off))
				wire.Transparency = 0.1
				Debris:AddItem(wire, 0.45)
			end
			local spark = fxPart(Vector3.new(0.9, 0.9, 0.9), Color3.fromRGB(170, 230, 255), CFrame.new(hitPos), Enum.PartType.Ball)
			make("PointLight", { Color = Color3.fromRGB(150, 210, 255), Range = 10, Brightness = 4, Shadows = false }, spark)
			Debris:AddItem(spark, 0.3)
			continue
		end

		if tracers then
			local len = math.min(dist, 9)
			local tracer = fxPart(Vector3.new(0.07, 0.07, len), Color3.fromRGB(255, 226, 150), CFrame.lookAt(origin + dir * (len / 2), hitPos))
			tracer.Transparency = 0.15
			local t = math.clamp(dist / 1100, 0.03, 0.3)
			local tween = TweenService:Create(tracer, TweenInfo.new(t, Enum.EasingStyle.Linear), {
				CFrame = CFrame.lookAt(hitPos - dir * (len / 2), hitPos + dir),
			})
			tween:Play()
			Debris:AddItem(tracer, t + 0.05)
		end

		if snd and snd > 0 then
			local flash = fxPart(Vector3.new(0.7, 0.7, 0.7), Color3.fromRGB(255, 200, 90), CFrame.new(origin), Enum.PartType.Ball)
			flash.Transparency = 0.2
			make("PointLight", { Color = Color3.fromRGB(255, 190, 90), Range = 12, Brightness = 3, Shadows = false }, flash)
			Debris:AddItem(flash, 0.06)
			if sounds < 10 then
				sounds += 1
				local key = SOUND_KEYS[snd]
				local id = if key then remotes:GetAttribute(key) or "" else ""
				local volume = if snd == 2 then 1.1 else 0.9
				playAt(origin, id, volume, Random.new():NextNumber(0.94, 1.06), 650)
			end
		end

		if not didHit then
			local spark = fxPart(Vector3.new(0.25, 0.25, 0.25), Color3.fromRGB(255, 230, 170), CFrame.new(hitPos))
			Debris:AddItem(spark, 0.08)
		end
	end
end)

---------------------------------------------------------------------------
-- flashbangs
---------------------------------------------------------------------------
local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "PoliceAI_Flash"
cc.Parent = Lighting
local blur = Instance.new("BlurEffect")
blur.Name = "PoliceAI_FlashBlur"
blur.Size = 0
blur.Parent = Lighting

local shake = { amp = 0, untilT = 0, total = 1 }
local shakeBound = false
local flashToken = 0
local ringing: Sound? = nil

local function startShake(amp: number, duration: number)
	shake.amp = math.max(amp, if os.clock() < shake.untilT then shake.amp else 0)
	shake.total = duration
	shake.untilT = os.clock() + duration
	if shakeBound then
		return
	end
	shakeBound = true
	RunService:BindToRenderStep("PoliceAI_Shake", Enum.RenderPriority.Camera.Value + 1, function()
		local cam = Workspace.CurrentCamera
		local left = shake.untilT - os.clock()
		if left <= 0 or not cam then
			RunService:UnbindFromRenderStep("PoliceAI_Shake")
			shakeBound = false
			return
		end
		local a = math.rad(shake.amp) * (left / shake.total)
		local rng = Random.new()
		cam.CFrame = cam.CFrame * CFrame.Angles(rng:NextNumber(-a, a), rng:NextNumber(-a, a), rng:NextNumber(-a, a) * 0.5)
	end)
end

local function flashBurst(pos: Vector3)
	local ball = fxPart(Vector3.new(1, 1, 1), Color3.new(1, 1, 1), CFrame.new(pos), Enum.PartType.Ball)
	ball.Transparency = 0
	make("PointLight", { Range = 50, Brightness = 10, Shadows = false }, ball)
	TweenService:Create(ball, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(12, 12, 12),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ball, 0.35)
	local smoke = fxPart(Vector3.new(3, 3, 3), Color3.fromRGB(200, 200, 200), CFrame.new(pos), Enum.PartType.Ball)
	smoke.Material = Enum.Material.SmoothPlastic
	smoke.Transparency = 0.5
	TweenService:Create(smoke, TweenInfo.new(2.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(14, 10, 14),
		Transparency = 1,
		CFrame = CFrame.new(pos + Vector3.new(0, 3, 0)),
	}):Play()
	Debris:AddItem(smoke, 2.6)
end

R.Flash.OnClientEvent:Connect(function(pos, effectKind, effectStrength)
	if typeof(pos) ~= "Vector3" then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	-- v142: rubber round head/body impacts reuse this remote for a short concussion
	-- effect: camera instability, desaturation and blur without the flashbang white-out.
	if effectKind == "concussion" then
		local intensity = math.clamp(tonumber(effectStrength) or 0.5, 0.2, 1)
		local cc=Instance.new("ColorCorrectionEffect");cc.Name="PoliceConcussion";cc.Parent=Lighting
		local blur=Instance.new("BlurEffect");blur.Parent=Lighting
		Debris:AddItem(cc,4);Debris:AddItem(blur,4)
		startShake(3.2 * intensity, 0.9 + 1.5 * intensity)
		cc.Brightness = -0.08 * intensity; cc.Contrast = 0.28 * intensity; cc.Saturation = -0.85 * intensity
		blur.Size = 18 * intensity
		local vignette = make("Frame", { Name = "RubberConcussion", BackgroundColor3 = Color3.new(0,0,0), BackgroundTransparency = 0.82, Size = UDim2.fromScale(1,1), ZIndex = 95 }, gui)
		TweenService:Create(vignette, TweenInfo.new(0.18), { BackgroundTransparency = 0.68 }):Play()
		task.delay(0.35 + intensity * 0.55, function()
			
			TweenService:Create(cc, TweenInfo.new(1.2 + intensity), { Brightness = 0, Contrast = 0, Saturation = 0 }):Play()
			TweenService:Create(blur, TweenInfo.new(1.0 + intensity), { Size = 0 }):Play()
			TweenService:Create(vignette, TweenInfo.new(0.8 + intensity), { BackgroundTransparency = 1 }):Play()
			Debris:AddItem(vignette, 1.9 + intensity)
		end)
		return
	end
	if (camPos - pos).Magnitude < 500 then
		flashBurst(pos)
		local bangId = remotes:GetAttribute("SoundFlashbang") or ""
		if bangId ~= "" then
			playAt(pos, bangId, 1.6, 1, 500)
		else
			playAt(pos, remotes:GetAttribute("SoundShotgun") or "", 2, 0.55, 500)
		end
	end

	local radius = remotes:GetAttribute("FlashRadius") or 42
	local maxBlind = remotes:GetAttribute("FlashMaxBlind") or 5
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not head or not head:IsA("BasePart") or not hum or hum.Health <= 0 then
		return
	end
	local eye = head.Position
	local dist = (eye - pos).Magnitude
	if dist > radius then
		if dist < radius * 2 then
			startShake(0.6, 0.5)
		end
		return
	end
	local intensity = (1 - dist / radius) ^ 0.7

	-- walls in the way soak most of it
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, fx }
	local toEye = eye - pos
	local hit = Workspace:Raycast(pos, toEye, params)
	if hit and hit.Instance.Transparency < 0.5 and (hit.Position - pos).Magnitude < toEye.Magnitude - 1.5 then
		intensity *= 0.35
	end
	-- looking right at it is worst
	local lookDot = cam.CFrame.LookVector:Dot((pos - camPos).Unit)
	local facing = math.clamp(0.55 + 0.45 * lookDot, 0.25, 1)
	local blind = maxBlind * intensity * facing
	startShake(2.5 * intensity, 0.4 + blind * 0.5)
	if blind < 0.25 then
		return
	end

	flashToken += 1
	local token = flashToken
	local hold = blind * 0.35
	local fade = blind * 0.65
	whiteout.BackgroundTransparency = math.min(whiteout.BackgroundTransparency, 1 - math.clamp(intensity * facing * 1.4, 0.35, 1))
	cc.Brightness = 0.7 * intensity
	cc.Contrast = -0.3 * intensity
	cc.Saturation = -0.9 * intensity
	blur.Size = 30 * intensity

	local ringId = remotes:GetAttribute("SoundRinging") or ""
	if ringId ~= "" then
		if ringing then
			ringing:Destroy()
		end
		local s = Instance.new("Sound")
		s.SoundId = ringId
		s.Volume = 0.8 * intensity
		s.Looped = true
		s.Parent = gui
		s:Play()
		ringing = s
		TweenService:Create(s, TweenInfo.new(blind + 1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Volume = 0 }):Play()
		Debris:AddItem(s, blind + 1.6)
	end

	task.delay(hold, function()
		if token ~= flashToken then
			return
		end
		local info = TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(whiteout, info, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(cc, TweenInfo.new(fade * 1.3), { Brightness = 0, Contrast = 0, Saturation = 0 }):Play()
		TweenService:Create(blur, TweenInfo.new(fade * 1.2), { Size = 0 }):Play()
	end)
end)

-- Tear-gas disorientation.  The world-space smoke is replicated by the server;
-- this adds the local watery/blurred vision only when the player's head is
-- actually inside the cloud and not protected by a solid wall.
local gasCC = Instance.new("ColorCorrectionEffect")
gasCC.Name = "PoliceAI_TearGas"
gasCC.Parent = Lighting
local gasBlur = Instance.new("BlurEffect")
gasBlur.Name = "PoliceAI_TearGasBlur"
gasBlur.Size = 0
gasBlur.Parent = Lighting
local gasToken = 0

R.Gas.OnClientEvent:Connect(function(pos, radius, duration)
	if typeof(pos) ~= "Vector3" then return end
	radius = tonumber(radius) or (remotes:GetAttribute("GasRadius") or 24)
	duration = tonumber(duration) or (remotes:GetAttribute("GasCloudTime") or 8)
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not head or not head:IsA("BasePart") or not hum or hum.Health <= 0 then return end
	local dist = (head.Position - pos).Magnitude
	if dist > radius then return end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, fx }
	local ray = head.Position - pos
	local hit = Workspace:Raycast(pos + Vector3.new(0, 1, 0), ray, params)
	if hit and hit.Instance.Transparency < 0.5 and (hit.Position - pos).Magnitude < ray.Magnitude - 1.5 then return end

	local intensity = math.clamp(1 - dist / radius, 0.25, 1)
	gasToken += 1
	local token = gasToken
	gasCC.TintColor = Color3.fromRGB(205, 220, 190)
	gasCC.Saturation = -0.65 * intensity
	gasCC.Contrast = -0.18 * intensity
	gasCC.Brightness = 0.08 * intensity
	gasBlur.Size = 15 * intensity
	startShake(1.2 * intensity, math.min(duration, 4))
	task.delay(math.min(duration, 5), function()
		if token ~= gasToken then return end
		local info = TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(gasCC, info, { TintColor = Color3.new(1,1,1), Saturation = 0, Contrast = 0, Brightness = 0 }):Play()
		TweenService:Create(gasBlur, info, { Size = 0 }):Play()
	end)
end)

---------------------------------------------------------------------------
-- police vehicles & helicopters: lightbars, wheels, rotors, searchlight
---------------------------------------------------------------------------
local lamps: { [Instance]: boolean } = {}
local wheels: { [Instance]: number } = {}
local rotors: { [Instance]: number } = {}
local helis: { [Instance]: { a0: Attachment, a1: Attachment, beam: Beam, light: PointLight, aim: Vector3? } } = {}

local function track(tag: string, onAdd: (Instance) -> (), onRemove: (Instance) -> ())
	for _, inst in CollectionService:GetTagged(tag) do
		task.spawn(onAdd, inst)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(onAdd)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(onRemove)
end

track("PoliceLamp", function(inst)
	lamps[inst] = true
end, function(inst)
	lamps[inst] = nil
end)
track("PoliceWheel", function(inst)
	wheels[inst] = 0
end, function(inst)
	wheels[inst] = nil
end)
track("PoliceRotor", function(inst)
	rotors[inst] = 0
end, function(inst)
	rotors[inst] = nil
end)

local function removeHeli(body: Instance)
	local h = helis[body]
	if h then
		h.a0:Destroy()
		h.a1:Destroy()
		helis[body] = nil
	end
end
track("PoliceHeli", function(body)
	if helis[body] then
		return
	end
	local a0 = make("Attachment", { Name = "PoliceSpotA" }, terrain)
	local a1 = make("Attachment", { Name = "PoliceSpotB" }, terrain)
	local beam = make("Beam", {
		Attachment0 = a0,
		Attachment1 = a1,
		Width0 = 1.6,
		Width1 = 16,
		FaceCamera = true,
		Segments = 1,
		LightEmission = 1,
		LightInfluence = 0,
		Color = ColorSequence.new(Color3.fromRGB(255, 250, 225)),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 0.88),
		}),
		Enabled = false,
	}, a0)
	local light = make("PointLight", { Range = 20, Brightness = 2.5, Shadows = false, Enabled = false, Color = Color3.fromRGB(255, 250, 230) }, a1)
	helis[body] = { a0 = a0, a1 = a1, beam = beam, light = light }
end, removeHeli)

local lampState: { [Instance]: boolean } = {}
local spotParams = RaycastParams.new()
spotParams.FilterType = Enum.RaycastFilterType.Exclude

RunService.RenderStepped:Connect(function(dt)
	local t = os.clock()

	-- lightbars: red/blue double-flash, sides alternate
	for lamp in lamps do
		if not lamp.Parent then
			lamps[lamp] = nil
			lampState[lamp] = nil
			continue
		end
		local side = lamp:GetAttribute("Side") or 1
		local phase = (t * 1.9 + (if side == 2 then 0.5 else 0)) % 1
		local on = phase < 0.09 or (phase > 0.16 and phase < 0.25)
		local owner = lamp:FindFirstAncestorOfClass("Model")
		if owner and owner:GetAttribute("Emergency") == false then
			on = false -- cruising patrol car: lights off
		end
		if lampState[lamp] ~= on then
			lampState[lamp] = on
			if lamp:IsA("BasePart") then
				lamp.Transparency = if on then 0 else 0.75
			end
			local light = lamp:FindFirstChildOfClass("PointLight")
			if light then
				light.Enabled = on
			end
		end
	end

	-- wheels roll with the vehicle's forward speed
	for weld, angle in wheels do
		if not weld.Parent or not weld:IsA("JointInstance") then
			wheels[weld] = nil
			continue
		end
		local body = weld.Part0
		local base = weld:GetAttribute("BaseC0")
		if body and typeof(base) == "CFrame" then
			local speed = body.AssemblyLinearVelocity:Dot(body.CFrame.LookVector)
			local radius = weld:GetAttribute("Radius") or 1.3
			angle -= speed / radius * dt
			wheels[weld] = angle
			weld.C0 = base * CFrame.Angles(angle, 0, 0)
		end
	end

	-- rotors
	for weld, angle in rotors do
		if not weld.Parent or not weld:IsA("JointInstance") then
			rotors[weld] = nil
			continue
		end
		local base = weld:GetAttribute("BaseC0")
		if typeof(base) == "CFrame" then
			angle = (angle + (weld:GetAttribute("Spin") or 20) * dt) % (math.pi * 2)
			rotors[weld] = angle
			weld.C0 = if weld:GetAttribute("Axis") == "X" then base * CFrame.Angles(angle, 0, 0) else base * CFrame.Angles(0, angle, 0)
		end
	end

	-- helicopter searchlights
	for body, h in helis do
		if not body.Parent then
			removeHeli(body)
			continue
		end
		local target = body:GetAttribute("SpotTarget")
		local origin = body:FindFirstChild("SpotOrigin")
		-- v286w: lock onto the lit player's live position (a little ahead of a moving car) and ease
		-- toward it - the beam used to jump each time the server updated SpotTarget
		local subj = body:GetAttribute("SpotSubject")
		if typeof(target) == "Vector3" and type(subj) == "number" then
			local sp = Players:GetPlayerByUserId(subj)
			local sr = sp and sp.Character and sp.Character:FindFirstChild("HumanoidRootPart")
			if sr and sr:IsA("BasePart") then target = sr.Position + sr.AssemblyLinearVelocity * 0.08 end
		end
		if typeof(target) == "Vector3" then
			h.aim = if h.aim and (h.aim - target).Magnitude < 80 then h.aim:Lerp(target, 1 - math.exp(-dt * 14)) else target
			target = h.aim
		else
			h.aim = nil
		end
		if typeof(target) == "Vector3" and origin and origin:IsA("Attachment") then
			local from = origin.WorldPosition
			local dir = (target - from)
			spotParams.FilterDescendantsInstances = { body.Parent :: Instance, fx }
			local hit = Workspace:Raycast(from, dir * 1.15, spotParams)
			local spot = if hit then hit.Position else target
			h.a0.WorldPosition = from
			h.a1.WorldPosition = spot + Vector3.new(0, 0.4, 0)
			h.beam.Enabled = true
			h.light.Enabled = true
		else
			h.beam.Enabled = false
			h.light.Enabled = false
		end
	end

	-- wanted stars blink while the cops are searching
	if shownStars > 0 and hud.searching then
		local dim = (t * 2.2) % 1 < 0.5
		for i = 1, shownStars do
			stars[i].label.TextTransparency = if dim then 0.55 else 0
		end
	end
end)


---------------------------------------------------------------------------
-- surrender (hands up)
---------------------------------------------------------------------------
local surrenderKey = Enum.KeyCode[remotes:GetAttribute("SurrenderKey") or "H"] or Enum.KeyCode.H
local surrenderBtn = make("TextButton", {
	Name = "Surrender",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -14, 1, -150),
	Size = UDim2.fromOffset(128, 42),
	BackgroundColor3 = Color3.fromRGB(28, 28, 32),
	BackgroundTransparency = 0.15,
	Font = Enum.Font.GothamBlack,
	TextSize = 15,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "HANDS UP (H)",
	AutoButtonColor = true,
	Visible = false,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 10) }, surrenderBtn)
stroke(surrenderBtn, 1.5, 0.3)

local function refreshSurrender()
	local canSurrender = remotes:GetAttribute("SurrenderEnabled") ~= false and hud.s > 0
	surrenderBtn.Visible = canSurrender
	if hud.surrendered then
		surrenderBtn.Text = "HANDS DOWN (" .. surrenderKey.Name .. ")"
		surrenderBtn.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
	else
		surrenderBtn.Text = "HANDS UP (" .. surrenderKey.Name .. ")"
		surrenderBtn.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
	end
end

local function toggleSurrender()
	if hud.s <= 0 then
		return
	end
	R.Justice:FireServer("Surrender", not hud.surrendered)
end
surrenderBtn.Activated:Connect(toggleSurrender)
R.Wanted.OnClientEvent:Connect(function()
	task.defer(refreshSurrender)
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == surrenderKey then
		toggleSurrender()
	end
end)

---------------------------------------------------------------------------
-- prison: sentence timer + bail
---------------------------------------------------------------------------
local jailFrame = make("Frame", {
	Name = "Jail",
	-- v290: on the left, clear of the hotbar (it sat on top of the player's items)
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 12, 0.6, 0),
	Size = UDim2.fromOffset(340, 96),
	BackgroundColor3 = Color3.fromRGB(16, 16, 20),
	BackgroundTransparency = 0.2,
	Visible = false,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 12) }, jailFrame)
local jailTitle = make("TextLabel", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(14, 8),
	Size = UDim2.new(1, -28, 0, 26),
	Font = Enum.Font.GothamBlack,
	TextSize = 20,
	TextColor3 = Color3.fromRGB(255, 150, 60),
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "IN PRISON",
}, jailFrame)
local jailCharges = make("TextLabel", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(14, 34),
	Size = UDim2.new(1, -28, 0, 18),
	Font = Enum.Font.Gotham,
	TextSize = 13,
	TextColor3 = Color3.fromRGB(210, 210, 210),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Text = "",
}, jailFrame)
local bailBtn = make("TextButton", {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -12, 1, -10),
	Size = UDim2.fromOffset(150, 30),
	BackgroundColor3 = Color3.fromRGB(46, 120, 60),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextColor3 = Color3.new(1, 1, 1),
	Text = "PAY BAIL",
}, jailFrame)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, bailBtn)
make("TextLabel", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 14, 1, -12),
	Size = UDim2.new(1, -180, 0, 26),
	Font = Enum.Font.Gotham,
	TextSize = 12,
	TextWrapped = true,
	TextColor3 = Color3.fromRGB(170, 170, 170),
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Serve your time - or break out.",
}, jailFrame)
local jailEnd = 0
local bailRate = 0
bailBtn.Activated:Connect(function()
	R.Justice:FireServer("Bail")
end)
task.spawn(function()
	while true do
		task.wait(0.5)
		if jailFrame.Visible then
			local left = math.max(0, math.floor(jailEnd - os.clock()))
			local where = string.upper(tostring(player:GetAttribute("Facility") or "PRISON"))
			-- v288g: a life sentence has no release date
			jailTitle.Text = if left > 1e7 then where .. "  LIFE WITHOUT PAROLE" else string.format("%s  %d:%02d", where, left // 60, left % 60)
			bailBtn.Visible = bailRate > 0 and left > 0
			bailBtn.Text = string.format("PAY BAIL  $%d", left * bailRate)
		end
	end
end)

---------------------------------------------------------------------------
-- police radio + wanted list (law teams only)
---------------------------------------------------------------------------
local radioFrame = make("Frame", {
	Name = "Radio",
	AnchorPoint = Vector2.new(0, 0),
	Position = UDim2.new(0, 12, 0, 60),
	Size = UDim2.fromOffset(320, 150),
	BackgroundTransparency = 1,
}, gui)
make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) }, radioFrame)
local radioOrder = 0
local function radioLine(text: string, color: Color3)
	radioOrder += 1
	local line = make("TextLabel", {
		BackgroundColor3 = Color3.fromRGB(10, 14, 22),
		BackgroundTransparency = 0.35,
		Size = UDim2.new(1, 0, 0, 22),
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "  RADIO: " .. text,
		LayoutOrder = radioOrder,
	}, radioFrame)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, line)
	local lines = {}
	for _, c in radioFrame:GetChildren() do
		if c:IsA("TextLabel") then
			table.insert(lines, c)
		end
	end
	table.sort(lines, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #lines > 5 do
		local oldest = table.remove(lines, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(14, function()
		if line.Parent then
			local fade = TweenInfo.new(1)
			TweenService:Create(line, fade, { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
			task.wait(1)
			line:Destroy()
		end
	end)
end

-- a temporary map ping where the call came from
local function ping(pos: Vector3, stars: number)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = pos + Vector3.new(0, 6, 0)
	anchor.Parent = fx
	local bb = make("BillboardGui", {
		Size = UDim2.fromOffset(90, 40),
		AlwaysOnTop = true,
		LightInfluence = 0,
	}, anchor)
	make("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(255, 90, 90),
		TextStrokeTransparency = 0.2,
		Text = "▼ " .. string.rep("★", math.max(stars, 1)),
	}, bb)
	Debris:AddItem(anchor, 25)
end

local listFrame = make("Frame", {
	Name = "WantedList",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 12, 1, -170),
	Size = UDim2.fromOffset(230, 20),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Color3.fromRGB(10, 14, 22),
	BackgroundTransparency = 0.3,
	Visible = false,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, listFrame)
make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, listFrame)
make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, listFrame)

local function isLawTool(t: Instance): boolean
	return t:IsA("Tool") and t:GetAttribute("PoliceTool") ~= nil
end

local function iAmLaw(): boolean
	local bp = player:FindFirstChildOfClass("Backpack")
	local char = player.Character
	for _, container in { bp, char } do
		if container then
			for _, t in container:GetChildren() do
				if isLawTool(t) then
					return true
				end
			end
		end
	end
	return false
end

task.spawn(function()
	while true do
		task.wait(2)
		local law = iAmLaw()
		for _, c in listFrame:GetChildren() do
			if c:IsA("TextLabel") then
				c:Destroy()
			end
		end
		if not law then
			listFrame.Visible = false
			continue
		end
		local myChar = player.Character
		local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
		local rows = {}
		for _, other in Players:GetPlayers() do
			local st = other:GetAttribute("WantedStars") or 0
			if other ~= player and st > 0 then
				local root = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
				local d = if myRoot and root and myRoot:IsA("BasePart") and root:IsA("BasePart") then math.floor((root.Position - myRoot.Position).Magnitude) else nil
				table.insert(rows, { name = other.Name, stars = st, dist = d })
			end
		end
		table.sort(rows, function(a, b)
			return a.stars > b.stars
		end)
		listFrame.Visible = #rows > 0
		make("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 16),
			Font = Enum.Font.GothamBlack,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(255, 205, 60),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "WANTED",
			LayoutOrder = 0,
		}, listFrame)
		for i, r in rows do
			if i > 6 then
				break
			end
			make("TextLabel", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 16),
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = Color3.new(1, 1, 1),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = string.format("%s  %s%s", string.rep("★", r.stars), r.name, if r.dist then "  " .. r.dist .. "m" else ""),
				LayoutOrder = i,
			}, listFrame)
		end
	end
end)

---------------------------------------------------------------------------
-- handcuffs / taser: click (or tap) a suspect; falls back to the nearest one in front of you
---------------------------------------------------------------------------
local mouse = player:GetMouse()
local function suspectFromPart(part: Instance?): Player?
	local node = part
	while node and node ~= Workspace do
		if node:IsA("Model") then
			local p = Players:GetPlayerFromCharacter(node)
			if p then
				return p
			end
		end
		node = node.Parent
	end
	return nil
end

local function nearestSuspect(range: number): Player?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local cam = Workspace.CurrentCamera
	if not root or not root:IsA("BasePart") or not cam then
		return nil
	end
	local best, bestD = nil, range
	for _, other in Players:GetPlayers() do
		if other ~= player and (other:GetAttribute("WantedStars") or 0) > 0 then
			local r = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				local delta = r.Position - root.Position
				local d = delta.Magnitude
				if d < bestD and (d < 6 or cam.CFrame.LookVector:Dot(delta.Unit) > 0.35) then
					best, bestD = other, d
				end
			end
		end
	end
	return best
end

local function hookTool(tool: Tool)
	if tool:GetAttribute("HookedByPoliceClient") then
		return
	end
	tool:SetAttribute("HookedByPoliceClient", true)
	tool.Activated:Connect(function()
		local kind = tool:GetAttribute("PoliceTool")
		local range = if kind == "Cuffs" then (remotes:GetAttribute("CuffRange") or 9) else (remotes:GetAttribute("TaserRange") or 30)
		local target = suspectFromPart(mouse.Target)
		if not target or target == player then
			target = nearestSuspect(range)
		end
		if target then
			R.Justice:FireServer(if kind == "Cuffs" then "Cuff" else "Tase", target)
		else
			radioLine("No wanted suspect in range", Color3.fromRGB(200, 200, 200))
		end
	end)
end

local function watchCharacter(char: Model)
	for _, c in char:GetChildren() do
		if isLawTool(c) then
			hookTool(c :: Tool)
		end
	end
	char.ChildAdded:Connect(function(c)
		if isLawTool(c) then
			hookTool(c :: Tool)
		end
	end)
end
if player.Character then
	watchCharacter(player.Character)
end
player.CharacterAdded:Connect(watchCharacter)

---------------------------------------------------------------------------
-- messages from the justice system
---------------------------------------------------------------------------
local custodyLabel = make("TextLabel", {
	Name = "Custody",
	-- v290: at the top under the stars, clear of the hotbar
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 96),
	Size = UDim2.fromOffset(420, 40),
	BackgroundColor3 = Color3.fromRGB(16, 16, 20),
	BackgroundTransparency = 0.2,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = Color3.fromRGB(255, 200, 120),
	Text = "",
	Visible = false,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 10) }, custodyLabel)
local fadeFrame = make("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	ZIndex = 20,
}, overlayGui)
local fadeText = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0.8, 0, 0, 40),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	TextColor3 = Color3.new(1, 1, 1),
	TextTransparency = 1,
	ZIndex = 21,
	Text = "",
}, fadeFrame)


-- v84 booking/counsel UI.  The old prison flow was removed by the police
-- rewrite; this panel restores the shared intake -> booking -> case review ->
-- classification -> housing experience on top of the new Justice remote.
local bookingFrame = make("Frame", {
	Name="BookingPanel",AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.54),
	Size=UDim2.fromOffset(520,470),BackgroundColor3=Color3.fromRGB(18,22,32),BackgroundTransparency=0.03,
	Visible=false,ZIndex=30,
}, overlayGui)
make("UICorner",{CornerRadius=UDim.new(0,12)},bookingFrame)
make("TextLabel",{
	Position=UDim2.new(0,18,0,12),Size=UDim2.new(1,-70,0,38),BackgroundTransparency=1,
	Text="BOOKING - SELECT COUNSEL",TextColor3=Color3.new(1,1,1),Font=Enum.Font.GothamBlack,TextSize=21,
	TextXAlignment=Enum.TextXAlignment.Left,ZIndex=31,
},bookingFrame)
local bookingCaseText=make("TextLabel",{
	Position=UDim2.new(0,18,0,55),Size=UDim2.new(1,-36,0,78),BackgroundTransparency=1,
	Text="",TextWrapped=true,TextColor3=Color3.fromRGB(220,225,235),Font=Enum.Font.Gotham,TextSize=14,
	TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,ZIndex=31,
},bookingFrame)
local closeBooking=make("TextButton",{
	AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-12,0,12),Size=UDim2.fromOffset(38,38),
	BackgroundColor3=Color3.fromRGB(90,40,40),TextColor3=Color3.new(1,1,1),Text="X",Font=Enum.Font.GothamBold,TextSize=17,ZIndex=31,
},bookingFrame)
make("UICorner",{CornerRadius=UDim.new(0,8)},closeBooking)
closeBooking.Activated:Connect(function() bookingFrame.Visible=false end)
-- v231: shrink the counsel panel to fit small (phone) screens - the bottom
-- choices (Premier Counsel) used to hang off the screen and couldn't be tapped
do
	local scale=Instance.new("UIScale");scale.Parent=bookingFrame
	local function fit()
		local cam=workspace.CurrentCamera
		if not cam then return end
		local vp=cam.ViewportSize
		scale.Scale=math.clamp(math.min((vp.Y-70)/470,(vp.X-20)/520),0.4,1)
	end
	fit()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(fit)
	RunService.RenderStepped:Connect(function() if bookingFrame.Visible then fit() end end)
end
bookingFrame.Position=UDim2.fromScale(0.5,0.5)
local counselChoices={
	{"Public Defender",0},{"Local Attorney",10000},{"Experienced Defense Counsel",50000},
	{"Criminal Defense Firm",250000},{"Elite Defense Team",1000000},
	{"National Trial Firm",5000000},{"Premier Counsel",10000000},
}
for i,info in ipairs(counselChoices) do
	local price=if info[2]==0 then "FREE" else ("$"..tostring(info[2]))
	local btn=make("TextButton",{
		Position=UDim2.new(0,18,0,137+(i-1)*44),Size=UDim2.new(1,-36,0,38),
		BackgroundColor3=Color3.fromRGB(42,56,82),TextColor3=Color3.new(1,1,1),
		Text=info[1].."  -  "..price,Font=Enum.Font.GothamBold,TextSize=15,ZIndex=31,
	},bookingFrame)
	make("UICorner",{CornerRadius=UDim.new(0,7)},btn)
	btn.Activated:Connect(function()
		bookingFrame.Visible=false
		R.Justice:FireServer("SelectCounsel",info[1])
	end)
end
local bookingPhone=make("TextButton",{
	AnchorPoint=Vector2.new(0.5,1),Position=UDim2.new(0.5,0,1,-70),Size=UDim2.fromOffset(220,42),
	BackgroundColor3=Color3.fromRGB(35,82,58),TextColor3=Color3.new(1,1,1),Text="OPEN BOOKING PHONE",
	Font=Enum.Font.GothamBold,TextSize=14,Visible=false,
},gui)
make("UICorner",{CornerRadius=UDim.new(0,9)},bookingPhone)
bookingPhone.Activated:Connect(function() R.Justice:FireServer("RequestCounselMenu") end)

local bookingWatch=0
RunService.Heartbeat:Connect(function(dt)
	bookingWatch+=dt;if bookingWatch<0.35 then return end;bookingWatch=0
	local state=player:GetAttribute("BookingState")
	bookingPhone.Visible=state=="Booking" and not player:GetAttribute("CounselName")
	if state and state~="Housed" and custodyLabel.Visible==false then
		custodyLabel.Text="PRISON PROCESSING - "..string.upper(tostring(state))
		custodyLabel.Visible=true
	end
end)

R.Justice.OnClientEvent:Connect(function(kind, a, b, c)
	if kind == "Custody" then
		custodyLabel.Text = "IN CUSTODY - " .. tostring(a or "")
		custodyLabel.Visible = true
		return
	elseif kind == "Booking" then
		custodyLabel.Visible = false
		fadeText.Text = "Booking at " .. tostring(a or "prison") .. "..."
		TweenService:Create(fadeFrame, TweenInfo.new(0.8), { BackgroundTransparency = 0 }):Play()
		TweenService:Create(fadeText, TweenInfo.new(0.8), { TextTransparency = 0 }):Play()
		task.delay(3, function()
			TweenService:Create(fadeFrame, TweenInfo.new(1.2), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(fadeText, TweenInfo.new(1.2), { TextTransparency = 1 }):Play()
		end)
		return
	end
	if kind == "Intake" then
		custodyLabel.Text="IN CUSTODY - Intake processing"
		custodyLabel.Visible=true
		radioLine("INTAKE: "..tostring(a or 0).." charge(s) - "..tostring(b or ""),Color3.fromRGB(255,205,90))
		return
	elseif kind == "BookingReady" then
		custodyLabel.Text="IN CUSTODY - Booking"
		custodyLabel.Visible=true
		bookingCaseText.Text=("Charges (%s): %s\n\nChoose counsel. Better counsel improves mitigation odds, but no result is guaranteed."):format(tostring(a or 0),tostring(b or ""))
		bookingFrame.Visible=true
		return
	elseif kind == "CaseReview" then
		bookingFrame.Visible=false
		custodyLabel.Text="IN CUSTODY - Case review"
		radioLine(tostring(a or "Case review underway"),Color3.fromRGB(210,220,255))
		return
	elseif kind == "Classification" then
		custodyLabel.Text="IN CUSTODY - Classification: "..tostring(a or "")
		radioLine(("CLASSIFICATION: %s security / %ss"):format(tostring(a or ""),tostring(b or "")),Color3.fromRGB(255,205,90))
		return
	elseif kind == "Sentenced" then
		radioLine(("CASE COMPLETE: %s / %s - %s"):format(tostring(b or ""),if (tonumber(a) or 0)>1e7 then "LIFE" else tostring(a or "").."s",tostring(c or "")),Color3.fromRGB(255,205,90))
		return
	elseif kind == "Housed" then
		bookingFrame.Visible=false;bookingPhone.Visible=false
		custodyLabel.Text="HOUSING ASSIGNMENT - "..tostring(a or "cell").." ["..tostring(b or "").."]"
		task.delay(4,function() if player:GetAttribute("BookingState")=="Housed" then custodyLabel.Visible=false end end)
		return
	end
	if kind == "Jailed" then
		custodyLabel.Visible = false
		jailEnd = os.clock() + (tonumber(a) or 0)
		jailCharges.Text = "Charges: " .. tostring(b or "")
		bailRate = tonumber(c) or 0
		jailFrame.Visible = true
	elseif kind == "Released" then
		jailFrame.Visible = false
		bookingFrame.Visible=false;bookingPhone.Visible=false;custodyLabel.Visible=false
		local msg = if a == "bail" then "Bailed out" elseif a == "executed" then "Executed - your record and belongings have been wiped" elseif a == "killed" then "Killed in prison - your record and belongings have been wiped" elseif a == "escaped" then "You broke out - every cop in the city is looking for you" else "Sentence served - you're free"
		table.insert(bannerQueue, { text = msg, style = if a == "escaped" then "wave" else "good" })
		showBanners()
	elseif kind == "Dispatch" then
		local stars = tonumber(c) or 0
		radioLine(tostring(a), if stars >= 3 then Color3.fromRGB(255, 110, 110) elseif stars >= 1 then Color3.fromRGB(255, 205, 90) else Color3.fromRGB(150, 210, 255))
		if typeof(b) == "Vector3" then
			ping(b, stars)
		end
	elseif kind == "Notice" then
		radioLine(tostring(a), Color3.fromRGB(230, 230, 230))
	end
end)
R.Justice:FireServer("Sync")

---------------------------------------------------------------------------
-- Studio test keys (the server ignores these outside Studio)
---------------------------------------------------------------------------
if remotes:GetAttribute("DebugKeys") then
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.Equals or k == Enum.KeyCode.KeypadPlus then
			R.Debug:FireServer(1)
		elseif k == Enum.KeyCode.Minus or k == Enum.KeyCode.KeypadMinus then
			R.Debug:FireServer(-1)
		end
	end)
end

-- ask for the current wanted state (covers rejoining mid-chase)
R.Wanted:FireServer()
