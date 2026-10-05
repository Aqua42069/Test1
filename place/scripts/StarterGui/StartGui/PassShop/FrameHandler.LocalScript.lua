-- Game Pass Shop panel contents (rewritten). Open/close is handled by SideMenu.Play/FrameTween.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local frame = script.Parent

local items = {
	{"Support Sign", 331263718, "Price: R$150\n Gives a sign to display images and text."},
	{"Tax Avoidance", 163868289, "Price: R$150\n 30% increase in income"},
	{"Street Racer", 163870680, "Price: R$100\n Allows you to race against Tito"},
	{"Body Armour", 163870271, "Price: $100\n Gives 100% increase to start health"},
	{"Aircraft Discount", 233309004, "Price: R$200\n Gives 20% discount at Jiheli Aircraft"},
	{"Dealership Discount", 163872567, "Price: R$150\n Gives 20% discount at YBCN"},
	{"Marksman Discount", 163868735, "Price: R$150\n Gives 20% discount at BB&B"},
	{"Advertiser", 163869634, "Price: R$150\n Allows you to advertise on in-game billboards for a small in-game fee"},
	{"Casino Access", 152908304, "Price: R$250\n Gives access to casino"},
	{"Airport Access", 163874000, "Price: R$100\n Allows access to the airport runway"},
	{"Sidearm", 152909903, "Price: R$250\n Start with an M9"},
	{"Spray Can", 240988085, "Price: R$250\n Start with an Spray Can"},
	{"Pilot License", 233311030, "Price: R$750\n Gives the ability to purchase and fly aircraft"},
	{"Novelty Car Package", 152925921, "Price: R$100\n Unlock novelty cars at YBCN"},
	{"Luxury Car Package", 170982772, "Price: R$150\n Unlock luxury cars at YBCN"},
	{"Posh Car Package", 445823461, "Price: R$250\n Unlock posh cars at YBCN"},
	{"British Car Package", 445822584, "Price: R$200\n Unlock british cars at YBCN"},
	{"Commercial Car Package", 445823012, "Price: R$250\n Unlock commercial cars at YBCN"},
	{"RV Package", 346581454, "Price: R$300\n Unlock RVs at YBCN"},
	{"Permanent Sedan", 163872015, "Price: R$300\n Have a permanent Sedan to drive around"},
	{"Permanent SUV", 163867182, "Price: R$320\n Have a permanent SUV to drive around"},
	{"Permanent Pickup", 163871571, "Price: R$290\n Have a permanent Pickup to drive around"},
	{"Permanent Van", 152919633, "Price: R$280\n Have a permanent Van to drive around"},
	{"Permanent Sports Car", 154605834, "Price: R$600\n Have a permanent Sports Car to drive around"}
}

local columns = 5
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
		image.Image = "rbxthumb://type=GamePass&id=" .. item[2] .. "&w=150&h=150"
	end)
end

frame:WaitForChild("BuyPass").MouseButton1Click:Connect(function()
	local id = currentBuy.Value
	if id <= 0 then
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, id)
	end)
	if not ok then
		warn("[Game Pass Shop] purchase prompt failed for", id, err)
	end
end)
