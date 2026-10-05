-- CasinoTables (v208): Baccarat, Roulette, No-Limit Texas Hold'em and the
-- Dragon Fortune slot for CasinoServer. CasinoServer owns the machines, the
-- remote, bets and payouts (ctx); this module owns the game rules and state.
--   * Baccarat: shared round (Player / Banker / Tie), standard third-card rules,
--     Banker pays 0.95:1, Tie pays 8:1 (Player/Banker bets push on a tie).
--   * Roulette: single-zero wheel on a table built on the casino floor. Straight
--     numbers 35:1, dozens/columns 2:1, red/black/odd/even/low/high 1:1.
--   * Hold'em: no-limit, 2-6 seats. The first player to sit sets the blinds
--     (anything from 5/10 to 50,000/100,000 and beyond) and buys in; the stack
--     goes back to the bank on standing up. Bots can fill empty seats.
--   * Craps (v295): Pass / Don't Pass, Field, Place, Hardways, Any Seven, Any Craps, Yo - see CRAPS.
--   * Dragon Fortune: 5x3, 243 ways, wilds on reels 2-4, Pearl scatter free spins
--     (x2), about 95% return (simulated).

local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local M = {}
local ctx: any = nil

local SUITS = { "S", "H", "D", "C" }
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

local function newDeck(decks: number): { string }
	local deck = {}
	for _ = 1, decks do
		for _, s in SUITS do
			for _, r in RANKS do
				table.insert(deck, r .. s)
			end
		end
	end
	for i = #deck, 2, -1 do
		local j = math.random(1, i)
		deck[i], deck[j] = deck[j], deck[i]
	end
	return deck
end

local function rankOf(card: string): string
	return card:sub(1, -2)
end

local function money(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return "$" .. out:gsub("^,", "")
end

local function now(): number
	return os.clock()
end

---------------------------------------------------------------------------
-- physical cards shared by baccarat / hold'em tables
---------------------------------------------------------------------------
local function tableLabel(machine: any, key: string, anchor: CFrame, text: string)
	ctx.physicalCard(machine, key, "??", anchor, 1, 1)
	local tag = machine.visibleCards[key]
	tag.part.Size = Vector3.new(1.9, 0.34, 0.025)
	tag.gui.CanvasSize = Vector2.new(640, 120)
	tag.face.BackgroundColor3 = Color3.fromRGB(15, 65, 43)
	tag.face.TextColor3 = Color3.fromRGB(240, 204, 100)
	tag.corner.Text = ""
	tag.face.Text = text
end

local function syncCards(machine: any, groups: { any })
	if not machine.cardFolder then
		return
	end
	local keep = {}
	for _, group in groups do
		for i, value in group.cards do
			local key = group.key .. "Card" .. i
			keep[key] = true
			ctx.physicalCard(machine, key, value, group.anchor, i, #group.cards)
		end
		if group.label then
			local key = group.key .. "Label"
			keep[key] = true
			tableLabel(machine, key, group.anchor * CFrame.new(0, 0, 0.7), group.label)
		end
	end
	for key, record in machine.visibleCards do
		if not keep[key] then
			record.part:Destroy()
			machine.visibleCards[key] = nil
		end
	end
end

---------------------------------------------------------------------------
-- BACCARAT
---------------------------------------------------------------------------
local BAC_BETTING = 12
local BAC_FINISHED = 7
local BAC_PAYS = { Player = 2, Banker = 1.95, Tie = 9 }
local baccarat: { [string]: any } = {}

local function bacValue(card: string): number
	local r = rankOf(card)
	if r == "A" then
		return 1
	elseif r == "10" or r == "J" or r == "Q" or r == "K" then
		return 0
	end
	return tonumber(r) or 0
end

local function bacTotal(cards: { string }): number
	local sum = 0
	for _, c in cards do
		sum += bacValue(c)
	end
	return sum % 10
end

local function bacState(id: string): any
	local s = baccarat[id]
	if not s then
		s = { id = id, phase = "Idle", deck = newDeck(8), player = {}, banker = {}, hiddenP = {}, hiddenB = {}, peeler = {}, bets = {}, order = {}, round = 0, ends = 0, result = "", history = {} }
		baccarat[id] = s
	end
	return s
end

local function bacDraw(s: any): string
	if #s.deck < 20 then
		s.deck = newDeck(8)
	end
	return table.remove(s.deck)
end

local bacPeelCards: (any) -> { any }

-- cards still face down show as "??" until peeled
local function masked(cards: { string }, hidden: { boolean }?): { string }
	local out = {}
	for i, c in cards do
		out[i] = if hidden and hidden[i] then "??" else c
	end
	return out
end

local function allShown(hidden: { boolean }?): boolean
	for _, h in hidden or {} do
		if h then
			return false
		end
	end
	return true
end

bacPeelCards = function(s: any): { any }
	local sq = s.squeeze
	local cards = if sq.side == "Player" then s.player else s.banker
	local hidden = if sq.side == "Player" then s.hiddenP else s.hiddenB
	local out = {}
	for _, i in sq.indices do
		table.insert(out, { index = i, card = cards[i], hidden = hidden[i] == true })
	end
	return out
end

local function bacSnapshot(s: any, player: Player?): any
	local mine = player and s.bets[player]
	local list = {}
	for _, p in s.order do
		local b = s.bets[p]
		if b then
			table.insert(list, { name = (p:GetAttribute("CharacterName") or p.DisplayName), side = b.side, bet = b.bet, win = b.win, isYou = p == player })
		end
	end
	local sq = s.squeeze
	return {
		ok = true,
		phase = s.phase,
		playerCards = masked(s.player, s.hiddenP),
		bankerCards = masked(s.banker, s.hiddenB),
		playerTotal = #s.player > 0 and allShown(s.hiddenP) and bacTotal(s.player) or nil,
		bankerTotal = #s.banker > 0 and allShown(s.hiddenB) and bacTotal(s.banker) or nil,
		bets = list,
		mySide = mine and mine.side or nil,
		myBet = mine and mine.bet or 0,
		myWin = mine and mine.win or 0,
		result = s.result,
		history = table.clone(s.history),
		seconds = if sq then math.max(0, math.ceil(sq.ends - now())) else math.max(0, math.ceil(s.ends - now())),
		squeezeSide = sq and sq.side or nil,
		canPeel = sq ~= nil and player ~= nil and s.peeler[sq.side] == player,
		peelerName = sq and s.peeler[sq.side] and s.peeler[sq.side].DisplayName or nil,
		-- only the peeler receives the face-down card values (for the squeeze view)
		peelCards = if sq and player and s.peeler[sq.side] == player then bacPeelCards(s) else nil,
	}
end

-- The biggest bettor on each side peels that side's cards (the squeeze). The
-- coup waits for the peel; after BAC_SQUEEZE seconds the dealer turns them.
-- With nobody on a side the dealer turns them over straight away.
local BAC_SQUEEZE = 35
local function bacSqueeze(s: any, side: string, indices: { number })
	local hidden = if side == "Player" then s.hiddenP else s.hiddenB
	local peeler = s.peeler[side]
	if peeler and peeler.Parent then
		s.squeeze = { side = side, indices = indices, ends = now() + BAC_SQUEEZE }
		while now() < s.squeeze.ends and peeler.Parent do
			local open = false
			for _, i in indices do
				if hidden[i] then
					open = true
				end
			end
			if not open then
				break
			end
			task.wait(0.1)
		end
	else
		task.wait(0.8)
	end
	s.squeeze = nil
	for _, i in indices do
		hidden[i] = false
	end
	task.wait(1.1)
end

local function bacPlay(s: any, machine: any)
	s.phase = "Dealing"
	s.player, s.banker = {}, {}
	s.hiddenP, s.hiddenB = {}, {}
	s.squeeze = nil
	-- biggest bettor on each side peels
	s.peeler = {}
	local biggest = { Player = 0, Banker = 0 }
	for plr, bet in s.bets do
		if (bet.side == "Player" or bet.side == "Banker") and bet.bet > biggest[bet.side] then
			biggest[bet.side] = bet.bet
			s.peeler[bet.side] = plr
		end
	end
	local function give(hand: { string }, hidden: { boolean })
		table.insert(hand, bacDraw(s))
		table.insert(hidden, true)
		task.wait(0.6)
	end
	give(s.player, s.hiddenP)
	give(s.banker, s.hiddenB)
	give(s.player, s.hiddenP)
	give(s.banker, s.hiddenB)
	bacSqueeze(s, "Player", { 1, 2 })
	bacSqueeze(s, "Banker", { 1, 2 })
	local p, b = bacTotal(s.player), bacTotal(s.banker)
	if p < 8 and b < 8 then
		local third: number? = nil
		if p <= 5 then
			give(s.player, s.hiddenP)
			bacSqueeze(s, "Player", { 3 })
			third = bacValue(s.player[3])
		end
		b = bacTotal(s.banker)
		local bankerDraws
		if third == nil then
			bankerDraws = b <= 5
		elseif b <= 2 then
			bankerDraws = true
		elseif b == 3 then
			bankerDraws = third ~= 8
		elseif b == 4 then
			bankerDraws = third >= 2 and third <= 7
		elseif b == 5 then
			bankerDraws = third >= 4 and third <= 7
		elseif b == 6 then
			bankerDraws = third == 6 or third == 7
		else
			bankerDraws = false
		end
		if bankerDraws then
			give(s.banker, s.hiddenB)
			bacSqueeze(s, "Banker", { 3 })
		end
	end
	p, b = bacTotal(s.player), bacTotal(s.banker)
	local winner = if p > b then "Player" elseif b > p then "Banker" else "Tie"
	s.result = if winner == "Tie" then ("TIE %d - %d"):format(p, b) else ("%s WINS %d - %d"):format(winner:upper(), math.max(p, b), math.min(p, b))
	table.insert(s.history, 1, winner:sub(1, 1))
	while #s.history > 14 do
		table.remove(s.history)
	end
	for plr, bet in s.bets do
		local mult = 0
		if bet.side == winner then
			mult = BAC_PAYS[winner]
		elseif winner == "Tie" then
			mult = 1 -- Player / Banker bets push on a tie
		end
		bet.win = math.floor(bet.bet * mult)
		if bet.win > 0 and plr.Parent then
			ctx.pay(plr, bet.win)
		end
	end
	s.phase = "Finished"
	s.ends = now() + BAC_FINISHED
	local token = s.round
	task.delay(BAC_FINISHED, function()
		if s.round == token and s.phase == "Finished" then
			s.phase = "Idle"
			s.player, s.banker, s.bets, s.order = {}, {}, {}, {}
			s.hiddenP, s.hiddenB = {}, {}
		end
	end)
end

local function baccaratAction(player: Player, machine: any, id: string, action: string, a: any, b: any): any
	local s = bacState(id)
	if action == "View" then
		return bacSnapshot(s, player)
	elseif action == "Peel" then
		-- a = card index the peeler has fully peeled (nil = turn them all)
		local sq = s.squeeze
		if sq and s.peeler and s.peeler[sq.side] == player then
			local hidden = if sq.side == "Player" then s.hiddenP else s.hiddenB
			local index = tonumber(a)
			for _, i in sq.indices do
				if index == nil or index == i then
					hidden[i] = false
				end
			end
		end
		return bacSnapshot(s, player)
	elseif action == "Bet" then
		local side = tostring(b)
		if not BAC_PAYS[side] then
			return { ok = false, message = "Bet on Player, Banker or Tie" }
		end
		if s.phase == "Dealing" then
			return { ok = false, message = "Cards are out - bet on the next coup" }
		end
		if s.phase == "Idle" or s.phase == "Finished" then
			s.round += 1
			s.phase = "Betting"
			s.player, s.banker, s.bets, s.order, s.result = {}, {}, {}, {}, ""
			s.ends = now() + BAC_BETTING
			local token = s.round
			task.delay(BAC_BETTING, function()
				if s.round == token and s.phase == "Betting" then
					if next(s.bets) then
						bacPlay(s, machine)
					else
						s.phase = "Idle"
					end
				end
			end)
		end
		if s.bets[player] then
			return { ok = false, message = "You already have a bet on this coup" }
		end
		local stake, err = ctx.validBet(player, machine, a)
		if not stake then
			return { ok = false, message = err }
		end
		s.bets[player] = { bet = stake, side = side, win = 0 }
		table.insert(s.order, player)
		return bacSnapshot(s, player)
	end
	return { ok = false, message = "?" }
end

---------------------------------------------------------------------------
-- ROULETTE
---------------------------------------------------------------------------
local WHEEL = { 0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26 }
local REDS = {}
for _, n in { 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36 } do
	REDS[n] = true
end
local RL_BETTING = 18
local RL_FINISHED = 7
local RL_MAX_BETS = 40
local roulette: { [string]: any } = {}

local function colorOf(n: number): string
	return if n == 0 then "Green" elseif REDS[n] then "Red" else "Black"
end

-- returns the payout (stake included) for one bet on `n`
local function rouletteReturn(bet: any, n: number): number
	local k, v = bet.kind, bet.value
	local hit = false
	local mult = 2
	if k == "Straight" then
		hit, mult = n == v, 36
	elseif n == 0 then
		hit = false
	elseif k == "Red" then
		hit = REDS[n] == true
	elseif k == "Black" then
		hit = not REDS[n]
	elseif k == "Odd" then
		hit = n % 2 == 1
	elseif k == "Even" then
		hit = n % 2 == 0
	elseif k == "Low" then
		hit = n <= 18
	elseif k == "High" then
		hit = n >= 19
	elseif k == "Dozen" then
		hit, mult = math.ceil(n / 12) == v, 3
	elseif k == "Column" then
		hit, mult = ((n - 1) % 3) + 1 == v, 3
	end
	return if hit then math.floor(bet.amount * mult) else 0
end

local function validRouletteBet(kind: any, value: any): (boolean, number?)
	local k = tostring(kind)
	local v = tonumber(value)
	if k == "Straight" then
		return v ~= nil and v % 1 == 0 and v >= 0 and v <= 36, v
	elseif k == "Dozen" or k == "Column" then
		return v ~= nil and v % 1 == 0 and v >= 1 and v <= 3, v
	elseif k == "Red" or k == "Black" or k == "Odd" or k == "Even" or k == "Low" or k == "High" then
		return true, 0
	end
	return false, nil
end

local function rlState(id: string): any
	local s = roulette[id]
	if not s then
		s = { id = id, phase = "Idle", bets = {}, round = 0, ends = 0, result = nil, history = {}, wins = {} }
		roulette[id] = s
	end
	return s
end

local function rlSnapshot(s: any, player: Player?): any
	local mine = player and s.bets[player] or {}
	local total = 0
	for _, bet in mine do
		total += bet.amount
	end
	local players = 0
	for _ in s.bets do
		players += 1
	end
	return {
		ok = true,
		phase = s.phase,
		seconds = math.max(0, math.ceil(s.ends - now())),
		myBets = mine,
		myTotal = total,
		myWin = player and s.wins[player] or 0,
		result = s.result,
		resultColor = s.result and colorOf(s.result) or nil,
		history = table.clone(s.history),
		players = players,
	}
end

local function rlSpin(s: any, machine: any)
	s.phase = "Spinning"
	local n = WHEEL[math.random(1, #WHEEL)]
	s.ends = now() + 5
	-- turn the physical wheel; land with the winning pocket at the pointer
	local wheel = machine.rouletteWheel
	if wheel then
		local index = table.find(WHEEL, n) or 1
		local step = 360 / #WHEEL
		local base = machine.rouletteBase
		local spins = 5
		local startAngle = machine.rouletteAngle or 0
		local finalAngle = -((index - 1) * step) + 360 * spins
		local t0 = now()
		while now() - t0 < 4.6 do
			local t = math.clamp((now() - t0) / 4.6, 0, 1)
			local eased = 1 - (1 - t) ^ 3
			local angle = startAngle + (finalAngle - startAngle) * eased
			wheel:PivotTo(base * CFrame.Angles(0, math.rad(angle), 0))
			task.wait(0.05)
		end
		machine.rouletteAngle = finalAngle % 360
		wheel:PivotTo(base * CFrame.Angles(0, math.rad(machine.rouletteAngle), 0))
	else
		task.wait(4.6)
	end
	s.result = n
	table.insert(s.history, 1, n)
	while #s.history > 12 do
		table.remove(s.history)
	end
	for plr, list in s.bets do
		local win = 0
		for _, bet in list do
			win += rouletteReturn(bet, n)
		end
		s.wins[plr] = win
		if win > 0 and plr.Parent then
			ctx.pay(plr, win)
		end
	end
	if machine.rouletteBoard then
		machine.rouletteBoard.Text = ("%d %s"):format(n, colorOf(n):upper())
		machine.rouletteBoard.TextColor3 = if n == 0 then Color3.fromRGB(60, 200, 90) elseif REDS[n] then Color3.fromRGB(230, 60, 60) else Color3.new(1, 1, 1)
	end
	s.phase = "Finished"
	s.ends = now() + RL_FINISHED
	local token = s.round
	task.delay(RL_FINISHED, function()
		if s.round == token and s.phase == "Finished" then
			s.phase = "Idle"
			s.bets, s.wins = {}, {}
		end
	end)
end

local function rouletteAction(player: Player, machine: any, id: string, action: string, a: any, b: any): any
	local s = rlState(id)
	if action == "View" then
		return rlSnapshot(s, player)
	elseif action == "Bet" then
		if s.phase == "Spinning" then
			return { ok = false, message = "No more bets - the ball is rolling" }
		end
		local spec = type(b) == "table" and b or {}
		local valid, value = validRouletteBet(spec.kind, spec.value)
		if not valid then
			return { ok = false, message = "Unknown bet" }
		end
		if s.phase == "Idle" or s.phase == "Finished" then
			s.round += 1
			s.phase = "Betting"
			s.bets, s.wins, s.result = {}, {}, nil
			s.ends = now() + RL_BETTING
			local token = s.round
			task.delay(RL_BETTING, function()
				if s.round == token and s.phase == "Betting" then
					if next(s.bets) then
						rlSpin(s, machine)
					else
						s.phase = "Idle"
					end
				end
			end)
		end
		local list = s.bets[player] or {}
		if #list >= RL_MAX_BETS then
			return { ok = false, message = "That's the most bets you can place on one spin" }
		end
		local stake, err = ctx.validBet(player, machine, a)
		if not stake then
			return { ok = false, message = err }
		end
		table.insert(list, { kind = tostring(spec.kind), value = value, amount = stake })
		s.bets[player] = list
		return rlSnapshot(s, player)
	elseif action == "Clear" then
		if s.phase ~= "Betting" then
			return { ok = false, message = "Bets can only be taken back before the spin" }
		end
		local list = s.bets[player]
		if list then
			local refund = 0
			for _, bet in list do
				refund += bet.amount
			end
			s.bets[player] = nil
			ctx.pay(player, refund)
		end
		return rlSnapshot(s, player)
	end
	return { ok = false, message = "?" }
end

-- Builds the roulette table on the casino floor at `cf` (floor level, facing
-- the players' side along -LookVector). Returns the focus part for the prompt.
local function buildRoulette(machine: any, cf: CFrame, parent: Instance): BasePart
	local model = Instance.new("Model")
	model.Name = "RouletteTable"
	local function part(name: string, size: Vector3, at: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = at
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.Anchored = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if shape then
			p.Shape = shape
		end
		p.Parent = model
		return p
	end
	local wood = Color3.fromRGB(92, 52, 28)
	local felt = Color3.fromRGB(18, 96, 50)
	-- base and top
	part("Base", Vector3.new(13, 3, 6), cf * CFrame.new(0, 1.5, 0), wood, Enum.Material.Wood)
	local top = part("Felt", Vector3.new(12.4, 0.2, 5.4), cf * CFrame.new(0, 3.1, 0), felt, Enum.Material.Fabric)
	part("Rail", Vector3.new(13.2, 0.35, 0.4), cf * CFrame.new(0, 3.2, 2.9), wood, Enum.Material.Wood)
	part("Rail", Vector3.new(13.2, 0.35, 0.4), cf * CFrame.new(0, 3.2, -2.9), wood, Enum.Material.Wood)
	-- betting layout printed on the felt
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(1240, 540)
	gui.LightInfluence = 0.3
	gui.Parent = top
	local grid = Instance.new("Frame")
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromScale(0.36, 0.08)
	grid.Size = UDim2.fromScale(0.62, 0.84)
	grid.Parent = gui
	for n = 0, 36 do
		local cell = Instance.new("TextLabel")
		cell.BorderSizePixel = 2
		cell.BorderColor3 = Color3.new(1, 1, 1)
		cell.TextColor3 = Color3.new(1, 1, 1)
		cell.Font = Enum.Font.GothamBold
		cell.TextScaled = true
		cell.Text = tostring(n)
		cell.BackgroundColor3 = if n == 0 then Color3.fromRGB(30, 140, 60) elseif REDS[n] then Color3.fromRGB(180, 30, 35) else Color3.fromRGB(20, 20, 22)
		if n == 0 then
			cell.Position = UDim2.fromScale(0, 0)
			cell.Size = UDim2.fromScale(1 / 13, 1)
		else
			local col = math.ceil(n / 3)
			local row = 3 - ((n - 1) % 3)
			cell.Position = UDim2.fromScale(col / 13, (row - 1) / 3)
			cell.Size = UDim2.fromScale(1 / 13, 1 / 3)
		end
		cell.Parent = grid
	end
	-- the wheel (spins as one model around its centre)
	local wheelCenter = cf * CFrame.new(-4.1, 3.35, 0)
	local wheel = Instance.new("Model")
	wheel.Name = "Wheel"
	part("Bowl", Vector3.new(0.5, 4.4, 4.4), wheelCenter * CFrame.Angles(0, 0, math.rad(90)), wood, Enum.Material.Wood, Enum.PartType.Cylinder).Parent = model
	local step = 360 / #WHEEL
	for i, n in WHEEL do
		local a = math.rad((i - 1) * step)
		local pocket = part("Pocket", Vector3.new(0.34, 0.12, 0.7), wheelCenter * CFrame.Angles(0, a, 0) * CFrame.new(0, 0.3, -1.6),
			if n == 0 then Color3.fromRGB(30, 150, 60) elseif REDS[n] then Color3.fromRGB(190, 30, 35) else Color3.fromRGB(20, 20, 22))
		pocket.Parent = wheel
	end
	local hub = part("Hub", Vector3.new(0.4, 1.8, 1.8), wheelCenter * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(200, 170, 80), Enum.Material.Metal, Enum.PartType.Cylinder)
	hub.Parent = wheel
	local spoke = part("Spoke", Vector3.new(0.18, 0.25, 1.6), wheelCenter * CFrame.new(0, 0.55, 0), Color3.fromRGB(220, 190, 90), Enum.Material.Metal)
	spoke.Parent = wheel
	wheel.WorldPivot = wheelCenter -- spin about the vertical axis through the wheel centre
	wheel.Parent = model
	-- fixed pointer at the pocket position of angle 0
	part("Pointer", Vector3.new(0.2, 0.2, 0.6), wheelCenter * CFrame.new(0, 0.55, -2.25), Color3.fromRGB(240, 240, 240), Enum.Material.Metal)
	-- result board
	local focus = part("Focus", Vector3.new(1, 1, 1), cf * CFrame.new(0, 4.5, 0), felt)
	focus.Transparency = 1
	focus.CanCollide = false
	local board = Instance.new("BillboardGui")
	board.Name = "RouletteResult"
	board.Size = UDim2.fromOffset(170, 40)
	board.StudsOffset = Vector3.new(0, 2.2, 0)
	board.MaxDistance = 70
	board.Parent = focus
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	text.BackgroundTransparency = 0.2
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Font = Enum.Font.GothamBlack
	text.TextScaled = true
	text.Text = "PLACE YOUR BETS"
	text.Parent = board
	model.Parent = parent
	machine.model = model
	machine.rouletteWheel = wheel
	machine.rouletteBase = wheel:GetPivot()
	machine.rouletteBoard = text
	machine.tableCamera = CFrame.lookAt((cf * CFrame.new(0, 12, 8)).Position, (cf * CFrame.new(0, 3, 0)).Position)
	return focus
end

-- Look for a clear floor spot for the roulette table near `around`.
local function findClearSpot(around: CFrame, size: Vector3, ignore: { Instance }): CFrame?
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local rays = RaycastParams.new()
	rays.FilterType = Enum.RaycastFilterType.Exclude
	rays.FilterDescendantsInstances = ignore
	for radius = 0, 60, 4 do
		for k = 0, math.max(0, radius // 2) do
			local angle = if radius == 0 then 0 else (k / math.max(1, radius // 2 + 1)) * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			local probe = around.Position + offset + Vector3.new(0, 6, 0)
			local hit = workspace:Raycast(probe, Vector3.new(0, -12, 0), rays)
			if hit then
				local floor = hit.Position
				local boxCf = CFrame.new(floor + Vector3.new(0, size.Y / 2 + 0.3, 0)) * around.Rotation
				local blockers = workspace:GetPartBoundsInBox(boxCf, size, params)
				local solid = false
				for _, p in blockers do
					if p.CanCollide and p.Transparency < 1 then
						solid = true
						break
					end
				end
				if not solid then
					return CFrame.new(floor) * around.Rotation
				end
			end
		end
	end
	return nil
end
M.findClearSpot = findClearSpot
M.buildRoulette = buildRoulette

---------------------------------------------------------------------------
-- TEXAS HOLD'EM (no limit)
---------------------------------------------------------------------------
local HE_SEATS = 6
local HE_ACTION_SECONDS = 25
local HE_BOT_NAMES = { "Vegas Vinnie", "Lucky Lou", "Big Stack Sam", "Card Shark Kim", "Dealer's Dan" }
local holdem: { [string]: any } = {}

local RANK_VALUE = { ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9, ["10"] = 10, J = 11, Q = 12, K = 13, A = 14 }
local HAND_NAMES = { [0] = "High card", "Pair", "Two pair", "Three of a kind", "Straight", "Flush", "Full house", "Four of a kind", "Straight flush" }

local function score5(cards: { string }): number
	local values, suits, counts = {}, {}, {}
	for _, c in cards do
		local v = RANK_VALUE[rankOf(c)]
		table.insert(values, v)
		suits[c:sub(-1)] = (suits[c:sub(-1)] or 0) + 1
		counts[v] = (counts[v] or 0) + 1
	end
	table.sort(values, function(a, b)
		return a > b
	end)
	local flush = false
	for _, n in suits do
		if n == 5 then
			flush = true
		end
	end
	local distinct = {}
	for v in counts do
		table.insert(distinct, v)
	end
	table.sort(distinct, function(a, b)
		return a > b
	end)
	local straightHigh = 0
	if #distinct == 5 then
		if distinct[1] - distinct[5] == 4 then
			straightHigh = distinct[1]
		elseif distinct[1] == 14 and distinct[2] == 5 then
			straightHigh = 5 -- wheel A-2-3-4-5
		end
	end
	-- group by (count desc, value desc)
	local groups = {}
	for v, n in counts do
		table.insert(groups, { v = v, n = n })
	end
	table.sort(groups, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.v > b.v
	end)
	local category
	local kick = {}
	if straightHigh > 0 and flush then
		category, kick = 8, { straightHigh }
	elseif groups[1].n == 4 then
		category, kick = 7, { groups[1].v, groups[2].v }
	elseif groups[1].n == 3 and groups[2] and groups[2].n == 2 then
		category, kick = 6, { groups[1].v, groups[2].v }
	elseif flush then
		category, kick = 5, values
	elseif straightHigh > 0 then
		category, kick = 4, { straightHigh }
	elseif groups[1].n == 3 then
		category, kick = 3, { groups[1].v, groups[2].v, groups[3].v }
	elseif groups[1].n == 2 and groups[2].n == 2 then
		category, kick = 2, { groups[1].v, groups[2].v, groups[3].v }
	elseif groups[1].n == 2 then
		category, kick = 1, { groups[1].v, groups[2].v, groups[3].v, groups[4].v }
	else
		category, kick = 0, values
	end
	local score = category
	for i = 1, 5 do
		score = score * 15 + (kick[i] or 0)
	end
	return score
end

local function bestHand(cards: { string }): (number, string)
	local best = -1
	local n = #cards
	for a = 1, n - 4 do
		for b = a + 1, n - 3 do
			for c = b + 1, n - 2 do
				for d = c + 1, n - 1 do
					for e = d + 1, n do
						local s = score5({ cards[a], cards[b], cards[c], cards[d], cards[e] })
						if s > best then
							best = s
						end
					end
				end
			end
		end
	end
	local category = math.floor(best / 15 ^ 5)
	return best, HAND_NAMES[category] or "?"
end
M.bestHand = bestHand

local function heState(id: string): any
	local s = holdem[id]
	if not s then
		s = { id = id, seats = {}, sb = 0, bb = 0, phase = "Waiting", button = 0, hand = nil, log = {}, handNo = 0, nextStart = 0 }
		holdem[id] = s
	end
	return s
end

local function heLog(s: any, text: string)
	table.insert(s.log, 1, text)
	while #s.log > 8 do
		table.remove(s.log)
	end
end

local function seatOf(s: any, player: Player): number?
	for i = 1, HE_SEATS do
		local seat = s.seats[i]
		if seat and seat.player == player then
			return i
		end
	end
	return nil
end

local function humans(s: any): number
	local n = 0
	for i = 1, HE_SEATS do
		if s.seats[i] and not s.seats[i].bot then
			n += 1
		end
	end
	return n
end

local function cashOut(s: any, i: number)
	local seat = s.seats[i]
	if not seat then
		return
	end
	if not seat.bot and seat.stack > 0 and seat.player.Parent then
		ctx.pay(seat.player, seat.stack)
		heLog(s, ("%s cashed out %s"):format(seat.name, money(seat.stack)))
	end
	s.seats[i] = nil
	if humans(s) == 0 then
		-- the table closes: bots go home, blinds reset for the next group
		for j = 1, HE_SEATS do
			s.seats[j] = nil
		end
		s.sb, s.bb = 0, 0
		s.phase = "Waiting"
		s.hand = nil
	end
end

local function inHand(s: any, i: number): boolean
	local h = s.hand
	return h ~= nil and h.players[i] ~= nil and not h.players[i].folded
end

local function canAct(s: any, i: number): boolean
	local h = s.hand
	local hp = h and h.players[i]
	return hp ~= nil and not hp.folded and not hp.allin
end

local function nextSeat(s: any, from: number, pred: (number) -> boolean): number?
	for k = 1, HE_SEATS do
		local i = ((from - 1 + k) % HE_SEATS) + 1
		if pred(i) then
			return i
		end
	end
	return nil
end

local function potTotal(h: any): number
	local t = 0
	for _, hp in h.players do
		t += hp.total
	end
	return t
end

local function putIn(s: any, i: number, amount: number)
	local seat, hp = s.seats[i], s.hand.players[i]
	amount = math.min(amount, seat.stack)
	seat.stack -= amount
	hp.bet += amount
	hp.total += amount
	if seat.stack <= 0 then
		hp.allin = true
	end
end

local heAdvance: (any) -> ()

local function heShowdown(s: any)
	local h = s.hand
	h.showdown = true
	-- side pots by contribution layers
	local contrib = {}
	for i, hp in h.players do
		contrib[i] = hp.total
	end
	local scores, names = {}, {}
	for i, hp in h.players do
		if not hp.folded then
			local cards = table.clone(hp.cards)
			for _, c in h.board do
				table.insert(cards, c)
			end
			scores[i], names[i] = bestHand(cards)
		end
	end
	local winnings = {}
	while true do
		local layer = math.huge
		for _, c in contrib do
			if c > 0 and c < layer then
				layer = c
			end
		end
		if layer == math.huge then
			break
		end
		local pot = 0
		local eligible = {}
		for i, c in contrib do
			if c > 0 then
				pot += math.min(c, layer)
				contrib[i] = c - math.min(c, layer)
				if scores[i] then
					table.insert(eligible, i)
				end
			end
		end
		if #eligible == 0 then
			for i in scores do
				table.insert(eligible, i)
			end
		end
		local best = -1
		for _, i in eligible do
			best = math.max(best, scores[i])
		end
		local winners = {}
		for _, i in eligible do
			if scores[i] == best then
				table.insert(winners, i)
			end
		end
		table.sort(winners, function(a, b)
			return ((a - s.button - 1) % HE_SEATS) < ((b - s.button - 1) % HE_SEATS)
		end)
		local share = math.floor(pot / #winners)
		local remainder = pot - share * #winners
		for k, i in winners do
			winnings[i] = (winnings[i] or 0) + share + (if k == 1 then remainder else 0)
		end
	end
	for i, amount in winnings do
		local seat = s.seats[i]
		if seat then
			seat.stack += amount
			heLog(s, ("%s wins %s with %s"):format(seat.name, money(amount), names[i] or "the pot"))
		end
		h.players[i].won = amount
		h.players[i].handName = names[i]
	end
end

local function heEndHand(s: any)
	s.phase = "Finished"
	s.nextStart = now() + 6
	local h = s.hand
	for i, hp in h.players do
		local seat = s.seats[i]
		if seat then
			seat.lastAction = if hp.won and hp.won > 0 then ("WON " .. money(hp.won)) else seat.lastAction
		end
	end
	-- players who asked to leave, or ran out of chips, stand up now
	for i = 1, HE_SEATS do
		local seat = s.seats[i]
		if seat and (seat.leaving or (seat.stack <= 0 and seat.bot)) then
			cashOut(s, i)
		end
	end
end

local function heAwardUncontested(s: any, winner: number)
	local h = s.hand
	local pot = potTotal(h)
	local seat = s.seats[winner]
	if seat then
		seat.stack += pot
		heLog(s, ("%s wins %s (everyone folded)"):format(seat.name, money(pot)))
	end
	h.players[winner].won = pot
	heEndHand(s)
end

local function heNewStreet(s: any)
	local h = s.hand
	for _, hp in h.players do
		hp.bet = 0
		hp.acted = false
	end
	h.currentBet = 0
	h.minRaise = s.bb
	h.street += 1
	if h.street == 1 then
		for _ = 1, 3 do
			table.insert(h.board, table.remove(h.deck))
		end
	elseif h.street <= 3 then
		table.insert(h.board, table.remove(h.deck))
	end
end

local function heStartTurn(s: any, i: number?)
	local h = s.hand
	h.toAct = i
	h.turnEnds = now() + HE_ACTION_SECONDS
	h.turnToken = (h.turnToken or 0) + 1
	if not i then
		return
	end
	local token = h.turnToken
	local seat = s.seats[i]
	if seat and seat.bot then
		task.delay(0.9 + math.random() * 1.4, function()
			if s.hand == h and h.turnToken == token and s.phase == "Playing" then
				M.botAct(s, i)
			end
		end)
	else
		task.delay(HE_ACTION_SECONDS, function()
			if s.hand == h and h.turnToken == token and s.phase == "Playing" then
				local hp = h.players[i]
				local seat2 = s.seats[i]
				if seat2 then
					seat2.timeouts = (seat2.timeouts or 0) + 1
					if seat2.timeouts >= 2 then
						seat2.leaving = true
					end
				end
				M.act(s, i, if hp and hp.bet >= h.currentBet then "Check" else "Fold", 0)
			end
		end)
	end
end

heAdvance = function(s: any)
	local h = s.hand
	-- one player left?
	local alive, lastAlive = 0, nil
	for i in h.players do
		if inHand(s, i) then
			alive += 1
			lastAlive = i
		end
	end
	if alive <= 1 then
		heAwardUncontested(s, lastAlive :: number)
		return
	end
	-- is the betting round over?
	local pending = false
	local actors = 0
	for i, hp in h.players do
		if canAct(s, i) then
			actors += 1
			if not hp.acted or hp.bet < h.currentBet then
				pending = true
			end
		end
	end
	if pending and actors >= 1 then
		-- a lone player who can still act only needs to act while facing a bet
		local nxt = nextSeat(s, h.toAct or s.button, function(i)
			local hp = h.players[i]
			return canAct(s, i) and (not hp.acted or hp.bet < h.currentBet)
		end)
		if nxt then
			heStartTurn(s, nxt)
			return
		end
	end
	-- round complete: next street, or showdown
	if h.street >= 3 then
		heShowdown(s)
		heEndHand(s)
		return
	end
	heNewStreet(s)
	if actors <= 1 then
		-- everyone else is all in: run the board out
		heStartTurn(s, nil)
		task.delay(1.2, function()
			if s.hand == h and s.phase == "Playing" then
				heAdvance(s)
			end
		end)
		return
	end
	local first = nextSeat(s, s.button, function(i)
		return canAct(s, i)
	end)
	heStartTurn(s, first)
end

function M.act(s: any, i: number, action: string, amount: number): (boolean, string?)
	local h = s.hand
	if s.phase ~= "Playing" or not h or h.toAct ~= i then
		return false, "It's not your turn"
	end
	local seat, hp = s.seats[i], h.players[i]
	if not seat or not hp then
		return false, "You're not in this hand"
	end
	local toCall = h.currentBet - hp.bet
	if action == "Fold" then
		hp.folded = true
		seat.lastAction = "Fold"
	elseif action == "Check" then
		if toCall > 0 then
			return false, "You have to call " .. money(toCall) .. " or fold"
		end
		hp.acted = true
		seat.lastAction = "Check"
	elseif action == "Call" then
		putIn(s, i, toCall)
		hp.acted = true
		seat.lastAction = if hp.allin then "All in" else ("Call " .. money(toCall))
	elseif action == "Raise" or action == "AllIn" then
		local maxTo = hp.bet + seat.stack
		local target = if action == "AllIn" then maxTo else math.floor(tonumber(amount) or 0)
		local minTo = h.currentBet + h.minRaise
		if target < minTo and target < maxTo then
			return false, "The minimum raise is to " .. money(minTo)
		end
		target = math.min(target, maxTo)
		if target <= h.currentBet then
			-- all in for less than a call is just a call
			putIn(s, i, target - hp.bet)
			hp.acted = true
			seat.lastAction = "All in"
		else
			local raiseBy = target - h.currentBet
			putIn(s, i, target - hp.bet)
			if raiseBy >= h.minRaise then
				h.minRaise = raiseBy
				-- a full raise re-opens the action for everyone else
				for j, other in h.players do
					if j ~= i then
						other.acted = false
					end
				end
			end
			h.currentBet = target
			hp.acted = true
			seat.lastAction = if hp.allin then ("All in " .. money(target)) elseif target == raiseBy then ("Bet " .. money(target)) else ("Raise to " .. money(target))
		end
	else
		return false, "?"
	end
	if not seat.bot then
		seat.timeouts = 0
	end
	heAdvance(s)
	return true
end

-- simple bot: hand strength + pot odds + a little randomness
function M.botAct(s: any, i: number)
	local h = s.hand
	local seat, hp = s.seats[i], h.players[i]
	if not seat or not hp then
		return
	end
	local toCall = h.currentBet - hp.bet
	local strength
	if #h.board == 0 then
		local a, b = RANK_VALUE[rankOf(hp.cards[1])], RANK_VALUE[rankOf(hp.cards[2])]
		strength = (math.max(a, b) + math.min(a, b) * 0.5) / 21
		if a == b then
			strength += 0.35 + a / 40
		end
		if hp.cards[1]:sub(-1) == hp.cards[2]:sub(-1) then
			strength += 0.06
		end
	else
		local cards = table.clone(hp.cards)
		for _, c in h.board do
			table.insert(cards, c)
		end
		local score = bestHand(cards)
		local category = math.floor(score / 15 ^ 5)
		strength = 0.18 + category * 0.16 + (score % 15 ^ 5) / 15 ^ 5 * 0.12
	end
	strength += (math.random() - 0.5) * 0.2
	local pot = potTotal(h)
	local token = h.turnToken
	if toCall == 0 then
		if strength > 0.7 and math.random() < 0.7 then
			local size = math.max(h.minRaise, math.floor(pot * (0.5 + math.random() * 0.5)))
			M.act(s, i, "Raise", h.currentBet + size)
		else
			M.act(s, i, "Check", 0)
		end
	else
		local odds = toCall / (pot + toCall)
		if strength > 0.85 and math.random() < 0.5 then
			M.act(s, i, "Raise", h.currentBet + math.max(h.minRaise, math.floor(pot * 0.75)))
		elseif strength > odds + 0.25 or toCall <= s.bb then
			M.act(s, i, "Call", 0)
		else
			M.act(s, i, "Fold", 0)
		end
	end
	-- an action the rules rejected (e.g. a raise below the minimum) must never
	-- stall the table: the turn hasn't moved, so check or fold instead
	if s.hand == h and h.turnToken == token and h.toAct == i and s.phase == "Playing" then
		M.act(s, i, if h.currentBet - hp.bet <= 0 then "Check" else "Fold", 0)
	end
end

local function heStartHand(s: any)
	local ready = {}
	for i = 1, HE_SEATS do
		local seat = s.seats[i]
		if seat and seat.stack > 0 and not seat.leaving then
			table.insert(ready, i)
		end
	end
	if #ready < 2 then
		s.phase = "Waiting"
		return
	end
	s.handNo += 1
	local h = { deck = newDeck(1), board = {}, players = {}, street = 0, currentBet = 0, minRaise = s.bb, toAct = nil }
	for _, i in ready do
		h.players[i] = { cards = {}, bet = 0, total = 0, folded = false, allin = false, acted = false }
		s.seats[i].lastAction = ""
	end
	s.hand = h
	s.phase = "Playing"
	s.button = nextSeat(s, s.button, function(i)
		return h.players[i] ~= nil
	end) :: number
	local sbSeat, bbSeat
	if #ready == 2 then
		sbSeat = s.button -- heads-up: the button posts the small blind
	else
		sbSeat = nextSeat(s, s.button, function(i)
			return h.players[i] ~= nil
		end)
	end
	bbSeat = nextSeat(s, sbSeat, function(i)
		return h.players[i] ~= nil
	end)
	putIn(s, sbSeat, s.sb)
	s.seats[sbSeat].lastAction = "SB " .. money(s.sb)
	putIn(s, bbSeat, s.bb)
	s.seats[bbSeat].lastAction = "BB " .. money(s.bb)
	h.currentBet = s.bb
	for _ = 1, 2 do
		for _, i in ready do
			table.insert(h.players[i].cards, table.remove(h.deck))
		end
	end
	heLog(s, ("Hand #%d - blinds %s/%s"):format(s.handNo, money(s.sb), money(s.bb)))
	h.toAct = bbSeat
	local first = nextSeat(s, bbSeat, function(i)
		return canAct(s, i)
	end)
	-- blinds count as "not yet acted" so the big blind gets its option
	if first then
		heStartTurn(s, first)
	else
		heAdvance(s)
	end
end

local function heSnapshot(s: any, player: Player?): any
	local mySeat = player and seatOf(s, player)
	local h = s.hand
	local seats = {}
	for i = 1, HE_SEATS do
		local seat = s.seats[i]
		if seat then
			local hp = h and h.players[i]
			local showCards = hp and (i == mySeat or (h.showdown and not hp.folded))
			table.insert(seats, {
				seat = i,
				name = seat.name,
				userId = if seat.player then seat.player.UserId else 0,
				bot = seat.bot == true,
				isYou = i == mySeat,
				stack = seat.stack,
				bet = hp and hp.bet or 0,
				folded = hp and hp.folded or false,
				allin = hp and hp.allin or false,
				inHand = hp ~= nil,
				cards = if showCards then table.clone(hp.cards) elseif hp then { "??", "??" } else {},
				action = seat.lastAction or "",
				dealer = i == s.button,
				turn = h ~= nil and h.toAct == i and s.phase == "Playing",
				handName = hp and hp.handName,
				won = hp and hp.won,
				leaving = seat.leaving == true,
			})
		end
	end
	local you = mySeat and s.seats[mySeat]
	local hp = h and mySeat and h.players[mySeat]
	local myTurn = h ~= nil and s.phase == "Playing" and h.toAct == mySeat and mySeat ~= nil
	return {
		ok = true,
		phase = s.phase,
		sb = s.sb,
		bb = s.bb,
		configured = s.bb > 0,
		seated = mySeat ~= nil,
		seats = seats,
		board = h and table.clone(h.board) or {},
		pot = h and potTotal(h) or 0,
		myTurn = myTurn,
		toCall = if hp and h then math.max(0, h.currentBet - hp.bet) else 0,
		minRaiseTo = if h then h.currentBet + h.minRaise else 0,
		maxRaiseTo = if hp and you then hp.bet + you.stack else 0,
		currentBet = h and h.currentBet or 0,
		myStack = you and you.stack or 0,
		seconds = if h and s.phase == "Playing" and h.turnEnds then math.max(0, math.ceil(h.turnEnds - now())) elseif s.phase == "Finished" then math.max(0, math.ceil(s.nextStart - now())) else 0,
		log = table.clone(s.log),
		minBuyIn = s.bb * 20,
		freeSeats = HE_SEATS - #seats,
	}
end

local function holdemAction(player: Player, machine: any, id: string, action: string, a: any, b: any): any
	local s = heState(id)
	local mine = seatOf(s, player)
	if action == "View" then
		return heSnapshot(s, player)
	elseif action == "Sit" then
		if mine then
			return heSnapshot(s, player)
		end
		local spec = type(b) == "table" and b or {}
		if s.bb <= 0 then
			-- first player at an empty table sets the stakes
			local sb = math.floor(tonumber(spec.sb) or 0)
			local bb = math.floor(tonumber(spec.bb) or 0)
			if sb < 1 or bb < sb or bb > 1e9 then
				return { ok = false, message = "Set the blinds: small blind at least $1, big blind at least the small blind" }
			end
			s.sb, s.bb = sb, bb
			heLog(s, ("%s opened the table at %s/%s"):format((player:GetAttribute("CharacterName") or player.DisplayName), money(sb), money(bb)))
		end
		local buyIn = math.floor(tonumber(a) or 0)
		if buyIn ~= buyIn or buyIn < s.bb * 20 then
			return { ok = false, message = "Minimum buy-in is " .. money(s.bb * 20) .. " (20 big blinds)" }
		end
		local free = nil
		for i = 1, HE_SEATS do
			if not s.seats[i] then
				free = i
				break
			end
		end
		if not free then
			return { ok = false, message = "The table is full" }
		end
		if not ctx.economy("Charge", player, buyIn) then
			if humans(s) == 0 then
				s.sb, s.bb = 0, 0
			end
			return { ok = false, message = "Not enough money for that buy-in" }
		end
		s.seats[free] = { player = player, name = (player:GetAttribute("CharacterName") or player.DisplayName), stack = buyIn, lastAction = "Sat down", timeouts = 0 }
		heLog(s, ("%s sits down with %s"):format((player:GetAttribute("CharacterName") or player.DisplayName), money(buyIn)))
		return heSnapshot(s, player)
	elseif action == "Leave" then
		if mine then
			if s.phase == "Playing" and s.hand and s.hand.players[mine] and not s.hand.players[mine].folded then
				s.seats[mine].leaving = true
				if s.hand.toAct == mine then
					M.act(s, mine, "Fold", 0)
				else
					s.hand.players[mine].folded = true
				end
				if s.phase == "Playing" then
					local alive = 0
					for i in s.hand.players do
						if inHand(s, i) then
							alive += 1
						end
					end
					if alive <= 1 then
						heAdvance(s)
					end
				end
			else
				cashOut(s, mine)
			end
		end
		return heSnapshot(s, player)
	elseif action == "TopUp" then
		if not mine then
			return { ok = false, message = "Sit down first" }
		end
		if s.phase == "Playing" and s.hand and s.hand.players[mine] then
			return { ok = false, message = "Add chips between hands" }
		end
		local amount = math.floor(tonumber(a) or 0)
		if amount <= 0 or amount ~= amount then
			return { ok = false, message = "Enter an amount" }
		end
		if not ctx.economy("Charge", player, amount) then
			return { ok = false, message = "Not enough money" }
		end
		s.seats[mine].stack += amount
		return heSnapshot(s, player)
	elseif action == "AddBot" then
		if not mine then
			return { ok = false, message = "Sit down first" }
		end
		for i = 1, HE_SEATS do
			if not s.seats[i] then
				local used = {}
				for j = 1, HE_SEATS do
					if s.seats[j] and s.seats[j].bot then
						used[s.seats[j].name] = true
					end
				end
				local name = "Bot"
				for _, n in HE_BOT_NAMES do
					if not used[n] then
						name = n
						break
					end
				end
				s.seats[i] = { bot = true, name = name, stack = s.bb * 100, lastAction = "Sat down" }
				heLog(s, name .. " (bot) sits down")
				return heSnapshot(s, player)
			end
		end
		return { ok = false, message = "The table is full" }
	elseif action == "RemoveBot" then
		for i = HE_SEATS, 1, -1 do
			local seat = s.seats[i]
			if seat and seat.bot and not (s.phase == "Playing" and s.hand and s.hand.players[i]) then
				s.seats[i] = nil
				return heSnapshot(s, player)
			end
		end
		return { ok = false, message = "No bot can leave right now" }
	elseif action == "Fold" or action == "Check" or action == "Call" or action == "Raise" or action == "AllIn" then
		if not mine then
			return { ok = false, message = "You're not seated" }
		end
		local ok, err = M.act(s, mine, action, tonumber(a) or 0)
		if not ok then
			return { ok = false, message = err }
		end
		return heSnapshot(s, player)
	end
	return { ok = false, message = "?" }
end

---------------------------------------------------------------------------
-- DRAGON FORTUNE slot: 5 reels x 3 rows, 243 ways
---------------------------------------------------------------------------
local DRAGON_SCALE = 8.3 -- tuned by simulation for ~95% return
local DRAGON = {
	{ "NINE", 34, { 0.04, 0.10, 0.30 } }, { "TEN", 32, { 0.04, 0.10, 0.30 } }, { "JACK", 30, { 0.05, 0.15, 0.40 } },
	{ "QUEEN", 26, { 0.06, 0.20, 0.50 } }, { "KING", 22, { 0.08, 0.25, 0.75 } }, { "ACE", 20, { 0.10, 0.30, 1.00 } },
	{ "JADE", 14, { 0.20, 0.60, 2.00 } }, { "COIN", 11, { 0.25, 0.80, 3.00 } }, { "TIGER", 8, { 0.40, 1.50, 5.00 } },
	{ "DRAGON", 5, { 0.80, 3.00, 12.0 } }, { "WILD", 6, nil }, { "PEARL", 4, nil },
}
local DRAGON_SPINS = { [3] = 8, [4] = 12, [5] = 20 }
local dragonWeight = 0
for _, sym in DRAGON do
	dragonWeight += sym[2]
end

local function dragonSymbol(col: number): string
	while true do
		local roll = math.random() * dragonWeight
		for _, sym in DRAGON do
			roll -= sym[2]
			if roll <= 0 then
				if sym[1] == "WILD" and (col == 1 or col == 5) then
					break -- wilds only land on reels 2-4
				end
				return sym[1]
			end
		end
	end
end

local function dragonSpin(bet: number): ({ string }, number, number, { any })
	local grid = {}
	for col = 1, 5 do
		grid[col] = { dragonSymbol(col), dragonSymbol(col), dragonSymbol(col) }
	end
	local win, hits = 0, {}
	for _, sym in DRAGON do
		local pays = sym[3]
		if pays then
			local ways, run = 1, 0
			for col = 1, 5 do
				local n = 0
				for row = 1, 3 do
					if grid[col][row] == sym[1] or grid[col][row] == "WILD" then
						n += 1
					end
				end
				if n == 0 then
					break
				end
				ways *= n
				run += 1
			end
			if run >= 3 then
				local amount = math.floor(bet * pays[run - 2] * DRAGON_SCALE * ways)
				win += amount
				table.insert(hits, { symbol = sym[1], count = run, ways = ways, win = amount })
			end
		end
	end
	local pearls = 0
	local flat = {}
	for col = 1, 5 do
		for row = 1, 3 do
			table.insert(flat, grid[col][row])
			if grid[col][row] == "PEARL" then
				pearls += 1
			end
		end
	end
	return flat, win, pearls, hits
end

local function playDragon(player: Player, machine: any, bet: any): any
	local stake, err = ctx.validBet(player, machine, bet)
	if not stake then
		return { ok = false, message = err }
	end
	local grid, win, pearls, hits = dragonSpin(stake)
	local bonus = nil
	local spins = DRAGON_SPINS[math.min(pearls, 5)]
	if spins then
		local results, total = {}, 0
		for i = 1, spins do
			local g, w = dragonSpin(stake)
			w *= 2
			total += w
			results[i] = { grid = g, win = w }
		end
		bonus = { spins = spins, results = results, total = total }
		win += total
	end
	win = math.min(win, stake * ctx.MAX_MULTIPLIER)
	ctx.holdWin(player, machine.id, win)
	return { ok = true, grid = grid, win = win, pearls = pearls, hits = hits, bonus = bonus }
end

---------------------------------------------------------------------------
-- CRAPS (v295)
---------------------------------------------------------------------------
-- One shared game per table, played on the physical table (no window): click a box on the felt to
-- put your chip there, and whoever has a bet down can shoot - the dice are thrown for real and
-- read where they land (the stickman rolls if nobody does). Standard rules and pays:
--   Pass Line 1:1 (come-out 7/11 win, 2/3/12 lose, else the point - hit it before a 7)
--   Don't Pass 1:1 (come-out 2/3 win, 12 pushes, 7/11 lose; then 7 before the point)
--   Field, one roll: 3 4 9 10 11 pay 1:1, 2 pays 2:1, 12 pays 3:1
--   Place 4/10 9:5, 5/9 7:5, 6/8 7:6 (working while a point is on; stay up when they win)
--   Hard 4/10 7:1, Hard 6/8 9:1 (lose to a 7 or the easy way; working while a point is on)
--   Any Seven 4:1, Any Craps 7:1, Yo (11) 15:1 - one roll
-- Pass / Don't Pass go on only on a come-out roll and can't come down once a point is set.
local CR_MAX_BETS = 24
local PLACE_PAY = { [4] = 9 / 5, [5] = 7 / 5, [6] = 7 / 6, [8] = 7 / 6, [9] = 7 / 5, [10] = 9 / 5 }
local HARD_PAY = { [4] = 7, [6] = 9, [8] = 9, [10] = 7 }
local craps: { [string]: any } = {}

local function validCrapsBet(kind: any, value: any): (boolean, number)
	local k = tostring(kind)
	local v = tonumber(value) or 0
	if k == "Place" then
		return PLACE_PAY[v] ~= nil, v
	elseif k == "Hard" then
		return HARD_PAY[v] ~= nil, v
	end
	return (k == "Pass" or k == "DontPass" or k == "Field" or k == "Any7" or k == "AnyCraps" or k == "Yo"), 0
end

local function crState(id: string): any
	local s = craps[id]
	if not s then
		s = { id = id, phase = "Idle", point = nil, dice = nil, bets = {}, wins = {}, round = 0, ends = 0, history = {}, lastText = nil }
		craps[id] = s
	end
	return s
end

local function crSnapshot(s: any, player: Player?): any
	local mine = player and s.bets[player] or {}
	local total = 0
	for _, bet in mine do total += bet.amount end
	local players = 0
	for _, list in s.bets do if #list > 0 then players += 1 end end
	return {
		ok = true,
		phase = s.phase,
		seconds = math.max(0, math.ceil(s.ends - now())),
		point = s.point,
		dice = s.dice,
		myBets = mine,
		myTotal = total,
		myWin = player and s.wins[player] or 0,
		history = table.clone(s.history),
		players = players,
		text = s.lastText,
	}
end

-- settle one roll for every player; returns nothing, pays through ctx
local function crSettle(s: any, d1: number, d2: number)
	local total = d1 + d2
	local hard = d1 == d2
	local point = s.point
	for plr, list in s.bets do
		local keep, won = {}, 0
		local function pay(amount: number)
			amount = math.floor(amount)
			if amount > 0 then
				won += amount
				if plr.Parent then ctx.pay(plr, amount) end
			end
		end
		for _, bet in list do
			local k, a = bet.kind, bet.amount
			local stay = false
			if k == "Pass" then
				if not point then
					if total == 7 or total == 11 then pay(a * 2)
					elseif total == 2 or total == 3 or total == 12 then -- lose
					else stay = true end
				else
					if total == point then pay(a * 2)
					elseif total == 7 then -- seven out
					else stay = true end
				end
			elseif k == "DontPass" then
				if not point then
					if total == 2 or total == 3 then pay(a * 2)
					elseif total == 12 then pay(a) -- push
					elseif total == 7 or total == 11 then -- lose
					else stay = true end
				else
					if total == 7 then pay(a * 2)
					elseif total == point then -- lose
					else stay = true end
				end
			elseif k == "Field" then
				if total == 2 then pay(a * 3)
				elseif total == 12 then pay(a * 4)
				elseif total == 3 or total == 4 or total == 9 or total == 10 or total == 11 then pay(a * 2) end
			elseif k == "Any7" then
				if total == 7 then pay(a * 5) end
			elseif k == "AnyCraps" then
				if total == 2 or total == 3 or total == 12 then pay(a * 8) end
			elseif k == "Yo" then
				if total == 11 then pay(a * 16) end
			elseif k == "Place" then
				if not point then stay = true -- off on the come-out
				elseif total == bet.value then pay(a * PLACE_PAY[bet.value]); stay = true
				elseif total ~= 7 then stay = true end
			elseif k == "Hard" then
				if not point then stay = true
				elseif total == bet.value and hard then pay(a * HARD_PAY[bet.value]); stay = true
				elseif total == bet.value or total == 7 then -- easy way or seven: lose
				else stay = true end
			end
			if stay then table.insert(keep, bet) end
		end
		s.bets[plr] = if #keep > 0 then keep else nil
		s.wins[plr] = won
	end
	-- the point
	local text
	if not point then
		if total == 7 or total == 11 then text = ("%d - WINNER, pass line wins"):format(total)
		elseif total == 2 or total == 3 or total == 12 then text = ("%d - CRAPS"):format(total)
		else
			s.point = total
			text = ("%d - THE POINT IS %d"):format(total, total)
		end
	else
		if total == point then
			s.point = nil
			text = ("%d - WINNER! The point is made"):format(total)
		elseif total == 7 then
			s.point = nil
			text = "7 - SEVEN OUT"
		else
			text = ("%d%s"):format(total, if hard then (" the hard way") else "")
		end
	end
	s.lastText = text
	return text
end

-- the chips on the layout: a stack per player per spot, coloured by denomination
local CR_CHIPS = { -- value, colour (as the chip rack on the client)
	{ 5, Color3.fromRGB(200, 30, 35) }, { 10, Color3.fromRGB(40, 90, 200) }, { 25, Color3.fromRGB(30, 140, 60) },
	{ 50, Color3.fromRGB(235, 120, 30) }, { 100, Color3.fromRGB(25, 25, 28) }, { 250, Color3.fromRGB(230, 110, 170) },
	{ 500, Color3.fromRGB(110, 40, 150) }, { 1000, Color3.fromRGB(240, 190, 40) }, { 2500, Color3.fromRGB(120, 190, 240) },
	{ 5000, Color3.fromRGB(140, 80, 40) }, { 10000, Color3.fromRGB(235, 235, 230) }, { 25000, Color3.fromRGB(30, 150, 150) },
	{ 50000, Color3.fromRGB(120, 20, 40) }, { 100000, Color3.fromRGB(20, 30, 80) }, { 250000, Color3.fromRGB(130, 200, 40) },
	{ 500000, Color3.fromRGB(200, 30, 160) }, { 1000000, Color3.fromRGB(212, 175, 55) }, { 2500000, Color3.fromRGB(190, 195, 200) },
	{ 5000000, Color3.fromRGB(220, 150, 130) }, { 10000000, Color3.fromRGB(200, 240, 255) },
}
local CR_AUTO = 25 -- with bets down and nobody shooting, the stickman rolls after this long

local function crSchedule(s: any)
	local anyone = false
	for _, list in s.bets do if #list > 0 then anyone = true break end end
	if anyone or s.point then
		s.phase = "Betting"
		s.ends = now() + CR_AUTO
	else
		s.phase = "Idle"
		s.ends = 0
	end
end

-- a roll: the dice are thrown down the table for real (physics), and whatever faces come up are
-- the roll; a die off the table is "no roll" and they go again
local function crRoll(s: any, machine: any, shooter: Player?)
	if s.phase == "Rolling" then return end
	s.phase = "Rolling"
	s.shooter = shooter and shooter.Name or "The stickman"
	s.ends = now() + 6
	if machine.crapsBoard then machine.crapsBoard.Text = (s.shooter .. " is rolling...") end
	task.spawn(function()
		local d1, d2
		for _ = 1, 3 do
			local ok, a, b = pcall(machine.crapsThrow)
			if ok and a and b then
				d1, d2 = a, b
				break
			end
			if machine.crapsBoard then machine.crapsBoard.Text = "NO ROLL - again" end
			task.wait(0.6)
		end
		if not d1 then d1, d2 = math.random(1, 6), math.random(1, 6) end
		s.dice = { d1, d2 }
		local text = crSettle(s, d1, d2)
		table.insert(s.history, 1, d1 + d2)
		while #s.history > 14 do table.remove(s.history) end
		if machine.crapsBoard then machine.crapsBoard.Text = text end
		if machine.crapsPuck then pcall(machine.crapsPuck, s.point) end
		if machine.crapsChips then local okC, errC = pcall(machine.crapsChips, s) if not okC then warn("[Craps] chips: " .. tostring(errC)) end end
		crSchedule(s)
		-- the stickman's timer
		local token = s.ends
		task.delay(CR_AUTO, function()
			if s.phase == "Betting" and s.ends == token then crRoll(s, machine, nil) end
		end)
	end)
end

local function crapsAction(player: Player, machine: any, id: string, action: string, a: any, b: any): any
	local s = crState(id)
	if action == "View" then
		local snap = crSnapshot(s, player)
		snap.shooter = s.shooter
		return snap
	elseif action == "Bet" then
		if s.phase == "Rolling" then
			return { ok = false, message = "No more bets - the dice are rolling" }
		end
		local spec = type(b) == "table" and b or {}
		local valid, value = validCrapsBet(spec.kind, spec.value)
		if not valid then
			return { ok = false, message = "Unknown bet" }
		end
		local kind = tostring(spec.kind)
		if (kind == "Pass" or kind == "DontPass") and s.point then
			return { ok = false, message = "Line bets go on with the come-out roll - wait for the point to be made or seven out" }
		end
		local list = s.bets[player] or {}
		if #list >= CR_MAX_BETS then
			return { ok = false, message = "That's the most bets you can have on the layout" }
		end
		local stake, err = ctx.validBet(player, machine, a)
		if not stake then
			return { ok = false, message = err }
		end
		-- the same spot again adds to the chips already there
		local merged = false
		for _, bet in list do
			if bet.kind == kind and bet.value == value then
				bet.amount += stake
				merged = true
				break
			end
		end
		if not merged then table.insert(list, { kind = kind, value = value, amount = stake }) end
		s.bets[player] = list
		s.wins[player] = nil
		if s.phase == "Idle" then
			crSchedule(s)
			local token = s.ends
			task.delay(CR_AUTO, function()
				if s.phase == "Betting" and s.ends == token then crRoll(s, machine, nil) end
			end)
		end
		if machine.crapsChips then local okC, errC = pcall(machine.crapsChips, s) if not okC then warn("[Craps] chips: " .. tostring(errC)) end end
		return crSnapshot(s, player)
	elseif action == "Roll" then
		if s.phase ~= "Betting" then
			return { ok = false, message = if s.phase == "Rolling" then "The dice are already rolling" else "Put a bet down first" }
		end
		if not s.bets[player] then
			return { ok = false, message = "To shoot you need a bet on the layout" }
		end
		crRoll(s, machine, player)
		return crSnapshot(s, player)
	elseif action == "Clear" then
		if s.phase == "Rolling" then
			return { ok = false, message = "Wait for the dice" }
		end
		local list = s.bets[player]
		if list then
			local keep, refund = {}, 0
			for _, bet in list do
				if (bet.kind == "Pass" or bet.kind == "DontPass") and s.point then
					table.insert(keep, bet) -- a contract bet: it stays until the point is decided
				else
					refund += bet.amount
				end
			end
			s.bets[player] = if #keep > 0 then keep else nil
			if refund > 0 then ctx.pay(player, refund) end
		end
		if machine.crapsChips then local okC, errC = pcall(machine.crapsChips, s) if not okC then warn("[Craps] chips: " .. tostring(errC)) end end
		return crSnapshot(s, player)
	end
	return { ok = false, message = "?" }
end

-- The craps table, built of parts at `cf` (floor level; the players stand along its -Z side):
-- the tub with its rails and the padded back wall, the felt with every bet a box you click
-- ("CrapsSpot" parts: BetKind/BetValue, a ClickDetector), the ON/OFF puck, the chips on the
-- spots, and two real dice that are THROWN - unanchored, tumbling down the felt, bouncing off the
-- far wall - and read when they settle. Returns the focus part (the "Play" prompt) and puts a
-- "Roll the dice" prompt on the dice.
local function buildCraps(machine: any, cf: CFrame, parent: Instance): BasePart
	local model = Instance.new("Model")
	model.Name = "CrapsTable"
	model:SetAttribute("CasinoId", machine.id)
	local function part(name: string, size: Vector3, at: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = at
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.Anchored = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if shape then p.Shape = shape end
		p.Parent = model
		return p
	end
	local wood = Color3.fromRGB(92, 52, 28)
	local felt = Color3.fromRGB(18, 96, 50)
	local white = Color3.new(1, 1, 1)
	local L, D = 20, 9 -- the tub inside
	local FT = 3.2 -- the felt's top
	part("Base", Vector3.new(L + 1.4, FT - 0.2, D + 1.4), cf * CFrame.new(0, (FT - 0.2) / 2, 0), wood, Enum.Material.Wood)
	part("Felt", Vector3.new(L, 0.2, D), cf * CFrame.new(0, FT - 0.1, 0), felt, Enum.Material.Fabric)
	-- the rails (chip rails on the players' side), the padded walls the dice bounce off
	for _, z in { -1, 1 } do part("Rail", Vector3.new(L + 1.4, 1.6, 0.7), cf * CFrame.new(0, FT + 0.8, z * (D / 2 + 0.35)), wood, Enum.Material.Wood) end
	for _, x in { -1, 1 } do part("Rail", Vector3.new(0.7, 1.6, D + 1.4), cf * CFrame.new(x * (L / 2 + 0.35), FT + 0.8, 0), wood, Enum.Material.Wood) end
	part("BackWall", Vector3.new(0.3, 1.5, D - 0.2), cf * CFrame.new(L / 2 - 0.15, FT + 0.75, 0), Color3.fromRGB(30, 30, 30), Enum.Material.Rubber)
	part("ChipRail", Vector3.new(L, 0.3, 0.9), cf * CFrame.new(0, FT + 1.45, -(D / 2 + 0.6)), Color3.fromRGB(60, 34, 18), Enum.Material.Wood)
	-- the bets: printed boxes on the felt you click to put your chip down
	local spots = {}
	local function spot(kind: string, value: number, text: string, x: number, z: number, w: number, d: number, color: Color3?, textColor: Color3?)
		local p = part("CrapsSpot", Vector3.new(w - 0.08, 0.04, d - 0.08), cf * CFrame.new(x, FT + 0.02, z), color or felt, Enum.Material.Fabric)
		p.CanCollide = false
		p:SetAttribute("BetKind", kind)
		p:SetAttribute("BetValue", value)
		-- v295b: the print is on a thin plate lying on the box with its FRONT face up (its X along
		-- the box's length, its "up" pointing away from the players) - a Front-face SurfaceGui reads
		-- upright from the players' side whatever the Top-face convention is (the box's own Top
		-- face put the text across the short side, then nowhere when the box was turned)
		local plate = part("CrapsSpotPrint", Vector3.new(w - 0.08, d - 0.08, 0.02),
			CFrame.fromMatrix((cf * CFrame.new(x, FT + 0.05, z)).Position, cf.XVector, cf.ZVector, -cf.YVector), white)
		plate.Transparency = 1
		plate.CanCollide = false
		plate.CanQuery = false -- (clicks go through to the box)
		plate.CanTouch = false
		plate.CastShadow = false
		local g = Instance.new("SurfaceGui")
		g.Face = Enum.NormalId.Front
		g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		g.PixelsPerStud = 40
		g.LightInfluence = 0.4
		g.Parent = plate
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundTransparency = 1
		frame.Parent = g
		local stroke = Instance.new("UIStroke")
		stroke.Color = white
		stroke.Thickness = 3
		stroke.Parent = frame
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(0.94, 0.9)
		t.Position = UDim2.fromScale(0.03, 0.05)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBlack
		t.TextScaled = true
		t.TextColor3 = textColor or white
		t.Text = text
		t.Parent = frame
		local cd = Instance.new("ClickDetector")
		cd.MaxActivationDistance = 22
		cd.Parent = p
		spots[kind .. value] = p
		return p
	end
	-- (x across the table from the shooter's end -x to the back wall +x; z from the players -z)
	local pz = 2.9
	for i, n in { 4, 5, 6, 8, 9, 10 } do
		spot("Place", n, ({ [4] = "4", [5] = "5", [6] = "SIX", [8] = "8", [9] = "NINE", [10] = "10" })[n], -7.5 + (i - 1) * 1.9, pz, 1.9, 2.4)
	end
	spot("Field", 0, "FIELD  2 · 3 · 4 · 9 · 10 · 11 · 12", -2.75, 0.75, 11.4, 1.8)
	spot("DontPass", 0, "DON'T PASS BAR 12", -2.75, -0.75, 11.4, 1.2, Color3.fromRGB(28, 28, 30))
	spot("Pass", 0, "PASS LINE", -2.75, -2.6, 11.8, 2.2)
	-- the proposition box
	local px = 6.2
	spot("Any7", 0, "ANY SEVEN  4:1", px, 3.4, 5.6, 1.1, Color3.fromRGB(150, 30, 35))
	spot("Hard", 6, "HARD 6\n9:1", px - 1.4, 2.2, 2.8, 1.3)
	spot("Hard", 8, "HARD 8\n9:1", px + 1.4, 2.2, 2.8, 1.3)
	spot("Hard", 4, "HARD 4\n7:1", px - 1.4, 0.9, 2.8, 1.3)
	spot("Hard", 10, "HARD 10\n7:1", px + 1.4, 0.9, 2.8, 1.3)
	spot("Yo", 0, "YO 11  15:1", px, -0.3, 5.6, 1.1)
	spot("AnyCraps", 0, "ANY CRAPS  7:1", px, -1.5, 5.6, 1.1, Color3.fromRGB(150, 30, 35))
	-- the puck: OFF by the shooter's end, ON on the point's box
	local puck = part("Puck", Vector3.new(0.2, 1, 1), cf * CFrame.new(-8.8, FT + 0.12, pz) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	puck.CanCollide = false
	local pg = Instance.new("SurfaceGui")
	pg.Face = Enum.NormalId.Right
	pg.CanvasSize = Vector2.new(100, 100)
	pg.Parent = puck
	local pl = Instance.new("TextLabel")
	pl.Size = UDim2.fromScale(1, 1)
	pl.BackgroundTransparency = 1
	pl.Font = Enum.Font.GothamBlack
	pl.TextScaled = true
	pl.TextColor3 = white
	pl.Text = "OFF"
	pl.Parent = pg
	local offAt = puck.CFrame
	machine.crapsPuck = function(point: number?)
		local box = point and spots["Place" .. point]
		if box then
			puck.CFrame = CFrame.new(box.Position + cf:VectorToWorldSpace(Vector3.new(0, 0.12, 0.75))) * cf.Rotation * CFrame.Angles(0, 0, math.rad(90))
			puck.Color = white
			pl.Text = "ON"
			pl.TextColor3 = Color3.new(0, 0, 0)
		else
			puck.CFrame = offAt
			puck.Color = Color3.fromRGB(20, 20, 20)
			pl.Text = "OFF"
			pl.TextColor3 = white
		end
	end
	-- the chips on the spots
	local chipFolder = Instance.new("Folder")
	chipFolder.Name = "Chips"
	chipFolder.Parent = model
	machine.crapsChips = function(s: any)
		chipFolder:ClearAllChildren()
		local seat = 0
		for plr, list in s.bets do
			seat += 1
			for _, bet in list do
				local box = spots[bet.kind .. tostring(bet.value)]
				if box then
					-- the stack: largest chips first, up to 8 high, each player a little apart on the box
					local chips, left = {}, bet.amount
					for i = #CR_CHIPS, 1, -1 do
						while left >= CR_CHIPS[i][1] and #chips < 8 do
							table.insert(chips, CR_CHIPS[i][2])
							left -= CR_CHIPS[i][1]
						end
					end
					if #chips == 0 then chips = { CR_CHIPS[1][2] } end
					local off = Vector3.new(((seat - 1) % 4 - 1.5) * 0.55, 0, (((seat - 1) // 4) - 0.5) * 0.5)
					local basePos = box.Position + cf:VectorToWorldSpace(off)
					for k = #chips, 1, -1 do
						local c = Instance.new("Part")
						c.Name = "Chip"
						c.Shape = Enum.PartType.Cylinder
						c.Size = Vector3.new(0.1, 0.5, 0.5)
						c.CFrame = CFrame.new(basePos + Vector3.new(0, 0.07 + (#chips - k) * 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
						c.Color = chips[k]
						c.Material = Enum.Material.SmoothPlastic
						c.Anchored = true
						c.CanCollide = false
						c.CanQuery = false
						c.CanTouch = false
						-- v295d: whose they are - that player's own client draws theirs itself
						c:SetAttribute("OwnerId", if typeof(plr) == "Instance" then plr.UserId else 0)
						c.Parent = chipFolder
					end
				end
			end
		end
	end
	-- the dice: faces numbered as a real die (opposites add to 7): +Y 1, -Y 6, -Z 2, +Z 5, +X 3, -X 4
	local FACE_VALUE = { { Vector3.new(0, 1, 0), 1, Enum.NormalId.Top }, { Vector3.new(0, -1, 0), 6, Enum.NormalId.Bottom }, { Vector3.new(0, 0, -1), 2, Enum.NormalId.Front }, { Vector3.new(0, 0, 1), 5, Enum.NormalId.Back }, { Vector3.new(1, 0, 0), 3, Enum.NormalId.Right }, { Vector3.new(-1, 0, 0), 4, Enum.NormalId.Left } }
	local PIPS = { [1] = { 5 }, [2] = { 1, 9 }, [3] = { 1, 5, 9 }, [4] = { 1, 3, 7, 9 }, [5] = { 1, 3, 5, 7, 9 }, [6] = { 1, 3, 4, 6, 7, 9 } }
	local dice = {}
	local rest = { cf * CFrame.new(-8.6, FT + 0.4, -1.6), cf * CFrame.new(-8.6, FT + 0.4, -0.7) }
	for i = 1, 2 do
		local d = part("Die", Vector3.new(0.8, 0.8, 0.8), rest[i], Color3.fromRGB(205, 25, 30), Enum.Material.Glass)
		d.Transparency = 0.08
		d.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.35, 0.45, 1, 1)
		for _, fv in FACE_VALUE do
			local g = Instance.new("SurfaceGui")
			g.Face = fv[3]
			g.CanvasSize = Vector2.new(90, 90)
			g.Parent = d
			for _, pip in PIPS[fv[2]] do
				local dot = Instance.new("Frame")
				dot.AnchorPoint = Vector2.new(0.5, 0.5)
				dot.Position = UDim2.fromScale(0.22 + ((pip - 1) % 3) * 0.28, 0.22 + ((pip - 1) // 3) * 0.28)
				dot.Size = UDim2.fromScale(0.2, 0.2)
				dot.BackgroundColor3 = white
				dot.BorderSizePixel = 0
				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(1, 0)
				corner.Parent = dot
				dot.Parent = g
			end
		end
		dice[i] = d
	end
	local function upValue(d: BasePart): number
		local best, value = -2, 1
		for _, fv in FACE_VALUE do
			local dot = d.CFrame:VectorToWorldSpace(fv[1]).Y
			if dot > best then best, value = dot, fv[2] end
		end
		return value
	end
	-- throw them from the shooter's end against the back wall; returns the two up faces, or nil
	-- when a die leaves the table
	machine.crapsThrow = function(): (number?, number?)
		for i, d in dice do
			d.Anchored = false
			d.CFrame = cf * CFrame.new(-8.4, FT + 1.6, -1.6 + i * 1.1) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
			pcall(function() d:SetNetworkOwner(nil) end)
			d.AssemblyLinearVelocity = cf:VectorToWorldSpace(Vector3.new(24 + math.random() * 8, 4 + math.random() * 3, (math.random() - 0.5) * 6))
			d.AssemblyAngularVelocity = Vector3.new(math.random(-30, 30), math.random(-30, 30), math.random(-30, 30))
		end
		local t0, still = now(), 0
		while now() - t0 < 6 do
			task.wait(0.1)
			local moving = false
			for _, d in dice do
				if d.AssemblyLinearVelocity.Magnitude > 0.25 or d.AssemblyAngularVelocity.Magnitude > 0.4 then moving = true end
			end
			still = if moving then 0 else still + 0.1
			if still >= 0.4 then break end
		end
		local values = {}
		local onTable = true
		for i, d in dice do
			local lp = cf:PointToObjectSpace(d.Position)
			if math.abs(lp.X) > L / 2 + 0.2 or math.abs(lp.Z) > D / 2 + 0.2 or lp.Y < FT - 0.5 or lp.Y > FT + 2 then onTable = false end
			values[i] = upValue(d)
			d.Anchored = true
		end
		if not onTable then
			for i, d in dice do d.CFrame = rest[i] end
			return nil, nil
		end
		task.delay(4, function()
			-- the stick brings them back to the shooter
			for i, d in dice do
				if d.Anchored then d.CFrame = rest[i] end
			end
		end)
		return values[1], values[2]
	end
	-- the shooter's prompt, on the dice
	local rp = Instance.new("ProximityPrompt")
	rp.Name = "RollPrompt"
	rp.ActionText = "Roll the dice"
	rp.ObjectText = "Craps"
	rp.KeyboardKeyCode = Enum.KeyCode.R
	rp.HoldDuration = 0.2
	rp.MaxActivationDistance = 10
	rp.RequiresLineOfSight = false
	local rollAnchor = part("RollSpot", Vector3.new(1, 1, 1), cf * CFrame.new(-8.6, FT + 1, -1.1), felt)
	rollAnchor.Transparency = 1
	rollAnchor.CanCollide = false
	rollAnchor.CanQuery = false
	rp.Parent = rollAnchor
	rp.Triggered:Connect(function(player)
		local r = crapsAction(player, machine, machine.id, "Roll")
		if r and r.ok == false and machine.crapsBoard then
			machine.crapsBoard.Text = r.message
		end
	end)
	local focus = part("Focus", Vector3.new(1, 1, 1), cf * CFrame.new(0, FT + 1.5, -(D / 2 + 1)), felt)
	focus.Transparency = 1
	focus.CanCollide = false
	focus.CanQuery = false
	local board = Instance.new("BillboardGui")
	board.Name = "CrapsResult"
	board.Size = UDim2.fromOffset(260, 44)
	board.StudsOffset = Vector3.new(0, 4.2, D / 2 + 1)
	board.MaxDistance = 80
	board.Parent = focus
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	text.BackgroundTransparency = 0.2
	text.TextColor3 = white
	text.Font = Enum.Font.GothamBlack
	text.TextScaled = true
	text.Text = "CRAPS - COMING OUT"
	text.Parent = board
	model.Parent = parent
	machine.model = model
	machine.crapsBoard = text
	machine.tableCamera = CFrame.lookAt((cf * CFrame.new(0, 14, -12)).Position, (cf * CFrame.new(0, FT, 0)).Position)
	return focus
end
M.buildCraps = buildCraps

---------------------------------------------------------------------------
-- physical table rendering (baccarat / hold'em)
---------------------------------------------------------------------------
local function renderLoop()
	while true do
		for _, machine in ctx.machines do
			if machine.kind == "Baccarat" and machine.cardFolder then
				local s = baccarat[machine.id]
				if s then
					local groups = {}
					if #s.player > 0 then
						table.insert(groups, { key = "Player", anchor = machine.handAnchors[1], cards = masked(s.player, s.hiddenP), label = "PLAYER" .. (if allShown(s.hiddenP) then " " .. bacTotal(s.player) else "") })
					end
					if #s.banker > 0 then
						table.insert(groups, { key = "Banker", anchor = machine.handAnchors[3], cards = masked(s.banker, s.hiddenB), label = "BANKER" .. (if allShown(s.hiddenB) then " " .. bacTotal(s.banker) else "") })
					end
					syncCards(machine, groups)
				end
			elseif machine.kind == "Holdem" and machine.cardFolder then
				local s = holdem[machine.id]
				local h = s and s.hand
				local groups = {}
				if s and h and s.phase ~= "Waiting" then
					table.insert(groups, { key = "Board", anchor = machine.handAnchors[2], cards = h.board, label = "POT " .. money(potTotal(h)) })
				end
				syncCards(machine, groups)
			end
		end
		-- hold'em tables deal the next hand on their own
		for _, s in holdem do
			if (s.phase == "Finished" and now() >= s.nextStart) or s.phase == "Waiting" then
				local ready = 0
				for i = 1, HE_SEATS do
					local seat = s.seats[i]
					if seat and seat.stack > 0 and not seat.leaving then
						ready += 1
					end
				end
				if ready >= 2 and (s.phase == "Finished" or (s.waitingSince and now() - s.waitingSince > 3)) then
					s.waitingSince = nil
					heStartHand(s)
				elseif s.phase == "Waiting" and ready >= 2 then
					s.waitingSince = s.waitingSince or now()
				elseif s.phase == "Finished" then
					s.phase = "Waiting"
					s.hand = nil
				end
			end
		end
		task.wait(0.2)
	end
end

---------------------------------------------------------------------------
-- public
---------------------------------------------------------------------------
function M.init(context: any)
	ctx = context
	task.spawn(renderLoop)
end

M.handles = { Baccarat = baccaratAction, Roulette = rouletteAction, Holdem = holdemAction, Craps = crapsAction }

function M.handle(player: Player, machine: any, action: string, a: any, b: any): any?
	if machine.kind == "DragonFortune" then
		if action == "Spin" then
			return playDragon(player, machine, a)
		end
		return { ok = false, message = "?" }
	end
	local handler = M.handles[machine.kind]
	if handler then
		return handler(player, machine, machine.id, action, a, b)
	end
	return nil
end

-- test hooks (used by the offline rules test, harmless in game)
M._holdem = holdem
M._startHand = function(s: any)
	heStartHand(s)
end
M._state = heState

function M.isTable(kind: string): boolean
	return kind == "Baccarat" or kind == "Roulette" or kind == "Holdem" or kind == "Craps"
end

function M.playerRemoving(player: Player)
	for _, s in holdem do
		local i = seatOf(s, player)
		if i then
			if s.phase == "Playing" and s.hand and s.hand.players[i] and not s.hand.players[i].folded then
				s.seats[i].leaving = true
				if s.hand.toAct == i then
					M.act(s, i, "Fold", 0)
				else
					s.hand.players[i].folded = true
				end
			end
			-- pay out now while the player object still exists
			local seat = s.seats[i]
			if seat and seat.stack > 0 then
				ctx.pay(player, seat.stack)
				seat.stack = 0
			end
			if not (s.phase == "Playing" and s.hand and s.hand.players[i]) then
				cashOut(s, i)
			end
		end
	end
	for _, s in roulette do
		if s.phase == "Betting" and s.bets[player] then
			local refund = 0
			for _, bet in s.bets[player] do
				refund += bet.amount
			end
			s.bets[player] = nil
			ctx.pay(player, refund)
		end
	end
	for _, s in craps do
		-- everything on the layout goes back to them (they can't be rolled for once they've gone)
		local list = s.bets[player]
		if list then
			local refund = 0
			for _, bet in list do refund += bet.amount end
			s.bets[player] = nil
			if refund > 0 then ctx.pay(player, refund) end
		end
		s.wins[player] = nil
	end
	for _, s in baccarat do
		if s.phase == "Betting" and s.bets[player] then
			ctx.pay(player, s.bets[player].bet)
			s.bets[player] = nil
			for k = #s.order, 1, -1 do
				if s.order[k] == player then
					table.remove(s.order, k)
				end
			end
		end
	end
end

return M
