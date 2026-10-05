-- params : ...

local player = script.Parent.Parent.Parent.Parent
local count = 0
local helis = player.HeliStorage:GetChildren()
local columns = math.ceil(#helis / 11)
local row = 0
local ySize = 1 / (#helis / columns)
script.Parent:WaitForChild("Example")
for _,v in pairs(helis) do
  do
    local a = script.Parent.Example:clone()
    a.Visible = true
    a.Parent = script.Parent
    a.Name = v.Name
    if v.Value ~= false or not v.Name then
      a.Text = v.Name .. " (Single use)"
      a.Size = UDim2.new(1 / columns, 0, ySize, 0)
      a.Position = UDim2.new(count % columns * 1 / columns, 0, row * ySize, 0)
      count = count + 1
      if (count) % columns ~= 0 or not row + 1 then
        do
          a.MouseButton1Click:connect(function()
  
  Workspace.SpawnPads.SpawnHeli:FireServer(v.Name, script.Parent.Parent.Pad.Value, v.Value)
  script.Parent.Parent:Destroy()
end
)
          -- DECOMPILER ERROR at PC78: LeaveBlock: unexpected jumping out IF_THEN_STMT

          -- DECOMPILER ERROR at PC78: LeaveBlock: unexpected jumping out IF_STMT

          -- DECOMPILER ERROR at PC78: LeaveBlock: unexpected jumping out IF_THEN_STMT

          -- DECOMPILER ERROR at PC78: LeaveBlock: unexpected jumping out IF_STMT

        end
      end
    end
  end
end
