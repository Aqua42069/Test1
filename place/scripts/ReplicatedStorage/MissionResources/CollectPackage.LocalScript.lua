-- params : ...

local packagePositions = {
{CFrame.new(-900, 21.7, 1045), " on a red shipping container in the military depot", 200}
, 
{CFrame.new(1939.5, 62.4, 947.5), " on top of the multi-story car park", 50}
, 
{CFrame.new(151.8, 1.589, 1291), " in between the fuel tanks in the airport", 150}
, 
{CFrame.new(-570, 81.6, 591), " on the helipad in the military depot", 200}
}
local spinny = true
local player = game.Players.LocalPlayer
player.HasMission.Value = true
local packageTab = packagePositions[math.random(1, #packagePositions)]
script:WaitForChild("Payout")
script.Payout.Value = packageTab[3]
local hasPackage = Instance.new("BoolValue")
hasPackage.Name = "PackageHeld"
hasPackage.Value = false
hasPackage.Parent = player
local newPackage = game.ReplicatedStorage.MissionResources.Package:clone()
newPackage.Parent = Workspace.CurrentCamera
newPackage.CFrame = packageTab[1]
local objectiveGui = game.ReplicatedStorage.Guis.MissionObjective:clone()
objectiveGui.Objective.Text = "Current Objective: Collect the package from" .. packageTab[2]
objectiveGui.Parent = script.Parent
local packageGui = game.ReplicatedStorage.Guis.PackageGui:clone()
packageGui.Parent = script.Parent
packageGui.PackageText.Text = "Have package: No"
newPackage.Touched:connect(function(hit)
  
  if game.Players:GetPlayerFromCharacter(hit.Parent) == player then
    hasPackage.Value = true
    objectiveGui.Objective.Text = "Current Objective: Return the package"
    packageGui.PackageText.Text = "Have package: Yes"
    spinny = false
    newPackage:Destroy()
  end
end
)
coroutine.resume(coroutine.create(function()
  
  while spinny do
    newPackage.CFrame = newPackage.CFrame * CFrame.Angles(0, math.rad(3), 0)
    wait(0.05)
  end
end
))
