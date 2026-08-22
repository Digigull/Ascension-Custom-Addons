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

-- These are the values a REAL /atrbound dump from the owner's client printed
-- back (2026-08-23), not the stock ones.  Ascension redefines two of them and
-- ships ITEM_BNETACCOUNTBOUND not at all:
--
--     ITEM_BIND_TO_ACCOUNT  =  "Binds to realm"   (stock: "Binds to account")
--     ITEM_ACCOUNTBOUND     =  "Realm Bound"      (stock: "Account Bound")
--
-- Using the real ones here is the point: a test against the stock strings would
-- pass while the addon failed on the only realm it runs on.
ITEM_SOULBOUND			= "Soulbound"
ITEM_BIND_ON_PICKUP		= "Binds when picked up"
ITEM_BIND_QUEST			= "Quest Item"
ITEM_BIND_TO_ACCOUNT	= "Binds to realm"
ITEM_ACCOUNTBOUND		= "Realm Bound"
ITEM_BNETACCOUNTBOUND	= nil

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

-- THE FLAVOUR-TEXT CASE, verbatim from the dump.  Item [2:6] "Personal Bank"
-- was bound anyway (line 2 said "Realm Bound"), so the verdict was right by
-- luck -- but the identical sentence on a tradeable item would have hidden it.
-- A marker has to START the line now, which is what makes this false.
eq (Atr_Sell_TextIsBinding (
	'"Gives you access to your Guild Sized Bank with purchaseable tabs. You can put soulbound items into bank."'),
	false, "flavour text that merely MENTIONS soulbound is not a binding line")

eq (Atr_Sell_TextIsBinding ("Use: Summons your realm bank. (10 Min Cooldown)"), false,
	"a Use: line naming the realm bank is not a binding line")
eq (Atr_Sell_TextIsBinding ("Requires Soulbound Attunement"), false,
	"a requirement mentioning a marker is not a binding line")

--------------------------------------------------------------------
-- THE POSITIVES, one per marker
--------------------------------------------------------------------

eq (Atr_Sell_TextIsBinding (ITEM_SOULBOUND), true, "Soulbound")
eq (Atr_Sell_TextIsBinding (ITEM_BIND_ON_PICKUP), true, "Binds when picked up (db item 22523)")
eq (Atr_Sell_TextIsBinding (ITEM_BIND_QUEST), true, "Quest Item")
eq (Atr_Sell_TextIsBinding (ITEM_BIND_TO_ACCOUNT), true, "Binds to realm -- Ascension's ITEM_BIND_TO_ACCOUNT")
eq (Atr_Sell_TextIsBinding (ITEM_ACCOUNTBOUND), true, "Realm Bound -- Ascension's ITEM_ACCOUNTBOUND")
eq (Atr_Sell_TextIsBinding ("Realmbound"), true, "Realmbound -- the unspaced spelling, which no global carries")
eq (Atr_Sell_TextIsBinding ("Binds to account"), false,
	"the STOCK account wording is not on this realm's list, and must not be assumed onto it")

-- Straight out of the dump: the three bind lines it actually produced across
-- 99 bag items.  If any of these stops matching, items go on sale that cannot.
eq (Atr_Sell_TextIsBinding ("Soulbound"), true, "dump: 21 items")
eq (Atr_Sell_TextIsBinding ("Realm Bound"), true, "dump: 5 items (scourgestones, realm/personal bank)")
eq (Atr_Sell_TextIsBinding ("Quest Item"), true, "dump: 3 items")

--------------------------------------------------------------------
-- shape of the match: case-insensitive, anywhere in the line
--------------------------------------------------------------------

eq (Atr_Sell_TextIsBinding ("SOULBOUND"), true, "upper case still matches")
eq (Atr_Sell_TextIsBinding ("realmbound"), true, "lower case still matches")
eq (Atr_Sell_TextIsBinding ("ReAlMbOuNd"), true, "mixed case still matches")
eq (Atr_Sell_TextIsBinding ("Soulbound (1)"), true, "a trailing suffix does not hide the marker")
eq (Atr_Sell_TextIsBinding ("  Realm Bound  "), true, "surrounding space does not hide it")

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
	"an item NAMED Soulbound still matches -- which is why the name line is never tested")

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
-- The SECOND source: Atr_Sell_ItemDefIsBound.
--
-- Worth the ~30 lines of tooltip stub below, and only these: this function
-- caches BY LINK, and every bug this file has ever had came from caching a
-- bind verdict by link.  It is allowed to here -- "does this item bind on
-- pickup" really is a property of the item -- and the rule that makes it safe
-- is the one asserted last: never remember an answer read off a tooltip that
-- had not arrived.
--------------------------------------------------------------------

RETRIEVING_ITEM_INFO = "Retrieving item information"

local gBagTip, gDefTip = {}, {}		-- [key] = { {left, right}, ... }

local function setLines (lines)
	for i = 1, 30 do
		local row = lines[i]
		_G["AtrScanningTooltipTextLeft"..i]  = { GetText = function () return row and row[1] or nil end }
		_G["AtrScanningTooltipTextRight"..i] = { GetText = function () return row and row[2] or nil end }
	end
	AtrScanningTooltip.n = #lines
end

AtrScanningTooltip = {
	n = 0,
	ClearLines   = function (self) end,
	NumLines     = function (self) return self.n end,
	SetBagItem   = function (self, bag, slot) setLines (gBagTip[bag .. ":" .. slot] or {}) end,
	SetHyperlink = function (self, link) setLines (gDefTip[link] or {}) end,
}

local BOP  = "|cff1eff00|Hitem:22523:0:0:0:0:0:0:0|h[Insignia of the Dawn]|h|r"
local BOE  = "|cff0070dd|Hitem:9001:0:0:0:0:0:0:0|h[Frostwoven Staff]|h|r"
local PLN  = "|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"
local COLD2 = "|cffffffff|Hitem:9002:0:0:0:0:0:0:0|h[Not Loaded Yet]|h|r"

-- The reported case, exactly as the dump shows it: the SLOT tooltip is the name
-- and nothing else, while the ITEM's own tooltip carries the bind line.
gBagTip["0:6"] = { { "Insignia of the Dawn" } }
gDefTip[BOP]   = { { "Insignia of the Dawn" }, { "Binds when picked up" } }

gBagTip["0:10"] = { { "Frostwoven Staff" }, { "Binds when equipped" }, { "Two-Hand", "Staff" } }
gDefTip[BOE]    = { { "Frostwoven Staff" }, { "Binds when equipped" }, { "Two-Hand", "Staff" } }

gBagTip["0:2"] = { { "Linen Cloth" } }
gDefTip[PLN]   = { { "Linen Cloth" } }

eq (Atr_Sell_ItemDefIsBound (BOP), true,  "the item's own tooltip says bind-on-pickup (db item 22523)")
eq (Atr_Sell_ItemDefIsBound (BOE), false, "bind-on-equip is NOT bound -- the whole safety property again")
eq (Atr_Sell_ItemDefIsBound (PLN), false, "a plain trade good is not bound")
eq (Atr_Sell_ItemDefIsBound (nil), false, "no link")

-- and through the real entry point: the slot says nothing, the item does
eq (Atr_Sell_ItemIsBound (0, 6, BOP), true,
	"Atr_Sell_ItemIsBound falls through to the item when the slot tooltip is silent")
eq (Atr_Sell_ItemIsBound (0, 10, BOE), false, "a BoE in a bag stays sellable")
eq (Atr_Sell_ItemIsBound (0, 2, PLN), false, "a plain trade good stays sellable")

-- the slot still wins when it has something to say
gBagTip["1:4"] = { { "Ectoplasmic Resonator" }, { "Soulbound" } }
gDefTip["x"]   = {}
eq (Atr_Sell_ItemIsBound (1, 4, "x"), true, "a bound copy is caught by the slot scan, as before")

-- THE CACHING RULE.  A tooltip that has not arrived must answer "not bound"
-- and must NOT be remembered, or the item stays sellable until a /reload.
gDefTip[COLD2] = { { RETRIEVING_ITEM_INFO } }
eq (Atr_Sell_ItemDefIsBound (COLD2), false, "an unarrived tooltip answers 'not bound' for now")

gDefTip[COLD2] = { { "Now Loaded" }, { "Binds when picked up" } }
eq (Atr_Sell_ItemDefIsBound (COLD2), true,  "...and is asked again once it arrives -- not cached")

-- a real answer, on the other hand, IS remembered
gDefTip[BOP] = { { "Insignia of the Dawn" } }		-- pull the line back out
eq (Atr_Sell_ItemDefIsBound (BOP), true, "a real verdict is cached: this is a property of the ITEM")

--------------------------------------------------------------------

print (string.format ("bound-scan-smoke: %d passed, %d failed", passed, failed))
if (failed > 0) then os.exit (1) end
