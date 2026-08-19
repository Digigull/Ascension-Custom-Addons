--[[ UI.lua -- shared window chrome (ns.UI).

ONE home for the frame-strata + toplevel choice every hand-rolled movable window
uses, so a new window (or a careless edit) can't drift back into the drag-freeze.

DRAG-FREEZE (Ascension 3.3.5) -- measured cause, do NOT undo:
A window that calls SetToplevel(true) while sitting on the HIGH strata freezes
the WHOLE client for ~0.8-1.3s the FIRST time it is dragged each session. The
first drag RAISES the toplevel frame, and raising into the crowded HIGH strata
(where most default UI + addons live) restacks the whole strata in a one-time
engine-side pass. It is pure engine CPU (no addon Lua on the stack) and re-colds
on /reload. Proven single-variable by a four-frame isolation harness (since
retired, once the cause was confirmed -- management/docs/DRAG-FREEZE.md): an EMPTY
HIGH+toplevel frame still froze 1273ms (so it is NOT the backdrop or the children),
while FULLSCREEN_DIALOG + toplevel was smooth (~53ms) and dropping SetToplevel was
smooth (0 spikes).

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

Front-on-open, the one thing the flag did usefully provide, is kept without any
restack at all: applyWindowChrome() parks the window on a fixed high frame level
inside its strata (UI.WINDOW_LEVEL), and UI.frontOnOpen() re-asserts that in each
show path. Frame level is a per-frame property -- setting it moves one frame, it
does not reorder the strata -- so it costs nothing, cold or warm. That replaced
the earlier Raise()-on-open once the windows moved up to MEDIUM: Raise() IS the
restack the freeze is made of, and MEDIUM is not a sparse strata.

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

-- Strata for the addon's movable windows. MEDIUM deliberately: LOW put them under
-- the default action bars and unit frames (and under Bartender's bars), so a window
-- parked anywhere near the bottom or the top-left of the screen was drawn through by
-- health bars and buttons. MEDIUM clears both while still staying BELOW the Blizzard
-- panels on HIGH and above (bags, and anything on DIALOG such as the Interface
-- Options window), which is the layering custom UI is expected to take.
--
-- Strata order, low -> high:
--   WORLD < BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP
--
-- This is a LAYERING choice, not a performance one, and it is only available
-- because applyWindowChrome() does not set SetToplevel -- see the file header.
-- A MEDIUM + SetToplevel window would restack the MEDIUM strata on every drag, the
-- same mechanism as the HIGH freeze.
--
-- NOTE (2026-08 field finding, recorded here because it reads as a surprise): "the
-- Blizzard panels" is not one layer. Bags are HIGH and the Interface Options window
-- is DIALOG, so MEDIUM does stay under those -- but the character sheet and the
-- auction house take MEDIUM's own default level and only raise within it when you
-- CLICK them, so a MEDIUM window at level 100 sits in FRONT of them when they are
-- opened by keybind or by an NPC. The two windows where that mattered were moved down
-- to LOW (the PassLoot Loot Rolls window and the cpp meter, both persistent logs left
-- open while playing). These stay on MEDIUM by the owner's call: they are windows you
-- open deliberately, use, and close, not ones parked on screen all session.
--
-- NOTE: this is for windows that are fine being covered by the Blizzard panels. It
-- is deliberately NOT used for two kinds of window in this addon:
--   * the debug copy box (Core/Scanner.lua) -- a copy/paste popup you open to
--     select text from, so it must float above whatever is on screen.
--   * the upgrade Alert (Core/Alert.lua) -- a transient notification whose whole
--     job is to be noticed; behind open bags while looting it would be missed.
--
-- Pure data, so it is offline-inspectable; applyWindowChrome() is the guarded wrapper.
UI.WINDOW_STRATA = "MEDIUM"

-- Frame level inside that strata. Strata alone is not enough on MEDIUM: action bar
-- addons (Bartender among them) default to MEDIUM too, and within one strata the
-- higher frame level wins. Blizzard's own frames and the bar addons sit in the low
-- single digits there, so 100 clears them with room to spare while staying under the
-- client's per-strata level ceiling.
--
-- This is also what gives us front-on-open for free: a fixed level above the
-- neighbours means the window is already in front, with no Raise() and therefore no
-- strata restack. See the file header.
UI.WINDOW_LEVEL = 100

-- Apply the drag-safe strata + level to a movable window. Use this instead of
-- SetFrameStrata("HIGH") + SetToplevel(true) on any hand-rolled window -- that
-- pairing is the drag-freeze.
--
-- levelBump (optional) offsets the frame level for a window that has to sit above
-- another window of ours rather than merely above the game's UI: two windows on the
-- same level order by nothing you can rely on, and a window's own children take
-- level+1 upwards, so bump in steps of 10 and leave 0 for the default case.
--
-- Deliberately does NOT call SetToplevel(true): see part 2 of the header. Adding
-- it back reintroduces a ~50ms strata restack on every single drag -- and on MEDIUM
-- the first one would be the full ~1s pass. If a window needs to come to the front
-- when opened, call UI.frontOnOpen() in its show path.
--
-- Returns the frame for chaining.
function UI.applyWindowChrome(frame, levelBump)
	if not frame or type(frame.SetFrameStrata) ~= "function" then return frame end
	frame:SetFrameStrata(UI.WINDOW_STRATA)
	if type(frame.SetFrameLevel) == "function" then
		frame:SetFrameLevel(UI.WINDOW_LEVEL + (tonumber(levelBump) or 0))
	end
	return frame
end

-- Put a window in front, from a show path. This is the replacement for the
-- click-to-raise that SetToplevel used to give us, and for the Raise()-on-open that
-- replaced it while these windows were on the sparse LOW strata.
--
-- It does NOT call Raise(). Raise() reorders the frame against every sibling in its
-- strata, which is the exact operation the drag-freeze is made of: cheap on a sparse
-- strata, but the ~1s engine pass on a populated one -- and MEDIUM, shared with the
-- default UI and the action bar addons, is populated. Re-asserting the fixed strata +
-- level instead touches one frame and reorders nothing, so it is free, and the level
-- chosen above already puts the window above its neighbours.
--
-- Guarded like applyWindowChrome, so it is inert where no real frames exist.
function UI.frontOnOpen(frame, levelBump)
	return UI.applyWindowChrome(frame, levelBump)
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
