-- Jobs / team change panel (rewritten). Open/close is handled by SideMenu.Play/FrameTween.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local frame = script.Parent
local sideMenu = frame.Parent:WaitForChild("SideMenu")
local currentTeamLabel = sideMenu:WaitForChild("CurrentTeam")
local example = frame:WaitForChild("Example")
local desc = frame:FindFirstChild("Desc")

local MAIN_GROUP = 758071
local isDev = RunService:IsStudio() or player.UserId == game.CreatorId

local function readJson(name)
	local value = ReplicatedStorage:WaitForChild(name, 10)
	if not value then
		return {}
	end
	local waited = 0
	while value.Value == "" and waited < 10 do
		waited += task.wait(0.2)
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, value.Value)
	return ok and decoded or {}
end

local teams = readJson("TeamInfo")
local admins = readJson("AdminInfo")

local function safeCall(fn, ...)
	local ok, result = pcall(fn, ...)
	return ok and result or nil
end

local function isAdmin()
	local lower = player.Name:lower()
	for _, name in ipairs(admins) do
		if name == lower then
			return true
		end
	end
	return false
end

local function canJoin(team)
	local color, requirement = team[2], team[3]
	if color == "Deep orange" then
		return false -- Prisoners are never selectable
	end
	if isDev then
		return true -- Studio / place owner can test every team
	end
	if color == "Bright yellow" then
		return false
	end
	if isAdmin() then
		return true
	end
	if type(requirement) == "number" then
		return requirement > 0 and safeCall(player.IsInGroup, player, requirement) == true
	elseif type(requirement) == "string" then
		return safeCall(player.GetRoleInGroup, player, MAIN_GROUP) == team[1]
	elseif type(requirement) == "table" then
		local lower = player.Name:lower()
		for _, name in ipairs(requirement) do
			if name == lower then
				return true
			end
		end
	end
	return false
end

local function showTeam(name, color)
	currentTeamLabel.BackgroundColor3 = BrickColor.new(color).Color
	currentTeamLabel.Text = "Current Team: " .. name
end

local function refreshCurrentTeam()
	local current = player.Team
	if current and not player.Neutral then
		for _, team in ipairs(teams) do
			if team[1] == current.Name then
				showTeam(team[1], team[2])
				return
			end
		end
		currentTeamLabel.BackgroundColor3 = current.TeamColor.Color
		currentTeamLabel.Text = "Current Team: " .. current.Name
		return
	end
	currentTeamLabel.Text = "Current Team: None"
end

player:GetPropertyChangedSignal("Team"):Connect(refreshCurrentTeam)
player:GetPropertyChangedSignal("TeamColor"):Connect(refreshCurrentTeam)
player:GetPropertyChangedSignal("Neutral"):Connect(refreshCurrentTeam)
refreshCurrentTeam()

-- InvokeServer with a timeout so the menu never hangs if the server side is missing.
local function invoke(remote, timeout, ...)
	local args = table.pack(...)
	local thread = coroutine.running()
	local finished = false
	task.spawn(function()
		local ok, result = pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n))
		if not finished then
			finished = true
			task.spawn(thread, ok, result)
		end
	end)
	task.delay(timeout, function()
		if not finished then
			finished = true
			task.spawn(thread, false, "timed out")
		end
	end)
	return coroutine.yield()
end

local functions = ReplicatedStorage:WaitForChild("Functions", 10)
local request = functions and functions:FindFirstChild("TeamChangeRequest")
local busy = false

local function requestTeam(team)
	if busy then
		return
	end
	if not request then
		currentTeamLabel.Text = "Team change unavailable (no TeamChangeRequest)"
		return
	end
	busy = true
	local ok, changed = invoke(request, 6, team[2], true)
	if ok and changed then
		showTeam(team[1], team[2])
	elseif not ok then
		currentTeamLabel.Text = "Team server not responding"
		task.delay(2, refreshCurrentTeam)
	else
		refreshCurrentTeam()
	end
	busy = false
end

-- Group checks can be slow, so build the list off the main thread.
task.spawn(function()
	local eligible = {}
	for _, team in ipairs(teams) do
		if canJoin(team) then
			table.insert(eligible, team)
		end
	end

	if desc then
		desc.Text = #eligible == 0 and "There are no jobs available to you." or ""
	end

	local columns = 2
	local rows = math.max(1, math.ceil(#eligible / columns))
	local rowHeight = math.min(0.8 / rows, 0.12)
	for index, team in ipairs(eligible) do
		local i = index - 1
		local button = example:Clone()
		button.Name = team[1]
		button.Text = team[1]
		button.BackgroundColor3 = BrickColor.new(team[2]).Color
		button.Size = UDim2.new(1 / columns, 0, rowHeight, 0)
		button.Position = UDim2.new((i % columns) / columns, 0, 0.2 + math.floor(i / columns) * rowHeight, 0)
		button.Visible = true
		button.Parent = frame
		button.MouseButton1Click:Connect(function()
			requestTeam(team)
		end)
	end
end)
