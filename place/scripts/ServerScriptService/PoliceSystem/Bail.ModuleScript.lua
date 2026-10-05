--[[
	Bail  (child ModuleScript of PoliceSystem)   v254

	The bail decision at Police HQ booking, for cases that aren't cited and released:
	  * amount: $400 per star, +50% per prior arrest, -40% for turning yourself in
	  * no bail: a prior failure to appear, an escape on record, already out on bond
	    (serious / murder cases are held before they get here - see hqCustody)
	  * the detainee chooses on screen (BailClient): pay it, a bondsman (10% fee, gone for
	    good, the bondsman covers the rest), or stay in custody; another player can post it
	    for them at the HQ front desk while the offer is open
	  * posted = walked out with a COURT DATE (kept in the saved record, survives leaving)
	  * court (until the courthouse is built): show up at the HQ front desk inside the window
	    -> the case closes as time served and the bail goes back to whoever paid it
	  * miss it -> failure to appear: bond forfeited, a warrant (Warrant attribute, v260 uses
	    it), +1 failuresToAppear on the record = no bail next time

	init(ctx) ctx = { tell(player, kind, text), charge(player, amount) -> bool,
	                  payBank(player, amount), Records }
	offer(player, info) -> "posted" | "stay" | "denied"   (yields while the detainee decides)
	desk(player) -> bool   (the HQ front desk: court appearance / post someone's bail)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local B = {}
B.VERSION = 254

local CFG = {
	PerStar = 400,
	PriorStep = 0.5,
	TurnedInScale = 0.6,
	BondsmanCut = 0.10,
	DecideSeconds = 30,
	CourtIn = 5 * 60, -- court date: 5 real minutes after release (TEMP for testing - was 20 * 60)
	CourtEarly = 2 * 60, -- (TEMP - was 5 * 60) -- can appear up to 5 minutes early
	CourtWindow = 5 * 60, -- ... and up to 5 minutes late
}
B.CFG = CFG

local ctx: any = nil
local offers: { [Player]: any } = {} -- open bail offers (detainee -> offer)
local remote: RemoteEvent? = nil

local function rec(player: Player): any
	return ctx.Records and ctx.Records.get(player) or {}
end

local function savePending(player: Player, pending: any?)
	if not ctx.Records then
		return
	end
	local r = ctx.Records.get(player)
	r.pendingCourt = pending
	if ctx.Records.touch then
		ctx.Records.touch(player)
	end
	player:SetAttribute("CourtDateAt", if pending then pending.due else nil)
end

function B.pending(player: Player): any?
	local p = rec(player).pendingCourt
	return if type(p) == "table" then p else nil
end

-- nil = no bail
function B.amountFor(player: Player, info: any): (number?, string?)
	local r = rec(player)
	if (tonumber(r.escapes) or 0) > 0 then
		return nil, "an escape on your record"
	end
	if B.pending(player) then
		return nil, "you're already out on bond"
	end
	local stars = math.max(1, tonumber(info.stars) or 1)
	local priors = math.max(0, tonumber(info.priors) or 0)
	local amount = CFG.PerStar * stars * (1 + CFG.PriorStep * priors)
	-- v285: the charge class: felonies are set far higher than misdemeanors
	if info.class == "F" then amount *= 4 elseif info.class == "GM" then amount *= 1.75 end
	-- v286d: missed court before - bail is set much higher (an escape still means no bail)
	if (tonumber(r.failuresToAppear) or 0) > 0 then amount *= 3 end
	if info.turnedIn then
		amount *= CFG.TurnedInScale
	end
	-- v257: a lawyer on retainer argues bail down
	if player:GetAttribute("CounselRetained") then
		amount *= 0.8
	end
	return math.floor(amount / 50 + 0.5) * 50, nil
end

-- where a court date is answered: the courthouse once it's there (v263), else the HQ front desk
local function courtPlace(): string
	if ctx.court and ctx.court.available() then return "the Clark County Courthouse - check in at the COURT CHECK-IN window (ground floor, Clerk's Office off the rotunda)" end
	return "the Police HQ front desk"
end

-- posted: release paperwork + court date
local function post(player: Player, o: any, how: string, payer: Player?)
	o.result = "posted"
	local refundTo = if how == "self" then player.UserId elseif how == "other" and payer then payer.UserId else nil
	savePending(player, {
		due = os.time() + CFG.CourtIn,
		amount = o.amount,
		refundTo = refundTo,
		how = how,
		recIndex = o.info.recIndex,
		charges = o.info.text,
		secs = o.info.secs, -- the sentence at stake (v263: the courthouse hears it)
		stars = o.info.stars,
		priors = o.info.priors,
		felony = o.info.class == "F" or nil, -- v290g: a State Prison case (30 minutes and up)
	})
	if ctx.Records then
		ctx.Records.setOutcome(player, o.info.recIndex, "Bail", { bail = o.amount, bailHow = how })
	end
	ctx.tell(player, "Custody", ("Bail posted ($%d%s). Court date in %d minutes - be at %s."):format(
		o.amount, if how == "bondsman" then ", by a bondsman" elseif how == "other" and payer then ", by " .. payer.Name else "",
		CFG.CourtIn // 60, courtPlace()))
	print(("[Bail] POSTED %s $%d via %s%s"):format(player.Name, o.amount, how, if payer then " (" .. payer.Name .. ")" else ""))
end

function B.offer(player: Player, info: any): string
	local amount, why = B.amountFor(player, info)
	if not amount then
		ctx.tell(player, "Custody", "Bail denied: " .. tostring(why))
		print(("[Bail] DENIED %s (%s)"):format(player.Name, tostring(why)))
		return "denied", why
	end
	local fee = math.max(50, math.floor(amount * CFG.BondsmanCut))
	local o = { amount = amount, fee = fee, info = info, result = nil, expires = os.clock() + CFG.DecideSeconds }
	offers[player] = o
	player:SetAttribute("BailOffered", amount)
	print(("[Bail] OFFER %s $%d (bondsman fee $%d)"):format(player.Name, amount, fee))
	if remote then
		remote:FireClient(player, { amount = amount, fee = fee, seconds = CFG.DecideSeconds, charges = info.text })
	end
	ctx.tell(player, "Custody", ("Bail set at $%d"):format(amount))
	while player.Parent and not o.result and os.clock() < o.expires do
		task.wait(0.25)
	end
	offers[player] = nil
	player:SetAttribute("BailOffered", nil)
	if remote and player.Parent then
		remote:FireClient(player, nil) -- close the panel
	end
	if o.result == "posted" then
		return "posted"
	end
	if not o.result then
		ctx.tell(player, "Custody", "No bail posted - you stay in custody")
	end
	return "stay"
end

-- HQ front desk. Returns true if it handled the visit.
function B.desk(player: Player): boolean
	local p = B.pending(player)
	if p and ctx.court and ctx.court.available() then
		ctx.tell(player, "Notice", "Your case is heard at the Clark County Courthouse - go to the clerk's window there")
		return true
	end
	if p then
		local now = os.time()
		if now < p.due - CFG.CourtEarly then
			ctx.tell(player, "Notice", ("Your court date is in %d minute(s) - come back then"):format(math.ceil((p.due - now) / 60)))
			return true
		end
		-- court (interim): time served, bail back to whoever paid it
		savePending(player, nil)
		if ctx.Records then
			ctx.Records.setOutcome(player, p.recIndex, "TimeServed", { court = os.time() })
		end
		local refundTo = p.refundTo and Players:GetPlayerByUserId(p.refundTo)
		if refundTo and p.amount then
			ctx.payBank(refundTo, p.amount)
			ctx.tell(refundTo, "Notice", ("$%d bail refunded - %s showed up for court"):format(p.amount, player.Name))
		end
		ctx.tell(player, "Notice", ("Court: case closed - time served%s"):format(if refundTo then ". Bail refunded." else ""))
		print(("[Bail] COURT %s appeared - time served"):format(player.Name))
		return true
	end
	-- someone in the holding cell has bail set: post it for them
	for detainee, o in offers do
		if detainee ~= player and detainee.Parent and not o.result then
			if ctx.charge(player, o.amount) then
				post(detainee, o, "other", player)
				ctx.tell(player, "Notice", ("You posted $%d bail for %s"):format(o.amount, detainee.Name))
			else
				ctx.tell(player, "Notice", ("%s's bail is $%d - you can't cover it"):format(detainee.Name, o.amount))
			end
			return true
		end
	end
	return false
end

-- v256: court reminders come in as a phone call (Clark County Court); the old
-- notice is the fallback when the phone system isn't there
local function courtCall(player: Player, text: string)
	local phone = game:GetService("ServerStorage"):FindFirstChild("Phone")
	if phone and phone:IsA("BindableFunction") then
		task.spawn(function()
			local ok = pcall(phone.Invoke, phone, "call", player, {
				from = "Clark County Court", kind = "court",
				lines = { text, "Failure to appear will result in a warrant for your arrest." },
				options = { "I'll be there" }, expires = CFG.CourtWindow + 5 * 60,
			})
			if not ok then ctx.tell(player, "Notice", text) end
		end)
	else
		ctx.tell(player, "Notice", text)
	end
end

-- court dates: reminders, and failures to appear
local function failToAppear(player: Player, p: any)
	savePending(player, nil)
	if ctx.Records then
		ctx.Records.note(player, "failuresToAppear")
		ctx.Records.setOutcome(player, p.recIndex, "FailureToAppear", { fta = os.time() })
	end
	player:SetAttribute("Warrant", "Failure to appear")
	ctx.tell(player, "Notice", ("You missed court. Bond forfeited ($%d) - there's a warrant out for you."):format(tonumber(p.amount) or 0))
	print(("[Bail] FAILURE TO APPEAR %s - warrant issued"):format(player.Name))
end

-- v263: answering a court date at the courthouse clerk's window -> a real hearing (Court.run).
-- Showing up gets the bail back to whoever paid it, whatever the verdict; guilty = remanded.
local appearing: { [Player]: boolean } = {}
function B.appear(player: Player)
	local p = B.pending(player)
	if not p then
		ctx.tell(player, "Notice", "Clerk: there's nothing on the docket for you today.")
		return
	end
	local now = os.time()
	if now < p.due - CFG.CourtEarly then
		ctx.tell(player, "Notice", ("Clerk: your case is in %d minute(s). Come back then."):format(math.ceil((p.due - now) / 60)))
		return
	end
	if appearing[player] then return end
	appearing[player] = true
	savePending(player, nil) -- they're here: no failure to appear while the case is heard
	player:SetAttribute("CourtDateAt", nil)
	local refundTo = p.refundTo and Players:GetPlayerByUserId(p.refundTo)
	if refundTo and p.amount then
		ctx.payBank(refundTo, p.amount)
		ctx.tell(refundTo, "Notice", ("$%d bail refunded - %s showed up for court"):format(p.amount, player.Name))
	end
	print(("[Bail] COURT %s appeared at the courthouse"):format(player.Name))
	local text = tostring(p.charges or player:GetAttribute("CaseCharges") or "the charges")
	local ok, res = pcall(ctx.court.run, player, {
		secs = tonumber(p.secs) or 120, text = text, stars = p.stars, priors = p.priors, free = true,
		prisonFloor = if p.felony then 1800 else nil,
		alive = function() return player.Parent ~= nil end,
		tell = function(m: string) ctx.tell(player, "Notice", m) end,
		cuff = function() end, uncuff = function() end,
		-- v291: sentenced: cuffed for real and walked out by a court officer (the rest of the case is free)
		remandCuff = if ctx.kit then function() ctx.kit.cuff(player) end else nil,
		remandWalk = if ctx.kit then function(goal: Vector3, t: number?): string return ctx.kit.walk(player, goal, t) end else nil,
	})
	appearing[player] = nil
	-- v290: walked out of a multi-day trial and wasn't back when court sat again: a bench warrant
	if not ok and tostring(res) == "COURT_FTA" then
		failToAppear(player, p)
		player:SetAttribute("Warrant", "Failure to appear - walked out of trial")
		return
	end
	if not ok or type(res) ~= "table" then
		warn("[Bail] court hearing failed for " .. player.Name .. ": " .. tostring(res))
		ctx.tell(player, "Notice", "Court: case closed - time served")
		return
	end
	if res.secs > 0 then
		if ctx.Records then ctx.Records.setOutcome(player, p.recIndex, "Pending", { verdict = res.verdict, judge = res.judge, sentence = res.secs }) end
		ctx.tell(player, "Notice", ("The bailiff takes you into custody - %d:%02d to serve"):format(res.secs // 60, res.secs % 60))
		if ctx.remand then ctx.remand(player, res.secs, text, p.recIndex) end
	else
		if ctx.Records then ctx.Records.setOutcome(player, p.recIndex, "Acquitted", { verdict = res.verdict, judge = res.judge }) end
		local steps = ctx.court.spot("CourthouseSteps")
		local c = player.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if steps and r then r.CFrame = CFrame.new(steps.Position + Vector3.new(0, 3, 0)) end
		ctx.tell(player, "Notice", "Case closed - you're free to go")
	end
end

-- v263: the courthouse is up - court dates are answered at its clerk's window
function B.setCourt(court: any, remand: any, kit: any?)
	ctx.court = court
	ctx.remand = remand
	ctx.kit = kit -- v291: { cuff(p), walk(p, goal, t) } for the walk out after a custodial sentence
	task.spawn(function()
		local window = nil
		for _ = 1, 30 do
			window = court.spot("ClerkWindow")
			if window then break end
			task.wait(1)
		end
		if not window then
			warn("[Bail] no ClerkWindow in the courthouse - court dates stay at the HQ front desk")
			return
		end
		local pp = window:FindFirstChild("CourtDatePrompt") or Instance.new("ProximityPrompt")
		pp.Name = "CourtDatePrompt"
		pp.ActionText = "Answer your court date"
		pp.ObjectText = "Clerk of the Court"
		pp.HoldDuration = 0.5
		pp.MaxActivationDistance = 14
		pp.RequiresLineOfSight = false
		pp.Parent = window
		pp.Triggered:Connect(function(player)
			task.spawn(B.appear, player)
		end)
		-- v288m: someone to check in with: a clerk behind the window and a sign over it
		pcall(function()
			local at = court.spot("ClerkSpot") or window
			local m = court.npc and court.npc("Clerk of the Court", "bailiff", at.Position)
			if m then
				m.Name = "CourtClerk"
				local hrp = m:FindFirstChild("HumanoidRootPart") :: BasePart?
				if hrp then
					hrp.Anchored = true
					hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(window.Position.X, hrp.Position.Y, window.Position.Z))
				end
			end
			local s = Instance.new("Part")
			s.Name = "CheckInSign"
			s.Anchored = true
			s.CanCollide = false
			s.Size = Vector3.new(8, 1.6, 0.3)
			s.CFrame = window.CFrame * CFrame.new(0, 4.5, 0)
			s.Color = Color3.fromRGB(20, 20, 24)
			s.Parent = window.Parent
			for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
				local g = Instance.new("SurfaceGui")
				g.Face = face
				local t = Instance.new("TextLabel")
				t.Size = UDim2.fromScale(1, 1)
				t.BackgroundTransparency = 1
				t.TextScaled = true
				t.Font = Enum.Font.Garamond
				t.TextColor3 = Color3.fromRGB(201, 163, 82)
				t.Text = "COURT CHECK-IN"
				t.Parent = g
				g.Parent = s
			end
		end)
		print("[Bail] court dates are answered at the courthouse clerk's window")
	end)
end

function B.init(c: any)
	ctx = c
	local folder = ReplicatedStorage:FindFirstChild("BailRemotes") or Instance.new("Folder")
	folder.Name = "BailRemotes"
	folder.Parent = ReplicatedStorage
	local r = folder:FindFirstChild("Offer") or Instance.new("RemoteEvent")
	r.Name = "Offer"
	r.Parent = folder
	remote = r :: RemoteEvent
	r.OnServerEvent:Connect(function(player, choice)
		local o = offers[player]
		if not o or o.result then
			return
		end
		if choice == "self" then
			if ctx.charge(player, o.amount) then
				post(player, o, "self")
			else
				ctx.tell(player, "Custody", ("You don't have $%d"):format(o.amount))
			end
		elseif choice == "bondsman" then
			if ctx.charge(player, o.fee) then
				post(player, o, "bondsman")
			else
				ctx.tell(player, "Custody", ("You can't even cover the bondsman's $%d"):format(o.fee))
			end
		elseif choice == "stay" then
			o.result = "stay"
		end
	end)
	task.spawn(function()
		while true do
			task.wait(15)
			local now = os.time()
			for _, player in Players:GetPlayers() do
				local p = B.pending(player)
				if p then
					player:SetAttribute("CourtDateAt", p.due)
					if not p.warnedPost and now > (tonumber(p.due) or now) - CFG.CourtIn + 30 then
						-- v256: the court calls once after release to confirm the date
						p.warnedPost = true
						courtCall(player, ("This is the Clark County Court. You are scheduled to appear in %d minute(s) at %s."):format(math.max(1, math.ceil((p.due - now) / 60)), courtPlace()))
					end
					-- v290h: a big case: the press is on the courthouse steps from when check-in opens
					if not p.press and now >= (tonumber(p.due) or now) - CFG.CourtEarly and ctx.court and ctx.court.stakeout then
						p.press = true
						task.spawn(ctx.court.stakeout, player, { text = p.charges, stars = p.stars,
							secs = (tonumber(p.due) or now) + CFG.CourtWindow - now + 60 })
					end
					if now > p.due + CFG.CourtWindow then
						failToAppear(player, p)
					elseif not p.warned5 and now > p.due - 5 * 60 then
						p.warned5 = true
						courtCall(player, "Reminder: your court date is in 5 minutes - " .. courtPlace() .. ".")
					elseif not p.warned0 and now >= p.due then
						p.warned0 = true
						courtCall(player, ("Your case is being called NOW. You have %d minutes to get to %s."):format(CFG.CourtWindow // 60, courtPlace()))
					end
				end
			end
		end
	end)
	print(("[Bail] v%d ready: $%d per star, court in %d min"):format(B.VERSION, CFG.PerStar, CFG.CourtIn // 60))
end

return B
