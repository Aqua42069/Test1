-- params : ...

local player = game.Players.LocalPlayer
local furniture = player.Furniture:GetChildren()
local count = 1
local model = nil
local isCFramed = true
local canPlace = false
local rotation = 0
local deb = false
local yOffset = 0
if #furniture == 0 then
  wait()
  script.Parent:Destroy()
end
updateGui = function()
  
  if player.PlayerGui:FindFirstChild("FurniturePlacing") then
    local holder = player.PlayerGui.FurniturePlacing.Holder
    holder.ItemNumber.Text = "Number " .. count .. "/" .. #furniture
    holder.ItemName.Text = "Item: " .. model.Name
  end
end

GetBricks = function(Model)
  
  local Table = {}
  local FindParts
  FindParts = function(TheModel)
    
    for _,b in pairs(TheModel:GetChildren()) do
      if b:IsA("BasePart") then
        table.insert(Table, b)
      end
      FindParts(b) -- (decompiler placeholder l_0_1_r2: the recursive call)
    end
  end

  FindParts(Model)
  return Table
end

MoveModel = function(Model, NewCFrame)
  
  Model:SetPrimaryPartCFrame(NewCFrame * CFrame.Angles(0, math.rad(rotation), 0))
end

snapTo = function(pos)
  
  local nearest = 1
  return CFrame.new(math.floor(pos.x / nearest + 0.5) * nearest, pos.y + yOffset, math.floor(pos.z / nearest + 0.5) * nearest)
end

modelCanRay = function(model, surface)
  
  local ignoreList = {model}
  if surface then
    table.insert(ignoreList, surface)
  end
  for _,v in pairs(model:GetChildren()) do
    if v:IsA("BasePart") then
      local Hit = Workspace:FindPartOnRayWithIgnoreList(Ray.new(v.Position, CFrame.new(v.Position, player.Character.Torso.Position).lookVector * 5), ignoreList)
      if Hit and Hit.Parent ~= player.Character and Hit.Parent.Parent ~= player.Character then
        return false
      end
    end
  end
  return true
end

modelCanDown = function(model)
  
  local ignoreList = {model}
  for _,v in pairs(model:GetChildren()) do
    if v:IsA("BasePart") then
      local Hit = Workspace:FindPartOnRayWithIgnoreList(Ray.new(v.Position, Vector3.new(0, -20, 0)), ignoreList)
      if Hit and Hit.Name == "Part" then
        return false
      end
    end
  end
  return true
end

updateModelGhost = function(m)
  
  if model then
    canPlace = false
    MoveModel(model, snapTo(m.Hit.p))
    -- DECOMPILER ERROR at PC100: Unhandled construct in 'MakeBoolean' P3

    -- DECOMPILER ERROR at PC100: Unhandled construct in 'MakeBoolean' P3

    -- DECOMPILER ERROR at PC100: Unhandled construct in 'MakeBoolean' P3

    if modelCanRay(model, (((m.Target.Name ~= "Floor" and m.Target.Name ~= "AnchorFloor") or m.Target.Parent.Owner.Value ~= player.Name) and m.Target.Name == "Surface" and model:FindFirstChild("IsSurface") and not model:FindFirstChild("IsOutdoor") and m.Target.Name == "OutsideFloor" and not model:FindFirstChild("IsSurface") and model:FindFirstChild("IsOutdoor") and m.Target.Parent.Owner.Value ~= player.Name) or ((m.Target.Name == "Surface" and m.Target.Parent))) and modelCanDown(model) then
      for _,v in pairs(model:GetChildren()) do
        if v:IsA("BasePart") then
          v.BrickColor = BrickColor.new("Bright green")
        end
      end
      canPlace = true
    else
      for _,v in pairs(model:GetChildren()) do
        if v:IsA("BasePart") then
          v.BrickColor = BrickColor.new("Bright red")
        end
      end
      canPlace = false
    end
  end
  -- DECOMPILER ERROR: 6 unprocessed JMP targets
end

recolourModel = function(mode)
  
  for i,v in pairs(mode:GetChildren()) do
    if v:IsA("BasePart") and v.Transparency ~= 1 then
      local colour = Instance.new("BrickColorValue", v)
      colour.Name = "Colour"
      colour.Value = v.BrickColor
      v.BrickColor = BrickColor.new("Bright red")
      local trans = Instance.new("NumberValue", v)
      trans.Name = "Trans"
      trans.Value = v.Transparency
      v.Transparency = 0.3
      local mater = Instance.new("StringValue", v)
      mater.Name = "Mater"
      mater.Value = v.Material.Name
      v.Material = "Plastic"
      if not v.CanCollide then
        local collide = Instance.new("BoolValue", v)
        collide.Name = "Collide"
      else
        do
          v.CanCollide = false
          do
            if v:FindFirstChild("Mesh") and v.Mesh.ClassName == "SpecialMesh" then
              local texture = Instance.new("StringValue", v)
              texture.Name = "Texture"
              texture.Value = v.Mesh.TextureId
              v.Mesh.TextureId = ""
            end
            -- DECOMPILER ERROR at PC76: LeaveBlock: unexpected jumping out DO_STMT

            -- DECOMPILER ERROR at PC76: LeaveBlock: unexpected jumping out IF_ELSE_STMT

            -- DECOMPILER ERROR at PC76: LeaveBlock: unexpected jumping out IF_STMT

            -- DECOMPILER ERROR at PC76: LeaveBlock: unexpected jumping out IF_THEN_STMT

            -- DECOMPILER ERROR at PC76: LeaveBlock: unexpected jumping out IF_STMT

          end
        end
      end
    end
  end
end

setModel = function(position, mouse)
  
  if model ~= nil then
    model:Destroy()
  end
  model = game.ReplicatedStorage.Furniture[furniture[count].Name]:clone()
  mouse.TargetFilter = model
  local lowestPoint = 100
  for _,v in pairs(model:GetChildren()) do
    if v:IsA("BasePart") then
      local low = v.Position.y - v.Size.y / 2
      if low < lowestPoint then
        lowestPoint = low
      end
      if v.ClassName == "Seat" then
        v.Disabled = true
      end
      v.CanCollide = false
    end
  end
  yOffset = model.PrimaryPart.Position.y - lowestPoint
  recolourModel(model)
  model.Parent = Workspace.CurrentCamera
  model:MakeJoints()
  updateModelGhost(mouse)
  updateGui()
end

press = function(m, k)
  
  k = k:lower()
  if k == "r" then
    for i,v in pairs(model:GetChildren()) do
      if v:IsA("BasePart") then
        v.CFrame = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.rad(90)) * (model:GetModelCFrame() * CFrame.Angles(0, math.rad(90), 0)) * model:GetModelCFrame() * CFrame.Angles(0, math.rad(90), 0):inverse() * v.CFrame
      end
    end
    MoveModel(model, snapTo(m.Hit.p))
    rotation = (rotation + 90) % 360
    updateModelGhost(m)
  else
    if k == "q" then
      count = (count - 2) % #furniture + 1
      setModel(count, m)
    else
      if k == "e" then
        count = count % #furniture + 1
        setModel(count, m)
      end
    end
  end
end

click = function(m)
  
  updateModelGhost(m)
  if canPlace and model and not deb then
    deb = true
    game.ReplicatedStorage.Events.FurnitureMaker:FireServer(m.Target, model.Name, snapTo(m.Hit.p), rotation)
    rotation = 0
    model:Destroy()
    model = nil
    wait(0.3)
    furniture[count]:Destroy()
    furniture = player.Furniture:GetChildren()
    if #furniture == 0 then
      if player.PlayerGui:FindFirstChild("FurniturePlacing") then
        player.PlayerGui.FurniturePlacing:Destroy()
      end
      script.Parent:Destroy()
    end
    count = count % #furniture + 1
    setModel(count, m)
    deb = false
  end
end

move = function(m)
  
  updateModelGhost(m)
end

script.Parent.Selected:connect(function(mouse)
  
  rotation = 0
  furniture = player.Furniture:GetChildren()
  game.ReplicatedStorage.Guis.FurniturePlacing:clone().Parent = player.PlayerGui
  setModel(count, mouse)
  wait()
  MoveModel(model, snapTo(mouse.Hit.p))
  mouse.KeyDown:connect(function(key)
    
    press(mouse, key)
  end
)
  mouse.Button1Down:connect(function()
    
    click(mouse)
  end
)
  mouse.Move:connect(function()
    
    move(mouse)
  end
)
end
)
script.Parent.Deselected:connect(function()
  
  if player.PlayerGui:FindFirstChild("FurniturePlacing") then
    player.PlayerGui.FurniturePlacing:Destroy()
  end
  if model then
    model:Destroy()
  end
end
)
