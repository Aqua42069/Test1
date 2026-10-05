--[[
	CityLife.Elite (v271) - Elite Representation, Premier Counsel's add-on (spec 9.7)

	Needs Premier Counsel ON RETAINER, a big standing fee every billing cycle, and a per-use
	fee scaled to the charges. At the arrest (the 24/7 line works at 3 AM too):
	  minor     cite and release at the scene - no booking
	  mid       charges knocked down before booking, a short hold, no interrogation
	              ("my client will provide a written statement"), the news buried
	  felony    a lighter case, no interrogation, quiet coverage
	  violent   only a little (and it's hard)
	  cop kill  near impossible; five officers killed can't be fixed - just a nicer ride
	ODDS, not guarantees: harder with a live news broadcast on you, a police player on scene,
	a crowd, a long record, and every time it's used. A real Chief online gets a prompt and
	can refuse. Failed attempts are still billed - and noticed.
	ABUSE: "special treatment" suspicion builds - news exposes, a harsher DA next time,
	the fiduciary underground heats up.
	Logs: [Elite]
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local E = {}
local Core: any

local CFG = {
	Standing = 1000000,
	CycleSeconds = 30 * 60,
	Fee = { minor = 250000, mid = 750000, felony = 3000000, violent = 10000000, copkill = 25000000, death = 25000000 },
	Odds = { minor = 0.9, mid = 0.7, felony = 0.4, violent = 0.15, copkill = 0.03, death = 0 },
	ChiefWait = 8,
}

local function premier(player: Player): boolean
	return player:GetAttribute("LawyerFirm") == "Premier Counsel" and player:GetAttribute("CounselRetained") ~= nil -- v286o: LawFirms stores the firm name there
end

local function classOf(info: any, player: Player): string
	local keys = info.keys or {}
	if player:GetAttribute("DeathRowTestOverride") or (tonumber(player:GetAttribute("PoliceOfficersKilled")) or 0) >= 5 then return "death" end
	if keys.CopKilled or keys.HelicopterDown then return "copkill" end
	if keys.Murder or keys.Kidnapping or keys.BankRobbery then return "violent" end
	if keys.Robbery or keys.AssaultOfficer or keys.ShotsFired or keys.PrisonEscape then return "felony" end
	if (info.stars or 1) <= 1 then return "minor" end
	return "mid"
end

local function crowded(pos: Vector3): number
	local n = 0
	local seen = {}
	for _, part in workspace:GetPartBoundsInRadius(pos, 30) do
		local m = part.Parent
		if m and not seen[m] and part.Name == "HumanoidRootPart" then
			seen[m] = true
			n += 1
		end
	end
	return n
end

-- the arrest: PoliceSystem asks before booking -> nil (no help) or a decision table
local function preJail(player: Player, info: any): any?
	local prof = Core.Profile.get(player)
	local e = prof.elite
	if not e.standing or e.paused or not premier(player) then return nil end
	local class = classOf(info, player)
	local fee = CFG.Fee[class]
	Core.UI.notice(player, "Your Elite Representation line picks up on the first ring...", 5, Color3.fromRGB(60, 50, 20))
	-- billed whether it works or not
	if not Core.charge(player, fee) then
		Core.UI.notice(player, ("Elite: \"The fee didn't clear (%s). We can't act.\""):format(Core.UI.money(fee)), 6)
		Core.log("Elite", "%s couldn't pay the %s fee", player.Name, class)
		return nil
	end
	e.uses = (e.uses or 0) + 1
	Core.Profile.dirty(player)
	local odds = CFG.Odds[class]
	local r = Core.root(player)
	local pos = r and r.Position
	local why = {}
	if Core.News and Core.News.live and Core.News.live.subject == player then odds -= 0.25; table.insert(why, "live TV") end
	if pos then
		for _, p in Players:GetPlayers() do
			local pr = p ~= player and Core.isLaw(p) and Core.root(p)
			if pr and (pr.Position - pos).Magnitude < 60 then odds -= 0.2; table.insert(why, "an officer on scene") break end
		end
		if crowded(pos) > 5 then odds -= 0.1; table.insert(why, "a crowd") end
	end
	local rec = Core.records()
	if rec then
		local ok, n = pcall(rec.priorArrests, player)
		if ok and type(n) == "number" then odds -= 0.05 * math.min(n, 6) end
	end
	odds -= 0.05 * (tonumber(player:GetAttribute("EliteSuspicion")) or 0)
	-- the Chief can refuse
	local chief = Core.chief()
	if chief and chief ~= player and class ~= "minor" then
		local pick = Core.UI.ask(chief, { title = "Elite Representation request", body = ("Premier Counsel asks for special handling of %s's arrest (%s). Allow it?"):format((player:GetAttribute("CharacterName") or player.DisplayName), tostring(info.text)),
			options = { "Allow", "Refuse" }, timeout = CFG.ChiefWait })
		if pick == 2 then
			odds = 0
			table.insert(why, "the Chief refused")
			if Core.News then Core.News.post({ kind = "corruption", level = 2, headline = "Chief refuses 'special treatment' for " .. (player:GetAttribute("CharacterName") or player.DisplayName), body = "Sources say a high-priced law firm leaned on the department.", subjects = { player } }) end
		end
	end
	local works = math.random() < math.max(0, odds)
	player:SetAttribute("EliteSuspicion", (tonumber(player:GetAttribute("EliteSuspicion")) or 0) + 1)
	Core.log("Elite", "%s %s class=%s odds=%.2f -> %s (%s)", player.Name, Core.UI.money(fee), class, odds, tostring(works), table.concat(why, ", "))
	if Core.Underground then Core.Underground.bump("fiduciaries", 0.03, "elite use") end
	-- exposé when it keeps happening
	local susp = tonumber(player:GetAttribute("EliteSuspicion")) or 0
	if susp >= 3 and Core.News then
		Core.News.post({ kind = "corruption", level = 2, headline = ("Special treatment? %s walks out again"):format((player:GetAttribute("CharacterName") or player.DisplayName)),
			body = "Internal Affairs is reviewing the officers involved. The DA promises a tougher line.", subjects = { player } })
	end
	if not works then
		Core.UI.notice(player, "Elite: \"We couldn't make this one go away. We'll see you at the station.\"" .. (if #why > 0 then " (" .. table.concat(why, ", ") .. ")" else ""), 7)
		return nil
	end
	player:SetAttribute("EliteQuiet", true)
	task.delay(20 * 60, function() if player.Parent then player:SetAttribute("EliteQuiet", nil) end end)
	if class == "minor" then
		return { cite = true, message = "Your attorney had a word with the sergeant. Cited and released - no booking." }
	elseif class == "mid" then
		player:SetAttribute("EliteNoInterview", true)
		Core.UI.notice(player, "Elite: \"The charges are being reduced before booking. Say nothing.\"", 6)
		return { stars = 1, dropFelony = true, scale = 0.5 }
	elseif class == "felony" then
		player:SetAttribute("EliteNoInterview", true)
		Core.UI.notice(player, "Elite: \"My client will provide a written statement.\" (no interrogation, a lighter case)", 6)
		return { scale = 0.65 }
	elseif class == "violent" then
		player:SetAttribute("EliteNoInterview", true)
		return { scale = 0.85 }
	else
		Core.UI.notice(player, "Elite: \"There is nothing anyone can do about this. But you'll ride in comfort.\"", 6)
		return { scale = 1 }
	end
end

function E.init(core: any)
	Core = core
	Core.Elite = E
	Core.hook("preJail", preJail)
	-- signing up / pausing lives in Connections
	Core.Connections.extraLists["elite"] = function(player: Player)
		local e = Core.Profile.get(player).elite
		if not premier(player) then
			return { { id = "elite_join", cat = "Legal", who = "Premier Counsel", title = "Elite Representation", price = CFG.Standing,
				desc = "Premier Counsel's 24/7 arrest-scene service. Requires Premier Counsel on retainer.", available = false, why = "Put Premier Counsel on retainer first (their tower lobby)" } }
		end
		if not e.standing then
			return { { id = "elite_join", cat = "Legal", who = "Premier Counsel", title = "Elite Representation", price = CFG.Standing,
				desc = ("Standing fee each billing cycle, plus a per-use fee (%s minor ... %s for the worst)."):format(Core.UI.money(CFG.Fee.minor), Core.UI.money(CFG.Fee.copkill)), available = true } }
		end
		return { { id = "elite_toggle", cat = "Legal", who = "Premier Counsel", title = if e.paused then "Elite: resume the arrest line" else "Elite: pause the arrest line",
			desc = ("On standing since %s. Used %d times."):format(os.date("%m/%d %H:%M", e.since or os.time()), e.uses or 0), price = 0, available = true },
			{ id = "elite_quit", cat = "Legal", who = "Premier Counsel", title = "End Elite Representation", desc = "No refunds.", price = 0, available = true } }
	end
	Core.Connections.extraRun["elite_join"] = function(player: Player)
		if not premier(player) then return false, "Premier Counsel isn't on retainer" end
		if not Core.charge(player, CFG.Standing) then return false, "The standing fee is " .. Core.UI.money(CFG.Standing) end
		local e = Core.Profile.get(player).elite
		e.standing = true
		e.paused = false
		e.since = os.time()
		e.paidAt = os.time()
		Core.Profile.dirty(player)
		player:SetAttribute("EliteRepresentation", true)
		return true, "Welcome to Elite Representation. Save the number. Call it from anywhere, any hour."
	end
	Core.Connections.extraRun["elite_toggle"] = function(player: Player)
		local e = Core.Profile.get(player).elite
		e.paused = not e.paused
		Core.Profile.dirty(player)
		return true, if e.paused then "Paused - arrests go through normally" else "The arrest line is on"
	end
	Core.Connections.extraRun["elite_quit"] = function(player: Player)
		local e = Core.Profile.get(player).elite
		e.standing = false
		Core.Profile.dirty(player)
		player:SetAttribute("EliteRepresentation", nil)
		return true, "Elite Representation ended"
	end
	-- the standing fee, every cycle
	task.spawn(function()
		while true do
			task.wait(60)
			for _, p in Players:GetPlayers() do
				local prof = Core.Profile.peek(p)
				local e = prof and prof.elite
				if e and e.standing and os.time() - (e.paidAt or 0) >= CFG.CycleSeconds then
					if Core.charge(p, CFG.Standing) then
						e.paidAt = os.time()
						Core.UI.notice(p, "Elite Representation: standing fee " .. Core.UI.money(CFG.Standing), 4)
					else
						e.standing = false
						p:SetAttribute("EliteRepresentation", nil)
						Core.UI.notice(p, "Elite Representation lapsed - the standing fee didn't clear", 6)
					end
					Core.Profile.dirty(p)
				end
			end
		end
	end)
	Core.Profile.onLoaded(function(player, prof)
		if prof.elite and prof.elite.standing then player:SetAttribute("EliteRepresentation", true) end
	end)
	print("[Elite] v271 ready (Elite Representation)")
end

return E
