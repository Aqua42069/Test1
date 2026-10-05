--[[
	CityLife.Connections (v267-v269) - the Connections phone app, fixers, money rules (spec 12)
	and appeals (spec 11.7).

	The app lists your contacts - lawyer, private investigator, fixer, shady dealer, corrupt
	officials, gang shot-callers and COs (inside) - what each can do and the price.
	  LEGAL      investigators (evidence, break a snitch's story, dirt), jury consultant, PR
	  STREET     lean on a witness, pressure a co-defendant, find out who snitched, stolen
	             plates, an introduction to the plate maker, the sealed jury list
	  SYSTEM     a detective loses evidence, a clerk loses a warrant, a corrupt DAVID lookup,
	             buy the judge
	  PRISON     protection, respect, a CO who looks away or loses a write-up, muscle, luxuries
	  APPEAL     after a trial conviction, one appeal from prison (a small chance of less time)
	RISK: every illegal payment can be caught (stings, fixers who flip, CO reports) - a
	bribery / obstruction / tampering warrant (or more time inside), and the underground gets
	hotter. More money = better middlemen = lower risk. A monitored prison phone is riskier.
	What money buys for a case is held until the case (Court asks: courtMods).
	Logs: [Links]
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local X = {}
local Core: any

local function serving(player: Player): boolean
	return player:GetAttribute("SentenceEnd") ~= nil
end
local function caseOf(player: Player): any
	local p = Core.Profile.get(player)
	p.connections.case = p.connections.case or {}
	return p.connections.case
end
local function pendingCase(player: Player): boolean
	-- out on bail with a court date, in custody before court, or a warrant / stars
	return player:GetAttribute("CustodyStage") ~= nil or player:GetAttribute("BookingState") ~= nil and not serving(player)
		or player:GetAttribute("CourtDateAt") ~= nil
		or #Core.Warrants.list(player) > 0 or Core.stars(player) > 0
end
local function topSeverity(player: Player): number
	local w = Core.Warrants.active(player)
	local s = if w then w.severity or 1 else 1
	local stars = tonumber(player:GetAttribute("CustodyStars")) or Core.stars(player)
	return math.clamp(math.max(s, math.ceil(stars / 2)), 1, 3)
end

---------------------------------------------------------------------------
-- risk
---------------------------------------------------------------------------
-- -> true when the payment got noticed
function X.risky(player: Player, base: number, price: number, trade: string?): boolean
	local scrutiny = if Core.Underground then Core.Underground.level(trade or "fixers") else 0
	local money = 1 + math.log10(math.max(1, price / 10000))
	local r = base * (1 + scrutiny) / money
	if serving(player) then r *= 1.5 end -- the prison phone is recorded
	return math.random() < math.clamp(r, 0.01, 0.9)
end

-- caught: the charge follows you
function X.caught(player: Player, crime: string, what: string, trade: string?)
	Core.log("Links", "CAUGHT %s: %s (%s)", player.Name, what, crime)
	if Core.Underground then Core.Underground.bump(trade or "fixers", 0.15, "sting: " .. what) end
	if serving(player) then
		local adj = ServerStorage:FindFirstChild("JusticeAdjustSentence")
		if adj and adj:IsA("BindableFunction") then pcall(adj.Invoke, adj, player, 1.3) end
		Core.UI.notice(player, "It was a setup. " .. what .. " - more time added to your sentence.", 8, Color3.fromRGB(120, 20, 20))
	elseif Core.inCustody(player) then
		local rec = Core.records()
		if rec and rec.note then pcall(rec.note, player, "bribery") end
		Core.UI.notice(player, "It was a setup. " .. what .. " - the DA adds a charge.", 8, Color3.fromRGB(120, 20, 20))
		local c = caseOf(player)
		c.evidence = (c.evidence or 0) + 0.2
	else
		Core.Warrants.issue(player, { reason = what, crimes = { crime }, severity = 2, source = "sting" })
	end
	if Core.News then
		Core.News.post({ kind = "corruption", level = 2, headline = ("Sting nets %s in %s"):format((player:GetAttribute("CharacterName") or player.DisplayName), string.lower(what)),
			body = "Investigators say the money trail was recorded from the first payment.", subjects = { player } })
	end
	Core.emit("caught", player, crime, what)
end

---------------------------------------------------------------------------
-- the catalogue
---------------------------------------------------------------------------
-- each: { id, cat, who, title, desc, price(player) -> number, ok(player) -> (bool, why?), run(player, arg) -> (bool, message), risk, illegal, target }
local LIST: { any } = {}
local BY_ID: { [string]: any } = {}
local function add(e: any)
	table.insert(LIST, e)
	BY_ID[e.id] = e
end

-- LEGAL
add({ id = "pi_evidence", cat = "Legal", who = "Marlowe Investigations (PI)", title = "Dig up evidence for your defense",
	desc = "Holes in the State's case before your trial.", price = function() return 25000 end,
	ok = function(p) return pendingCase(p), "You don't have a case" end,
	run = function(p)
		local c = caseOf(p)
		c.evidence = (c.evidence or 0) - 0.12
		return true, "The investigator found a witness who puts you somewhere else. (The State's case is weaker.)"
	end })
add({ id = "pi_snitch", cat = "Legal", who = "Marlowe Investigations (PI)", title = "Break the snitch's story",
	desc = "Someone named you. Make them look like a liar on the stand.", price = function() return 40000 end,
	ok = function(p)
		local s = Core.Profile.get(p).connections.snitchedBy
		return s ~= nil and #s > 0, "Nobody has named you"
	end,
	run = function(p)
		local c = caseOf(p)
		c.evidence = (c.evidence or 0) - 0.1
		return true, "The PI found the informant's own record. Their testimony is worth less now."
	end })
add({ id = "pi_dirt", cat = "Legal", who = "Marlowe Investigations (PI)", title = "Dirt on someone (blackmail)", target = "juror",
	desc = "Pick a juror on your panel - the PI finds what they'd pay to hide.", price = function() return 30000 end,
	ok = function(p) return Core.Jury ~= nil and Core.Jury.known(p), "Get the jury list first" end,
	run = function(p, arg)
		local ok, msg = Core.Jury.dirt(p, tonumber(arg))
		return ok, msg
	end })
add({ id = "jury_consult", cat = "Legal", who = "Vantage Jury Consulting", title = "Jury consultant",
	desc = "Pick the jurors who'll like you. Works on a jury trial.", price = function() return 40000 end,
	ok = function(p) return pendingCase(p), "You don't have a case" end,
	run = function(p)
		caseOf(p).consultant = true
		return true, "The consultant is on your case - three jurors will lean your way."
	end })
add({ id = "pr", cat = "Legal", who = "Halcyon PR", title = "Spin the coverage",
	desc = "Sympathy pieces, quieter headlines, and the underground cools off.", price = function() return 30000 end,
	ok = function() return true end,
	run = function(p)
		local prof = Core.Profile.get(p)
		prof.news.fame = math.floor((prof.news.fame or 0) / 2)
		p:SetAttribute("EliteQuiet", true)
		task.delay(20 * 60, function() if p.Parent then p:SetAttribute("EliteQuiet", nil) end end)
		if Core.Underground then Core.Underground.cool(0.1) end
		local c = caseOf(p)
		c.offerScale = (c.offerScale or 1) * 0.95
		return true, "Your coverage is softened for a while. Fewer people know your face."
	end })

-- STREET
add({ id = "fx_witness", cat = "Street", who = "Sal (fixer)", title = "Lean on a witness", illegal = true, risk = 0.2, crime = "WitnessTampering", trade = "fixers",
	desc = "The witness forgets, changes the story, or doesn't show.", price = function(p) return 30000 * topSeverity(p) end,
	ok = function(p) return pendingCase(p), "You don't have a case" end,
	run = function(p)
		local c = caseOf(p)
		c.evidence = (c.evidence or 0) - 0.15
		return true, "Sal says the witness has a sudden memory problem."
	end })
add({ id = "fx_codef", cat = "Street", who = "Sal (fixer)", title = "Pressure a co-defendant", illegal = true, risk = 0.22, crime = "Obstruction", trade = "fixers",
	desc = "Your co-defendant won't take the stand against you.", price = function() return 45000 end,
	ok = function(p) return pendingCase(p), "You don't have a case" end,
	run = function(p)
		local c = caseOf(p)
		c.evidence = (c.evidence or 0) - 0.1
		return true, "Your co-defendant got the message."
	end })
add({ id = "fx_whosnitched", cat = "Street", who = "Sal (fixer)", title = "Find out who snitched", illegal = true, risk = 0.05, crime = "Obstruction", trade = "fixers",
	desc = "A name from inside the DA's office.", price = function() return 15000 end,
	ok = function() return true end,
	run = function(p)
		local s = Core.Profile.get(p).connections.snitchedBy
		if not s or #s == 0 then return true, "Sal: \"Nobody's talking about you. Yet.\"" end
		return true, "Sal: \"It was " .. table.concat(s, ", ") .. ".\""
	end })
add({ id = "fx_plates", cat = "Street", who = "Eddie's Auto Salvage (shady dealer)", title = "Stolen plates (one set)", illegal = true, risk = 0.05, crime = "PlateTheft", trade = "fences",
	desc = "Cheap. They'll be reported in a few minutes. Fit them with 'Change plates'.", price = function() return 1500 end,
	ok = function() return true end,
	run = function(p)
		local plate = Core.code()
		local types = { "Sedan", "SUV", "Van", "Muscle Car", "Sports Car" }
		local colours = { "Black", "White", "Silver", "Blue", "Red", "Grey" }
		local rec = Core.Plates.register({ plate = plate, owner = Core.fakeName(), kind = "npc", type = types[math.random(1, #types)], colour = colours[math.random(1, #colours)], at = os.time() - 86400 })
		rec.plateStolenAt = os.time() + math.random(180, 420)
		table.insert(Core.Profile.get(p).plates, { plate = plate, kind = "stolen", type = rec.type, colour = rec.colour })
		return true, ("Eddie hands you %s (off a %s %s)."):format(plate, string.lower(rec.colour), rec.type)
	end })
add({ id = "fx_intro", cat = "Street", who = "Sal (fixer)", title = "An introduction to the plate maker", illegal = true, risk = 0.04, crime = "Conspiracy", trade = "coldplates",
	desc = "Cold plates are made to order by someone nobody names. Sal can vouch for you.", price = function() return 75000 end,
	ok = function(p)
		local u = Core.Profile.get(p).underground
		if u.referral then return false, "You already have the introduction" end
		if p:GetAttribute("UndergroundBurned") then return false, "Nobody vouches for a snitch" end
		return true
	end,
	run = function(p)
		Core.Profile.get(p).underground.referral = true
		return true, "Sal: \"Ask for Lenny. " .. (if Core.Underground then Core.Underground.tip() else "After midnight.") .. "\""
	end })
add({ id = "fx_jurylist", cat = "Street", who = "A court clerk (via Sal)", title = "The sealed jury list", illegal = true, risk = 0.15, crime = "JuryTampering", trade = "fixers",
	desc = "Names and addresses of the twelve jurors on your case.", price = function() return 20000 end,
	ok = function(p) return Core.Jury ~= nil and pendingCase(p), "You don't have a case going to trial" end,
	run = function(p)
		Core.Jury.reveal(p)
		return true, "The list is in your phone (Connections > Jury)."
	end })

-- SYSTEM
add({ id = "sys_detective", cat = "System", who = "Det. Ray Kowalski", title = "Lose evidence", illegal = true, risk = 0.25, crime = "Bribery", trade = "fixers",
	desc = "A chain-of-custody 'problem' with the State's best exhibit.", price = function(p) return 60000 * topSeverity(p) end,
	ok = function(p) return pendingCase(p), "You don't have a case" end,
	run = function(p)
		local c = caseOf(p)
		c.evidence = (c.evidence or 0) - 0.25
		return true, "Kowalski: \"Evidence room had a flood. Shame.\""
	end })
add({ id = "sys_clerk", cat = "System", who = "A court clerk (via Sal)", title = "Lose a warrant", illegal = true, risk = 0.2, crime = "Bribery", trade = "fixers",
	desc = "The paperwork goes missing. Not every time.", price = function(p) return 40000 * topSeverity(p) end,
	ok = function(p) return #Core.Warrants.list(p) > 0, "You don't have a warrant" end,
	run = function(p)
		local w = Core.Warrants.active(p)
		if math.random() < 0.75 and w then
			Core.Warrants.drop(p, w.id)
			return true, "The clerk 'misfiled' it: " .. w.reason
		end
		return true, "The clerk took the money, but the warrant was already in the system."
	end })
add({ id = "sys_david", cat = "System", who = "A cop who owes Sal", title = "Look someone up in DAVID", illegal = true, risk = 0.0, crime = "Bribery", trade = "fixers", target = "player",
	desc = "Address, plates and record of anyone. Every lookup is logged - audits happen.", price = function() return 20000 end,
	ok = function() return true end,
	run = function(p, arg)
		local t = Core.byName(arg)
		if not t then return false, "No one by that name" end
		local info = Core.David.bought(p, t)
		return true, ("%s\nAddress: %s\nVehicles: %s\nFlags: %s"):format(info.name, info.address,
			if #info.vehicles > 0 then table.concat(info.vehicles, "; ") else "none", if #info.flags > 0 then table.concat(info.flags, "; ") else "none")
	end })
add({ id = "sys_judge", cat = "System", who = "The judge's bagman", title = "Buy the judge", illegal = true, risk = 0.15, crime = "Bribery", trade = "fixers",
	desc = "Your case lands in Judge Marsh's courtroom, and he sees it your way. Bench trials only.", price = function(p) return ({ 250000, 600000, 1500000 })[topSeverity(p)] end,
	ok = function(p) return pendingCase(p), "You don't have a case" end,
	run = function(p)
		caseOf(p).judgeBought = true
		return true, "\"The judge will see you now.\" Choose a BENCH trial."
	end })

-- PRISON
add({ id = "pr_protect", cat = "Prison", who = "Big Mike (shot-caller)", title = "Protection",
	desc = "Call off hits - even with a snitch jacket. Price depends on how bad it is.", price = function(p) return if p:GetAttribute("SnitchJacket") then 25000 else 5000 end,
	ok = function(p) return serving(p), "You're not inside" end,
	run = function(p)
		p:SetAttribute("SnitchedOn", nil)
		p:SetAttribute("GangProtectionUntil", os.time() + 1800)
		return true, "Big Mike: \"Nobody touches you. For now.\""
	end })
add({ id = "pr_respect", cat = "Prison", who = "Big Mike (shot-caller)", title = "Buy respect", price = function() return 8000 end,
	desc = "Commissary for the crew. They remember who looked after them.",
	ok = function(p) return serving(p), "You're not inside" end,
	run = function(p)
		p:SetAttribute("GangPoints", (tonumber(p:GetAttribute("GangPoints")) or 0) + 15)
		return true, "Respect earned. (+15 gang points)"
	end })
add({ id = "pr_blind", cat = "Prison", who = "C.O. Dawson (bribable)", title = "Look the other way (5 min)", illegal = true, risk = 0.15, crime = "Bribery", trade = "fixers",
	desc = "Fights, trades and wandering go unseen for a few minutes.", price = function() return 3000 end,
	ok = function(p) return serving(p), "You're not inside" end,
	run = function(p)
		p:SetAttribute("COBlindEyeUntil", os.time() + 300)
		return true, "Dawson turns his back for five minutes."
	end })
add({ id = "pr_writeup", cat = "Prison", who = "C.O. Dawson (bribable)", title = "Lose a write-up", illegal = true, risk = 0.12, crime = "Bribery", trade = "fixers",
	desc = "Your last violation never happened.", price = function() return 4000 end,
	ok = function(p) return serving(p) and p:GetAttribute("PrisonViolation") ~= nil, "No write-up to lose" end,
	run = function(p)
		p:SetAttribute("PrisonViolation", nil)
		p:SetAttribute("PrisonViolationSince", nil)
		p:SetAttribute("CORespect", math.min(100, (tonumber(p:GetAttribute("CORespect")) or 0) + 5))
		return true, "The write-up is gone."
	end })
add({ id = "pr_hit", cat = "Prison", who = "Hired muscle", title = "Hit the snitch", illegal = true, risk = 0.2, crime = "Conspiracy", trade = "fixers", target = "snitch",
	desc = "The person who named you gets a visit from the gangs.", price = function() return 20000 end,
	ok = function(p)
		local s = Core.Profile.get(p).connections.snitchedBy
		return s ~= nil and #s > 0, "You don't know who snitched (ask Sal)"
	end,
	run = function(p, arg)
		local t = Core.byName(arg)
		if not t then return false, "They're not around" end
		t:SetAttribute("SnitchedOn", true)
		return true, "The word is out on " .. (t:GetAttribute("CharacterName") or t.DisplayName) .. "."
	end })
add({ id = "pr_lux", cat = "Prison", who = "Commissary", title = "Luxury package", price = function() return 2000 end,
	desc = "Real food, a radio, soft sheets. The COs notice who's comfortable.",
	ok = function(p) return serving(p), "You're not inside" end,
	run = function(p)
		local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		if h then h.Health = h.MaxHealth end
		p:SetAttribute("CORespect", math.min(100, (tonumber(p:GetAttribute("CORespect")) or 0) + 2))
		return true, "Life inside got a little better."
	end })

-- APPEAL
add({ id = "appeal", cat = "Legal", who = "Your lawyer", title = "File an appeal",
	desc = "After a conviction at trial: one appeal, heard by the prison court. 15-30 billed hours. Small odds.", price = function() return 0 end,
	ok = function(p)
		local a = Core.Profile.get(p).appeal
		if not serving(p) then return false, "Only from prison" end
		if a.used then return false, "You've used your appeal" end
		if not a.eligible then return false, "Only a conviction at TRIAL can be appealed (not a plea)" end
		if a.pendingAt then return false, "Your appeal is pending" end
		return true
	end,
	run = function(p) return X.appeal(p) end })

---------------------------------------------------------------------------
-- appeals (v267)
---------------------------------------------------------------------------
function X.appeal(player: Player): (boolean, string)
	local prof = Core.Profile.get(player)
	local a = prof.appeal
	a.pendingAt = os.time()
	Core.Profile.dirty(player)
	local lf = ServerStorage:FindFirstChild("LawFirms")
	if lf and lf:IsA("BindableFunction") then pcall(lf.Invoke, lf, "bill", player, "appeal", 0.5) end
	Core.log("Links", "APPEAL filed by %s", player.Name)
	task.delay(150, function()
		if not player.Parent then return end
		a.pendingAt = nil
		a.used = true
		Core.Profile.dirty(player)
		if not serving(player) then return end
		local firm = tostring(player:GetAttribute("LawyerFirm") or "Public Defender")
		local tierBonus = ({ ["Public Defender"] = 0, ["Local Attorney"] = 0.01, ["Experienced Defense Counsel"] = 0.02, ["Criminal Defense Firm"] = 0.04,
			["Elite Defense Team"] = 0.06, ["National Trial Firm"] = 0.08, ["Premier Counsel"] = 0.1 })[firm] or 0
		local r = math.random()
		-- v288g: no appeal shortens a life sentence
		local se = tonumber(player:GetAttribute("SentenceEnd"))
		if se and se - os.time() > 1e7 then r = 1 end
		local adj = ServerStorage:FindFirstChild("JusticeAdjustSentence")
		local function scale(s: number): number?
			if adj and adj:IsA("BindableFunction") then
				local ok, n = pcall(adj.Invoke, adj, player, s)
				if ok then return n end
			end
			return nil
		end
		local title = "Prison court - appeal"
		-- v290i: Premier Counsel's Elite Representation members: the appeal is won 99 times in 100,
		-- and it throws the conviction out (life and death row included)
		if firm == "Premier Counsel" and player:GetAttribute("EliteRepresentation") == true then
			local won = math.random() < 0.99
			local ov = ServerStorage:FindFirstChild("JusticeOverturn")
			if won and ov and ov:IsA("BindableFunction") and pcall(ov.Invoke, ov, player) then
				Core.UI.ask(player, { title = title, body = "APPEAL GRANTED. Premier Counsel's appellate team found the errors. The conviction is VACATED - you're being released.", options = { "OK" }, timeout = 30 })
				if Core.News then Core.News.post({ kind = "court", level = 2, headline = (player:GetAttribute("CharacterName") or player.DisplayName) .. "'s conviction thrown out on appeal", body = "Premier Counsel's appellate team won again.", subjects = { player } }) end
				Core.log("Links", "APPEAL (elite) won for %s - conviction vacated", player.Name)
				return
			end
			r = 1 -- the 1 in 100
		end
		if r < 0.04 + tierBonus * 0.5 then
			local left = scale(0.3)
			Core.UI.ask(player, { title = title, body = ("APPEAL GRANTED - a new trial was ordered, and the State offered time served plus a little. Time left: %s"):format(left and ("%d:%02d"):format(left // 60, left % 60) or "?"), options = { "OK" }, timeout = 30 })
			if Core.News then Core.News.post({ kind = "court", level = 2, headline = (player:GetAttribute("CharacterName") or player.DisplayName) .. " wins appeal", body = "A judge found errors at the original trial.", subjects = { player } }) end
		elseif r < 0.16 + tierBonus then
			local left = scale(0.6)
			Core.UI.ask(player, { title = title, body = ("Appeal partly granted - your sentence is reduced. Time left: %s"):format(left and ("%d:%02d"):format(left // 60, left % 60) or "?"), options = { "OK" }, timeout = 30 })
			if Core.News then Core.News.post({ kind = "court", level = 1, headline = (player:GetAttribute("CharacterName") or player.DisplayName) .. "'s sentence cut on appeal", subjects = { player } }) end
		else
			Core.UI.ask(player, { title = title, body = "Appeal DENIED. The conviction and the sentence stand.", options = { "OK" }, timeout = 30 })
			if Core.News then Core.News.post({ kind = "court", level = 1, headline = (player:GetAttribute("CharacterName") or player.DisplayName) .. "'s appeal denied", subjects = { player } }) end
		end
		Core.log("Links", "APPEAL decided for %s (roll %.2f)", player.Name, r)
	end)
	return true, "Your lawyer filed the appeal. The prison court will hear it in a few minutes."
end

---------------------------------------------------------------------------
-- the app
---------------------------------------------------------------------------
local function listFor(player: Player): { any }
	local out = {}
	for _, e in LIST do
		local ok, why = e.ok(player)
		table.insert(out, { id = e.id, cat = e.cat, who = e.who, title = e.title, desc = e.desc, price = math.floor(e.price(player) * (if e.illegal and Core.Underground then Core.Underground.priceScale(e.trade) else 1)), available = ok == true,
			why = if ok then nil else why, illegal = e.illegal == true, target = e.target })
	end
	-- extra sections other modules add (metals, offshore, Elite, the plate maker, the jury)
	for _, fn in X.extraLists do
		local ok, extra = pcall(fn, player)
		if ok and type(extra) == "table" then for _, e in extra do table.insert(out, e) end end
	end
	return out
end
X.extraLists = {} :: { (Player) -> { any } }
X.extraRun = {} :: { [string]: (Player, any) -> (boolean, string) }

function X.buy(player: Player, id: string, arg: any): (boolean, string)
	local custom = X.extraRun[id]
	if custom then return custom(player, arg) end
	local e = BY_ID[id]
	if not e then return false, "Unknown" end
	local ok, why = e.ok(player)
	if not ok then return false, why or "Not available" end
	if e.trade and Core.Underground and Core.Underground.dark(e.trade) then return false, e.who .. " has gone dark - try later" end
	local price = math.floor(e.price(player) * (if e.illegal and Core.Underground then Core.Underground.priceScale(e.trade) else 1))
	if e.illegal and e.trade and Core.Underground then Core.Underground.used(player, e.trade) end
	if price > 0 and not Core.charge(player, price) then return false, ("You need %s"):format(Core.UI.money(price)) end
	if e.illegal and e.risk and e.risk > 0 and X.risky(player, e.risk, price, e.trade) then
		X.caught(player, e.crime or "Bribery", e.title, e.trade)
		return false, "It was a setup."
	end
	local okR, done, msg = pcall(e.run, player, arg)
	Core.Profile.dirty(player)
	if not okR then warn("[Links] " .. tostring(done)) return false, "Something went wrong" end
	Core.log("Links", "%s bought %s (%s)", player.Name, id, Core.UI.money(price))
	return done ~= false, tostring(msg or "Done")
end

function X.init(core: any)
	Core = core
	Core.Connections = X
	Core.app("links.list", function(player: Player)
		return listFor(player)
	end)
	Core.app("links.buy", function(player: Player, id: any, arg: any)
		if type(id) ~= "string" then return false, "?" end
		return X.buy(player, id, arg)
	end)
	-- the phone's LAWYER button: LawFirms' call menu (your firm, or pick one to call)
	Core.clientEvent("lawyer.call", function(player: Player)
		local lf = ServerStorage:FindFirstChild("LawFirms")
		if lf and lf:IsA("BindableFunction") then
			pcall(lf.Invoke, lf, "menu", player)
		else
			Core.UI.notice(player, "No signal - try again in a moment", 3)
		end
	end)
	Core.app("links.players", function(player: Player)
		local out = {}
		for _, p in Players:GetPlayers() do
			if p ~= player then table.insert(out, p.Name) end
		end
		return out
	end)

	-- the court asks what money bought for this case
	Core.hook("courtMods", function(player: Player, info: any)
		local prof = Core.Profile.get(player)
		local c = prof.connections.case or {}
		prof.connections.case = {}
		Core.Profile.dirty(player)
		local mods = { evidence = c.evidence, offerScale = c.offerScale, judgeBought = c.judgeBought }
		if (tonumber(player:GetAttribute("EliteSuspicion")) or 0) >= 2 then
			mods.offerScale = (mods.offerScale or 1) * 1.15 -- a harsher DA for the specially treated
		end
		if Core.Jury and not info.minor then
			mods.jurors = Core.Jury.forCourt(player, c.consultant == true)
		end
		Core.log("Links", "courtMods %s: evidence=%s offer=%s judge=%s jurors=%s", player.Name, tostring(mods.evidence), tostring(mods.offerScale),
			tostring(mods.judgeBought), tostring(mods.jurors and #mods.jurors))
		Core.emit("courtStart", player, info)
		return mods
	end)
	-- v288e: your lawyer files the appeal from a phone call (PhoneCalls' lawyer call)
	Core.hook("fileAppeal", function(p: Player)
		local a = Core.Profile.get(p).appeal
		if not serving(p) then return false, "We file once you're processed into the prison. Call me from the phones inside." end
		if a.used then return false, "You've already used your appeal." end
		if not a.eligible then return false, "There's nothing to appeal - only a conviction at trial can be appealed, not a plea." end
		if a.pendingAt then return false, "Your appeal is already filed. We're waiting on the court." end
		return X.appeal(p)
	end)
	Core.hook("courtEvent", function(player: Player, data: any)
		local prof = Core.Profile.get(player)
		-- a conviction at trial can be appealed once
		if (data.verdict == "guilty" or data.verdict == "guilty (some counts)") and data.trial then
			prof.appeal.eligible = true
			prof.appeal.used = false
			Core.UI.notice(player, "You can appeal this conviction once - Connections > File an appeal (from prison)", 8)
		elseif data.verdict == "plea" then
			prof.appeal.eligible = false
		end
		Core.Profile.dirty(player)
		Core.emit("court", player, data)
		return true
	end)
	Core.hook("courtTampering", function(player: Player, juror: number)
		if Core.Underground then Core.Underground.bump("fixers", 0.2, "jury tampering reported") end
		if Core.News then
			Core.News.post({ kind = "tampering", level = 2, headline = ("Mistrial: juror says they were approached in the %s case"):format((player:GetAttribute("CharacterName") or player.DisplayName)),
				body = "The DA has opened a jury tampering investigation.", subjects = { player } })
		end
		Core.emit("tamperingReported", player, juror)
		return true
	end)
	print("[Links] v267-v269 ready (Connections app, fixers, appeals)")
end

return X
