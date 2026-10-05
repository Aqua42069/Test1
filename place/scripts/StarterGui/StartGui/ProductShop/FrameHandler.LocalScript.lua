-- Product Shop panel contents (rewritten). Open/close is handled by SideMenu.Play/FrameTween.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local frame = script.Parent

local items = {
	{"+1000 Money", 20320803, "Price: R$9\n Get an extra 1000 money", "rbxassetid://152442994"},
	{"+10000 Money", 20320835, "Price: R$80\n Get an extra 10000 money", "rbxassetid://152443008"},
	{"+100000 Money", 20320851, "Price: R$700\n Get an extra 100000 money", "rbxassetid://157741166"},
	{"Clear Arrests", 20320895, "Price: R$250\n Clear all your arrests", "rbxassetid://152443024"}
}

local columns = 2
local rows = math.ceil(#items / columns)
local cellSize = UDim2.new(1 / columns, 0, 1 / rows, 0)

local example = frame:WaitForChild("Example")
local holder = frame:WaitForChild("PassHolder")
local currentBuy = frame:WaitForChild("CurrentBuy")
local desc = frame:WaitForChild("PassDesc")
local image = frame:WaitForChild("PassImage")

for index, item in ipairs(items) do
	local i = index - 1
	local button = example:Clone()
	button.Name = item[1]
	button.Text = item[1]
	button.Size = cellSize
	button.Position = UDim2.new((i % columns) / columns, 0, math.floor(i / columns) / rows, 0)
	button.Visible = true
	button.Parent = holder
	button.MouseButton1Click:Connect(function()
		currentBuy.Value = item[2]
		desc.Text = item[3]
		image.Image = item[4]
	end)
end

frame:WaitForChild("BuyPass").MouseButton1Click:Connect(function()
	local id = currentBuy.Value
	if id <= 0 then
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, id)
	end)
	if not ok then
		warn("[Product Shop] purchase prompt failed for", id, err)
	end
end)
