--[[
	Classification (v288) - the prison decides your security level, not the judge.

	INTAKE: after booking, a CO walks the new arrival to the classification desk in intake
	(PrisonMap.Points.ClassificationPoint_1; the classification officer sits at
	ClassificationOfficerPost_1). A short timed interview - gang, enemies / protective custody,
	how you'll do your time - and the officer decides the level from the sentence, the charges,
	the record (priors, escapes, past write-ups inside) and the answers. A death or life sentence
	is fixed by the court.

	INSIDE: every disciplinary action (PrisonExtras' discipline -> ServerStorage.PrisonWriteUp) is
	written up on the record (Records rec.prison, saved). Minor ones (fighting, contraband,
	disrespect, drugs) stay inside: solitary + the write-up. Two write-ups since the last review,
	or any serious one, means a reclassification review at the desk - up a level. Clean time
	(CLEAN_SECONDS without a write-up) earns a review down a level, never below what the
	remaining sentence allows.
	Serious crimes inside (assaulting staff, rioting, a crime committed inside: murder, a killed
	CO...) are charged: a hearing by video from the prison (Court, bench), and a guilty verdict
	adds the new sentence to the time left (consecutive); a killing can mean death.
	Logs: [Classification]
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local CL = {}
CL.LEVELS = { "Low", "Medium", "High", "Maximum", "Supermax" }
local IDX = { Low = 1, Medium = 2, High = 3, Maximum = 4, Supermax = 5 }
local CLEAN_SECONDS = 900 -- 15 real minutes without a write-up = a review down
local REVIEW_EVERY = 60

-- ctx (from PoliceSystem): Records, court (Court module), toDesk(player, alive) -> bool,
-- rehouse(player, level, why) -> bool, prisonCourt(player, text, secs, capital) -> result?,
-- housed(player) -> bool, remaining(player) -> number?, tell(player, msg)
local ctx: any = nil
local busy: { [Player]: boolean } = {}

local function rec(player: Player): any
	local r = if ctx and ctx.Records then ctx.Records.get(player) else {}
	r.prison = r.prison or {}
	local p = r.prison
	p.writeups = p.writeups or {}
	p.clean = p.clean or os.time()
	p.sinceReview = p.sinceReview or 0
	return p
end
local function save(player: Player)
	if ctx and ctx.Records and ctx.Records.touch then pcall(ctx.Records.touch, player) end
end

-- the level the remaining sentence allows at least
function CL.floorFor(secs: number): number
	if secs >= 3600 then return 4 elseif secs >= 1500 then return 3 elseif secs >= 600 then return 2 end
	return 1
end

-- a timed choice (the trial's dialogue cards); the last option is the silent one
local function ask(player: Player, from: string, lines: { string }, options: { string }, seconds: number): number
	local f = ServerStorage:FindFirstChild("Phone")
	if f and f:IsA("BindableFunction") then
		local ok, how, i = pcall(f.Invoke, f, "dialog", player, { from = from, lines = lines, options = options, seconds = seconds, silent = #options })
		if ok and how == "answered" and type(i) == "number" then return i end
	end
	return #options
end
local function say(player: Player, from: string, lines: { string })
	local c = ctx and ctx.court and ctx.court.card
	if c then pcall(c, player, from, lines, { "..." }) end
end

local OFFICER = "Classification Officer"

---------------------------------------------------------------------------
-- intake: the interview at the desk -> the level
---------------------------------------------------------------------------
function CL.interview(player: Player, info: any): string
	local base = tostring(info.base or "Medium")
	if info.fixed or not IDX[base] then
		say(player, OFFICER, { ("Your sentence decides this one: %s."):format(base), "Nothing I can add or take away." })
		return base
	end
	local p = rec(player)
	local secs = tonumber(info.secs) or 600
	local text = string.lower(tostring(info.text or ""))
	local risk = 0
	local why: { string } = {}
	-- the file
	local priors = tonumber(info.priors) or 0
	if priors >= 5 then risk += 0.5; table.insert(why, ("%d prior arrests"):format(priors)) end
	local violent = text:find("murder", 1, true) or text:find("officer", 1, true) or text:find("assault", 1, true) or text:find("robbery", 1, true) or text:find("firearm", 1, true)
	if violent then risk += 0.5; table.insert(why, "violent charges") end
	local esc = (if ctx.Records then (ctx.Records.get(player).escapes or 0) else 0)
	if (tonumber(esc) or 0) > 0 then risk += 1; table.insert(why, "an escape on your record") end
	local pastSerious = 0
	for _, w in p.writeups do if w.serious then pastSerious += 1 end end
	if pastSerious > 0 then risk += 0.5 * math.min(pastSerious, 3); table.insert(why, ("%d serious write-ups from your last time inside"):format(pastSerious)) end

	say(player, OFFICER, { "Sit. This decides where you live for the next while.", (if secs > 1e7 then "Sentence: LIFE WITHOUT PAROLE. Charges: %s." else ("Sentence: " .. ("%d:%02d"):format(secs // 60, secs % 60) .. ". Charges: %s.")):format(tostring(info.text or "-")) })
	-- 1. gangs
	local gang = player:GetAttribute("PrisonGang") or player:GetAttribute("StreetGang")
	local a1 = ask(player, OFFICER, { "Are you affiliated with any gang or crew?" }, {
		"\"No.\"", "\"Yeah. I'll tell you who.\"", "\"That's none of your business.\"", "[Say nothing]" }, 15)
	if a1 == 1 and gang then
		risk += 1; table.insert(why, "you lied about your affiliation")
		say(player, OFFICER, { "\"No?\" The officer turns the monitor toward you. Your name, a gang file.", "\"Try that again in here and see what it gets you.\"" })
	elseif a1 == 2 then
		risk += 0.25; table.insert(why, "gang affiliation (declared)")
	elseif a1 == 3 then
		risk += 0.5; table.insert(why, "refused to answer")
	end
	-- 2. enemies, protective custody
	local a2 = ask(player, OFFICER, { "Anyone in here who wants you hurt? You can ask for protective custody." }, {
		"\"No enemies.\"", "\"I want protective custody.\"", "\"If they come for me, I'll handle it.\"", "[Say nothing]" }, 15)
	if a2 == 2 then
		player:SetAttribute("ProtectiveCustody", true)
		say(player, OFFICER, { "\"Noted. You'll be kept apart from general population where we can.\"" })
	elseif a2 == 3 then
		risk += 0.5; table.insert(why, "threatened violence")
	end
	-- 3. how you'll do your time
	local a3 = ask(player, OFFICER, { "Last question. How are you going to do your time?" }, {
		"\"Quietly. Head down.\"", "\"However I want.\"", "\"Can I get a job? Kitchen, library, anything.\"", "[Say nothing]" }, 12)
	if a3 == 1 then risk -= 0.5 elseif a3 == 2 then risk += 1; table.insert(why, "your attitude") elseif a3 == 3 then risk -= 0.5; player:SetAttribute("PrisonJobRequest", true) end

	local lvl = math.clamp(math.floor(IDX[base] + risk + 0.5), CL.floorFor(secs), 5)
	local level = CL.LEVELS[lvl]
	local lines = { ("Classification: %s."):format(string.upper(level)) }
	if lvl > IDX[base] and #why > 0 then table.insert(lines, "Because of " .. table.concat(why, ", ") .. ".")
	elseif lvl < IDX[base] then table.insert(lines, "You kept it simple. Keep it that way.") end
	table.insert(lines, "\"Next.\"")
	say(player, OFFICER, lines)
	p.level = level
	p.sinceReview = 0
	p.lastReview = os.time()
	p.clean = os.time()
	p.stars = 0 -- a new stay: a clean slate inside (the record of past stays still counts above)
	player:SetAttribute("PrisonStars", 0)
	save(player)
	print(("[Classification] INTAKE %s: base %s, risk %.2f (%s) -> %s"):format(player.Name, base, risk, table.concat(why, "; "), level))
	return level
end

---------------------------------------------------------------------------
-- inside: write-ups, charges, reviews
---------------------------------------------------------------------------
-- v288h: PRISON STARS - like wanted stars outside, but they never come off while you're inside.
-- They set how hard the COs come at you and weigh on every classification review.
local STARS = {
	fighting = 1, ["caught in the act"] = 1, ["failed a drug test"] = 1, ["disrespecting staff"] = 1,
	["contraband smuggled in a visit"] = 1, ["contraband passed in a legal visit"] = 1,
	["assaulting staff"] = 3, rioting = 3, ["inciting a riot"] = 4, ["killing staff"] = 5,
}
local CRIME_STARS = { Assault = 2, AssaultOfficer = 3, ShotsFired = 4, Murder = 4, CopKilled = 5, PrisonEscape = 5 }
function CL.raiseStars(player: Player, n: number)
	local p = rec(player)
	local cur = tonumber(player:GetAttribute("PrisonStars")) or p.stars or 0
	if n > cur then
		p.stars = n
		player:SetAttribute("PrisonStars", n)
		save(player)
		print(("[Classification] PRISON STARS %s %d -> %d"):format(player.Name, cur, n))
		if ctx then ctx.tell(player, ("PRISON ALERT %s - the COs will treat you accordingly"):format(string.rep("*", n))) end
	end
end

-- reason (from PrisonExtras' discipline) -> serious?, the charge, the sentence it carries, capital
local SERIOUS = {
	["killing staff"] = { "Murder of a correctional officer", 3600, true },
	["assaulting staff"] = { "Battery on a correctional officer", 900 },
	["rioting"] = { "Participating in a prison riot", 600 },
	["inciting a riot"] = { "Inciting a prison riot", 900 },
}
local CRIME_CHARGES = {
	CopKilled = { "Murder of a correctional officer", 3600, true },
	Murder = { "Murder (committed in custody)", 3000, true },
	AssaultOfficer = { "Battery on a correctional officer", 900 },
	PrisonEscape = { "Attempted escape", 1200 },
	ShotsFired = { "Discharge of a firearm in a prison", 900 },
}

local function review(player: Player, dir: number, reason: string)
	if busy[player] or not ctx.housed(player) then return end
	busy[player] = true
	task.spawn(function()
		-- after the hole, not during it
		local t0 = os.clock()
		while player.Parent and player:GetAttribute("Solitary") and os.clock() - t0 < 900 do task.wait(2) end
		if not player.Parent or not ctx.housed(player) then busy[player] = nil return end
		local p = rec(player)
		local cur = tostring(player:GetAttribute("SecurityClass") or p.level or "Medium")
		if not IDX[cur] then busy[player] = nil return end -- Death Row / Pardoned: not reviewed
		local floor = CL.floorFor(tonumber(ctx.remaining(player)) or 0)
		local new = math.clamp(IDX[cur] + dir, floor, 5)
		ctx.tell(player, "A classification officer is here for your review")
		local okD = pcall(ctx.toDesk, player)
		local lines = { ("Classification review: %s."):format(reason) }
		if new == IDX[cur] then
			table.insert(lines, ("You stay %s."):format(cur))
		else
			table.insert(lines, ("%s -> %s."):format(cur, CL.LEVELS[new]))
			table.insert(lines, if new > IDX[cur] then "\"You did this to yourself.\"" else "\"Keep your nose clean and it stays that way.\"")
		end
		say(player, OFFICER, lines)
		p.sinceReview = 0
		p.lastReview = os.time()
		p.level = CL.LEVELS[new]
		save(player)
		print(("[Classification] REVIEW %s: %s, %s -> %s (desk=%s)"):format(player.Name, reason, cur, CL.LEVELS[new], tostring(okD)))
		if new ~= IDX[cur] then
			local okR, moved = pcall(ctx.rehouse, player, CL.LEVELS[new], reason)
			if not (okR and moved) then warn("[Classification] rehouse failed for " .. player.Name .. ": " .. tostring(moved)) end
		elseif okD then
			pcall(ctx.rehouse, player, cur, "back to the cell")
		end
		busy[player] = nil
	end)
end

local function charge(player: Player, text: string, secs: number, capital: boolean?)
	task.spawn(function()
		local t0 = os.clock()
		while player.Parent and player:GetAttribute("Solitary") and os.clock() - t0 < 120 do task.wait(2) end -- a little time in the hole first
		if not player.Parent or not ctx.housed(player) then return end
		print(("[Classification] CHARGED %s: %s (%ds%s)"):format(player.Name, text, secs, if capital then ", capital" else ""))
		local ok, res = pcall(ctx.prisonCourt, player, text, secs, capital == true)
		if not ok then warn("[Classification] prison court failed: " .. tostring(res)) end
	end)
end

function CL.writeUp(player: Player, reason: string, crimeKeys: { [string]: any }?)
	if not ctx then return end
	local p = rec(player)
	local serious = SERIOUS[reason]
	do
		local s = STARS[reason] or 1
		for key in crimeKeys or {} do s = math.max(s, CRIME_STARS[key] or 1) end
		-- repeat offending climbs too: every 3 write-ups this stay is another star
		s = math.max(s, math.min(5, 1 + math.floor((p.sinceReview or 0) / 3)))
		CL.raiseStars(player, s)
	end
	local crime = nil
	for key in crimeKeys or {} do
		local c = CRIME_CHARGES[key]
		if c and (not crime or c[2] > crime[2]) then crime = c end
	end
	table.insert(p.writeups, { kind = reason, at = os.time(), serious = (serious or crime) ~= nil })
	while #p.writeups > 30 do table.remove(p.writeups, 1) end
	p.clean = os.time()
	p.sinceReview = (p.sinceReview or 0) + 1
	save(player)
	print(("[Classification] WRITE-UP %s: %s (%d since review)%s"):format(player.Name, reason, p.sinceReview, if serious or crime then " SERIOUS" else ""))
	-- serious crimes go to court; everything counts toward the review
	local c = crime or serious
	if c then charge(player, c[1], c[2], c[3]) end
	if c or p.sinceReview >= 2 then review(player, if c then 2 else 1, if c then c[1] else ("%d write-ups"):format(p.sinceReview)) end
end

function CL.setCourt(court: any)
	if ctx then ctx.court = court end
end

function CL.init(c: any)
	ctx = c
	local ev = ServerStorage:FindFirstChild("PrisonWriteUp") or Instance.new("BindableEvent")
	ev.Name = "PrisonWriteUp"
	ev.Parent = ServerStorage
	ev.Event:Connect(function(player, reason, keys)
		if typeof(player) == "Instance" and player:IsA("Player") then CL.writeUp(player, tostring(reason or "misconduct"), keys) end
	end)
	-- clean time earns a review down
	task.spawn(function()
		while true do
			task.wait(REVIEW_EVERY)
			for _, player in Players:GetPlayers() do
				if ctx.housed(player) and not busy[player] and not player:GetAttribute("Solitary") then
					local p = rec(player)
					local cur = player:GetAttribute("SecurityClass")
					if IDX[cur] and os.time() - (p.clean or os.time()) > CLEAN_SECONDS
						and IDX[cur] > CL.floorFor(tonumber(ctx.remaining(player)) or 0) then
						p.clean = os.time()
						review(player, -1, "clean conduct")
					end
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(p) busy[p] = nil end)
	print("[Classification] v288 ready")
end

return CL
