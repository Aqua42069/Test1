--[[
	PrisonNavigation  (child ModuleScript of PoliceSystem)

	One navigation service for every correctional NPC: intake / booking / housing / medical
	/ release escorts, cop-only moves and guard patrols.

	THE GRAPH IS BUILT FROM YOUR PRISON MAP (CorrectionalFacility.PrisonMap) AT SERVER START:
	  Zones        each polygon zone -> an interior node (+ extra interior nodes for big zones)
	  Zone borders where two zones touch AND a ray at waist/head height passes the border,
	               a PORTAL node joins them (walls between touching zones are rejected)
	  DoorMarkers  -> DOOR node in the doorway + a side node on each side of the door
	               (the door's thin axis from the marker size). Crossing = side -> door -> side,
	               so "this route requires Door X" is known before anyone starts walking
	  Routes       your numbered control points (P001, P002 ... by Index) -> AUTHORITATIVE
	               edges, kept even if a ray check would disagree; merged into the network
	  Validation   every automatic edge must stay inside a zone polygon (or between a door
	               side and its zone) and pass raycasts; if a ray is blocked, a
	               PathfindingService check may still accept it (waypoints are stored)
	  Stairs       separate floors / islands are bridged with PathfindingService (STAIRS)

	HIERARCHY: the graph decides WHERE (A* over nodes); CopAI:moveTo / local pathfinding
	decides HOW to reach the NEXT node. Nobody pathfinds straight to the final destination.

	API
	  Nav.init(opts)                 opts = { Util, mapRoot(), facility, openDoor(target, secs),
	                                          openNear(pos, radius, secs)?, ignore = {Instance} }
	  Nav.build()                    (yields) builds / rebuilds the graph
	  Nav.getRoute(from, dest, o)    dest = Vector3 | destination name  -> route or nil, reason
	  Nav.travel(cop, dest, o)       walk a cop there (o.escortee = Player to escort)
	  Nav.escort(cop, player, dest, o)
	  Nav.escortAlong(cop, player, routeName, o)   follow one of your mapped routes
	  Nav.patrol(cop, zoneKey, alive)              loop: patrol an area (see Config.PatrolZones)
	  Nav.addDestination(name, pos)  Nav.destinations()  Nav.setDebug(on)

	DEBUG VIEW: set attribute NavDebug = true on CorrectionalFacility.PrisonMap (or
	workspace attribute PrisonNavDebug = true), in Studio or at runtime.
	  white = zone node, green = portal, orange = door, yellow = cell door, cyan = your route
	  points, purple = pathfind/stairs edge, RED = node not connected to the main network.
	  Active NPC routes are drawn in bright green while they walk.
]]

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Nav = {}
Nav.ready = false
Nav.building = false
-- Verified against the saved polygon footprints and DoorObject references.
local verifiedCellPairs = {
	["Intake_Main_3"] = {category="IntakeCell", door="Intake Cell Door", pos=Vector3.new(3982.662793,0.419257,-2120.124951)},
	["Intake_Main_4"] = {category="IntakeCell", door="Intake Cell", pos=Vector3.new(3981.762756,0.419258,-2109.699036)},
	["Intake_Main_5"] = {category="IntakeCell", door="Intake Cell_2", pos=Vector3.new(3981.703491,0.419258,-2100.219543)},
	["Intake_Main_6"] = {category="IntakeCell", door="Intake Cell_3", pos=Vector3.new(3981.800537,0.419257,-2090.728271)},
	["Intake_Main_7"] = {category="IntakeCell", door="Intake Cell_4", pos=Vector3.new(3981.705811,0.419258,-2081.220215)},
	["Intake_Main_8"] = {category="IntakeCell", door="Intake Cell_5", pos=Vector3.new(3981.748169,0.419258,-2071.672180)},
	["Intake_Main_9"] = {category="IntakeCell", door="Intake Cell_6", pos=Vector3.new(3981.762878,0.419258,-2062.252991)},
	["Intake_Main_10"] = {category="IntakeCell", door="Intake Cell_7", pos=Vector3.new(3981.760254,0.419258,-2052.745239)},
	["Booking_Cell_Zone"] = {category="BookingCell", door="Booking Cell 5", pos=Vector3.new(3954.092957,0.419273,-2120.172668)},
	["Booking_Cell_Zone_2"] = {category="BookingCell", door="Booking Cell 4", pos=Vector3.new(3954.105164,0.419273,-2107.588928)},
	["Booking_Cell_Zone_3"] = {category="BookingCell", door="Booking Cell 3", pos=Vector3.new(3954.106506,0.419274,-2092.088257)},
	["Booking_Cell_Zone_4"] = {category="BookingCell", door="Booking Cell 2", pos=Vector3.new(3953.949707,0.419273,-2079.453369)},
	["Booking_Cell_Zone_5"] = {category="BookingCell", door="Booking Cell 1", pos=Vector3.new(3954.005798,0.419273,-2066.871399)},
	["MEdium_Security"] = {category="MediumSecurity", door="Medium Security cell door", pos=Vector3.new(3990.404785,0.419288,-2270.781576)},
	["MEdium_Security_2"] = {category="MediumSecurity", door="Medium Security cell door_2", pos=Vector3.new(3990.387248,0.419288,-2282.418498)},
	["MEdium_Security_3"] = {category="MediumSecurity", door="Medium Security cell door_3", pos=Vector3.new(3990.376709,0.419288,-2294.163086)},
	["MEdium_Security_4"] = {category="MediumSecurity", door="Medium Security cell door_4", pos=Vector3.new(3990.428630,0.419288,-2305.880046)},
	["MEdium_Security_5"] = {category="MediumSecurity", door="Medium Security cell door_7", pos=Vector3.new(3990.406331,0.419273,-2235.359538)},
	["MEdium_Security_6"] = {category="MediumSecurity", door="Medium Security cell door_6", pos=Vector3.new(3990.378947,0.419273,-2247.056071)},
	["MEdium_Security_7"] = {category="MediumSecurity", door="Medium Security cell door_5", pos=Vector3.new(3990.398031,0.419273,-2258.759318)},
}


Nav.CellPairs = {}

local CFG = {
	FloorTolerance = 6, -- zones / markers within this height belong to the same floor
	ZoneSampleSpacing = 28, -- extra interior nodes in zones bigger than this
	PortalStep = 2,
	PortalTolerance = 2.5,
	PortalMinSpan = 3,
	PortalDoorClearance = 7, -- no open portal this close to a door marker (the door is the connection)
	DoorSideOffset = 2.8,
	DoorAttachRange = 6,
	RouteAttachRange = 12,
	MaxEdgeLength = 140,
	RayHeights = { 2.4, 4.3 },
	PathfindBudget = 180, -- PathfindingService validations during a build
	BridgeRange = 170,
	BridgeBudget = 500, -- v212: extra PathfindingService checks just for joining islands (stairs)
	ArriveRadius = 3,
	DoorArriveRadius = 2.4,
	DoorLead = 14, -- start opening a door this far before it
	DoorOpenSecs = 5,
	DoorClearance = 0.5, -- wait this long after opening before stepping through
	FollowGap = 9, -- escort waits if the prisoner is further behind than this
	StuckRetry = 3.5,
	StuckLocal = 7,
	StuckReroute = 12,
	MaxReroutes = 3,
	BlockedEdgePenalty = 60,
	BlockedEdgeTime = 60,
	FinalRecovery = 20, -- tiny final reposition allowed within this of the goal when stuck
	-- guard patrol areas; guards are assigned round-robin
	PatrolZones = { "MEDIUM_SECURITY", "INTAKE", "BOOKING", "MAXIMUM_SECURITY", "LOW_SECURITY", "PERIMETER" },
	PatrolAreas = {
		MEDIUM_SECURITY = { "MEDIUM_SECURITY", "COMMON" },
		MAXIMUM_SECURITY = { "MAXIMUM_SECURITY" },
		LOW_SECURITY = { "LOW_SECURITY", "COMMON" },
		INTAKE = { "INTAKE" },
		BOOKING = { "BOOKING" },
		PERIMETER = { "CORRIDOR", "PUBLIC" },
	},
	PatrolPause = { 1.2, 3.5 },
}
Nav.Config = CFG

local opts: any = nil
local Util: any = nil

local nodes: { any } = {}
local zones: { any } = {}
local zoneByName: { [string]: any } = {}
local doorNodes: { any } = {}
local routes: { [string]: { number } } = {}
local routeMeta: { [string]: any } = {}
local destinations: { [string]: { number } } = {}
local extraDest: { [string]: Vector3 } = {}
local componentOf: { [number]: number } = {}
local mainComponent = 0
local blocked: { [string]: number } = {}
local report: any = {}
local patrolClaims: { [number]: any } = {}

local function log(fmt: string, ...)
	print("[PrisonNav] " .. string.format(fmt, ...))
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

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

local function segDist(px: number, pz: number, a: Vector2, b: Vector2): number
	local dx, dz = b.X - a.X, b.Y - a.Y
	local L2 = dx * dx + dz * dz
	local t = 0
	if L2 > 1e-6 then
		t = math.clamp(((px - a.X) * dx + (pz - a.Y) * dz) / L2, 0, 1)
	end
	local qx, qz = a.X + dx * t, a.Y + dz * t
	return math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
end

local function polyDist(x: number, z: number, poly: { Vector2 }): number
	if pointInPoly(x, z, poly) then
		return 0
	end
	local best = math.huge
	for i = 1, #poly do
		best = math.min(best, segDist(x, z, poly[i], poly[i % #poly + 1]))
	end
	return best
end

local function edgeDist(x: number, z: number, poly: { Vector2 }): number
	local best = math.huge
	for i = 1, #poly do
		best = math.min(best, segDist(x, z, poly[i], poly[i % #poly + 1]))
	end
	return best
end

local function polyArea(poly: { Vector2 }): number
	local a = 0
	for i = 1, #poly do
		local p, q = poly[i], poly[i % #poly + 1]
		a += p.X * q.Y - q.X * p.Y
	end
	return math.abs(a) / 2
end

-- segment stays inside (or hugging the border of) any of the given polygons
local function segmentInside(a: Vector3, b: Vector3, polys: { { Vector2 } }): boolean
	local len = flat(b - a).Magnitude
	local n = math.max(2, math.ceil(len / 3))
	for i = 0, n do
		local p = a:Lerp(b, i / n)
		local ok = false
		for _, poly in polys do
			if polyDist(p.X, p.Z, poly) <= CFG.PortalTolerance + 0.6 then -- hand-drawn zones rarely touch exactly
				ok = true
				break
			end
		end
		if not ok then
			return false
		end
	end
	return true
end

---------------------------------------------------------------------------
-- raycast validation (closed doors, NPCs, characters, the map itself are ignored;
-- non-collidable parts are ignored)
---------------------------------------------------------------------------
local rayParams: RaycastParams? = nil
local function buildRayParams()
	local list: { Instance } = {}
	local map = opts.mapRoot and opts.mapRoot()
	if map then
		table.insert(list, map)
	end
	-- Closed door geometry is not excluded: only explicit DOOR edges cross it.
	for _, inst in opts.ignore or {} do
		table.insert(list, inst)
	end
	for _, plr in game:GetService("Players"):GetPlayers() do
		if plr.Character then
			table.insert(list, plr.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	pcall(function()
		params.RespectCanCollide = true
	end)
	rayParams = params
end

local function rayClear(a: Vector3, b: Vector3): boolean
	for _, h in CFG.RayHeights do
		local from = a + Vector3.new(0, h, 0)
		local to = b + Vector3.new(0, h, 0)
		local hit = Workspace:Raycast(from, to - from, rayParams)
		if hit then
			return false
		end
	end
	return true
end

local pathfindUsed = 0
local function pathfindCheck(a: Vector3, b: Vector3, maxFactor: number, extraBudget: number?, stairSlack: number?): { Vector3 }?
	if pathfindUsed >= CFG.PathfindBudget + (extraBudget or 0) then
		return nil
	end
	pathfindUsed += 1
	local path = PathfindingService:CreatePath({ AgentRadius = 1.8, AgentHeight = 5, AgentCanJump = false, WaypointSpacing = 4 })
	local ok = pcall(function()
		path:ComputeAsync(a + Vector3.new(0, 2.5, 0), b + Vector3.new(0, 2.5, 0))
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		return nil
	end
	local wps = path:GetWaypoints()
	local len = 0
	local pts = {}
	for i, wp in wps do
		table.insert(pts, wp.Position)
		if i > 1 then
			len += (wp.Position - wps[i - 1].Position).Magnitude
		end
	end
	local straight = (b - a).Magnitude
	-- v212: a staircase is always far longer than the drop between floors
	local slack = if math.abs(a.Y - b.Y) > 4 then (stairSlack or 25) else 25
	if len > math.max(straight * maxFactor, straight + slack) then
		return nil
	end
	return pts
end

---------------------------------------------------------------------------
-- graph primitives
---------------------------------------------------------------------------
-- All callers supply mapped FLOOR positions. Preserve their storey; a cast
-- starting above a cell can hit its ceiling or the next floor instead.
local function ground(pos: Vector3): Vector3
	return pos
end

function Nav.doorFloor(marker: Instance): Vector3?
	local center=marker:FindFirstChild("Center")
	local p=if center and center:IsA("BasePart") then center.Position else nil
	if not p then
		local x,y,z=tonumber(marker:GetAttribute("CenterX")),tonumber(marker:GetAttribute("CenterY")),tonumber(marker:GetAttribute("CenterZ"))
		if not x or not y or not z then return nil end
		p=Vector3.new(x,y,z)
	end
	local height=tonumber(marker:GetAttribute("SizeY")) or (center and center:IsA("BasePart") and center.Size.Y)
	if not height then return nil end
	return Vector3.new(p.X,p.Y-height/2,p.Z)
end

local function addNode(pos: Vector3, kind: string, meta: any?): number
	local id = #nodes + 1
	local n = meta or {}
	n.id = id
	n.pos = pos
	n.kind = kind
	n.edges = {}
	n.zones = n.zones or {}
	nodes[id] = n
	return id
end

local function edgeKey(a: number, b: number): string
	return if a < b then a .. ":" .. b else b .. ":" .. a
end

local function hasEdge(a: number, b: number): boolean
	for _, e in nodes[a].edges do
		if e.to == b then
			return true
		end
	end
	return false
end

local function addEdge(a: number, b: number, kind: string, extra: any?, oneWay: boolean?)
	if a == b or hasEdge(a, b) then
		return
	end
	local na, nb = nodes[a], nodes[b]
	local cost = (na.pos - nb.pos).Magnitude
	local e = { to = b, cost = cost, kind = kind }
	if extra then
		for k, v in extra do
			e[k] = v
		end
	end
	table.insert(na.edges, e)
	if not oneWay then
		local r = { to = a, cost = cost, kind = kind }
		if extra then
			for k, v in extra do
				r[k] = v
			end
			if e.waypoints then
				local rev = {}
				for i = #e.waypoints, 1, -1 do
					table.insert(rev, e.waypoints[i])
				end
				r.waypoints = rev
			end
		end
		table.insert(nb.edges, r)
	end
	report[kind] = (report[kind] or 0) + 1
end

-- try to connect two nodes that share an area
local function tryConnect(a: number, b: number, polys: { { Vector2 } }?, kind: string?)
	if a == b or hasEdge(a, b) then
		return
	end
	local pa, pb = nodes[a].pos, nodes[b].pos
	if (pa - pb).Magnitude > CFG.MaxEdgeLength or math.abs(pa.Y - pb.Y) > CFG.FloorTolerance then
		return
	end
	if polys and not segmentInside(pa, pb, polys) then
		return
	end
	if rayClear(pa, pb) then
		addEdge(a, b, kind or "AREA")
		return
	end
	local wps = pathfindCheck(pa, pb, 1.6)
	if wps then
		addEdge(a, b, "PATHFIND", { waypoints = wps })
	end
end

---------------------------------------------------------------------------
-- classification
---------------------------------------------------------------------------
local function normKey(name: string): string
	local s = string.upper(name)
	s = string.gsub(s, "[^%w]+", "_")
	s = string.gsub(s, "_%d+$", "")
	s = string.gsub(s, "^_+", "")
	s = string.gsub(s, "_+$", "")
	return s
end

local function areaOf(name: string): string
	local n = string.lower(name)
	-- v212: the expanded prison's shared spaces (matched on the zone's own name)
	if string.find(n, "^indoor_yard") then
		return "INDOOR_YARD"
	elseif string.find(n, "^yard") then
		return "YARD"
	elseif string.find(n, "^cafeteria") then
		return "CAFETERIA"
	elseif string.find(n, "^solitary_block") then
		return "SOLITARY"
	elseif string.find(n, "^supermax_cellblock") then
		return "SUPERMAX"
	elseif string.find(n, "^longterm_holding_cellblock") or string.find(n, "^overflow_holding_cellblock") then
		return "HOLDING"
	elseif string.find(n, "^walkway area outside of death row") then
		return "DEATH_ROW"
	elseif string.find(n, "tower", 1, true) then
		return "TOWER"
	elseif string.find(n, "medium", 1, true) then
		return "MEDIUM_SECURITY"
	elseif string.find(n, "high_security", 1, true) or string.find(n, "maximum", 1, true) or string.find(n, "supermax", 1, true) then
		return "MAXIMUM_SECURITY"
	elseif string.find(n, "low_security", 1, true) then
		return "LOW_SECURITY"
	elseif string.find(n, "medical", 1, true) or string.find(n, "infirm", 1, true) then
		return "MEDICAL"
	elseif string.find(n, "booking", 1, true) or string.find(n, "dress", 1, true) then
		return "BOOKING"
	elseif string.find(n, "hallway_to_intake", 1, true) then
		return "PUBLIC"
	elseif string.find(n, "intake", 1, true) or string.find(n, "transfer", 1, true) then
		return "INTAKE"
	elseif string.find(n, "inmate", 1, true) or string.find(n, "prisoner", 1, true) or string.find(n, "guard_only", 1, true) then
		return "COMMON"
	elseif string.find(n, "lobby", 1, true) or string.find(n, "visit", 1, true) or string.find(n, "guard_post", 1, true) then
		return "PUBLIC"
	end
	return "CORRIDOR"
end

local function isCellName(name: string): boolean
	local n = "_" .. string.gsub(string.lower(name), "[^%w]+", "_") .. "_"
    for _,word in {"area", "outside", "transfer", "leads", "common", "hallway", "walkway", "lobby"} do
        if string.find(n,word,1,true) then return false end
    end
	-- v192: also the authored misspellings ("Cellbock", "Cellblok") and visit rooms;
	-- "High sEcuirty Cellbock Door" read as a CELL door and sealed the whole block.
	for _, word in { "cellblock", "cell_block", "cellbock", "cellblok", "cellbloc", "visit" } do
		if string.find(n, word, 1, true) then
			return false
		end
	end
	-- corridors / doors that merely lead TO cells are not cells
	for _, word in { "_to_", "outside", "hallway", "corridor", "leads", "transfer", "area" } do
		if string.find(n, word, 1, true) then
			return false
		end
	end
	return string.find(n, "cell", 1, true) ~= nil
end

---------------------------------------------------------------------------
-- import
---------------------------------------------------------------------------
local function sortedChildren(folder: Instance): { Instance }
	local list = folder:GetChildren()
	table.sort(list, function(a, b)
		local ia = tonumber(a:GetAttribute("Index"))
		local ib = tonumber(b:GetAttribute("Index"))
		if ia and ib and ia ~= ib then
			return ia < ib
		end
		return a.Name < b.Name
	end)
	return list
end

-- Reconcile the verified legacy pairs with the actual authored geometry. Missing
-- rooms/door links never count as capacity; explicitly mapped additions can join.
function Nav.refreshCellPairs(map: Instance)
    table.clear(Nav.CellPairs)
    local folder=map:FindFirstChild("Zones")
    local doors=map:FindFirstChild("DoorMarkers")
    if not folder or not doors then return end
    local used={}
    local function footprint(zone)
        local cp=zone:FindFirstChild("ControlPoints");local poly={};local sum=Vector3.zero
        if cp then for _,v in sortedChildren(cp) do
            local p=if v:IsA("Vector3Value") then v.Value elseif v:IsA("BasePart") then v.Position else nil
            if p then table.insert(poly,Vector2.new(p.X,p.Z));sum+=p end
        end end
        return poly,if #poly>0 then sum/#poly else nil
    end
    local function target(marker)
        local ref=marker and marker:FindFirstChild("DoorObject")
        return ref and ref:IsA("ObjectValue") and ref.Value and ref.Value.Parent and ref.Value or nil
    end
    local function register(zone,category,marker,pos)
        local obj=target(marker)
        if not obj or (used[obj] and (category=="IntakeCell" or category=="BookingCell")) then return false end
        if category=="IntakeCell" or category=="BookingCell" then used[obj]=true end
        -- v201: capacity from the zone ("Low Security Cell 4 inmates") or a
        -- Capacity attribute; a cell whose paired door is not on its own edge
        -- (low security: the cellblock entrance) is an OPEN cell - no door.
        local desc=tostring(zone:GetAttribute("ZoneType") or "")
        local capacity=tonumber(zone:GetAttribute("Capacity")) or tonumber(string.match(string.lower(desc),"(%d+)%s*inmate")) or 1
        local poly=footprint(zone)
        local dp=Nav.doorFloor(marker)
        local open=category=="LowSecurity" -- v204: only low security cells are doorless
        Nav.CellPairs[zone.Name]={category=category,door=marker.Name,pos=pos,capacity=math.max(1,capacity),open=open}
        return true
    end
    for name,pair in verifiedCellPairs do
        local zone=folder:FindFirstChild(name);local marker=doors:FindFirstChild(pair.door)
        if zone and marker then
            local poly,center=footprint(zone)
            if #poly>=3 and center and pointInPoly(pair.pos.X,pair.pos.Z,poly) then
                register(zone,pair.category,marker,Vector3.new(pair.pos.X,center.Y,pair.pos.Z))
            end
        end
    end
    for _,zone in folder:GetChildren() do
        if Nav.CellPairs[zone.Name] or zone:GetAttribute("NavIgnore")==true then continue end
        local name=string.lower(zone.Name.." "..tostring(zone:GetAttribute("ZoneType") or ""))
        local passage=false
        for _,word in {"area","outside","transfer","leads","common","block","hall","walk","lobby"} do
            if string.find(name,word,1,true) then passage=true end
        end
        if passage then continue end
        local explicit=zone:GetAttribute("Category")
        local category=if type(explicit)=="string" and explicit~="" then explicit
            elseif string.find(name,"intake",1,true) and string.find(name,"cell",1,true) then "IntakeCell"
            elseif string.find(name,"booking",1,true) and string.find(name,"cell",1,true) then "BookingCell" else nil
        -- v212: the expanded prison (solitary, supermax, maximum, holding,
        -- execution and visiting rooms)
        if not category then
            if string.find(name,"solitary",1,true) and string.find(name,"cell",1,true) then category="Solitary"
            elseif string.find(name,"supermax",1,true) and string.find(name,"cell",1,true) then category="Supermax"
            elseif string.find(name,"maximum",1,true) and string.find(name,"cell",1,true) then category="MaximumSecurity"
            elseif (string.find(name,"longterm",1,true) or string.find(name,"long_term",1,true)) and string.find(name,"cell",1,true) then category="LongTermHolding"
            elseif string.find(name,"overflow",1,true) and string.find(name,"cell",1,true) then category="OverflowHolding"
            elseif string.find(name,"execution",1,true) then category="ExecutionRoom"
            elseif string.find(name,"contact visit",1,true) then category="ContactVisit"
            elseif string.find(name,"visiting_room",1,true) then category="VisitPrisoner"
            elseif string.find(name,"visitng_room",1,true) or string.find(name,"visitor side",1,true) then category="VisitVisitor" end
        end
        if not category and string.find(name,"cell",1,true) then
            if string.find(name,"death",1,true) then category="DeathRow"
            elseif string.find(name,"high",1,true) then category="HighSecurity"
            elseif string.find(name,"medium",1,true) then category="MediumSecurity"
            elseif string.find(name,"low",1,true) then category="LowSecurity" end
        end
        if not category then continue end
        local poly,center=footprint(zone)
        if #poly<3 or not center or not pointInPoly(center.X,center.Z,poly) then continue end
        local chosen,best=nil,math.huge
        local maxDoorRange=if category=="LowSecurity" then 90 else 16
        for _,marker in doors:GetChildren() do
            local obj=target(marker);local dp=Nav.doorFloor(marker)
            local lowAccess=category=="LowSecurity" and string.find(string.lower(marker.Name),"low",1,true)~=nil
            local floorMatches=dp and math.abs(dp.Y-center.Y)<(if category=="LowSecurity" then 18 else 3)
            -- the contact visit room has a visitor door too; inmates use the other one
            local visitorDoor=category=="ContactVisit" and (string.find(string.lower(marker.Name),"vistiro",1,true) or string.find(string.lower(marker.Name),"visitor",1,true))
            if obj and not visitorDoor and (not used[obj] or category=="LowSecurity" or category=="HighSecurity" or category=="DeathRow") and floorMatches and (category~="LowSecurity" or lowAccess) then
                local edge=edgeDist(dp.X,dp.Z,poly)
                local distance=flat(dp-center).Magnitude
                local acceptable=if category=="LowSecurity" then edge<90 and distance<maxDoorRange else edge<2 and distance<maxDoorRange
                if acceptable and distance<best then chosen=marker;best=distance end
            end
        end
        -- v212: a cell whose own door isn't mapped (Supermax_Cell_10) uses the
        -- nearest door of its kind on the same floor
        if not chosen then
            local family=if category=="Supermax" then "super max" elseif category=="Solitary" then "solitary" else nil
            for _,marker in (if family then doors:GetChildren() else {}) do
                local dp=Nav.doorFloor(marker)
                if target(marker) and dp and math.abs(dp.Y-center.Y)<3 and string.find(string.lower(marker.Name),family,1,true) then
                    local distance=flat(dp-center).Magnitude
                    if distance<24 and distance<best then chosen=marker;best=distance end
                end
            end
        end
        if chosen then register(zone,category,chosen,center) end
    end
    -- v212: holding cells take a group; solitary / execution / visits one each
    for _,pair in Nav.CellPairs do
        if pair.category=="LongTermHolding" or pair.category=="OverflowHolding" then pair.capacity=math.max(pair.capacity or 1,4) end
    end
    -- v212: supermax cells sit behind a second (outer) barred door
    for name,pair in Nav.CellPairs do
        if pair.category~="Supermax" then continue end
        local inner=doors:FindFirstChild(pair.door)
        local ip=inner and Nav.doorFloor(inner)
        if not ip then continue end
        if string.find(string.lower(pair.door),"outer",1,true) then continue end
        local bestOuter,bestD=nil,14
        for _,marker in doors:GetChildren() do
            local dp=Nav.doorFloor(marker)
            if dp and string.find(string.lower(marker.Name),"outer",1,true) and math.abs(dp.Y-ip.Y)<3 then
                local d=flat(dp-ip).Magnitude
                if d<bestD then bestOuter,bestD=marker,d end
            end
        end
        if bestOuter then pair.outer=bestOuter.Name end
    end
    local counts={}
    for _,pair in Nav.CellPairs do counts[pair.category]=(counts[pair.category] or 0)+1 end
    local parts={}
    for category,n in counts do table.insert(parts,category.."="..n) end
    table.sort(parts)
    print("[PrisonNav] cell pairs: "..table.concat(parts," "))
end

local function importZones(map: Instance)
	local folder = map:FindFirstChild("Zones")
	if not folder then
		return
	end
	for _, zm in folder:GetChildren() do
		local cp = zm:FindFirstChild("ControlPoints")
		-- v238: sniper zones (kill zone between the fences, perimeter) aren't walkable areas
		if zm:GetAttribute("NavIgnore") == true then
			cp = nil
		end
		if cp then
			local poly, ysum, count = {}, 0, 0
			for _, v in sortedChildren(cp) do
				local p: Vector3? = nil
				if v:IsA("Vector3Value") then
					p = v.Value
				elseif v:IsA("BasePart") then
					p = v.Position
				end
				if p then
					table.insert(poly, Vector2.new(p.X, p.Z))
					ysum += p.Y
					count += 1
				end
			end
			if #poly >= 3 then
				local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
				for _, q in poly do
					minX, minZ = math.min(minX, q.X), math.min(minZ, q.Y)
					maxX, maxZ = math.max(maxX, q.X), math.max(maxZ, q.Y)
				end
				local z = {
					name = zm.Name,
					inst = zm,
					poly = poly,
					y = ysum / count,
					key = normKey(zm.Name),
					area = areaOf(zm.Name .. " " .. tostring(zm:GetAttribute("ZoneType") or "")),
					cell = Nav.CellPairs[zm.Name] ~= nil or isCellName(zm.Name .. " " .. tostring(zm:GetAttribute("ZoneType") or "")),
					size = polyArea(poly),
					bbox = { minX, minZ, maxX, maxZ },
					members = {},
				}
				table.insert(zones, z)
				zoneByName[zm.Name] = z
			end
		end
	end
end

local function zoneAt(pos: Vector3, tolerance: number?): any?
	local best, bestD = nil, math.huge
	for _, z in zones do
		if math.abs(z.y - pos.Y) <= CFG.FloorTolerance then
			local d = polyDist(pos.X, pos.Z, z.poly)
			if d <= (tolerance or 0) and d < bestD then
				best, bestD = z, d
			end
		end
	end
	return best
end
Nav.zoneAt = zoneAt

local function joinZone(z: any, id: number)
	if not table.find(z.members, id) then
		table.insert(z.members, id)
	end
	local n = nodes[id]
	if not table.find(n.zones, z) then
		table.insert(n.zones, z)
	end
	if not n.zone then
		n.zone = z
	end
end

-- interior node(s) for each zone
local function zoneInteriorNodes()
	for _, z in zones do
		local cx, cz = 0, 0
		for _, p in z.poly do
			cx += p.X
			cz += p.Y
		end
		cx /= #z.poly
		cz /= #z.poly
		local best, bestScore = nil, -math.huge
		if pointInPoly(cx, cz, z.poly) then
			best = Vector2.new(cx, cz)
		else
			-- concave: best-clearance grid sample inside the polygon
			local b = z.bbox
			local step = math.max(1.5, math.max(b[3] - b[1], b[4] - b[2]) / 14)
			for x = b[1], b[3], step do
				for zz = b[2], b[4], step do
					if pointInPoly(x, zz, z.poly) then
						local s = edgeDist(x, zz, z.poly)
						if s > bestScore then
							bestScore, best = s, Vector2.new(x, zz)
						end
					end
				end
			end
		end
		if best then
			local id = addNode(ground(Vector3.new(best.X, z.y, best.Y)), if z.cell then "CELL" else "AREA", { name = z.name })
			joinZone(z, id)
			z.center = id
		end
		-- big or concave (L-shaped...) zones get extra interior nodes so every part of
		-- the zone can be reached along lines that stay inside it
		local b = z.bbox
		local concave = false
		do
			local sign = 0
			local np = #z.poly
			for k = 1, np do
				local p0, p1, p2 = z.poly[k], z.poly[k % np + 1], z.poly[(k + 1) % np + 1]
				local cross = (p1.X - p0.X) * (p2.Y - p1.Y) - (p1.Y - p0.Y) * (p2.X - p1.X)
				if math.abs(cross) > 1e-3 then
					local sg = if cross > 0 then 1 else -1
					if sign == 0 then
						sign = sg
					elseif sg ~= sign then
						concave = true
						break
					end
				end
			end
		end
		z.concave = concave
		local sp = if concave then math.max(7, math.max(b[3] - b[1], b[4] - b[2]) / 6) else CFG.ZoneSampleSpacing
		if concave or (b[3] - b[1]) > sp * 1.4 or (b[4] - b[2]) > sp * 1.4 then
			for x = b[1] + sp / 2, b[3], sp do
				for zz = b[2] + sp / 2, b[4], sp do
					if pointInPoly(x, zz, z.poly) and edgeDist(x, zz, z.poly) >= 2.5 then
						local p = Vector3.new(x, z.y, zz)
						if not z.center or (nodes[z.center].pos - p).Magnitude > sp * 0.5 then
							local id = addNode(ground(p), "AREA", { name = z.name })
							joinZone(z, id)
						end
					end
				end
			end
		end
	end
end

local function doorNear(pos: Vector3, range: number): any?
	for _, d in doorNodes do
		if flat(nodes[d.id].pos - pos).Magnitude <= range and math.abs(nodes[d.id].pos.Y - pos.Y) <= CFG.FloorTolerance then
			return d
		end
	end
	return nil
end

local function importDoors(map: Instance)
	local folder = map:FindFirstChild("DoorMarkers")
	if not folder then
		return
	end
	for _, marker in folder:GetChildren() do
		local center = marker:FindFirstChild("Center")
		local ov = marker:FindFirstChild("DoorObject")
		local target = ov and ov:IsA("ObjectValue") and ov.Value or nil
		local cf: CFrame? = nil
		local size: Vector3? = nil
		if center and center:IsA("BasePart") then
			cf = center.CFrame
			size = center.Size
		else
			local x, y, z = tonumber(marker:GetAttribute("CenterX")), tonumber(marker:GetAttribute("CenterY")), tonumber(marker:GetAttribute("CenterZ"))
			if x and y and z then
				cf = CFrame.new(x, y, z)
			end
		end
		if cf then
			local sx = tonumber(marker:GetAttribute("SizeX")) or (size and size.X) or 1
			local sz = tonumber(marker:GetAttribute("SizeZ")) or (size and size.Z) or 4
			local floor = Nav.doorFloor(marker)
			if not floor then continue end
			-- the door's thin axis is the direction you walk through it. The marker size gives
			-- a first guess; the axis whose two sides land in two DIFFERENT zones wins (robust
			-- against rotated / resized marker parts).
			local guess = flat(if sx <= sz then cf.RightVector else cf.LookVector)
			guess = if guess.Magnitude > 0.1 then guess.Unit else Vector3.xAxis
			local other = Vector3.new(-guess.Z, 0, guess.X)
			local function sideScore(axis: Vector3): number
				local za = zoneAt(floor + axis * CFG.DoorSideOffset, CFG.DoorAttachRange * 0.5)
				local zb = zoneAt(floor - axis * CFG.DoorSideOffset, CFG.DoorAttachRange * 0.5)
				local score = (if za then 1 else 0) + (if zb then 1 else 0)
				if za and zb and za ~= zb then
					score += 2
				end
				return score
			end
			local through = if sideScore(other) > sideScore(guess) then other else guess
			local lname = string.lower(marker.Name)
            local kind = if string.find(lname, "exterior", 1, true) then "EXTERIOR_DOOR" elseif isCellName(marker.Name) then "CELL_DOOR" else "DOOR"
			local id = addNode(floor, kind, { name = marker.Name, marker = marker, target = target })
			local sides = {}
			for _, s in { 1, -1 } do
				local sp = ground(floor + through * CFG.DoorSideOffset * s)
				local sid = addNode(sp, "DOOR_SIDE", { name = marker.Name .. (if s > 0 then " +" else " -"), doorId = id })
				addEdge(sid, id, "DOOR", { door = id })
				table.insert(sides, sid)
			end
			local d = { id = id, marker = marker, target = target, sides = sides, name = marker.Name, kind = kind }
			nodes[id].door = d
			table.insert(doorNodes, d)
		end
	end
end

local function attachDoors()
	for _, d in doorNodes do
		for _, sid in d.sides do
			local sp = nodes[sid].pos
			local z = zoneAt(sp, CFG.DoorAttachRange)
			if z then
				joinZone(z, sid)
			end
		end
		d.zones = {}
		for _, sid in d.sides do
			for _, z in nodes[sid].zones do
				table.insert(d.zones, z)
			end
		end
		-- v192: evidence beats names the other way too. A "cell door" with no cell
		-- on either side is a corridor/cellblock door (typo'd names like
		-- "Cellbock"): as CELL_DOOR the route search refused to pass it.
		if d.kind == "CELL_DOOR" and #d.zones > 0 then
			local anyCell = false
			for _, z in d.zones do
				if z.cell or Nav.CellPairs[z.name] then anyCell = true end
			end
			if not anyCell then
				d.kind = "DOOR"
				nodes[d.id].kind = "DOOR"
				log("door %s has no cell behind it: treated as a passage door", d.name)
			end
		end
		-- evidence beats names: a small room behind a cell door IS a cell
		if d.kind == "CELL_DOOR" then
			for _, z in d.zones do
				if Nav.CellPairs[z.name] then
					z.cell = true
					if z.center and nodes[z.center].kind == "AREA" then
						nodes[z.center].kind = "CELL"
					end
				end
			end
		end
	end
end

local function importRoutes(map: Instance)
	local folder = map:FindFirstChild("Routes")
	if not folder then
		return
	end
	for _, route in folder:GetChildren() do
		local cp = route:FindFirstChild("ControlPoints")
		if cp then
			local ids = {}
			for _, p in sortedChildren(cp) do
				if p:IsA("BasePart") then
					local id = addNode(p.Position, "ROUTE", { name = route.Name .. " " .. p.Name, route = route.Name, wait = tonumber(p:GetAttribute("WaitSeconds")) })
					table.insert(ids, id)
				end
			end
			if #ids >= 2 then
				local oneWay = route:GetAttribute("Bidirectional") == false
				for i = 1, #ids - 1 do
					-- authoritative, plus: which door does this leg pass through?
					local a, b = nodes[ids[i]].pos, nodes[ids[i + 1]].pos
					local via = nil
					for _, d in doorNodes do
						local dp = nodes[d.id].pos
						if math.abs(dp.Y - a.Y) <= CFG.FloorTolerance and segDist(dp.X, dp.Z, Vector2.new(a.X, a.Z), Vector2.new(b.X, b.Z)) <= 3 then
							via = d.id
							break
						end
					end
					addEdge(ids[i], ids[i + 1], "ROUTE", { door = via }, oneWay)
				end
				routes[route.Name] = ids
				routeMeta[route.Name] = { oneWay = oneWay, speed = tonumber(route:GetAttribute("DefaultSpeed")) }
				for _, id in ids do
					local z = zoneAt(nodes[id].pos, 2)
					if z then
						joinZone(z, id)
					end
				end
			end
		end
	end
end

-- open borders between touching zones (walls rejected by raycasts)
local function buildPortals()
	local n = #zones
	for i = 1, n do
		local A = zones[i]
		for j = i + 1, n do
			local B = zones[j]
			if math.abs(A.y - B.y) > CFG.FloorTolerance then
				continue
			end
			-- v197: two different cellblocks (Medium vs High/Max vs Low vs Medical)
			-- never connect through an open border - only through a
			-- mapped door. A diagonal High_Security / MEdium_Security_Cellblock_2
			-- border produced a fake portal and escorts wandered the Medium block.
			local secured = { MEDIUM_SECURITY = true, MAXIMUM_SECURITY = true, LOW_SECURITY = true, MEDICAL = true }
			if A.area ~= B.area and secured[A.area] and secured[B.area] then
				continue
			end
			local a, b = A.bbox, B.bbox
			local t = CFG.PortalTolerance
			if a[1] > b[3] + t or b[1] > a[3] + t or a[2] > b[4] + t or b[2] > a[4] + t then
				continue
			end
			local samples = {}
			for k = 1, #A.poly do
				local p, q = A.poly[k], A.poly[k % #A.poly + 1]
				local len = (q - p).Magnitude
				local steps = math.max(1, math.floor(len / CFG.PortalStep))
				for s = 0, steps do
					local pt = p:Lerp(q, s / steps)
					if polyDist(pt.X, pt.Y, B.poly) <= t then
						table.insert(samples, pt)
					end
				end
			end
			if #samples < 2 then
				continue
			end
			local first, last = samples[1], samples[1]
			local span = 0
			for _, s1 in samples do
				for _, s2 in samples do
					local d = (s1 - s2).Magnitude
					if d > span then
						span, first, last = d, s1, s2
					end
				end
			end
			if span < CFG.PortalMinSpan then
				continue
			end
			local mid = (first + last) / 2
			local midV = Vector3.new(mid.X, (A.y + B.y) / 2, mid.Y)
			if doorNear(midV, CFG.PortalDoorClearance) then
				continue -- a doorway: the door node is the connection
			end
			local along = (last - first).Unit
			local normal = Vector2.new(-along.Y, along.X)
			local inA = mid + normal * 3
			local inB = mid - normal * 3
			if not pointInPoly(inA.X, inA.Y, A.poly) then
				inA, inB = inB, inA
			end
			local pA = ground(Vector3.new(inA.X, A.y, inA.Y))
			local pB = ground(Vector3.new(inB.X, B.y, inB.Y))
			-- v201: scan the whole shared border 1 stud at a time and use the
			-- longest OPEN run: an off-centre doorway (open low-security cells)
			-- is found, and a wall with one gap no longer becomes a wide portal.
			local steps = math.max(1, math.floor(span))
			local bestStart, bestLen, runStart = nil, 0, nil
			for s = 0, steps do
				local m2 = first:Lerp(last, s / steps)
				local a2, b2 = m2 + normal * 3, m2 - normal * 3
				if not pointInPoly(a2.X, a2.Y, A.poly) then a2, b2 = b2, a2 end
				local clear = rayClear(ground(Vector3.new(a2.X, A.y, a2.Y)), ground(Vector3.new(b2.X, B.y, b2.Y)))
				if clear then
					runStart = runStart or s
					local len = s - runStart
					if len > bestLen then bestStart, bestLen = runStart, len end
				else
					runStart = nil
				end
			end
			local open = bestStart ~= nil and bestLen * (span / steps) >= CFG.PortalMinSpan
			if open then
				mid = first:Lerp(last, (bestStart + bestLen / 2) / steps)
				midV = Vector3.new(mid.X, (A.y + B.y) / 2, mid.Y)
			end
			if open then
				local id = addNode(ground(midV), "PORTAL", { name = A.name .. " | " .. B.name })
				joinZone(A, id)
				joinZone(B, id)
			end
		end
	end
end

local function connectZones()
	for _, z in zones do
		local polys = { z.poly }
		local m = z.members
		for i = 1, #m do
			for j = i + 1, #m do
				tryConnect(m[i], m[j], polys)
			end
			if i % 12 == 0 then
				task.wait()
			end
		end
	end
	-- door sides that aren't inside a zone (cells without a zone, outdoors) still link to
	-- whatever mapped node is close and visible
	for _, d in doorNodes do
		for _, sid in d.sides do
			if #nodes[sid].zones == 0 then
				local sp = nodes[sid].pos
				for _, n in nodes do
					if n.id ~= sid and n.kind ~= "DOOR" and n.doorId ~= d.id and (n.pos - sp).Magnitude <= CFG.RouteAttachRange then
						tryConnect(sid, n.id, nil, "AREA")
					end
				end
			end
		end
	end
	-- your routes: join nearby graph nodes (including door sides) to every route point
	for _, ids in routes do
		for _, rid in ids do
			local rp = nodes[rid].pos
			for _, n in nodes do
				if n.id ~= rid and n.kind ~= "DOOR" and n.route == nil and (n.pos - rp).Magnitude <= CFG.RouteAttachRange then
					tryConnect(rid, n.id, nil, "AREA")
				end
			end
		end
		task.wait()
	end
end

local function computeComponents(): { [number]: { number } }
	table.clear(componentOf)
	local comps = {}
	local cid = 0
	for _, n in nodes do
		if not componentOf[n.id] then
			cid += 1
			comps[cid] = {}
			local stack = { n.id }
			componentOf[n.id] = cid
			while #stack > 0 do
				local u = table.remove(stack)
				table.insert(comps[cid], u)
				for _, e in nodes[u].edges do
					if not componentOf[e.to] then
						componentOf[e.to] = cid
						table.insert(stack, e.to)
					end
				end
			end
		end
	end
	local best, bestN = 0, -1
	for id, list in comps do
		if #list > bestN then
			best, bestN = id, #list
		end
	end
	mainComponent = best
	return comps
end

-- islands (upper tiers, towers...) joined to the main network with PathfindingService
-- v212: upper floors (medium / maximum / supermax tiers, low security's
-- second level) only reach the ground floor by stairs, so every island is
-- retried against the growing main network with its own pathfinding budget,
-- same-floor links first, and a staircase may be much longer than the drop.
local function bridgeIslands()
	local budget = CFG.BridgeBudget or 500
	local startUsed = pathfindUsed
	local failed: { [number]: boolean } = {}
	for _ = 1, 200 do
		local comps = computeComponents()
		local main = comps[mainComponent] or {}
		local bridged = false
		for cid, list in comps do
			if cid == mainComponent or failed[list[1]] then
				continue
			end
			if pathfindUsed - startUsed >= budget then
				break
			end
			local pairsList = {}
			for _, a in list do
				for _, b in main do
					local pa, pb = nodes[a].pos, nodes[b].pos
					local d = (pa - pb).Magnitude
					if d <= CFG.BridgeRange then
						local sameFloor = math.abs(pa.Y - pb.Y) <= 3
						table.insert(pairsList, { a = a, b = b, d = d + (if sameFloor then 0 else 60) })
					end
				end
			end
			table.sort(pairsList, function(x, y)
				return x.d < y.d
			end)
			for k = 1, math.min(4, #pairsList) do
				local pr = pairsList[k]
				local wps = pathfindCheck(nodes[pr.a].pos, nodes[pr.b].pos, 3, budget + (startUsed - CFG.PathfindBudget), 220)
				if wps then
					local stairs = math.abs(nodes[pr.a].pos.Y - nodes[pr.b].pos.Y) > 4
					addEdge(pr.a, pr.b, if stairs then "STAIRS" else "PATHFIND", { waypoints = wps })
					bridged = true
					break
				end
			end
			if bridged then
				break -- components changed: recompute before the next island
			end
			failed[list[1]] = true
		end
		if not bridged then
			break
		end
	end
	computeComponents()
end

local function addDest(name: string, ids: { number }?)
	if ids and #ids > 0 then
		destinations[name] = ids
	end
end

local function buildDestinations()
	table.clear(destinations)
	local byKey: { [string]: { number } } = {}
	local byArea: { [string]: { number } } = {}
	for _, z in zones do
		if z.center then
			byKey[z.key] = byKey[z.key] or {}
			table.insert(byKey[z.key], z.center)
			if not z.cell then
				byArea[z.area] = byArea[z.area] or {}
				table.insert(byArea[z.area], z.center)
			end
		end
	end
	for k, ids in byKey do
		addDest(k, ids)
	end
	for a, ids in byArea do
		if not destinations[a] then
			addDest(a, ids)
		end
	end
	for _, d in doorNodes do
		addDest("DOOR:" .. string.upper(d.name), { d.id })
	end
	for name, ids in routes do
		addDest("ROUTE:" .. string.upper(name) .. ":START", { ids[1] })
		addDest("ROUTE:" .. string.upper(name) .. ":END", { ids[#ids] })
	end
	local function door(name: string): { number }?
		return destinations["DOOR:" .. string.upper(name)]
	end
	local function zone(name: string): { number }?
		local z = zoneByName[name]
		return if z and z.center then { z.center } else nil
	end
	-- friendly aliases (only where the data exists)
	addDest("INTAKE_DROPOFF", destinations["ROUTE:INTAKE TO INTAKE CELLS:START"] or door("Exterior intake door"))
	addDest("INTAKE_CELLS", door("Door to Intake Cells") or byKey.INTAKE_MAIN)
	addDest("BOOKING", zone("Zone_outside_of_booking_cells") or door("Door to Booking"))
	addDest("BOOKING_CELLS", byKey.BOOKING_CELL_ZONE)
	addDest("MAIN_CORRECTIONAL", door("Door to main Correctional Unit"))
	addDest("MEDIUM_SECURITY", byKey.MEDIUM_SECURITY_CELLBLOCK or byArea.MEDIUM_SECURITY)
	addDest("MAXIMUM_SECURITY", zone("High_Security") or byArea.MAXIMUM_SECURITY)
	addDest("LOW_SECURITY", byKey.LOW_SECURITY_CELLBLOCK or byArea.LOW_SECURITY)
	addDest("CELL_BLOCK_A", zone("MEdium_Security_Cellblock"))
	addDest("CELL_BLOCK_B", zone("MEdium_Security_Cellblock_2"))
	addDest("LOBBY", byKey.LOBBY)
	addDest("VISITING", byKey.VISITING_ROOM)
	addDest("RELEASE", byKey.RELEASE_HALLWAU)
	addDest("DRESS_OUT", byKey.DRESS_OUT_ZONE)
	addDest("YARD", byArea.YARD or byArea.COMMON)
	addDest("INDOOR_YARD", byArea.INDOOR_YARD or byArea.YARD or byArea.COMMON)
	addDest("CAFETERIA", byArea.CAFETERIA or byArea.COMMON)
	addDest("SOLITARY", byArea.SOLITARY)
	addDest("SUPERMAX", byArea.SUPERMAX)
	addDest("HOLDING", byArea.HOLDING)
	addDest("DEATH_ROW", byArea.DEATH_ROW)
	for name, pos in extraDest do
		local id = Nav.nearestNode(pos, nil, true)
		if id then
			addDest(name, { id })
		end
	end
end

---------------------------------------------------------------------------
-- debug view
---------------------------------------------------------------------------
local debugFolder: Folder? = nil
local COLORS = {
	AREA = Color3.fromRGB(235, 235, 235),
	CELL = Color3.fromRGB(150, 150, 255),
	PORTAL = Color3.fromRGB(60, 220, 90),
	DOOR = Color3.fromRGB(255, 140, 20),
	EXTERIOR_DOOR = Color3.fromRGB(255, 90, 20),
	CELL_DOOR = Color3.fromRGB(255, 220, 40),
	DOOR_SIDE = Color3.fromRGB(255, 180, 90),
	ROUTE = Color3.fromRGB(40, 220, 255),
}
local EDGE_COLORS = {
	ROUTE = Color3.fromRGB(40, 220, 255),
	AREA = Color3.fromRGB(200, 200, 200),
	DOOR = Color3.fromRGB(255, 140, 20),
	PATHFIND = Color3.fromRGB(190, 80, 255),
	STAIRS = Color3.fromRGB(255, 60, 220),
}

local function dbgPart(parent: Instance, size: Vector3, cf: CFrame, color: Color3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function dbgLabel(part: BasePart, text: string, color: Color3)
	local g = Instance.new("BillboardGui")
	g.Size = UDim2.fromOffset(170, 22)
	g.StudsOffset = Vector3.new(0, 2.2, 0)
	g.AlwaysOnTop = true
	g.MaxDistance = 120
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 0.4
	t.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	t.TextColor3 = color
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.Size = UDim2.fromScale(1, 1)
	t.Text = text
	t.Parent = g
	g.Parent = part
end

local function drawGraph()
	if debugFolder then
		debugFolder:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "PrisonNavDebug"
	debugFolder = f
	local up = Vector3.new(0, 0.6, 0)
	local seen = {}
	for _, n in nodes do
		local off = componentOf[n.id] ~= mainComponent
		local color = if off then Color3.fromRGB(255, 30, 30) else (COLORS[n.kind] or Color3.new(1, 1, 1))
		local s = if n.kind == "DOOR" or n.kind == "CELL_DOOR" or n.kind == "EXTERIOR_DOOR" then 1.4 else 0.9
		local p = dbgPart(f, Vector3.new(s, s, s), CFrame.new(n.pos + up), color, Enum.PartType.Ball)
		p.Name = n.kind .. "_" .. n.id
		if n.door or off or (n.kind == "AREA" or n.kind == "CELL") and n.zone and n.zone.center == n.id then
			dbgLabel(p, (if off then "DISCONNECTED: " else "") .. (n.name or n.kind), color)
		end
		for _, e in n.edges do
			local key = edgeKey(n.id, e.to)
			if not seen[key] then
				seen[key] = true
				local a, b = n.pos + up, nodes[e.to].pos + up
				local len = (b - a).Magnitude
				if len > 0.2 then
					local ecol = if off then Color3.fromRGB(255, 30, 30) else (EDGE_COLORS[e.kind] or Color3.new(1, 1, 1))
					dbgPart(f, Vector3.new(0.12, 0.12, len), CFrame.lookAt((a + b) / 2, b), ecol)
				end
			end
		end
	end
	f.Parent = Workspace
end

local routeDraws: { [any]: Folder } = {}
local function drawRoute(owner: any, points: { Vector3 })
	if not Nav.debug then
		return
	end
	if routeDraws[owner] then
		routeDraws[owner]:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "NavRoute"
	local up = Vector3.new(0, 1.2, 0)
	for i = 1, #points - 1 do
		local a, b = points[i] + up, points[i + 1] + up
		local len = (b - a).Magnitude
		if len > 0.2 then
			dbgPart(f, Vector3.new(0.3, 0.3, len), CFrame.lookAt((a + b) / 2, b), Color3.fromRGB(0, 255, 60))
		end
	end
	f.Parent = debugFolder or Workspace
	routeDraws[owner] = f
	task.delay(25, function()
		if routeDraws[owner] == f then
			routeDraws[owner] = nil
		end
		f:Destroy()
	end)
end

function Nav.setDebug(on: boolean)
	Nav.debug = on
	if on and Nav.ready then
		drawGraph()
	elseif not on and debugFolder then
		debugFolder:Destroy()
		debugFolder = nil
	end
end

---------------------------------------------------------------------------
-- build
---------------------------------------------------------------------------
function Nav.init(o: any)
	log("BUILD v168 - mapped cuff walk / concurrent custody / cell capacity")
	opts = o
	Util = o.Util
	local function syncDebug()
		local map = opts.mapRoot and opts.mapRoot()
		local on = Workspace:GetAttribute("PrisonNavDebug") == true or (map ~= nil and map:GetAttribute("NavDebug") == true)
		if on ~= (Nav.debug == true) then
			Nav.setDebug(on)
		end
	end
	Workspace:GetAttributeChangedSignal("PrisonNavDebug"):Connect(syncDebug)
	local map = opts.mapRoot and opts.mapRoot()
	if map then
		map:GetAttributeChangedSignal("NavDebug"):Connect(syncDebug)
	end
	Nav.syncDebug = syncDebug
end

function Nav.build(): boolean
	if Nav.building then
		return false
	end
	Nav.building = true
	Nav.ready = false
	local ok, err = pcall(function()
		local map = opts.mapRoot and opts.mapRoot()
		if not map then
			error("no PrisonMap found")
		end
		table.clear(nodes)
		table.clear(zones)
		table.clear(zoneByName)
		table.clear(doorNodes)
		table.clear(routes)
		table.clear(blocked)
		report = {}
		pathfindUsed = 0
		local t0 = os.clock()
		Nav.mapRoot=map
		Nav.refreshCellPairs(map)
		importZones(map)
        if #zones==0 then error("selected PrisonMap has no valid polygon zones: "..map:GetFullName()) end
        importDoors(map)
        if #doorNodes==0 then error("selected PrisonMap has no valid DoorObject links") end
		buildRayParams()
		zoneInteriorNodes()
		attachDoors()
		importRoutes(map)
		buildPortals()
		connectZones()
		bridgeIslands()
		buildDestinations()
		-- report
		local comps = computeComponents()
		local islands, offZones = 0, {}
		for cid, list in comps do
			if cid ~= mainComponent then
				islands += 1
				for _, id in list do
					local n = nodes[id]
					if n.zone and n.zone.center == id then
						table.insert(offZones, n.zone.name)
					elseif n.door and n.kind ~= "DOOR_SIDE" then
						table.insert(offZones, "door:" .. n.name)
					end
				end
			end
		end
		local unattached = {}
		for _, d in doorNodes do
			if #d.zones == 0 then
				table.insert(unattached, d.name)
			end
		end
		local edgeCount = 0
		local kinds = {}
		for k, v in report do
			edgeCount += v
			table.insert(kinds, k .. "=" .. v)
		end
		local destCount = 0
		for _ in destinations do
			destCount += 1
		end
		log("graph built in %.1fs: %d nodes, %d edges (%s), %d zones, %d doors, %d routes, %d destinations, pathfind checks %d",
			os.clock() - t0, #nodes, edgeCount, table.concat(kinds, " "), #zones, #doorNodes, (function()
				local c = 0
				for _ in routes do
					c += 1
				end
				return c
			end)(), destCount, pathfindUsed)
		if islands > 0 then
			warn(("[PrisonNav] %d area(s) NOT connected to the main network (turn on NavDebug to see them in red): %s"):format(islands, table.concat(offZones, ", ")))
		end
		if #unattached > 0 then
			warn("[PrisonNav] door markers not touching any zone (only reachable via nearby route points): " .. table.concat(unattached, ", "))
		end
	end)
	Nav.building = false
	if not ok then
		warn("[PrisonNav] graph build failed - prison NPCs keep their old movement: " .. tostring(err))
		Nav.ready = false
		return false
	end
	Nav.ready = true
	if Nav.syncDebug then
		Nav.syncDebug()
	end
	if Nav.debug then
		drawGraph()
	end
	return true
end

function Nav.addDestination(name: string, pos: Vector3?)
	if pos then
		extraDest[string.upper(name)] = pos
		if Nav.ready then
			local id = Nav.nearestNode(pos, nil, true)
			if id then
				destinations[string.upper(name)] = { id }
			end
		end
	end
end

function Nav.destinations(): { string }
	local out = {}
	for k in destinations do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

---------------------------------------------------------------------------
-- queries
---------------------------------------------------------------------------
-- nearest node the position can actually reach (same zone, or a clear ray)
function Nav.nearestNode(pos: Vector3, allowed: ((any) -> boolean)?, mainOnly: boolean?): number?
	local z = zoneAt(pos, 1.5)
	local cands = {}
	for _, n in nodes do
		if (not allowed or allowed(n)) and (not mainOnly or componentOf[n.id] == mainComponent) and n.kind ~= "DOOR" then
			local d = (n.pos - pos).Magnitude
			-- v191: same floor only. The old 14-stud window let a ground-floor
			-- point (e.g. outside High_Security_2, y~0.4 / root y~3.4) snap to the
			-- second-floor Maximum_Security_Cell_4 directly above it (y~12.9),
			-- which has no stairs mapped -> "no connected route" to the cell.
			-- Points here are either floor points or root points (floor+~3).
			local dy = n.pos.Y - pos.Y
			if d < 160 and dy < CFG.FloorTolerance and dy > -(CFG.FloorTolerance + 3) then
				local sameZone = z ~= nil and table.find(n.zones, z) ~= nil
				local score = if sameZone then d * 0.6 else d
				-- Prefer the connected network; an island node is only a last resort.
				if componentOf[n.id] ~= mainComponent then score += 120 end
				table.insert(cands, { id = n.id, d = score })
			end
		end
	end
	table.sort(cands, function(a, b)
		return a.d < b.d
	end)
	for i = 1, math.min(8, #cands) do
		local n = nodes[cands[i].id]
		local sameZone = z ~= nil and table.find(n.zones, z) ~= nil
		if rayClear(pos, n.pos) then
			return n.id
		end
	end
	return if cands[1] then cands[1].id else nil
end

local function resolveGoal(dest: any, from: Vector3): ({ number }?, Vector3?)
	if typeof(dest) == "Vector3" then
		local id = Nav.nearestNode(dest, nil, false)
		return if id then { id } else nil, dest
	end
	local ids = destinations[string.upper(tostring(dest))]
	if not ids then
		return nil, nil
	end
	-- the nearest of a group
	local best, bestD = nil, math.huge
	for _, id in ids do
		local d = (nodes[id].pos - from).Magnitude
		if d < bestD then
			best, bestD = id, d
		end
	end
	return if best then { best } else nil, nil
end

-- A* over the graph. Cells are only entered when they are the start or goal.
function Nav.findPath(startId: number, goalId: number, o: any?): { number }?
	local goalNode = nodes[goalId]
	local startNode = nodes[startId]
	local allowedZones = {}
	for _, z in goalNode.zones do
		allowedZones[z] = true
	end
	for _, z in startNode.zones do
		allowedZones[z] = true
	end
	local now = os.clock()
	local function passable(n: any): boolean
		if n.id == goalId or n.id == startId then
			return true
		end
		if o and o.allowed and not o.allowed(n) then
			return false
		end
		-- don't route THROUGH somebody's cell
		if n.zone and n.zone.cell and not allowedZones[n.zone] then
			return false
		end
		if n.kind == "CELL_DOOR" or (n.kind == "DOOR_SIDE" and nodes[n.doorId] and nodes[n.doorId].kind == "CELL_DOOR") then
			local door = n.door or nodes[n.doorId].door
			local ok = false
			for _, z in door.zones do
				if z.cell and allowedZones[z] then
					ok = true
				end
			end
			if not ok then
				-- a cell door with no cell zone behind it: allowed only as the goal
				return goalNode.doorId == (n.doorId or n.id) or goalId == (n.doorId or n.id)
			end
		end
		return true
	end
	local open = { startId }
	local inOpen = { [startId] = true }
	local g = { [startId] = 0 }
	local came = {}
	local gp = goalNode.pos
	local iter = 0
	while #open > 0 do
		iter += 1
		if iter > 20000 then
			break
		end
		local bi, bf = 1, math.huge
		for i, id in open do
			local f = g[id] + (nodes[id].pos - gp).Magnitude
			if f < bf then
				bi, bf = i, f
			end
		end
		local u = table.remove(open, bi)
		inOpen[u] = nil
		if u == goalId then
			local path = { u }
			while came[u] do
				u = came[u]
				table.insert(path, 1, u)
			end
			return path
		end
		for _, e in nodes[u].edges do
			local v = e.to
			local nv = nodes[v]
			if passable(nv) then
				local cost = e.cost
				if e.door then
					cost += 3
				end
				local bk = blocked[edgeKey(u, v)]
				if bk and bk > now then
					cost += CFG.BlockedEdgePenalty
				end
				local ng = g[u] + cost
				if ng < (g[v] or math.huge) then
					g[v] = ng
					came[v] = u
					if not inOpen[v] then
						inOpen[v] = true
						table.insert(open, v)
					end
				end
			end
		end
	end
	return nil
end

local function edgeBetween(a: number, b: number): any?
	for _, e in nodes[a].edges do
		if e.to == b then
			return e
		end
	end
	return nil
end

-- route = { nodes = {ids}, points = {Vector3}, doors = {doorIds}, goal = Vector3? }
function Nav.getRoute(from: Vector3, dest: any, o: any?): (any?, string?)
	if not Nav.ready then
		return nil, "graph not ready"
	end
	local goalIds, exact = resolveGoal(dest, from)
	if not goalIds then
		return nil, "unknown destination " .. tostring(dest)
	end
	local startId = Nav.nearestNode(from, o and o.allowed, false)
	if not startId then
		return nil, "start is off the prison map"
	end
	local path = Nav.findPath(startId, goalIds[1], o)
	if not path then
		local sn, gn = nodes[startId], nodes[goalIds[1]]
		-- v205: once per start/goal pair per minute
		local key = tostring(startId) .. ">" .. tostring(goalIds[1])
		local now = os.clock()
		Nav._noRouteLog = Nav._noRouteLog or {}
		if (Nav._noRouteLog[key] or -math.huge) > now - 60 then
			return nil, "no connected route"
		end
		Nav._noRouteLog[key] = now
		warn(("[PrisonNavDiag] NO ROUTE start=%s(%s comp=%s) goal=%s(%s comp=%s) main=%s"):format(
			tostring(sn and sn.name or startId), tostring(sn and sn.pos), tostring(componentOf[startId]),
			tostring(gn and gn.name or goalIds[1]), tostring(gn and gn.pos), tostring(componentOf[goalIds[1]]), tostring(mainComponent)))
		return nil, "no connected route"
	end
	local doors = {}
	local points = { from }
	for i, id in path do
		table.insert(points, nodes[id].pos)
		if nodes[id].door and nodes[id].kind ~= "DOOR_SIDE" then
			table.insert(doors, id)
		end
		if i > 1 then
			local e = edgeBetween(path[i - 1], id)
			if e and e.door and not table.find(doors, e.door) then
				table.insert(doors, e.door)
			end
		end
	end
	if exact then
		table.insert(points, exact)
	end
	return { nodes = path, points = points, doors = doors, goal = exact }, nil
end

---------------------------------------------------------------------------
-- traversal
---------------------------------------------------------------------------
local function doorTargetOf(id: number): Instance?
	local n = nodes[id]
	local d = n and (n.door or (n.doorId and nodes[n.doorId].door))
	return d and d.target or nil
end

local function openDoorId(id: number)
	local target = doorTargetOf(id)
	if target and opts.openDoor then
		pcall(opts.openDoor, target, CFG.DoorOpenSecs)
	end
end

-- Each local leg owns its paths and disconnects every Blocked subscription.
-- Corridor clearance is 3.25; mapped 4.2-stud doors require single file (1.9).
local function clearPath(s: any)
	if s.connection then s.connection:Disconnect(); s.connection = nil end
	if s.path then s.path:Destroy(); s.path = nil end
	s.points = nil
	s.direct = nil
	s.bodyWidth = nil
	s.alignTarget = nil
end

local function permittedSegment(a: Vector3, b: Vector3, allowed: any): boolean
	for _, z in zones do
		if z.cell and not allowed[z] then
			local steps = math.max(1, math.ceil(flat(b-a).Magnitude / 1.5))
			for j = 0, steps do
				local p = a:Lerp(b, j/steps)
				if math.abs(p.Y-z.y) < 5 and pointInPoly(p.X,p.Z,z.poly) then return false end
			end
		end
	end
	return true
end

-- Navmesh voxels can reject the saved 4.2-stud cell openings. Only an explicitly
-- selected doorway may use this geometric fallback, in single-file formation.
local function clearDoorSegment(s: any, a: Vector3, b: Vector3, allowed: any): (boolean, string?)
	if not s.directDoor and not s.following and not s.allowClearCorridor then return false,"not a doorway leg" end
	local floor=if s.directDoor then Nav.doorFloor(s.directDoor) else nil
	if flat(b-a).Magnitude>12 then return false,"segment too long" end
	if s.directDoor and (not floor or flat(a-floor).Magnitude>13 or flat(b-floor).Magnitude>13) then return false,"outside doorway recovery bounds" end
	if math.abs(a.Y-b.Y)>1.5 then return false,"vertical difference "..tostring(a.Y-b.Y) end
	if not permittedSegment(a,b,allowed) then return false,"unrelated cell polygon" end
	local params=RaycastParams.new()
	params.FilterType=Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances=s.ignore or {}
	params.RespectCanCollide=true
	local overlap=OverlapParams.new()
	overlap.FilterType=Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances=s.ignore or {}
	overlap.RespectCanCollide=true
	local size=Vector3.new(3,5,3)
	-- A door-threshold resync may sweep the real collision width of a humanoid
	-- torso (2 studs) plus margin instead of the corridor-clearance box.
	if s.bodyWidth then size=Vector3.new(s.bodyWidth,5,s.bodyWidth) end
	-- The mapped dress-out openings have only a 2.8-stud clear width because
	-- their wall jamb reaches the edge of the frame. Keep the normal 3-stud
	-- corridor sweep everywhere else, but allow single-file passage here.
	if s.directDoor and string.find(string.lower(s.directDoor.Name),"dress out room door",1,true) then
		size=Vector3.new(math.min(2,size.X),5,math.min(2,size.Z))
	end
	local offset=Vector3.new(0,0.3,0)
	-- In a mapped doorway, anchor the body volume to the authored door floor
	-- (floor+0.8 .. floor+5.8, the same band a standard rig's root gives).
	-- Player avatars with a taller HipHeight otherwise sweep higher than the
	-- NPC officer and graze door frames the officer passes cleanly.
	if floor and math.abs(a.Y-floor.Y)<6 then offset=Vector3.new(0,floor.Y+3.3-a.Y,0) end
	-- Blockcast omits initial overlaps, so check the starting volume explicitly.
	local touching=Workspace:GetPartBoundsInBox(CFrame.new(a+offset),size,overlap)
	if #touching>0 then
		-- Bounds of unions can cover empty space (railings/stairs especially).
		-- Confirm an overlap against collision geometry before rejecting it.
		local probe=Instance.new("Part")
		probe.Name="CustodyClearanceProbe";probe.Anchored=true;probe.CanCollide=false
		probe.CanTouch=false;probe.CanQuery=false;probe.Transparency=1
		probe.Size=size;probe.CFrame=CFrame.new(a+offset);probe.Parent=Workspace
		touching=Workspace:GetPartsInPart(probe,overlap)
		probe:Destroy()
	end
	local delta=b-a
	local overlapEscapeParts={}
	if #touching>0 and s.allowDoorwayOverlapEscape and s.directDoor
		and string.find(string.lower(s.directDoor.Name),"dress out room door",1,true)
		and flat(delta).Magnitude>=0.5 and flat(delta).Magnitude<=4 then
		local direction=flat(delta).Unit
		local safeEscape=true
		for _,part in touching do
			local away=flat(a-part.Position)
			local farther=flat(b-part.Position)
			if part.Name~="Union" or flat(part.Position-floor).Magnitude>9 or away.Magnitude<0.01
				or farther.Magnitude<away.Magnitude+0.35 or direction:Dot(away.Unit)<0.15 then
				safeEscape=false;break
			end
			table.insert(overlapEscapeParts,part)
		end
		if safeEscape then
			-- Only permit a short, mapped-door egress step away from the specific
			-- Union that the character is already intersecting. Keep physical
			-- collision enabled; require the destination body volume to be clear.
			local destinationProbe=Instance.new("Part")
			destinationProbe.Name="CustodyClearanceProbe";destinationProbe.Anchored=true;destinationProbe.CanCollide=false
			destinationProbe.CanTouch=false;destinationProbe.CanQuery=false;destinationProbe.Transparency=1
			destinationProbe.Size=size;destinationProbe.CFrame=CFrame.new(b+offset);destinationProbe.Parent=Workspace
			local destinationOverlap=Workspace:GetPartsInPart(destinationProbe,overlap)
			destinationProbe:Destroy()
			if #destinationOverlap>0 then safeEscape=false end
		end
		if safeEscape then
			for _,part in overlapEscapeParts do table.insert(params.FilterDescendantsInstances,part) end
			for _,part in overlapEscapeParts do table.insert(overlap.FilterDescendantsInstances,part) end
		else
			table.clear(overlapEscapeParts)
		end
	end
	if #touching>0 and #overlapEscapeParts==0 then return false,"initial body overlap: "..touching[1]:GetFullName() end
	local hitBody=if delta.Magnitude>0.05 then Workspace:Blockcast(CFrame.new(a+offset),size,delta,params) else nil
	if hitBody then return false,"body sweep: "..hitBody.Instance:GetFullName().." at "..tostring(hitBody.Position) end
	-- Continuous solid floor, small step heights, no drops or furniture climbing.
	-- Root height varies by rig and animation. Door markers give us the floor
	-- directly; other follow segments use the supporting surface under the actor.
	local referenceY=floor and floor.Y
	if not referenceY then
		local support=Workspace:Raycast(a+Vector3.new(0,0.5,0),Vector3.new(0,-6,0),params)
		if not support or support.Normal.Y<0.7 then return false,"missing starting support" end
		referenceY=support.Position.Y
	end
	local previousY=nil
	local count=math.max(1,math.ceil(flat(delta).Magnitude))
	for i=0,count do
		local p=a:Lerp(b,i/count)
		local expected=referenceY
		local hit=Workspace:Raycast(Vector3.new(p.X,expected+1.2,p.Z),Vector3.new(0,-2.4,0),params)
		if not hit then return false,"missing floor at "..tostring(p) end
		if hit.Normal.Y<0.7 then return false,"floor slope: "..hit.Instance:GetFullName() end
		if math.abs(hit.Position.Y-expected)>0.65 then return false,("floor mismatch actual=%.2f expected=%.2f part=%s"):format(hit.Position.Y,expected,hit.Instance:GetFullName()) end
		if previousY and math.abs(hit.Position.Y-previousY)>0.6 then return false,"floor step exceeds 0.6" end
		previousY=hit.Position.Y
	end
	return true
end


-- Door frame from a mapped DoorMarker: floor point, crossing axis (through the
-- opening) and lateral axis (along the opening), plus the half clear width.
local function doorFrame(marker: Instance): (Vector3?, Vector3?, Vector3?, number)
	local dp=Nav.doorFloor(marker)
	if not dp then return nil,nil,nil,0 end
	local center=marker:FindFirstChild("Center")
	local cf=if center and center:IsA("BasePart") then center.CFrame else CFrame.new(dp)
	local sx=tonumber(marker:GetAttribute("SizeX")) or 1
	local sz=tonumber(marker:GetAttribute("SizeZ")) or 4
	local axis=if sx<sz then cf.RightVector else cf.LookVector
	axis=flat(axis)
	if axis.Magnitude<0.01 then return nil,nil,nil,0 end
	axis=axis.Unit
	local lateral=Vector3.new(-axis.Z,0,axis.X)
	return dp,axis,lateral,math.max(sx,sz)/2
end
Nav.doorFrame=doorFrame

-- Threshold resync: when a body sweep from the actor's current spot clips a
-- door jamb, the actor is usually standing off the door's centre line (it
-- stopped inside the arrival radius of the staging point). Find a validated
-- point on the SAME side of the door, on the centre line, from which a
-- straight walk through the opening is clear. Collision stays on; only the
-- sweep box can narrow to a real torso width (2.4) when the corridor box (3)
-- does not fit the 4.2-stud opening. Returns point, bodyWidth, or nil.
-- v195 perf: 3 depths x 5 offsets x 2 widths (was 5x5x2 = up to 100 sweeps).
local ALIGN_DEPTHS={0,3.5,2.2}
local ALIGN_LATERAL={0,0.3,-0.3,0.6,-0.6}
local function doorAlignment(s: any, a: Vector3, goal: Vector3, allowed: any, maxShift: number?): (Vector3?, number?)
	if not s.directDoor then return nil,nil end
	-- v195 perf: at most one full alignment search per actor every 0.5s.
	local now=os.clock()
	if s.nextAlignSearch and now<s.nextAlignSearch then return nil,nil end
	s.nextAlignSearch=now+0.5
	local dp,axis,lateral=doorFrame(s.directDoor)
	if not dp then return nil,nil end
	local da=axis:Dot(flat(a-dp))
	local side=if da>=0 then 1 else -1
	local limit=maxShift or 6
	local saved=s.bodyWidth
	for _,width in {3,2.4} do
		s.bodyWidth=if width==3 then nil else width
		for _,depthChoice in ALIGN_DEPTHS do
			local depth=if depthChoice==0 then math.clamp(math.abs(da),1.6,4.5) else depthChoice
			for _,off in ALIGN_LATERAL do
				local p=dp+axis*side*depth+lateral*off
				p=Vector3.new(p.X,a.Y,p.Z)
				local shift=flat(p-a).Magnitude
				if shift<=limit and (shift<0.2 or clearDoorSegment(s,a,p,allowed)) and clearDoorSegment(s,p,goal,allowed) then
					local chosen=s.bodyWidth
					s.bodyWidth=saved
					return p,chosen or 3
				end
			end
		end
	end
	s.bodyWidth=saved
	return nil,nil
end

local function pathStep(s: any, root: BasePart, goal: Vector3, radius: number, allowed: any, move: any, stop: any): (boolean, string?)
	local now = os.clock()
	local distance = flat(goal-root.Position).Magnitude
	-- Humanoid walking settles short of the exact point. A smaller acceptance
	-- radius can wait forever even after MoveTo has completed successfully.
	local arrivalRadius=if s.preciseArrival then 0.3 else math.max(1,s.arrivalRadius or 1.25)
	if distance < arrivalRadius and math.abs(goal.Y-root.Position.Y) < 5 then
		if not s.flow then stop() end
		return true
	end
	if not s.lastPos or (root.Position-s.lastPos).Magnitude >= 0.9 then
		s.lastPos, s.progressAt = root.Position, now
	end
	local stalled = s.progressAt and now-s.progressAt > 1.7
	local changed = not s.goal or (s.goal-goal).Magnitude > 3
	if s.invalid or stalled or changed then
		clearPath(s); if s.invalid or stalled then stop() end; s.invalid = false
		if stalled then s.failures = (s.failures or 0)+1; s.progressAt = now end
	end
	if (s.failures or 0) >= 3 then return false, "no progress" end
	if s.preciseArrival and distance<2 then
		local clear,reason=clearDoorSegment(s,root.Position,goal,allowed)
		if not clear and not s.bodyWidth then
			-- Final settle inside a doorway: retry with the humanoid torso width
			-- before declaring the alignment blocked.
			s.bodyWidth=2.4
			clear=clearDoorSegment(s,root.Position,goal,allowed)
			if not clear then s.bodyWidth=nil end
		end
		if not clear then stop();return false,"alignment blocked: "..tostring(reason) end
		local width=s.bodyWidth
		clearPath(s);s.goal=goal;s.bodyWidth=width
		move(goal,true)
		return false
	end
	-- Moving formation targets use body/floor-verified steering, not a new
	-- path and a stop command for every small change of target.
	if s.following then
		-- v195 perf: the follow target moves every tick; reuse a clear verdict for
		-- 0.25s while target and body moved < 1 stud (was a full body sweep +
		-- floor raycasts every 0.05s).
		local c=s.followCache
		local clear
		if c and now-c.at<0.25 and (c.a-root.Position).Magnitude<1 and (c.b-goal).Magnitude<1 then
			clear=c.clear
		else
			clear=clearDoorSegment(s,root.Position,goal,allowed)
			s.followCache={at=now,a=root.Position,b=goal,clear=clear}
		end
		if clear then clearPath(s); s.goal=goal; move(goal); return false end
	end
	if not s.points then
		if s.nextCompute and now < s.nextCompute then return false end
		s.nextCompute = now + 0.6
		s.goal = goal
		local path = PathfindingService:CreatePath({AgentRadius=radius, AgentHeight=5,
			AgentCanJump=false, AgentCanClimb=false, WaypointSpacing=2.5})
		local ok = pcall(function() path:ComputeAsync(root.Position, goal) end)
		local points
		if not ok or path.Status ~= Enum.PathStatus.Success then
			path:Destroy(); path=nil
			local clear,rejection=clearDoorSegment(s,root.Position,goal,allowed)
			local aligned,width=nil,nil
			if not clear and s.directDoor then
				aligned,width=doorAlignment(s,root.Position,goal,allowed)
			end
			if clear then
				points={{Position=goal}}; s.direct=true
				if not s.loggedDirect then
					s.loggedDirect=true
					print("[PrisonNav] VERIFIED DOOR PASSAGE "..s.directDoor.Name)
				end
			elseif aligned then
				-- Walk to the centre line first, then straight through the opening.
				-- The aligned point is often under a stud away; the normal waypoint
				-- advance (1.2) would skip it and re-test the same clipped diagonal
				-- forever, so it is reached by precise steering (alignTarget).
				points={{Position=goal}}; s.direct=true; s.alignTarget=aligned
				s.bodyWidth=if width and width<3 then width else nil
				s.alignments=(s.alignments or 0)+1
				print(("[PrisonNav] DOOR THRESHOLD RESYNC actor=%s door=%s via=%s width=%.1f (was: %s)"):format(s.actor or "?",s.directDoor.Name,tostring(aligned),width or 3,tostring(rejection)))
			else
				stop(); s.failures=(s.failures or 0)+1
				if s.directDoor and (not s.lastDiagnostic or now-s.lastDiagnostic>2) then
					s.lastDiagnostic=now
					warn(("[PrisonNavDiag] actor=%s door=%s from=%s goal=%s radius=%.2f attempt=%d reject=%s"):format(s.actor or "?",s.directDoor.Name,tostring(root.Position),tostring(goal),radius,s.failures,tostring(rejection)))
				end
				return false, if s.failures >= 3 then "local path unavailable: "..tostring(rejection) else nil
			end
		else points=path:GetWaypoints() end
		local previous = root.Position
		for _, wp in points do
			if not permittedSegment(previous, wp.Position, allowed) then
				if path then path:Destroy() end; stop(); return false, "local path enters unrelated cell"
			end
			previous = wp.Position
		end
		if #points < 1 then if path then path:Destroy() end; return false, "empty local path" end
		s.path, s.points, s.index = path, points, 1
		if path then
			s.connection = path.Blocked:Connect(function(index)
				if index >= s.index then s.invalid = true end
			end)
		end
		s.lastPos, s.progressAt = root.Position, os.clock()
	end
	if s.alignTarget then
		if flat(s.alignTarget-root.Position).Magnitude > 0.3 then
			move(s.alignTarget, true)
			return false
		end
		s.alignTarget = nil
		s.lastPos, s.progressAt = root.Position, now
	end
	-- Never skip a corner or select a later waypoint just because it is closer.
	local wp = s.points[s.index]
	local previous = if s.index>1 then s.points[s.index-1].Position else s.lastPos
	if previous and segDist(root.Position.X,root.Position.Z,Vector2.new(previous.X,previous.Z),Vector2.new(wp.Position.X,wp.Position.Z))>5 then
		s.invalid=true; stop(); return false
	end
	if s.index<#s.points and flat(wp.Position-root.Position).Magnitude < 1.2 and math.abs(wp.Position.Y-root.Position.Y) < 5 then
		s.index += 1
		wp = s.points[s.index]
		s.progressAt = now
	end
	if s.direct and flat(wp.Position-root.Position).Magnitude>0.2 and not clearDoorSegment(s,root.Position,wp.Position,allowed) then
		-- Drifted off the verified line: stop and re-plan from here (the
		-- threshold resync above picks a fresh aligned point).
		s.invalid=true; stop(); return false
	end
	move(wp.Position)
	return false
end

-- v201: is any graph node of this zone on the main connected network?
function Nav.zoneConnected(zoneName: string): boolean
	local z=zoneByName[zoneName]
	if not z then return false end
	if #z.members==0 then return true end -- no graph nodes recorded: unknown, don't exclude
	for _,id in z.members do
		if componentOf[id]==mainComponent then return true end
	end
	return false
end

-- v203: a doorless (low security) cell has no threshold to cross, so the
-- whole cellblock around it counts: the inmate may be released anywhere in the
-- cell or its open cellblock.
function Nav.inOpenBlock(room: any, pos: Vector3): boolean
	local z=zoneByName[room.name]
	if not z then return false end
	local area=if z.area and z.area~="CORRIDOR" then z.area else "LOW_SECURITY"
	for _, other in zones do
		if other.area==area and math.abs(pos.Y-other.y)<=6 and pointInPoly(pos.X,pos.Z,other.poly) then return true end
	end
	return false
end

-- v203: where the officer walks a low-security inmate to: the cellblock graph
-- node nearest the cell (not the bunk-cluttered middle of the cell).
function Nav.openCellDrop(room: any): Vector3?
	local z=zoneByName[room.name]
	local area=if z and z.area and z.area~="CORRIDOR" then z.area else "LOW_SECURITY"
	local best,bestD=nil,math.huge
	for _, n in nodes do
		if n.kind~="DOOR" and n.zone and not n.zone.cell and n.zone.area==area and componentOf[n.id]==mainComponent then
			local d=(n.pos-room.pos).Magnitude
			if d<bestD and math.abs(n.pos.Y-room.pos.Y)<CFG.FloorTolerance+3 then best,bestD=n.pos,d end
		end
	end
	return best
end

function Nav.isInsideCell(room: any, pos: Vector3): boolean
	local z=zoneByName[room.name]
	if room.open and Nav.inOpenBlock(room,pos) then return true end
	if not z or not z.cell or math.abs(pos.Y-z.y)>6 then return false end
	if not pointInPoly(pos.X,pos.Z,z.poly) or edgeDist(pos.X,pos.Z,z.poly)<1 then return false end
	if room.open then return true end -- doorless cell: inside the footprint is inside
	local dp=Nav.doorFloor(room.door)
	if not dp then return false end
	local toward=flat(room.pos-dp)
	if toward.Magnitude<0.1 then return false end
	return flat(pos-dp):Dot(toward.Unit)>2.5
end

function Nav.cellStand(room: any, cop: any, character: Model): Vector3
	if room.open then return room.pos end
	local dp=Nav.doorFloor(room.door)
	if not dp then return room.pos end
	local center=room.door:FindFirstChild("Center")
	local cf=if center and center:IsA("BasePart") then center.CFrame else CFrame.new(dp)
	local axis=if (tonumber(room.door:GetAttribute("SizeX")) or 1)<(tonumber(room.door:GetAttribute("SizeZ")) or 4) then cf.RightVector else cf.LookVector
	axis=flat(axis).Unit
	if axis:Dot(room.pos-dp)<0 then axis=-axis end
	local ignore={cop.model,character}
	local map=opts.mapRoot and opts.mapRoot();if map then table.insert(ignore,map) end
	local npcs=workspace:FindFirstChild("PrisonNPCs");if npcs then table.insert(ignore,npcs) end
	local state={directDoor=room.door,ignore=ignore}
	local z=zoneByName[room.name];local allowed={};if z then allowed[z]=true end
	for _,depth in {3.5,4,4.5,5,5.5,6} do
		local p=dp+axis*depth
		local rootPoint=p+Vector3.new(0,3,0)
		if Nav.isInsideCell(room,rootPoint) and clearDoorSegment(state,dp+axis*3.5+Vector3.new(0,3,0),rootPoint,allowed) then
			print("[CustodyDiag] CLEAR CELL STAND "..room.name.." "..tostring(p))
			return p
		end
	end
	return room.pos
end

local function behindTrail(trail: {Vector3}, head: Vector3, gap: number): Vector3
	local remaining=gap
	local nextPoint=head
	for i=#trail,1,-1 do
		local delta=trail[i]-nextPoint
		local length=flat(delta).Magnitude
		if length>=remaining and length>0.01 then return nextPoint+delta*(remaining/length) end
		remaining-=length;nextPoint=trail[i]
	end
	return trail[1]
end

local function escortIgnore(cop: any, char: Model?, o: any): {Instance}
	local ignore={}
	if cop and cop.model then table.insert(ignore,cop.model) end
	for _,obj in opts.ignore or {} do if obj then table.insert(ignore,obj) end end
	for _,p in game:GetService("Players"):GetPlayers() do
		if p.Character then table.insert(ignore,p.Character) end
	end
	local map=Nav.mapRoot or (opts.mapRoot and opts.mapRoot())
	if map then table.insert(ignore,map) end
	-- v204: prison NPC inmates/suspects never block a cuff-walk sweep
	local npcs=workspace:FindFirstChild("PrisonNPCs");if npcs then table.insert(ignore,npcs) end
	-- v205: humanoid props placed in the facility (e.g. a decorative "Inmate"
	-- in a death row cell) are people, not walls
	if not Nav._humanoidProps or os.clock()-Nav._humanoidPropsAt>30 then
		Nav._humanoidProps={};Nav._humanoidPropsAt=os.clock()
		local fac=workspace:FindFirstChild("CorrectionalFacility")
		for _,m in (fac and fac:GetDescendants() or {}) do
			if m:IsA("Humanoid") and m.Parent and m.Parent:IsA("Model") then table.insert(Nav._humanoidProps,m.Parent) end
			-- v211: spawn pads in cells are floor markers, not obstacles
			if m:IsA("SpawnLocation") then table.insert(Nav._humanoidProps,m) end
		end
	end
	for _,m in Nav._humanoidProps do if m.Parent then table.insert(ignore,m) end end
	if char then table.insert(ignore,char) end
	if o.ignoreCharacter then table.insert(ignore,o.ignoreCharacter) end
	for _,part in o.ignoreParts or {} do if part then table.insert(ignore,part) end end
	return ignore
end

-- Soft-recovery helper for the custody controller. Returns a validated point
-- near `from`, on the same side of `marker`, lined up with the opening so that
-- a straight walk to `goal` clears the jambs, or nil. `maxShift` bounds how
-- far from `from` the point may be (a micro-resync, never a cross-map jump).
function Nav.doorRecoveryPoint(cop: any, char: Model?, marker: Instance, from: Vector3, goal: Vector3, maxShift: number?, o: any?): (Vector3?, number?)
	o=o or {}
	local s={actor="recovery",directDoor=marker,ignore=escortIgnore(cop,char,o)}
	local allowed={}
	for _,p in {from,goal} do
		local z=zoneAt(p,0);if z and z.cell then allowed[z]=true end
	end
	return doorAlignment(s,from,goal,allowed,maxShift)
end

function Nav.localTravel(cop: any, goal: Vector3, o: any?): (boolean, string?)
	o=o or {}
	local alive=o.alive or function() return true end
	local char,hum,prisoner
	if o.escortee then
		char,hum,prisoner=Util.charInfo(o.escortee)
		if not hum or not prisoner then return false,"prisoner lost" end
	end
	-- In a cuff escort the prisoner leads the verified route and the officer
	-- follows the same track, instead of both fighting for one destination.
	local leaderRoot=prisoner or cop.root
	local leaderHum=hum or cop.hum
	local motion=o.motion or {}
	local trail=motion.trail or {cop.root.Position,leaderRoot.Position}
	motion.trail=trail
	local ignore=escortIgnore(cop,char,o)
	local lead={actor=if prisoner then "prisoner-front" else "officer",directDoor=o.directDoor,ignore=ignore,flow=o.continueMotion,arrivalRadius=o.arrivalRadius,preciseArrival=o.preciseArrival,allowClearCorridor=o.allowClearCorridor==true,allowDoorwayOverlapEscape=o.allowDoorwayOverlapEscape==true}
	local rear={actor="officer-behind",directDoor=o.directDoor,ignore=ignore,following=true,allowDoorwayOverlapEscape=o.allowDoorwayOverlapEscape==true}
	local allowed={}
	for _,p in {cop.root.Position,leaderRoot.Position,goal} do
		local z=zoneAt(p,0);if z and z.cell then allowed[z]=true end
	end
	local radius=o.radius or (if prisoner then 3.25 else 1.9)
	if not o.radius then
		for _,d in doorNodes do
			local dp=nodes[d.id].pos
			if math.abs(dp.Y-goal.Y)<6 and (flat(dp-goal).Magnitude<9 or flat(dp-leaderRoot.Position).Magnitude<9) then radius=1.9;break end
		end
	end
	local deadline=os.clock()+(o.maxTime or 20)
	local lastDoor=0
	-- Pair watchdog: if neither body makes progress for 1.5s, or the prisoner
	-- drifts beyond the formation gap for 3s, drop both local paths and re-plan
	-- from the current positions. Bounded; pathStep's own failure count still
	-- ends a genuinely blocked leg.
	local watch={at=os.clock(),lead=leaderRoot.Position,rear=cop.root.Position,replans=0,driftSince=nil}
	local function finish(ok: boolean,why: string?): (boolean,string?)
		clearPath(lead);clearPath(rear)
		if not ok or not o.continueMotion then
			if cop.alive then cop:stop() end
			if prisoner and prisoner.Parent then hum:MoveTo(prisoner.Position) end
		end
		if not ok and prisoner then -- v203: guard patrols (no prisoner) fail quietly
			warn(("[PrisonNavDiag] CUFF WALK FAILED reason=%s officer=%s prisoner=%s goal=%s door=%s"):format(tostring(why),tostring(cop.root.Position),tostring(prisoner and prisoner.Position),tostring(goal),o.directDoor and o.directDoor.Name or "none"))
		end
		return ok,why
	end
	-- v218: a short leg the pair can't physically walk (a door frame clipping the
	-- body sweep, a cell wall overlapping the start volume) no longer stalls the
	-- escort for a minute: step both through to the leg's goal and carry on.
	local snapped=false
	local function snapThrough(why: string?): boolean
		if snapped then return false end
		local d=flat(goal-leaderRoot.Position)
		if d.Magnitude>18 or math.abs(goal.Y-leaderRoot.Position.Y)>7 then return false end
		snapped=true
		if not prisoner then
			-- a lone officer hung on a cell's door frame (leaving a cell he locked a prisoner in)
			if not o.directDoor then snapped=false;return false end
			print(("[PrisonNav] OFFICER SNAP through %s (%s)"):format(o.directDoor.Name,tostring(why)))
			cop.root.AssemblyLinearVelocity=Vector3.zero
			cop.root.CFrame=CFrame.lookAt(goal,goal+(if d.Magnitude>0.1 then d.Unit else Vector3.zAxis))
			clearPath(lead)
			return true
		end
		if not prisoner.Parent then return false end
		local dir=if d.Magnitude>0.1 then d.Unit else flat(cop.root.CFrame.LookVector).Unit
		if o.keepDoor then pcall(o.keepDoor) end
		print(("[PrisonNav] ESCORT SNAP through %s (%s)"):format(o.directDoor and o.directDoor.Name or "leg",tostring(why)))
		prisoner.AssemblyLinearVelocity=Vector3.zero
		prisoner.CFrame=CFrame.lookAt(goal,goal+dir)
		cop.root.AssemblyLinearVelocity=Vector3.zero
		cop.root.CFrame=CFrame.lookAt(goal-dir*(o.formationGap or 2.8),goal)
		table.insert(trail,goal)
		clearPath(lead);clearPath(rear)
		return true
	end
	local rearSnaps=0
	while alive() and cop.alive and cop.root.Parent and os.clock()<deadline do
		if prisoner and (hum.Health<=0 or o.escortee.Character~=char) then return finish(false,"prisoner lost") end
		if o.keepDoor and os.clock()-lastDoor>1 then lastDoor=os.clock();pcall(o.keepDoor) end
		local gap=if prisoner then flat(prisoner.Position-cop.root.Position).Magnitude else 0
		do
			local now=os.clock()
			if flat(leaderRoot.Position-watch.lead).Magnitude>0.75 or flat(cop.root.Position-watch.rear).Magnitude>0.75 then
				watch.at,watch.lead,watch.rear=now,leaderRoot.Position,cop.root.Position
			end
			if prisoner and gap>=8 then watch.driftSince=watch.driftSince or now else watch.driftSince=nil end
			local stalled=now-watch.at>1.5
			local drifted=watch.driftSince~=nil and now-watch.driftSince>3
			if (stalled or drifted) and watch.replans<4 then
				watch.replans+=1
				watch.at,watch.lead,watch.rear,watch.driftSince=now,leaderRoot.Position,cop.root.Position,nil
				print(("[PrisonNav] ESCORT REPLAN reason=%s gap=%.1f door=%s"):format(if drifted then "prisoner drift" else "no progress",gap,o.directDoor and o.directDoor.Name or "none"))
				clearPath(lead);clearPath(rear)
				lead.nextCompute=nil;rear.nextCompute=nil
			end
		end
		local reached=false
		local leadGoal=goal
		if o.allowClearCorridor then
			local delta=flat(goal-leaderRoot.Position)
			if delta.Magnitude>10 then leadGoal=leaderRoot.Position+delta.Unit*10+Vector3.new(0,goal.Y-leaderRoot.Position.Y,0) end
		end
		if gap<8 then
			local why
			reached,why=pathStep(lead,leaderRoot,leadGoal,radius,allowed,function(p,steer)
				leaderHum.WalkSpeed=if prisoner then 8 else cop.cfg.WalkSpeed
				if steer then
					-- Directional walking avoids MoveTo's early-stop radius.
					leaderHum.WalkSpeed=4
					leaderHum:Move(flat(p-leaderRoot.Position).Unit,false)
				else leaderHum:MoveTo(p) end
				if not prisoner then cop.moving=true end
			end,function() leaderHum:MoveTo(leaderRoot.Position) end)
			if why then
				if snapThrough(why) then return finish(true) end
				return finish(false,why)
			end
		else
			leaderHum:MoveTo(leaderRoot.Position);lead.progressAt=os.clock()
		end
		if prisoner then
			if flat(leaderRoot.Position-trail[#trail]).Magnitude>0.5 then table.insert(trail,leaderRoot.Position) end
			while #trail>80 do table.remove(trail,1) end
			local follow=behindTrail(trail,leaderRoot.Position,o.formationGap or 2.8)
			local followGap=flat(follow-cop.root.Position).Magnitude
			local settled,why=pathStep(rear,cop.root,follow,1.9,allowed,function(p)
				-- Match walking speed with gentle catch-up; no stop at each breadcrumb.
				cop.hum.WalkSpeed=math.clamp(8+(followGap-1)*0.6,6,10)
				cop.moving=true;cop.hum:MoveTo(p)
			end,function() cop:stop() end)
			if why then
				-- v218: the officer behind got hung on a door frame: put him back
				-- behind the prisoner instead of abandoning the whole leg
				if rearSnaps<3 and follow then
					rearSnaps+=1
					local look=flat(leaderRoot.Position-follow)
					cop.root.AssemblyLinearVelocity=Vector3.zero
					cop.root.CFrame=if look.Magnitude>0.1 then CFrame.lookAt(follow,follow+look) else CFrame.new(follow)
					clearPath(rear);rear.failures=0;rear.progressAt=os.clock();rear.invalid=false
				else
					return finish(false,"officer following: "..why)
				end
			end
			cop:updateAnim()
			if reached and (o.continueMotion or settled or followGap<1) then
				if (goal-leaderRoot.Position).Magnitude<math.max(2,o.arrivalRadius or 2) then return finish(true) end
				clearPath(lead)
			end
		else
			cop:updateAnim()
			if reached then
				if (goal-leaderRoot.Position).Magnitude<math.max(2,o.arrivalRadius or 2) then return finish(true) end
				clearPath(lead)
			end
		end
		task.wait(0.05)
	end
	return finish(false,if alive() and cop.alive then "local timeout" else "cancelled")
end

local function traverse(cop: any, route: any, dest: any, o: any): (boolean, string?)
	local deadline = os.clock()+(o.maxTime or 120)
	local ids, i, retries = route.nodes, 1, 0
	local motion={}
	drawRoute(o.owner or cop, route.points)
	while i <= #ids and os.clock()<deadline do
		local id = ids[i]
		local node = nodes[id]
		local edge = if i>1 then edgeBetween(ids[i-1],id) else nil
		local doorId = node.doorId or (node.door and id) or (edge and edge.door)
		local leg = table.clone(o)
		leg.motion=motion
		leg.continueMotion=i<#ids
		leg.maxTime = math.min(math.max(12,flat(node.pos-cop.root.Position).Magnitude/4+8),deadline-os.clock())
		if doorId then
			if flat(nodes[doorId].pos-cop.root.Position).Magnitude>CFG.DoorLead then
				local sides=nodes[doorId].door.sides
				-- v193: approach the side of the door the officer is ON. Picking the
				-- nearer side by distance chose the far side when standing diagonal
				-- to the door (High sEcuirty Cellbock Door), i.e. a goal behind the
				-- still-closed door.
				local dpos=nodes[doorId].pos
				local here=cop.root.Position
				local function sameSide(sid)
					return flat(nodes[sid].pos-dpos):Dot(flat(here-dpos))>0
				end
				local side=sides[1]
				if sameSide(sides[2]) and not sameSide(sides[1]) then side=sides[2]
				elseif sameSide(sides[1])==sameSide(sides[2]) and (nodes[sides[2]].pos-here).Magnitude<(nodes[side].pos-here).Magnitude then side=sides[2] end
				-- v198: the route already says which side it enters from - trust it.
				-- The plane test above is wrong for a corridor running alongside the
				-- room (Hallway_7 beside High Security is "north" of that door).
				local entry=nil
				if node.kind=="DOOR_SIDE" and node.doorId==doorId then entry=id
				elseif i>1 and nodes[ids[i-1]].doorId==doorId and nodes[ids[i-1]].kind=="DOOR_SIDE" then entry=ids[i-1] end
				if entry and table.find(sides,entry) then side=entry end
				local approach=table.clone(leg)
				approach.radius=1.9
				local approached,why=Nav.localTravel(cop,nodes[side].pos+Vector3.new(0,2.5,0),approach)
				if not approached then return false,why end
			end
			leg.radius=1.9
			leg.directDoor=nodes[doorId].door.marker
			leg.keepDoor=function()
				if flat(nodes[doorId].pos-cop.root.Position).Magnitude<=CFG.DoorLead then openDoorId(doorId) end
			end
			leg.keepDoor()
			task.wait(CFG.DoorClearance)
		end
		local ok, why=Nav.localTravel(cop,node.pos+Vector3.new(0,2.5,0),leg)
		if ok then
			i+=1
		else
			if why=="cancelled" or why=="prisoner lost" then return false,why end
			if i>1 then blocked[edgeKey(ids[i-1],id)]=os.clock()+CFG.BlockedEdgeTime end
			retries+=1
			if retries>CFG.MaxReroutes then return false,why end
			warn("[PrisonNav] REPATH: "..tostring(why))
			local nextRoute=Nav.getRoute(cop.root.Position,dest,o.routeOpts)
			if not nextRoute then return false,"no alternative route" end
			ids,i=nextRoute.nodes,1
		end
	end
	return i>#ids, if i>#ids then nil else "route timeout"
end

local function finalLeg(cop: any, goal: Vector3, o: any): (boolean, string?)
	local leg=table.clone(o)
	leg.maxTime=o.finalTime or 20
	leg.settlePrisoner=true
	return Nav.localTravel(cop,goal+Vector3.new(0,2.5,0),leg)
end

-- Walk a cop to a destination (name or Vector3). o.escortee = Player to bring along.
function Nav.travel(cop: any, dest: any, o: any?): (boolean, string?)
	o = o or {}
	if not cop or not cop.alive then
		return false, "no officer"
	end
	local route, why = Nav.getRoute(cop.root.Position, dest, o.routeOpts)
	if not route then
		return false, why
	end
	if o.logRoute ~= false then
		local doorNames = {}
		for _, did in route.doors do
			table.insert(doorNames, nodes[did].name or "door")
		end
		log("%s route: %d nodes via %s", o.label or "NPC", #route.nodes, if #doorNames > 0 then table.concat(doorNames, " > ") else "no doors")
	end
	local ok, reason = traverse(cop, route, dest, o)
	if not ok then
		return false, reason
	end
	if route.goal then
		local finished,finalWhy=finalLeg(cop, route.goal, o)
		if not finished then
			return false, "final approach: "..tostring(finalWhy)
		end
	end
	return true, nil
end

function Nav.escort(cop: any, player: Player, dest: any, o: any?): (boolean, string?)
	o = table.clone(o or {})
	o.escortee = player
	return Nav.travel(cop, dest, o)
end

-- Follow one of YOUR mapped routes exactly (authoritative), entering it via the graph.
function Nav.escortAlong(cop: any, player: Player?, routeName: string, o: any?): (boolean, string?)
	o = table.clone(o or {})
	o.escortee = player
	o.honorWaits = false
	local ids = routes[routeName]
	if not ids then
		for name, list in routes do
			if string.lower(name) == string.lower(routeName) then
				ids = list
			end
		end
	end
	if not ids then
		return false, "unknown route " .. routeName
	end
	local seq = table.clone(ids)
	local meta = routeMeta[routeName]
	local here = cop.root.Position
	if not (meta and meta.oneWay) and (nodes[seq[#seq]].pos - here).Magnitude < (nodes[seq[1]].pos - here).Magnitude then
		local rev = {}
		for k = #seq, 1, -1 do
			table.insert(rev, seq[k])
		end
		seq = rev
	end
	-- get onto the route through the graph first if we're not at its start
	if (nodes[seq[1]].pos - here).Magnitude > 6 then
		local startId = Nav.nearestNode(here, nil, false)
		local lead = startId and Nav.findPath(startId, seq[1], nil)
		if lead then
			for k = #lead - 1, 1, -1 do
				table.insert(seq, 1, lead[k])
			end
		end
	end
	local points = { here }
	for _, id in seq do
		table.insert(points, nodes[id].pos)
	end
	log("%s following mapped route '%s' (%d points)", o.label or "NPC", routeName, #seq)
	return traverse(cop, { nodes = seq, points = points, doors = {} }, "ROUTE:" .. string.upper(routeName) .. ":END", o)
end

---------------------------------------------------------------------------
-- guard patrols
---------------------------------------------------------------------------
local function patrolCandidates(zoneKey: string): { number }
	local areas = CFG.PatrolAreas[zoneKey] or { zoneKey }
	local set = {}
	for _, a in areas do
		set[a] = true
	end
	local out = {}
	for _, n in nodes do
		if componentOf[n.id] == mainComponent and n.zone and not n.zone.cell and set[n.zone.area] and (n.kind == "AREA" or n.kind == "PORTAL") then
			table.insert(out, n.id)
		end
	end
	return out
end

function Nav.patrolStart(zoneKey: string): Vector3?
	local c = patrolCandidates(zoneKey)
	if #c == 0 then
		return nil
	end
	return nodes[c[math.random(1, #c)]].pos
end

function Nav.patrol(cop: any, zoneKey: string, alive: () -> boolean)
	task.wait(math.random()*1.5)
	local cands = patrolCandidates(zoneKey)
	if #cands == 0 then
		warn("[PrisonNav] no patrol nodes for zone " .. zoneKey)
		return false
	end
	local allowedAreas = {}
	for _, a in CFG.PatrolAreas[zoneKey] or { zoneKey } do
		allowedAreas[a] = true
	end
	local recent = {}
	local unreachable = {} -- v205: points this guard failed to route to (skip them)
	log("guard patrolling %s (%d patrol points)", zoneKey, #cands)
	while alive() and cop.alive do
		-- a far-ish point nobody else is heading to, not visited lately
		local here = cop.root.Position
		local best, bestScore = nil, -math.huge
		for _, id in cands do
			local claim = patrolClaims[id]
			if not recent[id] and (unreachable[id] or 0) < 2 and (not claim or claim == cop or not claim.alive) then
				local d = (nodes[id].pos - here).Magnitude
				local score = math.min(d, 120) - (if d < 12 then 200 else 0) + math.random() * 40
				if score > bestScore then
					best, bestScore = id, score
				end
			end
		end
		if not best then
			if next(recent) == nil then
				-- every point failed from here: forget and rest before trying again
				table.clear(unreachable)
				task.wait(15)
			end
			table.clear(recent)
			task.wait(1)
			continue
		end
		patrolClaims[best] = cop
		recent[best] = true
		local count = 0
		for _ in recent do
			count += 1
		end
		if count > math.max(3, #cands // 2) then
			table.clear(recent)
			recent[best] = true
		end
		local ok = Nav.travel(cop, nodes[best].pos, {
			alive = alive,
			maxTime = 90,
			label = "GUARD " .. zoneKey,
			logRoute = false,
			routeOpts = {
				-- guards stay in their area; corridors / doors / portals between are fine
				allowed = function(n: any): boolean
					if not n.zone then
						return true
					end
					return allowedAreas[n.zone.area] == true or n.zone.area == "CORRIDOR" or n.kind == "PORTAL"
				end,
			},
		})
		if patrolClaims[best] == cop then
			patrolClaims[best] = nil
		end
		if not ok then
			unreachable[best] = (unreachable[best] or 0) + 1
		end
		cop:stop()
		cop:updateAnim()
		if not ok then
			task.wait(1)
		else
			task.wait(CFG.PatrolPause[1] + math.random() * (CFG.PatrolPause[2] - CFG.PatrolPause[1]))
		end
	end
	return true
end

return Nav
