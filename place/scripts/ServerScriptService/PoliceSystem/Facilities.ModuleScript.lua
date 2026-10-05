--[[
	Facilities  (child ModuleScript of PoliceSystem)   v240

	One registry of every building mapped with the Facility Mapper plugin:
	  <Building>.FacilityMap        Police HQ, City Jail, Courthouse, law offices, Bank
	  CorrectionalFacility.PrisonMap  the state prison
	  Workspace.CityMap             city-wide points (dealers, stashes, news station ...)
	A building that isn't mapped simply isn't in the registry, so every caller keeps
	its old behaviour for it (the prison's own navigation still reads PrisonMap
	directly; nothing here changes how the prison works).

	MAP FORMAT (written by the plugin)
	  Zones/<Name>        Folder: ZoneType, Category, SecurityGroup, BottomY, TopY, Description
	                      + ControlPoints (polygon corners P001..)
	  DoorMarkers/<Name>  Folder: DoorType, Access, Description + Center (Part) + DoorObject (ObjectValue)
	  Routes/<Name>       Folder: RouteType, Bidirectional + ControlPoints (path, by Index)
	  Points/<Name>       Part:   PointType, Description
	  Seats               any Seat in the building with a SeatRole attribute

	API
	  F.refresh()                       re-read every map (also happens by itself when a map changes)
	  F.all() / F.ofType(type)          building records; type = PoliceHQ, CityJail, Courthouse,
	                                    LawOffice, Bank, Prison, City
	  F.get(type)                       first building of that type (nil = not mapped)
	  F.isMapped(type)
	  F.zones(type, zoneType, standIn?) zone records; standIn = also accept the stand-ins below
	  F.zone(type, zoneType, standIn?)  first of those
	  F.point(type, pointType, standIn?) -> Vector3?, CFrame?, how ("mapped" | "stand-in <x>")
	  F.points(type, pointType)         every mapped point record
	  F.seats(type, role)               seat records (role "JurorSeat" also matches JurorSeat1..12)
	  F.doors(type)                     door records
	  F.zoneAt(pos)                     -> zone, building  (smallest mapped zone containing pos)
	  F.describe(pos)                   "inside the police station lobby" ... or nil
	  F.missing(building)               checklist items still to map (same list as the plugin)
	  F.report()                        prints a summary per building to the Output
	All records are plain tables; zones have .center (Vector3 on the floor), .poly, .bottom, .top.

	STAND-INS (only when standIn = true): things a building doesn't have yet are taken
	from rooms it does have, e.g. Interrogation <- a "Room" called "Interview room",
	LegalVisit <- Interrogation, BookingDesk <- the BookingArea / Office / Lobby centre.
]]

local Workspace = game:GetService("Workspace")

local F = {}
F.VERSION = 240

local MAP_NAMES = { FacilityMap = true, PrisonMap = true }

-- friendly names for radio / notices
local LABEL = {
	PoliceHQ = "the police station", CityJail = "the city jail", Courthouse = "the courthouse",
	LawOffice = "the law office", Bank = "the bank", Prison = "the correctional facility", City = "the city",
}
local ZONE_LABEL = {
	SallyPort = "sally port", BookingArea = "booking area", HoldingCell = "holding cells", JailCell = "cells",
	Interrogation = "interview rooms", LegalVisit = "legal visit room", DayRoom = "day room", ReleaseArea = "release area",
	TransferHolding = "transfer holding", CourtHolding = "court holding", JuryRoom = "jury room",
	JudgeChambers = "judge's chambers", SecurityCheckpoint = "security checkpoint", CourtLobby = "lobby",
	MunicipalCourt = "municipal court", DepositVault = "deposit vault", BankLobby = "lobby", LockerRoom = "locker room",
}

-- a missing zone type can be stood in for by: other zone types, or rooms whose
-- name / description contains one of the words
local ZONE_STANDINS = {
	Interrogation = { words = { "interview", "interrog" } },
	LegalVisit = { types = { "Interrogation", "ContactVisit", "VisitPrisoner" }, words = { "legal", "lawyer", "attorney", "interview", "interrog" } },
	BookingArea = { words = { "booking", "intake", "process" }, types = { "SallyPort" } },
	HoldingCell = { types = { "JailCell", "IntakeCell", "BookingCell" }, words = { "holding", "cell" } },
	JailCell = { types = { "HoldingCell" }, words = { "cell" } },
	DayRoom = { words = { "day room", "dayroom", "cafeteria", "canteen", "common" }, types = { "Yard" } },
	ReleaseArea = { words = { "release", "exit" }, types = { "Lobby" } },
	TransferHolding = { words = { "transfer", "holding" }, types = { "HoldingCell", "SallyPort" } },
	CourtHolding = { types = { "HoldingCell" }, words = { "holding" } },
	Courtroom = { words = { "court" } },
	CourtLobby = { types = { "Lobby" } },
	Office = { types = { "Lobby" } },
}
-- a missing point can be stood in for by the centre of a zone
local POINT_STANDINS = {
	BookingDesk = { "BookingArea", "Office", "Lobby" },
	TurnInPoint = { "Lobby", "CourtLobby", "BankLobby" },
	FrontDesk = { "Lobby" },
	VehicleDropoff = { "SallyPort" },
	BusDeparture = { "SallyPort" },
	ReleasePoint = { "ReleaseArea", "Lobby" },
	MugshotSpot = { "BookingArea", "Office" },
	Reception = { "Lobby", "Office" },
	BailiffSpot = { "Courtroom", "MunicipalCourt" },
	ClerkWindow = { "CourtLobby", "Lobby" },
}

-- what the game needs per building (mirrors the plugin's "Check this facility")
local CHECKLIST = {
	PoliceHQ = {
		{ "zone", "SallyPort" }, { "zone", "BookingArea" }, { "zone", "HoldingCell" }, { "zone", "Interrogation" },
		{ "zone", "LegalVisit" }, { "zone", "Lobby" }, { "door", "", 1 },
		{ "point", "BookingDesk" }, { "point", "TurnInPoint" }, { "point", "VehicleDropoff" },
	},
	CityJail = {
		{ "zone", "SallyPort" }, { "zone", "BookingArea" }, { "zone", "JailCell", 4 }, { "zone", "DayRoom" },
		{ "zone", "ReleaseArea" }, { "zone", "TransferHolding" }, { "door", "", 1 },
		{ "point", "BookingDesk" }, { "point", "VehicleDropoff" }, { "point", "ReleasePoint" }, { "point", "BusDeparture" },
	},
	Courthouse = {
		{ "zone", "Courtroom" }, { "zone", "CourtHolding" }, { "zone", "JuryRoom" }, { "zone", "JudgeChambers" },
		{ "zone", "SecurityCheckpoint" }, { "zone", "CourtLobby" }, { "zone", "SallyPort" }, { "door", "", 1 },
		{ "seat", "JudgeSeat" }, { "seat", "DefendantSeat" }, { "seat", "DefenseSeat" }, { "seat", "ProsecutorSeat" },
		{ "seat", "WitnessSeat" }, { "seat", "JurorSeat", 12 }, { "seat", "GallerySeat" },
		{ "point", "BailiffSpot" }, { "point", "ClerkWindow" }, { "point", "MetalDetector" },
		{ "point", "VehicleDropoff" }, { "point", "CourthouseSteps" },
	},
	LawOffice = { { "firm" }, { "point", "Reception" }, { "seat", "LawyerSeat" }, { "seat", "ClientSeat" } },
	Bank = { { "zone", "DepositVault" }, { "door", "", 1 }, { "point", "DepositTerminal" }, { "point", "BoxWall" } },
	Prison = {
		{ "zone", "Interrogation" }, { "zone", "Courtroom" }, { "zone", "JuryRoom" }, { "zone", "GuardTower" },
		{ "zone", "KillZone" }, { "zone", "Perimeter" }, { "point", "BusBay" }, { "point", "PrisonPhone", 2 },
		{ "point", "SniperPost" }, { "point", "Spotlight" }, { "point", "BailiffSpot" },
		{ "seat", "JudgeSeat" }, { "seat", "DefendantSeat" }, { "seat", "JurorSeat", 12 },
	},
	City = {
		{ "point", "NewsStation" }, { "point", "BullionDealer" }, { "point", "StashSpot", 3 }, { "point", "DrugCorner", 3 },
		{ "point", "Bar" }, { "point", "Hospital" }, { "point", "ImpoundLot" }, { "point", "PrivateVaultSpot", 2 },
		{ "point", "FixerSpot", 2 }, { "point", "PlateMakerSpot", 3 }, { "point", "ShadyDealer" },
		{ "point", "ChopShop" }, { "point", "BailBondsOffice" },
	},
}

local buildings: { any } = {}
local dirty = true
local watched: { [Instance]: { RBXScriptConnection } } = {}

---------------------------------------------------------------------------
-- geometry
---------------------------------------------------------------------------
local function pointInPoly(x: number, z: number, poly: { Vector2 }): boolean
	local inside = false
	local n = #poly
	local j = n
	for i = 1, n do
		local a, b = poly[i], poly[j]
		if (a.Y > z) ~= (b.Y > z) then
			local xi = a.X + (z - a.Y) * (b.X - a.X) / (b.Y - a.Y)
			if x < xi then
				inside = not inside
			end
		end
		j = i
	end
	return inside
end

local function polyArea(poly: { Vector2 }): number
	local s = 0
	local n = #poly
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		s += a.X * b.Y - b.X * a.Y
	end
	return math.abs(s) / 2
end

local function sortedPoints(folder: Instance?): { BasePart }
	local list = {}
	if not folder then
		return list
	end
	for _, c in folder:GetChildren() do
		if c:IsA("BasePart") then
			table.insert(list, c)
		end
	end
	table.sort(list, function(a, b)
		local ia, ib = a:GetAttribute("Index"), b:GetAttribute("Index")
		if ia and ib then
			return ia < ib
		end
		return a.Name < b.Name
	end)
	return list
end

local function lower(s: any): string
	return string.lower(tostring(s or ""))
end

---------------------------------------------------------------------------
-- reading the maps
---------------------------------------------------------------------------
local function readZone(z: Instance, b: any): any?
	local pts = sortedPoints(z:FindFirstChild("ControlPoints"))
	if #pts < 3 then
		return nil
	end
	local poly = {}
	local sx, sz = 0, 0
	local minY = math.huge
	for _, p in pts do
		table.insert(poly, Vector2.new(p.Position.X, p.Position.Z))
		sx += p.Position.X
		sz += p.Position.Z
		minY = math.min(minY, p.Position.Y)
	end
	local bottom = tonumber(z:GetAttribute("BottomY")) or minY
	local top = tonumber(z:GetAttribute("TopY")) or (bottom + 20)
	return {
		instance = z,
		name = z.Name,
		zoneType = tostring(z:GetAttribute("ZoneType") or z:GetAttribute("Category") or "Room"),
		security = tostring(z:GetAttribute("SecurityGroup") or "General"),
		description = tostring(z:GetAttribute("Description") or ""),
		navIgnore = z:GetAttribute("NavIgnore") == true,
		poly = poly,
		area = polyArea(poly),
		bottom = bottom,
		top = top,
		center = Vector3.new(sx / #pts, bottom, sz / #pts),
		building = b,
	}
end

local function readDoor(m: Instance, b: any): any
	local center = m:FindFirstChild("Center")
	local ov = m:FindFirstChild("DoorObject")
	local pos = if center and center:IsA("BasePart") then center.Position
		else Vector3.new(tonumber(m:GetAttribute("CenterX")) or 0, tonumber(m:GetAttribute("CenterY")) or 0, tonumber(m:GetAttribute("CenterZ")) or 0)
	return {
		instance = m,
		name = m.Name,
		doorType = tostring(m:GetAttribute("DoorType") or "Normal"),
		access = tostring(m:GetAttribute("Access") or "Staff"),
		description = tostring(m:GetAttribute("Description") or ""),
		target = if ov and ov:IsA("ObjectValue") then ov.Value else nil,
		position = pos,
		building = b,
	}
end

local function readRoute(r: Instance, b: any): any?
	local pts = sortedPoints(r:FindFirstChild("ControlPoints"))
	if #pts < 2 then
		return nil
	end
	local path = {}
	for _, p in pts do
		table.insert(path, p.Position)
	end
	return {
		instance = r,
		name = r.Name,
		routeType = tostring(r:GetAttribute("RouteType") or "Walk"),
		bidirectional = r:GetAttribute("Bidirectional") ~= false,
		path = path,
		building = b,
	}
end

local function readPoint(p: Instance, b: any): any?
	if not p:IsA("BasePart") then
		return nil
	end
	return {
		instance = p,
		name = p.Name,
		pointType = tostring(p:GetAttribute("PointType") or p:GetAttribute("Category") or p.Name),
		description = tostring(p:GetAttribute("Description") or ""),
		cframe = p.CFrame,
		position = p.Position,
		building = b,
	}
end

local function facilityTypeOf(root: Instance, model: Instance): string
	local t = root:GetAttribute("FacilityType") or model:GetAttribute("FacilityType")
	if t then
		return tostring(t)
	end
	if root.Name == "PrisonMap" then
		return "Prison"
	elseif root.Name == "CityMap" then
		return "City"
	end
	return "Unknown"
end

local function readBuilding(root: Instance, model: Instance): any
	local ftype = facilityTypeOf(root, model)
	local b = {
		type = ftype,
		model = model,
		root = root,
		name = model.Name,
		firm = model:GetAttribute("Firm"),
		label = if model:GetAttribute("Firm") then tostring(model:GetAttribute("Firm")) else (LABEL[ftype] or model.Name),
		zones = {},
		doors = {},
		routes = {},
		points = {},
		seats = {},
	}
	local zf = root:FindFirstChild("Zones")
	if zf then
		for _, z in zf:GetChildren() do
			local rec = readZone(z, b)
			if rec then
				table.insert(b.zones, rec)
			end
		end
	end
	local df = root:FindFirstChild("DoorMarkers")
	if df then
		for _, m in df:GetChildren() do
			table.insert(b.doors, readDoor(m, b))
		end
	end
	local rf = root:FindFirstChild("Routes")
	if rf then
		for _, r in rf:GetChildren() do
			local rec = readRoute(r, b)
			if rec then
				table.insert(b.routes, rec)
			end
		end
	end
	local pf = root:FindFirstChild("Points")
	if pf then
		for _, p in pf:GetChildren() do
			local rec = readPoint(p, b)
			if rec then
				table.insert(b.points, rec)
			end
		end
	end
	-- seats live in the building itself (not in the map folder); the city has none
	if model ~= Workspace then
		for _, d in model:GetDescendants() do
			if (d:IsA("Seat") or d:IsA("VehicleSeat")) and d:GetAttribute("SeatRole") then
				table.insert(b.seats, { instance = d, role = tostring(d:GetAttribute("SeatRole")), position = d.Position, building = b })
			end
		end
	end
	return b
end

local function watch(inst: Instance)
	if watched[inst] then
		return
	end
	local function mark()
		dirty = true
	end
	watched[inst] = {
		inst.DescendantAdded:Connect(mark),
		inst.DescendantRemoving:Connect(mark),
		inst.AncestryChanged:Connect(function()
			dirty = true
			if not inst:IsDescendantOf(Workspace) then
				for _, c in watched[inst] or {} do
					c:Disconnect()
				end
				watched[inst] = nil
			end
		end),
	}
end

function F.refresh()
	dirty = false
	local list = {}
	for _, model in Workspace:GetChildren() do
		if model:IsA("Model") or model:IsA("Folder") then
			for _, c in model:GetChildren() do
				if c:IsA("Folder") and MAP_NAMES[c.Name] then
					table.insert(list, readBuilding(c, model))
					watch(c)
				end
			end
		end
	end
	local city = Workspace:FindFirstChild("CityMap")
	if city and city:IsA("Folder") then
		table.insert(list, readBuilding(city, Workspace))
		watch(city)
	end
	buildings = list
	return list
end

-- new buildings / maps appearing at runtime (the prison restores its map from a baked copy)
Workspace.ChildAdded:Connect(function(c)
	if c.Name == "CityMap" or c:GetAttribute("FacilityType") or c:FindFirstChild("FacilityMap") or c:FindFirstChild("PrisonMap") then
		dirty = true
	end
end)
for _, model in Workspace:GetChildren() do
	if model:GetAttribute("FacilityType") or model.Name == "CorrectionalFacility" then
		model.ChildAdded:Connect(function(c)
			if MAP_NAMES[c.Name] then
				dirty = true
			end
		end)
	end
end

local function current(): { any }
	if dirty then
		F.refresh()
	end
	return buildings
end

---------------------------------------------------------------------------
-- queries
---------------------------------------------------------------------------
function F.all(): { any }
	return current()
end

function F.ofType(ftype: string): { any }
	local out = {}
	for _, b in current() do
		if b.type == ftype then
			table.insert(out, b)
		end
	end
	return out
end

function F.get(ftype: string): any?
	return F.ofType(ftype)[1]
end

function F.isMapped(ftype: string): boolean
	local b = F.get(ftype)
	return b ~= nil and (#b.zones > 0 or #b.points > 0)
end

local function textHas(z: any, words: { string }?): boolean
	if not words then
		return false
	end
	local text = lower(z.name) .. " " .. lower(z.description)
	text = string.gsub(text, "_", " ")
	for _, w in words do
		if string.find(text, w, 1, true) then
			return true
		end
	end
	return false
end

local function zonesIn(list: { any }, zoneType: string, standIn: boolean?): { any }
	local out = {}
	for _, b in list do
		for _, z in b.zones do
			if z.zoneType == zoneType then
				table.insert(out, z)
			end
		end
	end
	if #out > 0 or not standIn then
		return out
	end
	local rule = ZONE_STANDINS[zoneType]
	if not rule then
		return out
	end
	-- generic rooms named like the thing first ("Interview room" -> Interrogation)
	-- (rooms before hallways: "Hallway to interview rooms" isn't the interview room)
	for _, generic in { { Room = true, Office = true }, { Hallway = true } } do
		for _, b in list do
			for _, z in b.zones do
				if generic[z.zoneType] and textHas(z, rule.words) then
					table.insert(out, z)
				end
			end
		end
		if #out > 0 then
			return out
		end
	end
	for _, t in rule.types or {} do
		out = zonesIn(list, t, true)
		if #out > 0 then
			return out
		end
	end
	return out
end

-- ftype may be a building type ("PoliceHQ") or a building record
local function scope(ftype: any): { any }
	if type(ftype) == "table" then
		return { ftype }
	end
	return F.ofType(ftype)
end

function F.zones(ftype: any, zoneType: string, standIn: boolean?): { any }
	return zonesIn(scope(ftype), zoneType, standIn)
end

function F.zone(ftype: any, zoneType: string, standIn: boolean?): any?
	return F.zones(ftype, zoneType, standIn)[1]
end

function F.points(ftype: any, pointType: string): { any }
	local out = {}
	for _, b in scope(ftype) do
		for _, p in b.points do
			if p.pointType == pointType then
				table.insert(out, p)
			end
		end
	end
	return out
end

-- -> position, cframe, how
function F.point(ftype: any, pointType: string, standIn: boolean?): (Vector3?, CFrame?, string?)
	local p = F.points(ftype, pointType)[1]
	if p then
		return p.position, p.cframe, "mapped"
	end
	if not standIn then
		return nil, nil, nil
	end
	-- the listed zone types in order, then the same list with zone stand-ins
	for pass = 1, 2 do
		for _, zt in POINT_STANDINS[pointType] or {} do
			local z = F.zone(ftype, zt, pass == 2)
			if z then
				local pos = z.center + Vector3.new(0, 3, 0)
				return pos, CFrame.new(pos), "stand-in " .. z.zoneType .. " " .. z.name
			end
		end
	end
	return nil, nil, nil
end

function F.seats(ftype: any, role: string): { any }
	local out = {}
	for _, b in scope(ftype) do
		for _, s in b.seats do
			if s.role == role or (role == "JurorSeat" and string.match(s.role, "^JurorSeat%d+$")) then
				table.insert(out, s)
			end
		end
	end
	if role == "JurorSeat" then
		table.sort(out, function(a, b)
			return (tonumber(string.match(a.role, "%d+")) or 0) < (tonumber(string.match(b.role, "%d+")) or 0)
		end)
	end
	return out
end

function F.doors(ftype: any): { any }
	local out = {}
	for _, b in scope(ftype) do
		for _, d in b.doors do
			table.insert(out, d)
		end
	end
	return out
end

function F.routes(ftype: any, routeType: string?): { any }
	local out = {}
	for _, b in scope(ftype) do
		for _, r in b.routes do
			if not routeType or r.routeType == routeType then
				table.insert(out, r)
			end
		end
	end
	return out
end

function F.inZone(z: any, pos: Vector3, tolerance: number?): boolean
	local tol = tolerance or 0
	if pos.Y < z.bottom - 3 - tol or pos.Y > z.top + tol then
		return false
	end
	return pointInPoly(pos.X, pos.Z, z.poly)
end

-- the smallest mapped zone containing pos (sniper / perimeter zones last)
-- v288i: is there ANY mapped zone at this spot (plan view, any height) or within `radius`?
-- (escape detection: on a roof inside the walls is still inside)
function F.anyZone2D(pos: Vector3, radius: number?): boolean
	local r = radius or 0
	local samples = { Vector3.zero }
	if r > 0 then
		for i = 0, 7 do
			local a = i * math.pi / 4
			table.insert(samples, Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
		end
	end
	for _, b in current() do
		for _, z in b.zones do
			for _, o in samples do
				if pointInPoly(pos.X + o.X, pos.Z + o.Z, z.poly) then return true end
			end
		end
	end
	return false
end

function F.zoneAt(pos: Vector3): (any?, any?)
	local best, bestArea = nil, math.huge
	for _, b in current() do
		for _, z in b.zones do
			if F.inZone(z, pos) then
				local area = z.area + (if z.navIgnore then 1e9 else 0)
				if area < bestArea then
					best, bestArea = z, area
				end
			end
		end
	end
	return best, best and best.building
end

function F.buildingAt(pos: Vector3): any?
	local _, b = F.zoneAt(pos)
	return b
end

-- "inside the police station sally port"; nil when pos isn't in a mapped zone
function F.describe(pos: Vector3): string?
	local z, b = F.zoneAt(pos)
	if not z or not b or b.type == "City" then
		return nil
	end
	local what = ZONE_LABEL[z.zoneType]
	if not what and z.zoneType ~= "Room" and z.zoneType ~= "Hallway" then
		what = string.lower(string.gsub(z.zoneType, "(%l)(%u)", "%1 %2"))
	end
	return if what then ("inside %s %s"):format(b.label, what) else ("inside %s"):format(b.label)
end

function F.missing(b: any): { string }
	local out = {}
	for _, item in CHECKLIST[b.type] or {} do
		local kind, what, need = item[1], item[2], item[3] or 1
		local have = 0
		if kind == "zone" then
			have = #zonesIn({ b }, what, false)
		elseif kind == "point" then
			have = #F.points(b, what)
		elseif kind == "seat" then
			have = #F.seats(b, what)
		elseif kind == "door" then
			have = #b.doors
			what = "doors"
		elseif kind == "firm" then
			have = if b.firm and tostring(b.firm) ~= "" then 1 else 0
			what = "firm name"
		end
		if have < need then
			local standIn = ""
			if kind == "zone" then
				local z = zonesIn({ b }, what, true)[1]
				if z then
					standIn = " (stand-in: " .. z.name .. ")"
				end
			elseif kind == "point" then
				local _, _, how = F.point(b, what, true)
				if how then
					standIn = " (" .. how .. ")"
				end
			end
			table.insert(out, (if need > 1 then ("%s %d/%d"):format(what, have, need) else what) .. standIn)
		end
	end
	return out
end

function F.report()
	local list = F.refresh()
	print(("[Facilities] v%d: %d mapped building(s)"):format(F.VERSION, #list))
	for _, b in list do
		local miss = F.missing(b)
		print(("[Facilities] %s %s%s: zones=%d doors=%d routes=%d points=%d seats=%d%s"):format(
			b.type, b.model:GetFullName(), if b.firm then (" (" .. tostring(b.firm) .. ")") else "",
			#b.zones, #b.doors, #b.routes, #b.points, #b.seats,
			if #miss > 0 then " | to map: " .. table.concat(miss, ", ") else " | complete"))
	end
	for _, t in { "PoliceHQ", "CityJail", "Courthouse", "LawOffice", "Bank" } do
		if #F.ofType(t) == 0 then
			print(("[Facilities] %s: not mapped (old behaviour)"):format(t))
		end
	end
end

return F
