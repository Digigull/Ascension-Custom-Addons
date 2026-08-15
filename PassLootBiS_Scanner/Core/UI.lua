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

FIX -- two parts, and BOTH are needed for a true zero:
  1. Build movable windows on the SPARSE FULLSCREEN_DIALOG strata, where a raise
     restacks almost nothing (~50ms) instead of the whole crowded HIGH list (~1s).
  2. Do NOT call SetToplevel(true). Part 1 alone kills the big cold freeze but
     leaves a ~50ms restack on EVERY click/drag, because a toplevel frame
     re-raises every time it is grabbed. That is a repeatable micro-spike on any
     window you reposition often -- measured in the field on a settings window,
     and cured only by dropping the flag. With no toplevel there is no raise, so
     the per-drag cost is zero, cold and warm.

Dropping the flag is free here because these windows are singletons that never
need click-to-raise: FULLSCREEN_DIALOG already renders them above the DIALOG-strata
Interface Options panel by strata alone. What the flag did provide -- front-on-open
-- is kept explicitly via UI.raiseOnOpen() in each show path, which is one cheap
restack in a near-empty strata on open rather than one on every drag.

See docs/DRAG-FREEZE.md in the !ClientPerfProbe repo for the full write-up.

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

-- The drag-safe strata for movable toplevel windows (see file header). Pure data,
-- so it is offline-inspectable; applyWindowChrome() is the guarded WoW wrapper.
UI.WINDOW_STRATA = "FULLSCREEN_DIALOG"

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
function UI.raiseOnOpen(frame)
	if not frame or type(frame.Raise) ~= "function" then return frame end
	frame:Raise()
	return frame
end

return UI
