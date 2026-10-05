-- params : ...

local player = game.Players.LocalPlayer
player.HasMission.Value = true
local lastCount = 0
local amount = math.random(5, 10)
local counter = Instance.new("IntValue", player)
counter.Name = "KillCounter"
local objectiveGui = game.ReplicatedStorage.Guis.MissionObjective:clone()
objectiveGui.Parent = script.Parent
objectiveGui.Objective.Text = "Current Objective: Kill " .. amount .. " more people"
counter.Changed:connect(function()
  
  if lastCount < counter.Value then
    objectiveGui.Objective.Text = "Current Objective: Kill " .. amount - counter.Value .. " more people"
    lastCount = counter.Value
    if lastCount == amount then
      local passGui = game.ReplicatedStorage.Guis.MissionPassed:clone()
      passGui.Reward.Value = 100 * amount
      passGui.Parent = player.PlayerGui
      passGui.PassScript.Disabled = false
      script:Destroy()
    end
  end
end
)
