--[[
	PoliceAI · Tactics
	Foot-officer coordination for one incident. Runs once per RoleRefresh (not per officer
	per frame) and hands each officer a role plus a position:

	  CONTACT     talks to / approaches the suspect; usually the arrest owner
	  COVER       overwatch for the contact officer from cover, offset so nobody is in a
	              shot line (armed suspects: everyone stays in one arc -> no crossfire)
	  LESSLETHAL  the one officer designated to tase / beanbag
	  SHIELD      riot officers lead close approaches
	  INTERCEPT   foot pursuit: runs for where the suspect is going, not where he is
	  PERIMETER   containment on the likely exits
	  SEARCH      sweeps search points when contact is lost (see Search)
	  HOLD        critical / custody: stand off, no force
]]

local Tactics = {}
local Ctx, Tuning, Log, Util, Knowledge, Threat, CopAI, Config

function Tactics.bind(ctx)
	Ctx = ctx
	Tuning, Log, Util, Knowledge, Threat, CopAI, Config = ctx.Tuning, ctx.Log, ctx.Util, ctx.Knowledge, ctx.Threat, ctx.CopAI, ctx.Config
	task.defer(function() pcall(Tactics.markDoors) end)
	task.delay(12, function() pcall(Tactics.markDoors) end) -- BankServer tags its doors a little later
end

---------------------------------------------------------------------------
-- v250 doors police can open are PASS-THROUGH for pathfinding: a closed bank
-- staff door used to make "no path" (lobby -> vault = NoPath), so officers ran
-- straight at the suspect into walls. Doors still open as officers reach them
-- (PoliceDoorAccess). Prison / City Jail doors are left alone (prison nav).
---------------------------------------------------------------------------
local CollectionService = game:GetService("CollectionService")
local DOOR_NAMES = { BankDoor = true, GNCDoor = true, FrontDoor = true, RestrictedDoor = true }
local function custodial(inst: Instance): boolean
	return inst:FindFirstAncestor("CorrectionalFacility") ~= nil or inst:FindFirstAncestor("City Jail") ~= nil
		or inst:GetAttribute("PrisonDoor") == true
end
local function passThrough(inst: Instance): number
	local n = 0
	local parts = if inst:IsA("BasePart") then { inst } else inst:GetDescendants()
	for _, p in parts do
		if p:IsA("BasePart") and not p:FindFirstChild("PoliceDoorPassThrough") then
			local m = Instance.new("PathfindingModifier")
			m.Name = "PoliceDoorPassThrough"
			m.Label = "PoliceDoor"
			m.PassThrough = true
			m.Parent = p
			n += 1
		end
	end
	return n
end
local doorsHooked = false
function Tactics.markDoors()
	local n = 0
	for _, d in CollectionService:GetTagged("PoliceAutoDoor") do
		if not custodial(d) then n += passThrough(d) end
	end
	for _, d in workspace:GetDescendants() do
		if DOOR_NAMES[d.Name] and (d:IsA("BasePart") or d:IsA("Model")) and not custodial(d) then n += passThrough(d) end
	end
	if not doorsHooked then
		doorsHooked = true
		CollectionService:GetInstanceAddedSignal("PoliceAutoDoor"):Connect(function(d)
			if not custodial(d) then passThrough(d) end
		end)
	end
	Log.event("DOORS", "%d door part(s) pass-through for police pathfinding", n)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function dirOf(angle: number): Vector3
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

-- Foot officers currently on this incident.
function Tactics.collect(inc: any): { any }
	local list = {}
	for cop in CopAI.all do
		if cop.alive and cop.active and cop.pursuit == inc.pursuit and cop.state ~= "leave" and cop.root and cop.root.Parent then
			table.insert(list, cop)
		end
	end
	return list
end

local coverParams: RaycastParams? = nil
local function castParams(): RaycastParams
	local params = coverParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		coverParams = params
	end
	local list = table.clone(Util.ignoreRoots)
	for _, c in Util.playerCharacters() do
		table.insert(list, c)
	end
	params.FilterDescendantsInstances = list
	return params
end

-- Find a spot near `slot` where low geometry shields the officer from `threat`
-- but he can still see over / around it.
function Tactics.coverNear(slot: Vector3, threat: Vector3): Vector3?
	local T = Tuning.Tactics
	local params = castParams()
	local best, bestScore = nil, -math.huge
	for i = 0, 15 do
		local r = if i % 3 == 0 then T.CoverSearch else (if i % 3 == 1 then T.CoverSearch * 0.65 else T.CoverSearch * 0.35)
		local cand = slot + dirOf(i / 16 * math.pi * 2) * r
		local g = Util.groundAt(cand, 10, 30)
		if not g then
			continue
		end
		local low = g + Vector3.new(0, 1.3, 0)
		local toward = threat - low
		local lowHit = workspace:Raycast(low, toward, params)
		local covered = lowHit ~= nil and (lowHit.Position - low).Magnitude < 7 and (lowHit.Position - low).Magnitude < toward.Magnitude - 2
		if not covered then
			continue
		end
		local eye = g + Vector3.new(0, 4.4, 0)
		local eyeHit = workspace:Raycast(eye, threat - eye, params)
		local canPeek = eyeHit == nil or (eyeHit.Position - eye).Magnitude >= (threat - eye).Magnitude - 2
		local score = (if canPeek then 3 else 1) - (g - slot).Magnitude / T.CoverSearch
		if canPeek and score > bestScore then
			bestScore, best = score, g
		end
	end
	return best
end

-- Is the line from `from` to `to` free of other officers on this incident?
function Tactics.clearShot(cop: any, inc: any, from: Vector3, to: Vector3): boolean
	local dir = to - from
	local len = dir.Magnitude
	if len < 0.5 then
		return true
	end
	local u = dir / len
	local width = Tuning.Tactics.FireLaneWidth
	for other in inc.units do
		if other ~= cop and other.alive and other.root then
			local rel = other.root.Position - from
			local along = rel:Dot(u)
			if along > 1 and along < len + 14 then
				if (rel - u * along).Magnitude < width then
					return false
				end
			end
		end
	end
	return true
end

local function snap(pos: Vector3): Vector3
	return Util.groundAt(pos, 12, 40) or pos
end

-- spread slot positions so no two are closer than MinSpacing
local function spread(slots: { Vector3 }, center: Vector3)
	local minS = Tuning.Tactics.MinSpacing
	for i = 2, #slots do
		for _ = 1, 3 do
			local moved = false
			for j = 1, i - 1 do
				if (slots[i] - slots[j]).Magnitude < minS then
					local out = Util.safeUnit(flat(slots[i] - center), Vector3.xAxis)
					local side = Vector3.new(-out.Z, 0, out.X)
					slots[i] += side * minS * 0.8 + out * 2
					moved = true
				end
			end
			if not moved then
				break
			end
		end
	end
end

local function setRole(inc: any, cop: any, role: string, slot: Vector3?, now: number)
	local entry = inc.units[cop]
	if not entry then
		entry = { role = role, since = now }
		inc.units[cop] = entry
	elseif entry.role ~= role then
		entry.role = role
		entry.since = now
		entry.searchPoint = nil
	end
	entry.slot = slot
	if cop.model and cop.model.Parent then
		cop.model:SetAttribute("IncidentId", inc.id)
		cop.model:SetAttribute("IncidentRole", role)
	end
end

-- Shared on-foot plan. Positions persist until the last observed location moves.
-- Only reachable, physically clear positions become movement goals.
local Pathfinding=game:GetService("PathfindingService")
local ServerStorage=game:GetService("ServerStorage")
local Debris=game:GetService("Debris")
local doorCache,doorScan={},-math.huge

-- v195 perf: PathfindingService per officer slot per plan is expensive;
-- remember answers for 8s on a 4-stud grid (start and end).
local reachCache={}
local function reachKey(a,b)
 return math.floor(a.X/4)..","..math.floor(a.Z/4)..">"..math.floor(b.X/4)..","..math.floor(b.Z/4)
end
function Tactics.reachable(cop,point)
 local key=reachKey(cop.root.Position,point)
 local hit=reachCache[key]
 local now=os.clock()
 if hit and now-hit.at<8 then return hit.ok end
 local ok=Tactics.reachableUncached(cop,point)
 reachCache[key]={ok=ok,at=now}
 if math.random()<0.02 then for k,v in reachCache do if now-v.at>8 then reachCache[k]=nil end end end
 return ok
end
function Tactics.reachableUncached(cop,point)
 local path=Pathfinding:CreatePath({AgentRadius=1.7,AgentHeight=5,AgentCanJump=true,AgentCanClimb=true,WaypointSpacing=4})
 local ok=pcall(function() path:ComputeAsync(cop.root.Position,point) end)
 local valid=ok and path.Status==Enum.PathStatus.Success
 path:Destroy();return valid
end

local function roomDoor(inc,now)
 local pos=inc.knowledge.pos
 if not workspace:Raycast(pos+Vector3.new(0,3,0),Vector3.new(0,36,0),castParams()) then return nil end
 if now-doorScan>30 then
  doorScan=now;doorCache={}
  for _,part in workspace:GetDescendants() do
   if part:IsA("BasePart") and (part.Name=="FrontDoor" or part.Name=="BankDoor" or part.Name=="GNCDoor") then table.insert(doorCache,part) end
  end
 end
 local best,distance=nil,65
 for _,door in doorCache do
  if door.Parent and math.abs(door.Position.Y-pos.Y)<9 then
   local d=flat(door.Position-pos).Magnitude
   if d<distance then best,distance=door,d end
  end
 end
 return best
end

local function phase(inc,name,now)
 if inc.squadPhase~=name then
  inc.squadPhase=name;inc.phaseSince=now
  inc.player:SetAttribute("PoliceSquadPhase",name)
  Log.event("SQUAD", "#%d %s",inc.id,name)
 end
end

-- One incident plan, stable officer identities, and bounded execution leases.
local squadSerial=0
function Tactics.coverReady(inc,owner,now)
 local ready=0
 for cop,entry in inc.units do
  if cop~=owner and cop.alive and cop.root and cop.head and
   (entry.role=="COVER" or entry.role=="SHIELD" or entry.role=="SNIPER") then
   local watching=Ctx.Perception.sawRecently(cop,inc,now,1.5)
   local positioned=entry.slot and flat(entry.slot-cop.root.Position).Magnitude<8
   if watching and positioned and Tactics.clearShot(cop,inc,cop.head.Position,inc.knowledge.pos) then ready+=1 end
  end
 end
 return ready>=1
end

function Tactics.canArrest(inc,cop,now)
 if inc.compliance~="Controlled" and inc.compliance~="Complying" then return false end
 if not cop or not cop.alive then return false end
 -- Surrendering unarmed suspects do not need a SWAT stack. An armed/stunned
 -- suspect still needs an actual watching cover officer, not just a timer.
 if not inc.threat.armed and not inc.threat.fired and inc.threat.level~="LETHAL" then return true end
 return Tactics.coverReady(inc,cop,now)
end

function Tactics.canMove(cop,inc,slot,now)
 inc.advanceLeases=inc.advanceLeases or {}
 inc.advanceRest=inc.advanceRest or {}
 local leases=inc.advanceLeases
 if not slot or flat(slot-cop.root.Position).Magnitude<5 then leases[cop]=nil;return true end
 local active=0
 for unit,untilT in leases do
  if not unit.alive or now>=untilT then
   leases[unit]=nil;inc.advanceRest[unit]=now+1.5
  else active+=1 end
 end
 if leases[cop] then return true end
 if now<(inc.advanceRest[cop] or 0) or active>=2 then return false end
 leases[cop]=now+4
 return true
end

function Tactics.fireWindow(cop,inc,now)
 if inc.compliance~="Noncompliant" or inc.pursuit.holdFire or now<(inc.pursuit.stunnedUntil or 0) then return false end
 local candidates={}
 for unit,entry in inc.units do
  if unit.alive and unit.root and (entry.role=="COVER" or entry.role=="SHIELD" or entry.role=="CONTACT" or entry.role=="SNIPER") then
   if entry.slot and flat(entry.slot-unit.root.Position).Magnitude<8 then table.insert(candidates,unit) end
  end
 end
 table.sort(candidates,function(a,b) return (a.squadOrder or 0)<(b.squadOrder or 0) end)
 local count=#candidates
 if count==0 then return false end
 local index=table.find(candidates,cop)
 if not index then return false end
 -- Two alternating firing positions; pauses create a readable escape/reload window.
 local beat=now%2
 if beat>1.35 then return false end
 local first=(math.floor(now/2)*2)%count+1
 return index==first or (count>1 and index==first%count+1)
end

local function rooftop(cop,center)
 -- Pathfinding must prove stairs/a jump/climb reaches the roof. No teleporting.
 for i=0,7 do
  local p=center+dirOf(i*math.pi/4)*65
  local hit=workspace:Raycast(p+Vector3.new(0,65,0),Vector3.new(0,-60,0),castParams())
  if hit and hit.Normal.Y>0.85 and hit.Position.Y-center.Y>7 and hit.Position.Y-center.Y<50 then
   local stand=hit.Position+Vector3.new(0,0.2,0)
   local sight=workspace:Raycast(stand+Vector3.new(0,4,0),center-stand-Vector3.new(0,4,0),castParams())
   if not sight and Tactics.reachable(cop,stand) then return stand end
  end
 end
 return nil
end

---------------------------------------------------------------------------
-- v250 indoor entry: when the suspect is inside a building, slots on a straight
-- line from the first officer land inside walls and everyone funnels the same way.
-- Instead the squad takes the real walking route in: shield / contact rush along
-- it, two cover officers hold the corners at the last bend before the suspect,
-- less-lethal and support stack behind, everyone else rings the building outside.
---------------------------------------------------------------------------
-- the building the suspect is in (something solid overhead), or nil
function Tactics.indoor(center: Vector3): (Instance?, Vector3?, Vector3?)
	local hit = workspace:Raycast(center + Vector3.new(0, 3, 0), Vector3.new(0, 36, 0), castParams())
	if not hit then return nil end
	local b: Instance = hit.Instance
	while b.Parent and b.Parent ~= workspace do b = b.Parent end
	if b.Parent ~= workspace then return nil end
	if b:IsA("Model") then
		local cf, size = b:GetBoundingBox()
		if math.max(size.X, size.Z) > 600 then return nil end -- a whole map chunk, not a building
		return b, cf.Position, size
	elseif b:IsA("BasePart") then
		return b, b.Position, b.Size
	end
	return nil
end

-- the walking route from the contact officer to the suspect (cached 4 s)
function Tactics.entryRoute(inc: any, from: Vector3, center: Vector3, now: number): { Vector3 }?
	local r = inc.entryRoute
	if r and now - r.at < 4 and flat(r.center - center).Magnitude < 8 then return r.points end
	local path = Pathfinding:CreatePath({ AgentRadius = 1.7, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 3 })
	local ok = pcall(function() path:ComputeAsync(from, center) end)
	local points = nil
	if ok and path.Status == Enum.PathStatus.Success then
		points = {}
		for _, w in path:GetWaypoints() do table.insert(points, w.Position) end
		if #points < 2 then points = nil end
	end
	path:Destroy()
	inc.entryRoute = { at = now, center = center, points = points }
	return points
end

-- a point `back` studs before the end of the route, and the walking direction there
local function alongRoute(points: { Vector3 }, back: number): (Vector3, Vector3)
	local remaining = back
	for i = #points, 2, -1 do
		local a, b = points[i - 1], points[i]
		local seg = (b - a).Magnitude
		if seg >= remaining and seg > 0.01 then
			local dir = Util.safeUnit(flat(b - a), Vector3.xAxis)
			return b + (a - b) * (remaining / seg), dir
		end
		remaining -= seg
	end
	return points[1], Util.safeUnit(flat(points[2] - points[1]), Vector3.xAxis)
end

function Tactics.planFoot(inc,free,now)
 local center=inc.knowledge.pos
 if #free==0 then return end
 local signatureParts={}
 for _,cop in free do
  if not cop.squadOrder then squadSerial+=1;cop.squadOrder=squadSerial end
  table.insert(signatureParts,tostring(cop.squadOrder)..(if cop.hum and cop.hum.Health<cop.hum.MaxHealth*.35 then "w" else "h"))
 end
 table.sort(signatureParts);local signature=table.concat(signatureParts,",")
 local last=inc.footPlan
 if last and now<last.next and last.count==#free and last.signature==signature and flat(center-last.center).Magnitude<12 then return end
 inc.footPlan={center=center,next=now+4,count=#free,signature=signature}
 table.sort(free,function(a,b) return a.squadOrder<b.squadOrder end)
 local contact=inc.arrestOwner or inc.contactUnit
 if not contact or not table.find(free,contact) or (contact.hum and contact.hum.Health<contact.hum.MaxHealth*.35) then
  contact=nil
  for _,cop in free do if not cop.hum or cop.hum.Health>=cop.hum.MaxHealth*.35 then contact=cop;break end end
  contact=contact or free[1]
 end
 inc.contactUnit=contact
 local direction=if last and flat(center-last.center).Magnitude<35 then last.direction else nil
 direction=direction or Util.safeUnit(flat(contact.root.Position-center),Vector3.xAxis)
 inc.footPlan.direction=direction
 local side=Vector3.new(-direction.Z,0,direction.X)
 local dangerous=Threat.dangerous(inc)
 local roles={[contact]="CONTACT"};local support,less
 if #free>=6 and (inc.pursuit.stars or 0)>=3 then
  for _,cop in free do if cop~=contact and cop.marksman and (not cop.hum or cop.hum.Health>=cop.hum.MaxHealth*.35) then roles[cop]="SNIPER";break end end
 end
 -- Reserve overwatch FIRST. A three-person team must not lose all cover to gadgets.
 local coverQuota=if #free>=5 then 2 elseif #free>=2 then 1 else 0
 local covers=0
 for _,cop in free do
  if not roles[cop] and covers<coverQuota and (not cop.hum or cop.hum.Health>=cop.hum.MaxHealth*.35) then
   roles[cop]=if cop.shield then "SHIELD" else "COVER";covers+=1
  end
 end
 local lessQuota=if #free>=7 then 2 elseif #free>=3 then 1 else 0;local lessCount=0
 for _,cop in free do
  if not roles[cop] then
   if cop.hum and cop.hum.Health<cop.hum.MaxHealth*.35 then roles[cop]="RESERVE"
   elseif lessCount<lessQuota then
    roles[cop]="LESSLETHAL";lessCount+=1;less=less or cop
    if not cop.rubber then cop.rubber=Ctx.Weapons.new("Rubber",nil,cop.head);cop.model:SetAttribute("PoliceLoadout","Rubber") end
   elseif not support and #free>=4 and ((cop.tearGas or 0)>0 or (cop.flashbangs or 0)>0) then roles[cop]="SUPPORT";support=cop
   elseif cop.marksman and #free>=5 and (inc.pursuit.stars or 0)>=3 then roles[cop]="SNIPER"
   else roles[cop]="PERIMETER" end
  end
 end
 -- v191 containment: PERIMETER officers take evenly spaced positions on a
 -- ring around the suspect (escape routes), skipping the contact sector.
 local perimeterList={}
 for _,cop in free do if roles[cop]=="PERIMETER" then table.insert(perimeterList,cop) end end
 local C=Tuning.Containment
 local ringRadius=if dangerous then C.RadiusDangerous else C.Radius
 local baseAngle=math.atan2(direction.Z,direction.X)
 local ringSlot={}
 for k,cop in perimeterList do
  local span=math.pi*2-C.ContactGap*2
  local a=baseAngle+C.ContactGap+span*(k-0.5)/#perimeterList
  ringSlot[cop]=center+dirOf(a)*ringRadius
 end
 local containing=#perimeterList>=2 or inc.pursuit.swatRequested==true
 -- v250: indoor suspect -> follow the real route in, ring the building outside
 local building,bCenter,bSize=nil,nil,nil
 if not inc.knowledge.inVehicle then building,bCenter,bSize=Tactics.indoor(center) end
 local route=if building then Tactics.entryRoute(inc,contact.root.Position,center,now) else nil
 local hasShield=false
 for _,cop in free do if roles[cop]=="SHIELD" then hasShield=true end end
 local coverSide=1
 local outsideCount,outsideIndex=0,0
 if route and bCenter and bSize then
  for _,cop in free do local r=roles[cop];if r=="PERIMETER" or r=="RESERVE" or r=="SNIPER" then outsideCount+=1 end end
 end
 local claimed={};local sniperAssigned=false
 for index,cop in free do
  local role=roles[cop]
  if role=="SNIPER" then if sniperAssigned then role="PERIMETER" else sniperAssigned=true end end
  local flank=if index%2==0 then 1 else -1
  local depth=if role=="CONTACT" then 18 elseif role=="LESSLETHAL" then 23 elseif role=="SUPPORT" then 32 elseif role=="RESERVE" then 85 elseif role=="PERIMETER" then 65 elseif role=="SNIPER" then 75 else 35
  if not dangerous then depth=math.max(10,depth-8) end
  local desired=ringSlot[cop] or (center+direction*depth+side*(if role=="CONTACT" then 0 else flank*(8+math.floor(index/2)*6)))
  local old=inc.units[cop]
  local onRoute=false
  local cover,candidate
  if route and bCenter and bSize then
   if role=="PERIMETER" or role=="RESERVE" or role=="SNIPER" then
    -- the outside ring: evenly around the building, covering its exits
    outsideIndex+=1
    local a=outsideIndex/math.max(1,outsideCount)*math.pi*2
    local radius=math.max(bSize.X,bSize.Z)/2+14
    desired=Vector3.new(bCenter.X,center.Y,bCenter.Z)+dirOf(a)*radius
    cover=nil;candidate=snap(desired)
   else
    local back=if role=="SHIELD" then 3 elseif role=="CONTACT" then (if hasShield then 7 else 4) elseif role=="LESSLETHAL" then 9
     elseif role=="COVER" then 12 elseif role=="SUPPORT" then 16 else 14
    local p,dirAt=alongRoute(route,back)
    local sideAt=Vector3.new(-dirAt.Z,0,dirAt.X)
    if role=="COVER" then p+=sideAt*(2.5*coverSide);coverSide=-coverSide end -- the two corners of the doorway
    cover=nil;candidate=p;onRoute=true
   end
  else
   cover=Tactics.coverNear(desired,center+Vector3.new(0,2,0))
   candidate=cover or snap(desired)
  end
  if role=="SNIPER" and not route then
   if not cop.roofCheckAt or now>=cop.roofCheckAt then cop.roofCheckAt=now+30;cop.roofSlot=rooftop(cop,center) end
   candidate=cop.roofSlot or candidate;cover=cop.roofSlot or cover
  end
  local separate=true
  local minSep=if onRoute then 2.5 else 7
  for _,occupied in claimed do if flat(candidate-occupied).Magnitude<minSep then separate=false end end
  if onRoute and separate then
   -- on the route by construction: no extra reachability check
  elseif not separate or not Tactics.reachable(cop,candidate) then
   candidate=if old and old.slot and flat(old.slot-center).Magnitude>12 then old.slot else cop.root.Position
   cover=nil
  end
  table.insert(claimed,candidate);setRole(inc,cop,role,candidate,now)
  inc.units[cop].covered=cover~=nil
 end
 if route then
  phase(inc,"INDOOR_ENTRY",now)
 else
  phase(inc,if Tactics.coverReady(inc,contact,now) then (if containing then "CONTAIN_AND_CONTROL" else "COVER_AND_CONTROL") else (if containing then "CONTAIN" else "ESTABLISH_COVER"),now)
 end
 -- A roof and a nearby designated entry identify a structure; staging still
 -- requires physical paths and recent reported/seen information.
 if not inc.knowledge.inVehicle and (inc.pursuit.stars or 0)>=3 and not inc.breach then
  local door=roomDoor(inc,now)
  if door then
   local axis=if door.Size.X<door.Size.Z then door.CFrame.RightVector else door.CFrame.LookVector
   axis=Util.safeUnit(flat(axis),Vector3.xAxis)
   if axis:Dot(center-door.Position)<0 then axis=-axis end
   local outside=Util.groundAt(door.Position-axis*7,8,25)
   if outside and Tactics.reachable(contact,outside) and (contact.root.Position-door.Position):Dot(axis)<0 then
    door:SetAttribute("PoliceStackUntil",now+32)
    inc.breach={door=door,outside=outside,inward=axis,inside=outside+axis*12,started=now,state="STACK",entry=contact,support=support or less,next=now+3}
    phase(inc,"BREACH_STACK",now)
   end
  end
 end
end

function Tactics.openBreach(door)
 local name=if door.Name=="FrontDoor" then "PoliceHouseBreach" else "PoliceDoorAccess"
 local bridge=ServerStorage:FindFirstChild(name)
 if not bridge or not bridge:IsA("BindableFunction") then return false end
 local ok,result=pcall(function() return bridge:Invoke("Breach",door,18) end)
 return ok and result==true
end

function Tactics.breachStep(cop,inc,now)
 local b=inc.breach
 if not b or inc.mode=="CUSTODY" or inc.mode=="CRITICAL" then return false end
 if not b.door.Parent or now-b.started>32 or flat(inc.knowledge.pos-b.door.Position).Magnitude>80 then
  inc.breach=nil;phase(inc,"REASSESS",now);return false
 end
 local flank=Vector3.new(-b.inward.Z,0,b.inward.X)
 local entry=cop==b.entry;local support=cop==b.support
 if not entry and not support then return false end
 if not b.entry.alive or not b.support or not b.support.alive then inc.breach=nil;phase(inc,"BREACH_ABORT",now);return false end
 local stack=b.outside+flank*(if entry then -3 else 3)
 if b.state=="STACK" then
  if flat(cop.root.Position-stack).Magnitude>3 then cop:moveTo(stack,false) else cop:stop();cop:face(b.door.Position) end
  if entry and b.support and b.support.alive and flat(b.support.root.Position-(b.outside+flank*3)).Magnitude<5 and flat(cop.root.Position-stack).Magnitude<4 and now>=b.next then
   local covering=false
   for c,e in inc.units do if c~=cop and c~=b.support and c.alive and (e.role=="COVER" or e.role=="SHIELD") and (e.covered or c.shield) and e.slot and flat(c.root.Position-e.slot).Magnitude<7 and Tactics.clearShot(c,inc,c.head.Position,b.outside+Vector3.new(0,2,0)) then covering=true end end
   if covering and Tactics.openBreach(b.door) then b.state="DEPLOY";b.next=now+0.5;phase(inc,"BREACH_OPEN",now) end
  end
  return true
 end
 if b.state=="DEPLOY" then
  cop:stop();cop:face(b.inside)
  if support and now>=b.next then
   if Tactics.supportDevice(cop,inc,now,b.inside+Vector3.new(0,2,0),true) then
    b.state="WAIT";b.next=now+2.5;phase(inc,"BREACH_DEVICE",now)
   else b.state="WAIT";b.next=now+3 end
  end
  return true
 end
 if b.state=="WAIT" then
  cop:stop()
  if now>=b.next then b.state="ENTRY";phase(inc,"BREACH_ENTRY",now) end
  return true
 end
 if b.state=="ENTRY" then
  local goal=b.inside+flank*(if entry then -1.5 else 1.5)
  local result=cop:moveTo(goal,false)
  if flat(cop.root.Position-goal).Magnitude<4 or result=="failed" then
   inc.breach=nil;inc.footPlan=nil;phase(inc,"ROOM_REASSESS",now)
  end
  return true
 end
 return false
end

function Tactics.deviceReady(inc,cop,now)
 -- Throw support needs a visible supporting officer, not two occupied pieces
 -- of map cover. Keep the stricter hands-on arrest gate separate.
 for ally in inc.units do
  if ally~=cop and ally.alive and ally.root and (ally.root.Position-cop.root.Position).Magnitude<65 and Ctx.Perception.sawRecently(ally,inc,now,1.5) then return true end
 end
 return inc.threat.fired==true and Ctx.Perception.sawRecently(cop,inc,now,1.0)
end

function Tactics.supportDevice(cop,inc,now,target,breach)
 if inc.compliance~="Noncompliant" or inc.pursuit.holdFire or inc.player:GetAttribute("PoliceCritical")==true or now<(inc.deviceAt or 0) then return false end
 if not breach and not Tactics.deviceReady(inc,cop,now) then return false end
 if now<(inc.pursuit.stunnedUntil or 0)+0.75 then return false end
 if (target-cop.head.Position).Magnitude>65 then return false end
 local char=inc.player.Character
 local obstruction=workspace:Raycast(cop.head.Position,target-cop.head.Position,castParams())
 if obstruction then return false end
 local function exposed(pos,radius)
  local c,h,r=Util.charInfo(inc.player)
  return not inc.closed and inc.compliance=="Noncompliant" and c==char and h and r and h.Health>0 and not h:GetAttribute("PoliceCuffed") and not inc.pursuit.holdFire and (r.Position-pos).Magnitude<radius and Util.canSee(pos+Vector3.new(0,1,0),c,r,{cop.model})
 end
 local heavy=(cop.flashbangs or 0)<=0 and (cop.tearGas or 0)<=0 and not breach and inc.threat.level=="LETHAL" and (inc.pursuit.stars or 0)>=5 and (cop.ordnance or 0)>0
 if heavy then
  -- Large support munitions require a clear area, including civilian players.
  for _,character in Util.playerCharacters() do
   local root=character:FindFirstChild("HumanoidRootPart")
   if character~=char and root and (root.Position-target).Magnitude<30 then heavy=false end
  end
  for c in CopAI.all do if c.alive and c.root and (c.root.Position-target).Magnitude<30 then heavy=false end end
  -- Houses/banks use gas/flash; no fire or fragmentation in interior rooms.
  if workspace:Raycast(target,Vector3.new(0,35,0),castParams()) then heavy=false end
 end
 if heavy then
  cop.ordnance-=1;inc.deviceAt=now+30
  Ctx.Weapons.throwTacticalOrdnance(cop.ordnanceKind,cop.head.Position,target,function(pos)
   if exposed(pos,14) then
    for c in CopAI.all do if c.alive and c.root and (c.root.Position-pos).Magnitude<20 then return end end
    for _,character in Util.playerCharacters() do local r=character:FindFirstChild("HumanoidRootPart");if character~=char and r and (r.Position-pos).Magnitude<20 then return end end
    local _,h=Util.charInfo(inc.player)
    h.Health=math.max(1,h.Health-(if cop.ordnanceKind=="FRAG" then 22 else 4))
   end
  end)
 elseif (cop.flashbangs or 0)>0 and not (inc.lastDevice=="FLASH" and (cop.tearGas or 0)>0) then
  cop.flashbangs-=1;inc.deviceAt=now+7;inc.lastDevice="FLASH";inc.player:SetAttribute("LastPoliceLessLethal","FLASH")
  Ctx.Weapons.throwFlashbang(cop.head.Position,target,function(pos)
   if exposed(pos,Config.Flashbang.Radius) then Ctx.Heat.stun(inc.player,2.2);Ctx.Arrest.onStun(inc,cop,2.2) end
  end)
 elseif (cop.tearGas or 0)>0 then
  cop.tearGas-=1;inc.deviceAt=now+10;inc.lastDevice="GAS";inc.player:SetAttribute("LastPoliceLessLethal","GAS")
  Ctx.Weapons.throwTearGas(cop.head.Position,target,function(pos)
   task.spawn(function()
    local untilT=os.clock()+6
    while os.clock()<untilT and inc.pursuit.active do
     if exposed(pos,Config.TearGas.Radius) and inc.compliance=="Noncompliant" and os.clock()>=(inc.pursuit.stunnedUntil or 0)+0.75 then Ctx.Heat.stun(inc.player,1.2);Ctx.Arrest.onStun(inc,cop,1.2);break end
     task.wait(0.4)
    end
   end)
  end)
 else return false end
 Ctx.Voice.say(cop,"Cover the entry! Device out!",inc,{command=false})
 return true
end

function Tactics.sniperLaser(cop,target,enabled)
 if not enabled then if cop.aimLaser then cop.aimLaser:Destroy();cop.aimLaser=nil end;return end
 local from=cop.head.Position
 local hit=workspace:Raycast(from,target-from,castParams())
 local finish=if hit then hit.Position else target
 local length=(finish-from).Magnitude
 if length<0.1 then return end
 local p=cop.aimLaser
 if not p or not p.Parent then
  p=Instance.new("Part");p.Name="PoliceAimLaser";p.Anchored=true;p.CanCollide=false;p.CanTouch=false;p.CanQuery=false
  p.Material=Enum.Material.Neon;p.Color=Color3.fromRGB(255,45,35);p.Transparency=0.35;p.Parent=cop.model;cop.aimLaser=p
 end
 p.Size=Vector3.new(0.035,0.035,length);p.CFrame=CFrame.lookAt((from+finish)/2,finish)
end

local function assignImpl(inc: any, now: number)
	local T = Tuning.Tactics
	local k = inc.knowledge
	local list = Tactics.collect(inc)
	-- drop officers who left the incident
	local present = {}
	for _, c in list do
		present[c] = true
	end
	for cop in inc.units do
		if not present[cop] then
			inc.units[cop] = nil
			if cop.model and cop.model.Parent then
				cop.model:SetAttribute("IncidentRole", nil)
				cop.model:SetAttribute("IncidentId", nil)
			end
		end
	end
	if #list == 0 then
		return
	end
	local center = k.pos
	table.sort(list, function(a, b)
		return flat(a.root.Position - center).Magnitude < flat(b.root.Position - center).Magnitude
	end)

	-- officers with a scripted / fixed job (spike deployers, roadblock crews) keep it
	local free = {}
	for _, c in list do
		if c.aiScripted or c.aiFixedRole then
			setRole(inc, c, c.aiFixedRole or "SCRIPTED", c.aiHoldPos, now)
		else
			table.insert(free, c)
		end
	end
	if #free == 0 then
		return
	end

	local mode = inc.mode
	if mode == "CRITICAL" or mode == "CUSTODY" then
		local owner = inc.arrestOwner
		local ring = if mode == "CRITICAL" then Tuning.Arrest.CriticalRing else Tuning.Arrest.CoverRing
		local n = #free
		for i, c in free do
			if c == owner and mode == "CUSTODY" then
				setRole(inc, c, "CONTACT", nil, now)
			else
				local bearing = flat(c.root.Position - center)
				local a = math.atan2(bearing.Z, bearing.X) + (i - n / 2) * 0.12
				local previous=inc.units[c]
                local slot=if mode=="CUSTODY" and previous and previous.slot then previous.slot else snap(center+dirOf(a)*ring)
                setRole(inc,c,if mode=="CRITICAL" then "HOLD" else "COVER",slot,now)
			end
		end
		return
	end

	if mode == "SEARCH" then
		Ctx.Search.assign(inc, free, now, setRole)
		return
	end

	if mode == "VEHICLE" then
		-- foot officers don't chase cars: mount up if their cruiser is close, otherwise hold near
		-- the road; a stopped car gets a proper felony-stop layout below
		local stopped = k.stoppedSince ~= nil and now - k.stoppedSince >= Tuning.Vehicles.StopTime
		if not stopped then
			for _, c in free do
				local car = c.homeCar
				if car and not car.dead and not car.transporting and car.body and (car.body.Position - c.root.Position).Magnitude < 160 then
					setRole(inc, c, "MOUNT", nil, now)
				else
					setRole(inc, c, "PERIMETER", nil, now)
				end
			end
			return
		end
	end

	Tactics.planFoot(inc,free,now)
end

function Tactics.assign(inc,now)
 if inc.planBusy or inc.closed then return end
 inc.planBusy=true
 local ok,err=pcall(assignImpl,inc,now)
 inc.planBusy=nil
 if not ok then Log.warn("foot plan",err) end
end

function Tactics.role(inc: any, cop: any): (string?, Vector3?)
	local entry = inc.units[cop]
	if entry then
		return entry.role, entry.slot
	end
	return nil, nil
end

return Tactics
