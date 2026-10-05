-- SkidMarksRelay: the driver's client lays skid marks (CarDriveClient) and sends the
-- segments here; everyone else gets them so they see the same marks.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote = ReplicatedStorage:FindFirstChild("SkidMarks") or Instance.new("RemoteEvent")
remote.Name = "SkidMarks"
remote.Parent = ReplicatedStorage

local lastSend = {}
remote.OnServerEvent:Connect(function(player, segs)
	if type(segs) ~= "table" or #segs > 60 then return end
	local now = os.clock()
	if lastSend[player] and now - lastSend[player] < 0.15 then return end
	lastSend[player] = now
	local clean = {}
	for _, s in segs do
		if type(s) == "table" and typeof(s[1]) == "Vector3" and typeof(s[2]) == "Vector3" and typeof(s[3]) == "Vector3"
			and (s[1] - s[2]).Magnitude <= 12 then
			table.insert(clean, { s[1], s[2], s[3].Unit, math.clamp(tonumber(s[4]) or 0.8, 0.3, 1.6) })
		end
	end
	if #clean == 0 then return end
	for _, other in Players:GetPlayers() do
		if other ~= player then remote:FireClient(other, clean) end
	end
end)
Players.PlayerRemoving:Connect(function(p) lastSend[p] = nil end)
