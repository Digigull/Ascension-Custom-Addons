-- price-variant-smoke.lua -- pins BACKLOG item 4, the read half.
--
-- Run from the repo root:   lua5.1 management/addons/auctionator/tools/price-variant-smoke.lua
--
-- Why this one exists when the house rule is "ship it, tooling is a fallback":
-- the symptom -- "I search an item on the Buy tab and its tooltip price does not
-- change" -- survived a whole investigation.  That investigation proved the
-- WRITE happens (it does, on every Buy and Sell search) and closed the item, and
-- the bug was in the READ the entire time: Atr_PriceStore files a targeted
-- search's price under the listing's variant key, while ShowTipWithPricing asked
-- Atr_GetAuctionPrice by NAME, which answers the name-level "?" slot that only a
-- full scan writes.  Both halves were individually correct, which is exactly why
-- reading either one alone kept exonerating it.
--
-- The trap is that the bug is invisible on an item the database has never seen
-- (no "?" slot, so the name-only answer falls through to the variant) and only
-- appears on one it already knows -- i.e. on almost everything, for anyone with
-- a full scan behind them, but on nothing in a fresh test.  So that asymmetry is
-- what this file pins.
--
-- It stubs the five globals AuctionatorHints.lua touches while loading and
-- nothing else.  It is not a client emulator and must not grow into one.

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
-- client stubs: only what the file reaches for as it loads
--------------------------------------------------------------------

local function frame ()
	return setmetatable ({}, { __index = function () return function () return nil end end })
end

CreateFrame     = function () return frame () end
GameTooltip     = frame ()
ItemRefTooltip  = frame ()
SlashCmdList    = {}
hooksecurefunc  = function () end
tinsert         = table.insert
ITEM_LEVEL      = "Item Level %d"
ITEM_MIN_LEVEL  = "Requires Level %d"

-- ------------------------------------------------------------------ the file

local chunk = assert (loadfile ("Auctionator-Finder-Ascension/AuctionatorHints.lua"))
chunk ("Auctionator", {})

-- ------------------------------------------------------------------- the run

check (type (Atr_VariantKey) == "function", "Atr_VariantKey loaded")
check (type (Atr_PriceStore) == "function", "Atr_PriceStore loaded")
check (type (Atr_PriceValue) == "function", "Atr_PriceValue loaded")

-- The key a tooltip and a listing both derive from the same item.
local LINK = "|cffffffff|Hitem:1206:0:0:0:0:0:0:0|h[Moss Agate]|h|r"
local VKEY = Atr_VariantKey (LINK)

eq (VKEY, "1206:0", "variant key is itemId:suffixId")
eq (Atr_VariantKey ("item:1206"), "1206:0", "bare item string keys with suffix 0")
eq (Atr_VariantKey (nil), nil, "no link, no key")

-- A suffixed item keeps its suffix: the other variant axis must stay separate.
eq (Atr_VariantKey ("|Hitem:7909:0:0:0:0:0:1783:0|h"), "7909:1783", "random suffix survives")

--------------------------------------------------------------------
-- THE REPORTED CASE: an item the database already knew.
--------------------------------------------------------------------

local db = {}
db["Moss Agate"] = 17000                            -- what a full scan left behind
Atr_PriceStore (db, "Moss Agate", 9500, VKEY)       -- what a Buy-tab search found

local row = db["Moss Agate"]

check (type (row) == "table", "a variant write promotes the bare number to a row")
eq (row[ATR_PV_ANY], 17000, "the full scan's price moves into the name-level slot")
eq (row[VKEY],        9500, "the search's price lands in its own variant slot")

-- This pair IS the bug.  Both lines were true in the shipped addon and the
-- tooltip read the first one.
eq (Atr_PriceValue (row),       17000, "name-only read still answers the STALE full-scan price")
eq (Atr_PriceValue (row, VKEY),  9500, "variant-keyed read answers what the search just found")

--------------------------------------------------------------------
-- ...and why it never showed up in a quick test: an unknown item works
-- either way, so a fresh name exonerates the code.
--------------------------------------------------------------------

local fresh = {}
Atr_PriceStore (fresh, "Newthing", 9500, VKEY)

eq (Atr_PriceValue (fresh["Newthing"]),       9500, "unseen item: name-only read is already correct")
eq (Atr_PriceValue (fresh["Newthing"], VKEY), 9500, "unseen item: variant read agrees")

--------------------------------------------------------------------
-- The fix must not cost anything on rows that predate variants.
--------------------------------------------------------------------

local legacy = { ["Copper Bar"] = 4200 }

eq (Atr_PriceValue (legacy["Copper Bar"]),       4200, "legacy bare number reads back")
eq (Atr_PriceValue (legacy["Copper Bar"], VKEY), 4200, "asking a bare number for a variant is harmless")

-- A name-level write on a row with no variants stays a bare number.
Atr_PriceStore (legacy, "Copper Bar", 4400)
eq (legacy["Copper Bar"], 4400, "name-only write leaves the row a plain number")

-- A variant slot the row does not have falls back to the name's default rather
-- than to nothing -- this is what keeps the tooltip fix from LOSING a price.
local partial = {}
Atr_PriceStore (partial, "Thing", 5000)             -- full scan only, no variants
eq (Atr_PriceValue (partial["Thing"], "999:0"), 5000, "unknown variant falls back to the name's price")

--------------------------------------------------------------------
-- The invariant the store was built to protect, re-checked: a dear variant
-- must never raise the name-only answer.  (Large Fang, from live data.)
--------------------------------------------------------------------

local fang = { ["Large Fang"] = 11000 }
Atr_PriceStore (fang, "Large Fang", 9900, "5637:0")

eq (Atr_PriceValue (fang["Large Fang"]), 11000, "name-level slot still wins over a cheaper variant")

Atr_PriceStore (fang, "Large Fang", 24000, "5637:99")
eq (Atr_PriceValue (fang["Large Fang"]), 11000, "...and over a dearer one")

--------------------------------------------------------------------

print (string.format ("%d passed, %d failed", passed, failed))
if (failed > 0) then os.exit (1) end
