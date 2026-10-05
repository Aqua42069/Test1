-- params : ...

local topBar = script.Parent
local p = script.Parent.Parent.Parent.Parent
game.ReplicatedStorage.Events.TopBarColor.OnClientEvent:connect(function()
  
  topBar.BackgroundColor3 = Color3.new(0.050980392156863 + p.TeamColor.r, 0.082352941176471 + p.TeamColor.g, 0.10196078431373 + p.TeamColor.b)
end
)
wait(1)
topBar.BackgroundColor3 = Color3.new(0.050980392156863 + p.TeamColor.r, 0.082352941176471 + p.TeamColor.g, 0.10196078431373 + p.TeamColor.b)
