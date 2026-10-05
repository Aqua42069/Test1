--[[
	Court (v263-v266) - the day in court, at the Clark County Courthouse (workspace.Courthouse,
	built by tools/build_courthouse.luau; every seat and spot is a named part in CourtMarkers).

	PoliceSystem (PrisonFlow.courtDay) calls Court.run(player, ctx) between booking and the sentence:
	  ctx = { secs, text, stars, priors, interview (the interrogation result or nil), minor,
	          free (out on bail: they walked in themselves - no ride, no holding cell),
	          alive(), ride(dest) -> how, walk(goal, maxTime) -> how, tell(msg), cuff(), uncuff(),
	          setHold(pos) }
	  -> { verdict = "plea" | "guilty" | "guilty (some counts)" | "not guilty" | "dismissed",
	       secs = the sentence (0 when free), judge = name }

	THE DAY
	 1. A cruiser to the prisoner sally port; walked up the secure stair to court holding.
	 2. "All rise": the judge walks in from chambers; the bailiff brings the defendant to the
	    defendant's chair. (Jury trials: the jurors file in from the jury room.)
	 3. Arraignment: the charges and the MAXIMUM sentence.
	 4. Plea: counsel reads the DA's offer (counsel tier, a prepared case, a confession, a deal
	    made in the interview room, priors and the judge move it). Accept / negotiate (it can get
	    better, stay, or be pulled) / reject. Capital cases: no deal. Minor cases: a quick plea.
	 5. Trial - bench (judge only) or jury (12 jurors): three pieces of the State's case built from
	    the real arrest and interview, each answered: object / challenge the evidence / testify
	    (from the witness stand) / stay silent. Jury: they deliberate in the jury room; 10+ guilty
	    votes convicts, 2 or fewer acquits, between is a hung jury (a last offer, or it's dropped).
	    Guilty at trial carries the trial penalty; a close case convicts on some counts only.
	 6. Judges with memory: a named roster; the same judge can come back and remembers how your
	    last case went (saved in the record, rec.court).
	Lawyer hours bill through LawFirms. Logs: [Court]
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local PathfindingService = game:GetService("PathfindingService")

local Court = {}

local CFG = {
	MaxScale = 1.6, -- the maximum the judge reads out = the expected sentence x this
	OpenPleaScale = 0.85, -- pleading guilty with no deal
	TrialPenalty = 1.25, -- guilty on every count at trial
	SomeCountsScale = 1.0,
	BaseOffer = 0.65, -- the DA's first offer, as a share of the expected sentence
	MinorPleaScale = 0.75, -- minor cases: plead guilty at arraignment
	LifeSecs = 315360000, -- v288g: LIFE - no release date (ten years of real time: never). Escape or die.
}

local JUDGES = {
	{ name = "Judge Harlan Voss", tilt = 0.08, offer = 0.05, greet = "This court has no patience for excuses." },
	{ name = "Judge Ruth Okafor", tilt = 0, offer = 0, greet = "Let's be clear, and let's be quick." },
	{ name = "Judge Daniel Price", tilt = -0.06, offer = -0.05, greet = "Everyone gets a fair hearing in my courtroom." },
	{ name = "Judge Leonard Marsh", tilt = 0.02, offer = 0, greet = "Sit down, counsel. We have a full docket." },
}
local PROSECUTORS = { "ADA Carla Brennan", "ADA Michael Stone", "ADA Victor Hale" }
local FIRM_TIER = {
	["Public Defender"] = 1, ["Local Attorney"] = 2, ["Experienced Defense Counsel"] = 3, ["Criminal Defense Firm"] = 4,
	["Elite Defense Team"] = 5, ["National Trial Firm"] = 6, ["Premier Counsel"] = 7,
	["Independent Counsel"] = 4, -- v291: a player attorney in their own practice
}

local Records: any = nil
function Court.init(c: any)
	Records = c.Records
end

---------------------------------------------------------------------------
-- the building
---------------------------------------------------------------------------
local function markers(): Instance?
	local m = workspace:FindFirstChild("Courthouse")
	return m and m:FindFirstChild("CourtMarkers")
end

function Court.available(): boolean
	local f = markers()
	return f ~= nil and f:FindFirstChild("JudgeSeat") ~= nil and f:FindFirstChild("DefendantSeat") ~= nil
		and f:FindFirstChild("HoldingSpot") ~= nil
end

function Court.spot(name: string): BasePart?
	local f = markers()
	local p = f and f:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p else nil
end
local spot = Court.spot

local function clock(secs: number): string
	secs = math.max(0, math.floor(secs))
	return ("%d:%02d"):format(secs // 60, secs % 60)
end

---------------------------------------------------------------------------
-- NPCs (PoliceSystem also uses these for the lawyer walking into the station)
---------------------------------------------------------------------------
local OUTFITS = {
	judge = { Color3.fromRGB(20, 20, 24), Color3.fromRGB(20, 20, 24) }, -- the robe
	lawyer = { Color3.fromRGB(35, 38, 48), Color3.fromRGB(30, 30, 36) },
	prosecutor = { Color3.fromRGB(64, 64, 70), Color3.fromRGB(40, 40, 44) },
	bailiff = { Color3.fromRGB(70, 80, 110), Color3.fromRGB(40, 46, 66) },
}
local SKIN = { Color3.fromRGB(234, 192, 160), Color3.fromRGB(198, 146, 110), Color3.fromRGB(141, 95, 64), Color3.fromRGB(92, 60, 40) }

function Court.npc(name: string, role: string, at: Vector3): Model?
	local ok, model = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		local o = OUTFITS[role]
		local top = if o then o[1] else Color3.fromHSV(math.random(), 0.35, 0.45 + math.random() * 0.35)
		local legs = if o then o[2] else Color3.fromHSV(math.random(), 0.25, 0.25 + math.random() * 0.3)
		desc.TorsoColor, desc.LeftArmColor, desc.RightArmColor = top, top, top
		desc.LeftLegColor, desc.RightLegColor = legs, legs
		desc.HeadColor = SKIN[math.random(1, #SKIN)]
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		warn("[Court] couldn't make an NPC: " .. tostring(model))
		return nil
	end
	model.Name = name
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayName = name
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		hum.NameDisplayDistance = 40
		hum.WalkSpeed = 11
	end
	model:SetAttribute("CourtNPC", role)
	model:PivotTo(CFrame.new(at + Vector3.new(0, 3, 0)))
	model.Parent = workspace
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		pcall(function() root:SetNetworkOwner(nil) end)
	end
	return model
end

-- walk an NPC to a goal (pathfinding; it's placed there if it gets stuck)
function Court.walk(model: Model?, goal: Vector3, timeout: number?): string
	local hum = model and model:FindFirstChildOfClass("Humanoid")
	local root = model and model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (hum and root and model) then return "no npc" end
	hum.Sit = false
	local deadline = os.clock() + (timeout or 40)
	local path = PathfindingService:CreatePath({ AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false })
	local ok = pcall(function() path:ComputeAsync(root.Position, goal) end)
	local points = if ok and path.Status == Enum.PathStatus.Success then path:GetWaypoints() else {}
	if #points == 0 then points = { { Position = goal } } :: any end
	for _, wp in points do
		if os.clock() > deadline or not model.Parent then break end
		hum:MoveTo(wp.Position)
		local t0 = os.clock()
		while model.Parent and (root.Position - wp.Position).Magnitude > 3.5 and os.clock() - t0 < 4 and os.clock() < deadline do
			task.wait(0.1)
		end
	end
	if model.Parent and (root.Position - goal).Magnitude > 6 then
		model:PivotTo(CFrame.new(goal + Vector3.new(0, 3, 0)))
		return "placed"
	end
	return "walked"
end

-- sit an NPC (or a player's humanoid) on a seat marker
function Court.seat(model: Model?, seatName: string, venue: Instance?): boolean
	local s = spot(seatName)
	if venue then
		local v = venue:FindFirstChild(seatName)
		s = if v and v:IsA("BasePart") then v else nil
	end
	local hum = model and model:FindFirstChildOfClass("Humanoid")
	if not (s and s:IsA("Seat") and hum and model) then return false end
	if s.Occupant and s.Occupant ~= hum then return false end
	model:PivotTo(s.CFrame * CFrame.new(0, 2.5, 0))
	task.wait()
	s:Sit(hum)
	return true
end

---------------------------------------------------------------------------
-- talking (the PhoneCalls dialog card) and billing
---------------------------------------------------------------------------
-- v290g: every court card runs on a visible clock and answers itself when it runs out - nobody
-- can stall the court forever. The clock is long enough to READ: ~2.5 words a second over the
-- whole card, plus time to weigh it up when there's a real choice (25 s at least).
local function readTime(lines: { string }, options: { string }, minimum: number?): number
	local words = 0
	for _, l in lines do words += #string.split(tostring(l), " ") end
	for _, o in options do words += #string.split(tostring(o), " ") end
	local choice = #options > 1
	local t = words / 2.5 + (if choice then 12 + 2 * #options else 3)
	return math.clamp(math.floor(t), minimum or (if choice then 25 else 8), if choice then 75 else 35)
end
Court.readTime = readTime
-- silence = `default` (an index; the last option when not given - in this court the last one is
-- the cautious / passive one)
local function card(player: Player, from: string, lines: { string }, options: { string }, default: number?): number?
	local f = ServerStorage:FindFirstChild("Phone")
	if not (f and f:IsA("BindableFunction")) then return nil end
	local ok, how, idx = pcall(f.Invoke, f, "dialog", player, { from = from, lines = lines, options = options,
		seconds = readTime(lines, options), silent = default or #options })
	if ok and how == "answered" then return idx end
	return nil
end
Court.card = card

local function bill(player: Player, activity: string, complexity: number?)
	local law = ServerStorage:FindFirstChild("LawFirms")
	if law and law:IsA("BindableFunction") then
		pcall(law.Invoke, law, "bill", player, activity, complexity)
	end
end

-- v270: CityLife (jury tampering, bought judges, investigators, the news) - nil when it isn't running
local function cityLife(name: string, ...: any): any
	local f = ServerStorage:FindFirstChild("CityLifeApi")
	if f and f:IsA("BindableFunction") then
		local ok, r = pcall(f.Invoke, f, name, ...)
		if ok then return r end
	end
	return nil
end

local function counselOf(player: Player): (string, number)
	local firm = tostring(player:GetAttribute("LawyerFirm") or player:GetAttribute("CounselName") or "Public Defender")
	return firm, FIRM_TIER[firm] or 1
end
Court.counselOf = counselOf

local function isCapital(text: string): boolean
	local t = text:lower()
	return t:find("death row", 1, true) ~= nil or t:find("5 police", 1, true) ~= nil or t:find("five police", 1, true) ~= nil
end

-- the State's evidence, built from the real arrest and interview
-- v286: the case file (CityLife.CaseFile): what happened, where, when, to whom - so the court
-- names the defendant and pins them down instead of reading a generic charge list
local SEVERITY = { CopKilled = 9, Murder = 8, BankRobbery = 7, Kidnapping = 7, AssaultOfficer = 6, Robbery = 6, ShotsFired = 5,
	VehicleTheft = 4, Burglary = 4, Drugs = 4, EvadingPolice = 3, Assault = 3, DUI = 3, PlateTheft = 2 }
local function crimesOf(file: any): { any }
	local out = {}
	for _, e in file.entries do
		if e.charge then table.insert(out, e) end
	end
	table.sort(out, function(a, b) return (SEVERITY[a.key] or 1) > (SEVERITY[b.key] or 1) end)
	return out
end
local function deed(e: any): string
	local k = e.key
	if k == "VehicleTheft" then
		return if e.car then ("took %s%s"):format(e.car, if e.owner then " from its owner, " .. e.owner else "") else "stole a car"
	elseif k == "Murder" then return ("killed %s"):format(e.victim or "a man")
	elseif k == "CopKilled" then return ("shot and killed %s"):format(e.victim or "a police officer")
	elseif k == "Assault" or k == "AssaultOnPress" then return ("attacked %s"):format(e.victim or "a bystander")
	elseif k == "AssaultOfficer" then return ("attacked %s"):format(e.victim or "a police officer")
	elseif k == "ShotsFired" then return ("fired %s in public"):format(if e.weapon then "a " .. e.weapon else "a gun")
	elseif k == "BankRobbery" then return "breached the vault and robbed the bank"
	elseif k == "Robbery" then return ("committed an armed robbery%s"):format(if e.weapon then " with a " .. e.weapon else "")
	elseif k == "Burglary" then return "broke into a home"
	elseif k == "EvadingPolice" then return ("ran from a traffic stop%s"):format(if e.car then " in " .. e.car else "")
	elseif k == "DUI" then return ("drove %s%s"):format(e.car or "a car", if e.bac then (" with a blood alcohol of %.3f"):format(e.bac) else " impaired")
	elseif k == "PlateTheft" then return ("drove %s on stolen plates"):format(e.car or "a car")
	elseif k == "Drugs" then return "sold drugs"
	end
	return ("committed %s"):format(string.lower(e.charge or "a crime"))
end
local function countLines(file: any?, text: string): { string }
	if not file then return { ("Charges: %s."):format(text) } end
	local out, seen = {}, {}
	for _, e in crimesOf(file) do
		local key = e.charge .. (e.car or e.victim or "")
		if not seen[key] and #out < 4 then
			seen[key] = true
			table.insert(out, ("Count %d: %s - at %s near %s, the defendant %s."):format(#out + 1, e.charge, e.at, e.place, deed(e)))
		end
	end
	if #out == 0 then out = { ("Charges: %s."):format(text) } end
	return out
end

local function evidence(text: string, iv: any?, file: any?): { { line: string, kind: string } }
	local list = {}
	if file then
		-- v286q: only what really exists, strongest first
		local b = file.brief
		if b and b.evidence and #b.evidence > 0 then
			local items = table.clone(b.evidence)
			table.sort(items, function(x, y) return x.weight > y.weight end)
			local who = file.defendant
			local KIND = { dashcam = "video", bodycam = "video", cctv = "video", news = "video", witness = "witness", owner = "witness", prints = "forensics", caught = "officer" }
			for i = 1, math.min(3, #items) do
				local x = items[i]
				local line = if x.kind == "caught" then ("%s testifies: %s - %s."):format(file.officer, b.happened, x.text)
					elseif x.kind == "owner" or x.kind == "witness" then ("The State calls %s. They point at %s."):format(x.text, who)
					elseif x.kind == "prints" then ("Forensics: %s match %s."):format(x.text, who)
					else ("The State plays %s: %s"):format(x.text, b.happened)
				table.insert(list, { line = line, kind = KIND[x.kind] or "officer" })
			end
			if iv and iv.confessed then
				table.insert(list, 1, { line = ("The recording from the interview room: %s admitting to it."):format(who), kind = "statement" })
			end
			while #list > 3 do table.remove(list) end
			while #list < 3 do
				table.insert(list, { line = ("%s's written report - and that's all the State has."):format(file.officer), kind = "officer" })
			end
			return list
		end
		local crimes = crimesOf(file)
		local e = crimes[1]
		if e then
			local who = file.defendant
			table.insert(list, { kind = "officer", line = ("%s testifies: at %s, near %s, %s %s."):format(file.officer, e.at, e.place, who, deed(e)) })
			-- what put them there: a camera, a plate reader, the interview, or the cruiser's camera
			local alpr = nil
			for _, x in file.entries do if x.key == "ALPR" then alpr = x end end
			if iv and iv.confessed then
				table.insert(list, { kind = "statement", line = ("The recording from the interview room: %s admitting to it."):format(who) })
			elseif e.camera then
				table.insert(list, { kind = "video", line = ("Security footage from %s at %s shows %s%s."):format(e.camera, e.at, who, if e.weapon then " holding a " .. e.weapon else "") })
			elseif alpr then
				table.insert(list, { kind = "video", line = ("A plate reader logged %s near %s at %s - the car %s was in."):format(alpr.car or "the car", alpr.place, alpr.at, who) })
			else
				table.insert(list, { kind = "video", line = ("Dash-camera footage from %s's cruiser puts %s near %s at %s."):format(file.officer, who, e.place, e.at) })
			end
			-- the witness
			if e.owner then
				table.insert(list, { kind = "witness", line = ("%s, the car's registered owner, takes the stand and points at %s."):format(e.owner, who) })
			elseif e.victim and not e.victimOfficer and e.key ~= "Murder" then
				table.insert(list, { kind = "witness", line = ("%s, the victim, takes the stand and identifies %s."):format(e.victim, who) })
			elseif iv and iv.named and #iv.named > 0 then
				table.insert(list, { kind = "witness", line = ("A sworn statement from %s naming %s."):format(tostring(iv.named[1]), who) })
			elseif e.witness then
				table.insert(list, { kind = "witness", line = ("%s saw it happen near %s and testifies against %s."):format(e.witness, e.place, who) })
			elseif (e.witnesses or 0) > 0 then
				table.insert(list, { kind = "witness", line = ("One of %d bystanders near %s picked %s out of a line-up."):format(e.witnesses, e.place, who) })
			else
				table.insert(list, { kind = "witness", line = ("Forensics: prints and DNA from %s match %s."):format(e.place, who) })
			end
			return list
		end
	end
	local first = (text:split(",")[1] or text):gsub("^%s+", "")
	table.insert(list, { line = ("The arresting officer testifies: you were taken into custody for %s."):format(first), kind = "officer" })
	if iv and iv.confessed then
		table.insert(list, { line = "The recording of your statement in the interview room.", kind = "statement" })
	else
		table.insert(list, { line = "Body-camera and dash-camera footage of the arrest.", kind = "video" })
	end
	local t = text:lower()
	if iv and iv.named and #iv.named > 0 then
		table.insert(list, { line = ("A sworn statement from %s naming you."):format(tostring(iv.named[1])), kind = "witness" })
	elseif t:find("bank", 1, true) or t:find("robbery", 1, true) then
		table.insert(list, { line = "Security footage from inside the bank, and the vault's alarm log.", kind = "video" })
	elseif t:find("murder", 1, true) or t:find("assault", 1, true) then
		table.insert(list, { line = "The medical examiner's report and a witness who saw it.", kind = "witness" })
	else
		table.insert(list, { line = "An eyewitness who picked you out of a line-up.", kind = "witness" })
	end
	return list
end

-- how strong the State's case is (0..1): the chance a neutral judge convicts
local function caseStrength(ctx: any, tier: number, prepared: boolean): number
	local iv = ctx.interview
	-- v286q: what they really have (CityLife.CaseFile: cameras, witnesses, caught in the act...)
	local e = if ctx.file and ctx.file.strength then ctx.file.strength else 0.5 + 0.05 * math.clamp(tonumber(ctx.stars) or 1, 0, 6)
	if iv then
		if iv.confessed then e += 0.25 end
		if iv.lawyered then e -= 0.05 end
		if iv.violation then e -= 0.2 end -- a detective crossed the line: the statement is tainted
		if iv.named and #iv.named > 0 then e += 0.03 end
	end
	if prepared then e -= 0.05 end
	e -= 0.03 * (tier - 1)
	return math.clamp(e, 0.1, 0.95)
end

---------------------------------------------------------------------------
-- v290g: THE ROOM - a live transcript for everyone watching (the gallery, Channel 8), the
-- people in it moving like a real court (counsel at the podium, the jury rail, the witness,
-- sidebars at the bench), the families and the press, and choices built from the case itself
---------------------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local feedRemote: RemoteEvent = (ReplicatedStorage:FindFirstChild("CourtFeed") :: RemoteEvent?) or (function()
	local r = Instance.new("RemoteEvent")
	r.Name = "CourtFeed"
	r.Parent = ReplicatedStorage
	return r
end)()
-- every line said in the courtroom goes to everyone but the defendant (who has the cards); the
-- client shows it when they're in the courthouse or watching the case live on Channel 8
-- (v290h: `big` = Channel 8 carries it live to the whole city; `at` = the courtroom, so people in
-- the building see it too)
local feedMeta: { [Player]: any } = {}
function Court.feed(defendant: Player, case: string, speaker: string, lines: { string }, kind: string?)
	local meta = feedMeta[defendant] or {}
	local payload = { case = case, speaker = speaker, lines = lines, kind = kind or "line", big = meta.big == true, at = meta.at }
	for _, p in Players:GetPlayers() do
		if p ~= defendant then feedRemote:FireClient(p, payload) end
	end
end

-- a speech bubble over someone in the room
function Court.say(m: Model?, text: string, secs: number?, color: Color3?)
	local head = m and m:FindFirstChild("Head")
	if not head then return end
	local old = head:FindFirstChild("CourtSpeech")
	if old then old:Destroy() end
	local b = Instance.new("BillboardGui")
	b.Name = "CourtSpeech"
	b.Size = UDim2.fromOffset(300, 64)
	b.StudsOffset = Vector3.new(0, 3, 0)
	b.MaxDistance = 90
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = color or Color3.new(1, 1, 1)
	t.BackgroundTransparency = 0.08
	t.TextColor3 = Color3.fromRGB(20, 20, 24)
	t.Font = Enum.Font.GothamMedium
	t.TextScaled = true
	t.Text = if #text > 150 then text:sub(1, 147) .. "..." else text
	Instance.new("UICorner").Parent = t
	t.Parent = b
	b.Parent = head
	task.delay(secs or math.clamp(#text / 14, 3, 9), function() if b.Parent then b:Destroy() end end)
end
-- a few people react at once (the families at the verdict, the gallery at an outburst)
function Court.react(list: { Model }, lines: { string }, color: Color3?)
	for _, m in list do
		task.delay(math.random() * 1.6, function()
			if m.Parent then Court.say(m, lines[math.random(1, #lines)], 5, color) end
		end)
	end
end

-- where counsel stand in the well of the court, worked out from the courtroom's own seats
function Court.well(spotFn: (string) -> BasePart?): any?
	local judge, def, pros, wit = spotFn("JudgeSeat"), spotFn("DefenseSeat"), spotFn("ProsecutorSeat"), spotFn("WitnessSeat")
	if not (judge and def and pros) then return nil end
	local y = def.Position.Y - 1
	local function flat(v: Vector3): Vector3 return Vector3.new(v.X, y, v.Z) end
	local mid = (def.Position + pros.Position) / 2
	local toBench = (judge.Position - mid) * Vector3.new(1, 0, 1)
	local j1, j12 = spotFn("JurorSeat1"), spotFn("JurorSeat12")
	local jc = if j1 and j12 then (j1.Position + j12.Position) / 2 else nil
	return {
		lectern = flat(mid + toBench * 0.42),
		bench = flat(mid + toBench * 0.78 + Vector3.new(5, 0, 0)),
		benchFace = judge.Position,
		jury = if jc then flat(jc:Lerp(mid, 0.45)) else nil,
		juryFace = jc,
		witness = if wit then flat(wit.Position:Lerp(mid, 0.4)) else nil,
		witnessFace = wit and wit.Position,
	}
end
local function moveTo(m: Model?, key: string, pos: Vector3?, face: Vector3?)
	if not (m and m.Parent and pos) or m:GetAttribute("CourtAt") == key then return end
	m:SetAttribute("CourtAt", key)
	task.spawn(function()
		Court.walk(m, pos, 10)
		local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and face and m:GetAttribute("CourtAt") == key then
			r.CFrame = CFrame.lookAt(r.Position, Vector3.new(face.X, r.Position.Y, face.Z))
		end
	end)
end
local function toSeat(m: Model?, seatName: string)
	if not (m and m.Parent) or m:GetAttribute("CourtAt") == "seat" or m:GetAttribute("CourtAt") == nil then return end
	m:SetAttribute("CourtAt", "seat")
	task.spawn(function()
		local s = spot(seatName)
		if s then Court.walk(m, s.Position, 10) end
		if m:GetAttribute("CourtAt") == "seat" then Court.seat(m, seatName) end
	end)
end
-- whoever is talking goes where they'd stand to say it. R = { pros, def, judge (Models), prosName,
-- defName, judgeName, spots = Court.well(), jury = bool }
function Court.block(R: any, from: string, lines: { string })
	if not (R and R.spots) then return end
	local S = R.spots
	local low = string.lower(from)
	local function starts(p: string?): boolean return p ~= nil and string.sub(from, 1, #p) == p end
	local who: Model? = if starts(R.prosName) then R.pros elseif starts(R.defName) then R.def else nil
	if who then
		local key, where, face
		if low:find("direct", 1, true) or low:find("cross", 1, true) or low:find("leaning over", 1, true) then
			key, where, face = "witness", S.witness, S.witnessFace
		elseif low:find("closing", 1, true) or low:find("for the state", 1, true) or low:find("opening", 1, true) or low:find("jury selection", 1, true) then
			if R.jury and S.jury then key, where, face = "jury", S.jury, S.juryFace else key, where, face = "lectern", S.lectern, S.benchFace end
		elseif low:find("penalty", 1, true) or low:find("bail", 1, true) or low:find("sentencing", 1, true) then
			key, where, face = "lectern", S.lectern, S.benchFace
		end
		if where then
			moveTo(who, key, where, face)
		elseif who == R.def then
			toSeat(R.def, "DefenseSeat") -- talking to the client: back at the table
		end
	elseif starts(R.judgeName) then
		-- the judge speaks: counsel go back to their tables - unless it's a ruling from a sidebar
		local text = table.concat(lines, " ")
		if not (text:find("Sustained", 1, true) or text:find("Overruled", 1, true)) then
			toSeat(R.pros, "ProsecutorSeat")
			toSeat(R.def, "DefenseSeat")
		end
	end
end
-- both counsel approach the bench (an objection, a motion)
function Court.sidebar(R: any, secs: number?)
	if not (R and R.spots) then return end
	local S = R.spots
	moveTo(R.pros, "bench", S.bench - Vector3.new(1.4, 0, 0), S.benchFace)
	moveTo(R.def, "bench", S.bench + Vector3.new(1.4, 0, 0), S.benchFace)
	task.wait(secs or 5)
end

-- the gallery: the defendant's people behind the defence table, the victim's family behind the
-- State's, uniformed officers when a cop died, the public - and the press in a big case
function Court.fillGallery(add: (Model?) -> Model?, info: any): any
	local out = { def = {}, vic = {}, press = {}, public = {}, all = {} }
	local function sit(i: number, name: string, role: string, list: { Model })
		local s = spot("GallerySeat" .. i)
		if not (s and s:IsA("Seat")) or s.Occupant then return end
		local m = add(Court.npc(name, role, s.Position + Vector3.new(0, 3, 0)))
		if m then
			Court.seat(m, "GallerySeat" .. i)
			table.insert(list, m)
			table.insert(out.all, m)
		end
	end
	local who = tostring(info.defendant or "the defendant")
	-- defence side = the seats on the defence table's side of the aisle
	local defSide, prosSide = {}, {}
	local d, p = spot("DefenseSeat"), spot("ProsecutorSeat")
	for i = 1, 80 do
		local s = spot("GallerySeat" .. i)
		if s and d and p then
			if (s.Position - d.Position).Magnitude < (s.Position - p.Position).Magnitude then table.insert(defSide, i) else table.insert(prosSide, i) end
		end
	end
	local DEF = { "%s's mother", "%s's younger brother", "%s's girlfriend", "%s's father", "%s's best friend" }
	for k = 1, math.min(#defSide, if info.big then 4 else 2) do sit(defSide[k], DEF[k]:format(who), "family", out.def) end
	if info.victim then
		local VIC = { "%s's mother", "%s's sister", "%s's husband", "%s's son", "%s's best friend" }
		for k = 1, math.min(#prosSide, if info.kills and info.kills > 0 then 5 else 2) do sit(prosSide[k], VIC[k]:format(info.victim), "family", out.vic) end
	end
	if info.copKill then
		for k = 6, math.min(#prosSide, 11) do sit(prosSide[k], "LVMPD officer", "bailiff", out.vic) end
	end
	-- the public: a few, more when it's a big case
	for _ = 1, if info.big then 8 else 3 do
		local list = if math.random() < 0.5 then defSide else prosSide
		local i = list[math.random(math.min(#list, 8), #list)]
		if i then sit(i, "Spectator", "public", out.public) end
	end
	if info.big then
		local back = {}
		for i = 71, 80 do table.insert(back, i) end
		local PRESS = { "Channel 8 reporter", "Court sketch artist", "Associated Press", "Las Vegas Review-Journal", "KTNV reporter" }
		for k, i in back do
			if k > #PRESS then break end
			sit(i, PRESS[k], "press", out.press)
		end
	end
	return out
end

-- the press pack outside: cameras, flashes and shouted questions round `at`. `questions` is a
-- list or a function giving one (it changes as the case goes on); `secs` is a duration or a
-- function that says whether they're still there. `follow` gives whoever they're after (nil =
-- nobody near: they wait, facing `toward`); when that person comes close the pack surges round
-- them - within `reach` studs of where they set up.
function Court.pressPack(at: Vector3, toward: Vector3, questions: { string } | () -> { string }, secs: number | () -> boolean,
	follow: (() -> Vector3?)?, reach: number?, count: number?): { Model }
	local pack = {}
	local homes: { Vector3 } = {}
	local dir = (toward - at) * Vector3.new(1, 0, 1)
	dir = if dir.Magnitude > 0.1 then dir.Unit else Vector3.new(0, 0, 1)
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local OUTLETS = { "Channel 8", "KTNV", "AP", "Review-Journal", "CNN", "Fox 5", "NBC 3" }
	for i = 1, math.clamp(count or 7, 1, 7) do
		local s = if i % 2 == 0 then 1 else -1
		local pos = at + dir * (2 + (i % 4) * 3) + side * s * (5 + (i % 3) * 2.5)
		local m = Court.npc(OUTLETS[i] .. (if i % 3 == 0 then " camera" else " reporter"), "press", pos)
		if m then
			table.insert(pack, m)
			table.insert(homes, pos)
			-- a camera on the shoulder (or a mic), with a flash
			local hand = m:FindFirstChild("RightHand") :: BasePart?
			if hand then
				local cam = Instance.new("Part")
				cam.Name = "PressCamera"
				cam.Size = if i % 3 == 0 then Vector3.new(0.9, 1, 2.2) else Vector3.new(0.35, 0.35, 1.1)
				cam.Color = Color3.fromRGB(25, 25, 28)
				cam.Material = Enum.Material.SmoothPlastic
				cam.CanCollide = false
				cam.Massless = true
				cam.CFrame = hand.CFrame * CFrame.new(0, 0.4, -0.6)
				cam.Parent = m
				local w = Instance.new("WeldConstraint")
				w.Part0, w.Part1 = hand, cam
				w.Parent = cam
				local flash = Instance.new("PointLight")
				flash.Name = "Flash"
				flash.Brightness = 0
				flash.Range = 14
				flash.Color = Color3.fromRGB(235, 240, 255)
				flash.Parent = cam
			end
		end
	end
	local t0 = os.clock()
	local function going(): boolean
		if type(secs) == "function" then return secs() end
		return os.clock() - t0 < (secs :: number)
	end
	local R = reach or 30
	local lastWho: Vector3? = nil
	local heading = dir
	task.spawn(function()
		while going() do
			local who = if follow then follow() else nil
			if who and (who - at).Magnitude > R + 30 then who = nil end
			-- which way they're walking (the pack backs off in front of them - never a wall)
			if who and lastWho then
				local v = (who - lastWho) * Vector3.new(1, 0, 1)
				if v.Magnitude > 1 then heading = v.Unit end
			elseif who then
				heading = dir
			end
			lastWho = who
			local target = who or toward
			for i, m in pack do
				if m.Parent then
					local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
					local hum = m:FindFirstChildOfClass("Humanoid")
					-- surge round them (a horseshoe open the way they're going), or drift back to the spot
					-- they staked out
					local goal = homes[i]
					if who then
						local a = ((i - 0.5) / #pack) * math.pi * 1.3 - math.pi * 0.65
						local ring = CFrame.lookAt(Vector3.zero, -heading):VectorToWorldSpace(Vector3.new(math.sin(a), 0, -math.cos(a)))
						local g = who + ring * (5.5 + (i % 2) * 1.5)
						local off = (g - at) * Vector3.new(1, 0, 1)
						if off.Magnitude > R then g = at + off.Unit * R end
						goal = Vector3.new(g.X, homes[i].Y, g.Z)
					end
					if hum and r and (r.Position - goal).Magnitude > 2.5 then
						hum.WalkSpeed = if who then 16 else 8
						hum:MoveTo(goal)
					elseif r then
						r.CFrame = CFrame.lookAt(r.Position, Vector3.new(target.X, r.Position.Y, target.Z))
					end
					local cam = m:FindFirstChild("PressCamera")
					local fl = cam and cam:FindFirstChild("Flash") :: PointLight?
					if fl and who and math.random() < 0.35 then
						fl.Brightness = 6
						task.delay(0.08, function() fl.Brightness = 0 end)
					end
				end
			end
			if who and math.random() < 0.45 and #pack > 0 then
				local q = if type(questions) == "function" then questions() else questions
				if #q > 0 then Court.say(pack[math.random(1, #pack)], q[math.random(1, #q)], 3) end
			end
			task.wait(0.6)
		end
		for _, m in pack do if m.Parent then m:Destroy() end end
	end)
	return pack
end

-- v290h: A BIG CASE ON BAIL - the press camps on the courthouse steps from the morning of the court
-- date: every arrival, every walk out for the night, and the walk out at the end (Bail starts it
-- when the check-in window opens; Court.run keeps it there for the whole trial)
local stakeouts: { [Player]: any } = {}
function Court.isBig(player: Player, text: string?, stars: number?): boolean
	local t = string.lower(tostring(text or player:GetAttribute("CaseCharges") or ""))
	if t:find("murder", 1, true) or t:find("officer", 1, true) or t:find("bank", 1, true) or t:find("kidnap", 1, true) then return true end
	if (tonumber(stars) or 0) >= 4 or (tonumber(player:GetAttribute("PoliceOfficersKilled")) or 0) > 0 then return true end
	local api = ServerStorage:FindFirstChild("CityLifeApi")
	if api and api:IsA("BindableFunction") then
		local ok, f = pcall(api.Invoke, api, "caseFile", player)
		if ok and type(f) == "table" and f.entries then
			for _, e in f.entries do
				if e.charge and (SEVERITY[e.key] or 1) >= 7 then return true end
			end
		end
	end
	return false
end
local function pressQuestions(S: any): { string }
	local who, v = S.who, S.victim
	if S.phase == "after" then
		if S.verdict == "not guilty" or S.verdict == "dismissed" then
			return { ("%s! How does it feel to walk out of there?"):format(who), "Do you think justice was done today?",
				if v then ("What do you say to %s's family?"):format(v) else "What do you say to the people who think you did it?",
				"Are you going to sue the city?", "Who are you thanking tonight?", "Will you leave Las Vegas?" }
		end
		return { "Any last words before they take you?", "Are you going to appeal?", "Did your lawyer let you down?" }
	elseif S.phase == "trial" then
		return { ("%s! How do you think it's going?"):format(who), "Are you going to take the stand?", "Did you see the family in there?",
			"Is it true the State has video?", "Has the DA offered you a deal?", "Do you trust this jury?",
			if v then ("Do you have anything to say about %s?"):format(v) else "Did you do it?" }
	end
	return { ("%s! Did you do it?"):format(who), "Anything to say to the family?", "Look over here!", "How do you plead?",
		"Who's paying for your lawyer?", if v then ("Why %s?"):format(v) else "Are you going to plead guilty?", "Are you going to testify?" }
end
function Court.stakeout(player: Player, info: any?): boolean
	info = info or {}
	local S = stakeouts[player]
	if S then
		S.stopAt = math.max(S.stopAt, os.clock() + (tonumber(info.secs) or 600))
		return true
	end
	if not (info.force or Court.isBig(player, info.text, info.stars)) then return false end
	local steps = spot("CourthouseSteps")
	if not steps then return false end
	local inside = spot("RotundaSpot")
	local doorDir = if inside then ((inside.Position - steps.Position) * Vector3.new(1, 0, 1)).Unit else Vector3.new(0, 0, -1)
	-- they set up on the pavement below the steps, facing the doors
	local at = steps.Position - doorDir * 12
	do
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { player.Character :: Instance }
		local h = workspace:Raycast(at + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), rp)
		if h then at = h.Position end
	end
	local file = cityLife("caseFile", player)
	local top = if file then crimesOf(file)[1] else nil
	S = { phase = "before", stopAt = os.clock() + (tonumber(info.secs) or 600), who = tostring(player:GetAttribute("CharacterName") or player.DisplayName),
		victim = top and not top.victimOfficer and top.victim or nil }
	stakeouts[player] = S
	print(("[Court] PRESS STAKEOUT %s at the courthouse steps"):format(player.Name))
	Court.pressPack(at, steps.Position, function() return pressQuestions(S) end, function()
		local on = player.Parent ~= nil and os.clock() < S.stopAt
		if not on and stakeouts[player] == S then stakeouts[player] = nil end
		return on
	end, function()
		local c = player.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		return r and r.Position
	end, 34)
	return true
end
-- the story moves on: "trial" while it's being heard, "after" (with the verdict) on the way out
function Court.stakeoutPhase(player: Player, phase: string, verdict: string?, secs: number?)
	local S = stakeouts[player]
	if not S then return end
	S.phase, S.verdict = phase, verdict
	if secs then S.stopAt = os.clock() + secs end
end

-- the case in a few facts, and choices made from them. Choices carry a category the trial's
-- logic understands (the opening theory: 1 doubt / 2 identity / 3 justified or a lesser crime;
-- the closing: 1 doubt / 2 wrong person / 3 sympathy / 4 concede the small stuff).
local LESSER = {
	Murder = "manslaughter", CopKilled = "manslaughter", Robbery = "theft", BankRobbery = "burglary",
	VehicleTheft = "joyriding", DUI = "reckless driving", Assault = "disorderly conduct", AssaultOfficer = "resisting arrest",
	Drugs = "simple possession", EvadingPolice = "failure to yield", Burglary = "trespassing", ShotsFired = "discharging a firearm in city limits",
}
Court.LESSER = LESSER
local function pick(pool: { any }, n: number): { any }
	local copy = table.clone(pool)
	for i = #copy, 2, -1 do
		local j = math.random(1, i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	local out = {}
	for i = 1, math.min(n, #copy) do table.insert(out, copy[i]) end
	return out
end
function Court.choices(kind: string, F: any): { any }
	local key, place, victim, weapon, car, owner = F.key, F.place or "the scene", F.victim, F.weapon, F.car, F.owner
	local gun = weapon or "gun"
	local hole = if F.night then ("it was dark, at %s"):format(F.at or "night")
		elseif not F.camera then "there's no video of it"
		elseif not F.witness then "nobody actually saw it happen"
		else "they rushed the whole investigation"
	if kind == "theory" then
		local pool: { any } = { { text = ("Reasonable doubt - %s"):format(hole), cat = 1 } }
		if key == "Murder" or key == "CopKilled" then
			if key == "CopKilled" then
				table.insert(pool, { text = "He never said he was police - I thought I was being robbed", cat = 3 })
			else
				table.insert(pool, { text = ("Self-defense - %s came at me first"):format(victim or "he"), cat = 3, poor = (F.kills or 1) > 1 })
			end
			table.insert(pool, { text = ("An accident - the %s went off"):format(gun), cat = 3 })
			table.insert(pool, { text = "Heat of the moment - it's manslaughter, not murder", cat = 3 })
			table.insert(pool, { text = ("Wrong person - I was never at %s"):format(place), cat = 2 })
			if (F.kills or 0) >= 2 then table.insert(pool, { text = "I wasn't in my right mind - not guilty by reason of insanity", cat = 3 }) end
		elseif key == "VehicleTheft" then
			table.insert(pool, { text = ("I was borrowing it - %s knows me"):format(owner or "the owner"), cat = 3 })
			table.insert(pool, { text = ("I never touched the %s"):format(car or "car"), cat = 2 })
			table.insert(pool, { text = "It was running with the keys in it - I moved it, I didn't steal it", cat = 3 })
		elseif key == "Robbery" or key == "BankRobbery" then
			table.insert(pool, { text = "Duress - somebody made me do it", cat = 3 })
			table.insert(pool, { text = "The robber wore a mask - it wasn't me", cat = 2 })
			table.insert(pool, { text = if weapon then ("The %s was never loaded - nobody was in danger"):format(weapon) else "Nobody was ever threatened", cat = 3 })
		elseif key == "Assault" or key == "AssaultOfficer" then
			table.insert(pool, { text = ("Self-defense - %s swung first"):format(victim or "he"), cat = 3 })
			table.insert(pool, { text = "A mutual fight - we both went at it", cat = 3 })
			table.insert(pool, { text = ("Wrong person - it was a crowd at %s"):format(place), cat = 2 })
		elseif key == "DUI" then
			table.insert(pool, { text = "The breath machine was out of calibration", cat = 3 })
			table.insert(pool, { text = "I wasn't drunk - I was exhausted", cat = 3 })
			table.insert(pool, { text = "I wasn't the one driving", cat = 2 })
		elseif key == "EvadingPolice" then
			table.insert(pool, { text = "I never saw the lights - the music was up", cat = 3 })
			table.insert(pool, { text = "I was scared - I was looking for somewhere safe to stop", cat = 3 })
			table.insert(pool, { text = ("Somebody else had the %s that night"):format(car or "car"), cat = 2 })
		elseif key == "Drugs" then
			table.insert(pool, { text = "Personal use - I was never selling", cat = 3 })
			table.insert(pool, { text = "They're not mine - they were planted", cat = 2 })
		elseif key == "Burglary" then
			table.insert(pool, { text = "I was invited in - I know the owner", cat = 3 })
			table.insert(pool, { text = "I went in for shelter - I took nothing", cat = 3 })
			table.insert(pool, { text = "Wrong house, wrong person", cat = 2 })
		elseif key == "ShotsFired" then
			table.insert(pool, { text = "Warning shots - I was being threatened", cat = 3 })
			table.insert(pool, { text = ("That %s isn't mine"):format(gun), cat = 2 })
		else
			table.insert(pool, { text = "Mistaken identity - it wasn't me", cat = 2 })
			table.insert(pool, { text = "It's not what they're saying it was", cat = 3 })
		end
		local out = pick(pool, 3)
		table.insert(out, { text = "Reserve our opening - see their case first", cat = 4 })
		return out
	elseif kind == "closing" then
		local lesser = LESSER[key or ""] or "a lesser charge"
		local out = pick({
			{ text = ("Hammer the holes - %s"):format(hole), cat = 1 },
			{ text = ("They have the wrong person - nothing puts me at %s"):format(place), cat = 2 },
			{ text = if victim and (key == "Murder" or key == "CopKilled") then ("Nobody wins today - %s is gone, and another life in a cell won't bring them back"):format(victim)
				elseif F.family then "Look behind me - my family is here. I'm a person, not a case file"
				else "Sympathy - a person, not a case number", cat = 3 },
			{ text = ("Admit the small stuff, fight the big charge - this is %s at most"):format(lesser), cat = 4 },
		}, 4)
		return out
	elseif kind == "defense" then
		local EXPERT = {
			Murder = { "A forensic pathologist", "the angle of the wound says the other man was reaching for something" },
			CopKilled = { "A use-of-force expert", "the officer never announced himself before he drew" },
			DUI = { "A breath-test technician", "that machine failed its last two calibration checks" },
			Drugs = { "A crime-lab chemist", "the amount found is consistent with personal use" },
			VehicleTheft = { "A locksmith", "nothing on that car was forced - it was opened with a key" },
			Robbery = { "An eyewitness-memory expert", "under stress, witnesses pick the wrong face about a third of the time" },
			BankRobbery = { "A video analyst", "at that resolution nobody can identify a face" },
		}
		local ex = EXPERT[key or ""] or { "A forensic expert", "the State's evidence doesn't prove what they say it proves" }
		local rel = if F.family then "your mother" else "a family friend"
		local out = {
			{ text = ("Call %s - a character witness"):format(rel), act = 1, name = if F.family then "The defendant's mother" else "A family friend" },
			{ text = ("Call %s - \"%s\""):format(string.lower(ex[1]), ex[2]), act = 5, name = ex[1], says = ex[2] },
		}
		if F.theory == 2 or math.random() < 0.5 then
			table.insert(out, { text = ("Call an alibi witness - someone who'll say you weren't at %s"):format(place), act = 2 })
		end
		table.insert(out, { text = "Testify yourself - tell them your side", act = 3 })
		table.insert(out, { text = "Rest - they haven't proved it", act = 4 })
		return out
	elseif kind == "testimony" then
		local where = pick({ "at my sister's place", "working a double shift", "at the tables at the Bellagio", "home asleep", "at the gym across town" }, 1)[1]
		local there = if key == "Murder" then ("\"I was there. %s pulled a %s on me first.\""):format(victim or "He", gun)
			elseif key == "VehicleTheft" then ("\"I was there. %s said I could take it.\""):format(owner or "The owner")
			elseif key == "Robbery" or key == "BankRobbery" then "\"I was there. But I didn't plan it, and I never hurt anybody.\""
			elseif key == "DUI" then "\"I was driving. But I'd had one drink, hours before.\""
			elseif key == "EvadingPolice" then "\"I was driving. I panicked when I saw the lights.\""
			else "\"I was there. But it didn't happen the way they say.\""
		local sorry = if key == "Murder" or key == "CopKilled" then "\"I never meant for anybody to die. I think about it every night.\""
			elseif key == "DUI" then "\"I should never have gotten behind that wheel.\""
			elseif victim then ("\"I'm sorry, %s. I panicked.\""):format(victim)
			else "\"I panicked. I never meant for any of it to happen.\""
		return {
			{ text = ("\"Nowhere near %s. I was %s.\""):format(place, where), story = "away" },
			{ text = there, story = "there" },
			{ text = sorry, story = "sorry" },
			{ text = "[Say nothing]", story = "silent" },
		}
	end
	return {}
end

-- v290h: the facts of a case file in one table (Court.choices reads it; so do the lawyer's office
-- meetings and the mock trial in LawFirms)
function Court.facts(file: any?): any
	local top = if file then crimesOf(file)[1] else nil
	local F: any = { key = top and top.key, place = top and top.place or "the scene", at = top and top.at or "that night",
		victim = top and top.victim, weapon = top and top.weapon, car = top and top.car, owner = top and top.owner,
		kills = 0, copKill = false, camera = false, witness = false, caught = false, identified = false,
		strength = tonumber(file and file.strength) or 0.5 }
	for _, e in (if file then file.entries else {}) do
		if e.key == "Murder" or e.key == "CopKilled" then F.kills += 1 end
		if e.key == "CopKilled" then F.copKill = true end
	end
	for _, x in (file and file.brief and file.brief.evidence or {}) do
		if x.kind == "dashcam" or x.kind == "cctv" or x.kind == "news" or x.kind == "bodycam" then F.camera = true end
		if x.kind == "owner" or x.kind == "witness" then F.witness = true end
		if x.kind == "caught" or x.kind == "bodycam" then F.caught = true end
		if x.kind == "owner" or x.kind == "witness" or x.kind == "bodycam" or x.kind == "caught" then F.identified = true end
	end
	local L = game:GetService("Lighting")
	F.night = L.ClockTime >= 20 or L.ClockTime < 6
	F.big = F.kills > 0 or (top ~= nil and (SEVERITY[top.key] or 1) >= 7)
	return F
end

-- v290h: how a defence theory plays to a panel of `n` ordinary people, given the facts. The same
-- reading the real trial uses (identity is hopeless when they caught you at the scene; doubt is
-- strong when there's no video and the case is thin). `extra` = how the practice testimony went.
-- -> (votes to acquit, what the jurors said)
function Court.mockJury(F: any, cat: number, extra: number?, n: number?): (number, { string })
	local fit, why = 0, {}
	if cat == 1 then
		fit = if F.strength < 0.5 then -0.12 else 0.04
		if not F.camera then fit -= 0.05; table.insert(why, "There's no video. I kept waiting for the proof.") end
		if F.camera then table.insert(why, "The video was hard to argue with.") end
	elseif cat == 2 then
		fit = if F.caught then 0.22 elseif F.identified then 0.12 else -0.1
		if F.caught then table.insert(why, "They arrested you right there. How is that the wrong person?")
		elseif F.identified then table.insert(why, "The witness pointed straight at you. That stuck with me.")
		else table.insert(why, "Nobody actually saw a face. I couldn't be sure.") end
	elseif cat == 3 then
		fit = if F.kills > 0 then -0.03 else -0.06
		if F.poor then fit += 0.12; table.insert(why, "Self-defense? Against that many people? No.")
		elseif F.kills > 0 then table.insert(why, "Something went wrong that night. I'm not sure it was murder.")
		else table.insert(why, "It sounded like it got out of hand. Not like a plan.") end
	else
		table.insert(why, "The defense never really told us anything.")
	end
	if F.witness and cat ~= 2 then table.insert(why, "The witness seemed sure.") end
	if (extra or 0) > 0.03 then table.insert(why, "When you testified, you lost me.")
	elseif (extra or 0) < -0.03 then table.insert(why, "I believed you on the stand.") end
	local p = math.clamp(F.strength + fit + (extra or 0), 0.05, 0.95)
	local acquit = 0
	for _ = 1, n or 6 do
		if math.random() >= math.clamp(p + (math.random() - 0.5) * 0.3, 0, 1) then acquit += 1 end
	end
	return acquit, why
end

---------------------------------------------------------------------------
-- v290i: REAL PLAYERS AS WITNESSES. The case file remembers a player who saw the crime
-- (CaseFile: witnessId on the entry, playerId on its evidence). When the case goes to trial a
-- detective phones them: will they testify? Yes = they're on the State's list; when the State
-- calls them and they're in the courthouse they take the stand and answer in their own words,
-- then the defence cross-examines and THEY decide whether to hold firm. No / not there = the
-- State has to do without (or reads their statement from the night, which counts for less).
---------------------------------------------------------------------------
local DETECTIVES = { "Detective Ana Morales", "Detective Ray Kowalski", "Detective Dana Whitfield", "Detective Luis Ortega" }
function Court.askWitnesses(defendant: Player, file: any?, RM: any)
	RM.pw = RM.pw or {}
	local phone = ServerStorage:FindFirstChild("Phone")
	if not (file and phone and phone:IsA("BindableFunction")) then return end
	for _, e in file.entries or {} do
		for _, x in e.evidence or {} do
			local id = x.playerId
			if id and RM.pw[id] == nil then
				local wp = Players:GetPlayerByUserId(id)
				if wp and wp ~= defendant then
					RM.pw[id] = "asked"
					task.spawn(function()
						local det = DETECTIVES[math.random(1, #DETECTIVES)] .. ", LVMPD"
						local ok, how, idx = pcall(phone.Invoke, phone, "call", wp, { from = det, kind = "court", expires = 600, lines = {
							("At %s, near %s, you saw %s %s."):format(e.at or "that night", e.place or "the scene", RM.who, deed(e)),
							("The State of Nevada v. %s is going to trial at the Clark County Courthouse."):format(RM.who),
							"Will you testify? If you will, come to the courthouse - the bailiff will call you to the stand when the State presents its case.",
						}, options = { "Yes - I'll testify", "I didn't see anything", "I'm not getting involved" } })
						local yes = ok and how == "answered" and idx == 1
						RM.pw[id] = if yes then "yes" else "no"
						if yes then wp:SetAttribute("CourtWitnessFor", RM.case) end
						print(("[Court] WITNESS %s asked about %s's case: %s"):format(wp.Name, defendant.Name, RM.pw[id]))
						Court.feed(defendant, RM.case, "Court", { if yes then "The State adds a new name to its witness list." else "One of the State's witnesses won't cooperate." }, "narration")
					end)
				end
			end
		end
	end
end

-- the State calls a player witness (x = their evidence item). dcard shows the defendant's cards
-- (and feeds the transcript). Returns how much it moved the case (+ = toward guilty).
function Court.playerWitness(defendant: Player, x: any, RM: any, T: any, prosecutor: string, counsel: string, dcard: any): number
	local wp = Players:GetPlayerByUserId(x.playerId)
	local status = RM.pw and RM.pw[x.playerId]
	local wname = if wp then tostring(wp:GetAttribute("CharacterName") or wp.DisplayName) else (string.match(x.text, "^(.-), who saw") or "The witness")
	local ws = spot("WitnessSeat")
	local wr = wp and wp.Character and wp.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = wp and wp.Character and wp.Character:FindFirstChildOfClass("Humanoid")
	if status ~= "yes" or not (wp and ws and wr and hum) or (wr.Position - ws.Position).Magnitude > 300 then
		local refused = status == "no"
		dcard(defendant, prosecutor, { if refused then ("The State's witness, %s, refused to testify. Their name comes off the list."):format(wname)
			else ("The State calls %s... who isn't in the courthouse. The State reads the statement they gave on the night instead."):format(wname) }, { "..." })
		if wp and not refused then wp:SetAttribute("CourtWitnessFor", nil) end
		return if refused then -x.weight * 0.35 else -x.weight * 0.15
	end
	-- to the stand
	dcard(defendant, "The courtroom", { ("The State calls %s."):format(wname), ("%s walks to the witness stand and takes the oath."):format(wname) }, { "..." })
	hum.Sit = false
	wp.Character:PivotTo(ws.CFrame * CFrame.new(0, 3, 0))
	task.wait(0.2)
	ws:Sit(hum)
	RM.witness = wp.Character
	local effect = 0
	-- their testimony, in their own words
	local opts = {
		("\"Yes. That's them - %s.\" (point at the defendant)"):format(RM.who),
		"\"I think it was them. It happened fast.\"",
		"\"I... I'm not sure anymore.\"",
		"\"I don't want to answer that.\"",
	}
	local a = card(wp, prosecutor .. " - direct examination", {
		("Q: Where were you at %s?"):format(T.at or "the time"),
		("Q: What did you see near %s?"):format(T.place or "the scene"),
		"Q: Is the person you saw in this courtroom today?",
	}, opts, 3) or 3
	Court.feed(defendant, RM.case, wname, { opts[a] }, "line")
	Court.say(wp.Character, opts[a], 6, Color3.fromRGB(255, 250, 220))
	if a == 1 then
		effect += x.weight * 0.8 + 0.06
		dcard(defendant, prosecutor .. " - direct examination", { ("%s points straight at you."):format(wname) }, { "..." })
	elseif a == 2 then
		effect += x.weight * 0.3
	elseif a == 3 then
		effect -= 0.05
		dcard(defendant, prosecutor, { "The prosecutor flips through the statement, frowning.", "\"...Nothing further.\"" }, { "..." })
	else
		effect -= 0.02
		card(wp, (RM.R and RM.R.judgeName) or "The judge", { "\"The witness will answer the question or be held in contempt.\"" }, { "..." })
	end
	-- the defence cross-examines: you choose the angle, the witness decides whether they hold
	local c = dcard(defendant, counsel, { ("\"%s is a real person, not a report. What do we hit them with?\""):format(wname) }, {
		"Their memory - it all happened in seconds",
		if T.victim then ("Their bias - do they know %s?"):format(T.victim) else "Their bias - why are they so keen to help the police?",
		"No questions",
	}, 3) or 3
	if c < 3 then
		local q = if c == 1 then "Q: You said it happened in seconds. How long did you actually see a face?"
			else "Q: You have your own reasons to want my client convicted, don't you?"
		local hold = card(wp, counsel .. " - cross-examination", { q }, { "Stand firm: \"I know what I saw.\"", "\"...A second or two, maybe.\"", "Lose your temper at the lawyer" }, 1) or 1
		local said = ({ "\"I know what I saw.\"", "\"...A second or two, maybe.\"", "(the witness snaps at the defence lawyer)" })[hold]
		Court.feed(defendant, RM.case, wname, { said }, "line")
		Court.say(wp.Character, said, 5, Color3.fromRGB(255, 250, 220))
		if hold == 1 then
			effect += 0.03
			dcard(defendant, counsel, { q, ("A: %s"):format(said), "Your lawyer couldn't shake them." }, { "..." })
		elseif hold == 2 then
			effect -= 0.08
			dcard(defendant, counsel, { q, ("A: %s"):format(said), "\"A second or two. Thank you. Nothing further.\"" }, { "..." })
		else
			effect -= 0.04
			dcard(defendant, counsel, { q, "The witness loses their temper on the stand. The jury sees it." }, { "..." })
		end
	end
	-- step down: to a seat in the gallery
	hum.Sit = false
	RM.witness = nil
	for i = 1, 80 do
		local s = spot("GallerySeat" .. i)
		if s and s:IsA("Seat") and not s.Occupant then
			wp.Character:PivotTo(s.CFrame * CFrame.new(0, 3, 0))
			break
		end
	end
	wp:SetAttribute("CourtWitnessFor", nil)
	local econ = ServerStorage:FindFirstChild("Economy")
	if econ and econ:IsA("BindableFunction") then pcall(econ.Invoke, econ, "AddCash", wp, 150) end -- the witness fee
	print(("[Court] PLAYER WITNESS %s in %s's case: answer %d, cross %d -> %.2f"):format(wp.Name, defendant.Name, a, c, effect))
	return effect
end

---------------------------------------------------------------------------
-- v291: THE PERP WALK after a custodial sentence. The cameras are waiting at the sally port where
-- the transport picks up (a full pack for a big case, a crew for any other felony), Channel 8 goes
-- live on the walk out (CityLife News "perpWalkStart"), and a reporter walks alongside and asks
-- one question - whatever you say (or don't) is the story ("perpWalk").
---------------------------------------------------------------------------
function Court.walkOutPress(player: Player, RM: any, result: any, drop: BasePart?, capital: boolean)
	if not drop then return end
	local big = RM.big == true or capital
	local who, v = RM.who, RM.victim
	local qs = {
		("%s! Any last words before they take you?"):format(who), "Are you going to appeal?", "Did your lawyer let you down?",
		if v then ("Anything to say to %s's family?"):format(v) else "Was the verdict fair?",
		if result.death then "How does it feel to be going to Death Row?" elseif result.life then "Life without parole - what's going through your head?"
			else ("%s inside - can you do that time?"):format(clock(result.secs or 0)),
		"Look over here!", "Who are you calling first?",
	}
	local function root(): BasePart?
		local c = player.Character
		return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	local t0 = os.clock()
	local near, awayAt = false, nil :: number?
	local function going(): boolean
		if not player.Parent or os.clock() - t0 > 300 then return false end
		local r = root()
		if r then
			local d = (r.Position - drop.Position).Magnitude
			if d < 40 then
				near, awayAt = true, nil
			elseif near and d > 150 then
				-- the transport has driven off with them
				awayAt = awayAt or os.clock()
				if os.clock() - (awayAt :: number) > 6 then return false end
			end
		end
		return true
	end
	local hold = spot("HoldingSpot")
	Court.pressPack(drop.Position, if hold then hold.Position else drop.Position + Vector3.new(0, 0, 10), qs, going,
		function() local r = root() return r and r.Position end, 30, if big then 7 else 3)
	cityLife("perpWalkStart", player, { pos = drop.Position, verdict = result.verdict, secs = result.secs, death = result.death, life = result.life, big = big, capital = capital })
	print(("[Court] PERP WALK %s: %s at the sally port"):format(player.Name, if big then "the press pack" else "a news crew"))
	-- the reporter's question as they come out
	task.spawn(function()
		while going() and not near do task.wait(0.5) end
		if not (near and player.Parent) then return end
		local q = if v then qs[4] elseif result.death or result.life then qs[5] else qs[1]
		local opts = {
			if v then ("\"Tell %s's family I'm sorry.\""):format(v) else "\"I'm sorry. To everyone I hurt.\"",
			"\"I'm innocent. We're appealing.\"",
			"\"That trial was a joke.\"",
			"\"No comment.\"",
			"[Keep your head down and keep walking]",
		}
		local i = Court.card(player, "Channel 8 reporter - walking beside you", { ("\"%s\""):format(q),
			"The camera light is in your face. The court officer doesn't stop you from answering." }, opts, #opts) or #opts
		local said = if i < #opts then opts[i] else nil
		local c = player.Character
		if c and said then Court.say(c, said, 6) end
		cityLife("perpWalk", player, { said = said, question = q, verdict = result.verdict, secs = result.secs, death = result.death, life = result.life, big = big, capital = capital })
		print(("[Court] PERP WALK %s answered: %s"):format(player.Name, tostring(said or "(head down)")))
	end)
end

---------------------------------------------------------------------------
-- THE DAY IN COURT
---------------------------------------------------------------------------
function Court.run(player: Player, ctx: any): any
	local alive = ctx.alive or function() return player.Parent ~= nil end
	local text = tostring(ctx.text or "")
	local secs = math.max(20, math.floor(tonumber(ctx.secs) or 60))
	-- v290g: a prison case (ctx.prisonFloor): prison time starts at 30 minutes and goes up from there
	-- - the stakes are scaled up front so every number the court reads out is what you'd serve
	local floorSecs = tonumber(ctx.prisonFloor)
	if floorSecs then secs = math.floor(floorSecs + secs * (tonumber(ctx.prisonScale) or 2)) end
	local function served(x: number): number
		local s = math.floor(x)
		return if floorSecs then math.max(s, floorSecs) else s
	end
	local firm, tier = counselOf(player)
	local prepared = player:GetAttribute("CasePrepared") == true
	local capital = isCapital(text)
	-- v268-v270: what money bought before the case (investigators, a fixer, the jury, the judge)
	local mods = cityLife("courtMods", player, { text = text, capital = capital, minor = ctx.minor == true }) or {}
	local file = cityLife("caseFile", player) -- v286: the specifics
	ctx.file = file
	local trialKind: string? = nil
	local priors = tonumber(ctx.priors) or 0
	-- v286s: a capital case = a killing with an aggravator: a record (priors), more than one
	-- victim, or a police officer. Then death is on the table after a guilty verdict.
	local kills, copKill = 0, false
	for _, e in (if file then file.entries else {}) do
		if e.key == "Murder" or e.key == "CopKilled" then kills += 1 end
		if e.key == "CopKilled" then copKill = true end
	end
	do
		local pk = tonumber(player:GetAttribute("PoliceOfficersKilled")) or 0
		if pk > 0 then copKill = true end
		local tl = text:lower()
		if pk == 0 and (tl:find("officer", 1, true) and (tl:find("murder", 1, true) or tl:find("kill", 1, true))) then copKill = true end
		if kills == 0 and (tl:find("murder", 1, true) or copKill) then kills = 1 end
		kills = math.max(kills, pk)
	end
	if kills > 0 and (priors >= 1 or kills >= 2 or copKill) then capital = true end
	local iv = ctx.interview
	-- v265: a venue other than the courthouse (ctx.venue = a marker folder) - the video
	-- arraignment room at Police HQ: no ride, the judge appears on the screen
	local venue: Instance? = ctx.venue
	local video = venue ~= nil
	local function spot(name: string): BasePart?
		local f = venue or markers()
		local p = f and f:FindFirstChild(name)
		return if p and p:IsA("BasePart") then p else nil
	end
	local function screenLabel(): TextLabel?
		local sv = venue and venue:FindFirstChild("Screen")
		local scr = sv and (sv :: ObjectValue).Value
		local g = scr and scr:FindFirstChildWhichIsA("SurfaceGui")
		return g and g:FindFirstChildWhichIsA("TextLabel")
	end
	local npcs: { Model } = {}
	local function add(m: Model?): Model?
		if m then table.insert(npcs, m) end
		return m
	end
	local function charOf()
		local c = player.Character
		return c, c and c:FindFirstChildOfClass("Humanoid"), c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	local function place(pos: Vector3)
		local _, _, r = charOf()
		if r then
			pcall(function() r:SetNetworkOwner(nil) end) -- v286m: server-placed
			r.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
		end
	end
	local function sitIn(seatName: string)
		local s = spot(seatName)
		local _, hum, _ = charOf()
		if not (s and hum and s:IsA("Seat")) then return end
		hum.Sit = false
		task.wait(0.15)
		place(s.Position)
		task.wait(0.15)
		s:Sit(hum)
	end
	local function stand()
		local _, hum, _ = charOf()
		if hum then hum.Sit = false end
	end

	-- judges with memory
	local rec = if Records then Records.get(player) else {}
	rec.court = rec.court or {}
	local judge = JUDGES[math.random(1, #JUDGES)]
	if rec.court.lastJudge and math.random() < 0.4 then
		for _, j in JUDGES do
			if j.name == rec.court.lastJudge then judge = j end
		end
	end
	if mods.judgeBought and not ctx.minor then
		judge = JUDGES[4] -- the one who can be bought
		print(("[Court] %s's case lands with %s (bought)"):format(player.Name, judge.name))
	end
	local returning = rec.court.lastJudge == judge.name
	local prosecutor = PROSECUTORS[math.random(1, #PROSECUTORS)]
	print(("[Court] CASE %s: %s | %s, %s for the State, counsel %s (tier %d)%s%s%s | %ds"):format(player.Name, text, judge.name, prosecutor,
		firm, tier, if prepared then ", prepared" else "", if capital then ", CAPITAL" else "", if ctx.minor then ", minor" else "", secs))
	player:SetAttribute("BookingState", "Court")
	player:SetAttribute("CourtJudge", judge.name)

	local result = { verdict = "guilty", secs = secs, judge = judge.name }
	-- v290g: the room. Everything said goes out on the live transcript (the gallery, Channel 8),
	-- whoever speaks gets a bubble and moves where they'd stand to say it.
	local RM: any = { who = tostring(player:GetAttribute("CharacterName") or player.DisplayName), R = nil, gallery = nil, witness = nil }
	RM.case = "State of Nevada v. " .. RM.who
	do
		local top = if file then crimesOf(file)[1] else nil
		RM.victim = top and not top.victimOfficer and top.victim or nil
		RM.big = capital or kills > 0 or (top ~= nil and (SEVERITY[top.key] or 1) >= 7) or (tonumber(ctx.stars) or 0) >= 4
		local room = spot("DefendantSeat")
		feedMeta[player] = { big = RM.big, at = room and room.Position }
		-- v290h: out on bail in a big case: the press stays on the steps for the whole trial
		if RM.big and ctx.free and not video then
			Court.stakeout(player, { force = true, secs = 3600 })
			Court.stakeoutPhase(player, "trial")
		end
		-- v290h: what the lawyer's office prepared (LawFirms: the case meeting, the mock trial)
		RM.mockText = player:GetAttribute("MockTheory")
		RM.mockCat = tonumber(player:GetAttribute("MockCat"))
		RM.mockAcquit = tonumber(player:GetAttribute("MockAcquit"))
		RM.mockOf = tonumber(player:GetAttribute("MockOf")) or 6
		RM.rehearsed = player:GetAttribute("Rehearsed") == true
	end
	ctx._tell = ctx.tell
	ctx.tell = function(m: string)
		Court.feed(player, RM.case, "Court", { m }, "narration")
		ctx._tell(m)
	end
	local card = function(p: Player, from: string, lines: { string }, options: { string }, default: number?): number?
		Court.feed(player, RM.case, from, lines)
		Court.block(RM.R, from, lines)
		for _, m in npcs do
			if m.Parent and string.sub(from, 1, #m.Name) == m.Name then Court.say(m, lines[1] or "", nil) break end
		end
		for _, l in lines do
			if string.sub(l, 1, 2) == "A:" and RM.witness and RM.witness.Parent then Court.say(RM.witness, string.sub(l, 4), nil, Color3.fromRGB(255, 250, 220)) end
		end
		local idx = card(p, from, lines, options, default)
		if idx and #options > 1 and options[idx] then Court.feed(player, RM.case, RM.who, { options[idx] }, "choice") end
		return idx
	end
	local ok, err = pcall(function()
		------------------------------------------------------------ 1. to court
		-- (ctx.free: out on bail, they came themselves - no ride, no holding cell)
		if not ctx.free then ctx.tell(if video then "Arraignment - taken to the video arraignment room" else "Court date - a cruiser is taking you to the Clark County Courthouse") end
		local drop = spot("PrisonerDropoff")
		if drop and ctx.ride and not ctx.free then
			local okR, how = pcall(ctx.ride, drop.Position)
			print(("[Court] RIDE %s: %s"):format(player.Name, tostring(if okR then how else "error: " .. tostring(how))))
			local _, _, r = charOf()
			if r and (r.Position - drop.Position).Magnitude > 60 then place(drop.Position) end
			-- v290g: a big case: the press is waiting at the sally port for the perp walk
			if RM.big and not video then
				local hold0 = spot("HoldingSpot")
				Court.pressPack(drop.Position, (if hold0 then hold0.Position else drop.Position + Vector3.new(0, 0, 10)), {
					("%s! Did you do it?"):format(RM.who), "Anything to say to the family?", "Look over here!",
					if RM.victim then ("Why %s?"):format(RM.victim) else "Are you going to plead guilty?",
					"How do you plead?", "Who's paying for your lawyer?",
				}, 25, function() local _, _, rr = charOf() return rr and rr.Position end)
				ctx.tell("Camera flashes - the press is waiting at the sally port")
			end
		end
		if not alive() then return end
		local hold = spot("HoldingSpot")
		if hold and not ctx.free then
			-- v286g: the floor under the marker (the marker floats ~3 studs up: people were left hanging)
			local holdPos = hold.Position
			do
				local fp = RaycastParams.new()
				fp.FilterType = Enum.RaycastFilterType.Exclude
				fp.FilterDescendantsInstances = { player.Character :: Instance, hold.Parent :: Instance }
				local h = workspace:Raycast(hold.Position + Vector3.new(0, 1, 0), Vector3.new(0, -10, 0), fp)
				if h then holdPos = h.Position end
			end
			ctx.tell(if video then "Walked down the custody corridor to the arraignment room" else "Through the sally port - up the secure stair to court holding")
			local how = if ctx.walk then ctx.walk(holdPos, 60) else "placed"
			local _, _, r = charOf()
			if r and (r.Position - holdPos).Magnitude > 12 then place(holdPos) end
			if ctx.setHold then ctx.setHold(holdPos + Vector3.new(0, 3, 0)) end
			print(("[Court] HOLDING %s (%s)"):format(player.Name, tostring(how)))
			ctx.tell("Court holding - waiting for your case to be called")
			-- v286g: counsel comes to the holding cell before the case is called
			if not video and alive() then
				local pick = card(player, firm .. " (your lawyer)", {
					("%s comes to the holding cell."):format(firm),
					"\"We have a few minutes before they call us. Let's talk.\"",
				}, { "Go over the case together", "What will the DA offer?", "Let's just go in" })
				if pick == 1 then
					prepared = true
					local lines = {}
					local b = file and file.brief
					if b then
						-- v286q: your actual case - what happened, what they have, what they don't, the read
						table.insert(lines, "\"" .. b.happened .. "\"")
						table.insert(lines, if #b.have > 0 then "They have: " .. table.concat(b.have, "; ") .. "." else "They have almost nothing - an officer's report.")
						if #b.haveNot > 0 then table.insert(lines, "They don't have: " .. table.concat(b.haveNot, " ")) end
						table.insert(lines, "\"" .. b.read .. "\"")
					else
						table.insert(lines, "\"Here's what they have - and how we answer it:\"")
						for _, ev in evidence(text, iv, file) do table.insert(lines, "- " .. ev.line) end
					end
					table.insert(lines, "\"Don't volunteer anything. Let me do the talking.\"")
					card(player, firm .. " (your lawyer)", lines, { "OK" })
					bill(player, "meeting")
				elseif pick == 2 then
					card(player, firm .. " (your lawyer)", {
						("\"If you plead, expect something around %s.\""):format(clock(served(secs * CFG.BaseOffer))),
						("\"Lose at trial and you're looking at up to %s.\""):format(clock(served(secs * CFG.MaxScale))),
					}, { "OK" })
				end
			end
		end
		-- the courtroom fills: counsel at their tables, the bailiff, the clerk
		local function seated(name: string, role: string, seatName: string): Model?
			local s = spot(seatName)
			if not s then return nil end -- (the video room has no prosecutor table / clerk desk)
			local m = add(Court.npc(name, role, s.Position))
			if m then Court.seat(m, seatName, venue) end
			return m
		end
		RM.pros = seated(prosecutor, "prosecutor", "ProsecutorSeat")
		local lawyer = seated(firm, "lawyer", "DefenseSeat")
		seated("Court Clerk", "bailiff", "CourtClerkSeat")
		-- v290g: the gallery - the families, the public, the press when it's a big case
		if not video then
			RM.gallery = Court.fillGallery(add, { defendant = RM.who, victim = RM.victim, kills = kills, copKill = copKill, big = RM.big })
			if #RM.gallery.press > 0 then ctx.tell("The press fills the back rows of the gallery") end
		end
		local bs = spot("BailiffSpot")
		local bailAt = if ctx.free then bs else hold or bs
		local bailiff = if bailAt then add(Court.npc("Bailiff", "bailiff", bailAt.Position)) else nil -- (v288: a hearing by video has no spots)
		if ctx.free then ctx.tell("The clerk checks you in - the bailiff will take you into the courtroom") end
		task.wait(4)
		if not alive() then return end

		------------------------------------------------------------ 2. all rise
		-- the bailiff brings the defendant in
		local defSeat = spot("DefendantSeat")
		ctx.tell("The bailiff calls your case")
		if defSeat then
			if bailiff then task.spawn(Court.walk, bailiff, defSeat.Position + Vector3.new(0, 0, 4), 40) end
			local how = if ctx.walk then ctx.walk(defSeat.Position, 45) else "placed"
			print(("[Court] TO THE CHAIR %s (%s)"):format(player.Name, tostring(how)))
			ctx.uncuff()
			sitIn("DefendantSeat")
		end
		if bailiff and bs then task.spawn(Court.walk, bailiff, bs.Position, 20) end
		if video then
			ctx.tell("\"The Las Vegas Justice Court is now in session.\" - the judge appears on the screen")
			local lbl = screenLabel()
			if lbl then
				lbl.Text = ("LAS VEGAS JUSTICE COURT - LIVE\n%s\nThe People v. %s"):format(judge.name, (player:GetAttribute("CharacterName") or player.DisplayName))
				lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
			end
		else
			ctx.tell("\"All rise. The Superior Court of Clark County is now in session.\"")
			local chambers = spot("ChambersSpot")
			local judgeNpc = add(Court.npc(judge.name, "judge", if chambers then chambers.Position else (defSeat :: BasePart).Position))
			local js = spot("JudgeSeat")
			if judgeNpc and js then
				Court.walk(judgeNpc, js.Position + Vector3.new(0, 0, 3), 30)
				Court.seat(judgeNpc, "JudgeSeat")
			end
			RM.R = { pros = RM.pros, def = lawyer, judge = judgeNpc, prosName = prosecutor, defName = firm, judgeName = judge.name, spots = Court.well(spot), jury = false }
		end
		task.wait(1)
		if not alive() then return end

		------------------------------------------------------------ 3. arraignment
		local maxSecs = served(secs * CFG.MaxScale)
		local greet = if returning then
			(if rec.court.lastVerdict == "not guilty" then "Back again. Last time you walked out of here. Not today."
				else "Back in my courtroom. I remember you.")
			else judge.greet
		do
			-- v286: each count read out with the time, the place and what was done
			local arr = { greet, ("The People of the State of Nevada v. %s."):format((player:GetAttribute("CharacterName") or player.DisplayName)) }
			for _, l in countLines(file, text) do table.insert(arr, l) end
			table.insert(arr, if capital then "This is a capital case. The State is seeking the death penalty."
				else ("Maximum sentence: %s."):format(clock(maxSecs)))
			card(player, judge.name, arr, { "Continue" })
		end
		if not alive() then return end

		------------------------------------------------------------ 4. plea
		if ctx.minor and not capital then
			-- v285: the first appearance. Plead guilty and it's dealt with today (a fine for a
			-- misdemeanor, a short sentence otherwise); plead not guilty and the case is set for
			-- trial at the courthouse - the judge sets bail (PoliceSystem runs the bail hearing).
			local plea = served(secs * CFG.MinorPleaScale)
			local fine = tonumber(ctx.fine)
			local classText = if ctx.class == "F" then "This is a felony charge."
				elseif ctx.class == "GM" then "This is a gross misdemeanor." else "This is a misdemeanor."
			local c = card(player, firm .. " (your lawyer)", {
				classText,
				if fine then ("Plead guilty and the judge fines you $%d - you walk out today."):format(fine)
					else ("Plead guilty and the judge gives you %s."):format(clock(plea)),
				if video then "Plead not guilty and it's set for trial at the courthouse. The judge will set bail."
					else "Or plead not guilty and the judge hears it now.",
			}, { "Plead guilty", "Plead not guilty" })
			if not alive() then return end
			if c == 1 then
				result = { verdict = "plea", secs = if fine then 0 else plea, fine = fine, judge = judge.name }
				card(player, judge.name, { "The court accepts your plea.",
					if fine then ("Fine: $%d, payable today."):format(fine) else ("Sentence: %s."):format(clock(plea)) }, { "OK" })
				bill(player, "plea")
				return
			end
			if video then
				result = { verdict = "continued", secs = secs, judge = judge.name }
				card(player, judge.name, {
					"A plea of not guilty is entered.",
					"This matter is set for trial at the Clark County Courthouse.",
					"Now - the question of bail.",
				}, { "OK" })
				print(("[Court] ARRAIGNMENT %s: not guilty - set for trial, bail hearing next"):format(player.Name))
				return
			end
		end
		local offerScale = CFG.BaseOffer - 0.04 * (tier - 1) + judge.offer
		if prepared then offerScale -= 0.05 end
		if iv and iv.confessed then offerScale += 0.15 end
		if iv and iv.lawyered then offerScale -= 0.03 end
		if iv and iv.secsScale and iv.secsScale < 1 then offerScale *= iv.secsScale end -- a deal from the interview room
		offerScale += math.min(0.2, 0.05 * priors)
		offerScale *= tonumber(mods.offerScale) or 1
		if mods.judgeBought then offerScale *= 0.7 end
		offerScale = math.clamp(offerScale, 0.2, 0.95)
		local offer = if capital or ctx.minor then nil else served(secs * offerScale)
		local strength = caseStrength(ctx, tier, prepared)
		strength = math.clamp(strength + (tonumber(mods.evidence) or 0), 0.05, 0.98)
		if mods.evidence and mods.evidence < 0 then print(("[Court] %s: the State's case is weaker (%.2f)"):format(player.Name, mods.evidence)) end
		-- v286s: THE PENALTY PHASE (capital cases, after a guilty plea or verdict): the State asks
		-- for death; the record, the body count and a dead officer weigh for it, the lawyer's
		-- mitigation and what you say weigh against. A jury has to be unanimous for death.
		local function penaltyPhase(byJury: boolean, pleaded: boolean): any
			local counsel = firm .. " (your lawyer)"
			ctx.tell("THE PENALTY PHASE - the State is asking for the death penalty")
			local aggr = {}
			if kills >= 2 then table.insert(aggr, ("%d people dead"):format(kills)) end
			if copKill then table.insert(aggr, "a police officer killed in the line of duty") end
			if priors > 0 then table.insert(aggr, ("a record - %d prior arrest%s"):format(priors, if priors == 1 then "" else "s")) end
			if #aggr == 0 then table.insert(aggr, "the cruelty of the crime") end
			card(player, prosecutor .. " - penalty phase", {
				"The defendant stands convicted. The only question left is what they deserve.",
				"The aggravating factors: " .. table.concat(aggr, "; ") .. ".",
				"The State asks for the ultimate penalty: death.",
			}, { "..." })
			if not alive() then return nil end
			local p = 0.2 + 0.12 * math.min(priors, 4) + 0.08 * math.clamp(kills - 1, 0, 5) + (if copKill then 0.15 else 0) + judge.tilt - 0.04 * (tier - 1)
			if pleaded then p -= 0.15 end
			if mods.judgeBought then p -= 0.35 end
			local mit = card(player, counsel, { "\"This is for your life now. What do we put in front of them?\"" }, {
				"Mitigation - my life, my family, what led me here",
				"I'll speak - show remorse",
				"I'll speak - tell them what I think of them",
				"Say nothing",
			}) or 4
			if not alive() then return nil end
			if mit == 1 then
				card(player, counsel, { "Your lawyer calls your mother, a teacher, a social worker.", "\"Whatever they did, they are still a human being.\"" }, { "..." })
				p -= 0.05 + 0.025 * tier
			elseif mit == 2 then
				local c = card(player, "You (allocution)", { "You stand to address the court." }, {
					"\"I'm sorry. I can't take it back. I'm sorry.\"", "\"I'm sorry - but I had my reasons.\"" }, 1) or 1
				if c == 1 then p -= 0.1 else p -= 0.02 end
			elseif mit == 3 then
				card(player, "You (allocution)", { "\"I'd do it again. Do what you want.\"", "The courtroom goes silent." }, { "..." })
				p += 0.25
			end
			p = math.clamp(p, 0.03, 0.93)
			local death = math.random() < p
			print(("[Court] PENALTY %s: kills=%d cop=%s priors=%d mitigation=%d -> p %.2f, %s"):format(player.Name, kills, tostring(copKill), priors, mit, p, if death then "DEATH" else "life"))
			if byJury then
				ctx.tell("The jury retires to decide the sentence...")
				task.wait(8)
				if not alive() then return nil end
			end
			local lifeSecs = CFG.LifeSecs
			if death then
				card(player, judge.name, {
					if byJury then "\"We, the jury, unanimously find that the defendant shall be sentenced to DEATH.\"" else "I have weighed the aggravating factors against the mitigation. They are not close.",
					("%s, you are sentenced to death by lethal injection."):format(player:GetAttribute("CharacterName") or player.DisplayName),
					"You will be taken to the State Prison and held on Death Row until the sentence is carried out.",
					"May God have mercy on your soul.",
				}, { "..." })
				return { verdict = if pleaded then "plea" else "guilty", secs = lifeSecs, judge = judge.name, death = true }
			end
			card(player, judge.name, {
				if byJury then "\"The jury could not agree on death.\" - one juror would not sign it." else "Death is not warranted here - but you will never be free again.",
				"You are sentenced to LIFE in the State Prison without the possibility of parole.",
			}, { "..." })
			return { verdict = if pleaded then "plea" else "guilty", secs = lifeSecs, judge = judge.name, life = true }
		end
		if not ctx.minor then
			local pick = card(player, judge.name, { "How do you plead?" }, { "Not guilty", "Guilty", "Let my lawyer speak first" }, 1)
			if not alive() then return end
			if pick == 2 and capital then
				-- v286s: pleading guilty to a capital count doesn't take death off the table
				card(player, judge.name, { "The court accepts your plea of guilty.", "We proceed directly to sentencing." }, { "..." })
				local pr = penaltyPhase(false, true)
				if pr then result = pr end
				bill(player, "plea")
				return
			elseif pick == 2 then
				result = { verdict = "plea", secs = served(secs * CFG.OpenPleaScale), judge = judge.name }
				card(player, judge.name, { "The court accepts your plea of guilty.", ("Sentence: %s."):format(clock(result.secs)) }, { "OK" })
				bill(player, "plea")
				return
			end
		end
		local negotiations = 0
		while offer and alive() do
			local lines = {
				("The DA's offer: plead guilty and take %s instead of up to %s."):format(clock(offer), clock(maxSecs)),
				if strength > 0.7 then "Their case is strong. I'd think hard about it."
					elseif strength < 0.45 then "Their case has holes. We could win at trial." else "It could go either way at trial.",
			}
			if tier <= 1 then table.insert(lines, "(Public Defender) I have four more of these today.") end
			-- v290g: what you'd actually be negotiating for (the lesser charge for this crime)
			local lesserTop = Court.LESSER[(if file then (crimesOf(file)[1] or {}).key else nil) or ""]
			local negLabel = if lesserTop then ("Negotiate - push the charge down to %s"):format(lesserTop) else "Negotiate - ask for less time"
			local opts = { "Accept the deal", negLabel, "Reject - go to trial" }
			if negotiations >= 2 then table.remove(opts, 2) end
			local choice = card(player, firm .. " (your lawyer)", lines, opts)
			if not alive() then return end
			local what = opts[choice or #opts]
			if what == "Accept the deal" then
				result = { verdict = "plea", secs = offer, judge = judge.name }
				card(player, judge.name, { "The court accepts the plea agreement.", ("Sentence: %s."):format(clock(offer)) }, { "OK" })
				bill(player, "plea")
				print(("[Court] PLEA %s: %ds"):format(player.Name, offer))
				return
			elseif what == negLabel then
				negotiations += 1
				bill(player, "plea")
				local r = math.random()
				local improve = 0.25 + 0.08 * tier + (if prepared then 0.1 else 0)
				local pulled = math.max(0.05, 0.28 - 0.03 * tier)
				if r < improve then
					offer = served(offer * (0.82 + math.random() * 0.08))
					card(player, prosecutor, { "Fine. That's as low as I go." }, { "OK" })
				elseif r < improve + pulled then
					card(player, prosecutor, { "You want to play games? The offer's off the table. See you at trial." }, { "..." })
					offer = nil
				else
					card(player, prosecutor, { "The offer stands. Take it or leave it." }, { "OK" })
				end
			else
				break
			end
		end
		if capital then
			card(player, prosecutor, { "The State is seeking the maximum. There will be no deal." }, { "..." })
		end
		if not alive() then return end

		-- v286v: THE BAIL HEARING. In custody and pleading not guilty: the judge rules on bail on
		-- the record - set (pay it, a bondsman, or someone pays at the desk: released until the
		-- trial date) or denied with a reason. Nobody is held without bail without hearing why.
		if ctx.bail and not ctx.free and not video and not ctx.minor then
			local deny: string? = if capital then "this is a capital case"
				elseif kills > 0 then "the nature of the charge - the defendant is a danger to the community"
				else nil
			card(player, judge.name, { "A plea of not guilty is entered.", "Now - the question of bail." }, { "..." })
			if not alive() then return end
			local argue = card(player, firm .. " (your lawyer)", {
				if deny then "\"They'll ask for no bail. I'll fight it, but it's an uphill climb.\"" else "\"I'll ask for reasonable bail. You have ties here.\"",
			}, { "Argue for release", "Leave it to the judge" })
			if not alive() then return end
			-- a good lawyer can turn a borderline denial (not capital) into a high bail
			if deny and not capital and argue == 1 and math.random() < 0.12 + 0.06 * tier then deny = nil end
			local okB, res, why = pcall(ctx.bail, deny)
			if not alive() then return end
			if okB and res == "posted" then
				card(player, judge.name, { "Bail has been posted.",
					"The defendant is released pending trial. Miss your court date and a warrant issues." }, { "OK" })
				result = { verdict = "bail", secs = 0, judge = judge.name }
				print(("[Court] BAIL %s: posted - released until trial"):format(player.Name))
				return
			elseif okB and res == "denied" then
				card(player, judge.name, { "Bail is DENIED.", ("The court notes %s."):format(tostring(why or deny or "the risk of flight")),
					"The defendant is remanded into custody pending trial." }, { "..." })
			else
				card(player, judge.name, { "Bail was set and not posted.", "The defendant remains in custody pending trial." }, { "..." })
			end
			print(("[Court] BAIL %s: %s (%s)"):format(player.Name, tostring(if okB then res else "error: " .. tostring(res)), tostring(why or deny)))
			if not alive() then return end
		end

		------------------------------------------------------------ 5. trial
		-- v291: THE TRIAL is an evidence contest (PoliceSystem.Trial): the case board, motions, live
		-- objections, cross-examination against real weaknesses, the defence case, deliberation by
		-- jurors who each have their own reasonable-doubt bar. Real players can be defence counsel,
		-- the prosecutor, the judge and jurors (Attorneys script); NPCs fill whatever is missing.
		local jury = false
		if not ctx.minor and not ctx.benchOnly then
			local kind = card(player, judge.name, { "This case goes to trial. Bench or jury?",
				"A judge decides on the evidence alone. A jury of twelve has to agree - harder to convince, slower, less predictable." },
				{ "Bench trial (the judge decides)", "Jury trial (12 jurors)" }, 1)
			if not alive() then return end
			jury = kind == 2
		end
		trialKind = if jury then "jury" else "bench"
		if RM.R then RM.R.jury = jury end
		-- v290i: a detective calls any real player who saw it - will they testify?
		Court.askWitnesses(player, file, RM)
		local TrialMod = require(script.Parent:WaitForChild("Trial")) :: any
		local E: any = { player = player, alive = alive, file = file, iv = iv, mods = mods, who = RM.who, caseName = RM.case,
			judge = judge, prosecutor = prosecutor, firm = firm, counsel = firm .. " (your lawyer)", tier = tier, prepared = prepared,
			rehearsed = RM.rehearsed, elite = firm == "Premier Counsel" and player:GetAttribute("EliteRepresentation") == true,
			jury = jury, capital = capital, big = RM.big, kills = kills, copKill = copKill, priors = priors, victim = RM.victim,
			panel = if jury then (type(mods.jurors) == "table" and mods.jurors or {}) else {}, jurorBias = {},
			mockText = RM.mockText, mockAcquit = RM.mockAcquit, mockOf = RM.mockOf, judgeBought = mods.judgeBought == true,
			familyName = if RM.gallery and RM.gallery.def[1] then RM.gallery.def[1].Name else nil,
			choices = Court.choices, clock = clock, roles = { jurors = {} }, jurorModels = {} }
		E.F = Court.facts(file)
		E.tell = function(m: string) ctx.tell(m) end
		E.feed = function(speaker: string, lines: { string }, kind: string?) Court.feed(player, RM.case, speaker, lines, kind) end
		E.card = function(p: Player, from: string, lines: { string }, options: { string }, default: number?): number?
			if p == player then return card(p, from, lines, options, default) end
			return Court.card(p, from, lines, options, default)
		end
		E.bill = function(activity: string, cx: number?) bill(player, activity, cx) end
		E.sitIn = sitIn
		-- the people: a player in a role takes the seat from the NPC who'd have had it
		local function seatPlayer(p: Player, seatName: string)
			local c = p.Character
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			local s = spot(seatName)
			if not (c and hum and s and s:IsA("Seat")) then return end
			if s.Occupant and s.Occupant ~= hum then
				local occ = s.Occupant.Parent
				s.Occupant.Sit = false
				if occ and occ:IsA("Model") and occ:GetAttribute("CourtNPC") then occ:Destroy() end
				task.wait(0.1)
			end
			hum.Sit = false
			c:PivotTo(s.CFrame * CFrame.new(0, 3, 0))
			task.wait(0.15)
			s:Sit(hum)
		end
		do
			local info = { defendant = player, case = RM.case, charges = text, big = RM.big, jury = jury }
			local got = 0
			local need = 3 + (if jury then 1 else 0)
			task.spawn(function() E.roles.defence = TrialMod.attorneys("counselFor", player, info); got += 1 end)
			task.spawn(function() E.roles.prosecutor = TrialMod.attorneys("summon", "prosecutor", info); got += 1 end)
			task.spawn(function() E.roles.judge = TrialMod.attorneys("summon", "judge", info); got += 1 end)
			if jury then task.spawn(function() E.roles.jurors = TrialMod.attorneys("summon", "jurors", info, 6) or {}; got += 1 end) end
			ctx.tell("The clerk calls the case and checks who's here for it...")
			local t0 = os.clock()
			while got < need and os.clock() - t0 < 40 do task.wait(0.5) end
			if E.roles.defence and E.roles.defence.Parent then
				if lawyer and lawyer.Parent then lawyer:Destroy() end
				seatPlayer(E.roles.defence, "DefenseSeat")
				if RM.R then RM.R.def = E.roles.defence.Character end
				ctx.tell(("Your attorney, %s, takes the defence table"):format(E.roles.defence:GetAttribute("CharacterName") or E.roles.defence.DisplayName))
			end
			if E.roles.prosecutor and E.roles.prosecutor.Parent then
				if RM.pros and RM.pros.Parent then RM.pros:Destroy() end
				seatPlayer(E.roles.prosecutor, "ProsecutorSeat")
				if RM.R then RM.R.pros = E.roles.prosecutor.Character end
				E.prosecutor = tostring(E.roles.prosecutor:GetAttribute("CharacterName") or E.roles.prosecutor.DisplayName)
			end
			if E.roles.judge and E.roles.judge.Parent then
				if RM.R and RM.R.judge and RM.R.judge.Parent then RM.R.judge:Destroy() end
				seatPlayer(E.roles.judge, "JudgeSeat")
				if RM.R then RM.R.judge = E.roles.judge.Character; RM.R.judgeName = TrialMod.judgeLabel(E) end
			end
		end
		-- the jury: twelve seats, real players first
		if jury then
			ctx.tell("The jury files in from the jury room")
			local jr = spot("JuryRoomSpot")
			local done = 0
			for i = 1, 12 do
				local pj = E.roles.jurors[i]
				if pj and pj.Parent then
					task.spawn(function() seatPlayer(pj, "JurorSeat" .. i); done += 1 end)
				else
					local jname = if E.panel[i] and E.panel[i].name then ("Juror #%d (%s)"):format(i, E.panel[i].name) else "Juror #" .. i
					local m = add(Court.npc(jname, "juror", (jr or defSeat :: BasePart).Position + Vector3.new((i % 4) * 2, 0, (i // 4) * 2)))
					E.jurorModels[i] = m
					task.spawn(function()
						local seat = spot("JurorSeat" .. i)
						if m and seat then Court.walk(m, seat.Position + Vector3.new(0, 0, -3), 25) end
						Court.seat(m, "JurorSeat" .. i)
						done += 1
					end)
				end
			end
			local t0 = os.clock()
			while done < 12 and os.clock() - t0 < 30 do task.wait(0.5) end
			-- voir dire: three of the NPC panel are questioned; the defence strikes one, a better firm knows who
			local POOL = {
				{ "a retired police sergeant", 0.07, "\"I spent thirty years on the job. I know when someone's guilty.\"" },
				{ "a nurse from Henderson", 0.0, "\"I'll listen to the evidence. That's all I can promise.\"" },
				{ "a college student", -0.05, "\"Honestly? I don't trust the police much.\"" },
				{ "a casino pit boss", 0.03, "\"I watch people cheat for a living. They always think they're clever.\"" },
				{ "a widow whose son was killed", 0.08, "\"...I can be fair. I think.\"" },
				{ "a public school teacher", -0.03, "\"Everyone deserves a second chance.\"" },
				{ "a security guard", 0.05, "\"If the camera shows it, it happened.\"" },
				{ "an Uber driver", -0.02, "\"Cops pulled me over four times last year. For nothing.\"" },
			}
			local seats = {}
			for i = #E.roles.jurors + 1, 12 do table.insert(seats, i) end
			local picks = {}
			while #picks < math.min(3, #seats) do
				local c = POOL[math.random(1, #POOL)]
				if not table.find(picks, c) then table.insert(picks, c) end
			end
			-- everyone on the panel leans a little (a juror's bar moves with their background)
			for i = 1, 12 do E.jurorBias[i] = (math.random() - 0.5) * 0.06 end
			for k, c in picks do E.jurorBias[seats[k]] = -c[2] end
			if #picks > 0 then
				local lines = { "DAY 1 - jury selection. The defence may strike one of these three:" }
				for k, c in picks do table.insert(lines, ("Juror #%d, %s: %s"):format(seats[k], c[1], c[3])) end
				if tier >= 3 and not E.roles.defence then
					local worst = 1
					for k, c in picks do if c[2] > picks[worst][2] then worst = k end end
					table.insert(lines, ("%s (whispering): \"Juror #%d is already decided against you.\""):format(firm, seats[worst]))
				end
				local opts = {}
				for k, c in picks do table.insert(opts, ("Strike Juror #%d (%s)"):format(seats[k], c[1])) end
				table.insert(opts, "Keep all three")
				local who = if E.roles.defence and E.roles.defence.Parent then E.roles.defence else player
				local s = card(who, TrialMod.counselLabel(E) .. " - jury selection", lines, opts, #opts) or #opts
				if picks[s] then
					-- struck: an alternate with no strong views takes the seat
					E.jurorBias[seats[s]] = (math.random() - 0.5) * 0.04
					ctx.tell(("Juror #%d is excused; an alternate takes the seat"):format(seats[s]))
				end
			end
		end
		-- what the room does when the trial says something happens
		E.say = function(whoKey: string, txt: string)
			local m = if whoKey == "pros" then (RM.R and RM.R.pros) elseif whoKey == "def" then (RM.R and RM.R.def)
				elseif whoKey == "judge" then (RM.R and RM.R.judge) else RM.witness
			if m and m.Parent then Court.say(m, txt, nil, if whoKey == "witness" then Color3.fromRGB(255, 250, 220) else nil) end
		end
		E.sidebar = function() Court.sidebar(RM.R, 4) end
		local function callWitness(name: string, role: string): Model?
			local ws = spot("WitnessSeat")
			if not ws then return nil end
			local from = spot("BailiffSpot") or ws
			local m = add(Court.npc(name, role, (from :: BasePart).Position))
			if m then
				ctx.tell(("%s is called to the stand"):format(name))
				RM.witness = m
				Court.walk(m, ws.Position + Vector3.new(0, 0, 3), 20)
				Court.seat(m, "WitnessSeat")
			end
			return m
		end
		E.callNamed = callWitness
		E.callFor = function(x: any): (string, Model?)
			local name
			if x.type == "eyewitness" then name = string.match(x.text, "^(.-),") or "An eyewitness"
			elseif x.type == "arrest" or x.type == "report" then name = string.gsub((if file then tostring(file.officer) else "The arresting officer"), ", Unit %d+", "")
			elseif x.type == "forensic" then name = "Crime-lab examiner"
			elseif x.type == "statement" then name = "The interviewing detective"
			elseif x.type == "alpr" then name = "LVMPD traffic analyst"
			else name = "Evidence technician" end
			return name, callWitness(name, if x.type == "arrest" or x.type == "report" or x.type == "statement" then "officer" else "witness")
		end
		E.stepDown = function(m: Model?)
			if m and m.Parent then
				local hum = m:FindFirstChildOfClass("Humanoid")
				if hum then hum.Sit = false end
				task.delay(1, function() if m.Parent then m:Destroy() end end)
			end
			RM.witness = nil
		end
		E.asWitness = function(x: any): string
			local h = if file and file.brief then file.brief.happened else "I saw what happened."
			h = string.gsub(h, "they say you", "the defendant")
			if x.type == "video" then return "The footage shows it. " .. h end
			if x.type == "forensic" then return "The results match the defendant." end
			if x.type == "statement" then return "The defendant told us what happened, on tape." end
			return h
		end
		E.playerWitness = function(x: any): number?
			local T = { at = E.F.at, place = E.F.place, victim = E.F.victim }
			return Court.playerWitness(player, x, RM, T, prosecutor, TrialMod.counselLabel(E), card)
		end
		E.jurorsOut = function()
			for i, m in E.jurorModels do
				task.spawn(function()
					local seat = spot("JuryRoomSeat" .. i)
					if m and m.Parent and seat then Court.walk(m, seat.Position + Vector3.new(0, 0, 3), 25); Court.seat(m, "JuryRoomSeat" .. i) end
				end)
			end
			ctx.tell("The jury retires to the jury room to deliberate")
		end
		E.jurorsBack = function()
			for i, m in E.jurorModels do
				task.spawn(function()
					local seat = spot("JurorSeat" .. i)
					if m and m.Parent and seat then Court.walk(m, seat.Position + Vector3.new(0, 0, -3), 20); Court.seat(m, "JurorSeat" .. i) end
				end)
			end
			ctx.tell("A knock on the jury room door: they have reached a verdict")
			task.wait(6)
		end
		E.retrialDeal = function(attempt: number): number?
			local last = if capital then CFG.LifeSecs else served(secs * (0.6 + 0.1 * attempt))
			local c3 = card(player, prosecutor, { "The State WILL retry this case.",
				if capital then "Plead guilty now and the State takes death off the table: life without parole." else ("Or plead to %s and we're done."):format(clock(last)) },
				{ "Take it", "No - try me again" }, 2)
			if c3 == 1 then bill(player, "plea"); return last end
			return nil
		end
		-- the court adjourns for the day: in custody = back down to court holding overnight
		local function floorUnder(p: BasePart?): Vector3?
			if not p then return nil end
			local fp = RaycastParams.new()
			fp.FilterType = Enum.RaycastFilterType.Exclude
			fp.FilterDescendantsInstances = { player.Character :: Instance, p.Parent :: Instance }
			local h = workspace:Raycast(p.Position + Vector3.new(0, 1, 0), Vector3.new(0, -10, 0), fp)
			return if h then h.Position else p.Position
		end
		E.recess = function(dayDone: number)
			if not alive() then return end
			card(player, TrialMod.judgeLabel(E), { ("That concludes day %d. We are adjourned until nine o'clock tomorrow morning."):format(dayDone),
				if jury then "The jury is reminded not to discuss this case with anyone." else "Court is in recess." }, { "..." })
			bill(player, if jury then "jury" else "bench", 0.15)
			stand()
			if not ctx.free then
				if ctx.cuff then pcall(ctx.cuff) end
				local hp = floorUnder(spot("HoldingSpot"))
				if hp and ctx.walk then
					ctx.tell("Court officers take you back down to holding for the night")
					local how = ctx.walk(hp, 45)
					print(("[Court] RECESS %s walked down to holding (%s)"):format(player.Name, tostring(how)))
					if ctx.setHold then ctx.setHold(hp + Vector3.new(0, 3, 0)) end
				end
				-- the night in court holding - until court sits again at 9:00 the next morning on the city
				-- clock (1 game hour = 1 real minute), at least a minute, at most 8
				local L = game:GetService("Lighting")
				local hoursTo9 = (9 - L.ClockTime) % 24
				if hoursTo9 < 1 then hoursTo9 += 24 end
				local wait = math.clamp(hoursTo9 * 60, 60, 480)
				ctx.tell(("Overnight in court holding - court resumes at 9:00 AM (%d:%02d)"):format(wait // 60, wait % 60))
				print(("[Court] OVERNIGHT %s after day %d: %ds"):format(player.Name, dayDone, math.floor(wait)))
				if ctx.uncuff then pcall(ctx.uncuff) end -- in the cell
				local t0 = os.clock()
				while alive() and os.clock() - t0 < wait do
					task.wait(0.5)
					local left = (9 - L.ClockTime) % 24
					if os.clock() - t0 > 5 and (left < 0.1 or left > 23.6) then break end
				end
				if not alive() then return end
				if ctx.cuff then pcall(ctx.cuff) end
				ctx.tell(("Day %d - you're brought back up to the courtroom"):format(dayDone + 1))
				if defSeat and ctx.walk then ctx.walk(defSeat.Position, 45) end
				if ctx.uncuff then pcall(ctx.uncuff) end
			else
				-- out on bail - free to go for the night. Back in the courtroom by 9:00, or it's a failure
				-- to appear: the trial stops, a bench warrant.
				ctx.tell("Court is adjourned until 9:00 AM. You're free to leave - be back in this courtroom by 9:00 or the judge issues a bench warrant.")
				local L = game:GetService("Lighting")
				local hoursTo9 = (9 - L.ClockTime) % 24
				if hoursTo9 < 1 then hoursTo9 += 24 end
				local t0 = os.clock()
				local warned = false
				while alive() and os.clock() - t0 < math.clamp(hoursTo9 * 60, 60, 480) do
					task.wait(0.5)
					local left = (9 - L.ClockTime) % 24
					if os.clock() - t0 > 5 and (left < 0.1 or left > 23.6) then break end
					if not warned and left < 1 and left > 0.1 then
						warned = true
						ctx.tell("Court resumes at 9:00 - be in the courtroom")
					end
				end
				if not alive() then return end
				local seatNow = defSeat or spot("DefendantSeat")
				local _, _, rNow = charOf()
				if not (seatNow and rNow and (rNow.Position - seatNow.Position).Magnitude < 260) then
					print(("[Court] FAILURE TO APPEAR %s - not back for day %d"):format(player.Name, dayDone + 1))
					for _, m in npcs do if m.Parent then m:Destroy() end end
					player:SetAttribute("CourtJudge", nil)
					player:SetAttribute("CasePrepared", nil)
					error("COURT_FTA", 0) -- Bail.appear: a bench warrant
				end
			end
			sitIn("DefendantSeat")
			-- the people in roles are put back in their seats for the new day
			for role, seatName in { defence = "DefenseSeat", prosecutor = "ProsecutorSeat", judge = "JudgeSeat" } do
				local p = E.roles[role]
				if p and p.Parent then task.spawn(seatPlayer, p, seatName) end
			end
			for i, p in E.roles.jurors do if p.Parent then task.spawn(seatPlayer, p, "JurorSeat" .. i) end end
			ctx.tell(("DAY %d of the trial - court is back in session"):format(dayDone + 1))
		end
		-- THE TRIAL
		local TR = TrialMod.run(E)
		if not alive() then return end
		if TR.deal then
			result = { verdict = "plea", secs = TR.deal, judge = judge.name, life = capital or nil }
			return
		end
		local verdict = if TR.verdict == "lesser" then "guilty" else TR.verdict
		RM.TR, RM.E = TR, E
		-- the jury says why (after the verdict is read)
		local function reasons()
			if TR.reasons and #TR.reasons > 0 and jury then
				TrialMod.announce(E, "The jury foreperson", TR.reasons)
			end
		end
		if verdict == "guilty" and capital and not TR.lesser then
			card(player, TrialMod.judgeLabel(E), {
				if jury then "Has the jury reached a verdict? ...\"We find the defendant GUILTY.\"" else "I find the defendant GUILTY.",
				"On all counts. The court will now hear argument on the sentence.",
			}, { "..." })
			reasons()
			if not alive() then return end
			local pr = penaltyPhase(jury, false)
			if pr then result = pr end
		elseif verdict == "guilty" then
			card(player, TrialMod.judgeLabel(E), {
				if jury then "Has the jury reached a verdict? ...\"We find the defendant GUILTY.\"" else "I find the defendant GUILTY.",
				if TR.lesser then ("Not of the charge as brought - of the lesser offence: %s."):format(Court.LESSER[E.F.key or ""] or "a lesser charge")
					else "On all counts.",
			}, { "..." })
			reasons()
			if not alive() then return end
			-- v291: THE SENTENCING HEARING - the range, the factors on both sides, the victim's family,
			-- the defendant's last words, then the judge (a player judge picks within the range)
			ctx.tell("THE SENTENCING HEARING")
			E.minSecs = served(secs * 0.6)
			E.maxSecs = served(secs * CFG.MaxScale)
			E.floorSecs = floorSecs
			local s = TrialMod.sentence(E, TR)
			result = { verdict = if TR.lesser then "guilty (lesser charge)" else "guilty", secs = served(s), judge = judge.name }
		elseif verdict == "dismissed" then
			result = { verdict = "dismissed", secs = 0, judge = judge.name }
			card(player, judge.name, { "The State has dropped the charges. You're free to go." }, { "OK" })
		else
			result = { verdict = "not guilty", secs = 0, judge = judge.name }
			card(player, judge.name, {
				if jury then "Has the jury reached a verdict? ...\"We find the defendant NOT GUILTY.\"" else "I find the defendant NOT GUILTY.",
				"You're free to go. This court is adjourned.",
			}, { "OK" })
		end
		-- v290g: the room reacts - the families, the press running for the doors
		if RM.gallery then
			if result.verdict == "not guilty" or result.verdict == "dismissed" then
				Court.react(RM.gallery.def, { "Thank God!", "(cheering)", ("We love you, %s!"):format(RM.who), "(hugging each other)" }, Color3.fromRGB(220, 255, 220))
				Court.react(RM.gallery.vic, { "NO! This isn't justice!", "(screaming at the defendant)", "(collapses in tears)" }, Color3.fromRGB(255, 220, 220))
			elseif (result.secs or 0) > 0 then
				Court.react(RM.gallery.def, { "No... NO!", "(sobbing)", "Stay strong! We'll appeal!" }, Color3.fromRGB(255, 220, 220))
				Court.react(RM.gallery.vic, { "(crying with relief)", if RM.victim then "Justice for " .. RM.victim .. "." else "Thank you, Your Honor.", "(holding each other)" }, Color3.fromRGB(220, 230, 255))
			end
			Court.react(RM.gallery.press, { "(rushing out to file)", "(scribbling)", "(on the phone to the newsroom)" })
			Court.feed(player, RM.case, "Court", { "The gallery reacts to the verdict." }, "narration")
		end
		if lawyer and result.secs == 0 then
			card(player, firm, { "Go home. And stay out of trouble." }, { "OK" })
		end
	end)
	if not ok then
		warn("[Court] error in " .. player.Name .. "'s case: " .. tostring(err))
	end
	stand()
	-- v286h/v291: THE WALK OUT after a custodial sentence: cuffed where they stand and walked out by a
	-- court officer. In custody: down to court holding (the transport picks up at the sally port
	-- after that). Out on bail: straight down the secure stair to the sally port and the transport.
	-- The press is waiting at the sally port either way.
	local walkOut: Vector3? = nil
	if (result.secs or 0) > 0 and not video and alive() then
		local drop = spot("PrisonerDropoff")
		walkOut = drop and drop.Position
		pcall(Court.walkOutPress, player, RM, result, drop, capital)
		ctx.tell(if ctx.free then "Taken into custody - a court officer cuffs you and walks you out to the transport"
			else "Remanded into custody - the court officer takes you back to holding")
		local cuffFn = ctx.remandCuff or ctx.cuff
		local walkFn = ctx.remandWalk or ctx.walk
		if cuffFn then pcall(cuffFn) end
		local target = if ctx.free then drop else spot("HoldingSpot")
		if target and walkFn then
			local pos = target.Position
			local fp = RaycastParams.new()
			fp.FilterType = Enum.RaycastFilterType.Exclude
			fp.FilterDescendantsInstances = { player.Character :: Instance, target.Parent :: Instance }
			local h = workspace:Raycast(target.Position + Vector3.new(0, 1, 0), Vector3.new(0, -10, 0), fp)
			if h then pos = h.Position end
			local how = walkFn(pos, if ctx.free then 90 else 45)
			if not ctx.free and ctx.setHold then ctx.setHold(pos + Vector3.new(0, 3, 0)) end
			if cuffFn then pcall(cuffFn) end
			print(("[Court] REMANDED %s -> %s (%s)"):format(player.Name, if ctx.free then "the sally port" else "court holding", tostring(how)))
		end
	end
	if video then
		local lbl = screenLabel()
		if lbl then lbl.Text = "LAS VEGAS JUSTICE COURT\nVIDEO ARRAIGNMENT\n- court not in session -" end
	end
	task.delay(5, function()
		for _, m in npcs do
			if m.Parent then m:Destroy() end
		end
	end)
	rec.court.lastJudge = judge.name
	rec.court.lastVerdict = result.verdict
	rec.court.cases = (rec.court.cases or 0) + 1
	if Records and Records.touch then pcall(Records.touch, player) end
	player:SetAttribute("CourtJudge", nil)
	player:SetAttribute("CasePrepared", nil)
	-- v290h: the case is over (unless it was only the arraignment / bail): the office's prep is spent
	if result.verdict ~= "bail" and result.verdict ~= "continued" then
		for _, a in { "MockTheory", "MockCat", "MockAcquit", "MockOf", "Rehearsed" } do player:SetAttribute(a, nil) end
	end
	Court.feed(player, RM.case, "Court", { ("VERDICT: %s"):format(string.upper(tostring(result.verdict))) }, "verdict")
	feedMeta[player] = nil
	-- the walk out past the cameras (free: the steps; the stakeout follows them out for a minute and a half)
	Court.stakeoutPhase(player, "after", result.verdict, if (result.secs or 0) > 0 then 20 else 90)
	-- v267/v280: appeals and the news follow the case
	cityLife("courtEvent", player, { verdict = result.verdict, secs = result.secs, judge = judge.name, text = text, death = result.death, life = result.life,
		trial = trialKind, capital = capital, minor = ctx.minor == true, video = video })
	print(("[Court] VERDICT %s: %s, %ds (%s)"):format(player.Name, result.verdict, result.secs, judge.name))
	return result
end

return Court
