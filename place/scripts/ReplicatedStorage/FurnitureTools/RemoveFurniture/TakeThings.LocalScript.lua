-- params : ...

local player = game.Players.LocalPlayer
hasNothingOnTop = function(model)
  
  if not model:FindFirstChild("Surface") then
    return true
  else
    for _,part in pairs(model:GetChildren()) do
      if part.Name == "Surface" then
        for _,v in pairs(part:GetConnectedParts()) do
          if v.Name == "IsSurface" then
            return false
          end
        end
      end
    end
    return true
  end
end

click = function(m)
  
  if not deb and m.Target and m.Target.Parent:FindFirstChild("IsFurniture") and m.Target.Parent.Parent:FindFirstChild("Owner") and m.Target.Parent.Parent.Owner.Value == player.Name and hasNothingOnTop(m.Target.Parent) then
    deb = true
    game.ReplicatedStorage.Events.FurnitureDestroyer:FireServer(m.Target.Parent)
    if not player.Backpack:FindFirstChild("Place Items") then
      game.ReplicatedStorage.FurnitureTools["Place Items"]:clone().Parent = player.Backpack
    end
    wait(1)
    deb = false
  end
end

script.Parent.Selected:connect(function(m)
  
  m.Button1Down:connect(function()
    
    click(m)
  end
)
end
)
