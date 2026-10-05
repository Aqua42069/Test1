-- PlayerDefaults (v200)
-- One place for starting balances, shared by EconomyServer (new profiles) and
-- PoliceSystem (Death Row wipe). Names are matched case-insensitively.

local PlayerDefaults = {}

PlayerDefaults.STARTING_CASH = 500
PlayerDefaults.STARTING_BANK = 2500

-- Players who always start with a special balance (new profile, after a
-- Death Row wipe, and topped back up to at least this bank balance on join).
PlayerDefaults.Special = {
	aquagaming22 = { cash = 0, bank = 50000000 },
}

function PlayerDefaults.special(player: Player)
	return PlayerDefaults.Special[string.lower(player.Name)]
end

-- (cash, bank) for a fresh start
function PlayerDefaults.start(player: Player): (number, number)
	local s = PlayerDefaults.special(player)
	if s then
		return s.cash, s.bank
	end
	return PlayerDefaults.STARTING_CASH, PlayerDefaults.STARTING_BANK
end

-- minimum bank balance applied on every join (0 = none)
function PlayerDefaults.bankFloor(player: Player): number
	local s = PlayerDefaults.special(player)
	return if s then s.bank else 0
end

return PlayerDefaults
