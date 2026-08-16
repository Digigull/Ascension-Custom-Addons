--[[--------------------------------------------------------------------------
  AdvisorStatus.lua  —  "is the advisor actually wired up?" panel on the rules page

  Three questions, answered at a glance in the dead column to the LEFT of the rule
  list (Interface > AddOns > PassLoot (BiS)):

    1. Is the loot advisor linked to the BiS Scanner?   (Core/RollAdvisor.lua's
       advisor registry — the scanner registers as "PLScanner")
    2. Can the scanner advise on GEAR?                  (spec weights selected)
    3. Can it advise on HIGH VALUE?                     (Auctionator fork present
       AND at least one AH scan has written price data)

  All three read-only, all three guarded: PassLootBiS_Scanner is an optional
  companion, so every hop (registry -> API -> GetStatus) degrades to a status line
  rather than an error. Colour is traffic-light and carries the same information
  as the words: green ready, yellow present-but-idle, red missing.

  Do NOT reach for the scanner through _G.PLBiSScanner alone. An addon's `...`
  namespace table is PRIVATE to that addon; a companion only has a global if it
  explicitly assigns one, and this panel shipped believing it always did. The
  supported handle is the advisor object the scanner passed to
  RegisterRollAdvisor — see scannerAPI() — with the global as a fallback and
  IsAddOnLoaded/GetAddOnInfo underneath both, so "not installed", "installed but
  not loaded" and "loaded but silent" stay distinguishable.

  State is read on OnShow and on the Refresh button, never on a timer: nothing
  the rows report changes on its own.

  Why the left column and not the empty space below the filter lists: that lower
  area is where a selected filter's rule widget is drawn (see the frame-layout
  comment at the top of Core/MainGUI.lua), so it is only blank until you click a
  filter. The column beside the rule list is blank for good — the rules frame is
  SetAllPoints'd onto InterfaceOptionsFramePanelContainer when Blizzard displays
  it, while its List/Settings children are anchored TOP (centred), leaving a strip
  either side that nothing else ever uses.

  No strata calls and no SetToplevel here: this is a child of a Blizzard options
  panel and takes that panel's layering (management/docs/DRAG-FREEZE.md).
----------------------------------------------------------------------------]]

local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

-- The name PassLootBiS_Scanner registers itself under (Core/Scanner.lua). Asking
-- for it BY NAME matters: some other addon registering an advisor does not make
-- the row's claim ("the BiS Scanner is linked") true.
local SCANNER_ADVISOR = "PLScanner"
-- The companion's folder name, for IsAddOnLoaded/GetAddOnInfo. Those two are the
-- only "is it there?" answers that do not depend on the scanner publishing
-- anything, which is what lets the panel tell "not installed" apart from
-- "installed but switched off in the AddOns list" and from "loaded but silent".
local SCANNER_ADDON = "PassLootBiS_Scanner"

--=============================================================================
-- 1. Reading the scanner's state
--=============================================================================

-- Is the companion addon on disk, and did the client load it? Independent of the
-- scanner's own code having run, so it still answers when nothing was published.
-- Returns "loaded" | "installed" (present but not loaded/enabled) | "absent".
local function scannerLoadState()
	local IsLoaded = rawget(_G, "IsAddOnLoaded")
	if (IsLoaded) then
		local Ok, Loaded = pcall(IsLoaded, SCANNER_ADDON)
		if (Ok and Loaded) then
			return "loaded"
		end
	end
	local GetInfo = rawget(_G, "GetAddOnInfo")
	if (GetInfo) then
		local Ok, Name = pcall(GetInfo, SCANNER_ADDON)
		if (Ok and Name) then
			return "installed"
		end
	end
	-- Last resort for a client where neither API answered: the namespace itself.
	if (type(rawget(_G, "PLBiSScanner")) == "table") then
		return "loaded"
	end
	return "absent"
end

-- The scanner's API table, preferring the object it REGISTERED with us over any
-- global. An addon's `...` namespace table is private, so a companion that never
-- publishes a global is invisible to rawget — but the advisor it handed to
-- RegisterRollAdvisor is a direct handle on exactly the same table. Reading the
-- registry first is what makes this panel work regardless.
local function scannerAPI(HostAPI)
	if (HostAPI and HostAPI.GetAdvisor) then
		local Advisor = HostAPI:GetAdvisor(SCANNER_ADVISOR)
		if (type(Advisor) == "table") then
			return Advisor
		end
	end
	local Scanner = rawget(_G, "PLBiSScanner")
	if (type(Scanner) == "table" and type(Scanner.API) == "table") then
		return Scanner.API
	end
	return nil
end

-- Pull the scanner's readiness snapshot. Three tiers so an older or half-loaded
-- companion still produces a sensible row instead of an error:
--   1. its API:GetStatus() — the supported contract (Scanner.lua), reached
--      through the advisor registry or the published namespace.
--   2. hand-built from the namespace's public tables, for a build predating it
--      (only possible when the namespace IS published).
--   3. nil — nothing to read; the row falls back to the load state above.
-- The fallback fills the same field names, minus `scanCount` (an older
-- Integrations/Auctionator.lua has no counter), so callers only ever branch on
-- the presence of a field, never on which tier produced it.
local function scannerStatus(HostAPI)
	local API = scannerAPI(HostAPI)
	if (type(API) == "table" and type(API.GetStatus) == "function") then
		local Ok, Status = pcall(API.GetStatus, API)
		if (Ok and type(Status) == "table") then
			return Status
		end
	end

	local Scanner = rawget(_G, "PLBiSScanner")
	if (type(Scanner) ~= "table") then
		return nil
	end

	local Status = { ["version"] = 0, ["loaded"] = true }
	local ScannerDB = Scanner.db
	if (type(ScannerDB) == "table") then
		Status.enabled = ScannerDB.enabled and true or false
		Status.threshold = ScannerDB.threshold
		Status.goldThreshold = ScannerDB.goldThreshold
	else
		Status.enabled = false
	end
	if (type(Scanner.chardb) == "table") then
		Status.class, Status.spec = Scanner.chardb.class, Scanner.chardb.spec
	end
	if (type(Scanner.getActiveWeights) == "function") then
		local Ok, Weights = pcall(Scanner.getActiveWeights)
		Status.hasWeights = (Ok and type(Weights) == "table") or false
	else
		Status.hasWeights = (Status.class ~= nil and Status.spec ~= nil)
	end
	Status.gearReady = Status.hasWeights and Status.enabled

	local Auctionator = Scanner.Auctionator
	if (type(Auctionator) == "table" and type(Auctionator.liveProvider) == "function") then
		local Ok, Provider = pcall(Auctionator.liveProvider)
		Status.auctionator = (Ok and Provider ~= nil) or false
	else
		Status.auctionator = false
	end
	-- Without a counter, "is there anything in there at all" is enough to colour
	-- the row; the count simply goes unmentioned.
	local PriceDB = rawget(_G, "gAtr_ScanDB")
	Status.valueReady = Status.auctionator and Status.enabled
		and type(PriceDB) == "table" and next(PriceDB) ~= nil

	return Status
end

-- "1,234" / "2000+" for the scanned-price count, or nil when we have no count.
local function scanCountText(Status)
	local Count = Status.scanCount
	if (type(Count) ~= "number" or Count <= 0) then
		return nil
	end
	if (Status.scanCapped) then
		return tostring(Count) .. "+"
	end
	return tostring(Count)
end

--=============================================================================
-- 2. The three rows
--=============================================================================

-- Returns an array of { Label, Text, Color, Tip = { TooltipTitle, line, ... } },
-- one entry per row, in display order. Pure-ish: it only reads state.
function PasslootBiS:GetAdvisorStatus()
	local API = self.API
	local Status = scannerStatus(API)
	local LoadState = scannerLoadState()
	local Names = (API and API.GetAdvisorNames) and API:GetAdvisorNames() or {}
	local Linked = (API and API.HasAdvisor and API:HasAdvisor(SCANNER_ADVISOR)) and true or false
	local GateOn = (API and API.enabled) and true or false
	-- The scanner is loaded but told us nothing: an older build with no GetStatus
	-- and no published namespace. Say so rather than claiming it is missing.
	local SilentTip = (LoadState == "loaded") and L["AdvisorStatus_NoStatus_Tip"] or L["AdvisorStatus_NoScanner_Tip"]

	--- Row 1: the PassLoot <-> Scanner link itself. ---------------------------
	local Link = { ["Label"] = L["AdvisorStatus_LinkLabel"] }
	if (not Linked and LoadState == "absent") then
		Link.Color, Link.Text = self.FontRed, L["AdvisorStatus_LinkMissing"]
		Link.Tip = { Link.Label, L["AdvisorStatus_LinkMissing_Tip"] }
	elseif (not Linked and LoadState == "installed") then
		Link.Color, Link.Text = self.FontRed, L["AdvisorStatus_LinkNotLoaded"]
		Link.Tip = { Link.Label, L["AdvisorStatus_LinkNotLoaded_Tip"] }
	elseif (not Linked) then
		Link.Color, Link.Text = self.FontYellow, L["AdvisorStatus_LinkLoaded"]
		Link.Tip = { Link.Label, L["AdvisorStatus_LinkLoaded_Tip"] }
	elseif (not GateOn) then
		Link.Color, Link.Text = self.FontYellow, L["AdvisorStatus_LinkGateOff"]
		Link.Tip = { Link.Label, L["AdvisorStatus_LinkGateOff_Tip"] }
	else
		Link.Color, Link.Text = self.FontGreen, L["AdvisorStatus_LinkOk"]
		Link.Tip = {
			Link.Label,
			L["AdvisorStatus_LinkOk_Tip"],
			string.format(L["AdvisorStatus_AdvisorsLine"], table.concat(Names, ", ")),
		}
	end

	--- Row 2: gear recommendations (needs spec weights). ----------------------
	local Gear = { ["Label"] = L["AdvisorStatus_GearLabel"] }
	if (not Status) then
		Gear.Color, Gear.Text = self.FontRed, L["AdvisorStatus_Unavailable"]
		Gear.Tip = { Gear.Label, SilentTip }
	elseif (not Status.hasWeights) then
		Gear.Color, Gear.Text = self.FontRed, L["AdvisorStatus_GearNoSpec"]
		Gear.Tip = { Gear.Label, L["AdvisorStatus_GearNoSpec_Tip"] }
	elseif (not Status.enabled) then
		Gear.Color, Gear.Text = self.FontYellow, L["AdvisorStatus_ScanningOff"]
		Gear.Tip = { Gear.Label, L["AdvisorStatus_ScanningOff_Tip"] }
	else
		Gear.Color = Status.placeholder and self.FontYellow or self.FontGreen
		Gear.Text = Status.placeholder and L["AdvisorStatus_GearPlaceholder"] or L["AdvisorStatus_Ready"]
		Gear.Tip = { Gear.Label, L["AdvisorStatus_GearReady_Tip"] }
		if (Status.class and Status.spec) then
			table.insert(Gear.Tip, string.format(L["AdvisorStatus_SpecLine"], Status.class, Status.spec))
		end
		if (type(Status.threshold) == "number") then
			table.insert(Gear.Tip,
				string.format(L["AdvisorStatus_ThresholdLine"], math.floor(Status.threshold * 100 + 0.5)))
		end
		if (Status.placeholder) then
			table.insert(Gear.Tip, L["AdvisorStatus_GearPlaceholder_Tip"])
		end
	end

	--- Row 3: high-value recommendations (needs Auctionator + scanned data). --
	local Value = { ["Label"] = L["AdvisorStatus_ValueLabel"] }
	if (not Status) then
		Value.Color, Value.Text = self.FontRed, L["AdvisorStatus_Unavailable"]
		Value.Tip = { Value.Label, SilentTip }
	elseif (not Status.auctionator) then
		Value.Color, Value.Text = self.FontRed, L["AdvisorStatus_ValueNoAuctionator"]
		Value.Tip = { Value.Label, L["AdvisorStatus_ValueNoAuctionator_Tip"] }
	elseif (not Status.enabled) then
		Value.Color, Value.Text = self.FontYellow, L["AdvisorStatus_ScanningOff"]
		Value.Tip = { Value.Label, L["AdvisorStatus_ScanningOff_Tip"] }
	elseif (not Status.valueReady) then
		Value.Color, Value.Text = self.FontYellow, L["AdvisorStatus_ValueNoData"]
		Value.Tip = { Value.Label, L["AdvisorStatus_ValueNoData_Tip"] }
	else
		Value.Color, Value.Text = self.FontGreen, L["AdvisorStatus_Ready"]
		Value.Tip = { Value.Label, L["AdvisorStatus_ValueReady_Tip"] }
		local Counted = scanCountText(Status)
		if (Counted) then
			table.insert(Value.Tip, string.format(L["AdvisorStatus_PricesLine"], Counted))
		end
		if (type(Status.goldThreshold) == "number") then
			table.insert(Value.Tip,
				string.format(L["AdvisorStatus_GoldLine"], math.floor(Status.goldThreshold / 10000)))
		end
	end

	return { Link, Gear, Value }
end

--=============================================================================
-- 3. The frame
--=============================================================================

-- A wrapping FontString has no fixed height, so measure it rather than assume a
-- line: the panel is narrow enough that most values wrap to two lines and one of
-- them ("Ready (placeholder weights)") to three.
local function stringHeight(FontString)
	local Height = FontString.GetStringHeight and FontString:GetStringHeight() or nil
	if (not Height or Height <= 0) then
		Height = FontString:GetHeight() or 0
	end
	if (Height <= 0) then
		Height = 12
	end
	return Height
end

function PasslootBiS:Create_AdvisorStatusFrame()
	local Frame = CreateFrame("Frame")
	-- Width comes from the caller's left/right anchors; height is recomputed on
	-- every refresh once the wrapped text has been measured.
	Frame:SetWidth(120)
	Frame:SetHeight(150)
	-- Same backdrop recipe as the rule list and rule settings frames beside it
	-- (Core/MainGUI.lua). Deliberately NOT the dark house chrome: a dark box
	-- inside the stock Interface Options parchment reads as a seam, not a theme.
	Frame:SetBackdrop({
		["bgFile"] = "Interface\\Tooltips\\UI-Tooltip-Background",
		["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["tile"] = true,
		["insets"] = {
			["top"] = 5,
			["bottom"] = 5,
			["left"] = 5,
			["right"] = 5,
		},
		["tileSize"] = 16,
		["edgeSize"] = 16,
	})
	Frame:SetBackdropBorderColor(0.4, 0.4, 0.4)
	Frame:SetBackdropColor(0.5, 0.5, 0.5)

	-- Every FontString below takes BOTH its left and right edge from the one above
	-- it, so the whole column inherits the title's span and each value wraps inside
	-- the panel. Note the deliberate TOP*RIGHT* rather than RIGHT: a bare "RIGHT"
	-- point also pins the vertical centre, which fights the TOPLEFT point and lets
	-- the region stretch instead of sizing itself to its wrapped text.
	Frame.Title = Frame:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
	Frame.Title:SetPoint("TOPLEFT", Frame, "TOPLEFT", 10, -10)
	Frame.Title:SetPoint("TOPRIGHT", Frame, "TOPRIGHT", -8, -10)
	Frame.Title:SetJustifyH("LEFT")
	Frame.Title:SetText(L["AdvisorStatus_Title"])

	Frame.Rows = {}
	local Anchor = Frame.Title
	for Index = 1, 3 do
		local Row = {}

		Row.Label = Frame:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
		Row.Label:SetPoint("TOPLEFT", Anchor, "BOTTOMLEFT", 0, -8)
		Row.Label:SetPoint("TOPRIGHT", Anchor, "BOTTOMRIGHT", 0, -8)
		Row.Label:SetJustifyH("LEFT")

		Row.Value = Frame:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
		Row.Value:SetPoint("TOPLEFT", Row.Label, "BOTTOMLEFT", 0, -1)
		Row.Value:SetPoint("TOPRIGHT", Row.Label, "BOTTOMRIGHT", 0, -1)
		Row.Value:SetJustifyH("LEFT")

		-- Mouse target for the tooltip. Anchored to the two FontStrings so it grows
		-- with them when the value wraps to a second or third line.
		Row.Hit = CreateFrame("Frame", nil, Frame)
		Row.Hit:SetPoint("TOPLEFT", Row.Label, "TOPLEFT", 0, 0)
		Row.Hit:SetPoint("BOTTOMRIGHT", Row.Value, "BOTTOMRIGHT", 0, 0)
		Row.Hit:EnableMouse(true)
		Row.Hit:SetScript("OnEnter", function()
			if (Row.Tip) then
				self:ShowTooltip(unpack(Row.Tip))
			end
		end)
		Row.Hit:SetScript("OnLeave", function() GameTooltip:Hide() end)

		Frame.Rows[Index] = Row
		Anchor = Row.Value
	end

	-- Manual re-check instead of an OnUpdate poll. Everything the rows report
	-- changes only when the user does something (loading an addon, picking a spec,
	-- finishing an AH scan), so a timer would spend all day re-reading a state
	-- nobody changed. Opening the page still refreshes for free via OnShow; this
	-- button covers the rest.
	Frame.Refresh = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Refresh:SetPoint("TOPLEFT", Anchor, "BOTTOMLEFT", 0, -8)
	Frame.Refresh:SetPoint("TOPRIGHT", Anchor, "BOTTOMRIGHT", 0, -8)
	Frame.Refresh:SetHeight(21)
	Frame.Refresh:SetText(L["AdvisorStatus_Refresh"])
	Frame.Refresh:SetScript("OnClick", function() self:RefreshAdvisorStatus() end)
	Frame.Refresh:SetScript("OnEnter",
		function() self:ShowTooltip(L["AdvisorStatus_Refresh"], L["AdvisorStatus_Refresh_Tip"]) end)
	Frame.Refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)

	Frame:SetScript("OnShow", function() self:RefreshAdvisorStatus() end)

	return Frame
end

function PasslootBiS:RefreshAdvisorStatus()
	local Frame = self.RulesFrame and self.RulesFrame.Status
	if (not Frame or not Frame.Rows) then
		return
	end

	local Status = self:GetAdvisorStatus()
	local Bottom = 10 + stringHeight(Frame.Title)
	for Index, Row in ipairs(Frame.Rows) do
		local Info = Status[Index]
		if (Info) then
			Row.Label:SetText(Info.Label)
			Row.Value:SetText((Info.Color or "") .. Info.Text .. "|r")
			Row.Tip = Info.Tip
			Row.Label:Show()
			Row.Value:Show()
			Bottom = Bottom + 8 + stringHeight(Row.Label) + 1 + stringHeight(Row.Value)
		else
			Row.Label:Hide()
			Row.Value:Hide()
			Row.Tip = nil
		end
	end
	-- + the Refresh button's own gap and height.
	Frame:SetHeight(Bottom + 8 + 21 + 12)
end
