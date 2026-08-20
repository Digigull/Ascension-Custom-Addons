-------------------------------------------------------------------------------
-- AuctionatorHistory.lua
--
-- BACKLOG item 31, stage 1: a MARKET price series, in a file of its own.
-- Full reasoning: management/addons/auctionator/HISTORY-STORE.md.
--
-- WHAT THIS IS FOR.  Four things in this addon look like history and none of
-- them is a market price series -- FRAMEWORK.md §5 says so and the write paths
-- confirm it.  AUCTIONATOR_PRICE_DATABASE is one current number per name.
-- AUCTIONATOR_MEAN_PRICE_DATABASE keeps 15 samples, sorted by PRICE and evicted
-- at math.random, so its ordering was never written and cannot be recovered.
-- AUCTIONATOR_PRICING_HISTORY is dated and is YOUR OWN POSTINGS.
-- AUCTIONATOR_AH_VARIANT is one snapshot per variant, replaced each session.
--
-- So "is copper ore dearer than it was last week" -- which is the question every
-- unbuilt item in the backlog turns out to need (8 group C, 28, 30) -- is not
-- computable from anything stored.  This is the store that makes it computable.
--
-- IT SHIPPED DARK AND OFF, so that a week of ordinary play left real data for
-- the readers to be built against instead of an empty table.  It is read now --
-- the price cascade, the Week column, and since BACKLOG item 1 (2026-08-21) the
-- History sub-tab on Buy, Sell and My Auctions, which is the first place the
-- series is the WHOLE of what a view shows.  The switch is still off by default,
-- so an install that does not ask for this pays one boolean check per scanned
-- name and nothing else; what changes when it is off is that those readers say
-- so rather than drawing blank.
--
-- WHY A SEPARATE FILE, WHICH IS THE WHOLE SHAPE OF THIS FEATURE.  All 19
-- account-wide variables share one SavedVariables file today.  A file truncated
-- by a client crash fails to parse and the client discards THE WHOLE FILE -- the
-- ledger of real trades, the vendor learning grown over months, the harvested
-- recipe book.  A history big enough to be useful is a history big enough to
-- make that file slower to write and longer exposed, and what it would take down
-- with it is everything the player cannot re-derive.
--
-- Alone in its own file it endangers only itself -- and it is the one store here
-- that REGROWS BY SCANNING AGAIN.  That is the whole argument, and it is why the
-- companion addon exists rather than another entry in this addon's own .toc.
--
-- A second consequence, and it is the reason "turn it off if it costs too much"
-- is a real offer rather than a hope: a companion addon gets its own
-- ADDON_LOADED, so !ClientPerfProbe's load profile reports this file's parse
-- cost as a line of its own, in ms and KB, separate from the rest of Auctionator.
-- (Ascension locks GetAddOnMemoryUsage to zero, so the load profile is the only
-- per-addon channel left -- and it is why /atr clear's memory line reads 0 KB.)
--
-- NOTHING ELSE MAY EVER MOVE INTO THAT FILE.  The bargain above holds only while
-- everything in it is re-derivable by scanning.  A ledger row or a learned
-- vendor price in here would quietly undo it.
--
-- THE STORAGE SHAPE, decided before the first write because it cannot be
-- cheaply undone (the same call item 13 had to make after the fact):
--
--   ONE PACKED STRING PER ITEM NAME, holding the whole series.
--
-- Blizzard's serialiser writes one array element per LINE with an index comment,
-- so a stored element costs ~20-30 bytes however small it is.  For 5267 names at
-- 30 daily samples that per-element overhead, not the data, is the whole cost:
--
--   obs[name][i] = { t =, p = }   ~5-8 MB   158,000 Lua TABLES   (ruled out)
--   obs[name][i] = "day:price"    ~3-5 MB   158,000 strings      (still per-line)
--   obs[name]    = "d:p;d:p;..."  ~1.5-1.8 MB   5,267 strings    <- this
--
-- The container costs more than the contents, which is exactly what item 13
-- found in the mean database's single-sample wrapper.  Decode is lazy: a
-- week-over-week reading wants two numbers out of one string and nothing needs
-- the table expanded.
--
-- THE RECORD is  day:price  or  day:price:n  when more than one scan backed it.
--   day    days since 2008-08-01, four digits (ToTightTime packs MINUTES since
--          the same epoch -- seven digits, and a daily series has no use for the
--          other three)
--   price  the quantity-weighted median of that scan's listings, in copper --
--          the same sample the mean database takes, not the lowest listing.  The
--          lowest is one seller's decision; the median is the book.
--   n      how many scans backed the day.  Kept because scans are user-driven
--          and irregular: a reader has to be able to tell one observation from
--          ten, or "daily close" quietly means "whenever they happened to look".
--
-- ONE SAMPLE A DAY, LAST WRITE WINS -- a close, not an average.  The demand
-- driver this was scoped around (Call Board quests) rotates WEEKLY, so daily is
-- generous against the signal, and it is also the de-duplication rule: scan an
-- item nine times in an evening and it writes once.
--
-- APPENDING IS O(1) PER NAME PER SCAN, which matters because the writer runs
-- inside a loop over every row of a scan.  Today's record is either the last one
-- in the string or absent, so the common path is one match on the tail and one
-- concatenation.  A full decode happens only when the string outgrows
-- ATR_HIST_TRIM_AT -- at most once per name per day.
--
-- RETENTION IS BOUNDED TWICE AND NEEDS NO LOGIN SWEEP.  Trimming on write keeps
-- a scanned name at ATR_HIST_DAYS; a name that stops being scanned freezes at
-- whatever it had, which is already under the per-name cap.  So the total is
-- bounded by names x cap without ever walking the table at login -- and walking
-- it at login is precisely the cost this feature is trying not to add.
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

local function HT (s)
	if (ZT) then return ZT (s); end
	return s;
end

-- 2008-08-01, the epoch gTimeTightZero uses.  A constant rather than that global
-- because this file must not care when Atr_OnLoad ran; the day boundary lands at
-- a fixed offset from UTC, which a daily series does not notice.
local ATR_HIST_DAY0 = 1217548800;

-- Retention is a WINDOW, not an exact edge, and deliberately so: trimming costs
-- a decode, so it runs only when a string outgrows ATR_HIST_TRIM_AT rather than
-- on every write.  A name therefore carries somewhere between ATR_HIST_DAYS and
-- roughly (ATR_HIST_TRIM_AT / record length) days before being cut back to the
-- window.  The overshoot is bounded, costs a few hundred bytes per name, and
-- buys one decode per name per MONTH instead of one per scan.
--
-- BEYOND THE DAILY WINDOW THE SERIES IS CONDENSED, NOT DROPPED (item 31, stage
-- 5).  A week that has passed entirely out of the daily window folds into one
-- record holding that week's MEDIAN close, and those keep for ATR_HIST_WEEKS.
--
-- Why keep anything at all when no reader asks for it yet: **retention is the
-- one decision that cannot be deferred.** A reader can be added next month; a
-- month that was dropped is gone. The asymmetry is entirely one-sided, and it is
-- the same argument that put the store in its own file.
--
-- Why a WEEK is the fold unit rather than a month: the market mechanism this was
-- built for rotates weekly (Call Board quests), so "this is the week copper
-- spikes" is a real question and a monthly average would erase exactly the
-- signal. A quarter of weekly shape answers it; more is speculation.
--
-- THE COST, from the measured 9.8 bytes a sample: 30 dailies is ~324 bytes and
-- 12 folded weeks adds ~170, so a full name goes from ~360 to ~530. Across the
-- whole 5267-name database that is roughly 1.8 MB -> 2.5 MB. If that is ever too
-- much, ATR_HIST_WEEKS is the dial and setting it to 0 restores the old
-- drop-everything behaviour exactly.
local ATR_HIST_DAYS     = 30;		-- days of DAILY samples kept per name
local ATR_HIST_WEEKS    = 12;		-- ... then this many folded weeks behind them
local ATR_HIST_MAX      = 64;		-- a hard record cap behind both
local ATR_HIST_TRIM_AT  = 620;		-- decode+trim only once a string passes this
local ATR_HIST_NAMECAP  = 8000;		-- backstop: the feed itself is bounded by the AH

-- How far back anything is kept at all.
local ATR_HIST_KEEP = ATR_HIST_DAYS + (ATR_HIST_WEEKS * 7);

-- WHAT MAKES A DAY'S CLOSE WORTH BELIEVING (owner's question, 2026-08-21:
-- "will this prevent a skew if I sell a cheap item like a single piece of linen
-- cloth for 1000 gold?").
--
-- Three separate answers, because it was three separate holes:
--
-- 1. YOUR OWN LISTINGS ARE NOT THE MARKET.  Nothing in this addon's price feeds
--    ever excluded them -- the only owner test in the scan is a display marker
--    for the browse list.  So listing linen at 1000g put 1000g into the sample
--    like anyone else's.  On a busy book that changed nothing; on a thin one you
--    were quoting yourself back at yourself.
--
-- 2. THE MEGA-HIGH OUTLIER.  The owner's model of a trade-goods book is exactly
--    right: "generally there will be a normal, medium and high price in the AH
--    on trade goods, then the dumb mega high price here and there."  A median is
--    already robust to a few of those -- but ours is QUANTITY-WEIGHTED, and one
--    enormous stack at a silly price carries enormous weight.  That is the case
--    the owner spotted, and it is the one a plain median does not cover.
--
--    So: reject listings priced above ATR_HIST_OUTLIER x the UNWEIGHTED middle.
--    Unweighted for the centre on purpose -- one vote per listing -- because a
--    giant stack must not be able to drag the very number it is measured against.
--
--    Only the HIGH tail is cut.  A cheap listing is a real buying opportunity and
--    is what the Auction line reports; trimming both ends would also bias the
--    figure downward, where trimming the junk end only removes prices nobody
--    trades at.
--
-- 3. A THIN BOOK IS NOT A PRICE.  With one or two listings the "median" is just
--    those listings, so the day is marked and the readers that quote a single
--    day's close decline rather than reporting you to yourself.
local ATR_HIST_THIN        = 3;		-- fewer listings than this and the day is marked
local ATR_HIST_OUTLIER     = 4;		-- x the unweighted middle is where junk starts
local ATR_HIST_OUTLIER_MIN = 4;		-- ... and you cannot name an outlier in a book of three

-- Memoised per name per DAY.  Two of the callers make this a hot path and
-- neither is obviously one: the Analysis view asks for every row on every
-- redraw, and Atr_ShowRecTooltip is re-run EVERY FRAME while the sell tooltip is
-- up (see its comment).  A decode allocates a table per sample, so uncached that
-- is a few thousand short-lived tables a second for a number that changes once a
-- day.  The entry is dropped when that name is written to, and the stored day
-- makes a day roll drop it by itself.
local gHist_DeltaCache = {};

-- ===========================================================================
-- THE COMPANION
--
-- AUCTIONATOR_MARKET_HISTORY is declared by Auctionator-Finder-Ascension-History
-- and deliberately NOT by this addon's .toc -- a global may only be declared by
-- one addon, and declaring it here would put the table back in the file this
-- whole design exists to keep it out of.
--
-- The marker global is set by the companion's one Lua line.  SavedVariables load
-- BEFORE an addon's files run, so if the marker is set then whatever was saved
-- is already in place -- which is what lets everything here resolve lazily and
-- ignore load order entirely.  ## OptionalDeps in the .toc asks for the
-- companion first as well; nothing depends on that being honoured.
-- ===========================================================================

function Atr_Hist_Available ()
	return (AUCTIONATOR_MARKET_HISTORY_LOADED == true);
end

-- DEFAULT OFF, and note the idiom is the opposite of feedPriceDB's `~= false`
-- beside it.  Copying that one here would turn this on for everybody.
function Atr_Hist_Enabled ()

	if (not Atr_Hist_Available ()) then return false; end
	if (type (AUCTIONATOR_FINDER_SETTINGS) ~= "table") then return false; end

	return (AUCTIONATOR_FINDER_SETTINGS.marketHistory == true);
end

function Atr_Hist_SetEnabled (on)

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
	AUCTIONATOR_FINDER_SETTINGS.marketHistory = on and true or false;

	-- the SETTING lives in the main file on purpose (owner's requirement): being
	-- able to turn this off must never depend on the thing being turned off
	return AUCTIONATOR_FINDER_SETTINGS.marketHistory;
end

local gHist_RealmKey = nil;

local function Hist_RealmKey ()

	if (gHist_RealmKey) then return gHist_RealmKey; end
	if (type (GetRealmName) ~= "function" or type (UnitFactionGroup) ~= "function") then return nil; end

	local realm = GetRealmName ();
	local fac   = UnitFactionGroup ("player");
	if (realm == nil or fac == nil) then return nil; end

	-- keyed exactly like AUCTIONATOR_PRICE_DATABASE: prices are per realm and
	-- per faction, and a series that mixed them would be noise
	gHist_RealmKey = realm.."_"..fac;
	return gHist_RealmKey;
end

-- This realm's store, or nil when the companion is not installed.  Creates
-- nothing until something actually records, so an install that never switches
-- the feature on leaves an empty companion file.
function Atr_Hist_DB ()

	if (not Atr_Hist_Available ()) then return nil; end

	local key = Hist_RealmKey ();
	if (key == nil) then return nil; end

	if (type (AUCTIONATOR_MARKET_HISTORY) ~= "table") then AUCTIONATOR_MARKET_HISTORY = {}; end

	local db = AUCTIONATOR_MARKET_HISTORY;
	if (db.ver == nil) then db.ver = 1; end
	if (type (db.realms) ~= "table") then db.realms = {}; end

	local r = db.realms[key];
	if (type (r) ~= "table") then r = {}; db.realms[key] = r; end
	if (type (r.p) ~= "table") then r.p = {}; end
	if (type (r.n) ~= "number") then r.n = 0; end

	return r;
end

-- ===========================================================================
-- THE PACKING
-- ===========================================================================

local function Hist_Day (now)
	now = tonumber (now) or (time and time()) or 0;
	return math.floor ((now - ATR_HIST_DAY0) / 86400);
end

-- day:price          one scan, one day
-- day:price:n         n scans closed that day
-- day:price:n:span    a FOLDED week -- span is the days it stands for
-- ...anything/L       THIN: L is the listing count for a day, or the number of
--                     thin days for a fold.  Readers treat its PRESENCE as the
--                     signal; only the diagnostic prints the number.
--
-- Each field is omitted when it carries no information, which is what keeps the
-- common record at nine characters -- and the thin suffix lands on the small
-- minority of days that have one, so a well-stocked book costs nothing extra.
local function Hist_Rec (d, p, n, span, thin)

	local s;

	if     (span and span > 1) then s = d..":"..p..":"..(n or 1)..":"..span;
	elseif (n and n > 1)       then s = d..":"..p..":"..n;
	else                            s = d..":"..p; end

	if (thin) then s = s.."/"..thin; end

	return s;
end

local function Hist_ParseRec (rec)

	local body, thin = string.match (rec or "", "^([^/]+)/(%d+)$");
	if (body == nil) then body = rec; end

	local d, p, n, span = string.match (body or "", "^(%d+):(%d+):?(%d*):?(%d*)$");

	d = tonumber (d);
	p = tonumber (p);
	if (d == nil or p == nil or p <= 0) then return nil; end

	return { d = d, p = p, n = tonumber (n) or 1, span = tonumber (span) or 1,
			 thin = tonumber (thin) };
end

-- One packed string -> { {d, p, n}, ... }, oldest first.  Malformed records are
-- dropped rather than guessed at: this is a store that regrows, so throwing one
-- bad record away costs a day and inventing a number costs the reader's trust.
function Atr_Hist_Decode (packed)

	local out = {};
	if (type (packed) ~= "string" or packed == "") then return out; end

	local rec;
	for rec in string.gmatch (packed, "[^;]+") do
		local e = Hist_ParseRec (rec);
		if (e) then tinsert (out, e); end
	end

	return out;
end

local function Hist_Encode (series)

	local parts = {};
	local i;
	for i = 1, #series do
		parts[i] = Hist_Rec (series[i].d, series[i].p, series[i].n, series[i].span, series[i].thin);
	end

	return table.concat (parts, ";");
end

-- Condense, then cap.  Only ever called just after today's record was written,
-- so the newest entry always survives and the result is never empty.
--
-- A WEEK IS FOLDED EXACTLY ONCE, and that is what makes this safe to re-run: a
-- week is only folded when ALL SEVEN of its days have left the daily window, so
-- the fold always happens from whole days and never from a previous fold's
-- output. An already-folded record (span > 1) is carried through untouched --
-- re-medianing a median would drift the number a little further every trim.
--
-- The folded price is the week's MEDIAN close, not its last or its mean: one bad
-- day inside a week is exactly what a week-long summary should absorb.
local function Hist_Trim (packed, today)

	local s = Atr_Hist_Decode (packed);

	local out, order, bucket = {}, {}, {};

	local i;
	for i = 1, #s do

		local e = s[i];
		local age = today - e.d;

		if (age > ATR_HIST_KEEP) then
			-- past everything: gone, and that is the only place data is destroyed

		elseif (age <= ATR_HIST_DAYS) then
			tinsert (out, e);					-- still daily

		elseif ((e.span or 1) > 1) then
			tinsert (out, e);					-- already a folded week

		elseif (today - ((math.floor (e.d / 7) * 7) + 6) > ATR_HIST_DAYS) then

			-- its whole week is out of the daily window: fold it
			local k = math.floor (e.d / 7);
			local b = bucket[k];

			if (b == nil) then
				b = { d = e.d, hi = e.d, n = 0, p = {} };
				bucket[k] = b;
				tinsert (order, k);
			end

			if (e.d < b.d)  then b.d  = e.d; end
			if (e.d > b.hi) then b.hi = e.d; end

			b.n    = b.n + (e.n or 1);
			b.thin = (b.thin or 0) + (e.thin and 1 or 0);
			b.days = (b.days or 0) + 1;
			tinsert (b.p, e.p);

		else
			tinsert (out, e);					-- old, but its week is not complete yet
		end
	end

	local k;
	for _, k in ipairs (order) do
		local b = bucket[k];
		table.sort (b.p);
		-- a week made mostly of thin days is a thin week, and the marker carries
		-- how many of its days were
		local wthin = ((b.thin or 0) * 2 > (b.days or 1)) and b.thin or nil;

		tinsert (out, { d = b.d, p = b.p[math.ceil (#b.p / 2)], n = b.n,
						span = (b.hi - b.d) + 1, thin = wthin });
	end

	-- folded weeks were appended after the dailies they came from
	table.sort (out, function (a, b) return a.d < b.d; end);

	while (#out > ATR_HIST_MAX) do tremove (out, 1); end

	if (#out == 0) then return packed; end

	return Hist_Encode (out);
end

-- The newest day in a packed string, without decoding the rest of it.
local function Hist_LastRec (packed)

	local last = string.match (packed or "", "[^;]+$");
	if (last == nil) then return nil, nil; end

	local e = Hist_ParseRec (last);
	if (e == nil) then return nil, last; end

	return e, last;
end

-- Reject the junk end of a book.  See the ATR_HIST_OUTLIER note above for why
-- the centre is measured UNWEIGHTED and why only the high tail is cut.
local function Hist_RejectHigh (list)

	if (#list < ATR_HIST_OUTLIER_MIN) then return list; end

	local p = {};
	local i;
	for i = 1, #list do p[i] = list[i].price; end
	table.sort (p);

	local mid = p[math.ceil (#p / 2)];
	if (mid == nil or mid <= 0) then return list; end

	local cap  = mid * ATR_HIST_OUTLIER;
	local keep = {};
	for i = 1, #list do
		if (list[i].price <= cap) then tinsert (keep, list[i]); end
	end

	-- rejection must never eat the book: if this left almost nothing then the
	-- "outliers" were the market and the centre was the anomaly
	if (#keep < 2) then return list; end

	return keep;
end

-- ONE SCAN'S LISTINGS -> THE DAY'S SAMPLE, and the count behind it.
--
-- `entries` is { price = per unit, weight = stack size, owner = seller } -- the
-- shape all three feeds already build for the weighted median, plus the owner
-- they already had and never used.
--
-- Returns nil when there is nothing left to measure, which the caller must treat
-- as "no observation" rather than as a price: an auction house holding only your
-- own listing has told you nothing about what anything is worth.
function Atr_Hist_Sample (entries)

	if (type (entries) ~= "table" or #entries == 0) then return nil, 0; end

	local me = (type (UnitName) == "function") and UnitName ("player") or nil;

	local keep = {};
	local i;
	for i = 1, #entries do

		local e = entries[i];

		-- Best effort, and it has to be: `owner` comes back nil from this API
		-- often enough that the Analysis tab counts the cases (numNilOwners).
		-- An unknown owner is KEPT -- dropping listings because we could not
		-- identify them would quietly thin every book.
		local mine = (me ~= nil and type (e.owner) == "string" and e.owner ~= "" and e.owner == me);

		if (not mine and (tonumber (e.price) or 0) > 0) then tinsert (keep, e); end
	end

	if (#keep == 0) then return nil, 0; end

	local kept = Hist_RejectHigh (keep);
	local med  = Atr_WeightedMedianPrice and Atr_WeightedMedianPrice (kept) or 0;

	if (med == nil or med <= 0) then return nil, #kept; end

	return math.floor (med), #kept;
end

-- ===========================================================================
-- WRITING
-- ===========================================================================

-- Names are only ever added by a feed that already passed the price database's
-- four rules, so this cap is a backstop against something pathological rather
-- than a working limit.  Halve on overflow, the way Atr_AHVariant_Prune does, so
-- it cannot run again on the very next write.
function Atr_Hist_PruneNames (db, today)

	db = db or Atr_Hist_DB ();
	if (db == nil) then return 0; end

	local ages, n = {}, 0;
	local name, packed;
	for name, packed in pairs (db.p) do
		n = n + 1;
		local rec = Hist_LastRec (packed);
		tinsert (ages, { name = name, d = (rec and rec.d) or 0 });
	end

	if (n <= ATR_HIST_NAMECAP) then db.n = n; return n; end

	table.sort (ages, function (a, b) return a.d > b.d; end);

	local keep = {};
	local half = math.floor (ATR_HIST_NAMECAP / 2);
	local i;
	for i = 1, half do
		if (ages[i]) then keep[ages[i].name] = db.p[ages[i].name]; end
	end

	db.p = keep;
	db.n = half;

	return half;
end

-- Record one observation.  `price` is the quantity-weighted median of the scan
-- that saw it, in copper.  Returns true when something was written.
--
-- Called from the four feeds that already write the price databases, and from
-- INSIDE their guards, so it inherits the four rules that make a partial scan
-- safe (never delete, skip scaled gear, skip a capped scan, no bid-only rows).
-- Rules 3 and 4 matter more here than they do there: a bad current price is
-- overwritten by the next scan, and a bad sample is averaged into every later
-- reading of this series forever.
-- `nlist` is how many listings backed the price -- Atr_Hist_Sample's second
-- return.  Below ATR_HIST_THIN the day is marked, and the readers that quote one
-- day's close then decline rather than report a book of one back at you.
function Atr_Hist_Note (name, price, now, nlist)

	if (not Atr_Hist_Enabled ()) then return false; end

	local db = Atr_Hist_DB ();
	if (db == nil) then return false; end

	if (type (name) ~= "string" or name == "") then return false; end

	price = math.floor (tonumber (price) or 0);
	if (price <= 0) then return false; end

	local day    = Hist_Day (now);
	local packed = db.p[name];

	nlist = tonumber (nlist);
	local thin = (nlist and nlist < ATR_HIST_THIN) and nlist or nil;

	if (type (packed) ~= "string" or packed == "") then
		db.p[name] = Hist_Rec (day, price, 1, nil, thin);
		db.n = (db.n or 0) + 1;
		gHist_DeltaCache[name] = nil;
		if (db.n > ATR_HIST_NAMECAP) then Atr_Hist_PruneNames (db, day); end
		return true;
	end

	local rec, raw = Hist_LastRec (packed);

	if (rec == nil) then
		-- the tail is not a record we wrote: start again rather than append to
		-- something we cannot read back
		db.p[name] = Hist_Rec (day, price, 1, nil, thin);
		gHist_DeltaCache[name] = nil;
		return true;

	elseif (rec.d == day) then
		-- the day's CLOSE is its newest reading, and the newest reading's book
		-- depth is the one that describes it
		db.p[name] = string.sub (packed, 1, #packed - #raw)..Hist_Rec (day, price, rec.n + 1, nil, thin);

	elseif (day > rec.d) then
		db.p[name] = packed..";"..Hist_Rec (day, price, 1, nil, thin);

	else
		-- the clock went backwards.  Refusing costs one sample; appending out of
		-- order would corrupt every later read of this name.
		return false;
	end

	if (#db.p[name] > ATR_HIST_TRIM_AT) then
		db.p[name] = Hist_Trim (db.p[name], day);
	end

	gHist_DeltaCache[name] = nil;		-- this name's cached delta is now stale

	return true;
end

-- ===========================================================================
-- READING
--
-- Nothing in the addon calls these yet -- stage 1 ships dark.  They exist
-- because the diagnostic below needs them, and because they are the seam
-- stage 2 plugs into (Atr_GetAuctionPrice's second rung) and stage 3 after it
-- (the week-over-week column that BACKLOG item 8's group C was scoped around).
-- ===========================================================================

-- The series for one name, oldest first, each entry { d, p, n } plus `age` in
-- days.  Empty when there is nothing -- never nil, so a caller cannot mistake
-- "not recorded" for "worth nothing".
function Atr_Hist_Series (name, now)

	local db = Atr_Hist_DB ();
	if (db == nil or type (name) ~= "string") then return {}; end

	local s     = Atr_Hist_Decode (db.p[name]);
	local today = Hist_Day (now);

	local i;
	for i = 1, #s do s[i].age = today - s[i].d; end

	return s;
end

-- THE HISTORY SUB-TAB'S ROWS (BACKLOG item 1, 2026-08-21) ------------------
--
-- The Current / History strip over the Buy, Sell and My Auctions results list
-- answered a different question from the one its name asks: it was built out of
-- AUCTIONATOR_PRICING_HISTORY, which is YOUR OWN POSTINGS.  The owner asked for
-- what the MARKET has been doing, and decided (2026-08-21) that it REPLACES the
-- postings rather than sitting beside them -- the Ledger tab reads your own
-- trades now, and it holds the ones that actually happened rather than the ones
-- you asked for.
--
-- Shaped here rather than in Auctionator.lua because the pane has no business
-- knowing how a day number is stored (FRAMEWORK.md section 6: the arithmetic
-- lives with the data).  What comes back is already the row shape that file
-- renders and prices from.
--
-- NEWEST FIRST, which is the opposite of the store's own order.  The series is
-- kept oldest-first because that is how it is appended and folded; a list you
-- read starts with what is true now.
--
-- `yours` IS DELIBERATELY NOT SET, and it is the one field whose absence does
-- something.  Atr_UpdateRecommendation prices at "undercut this" unless the row
-- is yours, and these rows are the market's -- so clicking one on the SELL tab
-- undercuts it, exactly as clicking a row on the Current tab does.  The old
-- rows set yours = true because undercutting your own past posting is a race
-- against yourself.
function Atr_Hist_PaneRows (name, now)

	local out = {};

	local s = Atr_Hist_Series (name, now);

	local i;
	for i = #s, 1, -1 do

		local e = s[i];

		tinsert (out, {
			itemPrice	= e.p,
			buyoutPrice	= e.p,			-- one unit: a daily close is a per-item price
			stackSize	= 1,
			-- MIDDAY, not midnight, and it is not cosmetic.  A day number is
			-- bucketed off the epoch in whole days, and date() renders in LOCAL
			-- time -- so the midnight that starts day N renders as the previous
			-- calendar day for anyone west of UTC, and every row would be
			-- labelled a day early.  Noon is inside the right day for any offset
			-- this side of +/-12h, which is all of them.
			when		= ATR_HIST_DAY0 + (e.d * 86400) + 43200,
			market		= true,			-- what Atr_BuildHistItemText switches on
			thin		= e.thin,
			span		= e.span,
			age			= e.age,
		});
	end

	return out;
end

-- WHY THIS HAS THREE STATES AND THE REQUEST NAMED ONE.
--
-- The owner asked for "if not enabled in settings then have it say enable the
-- setting to see history".  That covers installed-but-off.  The other two are
-- the ones that would actually read as a broken tab:
--
--   * THE COMPANION IS NOT INSTALLED.  Telling somebody to tick a setting they
--     cannot reach is worse than saying nothing, so this case names the folder.
--     Atr_Hist_Enabled() returns false here too, which is why the order of the
--     tests below matters -- "off" would swallow it.
--   * ON, AND EMPTY FOR THIS ITEM.  The ordinary state for days after switching
--     it on, and the one most likely to be mistaken for a bug.  It says the
--     record fills in by scanning rather than leaving a blank list.
--
-- Takes the row count rather than the name so the series is decoded once per
-- draw: the caller has the rows already.
function Atr_Hist_PaneMessage (haveRows)

	if (not Atr_Hist_Available ()) then
		return HT("Market price history needs the Auctionator-Finder-Ascension-History folder, installed beside this addon. It is not loaded, so there is nothing to show here.");
	end

	if (not Atr_Hist_Enabled ()) then
		return HT("Market price history is off.\n\nTurn on \"Market price history\" in the Finder's Scanning options, or type /atrhistory on, and this fills in as you scan.");
	end

	if (not haveRows) then
		return HT("No price history recorded for this item yet.\n\nOne reading a day is kept, from the scans you already run -- search for it and it starts.");
	end

	return nil;
end

-- THE NEWEST READING, without decoding the rest of the series.  This is the one
-- the price cascade calls (stage 2), so it is on a hot path: a table lookup and
-- one match on the tail of a string.
--
-- No age filter, deliberately.  The store's own retention IS the filter -- what
-- is in here is at most a month old -- and the rung this sits above is
-- Atr_GetMostRecentSale, which returns YOUR OWN LAST POSTING PRICE with no age
-- bound at all.  A three-week-old market reading beats an unbounded guess of
-- your own; the age comes back as a second return so a caller that wants to say
-- how old it is can.
function Atr_Hist_Recent (name, now)

	local db = Atr_Hist_DB ();
	if (db == nil or type (name) ~= "string") then return nil; end

	local packed = db.p[name];
	if (type (packed) ~= "string") then return nil; end

	local rec = Hist_LastRec (packed);
	if (rec == nil or rec.p == nil or rec.p <= 0) then return nil; end

	-- A THIN DAY IS NOT A PRICE, but it is not nothing either.  Prefer the newest
	-- day that had a real book behind it; fall back to the thin one only when
	-- that is all there has ever been, because for an item with two listings a
	-- week that IS the evidence and the rung below this one is worse.
	if (rec.thin) then
		local s = Atr_Hist_Series (name, now);
		local i;
		for i = #s, 1, -1 do
			if (not s[i].thin) then return s[i].p, s[i].age or 0; end
		end
	end

	return rec.p, Hist_Day (now) - rec.d;
end

-- WEEK OVER WEEK (BACKLOG item 8, group C -- this is the figure that item was
-- scoped around, and item 31 is what finally makes it computable).
--
-- "Copper ore at 40s says nothing. Copper ore at 40s WHEN IT WAS 12s LAST WEEK
-- is a farm worth doing." A week, not a trend line, because the demand driver
-- rotates weekly -- Call Board quests change every week, so one week the ore is
-- scarce and dear and the next nobody wants it.
--
-- The comparison sample is the NEWEST reading at or before a week back, which is
-- "what it was a week ago" and not "the oldest thing I have".  Until the store
-- has a week in it that does not exist, so it falls back to the oldest reading
-- it does have -- and returns the real `span` with it, so the caller says "vs 4
-- days ago" rather than quietly calling four days a week.  Under ATR_HIST_MINSPAN
-- it returns nothing at all: two readings a day apart is noise, not a trend.
local ATR_HIST_WEEK    = 7;
local ATR_HIST_MINSPAN = 3;

function Atr_Hist_Delta (name, days, now)

	local today  = Hist_Day (now);
	local cached = (days == nil) and gHist_DeltaCache[name] or nil;

	if (cached and cached.day == today) then return cached.d; end

	local all = Atr_Hist_Series (name, now);

	-- Both ends have to be real.  A delta between two thin days is the difference
	-- between two accidents, and it is exactly what would have printed ">999%" in
	-- green on the day somebody listed one linen for 1000 gold.
	local s = {};
	local i;
	for i = 1, #all do
		if (not all[i].thin) then tinsert (s, all[i]); end
	end

	if (#s < 2) then
		if (days == nil and type (name) == "string") then
			gHist_DeltaCache[name] = { day = today, d = nil };
		end
		return nil;
	end

	local asked = days;
	days = tonumber (days) or ATR_HIST_WEEK;

	local function keep (d)
		if (asked == nil and type (name) == "string") then
			gHist_DeltaCache[name] = { day = today, d = d };
		end
		return d;
	end

	local newest = s[#s];
	local target = newest.d - days;

	local pick;
	for i = #s - 1, 1, -1 do
		if (s[i].d <= target) then pick = s[i]; break; end
	end

	if (pick == nil) then
		if ((newest.d - s[1].d) < ATR_HIST_MINSPAN) then return keep (nil); end
		pick = s[1];
	end

	if (pick.p == nil or pick.p <= 0) then return keep (nil); end

	return keep {
		pct  = (newest.p - pick.p) / pick.p,
		from = pick.p,
		to   = newest.p,
		span = newest.d - pick.d,		-- days actually compared, which may not be 7
		age  = newest.age or 0,			-- how stale the NEWER end is
	};
end

-- WHAT THIS IS NORMALLY WORTH (item 31, stage 5) -----------------------------
--
-- The median of every close on file.  This is the figure
-- AUCTIONATOR_MEAN_PRICE_DATABASE has been trying to give since long before this
-- fork, and could not, for three reasons the write path makes unavoidable:
-- `Atr_MeanAppend` sorts its array BY PRICE and evicts at `math.random`, so
-- temporal order was never written and an unlucky thin can drop every sample
-- from the week you are asking about; and nothing carries a date, so a sample
-- from three months ago counts exactly as much as this morning's.
--
-- But the reason the owner actually sees a bad number on a tooltip is simpler
-- and is already measured in this repo: **that database averages 1.97 samples
-- per name and 64% of names have exactly ONE** (`AuctionatorHints.lua`, item 12
-- part 3b). Two thirds of the time "Auction median" is one scan's number wearing
-- the word median. One odd listing on the day somebody happened to scan is then
-- the item's "typical" price for good.
--
-- Here every sample is a day, days are bounded by retention, and there is a
-- minimum below which nothing is called a median at all.
local ATR_HIST_MEDIAN_MIN = 3;

function Atr_Hist_Median (name, now)

	local all = Atr_Hist_Series (name, now);

	-- Thin days are dropped outright here rather than fallen back on: a median is
	-- a statement about a market, and a day whose whole book was your own listing
	-- and one other is not one.  An item that is ALWAYS thin therefore gets no
	-- "typical price" at all, which is the honest answer -- the Auction line still
	-- shows what is actually on the shelf.
	local s = {};
	local i;
	for i = 1, #all do
		if (not all[i].thin) then tinsert (s, all[i]); end
	end

	if (#s < ATR_HIST_MEDIAN_MIN) then return nil, #s; end

	local p = {};
	for i = 1, #s do p[i] = s[i].p; end

	table.sort (p);

	local n = #p;
	if (n % 2 == 0) then return math.floor ((p[n/2] + p[n/2 + 1]) / 2), n; end

	return math.floor (p[math.ceil (n/2)]), n;
end

-- ONE PHRASING OF A MOVE, SHARED BY EVERY READER (item 31, stage 4).
--
-- The same figure now appears on the Analysis tab's Week column, on item
-- tooltips, on the Sell tab's hover and inside two of the Analysis side
-- tooltips.  Four sites rounding and clamping a percentage their own way is four
-- chances for the addon to describe one number two ways, which is the thing
-- FRAMEWORK.md warns about for prices and is no different here.
--
-- Clamped because the cell that shows it is 56px and because past a point the
-- digits stop being the point: a 12s reagent that went to 40g is +33,000%, which
-- is true and unreadable.
function Atr_Hist_PctText (d)

	if (d == nil or d.pct == nil) then return nil; end

	local pct = d.pct * 100;

	if (pct > 999)  then return ">999%", pct; end
	if (pct < -99)  then return "-99%", pct; end
	if (pct >= 0)   then return string.format ("+%d%%", math.floor (pct + 0.5)), pct; end

	return string.format ("%d%%", math.ceil (pct - 0.5)), pct;
end

-- "+240% vs 7d ago", or nil when there is not enough history to say anything.
-- The span is ALWAYS in the string: until a week has been recorded it is not a
-- week, and a reader who is not told that will read it as one.
function Atr_Hist_MoveText (name, now)

	local d = Atr_Hist_Delta (name, nil, now);
	local txt, pct = Atr_Hist_PctText (d);

	if (txt == nil) then return nil; end

	return string.format ("%s vs %dd ago", txt, d.span or 0), pct, d;
end

-- THE SELL TAB'S SENTENCE (item 31, stage 4).
--
-- Auctionator's whole sell flow is "undercut the current lowest", and the lowest
-- listing is one seller's decision -- so the case worth a warning is not the
-- market being dear, it is the market having FALLEN: undercutting a crash prices
-- you into it. The other direction is said too, shorter, because it is
-- reassurance rather than a decision.
--
-- Nothing at all under ATR_HIST_SAY: a few percent either way is the noise a
-- daily close carries, and a tooltip that comments on it teaches you to ignore
-- the line.  Nothing when the newer end is stale, because "the market has
-- fallen" would then be a claim about a market nobody has looked at.
local ATR_HIST_SAY   = 0.15;
local ATR_HIST_FRESH = 3;

function Atr_Hist_SellNote (name, now)

	local d = Atr_Hist_Delta (name, nil, now);
	if (d == nil or (d.age or 0) > ATR_HIST_FRESH) then return nil; end

	local txt = Atr_Hist_PctText (d);
	if (txt == nil) then return nil; end

	-- The extra parentheses are load-bearing: gsub returns the string AND a
	-- replacement count, and an unparenthesised call passes both, so the count
	-- would land in %d and every sentence would read "on 1 days ago".
	local bare = (txt:gsub ("^[%+%-]", ""));

	if (d.pct <= -ATR_HIST_SAY) then
		return string.format (HT("Down %s on %d days ago. The lowest listing may be a seller dumping rather than the market -- undercutting it prices you into that."),
			bare, d.span or 0), 1, 0.5, 0.5;
	end

	if (d.pct >= ATR_HIST_SAY) then
		return string.format (HT("Up %s on %d days ago."), bare, d.span or 0), 0.5, 0.9, 0.5;
	end

	return nil;
end

-- What the store holds, for the status line.
function Atr_Hist_Stats ()

	local db = Atr_Hist_DB ();
	if (db == nil) then return nil; end

	local names, samples, bytes = 0, 0, 0;
	local _, packed;
	for _, packed in pairs (db.p) do
		names   = names + 1;
		bytes   = bytes + #packed;
		samples = samples + 1;
		local c;
		for c in string.gmatch (packed, ";") do samples = samples + 1; end
	end

	return { names = names, samples = samples, bytes = bytes };
end

-- ===========================================================================
-- /atrhistory
--
-- `show` prints into a COPY BOX and not into chat, and the reason is the rule in
-- CLAUDE.md: chat text cannot be selected on this client, so a diagnostic that
-- prints there can only come back as a screenshot.
--
-- That this diagnostic exists at all is the exception the same rule allows for,
-- and the justification is specific: stage 1 deliberately ships with NO reader,
-- so without a way to look at the store there is no way to know it is recording
-- anything until stage 2 is built on top of it.
-- ===========================================================================

-- PLAIN TEXT, not zc.priceToMoneyString, and that is the whole point of it:
-- every money formatter in this addon renders coins as TEXTURES, which look
-- right on screen and copy out of an EditBox as nothing at all -- the first real
-- run of this box pasted back "58  00" where it meant 58 gold.  A copy box whose
-- text does not survive being copied has not delivered anything.
local function Hist_Money (c)

	c = math.floor (tonumber (c) or 0);

	local g  = math.floor (c / 10000);
	local s  = math.floor ((c % 10000) / 100);
	local cp = c % 100;

	return string.format ("%dg %02ds %02dc", g, s, cp);
end

function Atr_Hist_Report ()

	if (zc == nil or zc.msg_atr == nil) then return; end

	if (not Atr_Hist_Available ()) then
		zc.msg_atr (HT("market history: the companion addon is not installed, so nothing can be recorded"));
		zc.msg_atr (HT("install the Auctionator-Finder-Ascension-History folder beside this one"));
		return;
	end

	local st = Atr_Hist_Stats ();
	local on = Atr_Hist_Enabled ();

	zc.msg_atr (string.format (HT("market history: %s -- %d items, %d samples, %d KB packed"),
		on and HT("on") or HT("off"),
		(st and st.names) or 0, (st and st.samples) or 0,
		math.floor (((st and st.bytes) or 0) / 1024)));

	if (not on) then
		zc.msg_atr (HT("/atrhistory on -- or Interface > AddOns > Auctionator > Scanning"));
	end
end

function Atr_Hist_Show (name)

	name = tostring (name or ""):gsub ("^%s+", ""):gsub ("%s+$", "");
	name = name:match ("%[(.-)%]") or name;

	if (name == "") then return false; end

	local s = Atr_Hist_Series (name);

	local out = { name, "" };

	if (#s == 0) then
		tinsert (out, "(nothing recorded)");
	else
		tinsert (out, "day\tage\tscans\tprice           copper      book");
		local i;
		for i = 1, #s do
			tinsert (out, string.format ("%d\t%dd\t%d\t%-16s%-12d%s",
				s[i].d, s[i].age or 0, s[i].n or 1, Hist_Money (s[i].p), s[i].p,
				s[i].thin and ("thin("..s[i].thin..")") or
				((s[i].span or 1) > 1 and ("week of "..s[i].span) or "")));
		end
	end

	if (type (Atr_An_ShowDebugBox) == "function") then
		return Atr_An_ShowDebugBox (HT("Market history -- Ctrl+C to copy"), table.concat (out, "\n"));
	end

	return false;
end

-- THE EVIDENCE FOR DELETING THE MEAN DATABASE (item 31, stage 5).
--
-- `HISTORY-STORE.md` §4.2 promised this decision would be taken on data rather
-- than on a feeling, after the history had proven itself on a real account. This
-- is the data: how many of the mean database's rows could ever have been a
-- median, how many the new floor now suppresses, how much of it the history
-- already covers, and -- for the names where both can answer -- how far apart
-- the two figures are.
--
-- It is a report, not an action. Nothing here deletes anything.
function Atr_Hist_Audit ()

	local out = {};
	local function say (t) tinsert (out, tostring (t)); end

	local db = Atr_Hist_DB ();

	local hist, histUsable = 0, 0;
	if (db) then
		local nm, packed;
		for nm, packed in pairs (db.p) do
			hist = hist + 1;
			local n = 1;
			local c;
			for c in string.gmatch (packed, ";") do n = n + 1; end
			if (n >= 3) then histUsable = histUsable + 1; end
		end
	end

	local one, two, many, rows = 0, 0, 0, 0;
	local both, agree, off10, off50 = 0, 0, 0, 0;

	if (type (gAtr_MeanDB) == "table" and type (Atr_MeanCount) == "function") then

		local nm, v;
		for nm, v in pairs (gAtr_MeanDB) do

			rows = rows + 1;
			local n = Atr_MeanCount (v);

			if     (n <= 1) then one  = one + 1;
			elseif (n == 2) then two  = two + 1;
			else                 many = many + 1; end

			-- where BOTH can answer, how far apart are they
			local hm = Atr_Hist_Median (nm);
			local mm = (n >= 3) and Atr_MeanMedian (v) or nil;

			if (hm and mm and mm > 0) then
				both = both + 1;
				local diff = math.abs (hm - mm) / mm;
				if     (diff <= 0.10) then agree = agree + 1;
				elseif (diff <= 0.50) then off10 = off10 + 1;
				else                       off50 = off50 + 1; end
			end
		end
	end

	say ("MEAN PRICE DATABASE -- does it still earn its rows?");
	say ("");
	say (string.format ("rows                     %d", rows));
	say (string.format ("  one sample only        %d   (never was a median; now suppressed)", one));
	say (string.format ("  two samples            %d   (also suppressed)", two));
	say (string.format ("  three or more          %d   (still shown)", many));
	say ("");
	say (string.format ("MARKET HISTORY items      %d", hist));
	say (string.format ("  with 3+ days           %d   (can answer instead)", histUsable));
	say ("");
	say ("WHERE BOTH CAN ANSWER");
	say (string.format ("  compared               %d", both));
	say (string.format ("  within 10%%             %d", agree));
	say (string.format ("  10-50%% apart           %d", off10));
	say (string.format ("  more than 50%% apart    %d", off50));
	say ("");
	say ("Read it as: the first block is how much of that database could ever have");
	say ("been a median at all. The last block is whether the two disagree enough to");
	say ("matter -- if they mostly agree, the old one is redundant rather than wrong,");
	say ("and it can go once the history covers the same names.");

	if (type (Atr_An_ShowDebugBox) == "function") then
		return Atr_An_ShowDebugBox (HT("Market history audit -- Ctrl+C to copy"), table.concat (out, "\n"));
	end

	return false;
end

function Atr_Hist_Clear ()

	local db = Atr_Hist_DB ();
	if (db == nil) then return false; end

	db.p = {};
	db.n = 0;

	return true;
end

if (SlashCmdList) then
	SLASH_ATRHISTORY1 = "/atrhistory";
	SlashCmdList["ATRHISTORY"] = function (msg)

		local raw   = tostring (msg or "");
		local first = raw:lower():match ("^%s*(%a+)");

		if (first == "on" or first == "off") then
			Atr_Hist_SetEnabled (first == "on");
			if (Fdr_Options_Sync) then Fdr_Options_Sync (); end
			Atr_Hist_Report ();
			return;
		end

		if (first == "audit") then
			Atr_Hist_Audit ();
			return;
		end

		if (first == "clear") then
			Atr_Hist_Clear ();
			if (zc and zc.msg_atr) then zc.msg_atr (HT("market history cleared")); end
			Atr_Hist_Report ();
			return;
		end

		if (first == "show") then
			local rest = raw:gsub ("^%s*[Ss][Hh][Oo][Ww]%s*", "", 1);
			if (not Atr_Hist_Show (rest)) then
				if (zc and zc.msg_atr) then zc.msg_atr (HT("usage: /atrhistory show <item name or shift-clicked link>")); end
			end
			return;
		end

		Atr_Hist_Report ();
	end
end
