local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

--[[
Self-contained minimap button (Phase 0 of the minimap/Loot-Window feature; see
reference/minimap-loot-window-plan.md).

We deliberately do NOT vendor LibDBIcon-1.0: modern LibDBIcon relies on APIs that
don't exist on the 3.3.5 client (C_Timer, Mixin, …), and pinning a WotLK-era copy
is a version-matching hazard. This button uses only stock 3.3.5 widget API
(CreateFrame / Minimap / GetCursorPosition / drag scripts), so there is nothing to
keep in sync. The existing LibDataBroker launcher object (Core/PassLoot.lua) is
kept untouched so external display addons (Titan, etc.) still work; both it and
this button funnel into the same MinimapButton_OnClick / MinimapButton_OnTooltip
handlers so their behaviour never drifts.

Click routing: LEFT-click opens a submenu to open the Loot Window, the BiS
Manager window, or the Blizzard Interface > AddOns settings (PassLoot (BiS) main
window, subtree expanded); RIGHT-click opens the per-rule on/off toggle menu.
(Both this button and the LibDataBroker launcher funnel through
MinimapButton_OnClick.)
]]

-- The WoW Need-roll dice (the green "Need" button on the group-loot roll frame).
PasslootBiS.MINIMAP_ICON = "Interface\\Buttons\\UI-GroupLoot-Dice-Up"

local BUTTON_NAME = "PasslootBiS_MinimapButton"
local RADIUS = 80 -- distance from the minimap centre to the button, in minimap-space

-- Place the button on the minimap ring at the saved angle (degrees).
local function UpdatePosition(button)
	local angle = math.rad(PasslootBiS.db.profile.Minimap.pos or 220)
	local x = math.cos(angle) * RADIUS
	local y = math.sin(angle) * RADIUS
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging, follow the cursor around the ring and remember the angle.
local function DragOnUpdate(button)
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local px, py = GetCursorPosition()
	px, py = px / scale, py / scale
	PasslootBiS.db.profile.Minimap.pos = math.deg(math.atan2(py - my, px - mx))
	UpdatePosition(button)
end

-- Left-click menu: pick which window to open (the Loot Window or the BiS Manager
-- window). Both are plain gameplay frames toggled open here; the menu is one-shot
-- so each row just opens its window. Uses the shared UIDropDownMenu frame.
local function InitOpenMenu(_, level)
	level = level or 1

	local info = UIDropDownMenu_CreateInfo()
	info.isTitle = true
	info.notCheckable = true
	info.text = L["Minimap_OpenTitle"]
	UIDropDownMenu_AddButton(info, level)

	info = UIDropDownMenu_CreateInfo()
	info.notCheckable = true
	info.text = L["Minimap_OpenLootWindow"]
	info.func = function()
		PasslootBiS:ToggleLootWindow(true)
		CloseDropDownMenus()
	end
	UIDropDownMenu_AddButton(info, level)

	info = UIDropDownMenu_CreateInfo()
	info.notCheckable = true
	info.text = L["Minimap_OpenBiSManager"]
	info.func = function()
		PasslootBiS:ToggleBiSManagerWindow(true)
		CloseDropDownMenus()
	end
	UIDropDownMenu_AddButton(info, level)

	info = UIDropDownMenu_CreateInfo()
	info.notCheckable = true
	info.text = L["Minimap_OpenSettings"]
	info.func = function()
		PasslootBiS:OpenBlizSettings()
		CloseDropDownMenus()
	end
	UIDropDownMenu_AddButton(info, level)
end

-- Open the Blizzard Interface > AddOns panel to PassLoot (BiS)'s main window, with
-- its sub-page tree expanded. Blizzard expands a target's PARENT node so the target
-- is visible but never a target's own children, so we open to a child first (which
-- expands the PassLoot (BiS) node), then select the parent to land on the main
-- window — the subtree stays open since selecting doesn't re-collapse it. The
-- repeat parent call works around the 3.3.5 quirk where the first OpenToCategory
-- after the frame opens doesn't always display the chosen panel.
function PasslootBiS:OpenBlizSettings()
	if (type(InterfaceOptionsFrame_OpenToCategory) ~= "function") then
		return
	end
	local child = self.BlizOptionsFrames and self.BlizOptionsFrames["Import"]
	if (child) then
		InterfaceOptionsFrame_OpenToCategory(child)   -- expands the PassLoot (BiS) subtree
	end
	local main = self.RulesFrame or L["PasslootBiS"]
	InterfaceOptionsFrame_OpenToCategory(main)
	InterfaceOptionsFrame_OpenToCategory(main)
end

-- Right-click menu: one checkable row per PassLoot rule; ticking toggles the
-- rule's `Disabled` flag, which the roll-evaluation loop in PassLoot.lua honours
-- (a disabled rule is skipped entirely — no roll). Uses the addon's existing
-- UIDropDownMenu frame (PasslootBiS.DropDownFrame, created in OnInitialize).
local function InitRuleMenu(_, level)
	level = level or 1
	local rules = PasslootBiS.db.profile.Rules

	local info = UIDropDownMenu_CreateInfo()
	info.isTitle = true
	info.notCheckable = true
	info.text = L["Minimap_RulesTitle"]
	UIDropDownMenu_AddButton(info, level)

	if (not rules or #rules == 0) then
		info = UIDropDownMenu_CreateInfo()
		info.notCheckable = true
		info.disabled = true
		info.text = L["Minimap_NoRules"]
		UIDropDownMenu_AddButton(info, level)
		return
	end

	for index, rule in ipairs(rules) do
		info = UIDropDownMenu_CreateInfo()
		info.text = rule.Desc
		info.isNotRadio = true          -- checkbox, not a radio dot
		info.keepShownOnClick = true    -- let the user flip several without reopening
		info.checked = not rule.Disabled -- ticked == enabled
		-- Flipped through the shared setter (PasslootBiS:ToggleRuleDisabled) rather than
		-- here: the same tick now also sits on the rule's own right-click menu on the
		-- rules page, and turning a rule off has to reset the evaluation cache as well
		-- as repaint the list. Two copies of that would drift.
		--
		-- The STORED flag decides, not the 4th arg 3.3.5 passes (the new visual state
		-- after its auto-toggle). The two agree -- the visual was drawn from that same
		-- flag when the menu opened -- and reading the flag keeps this identical to the
		-- other entry point.
		info.func = function()
			PasslootBiS:ToggleRuleDisabled(index)
		end
		UIDropDownMenu_AddButton(info, level)
	end
end

-- Shared click handler: both this button and the LibDataBroker launcher call it.
function PasslootBiS:MinimapButton_OnClick(button)
	if (button == "RightButton") then
		-- Right-click: the rule on/off menu anchored at the cursor.
		UIDropDownMenu_Initialize(self.DropDownFrame, InitRuleMenu, "MENU")
		ToggleDropDownMenu(1, nil, self.DropDownFrame, "cursor", 0, 0)
	else
		-- Left-click: the "open a window" submenu (Loot Window / BiS Manager).
		UIDropDownMenu_Initialize(self.DropDownFrame, InitOpenMenu, "MENU")
		ToggleDropDownMenu(1, nil, self.DropDownFrame, "cursor", 0, 0)
	end
end

-- Shared tooltip: fills GameTooltip (button) or an LDB tooltip (external display).
function PasslootBiS:MinimapButton_OnTooltip(tooltip)
	if (not (tooltip and tooltip.AddLine)) then
		return
	end
	tooltip:SetText(L["PasslootBiS"])
	tooltip:AddLine(L["Minimap_LeftClick"], 1, 1, 1)
	tooltip:AddLine(L["Minimap_RightClick"], 1, 1, 1)
	if (self.LastRolls and #self.LastRolls > 0) then
		tooltip:AddLine(" ")
		for _, line in ipairs(self.LastRolls) do
			tooltip:AddLine(line)
		end
	end
	tooltip:Show()
end

function PasslootBiS:CreateMinimapButton()
	if (self.MinimapButton) then
		return
	end

	local button = CreateFrame("Button", BUTTON_NAME, Minimap)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetWidth(31)
	button:SetHeight(31)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture(PasslootBiS.MINIMAP_ICON)
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

	button:SetScript("OnClick", function(_, mouseButton)
		PasslootBiS:MinimapButton_OnClick(mouseButton)
	end)
	button:SetScript("OnEnter", function(self2)
		GameTooltip:SetOwner(self2, "ANCHOR_LEFT")
		PasslootBiS:MinimapButton_OnTooltip(GameTooltip)
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStart", function(self2)
		self2:LockHighlight()
		self2:SetScript("OnUpdate", DragOnUpdate)
	end)
	button:SetScript("OnDragStop", function(self2)
		self2:SetScript("OnUpdate", nil)
		self2:UnlockHighlight()
	end)

	self.MinimapButton = button
	UpdatePosition(button)
	if (self.db.profile.Minimap.hide) then
		button:Hide()
	end
end

-- Options hook (used by the "Show Minimap Button" toggle, wired in Phase 4/config).
function PasslootBiS:SetMinimapButtonHidden(hide)
	self.db.profile.Minimap.hide = hide and true or false
	if (self.MinimapButton) then
		if (hide) then
			self.MinimapButton:Hide()
		else
			self.MinimapButton:Show()
		end
	end
end
