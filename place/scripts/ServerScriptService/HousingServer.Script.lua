-- HousingServer
-- Rebuilt property and shops (the snapshot had no server code).
--   Property: trailers, motel rooms, houses and big houses. At the front door:
--     E = open the door (owner only - everyone else needs a lockpick = burglary)
--     F = rent it / move out. Rent is taken from you every payday.
--     You can have one place at a time; it's saved with your money.
--   Clothing store: click a mannequin's shirt/pants button to buy what it wears.
--   Spray shop: park your car by the garage and press E to respray it.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

-- rent per payday, deposit to move in (x rent)
local TYPES = {
	MotelRooms = { label = "motel room", rent = 20 },
	Trailers = { label = "trailer", rent = 40 },
	Houses = { label = "house", rent = 90 },
	BigHouses = { label = "big house", rent = 160 },
}
local DEPOSIT_MULTIPLIER = 10
local DOOR_OPEN_TIME = 6
local SHIRT_PRICE, PANTS_PRICE = 75, 75
local RESPRAY_PRICE = 150
local PAINT = {
	Color3.fromRGB(196, 40, 28), Color3.fromRGB(13, 105, 172), Color3.fromRGB(27, 42, 53),
	Color3.fromRGB(242, 243, 243), Color3.fromRGB(245, 205, 48), Color3.fromRGB(40, 127, 71),
	Color3.fromRGB(218, 133, 65), Color3.fromRGB(107, 50, 124), Color3.fromRGB(99, 95, 98),
	Color3.fromRGB(255, 102, 204),
}

local function economy(action, player, amount)
	local fn = ServerStorage:WaitForChild("Economy", 10)
	if not fn then
		return nil
	end
	return fn:Invoke(action, player, amount)
end

local function reportCrime(player, crime, stars)
	local fn = ServerStorage:FindFirstChild("ReportCrime")
	if fn then
		fn:Invoke(player, crime, stars)
	end
end

local function notify(player, text)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local old = playerGui:FindFirstChild("HousingNotice")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "HousingNotice"
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.24, 0)
	label.Size = UDim2.new(0.42, 0, 0.045, 0)
	label.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Text = text
	label.Parent = gui
	gui.Parent = playerGui
	game:GetService("Debris"):AddItem(gui, 3.5)
end

local function hasLockpick(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	return (backpack and backpack:FindFirstChild("Lockpick")) or (character and character:FindFirstChild("Lockpick"))
end

---------------------------------------------------------------------------
-- Property
---------------------------------------------------------------------------
local properties = {} -- id -> property
local owned = {} -- [player] = property

local function setSign(property)
	local text = property.sign.Text
	if property.owner then
		text.Text = ("%s's %s"):format(property.owner.Name, property.label)
		text.TextColor3 = Color3.fromRGB(220, 220, 220)
	else
		text.Text = ("FOR RENT  $%d/payday\n(%s, $%d to move in)"):format(property.rent, property.label, property.deposit)
		text.TextColor3 = Color3.fromRGB(120, 255, 120)
	end
end

local function openDoor(part)
	if part:GetAttribute("Open") then
		return
	end
	part:SetAttribute("Open", true)
	local collide, transparency = part.CanCollide, part.Transparency
	part.CanCollide = false
	part.Transparency = math.max(transparency, 0.6)
	task.delay(DOOR_OPEN_TIME, function()
		while part.Parent and os.clock()<(part:GetAttribute("PoliceBreachUntil") or 0) do task.wait(0.5) end
		if not part.Parent then return end
		part.CanCollide = collide
		part.Transparency = transparency
		part:SetAttribute("Open", false)
	end)
end

local breach=Instance.new("BindableFunction");breach.Name="PoliceHouseBreach";breach.Parent=ServerStorage
breach.OnInvoke=function(action,door,seconds)
 if action~="Breach" or typeof(door)~="Instance" or not door:IsA("BasePart") or door.Name~="FrontDoor" or not door:IsDescendantOf(workspace) then return false end
 door:SetAttribute("PoliceBreachUntil",os.clock()+math.clamp(tonumber(seconds) or 18,1,25));openDoor(door);return true
end

local function setRent(player)
	local rentValue = player:FindFirstChild("Rent")
	if rentValue then
		rentValue.Value = owned[player] and owned[player].rent or 0
	end
end

local function moveIn(player, property, free)
	if owned[player] then
		return false, "You already have a " .. owned[player].label .. ". Move out first."
	end
	if property.owner then
		return false, "Someone already lives here"
	end
	-- v255: a place paid for mostly with dirty money carries a lien (taken at an asset freeze)
	local dirtyPaid = false
	if not free then
		local dc, db = economy("Dirty", player)
		dirtyPaid = (tonumber(dc) or 0) + (tonumber(db) or 0) >= property.deposit * 0.5
	end
	if not free and not economy("Charge", player, property.deposit) then
		return false, ("You need $%d to move in"):format(property.deposit)
	end
	if not free then
		player:SetAttribute("HouseDirty", if dirtyPaid then true else nil)
	end
	property.owner = player
	property.ownerValue.Value = player.Name
	owned[player] = property
	player:SetAttribute("HouseId", property.id)
	setRent(player)
	setSign(property)
	return true
end

local function moveOut(player)
	local property = owned[player]
	if not property then
		return
	end
	owned[player] = nil
	property.owner = nil
	property.ownerValue.Value = ""
	player:SetAttribute("HouseId", nil)
	setRent(player)
	setSign(property)
end

local function setupProperty(id, model, info)
	local ownerValue = model:FindFirstChild("Owner")
	local front = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and (part.Name == "FrontDoor" or part.Name == "GarageDoor") then
			table.insert(front, part)
		end
	end
	if not ownerValue or #front == 0 then
		return
	end
	ownerValue.Value = ""
	local property = {
		id = id, model = model, label = info.label, rent = info.rent,
		deposit = info.rent * DEPOSIT_MULTIPLIER, ownerValue = ownerValue, owner = nil,
	}
	properties[id] = property

	-- Sign over the (first) front door
	local main = front[1]
	for _, part in ipairs(front) do
		if part.Name == "FrontDoor" then
			main = part
			break
		end
	end
	local sign = Instance.new("BillboardGui")
	sign.Name = "PropertySign"
	sign.Size = UDim2.new(0, 190, 0, 46)
	sign.StudsOffset = Vector3.new(0, main.Size.Y / 2 + 1.5, 0)
	sign.MaxDistance = 45
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	text.BackgroundTransparency = 0.35
	text.Font = Enum.Font.SourceSansBold
	text.TextScaled = true
	text.Parent = sign
	sign.Parent = main
	property.sign = sign
	setSign(property)

	-- Rent / move out prompt on the main door
	local rentPrompt = Instance.new("ProximityPrompt")
	rentPrompt.Name = "RentPrompt"
	rentPrompt.ActionText = "Rent / move out"
	rentPrompt.ObjectText = info.label
	rentPrompt.KeyboardKeyCode = Enum.KeyCode.F
	rentPrompt.HoldDuration = 0.8
	rentPrompt.RequiresLineOfSight = false
	rentPrompt.MaxActivationDistance = 9
	rentPrompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	rentPrompt.Parent = main
	rentPrompt.Triggered:Connect(function(player)
		if property.owner == player then
			moveOut(player)
			notify(player, "You moved out.")
		elseif property.owner then
			notify(player, "This is " .. property.owner.Name .. "'s place.")
		else
			local ok, err = moveIn(player, property)
			notify(player, ok and ("Welcome home! Rent is $%d every payday."):format(property.rent) or err)
		end
	end)

	-- Door prompts (every front/garage door)
	for _, door in ipairs(front) do
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "DoorPrompt"
		prompt.ActionText = "Open door"
		prompt.ObjectText = info.label
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 9
		prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
		prompt.Parent = door
		prompt.Triggered:Connect(function(player)
			if door:GetAttribute("Open") then
				return
			end
			if not property.owner or property.owner == player then
				openDoor(door) -- empty places are open for viewing
			elseif hasLockpick(player) then
				openDoor(door)
				reportCrime(player, "Burglary", 1)
				notify(player, "You broke in. The police have been told!")
			else
				notify(player, "Locked. This is " .. property.owner.Name .. "'s place.")
			end
		end)
	end
end

for folderName, info in pairs(TYPES) do
	local folder = workspace:FindFirstChild(folderName)
	if folder then
		for _, model in ipairs(folder:GetChildren()) do
			if model:IsA("Model") then
				setupProperty(folderName .. "/" .. model.Name, model, info)
			end
		end
	end
end

-- Interior doors in houses just open for anyone inside.
for folderName in pairs(TYPES) do
	local folder = workspace:FindFirstChild(folderName)
	if folder then
		for _, part in ipairs(folder:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == "Door" then
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Open door"
				prompt.RequiresLineOfSight = false
				prompt.MaxActivationDistance = 7
				prompt.Parent = part
				prompt.Triggered:Connect(function()
					openDoor(part)
				end)
			end
		end
	end
end

local function onPlayerAdded(player)
	-- Saved home (EconomyServer loads it into this attribute)
	local function claimSaved()
		local id = player:GetAttribute("SavedHouse")
		local property = id and properties[id]
		if property and not property.owner then
			moveIn(player, property, true)
		end
	end
	player:GetAttributeChangedSignal("SavedHouse"):Connect(claimSaved)
	claimSaved()
	-- v255: AssetFreeze sets HouseLien when a dirty-money home is seized
	player:GetAttributeChangedSignal("HouseLien"):Connect(function()
		if player:GetAttribute("HouseLien") and owned[player] then
			moveOut(player)
			player:SetAttribute("SavedHouse", nil)
			player:SetAttribute("HouseDirty", nil)
			notify(player, "Your home was seized - a DA lien on property bought with crime money")
		end
	end)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
-- v255: AssetFreeze puts the house safe inside the owner's home
do
	local fn = ServerStorage:FindFirstChild("HouseOf") or Instance.new("BindableFunction")
	fn.Name = "HouseOf"
	fn.OnInvoke = function(player)
		local property = owned[player]
		return property and property.model
	end
	fn.Parent = ServerStorage
end
Players.PlayerRemoving:Connect(function(player)
	local property = owned[player]
	if property then
		-- Free it up for others while you're away; you get it back next visit if it's still free.
		owned[player] = nil
		property.owner = nil
		property.ownerValue.Value = ""
		setSign(property)
	end
end)

---------------------------------------------------------------------------
-- Clothing store
---------------------------------------------------------------------------
local function assetId(value)
	return tonumber(tostring(value):match("(%d+)%D*$"))
end

local function wear(player, kind, id)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	local ok = pcall(function()
		local description = humanoid:GetAppliedDescription()
		description[kind] = id
		humanoid:ApplyDescription(description)
	end)
	return ok
end

local mannequins = 0
local shop = workspace:FindFirstChild("ThingsToBuy")
if shop then
	for _, mannequin in ipairs(shop:GetChildren()) do
		for _, pair in ipairs({ { "BuyShirt", "ShirtID", "Shirt", SHIRT_PRICE }, { "BuyPants", "PantsID", "Pants", PANTS_PRICE } }) do
			local button = mannequin:FindFirstChild(pair[1])
			local idValue = mannequin:FindFirstChild(pair[2])
			local detector = button and button:FindFirstChildOfClass("ClickDetector")
			local id = idValue and assetId(idValue.Value)
			if detector and id then
				mannequins += 1
				detector.MaxActivationDistance = 12
				detector.MouseClick:Connect(function(player)
					if not economy("Charge", player, pair[4]) then
						notify(player, ("You need $%d"):format(pair[4]))
						return
					end
					if wear(player, pair[3], id) then
						notify(player, ("Bought the %s for $%d"):format(pair[3]:lower(), pair[4]))
					else
						economy("AddBank", player, pair[4]) -- refund
						notify(player, "That item couldn't be loaded - refunded")
					end
				end)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Spray shop
---------------------------------------------------------------------------
local function playerCar(player, near, range)
	local folder = workspace:FindFirstChild("SpawnedCars")
	if not folder then
		return nil
	end
	for _, car in ipairs(folder:GetChildren()) do
		local owner = car:FindFirstChild("Owner")
		if owner and owner.Value == player and (car:GetPivot().Position - near).Magnitude <= range then
			return car
		end
	end
	return nil
end

local sprayShops = 0
for _, shopModel in ipairs(workspace:GetChildren()) do
	if shopModel.Name == "SprayShop" then
		local garage = shopModel:FindFirstChild("Garage", true)
		if garage and garage:IsA("BasePart") then
			sprayShops += 1
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = ("Respray your car ($%d)"):format(RESPRAY_PRICE)
			prompt.ObjectText = "The Lord Sprayer"
			prompt.RequiresLineOfSight = false
			prompt.MaxActivationDistance = 14
			prompt.Parent = garage
			prompt.Triggered:Connect(function(player)
				local car = playerCar(player, garage.Position, 40)
				if not car then
					notify(player, "Park your own car next to the garage first")
					return
				end
				if not economy("Charge", player, RESPRAY_PRICE) then
					notify(player, ("A respray costs $%d"):format(RESPRAY_PRICE))
					return
				end
				local index = ((car:GetAttribute("PaintIndex") or 0) % #PAINT) + 1
				car:SetAttribute("PaintIndex", index)
				local painted = 0
				for _, part in ipairs(car:GetDescendants()) do
					if part:IsA("BasePart") and part.Name == "Primary" then
						part.Color = PAINT[index]
						painted += 1
					end
				end
				notify(player, painted > 0 and "Fresh paint! Press again for another colour." or "This car can't be painted")
			end)
		end
	end
end

local count = 0
for _ in pairs(properties) do
	count += 1
end
print(("[HousingServer] %d properties, %d clothing buttons, %d spray shops ready"):format(count, mannequins, sprayShops))
