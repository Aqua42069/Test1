-- NPCServer
-- Makes the shop owners and street NPCs talkable again (the snapshot had no
-- server code, so their Talky/Speech scripts were empty).
-- Walk up and press E (or click them). Conversations show in the Chatter GUI.
--
-- To change what someone says, edit the DIALOGUES table below.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local TALK_DISTANCE = 16

local function carTemplates()
	local folder = ServerStorage:WaitForChild("CarTemplates", 10)
	return folder and folder:GetChildren() or {}
end

local function carShop(action, player, carName)
	local fn = ServerStorage:WaitForChild("CarShop", 10)
	if fn then
		return fn:Invoke(action, player, carName)
	end
end

local function economy(action, player, amount)
	local fn = ServerStorage:WaitForChild("Economy", 10)
	if fn then
		return fn:Invoke(action, player, amount)
	end
end

local function hasKeys(player, carName)
	local storage = player:FindFirstChild("CarStorage")
	return storage and storage:FindFirstChild(carName) ~= nil
end

---------------------------------------------------------------------------
-- Dialogues. Each returns: line, { {id, text, handler(player)?}, ... }
-- A handler can call say(...) again to continue the conversation.
---------------------------------------------------------------------------
local say -- forward declaration

local function bye(text)
	return { "bye", text or "Goodbye." }
end

local function simple(greeting, extraLines)
	return function(player, npc)
		local options = {}
		for i, pair in ipairs(extraLines or {}) do
			table.insert(options, {
				"q" .. i,
				pair[1],
				function(p)
					say(p, npc, pair[2], { bye() })
				end,
			})
		end
		table.insert(options, bye())
		return greeting, options
	end
end

local function carDealer(player, npc)
	local options = {}
	for _, template in ipairs(carTemplates()) do
		local name = template.Name
		local price = carShop("Price", player, name)
		table.insert(options, {
			"keys:" .. name,
			hasKeys(player, name) and ("The " .. name .. " (you own this)")
				or ("I'll buy the " .. name .. (price and (" ($" .. price .. ")") or "") .. "."),
			function(p)
				if hasKeys(p, name) then
					say(p, npc, "You already own the " .. name .. ". Use your keys or step on any blue spawn pad.", { bye("Thanks!") })
					return
				end
				local ok, message = carShop("Buy", p, name)
				if ok then
					say(p, npc, "Pleasure doing business! Your " .. name .. " keys are in your backpack. Click them near a blue spawn pad.", { bye("Thanks!") })
				else
					say(p, npc, "Sorry: " .. tostring(message or "can't do that right now") .. ".", { bye() })
				end
			end,
		})
	end
	table.insert(options, {
		"howto",
		"How do I get my car out?",
		function(p)
			say(p, npc, "Walk onto one of the big parking pads around the city and pick your car from the list. It'll appear right there.", { bye("Got it.") })
		end,
	})
	table.insert(options, bye("Just looking, thanks."))
	return "Welcome to You Buy Car Now! You can also shop from the YBCN app on your phone.", options
end

local function atm(player, npc)
	local cash, bank = economy("Balance", player)
	cash, bank = cash or 0, bank or 0
	local function result(ok, text)
		say(player, npc, ok and text or "Transaction declined: not enough funds.", { bye("Done") })
	end
	local options = {}
	if cash > 0 then
		table.insert(options, {
			"deposit",
			"Deposit all cash ($" .. cash .. ")",
			function(p)
				local c = economy("Balance", p) or 0
				result(economy("Deposit", p, c), "Deposited $" .. c .. ".")
			end,
		})
	end
	for _, amount in ipairs({ 100, 500, 1000 }) do
		table.insert(options, {
			"withdraw" .. amount,
			"Withdraw $" .. amount,
			function(p)
				result(economy("Withdraw", p, amount), "Withdrew $" .. amount .. ".")
			end,
		})
	end
	table.insert(options, bye("Cancel"))
	return ("Balance: $%d cash, $%d in the bank."):format(cash, bank), options
end

local function lockpicks(action, player)
	local fn = ServerStorage:WaitForChild("Lockpicks", 10)
	if fn then
		return fn:Invoke(action, player)
	end
end

local function pablo(player, npc)
	local price = lockpicks("Price", player) or 150
	local options = {
		{
			"lockpick",
			("I need a lockpick. ($%d)"):format(price),
			function(p)
				local ok, message = lockpicks("Buy", p)
				if ok then
					say(p, npc, "Here. Bank of America's staff doors, then the vault keypad. You didn't get this from me. Come back for more any time.", { bye("Thanks.") })
				else
					say(p, npc, tostring(message or "No money, no pick."), { bye() })
				end
			end,
		},
		{
			"howto",
			"How does a bank job work?",
			function(p)
				say(p, npc, "Pick the staff doors at the Bank of America, get down to the vault, and crack the keypad. Alarm goes off, so grab the cash bags fast.", { bye("Got it.") })
			end,
		},
		bye("Never mind."),
	}
	return "You're not a cop, right?", options
end

-- Keyed by a path under Workspace ("CarDealer/Man") or an NPC's own name.
local DIALOGUES = {
	["CarDealer/Man"] = { name = "YBCN Dealer", talk = carDealer },
	["BB&B/Man"] = {
		name = "Gun Clerk",
		talk = simple("Welcome to Bloodbath & Beyond. Everything here is legal, unlike those street dealers.", {
			{ "What do you sell?", "Sidearms, rifles, the works. Our shipment hasn't come in yet though, check back later." },
		}),
	},
	["FurnitureShop/Man"] = {
		name = "Furniture Clerk",
		talk = simple("Hi there! Just bought a house? You'll want something to put in it.", {
			{ "How does furniture work?", "Buy a house at the Estate Agency first, then come back here to furnish it." },
		}),
	},
	["Hospital/Man"] = {
		name = "Receptionist",
		talk = simple("Las Vegas General, how can I help?", {
			{ "I need medicine.", "Medical staff can sell you medicine. You can also order it from the Meds app on your phone." },
		}),
	},
	["Man"] = {
		name = "Local",
		talk = simple("Hey. Nice day in Vegas, huh?", {
			{ "Any tips?", "Take the tour from the main menu if you're new. And watch out for the cops if you're speeding." },
		}),
	},
	Jose = { talk = simple("Psst. You looking for something the gun shop doesn't sell?", { { "What have you got?", "Nothing right now, cops have been sniffing around. Come back later." } }) },
	Pedro = { talk = simple("Keep your voice down, amigo.", { { "What have you got?", "I'm all sold out. Try Jose or Pablo." } }) },
	Pablo = { talk = pablo },
	Cesar = { talk = simple("Make it quick.", { { "What have you got?", "Shipment's late. Come back later." } }) },
	Rafael = { talk = simple("You want long range? I'm your guy.", { { "What have you got?", "Out of stock. Check back later." } }) },
	Tito = { talk = simple("You think you can beat me? I hold every race record in this city.", { { "Let's race!", "Not today, my car's in the shop. Come back later." } }) },
	Sofia = { talk = simple("Hi! Can I help you?", {}) },
	Cook = { talk = simple("Kitchen's busy, come back later.", {}) },
}

---------------------------------------------------------------------------
-- Plumbing
---------------------------------------------------------------------------
local conversations = {} -- [player] = { npc = Model, handlers = { [id] = fn } }
local npcInfo = {} -- [Model] = dialogue entry

local function rootOf(model)
	return model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart", true)
end

local function inRange(player, npc)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local npcRoot = npc:FindFirstChild("BankMachine") or rootOf(npc)
	return root and npcRoot and (root.Position - npcRoot.Position).Magnitude <= TALK_DISTANCE
end

say = function(player, npc, line, options)
	local handlers, wire = {}, {}
	for _, option in ipairs(options) do
		handlers[option[1]] = option[3] or false
		table.insert(wire, { option[1], option[2] })
	end
	conversations[player] = { npc = npc, handlers = handlers }
	local entry = npcInfo[npc]
	npc.Speech:FireClient(player, line, wire, entry and entry.name or npc.Name)
end

local function startConversation(player, npc)
	local entry = npcInfo[npc]
	if not entry or not inRange(player, npc) then
		return
	end
	local line, options = entry.talk(player, npc)
	say(player, npc, line, options)
end

local function onSpeech(player, npc, choice)
	if type(choice) ~= "string" then
		return
	end
	if choice == "StartConversation" then
		startConversation(player, npc)
		return
	end
	local convo = conversations[player]
	if not convo or convo.npc ~= npc or not inRange(player, npc) then
		return
	end
	local handler = convo.handlers[choice]
	conversations[player] = nil
	if handler then
		handler(player)
	end
end

local function register(npc, entry, promptPart)
	if npcInfo[npc] then
		return
	end
	npcInfo[npc] = entry

	local speech = npc:FindFirstChild("Speech")
	if not (speech and speech:IsA("RemoteEvent")) then
		speech = Instance.new("RemoteEvent")
		speech.Name = "Speech"
		speech.Parent = npc
	end
	speech.OnServerEvent:Connect(function(player, choice)
		onSpeech(player, npc, choice)
	end)

	local root = promptPart or rootOf(npc)
	if root then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "TalkPrompt"
		prompt.ActionText = entry.action or "Talk"
		prompt.ObjectText = entry.name or npc.Name
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = root
		prompt.Triggered:Connect(function(player)
			startConversation(player, npc)
		end)
	end
end

for _, child in ipairs(workspace:GetChildren()) do
	if child:IsA("Model") then
		local direct = DIALOGUES[child.Name]
		if direct and child:FindFirstChildOfClass("Humanoid") then
			register(child, direct)
		end
		for _, sub in ipairs(child:GetChildren()) do
			local entry = DIALOGUES[child.Name .. "/" .. sub.Name]
			if entry and sub:IsA("Model") and sub:FindFirstChildOfClass("Humanoid") then
				register(sub, entry)
			end
		end
	end
end

-- ATMs
local atmEntry = { name = "ATM", action = "Use", talk = atm }
for _, obj in ipairs(workspace:GetDescendants()) do
	if obj.Name == "BankMachine" and obj:IsA("BasePart") and obj.Parent:IsA("Model") then
		register(obj.Parent, atmEntry, obj)
	end
end

Players.PlayerRemoving:Connect(function(player)
	conversations[player] = nil
end)
