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
-- Storage: AUCTIONATOR_ANALYSIS, account-wide, declared in the .toc.

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
		if (r and r.name and Atr_An_IsWatched (r.name)) then
			local t = byName[r.name];
			if (t == nil) then t = {}; byName[r.name] = t; end
			tinsert (t, { owner = r.owner, count = r.count, buyout = r.buyoutPrice, timeLeft = r.timeLeft });
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
	if (not Atr_An_IsWatched (itemName)) then return; end

	local bag = srch.anListings;
	if (bag == nil) then bag = {}; srch.anListings = bag; end

	local tl = 0;
	if (index and type (GetAuctionItemTimeLeft) == "function") then
		tl = GetAuctionItemTimeLeft ("list", index) or 0;
	end

	tinsert (bag, { name = itemName, owner = owner, count = count, buyoutPrice = buyout, timeLeft = tl });
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
local AN_ROW_W    = 660;

-- ONE definition of the columns, used to build both the headers and the cells.
-- They were two separate lists and had drifted apart: every header sat at the
-- LEFT edge of a column whose value was centred or right-aligned, so nothing
-- lined up, and the right-hand pair overlapped -- "Low" ran under the "Gold/day"
-- header and "Gold/day" ran under the per-row delete button.  Deriving both from
-- this table is what stops that happening again.
--
-- `x` is relative to a row; a header is the same x shifted by the scroll frame's
-- own inset (AN_HEAD_X0).  Columns end at 630 because the last 30px of the row
-- belong to the delete button, and the scroll bar owns 664 and beyond (the same
-- budget the Ledger's rows use).
local AN_HEAD_X0 = 14;

local AN_COLS = {
	{ key = "item",		head = "Item",		x = 6,	 w = 184					},
	{ key = "grp",		head = "Group",		x = 194, w = 74						},
	{ key = "sellers",	head = "Sellers",	x = 272, w = 48,  just = "CENTER"	},
	{ key = "listings",	head = "Listings",	x = 324, w = 54,  just = "CENTER"	},
	{ key = "rate",		head = "Sold/day",	x = 382, w = 68,  just = "CENTER",
	  tip = "An estimate. Counted from listings that disappeared between two scans, so it is a floor, not an exact count." },
	{ key = "low",		head = "Low",		x = 454, w = 84,  just = "RIGHT"	},
	{ key = "farm",		head = "Gold/day",	x = 542, w = 88,  just = "RIGHT",
	  tip = "An estimate: Sold/day valued at the current lowest price. A rate, not a promise." },
};

local gAn_Group = nil;		-- nil = every group

local function An_Money (c)
	if (c == nil or c == 0) then return "|cff666666--|r"; end
	if (zc and zc.priceToMoneyString) then return zc.priceToMoneyString (c); end
	return tostring (c);
end

-- Watched items in the current group, best farm score first.  Items never
-- scanned sort last: they have nothing to say yet, and pretending a missing
-- number is a zero would rank them as the worst rather than as unknown.
local function An_Rows ()

	local db   = Atr_An_DB ();
	local out  = {};

	local name, w;
	for name, w in pairs (db.watch) do
		if (gAn_Group == nil or (w.group or "") == gAn_Group) then
			tinsert (out, { name = name, group = w.group, st = Atr_An_Stats (name) });
		end
	end

	table.sort (out, function (a, b)
		-- rank on the upper bound: for a slow scanner the lower bound is 0 for
		-- almost everything, and a ranking where everything ties is no ranking
		local fa = a.st and a.st.farmMax;
		local fb = b.st and b.st.farmMax;
		if (fa and fb) then return fa > fb; end
		if (fa) then return true; end
		if (fb) then return false; end
		return a.name < b.name;
	end);

	return out;
end

function Atr_An_Redisplay ()

	if (not Atr_An_Panel or not Atr_An_Panel:IsShown()) then return; end

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
				line:Show();
			end
		end
	end

	if (Atr_An_Summary) then
		local watched = 0;
		local nm;
		for nm in pairs (Atr_An_DB ().watch) do watched = watched + 1; end
		Atr_An_Summary:SetText (string.format (
			AZT("%d watched   |   a range means some listings could have expired -- scan more often to narrow it   |   turnover is a floor: anything posted and sold between two scans is invisible"),
			watched));
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
			r.text:SetText ("|cff888888"..e.text.."|r");
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

	local rows = An_Rows ();
	local q, i = {}, nil;
	for i = 1, #rows do tinsert (q, rows[i].name); end

	if (#q == 0) then
		if (zc and zc.msg_atr) then
			zc.msg_atr (AZT("Analysis: nothing watched here yet -- add an item first"));
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
		Atr_An_Redisplay ();
	else
		-- the pump follows the current pane, so a run cannot survive the tab
		Atr_An_RefreshStop (true);
		if (Atr_An_HideItemMenu) then Atr_An_HideItemMenu (); end
		Atr_An_Panel:Hide();
	end
end

function Atr_An_Init ()

	if (Atr_An_Panel or type (CreateFrame) ~= "function") then return; end

	local panel = CreateFrame ("Frame", "Atr_An_Panel", AuctionFrame);
	panel:SetSize (738, 447);
	panel:SetPoint ("TOPLEFT", 10, 0);
	panel:Hide();

	local bg = panel:CreateTexture (nil, "BACKGROUND");
	bg:SetTexture (0, 0, 0, 0.85);
	bg:SetPoint ("TOPLEFT", 14, -70);
	bg:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -12, 28);

	local title = panel:CreateFontString (nil, "BACKGROUND", "GameFontNormal");
	title:SetPoint ("TOP", -10, -18);
	title:SetText ("Auctionator - "..AZT("Analysis"));

	-- add box: type a name or shift-click an item link into it
	local addLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	addLabel:SetPoint ("TOPLEFT", 20, -40);
	addLabel:SetText (AZT("Watch item"));

	local addBox = CreateFrame ("EditBox", "Atr_An_AddBox", panel, "InputBoxTemplate");
	addBox:SetSize (180, 20);
	addBox:SetPoint ("TOPLEFT", 24, -52);
	addBox:SetAutoFocus (false);
	addBox:SetMaxBytes (96);

	local function doAdd ()
		local txt = addBox:GetText();
		if (txt == nil or txt == "") then return; end
		-- a shift-clicked link arrives as the whole hyperlink; keep the name
		local name = txt:match ("%[(.-)%]") or txt;
		if (Atr_An_Watch (name, gAn_Group)) then
			if (zc and zc.msg_atr) then zc.msg_atr (string.format (AZT("Analysis: watching %s"), name)); end
		end
		addBox:SetText ("");
		addBox:ClearFocus();
		Atr_An_Redisplay ();
	end

	addBox:SetScript ("OnEnterPressed", doAdd);
	addBox:SetScript ("OnEscapePressed", function (self) self:SetText (""); self:ClearFocus(); end);

	local addBtn = CreateFrame ("Button", "Atr_An_AddButton", panel, "UIPanelButtonTemplate");
	addBtn:SetSize (46, 22);
	addBtn:SetPoint ("LEFT", addBox, "RIGHT", 6, 0);
	addBtn:SetText (AZT("Add"));
	addBtn:SetScript ("OnClick", doAdd);

	-- group filter
	if (UIDropDownMenu_Initialize) then
		local dd = CreateFrame ("Frame", "Atr_An_GroupDD", panel, "UIDropDownMenuTemplate");
		dd:SetPoint ("TOPLEFT", 290, -48);
		UIDropDownMenu_SetWidth (dd, 110);
		UIDropDownMenu_Initialize (dd, An_GroupDD_Init);
		UIDropDownMenu_SetText (dd, AZT("All groups"));
	end

	local newGrp = CreateFrame ("EditBox", "Atr_An_GroupBox", panel, "InputBoxTemplate");
	newGrp:SetSize (110, 20);
	newGrp:SetPoint ("TOPLEFT", 440, -52);
	newGrp:SetAutoFocus (false);
	newGrp:SetMaxBytes (32);
	newGrp:SetScript ("OnEnterPressed", function (self)
		local g = self:GetText();
		if (g and g ~= "") then
			Atr_An_AddGroup (g);
			gAn_Group = g;
			if (Atr_An_GroupDD) then UIDropDownMenu_SetText (Atr_An_GroupDD, g); end
		end
		self:SetText (""); self:ClearFocus();
		Atr_An_Redisplay ();
	end);
	newGrp:SetScript ("OnEscapePressed", function (self) self:SetText (""); self:ClearFocus(); end);

	local grpLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	grpLabel:SetPoint ("TOPLEFT", 436, -40);
	grpLabel:SetText (AZT("New group"));

	-- headers: same x, width and justification as the cells beneath them
	local c;
	for _, c in ipairs (AN_COLS) do

		local fs = panel:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
		fs:SetPoint ("TOPLEFT", AN_HEAD_X0 + c.x, -74);
		fs:SetWidth (c.w);
		fs:SetJustifyH (c.just or "LEFT");
		fs:SetText (AZT (c.head));

		-- A FontString cannot take scripts, so a column with something to explain
		-- gets an invisible hit frame over its header.  It stops above the scroll
		-- frame (-92) so it cannot eat a click meant for a row.
		if (c.tip) then
			local col = c;
			local hit = CreateFrame ("Frame", nil, panel);
			hit:SetPoint ("TOPLEFT", AN_HEAD_X0 + col.x, -72);
			hit:SetSize (col.w, 16);
			hit:EnableMouse (true);
			hit:SetScript ("OnEnter", function (self)
				if (GameTooltip) then
					GameTooltip:SetOwner (self, "ANCHOR_BOTTOMRIGHT");
					GameTooltip:SetText (AZT (col.head), 1, 1, 1);
					GameTooltip:AddLine (AZT (col.tip), 0.8, 0.8, 0.8, true);
					GameTooltip:Show();
				end
			end);
			hit:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);
		end
	end

	local scroll = CreateFrame ("ScrollFrame", "Atr_An_ScrollFrame", panel, "FauxScrollFrameTemplate");
	scroll:SetPoint ("TOPLEFT", 14, -92);
	scroll:SetSize (690, AN_NUM_ROWS * AN_ROW_H);
	scroll:SetScript ("OnVerticalScroll", function (self, offset)
		if (FauxScrollFrame_OnVerticalScroll) then
			FauxScrollFrame_OnVerticalScroll (self, offset, AN_ROW_H, Atr_An_Redisplay);
		end
	end);

	local holder = CreateFrame ("Frame", nil, panel);
	holder:SetPoint ("TOPLEFT", AN_HEAD_X0, -92);
	holder:SetSize (AN_ROW_W, AN_NUM_ROWS * AN_ROW_H);

	local i;
	for i = 1, AN_NUM_ROWS do

		local line = CreateFrame ("Button", "Atr_An_Row"..i, holder);
		line:SetSize (AN_ROW_W, AN_ROW_H);
		line:SetPoint ("TOPLEFT", 0, -(i - 1) * AN_ROW_H);

		local cc;
		for _, cc in ipairs (AN_COLS) do
			local fs = line:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			fs:SetPoint ("LEFT", cc.x, 0);
			fs:SetWidth (cc.w);
			fs:SetJustifyH (cc.just or "LEFT");
			line[cc.key] = fs;
		end

		-- its own lane past the last column, so it stops sitting on the numbers
		local del = CreateFrame ("Button", nil, line, "UIPanelCloseButton");
		del:SetSize (20, 20);
		del:SetPoint ("RIGHT", -4, 0);
		del:SetScript ("OnClick", function ()
			if (line.rec) then Atr_An_Unwatch (line.rec.name); Atr_An_Redisplay (); end
		end);

		-- the item's own tooltip, the way the Ledger's rows do it.  A watch entry
		-- stores only a name, so the link comes from the shared cache -- which
		-- means no tooltip until something has seen the item, and that is better
		-- than inventing a link from a name.
		line:SetScript ("OnEnter", function (self)
			local link = self.rec and Atr_GetItemLink and Atr_GetItemLink (self.rec.name);
			if (link and GameTooltip) then
				GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
				GameTooltip:SetHyperlink (link);
				GameTooltip:Show();
			end
		end);
		line:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

		line:Hide();
	end

	-- Given a width so it wraps instead of running off the panel and under the
	-- rescan button; anchored BOTTOMLEFT, so extra lines grow upward.
	local summary = panel:CreateFontString ("Atr_An_Summary", "ARTWORK", "GameFontNormalSmall");
	summary:SetPoint ("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 34);
	summary:SetWidth (520);
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
			GameTooltip:AddLine (AZT("One search per item, in sequence. Stays on this tab -- leaving it stops the run."), 0.8, 0.8, 0.8, true);
			GameTooltip:Show();
		end
	end);
	refresh:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

	local progress = panel:CreateFontString ("Atr_An_Progress", "ARTWORK", "GameFontNormalSmall");
	progress:SetPoint ("RIGHT", refresh, "LEFT", -8, 0);
	progress:SetJustifyH ("RIGHT");
	progress:SetText ("");

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
			local name = rest:match ("%[(.-)%]") or rest;
			Atr_An_Watch (name);
			if (zc and zc.msg_atr) then zc.msg_atr (string.format (AZT("Analysis: watching %s"), name)); end
		elseif (cmd == "group" and rest ~= "") then
			Atr_An_AddGroup (rest);
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
				zc.msg_atr (AZT("usage: /atranalysis add <item name or shift-clicked link>  |  group <name>  |  menu [item name]  |  diag"));
			end
		end
		Atr_An_Redisplay ();
	end
end
