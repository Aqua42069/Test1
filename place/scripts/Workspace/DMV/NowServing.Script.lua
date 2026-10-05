-- the DMV's NOW SERVING board: a new number every few seconds
local board = script.Parent:FindFirstChild("NowServing", true)
local label = board and board:FindFirstChildWhichIsA("TextLabel", true)
local n = 100
while label do
	task.wait(math.random(8, 16))
	n += 1
	local letter = ({ "A", "B", "C" })[math.random(1, 3)]
	label.Text = ("NOW SERVING  %s-%d  >  WINDOW %d"):format(letter, n, math.random(1, 7))
end
