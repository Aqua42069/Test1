-- Start menu controller (rewritten)
-- Owns opening/closing every menu panel, the menu camera, and the Play button.
-- The per-panel FrameHandler scripts only fill in their own content now.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local sideMenu = script.Parent
local gui = sideMenu.Parent
local frameOut = gui:WaitForChild("FrameOut")

local TWEEN_TIME = 0.3
local DEFAULT_OPEN = UDim2.new(0, 0, 0.25, 0)
local OPEN_POSITIONS = { Tour = UDim2.new(0, 0, 0.63, 0) }
local UPDATES_FALLBACK = "Welcome to Las Vegas!\n\nUpdate notes are served by the server's GetUpdates function."

local facts = {
	"You can buy cars from You Buy Car Now using in-game money",
	"Controls for the cars can be found in the game description",
	"Speed limits - 60MPH in city | 80MPH on highway",
	"More in-game money can be purchased from the product shop",
	"Record any abusive behaviour from law enforcement, we can deal with them then",
	"Cars can be resprayed at The Lord Sprayer",
	"Any guns that are from the gun shop are legal. Street dealers are not",
	"You have the right to refuse a search from an officer",
	"Furniture bought from the furniture shop will be permanently saved",
	"Houses can be bought from the estate agency which you can see on the tour",
	"Gamepasses offer enhanced gameplay here",
	"New to Las Vegas? Take a tour to know your way around",
	"Any advertisements found on billboards are bought by players",
	"Got suggestions to make Las Vegas better? PM LV City council members",
	"Try out the spray can and mark your territory",
}

local function setCore(coreType, enabled)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(coreType, enabled)
	end)
end

setCore(Enum.CoreGuiType.PlayerList, false)
setCore(Enum.CoreGuiType.Backpack, false)

local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
humanoid.WalkSpeed = 0

---------------------------------------------------------------------------
-- Menu camera
---------------------------------------------------------------------------
local current = nil -- name of the open panel

local function getHomeCFrame()
	local sign = workspace:FindFirstChild("VegasSign")
	if not sign then
		return nil
	end
	local center = sign:IsA("Model") and sign:GetBoundingBox() or sign.CFrame
	local pos = (center * CFrame.new(-3, 10, -20)).Position
	return CFrame.new(pos, pos + Vector3.new(1, 0, 0))
end

local function goHome(smooth)
	local cam = workspace.CurrentCamera
	local cf = getHomeCFrame()
	if not (cam and cf) then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	if smooth then
		TweenService:Create(cam, TweenInfo.new(1.5, Enum.EasingStyle.Sine), { CFrame = cf }):Play()
	else
		cam.CFrame = cf
	end
end

-- The default camera scripts like to flip the camera back to Custom when the
-- character spawns, so hold it on Scriptable for as long as the menu is up.
RunService:BindToRenderStep("StartMenuCameraLock", Enum.RenderPriority.Camera.Value + 1, function()
	local cam = workspace.CurrentCamera
	if cam and cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
		if current ~= "Tour" then
			goHome(false) -- the default camera moved us behind the character; put it back
		end
	end
end)
task.defer(goHome, false)

---------------------------------------------------------------------------
-- Panels
---------------------------------------------------------------------------
local panelNames = { "TeamChange", "ProductShop", "PassShop", "Tour", "Laws", "Credits" }
local panels = {}
for _, name in ipairs(panelNames) do
	panels[name] = gui:WaitForChild(name)
end
local touring = panels.Tour:WaitForChild("Touring")

-- The Tour panel never had a way out, so give it a Back button like the others.
if not panels.Tour:FindFirstChild("Close") then
	local template = panels.Laws:FindFirstChild("Close")
	if template then
		local back = template:Clone()
		back.Position = UDim2.new(0, 0, 0, 0)
		back.Parent = panels.Tour
	end
end

local function slide(frame, position)
	frame:TweenPosition(position, Enum.EasingDirection.Out, Enum.EasingStyle.Quad, TWEEN_TIME, true)
end

local function closePanel(name)
	local frame = panels[name]
	slide(frame, UDim2.new(-1, 0, frame.Position.Y.Scale, 0))
	if name == "Tour" then
		touring.Disabled = true
		goHome(true)
	end
	if current == name then
		current = nil
		frameOut.Value = false
	end
end

local function canChangeTeam()
	if RunService:IsStudio() or player.UserId == game.CreatorId then
		return true
	end
	local teamColor = player.TeamColor.Name
	return teamColor ~= "Deep orange" and teamColor ~= "Bright yellow"
end

local function openPanel(name)
	if current == name then
		closePanel(name) -- clicking the same button again closes it
		return
	end
	if name == "TeamChange" and not canChangeTeam() then
		return
	end
	if current then
		closePanel(current)
	end
	local frame = panels[name]
	local target = OPEN_POSITIONS[name] or DEFAULT_OPEN
	frame.Position = UDim2.new(-1, 0, target.Y.Scale, 0)
	frame.Visible = true
	slide(frame, target)
	current = name
	frameOut.Value = true
	if name == "Tour" then
		touring.Disabled = false -- restarting the script restarts the tour at stop 1
	end
end

for _, name in ipairs(panelNames) do
	local button = sideMenu:FindFirstChild(name)
	if button and button:IsA("GuiButton") then
		button.MouseButton1Click:Connect(function()
			openPanel(name)
		end)
	end
	local close = panels[name]:FindFirstChild("Close")
	if close then
		close.MouseButton1Click:Connect(function()
			closePanel(name)
		end)
	end
end

---------------------------------------------------------------------------
-- Random fact + recent updates
---------------------------------------------------------------------------
local randomFact = sideMenu:WaitForChild("RandomFact")
randomFact.Text = facts[math.random(1, #facts)]

task.spawn(function()
	local updates = sideMenu:WaitForChild("RecentUpdates"):WaitForChild("Updates")
	local functions = ReplicatedStorage:FindFirstChild("Functions")
	local getUpdates = functions and functions:FindFirstChild("GetUpdates")
	local answered = false
	task.delay(5, function()
		if not answered then
			updates.Text = UPDATES_FALLBACK
		end
	end)
	if not getUpdates then
		return
	end
	local ok, result = pcall(getUpdates.InvokeServer, getUpdates)
	answered = true
	updates.Text = (ok and type(result) == "string" and result ~= "") and result or UPDATES_FALLBACK
end)

---------------------------------------------------------------------------
-- Play
---------------------------------------------------------------------------
local playing = false

local function findPath(root, ...)
	local node = root
	for _, childName in ipairs({ ... }) do
		node = node and node:FindFirstChild(childName)
	end
	return node
end

sideMenu:WaitForChild("Play").MouseButton1Click:Connect(function()
	if playing then
		return
	end
	playing = true

	touring.Disabled = true
	for _, frame in pairs(panels) do
		slide(frame, UDim2.new(-1, 0, 0.25, 0))
	end
	slide(sideMenu, UDim2.new(-1, 0, 0, 0))
	local title = gui:FindFirstChild("Title")
	if title then
		slide(title, UDim2.new(0, 0, -0.2, 0))
	end
	frameOut.Value = false
	task.wait(TWEEN_TIME)

	RunService:UnbindFromRenderStep("StartMenuCameraLock")

	local playerGui = gui.Parent
	playerGui:WaitForChild("ArrestDatabase", 5)
	playerGui:WaitForChild("CellPhone", 5)
	playerGui:WaitForChild("HealthGui", 5)

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local forceField = char and char:FindFirstChildOfClass("ForceField")
	if forceField then
		forceField:Destroy()
	end
	-- the server has to remove it too, or you can never be hurt
	local events = game:GetService("ReplicatedStorage"):FindFirstChild("Events")
	local startPlaying = events and events:FindFirstChild("StartPlaying")
	if startPlaying then
		startPlaying:FireServer()
	end

	setCore(Enum.CoreGuiType.PlayerList, true)
	setCore(Enum.CoreGuiType.Backpack, true)

	local openClose = findPath(playerGui, "ArrestDatabase", "OpenClose")
	if openClose then
		openClose.Visible = true
	end
	local timer = findPath(playerGui, "CellPhone", "Outline", "ScreenFrame", "TimerScript")
	if timer then
		timer.Disabled = false
	end
	local phone = findPath(playerGui, "CellPhone", "Outline")
	if phone then
		phone.Visible = true
	end
	local health = findPath(playerGui, "HealthGui", "Holder")
	if health then
		health.Visible = true
	end

	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Custom
	if hum then
		cam.CameraSubject = hum
		hum.WalkSpeed = 16
	end

	local backpack = player:FindFirstChild("Backpack")
	local starterGear = player:FindFirstChild("StarterGear")
	if backpack and starterGear and #backpack:GetChildren() == 0 then
		for _, tool in ipairs(starterGear:GetChildren()) do
			tool:Clone().Parent = backpack
		end
	end

	local radio = playerGui:FindFirstChild("Radio")
	if radio then
		local teamColor = player.TeamColor.Name
		if teamColor ~= "Bright green" and teamColor ~= "Bright yellow" then
			local handler = findPath(radio, "Holder", "Handler")
			if handler then
				handler.Disabled = false
			end
			if radio:FindFirstChild("Holder") then
				radio.Holder.Visible = true
			end
		else
			radio:Destroy()
		end
	end

	gui:Destroy()
end)
