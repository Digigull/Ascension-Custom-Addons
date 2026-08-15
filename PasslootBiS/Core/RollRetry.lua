--[[--------------------------------------------------------------------------
  RollRetry.lua  —  first-see item-info helpers for the loot-roll path

  Two small, pure, offline-tested primitives that harden the roll path against
  GetItemInfo being cold or unreliable on this client:
    * ShouldRetry   — the retry-gate decision (wait for GetItemInfo, or evaluate).
    * NameFromLink  — recover the exact item name from the link itself, so the
                      exact-name BiS rule never depends on GetItemInfo at all.

  Why this exists (the silent bug it fixes):
  On WoW 3.3.5, GetItemInfo(link) returns nil for an item the client has not
  cached yet — i.e. the FIRST time you encounter it in a session. PassLoot builds
  its itemObj (Core/ItemInfo.lua) entirely from that one call, so a first-see item
  has no name/class/subclass, and PasslootBiS:ValidateItemObj (Core/Cache.lua) then
  makes GetItemEvaluation skip rule evaluation ENTIRELY. The roll frame silently
  falls through — no auto-roll, on ANY rule, including the ID-matched BiS rules —
  and the user has to roll by hand. (This is distinct from the cached-stats "lie"
  in research §2.4a: here the item info is simply ABSENT, not wrong.)

  There is no ITEM_INFO_RECEIVED-style event on this client (not in the Ascension
  API dumps), so the fix is a bounded re-poll: GetItemInfo populates asynchronously
  right after the first query, so re-building the item a few times over ~1s lets the
  name arrive and the normal evaluation run. PassLoot.lua drives the timer loop; the
  PURE gate decision (retry vs. proceed) lives here so it can be self-tested offline.

  Split like the addon's other tested modules (see RollAdvisor.lua): a PURE core
  self-tested under bare Lua 5.1 (ROLLRETRY_SELFTEST), then a one-line in-game
  attach guarded behind LibStub.

  Client target: WoW 3.3.5 (Ascension), Lua 5.1.
----------------------------------------------------------------------------]]

--=============================================================================
-- 0. Pure core — no WoW API, unit-testable offline (ROLLRETRY_SELFTEST)
--=============================================================================

local RollRetry = {}

-- Tuning: how many times to build+check the item, and how long to wait between
-- attempts. MAX_ATTEMPTS counts the FIRST (synchronous) try too, so the extra
-- re-polls number MAX_ATTEMPTS-1 and the total wait is ≈ (MAX_ATTEMPTS-1)*DELAY.
-- 6 attempts * 0.25s ≈ a 1.25s window, well inside the multi-second roll timer and
-- long enough for GetItemInfo to populate even on a laggy first-see.
RollRetry.MAX_ATTEMPTS = 6
RollRetry.DELAY        = 0.25

-- The whole decision, pure: should the roll path DEFER (schedule another attempt)
-- rather than evaluate now?  Defer only when the item has NOT resolved yet (the
-- client hasn't cached its info) AND attempts remain. Once resolved -> evaluate
-- immediately (never waste a roll-window second); out of attempts -> stop retrying
-- and let GetItemEvaluation record the miss as before (no worse than old behaviour).
--
--   resolved     — boolean: did the item resolve? (ValidateItemObj: name+id+link)
--   attempt      — 1-based index of the attempt just made
--   maxAttempts  — cap (defaults to MAX_ATTEMPTS)
function RollRetry.ShouldRetry(resolved, attempt, maxAttempts)
  if resolved then return false end
  maxAttempts = tonumber(maxAttempts) or RollRetry.MAX_ATTEMPTS
  attempt = tonumber(attempt) or 1
  return attempt < maxAttempts
end

-- Parse an item's display name straight from its link's [bracket] text. That text
-- is what the server sent for THIS instance, so — unlike GetItemInfo — it is immune
-- both to the client cache (nil on a first-see item) and to Ascension's scaled-variant
-- lie (the cache reflects the BASE item — research §2.4a). WoW item names never
-- contain a bracket, so a single non-greedy match is exact. Returns nil for anything
-- that isn't a string with non-empty [bracket] text.
function RollRetry.NameFromLink(link)
  if type(link) ~= "string" then return nil end
  local name = link:match("%[(.-)%]")
  if name == nil or name == "" then return nil end
  return name
end

--=============================================================================
-- 1. Offline self-test (skipped in-game; run by scripts/test.sh)
--=============================================================================

if rawget(_G, "ROLLRETRY_SELFTEST") then
  local passed = 0
  local function ok(cond, msg)
    if not cond then error("RollRetry self-test FAILED: " .. tostring(msg), 2) end
    passed = passed + 1
  end

  -- Resolved item: never retry, regardless of attempt number.
  ok(RollRetry.ShouldRetry(true, 1, 5) == false, "resolved@1 -> no retry")
  ok(RollRetry.ShouldRetry(true, 4, 5) == false, "resolved@4 -> no retry")

  -- Unresolved item: retry while attempts remain, stop exactly at the cap
  -- (off-by-one guard: attempt 4 of 5 still retries; attempt 5 stops).
  ok(RollRetry.ShouldRetry(false, 1, 5) == true,  "unresolved@1 -> retry")
  ok(RollRetry.ShouldRetry(false, 4, 5) == true,  "unresolved@4 -> retry")
  ok(RollRetry.ShouldRetry(false, 5, 5) == false, "unresolved@5 (cap) -> stop")
  ok(RollRetry.ShouldRetry(false, 6, 5) == false, "unresolved past cap -> stop")

  -- Default cap (uses MAX_ATTEMPTS, whatever it is set to) + a nil-attempt coercion.
  ok(RollRetry.ShouldRetry(false, 1) == true, "unresolved@1 default cap -> retry")
  ok(RollRetry.ShouldRetry(false, RollRetry.MAX_ATTEMPTS) == false, "unresolved@MAX default cap -> stop")
  ok(RollRetry.ShouldRetry(false, nil, 5) == true, "nil attempt coerced to 1 -> retry")

  -- A cap of 1 (no re-polls) must never retry, even unresolved.
  ok(RollRetry.ShouldRetry(false, 1, 1) == false, "cap 1 -> never retry")

  -- NameFromLink: the exact-name BiS rule must never depend on GetItemInfo, so the
  -- name is recoverable straight from the link's [bracket] text.
  ok(RollRetry.NameFromLink("|cff9d9d9d|Hitem:7073:0:0:0:0:0:0:0|h[Broken Fang]|h|r") == "Broken Fang", "colored link -> name")
  ok(RollRetry.NameFromLink("|Hitem:1559469:0:0:0|h[Gahz'rilla Scale Armor]|h|r") == "Gahz'rilla Scale Armor", "apostrophe name")
  ok(RollRetry.NameFromLink("|cffa335ee|Hitem:412491:0:0:0:0:0:0:0:60|h[Kyrstel Mantle]|h|r") == "Kyrstel Mantle", "scaled-variant link -> shared base name")
  ok(RollRetry.NameFromLink("[Just Brackets]") == "Just Brackets", "bare bracket text")
  ok(RollRetry.NameFromLink("no brackets here") == nil, "no bracket -> nil")
  ok(RollRetry.NameFromLink("") == nil, "empty string -> nil")
  ok(RollRetry.NameFromLink("|h[]|h") == nil, "empty bracket -> nil")
  ok(RollRetry.NameFromLink(nil) == nil, "nil link -> nil")
  ok(RollRetry.NameFromLink(12345) == nil, "non-string -> nil")

  print("RollRetry self-test: all " .. passed .. " vectors passed.")
  return
end

--=============================================================================
-- 2. In-game attach — expose the pure gate on the addon for the roll path.
--    Guarded: bare Lua 5.1 has no LibStub, so the file stops here offline.
--=============================================================================

if not rawget(_G, "LibStub") then
  return RollRetry
end

local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
PasslootBiS.RollRetry = RollRetry
