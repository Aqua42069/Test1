-- CityLife (v260-v282): starts the CityLife modules in dependency order.
-- Warrants & BOLOs, recognition, plates & DAVID, traffic stops, callouts, Connections,
-- the underground, jury tampering, Elite Representation, metals & offshore, the news.
local folder = script.Parent
local Core = require(folder:WaitForChild("Core"))

local ORDER = {
	"Warrants", "Plates", "David", "Recognition", "Stops", "Callouts", "CaseFile", "Extraction",
	"Connections", "Underground", "Jury", "Elite", "Money", "News",
}
local started = {}
for _, name in ORDER do
	local m = folder:FindFirstChild(name)
	if m and m:IsA("ModuleScript") then
		local ok, mod = pcall(require, m)
		if ok and type(mod) == "table" and mod.init then
			local okI, err = pcall(mod.init, Core)
			if okI then
				table.insert(started, name)
			else
				warn(("[CityLife] %s failed to start: %s"):format(name, tostring(err)))
			end
		else
			warn(("[CityLife] %s failed to load: %s"):format(name, tostring(mod)))
		end
	end
end
print(("[CityLife] v%d running: %s"):format(Core.VERSION, table.concat(started, ", ")))
