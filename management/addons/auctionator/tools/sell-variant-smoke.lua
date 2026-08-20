-- sell-variant-smoke.lua -- pins BACKLOG item 16.
--
-- Run from the repo root:   lua5.1 management/addons/auctionator/tools/sell-variant-smoke.lua
--
-- Why this one exists when the house rule is "ship it, tooling is a fallback":
-- the same symptom has now escaped twice.  Item 15 shipped a fix for "the sell
-- pane keeps the wrong same-name variant" and the owner saw it again -- an epic
-- Bloodforged Imperial Jewel turning blue as its own search completed.  The
-- cause is in AtrSearch:AnalyzeResultsPage's batch loop and depends on the ORDER
-- the auction house returns listings in, which is exactly the thing reasoning
-- about the code kept getting wrong.  So the orders are enumerated here instead.
--
-- It stubs only what that loop touches.  It is not a client emulator and must
-- not grow into one.

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
-- the two items: one name, two qualities.  This is the real case.
--------------------------------------------------------------------

local NAME  = "Bloodforged Imperial Jewel"
local RARE  = "|cff0070dd|Hitem:50001:0:0:0:0:0:0:0|h[" .. NAME .. "]|h|r"
local EPIC  = "|cffa335ee|Hitem:50002:0:0:0:0:0:0:0|h[" .. NAME .. "]|h|r"

local QUALITY_OF = { [RARE] = 3, [EPIC] = 4 }

--------------------------------------------------------------------
-- client + addon stubs
--------------------------------------------------------------------

local gListings          = {}		-- what the auction house "returned"
local gLinkCache         = {}		-- Atr_GetItemLink's name-keyed cache
local gCacheWrites       = 0

tinsert = table.insert

function GetItemInfo (link)
	-- name, link, quality, ilvl, minlevel, type, subtype
	return NAME, link, QUALITY_OF[link], 60, 60, "Armor", "Miscellaneous"
end

function GetNumAuctionItems ()			return #gListings, #gListings end
function GetAuctionItemLink (_, x)		return gListings[x].link end

function GetAuctionItemInfo (_, x)
	local L = gListings[x]
	-- name, texture, count, quality, canUse, level, minBid, minIncrement, buyout, bid, highBidder, owner
	return L.name, "tex", 1, QUALITY_OF[L.link], true, 60, 100, 1, L.buyout, 0, nil, "someone"
end

function Atr_AddToItemLinkCache (itemName, itemLink)
	gCacheWrites = gCacheWrites + 1
	gLinkCache[string.lower (itemName)] = itemLink
end

function Atr_GetItemLink (itemName)
	if (itemName == nil or itemName == "") then return nil end
	return gLinkCache[string.lower (itemName)]
end

function Atr_ItemType2AuctionClass ()		return 2 end
function Atr_SubType2AuctionSubclass ()		return 1 end
function Atr_AddToLowPrices ()				end
function Atr_SetMessage ()					end
function Atr_Error_Display ()				end
function ZT (s)								return s end
function Atr_NewQuery ()					return { numDupPages = 0 } end

local zc = {}
function zc.StringSame (a, b)	return string.lower (a or "") == string.lower (b or "") end
function zc.md ()				end
function zc.msg_red ()			end

--------------------------------------------------------------------
-- load the real file
--------------------------------------------------------------------

local chunk = assert (loadfile ("Auctionator-Finder-Ascension/AuctionatorScan.lua"))
chunk ("Auctionator-Finder-Ascension", { zc = zc })

--------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------

-- one sell-tab style exact search over a given listing order.
-- `sellLink` is what the sell path pushed into the scan (nil = never pushed).
-- `cachedLink` is what the name-keyed link cache held beforehand.
local function runSearch (order, sellLink, cachedLink)

	Atr_ClearScanCache ()
	gLinkCache   = {}
	gCacheWrites = 0

	if (cachedLink) then gLinkCache[string.lower (NAME)] = cachedLink end

	gListings = {}
	for i, link in ipairs (order) do
		gListings[i] = { name = NAME, link = link, buyout = 1000 * i }
	end

	local srch = Atr_NewSearch (NAME, true, 0)
	srch.current_page = 1

	-- what Atr_OnNewAuctionUpdate does right after DoSearch (item 12 part 2)
	if (sellLink) then srch.items[NAME]:UpdateItemLink (sellLink) end

	gCacheWrites = 0			-- count only what the batch loop writes
	srch:AnalyzeResultsPage ()

	return srch
end

local function bucketCount (srch)
	local n = 0
	for _ in pairs (srch.items) do n = n + 1 end
	return n
end

--------------------------------------------------------------------
-- 1 + 2.  The reported bug, both listing orders.
--
-- The sell slot holds the EPIC.  Whatever order the auction house lists the
-- two variants in, the scan the sell pane shows must stay the epic's.
--------------------------------------------------------------------

for _, case in ipairs {
	{ label = "rare listed first", order = { RARE, EPIC, RARE } },
	{ label = "epic listed first", order = { EPIC, RARE, RARE } },
} do

	local srch = runSearch (case.order, EPIC, RARE)		-- cache holds the RARE: the poisoned state
	local primary = srch.items[NAME]

	eq (primary.itemLink,      EPIC, case.label .. ": sell pane's scan keeps the epic link")
	eq (primary.itemQuality,   4,    case.label .. ": ... and the epic quality")
	eq (primary.variantQuality, 4,   case.label .. ": ... and buckets as the epic")
	eq (#primary.scanData,     1,    case.label .. ": epic bucket holds only the epic listing")

	local variant = srch.items[NAME .. "#q3"]
	check (variant ~= nil, case.label .. ": the rares got their own bucket")
	if (variant) then
		eq (variant.itemLink,    RARE, case.label .. ": rare bucket describes the rare")
		eq (variant.itemQuality, 3,    case.label .. ": ... with the rare's quality")
		eq (#variant.scanData,   2,    case.label .. ": ... and holds both rare listings")
	end

	eq (bucketCount (srch), 2, case.label .. ": exactly two buckets")
end

--------------------------------------------------------------------
-- 3.  No sell-side push (a browse search).  The scan only knows what the
--     name cache held, so THAT is the primary bucket -- and the other variant's
--     bucket must still end up describing its own variant, not the cached one.
--------------------------------------------------------------------

local srch = runSearch ({ RARE, EPIC }, nil, RARE)
eq (srch.items[NAME].itemLink,           RARE, "browse: primary bucket is the cached variant")
eq (srch.items[NAME].variantQuality,     3,    "browse: ... bucketed by its own quality")
eq (srch.items[NAME .. "#q4"].itemLink,  EPIC, "browse: variant bucket takes the epic's link")
eq (srch.items[NAME .. "#q4"].itemQuality, 4,  "browse: ... and the epic's quality")

--------------------------------------------------------------------
-- 4.  Nothing known about the item at all: fall back to the first listing,
--     which is what this did before the fix and is all a cold cache can offer.
--------------------------------------------------------------------

srch = runSearch ({ RARE, EPIC }, nil, nil)
eq (srch.items[NAME].itemLink,       RARE, "cold cache: primary adopts the first listing's link")
eq (srch.items[NAME].variantQuality, 3,    "cold cache: ... and its quality")
eq (bucketCount (srch), 2,                 "cold cache: the epic still splits off")

--------------------------------------------------------------------
-- 5.  The correction is self-limiting.  The old always-true condition rewrote
--     the scan's identity -- and the shared name-keyed link cache -- once per
--     listing, which is how a late rare could recolour an epic mid-search.
--------------------------------------------------------------------

srch = runSearch ({ RARE, EPIC, RARE, EPIC, RARE, EPIC }, EPIC, RARE)
check (gCacheWrites <= 2, string.format (
	"batch loop writes the link cache at most once per bucket -- got %d writes for 6 listings", gCacheWrites))
eq (srch.items[NAME].itemLink, EPIC, "six mixed listings later, the sell pane's scan is still the epic")

--------------------------------------------------------------------

print (string.format ("%d passed, %d failed", passed, failed))
os.exit (failed == 0 and 0 or 1)
