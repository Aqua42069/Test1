-- params : ...

local player = script.Parent.Parent.Parent.Parent
local maxArmour = 100
repeat
  wait()
until player.Character
player.Character:WaitForChild("Humanoid")
updateHealth = function(newHealth)
  
  if newHealth <= 100 then
    script.Parent.HealthBar.Size = UDim2.new(-0.96 * (newHealth / 100), 0, 0.8, 0)
    script.Parent.ArmourBar.Size = UDim2.new(0, 0, 0, 0)
  else
    if newHealth <= maxArmour + 100 then
      script.Parent.HealthBar.Size = UDim2.new(-0.96, 0, 0.8, 0)
      script.Parent.ArmourBar.Size = UDim2.new(-0.96 * ((newHealth - 100) / maxArmour), 0, 0.8, 0)
    else
      player.Character.Humanoid.Health = maxArmour + 100
      player.Character.Humanoid.MaxHealth = maxArmour + 100
      script.Parent.HealthBar.Size = UDim2.new(-0.96, 0, 0.8, 0)
      script.Parent.ArmourBar.Size = UDim2.new(-0.96, 0, 0.8, 0)
    end
  end
end

player.Character.Humanoid.HealthChanged:connect(function(newHealth)
  
  updateHealth(newHealth)
end
)
wait(1)
updateHealth(player.Character.Humanoid.MaxHealth)
