local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

--[[
The right-click "Loot Window" (Phase 2 + 3 of the minimap feature; see
reference/minimap-loot-window-plan.md). A movable, closable floating frame that
renders the per-item roll log collected by Modules/LootTracker.lua (who rolled
what, and who won).

§8.6 note: on this client, StaticPopups/overlays render BEHIND the Interface
Options window. This is a plain gameplay-time frame (not a StaticPopup) shown
while the options window is closed, so it should render fine — but that is the
in-game smoke-test gate for this phase. If it misbehaves, the fallback is an
options-page render of the same log.

All addon state lives here (the runtime log + persistence + redraw); the module
only parses chat and pushes events in via LootTracker_Record / LootTracker_OpenRoll.
]]

local MAX_GROUPS = 50

-- Roll-choice display: colour (WoW |cAARRGGBB) + label.
local CHOICE_COLORS = {
	["need"]       = "ff40ff40",
	["greed"]      = "ffffcc33",
	["disenchant"] = "ffcc66ff",
	["pass"]       = "ff999999",
}
local function choiceLabel(choice)
	if (choice == "need") then return L["Need"] end
	if (choice == "greed") then return L["Greed"] end
	if (choice == "disenchant") then return L["Disenchant"] end
	if (choice == "pass") then return L["Pass"] end
	return choice or "?"
end

-- Lazily hydrate the runtime log from the persisted groups array.
local function ensureLog(self)
	if (not self.LootLog) then
		if (self.LootTracker) then
			self.LootLog = self.LootTracker.Hydrate(self.db.profile.LootWindow.log)
		else
			self.LootLog = { groups = {}, openByKey = {} }
		end
	end
	return self.LootLog
end

local function persist(self)
	self.db.profile.LootWindow.log = self.LootLog.groups
end

-- WoW FontStrings can't change size/weight INLINE within one multiline string
-- (only colour via |c..|r), so the window renders as a POOL of per-line
-- FontStrings (f.rows). The base body size is user-selectable via the top "A"
-- dropdown (persisted per character); the winner + Need lines render
-- EMPHASIS_DELTA points larger. FONT_NORMAL supplies the typeface + white colour
-- the rows are built from; each row's SIZE is overridden per render via SetFont.
local FONT_NORMAL = "GameFontHighlightSmall"
local FONT_SIZES = { 8, 10, 12, 14, 16, 18 }
local DEFAULT_FONT_SIZE = 10
local EMPHASIS_DELTA = 2

local function currentFontSize()
	local lw = PasslootBiS.db and PasslootBiS.db.profile and PasslootBiS.db.profile.LootWindow
	local s = lw and lw.fontSize
	return (type(s) == "number" and s) or DEFAULT_FONT_SIZE
end

-- Threshold colour for a need count: 3 green, 4 yellow, 5+ red (callouts only show
-- from 3 on, so the sub-3 white fallback is never reached in practice).
local function needStreakColor(n)
	if (n >= 5) then return "ffff3333" end   -- red
	if (n == 4) then return "ffffcc00" end    -- yellow
	if (n == 3) then return "ff40ff40" end    -- green
	return "ffffffff"
end

local function acquireRow(f, idx)
	local row = f.rows[idx]
	if (not row) then
		row = f.content:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
		row:SetJustifyH("LEFT")
		row:SetJustifyV("TOP")
		f.rows[idx] = row
	end
	return row
end

-- Lay the line descriptors (f.lineDescs = { {str=, big=}, ... }) out as pooled
-- FontStrings at the CURRENT scroll width, stacking top-down, and size the scroll
-- child to the total height so the scrollbar range tracks it. Called from render
-- and live from the resize grip (OnSizeChanged), so lines re-wrap to the window
-- width instead of clipping.
local function layoutRows(f)
	if (not f or not f.scroll or not f.rows or not f.lineDescs) then return end
	local sw = f.scroll:GetWidth()
	if (not sw or sw < 40) then sw = (f:GetWidth() or 180) - 50 end
	if (sw < 40) then sw = 40 end
	f.content:SetWidth(sw)
	local width = sw - 6
	-- Typeface + flags come from the base font object; the SIZE is the user's
	-- chosen body size (emphasis lines a couple points larger), applied per row.
	local base = currentFontSize()
	local path, flags = "Fonts\\FRIZQT__.TTF", ""
	local fontObj = rawget(_G, FONT_NORMAL)
	if (fontObj and fontObj.GetFont) then
		local p, _, fl = fontObj:GetFont()
		if (p) then path = p; flags = fl or "" end
	end
	local y = -2
	for i, d in ipairs(f.lineDescs) do
		local row = acquireRow(f, i)
		row:SetFont(path, d.big and (base + EMPHASIS_DELTA) or base, flags)
		row:SetWidth(width)
		row:SetText(d.str or "")
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 2, y)
		row:Show()
		local h = row:GetStringHeight()
		if (h < 1) then h = 1 end
		y = y - h - 1
	end
	for i = #f.lineDescs + 1, #f.rows do f.rows[i]:Hide() end
	local total = (-y) + 4
	if (total < 1) then total = 1 end
	f.content:SetHeight(total)
end

-- Called by LootTracker with a parsed event.
function PasslootBiS:LootTracker_Record(ev)
	local LT = self.LootTracker
	if (not LT) then return end
	local log = ensureLog(self)
	LT.ApplyEvent(log, ev, UnitName("player"))
	LT.Trim(log, MAX_GROUPS)
	persist(self)
	if (self.LootWindowFrame and self.LootWindowFrame:IsShown()) then
		self:LootWindow_Render()
	end
end

-- Called by LootTracker on START_LOOT_ROLL so the item shows even with no rolls.
function PasslootBiS:LootTracker_OpenRoll(link)
	local LT = self.LootTracker
	if (not LT) then return end
	local log = ensureLog(self)
	LT.OpenRoll(log, link)
	LT.Trim(log, MAX_GROUPS)
	persist(self)
	if (self.LootWindowFrame and self.LootWindowFrame:IsShown()) then
		self:LootWindow_Render()
	end
end

-- Font-size dropdown (the "A" button by the close X). A radio list of sizes; the
-- pick persists to db.profile.LootWindow.fontSize (per character) and re-renders.
-- Uses the addon's shared UIDropDownMenu frame (PasslootBiS.DropDownFrame).
local function InitFontMenu(_, level)
	level = level or 1
	local info = UIDropDownMenu_CreateInfo()
	info.isTitle = true
	info.notCheckable = true
	info.text = L["LootWindow_FontSize"]
	UIDropDownMenu_AddButton(info, level)

	local cur = currentFontSize()
	for _, sz in ipairs(FONT_SIZES) do
		info = UIDropDownMenu_CreateInfo()
		info.text = tostring(sz)
		info.checked = (sz == cur)
		info.func = function()
			PasslootBiS.db.profile.LootWindow.fontSize = sz
			PasslootBiS:LootWindow_Render()
			CloseDropDownMenus()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end

function PasslootBiS:CreateLootWindow()
	if (self.LootWindowFrame) then
		return self.LootWindowFrame
	end

	local f = CreateFrame("Frame", "PasslootBiS_LootWindow", UIParent)
	local lw = self.db.profile.LootWindow
	-- Default ~a quarter of the original 360x420 footprint (half each dimension);
	-- a saved per-character size (from the resize grip) overrides.
	f:SetWidth((lw and lw.w) or 180)
	f:SetHeight((lw and lw.h) or 210)
	f:SetResizable(true)
	f:SetMinResize(160, 150)
	f:SetMaxResize(800, 900)
	-- FULLSCREEN_DIALOG, and deliberately NO SetToplevel: on Ascension 3.3.5 a
	-- SetToplevel(true) frame re-raises on every click/drag, and each raise
	-- restacks the strata (~50ms on FULLSCREEN_DIALOG, a full ~0.6-2.6s freeze on
	-- HIGH). This is a singleton window that never needs click-to-raise, so
	-- dropping SetToplevel gives 0 spikes on drag; the high strata still renders
	-- it above DIALOG-strata panels, and Raise() on open (ToggleLootWindow) puts
	-- it in front. (see DRAGFREEZE note — the "0 spikes" cure)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetBackdrop({
		["bgFile"] = "Interface\\DialogFrame\\UI-DialogBox-Background",
		["edgeFile"] = "Interface\\DialogFrame\\UI-DialogBox-Border",
		["tile"] = true,
		["tileSize"] = 32,
		["edgeSize"] = 32,
		["insets"] = { ["left"] = 11, ["right"] = 12, ["top"] = 12, ["bottom"] = 11 },
	})
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
	f:SetScript("OnDragStop", function(frame)
		frame:StopMovingOrSizing()
		local point, _, relPoint, x, y = frame:GetPoint()
		local lw = PasslootBiS.db.profile.LootWindow
		lw.point, lw.relPoint, lw.x, lw.y = point, relPoint, x, y
	end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", f, "TOP", 0, -16)
	title:SetText(L["LootWindow_Title"])

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
	close:SetScript("OnClick", function() PasslootBiS:ToggleLootWindow(false) end)

	-- Font-size selector: a small button just left of the close X. Its label is the
	-- current body size; clicking opens the size dropdown (InitFontMenu).
	local fontBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	fontBtn:SetWidth(28)
	fontBtn:SetHeight(20)
	fontBtn:SetPoint("RIGHT", close, "LEFT", 2, 0)
	fontBtn:SetText(tostring(currentFontSize()))
	fontBtn:SetScript("OnClick", function()
		if (not PasslootBiS.DropDownFrame) then return end
		UIDropDownMenu_Initialize(PasslootBiS.DropDownFrame, InitFontMenu, "MENU")
		ToggleDropDownMenu(1, nil, PasslootBiS.DropDownFrame, fontBtn, 0, 0)
	end)
	fontBtn:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip:SetText(L["LootWindow_FontSize"])
		GameTooltip:Show()
	end)
	fontBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.fontBtn = fontBtn

	local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	clear:SetWidth(90)
	clear:SetHeight(22)
	clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
	clear:SetText(L["LootWindow_Clear"])
	clear:SetScript("OnClick", function() PasslootBiS:LootWindow_Clear() end)

	local scroll = CreateFrame("ScrollFrame", "PasslootBiS_LootWindowScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -40)
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 44)

	local content = CreateFrame("Frame", "PasslootBiS_LootWindowContent", scroll)
	content:SetWidth(300)
	content:SetHeight(1)
	scroll:SetScrollChild(content)

	f.content = content
	f.scroll = scroll
	f.rows = {}          -- pool of per-line FontStrings (see layoutRows)
	f.lineDescs = {}     -- current line descriptors: { {str=, big=}, ... }

	-- Reflow the lines to the new width while the window is being dragged-to-size.
	scroll:SetScript("OnSizeChanged", function() layoutRows(f) end)

	-- Bottom-right resize grip (standard 3.3.5 size-grabber texture).
	local resize = CreateFrame("Button", nil, f)
	resize:SetWidth(16)
	resize:SetHeight(16)
	resize:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
	resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	resize:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	resize:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		local d = PasslootBiS.db.profile.LootWindow
		d.w, d.h = f:GetWidth(), f:GetHeight()
		PasslootBiS:LootWindow_Render()
	end)
	f.resize = resize

	self.LootWindowFrame = f

	-- Restore saved position (or centre).
	f:ClearAllPoints()
	if (lw.point) then
		f:SetPoint(lw.point, UIParent, lw.relPoint or lw.point, lw.x or 0, lw.y or 0)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	f:Hide()
	return f
end

-- show: true/false, or nil to toggle.
function PasslootBiS:ToggleLootWindow(show)
	local f = self:CreateLootWindow()
	if (show == nil) then
		show = not f:IsShown()
	end
	if (show) then
		self:LootWindow_Render()
		f:Show()
		f:Raise()   -- front-of-strata on open (replaces the dropped SetToplevel)
	else
		f:Hide()
	end
	self.db.profile.LootWindow.shown = show and true or false
end

function PasslootBiS:LootWindow_Clear()
	self.LootLog = (self.LootTracker and self.LootTracker.NewLog()) or { groups = {}, openByKey = {} }
	persist(self)
	self:LootWindow_Render()
end

function PasslootBiS:LootWindow_Render()
	local f = self.LootWindowFrame
	if (not f) then return end
	if (f.fontBtn) then f.fontBtn:SetText(tostring(currentFontSize())) end
	local log = ensureLog(self)
	local groups = log.groups

	-- Per-player need counts (consecutive streak + running total), computed
	-- chronologically (oldest first) over the current log. Pure + self-tested in
	-- LootTracker (the silent-failure net for a miscount); display-only.
	local counts
	if (self.LootTracker and self.LootTracker.NeedCounts) then
		counts = self.LootTracker.NeedCounts(groups)
	end

	-- Layout (owner request): the item is the topline, the party members and their
	-- current action are indented beneath it, then a blank spacer, then a single
	-- outcome line (Winner / Everyone passed / Rolling…) below. The winner line and
	-- any Need line use the larger emphasis font; a repeated needer also gets a
	-- coloured "needed N times consecutively" callout. Groups separated by a blank.
	local descs = {}
	local function add(str, big) descs[#descs + 1] = { str = str, big = big and true or false } end

	for i = #groups, 1, -1 do -- newest first
		local g = groups[i]
		add(g.link or g.name or "?", false)                       -- topline: the item
		for _, r in ipairs(g.rolls) do
			local col = CHOICE_COLORS[r.choice] or "ffffffff"
			local val = r.value and (" (" .. r.value .. ")") or ""
			local isNeed = (r.choice == "need")
			add(string.format("   %s: |c%s%s|r%s", tostring(r.player), col, choiceLabel(r.choice), val), isNeed)
			-- Need callouts at 3+: consecutive streak AND running total, each coloured
			-- by its own count (3 green / 4 yellow / 5+ red). Streak <= total, so the
			-- consecutive line only ever appears alongside the total line.
			if (isNeed and counts and counts[i] and counts[i][r.player]) then
				local c = counts[i][r.player]
				if (c.streak >= 3) then
					add(string.format("      |c%s%s|r", needStreakColor(c.streak),
						string.format(L["LootWindow_NeedStreak"], tostring(r.player), c.streak)), true)
				end
				if (c.total >= 3) then
					add(string.format("      |c%s%s|r", needStreakColor(c.total),
						string.format(L["LootWindow_NeedTotal"], tostring(r.player), c.total)), true)
				end
			end
		end
		add(" ", false)                                           -- spacer
		if (g.winner) then
			add("   |cff40ff40" .. string.gsub(L["LootWindow_Winner"], "%%s", g.winner) .. "|r", true)
		elseif (g.allPassed) then
			add("   |cff999999" .. L["LootWindow_AllPassed"] .. "|r", false)
		else
			add("   |cffffd200" .. L["LootWindow_Rolling"] .. "|r", false)
		end
		add(" ", false)                                           -- group separator
	end

	if (#descs == 0) then
		add("|cff999999" .. L["LootWindow_Empty"] .. "|r", false)
	end

	f.lineDescs = descs
	layoutRows(f)   -- size + reflow the pooled rows to the current width
end
