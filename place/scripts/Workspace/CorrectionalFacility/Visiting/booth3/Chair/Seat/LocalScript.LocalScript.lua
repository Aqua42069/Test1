-- Saved by UniversalSynSaveInstance (Join to Copy Games) https://discord.gg/wx4ThpAsmw

-- https://lua.expert/
function onChange() --[[ onChange | Line: 1 ]]
	print(script.Parent.Occupant.Parent.Name)

	if script.Parent.Occupant == "" then
		game:GetService("ReplicatedStorage").playerVisit.endVisit:FireServer(script.Parent.Parent.Parent.Name, script.Parent.Parent.Parent.Inmate.Value, script.Parent.Parent.Parent.Visitor.Value)

		return
	end

	if script.Parent.Occupant.Parent.Name ~= script.Parent.Parent.Parent.Visitor.Value then
		return
	end

	game.Workspace[script.Parent.Occupant.Parent.Name].JumpPower = 0
	game:GetService("ReplicatedStorage").playerVisit.giveGui:FireServer(script.Parent.Parent.Parent.Name, script.Parent.Occupant.Parent.Name)
end
script.Parent.Changed:connect(onChange)