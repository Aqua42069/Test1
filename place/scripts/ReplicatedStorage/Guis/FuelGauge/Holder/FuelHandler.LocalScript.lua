-- params : ...

local car = nil
local currFuel = 1
local maxFuel = 1
local player = script.Parent.Parent.Parent.Parent
updateGui = function()
  
  script.Parent.GreenBar.Holder.Size = UDim2.new(1, 0, 1 - currFuel / maxFuel, 0)
  game.ReplicatedStorage.Events.FuelUpdater:FireServer(car, currFuel)
end

game.ReplicatedStorage.Events.UpdateFuelCar.OnClientEvent:connect(function(sentCar)
  
  car = sentCar
  currFuel = sentCar.Fuel.Value
  maxFuel = game.ReplicatedStorage.Functions.GetMaxFuel:InvokeServer(sentCar.OriginalName.Value)
  updateGui()
end
)
wait(2)
repeat
  repeat
    wait()
  until script.Parent.GreenBar.AbsoluteSize.X > 0
until script.Parent.GreenBar.AbsoluteSize.Y > 0
script.Parent.GreenBar.Size = UDim2.new(0, script.Parent.GreenBar.AbsoluteSize.X, 0, script.Parent.GreenBar.AbsoluteSize.Y)
script.Parent.GreenBar.Holder.RedBar.Size = script.Parent.GreenBar.Size
Spawn(function()
  
  while 1 do
    while 1 do
      if wait(2) then
        if car then
          if car:FindFirstChild("Engine") then
            if car:FindFirstChild("Essentials") then
              if car.Engine.Value then
                if player.PlayerGui:FindFirstChild("FillCar") then
                  if player.PlayerGui.FillCar.Holder.Visible == false then
                    if currFuel > 0 then
                      currFuel = currFuel - math.abs(car.Essentials.Speed.Value) * 2
                      updateGui()
                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_THEN_STMT

                      -- DECOMPILER ERROR at PC55: LeaveBlock: unexpected jumping out IF_STMT

                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    currFuel = 0
    updateGui()
    game.ReplicatedStorage.Events.CutEngine:FireServer(car, false)
  end
end
)
repeat
  wait(0.2)
until car ~= nil
car.Fuel.Changed:connect(function()
  
  currFuel = math.min(car.Fuel.Value, maxFuel)
  updateGui()
end
)
