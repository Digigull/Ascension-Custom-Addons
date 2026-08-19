--[[ WonLedger.lua -- "what I already won this run", so a lesser drop stops reading
as an upgrade.

The problem this solves (owner report, 2026-08): the compare in Scanner.lua scores a
roll against what you are WEARING. Win a shoulder upgrade off the first boss and it
goes to your BAGS -- your equipped shoulders are unchanged -- so when a second, worse
pair drops off the third boss it still scores as an upgrade against the old ones, and
a BiS rule happily Needs it. You end up rolling against your own group for an item you
have already beaten.

So the ledger records what you actually received this run, per equipLoc, and the
compare raises its bar to "what I would be wearing if I equipped what I won".

Deliberately a SOFT list (owner decision): it never edits the BiS list and never
removes anything the user picked. It only raises the comparison bar for the run, and
feeds the end-of-run suggestion that offers to untick the entries it made stale.

applyWins is the whole trick, and it is why this is not a `math.max`. A win DISPLACES
the worst item in its slot group rather than raising the group's floor to itself:
  * single slot (shoulders): {100}, won 120     -> {120}          worst 120
  * dual slot  (rings):      {100, 110}, won 130 -> {130, 110}    worst 110
The dual-slot case is the one max() gets wrong -- you have two ring slots, so a 105
ring is still an upgrade over the 100 you would replace, even after winning a 130.

Pure: no WoW API here at all (the store is a plain table), so the whole file loads
and self-tests under bare lua5.1. Scanner.lua owns the event wiring that fills it.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local WonLedger = {}

--=============================================================================
-- 1. Pure logic
--=============================================================================

-- Fold this run's wins into a slot group's equipped scores.
--   scores : array of equipped scores for the group (0 for an empty slot), as
--            handed to Slots.worstEquipped
--   wins   : array of scores won this run for the same equipLoc, any order
-- Returns a NEW array; `scores` is never mutated (the caller still wants the real
-- equipped numbers for its own reporting).
--
-- Each win, best first, displaces the group's current worst entry. Once the best
-- remaining win no longer beats the worst slot, no later (smaller) win can either,
-- so we stop -- that early exit is correctness, not just speed.
function WonLedger.applyWins(scores, wins)
	local out = {}
	if type(scores) == "table" then
		for i = 1, #scores do out[i] = tonumber(scores[i]) or 0 end
	end
	if #out == 0 or type(wins) ~= "table" then return out end

	local sorted = {}
	for i = 1, #wins do
		local w = tonumber(wins[i])
		if w then sorted[#sorted + 1] = w end
	end
	table.sort(sorted, function(a, b) return a > b end)

	for i = 1, #sorted do
		local worstIdx, worstVal = 1, out[1]
		for j = 2, #out do
			if out[j] < worstVal then worstIdx, worstVal = j, out[j] end
		end
		if sorted[i] <= worstVal then break end
		out[worstIdx] = sorted[i]
	end
	return out
end

-- Turn one of the client's LOOT_ITEM_* format strings into a Lua pattern with the
-- item half captured. The literal parts are escaped first, so a locale that puts a
-- "." or "(" in the sentence still matches; %s becomes the capture and %d a number
-- run. Anchored, so "You receive loot: X." never matches a line that merely
-- contains it.
function WonLedger.toPattern(fmt)
	if type(fmt) ~= "string" or fmt == "" then return nil end
	local p = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
	p = p:gsub("%%%%s", "(.+)")
	p = p:gsub("%%%%d", "%%d+")
	return "^" .. p .. "$"
end

-- The item link out of a "you received X" chat line, or nil for anything else.
-- `patterns` is an ordered array of patterns from toPattern; ORDER MATTERS -- the
-- "...x3." multiple form must come before the plain one, because the plain form's
-- (.+) would otherwise swallow the count and hand back a link with "x3" glued on.
function WonLedger.linkFromLootMessage(msg, patterns)
	if type(msg) ~= "string" or type(patterns) ~= "table" then return nil end
	for i = 1, #patterns do
		local captured = msg:match(patterns[i])
		if captured then
			-- Only a real item link is usable; currency/honor lines capture plain text.
			if captured:find("|Hitem:", 1, true) then return captured end
			return nil
		end
	end
	return nil
end

--=============================================================================
-- 2. The run store -- a plain table, no WoW API
--=============================================================================
-- Keyed by equipLoc (INVTYPE_*) rather than by inventory slot id: the compare
-- works in equipLoc terms, and a dual-slot group shares one key by design (two
-- ring wins both land under INVTYPE_FINGER and displace both ring slots in turn).

local store = {}     -- equipLoc -> array of { score, link, name }
local zone            -- the zone/instance this store belongs to

-- Record one received item. A zero-or-negative score is dropped: it means the item
-- has no weighted stats for this spec, so it can never raise anyone's bar, and
-- keeping it would only bloat the end-of-run suggestion with vendor trash.
function WonLedger.record(equipLoc, score, link, name)
	if type(equipLoc) ~= "string" or equipLoc == "" then return false end
	score = tonumber(score)
	if not score or score <= 0 then return false end
	local list = store[equipLoc]
	if not list then list = {}; store[equipLoc] = list end
	list[#list + 1] = { score = score, link = link, name = name }
	return true
end

-- The scores won this run for one equipLoc, in the array shape applyWins wants.
function WonLedger.winsFor(equipLoc)
	local list = store[equipLoc]
	if not list then return nil end
	local out = {}
	for i = 1, #list do out[i] = list[i].score end
	return out
end

-- The best single win for an equipLoc, for the popup's "you already won X" line.
function WonLedger.bestFor(equipLoc)
	local list = store[equipLoc]
	if not list then return nil end
	local best
	for i = 1, #list do
		if not best or list[i].score > best.score then best = list[i] end
	end
	return best
end

function WonLedger.isEmpty()
	return next(store) == nil
end

-- Wipe the run. Returns what was in it, so the caller can report on it before it
-- goes (the end-of-run "these BiS entries look stale" suggestion).
function WonLedger.clear()
	local old = store
	store = {}
	zone = nil
	return old
end

-- Which run the store belongs to. SetZone returns true when the zone actually
-- CHANGED, which is the caller's cue to close out the run -- so the zone check and
-- the "did we move?" answer can never drift apart in the caller.
function WonLedger.GetZone() return zone end
function WonLedger.SetZone(z)
	local changed = (zone ~= nil and z ~= nil and z ~= zone)
	zone = z
	return changed
end

--=============================================================================
-- 3. Offline self-test (skipped in-game)
--=============================================================================

if rawget(_G, "WONLEDGER_SELFTEST") then
	local passed = 0
	local function ok(cond, msg)
		if not cond then error("WonLedger self-test FAILED: " .. tostring(msg), 2) end
		passed = passed + 1
	end
	local function eqArr(got, want, msg)
		ok(#got == #want, msg .. " (length " .. #got .. " vs " .. #want .. ")")
		for i = 1, #want do
			ok(got[i] == want[i], msg .. " [" .. i .. "] got " .. tostring(got[i]) ..
				" want " .. tostring(want[i]))
		end
	end

	-- applyWins: single slot -- the win simply replaces what you wear.
	eqArr(WonLedger.applyWins({ 100 }, { 120 }), { 120 }, "single slot displaced")
	eqArr(WonLedger.applyWins({ 100 }, { 80 }), { 100 }, "worse win changes nothing")
	eqArr(WonLedger.applyWins({ 100 }, {}), { 100 }, "no wins -> unchanged")
	eqArr(WonLedger.applyWins({ 100 }, nil), { 100 }, "nil wins -> unchanged")

	-- applyWins: dual slot -- the win takes the WORSE ring, leaving the better one
	-- as the new bar. This is the case math.max would get wrong (it would say 130).
	eqArr(WonLedger.applyWins({ 100, 110 }, { 130 }), { 130, 110 }, "dual slot displaces worst")
	local ring = WonLedger.applyWins({ 100, 110 }, { 130 })
	ok(math.min(ring[1], ring[2]) == 110, "dual slot new bar is 110, not 130")

	-- Two wins in one run displace both slots, best first.
	eqArr(WonLedger.applyWins({ 100, 110 }, { 130, 120 }), { 130, 120 }, "two wins displace both")
	-- Order of the wins array must not matter.
	eqArr(WonLedger.applyWins({ 100, 110 }, { 120, 130 }), { 130, 120 }, "win order irrelevant")
	-- A third win worse than everything equipped is ignored.
	eqArr(WonLedger.applyWins({ 100, 110 }, { 130, 120, 50 }), { 130, 120 }, "worthless win ignored")
	-- Empty slot (score 0) is the first thing a win fills.
	eqArr(WonLedger.applyWins({ 0, 110 }, { 40 }), { 40, 110 }, "win fills the empty slot")
	-- Source array is never mutated.
	local src = { 100, 110 }
	WonLedger.applyWins(src, { 130 })
	eqArr(src, { 100, 110 }, "input scores untouched")
	-- Degenerate inputs.
	eqArr(WonLedger.applyWins({}, { 130 }), {}, "no slots -> empty")
	eqArr(WonLedger.applyWins(nil, { 130 }), {}, "nil scores -> empty")

	-- toPattern / linkFromLootMessage
	local pSelf = WonLedger.toPattern("You receive loot: %s.")
	local pMulti = WonLedger.toPattern("You receive loot: %sx%d.")
	local pPush = WonLedger.toPattern("You receive item: %s.")
	ok(pSelf ~= nil and pMulti ~= nil, "patterns built")
	ok(WonLedger.toPattern(nil) == nil, "nil format -> nil pattern")
	ok(WonLedger.toPattern("") == nil, "empty format -> nil pattern")

	local LINK = "|cffa335ee|Hitem:412491:0:0:0:0:0:0:0:60|h[Kyrstel Mantle]|h|r"
	local pats = { pMulti, pSelf, pPush }
	ok(WonLedger.linkFromLootMessage("You receive loot: " .. LINK .. ".", pats) == LINK,
		"plain self-loot line -> link")
	ok(WonLedger.linkFromLootMessage("You receive item: " .. LINK .. ".", pats) == LINK,
		"pushed-item line -> link")
	-- The multiple form must be tried FIRST, or the plain form's (.+) eats the "x3".
	ok(WonLedger.linkFromLootMessage("You receive loot: " .. LINK .. "x3.", pats) == LINK,
		"stacked line -> link without the count")
	-- Someone else's loot must never count as ours.
	ok(WonLedger.linkFromLootMessage("Bob receives loot: " .. LINK .. ".", pats) == nil,
		"another player's loot ignored")
	-- Non-item lines capture text but no link.
	ok(WonLedger.linkFromLootMessage("You receive loot: 15 Gold.", pats) == nil,
		"money line -> nil")
	ok(WonLedger.linkFromLootMessage(nil, pats) == nil, "nil message -> nil")
	ok(WonLedger.linkFromLootMessage("You receive loot: x.", nil) == nil, "nil patterns -> nil")

	-- The store.
	ok(WonLedger.isEmpty(), "store starts empty")
	ok(WonLedger.record("INVTYPE_SHOULDER", 120, LINK, "Kyrstel Mantle"), "record accepted")
	ok(not WonLedger.isEmpty(), "store no longer empty")
	ok(not WonLedger.record("INVTYPE_SHOULDER", 0, LINK), "zero-score win rejected")
	ok(not WonLedger.record("INVTYPE_SHOULDER", -5, LINK), "negative-score win rejected")
	ok(not WonLedger.record(nil, 120, LINK), "nil equipLoc rejected")
	eqArr(WonLedger.winsFor("INVTYPE_SHOULDER"), { 120 }, "winsFor returns scores")
	ok(WonLedger.winsFor("INVTYPE_HEAD") == nil, "winsFor unknown slot -> nil")
	WonLedger.record("INVTYPE_SHOULDER", 140, LINK, "Better Mantle")
	ok(WonLedger.bestFor("INVTYPE_SHOULDER").score == 140, "bestFor picks the highest")

	-- Zone tracking: the FIRST set is not a change (we had no run before).
	ok(WonLedger.SetZone("Utgarde Keep") == false, "first zone is not a change")
	ok(WonLedger.GetZone() == "Utgarde Keep", "zone stored")
	ok(WonLedger.SetZone("Utgarde Keep") == false, "same zone is not a change")
	ok(WonLedger.SetZone("Dalaran") == true, "different zone is a change")

	local old = WonLedger.clear()
	ok(old.INVTYPE_SHOULDER ~= nil, "clear hands back what it held")
	ok(WonLedger.isEmpty(), "store empty after clear")
	ok(WonLedger.GetZone() == nil, "clear drops the zone")

	print("WonLedger self-test: all " .. passed .. " vectors passed.")
	return
end

ns.WonLedger = WonLedger
return WonLedger
