-- params : ...

wait(2)
while _G.newsStories == nil do
  wait()
end
local updates = _G.newsStories
findMaxSize = function()
  
  local highestY = 0
  for _,v in pairs(script.Parent.Scroller:GetChildren()) do
    if highestY < v.Position.Y.Offset + v.Size.Y.Offset then
      highestY = v.Position.Y.Offset + v.Size.Y.Offset
    end
  end
  script.Parent.Scroller.CanvasSize = UDim2.new(1, 0, 0, highestY)
end

updateStories = function()
  
  for i,v in pairs(updates) do
    local headLine = v[1]
    do
      local story = v[2]
      local image = v[3]
      local newStory = script.Example:clone()
      newStory.Parent = script.Parent.Scroller
      newStory.NewsImage.Image = image
      newStory.NewsName.Text = headLine
      newStory.Position = UDim2.new(0, 0, 0, 30 * (i - 1))
      local isOpen = false
      local storyFrame = nil
      newStory.View.MouseButton1Click:connect(function()
    
    isOpen = not isOpen
    if isOpen then
      for _,v in pairs(script.Parent.Scroller:GetChildren()) do
        if newStory.Position.Y.Offset < v.Position.Y.Offset then
          v.Position = v.Position + UDim2.new(0, 0, 0, 60)
        end
      end
      storyFrame = script.Story:clone()
      storyFrame.Parent = script.Parent.Scroller
      storyFrame.StoryLabel.Text = story
      storyFrame.Position = newStory.Position + UDim2.new(0, 0, 0, 30)
      wait(0.1)
      storyFrame.StoryLabel.Size = UDim2.new(1, -12, 0, 28 + 20 * math.ceil(storyFrame.StoryLabel.TextBounds.X / storyFrame.StoryLabel.AbsoluteSize.X))
      storyFrame.CanvasSize = storyFrame.StoryLabel.Size
      storyFrame.StoryLabel.TextWrapped = true
      findMaxSize()
    else
      for _,v in pairs(script.Parent.Scroller:GetChildren()) do
        if newStory.Position.Y.Offset < v.Position.Y.Offset then
          v.Position = v.Position + UDim2.new(0, 0, 0, -60)
        end
      end
      storyFrame:Destroy()
      storyFrame = nil
      findMaxSize()
    end
  end
)
    end
  end
  findMaxSize()
end

updateStories()
while wait(301) do
  updateStories()
end
