-- params : ...

local garagePositions = {
{Workspace.CarDropOffA, " return to the garage next to the airport multi-story car park."}
, 
{Workspace.CarDropOffB, " return to the garage next to the suburbs."}
}
local stealableCars = {
{"C-Span Van", 
{"C-Span"}
, 150}
, 
{"CIA Cruiser", 
{"Central Intelligence Agency"}
, 250}
, 
{"DoD Car", 
{"Dept. of Defense"}
, 250}
, 
{"DIA Cruiser", 
{"Defense Intelligence Agency"}
, 250}
, 
{"FBI Cruiser", 
{"Federal Bureau of Investigation"}
, 300}
, 
{"HLS Car", 
{"Homeland Security"}
, 250}
, 
{"Ambulance", 
{"Emergency Medical Service"}
, 200}
, 
{"NSA Cruiser", 
{"National Security Agency"}
, 250}
, 
{"SS Cruiser", 
{"Secret Service"}
, 250}
, 
{"Humvee", 
{"Special Forces"}
, 300}
, 
{"Police Car", 
{"LVPD"}
, 250}
, 
{"Prison Van", 
{"U.S. Marshal Service"}
, 350}
, 
{"SWAT Truck", 
{"SWAT"}
, 400}
, 
{"Taxi", 
{"Taxi Company"}
, 100}
, 
{"Willy\'s Jeep", 
{"Dept. of Defense", "USM"}
, 100}
}
local deb = false
local frames = 0
local carInGarage = false
local player = game.Players.LocalPlayer
player.HasMission.Value = true
local returnTab = garagePositions[math.random(1, #garagePositions)]
do
  for i = #stealableCars, 1, -1 do
    local isValid = false
    for _,v in pairs(stealableCars[i][2]) do
      if game:GetService("Teams"):FindFirstChild(v) then
        isValid = true
        break
      end
    end
    do
      do
        if not isValid then
          table.remove(stealableCars, i)
        end
        -- DECOMPILER ERROR at PC164: LeaveBlock: unexpected jumping out DO_STMT

      end
    end
  end
end
local objectiveGui = game.ReplicatedStorage.Guis.MissionObjective:clone()
objectiveGui.Parent = script.Parent
if #stealableCars == 0 then
  objectiveGui.Objective.Text = "Sorry, there are no cars able to be stolen currently. Try again later"
  player.HasMission.Value = false
  wait(5)
  objectiveGui:Destroy()
  script:Destroy()
else
  local stealTab = stealableCars[math.random(1, #stealableCars)]
  objectiveGui.Objective.Text = "Current Objective: Steal a " .. stealTab[1] .. " and" .. returnTab[2]
  closeDoor = function(door)
  
  local origCFrame = door.CFrame
  for i = 0, frames do
    wait()
    door.CFrame = origCFrame * CFrame.new(0, -1.72 * i, 0)
    door.CurrUp.Value = door.CurrUp.Value - 1.72
  end
  door.CurrUp.Value = 0
end

  noPlayers = function()
  
  for _,v in pairs(game.Players:GetPlayers()) do
    if v.Character and v.Character:FindFirstChild("HumanoidRootPart") and (v.Character.HumanoidRootPart.Position - (returnTab[1].Garage.Position + returnTab[1].Garage.Position) / 2).Magnitude < 14 then
      return false
    end
  end
  return true
end

  returnTab[1].DoorOpener.Touched:connect(function(hit)
  
  do
    -- DECOMPILER ERROR at PC15: Unhandled construct in 'MakeBoolean' P1

    if not carInGarage and game.Players:GetPlayerFromCharacter(hit.Parent.Parent.Parent) == player then
      local car = hit.Parent.Parent
      if car.OriginalName.Value == stealTab[1] then
        objectiveGui.Objective.Text = "Current Objective: Enter the garage"
        if not deb then
          deb = true
          while returnTab[1].Door.CurrUp.Value < returnTab[1].Door.Size.y + 0.1 do
            wait()
            returnTab[1].Door.CurrUp.Value = returnTab[1].Door.CurrUp.Value + 1.73
            returnTab[1].Door.CFrame = returnTab[1].Door.CFrame * CFrame.new(0, 1.73, 0)
            frames = frames + 1
          end
          deb = false
        end
      end
    end
    if game.Players:GetPlayerFromCharacter(hit.Parent) == player then
      local car = hit.Parent.VS3
      if noPlayers() then
        closeDoor(returnTab[1].Door)
        local passGui = game.ReplicatedStorage.Guis.MissionPassed:clone()
        passGui.Reward.Value = math.floor(stealTab[3] * (car.Body.HealthVal.Value / game.ServerStorage.Cars[stealTab[1]].Body.HealthVal.Value))
        passGui.Parent = player.PlayerGui
        passGui.PassScript.Disabled = false
        car:Destroy()
        script:Destroy()
      else
        do
          while 1 do
            if wait(1) and noPlayers() then
              closeDoor(returnTab[1].Door)
              local passGui = game.ReplicatedStorage.Guis.MissionPassed:clone()
              passGui.Reward.Value = math.floor(stealTab[3] * math.max(0.4, car.Body.HealthVal.Value / game.ServerStorage.Cars[stealTab[1]].Body.HealthVal.Value))
              passGui.Parent = player.PlayerGui
              passGui.PassScript.Disabled = false
              car:Destroy()
              script:Destroy()
            end
          end
        end
      end
    end
  end
end
)
  returnTab[1].Garage.Touched:connect(function(hit)
  
  if game.Players:GetPlayerFromCharacter(hit.Parent.Parent.Parent) == player then
    local car = hit.Parent.Parent
    if car.OriginalName.Value == stealTab[1] then
      objectiveGui.Objective.Text = "Current Objective: Exit the garage"
      carInGarage = true
      car.Engine.Value = false
    end
  end
end
)
end
