-- params : ...

game:GetService("ContentProvider"):Preload("http://www.roblox.com/asset/?id=141653643")
script.Parent:WaitForChild("PassText")
script.Parent:WaitForChild("Reward")
script.Parent:WaitForChild("RewardText")
script.Parent.RewardText.Text = "+ $" .. script.Parent.Reward.Value
local player = game.Players.LocalPlayer
wait()
game.ReplicatedStorage.Events.MoneyRequest:FireServer(script.Parent.Reward.Value, "Money")
player.HasMission.Value = false
if player.PlayerGui:FindFirstChild("MissionObjective") then
  game.ReplicatedStorage.Events.GuiHandler:FireServer(false, "MissionObjective")
end
script.Parent.PassText:TweenSizeAndPosition(UDim2.new(0.375, 0, 0.125, 0), UDim2.new(0.3125, 0, 0.4375, 0), 1, 0, 1)
wait(4)
script.Parent.PassText:TweenSizeAndPosition(UDim2.new(0, 0, 0, 0), UDim2.new(0.5, 0, 0.5, 0), 1, 0, 1)
wait(1)
game.ReplicatedStorage.Events.GuiHandler:FireServer(false, "MissionPassed")
script.Parent:Destroy()
