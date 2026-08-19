local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

--[[
The right-click "Loot Window" (Phase 2 + 3 of the minimap feature; see
reference/minimap-loot-window-plan.md). A movable, closable floating frame that
renders the per-item roll log collected by Modules/LootTracker.lua (who rolled
what, and who won).

§8.6 note (SUPERSEDED, kept for context): the original concern was that on this
client StaticPopups/overlays render BEHIND the Interface Options window, so the
window was put on a high strata to avoid disappearing behind it. The window now
sits on MEDIUM on purpose — see the strata comment in CreateLootWindow. Rendering
under the Blizzard panels is the intended behaviour for a persistent log you leave
open while playing, so what §8.6 treated as a failure mode is now the design. The
old fallback (rendering the log on an options page instead) is therefore moot.
(MEDIUM, not the LOW this first moved to: LOW is *also* where the action bars and
unit frames live, and they drew straight through the window. See the same comment.)

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

-- Item toplines get a mouse region laid over their text, so hovering an item in
-- the log shows the real item tooltip and modified-click links it into chat or
-- the dressing room -- the same behaviour as the stock loot-roll button (see the
-- icon handlers in Core/RollAdvisor.lua). FontStrings cannot take mouse input
-- themselves, so the regions are a SECOND pool (f.hovers), positioned on top of
-- the rows by layoutRows and reused the same way.

-- The tooltip payload for a logged item string. Groups store whatever the chat
-- line carried: usually a full |Hitem:...|h[Name]|h link, but a bare "[Name]"
-- when the client sent no link. Returns the hyperlink to feed SetHyperlink, or
-- nil when there is nothing the client can build a tooltip from.
local function hyperlinkOf(link)
	if (type(link) ~= "string") then return nil end
	local inner = link:match("|H(.-)|h")
	if (inner) then return inner end
	if (link:find("item:", 1, true)) then return link end
	return nil
end

local function acquireHover(f, idx)
	local h = f.hovers[idx]
	if (not h) then
		h = CreateFrame("Button", nil, f.content)
		h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		local tex = h:GetHighlightTexture()
		if (tex) then tex:SetAlpha(0.4) end
		h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		-- Drag must keep working over the log body: a mouse-enabled child swallows
		-- the left-drag the window's own OnDragStart relies on, so forward it.
		h:RegisterForDrag("LeftButton")
		h:SetScript("OnDragStart", function()
			local win = PasslootBiS.LootWindowFrame
			if (win) then win:StartMoving() end
		end)
		h:SetScript("OnDragStop", function()
			local win = PasslootBiS.LootWindowFrame
			if (not win) then return end
			win:StopMovingOrSizing()
			local point, _, relPoint, x, y = win:GetPoint()
			local d = PasslootBiS.db.profile.LootWindow
			d.point, d.relPoint, d.x, d.y = point, relPoint, x, y
		end)
		-- Reads btn.link / btn.itemName, which layoutRows sets per render: the
		-- regions are pooled and reused, so nothing here may close over one item.
		h:SetScript("OnEnter", function(btn)
			GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
			local shown = false
			local hl = hyperlinkOf(btn.link)
			if (hl) then
				shown = pcall(GameTooltip.SetHyperlink, GameTooltip, hl)
				-- An unknown/malformed link leaves the tooltip empty rather than
				-- erroring, so treat "no lines" as a miss and fall through.
				if (shown and GameTooltip.NumLines and GameTooltip:NumLines() == 0) then
					shown = false
				end
			end
			if (not shown) then
				local text = btn.itemName or btn.link
				if (not text) then GameTooltip:Hide() return end
				GameTooltip:SetText(text)
			end
			GameTooltip:Show()
		end)
		h:SetScript("OnLeave", function() GameTooltip:Hide() end)
		h:SetScript("OnClick", function(btn)
			local handle = rawget(_G, "HandleModifiedItemClick")
			if (handle and btn.link) then handle(btn.link) end
		end)
		f.hovers[idx] = h
	end
	return h
end

-- Lay the line descriptors (f.lineDescs = { {str=, big=, link=, itemName=}, ... })
-- out as pooled FontStrings at the CURRENT scroll width, stacking top-down, and
-- size the scroll child to the total height so the scrollbar range tracks it.
-- Lines carrying a link also get a hover region (acquireHover) sized to the text
-- they cover. Called from render and live from the resize grip (OnSizeChanged),
-- so lines re-wrap -- and the regions follow -- as the window is resized.
local function layoutRows(f)
	if (not f or not f.scroll or not f.rows or not f.hovers or not f.lineDescs) then return end
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
	local nHover = 0
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
		if (d.link) then
			-- Cover the TEXT, not the whole row: a full-width region would highlight
			-- (and grab clicks over) empty space to the right of a short item name.
			-- GetStringWidth reports the unwrapped width, so clamp to the wrap width.
			nHover = nHover + 1
			local hov = acquireHover(f, nHover)
			hov.link, hov.itemName = d.link, d.itemName
			local tw = (row:GetStringWidth() or 0) + 4
			if (tw < 8 or tw > width) then tw = width end
			hov:SetWidth(tw)
			hov:SetHeight(h)
			hov:ClearAllPoints()
			hov:SetPoint("TOPLEFT", f.content, "TOPLEFT", 2, y)
			hov:Show()
		end
		y = y - h - 1
	end
	for i = #f.lineDescs + 1, #f.rows do f.rows[i]:Hide() end
	for i = nHover + 1, #f.hovers do f.hovers[i]:Hide() end
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
	-- Deliberately NO SetToplevel: on Ascension 3.3.5 a SetToplevel(true) frame
	-- re-raises on every click/drag, and each raise restacks the strata (~50ms on a
	-- sparse one, a full ~0.6-2.6s freeze on a crowded one like HIGH). This is a
	-- singleton window that never needs click-to-raise, so dropping the flag gives
	-- 0 spikes on drag. (see DRAGFREEZE note — the "0 spikes" cure)
	--
	-- MEDIUM strata + a fixed high frame level: this is a persistent floating log you
	-- leave open while playing, so it should sit UNDER the default Blizzard panels
	-- (bags, character sheet, world map — HIGH and above) the way a damage meter does,
	-- rather than covering them. Note this reverses the original §8.6 choice in the
	-- file header, which put the window high specifically so it would not disappear
	-- behind the Interface Options window — that is now the accepted, intended
	-- behaviour: the log is not something you read while configuring the addon.
	--
	-- It was on LOW for exactly that reason and had to come up one step: LOW is also
	-- where Blizzard's action bars and unit frames live, and they are toplevel, so
	-- clicking one lifted it over the log. The strata + level pair lives in
	-- Core/PassLoot.lua (ApplyWindowChrome) — read the comment there before changing
	-- it; the level is what keeps a bar addon on the same strata from drawing through.
	--
	-- Safe on MEDIUM only because there is no SetToplevel above: a toplevel window
	-- would restack the MEDIUM strata on every drag, the same mechanism as the HIGH
	-- freeze. That is also why ToggleLootWindow no longer calls Raise(): Raise() IS
	-- that restack, cheap on a sparse strata like the old LOW but not on a populated
	-- one. The fixed level gives the same front-on-open for free, and — like Raise()
	-- — cannot cross strata, so the window still stays under the Blizzard panels.
	PasslootBiS:ApplyWindowChrome(f)
	PasslootBiS:ApplyDarkBackdrop(f)   -- shared house chrome (Core/PassLoot.lua)
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
	f.hovers = {}        -- pool of item-tooltip mouse regions (see acquireHover)
	f.lineDescs = {}     -- line descriptors: { {str=, big=, link=, itemName=}, ... }

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
		-- Front-of-strata on open without a restack. Deliberately NOT f:Raise() — on
		-- MEDIUM that is the drag-freeze pass; re-asserting the window's own level
		-- reorders nothing (see ApplyWindowChrome in Core/PassLoot.lua).
		self:ApplyWindowChrome(f)
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
	-- link/itemName are only set on the item topline; they are what turns that row
	-- into a tooltip hover region (layoutRows). Older persisted logs may have no
	-- link on a group, in which case the row simply stays inert.
	local descs = {}
	local function add(str, big, link, itemName)
		descs[#descs + 1] = {
			str = str,
			big = big and true or false,
			link = link,
			itemName = itemName,
		}
	end

	for i = #groups, 1, -1 do -- newest first
		local g = groups[i]
		add(g.link or g.name or "?", false, g.link, g.name)       -- topline: the item
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
