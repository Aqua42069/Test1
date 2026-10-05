-- params : ...

wait(1)
local player = script.Parent.Parent.Parent.Parent.Parent.Parent
if not player:FindFirstChild("MyMusic") then
  script.Parent.MyMusic:clone().Parent = player
end
player.MyMusic:Stop()
local music = game.ReplicatedStorage.Functions.GetMusic:InvokeServer()
local count = 0
local playImage = "rbxassetid://258461974"
local stopImage = "rbxassetid://258461995"
script.Parent.Play.MouseButton1Click:connect(function()
  
  if script.Parent.Play.Image == playImage then
    script.Parent.Play.Image = stopImage
    player.MyMusic:Play()
  else
    script.Parent.Play.Image = playImage
    player.MyMusic:Stop()
  end
end
)
for i,v in pairs(music) do
  do
    local button = script.Parent.ExampleButton:clone()
    do
      local pos = count
      button.Font = "SourceSansBold"
      button.Text = i
      button.Name = count
      button.Position = UDim2.new(0, 0, 0, count * 20)
      button.Parent = script.Parent.Scroller
      button.Visible = true
      count = count + 1
      local open = false
      button.MouseButton1Click:connect(function()
  
  open = not open
  if open then
    for _,a in pairs(script.Parent.Scroller:GetChildren()) do
      do
        if button.Position.Y.Offset < a.Position.Y.Offset then
          do
            a.Position = a.Position + UDim2.new(0, 0, 0, 20 * #v)
            -- DECOMPILER ERROR at PC35: LeaveBlock: unexpected jumping out IF_THEN_STMT

            -- DECOMPILER ERROR at PC35: LeaveBlock: unexpected jumping out IF_STMT

          end
        end
      end
    end
    for q,w in pairs(v) do
      local songButton = script.Parent.ExampleButton:clone()
      songButton.Name = w[1]
      songButton.Text = " - " .. w[1]
      songButton.Position = button.Position + UDim2.new(0, 0, 0, 20 * q)
      songButton.Parent = script.Parent.Scroller
      songButton.Visible = true
      songButton.MouseButton1Click:connect(function()
    
    script.Parent.Current.Text = "Current song: " .. w[1]
    player.MyMusic:Stop()
    player.MyMusic.SoundId = "http://www.roblox.com/asset/?id=" .. w[2]
    player.MyMusic:Play()
    script.Parent.Play.Image = stopImage
  end
)
    end
    script.Parent.Scroller.CanvasSize = UDim2.new(1, 0, 0, #script.Parent.Scroller:GetChildren() * 20)
  else
    for _,b in pairs(script.Parent.Scroller:GetChildren()) do
      for _,w in pairs(v) do
        if w[1] == b.Name then
          b:Destroy()
        end
      end
    end
    for _,a in pairs(script.Parent.Scroller:GetChildren()) do
      if button.Position.Y.Offset < a.Position.Y.Offset then
        a.Position = a.Position + UDim2.new(0, 0, 0, -20 * #v)
      end
    end
    script.Parent.Scroller.CanvasSize = UDim2.new(1, 0, 0, #script.Parent.Scroller:GetChildren() * 20)
  end
end
)
    end
  end
end
script.Parent.Scroller.CanvasSize = UDim2.new(1, 0, 0, #script.Parent.Scroller:GetChildren() * 20)
