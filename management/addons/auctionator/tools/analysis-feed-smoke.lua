-- analysis-feed-smoke.lua -- pins BACKLOG item 17's feed.
--
-- Run from the repo root:  lua5.1 management/addons/auctionator/tools/analysis-feed-smoke.lua
--
-- The Analysis tab counts a listing that VANISHED between two scans as sold. That
-- makes an incomplete scan actively dangerous: every listing on a page that was
-- never fetched looks bought, and the mistake lands in a saved database where it
-- is indistinguishable from a real sale afterwards. The guards that prevent it
-- are cheap to write and impossible to see in game -- the numbers would just be
-- wrong -- so they are asserted here.
--
-- Stubs only what the batch loop and the observer touch. Not a client emulator.

local passed, failed = 0, 0

local function check (ok, what)
	if (ok) then passed = passed + 1 else failed = failed + 1; print ("FAIL: " .. what) end
end

local function eq (got, want, what)
	check (got == want, string.format ("%s -- got %s, wanted %s", what, tostring (got), tostring (want)))
end

--------------------------------------------------------------------
-- stubs
--------------------------------------------------------------------

local WATCHED   = "Thorium Ore"
local IGNORED   = "Copper Ore"
local LINK_OF   = { [WATCHED] = "|cffffffff|Hitem:10620|h["..WATCHED.."]|h|r",
                    [IGNORED] = "|cffffffff|Hitem:2770|h["..IGNORED.."]|h|r" }

local gNow      = 1000000
local gListings = {}

tinsert  = table.insert
tremove  = table.remove
time     = function () return gNow end

function GetItemInfo (link)			return "x", link, 1, 60, 60, "Trade Goods", "Metal & Stone" end
function GetNumAuctionItems ()		return #gListings, #gListings end
function GetAuctionItemLink (_, x)	return LINK_OF[gListings[x].name] end
function GetAuctionItemTimeLeft (_, x)	return gListings[x].tl end

function GetAuctionItemInfo (_, x)
	local L = gListings[x]
	return L.name, "tex", L.count or 1, 1, true, 60, 100, 1, L.buyout, 0, nil, L.owner
end

function Atr_AddToItemLinkCache ()			end
function Atr_GetItemLink (n)				return LINK_OF[n] end
function Atr_ItemType2AuctionClass ()		return 0 end
function Atr_SubType2AuctionSubclass ()		return 0 end
function Atr_AddToLowPrices ()				end
function Atr_SetMessage ()					end
function Atr_Error_Display ()				end
function ZT (s)								return s end
function Atr_NewQuery ()					return { numDupPages = 0 } end
function CanSendAuctionQuery ()				return false end		-- keep Continue() inert

local zc = {}
function zc.StringSame (a, b)	return string.lower (a or "") == string.lower (b or "") end
function zc.md ()				end
function zc.msg_red ()			end
function zc.msg_atr ()			end
function zc.round (n)			return math.floor ((n or 0) + 0.5) end

--------------------------------------------------------------------
-- load the real files
--------------------------------------------------------------------

local function load_addon_file (path)
	local chunk = assert (loadfile (path))
	return chunk ("Auctionator-Finder-Ascension", { zc = zc })
end

load_addon_file ("Auctionator-Finder-Ascension/AuctionatorAnalysis.lua")
load_addon_file ("Auctionator-Finder-Ascension/AuctionatorScan.lua")

--------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------

-- Finish() does the whole price-database pass after handing the listings over,
-- and that pass needs a great deal more of the addon than this stubs. The
-- analysis call is the FIRST thing in it, so pcall is enough to exercise the
-- real wiring -- and if that call ever stops being reached, these assertions
-- fail, which is the point of running Finish rather than the observer directly.
local function finish (srch)
	pcall (function () srch:Finish() end)
end

local function scan (listings, opts)

	opts = opts or {}

	gListings = listings

	AUCTIONATOR_ANALYSIS = AUCTIONATOR_ANALYSIS		-- keep the DB across scans

	local srch = Atr_NewSearch (opts.searchText or WATCHED, opts.exact ~= false, 0)
	srch.current_page = 1

	srch:AnalyzeResultsPage ()

	if (opts.levelFiltered) then srch.anLevelFiltered = true end

	finish (srch)

	return srch
end

local function obs (name)	return Atr_An_DB().obs[name] end

local function reset ()
	AUCTIONATOR_ANALYSIS = nil
	Atr_ClearScanCache ()
	Atr_An_Watch (WATCHED)
end

--------------------------------------------------------------------
-- 1.  A complete search feeds the watched item, and only it.
--------------------------------------------------------------------

reset ()

scan {
	{ name = WATCHED, owner = "alice", count = 20, buyout = 10000, tl = 3 },
	{ name = WATCHED, owner = "bob",   count = 20, buyout = 12000, tl = 3 },
	{ name = IGNORED, owner = "carol", count = 20, buyout =   500, tl = 3 },
}

local o = obs (WATCHED)
check (o ~= nil, "a complete search records the watched item")
eq (o and o.scans,    1,   "... as one scan")
eq (o and o.listings, 2,   "... with both of its listings")
eq (o and o.sellers,  2,   "... and both sellers")
eq (o and o.low,      500, "... priced per unit")
eq (o and o.units,     40, "... and the UNITS in them, not just the listing count")
eq (obs (IGNORED), nil,    "an unwatched item in the same batch is not recorded")

-- BACKLOG item 29, rule 3: the reagent view compares supply against a Need
-- counted in units, so "66 listings" is not an answer -- it could be 66 items or
-- 1,300. The stack size was already being read here to work out the unit price
-- and then discarded; this pins it being kept. A record written before it was
-- must report units as UNKNOWN rather than as none, or every unrescanned
-- watchlist item reads as an empty market.
local stats = Atr_An_Stats (WATCHED)
eq (stats and stats.units,    40, "the tab reads the unit count off the record")
eq (stats and stats.listings,  2, "... beside the listing count, which still means listings")

obs (WATCHED).units = nil			-- as a pre-item-29 record looks
eq (Atr_An_Stats (WATCHED).units, nil, "a record from before units were counted reports nil, not 0")
obs (WATCHED).units = 40

--------------------------------------------------------------------
-- 2.  Sold vs expired, which is the whole point of the time-left buckets.
--------------------------------------------------------------------

-- bob's listing was on "Long" (min 2h left) and is gone 30 minutes later: it
-- cannot have expired.
gNow = gNow + 1800
scan {
	{ name = WATCHED, owner = "alice", count = 20, buyout = 10000, tl = 3 },
}

o = obs (WATCHED)
eq (o and o.sold, 1, "a listing that could not yet have expired counts as SOLD")
eq (o and o.amb,  0, "... and not as ambiguous")

-- alice's is on "Short" (min 0) and gone: unknowable, so it must not be a sale.
gNow = gNow + 1800
scan {
	{ name = WATCHED, owner = "dave", count = 5, buyout = 3000, tl = 1 },
}
-- (alice was last seen on tl 3 -> min 2h; 30m gap, so this one IS attributable)
o = obs (WATCHED)
eq (o and o.sold, 2, "... a second attributable disappearance is also a sale")

gNow = gNow + 7200			-- two hours: dave's Short listing could have expired
scan {
	{ name = WATCHED, owner = "erin", count = 5, buyout = 3000, tl = 4 },
}
o = obs (WATCHED)
eq (o and o.sold, 2, "a disappearance that could be an expiry adds no sale")
eq (o and o.amb,  1, "... it is counted as ambiguous instead")

--------------------------------------------------------------------
-- 3.  THE DANGEROUS CASE: an incomplete scan must observe nothing.
--     A full page (50) means more pages are coming; the listings on them are
--     not missing, they are unfetched.
--------------------------------------------------------------------

reset ()

local full = {}
for i = 1, 50 do
	full[i] = { name = WATCHED, owner = "seller"..i, count = 1, buyout = 100 * i, tl = 3 }
end

scan (full)
eq (obs (WATCHED), nil, "a full page (more to come) is never observed")

--------------------------------------------------------------------
-- 4.  A level-filtered query returns a subset of an item's listings.
--------------------------------------------------------------------

reset ()

scan ({ { name = WATCHED, owner = "alice", count = 1, buyout = 100, tl = 3 } },
	  { levelFiltered = true })
eq (obs (WATCHED), nil, "a level-filtered search is never observed")

--------------------------------------------------------------------
-- 5.  The bank is consumed exactly once: a second Finish cannot re-observe
--     the same snapshot and invent a scan interval out of nothing.
--------------------------------------------------------------------

reset ()

local srch = scan { { name = WATCHED, owner = "alice", count = 1, buyout = 100, tl = 3 } }
eq (obs (WATCHED).scans, 1, "one search, one scan")

gNow = gNow + 3600
finish (srch)
eq (obs (WATCHED).scans, 1, "finishing the same search again observes nothing")

--------------------------------------------------------------------
-- 6.  Unwatched items cost nothing: nothing is banked for them at all.
--------------------------------------------------------------------

reset ()
Atr_An_Unwatch (WATCHED)

srch = scan { { name = WATCHED, owner = "alice", count = 1, buyout = 100, tl = 3 } }
eq (srch.anListings, nil, "nothing is banked when nothing is watched")
eq (obs (WATCHED), nil,   "... and nothing is recorded")

--------------------------------------------------------------------
-- 7.  The item menu's CONTENTS (BACKLOG item 21).
--
--     The menu's frame cannot be tested here, but what goes ON it is now a pure
--     function -- which is half the point of dropping the Blizzard dropdown.
--     Atr_Shop_UserLists is not loaded in this harness, so the list section
--     takes its no-lists path, which is also the path a new player sees.
--------------------------------------------------------------------

reset ()
Atr_An_AddGroup ("Cloth")
Atr_An_AddGroup ("Ore")

local function texts (entries)
	local out = {}
	for i = 1, #entries do out[i] = entries[i].text end
	return table.concat (out, " | ")
end

local function findEntry (entries, text)
	for i = 1, #entries do if (entries[i].text == text) then return entries[i] end end
	return nil
end

local groups = Atr_An_MenuEntries (WATCHED, "groups")
eq (texts (groups), "(no group) | Cloth | Ore | New group...", "groups mode lists every group")

local lists = Atr_An_MenuEntries (WATCHED, "lists")
eq (texts (lists), "no lists yet | New list...", "lists mode still offers a way in with no lists")
eq (findEntry (lists, "no lists yet").disabled, true, "... and says so as a disabled line")

local both = Atr_An_MenuEntries (WATCHED, "both")
eq (findEntry (both, "Shopping list").header, true,  "both mode heads the shopping section")
eq (findEntry (both, "Analysis group").header, true, "both mode heads the group section")
eq (#both, #groups + #lists + 2, "both mode is the two sections plus their headers")

eq (#Atr_An_MenuEntries (nil, "both"), 0, "no item, no menu")

-- the entries DO something: picking a group watches the item in it
Atr_An_Unwatch (WATCHED)
findEntry (groups, "Cloth").func ()
eq (Atr_An_IsWatched (WATCHED), true, "picking a group watches the item")
eq (Atr_An_DB().watch[WATCHED].group, "Cloth", "... in that group")

-- and picking another MOVES it rather than refusing
findEntry (groups, "Ore").func ()
eq (Atr_An_DB().watch[WATCHED].group, "Ore", "picking a second group moves it")

--------------------------------------------------------------------
-- DELETING A GROUP (owner, 2026-08-20).  Pinned rather than reasoned for one
-- reason: it is the only destructive operation on this tab's saved data, and
-- the rule it has to keep -- a group is a label, deleting it must not delete
-- what it labels -- is invisible from the call site.  A watched item carries
-- observation history that scanning rebuilt over days; taking a dozen of them
-- out with one click on a red x is not recoverable.
--------------------------------------------------------------------

reset ()
Atr_An_AddGroup ("Cloth")
Atr_An_AddGroup ("Ore")

Atr_An_Watch ("Linen Cloth", "Cloth")
Atr_An_Watch ("Wool Cloth",  "Cloth")
Atr_An_Watch ("Copper Ore",  "Ore")

eq (Atr_An_GroupCount ("Cloth"), 2, "the count is taken before anything is deleted")
eq (Atr_An_GroupCount ("Ore"),   1, "... per group")
eq (Atr_An_GroupCount ("Nope"),  0, "... and a group nobody has is empty, not an error")

local menu = Atr_An_GroupMenuEntries ()
eq (texts (menu), "All groups | Cloth | Ore", "the group menu lists every group under All groups")
eq (findEntry (menu, "All groups").xfunc, nil, "All groups has no delete: it is not a group")
check (findEntry (menu, "Cloth").xfunc ~= nil, "every real group has one")

eq (Atr_An_DeleteGroup ("Cloth"), 2, "deleting reports how many items it unfiled")

eq (Atr_An_GroupCount ("Cloth"), 0, "the group is gone")
eq (#Atr_An_DB().groups, 1, "... and off the list")
eq (Atr_An_DB().groups[1], "Ore", "... leaving the others alone")

-- THE RULE. Both items are still watched, just unlabelled.
eq (Atr_An_IsWatched ("Linen Cloth"), true, "an item in a deleted group is STILL WATCHED")
eq (Atr_An_IsWatched ("Wool Cloth"),  true, "... all of them")
eq (Atr_An_DB().watch["Linen Cloth"].group, nil, "... and simply loses the label")
eq (Atr_An_DB().watch["Wool Cloth"].group,  nil, "... all of them")

-- Nothing outside the group is touched.
eq (Atr_An_DB().watch["Copper Ore"].group, "Ore", "another group's items are untouched")

eq (Atr_An_DeleteGroup ("Cloth"), nil, "deleting a group twice reports nothing to do")
eq (Atr_An_DeleteGroup (nil),     nil, "no name, nothing to do")
eq (Atr_An_DeleteGroup (""),      nil, "empty name, nothing to do")

-- An empty group deletes as 0 unfiled, which is not the same answer as "no such
-- group" -- the caller has to be able to tell them apart.
Atr_An_AddGroup ("Empty")
eq (Atr_An_DeleteGroup ("Empty"), 0, "an empty group deletes, reporting 0 unfiled")

eq (texts (Atr_An_GroupMenuEntries ()), "All groups | Ore", "the menu follows the deletions")

reset ()
eq (texts (Atr_An_GroupMenuEntries ()), "All groups | no groups yet", "with no groups it says so")
eq (findEntry (Atr_An_GroupMenuEntries (), "no groups yet").disabled, true, "... as a disabled line")

--------------------------------------------------------------------

print (string.format ("%d passed, %d failed", passed, failed))
os.exit (failed == 0 and 0 or 1)
