-- Resident traffic visuals run independently of player vehicle controls.
-- The server retains collisions, routing and the authoritative pose.
task.spawn(function()
 local Collection=game:GetService("CollectionService")
 local Run=game:GetService("RunService")
 local tracked,active={},{}
 local function remove(car)
  local entry=tracked[car]
  if entry then entry.connection:Disconnect();tracked[car]=nil;active[car]=nil end
 end
 local function add(car)
  if tracked[car] or not car:IsA("Model") then return end
  local pose=car:GetAttribute("TrafficPose")
  local entry={goal=pose or car:GetPivot(),shown=pose or car:GetPivot(),vel=Vector3.zero,at=os.clock()}
  -- v284: CityTraffic also sends the velocity: extrapolate between server updates
  entry.connection=car:GetAttributeChangedSignal("TrafficPose"):Connect(function()
   local nextPose=car:GetAttribute("TrafficPose")
   if typeof(nextPose)=="CFrame" then
    entry.goal=nextPose;entry.at=os.clock()
    local v=car:GetAttribute("TrafficVel");entry.vel=if typeof(v)=="Vector3" then v else Vector3.zero
   end
  end)
  tracked[car]=entry
 end
 Collection:GetInstanceAddedSignal("SmoothResidentTraffic"):Connect(add)
 Collection:GetInstanceRemovedSignal("SmoothResidentTraffic"):Connect(remove)
 for _,car in Collection:GetTagged("SmoothResidentTraffic") do add(car) end
 local refresh=0
 Run:BindToRenderStep("ResidentTrafficVisuals",Enum.RenderPriority.Camera.Value+1,function(dt)
  local camera=workspace.CurrentCamera
  if not camera then return end
  refresh-=dt
  if refresh<=0 then
   refresh=0.5
   local candidates={}
   for car,entry in tracked do
    if car:IsDescendantOf(workspace) and car:GetAttribute("TrafficActive")==true then
     local distance=(entry.goal.Position-camera.CFrame.Position).Magnitude
     if distance<500 then table.insert(candidates,{car=car,entry=entry,distance=distance}) end
    end
   end
   table.sort(candidates,function(a,b) return a.distance<b.distance end)
   local selected={}
   for i=1,math.min(60,#candidates) do
    local item=candidates[i];selected[item.car]=item.entry
    if not active[item.car] then item.entry.shown=item.entry.goal;item.entry.resting=false end
   end
   for car,entry in active do if not selected[car] and car.Parent then car:PivotTo(entry.goal) end end
   active=selected
  end
  local alpha=1-math.exp(-math.min(dt,0.1)/0.06)
  local clock=os.clock()
  for car,entry in active do
   if car.Parent and car:GetAttribute("TrafficActive")==true then
    if entry.resting and entry.restGoal==entry.goal and entry.vel.Magnitude<0.05 then continue end
    local ahead=entry.goal+entry.vel*math.min(clock-entry.at,0.15) -- v286i: short, so a braking car isn't drawn into you
    if (ahead.Position-entry.shown.Position).Magnitude>35 then entry.shown=ahead
    else entry.shown=entry.shown:Lerp(ahead,alpha) end
    entry.resting=(entry.goal.Position-entry.shown.Position).Magnitude<0.005 and entry.goal.LookVector:Dot(entry.shown.LookVector)>0.999999
    if entry.resting then entry.shown=entry.goal;entry.restGoal=entry.goal end
    car:PivotTo(entry.shown)
   end
  end
 end)
end)
-- v284e: crashes, seen from this machine (where the car's physics runs):
--   * impacts on my car and the physical cars near me -> ReplicatedStorage.CarImpact (dents etc.)
--   * a traffic car I'm about to hit -> ReplicatedStorage.TrafficWake (it becomes a real car
--     first, so I hit a car and not an anchored wall)
task.spawn(function()
 local Players=game:GetService("Players")
 local RS=game:GetService("ReplicatedStorage")
 local Run=game:GetService("RunService")
 local Collection=game:GetService("CollectionService")
 local player=Players.LocalPlayer
 local impactRemote=RS:WaitForChild("CarImpact",60)
 local wakeRemote=RS:WaitForChild("TrafficWake",60)
 local last=setmetatable({},{__mode="k"})
 local woke=setmetatable({},{__mode="k"})
 local function carOfSeat(seat)
  local m=seat:FindFirstAncestorOfClass("Model")
  while m and m.Parent and m.Parent~=workspace and m.Parent.Name~="SpawnedCars" do
   local up=m.Parent:FindFirstAncestorOfClass("Model")
   if not up then break end
   m=up
  end
  return m
 end
 local function flat(v) return Vector3.new(v.X,0,v.Z) end
 Run.Heartbeat:Connect(function()
  local char=player.Character
  local hum=char and char:FindFirstChildOfClass("Humanoid")
  local root=char and char:FindFirstChild("HumanoidRootPart")
  if not root then return end
  local myCar=nil
  if hum and hum.SeatPart and hum.SeatPart:IsA("VehicleSeat") then myCar=carOfSeat(hum.SeatPart) end
  local now=os.clock()
  -- impacts
  if impactRemote then
   local list={}
   if myCar then table.insert(list,myCar) end
   for _,m in Collection:GetTagged("TrafficWreck") do table.insert(list,m) end
   local sp=workspace:FindFirstChild("SpawnedCars")
   if sp then for _,m in sp:GetChildren() do if m~=myCar then table.insert(list,m) end end end
   for _,m in list do
    local r=m:IsA("Model") and m.PrimaryPart
    -- v290d: only cars simulated HERE (mine, or traffic I rammed - ReceiveAge 0): anyone
    -- else's arrive late and jumpy and read as huge fake hits
    if r and not r.Anchored and (m==myCar or r.ReceiveAge==0) and (r.Position-root.Position).Magnitude<120 then
     -- and a car I simulate never gets flung out of an overlap at absurd speed
     if m~=myCar then
      local lv=r.AssemblyLinearVelocity
      if lv.Magnitude>130 then r.AssemblyLinearVelocity=lv.Unit*130 end
      local av=r.AssemblyAngularVelocity
      if av.Magnitude>9 then r.AssemblyAngularVelocity=av.Unit*9 end
     end
     local v=r.AssemblyLinearVelocity
     local e=last[m]
     if e and now-e.t<0.25 then
      local dv=v-e.v
      dv=Vector3.new(dv.X,dv.Y*0.35,dv.Z)
      local moved=(r.Position-e.pos).Magnitude
      local teleport=moved>math.max(e.v.Magnitude,v.Magnitude)*(now-e.t)+6
      if teleport then e.grace=now+0.5 end
      if dv.Magnitude>=20 and not teleport and now>(e.grace or 0) and now-(e.hit or 0)>0.25 then
       e.hit=now
       impactRemote:FireServer(m,dv.Magnitude,dv.Unit)
      end
      e.v,e.pos,e.t=v,r.Position,now
     else
      last[m]={v=v,pos=r.Position,t=now,grace=now+0.6}
     end
    end
   end
  end
  -- traffic I'm about to hit
  -- v290d: my car, and the traffic cars I've knocked flying (simulated here) - so a car I
  -- shunt into the next one wakes that one too and the momentum carries on down the line
  local rammers={}
  if myCar and myCar.PrimaryPart then table.insert(rammers,myCar.PrimaryPart) end
  for _,m in Collection:GetTagged("TrafficWreck") do
   local pr=m:IsA("Model") and m.PrimaryPart
   if pr and m~=myCar and not pr.Anchored and pr.ReceiveAge==0 and (pr.Position-root.Position).Magnitude<160 then table.insert(rammers,pr) end
  end
  local ping=0.1
  pcall(function() ping=math.clamp(player:GetNetworkPing(),0,0.4) end)
  local look=math.clamp(0.35+ping*2.5,0.35,0.9)
  for _,r in (if wakeRemote then rammers else {}) do
   local v=flat(r.AssemblyLinearVelocity)
   if v.Magnitude>2.5 then
    local fwd=flat(r.CFrame.LookVector)
    fwd=if fwd.Magnitude>0.01 then fwd.Unit else Vector3.new(0,0,-1)
    for _,m in Collection:GetTagged("SmoothResidentTraffic") do
     if not woke[m] and m.Parent and m:GetAttribute("TrafficActive")==true then
      local cf=m:GetPivot()
      if flat(cf.Position-r.Position).Magnitude<30+v.Magnitude*look and math.abs(cf.Position.Y-r.Position.Y)<12 then
       local tv=m:GetAttribute("TrafficVel")
       tv=if typeof(tv)=="Vector3" then flat(tv) else Vector3.zero
       local th=flat(cf.LookVector)
       th=if th.Magnitude>0.01 then th.Unit else Vector3.new(0,0,-1)
       local hit=false
       for t=0,look,0.06 do
        local a=r.Position+v*t
        local b=cf.Position+tv*t
        for _,oa in {-4.6,4.6} do
         for _,ob in {-4.6,4.6} do
          local pa=a+fwd*oa
          local pb=b+th*ob
          local dx,dz=pa.X-pb.X,pa.Z-pb.Z
          if dx*dx+dz*dz<108 then hit=true end
         end
        end
        if hit then break end
       end
       local to=flat(cf.Position-r.Position)
       local closing=if to.Magnitude>0.01 then (v-tv):Dot(to.Unit) else 0
       if hit and closing>3 then
        woke[m]=true
        wakeRemote:FireServer(m)
       end
      end
     end
    end
   end
  end
 end)
end)
-- CarDriveClient
-- Runs the controls of the car you're driving on your own machine, so steering
-- and throttle react instantly (the server hands you physics ownership of the
-- car when you sit in the driver's seat). Tuning values come from attributes
-- that ServerScriptService.CarServer puts on the VehicleSeat.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local function collect(car)
	local spins, steers = {}, {}
	for _, obj in ipairs(car:GetDescendants()) do
		if obj:IsA("HingeConstraint") then
			if obj.Name == "Spin" and obj:GetAttribute("Sign") then
				table.insert(spins, obj)
			elseif obj.Name == "SteerHinge" then
				table.insert(steers, obj)
			end
		end
	end
	return spins, steers
end

---------------------------------------------------------------------------
-- GTA IV handling: cars with a GTAHandling line run ReplicatedStorage.GTAVehicle on
-- this machine. W/S throttle, brake and reverse, A/D steer, SPACE = handbrake (it
-- doesn't jump you out of the car - F gets you out).
---------------------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local handbrakeDown = false

-- v290: touch buttons (phone / tablet) - ReplicatedStorage.MobileControls places them round the jump button
local Mobile = require(game:GetService("ReplicatedStorage"):WaitForChild("MobileControls"))
Mobile.button("Handbrake", "HAND\nBRAKE", Color3.fromRGB(150, 30, 30), "side", function() handbrakeDown = true end, function() handbrakeDown = false end)

---------------------------------------------------------------------------
-- Skid marks (restored): dark strips where a tyre locks (handbrake) or slides.
-- Drawn here at once, and sent through ReplicatedStorage.SkidMarks so everyone
-- else sees them too (SkidMarksRelay). They fade after a while; at most MAX_SKIDS.
---------------------------------------------------------------------------
local Debris = game:GetService("Debris")
local MAX_SKIDS, SKID_LIFE = 500, 30
local skidFolder = workspace:FindFirstChild("SkidMarks") or Instance.new("Folder")
skidFolder.Name = "SkidMarks"
skidFolder.Parent = workspace
local skidList = {}
local function drawSkid(a, b, n, width)
	local len = (b - a).Magnitude
	if len < 0.05 or len > 12 then return end
	local p = Instance.new("Part")
	p.Name = "Skid"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = Color3.fromRGB(22, 22, 22)
	p.Transparency = 0.3
	p.Size = Vector3.new(width, 0.04, len + 0.15)
	p.CFrame = CFrame.lookAt((a + b) / 2 + n * 0.03, b + n * 0.03, n)
	p.Parent = skidFolder
	table.insert(skidList, p)
	while #skidList > MAX_SKIDS do
		local old = table.remove(skidList, 1)
		if old then old:Destroy() end
	end
	Debris:AddItem(p, SKID_LIFE)
end
local skidRemote = ReplicatedStorage:WaitForChild("SkidMarks", 10)
if skidRemote then
	skidRemote.OnClientEvent:Connect(function(segs)
		if type(segs) ~= "table" then return end
		for _, s in segs do
			if typeof(s[1]) == "Vector3" and typeof(s[2]) == "Vector3" and typeof(s[3]) == "Vector3" then
				drawSkid(s[1], s[2], s[3], tonumber(s[4]) or 0.8)
			end
		end
	end)
end
local pendingSkids, lastSkidSend = {}, 0
-- after each physics step: extend the mark under every tyre that is locked / sliding
local function laySkids(st, speed)
	for _, w in st.wheels do
		-- v284h: a real skid, not normal cornering: a locked wheel, or a tyre at its grip
		-- limit sliding at more than ~10 degrees, or any slide past ~18 degrees
		local slip = w.slipSpeed or 0
		local slipAngle = math.deg(math.atan2(slip, math.max(w.rollSpeed or speed, 1)))
		local sliding = w.contact and w.hitPos and speed > 10
			and (w.locked or (w.slipping and slipAngle > 10 and slip > 5) or (slipAngle > 18 and slip > 8))
		if sliding then
			local pos, n = w.hitPos, w.hitNormal or Vector3.yAxis
			if w.skidLast and (pos - w.skidLast).Magnitude >= 1.2 then
				local width = math.clamp(math.min(w.part.Size.X, w.part.Size.Y, w.part.Size.Z), 0.5, 1.4)
				drawSkid(w.skidLast, pos, n, width)
				table.insert(pendingSkids, { w.skidLast, pos, n, width })
				w.skidLast = pos
			elseif not w.skidLast then
				w.skidLast = pos
			end
		else
			w.skidLast = nil
		end
	end
	if #pendingSkids > 0 and os.clock() - lastSkidSend > 0.25 and skidRemote then
		lastSkidSend = os.clock()
		skidRemote:FireServer(pendingSkids)
		pendingSkids = {}
	end
end

local function driveGTA(humanoid, seat, car)
	local okM, Vehicle = pcall(require, ReplicatedStorage:WaitForChild("GTAVehicle", 10))
	local okD, data = pcall(require, ReplicatedStorage:WaitForChild("GTAHandlingData", 10))
	if not okM or not okD then
		warn("[GTAHandling] client couldn't load the handling modules")
		return
	end
	Vehicle.configure(data)
	local lines = Vehicle.parse(tostring(data.Text or ""), data.Columns)
	local h = lines[seat:GetAttribute("GTAHandling")]
	local st = h and Vehicle.new(car, seat, h, data.MetersToStuds or 2.8)
	if not st then
		return
	end
	Vehicle.ignore(st, { player.Character })
	ContextActionService:BindActionAtPriority("GTAHandbrake", function(_, state)
		handbrakeDown = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
		return Enum.ContextActionResult.Sink -- Space never jumps you out
	end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.ButtonX)
	Mobile.show("Handbrake", true) -- (touch screens: the HANDBRAKE button, beside jump)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	local drunkSteer = 0
	local connection
	-- PreSimulation: its dt is the time physics will actually simulate (a hitchy frame's
	-- Heartbeat dt is longer than that - pushing for it overshot gravity and hopped the car)
	connection = RunService.PreSimulation:Connect(function(dt)
		if humanoid.SeatPart ~= seat or not car.Parent then
			connection:Disconnect()
			ContextActionService:UnbindAction("GTAHandbrake")
			Mobile.show("Handbrake", false)
			handbrakeDown = false
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			return
		end
		local throttle, steer = seat.ThrottleFloat, seat.SteerFloat
		if math.abs(throttle) < 0.05 then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then throttle = 1
			elseif UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then throttle = -1 end
		end
		if math.abs(steer) < 0.05 then
			if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then steer = -1
			elseif UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then steer = 1 end
		end
		-- v252 impairment: lagging hands and drift
		local impaired = tonumber(player:GetAttribute("Impairment")) or 0
		if impaired > 0.1 then
			drunkSteer += (steer - drunkSteer) * (1 - math.clamp(impaired * 0.9, 0, 0.85))
			steer = math.clamp(drunkSteer + (math.sin(os.clock() * 0.7) * 0.6 + math.sin(os.clock() * 1.9) * 0.4) * impaired * 0.45, -1, 1)
		else
			drunkSteer = steer
		end
		if seat:GetAttribute("VehicleDestroyed") then
			throttle = 0
		end
		local res = Vehicle.step(st, dt, { throttle = throttle, steer = steer, handbrake = handbrakeDown })
		pcall(laySkids, st, seat.AssemblyLinearVelocity.Magnitude)
	end)
end

local function drive(humanoid, seat)
	local car = seat.Parent
	while car and car ~= workspace and not car:GetAttribute("CarName") do
		car = car.Parent
	end
	if car == workspace then
		car = nil
	end
	if not car or not seat:GetAttribute("TopSpeed") then
		return -- not one of the rebuilt cars
	end
	if seat:GetAttribute("GTAHandling") then
		driveGTA(humanoid, seat, car)
		return
	end

	local spins, steers = collect(car)
	local topSpeed = seat:GetAttribute("TopSpeed")
	local reverseSpeed = seat:GetAttribute("ReverseSpeed")
	local driveTorque = seat:GetAttribute("DriveTorque")
	local brakeTorque = seat:GetAttribute("BrakeTorque")
	local coastTorque = seat:GetAttribute("CoastTorque")
	local maxSteer = seat:GetAttribute("MaxSteerAngle")
	local minSteer = seat:GetAttribute("MinSteerAngle")
	local steerDirection = seat:GetAttribute("SteerDirection") or 1

	local drunkSteer = 0 -- v252: the steering you actually get when impaired
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if humanoid.SeatPart ~= seat or not car.Parent then
			connection:Disconnect()
			return
		end

		local throttle=seat.ThrottleFloat
		local steer=seat.SteerFloat
		-- Studio/legacy VehicleSeats occasionally fail to update ThrottleFloat/
		-- SteerFloat. Keyboard fallback keeps rebuilt cars driveable.
		if math.abs(throttle)<0.05 then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then throttle=1
			elseif UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then throttle=-1 end
		end
		if math.abs(steer)<0.05 then
			if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then steer=-1
			elseif UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then steer=1 end
		end
		local velocity = seat.AssemblyLinearVelocity
		local forwardSpeed = velocity:Dot(seat.CFrame.LookVector)
		local speed = math.abs(forwardSpeed)

		-- v113: police spike strips set TireDamage (0..1) on the seat: lower top speed and a
		-- wobble in the steering until it wears off (server clears it after a while).
		local tire = tonumber(seat:GetAttribute("TireDamage")) or 0
		local liveTop = topSpeed * (1 - math.clamp(tire, 0, 0.9))
		if tire > 0 and speed > 4 then
			-- v215: shredded tyres fight you: a hard pull to one side, a violent
			-- shimmy, and slides that come and go
			local pull = tonumber(seat:GetAttribute("TirePull")) or 1
			local t = os.clock()
			local shimmy = math.sin(t * 9.1) * 0.35 + math.sin(t * 3.7) * 0.25
			local slide = if math.sin(t * 1.3) > 0.75 then pull * 0.5 else 0
			steer = math.clamp(steer + (pull * 0.3 + shimmy + slide) * tire, -1, 1)
			throttle *= 1 - 0.35 * tire -- the rims bite: sluggish acceleration
		end
		-- v252: impaired driving (Drugs sets Impairment 0..1 on the player): the
		-- steering lags behind your hands, the car drifts, and you brake late
		local impaired = tonumber(Players.LocalPlayer:GetAttribute("Impairment")) or 0
		if impaired > 0.1 then
			local t = os.clock()
			local lag = math.clamp(impaired * 0.9, 0, 0.85)
			drunkSteer = drunkSteer + (steer - drunkSteer) * (1 - lag)
			local drift = (math.sin(t * 0.7) * 0.6 + math.sin(t * 1.9) * 0.4) * impaired * 0.45
			steer = math.clamp(drunkSteer + drift, -1, 1)
			if throttle < 0 and forwardSpeed > 2 then
				throttle *= 1 - impaired * 0.6 -- brakes late and soft
			end
		else
			drunkSteer = steer
		end
		-- a burning / destroyed car doesn't drive
		if seat:GetAttribute("VehicleDestroyed") then
			throttle, liveTop = 0, 0
		end

		-- Steering: full lock when slow, tighter at speed.
		local fraction = math.clamp(speed / topSpeed, 0, 1)
		local maxAngle = maxSteer + (minSteer - maxSteer) * fraction
		for _, hinge in ipairs(steers) do
			hinge.TargetAngle = -steer * maxAngle * steerDirection
		end

		-- Throttle / brake / reverse.
		local target, torque
		if math.abs(throttle) < 0.05 then
			target, torque = 0, coastTorque
		elseif forwardSpeed * throttle < -1 then
			target, torque = 0, brakeTorque -- pressing against the way you're moving = brake
		elseif throttle > 0 then
			target, torque = throttle * liveTop, driveTorque
		else
			target, torque = throttle * reverseSpeed, driveTorque
		end
		for _, hinge in ipairs(spins) do
			hinge.AngularVelocity = target / hinge:GetAttribute("Radius") * hinge:GetAttribute("Sign")
			hinge.MotorMaxTorque = torque
		end
	end)
end

local function onCharacter(character)
	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Seated:Connect(function(active,seatPart)
		if active and seatPart and seatPart:IsA("VehicleSeat") then drive(humanoid,seatPart) end
	end)
	task.defer(function()
		local seat=humanoid.SeatPart
		if seat and seat:IsA("VehicleSeat") then drive(humanoid,seat) end
	end)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

-- F (or the ENTER / EXIT button on mobile): get in the nearest car (GTA style) / get out.
-- The server walks you to the door. A traffic car is a carjacking (the server's seat code
-- pulls the driver out) - v284i: no more relying on the hidden prompt, it can't be tapped
-- on a phone and it could be left behind on a car you already took.
local function nearestFreeSeat(root)
	local best, bestD = nil, 16
	for _, part in workspace:GetDescendants() do
		if part:IsA("VehicleSeat") and not part.Occupant then -- (disabled too: a traffic seat; the server decides)
			local d = (part.Position - root.Position).Magnitude
			if d < bestD then
				best, bestD = part, d
			end
		end
	end
	return best
end
local function enterExit()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then
		return
	end
	local remote = ReplicatedStorage:FindFirstChild("CarEnterExit")
	if not remote then
		return
	end
	-- v286n: only really seated counts - a stale SeatPart (a seat that doesn't have us) used to turn
	-- every F into "get out" forever
	if hum.SeatPart and hum.SeatPart.Occupant == hum then
		remote:FireServer(nil) -- out
		return
	end
	if hum.SeatPart then hum.Sit = false end
	local best = nearestFreeSeat(root)
	if best then
		remote:FireServer(best)
	end
end
UserInputService.InputBegan:Connect(function(input, processed)
	-- "processed" is also set when a ProximityPrompt grabs F, so only a focused text box blocks it
	if input.KeyCode ~= Enum.KeyCode.F or UserInputService:GetFocusedTextBox() then
		return
	end
	enterExit()
end)
-- mobile: an ENTER / EXIT button (above jump) near a car / while in one
Mobile.button("EnterExit", "ENTER", Color3.fromRGB(30, 90, 160), "up", function() enterExit() end)
task.spawn(function()
	while true do
		task.wait(0.3)
		if not UserInputService.TouchEnabled then continue end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local want = nil
		if hum and root and hum.Health > 0 then
			local seated = hum.SeatPart and hum.SeatPart.Occupant == hum
			if seated and hum.SeatPart:IsA("VehicleSeat") then
				want = "EXIT"
			elseif not seated and nearestFreeSeat(root) then
				want = "ENTER"
			end
		end
		Mobile.show("EnterExit", want ~= nil, want)
	end
end)
