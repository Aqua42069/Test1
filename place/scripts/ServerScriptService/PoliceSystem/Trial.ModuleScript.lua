--[[
	Trial (child ModuleScript of PoliceSystem)   v291

	THE TRIAL AS A REAL EVIDENCE CONTEST. Replaces the old "lean" number that ~30 hidden nudges
	pushed around before a dice roll.

	THE CASE BOARD - every piece of the State's evidence is an EXHIBIT with a weight (how much it
	proves) and a credibility (1 = as strong as it looks). Each exhibit has three WEAKNESSES a
	defence could attack - and whether each one is REAL is decided by the facts of the arrest
	(night, caught at the scene, a detective's violation, how the footage was taken...) with a
	per-case seed, so it is the same from the first lawyer meeting to the verdict. Attacking a
	real weakness wrecks the exhibit; attacking a solid one makes it look stronger.
	Preparation is what finds the real ones (Trial.reveal: the lawyer meeting, the mock trial, a
	player attorney's investigation; a better firm knows more on the day; Elite Representation
	knows everything - that is how "Premier wins 9 in 10" works now: they don't miss).

	THE TRIAL - motions (suppress a statement taken after you asked for a lawyer, exclude
	evidence with a broken chain of custody, dismiss a case too thin to go to a jury) -> openings
	(the defence theory decides which attacks fit) -> the State's case (each exhibit: direct
	examination with LIVE OBJECTIONS - some lines are hearsay / leading / speculation / character,
	the objector has seconds to hit OBJECT and pick the ground - then cross, then the DA's
	redirect) -> the defence case (an expert aimed at one exhibit, a real alibi or a perjured one,
	character witnesses for sentencing, the defendant on the stand, checked against what they told
	the detectives) -> closings -> deliberation (every juror has their own reasonable-doubt bar;
	the room argues it out over ballots) -> the verdict, with the jury's reasons.

	ROLES - any of them can be a real player (Attorneys script): defence counsel (a player
	attorney the client hired), the prosecutor (an on-duty Deputy DA), the judge (an appointed
	judge), jurors (players summoned for jury duty). Missing roles are played by the NPCs.

	API
	  Trial.build(player, file, iv) -> board            (deterministic for the case)
	  Trial.reveal(player, file, iv, n, focus?) -> { lines }   (prep: learn n real/false weaknesses)
	  Trial.known(player, file, iv) -> number            (how many weaknesses the defence knows)
	  Trial.score(board) -> number                       (the State's case, 0.15 .. ~1.3)
	  Trial.run(E) -> { verdict, lesser, score, board, reasons, trialKind, sentencing }
	  Trial.sentence(E, R) -> secs                       (the sentencing hearing)
	Logs: [Trial]
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Trial = {}
Trial.VERSION = 291

local CFG = {
	Threshold = 0.6, -- the State's case a typical juror needs to convict (beyond a reasonable doubt)
	JurorSpread = 0.08, -- how much jurors differ
	RealHit = 0.4, -- a real weakness, hit: credibility x this
	FalseHit = 1.15, -- attacking a solid point: x this (it looks stronger)
	LineWeight = 0.04, -- an improper line the jury heard (not objected to)
	StruckBack = 0.05, -- a sustained objection: the jury's trust in that exhibit drops this much
	Impeach = 0.09, -- each contradiction in the defendant's testimony
	ObjectSeconds = 6, -- the window to hit OBJECT on a live line
	PayProsecutor = 2500, PayConviction = 2500, PayJudge = 3000, PayJuror = 500,
}
Trial.CFG = CFG
-- the interview record per defendant (PoliceSystem stores it when the interview ends): the whole
-- case uses it - the bail trial too, and a player attorney's investigation
Trial.ivs = {} :: { [number]: any }

---------------------------------------------------------------------------
-- the remote: the case board and live objections (CourtRoomClient)
---------------------------------------------------------------------------
local remote: RemoteEvent = (ReplicatedStorage:FindFirstChild("CourtRoom") :: RemoteEvent?) or (function()
	local r = Instance.new("RemoteEvent")
	r.Name = "CourtRoom"
	r.Parent = ReplicatedStorage
	return r
end)()
local pending: { [string]: { player: Player, answer: string?, done: boolean } } = {}
remote.OnServerEvent:Connect(function(p: Player, action: any, token: any, value: any)
	if action == "object" and type(token) == "string" then
		local w = pending[token]
		if w and w.player == p and not w.done then
			w.answer = if type(value) == "string" then value:sub(1, 40) else "?"
			w.done = true
		end
	end
end)

---------------------------------------------------------------------------
-- exhibits and their weaknesses
---------------------------------------------------------------------------
local TYPE = { dashcam = "video", bodycam = "video", cctv = "video", news = "video", witness = "eyewitness", owner = "eyewitness",
	caught = "arrest", prints = "forensic", statement = "statement", alpr = "alpr", report = "report" }

-- each weakness: key, attack (what the defence goes after), q (the question), rehab (the DA's answer
-- on redirect), real(F, x, rng) -> is it really there
local WEAK = {
	video = {
		{ key = "face", attack = "The footage never shows a face", q = "Pause it. Zoom in. Show us a face - any face.",
			rehab = "The clothing, the build and the car all match the defendant.", real = function(F, x, r) return F.night or r:NextNumber() < (if x.kind == "bodycam" then 0.15 else 0.45) end },
		{ key = "dark", attack = "It was dark - the picture is mush", q = "What time was this recorded? How many streetlights were working?",
			rehab = "The camera has a night mode. The enhancement is standard.", real = function(F) return F.night end },
		{ key = "gap", attack = "The video skips at the key moment", q = "Why does the timestamp jump four seconds right when it happens?",
			rehab = "Compression drops frames. Nothing is missing.", real = function(_, _, r) return r:NextNumber() < 0.25 end },
		{ key = "chain", attack = "Chain of custody - who handled the file?", q = "How many people copied this file before it reached this court?",
			rehab = "It went straight from the unit's recorder to evidence, logged and sealed.", real = function(F, _, r) return F.investigated or r:NextNumber() < 0.2 end },
	},
	eyewitness = {
		{ key = "dark", attack = "It was dark - how much could they see?", q = "How many streetlights were on? How far away were you?",
			rehab = "The witness was close enough to describe the defendant's clothes.", real = function(F) return F.night end },
		{ key = "glimpse", attack = "It was over in seconds", q = "How long did you actually see a face? Count it out loud for the jury.",
			rehab = "The witness saw them again as they ran past.", real = function(_, _, r) return r:NextNumber() < 0.55 end },
		{ key = "distance", attack = "They were too far away", q = "You were across the street - how many yards, exactly?",
			rehab = "The witness was close enough to read a licence plate.", real = function(_, _, r) return r:NextNumber() < 0.4 end },
		{ key = "bias", attack = "They have a reason to want a conviction", q = "You have your own reasons to see my client convicted, don't you?",
			rehab = "The witness had never met the defendant before that night.", real = function(_, x, r) return r:NextNumber() < (if x.kind == "owner" then 0.35 else 0.2) end },
		{ key = "changed", attack = "Their story has changed since the night", q = "That night you told police 'a guy in a hoodie'. Where did the face come from?",
			rehab = "The first statement was taken in shock. The witness has been consistent since.", real = function(_, _, r) return r:NextNumber() < 0.3 end },
	},
	arrest = {
		{ key = "lost", attack = "The officer lost sight of the suspect", q = "Officer, there were seconds you couldn't see the suspect at all - weren't there?",
			rehab = "The radio log shows continuous contact.", real = function(_, _, r) return r:NextNumber() < 0.15 end },
		{ key = "procedure", attack = "The arrest broke procedure", q = "Read the jury the part of the policy you followed. ...Go on.",
			rehab = "Every step is on the report and the body camera.", real = function(F, _, r) return F.violation or r:NextNumber() < 0.08 end },
		{ key = "others", attack = "Others matched the description nearby", q = "How many people in that block matched the description on the radio?",
			rehab = "Only one of them was standing over the scene.", real = function(_, _, r) return r:NextNumber() < 0.12 end },
	},
	forensic = {
		{ key = "when", attack = "Prints can't be dated", q = "Can you tell this jury WHEN that print was left? A day? A month?",
			rehab = "The surface was cleaned that morning - the owner will say so.", real = function(_, x, r) return string.find(x.text, "steering", 1, true) ~= nil or r:NextNumber() < 0.3 end },
		{ key = "lab", attack = "The lab mishandled the evidence", q = "Your lab lost a batch of evidence last spring. Who signed this one in?",
			rehab = "The lab is accredited; this sample was signed and sealed.", real = function(F, _, r) return F.investigated or r:NextNumber() < 0.18 end },
		{ key = "others", attack = "Other people's traces are on it too", q = "How many of the prints you lifted are NOT my client's?",
			rehab = "None of the other prints are on the parts that matter.", real = function(_, _, r) return r:NextNumber() < 0.45 end },
	},
	statement = {
		{ key = "nolawyer", attack = "They kept going after the lawyer was asked for", q = "Detective, how long after my client asked for a lawyer did you keep asking questions?",
			rehab = "The defendant waived their rights on tape.", real = function(F) return F.violation end },
		{ key = "pressure", attack = "Hours of pressure - a false confession", q = "How many hours had my client been in that room when this was recorded?",
			rehab = "The interview was short and the defendant was offered water and breaks.", real = function(F, _, r) return F.lied or r:NextNumber() < 0.25 end },
		{ key = "promise", attack = "The detective promised a deal", q = "Did you tell my client it would 'go easier' if they talked?",
			rehab = "No promises were made. The recording shows it.", real = function(F) return F.deal end },
	},
	alpr = {
		{ key = "driver", attack = "A plate reader logs a car, not a driver", q = "Does your camera show who was driving? At all?",
			rehab = "The defendant was the registered driver that night.", real = function() return true end },
		{ key = "misread", attack = "Plate readers misread plates", q = "What is this reader's error rate on a moving car at night?",
			rehab = "The read was confirmed by hand.", real = function(_, _, r) return r:NextNumber() < 0.3 end },
	},
	report = {
		{ key = "late", attack = "The report was written hours later", q = "You wrote this three hours after the arrest. From memory?",
			rehab = "Notes were taken on scene.", real = function(_, _, r) return r:NextNumber() < 0.5 end },
		{ key = "copy", attack = "It's copied from another report", q = "Why is the wording identical to your report from last week?",
			rehab = "It's standard language.", real = function(_, _, r) return r:NextNumber() < 0.2 end },
	},
}
local TITLE = {
	video = "Video", eyewitness = "Eyewitness", arrest = "Arresting officer", forensic = "Forensics", statement = "Your statement",
	alpr = "Plate reader", report = "Police report",
}

-- improper lines in direct examination: the ground that makes them objectionable
local GROUNDS = { "Hearsay", "Leading the witness", "Speculation", "Improper character evidence", "Relevance" }
Trial.GROUNDS = GROUNDS
local BAD_LINES = {
	Hearsay = { "A: \"My neighbour told me the defendant did it.\"", "A: \"Another officer said they'd seen him there before.\"", "A: \"The victim told her sister she was afraid of him.\"" },
	["Leading the witness"] = { "Q: You saw the defendant do it, didn't you?", "Q: And it was the defendant who ran, correct?", "Q: That was obviously the defendant's car, wasn't it?" },
	Speculation = { "A: \"He must have been planning it for weeks.\"", "A: \"I guess he wanted the money.\"", "A: \"He probably went back for the gun.\"" },
	["Improper character evidence"] = { "A: \"Everyone around there knows he's been arrested before.\"", "A: \"He's a known gang member.\"", "A: \"People like that do this kind of thing.\"" },
}

local function seedOf(player: Player, file: any?): number
	local e = file and file.entries and file.entries[1]
	local s = (tonumber(e and e.os) or 0) + player.UserId % 100000
	return s
end

local function factsOf(file: any?, iv: any?, mods: any?): any
	local L = game:GetService("Lighting")
	local top = nil
	for _, e in (file and file.entries or {}) do
		if e.charge and (not top or (e.evidence and #e.evidence > #(top.evidence or {}))) then top = e end
	end
	local at = tostring(top and top.at or "")
	local hour = tonumber(string.match(at, "^(%d+):")) or math.floor(L.ClockTime)
	local pm = string.find(at, "PM", 1, true) ~= nil
	if pm and hour < 12 then hour += 12 end
	if string.find(at, "AM", 1, true) and hour == 12 then hour = 0 end
	return {
		night = hour >= 20 or hour < 6,
		violation = iv ~= nil and iv.violation ~= nil,
		lied = iv ~= nil and (tonumber(iv.falseStatements) or 0) > 0,
		deal = iv ~= nil and iv.secsScale ~= nil and iv.secsScale < 1,
		investigated = mods ~= nil and tonumber(mods.evidence) ~= nil and mods.evidence < 0,
	}
end

-- the board for this case (same every time it's built: the seed is the case)
function Trial.build(player: Player, file: any?, iv: any?, mods: any?): any
	local rng = Random.new(seedOf(player, file))
	local F = factsOf(file, iv, mods)
	local items = {}
	local brief = file and file.brief
	for _, x in (brief and brief.evidence or {}) do table.insert(items, x) end
	for _, e in (file and file.entries or {}) do
		if e.key == "ALPR" then table.insert(items, { kind = "alpr", weight = 0.05, text = ("a plate reader logged %s near %s"):format(e.car or "the car", e.place or "the city") }) end
	end
	if iv and iv.confessed then table.insert(items, { kind = "statement", weight = 0.3, text = "the recording of your interview" }) end
	if #items == 0 then table.insert(items, { kind = "report", weight = 0.12, text = (if file then tostring(file.officer) else "the arresting officer") .. "'s report" }) end
	local board = { exhibits = {}, extra = 0, counts = 0, lines = {}, impeach = 0, seed = seedOf(player, file), facts = F }
	-- other counts with their own evidence make the pattern harder to explain away
	for _, e in (file and file.entries or {}) do
		if e.charge and e.evidence and #e.evidence > 0 then board.counts += 1 end
		if e.key == "ALPR" or e.key == "Identified" then board.extra += 0.03 end
	end
	board.counts = math.max(0, board.counts - 1)
	for i, x in items do
		local t = TYPE[x.kind] or "report"
		local pool = table.clone(WEAK[t] or WEAK.report)
		-- three of them, the fact-driven ones first
		for k = #pool, 2, -1 do
			local j = rng:NextInteger(1, k)
			pool[k], pool[j] = pool[j], pool[k]
		end
		local weak = {}
		for k = 1, math.min(3, #pool) do
			local w = pool[k]
			table.insert(weak, { key = w.key, attack = w.attack, q = w.q, rehab = w.rehab, real = w.real(F, x, rng) == true, used = false })
		end
		table.insert(board.exhibits, {
			id = ("%s%d"):format(t, i), kind = x.kind, type = t, text = x.text, playerId = x.playerId,
			title = ("%s: %s"):format(TITLE[t] or "Exhibit", x.text),
			weight = tonumber(x.weight) or 0.1, cred = 1, status = "pending", weak = weak, notes = {},
		})
	end
	table.sort(board.exhibits, function(a, b) return a.weight > b.weight end)
	return board
end

function Trial.value(x: any): number
	if x.status == "excluded" then return 0 end
	return x.weight * x.cred
end

-- the State's case: the base, every exhibit as it now stands, the pattern, impeachment
function Trial.score(board: any): number
	local s = 0.15 + math.min(board.extra, 0.1) + math.min(0.06 * board.counts, 0.24) + board.impeach
	for _, x in board.exhibits do s += Trial.value(x) end
	for _, l in board.lines do s += l end
	return s
end

---------------------------------------------------------------------------
-- what the defence knows (prep: the lawyer meeting, the mock trial, investigation)
---------------------------------------------------------------------------
local intel: { [number]: { seed: number, known: { [string]: boolean } } } = {}
local function knowTable(player: Player, board: any): { [string]: boolean }
	local k = intel[player.UserId]
	if not k or k.seed ~= board.seed then
		k = { seed = board.seed, known = {} }
		intel[player.UserId] = k
	end
	return k.known
end
Trial.knowTable = knowTable

-- learn about n weaknesses (the strongest exhibits first, or `focus` = an exhibit id) -> lines saying what was found
function Trial.reveal(player: Player, file: any?, iv: any?, n: number, focus: string?, mods: any?): { string }
	local board = Trial.build(player, file, iv, mods)
	local known = knowTable(player, board)
	local out = {}
	for _, x in board.exhibits do
		if not focus or x.id == focus then
			for _, w in x.weak do
				local key = x.id .. ":" .. w.key
				if n <= 0 then break end
				if known[key] == nil then
					known[key] = w.real
					n -= 1
					table.insert(out, ("%s - %s: %s"):format(x.text, string.lower(w.attack), if w.real then "REAL. We can use it." else "solid. Don't go there."))
				end
			end
		end
	end
	if #out == 0 then table.insert(out, "Nothing new - we already know everything we can about their evidence.") end
	return out
end

function Trial.known(player: Player, file: any?, iv: any?): (number, number)
	local board = Trial.build(player, file, iv)
	local known = knowTable(player, board)
	local n, total = 0, 0
	for _, x in board.exhibits do
		for _, w in x.weak do
			total += 1
			if known[x.id .. ":" .. w.key] ~= nil then n += 1 end
		end
	end
	return n, total
end

---------------------------------------------------------------------------
-- the board on screen (CourtRoomClient): the defendant, counsel, the DA and the judge see the
-- running total; jurors see the exhibits but not the meter
---------------------------------------------------------------------------
local function boardPayload(board: any, E: any, showMeter: boolean, known: { [string]: boolean }?): any
	local ex = {}
	for _, x in board.exhibits do
		local w = {}
		for _, k in x.weak do
			local kv = known and known[x.id .. ":" .. k.key]
			table.insert(w, { attack = k.attack, used = k.used, known = if kv == nil then nil else kv })
		end
		table.insert(ex, { id = x.id, title = x.title, status = x.status, value = Trial.value(x), weight = x.weight, cred = x.cred, notes = x.notes, weak = w })
	end
	return {
		case = E.caseName, phase = E.phase, exhibits = ex,
		score = if showMeter then Trial.score(board) else nil, threshold = if showMeter then CFG.Threshold else nil,
		impeach = board.impeach,
	}
end
local function push(E: any)
	local board = E.board
	for p, role in E.watchers do
		if p.Parent then
			local defence = role == "defendant" or role == "defence"
			remote:FireClient(p, "board", boardPayload(board, E, role ~= "juror", if defence then E.known else nil))
		end
	end
end
Trial.push = push
local function closeBoards(E: any)
	for p in E.watchers do
		if p.Parent then remote:FireClient(p, "clear") end
	end
end

-- a live objection window on `p`'s screen -> the ground they picked, or nil
local function objectWindow(p: Player?, speaker: string, line: string, secs: number): string?
	if not (p and p.Parent) then return nil end
	local token = HttpService:GenerateGUID(false)
	local w = { player = p, answer = nil, done = false }
	pending[token] = w
	remote:FireClient(p, "object", { token = token, speaker = speaker, line = line, secs = secs, grounds = GROUNDS })
	local t0 = os.clock()
	while not w.done and os.clock() - t0 < secs + 0.4 and p.Parent do task.wait(0.1) end
	pending[token] = nil
	if not w.done then remote:FireClient(p, "closeObject", token) end
	return w.answer
end
Trial.objectWindow = objectWindow

---------------------------------------------------------------------------
-- roles
---------------------------------------------------------------------------
local function attorneys(action: string, ...: any): any
	local f = ServerStorage:FindFirstChild("Attorneys")
	if f and f:IsA("BindableFunction") then
		local ok, r = pcall(f.Invoke, f, action, ...)
		if ok then return r end
		warn("[Trial] Attorneys." .. action .. ": " .. tostring(r))
	end
	return nil
end
Trial.attorneys = attorneys
local function pay(p: Player?, amount: number, why: string)
	if not (p and p.Parent) or amount <= 0 then return end
	local eco = ServerStorage:FindFirstChild("Economy")
	if eco and eco:IsA("BindableFunction") then pcall(eco.Invoke, eco, "AddBank", p, amount) end
	attorneys("notice", p, ("$%d paid - %s"):format(amount, why))
	print(("[Trial] PAY %s $%d (%s)"):format(p.Name, amount, why))
end
Trial.pay = pay

-- who decides for the defence: the player attorney when there is one, else the defendant
local function defenceSeat(E: any): Player
	return if E.roles.defence and E.roles.defence.Parent then E.roles.defence else E.player
end
local function counselLabel(E: any): string
	if E.roles.defence and E.roles.defence.Parent then
		return tostring(E.roles.defence:GetAttribute("CharacterName") or E.roles.defence.DisplayName) .. " (defence counsel)"
	end
	return E.counsel
end
local function prosLabel(E: any): string
	if E.roles.prosecutor and E.roles.prosecutor.Parent then
		return tostring(E.roles.prosecutor:GetAttribute("CharacterName") or E.roles.prosecutor.DisplayName) .. " (for the State)"
	end
	return E.prosecutor .. " (for the State)"
end
local function judgeLabel(E: any): string
	if E.roles.judge and E.roles.judge.Parent then
		return "Judge " .. tostring(E.roles.judge:GetAttribute("CharacterName") or E.roles.judge.DisplayName)
	end
	return E.judge.name
end
Trial.judgeLabel = judgeLabel
Trial.prosLabel = prosLabel
Trial.counselLabel = counselLabel

-- something said in the room: the transcript for the public, the log on the case board for
-- everyone in the case (cards are only for decisions - one card at a time per player), and time
-- to read it
local function announce(E: any, from: string, lines: { string })
	E.feed(from, lines)
	for p in E.watchers do
		if p.Parent then remote:FireClient(p, "line", { from = from, lines = lines }) end
	end
	task.wait(math.clamp(#table.concat(lines, " ") / 16, 2.5, 10))
end
Trial.announce = announce

-- how well the NPC side does what a person would choose: counsel's skill (0..1)
local function npcSkill(E: any): number
	if E.elite then return 0.95 end
	return math.clamp(0.25 + 0.09 * E.tier + (if E.prepared then 0.08 else 0), 0.2, 0.9)
end

-- the judge rules on an objection / a motion. A player judge decides (with the rule in front of
-- them); the NPC judge knows the law, mostly.
local function rule(E: any, what: string, lines: { string }, correct: boolean): boolean
	local j = E.roles.judge
	if j and j.Parent then
		local i = E.card(j, ("You are the judge - %s"):format(what), lines, { "Sustained / Granted", "Overruled / Denied" }, 2) or 2
		return i == 1
	end
	return if correct then math.random() < 0.88 else math.random() < 0.06
end

---------------------------------------------------------------------------
-- MOTIONS before the jury hears anything
---------------------------------------------------------------------------
local function motions(E: any)
	local board = E.board
	local opts, acts = {}, {}
	local stmt, chain = nil, nil
	for _, x in board.exhibits do
		if x.type == "statement" then stmt = x end
		for _, w in x.weak do
			if w.key == "chain" and not chain and x.status ~= "excluded" then chain = { x = x, w = w } end
		end
	end
	local known = E.known
	local function hint(x: any, key: string): string
		local kv = known[x.id .. ":" .. key]
		return if kv == true then " (your investigation backs it)" elseif kv == false then " (your investigation says it won't fly)" else ""
	end
	if stmt then
		table.insert(opts, "Move to suppress your statement - questioned after asking for a lawyer" .. hint(stmt, "nolawyer"))
		table.insert(acts, function()
			local real = false
			for _, w in stmt.weak do if w.key == "nolawyer" then real = w.real end end
			local granted = rule(E, "motion to suppress", { "The defence says the detectives kept questioning after the defendant asked for a lawyer.",
				"The rule: if the defendant asked for a lawyer and questioning went on, the statement is out.",
				if real then "The interview recording shows the request for a lawyer, and the questions after it." else "The recording shows no request for a lawyer." }, real)
			if granted then stmt.status = "excluded"; table.insert(stmt.notes, "SUPPRESSED") end
			return granted, stmt.title
		end)
	end
	if chain then
		table.insert(opts, ("Move to exclude %s - broken chain of custody%s"):format(chain.x.text, hint(chain.x, "chain")))
		table.insert(acts, function()
			local granted = rule(E, "motion to exclude", { ("The defence says nobody can account for %s between the scene and this court."):format(chain.x.text),
				"The rule: evidence whose handling can't be accounted for is excluded.",
				if chain.w.real then "The evidence log has a gap: two transfers nobody signed." else "The evidence log is complete and signed." }, chain.w.real)
			if granted then chain.x.status = "excluded"; table.insert(chain.x.notes, "EXCLUDED") end
			chain.w.used = true
			return granted, chain.x.title
		end)
	end
	local thin = Trial.score(board) < 0.42
	table.insert(opts, "Move to dismiss - not enough evidence to go to a jury")
	table.insert(acts, function()
		local granted = rule(E, "motion to dismiss", { "The defence says the State's evidence couldn't convince a reasonable jury even if it's all believed.",
			("The State's case as it stands: %d%% of what a conviction needs."):format(math.floor(Trial.score(board) / CFG.Threshold * 100)),
			"The rule: dismiss only if NO reasonable jury could convict." }, thin)
		if granted then E.dismissed = true end
		return granted, "the case"
	end)
	table.insert(opts, "No motions - straight to trial")
	table.insert(acts, function() return nil, nil end)
	local who = defenceSeat(E)
	local advice = {}
	if not (E.roles.defence and E.roles.defence.Parent) then
		-- the firm's advice
		if stmt then table.insert(advice, if known[stmt.id .. ":nolawyer"] == true then "\"They kept questioning you after you asked for me. We file to suppress.\"" else "\"Your statement is their best evidence. We can try to suppress it - if they crossed a line.\"") end
		if thin then table.insert(advice, "\"Honestly, their case is thin. A motion to dismiss has a real chance.\"") end
	end
	local filed = 0
	for _ = 1, 2 do
		if E.dismissed or not E.alive() then return end
		local lines = { "\"Before the jury comes in - any motions?\"" }
		for _, a in advice do table.insert(lines, a) end
		local i = E.card(who, counselLabel(E) .. " - pretrial motions", lines, opts, #opts) or #opts
		if i == #opts then break end
		local f = acts[i]
		table.remove(opts, i)
		table.remove(acts, i)
		filed += 1
		E.sidebar()
		local granted, what = f()
		E.feed(judgeLabel(E), { if granted then ("Motion GRANTED: %s."):format(what) else "Motion DENIED." })
		announce(E, judgeLabel(E), { if granted then ("The motion is granted - %s."):format(if E.dismissed then "the case is dismissed" else what .. " will not be shown to the jury") else "The motion is denied." })
		print(("[Trial] MOTION %s: %s -> %s"):format(E.player.Name, tostring(what), tostring(granted)))
		push(E)
	end
	if filed > 0 then E.bill("motions", 0.4 * filed) end
end

---------------------------------------------------------------------------
-- THE STATE'S CASE: each exhibit - direct (live objections), cross, redirect
---------------------------------------------------------------------------
local function directExam(E: any, x: any, witnessName: string)
	-- three lines; the State's lawyer sometimes crosses the line
	local rng = Random.new(E.board.seed + #x.id * 31 + math.floor(x.weight * 1000))
	local clean = {
		("Q: Tell the jury what you saw."):format(),
		("A: \"%s\""):format(E.asWitness(x)),
		("Q: And what did you do next?"):format(),
		("A: \"I made sure it was documented - %s.\""):format(x.text),
	}
	local lines = { clean[1], clean[2] }
	local bad = nil
	local badChance = if E.roles.prosecutor and E.roles.prosecutor.Parent then 0.35 else 0.55
	if rng:NextNumber() < badChance then
		local ground = GROUNDS[rng:NextInteger(1, 4)]
		local list = BAD_LINES[ground]
		bad = { ground = ground, text = list[rng:NextInteger(1, #list)] }
		table.insert(lines, bad.text)
	else
		table.insert(lines, clean[4])
	end
	-- a player prosecutor picks their own last question (and can choose the improper one)
	local pp = E.roles.prosecutor
	if pp and pp.Parent then
		local opts = { "Ask it straight: \"What did you do next?\"", "Lead them: \"You saw the defendant do it, didn't you?\"", "Ask what people say about the defendant" }
		local i = E.card(pp, prosLabel(E) .. " - direct examination of " .. witnessName, { lines[1], lines[2], "Your next question:" }, opts, 1) or 1
		if i == 1 then lines[3], bad = clean[4], nil
		elseif i == 2 then bad = { ground = "Leading the witness", text = "Q: You saw the defendant do it, didn't you?" }; lines[3] = bad.text
		else bad = { ground = "Improper character evidence", text = "A: \"Everyone around there knows he's been arrested before.\"" }; lines[3] = bad.text end
	end
	-- the lines go out one by one; the defence can object to each
	local objector = defenceSeat(E)
	local objected = false
	for idx, l in lines do
		if not E.alive() then return end
		E.feed(if string.sub(l, 1, 2) == "Q:" then prosLabel(E) else witnessName, { l })
		E.say(if string.sub(l, 1, 2) == "Q:" then "pros" else "witness", string.sub(l, 4))
		local isBad = bad ~= nil and l == bad.text
		local ground = nil
		if idx >= 2 and not objected then
			ground = objectWindow(objector, if string.sub(l, 1, 2) == "Q:" then prosLabel(E) else witnessName, l, CFG.ObjectSeconds)
			-- an NPC lawyer at the table objects on their own when the client didn't
			if not ground and not (E.roles.defence and E.roles.defence.Parent) and isBad and math.random() < npcSkill(E) * 0.7 then
				ground = bad.ground
				E.tell(E.counsel .. " is on their feet")
			end
		else
			task.wait(1.6)
		end
		if ground then
			objected = true
			E.feed(counselLabel(E), { ("Objection, Your Honor - %s."):format(string.lower(ground)) })
			E.say("def", "Objection!")
			local right = isBad and ground == bad.ground
			local sustained = rule(E, "objection", { ("The line: %s"):format(l), ("The objection: %s."):format(ground),
				"Hearsay = repeating what someone else said. Leading = a question that puts the answer in the witness's mouth. Speculation = guessing. Character = 'he's that kind of person'." }, right)
			if sustained then
				announce(E, judgeLabel(E), { "Sustained. The jury will disregard that." })
				if isBad then bad = nil end
				x.cred = math.max(0.2, x.cred - CFG.StruckBack)
				table.insert(x.notes, "objection sustained")
			else
				announce(E, judgeLabel(E), { "Overruled." })
				E.patience -= 1
				if E.patience <= 0 then
					announce(E, judgeLabel(E), { "\"Counsel, one more frivolous objection and I'll hold you in contempt.\"" })
					table.insert(E.board.lines, 0.02)
				end
			end
			push(E)
		end
	end
	-- an improper line nobody objected to: the jury heard it
	if bad then
		table.insert(E.board.lines, CFG.LineWeight)
		table.insert(x.notes, "the jury heard " .. string.lower(bad.ground))
	end
end

local function crossExam(E: any, x: any, witnessName: string)
	local who = defenceSeat(E)
	local known = E.known
	local opts, map = {}, {}
	for _, w in x.weak do
		if not w.used then
			local kv = known[x.id .. ":" .. w.key]
			local tag = if kv == true then "  [investigated: real]" elseif kv == false then "  [investigated: solid]" else ""
			table.insert(opts, w.attack .. tag)
			table.insert(map, w)
		end
	end
	table.insert(opts, "No questions")
	-- the firm's hunch when the client is choosing (better firms know more)
	local lines = { ("\"Your witness. What do we go after with %s?\""):format(witnessName) }
	if not (E.roles.defence and E.roles.defence.Parent) then
		local best = nil
		for _, w in map do
			if known[x.id .. ":" .. w.key] == true then best = w break end
		end
		if not best and math.random() < npcSkill(E) * 0.6 then
			for _, w in map do if w.real then best = w break end end
		end
		if best then table.insert(lines, ("%s whispers: \"%s. Trust me.\""):format(E.counsel, best.attack)) end
	end
	local i = E.card(who, counselLabel(E) .. " - cross-examination", lines, opts, #opts) or #opts
	local w = map[i]
	if not w then return end
	w.used = true
	-- the theory decides whether this attack even fits the story the jury was told
	local fits = not (E.theory == 3 and (w.key == "face" or w.key == "glimpse" or w.key == "distance" or w.key == "others" or w.key == "dark"))
	E.feed(counselLabel(E), { "Q: " .. w.q })
	E.say("def", w.q)
	task.wait(1.5)
	if w.real and fits then
		-- the identity story makes an attack on who-did-it count for more
		x.cred *= if w.identity then CFG.RealHit * 0.7 else CFG.RealHit
		table.insert(x.notes, "broken on cross: " .. string.lower(w.attack))
		announce(E, witnessName, { "Q: " .. w.q, ("%s hesitates... and can't answer it."):format(witnessName) })
		known[x.id .. ":" .. w.key] = true
	elseif w.real then
		x.cred *= 0.8
		table.insert(x.notes, "a hit - but it doesn't fit your story")
		announce(E, witnessName, { "Q: " .. w.q, ("%s falters. But the jury frowns: didn't the defence say you were there?"):format(witnessName) })
	else
		x.cred = math.min(1.35, x.cred * CFG.FalseHit)
		table.insert(x.notes, "held up on cross")
		announce(E, witnessName, { "Q: " .. w.q, ("%s answers it calmly. That made the State's case look stronger."):format(witnessName) })
		known[x.id .. ":" .. w.key] = false
	end
	push(E)
	-- redirect: the State tries to repair the damage
	if w.real and fits then
		local pp = E.roles.prosecutor
		local fixed = false
		if pp and pp.Parent then
			local others = {}
			for _, ow in x.weak do if ow ~= w then table.insert(others, ow.rehab) end end
			local ropts = { w.rehab }
			for _, r in others do table.insert(ropts, r) end
			-- shuffle so the right answer isn't always first
			for k = #ropts, 2, -1 do local j = math.random(1, k); ropts[k], ropts[j] = ropts[j], ropts[k] end
			table.insert(ropts, "No redirect")
			local r = E.card(pp, prosLabel(E) .. " - redirect", { ("The defence hit your witness on: %s."):format(string.lower(w.attack)), "How do you repair it?" }, ropts, #ropts) or #ropts
			fixed = ropts[r] == w.rehab
			if ropts[r] ~= "No redirect" then E.feed(prosLabel(E), { "Redirect: " .. ropts[r] }) end
		else
			fixed = math.random() < 0.35
			if fixed then E.feed(prosLabel(E), { "Redirect: " .. w.rehab }) end
		end
		if fixed then
			x.cred = math.min(1, x.cred / CFG.RealHit * 0.7)
			table.insert(x.notes, "partly repaired on redirect")
			announce(E, prosLabel(E), { "Redirect: " .. w.rehab, "Some of the damage is repaired." })
			push(E)
		end
	end
end

local function stateCase(E: any)
	local board = E.board
	E.phase = "The State's case"
	push(E)
	for _, x in board.exhibits do
		if not E.alive() or E.dismissed then return end
		if x.status == "excluded" then continue end
		x.status = "admitted"
		push(E)
		-- a real player who saw it testifies in person (CityLife witness) - their answers move it
		if x.playerId and E.playerWitness then
			local ok, d = pcall(E.playerWitness, x)
			if ok and type(d) == "number" then
				x.cred = math.clamp(x.cred + d / math.max(0.05, x.weight), 0.1, 1.4)
				table.insert(x.notes, "a real witness testified")
			end
			push(E)
			continue
		end
		local witnessName, model = E.callFor(x)
		E.tell(("The State presents: %s"):format(x.title))
		directExam(E, x, witnessName)
		if not E.alive() then return end
		crossExam(E, x, witnessName)
		E.stepDown(model)
		task.wait(0.6)
	end
	announce(E, prosLabel(E), { "The State rests, Your Honor." })
end

---------------------------------------------------------------------------
-- THE DEFENCE CASE
---------------------------------------------------------------------------
local function defendantTestifies(E: any)
	local p = E.player
	local F = E.facts
	E.tell("You walk to the witness stand and take the oath")
	E.sitIn("WitnessSeat")
	local said = E.choices("testimony", E.F)
	local i = E.card(p, counselLabel(E) .. " - your testimony", { ("Q: Where were you at %s?"):format(E.F.at or "the time") },
		{ said[1].text, said[2].text, said[3].text, said[4].text }, 4) or 4
	local story = said[i].story
	E.feed(E.who, { said[i].text })
	-- the State's cross: every contradiction they can prove
	local contra = {}
	if story == "away" and (E.F.caught or E.F.identified) then table.insert(contra, if E.F.caught then "the officer who arrested you there" else "the witness who picked you out") end
	if story == "away" and E.iv and E.iv.confessed then table.insert(contra, "your own recorded statement saying you did it") end
	if story ~= "silent" and E.theory == 2 and story ~= "away" then table.insert(contra, "your lawyer's opening - 'my client wasn't there'") end
	if story == "away" and E.theory == 3 then table.insert(contra, "your lawyer's opening - 'something happened, but not what they say'") end
	if F.lied and story ~= "silent" then table.insert(contra, "the lies you told the detectives") end
	local pp = E.roles.prosecutor
	local hits = #contra
	if pp and pp.Parent and #contra > 0 then
		-- a player DA has to actually catch them
		local opts = table.clone(contra)
		table.insert(opts, "Ask about their character instead")
		local c = E.card(pp, prosLabel(E) .. " - cross-examining the defendant", { ("They said: %s"):format(said[i].text), "Which contradiction do you confront them with?" }, opts, #opts) or #opts
		hits = if c <= #contra then 1 + (if #contra > 1 and math.random() < 0.5 then 1 else 0) else 0
	end
	if E.rehearsed then hits = math.floor(hits / 2 + 0.5) end
	if hits > 0 then
		local shown = {}
		for k = 1, math.min(hits, #contra) do table.insert(shown, "They confront you with " .. contra[k] .. ".") end
		E.board.impeach += CFG.Impeach * hits
		announce(E, prosLabel(E), shown)
		local reply = E.card(p, prosLabel(E) .. " - cross-examination", { "Q: Then explain that.", "(Every eye in the room is on you.)" }, {
			"\"I made a mistake. I was scared.\"", "\"They're lying.\"", "\"I don't remember.\"", "[Say nothing]" }, 4) or 4
		if reply == 1 and story ~= "away" then E.board.impeach -= 0.03 end
		if reply == 2 then E.board.impeach += 0.03 end
	elseif story == "there" and E.theory == 3 then
		-- a consistent, plausible account: real doubt
		E.board.impeach -= 0.06
		announce(E, prosLabel(E), { "The prosecutor can't shake your account. \"...Nothing further.\"" })
	elseif story == "sorry" then
		E.sentencing.remorse = true
		announce(E, prosLabel(E), { "\"So you admit it.\"", "The jury watches you closely." })
		E.board.impeach += 0.05
	end
	E.testified = { story = story, hits = hits }
	print(("[Trial] TESTIMONY %s: story=%s contradictions=%d (rehearsed=%s)"):format(p.Name, story, hits, tostring(E.rehearsed)))
	push(E)
	E.sitIn("DefendantSeat")
end

local function defenceCase(E: any)
	E.phase = "The defence case"
	push(E)
	local board = E.board
	local who = defenceSeat(E)
	-- what's on the table: an expert aimed at one exhibit, an alibi, a character witness, the defendant
	local acts = {}
	local opts = {}
	local alibiReal = E.facts.investigated or (not E.F.caught and not E.F.identified and Random.new(board.seed + 7):NextNumber() < 0.3)
	local targets = {}
	for _, x in board.exhibits do
		if x.status ~= "excluded" and (x.type == "video" or x.type == "forensic" or x.type == "eyewitness" or x.type == "statement") then table.insert(targets, x) end
	end
	if #targets > 0 then
		table.insert(opts, "Call an expert witness against one of their exhibits")
		table.insert(acts, "expert")
	end
	table.insert(opts, if alibiReal then "Call your alibi witness (your investigator found one)" else "Call a friend who'll say you were with them (it isn't true)")
	table.insert(acts, "alibi")
	table.insert(opts, "Call a character witness (helps at sentencing, not the verdict)")
	table.insert(acts, "character")
	table.insert(opts, "Put the defendant on the stand")
	table.insert(acts, "testify")
	table.insert(opts, "Rest - the State hasn't proved it")
	table.insert(acts, "rest")
	local used = {}
	for _ = 1, 3 do
		if not E.alive() then return end
		local o, a = {}, {}
		for k, t in opts do if not used[acts[k]] then table.insert(o, t); table.insert(a, acts[k]) end end
		local lines = { "\"Our case. What do we put on?\"",
			("The State's case right now: %d%% of what a conviction needs."):format(math.floor(Trial.score(board) / CFG.Threshold * 100)) }
		local i = E.card(who, counselLabel(E) .. " - the defence case", lines, o, #o) or #o
		local act = a[i]
		if act == "rest" then break end
		used[act] = true
		if act == "testify" then
			-- it's the defendant's own decision to testify
			if who ~= E.player then
				local yes = E.card(E.player, counselLabel(E), { "\"I want to put you on the stand. It's your right - and your risk. Will you testify?\"" }, { "Yes, I'll testify", "No" }, 2)
				if yes ~= 1 then continue end
			end
			defendantTestifies(E)
		elseif act == "expert" then
			local tl = {}
			for _, x in targets do table.insert(tl, x.title) end
			local t = E.card(who, counselLabel(E) .. " - expert witness", { "\"Which of their exhibits does our expert take apart?\"" }, tl, 1) or 1
			local x = targets[t]
			local anyReal = false
			for _, w in x.weak do if w.real then anyReal = true end end
			local m = E.callNamed(({ video = "A forensic video analyst", forensic = "An independent crime-lab examiner", eyewitness = "An eyewitness-memory expert", statement = "A false-confession researcher" })[x.type] or "An expert witness", "witness")
			if anyReal then
				x.cred *= 0.7
				table.insert(x.notes, "undermined by the defence expert")
				announce(E, counselLabel(E) .. " - direct", { ("The expert walks the jury through what's wrong with %s."):format(x.text), "Two jurors write something down." })
			else
				x.cred = math.min(1.35, x.cred * 1.08)
				table.insert(x.notes, "the defence expert couldn't fault it")
				announce(E, prosLabel(E) .. " - cross", { "Q: You couldn't find a single real flaw, could you?", "A: \"...No.\"" })
			end
			E.bill("motions", 0.5)
			E.stepDown(m)
			push(E)
		elseif act == "alibi" then
			local m = E.callNamed(if alibiReal then "Alibi witness" else "A friend of the defendant", "witness")
			if alibiReal then
				board.impeach -= 0.12
				announce(E, counselLabel(E) .. " - direct", { "\"The defendant was with me the whole evening. We have the receipts.\"", "The prosecutor's cross doesn't move them." })
			elseif math.random() < 0.75 then
				board.impeach += 0.15
				E.sentencing.perjury = true
				announce(E, prosLabel(E) .. " - cross", { "Q: Then why does your phone put you across town that night?", "The witness goes pale. The judge warns about perjury." })
			else
				board.impeach -= 0.05
				announce(E, counselLabel(E) .. " - direct", { "\"They were with me all night.\"", "The State can't disprove it." })
			end
			E.stepDown(m)
			push(E)
		elseif act == "character" then
			local m = E.callNamed(E.familyName or "A family friend", "family")
			E.sentencing.character = true
			announce(E, counselLabel(E) .. " - direct", { "Q: Who is the defendant, really?", ("A: \"Someone who didn't get many chances. %s isn't what they're saying.\""):format(E.who) })
			E.stepDown(m)
		end
	end
	announce(E, counselLabel(E), { "\"The defence rests, Your Honor.\"" })
end

---------------------------------------------------------------------------
-- DELIBERATION
---------------------------------------------------------------------------
-- -> "guilty" | "lesser" | "not guilty" | "hung", the final vote, the jury's reasons
local function deliberate(E: any, jurorPlayers: { Player }): (string, number, { string })
	local S = Trial.score(E.board)
	local n = 12
	local votes, bars = {}, {}
	for i = 1, n do
		local j = E.panel[i]
		local bar = CFG.Threshold + (math.random() - 0.5) * 2 * CFG.JurorSpread + (E.jurorBias[i] or 0) + (E.closingDelta or 0)
		bars[i] = bar
		if j and j.vote == "ng" then votes[i] = "x" -- reached: not guilty, and stays there
		elseif S > bar + 0.15 then votes[i] = "g"
		elseif S > bar then votes[i] = if E.theory == 3 then "l" else "g"
		else votes[i] = "n" end
	end
	-- real players on the jury vote for themselves
	local function playerVotes(round: number)
		local done = 0
		for k, p in jurorPlayers do
			task.spawn(function()
				local lines = { ("Ballot %d. The evidence as it stands:"):format(round) }
				for _, x in E.board.exhibits do
					table.insert(lines, ("- %s%s"):format(x.text, if x.status == "excluded" then " (excluded - ignore it)" elseif #x.notes > 0 then " (" .. x.notes[#x.notes] .. ")" else ""))
				end
				table.insert(lines, "Guilty only if you're sure beyond a reasonable doubt.")
				local opts = { "Guilty", "Not guilty" }
				if E.theory == 3 then table.insert(opts, 2, "Guilty of the lesser charge only") end
				local i = E.card(p, ("Jury room - you are Juror #%d"):format(k), lines, opts, #opts) or #opts
				votes[k] = if i == 1 then "g" elseif opts[i] == "Not guilty" then "n" else "l"
				done += 1
			end)
		end
		local t0 = os.clock()
		while done < #jurorPlayers and os.clock() - t0 < 80 do task.wait(0.5) end
	end
	local function tally(): (number, number, number)
		local g, l, x = 0, 0, 0
		for i = 1, n do
			if votes[i] == "g" then g += 1 elseif votes[i] == "l" then l += 1 elseif votes[i] == "n" or votes[i] == "x" then x += 1 end
		end
		return g, l, x
	end
	local g, l, x = 0, 0, 0
	for round = 1, 4 do
		if #jurorPlayers > 0 then playerVotes(round) end
		g, l, x = tally()
		print(("[Trial] BALLOT %s #%d: guilty %d, lesser %d, not guilty %d (case %.2f)"):format(E.player.Name, round, g, l, x, S))
		E.tell(("The jury is still out - ballot %d"):format(round))
		if g == n or x == n or l == n or (g + l == n and l > 0) then break end
		-- the room argues it out: the ones whose bar sits close to the evidence move toward the majority
		for i = #jurorPlayers + 1, n do
			local v = votes[i]
			if v == "x" then continue end
			local margin = math.abs(S - bars[i])
			local p = math.clamp(0.45 - margin * 2.5, 0.05, 0.45)
			if v == "n" and g + l >= 8 and math.random() < p then votes[i] = if l > g then "l" else "g"
			elseif (v == "g" or v == "l") and x >= 8 and math.random() < p then votes[i] = "n"
			elseif v == "g" and l >= 6 and math.random() < p then votes[i] = "l" end
		end
		task.wait(5)
	end
	g, l, x = tally()
	-- the reasons: what carried the most weight, what fell apart
	local reasons = {}
	local sorted = table.clone(E.board.exhibits)
	table.sort(sorted, function(a, b) return Trial.value(a) > Trial.value(b) end)
	if sorted[1] and Trial.value(sorted[1]) > 0.08 then table.insert(reasons, ("What weighed most: %s."):format(sorted[1].text)) end
	for _, ex in E.board.exhibits do
		if ex.cred < 0.6 or ex.status == "excluded" then table.insert(reasons, ("What fell apart: %s (%s)."):format(ex.text, ex.notes[#ex.notes] or "excluded")) break end
	end
	if E.board.impeach > 0.05 then table.insert(reasons, "The defendant's testimony didn't hold together.") end
	local verdict
	if g + l >= 10 and g >= l then verdict = "guilty"
	elseif g + l >= 10 then verdict = "lesser"
	elseif x >= 10 then verdict = "not guilty"
	else verdict = "hung" end
	return verdict, g + l, reasons
end

-- a bench trial: the judge alone (a player judge decides with the board in front of them)
local function benchVerdict(E: any): (string, { string })
	local S = Trial.score(E.board)
	local j = E.roles.judge
	if j and j.Parent then
		local lines = { ("The State's case: %d%% of what a conviction needs."):format(math.floor(S / CFG.Threshold * 100)) }
		for _, x in E.board.exhibits do table.insert(lines, ("- %s: %s"):format(x.text, if x.status == "excluded" then "excluded" else ("%.0f%% credible"):format(x.cred * 100))) end
		table.insert(lines, "Guilty only if the State proved it beyond a reasonable doubt.")
		local opts = { "Guilty", "Not guilty" }
		if E.theory == 3 then table.insert(opts, 2, "Guilty of the lesser charge") end
		local i = E.card(j, "You are the judge - the verdict", lines, opts, #opts) or #opts
		return if i == 1 then "guilty" elseif opts[i] == "Not guilty" then "not guilty" else "lesser", {}
	end
	local bar = CFG.Threshold - (E.judge.tilt or 0) + (math.random() - 0.5) * 0.06
	if E.judgeBought then bar += 0.3 end
	if S > bar + 0.15 or (S > bar and E.theory ~= 3) then return "guilty", {} end
	if S > bar then return "lesser", {} end
	return "not guilty", {}
end

---------------------------------------------------------------------------
-- THE TRIAL
---------------------------------------------------------------------------
-- E (from Court.run): player, alive, tell, feed(speaker, lines, kind?), card(p, from, lines, opts, default),
--   say(who: "pros"|"def"|"judge"|"witness", text), sidebar(), sitIn(seat), callFor(x) -> (name, model),
--   callNamed(name, role) -> model, stepDown(model), recess(day), asWitness(x) -> string, choices = Court.choices,
--   bill(activity, cx), playerWitness(x) -> number?, file, iv, mods, F (Court.facts), who, caseName,
--   judge { name, tilt }, prosecutor, counsel, firm, tier, elite, prepared, rehearsed, jury (bool), panel, jurorBias,
--   roles { defence, prosecutor, judge, jurors = { Player } }, familyName, capital, big
function Trial.run(E: any): any
	E.iv = E.iv or Trial.ivs[E.player.UserId]
	-- court days, counted (each adjournment is an overnight)
	E.day = 1
	local function adjourn() E.recess(E.day); E.day += 1 end
	local board = Trial.build(E.player, E.file, E.iv, E.mods)
	E.board = board
	E.facts = board.facts
	E.phase = "Pretrial"
	E.patience = 3
	E.sentencing = {}
	E.watchers = {}
	E.watchers[E.player] = "defendant"
	if E.roles.defence then E.watchers[E.roles.defence] = "defence" end
	if E.roles.prosecutor then E.watchers[E.roles.prosecutor] = "prosecutor" end
	if E.roles.judge then E.watchers[E.roles.judge] = "judge" end
	for _, p in E.roles.jurors or {} do E.watchers[p] = "juror" end
	-- what the defence knows on the day: prep (Trial.reveal) + what the firm digs up itself
	E.known = knowTable(E.player, board)
	if not (E.roles.defence and E.roles.defence.Parent) then
		local s = npcSkill(E)
		for _, x in board.exhibits do
			for _, w in x.weak do
				local key = x.id .. ":" .. w.key
				if E.known[key] == nil and (E.elite or math.random() < s * 0.45) then E.known[key] = w.real end
			end
		end
	end
	if E.roles.defence then
		-- a player attorney shares the client's file (what they investigated is in the client's table)
		local theirs = knowTable(E.roles.defence, board)
		for k, v in theirs do if E.known[k] == nil then E.known[k] = v end end
	end
	print(("[Trial] START %s: %d exhibits, case %.2f / %.2f, known %d, roles: defence=%s DA=%s judge=%s jurors=%d%s"):format(E.player.Name, #board.exhibits,
		Trial.score(board), CFG.Threshold, (function() local n = 0 for _ in E.known do n += 1 end return n end)(),
		tostring(E.roles.defence and E.roles.defence.Name), tostring(E.roles.prosecutor and E.roles.prosecutor.Name),
		tostring(E.roles.judge and E.roles.judge.Name), #(E.roles.jurors or {}), if E.elite then ", ELITE" else ""))
	push(E)
	local R: any = { verdict = "not guilty", board = board, trialKind = if E.jury then "jury" else "bench", sentencing = E.sentencing, reasons = {} }
	local ok, err = pcall(function()
		-- 1. motions
		motions(E)
		if E.dismissed then R.verdict = "dismissed" return end
		if not E.alive() then return end
		-- 2. openings
		E.phase = "Openings"
		push(E)
		local brief = E.file and E.file.brief
		announce(E, prosLabel(E), { "Ladies and gentlemen, this is a simple case.", if brief then brief.happened else "The defendant is guilty.",
			"You will see and hear: " .. (function() local t = {} for _, x in board.exhibits do if x.status ~= "excluded" then table.insert(t, x.text) end end return if #t > 0 then table.concat(t, "; ") else "the officer's report" end)() .. "." })
		local th = E.choices("theory", E.F)
		local labels = {}
		for _, o in th do table.insert(labels, o.text) end
		local lines = { "\"Our story. Whatever we tell them now, every question we ask has to fit it.\"",
			"Identity ('it wasn't me') makes attacks on who-did-it count double - but fall apart if you take the stand and admit being there.",
			"'It happened, but not like that' admits you were there - attacks on identity won't land, but the jury can find a lesser charge." }
		if E.mockText then table.insert(lines, ("\"In the mock trial, '%s' won over %d of %d.\""):format(E.mockText, E.mockAcquit or 0, E.mockOf or 6)) end
		local pick = E.card(defenceSeat(E), counselLabel(E) .. " - the defence theory", lines, labels, #labels) or #labels
		E.theory = th[pick].cat
		E.F.theory = E.theory
		if E.theory ~= 4 then
			announce(E, counselLabel(E) .. " - opening", { ("\"%s: %s.\""):format(if E.jury then "Ladies and gentlemen" else "Your Honor", th[pick].text),
				"\"The State has to prove every word of its story. Watch where it doesn't.\"" })
		end
		-- identity: attacks on who-did-it hit harder
		if E.theory == 2 then
			for _, x in board.exhibits do
				if x.type == "eyewitness" or x.type == "video" then
					for _, w in x.weak do if w.key == "face" or w.key == "glimpse" or w.key == "distance" or w.key == "dark" then w.identity = true end end
				end
			end
		end
		if E.jury or E.big then adjourn() end
		if not E.alive() then return end
		-- 3. the State's case
		stateCase(E)
		if not E.alive() then return end
		if E.jury or E.big then adjourn() end
		if not E.alive() then return end
		-- 4. the defence case
		defenceCase(E)
		if not E.alive() then return end
		-- 5. closings
		E.phase = "Closings"
		push(E)
		local strongest = nil
		for _, x in board.exhibits do if x.status ~= "excluded" and (not strongest or Trial.value(x) > Trial.value(strongest)) then strongest = x end end
		local pp = E.roles.prosecutor
		if pp and pp.Parent and strongest then
			local c = E.card(pp, prosLabel(E) .. " - closing", { "What do you hang your closing on?" }, {
				("The strongest evidence: %s"):format(strongest.text), "The defendant's own words", "The victim and the family" }, 1) or 1
			if c == 1 and strongest.cred >= 0.9 then E.closingDelta = (E.closingDelta or 0) - 0.02
			elseif c == 2 and board.impeach > 0.05 then E.closingDelta = (E.closingDelta or 0) - 0.03 end
		end
		announce(E, prosLabel(E) .. " - closing", { "The evidence is clear.", if strongest then ("Remember %s."):format(strongest.text) else "", "Find the defendant guilty." })
		local cl = E.choices("closing", E.F)
		local cll = {}
		for _, o in cl do table.insert(cll, o.text) end
		local ci = E.card(defenceSeat(E), counselLabel(E) .. " - closing", { "\"How do we close?\"", ("\"Our story from day one was the theory we chose.\"") }, cll, #cll) or #cll
		local cc = cl[ci].cat
		-- a closing that matches the story they've heard all trial raises the bar; one that doesn't lowers it
		if cc == E.theory or (E.theory == 3 and cc == 4) then E.closingDelta = (E.closingDelta or 0) + 0.04 else E.closingDelta = (E.closingDelta or 0) - 0.02 end
		announce(E, counselLabel(E) .. " - closing", { ("\"%s.\""):format(cll[ci]), "\"If you have a reasonable doubt - and you do - you must acquit.\"" })
		-- 6. the verdict
		E.phase = "Deliberation"
		push(E)
		local attempts = 0
		while E.alive() do
			attempts += 1
			if E.jury then
				announce(E, judgeLabel(E), { "Members of the jury: the defendant is presumed innocent. The State must prove guilt beyond a reasonable doubt.",
					"Evidence that was excluded or struck is not evidence. Go and deliberate." })
				E.jurorsOut()
				local v, votes, reasons = deliberate(E, E.roles.jurors or {})
				E.jurorsBack()
				R.reasons = reasons
				if v ~= "hung" then R.verdict = v break end
				announce(E, judgeLabel(E), { ("The jury is deadlocked, %d to %d. I'm declaring a mistrial."):format(votes, 12 - votes) })
				-- the State decides whether to try it again
				local retry = attempts < 3 and (E.capital or votes >= 7 or Trial.score(board) >= CFG.Threshold)
				if not retry then R.verdict = "dismissed" break end
				local deal = E.retrialDeal(attempts)
				if deal then R.verdict = "plea"; R.deal = deal break end
				adjourn()
				announce(E, judgeLabel(E), { ("THE RETRIAL - a new jury hears the same evidence (trial %d)."):format(attempts + 1) })
				for i = 1, 12 do E.jurorBias[i] = 0 end
				E.panel = {}
				E.closingDelta = (E.closingDelta or 0) - 0.03 -- the State knows the defence's playbook now
			else
				E.tell(("%s retires to chambers to consider the verdict"):format(judgeLabel(E)))
				task.wait(12)
				local v = benchVerdict(E)
				R.verdict = v
				break
			end
		end
	end)
	if not ok then warn("[Trial] error in " .. E.player.Name .. "'s trial: " .. tostring(err)) end
	R.score = Trial.score(board)
	R.lesser = R.verdict == "lesser"
	print(("[Trial] VERDICT %s: %s (case %.2f, impeach %.2f, theory %s)"):format(E.player.Name, tostring(R.verdict), R.score, board.impeach, tostring(E.theory)))
	-- pay the people who served
	local convicted = R.verdict == "guilty" or R.verdict == "lesser" or R.verdict == "plea"
	pay(E.roles.prosecutor, CFG.PayProsecutor + (if convicted then CFG.PayConviction else 0), "prosecuting " .. E.caseName)
	pay(E.roles.judge, CFG.PayJudge, "presiding over " .. E.caseName)
	for _, p in E.roles.jurors or {} do pay(p, CFG.PayJuror, "jury duty") end
	if E.roles.defence then attorneys("result", E.roles.defence, E.player, R.verdict) end
	if E.roles.prosecutor then attorneys("result", E.roles.prosecutor, E.player, R.verdict) end
	E.phase = "Verdict: " .. string.upper(R.verdict)
	push(E)
	task.delay(30, function() closeBoards(E) end)
	return R
end

---------------------------------------------------------------------------
-- SENTENCING: the range, the factors on both sides, the victim's family, then the judge
---------------------------------------------------------------------------
-- R = Trial.run's result. E.minSecs / E.maxSecs: the range. -> secs, the lines read out
function Trial.sentence(E: any, R: any): number
	local lo, hi = E.minSecs, E.maxSecs
	if R.lesser then lo, hi = math.floor(lo * 0.5), math.floor(hi * 0.6) end
	local aggr, mit = {}, {}
	local s = 0.5 -- where in the range: 0 = the minimum, 1 = the maximum
	if (E.priors or 0) > 0 then s += 0.08 * math.min(E.priors, 4); table.insert(aggr, ("%d prior arrest%s"):format(E.priors, if E.priors == 1 then "" else "s")) end
	if (E.kills or 0) > 1 then s += 0.15; table.insert(aggr, ("%d people dead"):format(E.kills)) end
	if E.copKill then s += 0.15; table.insert(aggr, "a police officer killed") end
	if R.sentencing.perjury then s += 0.12; table.insert(aggr, "a witness lied for the defendant") end
	if E.board and E.board.impeach > 0.1 then s += 0.05; table.insert(aggr, "the defendant lied on the stand") end
	if R.sentencing.character then s -= 0.1; table.insert(mit, "family and character witnesses") end
	if R.sentencing.remorse then s -= 0.08; table.insert(mit, "remorse on the stand") end
	if E.iv and E.iv.cooperative then s -= 0.08; table.insert(mit, "cooperated with the police") end
	if (E.priors or 0) == 0 then s -= 0.1; table.insert(mit, "no criminal record") end
	-- the victim's family speaks
	if E.victim then
		announce(E, ("%s's family - victim impact statement"):format(E.victim), {
			("\"%s was everything to us. We sat in this room every day of this trial.\""):format(E.victim),
			"\"Whatever you decide, it won't bring them back. But please - make it mean something.\"" })
		s += 0.05
	end
	-- the defendant's last words
	local a = E.card(E.player, judgeLabel(E) .. " - allocution", { "\"Before I pass sentence, is there anything you want to say?\"" }, {
		"\"I'm sorry. I'll carry it the rest of my life.\"", "\"I still say I didn't do it.\"", "\"Do what you want.\"", "[Say nothing]" }, 4) or 4
	if a == 1 then s -= 0.08; table.insert(mit, "an apology to the court") elseif a == 3 then s += 0.1; table.insert(aggr, "contempt for the court") end
	s = math.clamp(s, 0, 1)
	local guide = math.floor(lo + (hi - lo) * s)
	local secs = guide
	local j = E.roles.judge
	local lines = {
		("Range: %s to %s."):format(E.clock(lo), E.clock(hi)),
		"Aggravating: " .. (if #aggr > 0 then table.concat(aggr, "; ") else "none") .. ".",
		"Mitigating: " .. (if #mit > 0 then table.concat(mit, "; ") else "none") .. ".",
		("The guidelines suggest %s."):format(E.clock(guide)),
	}
	if j and j.Parent then
		local opts = { ("The minimum - %s"):format(E.clock(lo)), ("The guideline - %s"):format(E.clock(guide)), ("The maximum - %s"):format(E.clock(hi)) }
		local i = E.card(j, "You are the judge - the sentence", lines, opts, 2) or 2
		secs = if i == 1 then lo elseif i == 3 then hi else guide
	end
	secs = math.max(secs, E.floorSecs or 0)
	announce(E, judgeLabel(E) .. " - sentencing", { lines[2], lines[3], ("The sentence of this court: %s."):format(E.clock(secs)) })
	print(("[Trial] SENTENCE %s: %ds (range %d-%d, s=%.2f)"):format(E.player.Name, secs, lo, hi, s))
	return secs
end

return Trial
