-- params : ...

local crimeNames = {"All", "Abuse of Tools", "Accessory to murder", "AoS", "Arson", "Assault of Federal Agent", "Assault of Police Officer", "Attempted murder", "Exploiting", "Grand Theft Auto", "Jaywalking", "Harassment", "Hate crime", "Illegal weapon", "Kidnapping", "Misdemeanor", "Murder", "Obstruction of Justice", "Reckless driving", "Robbery", "Speeding", "Threatening behaviour", "Trespassing", "Vandalism", "Other"}
local daysInMonth = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
local months = {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
local monthToNumber = {January = 1, February = 2, March = 3, April = 4, May = 5, June = 6, July = 7, August = 8, September = 9, October = 10, November = 11, December = 12}
local frameNumber = 1
local ySize = 1 / #crimeNames
local currentTab = {}
local currentCrime, crimeDetails = nil, nil
local playerName = "Unknown"
local timeForRed = 0
local counting = false
formatDate = function(t)
  
  local DST = 0
  local y = math.floor(1970 + t / 31556926)
  local ds = (1970 + t / 31556926 - y) * 31556926
  local m = math.floor(ds / 2629743) + 1
  local d = math.floor(ds / 86400) + 1
  local md = math.floor((ds / 2629743 + 1 - m) * daysInMonth[m])
  local wd = d % 7 + 6
  if m == 11 then
    DST = 0
  else
    DST = 1
  end
  if m == 3 then
    if md >= 14 then
      DST = 1
    else
      DST = 0
    end
  end
  if m == 11 then
    if md >= 7 then
      DST = 0
    else
      DST = 1
    end
  end
  local h = math.floor(t % 86400 / 3600)
  local mn = math.floor(t % 86400 / 60 - 60 * h)
  local s = math.floor(t % 86400 % 60)
  if mn <= 9 or not mn then
    return h .. ":" .. "0" .. mn .. " | " .. md .. " " .. months[m] .. " " .. y
  end
end

tempMessage = function(msg)
  
  script.Parent.Parent.Title.Text = msg
  timeForRed = 3
  if not counting then
    counting = true
    script.Parent.Parent.Title.TextColor3 = Color3.new(0.76862745098039, 0.15686274509804, 0.10980392156863)
    while timeForRed > 0 do
      wait(1)
      timeForRed = timeForRed - 1
    end
    script.Parent.Parent.Title.Text = "Las Vegas Arrest Database"
    script.Parent.Parent.Title.TextColor3 = Color3.new(1, 1, 1)
    counting = false
  end
end

updateGui = function()
  
  local tab = currentTab[frameNumber]
  if tab then
    script.Parent.Info.CriminalName.Text = "Name: " .. playerName
    script.Parent.Info.ArrestNumber.Text = "Arrest number: " .. frameNumber .. "/" .. #currentTab
    script.Parent.Info.Reason.Text = "Reason: " .. tab[4]
    script.Parent.Info.Date.Text = "Date: " .. formatDate(tab[1])
    script.Parent.Info.ArresterName.Text = "Arrester: " .. tab[2]
    script.Parent.Info.ArresterImage.Image = "http://www.roblox.com/Thumbs/Avatar.ashx?x=200&y=200&Format=Png&username=" .. tab[2]
    if type(tab[3]) == "string" and tab[3] ~= "" then
      script.Parent.Info.Reason.Text = script.Parent.Info.Reason.Text .. " | Notes: " .. tab[3]
    end
  else
    script.Parent.Info.CriminalName.Text = "Name: " .. playerName
    script.Parent.Info.ArrestNumber.Text = "Arrest number: 0/0"
    script.Parent.Info.Reason.Text = "Reason: None"
    script.Parent.Info.Date.Text = "Date: Never"
    script.Parent.Info.ArresterName.Text = "Arrester: None"
    script.Parent.Info.ArresterImage.Image = ""
  end
end

updateCrimeNumbers = function()
  
  for _,crimeName in pairs(crimeNames) do
    local counter = 0
    if not crimeDetails[crimeName] or not #crimeDetails[crimeName] then
      counter = crimeName == "All" or 0
      for name,crimes in pairs(crimeDetails) do
        if name ~= "Tracker" then
          counter = (counter) + #crimes
        end
      end
      do
        do
          local start = string.find(script.Parent.CrimeFilters[crimeName].Text, "%(")
          script.Parent.CrimeFilters[crimeName].Text = string.sub(script.Parent.CrimeFilters[crimeName].Text, 1, start - 1) .. "(" .. counter .. ")"
          -- DECOMPILER ERROR at PC56: LeaveBlock: unexpected jumping out DO_STMT

          -- DECOMPILER ERROR at PC56: LeaveBlock: unexpected jumping out IF_THEN_STMT

          -- DECOMPILER ERROR at PC56: LeaveBlock: unexpected jumping out IF_STMT

        end
      end
    end
  end
end

getAllCrimes = function()
  
  local tab = {}
  for crimeName,crimes in pairs(crimeDetails) do
    if crimeName ~= "Tracker" then
      for _,crime in pairs(crimes) do
        table.insert(tab, {crime.Date, crime.Arrester, crime.Notes, crimeName})
      end
    end
  end
  table.sort(tab, function(a, b)
    
    do return b[1] < a[1] end
    -- DECOMPILER ERROR: 1 unprocessed JMP targets
  end
)
  currentTab = tab
  for _,v in pairs(script.Parent.CrimeFilters:GetChildren()) do
    v.BackgroundColor3 = Color3.new(0.10588235294118, 0.16470588235294, 0.2078431372549)
  end
  script.Parent.CrimeFilters.All.BackgroundColor3 = Color3.new(1, 1, 1)
  frameNumber = 1
  updateGui()
end

for i,v in pairs(crimeNames) do
  do
    local newButton = script.Parent.Back:Clone()
    do
      newButton.Text = v .. "(0)"
      newButton.Name = v
      newButton.Parent = script.Parent.CrimeFilters
      newButton.Position = UDim2.new(0, 0, (i - 1) * ySize, 0)
      newButton.Size = UDim2.new(1, 0, ySize, 0)
      if v ~= "All" then
        newButton.MouseButton1Click:connect(function()
  
  if crimeDetails[v] then
    local tab = {}
    for _,crime in pairs(crimeDetails[v]) do
      table.insert(tab, {crime.Date, crime.Arrester, crime.Notes, v})
    end
    table.sort(tab, function(a, b)
    
    do return b[1] < a[1] end
    -- DECOMPILER ERROR: 1 unprocessed JMP targets
  end
)
    currentTab = tab
    for _,v in pairs(script.Parent.CrimeFilters:GetChildren()) do
      v.BackgroundColor3 = Color3.new(0.10588235294118, 0.16470588235294, 0.2078431372549)
    end
    newButton.BackgroundColor3 = Color3.new(1, 1, 1)
    frameNumber = 1
    updateGui()
  end
end
)
      else
        do
          newButton.MouseButton1Click:connect(function()
  
  if crimeDetails then
    for _,v in pairs(script.Parent.CrimeFilters:GetChildren()) do
      v.BackgroundColor3 = Color3.new(0.10588235294118, 0.16470588235294, 0.2078431372549)
    end
    newButton.BackgroundColor3 = Color3.new(1, 1, 1)
    getAllCrimes()
  end
end
)
          -- DECOMPILER ERROR at PC151: LeaveBlock: unexpected jumping out IF_ELSE_STMT

          -- DECOMPILER ERROR at PC151: LeaveBlock: unexpected jumping out IF_STMT

        end
      end
    end
  end
end
wait()
script.Parent.Parent.Search.UserIdSearch.MouseButton1Click:connect(function()
  
  local id = tonumber(script.Parent.Parent.Search.SearchBox.Text)
  if id then
    script.Parent.Parent.Title.Text = "Loading criminal data"
    playerName = game.ReplicatedStorage.Functions.FetchCriminalData:InvokeServer(id)
    script.Parent.Parent.Title.Text = "Las Vegas Arrest Database"
    getAllCrimes()
    script.Parent.Visible = true
    script.Parent.Parent.Database.Visible = false
    updateCrimeNumbers()
  else
    tempMessage("Enter a number to search by userId")
  end
end
)
script.Parent.Parent.Search.UsernameSearch.MouseButton1Click:connect(function()
  
  local succ, id = pcall(function()
    
    return game.Players:GetUserIdFromNameAsync(script.Parent.Parent.Search.SearchBox.Text)
  end
)
  if succ and id then
    script.Parent.Parent.Title.Text = "Loading criminal data"
    playerName = game.ReplicatedStorage.Functions.FetchCriminalData:InvokeServer(id)
    script.Parent.Parent.Title.Text = "Las Vegas Arrest Database"
    getAllCrimes()
    script.Parent.Visible = true
    script.Parent.Parent.Database.Visible = false
    updateCrimeNumbers()
  end
  tempMessage("No player exists with that username")
end
)
script.Parent.Info.Next.MouseButton1Click:connect(function()
  
  if #currentTab > 0 then
    frameNumber = frameNumber % #currentTab + 1
    updateGui()
  end
end
)
script.Parent.Info.Prev.MouseButton1Click:connect(function()
  
  if #currentTab > 0 then
    frameNumber = (frameNumber - 2) % #currentTab + 1
    updateGui()
  end
end
)
local player = game:GetService("Players").LocalPlayer
local holder = script.Parent.Parent
local clipper = holder.Parent
local gui = clipper.Parent
local summary = holder:FindFirstChild("CustodySummary")
if not summary then
  summary = Instance.new("TextLabel")
  summary.Name = "CustodySummary"
  summary.BackgroundColor3 = Color3.fromRGB(18, 29, 37)
  summary.BackgroundTransparency = 0.08
  summary.BorderSizePixel = 0
  summary.TextColor3 = Color3.fromRGB(255, 224, 145)
  summary.TextSize = 17
  summary.TextWrapped = true
  summary.Font = Enum.Font.GothamSemibold
  summary.TextXAlignment = Enum.TextXAlignment.Center
  summary.TextYAlignment = Enum.TextYAlignment.Center
  summary.ZIndex = 20
  summary.Parent = holder
end
holder.Title.Position = UDim2.new(0,0,0,0); holder.Title.Size = UDim2.new(1,0,0.08,0)
summary.Position = UDim2.new(0.02,0,0.08,0); summary.Size = UDim2.new(0.96,0,0.075,0)
holder.Search.Position = UDim2.new(0,0,0.155,0); holder.Search.Size = UDim2.new(1,0,0.09,0)
holder.Database.Position = UDim2.new(0,0,0.245,0); holder.Database.Size = UDim2.new(1,0,0.755,0)
holder.CurrentCriminal.Position = UDim2.new(0,0,0.245,0); holder.CurrentCriminal.Size = UDim2.new(1,0,0.755,0)
clipper.Position = UDim2.new(0.17,0,0.055,0); clipper.Size = UDim2.new(0.66,0,0.84,0)
local toggle = gui:WaitForChild("OpenClose")
toggle.Visible = true; toggle.Position = UDim2.new(0.17,0,0,0); toggle.Size = UDim2.new(0.66,0,0.045,0)
local function refreshCustodySummary()
  local charges = player:GetAttribute("CaseCharges") or player:GetAttribute("Charges")
  local verdict = player:GetAttribute("CaseVerdict")
  local inmateClass = player:GetAttribute("SecurityClass")
  local sentence = tonumber(player:GetAttribute("SentenceSeconds"))
  local phase = player:GetAttribute("CustodyPhase") or player:GetAttribute("BookingState")
  if charges or verdict or inmateClass then
    local left = sentence and math.max(0, math.ceil(sentence)) or nil
    summary.Text = string.format("CASE: %s  |  RESULT: %s  |  CLASS: %s%s%s",
      tostring(charges or "Pending"), tostring(verdict or phase or "Pending"),
      tostring(inmateClass or "Pending"), left and "  |  SENTENCE: "..left.."s" or "",
      phase and "  |  STATUS: "..tostring(phase) or "")
  else
    summary.Text = "CASE: No active custody case"
  end
end
for _,attribute in {"CaseCharges","Charges","CaseVerdict","SecurityClass","SentenceSeconds","CustodyPhase","BookingState"} do
  player:GetAttributeChangedSignal(attribute):Connect(refreshCustodySummary)
end
refreshCustodySummary()
local open = false
local OpenClose = script.Parent.Parent.Parent.Parent:WaitForChild("OpenClose")
OpenClose.MouseButton1Click:connect(function()
  
  open = not open
  if open then
    script.Parent.Parent:TweenPosition(UDim2.new(0, 0, 0, 0), "Out", 0, 0.5, true)
    OpenClose:TweenPosition(UDim2.new(0.17, 0, 0.895, 0), "Out", 0, 0.5, true)
    OpenClose.Text = "Close Las Vegas Arrest Database"
  else
    script.Parent.Parent:TweenPosition(UDim2.new(0, 0, -1, 0), "Out", 0, 0.5, true)
    OpenClose:TweenPosition(UDim2.new(0.17, 0, 0, 0), "Out", 0, 0.5, true)
    OpenClose.Text = "Open Las Vegas Arrest Database"
  end
end
)
script.Parent:WaitForChild("Back").MouseButton1Click:connect(function()
  
  script.Parent.Visible = false
  script.Parent.Parent.Database.Visible = true
end
)
addNewCriminal = function(name)
  
  if not script.Parent.Parent.Database:FindFirstChild(name) then
    local newButton = script.CriminalButton:clone()
    newButton.Visible = true
    newButton.Parent = script.Parent.Parent.Database
    newButton.Name = name
    newButton.Text = name
    newButton.Position = UDim2.new(0, 0, 0, script.CriminalButton.Size.Y.Offset * (#script.Parent.Parent.Database:GetChildren() - 1))
    newButton.MouseButton1Click:connect(function()
    
    local succ, id = pcall(function()
      
      return game.Players:GetUserIdFromNameAsync(name)
    end
)
    if succ then
      script.Parent.Parent.Title.Text = "Loading criminal data"
      playerName = game.ReplicatedStorage.Functions.FetchCriminalData:InvokeServer(id)
      script.Parent.Parent.Title.Text = "Las Vegas Arrest Database"
      getAllCrimes()
      script.Parent.Visible = true
      script.Parent.Parent.Database.Visible = false
      updateCrimeNumbers()
    else
      tempMessage("No player with this name")
    end
  end
)
  end
end

for i,v in pairs(game.Players:GetPlayers()) do
  addNewCriminal(v.Name)
end
game.ReplicatedStorage.Events.ArrestDatabaseUpdate.OnClientEvent:connect(function(name, removing)
  
  if removing and script.Parent.Parent.Database:FindFirstChild(name) then
    for _,v in pairs(script.Parent.Parent.Database:GetChildren()) do
      if script.Parent.Parent.Database[name].Position.Y.Offset < v.Position.Y.Offset then
        v.Position = v.Position - UDim2.new(0, 0, 0, script.Parent.Parent.Database[name].Size.Y.Offset)
      end
    end
    script.Parent.Parent.Database[name]:Destroy()
  end
  addNewCriminal(name)
end
)
script.Parent.Parent.Database.CanvasSize = UDim2.new(1, 0, 0, script.CriminalButton.Size.Y.Offset * #script.Parent.Parent.Database:GetChildren())
