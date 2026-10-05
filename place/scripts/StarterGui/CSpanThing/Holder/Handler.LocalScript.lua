-- params : ...

wait(1)
-- v293: the board streams in and out (StreamingEnabled) - re-attach whenever it arrives
local function bindBoard()
  local board = Workspace:FindFirstChild("CSpanNews")
  if board then script.Parent.Parent.Adornee = board end
end
bindBoard()
Workspace.ChildAdded:Connect(function(c) if c.Name == "CSpanNews" then bindBoard() end end)
local transferUpdates = {}
updateGui = function()
  
  transferUpdates = {}
  script.Parent.StoryHolder:ClearAllChildren()
  local updates = game.ReplicatedStorage.Functions.HttpGet:InvokeServer("https://api.trello.com/1/boards/PFBV8kJG/lists?fields=name&cards=open&card_fields=name,desc")
  if updates ~= "" then
    local counter = 0
    do
      for _,card in pairs(updates[2].cards) do
        local headLine = card.name
        do
          local story = card.desc
          local imageLink = "rbxassetid://184928675"
          local cardComments = game.ReplicatedStorage.Functions.HttpGet:InvokeServer("https://api.trello.com/1/cards/" .. card.id .. "/actions?filter=commentCard")
          if cardComments ~= "" and #cardComments > 0 then
            imageLink = cardComments[#cardComments].data.text
          end
          table.insert(transferUpdates, {headLine, story, imageLink})
          local newFrame = script.Parent.BarExample:clone()
          newFrame.Parent = script.Parent.StoryHolder
          newFrame.Visible = true
          newFrame.Position = UDim2.new(0, 0, counter * 0.2, 0)
          newFrame.StoryImage.Image = imageLink
          newFrame.Headline.Text = headLine
          newFrame.Story.Text = string.len(story) > 58 and string.sub(story, 1, 58) .. "..." or story
          newFrame.Clicker.MouseButton1Click:connect(function()
    
    script.Parent.MainStory.StoryImage.Image = imageLink
    script.Parent.MainStory.Headline.Text = headLine
    script.Parent.MainStory.Story.Text = story
    script.Parent.StoryHolder:TweenPosition(UDim2.new(-1, 0, 0.2, 0), 0, 1, 0.5, true)
    script.Parent.MainStory:TweenPosition(UDim2.new(0, 0, 0.2, 0), 0, 1, 0.5, true)
  end
)
          counter = counter + 1
          if counter >= 5 then
            do
              do break end
              -- DECOMPILER ERROR at PC107: LeaveBlock: unexpected jumping out IF_THEN_STMT

              -- DECOMPILER ERROR at PC107: LeaveBlock: unexpected jumping out IF_STMT

            end
          end
        end
      end
    end
  end
  do
    _G.newsStories = transferUpdates
  end
end

script.Parent.MainStory.X.MouseButton1Click:connect(function()
  
  script.Parent.StoryHolder:TweenPosition(UDim2.new(0, 0, 0.2, 0), 0, 1, 0.5, true)
  script.Parent.MainStory:TweenPosition(UDim2.new(1, 0, 0.2, 0), 0, 1, 0.5, true)
end
)
wait(1)
updateGui()
spawn(function()
  
  while wait(300) do
    updateGui()
  end
end
)
