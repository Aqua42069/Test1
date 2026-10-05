--[[
	PoliceAI · Voice
	Officer commands ("Police! Hands up!", "Drop the weapon!", "Get out of the vehicle!").
	Shown as a speech line over the officer's head (a BillboardGui, visible to everyone
	nearby) and, for the important ones, as a banner on the suspect's screen through the
	existing PoliceAIRemotes.Announce remote. Rate-limited per officer and per incident.
]]

local Voice = {}
local Ctx, Tuning, State

function Voice.bind(ctx)
	Ctx = ctx
	Tuning, State = ctx.Tuning, ctx.State
end

local function bubble(cop: any): TextLabel?
	local head = cop.head
	if not head or not head.Parent then
		return nil
	end
	local gui = cop.voiceGui
	if not gui or not gui.Parent then
		gui = Instance.new("BillboardGui")
		gui.Name = "PoliceVoice"
		gui.Size = UDim2.fromOffset(230, 38)
		gui.StudsOffset = Vector3.new(0, 2.7, 0)
		gui.MaxDistance = Tuning.Voice.MaxDistance
		gui.LightInfluence = 0
		gui.Enabled = false
		local label = Instance.new("TextLabel")
		label.Name = "Line"
		label.BackgroundTransparency = 0.35
		label.BackgroundColor3 = Color3.fromRGB(12, 16, 30)
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = label
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = label
		gui.Parent = head
		cop.voiceGui = gui
	end
	return gui:FindFirstChild("Line") :: TextLabel?
end

-- opts: { announce = bool, style = string, command = bool (counts as a compliance command), force = bool }
function Voice.say(cop: any, text: string, inc: any?, opts: any?): boolean
	local o = opts or {}
	local now = os.clock()
	local V = Tuning.Voice
	if not o.force then
		if cop.voiceAt and now - cop.voiceAt < V.OfficerGap then
			return false
		end
		if inc and inc.voiceAt and now - inc.voiceAt < V.IncidentGap then
			return false
		end
	end
	cop.voiceAt = now
	if inc then
		inc.voiceAt = now
		if o.command ~= false then
			inc.lastCommandAt = now
			inc.firstCommandAt = inc.firstCommandAt or now
			inc.lastCommand = text
		end
	end
	local label = bubble(cop)
	if label then
		label.Text = text
		local gui = label.Parent :: BillboardGui
		gui.Enabled = true
		local token = (cop.voiceToken or 0) + 1
		cop.voiceToken = token
		task.delay(V.ShowTime, function()
			if cop.voiceToken == token and gui.Parent then
				gui.Enabled = false
			end
		end)
	end
	if o.announce and inc and inc.player and inc.player.Parent then
		if not inc.announceAt or now - inc.announceAt >= V.AnnounceGap or o.force then
			inc.announceAt = now
			State.announce(inc.player, "POLICE: " .. string.upper(text), o.style or "warn")
		end
	end
	return true
end

-- The right thing to shout given what the police know right now.
function Voice.commandFor(inc: any, cop: any, stopped: boolean?): (string?, string?)
	local t = inc.threat
	local k = inc.knowledge
	local comp = inc.compliance
	if comp == "Critical" then
		return "Suspect down! Get EMS here!", "info"
	elseif comp == "Controlled" then
		return "Don't resist! You're under arrest!", "info"
	elseif comp == "Complying" then
		return "Stay still! Keep your hands where I can see them!", "info"
	end
	if k.inVehicle then
		if stopped then
			if t.armed then
				return "Drop the weapon and get out of the vehicle!", "danger"
			end
			return "Police! Get out of the vehicle!", "danger"
		end
		return "Pull over! Stop the vehicle!", "warn"
	end
	if t.armed then
		return "Police! Drop the weapon!", "danger"
	end
	if t.fleeing then
		return "Stop! Police!", "warn"
	end
	if (cop.voiceCount or 0) % 2 == 0 then
		return "Police! Hands up!", "warn"
	end
	return "Don't move!", "warn"
end

return Voice
