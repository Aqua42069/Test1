--[[
	Attorneys (v291) - players working in the justice system.

	THE STATE BAR OF NEVADA (a desk in the courthouse clerk's office; also "My law practice" on
	the phone's Lawyer button once licensed):
	  * the BAR EXAM: $2,500, five questions on how the courts here work, four right to pass
	  * DEFENCE ATTORNEY - two ways to practise:
	      - an ASSOCIATE at a firm (the firm's rate; you get 50% of every hour billed to your
	        clients). Bigger firms take you as you win: Experienced Defense Counsel at 2 wins,
	        Criminal Defense Firm 4, Elite Defense Team 7, National Trial Firm 10, Premier Counsel 15
	      - INDEPENDENT: your own rate ($250-$5,000/h - the top rates need a record); you keep 85%
	        (15% is bar dues and overheads)
	    Clients hire you from the Lawyer menu ("Hire a player attorney"). You see their case file,
	    investigate the State's exhibits (which weaknesses are real - billed to the client), send
	    them advice, and when the trial starts you're called to court and run the defence: motions,
	    objections, cross-examination, the defence case, the closing.
	  * DEPUTY DA - on duty as a prosecutor, the court calls you when a trial starts: you present the
	    State's case, repair your witnesses on redirect, cross-examine the defendant, close.
	    $2,500 a trial, +$2,500 for a conviction.
	  * JUDGE - after 5 trials as counsel or DA, apply to the bench: you rule on motions and
	    objections, decide bench trials and set sentences within the range. $3,000 a trial.
	  * JURY DUTY - anyone free in the city can be summoned when a jury trial starts: sit in the box,
	    watch the evidence, vote. $500.

	Saved in the criminal-record store (Records: rec.bar). Attributes: AttorneyLicensed,
	AttorneyDuty ("defence" / "prosecutor" / "judge"), AttorneyFirm, AttorneyRate, AttorneyJudge.
	API ServerStorage.Attorneys (BindableFunction):
	  ("counselFor", defendant, info) -> the client's player attorney if they come to court
	  ("summon", "prosecutor"|"judge", info) -> a player who took it, or nil
	  ("summon", "jurors", info, n) -> { Player }
	  ("result", p, defendant, verdict)      ("earn", userId, amount, clientName)
	  ("list") -> on-duty defence attorneys    ("offer", attorney, client, info) -> bool
	  ("practice", p)  ("notice", p, text)  ("share", firmName?) -> 0.5 / 0.85
	Logs: [Bar]
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CFG = {
	Fee = 2500, Pass = 4, Questions = 5,
	FirmShare = 0.5, IndependentShare = 0.85,
	JudgeTrials = 5,
	CallSeconds = 25,
}
local FIRM_REQ = {
	{ "Public Defender", 0 }, { "Local Attorney", 0 }, { "Experienced Defense Counsel", 2 }, { "Criminal Defense Firm", 4 },
	{ "Elite Defense Team", 7 }, { "National Trial Firm", 10 }, { "Premier Counsel", 15 },
}
local RATES = { { 250, 0 }, { 500, 0 }, { 1000, 3 }, { 2500, 8 }, { 5000, 15 } } -- rate, wins needed

local Records: any = nil
task.spawn(function()
	local ps = ServerScriptService:WaitForChild("PoliceSystem", 30)
	for _ = 1, 30 do
		local rm = ps and ps:FindFirstChild("Records")
		if rm then
			local ok, m = pcall(require, rm)
			if ok then Records = m break end
		end
		task.wait(1)
	end
end)
local TrialMod: any = nil
local function trial(): any
	if TrialMod then return TrialMod end
	local ps = ServerScriptService:FindFirstChild("PoliceSystem")
	local m = ps and ps:FindFirstChild("Trial")
	if m then
		local ok, r = pcall(require, m)
		if ok then TrialMod = r end
	end
	return TrialMod
end

local function notice(p: Player, text: string)
	local r = ReplicatedStorage:FindFirstChild("PhoneCalls")
	if r and r:IsA("RemoteEvent") and p.Parent then r:FireClient(p, "notice", text) end
end
local function phone(): BindableFunction?
	local f = ServerStorage:FindFirstChild("Phone")
	return if f and f:IsA("BindableFunction") then f else nil
end
local function dialog(p: Player, from: string, lines: { string }, options: { string }): number?
	local f = phone()
	if not f then return nil end
	local ok, how, idx = pcall(f.Invoke, f, "dialog", p, { from = from, lines = lines, options = options })
	if ok and how == "answered" then return idx end
	return nil
end
local function call(p: Player, from: string, lines: { string }, options: { string }, expires: number?): number?
	local f = phone()
	if not f then return nil end
	local ok, how, idx = pcall(f.Invoke, f, "call", p, { from = from, kind = "court", legal = true, expires = expires or CFG.CallSeconds, lines = lines, options = options })
	if ok and how == "answered" then return idx end
	return nil
end
local function money(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then out = out:sub(2) end
	return "$" .. out
end
local function nameOf(p: Player): string
	return tostring(p:GetAttribute("CharacterName") or p.DisplayName)
end
local function economy(action: string, p: Player, amount: number): any
	local eco = ServerStorage:FindFirstChild("Economy")
	if eco and eco:IsA("BindableFunction") then
		local ok, r = pcall(eco.Invoke, eco, action, p, amount)
		if ok then return r end
	end
	return nil
end

---------------------------------------------------------------------------
-- the record
---------------------------------------------------------------------------
local function bar(p: Player): any
	if not Records then return { licensed = false, wins = 0, losses = 0, trials = 0, earned = 0 } end
	local rec = Records.get(p)
	rec.bar = rec.bar or { licensed = false, wins = 0, losses = 0, trials = 0, earned = 0 }
	return rec.bar
end
local function save(p: Player)
	local b = bar(p)
	p:SetAttribute("AttorneyLicensed", if b.licensed then true else nil)
	p:SetAttribute("AttorneyFirm", if b.licensed then (if b.independent then "Independent Counsel" else b.firm) else nil)
	p:SetAttribute("AttorneyRate", if b.licensed and b.independent then b.rate else nil)
	p:SetAttribute("AttorneyJudge", if b.judge then true else nil)
	if Records and Records.touch then pcall(Records.touch, p) end
end
local function free(p: Player): boolean
	return p.Parent ~= nil and p:GetAttribute("CustodyStage") == nil and p:GetAttribute("BeingEscorted") == nil
		and p:GetAttribute("BookingState") == nil and p:GetAttribute("SentenceEnd") == nil
end
local busy: { [Player]: string } = {} -- in a trial right now (role)

---------------------------------------------------------------------------
-- the bar exam
---------------------------------------------------------------------------
local QUESTIONS = {
	{ "A suspect asks for a lawyer and the detective keeps questioning. What they say after that is...",
		"Suppressed - it can't be shown to the jury", { "Admitted if it's true", "Admitted if the judge likes it" } },
	{ "A witness says: \"My neighbour told me he did it.\" The objection is...", "Hearsay", { "Leading the witness", "Speculation" } },
	{ "The DA asks: \"You saw the defendant shoot him, didn't you?\" The objection is...", "Leading the witness", { "Hearsay", "Relevance" } },
	{ "Who has to prove the case, and how sure must the jury be?", "The State - beyond a reasonable doubt", { "The defendant has to prove they're innocent", "Whoever has the better lawyer - more likely than not" } },
	{ "A witness tells the jury: \"Everyone knows he's been arrested before.\" That is...", "Improper character evidence", { "Fine - it's true", "Speculation" } },
	{ "Evidence nobody can account for between the scene and the courtroom...", "Can be excluded - the chain of custody is broken", { "Is always admitted", "Counts double" } },
	{ "You cross-examine a witness on a point that turns out to be solid. The jury...", "Trusts that witness MORE", { "Doesn't notice", "Has to disregard the witness" } },
	{ "Your opening said 'my client wasn't there'. On the stand your client says 'I was there, but...'. The result:", "The State uses the contradiction against you", { "Nothing - only the closing counts", "A mistrial" } },
	{ "A defendant chooses not to testify. The jury...", "Must not hold it against them", { "Must convict", "Gets to see their record instead" } },
	{ "A jury of twelve can't agree. The judge...", "Declares a mistrial - the State can try it again", { "Decides it alone", "Acquits automatically" } },
	{ "The State's evidence couldn't convince any reasonable jury even if all of it is believed. The defence should...", "Move to dismiss", { "Move to suppress", "Plead guilty" } },
}

local function exam(p: Player): boolean
	local C = nil
	do
		local ps = ServerScriptService:FindFirstChild("PoliceSystem")
		local m = ps and ps:FindFirstChild("Court")
		if m then local ok, r = pcall(require, m); if ok then C = r end end
	end
	local pool = table.clone(QUESTIONS)
	for k = #pool, 2, -1 do local j = math.random(1, k); pool[k], pool[j] = pool[j], pool[k] end
	local right = 0
	for n = 1, CFG.Questions do
		if not p.Parent then return false end
		local q = pool[n]
		local opts = { q[2], q[3][1], q[3][2] }
		for k = #opts, 2, -1 do local j = math.random(1, k); opts[k], opts[j] = opts[j], opts[k] end
		local lines = { ("Question %d of %d"):format(n, CFG.Questions), q[1] }
		local i = if C and C.card then C.card(p, "State Bar of Nevada - the bar exam", lines, opts, 1) else dialog(p, "State Bar of Nevada - the bar exam", lines, opts)
		if i and opts[i] == q[2] then right += 1 end
	end
	print(("[Bar] EXAM %s: %d/%d"):format(p.Name, right, CFG.Questions))
	dialog(p, "State Bar of Nevada", { ("You answered %d of %d correctly."):format(right, CFG.Questions),
		if right >= CFG.Pass then "Congratulations - you are admitted to the State Bar of Nevada." else ("You needed %d. You can sit it again (the fee is charged again)."):format(CFG.Pass) }, { "OK" })
	return right >= CFG.Pass
end

---------------------------------------------------------------------------
-- practising law
---------------------------------------------------------------------------
local function clientsOf(p: Player): { Player }
	local out = {}
	if not Records then return out end
	for _, c in Players:GetPlayers() do
		local rec = Records.get(c)
		if c ~= p and rec.lawyer and rec.lawyer.playerAttorney == p.UserId then table.insert(out, c) end
	end
	return out
end

local function caseFile(c: Player): any?
	local api = ServerStorage:FindFirstChild("CityLifeApi")
	if not (api and api:IsA("BindableFunction")) then return nil end
	local ok, f = pcall(api.Invoke, api, "caseFile", c)
	return if ok and type(f) == "table" then f else nil
end
local function billClient(c: Player, activity: string, cx: number)
	local law = ServerStorage:FindFirstChild("LawFirms")
	if law and law:IsA("BindableFunction") then pcall(law.Invoke, law, "bill", c, activity, cx) end
end

local function clientMenu(p: Player, c: Player)
	for _ = 1, 6 do
		if not (p.Parent and c.Parent) then return end
		local file = caseFile(c)
		local T = trial()
		local iv = T and T.ivs[c.UserId]
		local head = { ("Client: %s"):format(nameOf(c)), ("Charges: %s"):format(tostring(c:GetAttribute("CaseCharges") or c:GetAttribute("Charges") or "none on file")) }
		if c:GetAttribute("CourtDateAt") then table.insert(head, "Out on bail - court date pending.") end
		if c:GetAttribute("CustodyStage") then table.insert(head, "In custody.") end
		local i = dialog(p, "Your client", head, { "Review the case file", "Investigate one of the State's exhibits (billed)", "Send your client advice", "Back" })
		if i == 1 then
			if not (file and file.brief and T) then
				dialog(p, "Case file", { "Nothing on file yet - the State hasn't built a case." }, { "OK" })
			else
				local board = T.build(c, file, iv)
				local known = T.knowTable(c, board)
				local lines = { file.brief.happened, ("The State's case: %d%% of what a conviction needs."):format(math.floor(T.score(board) / T.CFG.Threshold * 100)) }
				for _, x in board.exhibits do
					local k = {}
					for _, w in x.weak do
						local kv = known[x.id .. ":" .. w.key]
						if kv ~= nil then table.insert(k, (if kv then "REAL: " else "solid: ") .. w.attack) end
					end
					table.insert(lines, ("- %s%s"):format(x.title, if #k > 0 then " [" .. table.concat(k, "; ") .. "]" else " [not investigated]"))
				end
				if iv then table.insert(lines, ("Interview: %s%s%s."):format(if iv.confessed then "confessed" else "no confession",
					if iv.violation then "; the detective crossed a line (" .. tostring(iv.violation) .. ")" else "",
					if (tonumber(iv.falseStatements) or 0) > 0 then "; lied to detectives" else "")) end
				dialog(p, "Case file - " .. nameOf(c), lines, { "OK" })
			end
		elseif i == 2 then
			if not (file and file.brief and T) then
				dialog(p, "Investigation", { "There's nothing to investigate yet." }, { "OK" })
			else
				local board = T.build(c, file, iv)
				local opts, ids = {}, {}
				for _, x in board.exhibits do table.insert(opts, x.title); table.insert(ids, x.id) end
				table.insert(opts, "Never mind")
				local k = dialog(p, "Investigate", { "Which exhibit do you dig into? (two of its weaknesses, billed to the client)" }, opts)
				if k and ids[k] then
					local found = T.reveal(c, file, iv, 2, ids[k])
					billClient(c, "motions", 0.4)
					dialog(p, "What you found", found, { "OK" })
					notice(c, ("%s investigated your case (billed)."):format(nameOf(p)))
					print(("[Bar] INVESTIGATE %s for %s: %s"):format(p.Name, c.Name, ids[k]))
				end
			end
		elseif i == 3 then
			local adv = { "Take the DA's deal - trial is too risky", "We're going to trial - don't plead", "Say NOTHING to anyone about this case", "Don't testify - let me do the talking", "Back" }
			local k = dialog(p, "Advice to your client", { "What do you tell them?" }, adv)
			if k and k < #adv then
				notice(c, ("Your attorney %s: \"%s.\""):format(nameOf(p), adv[k]))
				billClient(c, "call", 1)
			end
		else
			return
		end
	end
end

local function chooseFirm(p: Player)
	local b = bar(p)
	local opts, names = {}, {}
	for _, f in FIRM_REQ do
		if (b.wins or 0) >= f[2] then
			table.insert(opts, ("%s (associate, 50%% of the firm's hourly rate)"):format(f[1]))
			table.insert(names, f[1])
		else
			table.insert(opts, ("%s - needs %d wins"):format(f[1], f[2]))
			table.insert(names, false)
		end
	end
	table.insert(opts, "Back")
	local i = dialog(p, "Join a law firm", { ("Your record: %d wins, %d losses."):format(b.wins or 0, b.losses or 0) }, opts)
	if i and names[i] then
		b.firm, b.independent, b.rate = names[i], false, nil
		save(p)
		notice(p, ("You're now an associate at %s."):format(names[i]))
		print(("[Bar] FIRM %s joins %s"):format(p.Name, names[i]))
	elseif i and i < #opts then
		dialog(p, "Join a law firm", { "They won't take you yet. Win more cases." }, { "OK" })
	end
end

local function goIndependent(p: Player)
	local b = bar(p)
	local opts = {}
	for _, r in RATES do
		table.insert(opts, if (b.wins or 0) >= r[2] then ("%s an hour"):format(money(r[1])) else ("%s an hour - needs %d wins"):format(money(r[1]), r[2]))
	end
	table.insert(opts, "Back")
	local i = dialog(p, "Independent practice", { "Set your own rate. You keep 85% of everything you bill (15% is bar dues and overheads).",
		"Clients pay a retainer of ten hours up front." }, opts)
	local r = i and RATES[i]
	if r and (b.wins or 0) >= r[2] then
		b.independent, b.firm, b.rate = true, nil, r[1]
		save(p)
		notice(p, ("Independent practice: %s an hour."):format(money(r[1])))
		print(("[Bar] INDEPENDENT %s at %d/h"):format(p.Name, r[1]))
	elseif r then
		dialog(p, "Independent practice", { "Nobody pays that rate to a lawyer without a record." }, { "OK" })
	end
end

local function practice(p: Player, atDesk: boolean)
	if busy[p] == "menu" then return end
	busy[p] = busy[p] or "menu"
	local ok, err = pcall(function()
		local b = bar(p)
		if not b.licensed then
			if not atDesk then
				dialog(p, "State Bar of Nevada", { "You aren't licensed. Take the bar exam at the State Bar desk in the courthouse (the clerk's office)." }, { "OK" })
				return
			end
			local i = dialog(p, "State Bar of Nevada", {
				"Lawyers here represent real people: defence attorneys (at a firm or on their own), Deputy DAs who prosecute, and judges.",
				("The bar exam: %s, %d questions on how the courts work, %d to pass."):format(money(CFG.Fee), CFG.Questions, CFG.Pass),
			}, { ("Take the bar exam (%s)"):format(money(CFG.Fee)), "Leave" })
			if i ~= 1 then return end
			if economy("Charge", p, CFG.Fee) ~= true then
				dialog(p, "State Bar of Nevada", { ("The fee is %s."):format(money(CFG.Fee)) }, { "OK" })
				return
			end
			if exam(p) then
				b.licensed = true
				b.firm = "Public Defender"
				save(p)
				dialog(p, "State Bar of Nevada", { "You start with the Public Defender's office. Join a bigger firm or go independent from this desk (or the phone's Lawyer button).",
					"Go on duty to be hired, called to prosecute, or - later - to sit as a judge." }, { "OK" })
			end
			return
		end
		for _ = 1, 8 do
			b = bar(p)
			local duty = p:GetAttribute("AttorneyDuty")
			local where = if b.independent then ("independent, %s/h"):format(money(b.rate or 0)) else ("associate at %s"):format(tostring(b.firm))
			local lines = {
				("%s - %s"):format(nameOf(p), where),
				("Record: %d wins, %d losses, %d trials. Earned: %s."):format(b.wins or 0, b.losses or 0, b.trials or 0, money(b.earned or 0)),
				("On duty: %s."):format(if duty then tostring(duty) else "no"),
			}
			local opts, acts = {}, {}
			local function add(t: string, f: () -> ()) table.insert(opts, t); table.insert(acts, f) end
			local clients = clientsOf(p)
			if #clients > 0 then
				add(("My clients (%d)"):format(#clients), function()
					local names = {}
					for _, c in clients do table.insert(names, nameOf(c)) end
					table.insert(names, "Back")
					local k = dialog(p, "My clients", { "Which client?" }, names)
					if k and clients[k] then clientMenu(p, clients[k]) end
				end)
			end
			if duty ~= "defence" then add("Go on duty - defence attorney (clients can hire you)", function() p:SetAttribute("AttorneyDuty", "defence") end) end
			if duty ~= "prosecutor" then add("Go on duty - Deputy DA (the court calls you to prosecute)", function() p:SetAttribute("AttorneyDuty", "prosecutor") end) end
			if b.judge and duty ~= "judge" then add("Go on duty - judge (the court calls you to preside)", function() p:SetAttribute("AttorneyDuty", "judge") end) end
			if duty then add("Go off duty", function() p:SetAttribute("AttorneyDuty", nil) end) end
			add("Join a law firm", function() chooseFirm(p) end)
			add("Go independent - set your own rate", function() goIndependent(p) end)
			if not b.judge then
				add(("Apply to the bench (needs %d trials)"):format(CFG.JudgeTrials), function()
					if (b.trials or 0) >= CFG.JudgeTrials then
						b.judge = true
						save(p)
						dialog(p, "State Bar of Nevada", { "The Governor has appointed you to the Clark County bench. Go on duty as a judge to preside." }, { "OK" })
						print(("[Bar] JUDGE %s appointed"):format(p.Name))
					else
						dialog(p, "State Bar of Nevada", { ("You've tried %d case(s). The bench needs %d."):format(b.trials or 0, CFG.JudgeTrials) }, { "OK" })
					end
				end)
			end
			add("Done", function() end)
			local i = dialog(p, if atDesk then "State Bar of Nevada" else "My law practice", lines, opts)
			if not i or i == #opts then break end
			acts[i]()
			save(p)
		end
	end)
	if not ok then warn("[Bar] menu: " .. tostring(err)) end
	if busy[p] == "menu" then busy[p] = nil end
end

---------------------------------------------------------------------------
-- called to court
---------------------------------------------------------------------------
local function summonOne(role: string, info: any): Player?
	local defendant = info.defendant
	local cands = {}
	for _, p in Players:GetPlayers() do
		if p ~= defendant and p:GetAttribute("AttorneyDuty") == role and free(p) and not busy[p] then table.insert(cands, p) end
	end
	for _, p in cands do
		busy[p] = role
		local lines = if role == "prosecutor" then {
			("The State of Nevada v. %s is going to trial now at the Clark County Courthouse."):format(nameOf(defendant)),
			("Charges: %s."):format(tostring(info.charges)), "Will you prosecute? You'll be taken to the State's table. $2,500, +$2,500 on a conviction." }
			else { ("The State of Nevada v. %s is going to trial now."):format(nameOf(defendant)), ("Charges: %s."):format(tostring(info.charges)),
				"Will you preside? You'll be taken to the bench. $3,000." }
		local i = call(p, if role == "prosecutor" then "Clark County District Attorney" else "Clark County Court Administrator", lines, { "Yes - on my way", "Not now" })
		if i == 1 and free(p) then
			print(("[Bar] SUMMON %s: %s takes %s's case"):format(role, p.Name, defendant.Name))
			return p
		end
		busy[p] = nil
	end
	return nil
end

local function summonJurors(info: any, n: number): { Player }
	local defendant = info.defendant
	local out = {}
	local asked = 0
	local answered = 0
	for _, p in Players:GetPlayers() do
		if p ~= defendant and free(p) and not busy[p] and p:GetAttribute("AttorneyDuty") == nil and p:GetAttribute("CourtWitnessFor") == nil
			and p:GetAttribute("JuryDuty") ~= false then
			asked += 1
			task.spawn(function()
				local i = call(p, "Clark County Jury Commissioner", {
					("JURY SUMMONS: The State of Nevada v. %s."):format(nameOf(defendant)),
					"Serve on the jury? You'll be taken to the jury box. You watch the evidence and vote on the verdict. $500.",
				}, { "Yes - I'll serve", "Not now", "Never ask me again" })
				answered += 1
				if i == 1 and #out < n and free(p) and not busy[p] then
					busy[p] = "juror"
					table.insert(out, p)
				elseif i == 1 then
					notice(p, "Thank you - the jury is already full.")
				elseif i == 3 then
					p:SetAttribute("JuryDuty", false)
				end
			end)
		end
	end
	local t0 = os.clock()
	while answered < asked and #out < n and os.clock() - t0 < CFG.CallSeconds + 2 do task.wait(0.5) end
	print(("[Bar] JURY for %s: %d player juror(s) of %d asked"):format(defendant.Name, #out, asked))
	return out
end

local function counselFor(defendant: Player, info: any): Player?
	if not Records then return nil end
	local rec = Records.get(defendant)
	local uid = rec.lawyer and rec.lawyer.playerAttorney
	local p = uid and Players:GetPlayerByUserId(uid)
	if not (p and free(p) and not busy[p]) then return nil end
	busy[p] = "defence"
	local i = call(p, "Clark County Courthouse", { ("Your client %s's trial is starting now."):format(nameOf(defendant)),
		("Charges: %s."):format(tostring(info.charges)), "Go to court? You'll be taken to the defence table and run the defence." },
		{ "Yes - on my way", "No - let the firm cover it" }, 30)
	if i == 1 and free(p) then
		print(("[Bar] COUNSEL %s appears for %s"):format(p.Name, defendant.Name))
		return p
	end
	busy[p] = nil
	return nil
end

local owed: { [number]: number } = {} -- pay for attorneys who were offline when billed (this server)
local function earn(uid: number, amount: number, clientName: string)
	amount = math.floor(amount)
	if amount <= 0 then return end
	local p = Players:GetPlayerByUserId(uid)
	if p then
		economy("AddBank", p, amount)
		local b = bar(p)
		b.earned = (b.earned or 0) + amount
		save(p)
		notice(p, ("%s earned from %s's case."):format(money(amount), clientName))
		print(("[Bar] EARN %s %d from %s"):format(p.Name, amount, clientName))
	else
		owed[uid] = (owed[uid] or 0) + amount
	end
end
Players.PlayerAdded:Connect(function(p)
	task.delay(10, function()
		local due = owed[p.UserId]
		if due and p.Parent then
			owed[p.UserId] = nil
			earn(p.UserId, due, "your clients while you were away")
		end
		if p.Parent then save(p) end
	end)
end)
for _, p in Players:GetPlayers() do task.delay(10, function() if p.Parent then save(p) end end) end
Players.PlayerRemoving:Connect(function(p) busy[p] = nil end)

local function result(p: Player, defendant: Player, verdict: string)
	local role = busy[p]
	busy[p] = nil
	local b = bar(p)
	if not b.licensed then return end
	b.trials = (b.trials or 0) + 1
	local defenceWon = verdict == "not guilty" or verdict == "dismissed" or verdict == "lesser"
	local won = if role == "prosecutor" then (verdict == "guilty" or verdict == "lesser" or verdict == "plea") else defenceWon
	if won then b.wins = (b.wins or 0) + 1 else b.losses = (b.losses or 0) + 1 end
	save(p)
	notice(p, ("%s v. %s: %s. Your record: %d-%d."):format(if role == "prosecutor" then "State" else "Defence", nameOf(defendant), string.upper(verdict), b.wins, b.losses))
	print(("[Bar] RESULT %s (%s) in %s's case: %s -> %s"):format(p.Name, tostring(role), defendant.Name, verdict, if won then "win" else "loss"))
end

---------------------------------------------------------------------------
-- the State Bar desk at the courthouse
---------------------------------------------------------------------------
task.delay(12, function()
	local ch = workspace:FindFirstChild("Courthouse")
	local m = ch and ch:FindFirstChild("CourtMarkers")
	local at = m and (m:FindFirstChild("Room_ClerksOffice") or m:FindFirstChild("ClerkSpot"))
	if not (at and at:IsA("BasePart")) then warn("[Bar] no courthouse clerk's office - the State Bar desk isn't placed") return end
	local part = Instance.new("Part")
	part.Name = "StateBarDesk"
	part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = at.Position + Vector3.new(0, 0, 8)
	part.Parent = ch
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = "Licensing, duty and your practice"
	pp.ObjectText = "State Bar of Nevada"
	pp.HoldDuration = 0.4
	pp.MaxActivationDistance = 12
	pp.RequiresLineOfSight = false
	pp.Parent = part
	pp.Triggered:Connect(function(p) task.spawn(practice, p, true) end)
	-- a sign over it
	local s = Instance.new("Part")
	s.Name = "StateBarSign"
	s.Anchored = true
	s.CanCollide = false
	s.Size = Vector3.new(9, 1.6, 0.3)
	s.Color = Color3.fromRGB(20, 20, 24)
	s.CFrame = CFrame.new(part.Position + Vector3.new(0, 6, 0))
	s.Parent = ch
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local g = Instance.new("SurfaceGui")
		g.Face = face
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.TextScaled = true
		t.Font = Enum.Font.Garamond
		t.TextColor3 = Color3.fromRGB(201, 163, 82)
		t.Text = "STATE BAR OF NEVADA"
		t.Parent = g
		g.Parent = s
	end
	print("[Bar] v291 ready - State Bar desk in the clerk's office")
end)

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------
do
	local fn = ServerStorage:FindFirstChild("Attorneys") or Instance.new("BindableFunction")
	fn.Name = "Attorneys"
	fn.OnInvoke = function(action: string, a: any, b: any, c: any)
		if action == "counselFor" then
			return counselFor(a, b or {})
		elseif action == "summon" then
			if a == "jurors" then return summonJurors(b or {}, tonumber(c) or 6) end
			return summonOne(tostring(a), b or {})
		elseif action == "result" then
			if typeof(a) == "Instance" and a:IsA("Player") then result(a, b, tostring(c)) end
			return true
		elseif action == "earn" then
			earn(tonumber(a) or 0, tonumber(b) or 0, tostring(c))
			return true
		elseif action == "notice" then
			if typeof(a) == "Instance" and a:IsA("Player") then notice(a, tostring(b)) end
			return true
		elseif action == "practice" then
			if typeof(a) == "Instance" and a:IsA("Player") then task.spawn(practice, a, false) end
			return true
		elseif action == "list" then
			local out = {}
			for _, p in Players:GetPlayers() do
				local bb = bar(p)
				if p:GetAttribute("AttorneyDuty") == "defence" and bb.licensed and free(p) and p ~= a then
					table.insert(out, { userId = p.UserId, name = nameOf(p), firm = if bb.independent then nil else bb.firm,
						rate = if bb.independent then bb.rate else nil, wins = bb.wins or 0, losses = bb.losses or 0 })
				end
			end
			return out
		elseif action == "offer" then
			-- a client wants to hire them
			if not (typeof(a) == "Instance" and a:IsA("Player") and typeof(b) == "Instance" and b:IsA("Player")) then return false end
			local i = call(a, "New client", { ("%s wants to hire you."):format(nameOf(b)),
				("Charges: %s."):format(tostring(b:GetAttribute("CaseCharges") or b:GetAttribute("Charges") or "none yet")),
				if type(c) == "table" and c.fee then ("They'd pay %s up front."):format(money(c.fee)) else "",
				"Take the case?" }, { "Take the case", "Decline" }, 40)
			return i == 1
		elseif action == "share" then
			return if a == "Independent Counsel" then CFG.IndependentShare else CFG.FirmShare
		elseif action == "licensed" then
			return typeof(a) == "Instance" and a:IsA("Player") and bar(a).licensed == true
		end
		return nil
	end
	fn.Parent = ServerStorage
end
