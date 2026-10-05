--[[
	CityLife.Stops (v278) - traffic stops, LCPDFR style (spec 15)

	A police player driving presses B (or the STOP button on mobile): the nearest car ahead
	(within 70 studs) is lit up.
	  AI traffic: the driver eases to the kerb and stops. Walk up - "Talk to driver".
	  A player: "PULL OVER" on their screen; stop within ~20 s or it's evading (stars).
	At the window (a menu):
	  licence & registration . run the plate . run the driver (DAVID) . frisk . breathalyzer
	  . issue a citation (a fine from their bank) . arrest . let them go
	AI drivers each have a story: most are fine; some are drunk, suspended, carrying, have a
	warrant, or the car isn't theirs. Some flee, a few fight. DUI = licence suspended.
	Officers earn for good stops (paid to the bank). An arrest with no cause is a complaint.
	Logs: [Stop]
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local S = {}
local Core: any

local CFG = {
	Range = 70,
	PlayerStopWindow = 22,
	EvadeDistance = 160,
	Pay = { citation = 150, dui = 450, warrant = 600, contraband = 400, stolen = 500, suspended = 300 },
	CitationFine = 500,
}

local stops: { [any]: any } = {} -- key: car model
local busyOfficer: { [Player]: any } = {}

-- an AI driver's story
local function npcIdentity(car: Model): any
	local r = math.random
	local id = {
		name = Core.fakeName(),
		licence = if r() < 0.08 then "suspended" elseif r() < 0.04 then "none" else "valid",
		warrant = r() < 0.06,
		bac = if r() < 0.08 then 0.08 + r() * 0.12 else r() * 0.03,
		contraband = if r() < 0.05 then "an unlicensed pistol" elseif r() < 0.06 then "a bag of pills" else nil,
		mood = if r() < 0.07 then "flee" elseif r() < 0.04 then "fight" elseif r() < 0.2 then "argue" else "comply",
	}
	if car:GetAttribute("DrunkDriver") then -- a callout: "possible drunk driver"
		id.bac = 0.11 + r() * 0.08
		id.mood = if r() < 0.25 then "flee" else "argue"
	end
	local plate = Core.Plates.ensure(car)
	local rec = Core.Plates.lookup(plate)
	-- usually it's their car; sometimes borrowed or stolen
	if rec and rec.kind == "npc" then
		local roll = r()
		if roll < 0.82 then rec.owner = id.name
		elseif roll < 0.97 then id.borrowed = true
		else rec.stolenAt = os.time() - 60 end
	end
	return id
end

local function carAhead(officer: Player): Model?
	local mine = Core.seatedCar(officer)
	local root = Core.root(officer)
	if not mine or not root then return nil end
	local seat = mine.PrimaryPart or root
	local look = seat.CFrame.LookVector
	local best, bd = nil, math.huge
	local function consider(m: Model)
		if m == mine or not m.Parent then return end
		local pp = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
		if not pp then return end
		local off = pp.Position - seat.Position
		local d = off.Magnitude
		if d > CFG.Range or d < 3 then return end
		if look:Dot(off.Unit) < 0.5 then return end
		if d < bd then best, bd = m, d end
	end
	for _, m in CollectionService:GetTagged("SmoothResidentTraffic") do
		if m:IsA("Model") and m:GetAttribute("TrafficActive") then consider(m) end
	end
	local sp = workspace:FindFirstChild("SpawnedCars")
	if sp then
		for _, m in sp:GetChildren() do
			local d = m:IsA("Model") and Core.driver(m)
			if d and d ~= officer then consider(m) end
		end
	end
	return best
end

local function pay(officer: Player, what: string)
	local n = CFG.Pay[what] or 100
	Core.pay(officer, n, "bank")
	Core.UI.notice(officer, ("+%s (%s)"):format(Core.UI.money(n), what), 3, Color3.fromRGB(20, 90, 40))
end

local function finish(stop: any, why: string)
	stops[stop.car] = nil
	if busyOfficer[stop.officer] == stop then busyOfficer[stop.officer] = nil end
	if stop.prompt then stop.prompt:Destroy() end
	if stop.car.Parent and stop.kind == "npc" then
		stop.car:SetAttribute("PullOver", nil)
		stop.car:SetAttribute("PullOverBy", nil)
	end
	if stop.target then
		Core.UI.tag(stop.target, "stop", nil)
	end
	Core.UI.waypoint(stop.officer, "stop", nil)
	Core.log("Stop", "END %s's stop: %s", stop.officer.Name, why)
end

---------------------------------------------------------------------------
-- the window (AI driver)
---------------------------------------------------------------------------
local function npcWindow(stop: any)
	local o = stop.officer
	local id = stop.id
	local car = stop.car
	local cause = {}
	if id.mood == "flee" and not stop.fled and math.random() < 0.7 then
		stop.fled = true
		Core.UI.notice(o, "The driver floors it!", 4, Color3.fromRGB(120, 20, 20))
		Core.radio(("%s: driver fled a traffic stop near %s - %s"):format(o.Name, Core.placeName((car.PrimaryPart :: BasePart).Position), Core.Plates.describe(car).type))
		car:SetAttribute("TrafficFleeing", true)
		finish(stop, "fled")
		return
	end
	if id.mood == "fight" and not stop.fought then
		stop.fought = true
		local h = o.Character and o.Character:FindFirstChildOfClass("Humanoid")
		if h then h:TakeDamage(15) end
		Core.UI.notice(o, "The driver swings at you! You take them down.", 5, Color3.fromRGB(120, 20, 20))
		table.insert(cause, "assault on an officer")
		stop.cause = stop.cause or {}
		table.insert(stop.cause, "assault on an officer")
	end
	stop.cause = stop.cause or {}
	while stop.car.Parent and o.Parent and stops[car] == stop do
		local opts = { "Licence & registration", "Run the plate", "Run the driver (DAVID)", "Frisk / search", "Breathalyzer", "Issue a citation", "Arrest", "Let them go" }
		local body = ("Driver: %s%s"):format(if stop.seenId then id.name else "(not yet identified)",
			if #stop.cause > 0 then "\nCause: " .. table.concat(stop.cause, ", ") else "")
		local pick = Core.UI.ask(o, { title = "Traffic stop", body = body, options = opts, timeout = 45 })
		if not pick then finish(stop, "walked away") return end
		local what = opts[pick]
		if what == "Licence & registration" then
			stop.seenId = true
			if id.mood == "argue" then Core.UI.notice(o, "\"What's this about, officer? I wasn't doing anything!\"", 4) end
			local lic = if id.licence == "none" then "NO LICENCE" else id.licence
			Core.UI.notice(o, ("%s - licence: %s%s"):format(id.name, lic, if id.borrowed then " (says it's a friend's car)" else ""), 6)
			if id.licence ~= "valid" and not table.find(stop.cause, "driving without a valid licence") then table.insert(stop.cause, "driving without a valid licence") end
		elseif what == "Run the plate" then
			local hits = Core.Plates.check(car, nil)
			local rec = Core.Plates.lookup(car:GetAttribute("Plate"))
			local lines = { ("Plate %s: registered to %s"):format(tostring(car:GetAttribute("Plate")), rec and rec.owner or "?") }
			for _, h in hits do table.insert(lines, h.text) end
			for _, h in hits do
				if h.kind == "stolen" and not table.find(stop.cause, "stolen vehicle") then table.insert(stop.cause, "stolen vehicle") end
			end
			Core.UI.ask(o, { title = "Plate check", body = table.concat(lines, "\n"), options = { "OK" }, timeout = 20 })
		elseif what == "Run the driver (DAVID)" then
			stop.seenId = true
			local lines = { id.name, "Licence: " .. id.licence }
			if id.warrant then
				table.insert(lines, "ACTIVE WARRANT: failure to appear")
				if not table.find(stop.cause, "warrant") then table.insert(stop.cause, "warrant") end
			else
				table.insert(lines, "No warrants")
			end
			Core.UI.ask(o, { title = "DAVID", body = table.concat(lines, "\n"), options = { "OK" }, timeout = 20 })
		elseif what == "Frisk / search" then
			if id.contraband then
				Core.UI.notice(o, "Found " .. id.contraband .. "!", 5, Color3.fromRGB(120, 60, 20))
				if not table.find(stop.cause, "contraband") then table.insert(stop.cause, "contraband") end
			else
				Core.UI.notice(o, "Nothing found", 3)
			end
		elseif what == "Breathalyzer" then
			Core.UI.notice(o, ("BAC %.3f%s"):format(id.bac, if id.bac >= 0.08 then " - OVER THE LIMIT" else ""), 5)
			if id.bac >= 0.08 and not table.find(stop.cause, "DUI") then table.insert(stop.cause, "DUI") end
		elseif what == "Issue a citation" then
			pay(o, "citation")
			Core.UI.notice(o, "Citation issued. \"Have a nice day.\"", 3)
			finish(stop, "cited")
			return
		elseif what == "Arrest" then
			if #stop.cause == 0 then
				Core.UI.notice(o, "No probable cause - the driver files a complaint", 5, Color3.fromRGB(120, 20, 20))
				finish(stop, "bad arrest")
				return
			end
			for _, c in stop.cause do
				local key = if c == "DUI" then "dui" elseif c == "warrant" then "warrant" elseif c == "contraband" then "contraband"
					elseif c == "stolen vehicle" then "stolen" elseif c == "driving without a valid licence" then "suspended" else "citation"
				pay(o, key)
			end
			Core.UI.notice(o, ("%s is cuffed and taken in (%s). The car is towed."):format(id.name, table.concat(stop.cause, ", ")), 6)
			Core.log("Stop", "NPC ARREST by %s: %s (%s)", o.Name, id.name, table.concat(stop.cause, ", "))
			Core.emit("npcArrest", o, id, stop.cause)
			car:SetAttribute("TrafficRecycle", true)
			finish(stop, "arrested")
			return
		else
			finish(stop, "released")
			return
		end
	end
end

---------------------------------------------------------------------------
-- the window (a player)
---------------------------------------------------------------------------
local function playerWindow(stop: any)
	local o, t = stop.officer, stop.target
	stop.cause = stop.cause or {}
	while t.Parent and o.Parent and stops[stop.car] == stop do
		local opts = { "Ask for licence", "Run the plate", "Run the driver (DAVID)", "Frisk / search", "Breathalyzer", "Issue a citation ($500)", "Arrest", "Let them go" }
		local pick = Core.UI.ask(o, { title = "Traffic stop - " .. (t:GetAttribute("CharacterName") or t.DisplayName), body = if #stop.cause > 0 then "Cause: " .. table.concat(stop.cause, ", ") else "", options = opts, timeout = 60 })
		if not pick then finish(stop, "walked away") return end
		local what = opts[pick]
		if what == "Ask for licence" then
			local ans = Core.UI.ask(t, { title = "Officer " .. (o:GetAttribute("CharacterName") or o.DisplayName), body = "\"Licence and registration, please.\"", options = { "Hand it over", "Refuse", "Drive off" }, timeout = 15 })
			if ans == 1 then
				local status = Core.Licence.status(t)
				Core.UI.notice(o, ("%s - licence %s"):format((t:GetAttribute("CharacterName") or t.DisplayName), status), 6)
				if status ~= "valid" and not table.find(stop.cause, "driving while suspended") then table.insert(stop.cause, "driving while suspended") end
			elseif ans == 3 then
				Core.UI.notice(o, (t:GetAttribute("CharacterName") or t.DisplayName) .. " drives off!", 4, Color3.fromRGB(120, 20, 20))
				Core.report(t, "EvadingPolice", Core.root(t) and (Core.root(t) :: BasePart).Position)
				finish(stop, "evaded")
				return
			else
				Core.UI.notice(o, (t:GetAttribute("CharacterName") or t.DisplayName) .. " refuses to identify themselves", 4)
				if not table.find(stop.cause, "obstruction") then table.insert(stop.cause, "obstruction") end
			end
		elseif what == "Run the plate" then
			local hits = Core.Plates.check(stop.car, t)
			local lines = {}
			for _, h in hits do table.insert(lines, h.text) end
			if #lines == 0 then table.insert(lines, ("Plate %s - clean, matches the vehicle"):format(tostring(stop.car:GetAttribute("Plate")))) end
			for _, h in hits do
				if h.kind == "stolen" and not table.find(stop.cause, "stolen vehicle") then table.insert(stop.cause, "stolen vehicle") end
				if h.kind == "stolenplate" and not table.find(stop.cause, "stolen plates") then table.insert(stop.cause, "stolen plates") end
				if h.kind == "mismatch" and not table.find(stop.cause, "plate doesn't match") then table.insert(stop.cause, "plate doesn't match") end
			end
			Core.UI.ask(o, { title = "Plate check", body = table.concat(lines, "\n"), options = { "OK" }, timeout = 25 })
		elseif what == "Run the driver (DAVID)" then
			local info = Core.David.person(o, t, "traffic stop")
			local lines = { info.name, "Licence: " .. info.licence }
			for _, f in info.flags do table.insert(lines, f) end
			Core.UI.ask(o, { title = "DAVID", body = table.concat(lines, "\n"), options = { "OK" }, timeout = 25 })
			if Core.Warrants.active(t) then
				Core.Warrants.identify(t, "Traffic stop", o.Name)
				finish(stop, "warrant hit")
				pay(o, "warrant")
				return
			end
		elseif what == "Frisk / search" then
			local found = {}
			for _, c in { t:FindFirstChildOfClass("Backpack"), t.Character } do
				if c then
					for _, tool in c:GetChildren() do
						if tool:IsA("Tool") and (tool:GetAttribute("Contraband") or tool:GetAttribute("Substance")) then table.insert(found, tool.Name) end
					end
				end
			end
			Core.UI.notice(t, "The officer searches you", 3)
			if #found > 0 then
				Core.UI.notice(o, "Found: " .. table.concat(found, ", "), 5, Color3.fromRGB(120, 60, 20))
				if not table.find(stop.cause, "contraband") then table.insert(stop.cause, "contraband") end
			else
				Core.UI.notice(o, "Nothing found", 3)
			end
		elseif what == "Breathalyzer" then
			local imp = tonumber(t:GetAttribute("Impairment")) or 0
			local bac = tonumber(t:GetAttribute("DUIBAC")) or imp * 0.2
			Core.UI.notice(o, ("BAC %.3f%s"):format(bac, if bac >= 0.08 or imp >= 0.35 then " - IMPAIRED" else ""), 5)
			if (bac >= 0.08 or imp >= 0.35) and not table.find(stop.cause, "DUI") then table.insert(stop.cause, "DUI") end
		elseif what == "Issue a citation ($500)" then
			Core.Licence.cite(t, "Traffic violation", CFG.CitationFine, 2, o.Name)
			pay(o, "citation")
			finish(stop, "cited")
			return
		elseif what == "Arrest" then
			if #stop.cause == 0 then
				Core.UI.notice(o, "No probable cause - you can't arrest them for that", 5, Color3.fromRGB(120, 20, 20))
			else
				local pos = Core.root(t) and (Core.root(t) :: BasePart).Position
				for _, c in stop.cause do
					local key = if c == "DUI" then "DUI" elseif c == "contraband" then "Contraband" elseif c == "stolen vehicle" then "VehicleTheft"
						elseif c == "stolen plates" then "PlateTheft" elseif c == "driving while suspended" then "DrivingSuspended"
						elseif c == "obstruction" then "Obstruction" else "SuspiciousVehicle"
					Core.report(t, key, pos, 8)
					if c == "DUI" then Core.Licence.suspend(t, "DUI") end
				end
				Core.UI.notice(o, "Cuff them - they're wanted now (" .. table.concat(stop.cause, ", ") .. ")", 5)
				pay(o, "dui")
				finish(stop, "arrest")
				return
			end
		else
			Core.UI.notice(t, "\"You're free to go. Drive safe.\"", 3)
			finish(stop, "released")
			return
		end
	end
end

---------------------------------------------------------------------------
local function talkPrompt(stop: any)
	local car = stop.car
	local seat = car.PrimaryPart or car:FindFirstChildWhichIsA("VehicleSeat", true)
	if not seat then return end
	local pr = Instance.new("ProximityPrompt")
	pr.Name = "StopPrompt"
	pr.ActionText = "Talk to driver"
	pr.ObjectText = "Traffic stop"
	pr.HoldDuration = 0.3
	pr.MaxActivationDistance = 12
	pr.RequiresLineOfSight = false
	pr.KeyboardKeyCode = Enum.KeyCode.E
	pr:SetAttribute("OwnerOnly", stop.officer.UserId)
	pr.Parent = seat
	stop.prompt = pr
	pr.Triggered:Connect(function(who: Player)
		if who ~= stop.officer or stop.talking then return end
		stop.talking = true
		local ok, err = pcall(if stop.kind == "npc" then npcWindow else playerWindow, stop)
		if not ok then warn("[Stop] " .. tostring(err)) end
		stop.talking = false
	end)
end

function S.start(officer: Player)
	if not Core.isLaw(officer) then return end
	if busyOfficer[officer] then
		finish(busyOfficer[officer], "officer ended it")
		Core.UI.notice(officer, "Stop cancelled", 2)
		return
	end
	local car = carAhead(officer)
	if not car then
		Core.UI.notice(officer, "No vehicle ahead to stop", 2)
		return
	end
	if stops[car] then return end
	local target = Core.driver(car)
	local stop = { officer = officer, car = car, started = os.clock(), kind = if target then "player" else "npc", target = target }
	stops[car] = stop
	busyOfficer[officer] = stop
	local pp = car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart", true)
	Core.UI.waypoint(officer, "stop", (pp :: BasePart).Position, "Traffic stop")
	Core.log("Stop", "%s lit up a %s (%s)", officer.Name, Core.Plates.typeOf(car), if target then target.Name else "AI driver")
	if not target then
		stop.id = npcIdentity(car)
		car:SetAttribute("PullOver", true)
		car:SetAttribute("PullOverBy", officer.UserId)
		Core.UI.notice(officer, "The car signals and pulls over to the kerb", 3)
		task.delay(3, function() if stops[car] == stop then talkPrompt(stop) end end)
		-- a stop left alone ends itself
		task.delay(240, function() if stops[car] == stop then finish(stop, "timed out") end end)
		return
	end
	-- a player
	target:SetAttribute("TrafficStopAt", os.time())
	Core.UI.notice(target, "POLICE: \"Pull over - NOW!\" (stop the car)", 6, Color3.fromRGB(120, 20, 20))
	Core.UI.tag(target, "stop", "PULL OVER - police behind you")
	task.spawn(function()
		local t0 = os.clock()
		local stopped = false
		while os.clock() - t0 < CFG.PlayerStopWindow and stops[car] == stop do
			local cp = car.PrimaryPart
			if not cp or not target.Parent then break end
			local orr = Core.root(officer)
			if orr and (cp.Position - orr.Position).Magnitude > CFG.EvadeDistance then break end
			if cp.AssemblyLinearVelocity.Magnitude < 3 then
				stopped = true
				break
			end
			-- out of the car = stopped too
			if Core.driver(car) ~= target then stopped = true break end
			task.wait(0.5)
		end
		if stops[car] ~= stop then return end
		if stopped then
			Core.UI.tag(target, "stop", "TRAFFIC STOP - stay in the car")
			Core.UI.notice(officer, (target:GetAttribute("CharacterName") or target.DisplayName) .. " pulled over", 3)
			talkPrompt(stop)
			task.delay(300, function() if stops[car] == stop then finish(stop, "timed out") end end)
		else
			Core.UI.notice(officer, (target:GetAttribute("CharacterName") or target.DisplayName) .. " is not stopping!", 4, Color3.fromRGB(120, 20, 20))
			Core.report(target, "EvadingPolice", car.PrimaryPart and car.PrimaryPart.Position)
			finish(stop, "evading")
		end
	end)
end

function S.init(core: any)
	Core = core
	Core.clientEvent("stop.start", function(player: Player)
		S.start(player)
	end)
	Players.PlayerRemoving:Connect(function(p)
		local s = busyOfficer[p]
		if s then finish(s, "officer left") end
		for _, st in stops do
			if st.target == p then finish(st, "driver left") end
		end
	end)
	Core.Stops = S
	print("[Stop] v278 ready (traffic stops: B / STOP button)")
end

return S
