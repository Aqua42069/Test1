-- PhoneCallsClient (v256): the incoming-call screen. One UI, two skins:
--   cell   - a phone ringing on screen: Answer / Decline, then the conversation
--   prison - "This call is from a correctional facility" handset, monitored banner
-- In custody a CO sends you to the phone bank (marker + countdown); use the phone
-- (prompt) to take the call. Missed calls: a button bottom-right, tap to call back.
-- Big touch targets; a UIScale fits it to phone screens. Keys 1-9 pick answers.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("PhoneCalls")

local gui = Instance.new("ScreenGui")
gui.Name = "PhoneCalls"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 45
gui.Parent = player:WaitForChild("PlayerGui")
local scale = Instance.new("UIScale")
scale.Parent = gui
local function fit()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	scale.Scale = math.clamp(math.min(vp.X / 1000, vp.Y / 620), 0.6, 1.2)
end
fit()
if workspace.CurrentCamera then workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end

local function corner(p, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 12)
	c.Parent = p
end
local function label(parent, text, size, font, color)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Font = font or Enum.Font.Gotham
	l.TextSize = size or 18
	l.TextColor3 = color or Color3.new(1, 1, 1)
	l.TextWrapped = true
	l.Text = text
	l.Parent = parent
	return l
end
local function button(parent, text, color, h)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, h or 52)
	b.BackgroundColor3 = color
	b.Font = Enum.Font.GothamBold
	b.TextSize = 19
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextWrapped = true
	b.Text = text
	b.AutoButtonColor = true
	corner(b, 10)
	b.Parent = parent
	return b
end

-- ring sound (built-in content)
local ring = Instance.new("Sound")
ring.SoundId = "rbxasset://sounds/electronicpingshort.wav"
ring.Volume = 0.8
ring.Parent = SoundService
local ringing = false
local function startRing()
	if ringing then return end
	ringing = true
	task.spawn(function()
		while ringing do
			ring:Play()
			task.wait(0.25)
			if not ringing then break end
			ring:Play()
			task.wait(1.6)
		end
	end)
end
local function stopRing() ringing = false end

---------------------------------------------------------------------------
-- the call card
---------------------------------------------------------------------------
local card = nil
local cardId = nil
local function closeCard()
	if card then card:Destroy() end
	card, cardId = nil, nil
end

local SKINS = {
	cell = { bg = Color3.fromRGB(14, 16, 22), accent = Color3.fromRGB(70, 200, 120), stroke = Color3.fromRGB(60, 64, 80) },
	prison = { bg = Color3.fromRGB(38, 36, 30), accent = Color3.fromRGB(230, 170, 50), stroke = Color3.fromRGB(110, 100, 70) },
}

local function newCard(spec)
	closeCard()
	local skin = SKINS[spec.skin] or SKINS.cell
	local f = Instance.new("Frame")
	f.Name = "Call"
	f.AnchorPoint = Vector2.new(1, 0.5)
	f.Position = UDim2.new(1, -20, 0.5, 0)
	f.Size = UDim2.new(0, 340, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = skin.bg
	corner(f, 22)
	local s = Instance.new("UIStroke")
	s.Color = skin.stroke
	s.Thickness = 3
	s.Parent = f
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 18), UDim.new(0, 18)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 16), UDim.new(0, 16)
	pad.Parent = f
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 10)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = f
	if spec.skin == "prison" then
		local w = label(f, "This call is from a correctional facility." .. (if spec.monitored then " It is MONITORED and RECORDED." else " Legal call - privileged."), 14, Enum.Font.GothamBold, skin.accent)
		w.LayoutOrder = 1
	end
	local who = label(f, spec.from, 26, Enum.Font.GothamBlack, Color3.new(1, 1, 1))
	who.LayoutOrder = 2
	f.Parent = gui
	card, cardId = f, spec.id
	return f, skin
end

local function showRinging(spec)
	local f, skin = newCard(spec)
	label(f, "Incoming call...", 18, Enum.Font.Gotham, Color3.fromRGB(190, 195, 205)).LayoutOrder = 3
	local row = Instance.new("Frame")
	row.LayoutOrder = 4
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 60)
	row.Parent = f
	local a = button(row, "Answer", skin.accent, 60)
	a.Size = UDim2.new(0.48, 0, 1, 0)
	local d = button(row, "Decline", Color3.fromRGB(200, 50, 50), 60)
	d.Size = UDim2.new(0.48, 0, 1, 0)
	d.Position = UDim2.new(0.52, 0, 0, 0)
	local id = spec.id
	a.Activated:Connect(function() stopRing(); remote:FireServer("answer", id) end)
	d.Activated:Connect(function() stopRing(); remote:FireServer("decline", id); closeCard() end)
	-- the card shakes a little while it rings
	task.spawn(function()
		while card == f and ringing do
			f.Rotation = 2
			task.wait(0.06)
			f.Rotation = -2
			task.wait(0.06)
			f.Rotation = 0
			task.wait(0.8)
		end
		if f.Parent then f.Rotation = 0 end
	end)
	startRing()
end

local function showConnected(spec)
	local f, skin = newCard(spec)
	local order = 3
	for _, line in spec.lines or {} do
		local l = label(f, tostring(line), 18, Enum.Font.Gotham, Color3.fromRGB(225, 228, 235))
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.LayoutOrder = order
		order += 1
	end
	local id = spec.id
	-- v290g: every choice looks the same - the first one used to be the accent colour and read as
	-- the "right" answer. (A lone button keeps the accent.)
	local opts = spec.options or { "OK" }
	for i, opt in opts do
		local b = button(f, (if UserInputService.KeyboardEnabled and i <= 9 then ("[%d] "):format(i) else "") .. tostring(opt), if #opts == 1 then skin.accent else Color3.fromRGB(60, 64, 80))
		b.LayoutOrder = 100 + i
		b.Activated:Connect(function()
			remote:FireServer("choose", id, i)
			closeCard()
		end)
	end
	-- v286v: a timed choice: the bar runs down (Telltale) - when it's gone, the card closes and
	-- the server takes your silence
	local secs = tonumber(spec.seconds)
	if secs and secs > 0 then
		local track = Instance.new("Frame")
		track.LayoutOrder = 99
		track.Size = UDim2.new(1, 0, 0, 6)
		track.BackgroundColor3 = Color3.fromRGB(40, 42, 52)
		track.BorderSizePixel = 0
		track.Parent = f
		local bar = Instance.new("Frame")
		bar.Size = UDim2.new(1, 0, 1, 0)
		bar.BackgroundColor3 = Color3.fromRGB(235, 235, 240)
		bar.BorderSizePixel = 0
		bar.Parent = track
		game:GetService("TweenService"):Create(bar, TweenInfo.new(secs, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 1, 0) }):Play()
		-- what silence picks, so the clock running out is never a surprise
		local def = opts[tonumber(spec.silent) or 1]
		if #opts > 1 and def then
			local note = label(f, ("No answer in time: %s"):format(tostring(def)), 13, Enum.Font.GothamMedium, Color3.fromRGB(150, 154, 168))
			note.TextXAlignment = Enum.TextXAlignment.Left
			note.LayoutOrder = 98
		end
		task.delay(secs, function() if card == f then closeCard() end end)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not card or not cardId then return end
	local n = input.KeyCode.Value - Enum.KeyCode.One.Value + 1
	if n >= 1 and n <= 9 then
		local btns = 0
		for _, c in card:GetChildren() do if c:IsA("TextButton") then btns += 1 end end
		if btns > 0 and n <= btns then
			remote:FireServer("choose", cardId, n)
			closeCard()
		end
	end
end)

---------------------------------------------------------------------------
-- custody: summoned to the phone bank
---------------------------------------------------------------------------
local summon = nil
local function clearSummon()
	if summon then
		if summon.part then summon.part:Destroy() end
		summon.banner:Destroy()
		summon = nil
	end
end

local function showSummon(spec, pos, seconds)
	clearSummon()
	local banner = Instance.new("Frame")
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 60)
	banner.Size = UDim2.new(0, 520, 0, 0)
	banner.AutomaticSize = Enum.AutomaticSize.Y
	banner.BackgroundColor3 = Color3.fromRGB(60, 50, 20)
	corner(banner, 12)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 14), UDim.new(0, 14)
	pad.Parent = banner
	local text = label(banner, "", 18, Enum.Font.GothamBold, Color3.fromRGB(255, 225, 140))
	banner.Parent = gui
	local part = nil
	if typeof(pos) == "Vector3" then
		local p = Instance.new("Part")
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		p.Transparency = 1
		p.Size = Vector3.one
		p.Position = pos + Vector3.new(0, 3, 0)
		local bb = Instance.new("BillboardGui")
		bb.AlwaysOnTop = true
		bb.Size = UDim2.new(0, 150, 0, 40)
		bb.MaxDistance = 1e4
		bb.Parent = p
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromScale(1, 1)
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamBlack
		l.TextSize = 18
		l.TextColor3 = Color3.fromRGB(255, 210, 80)
		l.TextStrokeTransparency = 0.3
		l.Text = "\u{25BC} PHONE"
		l.Parent = bb
		p.Parent = workspace
		part = p
	end
	local me = { id = spec.id, part = part, banner = banner }
	summon = me
	local ends = os.clock() + (tonumber(seconds) or 90)
	task.spawn(function()
		while summon == me do
			local left = math.max(0, math.ceil(ends - os.clock()))
			text.Text = ("CO: \"%s call for you - get to the phone.\"  (%s)  %ds\nWalk to the phone and use it to answer."):format(
				if spec.legal then "Legal" else "Phone", spec.from, left)
			if left <= 0 then break end
			task.wait(0.25)
		end
	end)
	startRing()
	task.delay(3, stopRing)
end

---------------------------------------------------------------------------
-- missed calls
---------------------------------------------------------------------------
local missedBtn = button(gui, "", Color3.fromRGB(200, 50, 50), 46)
missedBtn.AnchorPoint = Vector2.new(1, 1)
missedBtn.Position = UDim2.new(1, -16, 1, -150)
missedBtn.Size = UDim2.new(0, 190, 0, 46)
missedBtn.Visible = false
local missedList = {}
local listFrame = nil
missedBtn.Activated:Connect(function()
	if listFrame then listFrame:Destroy(); listFrame = nil; return end
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(1, 1)
	f.Position = UDim2.new(1, -16, 1, -204)
	f.Size = UDim2.new(0, 300, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
	corner(f, 12)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
	pad.Parent = f
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 6)
	lay.Parent = f
	label(f, "Missed calls - tap to call back", 15, Enum.Font.GothamBold, Color3.fromRGB(190, 195, 205))
	for _, m in missedList do
		local b = button(f, ("%s  (%d:%02d left)"):format(m.from, m.left // 60, m.left % 60), Color3.fromRGB(44, 50, 66), 46)
		b.Activated:Connect(function()
			remote:FireServer("callback", m.id)
			f:Destroy()
			listFrame = nil
		end)
	end
	f.Parent = gui
	listFrame = f
end)

-- v283: the on-screen Lawyer button moved into the phone (the LAWYER app, CityLifeClient)

local function setMissed(list)
	missedList = list or {}
	missedBtn.Visible = #missedList > 0
	missedBtn.Text = ("Missed calls (%d)"):format(#missedList)
	if listFrame then listFrame:Destroy(); listFrame = nil end
end

---------------------------------------------------------------------------
remote.OnClientEvent:Connect(function(kind, a, b, c)
	if kind == "ring" then
		showRinging(a)
	elseif kind == "stopRing" then
		stopRing()
		if cardId == a then closeCard() end
	elseif kind == "connected" then
		stopRing()
		clearSummon()
		showConnected(a)
	elseif kind == "ended" then
		if cardId == a then closeCard() end
	elseif kind == "summon" then
		showSummon(a, b, c)
	elseif kind == "unsummon" then
		if summon and summon.id == a then clearSummon() end
	elseif kind == "missed" then
		setMissed(a)
	elseif kind == "notice" then
		local n = label(gui, tostring(a), 18, Enum.Font.GothamMedium, Color3.new(1, 1, 1))
		n.AnchorPoint = Vector2.new(0.5, 0)
		n.Position = UDim2.new(0.5, 0, 0, 130)
		n.Size = UDim2.new(0, 520, 0, 0)
		n.BackgroundTransparency = 0.15
		n.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
		corner(n, 8)
		task.delay(6, function() n:Destroy() end)
	end
end)

task.delay(3, function() remote:FireServer("missedList") end)
