--[[
	CityLife.Recognition (v261) - "Hey... don't I know you?" (spec 10.2)

	Every officer who can see someone with an active warrant (or the subject of a BOLO)
	builds a recognition meter for them:
	  faster   up close, in daylight, the longer they look, the more famous you are (the news)
	  slower   at night, at distance, moving fast, in a crowd, in a disguise (different clothes
	           from the booking photo / warrant, a hat, a mask)
	The subject sees a "?" filling above that officer (only they see it). Halfway the officer
	says "Hey... don't I know you?"; full = identified -> the warrant is served (Warrants.identify).
	Police PLAYERS get the same meter on the people they look at, and the ID when it fills.
	Civilians and shopkeepers phone in tips (a radio call with a place, no stars).
	Logs: [Recog]
]]

local Players = game:GetService("Players")

local R = {}
local Core: any

local CFG = {
	Tick = 0.4,
	Range = 95,
	BaseRate = 0.42, -- meter per second at 10 studs, noon, standing still, no disguise
	Decay = 0.12,
	Hey = 0.5,
	TipEvery = 25, -- seconds between tip rolls per person
	TipChance = 0.05,
}

local meters: { [Player]: { [Instance]: number } } = {}
local heyed: { [Player]: { [Instance]: boolean } } = {}
local lastTip: { [Player]: number } = {}

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true

local function headOf(m: Instance): BasePart?
	local h = m:FindFirstChild("Head")
	return if h and h:IsA("BasePart") then h else nil
end

local function canSee(eye: BasePart, target: Model): boolean
	local th = headOf(target)
	if not th then return false end
	params.FilterDescendantsInstances = { eye.Parent :: Instance, target }
	local dir = th.Position - eye.Position
	local hit = workspace:Raycast(eye.Position, dir, params)
	if not hit then return true end
	-- glass and see-through parts don't block
	local p = hit.Instance
	return p.Transparency > 0.6 or p.Material == Enum.Material.Glass
end

-- 1 = looks like the photo on file; lower = disguised
function R.disguise(player: Player): number
	local p = Core.Profile.peek(player)
	local look = p and p.look
	local c = player.Character
	if not c then return 1 end
	local f = 1
	local now = Core.Warrants.lookOf(player)
	if look and now then
		if look.shirt ~= now.shirt and look.torso ~= now.torso then f *= 0.7 end
		if look.pants ~= now.pants then f *= 0.85 end
	end
	for _, a in c:GetChildren() do
		if a:IsA("Accessory") then
			local n = string.lower(a.Name)
			if n:find("mask") or n:find("balaclava") or n:find("ski") then f *= 0.35
			elseif (n:find("hat") or n:find("cap") or n:find("hood") or n:find("glasses") or n:find("shades")) and look and not table.find(look.acc, a.Name) then f *= 0.75 end
		end
	end
	return math.max(0.15, f)
end

local function fame(player: Player): number
	local p = Core.Profile.peek(player)
	local f = p and p.news and tonumber(p.news.fame) or 0
	return math.clamp(1 + f * 0.08, 1, 1.8)
end

local function crowd(pos: Vector3, self: Model): number
	local n = 0
	local op = OverlapParams.new()
	op.FilterType = Enum.FilterType.Exclude
	op.FilterDescendantsInstances = { self }
	local seen = {}
	for _, part in workspace:GetPartBoundsInRadius(pos, 14, op) do
		local m = part.Parent
		if m and not seen[m] and m:FindFirstChildOfClass("Humanoid") and part.Name == "HumanoidRootPart" then
			seen[m] = true
			n += 1
		end
	end
	return 1 / (1 + 0.25 * n)
end

-- is this person someone police are looking for (without a pursuit already on)?
local function wantedQuietly(player: Player): (boolean, string?)
	if Core.stars(player) > 0 or Core.inCustody(player) or not Core.alive(player) then return false end
	if Core.Warrants.active(player) then return true, "warrant" end
	if Core.Warrants.boloFor(player) then return true, "bolo" end
	return false
end

local function rateFor(observerEye: BasePart, observerRoot: BasePart, target: Model, player: Player): number
	local th = headOf(target)
	local troot = target:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not th or not troot then return 0 end
	local d = (th.Position - observerEye.Position).Magnitude
	if d > CFG.Range then return 0 end
	-- field of view: officers look where they face
	local look = observerRoot.CFrame.LookVector
	local dir = (th.Position - observerEye.Position).Unit
	if look:Dot(dir) < 0.15 then return 0 end
	if not canSee(observerEye, target) then return 0 end
	local distF = math.clamp((CFG.Range - d) / (CFG.Range - 10), 0, 1) ^ 1.6
	local light = 0.35 + 0.65 * Core.daylight()
	local speed = troot.AssemblyLinearVelocity.Magnitude
	local speedF = if speed > 40 then 0.25 elseif speed > 18 then 0.55 else 1
	return CFG.BaseRate * distF * light * speedF * crowd(troot.Position, target) * R.disguise(player) * fame(player)
end

local function bubble(model: Instance, text: string)
	local head = headOf(model)
	if head then Core.fireAll("bubble", head, text) end
end

local function step(dt: number)
	local cops = Core.aiCops()
	local lawPlayers = {}
	for _, p in Players:GetPlayers() do
		if Core.isLaw(p) and p.Character and Core.alive(p) then table.insert(lawPlayers, p) end
	end
	for _, player in Players:GetPlayers() do
		local want, why = wantedQuietly(player)
		local m = meters[player]
		if not want then
			if m then
				meters[player] = nil
				heyed[player] = nil
				Core.fire(player, "recog", nil)
			end
			continue
		end
		local char = player.Character :: Model
		local troot = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not troot then continue end
		m = m or {}
		meters[player] = m
		heyed[player] = heyed[player] or {}
		local seenNow = {}
		local function observe(observer: Model, isPlayer: Player?)
			local root = observer:FindFirstChild("HumanoidRootPart") :: BasePart?
			local eye = headOf(observer)
			if not root or not eye then return end
			if (root.Position - troot.Position).Magnitude > CFG.Range then return end
			local rate = rateFor(eye, root, char, player)
			if rate <= 0 then return end
			seenNow[observer] = true
			local v = math.min(1, (m[observer] or 0) + rate * dt)
			m[observer] = v
			if v >= CFG.Hey and not heyed[player][observer] then
				heyed[player][observer] = true
				if isPlayer then
					Core.UI.notice(isPlayer, ("That face looks familiar... (%s)"):format((player:GetAttribute("CharacterName") or player.DisplayName)), 3)
				else
					bubble(observer, "Hey... don't I know you?")
				end
			end
			if v >= 1 then
				m[observer] = 0
				local who = if isPlayer then isPlayer.Name else (observer:GetAttribute("PoliceUnit") or "Officer")
				if why == "warrant" then
					Core.Warrants.identify(player, if isPlayer then "Officer" else "Patrol", who)
				else
					-- a BOLO subject without a warrant: a stop (1 star) and the BOLO on the radio
					local b = Core.Warrants.boloFor(player)
					Core.radio(("%s spotted the BOLO subject %s near %s"):format(who, player.Name, Core.placeName(troot.Position)), troot.Position, "BOLO subject")
					if Core.stars(player) < 1 then Core.report(player, "BOLOStop", troot.Position, 10) end
					if b then b.expires = os.time() end
				end
				if isPlayer then
					Core.UI.notice(isPlayer, ("IDENTIFIED: %s - %s"):format(player.Name, if why == "warrant" then (Core.Warrants.text(player) or "warrant") else "BOLO subject"), 6, Color3.fromRGB(20, 60, 120))
				end
			end
		end
		for _, cop in cops do observe(cop, nil) end
		for _, lp in lawPlayers do
			if lp ~= player and lp.Character then observe(lp.Character, lp) end
		end
		-- not seen this tick: fade
		local show = {}
		for obs, v in m do
			if not seenNow[obs] then
				v -= CFG.Decay * dt
				if v <= 0 or not obs.Parent then m[obs] = nil; heyed[player][obs] = nil; continue end
				m[obs] = v
			end
			if v > 0.04 then table.insert(show, { obs, v }) end
		end
		Core.fire(player, "recog", show)
		-- police players see the meter they're building on the people they look at
		for _, lp in lawPlayers do
			local v = m[lp.Character]
			if v and v > 0.04 then Core.fire(lp, "recogOn", char, v) end
		end

		-- civilian / shopkeeper tips
		local now = os.clock()
		if not lastTip[player] or now - lastTip[player] > CFG.TipEvery then
			lastTip[player] = now
			local nearby = 0
			local op = OverlapParams.new()
			op.FilterType = Enum.FilterType.Exclude
			op.FilterDescendantsInstances = { char }
			local seen = {}
			for _, part in workspace:GetPartBoundsInRadius(troot.Position, 45, op) do
				local mm = part.Parent
				if mm and not seen[mm] and part.Name == "HumanoidRootPart" and not Players:GetPlayerFromCharacter(mm) then
					local tagged = game:GetService("CollectionService"):HasTag(mm, "Police")
					if not tagged and mm:FindFirstChildOfClass("Humanoid") then nearby += 1 end
					seen[mm] = true
				end
			end
			local chance = CFG.TipChance * math.min(nearby, 4) * Core.daylight() * R.disguise(player) * fame(player)
			if nearby > 0 and math.random() < chance then
				local w = Core.Warrants.active(player)
				Core.radio(("Caller reports someone matching %s's description near %s (%s)"):format(player.Name, Core.placeName(troot.Position),
					if w then "warrant: " .. w.reason else "BOLO"), troot.Position, "Tip: " .. player.Name)
				Core.log("Recog", "TIP %s near %s (%d witnesses)", player.Name, Core.placeName(troot.Position), nearby)
				Core.emit("tip", player, troot.Position)
			end
		end
	end
end

function R.init(core: any)
	Core = core
	Players.PlayerRemoving:Connect(function(p) meters[p] = nil; heyed[p] = nil; lastTip[p] = nil end)
	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(CFG.Tick)
			local now = os.clock()
			local ok, err = pcall(step, now - last)
			last = now
			if not ok then warn("[Recog] " .. tostring(err)) end
		end
	end)
	Core.Recognition = R
	print("[Recog] v261 ready (recognition meters, disguises, tips)")
end

return R
