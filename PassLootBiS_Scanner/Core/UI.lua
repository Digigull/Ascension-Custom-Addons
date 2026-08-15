--[[ UI.lua -- shared window chrome (ns.UI).

ONE home for the frame-strata + toplevel choice every hand-rolled movable window
uses, so a new window (or a careless edit) can't drift back into the drag-freeze.

DRAG-FREEZE (Ascension 3.3.5) -- measured cause, do NOT undo:
A window that calls SetToplevel(true) while sitting on the HIGH strata freezes
the WHOLE client for ~0.8-1.3s the FIRST time it is dragged each session. The
first drag RAISES the toplevel frame, and raising into the crowded HIGH strata
(where most default UI + addons live) restacks the whole strata in a one-time
engine-side pass. It is pure engine CPU (no addon Lua on the stack) and re-colds
on /reload. Proven single-variable via /plbisscan dragtest (Core/DragTest.lua):
an EMPTY HIGH+toplevel frame still froze 1273ms (so it is NOT the backdrop or the
children), while FULLSCREEN_DIALOG + toplevel was smooth (~53ms) and dropping
SetToplevel was smooth (0 spikes).

FIX -- do NOT call SetToplevel(true). That single rule is what buys the true zero.
A toplevel frame re-raises every time it is grabbed, so even on a sparse strata it
pays a ~50ms restack on EVERY click/drag -- a repeatable micro-spike on a window
you reposition often, measured in the field on a settings window. With no toplevel
there is no raise at all, so the cost is zero, cold and warm, on ANY strata.

That last part is the important consequence: once the flag is gone, the strata is
free to be a UI decision instead of a performance one. Variant B in the isolation
test kept the crowded HIGH strata and was still perfectly smooth, because nothing
ever raised. So WINDOW_STRATA below is chosen purely for layering, NOT for safety.
If SetToplevel is ever added back, that stops being true immediately and the strata
becomes load-bearing again -- which is the trap this file exists to prevent.

Front-on-open, the one thing the flag did usefully provide, is kept explicitly via
UI.raiseOnOpen() in each show path: one restack on open rather than one per drag.

See management/docs/DRAG-FREEZE.md for the full write-up.

Guarded: a table with no :SetFrameStrata (or a nil frame) is a safe no-op, so this
is inert under bare lua5.1 where no real frames exist.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local UI = {}
ns.UI = UI

-- Strata for the addon's movable windows. LOW deliberately: it renders above the
-- 3D world but BELOW the default Blizzard panels (character sheet, bags, world map),
-- which is the expected behaviour for custom UI -- Blizzard's own windows should
-- come out on top. Same placement Details uses for its meters.
--
-- Strata order, low -> high:
--   WORLD < BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP
--
-- This is a LAYERING choice, not a performance one, and it is only available
-- because applyWindowChrome() does not set SetToplevel -- see the file header.
-- A LOW + SetToplevel window would restack the LOW strata on every drag, the same
-- mechanism as the HIGH freeze.
--
-- NOTE: this is for windows that are fine being covered by Blizzard panels. It is
-- deliberately NOT used for two kinds of window in this addon:
--   * the debug copy box (Core/Scanner.lua) -- a copy/paste popup you open to
--     select text from, so it must float above whatever is on screen.
--   * the upgrade Alert (Core/Alert.lua) -- a transient notification whose whole
--     job is to be noticed; behind open bags while looting it would be missed.
--
-- Pure data, so it is offline-inspectable; applyWindowChrome() is the guarded wrapper.
UI.WINDOW_STRATA = "LOW"

-- Apply the drag-safe strata to a movable window. Use this instead of
-- SetFrameStrata("HIGH") + SetToplevel(true) on any hand-rolled window -- that
-- pairing is the drag-freeze.
--
-- Deliberately does NOT call SetToplevel(true): see part 2 of the header. Adding
-- it back reintroduces a ~50ms strata restack on every single drag. If a window
-- needs to come to the front when opened, call UI.raiseOnOpen() in its show path
-- instead -- that pays the restack once, on open, not on every grab.
--
-- Returns the frame for chaining.
function UI.applyWindowChrome(frame)
	if not frame or type(frame.SetFrameStrata) ~= "function" then return frame end
	frame:SetFrameStrata(UI.WINDOW_STRATA)
	return frame
end

-- Bring a window to the front of its strata, once, from a show path. This is the
-- explicit replacement for the click-to-raise that SetToplevel used to give us:
-- same front-on-open result, but paid once per open instead of once per drag.
-- Guarded like applyWindowChrome, so it is inert where no real frames exist.
--
-- NOTE: only call this on a SPARSE strata. Raise() restacks the frame's strata,
-- which is cheap where few frames live but is the expensive ~1s pass on a crowded
-- one like HIGH. UI.WINDOW_STRATA (LOW) is sparse -- most of the default UI and
-- most addons sit on MEDIUM and above -- so windows built via applyWindowChrome()
-- are safe. Raise() also cannot cross strata: it orders the window among its LOW
-- siblings only, so it still stays under the Blizzard panels by design.
function UI.raiseOnOpen(frame)
	if not frame or type(frame.Raise) ~= "function" then return frame end
	frame:Raise()
	return frame
end

--------------------------------------------------------------------------------
-- House window styling (cosmetic)
--
-- The flat dark "Details-style" chrome: the tooltip background tiled behind a 1px
-- WHITE8X8 border, tinted near-black, replacing the ornate gold UI-DialogBox
-- parchment. Kept here so every window in the addon shares one look and a single
-- edit re-themes all of them.
--
-- Purely cosmetic and entirely separate from the drag-freeze work above: the
-- backdrop was explicitly exonerated as a cause (an EMPTY frame with no backdrop
-- at all still froze). Restyling a window neither causes nor cures a spike.
--
-- Pure data so it stays offline-inspectable, matching WINDOW_STRATA above.
UI.DARK_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Buttons\\WHITE8X8",
	tile = true, tileSize = 64, edgeSize = 1,
	insets = { left = 1, right = 1, top = 1, bottom = 1 },
}
UI.DARK_BACKDROP_COLOR = { 0.05, 0.05, 0.07, 0.95 }   -- dark, mostly opaque
UI.DARK_BORDER_COLOR   = { 0.30, 0.30, 0.34, 1 }      -- thin muted border

-- Apply the house backdrop to a window. Guarded like the helpers above, so it is
-- inert under bare lua5.1 where no real frames exist. Returns the frame.
function UI.applyDarkBackdrop(frame)
	if not frame or type(frame.SetBackdrop) ~= "function" then return frame end
	frame:SetBackdrop(UI.DARK_BACKDROP)
	local c = UI.DARK_BACKDROP_COLOR
	if type(frame.SetBackdropColor) == "function" then
		frame:SetBackdropColor(c[1], c[2], c[3], c[4])
	end
	local b = UI.DARK_BORDER_COLOR
	if type(frame.SetBackdropBorderColor) == "function" then
		frame:SetBackdropBorderColor(b[1], b[2], b[3], b[4])
	end
	return frame
end

return UI
