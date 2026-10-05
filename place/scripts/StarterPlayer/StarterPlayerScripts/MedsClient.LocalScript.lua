-- MedsClient: click an equipped medicine to use it. EconomyServer applies the
-- effect and decides whether it's wasted (e.g. already at full health).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local useMedicine = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UseMedicine")

local bound = {}
local function bind(tool)
	if bound[tool] or not tool:GetAttribute("MedName") then
		return
	end
	bound[tool] = true
	tool.Activated:Connect(function()
		useMedicine:FireServer(tool)
	end)
end

local function watch(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") then
			task.defer(bind, child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(bind, child)
		end
	end)
end

local function onCharacter(character)
	watch(character)
	watch(player:WaitForChild("Backpack"))
end
if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)
