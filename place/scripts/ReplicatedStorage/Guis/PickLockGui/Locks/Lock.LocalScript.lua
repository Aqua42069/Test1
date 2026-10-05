-- Lockpicking minigame (cleaned up). Click "Unlock Tumbler" (or Space) while the
-- rising bar's tip is inside the green zone. Beat every tumbler to open the door.
-- Missing resets the lock, and each miss has a 1 in 6 chance to snap the pick.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local locks = script.Parent
local gui = locks.Parent
local events = ReplicatedStorage:WaitForChild("Events")
local complexity = locks:WaitForChild("Complexity").Value
local template = locks:WaitForChild("Tumbler")
local unlockButton = locks:WaitForChild("Unlock")
local active = locks:WaitForChild("ActiveTumbler")

events.AnchorPlayer:FireServer(true)

local tumblers = {}
local width = 1 / math.max(complexity, 1)
local prisonLock=complexity>=16
for i = 1, complexity do
	local t = template:Clone()
	t.Name = "Tumbler" .. i
	t.Position = UDim2.new((i - 1) * width, 0, 0, 0)
	t.Size = UDim2.new(width, 0, 0.8, 0)
	t.Visible = true
	-- Every tumbler is different: its own sweep speed, zone height and zone size.
	-- v241: 12+ tumblers (city jail) sit between staff doors and the prison
	local jailLock = not prisonLock and complexity >= 12
	t:SetAttribute("SweepTime", if prisonLock then 0.48 + math.random() * 0.62 elseif jailLock then 0.52 + math.random() * 0.75 else 0.55 + math.random() * 0.9) -- seconds bottom->top
	local zone = t.UnlockZone
	local zoneSize = if prisonLock then 0.065 + math.random() * 0.045 elseif jailLock then 0.085 + math.random() * 0.06 else 0.1 + math.random() * 0.08
	zone.Size = UDim2.new(1, 0, zoneSize, 0)
	local top = math.floor(8)
	local bottom = math.floor((0.85 - zoneSize) * 100)
	zone.Position = UDim2.new(0, 0, math.random(top, math.max(bottom, top)) / 100, 0)
	t.Parent = locks
	tumblers[i] = t
end

local index = 1
local function activate(i)
	for j, t in ipairs(tumblers) do
		t.SlideScript.Disabled = j ~= i
		if j ~= i and j > i then
			t.Slider.Size = UDim2.new(1, 0, 0, 0)
		end
	end
	index = i
	active.Value = tumblers[i]
end
activate(1)

local function tipInZone(t)
	local tip = 1 + t.Slider.Size.Y.Scale -- slider grows upward from the bottom
	local zone = t.UnlockZone
	return tip > zone.Position.Y.Scale and tip < zone.Position.Y.Scale + zone.Size.Y.Scale
end

local done = false
local function press()
	if done then
		return
	end
	local t = tumblers[index]
	if tipInZone(t) then
		t.SlideScript.Disabled = true
		if index < #tumblers then
			activate(index + 1)
		else
			done = true
			unlockButton.Text = "Unlocked!"
			events.DoorOpening:FireServer(gui.Door.Value, true)
			task.wait(1.8)
			events.AnchorPlayer:FireServer(false)
			gui:Destroy()
		end
	else
		if math.random(1, 6) == 1 then
			done = true
			unlockButton.Text = "The pick snapped!"
			events.RemoveTool:FireServer("Lockpick")
			events.AnchorPlayer:FireServer(false)
			task.wait(1)
			gui:Destroy()
			return
		end
		unlockButton.Text = "Missed - start over"
		for _, other in ipairs(tumblers) do
			other.Slider.Size = UDim2.new(1, 0, 0, 0)
		end
		activate(1)
		task.wait(0.8)
		if not done then
			unlockButton.Text = "Unlock Tumbler"
		end
	end
end
unlockButton.MouseButton1Down:Connect(press)
game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Space then
		press()
	end
end)
