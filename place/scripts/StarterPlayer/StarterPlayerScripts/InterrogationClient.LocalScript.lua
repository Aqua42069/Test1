-- InterrogationClient (v246-v249)
-- The interview room screen: the detective's lines, your choices, the emotion meters
-- (anxiety, fear, anger, exhaustion), the hold clock, heartbeat / blur / shake effects,
-- inner thoughts, and the v247 "keep your mouth shut" quick-time events.
-- Every control works by touch: big buttons, and Space / A / D on a keyboard.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("Interrogation", 30)
if not remote then return end

local gui: ScreenGui? = nil
local ui: any = {}
local emo = { anxiety = 0, fear = 0, anger = 0, exhaustion = 0 }
local holdEnds = 0
local blur: BlurEffect? = nil
local effectsConn: RBXScriptConnection? = nil
local qteActive = false

local function new(class: string, props: any, parent: Instance?): any
	local o = Instance.new(class)
	for k, v in props do (o :: any)[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function corner(p: Instance, r: number?)
	new("UICorner", { CornerRadius = UDim.new(0, r or 10) }, p)
end

local function button(parent: Instance, text: string, color: Color3?): TextButton
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = color or Color3.fromRGB(40, 48, 62), AutoButtonColor = true,
		Text = text, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextScaled = true,
	}, parent)
	corner(b, 8)
	new("UITextSizeConstraint", { MaxTextSize = 20 }, b)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, b)
	return b
end

local function build()
	if gui then gui:Destroy() end
	local g = new("ScreenGui", { Name = "InterrogationGui", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 20 }, player:WaitForChild("PlayerGui"))
	gui = g
	-- heartbeat vignette
	ui.vignette = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, g)
	ui.stroke = new("UIStroke", { Thickness = 0, Color = Color3.fromRGB(160, 0, 0), Transparency = 0.4 }, ui.vignette)
	-- dialogue panel (bottom)
	local panel = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.new(0.94, 0, 0.42, 0),
		BackgroundColor3 = Color3.fromRGB(14, 18, 26), BackgroundTransparency = 0.12,
	}, g)
	corner(panel, 12)
	new("UISizeConstraint", { MaxSize = Vector2.new(760, 420) }, panel)
	ui.who = new("TextLabel", { Size = UDim2.new(1, -20, 0, 22), Position = UDim2.fromOffset(10, 8), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack, TextColor3 = Color3.fromRGB(255, 200, 90), TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true, Text = "DETECTIVE" }, panel)
	ui.line = new("TextLabel", { Size = UDim2.new(1, -20, 0.3, 0), Position = UDim2.fromOffset(10, 32), BackgroundTransparency = 1,
		Font = Enum.Font.Gotham, TextColor3 = Color3.new(1, 1, 1), TextWrapped = true, TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "" }, panel)
	new("UITextSizeConstraint", { MaxTextSize = 20 }, ui.line)
	-- v257b transcript: the last few lines stay readable above the panel
	ui.history = new("TextLabel", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 0, -6), Size = UDim2.new(1, 0, 0, 96),
		BackgroundColor3 = Color3.fromRGB(10, 12, 18), BackgroundTransparency = 0.35, Font = Enum.Font.Gotham, TextSize = 15,
		TextColor3 = Color3.fromRGB(185, 190, 200), TextWrapped = true, RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Bottom, Text = "" }, panel)
	corner(ui.history, 10)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 6) }, ui.history)
	ui.log = {}
	ui.choices = new("ScrollingFrame", { Size = UDim2.new(1, -20, 0.62, -40), Position = UDim2.new(0, 10, 0.38, 30),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y }, panel)
	new("UIListLayout", { Padding = UDim.new(0, 6) }, ui.choices)
	-- meters + hold clock (top right)
	local side = new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 60), Size = UDim2.fromOffset(200, 132),
		BackgroundColor3 = Color3.fromRGB(14, 18, 26), BackgroundTransparency = 0.2 }, g)
	corner(side, 10)
	ui.clock = new("TextLabel", { Size = UDim2.new(1, -16, 0, 22), Position = UDim2.fromOffset(8, 4), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextColor3 = Color3.fromRGB(255, 120, 120), TextScaled = true, Text = "HOLD 08:00" }, side)
	ui.bars = {}
	for i, key in { "anxiety", "fear", "anger", "exhaustion" } do
		local y = 28 + (i - 1) * 25
		new("TextLabel", { Size = UDim2.fromOffset(78, 18), Position = UDim2.fromOffset(8, y), BackgroundTransparency = 1,
			Font = Enum.Font.Gotham, TextColor3 = Color3.fromRGB(210, 210, 210), TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Left, Text = key:upper() }, side)
		local back = new("Frame", { Size = UDim2.new(1, -96, 0, 12), Position = UDim2.fromOffset(88, y + 3), BackgroundColor3 = Color3.fromRGB(45, 45, 55) }, side)
		corner(back, 6)
		local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ({
			anxiety = Color3.fromRGB(255, 190, 60), fear = Color3.fromRGB(150, 120, 255),
			anger = Color3.fromRGB(255, 80, 70), exhaustion = Color3.fromRGB(120, 170, 200) })[key] }, back)
		corner(fill, 6)
		ui.bars[key] = fill
	end
	-- inner thoughts
	ui.thought = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 70), Size = UDim2.new(0.6, 0, 0, 30),
		BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextColor3 = Color3.fromRGB(230, 230, 255), TextTransparency = 1,
		TextScaled = true, Text = "" }, g)
	new("UITextSizeConstraint", { MaxTextSize = 22 }, ui.thought)
	-- QTE overlay
	ui.qte = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.new(0.8, 0, 0, 220),
		BackgroundColor3 = Color3.fromRGB(10, 10, 14), BackgroundTransparency = 0.1, Visible = false }, g)
	corner(ui.qte, 14)
	new("UISizeConstraint", { MaxSize = Vector2.new(520, 260) }, ui.qte)
end

local function setMeters(e: any, left: number?)
	emo = e or emo
	for key, fill in ui.bars or {} do
		fill.Size = UDim2.fromScale(math.clamp((emo[key] or 0) / 100, 0, 1), 1)
	end
	if left then holdEnds = os.clock() + left end
end

local function startEffects()
	if effectsConn then return end
	blur = new("BlurEffect", { Name = "InterrogationBlur", Size = 0 }, Lighting)
	effectsConn = RunService.RenderStepped:Connect(function()
		if not gui then return end
		local t = os.clock()
		-- hold clock
		local left = math.max(0, holdEnds - t)
		ui.clock.Text = ("HOLD %02d:%02d"):format(math.floor(left / 60), math.floor(left % 60))
		-- heartbeat: faster and stronger with anxiety
		local a = emo.anxiety / 100
		local bpm = 60 + a * 80
		local beat = math.max(0, math.sin(t * bpm / 60 * math.pi * 2)) ^ 6
		ui.stroke.Thickness = 4 + a * 26 * beat
		if blur then blur.Size = (emo.exhaustion / 100) * 6 + a * 4 * beat end
		-- shaky hands / camera when afraid
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			local f = math.max(0, emo.fear - 50) / 50
			hum.CameraOffset = Vector3.new(math.noise(t * 7, 1) * 0.15 * f, math.noise(t * 7, 2) * 0.15 * f, 0)
		end
	end)
end

local function stopEffects()
	if effectsConn then effectsConn:Disconnect(); effectsConn = nil end
	if blur then blur:Destroy(); blur = nil end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then hum.CameraOffset = Vector3.zero end
end

local function thought(text: string)
	ui.thought.Text = text
	ui.thought.TextTransparency = 0
	TweenService:Create(ui.thought, TweenInfo.new(3.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1 }):Play()
end

local function clearChoices()
	for _, c in ui.choices:GetChildren() do if c:IsA("GuiButton") then c:Destroy() end end
end

local TONE_COLORS = {
	calm = Color3.fromRGB(40, 48, 62), lie = Color3.fromRGB(95, 75, 30), aggressive = Color3.fromRGB(110, 40, 40),
	lawyer = Color3.fromRGB(35, 85, 60), snitch = Color3.fromRGB(85, 40, 85), side = Color3.fromRGB(35, 60, 95),
	truth = Color3.fromRGB(60, 60, 60),
}
local function showChoices(list: { any })
	clearChoices()
	for i, c in list do
		local b = button(ui.choices, c.text, TONE_COLORS[c.tone or ""] or (if c.key == "lawyer" then TONE_COLORS.lawyer elseif c.key == "blame" then TONE_COLORS.snitch else nil))
		b.LayoutOrder = i
		b.Activated:Connect(function()
			if qteActive then return end
			clearChoices()
			remote:FireServer("choice", { key = c.key, arg = c.arg })
		end)
	end
end

---------------------------------------------------------------------------
-- v247 QTEs. Each returns a score 0-1. diff 0.2 (easy) .. 0.95 (brutal)
---------------------------------------------------------------------------
local function qteFrame(title: string, hint: string): (Frame, TextLabel)
	local f = ui.qte
	for _, c in f:GetChildren() do if not c:IsA("UICorner") and not c:IsA("UISizeConstraint") then c:Destroy() end end
	f.Visible = true
	new("TextLabel", { Size = UDim2.new(1, -20, 0, 34), Position = UDim2.fromOffset(10, 8), BackgroundTransparency = 1, Font = Enum.Font.GothamBlack,
		TextColor3 = Color3.fromRGB(255, 220, 90), TextScaled = true, Text = title }, f)
	local h = new("TextLabel", { Size = UDim2.new(1, -20, 0, 22), Position = UDim2.fromOffset(10, 44), BackgroundTransparency = 1, Font = Enum.Font.Gotham,
		TextColor3 = Color3.fromRGB(220, 220, 220), TextScaled = true, Text = hint }, f)
	return f, h
end

local function bigButton(f: Frame, text: string): TextButton
	local b = new("TextButton", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.new(0.6, 0, 0, 56),
		BackgroundColor3 = Color3.fromRGB(200, 60, 50), Text = text, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBlack, TextScaled = true }, f)
	corner(b, 12)
	return b
end

-- one "press" from the big button or Space
local function pressSignal(b: TextButton, onPress: () -> ()): { RBXScriptConnection }
	return {
		b.Activated:Connect(onPress),
		UserInputService.InputBegan:Connect(function(input, gp)
			if not gp and input.KeyCode == Enum.KeyCode.Space then onPress() end
		end),
	}
end

local function disconnect(list: { RBXScriptConnection })
	for _, c in list do c:Disconnect() end
end

local QTE = {}

-- rapid taps before the words come out
function QTE.bite(diff: number): number
	local f, h = qteFrame("BITE YOUR TONGUE", "Tap fast!")
	local need = math.floor(8 + diff * 14)
	local time = 4 - diff * 1.3
	local taps = 0
	local bar = new("Frame", { Position = UDim2.new(0.1, 0, 0, 80), Size = UDim2.new(0.8, 0, 0, 18), BackgroundColor3 = Color3.fromRGB(50, 50, 60) }, f)
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(90, 220, 120) }, bar)
	local b = bigButton(f, "TAP")
	local conns = pressSignal(b, function() taps += 1; fill.Size = UDim2.fromScale(math.min(1, taps / need), 1) end)
	local t0 = os.clock()
	while os.clock() - t0 < time and taps < need do
		h.Text = ("Tap fast! %.1fs"):format(time - (os.clock() - t0))
		task.wait()
	end
	disconnect(conns)
	return math.clamp(taps / need, 0, 1)
end

-- press in rhythm with a pulsing ring
function QTE.breath(diff: number): number
	local f, h = qteFrame("STEADY YOUR BREATH", "Press when the ring fills the circle")
	local target = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 120), Size = UDim2.fromOffset(70, 70),
		BackgroundTransparency = 1 }, f)
	new("UIStroke", { Thickness = 3, Color = Color3.fromRGB(90, 220, 120) }, target)
	corner(target, 35)
	local ring = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = target.Position, Size = UDim2.fromOffset(10, 10),
		BackgroundTransparency = 1 }, f)
	local rs = new("UIStroke", { Thickness = 3, Color = Color3.fromRGB(255, 255, 255) }, ring)
	corner(ring, 60)
	local b = bigButton(f, "BREATHE")
	local beats, hits = 5, 0
	for i = 1, beats do
		local period = (1.5 - diff * 0.7) * (1 + (math.random() - 0.5) * diff * 0.8) -- anxiety makes it uneven
		local pressed = false
		local result = false
		local conns = pressSignal(b, function()
			if pressed then return end
			pressed = true
			local s = ring.AbsoluteSize.X
			result = math.abs(s - 70) <= 14 - diff * 6
		end)
		local t0 = os.clock()
		while os.clock() - t0 < period do
			local k = (os.clock() - t0) / period
			ring.Size = UDim2.fromOffset(10 + k * 100, 10 + k * 100)
			task.wait()
		end
		disconnect(conns)
		if result then hits += 1; rs.Color = Color3.fromRGB(90, 220, 120) else rs.Color = Color3.fromRGB(255, 90, 90) end
		h.Text = ("%d / %d"):format(hits, beats)
	end
	return hits / beats
end

-- keep a marker inside a shrinking zone that fear pushes around (hold left / right)
function QTE.nerve(diff: number): number
	local f, h = qteFrame("HOLD YOUR NERVE", "Keep the marker in the green - hold < or > (A / D)")
	local bar = new("Frame", { Position = UDim2.new(0.08, 0, 0, 86), Size = UDim2.new(0.84, 0, 0, 24), BackgroundColor3 = Color3.fromRGB(50, 50, 60) }, f)
	local zone = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromScale(0.36, 1), Position = UDim2.fromScale(0.5, 0),
		BackgroundColor3 = Color3.fromRGB(70, 170, 90) }, bar)
	local marker = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0, 6, 1.6, 0), Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1) }, bar)
	local left = new("TextButton", { Position = UDim2.new(0.05, 0, 1, -68), Size = UDim2.new(0.4, 0, 0, 56), Text = "<",
		BackgroundColor3 = Color3.fromRGB(60, 70, 90), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBlack, TextScaled = true }, f)
	local right = new("TextButton", { Position = UDim2.new(0.55, 0, 1, -68), Size = UDim2.new(0.4, 0, 0, 56), Text = ">",
		BackgroundColor3 = Color3.fromRGB(60, 70, 90), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBlack, TextScaled = true }, f)
	corner(left, 12); corner(right, 12)
	local holdL, holdR = false, false
	local conns = {
		left.MouseButton1Down:Connect(function() holdL = true end), left.MouseButton1Up:Connect(function() holdL = false end),
		right.MouseButton1Down:Connect(function() holdR = true end), right.MouseButton1Up:Connect(function() holdR = false end),
		left.MouseLeave:Connect(function() holdL = false end), right.MouseLeave:Connect(function() holdR = false end),
	}
	local x, v = 0.5, 0
	local inside, total = 0, 0
	local duration = 5
	local t0 = os.clock()
	local last = t0
	while os.clock() - t0 < duration do
		local now = os.clock(); local dt = now - last; last = now
		local kl = holdL or UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left)
		local kr = holdR or UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right)
		local push = math.noise(now * (0.8 + diff), 3) * (0.9 + diff * 1.6) -- fear pushes it around
		v = v * 0.9 + (push + (if kr then 1.2 else 0) - (if kl then 1.2 else 0)) * dt
		x = math.clamp(x + v * dt * 3, 0, 1)
		local width = 0.36 - (now - t0) / duration * (0.16 + diff * 0.1)
		zone.Size = UDim2.fromScale(width, 1)
		marker.Position = UDim2.fromScale(x, 0.5)
		total += dt
		if math.abs(x - 0.5) <= width / 2 then inside += dt end
		h.Text = ("%.0f%%"):format(inside / math.max(total, 0.01) * 100)
		task.wait()
	end
	disconnect(conns)
	return inside / math.max(total, 0.01)
end

-- hold the eye-contact bar steady (hold to raise, release to fall)
function QTE.eye(diff: number): number
	local f, h = qteFrame("DON'T LOOK AWAY", "Hold to keep the bar in the band")
	local bar = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 74), Size = UDim2.fromOffset(40, 120),
		BackgroundColor3 = Color3.fromRGB(50, 50, 60) }, f)
	local band = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromScale(1, 0.3 - diff * 0.12),
		BackgroundColor3 = Color3.fromRGB(70, 170, 90) }, bar)
	local level = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.new(1, 0, 0, 4), Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1) }, bar)
	local b = bigButton(f, "HOLD")
	b.Position = UDim2.new(0.82, 0, 1, -12)
	b.Size = UDim2.new(0.3, 0, 0, 56)
	local holding = false
	local conns = { b.MouseButton1Down:Connect(function() holding = true end), b.MouseButton1Up:Connect(function() holding = false end),
		b.MouseLeave:Connect(function() holding = false end) }
	local y, vy = 0.5, 0
	local inside, total = 0, 0
	local t0 = os.clock()
	local last = t0
	while os.clock() - t0 < 5 do
		local now = os.clock(); local dt = now - last; last = now
		local up = holding or UserInputService:IsKeyDown(Enum.KeyCode.Space)
		vy += ((if up then -1.6 else 1.4) + math.noise(now * 2, 7) * diff * 2) * dt
		vy *= 0.94
		y = math.clamp(y + vy * dt, 0, 1)
		level.Position = UDim2.fromScale(0, y)
		local half = band.Size.Y.Scale / 2
		total += dt
		if math.abs(y - 0.5) <= half then inside += dt end
		h.Text = ("%.0f%%"):format(inside / math.max(total, 0.01) * 100)
		task.wait()
	end
	disconnect(conns)
	return inside / math.max(total, 0.01)
end

-- a sentence types out; stop it before it finishes
local SLIPS = { "Okay, okay, it was my idea to hit the bank and-", "I only drove the car, the gun was his-",
	"We split the money at the motel and then-", "I didn't mean to shoot him, he moved and-" }
function QTE.slip(diff: number): number
	local f, h = qteFrame("CATCH THE SLIP", "Stop yourself before you finish the sentence!")
	local text = SLIPS[math.random(1, #SLIPS)]
	local label = new("TextLabel", { Position = UDim2.new(0.05, 0, 0, 76), Size = UDim2.new(0.9, 0, 0, 60), BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium, TextColor3 = Color3.fromRGB(255, 170, 170), TextWrapped = true, TextScaled = true, Text = "" }, f)
	local b = bigButton(f, "SHUT UP")
	local stopped = false
	local conns = pressSignal(b, function() stopped = true end)
	local cps = 9 + diff * 16
	local start = math.random() < diff * 0.4 and 0.3 or 0 -- fake-out: it starts already halfway
	local shown = math.floor(#text * start)
	local t0 = os.clock()
	while not stopped and shown < #text do
		shown = math.floor(#text * start + (os.clock() - t0) * cps)
		label.Text = string.sub(text, 1, shown)
		task.wait()
	end
	disconnect(conns)
	h.Text = if stopped then "Caught it." else "Too late..."
	return if stopped then math.clamp(1 - shown / #text, 0, 1) * 1.15 else 0
end

-- say "I want a lawyer" clearly: press while the cursor is in the green
function QTE.lawyer(diff: number): number
	local f, h = qteFrame("SAY IT CLEARLY", "\"I want a lawyer.\" - press when the cursor is in the green")
	local bar = new("Frame", { Position = UDim2.new(0.08, 0, 0, 90), Size = UDim2.new(0.84, 0, 0, 24), BackgroundColor3 = Color3.fromRGB(50, 50, 60) }, f)
	local w = 0.26 - diff * 0.14
	local zx = 0.2 + math.random() * (0.6 - w)
	new("Frame", { Position = UDim2.fromScale(zx, 0), Size = UDim2.fromScale(w, 1), BackgroundColor3 = Color3.fromRGB(70, 170, 90) }, bar)
	local cursor = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0, 6, 1.6, 0), Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1) }, bar)
	local b = bigButton(f, "SAY IT")
	local pressedAt: number? = nil
	local conns = pressSignal(b, function() if not pressedAt then pressedAt = cursor.Position.X.Scale end end)
	local t0 = os.clock()
	local speed = 0.6 + diff * 0.9
	while not pressedAt and os.clock() - t0 < 6 do
		local k = ((os.clock() - t0) * speed) % 2
		cursor.Position = UDim2.fromScale(if k > 1 then 2 - k else k, 0.5)
		task.wait()
	end
	disconnect(conns)
	local ok = pressedAt ~= nil and pressedAt >= zx and pressedAt <= zx + w
	h.Text = if ok then "Clear." else "It came out wrong..."
	return if ok then 1 else 0.3
end

local function runQte(kind: string, diff: number, id: number)
	qteActive = true
	local fn = QTE[kind] or QTE.bite
	local ok, score = pcall(fn, diff)
	task.wait(0.6)
	ui.qte.Visible = false
	qteActive = false
	remote:FireServer("qte", id, if ok then score else 0)
end

remote.OnClientEvent:Connect(function(kind: string, a: any, b: any, c: any)
	if kind == "open" then
		build()
		holdEnds = os.clock() + (a and a.hold or 480)
		setMeters(a and a.emo)
		startEffects()
	elseif not gui then
		return
	elseif kind == "say" then
		-- the previous line goes into the transcript
		if ui.line.Text ~= "" then
			local who = ui.who.Text
			local line = ui.line.Text:gsub("<", "&lt;"):gsub(">", "&gt;")
			local prev = (if who ~= "" then ("<b>%s:</b> "):format(who) else "") .. line
			table.insert(ui.log, prev)
			while #ui.log > 4 do table.remove(ui.log, 1) end
			ui.history.Text = table.concat(ui.log, "\n")
		end
		ui.who.Text = tostring(a)
		ui.line.Text = tostring(b)
		ui.who.TextColor3 = if a == "YOUR LAWYER" then Color3.fromRGB(120, 220, 150) elseif a == "" then Color3.fromRGB(170, 170, 170)
			elseif a == player.Name then Color3.fromRGB(150, 190, 255) else Color3.fromRGB(255, 200, 90)
	elseif kind == "choices" then
		showChoices(a or {})
	elseif kind == "meters" then
		setMeters(a, b)
	elseif kind == "thought" then
		thought(tostring(a))
	elseif kind == "qte" then
		task.spawn(runQte, a, b, c)
	elseif kind == "close" then
		clearChoices()
		local s = a or {}
		ui.who.Text = "INTERVIEW OVER"
		ui.line.Text = (if s.lawyered then "You asked for a lawyer. " else "")
			.. (if s.confessed then "You confessed. " else "")
			.. (if s.named and #s.named > 0 then "You named: " .. table.concat(s.named, ", ") .. ". " else "")
			.. (if (s.falseStatements or 0) > 0 then "They caught you lying. " else "")
			.. (if s.protective then "Protective custody granted. " else "")
			.. (if (s.bluffs or 0) > 0 then ("You called %d bluff(s). "):format(s.bluffs) else "")
			.. (if s.violation then ("The detective crossed the line (%s) - your lawyer can use that. "):format(tostring(s.violation)) else "")
		task.delay(6, function()
			stopEffects()
			if gui then gui:Destroy(); gui = nil end
		end)
	end
end)
