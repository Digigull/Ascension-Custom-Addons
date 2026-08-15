-- FINDER: shared scan throttle -------------------------------------------------
--
-- Opening an NPC/merchant or a profession window makes the client stream item
-- data in from the server, and the events that carry it (MERCHANT_UPDATE,
-- TRADE_SKILL_UPDATE) fire in BURSTS -- one per row whose data is still cold.
-- The Finder's harvesters used to re-walk the whole list on every one of those
-- events, which is what made large vendors and professions stutter.
--
-- This module is the "have we already done this?" ledger the harvesters check
-- so they take the least aggressive path:
--
--   * they DEBOUNCE the event storm down to a single harvest a beat after the
--     updates go quiet (each harvester owns its own settle timer), and
--   * they record a SIGNATURE of what they harvested here, so re-opening the
--     same vendor or profession -- or a late stray update for it -- costs only
--     a cheap string compare instead of another full walk.
--
-- The ledger is a plain Lua table held in this file, so it lives exactly as
-- long as the UI session: it resets on /reload or relog.  That is deliberate.
-- Vendor stock and learned recipes do not drift within a session, so "seen this
-- session" is the safe skip window; a fresh login re-learns everything once, in
-- case a vendor rotated stock or the player trained a new recipe.
--
-- Completeness is the caller's job, not the ledger's: a harvester marks a
-- signature seen ONLY when it read the list with a warm cache (nothing cold).
-- A harvest taken while item data was still streaming leaves the signature
-- unmarked, so the next quiet update re-harvests and fills the gaps.  This is
-- why the ledger only ever stores "done", never "attempted".

local gSeen = {};   -- signature string -> true, for lists fully harvested this session

-- True once Mark has recorded this signature this session.  A nil/empty key is
-- never "seen" (an unidentifiable source is always allowed to scan).
function Fdr_ScanThrottle_Seen (key)
	if (type (key) ~= "string" or key == "") then return false; end
	return gSeen[key] == true;
end

-- Record that the list identified by `key` was fully harvested this session, so
-- future opens of the same list skip the walk.  No-op for a nil/empty key.
function Fdr_ScanThrottle_Mark (key)
	if (type (key) ~= "string" or key == "") then return; end
	gSeen[key] = true;
end

-- Forget everything.  Only used by the test harness (and harmless in game);
-- the ledger otherwise clears itself when the session ends.
function Fdr_ScanThrottle_Reset ()
	gSeen = {};
end
