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
local ADV_WATCH_NAMES	= 3;			-- how many reagents the Watch card names, and how
										-- many its button puts on the list.

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

-- A list of names as English reads it: "a", "a and b", "a, b and c".
local function Adv_Names (t)
	local n = #t;
	if (n == 0) then return ""; end
	if (n == 1) then return t[1]; end
	return table.concat (t, ", ", 1, n - 1)..DZT(" and ")..t[n];
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

-- MAKE.  The best thing to make, the catch that comes with it, and a button
-- that puts it in the plan at the batch size you already chose.
local function Adv_MakeCard (rank, byName)

	if (type (rank) ~= "table") then return nil; end

	-- THE FIRST ENTRY THAT CLEARS BOTH GATES, not the first entry.  The ranking
	-- sorts by perCraft, which is an ABSOLUTE figure, so a big-ticket recipe
	-- returning 40g on a 3800g outlay heads the list while earning 1% -- and
	-- stopping at rank[1] would let it veto a card for the 300g-at-69% recipe
	-- two rows below it.  Walking is still reading the ranking's own order; it
	-- is not a re-sort.  It stops early because a recipe far enough down the
	-- perCraft order is not the answer to "what should I make" whatever its
	-- margin.
	local best, margin;
	local n;
	for n = 1, math.min (#rank, 20) do
		local e = rank[n];
		if (e.perCraft and e.perCraft >= ADV_MIN_PERCRAFT and e.sell and e.sell > 0) then
			local m = (e.sell - (e.cost or 0)) / e.sell;
			if (m >= ADV_MIN_MARGIN) then best = e; margin = m; break; end
		end
	end

	if (best == nil) then return nil; end

	local text = string.format (DZT("%s -- %s a craft at %s margin, the best in your recipe book."),
								best.name, Adv_Money (best.perCraft), Adv_Pct (margin));

	-- THE CATCH, and it is the half that keeps somebody out of trouble: the same
	-- margin over one reagent ten people sell is a different proposition from
	-- the same margin spread over eight cheap ones.  Computed where the craft
	-- cost is (Atr_Craft_TopReagent), so it cannot be a share of a different total.
	if (type (Atr_Craft_TopReagent) == "function") then
		local top = Atr_Craft_TopReagent (best);
		if (top and top.name and top.share >= ADV_BILL_SHARE) then
			local st = byName[top.name];
			if (st and st.scans >= ADV_MIN_SCANS and st.sellers > 0) then
				text = text..string.format (DZT(" Catch: %s of that cost is %s, and %d sellers hold it."),
											Adv_Pct (top.share), top.name, st.sellers);
			else
				text = text..string.format (DZT(" Catch: %s of that cost is %s, which you have never scanned."),
											Adv_Pct (top.share), top.name);
			end
		end
	end

	if (best.assumed) then
		text = text..DZT("  The yield for this one was assumed rather than read from the profession window.");
	end

	local act = {};
	if (type (Atr_An_PlanTick) == "function" and type (Atr_An_PlanBatch) == "function") then
		table.insert (act, { label = string.format (DZT("Plan %d"), Atr_An_PlanBatch ()),
							 fn = "plan", arg = best.name });
	end
	table.insert (act, { label = DZT("Show me"), fn = "show", arg = best.name, view = "craft" });

	return { kind = "make", band = ADV_BAND_MONEY, gold = best.perCraft,
			 head = DZT("Make this"), text = text, act = act };
end

-- BUY.  One reagent dominating the shopping bill.  The share is a ratio of two
-- figures the Reagents view prints in the same column, which is reading a table
-- rather than re-deriving it.
local function Adv_BuyCard (press, pstats, byName)

	if (press == nil or pstats == nil) then return nil; end
	if ((pstats.outlay or 0) <= 0) then return nil; end

	local top;
	local i;
	for i = 1, #press do
		local e = press[i];
		if (e.outlay and e.outlay > 0 and (top == nil or e.outlay > top.outlay)) then top = e; end
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

	local cand = {};
	local i;
	for i = 1, #press do
		local e = press[i];
		if (e.name and (e.need or 0) > 0 and not e.vendor and not Atr_An_IsWatched (e.name)) then
			table.insert (cand, e);
		end
	end

	if (#cand == 0) then return nil; end

	table.sort (cand, function (a, b)
		local ao, bo = a.outlay or 0, b.outlay or 0;
		if (ao ~= bo) then return ao > bo; end
		return (a.name or "") < (b.name or "");
	end);

	local names = {};
	for i = 1, math.min (ADV_WATCH_NAMES, #cand) do table.insert (names, cand[i].name); end

	local text;
	if (watched == 0) then
		text = string.format (DZT("Your watchlist is empty, so I cannot tell you whether any of this is actually buyable. Your crafting leans hardest on %s."),
							  Adv_Names (names));
	else
		text = string.format (DZT("%d of the reagents your crafting depends on are not watched, so their Supply column is blank. The biggest are %s."),
							  #cand, Adv_Names (names));
	end

	return { kind = "watch", band = ADV_BAND_SETUP, gold = cand[1].outlay,
			 head = DZT("Watch these"), text = text,
			 act = { { label = string.format (DZT("Watch %d"), #names), fn = "watch", arg = names } } };
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
			if (r.margin and r.margin < 0 and (r.boughtQty or 0) > 0 and (r.soldQty or 0) >= r.boughtQty) then
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
			and st.topShare >= ADV_TOP_SHARE and st.low) then
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

-- FARM.  The best gold-per-day on the watchlist, which is the one card that
-- points away from the auction house.
local function Adv_FarmCard (stats)

	local best;
	local i;
	for i = 1, #stats do
		local st = stats[i];
		if (st.scans >= ADV_MIN_SCANS and st.farmAvg and st.farmAvg > 0) then
			if (best == nil or st.farmAvg > best.farmAvg) then best = st; end
		end
	end

	if (best == nil) then return nil; end

	return { kind = "farm", band = ADV_BAND_MONEY, gold = best.farmAvg,
			 head = DZT("Worth farming"),
			 text = string.format (DZT("%s has returned about %s a day at its current price -- the best rate on your watchlist, over %s of scanning. A rate, not a promise: it assumes you supply the sales."),
								   best.name, Adv_Money (best.farmAvg), Adv_Days (best.secs)),
			 act = { { label = DZT("Show me"), fn = "show", arg = best.name, view = "market" } } };
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

	-- One per line rather than run together with Adv_Names: several of these
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

-- What a card's buttons actually do.  Kept out of the rules so those stay
-- readable as rules; every one of these is a call into somebody else's public
-- surface, which is the same discipline as the figures.
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

	if (act.fn == "plan") then
		if (type (Atr_An_PlanTick) == "function") then Atr_An_PlanTick (act.arg, true); end
		Adv_ShowInAnalysis ("craft", act.arg);
		return;
	end

	if (act.fn == "watch") then
		if (type (Atr_An_Watch) ~= "function") then return; end
		local i;
		for i = 1, #(act.arg or {}) do Atr_An_Watch (act.arg[i]); end
		Adv_ShowInAnalysis ("market", nil);
		return;
	end
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
			btn:SetPoint ("BOTTOMRIGHT", -ADV_PAD, ADV_PAD);
		else
			btn:SetPoint ("RIGHT", f.act[1], "LEFT", -6, 0);
		end
		btn:SetScript ("OnClick", function (self) Adv_DoAction (self.act); end);
		btn:Hide();
		f.act[b] = btn;
	end

	return f;
end

function Atr_Advisor_Redisplay ()

	if (not Atr_Advisor_Panel or not Atr_Advisor_Panel:IsShown()) then return; end

	local cards = Atr_Advisor_Cards ();

	local y = 0;
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
				f:SetHeight (h);

				y = y - h - ADV_CARD_GAP;
			end
		end
	end
end

function Atr_Advisor_OnTabClick (index)

	if (Atr_Advisor_Panel == nil) then return; end

	if (ATR_ADVISOR_TAB and Atr_FindTabIndex and index == Atr_FindTabIndex (ATR_ADVISOR_TAB)) then
		Atr_Advisor_Panel:Show();
		Atr_Advisor_Redisplay ();
	else
		Atr_Advisor_Panel:Hide();
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

	local holder = CreateFrame ("Frame", nil, panel);
	holder:SetPoint ("TOPLEFT", 14, -92);
	holder:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -16, 32);

	local cardW = panelW - 14 - 16 - ADV_PAD * 2;

	local i;
	for i = 1, ADV_MAX_CARDS do
		gAdv_Cards[i] = Adv_BuildCard (holder, i, cardW);
	end
end
