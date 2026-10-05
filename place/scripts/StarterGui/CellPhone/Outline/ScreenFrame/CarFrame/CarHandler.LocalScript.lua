-- YBCN car shop app (rewritten). Prices, pass checks and payment all happen on
-- the server (EconomyServer); keys appear in your backpack once bought.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local frame = script.Parent
local example = script:WaitForChild("Example")
local scroller = frame:WaitForChild("Scroller")
local confirm = frame:WaitForChild("Confirm")
local functions = ReplicatedStorage:WaitForChild("Functions")
local getCatalog = functions:WaitForChild("GetCarCatalog")
local buyCar = functions:WaitForChild("BuyCar")

local ROW = 30
local selected = nil
local busy = false

local function thumb(image)
	local id = tostring(image):match("%d+")
	return id and ("rbxthumb://type=Asset&id=" .. id .. "&w=150&h=150") or ""
end

local function showList()
	selected = nil
	confirm.Visible = false
	scroller.Visible = true
end

local function build()
	local ok, list = pcall(getCatalog.InvokeServer, getCatalog)
	if not ok or type(list) ~= "table" then
		return
	end
	for _, child in ipairs(scroller:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for i, car in ipairs(list) do
		local row = example:Clone()
		row.Name = car.name
		row.Position = UDim2.new(0, 0, 0, ROW * (i - 1))
		row.CarImage.Image = thumb(car.image)
		row.CarName.Text = car.name
		row.Locked.Visible = not car.unlocked
		local status
		if car.owned then
			status = "Owned"
		elseif not car.available then
			status = "Out of stock"
		elseif not car.unlocked then
			status = "Needs " .. tostring(car.package)
		else
			status = "Price: $" .. car.price
		end
		row.CarPrice.Text = status
		row.Visible = true
		row.Parent = scroller
		row.Buy.MouseButton1Click:Connect(function()
			if car.owned or not car.available or not car.unlocked then
				return
			end
			selected = car
			confirm.CarImage.Image = thumb(car.image)
			confirm.CarName.Text = car.name
			confirm.CarPrice.Text = "Price: $" .. car.price
			confirm.Buy.Text = "Buy this Car"
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
	local ok, success, message = pcall(buyCar.InvokeServer, buyCar, selected.name)
	confirm.Buy.Text = ok and tostring(message) or "Shop is offline"
	task.wait(2)
	busy = false
	showList()
	build()
end)
confirm.Cancel.MouseButton1Click:Connect(showList)

frame:GetPropertyChangedSignal("Visible"):Connect(function()
	if frame.Visible then
		showList()
		build()
	end
end)
build()
