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
-- IT SHIPS DARK AND OFF.  Nothing reads it yet, on purpose: a week of ordinary
-- play then leaves real data for the readers to be built against instead of an
-- empty table.  The switch is off by default, so an install that does not ask
-- for this pays one boolean check per scanned name and nothing else.
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
local ATR_HIST_DAYS     = 30;		-- days of daily samples kept per name
local ATR_HIST_MAX      = 40;		-- ... and a hard sample cap behind it
local ATR_HIST_TRIM_AT  = 620;		-- decode+trim only once a string passes this
local ATR_HIST_NAMECAP  = 8000;		-- backstop: the feed itself is bounded by the AH

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

local function Hist_Rec (d, p, n)
	if (n and n > 1) then return d..":"..p..":"..n; end
	return d..":"..p;
end

-- One packed string -> { {d, p, n}, ... }, oldest first.  Malformed records are
-- dropped rather than guessed at: this is a store that regrows, so throwing one
-- bad record away costs a day and inventing a number costs the reader's trust.
function Atr_Hist_Decode (packed)

	local out = {};
	if (type (packed) ~= "string" or packed == "") then return out; end

	local rec;
	for rec in string.gmatch (packed, "[^;]+") do
		local d, p, n = string.match (rec, "^(%d+):(%d+):?(%d*)$");
		d = tonumber (d);
		p = tonumber (p);
		if (d and p and p > 0) then
			tinsert (out, { d = d, p = p, n = tonumber (n) or 1 });
		end
	end

	return out;
end

local function Hist_Encode (series)

	local parts = {};
	local i;
	for i = 1, #series do
		parts[i] = Hist_Rec (series[i].d, series[i].p, series[i].n);
	end

	return table.concat (parts, ";");
end

-- Drop what is past the age limit, then what is past the sample cap, oldest
-- first.  Only ever called just after today's record was written, so the newest
-- entry always survives and the result is never empty.
local function Hist_Trim (packed, today)

	local s    = Atr_Hist_Decode (packed);
	local keep = {};

	local i;
	for i = 1, #s do
		if (today - s[i].d <= ATR_HIST_DAYS) then tinsert (keep, s[i]); end
	end

	while (#keep > ATR_HIST_MAX) do tremove (keep, 1); end

	if (#keep == 0) then return packed; end

	return Hist_Encode (keep);
end

-- The newest day in a packed string, without decoding the rest of it.
local function Hist_LastRec (packed)

	local last = string.match (packed or "", "[^;]+$");
	if (last == nil) then return nil, nil; end

	local d, p, n = string.match (last, "^(%d+):(%d+):?(%d*)$");
	if (d == nil) then return nil, last; end

	return { d = tonumber (d), p = tonumber (p), n = tonumber (n) or 1 }, last;
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
function Atr_Hist_Note (name, price, now)

	if (not Atr_Hist_Enabled ()) then return false; end

	local db = Atr_Hist_DB ();
	if (db == nil) then return false; end

	if (type (name) ~= "string" or name == "") then return false; end

	price = math.floor (tonumber (price) or 0);
	if (price <= 0) then return false; end

	local day    = Hist_Day (now);
	local packed = db.p[name];

	if (type (packed) ~= "string" or packed == "") then
		db.p[name] = Hist_Rec (day, price, 1);
		db.n = (db.n or 0) + 1;
		if (db.n > ATR_HIST_NAMECAP) then Atr_Hist_PruneNames (db, day); end
		return true;
	end

	local rec, raw = Hist_LastRec (packed);

	if (rec == nil) then
		-- the tail is not a record we wrote: start again rather than append to
		-- something we cannot read back
		db.p[name] = Hist_Rec (day, price, 1);
		return true;

	elseif (rec.d == day) then
		-- the day's CLOSE is its newest reading; n says how many backed it
		db.p[name] = string.sub (packed, 1, #packed - #raw)..Hist_Rec (day, price, rec.n + 1);

	elseif (day > rec.d) then
		db.p[name] = packed..";"..Hist_Rec (day, price, 1);

	else
		-- the clock went backwards.  Refusing costs one sample; appending out of
		-- order would corrupt every later read of this name.
		return false;
	end

	if (#db.p[name] > ATR_HIST_TRIM_AT) then
		db.p[name] = Hist_Trim (db.p[name], day);
	end

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

local function Hist_Money (c)
	if (zc and zc.priceToMoneyString) then return zc.priceToMoneyString (c); end
	return tostring (c);
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
		tinsert (out, "day\tage\tscans\tprice");
		local i;
		for i = 1, #s do
			tinsert (out, string.format ("%d\t%dd\t%d\t%s   (%d copper)",
				s[i].d, s[i].age or 0, s[i].n or 1, Hist_Money (s[i].p), s[i].p));
		end
	end

	if (type (Atr_An_ShowDebugBox) == "function") then
		return Atr_An_ShowDebugBox (HT("Market history -- Ctrl+C to copy"), table.concat (out, "\n"));
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
