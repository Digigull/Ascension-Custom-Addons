-------------------------------------------------------------------------------
-- AuctionatorFinderPriceDB.lua
--
-- The Finder's "price database feed": ordinary Finder category scans feed
-- Auctionator's own name-keyed price/mean databases, since upstream's Full
-- Scan (getAll) is dead on Ascension.  Also hosts the /atrprices inspector.
--
-- Split out of AuctionatorFinder.lua (was the "price database feed" section).
-- It exports only globals (Fdr_PriceDB_*, the /atrprices slash command), so
-- the rest of the addon calls it exactly as before.  The only state it reads
-- back from the scan engine is shared through addonTable.Finder, published by
-- AuctionatorFinder.lua, which the .toc loads first:
--     F.MoneyString  -- Fdr_MoneyString (copper -> gold string)
--     F.GetResults() -- live gFdr_Results (raw scan records)
--     F.GetCapHit()  -- live gFdr_CapHit (was the scan truncated?)
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;		-- same idiom every Auctionator file uses
local F  = addonTable and addonTable.Finder;

-- Pulled from the shared Finder surface (see header). FT and Fdr_MoneyString
-- are stable closures, safe to capture once at load; the scan state is read
-- live through F.Get* accessors because it changes every scan.
local FT              = F and F.FT;
local Fdr_MoneyString = F and F.MoneyString;

-- ===========================================================================
-- FINDER_TAB begin: price database feed
--
-- A category sweep is long, and the user reasonably does not want to run one
-- without Auctionator's own price data benefiting.  Upstream's Full Scan is
-- dead on this server (it calls QueryAuctionItems with getAll=true, which
-- Ascension disables; its paged "slow scan" alternative was never written -
-- see VENDOR-PRICE-RESEARCH.md), so the Finder feeds the DB instead.
--
-- gAtr_ScanDB is AUCTIONATOR_PRICE_DATABASE[realm_Faction]: a flat
-- name -> lowest per-unit buyout map.  gAtr_MeanDB is the same keying with an
-- array of up to 15 sorted samples.  Both are created by Atr_InitScanDB at
-- login, so nothing needs initialising here.
--
-- FOUR RULES make this safe on a PARTIAL scan, which is the whole difference
-- from upstream's whole-AH pass:
--   1. NEVER DELETE.  Upstream prunes names below the quality floor because a
--      full scan saw everything; for us a missing name means "not scanned",
--      not "not for sale".  Insert and update only.
--   2. SKIP SCALED EQUIPMENT.  The DB is name-keyed, which CLAUDE.md flags as
--      never safe here - one price would stand in for every scaled variant.
--      Nothing of value is lost: commodities never scale.
--   3. SKIP A CAPPED SCAN.  A truncated slice yields the lowest of an
--      arbitrary subset, which is biased HIGH and would silently inflate
--      prices.  Per-category scanning should mean this never fires.
--   4. BID-ONLY ROWS CONTRIBUTE NOTHING.  buyoutPrice 0 must never enter the
--      DB as a zero price.
-- ===========================================================================

function Fdr_PriceDB_Enabled ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then return true; end
	return (AUCTIONATOR_FINDER_SETTINGS.feedPriceDB ~= false);		-- default ON
end


-- Turns the reason token from Fdr_PriceDB_Update into a status-line note.
-- Returns nil when the outcome needs no note (rows were written, or the scan
-- found nothing at all and the row count has already said so).
function Fdr_PriceDB_WhyText (why, skipped)

	if (why == nil or why == "empty") then return nil; end

	if (why == "off")		then return FT("prices not saved - Prices option is off (options > Scanning)");	end
	if (why == "cap")		then return FT("prices not saved - capped scan");				end
	if (why == "nodb")		then return FT("prices not saved - price DB not loaded");		end
	if (why == "nobuyout")	then return FT("prices not saved - no buyout rows");			end
	if (why == "quality")	then return FT("prices not saved - below the quality floor");	end
	if (why == "scaled") then
		return string.format (FT("prices not saved - all %d rows are scaled gear"), skipped or 0);
	end

	return FT("prices not saved");
end


-- returns added, updated, skippedScaled, reason
--
-- reason is nil when rows were written and a short token otherwise, so the
-- caller can always tell the user WHY nothing was saved.  Silence was the
-- real complaint here: four of these paths used to return 0,0,0 with no
-- message, which is indistinguishable from the feed never running at all.
--   "empty"    - the scan itself found nothing
--   "off"      - the Prices checkbox is unticked
--   "cap"      - rule 3: capped scan, prices would be biased high
--   "nodb"     - Atr_InitScanDB has not run (gAtr_ScanDB is not a table)
--   "scaled"   - rule 2: every candidate row was scaled equipment
--   "nobuyout" - rule 4: every row was bid-only (or a zero unit price)
--   "quality"  - everything sat below AUCTIONATOR_SCAN_MINLEVEL
-- partial=true: INSERT ONLY, never overwrite.  A half-finished scan's
-- "lowest" price is biased high (the cheap listing may be on a page we never
-- reached), so it must not be allowed to degrade a value a completed scan
-- already established -- but for a name we have NOTHING on, a possibly-high
-- price still beats no price at all.
function Fdr_PriceDB_Update (results, partial)

	results = results or F.GetResults ();
	if (type (results) ~= "table" or #results == 0) then return 0, 0, 0, "empty"; end
	if (not Fdr_PriceDB_Enabled ()) then return 0, 0, 0, "off"; end
	if (F.GetCapHit ()) then return 0, 0, 0, "cap"; end						-- rule 3
	if (type (gAtr_ScanDB) ~= "table") then return 0, 0, 0, "nodb"; end		-- Atr_InitScanDB has not run

	local lows, quals, skipped = {}, {}, 0;
	local candidates = 0;						-- distinct names that cleared rules 2 and 4

	-- FINDER_TAB: per-name listing detail for the quantity-weighted median
	-- sample.  lows alone can only feed the median the lowest price, pinning it
	-- to the Auction line; the across-listings median (Atr_WeightedMedianPrice)
	-- lets it reflect the whole book instead.
	local listings = {};

	local i;
	for i = 1, #results do

		local rec = results[i];

		if (rec and rec.name) then

			if (rec.equippable and rec.scaled) then				-- rule 2
				skipped = skipped + 1;
			else
				local cnt = tonumber (rec.count or 1) or 1;
				if (cnt < 1) then cnt = 1; end

				local bo = tonumber (rec.buyoutPrice or 0) or 0;
				if (bo > 0) then								-- rule 4
					local unit = math.floor (bo / cnt);
					if (unit > 0) then
						if (lows[rec.name] == nil) then
							lows[rec.name] = unit;
							candidates = candidates + 1;
						elseif (unit < lows[rec.name]) then
							lows[rec.name] = unit;
						end
						quals[rec.name] = rec.quality or 1;

						-- `owner` rides along for the history's sample only (item 31):
						-- it is what lets Atr_Hist_Sample drop your own listings, and
						-- the weighted median ignores the field entirely.
						if (not listings[rec.name]) then listings[rec.name] = {}; end
						tinsert (listings[rec.name], { price = unit, weight = cnt, owner = rec.owner });
					end
				end
			end
		end
	end

	local added, updated = 0, 0;
	local minq = tonumber (AUCTIONATOR_SCAN_MINLEVEL or 0) or 0;

	for name, price in pairs (lows) do

		if ((quals[name] or 0) + 1 >= minq) then				-- upstream's quality floor, same 1-based shift

			local known = (gAtr_ScanDB[name] ~= nil);

			if (partial and known) then
				price = nil;									-- keep the completed scan's value
			else
				if (known) then updated = updated + 1; else added = added + 1; end
				-- rule 1: assign, never nil out -- and through the store so this feed
				-- cannot flatten a variant table (BACKLOG item 12 part 3)
				if (type (Atr_PriceStore) == "function") then Atr_PriceStore (gAtr_ScanDB, name, price);
				else gAtr_ScanDB[name] = price; end
			end

			if (price and type (gAtr_MeanDB) == "table") then
				local medsample = price;
				if (type (Atr_WeightedMedianPrice) == "function") then
					local wm = Atr_WeightedMedianPrice (listings[name] or {});
					if (wm > 0) then medsample = wm; end
				end

				-- one call, so the one-sample shape is handled in one place (item 13)
				Atr_MeanAppend (gAtr_MeanDB, name, medsample);

				-- ... and the dated series beside it (BACKLOG item 31).  In here
				-- rather than anywhere else on purpose: the four rules above are
				-- what make a PARTIAL scan safe to store, and they matter more to a
				-- series than to a current price -- a bad current price is
				-- overwritten by the next scan, a bad sample is read back forever.
				-- Off by default, so this is one boolean.
				--
				-- It takes its OWN sample rather than reusing medsample: the series
				-- drops your own listings and rejects the junk end of the book,
				-- which the mean database deliberately does not (that would be a
				-- behaviour change to a shipped number, and it is being superseded
				-- anyway). Falls back to medsample if the cleaning left nothing.
				if (type (Atr_Hist_Note) == "function") then
					local hs, hn = Atr_Hist_Sample (listings[name]);
					if (hs) then Atr_Hist_Note (name, hs, nil, hn); end
				end
			end
		end
	end

	-- Feed changed the price DB: drop the suffix-variant estimate cache so base
	-- gear estimates (Atr_GetAHVariantEstimate) reflect the new variant prices.
	if (added + updated > 0 and Atr_AH_InvalidateVariantCache) then Atr_AH_InvalidateVariantCache (); end

	if (added + updated > 0 and time) then
		AUCTIONATOR_LAST_SCAN_TIME = time();					-- display-only; the real gate is CanSendAuctionQuery
	end

	if (added + updated > 0) then
		return added, updated, skipped, nil;
	end

	-- nothing written: say which rule swallowed the scan
	local why;
	if (candidates == 0) then
		why = (skipped > 0) and "scaled" or "nobuyout";			-- rule 2 vs rule 4
	else
		why = "quality";										-- everything below the quality floor
	end

	return added, updated, skipped, why;
end


-- /atrprices - the direct answer to "is the Finder actually feeding the
-- price database?".  Prints the feed's state and the DB's current size, so
-- the question can be settled without a scan or a /reload.
function Fdr_PriceDB_Report ()

	local function say (s)
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end

	say ("Finder price feed: "..(Fdr_PriceDB_Enabled () and "|cff40ff40ON|r" or "|cffff4040OFF|r (Auctionator options > Scanning)"));

	if (type (gAtr_ScanDB) ~= "table") then
		say ("  |cffff4040gAtr_ScanDB is not loaded|r - Auctionator's Atr_InitScanDB has not run.");
		return 0;
	end

	local names, mean = 0, 0;
	local k;
	for k in pairs (gAtr_ScanDB) do names = names + 1; end
	if (type (gAtr_MeanDB) == "table") then
		for k in pairs (gAtr_MeanDB) do mean = mean + 1; end
	end

	say (string.format ("  price DB: |cffffffff%d|r names, mean DB: |cffffffff%d|r names", names, mean));

	-- TWO CLOCKS, AND THEY ANSWER DIFFERENT QUESTIONS (BACKLOG item 4).
	--
	-- This line used to read "last write" off AUCTIONATOR_LAST_SCAN_TIME alone,
	-- which was wrong in the way that costs somebody an evening: that timestamp
	-- is set ONLY when a full scan finishes, or by the Finder's own feed. The
	-- ordinary per-item write -- every Buy and Sell search, through
	-- AtrSearch:ProcessBatch -> Atr_PriceStore -- never touches it. So a report
	-- saying "last write: 126 minutes ago" after an evening of searching was
	-- describing the last FULL SCAN and reading as "nothing has been written",
	-- which is exactly the impression item 4 was opened to chase.
	local function ago (t)
		t = tonumber (t or 0) or 0;
		if (t <= 0 or not time) then return nil; end
		local mins = math.floor ((time() - t) / 60);
		return string.format ("|cffffffff%d|r minute%s ago", mins, (mins == 1) and "" or "s");
	end

	local full = ago (AUCTIONATOR_LAST_SCAN_TIME);
	say ("  last full scan: "..(full or "|cff888888never|r"));

	local one = ago (gAtr_LastPriceWrite);
	if (one) then
		say ("  last search wrote: "..one);
	else
		-- Session-only, so "not yet" is the honest word: it does not mean no
		-- search has ever written, only that none has since this login.
		say ("  last search wrote: |cff888888not yet this session|r");
	end

	say (string.format ("  quality floor: |cffffffff%d|r  (Auctionator options; rows below it are ignored)",
					tonumber (AUCTIONATOR_SCAN_MINLEVEL or 0) or 0));
	say ("  |cff888888scaled gear is excluded by design - the DB is name-keyed and cannot tell variants apart|r");
	say ("  |cff888888/atrprices <item>|r inspect one item   |cff888888/atrprices reset <item>|r|cff888888 or |r|cff888888reset all|r recalibrate the median");

	return names;
end


-- Resolve a typed name or a shift-clicked item link to the actual key the
-- price databases are stored under: exact match first, then case-insensitive
-- across either database, so "fadeleaf" finds the "Fadeleaf" the DB is keyed
-- under.  Returns the cleaned input unchanged when nothing matches.
function Fdr_PriceDB_ResolveName (query)

	query = tostring (query or "");
	local bracket = query:match ("%[(.-)%]");			-- name inside a shift-clicked link
	local name = bracket or query:gsub ("^%s+", ""):gsub ("%s+$", "");
	if (name == "") then return ""; end

	local haveScan = (type (gAtr_ScanDB) == "table");
	local haveMean = (type (gAtr_MeanDB) == "table");

	if ((haveScan and gAtr_ScanDB[name] ~= nil)
		or (haveMean and gAtr_MeanDB[name] ~= nil)) then		-- item 13: one sample is a number, not a table
		return name;
	end

	local lq = name:lower();
	local k;
	if (haveScan) then
		for k in pairs (gAtr_ScanDB) do
			if (type (k) == "string" and k:lower() == lq) then return k; end
		end
	end
	if (haveMean) then
		for k in pairs (gAtr_MeanDB) do
			if (type (k) == "string" and k:lower() == lq) then return k; end
		end
	end
	return name;
end


-- Read-only inspector for a single item's stored price data.  Prints exactly
-- what the two name-keyed databases hold for a name so a "tooltip looks wrong"
-- report can be pinned to a cause:
--   * auction (gAtr_ScanDB)        - the single lowest per-unit buyout kept by
--                                    the last scan (no outlier rejection)
--   * median samples (gAtr_MeanDB) - the up-to-15 sample array the median is
--                                    taken from; a wide spread means the median
--                                    is mixing several market eras
--   * tooltip shows                - what Atr_GetAuctionPrice / Atr_GetMeanPrice
--                                    actually render (may differ from the raw
--                                    store via recent-sale / variant fallbacks)
-- Touches nothing; accepts a typed name or a shift-clicked item link, and
-- resolves case-insensitively to the real stored key.
function Fdr_PriceDB_Inspect (query)

	local function say (s)
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end

	if (type (gAtr_ScanDB) ~= "table") then
		say ("  |cffff4040gAtr_ScanDB is not loaded|r - Auctionator's Atr_InitScanDB has not run.");
		return;
	end

	local name = Fdr_PriceDB_ResolveName (query);

	if (name == "") then
		say ("  usage: |cffffffff/atrprices <item name>|r  (or shift-click an item into chat)");
		return;
	end

	say (string.format ("Price DB inspect: |cffffd100%s|r", name));

	local auc = (type (Atr_PriceValue) == "function") and Atr_PriceValue (gAtr_ScanDB[name]) or gAtr_ScanDB[name];
	say (string.format ("  auction (gAtr_ScanDB), name-only: %s",
			auc and Fdr_MoneyString (auc) or "|cff888888(not stored)|r"));

	-- THE VARIANT SLOTS, spelled out (BACKLOG item 4, the read half).
	--
	-- This command is invoked by NAME, so it has no link and cannot ask for a
	-- variant the way a tooltip does.  Printing only the name-only answer is how
	-- this instrument misled the first investigation: a Buy search files its
	-- price under the listing's variant key and leaves the name-level slot ("?",
	-- written by full scans only) untouched, so the two numbers can differ by a
	-- lot and the report showed just the one the search never wrote.  List every
	-- slot instead and the divergence is visible at a glance.
	local row = gAtr_ScanDB[name];
	if (type (row) == "table") then
		local parts, k, v = {}, nil, nil;
		for k, v in pairs (row) do
			if (k ~= "dflt" and type (v) == "number") then
				local label = (k == "?") and "name-level" or k;
				table.insert (parts, string.format ("|cffffffff%s|r %s", label, Fdr_MoneyString (v)));
			end
		end
		table.sort (parts);
		if (#parts > 0) then
			say (string.format ("  variant slots: |cffffffff%d|r", #parts));
			say ("    "..table.concat (parts, "|cff555555,|r "));
			say ("    |cff888888a tooltip asks by variant; this line is what it would find|r");
		end
	end

	local m = (type (gAtr_MeanDB) == "table") and gAtr_MeanDB[name] or nil;
	if (type (m) == "number") then m = { m }; end		-- item 13: the one-sample shape
	if (type (m) == "table" and #m > 0) then
		local n = #m;
		local lo, hi = m[1], m[1];
		local parts = {};
		local i;
		for i = 1, n do
			if (m[i] < lo) then lo = m[i]; end
			if (m[i] > hi) then hi = m[i]; end
			parts[i] = Fdr_MoneyString (m[i]);
		end
		say (string.format ("  median samples (gAtr_MeanDB): |cffffffff%d|r/15", n));
		say ("    "..table.concat (parts, "|cff555555,|r "));
		say (string.format ("    low %s   high %s   spread |cffffffffx%.1f|r",
				Fdr_MoneyString (lo), Fdr_MoneyString (hi),
				(lo > 0) and (hi / lo) or 0));
	else
		say ("  median samples (gAtr_MeanDB): |cff888888(none)|r");
	end

	-- What the tooltip renders can differ from the raw store (recent-sale or
	-- suffix-variant fallbacks in Atr_GetAuctionPrice), so show both.  Name-only,
	-- necessarily -- see the variant-slot note above: with no link there is no
	-- key to ask with, so this is the answer for an item whose variant the
	-- database has never seen, and the slot list is the answer for one it has.
	local tipAuc = (Atr_GetAuctionPrice) and Atr_GetAuctionPrice (name) or nil;
	local tipMed = (Atr_GetMeanPrice) and Atr_GetMeanPrice (name) or nil;
	say (string.format ("  name-only lookup -> auction %s   median %s",
			tipAuc and Fdr_MoneyString (tipAuc) or "|cff888888--|r",
			tipMed and Fdr_MoneyString (tipMed) or "|cff888888--|r"));
end


-- Correction: rebuild an item's median sample set from its current auction
-- price.  A median built from old samples (e.g. a run of stale/lowball scans)
-- otherwise takes several fresh scans to average back toward reality; this
-- snaps it to today's price at once and lets the spread rebuild from there.
-- "/atrprices reset all" recalibrates every priced item in one go.  Reseeding
-- from gAtr_ScanDB keeps the median consistent with the auction line the
-- moment it runs.
function Fdr_PriceDB_Reset (query)

	local function say (s)
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end

	if (type (gAtr_ScanDB) ~= "table") then
		say ("  |cffff4040gAtr_ScanDB is not loaded|r - nothing to reseed from.");
		return;
	end
	if (type (gAtr_MeanDB) ~= "table") then
		say ("  |cffff4040gAtr_MeanDB is not loaded|r.");
		return;
	end

	query = tostring (query or ""):gsub ("^%s+", ""):gsub ("%s+$", "");

	-- Bulk: reseed every item that has a current auction price.
	if (query:lower() == "all") then
		local n = 0;
		local name, price;
		for name, value in pairs (gAtr_ScanDB) do
			-- resolve rather than type-test: a variant row is a table, and the old
			-- filter would have skipped every item this database knows best
			local price = (type (Atr_PriceValue) == "function") and Atr_PriceValue (value) or value;
			if (type (price) == "number" and price > 0) then
				gAtr_MeanDB[name] = price;		-- item 13: one sample, stored bare
				n = n + 1;
			end
		end
		say (string.format ("Price DB reset: reseeded |cffffffff%d|r item%s to their current auction price.",
				n, (n == 1) and "" or "s"));
		say ("  medians now match the latest scan; spread rebuilds as you scan/search.");
		return;
	end

	if (query == "") then
		say ("  usage: |cffffffff/atrprices reset <item>|r  or  |cffffffff/atrprices reset all|r");
		return;
	end

	local name = Fdr_PriceDB_ResolveName (query);
	local price = (type (Atr_PriceValue) == "function") and Atr_PriceValue (gAtr_ScanDB[name]) or gAtr_ScanDB[name];
	if (type (price) ~= "number" or price <= 0) then
		say (string.format ("Price DB reset: |cffffd100%s|r has no stored auction price to reseed from - search or scan it first.", name));
		return;
	end

	local before = (Atr_GetMeanPrice) and Atr_GetMeanPrice (name) or nil;
	gAtr_MeanDB[name] = price;		-- item 13: one sample, stored bare
	say (string.format ("Price DB reset: |cffffd100%s|r  median %s -> %s  (reseeded from current auction)",
			name,
			before and Fdr_MoneyString (before) or "|cff888888--|r",
			Fdr_MoneyString (price)));
end


-- The toggle itself lives in the options panel now, so the slash command
-- doubles as the fallback for any build whose Scanning panel we cannot find:
-- /atrprices on|off.  Verbs:
--   on|off            toggle the Finder price feed
--   reset <item>|all  recalibrate an item's (or every item's) median to its
--                     current auction price
--   <item>            inspect one item's stored price data
--   (no argument)     DB-wide report
-- The leading verb is matched only when it is the first word, so an item that
-- happens to contain one of these words still inspects correctly.
if (SlashCmdList) then
	SLASH_ATRPRICEFEED1 = "/atrprices";
	SlashCmdList["ATRPRICEFEED"] = function (msg)
		local raw = tostring (msg or "");
		local firstword = raw:lower():match ("^%s*(%a+)");

		if (firstword == "on" or firstword == "off") then
			AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
			AUCTIONATOR_FINDER_SETTINGS.feedPriceDB = (firstword == "on");
			if (Fdr_Options_Sync) then Fdr_Options_Sync (); end
			Fdr_PriceDB_Report ();
			return;
		end

		if (firstword == "reset") then
			local rest = raw:gsub ("^%s*[Rr][Ee][Ss][Ee][Tt]%s*", "", 1);
			Fdr_PriceDB_Reset (rest);
			return;
		end

		-- Anything else names an item to inspect.
		if (raw:match ("%[(.-)%]") or raw:match ("%S")) then
			Fdr_PriceDB_Inspect (raw);
			return;
		end

		Fdr_PriceDB_Report ();
	end
end
-- FINDER_TAB end: price database feed
