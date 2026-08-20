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
-- 8.  Retention (item 31, stage 5): 30 days of DAILIES, then folded weeks
--     behind them, and only past all of that is anything actually destroyed.
--     Retention is the one decision that cannot be deferred -- a reader can be
--     added next month, a dropped month cannot be recovered -- so what this
--     pins is that old data is CONDENSED rather than thrown away.
--------------------------------------------------------------------

local i
for i = 6604, 6700 do
	gNow = day (i)
	Atr_Hist_Note ("Thorium Ore", 100 + i)
end

s = Atr_Hist_Series ("Thorium Ore")

check (#s <= 64, "the series is capped -- got " .. #s)
eq (s[#s].d, 6700,       "the newest day survives trimming")
eq (s[#s].p, 100 + 6700, "... with its price")

check (s[1].d >= 6700 - 114, "nothing past the whole retention window survives -- got age "
	.. (6700 - s[1].d))
check (6700 - s[1].d > 30,   "... but the series reaches back FURTHER than the daily window: "
	.. "old data is condensed, not dropped -- got " .. (6700 - s[1].d) .. " days")

-- days stay strictly in order, folded or not, because every read depends on it
local ordered, folded, dailies = true, 0, 0
for i = 1, #s do
	if (i > 1 and s[i].d <= s[i-1].d) then ordered = false end
	if ((s[i].span or 1) > 1) then folded = folded + 1 else dailies = dailies + 1 end
end
check (ordered, "the series stays in day order after folding")
check (folded > 0,  "whole weeks past the daily window are folded -- got " .. folded)
check (dailies >= 30, "... and the daily window is still daily -- got " .. dailies)

-- a folded record must say how many days it stands for, or a reader cannot tell
-- one week's median from one day's close
for i = 1, #s do
	if ((s[i].span or 1) > 1) then
		check (s[i].span <= 7, "a folded record covers at most a week -- got " .. s[i].span)
		break
	end
end

-- the invariant that makes trimming affordable: it must not run on every write
check (#packed ("Thorium Ore") <= 620 + 40,
	"a trimmed string stays near the trim threshold -- got " .. #packed ("Thorium Ore"))

-- FOLDING IS IDEMPOTENT. A week is folded once, from whole days, and never from
-- a previous fold's output -- otherwise the number drifts a little every trim.
local before8 = packed ("Thorium Ore")
gNow = day (6700)
Atr_Hist_Note ("Thorium Ore", 100 + 6700)		-- same day, same price: a re-close
local after8 = Atr_Hist_Series ("Thorium Ore")
local same = true
local b8 = Atr_Hist_Decode (before8)
for i = 1, math.min (#b8, #after8) do
	if (b8[i].d ~= after8[i].d or b8[i].p ~= after8[i].p) then same = false end
end
check (same, "re-running the trim does not move any already-folded price")

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
-- 13. THE READS (stage 2 and 3). Atr_Hist_Recent is on the price cascade's hot
--     path; Atr_Hist_Delta picks which historical sample "a week ago" means, and
--     picking the wrong one is an off-by-one nobody would ever see in game --
--     the number would just be quietly wrong.
--------------------------------------------------------------------

local d
for d = 6600, 6614 do
	gNow = day (d)
	Atr_Hist_Note ("Copper Ore Two", 1000 + (d - 6600) * 100)
end

gNow = day (6614)

local p, age = Atr_Hist_Recent ("Copper Ore Two")
eq (p, 2400,   "the cascade reads the newest price")
eq (age, 0,    "... and how old it is")
eq (Atr_Hist_Recent ("Never Heard Of It"), nil, "an unrecorded item prices at nothing, not zero")

local w = Atr_Hist_Delta ("Copper Ore Two")
check (w ~= nil, "a fortnight of history yields a week-over-week reading")
eq (w and w.span, 7,    "... spanning exactly a week")
eq (w and w.from, 1700, "... against the newest sample at or before seven days back")
eq (w and w.to,   2400, "... and the newest sample")
check (w and math.abs (w.pct - (700 / 1700)) < 0.0001,
	"... with the percentage over the OLD price")

-- the newer end going stale must not hide the reading, only mark it
gNow = day (6620)
w = Atr_Hist_Delta ("Copper Ore Two")
eq (w and w.age, 6, "a stale newest reading still reads, and reports its age")

--------------------------------------------------------------------
-- 14. Before a week exists: compare what there is, and say how much that was.
--------------------------------------------------------------------

gNow = day (6700); Atr_Hist_Note ("Short Series", 1000)
gNow = day (6701); Atr_Hist_Note ("Short Series", 1100)

eq (Atr_Hist_Delta ("Short Series"), nil, "two readings a day apart is noise, not a trend")

gNow = day (6703); Atr_Hist_Note ("Short Series", 2000)
w = Atr_Hist_Delta ("Short Series")
check (w ~= nil,      "three days apart is enough to say something")
eq (w and w.span, 3,  "... and it reports the REAL span, not a week")
eq (w and w.from, 1000, "... against the oldest reading there is")
check (w and math.abs (w.pct - 1.0) < 0.0001, "... doubling reads as +100%")

eq (Atr_Hist_Delta ("Never Heard Of It"), nil, "an unrecorded item has no trend")

gNow = day (6704); Atr_Hist_Note ("One Day Only", 500)
eq (Atr_Hist_Delta ("One Day Only"), nil, "one reading is not a comparison")

--------------------------------------------------------------------
-- 15. THE CACHE (stage 4). Atr_Hist_Delta memoises per name per day because two
--     of its callers are hot -- the Analysis view asks per row per redraw, and
--     the sell tooltip is rebuilt every frame. A cache that does not drop on a
--     write is a number frozen at yesterday's answer, which is exactly the sort
--     of wrong that looks right.
--------------------------------------------------------------------

gNow = day (6800); Atr_Hist_Note ("Cached Ore", 1000)
gNow = day (6807); Atr_Hist_Note ("Cached Ore", 2000)

w = Atr_Hist_Delta ("Cached Ore")
check (w and math.abs (w.pct - 1.0) < 0.0001, "a doubled price reads as +100%")

-- a second write the same day must invalidate: same day, new close
Atr_Hist_Note ("Cached Ore", 3000)
w = Atr_Hist_Delta ("Cached Ore")
check (w and math.abs (w.pct - 2.0) < 0.0001, "a re-close the same day drops the cached delta")

-- and a new day's write, likewise
gNow = day (6808); Atr_Hist_Note ("Cached Ore", 4000)
w = Atr_Hist_Delta ("Cached Ore")
eq (w and w.to, 4000, "a new day's write drops it too")

--------------------------------------------------------------------
-- 16. ONE PHRASING, SHARED. Four readers print this figure now; they all round
--     and clamp through here so the addon cannot describe one number two ways.
--------------------------------------------------------------------

eq (Atr_Hist_PctText (nil), nil,                     "no reading, no text")
eq (Atr_Hist_PctText ({ pct =  0.4118 }), "+41%",    "a rise rounds and signs")
eq (Atr_Hist_PctText ({ pct = -0.4118 }), "-41%",    "a fall keeps its sign")
eq (Atr_Hist_PctText ({ pct =  0 }),      "+0%",     "flat is a reading, not a blank")
eq (Atr_Hist_PctText ({ pct = 330 }),     ">999%",   "an unreadable rise is clamped, not printed")
eq (Atr_Hist_PctText ({ pct = -0.999 }),  "-99%",    "... and so is a total collapse")

local mv = Atr_Hist_MoveText ("Cached Ore")
check (mv and mv:find ("vs 8d ago", 1, true) ~= nil,
	"the move text always carries the REAL span -- got " .. tostring (mv))

--------------------------------------------------------------------
-- 17. THE SELL SENTENCE. It fires on a fall (undercutting a crash is the
--     mistake it exists to prevent), says less on a rise, and says nothing at
--     all about noise or about a market nobody has looked at lately.
--------------------------------------------------------------------

gNow = day (6900); Atr_Hist_Note ("Crashing Ore", 10000)
gNow = day (6907); Atr_Hist_Note ("Crashing Ore", 4000)

local note = Atr_Hist_SellNote ("Crashing Ore")
check (note ~= nil and note:find ("dumping", 1, true) ~= nil,
	"a market down 60% warns about undercutting a dumper")
check (note ~= nil and note:find ("60%% on 7 days ago", 1, false) ~= nil,
	"... naming the move and the REAL span -- got " .. tostring (note))

gNow = day (6910); Atr_Hist_Note ("Rising Ore", 1000)
gNow = day (6917); Atr_Hist_Note ("Rising Ore", 3000)
note = Atr_Hist_SellNote ("Rising Ore")
check (note ~= nil and note:find ("Up", 1, true) ~= nil, "a rise is reported")
check (note ~= nil and note:find ("dumping", 1, true) == nil, "... without the warning")
check (note ~= nil and note:find ("on 7 days ago", 1, true) ~= nil,
	"... and with the span intact (gsub returns two values; the count must not reach %d)")

gNow = day (6920); Atr_Hist_Note ("Flat Ore", 1000)
gNow = day (6927); Atr_Hist_Note ("Flat Ore", 1030)
eq (Atr_Hist_SellNote ("Flat Ore"), nil, "3% either way is noise and gets no sentence")

-- stale: the reading stands on the Analysis column but must not become advice
gNow = day (6930)
eq (Atr_Hist_SellNote ("Crashing Ore"), nil,
	"a reading nobody has refreshed in days is not advice about today")

eq (Atr_Hist_SellNote ("Never Heard Of It"), nil, "and an unrecorded item says nothing")

--------------------------------------------------------------------
-- 18. THE MEDIAN (stage 5). The owner's report was that the tooltip's "Auction
--     median" is usually a poisoned number. The measured cause is in the addon
--     already: that database averages 1.97 samples per name and 64% hold ONE,
--     so two thirds of the time the word "median" is over a single scan. This
--     one is over dated daily closes and refuses to answer below three of them.
--------------------------------------------------------------------

gNow = day (7000); Atr_Hist_Note ("Median Ore", 1000)
eq (Atr_Hist_Median ("Median Ore"), nil, "one day is not a median")

gNow = day (7001); Atr_Hist_Note ("Median Ore", 1200)
eq (Atr_Hist_Median ("Median Ore"), nil, "two days is not a median either")

gNow = day (7002); Atr_Hist_Note ("Median Ore", 1100)
local med, mn = Atr_Hist_Median ("Median Ore")
eq (med, 1100, "three days is, and it is the middle one")
eq (mn, 3,     "... reporting how many days it stands on")

-- the whole point: one absurd day must not become the item's typical price
gNow = day (7003); Atr_Hist_Note ("Median Ore", 900000)
med = Atr_Hist_Median ("Median Ore")
check (med ~= nil and med < 2000,
	"a single poisoned day does not move the median -- got " .. tostring (med))

eq (Atr_Hist_Median ("Never Heard Of It"), nil, "an unrecorded item has no typical price")

--------------------------------------------------------------------

print (string.format ("%d passed, %d failed", passed, failed))
os.exit (failed == 0 and 0 or 1)
