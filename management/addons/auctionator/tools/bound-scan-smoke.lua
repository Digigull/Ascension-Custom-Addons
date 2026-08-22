-- bound-scan-smoke.lua -- pins BACKLOG item 14's marker list.
--
-- Run from the repo root:   lua5.1 management/addons/auctionator/tools/bound-scan-smoke.lua
--
-- Why this one exists when the house rule is "ship it, tooling is a fallback":
-- the SELL browser decides whether an item can be auctioned by matching its
-- tooltip against a list of strings, and that list is now open-ended -- it has
-- Ascension's own "Realmbound" on it, and it will grow again the next time a
-- custom status turns up.  The hazard is not the entries that are on it.  It is
-- the two that must never be:
--
--     "Binds when equipped"  and  "Binds when used"
--
-- are the ordinary state of most gear worth selling, they differ from
-- "Binds when picked up" by one word, and an entry or a loosening that caught
-- them would empty the browser of exactly the items it exists for -- silently,
-- and only for the player whose bags happen to hold them.  So the negatives are
-- asserted here, not reasoned about.
--
-- It needs no stubs to speak of: Auctionator.lua loads under bare lua5.1 with
-- `time` and `date` filled in, so this drives the REAL function rather than a
-- copy of it.  Keep it that way -- a test of a transcribed marker list would be
-- worth nothing.

local passed, failed = 0, 0

local function check (ok, what)
	if (ok) then
		passed = passed + 1
	else
		failed = failed + 1
		print ("FAIL: " .. what)
	end
end

local function eq (got, want, what)
	check (got == want, string.format ("%s -- got %s, wanted %s", what, tostring (got), tostring (want)))
end

--------------------------------------------------------------------
-- client stubs.  The ITEM_* globals must be set BEFORE the first call:
-- the marker list is built once, lazily, and cached.
--------------------------------------------------------------------

time = os.time
date = os.date
SlashCmdList = {}

ITEM_SOULBOUND			= "Soulbound"
ITEM_BIND_ON_PICKUP		= "Binds when picked up"
ITEM_BIND_QUEST			= "Quest Item"
ITEM_BIND_TO_ACCOUNT	= "Binds to account"
ITEM_ACCOUNTBOUND		= "Account Bound"
ITEM_BNETACCOUNTBOUND	= "Binds to Battle.net account"

-- The two that must NEVER match.  Set as globals so a future edit that adds
-- them to the marker list is caught here rather than in somebody's bags.
ITEM_BIND_ON_EQUIP	= "Binds when equipped"
ITEM_BIND_ON_USE	= "Binds when used"

local gQuality = nil
function GetItemInfo (link) return "Some Item", link, gQuality end

local path = "Auctionator-Finder-Ascension/Auctionator.lua"
local chunk = loadfile (path)
if (chunk == nil) then
	print ("FAIL: could not load " .. path .. " -- run this from the repo root")
	os.exit (1)
end

local loaded, err = pcall (chunk, "Auctionator-Finder-Ascension", { zc = {} })
if (not loaded) then
	print ("FAIL: " .. path .. " would not load: " .. tostring (err))
	os.exit (1)
end

check (type (Atr_Sell_TextIsBinding) == "function", "Atr_Sell_TextIsBinding is published")

--------------------------------------------------------------------
-- THE NEGATIVES.  These are the assertions that matter.
--------------------------------------------------------------------

eq (Atr_Sell_TextIsBinding (ITEM_BIND_ON_EQUIP), false,
	"BoE must NOT read as bound -- it is most of what anyone sells")
eq (Atr_Sell_TextIsBinding (ITEM_BIND_ON_USE), false,
	"BoU must NOT read as bound -- it is tradeable until used")

eq (Atr_Sell_TextIsBinding ("Unique-Equipped"), false, "Unique-Equipped is not a bind")
eq (Atr_Sell_TextIsBinding ("Requires Level 70"), false, "a level requirement is not a bind")
eq (Atr_Sell_TextIsBinding ("Binds"), false, "the bare word is not a marker")
eq (Atr_Sell_TextIsBinding ("+24 Stamina"), false, "a stat line is not a bind")
eq (Atr_Sell_TextIsBinding ("Spellbound Tome"), false,
	"an item name merely ending in -bound does not match: the list holds whole phrases")

--------------------------------------------------------------------
-- THE POSITIVES, one per marker
--------------------------------------------------------------------

eq (Atr_Sell_TextIsBinding (ITEM_SOULBOUND), true, "Soulbound")
eq (Atr_Sell_TextIsBinding (ITEM_BIND_ON_PICKUP), true, "Binds when picked up (db item 22523)")
eq (Atr_Sell_TextIsBinding (ITEM_BIND_QUEST), true, "Quest Item")
eq (Atr_Sell_TextIsBinding (ITEM_BIND_TO_ACCOUNT), true, "Binds to account (db item 134985)")
eq (Atr_Sell_TextIsBinding (ITEM_ACCOUNTBOUND), true, "Account Bound")
eq (Atr_Sell_TextIsBinding (ITEM_BNETACCOUNTBOUND), true, "Binds to Battle.net account")
eq (Atr_Sell_TextIsBinding ("Realmbound"), true, "Realmbound -- Ascension's own, no global exists")
eq (Atr_Sell_TextIsBinding ("Realm Bound"), true, "Realm Bound -- the spaced spelling too")

--------------------------------------------------------------------
-- shape of the match: case-insensitive, anywhere in the line
--------------------------------------------------------------------

eq (Atr_Sell_TextIsBinding ("SOULBOUND"), true, "upper case still matches")
eq (Atr_Sell_TextIsBinding ("realmbound"), true, "lower case still matches")
eq (Atr_Sell_TextIsBinding ("ReAlMbOuNd"), true, "mixed case still matches")
eq (Atr_Sell_TextIsBinding ("Soulbound (1)"), true, "a trailing count does not hide the marker")
eq (Atr_Sell_TextIsBinding ("  Binds to account  "), true, "surrounding space does not hide it")

--------------------------------------------------------------------
-- nothing to read
--------------------------------------------------------------------

eq (Atr_Sell_TextIsBinding (nil), false, "nil")
eq (Atr_Sell_TextIsBinding (""), false, "empty string")
eq (Atr_Sell_TextIsBinding (42), false, "a non-string")

--------------------------------------------------------------------
-- WHY Atr_Sell_ItemIsBound SKIPS LINE 1.  The matcher cannot tell an item
-- that IS soulbound from one merely NAMED that, so the caller must not show
-- it the name line.  Asserting the matcher's side pins the reason.
--------------------------------------------------------------------

eq (Atr_Sell_TextIsBinding ("Soulbound Keepsake"), true,
	"an item NAMED Soulbound matches -- which is why the name line is never tested")

--------------------------------------------------------------------
-- Atr_Sell_ItemIsGrey: the other half of the classification, and the
-- not-cached-when-unknown rule its comment claims
--------------------------------------------------------------------

local GREY = "|cff9d9d9d|Hitem:1:0:0:0:0:0:0:0|h[Broken Fang]|h|r"
local BLUE = "|cff0070dd|Hitem:2:0:0:0:0:0:0:0|h[Good Sword]|h|r"
local COLD = "|cff0070dd|Hitem:3:0:0:0:0:0:0:0|h[Unknown Yet]|h|r"
local ZERO = "|cffffffff|Hitem:4:0:0:0:0:0:0:0|h[Odd Trash]|h|r"

eq (Atr_Sell_ItemIsGrey (nil, nil), true, "no link is not sellable")
eq (Atr_Sell_ItemIsGrey (BLUE, 3), false, "a rare with a known quality is not grey")
eq (Atr_Sell_ItemIsGrey (ZERO, 0), true, "quality 0 passed in is grey")
eq (Atr_Sell_ItemIsGrey (GREY, nil), true, "the grey colour prefix is read off the link itself")

-- Each link gets ONE answer for the whole session, which is the point of
-- keying the cache this way: quality really is a property of the item, unlike
-- boundness.  Asking again with a different quality does not change it.
eq (Atr_Sell_ItemIsGrey (BLUE, 0), false, "a link already judged keeps its answer -- the cache is per ITEM")

-- GetItemInfo cold: answer "not grey" but do NOT remember it, or one cold
-- lookup would freeze that item into the browser for the whole session.
gQuality = nil
eq (Atr_Sell_ItemIsGrey (COLD, nil), false, "a cold item cache answers 'not grey' for now")
gQuality = 0
eq (Atr_Sell_ItemIsGrey (COLD, nil), true, "...and is asked again once the client knows")

--------------------------------------------------------------------

print (string.format ("bound-scan-smoke: %d passed, %d failed", passed, failed))
if (failed > 0) then os.exit (1) end
