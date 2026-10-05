--[[
	CustodySync (v286z) - keeps a prisoner's own screen where the server has them.

	Seen in play: cuffed (the server anchors the HumanoidRootPart) and then moved by the server -
	the ride to the courthouse, walks, placements - the player's OWN client kept the character at
	the old spot (Police HQ) while the server had it in court holding 2,400 studs away. Attributes
	still replicated; the anchored root's CFrame did not reach the owning client.

	So while a player is in custody (CustodyStage set, or anchored by the police), the server
	publishes the root's CFrame as the player attribute ServerRootCF (10x a second, when it moves);
	CustodyPinClient snaps the local character to it when the two disagree.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local last: { [Player]: CFrame } = {}
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.1 then return end
	acc = 0
	for _, p in Players:GetPlayers() do
		local ch = p.Character
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		local inCustody = p:GetAttribute("CustodyStage") ~= nil or (hum and hum:GetAttribute("PoliceCuffed") == true)
		if root and root:IsA("BasePart") and inCustody then
			local cf = root.CFrame
			local prev = last[p]
			if not prev or (prev.Position - cf.Position).Magnitude > 0.3 or prev.LookVector:Dot(cf.LookVector) < 0.995 then
				last[p] = cf
				p:SetAttribute("ServerRootCF", cf)
			end
			p:SetAttribute("ServerRootAnchored", root.Anchored)
		elseif last[p] or p:GetAttribute("ServerRootCF") ~= nil then
			last[p] = nil
			p:SetAttribute("ServerRootCF", nil)
			p:SetAttribute("ServerRootAnchored", nil)
		end
	end
end)
Players.PlayerRemoving:Connect(function(p) last[p] = nil end)
print("[CustodySync] v286z ready")
