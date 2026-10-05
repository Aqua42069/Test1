-- params : ...

wait(2)
local frames = {script.Parent.HomeFrame}
for _,v in pairs(script.Parent:GetChildren()) do
  do
    if v.ClassName == "Frame" and v.Name ~= "PermFrame" and v.Name ~= "PayFrame" and v.Name ~= "HomeFrame" then
      do
        table.insert(frames, v)
        v.Home.MouseButton1Click:connect(function()
  
  for _,q in pairs(frames) do
    q.Visible = false
  end
  script.Parent.HomeFrame.Visible = true
end
)
        -- DECOMPILER ERROR at PC38: LeaveBlock: unexpected jumping out IF_THEN_STMT

        -- DECOMPILER ERROR at PC38: LeaveBlock: unexpected jumping out IF_STMT

      end
    end
  end
end
for _,v in pairs(script.Parent.HomeFrame:GetChildren()) do
  v.MouseButton1Click:connect(function()
  
  script.Parent.HomeFrame.Visible = false
  script.Parent[v.Name .. "Frame"].Visible = true
  v.Notification.Visible = false
  v.Notification.Number.Text = "0"
end
)
end
