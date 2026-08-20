-- history-store-smoke.lua -- pins BACKLOG item 31's packed series.
--
-- Run from the repo root:  lua5.1 management/addons/auctionator/tools/history-store-smoke.lua
--
-- WHY THIS ONE EXISTS when the house rule says not to build harnesses. Two
-- reasons, both specific:
--
--   1. The append path is STRING SURGERY with index arithmetic -- it rewrites the
--      tail of a packed string in place to keep the write O(1) per name per scan.
--      That is the one thing in this feature that cannot be read and trusted.
--   2. A bad append is SILENT AND PERMANENT. A wrong current price is overwritten
--      by the next scan; a corrupted series is read back wrong forever, and the
--      whole point of the store is that later features believe it.
--
-- Stubs only what the store touches, which is almost nothing -- the file is
-- deliberately free of CreateFrame at load. Not a client emulator.

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

local DAY0  = 1217548800			-- 2008-08-01, the epoch the store packs against
local gNow  = DAY0 + (6600 * 86400)	-- an ordinary day, four digits

tinsert = table.insert
tremove = table.remove
time    = function () return gNow end

local gRealm = "Areanoss"

function GetRealmName ()			return gRealm end
function UnitFactionGroup ()		return "Alliance" end
function ZT (s)						return s end

local zc = {}
function zc.msg_atr ()				end
function zc.priceToMoneyString (c)	return tostring (c) end

local function load_store ()
	local chunk = assert (loadfile ("Auctionator-Finder-Ascension/AuctionatorHistory.lua"))
	return chunk ("Auctionator-Finder-Ascension", { zc = zc })
end

local function day (n)  return DAY0 + (n * 86400) end

load_store ()

local function packed (name)
	local db = Atr_Hist_DB ()
	return db and db.p[name] or nil
end

--------------------------------------------------------------------
-- 1.  Off by default, and off means nothing is written at all.
--------------------------------------------------------------------

AUCTIONATOR_MARKET_HISTORY_LOADED = true
AUCTIONATOR_FINDER_SETTINGS       = {}

eq (Atr_Hist_Enabled (), false,          "the feature is OFF with no setting saved")
eq (Atr_Hist_Note ("Copper Ore", 1200), false, "... and records nothing")
eq (AUCTIONATOR_MARKET_HISTORY, nil,     "... not even the table -- an unused install writes an empty file")

--------------------------------------------------------------------
-- 2.  On, but the companion addon is missing: still nothing, and no error.
--     This is the state somebody lands in by updating one folder and not both.
--------------------------------------------------------------------

AUCTIONATOR_MARKET_HISTORY_LOADED = nil
Atr_Hist_SetEnabled (true)

eq (Atr_Hist_Available (), false,        "no companion addon means not available")
eq (Atr_Hist_Enabled (), false,          "... so the feature is off however the setting reads")
eq (Atr_Hist_Note ("Copper Ore", 1200), false, "... and records nothing")
eq (Atr_Hist_DB (), nil,                 "... and hands out no database")

--------------------------------------------------------------------
-- 3.  On, with the companion: the first sample, and the round trip.
--------------------------------------------------------------------

AUCTIONATOR_MARKET_HISTORY_LOADED = true

gNow = day (6600)
eq (Atr_Hist_Note ("Copper Ore", 1200), true, "the first sample is recorded")
eq (packed ("Copper Ore"), "6600:1200",       "... as one packed record, n omitted at 1")

local s = Atr_Hist_Series ("Copper Ore")
eq (#s, 1,        "one entry decodes back")
eq (s[1].d, 6600, "... same day")
eq (s[1].p, 1200, "... same price")
eq (s[1].n, 1,    "... one scan behind it")
eq (s[1].age, 0,  "... aged today")

--------------------------------------------------------------------
-- 4.  A second scan the SAME day is a close, not a second entry.
--------------------------------------------------------------------

gNow = day (6600) + 3600
Atr_Hist_Note ("Copper Ore", 1500)

eq (packed ("Copper Ore"), "6600:1500:2", "the same day keeps ONE record: newest price wins, n counts the scans")
eq (#Atr_Hist_Series ("Copper Ore"), 1,   "... still one entry")

Atr_Hist_Note ("Copper Ore", 1400)
eq (packed ("Copper Ore"), "6600:1400:3", "... and again")

--------------------------------------------------------------------
-- 5.  The next day appends. This is the tail-rewrite path, in both branches.
--------------------------------------------------------------------

gNow = day (6601)
Atr_Hist_Note ("Copper Ore", 900)
eq (packed ("Copper Ore"), "6600:1400:3;6601:900", "a new day appends rather than replacing")

gNow = day (6602)
Atr_Hist_Note ("Copper Ore", 950)
Atr_Hist_Note ("Copper Ore", 980)
eq (packed ("Copper Ore"), "6600:1400:3;6601:900;6602:980:2",
	"appending after a multi-scan day, then closing the new one, both land right")

s = Atr_Hist_Series ("Copper Ore")
eq (#s, 3,        "three days decode")
eq (s[1].p, 1400, "... oldest first")
eq (s[3].p, 980,  "... newest last")
eq (s[1].age, 2,  "... and age counts back from today")

--------------------------------------------------------------------
-- 6.  A clock that goes backwards is refused, not appended out of order.
--------------------------------------------------------------------

local before = packed ("Copper Ore")
gNow = day (6599)
eq (Atr_Hist_Note ("Copper Ore", 111), false, "a sample older than the newest one is refused")
eq (packed ("Copper Ore"), before,            "... and the series is untouched")

--------------------------------------------------------------------
-- 7.  Nothing worthless gets in.
--------------------------------------------------------------------

gNow = day (6603)
eq (Atr_Hist_Note ("Copper Ore", 0), false,    "a zero price is not a price")
eq (Atr_Hist_Note ("Copper Ore", -5), false,   "nor is a negative one")
eq (Atr_Hist_Note ("", 100), false,            "nor is an empty name an item")
eq (Atr_Hist_Note (nil, 100), false,           "nor is no name at all")
eq (packed ("Copper Ore"), before,             "... and none of them touched the series")

--------------------------------------------------------------------
-- 8.  Retention: 30 days of dailies, oldest dropped, newest always kept.
--------------------------------------------------------------------

local i
for i = 6604, 6700 do
	gNow = day (i)
	Atr_Hist_Note ("Thorium Ore", 100 + i)
end

s = Atr_Hist_Series ("Thorium Ore")
check (#s <= 40,  "the series is capped -- got " .. #s)
check (#s >= 30,  "... and keeps the retention window -- got " .. #s)
eq (s[#s].d, 6700,       "the newest day survives trimming")
eq (s[#s].p, 100 + 6700, "... with its price")
check (s[1].d > 6604,    "the oldest days were dropped")
check (s[1].d >= 6700 - 40, "... and nothing older than the cap survived")

-- the invariant that makes trimming affordable: it must not run on every write
check (#packed ("Thorium Ore") <= 620 + 20,
	"a trimmed string stays near the trim threshold -- got " .. #packed ("Thorium Ore"))

--------------------------------------------------------------------
-- 9.  A record we cannot read is dropped, never guessed at.
--------------------------------------------------------------------

Atr_Hist_DB ().p["Junk"] = "6600:1200;banana;6602:1300"
s = Atr_Hist_Series ("Junk")
eq (#s, 2,        "an unreadable record is dropped")
eq (s[1].p, 1200, "... and the readable ones on either side survive")
eq (s[2].p, 1300, "... both of them")

Atr_Hist_DB ().p["Junk2"] = "not a series at all"
eq (#Atr_Hist_Series ("Junk2"), 0, "a string that is no series at all decodes to nothing")

-- and writing over a tail we cannot parse restarts rather than appending to it
gNow = day (6701)
Atr_Hist_Note ("Junk2", 500)
eq (packed ("Junk2"), "6701:500", "a write onto an unreadable tail starts the series again")

--------------------------------------------------------------------
-- 10. An item nobody scanned is empty, not nil -- "not recorded" must never be
--     readable as "worth nothing".
--------------------------------------------------------------------

s = Atr_Hist_Series ("Never Scanned")
eq (type (s), "table", "an unrecorded item returns a table")
eq (#s, 0,             "... an empty one")

--------------------------------------------------------------------
-- 11. Two realms do not share a series. Re-loading the file is also the closest
--     this harness gets to a /reload with data already on disk.
--------------------------------------------------------------------

local saved = AUCTIONATOR_MARKET_HISTORY

gRealm = "Otherrealm"
load_store ()						-- fresh file locals, cached realm key included
AUCTIONATOR_MARKET_HISTORY = saved	-- the same saved table the client would hand back

eq (#Atr_Hist_Series ("Copper Ore"), 0, "another realm does not see the first one's series")

gNow = day (6702)
Atr_Hist_Note ("Copper Ore", 7777)
eq (#Atr_Hist_Series ("Copper Ore"), 1, "... and keeps its own")

gRealm = "Areanoss"
load_store ()
AUCTIONATOR_MARKET_HISTORY = saved
eq (#Atr_Hist_Series ("Copper Ore"), 3, "the first realm's series survived it all")

--------------------------------------------------------------------
-- 12. The status line counts what is there.
--------------------------------------------------------------------

local st = Atr_Hist_Stats ()
check (st ~= nil, "stats are available")
eq (st.names, 4, "four items recorded on this realm")
check (st.samples >= 33, "... and their samples are counted -- got " .. tostring (st.samples))

--------------------------------------------------------------------

print (string.format ("%d passed, %d failed", passed, failed))
os.exit (failed == 0 and 0 or 1)
