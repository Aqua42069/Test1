-- params : ...

local hasTools = false
local player = script.Parent.Parent.Parent.Parent
script.Parent:WaitForChild("Button")
script.Parent.Button.MouseButton1Click:connect(function()
  
  if hasTools then
    if player.Backpack:FindFirstChild("RemoveFurniture") then
      player.Backpack.RemoveFurniture:Destroy()
    end
    if player.Backpack:FindFirstChild("Place Items") then
      player.Backpack["Place Items"]:Destroy()
    end
    script.Parent.Button.Text = "Get Furniture Tools"
  else
    for _,v in pairs(game.ReplicatedStorage.FurnitureTools:GetChildren()) do
      v:clone().Parent = player.Backpack
    end
    script.Parent.Button.Text = "Remove Furniture Tools"
  end
  hasTools = not hasTools
end
)
