--[[
	PhoneCalls (v256) - incoming calls on the cell phone, and the jail / prison phones.

	Other server scripts place a call with ServerStorage.Phone (BindableFunction):
	  Phone:Invoke("call", player, {
	      from = "Clark County Court", kind = "court" | "lawyer" | "offer" | "info",
	      lines = { "text", ... },          what the caller says
	      options = { "Accept", "Reject" }, answer buttons (default: { "OK" })
	      expires = 300,                     seconds a missed call can still be returned
	      legal = true,                      in custody: a legal call (privileged, not monitored)
	  })  -> "answered", optionIndex | "declined" | "missed" | "refused"
	It yields until the call is over (a callback later runs spec.onCallback(player, optionIndex)).

	FREE: the cell phone rings (answer / decline, ~25 s). Missed / declined calls go to
	the missed-call list (tap to call back until they expire).
	IN CUSTODY: no cell phone. A CO announces the call and you must physically walk
	to a phone - HoldingPhone (Police HQ), JailPhone (City Jail) or PrisonPhone
	(prison) - within PickupSeconds. The handset says "This call is from a correctional
	facility" and every non-legal call is MONITORED (logged, MonitoredCalls attribute).
	Refuse / don't go -> the lawyer comes for a legal visit instead (slower).
	At a custody phone you can also make calls: your lawyer (case status), family, crew.
	Logs: [Phone]
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local CFG = {
	RingSeconds = 25,
	PickupSeconds = 90, -- custody: time to walk to the phone
	TalkSeconds = 45, -- time to pick an answer once connected
	DefaultExpiry = 300,
	VisitDelay = 120, -- refused legal call -> lawyer visit after this long
	PhoneReach = 9,
}

local remote = ReplicatedStorage:FindFirstChild("PhoneCalls") :: RemoteEvent?
if not remote then
	local r = Instance.new("RemoteEvent")
	r.Name = "PhoneCalls"
	r.Parent = ReplicatedStorage
	remote = r
end
local R = remote :: RemoteEvent

---------------------------------------------------------------------------
-- facilities: where the phones are
---------------------------------------------------------------------------
local F: any = nil
task.spawn(function()
	local ps = ServerScriptService:WaitForChild("PoliceSystem", 30)
	local fm = ps and ps:WaitForChild("Facilities", 30)
	if fm then
		local ok, mod = pcall(require, fm)
		if ok then F = mod end
	end
end)

local PHONE_OF = { HQ = { "PoliceHQ", "HoldingPhone" }, CityJail = { "CityJail", "JailPhone" }, Prison = { "Prison", "PrisonPhone" } }

-- which phone bank a player in custody uses -> key or nil (free)
local function siteOf(p: Player): string?
	local stage = p:GetAttribute("CustodyStage")
	if p:GetAttribute("SentenceEnd") ~= nil or stage == "Serving" then return "Prison" end
	if stage == nil then return nil end
	local site = p:GetAttribute("CustodySite")
	if site == "CityJail" then return "CityJail" end
	if site == "HQ" then return "HQ" end
	return "Custody" -- arrest / transport / intake: no phone access yet
end

local phoneCache: { [string]: { Vector3 } } = {}
local function phonesAt(site: string): { Vector3 }
	if phoneCache[site] and #phoneCache[site] > 0 then return phoneCache[site] end
	local out = {}
	local def = PHONE_OF[site]
	if not def then return out end
	if F then
		for _, pt in F.points(def[1], def[2]) do table.insert(out, pt.position) end
	end
	if #out == 0 then
		-- not registered by Facilities: any point part named like it
		for _, d in Workspace:GetDescendants() do
			if d:IsA("BasePart") and string.find(d.Name, def[2], 1, true) == 1 then table.insert(out, d.Position) end
		end
	end
	phoneCache[site] = out
	return out
end

local function rootOf(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function nearestPhone(p: Player, site: string): Vector3?
	local r = rootOf(p)
	local best, bd = nil, math.huge
	for _, pos in phonesAt(site) do
		local d = if r then (pos - r.Position).Magnitude else 0
		if d < bd then best, bd = pos, d end
	end
	return best
end

---------------------------------------------------------------------------
-- calls
---------------------------------------------------------------------------
type Call = { id: number, player: Player, spec: any, state: string, answer: number?, expiresAt: number, site: string? }
local nextId = 0
local active: { [Player]: Call } = {} -- the call on screen / ringing
local missed: { [Player]: { Call } } = {}
local pickupWait: { [Player]: Call } = {} -- custody: walking to the phone

local function send(p: Player, ...)
	if p.Parent then R:FireClient(p, ...) end
end

local function publicSpec(c: Call): any
	local s = c.spec
	return {
		id = c.id, from = tostring(s.from or "Unknown"), kind = tostring(s.kind or "info"),
		lines = s.lines or {}, options = s.options or { "OK" },
		skin = if c.site then "prison" else "cell",
		monitored = c.site ~= nil and not s.legal,
		-- v286v: a timed choice (the trial): a bar runs down, silence when it ends. v290g: every
		-- conversation shows its clock (it always auto-answered after TalkSeconds - unseen)
		seconds = tonumber(s.seconds) or (if c.state == "talking" then CFG.TalkSeconds else nil),
		silent = tonumber(s.silent),
		legal = s.legal == true, facility = c.site,
	}
end

local function pushMissed(p: Player)
	local list = missed[p] or {}
	local out = {}
	local now = os.time()
	for i = #list, 1, -1 do
		if list[i].expiresAt <= now then table.remove(list, i) end
	end
	for _, c in list do
		table.insert(out, { id = c.id, from = tostring(c.spec.from or "Unknown"), left = c.expiresAt - now })
	end
	send(p, "missed", out)
end

local function logMonitored(c: Call, text: string)
	if c.site and not c.spec.legal then
		print(("[Phone] MONITORED %s @%s: %s"):format(c.player.Name, c.site, text))
		local p = c.player
		p:SetAttribute("MonitoredCalls", (tonumber(p:GetAttribute("MonitoredCalls")) or 0) + 1)
	end
end

-- connected: show the conversation, wait for an answer
local function talk(c: Call): (string, number?)
	c.state = "talking"
	active[c.player] = c
	send(c.player, "connected", publicSpec(c))
	local deadline = os.clock() + (tonumber(c.spec.seconds) or CFG.TalkSeconds)
	while c.state == "talking" and c.player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	if active[c.player] == c then active[c.player] = nil end
	send(c.player, "ended", c.id)
	local idx = c.answer or tonumber(c.spec.silent) or 1 -- v286v: ran out of time = the silent option
	logMonitored(c, ("%s / %s"):format(tostring(c.spec.from), tostring((c.spec.options or { "OK" })[idx])))
	print(("[Phone] ANSWERED %s from %s -> option %d"):format(c.player.Name, tostring(c.spec.from), idx))
	return "answered", idx
end

local function toMissed(c: Call, why: string)
	c.state = why
	missed[c.player] = missed[c.player] or {}
	table.insert(missed[c.player], c)
	pushMissed(c.player)
	print(("[Phone] %s call from %s to %s"):format(string.upper(why), tostring(c.spec.from), c.player.Name))
end

-- cell phone: ring -> answer / decline / missed
local function ringCell(c: Call): (string, number?)
	c.state = "ringing"
	active[c.player] = c
	send(c.player, "ring", publicSpec(c))
	local deadline = os.clock() + CFG.RingSeconds
	while c.state == "ringing" and c.player.Parent and os.clock() < deadline do
		if siteOf(c.player) then break end -- arrested mid-ring: the cell phone is gone
		task.wait(0.1)
	end
	if active[c.player] == c then active[c.player] = nil end
	send(c.player, "stopRing", c.id)
	if c.state == "answering" then return talk(c) end
	local why = if c.state == "declined" then "declined" else "missed"
	toMissed(c, why)
	return why, nil
end

-- custody: a CO sends you to the phone bank
local function custodyCall(c: Call, site: string): (string, number?)
	c.site = site
	if site == "Custody" or #phonesAt(site) == 0 then
		-- no phone here (in a car, at intake) or none mapped: it waits as a missed call
		toMissed(c, "missed")
		return "missed", nil
	end
	c.state = "pickup"
	pickupWait[c.player] = c
	send(c.player, "summon", publicSpec(c), nearestPhone(c.player, site), CFG.PickupSeconds)
	print(("[Phone] SUMMON %s to the %s phone (%s call from %s)"):format(c.player.Name, site, if c.spec.legal then "legal" else "monitored", tostring(c.spec.from)))
	local deadline = os.clock() + CFG.PickupSeconds
	while c.state == "pickup" and c.player.Parent and os.clock() < deadline do
		if siteOf(c.player) ~= site then break end -- moved / released
		task.wait(0.2)
	end
	if pickupWait[c.player] == c then pickupWait[c.player] = nil end
	send(c.player, "unsummon", c.id)
	if c.state == "answering" then return talk(c) end
	c.state = "refused"
	print(("[Phone] REFUSED %s didn't take the call from %s"):format(c.player.Name, tostring(c.spec.from)))
	if c.spec.legal then
		local p = c.player
		send(p, "notice", ("You didn't take the call. %s will come for a legal visit instead."):format(tostring(c.spec.from)))
		task.delay(CFG.VisitDelay, function()
			if not p.Parent then return end
			send(p, "notice", ("LEGAL VISIT - %s: %s"):format(tostring(c.spec.from), table.concat(c.spec.lines or {}, " ")))
			if c.spec.onVisit then pcall(c.spec.onVisit, p) end
		end)
	end
	return "refused", nil
end

local function place(p: Player, spec: any): (string, number?)
	if typeof(p) ~= "Instance" or not p:IsA("Player") or not p.Parent then return "missed", nil end
	nextId += 1
	local c: Call = {
		id = nextId, player = p, spec = spec, state = "new", answer = nil,
		expiresAt = os.time() + math.floor(tonumber(spec.expires) or CFG.DefaultExpiry), site = nil,
	}
	-- one call at a time: wait while another is on screen
	local t0 = os.clock()
	while (active[p] or pickupWait[p]) and p.Parent and os.clock() - t0 < 120 do task.wait(0.5) end
	if not p.Parent then return "missed", nil end
	local site = siteOf(p)
	if site then return custodyCall(c, site) end
	return ringCell(c)
end

---------------------------------------------------------------------------
-- client requests
---------------------------------------------------------------------------
R.OnServerEvent:Connect(function(p, action, id, arg)
	if action == "answer" then
		local c = active[p]
		if c and c.id == id and c.state == "ringing" then c.state = "answering" end
	elseif action == "decline" then
		local c = active[p]
		if c and c.id == id and c.state == "ringing" then c.state = "declined" end
	elseif action == "choose" then
		local c = active[p]
		if c and c.id == id and c.state == "talking" then
			c.answer = math.clamp(math.floor(tonumber(arg) or 1), 1, #(c.spec.options or { "OK" }))
			c.state = "done"
		end
	elseif action == "callback" then
		local list = missed[p]
		if not list or siteOf(p) or active[p] then return end
		for i, c in list do
			if c.id == id then
				table.remove(list, i)
				pushMissed(p)
				if c.expiresAt <= os.time() then
					send(p, "notice", ("%s: this offer has expired."):format(tostring(c.spec.from)))
					return
				end
				task.spawn(function()
					c.site = nil
					local how, idx = talk(c)
					if how == "answered" and c.spec.onCallback then pcall(c.spec.onCallback, p, idx) end
				end)
				return
			end
		end
	elseif action == "missedList" then
		pushMissed(p)
	elseif action == "lawyerMenu" then
		-- v257: the phone's Lawyer button
		local law = ServerStorage:FindFirstChild("LawFirms")
		if siteOf(p) then
			send(p, "notice", "No cell phone in custody - use the phone bank.")
		elseif law and law:IsA("BindableFunction") then
			task.spawn(pcall, law.Invoke, law, "menu", p)
		end
	end
end)

---------------------------------------------------------------------------
-- custody phones: pick up a waiting call, or make one
---------------------------------------------------------------------------
local function caseStatus(p: Player): string
	local parts = {}
	local charges = p:GetAttribute("CaseCharges") or p:GetAttribute("Charges")
	if charges then table.insert(parts, "Charges: " .. tostring(charges) .. ".") end
	local ends = tonumber(p:GetAttribute("SentenceEnd"))
	if ends then table.insert(parts, ("You have about %d minute(s) left on your sentence."):format(math.max(0, math.ceil((ends - os.time()) / 60)))) end
	local court = tonumber(p:GetAttribute("CourtDateAt"))
	if court then table.insert(parts, ("Your court date is in %d minute(s)."):format(math.max(0, math.ceil((court - os.time()) / 60)))) end
	local bail = p:GetAttribute("BailOffered")
	if bail then table.insert(parts, ("Bail is set at $%s."):format(tostring(bail))) end
	if #parts == 0 then table.insert(parts, "Nothing new on your case. Sit tight, don't talk to anybody.") end
	return table.concat(parts, " ")
end

local busyPhone: { [Player]: boolean } = {}
-- an outgoing call from a custody phone: connected right away (you are holding the handset)
local function direct(p: Player, site: string, spec: any): (string, number?)
	nextId += 1
	local c: Call = { id = nextId, player = p, spec = spec, state = "new", answer = nil, expiresAt = os.time() + 30, site = site }
	return talk(c)
end
-- v288e: a call to your lawyer is a conversation: the case status, then parole and a new trial -
-- talk only, nothing is filed. Legal calls are privileged (not monitored).
local function lawyerCall(p: Player, site: string)
	local counsel = p:GetAttribute("CounselName") or p:GetAttribute("LawyerFirm")
	if counsel == "Public Defender" and p:GetAttribute("LawyerFirm") then counsel = p:GetAttribute("LawyerFirm") end
	local from = if counsel then tostring(counsel) else "Public Defender's Office"
	local lines = { caseStatus(p) }
	for _ = 1, 4 do
		local how, idx = direct(p, site, { from = from, kind = "lawyer", legal = true, lines = lines,
			options = { "Could I get parole?", "Can we get a new trial?", "That's all" }, expires = 30 })
		if how ~= "answered" or not idx or idx == 3 then break end
		-- talk only: the lawyer explains, nothing is filed on the call
		local death = p:GetAttribute("SecurityClass") == "Death Row" or p:GetAttribute("DeathSentence") == true
		local life = p:GetAttribute("LifeSentence") == true or tostring(p:GetAttribute("CaseVerdict") or ""):find("Life", 1, true) ~= nil
		local plea = p:GetAttribute("CaseVerdict") == "plea"
		if idx == 1 then
			lines = if death then { "\"Parole? You're on death row. What we talk about is appeals, and clemency from the governor - and those are long shots.\"" }
				elseif life then { "\"Life without parole means exactly that. The only door out is a new trial or a commutation.\"" }
				else { "\"You'll be eligible to go before the parole board after about half your time.\"",
					"\"What they look at is your conduct inside. Every write-up is on that table. A clean record and a job make the case for you.\"" }
		else
			lines = if plea then { "\"You pleaded guilty. That closes the door on a new trial - a plea waives almost every appeal.\"" }
				else { "\"A new trial means winning an appeal: an error by the judge, evidence that should never have come in, a juror who lied.\"",
					if death then "\"Capital cases get automatic review. I'll be going through every page of that transcript.\""
					else "\"The odds are small. Most appeals are denied. But I'm reading the transcript - if there's something there, we'll talk.\"" }
		end
	end
	-- v257: a paid lawyer bills the call
	local law = ServerStorage:FindFirstChild("LawFirms")
	if law and law:IsA("BindableFunction") then pcall(law.Invoke, law, "bill", p, "call") end
end

local function usePhone(p: Player, site: string)
	if busyPhone[p] then return end
	-- a call is waiting for this player: take it
	local waiting = pickupWait[p]
	if waiting and waiting.site == site then
		waiting.state = "answering"
		pickupWait[p] = nil
		return
	end
	if active[p] then return end
	busyPhone[p] = true
	local counsel = p:GetAttribute("CounselName") or p:GetAttribute("LawyerFirm") -- v286o: the firm you hired counts (LawyerFirm)
	if counsel == "Public Defender" and p:GetAttribute("LawyerFirm") then counsel = p:GetAttribute("LawyerFirm") end
	local opts = { "Call your lawyer" .. (if counsel then " (" .. tostring(counsel) .. ")" else " (public defender)"), "Call family", "Call your crew", "Hang up" }
	local how, idx = direct(p, site, {
		from = "Correctional phone", kind = "outgoing", legal = false,
		lines = { "Who do you want to call?" }, options = opts, expires = 30,
	})
	if how ~= "answered" or not idx or idx == 4 then busyPhone[p] = nil; return end
	if idx == 1 then
		lawyerCall(p, site)
	elseif idx == 2 then
		local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then hum.Health = math.min(hum.MaxHealth, hum.Health + 10) end
		direct(p, site, {
			from = "Family", kind = "info", legal = false,
			lines = { "\"We miss you. Keep your head down and come home.\"", "(It helps a little.)" }, options = { "Love you too" }, expires = 30,
		})
	elseif idx == 3 then
		local gang = p:GetAttribute("PrisonGang") or p:GetAttribute("StreetGang")
		local how2, idx2 = direct(p, site, {
			from = if gang then tostring(gang) .. " contact" else "Your old crew", kind = "info", legal = false,
			lines = { "\"Careful what you say - these lines are recorded.\"" }, options = { "Pass a message to the crew", "Hang up" }, expires = 30,
		})
		-- monitored: gang business on a prison line gets noticed
		if how2 == "answered" and idx2 == 1 and math.random() < 0.35 then
			p:SetAttribute("CORespect", math.clamp((tonumber(p:GetAttribute("CORespect")) or 0) - 5, -100, 100))
			send(p, "notice", "The call was flagged by monitoring. The COs are watching you.")
			print(("[Phone] FLAGGED %s - crew call on a monitored line"):format(p.Name))
		end
	end
	busyPhone[p] = nil
end

local function buildPhonePrompts()
	local made = 0
	for site in PHONE_OF do
		for _, pos in phonesAt(site) do
			local part = Instance.new("Part")
			part.Name = "PhonePrompt_" .. site
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Transparency = 1
			part.Size = Vector3.new(1, 1, 1)
			part.Position = pos
			part.Parent = Workspace
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = "Use phone"
			prompt.ObjectText = if site == "Prison" then "Inmate phone" elseif site == "CityJail" then "Jail phone" else "Holding phone"
			prompt.HoldDuration = 0.4
			prompt.MaxActivationDistance = CFG.PhoneReach
			prompt.RequiresLineOfSight = false
			prompt.Parent = part
			prompt.Triggered:Connect(function(p)
				if siteOf(p) ~= site then
					send(p, "notice", "Only people held here can use this phone.")
					return
				end
				task.spawn(usePhone, p, site)
			end)
			made += 1
		end
	end
	print(("[Phone] v256 ready: %d custody phone(s)  (HQ %d, City Jail %d, Prison %d)"):format(made,
		#phonesAt("HQ"), #phonesAt("CityJail"), #phonesAt("Prison")))
end

Players.PlayerRemoving:Connect(function(p)
	active[p] = nil
	missed[p] = nil
	pickupWait[p] = nil
	busyPhone[p] = nil
end)
Players.PlayerAdded:Connect(function(p)
	task.delay(5, function() if p.Parent then pushMissed(p) end end)
end)

---------------------------------------------------------------------------
-- the API
---------------------------------------------------------------------------
do
	local fn = ServerStorage:FindFirstChild("Phone") or Instance.new("BindableFunction")
	fn.Name = "Phone"
	fn.OnInvoke = function(action, p, spec)
		if action == "call" then
			return place(p, if type(spec) == "table" then spec else {})
		elseif action == "site" then
			return siteOf(p)
		elseif action == "lawyerCall" then
			-- v288e: one call at prison booking (PoliceSystem)
			if typeof(p) ~= "Instance" or not p:IsA("Player") then return false end
			lawyerCall(p, if type(spec) == "string" then spec else "Prison")
			return true
		elseif action == "dialog" then
			-- v257: a conversation card with no ringing (law office reception, lawyer menus)
			if typeof(p) ~= "Instance" or not p:IsA("Player") then return "missed" end
			local t0 = os.clock()
			while active[p] and p.Parent and os.clock() - t0 < 10 do task.wait(0.2) end
			nextId += 1
			local s = if type(spec) == "table" then spec else {}
			local st = siteOf(p)
			local c: Call = { id = nextId, player = p, spec = s, state = "new", answer = nil, expiresAt = os.time() + 60,
				site = if st and st ~= "Custody" then st else nil }
			return talk(c)
		end
		return nil
	end
	fn.Parent = ServerStorage
end

task.delay(8, buildPhonePrompts)
