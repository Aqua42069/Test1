-- Banking app (rewritten): send money from your bank account to another player.
-- Deposits and withdrawals are done at the ATMs around the city.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local frame = script.Parent
local scroller = frame:WaitForChild("Scroller")
local transferButton = scroller:WaitForChild("Transfer")
local confirm = scroller:WaitForChild("Confirm")
local amountBox = scroller:WaitForChild("TransAmount")
local pickButton = scroller:WaitForChild("Player")
local selecter = pickButton:WaitForChild("Selecter")
local chosen = pickButton:WaitForChild("ChosenPlayer")
local recentsLabel = scroller:WaitForChild("Recents")
local title = frame:WaitForChild("Title")
local homeIcon = frame.Parent:WaitForChild("HomeFrame"):WaitForChild("Bank")
local bankDeposit = ReplicatedStorage:WaitForChild("Functions"):WaitForChild("BankDeposit")
local moneyRequest = ReplicatedStorage:WaitForChild("Events"):WaitForChild("MoneyRequest")

local MAX_RECENTS = 6
local recent = {}
local store = player:FindFirstChild("RecentTransfers")
if store and store.Value ~= "" then
	pcall(function()
		recent = HttpService:JSONDecode(store.Value)
	end)
end

-- Layout: Transfer button, then (when open) player / amount / confirm, then recents.
local transferY = transferButton.Position.Y.Offset
local open = false

local function layout()
	pickButton.Visible = open
	amountBox.Visible = open
	confirm.Visible = open
	local y = transferY + 25
	if open then
		pickButton.Position = UDim2.new(pickButton.Position.X.Scale, pickButton.Position.X.Offset, 0, y)
		amountBox.Position = UDim2.new(amountBox.Position.X.Scale, amountBox.Position.X.Offset, 0, y + 25)
		confirm.Position = UDim2.new(confirm.Position.X.Scale, confirm.Position.X.Offset, 0, y + 50)
		y += 80
	end
	recentsLabel.Position = UDim2.new(recentsLabel.Position.X.Scale, recentsLabel.Position.X.Offset, 0, y)
	for _, child in ipairs(scroller:GetChildren()) do
		if child.Name == "TransList" then
			child:Destroy()
		end
	end
	for i, text in ipairs(recent) do
		local line = title:Clone()
		line.Name = "TransList"
		line.Size = UDim2.new(1, 0, 0, 20)
		line.Position = UDim2.new(0, 0, 0, y + 20 * i)
		line.Text = text
		line.Font = Enum.Font.SourceSans
		line.TextScaled = true
		line.TextXAlignment = Enum.TextXAlignment.Left
		line.Parent = scroller
	end
	scroller.CanvasSize = UDim2.new(0, 0, 0, y + 20 * (#recent + 1))
end

local function addRecent(text)
	table.insert(recent, 1, text)
	while #recent > MAX_RECENTS do
		table.remove(recent)
	end
	if store then
		store.Value = HttpService:JSONEncode(recent)
	end
	layout()
end

moneyRequest.OnClientEvent:Connect(function(fromPlayer, amount)
	if typeof(fromPlayer) == "Instance" then
		addRecent(fromPlayer.Name .. " sent you $" .. tostring(amount))
		if not frame.Visible then
			homeIcon.Notification.Visible = true
			homeIcon.Notification.Number.Text = tostring((tonumber(homeIcon.Notification.Number.Text) or 0) + 1)
		end
	end
end)

transferButton.MouseButton1Click:Connect(function()
	open = not open
	selecter.Visible = false
	layout()
end)

pickButton.MouseButton1Click:Connect(function()
	selecter.Visible = not selecter.Visible
	selecter:ClearAllChildren()
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local button = confirm:Clone()
			button.Name = other.Name
			button.Text = other.Name
			button.Visible = true
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.new(0, 0, 0)
			button.Position = UDim2.new(0, 0, 0, count * 20)
			button.Size = UDim2.new(1, 0, 0, 20)
			button.ZIndex = 5
			button.Parent = selecter
			count += 1
			button.MouseButton1Click:Connect(function()
				chosen.Value = other
				pickButton.Text = other.Name
				selecter.Visible = false
			end)
		end
	end
	if count == 0 then
		selecter.Visible = false
		pickButton.Text = "Nobody else online"
	end
	selecter.CanvasSize = UDim2.new(0, 0, 0, 20 * count)
end)

local busy = false
confirm.MouseButton1Click:Connect(function()
	local target = chosen.Value
	local amount = math.floor(tonumber(amountBox.Text) or 0)
	if busy or not target or amount <= 0 then
		return
	end
	busy = true
	local ok, sent = pcall(bankDeposit.InvokeServer, bankDeposit, "Transfer", amount, target)
	if ok and sent then
		confirm.Text = "Transfer successful!"
		addRecent("You sent $" .. amount .. " to " .. target.Name)
	else
		confirm.Text = "Insufficient funds!"
	end
	task.wait(2)
	confirm.Text = "Confirm"
	busy = false
end)

layout()

-- v255: a frozen account (felony money case) shows the DA's banner over the app
local frozenBanner = Instance.new("TextLabel")
frozenBanner.Name = "FrozenBanner"
frozenBanner.Size = UDim2.new(1, 0, 0, 44)
frozenBanner.BackgroundColor3 = Color3.fromRGB(150, 20, 20)
frozenBanner.TextColor3 = Color3.new(1, 1, 1)
frozenBanner.Font = Enum.Font.SourceSansBold
frozenBanner.TextScaled = true
frozenBanner.Text = "ACCOUNT FROZEN\nClark County DA"
frozenBanner.ZIndex = 10
frozenBanner.Parent = frame
local function showFrozen()
	local frozen = player:GetAttribute("AssetsFrozen") == true
	frozenBanner.Visible = frozen
	transferButton.Active = not frozen
	if frozen and open then
		open = false
		layout()
	end
end
player:GetAttributeChangedSignal("AssetsFrozen"):Connect(showFrozen)
showFrozen()
