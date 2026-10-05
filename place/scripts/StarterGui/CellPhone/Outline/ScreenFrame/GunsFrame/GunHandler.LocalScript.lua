-- BB&B gun shop app (rewritten). The server charges you and puts the gun in
-- your backpack (you keep it after respawning). Hold click to fire, R to reload.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local frame = script.Parent
local example = script:WaitForChild("Example")
local scroller = frame:WaitForChild("Scroller")
local confirm = frame:WaitForChild("Confirm")
local functions = ReplicatedStorage:WaitForChild("Functions")
local getCatalog = functions:WaitForChild("GetGunCatalog")
local buyGun = functions:WaitForChild("BuyGun")

local ROW = 30
local selected, busy, loaded = nil, false, false

local function showList()
	selected = nil
	confirm.Visible = false
	scroller.Visible = true
end

local function build()
	if loaded then
		return
	end
	local ok, list = pcall(getCatalog.InvokeServer, getCatalog)
	if not ok or type(list) ~= "table" then
		warn("[BB&B] couldn't load the gun list:", list)
		return
	end
	loaded = true
	for i, item in ipairs(list) do
		local row = example:Clone()
		row.Name = item.name
		row.Position = UDim2.new(0, 0, 0, ROW * (i - 1))
		row.GunImage.Image = item.image
		row.GunName.Text = item.name
		row.GunPrice.Text = ("$%d  (%s)"):format(item.price, item.stats)
		row.Visible = true
		row.Parent = scroller
		row.Buy.MouseButton1Click:Connect(function()
			selected = item
			confirm.GunImage.Image = item.image
			confirm.GunName.Text = item.name
			confirm.GunPrice.Text = "Price: $" .. item.price
			confirm.Buy.Text = "Buy this gun"
			scroller.Visible = false
			confirm.Visible = true
		end)
	end
	scroller.CanvasSize = UDim2.new(0, 0, 0, ROW * #list)
end

confirm.Buy.MouseButton1Click:Connect(function()
	if not selected or busy then
		return
	end
	busy = true
	local called, _, message = pcall(buyGun.InvokeServer, buyGun, selected.name)
	confirm.Buy.Text = called and tostring(message) or "Shop is closed"
	task.wait(2.5)
	busy = false
	showList()
end)
confirm.Cancel.MouseButton1Click:Connect(showList)

frame:GetPropertyChangedSignal("Visible"):Connect(function()
	if frame.Visible then
		showList()
		build()
	end
end)
task.spawn(build)
