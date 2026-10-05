-- SecurityGates
-- The metal detectors (casino x2, airport terminal, GNC bank) have an invisible
-- wall through the arch. Step on the pad in front of the detector and you're
-- walked through: your weapons are held on the way in and handed back on the
-- way out. Police teams keep their gear.
local Players = game:GetService("Players")

local LAW_TEAMS = {
	["LVPD"] = true, ["SWAT"] = true, ["Federal Bureau of Investigation"] = true,
	["U.S. Marshal Service"] = true, ["USM"] = true, ["Secret Service"] = true,
	["Homeland Security"] = true, ["Federal Protection Service"] = true,
	["Special Forces"] = true, ["Dept. of Justice"] = true, ["Prison Staff"] = true,
}
local STEP_PAST = 4 -- studs past the far pad you're placed

local held = {} -- [player] = { tools }
local cooldown = {} -- [player] = time

local function isWeapon(tool)
	return tool:IsA("Tool") and (tool:GetAttribute("GunName") ~= nil or tool:GetAttribute("Cuffs") ~= nil
		or tool.Name == "Lockpick")
end

local function isLaw(player)
	return player.Team ~= nil and LAW_TEAMS[player.Team.Name] == true
end

local function takeWeapons(player)
	if isLaw(player) then
		return 0
	end
	local stash = held[player] or {}
	held[player] = stash
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:UnequipTools()
	end
	local taken = 0
	local backpack = player:FindFirstChildOfClass("Backpack")
	for _, container in ipairs({ backpack, character }) do
		if container then
			for _, tool in ipairs(container:GetChildren()) do
				if isWeapon(tool) then
					tool.Parent = nil
					table.insert(stash, tool)
					taken += 1
				end
			end
		end
	end
	return taken
end

local function giveBack(player)
	local stash = held[player]
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not (stash and backpack) then
		return 0
	end
	for _, tool in ipairs(stash) do
		tool.Parent = backpack
	end
	held[player] = nil
	return #stash
end

local function notify(player, text)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local old = playerGui:FindFirstChild("GateNotice")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "GateNotice"
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.24, 0)
	label.Size = UDim2.new(0.4, 0, 0.045, 0)
	label.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Text = text
	label.Parent = gui
	gui.Parent = playerGui
	game:GetService("Debris"):AddItem(gui, 3)
end

-- Continue the player forward past the detector, in whatever direction they
-- were already walking (their own momentum, falling back to which way
-- they're facing). This never depends on guessing which pad is "in front" -
-- that guess was wrong for some gates and sent people backwards.
local function walkThrough(player, pad)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local velocity = root.AssemblyLinearVelocity
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	if flat.Magnitude < 2 then
		local look = root.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
	end
	if flat.Magnitude < 0.1 then
		return
	end
	local dir = flat.Unit
	local target = pad.Position + dir * STEP_PAST + Vector3.new(0, 3, 0)
	character:PivotTo(CFrame.lookAt(target, target + dir))
end

local function hook(pad, entering)
	pad.Touched:Connect(function(hit)
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if not player then
			return
		end
		local humanoid = hit.Parent:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart then
			return
		end
		local now = os.clock()
		if cooldown[player] and now - cooldown[player] < 1.5 then
			return
		end
		cooldown[player] = now
		if entering then
			local n = takeWeapons(player)
			if n > 0 then
				notify(player, ("Security is holding %d item%s until you leave."):format(n, n == 1 and "" or "s"))
			end
		else
			local n = giveBack(player)
			if n > 0 then
				notify(player, ("Security returned your %d item%s."):format(n, n == 1 and "" or "s"))
			end
		end
		walkThrough(player, pad)
	end)
end

local lanes = 0
for _, gate in ipairs(workspace:GetDescendants()) do
	if gate.Name == "SecurityGate" and gate:IsA("Model") then
		for _, teleporters in ipairs(gate:GetChildren()) do
			if teleporters.Name == "Teleporters" then
				-- Each pad just needs to know whether it's an entry or exit pad -
				-- the actual walk-through direction now comes from the player's
				-- own movement, not from pairing pads up.
				for _, pad in ipairs(teleporters:GetChildren()) do
					if pad:IsA("BasePart") then
						if pad.Name == "TakeTools" then
							hook(pad, true)
							lanes += 1
						elseif pad.Name == "GiveToolsBack" then
							hook(pad, false)
						end
					end
				end
			end
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	held[player] = nil
	cooldown[player] = nil
end)
print(("[SecurityGates] %d metal detector lanes working"):format(lanes))
