-- Meds app (rewritten). The server charges you and applies the effect.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local frame = script.Parent
local example = script:WaitForChild("Example")
local scroller = frame:WaitForChild("Scroller")
local confirm = frame:WaitForChild("Confirm")
local functions = ReplicatedStorage:WaitForChild("Functions")
local getMeds = functions:WaitForChild("GetMedicines")
local buyMed = functions:WaitForChild("BuyMedicine")

local ROW = 30
local selected = nil
local busy = false

local function showList()
	selected = nil
	confirm.Visible = false
	scroller.Visible = true
end

local loaded = false
local function build()
	if loaded then
		return
	end
	local ok, list = pcall(getMeds.InvokeServer, getMeds)
	if not ok or type(list) ~= "table" then
		warn("[Meds] couldn't load the medicine list:", list)
		return
	end
	loaded = true
	for i, med in ipairs(list) do
		local row = example:Clone()
		row.Name = med.name
		row.Position = UDim2.new(0, 0, 0, ROW * (i - 1))
		row.MedName.Text = med.name
		row.MedDesc.Text = med.desc
		row.MedPrice.Text = "Price: $" .. med.price
		row.Visible = true
		row.Parent = scroller
		row.Buy.MouseButton1Click:Connect(function()
			selected = med
			confirm.MedName.Text = med.name
			confirm.MedPrice.Text = "Price: $" .. med.price
			confirm.Buy.Text = "Buy this Medicine"
			scroller.Visible = false
			confirm.Visible = true
		end)
	end
	scroller.CanvasSize = UDim2.new(0, 0, 0, ROW * #list)
end

frame:GetPropertyChangedSignal("Visible"):Connect(function()
	if frame.Visible then
		showList()
		build()
	end
end)
task.spawn(build)

confirm.Buy.MouseButton1Click:Connect(function()
	if not selected or busy then
		return
	end
	busy = true
	local called, ok, message = pcall(buyMed.InvokeServer, buyMed, selected.name)
	confirm.Buy.Text = called and tostring(message) or "Pharmacy is offline"
	if called and ok then
		loaded = false -- refresh so "owned" style items can be re-checked later if needed
	end
	task.wait(2.5)
	busy = false
	showList()
end)
confirm.Cancel.MouseButton1Click:Connect(showList)
