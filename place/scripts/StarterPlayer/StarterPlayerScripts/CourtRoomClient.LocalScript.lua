-- CourtRoomClient (v291): the trial on your screen when you're in the case (the defendant, defence
-- counsel, the prosecutor, the judge, a juror) - ReplicatedStorage.CourtRoom from PoliceSystem.Trial.
--   * THE CASE BOARD: every exhibit the State has, how much it's worth right now (cross-examination
--     breaks them, objections strike lines, motions exclude them), what your investigation found
--     about its weaknesses (the defence only), and - for everyone but the jurors - the State's case
--     against the line a conviction needs.
--   * THE LOG: what's being said in the room.
--   * OBJECTION!: a line comes up during the State's questioning; you have seconds to object and
--     pick the ground (hearsay, leading, speculation, character, relevance).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("CourtRoom", 120)
if not (remote and remote:IsA("RemoteEvent")) then return end

local gui = Instance.new("ScreenGui")
gui.Name = "CourtRoom"
gui.ResetOnSpawn = false
gui.DisplayOrder = 6
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local INK = Color3.fromRGB(232, 234, 240)
local DIM = Color3.fromRGB(150, 155, 170)
local GOOD = Color3.fromRGB(120, 210, 140)
local BAD = Color3.fromRGB(240, 110, 100)
local GOLD = Color3.fromRGB(230, 190, 100)

local function label(parent: Instance, text: string, size: number, color: Color3?, font: Enum.Font?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Font = font or Enum.Font.Gotham
	l.TextSize = size
	l.TextColor3 = color or INK
	l.Text = text
	l.Parent = parent
	return l
end
local function bar(parent: Instance, frac: number, color: Color3, mark: number?): Frame
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 7)
	track.BackgroundColor3 = Color3.fromRGB(45, 47, 58)
	track.BorderSizePixel = 0
	track.Parent = parent
	Instance.new("UICorner", track).CornerRadius = UDim.new(0, 3)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = track
	Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 3)
	if mark then
		local m = Instance.new("Frame")
		m.Size = UDim2.new(0, 2, 1, 6)
		m.Position = UDim2.new(math.clamp(mark, 0, 1), -1, 0, -3)
		m.BackgroundColor3 = Color3.new(1, 1, 1)
		m.BorderSizePixel = 0
		m.Parent = track
	end
	return track
end

---------------------------------------------------------------------------
-- the board
---------------------------------------------------------------------------
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(1, 0)
panel.Position = UDim2.new(1, -12, 0, 70)
panel.Size = UDim2.new(0.3, 0, 0.62, 0)
panel.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
panel.BackgroundTransparency = 0.12
panel.Parent = gui
Instance.new("UICorner", panel)
do
	local c = Instance.new("UISizeConstraint")
	c.MinSize = Vector2.new(250, 160)
	c.MaxSize = Vector2.new(380, 560)
	c.Parent = panel
end
local head = label(panel, "", 14, INK, Enum.Font.GothamBold)
head.Position = UDim2.fromOffset(10, 6)
head.Size = UDim2.new(1, -50, 0, 0)
local collapse = Instance.new("TextButton")
collapse.Size = UDim2.fromOffset(30, 22)
collapse.Position = UDim2.new(1, -36, 0, 6)
collapse.BackgroundColor3 = Color3.fromRGB(45, 47, 58)
collapse.TextColor3 = INK
collapse.Font = Enum.Font.GothamBold
collapse.TextSize = 14
collapse.Text = "-"
collapse.Parent = panel
Instance.new("UICorner", collapse)

local body = Instance.new("ScrollingFrame")
body.Position = UDim2.fromOffset(10, 40)
body.Size = UDim2.new(1, -20, 1, -48)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 5
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.CanvasSize = UDim2.new()
body.Parent = panel
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 6)
layout.Parent = body

local collapsed = false
collapse.Activated:Connect(function()
	collapsed = not collapsed
	collapse.Text = if collapsed then "+" else "-"
	body.Visible = not collapsed
	panel.Size = if collapsed then UDim2.new(0.3, 0, 0, 36) else UDim2.new(0.3, 0, 0.62, 0)
end)

local log: { string } = {}
local lastBoard: any = nil

local function render()
	for _, c in body:GetChildren() do
		if not c:IsA("UIListLayout") then c:Destroy() end
	end
	local b = lastBoard
	local order = 0
	local function nextOrder(): number order += 1 return order end
	if b then
		head.Text = ("%s  |  %s"):format(tostring(b.case or "Court"), tostring(b.phase or ""))
		if b.score and b.threshold then
			local box = Instance.new("Frame")
			box.BackgroundTransparency = 1
			box.Size = UDim2.new(1, 0, 0, 0)
			box.AutomaticSize = Enum.AutomaticSize.Y
			box.LayoutOrder = nextOrder()
			box.Parent = body
			local l = Instance.new("UIListLayout")
			l.Padding = UDim.new(0, 3)
			l.Parent = box
			local pct = math.floor(b.score / b.threshold * 100)
			label(box, ("The State's case: %d%% of what a conviction needs"):format(pct), 13, if pct >= 100 then BAD else GOOD, Enum.Font.GothamBold)
			bar(box, b.score / (b.threshold * 1.6), if pct >= 100 then BAD else GOOD, 1 / 1.6)
		end
		for _, x in b.exhibits or {} do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
			row.Size = UDim2.new(1, 0, 0, 0)
			row.AutomaticSize = Enum.AutomaticSize.Y
			row.LayoutOrder = nextOrder()
			row.Parent = body
			Instance.new("UICorner", row)
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 4), UDim.new(0, 5)
			pad.Parent = row
			local l = Instance.new("UIListLayout")
			l.SortOrder = Enum.SortOrder.LayoutOrder
			l.Padding = UDim.new(0, 2)
			l.Parent = row
			local excluded = x.status == "excluded"
			local t = label(row, (if excluded then "[EXCLUDED] " elseif x.status == "pending" then "[not yet shown] " else "") .. tostring(x.title), 12,
				if excluded then DIM else INK, Enum.Font.GothamMedium)
			t.LayoutOrder = 1
			if not excluded then
				local cred = tonumber(x.cred) or 1
				local bb = bar(row, cred / 1.35, if cred < 0.6 then GOOD elseif cred > 1.05 then BAD else GOLD, 1 / 1.35)
				bb.LayoutOrder = 2
			end
			if x.notes and #x.notes > 0 then
				local n = label(row, x.notes[#x.notes], 11, DIM)
				n.LayoutOrder = 3
			end
			local k = 4
			for _, w in x.weak or {} do
				if w.known ~= nil or w.used then
					local mark = if w.known == true then "REAL: " elseif w.known == false then "solid: " else "tried: "
					local wl = label(row, mark .. tostring(w.attack), 11, if w.known == true then GOOD elseif w.known == false then BAD else DIM)
					wl.LayoutOrder = k
					k += 1
				end
			end
		end
	end
	if #log > 0 then
		local sep = label(body, "IN THE ROOM", 11, DIM, Enum.Font.GothamBold)
		sep.LayoutOrder = nextOrder()
		for i = math.max(1, #log - 5), #log do
			local l = label(body, log[i], 12, INK)
			l.LayoutOrder = nextOrder()
		end
	end
end

---------------------------------------------------------------------------
-- OBJECTION!
---------------------------------------------------------------------------
local objFrame = Instance.new("Frame")
objFrame.AnchorPoint = Vector2.new(0.5, 1)
objFrame.Position = UDim2.new(0.5, 0, 1, -110)
objFrame.Size = UDim2.new(0.5, 0, 0, 0)
objFrame.AutomaticSize = Enum.AutomaticSize.Y
objFrame.BackgroundColor3 = Color3.fromRGB(22, 18, 20)
objFrame.BackgroundTransparency = 0.05
objFrame.Visible = false
objFrame.Parent = gui
Instance.new("UICorner", objFrame)
do
	local c = Instance.new("UISizeConstraint")
	c.MinSize = Vector2.new(280, 0)
	c.MaxSize = Vector2.new(520, 400)
	c.Parent = objFrame
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10), UDim.new(0, 8), UDim.new(0, 10)
	pad.Parent = objFrame
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, 6)
	l.Parent = objFrame
end
local objToken: string? = nil

local function closeObjection()
	objToken = nil
	objFrame.Visible = false
	for _, c in objFrame:GetChildren() do
		if not (c:IsA("UIListLayout") or c:IsA("UIPadding") or c:IsA("UISizeConstraint") or c:IsA("UICorner")) then c:Destroy() end
	end
end

local function button(text: string, color: Color3, order: number, h: number?): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, h or 36)
	b.BackgroundColor3 = color
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = if (h or 36) > 40 then 24 else 15
	b.Text = text
	b.LayoutOrder = order
	b.Parent = objFrame
	Instance.new("UICorner", b)
	return b
end

local function openObjection(d: any)
	closeObjection()
	local token = tostring(d.token)
	objToken = token
	objFrame.Visible = true
	local who = label(objFrame, tostring(d.speaker), 12, DIM, Enum.Font.GothamBold)
	who.LayoutOrder = 1
	local line = label(objFrame, tostring(d.line), 15, INK, Enum.Font.GothamMedium)
	line.LayoutOrder = 2
	local timer = bar(objFrame, 1, BAD)
	timer.LayoutOrder = 3
	local fill = timer:FindFirstChildOfClass("Frame") :: Frame
	local secs = tonumber(d.secs) or 6
	TweenService:Create(fill, TweenInfo.new(secs, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 1, 0) }):Play()
	local big = button("OBJECTION!", Color3.fromRGB(190, 40, 40), 4, 54)
	big.Activated:Connect(function()
		if objToken ~= token then return end
		big:Destroy()
		local q = label(objFrame, "On what grounds?", 13, GOLD, Enum.Font.GothamBold)
		q.LayoutOrder = 5
		for i, g in d.grounds or {} do
			local gb = button(tostring(g), Color3.fromRGB(70, 60, 80), 5 + i)
			gb.Activated:Connect(function()
				if objToken ~= token then return end
				remote:FireServer("object", token, g)
				closeObjection()
			end)
		end
	end)
	task.delay(secs + 0.5, function()
		if objToken == token then closeObjection() end
	end)
end

---------------------------------------------------------------------------
remote.OnClientEvent:Connect(function(action: string, d: any)
	if action == "board" and type(d) == "table" then
		lastBoard = d
		gui.Enabled = true
		render()
	elseif action == "line" and type(d) == "table" then
		for _, l in d.lines or {} do
			if tostring(l) ~= "" then table.insert(log, ("%s: %s"):format(tostring(d.from), tostring(l))) end
		end
		while #log > 30 do table.remove(log, 1) end
		if gui.Enabled then render() end
	elseif action == "object" and type(d) == "table" then
		gui.Enabled = true
		openObjection(d)
	elseif action == "closeObject" then
		if objToken == d then closeObjection() end
	elseif action == "clear" then
		closeObjection()
		gui.Enabled = false
		lastBoard = nil
		table.clear(log)
	end
end)
