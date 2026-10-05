-- DayNightCycle (v200)
-- Advances Lighting.ClockTime so the prison schedule (Config.PrisonSchedule in
-- PoliceSystem: Count / Chow / Programs / Yard / Lockdown) actually changes.
-- One full in-game day takes DAY_LENGTH_MINUTES real minutes.

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local DAY_LENGTH_MINUTES = 24 -- 1 in-game hour per real minute
local START_HOUR = 9 -- servers start in the morning

Lighting.ClockTime = START_HOUR
local hoursPerSecond = 24 / (DAY_LENGTH_MINUTES * 60)
local accumulated = 0

RunService.Heartbeat:Connect(function(dt)
	-- write a few times a second, not every frame (replication)
	accumulated += dt
	if accumulated < 0.25 then
		return
	end
	Lighting.ClockTime = (Lighting.ClockTime + accumulated * hoursPerSecond) % 24
	accumulated = 0
end)

print(("[DayNightCycle] %d-minute days, starting at %02d:00"):format(DAY_LENGTH_MINUTES, START_HOUR))

-- v286z: /time - jump the city clock. "/time 21", "/time 9:30", "/time 6am", "/time 11:45pm",
-- "/time morning|noon|evening|night|midnight". Studio, or the owner / the game's creator.
local Players = game:GetService("Players")
local NAMED = { morning = 8, noon = 12, afternoon = 15, evening = 19, night = 22, midnight = 0, dawn = 6, dusk = 20 }
local function allowed(p: Player): boolean
	-- the owner by name, Studio, or the game's creator (a user-owned game) - works in live servers too
	return RunService:IsStudio() or string.lower(p.Name) == "aquagaming22" or (game.CreatorType == Enum.CreatorType.User and p.UserId == game.CreatorId)
end
local function parse(arg: string): number?
	arg = string.lower(arg)
	if NAMED[arg] then return NAMED[arg] end
	local h, m, ap = arg:match("^(%d+):?(%d*)%s*([ap]?)m?$")
	h = tonumber(h)
	if not h then return nil end
	m = tonumber(m) or 0
	if ap == "p" and h < 12 then h += 12 elseif ap == "a" and h == 12 then h = 0 end
	if h > 24 or m > 59 then return nil end
	return (h + m / 60) % 24
end
-- a short note on the player's screen (the command's answer)
local function toast(p: Player, text: string)
	local pg = p:FindFirstChild("PlayerGui")
	if not pg then return end
	local old = pg:FindFirstChild("TimeCommandNote")
	if old then old:Destroy() end
	local g = Instance.new("ScreenGui")
	g.Name = "TimeCommandNote"
	g.ResetOnSpawn = false
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = UDim2.new(0.5, 0, 0, 120)
	l.Size = UDim2.fromOffset(360, 36)
	l.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	l.BackgroundTransparency = 0.2
	l.TextColor3 = Color3.fromRGB(255, 220, 150)
	l.Font = Enum.Font.GothamBold
	l.TextSize = 16
	l.Text = text
	Instance.new("UICorner").Parent = l
	l.Parent = g
	g.Parent = pg
	task.delay(3, function() if g.Parent then g:Destroy() end end)
end
local lastRun: { [Player]: number } = {}
local function run(p: Player, msg: string)
	local arg = msg:match("^/time%s+(.+)$")
	if not arg or not allowed(p) then return end
	-- the same message can arrive by both routes (the chat command and Player.Chatted)
	if lastRun[p] and os.clock() - lastRun[p] < 0.5 then return end
	lastRun[p] = os.clock()
	local t = parse((arg:gsub("%s+$", "")))
	if not t then
		toast(p, "Try /time 21, /time 9:30, /time 6am, /time night")
		return
	end
	Lighting.ClockTime = t
	accumulated = 0
	local hh, mm = math.floor(t), math.floor((t % 1) * 60 + 0.5)
	toast(p, ("Time set to %02d:%02d"):format(hh, mm))
	print(("[DayNightCycle] %s set the time to %02d:%02d"):format(p.Name, hh, mm))
end
local function hook(p: Player)
	p.Chatted:Connect(function(msg) run(p, msg) end)
end
Players.PlayerAdded:Connect(hook)
for _, p in Players:GetPlayers() do hook(p) end
Players.PlayerRemoving:Connect(function(p) lastRun[p] = nil end)
-- v290: a real TextChatService command. With the new chat, a "/..." message that isn't a
-- registered command isn't sent as chat - Player.Chatted never saw "/time" in a live server.
-- Registered whatever ChatVersion says: Studio can report LegacyChatService while live servers
-- run TextChatService (Roblox retired legacy chat); a command is harmless under legacy.
local TextChatService = game:GetService("TextChatService")
do
	local folder = TextChatService:FindFirstChild("TextChatCommands") or TextChatService
	local cmd = Instance.new("TextChatCommand")
	cmd.Name = "TimeCommand"
	cmd.PrimaryAlias = "/time"
	cmd.Parent = folder
	cmd.Triggered:Connect(function(source: TextSource, text: string)
		local p = Players:GetPlayerByUserId(source.UserId)
		if p then run(p, text) end
	end)
end
