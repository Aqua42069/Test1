--[[
	CityLife.Jury (v270) - jury tampering (spec 13.1)

	A case headed for trial has a panel of 12 jurors. Each one lives in one of the city's
	houses, has a family member at home, and hidden traits: greedy, scared, brave, honest, loyal.
	GET THE LIST FIRST: it's sealed - pay a clerk through the fixer (Connections).
	THE EASY WAY: pay them through the fixer (safer) or knock on their door yourself (riskier).
	  Greedy take it, honest ones report it. More money and middlemen = better odds.
	THE HARD WAY (at their house):
	  intimidate   scared jurors fold, brave ones report
	  blackmail    the PI's dirt (Connections) - quiet and effective
	  kidnap       grab the family member and hold them at your safehouse (your house) for the
	               whole trial; the juror is told how to vote. Someone must stay near the
	               hostage - leave them alone too long and they escape: kidnapping charges,
	               SWAT, the news.
	OUTCOMES at the trial: a reached juror votes not guilty (or holds out - a hung jury); one
	who REPORTED it ends the trial in a mistrial with tampering charges (Court).
	High-profile cases are sequestered: no house visits, the fixer charges triple at half odds.
	Logs: [Jury]
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local J = {}
local Core: any

local CFG = {
	FixerPrice = 50000,
	OwnBribe = 25000,
	VisitRange = 70,
	GuardRange = 90,
	Unguarded = 90,
	TraitOdds = { -- pay, threaten, blackmail
		greedy = { 0.9, 0.5, 0.85 },
		scared = { 0.55, 0.9, 0.9 },
		brave = { 0.25, 0.1, 0.55 },
		honest = { 0.08, 0.35, 0.75 },
		loyal = { 0.45, 0.45, 0.8 },
	},
	ReportOnFail = { greedy = 0.15, scared = 0.3, brave = 0.85, honest = 0.9, loyal = 0.4 },
}
local TRAITS = { "greedy", "scared", "brave", "honest", "loyal" }

local panels: { [number]: any } = {} -- by defendant userId
local spawned: { [string]: Model } = {}
local hostages: { [number]: any } = {}

local function houses(): { Model }
	local out = {}
	local h = workspace:FindFirstChild("Houses")
	if h then
		for _, m in h:GetChildren() do
			if m:IsA("Model") then table.insert(out, m) end
		end
	end
	return out
end

function J.panel(player: Player): any
	local p = panels[player.UserId]
	if p then return p end
	local hs = houses()
	local prof = Core.Profile.peek(player)
	local fame = prof and prof.news and prof.news.fame or 0
	p = { jurors = {}, revealed = false, sequestered = fame >= 8 }
	for i = 1, 12 do
		local house = if #hs > 0 then hs[math.random(1, #hs)] else nil
		table.insert(p.jurors, {
			name = Core.fakeName(),
			family = Core.fakeName():match("^(%S+)") .. " (family)",
			house = house and house.Name or "an apartment downtown",
			houseModel = house,
			trait = TRAITS[math.random(1, #TRAITS)],
		})
	end
	panels[player.UserId] = p
	Core.log("Jury", "panel drawn for %s%s", player.Name, if p.sequestered then " (SEQUESTERED)" else "")
	return p
end
function J.known(player: Player): boolean
	local p = panels[player.UserId]
	return p ~= nil and p.revealed
end
function J.reveal(player: Player)
	J.panel(player).revealed = true
end
function J.dirt(player: Player, index: number?): (boolean, string)
	local p = panels[player.UserId]
	local j = p and index and p.jurors[index]
	if not j then return false, "Pick a juror from your list" end
	j.dirt = true
	return true, ("The PI found something %s would pay a lot to keep quiet."):format(j.name)
end

local function result(player: Player, j: any, ok: boolean, how: string, yourself: boolean)
	if ok then
		j.vote = if math.random() < 0.8 then "ng" else "hold"
		Core.log("Jury", "%s reached juror %s (%s, %s) -> %s", player.Name, j.name, j.trait, how, j.vote)
		return true, ("%s: \"...Fine. I'll see it your way.\""):format(j.name)
	end
	j.approached = true
	if math.random() < (CFG.ReportOnFail[j.trait] or 0.5) then
		j.reported = true
		Core.log("Jury", "juror %s REPORTED %s's approach (%s)", j.name, player.Name, how)
		if yourself then
			Core.Warrants.issue(player, { reason = "Jury tampering" .. (if how == "threat" then " (intimidation)" else ""), crimes = { "JuryTampering" }, severity = 2, source = "a juror" })
		elseif Core.Connections.risky(player, 0.5, CFG.FixerPrice, "fixers") then
			Core.Connections.caught(player, "JuryTampering", "Jury tampering (the fixer flipped)", "fixers")
		end
		return false, ("%s slams the door. They'll tell the judge."):format(j.name)
	end
	return false, ("%s won't do it - but keeps quiet about it."):format(j.name)
end

-- by phone, through the fixer
function J.payFixer(player: Player, index: number): (boolean, string)
	local p = panels[player.UserId]
	local j = p and p.jurors[index]
	if not j or not p.revealed then return false, "Get the list first" end
	if j.vote then return false, "Already taken care of" end
	local price = CFG.FixerPrice * (if p.sequestered then 3 else 1)
	if not Core.charge(player, price) then return false, ("Sal needs %s"):format(Core.UI.money(price)) end
	local odds = CFG.TraitOdds[j.trait][1] * (if p.sequestered then 0.5 else 1)
	return result(player, j, math.random() < odds, "fixer", false)
end

---------------------------------------------------------------------------
-- at the house
---------------------------------------------------------------------------
local function doorOf(house: Model): CFrame
	local cf, size = house:GetBoundingBox()
	-- the front: the side nearest the road
	local best, bd = cf.Position + cf.LookVector * (size.Z / 2 + 4), math.huge
	local rn = workspace:FindFirstChild("RoadNetwork")
	if rn then
		for _, dir in { cf.LookVector, -cf.LookVector, cf.RightVector, -cf.RightVector } do
			local ext = if math.abs(dir:Dot(cf.LookVector)) > 0.5 then size.Z / 2 else size.X / 2
			local p = cf.Position + dir * (ext + 4)
			for _, road in rn:GetChildren() do
				for _, n in road:GetChildren() do
					if n:IsA("BasePart") then
						local d = (n.Position - p).Magnitude
						if d < bd then best, bd = p, d end
					end
				end
			end
		end
	end
	local ground = workspace:Raycast(best + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0))
	local at = if ground then ground.Position + Vector3.new(0, 3, 0) else best
	return CFrame.lookAt(at, Vector3.new(cf.Position.X, at.Y, cf.Position.Z))
end

local function npc(name: string, at: CFrame, shirt: Color3): Model?
	local ok, m = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		local skin = ({ Color3.fromRGB(234, 184, 146), Color3.fromRGB(161, 108, 72), Color3.fromRGB(105, 64, 40) })[math.random(1, 3)]
		desc.HeadColor, desc.LeftArmColor, desc.RightArmColor, desc.LeftLegColor, desc.RightLegColor = skin, skin, skin, skin, skin
		desc.TorsoColor = shirt
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not m then return nil end
	m.Name = name
	m:PivotTo(at)
	local hum = m:FindFirstChildOfClass("Humanoid")
	if hum then hum.DisplayName = name end
	m.Parent = workspace:FindFirstChild("CityLifeIncidents") or workspace
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then pcall(function() root:SetNetworkOwner(nil) end) end
	return m
end

local function talk(player: Player, j: any)
	local p = panels[player.UserId]
	if not p or j.vote or j.reported then
		Core.UI.notice(player, j.name .. " won't open the door", 3)
		return
	end
	local opts = { ("Offer cash (%s)"):format(Core.UI.money(CFG.OwnBribe)), "Threaten them", "Blackmail (the PI's dirt)", "Leave" }
	local pick = Core.UI.ask(player, { title = j.name, body = ("Juror on your case. Lives at %s."):format(j.house), options = opts, timeout = 30 })
	local okR, msg
	if pick == 1 then
		if not Core.charge(player, CFG.OwnBribe) then Core.UI.notice(player, "You don't have the cash", 3) return end
		okR, msg = result(player, j, math.random() < CFG.TraitOdds[j.trait][1] * 0.9, "cash", true)
	elseif pick == 2 then
		okR, msg = result(player, j, math.random() < CFG.TraitOdds[j.trait][2], "threat", true)
	elseif pick == 3 then
		if not j.dirt then Core.UI.notice(player, "You have nothing on them (Connections > PI)", 4) return end
		okR, msg = result(player, j, math.random() < CFG.TraitOdds[j.trait][3], "blackmail", true)
	else
		return
	end
	Core.UI.notice(player, msg, 6, if okR then Color3.fromRGB(20, 90, 40) else Color3.fromRGB(120, 20, 20))
end

-- grab the family member: they follow you to the safehouse
local function grab(player: Player, j: any, model: Model)
	local p = panels[player.UserId]
	if not p or hostages[player.UserId] then return end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root then return end
	local r = Core.root(player)
	if r and Core.Plates.copWatching(r.Position, 60) then Core.report(player, "Kidnapping", r.Position) end
	Core.log("Jury", "%s GRABBED %s (juror %s's family)", player.Name, model.Name, j.name)
	local h = { juror = j, model = model, player = player, held = false, lastGuard = os.clock(), discovered = false }
	hostages[player.UserId] = h
	spawned[j.name .. "family"] = nil -- it's not a house NPC any more
	hum.WalkSpeed = 15
	local safe = nil
	local hf = ServerStorage:FindFirstChild("HouseOf")
	if hf and hf:IsA("BindableFunction") then
		local ok, house = pcall(hf.Invoke, hf, player)
		if ok and typeof(house) == "Instance" and house:IsA("Model") then safe = house:GetPivot().Position end
	end
	local sh = workspace:FindFirstChild("Safehouse", true)
	if not safe and sh and sh:IsA("BasePart") then safe = sh.Position end
	if not safe then
		Core.UI.notice(player, "You have nowhere to keep them - buy a house first (it's your safehouse)", 6)
	else
		Core.UI.waypoint(player, "safehouse", safe, "Safehouse")
		Core.UI.notice(player, "Get them to your safehouse - and someone has to stay near them for the whole trial", 7)
	end
	task.spawn(function()
		while hostages[player.UserId] == h and model.Parent and hum.Health > 0 do
			local pr = Core.root(player)
			if not h.held then
				if pr then hum:MoveTo(pr.Position - pr.CFrame.LookVector * 4) end
				if safe and root and (root.Position - safe).Magnitude < 30 then
					h.held = true
					hum.WalkSpeed = 0
					hum.Sit = true
					j.vote = "ng"
					j.hostage = true
					Core.UI.waypoint(player, "safehouse", nil)
					Core.UI.notice(player, ("%s is held. %s will vote the way they're told. Stay close."):format(model.Name, j.name), 7)
					Core.log("Jury", "hostage held at %s's safehouse", player.Name)
				end
			else
				-- guarded? (you within range)
				if pr and safe and (pr.Position - safe).Magnitude < CFG.GuardRange then h.lastGuard = os.clock() end
				if os.clock() - h.lastGuard > CFG.Unguarded then
					-- they get out
					Core.log("Jury", "hostage ESCAPED from %s's safehouse", player.Name)
					j.vote = nil
					j.reported = true
					hostages[player.UserId] = nil
					model:Destroy()
					Core.Warrants.issue(player, { reason = "Kidnapping and extortion", crimes = { "Kidnapping" }, severity = 3, source = "a hostage" })
					if safe then Core.policeFn("SpawnUnits", safe, "SWAT", 4, 120) end
					if Core.News then Core.News.post({ kind = "kidnap", level = 3, headline = "BREAKING: Juror's family member escapes kidnappers - SWAT raids safehouse",
						body = ("Police say the victim was held to influence the trial of %s."):format((player:GetAttribute("CharacterName") or player.DisplayName)), subjects = { player }, pos = safe, live = true }) end
					if Core.News and safe then Core.News.goLive({ headline = "SWAT RAID - hostage case", subject = player, pos = safe }) end
					if Core.Underground then Core.Underground.bump("fixers", 0.25, "kidnapping") end
					return
				end
			end
			task.wait(0.5)
		end
	end)
end

-- house NPCs appear when the defendant (who has the list) comes near
local function houseLoop()
	for userId, p in panels do
		local player = Players:GetPlayerByUserId(userId)
		if not (player and p.revealed and not p.sequestered) then continue end
		local r = Core.root(player)
		for _, j in p.jurors do
			if not j.houseModel or not j.houseModel.Parent then continue end
			local key = j.name
			local door = j.door or doorOf(j.houseModel)
			j.door = door
			local near = r and (r.Position - door.Position).Magnitude < CFG.VisitRange
			if near and not spawned[key] and not j.reported then
				local m = npc(j.name .. " (juror)", door, Color3.fromRGB(90, 90, 120))
				if m then
					spawned[key] = m
					local root = m:FindFirstChild("HumanoidRootPart") :: BasePart
					root.Anchored = true
					local pr = Instance.new("ProximityPrompt")
					pr.ActionText = "Talk to " .. j.name
					pr.ObjectText = "Juror"
					pr.MaxActivationDistance = 9
					pr.RequiresLineOfSight = false
					pr:SetAttribute("OwnerOnly", userId)
					pr.Parent = root
					pr.Triggered:Connect(function(who: Player)
						if who.UserId == userId then talk(who, j) end
					end)
				end
				if not j.hostage and not spawned[key .. "family"] then
					local f = npc(j.family, door * CFrame.new(5, 0, 2), Color3.fromRGB(180, 120, 160))
					if f then
						spawned[key .. "family"] = f
						local root = f:FindFirstChild("HumanoidRootPart") :: BasePart
						local pr = Instance.new("ProximityPrompt")
						pr.ActionText = "Grab"
						pr.ObjectText = j.family
						pr.HoldDuration = 2.5
						pr.MaxActivationDistance = 7
						pr.RequiresLineOfSight = false
						pr:SetAttribute("OwnerOnly", userId)
						pr.Parent = root
						pr.Triggered:Connect(function(who: Player)
							if who.UserId ~= userId then return end
							pr:Destroy()
							grab(who, j, f)
						end)
					end
				end
			elseif not near and spawned[key] then
				spawned[key]:Destroy()
				spawned[key] = nil
				local f = spawned[key .. "family"]
				if f then f:Destroy() spawned[key .. "family"] = nil end
			end
		end
	end
end

-- the court takes the panel (and the case is over after it)
function J.forCourt(player: Player, consultant: boolean): { any }
	local p = J.panel(player)
	local out = {}
	for i, j in p.jurors do
		table.insert(out, { name = j.name, vote = j.vote, reported = j.reported == true, lean = if consultant and i <= 3 then -0.2 else 0 })
	end
	return out
end

local function closeCase(player: Player)
	local p = panels[player.UserId]
	if not p then return end
	panels[player.UserId] = nil
	for _, j in p.jurors do
		for _, k in { j.name, j.name .. "family" } do
			if spawned[k] then spawned[k]:Destroy() spawned[k] = nil end
		end
	end
	local h = hostages[player.UserId]
	if h then
		hostages[player.UserId] = nil
		if h.model.Parent then h.model:Destroy() end
		-- released after the trial; sometimes it comes out later
		if math.random() < 0.3 then
			task.delay(math.random(60, 240), function()
				if not player.Parent then return end
				Core.Warrants.issue(player, { reason = "Kidnapping of a juror's family member", crimes = { "Kidnapping" }, severity = 3, source = "the victim" })
				if Core.News then Core.News.post({ kind = "tampering", level = 3, headline = "Juror's family says they were held hostage during trial",
					body = ("Investigators are re-examining the verdict in the case of %s."):format((player:GetAttribute("CharacterName") or player.DisplayName)), subjects = { player } }) end
			end)
		end
	end
end

---------------------------------------------------------------------------
function J.init(core: any)
	Core = core
	Core.Jury = J
	Core.on("court", function(player: Player, data: any)
		if type(data) == "table" and data.verdict == "bail" then return end -- v286v: same panel at the trial
		closeCase(player)
	end)
	-- the defendant's list in the phone (Connections > Jury)
	Core.app("jury.panel", function(player: Player)
		local p = panels[player.UserId]
		if not p or not p.revealed then return nil end
		local out = { sequestered = p.sequestered, jurors = {} }
		for i, j in p.jurors do
			table.insert(out.jurors, { i = i, name = j.name, house = j.house, done = j.vote ~= nil, reported = j.reported == true, dirt = j.dirt == true,
				hostage = j.hostage == true })
		end
		return out
	end)
	Core.app("jury.act", function(player: Player, index: any, action: any)
		local i = tonumber(index)
		local p = panels[player.UserId]
		local j = p and i and p.jurors[i]
		if not j or not p.revealed then return false, "Get the list first" end
		if action == "fixer" then
			return J.payFixer(player, i :: number)
		elseif action == "visit" then
			if p.sequestered then return false, "The jury is sequestered at a hotel - no visits" end
			if not j.houseModel then return false, "No address on file" end
			j.door = j.door or doorOf(j.houseModel)
			Core.UI.waypoint(player, "juror", j.door.Position, j.name .. "'s house")
			return true, "Marked " .. j.name .. "'s house on your screen"
		end
		return false, "?"
	end)
	Players.PlayerRemoving:Connect(function(p)
		local h = hostages[p.UserId]
		if h and h.model.Parent then h.model:Destroy() end
		hostages[p.UserId] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(houseLoop)
			if not ok then warn("[Jury] " .. tostring(err)) end
		end
	end)
	print("[Jury] v270 ready (jury lists, bribes, threats, blackmail, hostages)")
end

return J
