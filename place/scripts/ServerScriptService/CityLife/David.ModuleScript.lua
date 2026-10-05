--[[
	CityLife.David (v277) - DAVID (Driver And Vehicle Information Database), the MDT, licences
	(spec 10.4, 15 v277)

	PERSON lookup: licence photo (avatar headshot), name, age, address (owned house), licence
	  status (valid / suspended / revoked), registered vehicles, citations, flags (warrants,
	  BOLOs, officer safety: armed / violent / cop killer, probation), criminal / court history.
	PLATE lookup: owner, type, colour, stolen, mismatch warnings (cold plates come back clean).
	Users: police player teams through the phone MDT app (Core.MDT_TEAMS).
	EVERY lookup is logged (officer + reason). An audit catches lookups with no open case:
	  repeat misuse = Internal Affairs, the news, a charge. Bought lookups (a corrupt cop paid
	  through a fixer) leave the same trail - traced back to whoever paid.
	LICENCES: automatic. Suspended for DUI, piled-up citations (6 points) or failure to appear;
	  driving while suspended is a charge. Reinstated at the clerk window (fees) or by a lawyer.
	Logs: [DAVID]
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local D = {}
local L = {} -- licences
local Core: any

local CFG = {
	SuspendPoints = 6,
	SuspendSeconds = 30 * 60,
	ReinstateFee = 2500,
	LawyerReinstateFee = 15000,
	AuditChance = 0.25,
	MisuseLimit = 3,
}

D.log = {} :: { any } -- every lookup this server: { at, officer, subject, kind, reason, case, paidBy }
local misuse: { [number]: number } = {}

---------------------------------------------------------------------------
-- licences
---------------------------------------------------------------------------
function L.status(player: Player): (string, string?)
	local p = Core.Profile.get(player)
	local l = p.licence
	-- the Drugs DUI arrest suspends through an attribute: take it onto the record
	local dui = tonumber(player:GetAttribute("LicenceSuspendedUntil"))
	if dui and dui > os.time() and l.status == "valid" then
		l.status = "suspended"
		l.reason = "DUI"
		l.suspendedUntil = dui
		Core.Profile.dirty(player)
	end
	if l.status == "suspended" and (l.suspendedUntil or 0) > 0 and os.time() >= l.suspendedUntil and l.reason ~= "Failure to appear" then
		-- the suspension ran out, but it stays suspended until the fees are paid
		return "suspended (eligible for reinstatement)", l.reason
	end
	if l.status == "suspended" and l.reason == "Failure to appear" and #Core.Warrants.list(player) == 0 then
		return "suspended (eligible for reinstatement)", l.reason
	end
	return l.status, l.reason
end
function L.suspended(player: Player): boolean
	local s = L.status(player)
	return s ~= "valid"
end
function L.suspend(player: Player, reason: string, secs: number?)
	local p = Core.Profile.get(player)
	p.licence.status = "suspended"
	p.licence.reason = reason
	p.licence.suspendedUntil = os.time() + (secs or CFG.SuspendSeconds)
	Core.Profile.dirty(player)
	Core.UI.notice(player, "Your driver's licence has been SUSPENDED: " .. reason, 7, Color3.fromRGB(120, 20, 20))
	Core.log("DAVID", "LICENCE SUSPENDED %s (%s)", player.Name, reason)
end
function L.reinstate(player: Player, how: string): boolean
	local p = Core.Profile.get(player)
	if p.licence.status == "valid" then
		Core.UI.notice(player, "Your licence is already valid", 3)
		return false
	end
	local s = L.status(player)
	local lawyer = how == "lawyer"
	if not lawyer and not string.find(s, "eligible") then
		Core.UI.notice(player, ("Not yet - your suspension (%s) hasn't run out. A lawyer can get it lifted early."):format(tostring(p.licence.reason)), 6)
		return false
	end
	local fee = if lawyer then CFG.LawyerReinstateFee else CFG.ReinstateFee
	if not Core.chargeOrSay(player, fee, "licence reinstatement") then return false end
	p.licence.status = "valid"
	p.licence.reason = nil
	p.licence.points = 0
	p.licence.suspendedUntil = 0
	Core.Profile.dirty(player)
	Core.UI.notice(player, "Licence reinstated", 4)
	Core.log("DAVID", "LICENCE REINSTATED %s (%s)", player.Name, how)
	return true
end
function L.cite(player: Player, what: string, fine: number, points: number, by: string?)
	local p = Core.Profile.get(player)
	table.insert(p.citations, { what = what, fine = fine, at = os.time(), by = by })
	while #p.citations > 30 do table.remove(p.citations, 1) end
	p.licence.points = (p.licence.points or 0) + points
	Core.Profile.dirty(player)
	-- the fine comes straight out of the bank; unpaid = it sits on the record
	local paid = Core.charge(player, fine)
	if not paid then p.citations[#p.citations].unpaid = true end
	Core.UI.notice(player, ("CITATION: %s - %s fine%s"):format(what, Core.UI.money(fine), if paid then " (paid)" else " (UNPAID - pay at the clerk window)"), 7)
	if p.licence.points >= CFG.SuspendPoints and p.licence.status == "valid" then
		L.suspend(player, "Too many points (" .. p.licence.points .. ")")
	end
end
D.Licence = L

---------------------------------------------------------------------------
-- lookups
---------------------------------------------------------------------------
-- officer safety flags kept on the profile, updated from what the police see
local function flagsFor(player: Player): { string }
	local out = {}
	local p = Core.Profile.get(player)
	for _, w in p.warrants do table.insert(out, "WARRANT: " .. w.reason) end
	local b = Core.Warrants.boloFor(player)
	if b then table.insert(out, "BOLO: " .. b.text) end
	for f in p.flags do table.insert(out, "OFFICER SAFETY: " .. string.upper(f)) end
	if player:GetAttribute("SnitchJacket") then table.insert(out, "Cooperating witness (sealed)") end
	if player:GetAttribute("CourtDateAt") then table.insert(out, "On bail - court date pending") end
	if player:GetAttribute("SentenceEnd") then table.insert(out, "IN CUSTODY - serving a sentence") end
	if player:GetAttribute("CustodyPhase") == "Escaped" then table.insert(out, "ESCAPED PRISONER") end
	return out
end

local function hasCase(subject: Player?): boolean
	if not subject then return false end
	if Core.stars(subject) > 0 or #Core.Warrants.list(subject) > 0 or Core.Warrants.boloFor(subject) then return true end
	if subject:GetAttribute("TrafficStopAt") and os.time() - (tonumber(subject:GetAttribute("TrafficStopAt")) or 0) < 600 then return true end
	if subject:GetAttribute("CustodyStage") or subject:GetAttribute("SentenceEnd") then return true end
	return false
end

local function audit(entry: any)
	table.insert(D.log, 1, entry)
	while #D.log > 200 do table.remove(D.log) end
	Core.log("DAVID", "LOOKUP %s -> %s (%s) reason=%s case=%s%s", entry.officer, entry.subject, entry.kind, entry.reason, tostring(entry.case),
		if entry.paidBy then " PAID BY " .. entry.paidBy else "")
	if entry.case then return end
	if math.random() > CFG.AuditChance then return end
	-- the audit flags a no-case lookup
	local officer = entry.officerPlayer
	if entry.paidBy then
		-- a bought lookup: Internal Affairs traces the money
		local payer = Players:FindFirstChild(entry.paidBy)
		Core.log("DAVID", "AUDIT: bought lookup on %s traced to %s", entry.subject, entry.paidBy)
		if Core.News then Core.News.post({ kind = "corruption", level = 2, headline = "Officer fired over database lookups for cash",
			body = ("Internal Affairs says an officer ran %s through DAVID with no case open - and the money led back to %s."):format(entry.subject, entry.paidBy),
			subjects = if payer then { payer } else nil }) end
		if payer and payer:IsA("Player") then
			if Core.inCustody(payer) then
				local rec = Core.records()
				if rec and rec.note then pcall(rec.note, payer, "bribery") end
			else
				Core.Warrants.issue(payer, { reason = "Bribery of a public official (DAVID lookup)", crimes = { "Bribery" }, severity = 2, source = "internal affairs" })
			end
		end
		return
	end
	if officer and officer.Parent then
		misuse[officer.UserId] = (misuse[officer.UserId] or 0) + 1
		local n = misuse[officer.UserId]
		Core.UI.notice(officer, ("INTERNAL AFFAIRS: your lookup of %s had no open case. Strike %d of %d."):format(entry.subject, n, CFG.MisuseLimit), 8, Color3.fromRGB(120, 20, 20))
		if n >= CFG.MisuseLimit then
			misuse[officer.UserId] = 0
			Core.log("DAVID", "IA: %s fired for database misuse", officer.Name)
			if Core.News then Core.News.post({ kind = "corruption", level = 2, headline = "Officer fired for database misuse",
				body = ("%s ran people through DAVID with no case. Internal Affairs has opened a criminal inquiry."):format(officer.Name), subjects = { officer } }) end
			-- off the force: a civilian team, and a charge
			local civ = game:GetService("Teams"):FindFirstChild("Civilian") or game:GetService("Teams"):FindFirstChild("Citizens")
			if civ then officer.Team = civ end
			Core.report(officer, "MisuseOfDatabase", nil, 10)
		end
	end
end

function D.person(officer: any, subject: Player, reason: string, paidBy: string?): any
	local p = Core.Profile.get(subject)
	local house = nil
	local hf = ServerStorage:FindFirstChild("HouseOf")
	if hf and hf:IsA("BindableFunction") then
		local ok, m = pcall(hf.Invoke, hf, subject)
		if ok and typeof(m) == "Instance" then house = m.Name end
	end
	local vehicles = {}
	for name, reg in p.cars do
		table.insert(vehicles, ("%s - %s, plate %s%s"):format(name, reg.colour or "?", reg.plate, if reg.fitted then " (different plate fitted!)" else ""))
	end
	local history = {}
	local rec = Core.records()
	if rec then
		local ok, r = pcall(rec.get, subject)
		if ok and type(r) == "table" then
			for i = #(r.arrests or {}), math.max(1, #(r.arrests or {}) - 5), -1 do
				local a = r.arrests[i]
				if a then table.insert(history, ("%s - %s%s"):format(os.date("%m/%d %H:%M", a.t or os.time()), tostring(a.charges or "?"), if a.outcome then " -> " .. tostring(a.outcome) else "")) end
			end
		end
	end
	local cites = {}
	for i = #p.citations, math.max(1, #p.citations - 4), -1 do
		local c = p.citations[i]
		if c then table.insert(cites, ("%s %s%s"):format(c.what, Core.UI.money(c.fine), if c.unpaid then " UNPAID" else "")) end
	end
	local status, why = L.status(subject)
	local ageDays = subject.AccountAge
	local entry = { at = os.time(), officer = if typeof(officer) == "Instance" then officer.Name else tostring(officer), officerPlayer = if typeof(officer) == "Instance" then officer else nil,
		subject = subject.Name, kind = "person", reason = reason, case = hasCase(subject), paidBy = paidBy }
	audit(entry)
	return {
		name = (subject:GetAttribute("CharacterName") or subject.DisplayName) .. " (@" .. subject.Name .. ")",
		userId = subject.UserId,
		age = 21 + (ageDays % 40),
		address = house or "No fixed address",
		licence = status .. (if why then " - " .. why else ""),
		points = p.licence.points or 0,
		vehicles = vehicles,
		citations = cites,
		flags = flagsFor(subject),
		history = history,
		warrants = #p.warrants,
	}
end

function D.plate(officer: any, plate: string, reason: string): any
	local rec = Core.Plates.lookup(plate)
	local entry = { at = os.time(), officer = if typeof(officer) == "Instance" then officer.Name else tostring(officer), officerPlayer = if typeof(officer) == "Instance" then officer else nil,
		subject = "plate " .. plate, kind = "plate", reason = reason, case = true }
	audit(entry)
	if not rec then return { plate = plate, found = false } end
	local now = os.time()
	local flags = {}
	if rec.stolenAt and now >= rec.stolenAt then table.insert(flags, "VEHICLE REPORTED STOLEN") end
	if rec.plateStolenAt and now >= rec.plateStolenAt then table.insert(flags, "PLATE REPORTED STOLEN") end
	if rec.burned then table.insert(flags, "Plate flagged - seen in a crime") end
	local owner = rec.ownerId and Players:GetPlayerByUserId(rec.ownerId)
	if owner then
		for _, w in Core.Warrants.list(owner) do table.insert(flags, "Owner warrant: " .. w.reason) end
		if L.suspended(owner) then table.insert(flags, "Owner licence suspended") end
	end
	-- is that car out right now, and does it match?
	local where = nil
	local function scan(folder: Instance?)
		if not folder then return end
		for _, m in folder:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Plate") == plate then
				local d = Core.Plates.describe(m)
				if d.type ~= rec.type or string.lower(d.colour) ~= string.lower(rec.colour or "") then
					table.insert(flags, ("MISMATCH: plate is on a %s %s"):format(string.lower(d.colour), d.type))
				end
				local pp = m.PrimaryPart
				if pp then where = Core.placeName(pp.Position) end
			end
		end
	end
	scan(workspace:FindFirstChild("SpawnedCars"))
	return { plate = plate, found = true, owner = rec.owner, ownerId = rec.ownerId, type = rec.type, colour = rec.colour, flags = flags, seen = where,
		registered = os.date("%m/%d/%Y", rec.at or os.time()) }
end

-- a corrupt lookup bought through a fixer (Connections): address, plates
function D.bought(payer: Player, subject: Player): any
	local fakeOfficer = "Ofc. " .. Core.fakeName()
	local info = D.person(fakeOfficer, subject, "bought", payer.Name)
	return info
end

---------------------------------------------------------------------------
function D.init(core: any)
	Core = core
	Core.Licence = L
	Core.David = D

	Core.app("mdt.person", function(player: Player, name: any, reason: any)
		if not Core.canMDT(player) then return { error = "MDT is for police officers" } end
		local subject = Core.byName(name)
		if not subject then return { error = "No match for '" .. tostring(name) .. "'" } end
		return D.person(player, subject, tostring(reason or "investigation"))
	end)
	Core.app("mdt.plate", function(player: Player, plate: any, reason: any)
		if not Core.canMDT(player) then return { error = "MDT is for police officers" } end
		if type(plate) ~= "string" or #plate < 3 then return { error = "Enter a plate" } end
		return D.plate(player, string.upper(plate), tostring(reason or "investigation"))
	end)
	Core.app("mdt.nearby", function(player: Player)
		if not Core.canMDT(player) then return {} end
		local r = Core.root(player)
		if not r then return {} end
		local out = {}
		for _, p in Players:GetPlayers() do
			local pr = p ~= player and Core.root(p)
			if pr and (pr.Position - r.Position).Magnitude < 120 then table.insert(out, { kind = "person", label = (p:GetAttribute("CharacterName") or p.DisplayName), value = p.Name }) end
		end
		local sp = workspace:FindFirstChild("SpawnedCars")
		if sp then
			for _, m in sp:GetChildren() do
				local pp = m:IsA("Model") and m.PrimaryPart
				if pp and (pp.Position - r.Position).Magnitude < 120 and m:GetAttribute("Plate") then
					local d = Core.Plates.describe(m)
					table.insert(out, { kind = "plate", label = ("%s %s %s"):format(d.colour, d.type, tostring(d.plate)), value = d.plate })
				end
			end
		end
		return out
	end)
	Core.app("mdt.lists", function(player: Player)
		if not Core.canMDT(player) and not Core.isChief(player) then return nil end
		local warrants = {}
		for _, p in Players:GetPlayers() do
			for _, w in Core.Warrants.list(p) do
				table.insert(warrants, { name = p.Name, reason = w.reason, severity = w.severity, source = w.source, at = w.at })
			end
		end
		local bolos = {}
		for _, b in Core.Warrants.activeBolos() do table.insert(bolos, { id = b.id, text = b.text, subject = b.subject, at = b.at }) end
		local log = {}
		for i = 1, math.min(15, #D.log) do
			local e = D.log[i]
			table.insert(log, ("%s %s -> %s (%s)%s"):format(os.date("%H:%M", e.at), e.officer, e.subject, e.reason, if e.case then "" else " NO CASE"))
		end
		return { warrants = warrants, bolos = bolos, log = log }
	end)
	Core.app("mdt.bolo", function(player: Player, text: any)
		if not Core.canMDT(player) then return false end
		if type(text) ~= "string" or #text < 4 then return false end
		local r = Core.root(player)
		Core.Warrants.bolo({ text = string.sub(text, 1, 140), pos = r and r.Position, by = player.Name })
		return true
	end)
	Core.app("mdt.flag", function(player: Player, name: any, flag: any)
		if not Core.canMDT(player) then return false end
		local subject = Core.byName(name)
		if not subject or (flag ~= "armed" and flag ~= "violent" and flag ~= "copkiller") then return false end
		local p = Core.Profile.get(subject)
		p.flags[flag] = true
		Core.Profile.dirty(subject)
		return true
	end)

	-- the police mark people themselves: officer safety flags from what they do
	Core.onCrime(function(player: Player, crime: string)
		local flag = if crime == "CopKilled" then "copkiller" elseif crime == "Murder" or crime == "AssaultOfficer" then "violent"
			elseif crime == "ShotsFired" or crime == "Robbery" or crime == "BankRobbery" then "armed" else nil
		if flag then
			local p = Core.Profile.get(player)
			if not p.flags[flag] then
				p.flags[flag] = true
				Core.Profile.dirty(player)
			end
		end
	end)

	-- the courthouse clerk window (and DMV counter): warrants, fines, licences, registration
	task.spawn(function()
		local window = nil
		for _ = 1, 60 do
			local ch = workspace:FindFirstChild("Courthouse")
			local m = ch and ch:FindFirstChild("CourtMarkers")
			window = m and m:FindFirstChild("ClerkWindow")
			if window then break end
			task.wait(1)
		end
		-- the DMV building (workspace.DMV, a part named DMVCounter) gets the same counter
		local function attach(part: BasePart, title: string)
		local pp = Instance.new("ProximityPrompt")
		pp.Name = "ClerkServicesPrompt"
		pp.ActionText = if title == "DMV" then "DMV services" else "Clerk services"
		pp.ObjectText = title
		pp.KeyboardKeyCode = Enum.KeyCode.R
		pp.HoldDuration = 0.3
		pp.MaxActivationDistance = 10
		pp.RequiresLineOfSight = false
		pp.UIOffset = Vector2.new(0, 60)
		pp.Parent = part
		pp.Triggered:Connect(function(player: Player)
			local prof = Core.Profile.get(player)
			local unpaid = 0
			for _, c in prof.citations do if c.unpaid then unpaid += c.fine end end
			local status = L.status(player)
			local opts = { "Do I have any warrants?", ("Pay unpaid citations (%s)"):format(Core.UI.money(unpaid)),
				("Reinstate my licence (%s) - %s"):format(Core.UI.money(CFG.ReinstateFee), status),
				"Re-register my vehicle (DMV, $250)", "Turn myself in", "Nothing, thanks" }
			local pick = Core.UI.ask(player, { title = "Clerk of the Court", body = "How can I help you?", options = opts, timeout = 30 })
			if pick == 1 then
				local ws = Core.Warrants.list(player)
				if #ws == 0 then
					Core.UI.notice(player, "Clerk: \"Nothing on file. Have a good day.\"", 4)
				else
					local names = {}
					for _, w in ws do table.insert(names, w.reason) end
					Core.UI.notice(player, "Clerk: \"There's an active warrant: " .. table.concat(names, "; ") .. ". You should turn yourself in.\"", 8, Color3.fromRGB(120, 20, 20))
				end
			elseif pick == 2 then
				if unpaid <= 0 then Core.UI.notice(player, "Nothing unpaid", 3) return end
				if Core.chargeOrSay(player, unpaid, "unpaid citations") then
					for _, c in prof.citations do c.unpaid = nil end
					Core.Profile.dirty(player)
				end
			elseif pick == 3 then
				L.reinstate(player, "clerk")
			elseif pick == 4 then
				Core.Plates.reregister(player)
			elseif pick == 5 then
				if #Core.Warrants.list(player) == 0 and Core.stars(player) == 0 then
					Core.UI.notice(player, "Clerk: \"You're not wanted for anything.\"", 4)
					return
				end
				-- the HQ front desk takes surrenders
				local ps = workspace:FindFirstChild("PoliceStation")
				local fm = ps and ps:FindFirstChild("FacilityMap")
				local pts = fm and fm:FindFirstChild("Points")
				local desk = pts and (pts:FindFirstChild("TurnInPoint_1") or pts:FindFirstChild("FrontDesk_1"))
				if desk and desk:IsA("BasePart") then Core.UI.waypoint(player, "turnin", desk.Position, "Turn yourself in") end
				Core.UI.notice(player, "Clerk: \"Surrenders are taken at the Police HQ front desk. I've called ahead - it'll go better for you.\"", 7)
			end
		end)
		end
		if window then attach(window, "Clerk of the Court") end
		local dmv = workspace:FindFirstChild("DMV")
		local counter = dmv and dmv:FindFirstChild("DMVCounter", true)
		if counter and counter:IsA("BasePart") then attach(counter, "DMV") end
	end)

	-- FTA suspends the licence
	Core.on("warrant", function(player: Player, w: any)
		if w.reason:lower():find("appear") then L.suspend(player, "Failure to appear", 0) end
	end)
	print("[DAVID] v277 ready (person / plate lookups, audits, licences)")
end

return D
