--[[
	PoliceAI · Tuning
	Every number the tactical police brain uses. Distances are studs, times are seconds.
	The legacy Config inside the PoliceSystem script still owns wanted levels, weapons,
	unit types, waves, prison/justice settings. This file only covers the new
	incident / perception / pursuit architecture.
]]

local Tuning = {}

Tuning.Enabled = true
-- Major state transitions ([PoliceAI] INCIDENT CREATED, PRIMARY ASSIGNED, LOST VISUAL ...)
Tuning.Log = true
-- Extra detail (role refreshes, route plans). Leave off unless debugging.
Tuning.VerboseLog = false
-- Mirrors knowledge/threat/compliance onto the suspect as attributes (PoliceKnowledge etc.)
Tuning.DebugAttributes = true

Tuning.Tick = 0.2 -- incident brain cadence (knowledge, compliance). Heavier work is throttled below.

---------------------------------------------------------------------------
-- PERCEPTION  (knowledge comes from line of sight, never from distance alone)
---------------------------------------------------------------------------
Tuning.Perception = {
	DetectRange = 260, -- first notice of a suspect (needs FOV)
	TrackRange = 2500, -- v116: an officer on the call keeps eyes on you this far with clear LOS
	-- v245 vision: clear sight in a 110 degree cone, slower noticing out to 150 degrees, a small
	-- all-round bubble (bigger when you're loud), darkness shortens sight, walking is quieter
	NoticeRange = 7, -- sees you even behind him this close
	LoudNoticeRange = 22, -- ...this close when you're loud (sprinting, driving, shooting)
	FOV = 110,
	PeripheralFOV = 150, -- 110-150 degrees: noticed only after PeripheralChecks sightings in a row
	PeripheralChecks = 2,
	NightDetectScale = 0.6, -- detect range at night (lit by headlights / streetlights not modelled yet)
	WalkDetectScale = 0.75, -- detect range when you're walking, not sprinting
	RadioTurnTime = 0.8, -- seconds for an officer to turn toward a radio report
	TrackMemory = 4, -- seconds an officer keeps looking where he last saw you (FOV ignored)
	IntervalNear = 0.2, -- LOS checks per officer per incident (LOD by distance)
	IntervalMid = 0.4,
	IntervalFar = 0.8,
	CruiserRange = 2500, -- v116: clear line of sight = they still see you, however far
	CruiserInterval = 0.2,
	PatrolCarDetect = 320, -- cruising patrol cars notice wanted suspects this close (forward arc)
}

---------------------------------------------------------------------------
-- INCIDENT KNOWLEDGE
---------------------------------------------------------------------------
Tuning.Knowledge = {
	DirectWindow = 1.1, -- a sighting this fresh = DIRECT_VISUAL / HELICOPTER_REPORTED
	ReportWindow = 2.5, -- non-visual reports (911 call, gunshots heard) = UNIT_REPORTED
	RecentWindow = 3.0, -- after that: RECENT_VISUAL (short dead-reckoning)
	PredictWindow = 9.0, -- after that: PREDICTED (along the road graph / heading)
	PredictFootMax = 60, -- max studs a foot suspect is extrapolated
	PredictCarMax = 320, -- max studs a vehicle suspect is extrapolated along roads
	PredictDecay = 0.035, -- confidence lost per second while PREDICTED
	SearchDecay = { 0.015, 0.012, 0.009, 0.007, 0.0056 }, -- per second while SEARCHING, by stars (v258: 5x slower)
	ContainedDecayScale = 0.1, -- v258: SearchDecay multiplier while the suspect is still inside the building they were last seen in
	ReportConfidence = 0.8,
	TrailSpacing = 6, -- breadcrumbs of where the suspect was SEEN driving/running
	TrailMax = 170,
	TrailBreak = 3.5, -- unseen longer than this: the old trail is not followed any more
}

---------------------------------------------------------------------------
-- THREAT
---------------------------------------------------------------------------
Tuning.Threat = {
	AimCone = 0.94, -- cos of the cone a gun must point inside to count as "aiming at an officer"
	AimRange = 150,
	FireMemory = 8,
	ArmedMemory = 20, -- once seen armed, assumed armed this long while unseen
	AssaultMemory = 20,
	FleeSpeed = 9,
}

---------------------------------------------------------------------------
-- COMPLIANCE / ARREST
---------------------------------------------------------------------------
-- v116: stopped / boxed-in suspects are pulled out of their car
Tuning.Extraction = {
	Enabled = true,
	StopTime = 1.5, -- car stopped this long before an officer walks up to the door
	OrderTime = 2.5, -- "Get out of the vehicle!" - then he opens the door and pulls you out
	Reach = 5, -- officer must be this close to the driver's door
	DownTime = 2.5, -- stun after being pulled out
}

Tuning.Compliance = {
	CommandLead = 1.0, -- a command must have been given this long before standing still counts
	StillSpeed = 2.5,
	StillTime = 1.4,
	BreakDistance = 8, -- moving this far from where you complied = noncompliant again
	MaxCommandDistance = 70,
}

Tuning.Arrest = {
	OwnerMaxDistance = 110,
	OwnerStuckTime = 7, -- no progress toward the suspect this long = ownership transfers
	CoverRing = 12, -- other officers hold here while the owner cuffs
	CriticalRing = 10,
}

---------------------------------------------------------------------------
-- LESS LETHAL
---------------------------------------------------------------------------
Tuning.LessLethal = {
	LockTime = 1.5, -- one taser/beanbag deployment at a time per incident
	TaserArmedMax = 16, -- only tase an armed suspect this close (and not aiming at anyone)
	ExploitWindow = 1.0, -- extra time after a stun where the arrest owner sprints in
}

---------------------------------------------------------------------------
-- USE OF FORCE BY DISTANCE (v191)
-- Take-alive calls never use live fire (unchanged). Once lethal force is
-- authorized: officers engage with firearms from range, and inside CloseRange
-- they go to taser / pepper / beanbag / rubber first. Live fire inside
-- CloseRange only in self-defence (suspect aiming at THIS officer, or fired
-- within SelfDefenseWindow seconds).
---------------------------------------------------------------------------
Tuning.Force = {
	CloseRange = 18,
	SelfDefenseWindow = 1.5,
}

-- Containment ring: PERIMETER officers are spread evenly AROUND the suspect
-- (not stacked behind the contact officer), leaving a gap in the contact sector.
Tuning.Containment = {
	Radius = 42, -- unarmed / take-alive
	RadiusDangerous = 58, -- armed or lethal
	ContactGap = math.rad(50), -- keep the contact/cover sector clear
}

---------------------------------------------------------------------------
-- FOOT TACTICS
---------------------------------------------------------------------------
Tuning.Tactics = {
	RoleRefresh = 0.7,
	MinSpacing = 11, -- v142: squads spread instead of shoulder-to-shoulder mobbing
	RingLow = 15, -- unarmed suspects: cover officers ring at this radius
	PerimeterLow = 30,
	StandoffMin = 20, -- v142: establish cover before closing for less-lethal
	StandoffMax = 36,
	PerimeterHigh = 54,
	ArcHigh = math.rad(75), -- armed: everyone stays within +-75 deg of the contact bearing (no crossfire)
	ArcLow = math.rad(125),
	CoverSearch = 22, -- v141: search far enough to use cars, corners, planters and nearby walls
	FireLaneWidth = 3.2, -- hold fire if another officer is this close to the shot line
	InterceptLead = 4, -- seconds ahead a foot interceptor aims for
	MaxInterceptors = 2,
	MaxCover = 3,
}

---------------------------------------------------------------------------
-- SEARCH
---------------------------------------------------------------------------
Tuning.Search = {
	Radius = { 70, 95, 120, 150, 180 },
	Points = 12,
	LookTime = 1.6,
	ReplanAfter = 25,
}

---------------------------------------------------------------------------
-- VEHICLE PURSUIT
---------------------------------------------------------------------------
Tuning.Vehicles = {
	PursuitSpeed = 86, -- fallback; see PursuitSpeedByStars
	-- player cars: Sports 95, Muscle 85, SUV/Sedan 75, Van 65. Higher heat = interceptor units.
	PursuitSpeedByStars = { 94, 98, 102, 106, 110, 116 }, -- v215: interceptors outrun most player cars from 3 stars
	ParallelSpeed = 92,
	SearchSpeed = 42,
	Accel = 48, -- player cars: 35
	Brake = 78, -- player cars: 70
	Grip = 90, -- lateral acceleration the cruiser corners at (studs/s^2)
	FollowGap = 16, -- PRIMARY stays this close behind the suspect's trail
	SecondaryGap = 55,
	TailGap = 85,
	CarSpacing = 26, -- cruisers don't bunch closer than this on the same line
	DirectRange = 520, -- within this and with a fresh trail, units follow the suspect's exact line
	ReplanInterval = 1.0,
	CarsPerStar = { 4, 6, 9, 12, 15, 18 }, -- v215: a real pursuit - units keep piling in
	MaxPursuitCars = 24, -- across all incidents
	ClaimRadius = 6000, -- v215: every free cruiser in the city answers an active pursuit
	JoinAll = true, -- v215: claim every free patrol cruiser, not just the star quota
	SpawnMin = 340,
	SpawnMax = 850,
	SpawnCooldown = 1.0,
	SpawnBurst = 3, -- units dispatched at once while short-handed
	InterceptDispatch = 8, -- seconds between side-street intercept units (2+ stars)
	RoleRefresh = 1.5,
	PlanInterval = 2.2, -- intercept / spike / roadblock opportunity search
	StopSpeed = 3, -- suspect slower than this for StopTime = vehicle stop
	StopTime = 2.2,
	FallBehind = 420, -- PRIMARY this far behind while another car is much closer = hand over
	MaxParallel = 3, -- v215: more units run alongside / get ahead
	DeployRadius = 320, -- suspect bails out: cruisers this close park and deploy their crews
	MaxDeployCars = 3,
}

---------------------------------------------------------------------------
-- PHYSICAL PURSUIT (v114)
-- Pursuing cruisers become solid against the suspect's car ONLY (they still pass through
-- buildings / traffic / pedestrians so they can't get stuck), with a force limit so a bump
-- is a bump, not a launch. Set Contact.Enabled = false for the old ghost cars.
---------------------------------------------------------------------------
Tuning.Contact = {
	Enabled = true,
	FollowPush = 0.45, -- normal driving: max shove, as a share of the suspect car's weight
	ManeuverPush = 1.4, -- PIT / ram: enough to break the suspect's tyres loose
	MassMatch = 0.8, -- cruiser mass as a share of the suspect car's (so bumps feel heavy)
}

Tuning.PIT = {
	Enabled = true,
	MinStars = 1,
	MinSpeed = 22,
	Range = 55,
	Cooldown = 5,
	AlignTimeout = 5,
	TapTime = 0.55,
	RecoverTime = 1.6,
}

Tuning.Ram = {
	Enabled = true,
	MinStars = 2,
	MaxSuspectSpeed = 55, -- rams a slowed / cornering suspect, not one flat out on a highway
	Cooldown = 5,
	Time = 0.6,
}

Tuning.BoxIn = {
	Enabled = true,
	MinStars = 2,
	MaxSuspectSpeed = 26, -- once he slows, a second car pulls in front (rolling roadblock)
}

Tuning.Spike = {
	Enabled = true,
	DispatchUnits = true, -- no spare car can get ahead? send one from a side street ahead
	WheelFriction = 0.22, -- shredded tyres lose grip...
	FlatSpeedCap = 26, -- ...and drag the car down to about this speed
	DragGain = 3,
	MaxDragDecel = 85,
	MinStars = 1, -- v215: spike units wait ahead from the first star
	MinLead = 160, -- the strip is never placed closer than this ahead of the suspect
	MaxLead = 750,
	SetupTime = 5, -- seconds the unit needs on scene before the suspect arrives
	AbortDistance = 110, -- suspect this close before the strip is down = too late, abort
	Timeout = 45,
	Cooldown = 12,
	FlatTire = 0.7, -- share of top speed lost with punctured tyres
	FlatDuration = 180,
}

Tuning.Roadblock = {
	Enabled = true,
	DispatchUnits = true,
	MinStars = 2,
	MinLead = 260,
	MaxLead = 900,
	SetupTime = 7,
	AbortDistance = 140,
	Timeout = 55,
	Cooldown = 20,
	Breakable = true, -- parked roadblock cars can be shoved by a hard hit (false = immovable)
	HoldForce = 45000,
}

-- Radio chatter on the suspect's screen when spikes / roadblocks go up (fair warning)
Tuning.ScannerHints = true
-- Role tag over each pursuit car ("PRIMARY", "SPIKE UNIT", ...). Handy while testing.
Tuning.UnitLabels = true
-- Output line summarising each vehicle pursuit every N seconds (0 = off)
Tuning.StatusLogInterval = 8

---------------------------------------------------------------------------
-- CRUISER PARKING
---------------------------------------------------------------------------
Tuning.Parking = {
	Spacing = 19, -- min distance between reserved cruiser stops
	Preferred = 36, -- preferred stop distance from the incident
	MinDistance = 20,
	MaxDistance = 120,
	FelonyMin = 16,
	FelonyPreferred = 26,
}

---------------------------------------------------------------------------
-- VOICE
---------------------------------------------------------------------------
Tuning.Voice = {
	OfficerGap = 2.6, -- one line per officer every N seconds
	IncidentGap = 1.2, -- the squad doesn't talk over itself
	AnnounceGap = 6, -- banner to the suspect's screen at most this often
	ShowTime = 2.2,
	MaxDistance = 140,
}

return Tuning
