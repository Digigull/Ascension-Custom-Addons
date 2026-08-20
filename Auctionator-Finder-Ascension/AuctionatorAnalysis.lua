-- ANALYSIS: what is actually MOVING, not just what it is worth ------------------
--
-- BACKLOG item 8.  Every price this addon knows answers "what is this worth".
-- None of them answer "is anyone buying it", and for deciding what to farm that
-- is the more useful question: an item at 50g that moves once a week is worse
-- than one at 5g that moves twenty times a day, and no price database can tell
-- those apart.
--
-- THE IDEA IS THE OWNER'S (2026-08-19): watch a set of items, count how many
-- distinct sellers list each one, and see whether a given seller's listing is
-- GONE at the next scan or still sitting there.  Gone means the market took it;
-- still there means it did not.
--
-- WHAT MAKES IT RIGOROUS: a listing that vanished did not necessarily sell -- it
-- may have expired -- and counting expiries as sales would inflate every number
-- on this tab.  The client's own countdown separates them.  Each bucket carries
-- a MINIMUM remaining life:
--
--     1 Short      < 30m      min 0
--     2 Medium     30m - 2h   min 30m
--     3 Long       2h  - 12h  min 2h
--     4 Very Long  > 12h      min 12h
--
-- So if a listing was last seen on bucket B and less than B's minimum has
-- elapsed since, it CANNOT have expired in the gap -- it was bought (or
-- cancelled).  Anything else is counted as AMBIGUOUS and never as a sale.  That
-- costs nothing: the Finder already reads GetAuctionItemTimeLeft for its Time
-- column, so this is arithmetic over data already on hand.
--
-- LIMITS, by construction rather than by oversight -- the tab states them:
--
--   * Turnover is a FLOOR, never a count.  A listing posted and sold between two
--     scans is invisible; two scans two hours apart cannot see a listing that
--     lived twenty minutes.
--   * Only what you scan.  getAll is disabled on this server, so coverage is
--     whatever you searched -- which is why the watchlist is the unit of
--     analysis rather than a convenience.
--   * Rates are per ELAPSED TIME, not per scan, because scan cadence is
--     irregular and user-driven.  "3 sold since last scan" means nothing without
--     the interval.
--   * `owner` can come back nil from the API (AtrSearch:ProcessBatch counts
--     numNilOwners for this reason), so unknown sellers are tracked apart rather
--     than collapsed into one.
--
-- THREE VIEWS OVER ONE TABLE.  Everything above is an ESTIMATE inferred from
-- listings that vanished.  The other two views are not, and the tab keeps the
-- three apart rather than mixing them into one table: a fact printed in the same
-- row as an estimate reads as an estimate.
--
--   Market     the watchlist above -- what the market is doing, from scanning.
--   My trades  (group D, 2026-08-20) your own paid, got, margin and sell-through
--              per item, out of the Ledger by Atr_Ledger_ItemTotals: money that
--              actually moved.
--   Crafting   (B2, 2026-08-20) every recipe this account has harvested, ranked
--              by what one craft is worth -- Atr_Craft_ProfitRanking, in
--              AuctionatorFinderProfession.lua.  Neither an estimate nor a fact:
--              arithmetic over today's prices, exact if the prices are current.
--
-- ONE FILTER BOX serves all three: it narrows whichever table is up, live, as
-- you type, and it deliberately survives a view switch -- "show me the linen" is
-- the same question on any of them.  The box used to be for ADDING a watched
-- item, which is a once-per-item job; that moved to a popup behind the Add
-- button beside it.
--
-- EVERY ROW BEHAVES THE SAME WAY in all three views, because they are all the
-- same kind of thing -- an item you are deciding about.  Hover shows the item's
-- own tooltip (and, on the crafting view, a second tooltip beside it with the
-- reagents and the figures); left click looks the item up, gear on the Finder
-- tab and everything else on Buy; right click opens the list menu.  See
-- An_RowLink / An_OpenItem below for why those two tabs and not one.
--
-- Every column in all three sorts: click a header, click it again to reverse,
-- the way the Finder tab's headers have always worked.  Each view keeps its own
-- key, and a cell with nothing in it sorts last in both directions rather than
-- as a zero -- see the sorting block below for why that is not a detail.
--
-- This file owns only the views; the arithmetic and the reasoning behind each
-- figure live with the rows, in AuctionatorLedger.lua and
-- AuctionatorFinderProfession.lua respectively.
--
-- Storage: AUCTIONATOR_ANALYSIS, account-wide, declared in the .toc.  The other
-- two views add none of their own -- they are readers of AUCTIONATOR_LEDGER and
-- AUCTIONATOR_CRAFT_RECIPES.

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

local function AZT (s)
	if (ZT) then return ZT (s); end
	return s;
end

-- Minimum seconds of life left implied by each time-left bucket.
local ATR_AN_MIN_LEFT = { [1] = 0, [2] = 1800, [3] = 7200, [4] = 43200 };

-- A watched item stops accumulating if it goes unscanned for this long -- the
-- gap says nothing about the market, only about the player, and folding it into
-- a rate would quietly drag every number toward zero.
local ATR_AN_MAX_GAP = 3 * 24 * 60 * 60;

local ATR_AN_UNKNOWN_SELLER = "?";

function Atr_An_DB ()

	if (type (AUCTIONATOR_ANALYSIS) ~= "table") then AUCTIONATOR_ANALYSIS = {}; end

	local db = AUCTIONATOR_ANALYSIS;
	if (db.ver == nil) then db.ver = 1; end
	if (type (db.groups) ~= "table") then db.groups = {}; end
	if (type (db.watch)  ~= "table") then db.watch  = {}; end
	if (type (db.obs)    ~= "table") then db.obs    = {}; end
	if (type (db.ids)    ~= "table") then db.ids    = {}; end

	return db;
end

-- WATCHLIST ---------------------------------------------------------------

function Atr_An_IsWatched (itemName)
	if (type (itemName) ~= "string") then return false; end
	return (Atr_An_DB ().watch[itemName] ~= nil);
end

function Atr_An_Watch (itemName, group)

	if (type (itemName) ~= "string" or itemName == "") then return false; end

	local db = Atr_An_DB ();
	if (db.watch[itemName]) then
		if (group) then db.watch[itemName].group = group; end
		return false;						-- already watched
	end

	db.watch[itemName] = { group = group, added = (time and time()) or 0 };
	return true;
end

function Atr_An_Unwatch (itemName)
	local db = Atr_An_DB ();
	if (db.watch[itemName] == nil) then return false; end
	db.watch[itemName] = nil;
	db.obs[itemName]   = nil;				-- its history means nothing without it
	return true;
end

function Atr_An_AddGroup (name)

	if (type (name) ~= "string" or name == "") then return false; end

	local db = Atr_An_DB ();
	local i;
	for i = 1, #db.groups do
		if (db.groups[i] == name) then return false; end
	end

	tinsert (db.groups, name);
	table.sort (db.groups);
	return true;
end

-- WHAT THE CLIENT NEEDS TO DRAW A TOOLTIP, AND WHY IT SO OFTEN HAS NEITHER --
--
-- A tooltip needs an item ID. This tab's three views mostly have a NAME: the
-- watchlist is keyed by one, and so is every enchant recipe (an enchant makes no
-- item, so its record is filed under the scroll it sells as). GetItemInfo can
-- turn a name into a link, but only for an item the CLIENT has cached, and it
-- caches what it has seen -- which is why a fresh session showed no tooltip
-- until something was looked up, and why the same item needed looking up again
-- the next session (owner's report, 2026-08-20: Essence of Earth on the market
-- view, and the Scroll of Enchant rows on the crafting view).
--
-- The client cannot be asked "what ID is this name" -- but this addon has been
-- writing that answer down for months without anybody noticing, in three saved
-- tables it keeps for other reasons:
--
--   * every REAGENT of every harvested recipe carries an id AND a name, because
--     the profession harvest stores both (a reagent link can come back nil on
--     this client, so the name is its fallback).  That is a name -> id map of
--     every trade good the player's professions use -- Essence of Earth among
--     them -- built by opening a profession window once;
--   * every LEDGER row carries both, since Atr_Ledger_Add resolves the id off
--     the link when it records the trade;
--   * every watched item that has been observed carries the id this file
--     started storing with item 26.
--
-- So the index is assembled from those, once per session, at no storage cost --
-- and anything NEW that gets resolved from a real link is written to a small
-- saved map of our own, so one lookup is the last one that item ever needs.
--
-- That map is GATED to names this tab could actually draw (watched, or a
-- harvested recipe), which bounds it at a few hundred entries: an ungated
-- name -> id cache fed by a category sweep is thousands of rows of saved
-- variable, and item 13 was spent clawing back exactly that kind of weight.
local gAn_IdIndex = nil;		-- name -> id, in memory, one build per session

local function An_IdFromLink (link)

	if (type (link) ~= "string" or zc == nil or zc.ItemIDfromLink == nil) then return nil; end

	return tonumber ((zc.ItemIDfromLink (link)));		-- extra parens: returns 3 values
end

local function An_IdIndexBuild ()

	local idx = {};
	local db  = Atr_An_DB ();

	local nm, v;

	-- what we have already learned and saved
	for nm, v in pairs (db.ids) do
		if (type (v) == "number") then idx[nm] = v; end
	end

	-- watched items, from their own observations
	for nm, v in pairs (db.obs) do
		if (type (v) == "table" and v.id and idx[nm] == nil) then idx[nm] = v.id; end
	end

	-- the ledger: every row it kept carries a name and the id it resolved
	if (type (AUCTIONATOR_LEDGER) == "table" and type (AUCTIONATOR_LEDGER.rows) == "table") then
		local i, row;
		for i = 1, #AUCTIONATOR_LEDGER.rows do
			row = AUCTIONATOR_LEDGER.rows[i];
			if (type (row) == "table" and row.name and row.id and idx[row.name] == nil) then
				idx[row.name] = row.id;
			end
		end
	end

	-- every reagent of every harvested recipe
	if (type (AUCTIONATOR_CRAFT_RECIPES) == "table") then
		local _, rec, rg;
		for _, rec in pairs (AUCTIONATOR_CRAFT_RECIPES) do
			if (type (rec) == "table" and type (rec.reagents) == "table") then
				for _, rg in ipairs (rec.reagents) do
					if (type (rg) == "table" and rg.id and rg.name and idx[rg.name] == nil) then
						idx[rg.name] = rg.id;
					end
				end
			end
		end
	end

	return idx;
end

-- Is this a name the tab could actually draw?  The gate on what gets SAVED, and
-- on whether a scan is worth asking the auction API for a link.  A recipe key
-- covers the case that prompted it: "Scroll of Enchant Boots - Speed" is a
-- crafting row and nothing else in the addon can resolve its ID.
local function An_IdWanted (itemName)

	if (Atr_An_IsWatched (itemName)) then return true; end

	return (type (AUCTIONATOR_CRAFT_RECIPES) == "table"
			and AUCTIONATOR_CRAFT_RECIPES[itemName] ~= nil);
end

function Atr_An_IdForName (itemName)

	if (type (itemName) ~= "string" or itemName == "") then return nil; end

	if (gAn_IdIndex == nil) then gAn_IdIndex = An_IdIndexBuild (); end

	return gAn_IdIndex[itemName];
end

-- Remember a name -> id resolved from a real link.  Global so the feed above can
-- call it; see the gate comment for why not everything is kept.
function Atr_An_LearnId (itemName, id)

	id = tonumber (id);
	if (type (itemName) ~= "string" or itemName == "" or id == nil) then return; end

	if (gAn_IdIndex == nil) then gAn_IdIndex = An_IdIndexBuild (); end
	if (gAn_IdIndex[itemName] == id) then return; end

	gAn_IdIndex[itemName] = id;

	if (An_IdWanted (itemName)) then Atr_An_DB ().ids[itemName] = id; end
end

-- OBSERVATION -------------------------------------------------------------

-- One scan's worth of listings for ONE item.  `listings` is an array of
-- { owner, count, buyout, timeLeft } -- exactly what a Finder result row already
-- carries, so the caller does no work beyond filtering to this item.
function Atr_An_Observe (itemName, listings, now)

	if (not Atr_An_IsWatched (itemName)) then return; end
	if (type (listings) ~= "table") then return; end

	now = now or (time and time()) or 0;

	local db = Atr_An_DB ();
	local o  = db.obs[itemName];

	if (o == nil) then
		o = { fp = {}, sold = 0, amb = 0, secs = 0, scans = 0 };
		db.obs[itemName] = o;
	end

	-- this scan's multiset of listing fingerprints, and the snapshot numbers
	local cur, sellers, low, n = {}, {}, nil, 0;

	local i;
	for i = 1, #listings do

		local L = listings[i];
		local qty = tonumber (L.count) or 1;
		if (qty < 1) then qty = 1; end

		local owner = L.owner or ATR_AN_UNKNOWN_SELLER;
		local buy   = tonumber (L.buyout) or 0;

		-- Identity is the seller, the stack and the price.  Two identical
		-- listings from one seller are indistinguishable -- the same problem the
		-- Ledger's mail sweep has -- so they are COUNTED rather than set-merged.
		local key = tostring (owner).."\1"..tostring (qty).."\1"..tostring (buy);

		local e = cur[key];
		if (e == nil) then cur[key] = { n = 1, tl = tonumber (L.timeLeft) or 0 };
		else e.n = e.n + 1; end

		if (owner ~= ATR_AN_UNKNOWN_SELLER) then sellers[owner] = true; end

		-- One number, once, and it is what makes a watched item hoverable: the
		-- watchlist is keyed by NAME and a name cannot draw a tooltip. Taken from
		-- the first listing that carries a link and never revisited -- a same-name
		-- variant is a different instance of the same item, so any of them names
		-- the right thing to show.
		if (o.id == nil and L.link) then
			o.id = An_IdFromLink (L.link);
		end

		if (buy > 0) then
			local unit = math.floor (buy / qty);
			if (unit > 0 and (low == nil or unit < low)) then low = unit; end
		end

		n = n + 1;
	end

	-- Diff against the previous scan.  Only a gap we can reason about counts:
	-- too long and the elapsed time says more about the player than the market.
	local elapsed = (o.last and (now - o.last)) or nil;

	if (elapsed and elapsed > 0 and elapsed <= ATR_AN_MAX_GAP) then

		local key, prev;
		for key, prev in pairs (o.fp) do

			local still = cur[key];
			local gone  = prev.n - ((still and still.n) or 0);

			if (gone > 0) then
				-- Could this listing have expired in the gap?  Only if more time
				-- passed than its last-seen bucket guarantees it had left.
				local minLeft = ATR_AN_MIN_LEFT[prev.tl or 0] or 0;
				if (elapsed < minLeft) then
					o.sold = o.sold + gone;			-- it cannot have expired: bought
				else
					o.amb = o.amb + gone;			-- sold or expired, unknowable
				end
			end
		end

		o.secs  = (o.secs or 0) + elapsed;
	end

	o.fp		= cur;
	o.last		= now;
	o.scans		= (o.scans or 0) + 1;
	o.listings	= n;
	o.low		= low;

	local ns = 0;
	local k;
	for k in pairs (sellers) do ns = ns + 1; end
	o.sellers = ns;

	-- seller concentration: the largest share one seller holds of the listings
	local most = 0;
	local counts = {};
	for key, e in pairs (cur) do
		local owner = key:match ("^(.-)\1");
		if (owner and owner ~= ATR_AN_UNKNOWN_SELLER) then
			counts[owner] = (counts[owner] or 0) + e.n;
			if (counts[owner] > most) then most = counts[owner]; end
		end
	end
	o.topShare = (n > 0) and (most / n) or 0;
end

-- READING -----------------------------------------------------------------

-- Everything the tab shows for one item, or nil when it has never been scanned.
function Atr_An_Stats (itemName)

	local o = Atr_An_DB ().obs[itemName];
	if (o == nil) then return nil; end

	local days = (o.secs or 0) / 86400;

	local perDay, perDayMax = nil, nil;
	if (days > 0) then
		perDay    = (o.sold or 0) / days;
		perDayMax = ((o.sold or 0) + (o.amb or 0)) / days;
	end

	-- Farm score: gold per day this item would have returned at its current
	-- lowest price, IF you had supplied the sales we can attribute.  A rate, not
	-- a promise.
	--
	-- Reported as a RANGE, and that is not hedging -- it is the honest shape of
	-- the evidence.  The low end counts only listings that provably could not
	-- have expired; the high end also counts the ambiguous ones.  How far apart
	-- they sit is decided by YOUR SCAN CADENCE, not by the market: a listing on
	-- Very Long is only a certain sale if you look again within 12 hours, and one
	-- on Long within 2.  Scan twice a day and almost everything is ambiguous;
	-- scan every couple of hours -- which is what the owner described wanting --
	-- and the range collapses onto the real number.
	--
	-- Showing only the low end would read as "nothing sells here" for anyone who
	-- scans slowly, which is a statement about them and not about the item.
	local farm, farmMax = nil, nil;
	if (perDay and o.low) then
		farm    = perDay * o.low;
		farmMax = perDayMax * o.low;
	end

	return {
		id			= o.id,
		sellers		= o.sellers or 0,
		listings	= o.listings or 0,
		low			= o.low,
		sold		= o.sold or 0,
		amb			= o.amb or 0,
		perDay		= perDay,
		perDayMax	= perDayMax,
		farm		= farm,
		farmMax		= farmMax,
		topShare	= o.topShare or 0,
		secs		= o.secs or 0,
		scans		= o.scans or 0,
		last		= o.last,
	};
end

-- FEEDING IT --------------------------------------------------------------

-- Called with a whole result set (the Finder's, whose rows already carry owner,
-- timeLeft, count and buyoutPrice).  Groups the rows by item name and observes
-- every watched one -- so the watchlist fills in from ordinary searching rather
-- than needing a scanner of its own.
function Atr_An_ObserveResults (results)

	if (type (results) ~= "table") then return 0; end

	local byName = {};
	local i;
	for i = 1, #results do
		local r = results[i];

		-- Learn the name -> id here, for EVERY result and not just the watched
		-- ones: this is the only place the addon sees a live link beside the name
		-- it was listed under, and the crafting view's enchant rows -- keyed by a
		-- scroll name nothing else can resolve -- are exactly what needs it.  The
		-- gate inside decides what is worth keeping.
		if (r and r.name and r.link and Atr_An_IdForName (r.name) == nil) then
			Atr_An_LearnId (r.name, An_IdFromLink (r.link));
		end

		if (r and r.name and Atr_An_IsWatched (r.name)) then
			local t = byName[r.name];
			if (t == nil) then t = {}; byName[r.name] = t; end
			tinsert (t, { owner = r.owner, count = r.count, buyout = r.buyoutPrice, timeLeft = r.timeLeft,
						  link = r.link });
		end
	end

	local now, n = (time and time()) or 0, 0;
	local name, rows;
	for name, rows in pairs (byName) do
		Atr_An_Observe (name, rows, now);
		n = n + 1;
	end

	return n;
end

-- The Finder is not the only thing that scans.  Every SEARCH the addon runs --
-- Buy, Sell, More -- walks the same listings through AtrSearch:AnalyzeResultsPage,
-- and that loop is the only place a listing's owner, stack, price and time-left
-- are all in scope at once.  So it collects them here (BACKLOG item 17) and the
-- search hands the set over when it finishes.
--
-- WHY NOT OBSERVE PER PAGE: a listing missing from the set is what "sold" MEANS.
-- Observing half a scan would report every listing on the pages not yet fetched
-- as bought, so the set is banked until the search is known to be complete.
function Atr_An_CollectListing (srch, itemName, owner, count, buyout, index)

	if (type (srch) ~= "table" or type (itemName) ~= "string") then return; end

	-- EVERY scan passes through here, which makes it the one place a crafting
	-- row's scroll can learn its own ID: a scroll is not gear, so looking one up
	-- lands on the Buy tab, which never reaches the Finder's result feed.  Two
	-- table lookups per listing in the ordinary case -- the API call happens only
	-- for a name this tab can draw and cannot already resolve.
	if (An_IdWanted (itemName) and Atr_An_IdForName (itemName) == nil
		and index and type (GetAuctionItemLink) == "function") then
		Atr_An_LearnId (itemName, An_IdFromLink (GetAuctionItemLink ("list", index)));
	end

	if (not Atr_An_IsWatched (itemName)) then return; end

	local bag = srch.anListings;
	if (bag == nil) then bag = {}; srch.anListings = bag; end

	local tl, link = 0, nil;
	if (index) then
		if (type (GetAuctionItemTimeLeft) == "function") then
			tl = GetAuctionItemTimeLeft ("list", index) or 0;
		end
		-- The item's LINK, kept for one reason: the watchlist stores a name, and
		-- a name alone cannot draw a tooltip. Atr_An_Observe reads the ID off it
		-- once and remembers that, so a watched item is hoverable from then on
		-- -- including in a later session, before anything has been scanned.
		if (type (GetAuctionItemLink) == "function") then
			link = GetAuctionItemLink ("list", index);
		end
	end

	tinsert (bag, { name = itemName, owner = owner, count = count, buyoutPrice = buyout, timeLeft = tl, link = link });
end

-- Hand a finished search's collected listings to the analysis, or throw them
-- away.  Called from AtrSearch:Finish, which a WATCHDOG can also reach on a
-- stalled search -- so completeness is asserted by the batch loop rather than
-- assumed from being here at all.
function Atr_An_ObserveSearch (srch)

	if (type (srch) ~= "table") then return 0; end

	local rows = srch.anListings;
	srch.anListings = nil;			-- consumed either way: never observe one scan twice

	if (rows == nil or #rows == 0) then return 0; end

	-- Not a full result set.  Either the search stopped early (too many results,
	-- duplicate pages, a watchdog) or a page is still outstanding.
	if (not srch.anComplete) then return 0; end

	-- A level-filtered query returns a SUBSET of an item's listings, and on this
	-- server that is not hypothetical: gear scales per instance, so one item's
	-- listings carry many required levels.  The ones outside the filter would
	-- read as sold.
	if (srch.anLevelFiltered) then return 0; end

	return Atr_An_ObserveResults (rows);
end

-- THE TAB -----------------------------------------------------------------
--
-- Own panel on its own main tab, the same shape as the Ledger and for the same
-- reason (FRAMEWORK.md §4, World 2): the shared panel is built around one
-- scanned item, and this is a view across many.  Wiring sites in
-- Auctionator.lua are tagged `-- ANALYSIS_TAB`.

local AN_NUM_ROWS = 14;
local AN_ROW_H    = 20;
local AN_ROW_W    = 660;		-- a placeholder: Atr_An_Init recomputes it from the real window

-- ONE definition of the columns, used to build the headers, the cells AND the
-- sort.  The first two were separate lists and had drifted apart: every header
-- sat at the LEFT edge of a column whose value was centred or right-aligned, so
-- nothing lined up, and the right-hand pair overlapped -- "Low" ran under the
-- "Gold/day" header and "Gold/day" ran under the per-row delete button.
-- Deriving all three from this table is what stops that happening again: a
-- column that cannot be sorted is now a column with no `val`, which is a thing
-- you can see here rather than a case someone forgot to add somewhere else.
--
-- `w` is a column's MINIMUM width and `grow` its share of whatever the window
-- has spare; An_LayoutCols fills in `cx`/`cw`, which are the numbers actually
-- used.  Those were fixed x positions summing to a 660px row, and 660 is only
-- right on Blizzard's 768px auction house: Ascension's is wider, so the right
-- third of the tab sat empty while the two money columns were squeezed hard
-- enough to wrap onto two lines.  Nothing here may assume a window width.
--
-- Sold/day and Gold/day are the greedy ones because they are the two that can
-- print a RANGE -- "279g 10s-310g 28s" is twice the width of the value beside
-- it, and a cell that overflows wraps onto a second line rather than clipping.
--
-- A header is the same cx shifted by the scroll frame's own inset (AN_HEAD_X0).
local AN_HEAD_X0  = 14;
local AN_LEAD     = 6;		-- gap before the first column
local AN_COL_GAP  = 4;		-- gap between columns
local AN_DEL_LANE = 26;		-- the delete button's own lane at the end of a row
local AN_SB_LANE  = 26;		-- what the scroll bar needs to the RIGHT of the scroll frame

--
-- `val` is what the column SORTS on (see An_SortRows).  It returns nil for a
-- cell with nothing in it, and nil always sorts last -- the rule the whole tab
-- already followed by hand: an item that has never been scanned has not sold
-- nothing, it has told us nothing, and ranking it as the worst row would be a
-- statement about the market that the data does not support.
--
-- Sold/day and Gold/day sort on the UPPER bound of their range for the reason
-- the original ranking did: for anyone scanning slowly the lower bound is zero
-- on almost every item, and a ranking where everything ties is no ranking.
local AN_COLS = {
	{ key = "item",		head = "Item",		w = 184, grow = 3,					text = true,
	  val = function (r) return string.lower (r.name or ""); end },
	{ key = "grp",		head = "Group",		w = 74,  grow = 1,					text = true,
	  val = function (r) return (r.group and r.group ~= "") and string.lower (r.group) or nil; end },
	{ key = "sellers",	head = "Sellers",	w = 48,  grow = 0, just = "CENTER",
	  val = function (r) return r.st and r.st.scans > 0 and r.st.sellers or nil; end },
	{ key = "listings",	head = "Listings",	w = 54,  grow = 0, just = "CENTER",
	  val = function (r) return r.st and r.st.scans > 0 and r.st.listings or nil; end },
	{ key = "rate",		head = "Sold/day",	w = 80,  grow = 2, just = "CENTER",
	  tip = "An estimate. Counted from listings that disappeared between two scans, so it is a floor, not an exact count.",
	  val = function (r) return r.st and r.st.perDay and r.st.perDayMax or nil; end },
	{ key = "low",		head = "Low",		w = 84,  grow = 1, just = "RIGHT",
	  -- the scans guard matches the cell: an unscanned row prints "--" here, and
	  -- what prints "--" sorts as unknown
	  val = function (r) return r.st and r.st.scans > 0 and r.st.low or nil; end },
	{ key = "farm",		head = "Gold/day",	w = 96,  grow = 4, just = "RIGHT",
	  tip = "An estimate: Sold/day valued at the current lowest price. A rate, not a promise.",
	  val = function (r) return r.st and r.st.farmMax or nil; end },
};

-- THE SECOND VIEW (BACKLOG item 8, group D): the same table, over the Ledger.
--
-- Every column above is inferred from listings that vanished between two scans.
-- Every column here is money that actually moved, which is why the two are not
-- mixed into one table: a row of estimates beside a row of facts, in matching
-- type, invites reading them as the same kind of number.  The panel, the scroll
-- frame and the rows are shared because they are the expensive part; only the
-- columns and the row builder differ.
--
-- Keys are distinct from the market view's on purpose -- each row Button carries
-- BOTH sets of FontStrings and shows one of them -- so nothing has to be
-- re-anchored when the view changes.
local AN_TCOLS = {
	{ key = "titem",	head = "Item",		w = 184, grow = 3,					text = true,
	  val = function (r) return string.lower (r.name or ""); end },
	{ key = "tbought",	head = "Bought",	w = 54,  grow = 0, just = "CENTER",
	  val = function (r) return r.boughtQty > 0 and r.boughtQty or nil; end },
	{ key = "tpaid",	head = "Paid",		w = 84,  grow = 1, just = "RIGHT",
	  tip = "What you paid, from the delivery's own invoice -- so a purchase made by hand in the auction house counts too, not just ones the Buy tab drove. A * marks an item priced from what the buy loop intended, because no delivery invoice was seen for it.",
	  val = function (r) return r.paid > 0 and r.paid or nil; end },
	{ key = "tsold",	head = "Sold",		w = 54,  grow = 0, just = "CENTER",
	  val = function (r) return r.soldQty > 0 and r.soldQty or nil; end },
	{ key = "tgot",		head = "Got",		w = 84,  grow = 1, just = "RIGHT",
	  tip = "The gold the sale actually earned: the invoice's winning bid less the auction house's cut. A returned deposit is not counted as profit.",
	  val = function (r) return r.got > 0 and r.got or nil; end },
	{ key = "tmargin",	head = "Margin",	w = 96,  grow = 3, just = "RIGHT",
	  tip = "Got minus Paid, over the rows the ledger still holds -- not an estimate. Deposits are not netted in; they are in the totals line below, because a deposit on a listing that is still up is not lost yet.",
	  -- an item that has only ever been LISTED has a margin of zero by
	  -- arithmetic and no margin in fact, which is why the cell prints "--";
	  -- sorting it among real results would push what you made off the top
	  -- spelled out, not `cond and nil or x`: that idiom returns x when the
	  -- condition holds, which is exactly backwards here
	  val = function (r) if (r.paid == 0 and r.got == 0) then return nil; end return r.margin; end },
	{ key = "tthru",	head = "Sell-through", w = 78, grow = 1, just = "CENTER",
	  tip = "Of the items whose listings resolved, how many sold rather than expired. Cancelling your own listing is your verdict, not the market's, so it counts on neither side.",
	  val = function (r) return r.sellThrough; end },
};

-- THE THIRD VIEW (BACKLOG item 8, B2): what is worth CRAFTING.
--
-- The profession window already ranks recipes by profit (the "Sort by Profit"
-- checkbox, AuctionatorFinderProfession.lua) -- but only while that window is
-- open, and it is never open at the auction house, which is where the question
-- gets asked.  This view ranks the HARVESTED recipes instead, so the answer is
-- available standing at the mailbox.  Atr_Craft_ProfitRanking does the
-- arithmetic and carries the reasoning; this is its table.
--
-- Money columns are PER ITEM and the ranked one is PER CRAFT, which is the same
-- split the trade skill window's own column uses -- one craft is what one press
-- of Create costs and earns, and a recipe making 3 at 12g beats one making 1 at
-- 20g.  Makes is right beside them so the two scales are never a guess.
local AN_CCOLS = {
	{ key = "citem",	head = "Item",		w = 184, grow = 3,					text = true,
	  val = function (r) return string.lower (r.name or ""); end },
	{ key = "cmakes",	head = "Makes",		w = 48,  grow = 0, just = "CENTER",
	  tip = "How many one craft yields. A ? is a yield we assumed: the recipe came from hovering a plan rather than from your profession window, so it was read as 1 and you may not even know it yet.",
	  val = function (r) return r.made; end },
	{ key = "ccost",	head = "Cost",		w = 84,  grow = 1, just = "RIGHT",
	  tip = "What the reagents for ONE of them cost: the vendor price where a vendor sells it, otherwise the auction price you last scanned, otherwise its vendor value as a floor. Blank means one reagent has never been priced -- scan it and the row fills in.",
	  val = function (r) return r.cost; end },
	{ key = "csell",	head = "Price",		w = 84,  grow = 1, just = "RIGHT",
	  tip = "What ONE sells for, from your own scans. An enchant is priced as the scroll it is sold as, and the vellum is counted as a reagent. Blank means you have never scanned it.",
	  val = function (r) return r.sell; end },
	{ key = "cprofit",	head = "Profit/craft", w = 96, grow = 4, just = "RIGHT",
	  tip = "Price less Cost, times the yield -- what ONE press of Create is worth at today's prices. Not an estimate and not a promise: it is exact arithmetic over prices that are only as fresh as your last scan, and it assumes the sale actually happens.",
	  val = function (r) return r.perCraft; end },
	{ key = "cmargin",	head = "Margin",	w = 60,  grow = 1, just = "CENTER",
	  tip = "Profit as a share of the sale price. 40% means four gold in every ten you take is profit -- a fat margin survives being undercut, a thin one does not.",
	  -- the ratio, not the printed percent: two rows rounding to the same
	  -- whole number are still in a real order
	  val = function (r) return (r.profit and r.sell and r.sell > 0) and (r.profit / r.sell) or nil; end },
};

-- "market" (the watchlist, above), "trades" (the Ledger) or "craft" (recipes).
local gAn_View = "market";

-- Widgets that belong to the market view only, filled in by Atr_An_Init and
-- hidden wholesale when another view is up.
local gAn_MarketOnly = {};

-- Spread the columns over a row `rowW` wide: each keeps its minimum width and
-- the slack is handed out by `grow`, with the rounding remainder going to the
-- last growing column so the right edge lands exactly on the delete lane.
--
-- It takes the column table rather than reading AN_COLS because there are two of
-- them now (item 8 group D), laid out against the same row width so the two
-- views' right edges land in the same place.
local function An_LayoutCols (cols, rowW)

	local base, grow, last = 0, 0, nil;
	local i, c;
	for i, c in ipairs (cols) do
		base = base + c.w;
		if ((c.grow or 0) > 0) then grow = grow + c.grow; last = i; end
	end

	local slack = rowW - AN_LEAD - AN_DEL_LANE - AN_COL_GAP * (#cols - 1) - base;
	if (slack < 0 or grow == 0) then slack = 0; end		-- narrow window: minimums win

	local x, handed = AN_LEAD, 0;
	for i, c in ipairs (cols) do
		local add = 0;
		if (slack > 0 and (c.grow or 0) > 0) then
			if (i == last) then
				add = slack - handed;
			else
				add = math.floor (slack * c.grow / grow);
				handed = handed + add;
			end
		end
		c.cw = c.w + add;
		c.cx = x;
		x = x + c.cw + AN_COL_GAP;
	end
end

-- SORTING: CLICK A HEADER (BACKLOG item 24) --------------------------------
--
-- Click a header to sort by it, click it again to reverse.  The Finder tab has
-- worked this way since it was written and this is deliberately the same idiom
-- -- the same arrow glyphs, the same faint highlight under the cursor, the same
-- click-again-to-reverse (Fdr_MakeHeader / Fdr_HeaderClick in
-- AuctionatorFinder.lua).
--
-- THREE STATES, ONE PER VIEW.  The views share a table and nothing else, and
-- each one's default sort IS its point: the market view ranks on gold per day,
-- the ledger on what you actually made, the crafting view on what one craft is
-- worth.  Carrying one key across a view switch would land on a column the next
-- view does not have; each view keeps its own and returns to it.
--
-- A CELL WITH NOTHING IN IT SORTS LAST IN BOTH DIRECTIONS.  "not scanned", a
-- blank group, a "--" -- none of them are zeros.  Ascending by Sold/day would
-- otherwise open on a page of items nobody has ever scanned, which is a
-- statement about the watchlist and not about the market.  Each row builder
-- used to hand-roll this for its own default ordering; a column's `val`
-- returning nil is now the one place it lives.
local gAn_Sort = {
	market	= { key = "farm",    asc = false },
	trades	= { key = "tmargin", asc = false },
	craft	= { key = "cprofit", asc = false },
};

local gAn_ColsFor = { market = AN_COLS, trades = AN_TCOLS, craft = AN_CCOLS };

-- The header Buttons, per view, keyed by column.  Filled in by Atr_An_Init.
local gAn_Heads = { market = {}, trades = {}, craft = {} };

local function An_ColByKey (cols, key)

	local _, c;
	for _, c in ipairs (cols) do
		if (c.key == key) then return c; end
	end
	return nil;
end

-- Sort `rows` in place by the view's current key.  The tie-break is always the
-- name, ascending: table.sort is not stable, so without one two rows carrying
-- the same number can swap places on every redraw -- and a list that reshuffles
-- under the cursor reads as a bug rather than as a tie.
local function An_SortRows (view, rows)

	local st  = gAn_Sort[view];
	local col = st and An_ColByKey (gAn_ColsFor[view] or {}, st.key);
	local val = col and col.val;

	if (val == nil) then return rows; end

	table.sort (rows, function (a, b)

		local av, bv = val (a), val (b);

		if (av == nil or bv == nil) then
			if (av == bv) then return (a.name or "") < (b.name or ""); end
			return (av ~= nil);				-- nothing to say sorts last, either way
		end

		if (av ~= bv) then
			if (st.asc) then return av < bv; end
			return av > bv;
		end

		return (a.name or "") < (b.name or "");
	end);

	return rows;
end

-- The arrow is appended to the header's own text rather than being a second
-- FontString beside it.  A header spans its whole column and is justified like
-- the cells under it, so an arrow anchored to the label's right edge would land
-- in the NEXT column on everything right-aligned; appended, it sits with the
-- word whatever the justification.  The cost is that the sorted column's header
-- shifts by the width of a glyph, which is the column you are looking at.
local function An_UpdateArrows (view)

	local st = gAn_Sort[view];

	local key, btn;
	for key, btn in pairs (gAn_Heads[view] or {}) do
		if (btn.label and btn.head) then
			local mark = "";
			if (st and key == st.key) then
				mark = st.asc and " |cff88ccff^|r" or " |cff88ccffv|r";
			end
			btn.label:SetText (btn.head..mark);
		end
	end
end

-- Back to the top of the list.  Re-sorting under a scrolled offset leaves you
-- looking at the middle of a list you just reordered, which is exactly where
-- the rows you asked to see are not.  The bar has to move as well as the
-- offset: it is what the offset is read back from.
local function An_ScrollTop ()

	if (FauxScrollFrame_SetOffset) then FauxScrollFrame_SetOffset (Atr_An_ScrollFrame, 0); end

	local bar = _G["Atr_An_ScrollFrameScrollBar"];
	if (bar and bar.SetValue) then bar:SetValue (0); end
end

local function An_HeaderClick (view, key)

	local st = gAn_Sort[view];
	if (st == nil) then return; end

	if (st.key == key) then
		st.asc = not st.asc;
	else
		st.key = key;
		-- a name reads best A-Z; a number is being asked "which is the biggest"
		local col = An_ColByKey (gAn_ColsFor[view] or {}, key);
		st.asc = (col and col.text) and true or false;
	end

	An_UpdateArrows (view);
	An_ScrollTop ();
	Atr_An_Redisplay ();
end

local gAn_Group = nil;		-- nil = every group

-- THE FILTER BOX (owner's request, 2026-08-20) ------------------------------
--
-- The box at the top left used to ADD an item to the watchlist. Adding an item
-- is something you do once per item and then never again; narrowing what is on
-- screen is something you do constantly, and neither the crafting view (a
-- couple of hundred recipes) nor the ledger had any way to do it at all. So the
-- box filters, live, as you type, and it is the SAME box on all three views --
-- "show me the linen" is one question whichever table is up, and the filter
-- deliberately survives a view switch for that reason.
--
-- Adding moved to the button beside it, which opens a popup (item 26).
--
-- Plain substring, case-insensitive, and matched with find's plain flag: an
-- item name is full of Lua pattern characters ("Mana Potion (Superior)") and a
-- filter box that threw a pattern error on a bracket would be worse than no
-- filter at all.
local gAn_Filter = "";

local function An_PassesFilter (name)

	if (gAn_Filter == "") then return true; end
	if (type (name) ~= "string") then return false; end

	return (string.find (string.lower (name), gAn_Filter, 1, true) ~= nil);
end

local function An_SetFilter (text)

	local f = tostring (text or "");
	f = f:gsub ("^%s+", ""):gsub ("%s+$", "");
	f = string.lower (f);

	if (f == gAn_Filter) then return; end

	gAn_Filter = f;

	-- a narrower list under an old scroll offset draws as a page of nothing
	An_ScrollTop ();
	Atr_An_Redisplay ();
end

-- Make a group, from the popup the Add Group button opens.
--
-- It also SWITCHES to the new group, which is what the edit box it replaced did:
-- you make a group in order to put something in it, and the next thing you press
-- is Add Item, which files into whatever group is being looked at.
local function An_AddGroupFromText (txt)

	if (type (txt) ~= "string") then return false; end

	local g = txt:gsub ("^%s+", ""):gsub ("%s+$", "");
	if (g == "") then return false; end

	Atr_An_AddGroup (g);

	gAn_Group = g;
	if (Atr_An_GroupDD and UIDropDownMenu_SetText) then
		UIDropDownMenu_SetText (Atr_An_GroupDD, g);
	end

	Atr_An_Redisplay ();
	return true;
end

-- Add an item to the watchlist from typed text, from the popup the Add Item
-- button opens or from a shift-clicked link pasted into it.
local function An_AddWatchFromText (txt)

	if (type (txt) ~= "string" or txt == "") then return false; end

	local name = txt:match ("%[(.-)%]") or txt;
	name = name:gsub ("^%s+", ""):gsub ("%s+$", "");

	if (name == "") then return false; end

	-- into the group being looked at, which is what the old add box did
	if (Atr_An_Watch (name, gAn_Group)) then
		if (zc and zc.msg_atr) then zc.msg_atr (string.format (AZT("Analysis: watching %s"), name)); end
	end

	Atr_An_Redisplay ();
	return true;
end

local AN_GOLD   = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:4:0|t";
local AN_SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:4:0|t";
local AN_COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:4:0|t";

-- Gold and silver only.
--
-- This was zc.priceToMoneyString, which always ends on copper and pads every
-- coin with two trailing spaces.  A Gold/day RANGE is two of those joined by a
-- dash, so it ran past twenty glyphs and wrapped onto a second line -- and the
-- trailing pad on a right-aligned cell held the number off its own right edge.
-- Copper is not a digit anyone trades on at these prices, so it goes, and the
-- spacing is single.
--
-- Under a gold, silver is all that is shown; under a silver, copper is, since
-- dropping it there would leave the cell blank rather than merely coarse.
local function An_Money (c)

	if (c == nil or c == 0) then return "|cff666666--|r"; end
	if (zc == nil or zc.val2gsc == nil) then return tostring (c); end

	local g, s, cp = zc.val2gsc (c);

	if (g ~= 0) then return string.format ("%d%s %02d%s", g, AN_GOLD, s, AN_SILVER); end
	if (s ~= 0) then return string.format ("%d%s", s, AN_SILVER); end
	return string.format ("%d%s", cp, AN_COPPER);
end

-- WHAT A ROW DOES (owner's request, 2026-08-20) -----------------------------
--
-- Every row of every view behaves the same way, because they are all the same
-- kind of thing -- an item you are deciding about:
--
--   hover        the item's own tooltip, exactly as the auction house draws it
--   left click   look it up: gear on the FINDER tab, everything else on BUY
--   right click  the list menu (shopping list / analysis group)
--
-- The item link is the hard part, and each view knows the item differently: a
-- ledger row carries the real link (which on a same-name variant is the exact
-- item), a craft row has the produced item's ID, and a watch entry has only a
-- name.  Resolved once per row and remembered on the record -- GetItemInfo is a
-- cache lookup, but a mouse-over hot path is no place to find that out.
local function An_RowLink (rec)

	if (rec == nil) then return nil; end
	if (rec.link) then return rec.link; end

	-- The ID this row knows, or the one the index remembers for its name. A
	-- watch entry and an enchant recipe are both name-only, and the index is
	-- what gives them an ID at all (see Atr_An_IdForName).
	local id = rec.id or Atr_An_IdForName (rec.name);

	if (id and type (GetItemInfo) == "function") then
		local _, link = GetItemInfo (id);
		if (link) then rec.link = link; return link; end
	end

	if (rec.name and Atr_GetItemLink) then
		local link = Atr_GetItemLink (rec.name);
		if (link) then
			rec.link = link;
			-- resolved from the client's own cache: worth writing down, since
			-- that cache is a session and this is not
			Atr_An_LearnId (rec.name, An_IdFromLink (link));
			return link;
		end
	end

	-- An ID the client cannot name yet still makes a tooltip: "item:1234" is a
	-- link as far as SetHyperlink and GetItemInfo are concerned, and asking for
	-- it is what makes the client go and fetch the item. NOT remembered on the
	-- record -- the next hover should get the real link once it arrives.
	if (id) then return "item:"..id; end

	return nil;
end

-- ITEMS THE CLIENT HAS NEVER HEARD OF ---------------------------------------
--
-- A tooltip needs the client to know the item, and it only knows what it has
-- seen. On a fresh session the market and crafting views can be a whole page of
-- rows with no tooltip behind them, which is what happened in game (owner's
-- report, 2026-08-20: "it didn't immediately show the tooltip, but once I did a
-- left click most of them updated" -- the lookup warmed the cache).
--
-- So ask for the item on a hidden tooltip as its row is drawn. That is the
-- standard way to make this client fetch an item it does not have, and by the
-- time the cursor arrives a moment later the real data is in. Once per item per
-- session: an item that never answers is not asked twice, and the hover path
-- still asks for itself, so nothing is lost if the fetch failed.
local gAn_Warm, gAn_Warmed = nil, {};

local function An_WarmItem (rec)

	if (rec == nil) then return; end

	-- the index first, because the rows that need warming most are the ones with
	-- no ID of their own: a watched name, an enchant's scroll
	local id = rec.id or Atr_An_IdForName (rec.name);

	if (id == nil or gAn_Warmed[id]) then return; end

	if (type (GetItemInfo) == "function" and GetItemInfo (id)) then
		gAn_Warmed[id] = true;		-- already known, nothing to fetch
		return;
	end

	if (type (CreateFrame) ~= "function") then return; end

	if (gAn_Warm == nil) then
		gAn_Warm = CreateFrame ("GameTooltip", "Atr_An_WarmTooltip", UIParent, "GameTooltipTemplate");
	end

	gAn_Warmed[id] = true;

	gAn_Warm:SetOwner (UIParent, "ANCHOR_NONE");
	gAn_Warm:SetHyperlink ("item:"..id);
	gAn_Warm:Hide();
end

-- GEAR GOES TO THE FINDER, EVERYTHING ELSE TO BUY.  That split is not a
-- preference, it is the reason the Finder tab exists: the Buy tab condenses a
-- scan by item NAME and keeps essentially one link per name, and on this server
-- two auctions of the "same" piece of gear are different items
-- (AuctionatorFinderBuyRedirect.lua).  So this asks the same question that file
-- asks (Fdr_BuyRedirect_ClassOf + Fdr_IsGearClassName) and takes the same jump
-- it takes (Atr_Finder_JumpFromBuy), rather than deciding it a second way.
--
-- An item the client has never cached answers "no class", which lands on the
-- Buy tab -- and the redirect's own second entry point picks it up from there
-- once the auction rows arrive and the class is finally knowable.  Guessing is
-- what that file's fourth rule forbids, and this is the same nil case.
-- A 1x1 frame parked where the cursor is, for the right-click menu to hang off.
-- The menu anchors to a FRAME (it is placed under one, or above it near the
-- bottom of the screen), and the only frame a row click has to offer is the row
-- -- which is as wide as the table, so a menu opened from the Profit column
-- would appear back at the Item column, 600px away from the click.
local gAn_CursorAnchor = nil;

local function An_CursorAnchor (fallback)

	if (type (CreateFrame) ~= "function" or type (GetCursorPosition) ~= "function") then
		return fallback;
	end

	if (gAn_CursorAnchor == nil) then
		gAn_CursorAnchor = CreateFrame ("Frame", nil, UIParent);
		gAn_CursorAnchor:SetSize (1, 1);
	end

	local x, y = GetCursorPosition ();
	local sc   = (UIParent and UIParent.GetEffectiveScale) and UIParent:GetEffectiveScale () or 1;

	if (x == nil or y == nil or sc == nil or sc == 0) then return fallback; end

	gAn_CursorAnchor:ClearAllPoints ();
	gAn_CursorAnchor:SetPoint ("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / sc, y / sc);

	return gAn_CursorAnchor;
end

local function An_OpenItem (rec)

	local name = rec and rec.name;
	if (name == nil or name == "") then return false; end

	local link = An_RowLink (rec);
	local cls  = (Fdr_BuyRedirect_ClassOf) and Fdr_BuyRedirect_ClassOf (name, link) or nil;

	if (Fdr_IsGearClassName and Fdr_IsGearClassName (cls) == true
		and Atr_Finder_JumpFromBuy and Atr_Finder_JumpFromBuy (name)) then
		return true;
	end

	if (Atr_SelectPane == nil or Atr_Search_Box == nil or Atr_Search_Onclick == nil) then
		return false;
	end

	-- select first: the search box belongs to the shared main panel and is
	-- hidden until the Buy tab is up (the Bazaar's jump learned this)
	Atr_SelectPane (ATR_BUY_TAB or 3);

	-- quoted, so Auctionator treats it as an exact name rather than a substring
	Atr_Search_Box:SetText ('"'..name..'"');
	Atr_Search_Onclick ();

	return true;
end

-- Watched items in the current group, in the market view's current sort order
-- (best farm score first until a header is clicked).  The ordering itself lives
-- in An_SortRows and the columns' `val` functions -- including the rule this
-- function used to carry alone, that an item never scanned sorts last rather
-- than as a zero.
local function An_Rows ()

	local db   = Atr_An_DB ();
	local out  = {};

	local name, w;
	for name, w in pairs (db.watch) do
		if ((gAn_Group == nil or (w.group or "") == gAn_Group) and An_PassesFilter (name)) then
			local st = Atr_An_Stats (name);
			tinsert (out, { name = name, group = w.group, st = st, id = st and st.id });
		end
	end

	return An_SortRows ("market", out);
end

-- THE LEDGER VIEW (BACKLOG item 8, group D) --------------------------------

-- A margin with its sign kept.  An_Money prints a grey dash for zero, which is
-- right for "no price known" and wrong for "these came out exactly even", so a
-- real zero is printed as a zero.
local function An_Signed (v)

	if (v == nil) then return "|cff666666--|r"; end
	if (v == 0) then return "|cffffffff0|r"; end
	if (v > 0) then return "|cff40ff40"..An_Money (v).."|r"; end
	return "|cffff6060-"..An_Money (-v).."|r";
end

-- Best margin first, until a header is clicked.  Items that have only ever been
-- LISTED still sort under the ones that actually traded -- their margin is a
-- true zero rather than an unknown, but ranking them among real results would
-- push what you made off the top of the table.  That rule now lives on the
-- Margin column's `val`, which returns nil for exactly the rows whose cell
-- prints "--".
local function An_TradeRows ()

	if (type (Atr_Ledger_ItemTotals) ~= "function") then return {}, nil; end

	local list, tot = Atr_Ledger_ItemTotals ();

	if (gAn_Filter ~= "") then
		local keep, i = {}, nil;
		for i = 1, #list do
			if (An_PassesFilter (list[i].name)) then tinsert (keep, list[i]); end
		end
		list = keep;
	end

	return An_SortRows ("trades", list), tot;
end

-- `shown` is how many rows the filter left; the totals are the LEDGER's, over
-- every row it holds, which is why the two counts can disagree and why the
-- filtered one is said separately rather than substituted in.
local function An_TradeSummary (tot, shown)

	if (tot == nil or tot.rows == 0) then
		return AZT("The ledger is empty. It fills itself from your auction house buys, posts and mail.");
	end

	local s = string.format (AZT("%d items -- paid %s, got %s, margin %s"),
				tot.items, An_Money (tot.paid), An_Money (tot.got), An_Signed (tot.margin));

	if (gAn_Filter ~= "" and shown) then
		s = string.format (AZT("%d shown of "), shown)..s;
	end

	if (tot.tiedQty > 0) then
		s = s..string.format (AZT("  |  %s still listed (%d)"), An_Money (tot.tied), tot.tiedQty);
	end

	if (tot.deposits > 0) then
		s = s..string.format (AZT("  |  deposits %s"), An_Money (tot.deposits));
	end

	-- The ledger prunes oldest-first, so these are totals over a WINDOW. Saying
	-- when it starts is the difference between a number and a claim.
	if (tot.from and date) then
		s = s..string.format (AZT("  |  since %s"), date ("%b %d", tot.from));
	end

	return s;
end

local function An_RedisplayTrades ()

	local rows, tot = An_TradeRows ();
	local n = #rows;

	if (FauxScrollFrame_Update) then
		FauxScrollFrame_Update (Atr_An_ScrollFrame, n, AN_NUM_ROWS, AN_ROW_H);
	end

	local offset = (FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset (Atr_An_ScrollFrame)) or 0;

	local i;
	for i = 1, AN_NUM_ROWS do

		local line = _G["Atr_An_Row"..i];
		if (line) then

			local r = rows[offset + i];

			if (r == nil) then
				line:Hide();
			else
				line.titem:SetText (r.name);

				line.tbought:SetText (r.boughtQty > 0 and tostring (r.boughtQty) or "|cff666666--|r");
				line.tsold:SetText   (r.soldQty   > 0 and tostring (r.soldQty)   or "|cff666666--|r");

				-- the star is the fallback saying so: priced from what the buy
				-- loop intended, because no delivery invoice was ever seen
				if (r.paid > 0) then
					line.tpaid:SetText (An_Money (r.paid)..(r.paidFromIntent and "|cff888888*|r" or ""));
				else
					line.tpaid:SetText ("|cff666666--|r");
				end

				line.tgot:SetText (r.got > 0 and An_Money (r.got) or "|cff666666--|r");

				if (r.paid == 0 and r.got == 0) then
					line.tmargin:SetText ("|cff666666--|r");
				else
					line.tmargin:SetText (An_Signed (r.margin));
				end

				if (r.sellThrough == nil) then
					line.tthru:SetText ("|cff666666--|r");
				else
					line.tthru:SetText (string.format ("%d%%|cff888888 %d/%d|r",
						math.floor (r.sellThrough * 100 + 0.5),
						r.soldQty, r.soldQty + r.expiredQty));
				end

				line.rec = r;
				An_WarmItem (r);
				line:Show();
			end
		end
	end

	if (Atr_An_Summary) then Atr_An_Summary:SetText (An_TradeSummary (tot, n)); end
end

-- THE CRAFTING VIEW (BACKLOG item 8, B2) -----------------------------------

-- Ranking every harvested recipe means pricing every reagent of every one of
-- them, and Atr_GetAuctionPrice is not a table lookup -- it falls through to a
-- recent-sale check and then to a median over an item's variants.  A few hundred
-- recipes is fine to do once and wasteful to redo on every scroll tick, which is
-- what Atr_An_Redisplay is called for, so the ranking is cached.
--
-- Nothing can invalidate it while it is on screen: prices move only when a scan
-- finishes, recipes are learned only at a profession window, and neither can
-- happen without leaving this view -- there is no search control on it and the
-- panel is hidden the moment another tab is clicked.  So the cache is dropped
-- where those journeys come back: entering the view, and re-entering the tab.
local gAn_CraftRows	= nil;
local gAn_CraftStats	= nil;

local function An_CraftInvalidate ()
	gAn_CraftRows  = nil;
	gAn_CraftStats = nil;
end

local function An_CraftRows ()

	if (gAn_CraftRows == nil) then

		if (type (Atr_Craft_ProfitRanking) ~= "function") then return {}, nil; end

		gAn_CraftRows, gAn_CraftStats = Atr_Craft_ProfitRanking ();
	end

	-- Re-sorted rather than re-priced: the ranking arrives best-per-craft first,
	-- and a header click reorders the cached list without touching a price.
	-- stats.best was taken when the list was built, so it keeps naming the best
	-- craft however the table is currently ordered.
	An_SortRows ("craft", gAn_CraftRows);

	-- The filter makes a COPY: what is cached is every recipe, and filtering the
	-- cache in place would throw away the rest of it on the first keystroke.
	if (gAn_Filter ~= "") then
		local keep, i = {}, nil;
		for i = 1, #gAn_CraftRows do
			if (An_PassesFilter (gAn_CraftRows[i].name)) then tinsert (keep, gAn_CraftRows[i]); end
		end
		return keep, gAn_CraftStats;
	end

	return gAn_CraftRows, gAn_CraftStats;
end

-- Profit as a share of the SALE price, not of the cost.  Markup on cost is the
-- more flattering number and it explodes -- a 5c reagent making a 40g item is
-- 80,000% and tells you nothing you could not read off the Profit column.  A
-- share of the price is bounded above by 100% and answers the question that
-- actually decides a craft: how far can this be undercut before it stops paying.
local function An_Margin (r)

	if (r.profit == nil or r.sell == nil or r.sell <= 0) then return "|cff666666--|r"; end

	local pct = math.floor (r.profit * 100 / r.sell + 0.5);

	if (pct < -999) then pct = -999; end		-- a deep loss is a loss; the digits stop meaning anything

	if (pct > 0)  then return string.format ("|cff40ff40%d%%|r", pct); end
	if (pct == 0) then return "|cffffffff0%|r"; end
	return string.format ("|cffff6060%d%%|r", pct);
end

-- THE CRAFTING TOOLTIP, BESIDE THE ITEM'S OWN (owner's request, 2026-08-20)
--
-- What the Cost column is made of: a bare number is one you cannot check, and
-- the reagent it is waiting on is the thing you would go and scan.
--
-- It used to be extra lines appended UNDER the item's real tooltip. It is a
-- tooltip of its own now, drawn beside that one, because the two are different
-- kinds of thing -- one is the item as the client knows it, the other is what
-- it costs you to make and what that is worth -- and stacked they made a
-- column tall enough to put the interesting half off the bottom of the screen
-- on any piece of gear.
--
-- Its own GameTooltipTemplate frame, not a second SetOwner on the shared one:
-- GameTooltip can show one thing at a time and every other addon expects to be
-- able to take it. The template parks it on the TOOLTIP strata, which is the
-- one placement management/docs/CLAUDE.md leaves alone -- a tooltip that draws
-- under what it describes is not a tooltip.
local gAn_CraftTip = nil;

local function An_CraftTipFrame ()

	if (gAn_CraftTip) then return gAn_CraftTip; end
	if (type (CreateFrame) ~= "function") then return nil; end

	gAn_CraftTip = CreateFrame ("GameTooltip", "Atr_An_CraftTooltip", UIParent, "GameTooltipTemplate");

	return gAn_CraftTip;
end

local function An_HideCraftTip ()
	if (gAn_CraftTip) then gAn_CraftTip:Hide(); end
end

local function An_ShowCraftTip (owner, r)

	if (r == nil or r.reagents == nil or GameTooltip == nil) then return; end

	local tip = An_CraftTipFrame ();
	if (tip == nil) then return; end

	-- ANCHOR_NONE and then our own point: what this hangs off is the ITEM's
	-- tooltip, so the pair moves as one and neither lands on the row being read.
	tip:SetOwner (owner, "ANCHOR_NONE");
	tip:ClearLines ();

	tip:AddDoubleLine (r.name or "", (r.made > 1) and string.format (AZT("makes %d"), r.made) or "",
		1, 0.82, 0, 0.8, 0.8, 0.8);

	tip:AddLine (" ");
	tip:AddDoubleLine (AZT("Reagents"), AZT("for one craft"), 1, 1, 1, 0.6, 0.6, 0.6);

	local _, rg;
	for _, rg in ipairs (r.reagents) do

		local nm = rg.name;
		if ((nm == nil or nm == "") and rg.id and GetItemInfo) then nm = (GetItemInfo (rg.id)); end
		nm = nm or ("item "..tostring (rg.id));

		local count = rg.count or 1;
		local unit  = (Atr_Craft_ReagentPrice) and Atr_Craft_ReagentPrice (rg.id, rg.name) or nil;

		if (unit) then
			tip:AddDoubleLine (string.format ("%s x%d", nm, count), An_Money (unit * count),
				0.9, 0.9, 0.9, 1, 1, 1);
		else
			tip:AddDoubleLine (string.format ("%s x%d", nm, count), AZT("not priced"),
				0.9, 0.9, 0.9, 1, 0.4, 0.4);
		end
	end

	-- An enchant is not sellable until it is on a vellum, so the vellum is as
	-- much a reagent as the dust is -- and it is the one the recipe never lists.
	if (r.vellum and Atr_Craft_VellumCost) then
		tip:AddDoubleLine (AZT("Vellum").." ("..tostring (r.vellum)..")",
			An_Money (Atr_Craft_VellumCost (r.vellum)), 0.9, 0.9, 0.9, 1, 1, 1);
	end

	-- The row's own numbers, repeated here on purpose: this box is read while
	-- the cursor is over a row whose columns are behind the item's tooltip.
	tip:AddLine (" ");

	if (r.cost) then
		tip:AddDoubleLine (AZT("Craft cost"), An_Money (r.cost * r.made), 1, 1, 1, 1, 1, 1);
	end
	if (r.sell) then
		tip:AddDoubleLine (AZT("Sells for, each"), An_Money (r.sell), 1, 1, 1, 1, 1, 1);
	end
	if (r.perCraft) then
		tip:AddDoubleLine (AZT("Profit per craft"), An_Signed (r.perCraft), 1, 1, 1, 1, 1, 1);
	end

	if (r.assumed) then
		tip:AddLine (" ");
		tip:AddLine (AZT("Read from a recipe's tooltip: the yield is assumed to be 1, and you may not have learned it."),
			0.8, 0.8, 0.8, true);
	end

	-- Right of the item's tooltip if it fits, left of it if it does not. A row
	-- is as wide as the table, so GameTooltip is already out at the auction
	-- house's right edge and there is not always a second tooltip's worth of
	-- screen past it. Measured after Show, which is what gives it a width.
	tip:ClearAllPoints ();
	tip:SetPoint ("TOPLEFT", GameTooltip, "TOPRIGHT", 4, 0);
	tip:Show ();

	local right  = tip.GetRight and tip:GetRight ();
	local screen = (UIParent and UIParent.GetRight) and UIParent:GetRight () or nil;

	if (right and screen and right > screen) then
		tip:ClearAllPoints ();
		tip:SetPoint ("TOPRIGHT", GameTooltip, "TOPLEFT", -4, 0);
	end
end

local function An_CraftSummary (stats, shown)

	if (stats == nil or stats.total == 0) then
		return AZT("No recipes harvested yet. Open a profession window once and this fills itself in.");
	end

	local s;
	if (gAn_Filter ~= "" and shown) then
		s = string.format (AZT("%d of %d recipes -- %d priced"), shown, stats.total, stats.priced);
	else
		s = string.format (AZT("%d recipes -- %d priced"), stats.total, stats.priced);
	end

	if (stats.best) then
		s = s..string.format (AZT("  |  best %s per craft"), An_Signed (stats.best));
	end

	-- Not a rounding error to hide: the price database is name-keyed, so an item
	-- the client cannot name is an item nothing can price.
	if (stats.unnamed > 0) then
		s = s..string.format (AZT("  |  %d the client has not cached a name for"), stats.unnamed);
	end

	return s;
end

local function An_RedisplayCraft ()

	local rows, stats = An_CraftRows ();
	local n = #rows;

	if (FauxScrollFrame_Update) then
		FauxScrollFrame_Update (Atr_An_ScrollFrame, n, AN_NUM_ROWS, AN_ROW_H);
	end

	local offset = (FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset (Atr_An_ScrollFrame)) or 0;

	local i;
	for i = 1, AN_NUM_ROWS do

		local line = _G["Atr_An_Row"..i];
		if (line) then

			local r = rows[offset + i];

			if (r == nil) then
				line:Hide();
			else
				line.citem:SetText (r.name);

				-- The yield only earns its column when it is not 1, and a ? is
				-- the honest mark on one that was assumed rather than read.
				if (r.assumed) then
					line.cmakes:SetText ("|cff888888"..r.made.."?|r");
				elseif (r.made > 1) then
					line.cmakes:SetText ("|cffffffff"..r.made.."|r");
				else
					line.cmakes:SetText ("|cff6666661|r");
				end

				line.ccost:SetText (r.cost and An_Money (r.cost) or "|cff666666--|r");
				line.csell:SetText (r.sell and An_Money (r.sell) or "|cff666666--|r");

				if (r.perCraft == nil) then
					line.cprofit:SetText ("|cff666666--|r");
				else
					line.cprofit:SetText (An_Signed (r.perCraft));
				end

				line.cmargin:SetText (An_Margin (r));

				line.rec = r;
				An_WarmItem (r);
				line:Show();
			end
		end
	end

	if (Atr_An_Summary) then Atr_An_Summary:SetText (An_CraftSummary (stats, n)); end
end

-- Swap the views over the shared table.  Nothing is re-anchored: every row
-- already carries all three sets of cells and each header set has its own
-- container, so this is Show and Hide only.
function Atr_An_SetView (view)

	if (view ~= "trades" and view ~= "craft") then view = "market"; end
	gAn_View = view;

	local market = (view == "market");

	local function vis (f, on)
		if (f == nil) then return; end
		if (on) then f:Show(); else f:Hide(); end
	end

	vis (Atr_An_HeadMarket, market);
	vis (Atr_An_HeadTrades, view == "trades");
	vis (Atr_An_HeadCraft,  view == "craft");

	local i;
	for i = 1, #gAn_MarketOnly do vis (gAn_MarketOnly[i], market); end

	for i = 1, AN_NUM_ROWS do
		local line = _G["Atr_An_Row"..i];
		if (line) then
			local _, c;
			for _, c in ipairs (AN_COLS)  do vis (line[c.key], market); end
			for _, c in ipairs (AN_TCOLS) do vis (line[c.key], view == "trades"); end
			for _, c in ipairs (AN_CCOLS) do vis (line[c.key], view == "craft");  end
			vis (line.del, market);
		end
	end

	-- the active view's button is the disabled one: the others are the things
	-- left to press, which is what a button should be
	local btn = { market = Atr_An_ViewMarket, trades = Atr_An_ViewTrades, craft = Atr_An_ViewCraft };
	local k, b;
	for k, b in pairs (btn) do
		if (b and b.Enable) then
			if (k == view) then b:Disable(); else b:Enable(); end
		end
	end

	-- a rescan run belongs to the watchlist, and its Stop button has just gone
	if (not market) then Atr_An_RefreshStop (true); end

	-- Re-price on the way in, rather than showing whatever the prices were the
	-- last time this view was open (see An_CraftInvalidate).
	if (view == "craft") then An_CraftInvalidate (); end

	-- the crafting tooltip belongs to a view that may just have gone
	An_HideCraftTip ();

	-- Each view keeps its own sort, so the arrow has to be redrawn for the one
	-- coming up rather than left on whatever the last view was sorted by.
	An_UpdateArrows (view);

	-- Back to the top.  The views are different lengths, and an offset left over
	-- from a scrolled watchlist lands past the end of a shorter ledger -- every
	-- row then draws empty, which reads as "no trades" rather than as a scroll
	-- position.
	An_ScrollTop ();

	Atr_An_Redisplay ();
end

function Atr_An_Redisplay ()

	if (not Atr_An_Panel or not Atr_An_Panel:IsShown()) then return; end

	if (gAn_View == "trades") then return An_RedisplayTrades (); end
	if (gAn_View == "craft")  then return An_RedisplayCraft ();  end

	local rows = An_Rows ();
	local n    = #rows;

	if (FauxScrollFrame_Update) then
		FauxScrollFrame_Update (Atr_An_ScrollFrame, n, AN_NUM_ROWS, AN_ROW_H);
	end

	local offset = (FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset (Atr_An_ScrollFrame)) or 0;

	local i;
	for i = 1, AN_NUM_ROWS do

		local line = _G["Atr_An_Row"..i];
		if (line) then

			local r = rows[offset + i];

			if (r == nil) then
				line:Hide();
			else
				local st = r.st;

				line.item:SetText (r.name);
				line.grp:SetText (r.group and ("|cff888888"..r.group.."|r") or "");

				if (st == nil or st.scans == 0) then
					-- never scanned: say so rather than showing zeros, which would
					-- read as "nothing sells" instead of "we have not looked"
					line.sellers:SetText ("|cff666666--|r");
					line.listings:SetText ("|cff666666--|r");
					line.rate:SetText ("|cff666666"..AZT("not scanned").."|r");
					line.low:SetText ("|cff666666--|r");
					line.farm:SetText ("|cff666666--|r");
				else
					-- one seller holding most of the supply is a different market
					-- from ten sharing it, so it is coloured rather than buried
					local sc = (st.topShare >= 0.8) and "|cffff8080" or "|cffffffff";
					line.sellers:SetText (sc..st.sellers.."|r");
					line.listings:SetText (tostring (st.listings));

					if (st.perDay == nil) then
						line.rate:SetText ("|cff666666"..AZT("one scan").."|r");
					elseif (st.perDayMax > st.perDay + 0.05) then
						line.rate:SetText (string.format ("%.1f|cff888888-%.1f|r", st.perDay, st.perDayMax));
					else
						line.rate:SetText (string.format ("%.1f", st.perDay));
					end

					line.low:SetText (An_Money (st.low));

					if (st.farm == nil) then
						line.farm:SetText ("|cff666666--|r");
					elseif (st.farmMax > st.farm * 1.05) then
						line.farm:SetText (An_Money (math.floor (st.farm)).."|cff888888-|r"..An_Money (math.floor (st.farmMax)));
					else
						line.farm:SetText (An_Money (math.floor (st.farm)));
					end
				end

				line.rec = r;
				An_WarmItem (r);
				line:Show();
			end
		end
	end

	-- Just the count.  This line used to carry two paragraphs explaining what a
	-- range and a turnover figure mean; both now live in the tooltips on the
	-- "Sold/day" and "Gold/day" headers, which is where someone puzzled by a
	-- number actually looks.  As standing text under the table it was a wall of
	-- yellow that never changed and never got read twice (owner's call, 2026-08).
	if (Atr_An_Summary) then

		local watched = 0;
		local nm;
		for nm in pairs (Atr_An_DB ().watch) do watched = watched + 1; end

		-- Both the group dropdown and the filter box narrow this list, so say so
		-- whenever what is on screen is not the whole watchlist: "3 watched" over
		-- a filtered table reads as three items watched in total.
		if (n < watched) then
			Atr_An_Summary:SetText (string.format (AZT("%d of %d watched"), n, watched));
		else
			Atr_An_Summary:SetText (string.format (AZT("%d watched"), watched));
		end
	end
end

local function An_GroupDD_Init ()

	local db = Atr_An_DB ();
	local info;

	info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
	info.text	= AZT("All groups");
	info.func	= function () gAn_Group = nil; UIDropDownMenu_SetText (Atr_An_GroupDD, AZT("All groups")); Atr_An_Redisplay(); CloseDropDownMenus(); end;
	info.checked = (gAn_Group == nil);
	UIDropDownMenu_AddButton (info);

	local i;
	for i = 1, #db.groups do
		local g = db.groups[i];
		info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
		info.text		= g;
		info.func		= function () gAn_Group = g; UIDropDownMenu_SetText (Atr_An_GroupDD, g); Atr_An_Redisplay(); CloseDropDownMenus(); end;
		info.checked	= (gAn_Group == g);
		UIDropDownMenu_AddButton (info);
	end
end
-- ADDING FROM ELSEWHERE ---------------------------------------------------
--
-- BACKLOG item 18.  The watchlist was only reachable from this tab -- an edit box
-- you type a name into.  But the two places you actually decide an item is worth
-- watching are the Finder (you just found it) and the Buy tab (you are looking at
-- its market), and in both of those the item is already in your hand.
--
-- WHY THIS IS NOT A BLIZZARD DROPDOWN (BACKLOG item 21).  It was, twice, and it
-- opened nothing either time.  UIDropDownMenu is driven by four globals
-- (UIDROPDOWNMENU_MENU_LEVEL, _VALUE, _OPEN_MENU, _INIT_MENU) that every other
-- dropdown in the UI writes, and a menu that lands on the wrong level is not an
-- error -- it is silence.  Nothing offline can reach it, so each attempt cost a
-- round trip through the client to learn nothing.
--
-- So this is ~90 lines of plain frame: a backdrop, a row per entry, and a
-- full-screen click-eater behind it.  No shared globals, no lifecycle, and the
-- half that decides WHAT is on the menu is a pure function this repo can test.
-- Not the smallest diff; the one that can be reasoned about to the end.

local AN_MENU_ROW_H	= 16;
local AN_MENU_PAD	= 8;
local AN_MENU_TOP	= 20;		-- room for the title line

local gAnMenuFrame	= nil;
local gAnMenuEater	= nil;

-- What the Buy tab's buttons have actually experienced.  Three rounds went by
-- with "nothing happens" as the only evidence, and from outside the client a
-- click that never fired and a menu that never drew are the same report.  These
-- three counters separate them, and /atranalysis diag reads them out.
gAn_Diag = { hovered = 0, clicked = 0, shown = nil, clickName = nil };
local gAn_PendingItem = nil;	-- survives the menu closing, for a popup

-- Watch an item, optionally filing it in a group.  Choosing a group for an item
-- that is ALREADY watched moves it (Atr_An_Watch updates the group and reports
-- that it added nothing), which is the behaviour a user expects from picking a
-- group off a menu.
function Atr_An_AddToGroup (itemName, group)

	if (itemName == nil or itemName == "") then return false; end

	if (group) then Atr_An_AddGroup (group); end

	local added = Atr_An_Watch (itemName, group);

	if (zc and zc.msg_atr) then
		if (added and group) then
			zc.msg_atr (string.format (AZT("Analysis: watching %s in %s"), itemName, group));
		elseif (added) then
			zc.msg_atr (string.format (AZT("Analysis: watching %s"), itemName));
		elseif (group) then
			zc.msg_atr (string.format (AZT("Analysis: moved %s to %s"), itemName, group));
		else
			zc.msg_atr (string.format (AZT("Analysis: already watching %s"), itemName));
		end
	end

	Atr_An_Redisplay ();
	return true;
end

function Atr_An_AddToShoppingList (itemName, listIndex, listName)

	if (type (Atr_Shop_AddNameToList) ~= "function") then return false; end

	local ok, why = Atr_Shop_AddNameToList (listIndex, itemName);

	if (zc and zc.msg_atr) then
		if (ok) then
			zc.msg_atr (string.format (AZT("Added %s to %s"), tostring (itemName), tostring (listName)));
		elseif (why == "already") then
			zc.msg_atr (string.format (AZT("%s is already on %s"), tostring (itemName), tostring (listName)));
		elseif (why == "full") then
			zc.msg_atr (string.format (AZT("%s is full (50 items)"), tostring (listName)));
		end
	end

	return ok;
end

-- WHAT IS ON THE MENU -- a pure function, and the half worth testing.
--
-- `mode` is "groups", "lists", or "both" (the Finder's row menu, which shows both
-- sections one after the other rather than in submenus -- a flat list of eight is
-- easier to hit than two fly-outs, and there is no submenu machinery to get
-- wrong).  Entries are { text, func, disabled, header }.
function Atr_An_MenuEntries (itemName, mode)

	local out = {};

	if (itemName == nil or itemName == "") then return out; end

	mode = mode or "both";

	local both = (mode == "both");

	if (both or mode == "lists") then

		if (both) then tinsert (out, { text = AZT("Shopping list"), header = true }); end

		-- "Recent Searches" is deliberately absent: it is a rolling log this addon
		-- rewrites, so anything filed there would not survive.
		local lists = (type (Atr_Shop_UserLists) == "function") and Atr_Shop_UserLists() or {};

		local i;
		for i = 1, #lists do
			local L = lists[i];
			tinsert (out, { text = L.name, func = function () Atr_An_AddToShoppingList (itemName, L.index, L.name); end });
		end

		if (#lists == 0) then
			tinsert (out, { text = AZT("no lists yet"), disabled = true });
		end

		tinsert (out, { text = AZT("New list..."), func = function ()
			gAn_PendingItem = itemName;
			if (StaticPopup_Show) then StaticPopup_Show ("ATR_AN_NEW_SLIST"); end
		end });
	end

	if (both or mode == "groups") then

		if (both) then tinsert (out, { text = AZT("Analysis group"), header = true }); end

		local db = Atr_An_DB ();

		tinsert (out, { text = AZT("(no group)"), func = function () Atr_An_AddToGroup (itemName, nil); end });

		local i;
		for i = 1, #db.groups do
			local g = db.groups[i];
			tinsert (out, { text = g, func = function () Atr_An_AddToGroup (itemName, g); end });
		end

		tinsert (out, { text = AZT("New group..."), func = function ()
			gAn_PendingItem = itemName;
			if (StaticPopup_Show) then StaticPopup_Show ("ATR_AN_NEW_GROUP"); end
		end });
	end

	return out;
end

-- A DEBUG BOX YOU CAN ACTUALLY COPY OUT OF ---------------------------------
--
-- Chat text cannot be selected on this client, so a diagnostic printed there can
-- only come back as a screenshot -- which is no use for forty numbers, and is
-- exactly what happened with the first version of /atranalysis diag.  Repo rule
-- now (management/docs/CLAUDE.md): in-game debug output goes in a window like
-- this one.  Same shape as PassLootBiS_Scanner's /plbisscan debug box, which is
-- where this was learned first.
--
-- FULLSCREEN_DIALOG for the reason the strata table gives for copy/paste boxes:
-- you opened it deliberately to read and select text out of, so it must clear
-- whatever is underneath.  Never toplevel -- DRAG-FREEZE.md.
local gAnDebugBox = nil;

function Atr_An_ShowDebugBox (title, text)

	if (type (CreateFrame) ~= "function") then return false; end

	if (gAnDebugBox == nil) then

		local f = CreateFrame ("Frame", "Atr_An_DebugBox", UIParent);
		f:SetWidth (560);
		f:SetHeight (420);
		f:SetPoint ("CENTER");
		f:SetFrameStrata ("FULLSCREEN_DIALOG");
		f:EnableMouse (true);
		f:SetMovable (true);
		f:RegisterForDrag ("LeftButton");
		f:SetScript ("OnDragStart", function (self) self:StartMoving(); end);
		f:SetScript ("OnDragStop", function (self) self:StopMovingOrSizing(); end);

		if (f.SetBackdrop) then
			f:SetBackdrop ({
				bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Buttons\\WHITE8X8",
				edgeSize = 1,
				insets   = { left = 1, right = 1, top = 1, bottom = 1 },
			});
			f:SetBackdropColor (0.05, 0.05, 0.07, 0.95);
			f:SetBackdropBorderColor (0.30, 0.30, 0.34, 1);
		end

		f.title = f:CreateFontString (nil, "OVERLAY", "GameFontNormal");
		f.title:SetPoint ("TOP", 0, -14);

		local close = CreateFrame ("Button", nil, f, "UIPanelCloseButton");
		close:SetPoint ("TOPRIGHT", -6, -6);

		local scroll = CreateFrame ("ScrollFrame", "Atr_An_DebugBoxScroll", f, "UIPanelScrollFrameTemplate");
		scroll:SetPoint ("TOPLEFT", 16, -44);
		scroll:SetPoint ("BOTTOMRIGHT", -34, 16);

		local eb = CreateFrame ("EditBox", "Atr_An_DebugBoxEdit", scroll);
		eb:SetMultiLine (true);
		eb:SetAutoFocus (false);
		eb:SetFontObject (ChatFontNormal);
		eb:SetWidth (500);
		eb:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);
		scroll:SetScrollChild (eb);

		f.eb = eb;
		gAnDebugBox = f;
	end

	gAnDebugBox.title:SetText (tostring (title or AZT("Auctionator debug")));

	-- arrives already selected, so Ctrl+C is the only key needed
	gAnDebugBox.eb:SetText (tostring (text or ""));
	gAnDebugBox.eb:HighlightText ();
	gAnDebugBox.eb:SetCursorPosition (0);
	gAnDebugBox:Show ();
	gAnDebugBox.eb:SetFocus ();

	return true;
end

-- THE FRAME ---------------------------------------------------------------

function Atr_An_HideItemMenu ()
	if (gAnMenuFrame) then gAnMenuFrame:Hide(); end		-- its OnHide takes the eater with it
end

local function An_EnsureMenu ()

	if (gAnMenuFrame) then return gAnMenuFrame; end
	if (type (CreateFrame) ~= "function") then return nil; end

	-- One click anywhere else closes the menu.  It covers the screen, so it MUST
	-- never be able to outlive the menu -- see the OnHide below, which is the only
	-- thing standing between a bug here and an unclickable UI.
	local eat = CreateFrame ("Frame", "Atr_An_ItemMenuEater", UIParent);
	eat:SetFrameStrata ("FULLSCREEN_DIALOG");
	eat:SetFrameLevel (1);
	eat:SetAllPoints (UIParent);
	eat:EnableMouse (true);
	eat:Hide();
	eat:SetScript ("OnMouseDown", function () Atr_An_HideItemMenu (); end);

	-- FULLSCREEN_DIALOG because this is deliberately opened, must clear the
	-- auction house, and that strata is near-empty (see the strata table in
	-- management/docs/CLAUDE.md).  NOT toplevel, ever: DRAG-FREEZE.md.
	local f = CreateFrame ("Frame", "Atr_An_ItemMenu", UIParent);
	f:SetFrameStrata ("FULLSCREEN_DIALOG");
	f:SetFrameLevel (10);
	f:EnableMouse (true);
	f:Hide();

	if (f.SetBackdrop) then
		f:SetBackdrop ({
			bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
			insets   = { left = 1, right = 1, top = 1, bottom = 1 },
		});
		f:SetBackdropColor (0.05, 0.05, 0.07, 0.95);
		f:SetBackdropBorderColor (0.30, 0.30, 0.34, 1);
	end

	f:SetScript ("OnHide", function ()
		if (gAnMenuEater) then gAnMenuEater:Hide(); end
	end);

	f.title = f:CreateFontString (nil, "OVERLAY", "GameFontNormalSmall");
	f.title:SetPoint ("TOPLEFT", AN_MENU_PAD, -6);

	f.rows = {};

	gAnMenuFrame = f;
	gAnMenuEater = eat;

	return f;
end

local function An_MenuRow (f, i)

	if (f.rows[i]) then return f.rows[i]; end

	local r = CreateFrame ("Button", nil, f);
	r:SetHeight (AN_MENU_ROW_H);
	r:SetPoint ("TOPLEFT", AN_MENU_PAD, -(AN_MENU_TOP + (i - 1) * AN_MENU_ROW_H));
	r:SetPoint ("RIGHT", f, "RIGHT", -AN_MENU_PAD, 0);

	r.text = r:CreateFontString (nil, "OVERLAY", "GameFontHighlightSmall");
	r.text:SetPoint ("LEFT", 2, 0);
	r.text:SetJustifyH ("LEFT");

	local hl = r:CreateTexture (nil, "HIGHLIGHT");
	hl:SetAllPoints ();
	hl:SetTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");
	hl:SetBlendMode ("ADD");

	r:SetScript ("OnClick", function (self)
		local fn = self.func;
		Atr_An_HideItemMenu ();
		if (fn) then fn(); end
	end);

	f.rows[i] = r;
	return r;
end

-- `anchor` is the frame the menu hangs off -- the button or row that was clicked.
function Atr_An_ShowItemMenu (anchor, itemName, mode)

	local entries = Atr_An_MenuEntries (itemName, mode);
	if (#entries == 0) then return false; end

	local f = An_EnsureMenu ();
	if (f == nil) then return false; end

	f.title:SetText ("|cffffd100"..tostring (itemName).."|r");

	local widest = f.title:GetStringWidth() or 0;

	local i;
	for i = 1, #entries do

		local e = entries[i];
		local r = An_MenuRow (f, i);

		if (e.header) then
			-- green, and the owner asked for it: the two headers are the only
			-- lines in this menu that are not a thing you can click, and grey
			-- read as "disabled row" rather than as "heading"
			r.text:SetText ("|cff40ff40"..e.text.."|r");
			r.func = nil;
		elseif (e.disabled) then
			r.text:SetText ("|cff777777"..e.text.."|r");
			r.func = nil;
		else
			r.text:SetText (e.text);
			r.func = e.func;
		end

		local w = r.text:GetStringWidth() or 0;
		if (w > widest) then widest = w; end

		r:Show();
	end

	for i = #entries + 1, #f.rows do
		f.rows[i]:Hide();
	end

	f:SetWidth (math.max (130, widest + AN_MENU_PAD * 2 + 10));
	f:SetHeight (AN_MENU_TOP + #entries * AN_MENU_ROW_H + 8);

	-- Below the anchor, unless there is no room below -- a Finder row near the
	-- bottom of the list would otherwise drop the menu off the screen.
	f:ClearAllPoints ();

	local bottom = anchor and anchor.GetBottom and anchor:GetBottom();

	if (anchor == nil) then
		f:SetPoint ("CENTER");
	elseif (bottom and bottom < f:GetHeight() + 20) then
		f:SetPoint ("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2);
	else
		f:SetPoint ("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2);
	end

	gAnMenuEater:Show();
	f:Show();

	return true;
end

if (StaticPopupDialogs) then

	StaticPopupDialogs["ATR_AN_NEW_GROUP"] = {
		text			= AZT("Name for the new Analysis group"),
		button1			= ACCEPT,
		button2			= CANCEL,
		hasEditBox		= 1,
		maxLetters		= 32,
		OnAccept		= function (self)
			local g = self.editBox:GetText();
			if (g and g ~= "" and gAn_PendingItem) then Atr_An_AddToGroup (gAn_PendingItem, g); end
			gAn_PendingItem = nil;
		end,
		EditBoxOnEnterPressed = function (self)
			local g = self:GetParent().editBox:GetText();
			if (g and g ~= "" and gAn_PendingItem) then Atr_An_AddToGroup (gAn_PendingItem, g); end
			gAn_PendingItem = nil;
			self:GetParent():Hide();
		end,
		OnShow			= function (self) self.editBox:SetText(""); self.editBox:SetFocus(); end,
		timeout = 0, exclusive = 1, whileDead = 1, hideOnEscape = 1
	};

	StaticPopupDialogs["ATR_AN_ADD_GROUP"] = {
		text			= AZT("Name for the new Analysis group"),
		button1			= ACCEPT,
		button2			= CANCEL,
		hasEditBox		= 1,
		maxLetters		= 32,
		OnAccept		= function (self) An_AddGroupFromText (self.editBox:GetText()); end,
		EditBoxOnEnterPressed = function (self)
			An_AddGroupFromText (self:GetParent().editBox:GetText());
			self:GetParent():Hide();
		end,
		OnShow			= function (self) self.editBox:SetText(""); self.editBox:SetFocus(); end,
		timeout = 0, exclusive = 1, whileDead = 1, hideOnEscape = 1
	};

	StaticPopupDialogs["ATR_AN_ADD_WATCH"] = {
		text			= AZT("Item to watch -- type a name or shift-click a link"),
		button1			= ACCEPT,
		button2			= CANCEL,
		hasEditBox		= 1,
		maxLetters		= 96,
		OnAccept		= function (self) An_AddWatchFromText (self.editBox:GetText()); end,
		EditBoxOnEnterPressed = function (self)
			An_AddWatchFromText (self:GetParent().editBox:GetText());
			self:GetParent():Hide();
		end,
		OnShow			= function (self) self.editBox:SetText(""); self.editBox:SetFocus(); end,
		timeout = 0, exclusive = 1, whileDead = 1, hideOnEscape = 1
	};

	StaticPopupDialogs["ATR_AN_NEW_SLIST"] = {
		text			= AZT("Name for the new shopping list"),
		button1			= ACCEPT,
		button2			= CANCEL,
		hasEditBox		= 1,
		maxLetters		= 32,
		OnAccept		= function (self)
			local n = self.editBox:GetText();
			if (n and n ~= "" and gAn_PendingItem and type (Atr_Shop_CreateListWithItem) == "function") then
				Atr_Shop_CreateListWithItem (n, gAn_PendingItem);
			end
			gAn_PendingItem = nil;
		end,
		EditBoxOnEnterPressed = function (self)
			local n = self:GetParent().editBox:GetText();
			if (n and n ~= "" and gAn_PendingItem and type (Atr_Shop_CreateListWithItem) == "function") then
				Atr_Shop_CreateListWithItem (n, gAn_PendingItem);
			end
			gAn_PendingItem = nil;
			self:GetParent():Hide();
		end,
		OnShow			= function (self) self.editBox:SetText(""); self.editBox:SetFocus(); end,
		timeout = 0, exclusive = 1, whileDead = 1, hideOnEscape = 1
	};
end

-- THE BUY TAB'S WAY IN ----------------------------------------------------
--
-- The item the Buy tab is showing, or nil.  gCurrentPane is a file-local in
-- Auctionator.lua; Atr_GetCurrentPane exists precisely so other modules can ask.
--
-- IsNil is the test that matters, not an empty string: a pane with no item still
-- carries a scan, and Atr_FindScan(nil) names it the literal string "nil".  On the
-- Buy tab's search-summary view that is exactly the state, and without this the
-- buttons would offer to watch an item called "nil".
function Atr_An_BuyItemName ()

	if (type (Atr_GetCurrentPane) ~= "function") then return nil; end

	local pane = Atr_GetCurrentPane ();
	local scn  = pane and pane.activeScan;

	if (scn == nil) then return nil; end
	if (scn.IsNil and scn:IsNil()) then return nil; end

	local nm = scn.itemName;
	if (nm == nil or nm == "" or nm == "nil") then return nil; end

	return nm;
end

-- Show the two buttons on the Buy tab's item view, and nowhere else.
--
-- THE FIRST ATTEMPT PUT THEM IN recommendElements AND THEY NEVER APPEARED.  That
-- strip is the SELL tab's recommendation ("Recommended buyout price" and the two
-- prices); the Buy tab explicitly HIDES it (Atr_UpdateUI's else branch) and then
-- paints its own header by re-showing two of its members through
-- Atr_ShowItemNameAndTexture -- the icon, and Atr_Recommend_Text reused as the
-- item's name.  So membership meant "hidden on every Buy tab repaint", which is
-- the exact opposite of what was wanted.
--
-- Hence: not in that table, and called from the three places that repaint or
-- leave that header -- Atr_ShowItemNameAndTexture (Buy paints it),
-- Atr_UpdateRecommendation (SELL paints it) and the tab click.  Each just asks
-- this, and this decides.
function Atr_An_UpdateBuyButton ()

	local watch = Atr_An_BuyWatchButton;
	local shop  = Atr_An_BuyListButton;

	if (watch == nil and shop == nil) then return; end

	local show = (type (Atr_IsModeBuy) == "function" and Atr_IsModeBuy()
					and Atr_An_BuyItemName () ~= nil);

	if (watch) then if (show) then watch:Show(); else watch:Hide(); end end
	if (shop)  then if (show) then shop:Show();  else shop:Hide();  end end

	-- a menu hanging off a button that just vanished has nothing to hang from
	if (not show and Atr_An_HideItemMenu) then Atr_An_HideItemMenu (); end
end

-- RESCAN ------------------------------------------------------------------
--
-- Watching an item and then having to remember to search for it is the wrong way
-- round: the tab knows exactly which items it wants a fresh look at.  getAll is
-- disabled on this server, so there is no one query that covers them -- it is one
-- exact search per watched item, run in sequence.
--
-- It deliberately reuses the ordinary search machinery through gAnalysisPane
-- rather than driving QueryAuctionItems itself.  One pump owns the auction API;
-- a second one racing it is how you get duplicate pages and disconnects.  The
-- cost of that choice is that the pump only advances the CURRENT pane's search,
-- so leaving the tab stops the run (see Atr_An_OnTabClick).

local gAn_Queue		= nil;		-- names still to scan, or nil when not running
local gAn_QDone		= 0;
local gAn_QTotal	= 0;

-- Is this tab the one the pump is currently driving?  It cannot be answered by
-- comparing against gCurrentPane -- that is a file-local in Auctionator.lua and
-- reads as nil from here (gAnalysisPane is a global, gCurrentPane is not).  The
-- SELECTED TAB is what assigns gCurrentPane in the first place, and that is
-- readable, so ask the question that way round.
local function An_TabIsCurrent ()

	if (type (Atr_IsTabSelected) ~= "function" or ATR_ANALYSIS_TAB == nil) then return false; end

	return (Atr_IsTabSelected (ATR_ANALYSIS_TAB) == true);
end

local function An_RefreshUI ()

	if (Atr_An_RefreshButton) then
		Atr_An_RefreshButton:SetText (gAn_Queue and AZT("Stop") or AZT("Rescan"));
	end

	if (Atr_An_Progress) then
		if (gAn_Queue) then
			Atr_An_Progress:SetText (string.format (AZT("scanning %d of %d"),
				math.min (gAn_QDone + 1, gAn_QTotal), gAn_QTotal));
		else
			Atr_An_Progress:SetText ("");
		end
	end
end

function Atr_An_RefreshStop (quiet)

	local wasRunning = (gAn_Queue ~= nil);
	local done		 = gAn_QDone;

	gAn_Queue = nil;
	gAn_QDone = 0;
	gAn_QTotal = 0;

	An_RefreshUI ();

	if (wasRunning and not quiet and zc and zc.msg_atr) then
		zc.msg_atr (string.format (AZT("Analysis: rescanned %d item(s)"), done));
	end

	if (wasRunning) then Atr_An_Redisplay (); end
end

local function An_RefreshStep ()

	if (gAn_Queue == nil) then return; end

	local name = tremove (gAn_Queue, 1);

	if (name == nil) then
		Atr_An_RefreshStop ();
		return;
	end

	An_RefreshUI ();

	-- rescanThreshold 0: never accept a cached scan.  A cache hit would return
	-- the PREVIOUS scan's listings, and observing those again would compare a
	-- snapshot with itself -- zero sales, and elapsed time added for nothing.
	local ok, cacheHit = pcall (function () return gAnalysisPane:DoSearch (name, true, 0); end);

	if (not ok) then
		Atr_An_RefreshStop (true);
		return;
	end

	if (cacheHit and Atr_OnSearchComplete) then
		Atr_OnSearchComplete ();		-- nothing to wait for; keeps the queue moving
	end
end

-- Called from Atr_OnSearchComplete for EVERY search, so it does nothing at all
-- unless a rescan of ours is the thing that just finished.
function Atr_An_OnSearchComplete ()

	if (gAn_Queue == nil) then return; end

	if (gAnalysisPane == nil or not An_TabIsCurrent ()) then
		Atr_An_RefreshStop (true);		-- someone else owns the pump now
		return;
	end

	gAn_QDone = gAn_QDone + 1;

	Atr_An_Redisplay ();				-- watch the numbers fill in
	An_RefreshStep ();
end

function Atr_An_RefreshToggle ()

	if (gAn_Queue) then
		Atr_An_RefreshStop ();
		return;
	end

	if (gAnalysisPane == nil or not An_TabIsCurrent ()) then return; end

	-- WHAT IS ON SCREEN, which the group dropdown and now the filter box both
	-- narrow.  That is the useful behaviour -- "rescan these" -- but it is worth
	-- knowing rather than discovering, so the button's tooltip says it too.
	local rows = An_Rows ();
	local q, i = {}, nil;
	for i = 1, #rows do tinsert (q, rows[i].name); end

	if (#q == 0) then
		if (zc and zc.msg_atr) then
			zc.msg_atr (AZT("Analysis: nothing to rescan here -- the filter or the group is hiding everything, or nothing is watched yet"));
		end
		return;
	end

	gAn_Queue	= q;
	gAn_QDone	= 0;
	gAn_QTotal	= #q;

	An_RefreshStep ();
end

function Atr_An_OnTabClick (index)

	if (Atr_An_Panel == nil) then return; end

	if (ATR_ANALYSIS_TAB and Atr_FindTabIndex and index == Atr_FindTabIndex (ATR_ANALYSIS_TAB)) then
		Atr_An_Panel:Show();
		-- prices may have moved while another tab had the window: re-price rather
		-- than redraw what was on screen before (see An_CraftInvalidate)
		An_CraftInvalidate ();
		Atr_An_Redisplay ();
	else
		-- the pump follows the current pane, so a run cannot survive the tab
		Atr_An_RefreshStop (true);
		if (Atr_An_HideItemMenu) then Atr_An_HideItemMenu (); end
		An_HideCraftTip ();		-- the panel can go while the cursor is still on a row
		Atr_An_Panel:Hide();
	end
end

function Atr_An_Init ()

	if (Atr_An_Panel or type (CreateFrame) ~= "function") then return; end

	-- The panel used to be a flat 738 wide, which is Blizzard's 768px auction
	-- house minus its insets.  Ascension's window is wider, so everything anchored
	-- to the panel's BOTTOMRIGHT -- the Rescan button above all -- stopped short of
	-- the right edge with a band of empty backdrop beyond it.  Measure instead:
	-- the panel starts 10 in from the window's left and ends where the backdrop
	-- does, 12 in from its right, so it IS the content area and anything anchored
	-- right is genuinely right.  The height is left alone -- it already matches.
	local frameW = 768;
	if (AuctionFrame and AuctionFrame.GetWidth) then frameW = AuctionFrame:GetWidth() or 768; end
	if (frameW < 600) then frameW = 768; end		-- not laid out yet: fall back

	local panelW = math.floor (frameW) - 22;

	local panel = CreateFrame ("Frame", "Atr_An_Panel", AuctionFrame);
	panel:SetSize (panelW, 447);
	panel:SetPoint ("TOPLEFT", 10, 0);
	panel:Hide();

	-- Row and scroll widths follow from that.  A FauxScrollFrame's bar is anchored
	-- to the scroll frame's TOPRIGHT and hangs OUTSIDE it, so the lane it needs
	-- comes off the panel, not off the rows -- reserving it inside as well (rows
	-- were scrollW - 30) spent it twice and left the table short of the right edge
	-- by that much again.  Rows are the full scroll width; the bar gets AN_SB_LANE
	-- beyond it, and 4 more keeps it off the backdrop's edge.
	local scrollW = panelW - AN_HEAD_X0 - AN_SB_LANE - 4;
	AN_ROW_W = scrollW;
	An_LayoutCols (AN_COLS,  AN_ROW_W);
	An_LayoutCols (AN_TCOLS, AN_ROW_W);
	An_LayoutCols (AN_CCOLS, AN_ROW_W);

	local bg = panel:CreateTexture (nil, "BACKGROUND");
	bg:SetTexture (0, 0, 0, 0.85);
	bg:SetPoint ("TOPLEFT", 14, -70);
	bg:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -12, 28);

	local title = panel:CreateFontString (nil, "BACKGROUND", "GameFontNormal");
	title:SetPoint ("TOP", 0, -18);
	title:SetText ("Auctionator - "..AZT("Analysis"));

	-- FILTER BOX: narrows whichever table is up, live, as you type.  It is on
	-- every view (see An_SetFilter) and so is deliberately NOT in gAn_MarketOnly
	-- below.  Same size and place as the add box it replaced -- 90 wide starting
	-- at x=76, because at x=24 both it and its label ran under the auction
	-- house's portrait, which is drawn over them.
	local filtLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	filtLabel:SetPoint ("TOPLEFT", 72, -40);
	filtLabel:SetText (AZT("Filter"));

	local filtBox = CreateFrame ("EditBox", "Atr_An_FilterBox", panel, "InputBoxTemplate");
	filtBox:SetSize (90, 20);
	filtBox:SetPoint ("TOPLEFT", 76, -52);
	filtBox:SetAutoFocus (false);
	filtBox:SetMaxBytes (96);

	-- OnTextChanged, not OnEnterPressed: "works immediately when text is typed
	-- in" is the request, and a filter you have to confirm is a search box.
	local rewriting = false;

	filtBox:SetScript ("OnTextChanged", function (self)

		if (rewriting) then return; end

		local txt = self:GetText() or "";

		-- a shift-clicked link arrives as the whole hyperlink; filter on the name
		-- anybody would have typed.  The rewrite re-enters this script, hence the
		-- flag -- without it the SetText below would recurse.
		local name = txt:match ("%[(.-)%]");
		if (name) then
			rewriting = true;
			self:SetText (name);
			rewriting = false;
			txt = name;
		end

		An_SetFilter (txt);
	end);

	filtBox:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); end);
	filtBox:SetScript ("OnEscapePressed", function (self)
		self:SetText ("");			-- OnTextChanged clears the filter with it
		self:ClearFocus();
	end);

	-- THE REST OF THE CONTROL ROW, left to right: the group dropdown, then Add
	-- Item, then Add Group (owner's layout, 2026-08-20).  Both adds are popups
	-- now -- typing a name is a once-per-item and once-per-group job, and a
	-- permanent edit box for each was two boxes' worth of row spent on it.
	--
	-- Anchored to each other rather than at fixed x from the dropdown onwards:
	-- UIDropDownMenu_SetWidth(110) makes a frame 160 wide (25 of dead art each
	-- side), and hard-coding where that ends is how the last layout ended up
	-- being retuned from a screenshot.  The chain starts at x=176, which is just
	-- past the filter box's own border art, and ends around x=492 on Blizzard's
	-- 768px window -- clear of the view toggle, which starts at 526 there.
	local grpDD;

	if (UIDropDownMenu_Initialize) then
		grpDD = CreateFrame ("Frame", "Atr_An_GroupDD", panel, "UIDropDownMenuTemplate");
		grpDD:SetPoint ("TOPLEFT", 176, -48);
		UIDropDownMenu_SetWidth (grpDD, 110);
		UIDropDownMenu_Initialize (grpDD, An_GroupDD_Init);
		UIDropDownMenu_SetText (grpDD, AZT("All groups"));
	end

	local function rowButton (name, w, label, popup, tipTitle, tipBody)

		local b = CreateFrame ("Button", name, panel, "UIPanelButtonTemplate");
		b:SetSize (w, 22);
		b:SetText (AZT (label));
		b:SetNormalFontObject ("GameFontNormalSmall");
		b:SetHighlightFontObject ("GameFontHighlightSmall");
		b:SetScript ("OnClick", function ()
			if (StaticPopup_Show) then StaticPopup_Show (popup); end
		end);
		b:SetScript ("OnEnter", function (self)
			if (GameTooltip) then
				GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
				GameTooltip:SetText (AZT (tipTitle), 1, 1, 1);
				GameTooltip:AddLine (AZT (tipBody), 0.8, 0.8, 0.8, true);
				GameTooltip:Show();
			end
		end);
		b:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

		return b;
	end

	local addBtn = rowButton ("Atr_An_AddButton", 76, "Add Item", "ATR_AN_ADD_WATCH",
		"Watch an item",
		"Type a name, or shift-click an item link into the box. It joins the group you are looking at.");

	local grpBtn = rowButton ("Atr_An_AddGroupButton", 82, "Add Group", "ATR_AN_ADD_GROUP",
		"Make a group",
		"Groups are your own labels for watched items -- ore, flasks, whatever you actually farm. The new one becomes the one you are looking at, so the next item you add lands in it.");

	if (grpDD) then
		-- +2 vertically: the dropdown's frame is taller than a button and hangs
		-- below its own anchor, so its RIGHT is not where its box looks to be
		addBtn:SetPoint ("LEFT", grpDD, "RIGHT", 0, 2);
	else
		addBtn:SetPoint ("LEFT", filtBox, "RIGHT", 6, 0);		-- no dropdown to hang off
	end

	grpBtn:SetPoint ("LEFT", addBtn, "RIGHT", 4, 0);

	-- Headers: same x, width and justification as the cells beneath them.  The
	-- text sits at -84, not -74: the group dropdown's frame art hangs well below
	-- its own anchor and was all but touching it.
	--
	-- Each view's headers go in a container of their own, laid over the panel so
	-- the offsets below are unchanged, and the view switch is then one Show and
	-- one Hide rather than a walk over three lists of frames.
	--
	-- EVERY HEADER IS A BUTTON NOW (item 24), because every one of them sorts.
	-- They used to be FontStrings with an invisible hit frame added over the two
	-- that had a tooltip to show; one Button per column does both jobs and there
	-- is no second frame to keep in step with the first.
	local function headerSet (name, view, cols)

		local box = CreateFrame ("Frame", name, panel);
		box:SetAllPoints (panel);

		local c;
		for _, c in ipairs (cols) do

			local col = c;

			-- 18 tall at -82, so the label still lands at -84 where it always has
			-- and the button ends exactly where the scroll frame starts (-102).  A
			-- header that overhung it would eat clicks meant for the first row.
			local btn = CreateFrame ("Button", nil, box);
			btn:SetPoint ("TOPLEFT", AN_HEAD_X0 + col.cx, -82);
			btn:SetSize (col.cw, 18);

			-- the Finder's header treatment exactly: a barely-there wash that
			-- brightens under the cursor, so a sortable header looks sortable
			local hi = btn:CreateTexture (nil, "BACKGROUND");
			hi:SetAllPoints ();
			hi:SetTexture (1, 1, 1, 0.06);

			local fs = btn:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
			fs:SetPoint ("TOPLEFT", 0, -2);
			fs:SetWidth (col.cw);
			fs:SetJustifyH (col.just or "LEFT");
			fs:SetText (AZT (col.head));

			btn.label	= fs;
			btn.head	= AZT (col.head);		-- An_UpdateArrows appends to this

			btn:SetScript ("OnClick", function () An_HeaderClick (view, col.key); end);

			btn:SetScript ("OnEnter", function (self)
				hi:SetTexture (1, 1, 1, 0.15);
				if (GameTooltip) then
					GameTooltip:SetOwner (self, "ANCHOR_BOTTOMRIGHT");
					GameTooltip:SetText (AZT (col.head), 1, 1, 1);
					if (col.tip) then GameTooltip:AddLine (AZT (col.tip), 0.8, 0.8, 0.8, true); end
					GameTooltip:AddLine (AZT("Click to sort by this column. Click again to reverse it."), 0.5, 0.5, 0.5, true);
					GameTooltip:Show();
				end
			end);

			btn:SetScript ("OnLeave", function ()
				hi:SetTexture (1, 1, 1, 0.06);
				if (GameTooltip) then GameTooltip:Hide(); end
			end);

			gAn_Heads[view][col.key] = btn;
		end

		return box;
	end

	headerSet ("Atr_An_HeadMarket", "market", AN_COLS);
	headerSet ("Atr_An_HeadTrades", "trades", AN_TCOLS);
	headerSet ("Atr_An_HeadCraft",  "craft",  AN_CCOLS);

	local scroll = CreateFrame ("ScrollFrame", "Atr_An_ScrollFrame", panel, "FauxScrollFrameTemplate");
	scroll:SetPoint ("TOPLEFT", AN_HEAD_X0, -102);
	scroll:SetSize (scrollW, AN_NUM_ROWS * AN_ROW_H);
	scroll:SetScript ("OnVerticalScroll", function (self, offset)
		if (FauxScrollFrame_OnVerticalScroll) then
			FauxScrollFrame_OnVerticalScroll (self, offset, AN_ROW_H, Atr_An_Redisplay);
		end
	end);

	local holder = CreateFrame ("Frame", nil, panel);
	holder:SetPoint ("TOPLEFT", AN_HEAD_X0, -102);
	holder:SetSize (AN_ROW_W, AN_NUM_ROWS * AN_ROW_H);

	local i;
	for i = 1, AN_NUM_ROWS do

		local line = CreateFrame ("Button", "Atr_An_Row"..i, holder);
		line:SetSize (AN_ROW_W, AN_ROW_H);
		line:SetPoint ("TOPLEFT", 0, -(i - 1) * AN_ROW_H);

		-- every view's cells, on every row: the keys do not collide and only one
		-- set is ever shown, which is what makes the switch free of re-anchoring
		local cols, cc;
		for _, cols in ipairs ({ AN_COLS, AN_TCOLS, AN_CCOLS }) do
			for _, cc in ipairs (cols) do
				local fs = line:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
				fs:SetPoint ("LEFT", cc.cx, 0);
				fs:SetWidth (cc.cw);
				fs:SetJustifyH (cc.just or "LEFT");
				line[cc.key] = fs;
			end
		end

		-- its own lane past the last column, so it stops sitting on the numbers
		local del = CreateFrame ("Button", nil, line, "UIPanelCloseButton");
		del:SetSize (20, 20);
		del:SetPoint ("RIGHT", -4, 0);
		del:SetScript ("OnClick", function ()
			if (line.rec) then Atr_An_Unwatch (line.rec.name); Atr_An_Redisplay (); end
		end);
		line.del = del;		-- unwatching is the market view's action, not the Ledger's

		-- the item's own tooltip, the way the Ledger's rows do it.  A watch entry
		-- stores only a name, so the link comes from the shared cache -- which
		-- means no tooltip until something has seen the item, and that is better
		-- than inventing a link from a name.
		-- The item's own tooltip, on every row of every view.  Which link that is
		-- differs per view and An_RowLink knows all three.
		line:SetScript ("OnEnter", function (self)

			local rec = self.rec;
			if (rec == nil or GameTooltip == nil) then return; end

			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");

			local link = An_RowLink (rec);

			if (link) then
				GameTooltip:SetHyperlink (link);
			else
				-- nothing has ever seen this item: an enchant sells as a scroll
				-- that may never have been scanned, and a watch entry is a name
				-- someone typed.  The name is what there is, and it beats nothing.
				GameTooltip:SetText (rec.name or "", 1, 1, 1);
			end

			GameTooltip:AddLine (" ");
			GameTooltip:AddLine (AZT("Left click to look it up.  Right click for lists."), 0.5, 0.5, 0.5);
			GameTooltip:Show();

			-- the crafting figures go BESIDE it, not under it
			if (gAn_View == "craft") then An_ShowCraftTip (self, rec); end
		end);

		line:SetScript ("OnLeave", function ()
			if (GameTooltip) then GameTooltip:Hide(); end
			An_HideCraftTip ();
		end);

		-- A plain Button hears the left click only, and the right one is now half
		-- of what a row does.
		line:RegisterForClicks ("LeftButtonUp", "RightButtonUp");

		-- Left: look the item up on the tab that handles it properly.  Right: the
		-- same list menu the Buy tab's two buttons open (item 18), so an item
		-- worth watching or buying can be filed without retyping its name.
		line:SetScript ("OnClick", function (self, button)

			local rec = self.rec;
			if (rec == nil) then return; end

			-- a jump hides this panel without the cursor ever leaving the row, so
			-- OnLeave never fires and the tooltips would sit there over the tab we
			-- just switched to
			if (GameTooltip) then GameTooltip:Hide(); end
			An_HideCraftTip ();

			if (button == "RightButton") then
				if (type (Atr_An_ShowItemMenu) == "function") then
					Atr_An_ShowItemMenu (An_CursorAnchor (self), rec.name, "both");
				end
				return;
			end

			An_OpenItem (rec);
		end);

		line:Hide();
	end

	-- The market view puts one short line here -- the watched count -- and needed
	-- no wrap width for it.  The Ledger view's totals line is long (paid, got,
	-- margin, what is still listed, deposits, and the window they cover), so the
	-- width is back: without it a wide total runs off the panel's right edge
	-- rather than wrapping.  It cannot collide with the Rescan button the way the
	-- original wall of text did, because that button is hidden in the view that
	-- writes the long line.
	local summary = panel:CreateFontString ("Atr_An_Summary", "ARTWORK", "GameFontNormalSmall");
	summary:SetPoint ("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 34);
	summary:SetWidth (panelW - 60);
	summary:SetJustifyH ("LEFT");
	summary:SetText ("");

	-- Rescan, in the Ledger's place for a tab-level action button
	local refresh = CreateFrame ("Button", "Atr_An_RefreshButton", panel, "UIPanelButtonTemplate");
	refresh:SetSize (76, 22);
	refresh:SetPoint ("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 30);
	refresh:SetText (AZT("Rescan"));
	refresh:SetScript ("OnClick", function () Atr_An_RefreshToggle (); end);
	refresh:SetScript ("OnEnter", function (self)
		if (GameTooltip) then
			GameTooltip:SetOwner (self, "ANCHOR_LEFT");
			GameTooltip:SetText (AZT("Rescan the watched items"), 1, 1, 1);
			GameTooltip:AddLine (AZT("One search per item, in sequence, for the items on screen -- the filter and the group both narrow it. Stays on this tab: leaving it stops the run."), 0.8, 0.8, 0.8, true);
			GameTooltip:Show();
		end
	end);
	refresh:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

	local progress = panel:CreateFontString ("Atr_An_Progress", "ARTWORK", "GameFontNormalSmall");
	progress:SetPoint ("RIGHT", refresh, "LEFT", -8, 0);
	progress:SetJustifyH ("RIGHT");
	progress:SetText ("");

	-- THE VIEW TOGGLE (BACKLOG item 8, group D; a third view added for B2).
	--
	-- Top right, which is the one part of the control row that is empty: the add
	-- box, the group dropdown and the new-group box run along the left of it, and
	-- the panel is wider than they are on every window this addon has been
	-- measured on.  Anchored to the panel's own TOPRIGHT rather than a fixed x
	-- for the reason the panel width itself is measured -- 768 is not the only
	-- auction house.
	local function viewButton (name, label, view, tipTitle, tipBody)

		-- 62 apiece and a 4px gap: three of those is 194, so on Blizzard's 768
		-- window (a 746 panel) the row runs 526..720 and the group controls,
		-- moved left to end at ~508, clear it by 18. The pair used to be 72 wide
		-- against controls ending at ~558, which a third button would have run
		-- straight into. 62 still fits "My trades" at GameFontNormalSmall, which
		-- is the widest of the three labels.
		local b = CreateFrame ("Button", name, panel, "UIPanelButtonTemplate");
		b:SetSize (62, 22);
		b:SetText (AZT (label));
		b:SetNormalFontObject ("GameFontNormalSmall");
		b:SetHighlightFontObject ("GameFontHighlightSmall");
		b:SetScript ("OnClick", function () Atr_An_SetView (view); end);
		b:SetScript ("OnEnter", function (self)
			if (GameTooltip) then
				GameTooltip:SetOwner (self, "ANCHOR_LEFT");
				GameTooltip:SetText (AZT (tipTitle), 1, 1, 1);
				GameTooltip:AddLine (AZT (tipBody), 0.8, 0.8, 0.8, true);
				GameTooltip:Show();
			end
		end);
		b:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

		return b;
	end

	-- Right to left, in the order they are read: what the market is doing, what
	-- you made, what you could make.
	local vCraft = viewButton ("Atr_An_ViewCraft", "Crafting", "craft",
		"What is worth crafting",
		"Every recipe your professions have harvested, ranked by what one craft is worth at today's prices. The profession window's own profit sort, available where you are actually standing when you decide.");
	vCraft:SetPoint ("TOPRIGHT", panel, "TOPRIGHT", -26, -50);

	local vTrades = viewButton ("Atr_An_ViewTrades", "My trades", "trades",
		"What you actually made",
		"Your own buys and sales out of the ledger: paid, got, margin and sell-through, per item. The only numbers on this tab that are not estimates.");
	vTrades:SetPoint ("RIGHT", vCraft, "LEFT", -4, 0);

	local vMarket = viewButton ("Atr_An_ViewMarket", "Market", "market",
		"What the market is doing",
		"The watched items: how many sellers, how fast listings disappear, and what that is worth per day. Estimates, from scanning.");
	vMarket:SetPoint ("RIGHT", vTrades, "LEFT", -4, 0);

	-- Everything that only makes sense against the watchlist.  The Ledger view
	-- has nothing to add an item to, no groups to filter by and nothing to
	-- rescan, so these go away wholesale rather than sitting there inert.
	-- The filter box and its label are NOT here: they are on every view now.
	gAn_MarketOnly = { addBtn, grpBtn, refresh, progress, _G["Atr_An_GroupDD"] };

	Atr_An_SetView ("market");

	-- BUY TAB (BACKLOG item 18, corrected in 19): two buttons on the item view.
	--
	-- They are built here with the rest of the analysis UI but belong to the
	-- SHARED main panel, so they are parented to that panel and anchored to
	-- Atr_Recommend_Text -- which on the Buy tab holds the ITEM'S NAME (that tab
	-- reuses the FontString; see Atr_ShowItemNameAndTexture).  Anchoring to it
	-- puts them under the name whatever the header does.
	--
	-- Under the ICON is where they were first put, and that space is taken: the
	-- Back button sits there whenever a search matched more than one item.  Below
	-- the name is clear on this tab -- what occupies it on SELL is the two
	-- recommended prices, and these are hidden there.
	local nameFS = _G["Atr_Recommend_Text"];
	local panelP = _G["Atr_Main_Panel"];

	if (nameFS and panelP) then

		local function headerButton (name, w, label, mode, tipTitle, tipBody)

			local b = CreateFrame ("Button", name, panelP, "UIPanelButtonTemplate");
			b:SetSize (w, 18);
			b:SetText (AZT (label));
			b:SetNormalFontObject ("GameFontNormalSmall");
			b:SetHighlightFontObject ("GameFontHighlightSmall");
			b:Hide();

			-- Well clear of its siblings in this panel.  A frame LEVEL, not a
			-- Raise and never toplevel (DRAG-FREEZE.md); 100 is the house number
			-- for "in front of the furniture" and costs nothing if it was never
			-- the problem.  It is a candidate cause of the dead click: anything
			-- sharing this strata at a higher level takes the mouse first.
			if (b.SetFrameLevel and b.GetFrameLevel) then
				b:SetFrameLevel ((b:GetFrameLevel() or 1) + 20);
			end

			b:SetScript ("OnClick", function (self)
				gAn_Diag.clicked = (gAn_Diag.clicked or 0) + 1;
				local nm = Atr_An_BuyItemName ();
				gAn_Diag.clickName = nm or "(none)";
				if (nm) then
					gAn_Diag.shown = Atr_An_ShowItemMenu (self, nm, mode);
				end
			end);

			b:SetScript ("OnEnter", function (self)
				gAn_Diag.hovered = (gAn_Diag.hovered or 0) + 1;
				if (GameTooltip) then
					GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
					GameTooltip:SetText (AZT (tipTitle), 1, 1, 1);
					GameTooltip:AddLine (AZT (tipBody), 0.8, 0.8, 0.8, true);
					GameTooltip:Show();
				end
			end);
			b:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

			return b;
		end

		-- The panel's own "Add Item To List" button adds whatever is in the SEARCH
		-- BOX, which on a broad search is the search term and not this item -- so
		-- searching "silk" and pressing it files "silk".  This one files the item
		-- you are looking at, and asks which list.
		local tolist = headerButton ("Atr_An_BuyListButton", 100, "+Shopping list", "lists",
			"Add to a shopping list",
			"Adds THIS item -- not the search term -- to a shopping list of your choosing.");
		tolist:SetPoint ("TOPLEFT", nameFS, "BOTTOMLEFT", 2, -8);

		local watch = headerButton ("Atr_An_BuyWatchButton", 76, "+Analysis", "groups",
			"Watch on the Analysis tab",
			"Adds this item to an Analysis group, so searches start counting what sells.");
		watch:SetPoint ("LEFT", tolist, "RIGHT", 6, 0);
	end
end

if (SlashCmdList) then
	SLASH_ATRANALYSIS1 = "/atranalysis";
	SlashCmdList["ATRANALYSIS"] = function (msg)
		msg = tostring (msg or ""):gsub ("^%s+", ""):gsub ("%s+$", "");
		local cmd, rest = msg:match ("^(%S+)%s*(.*)$");
		if (cmd == "add" and rest ~= "") then
			An_AddWatchFromText (rest);		-- same path as the Add button's popup
		elseif (cmd == "group" and rest ~= "") then
			Atr_An_AddGroup (rest);
		elseif (cmd == "trades" or cmd == "market" or cmd == "craft") then
			-- the toggle buttons do this; the command exists because a button on
			-- this tab has been reported dead three times (item 22) and a second
			-- way in costs two lines
			Atr_An_SetView (cmd);
		elseif (cmd == "diag") then

			-- THE LAST RESORT, and the reason is on the record: the Buy tab's
			-- buttons have now been reported dead three times, and every remaining
			-- explanation -- the click never arriving, the menu never drawing, the
			-- menu drawing somewhere invisible -- produces exactly the same report
			-- from outside the client.  This prints the three facts that separate
			-- them, in one command, instead of another round trip per guess.
			local out = {};
			local function say (t) tinsert (out, tostring (t)); end

			local function frameLine (label, f)
				if (f == nil) then say (label..": MISSING"); return; end
				say (string.format ("%s: shown=%s visible=%s strata=%s level=%s mouse=%s pos=%s,%s size=%sx%s",
					label,
					tostring (f:IsShown()), tostring (f:IsVisible()),
					tostring (f.GetFrameStrata and f:GetFrameStrata()),
					tostring (f.GetFrameLevel and f:GetFrameLevel()),
					tostring (f.IsMouseEnabled and f:IsMouseEnabled()),
					tostring (f.GetLeft and f:GetLeft()), tostring (f.GetTop and f:GetTop()),
					tostring (f.GetWidth and f:GetWidth()), tostring (f.GetHeight and f:GetHeight())));
			end

			say (string.format ("hovered=%d clicked=%d menuShown=%s clickedItem=%s",
				gAn_Diag.hovered or 0, gAn_Diag.clicked or 0,
				tostring (gAn_Diag.shown), tostring (gAn_Diag.clickName)));
			say (string.format ("buy item now = %s", tostring (Atr_An_BuyItemName ())));

			frameLine ("+Analysis btn", Atr_An_BuyWatchButton);
			frameLine ("+Shopping btn", Atr_An_BuyListButton);
			frameLine ("menu", _G["Atr_An_ItemMenu"]);
			frameLine ("eater", _G["Atr_An_ItemMenuEater"]);
			frameLine ("AuctionFrame", _G["AuctionFrame"]);
			frameLine ("Atr_Main_Panel", _G["Atr_Main_Panel"]);

			if (GetMouseFocus) then
				local mf = GetMouseFocus();
				say ("mouse is over: "..tostring (mf and mf.GetName and mf:GetName() or mf));
			end

			-- into a window, not chat: the whole point is that this comes BACK
			Atr_An_ShowDebugBox (AZT("Auctionator diag -- Ctrl+C to copy"), table.concat (out, "\n"));

		elseif (cmd == "menu") then
			-- DIAGNOSTIC, and the reason it exists is worth stating: the Buy tab's
			-- buttons did nothing through two attempts, and from outside the client
			-- "the click never fired" and "the menu never showed" look identical.
			-- This opens the same menu without a button in the way, so the next
			-- report separates them in one step instead of one round trip.
			local nm = Atr_An_BuyItemName () or rest;
			if (nm == nil or nm == "") then
				if (zc and zc.msg_atr) then zc.msg_atr (AZT("usage: /atranalysis menu <item name>, or open an item on the Buy tab first")); end
			elseif (not Atr_An_ShowItemMenu (nil, nm, "both")) then
				if (zc and zc.msg_atr) then zc.msg_atr (AZT("Analysis: the menu could not be built")); end
			end
		else
			if (zc and zc.msg_atr) then
				zc.msg_atr (AZT("usage: /atranalysis add <item name or shift-clicked link>  |  group <name>  |  market  |  trades  |  craft  |  menu [item name]  |  diag"));
			end
		end
		Atr_An_Redisplay ();
	end
end
