-- Saved by UniversalSynSaveInstance (Join to Copy Games) https://discord.gg/wx4ThpAsmw

-- https://lua.expert/
function waitForChild(p1, p2) --[[ waitForChild | Line: 1 ]]
	local v1 = p1:findFirstChild(p2)

	if v1 then
		return v1
	end

	local v2

	repeat
		v2 = p1.ChildAdded:wait()
	until v2.Name == p2

	return v2
end

local v1 = script.Parent
local v2 = waitForChild(v1, "Torso")
local v3 = waitForChild(v2, "Right Shoulder")
local v4 = waitForChild(v2, "Left Shoulder")
local v5 = waitForChild(v2, "Right Hip")
local v6 = waitForChild(v2, "Left Hip")

waitForChild(v2, "Neck")

local v7 = waitForChild(v1, "Humanoid")
local t = {}
local tbl = {
	idle = {
		{
			id = "http://www.roblox.com/asset/?id=180435571",
			weight = 9
		},
		{
			id = "http://www.roblox.com/asset/?id=180435792",
			weight = 1
		}
	},
	walk = {
		{
			id = "http://www.roblox.com/asset/?id=180426354",
			weight = 10
		}
	},
	run = {
		{
			id = "run.xml",
			weight = 10
		}
	},
	jump = {
		{
			id = "http://www.roblox.com/asset/?id=125750702",
			weight = 10
		}
	},
	fall = {
		{
			id = "http://www.roblox.com/asset/?id=180436148",
			weight = 10
		}
	},
	climb = {
		{
			id = "http://www.roblox.com/asset/?id=180436334",
			weight = 10
		}
	},
	sit = {
		{
			id = "http://www.roblox.com/asset/?id=178130996",
			weight = 10
		}
	},
	toolnone = {
		{
			id = "http://www.roblox.com/asset/?id=182393478",
			weight = 10
		}
	},
	toolslash = {
		{
			id = "http://www.roblox.com/asset/?id=129967390",
			weight = 10
		}
	},
	toollunge = {
		{
			id = "http://www.roblox.com/asset/?id=129967478",
			weight = 10
		}
	},
	wave = {
		{
			id = "http://www.roblox.com/asset/?id=128777973",
			weight = 10
		}
	},
	point = {
		{
			id = "http://www.roblox.com/asset/?id=128853357",
			weight = 10
		}
	},
	dance1 = {
		{
			id = "http://www.roblox.com/asset/?id=182435998",
			weight = 10
		},
		{
			id = "http://www.roblox.com/asset/?id=182491037",
			weight = 10
		},
		{
			id = "http://www.roblox.com/asset/?id=182491065",
			weight = 10
		}
	},
	dance2 = {
		{
			id = "http://www.roblox.com/asset/?id=182436842",
			weight = 10
		},
		{
			id = "http://www.roblox.com/asset/?id=182491248",
			weight = 10
		},
		{
			id = "http://www.roblox.com/asset/?id=182491277",
			weight = 10
		}
	},
	dance3 = {
		{
			id = "http://www.roblox.com/asset/?id=182436935",
			weight = 10
		},
		{
			id = "http://www.roblox.com/asset/?id=182491368",
			weight = 10
		},
		{
			id = "http://www.roblox.com/asset/?id=182491423",
			weight = 10
		}
	},
	laugh = {
		{
			id = "http://www.roblox.com/asset/?id=129423131",
			weight = 10
		}
	},
	cheer = {
		{
			id = "http://www.roblox.com/asset/?id=129423030",
			weight = 10
		}
	}
}

function configureAnimationSet(p1, p2) --[[ configureAnimationSet | Line: 92 | Upvalues: t (copy) ]]
	if t[p1] ~= nil then
		for k, v in pairs(t[p1].connections) do
			v:disconnect()
		end
	end

	t[p1] = {}
	t[p1].count = 0
	t[p1].totalWeight = 0
	t[p1].connections = {}

	local v1 = script:FindFirstChild(p1)

	if v1 ~= nil then
		table.insert(t[p1].connections, v1.ChildAdded:connect(function(p12) --[[ Line: 107 | Upvalues: p1 (copy), p2 (copy) ]]
			configureAnimationSet(p1, p2)
		end))
		table.insert(t[p1].connections, v1.ChildRemoved:connect(function(p12) --[[ Line: 108 | Upvalues: p1 (copy), p2 (copy) ]]
			configureAnimationSet(p1, p2)
		end))

		local count = 1

		for k, v in pairs(v1:GetChildren()) do
			if v:IsA("Animation") then
				table.insert(t[p1].connections, v.Changed:connect(function(p12) --[[ Line: 112 | Upvalues: p1 (copy), p2 (copy) ]]
					configureAnimationSet(p1, p2)
				end))
				t[p1][count] = {}
				t[p1][count].anim = v

				local Weight = v:FindFirstChild("Weight")

				if Weight == nil then
					t[p1][count].weight = 1
				else
					t[p1][count].weight = Weight.Value
				end

				t[p1].count = t[p1].count + 1
				t[p1].totalWeight = t[p1].totalWeight + t[p1][count].weight
				count = count + 1
			end
		end
	end

	if not (t[p1].count <= 0) then
		return
	end

	for k, v in pairs(p2) do
		t[p1][k] = {}
		t[p1][k].anim = Instance.new("Animation")
		t[p1][k].anim.Name = p1
		t[p1][k].anim.AnimationId = v.id
		t[p1][k].weight = v.weight
		t[p1].count = t[p1].count + 1
		t[p1].totalWeight = t[p1].totalWeight + v.weight
	end
end
function scriptChildModified(p1) --[[ scriptChildModified | Line: 145 | Upvalues: tbl (copy) ]]
	local v1 = tbl[p1.Name]

	if v1 == nil then
		return
	end

	configureAnimationSet(p1.Name, v1)
end
script.ChildAdded:connect(scriptChildModified)
script.ChildRemoved:connect(scriptChildModified)

local v8 = nil
local v9 = nil
local v10 = nil
local v11 = 1
local v12 = "Standing"
local v13 = ""
local t2 = {
	wave = false,
	point = false,
	dance1 = true,
	dance2 = true,
	dance3 = true,
	laugh = false,
	cheer = false
}
local t3 = { "dance1", "dance2", "dance3" }

for k, v in pairs(tbl) do
	configureAnimationSet(k, v)
end

local v14 = "None"
local v15 = 0
local v16 = 0

function stopAllAnimations() --[[ stopAllAnimations | Line: 175 | Upvalues: v13 (ref), t2 (copy), v8 (ref), v9 (ref), v10 (ref) ]]
	local v1 = v13

	if t2[v1] ~= nil and t2[v1] == false then
		v1 = "idle"
	end

	v13 = ""
	v8 = nil

	if v9 ~= nil then
		v9:disconnect()
	end

	if v10 == nil then
		return v1
	end

	v10:Stop()
	v10:Destroy()
	v10 = nil

	return v1
end
function setAnimationSpeed(p1) --[[ setAnimationSpeed | Line: 197 | Upvalues: v11 (ref), v10 (ref) ]]
	if p1 == v11 then
		return
	end

	v11 = p1
	v10:AdjustSpeed(p1)
end
function keyFrameReachedFunc(p1) --[[ keyFrameReachedFunc | Line: 204 | Upvalues: v13 (ref), t2 (copy), v11 (ref), v7 (copy) ]]
	if p1 ~= "End" then
		return
	end

	local v1 = v13

	if t2[v1] ~= nil and t2[v1] == false then
		v1 = "idle"
	end

	playAnimation(v1, 0, v7)
	setAnimationSpeed(v11)
end
function playAnimation(p1, p2, p3) --[[ playAnimation | Line: 220 | Upvalues: t (copy), v8 (ref), v10 (ref), v11 (ref), v13 (ref), v9 (ref) ]]
	local sum = math.random(1, t[p1].totalWeight)
	local count = 1

	while t[p1][count].weight < sum do
		sum = sum - t[p1][count].weight
		count = count + 1
	end

	local anim = t[p1][count].anim

	if anim == v8 then
		return
	end

	if v10 ~= nil then
		v10:Stop(p2)
		v10:Destroy()
	end

	v11 = 1
	v10 = p3:LoadAnimation(anim)
	v10:Play(p2)
	v13 = p1
	v8 = anim

	if v9 ~= nil then
		v9:disconnect()
	end

	v9 = v10.KeyframeReached:connect(keyFrameReachedFunc)
end

local v17 = ""
local v18 = nil
local v19 = nil
local v20 = nil

function toolKeyFrameReachedFunc(p1) --[[ toolKeyFrameReachedFunc | Line: 268 | Upvalues: v17 (ref), v7 (copy) ]]
	if p1 ~= "End" then
		return
	end

	playToolAnimation(v17, 0, v7)
end
function playToolAnimation(p1, p2, p3) --[[ playToolAnimation | Line: 276 | Upvalues: t (copy), v19 (ref), v18 (ref), v17 (ref), v20 (ref) ]]
	local sum = math.random(1, t[p1].totalWeight)
	local count = 1

	while t[p1][count].weight < sum do
		sum = sum - t[p1][count].weight
		count = count + 1
	end

	local anim = t[p1][count].anim

	if v19 == anim then
		return
	end

	if v18 ~= nil then
		v18:Stop()
		v18:Destroy()
		p2 = 0
	end

	v18 = p3:LoadAnimation(anim)
	v18:Play(p2)
	v17 = p1
	v19 = anim
	v20 = v18.KeyframeReached:connect(toolKeyFrameReachedFunc)
end
function stopToolAnimations() --[[ stopToolAnimations | Line: 308 | Upvalues: v17 (ref), v20 (ref), v19 (ref), v18 (ref) ]]
	local v1 = v17

	if v20 ~= nil then
		v20:disconnect()
	end

	v17 = ""
	v19 = nil

	if v18 == nil then
		return v1
	end

	v18:Stop()
	v18:Destroy()
	v18 = nil

	return v1
end
function onRunning(p1) --[[ onRunning | Line: 331 | Upvalues: v7 (copy), v8 (ref), v12 (ref), t2 (copy), v13 (ref) ]]
	if p1 > 0.01 then
		playAnimation("walk", 0.1, v7)

		if v8 and v8.AnimationId == "http://www.roblox.com/asset/?id=180426354" then
			setAnimationSpeed(p1 / 14.5)
		end

		v12 = "Running"
	else
		if t2[v13] ~= nil then
			return
		end

		playAnimation("idle", 0.1, v7)
		v12 = "Standing"
	end
end
function onDied() --[[ onDied | Line: 346 | Upvalues: v12 (ref) ]]
	v12 = "Dead"
end
function onJumping() --[[ onJumping | Line: 350 | Upvalues: v7 (copy), v16 (ref), v12 (ref) ]]
	playAnimation("jump", 0.1, v7)
	v16 = 0.3
	v12 = "Jumping"
end
function onClimbing(p1) --[[ onClimbing | Line: 356 | Upvalues: v7 (copy), v12 (ref) ]]
	playAnimation("climb", 0.1, v7)
	setAnimationSpeed(p1 / 12)
	v12 = "Climbing"
end
function onGettingUp() --[[ onGettingUp | Line: 362 | Upvalues: v12 (ref) ]]
	v12 = "GettingUp"
end
function onFreeFall() --[[ onFreeFall | Line: 366 | Upvalues: v16 (ref), v7 (copy), v12 (ref) ]]
	if not (v16 <= 0) then
		v12 = "FreeFall"

		return
	end

	playAnimation("fall", 0.3, v7)
	v12 = "FreeFall"
end
function onFallingDown() --[[ onFallingDown | Line: 373 | Upvalues: v12 (ref) ]]
	v12 = "FallingDown"
end
function onSeated() --[[ onSeated | Line: 377 | Upvalues: v12 (ref) ]]
	v12 = "Seated"
end
function onPlatformStanding() --[[ onPlatformStanding | Line: 381 | Upvalues: v12 (ref) ]]
	v12 = "PlatformStanding"
end
function onSwimming(p1) --[[ onSwimming | Line: 385 | Upvalues: v12 (ref) ]]
	v12 = if p1 > 0 then "Running" else "Standing"
end
function getTool() --[[ getTool | Line: 393 | Upvalues: v1 (copy) ]]
	for i, v in ipairs(v1:GetChildren()) do
		if v.className == "Tool" then
			return v
		end
	end

	return nil
end
function getToolAnim(p1) --[[ getToolAnim | Line: 400 ]]
	for i, v in ipairs(p1:GetChildren()) do
		if v.Name == "toolanim" and v.className == "StringValue" then
			return v
		end
	end

	return nil
end
function animateTool() --[[ animateTool | Line: 409 | Upvalues: v14 (ref), v7 (copy) ]]
	if v14 == "None" then
		playToolAnimation("toolnone", 0.1, v7)

		return
	end

	if v14 == "Slash" then
		playToolAnimation("toolslash", 0, v7)

		return
	end

	if v14 == "Lunge" then
		playToolAnimation("toollunge", 0, v7)
	end
end
function moveSit() --[[ moveSit | Line: 427 | Upvalues: v3 (copy), v4 (copy), v5 (copy), v6 (copy) ]]
	v3.MaxVelocity = 0.15
	v4.MaxVelocity = 0.15
	v3:SetDesiredAngle(1.57)
	v4:SetDesiredAngle(-1.57)
	v5:SetDesiredAngle(1.57)
	v6:SetDesiredAngle(-1.57)
end

local v21 = 0

function move(p1) --[[ move | Line: 438 | Upvalues: v21 (ref), v16 (ref), v12 (ref), v7 (copy), v3 (copy), v4 (copy), v5 (copy), v6 (copy), v14 (ref), v15 (ref), v19 (ref) ]]
	local v1 = 1
	local v2 = 1
	local v32 = p1 - v21

	v21 = p1

	local v42 = false

	if v16 > 0 then
		v16 = v16 - v32
	end

	if v12 == "FreeFall" and v16 <= 0 then
		playAnimation("fall", 0.3, v7)
	else
		if v12 == "Seated" then
			playAnimation("sit", 0.5, v7)

			return
		end

		if v12 == "Running" then
			playAnimation("walk", 0.1, v7)
		elseif v12 == "Dead" or (v12 == "GettingUp" or (v12 == "FallingDown" or (v12 == "Seated" or v12 == "PlatformStanding"))) then
			stopAllAnimations()
			v42 = true
			v2 = 1
			v1 = 0.1
		end
	end

	if v42 then
		desiredAngle = v1 * math.sin(p1 * v2)
		v3:SetDesiredAngle(desiredAngle + 0)
		v4:SetDesiredAngle(desiredAngle - 0)
		v5:SetDesiredAngle(-desiredAngle)
		v6:SetDesiredAngle(-desiredAngle)
	end

	local v52 = getTool()

	if not (v52 and v52:FindFirstChild("Handle")) then
		stopToolAnimations()
		v14 = "None"
		v19 = nil
		v15 = 0

		return
	end

	animStringValueObject = getToolAnim(v52)

	if animStringValueObject then
		v14 = animStringValueObject.Value
		animStringValueObject.Parent = nil
		v15 = p1 + 0.3
	end

	if not (v15 < p1) then
		animateTool()

		return
	end

	v15 = 0
	v14 = "None"
	animateTool()
end
v7.Died:connect(onDied)
v7.Running:connect(onRunning)
v7.Jumping:connect(onJumping)
v7.Climbing:connect(onClimbing)
v7.GettingUp:connect(onGettingUp)
v7.FreeFalling:connect(onFreeFall)
v7.FallingDown:connect(onFallingDown)
v7.Seated:connect(onSeated)
v7.PlatformStanding:connect(onPlatformStanding)
v7.Swimming:connect(onSwimming)
game.Players.LocalPlayer.Chatted:connect(function(p1) --[[ Line: 515 | Upvalues: t3 (copy), v12 (ref), t2 (copy), v7 (copy) ]]
	local v1 = ""

	if p1 == "/e dance" then
		v1 = t3[math.random(1, #t3)]
	elseif string.sub(p1, 1, 3) == "/e " then
		v1 = string.sub(p1, 4)
	elseif string.sub(p1, 1, 7) == "/emote " then
		v1 = string.sub(p1, 8)
	end

	if v12 ~= "Standing" or t2[v1] == nil then
		return
	end

	playAnimation(v1, 0.1, v7)
end)
game:service("RunService")
playAnimation("idle", 0.1, v7)

while v1.Parent ~= nil do
	local _2, v22 = wait(0.1)

	move(v22)
end