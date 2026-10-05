-- CasinoCards (v209): playing cards drawn in UI like a real deck - corner
-- indices, standard pip layouts, court cards, a patterned back - and the
-- baccarat squeeze: drag any edge of a face-down card to bend it up and see
-- the pips underneath (never the corner index) until it's peeled all the way.

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Cards = {}

local SUIT = { S = "♠", H = "♥", D = "♦", C = "♣" }
local RED = Color3.fromRGB(196, 30, 42)
local BLACK = Color3.fromRGB(22, 24, 30)
local PAPER = Color3.fromRGB(252, 250, 244)
local BACK = Color3.fromRGB(28, 46, 110)

-- pip centres in the pip area (0..1), standard layouts
local L, M, R = 0.18, 0.5, 0.82
local PIPS = {
	["A"] = { { M, 0.5 } },
	["2"] = { { M, 0 }, { M, 1 } },
	["3"] = { { M, 0 }, { M, 0.5 }, { M, 1 } },
	["4"] = { { L, 0 }, { R, 0 }, { L, 1 }, { R, 1 } },
	["5"] = { { L, 0 }, { R, 0 }, { M, 0.5 }, { L, 1 }, { R, 1 } },
	["6"] = { { L, 0 }, { R, 0 }, { L, 0.5 }, { R, 0.5 }, { L, 1 }, { R, 1 } },
	["7"] = { { L, 0 }, { R, 0 }, { M, 0.25 }, { L, 0.5 }, { R, 0.5 }, { L, 1 }, { R, 1 } },
	["8"] = { { L, 0 }, { R, 0 }, { M, 0.25 }, { L, 0.5 }, { R, 0.5 }, { M, 0.75 }, { L, 1 }, { R, 1 } },
	["9"] = { { L, 0 }, { R, 0 }, { L, 1 / 3 }, { R, 1 / 3 }, { M, 0.5 }, { L, 2 / 3 }, { R, 2 / 3 }, { L, 1 }, { R, 1 } },
	["10"] = { { L, 0 }, { R, 0 }, { M, 1 / 6 }, { L, 1 / 3 }, { R, 1 / 3 }, { L, 2 / 3 }, { R, 2 / 3 }, { M, 5 / 6 }, { L, 1 }, { R, 1 } },
}

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local obj = Instance.new(className)
	for k, v in props do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function text(parent: Instance, str: string, color: Color3, props: { [string]: any }): TextLabel
	local l = new("TextLabel", {
		BackgroundTransparency = 1, Text = str, TextColor3 = color, TextScaled = true,
		Font = Enum.Font.GothamBold, BorderSizePixel = 0,
	}, parent)
	for k, v in props do
		l[k] = v
	end
	return l
end

-- Card face. opts.noIndex hides the corner rank/suit (squeeze view).
function Cards.face(parent: Instance, card: string, opts: { [string]: any }?): Frame
	opts = opts or {}
	local rank, suitKey = card:sub(1, -2), card:sub(-1)
	local suit = SUIT[suitKey] or "?"
	local color = if suitKey == "H" or suitKey == "D" then RED else BLACK
	local face = new("Frame", {
		Name = "Face", Size = UDim2.fromScale(1, 1), BackgroundColor3 = PAPER, BorderSizePixel = 0, ClipsDescendants = true,
	}, parent)
	new("UICorner", { CornerRadius = UDim.new(0.08, 0) }, face)
	new("UIStroke", { Color = Color3.fromRGB(190, 190, 190), Thickness = 1 }, face)
	if not opts.noIndex then
		local tl = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromScale(0.04, 0.03), Size = UDim2.fromScale(0.2, 0.24) }, face)
		text(tl, rank, color, { Size = UDim2.fromScale(1, 0.58) })
		text(tl, suit, color, { Position = UDim2.fromScale(0, 0.55), Size = UDim2.fromScale(1, 0.45) })
		local br = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromScale(0.76, 0.73), Size = UDim2.fromScale(0.2, 0.24), Rotation = 180 }, face)
		text(br, rank, color, { Size = UDim2.fromScale(1, 0.58) })
		text(br, suit, color, { Position = UDim2.fromScale(0, 0.55), Size = UDim2.fromScale(1, 0.45) })
	end
	local pips = PIPS[rank]
	if pips then
		local area = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromScale(0.22, 0.12), Size = UDim2.fromScale(0.56, 0.76) }, face)
		local size = if rank == "A" then 0.42 else 0.26
		for _, p in pips do
			local pip = text(area, suit, color, {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(p[1], p[2]),
				Size = UDim2.fromScale(size * 1.3, size), Font = Enum.Font.Arial,
			})
			if p[2] > 0.5 then
				pip.Rotation = 180
			end
		end
	else
		-- court card: framed picture panel
		local panel = new("Frame", {
			Position = UDim2.fromScale(0.2, 0.12), Size = UDim2.fromScale(0.6, 0.76),
			BackgroundColor3 = Color3.fromRGB(246, 232, 190), BorderSizePixel = 0,
		}, face)
		new("UIStroke", { Color = color, Thickness = 2 }, panel)
		new("UIGradient", {
			Color = ColorSequence.new(Color3.fromRGB(255, 244, 210), Color3.fromRGB(226, 196, 130)), Rotation = 90,
		}, panel)
		text(panel, "♛", Color3.fromRGB(200, 150, 40), { Position = UDim2.fromScale(0.1, 0.04), Size = UDim2.fromScale(0.8, 0.3) })
		if not opts.noIndex then
			text(panel, rank, color, { Position = UDim2.fromScale(0.1, 0.32), Size = UDim2.fromScale(0.8, 0.38), Font = Enum.Font.Garamond })
		end
		text(panel, suit, color, { Position = UDim2.fromScale(0.25, 0.68), Size = UDim2.fromScale(0.5, 0.28) })
	end
	return face
end

-- Card back: navy with a lattice and a white border.
function Cards.back(parent: Instance): Frame
	local back = new("Frame", { Name = "Back", Size = UDim2.fromScale(1, 1), BackgroundColor3 = PAPER, BorderSizePixel = 0, ClipsDescendants = true }, parent)
	new("UICorner", { CornerRadius = UDim.new(0.08, 0) }, back)
	new("UIStroke", { Color = Color3.fromRGB(190, 190, 190), Thickness = 1 }, back)
	local inner = new("Frame", { Position = UDim2.fromScale(0.07, 0.05), Size = UDim2.fromScale(0.86, 0.9), BackgroundColor3 = BACK, BorderSizePixel = 0, ClipsDescendants = true }, back)
	new("UICorner", { CornerRadius = UDim.new(0.06, 0) }, inner)
	new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(46, 70, 150), Color3.fromRGB(20, 32, 84)), Rotation = 45 }, inner)
	for i = 0, 5 do
		for j = 0, 7 do
			text(inner, "◆", Color3.fromRGB(90, 120, 200), {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(i / 5, j / 7),
				Size = UDim2.fromScale(0.3, 0.2), TextTransparency = 0.35, Font = Enum.Font.Arial,
			})
		end
	end
	return back
end

-- A card (face up, or "??" face down) in a holder frame.
function Cards.card(parent: Instance, card: string, props: { [string]: any }?): Frame
	local holder = new("Frame", { BackgroundTransparency = 1 }, parent)
	for k, v in props or {} do
		holder[k] = v
	end
	new("UIAspectRatioConstraint", { AspectRatio = 0.7 }, holder)
	if card == "??" then
		Cards.back(holder)
	else
		Cards.face(holder, card)
	end
	return holder
end

-- Squeeze widget: a face-down card you peel by dragging from any edge.
-- The underside shows pips only; past `threshold` it flips face up and
-- onPeeled() fires once.
function Cards.squeeze(parent: Instance, card: string, props: { [string]: any }, onPeeled: () -> ())
	local holder = new("Frame", { BackgroundTransparency = 1, Active = true }, parent)
	for k, v in props do
		holder[k] = v
	end
	new("UIAspectRatioConstraint", { AspectRatio = 0.7 }, holder)
	Cards.face(holder, card, { noIndex = true })
	-- the back is clipped away from the edge being lifted
	local clip = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 2 }, holder)
	local back = Cards.back(clip)
	back.ZIndex = 2
	-- the bent-up flap (underside of the card, seen at the fold)
	local flap = new("Frame", {
		BackgroundColor3 = Color3.fromRGB(236, 234, 226), BorderSizePixel = 0, Visible = false, ZIndex = 4,
	}, holder)
	new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 178, 170)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(250, 248, 240)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 203, 195)),
		}),
	}, flap)
	local shadow = new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.7, BorderSizePixel = 0, Visible = false, ZIndex = 3 }, holder)
	local hint = text(holder, "drag an edge to peel", Color3.new(1, 1, 1), {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 6), Size = UDim2.new(1.4, 0, 0, 18), ZIndex = 5,
		Font = Enum.Font.Gotham,
	})

	local edge: string? = nil
	local amount = 0
	local done = false
	local dragging = false
	local startPos = Vector2.zero

	local function apply()
		local a = math.clamp(amount, 0, 1)
		local f = a * 0.5 -- the curled flap is about half the lifted depth
		flap.Visible = a > 0.01 and not done
		shadow.Visible = flap.Visible
		if edge == "bottom" then
			clip.Position, clip.Size = UDim2.fromScale(0, 0), UDim2.fromScale(1, 1 - a)
			flap.Position, flap.Size = UDim2.fromScale(0, 1 - a - f), UDim2.fromScale(1, f)
			shadow.Position, shadow.Size = UDim2.fromScale(0, 1 - a - f - 0.02), UDim2.fromScale(1, 0.02)
		elseif edge == "top" then
			clip.Position, clip.Size = UDim2.fromScale(0, a), UDim2.fromScale(1, 1 - a)
			flap.Position, flap.Size = UDim2.fromScale(0, a), UDim2.fromScale(1, f)
			shadow.Position, shadow.Size = UDim2.fromScale(0, a + f), UDim2.fromScale(1, 0.02)
		elseif edge == "right" then
			clip.Position, clip.Size = UDim2.fromScale(0, 0), UDim2.fromScale(1 - a, 1)
			flap.Position, flap.Size = UDim2.fromScale(1 - a - f, 0), UDim2.fromScale(f, 1)
			shadow.Position, shadow.Size = UDim2.fromScale(1 - a - f - 0.03, 0), UDim2.fromScale(0.03, 1)
		elseif edge == "left" then
			clip.Position, clip.Size = UDim2.fromScale(a, 0), UDim2.fromScale(1 - a, 1)
			flap.Position, flap.Size = UDim2.fromScale(a, 0), UDim2.fromScale(f, 1)
			shadow.Position, shadow.Size = UDim2.fromScale(a + f, 0), UDim2.fromScale(0.03, 1)
		end
		-- the back image inside the clip must stay put while the clip shrinks
		local w, h = holder.AbsoluteSize.X, holder.AbsoluteSize.Y
		back.Size = UDim2.fromOffset(w, h)
		back.Position = UDim2.fromOffset(if edge == "left" then -a * w else 0, if edge == "top" then -a * h else 0)
	end

	local grab: TextButton -- (set below; finish() destroys it - it was a nil global here)
	local function finish()
		if done then
			return
		end
		done = true
		flap.Visible, shadow.Visible, hint.Visible = false, false, false
		clip.Visible = false
		-- the fully turned card shows its index
		holder:FindFirstChild("Face"):Destroy()
		local face = Cards.face(holder, card)
		face.ZIndex = 1
		grab:Destroy()
		onPeeled()
	end

	-- an invisible button over the card takes the press (frames alone don't
	-- reliably receive touch input)
	grab = new("TextButton", { Name = "Grab", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 10 }, holder)
	grab.InputBegan:Connect(function(input)
		if done then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local rel = Vector2.new(input.Position.X, input.Position.Y) - holder.AbsolutePosition
		local size = holder.AbsoluteSize
		local u, v = rel.X / size.X, rel.Y / size.Y
		-- lift from the closest edge (players usually squeeze the long side)
		local d = { bottom = 1 - v, top = v, right = 1 - u, left = u }
		if not edge or amount < 0.02 then
			edge = "bottom"
			for k, dist in d do
				if dist < d[edge] then
					edge = k
				end
			end
		end
		dragging = true
		startPos = Vector2.new(input.Position.X, input.Position.Y)
		hint.Visible = false
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging or done or not holder.Parent then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local delta = Vector2.new(input.Position.X, input.Position.Y) - startPos
		local size = holder.AbsoluteSize
		local pull = if edge == "bottom" then -delta.Y / size.Y
			elseif edge == "top" then delta.Y / size.Y
			elseif edge == "right" then -delta.X / size.X
			else delta.X / size.X
		amount = math.clamp(math.max(amount, pull), 0, 1)
		apply()
		if amount >= 0.92 then
			finish()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			if not done and amount < 0.92 then
				-- let go: the card settles back down a little, like real card stock
				local target = math.max(0, amount - 0.15)
				local start = amount
				local t0 = os.clock()
				task.spawn(function()
					while os.clock() - t0 < 0.2 and not dragging and not done and holder.Parent do
						amount = start + (target - start) * ((os.clock() - t0) / 0.2)
						apply()
						task.wait()
					end
					if not dragging and not done then
						amount = target
						apply()
					end
				end)
			end
		end
	end)
	return {
		holder = holder,
		finish = finish,
		isDone = function()
			return done
		end,
	}
end

return Cards
