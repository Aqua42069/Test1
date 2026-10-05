-- BankServer
-- Rebuilt bank heists (the snapshot had no server code), using what's left in
-- the map: the locked staff doors, both vault doors with their keypads, the
-- alarm lights and siren, and the lockpicking minigame (Guis.PickLockGui).
--
-- The heist (both banks):
--   1. Buy a Lockpick from Pablo.
--   2. Staff doors: equip the lockpick and click the door (or press E), then
--      beat the tumbler minigame.
--   3. Hack the bank computer on the office desk (letter minigame) to get the
--      vault code.
--   4. Enter the code on the vault keypad. The vault opens and the alarm goes
--      off - it STAYS open until police or bank staff reset it at the keypad.
--   5. Inside, choose how much to take: bigger amounts take longer and you
--      have to stay in the vault the whole time.
-- The client side (hack screen, keypad, amount picker) is StarterPlayerScripts.HeistClient.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")

local LOCKPICK_PRICE = 150
local LOCK_COMPLEXITY = 8 -- tumblers in the minigame
local PRISON_LOCK_COMPLEXITY = 16 -- prison doors are much harder than commercial staff doors
local DOOR_OPEN_TIME = 8
-- Hacker-flavoured words the computer hack spells out, one letter at a time.
local HACK_WORDS = {
	"CIPHER", "EXPLOIT", "FIREWALL", "MALWARE", "ROOTKIT", "BACKDOOR", "KEYLOGGER",
	"PAYLOAD", "DECRYPT", "OVERRIDE", "BYPASS", "INTRUDER", "PHISHING", "TROJAN",
	"SPYWARE", "BOTNET", "ENCRYPT", "PROTOCOL", "MAINFRAME", "NETWORK", "GATEWAY",
	"TERMINAL", "DATABASE", "ACCESS", "BREACH", "PACKET", "CRACKER", "PASSWORD",
}
-- Rob tiers: the vault's available cash is randomized for every robbery.
-- The slow/best option is never below $5,000 and can roll as high as $20,000.
-- The quicker choices scale down from that same vault roll, so a poor vault and a
-- rich vault feel meaningfully different instead of always paying fixed amounts.
local ROB_TIERS = {
	{ time = 15 },
	{ time = 30 },
	{ time = 45 },
}

local function roundCash(n)
	return math.max(500, math.floor((n + 250) / 500) * 500)
end

local function rollRobberyAmounts()
	local best = math.random(5000, 20000)
	best = math.clamp(roundCash(best), 5000, 20000)
	local quick = roundCash(best * (math.random(22, 32) / 100))
	local medium = roundCash(best * (math.random(48, 65) / 100))
	quick = math.clamp(quick, 1000, math.max(1000, best - 2000))
	medium = math.clamp(medium, quick + 500, best - 500)
	return { quick, medium, best }
end
local LAW_TEAMS = {
	["LVPD"] = true, ["SWAT"] = true, ["Federal Bureau of Investigation"] = true,
	["U.S. Marshal Service"] = true, ["USM"] = true, ["Secret Service"] = true,
	["Homeland Security"] = true, ["Federal Protection Service"] = true,
	["Special Forces"] = true, ["Dept. of Justice"] = true,
	["Prison Staff"] = true,
}
local STAFF_TEAM = "Bank of America"

local events = ReplicatedStorage:WaitForChild("Events")
local guis = ReplicatedStorage:WaitForChild("Guis")
local pickGui = guis:WaitForChild("PickLockGui")

local function economy(action, player, amount)
	local fn = ServerStorage:WaitForChild("Economy", 10)
	return fn and fn:Invoke(action, player, amount)
end

local RunService = game:GetService("RunService")

-- Studio testing / the place owner can always reset a vault, since there's
-- often nobody around on a police team to do it for real.
local function isDev(player)
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		return ok and rank == 255
	end
	return player.UserId == game.CreatorId
end

local function isStaff(player, bank)
	local teamName = player.Team and player.Team.Name
	return teamName ~= nil and teamName == ((bank and bank.staffTeam) or STAFF_TEAM)
end

local function isLaw(player)
	return player.Team ~= nil and LAW_TEAMS[player.Team.Name] == true
end

local function rootOf(player)
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart"), character and character:FindFirstChildOfClass("Humanoid")
end

local function notify(player, text, seconds)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local old = playerGui:FindFirstChild("BankNotice")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "BankNotice"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.18, 0)
	label.Size = UDim2.new(0.45, 0, 0.05, 0)
	label.BackgroundColor3 = Color3.fromRGB(120, 20, 20)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Text = text
	label.Parent = gui
	gui.Parent = playerGui
	Debris:AddItem(gui, seconds or 4)
end

local function notifyAll(text)
	for _, player in ipairs(Players:GetPlayers()) do
		notify(player, text, 6)
	end
end

---------------------------------------------------------------------------
-- Lockpicks
---------------------------------------------------------------------------
local function findLockpick(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	return (backpack and backpack:FindFirstChild("Lockpick")) or (character and character:FindFirstChild("Lockpick"))
end

local function giveLockpick(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false
	end
	local tool = Instance.new("Tool")
	tool.Name = "Lockpick"
	tool.ToolTip = "Walk up to a locked door or a vault keypad"
	tool.CanBeDropped = false
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.15, 0.15, 1)
	handle.Color = Color3.fromRGB(160, 160, 170)
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	tool.Parent = backpack
	return true
end

local lockpickFn = ServerStorage:FindFirstChild("Lockpicks") or Instance.new("BindableFunction")
lockpickFn.Name = "Lockpicks"
lockpickFn.OnInvoke = function(action, player)
	if action == "Price" then
		return LOCKPICK_PRICE
	elseif action == "Has" then
		return findLockpick(player) ~= nil
	elseif action == "Give" then -- v212: the prison lockpick dealer (PrisonSociety) already took the money
		return giveLockpick(player)
	elseif action == "Buy" then
		if not economy("Charge", player, LOCKPICK_PRICE) then
			return false, "Come back with $" .. LOCKPICK_PRICE
		end
		giveLockpick(player)
		return true
	end
end
lockpickFn.Parent = ServerStorage

---------------------------------------------------------------------------
-- Doors: open for a few seconds, then lock again
---------------------------------------------------------------------------
local function openDoor(door)
	if door:GetAttribute("Open") then
		return
	end
	door:SetAttribute("Open", true)
	local parts = door:IsA("BasePart") and { door } or door:GetDescendants()
	local saved = {}
	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			saved[part] = { part.CanCollide, part.Transparency }
			part.CanCollide = false
			part.Transparency = math.max(part.Transparency, 0.7)
		end
	end
	task.delay(DOOR_OPEN_TIME, function()
		while door.Parent and os.clock()<(door:GetAttribute("PoliceBreachUntil") or 0) do task.wait(0.5) end
		if not door.Parent then return end
		for part, s in pairs(saved) do
			part.CanCollide, part.Transparency = s[1], s[2]
		end
		door:SetAttribute("Open", false)
	end)
end

local sessions = {} -- [player] = { door = part, gui = gui, started = time }

local function endSession(player)
	local session = sessions[player]
	sessions[player] = nil
	local root = rootOf(player)
	if root then
		root.Anchored = false
	end
	if session and session.gui and session.gui.Parent then
		session.gui:Destroy()
	end
end

local function startPicking(player, door)
	if sessions[player] then
		return
	end
	if not findLockpick(player) then
		notify(player, "It's locked. You need a lockpick (ask Pablo).")
		return
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local gui = pickGui:Clone()
	gui.Door.Value = door
	local isPrisonDoor=door:GetAttribute("PrisonDoor")==true
	-- v241: mapped doors of other facilities carry their own tumbler count (City Jail = 12)
	gui.Locks.Complexity.Value = tonumber(door:GetAttribute("LockComplexity")) or (if isPrisonDoor then PRISON_LOCK_COMPLEXITY else LOCK_COMPLEXITY)
	-- v250: a gang Lieutenant taught you to feel the pins - 3 fewer tumblers (min 4)
	if player:GetAttribute("SkillLockpicking") then
		gui.Locks.Complexity.Value = math.max(4, gui.Locks.Complexity.Value - 3)
	end
	gui.Locks.Lock.Disabled = false -- the template ships with the minigame switched off
	gui.ResetOnSpawn = true
	sessions[player] = { door = door, gui = gui, started = os.clock() }
	gui.Parent = playerGui
	-- Safety: don't leave anyone frozen if they give up.
	task.delay(if isPrisonDoor then 90 else 60, function()
		if sessions[player] and sessions[player].gui == gui then
			endSession(player)
		end
	end)
end

-- Minigame -> server
events:WaitForChild("DoorOpening").OnServerEvent:Connect(function(player, door)
	local session = sessions[player]
	if not session or session.door ~= door then
		return
	end
	endSession(player)
	openDoor(door)
	notify(player, "Unlocked! The door relocks in a few seconds.", 3)
end)
events:WaitForChild("AnchorPlayer").OnServerEvent:Connect(function(player, anchored)
	local root = rootOf(player)
	if root then
		root.Anchored = anchored == true and sessions[player] ~= nil
	end
end)
events:WaitForChild("RemoveTool").OnServerEvent:Connect(function(player, toolName)
	if toolName == "Lockpick" and sessions[player] then
		local pick = findLockpick(player)
		if pick then
			pick:Destroy()
		end
		notify(player, "Your lockpick snapped!")
		endSession(player)
	end
end)
Players.PlayerRemoving:Connect(function(player)
	sessions[player] = nil
end)

local heist = events:FindFirstChild("Heist") or Instance.new("RemoteEvent")
heist.Name = "Heist"
heist.Parent = events

local lockDoorAnchors = {}
local function near(player, part, distance)
	local root = rootOf(player)
	if not root or not part then return false end
	local anchor=lockDoorAnchors[part]
	local pos=if anchor and anchor.Parent then anchor.Position elseif part:IsA("BasePart") then part.Position elseif part:IsA("Model") then part:GetPivot().Position else nil
	return pos~=nil and (root.Position-pos).Magnitude<=distance
end

---------------------------------------------------------------------------
-- Staff doors (Bank of America "BankDoor", GNC "GNCDoor")
---------------------------------------------------------------------------
local lockedDoors = {}
local lockedDoorParts = {}
local prisonDoorCount=0

local function tryDoor(player, door)
	if door:GetAttribute("Open") or not near(player, door, 12) then
		return
	end
	local bank = door:GetAttribute("Bank") == "GNC" and { staffTeam = "GNC Finance" } or nil
	if isStaff(player, bank) or isLaw(player) then
		openDoor(door)
	else
		startPicking(player, door)
	end
end

local function setupLockedDoor(door, bankTag)
	lockedDoors[door] = true
	door:SetAttribute("Bank", bankTag)
	door:SetAttribute("Lockable", true)
	door:SetAttribute("PoliceAutoAccess", true)
	CollectionService:AddTag(door, "PoliceAutoDoor")
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LockPrompt"
	prompt.ActionText = "Pick lock"
	prompt.ObjectText = "Staff door"
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.Parent = door
	prompt.Triggered:Connect(function(player)
		tryDoor(player, door)
	end)
end

local function setupPrisonDoor(marker, complexity)
	if not marker or marker:GetAttribute("PrisonDoorMarker")~=true then return end
	local value=marker:FindFirstChild("DoorObject")
	local target=value and value.Value
	local anchor=marker:FindFirstChild("Center")
	if not target or not anchor or not anchor:IsA("BasePart") or lockedDoors[target] then return end
	lockedDoors[target]=true
	prisonDoorCount+=1
	lockDoorAnchors[target]=anchor
	target:SetAttribute("Lockable",true)
	target:SetAttribute("PrisonDoor",true)
	if complexity then target:SetAttribute("LockComplexity",complexity) end
	for _,part in ipairs(if target:IsA("BasePart") then {target} else target:GetDescendants()) do
		if part:IsA("BasePart") then lockedDoorParts[part]=target end
	end
	local prompt=Instance.new("ProximityPrompt")
	prompt.Name="PrisonLockPrompt"
	prompt.ActionText="Pick lock"
	prompt.ObjectText=marker.Name
	prompt.RequiresLineOfSight=false
	prompt.MaxActivationDistance=7
	prompt.HoldDuration=0.5
	prompt.Exclusivity=Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent=anchor
	prompt.Triggered:Connect(function(player) tryDoor(player,target) end)
end

local prisonFacility=workspace:FindFirstChild("CorrectionalFacility")
local prisonMap=prisonFacility and prisonFacility:FindFirstChild("PrisonMap")
local prisonMarkers=prisonMap and prisonMap:FindFirstChild("DoorMarkers")
if prisonMarkers then
	for _,marker in ipairs(prisonMarkers:GetChildren()) do setupPrisonDoor(marker) end
	prisonMarkers.ChildAdded:Connect(function(marker) task.defer(setupPrisonDoor,marker) end)
	print(("[BankServer] %d mapped prison door(s) can be lockpicked (16 tumblers)"):format(prisonDoorCount))
else
	warn("[BankServer] prison DoorMarkers unavailable; mapped prison lockpicks will retry")
	task.spawn(function()
		-- v210: the prison can restore its map a while after start (from its
		-- baked copy when the place file has lost it), so keep looking.
		for _=1,180 do
			task.wait(1)
			local facility=workspace:FindFirstChild("CorrectionalFacility")
			local map=facility and facility:FindFirstChild("PrisonMap")
			local markers=map and map:FindFirstChild("DoorMarkers")
			if markers then
				for _,marker in ipairs(markers:GetChildren()) do setupPrisonDoor(marker) end
				markers.ChildAdded:Connect(function(marker) task.defer(setupPrisonDoor,marker) end)
				print(("[BankServer] %d mapped prison door(s) can be lockpicked (16 tumblers)"):format(prisonDoorCount))
				return
			end
		end
		warn("[BankServer] no mapped prison DoorMarkers found; prison lockpicks remain unavailable")
	end)
end

-- v241: City Jail doors mapped with the Facility Mapper can be picked too - harder
-- than a staff door (8), easier than the prison (16)
do
	local CITY_JAIL_LOCK_COMPLEXITY=12
	local count=0
	for _,building in ipairs(workspace:GetChildren()) do
		local map=building:FindFirstChild("FacilityMap")
		if map and (map:GetAttribute("FacilityType") or building:GetAttribute("FacilityType"))=="CityJail" then
			local markers=map:FindFirstChild("DoorMarkers")
			if markers then
				for _,marker in ipairs(markers:GetChildren()) do
					local before=prisonDoorCount
					setupPrisonDoor(marker,CITY_JAIL_LOCK_COMPLEXITY)
					count+=prisonDoorCount-before
				end
				markers.ChildAdded:Connect(function(marker) task.defer(setupPrisonDoor,marker,CITY_JAIL_LOCK_COMPLEXITY) end)
			end
		end
	end
	print(("[BankServer] %d mapped city jail door(s) can be lockpicked (%d tumblers)"):format(count,CITY_JAIL_LOCK_COMPLEXITY))
end

local doorCount = 0
for _, obj in ipairs(workspace:GetDescendants()) do
	if obj:IsA("BasePart") and (obj.Name == "BankDoor" or obj.Name == "GNCDoor") then
		setupLockedDoor(obj, obj.Name == "GNCDoor" and "GNC" or "BOA")
		doorCount += 1
	end
end
print(("[BankServer] %d staff doors can be lockpicked"):format(doorCount))

-- AI police use the exact same door-opening path as player police.  The door
-- remains locked for everyone else; an officer simply gets an automatic staff
-- access pulse when they approach it, then it relocks normally.
local oldPoliceAccess = ServerStorage:FindFirstChild("PoliceDoorAccess")
if oldPoliceAccess then oldPoliceAccess:Destroy() end
local policeDoorAccess = Instance.new("BindableFunction")
policeDoorAccess.Name = "PoliceDoorAccess"
policeDoorAccess.OnInvoke = function(action, pos, radius)
 if action=="Breach" then
  if typeof(pos)~="Instance" or not lockedDoors[pos] or not pos.Parent then return false end
  pos:SetAttribute("PoliceBreachUntil",os.clock()+math.clamp(tonumber(radius) or 18,1,25));openDoor(pos);return true
 end
	if action ~= "OpenNear" or typeof(pos) ~= "Vector3" then return 0 end
	radius = math.clamp(tonumber(radius) or 28, 6, 60)
	local opened = 0
	for _, door in ipairs(CollectionService:GetTagged("PoliceAutoDoor")) do
		if door and door.Parent then
			local at
			if door:IsA("BasePart") then
				at = door.Position
			else
				local bp = door:FindFirstChildWhichIsA("BasePart", true)
				at = bp and bp.Position or nil
			end
			if at and (at - pos).Magnitude <= radius and not door:GetAttribute("Open") and os.clock()>=(door:GetAttribute("PoliceStackUntil") or 0) then
				openDoor(door)
				opened += 1
			end
		end
	end
	return opened
end
policeDoorAccess.Parent = ServerStorage

---------------------------------------------------------------------------
-- Vaults, computers and the robbery
---------------------------------------------------------------------------
local banks = {} -- id -> bank

local function setAlarm(bank, on)
	local holder = bank.holder
	local soundPart = holder:FindFirstChild("SoundPart")
	local alarm = soundPart and soundPart:FindFirstChild("Alarm")
	if alarm and alarm:IsA("Sound") then
		alarm.Looped = true
		if on then alarm:Play() else alarm:Stop() end
	end
	local lights = holder:FindFirstChild("AlarmLights")
	if not lights then
		return
	end
	for _, part in ipairs(lights:GetDescendants()) do
		if part:IsA("BasePart") then
			local glow = part:FindFirstChild("AlarmGlow")
			if on then
				if not glow then
					glow = Instance.new("PointLight")
					glow.Name = "AlarmGlow"
					glow.Color = Color3.fromRGB(255, 30, 30)
					glow.Range = 26
					glow.Brightness = 3
					glow.Parent = part
				end
				part.Material = Enum.Material.Neon
				part.Color = Color3.fromRGB(255, 30, 30)
			elseif glow then
				glow:Destroy()
			end
		end
	end
	if on then
		task.spawn(function()
			local blinkOn = true
			while bank.open do
				blinkOn = not blinkOn
				for _, glow in ipairs(lights:GetDescendants()) do
					if glow.Name == "AlarmGlow" then
						glow.Enabled = blinkOn
					end
				end
				task.wait(0.5)
			end
		end)
	end
end

local function newCode(bank)
	bank.code = tostring(math.random(10000, 99999)) -- 5 digits
end

local function openVault(bank, robber)
	if bank.open then
		return
	end
	bank.open = true
	bank.robbedBy = {}
	-- v258: the bank is a crime scene until the police secure it (scene loop below)
	bank.sceneSince = os.clock()
	bank.sceneClearSince = nil
	bank.sceneSuspects = {}
	if robber then
		bank.sceneSuspects[robber] = true
		robber:SetAttribute("BankScene", bank.name)
	end
	for _, info in ipairs(bank.doorParts) do
		info.part.CanCollide = false
		info.part.CanQuery = false -- v258: bullets pass through the open vault door
		TweenService:Create(info.part, TweenInfo.new(1.5), { Transparency = 1 }):Play()
	end
	bank.keypadPrompt.ActionText = "Reset vault"
	bank.keypadPrompt.ObjectText = "Police / bank staff only"
	bank.robPrompt.Enabled = true
	setAlarm(bank, true)
	notifyAll(("%s vault has been broken into!"):format(bank.name))
	if robber then
		-- A vault breach is an active high-risk bank robbery, so start the four-star
		-- response BEFORE reporting the charge.  This makes the first wave the actual
		-- SWAT/Riot + armored response instead of spawning a 3-star tactical wave and
		-- waiting for that wave to finish before SWAT is allowed to appear.
		local police = ServerStorage:FindFirstChild("PoliceAI")
		local setWanted = police and police:FindFirstChild("SetWanted")
		if setWanted and setWanted:IsA("BindableEvent") then
			setWanted:Fire(robber, 4)
		end
		local report = ServerStorage:FindFirstChild("ReportCrime")
		if report then
			task.spawn(report.Invoke, report, robber, "Bank robbery", 4)
		end
		print(("[BankServer] SWAT ASSAULT REQUESTED: %s at %s"):format(robber.Name, bank.name))
	end
	heist:FireAllClients("VaultOpened", bank.id)
end

local function resetVault(bank, by)
	if not bank.open then
		return
	end
	bank.open = false
	for _, info in ipairs(bank.doorParts) do
		info.part.CanCollide = info.collide
		info.part.CanQuery = info.query ~= false
		TweenService:Create(info.part, TweenInfo.new(1.5), { Transparency = info.transparency }):Play()
	end
	bank.keypadPrompt.ActionText = "Enter code"
	bank.keypadPrompt.ObjectText = bank.name .. " vault"
	bank.robPrompt.Enabled = false
	setAlarm(bank, false)
	newCode(bank)
	bank.hackedBy = {}
	for player in pairs(bank.robbing) do
		bank.robbing[player] = nil
		heist:FireClient(player, "RobCancelled", bank.id, "The vault was locked!")
	end
	for player in pairs(bank.sceneSuspects or {}) do
		if player:GetAttribute("BankScene") == bank.name then player:SetAttribute("BankScene", nil) end
	end
	bank.sceneSuspects, bank.sceneSince, bank.sceneClearSince = {}, nil, nil
	notifyAll(("%s vault was secured by %s."):format(bank.name, if typeof(by) == "string" then by elseif by then by.Name else "staff"))
	heist:FireAllClients("VaultReset", bank.id)
end

-- v258: crime scene. While the vault is open every robber is tagged BankScene; the police
-- AI holds a tagged suspect inside the bank as contained (full SWAT entry, never "lost").
-- Once no free suspect has been inside for SCENE_CLEAR_SECONDS, SWAT sweeps the building
-- and the police secure the bank.
local SCENE_CLEAR_SECONDS = 20
local SCENE_MIN_SECONDS = 45
local Facilities = nil
task.spawn(function()
	local ps = game:GetService("ServerScriptService"):WaitForChild("PoliceSystem", 60)
	local fm = ps and ps:WaitForChild("Facilities", 30)
	if fm then
		local ok, m = pcall(require, fm)
		if ok then Facilities = m end
	end
end)

local function insideBank(bank, pos)
	if Facilities then
		local ok, b = pcall(Facilities.buildingAt, pos)
		if ok and b and b.type == "Bank" then return true end
	end
	return (pos - bank.floor.Position).Magnitude < 60
end

local function inCustody(player)
	return player:GetAttribute("CustodyStage") ~= nil or player:GetAttribute("BookingState") ~= nil
end

task.spawn(function()
	while true do
		task.wait(2)
		for _, bank in pairs(banks) do
			if bank.open and bank.sceneSince then
				local anyInside = false
				for player in pairs(bank.sceneSuspects) do
					local root = player.Parent and rootOf(player)
					local hum = root and root.Parent:FindFirstChildOfClass("Humanoid")
					if root and hum and hum.Health > 0 and not inCustody(player) and insideBank(bank, root.Position) then
						anyInside = true
						player:SetAttribute("BankScene", bank.name)
					elseif player.Parent and player:GetAttribute("BankScene") == bank.name then
						player:SetAttribute("BankScene", nil) -- out of the building: a normal chase
					end
				end
				if anyInside then
					bank.sceneClearSince = nil
				else
					bank.sceneClearSince = bank.sceneClearSince or os.clock()
					if not bank.sweeping and os.clock() - bank.sceneClearSince >= SCENE_CLEAR_SECONDS and os.clock() - bank.sceneSince >= SCENE_MIN_SECONDS then
						-- SWAT clears the building room by room before the bank is handed back
						bank.sweeping = true
						task.spawn(function()
							local police = ServerStorage:FindFirstChild("PoliceAI")
							local sweep = police and police:FindFirstChild("BankSweep")
							if sweep and sweep:IsA("BindableFunction") then
								notifyAll(("SWAT is clearing the %s."):format(bank.name))
								pcall(sweep.Invoke, sweep, "Bank", { bank.floor.Position + Vector3.new(0, 3, 0) })
							end
							bank.sweeping = false
							-- a suspect turned up during the sweep: the scene stays open
							if bank.open and bank.sceneClearSince then
								print(("[BankServer] SCENE SECURED %s by police"):format(bank.name))
								resetVault(bank, "the police")
							end
						end)
					end
				end
			end
		end
	end
end)

-- Finds a "computer" part for the hack: prefers a nearby monitor (a part
-- showing a logo), falls back to the desk's own biggest part. Searches near
-- `near` (the vault or keypad) rather than requiring an "OfficeDesk" model
-- to exist by that exact name/nesting, since that assumption has been wrong
-- before.
local function findComputer(desk, near)
	local top, topSize = nil, 0
	if desk then
		for _, part in ipairs(desk:GetDescendants()) do
			if part:IsA("BasePart") and part.Size.X * part.Size.Z > topSize then
				top, topSize = part, part.Size.X * part.Size.Z
			end
		end
	end

	local searchRoot = (desk and desk.Parent) or (near and near:FindFirstAncestorOfClass("Model")) or workspace
	local origin = top and top.Position or (near and near.Position)
	local best, bestDist = nil, 14
	if origin then
		for _, part in ipairs(searchRoot:GetDescendants()) do
			if part:IsA("BasePart") and (part:FindFirstChildWhichIsA("Decal") or part:FindFirstChildWhichIsA("SurfaceGui")) then
				local d = (part.Position - origin).Magnitude
				if d < bestDist then
					best, bestDist = part, d
				end
			end
		end
	end
	return best or top, top
end

local function setupBank(id, name, staffTeam, vault, desk)
	local holder = vault.Parent
	local keypad = vault:FindFirstChild("Keypad")
	local floor = holder:FindFirstChild("VaultFloor")
	if not (keypad and floor) then
		warn("[BankServer] vault for", name, "is missing its keypad or floor")
		return
	end
	local bank = {
		id = id, name = name, staffTeam = staffTeam, holder = holder, keypad = keypad, floor = floor,
		open = false, doorParts = {}, hacks = {}, hackedBy = {}, robbing = {}, robbedBy = {},
	}
	banks[id] = bank
	newCode(bank)
	for _, part in ipairs(vault:GetDescendants()) do
		if part:IsA("BasePart") and part ~= keypad then
			table.insert(bank.doorParts, { part = part, collide = part.CanCollide, query = part.CanQuery, transparency = part.Transparency })
		end
	end

	-- Keypad: enter the code (robbers) / reset the vault (police & staff)
	local keypadPrompt = Instance.new("ProximityPrompt")
	keypadPrompt.Name = "KeypadPrompt"
	keypadPrompt.ActionText = "Enter code"
	keypadPrompt.ObjectText = name .. " vault"
	keypadPrompt.RequiresLineOfSight = false
	keypadPrompt.MaxActivationDistance = 8
	keypadPrompt.Parent = keypad
	bank.keypadPrompt = keypadPrompt
	keypadPrompt.Triggered:Connect(function(player)
		if bank.open then
			if isLaw(player) or isStaff(player, bank) or isDev(player) then
				resetVault(bank, player)
			else
				notify(player, "Only police or bank staff can reset the vault.", 6)
			end
			return
		end
		heist:FireClient(player, "Keypad", id, name)
	end)

	-- Computer: hack it for the code
	local deskPart, deskTop = findComputer(desk, keypad)
	if deskPart then
		local hackPrompt = Instance.new("ProximityPrompt")
		hackPrompt.Name = "HackPrompt"
		hackPrompt.ActionText = "Hack computer"
		hackPrompt.ObjectText = name .. " terminal"
		hackPrompt.RequiresLineOfSight = false
		hackPrompt.MaxActivationDistance = 12
		hackPrompt.KeyboardKeyCode = Enum.KeyCode.E
		hackPrompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
		hackPrompt.Parent = deskPart
		local function startHack(player)
			if bank.open then
				notify(player, ("The %s vault is already open - reset it at the keypad first (E on the keypad)."):format(name), 6)
				print(("[BankServer] %s tried the %s terminal, but the vault is still open"):format(player.Name, name))
				return
			end
			if isStaff(player, bank) then
				notify(player, "Vault code: " .. bank.code, 6)
				return
			end
			local word = HACK_WORDS[math.random(1, #HACK_WORDS)]
			bank.hacks[player] = { started = os.clock(), part = deskPart, shown = false }
			notify(player, "Connecting to terminal...", 2)
			heist:FireClient(player, "Hack", id, word)
			local session = bank.hacks[player]
			task.delay(3, function()
				if bank.hacks[player] == session and not session.shown then
					notify(player, "Hack screen didn't open on your side (HeistClient isn't running?)", 6)
					warn("[BankServer] no HackShown reply from", player.Name, "- is StarterPlayerScripts.HeistClient running?")
				end
			end)
			print(("[BankServer] %s started hacking the %s computer"):format(player.Name, name))
		end
		hackPrompt.Triggered:Connect(startHack)
		local terminalSign = Instance.new("BillboardGui")
		terminalSign.Name = "TerminalSign"
		terminalSign.Size = UDim2.new(0, 150, 0, 34)
		terminalSign.StudsOffset = Vector3.new(0, 2.5, 0)
		terminalSign.MaxDistance = 40
		local signText = Instance.new("TextLabel")
		signText.Size = UDim2.new(1, 0, 1, 0)
		signText.BackgroundColor3 = Color3.fromRGB(10, 20, 10)
		signText.BackgroundTransparency = 0.25
		signText.TextColor3 = Color3.fromRGB(120, 255, 120)
		signText.Font = Enum.Font.Code
		signText.TextScaled = true
		signText.Text = "HACK TERMINAL (E / click)"
		signText.Parent = terminalSign
		terminalSign.Parent = deskPart
		-- Clicking the computer or desk works too.
		local clickable = desk and desk:GetDescendants() or {}
		if deskPart ~= deskTop then
			table.insert(clickable, deskPart)
		end
		for _, part in ipairs(clickable) do
			if part:IsA("BasePart") and not part:FindFirstChildOfClass("ClickDetector") then
				local click = Instance.new("ClickDetector")
				click.MaxActivationDistance = 14
				click.Parent = part
				click.MouseClick:Connect(startHack)
			end
		end
	else
		warn("[BankServer] no computer found for", name, "- tried the OfficeDesk model and a", 14, "stud search around the vault")
	end

	-- Rob spot in the middle of the vault floor
	local robPart = Instance.new("Part")
	robPart.Name = "VaultCash"
	robPart.Size = Vector3.new(3, 1, 2)
	robPart.Color = Color3.fromRGB(70, 130, 60)
	robPart.Material = Enum.Material.Fabric
	robPart.Anchored = true
	robPart.CanCollide = false
	robPart.CFrame = CFrame.new(floor.Position + Vector3.new(0, floor.Size.Y / 2 + 0.5, 0))
	robPart.Parent = holder
	local robPrompt = Instance.new("ProximityPrompt")
	robPrompt.ActionText = "Rob the vault"
	robPrompt.ObjectText = name
	robPrompt.RequiresLineOfSight = false
	robPrompt.MaxActivationDistance = 12
	robPrompt.Enabled = false
	robPrompt.Parent = robPart
	bank.robPrompt = robPrompt
	bank.robPart = robPart
	robPrompt.Triggered:Connect(function(player)
		if not bank.open or bank.robbing[player] then
			return
		end
		if isLaw(player) or isStaff(player, bank) then
			notify(player, "You're supposed to be stopping this!")
			return
		end
		local amounts, times = rollRobberyAmounts(), {}
		for i, tier in ipairs(ROB_TIERS) do
			times[i] = tier.time
		end
		print(("[BankServer] %s vault roll for %s: $%d / $%d / $%d"):format(
			name, player.Name, amounts[1], amounts[2], amounts[3]))
		bank.robbing[player] = { amounts = amounts, choosing = true }
		if bank.sceneSuspects then -- v258: looters are scene suspects too
			bank.sceneSuspects[player] = true
			player:SetAttribute("BankScene", bank.name)
		end
		heist:FireClient(player, "RobChoice", id, amounts, times)
	end)
	print(("[BankServer] %s: vault, keypad and %s ready"):format(name, deskPart and ("computer (" .. deskPart:GetFullName() .. ")") or "NO computer"))
end

-- Client -> server
heist.OnServerEvent:Connect(function(player, action, id, value)
	local bank = banks[id]
	if not bank then
		return
	end
	if action == "HackShown" then
		if bank.hacks[player] then
			bank.hacks[player].shown = true
		end
		return
	elseif action == "HackDone" then
		local session = bank.hacks[player]
		bank.hacks[player] = nil
		if not session or os.clock() - session.started < 4 or not near(player, session.part, 14) then
			return
		end
		bank.hackedBy[player] = true
		heist:FireClient(player, "Code", id, bank.code, bank.name)
	elseif action == "HackFailed" then
		bank.hacks[player] = nil
	elseif action == "Code" then
		if bank.open or type(value) ~= "string" or not near(player, bank.keypad, 12) then
			return
		end
		if value == bank.code then
			openVault(bank, player)
		else
			heist:FireClient(player, "WrongCode", id)
		end
	elseif action == "RobPick" then
		local rob = bank.robbing[player]
		local tier = ROB_TIERS[tonumber(value) or 0]
		if not (rob and rob.choosing and tier and bank.open) then
			return
		end
		rob.choosing = false
		local amount = rob.amounts[tonumber(value)]
		heist:FireClient(player, "RobStarted", id, tier.time)
		local finishAt = os.clock() + tier.time
		task.spawn(function()
			while os.clock() < finishAt do
				task.wait(0.25)
				local _, humanoid = rootOf(player)
				if bank.robbing[player] ~= rob then
					return -- vault reset, or cancelled
				end
				if not humanoid or humanoid.Health <= 0 or not near(player, bank.robPart, 25) then
					bank.robbing[player] = nil
					heist:FireClient(player, "RobCancelled", id, "You left the vault - robbery failed!")
					return
				end
			end
			bank.robbing[player] = nil
			bank.robbedBy[player] = true
			economy("AddDirtyCash", player, amount) -- v255: heist money is dirty
			do
				local report = ServerStorage:FindFirstChild("ReportCrime")
				if report then
					task.spawn(report.Invoke, report, player, "Bank robbery", 4)
				end
			end
			heist:FireClient(player, "RobDone", id, amount)
			notify(player, ("You got $%d! Stick around and the cops will find you."):format(amount), 4)
		end)
	elseif action == "RobCancel" then
		bank.robbing[player] = nil
	end
end)

-- Lockpick tool clicks (HeistClient sends what you clicked)
heist.OnServerEvent:Connect(function(player, action, target)
	if action ~= "UseLockpick" or typeof(target) ~= "Instance" then
		return
	end
	local door=target
	while door and not lockedDoors[door] do door=door.Parent end
	if door then tryDoor(player,door) end
end)

Players.PlayerRemoving:Connect(function(player)
	for _, bank in pairs(banks) do
		bank.hacks[player] = nil
		bank.robbing[player] = nil
	end
end)

local boaVault = workspace:FindFirstChild("Bank") and workspace.Bank:FindFirstChild("Bank") and workspace.Bank.Bank:FindFirstChild("BankVault")
local boaDesk = workspace:FindFirstChild("Bank") and workspace.Bank:FindFirstChild("OfficeDesk")
if boaVault then
	setupBank("BOA", "Bank of America", "Bank of America", boaVault, boaDesk)
end
for _, obj in ipairs(workspace:GetDescendants()) do
	if obj.Name == "BankVault" and obj:IsA("Model") and obj ~= boaVault and obj:FindFirstChild("Keypad") then
		setupBank("GNC", "GNC Bank", "GNC Finance", obj, obj.Parent:FindFirstChild("OfficeDesk", true))
	end
end
print("[BankServer] heists ready")
