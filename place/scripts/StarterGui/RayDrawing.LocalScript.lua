-- params : ...

game.ReplicatedStorage.Events:WaitForChild("RayDrawing").OnClientEvent:connect(function(startPos, endPos, colour, thickness)
  
  local bullet = Instance.new("Part", Workspace.BulletHolder)
  bullet.Anchored = true
  bullet.FormFactor = "Custom"
  bullet.Size = Vector3.new(0.2, 0.2, 0.2)
  bullet.CanCollide = false
  if colour then
    bullet.BrickColor = BrickColor.new(colour)
  end
  if thickness ~= nil then
    bullet.CFrame = CFrame.new(startPos, endPos) * CFrame.Angles(math.rad(90), 0, 0)
    local bulletMesh = Instance.new("CylinderMesh", bullet)
    bulletMesh.Scale = Vector3.new(thickness, 5 * endPos - startPos.magnitude, thickness)
    bulletMesh.Offset = Vector3.new(0, -endPos - startPos.magnitude / 2, 0)
    game:GetService("Debris"):AddItem(bullet, 0.19)
  else
    do
      bullet.Transparency = 0.6
      bullet.CFrame = CFrame.new(startPos, endPos)
      local bulletMesh = Instance.new("BlockMesh", bullet)
      bulletMesh.Scale = Vector3.new(0.5, 0.5, 5 * endPos - startPos.magnitude)
      bulletMesh.Offset = Vector3.new(0, 0, -endPos - startPos.magnitude / 2)
      game:GetService("Debris"):AddItem(bullet, 0.1)
    end
  end
end
)
