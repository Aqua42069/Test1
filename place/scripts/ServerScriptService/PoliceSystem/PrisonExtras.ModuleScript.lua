-- PrisonExtras (v212)
-- The expanded prison, driven from PoliceSystem's prison-life block (which
-- hands over a context table of Justice internals in X.init):
--
--   REGIMEN   every class follows the day: cells at Count/Lockdown, the
--             cafeteria at Chow, outdoor yards (Yard A/B) or the indoor yard at
--             Yard, cellblock time at Programs. When the block changes a CO
--             walks to the class, has them LINE UP (NPCs and player inmates) and
--             marches the line to the next place, then back to the cells.
--             Supermax / Death Row: meals in the cell, indoor yard only.
--             High security: indoor yard on alternating days.
--   NPC CELLS each NPC inmate owns a cell of its class; NPCs take at most half
--             of a class's cells so players always have room.
--   SENTENCES NPC inmates have generated charges and sentences; when one is
--             served a CO walks them out of the prison and they're released.
--   SOLITARY  fights (PrisonSociety -> ServerStorage.PrisonDiscipline) send the
--             inmate - player or NPC - to a solitary cell for a while.
--   EXECUTION a death row inmate is walked to an execution room, picks gas,
--             the electric chair or lethal injection, and an executioner carries
--             it out - broadcast LIVE on C-SPAN with a camera in the room. Any
--             viewer can pay $50,000,000 for a governor's pardon.
--   VISITS    visitors request a visit in the phone's Visits app (inmates with a
--             10+ minute sentence, visiting hours 08:00-20:00). A cruiser drives
--             the visitor to the prison and back; the inmate is escorted to the
--             matching visiting room. Contact visits can smuggle an item in -
--             a quick-time event, with a chance of getting caught.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

local X: any = {}
local C: any = nil

---------------------------------------------------------------------------
-- config
---------------------------------------------------------------------------
X.CELL_CATEGORY = {
	Low = "LowSecurity",
	Medium = "MediumSecurity",
	High = "HighSecurity",
	Maximum = "MaximumSecurity",
	Supermax = "Supermax",
	["Death Row"] = "DeathRow",
}
X.BLOCK_AREA = {
	Low = "LOW_SECURITY",
	Medium = "MEDIUM_SECURITY",
	High = "MAXIMUM_SECURITY",
	Maximum = "MAXIMUM_SECURITY",
	Supermax = "SUPERMAX",
	["Death Row"] = "DEATH_ROW",
}
X.CLASSES = { "Low", "Medium", "High", "Maximum", "Supermax", "Death Row" }
X.NPC_COUNT = { Low = 8, Medium = 10, High = 3, Maximum = 3, Supermax = 4, ["Death Row"] = 1 }
X.START_FILL = 0.5 -- the rest arrive through intake (city arrests)
-- v215: a mixed prison at server start (the rest arrive through intake)
X.START = { Low = 5, Medium = 5, High = 2, Maximum = 1, Supermax = 2, ["Death Row"] = 1 }
X.START_SOLITARY = { 1, 2 } -- this many of them begin in solitary
-- intake leans towards the general population
X.ARREST_WEIGHT = { Low = 1.6, Medium = 1.4, High = 0.8, Maximum = 0.5, Supermax = 0.4, ["Death Row"] = 0.15 } -- share of NPC_COUNT spawned at server start; arrests bring in the rest
-- v226: NPC terms are at least 30 minutes so the population sticks around; the
-- inmates already inside when a server starts are part-way through theirs (see
-- X.seeding) so releases and new arrivals flow from the first minutes.
X.SENTENCE = {
	Low = { 1800, 2700 },
	Medium = { 2100, 3600 },
	High = { 2700, 4800 },
	Maximum = { 3600, 6000 },
	Supermax = { 5400, 9000 },
	["Death Row"] = { 1800, 3600 },
}
X.MIN_SENTENCE = 1800
X.seeding = false
X.CHARGES = {
	Low = { "Petty theft", "Trespassing", "Vandalism", "Disorderly conduct", "Shoplifting", "Driving without a license",
		"Public intoxication", "Loitering", "Jaywalking", "Illegal gambling", "Counterfeit casino chips", "Noise violation" },
	Medium = { "Burglary", "Grand theft auto", "Drug possession", "Assault", "Resisting arrest", "Fraud", "Identity theft",
		"Card counting fraud", "Receiving stolen property", "DUI", "Reckless driving", "Possession of a firearm" },
	High = { "Armed robbery", "Drug trafficking", "Aggravated assault", "Carjacking", "Racketeering", "Extortion",
		"Casino heist", "Arms dealing" },
	Maximum = { "Bank robbery", "Attempted murder", "Kidnapping", "Arson", "Manslaughter", "Human trafficking" },
	Supermax = { "Murder of a police officer", "Prison escape", "Organized crime", "Terrorism", "Serial armed robbery" },
	["Death Row"] = { "Capital murder", "Multiple homicide", "Murder of a police officer" },
}
-- who defends an NPC: mostly the public defender (price tiers match player counsel)
X.COUNSEL = {
	{ "Public Defender", 55, 0.08 },
	{ "Local Attorney", 20, 0.16 },
	{ "Experienced Defense Counsel", 12, 0.25 },
	{ "Criminal Defense Firm", 7, 0.36 },
	{ "Elite Defense Team", 4, 0.48 },
	{ "National Trial Firm", 1.5, 0.60 },
	{ "Premier Counsel", 0.5, 0.72 },
}
X.SOLITARY_SECS = 150
X.PARDON_PRICE = 50000000
X.PARDON_WINDOW = 35
X.VISIT_MIN_SENTENCE = 600
X.VISIT_HOURS = { 8, 20 }
X.VISIT_SECS = 120
X.SMUGGLE_CAUGHT = 0.18

---------------------------------------------------------------------------
-- remotes
---------------------------------------------------------------------------
local remotes = ReplicatedStorage:FindFirstChild("PrisonExtras") or Instance.new("Folder")
remotes.Name = "PrisonExtras"
remotes.Parent = ReplicatedStorage
local function remote(className: string, name: string): any
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new(className)
		r.Name = name
		r.Parent = remotes
	end
	return r
end
local ExecRE = remote("RemoteEvent", "Execution")
local VisitRE = remote("RemoteEvent", "Visit")
local VisitRF = remote("RemoteFunction", "VisitQuery")

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------
local function pick<T>(list: { T }): T
	return list[math.random(1, #list)]
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function notice(player: Player, text: string)
	pcall(C.tell, player, "Notice", text)
end

local function economy(action: string, player: Player, amount: number?): any
	local fn = ServerStorage:FindFirstChild("Economy")
	if not fn then
		return nil
	end
	local ok, result = pcall(fn.Invoke, fn, action, player, amount)
	return ok and result
end

local function pretty(loc: string): string
	if loc == "CAFETERIA" then
		return "cafeteria"
	elseif loc == "YARD" then
		return "yard"
	elseif loc == "INDOOR_YARD" then
		return "indoor yard"
	elseif loc == "CELL" then
		return "cells"
	end
	return "cellblock"
end

-- v229: PrisonSociety's riot state (a riot pauses the schedule and the CO sweep;
-- afterwards the whole facility is locked down for a while)
function X.society(): Instance?
	return ReplicatedStorage:FindFirstChild("PrisonSociety")
end
function X.riotActive(): boolean
	local f = X.society()
	return f ~= nil and f:GetAttribute("Riot") == true
end

function X.block(): string
	local f = X.society()
	if f and (tonumber(f:GetAttribute("RiotLockdownUntil")) or 0) > os.time() then
		return "Lockdown"
	end
	local hour = Lighting.ClockTime
	for _, b in C.Config.PrisonSchedule.Blocks do
		if hour >= b.Start and hour < b.Finish then
			return b.Name
		end
	end
	return "Lockdown"
end

function X.highIndoors(): boolean
	return math.floor(os.time() / 1200) % 2 == 0
end

-- where a class should be during a schedule block
function X.locationFor(class: string, block: string): string
	-- Death Row is like solitary: the door never opens on the schedule
	if block == "Lockdown" or block == "Count" or class == "Death Row" then
		return "CELL"
	end
	local restricted = class == "Supermax" or class == "Death Row"
	if block == "Chow" then
		return if restricted then "CELL" else "CAFETERIA"
	end
	if block == "Yard" then
		if restricted then
			return "INDOOR_YARD"
		end
		if class == "High" and X.highIndoors() then
			return "INDOOR_YARD"
		end
		return "YARD"
	end
	-- Programs: cellblock time for the general population only
	if class == "Low" or class == "Medium" then
		return "BLOCK"
	end
	return "CELL"
end

function X.areaFor(class: string, loc: string): string?
	if loc == "BLOCK" or loc == "CELL" then
		return X.BLOCK_AREA[class]
	end
	return loc
end

function X.pointIn(class: string, loc: string): Vector3?
	local area = X.areaFor(class, loc)
	local p = area and C.PrisonNav.patrolStart(area)
	if not p and loc ~= "BLOCK" then
		local blockArea = X.BLOCK_AREA[class]
		p = blockArea and C.PrisonNav.patrolStart(blockArea)
	end
	return p
end

---------------------------------------------------------------------------
-- rooms from the mapped cell pairs
---------------------------------------------------------------------------
function X.rooms(category: string): { any }
	local list = {}
	local map = C.PrisonNav.mapRoot
	local zones = map and map:FindFirstChild("Zones")
	local doors = map and map:FindFirstChild("DoorMarkers")
	if not zones or not doors then
		return list
	end
	for name, pair in C.PrisonNav.CellPairs do
		if pair.category == category then
			local cell = zones:FindFirstChild(name)
			local door = doors:FindFirstChild(pair.door)
			if cell and door then
				table.insert(list, {
					cell = cell,
					door = door,
					outer = pair.outer and doors:FindFirstChild(pair.outer) or nil,
					pos = pair.pos,
					name = name,
					category = category,
					open = pair.open == true,
					capacity = pair.capacity or 1,
				})
			end
		end
	end
	table.sort(list, function(a, b)
		local an = tonumber(a.name:match("_(%d+)$")) or 1
		local bn = tonumber(b.name:match("_(%d+)$")) or 1
		if an ~= bn then
			return an < bn
		end
		return a.name < b.name
	end)
	return list
end

local function playerOccupied(cell: Instance): boolean
	for plr, c in C.housingAssignment do
		if c == cell and plr.Parent then
			return true
		end
	end
	for plr, room in C.PrisonFlow.rooms do
		if room.cell == cell and plr.Parent then
			return true
		end
	end
	for plr, room in C.PrisonFlow.reserved do
		if room.cell == cell and plr.Parent then
			return true
		end
	end
	return false
end

local function npcCount(cell: Instance): number
	return tonumber(cell:GetAttribute("NPCResident")) or 0
end

local function setNpcCount(cell: Instance, n: number)
	cell:SetAttribute("NPCResident", if n > 0 then n else nil)
end

-- a cell of this class for an NPC; NPCs never take more than half the cells
function X.claimCell(class: string): any?
	local rooms = X.rooms(X.CELL_CATEGORY[class] or "")
	if #rooms == 0 then
		return nil
	end
	local maxCells = math.max(1, math.floor(#rooms / 2))
	local used = 0
	for _, r in rooms do
		if npcCount(r.cell) > 0 then
			used += 1
		end
	end
	-- share an open (dorm) cell first
	for _, r in rooms do
		local n = npcCount(r.cell)
		if n > 0 and r.open and n < math.min(3, r.capacity) then
			setNpcCount(r.cell, n + 1)
			return r
		end
	end
	if used >= maxCells then
		return nil
	end
	for i = #rooms, 1, -1 do -- from the back, away from where players are housed first
		local r = rooms[i]
		if npcCount(r.cell) == 0 and not playerOccupied(r.cell) then
			setNpcCount(r.cell, 1)
			return r
		end
	end
	return nil
end

function X.releaseCell(room: any?)
	if room and room.cell then
		setNpcCount(room.cell, npcCount(room.cell) - 1)
	end
end

-- a free single room (solitary / execution / visiting) for an NPC
function X.freeRoom(category: string): any?
	for _, r in X.rooms(category) do
		if npcCount(r.cell) == 0 and not playerOccupied(r.cell) and not r.cell:GetAttribute("RoomBusy") then
			return r
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- NPC inmates
---------------------------------------------------------------------------
X.npcs = {} :: { [Model]: any }
X.classLoc = {} :: { [string]: string }
X.moving = {} :: { [string]: boolean }

local function recAlive(rec: any): boolean
	return rec.hum.Health > 0 and not rec.gone and (rec.model.Parent ~= nil or rec.hidden == true)
end

local function busy(rec: any): boolean
	local m = rec.model
	return m:GetAttribute("SocietyBusy") == true or m:GetAttribute("Solitary") == true or m:GetAttribute("LineUp") == true
		or m:GetAttribute("Executing") == true
end

local function inCellNow(rec: any): boolean
	return rec.room ~= nil and C.PrisonNav.isInsideCell(rec.room, rec.root.Position)
end

function X.enterCell(rec: any)
	local room = rec.room
	if not room then
		return
	end
	rec.model:SetAttribute("InCell", true)
	if room.outer then
		C.openMarkedDoor(room.outer, 20)
	end
	local outside = C.PrisonFlow.approach(room)
	if not room.open then
		C.openMarkedDoor(room.door, 12)
	end
	if flat(rec.root.Position - outside).Magnitude > 4 and not inCellNow(rec) then
		if not C.PL.walk(rec.model, rec.hum, rec.root, outside, 25) and flat(rec.root.Position - outside).Magnitude > 8 then
			rec.model:PivotTo(CFrame.new(outside + Vector3.new(0, 3, 0))) -- a CO walks them in
		end
	end
	if not room.open then
		C.openMarkedDoor(room.door, 8)
	end
	C.PL.walk(rec.model, rec.hum, rec.root, room.pos, 8)
	if not inCellNow(rec) then
		rec.model:PivotTo(CFrame.new(room.pos + Vector3.new(0, 3, 0)))
	end
	rec.inCell = true
	if not room.open then
		task.wait(0.5)
		pcall(C.PrisonFlow.closeCell, room)
	end
end

function X.leaveCell(rec: any)
	local room = rec.room
	rec.model:SetAttribute("InCell", nil)
	rec.inCell = false
	if not room then
		return
	end
	if not room.open then
		C.openMarkedDoor(room.door, 10)
	end
	if room.outer then
		C.openMarkedDoor(room.outer, 14)
	end
	local outside = C.PrisonFlow.approach(room)
	if not C.PL.walk(rec.model, rec.hum, rec.root, outside, 12) and flat(rec.root.Position - outside).Magnitude > 8 then
		rec.model:PivotTo(CFrame.new(outside + Vector3.new(0, 3, 0)))
	end
end

function X.life(rec: any)
	local model, hum, root = rec.model, rec.hum, rec.root
	while recAlive(rec) and C.prison and C.prison.Parent do
		if busy(rec) then
			task.wait(1)
			continue
		end
		-- sentence served: walked out
		if rec.sentenceEnd and os.time() >= rec.sentenceEnd then
			if rec.class == "Death Row" then
				rec.sentenceEnd = nil
				task.spawn(X.executeNpc, rec)
			else
				X.releaseNpc(rec)
				return
			end
			continue
		end
		local want = X.classLoc[rec.class] or X.locationFor(rec.class, X.block())
		if want == "CELL" then
			if not rec.inCell then
				X.enterCell(rec)
			end
			if hum.Sit then
				hum.Sit = false
			end
			task.wait(3)
		else
			if rec.inCell then
				X.leaveCell(rec)
			end
			local pt = X.pointIn(rec.class, want)
			if pt then
				if flat(pt - root.Position).Magnitude > 220 then
					-- a straggler (new arrival, back from solitary): a CO brings them over
					model:PivotTo(CFrame.new(pt + Vector3.new(0, 3, 0)))
				else
					C.PL.walk(model, hum, root, pt, 20)
				end
			end
			local rest = os.clock() + math.random(3, 10)
			while os.clock() < rest and not busy(rec) do
				if hum.Sit or hum.SeatPart then
					hum.Sit = false
					hum.Jump = true
				end
				task.wait(0.5)
			end
		end
	end
	X.forget(rec)
end

function X.forget(rec: any)
	if X.npcs[rec.model] then
		X.npcs[rec.model] = nil
		X.releaseCell(rec.room)
	end
end

local function pickCounsel(): (string, number)
	local total = 0
	for _, c in X.COUNSEL do
		total += c[2]
	end
	local roll = math.random() * total
	for _, c in X.COUNSEL do
		roll -= c[2]
		if roll <= 0 then
			return c[1], c[3]
		end
	end
	return X.COUNSEL[1][1], X.COUNSEL[1][3]
end

local function sentenceFor(class: string): (number, string, string)
	local range = X.SENTENCE[class] or { 300, 600 }
	local secs = math.random(range[1], range[2])
	local charges = X.CHARGES[class] or X.CHARGES.Low
	local list = { pick(charges) }
	-- sometimes a second charge, sometimes one from the class below
	if math.random() < 0.35 then
		local second = pick(charges)
		if second ~= list[1] then
			table.insert(list, second)
		end
	end
	if math.random() < 0.2 then
		local lower = X.CHARGES.Low
		local extra = pick(lower)
		if not table.find(list, extra) then
			table.insert(list, extra)
		end
	end
	-- better counsel, shorter sentence (death row stays death row)
	local counsel, quality = pickCounsel()
	if class ~= "Death Row" then
		secs = math.floor(secs * (1 - quality * (0.3 + math.random() * 0.5)))
	end
	return math.max(X.MIN_SENTENCE, secs), table.concat(list, ", "), counsel
end

-- take over an NPC that is already in the prison (spawned here or arrived via intake)
function X.adopt(npc: Model, hum: Humanoid, root: BasePart, class: string): boolean
	local room = X.claimCell(class)
	if not room then
		return false
	end
	local secs, charges, counsel = sentenceFor(class)
	if X.seeding then
		-- already inside when the server started: somewhere in the middle of the term
		secs = math.max(60, math.floor(secs * (0.02 + (math.random() ^ 1.3) * 0.98)))
	end
	local rec = {
		model = npc,
		hum = hum,
		root = root,
		class = class,
		room = room,
		inCell = false,
		sentenceEnd = os.time() + secs,
		charges = charges,
	}
	npc:SetAttribute("PrisonNPCInmate", class)
	npc:SetAttribute("Charges", charges)
	npc:SetAttribute("Counsel", counsel)
	npc:SetAttribute("SentenceEnd", rec.sentenceEnd)
	print(("[PrisonExtras] NPC %s sentenced: %s | %s | %s | %d:%02d"):format(npc.Name, class, charges, counsel, secs // 60, secs % 60))
	C.PL.npcLabel(npc, ("%s · %d min · %s"):format(charges, math.max(1, secs // 60), counsel))
	task.delay(25, function()
		local head = npc:FindFirstChild("Head")
		local gui = head and head:FindFirstChild("NpcCustodyLabel")
		if gui then
			gui:Destroy()
		end
	end)
	npc:SetAttribute("AssignedCell", room.name)
	room.cell:SetAttribute("NPCName", npc.Name)
	X.npcs[npc] = rec
	hum.Died:Connect(function()
		X.forget(rec)
		task.delay(8, function()
			if npc.Parent then
				npc:Destroy()
			end
		end)
	end)
	X.life(rec)
	return true
end

function X.spawnInmate(class: string): boolean
	local npc, hum, root = C.PL.makeInmateNpc(class)
	if not npc or not hum or not root then
		return false
	end
	local loc = X.classLoc[class] or X.locationFor(class, X.block())
	local start = X.pointIn(class, loc)
	if loc == "CELL" then
		local room = X.claimCell(class)
		if not room then
			npc:Destroy()
			return false
		end
		X.releaseCell(room) -- adopt claims it again
		start = room.pos
	end
	if not start then
		npc:Destroy()
		return false
	end
	npc:PivotTo(CFrame.new(start + Vector3.new(0, 3, 0)))
	npc.Parent = C.PL.prisonNpcFolder()
	if C.inmateClothes[class] then
		pcall(C.PrisonFlow.wearUniform, npc, C.inmateClothes[class])
	end
	C.PL.prisonNpcCollision(npc)
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	task.spawn(function()
		if not X.adopt(npc, hum, root, class) then
			npc:Destroy()
		end
	end)
	return true
end

function X.population(class: string): number
	local n = 0
	for _, rec in X.npcs do
		if rec.class == class and recAlive(rec) then
			n += 1
		end
	end
	return n
end

-- classes that still have room, weighted by how many are missing
function X.rollArrestClass(): string?
	local pool, total = {}, 0
	for _, class in X.CLASSES do
		local missing = (X.NPC_COUNT[class] or 0) - X.population(class)
		if missing > 0 then
			local w = missing * (X.ARREST_WEIGHT[class] or 1)
			total += w
			table.insert(pool, { class, w })
		end
	end
	if total == 0 then
		return nil
	end
	local roll = math.random() * total
	for _, e in pool do
		roll -= e[2]
		if roll <= 0 then
			return e[1]
		end
	end
	return pool[#pool][1]
end

-- sentence served: a CO walks them to the release exit and out
function X.releaseNpc(rec: any)
	rec.model:SetAttribute("LineUp", true)
	if rec.inCell then
		X.leaveCell(rec)
	end
	local inside, outside = C.prisonExit()
	local cop = C.nameEscort(C.escortCop(rec.root.Position + Vector3.new(3, 0, 0), Vector3.zAxis), "RELEASE OFFICER")
	C.PL.npcLabel(rec.model, "RELEASED")
	if cop then
		C.PL.npcEscortTo(cop, rec.model, inside, "NPC RELEASE")
		C.openPrisonDoorsNear(inside, 30, 20)
		C.PL.npcEscortTo(cop, rec.model, outside, "NPC RELEASE OUT")
		cop:despawn("npc released")
	end
	print(("[PrisonExtras] NPC %s released after serving: %s"):format(rec.model.Name, tostring(rec.charges)))
	rec.gone = true
	X.forget(rec)
	C.PL.walk(rec.model, rec.hum, rec.root, outside + Vector3.new(math.random(-20, 20), 0, math.random(10, 30)), 12)
	task.wait(4)
	if rec.model.Parent then
		rec.model:Destroy()
	end
end

---------------------------------------------------------------------------
-- line-ups: a CO moves a whole class to the next place
---------------------------------------------------------------------------
local function classPlayers(class: string): { Player }
	local out = {}
	for _, plr in Players:GetPlayers() do
		if plr:GetAttribute("CustodyOwner") == "INCARCERATED" and plr:GetAttribute("SecurityClass") == class
			and C.sentenceEnd[plr] and not C.releaseBusy[plr] and not plr:GetAttribute("Solitary")
			and not plr:GetAttribute("Visiting") and not plr:GetAttribute("DeathRowExecutionStarted") then
			table.insert(out, plr)
		end
	end
	return out
end

local function setLabel(cop: any, text: string)
	local label = cop.model and cop.model:FindFirstChild("PrisonRoleLabel", true)
	local t = label and label:FindFirstChildOfClass("TextLabel")
	if t then
		t.Text = text
	end
end

-- v227: inmates can walk away from a CO - it just costs them. Losing the CO's
-- respect, a strike, and a second strike within 4 minutes is solitary.
X.brokeAway = {} :: { [Player]: boolean }
function X.walkedAway(plr: Player, what: string)
	local r = tonumber(plr:GetAttribute("CORespect")) or 0
	plr:SetAttribute("CORespect", math.clamp(r - 12, -100, 100))
	local strike = X.strikes and X.strikes[plr]
	if strike and os.clock() - strike.at > 240 then
		strike = nil
	end
	strike = { n = (strike and strike.n or 0) + 1, at = os.clock() }
	X.strikes[plr] = strike
	print(("[PrisonExtras] %s walked away from %s (strike %d)"):format(plr.Name, what, strike.n))
	if strike.n >= 2 then
		X.strikes[plr] = nil
		notice(plr, "You walked away from a CO again - you're going to SOLITARY")
		task.spawn(X.solitaryPlayer, plr, "ignoring a correctional officer")
	else
		notice(plr, ("You walked away from %s. COs -12 respect - do it again and it's solitary."):format(what))
	end
end

function X.moveClass(class: string, from: string?, to: string)
	local members = {}
	for _, rec in X.npcs do
		if rec.class == class and recAlive(rec) and rec.model.Parent and not busy(rec) then
			table.insert(members, rec)
		end
	end
	local plist = classPlayers(class)
	if #members == 0 and #plist == 0 then
		X.classLoc[class] = to
		return
	end
	for _, rec in members do
		rec.model:SetAttribute("LineUp", true)
	end
	-- v239: players being walked by a CO can't sit down on the way
	for _, plr in plist do
		plr:SetAttribute("NoSit", true)
	end
	local ok, err = pcall(function()
		local fromLoc = from or "CELL"
		local gather = X.pointIn(class, if fromLoc == "CELL" then "BLOCK" else fromLoc)
			or (members[1] and members[1].root.Position)
		if not gather then
			return
		end
		local cop = C.nameEscort(C.escortCop(gather, Vector3.zAxis), "CORRECTIONAL OFFICER")
		if not cop then
			return
		end
		cop.cfg.WalkSpeed = 7
		setLabel(cop, "LINE UP!")
		for _, plr in plist do
			notice(plr, ("LINE UP - %s security to the %s. Follow the officer."):format(class, pretty(to)))
			local room = C.PL.playerRoom(plr)
			if room and not room.open then
				C.openMarkedDoor(room.door, 20)
			end
		end
		-- out of the cells and into a line behind the CO
		for _, rec in members do
			if rec.inCell then
				task.spawn(X.leaveCell, rec)
			end
		end
		local lineUntil = os.clock() + 14
		while os.clock() < lineUntil and cop.alive do
			local ready = 0
			local back = -cop.root.CFrame.LookVector
			for i, rec in members do
				local slot = cop.root.Position + back * (3 + 2.4 * i)
				if flat(rec.root.Position - slot).Magnitude < 4 then
					ready += 1
				else
					rec.hum:MoveTo(slot)
					C.openPrisonDoorsNear(rec.root.Position, 8, 4)
				end
			end
			-- v215: player inmates are walked into the line as well
			for j, plr in plist do
				local _, hum, root = C.Util.charInfo(plr)
				if hum and root then
					local slot = cop.root.Position + back * (3 + 2.4 * (#members + j))
					if flat(root.Position - slot).Magnitude < 5 then
						ready += 1
					else
						hum:MoveTo(slot)
						C.openPrisonDoorsNear(root.Position, 8, 4)
					end
				end
			end
			if ready >= #members + #plist then
				break
			end
			task.wait(0.4)
		end
		-- march
		local dest = if to == "CELL" then X.pointIn(class, "BLOCK") else X.pointIn(class, to)
		if not dest then
			cop:despawn("line-up: no destination")
			return
		end
		setLabel(cop, "CORRECTIONAL OFFICER")
		local trail = { cop.root.Position }
		local done = false
		task.spawn(function()
			pcall(function()
				C.PrisonNav.travel(cop, dest, { alive = function()
					return cop.alive and not done
				end, maxTime = 120, label = "LINE UP " .. string.upper(class) })
			end)
			done = true
		end)
		local deadline = os.clock() + 130
		local stuckSince: { [any]: number } = {}
		while not done and os.clock() < deadline and cop.alive do
			local head = cop.root.Position
			if (trail[#trail] - head).Magnitude > 1.5 then
				table.insert(trail, head)
			end
			local slot = 0
			for _, rec in members do
				if not recAlive(rec) or not rec.model.Parent then
					continue
				end
				slot += 1
				local target = trail[math.max(1, #trail - slot * 2)]
				local d = flat(rec.root.Position - target).Magnitude
				rec.hum:MoveTo(target)
				C.openPrisonDoorsNear(rec.root.Position, 8, 4)
				if d > 6 then
					stuckSince[rec] = stuckSince[rec] or os.clock()
					if os.clock() - stuckSince[rec] > 6 or d > 30 then
						rec.model:PivotTo(CFrame.new(target + Vector3.new(0, 3, 0)))
						stuckSince[rec] = nil
					end
				else
					stuckSince[rec] = nil
				end
			end
			-- v215: the CO takes player inmates along too: they're walked in line and a
			-- straggler who wanders off is brought back into the column
			for _, plr in plist do
				local _, hum, root = C.Util.charInfo(plr)
				if hum and root and plr:GetAttribute("CustodyOwner") == "INCARCERATED" and not X.brokeAway[plr] then
					slot += 1
					local target = trail[math.max(1, #trail - slot * 2)]
					local d = flat(root.Position - target).Magnitude
					if hum.Sit or hum.SeatPart then
						hum.Sit = false -- v227: never left stuck in a cafeteria seat
						hum.Jump = true
					end
					if d > 28 then
						-- v227: walked off - free to go, with consequences
						X.brokeAway[plr] = true
						stuckSince[plr] = nil
						X.walkedAway(plr, "the line-up")
					elseif d > 5 then
						hum:MoveTo(target)
						stuckSince[plr] = stuckSince[plr] or os.clock()
						if os.clock() - stuckSince[plr] > 8 then
							-- physically stuck (a seat, a table corner) - the CO pulls them along
							root.CFrame = CFrame.new(target + Vector3.new(0, 3, 0))
							stuckSince[plr] = nil
							notice(plr, "Stay in line")
						end
					else
						stuckSince[plr] = nil
					end
					C.openPrisonDoorsNear(root.Position, 8, 4)
				end
			end
			task.wait(0.3)
		end
		for _, rec in members do
			if rec.model.Parent and flat(rec.root.Position - dest).Magnitude > 45 then
				rec.model:PivotTo(CFrame.new(dest + Vector3.new(math.random(-6, 6), 3, math.random(-6, 6))))
			end
		end
		for _, plr in plist do
			local _, hum, root = C.Util.charInfo(plr)
			if X.brokeAway[plr] then
				X.brokeAway[plr] = nil
				continue -- they walked off; the CO sweep deals with them now
			end
			if to == "CELL" then
				-- walked back into their own cell and locked in
				local room = C.PL.playerRoom(plr)
				if room and hum and root then
					notice(plr, "Lockdown - back in your cell")
					task.spawn(function()
						if not room.open then
							C.openMarkedDoor(room.door, 16)
						end
						local t0 = os.clock()
						while os.clock() - t0 < 12 and not C.PrisonNav.isInsideCell(room, root.Position) do
							hum:MoveTo(room.pos)
							task.wait(0.4)
						end
						if not C.PrisonNav.isInsideCell(room, root.Position) then
							root.CFrame = CFrame.new(room.pos + Vector3.new(0, 3, 0))
						end
						task.wait(0.5)
						if not room.open then
							pcall(C.PrisonFlow.closeCell, room)
						end
						C.PL.freeState[plr] = nil
					end)
				end
			else
				if root and flat(root.Position - dest).Magnitude > 45 then
					root.CFrame = CFrame.new(dest + Vector3.new(math.random(-5, 5), 3, math.random(-5, 5)))
				end
				notice(plr, ("%s time in the %s"):format(if to == "CAFETERIA" then "Chow" else "Free", pretty(to)))
			end
		end
		cop:despawn("line-up complete")
	end)
	if not ok then
		warn("[PrisonExtras] line-up " .. class .. ": " .. tostring(err))
	end
	X.classLoc[class] = to
	for _, rec in members do
		if rec.model.Parent then
			rec.model:SetAttribute("LineUp", nil)
		end
	end
	for _, plr in plist do
		if plr.Parent then
			plr:SetAttribute("NoSit", nil)
		end
	end
end

-- v215: each class's day, published for the prisoners' schedule panel
function X.publishSchedule()
	local HttpService = game:GetService("HttpService")
	local blocks = table.clone(C.Config.PrisonSchedule.Blocks)
	table.sort(blocks, function(a, b)
		return a.Start < b.Start
	end)
	for _, class in X.CLASSES do
		local rows = {}
		for _, b in blocks do
			local loc = X.locationFor(class, b.Name)
			local where = pretty(loc)
			if b.Name == "Yard" and class == "High" then
				where = "yard / indoor yard (alternating)"
			elseif loc == "CELL" then
				where = if b.Name == "Chow" then "meal in your cell" elseif b.Name == "Count" then "count - in your cell" else "in your cell"
			elseif loc == "BLOCK" then
				where = "cellblock time"
			end
			table.insert(rows, { s = b.Start, f = b.Finish, b = b.Name, w = where })
		end
		local ok, json = pcall(HttpService.JSONEncode, HttpService, rows)
		if ok then
			pcall(remotes.SetAttribute, remotes, "Regimen_" .. (string.gsub(class, "%W", "")), json)
		end
	end
end

function X.startRegimen()
	X.publishSchedule()
	local block = X.block()
	for _, class in X.CLASSES do
		X.classLoc[class] = X.locationFor(class, block)
	end
	task.spawn(function()
		while C.prison and C.prison.Parent do
			task.wait(5)
			if X.riotActive() then
				continue
			end
			local now = X.block()
			for i, class in X.CLASSES do
				local want = X.locationFor(class, now)
				if X.classLoc[class] ~= want and not X.moving[class] then
					X.moving[class] = true
					local from = X.classLoc[class]
					task.delay((i - 1) * 6, function()
						local ok, err = pcall(X.moveClass, class, from, want)
						if not ok then
							warn("[PrisonExtras] regimen: " .. tostring(err))
							X.classLoc[class] = want
						end
						X.moving[class] = nil
					end)
				end
			end
		end
	end)
end

function X.startPopulation()
	task.spawn(function()
		task.wait(5)
		-- interleave the classes so the first arrivals are already a mix
		local left = table.clone(X.START)
		local any = true
		X.seeding = true
		while any do
			any = false
			for _, class in X.CLASSES do
				if (left[class] or 0) > 0 then
					left[class] -= 1
					any = true
					pcall(X.spawnInmate, class)
					task.wait(0.6)
				end
			end
		end
		X.seeding = false
		-- one or two start the day in solitary
		task.delay(20, function()
			local pool = {}
			for _, rec in X.npcs do
				if (rec.class == "Low" or rec.class == "Medium" or rec.class == "High") and recAlive(rec) then
					table.insert(pool, rec)
				end
			end
			local n = math.random(X.START_SOLITARY[1], X.START_SOLITARY[2])
			for _ = 1, math.min(n, #pool) do
				local i = math.random(1, #pool)
				local rec = table.remove(pool, i)
				task.spawn(X.solitaryNpc, rec, "serving a solitary term")
			end
		end)
		local counts = {}
		for _, class in X.CLASSES do
			table.insert(counts, class .. "=" .. X.population(class))
		end
		print("[PrisonExtras] NPC inmates online: " .. table.concat(counts, " "))
	end)
end

---------------------------------------------------------------------------
-- solitary
---------------------------------------------------------------------------
X.inSolitary = {} :: { [any]: boolean }

-- v290: pc = protective custody - the same isolation cells, but for his safety, not punishment
function X.solitaryPlayer(player: Player, reason: string, pc: boolean?)
	if X.inSolitary[player] then
		return
	end
	if player:GetAttribute("CustodyOwner") ~= "INCARCERATED" or not C.sentenceEnd[player] or C.releaseBusy[player] then
		return
	end
	local class = tostring(player:GetAttribute("SecurityClass") or "")
	if class == "Death Row" or player:GetAttribute("Visiting") then
		return
	end
	X.inSolitary[player] = true
	C.custody[player] = true
	local room = C.PrisonFlow.pick(player, "Solitary")
	if not room then
		C.custody[player] = nil
		X.inSolitary[player] = nil
		return
	end
	player:SetAttribute("Solitary", true)
	notice(player, (if pc then "PROTECTIVE CUSTODY - " else "SOLITARY CONFINEMENT - ") .. reason)
	print(("[PrisonExtras] %s %s -> %s (%s)"):format(if pc then "PROTECTIVE CUSTODY" else "SOLITARY", player.Name, room.name, reason))
	local delivered = C.PrisonFlow.deliver(player, "CORRECTIONAL OFFICER", room, "HOUSING_ESCORT")
	if delivered then
		C.housingAssignment[player] = room.cell
		player:SetAttribute("AssignedCell", room.name)
	end
	C.custody[player] = nil
	local untilT = os.time() + X.SOLITARY_SECS
	player:SetAttribute("SolitaryUntil", untilT)
	while player.Parent and os.time() < untilT and C.sentenceEnd[player] and not C.releaseBusy[player] do
		task.wait(2)
	end
	player:SetAttribute("SolitaryUntil", nil)
	if player.Parent and C.sentenceEnd[player] and not C.releaseBusy[player] then
		-- back to general housing
		C.custody[player] = true
		local back = C.PrisonFlow.pick(player, C.PrisonFlow.categoryFor(class))
		if back then
			notice(player, "Solitary is over - returning to your cellblock")
			if C.PrisonFlow.deliver(player, "CORRECTIONAL OFFICER", back, "HOUSING_ESCORT") then
				C.housingAssignment[player] = back.cell
				player:SetAttribute("AssignedCell", back.name)
			end
		end
		C.custody[player] = nil
	end
	player:SetAttribute("Solitary", nil)
	X.inSolitary[player] = nil
end

function X.solitaryNpc(rec: any, reason: string)
	if X.inSolitary[rec] or not recAlive(rec) or rec.class == "Death Row" then
		return
	end
	local room = X.freeRoom("Solitary")
	if not room then
		return
	end
	X.inSolitary[rec] = true
	room.cell:SetAttribute("RoomBusy", true)
	local model = rec.model
	model:SetAttribute("Solitary", true)
	local cop = C.nameEscort(C.escortCop(rec.root.Position + Vector3.new(3, 0, 0), Vector3.zAxis), "CORRECTIONAL OFFICER")
	C.PL.npcLabel(model, "TO SOLITARY")
	if cop then
		C.PL.npcEscortTo(cop, model, C.PrisonFlow.approach(room), "NPC SOLITARY")
	end
	C.openMarkedDoor(room.door, 8)
	C.PL.walk(model, rec.hum, rec.root, room.pos, 8)
	if not C.PrisonNav.isInsideCell(room, rec.root.Position) then
		model:PivotTo(CFrame.new(room.pos + Vector3.new(0, 3, 0)))
	end
	task.wait(0.5)
	pcall(C.PrisonFlow.closeCell, room)
	if cop then
		cop:despawn("npc in solitary")
	end
	local gui = model:FindFirstChild("Head") and model.Head:FindFirstChild("NpcCustodyLabel")
	if gui then
		gui:Destroy()
	end
	print(("[PrisonExtras] SOLITARY npc %s -> %s (%s)"):format(model.Name, room.name, reason))
	task.wait(X.SOLITARY_SECS * 0.8)
	if recAlive(rec) then
		C.openMarkedDoor(room.door, 10)
		C.PL.walk(model, rec.hum, rec.root, C.PrisonFlow.approach(room), 10)
		model:SetAttribute("Solitary", nil)
	end
	room.cell:SetAttribute("RoomBusy", nil)
	X.inSolitary[rec] = nil
end

function X.discipline(target: any, reason: any): boolean
	local why = if type(reason) == "string" then reason else "fighting"
	if typeof(target) == "Instance" and target:IsA("Player") then
		-- v288: on the record (Classification: write-ups, reviews, charges)
		local ev = ServerStorage:FindFirstChild("PrisonWriteUp")
		if ev and ev:IsA("BindableEvent") and why ~= "a crime committed inside the prison" then ev:Fire(target, why) end
		-- v288l: violence is answered by COs who fight like police (subdue, cuff -> the arrest
		-- sends you to solitary); only when no CO can come is it straight to the hole
		local engage = ServerStorage:FindFirstChild("PrisonCOEngage")
		if engage and engage:IsA("BindableFunction") and not X.inSolitary[target] then
			local ok, res = pcall(engage.Invoke, engage, target, why)
			if ok and res == true then return true end
		end
		task.spawn(X.solitaryPlayer, target, why)
		return true
	elseif typeof(target) == "Instance" and target:IsA("Model") and X.npcs[target] then
		task.spawn(X.solitaryNpc, X.npcs[target], why)
		return true
	end
	return false
end


---------------------------------------------------------------------------
-- v220 CO SWEEP: an inmate (player or NPC) caught somewhere they shouldn't be
-- for the current schedule block is walked back by a CO. Players who keep
-- wandering off, or swing at the CO, go to solitary.
---------------------------------------------------------------------------
X.SWEEP_GRACE_PLAYER = 15
X.SWEEP_GRACE_NPC = 25
X.outSince = {} :: { [any]: number }
X.returning = {} :: { [any]: boolean }
X.strikes = {} :: { [Player]: { n: number, at: number } }

function X.inPlace(pos: Vector3, class: string, want: string, room: any?): boolean
	if room and C.PrisonNav.isInsideCell(room, pos) then
		-- in their own cell is always fine except when they should be out at chow/yard
		return want == "CELL" or want == "BLOCK"
	end
	if want == "CELL" then
		return false
	end
	local area = X.areaFor(class, want)
	local z = C.PrisonNav.zoneAt(pos, 1.5)
	if z and area and z.area == area then
		return true
	end
	local pt = X.pointIn(class, want)
	return pt ~= nil and flat(pt - pos).Magnitude < 35 and math.abs(pt.Y - pos.Y) < 8
end

local function sweepEligible(plr: Player): boolean
	local class = plr:GetAttribute("SecurityClass")
	return plr:GetAttribute("CustodyOwner") == "INCARCERATED" and type(class) == "string" and C.sentenceEnd[plr] ~= nil
		and not C.releaseBusy[plr] and not plr:GetAttribute("Solitary") and not plr:GetAttribute("Visiting")
		and not plr:GetAttribute("DeathRowExecutionStarted") and not X.moving[class] and not X.inSolitary[plr]
end

function X.returnPlayer(plr: Player, class: string, want: string)
	X.returning[plr] = true
	plr:SetAttribute("NoSit", true)
	local ok, err = pcall(function()
		local _, hum, root = C.Util.charInfo(plr)
		if not hum or not root then
			return
		end
		local room = C.PL.playerRoom(plr)
		local dest = if want == "CELL" then (room and C.PrisonFlow.approach(room)) else X.pointIn(class, want)
		if not dest then
			return
		end
		local strike = X.strikes[plr]
		if strike and os.clock() - strike.at > 240 then
			strike = nil
		end
		strike = { n = (strike and strike.n or 0) + 1, at = os.clock() }
		X.strikes[plr] = strike
		local respect = tonumber(plr:GetAttribute("CORespect")) or 0
		if strike.n >= (if respect >= 40 then 4 elseif respect <= -30 then 2 else 3) then
			notice(plr, "You keep wandering off - a CO is taking you to solitary")
			X.strikes[plr] = nil
			task.spawn(X.solitaryPlayer, plr, "out of place, ignoring orders")
			return
		end
		notice(plr, ("CO: You're out of place. Back to the %s - NOW. (warning %d/2)"):format(pretty(want), strike.n))
		local side = flat(root.CFrame.RightVector)
		local cop = C.nameEscort(C.escortCop(root.Position + side * 4, -side), "CORRECTIONAL OFFICER")
		if not cop then
			return
		end
		cop.cfg.WalkSpeed = 9
		setLabel(cop, "BACK TO YOUR " .. string.upper(pretty(want)) .. "!")
		-- swinging at the CO is a trip to solitary
		local last = cop.hum.Health
		local hit = false
		local conn = cop.hum.HealthChanged:Connect(function(h)
			if h < last then
				local _, _, r = C.Util.charInfo(plr)
				if r and flat(r.Position - cop.root.Position).Magnitude < 8 then
					hit = true
				end
			end
			last = h
		end)
		local trail = { cop.root.Position }
		local done = false
		task.spawn(function()
			pcall(function()
				C.PrisonNav.travel(cop, dest, { alive = function()
					return cop.alive and not done and not hit
				end, maxTime = 90, label = "CO RETURN " .. plr.Name })
			end)
			done = true
		end)
		local deadline = os.clock() + 95
		local stuck: number? = nil
		local walkedOff = false
		while not done and not hit and os.clock() < deadline and cop.alive and plr.Parent do
			local _, h2, r2 = C.Util.charInfo(plr)
			if not h2 or not r2 or not sweepEligible(plr) then
				break
			end
			local head = cop.root.Position
			if (trail[#trail] - head).Magnitude > 1.5 then
				table.insert(trail, head)
			end
			local target = trail[math.max(1, #trail - 2)]
			local d = flat(r2.Position - target).Magnitude
			if h2.Sit or h2.SeatPart then
				h2.Sit = false
				h2.Jump = true
			end
			if d > 28 then
				-- v227: walked away from the escorting CO
				walkedOff = true
				break
			elseif d > 5 then
				h2:MoveTo(target)
				stuck = stuck or os.clock()
				if os.clock() - (stuck :: number) > 8 then
					r2.CFrame = CFrame.new(target + Vector3.new(0, 3, 0))
					stuck = nil
				end
			else
				stuck = nil
			end
			C.openPrisonDoorsNear(r2.Position, 8, 4)
			task.wait(0.3)
		end
		conn:Disconnect()
		if walkedOff and not hit then
			done = true
			setLabel(cop, "GET BACK HERE!")
			task.delay(3, function()
				if cop.alive then
					cop:despawn("inmate walked off")
				end
			end)
			X.walkedAway(plr, "the CO")
			return
		end
		if hit then
			notice(plr, "Assaulting a correctional officer - SOLITARY")
			cop:despawn("assaulted")
			task.spawn(X.solitaryPlayer, plr, "assaulted a correctional officer")
			return
		end
		local _, h3, r3 = C.Util.charInfo(plr)
		if h3 and r3 and sweepEligible(plr) then
			if want == "CELL" and room then
				if not room.open then
					C.openMarkedDoor(room.door, 14)
				end
				local t0 = os.clock()
				while os.clock() - t0 < 10 and not C.PrisonNav.isInsideCell(room, r3.Position) do
					h3:MoveTo(room.pos)
					task.wait(0.4)
				end
				if not C.PrisonNav.isInsideCell(room, r3.Position) then
					r3.CFrame = CFrame.new(room.pos + Vector3.new(0, 3, 0))
				end
				task.wait(0.5)
				if not room.open then
					pcall(C.PrisonFlow.closeCell, room)
				end
			elseif flat(r3.Position - dest).Magnitude > 30 then
				r3.CFrame = CFrame.new(dest + Vector3.new(math.random(-4, 4), 3, math.random(-4, 4)))
			end
		end
		cop:despawn("inmate returned")
	end)
	if not ok then
		warn("[PrisonExtras] CO return " .. plr.Name .. ": " .. tostring(err))
	end
	X.outSince[plr] = nil
	X.returning[plr] = nil
	if plr.Parent then
		plr:SetAttribute("NoSit", nil)
	end
end

function X.returnNpc(rec: any, want: string)
	X.returning[rec] = true
	pcall(function()
		print(("[PrisonExtras] CO SWEEP npc %s -> %s"):format(rec.model.Name, want))
		if want == "CELL" then
			rec.inCell = false
			X.enterCell(rec)
		else
			if rec.inCell then
				X.leaveCell(rec)
			end
			local pt = X.pointIn(rec.class, want)
			if pt and not C.PL.walk(rec.model, rec.hum, rec.root, pt, 25) then
				rec.model:PivotTo(CFrame.new(pt + Vector3.new(0, 3, 0)))
			end
		end
	end)
	X.outSince[rec] = nil
	X.returning[rec] = nil
end

function X.startSweep()
	task.spawn(function()
		while C.prison and C.prison.Parent do
			task.wait(4)
			if X.riotActive() then
				continue
			end
			local now = os.clock()
			for _, plr in Players:GetPlayers() do
				if sweepEligible(plr) and not X.returning[plr] then
					local class = plr:GetAttribute("SecurityClass") :: string
					local want = X.classLoc[class] or X.locationFor(class, X.block())
					local _, _, root = C.Util.charInfo(plr)
					if root and not X.inPlace(root.Position, class, want, C.PL.playerRoom(plr)) then
						X.outSince[plr] = X.outSince[plr] or now
						-- v226: COs who respect you give you longer; ones who don't, less
						local r = tonumber(plr:GetAttribute("CORespect")) or 0
						local grace = X.SWEEP_GRACE_PLAYER + (if r >= 40 then 20 elseif r <= -30 then -8 else 0)
						if now - X.outSince[plr] > grace then
							print(("[PrisonExtras] CO SWEEP player %s out of place (want %s)"):format(plr.Name, want))
							task.spawn(X.returnPlayer, plr, class, want)
						end
					else
						X.outSince[plr] = nil
					end
				elseif not X.returning[plr] then
					X.outSince[plr] = nil
				end
			end
			for model, rec in X.npcs do
				if not recAlive(rec) or not model.Parent or X.returning[rec] then
					continue
				end
				-- a line-up that died half way never clears LineUp: unstick it
				if model:GetAttribute("LineUp") and not X.moving[rec.class] then
					model:SetAttribute("LineUp", nil)
				end
				if busy(rec) or X.moving[rec.class] then
					X.outSince[rec] = nil
					continue
				end
				local want = X.classLoc[rec.class] or X.locationFor(rec.class, X.block())
				if (want == "CELL" and not rec.room) or X.inPlace(rec.root.Position, rec.class, want, rec.room) then
					X.outSince[rec] = nil
				else
					X.outSince[rec] = X.outSince[rec] or now
					if now - X.outSince[rec] > X.SWEEP_GRACE_NPC then
						task.spawn(X.returnNpc, rec, want)
					end
				end
			end
		end
	end)
end

---------------------------------------------------------------------------
-- executions
---------------------------------------------------------------------------
X.exec = {} :: { [any]: any } -- subject key (Player / npc rec) -> job
X.live = nil :: any
local liveSeq = 0

local function roomGeometry(room: any): (Vector3, CFrame)
	local center = room.pos
	local corners = {}
	local cp = room.cell:FindFirstChild("ControlPoints")
	if cp then
		for _, v in cp:GetChildren() do
			local p = if v:IsA("Vector3Value") then v.Value elseif v:IsA("BasePart") then v.Position else nil
			if p then
				table.insert(corners, Vector3.new(p.X, center.Y, p.Z))
			end
		end
	end
	local dp = C.markerFloorPosition(room.door) or center
	local far = center + Vector3.new(4, 0, 4)
	local best = -1
	for _, c in corners do
		local d = flat(c - dp).Magnitude
		if d > best then
			best, far = d, c
		end
	end
	local camPos = far + C.Util.safeUnit(flat(center - far), Vector3.zAxis) * 1.6 + Vector3.new(0, 7.5, 0)
	return dp, CFrame.lookAt(camPos, center + Vector3.new(0, 2.5, 0))
end

local function part(props: { [string]: any }, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function sound(parent: Instance, id: string, volume: number, speed: number, looped: boolean): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = speed
	s.Looped = looped
	s.RollOffMaxDistance = 80
	s.Parent = parent
	s:Play()
	return s
end

-- props face the camera side of the room
local function buildProps(job: any)
	local folder = Instance.new("Folder")
	folder.Name = "ExecutionProps_" .. job.name
	folder.Parent = Workspace
	job.props = folder
	local center = job.room.pos
	local facing = C.Util.safeUnit(flat(job.cam.Position - center), Vector3.zAxis)
	local base = CFrame.lookAt(center, center + facing)
	job.base = base
	local metal = Color3.fromRGB(80, 82, 86)
	if job.method == "Electric chair" then
		local wood = Color3.fromRGB(92, 62, 38)
		local seat = Instance.new("Seat")
		seat.Name = "ChairSeat"
		seat.Size = Vector3.new(2.6, 0.5, 2.6)
		seat.Color = wood
		seat.Material = Enum.Material.Wood
		seat.Anchored = true
		seat.CanTouch = false
		seat.CFrame = base * CFrame.new(0, 1.9, 0)
		seat.Parent = folder
		job.seat = seat
		part({ Name = "Back", Size = Vector3.new(2.6, 4, 0.4), Color = wood, Material = Enum.Material.Wood, CFrame = base * CFrame.new(0, 4, 1.2) }, folder)
		for _, x in { -1.4, 1.4 } do
			part({ Size = Vector3.new(0.35, 0.4, 2.4), Color = wood, Material = Enum.Material.Wood, CFrame = base * CFrame.new(x, 3, 0) }, folder)
			part({ Size = Vector3.new(0.35, 1.8, 0.35), Color = wood, Material = Enum.Material.Wood, CFrame = base * CFrame.new(x, 0.9, -1.1) }, folder)
			part({ Size = Vector3.new(0.35, 1.8, 0.35), Color = wood, Material = Enum.Material.Wood, CFrame = base * CFrame.new(x, 0.9, 1.1) }, folder)
		end
		local panel = part({ Name = "SwitchPanel", Size = Vector3.new(1.6, 2.4, 0.4), Color = metal, Material = Enum.Material.DiamondPlate, CFrame = base * CFrame.new(4.5, 4, 2.5) }, folder)
		job.lever = part({ Name = "Lever", Size = Vector3.new(0.25, 1.4, 0.25), Color = Color3.fromRGB(170, 20, 20), CFrame = panel.CFrame * CFrame.new(0, 0.4, -0.4) * CFrame.Angles(math.rad(-30), 0, 0) }, folder)
		job.switchStand = (base * CFrame.new(4.5, 0, 0.5)).Position
	elseif job.method == "Lethal injection" then
		local steel = Color3.fromRGB(200, 202, 205)
		local bed = part({ Name = "Gurney", Size = Vector3.new(2.8, 0.5, 7), Color = Color3.fromRGB(235, 235, 235), Material = Enum.Material.Fabric, CFrame = base * CFrame.new(0, 2.6, 0) }, folder)
		job.bed = bed
		for _, x in { -1.2, 1.2 } do
			for _, z in { -3, 3 } do
				part({ Size = Vector3.new(0.25, 2.4, 0.25), Color = steel, Material = Enum.Material.Metal, CFrame = base * CFrame.new(x, 1.2, z) }, folder)
			end
		end
		local pole = part({ Size = Vector3.new(0.2, 6, 0.2), Color = steel, Material = Enum.Material.Metal, CFrame = base * CFrame.new(2.4, 3, -1.5) }, folder)
		local bag = part({ Name = "IVBag", Size = Vector3.new(0.7, 1, 0.3), Color = Color3.fromRGB(230, 240, 255), Transparency = 0.3, CFrame = pole.CFrame * CFrame.new(0, 2.6, 0) }, folder)
		job.bag = bag
		local monitor = part({ Name = "Monitor", Size = Vector3.new(1.8, 1.3, 0.3), Color = Color3.fromRGB(25, 25, 28), CFrame = base * CFrame.new(-2.6, 4.5, -1) * CFrame.Angles(0, math.rad(200), 0) }, folder)
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.CanvasSize = Vector2.new(180, 130)
		gui.LightInfluence = 0
		gui.Parent = monitor
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = Color3.fromRGB(5, 20, 8)
		label.TextColor3 = Color3.fromRGB(60, 255, 90)
		label.Font = Enum.Font.Code
		label.TextScaled = true
		label.Text = "♥ 84 BPM"
		label.Parent = gui
		job.monitorLabel = label
		job.monitor = monitor
		-- v219: stand clear of the gurney (it is 2.8 wide) by the IV pole
		job.standAt = (base * CFrame.new(3.8, 0, 0.6)).Position
	else -- gas chamber
		local seat = Instance.new("Seat")
		seat.Name = "ChairSeat"
		seat.Size = Vector3.new(2.4, 0.5, 2.4)
		seat.Color = metal
		seat.Material = Enum.Material.Metal
		seat.Anchored = true
		seat.CanTouch = false
		seat.CFrame = base * CFrame.new(0, 1.9, 0)
		seat.Parent = folder
		job.seat = seat
		part({ Size = Vector3.new(2.4, 3.6, 0.3), Color = metal, Material = Enum.Material.Metal, CFrame = base * CFrame.new(0, 3.8, 1.1) }, folder)
		part({ Size = Vector3.new(0.4, 1.8, 0.4), Color = metal, Material = Enum.Material.Metal, CFrame = base * CFrame.new(0, 0.9, 0) }, folder)
		job.canister = part({ Name = "GasPellets", Size = Vector3.new(0.8, 0.6, 0.8), Color = Color3.fromRGB(60, 70, 50), Material = Enum.Material.Metal, CFrame = base * CFrame.new(0, 0.3, -1.6) }, folder)
	end
end

local function subjectInfo(job: any): (Model?, Humanoid?, BasePart?)
	if job.player then
		return C.Util.charInfo(job.player)
	end
	local rec = job.rec
	if rec and rec.hum.Health > 0 and rec.model.Parent then
		return rec.model, rec.hum, rec.root
	end
	return nil, nil, nil
end

local function hold(job: any)
	local char, hum, root = subjectInfo(job)
	if not hum then
		return
	end
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.JumpHeight = 0
end

local function placeSubject(job: any)
	local char, hum, root = subjectInfo(job)
	if not char or not hum or not root then
		return
	end
	if job.seat then
		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.Seated, true)
		end)
		char:PivotTo(job.seat.CFrame * CFrame.new(0, 2.5, 0))
		task.wait(0.2)
		pcall(function()
			job.seat:Sit(hum)
		end)
	elseif job.bed then
		hum.PlatformStand = true
		root.Anchored = true
		char:PivotTo(job.bed.CFrame * CFrame.new(0, 1.3, 0) * CFrame.Angles(math.rad(90), 0, 0))
	end
	hold(job)
end

local function liveInfo(): any?
	local live = X.live
	if not live then
		return nil
	end
	return {
		token = live.token,
		name = live.name,
		method = live.method,
		camera = live.cam,
		focus = live.room.pos,
		pardonAt = live.pardonUntil,
		price = X.PARDON_PRICE,
		state = live.state,
		subject = live.player and live.player.Name or nil,
	}
end

local function broadcast(kind: string, extra: any?)
	local info = liveInfo()
	if info and extra then
		for k, v in extra do
			info[k] = v
		end
	end
	ExecRE:FireAllClients(kind, info)
end

local function carryOut(job: any)
	local char, hum, root = subjectInfo(job)
	if not hum or not root then
		return
	end
	local exe = job.executioner
	if job.method == "Electric chair" then
		if exe and exe.alive and job.switchStand then
			exe:moveTo(job.switchStand, false)
			local t0 = os.clock()
			while exe.alive and flat(exe.root.Position - job.switchStand).Magnitude > 2.5 and os.clock() - t0 < 8 do
				exe:moveTo(job.switchStand, false)
				pcall(function()
					exe:updateAnim()
				end)
				task.wait(0.3)
			end
			exe:stop()
			pcall(function()
				exe:face(job.lever.Position)
			end)
		end
		task.wait(1)
		if job.lever then
			job.lever.CFrame = job.lever.CFrame * CFrame.Angles(math.rad(60), 0, 0)
		end
		local head = char and char:FindFirstChild("Head") :: BasePart?
		local cap = head and part({ Name = "Cap", Size = Vector3.new(head.Size.X * 1.1, 0.5, head.Size.Z * 1.1), Color = Color3.fromRGB(120, 120, 125), Material = Enum.Material.Metal, CFrame = head.CFrame * CFrame.new(0, head.Size.Y * 0.5, 0) }, job.props)
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(150, 200, 255)
		light.Range = 18
		light.Brightness = 0
		light.Parent = cap or job.seat
		local sparks = Instance.new("ParticleEmitter")
		sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparks.Color = ColorSequence.new(Color3.fromRGB(170, 220, 255))
		sparks.LightEmission = 1
		sparks.Size = NumberSequence.new(0.4, 0)
		sparks.Lifetime = NumberRange.new(0.2, 0.5)
		sparks.Speed = NumberRange.new(6, 12)
		sparks.SpreadAngle = Vector2.new(180, 180)
		sparks.Rate = 120
		sparks.Parent = cap or job.seat
		local buzz = sound(job.seat, "rbxasset://sounds/electronicpingshort.wav", 1, 0.35, true)
		for i = 1, 16 do
			light.Brightness = if i % 2 == 0 then 8 else 1
			if hum.Health > 0 then
				hum.Health = math.max(0, hum.Health - hum.MaxHealth / 14)
			end
			task.wait(0.35)
		end
		sparks.Enabled = false
		buzz:Stop()
		light.Brightness = 0
	elseif job.method == "Lethal injection" then
		if exe and exe.alive and job.standAt then
			-- v219: the executioner never shoves the strapped-down inmate
			if exe.model then
				for _, d in exe.model:GetDescendants() do
					if d:IsA("BasePart") then
						d.CanCollide = false
					end
				end
			end
			local t0 = os.clock()
			while exe.alive and flat(exe.root.Position - job.standAt).Magnitude > 2.5 and os.clock() - t0 < 8 do
				exe:moveTo(job.standAt, false)
				pcall(function()
					exe:updateAnim()
				end)
				task.wait(0.3)
			end
			exe:stop()
			if exe.alive and flat(exe.root.Position - job.standAt).Magnitude > 2.5 and exe.model then
				exe.model:PivotTo(CFrame.lookAt(job.standAt + Vector3.new(0, 3, 0), Vector3.new(root.Position.X, job.standAt.Y + 3, root.Position.Z)))
			end
			pcall(function()
				exe:face(root.Position)
			end)
		end
		task.wait(1)
		-- the IV line
		local arm = char and (char:FindFirstChild("LeftHand") or char:FindFirstChild("Left Arm")) :: BasePart?
		if arm and job.bag then
			local a0 = Instance.new("Attachment")
			a0.Parent = job.bag
			local a1 = Instance.new("Attachment")
			a1.Parent = arm
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Width0 = 0.08
			beam.Width1 = 0.08
			beam.Color = ColorSequence.new(Color3.fromRGB(230, 240, 255))
			beam.FaceCamera = true
			beam.Parent = job.bag
		end
		-- v219: the three-drug protocol. Each drug changes the IV bag colour; the
		-- condemned player's own screen blurs (1: sedative), locks up (2: paralytic)
		-- and fades out as the heart stops (3: potassium chloride).
		local function stage(n: number, drug: string, color: Color3, line: string)
			if job.bag then
				job.bag.Color = color
			end
			if exe and exe.alive then
				pcall(function()
					exe:face(root.Position)
				end)
			end
			local head = exe and exe.alive and exe.model and exe.model:FindFirstChild("Head")
			if head then
				pcall(function()
					game:GetService("Chat"):Chat(head, line, Enum.ChatColor.White)
				end)
			end
			if job.player then
				ExecRE:FireClient(job.player, "injection", { stage = n, drug = drug })
			end
			broadcast("injection", { stage = n, drug = drug, viewer = true })
			print(("[PrisonExtras] LETHAL INJECTION %s stage %d: %s"):format(job.name, n, drug))
		end
		local function monitor(bpm: number)
			if job.monitorLabel then
				job.monitorLabel.Text = if bpm > 0 then ("♥ %d BPM"):format(bpm) else "— FLATLINE —"
				job.monitorLabel.TextColor3 = if bpm > 0 then Color3.fromRGB(60, 255, 90) else Color3.fromRGB(255, 70, 70)
			end
			if job.monitor then
				sound(job.monitor, "rbxasset://sounds/electronicpingshort.wav", 0.6, if bpm > 0 then 1.4 else 0.9, false)
			end
		end
		-- 1. sodium thiopental: unconscious
		stage(1, "Sodium thiopental", Color3.fromRGB(245, 245, 200), "Administering the first drug.")
		for _, bpm in { 88, 80, 72, 66, 62, 60, 58 } do
			monitor(bpm)
			task.wait(1.1)
		end
		-- 2. pancuronium bromide: paralysed, breathing stops
		stage(2, "Pancuronium bromide", Color3.fromRGB(200, 225, 255), "Second drug. Respiration is stopping.")
		for _, bpm in { 56, 54, 50, 46, 42, 40 } do
			monitor(bpm)
			task.wait(1.1)
		end
		-- 3. potassium chloride: the heart stops
		stage(3, "Potassium chloride", Color3.fromRGB(255, 205, 205), "Third drug.")
		for _, bpm in { 34, 22, 12, 4, 0, 0, 0 } do
			monitor(bpm)
			if bpm == 0 and hum.Health > 0 then
				hum.Health = 0
			end
			task.wait(1)
		end
		if hum.Health > 0 then
			hum.Health = 0
		end
	else
		-- gas chamber: the executioner steps out, the door seals, pellets drop
		if exe and exe.alive then
			exe:moveTo(C.PrisonFlow.approach(job.room), false)
			task.wait(2.5)
		end
		pcall(C.PrisonFlow.closeCell, job.room)
		task.wait(1)
		local gas = Instance.new("ParticleEmitter")
		gas.Texture = "rbxasset://textures/particles/smoke_main.dds"
		gas.Color = ColorSequence.new(Color3.fromRGB(190, 210, 120), Color3.fromRGB(140, 160, 90))
		gas.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		gas.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 9) })
		gas.Lifetime = NumberRange.new(4, 7)
		gas.Rate = 45
		gas.Speed = NumberRange.new(1, 4)
		gas.SpreadAngle = Vector2.new(180, 180)
		gas.Parent = job.canister
		sound(job.canister, "rbxasset://sounds/electronicpingshort.wav", 0.8, 0.2, false)
		for _ = 1, 14 do
			if hum.Health > 0 then
				hum.Health = math.max(0, hum.Health - hum.MaxHealth / 12)
			end
			task.wait(0.8)
		end
		gas.Enabled = false
	end
	-- no money drop from an execution: it's a wipe
	if job.player then
		local cash = job.player:FindFirstChild("Cash")
		if cash and (cash:IsA("IntValue") or cash:IsA("NumberValue")) then
			cash.Value = 0
		end
	end
	if hum.Health > 0 then
		hum.Health = 0
	end
end

local function cleanup(job: any)
	if job.executioner and job.executioner.alive then
		pcall(function()
			job.executioner:despawn("execution over")
		end)
	end
	task.delay(6, function()
		if job.props then
			job.props:Destroy()
		end
	end)
	job.room.cell:SetAttribute("RoomBusy", nil)
	C.openMarkedDoor(job.room.door, 3)
end

-- the whole sequence, after the condemned is inside the room
local function runExecution(job: any)
	local ok, err = pcall(function()
		local dp, cam = roomGeometry(job.room)
		job.cam = cam
		hold(job)
		-- 1. the method
		local options = { "Gas chamber", "Electric chair", "Lethal injection" }
		if job.player then
			liveSeq += 1
			job.choiceToken = liveSeq
			ExecRE:FireClient(job.player, "choose", { token = liveSeq, options = options, seconds = 20 })
			local deadline = os.clock() + 21
			while not job.method and os.clock() < deadline and job.player.Parent do
				hold(job)
				task.wait(0.25)
			end
		end
		job.method = job.method or pick(options)
		print(("[PrisonExtras] EXECUTION %s method=%s room=%s"):format(job.name, job.method, job.room.name))
		buildProps(job)
		placeSubject(job)
		-- 2. the executioner
		local inward = C.Util.safeUnit(flat(job.room.pos - dp), Vector3.zAxis)
		job.executioner = C.nameEscort(C.escortCop(dp + inward * 3, inward), "EXECUTIONER")
		if job.executioner then
			job.executioner.cfg.WalkSpeed = 6
		end
		-- 3. live on C-SPAN, pardon window
		liveSeq += 1
		X.live = { token = liveSeq, name = job.name, method = job.method, cam = cam, room = job.room, player = job.player, job = job, state = "live" }
		X.live.pardonUntil = os.time() + X.PARDON_WINDOW
		broadcast("live")
		for _, plr in Players:GetPlayers() do
			notice(plr, ("LIVE ON C-SPAN: the execution of %s (%s). Open C-SPAN to watch."):format(job.name, string.lower(job.method)))
		end
		while os.time() < X.live.pardonUntil and not job.pardoned do
			hold(job)
			local _, hum = subjectInfo(job)
			if not hum then
				break
			end
			task.wait(0.5)
		end
		if job.pardoned then
			X.live.state = "pardoned"
			broadcast("pardoned", { by = job.pardonBy })
			for _, plr in Players:GetPlayers() do
				notice(plr, ("GOVERNOR'S PARDON: %s's execution was called off (paid by %s)"):format(job.name, tostring(job.pardonBy)))
			end
			local char, hum, root = subjectInfo(job)
			if hum then
				hum.Sit = false
				hum.PlatformStand = false
			end
			if root then
				root.Anchored = false
			end
			cleanup(job)
			X.live = nil
			if job.player then
				X.pardonPlayer(job.player)
			elseif job.rec then
				job.rec.model:SetAttribute("Executing", nil)
				task.spawn(X.releaseNpc, job.rec)
			end
			return
		end
		-- 4. carried out
		X.live.state = "executing"
		broadcast("executing")
		carryOut(job)
		task.wait(3)
		X.live.state = "ended"
		broadcast("ended")
		X.live = nil
		local char, hum, root = subjectInfo(job)
		if root then
			root.Anchored = false
		end
		cleanup(job)
		if job.player and job.player.Parent then
			if C.finishExecution then
				C.finishExecution(job.player)
			else
				C.resetExecutedPlayer(job.player)
				pcall(C.tell, job.player, "Released", "executed")
			end
		elseif job.rec then
			job.rec.gone = true
			X.forget(job.rec)
			task.delay(3, function()
				if job.rec.model.Parent then
					job.rec.model:Destroy()
				end
			end)
		end
	end)
	if not ok then
		warn("[PrisonExtras] execution error: " .. tostring(err))
		pcall(cleanup, job)
		if X.live and X.live.job == job then
			X.live = nil
			broadcast("ended")
		end
	end
	X.exec[job.key] = nil
end

function X.pardonPlayer(player: Player)
	for _, name in { "DeathRowExecutionStarted", "DeathRowGasExposure", "DeathRowExecutionComplete" } do
		player:SetAttribute(name, nil)
	end
	player:SetAttribute("CustodyPhase", "SentencedPrisoner")
	player:SetAttribute("SecurityClass", "Pardoned")
	local _, hum = C.Util.charInfo(player)
	if hum then
		hum.WalkSpeed = 8
		hum.JumpPower = 50
		hum.JumpHeight = 7.2
	end
	C.custody[player] = nil
	task.spawn(C.release, player, "governor pardon")
end

-- sentenceLoop hook. True = handled (or already running)
function X.execute(player: Player): boolean
	if X.exec[player] then
		return true
	end
	if player:GetAttribute("SecurityClass") ~= "Death Row" or not player.Parent then
		return true
	end
	C.custody[player] = true
	local room = C.PrisonFlow.pick(player, "ExecutionRoom") or X.freeRoom("ExecutionRoom")
	if not room then
		C.custody[player] = nil
		warn(("[PrisonExtras] no free execution room for %s (mapped: %d)"):format(player.Name, #X.rooms("ExecutionRoom")))
		return false -- retried next second
	end
	print(("[PrisonExtras] EXECUTION START %s -> %s"):format(player.Name, room.name))
	local job = { key = player, player = player, room = room, name = player.Name }
	X.exec[player] = job
	room.cell:SetAttribute("RoomBusy", true)
	player:SetAttribute("DeathRowExecutionStarted", true)
	player:SetAttribute("CustodyPhase", "DeathRowExecution")
	player:SetAttribute("BookingState", "DeathRowExecution")
	pcall(C.tell, player, "DeathRowExecution", "Sentence complete - the execution detail is here for you")
	task.spawn(function()
		local delivered = C.PrisonFlow.deliver(player, "EXECUTION OFFICER", room, "HOUSING_ESCORT")
		if not delivered and player.Parent then
			pcall(C.PrisonFlow.fallbackDeliver, player, "EXECUTION OFFICER", room, "HOUSING_ESCORT")
		end
		-- the escort ends as "incarcerated"; this is the execution chamber
		player:SetAttribute("CustodyPhase", "DeathRowExecution")
		player:SetAttribute("BookingState", "DeathRowExecution")
		if player.Parent then
			runExecution(job)
		else
			X.exec[player] = nil
			room.cell:SetAttribute("RoomBusy", nil)
		end
	end)
	return true
end

function X.executeNpc(rec: any)
	if X.exec[rec] or not recAlive(rec) then
		return
	end
	local room = X.freeRoom("ExecutionRoom")
	if not room then
		rec.sentenceEnd = os.time() + 300
		return
	end
	room.cell:SetAttribute("RoomBusy", true)
	local job = { key = rec, rec = rec, room = room, name = rec.model.Name }
	X.exec[rec] = job
	rec.model:SetAttribute("Executing", true)
	if rec.inCell then
		X.leaveCell(rec)
	end
	local cop = C.nameEscort(C.escortCop(rec.root.Position + Vector3.new(3, 0, 0), Vector3.zAxis), "EXECUTION OFFICER")
	C.PL.npcLabel(rec.model, "DEATH ROW")
	if cop then
		C.PL.npcEscortTo(cop, rec.model, C.PrisonFlow.approach(room), "NPC EXECUTION")
	end
	C.openMarkedDoor(room.door, 8)
	C.PL.walk(rec.model, rec.hum, rec.root, room.pos, 8)
	if cop then
		cop:despawn("npc at execution")
	end
	local gui = rec.model:FindFirstChild("Head") and rec.model.Head:FindFirstChild("NpcCustodyLabel")
	if gui then
		gui:Destroy()
	end
	runExecution(job)
end

ExecRE.OnServerEvent:Connect(function(player: Player, kind: any, token: any, value: any)
	if not C then
		return
	end
	if kind == "choose" then
		local job = X.exec[player]
		if job and job.choiceToken == token and not job.method then
			if value == "Gas chamber" or value == "Electric chair" or value == "Lethal injection" then
				job.method = value
			end
		end
	elseif kind == "pardon" then
		local live = X.live
		if not live or live.token ~= token or live.state ~= "live" or live.job.pardoned then
			return
		end
		if live.player == player then
			notice(player, "You can't pay for your own pardon")
			return
		end
		if os.time() > (live.pardonUntil or 0) then
			notice(player, "Too late - the governor's line is closed")
			return
		end
		if economy("Charge", player, X.PARDON_PRICE) then
			live.job.pardoned = true
			live.job.pardonBy = player.Name
			print(("[PrisonExtras] PARDON %s paid $%d for %s"):format(player.Name, X.PARDON_PRICE, live.name))
		else
			notice(player, "You need $50,000,000 for the governor's pardon")
		end
	elseif kind == "sync" then
		local info = liveInfo()
		if info then
			ExecRE:FireClient(player, "live", info)
		end
	end
end)

---------------------------------------------------------------------------
-- visits
---------------------------------------------------------------------------
X.visits = {} :: { [Player]: any } -- keyed by visitor AND inmate
local visitSeq = 0

local function visitingHours(): boolean
	local h = Lighting.ClockTime
	return h >= X.VISIT_HOURS[1] and h < X.VISIT_HOURS[2]
end

local function inCustody(player: Player): boolean
	return player:GetAttribute("BookingState") ~= nil or player:GetAttribute("CustodyPhase") ~= nil
		or player:GetAttribute("SentenceEnd") ~= nil or player:GetAttribute("CustodyOwner") ~= nil
end

local function eligibleInmate(player: Player): (boolean, string?)
	if player:GetAttribute("CustodyOwner") ~= "INCARCERATED" or not C.sentenceEnd[player] then
		return false, "not housed"
	end
	if (tonumber(player:GetAttribute("SentenceSeconds")) or 0) < X.VISIT_MIN_SENTENCE then
		return false, "sentence under 10 minutes"
	end
	if player:GetAttribute("Solitary") or player:GetAttribute("DeathRowExecutionStarted") or C.releaseBusy[player] then
		return false, "not available"
	end
	if X.visits[player] then
		return false, "already in a visit"
	end
	return true, nil
end

VisitRF.OnServerInvoke = function(player: Player, action: any)
	if not C then
		return { hours = false, inmates = {}, busy = false }
	end
	if action == "list" then
		local out = {}
		for _, plr in Players:GetPlayers() do
			if plr ~= player and plr:GetAttribute("CustodyOwner") == "INCARCERATED" and C.sentenceEnd[plr] then
				local ok, why = eligibleInmate(plr)
				local class = tostring(plr:GetAttribute("SecurityClass") or "")
				table.insert(out, {
					name = plr.Name,
					display = (plr:GetAttribute("CharacterName") or plr.DisplayName),
					class = class,
					remaining = math.max(0, (C.sentenceEnd[plr] or os.time()) - os.time()),
					eligible = ok,
					why = why,
					contact = class ~= "Supermax" and class ~= "Death Row",
				})
			end
		end
		return { hours = visitingHours(), inmates = out, busy = X.visits[player] ~= nil }
	end
	return nil
end

local function pickByNumber(category: string, number: number?): any?
	for _, r in X.rooms(category) do
		local n = tonumber(r.name:match("_(%d+)$")) or 1
		if (not number or n == number) and not r.cell:GetAttribute("RoomBusy") and not playerOccupied(r.cell) then
			return r
		end
	end
	return nil
end

-- a cruiser drives `player` from where they are to `dest` (a road point)
function X.ride(player: Player, dest: Vector3, text: string): boolean
	local char, hum, root = C.Util.charInfo(player)
	if not char or not hum or not root then
		return false
	end
	local pickup = root.Position + root.CFrame.RightVector * 8
	local bestD = math.huge
	for _, node in C.RoadGraph.nodesNear(root.Position, 150) do
		local p = C.RoadGraph.nodePos(node)
		if p and flat(p - root.Position).Magnitude < bestD then
			pickup, bestD = p, flat(p - root.Position).Magnitude
		end
	end
	local ground = C.Util.groundAt(pickup, 30, 80)
	if ground then
		pickup = Vector3.new(pickup.X, ground.Y, pickup.Z)
	end
	local van = C.Van.spawnPatrol(pickup, 1, true, C.Util.safeUnit(flat(dest - pickup), Vector3.zAxis))
	local function drop()
		local _, _, r = C.Util.charInfo(player)
		if r then
			local g = C.Util.groundAt(dest, 20, 60) or dest
			r.CFrame = CFrame.new(Vector3.new(dest.X, g.Y + 3, dest.Z))
		end
	end
	if not van then
		drop()
		return true
	end
	van.driveToken += 1
	van.mode = "respond"
	van.crewTotal = 1
	van.crewOut = 0
	van.transporting = true
	van.parked = false
	van.parts.ap.Enabled = true
	van.parts.ao.Enabled = true
	for _, p in van.model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = false
			p.CanTouch = false
		end
	end
	pcall(function()
		van.body:SetNetworkOwner(nil)
	end)
	van.parts.ap.Position = van.body.Position
	van.parts.ao.CFrame = van.body.CFrame.Rotation
	local body = van.body
	notice(player, text)
	task.wait(1.5)
	root.CFrame = body.CFrame * CFrame.new(-1.3, body.Size.Y / 2 + 1.1, 2.4)
	hum.Sit = true
	pcall(C.custodyTransportGhost, char, true)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = root
	weld.Parent = body
	local done = false
	local started = van:driveTo(dest, false, function()
		done = true
	end)
	local deadline = os.clock() + 150
	local lastPos, lastMove = body.Position, os.clock()
	while started and not done and os.clock() < deadline and player.Parent and player.Character == char and not van.dead do
		if flat(body.Position - dest).Magnitude < 25 then
			break
		end
		if flat(body.Position - lastPos).Magnitude > 4 then
			lastPos, lastMove = body.Position, os.clock()
		end
		if os.clock() - lastMove > 12 then
			break
		end
		task.wait(0.5)
	end
	weld:Destroy()
	if player.Character == char then
		pcall(C.custodyTransportGhost, char, false)
		hum.Sit = false
	end
	drop()
	task.delay(6, function()
		van.transporting = false
		pcall(function()
			van:destroy()
		end)
	end)
	return true
end

-- the public road in front of the prison lobby
local function prisonFront(): Vector3?
	local map = C.PrisonNav.mapRoot
	local zones = map and map:FindFirstChild("Zones")
	local lobby = zones and zones:FindFirstChild("Lobby")
	local center: Vector3? = nil
	local cp = lobby and lobby:FindFirstChild("ControlPoints")
	if cp then
		local sum, n = Vector3.zero, 0
		for _, v in cp:GetChildren() do
			local p = if v:IsA("Vector3Value") then v.Value elseif v:IsA("BasePart") then v.Position else nil
			if p then
				sum += p
				n += 1
			end
		end
		if n > 0 then
			center = sum / n
		end
	end
	if not center then
		local _, outside = C.prisonExit()
		center = outside
	end
	local best, bestD = nil, math.huge
	for _, node in C.RoadGraph.nodesNear(center :: Vector3, 400) do
		local p = C.RoadGraph.nodePos(node)
		if p and C.outsidePrison(p, nil) then
			local d = flat(p - (center :: Vector3)).Magnitude
			if d < bestD then
				best, bestD = p, d
			end
		end
	end
	return best or center
end

-- the visitor-side spot of a visit room
local function visitorSpot(room: any, visitorDoor: Instance?): Vector3
	if visitorDoor then
		local dp = C.markerFloorPosition(visitorDoor)
		if dp then
			local inward = C.Util.safeUnit(flat(room.pos - dp), Vector3.zAxis)
			return dp + inward * 3
		end
	end
	return room.pos
end

local function endVisit(visit: any)
	if visit.ended then
		return
	end
	visit.ended = true
	VisitRE:FireClient(visit.visitor, "ended", {})
	if visit.inmate.Parent then
		VisitRE:FireClient(visit.inmate, "ended", {})
	end
end

function X.runVisit(visitor: Player, inmate: Player, contact: boolean)
	visitSeq += 1
	local visit = { id = visitSeq, visitor = visitor, inmate = inmate, contact = contact }
	X.visits[visitor] = visit
	X.visits[inmate] = visit
	visitor:SetAttribute("Visiting", inmate.Name)
	inmate:SetAttribute("Visiting", visitor.Name)
	local ok, err = pcall(function()
		-- rooms
		local prisonerRoom, visitorRoom, visitorDoor
		if contact then
			prisonerRoom = pickByNumber("ContactVisit", nil)
			local doors = C.PrisonNav.mapRoot and C.PrisonNav.mapRoot:FindFirstChild("DoorMarkers")
			visitorDoor = doors and (doors:FindFirstChild("Vistiro Contact Visit") or doors:FindFirstChild("Visitor Contact Visit"))
		else
			prisonerRoom = pickByNumber("VisitPrisoner", nil)
			local n = prisonerRoom and tonumber(prisonerRoom.name:match("_(%d+)$")) or 1
			visitorRoom = pickByNumber("VisitVisitor", n) or pickByNumber("VisitVisitor", nil)
		end
		if not prisonerRoom then
			notice(visitor, "All visiting rooms are in use - try again soon")
			notice(inmate, "Visit cancelled: no visiting room free")
			return
		end
		prisonerRoom.cell:SetAttribute("RoomBusy", true)
		if visitorRoom then
			visitorRoom.cell:SetAttribute("RoomBusy", true)
		end
		visit.rooms = { prisonerRoom, visitorRoom }
		-- the visitor's ride in, while a CO brings the inmate down
		local _, _, vroot = C.Util.charInfo(visitor)
		visit.origin = vroot and vroot.Position
		local front = prisonFront()
		local inmateReady = false
		task.spawn(function()
			C.custody[inmate] = true
			notice(inmate, "Visitor on the way - a CO is taking you to visitation")
			local room = { cell = prisonerRoom.cell, door = prisonerRoom.door, pos = prisonerRoom.pos, name = prisonerRoom.name, category = prisonerRoom.category, open = false, capacity = 1 }
			C.PrisonFlow.reserved[inmate] = room
			if not C.PrisonFlow.deliver(inmate, "VISITATION OFFICER", room, "HOUSING_ESCORT") and inmate.Parent then
				pcall(C.PrisonFlow.fallbackDeliver, inmate, "VISITATION OFFICER", room, "HOUSING_ESCORT")
			end
			C.custody[inmate] = nil
			inmateReady = true
		end)
		if front then
			X.ride(visitor, front, "Visitation: a cruiser is taking you to the State Prison")
		end
		if not visitor.Parent then
			return
		end
		-- checked in and walked through to the visitor side
		local spot = if contact then visitorSpot(prisonerRoom, visitorDoor) else (visitorRoom and visitorRoom.pos or prisonerRoom.pos)
		local _, _, vr = C.Util.charInfo(visitor)
		if vr then
			vr.CFrame = CFrame.new(spot + Vector3.new(0, 3, 0))
		end
		notice(visitor, "Checked in at visitation. Wait for the inmate.")
		local waitUntil = os.clock() + 120
		while not inmateReady and os.clock() < waitUntil and visitor.Parent and inmate.Parent do
			task.wait(1)
		end
		if not inmate.Parent or not visitor.Parent then
			return
		end
		-- the visit
		visit.endsAt = os.time() + X.VISIT_SECS
		VisitRE:FireClient(visitor, "visiting", { with = (inmate:GetAttribute("CharacterName") or inmate.DisplayName), contact = contact, endsAt = visit.endsAt, items = if contact then { "Shiv", "Prison Pills", "Cash ($1,000)" } else nil })
		VisitRE:FireClient(inmate, "visiting", { with = (visitor:GetAttribute("CharacterName") or visitor.DisplayName), contact = contact, endsAt = visit.endsAt })
		while os.time() < visit.endsAt and not visit.ended and visitor.Parent and inmate.Parent do
			task.wait(1)
		end
	end)
	if not ok then
		warn("[PrisonExtras] visit error: " .. tostring(err))
	end
	endVisit(visit)
	-- visitor out and home
	if visitor.Parent then
		local front = prisonFront()
		if visit.caught then
			notice(visitor, "You were caught smuggling contraband")
		elseif front and visit.origin then
			local _, _, vr = C.Util.charInfo(visitor)
			if vr then
				vr.CFrame = CFrame.new(front + Vector3.new(0, 3, 0))
			end
			task.spawn(X.ride, visitor, visit.origin, "Visit over - a cruiser is driving you back")
		end
		visitor:SetAttribute("Visiting", nil)
	end
	-- inmate back to their cellblock
	if inmate.Parent then
		inmate:SetAttribute("Visiting", nil)
		if visit.caught then
			X.discipline(inmate, "contraband smuggled in a visit")
		elseif C.sentenceEnd[inmate] and not C.releaseBusy[inmate] then
			C.custody[inmate] = true
			local class = tostring(inmate:GetAttribute("SecurityClass") or "Medium")
			local back = C.PrisonFlow.pick(inmate, C.PrisonFlow.categoryFor(class))
			if back and C.PrisonFlow.deliver(inmate, "CORRECTIONAL OFFICER", back, "HOUSING_ESCORT") then
				C.housingAssignment[inmate] = back.cell
				inmate:SetAttribute("AssignedCell", back.name)
			end
			C.custody[inmate] = nil
		end
	end
	for _, r in visit.rooms or {} do
		if r then
			r.cell:SetAttribute("RoomBusy", nil)
		end
	end
	X.visits[visitor] = nil
	X.visits[inmate] = nil
end

local pendingRequests: { [number]: any } = {}

VisitRE.OnServerEvent:Connect(function(player: Player, kind: any, a: any, b: any)
	if not C then
		return
	end
	if kind == "request" then
		local inmate = type(a) == "string" and Players:FindFirstChild(a)
		local contact = b == true
		if not inmate or not inmate:IsA("Player") or inmate == player then
			return
		end
		if inCustody(player) then
			notice(player, "You can't visit while you're in custody")
			return
		end
		if not visitingHours() then
			notice(player, "Visiting hours are 08:00 - 20:00")
			return
		end
		if X.visits[player] then
			notice(player, "You're already on a visit")
			return
		end
		local ok, why = eligibleInmate(inmate)
		if not ok then
			notice(player, (inmate:GetAttribute("CharacterName") or inmate.DisplayName) .. " can't have visitors: " .. tostring(why))
			return
		end
		local class = tostring(inmate:GetAttribute("SecurityClass") or "")
		if contact and (class == "Supermax" or class == "Death Row") then
			contact = false
		end
		visitSeq += 1
		local token = visitSeq
		pendingRequests[token] = { visitor = player, inmate = inmate, contact = contact, at = os.clock() }
		VisitRE:FireClient(inmate, "request", { token = token, from = (player:GetAttribute("CharacterName") or player.DisplayName), contact = contact })
		notice(player, "Visit requested - waiting for " .. (inmate:GetAttribute("CharacterName") or inmate.DisplayName) .. " to accept")
		task.delay(30, function()
			if pendingRequests[token] then
				pendingRequests[token] = nil
				if player.Parent then
					notice(player, "No answer - visit request expired")
				end
			end
		end)
	elseif kind == "answer" then
		local req = pendingRequests[a]
		if not req or req.inmate ~= player then
			return
		end
		pendingRequests[a] = nil
		if b ~= true then
			notice(req.visitor, (player:GetAttribute("CharacterName") or player.DisplayName) .. " declined the visit")
			return
		end
		if X.visits[req.visitor] or X.visits[player] or not req.visitor.Parent then
			return
		end
		notice(req.visitor, (player:GetAttribute("CharacterName") or player.DisplayName) .. " accepted - transport is on the way")
		task.spawn(X.runVisit, req.visitor, player, req.contact)
	elseif kind == "smuggle" then
		local visit = X.visits[player]
		if not visit or visit.visitor ~= player or not visit.contact or visit.smuggled or visit.ended then
			return
		end
		local item = if a == "Shiv" or a == "Prison Pills" or a == "Cash ($1,000)" then a else nil
		if not item then
			return
		end
		visit.smuggled = true
		visit.item = item
		if math.random() < X.SMUGGLE_CAUGHT then
			X.caught(visit, "spotted instantly")
			return
		end
		local keys = {}
		local pool = { "E", "Q", "R", "F", "Z", "X" }
		for i = 1, 4 do
			keys[i] = pick(pool)
		end
		visit.qte = { keys = keys, at = os.clock() }
		VisitRE:FireClient(player, "qte", { keys = keys, window = 1.4 })
	elseif kind == "qte" then
		local visit = X.visits[player]
		if not visit or visit.visitor ~= player or not visit.qte or visit.qteDone then
			return
		end
		visit.qteDone = true
		local elapsed = os.clock() - visit.qte.at
		-- a pass can't come back faster than a human could press four keys
		if a == true and elapsed > 1.0 and elapsed < 12 then
			X.deliverContraband(visit.inmate, visit.item)
			notice(player, "Slipped it over. Nobody saw a thing.")
			notice(visit.inmate, "Your visitor slipped you: " .. visit.item)
		else
			X.caught(visit, "fumbled the hand-off")
		end
	end
end)

-- v257b LEGAL VISIT: the inmate's lawyer (an NPC) in a visiting room - glass for routine
-- talks, contact when there's a lot to go over. Any hour (legal visits aren't social
-- visits). LawFirms runs the conversation: talk(inmate, info) -> { caught = bool }?
local function lawyerNpc(at: Vector3, face: Vector3, firm: string): Model?
	local ok, model = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		desc.TorsoColor = Color3.fromRGB(35, 38, 48) -- dark suit
		desc.LeftArmColor, desc.RightArmColor = desc.TorsoColor, desc.TorsoColor
		desc.LeftLegColor, desc.RightLegColor = Color3.fromRGB(30, 30, 36), Color3.fromRGB(30, 30, 36)
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		return nil
	end
	model.Name = firm
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayName = firm
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	end
	model.Parent = workspace
	if root then
		root.Anchored = true
		local flat = Vector3.new(face.X, at.Y, face.Z)
		model:PivotTo(CFrame.lookAt(at + Vector3.new(0, 3, 0), flat + Vector3.new(0, 3, 0)))
	end
	return model
end

function X.legalVisit(inmate: Player, firm: string, contact: boolean, talk: any): (boolean, string?)
	if X.visits[inmate] or inmate:GetAttribute("Visiting") then
		return false, "already in a visit"
	end
	if not C.sentenceEnd[inmate] or C.releaseBusy[inmate] or inmate:GetAttribute("Solitary") then
		return false, "not available for visits right now"
	end
	local class = tostring(inmate:GetAttribute("SecurityClass") or "")
	if contact and (class == "Supermax" or class == "Death Row") then
		contact = false -- glass only at that level
	end
	local prisonerRoom, visitorRoom, visitorDoor
	if contact then
		prisonerRoom = pickByNumber("ContactVisit", nil)
		local doors = C.PrisonNav.mapRoot and C.PrisonNav.mapRoot:FindFirstChild("DoorMarkers")
		visitorDoor = doors and (doors:FindFirstChild("Vistiro Contact Visit") or doors:FindFirstChild("Visitor Contact Visit"))
	else
		prisonerRoom = pickByNumber("VisitPrisoner", nil)
		local n = prisonerRoom and tonumber(prisonerRoom.name:match("_(%d+)$")) or 1
		visitorRoom = pickByNumber("VisitVisitor", n) or pickByNumber("VisitVisitor", nil)
	end
	if not prisonerRoom then
		return false, "every visiting room is in use"
	end
	visitSeq += 1
	local visit = { id = visitSeq, visitor = inmate, inmate = inmate, contact = contact, legal = true }
	X.visits[inmate] = visit
	inmate:SetAttribute("Visiting", firm)
	prisonerRoom.cell:SetAttribute("RoomBusy", true)
	if visitorRoom then
		visitorRoom.cell:SetAttribute("RoomBusy", true)
	end
	print(("[PrisonExtras] LEGAL VISIT %s with %s (%s) in %s"):format(inmate.Name, firm, if contact then "contact" else "glass", prisonerRoom.name))
	local npc: Model? = nil
	local result: any = nil
	local ok, err = pcall(function()
		C.custody[inmate] = true
		notice(inmate, "Legal visit - " .. firm .. " is here. A CO is taking you down.")
		local room = { cell = prisonerRoom.cell, door = prisonerRoom.door, pos = prisonerRoom.pos, name = prisonerRoom.name, category = prisonerRoom.category, open = false, capacity = 1 }
		C.PrisonFlow.reserved[inmate] = room
		if not C.PrisonFlow.deliver(inmate, "VISITATION OFFICER", room, "HOUSING_ESCORT") and inmate.Parent then
			pcall(C.PrisonFlow.fallbackDeliver, inmate, "VISITATION OFFICER", room, "HOUSING_ESCORT")
		end
		C.custody[inmate] = nil
		if not inmate.Parent then
			return
		end
		local spot = if contact then visitorSpot(prisonerRoom, visitorDoor) else (visitorRoom and visitorRoom.pos or prisonerRoom.pos)
		npc = lawyerNpc(spot, prisonerRoom.pos, firm)
		local r = talk(inmate, { contact = contact, firm = firm })
		result = if type(r) == "table" then r else nil
	end)
	if not ok then
		warn("[PrisonExtras] legal visit error: " .. tostring(err))
	end
	if npc then
		npc:Destroy()
	end
	if inmate.Parent then
		inmate:SetAttribute("Visiting", nil)
		if result and result.caught then
			X.discipline(inmate, "contraband passed in a legal visit")
		elseif C.sentenceEnd[inmate] and not C.releaseBusy[inmate] then
			C.custody[inmate] = true
			local cls = tostring(inmate:GetAttribute("SecurityClass") or "Medium")
			local back = C.PrisonFlow.pick(inmate, C.PrisonFlow.categoryFor(cls))
			if back and C.PrisonFlow.deliver(inmate, "CORRECTIONAL OFFICER", back, "HOUSING_ESCORT") then
				C.housingAssignment[inmate] = back.cell
				inmate:SetAttribute("AssignedCell", back.name)
			end
			C.custody[inmate] = nil
		end
	end
	prisonerRoom.cell:SetAttribute("RoomBusy", nil)
	if visitorRoom then
		visitorRoom.cell:SetAttribute("RoomBusy", nil)
	end
	X.visits[inmate] = nil
	print(("[PrisonExtras] LEGAL VISIT %s done%s"):format(inmate.Name, if result and result.caught then " - CAUGHT" else ""))
	return true, nil
end

do
	local fn = ServerStorage:FindFirstChild("LegalVisit") or Instance.new("BindableFunction")
	fn.Name = "LegalVisit"
	fn.OnInvoke = function(inmate, firm, contact, talk)
		if not C or typeof(inmate) ~= "Instance" or not inmate:IsA("Player") or type(talk) ~= "function" then
			return false, "unavailable"
		end
		return X.legalVisit(inmate, tostring(firm), contact == true, talk)
	end
	fn.Parent = ServerStorage
end

function X.caught(visit: any, why: string)
	visit.caught = true
	notice(visit.visitor, "CAUGHT SMUGGLING - " .. why)
	notice(visit.inmate, "Your visitor was caught smuggling - you're going to solitary")
	local report = ServerStorage:FindFirstChild("ReportCrime")
	if report and report:IsA("BindableFunction") then
		pcall(report.Invoke, report, visit.visitor, "Smuggling contraband into a prison", 2)
	end
	endVisit(visit)
end

function X.deliverContraband(inmate: Player, item: string)
	if item == "Cash ($1,000)" then
		economy("AddCash", inmate, 1000)
		return
	end
	local fn = ServerStorage:FindFirstChild("PrisonContraband")
	if fn and fn:IsA("BindableFunction") then
		pcall(fn.Invoke, fn, inmate, if item == "Shiv" then "Shiv" else "Pills")
	end
end

---------------------------------------------------------------------------
-- boot
---------------------------------------------------------------------------
function X.init(ctx: any)
	C = ctx
	-- NPC inmates now belong to the regimen; arrests hand their NPC over here
	C.PL.inmateLife = function(npc: Model, hum: Humanoid, root: BasePart, group: any, _room: any, _folder: any)
		if not X.adopt(npc, hum, root, group.class) then
			npc:Destroy()
		end
	end
	C.PL.startNpcInmates = function() end
	C.PL.rollClass = function()
		return X.rollArrestClass()
	end
	-- player cell doors follow the regimen too (open whenever the class is out)
	C.PL.cellOpenFor = function(class: string): boolean
		return X.locationFor(class, X.block()) ~= "CELL"
	end
	local discipline = ServerStorage:FindFirstChild("PrisonDiscipline") or Instance.new("BindableFunction")
	discipline.Name = "PrisonDiscipline"
	discipline.OnInvoke = function(target, reason)
		return X.discipline(target, reason)
	end
	discipline.Parent = ServerStorage
	-- v226: a CO's good word (or a bad report) moves an inmate's release time
	local adjust = ServerStorage:FindFirstChild("PrisonSentenceAdjust") or Instance.new("BindableFunction")
	adjust.Name = "PrisonSentenceAdjust"
	adjust.OnInvoke = function(target, delta)
		if typeof(target) ~= "Instance" or not target:IsA("Player") or type(delta) ~= "number" then
			return false
		end
		local done = C.sentenceEnd[target]
		if not done then
			return false
		end
		C.sentenceEnd[target] = math.max(os.time() + 15, done + math.floor(delta))
		target:SetAttribute("SentenceEnd", C.sentenceEnd[target])
		return true
	end
	adjust.Parent = ServerStorage
	Players.PlayerRemoving:Connect(function(player)
		local visit = X.visits[player]
		if visit then
			endVisit(visit)
		end
	end)
	X.startRegimen()
	X.startSweep()
	-- v239: server-side backstop for NoSit / custody walks - the seat weld is made
	-- by the server, so a player being walked is pulled straight back off any seat
	local function guardSeats(plr: Player)
		local function hook(char: Model)
			plr:SetAttribute("NoSit", nil) -- a fresh character is never mid-walk
			local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
			if not hum then
				return
			end
			hum:GetPropertyChangedSignal("SeatPart"):Connect(function()
				local seat = hum.SeatPart
				if seat and (plr:GetAttribute("NoSit") == true or plr:GetAttribute("CustodyAutoMove") == true) then
					task.defer(function()
						local weld = seat:FindFirstChild("SeatWeld")
						if weld then
							weld:Destroy()
						end
						hum.Sit = false
						hum.Jump = true
					end)
				end
			end)
		end
		if plr.Character then
			task.spawn(hook, plr.Character)
		end
		plr.CharacterAdded:Connect(hook)
	end
	for _, plr in Players:GetPlayers() do
		guardSeats(plr)
	end
	Players.PlayerAdded:Connect(guardSeats)
	X.startPopulation()
	print("[PrisonExtras] regimen, solitary, executions and visits online")
end

return X
