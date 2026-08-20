
local addonName, addonTable = ...; 
local zc = addonTable.zc;


-----------------------------------------

local auctionator_orig_GameTooltip_OnTooltipAddMoney;

-----------------------------------------

function auctionator_GameTooltip_OnTooltipAddMoney (self, cost, maxcost)

	if (AUCTIONATOR_V_TIPS == 1) then
		return;
	end

	auctionator_orig_GameTooltip_OnTooltipAddMoney (self, cost, maxcost);
end

-----------------------------------------

function Atr_Hook_OnTooltipAddMoney()
	auctionator_orig_GameTooltip_OnTooltipAddMoney = GameTooltip_OnTooltipAddMoney;
	GameTooltip_OnTooltipAddMoney = auctionator_GameTooltip_OnTooltipAddMoney;
end

------------------------------------------------

local function Atr_AppendHint (results, price, text, volume)

	if (price and price > 0) then
		local e = {};
		e.price		= price;
		e.text		= text;
		e.volume	= volume;
		
		table.insert (results, e);
	end

end

------------------------------------------------

function Atr_BuildHints (itemName)

	local results = {};

	local itemLink = Atr_GetItemLink (itemName);

	if (itemLink == nil and itemName == nil) then
		return results;
	end

	-- Auctionator Full Scan
	
	if (itemName ~= nil and gAtr_ScanDB[itemName] ~= nil) then
		Atr_AppendHint (results, Atr_PriceValue (gAtr_ScanDB[itemName]), ZT("Auctionator scan data"));
	end

	-- most recent historical price
	
	local price = Atr_GetMostRecentSale(itemName);
	if (price ~= nil) then
		Atr_AppendHint (results, price, ZT("your most recent posting"));
	end

	-- Wowecon

	if (Wowecon and Wowecon.API) then
	
		local priceG, volG, priceS, volS;
		
		if (itemLink) then
			priceG, volG = Wowecon.API.GetAuctionPrice_ByLink (itemLink, Wowecon.API.GLOBAL_PRICE)
			priceS, volS = Wowecon.API.GetAuctionPrice_ByLink (itemLink, Wowecon.API.SERVER_PRICE)
		else
			priceG, volG = Wowecon.API.GetAuctionPrice_ByName (itemName, Wowecon.API.GLOBAL_PRICE)
			priceS, volS = Wowecon.API.GetAuctionPrice_ByName (itemName, Wowecon.API.SERVER_PRICE)
		end
		
		Atr_AppendHint (results, priceG, ZT("Wowecon global price"), volG);
		Atr_AppendHint (results, priceS, ZT("Wowecon server price"), volS);
		
	end
	
	if (itemLink) then
	
		-- GoingPrice Wowhead
		
		local id = zc.ItemIDfromLink (itemLink);
		
		id = tonumber(id);

		if (GoingPrice_Wowhead_Data and GoingPrice_Wowhead_Data[id] and GoingPrice_Wowhead_SV._index) then
			local index = GoingPrice_Wowhead_SV._index["Buyout price"];

			if (index ~= nil) then
				local price = GoingPrice_Wowhead_Data[id][index];
			
				Atr_AppendHint (results, price, "GoingPrice - Wowhead");
			end
		end

		-- GoingPrice Allakhazam
		
		if (GoingPrice_Allakhazam_Data and GoingPrice_Allakhazam_Data[id] and GoingPrice_Allakhazam_SV._index) then
			local index = GoingPrice_Allakhazam_SV._index["Median"];

			if (index ~= nil) then
				local price = GoingPrice_Allakhazam_Data[id][index];
			
				Atr_AppendHint (results, price, "GoingPrice - Allakhazam");
			end
		end
	end
	
	return results;

end

-----------------------------------------

function Atr_ShowHints ()

	Atr_Col1_Heading:Hide();
	Atr_Col3_Heading:Hide();
	Atr_Col4_Heading:Hide();

	Atr_Col3_Heading:SetText (ZT("Source"));

	local currentPane = Atr_GetCurrentPane();

	currentPane.hints = Atr_BuildHints (currentPane.activeScan.itemName);
	
	local numrows = currentPane.hints and #currentPane.hints or 0;

	if (numrows > 0) then
		Atr_Col1_Heading:Show();
		Atr_Col3_Heading:Show();
	end

	local line;							-- 1 through 12 of our window to scroll
	local dataOffset;					-- an index into our data calculated from the scroll offset

	FauxScrollFrame_Update (AuctionatorScrollFrame, numrows, 12, 16);

	for line = 1,12 do

		dataOffset = line + FauxScrollFrame_GetOffset (AuctionatorScrollFrame);

		local lineEntry = _G["AuctionatorEntry"..line];

		lineEntry:SetID(dataOffset);

		if (dataOffset <= numrows and currentPane.hints[dataOffset]) then

			local data = currentPane.hints[dataOffset];

			local lineEntry_item_tag = "AuctionatorEntry"..line.."_PerItem_Price";

			local lineEntry_item		= _G[lineEntry_item_tag];
			local lineEntry_itemtext	= _G["AuctionatorEntry"..line.."_PerItem_Text"];
			local lineEntry_text		= _G["AuctionatorEntry"..line.."_EntryText"];
			local lineEntry_stack		= _G["AuctionatorEntry"..line.."_StackPrice"];

			lineEntry_item:Show();
			lineEntry_itemtext:Hide();
			lineEntry_stack:SetText	("");

			Atr_SetMFcolor (lineEntry_item_tag, true);

			MoneyFrame_Update (lineEntry_item_tag, zc.round(data.price) );

			local text = data.text;
			if (data.volume) then
				text = text.." ("..ZT("trade volume")..": "..data.volume..")";
			end
			
			lineEntry_text:SetText (text);
			lineEntry_text:SetTextColor (0.8, 0.8, 1.0);

			lineEntry:Show();
		else
			lineEntry:Hide();
		end
	end

	Atr_HighlightEntry (currentPane.hintsIndex);
end


-----------------------------------------

function Atr_SetMFcolor (frameName, blue)

	local goldButton   = _G[frameName.."GoldButton"];
	local silverButton = _G[frameName.."SilverButton"];
	local copperButton = _G[frameName.."CopperButton"];

	if (blue) then
		goldButton:SetNormalFontObject(NumberFontNormalRightATRblue);
		silverButton:SetNormalFontObject(NumberFontNormalRightATRblue);
		copperButton:SetNormalFontObject(NumberFontNormalRightATRblue);
	else
		goldButton:SetNormalFontObject(NumberFontNormalRight);
		silverButton:SetNormalFontObject(NumberFontNormalRight);
		copperButton:SetNormalFontObject(NumberFontNormalRight);
	end
	
end


-----------------------------------------

-- FINDER_TAB: AH price estimate for random-suffix base gear ---------------
-- Random-enchant gear (e.g. "Dreamdust Slippers") is listed on the AH only
-- under its rolled-suffix names ("Dreamdust Slippers of the Magus", "... of
-- the Owl", ...), never under the bare base name.  So a lookup of the base
-- name finds nothing even when the market is full of that item -- which is
-- why crafted base gear shows "Auction: unknown" despite matching listings.
--
-- When a base name isn't listed directly we estimate its going price from the
-- suffixed variants that ARE listed: gather every "<base> of ..." entry in the
-- scan DB and take the median.  A crafted item rolls a random suffix, so the
-- median across suffixes is a fair estimate of what a freshly-crafted one
-- fetches.  The scan DB is name-keyed and can be large, so results are
-- memoised per base name; the cache is dropped whenever a scan rewrites the DB
-- (Atr_AH_InvalidateVariantCache, called from the scan finalisers).
local gAHVariantEstCache = {};

function Atr_AH_InvalidateVariantCache ()
	gAHVariantEstCache = {};
end

-- SAME-NAME VARIANTS IN THE PRICE DATABASE (BACKLOG item 12 part 3) -------
--
-- This server ships genuinely different items under one name -- a rare and an
-- epic Bloodforged Imperial Jewel -- and the price database is keyed by name,
-- so one number was standing in for both.
--
-- The value carries the variants; the KEY stays the name.  Re-keying the
-- database to item id was the obvious move and is the wrong one: a dozen callers
-- have a name and nothing else and always will (Atr_GetDEitemName turns an id
-- into a name and looks the name up; the profession code prices reagents and
-- scrolls by name; the Bazaar prices rec.name; Atr_GetAuctionBuyout is a public
-- API taking either).  Under id-keying every one of those becomes unanswerable
-- and the fix is a name->ids index with a policy for picking among them -- which
-- is this design, arrived at by the expensive route and bolted on the side.
--
--   gAtr_ScanDB[name] = 123456                       -- legacy: one price
--   gAtr_ScanDB[name] = { ["52510:0"] = 97500,       -- itemId:suffixId
--                         ["52511:0"] = 1233375,
--                         ["?"]       = 97500,       -- price for the name, variant unknown
--                         dflt        = 97500 }      -- derived: "?" when set, else the lowest
--
-- MIGRATION IS FREE, which is the other reason for this shape.  A legacy number
-- simply IS "one variant, unknown id", so a type check handles every pre-existing
-- row forever: no __dbversion bump, no rewrite pass, no risk of eating someone's
-- database.  gAtr_MeanDB already does exactly this trick at AuctionatorScan.lua.
--
-- `dflt` IS THE LOWEST KNOWN VARIANT, deliberately.  The database's meaning is
-- "lowest per-unit buyout", and before this change a merged bucket took the
-- minimum across every listing regardless of variant.  Defaulting to the lowest
-- therefore answers a name-only lookup with exactly the number it would have got
-- before -- the one property that matters, because a price silently RISING is
-- the worst thing this addon could do to someone pricing their goods.
--
-- The key is itemId:suffixId and not a bare id: random-suffix gear is the OTHER
-- variant axis and the two must not be conflated (see Atr_GetAHVariantEstimate
-- just below, which handles that one and is unrelated to this).  The format is
-- already in this addon -- AUCTIONATOR_PRICING_HISTORY stores
-- itemId:suffixId:uniqueId -- minus uniqueId, which is per-instance and would
-- shatter the table.

-- The variant key for an item link, or nil when there is no link to read.
-- 3.3.5 item strings are item:id:enchant:gem1:gem2:gem3:gem4:suffixId:uniqueId:level
function Atr_VariantKey (link)

	if (type (link) ~= "string") then return nil; end

	local itemId, suffixId = link:match ("item:(%d+):%-?%d*:%-?%d*:%-?%d*:%-?%d*:%-?%d*:(%-?%d+)");

	if (itemId == nil) then
		itemId = link:match ("item:(%d+)");
		if (itemId == nil) then return nil; end
		suffixId = "0";
	end

	return itemId..":"..(suffixId or "0");
end

-- Read one stored value.  Takes what is IN the table, not the table, so every
-- caller that already has the value can resolve it without a second lookup.
function Atr_PriceValue (v, variantKey)

	if (type (v) == "number") then return v; end		-- legacy row: one price, unknown variant
	if (type (v) ~= "table")  then return nil; end

	if (variantKey and type (v[variantKey]) == "number") then return v[variantKey]; end

	return v.dflt;
end

-- Write one price.  With no variant key this behaves exactly as the old
-- assignment did, except that it will not flatten a variant table another
-- writer has already built.
--
-- `dflt` is DERIVED, never assigned: it is the minimum across every slot, and it
-- is what a name-only lookup answers.  Two things follow, and the second one is
-- the one that bit on the first attempt:
--
--   * A price the addon knew BEFORE it knew about variants is not thrown away
--     when the first variant arrives.  It moves into the reserved slot ATR_PV_ANY
--     ("this name, variant unknown"), so promoting a row cannot make its
--     name-only price jump to whatever variant happened to be scanned first.
--     Written naively -- legacy value into dflt, then dflt recomputed from the
--     variant slots alone -- a single dear variant RAISED the answer for the
--     whole name, which is the one thing this database must never do quietly.
--     Caught by running this over a real 5471-row database rather than reasoning
--     about it.
--   * ATR_PV_ANY is not a stale ghost: the variant-less writers (the full scan,
--     the Finder feed, the Bazaar) all keep writing to it, so it stays the
--     name-level price it has always been and is refreshed on every full scan.
ATR_PV_ANY = "?";		-- reserved slot: a price for the name, variant unknown

function Atr_PriceStore (db, name, price, variantKey)

	if (type (db) ~= "table" or name == nil or type (price) ~= "number") then return; end

	local cur = db[name];

	-- a name-level write on a row that has no variants stays a bare number,
	-- exactly as before -- most of the database never becomes a table at all
	if (variantKey == nil and type (cur) ~= "table") then
		db[name] = price;
		return;
	end

	if (type (cur) ~= "table") then
		cur = {};
		if (type (db[name]) == "number") then cur[ATR_PV_ANY] = db[name]; end
		db[name] = cur;
	end

	cur[variantKey or ATR_PV_ANY] = price;

	-- `dflt` is the NAME-LEVEL slot when there is one, and only falls back to the
	-- lowest variant when there is not.
	--
	-- It was the minimum across every slot at first, which read well and is
	-- wrong: the slots are written at different TIMES by different writers, so a
	-- minimum mixes eras.  A variant slot is only refreshed when that exact name
	-- is targeted-scanned, while ATR_PV_ANY is refreshed by every full scan and
	-- by the Finder feed -- so one stale cheap variant would pin a name's answer
	-- below the market indefinitely, and nothing would lift it back.
	--
	-- Seen in the owner's live data before it could do any harm: `Large Fang`
	-- came back as `{ ["5637:0"] = 9900, ["?"] = 11000 }`, and the minimum rule
	-- answered 9900 for the name while the current name-level price was 11000.
	--
	-- Preferring ATR_PV_ANY also makes a name-only lookup behave EXACTLY as it
	-- did before variants existed, because that slot is written by precisely the
	-- writers that used to write the bare number.  Callers that want a specific
	-- variant ask for it by key and are unaffected.
	if (type (cur[ATR_PV_ANY]) == "number") then
		cur.dflt = cur[ATR_PV_ANY];
	else
		local lo = nil;
		local k, pr;
		for k, pr in pairs (cur) do
			if (k ~= "dflt" and type (pr) == "number" and (lo == nil or pr < lo)) then lo = pr; end
		end
		cur.dflt = lo;
	end
end

-- Returns estimatedPrice, variantCount for a base item name, or nil when the
-- scan DB holds no "<name> of ..." variants to estimate from.
function Atr_GetAHVariantEstimate (itemName)
	if (type (itemName) ~= "string" or itemName == "" or gAtr_ScanDB == nil) then return nil; end

	local cached = gAHVariantEstCache[itemName];
	if (cached ~= nil) then
		if (cached == false) then return nil; end		-- memoised "no variants"
		return cached.price, cached.count;
	end

	local prefix = itemName .. " of ";		-- random-suffix delimiter (enUS: "of the Owl", "of Intellect", ...)
	local plen   = #prefix;
	local prices = {};
	for name, value in pairs (gAtr_ScanDB) do
		-- Atr_PriceValue, not a type check: a variant row is a TABLE now, and the
		-- old `type(price) == "number"` filter would have silently dropped exactly
		-- the rows this database learned the most about.
		local price = Atr_PriceValue (value);
		if (price and price > 0 and #name > plen and string.sub (name, 1, plen) == prefix) then
			table.insert (prices, price);
		end
	end

	if (#prices == 0) then
		gAHVariantEstCache[itemName] = false;
		return nil;
	end

	table.sort (prices);
	local n = #prices;
	local median;
	if (n % 2 == 0) then median = (prices[n/2] + prices[n/2 + 1]) / 2; else median = prices[math.ceil (n/2)]; end
	median = math.floor (median);

	gAHVariantEstCache[itemName] = { price = median, count = n };
	return median, n;
end

-----------------------------------------

-- `variantKey` is optional (Atr_VariantKey of the item's link).  Without one the
-- answer is the name's default, which is what every existing caller gets and is
-- the same number they got before variants existed.
function Atr_GetAuctionPrice (item, variantKey)  -- itemName or itemID

	local itemName;

	if (type (item) == "number") then
		itemName = GetItemInfo (item);
	else
		itemName = item;
	end

	if (itemName == nil) then
		return nil;
	end

	if (gAtr_ScanDB and gAtr_ScanDB[itemName]) then
		local p = Atr_PriceValue (gAtr_ScanDB[itemName], variantKey);
		if (p) then return p; end
	end

	-- THE MARKET SERIES, above your own postings (BACKLOG item 31, stage 2).
	--
	-- The rung below this one is Atr_GetMostRecentSale, which reads
	-- AUCTIONATOR_PRICING_HISTORY -- and that is a record of WHAT YOU LISTED
	-- THINGS AT, not what the market did.  So when the scan database has nothing,
	-- this function's answer used to be your own last guess, priced back to you
	-- as though it were evidence.  A recorded market reading is strictly better,
	-- and it is bounded by the store's own month of retention where the posting
	-- history has no age bound at all.
	--
	-- Name-keyed, so like every fallback under it this answers the name's default
	-- rather than a variant -- the same limitation the mean database carries, and
	-- for the same reason (item 12 part 3b).  Costs a table lookup and one string
	-- match, and only on the path where the scan database already missed.
	if (type (Atr_Hist_Recent) == "function") then
		local hp = Atr_Hist_Recent (itemName);
		if (hp and hp > 0) then return hp; end
	end

	local recent = Atr_GetMostRecentSale (itemName);
	if (recent) then
		return recent;
	end

	-- Random-suffix base gear isn't listed under its bare name; fall back to a
	-- median estimate across its suffixed variants (see Atr_GetAHVariantEstimate).
	local est = Atr_GetAHVariantEstimate (itemName);
	if (est) then
		return est;
	end

	return nil;
end

-----------------------------------------

-- FINDER_TAB: NPC (vendor-bought) trade-good prices -----------------------
-- Moved to AuctionatorFinderMerchant.lua, which now owns all merchant-window
-- scanning (NPC trade-good prices AND Bazaar tokens) behind one debounced,
-- session-throttled event frame so opening a vendor no longer re-walks the
-- list on every MERCHANT_UPDATE.  Atr_NPC_DB / Atr_GetNPCPrice /
-- Atr_NPC_HarvestMerchant stay global, so the tooltip code below still calls
-- Atr_GetNPCPrice exactly as before.

-----------------------------------------

-- THE MEAN DATABASE'S SHAPE (BACKLOG item 13) ----------------------------
--
-- A sample set of ONE is stored as a bare number, and only becomes a table on
-- the second sample.  Measured on a real 5523-name database: **64% of names hold
-- exactly one sample** and 1737 of those are byte-identical to that name's price
-- row -- ~232 KB, a fifth of the whole saved-variables file, spent on table
-- wrappers around a single number that is often written down twice.
--
-- Legacy arrays keep working untouched, the same way the price database's legacy
-- numbers do, and Atr_CompactMeanDB folds the existing ones down at load.
--
-- DELIBERATELY NOT VARIANT-AWARE, which is where this parts company with the
-- price database (BACKLOG item 12 part 3b).  The plan was to give it the same
-- per-variant slots so the tooltip's two price lines could not disagree.  The
-- data says not to: this database averages **1.97 samples per name**, 64% have
-- one and only 8.7% have five or more.  Splitting that by variant would leave
-- most variants with a single sample -- a "median" of one number -- so it would
-- buy no statistical accuracy at all while turning one value into three shapes
-- (number, sample array, variant map).  The mild inconsistency between an
-- exact `Auction` line and a name-level `Auction median` is the cheaper of the
-- two wrongs, and it is stated here rather than left for someone to rediscover.
ATR_MEAN_CAP = 15;

-- The median of a stored value, whatever shape it is in.
function Atr_MeanMedian (v)

	if (type (v) == "number") then return v; end				-- the one-sample shape
	if (type (v) ~= "table" or #v == 0) then return nil; end

	local n = #v;
	if (n % 2 == 0) then return math.floor ((v[n/2] + v[n/2 + 1]) / 2); end
	return math.floor (v[math.ceil (n/2)]);
end

-- Append one sample, promoting the shape as it goes.  Keeps the existing cap and
-- eviction behaviour exactly: sorted, and at the cap one is dropped at random.
-- Random eviction is what FRAMEWORK.md §5 criticises, and it is preserved here
-- on purpose -- the array is sorted anyway, so the ordering it would protect was
-- already gone, and changing it is a behaviour change that does not belong in a
-- size fix.
function Atr_MeanAppend (db, name, sample)

	if (type (db) ~= "table" or name == nil or type (sample) ~= "number" or sample <= 0) then return; end

	local cur = db[name];

	if (cur == nil) then
		db[name] = sample;					-- first sample: no table at all
		return;
	end

	if (type (cur) == "number") then
		db[name] = { cur, sample };			-- second sample: promote
		cur = db[name];
	elseif (type (cur) == "table") then
		tinsert (cur, sample);
	else
		db[name] = sample;
		return;
	end

	if (#cur > ATR_MEAN_CAP) then tremove (cur, math.random (1, #cur)); end
	table.sort (cur);
end

function Atr_GetMeanPrice (item)  -- itemName or itemID

	local itemName;
	
	if (type (item) == "number") then
		itemName = GetItemInfo (item);
	else
		itemName = item;
	end

	if (itemName == nil) then
		return nil;
	end

	if (gAtr_MeanDB) then
		return Atr_MeanMedian (gAtr_MeanDB[itemName]);
	end
	
	return nil;
end	

-----------------------------------------

local function Atr_CalcTextWid (price)

	local wid = 15;
	
	if (price > 9)			then wid = wid + 12;	end;
	if (price > 99)			then wid = wid + 44;	end;
	if (price > 999)		then wid = wid + 12;	end;
	if (price > 9999)		then wid = wid + 44;	end;
	if (price > 99999)		then wid = wid + 12;	end;
	if (price > 999999)		then wid = wid + 12;	end;
	if (price > 9999999)	then wid = wid + 12;	end;
	if (price > 99999999)	then wid = wid + 12;	end;
	
	return wid;
end

-----------------------------------------

local function Atr_CalcTTpadding (price1, price2)

	local padding = "";

	if (price1 and price2) then
		local vpwidth = Atr_CalcTextWid (price1);
		local apwidth = Atr_CalcTextWid (price2);

		local padlen = math.floor ((apwidth - vpwidth)/6);
		local k;
		
		for k = 1,padlen do
			padding = padding.." ";
		end
	end

	return padding;

end

-----------------------------------------

local UNCOMMON	= 2;
local RARE		= 3;
local EPIC		= 4;

local WEAPON = 1;
local ARMOR  = 2;

local LESSER_MAGIC		= 10938;
local GREATER_MAGIC		= 10939;
local STRANGE_DUST		= 10940;

local SMALL_GLIMMERING	= 10978;
local LESSER_ASTRAL		= 10998;

local GREATER_ASTRAL	= 11082;
local SOUL_DUST			= 11083;
local LARGE_GLIMMERING	= 11084;

local LESSER_MYSTIC		= 11134;
local GREATER_MYSTIC	= 11135;
local VISION_DUST		= 11137;
local SMALL_GLOWING		= 11138;
local LARGE_GLOWING		= 11139;

local LESSER_NETHER		= 11174;
local GREATER_NETHER	= 11175;
local DREAM_DUST		= 11176;
local SMALL_RADIANT		= 11177;
local LARGE_RADIANT		= 11178;

local SMALL_BRILLIANT	= 14343;
local LARGE_BRILLIANT	= 14344;

local LESSER_ETERNAL	= 16202;
local GREATER_ETERNAL	= 16203;
local ILLUSION_DUST		= 16204;

local NEXUS_CRYSTAL		= 20725;

local ARCANE_DUST		= 22445;
local GREATER_PLANAR	= 22446;
local LESSER_PLANAR		= 22447;
local SMALL_PRISMATIC	= 22448;
local LARGE_PRISMATIC	= 22449;
local VOID_CRYSTAL		= 22450;

local DREAM_SHARD		= 34052;
local SMALL_DREAM		= 34053;

local INFINITE_DUST		= 34054;
local GREATER_COSMIC	= 34055;
local LESSER_COSMIC		= 34056;
local ABYSS_CRYSTAL		= 34057;

local engDEnames = {};

engDEnames [LESSER_MAGIC]		= "Lesser Magic Essence";
engDEnames [GREATER_MAGIC]		= "Greater Magic Essence";
engDEnames [STRANGE_DUST]		= "Strange Dust";

engDEnames [SMALL_GLIMMERING]	= "Small Glimmering Shard";
engDEnames [LESSER_ASTRAL]		= "Lesser Astral Essence";

engDEnames [GREATER_ASTRAL]		= "Greater Astral Essence";
engDEnames [SOUL_DUST]			= "Soul Dust";
engDEnames [LARGE_GLIMMERING]	= "Large Glimmering Essence";

engDEnames [LESSER_MYSTIC]		= "Lesser Mystic Essence";
engDEnames [GREATER_MYSTIC]		= "Greater Mystic Essence";
engDEnames [VISION_DUST]		= "Vision Dust";
engDEnames [SMALL_GLOWING]		= "Small Glowing Shard";
engDEnames [LARGE_GLOWING]		= "Large Glowing Shard";

engDEnames [LESSER_NETHER]		= "Lesser Nether Essence";
engDEnames [GREATER_NETHER]		= "Greater Nether Essence";
engDEnames [DREAM_DUST]			= "Dream Dust";
engDEnames [SMALL_RADIANT]		= "Small Radiant";
engDEnames [LARGE_RADIANT]		= "Large Radiant";

engDEnames [SMALL_BRILLIANT]	= "Small Brilliant Shard";
engDEnames [LARGE_BRILLIANT]	= "Large Brilliant Shard";

engDEnames [LESSER_ETERNAL]		= "Lesser Eternal Essence";
engDEnames [GREATER_ETERNAL]	= "Greater Eternal Essence";
engDEnames [ILLUSION_DUST]		= "Illusion Dust";

engDEnames [NEXUS_CRYSTAL]		= "Nexus Crystal";

engDEnames [ARCANE_DUST]		= "Arcane Dust";
engDEnames [GREATER_PLANAR]		= "Greater Planar Essence";
engDEnames [LESSER_PLANAR]		= "Lesser Planar Essence";
engDEnames [SMALL_PRISMATIC]	= "Small Prismatic Shard";
engDEnames [LARGE_PRISMATIC]	= "Large Prismatic Shard";
engDEnames [VOID_CRYSTAL]		= "Void Crystal";

engDEnames [DREAM_SHARD]		= "Dream Shard";
engDEnames [SMALL_DREAM]		= "Small Dream Shard";

engDEnames [INFINITE_DUST]		= "Infinite Dust";
engDEnames [GREATER_COSMIC]		= "Greater Cosmic Essence";
engDEnames [LESSER_COSMIC]		= "Lesser Cosmic Essence";
engDEnames [ABYSS_CRYSTAL]		= "Abyss Crystal";


local dustsAndEssences = {};

tinsert (dustsAndEssences, LESSER_MAGIC)
tinsert (dustsAndEssences, GREATER_MAGIC)
tinsert (dustsAndEssences, STRANGE_DUST)

tinsert (dustsAndEssences, SMALL_GLIMMERING)
tinsert (dustsAndEssences, LESSER_ASTRAL)

tinsert (dustsAndEssences, GREATER_ASTRAL)
tinsert (dustsAndEssences, SOUL_DUST)
tinsert (dustsAndEssences, LARGE_GLIMMERING)

tinsert (dustsAndEssences, LESSER_MYSTIC)
tinsert (dustsAndEssences, GREATER_MYSTIC)
tinsert (dustsAndEssences, VISION_DUST)
tinsert (dustsAndEssences, SMALL_GLOWING)
tinsert (dustsAndEssences, LARGE_GLOWING)

tinsert (dustsAndEssences, LESSER_NETHER)
tinsert (dustsAndEssences, GREATER_NETHER)
tinsert (dustsAndEssences, DREAM_DUST)
tinsert (dustsAndEssences, SMALL_RADIANT)
tinsert (dustsAndEssences, LARGE_RADIANT)

tinsert (dustsAndEssences, SMALL_BRILLIANT)
tinsert (dustsAndEssences, LARGE_BRILLIANT)

tinsert (dustsAndEssences, LESSER_ETERNAL)
tinsert (dustsAndEssences, GREATER_ETERNAL)
tinsert (dustsAndEssences, ILLUSION_DUST)

tinsert (dustsAndEssences, NEXUS_CRYSTAL)

tinsert (dustsAndEssences, ARCANE_DUST)
tinsert (dustsAndEssences, GREATER_PLANAR)
tinsert (dustsAndEssences, LESSER_PLANAR)
tinsert (dustsAndEssences, SMALL_PRISMATIC)
tinsert (dustsAndEssences, LARGE_PRISMATIC)
tinsert (dustsAndEssences, VOID_CRYSTAL)

tinsert (dustsAndEssences, DREAM_SHARD)
tinsert (dustsAndEssences, SMALL_DREAM)

tinsert (dustsAndEssences, INFINITE_DUST)
tinsert (dustsAndEssences, GREATER_COSMIC)
tinsert (dustsAndEssences, LESSER_COSMIC)
tinsert (dustsAndEssences, ABYSS_CRYSTAL)

gAtr_dustCacheIndex = 1;

local DUST_CACHE_READY_FOR_NEXT  = 0;
local DUST_CACHE_WAITING_ON_PREV = 1;

local dustCacheState = DUST_CACHE_READY_FOR_NEXT;

-----------------------------------------

function Atr_GetNextDustIntoCache()		-- make sure all the dusts and essences are in the local cache
										-- only needed after a major patch and a cache wipe
	if (gAtr_dustCacheIndex == 0) then
		return;
	end

	local itemID		= dustsAndEssences[gAtr_dustCacheIndex];
	local itemString	= "item:"..itemID..":0:0:0:0:0:0:0";
	
	local itemName, itemLink = GetItemInfo(itemString);
	
	zc.md (itemString, itemName, itemLink, dustCacheState, gAtr_dustCacheIndex);

	if (itemLink == nil and dustCacheState == DUST_CACHE_READY_FOR_NEXT) then
		dustCacheState = DUST_CACHE_WAITING_ON_PREV;
		AtrScanningTooltip:SetHyperlink(itemString);
		local _, link = GetItemInfo(itemString);
--		zc.md ("pulling "..itemString.." into the local cache   ", itemLink, link, dustCacheState);
	end

	if (itemLink) then
--		zc.md (itemLink.." is in local cache");
		dustCacheState = DUST_CACHE_READY_FOR_NEXT;
		gAtr_dustCacheIndex = gAtr_dustCacheIndex + 1;
		
		if (gAtr_dustCacheIndex > #dustsAndEssences) then
			gAtr_dustCacheIndex = 0;		-- finished
		end
	end
end

-----------------------------------------

local deItemNames = {};

local function Atr_GetDEitemName (itemID)

	if (deItemNames[itemID] == nil) then
		local itemName = GetItemInfo (itemID);
		if (itemName == nil) then
			zc.md ("defaulting to english DE mat name: "..engDEnames [itemID]);
			return engDEnames [itemID];
		end
		
		deItemNames[itemID] = itemName;
	end
	
	return deItemNames[itemID];

end

-----------------------------------------

function Atr_GetAuctionPriceDE (itemID)  -- same as Atr_GetAuctionPrice but understands that some "lesser" essences are convertible with "greater"

	local lesserPrice;
	local greaterPrice;
	
	if (itemID == LESSER_COSMIC) then
		lesserPrice  = Atr_GetAuctionPrice (Atr_GetDEitemName (LESSER_COSMIC));
		greaterPrice = Atr_GetAuctionPrice (Atr_GetDEitemName (GREATER_COSMIC));
	end
	
	if (itemID == LESSER_PLANAR) then
		lesserPrice  = Atr_GetAuctionPrice (Atr_GetDEitemName (LESSER_PLANAR));
		greaterPrice = Atr_GetAuctionPrice (Atr_GetDEitemName (GREATER_PLANAR));
	end
	
	if (lesserPrice ~= nil and greaterPrice ~= nil and lesserPrice * 3 > greaterPrice) then
		return math.floor (greaterPrice / 3);
	end
	
	return Atr_GetAuctionPrice (Atr_GetDEitemName (itemID));
end

-----------------------------------------

local deTable = {};

-----------------------------------------

local function deKey (itemType, itemRarity)
	local s = tostring(itemType).."_"..itemRarity
	return s;
end

-----------------------------------------

local function DEtableInsert(t, info)

	local entry = {};

	local x, i, n;
	
	entry[1]	= info[1];
	entry[2]	= info[2];
	
	n = 3;
	
	for x = 3,#info,3 do
		local nums = info[x+1];
		if (type(nums) == "number") then
			entry[n]   = info[x];
			entry[n+1] = info[x+1];
			entry[n+2] = info[x+2];
			n = n + 3;
		else
			for i = nums[1],nums[2] do
				entry[n]   = info[x]/(nums[2]-nums[1]+1);
				entry[n+1] = i;
				entry[n+2] = info[x+2];
				n = n + 3;				
			end
		end
	end
	
	table.insert (t, entry);

end


-----------------------------------------

function Atr_InitDETable()		-- based on table at wowwiki.com/Disenchanting_tables


	-- UNCOMMON ARMOR

	deTable[deKey(ARMOR, UNCOMMON)] = {};
	
	local t = deTable[deKey(ARMOR, UNCOMMON)];
	
	
	DEtableInsert (t, {5, 15,		80, {1,2}, STRANGE_DUST,	20, {1,2}, LESSER_MAGIC});
	DEtableInsert (t, {16, 20,		75, {2,3}, STRANGE_DUST,	20, {1,2}, GREATER_MAGIC,	5, 1, SMALL_GLIMMERING});
	DEtableInsert (t, {21, 25,		75, {4,6}, STRANGE_DUST,	15, {1,2}, LESSER_ASTRAL,	10, 1, SMALL_GLIMMERING});
	DEtableInsert (t, {26, 30,		75, {1,2}, SOUL_DUST,		20, {1,2}, GREATER_ASTRAL,	5, 1, LARGE_GLIMMERING});
	DEtableInsert (t, {31, 35,		75, {2,5}, SOUL_DUST,		20, {1,2}, LESSER_MYSTIC,	5, 1, SMALL_GLOWING});
	DEtableInsert (t, {36, 40,		75, {1,2}, VISION_DUST,		20, {1,2}, GREATER_MYSTIC,	5, 1, LARGE_GLOWING});
	DEtableInsert (t, {41, 45,		75, {2,5}, VISION_DUST,		20, {1,2}, LESSER_NETHER,	5, 1, SMALL_RADIANT});
	DEtableInsert (t, {46, 50,		75, {1,2}, DREAM_DUST,		20, {1,2}, GREATER_NETHER,	5, 1, LARGE_RADIANT});
	DEtableInsert (t, {51, 55,		75, {2,5}, DREAM_DUST,		20, {1,2}, LESSER_ETERNAL,	5, 1, SMALL_BRILLIANT});
	DEtableInsert (t, {56, 60,		75, {1,2}, ILLUSION_DUST,	20, {1,2}, GREATER_ETERNAL,	5, 1, LARGE_BRILLIANT});
	DEtableInsert (t, {61, 65,		75, {2,5}, ILLUSION_DUST,	20, {2,3}, GREATER_ETERNAL,	5, 1, LARGE_BRILLIANT});
	DEtableInsert (t, {66, 80,		75, {1,3}, ARCANE_DUST,		22, {1,3}, LESSER_PLANAR,	3, 1, SMALL_PRISMATIC});
	DEtableInsert (t, {81, 99,		75, {2,3}, ARCANE_DUST,		22, {2,3}, LESSER_PLANAR,	3, 1, SMALL_PRISMATIC});
	DEtableInsert (t, {100, 120,	75, {2,5}, ARCANE_DUST,		22, {1,2}, GREATER_PLANAR,	3, 1, LARGE_PRISMATIC});
	DEtableInsert (t, {121, 151,	75, {1,3}, INFINITE_DUST,	22, {1,2}, LESSER_COSMIC,	3, 1, SMALL_DREAM});
	DEtableInsert (t, {152, 200,	75, {4,7}, INFINITE_DUST,	22, {1,2}, GREATER_COSMIC,	3, 1, DREAM_SHARD});


	-- UNCOMMON WEAPONS

	deTable[deKey(WEAPON, UNCOMMON)] = {};
	
	local t = deTable[deKey(WEAPON, UNCOMMON)];

	DEtableInsert (t, {6, 15,		20, {1,2}, STRANGE_DUST,	80, {1,2}, LESSER_MAGIC});
	DEtableInsert (t, {16, 20,		20, {2,3}, STRANGE_DUST,	75, {1,2}, GREATER_MAGIC,	5, 1, SMALL_GLIMMERING});
	DEtableInsert (t, {21, 25,		15, {4,6}, STRANGE_DUST,	75, {1,2}, LESSER_ASTRAL,	10, 1, SMALL_GLIMMERING});
	DEtableInsert (t, {26, 30,		20, {1,2}, SOUL_DUST,		75, {1,2}, GREATER_ASTRAL,	5, 1, LARGE_GLIMMERING});
	DEtableInsert (t, {31, 35,		20, {2,5}, SOUL_DUST,		75, {1,2}, LESSER_MYSTIC,	5, 1, SMALL_GLOWING});
	DEtableInsert (t, {36, 40,		20, {1,2}, VISION_DUST,		75, {1,2}, GREATER_MYSTIC,	5, 1, LARGE_GLOWING});
	DEtableInsert (t, {41, 45,		20, {2,5}, VISION_DUST,		75, {1,2}, LESSER_NETHER,	5, 1, SMALL_RADIANT});
	DEtableInsert (t, {46, 50,		20, {1,2}, DREAM_DUST,		75, {1,2}, GREATER_NETHER,	5, 1, LARGE_RADIANT});
	DEtableInsert (t, {51, 55,		22, {2,5}, DREAM_DUST,		75, {1,2}, LESSER_ETERNAL,	5, 1, SMALL_BRILLIANT});
	DEtableInsert (t, {56, 60,		22, {1,2}, ILLUSION_DUST,	75, {1,2}, GREATER_ETERNAL,	5, 1, LARGE_BRILLIANT});
	DEtableInsert (t, {61, 65,		22, {2,5}, ILLUSION_DUST,	75, {2,3}, GREATER_ETERNAL,	5, 1, LARGE_BRILLIANT});
	DEtableInsert (t, {66, 99,		22, {2,3}, ARCANE_DUST,		75, {2,3}, LESSER_PLANAR,	3, 1, SMALL_PRISMATIC});
	DEtableInsert (t, {100, 120,	22, {2,5}, ARCANE_DUST,		75, {1,2}, GREATER_PLANAR,	3, 1, LARGE_PRISMATIC});
	DEtableInsert (t, {121, 151,	22, {1,3}, INFINITE_DUST,	75, {1,2}, LESSER_COSMIC,	3, 1, SMALL_DREAM});
	DEtableInsert (t, {152, 200,	22, {4,7}, INFINITE_DUST,	75, {1,2}, GREATER_COSMIC,	3, 1, DREAM_SHARD});
	
	-- RARE ITEMS
	
	deTable[deKey(ARMOR, RARE)] = {};
	
	t = deTable[deKey(ARMOR, RARE)];

	DEtableInsert (t, {11, 25,		100, 1, SMALL_GLIMMERING});
	DEtableInsert (t, {26, 30,		100, 1, LARGE_GLIMMERING});
	DEtableInsert (t, {31, 35,		100, 1, SMALL_GLOWING});
	DEtableInsert (t, {36, 40,		100, 1, LARGE_GLOWING});
	DEtableInsert (t, {41, 45,		100, 1, SMALL_RADIANT});
	DEtableInsert (t, {46, 50,		100, 1, LARGE_RADIANT});
	DEtableInsert (t, {51, 55,		100, 1, SMALL_BRILLIANT});
	DEtableInsert (t, {56, 65,		99.5, 1, LARGE_BRILLIANT,		0.5, 1, NEXUS_CRYSTAL});
	DEtableInsert (t, {66, 99,		99.5, 1, SMALL_PRISMATIC,		0.5, 1, NEXUS_CRYSTAL});
	DEtableInsert (t, {100, 120,	99.5, 1, LARGE_PRISMATIC,		0.5, 1, VOID_CRYSTAL});
	DEtableInsert (t, {121, 164,	99.5, 1, SMALL_DREAM,			0.5, 1, ABYSS_CRYSTAL});
	DEtableInsert (t, {165, 999,	99.5, 1, DREAM_SHARD,			0.5, 1, ABYSS_CRYSTAL});

	deTable[deKey(WEAPON, RARE)] = deTable[deKey(ARMOR, RARE)];


	-- EPIC ITEMS
	
	deTable[deKey(ARMOR, EPIC)] = {};
	
	t = deTable[deKey(ARMOR, EPIC)];

	DEtableInsert (t, {40, 45,		100, {2,4}, SMALL_RADIANT});
	DEtableInsert (t, {46, 50,		100, {2,4}, LARGE_RADIANT});
	DEtableInsert (t, {51, 55,		100, {2,4}, SMALL_BRILLIANT});
	DEtableInsert (t, {56, 60,		100, 1, NEXUS_CRYSTAL});
--	DEtableInsert (t, {61, 80,  FILLED IN BELOW
	DEtableInsert (t, {95, 100,		100, {1,2}, VOID_CRYSTAL});
	DEtableInsert (t, {105, 164,	33.3, 1, VOID_CRYSTAL,	66.6, 2, VOID_CRYSTAL});
	DEtableInsert (t, {165, 200,	100, 1, ABYSS_CRYSTAL});
	DEtableInsert (t, {200, 999,	100, 1, ABYSS_CRYSTAL});

	deTable[deKey(WEAPON, EPIC)] = zc.CopyDeep (deTable[deKey(ARMOR, EPIC)]);	-- copy it this time because of differences

	DEtableInsert (deTable[deKey(ARMOR,  EPIC)], {61, 80,	50,   1, NEXUS_CRYSTAL, 	50,   2, NEXUS_CRYSTAL});
	DEtableInsert (deTable[deKey(WEAPON, EPIC)], {61, 80,	33.3, 1, NEXUS_CRYSTAL, 	66.6, 2, NEXUS_CRYSTAL});

end

-----------------------------------------

local function Atr_FindDEentry (itemType, itemRarity, itemLevel)

	local itemTypeNum = Atr_ItemType2AuctionClass (itemType);

	local t = deTable[deKey(itemTypeNum, itemRarity)];

	if (t) then
		local n;
		for n = 1, #t do
			
			local ta = t[n];
			
			if (itemLevel >= ta[1] and itemLevel <= ta[2]) then
				return ta;
			end
		end
	end


end

-----------------------------------------

local function Atr_AddDEDetailsToTip (tip, itemType, itemRarity, itemLevel, DEreqLevel)

	local ta = Atr_FindDEentry (itemType, itemRarity, itemLevel);

	if (ta) then
		local x;
		for x = 3,#ta,3 do
			local percent = math.floor (ta[x]*100) / 100;

			local deitem = Atr_GetDEitemName(ta[x+2]);
			if (deitem == nil) then
				deitem = "???";
			end

			tip:AddLine ("  |cFFFFFFFF"..percent.."%|r   "..ta[x+1].." "..deitem);
		end
	end

	tip:AddLine ("  |cFFAAAAFF"..ZT("Required DE skill level")..": "..DEreqLevel);
end

-----------------------------------------

function Atr_DumpDETable (itemType, itemRarity)

	local t = deTable[deKey(itemType, itemRarity)];

	if (t) then
		local n, x;
		for n = 1, #t do
			local ta = t[n];
			
			zc.msg_pink ("iLvl: "..ta[1].."-"..ta[2]);
			
			for x = 3,#ta,3 do
				zc.msg_pink ("   "..ta[x].."%  "..ta[x+1].."  "..Atr_GetDEitemName(ta[x+2]).."  ("..Atr_GetAuctionPrice (Atr_GetDEitemName(ta[x+2]))..")");
			end
		end
	end

end

-----------------------------------------

function Atr_CalcDisenchantPrice (itemType, itemRarity, itemLevel)

	if (Atr_IsWeaponType (itemType) or Atr_IsArmorType (itemType)) then
		if (itemRarity == UNCOMMON or itemRarity == RARE or itemRarity == EPIC) then

			local dePrice = 0;

			local ta = Atr_FindDEentry (itemType, itemRarity, itemLevel);
			if (ta) then
				local x;
				for x = 3,#ta,3 do
					local price = Atr_GetAuctionPriceDE (ta[x+2]);
					if (price) then
						dePrice = dePrice + (ta[x] * ta[x+1] * price);
					end
				end
			end

			return math.floor (dePrice/100);
		end
	end
	
	return nil;		-- can't be disenchanted
end

-----------------------------------------

-- FINDER_TAB begin: Ascension per-instance scaling detector ---------------
-- The tooltip body is SERVER-rendered truth for the hovered instance;
-- GetItemInfo(link) is cached-first and lies for scaled variants (see
-- ASCENSION-CLIENT-NOTES.md "THE BIG ONE").  If the tooltip's own
-- Item Level / Requires Level lines disagree with the cached values, then
-- every cached-derived price (notably vendor price) belongs to a different
-- scale-variant of this itemID and must not be shown as if it were real.
local ATR_PAT_ILVL = (type(ITEM_LEVEL)     == "string") and ("^"..ITEM_LEVEL:gsub("%%d", "(%%d+)"))     or "^Item Level (%d+)";
local ATR_PAT_REQ  = (type(ITEM_MIN_LEVEL) == "string") and ("^"..ITEM_MIN_LEVEL:gsub("%%d", "(%%d+)")) or "^Requires Level (%d+)";

-- returns: mismatch (bool), tooltip item level, tooltip required level
local function Atr_TipScaleMismatch (tip, cachedIlvl, cachedReq)
	if (tip == nil or tip.NumLines == nil or tip.GetName == nil) then return false; end;
	local tipname = tip:GetName();
	if (tipname == nil) then return false; end;
	local tipIlvl, tipReq;
	local i;
	for i = 2, tip:NumLines() do
		local fs  = _G[tipname.."TextLeft"..i];
		local txt = fs and fs.GetText and fs:GetText();
		if (txt) then
			local ilvl = txt:match (ATR_PAT_ILVL);
			if (ilvl) then tipIlvl = tonumber(ilvl); end;
			local req = txt:match (ATR_PAT_REQ);
			if (req) then tipReq = tonumber(req); end;
		end
	end
	local mismatch = false;
	if (tipIlvl and cachedIlvl and cachedIlvl > 0 and tipIlvl ~= cachedIlvl) then mismatch = true; end;
	if (tipReq  and cachedReq  and cachedReq  > 0 and tipReq  ~= cachedReq)  then mismatch = true; end;
	return mismatch, tipIlvl, tipReq;
end
-- FINDER_TAB end: Ascension per-instance scaling detector -----------------

-- FINDER_TAB begin: vendor price learning ----------------------------------
-- Records the REAL unit price whenever a scaled variant is sold to a
-- merchant.  Capture: wrap UseContainerItem (the sell call) -> read the
-- instance's server tooltip via a hidden scan tooltip -> after the sale,
-- confirm the exact price from the buyback list (server-authoritative,
-- matched by name+count; money deltas are never used - they race).
-- Data lives in SavedVariables AUCTIONATOR_VENDOR_LEARNED:
--   .obs["itemID:ilvl:req"] = { p = unit price, n = times observed }
--   .log = last 500 raw samples incl. base ilvl/price, for deriving the
--          server's scaling formula offline (stage 2: prediction).
--   .base[itemID] = { p, il, rq, n, x } - TRUSTED base facts, captured
--          only from UNSCALED buyback-confirmed sales of equippable
--          items.  The cached GetItemInfo basePrice recorded in .log
--          is cached-first and unreliable (see ASCENSION-CLIENT-NOTES;
--          harvest #2 analysis); this is the server-authoritative
--          replacement.  n = majority-vote count, x = conflicts seen.
--   .cb[itemID] = { v = { [il] = { p, rq, ag } } } - per-VARIANT sighting
--          map: every distinct ilvl GetItemInfo has ever served for the
--          item, with that sighting's price (cap 12, highest il evicted
--          first; ag=1 when the server tooltip agreed with the cache at
--          that sighting - agreed prices are never displaced by
--          unagreed refreshes).  Persisted account-wide because owning
--          item rewrites the on-disk item cache to THAT instance's
--          values; after /reload GetItemInfo then returns the owned
--          instance (delta ~ 0) and prediction would be wrongly gated
--          (see ASCENSION-CLIENT-NOTES).  The pre-purchase sighting
--          kept here survives both the purchase and the reload.
--   Atr_VendorPredict_Get = stage-2 GATED prediction from the harvest #3
--          rule set (docs/VENDOR-PRICE-RESEARCH.md); feeds the tooltip
--          "Predicted vendor" line for scale-variants never sold.
local gVendorScanTip      = nil;
local gVendorPendingSales = {};		-- FIFO queue of recent sells (pruned after 3s); a single slot cross-attributed prices during same-name sell sprees (live case study #5)

local function Atr_VendorLearnedDB ()
	if (type(AUCTIONATOR_VENDOR_LEARNED) ~= "table")     then AUCTIONATOR_VENDOR_LEARNED = {}; end;
	if (type(AUCTIONATOR_VENDOR_LEARNED.obs) ~= "table") then AUCTIONATOR_VENDOR_LEARNED.obs = {}; end;
	if (type(AUCTIONATOR_VENDOR_LEARNED.log) ~= "table") then AUCTIONATOR_VENDOR_LEARNED.log = {}; end;
	if (type(AUCTIONATOR_VENDOR_LEARNED.base) ~= "table") then AUCTIONATOR_VENDOR_LEARNED.base = {}; end;
	if (type(AUCTIONATOR_VENDOR_LEARNED.cb) ~= "table")   then AUCTIONATOR_VENDOR_LEARNED.cb   = {}; end;
	if (type(AUCTIONATOR_VENDOR_LEARNED.trk) ~= "table")  then AUCTIONATOR_VENDOR_LEARNED.trk  = {}; end;	-- observed cap floors (self-healing track correction)
	return AUCTIONATOR_VENDOR_LEARNED;
end

function Atr_VendorLearned_Get (itemID, ilvl, req)
	local rec = Atr_VendorLearnedDB().obs[itemID..":"..(ilvl or 0)..":"..(req or 0)];
	if (rec and rec.p and rec.p > 0) then return rec.p; end;
	return nil;
end

-- trusted base facts for an itemID (from unscaled confirmed sales), or nil.
-- returns: basePrice, baseIlvl, baseReq, voteCount, conflictsSeen
function Atr_VendorBase_Get (itemID)
	local rec = Atr_VendorLearnedDB().base[tonumber(itemID or 0) or 0];
	if (rec and rec.n and rec.n > 0 and rec.p and rec.p > 0) then return rec.p, rec.il, rec.rq, rec.n, (rec.x or 0); end;
	return nil;
end

-- Base-candidate registry: remember, per itemID, the LOWEST-ilvl cached
-- sighting (bp/il/rq move together as one tuple).  Scaling is mostly
-- up-scaling, so the lowest sighting is the closest thing to the true
-- base the cache has ever shown us.  agreed=true marks sightings where
-- the server tooltip matched the cache (server-confirmed variant); an
-- agreed sighting may upgrade an equal-il unagreed record but never
-- displaces a lower-il one.
function Atr_VendorCB_Note (itemID, bp, bil, brq, agreed)
	itemID = tonumber (itemID or 0) or 0;
	bp  = tonumber (bp or 0) or 0;
	bil = tonumber (bil or 0) or 0;
	if (itemID <= 0 or bp <= 0 or bil <= 0) then return; end;
	local db  = Atr_VendorLearnedDB();
	local rec = db.cb[itemID];
	if (rec == nil) then rec = { v = {} }; db.cb[itemID] = rec; end;
	if (rec.v == nil) then		-- migrate a v1 single-slot record into the map
		rec.v = {};
		if (rec.p and rec.il) then rec.v[rec.il] = { p = rec.p, rq = rec.rq or 0, ag = rec.ag }; end;
		rec.p = nil; rec.il = nil; rec.rq = nil; rec.ag = nil;
	end
	local e = rec.v[bil];
	if (e == nil) then
		local n, hi = 0, nil;		-- cap at 12 variants; evict the HIGHEST il (low sightings are the irreplaceable base evidence)
		for vil in pairs (rec.v) do n = n + 1; if (hi == nil or vil > hi) then hi = vil; end; end;
		if (n >= 12) then
			if (bil >= hi) then return; end;
			rec.v[hi] = nil;
		end
		rec.v[bil] = { p = bp, rq = tonumber(brq or 0) or 0, ag = (agreed and 1 or nil) };
	elseif (agreed) then		-- server-confirmed sighting refreshes and pins the tuple
		e.p = bp; e.rq = tonumber(brq or 0) or 0; e.ag = 1;
	elseif (e.ag ~= 1) then		-- unagreed refresh never displaces an agreed price
		e.p = bp; e.rq = tonumber(brq or 0) or 0;
	end
end

-- Gated vendor-price PREDICTION for scale-variants never sold (stage 2).
-- Harvest #3 established p = base_price x m, where m rises with the scale
-- jump and saturates at a per-track plateau: x2.0 (stock), x2.5 (custom
-- range, id >= 2M), x7.5 (the cheap track: armor with base req <= 15, and
-- RANGED weapons with base req <= 15 - even custom-range ones; melee
-- weapons stay on the 2.0/2.5 track at any req).  An instance whose il
-- EQUALS the base candidate's il is x1.0 - the candidate price applies
-- directly, even when the required level is shifted (8117, 4108).
-- Beyond that, only saturated jumps are predictable; the small-jump
-- rising curve (delta 1 to gate-1: conflicting x1.0 vs x1.2 samples)
-- and down-scales are unmapped, so those return nil and the tooltip
-- keeps "unknown (scaled)".
-- In-sample accuracy on harvest #3: 45/52 within 2% of the confirmed
-- price on rows passing the gate (~92% excluding rows whose recorded
-- inputs are provably cache-polluted).  Input priority: trusted .base
-- facts (uncontested only, x == 0) > the persisted .cb lowest-il
-- sighting > live cached GetItemInfo.  The .cb layer exists because
-- owning an item rewrites the on-disk cache to that instance, which
-- after /reload collapses delta to ~0 and wrongly gates the
-- prediction.  All of these are still estimates from untrusted
-- fields - hence "Predicted vendor", never the learned '*'.
-- STAGE 4: CROSS-ITEM SHAPE ESTIMATE (harvest #5b).
-- Every stage above needs this item's OWN data.  When there is none, fall back
-- to the shape the four measured ladders share, expressed as normalised
-- saturation s = ln(m)/ln(cap) against the cached template il.  m = cap^s.
--
-- Leave-one-ITEM-out accuracy over 17 confirmed rungs (each ladder predicted
-- from only the other three, using the same untrusted cached inputs the live
-- addon has): median 8.3% error, 15/17 within 25%, 17/17 within 50%.  Dropping
-- 2167, whose cached template is known cache-polluted: median 9.0%, worst
-- 28.2%, 12/13 within 25%.
--
-- This is an ESTIMATE and is labelled as one - never the '*' of a confirmed
-- sale, never the "Predicted" of the gated plateau rule.  n = 4 ladders; expect
-- it to improve as more are measured.
local ATR_VP_SHAPE = {
	{  1, 0.124 }, {  2, 0.155 }, {  4, 0.248 }, {  6, 0.334 },
	{  8, 0.630 }, { 11, 0.965 }, { 14, 1.000 },
};
-- DOWN-SCALE SHAPE (refit 2026-07).  The flat x0.42 (retuned earlier from a
-- 205-row backtest) is replaced: with more confirmed down rungs it is now clear
-- the down region DECLINES with depth rather than sitting at one value.  Fitted
-- to the clean down cluster across seven items (Gloomshroud, Mantle of Thieves,
-- Doomspike, Flintrock + the 2167/2168/4661 ladders):
--
--   delta   -4     -5     -6     -7     -8
--   m      0.43   0.42   0.38   0.35   0.33      (flat-extended past -8)
--
-- Down-region backtest over the confirmed rungs (delta <= -4), old flat vs this:
--   ALL down rows   n=26   13.7% -> 2.9%  median error
--   CLEAN cluster   n=19   10.1% -> 0.9%  median error
-- The remaining rows are the documented bimodal case: below about -7 a
-- cache-polluted bil puts the row's true delta near 0 (m ~0.89-1.27), so NO
-- down constant fits them.  They stay the weakest thing this function returns,
-- exactly as before - the refit helps the physically-down rows, not these.
local ATR_VP_DOWN = {
	{ -4, 0.43 }, { -5, 0.42 }, { -6, 0.38 }, { -7, 0.35 }, { -8, 0.33 },
};
local ATR_VP_SHELF		= 2;		-- upper edge: 4661 il26/27/28 all x1.0
local ATR_VP_SHELF_LO	= -3;		-- lower edge: measured, not assumed

-- piecewise-linear lookup on the down shape (knots DESCEND in delta),
-- flat-extended past both ends
local function Atr_VendorDown_M (delta)
	if (delta >= ATR_VP_DOWN[1][1])            then return ATR_VP_DOWN[1][2]; end
	if (delta <= ATR_VP_DOWN[#ATR_VP_DOWN][1]) then return ATR_VP_DOWN[#ATR_VP_DOWN][2]; end
	local i;
	for i = 1, #ATR_VP_DOWN - 1 do
		local a, b = ATR_VP_DOWN[i], ATR_VP_DOWN[i+1];
		if (delta <= a[1] and delta >= b[1]) then
			local t = (delta - a[1]) / (b[1] - a[1]);
			return a[2] + t * (b[2] - a[2]);
		end
	end
	return 0.42;		-- unreachable; defensive
end

-- OBSERVED CAP FLOOR (self-healing track correction).
-- The harvest-3 brq<=15 boundary picks the track, and the live backtest showed
-- it is INCOMPLETE: 19 of 156 rows with brq>15 priced above 2.6x, up to 7.51x,
-- with nothing observable (quality, class, subclass, slot) separating them.
-- Rather than keep guessing the rule, remember what each item has actually
-- been seen to do: db.trk[itemID] holds the highest p/bp ratio ever confirmed
-- for it, and that becomes a FLOOR on its cap.
--
-- This is also self-correcting when bp itself is polluted low: a low bp makes
-- estimates low AND makes the observed ratio high, so raising the cap pushes
-- the estimate back toward truth rather than compounding the error.
-- CLAMPED at the highest track ever observed.  The stored ratio is only
-- meaningful against the bp it was measured from, and the cache can move
-- underneath it (harness11's contested-base case: a ratio of 18.75 recorded
-- against one bp, then applied to another, predicted 2.5x too high).  No cap
-- above 7.5 has ever been seen, so a larger ratio is evidence that the BASE
-- was wrong, not that the cap is high - discard it rather than trust it.
local ATR_VP_MAXCAP = 7.5;

function Atr_VendorTrack_Floor (itemID)

	local db = Atr_VendorLearnedDB();
	if (type (db) ~= "table" or type (db.trk) ~= "table") then return nil; end

	local r = tonumber (db.trk[itemID]);
	if (r == nil or r <= 0) then return nil; end
	if (r > ATR_VP_MAXCAP) then return nil; end
	return r;
end


-- returns price, reason  (or nil, reason) for a delta with no item-specific data
function Atr_VendorShape_Estimate (bp, cap, delta)

	bp    = tonumber (bp or 0) or 0;
	cap   = tonumber (cap or 0) or 0;
	delta = tonumber (delta or 0) or 0;
	if (bp <= 0 or cap <= 1) then return nil, "no base price to estimate from"; end

	if (delta >= ATR_VP_SHELF_LO and delta <= ATR_VP_SHELF) then
		return math.floor (bp + 0.5), string.format ("estimate: base shelf (delta %+d, x1.0)", delta);
	end

	if (delta < 0) then
		local dm = Atr_VendorDown_M (delta);
		return math.floor ((bp * dm) + 0.5),
			   string.format ("estimate: down-scale delta %d (x%.2f)", delta, dm);
	end

	local s;								-- interpolate the shared shape
	if (delta >= ATR_VP_SHAPE[#ATR_VP_SHAPE][1]) then
		s = 1.0;
	else
		local i;
		for i = 1, #ATR_VP_SHAPE - 1 do
			local a, b = ATR_VP_SHAPE[i], ATR_VP_SHAPE[i+1];
			if (delta >= a[1] and delta <= b[1]) then
				local t = (delta - a[1]) / (b[1] - a[1]);
				s = a[2] + t * (b[2] - a[2]);
				break;
			end
		end
	end
	if (s == nil) then return nil, "delta outside the fitted shape"; end

	return math.floor ((bp * (cap ^ s)) + 0.5),
		   string.format ("estimate: delta +%d, %d%% saturated on the x%.1f track", delta, math.floor (s * 100 + 0.5), cap);
end

local ATR_VP_RANGED = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true };
local ATR_VP_MELEE  = { INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true, INVTYPE_THROWN = true };

function Atr_VendorPredict_Get (itemID, ilvl, req)
	itemID = tonumber (itemID or 0) or 0;
	ilvl   = tonumber (ilvl or 0) or 0;
	if (itemID <= 0 or ilvl <= 0) then return nil, "bad arguments"; end;
	-- CONFIRMED-RUNG INTERPOLATION (harvest #4): if this item has learned
	-- prices at other ilvls, they outrank every cache-derived input.
	-- Between two rungs: log-linear interpolation.  Above the top rung:
	-- flat extension, but only when the two highest rungs AGREE (a proven
	-- flat plateau - 2167 sold for 848c at both il33 and il42).  Below
	-- the bottom rung: no prediction (the down region is unmapped).
	local db2  = Atr_VendorLearnedDB();
	local pre  = itemID..":";
	local plen = string.len (pre);
	local lowIl, lowP, highIl, highP, maxIl, maxP, max2Il, max2P;
	for k, o in pairs (db2.obs) do
		if (string.sub (k, 1, plen) == pre and o.p and o.p > 0) then
			local ril = tonumber (string.match (k, "^%d+:(%d+):"));
			if (ril and ril == ilvl) then
				return o.p, "learned at il"..ilvl.." (rq variant)";		-- same il, different rq: pricing is per-il (deterministic)
			elseif (ril) then
				if (ril < ilvl and (lowIl == nil or ril > lowIl))  then lowIl = ril; lowP = o.p; end;
				if (ril > ilvl and (highIl == nil or ril < highIl)) then highIl = ril; highP = o.p; end;
				if (maxIl == nil or ril > maxIl) then
					max2Il = maxIl; max2P = maxP; maxIl = ril; maxP = o.p;
				elseif (max2Il == nil or ril > max2Il) then
					max2Il = ril; max2P = o.p;
				end
			end
		end
	end
	if (lowIl and highIl) then
		local t = (ilvl - lowIl) / (highIl - lowIl);
		return math.floor (lowP * ((highP / lowP) ^ t) + 0.5), "interpolated between learned il"..lowIl.." and il"..highIl;
	end
	if (maxIl and max2Il and maxP == max2P and ilvl > maxIl) then
		return maxP, "flat plateau above learned il"..max2Il.."/il"..maxIl;
	end
	local _, _, _, bil, brq, _, _, _, eloc, _, bp = GetItemInfo (itemID);
	if (bp and bp > 0 and bil and bil > 0) then Atr_VendorCB_Note (itemID, bp, bil, brq); end;		-- the live cache is itself a sighting
	local tb, tbi, tbr, _, tx = Atr_VendorBase_Get (itemID);
	if (tb and tx == 0 and tbi == ilvl) then return tb, "x1.0 trusted base facts"; end;		-- x1.0 against trusted base facts: strongest exact match
	local cb = Atr_VendorLearnedDB().cb[itemID];		-- persisted per-variant sighting map: survives purchase re-caching + /reload
	if (cb and cb.v) then
		local ex = cb.v[ilvl];
		if (ex and ex.p and ex.p > 0) then return ex.p, "x1.0 sighting at il"..ilvl; end;		-- x1.0: this exact il has been sighted with a price
		for vil, e in pairs (cb.v) do		-- lowest sighting is the base candidate for the plateau math
			if (e.p and e.p > 0 and (bil == nil or bil <= 0 or vil < bil)) then
				bp = e.p; bil = vil;
				if (e.rq and e.rq > 0) then brq = e.rq; end;
			end
		end
	end
	if (tb and tx == 0) then		-- trusted base facts beat every cache view for the plateau inputs
		bp = tb;
		if (tbi and tbi > 0) then bil = tbi; end;
		if (tbr and tbr > 0) then brq = tbr; end;
	end
	if (bp == nil or bp <= 0 or bil == nil or bil <= 0) then return nil, "no priced sighting of this item yet"; end;
	local delta = ilvl - bil;
	if (delta == 0) then return bp, "x1.0 candidate match at il"..bil; end;		-- x1.0: instance il equals the base candidate's il -> candidate price applies (8117/4108: rq shifts alone do not change the price)
	local m, gate;
	if (ATR_VP_RANGED[eloc] and brq and brq <= 15) then
		m = 7.5; gate = 19;		-- ranged obeys the low-req rule even in the custom range (3595664)
	elseif (itemID >= 2000000) then
		m = 2.5; gate = 20;		-- custom plateau is reached later (1616208 still rising at delta 17)
	elseif (ATR_VP_MELEE[eloc]) then
		m = 2.0; gate = 15;		-- melee stays on the 2.0 track even at base req 7-13
	elseif (brq and brq <= 15) then
		m = 7.5; gate = 19;		-- stock armor cheap track; boundary pinned at req 15/16
	else
		m = 2.0; gate = 15;
	end
	local seen = Atr_VendorTrack_Floor (itemID);		-- self-healing: this item has been SEEN above its assigned cap
	if (seen and seen > m) then m = seen; end

	if (delta >= gate) then
		return math.floor ((bp * m) + 0.5), string.format ("x%.1f plateau from candidate il%d (%dc)", m, bil, bp);
	end
	local est, ewhy = Atr_VendorShape_Estimate (bp, m, delta);		-- stage 4: no item-specific data left, use the shared shape
	if (est) then return est, ewhy, true; end
	return nil, ewhy;
end

local function Atr_VendorScanBagItem (bag, slot)
	if (gVendorScanTip == nil) then
		gVendorScanTip = CreateFrame ("GameTooltip", "AtrVendorScanTip", UIParent, "GameTooltipTemplate");
	end
	gVendorScanTip:SetOwner (UIParent, "ANCHOR_NONE");
	gVendorScanTip:ClearLines();
	gVendorScanTip:SetBagItem (bag, slot);
	local _, tipIlvl, tipReq = Atr_TipScaleMismatch (gVendorScanTip, nil, nil);
	gVendorScanTip:Hide();
	return tipIlvl, tipReq;
end

-- server tooltip of a BUYBACK entry: the only way to tell same-name,
-- same-count scale-variants apart at confirmation time.
local function Atr_VendorScanBuyback (slot)
	if (gVendorScanTip == nil) then
		gVendorScanTip = CreateFrame ("GameTooltip", "AtrVendorScanTip", UIParent, "GameTooltipTemplate");
	end
	if (gVendorScanTip.SetBuybackItem == nil) then return nil, nil; end;
	gVendorScanTip:SetOwner (UIParent, "ANCHOR_NONE");
	gVendorScanTip:ClearLines();
	gVendorScanTip:SetBuybackItem (slot);
	local _, tipIlvl, tipReq = Atr_TipScaleMismatch (gVendorScanTip, nil, nil);
	gVendorScanTip:Hide();
	return tipIlvl, tipReq;
end

-- TAINT: never replace the global UseContainerItem.  Blizzard's secure
-- ContainerFrameItemButton_OnClick reads that global, so an addon-written
-- value taints the whole call chain and the client blocks the protected
-- native call ("tainted the call of the secure function
-- 'Atr_Orig_UseContainerItem()'") -- reproduced by opening lootable
-- containers (Clam, Adventurer's Satchel).  hooksecurefunc runs AFTER the
-- native call without tainting it.  Capture still works: the sell is a
-- server round-trip, so on this same frame the bag slot still holds the
-- item and its link/tooltip remain readable.
-- (Post-hook edge: dropping a held item onto a bag slot now passes the
-- CursorHasItem guard because the cursor empties during the call; harmless
-- -- confirmation requires the NEWEST buyback entry to match name+count
-- within 3s, which a placement never produces, and the next real sell
-- overwrites gVendorPendingSale anyway.)
hooksecurefunc ("UseContainerItem", function (bag, slot, onSelf)
	if (MerchantFrame and MerchantFrame:IsShown() and not CursorHasItem() and not onSelf) then
		local link = GetContainerItemLink (bag, slot);
		if (link) then
			local _, cnt = GetContainerItemInfo (bag, slot);
			local iname, _, cQual, cIlvl, cReq, cClass, cSub, _, cSlot, _, cVP = GetItemInfo (link);
			if (iname) then
				local tipIlvl, tipReq = Atr_VendorScanBagItem (bag, slot);
				local scaled = (tipIlvl and cIlvl and cIlvl > 0 and tipIlvl ~= cIlvl) or (tipReq and cReq and cReq > 0 and tipReq ~= cReq);
				local ps = { name=iname, link=link, scaled=(scaled and true or false), count=cnt or 1, itemID=tonumber((zc.ItemIDfromLink (link))), ilvl=tipIlvl or 0, req=tipReq or 0, baseIlvl=cIlvl or 0, baseReq=cReq or 0, basePrice=cVP or 0, qual=cQual or 0, cls=cClass or "", sub=cSub or "", slot=cSlot or "", t=GetTime() };
				table.insert (gVendorPendingSales, ps);
				while (#gVendorPendingSales > 10) do table.remove (gVendorPendingSales, 1); end;
				Atr_VendorCB_Note (ps.itemID, cVP, cIlvl, cReq, not scaled);		-- merchant sightings feed the base-candidate registry too
			end
		end
	end
end);

-- Build tag + /atrvp diagnostics.  /atrvp alone prints the build and DB
-- counts (if it says "unknown command", a STALE AuctionatorHints.lua is
-- deployed).  '/atrvp <itemID|shift-clicked link> [il rq]' dumps the
-- item's GetItemInfo view, base facts, sighting map, learned tuples, and
-- - when il/rq are given - the prediction plus the exact rule that fired.
local ATR_VP_BUILD = "cb2-map+x1 (2026-07-23)";

if (SlashCmdList) then
	SLASH_ATRVENDORPREDICT1 = "/atrvp";
	SlashCmdList["ATRVENDORPREDICT"] = function (msg)
		msg = tostring (msg or "");
		local db = Atr_VendorLearnedDB();
		local id = tonumber (msg:match ("item:(%d+)") or msg:match ("^%s*(%d+)"));
		if (id == nil) then
			local nobs, nbase, ncb, nseed = 0, 0, 0, 0;
			local nx, nsx = 0, 0;			-- tuples that ever sold for two different prices
			for _, o in pairs (db.obs)  do
				nobs  = nobs  + 1;
				if (o.seed and (o.n or 0) == 0) then nseed = nseed + 1; end;
				if ((o.x  or 0) > 0) then nx  = nx  + 1; end;
				if ((o.sx or 0) > 0) then nsx = nsx + 1; end;
			end
			for _ in pairs (db.base) do nbase = nbase + 1; end;
			for _ in pairs (db.cb)   do ncb   = ncb   + 1; end;
			zc.msg_atr ("vendor-predict build "..ATR_VP_BUILD.."  |  obs "..nobs.."  base "..nbase.."  sighted items "..ncb);
			-- Seed readout: how many shipped prices are still untested here, how
			-- many have been field-confirmed by a real sale (pt=="seed" log rows),
			-- and how far those confirmed sales landed from the shipped guess -
			-- the live measure of whether the shared table holds cross-player.
			local npromoted, serr = 0, {};
			for _, s in pairs (db.log or {}) do
				if (s.pt == "seed") then
					npromoted = npromoted + 1;
					if (s.p and s.p > 0 and s.pp) then serr[#serr + 1] = math.abs (s.p - s.pp) / s.p; end;
				end
			end
			local smed = "-";
			if (#serr > 0) then
				table.sort (serr);
				local m = (#serr % 2 == 0) and ((serr[#serr/2] + serr[#serr/2 + 1]) / 2) or serr[math.ceil (#serr/2)];
				smed = string.format ("%.1f%%", m * 100);
			end
			zc.msg_atr ("seed v"..tostring(db.seedver).."  |  "..nseed.." pending  "..npromoted.." field-tested  median err "..smed);
			-- Silent while the price-is-a-server-fact premise holds, which is the
			-- point: any number here is a tuple that sold for two different
			-- prices, and worth chasing before the next seed regeneration.
			if (nx > 0 or nsx > 0) then
				zc.msg_atr ("|cffff8800conflicts|r  "..nx.." tuple(s) sold at two prices  "..nsx.." contradicting the shipped seed  (/atrvp <item> to inspect)");
			end
			zc.msg_atr ("usage: /atrvp <itemID or shift-clicked link> [il rq]");
			return;
		end
		local ail, arq;
		if (msg:find ("|h")) then ail, arq = msg:match ("|r%s+(%d+)%s+(%d+)");
		else ail, arq = msg:match ("^%s*%d+%s+(%d+)%s+(%d+)"); end;
		local _, _, _, gbil, gbrq, _, _, _, geloc, _, gbp = GetItemInfo (id);
		zc.msg_atr ("== vendor-predict "..ATR_VP_BUILD.." | item "..id.." ==");
		zc.msg_atr ("GetItemInfo(id): il "..tostring(gbil).."  rq "..tostring(gbrq).."  sell "..tostring(gbp).."  slot "..tostring(geloc));
		local tb, tbi, tbr, tbn, tbx = Atr_VendorBase_Get (id);
		if (tb) then zc.msg_atr ("base facts: "..tb.."c @ il"..tostring(tbi).."/rq"..tostring(tbr).."  n="..tostring(tbn).." x="..tostring(tbx));
		else zc.msg_atr ("base facts: none"); end;
		local rec = db.cb[id];
		if (rec and rec.v) then
			local s = "";
			for vil, e in pairs (rec.v) do s = s.."  il"..vil.."="..tostring(e.p).."c"..((e.ag == 1) and "(ag)" or ""); end;
			zc.msg_atr ("sightings:"..s);
		elseif (rec and rec.p) then
			zc.msg_atr ("sightings: V1 RECORD il"..tostring(rec.il).."="..tostring(rec.p).."c  << stale build wrote this");
		else
			zc.msg_atr ("sightings: none");
		end
		local pre = tostring (id)..":";
		for k, o in pairs (db.obs) do
			if (string.sub (k, 1, string.len (pre)) == pre) then zc.msg_atr ("learned: "..k.." = "..tostring(o.p).."c (n"..tostring(o.n)..")"); end;
		end
		if (ail) then
			local p, why = Atr_VendorPredict_Get (id, tonumber(ail), tonumber(arq));
			zc.msg_atr ("predict @ il"..ail.."/rq"..tostring(arq).." -> "..(p and (p.."c") or "nil").."  ["..tostring(why).."]");
		end
	end
end

-- sale announcement: chat message for every confirmed merchant sale.
-- Toggle: AUCTIONATOR_SALE_MSG (per-character), checkbox added at runtime to
-- the Tooltips options panel.  All UI wiring is guarded so a differing
-- AuctionatorConfig build degrades to "no checkbox", never to an error.
local gSaleMsgCB = nil;

local function Atr_SaleMsg_EnsureCB ()
	if (Atr_TooltipsOptionsFrame == nil or CreateFrame == nil) then return; end;
	if (gSaleMsgCB == nil) then
		gSaleMsgCB = CreateFrame ("CheckButton", "ATR_saleMsgOpt_CB", Atr_TooltipsOptionsFrame, "UICheckButtonTemplate");
		gSaleMsgCB:SetWidth (24);
		gSaleMsgCB:SetHeight (24);
		gSaleMsgCB:SetPoint ("TOPLEFT", Atr_TooltipsOptionsFrame, "TOPLEFT", 20, -146);		-- below the disenchant row (-120), above the Shift dropdown label (-181)
		local label = _G["ATR_saleMsgOpt_CBText"];
		if (label) then label:SetText (" "..ZT("Announce merchant sales in chat")); end;
	end
	gSaleMsgCB:SetChecked (AUCTIONATOR_SALE_MSG == 1);
end

local function Atr_SaleMsg_Init ()
	if (AUCTIONATOR_SALE_MSG == nil) then AUCTIONATOR_SALE_MSG = 1; end;		-- default: on
	if (type(Atr_SetupTooltipsOptionsFrame) == "function") then
		hooksecurefunc ("Atr_SetupTooltipsOptionsFrame", Atr_SaleMsg_EnsureCB);
	end
	local function Atr_SaleMsg_Apply ()
		if (gSaleMsgCB == nil) then return; end;
		if (gSaleMsgCB:GetChecked()) then AUCTIONATOR_SALE_MSG = 1; else AUCTIONATOR_SALE_MSG = 0; end;
	end

	-- TRAP (found 2026-07): Atr_LoadOptionsSubPanel copies the save function
	-- into the panel's okay field BY VALUE at XML OnLoad, and Blizzard calls
	-- THAT field when Okay is pressed - never the global.  So hooking the
	-- global name alone never ran on Okay and unticking this box silently did
	-- nothing.  Wrap the field; keep the name hook too for direct calls.
	if (type(Atr_TooltipsOptionsFrame_Save) == "function") then
		hooksecurefunc ("Atr_TooltipsOptionsFrame_Save", Atr_SaleMsg_Apply);
	end
	if (Atr_TooltipsOptionsFrame and not Atr_TooltipsOptionsFrame.saleMsgWrapped) then
		Atr_TooltipsOptionsFrame.saleMsgWrapped = true;
		local prevOkay = Atr_TooltipsOptionsFrame.okay;
		Atr_TooltipsOptionsFrame.okay = function (...)
			if (prevOkay) then prevOkay (...); end;		-- the original, not the hooked global: apply once
			Atr_SaleMsg_Apply ();
		end;
	end
	Atr_SaleMsg_EnsureCB();		-- panel may have been set up before login
end

-- record one CONFIRMED sale (announce + learn/base-facts), shared by the
-- confirmation sweep below.
local function Atr_VendorRecordSale (ps, bprice, bqty)
	if (AUCTIONATOR_SALE_MSG == 1) then
		local qtyStr = "";
		if (ps.count > 1) then qtyStr = " x"..ps.count; end;
		zc.msg_atr ((ps.link or ps.name)..qtyStr.." sold for "..zc.priceToMoneyString (bprice));
	end
	local db   = Atr_VendorLearnedDB();
	local unit = math.floor ((bprice / bqty) + 0.5);
	if (ps.scaled) then
		-- CALIBRATION.  Ask the predictor what it WOULD have said before this
		-- sale is stored, so every vendor trip scores the estimator against
		-- ground truth.  Taken before the write, so on a first sale of a tuple
		-- stage 1 cannot see it and the answer is genuinely out-of-sample; pt
		-- records which tier answered so repeat sales (pt="learned") can be
		-- excluded from accuracy stats.
		local pp, pwhy, pest = Atr_VendorPredict_Get (ps.itemID, ps.ilvl, ps.req);
		local key     = ps.itemID..":"..ps.ilvl..":"..ps.req;
		local prior   = db.obs[key];
		local wasSeed = prior and prior.seed and (prior.n or 0) == 0;		-- seed-only, never really sold on this client
		local pt;
		if (pp == nil) then					pt = "none";
		elseif (pest) then					pt = "est";
		elseif (wasSeed) then					pt = "seed";		-- out-of-sample vs the shipped table: the number worth measuring
		elseif (Atr_VendorLearned_Get and Atr_VendorLearned_Get (ps.itemID, ps.ilvl, ps.req)) then pt = "learned";
		elseif (pwhy and pwhy:find ("interpolated")) then pt = "interp";
		else								pt = "plateau"; end

		local rec = db.obs[key];
		if (rec == nil) then rec = { n = 0 }; db.obs[key] = rec; end;

		-- CONFLICT ACCOUNTING.  The whole seed rests on one claim: a confirmed
		-- (itemID, ilvl, req) price is a server fact, identical for every player
		-- and every character.  A tuple that sells twice for two different
		-- prices falsifies that claim for this item, and until now nothing
		-- recorded it -- rec.p was overwritten in place, so n counted sales
		-- rather than agreement and a contradiction left no trace at all.
		-- db.base has had this check since it was written (majority vote, x
		-- counts conflicts); obs is the table the seed actually ships, so it
		-- needs it more.  Counters only: the price still takes the latest
		-- reading, exactly as before.
		--   x  two real sales of the same tuple disagreed
		--   sx a real sale here contradicted the SHIPPED seed price
		if (prior and prior.p and prior.p ~= unit) then
			if (wasSeed) then rec.sx = (rec.sx or 0) + 1;
			else              rec.x  = (rec.x  or 0) + 1; end
		end

		rec.p = unit;
		rec.n = rec.n + 1;
		rec.seed = nil;					-- promoted: a real sale outranks the shipped guess
		local smp = { id=ps.itemID, il=ps.ilvl, rq=ps.req, bil=ps.baseIlvl, brq=ps.baseReq, bp=ps.basePrice, qual=ps.qual, cls=ps.cls, sub=ps.sub, slot=ps.slot, p=rec.p, q=ps.count };
		smp.pp = pp; smp.pt = pt;		-- what the predictor said, and which tier said it
		-- Seller level.  Not part of the tuple key, and deliberately so: the
		-- premise is that price is a function of (itemID, ilvl, req) alone.  But
		-- that is the premise, not a proven fact, and without this field nothing
		-- in the record could test it -- the same tuple sold by a level 39 and a
		-- level 60 produced two identical rows.  When x/sx fires, this is the
		-- first thing to check.  Log-only: the log never ships in the seed.
		smp.lv = UnitLevel ("player");

		-- SELF-HEALING TRACK CORRECTION: remember the highest multiplier this
		-- item has ever actually been seen to reach, as a floor on its cap.
		-- One sale above the assigned cap fixes the item permanently.
		if (ps.basePrice and ps.basePrice > 0 and unit > 0) then
			if (type (db.trk) ~= "table") then db.trk = {}; end
			local ratio = unit / ps.basePrice;
			if (ratio > (db.trk[ps.itemID] or 0)) then db.trk[ps.itemID] = ratio; end
		end
		local base = db.base[ps.itemID];
		if (base and base.n and base.n > 0) then smp.tb = base.p; smp.tbi = base.il; smp.tbr = base.rq; smp.tbn = base.n; end;
		table.insert (db.log, smp);
		while (#db.log > 500) do table.remove (db.log, 1); end;
	elseif (ps.slot and ps.slot ~= "") then
		-- base facts: an UNSCALED buyback-confirmed sale of an equippable
		-- item is the only trusted source for its true base sell price
		-- (only equipment scales, so only equipment needs base facts).
		-- Majority vote self-heals a polluted first sighting (cache held
		-- a scaled variant that then got sold "unscaled"): a price match
		-- bumps n, a mismatch decrements it, and at n = 0 the record is
		-- replaced.  x counts conflicts ever seen so offline analysis
		-- can distrust contested items.
		local base = db.base[ps.itemID];
		if (base == nil or base.n == nil or base.n <= 0) then
			db.base[ps.itemID] = { p = unit, il = ps.ilvl, rq = ps.req, n = 1, x = (base and base.x or 0) };
		elseif (base.p == unit) then
			base.n = base.n + 1;
			if (ps.ilvl and ps.ilvl > 0) then base.il = ps.ilvl; end;
			if (ps.req  and ps.req  > 0) then base.rq = ps.req;  end;
		else
			base.n = base.n - 1;
			base.x = (base.x or 0) + 1;
			if (base.n <= 0) then db.base[ps.itemID] = { p = unit, il = ps.ilvl, rq = ps.req, n = 1, x = base.x }; end;
		end
	end
end

-- Seed fresh installs with the shipped confirmed-price table
-- (AuctionatorVendorSeed.lua -> ATR_VENDOR_SEED).  Non-destructive: a real
-- observation (seed flag absent, or n > 0) is NEVER touched; a seed-only entry
-- (n == 0, seed == 1) may be refreshed when the shipped table's version bumps.
-- Prices are server-deterministic (base x multiplier, both server properties),
-- so a confirmed (itemID:ilvl:req) price is a global fact, valid for every
-- player.  Idempotent - safe to run every login.
local function Atr_VendorSeed_Merge ()
	if (type(ATR_VENDOR_SEED) ~= "table") then return; end;
	local db  = Atr_VendorLearnedDB();
	local ver = (ATR_VENDOR_SEED.meta and ATR_VENDOR_SEED.meta.built) or "?";
	local prev = db.seedver;						-- last applied seed version
	for k, p in pairs (ATR_VENDOR_SEED.obs or {}) do
		if (type(p) == "number" and p > 0) then
			local rec = db.obs[k];
			if (rec == nil) then
				db.obs[k] = { p = p, n = 0, seed = 1 };			-- fresh seed
			elseif (rec.seed and (rec.n or 0) == 0 and prev ~= ver) then
				rec.p = p;								-- refresh seed-only entry on version bump
			end
			-- rec with seed==nil or n>0 is a real observation: leave it.
		end
	end
	for id, r in pairs (ATR_VENDOR_SEED.base or {}) do
		if (type(r) == "table" and r.p and r.p > 0) then
			local b = db.base[id];
			if (b == nil or (b.seed and (b.n or 0) <= 1 and prev ~= ver)) then
				db.base[id] = { p = r.p, il = r.il or 0, rq = r.rq or 0, n = 1, seed = 1 };
			end
			-- a real base fact (seed==nil, majority-voted) is left untouched.
		end
	end
	db.seedver = ver;
end

-- The inverse of the merge above (BACKLOG item 13).  Measured on a real dump:
-- 1338 of 1437 `obs` entries and 449 of 518 `base` entries are seed echoes --
-- about 152 KB of a 1.14 MB saved-variables file spent on a private copy of a
-- table that already ships inside the addon, in AuctionatorVendorSeed.lua.
--
-- So drop them at logout and let the merge put them back at login.  The merge is
-- already idempotent and already documented as safe to run every login, so this
-- needs no new machinery -- only a rule for what may be dropped.
--
-- THE RULE IS "ONLY WHAT THE SEED WILL PUT BACK IDENTICALLY", and it is checked
-- against the seed value rather than trusted from the flag.  A seeded entry that
-- has since been CONFIRMED by a real sale is a field-tested fact, not an echo,
-- and diff-vendor-seed.lua reports those separately for exactly this reason. So
-- an entry is only dropped when the shipped seed holds the same price for it and
-- nothing has been learned on top: that makes the round trip provably lossless
-- rather than merely probably.
--
-- If the addon is ever run without its seed file the merge returns early and
-- these do not come back -- but a table whose only source is the addon itself is
-- not data the addon can lose independently of being installed.
local function Atr_VendorSeed_DropEchoes ()

	if (type (ATR_VENDOR_SEED) ~= "table") then return 0; end
	if (type (AUCTIONATOR_VENDOR_LEARNED) ~= "table") then return 0; end

	local db = AUCTIONATOR_VENDOR_LEARNED;
	local n  = 0;

	if (type (db.obs) == "table" and type (ATR_VENDOR_SEED.obs) == "table") then
		local k, rec;
		for k, rec in pairs (db.obs) do
			local seeded = ATR_VENDOR_SEED.obs[k];
			if (type (rec) == "table" and rec.seed and (rec.n or 0) == 0
				and type (seeded) == "number" and rec.p == seeded) then
				db.obs[k] = nil;
				n = n + 1;
			end
		end
	end

	if (type (db.base) == "table" and type (ATR_VENDOR_SEED.base) == "table") then
		local id, b;
		for id, b in pairs (db.base) do
			local r = ATR_VENDOR_SEED.base[id];
			if (type (b) == "table" and b.seed and (b.n or 0) <= 1 and (b.x or 0) == 0
				and type (r) == "table" and b.p == r.p
				and (b.il or 0) == (r.il or 0) and (b.rq or 0) == (r.rq or 0)) then
				db.base[id] = nil;
				n = n + 1;
			end
		end
	end

	return n;
end

local function Atr_VendorLearn_OnEvent (self, event)
	if (event == "PLAYER_LOGIN") then Atr_SaleMsg_Init(); Atr_VendorSeed_Merge(); return; end;
	if (event == "PLAYER_LOGOUT") then Atr_VendorSeed_DropEchoes(); return; end;
	if (event == "MERCHANT_CLOSED") then gVendorPendingSales = {}; return; end;
	local q = gVendorPendingSales;
	if (#q == 0) then return; end;
	local now = GetTime();
	for i = #q, 1, -1 do
		if (now - q[i].t > 3) then table.remove (q, i); end;
	end
	if (#q == 0) then return; end;
	local nbb = GetNumBuybackItems();
	if (nbb == nil or nbb < 1) then return; end;
	-- sweep the newest buyback slots (several entries can land between
	-- events during a sell spree) and attach each to the queued sale it
	-- IDENTIFIES: name + count + the buyback entry's own server-tooltip
	-- il/req.  Same-name same-count scale-variants are only told apart by
	-- that tooltip - matching name+count alone cross-attributed prices
	-- (live case study #5).  When the tooltip is unreadable, fall back to
	-- FIFO name+count.
	local lo = nbb - 7;
	if (lo < 1) then lo = 1; end;
	for bslot = nbb, lo, -1 do
		local bname, _, bprice, bqty = GetBuybackItemInfo (bslot);
		if (bname and bprice and bprice > 0) then
			local bil, brq = Atr_VendorScanBuyback (bslot);
			for pi = 1, #q do
				local ps = q[pi];
				if (ps.itemID and ps.name == bname and ps.count == bqty
						and (bil == nil or ps.ilvl == 0 or bil == ps.ilvl)
						and (brq == nil or ps.req == 0 or brq == ps.req)) then
					Atr_VendorRecordSale (ps, bprice, bqty);
					table.remove (q, pi);
					break;
				end
			end
		end
		if (#q == 0) then break; end;
	end
end

local gVendorLearnFrame = CreateFrame ("Frame");
gVendorLearnFrame:RegisterEvent ("PLAYER_LOGIN");
gVendorLearnFrame:RegisterEvent ("PLAYER_LOGOUT");		-- item 13: shed the seed echoes on the way out
gVendorLearnFrame:RegisterEvent ("MERCHANT_UPDATE");
gVendorLearnFrame:RegisterEvent ("PLAYER_MONEY");
gVendorLearnFrame:RegisterEvent ("MERCHANT_CLOSED");
gVendorLearnFrame:SetScript ("OnEvent", Atr_VendorLearn_OnEvent);
-- FINDER_TAB end: vendor price learning ------------------------------------

-- FINDER_TAB begin: verified auction prices per scale-variant --------------
--
-- The name-keyed price DB (gAtr_ScanDB) deliberately refuses scaled equipment
-- (Fdr_PriceDB_Update rule 2): one name covers every scale-variant of an item,
-- so a name key would file six different items under one price and hand the
-- Buy tab a number that belongs to somebody else's variant.
--
-- Verification removes exactly that objection.  Once the Verify sweep has read
-- a listing's SERVER tooltip we know its real item level, and the list API's
-- own `level` return gave us its real required level (ASCENSION-CLIENT-NOTES:
-- the two per-instance truths that exist).  That is the same
-- (itemID, ilvl, req) tuple the vendor DB is keyed on, and it identifies a
-- scale-variant exactly -- so a verified auction price CAN be stored, and the
-- tooltip can find it again by reading the same tuple off the rendered
-- tooltip.  This is what fills the "Auction: unknown" line on a scaled item
-- sitting in your bags.
--
-- SavedVariables AUCTIONATOR_AH_VARIANT (account-wide, like the vendor DB):
--   .obs["itemID:ilvl:req"] = { p = lowest unit buyout, t = when, s = session }
--   .s = session counter, bumped once per Verify sweep / group window
--   .c = live entry count, so the cap check costs nothing per write
--
-- Two rules make the number honest:
--
-- 1. LOWEST WITHIN A SESSION, REPLACED ACROSS SESSIONS.  Several listings of
--    one variant is the normal case, and the cheapest is the market price; but
--    a price from a previous sweep is a stale observation, not a competing
--    offer, so a new sweep OVERWRITES rather than mins against it.  Minning
--    across sessions would pin the number to the cheapest listing ever seen
--    and it would never rise again.
--
-- 2. AGE IS SHOWN, NEVER HIDDEN.  A vendor price is a property of the item and
--    keeps forever; an auction price is a snapshot of a market and rots.  The
--    tooltip prints the age past a day and the entry is dropped past a month,
--    so nothing here can quietly present last month's market as today's.
local ATR_AHV_MAXAGE = 30 * 24 * 3600;
local ATR_AHV_CAP    = 3000;

function Atr_AHVariant_Enabled ()
	if (AUCTIONATOR_FINDER_SETTINGS == nil) then return true; end
	return (AUCTIONATOR_FINDER_SETTINGS.ahVariant ~= false);		-- default ON
end

function Atr_AHVariantDB ()
	if (type(AUCTIONATOR_AH_VARIANT) ~= "table")     then AUCTIONATOR_AH_VARIANT = {}; end;
	if (type(AUCTIONATOR_AH_VARIANT.obs) ~= "table") then AUCTIONATOR_AH_VARIANT.obs = {}; end;
	if (type(AUCTIONATOR_AH_VARIANT.s) ~= "number")  then AUCTIONATOR_AH_VARIANT.s = 0; end;
	if (type(AUCTIONATOR_AH_VARIANT.c) ~= "number")  then AUCTIONATOR_AH_VARIANT.c = 0; end;
	return AUCTIONATOR_AH_VARIANT;
end

function Atr_AHVariant_Key (itemID, ilvl, req)
	itemID = tonumber (itemID or 0) or 0;
	ilvl   = tonumber (ilvl or 0) or 0;
	req    = tonumber (req or 0) or 0;
	if (itemID <= 0 or ilvl <= 0 or req <= 0) then return nil; end
	return itemID..":"..ilvl..":"..req;
end

-- One Verify sweep (or one group window) is one session.  Bumped up front so
-- every listing it verifies shares a stamp, which is what lets rule 1 tell
-- "another listing of this variant, right now" from "what it cost last week".
function Atr_AHVariant_NewSession ()
	local db = Atr_AHVariantDB ();
	db.s = (db.s or 0) + 1;
	return db.s;
end

-- Drops everything past ATR_AHV_MAXAGE, and if that was not enough to get
-- under the cap, the oldest entries after it.  Recounts as it goes: .c is an
-- incremental tally and this is the one place that can put it back in step.
function Atr_AHVariant_Prune (db, now)

	db  = db or Atr_AHVariantDB ();
	now = now or (time and time()) or 0;

	local keep, n = {}, 0;
	local k, v;
	for k, v in pairs (db.obs) do
		if (type (v) == "table" and v.p and v.p > 0 and (now - (v.t or 0)) < ATR_AHV_MAXAGE) then
			keep[k] = v;
			n = n + 1;
		end
	end

	-- still over the cap: sort what is left by age and keep the newest half of
	-- the cap, so this cannot run again on the very next write
	if (n > ATR_AHV_CAP) then
		local ages = {};
		for k, v in pairs (keep) do tinsert (ages, { k = k, t = v.t or 0 }); end
		table.sort (ages, function (a, b) return a.t > b.t; end);
		local trimmed = {};
		local i;
		for i = 1, math.floor (ATR_AHV_CAP / 2) do
			if (ages[i]) then trimmed[ages[i].k] = keep[ages[i].k]; end
		end
		keep = trimmed;
		n = math.floor (ATR_AHV_CAP / 2);
	end

	db.obs = keep;
	db.c   = n;
	return n;
end

-- Records one verified listing.  unit is the PER-ITEM buyout; a bid-only
-- listing has no buyout and must never be read as a price (the token market is
-- full of them - ASCENSION-CLIENT-NOTES), so the caller passes nothing for it
-- and this refuses anything <= 0.
function Atr_AHVariant_Note (itemID, ilvl, req, unit, now)

	if (not Atr_AHVariant_Enabled ()) then return false; end

	local key = Atr_AHVariant_Key (itemID, ilvl, req);
	if (key == nil) then return false; end

	unit = tonumber (unit or 0) or 0;
	if (unit <= 0) then return false; end

	local db  = Atr_AHVariantDB ();
	now = now or (time and time()) or 0;

	local rec = db.obs[key];
	if (type (rec) ~= "table") then
		db.obs[key] = { p = unit, t = now, s = db.s };
		db.c = (db.c or 0) + 1;
		if (db.c > ATR_AHV_CAP) then Atr_AHVariant_Prune (db, now); end
		return true;
	end

	if (rec.s ~= db.s) then			-- a fresh snapshot replaces an old one
		rec.p = unit; rec.t = now; rec.s = db.s;
		return true;
	end

	if (unit < (rec.p or 0)) then	-- same sweep: the cheapest listing wins
		rec.p = unit; rec.t = now;
		return true;
	end

	return false;
end

-- returns: unit price, age in seconds -- or nil when this variant is unknown
function Atr_AHVariant_Get (itemID, ilvl, req, now)

	if (not Atr_AHVariant_Enabled ()) then return nil; end

	local key = Atr_AHVariant_Key (itemID, ilvl, req);
	if (key == nil) then return nil; end

	local rec = Atr_AHVariantDB ().obs[key];
	if (type (rec) ~= "table" or not rec.p or rec.p <= 0) then return nil; end

	now = now or (time and time()) or 0;
	local age = now - (rec.t or 0);
	if (age >= ATR_AHV_MAXAGE) then return nil; end		-- expired but not yet swept
	if (age < 0) then age = 0; end						-- clock moved; do not claim the future

	return rec.p, age;
end

-- "6d" / "3h" for the tooltip.  Under an hour reads as current and gets no
-- suffix at all: the point of the marker is to flag a number old enough to
-- have moved, not to timestamp every hover.
function Atr_AHVariant_AgeText (age)

	age = tonumber (age or 0) or 0;
	if (age < 3600) then return nil; end

	local days = math.floor (age / 86400);
	if (days >= 1) then return days.."d"; end

	return math.floor (age / 3600).."h";
end
-- FINDER_TAB end: verified auction prices per scale-variant ----------------

-- FINDER_TAB begin: Finder row tooltip override ---------------------------
--
-- ShowTipWithPricing derives tipIlvl/tipReq from the RENDERED tooltip.  For
-- a Finder row that tooltip is SetHyperlink output, i.e. whichever scale
-- variant the client cached first -- identical for every row sharing a
-- name, because the links are byte-identical (ASCENSION-CLIENT-NOTES).  So
-- every listing of one item got the SAME predicted vendor value.
--
-- The Finder sets Atr_Finder_TipOverride for the single SetHyperlink call
-- it makes per hover and clears it immediately afterwards, so no other
-- tooltip in the game is affected.  Both halves of the tuple are required:
-- the vendor DB is keyed (itemID, ilvl, req) and a real req paired with a
-- cached ilvl would simply miss and fall through to a worse guess.
--
-- It also publishes Atr_Finder_TipItemLines.  NumLines() HERE is exactly
-- the item body's line count: this runs as the post-hook of the original
-- SetHyperlink and before anything below appends a price line.  The Finder
-- needs that boundary to know which lines it may overwrite.
function Atr_Finder_TipApplyOverride (tip, scaleMismatch, tipIlvl, tipReq)

	if (Atr_Finder_TipOverride == nil or tip ~= GameTooltip) then
		return scaleMismatch, tipIlvl, tipReq;
	end

	Atr_Finder_TipItemLines = (tip.NumLines and tip:NumLines()) or nil;

	local ov = Atr_Finder_TipOverride;
	if (ov.il and ov.il > 0 and ov.rq and ov.rq > 0) then
		return true, ov.il, ov.rq;		-- a mismatch by construction
	end

	return scaleMismatch, tipIlvl, tipReq;
end
-- FINDER_TAB end: Finder row tooltip override -----------------------------

-- FINDER_TAB begin: highest-value tooltip label ---------------------------
--
-- A tooltip can carry four money lines - Vendor, Auction, Auction median,
-- Disenchant - and the question they exist to answer is "what is this thing
-- worth to me".  The line holding the largest figure now names itself in
-- green, so the answer is legible at a glance instead of by eye-comparing
-- four money strings.  Only the LABEL changes colour; the values keep the
-- white/grey scheme that already distinguishes the vendor tiers.
--
-- Only lines that render a NUMBER compete.  "unknown", "BOP", "Quest Item"
-- and "unknown (scaled)" carry no value at all, and neither does a zero.  A
-- predicted or estimated vendor price DOES compete: it is a number the user
-- can see, and excluding it would paint the green label on a line showing a
-- visibly smaller figure, which reads as a bug rather than as caution.
--
-- Fewer than two competitors means there is nothing to compare, so nothing
-- is highlighted: a lone green label would state a preference it has not
-- earned.  Ties highlight every line that holds the top figure - Auction and
-- Auction median agreeing is the common case and is true information.
function Atr_TipBestPrice (...)

	local best, n = nil, 0;

	local i;
	for i = 1, select ("#", ...) do
		local v = select (i, ...);
		if (type (v) == "number" and v > 0) then
			n = n + 1;
			if (best == nil or v > best) then best = v; end
		end
	end

	if (n < 2) then return nil; end

	return best;
end

-- FINDER_TAB: the colour code (|cFFrrggbb form) for the best-price highlight.
-- Configurable in the Tooltips options panel and stored as a hex "RRGGBB"
-- string; falls back to the default blue when unset or malformed so a bad
-- saved value can never break a tooltip.
function Atr_TipsHighlightCode ()

	local hex = AUCTIONATOR_TIPS_HL_COLOR;
	if (type (hex) == "string" and hex:match ("^%x%x%x%x%x%x$")) then
		return "|cFF"..hex;
	end

	return "|cFF3399FF";		-- default blue
end

-- Wraps a label in the highlight colour when its own line holds the best price.
-- ONLY the label is wrapped: xstring carries its own |c...|r for the stack
-- multiplier, and a |r returns to the FontString's own colour rather than to an
-- enclosing |c, so wrapping both would leave the suffix uncoloured and a stray
-- |r behind.  best == nil (nothing to compare) returns the label untouched.
function Atr_TipLabel (text, price, best)

	if (best and price and price == best) then
		return Atr_TipsHighlightCode()..text.."|r";
	end

	return text;
end
-- FINDER_TAB end: highest-value tooltip label -----------------------------

-- FINDER_TAB: crafted-goods profitability on item tooltips ----------------
-- Adds "Craft cost" + "Craft profit"/"Craft loss" lines to a tooltip when the
-- item is one we have a harvested recipe for.  Reagent cost comes from the
-- SELL tab's craft DB (Atr_Craft_GetCraftCost, filled by opening profession
-- windows and viewing recipe tooltips); the sell side is Auctionator's own
-- auction price.  With a profession window open, hovering a craftable item
-- then shows at a glance whether making it to sell is profitable or the raw
-- materials cost more than the finished craft.
--
--   num / showStackPrices / xstring mirror the surrounding tooltip: when the
--   rest of the tip is showing per-stack prices we scale both figures by the
--   stack too, so the craft lines never disagree with the Auction line above.
--
--   MULTI-OUTPUT RECIPES are shown PER CRAFT, tagged with the yield.  Distilled
--   Flask of the Unyielding makes 3, so "what does it cost" has two honest
--   answers -- one flask, or one press of Create -- and an unlabelled figure
--   sitting under a per-item Auction price is read as whichever the reader was
--   expecting.  One craft is the answer worth the tooltip room: it is what a
--   press of Create actually costs and earns, and it is what the profit sort
--   ranks on (Atr_ProfSort_BuildOrder), so the two agree by construction.  The
--   tag is what keeps it honest against the per-item Auction line above --
--   these lines say "x3" where that one says nothing.  Showing both scales was
--   the first shape of this; it was correct and it was clutter (owner,
--   2026-08-19).
--
--   skillIndex, when the caller has it, is the trade skill row this tooltip is
--   for.  See the first source below -- it is worth more than it looks.
function Atr_AddCraftProfitToTip (tip, link, itemName, num, showStackPrices, xstring, skillIndex)

	if (tip == nil or link == nil) then return; end
	if (AUCTIONATOR_A_TIPS ~= 1) then return; end			-- crafting economics are auction info
	if (type(Atr_Craft_GetCraftCost) ~= "function") then return; end

	xstring = xstring or "";

	local craftCost, madeCount;
	local isCraftable = false;

	-- FIRST: the row this tooltip is actually for, when the caller knows it.
	--
	-- Both sources below have to FIND the recipe that makes this item, and both
	-- match on the produced item's ID or on the row's NAME.  That match fails
	-- outright for a row named after its action rather than its product --
	-- "Transmute: Arcanite" makes "Arcanite Bar" -- and it fails again for any
	-- row this client hands back no item link for (the quirk the
	-- SetTradeSkillItem hook already works around by reading the link back off
	-- the rendered tooltip).  Transmutes hit both at once, which is why they
	-- showed no craft lines at all rather than a wrong number.
	--
	-- The index needs no match, cannot be wrong, and is cheaper than the scan it
	-- replaces.  It also proves the recipe EXISTS even when a reagent cannot be
	-- priced, so an unpriced transmute now says "cost unknown" instead of
	-- staying silent.
	if (skillIndex and type(Atr_ProfSort_RowCost) == "function") then
		isCraftable = true;
		craftCost, madeCount = Atr_ProfSort_RowCost (skillIndex);
	end

	-- Then the background-harvested recipe DB, which is the only source with the
	-- profession window closed (a bag or auction house tooltip).
	if (craftCost == nil or craftCost <= 0) then
		craftCost, madeCount = Atr_Craft_GetCraftCost (link, itemName);		-- per item
	end

	-- Fall back to a LIVE read of the open profession window.  On the Ascension
	-- client the harvest into the recipe DB can miss recipes (reagent item links
	-- come back nil), so the harvested cost above is often absent even while the
	-- window is open in front of you -- but the live window has the data.  This
	-- also tells us the recipe EXISTS (isCraftable) even when a reagent can't be
	-- priced, so we can say "cost unknown" instead of nothing.
	if ((craftCost == nil or craftCost <= 0) and type(Atr_Craft_LiveCostForItem) == "function") then
		local liveCost, found, liveMade = Atr_Craft_LiveCostForItem (link, itemName);
		if (liveCost and liveCost > 0) then craftCost = liveCost; madeCount = liveMade; end
		if (found) then isCraftable = true; end
	end
	if (not isCraftable and type(Atr_Craft_HasRecipe) == "function" and Atr_Craft_HasRecipe (link, itemName)) then
		isCraftable = true;
	end

	-- No total?  Don't stay silent on something we KNOW is craftable -- that
	-- reads as "no craft support" when the real cause is a reagent we can't
	-- price yet (scan the AH, or visit the vendor that sells it).  For an item
	-- that isn't a recipe at all, add nothing.
	if (craftCost == nil or craftCost <= 0) then
		if (isCraftable) then
			tip:AddDoubleLine (ZT("Craft cost")..xstring, "|cFFAAAAAA"..ZT("unknown").."|r");
		end
		return;
	end

	-- The produced item's own auction price -- needed only for the profit line,
	-- NOT for the cost line.  Craft cost is worth showing on its own (it tells
	-- you what a craft ties up), so we no longer bail when this is missing.
	local sellPrice = (itemName and Atr_GetAuctionPrice) and tonumber (Atr_GetAuctionPrice (itemName)) or nil;

	-- Match the stack scaling the rest of the tooltip used (see the Auction line).
	if (num and showStackPrices) then
		craftCost = craftCost * num;
		if (sellPrice) then sellPrice = sellPrice * num; end
	end

	-- Does this recipe make more than one?  Under the Shift stack multiplier
	-- every line on the tooltip is already scaled by the hovered stack and says
	-- so through xstring; a second multiplier there would be two scales arguing
	-- on one tooltip, so we leave those lines per item, exactly as they always
	-- were, and let xstring speak.
	madeCount = tonumber (madeCount) or 1;
	if (madeCount < 1) then madeCount = 1; end
	local perCraft = (madeCount > 1) and not (num and showStackPrices);

	if (perCraft) then
		craftCost = craftCost * madeCount;
		if (sellPrice) then sellPrice = sellPrice * madeCount; end
		xstring = xstring.."|cFFAAAAFF x"..madeCount.."|r";
	end

	tip:AddDoubleLine (ZT("Craft cost")..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (craftCost));

	if (sellPrice == nil or sellPrice <= 0) then			-- cost known, market price not
		tip:AddDoubleLine (ZT("Craft profit")..xstring, "|cFFAAAAAA"..ZT("unknown").."|r");
		return;
	end

	local margin = sellPrice - craftCost;
	if (margin >= 0) then
		tip:AddDoubleLine (ZT("Craft profit")..xstring, "|cFF44FF44"..zc.priceToMoneyString (margin).."|r");
	else
		tip:AddDoubleLine (ZT("Craft loss")..xstring, "|cFFFF4444-"..zc.priceToMoneyString (-margin).."|r");
	end
end
-- FINDER_TAB end: crafted-goods profitability -----------------------------

-- FINDER_TAB: enchanting rows on the trade skill window -------------------
-- An enchant produces no item, and every item-shaped lookup below is therefore
-- empty for one: GetTradeSkillItemLink hands back an |Henchant: link, GetItemInfo
-- returns nothing for it, so ShowTipWithPricing could only ever print "Auction
-- unknown" and the craft lines never appeared at all.  What IS sold is the
-- enchant applied to a vellum -- "Scroll of <enchant name>" -- and
-- AuctionatorFinderProfession.lua already knows how to price exactly that: the
-- scroll's auction price on the sell side, reagents plus the right vellum on the
-- cost side (see the ENCHANTING block there, and Atr_ProfSort_RowCost).  The
-- profit sort has been ranking enchanting rows on those figures for a while; all
-- that was missing was showing them.
--
-- So an enchant row gets its OWN lines, built from the trade skill index rather
-- than from an item link, and ShowTipWithPricing is skipped for it entirely --
-- there is no item for it to say anything true about, and its "Auction unknown"
-- sitting above a real scroll price would only contradict it.
--
-- Returns true when it handled the row, false when the caller should carry on.
function Atr_AddEnchantTradeSkillTip (tip, skillIndex)

	if (tip == nil or skillIndex == nil) then return false; end
	if (type (Atr_ProfSort_RowIsEnchant) ~= "function") then return false; end
	if (not Atr_ProfSort_RowIsEnchant (skillIndex)) then return false; end

	local rowName = GetTradeSkillInfo (skillIndex);
	if (rowName == nil or rowName == "") then return false; end

	if (AUCTIONATOR_A_TIPS ~= 1) then return true; end		-- auction info switched off entirely

	-- Same ALT gate, and the same breadcrumb, as every other addon price line
	-- (see revealExtra in ShowTipWithPricing) -- an enchant row must not be the
	-- one tooltip in the addon that ignores the setting.
	if (AUCTIONATOR_TIPS_ALT == 1 and not IsAltKeyDown()) then
		tip:AddLine ("|cFF808080"..ZT("Hold <Alt> for auction prices").."|r");
		tip:Show();
		return true;
	end

	local scroll = Atr_ProfSort_RowSellName (skillIndex) or rowName;	-- the scroll, for an enchant row
	local sell   = Atr_GetAuctionPrice   and tonumber (Atr_GetAuctionPrice (scroll)) or nil;
	local median = Atr_GetMeanPrice      and tonumber (Atr_GetMeanPrice (scroll))    or nil;
	local cost   = Atr_ProfSort_RowCost  and Atr_ProfSort_RowCost (skillIndex)       or nil;

	-- Name what the figures are about.  The row says "Enchant Weapon - Ninja's
	-- Focus" and every price under it is for an item with a different name, so
	-- without this line the numbers look like they belong to the enchant.
	tip:AddLine ("|cFF808080"..ZT("Sells as")..":|r |cFFFFFFFF"..scroll.."|r");

	if (sell and sell > 0) then
		tip:AddDoubleLine (ZT("Auction"), "|cFFFFFFFF"..zc.priceToMoneyString (sell));
	else
		tip:AddDoubleLine (ZT("Auction"), "|cFFAAAAAA"..ZT("unknown").."|r");
	end

	if (median and median > 0) then
		tip:AddDoubleLine (ZT("Auction median"), "|cFFFFFFFF"..zc.priceToMoneyString (median));
	end

	-- The vellum is not in the reagent list the window shows, but it is in this
	-- cost, so the label says so rather than leaving the total looking wrong by
	-- the price of a vellum.
	if (cost and cost > 0) then
		tip:AddDoubleLine (ZT("Craft cost").."|cFF808080 (+vellum)|r", "|cFFFFFFFF"..zc.priceToMoneyString (cost));
	else
		tip:AddDoubleLine (ZT("Craft cost").."|cFF808080 (+vellum)|r", "|cFFAAAAAA"..ZT("unknown").."|r");
	end

	if (cost and cost > 0 and sell and sell > 0) then
		local margin = sell - cost;
		if (margin >= 0) then
			tip:AddDoubleLine (ZT("Craft profit"), "|cFF44FF44"..zc.priceToMoneyString (margin).."|r");
		else
			tip:AddDoubleLine (ZT("Craft loss"), "|cFFFF4444-"..zc.priceToMoneyString (-margin).."|r");
		end
	else
		tip:AddDoubleLine (ZT("Craft profit"), "|cFFAAAAAA"..ZT("unknown").."|r");
	end

	tip:Show();
	return true;
end
-- FINDER_TAB end: enchanting rows -----------------------------------------

-- skillIndex is passed only by the trade skill hook, and only for the RECIPE
-- hover: it is the row the tooltip is for, which spares the craft-cost lines a
-- search that cannot always succeed (see Atr_AddCraftProfitToTip).  Every other
-- caller leaves it nil and nothing changes for them.
local function ShowTipWithPricing (tip, link, num, skillIndex)

	if (link == nil) then
		return;
	end

--[[
	if (num == "tradeskill") then
	
		local skill = link;
	
		local n;
		for n = 1,GetTradeSkillNumReagents(skill) do
			local rname, _, rnum = GetTradeSkillReagentInfo(skill, n);
			local rlink = GetTradeSkillReagentItemLink (skill, n);
			zc.md (skill, rlink, rnum);
		end
	
		return;
	end
]]--

	local itemName, itemLink, itemRarity, itemLevel, itemMinLevel, itemType, _, _, _, _, itemVendorPrice = GetItemInfo (link);

	-- Recipe items expose their reagents only in the tooltip; harvest them for
	-- the SELL tab's Crafted Goods Margin filter (see Atr_Craft_HarvestRecipeTooltip).
	if (itemType == "Recipe" and Atr_Craft_HarvestRecipeTooltip) then
		Atr_Craft_HarvestRecipeTooltip (tip, itemName);
	end

	local itemID = zc.ItemIDfromLink (link);
	itemID = tonumber(itemID);

	-- FINDER_TAB: "Qty: N" (+ per-character bag/bank locations on a held
	-- modifier).  Implemented in AuctionatorFinderItemCount.lua so this file
	-- doesn't grow another feature; guarded so a load-order slip can't error.
	if (type (Atr_ItemCount_AddToTip) == "function") then
		Atr_ItemCount_AddToTip (tip, itemID);
	end

	local vendorPrice	= 0;
	local auctionPrice	= 0;
    local auctionMedianPrice = 0;
	local dePrice		= nil;
	
	local scaleMismatch, tipIlvl, tipReq = Atr_TipScaleMismatch (tip, itemLevel, itemMinLevel);		-- FINDER_TAB
	scaleMismatch, tipIlvl, tipReq = Atr_Finder_TipApplyOverride (tip, scaleMismatch, tipIlvl, tipReq);		-- FINDER_TAB

	if (AUCTIONATOR_V_TIPS == 1) then vendorPrice	= itemVendorPrice; end;
	if (AUCTIONATOR_A_TIPS == 1) then auctionPrice	= Atr_GetAuctionPrice (itemName); end;
    if (AUCTIONATOR_A_TIPS == 1) then auctionMedianPrice = Atr_GetMeanPrice (itemName); end;

	-- FINDER_TAB: NPC-sold trade good?  If we've learned this item from a vendor
	-- (Atr_GetNPCPrice), its going cost is the fixed NPC price, so we show that
	-- and suppress the misleading AH line rather than pricing it off the market.
	local npcPrice = (itemID and Atr_GetNPCPrice) and Atr_GetNPCPrice (itemID) or nil;
	local isNPCReagent = (npcPrice ~= nil and npcPrice > 0);
	if (isNPCReagent) then
		auctionPrice = nil; auctionMedianPrice = nil;		-- never show an AH price for a vendor-sold reagent
	end

	-- FINDER_TAB: flag when the auction figure is a suffix-variant estimate
	-- rather than a real listing for this name -- i.e. Atr_GetAuctionPrice fell
	-- back to Atr_GetAHVariantEstimate because the base name isn't listed
	-- directly (random-suffix gear like the crafted "Dreamdust Slippers").  Only
	-- then do we render it as "~... (est)" so an estimate never reads as exact.
	local auctionIsEst, auctionEstCount = false, nil;
	if (AUCTIONATOR_A_TIPS == 1 and not isNPCReagent and auctionPrice
	    and not (gAtr_ScanDB and gAtr_ScanDB[itemName])
	    and not (Atr_GetMostRecentSale and Atr_GetMostRecentSale (itemName))) then
		local est, cnt = Atr_GetAHVariantEstimate (itemName);
		if (est) then auctionIsEst = true; auctionEstCount = cnt; end
	end
	if (AUCTIONATOR_D_TIPS == 1) then dePrice		= Atr_CalcDisenchantPrice (itemType, itemRarity, itemLevel); end;

	if (itemID and tipIlvl and itemVendorPrice and itemVendorPrice > 0 and itemLevel and itemLevel > 0) then		-- FINDER_TAB: every equipment sighting feeds the base-candidate registry
		Atr_VendorCB_Note (itemID, itemVendorPrice, itemLevel, itemMinLevel, not scaleMismatch);
	end
	local vendorLearned = false;		-- FINDER_TAB: real price observed at a merchant for this exact scale-variant
	local vendorSeeded  = false;		-- FINDER_TAB: obs hit that is a shipped seed guess, not the user's own confirmed sale (rendered '~*')
	local vendorPredicted = false;		-- FINDER_TAB: gated formula estimate for an unsold variant (see VENDOR-PRICE-RESEARCH.md)
	local vendorEstimate  = false;		-- FINDER_TAB: stage-4 cross-item shape estimate - the weakest tier, rendered '~... (est)'
	if (scaleMismatch and AUCTIONATOR_V_TIPS == 1 and itemID and tipIlvl) then
		local learned = Atr_VendorLearned_Get (itemID, tipIlvl, tipReq);
		if (learned) then
			vendorPrice = learned; vendorLearned = true;
			local lrec = Atr_VendorLearnedDB().obs[itemID..":"..(tipIlvl or 0)..":"..(tipReq or 0)];
			vendorSeeded = (lrec and lrec.seed and (lrec.n or 0) == 0) and true or false;		-- shipped guess: never really sold on this client
		else
			local predicted, _, isEstimate = Atr_VendorPredict_Get (itemID, tipIlvl, tipReq);
			if (predicted) then
				vendorPrice = predicted;
				vendorPredicted = true;
				vendorEstimate = isEstimate and true or false;		-- weaker tier: shared-shape guess, not this item's own data
			end
		end
	end
    
	-- FINDER_TAB: a verified price for THIS exact scale-variant beats the
	-- name-keyed one, which is an average over every variant sharing the name
	-- (and for scaled gear is usually absent entirely, since the feed refuses
	-- to write it).  Gated on having the tuple, NOT on scaleMismatch: an item
	-- you own re-caches to its own instance, so your own bags are exactly
	-- where the cache AGREES with the tooltip and the mismatch flag is false
	-- (ASCENSION-CLIENT-NOTES).  Reading it here, before the stack multiply,
	-- keeps it a per-item price like every other figure on the tooltip.
	local auctionVariant, auctionAge = false, nil;
	if (AUCTIONATOR_A_TIPS == 1 and itemID and tipIlvl and tipReq) then
		local vprice, vage = Atr_AHVariant_Get (itemID, tipIlvl, tipReq);
		if (vprice) then
			auctionPrice	= vprice;
			auctionVariant	= true;
			auctionAge		= vage;
		end
	end

	local xstring = "";
	local showStackPrices = IsShiftKeyDown();

	if (AUCTIONATOR_SHIFT_TIPS == 2) then
		showStackPrices = not IsShiftKeyDown();
	end

	-- FINDER_TAB: unless ALT is held, every addon price line EXCEPT the Vendor
	-- line (learned / predicted / estimated tiers all count as Vendor) stays
	-- hidden, keeping the tooltip clean at a glance.  Governed by
	-- AUCTIONATOR_TIPS_ALT (1 = hide until ALT, 0 = always show).
	local revealExtra = true;
	if (AUCTIONATOR_TIPS_ALT == 1 and not IsAltKeyDown()) then
		revealExtra = false;
	end

	if (num and showStackPrices) then
		if (auctionPrice)	then	auctionPrice = auctionPrice * num;	end;
        if (auctionMedianPrice) then auctionMedianPrice = auctionMedianPrice * num; end;
		if (vendorPrice)	then	vendorPrice  = vendorPrice  * num;	end;
		if (dePrice)  		then	dePrice  	 = dePrice  * num;	end;
		if (npcPrice)		then	npcPrice     = npcPrice     * num;	end;
		xstring = "|cFFAAAAFF x"..num.."|r";
	end;

	if (vendorPrice == nil) then
		vendorPrice = 0;
	end

	-- FINDER_TAB: which money line is the largest.  Decided BEFORE the first
	-- line is added, because the answer is needed the moment its label is
	-- written.  Each candidate is the value its line will actually RENDER as a
	-- number, or nil where the line renders text instead; vendorUnknown and
	-- isBOP/isQuest are computed here and REUSED by the drawing code below, so
	-- the two cannot drift into disagreeing about what is on screen.  It also
	-- sits after the stack multiply, so every candidate is read from the same
	-- variable its line prints and the two can never be a factor of num apart.
	local vendorUnknown = (scaleMismatch and not vendorLearned and not vendorPredicted);

	local bonding, isBOP, isQuest;
	if (AUCTIONATOR_A_TIPS == 1) then
		bonding = Atr_GetBonding (itemID);
		isBOP   = (bonding == 1);
		isQuest = (bonding == 4 or bonding == 5);
	end

	local vendorShown, auctionShown, medianShown, deShown;
	if (AUCTIONATOR_V_TIPS == 1 and not vendorUnknown)        then vendorShown  = vendorPrice;        end
	if (AUCTIONATOR_A_TIPS == 1 and not isBOP and not isQuest) then auctionShown = auctionPrice;       end
	if (AUCTIONATOR_A_TIPS == 1)                               then medianShown  = auctionMedianPrice; end
	if (AUCTIONATOR_D_TIPS == 1)                               then deShown      = dePrice;            end

	-- FINDER_TAB: when the extra lines are hidden they must not count towards
	-- the highlight either -- with only the Vendor line visible there is
	-- nothing to compare, so nothing should be painted.  Clearing the shown
	-- values here keeps Atr_TipBestPrice's "fewer than two competitors" rule
	-- honest about what is actually on screen.
	if (not revealExtra) then
		auctionShown = nil; medianShown = nil; deShown = nil;
	end

	local bestPrice = Atr_TipBestPrice (vendorShown, auctionShown, medianShown, deShown);

	-- FINDER_TAB: Auction and Auction median agreeing is the common case, and
	-- highlighting both reads as noise.  When they tie for best the Auction line
	-- keeps the highlight (it is the figure to act on) and the median yields --
	-- so medianBest only holds the best price when the median STRICTLY beats the
	-- auction line, i.e. it is the sole top figure.
	local medianBest = bestPrice;
	if (medianShown and auctionShown and medianShown == auctionShown) then
		medianBest = nil;
	end

	-- vendor info

	if (AUCTIONATOR_V_TIPS == 1 and vendorPrice > 0) then
		local vpadding = Atr_CalcTTpadding (vendorPrice, auctionPrice);
		if (vendorUnknown) then		-- FINDER_TAB: different scale-variant, never sold, not predictable
			tip:AddDoubleLine (ZT("Vendor")..xstring, "|cFFAAAAAAunknown (scaled)|r");
		elseif (vendorEstimate) then		-- FINDER_TAB: weakest tier - cross-item shape, ~8% median error (harvest #5b)
			tip:AddDoubleLine (Atr_TipLabel (ZT("Vendor"), vendorShown, bestPrice)..xstring, "|cFFBBBBBB~|r|cFFDDDDDD"..zc.priceToMoneyString (vendorPrice).."|r|cFFAAAAAA (est)|r");
		elseif (vendorPredicted) then		-- FINDER_TAB: gated estimate - labeled, never '*'
			tip:AddDoubleLine (Atr_TipLabel (ZT("Predicted vendor"), vendorShown, bestPrice)..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (vendorPrice));
		elseif (vendorSeeded) then		-- FINDER_TAB: '~*' = shipped seed price (server-deterministic guess), not a sale you made
			tip:AddDoubleLine (Atr_TipLabel (ZT("Vendor"), vendorShown, bestPrice)..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (vendorPrice).."|cFFAAAAFF~*|r");
		elseif (vendorLearned) then		-- FINDER_TAB: '*' = learned from a real sale of this variant
			tip:AddDoubleLine (Atr_TipLabel (ZT("Vendor"), vendorShown, bestPrice)..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (vendorPrice).."|cFFAAAAFF*|r");
		else
			tip:AddDoubleLine (Atr_TipLabel (ZT("Vendor"), vendorShown, bestPrice)..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (vendorPrice))
		end
	end
	
	-- auction info

	if (revealExtra and AUCTIONATOR_A_TIPS == 1) then

		-- FINDER_TAB: bonding is resolved with the candidates above (same call,
		-- same gate) so the highlight and this branch agree by construction
		if (isNPCReagent) then		-- FINDER_TAB: vendor-sold reagent -> show the NPC price, never the AH
			tip:AddDoubleLine (ZT("NPC price")..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (npcPrice));
		elseif (isBOP) then
			tip:AddDoubleLine (ZT("Auction")..xstring, "|cFFFFFFFF"..ZT("BOP").."  ");
		elseif (isQuest) then
			tip:AddDoubleLine (ZT("Auction")..xstring, "|cFFFFFFFF"..ZT("Quest Item").."  ");			
		elseif (auctionVariant) then		-- FINDER_TAB: '*' = a verified price for this exact scale-variant
			local agetxt = Atr_AHVariant_AgeText (auctionAge);
			tip:AddDoubleLine (Atr_TipLabel (ZT("Auction"), auctionShown, bestPrice)..xstring,
				"|cFFFFFFFF"..zc.priceToMoneyString (auctionPrice).."|cFFAAAAFF*|r"
				..(agetxt and ("|cFF888888 "..agetxt.."|r") or ""));
		elseif (auctionIsEst) then		-- FINDER_TAB: median across suffixed variants of an unlisted base name
			local cnttxt = (auctionEstCount and auctionEstCount > 0) and ("|cFF888888 ("..auctionEstCount..")|r") or "";
			tip:AddDoubleLine (Atr_TipLabel (ZT("Auction"), auctionShown, bestPrice)..xstring,
				"|cFFBBBBBB~|r|cFFDDDDDD"..zc.priceToMoneyString (auctionPrice).."|r|cFFAAAAAA (est)|r"..cnttxt);
		elseif (auctionPrice ~= nil) then
			tip:AddDoubleLine (Atr_TipLabel (ZT("Auction"), auctionShown, bestPrice)..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (auctionPrice));
		else
			tip:AddDoubleLine (ZT("Auction")..xstring, "|cFFFFFFFF"..ZT("unknown").."  ");
		end
        if (auctionMedianPrice ~= nil) then
            tip:AddDoubleLine (Atr_TipLabel (ZT("Auction median"), medianShown, medianBest)..xstring, "|cFFFFFFFF"..zc.priceToMoneyString (auctionMedianPrice));
        end
	end

	-- disenchanting info

	if (revealExtra and AUCTIONATOR_D_TIPS == 1 and dePrice ~= nil) then
		if (dePrice > 0) then
			tip:AddDoubleLine (Atr_TipLabel (ZT("Disenchant"), deShown, bestPrice)..xstring, "|cFFFFFFFF"..zc.priceToMoneyString(dePrice));
		else
			tip:AddDoubleLine (ZT("Disenchant")..xstring, "|cFFFFFFFF"..ZT("unknown").."  ");
		end
	end

	local showDetails = true;
	
	if (AUCTIONATOR_DE_DETAILS_TIPS == 1) then showDetails = IsShiftKeyDown(); end;
	if (AUCTIONATOR_DE_DETAILS_TIPS == 2) then showDetails = IsControlKeyDown(); end;
	if (AUCTIONATOR_DE_DETAILS_TIPS == 3) then showDetails = IsAltKeyDown(); end;
	if (AUCTIONATOR_DE_DETAILS_TIPS == 4) then showDetails = false; end;
	if (AUCTIONATOR_DE_DETAILS_TIPS == 5) then showDetails = true; end;
	
	if (revealExtra and showDetails and dePrice ~= nil) then
		Atr_AddDEDetailsToTip (tip, itemType, itemRarity, itemLevel, Atr_DEReqLevel(itemID));
	end

	-- crafted-goods profitability
	--
	-- FINDER_TAB: for any item we have a harvested recipe for (see
	-- Atr_Craft_GetCraftCost / Atr_Craft_Harvest), compare its current auction
	-- price to what the reagents cost to craft.  With a profession window open
	-- and hovering the produced item, this tells you at a glance whether
	-- crafting to sell turns a profit or the raw materials cost more than the
	-- finished craft would fetch.  Gated on Auction tips being on, since the
	-- comparison needs the auction price; only appears for craftable items
	-- whose reagents we can fully price, so normal tooltips stay untouched.
	if (revealExtra) then
		Atr_AddCraftProfitToTip (tip, link, itemName, num, showStackPrices, xstring, skillIndex);
	end

	-- FINDER_TAB: while the extra lines are hidden behind ALT, leave a faint
	-- one-line breadcrumb so the prices are discoverable.  Only shown when there
	-- is actually something to reveal (Auction or Disenchant tips enabled).
	if (not revealExtra and (AUCTIONATOR_A_TIPS == 1 or AUCTIONATOR_D_TIPS == 1)) then
		tip:AddLine ("|cFF808080"..ZT("Hold <Alt> for auction prices").."|r");
	end

	tip:Show()

end

-----------------------------------------

hooksecurefunc (GameTooltip, "SetBagItem",
	function(tip, bag, slot)
		local _, num = GetContainerItemInfo(bag, slot);
		ShowTipWithPricing (tip, GetContainerItemLink(bag, slot), num);
	end
);

hooksecurefunc (GameTooltip, "SetAuctionItem",
	function (tip, type, index)
		local _, _, num = GetAuctionItemInfo(type, index);
		ShowTipWithPricing (tip, GetAuctionItemLink(type, index), num);
	end
);

hooksecurefunc (GameTooltip, "SetAuctionSellItem",
	function (tip)
		local name, _, count = GetAuctionSellItemInfo();
		local __, link = GetItemInfo(name);
		ShowTipWithPricing (tip, link, num);
	end
);


hooksecurefunc (GameTooltip, "SetLootItem",
	function (tip, slot)
		if LootSlotIsItem(slot) then
			local link, _, num = GetLootSlotLink(slot);
			ShowTipWithPricing (tip, link, num);
		end
	end
);

hooksecurefunc (GameTooltip, "SetLootRollItem",
	function (tip, slot)
		local _, _, num = GetLootRollItemInfo(slot);
		ShowTipWithPricing (tip, GetLootRollItemLink(slot), num);
	end
);


hooksecurefunc (GameTooltip, "SetInventoryItem",
	function (tip, unit, slot)
		ShowTipWithPricing (tip, GetInventoryItemLink(unit, slot), GetInventoryItemCount(unit, slot));
	end
);

hooksecurefunc (GameTooltip, "SetGuildBankItem",
	function (tip, tab, slot)
		local _, num = GetGuildBankItemInfo(tab, slot);
		ShowTipWithPricing (tip, GetGuildBankItemLink(tab, slot), num);
	end
);

-- A focused search/filter EditBox swallows the Alt/Shift/Ctrl keys, so the
-- client's modifier tracker never sees them pressed and IsAltKeyDown() reads
-- false.  That silently hid the Alt-gated reagent "Qty/locations" lines while
-- the cursor still blinked in the profession window's filter box -- the fix the
-- player had found by hand was to press Escape (drop the box's focus) first.
-- Clearing that keyboard focus for them, the moment they hover a reagent, lets
-- the modifier keys register again.  Best-effort and fully guarded: on a client
-- where we can't find the focused box we simply do nothing.
local function Atr_ClearProfSearchFocus ()
	-- Preferred: the client's own "who owns the keyboard" accessor, when present.
	if (type (GetCurrentKeyBoardFocus) == "function") then
		local ok, eb = pcall (GetCurrentKeyBoardFocus);
		if (ok and eb and eb.HasFocus and eb.ClearFocus and eb:HasFocus()) then
			eb:ClearFocus();
			return;
		end
	end

	-- Fallback: walk the profession window's frames for a focused EditBox and
	-- drop it.  Bounded so a surprise frame tree can't spin.
	local root = TradeSkillFrame;
	if (root == nil or type (root.GetChildren) ~= "function") then return; end
	local stack, guard = { root }, 0;
	while (#stack > 0 and guard < 400) do
		guard = guard + 1;
		local f = table.remove (stack);
		if (type (f) == "table") then
			if (f.HasFocus and f.ClearFocus and f:HasFocus ()) then
				f:ClearFocus ();
				return;
			end
			if (type (f.GetChildren) == "function") then
				for _, k in ipairs ({ f:GetChildren () }) do stack[#stack + 1] = k; end
			end
		end
	end
end

-- The reagent/recipe the trade-skill tooltip is currently showing, remembered so
-- a modifier press can re-render exactly that tooltip (below).
local gAtr_TSTip = { skill = nil, id = nil, owner = nil };

hooksecurefunc (GameTooltip, "SetTradeSkillItem",
	function (tip, skill, id)
		local link = GetTradeSkillItemLink(skill);
		local num  = GetTradeSkillNumMade(skill);
		if id then
			link = GetTradeSkillReagentItemLink(skill, id);
			num = select (3, GetTradeSkillReagentInfo(skill, id));
		end

		-- Ascension quirk: GetTradeSkillReagentItemLink (and GetTradeSkillItemLink)
		-- can return nil for the given skill index -- most reliably reproduced with
		-- the profession window's search/filter bar active.  That left reagent
		-- hovers with no price or "Qty/locations" line, even though the reagent's
		-- own tooltip rendered fine.  This is a hooksecurefunc, so the stock
		-- SetTradeSkillItem call it follows has ALREADY drawn the item onto the
		-- tooltip; recover the link straight off the rendered tooltip whenever the
		-- index-based lookup comes back empty, which is independent of the filter.
		if (link == nil and tip and tip.GetItem) then
			link = select (2, tip:GetItem());
		end

		-- Remember what this tooltip is showing, then drop any lingering search-box
		-- focus so the player's Alt press actually registers (see the helper and
		-- the MODIFIER_STATE_CHANGED refresh below).
		gAtr_TSTip.skill = skill;
		gAtr_TSTip.id    = id;
		gAtr_TSTip.owner = (tip and tip.GetOwner) and (tip:GetOwner ()) or nil;
		pcall (Atr_ClearProfSearchFocus);

		-- An enchanting row makes no item, so the item-shaped path below has
		-- nothing to work with and prints "Auction unknown"; it gets its own
		-- lines instead.  Only the RECIPE hover is diverted -- a reagent hover
		-- (id given) is an ordinary item and goes the ordinary way.  pcall'd
		-- because a tooltip must never be the thing that errors.
		if (id == nil) then
			local ok, handled = pcall (Atr_AddEnchantTradeSkillTip, tip, skill);
			if (ok and handled) then return; end
		end

		-- Hand the row index down for a RECIPE hover only.  A reagent hover is an
		-- ordinary item that may itself be craftable by some other row, so it
		-- must go through the normal item-to-recipe lookup, not this row.
		ShowTipWithPricing (tip, link, num, (id == nil) and skill or nil);
	end
);

-- Live-refresh the trade-skill tooltip when a modifier key changes.  Without
-- this, pressing Alt while already hovering a reagent does nothing (the tooltip
-- is only built on hover, and nothing rebuilds it on a key change), so the
-- Alt-gated location lines would only ever appear if Alt happened to be held at
-- the instant of the hover.  When Alt/Shift/Ctrl toggles and the trade-skill
-- tooltip is still the one on screen, we re-run SetTradeSkillItem for the same
-- reagent -- our hook above then re-adds (or removes) the location lines for the
-- new modifier state.  MODIFIER_STATE_CHANGED does not fire while an EditBox
-- holds focus, but the hover already cleared that focus, so by now it flows.
if (type (CreateFrame) == "function") then
	local mf = CreateFrame ("Frame");
	mf:RegisterEvent ("MODIFIER_STATE_CHANGED");
	mf:SetScript ("OnEvent", function ()
		if (GameTooltip == nil or type (GameTooltip.IsShown) ~= "function" or not GameTooltip:IsShown ()) then return; end
		if (gAtr_TSTip.skill == nil) then return; end
		if (type (GameTooltip.SetTradeSkillItem) ~= "function") then return; end
		-- Only if this tooltip is still the trade-skill one we last drew (its owner
		-- is unchanged), so we never hijack some other tooltip that is now showing.
		local owner = (GameTooltip.GetOwner) and GameTooltip:GetOwner () or nil;
		if (owner ~= gAtr_TSTip.owner) then return; end
		pcall (function ()
			if (gAtr_TSTip.id) then GameTooltip:SetTradeSkillItem (gAtr_TSTip.skill, gAtr_TSTip.id);
			else                    GameTooltip:SetTradeSkillItem (gAtr_TSTip.skill); end
		end);
	end);
end

hooksecurefunc (GameTooltip, "SetTradePlayerItem",
	function (tip, id)
		local _, _, num = GetTradePlayerItemInfo(id);
		ShowTipWithPricing (tip, GetTradePlayerItemLink(id), num);
	end
);

hooksecurefunc (GameTooltip, "SetTradeTargetItem",
	function (tip, id)
		local _, _, num = GetTradeTargetItemInfo(id);
		ShowTipWithPricing (tip, GetTradeTargetItemLink(id), num);
	end
);

hooksecurefunc (GameTooltip, "SetQuestItem",
	function (tip, type, index)
		local _, _, num = GetQuestItemInfo(type, index);
		ShowTipWithPricing (tip, GetQuestItemLink(type, index), num);
	end
);

hooksecurefunc (GameTooltip, "SetMerchantItem",
	function(tip, merchantID)
		local itemLink = GetMerchantItemLink(merchantID)
		local _, _, _, num = GetMerchantItemInfo(merchantID)
		ShowTipWithPricing (tip, itemLink, num);
	end
);

hooksecurefunc (GameTooltip, "SetQuestLogItem",
	function (tip, type, index)
		local num, _;
		if type == "choice" then
			_, _, num = GetQuestLogChoiceInfo(index);
		else
			_, _, num = GetQuestLogRewardInfo(index)
		end

		ShowTipWithPricing (tip, GetQuestLogItemLink(type, index), num);
	end
);

hooksecurefunc (GameTooltip, "SetInboxItem",
	function (tip, index, attachIndex)
		local _, _, num = GetInboxItem(index, attachIndex);
		ShowTipWithPricing (tip, GetInboxItemLink(index, attachIndex), num);
	end
);

hooksecurefunc (GameTooltip, "SetSendMailItem",
	function (tip, id)
		local name, _, num = GetSendMailItem(id)
		local name, link = GetItemInfo(name);
		ShowTipWithPricing (tip, link, num);
	end
);

hooksecurefunc (GameTooltip, "SetHyperlink",
	function (tip, itemstring, num)
		local name, link = GetItemInfo (itemstring);
		ShowTipWithPricing (tip, link, num);
	end
);

hooksecurefunc (ItemRefTooltip, "SetHyperlink",
	function (tip, itemstring)
		local name, link = GetItemInfo (itemstring);
		ShowTipWithPricing (tip, link);
	end
);










