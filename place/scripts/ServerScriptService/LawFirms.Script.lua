--[[
	LawFirms (v257) - law offices, retainers, hourly billing, the 3 AM call.

	Firms (spec 9.1): Public Defender, Local Attorney, Experienced Defense Counsel,
	Criminal Defense Firm, Elite Defense Team, National Trial Firm, Premier Counsel.

	OFFICES: every building mapped as a LawOffice (Facility Mapper) is a firm's office.
	The firm is the Firm attribute on the building or its FacilityMap; an office
	without one is used as the Local Attorney's office (and the log says so). The
	receptionist stands at the Reception point (or LawyerSeat / the first room).
	At reception: get a quote, put the firm on retainer, see your legal bill, top up
	the trust balance, end the retainer. Criminal Defense Firm and up only sign a
	retainer IN PERSON; the cheaper ones also take it over the phone (Lawyer button).

	MONEY (spec 9.2-9.3):
	  * retainer = a trust balance; hours are billed against it at the firm's rate
	  * on retainer BEFORE an arrest: a billing-cycle fee (every CycleSeconds), 25% off
	    the hourly rate, an instant call when you're arrested, bail -20% (Bail module),
	    and the firm is used at prison booking without paying again
	  * hired after the arrest: the full retainer up front (frozen money can't pay -
	    AssetFreeze already holds it), full rate
	  * trust running low -> the lawyer calls for a top-up; can't pay -> debt, then
	    they withdraw and a Public Defender is appointed
	3 AM (spec 9.4): the game clock (Lighting.ClockTime) 22:00-06:00 is night; cheap
	firms often sleep through the arrest call (voicemail, then "Sorry, I was asleep...").

	Saved in the criminal record (Records, rec.lawyer). Attributes: CounselRetained,
	LawyerFirm, LawyerTrust, LawyerDebt, LawyerPresent. Logs: [Law]
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local FIRMS = {
	{ name = "Public Defender", retainer = 0, rate = 0, night = 0.25, inPerson = false },
	{ name = "Local Attorney", retainer = 10000, rate = 250, night = 0.35, inPerson = false },
	{ name = "Experienced Defense Counsel", retainer = 50000, rate = 650, night = 0.6, inPerson = false },
	{ name = "Criminal Defense Firm", retainer = 250000, rate = 1600, night = 0.85, inPerson = true, junior = true },
	{ name = "Elite Defense Team", retainer = 1000000, rate = 4500, night = 1, inPerson = true },
	{ name = "National Trial Firm", retainer = 5000000, rate = 9000, night = 1, inPerson = true },
	{ name = "Premier Counsel", retainer = 10000000, rate = 15000, night = 1, inPerson = true },
}
local BY_NAME = {}
for i, f in FIRMS do f.tier = i; BY_NAME[f.name] = f end
-- v291: a player attorney in their own practice (Attorneys): their own rate, no retainer schedule
BY_NAME["Independent Counsel"] = { name = "Independent Counsel", retainer = 0, rate = 0, night = 1, inPerson = false, tier = 4 }

local CFG = {
	CycleSeconds = 30 * 60, -- one billing cycle (a game "month")
	CycleShare = 0.05, -- cycle fee = 5% of the retainer
	RetainedDiscount = 0.25, -- hourly rate off while on retainer
	LowTrustHours = 2, -- top-up call below this many hours
	MaxUnpaidCalls = 2, -- then they withdraw
}

-- hours per activity (spec 9.2)
local HOURS = {
	call = { 0.5, 1 }, interrogation = { 1, 3 }, bail = { 2, 4 }, plea = { 1, 3 }, motions = { 3, 8 },
	bench = { 8, 15 }, jury = { 20, 60 }, appeal = { 15, 30 }, meeting = { 0.5, 1.5 },
}

local Records: any = nil
local F: any = nil
task.spawn(function()
	local ps = ServerScriptService:WaitForChild("PoliceSystem", 30)
	for _ = 1, 30 do
		if ps then
			local rm, fm = ps:FindFirstChild("Records"), ps:FindFirstChild("Facilities")
			if rm and not Records then local ok, m = pcall(require, rm); if ok then Records = m end end
			if fm and not F then local ok, m = pcall(require, fm); if ok then F = m end end
		end
		if Records and F then break end
		task.wait(1)
	end
end)

local function phone(): BindableFunction?
	local f = ServerStorage:FindFirstChild("Phone")
	return if f and f:IsA("BindableFunction") then f else nil
end

local function money(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then out = out:sub(2) end
	return (if n < 0 then "-$" else "$") .. out
end

local function notice(p: Player, text: string)
	local r = game:GetService("ReplicatedStorage"):FindFirstChild("PhoneCalls")
	if r and r:IsA("RemoteEvent") and p.Parent then r:FireClient(p, "notice", text) end
end

-- the dialog card (no ringing) -> option index or nil
local function dialog(p: Player, from: string, lines: { string }, options: { string }): number?
	local f = phone()
	if not f then return nil end
	local ok, how, idx = pcall(f.Invoke, f, "dialog", p, { from = from, lines = lines, options = options })
	if ok and how == "answered" then return idx end
	return nil
end

local function call(p: Player, spec: any): (string?, number?)
	local f = phone()
	if not f then notice(p, tostring(spec.from) .. ": " .. table.concat(spec.lines or {}, " ")); return nil, nil end
	local ok, how, idx = pcall(f.Invoke, f, "call", p, spec)
	if ok then return how, idx end
	return nil, nil
end

---------------------------------------------------------------------------
-- the account (saved in the record)
---------------------------------------------------------------------------
local function acct(p: Player): any
	if not Records then return {} end
	local rec = Records.get(p)
	rec.lawyer = rec.lawyer or { firm = nil, retained = false, trust = 0, debt = 0, hours = 0, billed = 0, nextCycle = 0, unpaid = 0, log = {} }
	rec.lawyer.log = rec.lawyer.log or {}
	return rec.lawyer
end

local function save(p: Player)
	local a = acct(p)
	p:SetAttribute("CounselRetained", if a.retained then a.firm else nil)
	p:SetAttribute("LawyerFirm", a.firm)
	p:SetAttribute("LawyerTrust", math.floor(a.trust or 0))
	p:SetAttribute("LawyerDebt", if (a.debt or 0) > 0 then math.floor(a.debt) else nil)
	if Records and Records.touch then pcall(Records.touch, p) end
end

local function rateFor(a: any): number
	if a.firm == "Independent Counsel" and tonumber(a.playerRate) then return math.floor(a.playerRate) end
	local f = BY_NAME[a.firm or ""]
	if not f then return 0 end
	return math.floor(f.rate * (if a.retained then 1 - CFG.RetainedDiscount else 1))
end

local function isNight(): boolean
	local t = Lighting.ClockTime
	return t >= 22 or t < 6
end

local function available(p: Player): number
	local c, b = p:FindFirstChild("Cash"), p:FindFirstChild("Money")
	return (if c and c:IsA("IntValue") then c.Value else 0) + (if b and b:IsA("IntValue") then b.Value else 0)
end

local function charge(p: Player, amount: number): boolean
	amount = math.floor(amount)
	if available(p) < amount then return false end
	-- v257b: through the Economy, so the dirty-money share (v255) stays right
	local eco = ServerStorage:FindFirstChild("Economy")
	if eco and eco:IsA("BindableFunction") then
		local ok, paid = pcall(eco.Invoke, eco, "Charge", p, amount)
		return ok and paid == true
	end
	local c, b = p:FindFirstChild("Cash") :: IntValue?, p:FindFirstChild("Money") :: IntValue?
	local fromCash = if c then math.min(c.Value, amount) else 0
	if c then c.Value -= fromCash end
	if b and amount - fromCash > 0 then b.Value -= amount - fromCash end
	return true
end

local withdraw -- forward

-- bill an activity -> hours billed
local function bill(p: Player, activity: string, complexity: number?): number
	local a = acct(p)
	local f = BY_NAME[a.firm or ""]
	if not f or rateFor(a) <= 0 then return 0 end
	local r = HOURS[activity] or HOURS.call
	local hours = (r[1] + math.random() * (r[2] - r[1])) * (complexity or 1)
	hours = math.floor(hours * 10 + 0.5) / 10
	local cost = math.floor(hours * rateFor(a))
	a.hours = (a.hours or 0) + hours
	a.billed = (a.billed or 0) + cost
	a.trust = (a.trust or 0) - cost
	if a.trust < 0 then
		a.debt = (a.debt or 0) - a.trust
		a.trust = 0
	end
	table.insert(a.log, 1, ("%s: %.1f h = %s"):format(activity, hours, money(cost)))
	-- v291: a player attorney on the case gets their share of every hour (Attorneys)
	if a.playerAttorney then
		local at = ServerStorage:FindFirstChild("Attorneys")
		if at and at:IsA("BindableFunction") then
			local okS, share = pcall(at.Invoke, at, "share", a.firm)
			pcall(at.Invoke, at, "earn", a.playerAttorney, cost * (if okS and tonumber(share) then share else 0.5), p:GetAttribute("CharacterName") or p.DisplayName)
		end
	end
	while #a.log > 8 do table.remove(a.log) end
	save(p)
	print(("[Law] BILL %s %s %.1fh %s (trust %s, debt %s)"):format(p.Name, activity, hours, money(cost), money(a.trust), money(a.debt or 0)))
	-- running low: the lawyer calls for a top-up
	if a.trust < rateFor(a) * CFG.LowTrustHours then
		task.spawn(function()
			local need = math.floor(math.max(f.retainer * 0.25, rateFor(a) * 10) + (a.debt or 0))
			local how, idx = call(p, {
				from = f.name, kind = "lawyer", legal = true, expires = 300,
				lines = { ("Your trust balance is %s%s. We need %s to keep working your case."):format(money(a.trust),
					if (a.debt or 0) > 0 then (" and you owe us %s"):format(money(a.debt)) else "", money(need)) },
				options = { ("Pay %s now"):format(money(need)), "I can't right now" },
			})
			if how == "answered" and idx == 1 and charge(p, need) then
				local pay = need - (a.debt or 0)
				a.debt = 0
				a.trust += pay
				a.unpaid = 0
				save(p)
				notice(p, ("%s: trust topped up to %s"):format(f.name, money(a.trust)))
				print(("[Law] TOPUP %s %s"):format(p.Name, money(need)))
			else
				a.unpaid = (a.unpaid or 0) + 1
				save(p)
				if a.unpaid >= CFG.MaxUnpaidCalls and (a.debt or 0) > 0 then withdraw(p, "unpaid bills") end
			end
		end)
	end
	return hours
end

withdraw = function(p: Player, why: string)
	local a = acct(p)
	local old = a.firm
	a.firm = "Public Defender"
	a.playerAttorney, a.playerRate = nil, nil -- v291
	p:SetAttribute("PlayerAttorney", nil)
	a.retained = false
	a.trust = 0
	a.unpaid = 0
	save(p)
	if p:GetAttribute("CounselName") and p:GetAttribute("CounselName") ~= "Public Defender" then
		p:SetAttribute("CounselName", "Public Defender")
	end
	notice(p, ("%s has withdrawn from your case (%s). A Public Defender has been appointed. You still owe %s."):format(tostring(old), why, money(a.debt or 0)))
	print(("[Law] WITHDREW %s from %s (%s) debt=%s"):format(tostring(old), p.Name, why, money(a.debt or 0)))
end

---------------------------------------------------------------------------
-- quotes
---------------------------------------------------------------------------
local function caseKind(p: Player): (string, string, number)
	local text = string.lower(tostring(p:GetAttribute("CaseCharges") or p:GetAttribute("Charges") or ""))
	if text:find("murder") or text:find("officer") then return "murder / cop killing", "jury", 1.6 end
	if text:find("bank") or text:find("robbery") or text:find("escape") then return "armed robbery / heist", "jury", 1.2 end
	if text ~= "" then return "felony / misdemeanor", "bench", 1 end
	return "no open case", "bench", 1
end

local function quoteLines(p: Player, f: any): { string }
	local kind, trial, cx = caseKind(p)
	local a = acct(p)
	local rate = if a.firm == f.name and a.retained then math.floor(f.rate * (1 - CFG.RetainedDiscount)) else f.rate
	local r = HOURS[trial]
	local lo, hi = math.floor(r[1] * cx), math.floor(r[2] * cx)
	local lines = {
		("Retainer: %s  |  Hourly: %s"):format(money(f.retainer), money(f.rate)),
		("Your case: %s. A %s trial runs %d-%d h, about %s-%s."):format(kind, trial, lo, hi, money(lo * rate), money(hi * rate)),
		("On retainer before trouble: %s every billing cycle, %d%% off the hourly rate, we pick up when you're arrested."):format(
			money(f.retainer * CFG.CycleShare), math.floor(CFG.RetainedDiscount * 100)),
	}
	if f.tier >= 5 and kind == "no open case" then table.insert(lines, "(Frankly, for parking tickets you don't need us.)") end
	if f.tier <= 2 and cx >= 1.6 then table.insert(lines, "(A homicide is out of our depth. You want a bigger firm.)") end
	return lines
end

local function billLines(p: Player): { string }
	local a = acct(p)
	if not a.firm or a.firm == "Public Defender" then return { "You have no paid counsel." .. (if (a.debt or 0) > 0 then " Old debt: " .. money(a.debt) else "") } end
	local lines = {
		("Counsel: %s%s"):format(a.firm, if a.retained then " (on retainer)" else ""),
		("Trust balance: %s  |  Rate: %s/h  |  Hours billed: %.1f (%s)"):format(money(a.trust or 0), money(rateFor(a)), a.hours or 0, money(a.billed or 0)),
	}
	if (a.debt or 0) > 0 then table.insert(lines, "Unpaid: " .. money(a.debt)) end
	if a.retained then table.insert(lines, ("Next billing cycle in %d min."):format(math.max(0, math.ceil(((a.nextCycle or 0) - os.time()) / 60)))) end
	for i = 1, math.min(4, #a.log) do table.insert(lines, a.log[i]) end
	return lines
end

-- sign on (retainer before an arrest, or hiring for an open case)
local function signOn(p: Player, f: any, retainerOnly: boolean): boolean
	local a = acct(p)
	local fee = if retainerOnly then math.floor(f.retainer * CFG.CycleShare) else f.retainer
	if f.rate <= 0 then
		a.firm, a.retained, a.trust = f.name, false, 0
		save(p)
		return true
	end
	if not charge(p, fee) then
		notice(p, ("You need %s (frozen money doesn't count)."):format(money(fee)))
		return false
	end
	local same = a.firm == f.name
	if not same then a.hours, a.billed, a.log, a.trust = 0, 0, {}, 0 end
	if not same then a.playerAttorney, a.playerRate = nil, nil; p:SetAttribute("PlayerAttorney", nil) end -- v291
	a.firm = f.name
	a.retained = retainerOnly or (same and a.retained)
	if not retainerOnly then a.trust = (a.trust or 0) + fee end
	a.nextCycle = os.time() + CFG.CycleSeconds
	a.unpaid = 0
	save(p)
	print(("[Law] SIGNED %s with %s (%s, %s)"):format(p.Name, f.name, if retainerOnly then "retainer" else "hired", money(fee)))
	return true
end

---------------------------------------------------------------------------
-- v257b LEGAL VISITS (spec 9.6): an inmate's lawyer in the prison visiting rooms.
-- Glass for routine talks, contact when there's a lot to go over. Pay the lawyer a lot
-- extra on a contact visit and they slip you something; elite lawyers are searched
-- less, cheap ones are riskier and may give you up to save themselves.
---------------------------------------------------------------------------
local COURIER = {
	{ name = "Cash ($1,000)", item = "Cash", minTier = 2, rateHours = 2, extra = 1000 },
	{ name = "Pills", item = "Pills", minTier = 2, rateHours = 3, extra = 0 },
	{ name = "Spice", item = "Spice", minTier = 3, rateHours = 4, extra = 0 },
	{ name = "Lockpick", item = "Lockpick", minTier = 4, rateHours = 8, extra = 0 },
	{ name = "Shiv", item = "Shiv", minTier = 6, rateHours = 10, extra = 0 },
}
-- chance a CO search finds it, by firm tier (1 = PD ... 7 = Premier)
local SEARCH = { 0.5, 0.35, 0.25, 0.18, 0.1, 0.08, 0.05 }
local visiting: { [Player]: boolean } = {}

local function serving(p: Player): boolean
	return p:GetAttribute("SentenceEnd") ~= nil and p:GetAttribute("Visiting") == nil
end

local function giveContraband(p: Player, item: string)
	if item == "Cash" then
		local eco = ServerStorage:FindFirstChild("Economy")
		if eco then pcall(eco.Invoke, eco, "AddCash", p, 1000) end
	elseif item == "Lockpick" then
		local lp = ServerStorage:FindFirstChild("Lockpicks")
		if lp then
			pcall(lp.Invoke, lp, "Give", p)
			local bp = p:FindFirstChildOfClass("Backpack")
			local tool = bp and bp:FindFirstChild("Lockpick")
			if tool then tool:SetAttribute("Contraband", true) end
		end
	else
		local fn = ServerStorage:FindFirstChild("PrisonContraband")
		if fn then pcall(fn.Invoke, fn, p, item) end
	end
end

-- the conversation in the visiting room (runs inside PrisonExtras' legal visit)
local function visitTalk(p: Player, info: any): any
	local a = acct(p)
	local f = BY_NAME[a.firm or ""] or FIRMS[1]
	local result = { caught = false }
	local secs = math.max(0, (tonumber(p:GetAttribute("SentenceEnd")) or os.time()) - os.time())
	local kind = caseKind(p)
	local intro = {
		if f.tier <= 1 then "Public Defender's office. I've got ten minutes." else "Good to see you. This room is privileged - nobody's listening.",
		("Time left: %d:%02d. Charges: %s."):format(secs // 60, secs % 60, kind),
	}
	for _ = 1, 6 do
		local opts, acts = {}, {}
		local function add(t: string, fn: () -> boolean?) table.insert(opts, t); table.insert(acts, fn) end
		add("Go over my case", function()
			dialog(p, f.name, {
				if f.tier >= 5 then "We're reviewing every step of your arrest. If they cut corners, we'll find it." else "Keep your head down, no write-ups. Good behaviour is your best argument right now.",
				"An appeal goes through the prison court once you have a trial conviction.",
			}, { "OK" })
			bill(p, "meeting")
			return false
		end)
		add("Send a message to my crew", function()
			dialog(p, f.name, { "I'll pass it on. Attorney-client - it never happened." }, { "OK" })
			bill(p, "call")
			print(("[Law] MESSAGE OUT %s via %s"):format(p.Name, f.name))
			return false
		end)
		if info.contact and f.rate > 0 then
			add("Slip me something...", function()
				local items, list = {}, {}
				for _, c in COURIER do
					if f.tier >= c.minTier then
						local price = math.floor(rateFor(a) * c.rateHours + c.extra)
						table.insert(items, { c = c, price = price })
						table.insert(list, ("%s - %s"):format(c.name, money(price)))
					end
				end
				if #items == 0 then
					dialog(p, f.name, { "I'm going to pretend you didn't ask that." }, { "OK" })
					return false
				end
				table.insert(list, "Never mind")
				local idx = dialog(p, f.name, { "(quietly) That's... not something I do. For the right fee." }, list)
				local pick = idx and items[idx]
				if not pick then return false end
				if not charge(p, pick.price) then
					dialog(p, f.name, { "Not with what you've got. Frozen money doesn't count." }, { "OK" })
					return false
				end
				print(("[Law] COURIER %s: %s brings %s for %s"):format(p.Name, f.name, pick.c.item, money(pick.price)))
				if math.random() < (SEARCH[f.tier] or 0.3) then
					result.caught = true
					notice(p, ("CAUGHT - the COs searched %s and found the %s"):format(f.name, pick.c.name))
					local report = ServerStorage:FindFirstChild("ReportCrime")
					if report then pcall(report.Invoke, report, p, "Smuggling contraband into a prison", 2) end
					-- cheap lawyers save themselves
					if f.tier <= 2 and math.random() < 0.5 then
						notice(p, f.name .. " told the COs it was all your idea.")
					end
					print(("[Law] COURIER CAUGHT %s / %s - lawyer drops the case"):format(p.Name, f.name))
					withdraw(p, "caught smuggling contraband for you")
					return true
				end
				giveContraband(p, pick.c.item)
				notice(p, ("%s slid it over under the table: %s"):format(f.name, pick.c.name))
				return false
			end)
		end
		add("That's all", function() return true end)
		local idx = dialog(p, f.name .. " - legal visit", intro, opts)
		intro = { "Anything else?" }
		if not idx or not acts[idx] or acts[idx]() then break end
	end
	return result
end

local function requestVisit(p: Player, contact: boolean)
	if visiting[p] then return end
	local fn = ServerStorage:FindFirstChild("LegalVisit")
	if not (fn and fn:IsA("BindableFunction")) then
		notice(p, "Legal visits aren't available right now.")
		return
	end
	local a = acct(p)
	local firm = a.firm or "Public Defender"
	visiting[p] = true
	notice(p, ("%s is coming for a %s visit."):format(firm, if contact then "contact" else "glass"))
	task.wait(if (BY_NAME[firm] or FIRMS[1]).tier >= 5 then 10 else 30) -- the better the firm, the sooner
	if p.Parent and serving(p) then
		local ok, res, why = pcall(fn.Invoke, fn, p, firm, contact, visitTalk)
		if not ok or res ~= true then
			notice(p, "The visit couldn't happen: " .. tostring(if ok then why else res))
		end
	end
	visiting[p] = nil
end

---------------------------------------------------------------------------
-- v290h CASE MEETINGS: sitting down with your lawyer about THIS case (the case file: what the
-- police say happened, what they really have and don't), the defence options and how each one
-- plays, practising your testimony against an associate playing the DA - and for the top two
-- firms, a MOCK TRIAL: associates as the judge and the DA, six paid strangers as the jury, your
-- story tested before the real thing. The court reads what came out of it (MockTheory / MockCat /
-- MockAcquit / MockOf / Rehearsed / CasePrepared).
---------------------------------------------------------------------------
local CourtMod: any = nil
local function court(): any
	if CourtMod then return CourtMod end
	local ps = ServerScriptService:FindFirstChild("PoliceSystem")
	local m = ps and ps:FindFirstChild("Court")
	if m and m:IsA("ModuleScript") then
		local ok, r = pcall(require, m)
		if ok then CourtMod = r end
	end
	return CourtMod
end
-- v291: the trial engine (the case board: which of the State's weaknesses are real)
local TrialMod: any = nil
local function trialMod(): any
	if TrialMod then return TrialMod end
	local ps = ServerScriptService:FindFirstChild("PoliceSystem")
	local m = ps and ps:FindFirstChild("Trial")
	if m then local ok, r = pcall(require, m); if ok then TrialMod = r end end
	return TrialMod
end
local function digInto(p: Player, file: any?, n: number, focus: string?): { string }
	local T = trialMod()
	if not (T and file) then return {} end
	local ok, r = pcall(T.reveal, p, file, T.ivs[p.UserId], n, focus)
	return if ok and type(r) == "table" then r else {}
end
local function caseFile(p: Player): any?
	local api = ServerStorage:FindFirstChild("CityLifeApi")
	if not (api and api:IsA("BindableFunction")) then return nil end
	local ok, f = pcall(api.Invoke, api, "caseFile", p)
	return if ok and type(f) == "table" then f else nil
end
local function bigCase(p: Player, F: any?): boolean
	local _, _, cx = caseKind(p)
	return cx >= 1.2 or (F ~= nil and F.big == true)
end
-- the dialog card on a readable clock that answers itself (the court's own card)
local function ask(p: Player, from: string, lines: { string }, options: { string }, default: number?): number?
	local C = court()
	if C and C.card then return C.card(p, from, lines, options, default) end
	return dialog(p, from, lines, options)
end

-- a spot on the floor under `v` (the stage NPCs stand on whatever is there)
local function ground(v: Vector3, ignore: { Instance }?): Vector3
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore or {}
	local h = Workspace:Raycast(v + Vector3.new(0, 4, 0), Vector3.new(0, -30, 0), rp)
	return if h then h.Position else v
end
local function flatUnit(v: Vector3, fallback: Vector3): Vector3
	local f = v * Vector3.new(1, 0, 1)
	return if f.Magnitude > 0.1 then f.Unit else fallback
end
local function longAxis(part: BasePart): (Vector3, number, Vector3, number)
	local cf, s = part.CFrame, part.Size
	if s.X >= s.Z then return cf.RightVector, s.X, cf.LookVector, s.Z end
	return cf.LookVector, s.Z, cf.RightVector, s.X
end

-- where a firm holds its mock trials: Premier Counsel's mock courtroom (the floor with the MOCK
-- COURTROOM sign), the National Trial Firm's big ground-floor conference room
local stageCache: { [string]: any } = {}
local function mockStage(firm: string): any?
	if stageCache[firm] then return stageCache[firm] end
	local S: any = nil
	if firm == "Premier Counsel" then
		local tower = Workspace:FindFirstChild("PremierCounsel")
		local sign = tower and tower:FindFirstChild("MockSign", true)
		local room = sign and sign.Parent
		local function part(n: string): BasePart?
			local x = room and room:FindFirstChild(n, true)
			return if x and x:IsA("BasePart") then x else nil
		end
		local lectern, bench, stand, riser = part("Lectern"), part("Bench"), part("WitnessStand"), part("JuryRiser")
		if room and lectern and bench and riser then
			local floorY = lectern.Position.Y - lectern.Size.Y / 2
			local toBench = flatUnit(bench.Position - lectern.Position, Vector3.new(0, 0, -1))
			local tables = {}
			for _, d in room:GetDescendants() do
				if d:IsA("BasePart") and d.Name == "CounselTable" then table.insert(tables, d) end
			end
			table.sort(tables, function(a, b) return a.Position.X < b.Position.X end)
			-- counsel stand in front of their tables (the chairs are behind them)
			local function behind(t: BasePart?, fallback: Vector3): Vector3
				if not t then return fallback end
				local v = t.Position + toBench * 3.5
				return Vector3.new(v.X, floorY, v.Z)
			end
			local ax, len = longAxis(riser)
			local jury = {}
			for k = 1, 6 do
				local v = riser.Position + ax * ((k - 3.5) / 6) * len * 0.85
				table.insert(jury, Vector3.new(v.X, riser.Position.Y + riser.Size.Y / 2, v.Z))
			end
			local benchBack = bench.Position + toBench * 2.6
			S = {
				label = "the mock courtroom (6th floor)",
				at = Vector3.new(lectern.Position.X, floorY, lectern.Position.Z),
				center = Vector3.new(lectern.Position.X, floorY, lectern.Position.Z),
				judge = Vector3.new(benchBack.X, bench.Position.Y, benchBack.Z),
				defence = behind(tables[1], lectern.Position - toBench * 4),
				state = behind(tables[2], lectern.Position - toBench * 4),
				witness = if stand then Vector3.new(stand.Position.X, floorY, stand.Position.Z) - toBench * 1.5 else lectern.Position,
				jury = jury,
			}
		end
	elseif firm == "National Trial Firm" then
		local b = Workspace:FindFirstChild("NationalTrialFirm")
		local best: BasePart? = nil
		for _, d in (if b then b:GetDescendants() else {}) do
			if d:IsA("BasePart") and d.Name == "ConferenceTable" and (not best or d.Position.Y < best.Position.Y) then best = d end
		end
		if best then
			local ax, len, side, wid = longAxis(best)
			local c = best.Position
			local function at(v: Vector3): Vector3 return ground(Vector3.new(v.X, c.Y, v.Z), { best :: Instance }) end
			local jury = {}
			for k = 1, 3 do
				local along = ax * ((k - 2) * len * 0.3)
				table.insert(jury, at(c + along + side * (wid / 2 + 2.2)))
				table.insert(jury, at(c + along - side * (wid / 2 + 2.2)))
			end
			S = {
				label = "the big conference room (ground floor)",
				at = at(c - ax * (len / 2 + 4)), center = at(c),
				judge = at(c + ax * (len / 2 + 3)),
				witness = at(c + ax * (len / 2 + 3) + side * 4),
				state = at(c - ax * (len / 2 + 3) + side * 3),
				defence = at(c - ax * (len / 2 + 3) - side * 3),
				jury = jury,
			}
		end
	end
	stageCache[firm] = S
	return S
end

local function face(m: Model?, toward: Vector3)
	local r = m and m:FindFirstChild("HumanoidRootPart") :: BasePart?
	if r then r.CFrame = CFrame.lookAt(r.Position, Vector3.new(toward.X, r.Position.Y, toward.Z)) end
end
local function npcAt(name: string, role: string, pos: Vector3, look: Vector3?, list: { Model }): Model?
	local C = court()
	local m = C and C.npc(name, role, pos)
	if m then
		table.insert(list, m)
		if look then task.delay(0.6, face, m, look) end
	end
	return m
end
local function say(m: Model?, text: string, secs: number?)
	local C = court()
	if C and C.say and m then C.say(m, text, secs) end
end
local function cleanup(list: { Model })
	for _, m in list do if m.Parent then m:Destroy() end end
	table.clear(list)
end
local function partnerName(f: any): string
	return if f.tier >= 5 then f.name .. " - senior partner" else f.name
end
local function prepared(p: Player)
	p:SetAttribute("CasePrepared", true)
end

-- practising the stand: an associate plays the DA. -> how it went (negative = good for you)
local function rehearse(p: Player, f: any, F: any, file: any, cat: number?, ada: Model?): number
	local C = court()
	local said = if C then C.choices("testimony", F) else {}
	if #said < 4 then return 0 end
	local q1 = ("Q: Where were you at %s?"):format(F.at)
	say(ada, q1)
	local i = ask(p, "Associate (playing the DA)", { "\"I'm going to be them now. I won't be nice.\"", q1 },
		{ said[1].text, said[2].text, said[3].text, said[4].text }, 4) or 4
	local story = said[i].story
	local eff = 0
	local note
	if story == "away" then
		eff = if F.caught or F.identified then 0.1 else -0.05
		if cat and cat ~= 2 then eff += 0.05 end
		note = if F.caught then "\"They arrested you THERE. That answer gets you destroyed on cross.\""
			elseif F.identified then "\"A witness puts you there. If you say 'nowhere near', you'd better have someone who'll back it up.\""
			else "\"Good. Nobody can put a face there. Say it exactly like that.\""
	elseif story == "there" then
		eff = if cat == 3 then -0.06 else 0.02
		note = if cat == 3 then "\"That fits our story. Calm, simple - you were there, it wasn't what they say.\""
			else "\"You just admitted you were there. That kills 'it wasn't me' - pick one story and stick to it.\""
	elseif story == "sorry" then
		eff = if cat == 2 then 0.06 else -0.02
		note = if cat == 2 then "\"Sorry for WHAT? You're saying you weren't there.\"" else "\"Remorse plays. Don't overdo it - one sentence.\""
	else
		eff = 0.04
		note = "\"Silence on the stand looks like guilt. If you take the stand, you answer.\""
	end
	-- the follow-up on the strongest thing they have
	local b = file and file.brief
	local ev = if b and b.evidence and #b.evidence > 0 then b.evidence[1].text else "the evidence"
	local q2 = ("Q: Then explain %s."):format(ev)
	say(ada, q2)
	local j = ask(p, "Associate (playing the DA)", { q2 }, {
		"\"I can't explain it. But I didn't do what you're saying.\"",
		"\"Your cops planted that.\"",
		"\"I don't remember.\"",
		"[Look at your lawyer]",
	}, 4) or 4
	local e2 = ({ -0.03, 0.06, 0.04, 0.06 })[j] or 0
	eff += e2
	ask(p, partnerName(f), {
		note,
		if j == 1 then "\"And that second answer was right. Short, steady, no fight.\"" elseif j == 2 then "\"Never attack the police on the stand unless we can prove it.\""
			elseif j == 3 then "\"'I don't remember' on the thing that matters most sounds like a lie.\"" else "\"Don't look at me on the stand. The jury sees that.\"",
	}, { "OK" })
	p:SetAttribute("Rehearsed", true)
	prepared(p)
	print(("[Law] REHEARSAL %s: story=%s follow-up=%d -> %.2f"):format(p.Name, story, j, eff))
	return eff
end

-- the mock trial itself (they're at the stage)
local function mockTrial(p: Player, f: any, S: any)
	local C = court()
	local file = caseFile(p)
	if not (C and file and file.brief) then
		ask(p, partnerName(f), { "\"There's nothing on file to try yet. Come back when the State has charged you.\"" }, { "OK" })
		return
	end
	local F = C.facts(file)
	local cast: { Model } = {}
	local ok, err = pcall(function()
		print(("[Law] MOCK TRIAL %s with %s"):format(p.Name, f.name))
		local judge = npcAt("Associate (as the judge)", "judge", S.judge, S.center, cast)
		local ada = npcAt("Associate (as the DA)", "prosecutor", S.state, S.center, cast)
		local partner = npcAt(partnerName(f), "lawyer", S.defence, S.center, cast)
		local jurors: { Model } = {}
		for k, pos in S.jury do
			local m = npcAt("Mock juror #" .. k, "public", pos, S.center, cast)
			if m then table.insert(jurors, m) end
		end
		say(judge, "Mock court is in session.")
		say(partner, "Sit in. Let's see how your story holds up.")
		ask(p, partnerName(f), {
			"\"Our associates play the judge and the DA - and they play them hard.\"",
			"\"These six are a focus group: ordinary people off the street, paid for the afternoon. They know nothing about you.\"",
			"\"Whatever they decide, we learn something before a real jury decides it for us.\"",
		}, { "Let's do it" })
		local best = { acquit = tonumber(p:GetAttribute("MockAcquit")) or -1 }
		for run = 1, 3 do
			if not p.Parent then return end
			-- which story do we test?
			local opts = {}
			for _, o in C.choices("theory", F) do if o.cat ~= 4 then table.insert(opts, o) end end
			local labels = {}
			for _, o in opts do table.insert(labels, o.text) end
			local i = ask(p, partnerName(f), { if run == 1 then "\"Which story do we put in front of them?\"" else "\"Another one. Which?\"" }, labels, 1) or 1
			local th = opts[i]
			F.poor = th.poor == true
			-- the State's opening, from the case file
			local b = file.brief
			say(ada, "This is a simple case.")
			ask(p, "Associate (as the DA) - opening", { b.happened,
				if #b.have > 0 then "You will see and hear: " .. table.concat(b.have, "; ") .. "." else "You'll hear from the arresting officer.",
				"Find the defendant guilty." }, { "..." })
			say(partner, th.text)
			ask(p, partnerName(f) .. " - opening", { ("\"Ladies and gentlemen: %s.\""):format(th.text) }, { "..." })
			-- the strongest piece of evidence, on the stand
			local ev = b.evidence and b.evidence[1]
			if ev then
				local wit = npcAt("Associate (as the witness)", "public", S.witness, S.center, cast)
				say(wit, if ev.kind == "dashcam" or ev.kind == "cctv" or ev.kind == "news" or ev.kind == "bodycam" then "(plays the video)" else "I saw it. It was them.")
				ask(p, "Associate (as the DA) - the evidence", { ("The State presents %s."):format(ev.text) }, { "..." })
				if wit then task.delay(2, function() if wit.Parent then wit:Destroy() end end) end
			end
			-- you on the stand
			local eff = rehearse(p, f, F, file, th.cat, ada)
			if not p.Parent then return end
			-- the focus group deliberates
			for _, m in jurors do say(m, "(talking it over)", 4) end
			task.wait(5)
			local acquit, why = C.mockJury(F, th.cat, eff, #jurors > 0 and #jurors or 6)
			local n = if #jurors > 0 then #jurors else 6
			for k, m in jurors do
				task.delay(k * 0.5, function() say(m, if k <= acquit then "Not guilty." else "Guilty.", 4) end)
			end
			task.wait(0.5 * n + 1)
			local lines = { ("The focus group votes: %d not guilty, %d guilty."):format(acquit, n - acquit) }
			for k = 1, math.min(2, #why) do table.insert(lines, ("Mock juror #%d: \"%s\""):format(math.random(1, n), why[k])) end
			table.insert(lines, if acquit * 2 > n then "\"That's our story. We take it to trial like that.\""
				elseif acquit * 2 == n then "\"A coin flip. In a real jury room, that's a hung jury - or worse.\""
				else "\"That doesn't fly. We need a different story - or we take the DA's deal.\"")
			if jurors[1] then say(jurors[1], why[1] or "", 6) end
			bill(p, "motions", 0.6)
			-- v291: the associates pull apart the State's strongest exhibit while the focus group is out
			for _, l in digInto(p, file, 2) do table.insert(lines, "Associates: " .. l) end
			if acquit > best.acquit then
				best.acquit = acquit
				p:SetAttribute("MockTheory", th.text)
				p:SetAttribute("MockCat", th.cat)
				p:SetAttribute("MockAcquit", acquit)
				p:SetAttribute("MockOf", n)
			end
			prepared(p)
			print(("[Law] MOCK VERDICT %s: '%s' (cat %d) -> %d/%d acquit, testimony %.2f"):format(p.Name, th.text, th.cat, acquit, n, eff))
			local again = ask(p, partnerName(f), lines, if run < 3 then { "Test another story", "That's enough" } else { "OK" }, if run < 3 then 2 else 1)
			if again ~= 1 or run >= 3 then break end
		end
		say(partner, "Go home. Sleep. Wear a suit.")
		ask(p, partnerName(f), { ("\"In court, the story that did best here will be on the table: '%s'.\""):format(tostring(p:GetAttribute("MockTheory") or "-")),
			"\"Go home. Sleep. Wear a suit. And don't talk to anyone about this case.\"" }, { "OK" })
	end)
	if not ok then warn("[Law] mock trial failed: " .. tostring(err)) end
	cleanup(cast)
end

-- book the mock trial: come to the stage (the meeting marker shows the way), then it runs
local mockBooked: { [Player]: boolean } = {}
local function bookMock(p: Player, f: any, S: any)
	if mockBooked[p] then return end
	mockBooked[p] = true
	local due = os.time() + 150
	p:SetAttribute("MeetingAt", due)
	p:SetAttribute("MeetingPlace", S.at)
	p:SetAttribute("MeetingWith", f.name .. " mock trial")
	notice(p, ("%s: the associates are setting up the mock trial in %s. Come up when you're ready."):format(f.name, S.label))
	task.spawn(function()
		local arrived = false
		while p.Parent and os.time() < due + 150 do
			local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and (root.Position - S.at).Magnitude <= 22 and p:GetAttribute("CustodyStage") == nil then
				arrived = true
				break
			end
			task.wait(1)
		end
		if p:GetAttribute("MeetingWith") == f.name .. " mock trial" then
			p:SetAttribute("MeetingAt", nil)
			p:SetAttribute("MeetingPlace", nil)
			p:SetAttribute("MeetingWith", nil)
		end
		if arrived then mockTrial(p, f, S) else notice(p, f.name .. ": the associates waited, then packed up the mock trial.") end
		mockBooked[p] = nil
	end)
end

-- the meeting: what they have, the options, practice on the stand, the mock trial
local meeting: { [Player]: boolean } = {}
local function caseMeeting(p: Player, f: any, late: boolean?)
	if meeting[p] then return end
	meeting[p] = true
	local C = court()
	local file = caseFile(p)
	local cast: { Model } = {}
	local ok, err = pcall(function()
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local lawyerM = if root then npcAt(partnerName(f), "lawyer", root.Position + root.CFrame.LookVector * 5, root.Position, cast) else nil
		if not (C and file and file.brief) then
			say(lawyerM, "You don't have a case open.")
			ask(p, partnerName(f), { if late then "\"You're late. We bill for waiting.\"" else "\"Sit down.\"",
				"\"There's nothing on file against you right now. If that changes, call us before you say a word to anyone.\"" }, { "OK" })
			return
		end
		local F = C.facts(file)
		local b = file.brief
		local S = if f.tier >= 6 then mockStage(f.name) else nil
		local intro = { if late then "\"You're late. We bill for waiting. Sit down.\"" else "\"Right on time. Sit down - let's talk about your case.\"",
			("\"%s\""):format(b.happened) }
		if S and bigCase(p, F) then
			table.insert(intro, ("\"In a case this size we don't guess. The associates can run a mock trial for you in %s.\""):format(S.label))
		end
		say(lawyerM, "Let's talk about your case.")
		for _ = 1, 8 do
			local opts, acts = {}, {}
			local function add(t: string, fn: () -> boolean?) table.insert(opts, t); table.insert(acts, fn) end
			add("What do they actually have?", function()
				local lines = {
					if #b.have > 0 then "They have: " .. table.concat(b.have, "; ") .. "." else "They have an officer's report and not much else.",
				}
				if #b.haveNot > 0 then table.insert(lines, "They DON'T have: " .. table.concat(b.haveNot, " ")) end
				table.insert(lines, ("\"%s\""):format(b.read))
				-- v291: what the firm's investigator found about their evidence
				for _, l in digInto(p, file, 2) do table.insert(lines, "Our investigator: " .. l) end
				ask(p, partnerName(f), lines, { "OK" })
				bill(p, "meeting", 0.5)
				prepared(p)
				return false
			end)
			add("What are our options for a defence?", function()
				local lines = { "\"Here's how each story plays with what they've got:\"" }
				for _, o in C.choices("theory", F) do
					if o.cat ~= 4 then
						local read = if o.cat == 2 then (if F.caught then "they arrested you at the scene - a jury won't buy it"
								elseif F.identified then "a witness puts you there; we'd have to break them" else "nobody saw a face - this could work")
							elseif o.cat == 1 then (if F.strength < 0.5 then "their case is thin - this is our strongest play" else "they have a lot; doubt alone may not do it")
							elseif o.poor then "with that many dead, nobody believes it"
							else "it admits you were there, but it can bring the charge down"
						table.insert(lines, ("- %s: %s."):format(o.text, read))
					end
				end
				if f.tier >= 6 and S then table.insert(lines, ("\"If you want to know for sure, we test it - a mock trial in %s.\""):format(S.label)) end
				ask(p, partnerName(f), lines, { "OK" })
				bill(p, "meeting", 0.7)
				prepared(p)
				return false
			end)
			add("Prepare me to testify", function()
				local ada = if root then npcAt("Associate (playing the DA)", "prosecutor", root.Position - root.CFrame.RightVector * 5, root.Position, cast) else nil
				rehearse(p, f, F, file, nil, ada)
				if ada and ada.Parent then ada:Destroy() end
				bill(p, "meeting", 1.2)
				return false
			end)
			if S then
				add("Run a mock trial with the associates", function()
					local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if r and (r.Position - S.at).Magnitude <= 30 then
						task.spawn(mockTrial, p, f, S)
					else
						ask(p, partnerName(f), { ("\"Go up to %s. The associates will be ready for you.\""):format(S.label) }, { "OK" })
						bookMock(p, f, S)
					end
					return true
				end)
			end
			add("What will the DA offer?", function()
				ask(p, partnerName(f), {
					if b.strength >= 0.7 then "\"With what they have, the DA won't move much. Expect an offer around two-thirds of the maximum.\""
						elseif b.strength >= 0.45 then "\"Something around half the maximum. Push back once - they usually come down.\""
						else "\"They know it's thin. A lowball offer - and if we refuse, they might not want a trial at all.\"",
					if F.big then "\"In a case like yours, the cameras will be on the courthouse steps. Say nothing to them.\"" else "\"Don't discuss the case with anyone. Not on the phone, not with friends.\"",
				}, { "OK" })
				bill(p, "meeting", 0.4)
				return false
			end)
			add("That's all", function() return true end)
			local idx = ask(p, partnerName(f), intro, opts, #opts)
			intro = { "\"Anything else?\"" }
			if not idx or not acts[idx] or acts[idx]() then break end
		end
		say(lawyerM, "Stay out of trouble.")
		print(("[Law] CASE MEETING %s with %s (big=%s)"):format(p.Name, f.name, tostring(bigCase(p, F))))
	end)
	if not ok then warn("[Law] case meeting failed: " .. tostring(err)) end
	cleanup(cast)
	meeting[p] = nil
end

---------------------------------------------------------------------------
-- v257b IN-PERSON MEETINGS (spec 9.5): the lawyer books a time at the office.
-- On time = a prepared case (CasePrepared - plea and court read it); late = billed
-- waiting; no-show = billed anyway and the lawyer gets annoyed (twice = they drop you).
-- MeetingAt / MeetingPlace / MeetingWith attributes drive the client's marker.
---------------------------------------------------------------------------
local offices: { [string]: Vector3 } = {}
local MEETING = { Lead = 150, Window = 150, Reach = 14 }

local function scheduleMeeting(p: Player, reason: string)
	local a = acct(p)
	local f = BY_NAME[a.firm or ""]
	if not f or f.rate <= 0 or p:GetAttribute("MeetingAt") then return end
	local place = offices[f.name]
	if not place then
		-- no office mapped for this firm: they do it over the phone
		local how = call(p, { from = f.name, kind = "lawyer", legal = true, expires = 300,
			lines = { ("We need to go over your case (%s). Let's do it now, on the phone."):format(reason) }, options = { "OK" } })
		if how == "answered" then
			bill(p, "meeting")
			p:SetAttribute("CasePrepared", true)
		end
		return
	end
	local due = os.time() + MEETING.Lead
	p:SetAttribute("MeetingAt", due)
	p:SetAttribute("MeetingPlace", place)
	p:SetAttribute("MeetingWith", f.name)
	print(("[Law] MEETING booked %s with %s (%s) in %d s"):format(p.Name, f.name, reason, MEETING.Lead))
	call(p, { from = f.name, kind = "lawyer", legal = true, expires = 120,
		lines = { ("Come to the office in %d minutes - %s. It has to be in person."):format(math.ceil(MEETING.Lead / 60), reason),
			"Watch for patrols on the way." }, options = { "I'll be there" } })
	-- wait for them at the office
	task.spawn(function()
		local arrived = nil
		while p.Parent and os.time() < due + MEETING.Window do
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and (root.Position - place).Magnitude <= MEETING.Reach and p:GetAttribute("CustodyStage") == nil then
				arrived = os.time()
				break
			end
			task.wait(1)
		end
		p:SetAttribute("MeetingAt", nil)
		p:SetAttribute("MeetingPlace", nil)
		p:SetAttribute("MeetingWith", nil)
		if not p.Parent then return end
		if arrived then
			local late = arrived > due
			if late then bill(p, "call") end -- the waiting time
			bill(p, "meeting")
			p:SetAttribute("CasePrepared", true)
			a.annoyed = 0
			save(p)
			print(("[Law] MEETING %s attended%s"):format(p.Name, if late then " (late)" else ""))
			-- v290h: a real sit-down about the case (and in a big case with a top firm, they've
			-- set up a mock trial upstairs)
			caseMeeting(p, f, late)
		else
			bill(p, "meeting")
			a.annoyed = (a.annoyed or 0) + 1
			save(p)
			print(("[Law] MEETING %s no-show (%d)"):format(p.Name, a.annoyed))
			if a.annoyed >= 2 then
				withdraw(p, "missed meetings")
			else
				call(p, { from = f.name, kind = "lawyer", legal = true, expires = 300,
					lines = { "You didn't show. We billed you for the hour anyway. Do it again and find another lawyer." }, options = { "Sorry" } })
			end
		end
	end)
end

---------------------------------------------------------------------------
-- v291: hiring a PLAYER attorney (Attorneys: licensed players on duty as defence counsel). A firm
-- associate comes with their firm (the firm's retainer and rate - they get half of every hour);
-- an independent sets their own rate (ten hours up front into trust - they keep 85%).
---------------------------------------------------------------------------
local function hirePlayerAttorney(p: Player)
	local at = ServerStorage:FindFirstChild("Attorneys")
	if not (at and at:IsA("BindableFunction")) then return end
	local okL, list = pcall(at.Invoke, at, "list", p)
	if not okL or type(list) ~= "table" or #list == 0 then
		dialog(p, "Player attorneys", { "No player attorneys are on duty right now." }, { "OK" })
		return
	end
	local opts = {}
	for _, l in list do
		local fee = if l.firm then (BY_NAME[l.firm] and BY_NAME[l.firm].retainer or 0) else (l.rate or 0) * 10
		table.insert(opts, ("%s - %s - %d-%d - retainer %s"):format(l.name, if l.firm then l.firm .. " associate" else ("independent, %s/h"):format(money(l.rate or 0)), l.wins, l.losses, money(fee)))
	end
	table.insert(opts, "Never mind")
	local i = dialog(p, "Player attorneys on duty", { "Real lawyers. They run your defence in court themselves." }, opts)
	local pick = i and list[i]
	if not pick then return end
	local lawyerP = Players:GetPlayerByUserId(pick.userId)
	if not lawyerP then return end
	local f = if pick.firm then BY_NAME[pick.firm] else nil
	local fee = if f then f.retainer else (pick.rate or 0) * 10
	if fee > 0 and available(p) < fee then
		dialog(p, pick.name, { ("You need %s for the retainer (frozen money doesn't count)."):format(money(fee)) }, { "OK" })
		return
	end
	notice(p, ("Calling %s..."):format(pick.name))
	local okO, yes = pcall(at.Invoke, at, "offer", lawyerP, p, { fee = fee })
	if not (okO and yes) then
		dialog(p, pick.name, { "They declined the case." }, { "OK" })
		return
	end
	local a = acct(p)
	if f then
		if f.rate > 0 and not signOn(p, f, false) then return end
		if f.rate <= 0 then a.firm, a.retained, a.trust = f.name, false, 0 end
	else
		if not charge(p, fee) then notice(p, "You can't cover the retainer."); return end
		a.firm, a.retained = "Independent Counsel", false
		a.hours, a.billed, a.log, a.trust = 0, 0, {}, fee
		a.playerRate = pick.rate
	end
	a.playerAttorney = pick.userId
	a.unpaid = 0
	save(p)
	p:SetAttribute("PlayerAttorney", pick.name)
	-- the retainer for an independent goes to them now (their share); a firm's is billed by the hour
	if not f and fee > 0 then pcall(at.Invoke, at, "earn", pick.userId, fee * 0.85, p:GetAttribute("CharacterName") or p.DisplayName); a.trust = 0; save(p) end
	notice(p, ("%s is now your attorney."):format(pick.name))
	print(("[Law] PLAYER ATTORNEY %s hired %s (%s)"):format(p.Name, lawyerP.Name, pick.firm or "independent"))
end

---------------------------------------------------------------------------
-- the menu (office reception, or the phone's Lawyer button)
---------------------------------------------------------------------------
local busy: { [Player]: boolean } = {}
local function menu(p: Player, office: any?)
	if busy[p] then return end
	busy[p] = true
	local a = acct(p)
	local inCustody = p:GetAttribute("CustodyStage") ~= nil
	local firm = if office then BY_NAME[office.firm or ""] else BY_NAME[a.firm or ""]
	if firm and firm.rate <= 0 and not office then firm = nil end
	local from = if office and not office.phone then office.firm .. " - Reception" elseif firm then firm.name else "Lawyer"
	if not firm then
		-- phone with no lawyer: pick a firm to call
		local names = {}
		for i = 2, #FIRMS do names[i - 1] = FIRMS[i].name end
		-- v291: a player attorney; your own practice
		local extra = {}
		table.insert(names, "A player attorney (a real person)")
		extra[#names] = function() task.spawn(hirePlayerAttorney, p) end
		if p:GetAttribute("AttorneyLicensed") then
			table.insert(names, "My law practice")
			extra[#names] = function()
				local at = ServerStorage:FindFirstChild("Attorneys")
				if at and at:IsA("BindableFunction") then pcall(at.Invoke, at, "practice", p) end
			end
		end
		table.insert(names, "Hang up")
		local idx = dialog(p, "Call a lawyer", { "Who do you call?" }, names)
		busy[p] = nil
		if idx and extra[idx] then extra[idx]() return end
		if idx and idx < #names then
			local f = FIRMS[idx + 1]
			-- 3 AM: cheap firms don't pick up
			if isNight() and math.random() > f.night then
				notice(p, f.name .. ": voicemail. \"Leave a message after the tone...\"")
				return
			end
			menu(p, { firm = f.name, phone = true })
		end
		return
	end
	local byPhone = office == nil or office.phone == true
	local opts, acts = {}, {}
	local function add(t: string, fn: () -> ()) table.insert(opts, t); table.insert(acts, fn) end
	add("Get a quote", function()
		dialog(p, firm.name, quoteLines(p, firm), { "OK" })
	end)
	if not (a.firm == firm.name and a.retained) and firm.rate > 0 and not inCustody then
		add(("Put %s on retainer (%s per cycle)"):format(firm.name, money(firm.retainer * CFG.CycleShare)), function()
			if byPhone and firm.inPerson then
				dialog(p, firm.name, { "We only sign new clients in person. Come by the office." }, { "OK" })
				return
			end
			if signOn(p, firm, true) then
				dialog(p, firm.name, { "Welcome aboard. Keep this number - day or night." }, { "OK" })
			end
		end)
	end
	if firm.rate > 0 and (inCustody or p:GetAttribute("CourtDateAt")) then
		add(("Hire for your open case (retainer %s)"):format(money(firm.retainer)), function()
			if byPhone and firm.inPerson and not inCustody then
				dialog(p, firm.name, { "Come to the office to sign. Bring the retainer." }, { "OK" })
				return
			end
			if signOn(p, firm, false) then
				dialog(p, firm.name, { ("Retained. %s in trust. We bill %s an hour against it."):format(money(acct(p).trust or 0), money(rateFor(acct(p)))) }, { "OK" })
				bill(p, "call")
			end
		end)
	end
	-- v291: a real person as your lawyer; and if you ARE a lawyer, your practice
	if inCustody or p:GetAttribute("CourtDateAt") or p:GetAttribute("CaseCharges") then
		add("Hire a player attorney", function() task.spawn(hirePlayerAttorney, p) end)
	end
	if p:GetAttribute("AttorneyLicensed") then
		add("My law practice (you're a licensed attorney)", function()
			local at = ServerStorage:FindFirstChild("Attorneys")
			if at and at:IsA("BindableFunction") then pcall(at.Invoke, at, "practice", p) end
		end)
	end
	-- v290h: out on bail with a case pending: sit down with your own lawyer about it
	if not byPhone and not inCustody and a.firm == firm.name and firm.rate > 0 and p:GetAttribute("CourtDateAt") then
		add("Meet with my lawyer about my case", function() task.spawn(caseMeeting, p, firm, false) end)
		local S = if firm.tier >= 6 then mockStage(firm.name) else nil
		if S then
			add("Book a mock trial with the associates", function() bookMock(p, firm, S) end)
		end
	end
	-- v257b: serving time - your lawyer comes to the prison
	if serving(p) and a.firm == firm.name and not visiting[p] then
		add("Request a legal visit (glass)", function() task.spawn(requestVisit, p, false) end)
		if firm.rate > 0 then
			add("Request a legal visit (contact)", function() task.spawn(requestVisit, p, true) end)
		end
	end
	if a.firm == firm.name and firm.rate > 0 then
		add("See my legal bill", function() dialog(p, firm.name .. " - Legal bill", billLines(p), { "OK" }) end)
		local amt = math.max(firm.rate * 10, 1000)
		add(("Top up trust (%s)"):format(money(amt)), function()
			if charge(p, amt) then
				local pay = amt
				if (a.debt or 0) > 0 then local d = math.min(a.debt, pay); a.debt -= d; pay -= d end
				a.trust = (a.trust or 0) + pay
				save(p)
				notice(p, ("Trust balance: %s"):format(money(a.trust)))
			else
				notice(p, "You can't cover that.")
			end
		end)
		if a.retained then
			add("End the retainer", function()
				a.retained = false
				save(p)
				notice(p, firm.name .. " is no longer on retainer.")
			end)
		end
	end
	if office == nil then
		-- the phone: you're not stuck with the firm you have
		add("Call a different firm", function() task.spawn(menu, p, { phone = true, pick = true }) end)
	end
	add("Leave", function() end)
	local body = { if not byPhone then "\"Good day. How can the firm help you?\"" else "\"Law office, how can I help?\"" }
	local idx = dialog(p, from, body, opts)
	busy[p] = nil
	if idx and acts[idx] then acts[idx]() end
end

---------------------------------------------------------------------------
-- offices
---------------------------------------------------------------------------
local function setupOffices()
	if not F then warn("[Law] Facilities not available - no offices"); return end
	local used = {}
	for _, b in F.ofType("LawOffice") do
		local model = b.model
		local mapRoot = b.root
		local firm = (model and model:GetAttribute("Firm")) or (mapRoot and mapRoot:GetAttribute("Firm")) or b.firm
		local how = "Firm attribute"
		if not (type(firm) == "string" and BY_NAME[firm]) then
			firm = if not used["Local Attorney"] then "Local Attorney" else nil
			how = "no Firm attribute - used as the Local Attorney"
		end
		if not firm then
			print(("[Law] office %s has no Firm attribute - skipped (set Firm on the building)"):format(tostring(model and model.Name)))
		else
			used[firm] = true
			local pos, where = nil, "stand-in: first room"
			for _, pt in b.points or {} do if pt.pointType == "Reception" then pos, where = pt.position, "Reception point" end end
			if not pos then for _, s in b.seats or {} do if s.role == "LawyerSeat" then pos, where = s.position, "LawyerSeat" end end end
			if not pos then
				local z = (b.zones or {})[1]
				pos = z and z.center + Vector3.new(0, 3, 0)
			end
			if pos then
				local part = Instance.new("Part")
				part.Name = "LawReception_" .. firm
				part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
				part.Transparency = 1
				part.Size = Vector3.one
				part.Position = pos
				part.Parent = Workspace
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Talk to reception"
				prompt.ObjectText = firm
				prompt.HoldDuration = 0.3
				prompt.MaxActivationDistance = 10
				prompt.RequiresLineOfSight = false
				prompt.Parent = part
				local office = { firm = firm, pos = pos }
				offices[firm] = pos
				prompt.Triggered:Connect(function(p) task.spawn(menu, p, office) end)
				print(("[Law] office: %s in %s (%s, %s)"):format(firm, tostring(model and model.Name), how, where))
			end
		end
	end
	for _, f in FIRMS do
		if f.rate > 0 and not used[f.name] then print("[Law] no office mapped for " .. f.name .. " (LawOffice building with Firm = \"" .. f.name .. "\")") end
	end
end

---------------------------------------------------------------------------
-- hooks: arrest call (3 AM rule), interrogation, bail hearing, booking, cycles
---------------------------------------------------------------------------
local function onArrest(p: Player)
	local a = acct(p)
	local f = BY_NAME[a.firm or ""]
	if not (f and a.retained and f.rate > 0) then return end
	local night = isNight()
	local answers = (not night) or math.random() < f.night
	if answers then
		p:SetAttribute("LawyerPresent", true)
		local junior = night and f.junior and math.random() < 0.5
		notice(p, ("%s picked up. %s"):format(f.name, if junior then "A junior associate is on the way." else "Your lawyer is on the way - say nothing."))
		bill(p, "call")
		print(("[Law] ARREST CALL %s -> %s answered (%s)"):format(p.Name, f.name, if night then "night" else "day"))
	else
		notice(p, ("%s: voicemail. Nobody picks up at this hour."):format(f.name))
		print(("[Law] ARREST CALL %s -> %s slept through it"):format(p.Name, f.name))
		task.delay(240, function()
			if p.Parent then
				call(p, { from = f.name, kind = "lawyer", legal = true, expires = 300,
					lines = { "Sorry, I was asleep... What did you tell them?" }, options = { "Nothing", "...Some things" } })
			end
		end)
	end
end

local function watch(p: Player)
	p:GetAttributeChangedSignal("CustodyStage"):Connect(function()
		local s = p:GetAttribute("CustodyStage")
		if s == "Arrest" and not p:GetAttribute("LawyerCalledThisCase") then
			p:SetAttribute("LawyerCalledThisCase", true)
			task.spawn(onArrest, p)
		elseif s == nil then
			p:SetAttribute("LawyerCalledThisCase", nil)
			p:SetAttribute("LawyerPresent", nil)
			-- v257b: out on bond with a court date - paid counsel books a case review
			task.delay(20, function()
				if p.Parent and p:GetAttribute("CourtDateAt") and p:GetAttribute("CustodyStage") == nil then
					scheduleMeeting(p, "case review before your court date")
				end
			end)
		end
	end)
	-- a new case starts unprepared
	p:GetAttributeChangedSignal("LastArrestAt"):Connect(function()
		p:SetAttribute("CasePrepared", nil)
		for _, k in { "MockTheory", "MockCat", "MockAcquit", "MockOf", "Rehearsed" } do p:SetAttribute(k, nil) end -- v290h
	end)
	p:GetAttributeChangedSignal("BookingState"):Connect(function()
		if p:GetAttribute("BookingState") == "Interrogation" and p:GetAttribute("LawyerPresent") then
			bill(p, "interrogation")
		end
	end)
	p:GetAttributeChangedSignal("BailOffered"):Connect(function()
		if p:GetAttribute("BailOffered") then
			local a = acct(p)
			if a.firm and a.firm ~= "Public Defender" then bill(p, "bail") end
		end
	end)
	p:GetAttributeChangedSignal("CounselName"):Connect(function()
		local n = p:GetAttribute("CounselName")
		if n and n ~= "Public Defender" and acct(p).firm == n then
			local _, trial, cx = caseKind(p)
			bill(p, trial, cx)
		end
	end)
	task.delay(8, function() if p.Parent and Records then save(p) end end)
end
Players.PlayerAdded:Connect(watch)
for _, p in Players:GetPlayers() do task.spawn(watch, p) end
Players.PlayerRemoving:Connect(function(p) busy[p] = nil; meeting[p] = nil; mockBooked[p] = nil end)

-- billing cycles for retained clients
task.spawn(function()
	while true do
		task.wait(20)
		if Records then
			for _, p in Players:GetPlayers() do
				local a = acct(p)
				if a.retained and (a.nextCycle or 0) > 0 and os.time() >= a.nextCycle then
					local f = BY_NAME[a.firm or ""]
					if f then
						local fee = math.floor(f.retainer * CFG.CycleShare)
						a.nextCycle = os.time() + CFG.CycleSeconds
						if charge(p, fee) then
							notice(p, ("%s retainer: %s billed for this cycle."):format(f.name, money(fee)))
						else
							a.retained = false
							notice(p, ("%s retainer lapsed - you couldn't pay %s."):format(f.name, money(fee)))
						end
						save(p)
					end
				end
			end
		end
	end
end)

---------------------------------------------------------------------------
-- API: ServerStorage.LawFirms
--   ("hireAtBooking", player, firmName) -> true | reason   (PoliceSystem SelectCounsel)
--   ("menu", player)                                        (phone Lawyer button)
--   ("bill", player, activity, complexity) -> hours
--   ("retained", player) -> firm name or nil
---------------------------------------------------------------------------
do
	local fn = ServerStorage:FindFirstChild("LawFirms") or Instance.new("BindableFunction")
	fn.Name = "LawFirms"
	fn.OnInvoke = function(action, p, x, y)
		if typeof(p) ~= "Instance" or not p:IsA("Player") then return nil end
		if action == "hireAtBooking" then
			local f = BY_NAME[tostring(x)]
			if not f then return "Unknown counsel" end
			local a = acct(p)
			if f.rate <= 0 or (a.firm == f.name and (a.retained or (a.trust or 0) > 0)) then
				print(("[Law] BOOKING %s uses %s"):format(p.Name, f.name))
				if f.rate <= 0 then a.firm = f.name; save(p) end
				return true
			end
			if signOn(p, f, false) then return true end
			return ("You need %s for the %s retainer"):format(money(f.retainer), f.name)
		elseif action == "menu" then
			task.spawn(menu, p, nil)
			return true
		elseif action == "bill" then
			return bill(p, tostring(x), tonumber(y))
		elseif action == "retained" then
			local a = acct(p)
			return if a.retained then a.firm else nil
		elseif action == "meeting" then
			-- v257b: other scripts (plea offers, trial prep) book an in-person meeting
			task.spawn(scheduleMeeting, p, tostring(x or "your case"))
			return true
		elseif action == "legalVisit" then
			task.spawn(requestVisit, p, x == true)
			return true
		end
		return nil
	end
	fn.Parent = ServerStorage
end

task.delay(10, function()
	local ok, err = pcall(setupOffices)
	if not ok then warn("[Law] office setup failed: " .. tostring(err)) end
	print("[Law] v257 ready")
end)
