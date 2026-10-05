-- MobileLayout (v207)
-- On touch devices the bottom-left corner is the thumbstick and the bottom-right
-- corner is the jump button. HUD pieces that sit there on desktop are moved:
--   * Surrender button     -> right edge, under the phone button
--   * Wanted list (police) -> top-left
--   * Ammo counter         -> top-right
--   * Custody / jail timer banners -> top-centre
-- The cell phone has its own mobile mode (StarterGui.CellPhone.PhoneToggle).
-- Desktop layouts are left exactly as authored.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function isMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

type Layout = { anchor: Vector2, pos: UDim2, size: UDim2? }

-- keyed by "<ScreenGui>/<element>"
local MOBILE: { [string]: Layout } = {
	["PoliceAI_HUD/Surrender"] = {
		anchor = Vector2.new(1, 0),
		pos = UDim2.new(1, -12, 0.38, 36),
		size = UDim2.fromOffset(112, 38),
	},
	["PoliceAI_HUD/WantedList"] = {
		anchor = Vector2.new(0, 0),
		pos = UDim2.new(0, 12, 0, 8),
	},
	-- wide bottom-centre banners reach into both thumb zones: move them up top
	["PoliceAI_HUD/Custody"] = {
		anchor = Vector2.new(0.5, 0),
		pos = UDim2.new(0.5, 0, 0, 8),
		size = UDim2.new(0.55, 0, 0, 40),
	},
	["PoliceAI_HUD/Jail"] = {
		anchor = Vector2.new(0.5, 0),
		pos = UDim2.new(0.5, 0, 0, 8),
	},
	["AmmoHud/*TextLabel"] = {
		anchor = Vector2.new(1, 0),
		pos = UDim2.new(1, -12, 0, 8),
		size = UDim2.new(0.18, 0, 0, 30),
	},
}

local desktop: { [GuiObject]: Layout } = {}

local function keyFor(obj: GuiObject): string?
	local screen = obj:FindFirstAncestorWhichIsA("ScreenGui")
	if not screen or obj.Parent ~= screen then
		return nil
	end
	local named = screen.Name .. "/" .. obj.Name
	if MOBILE[named] then
		return named
	end
	local byClass = screen.Name .. "/*" .. obj.ClassName
	if MOBILE[byClass] then
		return byClass
	end
	return nil
end

local function apply(obj: GuiObject)
	local key = keyFor(obj)
	if not key then
		return
	end
	if not desktop[obj] then
		desktop[obj] = { anchor = obj.AnchorPoint, pos = obj.Position, size = obj.Size }
	end
	local layout = if isMobile() then MOBILE[key] else desktop[obj]
	obj.AnchorPoint = layout.anchor
	obj.Position = layout.pos
	if layout.size then
		obj.Size = layout.size
	end
end

local function applyAll()
	for obj in desktop do
		if obj.Parent then
			apply(obj)
		else
			desktop[obj] = nil
		end
	end
end

playerGui.DescendantAdded:Connect(function(obj)
	if obj:IsA("GuiObject") then
		task.defer(apply, obj)
	end
end)
for _, obj in playerGui:GetDescendants() do
	if obj:IsA("GuiObject") then
		apply(obj)
	end
end

-- a tablet gaining or losing a keyboard switches layouts
local wasMobile = isMobile()
UserInputService.LastInputTypeChanged:Connect(function()
	local now = isMobile()
	if now ~= wasMobile then
		wasMobile = now
		applyAll()
	end
end)
