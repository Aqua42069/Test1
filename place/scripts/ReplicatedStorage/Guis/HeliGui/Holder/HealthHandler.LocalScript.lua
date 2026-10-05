-- params : ...

local player = script.Parent.Parent.Parent.Parent
local heli = player.Character:FindFirstChild("Helicopter")
if heli then
  local heliMaxHealth = game.ReplicatedStorage.Functions.GetHeliHealth:InvokeServer(heli.OriginalName.Value)
  do
    local healthVal = heli.HealthVal
    local updateHealth = function()
  
  script.Parent.HealthBar.Size = UDim2.new(-0.96 * healthVal.Value / heliMaxHealth, 0, 0.83, 0)
end

    healthVal.Changed:connect(function()
  
  updateHealth()
end
)
    wait()
    updateHealth()
  end
end
