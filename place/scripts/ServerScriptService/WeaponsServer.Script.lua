-- WeaponsServer
-- Rebuilt guns (the snapshot had no gun models or gun scripts).
--   * BB&B phone app sells them (prices = original x5, Marksman Discount = 20% off)
--   * Guns are built here as Tools; StarterPlayerScripts.GunClient handles aiming,
--     firing (hold for automatics) and reloading (R). Damage is done here.
--   * Body Armour gives +50 max health until you die.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

-- name, base price, image asset, damage, seconds between shots, magazine,
-- automatic, spread (degrees), range, reload seconds, handle length
local GUNS = {
	{ "M9", 50, 140471680, 22, 0.22, 15, false, 1.2, 250, 1.4, 1.2 },
	{ "G36C", 390, 152589159, 18, 0.09, 30, true, 2.2, 400, 2.2, 2.6 },
	{ "M16", 380, 140471694, 26, 0.16, 30, false, 1.2, 500, 2.2, 3.2 },
	{ "M4A1", 400, 140471667, 19, 0.085, 30, true, 2.0, 450, 2.2, 2.8 },
	{ "SCAR-L", 410, 152589235, 22, 0.1, 30, true, 2.2, 450, 2.4, 3.0 },
	{ "TAR-21", 420, 152589246, 20, 0.08, 30, true, 2.4, 420, 2.3, 2.6 },
	{ "L86 LSW", 450, 152589178, 21, 0.1, 60, true, 2.6, 500, 3.2, 3.4 },
	{ "M124", 460, 152589200, 18, 0.07, 100, true, 3.4, 450, 4.5, 3.4 },
	{ "M1014", 420, 140471705, 12, 0.5, 7, false, 6, 120, 3.0, 3.2, 6 },
	{ "Barret .50Cal", 500, 152589140, 95, 1.6, 5, false, 0.2, 1500, 3.5, 4.4 },
	{ "R700", 480, 152589224, 80, 1.3, 5, false, 0.2, 1200, 3.0, 4.0 },
}
local ARMOUR = { "Body Armour", 250, 152596158 }
local PRICE_MULTIPLIER = 5

local functions = ReplicatedStorage:WaitForChild("Functions")
local events = ReplicatedStorage:WaitForChild("Events")

local function remote(folder, className, name)
	local obj = folder:FindFirstChild(name)
	if not (obj and obj:IsA(className)) then
		obj = Instance.new(className)
		obj.Name = name
		obj.Parent = folder
	end
	return obj
end

local gunShot = remote(events, "RemoteEvent", "GunShot")

-- Lets other scripts (PoliceAIServer) react to a player actually firing a
-- shot, not just their wanted level - e.g. escalating from "approach and
-- taser" to "return fire" the instant a suspect shoots at an officer.
local shotFired = ServerStorage:FindFirstChild("ShotFired") or Instance.new("BindableEvent")
shotFired.Name = "ShotFired"
shotFired.Parent = ServerStorage
local gunReload = remote(events, "RemoteEvent", "GunReload")

local defs = {}
for _, g in ipairs(GUNS) do
	defs[g[1]] = {
		name = g[1], price = g[2] * PRICE_MULTIPLIER, image = g[3], damage = g[4], rate = g[5],
		mag = g[6], auto = g[7], spread = g[8], range = g[9], reload = g[10], length = g[11],
		pellets = g[12] or 1,
	}
end

local function economy(action, player, amount)
	local fn = ServerStorage:WaitForChild("Economy", 10)
	return fn and fn:Invoke(action, player, amount)
end

local function ownsPass(player, passName)
	return economy("OwnsPass", player, passName) == true
end

local function price(player, base)
	if ownsPass(player, "Marksman Discount") then
		return math.floor(base * 0.8)
	end
	return base
end

---------------------------------------------------------------------------
-- Building gun tools
---------------------------------------------------------------------------
local function makeGun(def, issued)
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.ToolTip = ("%s  |  %d dmg  |  %d rounds"):format(def.name, def.damage, def.mag)
	tool.CanBeDropped = false
	tool:SetAttribute("GunName", def.name)
	if issued then
		tool:SetAttribute("Issued", true) -- police-issued, not owned - see PoliceServer.revokePoliceGear
	end
	tool:SetAttribute("Ammo", def.mag)
	tool:SetAttribute("MagSize", def.mag)
	tool:SetAttribute("FireRate", def.rate)
	tool:SetAttribute("Automatic", def.auto)
	tool:SetAttribute("Reloading", false)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.35, 0.55, def.length)
	handle.Color = Color3.fromRGB(30, 30, 32)
	handle.Material = Enum.Material.Metal
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	local grip = Instance.new("Part")
	grip.Name = "Grip"
	grip.Size = Vector3.new(0.3, 0.8, 0.4)
	grip.Color = Color3.fromRGB(20, 20, 20)
	grip.CanCollide = false
	grip.Massless = true
	grip.CFrame = handle.CFrame * CFrame.new(0, -0.5, def.length * 0.2)
	grip.Parent = tool
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = grip
	weld.Parent = grip

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0.1, -def.length / 2)
	muzzle.Parent = handle

	tool.GripPos = Vector3.new(0, -0.1, def.length * 0.2)
	return tool
end

local function giveGun(player, gunName, temporary)
	local def = defs[gunName]
	if not def then
		return false
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false
	end
	-- Bought guns are kept after respawning; issued ones (police sidearms) aren't.
	local starterGear = player:FindFirstChild("StarterGear")
	if not temporary and starterGear and not starterGear:FindFirstChild(gunName) then
		makeGun(def).Parent = starterGear
	end
	local character = player.Character
	if not (backpack:FindFirstChild(gunName) or (character and character:FindFirstChild(gunName))) then
		makeGun(def, temporary).Parent = backpack
	end
	return true
end

local giveGunFn = ServerStorage:FindFirstChild("GiveGun") or Instance.new("BindableFunction")
giveGunFn.Name = "GiveGun"
giveGunFn.OnInvoke = giveGun
giveGunFn.Parent = ServerStorage

---------------------------------------------------------------------------
-- BB&B app
---------------------------------------------------------------------------
remote(functions, "RemoteFunction", "GetGunCatalog").OnServerInvoke = function(player)
	local list = {}
	for _, g in ipairs(GUNS) do
		local def = defs[g[1]]
		table.insert(list, {
			name = def.name,
			price = price(player, def.price),
			image = "rbxthumb://type=Asset&id=" .. def.image .. "&w=150&h=150",
			stats = ("%d dmg, %d rds%s"):format(def.damage, def.mag, def.auto and ", auto" or ""),
		})
	end
	table.insert(list, {
		name = ARMOUR[1],
		price = price(player, ARMOUR[2] * PRICE_MULTIPLIER),
		image = "rbxthumb://type=Asset&id=" .. ARMOUR[3] .. "&w=150&h=150",
		stats = "+50 max health until you die",
	})
	return list
end

remote(functions, "RemoteFunction", "BuyGun").OnServerInvoke = function(player, itemName)
	if type(itemName) ~= "string" then
		return false, "?"
	end
	if player.Team and player.Team.Name == "Prisoners" then
		return false, "We ain't sellin' to inmates"
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "Try again when you're alive"
	end

	if itemName == ARMOUR[1] then
		if humanoid:GetAttribute("Armoured") then
			return false, "You're already wearing armour"
		end
		if not economy("Charge", player, price(player, ARMOUR[2] * PRICE_MULTIPLIER)) then
			return false, "Get more money"
		end
		humanoid:SetAttribute("Armoured", true)
		humanoid.MaxHealth += 50
		humanoid.Health += 50
		return true, "Armour on (+50 health)"
	end

	local def = defs[itemName]
	if not def then
		return false, "Out of stock"
	end
	local gear = player:FindFirstChild("StarterGear")
	if gear and gear:FindFirstChild(itemName) then
		return false, "You already own this"
	end
	if not economy("Charge", player, price(player, def.price)) then
		return false, "Get more money"
	end
	giveGun(player, itemName)
	return true, "Here y'all go - check your backpack"
end

---------------------------------------------------------------------------
-- Shooting
---------------------------------------------------------------------------
local lastShot = {}

local function tracer(from, to)
	local length = (to - from).Magnitude
	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 210, 120)
	beam.Transparency = 0.3
	beam.Size = Vector3.new(0.08, 0.08, length)
	beam.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2)
	beam.Parent = workspace
	Debris:AddItem(beam, 0.06)
end

gunShot.OnServerEvent:Connect(function(player, tool, target)
	if typeof(tool) ~= "Instance" or typeof(target) ~= "Vector3" then
		return
	end
	local character = player.Character
	local def = defs[tool:GetAttribute("GunName") or ""]
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (def and tool.Parent == character and humanoid and humanoid.Health > 0) then
		return
	end
	if tool:GetAttribute("Reloading") or (tool:GetAttribute("Ammo") or 0) <= 0 then
		return
	end
	local now = os.clock()
	if lastShot[tool] and now - lastShot[tool] < def.rate * 0.75 then
		return
	end
	lastShot[tool] = now
	tool:SetAttribute("Ammo", tool:GetAttribute("Ammo") - 1)
	shotFired:Fire(player, tool)

	local handle = tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	local origin = muzzle and muzzle.WorldPosition or (handle and handle.Position)
	local head = character:FindFirstChild("Head")
	if not origin or not head or (origin - head.Position).Magnitude > 10 then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local aim = (target - origin)
	if aim.Magnitude < 0.1 then
		return
	end
	aim = aim.Unit
	for _ = 1, def.pellets do
		local spread = math.rad(def.spread)
		local direction = (CFrame.lookAt(Vector3.zero, aim)
			* CFrame.Angles((math.random() - 0.5) * spread, (math.random() - 0.5) * spread, 0)).LookVector
		local result = workspace:Raycast(origin, direction * def.range, params)
		local hitPos = result and result.Position or (origin + direction * def.range)
		tracer(origin, hitPos)

		if result then
			local model = result.Instance:FindFirstAncestorOfClass("Model")
			local victim = model and model:FindFirstChildOfClass("Humanoid")
			if victim and victim ~= humanoid and victim.Health > 0 then
				local damage = def.damage * (result.Instance.Name == "Head" and 1.5 or 1)
				local tag = Instance.new("ObjectValue")
				tag.Name = "creator"
				tag.Value = player
				tag.Parent = victim
				Debris:AddItem(tag, 2)
				-- Persistent attribution survives the short-lived creator tag.
				-- NPC death/reporting can therefore identify a killer even if a
				-- delayed death happens after the 2-second creator tag expired.
				victim:SetAttribute("LastDamagerUserId",player.UserId)
				victim:SetAttribute("LastDamagedAt",os.time())
				-- v215: someone in a car: the car takes the hit
				if victim.SeatPart then
					local vd = game:GetService("ServerStorage"):FindFirstChild("VehicleDamage")
					if vd and vd:IsA("BindableFunction") then
						local ok, left = pcall(vd.Invoke, vd, victim, damage)
						if ok and type(left) == "number" then
							damage = left
						end
					end
				end
				if damage > 0 then
					victim:TakeDamage(damage)
				end
			end
		end
	end
end)

gunReload.OnServerEvent:Connect(function(player, tool)
	if typeof(tool) ~= "Instance" or tool.Parent ~= player.Character then
		return
	end
	local def = defs[tool:GetAttribute("GunName") or ""]
	if not def or tool:GetAttribute("Reloading") or tool:GetAttribute("Ammo") >= def.mag then
		return
	end
	tool:SetAttribute("Reloading", true)
	task.delay(def.reload, function()
		if tool.Parent then
			tool:SetAttribute("Ammo", def.mag)
			tool:SetAttribute("Reloading", false)
		end
	end)
end)
