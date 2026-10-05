-- GunClient: aiming and firing for the guns WeaponsServer hands out.
-- Click to shoot (hold for automatics), R to reload. The server does the damage.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local events = ReplicatedStorage:WaitForChild("Events")
local gunShot = events:WaitForChild("GunShot")
local gunReload = events:WaitForChild("GunReload")

-- Ammo counter
local hud = Instance.new("ScreenGui")
hud.Name = "AmmoHud"
hud.ResetOnSpawn = false
local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(1, 1)
label.Position = UDim2.new(0.98, 0, 0.85, 0)
label.Size = UDim2.new(0.16, 0, 0.05, 0)
label.BackgroundTransparency = 0.4
label.BackgroundColor3 = Color3.new(0, 0, 0)
label.TextColor3 = Color3.new(1, 1, 1)
label.TextScaled = true
label.Font = Enum.Font.SourceSansBold
label.Visible = false
label.Parent = hud
hud.Parent = player:WaitForChild("PlayerGui")

local equipped = nil
local holding = false
local lastShot = 0

local function updateHud()
	if not equipped then
		label.Visible = false
		return
	end
	label.Visible = true
	if equipped:GetAttribute("Reloading") then
		label.Text = equipped.Name .. "  reloading..."
	else
		label.Text = ("%s  %d / %d"):format(equipped.Name, equipped:GetAttribute("Ammo") or 0, equipped:GetAttribute("MagSize") or 0)
	end
end

local function reload()
	if equipped and not equipped:GetAttribute("Reloading") then
		gunReload:FireServer(equipped)
	end
end

local function fireOnce(tool)
	if (tool:GetAttribute("Ammo") or 0) <= 0 then
		reload()
		return false
	end
	if tool:GetAttribute("Reloading") then
		return false
	end
	lastShot = os.clock()
	gunShot:FireServer(tool, mouse.Hit.Position)
	return true
end

local bound = {}
local function bind(tool)
	if bound[tool] then
		return
	end
	bound[tool] = true
	tool.Equipped:Connect(function()
		equipped = tool
		mouse.Icon = "rbxasset://textures/GunCursor.png"
		updateHud()
	end)
	tool.Unequipped:Connect(function()
		if equipped == tool then
			equipped = nil
			holding = false
			mouse.Icon = ""
			updateHud()
		end
	end)
	tool.Activated:Connect(function()
		holding = true
		local rate = tool:GetAttribute("FireRate") or 0.2
		while holding and equipped == tool do
			if os.clock() - lastShot >= rate then
				fireOnce(tool)
				if not tool:GetAttribute("Automatic") then
					break
				end
			end
			RunService.Heartbeat:Wait()
		end
	end)
	tool.Deactivated:Connect(function()
		holding = false
	end)
	tool:GetAttributeChangedSignal("Ammo"):Connect(updateHud)
	tool:GetAttributeChangedSignal("Reloading"):Connect(updateHud)
end

local function watch(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") and child:GetAttribute("GunName") then
			bind(child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(function()
				if child:GetAttribute("GunName") then
					bind(child)
				end
			end)
		end
	end)
end

local function onCharacter(character)
	watch(character)
	local backpack = player:WaitForChild("Backpack")
	watch(backpack)
end
if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.R then
		reload()
	end
end)
