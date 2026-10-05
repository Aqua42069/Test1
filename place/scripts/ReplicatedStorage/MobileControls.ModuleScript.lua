--[[
	MobileControls (v290) - the game's touch buttons (phone and tablet), placed around Roblox's own
	jump button so they're on screen on every device:
	  "side"  left of jump          (RUN on foot, HANDBRAKE in a car - never both at once)
	  "up"    above jump            (ENTER / EXIT a car)
	  "side2" left of "side"        (STOP - police traffic stop)
	Phone mode (a short screen) uses smaller buttons and tighter spacing than tablet mode; the
	layout follows rotation / resizing. (Context-action buttons sat at fixed offsets and ended
	up off screen on phones.)

	Mobile.button(name, text, color, slot, onDown, onUp?)   -- does nothing without touch
	Mobile.show(name, visible, text?)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local M = {}

local gui: ScreenGui? = nil
local buttons: { [string]: { b: TextButton, slot: string } } = {}

local function jumpButton(): GuiObject?
	local pg = player:FindFirstChild("PlayerGui")
	local tg = pg and pg:FindFirstChild("TouchGui")
	local frame = tg and tg:FindFirstChild("TouchControlFrame")
	local jb = frame and frame:FindFirstChild("JumpButton")
	return if jb and jb:IsA("GuiObject") then jb else nil
end

local function layout()
	if not gui then return end
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1024, 768)
	local phone = math.min(vp.X, vp.Y) < 500
	local size = if phone then 64 else 84
	local gap = if phone then 10 else 16
	gui:SetAttribute("Mode", if phone then "phone" else "tablet")
	local jb = jumpButton()
	local jPos, jSize
	if jb and jb.AbsoluteSize.X > 0 then
		jPos, jSize = jb.AbsolutePosition, jb.AbsoluteSize
		-- the TouchGui doesn't ignore the top inset; ours does
		local tg = jb:FindFirstAncestorOfClass("ScreenGui")
		if tg and not tg.IgnoreGuiInset then jPos += GuiService:GetGuiInset() end
	else
		-- where Roblox puts it
		local js = if phone then 70 else 120
		jSize = Vector2.new(js, js)
		jPos = Vector2.new(vp.X - js - (if phone then 25 else 35), vp.Y - js - (if phone then 20 else 30))
	end
	local spots = {
		side = Vector2.new(jPos.X - size - gap, jPos.Y + jSize.Y - size),
		side2 = Vector2.new(jPos.X - 2 * (size + gap), jPos.Y + jSize.Y - size),
		up = Vector2.new(jPos.X + (jSize.X - size) / 2, jPos.Y - size - gap),
	}
	for _, e in buttons do
		local p = spots[e.slot] or spots.side
		e.b.Size = UDim2.fromOffset(size, size)
		e.b.TextSize = if phone then 13 else 16
		e.b.Position = UDim2.fromOffset(math.clamp(p.X, 4, vp.X - size - 4), math.clamp(p.Y, 4, vp.Y - size - 4))
	end
end

local function ensure(): ScreenGui
	if gui and gui.Parent then return gui end
	local g = Instance.new("ScreenGui")
	g.Name = "MobileControls"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 20
	g.Parent = player:WaitForChild("PlayerGui")
	gui = g
	local cam = workspace.CurrentCamera
	if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(layout) end
	task.spawn(function()
		-- the jump button appears / moves as the touch controls load
		for _ = 1, 20 do
			task.wait(0.5)
			layout()
		end
	end)
	return g
end

function M.button(name: string, text: string, color: Color3, slot: string, onDown: () -> (), onUp: (() -> ())?)
	if not UserInputService.TouchEnabled or buttons[name] then return end
	local g = ensure()
	local b = Instance.new("TextButton")
	b.Name = name
	b.BackgroundColor3 = color
	b.BackgroundTransparency = 0.25
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextWrapped = true
	b.AutoButtonColor = true
	b.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.4
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = b
	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
	end
	b.InputBegan:Connect(function(input)
		if isPress(input) then
			b.BackgroundTransparency = 0
			onDown()
		end
	end)
	b.InputEnded:Connect(function(input)
		if isPress(input) then
			b.BackgroundTransparency = 0.25
			if onUp then onUp() end
		end
	end)
	b.Parent = g
	buttons[name] = { b = b, slot = slot }
	layout()
end

function M.show(name: string, visible: boolean, text: string?)
	local e = buttons[name]
	if not e then return end
	if text then e.b.Text = text end
	if e.b.Visible ~= visible then
		e.b.Visible = visible
		if visible then layout() end
	end
end

return M
