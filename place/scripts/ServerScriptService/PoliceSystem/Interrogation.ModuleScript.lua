--[[
	Interrogation  (child ModuleScript of PoliceSystem)   v246-v249, v257b dialogue

	v248 CRIME LOG - the secret truth of who did what. Every crime that goes through
	  Heat.addCrime is logged as an "event"; crimes of the same kind within LinkWindow
	  seconds and LinkRadius studs are the same event, its members are co-defendants.
	  Roles: Planner (first in on a robbery / burglary), Shooter (any violent crime),
	  Driver (did it from a vehicle seat), Lookout / Accomplice. Each member has an
	  evidence strength the police can prove (0-1), never shown to the suspect.
	  Co-defendants in custody are interviewed in different rooms and can't chat.

	v246 INTERROGATION - serious crimes, accomplices or thin evidence. A hold clock
	  (HoldSeconds, ~48 h of game time); Miranda; a clear "I want a lawyer" ends it,
	  "I'm not saying anything" pauses it.

	v257b THE CONVERSATION - two detectives (a good cop and a bad cop who trade places),
	  in phases:
	    1. Miranda: waive and talk, stay quiet, or ask for a lawyer
	    2. "Where were you?": home, the casino, with friends, don't remember, "why?"
	    3. evidence on the table - camera, prints, witness, phone. Each one is REAL or a
	       BLUFF (real more often when their case is strong). Call the bluff ("show me"),
	       deny it, explain it away (a lie = a QTE), no comment
	    4. pressure (family, silence, the death penalty, "your buddy talked") and the
	       deal pitch ("what happens if I cooperate?")
	  Side questions that don't cost a round: the charges, "am I free to go?", water,
	  a break, a phone call, whisper to your lawyer. Get angry ("go to hell") and the bad
	  cop leans in. Rarely a detective crosses the line - a promised deal, a threat, a
	  denied break - and that is recorded (DetectiveViolation) for the court.
	  A lawyer in the room (retained counsel who answered the arrest call) objects,
	  makes them show their evidence, and ends it: "charge my client or let him go".

	v247 QTEs - the character wants to talk; the player fights it (bite, breath, nerve,
	  eye, slip; "say it clearly" for the lawyer request when anxious; lying = slip /
	  nerve). Small miss = nervous tell; bigger = slip (evidence up); collapse = confession.

	v249 SNITCHING - tell the truth, blame someone (crewmate, someone who got away),
	  minimise, deny. Stories are cross-checked against the log; two people blaming the
	  same person is believed; lies are caught (false statement). First to give new info
	  gets the best deal. Snitch jacket (leaks -> SnitchedOn), protective custody.

	Outputs (player attributes + Records): InterrogationEvidence, Confessed,
	NamedAccomplices, LawyeredUp, Cooperative, CooperationDeal, FalseStatements,
	DetectiveViolation. run() returns { secsScale, extraCharges, ... }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local I = {}
I.VERSION = 257

I.CFG = {
	HoldSeconds = 480, -- ~48 h of game time before you must see a judge
	LinkWindow = 180, -- seconds: crimes this close in time ...
	LinkRadius = 260, -- ... and space are one event (co-defendants)
	EventMemory = 1800, -- an arrest this long after the crime still links to it
	ChoiceTimeout = 30,
	QTETimeout = 14,
	SilenceBreak = 15, -- "I'm not saying anything": the detective leaves this long
	MaxRounds = 10,
	MaxSideQuestions = 4, -- per round
	QTEPressure = 35, -- a QTE when pressure is at least this
	FalseStatementScale = 1.15,
	DealNew = 0.5, -- first to give new info (planner / shooter they didn't have)
	DealConfirm = 0.8,
	DealKnown = 0.95,
	MinimiseBelieved = 0.9,
	LeakChance = 0.5, -- a snitch's paperwork leaks to the gangs
	ViolationChance = 0.08, -- a detective crossing the line (promise / threat)
	LawyerEndsAfter = 3, -- rounds before counsel shuts it down
}
local CFG = I.CFG

local LOGGED = {
	Robbery = "Robbery", BankRobbery = "Robbery", Burglary = "Robbery", VehicleTheft = "Theft",
	Murder = "Violence", CopKilled = "Violence", AssaultOfficer = "Violence", ShotsFired = "Violence", Assault = "Violence",
	Drugs = "Drugs", HelicopterDown = "Violence",
}
local VIOLENT = { Murder = true, CopKilled = true, AssaultOfficer = true, ShotsFired = true, Assault = true, HelicopterDown = true }
local ROLE_RANK = { Planner = 4, Shooter = 4, Driver = 2, Lookout = 1, Accomplice = 1 }
local CHARGE_NAMES = {
	Murder = "murder", CopKilled = "the murder of a police officer", AssaultOfficer = "assaulting an officer",
	ShotsFired = "unlawful discharge of a firearm", Assault = "assault", Robbery = "armed robbery",
	BankRobbery = "bank robbery", Burglary = "burglary", VehicleTheft = "grand theft auto", Drugs = "drug dealing",
	PrisonEscape = "escape from custody", HelicopterDown = "downing a police aircraft", ResistingArrest = "resisting arrest",
}

local ctx: any = nil
local events: { any } = {}
local sessions: { [Player]: any } = {}
local roomsInUse: { [Instance]: Player } = {}
local nextEventId = 0

local remote = ReplicatedStorage:FindFirstChild("Interrogation")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "Interrogation"
	remote.Parent = ReplicatedStorage
end
I.remote = remote

local function send(player: Player, ...)
	if player.Parent then (remote :: RemoteEvent):FireClient(player, ...) end
end

---------------------------------------------------------------------------
-- v248 crime log
---------------------------------------------------------------------------
local function memberOf(ev: any, player: Player): any?
	return ev.members[player.UserId]
end

function I.onCrime(player: Player, crimeName: string, pos: Vector3?, crime: any?)
	local family = LOGGED[crimeName]
	if not family or not pos then return end
	local now = os.clock()
	local ev = nil
	for i = #events, 1, -1 do
		local e = events[i]
		if now - e.last > CFG.LinkWindow then break end
		if e.family == family and (e.pos - pos).Magnitude <= CFG.LinkRadius then ev = e; break end
	end
	if not ev then
		nextEventId += 1
		ev = { id = nextEventId, family = family, crime = crimeName, pos = pos, t = now, last = now,
			members = {}, order = 0, talked = {}, blames = {}, named = {} }
		table.insert(events, ev)
		while #events > 60 do table.remove(events, 1) end
	end
	ev.last = now
	if VIOLENT[crimeName] and not VIOLENT[ev.crime] then ev.crime = crimeName end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local inVehicle = hum ~= nil and hum.SeatPart ~= nil and hum.SeatPart:IsA("VehicleSeat")
	local m = memberOf(ev, player)
	if not m then
		ev.order += 1
		local role = if VIOLENT[crimeName] then "Shooter"
			elseif inVehicle then "Driver"
			elseif ev.order == 1 and family == "Robbery" then "Planner"
			elseif ev.order == 1 then "Accomplice"
			else "Lookout"
		local evidence = 0.35 + (if crime and crime.Witness then 0.2 else 0) + math.random() * 0.25
		m = { userId = player.UserId, name = player.Name, player = player, role = role, evidence = math.min(0.95, evidence), crimes = {} }
		ev.members[player.UserId] = m
		print(("[CrimeLog] event #%d %s: %s joins as %s (evidence %.2f)"):format(ev.id, ev.crime, player.Name, role, m.evidence))
	else
		if VIOLENT[crimeName] and m.role ~= "Shooter" and m.role ~= "Planner" then m.role = "Shooter" end
		m.evidence = math.min(0.95, m.evidence + 0.05)
	end
	m.crimes[crimeName] = true
	player:SetAttribute("CrimeEventId", ev.id)
end

function I.eventFor(player: Player): any?
	local now = os.clock()
	for i = #events, 1, -1 do
		local e = events[i]
		if now - e.last > CFG.EventMemory then break end
		if memberOf(e, player) then return e end
	end
	return nil
end

function I.coDefendants(player: Player): { any }
	local out = {}
	local ev = I.eventFor(player)
	if ev then
		for uid, m in ev.members do
			if uid ~= player.UserId then table.insert(out, m) end
		end
	end
	return out
end

function I.shouldInterrogate(player: Player, keys: { [string]: boolean }, stars: number): (boolean, string)
	local ev = I.eventFor(player)
	local m = ev and memberOf(ev, player)
	if #I.coDefendants(player) > 0 then return true, "accomplices involved" end
	if keys.Murder or keys.CopKilled or keys.BankRobbery or keys.Robbery or keys.HelicopterDown then return true, "serious crime" end
	if m and m.evidence < 0.45 then return true, "thin evidence" end
	return false, "case is solid"
end

---------------------------------------------------------------------------
-- co-defendants can't talk to each other while in custody (legacy chat mute)
---------------------------------------------------------------------------
local chatService: any = nil
local function getChat(): any?
	if chatService then return chatService end
	local runner = ServerScriptService:FindFirstChild("ChatServiceRunner")
	local mod = runner and runner:FindFirstChild("ChatService")
	if mod then
		local ok, cs = pcall(require, mod)
		if ok then chatService = cs end
	end
	return chatService
end

local function muteBetween(a: Player, b: Player, on: boolean)
	local cs = getChat()
	if not cs then return end
	pcall(function()
		local sa, sb = cs:GetSpeaker(a.Name), cs:GetSpeaker(b.Name)
		if sa and sb then
			if on then sa:AddMutedSpeaker(b.Name); sb:AddMutedSpeaker(a.Name)
			else sa:RemoveMutedSpeaker(b.Name); sb:RemoveMutedSpeaker(a.Name) end
		end
	end)
end

function I.isolate(player: Player, on: boolean)
	for _, m in I.coDefendants(player) do
		if m.player and m.player.Parent then muteBetween(player, m.player, on) end
	end
end

---------------------------------------------------------------------------
-- rooms (prefer = "PoliceHQ" | "CityJail" | "Prison": only that building)
---------------------------------------------------------------------------
function I.reserveRoom(player: Player, prefer: string?): any?
	if not ctx or not ctx.F then return nil end
	local F = ctx.F
	local list = {}
	for _, t in (if prefer then { prefer } else { "PoliceHQ", "CityJail", "Prison" }) do
		-- stand-in rooms (e.g. the City Jail's interview rooms) except at Police HQ, which has real ones
		for _, z in F.zones(t, "Interrogation", t ~= "PoliceHQ") do table.insert(list, z) end
		if #list > 0 then break end
	end
	for _, z in list do
		local who = roomsInUse[z.instance]
		if not who or not who.Parent or not sessions[who] then
			roomsInUse[z.instance] = player
			return z
		end
	end
	return nil
end

function I.releaseRoom(zone: any?)
	if zone then roomsInUse[zone.instance] = nil end
end

---------------------------------------------------------------------------
-- the cast and the script
---------------------------------------------------------------------------
local BAD_COPS = { "Det. Russo", "Det. Brennan", "Det. Kowalski", "Det. Vance" }
local GOOD_COPS = { "Det. Hayes", "Det. Okafor", "Det. Kim", "Det. Delgado" }

local TACTICS = {
	{ key = "family", good = "Think about your family. You want them reading about this in the news?", bad = "Your mother's going to see your mugshot on Channel 8 tonight. Proud moment.", a = 6, f = 12, n = 4 },
	{ key = "silence", good = "...", bad = "...", a = 10, f = 4, n = 2, wait = 8, stage = "(The detective just stares at you. The clock on the wall ticks.)" },
	{ key = "sympathy", good = "Look, I get it. Things got out of hand. Nobody planned for it to go this way.", bad = "Nobody plans to ruin their life. Yet here you are.", a = -4, f = -2, n = -4 },
	{ key = "time", good = "You can be home in a few years, or you can be an old man when you get out. It's up to you.", bad = "You're looking at decades. Decades.", a = 10, f = 10, n = 2 },
	{ key = "partner", good = "Your friend in the other room is scared. He's talking. I'd hate for you to take the fall for him.", bad = "%s is in room two singing like a bird. Says you %s it.", a = 15, f = 6, n = 10, big = true },
	{ key = "death", good = "This is a capital case. I don't want to see you on death row. Help me help you.", bad = "The DA wants the needle. You understand me? The needle.", a = 10, f = 20, n = 0, big = true },
}

-- evidence pieces: real = what they have; bluff = what they claim
local EVIDENCE = {
	{ key = "camera", claim = "We pulled the footage from the camera across the street.",
		real = "(A grainy still slides across the table. The face is blurry - but the jacket is yours.)",
		bluff = "(He opens the folder. It's a blank sheet. He closes it quickly.) ...The lab's still enhancing it.",
		deny = "That's not me." },
	{ key = "prints", claim = "Your prints are all over the scene.",
		real = "(A fingerprint card with red circles. The tech's note says MATCH.)",
		bluff = "(He taps a folder he doesn't open.) The report's coming.", deny = "I've never been there." },
	{ key = "witness", claim = "We've got a witness who picked you out of a lineup.",
		real = "(A signed statement with a description that fits you down to the shoes.)",
		bluff = "(He doesn't show anything.) She's very sure. Very sure.", deny = "Your witness is wrong." },
	{ key = "phone", claim = "Your phone hit a tower two blocks from the scene.",
		real = "(A printout of tower pings with times circled in red.)",
		bluff = "(He shrugs.) Records take a few days. But we'll get them.", deny = "My phone was at home." },
}

local THOUGHTS = {
	"Just tell them, it'll be easier...", "Don't say anything. Don't say anything.", "They're bluffing. Right?",
	"My hands won't stop shaking.", "How long have I been in here?", "Maybe if I explain...",
	"Is that camera recording?", "They can lie to me. I can't lie to them.", "I need water.",
}
local QTE_KINDS = { "bite", "breath", "nerve", "eye", "slip" }

local function clamp(v: number): number return math.clamp(v, 0, 100) end

local function pressure(s: any): number
	local e = s.emo
	return (e.anxiety + e.fear + e.exhaustion) / 3 + e.anger * 0.2
end

local function pushMeters(s: any)
	send(s.player, "meters", s.emo, s.holdEnds - os.time())
end

-- one spoken line; waits long enough to read it
local function say(s: any, who: string, text: string, pause: number?)
	send(s.player, "say", who, text, nil)
	local t = pause or math.clamp(#text / 38, 1.2, 4)
	local t0 = os.clock()
	while os.clock() - t0 < t and s.alive() do task.wait(0.1) end
end

local function det(s: any): string
	return if s.lead == "bad" then s.badName else s.goodName
end

local function await(s: any, kind: string, timeout: number): any
	s.waiting = kind
	s.answer = nil
	local t0 = os.clock()
	while s.answer == nil and os.clock() - t0 < timeout and s.alive() do task.wait(0.1) end
	s.waiting = nil
	return s.answer
end

-- v247: run one QTE on the client and get a score 0-1 back
local function qte(s: any, kind: string?, hard: boolean?): number
	local k = kind or QTE_KINDS[math.random(1, #QTE_KINDS)]
	local diff = math.clamp(pressure(s) / 100 + (if hard then 0.25 else 0) - (if s.counsel then 0.15 else 0), 0.2, 0.95)
	s.qteId += 1
	send(s.player, "qte", k, diff, s.qteId)
	local res = await(s, "qte", CFG.QTETimeout)
	local score = if type(res) == "number" then math.clamp(res, 0, 1) else 0
	print(("[Interrogation] QTE %s %s diff=%.2f score=%.2f"):format(s.player.Name, k, diff, score))
	return score
end

local function deal(s: any, scale: number, why: string)
	if scale < s.dealScale then
		s.dealScale = scale
		s.cooperative = true
		say(s, det(s), ("That's useful. I'll tell the DA you cooperated (%s)."):format(why))
	end
end

local function falseStatement(s: any, what: string)
	s.falseStatements += 1
	s.credibility = math.max(0, s.credibility - 0.35)
	s.emo.anxiety = clamp(s.emo.anxiety + 15)
	s.emo.anger = clamp(s.emo.anger + 5)
	say(s, det(s), what .. " Lying to us is a crime too.")
	print(("[Interrogation] FALSE STATEMENT %s: %s"):format(s.player.Name, what))
end

local function violation(s: any, kind: string)
	if s.violation then return end
	s.violation = kind
	print(("[Interrogation] DETECTIVE VIOLATION %s: %s"):format(s.player.Name, kind))
	if s.counsel then
		say(s, "YOUR LAWYER", "Did you all hear that? That's going in my motion. This interview is over.")
		s.endNow = true
	else
		send(s.player, "thought", "Can they even say that?")
	end
end

-- v249: name someone. target = member (co-defendant), or "ghost"
local function blame(s: any, targetKey: string)
	local ev, me = s.ev, s.member
	if not ev or not me then
		falseStatement(s, "There's nobody else on this case.")
		return
	end
	local target = nil
	for _, m in ev.members do
		if m.name == targetKey and m.userId ~= me.userId then target = m end
	end
	local key = if target then target.name else targetKey
	ev.blames[key] = (ev.blames[key] or 0) + 1
	local corroborated = targetKey ~= "ghost" and (ev.blames[key] or 0) >= 2
	local truthful = target ~= nil
	if not truthful and not corroborated then
		local someoneFree = false
		for _, m in s.knownMembers do
			if not (m.player and m.player.Parent and ctx.inCustody and ctx.inCustody(m.player)) then someoneFree = true end
		end
		if targetKey == "ghost" and someoneFree then
			say(s, det(s), "Someone who got away. Convenient. We'll look into it.")
			s.credibility = math.max(0, s.credibility - 0.1)
		else
			falseStatement(s, "Nobody puts that person at the scene.")
		end
		return
	end
	local alreadyNamed = ev.named[key] == true
	ev.named[key] = true
	table.insert(s.namedList, key)
	if target and target.player and target.player.Parent then
		target.evidence = math.min(0.98, target.evidence + 0.25)
		if ctx.inCustody and not ctx.inCustody(target.player) and ctx.Heat then
			-- v260: named by an accomplice = a warrant (no stars until someone spots them)
			local api = game:GetService("ServerStorage"):FindFirstChild("CityLifeApi")
			local okW, issued = false, false
			if api and api:IsA("BindableFunction") then okW, issued = pcall(api.Invoke, api, "snitched", s.player, target.player, ev.crime) end
			if not (okW and issued) then pcall(ctx.Heat.addCrime, target.player, ev.crime, nil) end
			print(("[Interrogation] %s named %s -> %s"):format(s.player.Name, key, if okW and issued then "warrant" else "charged / wanted"))
		end
	end
	local myRank = ROLE_RANK[me.role] or 1
	local theirRank = target and ROLE_RANK[target.role] or 2
	local first = #ev.talked == 0 or ev.talked[1] == me.userId
	if not table.find(ev.talked, me.userId) then table.insert(ev.talked, me.userId) end
	if alreadyNamed then
		deal(s, CFG.DealKnown, "they already knew")
	elseif theirRank > myRank and first then
		deal(s, CFG.DealNew, "new information on the " .. string.lower(target and target.role or "ringleader"))
	else
		deal(s, CFG.DealConfirm, "it confirms what we suspected")
	end
	s.snitched = true
	s.player:SetAttribute("SnitchJacket", true)
	s.player:SetAttribute("UndergroundBurned", true)
	if math.random() < CFG.LeakChance then
		s.player:SetAttribute("SnitchedOn", true) -- v237 gang-hit hook
		print(("[Interrogation] %s's statement leaked - snitch jacket"):format(s.player.Name))
	end
end

local function confess(s: any, reason: string)
	s.confessed = true
	s.evidence = math.min(0.99, s.evidence + 0.4)
	say(s, s.player.Name, if #s.knownMembers > 0 then "Fine. FINE. I did it. And I wasn't alone..." else "...Okay. Okay. It was me.")
	print(("[Interrogation] CONFESSION %s (%s)"):format(s.player.Name, reason))
	for _, m in s.knownMembers do blame(s, m.name) end
end

local function chargesText(s: any): string
	local list = {}
	for k in s.keys do
		if CHARGE_NAMES[k] then table.insert(list, CHARGE_NAMES[k]) end
	end
	if #list == 0 then return "We're still putting the charges together." end
	return "You're being held on " .. table.concat(list, ", ") .. "."
end

local function swapDetectives(s: any)
	local was = det(s)
	s.lead = if s.lead == "bad" then "good" else "bad"
	send(s.player, "say", "", ("(%s walks out. %s sits down%s.)"):format(was, det(s), if s.lead == "good" then " with two coffees" else " and drops a thick folder on the table"), nil)
	task.wait(2)
end

---------------------------------------------------------------------------
-- choices. tone: calm / lie / aggressive / lawyer / snitch / side / truth
---------------------------------------------------------------------------
local function C(key: string, text: string, tone: string?, arg: any?): any
	return { key = key, text = text, tone = tone or "calm", arg = arg }
end

local function sideChoices(s: any): { any }
	local list = {}
	if s.sideUsed < CFG.MaxSideQuestions then
		if not s.askedCharges then table.insert(list, C("q_charges", "\"What am I being charged with?\"", "side")) end
		if not s.askedLeave then table.insert(list, C("q_leave", "\"Am I free to go?\"", "side")) end
		if s.emo.exhaustion > 20 and not s.hadWater then table.insert(list, C("q_water", "\"Can I get some water?\"", "side")) end
		if s.round >= 3 and not s.hadBreak then table.insert(list, C("q_break", "\"I need a break. Bathroom.\"", "side")) end
		if not s.askedPhone then table.insert(list, C("q_phone", "\"I get a phone call, right?\"", "side")) end
		if s.counsel then table.insert(list, C("q_counsel", "Whisper to your lawyer", "lawyer")) end
	end
	return list
end

local function baseChoices(): { any }
	return {
		C("silent", "\"I'm not saying anything.\"", "calm"),
		C("lawyer", "\"I want a lawyer.\"", "lawyer"),
	}
end

local function snitchChoices(s: any, list: { any })
	if s.member then
		table.insert(list, C("truth", "Tell them what happened", "truth"))
		if s.member.role ~= "Shooter" and s.member.role ~= "Planner" then
			table.insert(list, C("minimise", "\"I was just the " .. (if s.member.role == "Driver" then "driver" else "lookout") .. ".\"", "lie"))
		end
		for _, m in s.knownMembers do
			table.insert(list, C("blame", "Put it on " .. m.name, "snitch", m.name))
		end
		table.insert(list, C("blame", "Blame someone who got away", "snitch", "ghost"))
	else
		table.insert(list, C("truth", "Admit it", "truth"))
	end
	if s.snitched and not s.pc then
		table.insert(list, C("pc", "\"I need protective custody.\"", "side"))
	end
end

local function phaseChoices(s: any): { any }
	local list = {}
	local phase = s.phase
	if phase == "miranda" then
		list = {
			C("waive", "\"Yeah, I understand. Let's talk.\"", "calm"),
			C("silent", "\"I understand. I'm not saying anything.\"", "calm"),
			C("lawyer", "\"I want a lawyer.\"", "lawyer"),
			C("smart", "\"Do I look stupid to you?\"", "aggressive"),
		}
	elseif phase == "alibi" then
		list = {
			C("alibi_home", "\"I was home. All day.\"", "lie"),
			C("alibi_casino", "\"I was at the casino.\"", "lie"),
			C("alibi_friends", "\"I was with friends. They'll tell you.\"", "lie"),
			C("alibi_forget", "\"I don't remember.\"", "calm"),
			C("alibi_why", "\"Why do you want to know?\"", "calm"),
		}
		for _, c in baseChoices() do table.insert(list, c) end
	elseif phase == "evidence" then
		local p = s.piece
		list = {
			C("ev_show", "\"Show me.\"", "calm"),
			C("ev_deny", "\"" .. (if p then p.deny else "That's not me.") .. "\"", "lie"),
			C("ev_explain", "\"There's an innocent explanation for that.\"", "lie"),
			C("ev_nocomment", "\"No comment.\"", "calm"),
			C("angry", "\"Go to hell.\"", "aggressive"),
			C("lawyer", "\"I want a lawyer.\"", "lawyer"),
		}
	elseif phase == "deal" then
		list = {
			C("deal_ask", "\"What happens if I cooperate?\"", "calm"),
			C("deal_writing", "\"Put it in writing.\"", "calm"),
		}
		snitchChoices(s, list)
		for _, c in baseChoices() do table.insert(list, c) end
	else -- pressure
		list = {
			C("deny", "\"I didn't do anything.\"", "lie"),
			C("angry", "\"Go to hell.\"", "aggressive"),
			C("deal_ask", "\"What happens if I cooperate?\"", "calm"),
		}
		snitchChoices(s, list)
		for _, c in baseChoices() do table.insert(list, c) end
	end
	for _, c in sideChoices(s) do table.insert(list, c) end
	return list
end

---------------------------------------------------------------------------
-- answers -> "continue" | "end" | "again" (a side question: ask again, same round)
---------------------------------------------------------------------------
local function handleChoice(s: any, choice: any): string
	local key = if type(choice) == "table" then choice.key else "silent"
	local arg = if type(choice) == "table" then choice.arg else nil
	local p = s.player
	local me = p.Name
	print(("[Interrogation] CHOICE %s %s %s (%s)"):format(p.Name, tostring(key), tostring(arg or ""), tostring(s.phase)))
	if string.sub(key, 1, 2) == "q_" then
		s.sideUsed += 1
		if key == "q_charges" then
			s.askedCharges = true
			say(s, det(s), chargesText(s))
		elseif key == "q_leave" then
			s.askedLeave = true
			say(s, det(s), "No. You're under arrest. You leave when a judge says so.")
		elseif key == "q_water" then
			s.hadWater = true
			say(s, det(s), if s.lead == "good" then "Sure. Here." else "(He sighs and slides a paper cup across.) Drink up.")
			s.emo.exhaustion = clamp(s.emo.exhaustion - 15)
			s.emo.anxiety = clamp(s.emo.anxiety - 4)
		elseif key == "q_break" then
			s.hadBreak = true
			if s.lead == "bad" and math.random() < CFG.ViolationChance then
				say(s, det(s), "You'll go when we're done.")
				violation(s, "denied a bathroom break")
			else
				say(s, det(s), "Five minutes. An officer will walk you.")
				send(p, "say", "", "(A few minutes in a cold hallway. You catch your breath.)", nil)
				task.wait(3)
				s.emo.anxiety = clamp(s.emo.anxiety - 10)
				s.emo.exhaustion = clamp(s.emo.exhaustion - 8)
			end
		elseif key == "q_phone" then
			s.askedPhone = true
			say(s, det(s), "After we're done here. There's a phone in holding.")
		elseif key == "q_counsel" then
			local advice = if s.evidence >= 0.75 then "They have a real case. Don't make it worse. Say nothing - I'll negotiate."
				elseif s.evidence >= 0.5 then "Half of what they're showing you is smoke. Stay quiet."
				else "They have almost nothing. That's why they're pushing. Not a word."
			say(s, "YOUR LAWYER", "(whispers) " .. advice)
			s.emo.anxiety = clamp(s.emo.anxiety - 12)
			s.emo.fear = clamp(s.emo.fear - 6)
		end
		pushMeters(s)
		return "again"
	end
	if key == "lawyer" then
		local clear = s.counsel or s.emo.anxiety < 55 or qte(s, "lawyer") >= 0.6
		if clear then
			s.lawyered = true
			say(s, det(s), "...Okay. Interview over. We'll get you your lawyer.")
			return "end"
		end
		say(s, me, "\"Maybe... maybe I should get a lawyer?\"")
		say(s, det(s), "Maybe? Let's keep talking for now.")
		return "continue"
	elseif key == "silent" then
		s.silences += 1
		say(s, det(s), if s.lead == "bad" then "Fine. Sit here and think about it." else "Okay. I'll give you some time.")
		s.emo.exhaustion = clamp(s.emo.exhaustion + 8)
		s.emo.anxiety = clamp(s.emo.anxiety + 5)
		pushMeters(s)
		send(p, "say", "", "(The door shuts. You're alone with the hum of the lights.)", nil)
		local t0 = os.clock()
		while os.clock() - t0 < CFG.SilenceBreak and s.alive() and os.time() < s.holdEnds do task.wait(0.5) end
		if s.silences >= 3 then
			say(s, det(s), "We're done here. You'll have your chance in front of a judge.")
			return "end"
		end
		return "continue"
	elseif key == "waive" then
		s.waived = true
		say(s, det(s), "Good. Let's start simple.")
		return "continue"
	elseif key == "smart" then
		s.emo.anger = clamp(s.emo.anger + 8)
		s.lead = "bad"
		say(s, det(s), "Smart guy. We love smart guys in here.")
		return "continue"
	elseif key == "alibi_home" or key == "alibi_casino" or key == "alibi_friends" then
		s.alibi = key
		local guilty = s.member ~= nil
		if key == "alibi_casino" then
			if guilty and math.random() < 0.8 then
				falseStatement(s, "The casino has cameras on every table. You're not on a single one.")
			else
				say(s, det(s), "We'll check the casino tape.")
				s.evidence = math.max(0.1, s.evidence - 0.05)
			end
		elseif key == "alibi_home" then
			if guilty and math.random() < s.evidence then
				falseStatement(s, "Home? Your phone says otherwise.")
			else
				say(s, det(s), "Home alone. Nobody to back that up. Convenient.")
			end
		else
			say(s, det(s), "Names. I'll need names.")
			s.friendsAlibi = true
		end
		return "continue"
	elseif key == "alibi_forget" then
		s.emo.anxiety = clamp(s.emo.anxiety + 5)
		say(s, det(s), "You don't remember where you were a few hours ago. Sure.")
		return "continue"
	elseif key == "alibi_why" then
		say(s, det(s), "Because something happened, and I think you know what.")
		s.emo.anxiety = clamp(s.emo.anxiety + 4)
		return "continue"
	elseif key == "ev_show" then
		local piece = s.piece
		if not piece then return "continue" end
		if s.pieceReal then
			say(s, det(s), "Happy to.", 1)
			send(p, "say", "", piece.real, nil)
			task.wait(2.5)
			s.emo.anxiety = clamp(s.emo.anxiety + 12)
			s.emo.fear = clamp(s.emo.fear + 6)
			send(p, "thought", "That's... that's real.")
		else
			send(p, "say", "", piece.bluff, nil)
			task.wait(2.5)
			s.bluffsCalled += 1
			s.emo.anxiety = clamp(s.emo.anxiety - 10)
			s.emo.fear = clamp(s.emo.fear - 6)
			send(p, "thought", "They've got nothing.")
		end
		return "continue"
	elseif key == "ev_deny" then
		if s.pieceReal and math.random() < 0.7 then
			falseStatement(s, "We both know that's you.")
		else
			say(s, det(s), "Uh huh.")
			s.emo.anger = clamp(s.emo.anger + 3)
		end
		return "continue"
	elseif key == "ev_explain" then
		say(s, me, "\"Look, I was around there earlier. That's all it is.\"", 1.5)
		local score = qte(s, if math.random() < 0.5 then "slip" else "nerve")
		if score >= 0.6 then
			say(s, det(s), "...Maybe. Maybe.")
			s.evidence = math.max(0.1, s.evidence - 0.07)
		elseif score >= 0.3 then
			say(s, det(s), "You're sweating. Your story changes every time you open your mouth.")
			s.emo.anxiety = clamp(s.emo.anxiety + 8)
		else
			falseStatement(s, "That story falls apart and you know it.")
			s.evidence = math.min(0.99, s.evidence + 0.08)
		end
		return "continue"
	elseif key == "ev_nocomment" then
		say(s, det(s), if s.lead == "bad" then "No comment. Great. Juries love no comment." else "Okay. Noted.")
		s.emo.exhaustion = clamp(s.emo.exhaustion + 3)
		return "continue"
	elseif key == "angry" then
		s.emo.anger = clamp(s.emo.anger + 12)
		s.emo.fear = clamp(s.emo.fear - 6)
		if s.lead == "bad" then
			send(p, "say", "", "(He slams his palm on the table. The cup jumps.)", nil)
			task.wait(1.5)
			if math.random() < CFG.ViolationChance then
				say(s, det(s), "Keep it up. People have accidents in holding.")
				violation(s, "threatened the suspect")
			else
				say(s, det(s), "You want to do this the hard way? We've got all night.")
				s.emo.fear = clamp(s.emo.fear + 10)
			end
		else
			say(s, det(s), "Okay. Take a breath. I'm not your enemy here.")
			s.emo.anger = clamp(s.emo.anger - 6)
		end
		return "continue"
	elseif key == "deal_ask" then
		s.dealTalk = true
		if s.lead == "good" and math.random() < CFG.ViolationChance then
			say(s, det(s), "Tell me everything and I'll make sure you walk out of here today. My word.")
			violation(s, "promised a specific deal")
		else
			say(s, det(s), "I can't promise you anything - that's the DA. But when someone helps us, I tell the DA. It matters.")
		end
		return "continue"
	elseif key == "deal_writing" then
		say(s, det(s), "This isn't that kind of room. You want paper, you get a lawyer and the DA.")
		s.emo.anxiety = clamp(s.emo.anxiety - 5)
		return "continue"
	elseif key == "deny" then
		if s.evidence >= 0.7 then
			falseStatement(s, "We can put you right there.")
		else
			say(s, det(s), "Sure you didn't.")
			s.emo.anger = clamp(s.emo.anger + 6)
		end
		return "continue"
	elseif key == "truth" then
		confess(s, "told the truth")
		return "end"
	elseif key == "minimise" then
		local role = s.member and s.member.role
		if role == "Driver" or role == "Lookout" or role == "Accomplice" then
			say(s, det(s), "That matches what we have. Small fish.")
			deal(s, CFG.MinimiseBelieved, "minor role")
			s.cooperative = true
		else
			falseStatement(s, "You were a lot more than that.")
		end
		return "continue"
	elseif key == "blame" then
		blame(s, tostring(arg))
		return "continue"
	elseif key == "pc" then
		s.pc = true
		p:SetAttribute("ProtectiveCustody", true)
		say(s, det(s), "Protective custody. You'll be isolated - no yard, no gangs. Everyone will know why.")
		return "continue"
	end
	return "continue"
end

---------------------------------------------------------------------------
-- the detective's move for this round -> the phase it opens
---------------------------------------------------------------------------
local function detectiveMove(s: any): string
	local p = s.player
	local r = s.round
	if r == 1 then
		say(s, det(s), "You have the right to remain silent. Anything you say can and will be used against you. You have the right to an attorney. Do you understand these rights?")
		if s.counsel then
			say(s, "YOUR LAWYER", "My client understands. He has nothing to say. Ask your questions if you have to.")
		end
		return "miranda"
	end
	if r == 2 then
		say(s, det(s), "So. Where were you this afternoon?")
		return "alibi"
	end
	if r == 4 or r == 7 then swapDetectives(s) end
	if s.friendsAlibi and not s.friendsChecked and r >= 4 then
		s.friendsChecked = true
		if s.member then
			say(s, det(s), "We called your friends. Funny - none of them remember seeing you.")
			s.credibility = math.max(0, s.credibility - 0.2)
			s.emo.anxiety = clamp(s.emo.anxiety + 10)
		else
			say(s, det(s), "Your friends backed you up. For now.")
			s.evidence = math.max(0.1, s.evidence - 0.08)
		end
	end
	if (r == 3 or r == 5 or r == 8) and #s.pieces > 0 then
		local piece = table.remove(s.pieces, math.random(1, #s.pieces))
		s.piece = piece
		s.pieceReal = math.random() < s.evidence
		say(s, det(s), piece.claim)
		if s.counsel and not s.pieceReal and math.random() < 0.6 then
			say(s, "YOUR LAWYER", "Then put it on the table. ...No? Move on, Detective.")
			s.emo.anxiety = clamp(s.emo.anxiety - 8)
			s.bluffsCalled += 1
		end
		return "evidence"
	end
	if r == 6 and (s.member or s.evidence >= 0.6) then
		say(s, det(s), if s.lead == "good" then "Let me be straight with you. Somebody is making a deal today. The first one through that door gets the best one." else "Last chance before the DA decides you're the one who takes the whole weight.")
		return "deal"
	end
	local pool = {}
	for _, t in TACTICS do
		if t.key == "partner" and #s.knownMembers == 0 then continue end
		if t.key == "death" and not (s.keys.Murder or s.keys.CopKilled) then continue end
		if s.usedTactics[t.key] then continue end
		table.insert(pool, t)
	end
	if #pool == 0 then s.usedTactics = {}; pool = { TACTICS[1], TACTICS[3] } end
	local t = pool[math.random(1, #pool)]
	s.usedTactics[t.key] = true
	local line = if s.lead == "bad" then t.bad else t.good
	if t.key == "partner" and s.lead == "bad" then
		line = line:format(s.knownMembers[math.random(1, #s.knownMembers)].name,
			if s.member and s.member.role == "Shooter" then "pulled the trigger" else "planned")
	end
	if t.stage then send(p, "say", "", t.stage, nil); task.wait(1.5) end
	say(s, det(s), line)
	if t.wait then
		local t0 = os.clock()
		while os.clock() - t0 < t.wait and s.alive() do task.wait(0.5) end
	end
	s.emo.anxiety = clamp(s.emo.anxiety + t.a)
	s.emo.fear = clamp(s.emo.fear + t.f)
	s.emo.anger = clamp(s.emo.anger + t.n)
	s.bigMove = t.big == true
	return "pressure"
end

--[[ run(player, opts) - yields until the interview ends.
	opts = { keys, stars, priors, counsel (bool: lawyer in the room), alive() -> bool }
	returns { secsScale, extraCharges, confessed, lawyered, cooperative, evidence, violation } ]]
function I.run(player: Player, opts: any): any
	local ev = I.eventFor(player)
	local me = ev and memberOf(ev, player)
	local known = {}
	if ev then
		for uid, m in ev.members do
			if uid ~= player.UserId then table.insert(known, m) end
		end
	end
	local keys = opts.keys or {}
	local priors = tonumber(opts.priors) or 0
	local pieces = {}
	for _, e in EVIDENCE do table.insert(pieces, e) end
	local s = {
		player = player, ev = ev, member = me, knownMembers = known, keys = keys,
		holdEnds = os.time() + CFG.HoldSeconds,
		emo = {
			anxiety = clamp(25 + (if priors == 0 then 15 else -5 * math.min(priors, 3)) - (if opts.counsel then 15 else 0)),
			fear = clamp(if keys.CopKilled then 40 elseif keys.Murder then 30 elseif keys.BankRobbery then 20 else 10),
			anger = 10, exhaustion = 0,
		},
		evidence = if me then me.evidence else 0.5,
		credibility = 1, dealScale = 1, falseStatements = 0, silences = 0, namedList = {},
		confessed = false, lawyered = false, cooperative = false, snitched = false, pc = false,
		counsel = opts.counsel == true, qteId = 0, round = 0, sideUsed = 0, bluffsCalled = 0,
		lead = if math.random() < 0.5 then "bad" else "good",
		badName = BAD_COPS[math.random(1, #BAD_COPS)], goodName = GOOD_COPS[math.random(1, #GOOD_COPS)],
		pieces = pieces, usedTactics = {}, phase = "miranda", violation = nil, endNow = false,
		alive = opts.alive or function() return player.Parent ~= nil end,
	}
	sessions[player] = s
	I.isolate(player, true)
	print(("[Interrogation] START %s event=%s role=%s evidence=%.2f co-defendants=%d counsel=%s lead=%s"):format(player.Name,
		tostring(ev and ev.id), tostring(me and me.role), s.evidence, #known, tostring(s.counsel), det(s)))
	send(player, "open", { holdEnds = s.holdEnds, emo = s.emo, hold = CFG.HoldSeconds, bad = s.badName, good = s.goodName, counsel = s.counsel })
	local stop = false
	while not stop and s.alive() and os.time() < s.holdEnds and s.round < CFG.MaxRounds and not s.endNow do
		s.round += 1
		s.sideUsed = 0
		s.bigMove = false
		s.phase = detectiveMove(s)
		s.emo.exhaustion = clamp(s.emo.exhaustion + 6)
		pushMeters(s)
		if not s.alive() or s.endNow then break end
		if s.emo.anxiety > 50 and math.random() < 0.6 then
			send(player, "thought", THOUGHTS[math.random(1, #THOUGHTS)])
		end
		-- counsel shuts it down
		if s.counsel and s.round > CFG.LawyerEndsAfter and not s.waived then
			say(s, "YOUR LAWYER", "We're done, Detective. Charge my client or let him go.")
			say(s, det(s), "...Fine. Interview over.")
			s.lawyered = true
			break
		end
		-- v247: keep your mouth shut (from round 3 on)
		if s.round >= 3 and (pressure(s) >= CFG.QTEPressure or s.bigMove) then
			local score = qte(s, nil, s.bigMove)
			if score >= 0.7 then
				s.emo.anxiety = clamp(s.emo.anxiety - 8)
				send(player, "thought", "Breathe. Say nothing.")
			elseif score >= 0.4 then
				s.emo.anxiety = clamp(s.emo.anxiety + 8)
				say(s, det(s), "You're sweating. Something on your mind?")
			elseif score >= 0.15 then
				s.evidence = math.min(0.99, s.evidence + 0.12)
				say(s, player.Name, "\"I- I wasn't even driving that- ...\"")
				say(s, det(s), "Driving what?")
			else
				confess(s, "cracked under pressure")
				stop = true
			end
			pushMeters(s)
		end
		if stop or not s.alive() then break end
		-- the answer (side questions don't use up the round)
		for _ = 1, CFG.MaxSideQuestions + 1 do
			send(player, "choices", phaseChoices(s))
			local choice = await(s, "choice", CFG.ChoiceTimeout)
			if not s.alive() then break end
			local res = handleChoice(s, choice or { key = "silent" })
			pushMeters(s)
			if res == "end" then stop = true; break end
			if res ~= "again" or s.endNow then break end
		end
	end
	if os.time() >= s.holdEnds then
		say(s, det(s), "Time's up. You're going in front of a judge.")
	end
	-- outputs
	local scale = s.dealScale
	local extra = {}
	if s.falseStatements > 0 then
		scale *= math.min(1.5, CFG.FalseStatementScale ^ s.falseStatements)
		table.insert(extra, "False statement to police")
	end
	player:SetAttribute("InterrogationEvidence", math.floor(s.evidence * 100) / 100)
	player:SetAttribute("Confessed", s.confessed or nil)
	player:SetAttribute("LawyeredUp", s.lawyered or nil)
	player:SetAttribute("Cooperative", s.cooperative or nil)
	player:SetAttribute("CooperationDeal", if s.dealScale < 1 then s.dealScale else nil)
	player:SetAttribute("NamedAccomplices", if #s.namedList > 0 then table.concat(s.namedList, ", ") else nil)
	player:SetAttribute("FalseStatements", if s.falseStatements > 0 then s.falseStatements else nil)
	player:SetAttribute("DetectiveViolation", s.violation)
	local result = { secsScale = scale, extraCharges = extra, confessed = s.confessed, lawyered = s.lawyered,
		cooperative = s.cooperative, evidence = s.evidence, named = s.namedList, snitched = s.snitched, protective = s.pc,
		violation = s.violation, falseStatements = s.falseStatements } -- (v291: the trial checks the testimony against the lies)
	send(player, "close", { scale = scale, confessed = s.confessed, lawyered = s.lawyered, named = s.namedList,
		falseStatements = s.falseStatements, protective = s.pc, violation = s.violation, bluffs = s.bluffsCalled })
	print(("[Interrogation] END %s rounds=%d confessed=%s lawyer=%s deal=%.2f false=%d bluffsCalled=%d violation=%s named=[%s] -> time x%.2f"):format(
		player.Name, s.round, tostring(s.confessed), tostring(s.lawyered), s.dealScale, s.falseStatements, s.bluffsCalled,
		tostring(s.violation), table.concat(s.namedList, ","), scale))
	sessions[player] = nil
	return result
end

function I.active(player: Player): boolean
	return sessions[player] ~= nil
end

;(remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, kind: any, a: any, b: any)
	local s = sessions[player]
	if not s then return end
	if kind == "choice" and s.waiting == "choice" and type(a) == "table" then
		-- only accept a choice that was actually offered
		for _, c in phaseChoices(s) do
			if c.key == a.key and (c.arg == nil or c.arg == a.arg) then s.answer = c; return end
		end
	elseif kind == "qte" and s.waiting == "qte" and a == s.qteId and type(b) == "number" then
		s.answer = b
	end
end)

Players.PlayerRemoving:Connect(function(p)
	sessions[p] = nil
	for zone, who in roomsInUse do if who == p then roomsInUse[zone] = nil end end
end)

function I.init(c: any)
	ctx = c
	print(("[Interrogation] v%d ready (crime log, interrogation dialogue, QTEs, snitching)"):format(I.VERSION))
end

return I
