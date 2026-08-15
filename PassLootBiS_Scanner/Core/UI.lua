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

FIX: build movable windows on the SPARSE FULLSCREEN_DIALOG strata, where the same
toplevel raise restacks almost nothing. That keeps click-to-raise behaviour (the
reason SetToplevel is wanted) without the freeze -- the recipe the never-freezing
ClientPerfProbe export window already uses. See docs/DRAG-FREEZE.md in the
!ClientPerfProbe repo for the full write-up.

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

-- Apply the drag-safe strata + toplevel to a movable window. Use this instead of
-- SetFrameStrata("HIGH") + SetToplevel(true) on any hand-rolled window -- that
-- pairing is the drag-freeze. Returns the frame for chaining.
function UI.applyWindowChrome(frame)
	if not frame or type(frame.SetFrameStrata) ~= "function" then return frame end
	frame:SetFrameStrata(UI.WINDOW_STRATA)
	if type(frame.SetToplevel) == "function" then
		frame:SetToplevel(true)   -- safe on FULLSCREEN_DIALOG: it is a sparse strata
	end
	return frame
end

return UI
