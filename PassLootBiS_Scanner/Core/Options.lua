--[[ Options.lua -- the hand-rolled settings window (ns.Options).

A single floating CreateFrame with class/spec dropdowns and a checkbox/slider for
every setting that also has a slash toggle. The whole point is that picking a spec
becomes a two-click dropdown instead of the error-prone
`/plbisscan spec <Class> | <Spec>` pipe syntax; the dropdowns route through the
same ns.setSpec path the slash command now uses, so there is one source of truth.

HARD CONSTRAINT (DESIGN §6.4): NOT a StaticPopup and NOT AceConfig -- those don't
render reliably on this 3.3.5 client. This is a plain gameplay-time frame, pattern
mirrored from PasslootBiS/Core/LootWindow.lua. Most controls read and write the
matching account-wide PassLootBiS_ScannerDB field; the class/spec dropdowns are
PER-CHARACTER (PassLootBiS_ScannerCharDB, via ns.setSpec), since a character is
exactly one class. Refresh() re-reads both and repaints, so the window always
reflects settings changed elsewhere (e.g. via slash).

Guarded: under bare lua5.1 there is no client, so the file returns a stub and the
pure cores still self-test.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Options = {}
ns.Options = Options

-- WoW-API from here down; skip under bare lua5.1.
if not rawget(_G, "CreateFrame") then
	return Options
end

local SpecWeights = ns.SpecWeights
local Filter      = ns.Filter

local frame          -- the window
local classDrop, specDrop, powerDrop
local checks = {}    -- CheckButtons, so Refresh() can repaint them
local slider, goldBox, powerBox
local refreshing = false   -- suppress control->db writes while Refresh() repaints

local filterFrame            -- the per-character armor/weapon filter window
local filterChecks = {}      -- { {cb, cat, key}, ... } so RefreshFilter() can repaint
local dwSlider               -- dual-wield off-hand DPS % slider (per character)
local filterRefreshing = false

local function weightsDB() return rawget(_G, "PLBiSScannerWeights") end

-- CoA Power scoring options (db.powerMode), in dropdown order.
local POWER_MODES = {
	{ value = "off", text = "Off" },
	{ value = "pve", text = "PvE Power" },
	{ value = "pvp", text = "PvP Power" },
}
local function powerModeText(mode)
	for _, o in ipairs(POWER_MODES) do
		if o.value == mode then return o.text end
	end
	return "Off"
end

----------------------------------------------------------------------
-- Class / spec dropdowns (stock UIDropDownMenuTemplate, ships with 3.3.5)
----------------------------------------------------------------------

local specInit   -- forward declaration (classInit repopulates the spec list)

-- Class/spec are per-character (chardb), so an alt keeps its own pick. Everything
-- else in this window stays account-wide (ns.db).
local function classInit(_, level)
	local data = weightsDB()
	if type(data) ~= "table" then return end
	local cdb = ns.chardb
	for _, cls in ipairs(SpecWeights.classes(data)) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = cls
		info.value = cls
		info.checked = (cdb and cdb.class == cls) or false
		info.func = function()
			if ns.chardb then
				ns.chardb.class = cls
				ns.chardb.spec = nil   -- old spec no longer valid for the new class
			end
			Options.Refresh()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end

specInit = function(_, level)
	local cdb = ns.chardb
	local data = weightsDB()
	if not (cdb and cdb.class) or type(data) ~= "table" then return end
	for _, spc in ipairs(SpecWeights.specs(data, cdb.class)) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = spc
		info.value = spc
		info.checked = (cdb.spec == spc)
		info.func = function()
			-- Route through the shared validate-and-set path (same as slash).
			ns.setSpec(ns.chardb and ns.chardb.class, spc)
			Options.Refresh()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end

-- CoA Power-stat dropdown: Off / PvE Power / PvP Power.
local function powerInit(_, level)
	local mode = (ns.db and ns.db.powerMode) or "off"
	for _, o in ipairs(POWER_MODES) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = o.text
		info.value = o.value
		info.checked = (mode == o.value)
		info.func = function()
			if ns.db then ns.db.powerMode = o.value end
			Options.Refresh()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end

----------------------------------------------------------------------
-- Small control builders
----------------------------------------------------------------------

-- get()/set(v) read and write the db field this checkbox is bound to.
local function makeCheck(label, x, y, get, set)
	local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	cb:SetWidth(24)
	cb:SetHeight(24)
	cb:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb.get, cb.set = get, set
	cb:SetScript("OnClick", function(self)
		if refreshing then return end
		self.set(self:GetChecked() and true or false)
		Options.Refresh()
	end)
	checks[#checks + 1] = cb
	return cb
end

local function makeLabel(text, x, y)
	local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

----------------------------------------------------------------------
-- Window construction
----------------------------------------------------------------------

local function build()
	if frame then return frame end

	frame = CreateFrame("Frame", "PLBiSScannerOptions", UIParent)
	frame:SetWidth(320)
	frame:SetHeight(632)
	-- DRAG-FREEZE FIX: drag-safe strata + level via the shared helper (see Core/UI.lua).
	-- HIGH + SetToplevel(true) froze the client ~1s on first drag; FULLSCREEN_DIALOG
	-- alone still cost ~50ms on EVERY drag while the toplevel flag remained, so the
	-- flag is gone too and Options.Show() calls UI.frontOnOpen() instead. Measured
	-- single-variable (management/docs/DRAG-FREEZE.md); centralized here so no
	-- window can drift back.
	ns.UI.applyWindowChrome(frame)
	ns.UI.applyDarkBackdrop(frame)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
	frame:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		local point, _, relPoint, x, y = f:GetPoint()
		local o = ns.db and ns.db.options
		if o then o.point, o.relPoint, o.x, o.y = point, relPoint, x, y end
	end)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", frame, "TOP", 0, -16)
	title:SetText("PassLootBiS Scanner")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
	close:SetScript("OnClick", function() Options.Hide() end)

	-- Class / spec dropdowns.
	makeLabel("Class", 20, -44)
	classDrop = CreateFrame("Frame", "PLBiSScannerOptionsClassDrop", frame, "UIDropDownMenuTemplate")
	classDrop:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -60)
	UIDropDownMenu_SetWidth(classDrop, 160)
	UIDropDownMenu_Initialize(classDrop, classInit)

	makeLabel("Spec", 20, -96)
	specDrop = CreateFrame("Frame", "PLBiSScannerOptionsSpecDrop", frame, "UIDropDownMenuTemplate")
	specDrop:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -112)
	UIDropDownMenu_SetWidth(specDrop, 160)
	UIDropDownMenu_Initialize(specDrop, specInit)

	-- Toggles (each bound to a db field).
	makeCheck("Enable scanning", 16, -150,
		function() return ns.db and ns.db.enabled end,
		function(v) if ns.db then ns.db.enabled = v end end)
	makeCheck("Tooltip score / arrow", 16, -176,
		function() return ns.db and ns.db.tooltip end,
		function(v) if ns.db then ns.db.tooltip = v end end)
	makeCheck("Chat alerts", 16, -202,
		function() return ns.db and ns.db.useChat end,
		function(v) if ns.db then ns.db.useChat = v end end)
	makeCheck("Floating alert frame", 16, -228,
		function() return ns.db and ns.db.useFrame end,
		function(v) if ns.db then ns.db.useFrame = v end end)
	-- The two sound cues have no thresholds of their own: the upgrade slider and the
	-- gold threshold below already say what counts, so a cue just follows its flag.
	makeCheck("Sound on upgrade", 16, -254,
		function() return ns.db and ns.db.useSound end,
		function(v) if ns.db then ns.db.useSound = v end end)
	makeCheck("Sound on high value (gold)", 16, -280,
		function() return ns.db and ns.db.useSoundGold end,
		function(v) if ns.db then ns.db.useSoundGold = v end end)

	-- Test: fires whatever the two boxes above would fire for an item that is both
	-- an upgrade and high value, so you hear the real cues rather than a stand-in.
	-- Both toggles play the same coin jingle and Alert.cues() de-duplicates it, so
	-- that item is ONE coin however many of the two boxes are ticked -- if you hear
	-- two sounds here, something has pointed the cues at different files again.
	local soundTest = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	soundTest:SetWidth(56)
	soundTest:SetHeight(22)
	soundTest:SetPoint("TOPLEFT", frame, "TOPLEFT", 244, -268)
	soundTest:SetText("Test")
	soundTest:SetScript("OnClick", function()
		local played = ns.Alert and ns.Alert.PlayCues
			and ns.Alert.PlayCues({ delta = 0.1, goldText = "test" }, ns.db or {}) or 0
		if played == 0 then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cff33ff99PLBiS|r both sound cues are off -- tick one to hear it.")
		end
	end)

	-- Scoring fairness, not a display option, so it sits with the scoring controls
	-- below rather than the alert toggles above. ON by default: see ns.equippedStats
	-- in Scanner.lua for why, and for the /plbisdebug check that decided it.
	--
	-- Untick this if [Enchant strip check] in /plbisdebug ever reports a MISMATCH
	-- row -- that means SetHyperlink is reporting cached or nominal stats for a
	-- scaled item on your client, which is a worse error than the enchant skew this
	-- fixes. It is the one condition under which the box is wrong to leave on.
	makeCheck("Ignore enchants when scoring", 16, -332,
		function() return ns.db and ns.db.ignoreEnchants end,
		function(v) if ns.db then ns.db.ignoreEnchants = v end end)
	makeCheck("Hide minimap button", 16, -306,
		function() return ns.db and ns.db.minimap and ns.db.minimap.hide end,
		function(v)
			if ns.MinimapButton and ns.MinimapButton.SetHidden then
				ns.MinimapButton.SetHidden(v)
			elseif ns.db and ns.db.minimap then
				ns.db.minimap.hide = v
			end
		end)

	-- Upgrade threshold slider (0-15%, stored as a fraction in db.threshold).
	makeLabel("Upgrade threshold", 20, -370)
	slider = CreateFrame("Slider", "PLBiSScannerOptionsThreshold", frame, "OptionsSliderTemplate")
	slider:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -396)
	slider:SetWidth(250)
	slider:SetMinMaxValues(0, 15)
	slider:SetValueStep(1)
	_G[slider:GetName() .. "Low"]:SetText("0%")
	_G[slider:GetName() .. "High"]:SetText("+15%")
	slider:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value + 0.5)
		_G[self:GetName() .. "Text"]:SetText(string.format("+%d%%", value))
		if refreshing then return end
		if ns.db then ns.db.threshold = value / 100 end
	end)

	-- Gold threshold (Phase 4): the Auctionator high-value flag cutoff, in gold.
	makeLabel("Gold flag threshold (g)", 20, -436)
	goldBox = CreateFrame("EditBox", "PLBiSScannerOptionsGold", frame, "InputBoxTemplate")
	goldBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 26, -456)
	goldBox:SetWidth(80)
	goldBox:SetHeight(20)
	goldBox:SetAutoFocus(false)
	goldBox:SetNumeric(true)
	goldBox:SetMaxLetters(9)
	local function commitGold(self)
		local g = tonumber(self:GetText())
		if g and ns.db then ns.db.goldThreshold = math.floor(g) * 10000 end  -- gold -> copper
		self:ClearFocus()
		Options.Refresh()
	end
	goldBox:SetScript("OnEnterPressed", commitGold)
	goldBox:SetScript("OnEditFocusLost", commitGold)
	goldBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); Options.Refresh() end)

	-- CoA Power scoring: pick which flat Power stat (if any) to fold into scores,
	-- and how much a point of it is worth (db.powerMode + db.powerWeight).
	makeLabel("Score CoA Power", 20, -484)
	powerDrop = CreateFrame("Frame", "PLBiSScannerOptionsPowerDrop", frame, "UIDropDownMenuTemplate")
	powerDrop:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -500)
	UIDropDownMenu_SetWidth(powerDrop, 100)
	UIDropDownMenu_Initialize(powerDrop, powerInit)

	local wLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	wLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 196, -498)
	wLabel:SetText("Weight")
	powerBox = CreateFrame("EditBox", "PLBiSScannerOptionsPowerWeight", frame, "InputBoxTemplate")
	powerBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 200, -514)
	powerBox:SetWidth(60)
	powerBox:SetHeight(20)
	powerBox:SetAutoFocus(false)
	powerBox:SetMaxLetters(7)   -- allow decimals (e.g. "0.75"), so not SetNumeric
	local function commitPower(self)
		local n = tonumber(self:GetText())
		if n and ns.db then ns.db.powerWeight = n end
		self:ClearFocus()
		Options.Refresh()
	end
	powerBox:SetScript("OnEnterPressed", commitPower)
	powerBox:SetScript("OnEditFocusLost", commitPower)
	powerBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); Options.Refresh() end)

	-- Per-character armor/weapon filter: opens a separate checkbox window. Lives per
	-- character (PassLootBiS_ScannerCharDB), unlike everything else in this window.
	local filterBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	filterBtn:SetWidth(220)
	filterBtn:SetHeight(22)
	filterBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -552)
	filterBtn:SetText("Armor / weapon filter (char)")
	filterBtn:SetScript("OnClick", function() Options.ToggleFilter() end)

	-- Reset-to-defaults (nice-to-have; leaves saved class/spec picks alone).
	local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	reset:SetWidth(140)
	reset:SetHeight(22)
	reset:SetPoint("BOTTOM", frame, "BOTTOM", 0, 16)
	reset:SetText("Reset toggles")
	reset:SetScript("OnClick", function()
		local db = ns.db
		if db then
			db.enabled  = true
			db.tooltip  = true
			db.useChat  = true
			db.useFrame = false
			db.useSound = false
			db.useSoundGold = false
			db.ignoreEnchants = true
			db.threshold = 0.03
		end
		Options.Refresh()
	end)

	-- ESC closes it (works for a normal frame; would not for a StaticPopup).
	tinsert(UISpecialFrames, "PLBiSScannerOptions")

	-- Restore saved position (or centre).
	local o = ns.db and ns.db.options
	frame:ClearAllPoints()
	if o and o.point then
		frame:SetPoint(o.point, UIParent, o.relPoint or o.point, o.x or 0, o.y or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	frame:Hide()
	return frame
end

----------------------------------------------------------------------
-- Per-character armor/weapon filter window
----------------------------------------------------------------------
-- A separate floating frame with a checkbox per armor material and weapon type.
-- Checked = that category is scored for THIS character; unchecked = the scanner
-- ignores it (score 0, never an upgrade). Writes to ns.chardb.filter, which lives
-- in PassLootBiS_ScannerCharDB (## SavedVariablesPerCharacter), so each character
-- keeps its own picks. Absent keys mean "included", so a fresh character starts
-- with everything on.

local function charFilter() return ns.chardb and ns.chardb.filter end

-- A filter checkbox bound to filter[cat][key]; toggling writes an explicit bool.
local function makeFilterCheck(label, x, y, cat, key)
	local cb = CreateFrame("CheckButton", nil, filterFrame, "UICheckButtonTemplate")
	cb:SetWidth(24)
	cb:SetHeight(24)
	cb:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", x, y)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self)
		if filterRefreshing then return end
		local flt = charFilter()
		if flt and flt[cat] then
			flt[cat][key] = self:GetChecked() and true or false
		end
	end)
	filterChecks[#filterChecks + 1] = { cb = cb, cat = cat, key = key }
	return cb
end

-- Flip every category on/off for this character, then repaint.
local function setAllFilter(on)
	local flt = charFilter()
	if not flt then return end
	for _, key in ipairs(Filter.ARMOR)   do flt.armor[key]   = on end
	for _, key in ipairs(Filter.WEAPONS) do flt.weapons[key] = on end
	Options.RefreshFilter()
end

local function buildFilter()
	if filterFrame then return filterFrame end
	if not Filter then return nil end

	filterFrame = CreateFrame("Frame", "PLBiSScannerFilter", UIParent)
	filterFrame:SetWidth(380)
	filterFrame:SetHeight(540)
	-- DRAG-FREEZE FIX: drag-safe strata + level via the shared helper, no toplevel
	-- (see Core/UI.lua and the note on PLBiSScannerOptions above). ShowFilter() calls
	-- UI.frontOnOpen() so this still opens in front. The +10 level bump is only about
	-- our own two windows: this one is opened from a button on PLBiSScannerOptions, so
	-- it has to land above it (and above its children) rather than tie with it.
	ns.UI.applyWindowChrome(filterFrame, 10)
	ns.UI.applyDarkBackdrop(filterFrame)
	filterFrame:EnableMouse(true)
	filterFrame:SetMovable(true)
	filterFrame:RegisterForDrag("LeftButton")
	filterFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
	filterFrame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)

	local title = filterFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", filterFrame, "TOP", 0, -14)
	title:SetText("Score which gear? (this character only)")

	local close = CreateFrame("Button", nil, filterFrame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", filterFrame, "TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() Options.HideFilter() end)

	local function heading(text, x, y)
		local fs = filterFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", x, y)
		fs:SetText(text)
		return fs
	end

	local cols = { 24, 200 }   -- two-column x positions

	-- Armor materials: 2x2 grid.
	heading("Armor", 20, -40)
	for i, key in ipairs(Filter.ARMOR) do
		local col = (i - 1) % 2
		local row = math.floor((i - 1) / 2)
		makeFilterCheck(key, cols[col + 1], -60 - row * 26, "armor", key)
	end

	-- Weapon types (Shields folded in): two columns, first half down the left.
	heading("Weapons", 20, -120)
	local wlist = Filter.WEAPONS
	local half = math.ceil(#wlist / 2)
	for i, key in ipairs(wlist) do
		local col = (i - 1) < half and 0 or 1
		local row = (i - 1) % half
		makeFilterCheck(key, cols[col + 1], -140 - row * 26, "weapons", key)
	end

	-- Cloaks are cloth but always scored (you never skip your back piece), so make
	-- that explicit -- the Cloth checkbox above only affects cloth body armor.
	local note = filterFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 24, -358)
	note:SetText("Cloaks are always scored (the Cloth box is body armor only).")

	-- Dual-wield off-hand DPS weight (per character): when you dual-wield, how much
	-- of a second one-hander's DPS counts toward the combined weapon score. 50% by
	-- default (WoW's off-hand damage penalty). Only matters if DPS is a spec weight.
	heading("Dual-wield off-hand DPS", 20, -388)
	dwSlider = CreateFrame("Slider", "PLBiSScannerFilterDW", filterFrame, "OptionsSliderTemplate")
	dwSlider:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 24, -414)
	dwSlider:SetWidth(320)
	dwSlider:SetMinMaxValues(0, 100)
	dwSlider:SetValueStep(5)
	_G[dwSlider:GetName() .. "Low"]:SetText("0%")
	_G[dwSlider:GetName() .. "High"]:SetText("100%")
	dwSlider:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value / 5 + 0.5) * 5
		_G[self:GetName() .. "Text"]:SetText(string.format("%d%% of full", value))
		if filterRefreshing then return end
		if ns.chardb then ns.chardb.dwOffhandDps = value / 100 end
	end)

	-- Check-all / uncheck-all.
	local allBtn = CreateFrame("Button", nil, filterFrame, "UIPanelButtonTemplate")
	allBtn:SetWidth(120)
	allBtn:SetHeight(22)
	allBtn:SetPoint("BOTTOMLEFT", filterFrame, "BOTTOMLEFT", 20, 16)
	allBtn:SetText("Check all")
	allBtn:SetScript("OnClick", function() setAllFilter(true) end)

	local noneBtn = CreateFrame("Button", nil, filterFrame, "UIPanelButtonTemplate")
	noneBtn:SetWidth(120)
	noneBtn:SetHeight(22)
	noneBtn:SetPoint("BOTTOMRIGHT", filterFrame, "BOTTOMRIGHT", -20, 16)
	noneBtn:SetText("Uncheck all")
	noneBtn:SetScript("OnClick", function() setAllFilter(false) end)

	tinsert(UISpecialFrames, "PLBiSScannerFilter")   -- ESC closes it
	filterFrame:ClearAllPoints()
	filterFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	filterFrame:Hide()
	return filterFrame
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Re-read the db and repaint every control, so the window always reflects the
-- live settings (including a spec set via slash while it was open).
function Options.Refresh()
	if not frame then return end
	local db = ns.db or {}
	refreshing = true

	local cdb = ns.chardb or {}   -- class/spec are per-character
	UIDropDownMenu_SetText(classDrop, cdb.class or "Select class")
	UIDropDownMenu_Initialize(specDrop, specInit)   -- list follows the current class
	UIDropDownMenu_SetText(specDrop, cdb.spec or "Select spec")

	for _, cb in ipairs(checks) do
		cb:SetChecked(cb.get() and true or false)
	end

	local pct = math.floor((db.threshold or 0) * 100 + 0.5)
	slider:SetValue(pct)
	_G[slider:GetName() .. "Text"]:SetText(string.format("+%d%%", pct))

	if not goldBox:HasFocus() then
		goldBox:SetText(tostring(math.floor((db.goldThreshold or 0) / 10000)))
	end

	UIDropDownMenu_SetText(powerDrop, powerModeText(db.powerMode or "off"))
	if not powerBox:HasFocus() then
		powerBox:SetText(tostring(db.powerWeight or 1))
	end

	refreshing = false
end

function Options.Show()
	build()
	Options.Refresh()
	frame:Show()
	ns.UI.frontOnOpen(frame)   -- front-of-strata on open; no Raise(), see Core/UI.lua
end

function Options.Hide()
	if frame then frame:Hide() end
end

function Options.Toggle()
	build()
	if frame:IsShown() then
		frame:Hide()
	else
		Options.Show()
	end
end

-- Repaint every filter checkbox from the current character's saved picks.
function Options.RefreshFilter()
	if not filterFrame then return end
	local flt = charFilter()
	filterRefreshing = true
	for _, e in ipairs(filterChecks) do
		e.cb:SetChecked(Filter.included(flt, e.cat, e.key) and true or false)
	end
	if dwSlider then
		local pct = math.floor(((ns.chardb and ns.chardb.dwOffhandDps) or 0.5) * 100 + 0.5)
		dwSlider:SetValue(pct)
		_G[dwSlider:GetName() .. "Text"]:SetText(string.format("%d%% of full", pct))
	end
	filterRefreshing = false
end

function Options.ShowFilter()
	if not buildFilter() then return end
	Options.RefreshFilter()
	filterFrame:Show()
	ns.UI.frontOnOpen(filterFrame, 10)   -- front-of-strata on open; no Raise(), see Core/UI.lua
end

function Options.HideFilter()
	if filterFrame then filterFrame:Hide() end
end

function Options.ToggleFilter()
	if not buildFilter() then return end
	if filterFrame:IsShown() then
		filterFrame:Hide()
	else
		Options.ShowFilter()
	end
end

return Options
