-- params : ...

local player = game.Players.LocalPlayer
local stylecount = 0
local currentStyle = nil
local deb = false
updateStyle = function(style)
  
  script.Parent.AdStyle:ClearAllChildren()
  for _,v in pairs(style:GetChildren()) do
    v:clone().Parent = script.Parent.AdStyle
  end
  currentStyle = style.Name
end

script.Parent:WaitForChild("Example")
for _,v in pairs(game.ReplicatedStorage.AdStyles:GetChildren()) do
  do
    local size = 0.9 / #game.ReplicatedStorage.AdStyles:GetChildren()
    local a = script.Parent.Example:clone()
    a.Visible = true
    a.Parent = script.Parent.ChooseStyle
    a.Text = v.Name
    a.Size = UDim2.new(1, 0, size, 0)
    a.Position = UDim2.new(0, 0, 0.1 + size * stylecount, 0)
    stylecount = stylecount + 1
    a.MouseButton1Click:connect(function()
  
  updateStyle(v)
end
)
  end
end
do
  while #script.Parent:GetChildren() < 7 do
    wait()
  end
  script.Parent:WaitForChild("ImageId").FocusLost:connect(function()
  
  if string.sub(script.Parent.ImageId.Text, 1, 7) ~= "http://" or not script.Parent.ImageId.Text then
    script.Parent.AdStyle.Image.Image = "http://www.roblox.com/asset/?id=" .. script.Parent.ImageId.Text
  end
end
)
  script.Parent:WaitForChild("SelectThis").MouseButton1Click:connect(function()
  
  if not deb then
    deb = true
    script.Parent.SelectThis.Text = "Updated Sign"
    local adInfo = {}
    for _,v in pairs(script.Parent.AdStyle:GetChildren()) do
      if v.ClassName == "ImageLabel" then
        adInfo[v.Name] = v.Image
      else
        if v.ClassName == "TextBox" then
          adInfo[v.Name] = v.Text
        end
      end
    end
    game.ReplicatedStorage.Events.SupportSignUpdater:FireServer(currentStyle, adInfo)
    wait(1)
    deb = false
    wait(2)
    script.Parent.SelectThis.Text = "Click to display on your sign"
  end
end
)
  local open = false
  script.Parent.OpenClose.MouseButton1Click:connect(function()
  
  open = not open
  if open then
    script.Parent:TweenPosition(UDim2.new(0, 0, 0.25, 0), 0, 0, 0.3, true)
    script.Parent.OpenClose.Text = "Close support GUI"
  else
    script.Parent:TweenPosition(UDim2.new(-0.5, 0, 0.25, 0), 0, 0, 0.3, true)
    script.Parent.OpenClose.Text = "Open support GUI"
  end
end
)
  updateStyle(game.ReplicatedStorage.AdStyles.Style1)
end
