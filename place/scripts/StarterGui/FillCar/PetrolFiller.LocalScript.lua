-- params : ...

local petrolPump = nil
local player = script.Parent.Parent.Parent
local litresPerDollar = 8
local filling = false
local car = nil
local maxFuel = 1
local currFuel = 0
local startFuel = 0
local maxDist = 35
local playerMoney = -1
local key = math.random(100, 10000)
local currentCost = key
Spawn(function()
  
  repeat
    wait()
  until car ~= nil
  maxFuel = game.ReplicatedStorage.Functions.GetMaxFuel:InvokeServer(car.OriginalName.Value)
  currFuel = car.Fuel.Value
end
)
game.ReplicatedStorage.Events.ClientGuiVisible.OnClientEvent:connect(function(state)
  
  script.Parent.Holder.Visible = state
end
)
game.ReplicatedStorage.Events.UpdateFuelCar.OnClientEvent:connect(function(sentCar)
  
  car = sentCar
end
)
game.ReplicatedStorage.Events.PetrolPump.OnClientEvent:connect(function(part)
  
  petrolPump = part
end
)
script.Parent.Holder.FillButton.MouseButton1Down:connect(function()
  
  playerMoney = player.Money.Value + player.Cash.Value + key
  if not filling then
    filling = true
    if car then
      maxFuel = game.ReplicatedStorage.Functions.GetMaxFuel:InvokeServer(car.OriginalName.Value)
      currFuel = car.Fuel.Value
      startFuel = currFuel
    end
    if petrolPump and maxFuel > 1 then
      Spawn(function()
    
    while filling and currentCost < playerMoney and currFuel < maxFuel do
      currentCost = currentCost + 1
      script.Parent.Holder.Cost.Text = "Current Cost: $" .. currentCost - key
      currFuel = math.min(maxFuel, currFuel + litresPerDollar)
      if player.PlayerGui:FindFirstChild("FuelGauge") then
        player.PlayerGui.FuelGauge.Holder.GreenBar.Holder.Size = UDim2.new(1, 0, 1 - currFuel / maxFuel, 0)
      end
      wait(0.2)
    end
  end
)
    end
  end
end
)
script.Parent.Holder.FillButton.MouseButton1Up:connect(function()
  
  currentCost = key
  script.Parent.Holder.Cost.Text = "Current Cost: $0"
  game.ReplicatedStorage.Events.FuelUpdater:FireServer(car, currFuel, startFuel)
  wait(0.2)
  filling = false
end
)
Spawn(function()
  
  while 1 do
    if wait(3) and not player.Character or not petrolPump or maxDist < player.Character.Torso.Position - petrolPump.Position.magnitude then
      script.Parent.Holder.Visible = false
    end
  end
end
)
