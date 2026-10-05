--[[
	CityLife.Warrants (v260) - no-star warrants and BOLOs (spec 10.1, 10.3, 10.5).

	WARRANTS: failure to appear (Bail), named by an accomplice (Interrogation), escape, the
	Chief's console. Saved in the profile, shown only to you as a HUD tag
	("ACTIVE WARRANT: Failure to appear"). Police act normally until they IDENTIFY you
	(Recognition, a plate reader, a traffic stop, the MDT): then it's served - the charges go
	back on the record and the stars match the severity:
	    1 low-risk   (1 star: approach, comply, cuff)
	    2 standard   (2 stars)
	    3 serious    (3+ stars: felony stop, guns drawn, backup)
	Running turns into a normal pursuit; evading clears the stars, NOT the warrant.
	Cleared by: an arrest (bail revoked, held until trial), turning yourself in (better
	outcome), the Chief, or a bribed clerk (Connections).

	BOLOs: "black SUV, partial plate 7K..., red shirt, last seen near the Bellagio".
	Posted after an evaded pursuit, by the Chief or a police player; expire after a while.
	Logs: [Warrant]
]]

local Players = game:GetService("Players")

local W = {}
local Core: any

local CFG = {
	IdentifyCooldown = 45, -- seconds between servings for one person (no spam while they run)
	BoloLife = 12 * 60,
	SeverityStars = { 1, 2, 3 },
}

-- crimes the severity is read from when nobody gives one
local SERIOUS = { Murder = 3, CopKilled = 3, FiveCopKills = 3, BankRobbery = 3, PrisonEscape = 3, HelicopterDown = 3,
	Robbery = 2, AssaultOfficer = 2, ShotsFired = 2, Kidnapping = 3, JuryTampering = 2 }

local lastServed: { [Player]: number } = {}
local syncing: { [Player]: boolean } = {}
W.bolos = {} :: { any }
local nextBolo = 0

local function severityOf(crimes: { string }?, given: number?): number
	if given and given >= 1 then return math.clamp(math.floor(given), 1, 3) end
	local s = 1
	for _, c in crimes or {} do s = math.max(s, SERIOUS[c] or 1) end
	return s
end

function W.list(player: Player): { any }
	local p = Core.Profile.peek(player)
	return p and p.warrants or {}
end
function W.active(player: Player): any?
	local list = W.list(player)
	local top = nil
	for _, w in list do
		if not top or (w.severity or 1) > (top.severity or 1) then top = w end
	end
	return top
end
function W.text(player: Player): string?
	local list = W.list(player)
	if #list == 0 then return nil end
	local parts = {}
	for _, w in list do table.insert(parts, w.reason) end
	return table.concat(parts, "; ")
end

-- the HUD tag + the Warrant attribute other scripts read (Chief console, Bail)
local function refresh(player: Player)
	local txt = W.text(player)
	syncing[player] = true
	player:SetAttribute("Warrant", if txt then string.sub(txt, 1, 200) else nil)
	local top = W.active(player)
	player:SetAttribute("WarrantSeverity", if top then top.severity else nil)
	syncing[player] = nil
	Core.UI.tag(player, "warrant", if txt then "ACTIVE WARRANT: " .. string.sub(txt, 1, 60) else nil)
end
W.refresh = refresh

-- the look on file (for disguises): clothes, accessories, face
function W.lookOf(player: Player): any?
	local c = player.Character
	if not c then return nil end
	local look = { acc = {} }
	local shirt = c:FindFirstChildOfClass("Shirt")
	local pants = c:FindFirstChildOfClass("Pants")
	look.shirt = shirt and shirt.ShirtTemplate or ""
	look.pants = pants and pants.PantsTemplate or ""
	for _, a in c:GetChildren() do
		if a:IsA("Accessory") then table.insert(look.acc, a.Name) end
	end
	local torso = c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
	look.torso = if torso and torso:IsA("BasePart") then torso.BrickColor.Name else ""
	return look
end
-- "red shirt, black cap" style description for a BOLO
function W.describe(player: Player): string
	local c = player.Character
	if not c then return "unknown clothing" end
	local bits = {}
	local torso = c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then table.insert(bits, string.lower(torso.BrickColor.Name) .. " top") end
	for _, a in c:GetChildren() do
		if a:IsA("Accessory") then
			local n = string.lower(a.Name)
			if n:find("mask") or n:find("balaclava") then table.insert(bits, "masked")
			elseif n:find("hat") or n:find("cap") or n:find("beanie") or n:find("helmet") then table.insert(bits, "wearing a hat") end
		end
	end
	return if #bits > 0 then table.concat(bits, ", ") else "plain clothes"
end

---------------------------------------------------------------------------
-- issue / clear / serve
---------------------------------------------------------------------------
-- spec = { reason, crimes = { key }, severity?, source, by? } -> the warrant
function W.issue(player: Player, spec: any): any
	local p = Core.Profile.get(player)
	local crimes = spec.crimes or {}
	local w = {
		id = Core.code(),
		reason = string.sub(tostring(spec.reason or "Outstanding warrant"), 1, 120),
		crimes = crimes,
		severity = severityOf(crimes, spec.severity),
		source = spec.source or "court",
		by = spec.by,
		at = os.time(),
	}
	-- one warrant per reason (a second FTA doesn't stack)
	for _, old in p.warrants do
		if old.reason == w.reason then return old end
	end
	table.insert(p.warrants, w)
	p.look = p.look or W.lookOf(player)
	Core.Profile.dirty(player)
	refresh(player)
	Core.UI.notice(player, "A warrant has been issued for your arrest: " .. w.reason, 8, Color3.fromRGB(120, 20, 20))
	Core.radio(("WARRANT ISSUED: %s - %s (severity %d)"):format(player.Name, w.reason, w.severity))
	Core.log("Warrant", "ISSUED %s: %s sev=%d source=%s", player.Name, w.reason, w.severity, w.source)
	Core.emit("warrant", player, w)
	return w
end

function W.clear(player: Player, why: string)
	local p = Core.Profile.peek(player)
	if not p or #p.warrants == 0 then
		refresh(player)
		return
	end
	p.warrants = {}
	Core.Profile.dirty(player)
	refresh(player)
	Core.log("Warrant", "CLEARED %s (%s)", player.Name, why)
	Core.emit("warrantCleared", player, why)
end

-- remove one warrant (a bribed clerk loses the paperwork)
function W.drop(player: Player, id: string): boolean
	local p = Core.Profile.peek(player)
	if not p then return false end
	for i, w in p.warrants do
		if w.id == id then
			table.remove(p.warrants, i)
			Core.Profile.dirty(player)
			refresh(player)
			return true
		end
	end
	return false
end

-- put the warrant's charges back on the police record and set the stars
local function serveCharges(player: Player, w: any)
	local pos = Core.root(player) and (Core.root(player) :: BasePart).Position
	local any = false
	for _, key in w.crimes or {} do
		if key == "FiveCopKills" then
			local have = tonumber(player:GetAttribute("PoliceOfficersKilled")) or 0
			for _ = 1, math.max(1, 5 - have) do Core.report(player, "CopKilled", pos) end
			player:SetAttribute("DeathRowTestOverride", true)
		else
			Core.report(player, key, pos)
		end
		any = true
	end
	if not any then
		-- the charge is the warrant itself (failure to appear, escape...)
		local key = if w.reason:lower():find("appear") then "FailureToAppear" else "Warrant"
		Core.report(player, key, pos, 10)
	end
	local want = CFG.SeverityStars[w.severity or 1] or 1
	if Core.stars(player) < want then Core.setStars(player, want) end
end

-- an officer / reader / stop identified them: serve every warrant they have
function W.identify(player: Player, how: string, by: any?): boolean
	local w = W.active(player)
	if not w or Core.inCustody(player) then return false end
	local now = os.clock()
	if lastServed[player] and now - lastServed[player] < CFG.IdentifyCooldown and Core.stars(player) > 0 then return false end
	lastServed[player] = now
	for _, each in W.list(player) do serveCharges(player, each) end
	local where = Core.root(player) and Core.placeName((Core.root(player) :: BasePart).Position) or "the city"
	local stop = if (w.severity or 1) >= 3 then "FELONY STOP - weapons drawn, backup en route" elseif (w.severity or 1) == 2 then "approach with caution" else "low-risk stop"
	Core.radio(("%s: %s identified %s - ACTIVE WARRANT: %s. %s"):format(how, if type(by) == "string" then by else "unit", player.Name, w.reason, stop),
		Core.root(player) and (Core.root(player) :: BasePart).Position, "Warrant subject")
	Core.UI.notice(player, if (w.severity or 1) >= 3 then "POLICE: \"Show me your hands! Get on the ground!\"" else "POLICE: \"Hey - stop right there. You've got a warrant.\"", 6, Color3.fromRGB(120, 20, 20))
	Core.log("Warrant", "IDENTIFIED %s via %s near %s (sev %d)", player.Name, how, where, w.severity or 1)
	Core.emit("identified", player, how, w)
	if (w.severity or 1) >= 3 then
		task.spawn(Core.policeFn, "SpawnUnits", (Core.root(player) :: BasePart).Position, "Officer", 2, 90)
	end
	return true
end

---------------------------------------------------------------------------
-- BOLOs
---------------------------------------------------------------------------
-- spec = { subject = Player?, text, car = { type, colour, plate }, clothing, pos }
function W.bolo(spec: any): any
	nextBolo += 1
	local b = {
		id = nextBolo,
		subjectId = spec.subject and spec.subject.UserId,
		subject = spec.subject and spec.subject.Name,
		car = spec.car,
		clothing = spec.clothing,
		pos = spec.pos,
		place = spec.pos and Core.placeName(spec.pos) or nil,
		text = spec.text,
		at = os.time(),
		expires = os.time() + (spec.life or CFG.BoloLife),
		by = spec.by,
	}
	if not b.text then
		local bits = {}
		if b.car then
			table.insert(bits, ("%s %s"):format(string.lower(b.car.colour or ""), b.car.type or "vehicle"))
			if b.car.plate then table.insert(bits, "partial plate " .. string.sub(b.car.plate, 1, 3) .. "...") end
		end
		if b.clothing then table.insert(bits, b.clothing) end
		if b.place then table.insert(bits, "last seen " .. b.place) end
		b.text = table.concat(bits, ", ")
	end
	table.insert(W.bolos, 1, b)
	while #W.bolos > 25 do table.remove(W.bolos) end
	Core.radio("BOLO: " .. (b.subject and (b.subject .. " - ") or "") .. b.text, b.pos, "BOLO")
	Core.log("Warrant", "BOLO #%d %s", b.id, b.text)
	Core.emit("bolo", b)
	return b
end
function W.activeBolos(): { any }
	local now, out = os.time(), {}
	for _, b in W.bolos do
		if b.expires > now then table.insert(out, b) end
	end
	return out
end
-- a car that visually matches a BOLO (type + colour) -> the BOLO
function W.boloForCar(carType: string?, colour: string?, plate: string?): any?
	for _, b in W.activeBolos() do
		local c = b.car
		if c then
			if plate and c.plate and plate == c.plate then return b end
			if carType and colour and c.type == carType and string.lower(c.colour or "") == string.lower(colour) then return b end
		end
	end
	return nil
end
function W.boloFor(player: Player): any?
	for _, b in W.activeBolos() do
		if b.subjectId == player.UserId then return b end
	end
	return nil
end

---------------------------------------------------------------------------
function W.init(core: any)
	Core = core

	-- the Warrant attribute set by older code (Bail's failure to appear, the Chief fallback)
	local function watch(player: Player)
		player:GetAttributeChangedSignal("Warrant"):Connect(function()
			if syncing[player] then return end
			local v = player:GetAttribute("Warrant")
			if type(v) == "string" and v ~= "" then
				local src = if v:lower():find("appear") then "court" else "external"
				W.issue(player, { reason = v, crimes = {}, severity = if src == "court" then 1 else 2, source = src })
			end
		end)
		-- escapes (PoliceSystem marks the phase) become a warrant
		player:GetAttributeChangedSignal("CustodyPhase"):Connect(function()
			if player:GetAttribute("CustodyPhase") == "Escaped" then
				W.issue(player, { reason = "Escape from custody", crimes = { "PrisonEscape" }, severity = 3, source = "escape" })
			end
		end)
	end
	for _, p in Players:GetPlayers() do watch(p) end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(p) lastServed[p] = nil; syncing[p] = nil end)
	Core.Profile.onLoaded(function(player)
		task.wait(2)
		refresh(player)
		local w = W.active(player)
		if w then Core.UI.notice(player, "You still have an active warrant: " .. w.reason, 8, Color3.fromRGB(120, 20, 20)) end
	end)

	-- arrested = served; evaded = the warrant stays, a BOLO goes out
	task.spawn(function()
		local ev = nil
		for _ = 1, 60 do
			ev = Core.policeEvent("Cleared")
			if ev then break end
			task.wait(1)
		end
		if not ev then warn("[Warrant] PoliceAI.Cleared not found") return end
		ev.Event:Connect(function(player: Player, reason: string)
			if reason == "Busted" then
				if #W.list(player) > 0 then
					Core.log("Warrant", "SERVED %s (arrested)", player.Name)
					local rec = Core.records()
					if rec and rec.note then pcall(rec.note, player, "warrantServed") end
					player:SetAttribute("BailRevoked", true) -- held until trial
					W.clear(player, "served - arrested")
				end
				local p = Core.Profile.peek(player)
				if p then p.look = W.lookOf(player); Core.Profile.dirty(player) end -- the booking photo
			elseif reason == "Evaded" then
				local r = Core.root(player)
				local car = Core.seatedCar(player)
				local carInfo = nil
				if car and Core.Plates then carInfo = Core.Plates.describe(car) end
				local stars = player:GetAttribute("LastStarsBeforeClear") or 0
				if (tonumber(stars) or 0) >= 2 or #W.list(player) > 0 then
					W.bolo({ subject = player, car = carInfo, clothing = W.describe(player), pos = r and r.Position })
				end
			end
		end)
	end)

	-- PoliceSystem / Interrogation / the Chief ask for these
	Core.hook("turnIn", function(player: Player)
		local w = W.active(player)
		if not w then return false end
		player:SetAttribute("TurnedIn", true)
		for _, each in W.list(player) do serveCharges(player, each) end
		Core.log("Warrant", "TURN IN %s (%s)", player.Name, w.reason)
		W.clear(player, "turned in")
		return true
	end)
	Core.hook("snitched", function(snitch: Player, target: Player, crime: string?)
		local p = Core.Profile.get(target)
		p.connections.snitchedBy = p.connections.snitchedBy or {}
		if not table.find(p.connections.snitchedBy, snitch.Name) then table.insert(p.connections.snitchedBy, snitch.Name) end
		Core.Profile.dirty(target)
		W.issue(target, { reason = "Named by an accomplice" .. (if crime then " (" .. crime .. ")" else ""), crimes = if crime then { crime } else {}, source = "informant" })
		Core.emit("snitch", snitch, target, crime)
		return true
	end)
	Core.hook("chiefWarrant", function(target: Player, spec: any)
		W.issue(target, { reason = spec.reason, crimes = spec.crimes, severity = if (spec.severity or 0) > 0 then spec.severity else nil, source = "chief", by = spec.by })
		return true
	end)
	Core.hook("clearWarrant", function(target: Player, why: string?)
		W.clear(target, why or "cleared")
		return true
	end)

	-- remember the stars just before a pursuit ends (for the BOLO decision)
	local function trackStars(player: Player)
		player:GetAttributeChangedSignal("WantedStars"):Connect(function()
			local s = tonumber(player:GetAttribute("WantedStars")) or 0
			if s > 0 then player:SetAttribute("LastStarsBeforeClear", s) end
		end)
	end
	for _, p in Players:GetPlayers() do trackStars(p) end
	Players.PlayerAdded:Connect(trackStars)

	Core.Warrants = W
	print("[Warrant] v260 ready (no-star warrants, BOLOs)")
end

return W
