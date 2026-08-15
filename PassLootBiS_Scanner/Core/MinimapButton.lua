--[[ MinimapButton.lua -- a hand-rolled minimap button for the scanner.

Left-click opens the settings window (ns.Options); right-click flips scanning
on/off for a quick action; hover shows the current state. It is draggable around
the minimap ring and remembers its angle in db.minimap.angle.

We deliberately do NOT vendor LibDBIcon: modern copies assume APIs absent on the
3.3.5 client (C_Timer, Mixin, ...) and pinning a WotLK-era copy is a
version-matching hazard (DESIGN §2.3, §10). This uses only stock 3.3.5 widget
API. Pattern mirrored from PasslootBiS/Core/MinimapButton.lua -- but the scanner
owns its OWN button, independent of the importer's (DESIGN §6.5).

Pure/guarded split (same as every other file): the ring math is a pure function
with an offline self-test; everything touching CreateFrame sits behind the guard
so the file still loads under bare lua5.1.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local RADIUS        = 80    -- distance from minimap centre, in minimap-space
local DEFAULT_ANGLE = 220
local ICON          = "Interface\\Common\\UI-Searchbox-Icon"  -- magnifying glass (a scanner)

-- PURE: angle (degrees) -> (x, y) offset of the button from the minimap centre.
-- Offline-tested (tests/test_minimap.lua).
function MinimapButton.pos(angleDeg, radius)
	radius = radius or RADIUS
	local a = math.rad(angleDeg or DEFAULT_ANGLE)
	return math.cos(a) * radius, math.sin(a) * radius
end

-- PURE: cursor position (px,py) relative to the minimap centre (cx,cy) -> the
-- angle (degrees) to store while dragging. Inverse of MinimapButton.pos.
function MinimapButton.angleFromCursor(px, py, cx, cy)
	return math.deg(math.atan2(py - cy, px - cx))
end

-- Below here is WoW-API; skip entirely under bare lua5.1 so the pure math above
-- still loads and self-tests.
if not rawget(_G, "CreateFrame") then
	return MinimapButton
end

local button

local function currentAngle()
	local db = ns.db
	if db and db.minimap and db.minimap.angle then return db.minimap.angle end
	return DEFAULT_ANGLE
end

local function UpdatePosition()
	if not button then return end
	local x, y = MinimapButton.pos(currentAngle())
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging, follow the cursor around the ring and remember the angle.
local function DragOnUpdate()
	local cx, cy = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local px, py = GetCursorPosition()
	px, py = px / scale, py / scale
	local angle = MinimapButton.angleFromCursor(px, py, cx, cy)
	local db = ns.db
	if db and db.minimap then db.minimap.angle = angle end
	UpdatePosition()
end

local function OnTooltip(tooltip)
	if not (tooltip and tooltip.AddLine) then return end
	local db = ns.db or {}
	tooltip:SetText("PassLootBiS Scanner")
	tooltip:AddLine("|cffffffffLeft-click|r: settings window", 1, 1, 1)
	tooltip:AddLine("|cffffffffRight-click|r: toggle scanning", 1, 1, 1)
	tooltip:AddLine(" ")
	tooltip:AddLine("Scanning: " .. (db.enabled and "|cff00ff00on|r" or "|cffff0000off|r"))
	local cdb = ns.chardb   -- class/spec are per-character
	local cls, spc = cdb and cdb.class, cdb and cdb.spec
	local spec = (cls and spc) and ("|cffffd700" .. cls .. " / " .. spc .. "|r")
		or "|cffff0000none|r"
	tooltip:AddLine("Spec: " .. spec)
	tooltip:Show()
end

local function OnClick(mouseButton)
	if mouseButton == "RightButton" then
		local db = ns.db
		if db then
			db.enabled = not db.enabled
			DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PLBiS|r scanning "
				.. (db.enabled and "|cff00ff00on|r" or "|cffff0000off|r") .. ".")
			if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
		end
		-- Refresh the hover tooltip in place if it is still showing this button.
		if GameTooltip:IsOwned(button) then OnTooltip(GameTooltip) end
	else
		if ns.Options and ns.Options.Toggle then ns.Options.Toggle() end
	end
end

function MinimapButton.Create()
	if button then return button end

	button = CreateFrame("Button", "PLBiSScannerMinimapButton", Minimap)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetWidth(31)
	button:SetHeight(31)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture(ICON)
	icon:SetWidth(20)
	icon:SetHeight(20)
	icon:SetPoint("CENTER", button, "CENTER", 0, 0)
	button.icon = icon

	-- Standard round minimap-button frame so the square dice reads as a button.
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetWidth(53)
	border:SetHeight(53)
	border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	button.border = border

	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	button:SetScript("OnClick", function(_, mouseButton) OnClick(mouseButton) end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		OnTooltip(GameTooltip)
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	button:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", DragOnUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		self:UnlockHighlight()
	end)

	UpdatePosition()
	if ns.db and ns.db.minimap and ns.db.minimap.hide then
		button:Hide()
	end
	return button
end

-- Options hook (the "Hide minimap button" checkbox). Persists the choice and
-- shows/hides the live button.
function MinimapButton.SetHidden(hide)
	hide = hide and true or false
	local db = ns.db
	if db and db.minimap then db.minimap.hide = hide end
	if button then
		if hide then button:Hide() else button:Show() end
	end
end

return MinimapButton
