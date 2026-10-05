--[[
	LuxorHotel (v290) - checking in at the Luxor.
	The front desk (Workspace.Luxor ... "FrontDeskClerk" parts, built by tools/build_luxor.luau)
	sells three kinds of room, as the real hotel does:
	  Pyramid Room   - in the pyramid, the slanted glass wall is the window
	  Pyramid Suite  - the corner Jacuzzi suites of every pyramid floor
	  Tower Deluxe   - in the East / West towers (north of the pyramid)
	  Tower Suite    - two-room suites in the towers
	  Presidential   - West Tower floors 13-15: the suite, its upper level, a private casino floor, the terraces ($15,000)
	Pay at the clerk for that room type and you're given a free room of it: the number and how to
	get there show on screen, and its door shows a marker only you can see. Only you (the guest)
	can open the door. The stay lasts until you check out at the desk, leave the game, or
	STAY_SECS runs out; checking in again at the desk while you have a room extends it.
	Doors are "HotelDoor" parts carrying RoomId, RoomType and RoomFloor.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local TYPES = {
	Pyramid = { label = "Pyramid Room", price = 300 },
	PyramidSuite = { label = "Pyramid Jacuzzi Suite", price = 1200 },
	TowerDeluxe = { label = "Tower Deluxe", price = 750 },
	TowerSuite = { label = "Tower Suite", price = 2500 },
	Presidential = { label = "Presidential Suite", price = 15000 },
}
local STAY_SECS = 45 * 60
local DOOR_OPEN_TIME = 5

local luxor = workspace:WaitForChild("Luxor", 60)
if not luxor then return end

local function economy(action: string, player: Player, amount: number?): any
	local fn = ServerStorage:WaitForChild("Economy", 10)
	return fn and fn:Invoke(action, player, amount)
end

local function notify(player: Player, text: string, secs: number?)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then return end
	local old = pg:FindFirstChild("LuxorHotelNotice")
	if old then old:Destroy() end
	local gui = Instance.new("ScreenGui")
	gui.Name = "LuxorHotelNotice"
	gui.ResetOnSpawn = false
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = UDim2.new(0.5, 0, 0.2, 0)
	l.Size = UDim2.new(0.9, 0, 0, 74)
	l.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	l.BackgroundTransparency = 0.15
	l.TextColor3 = Color3.fromRGB(201, 163, 82)
	l.Font = Enum.Font.Garamond
	l.TextScaled = true
	l.TextWrapped = true
	l.Text = text
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(620, 74)
	cap.Parent = l
	Instance.new("UICorner").Parent = l
	l.Parent = gui
	gui.Parent = pg
	task.delay(secs or 7, function() if gui.Parent then gui:Destroy() end end)
end

---------------------------------------------------------------- rooms
type Room = { id: string, kind: string, floor: string, door: BasePart, guest: Player?, untilT: number }
local rooms: { [string]: Room } = {}
local byGuest: { [Player]: Room } = {}

local function where(r: Room): string
	if r.kind == "Presidential" then
		return "West Tower floor 13 - take the West Tower walkway (the casino's north side), then its elevator to 13"
	end
	if r.kind == "Pyramid" or r.kind == "PyramidSuite" then
		return ("%s - take an inclinator (the lifts in the pyramid's corners) to %s"):format(r.floor, r.floor)
	end
	return ("%s - take that tower's walkway from the casino's north side, then its elevator"):format(r.floor)
end

local function marker(r: Room, on: boolean)
	local g = r.guest
	local pg = g and g:FindFirstChild("PlayerGui")
	if not pg then return end
	local old = pg:FindFirstChild("LuxorRoomMarker")
	if old then old:Destroy() end
	if not on then return end
	local b = Instance.new("BillboardGui")
	b.Name = "LuxorRoomMarker"
	b.Adornee = r.door
	b.AlwaysOnTop = true
	b.Size = UDim2.fromOffset(150, 40)
	b.StudsOffset = Vector3.new(0, 6, 0)
	b.ResetOnSpawn = false
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 0.2
	t.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	t.TextColor3 = Color3.fromRGB(255, 220, 150)
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.Text = "YOUR ROOM " .. r.id
	t.Parent = b
	b.Parent = pg
end

local function release(r: Room)
	marker(r, false)
	if r.guest then
		byGuest[r.guest] = nil
		r.guest:SetAttribute("LuxorRoom", nil)
	end
	r.guest = nil
end

local function openDoor(door: BasePart)
	if door:GetAttribute("Open") then return end
	door:SetAttribute("Open", true)
	door.CanCollide = false
	door.Transparency = 0.9
	task.delay(DOOR_OPEN_TIME, function()
		door.CanCollide = true
		door.Transparency = 0
		door:SetAttribute("Open", nil)
	end)
end

local function hookDoor(door: BasePart)
	local id = door:GetAttribute("RoomId")
	if id == nil then return end
	local r: Room = { id = tostring(id), kind = tostring(door:GetAttribute("RoomType") or "Pyramid"), floor = tostring(door:GetAttribute("RoomFloor") or ""), door = door, untilT = 0 }
	rooms[r.id] = r
	local p = Instance.new("ProximityPrompt")
	p.Name = "RoomPrompt"
	p.ActionText = "Open"
	p.ObjectText = "Room " .. r.id
	p.HoldDuration = 0
	p.MaxActivationDistance = 10 -- measured from the door's middle; the suite's door is tall
	p.RequiresLineOfSight = false
	-- v290: always shown - next to an elevator call panel (also E) the nearer panel won and
	-- the door's prompt never appeared (the Presidential Suite's foyer)
	p.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	p.Parent = door
	p.Triggered:Connect(function(player)
		if r.guest == player then
			openDoor(door)
			notify(player, "Key card accepted - room " .. r.id .. " is open", 2)
		elseif r.guest then
			notify(player, "Room " .. r.id .. " is occupied. Your key card doesn't open it.", 3)
		else
			notify(player, "Room " .. r.id .. " - check in at the front desk to get a key.", 3)
		end
	end)
end

---------------------------------------------------------------- the desk
local function checkIn(player: Player, kind: string)
	local t = TYPES[kind]
	if not t then return end
	local have = byGuest[player]
	if have then
		if have.kind ~= kind then
			notify(player, ("You already have room %s (%s). Check out first to change rooms."):format(have.id, TYPES[have.kind].label))
			return
		end
		if not economy("Charge", player, t.price) then notify(player, "Not enough money to extend your stay ($" .. t.price .. ").") return end
		have.untilT += STAY_SECS
		notify(player, ("Stay extended - room %s is yours for another %d minutes."):format(have.id, STAY_SECS // 60))
		return
	end
	local free: Room? = nil
	local ids = {}
	for id, r in rooms do if r.kind == kind and not r.guest then table.insert(ids, id) end end
	table.sort(ids)
	if #ids > 0 then free = rooms[ids[math.random(1, #ids)]] end
	if not free then notify(player, "Sorry - no " .. t.label .. "s free tonight. Try another room type.") return end
	if not economy("Charge", player, t.price) then notify(player, ("A %s is $%d a stay - you can't cover it."):format(t.label, t.price)) return end
	free.guest = player
	free.untilT = os.clock() + STAY_SECS
	byGuest[player] = free
	player:SetAttribute("LuxorRoom", free.id)
	marker(free, true)
	notify(player, ("Welcome to the Luxor. %s %s, %s. Your key opens the door; check out here when you leave."):format(t.label, free.id, where(free)), 10)
end

local function checkOut(player: Player)
	local r = byGuest[player]
	if not r then notify(player, "You don't have a room here. Pick a room type at the desk to check in.", 4) return end
	release(r)
	notify(player, "You're checked out of room " .. r.id .. ". Thank you for staying at the Luxor.", 5)
end

local function hookClerk(clerk: BasePart)
	local kind = clerk:GetAttribute("Offer")
	if kind == "CheckOut" then
		local p = Instance.new("ProximityPrompt")
		p.ActionText = "Check out / your room"
		p.ObjectText = "Luxor front desk"
		p.HoldDuration = 0.3
		p.MaxActivationDistance = 10
		p.RequiresLineOfSight = false
		p.Parent = clerk
		p.Triggered:Connect(function(player)
			local r = byGuest[player]
			if r and os.clock() < r.untilT and not player:GetAttribute("LuxorCheckoutConfirm") then
				player:SetAttribute("LuxorCheckoutConfirm", true)
				task.delay(6, function() player:SetAttribute("LuxorCheckoutConfirm", nil) end)
				notify(player, ("Room %s: %s, %d min left. Press again to check out."):format(r.id, where(r), math.max(0, (r.untilT - os.clock()) // 60)), 6)
				if r then marker(r, true) end
				return
			end
			player:SetAttribute("LuxorCheckoutConfirm", nil)
			checkOut(player)
		end)
		return
	end
	local t = TYPES[kind]
	if not t then return end
	local p = Instance.new("ProximityPrompt")
	p.ActionText = ("Check in: %s ($%d)"):format(t.label, t.price)
	p.ObjectText = "Luxor front desk"
	p.HoldDuration = 0.8
	p.MaxActivationDistance = 10
	p.RequiresLineOfSight = false
	p.Parent = clerk
	p.Triggered:Connect(function(player) checkIn(player, kind) end)
end

for _, d in luxor:GetDescendants() do
	if d:IsA("BasePart") and d.Name == "HotelDoor" then hookDoor(d)
	elseif d:IsA("BasePart") and d.Name == "FrontDeskClerk" then hookClerk(d) end
end

Players.PlayerRemoving:Connect(function(p)
	local r = byGuest[p]
	if r then release(r) end
end)
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function()
		local r = byGuest[p]
		if r then task.wait(1) marker(r, true) end
	end)
end)

-- stays run out
task.spawn(function()
	while true do
		task.wait(20)
		for _, r in rooms do
			if r.guest and os.clock() > r.untilT then
				local g = r.guest
				release(r)
				if g.Parent then notify(g, "Your stay at the Luxor has ended (room " .. r.id .. "). Check in again at the front desk to stay.", 8) end
			end
		end
	end
end)

local n = 0
for _ in rooms do n += 1 end
print(("[LuxorHotel] %d rooms ready"):format(n))
