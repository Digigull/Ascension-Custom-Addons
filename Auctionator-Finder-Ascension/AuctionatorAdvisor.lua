--[[--------------------------------------------------------------------------

AuctionatorAdvisor.lua -- the Advisor tab.  BACKLOG item 30.

WHAT IT IS.  Five or six cards, in sentences, saying what to do about the
evidence on the Analysis tab.  Analysis holds what is TRUE; this holds what to
do about it.  One is four dense sortable tables for checking the working, the
other is a page you read in ten seconds.

THE ONE RULE: THE ADVISOR COMPUTES NOTHING.  Every card is a reading of a figure
some other subsystem already returns, and every card links back to the row it
came from.  This is FRAMEWORK.md section 6's rule -- the arithmetic lives with
the data -- and it is the whole of why this file is cheap.  An Advisor that did
its own sums would be a second opinion nobody asked for, and the first time it
disagreed with a table on the tab next door the addon would stop being
trustworthy.

Where a card needs a figure nobody returned yet, the fix is to add it to the
subsystem that owns the data, not to work it out here.  That is exactly what
Atr_Craft_TopReagent (AuctionatorFinderProfession.lua) is: the Make card wants
"74% of the cost is Essence of Fire", so the share is computed beside the craft
cost it is a share OF, through the same reagent cascade, where it cannot
disagree.  Ratios of two figures one table already prints side by side -- a
reagent's outlay over the bill's total, say -- are read here, because that is
reading a table and not re-deriving it.

WHAT IT READS, and it is the entire list:

    Atr_Craft_ProfitRanking()             what is worth making
    Atr_Craft_TopReagent(entry)           ...and which reagent that cost is
    Atr_Craft_ReagentPressure(rank, plan) what you would have to buy
    Atr_An_Stats(name)                    per watched item: depth, rates, sellers
    Atr_An_PlanMap() / Atr_An_PlanBatch() the plan, for the Make card's button
    Atr_Ledger_ItemTotals()               what actually happened

No new capture, no new saved variable, no event handler.  It is a renderer.

WHAT IT EXPORTS

    Atr_Advisor_Init()          builds the panel (called from Auctionator.lua)
    Atr_Advisor_OnTabClick(i)   show/hide with the tab
    Atr_Advisor_Redisplay()     rebuild the cards
    Atr_Advisor_Cards()         the cards as data -- no UI, guarded around every
                                WoW API, so the rules can be read and checked
                                without a client

THREE THINGS THAT MAKE OR BREAK IT (owner, 2026-08-20), and each one is a rule
enforced below rather than an aspiration:

  * THE NUMBER IS IN THE SENTENCE.  Never a bare "make this".  A card that
    cannot name the figure it is arguing from does not fire.
  * IT MUST BE WILLING TO SAY IT HAS NOTHING.  On a fresh install "not enough
    data yet, and here is what would give me some" is the most useful thing
    this tab can say.  Adv_NothingCard is that state, and it is a feature.
  * FIVE OR SIX CARDS, RANKED BY GOLD AT STAKE.  An advisor listing forty
    things has become a table again, which is the tab next door.

--------------------------------------------------------------------------]]--

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

local function DZT (s)
	if (ZT) then return ZT (s); end
	return s;
end

-- THE THRESHOLDS ------------------------------------------------------------
--
-- Gathered here rather than buried in the rules, because every one of them is a
-- judgement about when advice is worth giving and they should be arguable in
-- one place.

local ADV_MIN_PERCRAFT	= 10000;		-- 1g.  Below this "make this" is not advice,
										-- it is noise: the walk to the trainer costs
										-- more than the craft returns.
local ADV_MIN_MARGIN	= 0.15;			-- 15% of the sale price.  A thin margin over a
										-- cost estimate is inside the estimate's own error.
local ADV_BILL_SHARE	= 0.35;			-- one reagent is "dominating" the shopping bill at
										-- a third of it: that is the price that decides
										-- whether the batch is worth starting.
local ADV_TOP_SHARE		= 0.80;			-- one seller holding this much of an item's
										-- listings can move its price at will.
local ADV_MIN_LISTINGS	= 3;			-- ...but not over two listings.  "One seller holds
										-- 100%" of a two-listing book is arithmetic, not a
										-- cartel.
local ADV_MIN_SCANS		= 2;			-- never argue from a single observation.  The
										-- Market view already refuses to and this inherits it.
local ADV_STALE_SECS	= 3 * 24 * 60 * 60;	-- 3 days, and the number is not free-standing:
										-- it is ATR_AN_MAX_GAP, the point at which a watched
										-- item stops accumulating at all.  Past it the rates
										-- below have stopped being updated, which is exactly
										-- when the tab should say so.
local ADV_MAX_CARDS		= 6;
local ADV_WATCH_GROUP	= "Advisor";	-- the Analysis group the Watch button files into,
										-- created on first use.  One group for everything
										-- this tab suggested, so you can always tell it
										-- apart from what you put on the list yourself.
local ADV_CARD_ITEMS	= 3;			-- how many candidates a card offers you to choose
										-- between.  Three, because the point of offering a
										-- choice is that the top one might be a thing you
										-- will not do -- and a fourth turns the card back
										-- into the table on the tab next door.

-- MONEY IN A SENTENCE -------------------------------------------------------
--
-- Gold and silver only, and no placeholder for nil -- a card that cannot price
-- something does not fire, so there is never a "--" to print.  Deliberately not
-- shared with An_Money (AuctionatorAnalysis.lua): that one is for a
-- right-aligned table cell and returns a grey dash for an empty one, which
-- inside a sentence would read as a typo.
local ADV_GOLD	 = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:4:0|t";
local ADV_SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:4:0|t";

local function Adv_Money (c)

	c = tonumber (c);
	if (c == nil) then return "?"; end

	if (zc == nil or zc.val2gsc == nil) then return tostring (c); end

	local g, s = zc.val2gsc (c);

	if (g ~= 0) then
		if (s ~= 0) then return string.format ("%d%s %02d%s", g, ADV_GOLD, s, ADV_SILVER); end
		return string.format ("%d%s", g, ADV_GOLD);
	end

	return string.format ("%d%s", s, ADV_SILVER);
end

local function Adv_Pct (f)
	return string.format ("%d%%", math.floor ((tonumber (f) or 0) * 100 + 0.5));
end

local function Adv_Days (secs)
	local d = (tonumber (secs) or 0) / 86400;
	if (d < 1.5) then return DZT("a day"); end
	return string.format (DZT("%d days"), math.floor (d + 0.5));
end


-- WHAT YOU TOLD IT ----------------------------------------------------------
--
-- The tab now remembers decisions, which is a real change to the "it computes
-- nothing" rule above and worth being exact about: **it still derives nothing.**
-- Every FIGURE on this page is still read from another subsystem.  What is
-- stored here is only what YOU said about a recommendation -- and your own
-- decisions are an input, not a derived number, so there is nothing here for a
-- table on the next tab to disagree with.
--
-- FOUR PIECES OF STATE, and only one of them is not saved:
--
--   ignore  a permanent "stop suggesting this".  The high-risk PvP material you
--           are never going to farm is the case that asked for it -- an advisor
--           that keeps recommending it has not understood you.  Undoable from
--           the Ignored list button on the panel; nothing else can clear it.
--   skip    "next one, please".  SESSION ONLY, deliberately: it means move past
--           this recommendation, not that the recommendation is wrong.  A
--           /reload brings it back, which is the correct amount of memory for
--           a decision you made about today.
--   slow    a recipe you have flagged as a slow mover.  Saved, because it is a
--           fact about the market that does not stop being true at logout.
--   farm    the farm list.  Saved, and read out by Atr_Advisor_FarmList() --
--           which exists so the minimap window over it is a reader rather than a
--           second copy.  That window is now built: AuctionatorFarmList.lua
--           (item 34).  The entry also keeps the gold-per-day rate AS IT WAS
--           when you ticked it -- see Atr_Advisor_SetFarmed for why.
--
-- ITS OWN SAVED VARIABLE, not a corner of AUCTIONATOR_ANALYSIS.  The farm list
-- is opened from a minimap button, away from the auction house and away from the
-- Analysis tab entirely; making that reader load the watchlist database to find
-- out what to farm would have been the wrong dependency.  It paid off exactly as
-- written: AuctionatorFarmList.lua reads Atr_Advisor_FarmList() and nothing else.
--
-- KEYED BY NAME, like everything else on this page.  The ID is stored beside it
-- where one is known, because the farm list wants an icon and a link, but it is
-- the name that matches -- the same limitation, and the same reason, as the
-- mean price database and the watchlist (BACKLOG item 12 part 3b).

function Atr_Advisor_DB ()

	if (type (AUCTIONATOR_ADVISOR) ~= "table") then AUCTIONATOR_ADVISOR = {}; end

	local db = AUCTIONATOR_ADVISOR;
	if (db.ver == nil) then db.ver = 1; end
	if (type (db.ignore) ~= "table") then db.ignore = {}; end
	if (type (db.slow)   ~= "table") then db.slow   = {}; end
	if (type (db.farm)   ~= "table") then db.farm   = {}; end

	return db;
end

local function Adv_Now ()
	return (type (time) == "function") and time() or 0;
end

-- Skipped THIS SESSION.  A plain local, and that is the whole implementation:
-- there is no file to write because forgetting at logout is the feature.
local gAdv_Skip = {};

-- WATCHED FROM THIS TAB, THIS VISIT -- and this one is not a convenience, it is
-- what makes the "Added!" feedback possible at all.  The Watch card's candidates
-- are BY DEFINITION the reagents that are not watched, so the instant the button
-- works the row qualifies for removal and the next candidate slides into its
-- place.  The button would flash out of existence rather than ever reading
-- "Added!", and the click would look exactly like a click that did nothing --
-- which is the confusion the label was asked for in the first place.
--
-- So a name watched from here is held on the card until you LEAVE the tab.
-- Cleared on the way in (Atr_Advisor_OnTabClick), not on a timer: coming back to
-- the tab is when you want fresh suggestions, and staying on it is when you want
-- to see what you just did.
local gAdv_JustWatched = {};

local function Adv_MarkJustWatched (name)
	if (name) then gAdv_JustWatched[name] = true; end
end

local function Adv_ClearJustWatched ()
	gAdv_JustWatched = {};
end

function Atr_Advisor_IsIgnored (name)
	return (name ~= nil) and (Atr_Advisor_DB ().ignore[name] ~= nil);
end

function Atr_Advisor_SetIgnored (name, on)
	if (name == nil or name == "") then return; end
	Atr_Advisor_DB ().ignore[name] = on and Adv_Now () or nil;
end

function Atr_Advisor_IsSlow (name)
	return (name ~= nil) and (Atr_Advisor_DB ().slow[name] ~= nil);
end

function Atr_Advisor_SetSlow (name, on)
	if (name == nil or name == "") then return; end
	Atr_Advisor_DB ().slow[name] = on and Adv_Now () or nil;
end

function Atr_Advisor_IsFarmed (name)
	return (name ~= nil) and (Atr_Advisor_DB ().farm[name] ~= nil);
end

-- `gold` IS THE RATE AS IT WAS WHEN YOU TICKED IT, and storing it is the whole
-- of item 34's one honest limit.  What made something worth farming was a
-- gold-per-day figure at the auction house's prices, and the window that reads
-- this list is opened in a zone with no auction house in it -- so the figure
-- cannot be recomputed there, and a live-LOOKING number that is three days old
-- is worse than an obviously old one.  It is stamped with `t` and the window
-- prints the two together.
--
-- Re-ticking an item that is already on the list leaves the original stamp
-- alone: the entry says when you decided, and deciding twice is still once.
function Atr_Advisor_SetFarmed (name, on, id, gold)
	if (name == nil or name == "") then return; end
	local db = Atr_Advisor_DB ();
	if (on) then
		local e = db.farm[name];
		if (e == nil) then e = { t = Adv_Now () }; db.farm[name] = e; end
		if (id and e.id == nil) then e.id = id; end
		if (gold and e.gold == nil) then e.gold = gold; end
	else
		db.farm[name] = nil;
	end

	-- The window and the minimap count are readers of this table, and a reader
	-- that has to be told to look again is a reader that will be forgotten.  It
	-- may not be loaded yet -- ticking works with or without it.
	if (type (Atr_Farm_Refresh) == "function") then Atr_Farm_Refresh (); end
end

-- THE FARM LIST AS A LIST, sorted by name, which is what a window renders.
-- Global and free of any WoW API: the minimap reader this is for does not exist
-- yet, and the one thing that would make writing it awkward is having to reach
-- into a saved table's shape.
function Atr_Advisor_FarmList ()

	local out = {};
	local name, e;
	for name, e in pairs (Atr_Advisor_DB ().farm) do
		table.insert (out, { name = name, id = e.id, t = e.t, gold = e.gold });
	end

	table.sort (out, function (a, b) return a.name < b.name; end);

	return out;
end

function Atr_Advisor_IgnoreList ()

	local out = {};
	local name, t;
	for name, t in pairs (Atr_Advisor_DB ().ignore) do
		table.insert (out, { name = name, t = t });
	end

	table.sort (out, function (a, b) return a.name < b.name; end);

	return out;
end

-- Whether a candidate should be offered at all.  The two suppressions are read
-- through one function so no rule can accidentally honour one and not the other.
local function Adv_Suppressed (name)
	if (name == nil) then return true; end
	if (gAdv_Skip[name]) then return true; end
	return Atr_Advisor_IsIgnored (name);
end

-- WHERE A CARD SENDS YOU ----------------------------------------------------
--
-- Every card links back to the row it came from, which is half of what makes it
-- checkable.  The filter box does the finding: it is a plain substring match on
-- every view (An_SetFilter), so setting its text IS "show me this row", and its
-- own OnTextChanged does the redisplay.  Nothing here reaches into the Analysis
-- tab's internals.
local function Adv_ShowInAnalysis (view, itemName)

	if (type (Atr_SelectPane) ~= "function" or ATR_ANALYSIS_TAB == nil) then return; end

	Atr_SelectPane (ATR_ANALYSIS_TAB);				-- shows the panel; SetView redisplays into it
	if (Atr_An_SetView) then Atr_An_SetView (view); end

	local box = _G["Atr_An_FilterBox"];
	if (box and box.SetText) then box:SetText (itemName or ""); end
end

-- READING THE FOUR SUBSYSTEMS ------------------------------------------------

-- Every watched item's stats, once, with the name attached.  Several rules walk
-- this and Atr_An_Stats is a table build per call.
local function Adv_WatchedStats ()

	local out, watched = {}, 0;

	if (type (Atr_An_DB) ~= "function" or type (Atr_An_Stats) ~= "function") then
		return out, watched;
	end

	local name;
	for name in pairs (Atr_An_DB ().watch) do
		watched = watched + 1;
		local st = Atr_An_Stats (name);
		if (st) then
			st.name = name;
			table.insert (out, st);
		end
	end

	return out, watched;
end

-- THE RULES ------------------------------------------------------------------
--
-- One function per card.  Each takes the read-out data and returns a card or
-- nil; none of them touches a frame, so what fires and what it says can be read
-- straight down the file.
--
-- A card is
--   { kind, head, text, gold, band, act = { { label, fn }, ... } }
-- `gold` is what is at stake, which is what the page sorts on, and `band` is the
-- coarse order above it: a warning that qualifies every figure below it has to
-- come first however little money is riding on the warning itself.

local ADV_BAND_WARN	= 1;		-- qualifies everything under it
local ADV_BAND_MONEY = 2;		-- ranked among themselves by gold at stake
local ADV_BAND_SETUP = 3;		-- "do this and I can tell you more"

-- STALE.  Not a money card: it is the caveat on every rate below it, so it
-- outranks all of them and carries no gold.
local function Adv_StaleCard (stats, watched)

	if (watched == 0) then return nil; end
	if (type (time) ~= "function") then return nil; end

	local now, newest = time (), nil;
	local i;
	for i = 1, #stats do
		local last = stats[i].last;
		if (last and (newest == nil or last > newest)) then newest = last; end
	end

	if (newest == nil) then
		return { kind = "stale", band = ADV_BAND_WARN,
				 head = DZT("Nothing scanned yet"),
				 text = string.format (DZT("Nothing on your watchlist (%d %s) has ever been scanned. Every rate on this page needs two scans of the same item before it means anything."),
									   watched, (watched == 1) and DZT("item") or DZT("items")),
				 act = { { label = DZT("Rescan"), fn = "rescan" } } };
	end

	local age = now - newest;
	if (age < ADV_STALE_SECS) then return nil; end

	return { kind = "stale", band = ADV_BAND_WARN,
			 head = DZT("Your prices are stale"),
			 text = string.format (DZT("Nothing has been scanned for %s. Watched items stop accumulating after three days, so every rate below is guesswork until you rescan."), Adv_Days (age)),
			 act = { { label = DZT("Rescan"), fn = "rescan" } } };
end

-- MAKE.  What is worth making, with the catch that comes with each one, and a
-- row per candidate so you can take the second one when the first is a craft you
-- are not going to sit on.
local function Adv_MakeCard (rank, byName)

	if (type (rank) ~= "table") then return nil; end

	-- EVERY ENTRY THAT CLEARS BOTH GATES, not just the first.  The ranking sorts
	-- by perCraft, which is an ABSOLUTE figure, so a big-ticket recipe returning
	-- 40g on a 3800g outlay heads the list while earning 1% -- and stopping at
	-- rank[1] would let it veto the 300g-at-69% recipe two rows below it.
	-- Collecting is still reading the ranking's own order, not a re-sort; the
	-- walk stops at 20 because a recipe further down the perCraft order is not
	-- the answer to "what should I make" whatever its margin.
	local cand = {};
	local n;
	for n = 1, math.min (#rank, 20) do
		local e = rank[n];
		if (e.perCraft and e.perCraft >= ADV_MIN_PERCRAFT and e.sell and e.sell > 0
			and not Adv_Suppressed (e.name)) then
			local m = (e.sell - (e.cost or 0)) / e.sell;
			if (m >= ADV_MIN_MARGIN) then
				table.insert (cand, { e = e, margin = m, slow = Atr_Advisor_IsSlow (e.name) });
			end
		end
	end

	if (#cand == 0) then return nil; end

	-- SLOW MOVERS SINK, and that is the whole of what the flag does to the order.
	-- A recipe you have told this tab you will be holding for a week is still
	-- worth making -- it has not stopped earning its margin -- but it is not the
	-- first thing to suggest to somebody asking what to make today.  Within each
	-- half the order is untouched, which keeps it the ranking's own.
	table.sort (cand, function (a, b)
		if (a.slow ~= b.slow) then return b.slow; end
		if (a.e.perCraft ~= b.e.perCraft) then return a.e.perCraft > b.e.perCraft; end
		return (a.e.name or "") < (b.e.name or "");
	end);

	local batch = (type (Atr_An_PlanBatch) == "function") and Atr_An_PlanBatch () or 1;

	local items = {};
	local i;
	for i = 1, math.min (ADV_CARD_ITEMS, #cand) do

		local c = cand[i];
		local e = c.e;

		local note = string.format (DZT("%s a craft at %s margin"),
									Adv_Money (e.perCraft), Adv_Pct (c.margin));

		-- THE CATCH, and it is the half that keeps somebody out of trouble: the
		-- same margin over one reagent ten people sell is a different
		-- proposition from the same margin spread over eight cheap ones.
		-- Computed where the craft cost is (Atr_Craft_TopReagent), so it can
		-- never be a share of a different total.
		if (type (Atr_Craft_TopReagent) == "function") then
			local top = Atr_Craft_TopReagent (e);
			if (top and top.name and top.share >= ADV_BILL_SHARE) then
				local st = byName[top.name];
				if (st and st.scans >= ADV_MIN_SCANS and st.sellers > 0) then
					note = note..string.format (DZT(". Catch: %s of that cost is %s, and %d sellers hold it"),
												Adv_Pct (top.share), top.name, st.sellers);
				else
					note = note..string.format (DZT(". Catch: %s of that cost is %s, which you have never scanned"),
												Adv_Pct (top.share), top.name);
				end
			end
		end

		if (c.slow) then
			note = note..DZT(". You flagged this a slow mover -- expect to hold it a week or more");
		end

		if (e.assumed) then
			note = note..DZT(". Yield assumed, not read from the profession window");
		end

		table.insert (items, {
			name	= e.name,
			id		= e.id,
			gold	= e.perCraft,
			note	= note,
			view	= "craft",
			ctl		= { plan = true, slow = true, ignore = true, skip = true },
			planLabel = string.format (DZT("Plan %d"), batch),
		});
	end

	return { kind = "make", band = ADV_BAND_MONEY, gold = items[1].gold,
			 head = DZT("Make this"),
			 text = string.format (DZT("%d of your recipes are worth making at today's prices. Tick one into the plan, or move past it."), #cand),
			 items = items };
end

-- BUY.  One reagent dominating the shopping bill.  The share is a ratio of two
-- figures the Reagents view prints in the same column, which is reading a table
-- rather than re-deriving it.
local function Adv_BuyCard (press, pstats, byName)

	if (press == nil or pstats == nil) then return nil; end
	if ((pstats.outlay or 0) <= 0) then return nil; end

	-- IGNORE IS HONOURED HERE TOO, even though this card carries no controls of
	-- its own.  "Stop suggesting this" has to mean the whole tab or it means
	-- nothing: being told about a reagent on one card immediately after telling
	-- the tab to drop it on another is exactly the behaviour the ignore list
	-- exists to stop.  Skip is session-scoped and rides along for the same reason.
	local top;
	local i;
	for i = 1, #press do
		local e = press[i];
		if (e.outlay and e.outlay > 0 and not Adv_Suppressed (e.name)
			and (top == nil or e.outlay > top.outlay)) then top = e; end
	end

	if (top == nil or top.name == nil) then return nil; end

	local share = top.outlay / pstats.outlay;
	if (share < ADV_BILL_SHARE) then return nil; end

	local text = string.format (DZT("%s is %s of your shopping bill -- %s of %s. Check its price before you commit to the batch."),
								top.name, Adv_Pct (share), Adv_Money (top.outlay), Adv_Money (pstats.outlay));

	-- ...and the second half of the same worry: whether it is there to buy.  The
	-- Reagents view's own Supply column, read out.
	local st = byName[top.name];
	if (top.vendor) then
		text = text..DZT("  A vendor sells it, so supply is not the problem -- the price is.");
	elseif (st and st.scans >= ADV_MIN_SCANS and st.units and top.need and st.units < top.need) then
		text = text..string.format (DZT("  Worse: the market held %d units at your last scan and this basket wants %d."),
									st.units, top.need);
	end

	-- The bill is the plan's if there is one, and the baseline reading if not.
	-- Saying which is the difference between "what you asked for costs this" and
	-- "what your professions lean on costs this", and they are not the same claim.
	local head = DZT("Buy carefully");
	if ((pstats.planned or 0) > 0) then
		head = string.format (DZT("Your batch of %d"), pstats.crafts or 0);
	end

	return { kind = "buy", band = ADV_BAND_MONEY, gold = top.outlay,
			 head = head, text = text,
			 act = { { label = DZT("Show me"), fn = "show", arg = top.name, view = "reagents" } } };
end

-- WATCH.  The reagents the bill leans on that nobody is watching -- which is
-- why the Supply column beside them is empty.
local function Adv_WatchCard (press, watched)

	if (press == nil or type (Atr_An_IsWatched) ~= "function") then return nil; end

	local cand, unwatched = {}, 0;
	local i;
	for i = 1, #press do
		local e = press[i];
		if (e.name and (e.need or 0) > 0 and not e.vendor and not Adv_Suppressed (e.name)) then
			-- ...or watched a moment ago FROM HERE, which is the one case a
			-- watched reagent still belongs on this card: see gAdv_JustWatched.
			if (not Atr_An_IsWatched (e.name)) then
				unwatched = unwatched + 1;
				table.insert (cand, e);
			elseif (gAdv_JustWatched[e.name]) then
				table.insert (cand, e);
			end
		end
	end

	if (#cand == 0) then return nil; end

	table.sort (cand, function (a, b)
		local ao, bo = a.outlay or 0, b.outlay or 0;
		if (ao ~= bo) then return ao > bo; end
		return (a.name or "") < (b.name or "");
	end);

	local items = {};
	for i = 1, math.min (ADV_CARD_ITEMS, #cand) do
		local e = cand[i];
		local note;
		if (e.outlay) then
			note = string.format (DZT("%s of the bill, over %d %s"), Adv_Money (e.outlay),
								  e.need, (e.need == 1) and DZT("unit") or DZT("units"));
		else
			note = string.format (DZT("%d wanted, never priced"), e.need);
		end
		table.insert (items, {
			name	= e.name,
			id		= e.id,
			gold	= e.outlay,
			note	= note,
			view	= "reagents",
			ctl		= { watch = true, ignore = true, skip = true },
		});
	end

	local text;
	if (watched == 0) then
		text = DZT("Your watchlist is empty, so I cannot tell you whether any of this is actually buyable. These are what your crafting leans hardest on.");
	elseif (unwatched == 0) then
		text = DZT("Everything your crafting leans on is on the watchlist now.");
	else
		-- counted over the UNWATCHED ones, not over the rows: a row you just
		-- watched is still on screen, and including it would make the sentence
		-- disagree with the button beside it.
		text = string.format (DZT("%d of the reagents your crafting depends on are not watched, so their Supply column is blank. These are the biggest."),
							  unwatched);
	end

	return { kind = "watch", band = ADV_BAND_SETUP, gold = cand[1].outlay,
			 head = DZT("Watch these"), text = text, items = items };
end

-- CAREFUL.  Two different ways to lose money, and at most one card: they are the
-- same warning wearing different evidence, and two of them would push a card
-- that tells you what to DO off a page of six.  The bigger number wins.
local function Adv_CarefulCard (stats, ledger)

	local function card (gold, head, text, arg, view)
		return { kind = "careful", band = ADV_BAND_MONEY, gold = gold, head = head, text = text,
				 act = { { label = DZT("Show me"), fn = "show", arg = arg, view = view } } };
	end

	local i;

	-- MONEY ALREADY LOST COMES FIRST, and not because it is the larger number --
	-- it usually is not.  The two halves of this card are not the same kind of
	-- claim: a realised loss is something that HAPPENED, a thin book is something
	-- that MIGHT.  Ranking them against each other by magnitude would let 20g of
	-- depth somebody else is holding outrank 12g you have actually handed over.
	--
	-- The gate is what stops inventory being mistaken for a loss: an item bought
	-- and not yet sold shows a negative margin because it is sitting in your
	-- bags.  Requiring that you have sold at least as many as you bought removes
	-- that reading entirely, at the cost of staying quiet about a genuine loss
	-- you are still half-holding -- which is the right way round for a warning.
	local worst;
	if (ledger) then
		for i = 1, #ledger do
			local r = ledger[i];
			if (r.margin and r.margin < 0 and (r.boughtQty or 0) > 0 and (r.soldQty or 0) >= r.boughtQty
				and not Adv_Suppressed (r.name)) then
				if (worst == nil or r.margin < worst.margin) then worst = r; end
			end
		end
	end

	if (worst) then
		return card (-worst.margin,
					 DZT("You are losing money on this"),
					 string.format (DZT("%s: %s spent, %s back over %d bought and %d sold. That is %s down, and none of it is stock still sitting in your bags."),
									worst.name, Adv_Money (worst.paid), Adv_Money (worst.got),
									worst.boughtQty, worst.soldQty, Adv_Money (-worst.margin)),
					 worst.name, "trades");
	end

	-- One seller holding the book.  What is at stake is the value of the depth
	-- they are holding at the price they are holding it at -- which is the money
	-- you would be handing them.
	local held;
	for i = 1, #stats do
		local st = stats[i];
		if (st.scans >= ADV_MIN_SCANS and st.listings >= ADV_MIN_LISTINGS
			and st.topShare >= ADV_TOP_SHARE and st.low and not Adv_Suppressed (st.name)) then
			local gold = (st.units or st.listings) * st.low;
			if (held == nil or gold > held.gold) then held = { st = st, gold = gold }; end
		end
	end

	if (held == nil) then return nil; end

	return card (held.gold,
				 DZT("One seller owns this market"),
				 string.format (DZT("%s: one seller holds %s of the listings and can move the price at will. There are %d sellers in all."),
								held.st.name, Adv_Pct (held.st.topShare), held.st.sellers),
				 held.st.name, "market");
end

-- FARM.  The best gold-per-day rates on the watchlist -- the one card that
-- points away from the auction house, and the one the owner most wanted a choice
-- on: the best rate on the page can be a material you only get by standing in a
-- zone where losing your gear is on the table.  That is not a judgement the
-- addon can make for you, so it offers several and lets you say.
local function Adv_FarmCard (stats)

	local cand = {};
	local i;
	for i = 1, #stats do
		local st = stats[i];
		if (st.scans >= ADV_MIN_SCANS and st.farmAvg and st.farmAvg > 0
			and not Adv_Suppressed (st.name)) then
			table.insert (cand, st);
		end
	end

	if (#cand == 0) then return nil; end

	table.sort (cand, function (a, b)
		if (a.farmAvg ~= b.farmAvg) then return a.farmAvg > b.farmAvg; end
		return a.name < b.name;
	end);

	local items = {};
	for i = 1, math.min (ADV_CARD_ITEMS, #cand) do
		local st = cand[i];
		table.insert (items, {
			name	= st.name,
			id		= st.id,
			gold	= st.farmAvg,
			note	= string.format (DZT("about %s a day, over %s of scanning"),
									 Adv_Money (st.farmAvg), Adv_Days (st.secs)),
			view	= "market",
			ctl		= { farm = true, ignore = true, skip = true },
		});
	end

	return { kind = "farm", band = ADV_BAND_MONEY, gold = items[1].gold,
			 head = DZT("Worth farming"),
			 text = DZT("What your watchlist has been returning per day at current prices. A rate, not a promise: it assumes you supply the sales."),
			 items = items };
end

-- NOTHING.  The state this tab has to be willing to be in, and on a fresh
-- install the most useful thing it can say.  It names what is missing, in the
-- order that fixing it would unlock the most.
local function Adv_NothingCard (watched, rank, ledger)

	local want = {};

	if ((rank and #rank or 0) == 0) then
		table.insert (want, DZT("open a profession window, which harvests your recipes"));
	end
	if (watched == 0) then
		table.insert (want, DZT("right-click an item anywhere in this addon to watch it"));
	end
	table.insert (want, DZT("scan the auction house twice, a few hours apart"));
	if ((ledger and #ledger or 0) == 0) then
		table.insert (want, DZT("buy or sell something, which fills the Ledger"));
	end

	-- One per line rather than run together into a sentence: several of these
	-- contain commas of their own, and a comma-spliced list of comma'd clauses
	-- is unreadable exactly where legibility is the entire point of the card.
	return { kind = "none", band = ADV_BAND_SETUP,
			 head = DZT("Not enough data yet"),
			 text = DZT("Nothing here clears the bar for advice, which is the honest answer rather than a shortage of opinions. What would give me some:")
					.."\n   - "..table.concat (want, "\n   - "),
			 act = {} };
end

-- THE CARDS ------------------------------------------------------------------
--
-- Global and free of any WoW API it does not guard, so what fires and what it
-- says can be read -- and checked -- without a client.  Returns the card list.
function Atr_Advisor_Cards ()

	local rank = (type (Atr_Craft_ProfitRanking) == "function") and (Atr_Craft_ProfitRanking ()) or {};

	local plan = (type (Atr_An_PlanMap) == "function") and Atr_An_PlanMap () or nil;

	local press, pstats;
	if (type (Atr_Craft_ReagentPressure) == "function") then
		press, pstats = Atr_Craft_ReagentPressure (rank, plan);
	end

	local ledger;
	if (type (Atr_Ledger_ItemTotals) == "function") then
		ledger = (Atr_Ledger_ItemTotals ());
	end

	local stats, watched = Adv_WatchedStats ();

	local byName = {};
	local i;
	for i = 1, #stats do byName[stats[i].name] = stats[i]; end

	local cards = {};

	local function add (c) if (c) then table.insert (cards, c); end end

	add (Adv_StaleCard   (stats, watched));
	add (Adv_MakeCard    (rank, byName));
	add (Adv_BuyCard     (press, pstats, byName));
	add (Adv_WatchCard   (press, watched));
	add (Adv_CarefulCard (stats, ledger));
	add (Adv_FarmCard    (stats));

	if (#cards == 0) then
		table.insert (cards, Adv_NothingCard (watched, rank, ledger));
	end

	-- Band first, then gold at stake.  Stable on ties by head text, so a
	-- redisplay over unchanged data does not reshuffle the page under the cursor
	-- -- pairs() over the watchlist is unordered, and two cards worth the same
	-- would otherwise swap places every repaint.
	table.sort (cards, function (a, b)
		if (a.band ~= b.band) then return a.band < b.band; end
		local ag, bg = a.gold or 0, b.gold or 0;
		if (ag ~= bg) then return ag > bg; end
		return a.head < b.head;
	end);

	while (#cards > ADV_MAX_CARDS) do table.remove (cards); end

	return cards;
end

-- THE PAGE -------------------------------------------------------------------

local ADV_CARD_GAP	= 8;
local ADV_PAD		= 10;
local ADV_ACT_W		= 84;
local ADV_ACT_H		= 20;
local ADV_ACT_LANE	= (ADV_ACT_W + 8) * 2;		-- the two buttons' lane, kept off the text

local ADV_ICON		= 20;						-- the item icon, and the row's height driver
local ADV_ROW_H		= ADV_ICON + 6;
local ADV_CTL_H		= 20;

-- One accent colour per kind, which is the only thing distinguishing a card at a
-- glance.  Deliberately not a backdrop per kind: these panels are stock auction
-- house chrome (CLAUDE.md) and six coloured boxes would read as a different addon.
local ADV_COLOR = {
	stale	= { 1.00, 0.82, 0.00 },
	make	= { 0.20, 1.00, 0.30 },
	buy		= { 0.40, 0.70, 1.00 },
	watch	= { 0.75, 0.60, 1.00 },
	careful	= { 1.00, 0.30, 0.30 },
	farm	= { 1.00, 0.70, 0.25 },
	none	= { 0.60, 0.60, 0.60 },
};

local gAdv_Cards = {};

-- THE ITEM ROW'S CONTROLS, in the order they are laid out from the left.  A
-- table rather than four hand-anchored widgets because every row carries every
-- control and shows the ones its card asked for -- the same trick the Analysis
-- rows play with their four views' cells, and for the same reason: anchoring is
-- the expensive part, so it is done once at build.
--
-- WHY TWO OF THESE ARE BUTTONS AND TWO ARE CHECKBOXES, since the request called
-- them all checkboxes.  A checkbox shows a STATE you can see and reverse in
-- place; a button performs an ACTION.  "Farm list" and "Slow mover" are states
-- -- the row stays, ticked, and you can untick it -- so they are checkboxes.
-- "Ignore" and "Skip" both REMOVE the row, so there would be no ticked box left
-- to look at: they are buttons.  Skip's own description settled it -- "just
-- moves past to next recommendation" is an action, and the next candidate slides
-- into the row you clicked.
local ADV_CTLS = {
	{ key = "farm",  kind = "check",  label = "Farm list",
	  tip = "Put this on your farm list. The list is saved account-wide and the minimap button opens it, so it is readable out in the field where you need it." },
	{ key = "plan",  kind = "check",  label = "Plan",
	  tip = "Tick this recipe into the crafting plan at your current batch size. Same tick as the one on the Crafting view -- it is the same plan." },
	{ key = "slow",  kind = "check",  label = "Slow mover",
	  tip = "Flag this as something that sells slowly. It keeps its place on profit but sinks below anything not flagged, and the row says so. Saved." },
	{ key = "watch", kind = "button", label = "Watch",
	  tip = "Put this on your watchlist, in a group called Advisor, so the Market view starts tracking its price and depth." },
	{ key = "ignore",kind = "button", label = "Ignore",
	  tip = "Stop suggesting this, on every card, for good. Undo it from the Ignored button at the top of this tab." },
	{ key = "skip",  kind = "button", label = "Skip",
	  tip = "Move past this one and show the next recommendation instead. Forgotten at logout -- this is a decision about today, not about the item." },
};

-- GLOBAL, because the farm window (AuctionatorFarmList.lua, item 34) renders the
-- same items away from the auction house and needs the same cascade.  One copy:
-- an icon lookup that disagreed with itself between two windows showing the same
-- list would be the same class of bug as two pricing cascades.
function Atr_Advisor_IconFor (name, id)

	if (id == nil and name and type (Atr_An_IdForName) == "function") then
		id = Atr_An_IdForName (name);
	end

	if (id and type (GetItemIcon) == "function") then
		local tex = GetItemIcon (id);
		if (tex) then return tex, id; end
	end

	if (type (GetItemInfo) == "function") then
		local key = id or name;
		if (key) then
			local tex = select (10, GetItemInfo (key));
			if (tex) then return tex, id; end
		end
	end

	-- The client has never seen this item.  A blank square reads as a broken
	-- icon, so use the question mark the client itself uses for exactly this.
	return "Interface\\Icons\\INV_Misc_QuestionMark", id;
end

-- What a card's own buttons do (the Stale card's Rescan, and the two jumps).
-- Kept out of the rules so those stay readable as rules; every one of these is a
-- call into somebody else's public surface, which is the same discipline as the
-- figures.
local function Adv_DoAction (act)

	if (act == nil) then return; end

	if (act.fn == "rescan") then
		if (type (Atr_SelectPane) ~= "function" or ATR_ANALYSIS_TAB == nil) then return; end
		Atr_SelectPane (ATR_ANALYSIS_TAB);
		if (Atr_An_SetView) then Atr_An_SetView ("market"); end
		-- the rescan sweeps WHAT IS ON SCREEN, so a filter left over from a
		-- previous card would quietly rescan one item and call it a rescan
		local box = _G["Atr_An_FilterBox"];
		if (box and box.SetText) then box:SetText (""); end
		if (Atr_An_RefreshToggle) then Atr_An_RefreshToggle (); end
		return;
	end

	if (act.fn == "show") then
		Adv_ShowInAnalysis (act.view or "market", act.arg);
		return;
	end
end

-- WHAT A ROW'S CONTROL DOES.  Every one of these ends in a redisplay, because
-- every one of them changes which candidates the cards would offer -- ignoring
-- the top farm target has to slide the next one into its place, or the control
-- has not visibly done anything.
-- Forward declaration: Adv_DoControl below ticks the plan, and the reader that
-- says whether it is already ticked reads through Atr_An_PlanMap rather than the
-- saved table -- so this box and the one on the Crafting view can never disagree
-- about what is planned.  Declared here, defined under Adv_DoControl, kept local
-- because nothing outside this file has any business asking.
local Adv_PlanHas;

local function Adv_DoControl (row, key)

	local name = row and row.itemName;
	if (name == nil) then return; end

	if (key == "farm") then
		Atr_Advisor_SetFarmed (name, not Atr_Advisor_IsFarmed (name), row.itemId, row.itemGold);

	elseif (key == "slow") then
		Atr_Advisor_SetSlow (name, not Atr_Advisor_IsSlow (name));

	elseif (key == "plan") then
		if (type (Atr_An_PlanTick) == "function") then
			Atr_An_PlanTick (name, not Adv_PlanHas (name));
		end

	elseif (key == "watch") then
		-- THE GROUP IS CREATED ON FIRST USE, and it is what makes this button
		-- worth having over right-clicking the row on the Market view: everything
		-- the Advisor put on your watchlist lands together, so you can tell at a
		-- glance what you added and what the tab suggested.
		if (type (Atr_An_AddGroup) == "function") then Atr_An_AddGroup (ADV_WATCH_GROUP); end
		if (type (Atr_An_Watch) == "function") then Atr_An_Watch (name, ADV_WATCH_GROUP); end
		Adv_MarkJustWatched (name);

	elseif (key == "ignore") then
		Atr_Advisor_SetIgnored (name, true);

	elseif (key == "skip") then
		gAdv_Skip[name] = true;
	end

	Atr_Advisor_Redisplay ();
end

function Adv_PlanHas (name)
	local plan = (type (Atr_An_PlanMap) == "function") and Atr_An_PlanMap () or nil;
	return (plan ~= nil) and (plan[name] ~= nil);
end

local function Adv_BuildRow (card, i, w)

	local row = CreateFrame ("Button", card:GetName().."Row"..i, card);
	row:SetSize (w, ADV_ROW_H + ADV_CTL_H);
	row:Hide();

	-- The icon is the item, and it behaves the way every other item in this addon
	-- does: hover for the real tooltip, click to go and look at it.  That is one
	-- button instead of a "Show me" per row, and it is the convention already
	-- established on the Analysis rows.
	local icon = row:CreateTexture (nil, "ARTWORK");
	icon:SetSize (ADV_ICON, ADV_ICON);
	icon:SetPoint ("TOPLEFT", 0, 0);
	row.icon = icon;

	local nm = row:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	nm:SetPoint ("TOPLEFT", icon, "TOPRIGHT", 6, -2);
	nm:SetJustifyH ("LEFT");
	row.nm = nm;

	local note = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	note:SetPoint ("LEFT", nm, "RIGHT", 6, 0);
	note:SetPoint ("RIGHT", row, "RIGHT", -4, 0);
	note:SetJustifyH ("LEFT");
	note:SetHeight (ADV_ICON);
	note:SetTextColor (0.7, 0.7, 0.7);
	row.note = note;

	row:SetScript ("OnEnter", function (self)
		if (self.link and GameTooltip) then
			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
			GameTooltip:SetHyperlink (self.link);
			GameTooltip:Show();
		end
	end);
	row:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);
	row:SetScript ("OnClick", function (self)
		Adv_ShowInAnalysis (self.itemView or "market", self.itemName);
	end);

	-- Every row carries every control and shows the ones its card asked for.
	row.ctl = {};
	local c;
	for c = 1, #ADV_CTLS do

		local spec = ADV_CTLS[c];
		local f;

		if (spec.kind == "check") then
			f = CreateFrame ("CheckButton", nil, row, "UICheckButtonTemplate");
			f:SetSize (18, 18);
			local lbl = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			lbl:SetPoint ("LEFT", f, "RIGHT", 0, 0);
			f.lbl = lbl;
			f:SetScript ("OnClick", function (self)
				-- The tick is set from the store on every redisplay, so the visual
				-- state is whatever the store says and never what the click left
				-- behind.  Without this a failed write would still look applied.
				Adv_DoControl (row, spec.key);
			end);
		else
			f = CreateFrame ("Button", nil, row, "UIPanelButtonTemplate");
			f:SetHeight (ADV_CTL_H);
			f:SetScript ("OnClick", function (self) Adv_DoControl (row, spec.key); end);
		end

		f:SetScript ("OnEnter", function (self)
			if (GameTooltip == nil) then return; end
			GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
			GameTooltip:SetText (DZT(spec.label), 1, 1, 1);
			GameTooltip:AddLine (DZT(spec.tip), 0.8, 0.8, 0.8, true);
			GameTooltip:Show();
		end);
		f:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

		f:Hide();
		row.ctl[spec.key] = f;
	end

	return row;
end

local function Adv_BuildCard (parent, i, w)

	local f = CreateFrame ("Frame", "Atr_Advisor_Card"..i, parent);
	f:SetWidth (w);
	f:SetHeight (62);		-- replaced on every redisplay; a frame that has never had
							-- a height is the one state the measure below cannot fix
	f:Hide();

	local bg = f:CreateTexture (nil, "BACKGROUND");
	bg:SetTexture (1, 1, 1, 0.05);
	bg:SetAllPoints (f);

	local stripe = f:CreateTexture (nil, "ARTWORK");
	stripe:SetPoint ("TOPLEFT", 0, 0);
	stripe:SetPoint ("BOTTOMLEFT", 0, 0);
	stripe:SetWidth (3);
	f.stripe = stripe;

	local head = f:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	head:SetPoint ("TOPLEFT", ADV_PAD, -ADV_PAD);
	head:SetJustifyH ("LEFT");
	f.head = head;

	-- The gold at stake, right-aligned above the buttons: it is what the page is
	-- sorted by, so it belongs where the eye runs down the order rather than
	-- buried mid-sentence.
	local gold = f:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	gold:SetPoint ("TOPRIGHT", -ADV_PAD, -ADV_PAD);
	gold:SetJustifyH ("RIGHT");
	f.gold = gold;

	local body = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	body:SetPoint ("TOPLEFT", head, "BOTTOMLEFT", 0, -5);
	body:SetWidth (w - ADV_PAD * 2 - ADV_ACT_LANE);
	body:SetJustifyH ("LEFT");
	body:SetJustifyV ("TOP");
	f.body = body;

	f.act = {};
	local b;
	for b = 1, 2 do
		local btn = CreateFrame ("Button", "Atr_Advisor_Card"..i.."Act"..b, f, "UIPanelButtonTemplate");
		btn:SetSize (ADV_ACT_W, ADV_ACT_H);
		if (b == 1) then
			btn:SetPoint ("TOPRIGHT", -ADV_PAD, -ADV_PAD - 16);
		else
			btn:SetPoint ("RIGHT", f.act[1], "LEFT", -6, 0);
		end
		btn:SetScript ("OnClick", function (self) Adv_DoAction (self.act); end);
		btn:Hide();
		f.act[b] = btn;
	end

	f.rows = {};
	local r;
	for r = 1, ADV_CARD_ITEMS do
		f.rows[r] = Adv_BuildRow (f, r, w - ADV_PAD * 2);
	end

	return f;
end

-- Lay one item row out: the icon, the name, the figure, and whichever controls
-- its card asked for, packed left to right under the name.
local function Adv_DrawRow (row, item)

	row.itemName = item.name;
	row.itemView = item.view;

	local tex, id = Atr_Advisor_IconFor (item.name, item.id);
	row.itemId = id;
	row.itemGold = item.gold;		-- the rate the farm list keeps, if this row is ticked onto it
	row.icon:SetTexture (tex);

	row.link = nil;
	if (id and type (GetItemInfo) == "function") then
		row.link = select (2, GetItemInfo (id));
	end

	row.nm:SetText (item.name or "?");
	row.note:SetText (item.note or "");

	-- Controls pack from the left under the icon, each one taking only the width
	-- its own label needs.  Measured rather than fixed: "Slow mover" and "Plan 5"
	-- are not the same width, and a fixed lane would either clip one or leave a
	-- gap after the other.
	local x = ADV_ICON + 6;
	local c;
	for c = 1, #ADV_CTLS do

		local spec = ADV_CTLS[c];
		local f    = row.ctl[spec.key];
		local want = item.ctl and item.ctl[spec.key];

		if (not want) then
			f:Hide();
		else
			f:ClearAllPoints();
			f:SetPoint ("TOPLEFT", x, -ADV_ROW_H + 2);

			if (spec.kind == "check") then

				local label = DZT(spec.label);
				if (spec.key == "plan" and item.planLabel) then label = item.planLabel; end
				f.lbl:SetText (label);

				local on = false;
				if (spec.key == "farm") then on = Atr_Advisor_IsFarmed (item.name);
				elseif (spec.key == "slow") then on = Atr_Advisor_IsSlow (item.name);
				elseif (spec.key == "plan") then on = Adv_PlanHas (item.name); end
				f:SetChecked (on);

				x = x + 18 + (f.lbl:GetStringWidth() or 40) + 14;
			else

				local label = DZT(spec.label);
				local wide  = false;

				-- "ADDED!", AND WHY IT IS NOT JUST A NICETY.  Watching is silent --
				-- the item goes onto a list on another tab -- so without feedback
				-- the only evidence a click did anything is that nothing visibly
				-- happened, which is exactly what a click that failed looks like.
				-- The button says so and goes dead, so there is nothing to spam.
				if (spec.key == "watch") then
					local watched = (type (Atr_An_IsWatched) == "function")
									and Atr_An_IsWatched (item.name);
					if (watched) then
						label = DZT("Added!");
						f:Disable();
						wide = true;
					else
						f:Enable();
					end
				end

				f:SetText (label);
				local tw = (f:GetTextWidth() or 40) + 18;
				if (wide and tw < 60) then tw = 60; end		-- keep the row from twitching
				f:SetWidth (tw);

				x = x + tw + 6;
			end

			f:Show();
		end
	end

	row:Show();
end

function Atr_Advisor_Redisplay ()

	if (not Atr_Advisor_Panel or not Atr_Advisor_Panel:IsShown()) then return; end

	local cards = Atr_Advisor_Cards ();

	local y, total = 0, 0;
	local i;
	for i = 1, ADV_MAX_CARDS do

		local f = gAdv_Cards[i];
		local c = cards[i];

		if (f) then
			if (c == nil) then
				f:Hide();
			else
				local col = ADV_COLOR[c.kind] or ADV_COLOR.none;
				f.stripe:SetTexture (col[1], col[2], col[3], 1);
				f.head:SetText (c.head);
				f.head:SetTextColor (col[1], col[2], col[3]);
				f.body:SetText (c.text);

				if (c.gold and c.gold > 0) then
					f.gold:SetText (Adv_Money (c.gold));
				else
					f.gold:SetText ("");
				end

				-- Buttons right to left: act[1] is the rightmost, so the first
				-- action in the card's list has to land in the LAST slot or a
				-- one-button card would sit in the middle of the row.
				local n = #(c.act or {});
				local b;
				for b = 1, 2 do
					local btn = f.act[b];
					local a = c.act and c.act[n - b + 1] or nil;
					if (a) then
						btn.act = a;
						btn:SetText (a.label);
						btn:Show();
					else
						btn.act = nil;
						btn:Hide();
					end
				end

				f:ClearAllPoints();
				f:SetPoint ("TOPLEFT", ADV_PAD * 2, y);
				f:Show();

				-- Height follows the wrapped text, so a two-line card is not
				-- padded out to the height a four-line one would need.  MEASURED
				-- AFTER Show, deliberately: GetStringHeight on a FontString whose
				-- frame has never been shown can come back 0 on this client, and
				-- a card of height 20 with its text spilling over the one below
				-- it is the symptom nobody would trace back to here.  The button
				-- row sets the floor.
				local th = f.body:GetStringHeight();
				if (th == nil or th < 12) then th = 12; end

				local hh = f.head:GetStringHeight();
				if (hh == nil or hh < 12) then hh = 14; end

				local h = math.floor (ADV_PAD * 2 + hh + 5 + th);
				if (n > 0 and h < 62) then h = 62; end

				-- ...and then the item rows, which are the rest of the card.
				local ry = -(h - ADV_PAD) - 2;
				local r;
				for r = 1, ADV_CARD_ITEMS do

					local row  = f.rows[r];
					local item = c.items and c.items[r] or nil;

					if (item == nil) then
						row:Hide();
					else
						row:ClearAllPoints();
						row:SetPoint ("TOPLEFT", ADV_PAD, ry);
						Adv_DrawRow (row, item);
						ry = ry - (ADV_ROW_H + ADV_CTL_H) - 4;
						h = h + (ADV_ROW_H + ADV_CTL_H) + 4;
					end
				end

				if (c.items and #c.items > 0) then h = h + 6; end

				f:SetHeight (h);

				y = y - h - ADV_CARD_GAP;
				total = total + h + ADV_CARD_GAP;
			end
		end
	end

	-- The scroll child has to be told how tall its contents are or the bar has
	-- nothing to scroll against.  A minimum of the viewport height keeps the bar
	-- inert rather than jumpy when everything already fits.
	local child = Atr_Advisor_ScrollChild;
	if (child) then
		local vis = Atr_Advisor_Scroll and Atr_Advisor_Scroll:GetHeight() or 300;
		child:SetHeight (math.max (total + 4, vis));
	end

	local ign = _G["Atr_Advisor_IgnoredButton"];
	if (ign) then
		local n = #Atr_Advisor_IgnoreList ();
		ign:SetText (string.format (DZT("Ignored (%d)"), n));
		if (n > 0) then ign:Enable(); else ign:Disable(); end
	end
end

-- THE IGNORED LIST ----------------------------------------------------------
--
-- "Stop suggesting this, for good" is only safe to offer if it is also easy to
-- take back -- otherwise one misclick permanently removes an item from a tab
-- whose whole job is to suggest things, and nothing on screen would ever say so.
-- This is that undo, and the button that opens it carries the count so the list
-- is visible even when you have forgotten it exists.
--
-- FULLSCREEN_DIALOG, and NOT toplevel: the same choice, for the same reasons, as
-- the Analysis tab's item menu and debug box.  It is deliberately opened, it has
-- to clear the auction house window, that strata is near-empty -- and a toplevel
-- frame re-raises on every click, which is the drag freeze (DRAG-FREEZE.md).
local ADV_IGN_ROWS = 12;

function Atr_Advisor_ShowIgnored ()

	if (type (CreateFrame) ~= "function") then return; end

	local f = _G["Atr_Advisor_IgnoreBox"];

	if (f == nil) then

		f = CreateFrame ("Frame", "Atr_Advisor_IgnoreBox", UIParent);
		f:SetFrameStrata ("FULLSCREEN_DIALOG");
		f:SetSize (320, 60 + ADV_IGN_ROWS * 20);
		f:SetPoint ("CENTER");
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

		local title = f:CreateFontString (nil, "OVERLAY", "GameFontNormal");
		title:SetPoint ("TOP", 0, -10);
		title:SetText (DZT("Ignored by the Advisor"));

		local note = f:CreateFontString (nil, "OVERLAY", "GameFontHighlightSmall");
		note:SetPoint ("TOP", title, "BOTTOM", 0, -3);
		note:SetText (DZT("Click one to start suggesting it again."));

		local close = CreateFrame ("Button", nil, f, "UIPanelCloseButton");
		close:SetPoint ("TOPRIGHT", -2, -2);

		f.rows = {};
		local i;
		for i = 1, ADV_IGN_ROWS do
			local b = CreateFrame ("Button", nil, f, "UIPanelButtonTemplate");
			b:SetSize (290, 18);
			b:SetPoint ("TOPLEFT", 14, -48 - (i - 1) * 20);
			b:Hide();
			b:SetScript ("OnClick", function (self)
				if (self.itemName) then
					Atr_Advisor_SetIgnored (self.itemName, false);
					Atr_Advisor_ShowIgnored ();		-- repaint the list under the cursor
					Atr_Advisor_Redisplay ();
				end
			end);
			f.rows[i] = b;
		end

		f.more = f:CreateFontString (nil, "OVERLAY", "GameFontDisableSmall");
		f.more:SetPoint ("BOTTOM", 0, 10);
	end

	local list = Atr_Advisor_IgnoreList ();

	local i;
	for i = 1, ADV_IGN_ROWS do
		local b = f.rows[i];
		local e = list[i];
		if (e == nil) then
			b.itemName = nil;
			b:Hide();
		else
			b.itemName = e.name;
			b:SetText (e.name);
			b:Show();
		end
	end

	if (#list == 0) then
		f.more:SetText (DZT("Nothing is ignored."));
	elseif (#list > ADV_IGN_ROWS) then
		f.more:SetText (string.format (DZT("...and %d more. Un-ignore some to see the rest."),
									   #list - ADV_IGN_ROWS));
	else
		f.more:SetText ("");
	end

	f:Show();
end

function Atr_Advisor_OnTabClick (index)

	if (Atr_Advisor_Panel == nil) then return; end

	if (ATR_ADVISOR_TAB and Atr_FindTabIndex and index == Atr_FindTabIndex (ATR_ADVISOR_TAB)) then
		Atr_Advisor_Panel:Show();
		-- fresh visit, fresh suggestions: the rows held open to say "Added!" have
		-- served their purpose and the next candidates take their places
		Adv_ClearJustWatched ();
		Atr_Advisor_Redisplay ();
	else
		Atr_Advisor_Panel:Hide();
		local box = _G["Atr_Advisor_IgnoreBox"];
		if (box) then box:Hide(); end		-- it hangs off UIParent, not the panel
	end
end

function Atr_Advisor_Init ()

	if (Atr_Advisor_Panel or type (CreateFrame) ~= "function") then return; end

	-- Measured off the auction house window the same way the Analysis panel is,
	-- and for the same reason: Ascension's window is wider than Blizzard's 768,
	-- so a hardcoded width leaves a band of empty backdrop at the right edge.
	local frameW = 768;
	if (AuctionFrame and AuctionFrame.GetWidth) then frameW = AuctionFrame:GetWidth() or 768; end
	if (frameW < 600) then frameW = 768; end

	local panelW = math.floor (frameW) - 22;

	local panel = CreateFrame ("Frame", "Atr_Advisor_Panel", AuctionFrame);
	panel:SetSize (panelW, 447);
	panel:SetPoint ("TOPLEFT", 10, 0);
	panel:Hide();

	local bg = panel:CreateTexture (nil, "BACKGROUND");
	bg:SetTexture (0, 0, 0, 0.85);
	bg:SetPoint ("TOPLEFT", 14, -70);
	bg:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -12, 28);

	local title = panel:CreateFontString (nil, "BACKGROUND", "GameFontNormal");
	title:SetPoint ("TOP", 0, -18);
	title:SetText ("Auctionator - "..DZT("Advisor"));

	-- Said ONCE, here, rather than hedged per card: the ordering is a ranking of
	-- estimates and every card would otherwise have to apologise for it.
	local note = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	note:SetPoint ("TOP", title, "BOTTOM", 0, -4);
	note:SetText (DZT("Ranked by gold at stake, which is an estimate. Every figure is read off the Analysis tab."));

	local ign = CreateFrame ("Button", "Atr_Advisor_IgnoredButton", panel, "UIPanelButtonTemplate");
	ign:SetSize (110, 20);
	ign:SetPoint ("TOPRIGHT", -20, -46);
	ign:SetText (DZT("Ignored (0)"));
	ign:SetScript ("OnClick", function () Atr_Advisor_ShowIgnored (); end);
	ign:SetScript ("OnEnter", function (self)
		if (GameTooltip == nil) then return; end
		GameTooltip:SetOwner (self, "ANCHOR_LEFT");
		GameTooltip:SetText (DZT("Ignored items"), 1, 1, 1);
		GameTooltip:AddLine (DZT("Everything you have told this tab to stop suggesting. Open it to put something back."), 0.8, 0.8, 0.8, true);
		GameTooltip:Show();
	end);
	ign:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

	-- THE TAB SAYS SO ITSELF.  Every card here is built out of scan estimates --
	-- craft costs, margins, sale rates, all of which the Analysis tab already
	-- calls approximations -- and ranking them compounds the error rather than
	-- cancelling it.  The note under the title admits that about the ordering;
	-- this says the louder half, that the tab is new and its cards are a place
	-- to start looking, not a decision.  Said once, in the chrome, so no card
	-- has to hedge in its own body text.
	--
	-- It rides the Ignored button's row rather than sitting above the scroll
	-- frame because that row is empty to the left of the button: a banner in
	-- the gap costs the cards no height, and the cards were already the thing
	-- that outgrew this panel (see the scroll frame below).
	local banner = CreateFrame ("Frame", "Atr_Advisor_Banner", panel);
	banner:SetHeight (20);
	banner:SetPoint ("TOPLEFT", 20, -46);
	banner:SetPoint ("TOPRIGHT", ign, "TOPLEFT", -8, 0);
	banner:EnableMouse (true);

	local bnbg = banner:CreateTexture (nil, "BACKGROUND");
	bnbg:SetTexture (0.55, 0.33, 0.04, 0.55);
	bnbg:SetAllPoints (banner);

	local bntxt = banner:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	bntxt:SetPoint ("LEFT", 8, 0);
	bntxt:SetPoint ("RIGHT", -8, 0);
	bntxt:SetJustifyH ("CENTER");
	bntxt:SetTextColor (1, 0.85, 0.4);
	bntxt:SetText (DZT("Experimental - advice, not instructions. Use at your own discretion."));

	banner:SetScript ("OnEnter", function (self)
		if (GameTooltip == nil) then return; end
		GameTooltip:SetOwner (self, "ANCHOR_BOTTOM");
		GameTooltip:SetText (DZT("Experimental"), 1, 0.85, 0.4);
		GameTooltip:AddLine (DZT("This tab reads the Analysis tab and guesses at what is worth your time. Every figure behind a card is an estimate, and a card can be confidently wrong when the scan data behind it is thin or stale. Check the numbers before you spend on them."), 0.8, 0.8, 0.8, true);
		GameTooltip:Show();
	end);
	banner:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

	-- THE CARDS SCROLL, and they have to.  Six cards with three item rows each is
	-- roughly twice the height this panel has -- the tab was a fixed page of six
	-- short cards before the rows went in, and it stopped being one the moment a
	-- card could carry three icons and twelve controls.  A real ScrollFrame is
	-- the cheap answer: the cards are anchored into a child frame whose height
	-- the redisplay sets, and the template brings its own bar and wheel handling.
	local scroll = CreateFrame ("ScrollFrame", "Atr_Advisor_Scroll", panel, "UIPanelScrollFrameTemplate");
	scroll:SetPoint ("TOPLEFT", 20, -74);
	scroll:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -42, 34);

	local child = CreateFrame ("Frame", "Atr_Advisor_ScrollChild", scroll);
	child:SetSize (panelW - 70, 400);
	scroll:SetScrollChild (child);

	local cardW = panelW - 70 - ADV_PAD * 2 - 8;

	local i;
	for i = 1, ADV_MAX_CARDS do
		gAdv_Cards[i] = Adv_BuildCard (child, i, cardW);
	end
end
