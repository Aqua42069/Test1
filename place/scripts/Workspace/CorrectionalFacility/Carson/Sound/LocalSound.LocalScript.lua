-- Saved by UniversalSynSaveInstance (Join to Copy Games) https://discord.gg/wx4ThpAsmw

-- https://lua.expert/
local v1 = script.Parent.Parent
local Head = v1:WaitForChild("Head")
local v2 = nil
local t = {}

while not v2 do
	for k, v in pairs(v1:GetChildren()) do
		if v:IsA("Humanoid") then
			v2 = v

			break
		end
	end

	v1.ChildAdded:wait()
end

t[0] = Head:WaitForChild("Died")
t[1] = Head:WaitForChild("Running")
t[2] = Head:WaitForChild("Swimming")
t[3] = Head:WaitForChild("Climbing")
t[4] = Head:WaitForChild("Jumping")
t[5] = Head:WaitForChild("GettingUp")
t[6] = Head:WaitForChild("FreeFalling")
t[8] = Head:WaitForChild("Landing")
t[9] = Head:WaitForChild("Splash")

local t2 = {
	YForLineGivenXAndTwoPts = function(p1, p2, p3, p4, p5) --[[ YForLineGivenXAndTwoPts | Line: 60 ]]
		local v1 = (p3 - p5) / (p2 - p4)

		return v1 * p1 + (p3 - v1 * p2)
	end,
	Clamp = function(p1, p2, p3) --[[ Clamp | Line: 69 ]]
		return math.min(p3, (math.max(p2, p1)))
	end,
	HorizontalSpeed = function(p1) --[[ HorizontalSpeed | Line: 74 ]]
		return (p1.Velocity + Vector3.new(0, -p1.Velocity.Y, 0)).magnitude
	end,
	VerticalSpeed = function(p1) --[[ VerticalSpeed | Line: 80 ]]
		return math.abs(p1.Velocity.Y)
	end,
	Play = function(p1) --[[ Play | Line: 86 ]]
		if p1.TimePosition ~= 0 then
			p1.TimePosition = 0
		end

		if p1.IsPlaying then
			return
		end

		p1.Playing = true
	end,
	Pause = function(p1) --[[ Pause | Line: 94 ]]
		if not p1.IsPlaying then
			return
		end

		p1.Playing = false
	end,
	Resume = function(p1) --[[ Resume | Line: 99 ]]
		if p1.IsPlaying then
			return
		end

		p1.Playing = true
	end,
	Stop = function(p1) --[[ Stop | Line: 104 ]]
		if p1.IsPlaying then
			p1.Playing = false
		end

		if p1.TimePosition == 0 then
			return
		end

		p1.TimePosition = 0
	end
}
local t3 = {}
local v3 = nil

function setSoundInPlayingLoopedSounds(p1) --[[ setSoundInPlayingLoopedSounds | Line: 122 | Upvalues: t3 (copy) ]]
	for i = 1, #t3 do
		if t3[i] == p1 then
			return
		end
	end

	table.insert(t3, p1)
end
function stopPlayingLoopedSoundsExcept(p1) --[[ stopPlayingLoopedSoundsExcept | Line: 132 | Upvalues: t3 (copy), t2 (ref) ]]
	for i = #t3, 1, -1 do
		if t3[i] ~= p1 then
			t2.Pause(t3[i])
			table.remove(t3, i)
		end
	end
end

local t4 = {
	[Enum.HumanoidStateType.Dead] = function() --[[ Line: 143 | Upvalues: t (copy), t2 (ref) ]]
		stopPlayingLoopedSoundsExcept()
		t2.Play(t[0])
	end,
	[Enum.HumanoidStateType.RunningNoPhysics] = function() --[[ Line: 149 ]]
		stateUpdated(Enum.HumanoidStateType.Running)
	end,
	[Enum.HumanoidStateType.Running] = function() --[[ Line: 153 | Upvalues: t (copy), t2 (ref), Head (ref) ]]
		local v1 = t[1]

		stopPlayingLoopedSoundsExcept(v1)

		if t2.HorizontalSpeed(Head) > 0.5 then
			t2.Resume(v1)
			setSoundInPlayingLoopedSounds(v1)
		else
			stopPlayingLoopedSoundsExcept()
		end
	end,
	[Enum.HumanoidStateType.Swimming] = function() --[[ Line: 165 | Upvalues: v3 (ref), t2 (ref), Head (ref), t (copy) ]]
		local v1

		if v3 ~= Enum.HumanoidStateType.Swimming and t2.VerticalSpeed(Head) > 0.1 then
			local v2 = t[9]

			v2.Volume = t2.Clamp(t2.YForLineGivenXAndTwoPts(t2.VerticalSpeed(Head), 100, 0.28, 350, 1), 0, 1)
			t2.Play(v2)
		end

		v1 = t[2]
		stopPlayingLoopedSoundsExcept(v1)
		t2.Resume(v1)
		setSoundInPlayingLoopedSounds(v1)
	end,
	[Enum.HumanoidStateType.Climbing] = function() --[[ Line: 185 | Upvalues: t (copy), t2 (ref), Head (ref) ]]
		local v1 = t[3]

		if t2.VerticalSpeed(Head) > 0.1 then
			t2.Resume(v1)
			stopPlayingLoopedSoundsExcept(v1)
		else
			stopPlayingLoopedSoundsExcept()
		end

		setSoundInPlayingLoopedSounds(v1)
	end,
	[Enum.HumanoidStateType.Jumping] = function() --[[ Line: 196 | Upvalues: v3 (ref), t (copy), t2 (ref) ]]
		if v3 ~= Enum.HumanoidStateType.Jumping then
			stopPlayingLoopedSoundsExcept()
			t2.Play(t[4])
		end
	end,
	[Enum.HumanoidStateType.GettingUp] = function() --[[ Line: 205 | Upvalues: t (copy), t2 (ref) ]]
		stopPlayingLoopedSoundsExcept()
		t2.Play(t[5])
	end,
	[Enum.HumanoidStateType.Freefall] = function() --[[ Line: 211 | Upvalues: v3 (ref), t (copy) ]]
		if v3 ~= Enum.HumanoidStateType.Freefall then
			t[6].Volume = 0
			stopPlayingLoopedSoundsExcept()
		end
	end,
	[Enum.HumanoidStateType.FallingDown] = function() --[[ Line: 220 ]]
		stopPlayingLoopedSoundsExcept()
	end,
	[Enum.HumanoidStateType.Landed] = function() --[[ Line: 224 | Upvalues: t2 (ref), Head (ref), t (copy) ]]
		stopPlayingLoopedSoundsExcept()

		if not (t2.VerticalSpeed(Head) > 75) then
			return
		end

		local v1 = t[8]

		v1.Volume = t2.Clamp(t2.YForLineGivenXAndTwoPts(t2.VerticalSpeed(Head), 50, 0, 100, 1), 0, 1)
		t2.Play(v1)
	end,
	[Enum.HumanoidStateType.Seated] = function() --[[ Line: 238 ]]
		stopPlayingLoopedSoundsExcept()
	end
}

function stateUpdated(p1) --[[ stateUpdated | Line: 244 | Upvalues: t4 (copy), v3 (ref) ]]
	if t4[p1] ~= nil then
		t4[p1]()
	end

	v3 = p1
end
v2.Died:connect(function() --[[ Line: 251 ]]
	stateUpdated(Enum.HumanoidStateType.Dead)
end)
v2.Running:connect(function() --[[ Line: 252 ]]
	stateUpdated(Enum.HumanoidStateType.Running)
end)
v2.Swimming:connect(function() --[[ Line: 253 ]]
	stateUpdated(Enum.HumanoidStateType.Swimming)
end)
v2.Climbing:connect(function() --[[ Line: 254 ]]
	stateUpdated(Enum.HumanoidStateType.Climbing)
end)
v2.Jumping:connect(function() --[[ Line: 255 ]]
	stateUpdated(Enum.HumanoidStateType.Jumping)
end)
v2.GettingUp:connect(function() --[[ Line: 256 ]]
	stateUpdated(Enum.HumanoidStateType.GettingUp)
end)
v2.FreeFalling:connect(function() --[[ Line: 257 ]]
	stateUpdated(Enum.HumanoidStateType.Freefall)
end)
v2.FallingDown:connect(function() --[[ Line: 258 ]]
	stateUpdated(Enum.HumanoidStateType.FallingDown)
end)
v2.StateChanged:connect(function(p1, p2) --[[ Line: 261 ]]
	stateUpdated(p2)
end)
function onUpdate(p1, p2) --[[ onUpdate | Line: 266 | Upvalues: t (copy), v3 (ref), Head (ref), t2 (ref) ]]
	local v1 = p1 / p2
	local v2 = t[6]

	if v3 == Enum.HumanoidStateType.Freefall then
		if Head.Velocity.Y < 0 and t2.VerticalSpeed(Head) > 75 then
			t2.Resume(v2)
			v2.Volume = t2.Clamp(v2.Volume + p2 / 1.1 * v1, 0, 1)
		else
			v2.Volume = 0
		end
	else
		t2.Pause(v2)
	end

	if v3 ~= Enum.HumanoidStateType.Running or not (t2.HorizontalSpeed(Head) < 0.5) then
		return
	end

	t2.Pause(t[1])
end

local v4 = tick()

while true do
	onUpdate(tick() - v4, 0.25)

	local v5 = tick()

	wait(0.25)
	v4 = v5
end