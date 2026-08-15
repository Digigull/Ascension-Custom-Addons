--[[ DragTest.lua -- window-drag-freeze ISOLATION harness (ns.DragTest, DEBUG).

RESULT (measured 2026-08-14, Wetlands, cold /reload each, ClientPerfProbe sus=DRAG):
  A HIGH + toplevel + children      -> FREEZE  dt=864ms
  B HIGH + NO toplevel + children   -> smooth  0 spikes
  C FULLSCREEN_DIALOG + toplevel    -> smooth  dt=53ms (imperceptible)
  D HIGH + toplevel + NO children   -> FREEZE  dt=1273ms
CAUSE CONFIRMED: SetToplevel(true) + the crowded HIGH strata, together. D proves
children/backdrop/dropdowns are NOT involved (empty frame still froze 1273ms).
Removing SetToplevel (B) OR moving to a sparse strata (C) eliminates it. FIX
SHIPPED: Options.lua both windows HIGH -> FULLSCREEN_DIALOG (keeps toplevel). This
harness is retained as the reproducer/regression check.

WHY THIS EXISTS
The armor/weapon Filter window (PLBiSScannerFilter) freezes the whole client for
~0.6-2.6s the FIRST time it is dragged each session (re-colds on /reload; pure
engine-side CPU, no addon Lua on the stack -- measured via ClientPerfProbe as a
sus=DRAG spike with cpu= empty). Two fixes were tried and BOTH FAILED:
  1. Swapping the heavy UI-DialogBox backdrop for the light Details recipe -- the
     freeze persisted unchanged. Backdrop EXONERATED.
  2. (The backdrop was the only thing the earlier "confirmed" test varied, and it
     compared two DIFFERENT windows -- a confound.)

What we know now, from comparing this window to a window that NEVER freezes (the
ClientPerfProbe export window, which is smooth on drag):
  - The smooth window ALSO uses SetToplevel(true), RegisterForDrag, and a
    SetBackdrop -- so toplevel, drag-wiring, and the backdrop path are each
    exonerated by a window that has them and does not freeze.
  - What the smooth window does NOT share with this one: it uses the
    FULLSCREEN_DIALOG strata (this window uses HIGH), and its children are a
    handful of buttons + an editbox (this window has ~20 UICheckButtonTemplate +
    an OptionsSliderTemplate). The Filter window has NO dropdowns, so
    UIDropDownMenuTemplate is NOT the cause here.

LEADING HYPOTHESIS: the freeze is the engine's first RAISE-triggered relayout.
SetToplevel(true) makes the first drag RAISE the frame; on 3.3.5 a raise into a
crowded strata (HIGH is where most default UI lives) re-sorts the strata AND can
force a first full layout of the frame's descendants. Cost scales with descendant
widget count and strata population -- which is exactly what separates this window
(HIGH + ~20 widgets) from the smooth one (FULLSCREEN_DIALOG + a few widgets).

THE TEST: four faithful clones of the Filter window's widget load, differing in
exactly ONE construction axis each. Drag each ONCE from a cold client and note
which HITCH. All use the same (heavy) backdrop the installed client has, so the
baseline definitely reproduces; backdrop is held constant because it is already
exonerated.

  A -- REPRO baseline: HIGH strata, SetToplevel(true), full children  -> expect FREEZE
  B -- no SetToplevel:  HIGH strata, (no toplevel),  full children     -> tests the RAISE
  C -- lighter strata:  FULLSCREEN_DIALOG, SetToplevel(true), children -> tests STRATA crowding
  D -- empty chrome:    HIGH strata, SetToplevel(true), ZERO children  -> tests CHILD relayout

Reading:
  * B smooth  => the SetToplevel raise is the cost. Fix: drop SetToplevel(true),
                 or Raise() the frame once at Show() (off the drag path).
  * C smooth  => strata crowding is the cost. Fix: build the window in a lighter
                 strata (e.g. FULLSCREEN_DIALOG / DIALOG).
  * D smooth (A freezes) => the first layout of the ~20 child widgets is the cost
                 (triggered by the raise). Fix: reduce/defer children, or raise
                 once at show so the relayout is paid off the drag path.
  * B and C both smooth => it is the toplevel-raise-into-crowded-strata combo;
                 either fix eliminates it.

If ClientPerfProbe is installed, `/cpp clear` then drag one frame then `/cpp`
labels each result objectively (a sus=DRAG spike = froze; nothing = smooth).

Guarded: under bare lua5.1 there is no client, so the file returns a stub and the
pure cores still self-test. Every CreateFrame/SetBackdrop call is inside build().
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local DragTest = {}
ns.DragTest = DragTest

-- WoW-API from here down; skip under bare lua5.1.
if not rawget(_G, "CreateFrame") then
	return DragTest
end

-- The heavy stock backdrop the installed windows use (held CONSTANT across all
-- four variants -- it is already exonerated, and matching the installed client
-- guarantees the baseline reproduces).
local HEAVY = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

-- Same widget TYPES and COUNTS as the real Filter window (that is what the
-- raise-relayout cost scales with), packed into a grid so position is irrelevant.
-- 20 UICheckButtonTemplate + 1 OptionsSliderTemplate + 2 UIPanelButtonTemplate.
local function addFilterBody(f)
	local name = f:GetName()
	for i = 1, 20 do
		local col = (i - 1) % 4
		local row = math.floor((i - 1) / 4)
		local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
		cb:SetWidth(22)
		cb:SetHeight(22)
		cb:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + col * 90, -36 - row * 26)
		local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
		fs:SetText("opt " .. i)
	end
	local slider = CreateFrame("Slider", name .. "Slider", f, "OptionsSliderTemplate")
	slider:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -196)
	slider:SetWidth(250)
	slider:SetMinMaxValues(0, 100)
	slider:SetValueStep(5)
	if _G[slider:GetName() .. "Low"] then _G[slider:GetName() .. "Low"]:SetText("0%") end
	if _G[slider:GetName() .. "High"] then _G[slider:GetName() .. "High"]:SetText("100%") end
	local a = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	a:SetWidth(120); a:SetHeight(22)
	a:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 16)
	a:SetText("Check all")
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetWidth(120); b:SetHeight(22)
	b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 16)
	b:SetText("Uncheck all")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
end

local VARIANTS = {
	{ key = "A", label = "A: REPRO baseline\nHIGH + toplevel + children\n<-- should FREEZE -->",
	  strata = "HIGH", toplevel = true, children = true },
	{ key = "B", label = "B: NO SetToplevel\nHIGH + children\n(tests the raise)",
	  strata = "HIGH", toplevel = false, children = true },
	{ key = "C", label = "C: FULLSCREEN_DIALOG\ntoplevel + children\n(tests strata crowding)",
	  strata = "FULLSCREEN_DIALOG", toplevel = true, children = true },
	{ key = "D", label = "D: EMPTY chrome\nHIGH + toplevel + NO children\n(tests child relayout)",
	  strata = "HIGH", toplevel = true, children = false },
}
local POS = { { 30, -90 }, { 340, -90 }, { 30, -400 }, { 340, -400 } }

local frames

local function build()
	frames = {}
	for i, v in ipairs(VARIANTS) do
		local f = CreateFrame("Frame", "PLBiSScannerDragTest" .. v.key, UIParent)
		f:SetWidth(300)
		f:SetHeight(300)
		f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", POS[i][1], POS[i][2])
		f:SetFrameStrata(v.strata)
		if v.toplevel then f:SetToplevel(true) end
		f:SetBackdrop(HEAVY)
		f:EnableMouse(true)
		f:SetMovable(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
		f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing() end)
		if v.children then addFilterBody(f) end
		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("BOTTOM", f, "BOTTOM", 0, 44)
		title:SetWidth(270)
		title:SetJustifyH("CENTER")
		title:SetText(v.label)
		f:Hide()
		frames[i] = f
	end
end

-- Show/hide the four isolation frames. Returns true if now shown. Each frame's
-- FIRST drag is independent, so dragging all four in one cold session is valid.
function DragTest.toggle()
	if not frames then build() end
	local anyShown = false
	for _, f in ipairs(frames) do if f:IsShown() then anyShown = true; break end end
	for _, f in ipairs(frames) do
		if anyShown then f:Hide() else f:Show() end
	end
	return not anyShown
end

return DragTest
