-------------------------------------------------------------------------------
-- AuctionatorFinder.lua  (v2)
--
-- "Finder" tab for the auction house: Blizzard-style item search that pages
-- through every result with normal queries (works with getAll disabled),
-- then displays auctions with client-side sortable columns.
--
-- v2 additions:
--   * Grouping: identical NON-equippable items (same exact item link) are
--     consolidated into one row (total qty, xN listings, cheapest price).
--     Weapons/armor stay as individual rows since their stats differ.
--     Toggle via the "Group" checkbox.
--   * iLvl column for equippable items (via GetItemInfo).
--   * Stat column: dropdown lists every stat found on gear in the current
--     results (via GetItemStats); picking one shows a sortable stat column.
--     Columns reflow automatically when the stat column appears/disappears.
--
-- Integration points (see patched Auctionator.lua):
--   * ATR_FINDER_TAB, Atr_Finder_Init(), Atr_Finder_Panel, Atr_Finder_OnTabClick(i)
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
addonTable = addonTable or {};		-- robust if loaded outside the client (test harness)
local zc = addonTable and addonTable.zc;

local function FT (s)
	if (ZT) then return ZT(s); end
	return s;
end

-------------------------------------------------------------------------------
-- constants / state
-------------------------------------------------------------------------------

local FDR_NULL		= 0;
local FDR_PREQUERY	= 1;
local FDR_POSTQUERY	= 2;
local FDR_PAUSED	= 3;	-- waiting on the large-search confirmation

local FDR_NUM_ROWS		= 15;
local FDR_ROW_HEIGHT	= 20;
-- Page limits.  There is deliberately NO fixed page cap any more: a scan runs
-- until the server serves a short page, which is the real end of the result
-- set.  What remains is a RUNAWAY GUARD, because "run until a short page" is
-- not by itself terminating on this server -- the duplicate-page path
-- (CheckForDuplicatePage) advances gFdr_Page after 4 failed retries, so a
-- server that keeps re-serving one full page would otherwise loop forever.
-- The guard is derived from the server's OWN reported total (page 0's
-- GetNumAuctionItems), so it is a fact about the query rather than an
-- arbitrary number, with slack for the pages the dup path skips past.
local FDR_MAX_PAGES		= 0;	-- >0 forces a hard page limit; 0 = no fixed limit
local FDR_PAGE_SLACK	= 25;	-- pages allowed ABOVE the server's reported total
local FDR_RUNAWAY_PAGES	= 2000;	-- absolute stop when the server reports no usable total
local FDR_WARN_PAGES	= 25;	-- prompt before scans larger than this
local FDR_QUERY_TIMEOUT	= 8;

local gFdr_State		= FDR_NULL;
local gFdr_Page			= 0;
local gFdr_Query		= nil;
local gFdr_QuerySentAt	= 0;
local gFdr_Elapsed		= 0;
local gFdr_OnFinish		= nil;		-- FINDER_TAB: full-scan driver callback (see below)
local gFdr_WaitTicks	= 0;		-- FINDER_TAB: OnUpdate ticks since the page last moved
local gFdr_RetryHold	= 0;		-- FINDER_TAB: ticks to wait before re-querying a stale page
local gFdr_Results		= {};		-- raw auction records from the scan
local gFdr_Display		= {};		-- what's actually shown (post-grouping)
local gFdr_TotalPages	= 0;

local gFdr_DupRetries	= 0;
local gFdr_SkippedPages	= 0;

local gFdr_SortKey		= "peritem";
local gFdr_SortAsc		= true;

local gFdr_SelectedCats	 = {};		-- ordered list of selected category leaves (filter, OR)
local gFdr_SelectedCatSet = {};		-- leaf key -> true
local gFdr_SpecQueue	 = {};		-- server query specs for the current scan
local gFdr_SpecIdx		 = 1;
local gFdr_CapHit		 = false;

-- The page at which the scan gives up.  Normally unreachable: the scan ends
-- when a page comes back short.  Exposed as a global so the harness and any
-- future diagnostic can read the live ceiling.
function Fdr_PageCeiling ()

	if (FDR_MAX_PAGES > 0) then return FDR_MAX_PAGES; end
	if (gFdr_TotalPages > 0) then return gFdr_TotalPages + FDR_PAGE_SLACK; end
	return FDR_RUNAWAY_PAGES;
end
local gFdr_CatSum		 = nil;		-- cached category-selection summary
local gFdr_JumpPending	 = false;	-- Finder -> Buy tab jump in progress
local gFdr_BackEnabled	 = false;	-- Back-to-Finder button state

-- Buy tab -> Finder redirect (see "gear on the Buy tab comes back here").
-- ONE table rather than four locals: this file sits against Lua 5.1's
-- 200-local file-scope ceiling (see CLAUDE.md), and the wrappers need to keep
-- the originals they replaced somewhere.
--   skip  - lowercased name we already bounced once; a second search of the
--           same item is let through, so the Buy tab is never unreachable
--   told  - the long form of the chat note has been shown this session
--   prev* - the upstream functions this file wrapped, called through
local gFdr_Redir		 = { skip = nil, told = false };
local gFdr_AutoMinLvl	 = nil;		-- min-level value we auto-filled (nil = user-owned)
local gFdr_AutoUsable	 = false;	-- we checked Usable automatically
local gFdr_UsableUserOff = false;	-- user unchecked it after our auto-check; respect that
-- (My Lvl had a gFdr_AutoReq/gFdr_ReqUserOff pair to match; it no longer
--  auto-ticks, so there is nothing to remember overriding.  See
--  Fdr_AutoFillMinLevel.)
local gFdr_LvlMin		 = nil;		-- client-side level range (read live at rebuild)
local gFdr_LvlMax		 = nil;
local gFdr_ReqCap		 = nil;		-- "My Lvl": hide items requiring more than this
local gFdr_HideKnown	 = false;	-- hide recipes this character has already learned

local gFdr_SelectedStats = {};		-- ordered list of selected stat keys (filter, AND)
local gFdr_SelectedSet	 = {};		-- same keys as a set for quick lookup
local gFdr_StatKeys		 = {};		-- stats discovered in current results
local gFdr_StatSeenKeys	 = {};		-- every stat key in the current results, pre-filter
local FDR_MAX_STAT_COLS	 = 3;		-- columns shown for the first N selected stats
local FDR_DPS_KEY		 = "ITEM_MOD_DAMAGE_PER_SECOND_SHORT";
local gFdr_HasDPS		 = false;	-- weapons present -> automatic DPS column
local FDR_STAT_LEARN_CAP = 400;		-- sanity cap on the learned stat set (see Fdr_LearnStatKeys)
local gFdr_LearnCapTold	 = false;	-- cap complaint shown this session

local gFdr_SearchText	= "";
local gFdr_MinLevel		= nil;
local gFdr_MaxLevel		= nil;
local gFdr_UsableOnly	= nil;

local gFdr_Rows			= {};
local gFdr_Headers		= {};
gFdr_ScaledNames		= gFdr_ScaledNames or {};	-- item names with known scaled variants (session)

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------

local function Fdr_IgnoreWarn ()
	return AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.ignoreLargeWarn;
end

-- one setting, mirrored by the dialog checkbox and the toolbar checkbox
function Atr_Finder_SetIgnoreWarn (v)

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
	AUCTIONATOR_FINDER_SETTINGS.ignoreLargeWarn = v and true or false;

	if (Atr_Finder_NoWarnCheck)		then Atr_Finder_NoWarnCheck:SetChecked (v and true or nil); end
	if (Atr_Finder_WarnIgnoreCheck)	then Atr_Finder_WarnIgnoreCheck:SetChecked (v and true or nil); end
end

-- One setting, two checkboxes -- the Finder's own toolbar and the options
-- panel -- mirrored the same way Atr_Finder_SetIgnoreWarn does it. The toolbar
-- one is where you actually reach for it; the options row stays because that is
-- where someone reading the option list will look for it.
function Atr_Finder_SetHideKnownRecipes (v)

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
	AUCTIONATOR_FINDER_SETTINGS.hideKnownRecipes = v and true or false;

	if (Atr_Finder_HideKnownCheck)		then Atr_Finder_HideKnownCheck:SetChecked (v and true or nil); end
	if (Atr_Finder_Opt_KnownRecipes_CB)	then Atr_Finder_Opt_KnownRecipes_CB:SetChecked (v and true or nil); end
end

local function Fdr_MoneyString (copper)

	if (copper == nil or copper <= 0) then
		return "|cff888888--|r";
	end

	local gold	 = math.floor (copper / 10000);
	local silver = math.floor ((copper % 10000) / 100);
	local cop	 = copper % 100;

	if (gold > 0) then
		return string.format ("|cffffffff%d|r|cffffd70bg|r |cffffffff%02d|r|cffc7c7cfs|r", gold, silver);
	elseif (silver > 0) then
		return string.format ("|cffffffff%d|r|cffc7c7cfs|r |cffffffff%02d|r|cffeda55fc|r", silver, cop);
	else
		return string.format ("|cffffffff%d|r|cffeda55fc|r", cop);
	end
end

local gFdr_TimeLeftText = { "|cffff4444S|r", "|cffffff44M|r", "|cff44ff44L|r", "|cff4488ffV|r" };

local function Fdr_SetMessage (msg)
	if (Atr_Finder_Message) then
		Atr_Finder_Message:SetText (msg or "");
	end

	-- FINDER_TAB: during a Full Scan run the dialog covers the Finder tab, so
	-- the engine's live page counter has to be echoed there or the user has no
	-- way to tell a working scan from a hung one.
	if (Fdr_FS_EchoProgress) then Fdr_FS_EchoProgress (msg); end
end

local function Fdr_StatDisplayName (key)

	local s = _G[key];
	if (type(s) == "string" and s ~= "") then
		return s;
	end
	-- fall back to a cleaned-up token: ITEM_MOD_ATTACK_POWER_SHORT -> Attack Power
	s = key:gsub ("^ITEM_MOD_", ""):gsub ("_SHORT$", ""):lower():gsub ("_", " "):gsub ("^%l", string.upper);
	return s;
end

-------------------------------------------------------------------------------
-- learned stat keys
--
-- The stats dropdown used to list only the stats found in the CURRENT results,
-- so on a fresh session it read "(clear all)" and nothing else until a search
-- had run.  That is backwards: the stats are a FILTER (Fdr_PassesStatFilter --
-- a selected stat a row lacks removes the row), so you want to set them BEFORE
-- searching, not after.  The addon therefore remembers every stat key it has
-- ever seen on equippable results and offers the accumulated set from then on.
--
-- Learn, don't seed (owner's decision, 2026-08-19).  There is deliberately no
-- static ITEM_MOD_* list: stock constants may not apply on this server, and
-- Ascension's custom stats are covered by no constant at all, so a seed would
-- have needed discovery as a fallback anyway.  The list is empty on a fresh
-- install and fills in as you search.
--
-- The set lives in AUCTIONATOR_FINDER_SETTINGS (already account-wide in the
-- .toc, so no .toc change).  Account-wide is right: stats are a property of the
-- server's items, not of a character.
-------------------------------------------------------------------------------

local function Fdr_LearnedStats ()

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};

	if (type (AUCTIONATOR_FINDER_SETTINGS.statKeys) ~= "table") then
		AUCTIONATOR_FINDER_SETTINGS.statKeys = {};
	end

	return AUCTIONATOR_FINDER_SETTINGS.statKeys;
end

-- Learn from the RAW discoveries (Fdr_AnalyzeResults's statSeen), NOT from
-- gFdr_StatKeys.  This is the part that is easy to get wrong.  gFdr_StatKeys is
-- what survives the ubiquitousConstant filter, and that filter is a judgement
-- about ONE result set: a search narrow enough that every hit carries the same
-- +10 Stamina drops Stamina, and Stamina is obviously worth remembering.
-- Persisting the filtered list would make what gets learned depend on the shape
-- of your past searches -- a stat could become harder to learn precisely
-- because you once searched for it too precisely.  So ubiquitousConstant stays
-- a DISPLAY rule for the current results only, and never touches this set.
--
-- FDR_DPS_KEY is excluded here for the same reason it is excluded there: DPS
-- has its own dedicated column and is not offered as a stat filter.
local function Fdr_LearnStatKeys (seen)

	local learned = Fdr_LearnedStats ();

	local n = 0;
	for _ in pairs (learned) do n = n + 1; end

	local key;
	for key in pairs (seen) do
		if (type (key) == "string" and key ~= FDR_DPS_KEY and not learned[key]) then

			-- The set is bounded by the number of distinct stat keys that exist
			-- on the server, so this cap should never be reached in normal use.
			-- It is insurance against a malformed key being written in a loop --
			-- and it complains rather than truncating silently, because a
			-- silently capped list would just look like a stat that refuses to
			-- be learned.
			if (n >= FDR_STAT_LEARN_CAP) then
				if (not gFdr_LearnCapTold) then
					gFdr_LearnCapTold = true;
					local s = string.format (FT("Auctionator Finder: the remembered stat list has reached its limit of %d keys, so new stats are no longer being learned.  This should not happen in normal use; run |cffffd200/run Atr_Finder_ForgetStats()|r to clear it."), FDR_STAT_LEARN_CAP);
					if (zc and zc.msg_atr) then zc.msg_atr (s);
					elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
				end
				break;
			end

			learned[key] = true;
			n = n + 1;
		end
	end
end

-- global so it is macro-able: the only way to clear a set that has learned junk
function Atr_Finder_ForgetStats ()

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
	AUCTIONATOR_FINDER_SETTINGS.statKeys = {};
	gFdr_LearnCapTold = false;

	local s = FT("Auctionator Finder: remembered stats cleared; they will be learned again as you search.");
	if (zc and zc.msg_atr) then zc.msg_atr (s);
	elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
end

-- learned keys the given result set does NOT contain, sorted for display
local function Fdr_LearnedOnlyKeys (present)

	local out = {};

	local key;
	for key in pairs (Fdr_LearnedStats ()) do
		if (not present[key]) then
			tinsert (out, key);
		end
	end

	table.sort (out, function (a, b)
		return Fdr_StatDisplayName (a) < Fdr_StatDisplayName (b);
	end);

	return out;
end

local function Fdr_GetStats (rec)

	if (rec.stats == nil) then
		if (GetItemStats and rec.link) then
			local ok, t = pcall (GetItemStats, rec.link);
			rec.stats = (ok and type(t) == "table") and t or {};
		else
			rec.stats = {};
		end
	end

	return rec.stats;
end

local function Fdr_GetStat (rec, key)

	if (not key or not rec.equippable) then
		return 0;
	end

	-- A verified value wins, exactly as rec.trueDPS already beats the
	-- cached DPS.  This feeds the stat COLUMNS and Fdr_SortValue alike, so
	-- sorting by a stat orders rows by the real listings rather than by
	-- whichever scale variant the client cached.
	if (rec.trueStats and rec.trueStats[key]) then
		return rec.trueStats[key];
	end

	return Fdr_GetStats(rec)[key] or 0;
end

-------------------------------------------------------------------------------
-- column layout (reflows when the stat column is shown/hidden)
-------------------------------------------------------------------------------

local function Fdr_NumStatCols ()
	return math.min (#gFdr_SelectedStats, FDR_MAX_STAT_COLS);
end

-- builds { {key, x, width, justify}, ... } for the current stat selection;
-- the name column absorbs whatever width the stat columns don't take
local function Fdr_BuildLayout ()

	local ROW_W		= 690;
	local GAP		= 2;
	local STAT_W	= 46;

	local nstats = Fdr_NumStatCols();

	local tail =
	{
		{ "ilvl",		40,  "RIGHT"  },
		{ "level",		32,  "RIGHT"  },
		{ "qty",		32,  "RIGHT"  },
		{ "timeleft",	38,  "CENTER" },
	};

	if (gFdr_HasDPS) then
		tinsert (tail, { "dps", 46, "RIGHT" });
	end

	local i;
	for i = 1, nstats do
		tinsert (tail, { "stat"..i, STAT_W, "RIGHT" });
	end

	tinsert (tail, { "buyout",	112, "RIGHT" });
	tinsert (tail, { "peritem",	 96, "RIGHT" });

	local fixed = 0;
	for _, c in ipairs (tail) do
		fixed = fixed + c[2] + GAP;
	end

	local layout = {};
	local x = 20;

	local namew = ROW_W - fixed - GAP;
	tinsert (layout, { "name", x, namew, "LEFT" });
	x = x + namew + GAP;

	for _, c in ipairs (tail) do
		tinsert (layout, { c[1], x, c[2], c[3] });
		x = x + c[2] + GAP;
	end

	return layout;
end

local function Fdr_ApplyColumnLayout ()

	local layout = Fdr_BuildLayout();
	local active = {};

	for _, col in ipairs (layout) do

		local key, x, w = col[1], col[2], col[3];
		active[key] = true;

		local hdr = gFdr_Headers[key];
		if (hdr) then
			hdr:SetPoint ("TOPLEFT", x, -74);
			hdr:SetWidth (w);
			if (hdr.label.SetWidth) then hdr.label:SetWidth (w - 4); end
			hdr:Show();
		end

		for i = 1, FDR_NUM_ROWS do
			local cell = gFdr_Rows[i] and gFdr_Rows[i].cells[key];
			if (cell) then
				if (key == "name") then
					cell:SetPoint ("LEFT", 22, 0);		-- right of the icon
					cell:SetWidth (w - 22);
				else
					cell:SetPoint ("LEFT", x - 18, 0);	-- rows start at panel x=20
					cell:SetWidth (w);
				end
			end
		end
	end

	-- hide stat headers/cells beyond the current selection
	for key, hdr in pairs (gFdr_Headers) do
		if (not active[key]) then
			hdr:Hide();
			for i = 1, FDR_NUM_ROWS do
				local cell = gFdr_Rows[i] and gFdr_Rows[i].cells[key];
				if (cell) then cell:SetText (""); end
			end
		end
	end

	-- stat header labels follow the selected stats
	local i;
	for i = 1, Fdr_NumStatCols() do
		local hdr = gFdr_Headers["stat"..i];
		if (hdr) then
			hdr.label:SetText (Fdr_StatDisplayName (gFdr_SelectedStats[i]));
		end
	end
end

-------------------------------------------------------------------------------
-- sorting
-------------------------------------------------------------------------------

local BIGNUM = 999999999999;

local function Fdr_SortValue (rec, key)

	if (key == "name")		then return string.lower (rec.name or ""); end
	if (key == "level")		then return rec.level or 0; end
	if (key == "qty")		then return rec.count or 0; end
	if (key == "timeleft")	then return rec.timeLeft or 0; end
	if (key == "ilvl")		then return rec.trueIlvl or rec.ilvl or 0; end

	if (key == "dps") then
		return rec.trueDPS or Fdr_GetStat (rec, FDR_DPS_KEY);
	end

	local statIdx = key:match ("^stat(%d)$");
	if (statIdx) then
		return Fdr_GetStat (rec, gFdr_SelectedStats[tonumber (statIdx)]);
	end

	if (key == "buyout") then
		if (rec.buyoutPrice and rec.buyoutPrice > 0) then return rec.buyoutPrice; end
		return BIGNUM;
	end

	if (key == "peritem") then
		if (rec.perItem and rec.perItem > 0) then return rec.perItem; end
		return BIGNUM;
	end

	return 0;
end

local function Fdr_Comparator (a, b)

	local av = Fdr_SortValue (a, gFdr_SortKey);
	local bv = Fdr_SortValue (b, gFdr_SortKey);

	if (av == bv) then
		local an = string.lower (a.name or "");
		local bn = string.lower (b.name or "");
		if (an ~= bn) then
			return an < bn;
		end
		return Fdr_SortValue (a, "peritem") < Fdr_SortValue (b, "peritem");
	end

	if (gFdr_SortAsc) then
		return av < bv;
	else
		return av > bv;
	end
end

local function Fdr_SortAndRedisplay ()

	table.sort (gFdr_Display, Fdr_Comparator);
	Atr_Finder_Redisplay ();
end

local function Fdr_UpdateHeaderArrows ()

	for key, btn in pairs (gFdr_Headers) do
		if (key == gFdr_SortKey) then
			btn.arrow:SetText (gFdr_SortAsc and "|cff88ccff^|r" or "|cff88ccffv|r");
		else
			btn.arrow:SetText ("");
		end
	end
end

local function Fdr_HeaderClick (key)

	if (gFdr_SortKey == key) then
		gFdr_SortAsc = not gFdr_SortAsc;
	else
		gFdr_SortKey = key;
		-- stats and item level: highest first feels right by default
		gFdr_SortAsc = not (key:match ("^stat%d$") or key == "ilvl" or key == "dps");
	end

	Fdr_UpdateHeaderArrows ();
	Fdr_SortAndRedisplay ();
end

-------------------------------------------------------------------------------
-- grouping / display list construction
-------------------------------------------------------------------------------

local FDR_ARMOR_CLASS = 2;	-- index of Armor in GetAuctionItemClasses (stable in 3.3.5)
local FDR_RECIPE_CLASS = 9;	-- index of Recipe in the same list, same assumption

-- Summarizes the category selection. Armor is special: material subclasses
-- (Cloth/Leather/...) and slots (Legs/Chest/...) combine with AND — materials
-- OR'd among themselves, slots OR'd among themselves — so "Leather + Legs +
-- Chest" means leather items that are legs or chest, not all leather.
local function Fdr_CatSummary ()

	local s = { classSet = {}, otherSubs = {}, armorAll = false,
				mats = {}, matLeaves = {}, nMats = 0,
				slotTokens = {}, slotLeaves = {}, nSlots = 0, armorName = nil };

	for _, leaf in ipairs (gFdr_SelectedCats) do

		if (leaf.kind == "class") then
			if (leaf.ci == FDR_ARMOR_CLASS) then
				s.armorAll	= true;
				s.armorName	= leaf.label;
			else
				s.classSet[leaf.label] = true;
			end

		elseif (leaf.kind == "subclass") then
			if (leaf.ci == FDR_ARMOR_CLASS) then
				s.mats[leaf.label]	= true;
				s.nMats				= s.nMats + 1;
				tinsert (s.matLeaves, leaf);
				s.armorName			= leaf.className;
			else
				s.otherSubs[leaf.className] = s.otherSubs[leaf.className] or {};
				s.otherSubs[leaf.className][leaf.label] = true;
			end

		elseif (leaf.kind == "slot") then
			for t in pairs (leaf.tokens) do
				s.slotTokens[t] = true;
			end
			tinsert (s.slotLeaves, leaf);
			s.nSlots = s.nSlots + 1;
		end
	end

	if (not s.armorName and GetAuctionItemClasses) then
		s.armorName = select (FDR_ARMOR_CLASS, GetAuctionItemClasses());
	end
	s.armorName		= s.armorName or "Armor";
	s.armorSelected	= s.armorAll or s.nMats > 0 or s.nSlots > 0;

	return s;
end

-- Server-side inventory-type filter (arg 4 of QueryAuctionItems). The index
-- is a 1-based ordinal into GetAuctionInvTypes(class, subclass), which returns
-- alternating token/display pairs.
--
-- Verified on Ascension 2026-07 (see ASCENSION-CLIENT-NOTES):
--   * the list order is NOT our FDR_ARMOR_SLOTS order (waist 6, wrist 9),
--   * its length varies by subclass (Cloth/Leather 11, Miscellaneous 14),
--   * INVTYPE_ROBE has no entry at all - the server folds robes into
--     INVTYPE_CHEST, so a chest query returns both.
-- Resolve by token, never by position.
local gFdr_InvTypeCache = {};

local function Fdr_InvTypeMap (classIndex, subclassIndex)

	if (not classIndex or not subclassIndex or not GetAuctionInvTypes) then
		return nil;
	end

	local ckey = classIndex.."/"..subclassIndex;

	if (gFdr_InvTypeCache[ckey] == nil) then

		local map	= {};
		local list	= { GetAuctionInvTypes (classIndex, subclassIndex) };
		local any	= false;

		local i;
		for i = 1, #list, 2 do
			local token = list[i];
			if (type (token) == "string" and map[token] == nil) then
				map[token]	= (i + 1) / 2;
				any			= true;
			end
		end

		-- Never cache a failed probe: GetAuctionInvTypes can come back empty
		-- before the AH has finished opening, and a cached empty map would
		-- disable slot filtering for the rest of the session.
		if (not any) then
			return nil;
		end

		gFdr_InvTypeCache[ckey] = map;
	end

	return gFdr_InvTypeCache[ckey];
end

-- Resolves every selected slot to a server inv-type index for one armor
-- subclass. Returns a sorted { index, label } list, or nil if ANY selected
-- slot has no index there (INVTYPE_CLOAK has none under Cloth or Leather).
-- nil means "fall back to an unfiltered scan for this material": an item the
-- server never sends cannot be recovered by the client-side equipLoc check,
-- so a partial server filter would silently lose rows.
local function Fdr_SlotSpecTypes (slotLeaves, subclassIndex)

	if (not slotLeaves or #slotLeaves == 0) then
		return nil;
	end

	local map = Fdr_InvTypeMap (FDR_ARMOR_CLASS, subclassIndex);
	if (not map) then
		return nil;
	end

	local out	= {};
	local seen	= {};

	local _, leaf;
	for _, leaf in ipairs (slotLeaves) do

		local got = false;

		local token;
		for token in pairs (leaf.tokens or {}) do
			local idx = map[token];
			if (idx) then
				got = true;
				if (not seen[idx]) then
					seen[idx] = true;
					tinsert (out, { index = idx, label = leaf.label });
				end
			end
		end

		if (not got) then
			return nil;
		end
	end

	table.sort (out, function (a, b) return a.index < b.index; end);

	return out;
end

-- Builds the list of server queries for the current category selection.
-- Class/subclass selections each get their own server-filtered scan
-- (autoAccept: the server guarantees the category). Armor slot selections
-- collapse into one Armor-wide scan filtered client-side by equip location.
local function Fdr_BuildSpecQueue ()

	local specs = {};

	if (#gFdr_SelectedCats == 0) then
		tinsert (specs, { class = nil, subclass = nil, autoAccept = false, label = "" });
		return specs;
	end

	local s = Fdr_CatSummary ();

	-- non-armor: class scans, plus subclass scans not covered by a class scan
	local classAll = {};
	for _, leaf in ipairs (gFdr_SelectedCats) do
		if (leaf.kind == "class" and leaf.ci ~= FDR_ARMOR_CLASS) then
			classAll[leaf.ci] = true;
			tinsert (specs, { class = leaf.ci, subclass = nil, autoAccept = true, label = leaf.label });
		end
	end
	for _, leaf in ipairs (gFdr_SelectedCats) do
		if (leaf.kind == "subclass" and leaf.ci ~= FDR_ARMOR_CLASS and not classAll[leaf.ci]) then
			tinsert (specs, { class = leaf.ci, subclass = leaf.si, autoAccept = true, label = leaf.label });
		end
	end

	-- armor: materials AND slots
	if (s.armorSelected) then

		if (s.nSlots == 0) then
			-- no slot restriction: server-filtered, auto-accepted
			if (s.armorAll) then
				tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = nil, autoAccept = true, label = s.armorName });
			else
				for _, leaf in ipairs (s.matLeaves) do
					tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = leaf.si, autoAccept = true, label = leaf.label });
				end
			end
		else
			-- Slot restriction. With a material also chosen, push the slot down
			-- to the server's inventory-type filter: "Leather + Head" becomes
			-- one small query instead of scanning all leather and discarding
			-- most of it. autoAccept stays false regardless - the client-side
			-- equipLoc check is kept as a net against a wrong index, which also
			-- means a server that ignores the parameter behaves as before.
			if (s.nMats > 0 and not s.armorAll) then
				for _, leaf in ipairs (s.matLeaves) do

					local invTypes = Fdr_SlotSpecTypes (s.slotLeaves, leaf.si);

					if (invTypes) then
						local _, it;
						for _, it in ipairs (invTypes) do
							tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = leaf.si,
											  invType = it.index, autoAccept = false,
											  label = leaf.label.." "..it.label });
						end
					else
						tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = leaf.si,
										  autoAccept = false, label = leaf.label });
					end
				end
			else
				tinsert (specs, { class = FDR_ARMOR_CLASS, subclass = nil, autoAccept = false, label = s.armorName });
			end
		end
	end

	return specs;
end

-- OR across selected category leaves; autoAccept records came from a scan
-- whose server filter already guarantees a selected category
local function Fdr_PassesCategoryFilter (rec)

	if (#gFdr_SelectedCats == 0) then
		return true;
	end

	if (rec.autoAccept) then
		return true;
	end

	local s = gFdr_CatSum or Fdr_CatSummary ();

	if (s.classSet[rec.itemType]) then
		return true;
	end

	local subs = s.otherSubs[rec.itemType];
	if (subs and subs[rec.itemSubType]) then
		return true;
	end

	if (s.armorSelected and rec.itemType == s.armorName) then
		local matOK		= s.armorAll or s.nMats == 0 or s.mats[rec.itemSubType] == true;
		local slotOK	= s.nSlots == 0 or (rec.equipLoc and s.slotTokens[rec.equipLoc] == true);
		if (matOK and slotOK) then
			return true;
		end
	end

	return false;
end

-- Strips the per-instance fields from an item link payload so that two
-- physically identical items produce the same key:
--   field 8 = uniqueId (random seed), field 9 = linkLevel (seller's level).
-- Any extra fields Ascension appends are preserved untouched.
local function Fdr_NormalizeLink (link)

	if (not link) then return nil; end

	local payload = link:match ("|Hitem:([%-%d:]+)|h") or link:match ("^item:([%-%d:]+)$");
	if (not payload) then return link; end

	local fields = {};
	for f in payload:gmatch ("[^:]+") do
		tinsert (fields, f);
	end

	if (fields[8]) then fields[8] = "0"; end
	if (fields[9]) then fields[9] = "0"; end

	return table.concat (fields, ":");
end

-- Group key for equippable items: normalized identity + exact stat fingerprint
-- + quality + item level. Same name is NOT sufficient (Ascension items with
-- identical names can carry different rolls); identical key IS sufficient.
local function Fdr_GearGroupKey (rec)

	local parts = {};
	for statKey, val in pairs (Fdr_GetStats (rec)) do
		tinsert (parts, statKey.."="..tostring (val));
	end
	table.sort (parts);

	return (Fdr_NormalizeLink (rec.link) or rec.name or "?")
			.."#q"..tostring (rec.quality or 0)
			.."#i"..tostring (rec.ilvl or 0)
			.."#L"..tostring (rec.level or 0)
			.."#"..table.concat (parts, ";");
end

local function Fdr_PerItem (rec)

	if (rec.buyoutPrice and rec.buyoutPrice > 0 and rec.count and rec.count > 0) then
		return math.floor (rec.buyoutPrice / rec.count);
	end
	return 0;
end

local Fdr_PassesStatFilter;		-- fwd decl

-- enforced against rec.level: the same value shown in the Lvl column, so the
-- filter always agrees with what's on screen
local function Fdr_PassesLevelFilter (rec)

	if (gFdr_LvlMin and (rec.level or 0) < gFdr_LvlMin) then return false; end
	if (gFdr_LvlMax and (rec.level or 0) > gFdr_LvlMax) then return false; end
	if (gFdr_ReqCap and (rec.level or 0) > gFdr_ReqCap) then return false; end
	return true;
end

-- Hide recipes this character already knows.  The knowing is decided in
-- AuctionatorFinderProfession.lua (Atr_Craft_IsRecipeKnown, which reads the
-- client's own ITEM_SPELL_KNOWN tooltip line); this only asks.
--
-- Gated on the item class for COST, not correctness: only a recipe ever carries
-- the known-line, so scanning a tooltip for every sword would be pure waste.
-- The class name comes from GetAuctionItemClasses, which returns the same
-- strings GetItemInfo does (see Fdr_IsGearClassName) -- so this reads right on
-- a localised client, where an English literal would not. The literal is kept
-- as a fallback for a server that reorders the list; if neither matches, the
-- filter simply stops hiding anything, which is the safe direction.
--
-- The verdict is memoised on the record because a rebuild runs on every sort,
-- filter tick and column change, and a tooltip scan per row per rebuild would
-- be felt. A fresh search builds fresh records, so a recipe learned mid-session
-- is re-read then -- and the per-character cache carries a `true` across
-- sessions anyway.
local function Fdr_IsRecipeClassName (sType)

	if (sType == nil) then return false; end
	if (sType == "Recipe") then return true; end
	if (GetAuctionItemClasses == nil) then return false; end

	local recipe = select (FDR_RECIPE_CLASS, GetAuctionItemClasses());
	return (recipe ~= nil and sType == recipe);
end

local function Fdr_PassesKnownFilter (rec)

	if (not gFdr_HideKnown) then return true; end
	if (not Fdr_IsRecipeClassName (rec.itemType)) then return true; end

	if (rec.recipeKnown == nil) then
		rec.recipeKnown = (type (Atr_Craft_IsRecipeKnown) == "function")
						  and Atr_Craft_IsRecipeKnown (rec.link) or false;
	end

	return not rec.recipeKnown;
end

local function Fdr_PassesFilters (rec)
	return Fdr_PassesLevelFilter (rec) and Fdr_PassesCategoryFilter (rec)
			and Fdr_PassesStatFilter (rec) and Fdr_PassesKnownFilter (rec);
end

Fdr_PassesStatFilter = function (rec)

	if (#gFdr_SelectedStats == 0) then
		return true;
	end

	if (not rec.equippable) then
		return false;		-- stat filter active: only gear can qualify
	end

	local i;
	for i = 1, #gFdr_SelectedStats do
		if (Fdr_GetStat (rec, gFdr_SelectedStats[i]) == 0) then
			return false;
		end
	end

	return true;
end

local Fdr_PostRebuild;		-- set below; runs after every display rebuild

function Atr_Finder_RebuildDisplay ()

	gFdr_Display = {};
	gFdr_CatSum  = Fdr_CatSummary ();

	gFdr_LvlMin = nil;
	gFdr_LvlMax = nil;
	if (Atr_Finder_MinLevel) then
		local n = Atr_Finder_MinLevel:GetNumber();
		if (n and n > 0) then gFdr_LvlMin = n; end
	end
	if (Atr_Finder_MaxLevel) then
		local n = Atr_Finder_MaxLevel:GetNumber();
		if (n and n > 0) then gFdr_LvlMax = n; end
	end

	gFdr_ReqCap = nil;
	if (Atr_Finder_ReqCheck and Atr_Finder_ReqCheck:GetChecked() and UnitLevel) then
		gFdr_ReqCap = UnitLevel ("player");
	end

	-- read once per rebuild, not once per row: the setting lives in the Finder
	-- options panel (the control row here has no space left for a checkbox)
	gFdr_HideKnown = (type (Fdr_HideKnownRecipes_Enabled) == "function")
					 and Fdr_HideKnownRecipes_Enabled () or false;

	local grouping = Atr_Finder_GroupCheck and Atr_Finder_GroupCheck:GetChecked();

	if (not grouping) then

		local i;
		for i = 1, #gFdr_Results do
			local rec = gFdr_Results[i];
			rec.perItem		= Fdr_PerItem (rec);
			rec.numListings	= 1;
			if (Fdr_PassesFilters (rec)) then
				tinsert (gFdr_Display, rec);
			end
		end

		if (Fdr_PostRebuild) then Fdr_PostRebuild (); end
		return;
	end

	local groups = {};		-- link -> group display rec

	local i;
	for i = 1, #gFdr_Results do

		local rec = gFdr_Results[i];
		rec.perItem = Fdr_PerItem (rec);

		if (not Fdr_PassesFilters (rec)) then
			-- filtered out entirely

		elseif (not rec.link) then

			rec.numListings = 1;
			tinsert (gFdr_Display, rec);

		else
			local key = rec.equippable and Fdr_GearGroupKey (rec) or rec.link;
			local g = groups[key];

			if (g == nil) then

				g = {};
				for k, v in pairs (rec) do g[k] = v; end

				g.numListings	= 1;
				g.totalQty		= rec.count or 1;
				g.groupKey		= key;
				g.members		= { rec };

				-- per-instance fields never belong to a merged face directly;
				-- they are re-derived below once all members are known
				g.trueIlvl		= nil;
				g.trueDPS		= nil;
				g.trueLines		= nil;
				g.trueStats		= nil;
				g.fdrVerified	= nil;
				g.fdrGone		= nil;

				groups[key] = g;
				tinsert (gFdr_Display, g);
			else
				g.numListings	= g.numListings + 1;
				g.totalQty		= g.totalQty + (rec.count or 1);
				tinsert (g.members, rec);

				-- keep the cheapest per-item listing as the face of the group
				if (rec.perItem > 0 and (g.perItem == 0 or rec.perItem < g.perItem)) then
					g.perItem		= rec.perItem;
					g.buyoutPrice	= rec.buyoutPrice;
					g.count			= rec.count;
					g.timeLeft		= rec.timeLeft;
					g.owner			= rec.owner;
				end
			end
		end
	end

	-- for groups, the qty column shows the TOTAL quantity across listings;
	-- (for gear that's simply the number of identical copies listed)
	for key, g in pairs (groups) do
		g.count = g.totalQty;

		-- the face may show verified values only when EVERY member was
		-- verified and they agree (per-instance scaling can differ even
		-- inside one group; disagreement keeps the face dimmed)
		--
		-- Stats merge PER KEY, exactly as ilvl and DPS merge: two listings
		-- can share an agility roll and differ on stamina, and dropping the
		-- agreed half would send the column back to the cached number for no
		-- reason.  A dropped key falls back to the cache and, because the
		-- stat cells dim per cell, says so.
		--
		-- The captured TOOLTIP is different in kind: it is one document, not
		-- a bag of fields, so it transfers only when every member captured
		-- exactly the same one.  Otherwise the face keeps the cached body and
		-- the scaled warning, and a click opens the per-listing window.
		local ti, td, tstats, tlines, allv;
		allv = true;
		local mi;
		for mi = 1, #g.members do
			local m = g.members[mi];
			if (not m.fdrVerified) then
				allv = false;
				break;
			end
			if (mi == 1) then
				ti = m.trueIlvl;
				td = m.trueDPS;
				tlines = m.trueLines;

				-- copied, never shared: the merge below prunes keys, and a
				-- face must not be able to edit its own member
				if (m.trueStats) then
					tstats = {};
					local k, v;
					for k, v in pairs (m.trueStats) do tstats[k] = v; end
				end
			else
				if (ti ~= m.trueIlvl) then ti = nil; end
				if (td ~= m.trueDPS)  then td = nil; end

				if (not Fdr_SameTrueLines (tlines, m.trueLines)) then tlines = nil; end

				if (tstats) then
					local ms = m.trueStats;
					local k, v;
					-- clearing existing fields during a pairs() walk is
					-- explicitly allowed in Lua 5.1; adding them is not
					for k, v in pairs (tstats) do
						if (ms == nil or ms[k] ~= v) then tstats[k] = nil; end
					end
				end
			end
		end
		if (allv) then
			g.trueIlvl	= ti;
			g.trueDPS	= td;
			g.trueStats	= tstats;
			g.trueLines	= tlines;
		end
	end

	if (Fdr_PostRebuild) then Fdr_PostRebuild (); end
end

function Atr_Finder_HasDPSColumn ()
	return gFdr_HasDPS;
end

-- weapons in the display -> DPS column appears; called after every rebuild
local function Fdr_UpdateDPSColumn ()

	local has = false;
	local i;
	for i = 1, #gFdr_Display do
		local rec = gFdr_Display[i];
		if (rec.equippable and Fdr_GetStat (rec, FDR_DPS_KEY) ~= 0) then
			has = true;
			break;
		end
	end

	if (has ~= gFdr_HasDPS) then
		gFdr_HasDPS = has;
		if (gFdr_SortKey == "dps" and not has) then
			gFdr_SortKey = "peritem";
			gFdr_SortAsc = true;
		end
		Fdr_ApplyColumnLayout ();
		Fdr_UpdateHeaderArrows ();
	end
end

Fdr_PostRebuild = Fdr_UpdateDPSColumn;

-------------------------------------------------------------------------------
-- direct buy: locate a specific listing by its full identity tuple
-- (name + stack + buyout + required level) and buy exactly that one.
-- The level component is what makes this safe on Ascension: scaled variants
-- share links but never levels, so the tuple can't buy the wrong version.
-------------------------------------------------------------------------------

local FDRBUY_IDLE		= 0;
local FDRBUY_QUERY		= 1;	-- waiting to send the next page query
local FDRBUY_WAIT		= 2;	-- page query sent, waiting for results
local FDRBUY_CONFIRM	= 3;	-- listing found and loaded; awaiting the user's
								-- Buyout/Bid choice (PlaceAuctionBid is hardware-
								-- event protected and must run inside a click)
local FDRBUY_FINAL		= 4;	-- final are-you-sure step before the purchase

local gFdrBuy_State		= FDRBUY_IDLE;
local gFdrBuy_Rec		= nil;
local gFdrBuy_Page		= 0;
local gFdrBuy_Query		= nil;
local gFdrBuy_SentAt	= 0;

local FDRBUY_MAX_PAGES	= 10;
local FDRBUY_TIMEOUT	= 8;

local gFdrBuy_FoundIndex = nil;
local gFdrBuy_BidShown	 = nil;		-- bid amount displayed to the user at Found
local gFdrBuy_FinalMode	 = nil;		-- "buyout"/"bid" pending final confirmation
local gFdrBuy_FinalPrice = nil;

function FdrBuy_RequiredBid (bidAmount, minIncrement, minBid)

	if (bidAmount and bidAmount > 0) then
		return bidAmount + (minIncrement or 0);
	end
	return minBid or 0;
end

function FdrBuy_HidePreview ()
	if (Atr_Finder_PreviewTT) then Atr_Finder_PreviewTT:Hide(); end
end

-- With the listing live-loaded we can read the SERVER's tooltip for this
-- exact instance - the only accurate source for scaled items - and pull the
-- true DPS and item level back into the row.
function FdrBuy_HarvestTrueData (index, rec)

	local tt = Atr_FinderScanTT;
	if (not (tt and tt.SetAuctionItem and tt.NumLines)) then return; end

	tt:SetOwner (UIParent, "ANCHOR_NONE");
	tt:SetAuctionItem ("list", index);

	local n = tt:NumLines() or 0;
	local ilvlPat = (ITEM_LEVEL and ITEM_LEVEL:gsub ("%%d", "(%%d+)")) or "Item Level (%d+)";

	-- The same pass now keeps the WHOLE rendered tooltip.  This is the only
	-- moment the server's text for this exact instance is on screen, and the
	-- row tooltip cannot reproduce it later: SetHyperlink resolves a link,
	-- and scaled variants share one byte-identical link.  Capped at 40 lines
	-- so a pathological tooltip cannot bloat a scan holding thousands of
	-- records; nothing in 3.3.5 comes close.
	local lines = {};

	local j;
	for j = 1, n do
		local fs  = _G["Atr_FinderScanTTTextLeft"..j];
		local txt = fs and fs:GetText();
		if (txt) then
			local d = txt:match ("([%d%.]+)%s+damage per second");	-- enUS pattern
			if (d) then rec.trueDPS = tonumber (d); end

			local il = txt:match (ilvlPat);
			if (il) then rec.trueIlvl = tonumber (il); end
		end

		if (j <= 40) then
			local fsr = _G["Atr_FinderScanTTTextRight"..j];
			local e = { l = txt or "" };

			-- GetTextColor is absent on some mock fontstrings and on any
			-- future client that drops it; a nil colour simply means "leave
			-- whatever the cached line was using".
			if (fs and fs.GetTextColor) then e.lr, e.lg, e.lb = fs:GetTextColor(); end

			if (fsr and fsr.GetText) then
				e.r = fsr:GetText() or "";
				if (e.r ~= "" and fsr.GetTextColor) then e.rr, e.rg, e.rb = fsr:GetTextColor(); end
			end

			lines[j] = e;
		end
	end

	rec.trueLines	= (#lines > 0) and lines or nil;
	rec.trueStats	= Fdr_TrueStatsFromLines (rec.trueLines, Fdr_GetStats (rec));
	rec.fdrVerified = true;

	Fdr_AHVariant_Record (rec);
end

-- Verification is the moment a scaled listing becomes storable: the server
-- tooltip just gave us its real item level, and the list API's own `level`
-- return gave us its real required level.  That tuple names the variant
-- exactly, so unlike the name-keyed feed (Fdr_PriceDB_Update rule 2) this
-- price can be filed without smearing six variants together -- and the
-- tooltip can find it again from the same tuple.  See the
-- FINDER_TAB "verified auction prices per scale-variant" block in
-- AuctionatorHints.lua for the storage rules.
--
-- Deliberately narrow: only scaled equipment, which is precisely what the
-- name-keyed DB refuses.  Everything else already prices correctly by name,
-- and writing it here would give one item two sources that could disagree.
function Fdr_AHVariant_Record (rec)

	if (type (rec) ~= "table" or not Atr_AHVariant_Note) then return false; end
	if (not (rec.scaled and rec.equippable)) then return false; end

	local link   = rec.link;
	local itemID = link and tonumber (link:match ("|Hitem:(%d+)") or link:match ("^item:(%d+)"));
	local ilvl   = tonumber (rec.trueIlvl or 0) or 0;
	local req    = tonumber (rec.level or 0) or 0;
	if (not itemID or ilvl <= 0 or req <= 0) then return false; end

	-- bid-only listings carry no buyout and must never be read as free
	local bo = tonumber (rec.buyoutPrice or 0) or 0;
	if (bo <= 0) then return false; end

	local cnt = tonumber (rec.count or 1) or 1;
	if (cnt < 1) then cnt = 1; end

	return Atr_AHVariant_Note (itemID, ilvl, req, math.floor (bo / cnt));
end

-- Lua patterns have no "literal" flag, so a stat label has to be escaped
-- before it can be matched.  Locale labels are ordinary words in enUS but
-- nothing guarantees that everywhere.
function Fdr_EscapePattern (s)
	return (tostring (s):gsub ("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"));
end

-- True when two captured tooltips would render identically.  Used to decide
-- whether a merged face may claim its members' tooltip: same length, same
-- text on both sides, same colours.  Two nils count as the same (neither
-- member captured anything), which is harmless - the face ends up with nil
-- either way.
function Fdr_SameTrueLines (a, b)

	if (a == b) then return true; end
	if (type (a) ~= "table" or type (b) ~= "table") then return false; end
	if (#a ~= #b) then return false; end

	local i;
	for i = 1, #a do
		local x, y = a[i], b[i];
		if (x == nil or y == nil) then return false; end
		if (x.l ~= y.l or x.r ~= y.r) then return false; end
		if (x.lr ~= y.lr or x.lg ~= y.lg or x.lb ~= y.lb) then return false; end
		if (x.rr ~= y.rr or x.rg ~= y.rg or x.rb ~= y.rb) then return false; end
	end

	return true;
end

-- Reads real stat values out of a captured server tooltip.
--
-- The CACHED stat table decides which stats to look for and under which
-- keys; the captured tooltip supplies the values.  That split matters:
-- GetItemStats returns keys (ITEM_MOD_AGILITY_SHORT), a tooltip renders
-- labels ("Agility"), and _G[key] is the only bridge between them - which
-- also keeps this correct in every locale without a word list.
--
-- Deliberately limited to the "+18 Agility" / "126 Armor" forms, i.e. the
-- base stats and armor - the ones the stat picker offers by default.
-- Ratings arrive as prose ("Equip: Improves hit rating by 3.") whose
-- shape varies by effect and by locale; guessing at those would put wrong
-- numbers in a column that now looks authoritative, which is exactly the
-- bug being fixed.  Those keys stay absent and fall back to the cache.
--
-- The label must match to END of line, or "Agility" would also claim a
-- line reading "+3 Agility Rating".
function Fdr_TrueStatsFromLines (lines, cached)

	if (type (lines) ~= "table" or type (cached) ~= "table") then return nil; end

	local out, any = {}, false;

	local key;
	for key in pairs (cached) do

		local label = _G[key];
		if (type (label) == "string" and label ~= "") then

			local pat = "^%+?([%d%.]+)%s+"..Fdr_EscapePattern (label).."$";

			local i;
			for i = 1, #lines do
				local txt = lines[i] and lines[i].l;
				if (txt and txt ~= "") then
					local v = tonumber (txt:match (pat));
					if (v) then
						out[key] = v;
						any = true;
						break;
					end
				end
			end
		end
	end

	return any and out or nil;
end

-- Replays a captured server tooltip over the cached body that SetHyperlink
-- just drew.  nItem is where that body ends (published by the hints module
-- as Atr_Finder_TipItemLines); everything past it is Auctionator's own
-- price lines and must not be touched.
--
-- Overwriting rather than rebuilding is deliberate: the tooltip keeps the
-- item identity SetHyperlink gave it, so GameTooltip_ShowCompareItem still
-- works.  A rebuilt-from-text tooltip has no GetItem() and Compare dies.
function Fdr_ApplyTrueLines (tip, lines, nItem)

	if (not (tip and lines and nItem and nItem > 0)) then return; end

	local tname = tip.GetName and tip:GetName();
	if (not tname) then return; end

	local i;
	for i = 1, nItem do

		local src = lines[i];
		local L   = _G[tname.."TextLeft"..i];
		local R   = _G[tname.."TextRight"..i];

		if (L and L.SetText) then
			-- no counterpart means the cached body was LONGER; blanking is
			-- the honest option, since the leftover line describes a variant
			-- that is not the one under the cursor
			L:SetText ((src and src.l) or "");
			if (src and src.lr and L.SetTextColor) then L:SetTextColor (src.lr, src.lg, src.lb); end
		end

		if (R and R.SetText) then
			if (src and src.r and src.r ~= "") then
				R:SetText (src.r);
				if (src.rr and R.SetTextColor) then R:SetTextColor (src.rr, src.rg, src.rb); end
				if (R.Show) then R:Show(); end
			else
				R:SetText ("");
				if (R.Hide) then R:Hide(); end
			end
		end
	end

	-- the true tooltip ran LONGER than the cached one.  The surplus cannot be
	-- spliced into the middle of a drawn tooltip, so append it rather than
	-- drop it: out of order beats missing.
	for i = nItem + 1, #lines do
		local src = lines[i];
		if (src and src.l and src.l ~= "") then
			if (src.r and src.r ~= "" and tip.AddDoubleLine) then
				tip:AddDoubleLine (src.l, src.r, src.lr, src.lg, src.lb, src.rr, src.rg, src.rb);
			elseif (tip.AddLine) then
				tip:AddLine (src.l, src.lr, src.lg, src.lb, true);
			end
		end
	end
end

function FdrBuy_Fail (msg)

	gFdrBuy_State = FDRBUY_IDLE;
	FdrBuy_HidePreview ();
	if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end
	Fdr_SetMessage ("|cffff6666"..(msg or FT("Purchase failed")).."|r");
end

function Atr_Finder_CancelBuy ()

	gFdrBuy_State = FDRBUY_IDLE;
	FdrBuy_HidePreview ();
	if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end
end

function FdrBuy_Matches (i, rec)

	local name, _, count, _, _, level, _, _, buyoutPrice = GetAuctionItemInfo ("list", i);

	return name == rec.name
		and (count or 1) == (rec.count or 1)
		and (buyoutPrice or 0) == (rec.buyoutPrice or 0)
		and (level or 0) == (rec.level or 0);
end

function FdrBuy_Found (i, rec)

	gFdrBuy_FoundIndex	= i;
	gFdrBuy_State		= FDRBUY_CONFIRM;

	FdrBuy_HarvestTrueData (i, rec);

	-- fresh bid data from the live listing (scan-time values may be stale)
	local _, _, _, _, _, _, liveMinBid, liveIncr, liveBuyout, liveBid = GetAuctionItemInfo ("list", i);
	gFdrBuy_BidShown = FdrBuy_RequiredBid (liveBid, liveIncr, liveMinBid);

	FdrBuy_ShowConfirmView ();

	Atr_Finder_Redisplay ();	-- true DPS/iLvl now render verified (white)
end

-- (re)populates the dialog for the found listing: preview embedded, prices
-- above their buttons, bid input prefilled with the minimum
function FdrBuy_ShowConfirmView ()

	local f, rec, i = Atr_Finder_BuyFrame, gFdrBuy_Rec, gFdrBuy_FoundIndex;
	if (not f or not rec or not i) then return; end

	gFdrBuy_State = FDRBUY_CONFIRM;

	f.details:SetText (FT("Listing found and verified."));

	if (rec.buyoutPrice and rec.buyoutPrice > 0) then
		f.buyoutLabel:SetText (Fdr_MoneyString (rec.buyoutPrice));
		f.buyBtn:Enable();
	else
		f.buyoutLabel:SetText ("|cff888888--|r");
		f.buyBtn:Disable();
	end
	f.buyBtn:SetText (FT("Buyout"));

	if (gFdrBuy_BidShown and gFdrBuy_BidShown > 0) then
		if (f.bidInput and MoneyInputFrame_SetCopper) then
			MoneyInputFrame_SetCopper (f.bidInput, gFdrBuy_BidShown);
			f.bidInput:Show();
			f.bidLabel:SetText ("");
		else
			f.bidLabel:SetText (Fdr_MoneyString (gFdrBuy_BidShown));
		end
		f.bidBtn:Enable();
	else
		if (f.bidInput) then f.bidInput:Hide(); end
		f.bidLabel:SetText ("|cff888888--|r");
		f.bidBtn:Disable();
	end
	f.bidBtn:SetText (FT("Bid"));
	f.cancelBtn:SetText (FT("Cancel"));

	local tt = Atr_Finder_PreviewTT;
	if (tt and tt.SetAuctionItem) then
		tt:SetOwner (f, "ANCHOR_NONE");
		tt:SetAuctionItem ("list", i);
		tt:ClearAllPoints ();
		tt:SetPoint ("TOP", f, "TOP", 0, -58);
		tt:Show ();

		local th = (tt.GetHeight and tt:GetHeight()) or 0;
		if (f.SetHeight) then f:SetHeight (150 + th); end
		local tw = (tt.GetWidth and tt:GetWidth()) or 0;
		if (f.SetWidth and tw + 40 > 380) then f:SetWidth (tw + 40); end
	end
end

function FdrBuy_InlineError (msg)
	if (Atr_Finder_BuyFrame) then
		Atr_Finder_BuyFrame.details:SetText ("|cffff6666"..msg.."|r");
	end
end

-- first choice click (Buyout/Bid at CONFIRM): validate, then ask once more
function FdrBuy_EnterFinal (mode)

	local rec, i = gFdrBuy_Rec, gFdrBuy_FoundIndex;
	if (not rec or not i) then return; end

	if (not FdrBuy_Matches (i, rec)) then
		FdrBuy_Fail (FT("Listing changed - please try again"));
		return;
	end

	local payPrice;

	if (mode == "bid") then
		local _, _, _, _, _, _, liveMinBid, liveIncr, _, liveBid = GetAuctionItemInfo ("list", i);
		local required = FdrBuy_RequiredBid (liveBid, liveIncr, liveMinBid);

		payPrice = required;
		if (Atr_Finder_BuyFrame and Atr_Finder_BuyFrame.bidInput and MoneyInputFrame_GetCopper) then
			payPrice = MoneyInputFrame_GetCopper (Atr_Finder_BuyFrame.bidInput) or required;
		end

		if (payPrice < required) then
			FdrBuy_InlineError (string.format (FT("Bid too low - minimum is %s"), Fdr_MoneyString (required)));
			return;
		end
	else
		payPrice = rec.buyoutPrice;
		if (not payPrice or payPrice <= 0) then return; end
	end

	if (GetMoney and GetMoney() < payPrice) then
		FdrBuy_InlineError (FT("Not enough gold"));
		return;
	end

	gFdrBuy_FinalMode	= mode;
	gFdrBuy_FinalPrice	= payPrice;
	gFdrBuy_State		= FDRBUY_FINAL;

	local f = Atr_Finder_BuyFrame;
	if (f) then
		local verb = (mode == "bid") and FT("Place bid of") or FT("Buy out for");
		f.details:SetText ("|cffffd100"..verb.." "..Fdr_MoneyString (payPrice).."?|r");
		f.buyBtn:SetText (FT("Confirm"));
		f.buyBtn:Enable();
		f.bidBtn:Disable();
		f.cancelBtn:SetText (FT("Back"));
	end
end

-- FINAL confirm click: the purchase itself (still a hardware event)
function FdrBuy_ConfirmPurchase ()

	local rec, i	= gFdrBuy_Rec, gFdrBuy_FoundIndex;
	local mode		= gFdrBuy_FinalMode;
	local payPrice	= gFdrBuy_FinalPrice;

	if (not rec or not i or not payPrice) then
		FdrBuy_Fail (FT("Nothing to confirm"));
		return;
	end

	-- last-instant insurance: the tuple must still match at this index
	if (not FdrBuy_Matches (i, rec)) then
		FdrBuy_Fail (FT("Listing changed - please try again"));
		return;
	end

	if (mode == "bid") then
		local _, _, _, _, _, _, liveMinBid, liveIncr, _, liveBid = GetAuctionItemInfo ("list", i);
		if (FdrBuy_RequiredBid (liveBid, liveIncr, liveMinBid) > payPrice) then
			gFdrBuy_State = FDRBUY_CONFIRM;
			FdrBuy_ShowConfirmView ();
			FdrBuy_InlineError (FT("Bid has increased - amount refreshed"));
			return;
		end
	end

	PlaceAuctionBid ("list", i, payPrice);

	if (mode == "bid") then
		gFdrBuy_State = FDRBUY_IDLE;
		FdrBuy_HidePreview ();
		if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end
		Fdr_SetMessage ("|cff66ff66"..string.format (FT("Bid placed: %s (%s)"), rec.name, Fdr_MoneyString (payPrice)).."|r");
		return;
	end

	gFdrBuy_State = FDRBUY_IDLE;
	FdrBuy_HidePreview ();
	if (Atr_Finder_BuyFrame) then Atr_Finder_BuyFrame:Hide(); end

	-- remove one matching raw record so the display reflects the purchase
	FdrBuy_DropRec (rec);

	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();

	Fdr_SetMessage ("|cff66ff66"..string.format (FT("Bought: %s for %s"), rec.name, Fdr_MoneyString (payPrice)).."|r");
end

-- Drops one raw record matching this listing's tuple.  Identity is no use
-- here: a grouped row is a COPY of its member, so == never matches, which
-- is why FdrGrp_RemoveRec cannot be reused.  Returns true if one went.
function FdrBuy_DropRec (rec)

	if (rec == nil) then return false; end

	local k;
	for k = 1, #gFdr_Results do
		local r = gFdr_Results[k];
		if (r.name == rec.name and (r.count or 1) == (rec.count or 1)
				and (r.buyoutPrice or 0) == (rec.buyoutPrice or 0)
				and (r.level or 0) == (rec.level or 0)) then
			table.remove (gFdr_Results, k);
			return true;
		end
	end
	return false;
end

-- Does a short page really prove the server has nothing left to give?
--
-- Only if the page is OURS.  AUCTION_ITEM_LIST_UPDATE fires for any change to
-- the client's auction list - a completed bid, an owner refresh, another
-- addon's query - and both find loops consume whichever one arrives while they
-- are waiting; neither ever checked that the batch it read was the answer to
-- its own query.  Read a foreign batch and every unmatched member looks sold,
-- so one short foreign page condemns a whole name at once.  The server's own
-- unstable sort can hand back an incomplete result set for a query it answered
-- correctly seconds earlier (ASCENSION-CLIENT-NOTES), which reads identically
-- from here.  Either route explains a Verify that deleted six of seven live
-- listings once and never again.
--
-- An exhausted exact-name query must therefore still CONTAIN that name.  The
-- one case where it legitimately does not - every listing of the name sold in
-- the last few seconds - is precisely the case where guessing wrong deletes
-- rows the user came here to buy, so it resolves toward keeping them: a stale
-- row costs one wasted click and dies at the next scan, a wrongly pruned row
-- hides a purchase and looks like data loss.
--
-- The name is compared exactly.  QueryAuctionItems matches substrings, so a
-- batch can carry longer names that merely contain ours; those are somebody
-- else's listings and prove nothing about this one.
function FdrGrp_ShortPageProvesGone (numBatch, name)

	if (numBatch == nil or numBatch >= 50) then return false; end
	if (name == nil or name == "") then return false; end

	local i;
	for i = 1, numBatch do
		-- extra parens truncate the multi-return (see conventions)
		if ((GetAuctionItemInfo ("list", i)) == name) then return true; end
	end

	return false;
end

function FdrBuy_ScanPage ()

	local numBatch = GetNumAuctionItems ("list");

	local i;
	for i = 1, numBatch do
		if (FdrBuy_Matches (i, gFdrBuy_Rec)) then
			FdrBuy_Found (i, gFdrBuy_Rec);
			return;
		end
	end

	-- A short page means the server had nothing more to give: every listing
	-- under this name was seen and none of them is ours, so the row is a
	-- sold listing (or one double-seen across a page boundary during the
	-- scan).  Prune it, on the same rule FdrGrp_Finish uses - and leaving it
	-- on screen only invites the same click again.
	--
	-- Hitting the page cap is NOT that proof.  The search was cut short, so
	-- the row stays and the message stays uncommitted.
	if (FdrGrp_ShortPageProvesGone (numBatch, gFdrBuy_Rec and gFdrBuy_Rec.name)) then
		local rec = gFdrBuy_Rec;
		local dropped = FdrBuy_DropRec (rec);

		FdrBuy_Fail (dropped
			and FT("Listing is gone - it sold, and the row has been removed")
			or  FT("Listing not found - it may have sold or changed"));

		if (dropped) then
			Atr_Finder_RebuildDisplay ();
			Fdr_SortAndRedisplay ();
		end
		return;
	end

	-- Short, but not one row of it is the name we asked for: this batch is
	-- not our answer, or not a whole one.  Absence proves nothing, so the row
	-- stays and the user can click it again.
	if (numBatch < 50) then
		FdrBuy_Fail (FT("Listing not found - the auction list changed; try again"));
		return;
	end

	if (gFdrBuy_Page + 1 >= FDRBUY_MAX_PAGES) then
		FdrBuy_Fail (FT("Listing not found - it may have sold or changed"));
		return;
	end

	gFdrBuy_Page	= gFdrBuy_Page + 1;
	gFdrBuy_State	= FDRBUY_QUERY;
	gFdrBuy_SentAt	= time();
end

-- called by the Buy button on the confirm dialog
function Atr_Finder_ExecuteBuy ()

	local rec = gFdrBuy_Rec;
	if (not rec) then return; end

	gFdrBuy_Page	= 0;
	gFdrBuy_State	= FDRBUY_QUERY;
	gFdrBuy_SentAt	= time();

	if (Atr_NewQuery) then gFdrBuy_Query = Atr_NewQuery(); end
end

function FdrBuy_SendQuery ()

	local queryString = gFdrBuy_Rec.name;
	if (zc and zc.UTF8_Truncate) then
		queryString = zc.UTF8_Truncate (queryString, 63);
	end

	QueryAuctionItems (queryString, nil, nil, nil, 0, 0, gFdrBuy_Page, nil, nil);

	gFdrBuy_State	= FDRBUY_WAIT;
	gFdrBuy_SentAt	= time();
end

-------------------------------------------------------------------------------
-- group listings window: a grouped row's face carries the group TOTAL in its
-- count field, so the face is NOT a buyable identity tuple (this is why a
-- direct buy on a multi-listing group used to end in "Listing not found").
-- Clicking such a row opens this window instead: every real listing in the
-- group on its own line (qty / ilvl / dps / time left / buyout / per item),
-- each line individually buyable via the normal exact-buy flow.
-- For scaled gear the window auto-runs an exact-name find (same channel and
-- dup handling as the buy engine) and reads each listing's SERVER tooltip,
-- so dimmed base values populate to verified white per listing - the same
-- greyed->white behavior as the buy dialog, but for the whole group at once.
-------------------------------------------------------------------------------

local FDRGRP_IDLE	= 0;
local FDRGRP_QUERY	= 1;	-- waiting to send the next page query
local FDRGRP_WAIT	= 2;	-- page query sent, waiting for results
local FDRGRP_DONE	= 3;	-- window open; verification finished or not needed

local gFdrGrp_State		= FDRGRP_IDLE;
local gFdrGrp_Face		= nil;
local gFdrGrp_Members	= nil;
local gFdrGrp_Page		= 0;
local gFdrGrp_Query		= nil;
local gFdrGrp_SentAt	= 0;

local gFdrGrp_Mode		= "window";	-- "window" | "sweep" (the Verify button)
local gFdrGrp_Name		= nil;		-- exact-name query of the current find
local gFdrGrp_Queue		= nil;		-- sweep: remaining {name, members} entries
local gFdrGrp_QTotal	= 0;		-- sweep: total entries, for progress text
local gFdrGrp_Pruned	= 0;		-- stale records removed this run

local FDRGRP_MAX_PAGES	= 10;
local FDRGRP_TIMEOUT	= 8;
local FDRGRP_NUM_ROWS	= 10;
local FDRGRP_ROW_H		= 17;

local gFdrGrp_Rows = nil;
local gFdrGrp_Cols = nil;		-- active column layout (per group type)
local gFdrGrp_StatKeys = {};	-- the picked top-2 stat keys for this group

local FDRGRP_INNER_W = 348;

-- default whitelist for the window's stat columns: the five base stats.
-- Everything else (armor, resistances, PVE/PVP_POWER, ratings) stays out
-- unless the user picked it in the Stats dropdown.
local FDRGRP_BASE_STATS = {
	"ITEM_MOD_STAMINA_SHORT",
	"ITEM_MOD_STRENGTH_SHORT",
	"ITEM_MOD_AGILITY_SHORT",
	"ITEM_MOD_INTELLECT_SHORT",
	"ITEM_MOD_SPIRIT_SHORT",
};

-- picks the window's two stat columns:
--  1) stats selected in the Finder's Stats dropdown, in selection order
--     (this is how Armor or any other stat can be shown deliberately);
--  2) otherwise the two biggest BASE stats present on the item.
function FdrGrp_TopStats (face)

	local out = {};
	local i;

	for i = 1, #gFdr_SelectedStats do
		if (#out >= 2) then break; end
		if (gFdr_SelectedStats[i] ~= FDR_DPS_KEY) then
			tinsert (out, gFdr_SelectedStats[i]);
		end
	end
	if (#out > 0) then return out; end

	local base = {};
	for i = 1, #FDRGRP_BASE_STATS do base[FDRGRP_BASE_STATS[i]] = true; end

	local picks = {};
	local k, v;
	for k, v in pairs (Fdr_GetStats (face)) do
		if (base[k]) then
			tinsert (picks, { k = k, v = tonumber (v) or 0 });
		end
	end
	table.sort (picks, function (a, b)
		if (a.v ~= b.v) then return a.v > b.v; end
		return a.k < b.k;
	end);

	for i = 1, 2 do
		if (picks[i]) then out[i] = picks[i].k; end
	end
	return out;
end

-- builds the column list for this group and (re)anchors headers + row cells.
-- gear:  Qty | Lvl | [DPS] | [stat1] | [stat2] | Buyout
-- goods: Qty | Buyout | Per Item
function FdrGrp_ApplyLayout (face)

	local cols = {};
	local x = 0;
	local function add (key, label, w, j)
		tinsert (cols, { key = key, label = label, x = x, w = w, j = j });
		x = x + w + 8;
	end

	if (face.equippable) then
		add ("qty",  FT("Qty"),  30, "RIGHT");
		add ("lvl",  FT("Lvl"),  30, "RIGHT");

		if (face.trueDPS or Fdr_GetStat (face, FDR_DPS_KEY) ~= 0) then
			add ("dps", FT("DPS"), 42, "RIGHT");
		end

		gFdrGrp_StatKeys = FdrGrp_TopStats (face);
		local si;
		for si = 1, #gFdrGrp_StatKeys do
			add ("stat"..si, Fdr_StatDisplayName (gFdrGrp_StatKeys[si]), 58, "RIGHT");
		end

		add ("buyout", FT("Buyout"), 60, "RIGHT");
	else
		gFdrGrp_StatKeys = {};
		add ("qty",		FT("Qty"),		36, "RIGHT");
		add ("buyout",	FT("Buyout"),	130, "RIGHT");
		add ("peritem",	FT("Per Item"),	60, "RIGHT");
	end

	-- last column absorbs the remaining width
	local last = cols[#cols];
	last.w = FDRGRP_INNER_W - last.x;

	gFdrGrp_Cols = cols;

	local f = Atr_Finder_GroupFrame;
	if (not f) then return; end

	-- headers: park every known header, then place the active ones
	local key, fs;
	for key, fs in pairs (f.heads) do
		fs:SetText ("");
	end
	local ci;
	for ci = 1, #cols do
		local c = cols[ci];
		fs = f.heads[c.key];
		if (fs) then
			if (fs.ClearAllPoints) then fs:ClearAllPoints (); end
			fs:SetPoint ("TOPLEFT", 20 + c.x, -48);
			fs:SetWidth (c.w);
			fs:SetJustifyH (c.j);
			fs:SetText (c.label);
		end
	end

	-- row cells follow the same layout
	local i;
	for i = 1, FDRGRP_NUM_ROWS do
		local row = gFdrGrp_Rows[i];
		for ci = 1, #cols do
			local c = cols[ci];
			local cell = row.cells[c.key];
			if (cell) then
				if (cell.ClearAllPoints) then cell:ClearAllPoints (); end
				cell:SetPoint ("LEFT", c.x, 0);
				cell:SetWidth (c.w);
				cell:SetJustifyH (c.j);
			end
		end
	end
end

-- what a cell shows for a member; nil-safe for inactive columns
function FdrGrp_CellValue (key, m)

	if (key == "qty") then
		return tostring (m.count or 1);
	end
	if (key == "lvl") then
		return (m.level and m.level > 0) and tostring (m.level) or "";
	end
	if (key == "dps") then
		local dps = m.trueDPS or Fdr_GetStat (m, FDR_DPS_KEY);
		if (dps and dps ~= 0) then
			return (dps % 1 == 0) and tostring (dps) or string.format ("%.1f", dps);
		end
		return "";
	end
	local si = key:match ("^stat(%d)$");
	if (si) then
		local sk = gFdrGrp_StatKeys[tonumber (si)];
		local v = sk and Fdr_GetStat (m, sk);
		if (v and v ~= 0) then
			return (v % 1 == 0) and tostring (v) or string.format ("%.1f", v);
		end
		return "";
	end
	if (key == "buyout") then
		return Fdr_MoneyString (m.buyoutPrice);
	end
	if (key == "peritem") then
		if (m.perItem and m.perItem > 0 and m.count and m.count > 1) then
			return Fdr_MoneyString (m.perItem);
		end
		return "";
	end
	return "";
end

function FdrGrp_SetNote (txt)
	if (Atr_Finder_GroupFrame) then
		Atr_Finder_GroupFrame.note:SetText (txt or "");
	end
end

function FdrGrp_Redisplay ()

	local f = Atr_Finder_GroupFrame;
	if (not f or not gFdrGrp_Members or gFdrGrp_Mode ~= "window") then return; end

	local num = #gFdrGrp_Members;

	FauxScrollFrame_Update (Atr_Finder_GroupScroll, num, FDRGRP_NUM_ROWS, FDRGRP_ROW_H);
	local offset = FauxScrollFrame_GetOffset (Atr_Finder_GroupScroll);

	local scaled = gFdrGrp_Face and gFdrGrp_Face.scaled;

	local i;
	for i = 1, FDRGRP_NUM_ROWS do

		local row = gFdrGrp_Rows[i];
		local idx = offset + i;
		local m = gFdrGrp_Members[idx];

		if (m) then
			row.member = m;

			-- greyed until THIS listing's server tooltip has confirmed it
			local dim = 1;
			if (m.fdrGone) then
				dim = 0.4;
			elseif (scaled and not m.fdrVerified) then
				dim = 0.55;
			end

			-- blank every cell, then fill the active columns
			local key, cell;
			for key, cell in pairs (row.cells) do
				cell:SetText ("");
			end
			local ci;
			for ci = 1, #(gFdrGrp_Cols or {}) do
				local c = gFdrGrp_Cols[ci];
				cell = row.cells[c.key];
				if (cell) then
					local txt = FdrGrp_CellValue (c.key, m);
					if (m.fdrGone and c.key == "buyout") then
						txt = "|cffff6666?|r  "..txt;
					end
					cell:SetText (txt);
					-- price cells carry their own colors; the rest dim
					if (c.key ~= "buyout" and c.key ~= "peritem") then
						cell:SetTextColor (dim, dim, dim);
					end
				end
			end

			row:Show();
		else
			row.member = nil;
			row:Hide();
		end
	end
end

function Atr_Finder_CancelGroup ()

	gFdrGrp_State	= FDRGRP_IDLE;
	gFdrGrp_Face	= nil;
	gFdrGrp_Members	= nil;
	gFdrGrp_Queue	= nil;
	gFdrGrp_Mode	= "window";

	if (Atr_Finder_GroupFrame) then Atr_Finder_GroupFrame:Hide(); end
	if (Atr_Finder_UpdateVerifyButton) then Atr_Finder_UpdateVerifyButton (); end
end

-- removes a raw scan record by reference
function FdrGrp_RemoveRec (rec)

	local k;
	for k = 1, #gFdr_Results do
		if (gFdr_Results[k] == rec) then
			table.remove (gFdr_Results, k);
			return true;
		end
	end
	return false;
end


-- completes the current find. reason: "ok" | "exhausted" | "capped" |
-- "timeout". exhausted=true means every page was seen, so unverified
-- members truly aren't on the AH anymore: flag them gone AND remove them
-- from the scan results - they are sold listings, or single listings
-- double-seen across page boundaries during the scan (the server's
-- unstable sort). Timeouts, page caps and unproven batches never prune:
-- the search was cut short or was not ours, and absence proves nothing.
function FdrGrp_Finish (reason, exhausted)

	local gone = 0;
	if (gFdrGrp_Members and exhausted) then
		local i;
		for i = 1, #gFdrGrp_Members do
			local m = gFdrGrp_Members[i];
			if (not m.fdrVerified) then
				m.fdrGone = true;
				if (FdrGrp_RemoveRec (m)) then gone = gone + 1; end
			end
		end
	end
	gFdrGrp_Pruned = gFdrGrp_Pruned + gone;

	if (gFdrGrp_Mode == "sweep") then
		-- progressive: each finished name whitens/cleans the main list
		Atr_Finder_RebuildDisplay ();
		Fdr_SortAndRedisplay ();
		FdrGrp_NextInQueue ();
		return;
	end

	gFdrGrp_State = FDRGRP_DONE;

	local note;
	if (reason == "timeout") then
		note = FT("Verification timed out");
	elseif (reason == "unproven") then
		note = FT("The auction list changed - nothing removed; try again");
	elseif (gone > 0) then
		note = string.format (FT("%d stale listing(s) removed - sold or double-counted by the scan"), gone);
	elseif (reason == "capped") then
		note = FT("Some listings could not be verified");
	else
		note = FT("All listings verified");
	end
	FdrGrp_SetNote (note);
	FdrGrp_Redisplay ();

	-- a rebuild re-derives face trueIlvl/trueDPS from the (now verified)
	-- members, so the main list row turns white too when they agree
	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();
end

function FdrGrp_ScanPage ()

	if (not gFdrGrp_Members) then return; end

	local numBatch = GetNumAuctionItems ("list");
	local claimed = {};		-- one live index verifies at most one member

	local i;
	for i = 1, numBatch do
		local j;
		for j = 1, #gFdrGrp_Members do
			local m = gFdrGrp_Members[j];
			if (not m.fdrVerified and not claimed[i] and FdrBuy_Matches (i, m)) then
				claimed[i] = true;
				FdrBuy_HarvestTrueData (i, m);
				m.fdrVerified = true;
				break;
			end
		end
	end

	local remaining = 0;
	for i = 1, #gFdrGrp_Members do
		if (not gFdrGrp_Members[i].fdrVerified) then remaining = remaining + 1; end
	end

	if (remaining == 0) then
		FdrGrp_Finish ("ok", false);
		return;
	end

	if (FdrGrp_ShortPageProvesGone (numBatch, gFdrGrp_Name)) then
		FdrGrp_Finish ("exhausted", true);
		return;
	end

	-- Short page that does not carry our own name: see FdrGrp_ShortPageProvesGone.
	-- Finishing UNPROVEN prunes nothing, so the rows stay greyed and the Verify
	-- button stays on screen - which is the signal that a name was skipped, and
	-- pressing it again re-runs exactly those names.
	if (numBatch < 50) then
		FdrGrp_Finish ("unproven", false);
		return;
	end

	if (gFdrGrp_Page + 1 >= FDRGRP_MAX_PAGES) then
		FdrGrp_Finish ("capped", false);
		return;
	end

	FdrGrp_Redisplay ();

	gFdrGrp_Page	= gFdrGrp_Page + 1;
	gFdrGrp_State	= FDRGRP_QUERY;
	gFdrGrp_SentAt	= time();
end

function FdrGrp_SendQuery ()

	local queryString = gFdrGrp_Name or "";
	if (zc and zc.UTF8_Truncate) then
		queryString = zc.UTF8_Truncate (queryString, 63);
	end

	QueryAuctionItems (queryString, nil, nil, nil, 0, 0, gFdrGrp_Page, nil, nil);

	gFdrGrp_State	= FDRGRP_WAIT;
	gFdrGrp_SentAt	= time();
end

-- Flat, opaque dialog chrome for the Finder's popups.
--
-- UI-DialogBox-Background renders semi-transparent on this client, so the
-- group window and the buy dialog were showing the listing rows straight
-- through their own text.  WHITE8X8 tinted by SetBackdropColor is the
-- reliable way to get a solid fill on 3.3.5 - there is no alpha argument on
-- SetBackdrop itself, and the stock dialog art cannot be made opaque.
--
-- Every call is guarded: a frame without SetBackdrop (the test harness's
-- mock, say) degrades to no chrome rather than to an error.
function Fdr_StyleDialog (f)

	if (not (f and f.SetBackdrop)) then return; end

	f:SetBackdrop ({
		bgFile		= "Interface\\Buttons\\WHITE8X8",
		edgeFile	= "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile		= true, tileSize = 32, edgeSize = 32,
		insets		= { left = 11, right = 12, top = 12, bottom = 11 },
	});

	-- alpha 1 is the entire point; anything less and the rows read through
	if (f.SetBackdropColor) then f:SetBackdropColor (0.10, 0.10, 0.11, 1); end
	if (f.SetBackdropBorderColor) then f:SetBackdropBorderColor (0.85, 0.85, 0.85, 1); end
end

function FdrGrp_BuildFrame ()

	if (Atr_Finder_GroupFrame) then return; end

	local parent = Atr_Finder_Panel or AuctionFrame or UIParent;

	local f = CreateFrame ("Frame", "Atr_Finder_GroupFrame", parent);
	f:SetSize (400, 124 + FDRGRP_NUM_ROWS * FDRGRP_ROW_H);
	f:SetPoint ("CENTER", parent, "CENTER", 0, 30);
	f:SetFrameStrata ("DIALOG");
	Fdr_StyleDialog (f);
	f:EnableMouse (true);
	f:Hide();

	f.itemname = f:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	f.itemname:SetPoint ("TOP", 0, -18);
	f.itemname:SetWidth (350);

	f.sub = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	f.sub:SetPoint ("TOP", 0, -33);

	-- header fontstrings for every column the layout may use; positions,
	-- widths and labels are assigned per group by FdrGrp_ApplyLayout
	local CELLKEYS = { "qty", "lvl", "dps", "stat1", "stat2", "buyout", "peritem" };
	f.heads = {};
	local hi;
	for hi = 1, #CELLKEYS do
		local fs = f:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
		fs:SetHeight (12);
		f.heads[CELLKEYS[hi]] = fs;
	end

	f.note = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	f.note:SetPoint ("BOTTOM", 0, 42);
	f.note:SetWidth (360);
	f.note:SetJustifyH ("CENTER");

	local scroll = CreateFrame ("ScrollFrame", "Atr_Finder_GroupScroll", f, "FauxScrollFrameTemplate");
	scroll:SetPoint ("TOPLEFT", 20, -64);
	scroll:SetSize (348, FDRGRP_NUM_ROWS * FDRGRP_ROW_H);
	scroll:SetScript ("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll (self, offset, FDRGRP_ROW_H, FdrGrp_Redisplay);
	end);

	gFdrGrp_Rows = {};
	local i;
	for i = 1, FDRGRP_NUM_ROWS do

		local row = CreateFrame ("Button", "Atr_Finder_GroupRow"..i, f);
		row:SetSize (348, FDRGRP_ROW_H);
		row:SetPoint ("TOPLEFT", 20, -64 - (i-1) * FDRGRP_ROW_H);
		row:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");

		row.cells = {};
		local hj;
		for hj = 1, #CELLKEYS do
			local fs = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			fs:SetHeight (FDRGRP_ROW_H);
			row.cells[CELLKEYS[hj]] = fs;
		end

		row:RegisterForClicks ("LeftButtonUp", "RightButtonUp");
		row:SetScript ("OnClick", function (self, button)
			local m = self.member;
			if (not m) then return; end
			-- same menu as a Finder row (BACKLOG item 18): every listing here is
			-- the same item, so filing it works exactly as it does out there
			if (button == "RightButton") then
				if (m.name and m.name ~= "" and type (Atr_An_ShowItemMenu) == "function") then
					Atr_An_ShowItemMenu (self, m.name, "both");
				end
				return;
			end
			Atr_Finder_CancelGroup ();
			Atr_Finder_RequestBuy (m);
		end);
		row:SetScript ("OnEnter", function (self)
			if (not self.member) then return; end
			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
			if (self.member.owner) then
				GameTooltip:AddLine (FT("Seller")..": "..self.member.owner, 0.8, 0.8, 0.8);
			end
			if (self.member.fdrGone) then
				GameTooltip:AddLine (FT("Not found on the last check - it may have sold"), 1, 0.4, 0.4);
			end
			GameTooltip:AddLine (FT("Click to go to this listing"), 0.5, 0.7, 1.0);
			GameTooltip:Show();
		end);
		row:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

		row:Hide();
		gFdrGrp_Rows[i] = row;
	end

	f.closeBtn = CreateFrame ("Button", "Atr_Finder_GroupClose", f, "UIPanelButtonTemplate");
	f.closeBtn:SetSize (86, 22);
	f.closeBtn:SetPoint ("BOTTOM", 0, 14);
	f.closeBtn:SetText (FT("Close"));
	f.closeBtn:SetScript ("OnClick", function ()
		Atr_Finder_CancelGroup ();
	end);
end

function Atr_Finder_ShowGroup (face)

	if (not face or not face.members) then return; end

	-- the verification find shares the AH query channel with the scanner
	if (gFdr_State ~= FDR_NULL) then
		Fdr_SetMessage (FT("Finish or cancel the scan first"));
		return;
	end

	Atr_Finder_CancelBuy ();
	FdrGrp_BuildFrame ();

	gFdrGrp_Mode	= "window";
	gFdrGrp_Queue	= nil;
	gFdrGrp_Face	= face;
	if (Atr_AHVariant_NewSession) then Atr_AHVariant_NewSession (); end
	gFdrGrp_Name	= face.name;
	gFdrGrp_Members	= {};
	gFdrGrp_Pruned	= 0;

	local needVerify = face.scaled and face.equippable;

	local i;
	for i = 1, #face.members do
		local m = face.members[i];
		m.fdrGone = nil;
		if (needVerify) then
			m.fdrVerified = nil;	-- always re-verify: catches sold listings
		end
		tinsert (gFdrGrp_Members, m);
	end

	table.sort (gFdrGrp_Members, function (a, b)
		local ap = (a.perItem and a.perItem > 0) and a.perItem or math.huge;
		local bp = (b.perItem and b.perItem > 0) and b.perItem or math.huge;
		if (ap ~= bp) then return ap < bp; end
		return (a.buyoutPrice or 0) < (b.buyoutPrice or 0);
	end);

	local f = Atr_Finder_GroupFrame;
	local r, g, b = GetItemQualityColor (face.quality or 1);
	f.itemname:SetText (face.name);
	f.itemname:SetTextColor (r, g, b);

	local sub = string.format (FT("%d listings"), #gFdrGrp_Members);
	if (face.equippable and face.level and face.level > 0) then
		sub = sub.."  ·  "..string.format (FT("Requires level %d"), face.level);
	end
	f.sub:SetText (sub);

	FdrGrp_ApplyLayout (face);

	local shown = #gFdrGrp_Members;
	if (shown > FDRGRP_NUM_ROWS) then shown = FDRGRP_NUM_ROWS; end
	if (shown < 1) then shown = 1; end
	f:SetHeight (124 + shown * FDRGRP_ROW_H);
	if (Atr_Finder_GroupScroll) then
		Atr_Finder_GroupScroll:SetHeight (shown * FDRGRP_ROW_H);
	end

	if (needVerify) then
		gFdrGrp_Page	= 0;
		gFdrGrp_State	= FDRGRP_QUERY;
		gFdrGrp_SentAt	= time();
		if (Atr_NewQuery) then gFdrGrp_Query = Atr_NewQuery(); end
		FdrGrp_SetNote (FT("Verifying each listing..."));
	else
		gFdrGrp_State = FDRGRP_DONE;
		FdrGrp_SetNote (FT("Go to listing..."));
	end

	f:Show();
	FdrGrp_Redisplay ();
end

-- called from the shared OnUpdate handler (throttled there)
function Atr_Finder_GroupOnUpdate ()

	if (gFdrGrp_State == FDRGRP_QUERY) then
		if (CanSendAuctionQuery()) then
			FdrGrp_SendQuery ();
		elseif (time() - gFdrGrp_SentAt > 12) then
			FdrGrp_Finish ("timeout", false);
		end
	elseif (gFdrGrp_State == FDRGRP_WAIT) then
		if (time() - gFdrGrp_SentAt > FDRGRP_TIMEOUT) then
			FdrGrp_Finish ("timeout", false);
		end
	end
end

function Atr_Finder_GroupIsFinding ()
	return gFdrGrp_State == FDRGRP_QUERY or gFdrGrp_State == FDRGRP_WAIT;
end

-- called from the shared AUCTION_ITEM_LIST_UPDATE handler
function Atr_Finder_GroupOnListUpdate ()

	if (gFdrGrp_State ~= FDRGRP_WAIT) then return; end

	if (gFdrGrp_Query and gFdrGrp_Query.CheckForDuplicatePage
			and gFdrGrp_Query:CheckForDuplicatePage (gFdrGrp_Page)) then
		gFdrGrp_State	= FDRGRP_QUERY;
		gFdrGrp_SentAt	= time();
	else
		FdrGrp_ScanPage ();
	end
end

-------------------------------------------------------------------------------
-- "Verify" button: appears when the list contains greyed (scaled, unverified)
-- rows. Runs one exact-name find per distinct name, verifying EVERY matching
-- scan record from its server tooltip - the same greyed->white behavior as
-- opening each listing, automated. Exhausted finds also prune records that
-- are no longer on the AH (sold, or double-seen during the paged scan).
-------------------------------------------------------------------------------

function FdrGrp_NextInQueue ()

	if (not gFdrGrp_Queue or #gFdrGrp_Queue == 0) then

		gFdrGrp_State	= FDRGRP_IDLE;
		gFdrGrp_Queue	= nil;
		gFdrGrp_Members	= nil;
		gFdrGrp_Mode	= "window";

		local msg = FT("Verification complete");
		if (gFdrGrp_Pruned > 0) then
			msg = msg.." · "..string.format (FT("%d stale listing(s) removed"), gFdrGrp_Pruned);
		end
		Fdr_SetMessage (msg);
		Atr_Finder_UpdateVerifyButton ();
		return;
	end

	local entry = table.remove (gFdrGrp_Queue, 1);

	gFdrGrp_Name	= entry.name;
	gFdrGrp_Members	= entry.members;
	gFdrGrp_Page	= 0;
	gFdrGrp_State	= FDRGRP_QUERY;
	gFdrGrp_SentAt	= time();
	if (Atr_NewQuery) then gFdrGrp_Query = Atr_NewQuery(); end

	Fdr_SetMessage (string.format (FT("Verifying (%d/%d): %s"),
		gFdrGrp_QTotal - #gFdrGrp_Queue, gFdrGrp_QTotal, entry.name));
end

-- does the current display contain rows that would render greyed?
local function Fdr_HasUnverifiedScaled ()

	local i;
	for i = 1, #gFdr_Display do
		local rec = gFdr_Display[i];
		if (rec.scaled and rec.equippable and not rec.trueIlvl) then
			return true;
		end
	end
	return false;
end

function Atr_Finder_UpdateVerifyButton ()

	local btn = Atr_Finder_VerifyButton;
	if (not btn) then return; end

	if (gFdrGrp_Mode == "sweep" and gFdrGrp_State ~= FDRGRP_IDLE) then
		btn:SetText (FT("Cancel"));
		btn:Show();
	elseif (Fdr_HasUnverifiedScaled ()) then
		btn:SetText (FT("Verify"));
		btn:Show();
	else
		btn:Hide();
	end
end

function Atr_Finder_StartVerify ()

	-- the button doubles as Cancel while a sweep runs
	if (gFdrGrp_Mode == "sweep" and gFdrGrp_State ~= FDRGRP_IDLE) then
		Atr_Finder_CancelGroup ();
		Fdr_SetMessage (FT("Verification cancelled"));
		return;
	end

	if (gFdr_State ~= FDR_NULL) then
		Fdr_SetMessage (FT("Finish or cancel the scan first"));
		return;
	end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	-- one queue entry per distinct name among the greyed DISPLAYED rows;
	-- its members are ALL unverified scaled scan records with that name
	-- (every variant of the name verifies off the same exact-name query)
	local wanted, order = {}, {};
	local i;
	for i = 1, #gFdr_Display do
		local rec = gFdr_Display[i];
		if (rec.scaled and rec.equippable and not rec.trueIlvl
				and rec.name and not wanted[rec.name]) then
			wanted[rec.name] = true;
			tinsert (order, rec.name);
		end
	end

	if (#order == 0) then
		Fdr_SetMessage (FT("Nothing to verify"));
		Atr_Finder_UpdateVerifyButton ();
		return;
	end

	gFdrGrp_Queue = {};
	for i = 1, #order do
		local name = order[i];
		local members = {};
		local k;
		for k = 1, #gFdr_Results do
			local r = gFdr_Results[k];
			if (r.name == name and r.scaled and not r.fdrVerified) then
				r.fdrGone = nil;
				tinsert (members, r);
			end
		end
		if (#members > 0) then
			tinsert (gFdrGrp_Queue, { name = name, members = members });
		end
	end

	gFdrGrp_Mode	= "sweep";
	gFdrGrp_Face	= nil;
	if (Atr_AHVariant_NewSession) then Atr_AHVariant_NewSession (); end
	gFdrGrp_QTotal	= #gFdrGrp_Queue;
	gFdrGrp_Pruned	= 0;

	Atr_Finder_UpdateVerifyButton ();
	FdrGrp_NextInQueue ();
end

-------------------------------------------------------------------------------
-- scan engine
-------------------------------------------------------------------------------

-- returns added, updated -- what the partial flush salvaged
function Atr_Finder_CancelSearch (showMsg)

	if (Atr_Finder_WarnFrame) then
		Atr_Finder_WarnFrame:Hide();
	end

	local wasScanning = (gFdr_State ~= FDR_NULL);
	local pAdd, pUpd = 0, 0;

	if (wasScanning) then
		gFdr_State = FDR_NULL;

		-- FINDER_TAB: a cancel used to bin everything harvested so far, which
		-- on a long sweep means throwing away minutes of scanning. Keep it,
		-- insert-only so a truncated slice can never overwrite better data.
		pAdd, pUpd = Fdr_PriceDB_Update (nil, true);

		if (showMsg) then
			if (pAdd > 0) then
				Fdr_SetMessage (string.format (FT("Search cancelled - kept %d new prices"), pAdd));
			else
				Fdr_SetMessage (FT("Search cancelled"));
			end
		end
	end

	if (Atr_Finder_SearchButton) then
		Atr_Finder_SearchButton:SetText (FT("Search"));
		Atr_Finder_SearchButton:Enable();
	end

	-- FINDER_TAB: a cancel never reaches Fdr_FinishSearch, so the driver's
	-- callback would never fire and a full scan would hang on this category.
	-- Tell it directly, and drop the hook so nothing fires later.
	gFdr_OnFinish = nil;
	if (Fdr_FS_Running and Fdr_FS_Running ()) then
		Fdr_FS_Cancel (false);
	end

	-- Same problem for the Sell tab's "Scan Prices" driver: its per-name chain
	-- rides gFdr_OnFinish, which we just cleared, so tell it to stop too.
	if (Atr_SB_ScanRunning and Atr_SB_ScanRunning ()) then
		Atr_SB_ScanCancel ();
	end

	-- And once more for Batch Post, which scans a name immediately before
	-- listing it and rides the same hook.  It no-ops unless a scan of its own
	-- is actually out, so this is safe on every cancel.
	if (Atr_BP_ScanCancelled) then
		Atr_BP_ScanCancelled ();
	end

	return pAdd, pUpd;
end

function Atr_Finder_OnTabClick (index)

	if (index ~= Atr_FindTabIndex (ATR_FINDER_TAB)) then
		Atr_Finder_CancelSearch (false);
		Atr_Finder_CancelBuy ();
		Atr_Finder_CancelGroup ();
	end
end

-- FINDER_TAB: install/clear the completion callback.  Separate from
-- StartQueueScan so a driver can clear it on cancel without starting anything.
function Atr_Finder_SetFinishHook (fn)
	gFdr_OnFinish = fn;
end


-- FINDER_TAB: start a scan from an EXPLICIT spec queue rather than from the
-- tab's widgets.  Everything downstream (paging, dup-page retry, the runaway
-- guard, Fdr_PriceDB_Update, the research ledger) is the ordinary engine --
-- this only replaces where the queue comes from, so the Full Scan dialog
-- cannot drift from the behaviour the Finder tab is tested against.
--
-- Returns false when a scan is already in flight; the caller must not assume
-- its callback will fire.
function Atr_Finder_StartQueueScan (specs, onFinish)

	if (type (specs) ~= "table" or #specs == 0) then return false; end
	if (gFdr_State ~= FDR_NULL) then return false; end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	-- no name/level/usable narrowing: a category sweep wants the whole class
	gFdr_SearchText	= "";
	gFdr_MinLevel	= nil;
	gFdr_MaxLevel	= nil;
	gFdr_UsableOnly	= nil;

	gFdr_Results		= {};
	gFdr_Display		= {};
	gFdr_Page			= 0;
	gFdr_TotalPages		= 0;
	gFdr_DupRetries		= 0;
	gFdr_SkippedPages	= 0;
	gFdr_CapHit			= false;
	gFdr_WaitTicks		= 0;
	gFdr_RetryHold		= 0;

	-- The large-scan confirmation must NOT fire during a queued run. The
	-- dialog is built as a Finder-panel child, and Atr_FullScanFrame is
	-- toplevel at DIALOG strata, so the prompt appears BEHIND it: the scan
	-- parks in FDR_PAUSED waiting for a click the user cannot make, and
	-- nothing in OnUpdate drives that state, so it waits forever.
	-- Marking each spec pre-warned reuses the existing suppression. Choosing
	-- categories and pressing the button IS the confirmation.
	local q;
	for q = 1, #specs do
		if (type (specs[q]) == "table") then specs[q].warned = true; end
	end

	gFdr_SpecQueue		= specs;
	gFdr_SpecIdx		= 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();

	gFdr_OnFinish = onFinish;

	if (Atr_NewQuery) then
		gFdr_Query = Atr_NewQuery();
	else
		gFdr_Query = nil;
	end

	if (Atr_Finder_SearchButton) then
		Atr_Finder_SearchButton:SetText (FT("Cancel"));
	end
	Fdr_SetMessage (FT("Scanning..."));
	if (Atr_Finder_Redisplay) then Atr_Finder_Redisplay (); end

	return true;
end


-- FINDER_TAB: scan the AH for ONE exact item name and feed the price DB, for
-- callers OUTSIDE the Finder tab (the Sell tab's "Scan Prices" button).
-- Identical to Atr_Finder_StartQueueScan except the server-side NAME filter is
-- KEPT instead of blanked, and the queue is a single all-class spec -- so the
-- server returns just this item's listings and the ordinary Fdr_PriceDB_Update
-- writes its lowest current buyout to gAtr_ScanDB[name].  onFinish fires with
-- (pAdd, pUpd, pSkip, pWhy) exactly as for a queued scan.  The shared event
-- frame is parented to UIParent, so this pages correctly while the user is on
-- the Sell tab.  Returns false when the engine is already busy.
function Atr_Finder_StartNameScan (name, onFinish)

	if (type (name) ~= "string" or name == "") then return false; end
	if (gFdr_State ~= FDR_NULL) then return false; end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	gFdr_SearchText	= name;			-- the ONE difference from StartQueueScan
	gFdr_MinLevel	= nil;
	gFdr_MaxLevel	= nil;
	gFdr_UsableOnly	= nil;

	gFdr_Results		= {};
	gFdr_Display		= {};
	gFdr_Page			= 0;
	gFdr_TotalPages		= 0;
	gFdr_DupRetries		= 0;
	gFdr_SkippedPages	= 0;
	gFdr_CapHit			= false;
	gFdr_WaitTicks		= 0;
	gFdr_RetryHold		= 0;

	-- one all-class spec: the server narrows by the name filter set above.
	-- warned is pre-set for the same reason StartQueueScan does it -- no
	-- confirmation dialog can be answered for a programmatic run.
	gFdr_SpecQueue		= { { class = 0, subclass = 0, autoAccept = true, label = name, warned = true } };
	gFdr_SpecIdx		= 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();

	gFdr_OnFinish = onFinish;

	if (Atr_NewQuery) then
		gFdr_Query = Atr_NewQuery();
	else
		gFdr_Query = nil;
	end

	if (Atr_Finder_SearchButton) then
		Atr_Finder_SearchButton:SetText (FT("Cancel"));
	end
	Fdr_SetMessage (FT("Scanning..."));
	if (Atr_Finder_Redisplay) then Atr_Finder_Redisplay (); end

	return true;
end


function Atr_Finder_StartSearch ()

	if (gFdr_State ~= FDR_NULL) then
		Atr_Finder_CancelSearch (true);
		return;
	end

	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	gFdr_SearchText = Atr_Finder_SearchBox:GetText() or "";

	local minlev = Atr_Finder_MinLevel:GetNumber();
	local maxlev = Atr_Finder_MaxLevel:GetNumber();

	gFdr_MinLevel	= (minlev and minlev > 0) and minlev or nil;
	gFdr_MaxLevel	= (maxlev and maxlev > 0) and maxlev or nil;
	gFdr_UsableOnly	= Atr_Finder_UsableCheck:GetChecked() and 1 or nil;

	gFdr_Results		= {};
	gFdr_Display		= {};
	gFdr_Page			= 0;
	gFdr_TotalPages		= 0;
	gFdr_DupRetries		= 0;
	gFdr_SkippedPages	= 0;
	gFdr_CapHit			= false;
	gFdr_WaitTicks		= 0;
	gFdr_RetryHold		= 0;
	gFdr_SpecQueue		= Fdr_BuildSpecQueue ();
	gFdr_SpecIdx		= 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();

	if (Atr_NewQuery) then
		gFdr_Query = Atr_NewQuery();
	else
		gFdr_Query = nil;
	end

	Atr_Finder_SearchButton:SetText (FT("Cancel"));
	Fdr_SetMessage (FT("Scanning..."));
	Atr_Finder_Redisplay ();
end

local function Fdr_SendQuery ()

	local queryString = gFdr_SearchText;

	if (zc and zc.UTF8_Truncate) then
		queryString = zc.UTF8_Truncate (queryString, 63);
	end

	local spec = gFdr_SpecQueue[gFdr_SpecIdx] or {};

	QueryAuctionItems (queryString, gFdr_MinLevel, gFdr_MaxLevel, spec.invType,
					   spec.class or 0, spec.subclass or 0,
					   gFdr_Page, gFdr_UsableOnly, nil);

	gFdr_State			= FDR_POSTQUERY;
	gFdr_QuerySentAt	= time();
end

local function Fdr_AnalyzeResults ()

	-- per-record enrichment: equippable flag, item level, stat discovery

	local statSeen	= {};	-- key -> { count, min, max }
	local eqTotal	= 0;

	local i;
	for i = 1, #gFdr_Results do

		local rec = gFdr_Results[i];

		if (rec.link) then
			rec.equippable = (IsEquippableItem and IsEquippableItem (rec.link)) and true or false;

			if (GetItemInfo) then
				local _, _, _, iLevel, reqLevel, itype, isub, _, eloc = GetItemInfo (rec.link);
				rec.ilvl		= (rec.equippable and iLevel) or 0;
				rec.baseReq		= reqLevel;
				rec.itemType	= itype;
				rec.itemSubType	= isub;
				rec.equipLoc	= eloc;
			else
				rec.ilvl = 0;
			end

			if (rec.equippable) then
				eqTotal = eqTotal + 1;
			end

			if (rec.equippable and GetItemStats) then
				for statKey, val in pairs (Fdr_GetStats (rec)) do
					if (val and val ~= 0) then
						local s = statSeen[statKey];
						if (not s) then
							s = { count = 0, min = val, max = val };
							statSeen[statKey] = s;
						end
						s.count	= s.count + 1;
						if (val < s.min) then s.min = val; end
						if (val > s.max) then s.max = val; end
					end
				end
			end
		else
			rec.equippable	= false;
			rec.ilvl		= 0;
		end
	end

	-- a "stat" that appears on EVERY item with the SAME value (like Ascension's
	-- PVE_POWER, constant across the whole AH) carries no information: sorting
	-- and filtering by it is meaningless, so keep it out of the dropdown.
	-- Ascension scales item INSTANCES server-side without changing the link:
	-- identical links can be different power levels, and every link-based API
	-- (stats, ilvl, tooltips) reports only the cached base version. The one
	-- per-instance signal in the list API is the required level, so flag a
	-- record as scaled when its level disagrees with the base item's, or when
	-- listings sharing a link disagree with each other.
	local linkLevels = {};
	for i = 1, #gFdr_Results do
		local rec = gFdr_Results[i];
		if (rec.equippable and rec.link) then
			local nl = Fdr_NormalizeLink (rec.link);
			local e  = linkLevels[nl];
			if (not e) then
				linkLevels[nl] = { min = rec.level or 0, max = rec.level or 0 };
			else
				if ((rec.level or 0) < e.min) then e.min = rec.level or 0; end
				if ((rec.level or 0) > e.max) then e.max = rec.level or 0; end
			end
		end
	end

	for i = 1, #gFdr_Results do
		local rec = gFdr_Results[i];
		if (rec.equippable and rec.link) then
			local e = linkLevels[Fdr_NormalizeLink (rec.link)];
			rec.scaled = (e and e.min ~= e.max)
					or (rec.baseReq and rec.baseReq > 0 and rec.level and rec.level > 0
						and rec.level ~= rec.baseReq)
					or false;

			if (rec.scaled) then
				gFdr_ScaledNames[rec.name] = true;
			end
		end
	end

	-- remember everything discovered, BEFORE the ubiquitousConstant filter
	-- below throws any of it away -- see Fdr_LearnStatKeys for why the raw set
	-- is the one worth persisting.
	Fdr_LearnStatKeys (statSeen);

	-- the raw key set is also what the dropdown dims against: a stat dropped by
	-- ubiquitousConstant below is still IN these results, so selecting it will
	-- not empty the list and it must not be dimmed as though it would.
	gFdr_StatSeenKeys = {};
	for key in pairs (statSeen) do
		if (key ~= FDR_DPS_KEY) then gFdr_StatSeenKeys[key] = true; end
	end

	-- ANALYSIS (BACKLOG item 8): every Finder row already carries owner, count,
	-- buyout and timeLeft, which is exactly what turnover needs -- so a watched
	-- item accumulates from ordinary searching and the tab needs no scanner of
	-- its own.  Guarded and pcall'd: an analysis error must never break a search.
	if (type (Atr_An_ObserveResults) == "function") then
		pcall (Atr_An_ObserveResults, gFdr_Results);
	end

	gFdr_StatKeys = {};
	for key, s in pairs (statSeen) do
		local ubiquitousConstant = (eqTotal >= 5 and s.count == eqTotal and s.min == s.max);
		if (not ubiquitousConstant and key ~= FDR_DPS_KEY) then
			tinsert (gFdr_StatKeys, key);
		end
	end
	table.sort (gFdr_StatKeys, function (a, b)
		return Fdr_StatDisplayName (a) < Fdr_StatDisplayName (b);
	end);

	-- if the previously selected stat no longer exists in results, keep it
	-- anyway (values just read 0) so the user's choice is stable
end

function Atr_Finder_GetStatKeys ()
	return gFdr_StatKeys;
end

local function Fdr_FinishSearch (note)

	gFdr_State = FDR_NULL;

	Atr_Finder_SearchButton:SetText (FT("Search"));
	Atr_Finder_SearchButton:Enable();

	Fdr_AnalyzeResults ();
	Atr_Finder_RebuildDisplay ();

	local n = #gFdr_Results;

	local msg;
	if (n == 0) then
		msg = FT("No auctions found");
	elseif (#gFdr_Display < n) then
		local why = (#gFdr_SelectedStats > 0) and FT("%d rows after filters") or FT("%d rows after grouping");
		msg = string.format (FT("%d auctions found"), n).." · "..string.format (why, #gFdr_Display);
	else
		msg = string.format (FT("%d auctions found"), n);
	end

	if (gFdr_CapHit) then
		local capnote = FT("page ceiling reached - results incomplete");
		note = note and (note..", "..capnote) or capnote;
	end

	local pAdd, pUpd, pSkip, pWhy = Fdr_PriceDB_Update ();
	if (pAdd + pUpd > 0) then
		msg = msg..string.format (FT("  ·  prices: %d new, %d updated"), pAdd, pUpd);
		if (pSkip > 0) then
			msg = msg..string.format (FT(", %d scaled skipped"), pSkip);
		end
	else
		local why = Fdr_PriceDB_WhyText (pWhy, pSkip);		-- nil for "empty": the row count already said it
		if (why) then
			note = note and (note..", "..why) or why;
		end
	end

	if (gFdr_SkippedPages > 0) then
		local skipnote = string.format (FT("%d pages skipped - server lag"), gFdr_SkippedPages);
		note = note and (note..", "..skipnote) or skipnote;
	end

	if (note) then
		msg = msg.."  |cffff8888("..note..")|r";
	end

	Fdr_SetMessage (msg);
	Fdr_UpdateHeaderArrows ();
	Fdr_SortAndRedisplay ();

	-- FINDER_TAB: full-scan driver hook.  Deliberately LAST, so the price
	-- feed has already consumed this category's rows and the driver is free
	-- to throw them away.
	if (gFdr_OnFinish) then
		gFdr_OnFinish (pAdd or 0, pUpd or 0, pSkip or 0, pWhy);
	end
end




-- ===========================================================================
-- FINDER_TAB: price database feed  ->  moved to AuctionatorFinderPriceDB.lua
--
-- The price-DB feed and the /atrprices inspector now live in their own file
-- (loaded right after this one).  It reaches back into the scan engine only
-- through the shared Finder surface published just below, so nothing else
-- about the feed changed.
-- ===========================================================================

-- Shared Finder surface: the handful of symbols the split-out Finder files
-- (AuctionatorFinder*.lua, loaded after this one) reach back into.  Everything
-- else in those files talks to the rest of the addon through globals as before.
addonTable.Finder = addonTable.Finder or {};
addonTable.Finder.FT          = FT;					-- ZT() localization wrapper
addonTable.Finder.MoneyString = Fdr_MoneyString;			-- copper -> gold string
addonTable.Finder.GetResults  = function () return gFdr_Results; end;	-- live raw scan records
addonTable.Finder.GetCapHit   = function () return gFdr_CapHit;  end;	-- was the scan truncated?
addonTable.Finder.Redir       = gFdr_Redir;				-- Buy<->Finder redirect table (shared by ref, never reassigned)
addonTable.Finder.GetState    = function () return gFdr_State; end;	-- live scan state-machine value
addonTable.Finder.State_NULL  = FDR_NULL;					-- the idle scan state

local function Fdr_NextSpecOrFinish ()

	if (gFdr_SpecIdx < #gFdr_SpecQueue) then

		gFdr_SpecIdx		= gFdr_SpecIdx + 1;
		gFdr_Page			= 0;
		gFdr_TotalPages		= 0;
		gFdr_DupRetries		= 0;

		if (Atr_NewQuery) then
			gFdr_Query = Atr_NewQuery();
		end

		gFdr_State			= FDR_PREQUERY;
		gFdr_QuerySentAt	= time();
	else
		Fdr_FinishSearch ();
	end
end

-- The page number alone is NOT enough of a heartbeat.  A scan can sit in
-- FDR_PREQUERY for a long time while CanSendAuctionQuery throttles us, and
-- the duplicate-page path retries without advancing either -- so the line
-- froze and a working scan was indistinguishable from a hung one.  The row
-- count and the seconds-waiting both move on their own.
local function Fdr_ScanProgressLabel ()

	local spec = gFdr_SpecQueue[gFdr_SpecIdx] or {};
	local what = (spec.label and spec.label ~= "") and spec.label or FT("auctions");

	if (gFdr_State == FDR_PAUSED) then
		-- nothing drives this state but a click, so never let it look like work
		return string.format (FT("%s: waiting for confirmation"), what);
	end

	local s = string.format (FT("Scanning %s: page %d"), what, gFdr_Page + 1)
				..((gFdr_TotalPages > 0) and (" / "..gFdr_TotalPages) or "");

	-- "listings", NOT "rows": the finish line already uses "rows after
	-- grouping" to mean GROUPED rows, and these are the raw pre-grouping
	-- records. Two different numbers deserve two different words.
	s = s..string.format ("  \194\183 %d "..FT("listings"), #gFdr_Results);

	if (gFdr_DupRetries > 0) then
		s = s..string.format ("  |cffffcc00"..FT("retry %d").."|r", gFdr_DupRetries);
	end

	-- a skipped page is 50 listings lost for good; do not hide that until the
	-- summary line at the very end
	if (gFdr_SkippedPages > 0) then
		s = s..string.format ("  |cffff6666"..FT("%d skipped").."|r", gFdr_SkippedPages);
	end

	-- Seconds are derived from the OnUpdate tick count rather than time():
	-- the label is rebuilt every frame, and an extra clock read per frame is
	-- pointless when the tick rate is already a fixed 0.25s.
	local waited = math.floor (gFdr_WaitTicks * 0.25);
	if (waited >= 1) then
		s = s..string.format ("  |cff888888(%ds)|r", waited);
	end

	if (#gFdr_SpecQueue > 1) then
		s = s.."  ("..gFdr_SpecIdx.."/"..#gFdr_SpecQueue..")";
	end

	return s;
end

local function Fdr_HarvestPage ()

	local numBatchAuctions, totalAuctions = GetNumAuctionItems ("list");

	if (gFdr_Page == 0) then
		gFdr_TotalPages = math.ceil ((totalAuctions or 0) / 50);

		local spec = gFdr_SpecQueue[gFdr_SpecIdx];
		if (spec and not spec.warned and gFdr_TotalPages > FDR_WARN_PAGES
				and not Fdr_IgnoreWarn() and Atr_Finder_WarnFrame) then
			spec.warned	= true;
			gFdr_State	= FDR_PAUSED;
			Atr_Finder_ShowLargeWarn (gFdr_TotalPages, totalAuctions or 0, spec.label);
			return;
		end
	end

	local x;
	for x = 1, numBatchAuctions do

		local name, texture, count, quality, canUse, level, minBid, minIncrement,
			  buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo ("list", x);

		if (name) then
			local rec = {};

			rec.name		= name;
			rec.texture		= texture;
			rec.count		= count or 1;
			rec.quality		= quality or 1;
			rec.level		= level or 0;
			rec.minBid		= minBid;
			rec.minIncrement = minIncrement;
			rec.bidAmount	= bidAmount;
			rec.buyoutPrice	= buyoutPrice;
			rec.owner		= owner;
			rec.link		= GetAuctionItemLink ("list", x);
			rec.timeLeft	= GetAuctionItemTimeLeft ("list", x);
			rec.page		= gFdr_Page;

			local spec		= gFdr_SpecQueue[gFdr_SpecIdx];
			rec.autoAccept	= spec and spec.autoAccept or false;

			tinsert (gFdr_Results, rec);
		end
	end

	if (numBatchAuctions < 50) then
		Fdr_NextSpecOrFinish ();
		return;
	end

	if (gFdr_Page + 1 >= Fdr_PageCeiling ()) then
		gFdr_CapHit = true;
		Fdr_NextSpecOrFinish ();
		return;
	end

	gFdr_Page			= gFdr_Page + 1;
	gFdr_State			= FDR_PREQUERY;
	gFdr_QuerySentAt	= time();
	gFdr_WaitTicks		= 0;					-- real progress: restart the heartbeat

	Fdr_SetMessage (Fdr_ScanProgressLabel ());
end

-------------------------------------------------------------------------------
-- Buy-tab mitigation: Auctionator's name-keyed tooltips can only show one
-- cached version of a scaled item, so append a warning whenever any tooltip
-- at the AH shows an item the Finder has seen with multiple scaled versions.
-------------------------------------------------------------------------------

if (hooksecurefunc and GameTooltip and GameTooltip.SetHyperlink) then

	hooksecurefunc (GameTooltip, "SetHyperlink", function (self, link)

		if (not AuctionFrame or not AuctionFrame:IsShown()) then return; end
		if (not link) then return; end

		-- our own rows already carry a richer warning
		local owner = self.GetOwner and self:GetOwner();
		local oname = owner and owner.GetName and owner:GetName();
		if (oname and oname:find ("^Atr_Finder_Row")) then return; end

		local name = link:match ("%[(.-)%]");
		if (not name and GetItemInfo) then name = GetItemInfo (link); end

		if (name and gFdr_ScaledNames and gFdr_ScaledNames[name]) then
			self:AddLine (" ");
			self:AddLine (FT("Scaled item: multiple versions of this item exist!"), 1, 0.55, 0.1);
			self:AddLine (FT("This tooltip may show a different version. The Finder tab and Browse show each listing's true required level."), 1, 0.8, 0.5, true);
			self:Show ();
		end
	end);
end

-------------------------------------------------------------------------------
-- event / update handlers
-------------------------------------------------------------------------------

local gFdr_EventFrame = CreateFrame ("Frame", "Atr_Finder_EventFrame", UIParent);

gFdr_EventFrame:RegisterEvent ("AUCTION_ITEM_LIST_UPDATE");
gFdr_EventFrame:RegisterEvent ("AUCTION_HOUSE_CLOSED");

gFdr_EventFrame:SetScript ("OnEvent", function (self, event, ...)

	if (event == "AUCTION_HOUSE_CLOSED") then
		Atr_Finder_CancelSearch (false);
		Atr_Finder_CancelBuy ();
		Atr_Finder_CancelGroup ();
		return;
	end

	if (gFdrBuy_State == FDRBUY_CONFIRM or gFdrBuy_State == FDRBUY_FINAL) then
		-- the loaded page shifted under us (server-side change); re-verify
		if (gFdrBuy_Rec and gFdrBuy_FoundIndex
				and not FdrBuy_Matches (gFdrBuy_FoundIndex, gFdrBuy_Rec)) then
			FdrBuy_Fail (FT("Listing changed - please try again"));
		end
		return;
	end

	if (gFdrBuy_State == FDRBUY_WAIT) then
		if (gFdrBuy_Query and gFdrBuy_Query.CheckForDuplicatePage
				and gFdrBuy_Query:CheckForDuplicatePage (gFdrBuy_Page)) then
			gFdrBuy_State	= FDRBUY_QUERY;
			gFdrBuy_SentAt	= time();
		else
			FdrBuy_ScanPage ();
		end
		return;
	end

	if (Atr_Finder_GroupIsFinding ()) then
		Atr_Finder_GroupOnListUpdate ();
		return;
	end

	if (gFdr_State ~= FDR_POSTQUERY) then
		return;
	end

	if (gFdr_Query and gFdr_Query.CheckForDuplicatePage) then

		if (gFdr_Query:CheckForDuplicatePage (gFdr_Page)) then

			gFdr_DupRetries = gFdr_DupRetries + 1;

			if (gFdr_DupRetries <= 4) then
				gFdr_State			= FDR_PREQUERY;
				gFdr_QuerySentAt	= time();

				-- BACK OFF between retries. A "duplicate" page is usually just
				-- the server not having delivered the new one yet, and retrying
				-- on the very next 0.25s tick burned all four attempts inside a
				-- SECOND -- then skipped the page and lost 50 listings for good.
				-- Doubling the wait (0.25 / 0.5 / 1 / 2s) gives a loaded server
				-- ~3.75s to catch up, which turns skips into successes. Costs
				-- nothing when pages arrive promptly: the hold is only ever set
				-- after a duplicate is actually seen.
				gFdr_RetryHold = 2 ^ (gFdr_DupRetries - 1);
			else
				gFdr_DupRetries		= 0;
				gFdr_RetryHold		= 0;
				gFdr_SkippedPages	= gFdr_SkippedPages + 1;
				gFdr_Page			= gFdr_Page + 1;

				if (gFdr_Page >= Fdr_PageCeiling ()) then
					gFdr_CapHit = true;
					Fdr_NextSpecOrFinish ();
				else
					gFdr_State			= FDR_PREQUERY;
					gFdr_QuerySentAt	= time();
				end
			end

			return;
		end
	end

	gFdr_DupRetries = 0;
	gFdr_RetryHold	= 0;					-- page arrived: drop any backoff

	Fdr_HarvestPage ();
end);

gFdr_EventFrame:SetScript ("OnUpdate", function (self, elapsed)

	if (Atr_Finder_GroupIsFinding ()) then
		gFdr_Elapsed = gFdr_Elapsed + elapsed;
		if (gFdr_Elapsed < 0.25) then return; end
		gFdr_Elapsed = 0;
		Atr_Finder_GroupOnUpdate ();
		return;
	end

	if (gFdrBuy_State ~= FDRBUY_IDLE) then
		gFdr_Elapsed = gFdr_Elapsed + elapsed;
		if (gFdr_Elapsed < 0.25) then return; end
		gFdr_Elapsed = 0;

		if (gFdrBuy_State == FDRBUY_QUERY) then
			if (CanSendAuctionQuery()) then
				FdrBuy_SendQuery ();
			elseif (time() - gFdrBuy_SentAt > 12) then
				FdrBuy_Fail (FT("Auction house timed out"));
			end
		elseif (gFdrBuy_State == FDRBUY_WAIT) then
			if (time() - gFdrBuy_SentAt > FDRBUY_TIMEOUT) then
				FdrBuy_Fail (FT("Auction house timed out"));
			end
		end
		-- FDRBUY_CONFIRM: no timeout; the user is deciding
		return;
	end

	if (gFdr_State == FDR_NULL) then
		return;
	end

	gFdr_Elapsed = gFdr_Elapsed + elapsed;
	if (gFdr_Elapsed < 0.25) then
		return;
	end
	gFdr_Elapsed = 0;

	-- FINDER_TAB: refresh the status EVERY tick while a scan is live. Waiting
	-- on the throttle is the longest part of a big sweep and used to show
	-- nothing at all.
	gFdr_WaitTicks = gFdr_WaitTicks + 1;
	Fdr_SetMessage (Fdr_ScanProgressLabel ());

	if (gFdr_State == FDR_PREQUERY) then

		if (gFdr_RetryHold > 0) then
			gFdr_RetryHold = gFdr_RetryHold - 1;		-- serving out the backoff
		elseif (CanSendAuctionQuery()) then
			Fdr_SendQuery ();
		elseif (time() - gFdr_QuerySentAt > 15) then
			Fdr_FinishSearch (FT("auction house timed out"));
		end

	elseif (gFdr_State == FDR_POSTQUERY) then

		if (time() - gFdr_QuerySentAt > FDR_QUERY_TIMEOUT) then
			Fdr_FinishSearch (FT("auction house timed out"));
		end
	end
end);

-------------------------------------------------------------------------------
-- results display
-------------------------------------------------------------------------------

function Atr_Finder_Redisplay ()

	local numResults = #gFdr_Display;

	FauxScrollFrame_Update (Atr_Finder_ScrollFrame, numResults, FDR_NUM_ROWS, FDR_ROW_HEIGHT);

	local offset = FauxScrollFrame_GetOffset (Atr_Finder_ScrollFrame);

	local i;
	for i = 1, FDR_NUM_ROWS do

		local row = gFdr_Rows[i];
		local idx = offset + i;

		if (idx <= numResults) then

			local rec = gFdr_Display[idx];

			row.rec = rec;

			row.icon:SetTexture (rec.texture);

			local r, g, b = GetItemQualityColor (rec.quality or 1);

			local nametext = rec.name;
			if (rec.numListings and rec.numListings > 1) then
				nametext = nametext.." |cffaaaaaa x"..rec.numListings.."|r";
			end
			row.cells.name:SetText (nametext);
			row.cells.name:SetTextColor (r, g, b);

			local ilvlShown = rec.trueIlvl or rec.ilvl;
			row.cells.ilvl:SetText ((rec.equippable and ilvlShown and ilvlShown > 0) and ilvlShown or "");
			local dim = (rec.scaled and not rec.trueIlvl) and 0.55 or 1;
			row.cells.ilvl:SetTextColor (dim, dim, dim);
			row.cells.level:SetText ((rec.level and rec.level > 1) and rec.level or "");
			if (rec.scaled) then
				row.cells.level:SetTextColor (1, 0.55, 0.1);
			else
				row.cells.level:SetTextColor (1, 1, 1);
			end
			row.cells.qty:SetText ((rec.count and rec.count > 1) and rec.count or "");
			row.cells.timeleft:SetText (gFdr_TimeLeftText[rec.timeLeft or 0] or "");

			if (gFdr_HasDPS) then
				local v = rec.trueDPS or Fdr_GetStat (rec, FDR_DPS_KEY);
				local vt = "";
				if (v and v ~= 0) then
					vt = (v % 1 == 0) and tostring (v) or string.format ("%.1f", v);
				end
				row.cells.dps:SetText (vt);
				local ddim = (rec.scaled and not rec.trueDPS) and 0.55 or 1;
				row.cells.dps:SetTextColor (ddim, ddim, ddim);
			end

			local si;
			for si = 1, Fdr_NumStatCols() do
				local skey = gFdr_SelectedStats[si];
				local v = Fdr_GetStat (rec, skey);
				local vtext = "";
				if (v and v ~= 0) then
					vtext = (v % 1 == 0) and tostring (v) or string.format ("%.1f", v);
				end
				row.cells["stat"..si]:SetText (vtext);

				-- per CELL, not per row: verifying a listing does not
				-- necessarily pin every stat (ratings are prose and are not
				-- parsed), and a cached number rendered at full brightness
				-- reads as confirmed when it is not
				local sdim = (rec.scaled and not (rec.trueStats and rec.trueStats[skey]))
					and 0.55 or 1;
				row.cells["stat"..si]:SetTextColor (sdim, sdim, sdim);
			end

			row.cells.buyout:SetText (Fdr_MoneyString (rec.buyoutPrice));

			if (rec.perItem and rec.perItem > 0 and rec.count and rec.count > 1) then
				row.cells.peritem:SetText (Fdr_MoneyString (rec.perItem));
			else
				row.cells.peritem:SetText ("");
			end

			row:Show();
		else
			row.rec = nil;
			row:Hide();
		end
	end

	if (Atr_Finder_UpdateVerifyButton) then Atr_Finder_UpdateVerifyButton (); end
end

-------------------------------------------------------------------------------
-- row interaction
-------------------------------------------------------------------------------

function Atr_Finder_RequestBuy (rec)

	if (not rec) then return; end

	if (gFdr_State ~= FDR_NULL) then
		Fdr_SetMessage (FT("Finish or cancel the scan first"));
		return;
	end

	if (not Atr_Finder_BuyFrame) then return; end

	Atr_Finder_CancelGroup ();

	gFdrBuy_Rec			= rec;
	gFdrBuy_FoundIndex	= nil;

	local r, g, b = GetItemQualityColor (rec.quality or 1);
	Atr_Finder_BuyFrame.itemname:SetText (rec.name);
	Atr_Finder_BuyFrame.itemname:SetTextColor (r, g, b);

	local details = string.format (FT("Requires level %d"), rec.level or 0);
	if (rec.count and rec.count > 1 and rec.numListings and rec.numListings > 1) then
		details = details.."  ·  "..string.format (FT("%d listings at this price"), rec.numListings);
	end
	if (rec.scaled) then
		details = details.."\n|cffff8800"..FT("Scaled item: matched by required level, so you get exactly this version.").."|r";
	end
	Atr_Finder_BuyFrame.details:SetText (details);
	Atr_Finder_BuyFrame.price:SetText ("");

	Atr_Finder_BuyFrame.buyBtn:SetText (FT("Finding..."));
	Atr_Finder_BuyFrame.buyBtn:Disable();
	if (Atr_Finder_BuyFrame.bidBtn) then Atr_Finder_BuyFrame.bidBtn:Disable(); end

	FdrBuy_HidePreview ();
	Atr_Finder_BuyFrame:SetHeight (150);
	Atr_Finder_BuyFrame:Show();

	-- start the find immediately: the row click IS the first click
	Atr_Finder_ExecuteBuy ();
end

-- ---------------------------------------------------------------------------
-- FINDER_TAB: non-gear rows hand off to the Buy tab
--
-- Everything this tab adds -- the ilvl/DPS/stat columns, the group listings
-- window, the instance-exact buy engine -- exists because Ascension scales
-- EQUIPMENT per instance and the item link says nothing about it (see
-- ASCENSION-CLIENT-NOTES).  A stack of Saronite Bars has none of that
-- problem: what matters there is the per-unit price across every stack on
-- the AH, which is precisely what the Buy tab shows.  So a click on a
-- non-gear row goes there instead of opening a dialog built for scaled gear.
--
-- Both functions are globals, per the namespace rule in
-- FINDER-ARCHITECTURE.md: this is click-time code, not the per-record path,
-- and being global makes the routing decision drivable from a harness.
-- ---------------------------------------------------------------------------

-- THE routing predicate, shared by both directions: this tab sends non-gear
-- to the Buy tab, and the Buy tab sends gear back here.  If those two ever
-- disagreed about one item the user would be bounced between the tabs, so
-- there is deliberately only one function that decides.
--
-- Decided by item CLASS, not by IsEquippableItem: bags, quivers and ammo are
-- all equippable and are all commodities.  sType is GetItemInfo's localized
-- class string and GetAuctionItemClasses returns those same strings -- the
-- comparison Fdr_PassesCategoryFilter already relies on.
--
-- Returns true / false / **nil**, and nil is load-bearing: it means "no class
-- to test", which is not the same as "not gear".  Each caller resolves it
-- toward leaving the user where they already are.
function Fdr_IsGearClassName (sType)

	if (sType == nil or GetAuctionItemClasses == nil) then return nil; end

	-- Weapon is class 1 and Armor class 2 (stable in 3.3.5; the same
	-- assumption FDR_ARMOR_CLASS and FS_WEAPON_CLASS already make).
	-- Assigning to two locals truncates the multi-return, so this costs
	-- no table allocation in what is a mouse-over hot path.
	local weapon, armor = GetAuctionItemClasses();

	-- An empty return means the AH has not finished opening.  Nothing is
	-- cached, so the next call simply asks again (the trap Fdr_InvTypeMap
	-- documents).
	if (not weapon and not armor) then return nil; end

	return (sType == weapon or sType == armor);
end


-- True for Weapon and Armor rows; only those keep the Finder's own dialog.
function Fdr_IsGearRec (rec)

	if (rec == nil) then return false; end

	local gear = Fdr_IsGearClassName (rec.itemType);
	if (gear ~= nil) then return gear; end

	-- GetItemInfo returns nil for an item this client has never cached, which
	-- on this realm is most custom IDs (see ASCENSION-CLIENT-NOTES).  With no
	-- class to test, fall back to the equippable flag and keep the existing
	-- dialog: a wrong handoff throws the user's results away, whereas a wrong
	-- dialog still buys the item.
	return rec.equippable and true or false;
end

-- Hands a row to Auctionator's Buy tab.  Mirrors Atr_Bz_JumpToBuy: select the
-- pane FIRST (the search box belongs to the shared main panel and is hidden
-- until the Buy tab is up), then QUOTE the name so Auctionator matches it
-- exactly rather than as a substring -- unquoted, "Copper Bar" also drags in
-- every longer name that contains it.
--
-- Returns false when there is no Buy tab to hand to, so the caller can fall
-- back to the Finder's own dialog instead of swallowing the click.
function Atr_Finder_JumpToBuy (rec)

	if (rec == nil or rec.name == nil or rec.name == "") then return false; end

	if (Atr_SelectPane == nil or Atr_Search_Box == nil or Atr_Search_Onclick == nil) then
		return false;
	end

	-- leaving the tab cancels both anyway (Atr_Finder_OnTabClick); doing it
	-- first means no half-open dialog can outlive the jump
	Atr_Finder_CancelBuy ();
	Atr_Finder_CancelGroup ();

	-- raise the flag BEFORE switching: Atr_SelectPane runs
	-- Atr_AuctionFrameTab_OnClick synchronously, and the post-hook that shows
	-- "Back to Finder" reads this on the way through
	gFdr_JumpPending = true;

	Atr_SelectPane (ATR_BUY_TAB or 3);

	Atr_Search_Box:SetText ('"'..rec.name..'"');
	Atr_Search_Onclick ();

	return true;
end

-- ===========================================================================
-- FINDER_TAB: gear on the Buy tab comes back here -> AuctionatorFinderBuyRedirect.lua
--
-- The Buy-tab -> Finder redirect (the hooks that wrap Atr_Search_Onclick,
-- Atr_OnSearchComplete and Atr_EntryOnClick) now lives in its own file, loaded
-- after this one. It shares the redirect table (addonTable.Finder.Redir) and
-- reads the live scan state through addonTable.Finder.GetState/State_NULL,
-- both published above.
-- ===========================================================================

local function Fdr_Row_OnEnter (self)

	if (self.rec and self.rec.link) then

		-- with Dress active the dressing room sits to the right, so park the
		-- tooltip mid-panel instead of covering the preview
		if (AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.dressHover
				and Atr_Finder_Panel) then
			GameTooltip:SetOwner (self, "ANCHOR_NONE");
			GameTooltip:ClearAllPoints ();
			GameTooltip:SetPoint ("TOPLEFT", Atr_Finder_Panel, "TOP", -70, -110);
		else
			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
		end

		-- C: tell the hints module which instance this row really is, so its
		-- vendor lookup is keyed on this listing rather than on whichever
		-- variant the client cached.  Set for exactly one SetHyperlink call
		-- and cleared the instant it returns: every other tooltip in the
		-- game, including the Compare tooltips raised below, must keep
		-- reading their own values.
		Atr_Finder_TipItemLines = nil;
		Atr_Finder_TipOverride  = self.rec.scaled
			and { il = self.rec.trueIlvl, rq = self.rec.level } or nil;

		GameTooltip:SetHyperlink (self.rec.link);

		Atr_Finder_TipOverride = nil;

		-- A: replay the server's own text for this exact listing over the
		-- cached body.  Silently does nothing when the row was never verified
		-- (no trueLines) or when the hints module is absent (no boundary),
		-- which leaves the previous behaviour plus the warning below.
		if (self.rec.trueLines) then
			Fdr_ApplyTrueLines (GameTooltip, self.rec.trueLines, Atr_Finder_TipItemLines);
		end
		Atr_Finder_TipItemLines = nil;

		if (self.rec.numListings and self.rec.numListings > 1) then
			GameTooltip:AddLine (string.format (FT("%d listings, %d total"), self.rec.numListings, self.rec.count or 0), 0.8, 0.8, 0.8);
		elseif (self.rec.owner) then
			GameTooltip:AddLine (FT("Seller")..": "..self.rec.owner, 0.8, 0.8, 0.8);
		end
		if (self.rec.scaled) then
			GameTooltip:AddLine (" ");
			GameTooltip:AddLine (FT("Scaled item!"), 1, 0.55, 0.1);
			GameTooltip:AddLine (string.format (FT("This listing actually requires level %d; the dimmed stats above may show a different version."), self.rec.level or 0), 1, 0.8, 0.5, true);
		end
		-- the click must not be a surprise: say where it goes
		if (not Fdr_IsGearRec (self.rec)) then
			GameTooltip:AddLine (FT("Click to open this item on the Buy tab"), 0.5, 0.7, 1.0);
		elseif (self.rec.members and (self.rec.numListings or 1) > 1) then
			GameTooltip:AddLine (FT("Click to view each listing"), 0.5, 0.7, 1.0);
		else
			GameTooltip:AddLine (FT("Click to buy this exact listing"), 0.5, 0.7, 1.0);
		end
		GameTooltip:AddLine (FT("Shift: link   Ctrl: dressing room   Right-click: watch or shop"), 0.6, 0.6, 0.6);
		GameTooltip:Show();

		if (AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.autoCompare
				and self.rec.equippable and GameTooltip_ShowCompareItem) then
			GameTooltip_ShowCompareItem (GameTooltip);
		end

		if (AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.dressHover
				and self.rec.equippable and self.rec.link and DressUpItemLink) then
			DressUpItemLink (self.rec.link);
		end
	end
end

local function Fdr_Row_OnLeave ()

	GameTooltip:Hide();
	if (ShoppingTooltip1) then ShoppingTooltip1:Hide(); end
	if (ShoppingTooltip2) then ShoppingTooltip2:Hide(); end
end

local function Fdr_Row_OnClick (self, button)

	if (not self.rec) then
		return;
	end

	-- RIGHT-CLICK: file this item somewhere (BACKLOG item 18).  The row has always
	-- registered RightButtonUp, but the handler ignored `button` entirely -- so a
	-- right-click ran the whole left-click path and could ASK TO BUY the listing.
	-- Giving the button a meaning of its own is a fix as much as a feature.
	--
	-- The menu is the Analysis tab's (it owns the groups) and offers the shopping
	-- list too, which is the other thing you want when you have just found
	-- something: both are "remember this", neither is "buy it now".
	if (button == "RightButton") then
		local nm = self.rec.name;
		if (nm and nm ~= "" and type (Atr_An_ShowItemMenu) == "function") then
			Atr_An_ShowItemMenu (self, nm, "both");		-- hangs off the row
		end
		return;
	end

	if (IsShiftKeyDown() and self.rec.link) then
		ChatEdit_InsertLink (self.rec.link);
		return;
	end

	if (IsControlKeyDown() and self.rec.link) then
		DressUpItemLink (self.rec.link);
		return;
	end

	-- Non-gear goes to the Buy tab.  Tested BEFORE the group-face branch on
	-- purpose: for a commodity the group window would only re-split the very
	-- stacks that the Buy tab already condenses into one per-unit view.
	if (not Fdr_IsGearRec (self.rec)) then

		-- a tab change cancels the scan, so an accidental click must not throw
		-- minutes of paging away; refuse it the way Atr_Finder_RequestBuy does
		if (gFdr_State ~= FDR_NULL) then
			Fdr_SetMessage (FT("Finish or cancel the scan first"));
			return;
		end

		if (Atr_Finder_JumpToBuy (self.rec)) then
			return;
		end
		-- no Buy tab to hand to: fall through to the Finder's own dialog
	end

	-- a multi-listing group face carries the group TOTAL as its count, so it
	-- is not a real listing's identity tuple and can never be found by the
	-- buy engine; open the group window with each real listing instead
	if (self.rec.members and (self.rec.numListings or 1) > 1) then
		Atr_Finder_ShowGroup (self.rec);
		return;
	end

	-- plain click: buy this exact listing (matched by name+stack+price+level)
	Atr_Finder_RequestBuy (self.rec);
end

-- clears every filter: categories, stats, level range, usable
function Atr_Finder_ClearFilters ()

	gFdr_SelectedStats	= {};
	gFdr_SelectedSet	= {};

	if (gFdr_SortKey:match ("^stat%d$")) then
		gFdr_SortKey = "peritem";
		gFdr_SortAsc = true;
	end

	if (Atr_Finder_SearchBox) then
		Atr_Finder_SearchBox:SetText ("");
		Atr_Finder_SearchBox:ClearFocus ();
	end
	if (Atr_Finder_MinLevel)	then Atr_Finder_MinLevel:SetText ("");	end
	if (Atr_Finder_MaxLevel)	then Atr_Finder_MaxLevel:SetText ("");	end
	if (Atr_Finder_UsableCheck)	then Atr_Finder_UsableCheck:SetChecked (nil); end
	if (Atr_Finder_ReqCheck) then
		Atr_Finder_ReqCheck:SetChecked (nil);
		if (AUCTIONATOR_FINDER_SETTINGS) then AUCTIONATOR_FINDER_SETTINGS.reqOnly = false; end
	end

	if (Fdr_StatDD_SetTextFwd) then Fdr_StatDD_SetTextFwd (); end
	Fdr_ApplyColumnLayout ();
	Fdr_UpdateHeaderArrows ();

	Atr_Finder_ToggleCategory (nil);	-- also rebuilds + redisplays + updates button
end

-------------------------------------------------------------------------------
-- category menu (Blizzard-style class/subclass tree with checkboxes)
-------------------------------------------------------------------------------

-- armor slots offered under the Armor submenu; each entry: accepted equipLoc
-- tokens (first token's global provides the localized label)
local FDR_ARMOR_SLOTS =
{
	{ "INVTYPE_HEAD" },
	{ "INVTYPE_NECK" },
	{ "INVTYPE_SHOULDER" },
	{ "INVTYPE_CLOAK" },
	{ "INVTYPE_CHEST", "INVTYPE_ROBE" },
	{ "INVTYPE_WRIST" },
	{ "INVTYPE_HAND" },
	{ "INVTYPE_WAIST" },
	{ "INVTYPE_LEGS" },
	{ "INVTYPE_FEET" },
	{ "INVTYPE_FINGER" },
	{ "INVTYPE_TRINKET" },
	{ "INVTYPE_HOLDABLE" },
};

local FDR_WEAPON_CLASS = 1;

local function Fdr_SelectionHasGear ()

	for _, leaf in ipairs (gFdr_SelectedCats) do
		if (leaf.ci == FDR_WEAPON_CLASS or leaf.ci == FDR_ARMOR_CLASS) then
			return true;
		end
	end
	return false;
end

-- When gear categories are selected: auto-fill min level (character level - 5)
-- and auto-check Usable, both server-side scan reducers. Only touches values
-- we set ourselves; manual edits and manual unchecks are respected.
local function Fdr_AutoFillMinLevel ()

	if (not Atr_Finder_MinLevel or not UnitLevel) then return; end

	local cur = Atr_Finder_MinLevel:GetText() or "";

	local hasGear = Fdr_SelectionHasGear ();

	-- Usable checkbox
	if (Atr_Finder_UsableCheck) then
		if (hasGear) then
			if (not Atr_Finder_UsableCheck:GetChecked()) then
				if (gFdr_AutoUsable) then
					gFdr_AutoUsable		= false;	-- user unchecked our auto-check
					gFdr_UsableUserOff	= true;
				elseif (not gFdr_UsableUserOff) then
					Atr_Finder_UsableCheck:SetChecked (true);
					gFdr_AutoUsable = true;
				end
			end
		else
			if (gFdr_AutoUsable and Atr_Finder_UsableCheck:GetChecked()) then
				Atr_Finder_UsableCheck:SetChecked (nil);
			end
			gFdr_AutoUsable		= false;
			gFdr_UsableUserOff	= false;
		end
	end

	-- My Lvl is deliberately NOT auto-ticked here (owner's request, 2026-08),
	-- though it used to be, on the same etiquette as Usable.  It is now purely
	-- the user's: ticked from the checkbox's own OnClick, remembered in
	-- AUCTIONATOR_FINDER_SETTINGS.reqOnly and restored at creation.  Nothing
	-- here may write reqOnly -- doing so would overwrite that saved choice with
	-- one the user did not make.

	if (hasGear) then
		if (cur == "" or (gFdr_AutoMinLvl and tonumber (cur) == gFdr_AutoMinLvl)) then
			local ul = UnitLevel ("player") or 0;
			if (ul > 1) then
				local lvl = ul - 5;
				if (lvl < 1) then lvl = 1; end
				Atr_Finder_MinLevel:SetText (lvl);
				gFdr_AutoMinLvl = lvl;
			end
		end
	else
		if (gFdr_AutoMinLvl and tonumber (cur) == gFdr_AutoMinLvl) then
			Atr_Finder_MinLevel:SetText ("");
		end
		gFdr_AutoMinLvl = nil;
	end
end

local function Fdr_UpdateCatButton ()

	if (not Atr_Finder_CatButton) then return; end

	local n = #gFdr_SelectedCats;
	if (n > 0) then
		Atr_Finder_CatButton:SetText (FT("Categories").." ("..n..")");
	else
		Atr_Finder_CatButton:SetText (FT("Categories"));
	end
end

-- global for testability; leaf = { kind="class"/"subclass"/"slot", ci, si,
-- className, label, tokens }.  key nil = clear all.
function Atr_Finder_ToggleCategory (key, leaf)

	if (key == nil) then
		gFdr_SelectedCats	= {};
		gFdr_SelectedCatSet	= {};
	elseif (gFdr_SelectedCatSet[key]) then
		gFdr_SelectedCatSet[key] = nil;
		local i;
		for i = #gFdr_SelectedCats, 1, -1 do
			if (gFdr_SelectedCats[i].key == key) then
				table.remove (gFdr_SelectedCats, i);
			end
		end
	else
		leaf.key = key;
		gFdr_SelectedCatSet[key] = true;
		tinsert (gFdr_SelectedCats, leaf);
	end

	Fdr_UpdateCatButton ();
	Fdr_AutoFillMinLevel ();

	-- re-filter what's on screen now; a fresh Search picks up the new scan scope
	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();

	if (#gFdr_Results > 0 and gFdr_State == FDR_NULL) then
		Fdr_SetMessage (string.format (FT("%d rows shown"), #gFdr_Display).."  |cff88ccff"..FT("(press Search to rescan with new categories)").."|r");
	end
end

local function Fdr_CatMenu_AddLeaf (key, label, leaf, level)

	local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
	info.text				= label;
	info.checked			= (gFdr_SelectedCatSet[key] == true);
	info.keepShownOnClick	= 1;
	info.func				= function() Atr_Finder_ToggleCategory (key, leaf); end;
	UIDropDownMenu_AddButton (info, level);
end

local function Fdr_CatMenu_Init (self, level)

	level = level or 1;

	if (not GetAuctionItemClasses) then return; end

	if (level == 1) then

		local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
		info.text			= FT("(clear all)");
		info.notCheckable	= true;
		info.func			= function() Atr_Finder_ToggleCategory (nil); CloseDropDownMenus(); end;
		UIDropDownMenu_AddButton (info, level);

		local classes = { GetAuctionItemClasses() };
		local ci;
		for ci = 1, #classes do
			info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
			info.text			= classes[ci];
			info.hasArrow		= true;
			info.notCheckable	= true;
			info.value			= ci;
			info.keepShownOnClick = 1;
			UIDropDownMenu_AddButton (info, level);
		end

	elseif (level == 2) then

		local ci		= UIDROPDOWNMENU_MENU_VALUE;
		local classes	= { GetAuctionItemClasses() };
		local className	= classes[ci] or ("class "..tostring (ci));

		Fdr_CatMenu_AddLeaf ("c"..ci, FT("All").." "..className,
			{ kind = "class", ci = ci, className = className, label = className }, level);

		local subs = GetAuctionItemSubClasses and { GetAuctionItemSubClasses (ci) } or {};
		local si;
		for si = 1, #subs do
			Fdr_CatMenu_AddLeaf ("c"..ci.."s"..si, subs[si],
				{ kind = "subclass", ci = ci, si = si, className = className, label = subs[si] }, level);
		end

		if (ci == FDR_ARMOR_CLASS) then

			local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
			info.text			= FT("Slots");
			info.isTitle		= true;
			info.notCheckable	= true;
			UIDropDownMenu_AddButton (info, level);

			local k;
			for k = 1, #FDR_ARMOR_SLOTS do
				local tokens = FDR_ARMOR_SLOTS[k];
				local tokenSet = {};
				local t;
				for t = 1, #tokens do tokenSet[tokens[t]] = true; end

				local label = _G[tokens[1]] or tokens[1];

				Fdr_CatMenu_AddLeaf ("slot:"..tokens[1], label,
					{ kind = "slot", ci = FDR_ARMOR_CLASS, tokens = tokenSet, label = label }, level);
			end
		end
	end
end

-------------------------------------------------------------------------------
-- stat dropdown
-------------------------------------------------------------------------------

local function Fdr_StatDD_SetText ()

	if (not Atr_Finder_StatDD or not UIDropDownMenu_SetText) then return; end

	local n = #gFdr_SelectedStats;

	if (n == 0) then
		UIDropDownMenu_SetText (Atr_Finder_StatDD, FT("Stats..."));
	elseif (n == 1) then
		UIDropDownMenu_SetText (Atr_Finder_StatDD, Fdr_StatDisplayName (gFdr_SelectedStats[1]));
	else
		UIDropDownMenu_SetText (Atr_Finder_StatDD, string.format (FT("Stats (%d)"), n));
	end
end

Fdr_StatDD_SetTextFwd = Fdr_StatDD_SetText;

local function Fdr_AfterStatChange ()

	-- if the current sort points at a stat column that no longer exists, reset
	local statIdx = gFdr_SortKey:match ("^stat(%d)$");
	if (statIdx and tonumber (statIdx) > Fdr_NumStatCols()) then
		gFdr_SortKey = "peritem";
		gFdr_SortAsc = true;
	end

	Fdr_StatDD_SetText ();
	Fdr_ApplyColumnLayout ();
	Fdr_UpdateHeaderArrows ();
	Atr_Finder_RebuildDisplay ();
	Fdr_SortAndRedisplay ();
end

-- global so it's testable and macro-able; toggles a stat in/out of the filter
function Atr_Finder_ToggleStat (key)

	if (key == nil) then					-- clear all
		gFdr_SelectedStats	= {};
		gFdr_SelectedSet	= {};
	elseif (gFdr_SelectedSet[key]) then
		gFdr_SelectedSet[key] = nil;
		local i;
		for i = #gFdr_SelectedStats, 1, -1 do
			if (gFdr_SelectedStats[i] == key) then
				table.remove (gFdr_SelectedStats, i);
			end
		end
	else
		gFdr_SelectedSet[key] = true;
		tinsert (gFdr_SelectedStats, key);
	end

	Fdr_AfterStatChange ();
end

local function Fdr_StatDD_Initialize ()

	local info;

	info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
	info.text			= FT("(clear all)");
	info.func			= function() Atr_Finder_ToggleStat (nil); CloseDropDownMenus(); end;
	info.notCheckable	= true;
	UIDropDownMenu_AddButton (info);

	-- Two groups, in this order: the stats present in the CURRENT results, then
	-- the rest of the remembered set (Fdr_LearnedStats).  Before a search there
	-- is only the second group, which is the whole point -- the dropdown used
	-- to be empty until a scan had run.
	local present = {};

	local i;
	for i = 1, #gFdr_StatKeys do
		local key = gFdr_StatKeys[i];
		present[key] = true;

		info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
		info.text				= Fdr_StatDisplayName (key);
		info.func				= function() Atr_Finder_ToggleStat (key); end;
		info.checked			= (gFdr_SelectedSet[key] == true);
		info.keepShownOnClick	= 1;
		UIDropDownMenu_AddButton (info);
	end

	-- Dim the remembered-but-not-in-these-results entries.  Selecting one is
	-- perfectly meaningful before a search, but once results are on screen it
	-- will empty the list: Fdr_PassesStatFilter removes any row missing a
	-- selected stat.  Dimming makes that predictable instead of surprising.
	-- With no results to compare against there is nothing to warn about, so the
	-- dimming only applies once a scan has produced stats.
	local haveResults	= (next (gFdr_StatSeenKeys) ~= nil);
	local learned		= Fdr_LearnedOnlyKeys (present);

	for i = 1, #learned do
		local key = learned[i];
		local dim = (haveResults and not gFdr_StatSeenKeys[key]);

		info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {};
		info.text				= dim and ("|cff808080"..Fdr_StatDisplayName (key).."|r")
											or Fdr_StatDisplayName (key);
		info.func				= function() Atr_Finder_ToggleStat (key); end;
		info.checked			= (gFdr_SelectedSet[key] == true);
		info.keepShownOnClick	= 1;
		UIDropDownMenu_AddButton (info);
	end
end

-------------------------------------------------------------------------------
-- UI construction
-------------------------------------------------------------------------------

local function Fdr_MakeHeader (parent, key, text, width, xoff)

	local btn = CreateFrame ("Button", "Atr_Finder_Head_"..key, parent);
	btn:SetSize (width, 19);
	btn:SetPoint ("TOPLEFT", xoff, -74);

	local label = btn:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	label:SetPoint ("LEFT", 2, 0);
	label:SetText (text);
	btn.label = label;

	local arrow = btn:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	arrow:SetPoint ("LEFT", label, "RIGHT", 3, 0);
	btn.arrow = arrow;

	local tex = btn:CreateTexture (nil, "BACKGROUND");
	tex:SetAllPoints ();
	tex:SetTexture (1, 1, 1, 0.06);

	btn:SetScript ("OnClick",	function() Fdr_HeaderClick (key); end);
	btn:SetScript ("OnEnter",	function(self) tex:SetTexture (1, 1, 1, 0.15); end);
	btn:SetScript ("OnLeave",	function(self) tex:SetTexture (1, 1, 1, 0.06); end);

	gFdr_Headers[key] = btn;

	return btn;
end

function Atr_Finder_Init ()

	if (Atr_Finder_Panel) then
		return;
	end

	local panel = CreateFrame ("Frame", "Atr_Finder_Panel", AuctionFrame);
	panel:SetSize (738, 447);
	panel:SetPoint ("TOPLEFT", 10, 0);
	panel:Hide();

	-- backdrop over the sidebar art; right edge pinned to the real frame edge
	local bg = panel:CreateTexture ("Atr_Finder_ResultsBG", "BACKGROUND");
	bg:SetTexture (0, 0, 0, 0.85);
	bg:SetPoint ("TOPLEFT", 14, -70);
	bg:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -12, 28);

	local title = panel:CreateFontString ("Atr_Finder_Title", "BACKGROUND", "GameFontNormal");
	title:SetPoint ("TOP", -10, -18);
	title:SetText ("Auctionator - "..FT("Finder"));

	-- search controls ------------------------------------------------------

	local nameLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	nameLabel:SetPoint ("TOPLEFT", 68, -38);
	nameLabel:SetText (FT("Name"));

	local searchBox = CreateFrame ("EditBox", "Atr_Finder_SearchBox", panel, "InputBoxTemplate");
	searchBox:SetSize (100, 20);
	searchBox:SetPoint ("TOPLEFT", 72, -50);
	searchBox:SetAutoFocus (false);
	searchBox:SetMaxBytes (64);
	searchBox:SetScript ("OnEnterPressed", function (self)
		self:ClearFocus();
		Atr_Finder_StartSearch();
	end);
	searchBox:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);

	local catBtn = CreateFrame ("Button", "Atr_Finder_CatButton", panel, "UIPanelButtonTemplate");
	catBtn:SetSize (92, 22);
	catBtn:SetPoint ("TOPLEFT", 178, -49);
	catBtn:SetText (FT("Categories"));

	if (UIDropDownMenu_Initialize) then
		local catDD = CreateFrame ("Frame", "Atr_Finder_CatDDMenu", panel, "UIDropDownMenuTemplate");
		catDD:Hide();
		UIDropDownMenu_Initialize (catDD, Fdr_CatMenu_Init, "MENU");
		catBtn:SetScript ("OnClick", function (self)
			ToggleDropDownMenu (1, nil, catDD, self, 0, 0);
		end);
	end

	local levLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	levLabel:SetPoint ("TOPLEFT", 276, -38);
	levLabel:SetText (FT("Level Range"));

	local minBox = CreateFrame ("EditBox", "Atr_Finder_MinLevel", panel, "InputBoxTemplate");
	minBox:SetSize (30, 20);
	minBox:SetPoint ("TOPLEFT", 280, -50);
	minBox:SetAutoFocus (false);
	minBox:SetNumeric (true);
	minBox:SetMaxLetters (3);
	minBox:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); Atr_Finder_StartSearch(); end);
	minBox:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);

	local dash = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlight");
	dash:SetPoint ("TOPLEFT", 314, -54);
	dash:SetText ("-");

	local maxBox = CreateFrame ("EditBox", "Atr_Finder_MaxLevel", panel, "InputBoxTemplate");
	maxBox:SetSize (30, 20);
	maxBox:SetPoint ("TOPLEFT", 326, -50);
	maxBox:SetAutoFocus (false);
	maxBox:SetNumeric (true);
	maxBox:SetMaxLetters (3);
	maxBox:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); Atr_Finder_StartSearch(); end);
	maxBox:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);

	local usable = CreateFrame ("CheckButton", "Atr_Finder_UsableCheck", panel, "UICheckButtonTemplate");
	usable:SetSize (24, 24);
	usable:SetPoint ("TOPLEFT", 356, -48);
	_G["Atr_Finder_UsableCheckText"]:SetText (FT("Usable"));

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};

	local reqchk = CreateFrame ("CheckButton", "Atr_Finder_ReqCheck", panel, "UICheckButtonTemplate");
	reqchk:SetSize (24, 24);
	reqchk:SetPoint ("TOPLEFT", 424, -48);
	reqchk:SetChecked (AUCTIONATOR_FINDER_SETTINGS.reqOnly and true or nil);
	_G["Atr_Finder_ReqCheckText"]:SetText (FT("My Lvl"));
	reqchk:SetScript ("OnClick", function (self)
		AUCTIONATOR_FINDER_SETTINGS.reqOnly = self:GetChecked() and true or false;
		Atr_Finder_RebuildDisplay ();
		Atr_Finder_Redisplay ();
	end);
	reqchk:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("My level only"), 1, 1, 1);
		GameTooltip:AddLine (FT("Hide items whose required level (Lvl column) is above your character's level. On Ascension, the Usable filter does not do this."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	reqchk:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	local searchBtn = CreateFrame ("Button", "Atr_Finder_SearchButton", panel, "UIPanelButtonTemplate");
	searchBtn:SetSize (70, 22);
	searchBtn:SetPoint ("TOPRIGHT", AuctionFrame, "TOPRIGHT", -18, -49);
	searchBtn:SetText (FT("Search"));
	searchBtn:SetScript ("OnClick", Atr_Finder_StartSearch);

	local group = CreateFrame ("CheckButton", "Atr_Finder_GroupCheck", panel, "UICheckButtonTemplate");
	group:SetSize (24, 24);
	group:SetPoint ("TOPLEFT", 494, -48);
	group:SetChecked (true);
	_G["Atr_Finder_GroupCheckText"]:SetText (FT("Group"));
	group:SetScript ("OnClick", function ()
		Atr_Finder_RebuildDisplay ();
		Fdr_SortAndRedisplay ();
	end);

	-- "Hide known" sits in the HEADER BAND, directly above Group.  The control
	-- row itself is full -- search box, Categories, the level range, three
	-- checkboxes and the stat dropdown leave no 24px gap anywhere -- and the band
	-- above it holds only the centred title, which ends well left of here.
	--
	-- Anchored to Group rather than placed by absolute offset, so it stays put if
	-- that row is ever re-laid-out.  Terse label like its neighbours; the tooltip
	-- carries the detail.
	local known = CreateFrame ("CheckButton", "Atr_Finder_HideKnownCheck", panel, "UICheckButtonTemplate");
	known:SetSize (24, 24);
	known:SetPoint ("BOTTOMLEFT", group, "TOPLEFT", 0, 2);
	known:SetChecked ((type (Fdr_HideKnownRecipes_Enabled) == "function")
					  and Fdr_HideKnownRecipes_Enabled () and true or nil);
	_G["Atr_Finder_HideKnownCheckText"]:SetText (FT("Hide known"));
	known:SetScript ("OnClick", function (self)
		Atr_Finder_SetHideKnownRecipes (self:GetChecked());
		Atr_Finder_RebuildDisplay ();
		Atr_Finder_Redisplay ();
	end);
	known:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Hide known recipes"), 1, 1, 1);
		GameTooltip:AddLine (FT("Removes recipe listings this character has already learned. Read from the recipe's own tooltip, so it costs nothing until a search returns recipes. Knowing is per character; the setting is shared."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	known:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- stat dropdown (only if the client has the dropdown library loaded)
	if (UIDropDownMenu_Initialize) then
		local dd = CreateFrame ("Frame", "Atr_Finder_StatDD", panel, "UIDropDownMenuTemplate");
		dd:SetPoint ("TOPLEFT", 556, -44);
		UIDropDownMenu_SetWidth (dd, 80);
		UIDropDownMenu_Initialize (dd, Fdr_StatDD_Initialize);
		Fdr_StatDD_SetText ();
	end

	local clearBtn = CreateFrame ("Button", "Atr_Finder_ClearButton", panel, "UIPanelButtonTemplate");
	clearBtn:SetSize (56, 22);
	clearBtn:SetPoint ("RIGHT", Atr_Finder_SearchButton, "LEFT", -6, 0);
	clearBtn:SetText (FT("Clear"));
	clearBtn:SetScript ("OnClick", Atr_Finder_ClearFilters);

	-- persisted settings (AUCTIONATOR_FINDER_SETTINGS in the addon's SavedVariables)
	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};

	-- toolbar toggle for the large-search warning, next to Clear
	local nowarn = CreateFrame ("CheckButton", "Atr_Finder_NoWarnCheck", panel, "UICheckButtonTemplate");
	nowarn:SetSize (20, 20);
	nowarn:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -75, 8);
	nowarn:SetChecked (AUCTIONATOR_FINDER_SETTINGS.ignoreLargeWarn and true or nil);
	_G["Atr_Finder_NoWarnCheckText"]:SetText (FT("No Warn"));
	nowarn:SetScript ("OnClick", function (self)
		Atr_Finder_SetIgnoreWarn (self:GetChecked());
	end);
	nowarn:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Large search warning"), 1, 1, 1);
		GameTooltip:AddLine (string.format (FT("When unchecked, searches larger than %d pages ask for confirmation before scanning. Check to skip the prompt."), 25), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	nowarn:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- auto compare-tooltip toggle (equivalent of holding Shift while hovering)
	local cmp = CreateFrame ("CheckButton", "Atr_Finder_CompareCheck", panel, "UICheckButtonTemplate");
	cmp:SetSize (20, 20);
	cmp:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -148, 8);
	cmp:SetChecked (AUCTIONATOR_FINDER_SETTINGS.autoCompare and true or nil);
	_G["Atr_Finder_CompareCheckText"]:SetText (FT("Compare"));
	cmp:SetScript ("OnClick", function (self)
		AUCTIONATOR_FINDER_SETTINGS.autoCompare = self:GetChecked() and true or false;
	end);
	cmp:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Auto compare"), 1, 1, 1);
		GameTooltip:AddLine (FT("Show your equipped item next to the tooltip when hovering gear, without holding Shift."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	cmp:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- Display on Character: update the dressing room while hovering rows
	local dress = CreateFrame ("CheckButton", "Atr_Finder_DressCheck", panel, "UICheckButtonTemplate");
	dress:SetSize (20, 20);
	dress:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -230, 8);
	dress:SetChecked (AUCTIONATOR_FINDER_SETTINGS.dressHover and true or nil);
	_G["Atr_Finder_DressCheckText"]:SetText (FT("Dress"));
	dress:SetScript ("OnClick", function (self)
		AUCTIONATOR_FINDER_SETTINGS.dressHover = self:GetChecked() and true or false;
	end);
	dress:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Display on Character"), 1, 1, 1);
		GameTooltip:AddLine (FT("Show hovered gear on your character in the dressing room preview (rows are click-to-buy, so this updates on hover)."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	dress:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- large-search confirmation dialog
	local warn = CreateFrame ("Frame", "Atr_Finder_WarnFrame", panel);
	warn:SetSize (340, 130);
	warn:SetPoint ("CENTER", panel, "CENTER", 0, 40);
	warn:SetFrameStrata ("DIALOG");
	Fdr_StyleDialog (warn);
	warn:EnableMouse (true);
	warn:Hide();

	warn.text = warn:CreateFontString (nil, "ARTWORK", "GameFontHighlight");
	warn.text:SetPoint ("TOP", 0, -18);
	warn.text:SetWidth (300);
	warn.text:SetJustifyH ("CENTER");

	local wIgnore = CreateFrame ("CheckButton", "Atr_Finder_WarnIgnoreCheck", warn, "UICheckButtonTemplate");
	wIgnore:SetSize (22, 22);
	wIgnore:SetPoint ("BOTTOMLEFT", 22, 40);
	_G["Atr_Finder_WarnIgnoreCheckText"]:SetText (FT("Don't warn about large searches"));
	wIgnore:SetScript ("OnClick", function (self)
		Atr_Finder_SetIgnoreWarn (self:GetChecked());
	end);

	warn.continueBtn = CreateFrame ("Button", "Atr_Finder_WarnContinue", warn, "UIPanelButtonTemplate");
	warn.continueBtn:SetSize (90, 22);
	warn.continueBtn:SetPoint ("BOTTOMLEFT", 60, 12);
	warn.continueBtn:SetText (FT("Continue"));
	warn.continueBtn:SetScript ("OnClick", function ()
		warn:Hide();
		if (gFdr_State == FDR_PAUSED) then
			Fdr_HarvestPage ();		-- resume with the page we already received
		end
	end);

	warn.cancelBtn = CreateFrame ("Button", "Atr_Finder_WarnCancel", warn, "UIPanelButtonTemplate");
	warn.cancelBtn:SetSize (90, 22);
	warn.cancelBtn:SetPoint ("BOTTOMRIGHT", -60, 12);
	warn.cancelBtn:SetText (FT("Cancel"));
	warn.cancelBtn:SetScript ("OnClick", function ()
		Atr_Finder_CancelSearch (true);
	end);

	-- direct-buy confirmation dialog
	local buyf = CreateFrame ("Frame", "Atr_Finder_BuyFrame", panel);
	buyf:SetSize (390, 150);
	buyf:SetPoint ("CENTER", panel, "CENTER", 0, 40);
	buyf:SetFrameStrata ("DIALOG");
	Fdr_StyleDialog (buyf);
	buyf:EnableMouse (true);
	buyf:Hide();

	-- hidden tooltip used to read the server's per-listing data
	CreateFrame ("GameTooltip", "Atr_FinderScanTT", UIParent, "GameTooltipTemplate");

	buyf.itemname = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	buyf.itemname:SetPoint ("TOP", 0, -18);
	buyf.itemname:SetWidth (290);

	buyf.details = buyf:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	buyf.details:SetPoint ("TOP", 0, -40);
	buyf.details:SetWidth (290);
	buyf.details:SetJustifyH ("CENTER");

	buyf.price = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	buyf.price:SetPoint ("TOP", 0, -84);

	buyf.buyBtn = CreateFrame ("Button", "Atr_Finder_BuyConfirm", buyf, "UIPanelButtonTemplate");
	buyf.buyBtn:SetSize (86, 22);
	buyf.buyBtn:SetPoint ("BOTTOMLEFT", 24, 14);
	buyf.buyBtn:SetText (FT("Buyout"));
	buyf.buyBtn:SetScript ("OnClick", function ()
		if (gFdrBuy_State == FDRBUY_CONFIRM) then
			FdrBuy_EnterFinal ("buyout");
		elseif (gFdrBuy_State == FDRBUY_FINAL) then
			FdrBuy_ConfirmPurchase ();
		end
	end);

	buyf.bidBtn = CreateFrame ("Button", "Atr_Finder_BuyBid", buyf, "UIPanelButtonTemplate");
	buyf.bidBtn:SetSize (86, 22);
	buyf.bidBtn:SetPoint ("BOTTOM", 0, 14);
	buyf.bidBtn:SetText (FT("Bid"));
	buyf.bidBtn:SetScript ("OnClick", function ()
		if (gFdrBuy_State == FDRBUY_CONFIRM) then
			FdrBuy_EnterFinal ("bid");
		end
	end);

	buyf.cancelBtn = CreateFrame ("Button", "Atr_Finder_BuyCancel", buyf, "UIPanelButtonTemplate");
	buyf.cancelBtn:SetSize (86, 22);
	buyf.cancelBtn:SetPoint ("BOTTOMRIGHT", -24, 14);
	buyf.cancelBtn:SetText (FT("Cancel"));
	buyf.cancelBtn:SetScript ("OnClick", function ()
		if (gFdrBuy_State == FDRBUY_FINAL) then
			FdrBuy_ShowConfirmView ();		-- Back to the choice step
		else
			Atr_Finder_CancelBuy ();
		end
	end);

	buyf.buyoutLabel = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	buyf.buyoutLabel:SetPoint ("BOTTOM", buyf.buyBtn, "TOP", 0, 4);

	buyf.bidLabel = buyf:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	buyf.bidLabel:SetPoint ("BOTTOM", buyf.bidBtn, "TOP", 0, 4);

	if (MoneyInputFrame_SetCopper) then
		local mi = CreateFrame ("Frame", "Atr_Finder_BidInput", buyf, "MoneyInputFrameTemplate");
		mi:SetPoint ("BOTTOM", buyf.bidBtn, "TOP", 32, 6);
		mi:Hide();
		buyf.bidInput = mi;
	end

	-- embedded preview tooltip: parented to the dialog so nothing steals it
	CreateFrame ("GameTooltip", "Atr_Finder_PreviewTT", buyf, "GameTooltipTemplate");

	function Atr_Finder_GetDisplay ()
		return gFdr_Display;
	end

	function Atr_Finder_ShowLargeWarn (pages, total, label)
		local what = (label and label ~= "") and (" "..FT("for").." "..label) or "";
		warn.text:SetText (string.format (
			FT("This search%s spans ~%d pages (~%d auctions) and may take a while.\n\nRefining categories, level range or name may be faster."),
			what, pages, total));
		wIgnore:SetChecked (Fdr_IgnoreWarn() and true or nil);
		warn:Show();
	end

	-- status message: bottom strip of the results area
	local msg = panel:CreateFontString ("Atr_Finder_Message", "ARTWORK", "GameFontNormal");
	msg:SetPoint ("TOPLEFT", 24, -398);
	msg:SetJustifyH ("LEFT");

	-- The "Prices" and "Research" toggles used to sit on this strip, at
	-- BOTTOMRIGHT -400 and -75.  They are settings, not per-search controls,
	-- so they moved to Interface > AddOns > Auctionator > Scanning - see the
	-- "scanning options rows" block at the end of this file.  Dress, Compare
	-- and No Warn each shifted one slot right so the strip still ends flush
	-- with the frame's right edge instead of leaving a hole where Research
	-- was.

	-- Verify button: only visible while greyed (scaled) rows are listed
	local verify = CreateFrame ("Button", "Atr_Finder_VerifyButton", panel, "UIPanelButtonTemplate");
	verify:SetSize (90, 22);
	verify:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -70, 32);
	verify:SetText (FT("Verify"));
	verify:Hide();
	verify:SetScript ("OnClick", Atr_Finder_StartVerify);
	verify:SetScript ("OnEnter", function (self)
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FT("Verify greyed listings"), 1, 1, 1);
		GameTooltip:AddLine (FT("Reads each greyed (scaled) listing's server tooltip to fill in its true item level and DPS, and removes listings that are no longer on the auction house."), nil, nil, nil, true);
		GameTooltip:Show();
	end);
	verify:SetScript ("OnLeave", function () GameTooltip:Hide(); end);

	-- column headers -------------------------------------------------------

	Fdr_MakeHeader (panel, "name",		FT("Item"),			280,  20);
	Fdr_MakeHeader (panel, "ilvl",		FT("iLvl"),			 40, 302);
	Fdr_MakeHeader (panel, "level",		FT("Lvl"),			 36, 346);
	Fdr_MakeHeader (panel, "qty",		FT("Qty"),			 36, 386);
	Fdr_MakeHeader (panel, "timeleft",	FT("Time"),			 42, 426);
	Fdr_MakeHeader (panel, "dps",		FT("DPS"),			 46, 418);
	Fdr_MakeHeader (panel, "stat1",		"",					 46, 418);
	Fdr_MakeHeader (panel, "stat2",		"",					 46, 418);
	Fdr_MakeHeader (panel, "stat3",		"",					 46, 418);
	Fdr_MakeHeader (panel, "buyout",	FT("Buyout"),		120, 470);
	Fdr_MakeHeader (panel, "peritem",	FT("Per Item"),		 96, 592);

	-- scroll frame + rows --------------------------------------------------

	local scroll = CreateFrame ("ScrollFrame", "Atr_Finder_ScrollFrame", panel, "FauxScrollFrameTemplate");
	scroll:SetSize (690, FDR_NUM_ROWS * FDR_ROW_HEIGHT);
	scroll:SetPoint ("TOPLEFT", 20, -94);
	scroll:SetScript ("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll (self, offset, FDR_ROW_HEIGHT, Atr_Finder_Redisplay);
	end);

	local sbar = _G["Atr_Finder_ScrollFrameScrollBar"];
	if (sbar) then
		sbar:ClearAllPoints();
		sbar:SetPoint ("TOPRIGHT",    AuctionFrame, "TOPRIGHT",    -18, -110);
		sbar:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -18,  69);
	end

	local i;
	for i = 1, FDR_NUM_ROWS do

		local row = CreateFrame ("Button", "Atr_Finder_Row"..i, panel);
		row:SetSize (690, FDR_ROW_HEIGHT);
		row:SetPoint ("TOPLEFT", 20, -94 - (i-1) * FDR_ROW_HEIGHT);

		row:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");

		row.icon = row:CreateTexture (nil, "ARTWORK");
		row.icon:SetSize (16, 16);
		row.icon:SetPoint ("LEFT", 2, 0);

		row.cells = {};

		local function cell (justify)
			local fs = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			fs:SetHeight (FDR_ROW_HEIGHT);
			fs:SetJustifyH (justify);
			return fs;
		end

		row.cells.name		= cell ("LEFT");
		row.cells.ilvl		= cell ("RIGHT");
		row.cells.level		= cell ("RIGHT");
		row.cells.qty		= cell ("RIGHT");
		row.cells.timeleft	= cell ("CENTER");
		row.cells.dps		= cell ("RIGHT");
		row.cells.stat1		= cell ("RIGHT");
		row.cells.stat2		= cell ("RIGHT");
		row.cells.stat3		= cell ("RIGHT");
		row.cells.buyout	= cell ("RIGHT");
		row.cells.peritem	= cell ("RIGHT");

		row:RegisterForClicks ("LeftButtonUp", "RightButtonUp");
		row:SetScript ("OnEnter",		Fdr_Row_OnEnter);
		row:SetScript ("OnLeave",		Fdr_Row_OnLeave);
		row:SetScript ("OnClick",		Fdr_Row_OnClick);

		row:Hide();

		gFdr_Rows[i] = row;
	end

	Fdr_ApplyColumnLayout ();
	Fdr_UpdateHeaderArrows ();
	Fdr_SetMessage (FT("Enter a search and press Search"));

	-- "Back to Finder" on the Buy tab: PRESENT only when the Buy tab was
	-- reached from a Finder row, exactly as the Bazaar's own "Back to Bazaar"
	-- behaves.  Until 2026-07 this hung off a gFdr_JumpPending flag that
	-- nothing ever set -- the jump it was written for was never built -- so
	-- the button sat on the Buy tab permanently greyed out and did nothing.
	-- Atr_Finder_JumpToBuy now raises that flag.
	if (Atr_Buy1_Button and hooksecurefunc) then

		local back = CreateFrame ("Button", "Atr_Finder_BackButton", Atr_Buy1_Button:GetParent() or AuctionFrame, "UIPanelButtonTemplate");
		back:SetSize (120, 24);
		back:SetPoint ("RIGHT", Atr_Buy1_Button, "LEFT", -45, 0);
		back:SetText (FT("Back to Finder"));
		back:Hide();
		back:SetScript ("OnClick", function ()
			Atr_SelectPane (ATR_FINDER_TAB);
		end);

		hooksecurefunc ("Atr_AuctionFrameTab_OnClick", function ()

			if (not Atr_Finder_BackButton) then return; end

			local onBuy = Atr_IsTabSelected and Atr_IsTabSelected (ATR_BUY_TAB or 3);

			if (onBuy and gFdr_JumpPending) then
				gFdr_BackEnabled = true;
			elseif (not onBuy) then
				-- left the Buy tab: the offer to go back expires with it
				gFdr_BackEnabled = false;
			end
			gFdr_JumpPending = false;

			if (onBuy and gFdr_BackEnabled) then
				Atr_Finder_BackButton:Enable();
				Atr_Finder_BackButton:Show();
			else
				Atr_Finder_BackButton:Hide();
			end

			-- The Bazaar parks its own "Back to Bazaar" to the LEFT of this
			-- button so the two cannot collide when both jumps are pending.
			-- That anchor was chosen when this button was always on screen;
			-- now that it is usually hidden it would leave a hole, so re-seat
			-- the Bazaar's button against whichever neighbour is actually
			-- visible.  Safe to read here: Atr_Bz_OnTabClick runs from the TOP
			-- of Atr_AuctionFrameTab_OnClick and this is a post-hook, so the
			-- Bazaar's own show/hide has already settled.
			if (Atr_Bz_BuyBackButton and Atr_Bz_BuyBackButton:IsShown()) then
				Atr_Bz_BuyBackButton:ClearAllPoints();
				if (Atr_Finder_BackButton:IsShown()) then
					Atr_Bz_BuyBackButton:SetPoint ("RIGHT", Atr_Finder_BackButton, "LEFT", -6, 0);
				else
					Atr_Bz_BuyBackButton:SetPoint ("RIGHT", Atr_Buy1_Button, "LEFT", -45, 0);
				end
			end
		end);
	end
end


-- ===========================================================================
-- FINDER_TAB: full scan replacement  ->  moved to AuctionatorFinderFullScan.lua
--
-- The per-category Full Scan replacement (Scan Categories button, the Fdr_FS_*
-- and Atr_*FullScan* globals) now lives in its own file, loaded after this one.
-- It exports only globals, so the guarded calls above (Fdr_FS_Running, etc.)
-- resolve at runtime exactly as before.
-- ===========================================================================


-- ===========================================================================
-- FINDER_TAB: scanning options rows  ->  moved to AuctionatorFinderOptions.lua
--
-- The Finder's rows on the Scanning options panel now live in their own file,
-- loaded after this one. It shares only the Buy<->Finder redirect table via
-- addonTable.Finder.Redir (published above).
-- ===========================================================================
