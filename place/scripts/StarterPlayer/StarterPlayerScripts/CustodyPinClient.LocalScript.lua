-- CustodyPinClient (v230)
-- After a reset in custody the server puts the new character in an intake cell,
-- but the player's own machine (which simulates its character) could keep that
-- character standing at its spawn point in the city - server-side teleports
-- never stuck. While the server sets the player attribute CustodyPinCF, this
-- script moves the character there from the client side too, so both agree.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

RunService.Heartbeat:Connect(function(dt)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	-- v286z: in custody, follow where the SERVER has the character (CustodySync). An anchored
	-- root moved by the server never reached this client: the screen stayed at Police HQ while
	-- the server had you in court holding. Tight while the server holds the body (anchored),
	-- loose otherwise so it never fights normal walking.
	local srv = player:GetAttribute("ServerRootCF")
	if typeof(srv) == "CFrame" then
		local d = (root.Position - srv.Position).Magnitude
		if player:GetAttribute("ServerRootAnchored") == true and root.Anchored and d > 0.2 and d < 20 then
			-- an escort walk arrives 10x a second: glide, don't stutter
			root.CFrame = root.CFrame:Lerp(srv, 1 - math.exp(-dt * 15))
		elseif d > (if player:GetAttribute("ServerRootAnchored") == true then 20 else 12) then
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = srv
		end
	end
	local pin = player:GetAttribute("CustodyPinCF")
	if typeof(pin) ~= "CFrame" then
		return
	end
	local offset = root.Position - pin.Position
	if Vector3.new(offset.X, 0, offset.Z).Magnitude > 6 or math.abs(offset.Y) > 8 then
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = pin
	end
end)
