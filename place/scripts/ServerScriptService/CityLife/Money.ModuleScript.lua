--[[
	CityLife.Money (v259, v272) - where the money hides (Connections > Money)

	METALS: gold and silver bars from a bullion dealer. Paid in cash or bank (dirty cash spends
	  too). Kept in your profile - an asset freeze can't touch them. Sold back for clean money
	  in the bank at a spread. Prices drift every few minutes.
	OFFSHORE: a fiduciary (through Sal) moves cash to an account nobody can freeze. 12% to
	  wire it out (it lands a few minutes later), 8% to bring it back clean into the bank.
	  When the fiduciary trade gets too hot the network can be EXPOSED: accounts seized, the news.
	FIRM-MANAGED ASSETS (v259): a retained firm (Criminal Defense Firm and up) holds money in
	  its client trust for you - safe from freezes, 3% in, 2% out, honest and legal.
	Logs: [Money]
]]

local Players = game:GetService("Players")

local M = {}
local Core: any

local CFG = {
	Gold = 10000,
	Silver = 600,
	Spread = 0.92,
	OffshoreIn = 0.12,
	OffshoreOut = 0.08,
	OffshoreDelay = 4 * 60,
	EscrowIn = 0.03,
	EscrowOut = 0.02,
	EscrowFirms = { ["Criminal Defense Firm"] = true, ["Elite Defense Team"] = true, ["National Trial Firm"] = true, ["Premier Counsel"] = true },
}
local price = { gold = CFG.Gold, silver = CFG.Silver }

local function amountOf(arg: any): number
	return math.floor(math.max(0, tonumber(arg) or 0))
end

function M.exposure()
	Core.log("Money", "OFFSHORE NETWORK EXPOSED")
	local hit = {}
	for _, p in Players:GetPlayers() do
		local prof = Core.Profile.peek(p)
		if prof and (prof.offshore.balance or 0) > 0 and math.random() < 0.5 then
			local lost = prof.offshore.balance
			prof.offshore.balance = 0
			Core.Profile.dirty(p)
			Core.UI.notice(p, ("Your offshore account was seized: %s"):format(Core.UI.money(lost)), 8, Color3.fromRGB(120, 20, 20))
			table.insert(hit, p)
		end
	end
	if Core.News then
		Core.News.post({ kind = "money", level = 2, headline = "Offshore money network exposed - accounts frozen",
			body = ("Federal agents seized accounts tied to %d Las Vegas residents."):format(#hit), subjects = hit })
	end
end

local function lines(player: Player): { any }
	local prof = Core.Profile.get(player)
	local m, o = prof.metals, prof.offshore
	local firm = tostring(player:GetAttribute("LawyerFirm") or "")
	local escrowOk = CFG.EscrowFirms[firm] == true and player:GetAttribute("CounselRetained") ~= nil -- v286o: the firm name, not true
	local out = {
		{ id = "m_buygold", cat = "Money", who = "Desert Bullion Co.", title = ("Buy a gold bar (%s)"):format(Core.UI.money(price.gold)), price = price.gold,
			desc = ("You hold %d gold, %d silver. Freezes can't touch metal."):format(m.gold or 0, m.silver or 0), available = true },
		{ id = "m_buysilver", cat = "Money", who = "Desert Bullion Co.", title = ("Buy 10 silver bars (%s)"):format(Core.UI.money(price.silver * 10)), price = price.silver * 10, desc = "", available = true },
		{ id = "m_sellgold", cat = "Money", who = "Desert Bullion Co.", title = ("Sell a gold bar (+%s to the bank)"):format(Core.UI.money(math.floor(price.gold * CFG.Spread))), price = 0,
			desc = "Clean money, into your bank.", available = (m.gold or 0) > 0, why = "You have no gold" },
		{ id = "m_sellsilver", cat = "Money", who = "Desert Bullion Co.", title = ("Sell 10 silver (+%s)"):format(Core.UI.money(math.floor(price.silver * 10 * CFG.Spread))), price = 0,
			desc = "", available = (m.silver or 0) >= 10, why = "You need 10 silver" },
		{ id = "o_in", cat = "Money", who = "Mr. Lindqvist (fiduciary)", title = "Wire cash offshore", price = 0, illegal = true, target = "amount",
			desc = ("12%% fee, lands in %d min. Balance %s%s."):format(CFG.OffshoreDelay // 60, Core.UI.money(o.balance or 0), if #(o.pending or {}) > 0 then " (+ transfers pending)" else ""),
			available = not (Core.Underground and Core.Underground.dark("fiduciaries")), why = "Lindqvist isn't answering" },
		{ id = "o_out", cat = "Money", who = "Mr. Lindqvist (fiduciary)", title = "Bring money home (clean, to the bank)", price = 0, illegal = true, target = "amount",
			desc = "8% fee.", available = (o.balance or 0) > 0, why = "Nothing offshore" },
		{ id = "e_in", cat = "Money", who = (if firm ~= "" then firm else "Your law firm"), title = "Firm-managed assets: deposit", price = 0, target = "amount",
			desc = ("The firm's client trust holds it - safe from freezes. 3%% in. Held: %s"):format(Core.UI.money(prof.escrow or 0)),
			available = escrowOk, why = "Needs a retained Criminal Defense Firm or better" },
		{ id = "e_out", cat = "Money", who = (if firm ~= "" then firm else "Your law firm"), title = "Firm-managed assets: withdraw", price = 0, target = "amount",
			desc = "2% out, to your bank.", available = (prof.escrow or 0) > 0, why = "Nothing held" },
	}
	return out
end

local function run(id: string): (Player, any) -> (boolean, string)
	return function(player: Player, arg: any): (boolean, string)
		local prof = Core.Profile.get(player)
		local m, o = prof.metals, prof.offshore
		if id == "m_buygold" or id == "m_buysilver" then
			local gold = id == "m_buygold"
			local cost = if gold then price.gold else price.silver * 10
			if not Core.charge(player, cost) then return false, "You need " .. Core.UI.money(cost) end
			if gold then m.gold = (m.gold or 0) + 1 else m.silver = (m.silver or 0) + 10 end
			Core.Profile.dirty(player)
			Core.log("Money", "%s bought %s", player.Name, if gold then "gold" else "silver")
			return true, ("Bought. You hold %d gold, %d silver."):format(m.gold or 0, m.silver or 0)
		elseif id == "m_sellgold" or id == "m_sellsilver" then
			local gold = id == "m_sellgold"
			if gold and (m.gold or 0) < 1 then return false, "No gold" end
			if not gold and (m.silver or 0) < 10 then return false, "Not enough silver" end
			local pay = math.floor((if gold then price.gold else price.silver * 10) * CFG.Spread)
			if gold then m.gold -= 1 else m.silver -= 10 end
			Core.pay(player, pay, "bank")
			Core.Profile.dirty(player)
			if Core.Underground then Core.Underground.bump("fences", 0.01, "metal sold") end
			return true, ("Sold for %s (clean, in your bank)"):format(Core.UI.money(pay))
		elseif id == "o_in" then
			local n = amountOf(arg)
			if n < 1000 then return false, "Enter at least $1,000" end
			if Core.Underground and Core.Underground.dark("fiduciaries") then return false, "Lindqvist isn't answering" end
			if not Core.charge(player, n) then return false, "You don't have " .. Core.UI.money(n) end
			Core.Underground.used(player, "fiduciaries")
			if Core.Connections.risky(player, 0.04, n, "fiduciaries") then
				Core.Connections.caught(player, "MoneyLaundering", "Money laundering", "fiduciaries")
				return false, "The wire was flagged. The money is gone."
			end
			local net = math.floor(n * (1 - CFG.OffshoreIn))
			o.pending = o.pending or {}
			table.insert(o.pending, { amount = net, at = os.time() + CFG.OffshoreDelay })
			Core.Profile.dirty(player)
			Core.Underground.bump("fiduciaries", 0.01 + math.min(0.05, n / 5e7), "a wire")
			return true, ("%s is on its way (lands in %d min)"):format(Core.UI.money(net), CFG.OffshoreDelay // 60)
		elseif id == "o_out" then
			local n = math.min(amountOf(arg), o.balance or 0)
			if n <= 0 then return false, "Enter an amount" end
			o.balance -= n
			local net = math.floor(n * (1 - CFG.OffshoreOut))
			Core.Profile.dirty(player)
			if Core.Connections.risky(player, 0.03, n, "fiduciaries") then
				Core.Connections.caught(player, "MoneyLaundering", "Money laundering", "fiduciaries")
				return false, "The transfer was flagged and seized."
			end
			task.delay(180, function()
				if player.Parent then
					Core.pay(player, net, "bank")
					Core.UI.notice(player, ("Offshore transfer arrived: %s (clean)"):format(Core.UI.money(net)), 5)
				else
					o.balance += n -- they left: it stays offshore
				end
			end)
			return true, ("%s will be in your bank in 3 minutes"):format(Core.UI.money(net))
		elseif id == "e_in" then
			local n = amountOf(arg)
			if n < 1000 then return false, "Enter at least $1,000" end
			if player:GetAttribute("AssetsFrozen") then return false, "Your assets are frozen - too late" end
			if not Core.charge(player, n) then return false, "You don't have " .. Core.UI.money(n) end
			prof.escrow = (prof.escrow or 0) + math.floor(n * (1 - CFG.EscrowIn))
			Core.Profile.dirty(player)
			return true, ("The firm holds %s for you"):format(Core.UI.money(prof.escrow))
		elseif id == "e_out" then
			local n = math.min(amountOf(arg), prof.escrow or 0)
			if n <= 0 then return false, "Enter an amount" end
			prof.escrow -= n
			Core.pay(player, math.floor(n * (1 - CFG.EscrowOut)), "bank")
			Core.Profile.dirty(player)
			return true, "Transferred to your bank"
		end
		return false, "?"
	end
end

function M.init(core: any)
	Core = core
	Core.Money = M
	Core.Connections.extraLists["money"] = lines
	for _, id in { "m_buygold", "m_buysilver", "m_sellgold", "m_sellsilver", "o_in", "o_out", "e_in", "e_out" } do
		Core.Connections.extraRun[id] = run(id)
	end
	task.spawn(function()
		while true do
			task.wait(15)
			local now = os.time()
			for _, p in Players:GetPlayers() do
				local prof = Core.Profile.peek(p)
				local o = prof and prof.offshore
				if o and o.pending and #o.pending > 0 then
					for i = #o.pending, 1, -1 do
						local t = o.pending[i]
						if now >= t.at then
							o.balance = (o.balance or 0) + t.amount
							table.remove(o.pending, i)
							Core.UI.notice(p, ("Offshore: %s landed. Balance %s"):format(Core.UI.money(t.amount), Core.UI.money(o.balance)), 5)
							Core.Profile.dirty(p)
						end
					end
				end
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(300)
			price.gold = math.floor(CFG.Gold * (0.9 + math.random() * 0.2))
			price.silver = math.floor(CFG.Silver * (0.88 + math.random() * 0.24))
		end
	end)
	print("[Money] v259/v272 ready (metals, offshore, firm-managed assets)")
end

return M
