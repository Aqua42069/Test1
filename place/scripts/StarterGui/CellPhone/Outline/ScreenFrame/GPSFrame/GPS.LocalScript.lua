-- params : ...

local currentLocation = nil
local width = 4.1666666666667
local locations = {
{"Bank", Vector2.new(891, -2098)}
, 
{"Casino", Vector2.new(1362, -473)}
, 
{"Airport Terminal", Vector2.new(169, 736)}
, 
{"Car Dealer 1", Vector2.new(86, 347)}
, 
{"Car Dealer 2", Vector2.new(1362, -1576)}
, 
{"Hospital", Vector2.new(1455, -1023)}
, 
{"City Hall", Vector2.new(2746, -1337)}
, 
{"Ad Agency", Vector2.new(50, -1028)}
, 
{"Estate Agency", Vector2.new(641, -861)}
, 
{"Furniture Store", Vector2.new(52, -960)}
, 
{"Heli Store", Vector2.new(548, 499)}
, 
{"Prison", Vector2.new(-678, -2306)}
, 
{"Police Station", Vector2.new(236, 21)}
, 
{"NSA HQ", Vector2.new(223, -788)}
, 
{"Military Outpost", Vector2.new(-668, 1110)}
, 
{"Impound Lot", Vector2.new(1368, -2010)}
}
local rightAngle = CFrame.Angles(0, 0, math.rad(90))
local offset = 10
local arrow = Instance.new("Part", Workspace.CurrentCamera)
arrow.FormFactor = "Custom"
arrow.Size = Vector3.new(1, 1, 1)
arrow.Anchored = true
arrow.Transparency = 1
arrow.BrickColor = BrickColor.new("Lime green")
arrow.CanCollide = false
local arrowMesh = Instance.new("SpecialMesh", arrow)
arrowMesh.MeshId = "http://www.roblox.com/asset/?id=14656345"
arrowMesh.Scale = Vector3.new(0.1, 0.1, 0.1)
local arrow2 = arrow:clone()
arrow2.Parent = Workspace.CurrentCamera
local finding = false
script.Parent.Stop.MouseButton1Click:connect(function()
  
  currentLocation = nil
  script.Parent.Info.Text = "Currently headed to: None"
  game:GetService("RunService"):UnbindFromRenderStep("GPS")
  arrow.Transparency = 1
  arrow2.Transparency = 1
end
)
local count = 0
script.Parent:WaitForChild("Scroller")
script.Parent:WaitForChild("Stop")
for _,v in pairs(locations) do
  do
    local newButton = script.Parent.Stop:Clone()
    newButton.Parent = script.Parent.Scroller
    newButton.Text = v[1]
    newButton.Size = UDim2.new(1, 0, 0, 20)
    newButton.Position = UDim2.new(0, 0, 0, count * 20)
    count = count + 1
    newButton.MouseButton1Click:connect(function()
  
  do
    local wasEmpty = currentLocation == nil
    currentLocation = v[2]
    script.Parent.Info.Text = "Currently headed to: " .. v[1]
    arrow.Transparency = 0
    arrow2.Transparency = 0
    if wasEmpty then
      game:GetService("RunService"):BindToRenderStep("GPS", Enum.RenderPriority.Camera.Value, function()
    
    if currentLocation ~= nil then
      local camPos = Workspace.CurrentCamera.CoordinateFrame.p
      local targetPos = Vector3.new(currentLocation.x, camPos.y, currentLocation.y)
      arrow.CFrame = CFrame.new(Workspace.CurrentCamera.CoordinateFrame.lookVector * offset) * CFrame.new(0, 3, 0) * CFrame.new(camPos, targetPos)
      arrow2.CFrame = arrow.CFrame * rightAngle
      if targetPos - camPos.magnitude < 20 then
        game:GetService("RunService"):UnbindFromRenderStep("GPS")
        currentLocation = nil
        script.Parent.Info.Text = "Currently headed to: None"
        arrow.Transparency = 1
        arrow2.Transparency = 1
      end
    end
  end
)
    end
    -- DECOMPILER ERROR: 2 unprocessed JMP targets
  end
end
)
  end
end
script.Parent.Scroller.CanvasSize = UDim2.new(1, 0, 0, 20 * (count))
