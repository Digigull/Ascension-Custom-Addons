local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

--[[--------------------------------------------------------------------------
  BiSCleanup.lua  —  the end-of-run "these BiS entries look stale" suggestion

  BiS Check (Core/RollAdvisor.lua) catches a stale BiS entry one roll at a time: it
  vetoes the auto-roll and shows the red downgrade window. That fixes the roll in
  front of you, but the LIST is still wrong — the same entry will stop you again on
  the next run, and every run after that, until someone edits it.

  So every veto is also noted here, and when you leave the zone the run's notes are
  offered back as a suggestion: "these N items on your BiS list are worse than what
  you have — untick them?".

  Two rules this obeys, both owner decisions:
    * It SUGGESTS, never acts. The list is the user's, and an entry can be stale for
      a perfectly good reason (a second set for another spec, an item you are still
      chasing a better roll of). Nothing changes until the Apply button is pressed.
    * Unticking is not deleting. It clears the item's "auto-roll" tick exactly as the
      BiS Manager's own checkbox does, so the entry stays on the list as data. That
      is what makes this safe to accept on a whim — the same window's checkbox puts
      it back.

  The ledger is per-session and NOT persisted. It is a record of what happened in
  the run you just did; carrying it across a logout would offer you decisions about
  a dungeon you no longer remember.

  Strata: the house window chrome (MEDIUM + level 100 via ApplyWindowChrome). This
  is a window you leave open while you sort your bags after a run, not a modal —
  see the strata table in management/docs/CLAUDE.md. No SetToplevel, no Raise: both
  are the drag freeze (management/docs/DRAG-FREEZE.md).
----------------------------------------------------------------------------]]

-- Per-session ledger: listName -> matchKey -> record. Keyed by the same
-- "kind\0key" form the BiS Manager uses, so a record maps straight onto the
-- manager's tick state without a second lookup.
PasslootBiS.BiSStale = PasslootBiS.BiSStale or {}

local MAX_ROWS = 12          -- beyond this the window scrolls its text instead
local ROW_HEIGHT = 18
local WINDOW_WIDTH = 380
local BUTTON_HEIGHT = 22

-- The match key for an item, in the BiS Manager's own "kind\0key" form. An
-- ID-matched pick wins over a name-matched one: the id is exact where a name can
-- be shared by several scaled variants of the same base item (research §2.4a).
local function matchKeyFor(id, name)
	if id then return "id\0" .. tostring(id), "id", tostring(id) end
	if name then return "name\0" .. tostring(name), "name", tostring(name) end
	return nil
end

--=============================================================================
-- 1. Recording — called by the BiS Check veto in Core/RollAdvisor.lua
--=============================================================================

-- Note that BiS Check vetoed a roll on this item. Idempotent per item per run: a
-- boss that drops the same stale item twice is one suggestion, not two, and the
-- worst delta seen is the one kept (it is the most convincing number to show).
function PasslootBiS:RecordBiSDowngrade(ctx, verdict)
	if type(ctx) ~= "table" then return end
	local list = ctx.bisList
	if not list or list == "" then return end
	local id = ctx.itemLink and GetItemInfoFromHyperlink(ctx.itemLink) or nil
	local name = ctx.itemName
	if not name and ctx.itemLink and self.RollRetry then
		name = self.RollRetry.NameFromLink(ctx.itemLink)
	end
	local key, kind, rawKey = matchKeyFor(id, name)
	if not key then return end

	self.BiSStale[list] = self.BiSStale[list] or {}
	local prev = self.BiSStale[list][key]
	local delta = (type(verdict) == "table" and tonumber(verdict.downDelta)) or 0
	if prev and (tonumber(prev.delta) or 0) <= delta then
		return   -- already noted, and the stored delta is the worse (more negative) one
	end
	self.BiSStale[list][key] = {
		kind  = kind,
		key   = rawKey,
		name  = name or ("Item #" .. tostring(id)),
		link  = ctx.itemLink,
		delta = delta,
	}
end

-- Flatten the ledger into a display array: { list, kind, key, name, link, delta }.
function PasslootBiS:CollectStaleBiSItems()
	local out = {}
	for list, items in pairs(self.BiSStale) do
		for _, rec in pairs(items) do
			out[#out + 1] = {
				list = list, kind = rec.kind, key = rec.key,
				name = rec.name, link = rec.link, delta = rec.delta,
			}
		end
	end
	table.sort(out, function(a, b)
		if a.list ~= b.list then return a.list < b.list end
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

function PasslootBiS:ClearStaleBiSItems()
	self.BiSStale = {}
end

--=============================================================================
-- 2. Applying — untick the chosen items on their lists
--=============================================================================

-- Clear the "auto-roll" tick for a set of items on ONE list and rebuild its rules.
-- `keySet` is a set of "kind\0key" strings.
--
-- Routed through the BiS Manager's own staging table and ApplyBiSManager rather
-- than editing the rules here: that path already knows how to preserve the list's
-- roll action, its position among the rules, and its Before Advisor tick, and it
-- refreshes the rule list and the manager window afterwards. A second, parallel
-- rule-rebuild would be a second place for those to be got wrong.
function PasslootBiS:DisableBiSItems(list, keySet)
	if not list or type(keySet) ~= "table" then return 0 end
	if not self:BiSListExists(list) then return 0 end

	self.BiSManagerStaging = self.BiSManagerStaging or {}
	self.BiSManagerStaging[list] = self.BiSManagerStaging[list] or {}
	local staging = self.BiSManagerStaging[list]

	local turned = 0
	for _, item in ipairs(self:CollectBiSListItems(list)) do
		local key = tostring(item.kind) .. "\0" .. tostring(item.key)
		if keySet[key] and item.rolls then
			staging[key] = false
			turned = turned + 1
		end
	end
	if turned == 0 then return 0 end

	-- ApplyBiSManager commits the SELECTED list, so point the selection at this one
	-- for the commit and put it back afterwards — the user may have had another list
	-- open in the manager and would not expect this to move it.
	local previous = self.BiSManagerSelected
	self.BiSManagerSelected = list
	self:ApplyBiSManager()
	self.BiSManagerSelected = previous
	return turned
end

--=============================================================================
-- 3. The suggestion window
--=============================================================================

local function makeWindow()
	local f = CreateFrame("Frame", "PasslootBiSCleanupFrame", UIParent)
	f:SetWidth(WINDOW_WIDTH)
	f:SetHeight(200)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	-- House chrome: MEDIUM + frame level 100, dark backdrop. No SetToplevel and no
	-- Raise — see the file header and management/docs/DRAG-FREEZE.md.
	PasslootBiS:ApplyWindowChrome(f)
	PasslootBiS:ApplyDarkBackdrop(f)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
	f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing() end)
	f:Hide()

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
	f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10)
	f.title:SetJustifyH("LEFT")
	f.title:SetText(L["BiSCleanup_Title"])

	f.blurb = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.blurb:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
	f.blurb:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -4)
	f.blurb:SetJustifyH("LEFT")
	f.blurb:SetText(L["BiSCleanup_Blurb"])

	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
	f.close:SetScript("OnClick", function() PasslootBiS:HideBiSCleanup() end)

	f.rows = {}
	return f
end

-- One row: a checkbox, the item link, and how far below your gear it scored.
local function acquireRow(f, index)
	local row = f.rows[index]
	if row then return row end

	row = CreateFrame("Frame", nil, f)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("LEFT", f, "LEFT", 12, 0)
	row:SetPoint("RIGHT", f, "RIGHT", -12, 0)

	row.check = CreateFrame("CheckButton", "PasslootBiSCleanupCheck" .. index, row,
		"UICheckButtonTemplate")
	row.check:SetWidth(20)
	row.check:SetHeight(20)
	row.check:SetPoint("LEFT", row, "LEFT", 0, 0)

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
	row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.text:SetJustifyH("LEFT")

	-- Mouseover the row for the real item tooltip, and modified-click to link it,
	-- exactly as the roll window's icon behaves.
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(r)
		if not r.link then return end
		GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
		if pcall(GameTooltip.SetHyperlink, GameTooltip, r.link) then
			GameTooltip:Show()
		else
			GameTooltip:Hide()
		end
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row:SetScript("OnMouseUp", function(r)
		local handle = rawget(_G, "HandleModifiedItemClick")
		if handle and r.link then handle(r.link) end
	end)
	-- The checkbox sits inside a mouse-enabled row, whose default frame level is the
	-- same; lift it so the row never eats its clicks (the same fix AdvisorStatus.lua
	-- documents for its own row controls).
	row.check:SetFrameLevel(row:GetFrameLevel() + 2)

	f.rows[index] = row
	return row
end

function PasslootBiS:ShowBiSCleanup()
	local items = self:CollectStaleBiSItems()
	if #items == 0 then return false end

	if not self.BiSCleanupFrame then
		self.BiSCleanupFrame = makeWindow()
	end
	local f = self.BiSCleanupFrame
	f.items = items

	local shown = math.min(#items, MAX_ROWS)
	local anchor = f.blurb
	for i = 1, shown do
		local it = items[i]
		local row = acquireRow(f, i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
		row:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
		row.link = it.link
		row.check:SetChecked(true)   -- pre-ticked: the suggestion is "untick these"
		row.text:SetText(string.format("%s |cff9d9d9d(%s, %s)|r",
			it.link or it.name, it.list, self:FormatBiSDelta(it.delta)))
		row:Show()
		anchor = row
	end
	for i = shown + 1, #f.rows do f.rows[i]:Hide() end

	-- An overflowing run says so rather than silently dropping the tail: a
	-- suggestion you cannot see is worse than no suggestion.
	if not f.more then
		f.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		f.more:SetJustifyH("LEFT")
	end
	f.more:ClearAllPoints()
	f.more:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
	f.more:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
	if #items > shown then
		f.more:SetText(string.format(L["BiSCleanup_More"], #items - shown))
		f.more:Show()
		anchor = f.more
	else
		f.more:SetText("")
		f.more:Hide()
	end

	if not f.apply then
		f.apply = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		f.apply:SetHeight(BUTTON_HEIGHT)
		f.apply:SetWidth(150)
		f.apply:SetText(L["BiSCleanup_Apply"])
		f.apply:SetScript("OnClick", function() PasslootBiS:ApplyBiSCleanup() end)

		f.keep = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		f.keep:SetHeight(BUTTON_HEIGHT)
		f.keep:SetWidth(150)
		f.keep:SetText(L["BiSCleanup_Keep"])
		f.keep:SetScript("OnClick", function() PasslootBiS:HideBiSCleanup() end)
	end
	f.apply:ClearAllPoints()
	f.apply:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
	f.keep:ClearAllPoints()
	f.keep:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -10)

	-- Height from what is actually drawn, so a one-item run is a small window.
	-- The title and blurb are MEASURED rather than assumed: both are anchored to
	-- both edges, so the blurb wraps to two or three lines depending on the font
	-- scale, and a hardcoded allowance for it overlaps the first row on any client
	-- where it wraps further than the author's did.
	local function textHeight(fs, fallback)
		local h = fs and fs.GetStringHeight and fs:GetStringHeight()
		if type(h) == "number" and h > 0 then return h end
		return fallback
	end
	local rowsHeight = shown * (ROW_HEIGHT + 4)
	local moreHeight = (#items > shown) and (textHeight(f.more, 16) + 4) or 0
	f:SetHeight(10 + textHeight(f.title, 14) + 4 + textHeight(f.blurb, 40) + 4
		+ rowsHeight + moreHeight + 10 + BUTTON_HEIGHT + 12)
	f:Show()
	return true
end

function PasslootBiS:HideBiSCleanup()
	if self.BiSCleanupFrame then self.BiSCleanupFrame:Hide() end
	-- Dismissing IS the answer "keep these" — the run's notes are spent either way,
	-- so the same suggestion cannot resurface at the next zone change.
	self:ClearStaleBiSItems()
end

-- Commit the ticked rows: untick those items on their lists, one Apply per list.
function PasslootBiS:ApplyBiSCleanup()
	local f = self.BiSCleanupFrame
	if not f or not f.items then return end

	local byList, any = {}, false
	local shown = math.min(#f.items, MAX_ROWS)
	for i = 1, shown do
		local row = f.rows[i]
		local it = f.items[i]
		if row and it and row.check:GetChecked() then
			byList[it.list] = byList[it.list] or {}
			byList[it.list][tostring(it.kind) .. "\0" .. tostring(it.key)] = true
			any = true
		end
	end

	local turned = 0
	if any then
		for list, keySet in pairs(byList) do
			turned = turned + self:DisableBiSItems(list, keySet)
		end
	end
	if turned > 0 then
		self:Pour(string.format(L["BiSCleanup_Done"], turned))
	end
	self:HideBiSCleanup()
end

-- The delta as a signed percent. Mirrors the scanner's Verdict.fmtDownDelta so the
-- suggestion window and the roll popup quote the same number the same way.
function PasslootBiS:FormatBiSDelta(delta)
	-- Magnitude rounded then re-signed -- math.floor on the negative rounds toward
	-- -infinity and turns a clean -12% into "-13%". Kept identical to the scanner's
	-- Verdict.fmtDownDelta so the two never quote the same item differently.
	return string.format("-%d%%", math.floor(math.abs(tonumber(delta) or 0) * 100 + 0.5))
end

--=============================================================================
-- 4. The zone watch — "on zone change" (owner decision 2026-08)
--=============================================================================
-- The run ends when the zone does. ZONE_CHANGED_NEW_AREA is the signal that
-- actually fires on walking out of an instance; PLAYER_ENTERING_WORLD covers the
-- loading-screen route (a hearth, a summon, a logout-and-back) which does not
-- always produce the former.
--
-- Both are noisy, so the zone STRING is what decides, not the event: entering the
-- same zone twice is not the end of a run. The first zone seen in a session is
-- recorded without firing, or logging in would offer a suggestion about a run that
-- happened before the addon was watching.

local watchedZone

local function currentZone()
	local get = rawget(_G, "GetRealZoneText")
	local zone = get and get() or nil
	if zone == nil or zone == "" then return nil end
	return zone
end

function PasslootBiS:BiSCleanup_ZoneCheck()
	local zone = currentZone()
	if not zone then return end            -- mid-load: the client answers "" for a moment
	if watchedZone == nil then
		watchedZone = zone
		return
	end
	if zone == watchedZone then return end
	watchedZone = zone

	-- Tell the scanner its run is over, so its win ledger starts the next zone clean
	-- (PassLootBiS_Scanner/Core/WonLedger.lua). Guarded: the scanner is optional, and
	-- an older one has no EndRun.
	local scanner = self.API and self.API.GetAdvisor and self.API:GetAdvisor("PLScanner")
	if scanner and type(scanner.EndRun) == "function" then
		pcall(scanner.EndRun, scanner)
	end

	if next(self.BiSStale) == nil then return end
	self:ShowBiSCleanup()
end
