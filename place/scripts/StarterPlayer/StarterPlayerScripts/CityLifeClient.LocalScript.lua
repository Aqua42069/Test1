--[[
	CityLifeClient (v260-v282)
	  * phone apps: CONNECTIONS (fixers, lawyers, money, the jury), MDT (police: DAVID lookups,
	    warrants, BOLOs, callouts, backup), NEWS (stories, most wanted, WATCH LIVE)
	  * recognition meters ("?" over the officer who's working out who you are)
	  * traffic stops: B (or the STOP button on mobile) while driving as police
	  * prompts only the right person sees (your plates, your juror, police-only)
	  * the breaking-news banner and the live broadcast (auto-director camera)
	Everything is sized for a phone too (UIScale, 44px+ touch targets).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local RE = ReplicatedStorage:WaitForChild("CityLife") :: RemoteEvent
local RF = ReplicatedStorage:WaitForChild("CityLifeFn") :: RemoteFunction

local LAW = {
	["LVPD"] = true, ["SWAT"] = true, ["Federal Bureau of Investigation"] = true, ["U.S. Marshal Service"] = true,
	["USM"] = true, ["Secret Service"] = true, ["Homeland Security"] = true, ["Federal Protection Service"] = true,
	["Special Forces"] = true, ["Dept. of Justice"] = true, ["Prison Staff"] = true,
	["National Security Agency"] = true, ["Central Intelligence Agency"] = true, ["Chief of Police"] = true,
}
local MDT = {
	["LVPD"] = true, ["SWAT"] = true, ["Federal Bureau of Investigation"] = true, ["U.S. Marshal Service"] = true,
	["USM"] = true, ["Chief of Police"] = true, ["Dept. of Justice"] = true, ["Homeland Security"] = true,
}
local function isLaw(): boolean
	return player.Team ~= nil and LAW[player.Team.Name] == true or player:GetAttribute("Police") == true
end
local function canMDT(): boolean
	return player.Team ~= nil and MDT[player.Team.Name] == true
end

local function call(name: string, ...: any): ...any
	local ok, a, b, c = pcall(RF.InvokeServer, RF, name, ...)
	if ok then return a, b, c end
	warn("[CityLife] " .. name .. ": " .. tostring(a))
	return nil
end
local function money(n: number): string
	n = math.floor(n or 0)
	local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if s:sub(1, 1) == "," then s = s:sub(2) end
	return (if n < 0 then "-$" else "$") .. s
end

---------------------------------------------------------------------------
-- the screen
---------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "CityLifeUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 35
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")
local scale = Instance.new("UIScale")
scale.Parent = gui
local function fit()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	scale.Scale = math.clamp(math.min(vp.X / 1100, vp.Y / 680), 0.55, 1.2)
end
fit()
if workspace.CurrentCamera then workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end

local C = {
	bg = Color3.fromRGB(16, 18, 24), panel = Color3.fromRGB(28, 32, 42), row = Color3.fromRGB(36, 41, 54),
	accent = Color3.fromRGB(255, 196, 64), text = Color3.fromRGB(235, 238, 245), dim = Color3.fromRGB(150, 156, 170),
	red = Color3.fromRGB(200, 40, 50), green = Color3.fromRGB(40, 150, 80), blue = Color3.fromRGB(40, 90, 180),
}
local function corner(p: Instance, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = p
end
local function pad(p: Instance, n: number)
	local u = Instance.new("UIPadding")
	u.PaddingTop, u.PaddingBottom, u.PaddingLeft, u.PaddingRight = UDim.new(0, n), UDim.new(0, n), UDim.new(0, n), UDim.new(0, n)
	u.Parent = p
end
local function label(parent: Instance, text: string, size: number?, color: Color3?, bold: boolean?, order: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	l.TextSize = size or 16
	l.TextColor3 = color or C.text
	l.Text = text
	l.RichText = true
	l.LayoutOrder = order or 0
	l.Parent = parent
	return l
end
local function button(parent: Instance, text: string, color: Color3?, onClick: () -> (), order: number?, width: UDim?): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(width or UDim.new(1, 0), UDim.new(0, 44))
	b.BackgroundColor3 = color or C.blue
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 16
	b.TextWrapped = true
	b.Text = text
	b.AutoButtonColor = true
	b.LayoutOrder = order or 0
	corner(b, 8)
	b.Parent = parent
	b.Activated:Connect(onClick)
	return b
end
local function list(parent: Instance, padding: number?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, padding or 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = parent
	return l
end

---------------------------------------------------------------------------
-- the app window (one at a time)
---------------------------------------------------------------------------
local window: Frame? = nil
local content: ScrollingFrame? = nil
local tabsBar: Frame? = nil
local currentApp: string? = nil
local refreshApp: (() -> ())? = nil

local function closeApp()
	if window then window:Destroy() end
	window, content, tabsBar, currentApp, refreshApp = nil, nil, nil, nil, nil
end

local function openWindow(title: string, color: Color3): (ScrollingFrame, Frame)
	closeApp()
	local w = Instance.new("Frame")
	w.Name = "AppWindow"
	w.AnchorPoint = Vector2.new(0.5, 0.5)
	w.Position = UDim2.fromScale(0.5, 0.52)
	w.Size = UDim2.fromOffset(560, 600)
	w.BackgroundColor3 = C.bg
	corner(w, 14)
	local st = Instance.new("UIStroke")
	st.Color = color
	st.Thickness = 2
	st.Parent = w
	local head = Instance.new("Frame")
	head.Size = UDim2.new(1, 0, 0, 50)
	head.BackgroundColor3 = color
	corner(head, 14)
	head.Parent = w
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromOffset(16, 0)
	t.Size = UDim2.new(1, -80, 1, 0)
	t.Font = Enum.Font.GothamBlack
	t.TextSize = 22
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Text = title
	t.Parent = head
	local x = Instance.new("TextButton")
	x.AnchorPoint = Vector2.new(1, 0.5)
	x.Position = UDim2.new(1, -8, 0.5, 0)
	x.Size = UDim2.fromOffset(44, 40)
	x.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	x.BackgroundTransparency = 0.6
	x.Text = "X"
	x.Font = Enum.Font.GothamBlack
	x.TextSize = 20
	x.TextColor3 = Color3.new(1, 1, 1)
	corner(x, 8)
	x.Parent = head
	x.Activated:Connect(closeApp)
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.Position = UDim2.fromOffset(10, 56)
	tabs.Size = UDim2.new(1, -20, 0, 40)
	tabs.BackgroundTransparency = 1
	tabs.Parent = w
	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.Padding = UDim.new(0, 6)
	tl.Parent = tabs
	local sc = Instance.new("ScrollingFrame")
	sc.Position = UDim2.fromOffset(10, 102)
	sc.Size = UDim2.new(1, -20, 1, -112)
	sc.BackgroundTransparency = 1
	sc.ScrollBarThickness = 8
	sc.CanvasSize = UDim2.new()
	sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sc.ScrollingDirection = Enum.ScrollingDirection.Y
	sc.Parent = w
	list(sc, 8)
	w.Parent = gui
	window, content, tabsBar = w, sc, tabs
	return sc, tabs
end
local function clear()
	if not content then return end
	for _, c in content:GetChildren() do
		if not c:IsA("UIListLayout") then c:Destroy() end
	end
	content.CanvasPosition = Vector2.zero
end
local function setTabs(names: { string }, active: string, onPick: (string) -> ())
	if not tabsBar then return end
	for _, c in tabsBar:GetChildren() do
		if c:IsA("TextButton") then c:Destroy() end
	end
	local w = 1 / #names
	for _, n in names do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(w, -6, 1, 0)
		b.BackgroundColor3 = if n == active then C.accent else C.panel
		b.TextColor3 = if n == active then Color3.new(0, 0, 0) else C.text
		b.Font = Enum.Font.GothamBold
		b.TextSize = 15
		b.Text = n
		corner(b, 8)
		b.Parent = tabsBar
		b.Activated:Connect(function() onPick(n) end)
	end
end
local function card(order: number?, color: Color3?): Frame
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, -4, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = color or C.row
	f.LayoutOrder = order or 0
	corner(f, 10)
	pad(f, 10)
	list(f, 4)
	f.Parent = content
	return f
end
-- a message over the window
local function toast(text: string, good: boolean?)
	local f = Instance.new("TextLabel")
	f.AnchorPoint = Vector2.new(0.5, 1)
	f.Position = UDim2.new(0.5, 0, 1, -16)
	f.Size = UDim2.fromOffset(520, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = if good == false then C.red elseif good then C.green else C.panel
	f.TextColor3 = Color3.new(1, 1, 1)
	f.Font = Enum.Font.GothamMedium
	f.TextSize = 16
	f.TextWrapped = true
	f.Text = text
	f.ZIndex = 20
	pad(f, 10)
	corner(f, 10)
	f.Parent = window or gui
	task.delay(math.clamp(#text / 18, 3, 9), function() if f.Parent then f:Destroy() end end)
end
-- pick from a list (players, jurors) inside the window
local function choose(title: string, options: { string }, onPick: (number) -> ())
	clear()
	label(content :: any, title, 18, C.accent, true, 0)
	for i, o in options do
		button(content :: any, o, C.panel, function() onPick(i) end, i)
	end
	button(content :: any, "Cancel", C.red, function() if refreshApp then refreshApp() end end, 999)
end
local function askAmount(title: string, onDone: (number) -> ())
	clear()
	label(content :: any, title, 18, C.accent, true, 0)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 48)
	box.BackgroundColor3 = C.panel
	box.TextColor3 = Color3.new(1, 1, 1)
	box.PlaceholderText = "Amount in $"
	box.Font = Enum.Font.GothamMedium
	box.TextSize = 20
	box.Text = ""
	box.ClearTextOnFocus = false
	box.LayoutOrder = 1
	corner(box, 8)
	box.Parent = content
	button(content :: any, "OK", C.green, function()
		local n = tonumber((box.Text:gsub("[^%d]", "")))
		if n then onDone(n) end
	end, 2)
	button(content :: any, "Cancel", C.red, function() if refreshApp then refreshApp() end end, 3)
end

---------------------------------------------------------------------------
-- CONNECTIONS
---------------------------------------------------------------------------
local linksTab = "Legal"
local function openLinks()
	openWindow("CONNECTIONS", Color3.fromRGB(120, 80, 20))
	currentApp = "links"
	local function render()
		local items = call("links.list") or {}
		local jury = call("jury.panel")
		local cats = { "Legal", "Street", "System", "Money" }
		local inside = player:GetAttribute("SentenceEnd") ~= nil
		if inside then table.insert(cats, 1, "Prison") end
		if jury then table.insert(cats, "Jury") end
		if not table.find(cats, linksTab) then linksTab = cats[1] end
		setTabs(cats, linksTab, function(n) linksTab = n; render() end)
		clear()
		if inside then label(content :: any, "<i>You're on a prison phone - every call is recorded. Illegal deals are riskier.</i>", 14, C.dim, false, -1) end
		if linksTab == "Jury" and jury then
			label(content :: any, if jury.sequestered then "The jury is SEQUESTERED - no house visits; the fixer charges triple." else "Your jury. Pay them through Sal, or visit their homes (bribe, threaten, blackmail - or take someone).", 14, C.dim, false, 0)
			for _, j in jury.jurors do
				local f = card(j.i)
				label(f, ("#%d  <b>%s</b>  -  %s"):format(j.i, j.name, j.house), 16)
				local status = if j.reported then "<font color='#ff6060'>REPORTED the approach</font>" elseif j.hostage then "Family held - votes your way" elseif j.done then "<font color='#60ff90'>Taken care of</font>" else "Not approached"
				label(f, status .. (if j.dirt then "  |  you have dirt" else ""), 14, C.dim)
				if not j.done and not j.reported then
					local row = Instance.new("Frame")
					row.Size = UDim2.new(1, 0, 0, 44)
					row.BackgroundTransparency = 1
					row.Parent = f
					local rl = Instance.new("UIListLayout")
					rl.FillDirection = Enum.FillDirection.Horizontal
					rl.Padding = UDim.new(0, 6)
					rl.Parent = row
					button(row, "Pay via Sal", C.green, function()
						local ok, msg = call("jury.act", j.i, "fixer")
						toast(tostring(msg), ok)
						render()
					end, 1, UDim.new(0.5, -3))
					button(row, "Mark their house", C.blue, function()
						local ok, msg = call("jury.act", j.i, "visit")
						toast(tostring(msg), ok)
					end, 2, UDim.new(0.5, -3))
				end
			end
			return
		end
		local order = 0
		for _, e in items do
			if e.cat ~= linksTab then continue end
			order += 1
			local f = card(order, if e.available then C.row else Color3.fromRGB(30, 32, 38))
			label(f, e.who, 13, C.dim)
			label(f, ("<b>%s</b>%s"):format(e.title, if e.illegal then "  <font color='#ff9040'>(risky)</font>" else ""), 17)
			if e.desc and e.desc ~= "" then label(f, e.desc, 14, C.dim) end
			local priceText = if e.price and e.price > 0 then money(e.price) else ""
			if not e.available then
				label(f, "<font color='#ff7070'>" .. tostring(e.why or "Not available") .. "</font>", 14)
			else
				button(f, if priceText ~= "" then "Pay " .. priceText else "Go", if e.illegal then Color3.fromRGB(150, 70, 20) else C.green, function()
					local function buy(arg: any)
						local ok, msg = call("links.buy", e.id, arg)
						render()
						toast(tostring(msg), ok)
					end
					if e.target == "player" or e.target == "snitch" then
						local names = call("links.players") or {}
						choose("Who?", names, function(i) buy(names[i]) end)
					elseif e.target == "juror" then
						local jp = call("jury.panel")
						if not jp then toast("Get the jury list first", false) return end
						local names = {}
						for _, j in jp.jurors do table.insert(names, ("#%d %s"):format(j.i, j.name)) end
						choose("Which juror?", names, function(i) buy(i) end)
					elseif e.target == "amount" then
						askAmount(e.title, function(n) buy(n) end)
					else
						buy(nil)
					end
				end)
			end
		end
		if order == 0 then label(content :: any, "Nothing here right now.", 15, C.dim) end
	end
	refreshApp = render
	render()
end

---------------------------------------------------------------------------
-- MDT (police)
---------------------------------------------------------------------------
local mdtTab = "Lookup"
local REASONS = { "traffic stop", "investigation", "warrant check", "suspicious person", "other" }
local reasonIdx = 1
local function showPerson(info: any)
	clear()
	if info.error then label(content :: any, info.error, 16, C.red) return end
	local f = card(1)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 110)
	row.BackgroundTransparency = 1
	row.Parent = f
	local img = Instance.new("ImageLabel")
	img.Size = UDim2.fromOffset(100, 100)
	img.BackgroundColor3 = C.panel
	corner(img, 8)
	img.Parent = row
	task.spawn(function()
		local ok, url = pcall(Players.GetUserThumbnailAsync, Players, info.userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		if ok then img.Image = url end
	end)
	local side = Instance.new("Frame")
	side.Position = UDim2.fromOffset(110, 0)
	side.Size = UDim2.new(1, -110, 1, 0)
	side.BackgroundTransparency = 1
	side.Parent = row
	list(side, 2)
	label(side, "<b>" .. info.name .. "</b>", 18)
	label(side, ("Age %d  |  %s"):format(info.age or 0, info.address or "?"), 14, C.dim)
	label(side, "Licence: " .. tostring(info.licence) .. (if (info.points or 0) > 0 then (" (%d points)"):format(info.points) else ""), 14,
		if tostring(info.licence):find("valid") == 1 then C.text else Color3.fromRGB(255, 120, 120))
	local function section(title: string, items: { string }?, color: Color3?)
		local s = card(nil, C.panel)
		label(s, "<b>" .. title .. "</b>", 15, C.accent)
		if not items or #items == 0 then label(s, "none", 14, C.dim) return end
		for _, it in items do label(s, it, 14, color) end
	end
	section("FLAGS", info.flags, Color3.fromRGB(255, 120, 120))
	section("VEHICLES", info.vehicles)
	section("CITATIONS", info.citations)
	section("ARRESTS / COURT", info.history)
	button(content :: any, "Back", C.panel, function() if refreshApp then refreshApp() end end, 99)
end
local function showPlate(info: any)
	clear()
	if info.error then label(content :: any, info.error, 16, C.red) return end
	local f = card(1)
	label(f, "<b>PLATE " .. tostring(info.plate) .. "</b>", 20)
	if not info.found then
		label(f, "NOT ON FILE", 16, C.red)
	else
		label(f, ("Registered owner: %s"):format(tostring(info.owner)), 16)
		label(f, ("%s %s  |  registered %s"):format(tostring(info.colour), tostring(info.type), tostring(info.registered)), 15, C.dim)
		if info.seen then label(f, "On the road now: " .. info.seen, 14, C.dim) end
		if #info.flags == 0 then label(f, "No flags - clean", 15, Color3.fromRGB(120, 255, 150)) end
		for _, fl in info.flags do label(f, fl, 15, Color3.fromRGB(255, 120, 120)) end
	end
	button(content :: any, "Back", C.panel, function() if refreshApp then refreshApp() end end, 99)
end
local function openMDT()
	if not canMDT() then
		toast("The MDT is for police officers", false)
		return
	end
	openWindow("MDT - DAVID", Color3.fromRGB(30, 60, 130))
	currentApp = "mdt"
	local function render()
		setTabs({ "Lookup", "Warrants", "Callouts", "Backup" }, mdtTab, function(n) mdtTab = n; render() end)
		clear()
		if mdtTab == "Lookup" then
			local box = Instance.new("TextBox")
			box.Size = UDim2.new(1, 0, 0, 48)
			box.BackgroundColor3 = C.panel
			box.TextColor3 = Color3.new(1, 1, 1)
			box.PlaceholderText = "Name or plate"
			box.Font = Enum.Font.GothamMedium
			box.TextSize = 20
			box.Text = ""
			box.ClearTextOnFocus = false
			box.LayoutOrder = 1
			corner(box, 8)
			box.Parent = content
			local reasonBtn
			reasonBtn = button(content :: any, "Reason: " .. REASONS[reasonIdx] .. "  (tap to change - every lookup is logged)", C.panel, function()
				reasonIdx = reasonIdx % #REASONS + 1
				reasonBtn.Text = "Reason: " .. REASONS[reasonIdx] .. "  (tap to change - every lookup is logged)"
			end, 2)
			button(content :: any, "Run PERSON", C.blue, function()
				local info = call("mdt.person", box.Text, REASONS[reasonIdx])
				if info then showPerson(info) end
			end, 3)
			button(content :: any, "Run PLATE", C.blue, function()
				local info = call("mdt.plate", box.Text, REASONS[reasonIdx])
				if info then showPlate(info) end
			end, 4)
			label(content :: any, "<b>Nearby</b>", 16, C.accent, false, 5)
			local near = call("mdt.nearby") or {}
			for i, n in near do
				button(content :: any, (if n.kind == "plate" then "Plate: " else "Person: ") .. n.label, C.row, function()
					local info = if n.kind == "plate" then call("mdt.plate", n.value, REASONS[reasonIdx]) else call("mdt.person", n.value, REASONS[reasonIdx])
					if info then if n.kind == "plate" then showPlate(info) else showPerson(info) end end
				end, 5 + i)
			end
			if #near == 0 then label(content :: any, "Nobody close", 14, C.dim, false, 6) end
		elseif mdtTab == "Warrants" then
			local data = call("mdt.lists") or { warrants = {}, bolos = {}, log = {} }
			label(content :: any, "<b>ACTIVE WARRANTS</b>", 16, C.accent, false, 1)
			for i, w in data.warrants do
				local f = card(1 + i)
				label(f, ("<b>%s</b> - %s"):format(w.name, w.reason), 15)
				label(f, ("severity %d  |  %s"):format(w.severity or 1, w.source or "?"), 13, C.dim)
			end
			if #data.warrants == 0 then label(content :: any, "none", 14, C.dim, false, 2) end
			label(content :: any, "<b>BOLOs</b>", 16, C.accent, false, 50)
			for i, b in data.bolos do
				local f = card(50 + i)
				label(f, (if b.subject then "<b>" .. b.subject .. "</b> - " else "") .. b.text, 15)
			end
			if #data.bolos == 0 then label(content :: any, "none", 14, C.dim, false, 51) end
			local box = Instance.new("TextBox")
			box.Size = UDim2.new(1, 0, 0, 44)
			box.BackgroundColor3 = C.panel
			box.TextColor3 = Color3.new(1, 1, 1)
			box.PlaceholderText = "New BOLO: description..."
			box.Font = Enum.Font.Gotham
			box.TextSize = 16
			box.Text = ""
			box.LayoutOrder = 90
			corner(box, 8)
			box.Parent = content
			button(content :: any, "Broadcast BOLO", Color3.fromRGB(150, 70, 20), function()
				if call("mdt.bolo", box.Text) then toast("BOLO broadcast", true) render() end
			end, 91)
			label(content :: any, "<b>LOOKUP LOG</b> (audited)", 15, C.accent, false, 100)
			for i, l in data.log do label(content :: any, l, 13, C.dim, false, 100 + i) end
		elseif mdtTab == "Callouts" then
			local cs = call("callout.list") or {}
			for i, c in cs do
				local f = card(i)
				label(f, ("<b>%s</b>%s"):format(c.title, if c.mine then "  <font color='#60ff90'>(yours)</font>" else ""), 16)
				label(f, ("%s  |  %s  |  %d responding"):format(c.text, c.place or "?", c.officers or 0), 14, C.dim)
				if not c.mine then
					button(f, "Respond", C.blue, function()
						if call("callout.respond", c.id) then toast("Responding - waypoint set", true) render() end
					end)
				end
			end
			if #cs == 0 then label(content :: any, "No open calls. Stay safe out there.", 15, C.dim) end
		else
			label(content :: any, "Backup goes to your callout (or to you).", 14, C.dim, false, 0)
			for i, b in { { "units", "More units (3 officers)" }, { "k9", "K9 unit" }, { "air", "Air support (active pursuit)" }, { "roadblock", "Roadblock ahead" } } do
				button(content :: any, b[2], C.blue, function()
					local ok = call("callout.backup", b[1])
					toast(if ok then "Requested: " .. b[2] else "Request denied", ok == true)
				end, i)
			end
			label(content :: any, "Traffic stop: press <b>B</b> (or the STOP button) while driving behind a car.", 14, C.dim, false, 10)
		end
	end
	refreshApp = render
	render()
end

---------------------------------------------------------------------------
-- NEWS
---------------------------------------------------------------------------
local stories: { any } = {}
local liveInfo: any = nil
local newsTab = "Stories"
local watchLive: (() -> ())? = nil
local function timeAgo(t: number): string
	local d = os.time() - t
	if d < 60 then return "just now" end
	if d < 3600 then return ("%dm ago"):format(d // 60) end
	return ("%dh ago"):format(d // 3600)
end
local function openNews()
	openWindow("CHANNEL 8 NEWS", Color3.fromRGB(170, 20, 30))
	currentApp = "news"
	local function render()
		local s, live, wanted = call("news.list")
		stories = s or stories
		liveInfo = live
		setTabs({ "Stories", "Most Wanted" }, newsTab, function(n) newsTab = n; render() end)
		clear()
		if liveInfo then
			button(content :: any, "WATCH LIVE: " .. tostring(liveInfo.headline), C.red, function()
				closeApp()
				if watchLive then watchLive() end
			end, 0)
		end
		if newsTab == "Stories" then
			for i, st in stories do
				local f = card(i, if st.level >= 3 then Color3.fromRGB(70, 18, 22) else C.row)
				label(f, (if st.level >= 3 then "BREAKING  " elseif st.live then "LIVE  " else "") .. timeAgo(st.at) .. (if st.place then "  |  " .. st.place else ""), 12,
					if st.level >= 3 then Color3.fromRGB(255, 120, 120) else C.dim)
				label(f, st.headline, if st.level >= 2 then 17 else 15, C.text, st.level >= 2)
				if st.body and st.body ~= "" and st.level >= 2 then label(f, st.body, 14, C.dim) end
			end
			-- the old C-SPAN items (executions etc.)
			local legacy = _G.newsStories
			if type(legacy) == "table" then
				for i, v in legacy do
					if type(v) == "table" and v[1] then
						local f = card(500 + i)
						label(f, tostring(v[1]), 15, C.text, true)
						if v[2] then label(f, tostring(v[2]), 13, C.dim) end
					end
				end
			end
			if #stories == 0 then label(content :: any, "A quiet day in Las Vegas.", 15, C.dim) end
		else
			for i, w in wanted or {} do
				local f = card(i)
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, 70)
				row.BackgroundTransparency = 1
				row.Parent = f
				local img = Instance.new("ImageLabel")
				img.Size = UDim2.fromOffset(66, 66)
				img.BackgroundColor3 = C.panel
				corner(img, 8)
				img.Parent = row
				task.spawn(function()
					local ok, url = pcall(Players.GetUserThumbnailAsync, Players, w.userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
					if ok then img.Image = url end
				end)
				local side = Instance.new("Frame")
				side.Position = UDim2.fromOffset(76, 0)
				side.Size = UDim2.new(1, -76, 1, 0)
				side.BackgroundTransparency = 1
				side.Parent = row
				list(side, 2)
				label(side, ("<b>%s</b>  %s"):format(w.name, string.rep("*", w.stars or 0)), 17)
				if w.warrant then label(side, "Warrant: " .. w.warrant, 13, Color3.fromRGB(255, 130, 130)) end
				if w.bolo then label(side, "BOLO: " .. w.bolo, 13, C.dim) end
			end
			if not wanted or #wanted == 0 then label(content :: any, "Nobody's wanted right now.", 15, C.dim) end
		end
	end
	refreshApp = render
	render()
end

---------------------------------------------------------------------------
-- the phone: our buttons open these windows
---------------------------------------------------------------------------
local function hookPhone()
	local pg = player:WaitForChild("PlayerGui")
	local phone = pg:WaitForChild("CellPhone", 60)
	if not phone then return end
	local screen = phone:WaitForChild("Outline"):WaitForChild("ScreenFrame")
	local home = screen:WaitForChild("HomeFrame")
	local function redirect(frameName: string, open: () -> ())
		local f = screen:WaitForChild(frameName, 20)
		if not f then return end
		f:GetPropertyChangedSignal("Visible"):Connect(function()
			if f.Visible then
				f.Visible = false
				home.Visible = true
				open()
			end
		end)
	end
	task.spawn(redirect, "LinksFrame", openLinks)
	task.spawn(redirect, "MDTFrame", openMDT)
	task.spawn(redirect, "NewsFrame", openNews)
	task.spawn(redirect, "LawyerFrame", function()
		closeApp()
		RE:FireServer("lawyer.call")
	end)
	local mdtButton = home:WaitForChild("MDT", 20)
	local function showMdt()
		if mdtButton then (mdtButton :: GuiObject).Visible = canMDT() end
	end
	showMdt()
	player:GetPropertyChangedSignal("Team"):Connect(showMdt)
end
task.spawn(hookPhone)
player.CharacterAdded:Connect(function() task.wait(1) task.spawn(hookPhone) end)

---------------------------------------------------------------------------
-- breaking news banner + phone badge
---------------------------------------------------------------------------
local function banner(text: string)
	local b = Instance.new("Frame")
	b.AnchorPoint = Vector2.new(0.5, 0)
	b.Position = UDim2.new(0.5, 0, 0, 8)
	b.Size = UDim2.fromOffset(760, 54)
	b.BackgroundColor3 = Color3.fromRGB(170, 15, 25)
	b.ZIndex = 30
	corner(b, 10)
	b.Parent = gui
	local tag = Instance.new("TextLabel")
	tag.Size = UDim2.fromOffset(120, 54)
	tag.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	tag.TextColor3 = Color3.fromRGB(170, 15, 25)
	tag.Font = Enum.Font.GothamBlack
	tag.TextSize = 18
	tag.Text = "BREAKING"
	tag.ZIndex = 31
	corner(tag, 10)
	tag.Parent = b
	local t = Instance.new("TextLabel")
	t.Position = UDim2.fromOffset(130, 0)
	t.Size = UDim2.new(1, -(if liveInfo then 260 else 140), 1, 0)
	t.BackgroundTransparency = 1
	t.TextColor3 = Color3.new(1, 1, 1)
	t.Font = Enum.Font.GothamBold
	t.TextSize = 17
	t.TextWrapped = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Text = text
	t.ZIndex = 31
	t.Parent = b
	if liveInfo then
		local w = Instance.new("TextButton")
		w.AnchorPoint = Vector2.new(1, 0.5)
		w.Position = UDim2.new(1, -8, 0.5, 0)
		w.Size = UDim2.fromOffset(120, 42)
		w.BackgroundColor3 = Color3.new(0, 0, 0)
		w.TextColor3 = Color3.new(1, 1, 1)
		w.Font = Enum.Font.GothamBlack
		w.TextSize = 15
		w.Text = "WATCH LIVE"
		w.ZIndex = 32
		corner(w, 8)
		w.Parent = b
		w.Activated:Connect(function()
			b:Destroy()
			if watchLive then watchLive() end
		end)
	end
	task.delay(9, function() if b.Parent then b:Destroy() end end)
end
local function badge()
	local pg = player:FindFirstChild("PlayerGui")
	local ok, btn = pcall(function() return pg.CellPhone.Outline.ScreenFrame.HomeFrame.News end)
	if ok and btn and btn:FindFirstChild("Notification") then
		btn.Notification.Visible = true
		local n = btn.Notification:FindFirstChild("Number")
		if n then n.Text = tostring((tonumber(n.Text) or 0) + 1) end
	end
end

---------------------------------------------------------------------------
-- LIVE broadcast (auto-director)
---------------------------------------------------------------------------
local watching = false
local overlay: Frame? = nil
local function subjectPos(): Vector3?
	if not liveInfo then return nil end
	if liveInfo.subject then
		local p = Players:GetPlayerByUserId(liveInfo.subject)
		local r = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if r then return (r :: BasePart).Position end
	end
	return liveInfo.pos
end
local function courtSpot(name: string): BasePart?
	local ch = workspace:FindFirstChild("Courthouse")
	local m = ch and ch:FindFirstChild("CourtMarkers")
	local p = m and m:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p else nil
end
local function stopWatching()
	watching = false
	if overlay then overlay:Destroy() overlay = nil end
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Custom
	cam.FieldOfView = 70
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then cam.CameraSubject = hum end
end
watchLive = function()
	if watching or not liveInfo then return end
	watching = true
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	-- the graphics
	local o = Instance.new("Frame")
	o.Size = UDim2.fromScale(1, 1)
	o.BackgroundTransparency = 1
	o.ZIndex = 40
	o.Parent = gui
	overlay = o
	local bug = Instance.new("TextLabel")
	bug.Position = UDim2.fromOffset(20, 20)
	bug.Size = UDim2.fromOffset(170, 40)
	bug.BackgroundColor3 = Color3.fromRGB(200, 15, 25)
	bug.TextColor3 = Color3.new(1, 1, 1)
	bug.Font = Enum.Font.GothamBlack
	bug.TextSize = 20
	bug.Text = "LIVE  |  8 NEWS"
	bug.ZIndex = 41
	corner(bug, 6)
	bug.Parent = o
	local lower = Instance.new("Frame")
	lower.AnchorPoint = Vector2.new(0, 1)
	lower.Position = UDim2.new(0, 20, 1, -64)
	lower.Size = UDim2.new(0.75, 0, 0, 64)
	lower.BackgroundColor3 = Color3.fromRGB(15, 20, 35)
	lower.BackgroundTransparency = 0.1
	lower.ZIndex = 41
	lower.Parent = o
	local stripe = Instance.new("Frame")
	stripe.Size = UDim2.new(0, 8, 1, 0)
	stripe.BackgroundColor3 = Color3.fromRGB(200, 15, 25)
	stripe.ZIndex = 42
	stripe.Parent = lower
	local headline = Instance.new("TextLabel")
	headline.Position = UDim2.fromOffset(18, 4)
	headline.Size = UDim2.new(1, -24, 0, 34)
	headline.BackgroundTransparency = 1
	headline.TextColor3 = Color3.new(1, 1, 1)
	headline.Font = Enum.Font.GothamBlack
	headline.TextSize = 22
	headline.TextXAlignment = Enum.TextXAlignment.Left
	headline.TextScaled = true
	headline.Text = tostring(liveInfo.headline)
	headline.ZIndex = 42
	headline.Parent = lower
	local shotLabel = Instance.new("TextLabel")
	shotLabel.Position = UDim2.fromOffset(18, 38)
	shotLabel.Size = UDim2.new(1, -24, 0, 22)
	shotLabel.BackgroundTransparency = 1
	shotLabel.TextColor3 = Color3.fromRGB(200, 205, 220)
	shotLabel.Font = Enum.Font.Gotham
	shotLabel.TextSize = 15
	shotLabel.TextXAlignment = Enum.TextXAlignment.Left
	shotLabel.ZIndex = 42
	shotLabel.Parent = lower
	local tick = Instance.new("Frame")
	tick.AnchorPoint = Vector2.new(0, 1)
	tick.Position = UDim2.new(0, 0, 1, 0)
	tick.Size = UDim2.new(1, 0, 0, 40)
	tick.BackgroundColor3 = Color3.fromRGB(200, 15, 25)
	tick.ClipsDescendants = true
	tick.ZIndex = 41
	tick.Parent = o
	local tickText = Instance.new("TextLabel")
	tickText.Size = UDim2.new(0, 3000, 1, 0)
	tickText.BackgroundTransparency = 1
	tickText.TextColor3 = Color3.new(1, 1, 1)
	tickText.Font = Enum.Font.GothamBold
	tickText.TextSize = 18
	tickText.TextXAlignment = Enum.TextXAlignment.Left
	tickText.ZIndex = 42
	local heads = {}
	for i = 1, math.min(8, #stories) do table.insert(heads, stories[i].headline) end
	tickText.Text = "   " .. table.concat(heads, "   ///   ")
	tickText.Parent = tick
	local exit = Instance.new("TextButton")
	exit.AnchorPoint = Vector2.new(1, 0)
	exit.Position = UDim2.new(1, -20, 0, 20)
	exit.Size = UDim2.fromOffset(110, 44)
	exit.BackgroundColor3 = Color3.new(0, 0, 0)
	exit.BackgroundTransparency = 0.3
	exit.TextColor3 = Color3.new(1, 1, 1)
	exit.Font = Enum.Font.GothamBold
	exit.TextSize = 17
	exit.Text = "EXIT"
	exit.ZIndex = 43
	corner(exit, 8)
	exit.Parent = o
	exit.Activated:Connect(stopWatching)

	-- shots
	local shots = if liveInfo.court then { "court_wide", "court_defendant", "court_judge", "court_jury" } else { "heli", "ground", "reporter", "low", "long", "heli" }
	local shot, shotStart, shotLen, groundAt = 1, os.clock(), 5, nil :: Vector3?
	local tickX = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		if not watching or not liveInfo then
			conn:Disconnect()
			stopWatching()
			return
		end
		tickX -= dt * 90
		if tickX < -2400 then tickX = 300 end
		tickText.Position = UDim2.fromOffset(tickX, 0)
		local now = os.clock()
		if now - shotStart > shotLen then
			shot = shot % #shots + 1
			shotStart = now
			shotLen = 4 + math.random() * 2.5
			groundAt = nil
		end
		local kind = shots[shot]
		local t = now - shotStart
		local target = subjectPos() or Vector3.zero
		if kind == "heli" then
			local heli = liveInfo.heli
			local from = if heli and heli.Parent and heli.PrimaryPart then heli.PrimaryPart.Position + Vector3.new(0, -5, 0) else target + Vector3.new(90, 80, 90)
			local shake = Vector3.new(math.noise(now * 1.3, 1) * 0.6, math.noise(now * 1.1, 2) * 0.5, math.noise(now * 1.2, 3) * 0.6)
			cam.CFrame = CFrame.lookAt(from, target + shake)
			cam.FieldOfView = 34 - t * 2
			shotLabel.Text = "NEWS 8 CHOPPER - over " .. tostring(liveInfo.place or "the scene")
		elseif kind == "ground" then
			groundAt = groundAt or (target + Vector3.new(math.random(-40, 40), 6, math.random(-40, 40)))
			cam.CFrame = CFrame.lookAt(groundAt :: Vector3, target + Vector3.new(0, 2, 0))
			cam.FieldOfView = 45
			shotLabel.Text = "Ground camera"
		elseif kind == "reporter" then
			local rep = liveInfo.reporter
			local head = rep and rep.Parent and rep:FindFirstChild("Head")
			if head then
				local look = (head :: BasePart).CFrame
				local from = (look * CFrame.new(1.8, 0.6, 5)).Position
				cam.CFrame = CFrame.lookAt(from, (head :: BasePart).Position + Vector3.new(0, -0.2, 0))
				cam.FieldOfView = 40
				shotLabel.Text = "Channel 8 reporter on the scene"
			else
				shotStart -= 10
			end
		elseif kind == "low" then
			groundAt = groundAt or (target + Vector3.new(math.random(-12, 12), 1, math.random(-12, 12)))
			cam.CFrame = CFrame.lookAt(groundAt :: Vector3, target + Vector3.new(0, 4, 0))
			cam.FieldOfView = 60
			shotLabel.Text = ""
		elseif kind == "long" then
			groundAt = groundAt or (target + Vector3.new(math.random(-1, 1) * 160 + 1, 22, math.random(-1, 1) * 160 + 1))
			cam.CFrame = CFrame.lookAt(groundAt :: Vector3, target + Vector3.new(0, 2, 0))
			cam.FieldOfView = 12
			shotLabel.Text = "Long lens"
		else
			-- courtroom cameras
			local judge, def, juror, gallery = courtSpot("JudgeSeat"), courtSpot("DefendantSeat"), courtSpot("JurorSeat6"), courtSpot("GallerySeat")
			if judge and def then
				if kind == "court_wide" then
					local back = def.Position + (def.Position - judge.Position).Unit * 40 + Vector3.new(0, 10, 0)
					cam.CFrame = CFrame.lookAt(back, judge.Position)
					cam.FieldOfView = 55
					shotLabel.Text = "Clark County Courthouse - courtroom camera"
				elseif kind == "court_defendant" then
					cam.CFrame = CFrame.lookAt(def.Position + (judge.Position - def.Position).Unit * 9 + Vector3.new(0, 4, 0), def.Position + Vector3.new(0, 3, 0))
					cam.FieldOfView = 35
					shotLabel.Text = "The defendant"
				elseif kind == "court_judge" then
					cam.CFrame = CFrame.lookAt(judge.Position + (def.Position - judge.Position).Unit * 12 + Vector3.new(0, 3, 0), judge.Position + Vector3.new(0, 4, 0))
					cam.FieldOfView = 35
					shotLabel.Text = "The bench"
				else
					local j = juror or gallery or judge
					cam.CFrame = CFrame.lookAt(j.Position + Vector3.new(14, 6, 0), j.Position + Vector3.new(0, 3, math.sin(t * 0.5) * 8))
					cam.FieldOfView = 45
					shotLabel.Text = "The jury"
				end
			else
				shotLabel.Text = "(courtroom sketch) " .. tostring(liveInfo.headline)
				cam.CFrame = CFrame.lookAt(target + Vector3.new(20, 12, 20), target)
			end
		end
	end)
end

---------------------------------------------------------------------------
-- recognition meters
---------------------------------------------------------------------------
local meters: { [Instance]: BillboardGui } = {}
local function meterGui(adornee: BasePart, color: Color3): BillboardGui
	local b = Instance.new("BillboardGui")
	b.Size = UDim2.fromOffset(46, 58)
	b.StudsOffset = Vector3.new(0, 2.8, 0)
	b.AlwaysOnTop = true
	b.MaxDistance = 140
	b.Adornee = adornee
	local q = Instance.new("TextLabel")
	q.Name = "Q"
	q.Size = UDim2.new(1, 0, 1, -10)
	q.BackgroundTransparency = 1
	q.Font = Enum.Font.GothamBlack
	q.TextScaled = true
	q.Text = "?"
	q.TextColor3 = color
	q.TextStrokeTransparency = 0.2
	q.Parent = b
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 0, 1, 0)
	bar.Size = UDim2.new(0, 0, 0, 6)
	bar.BackgroundColor3 = color
	bar.BorderSizePixel = 0
	bar.Parent = b
	b.Parent = gui
	return b
end
local function setMeter(key: Instance, head: BasePart?, v: number?, cop: boolean)
	local g = meters[key]
	if not v or not head then
		if g then g:Destroy() meters[key] = nil end
		return
	end
	if not g then
		g = meterGui(head, if cop then Color3.fromRGB(90, 160, 255) else Color3.fromRGB(255, 220, 60))
		meters[key] = g
	end
	local col = if cop then Color3.fromRGB(90, 160, 255) else Color3.fromRGB(255, 220 - 180 * v, 60 - 50 * v)
	local q = g:FindFirstChild("Q") :: TextLabel
	local bar = g:FindFirstChild("Bar") :: Frame
	q.TextColor3 = col
	q.TextTransparency = 0.5 - 0.5 * v
	bar.BackgroundColor3 = col
	bar.Size = UDim2.new(v, 0, 0, 6)
	g.Size = UDim2.fromOffset(38 + 18 * v, 50 + 18 * v)
end
local lastCopView: { [Instance]: number } = {}

---------------------------------------------------------------------------
-- prompts: only the right person sees them
---------------------------------------------------------------------------
local function applyPrompt(pr: ProximityPrompt)
	local owner = pr:GetAttribute("OwnerOnly")
	local notOwner = pr:GetAttribute("NotOwner")
	local lawOnly = pr:GetAttribute("LawOnly")
	if owner ~= nil then pr.Enabled = owner == player.UserId
	elseif notOwner ~= nil then pr.Enabled = notOwner ~= player.UserId and not isLaw()
	elseif lawOnly then pr.Enabled = isLaw() end
end
workspace.DescendantAdded:Connect(function(d)
	if d:IsA("ProximityPrompt") then task.defer(applyPrompt, d) end
end)
local function applyAll()
	for _, d in workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") and (d:GetAttribute("OwnerOnly") ~= nil or d:GetAttribute("NotOwner") ~= nil or d:GetAttribute("LawOnly")) then applyPrompt(d) end
	end
end
task.defer(applyAll)
player:GetPropertyChangedSignal("Team"):Connect(applyAll)

---------------------------------------------------------------------------
-- traffic stops: B / STOP while driving as police
---------------------------------------------------------------------------
local bound = false
local function stopAction(_, state)
	if state == Enum.UserInputState.Begin then RE:FireServer("stop.start") end
	return Enum.ContextActionResult.Sink
end
-- v290: the touch STOP button lives with the other touch buttons (MobileControls, left of RUN / HANDBRAKE)
local StopMobile = require(game:GetService("ReplicatedStorage"):WaitForChild("MobileControls"))
StopMobile.button("TrafficStop", "STOP", Color3.fromRGB(30, 60, 160), "side2", function() RE:FireServer("stop.start") end)
local function updateStopBinding()
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local want = isLaw() and seat ~= nil and seat:IsA("VehicleSeat")
	if want and not bound then
		bound = true
		ContextActionService:BindAction("CityLifeTrafficStop", stopAction, false, Enum.KeyCode.B, Enum.KeyCode.ButtonY)
		StopMobile.show("TrafficStop", true)
	elseif not want and bound then
		bound = false
		ContextActionService:UnbindAction("CityLifeTrafficStop")
		StopMobile.show("TrafficStop", false)
	end
end
task.spawn(function()
	while true do
		task.wait(0.5)
		updateStopBinding()
	end
end)

-- where we aim (camera), while a tool is out: traffic drivers react to a gun pointed at them
task.spawn(function()
	while true do
		task.wait(0.15)
		local char = player.Character
		if char and char:FindFirstChildOfClass("Tool") and workspace.CurrentCamera then
			RE:FireServer("aim", workspace.CurrentCamera.CFrame.LookVector)
		end
	end
end)

---------------------------------------------------------------------------
-- server events
---------------------------------------------------------------------------
RE.OnClientEvent:Connect(function(kind, a, b)
	if kind == "recog" then
		local seen = {}
		for _, pair in a or {} do
			local obs, v = pair[1], pair[2]
			if typeof(obs) == "Instance" then
				seen[obs] = true
				setMeter(obs, obs:FindFirstChild("Head") :: BasePart?, v, false)
			end
		end
		for k in meters do
			if not seen[k] and not lastCopView[k] then setMeter(k, nil, nil, false) end
		end
	elseif kind == "recogOn" then
		if typeof(a) == "Instance" then
			lastCopView[a] = os.clock()
			setMeter(a, a:FindFirstChild("Head") :: BasePart?, b, true)
		end
	elseif kind == "bubble" then
		if typeof(a) == "Instance" and a:IsA("BasePart") then
			pcall(function() TextChatService:DisplayBubble(a, tostring(b)) end)
		end
	elseif kind == "news" then
		table.insert(stories, 1, a)
		while #stories > 40 do table.remove(stories) end
		badge()
		if currentApp == "news" and refreshApp then refreshApp() end
	elseif kind == "breaking" then
		banner(tostring(a))
	elseif kind == "live" then
		liveInfo = a
		if not a and watching then stopWatching() end
	end
end)
-- police-side meters fade when nothing new arrives
task.spawn(function()
	while true do
		task.wait(1)
		for k, t in lastCopView do
			if os.clock() - t > 1.5 then
				lastCopView[k] = nil
				setMeter(k, nil, nil, true)
			end
		end
	end
end)
-- the first fetch (so a late joiner has the stories and any live coverage)
task.spawn(function()
	task.wait(5)
	local s, live = call("news.list")
	if s then stories = s end
	liveInfo = live
end)
