local addonName, addonTable = ...; 
local zc = addonTable.zc;

KM_NULL_STATE	= 0;
KM_PREQUERY		= 1;
KM_INQUERY		= 2;
KM_POSTQUERY	= 3;
KM_ANALYZING	= 4;
KM_SETTINGSORT	= 5;

local AUCTION_CLASS_WEAPON = 1;
local AUCTION_CLASS_ARMOR  = 2;

local gAllScans = {};

local BIGNUM = 999999999999;

local ATR_SORTBY_NAME_ASC = 0;
local ATR_SORTBY_NAME_DES = 1;
local ATR_SORTBY_PRICE_ASC = 2;
local ATR_SORTBY_PRICE_DES = 3;

-----------------------------------------

AtrScan = {};
AtrScan.__index = AtrScan;

-----------------------------------------

AtrSearch = {};
AtrSearch.__index = AtrSearch;

-----------------------------------------

function Atr_NewSearch (itemName, exact, rescanThreshold, callback)

	local srch = {};
	setmetatable (srch, AtrSearch);
	srch:Init (itemName, exact, rescanThreshold, callback);

	return srch;
end

-----------------------------------------

function AtrSearch:Init (searchText, exact, rescanThreshold, callback)

	if (searchText == nil) then
		searchText = "";
	end

	self.origSearchText = searchText;
	
	if (not exact) then
		if (zc.StringStartsWith (searchText, "\"") and zc.StringEndsWith (searchText, "\"")) then
			searchText = string.sub (searchText, 2, searchText:len()-1);
			exact = true;
		end
	end		

	self.searchText			= searchText;
	self.exact				= exact;
	self.processing_state	= KM_NULL_STATE
	self.current_page		= -1
	self.items				= {};
	self.query				= Atr_NewQuery();
	self.sortedScans		= nil;
	self.sortHow			= ATR_SORTBY_PRICE_ASC;
	self.callback			= callback;
	
	if (exact) then	

		if (rescanThreshold and rescanThreshold > 0) then
			local scan = Atr_FindScan (searchText);
			if (scan and (time() - scan.whenScanned) <= rescanThreshold) then
				self.items[searchText] = scan;
			end
		end
		
		if (not self.items[searchText]) then		
			self.items[searchText] = Atr_FindScanAndInit (searchText);
		end
		
	end
	
end

-----------------------------------------

-- `scanKey` is what gAllScans is keyed by; `itemName` is the item's real name
-- and is what the scan reports to the UI and writes to the price database.
-- They differ only for a same-name VARIANT bucket (BACKLOG item 12 part 1),
-- where the key carries the quality and the name stays the item's own. Keeping
-- them apart is what stops a bucket split from inventing database rows -- the
-- old trailing-space hack made its second bucket by making a second NAME, which
-- is how "Some Item " keys ended up on disk.
function Atr_FindScanAndInit (scanKey, itemName)

	return Atr_FindScan (scanKey, true, itemName);
end

-----------------------------------------

function Atr_FindScan (scanKey, init, itemName)

	if (scanKey == nil or scanKey == "") then
		scanKey = "nil";
	end

	itemName = itemName or scanKey;

	local scanKeyLC = string.lower (scanKey);

	if (gAllScans[scanKeyLC] == nil) then

		local scn = {};
		setmetatable (scn, AtrScan);
		scn:Init (itemName);

		gAllScans[scanKeyLC] = scn;
	elseif (init) then
		gAllScans[scanKeyLC]:Init (itemName);
	end
	
	return gAllScans[scanKeyLC];
end

-----------------------------------------

function Atr_ClearScanCache ()

--	zc.msg_red ("Clearing Scan Cache");

	for a,v in pairs (gAllScans) do
		if (a ~= "nil") then
			gAllScans[a] = nil;
		end
	end

end

-----------------------------------------

function AtrScan:Init (itemName)
	self.itemName			= itemName;
	self.variantQuality		= nil;		-- see the quality split in AtrSearch:ProcessBatch
	self.itemLink			= nil;
	self.texture            = nil;		-- vestigial: the texture-based variant split
										-- that set it is gone (BACKLOG item 12
										-- part 1) and nothing reads it
	self.scanData			= {};
	self.sortedData			= {};
	self.whenScanned		= 0;
	self.lowprices			= {BIGNUM, BIGNUM, BIGNUM};
	self.absoluteBest		= nil;
	self.itemClass			= 0;
	self.itemSubclass		= 0;
	self.yourBestPrice		= nil;
	self.yourWorstPrice		= nil;
	self.numYourSingletons	= 0;
	self.itemTextColor 		= { 1.0, 1.0, 1.0 };
	self.searchText			= nil;
	
	self:UpdateItemLink (Atr_GetItemLink (itemName));
end

-----------------------------------------

function AtrScan:UpdateItemLink (itemLink)

	self.itemLink = itemLink;
	
	if (itemLink) then
	
		Atr_AddToItemLinkCache (self.itemName, itemLink);

		local _, _, quality, _, _, sType, sSubType = GetItemInfo(itemLink);

		self.itemQuality	= quality;
		self.itemClass		= Atr_ItemType2AuctionClass (sType);
		self.itemSubclass	= Atr_SubType2AuctionSubclass (self.itemClass, sSubType);	

		self.itemTextColor = { 1.0, 1.0, 1.0 };

		if (quality == 0)	then	self.itemTextColor = { 0.6, 0.6, 0.6 };	end
		if (quality == 2)	then	self.itemTextColor = { 0.2, 1.0, 0.0 };	end
		if (quality == 3)	then	self.itemTextColor = { 0.0, 0.5, 1.0 };	end
		if (quality == 4)	then	self.itemTextColor = { 0.7, 0.3, 1.0 };	end
	end

end


-----------------------------------------

function AtrSearch:NumScans()

	if (self.sortedScans) then
		return #self.sortedScans;
	end

	local count = 0;
	for name,scn in pairs (self.items) do
		count = count + 1;
	end

	return count;
end

-----------------------------------------

function AtrSearch:NumSortedScans()

	if (self.sortedScans) then
		return #self.sortedScans;
	end

	return 0;
end

-----------------------------------------

function AtrSearch:GetFirstScan()

	if (self.sortedScans) then
		return self.sortedScans[1];
	end

	for name,scn in pairs (self.items) do
		return scn;
	end
	
	return nil;

end


-----------------------------------------

function AtrSearch:Start ()

    if (self.searchText == "") then
        return;
    end
	
	if (Atr_IsCompoundSearch (self.searchText)) then
			
		local _, itemClass = Atr_ParseCompoundSearch (self.searchText);
	
		if (itemClass == 0) then
			Atr_Error_Display (ZT("The first part of this compound\n\nsearch is not a valid category."));
			return;
		end

		self.sortHow = ATR_SORTBY_PRICE_DES;

	end
	
	self.processing_state = KM_SETTINGSORT;
    -- mark when this search started so callers can enforce a hard timeout
    self.started_when = (gAtr_ptime or 0);
	
	SortAuctionClearSort ("list");

	BrowseName:SetText (self.searchText);		-- not necessary but nice when user switches to Browse tab

    self.current_page		= 0;
    self.processing_state	= KM_PREQUERY;
    -- entering PREQUERY so a watchdog can measure stall time per stage
    self.prequery_when     = (gAtr_ptime or 0);

    self:Continue();
    
end

-----------------------------------------

function AtrSearch:Abort ()

	if (self.processing_state == KM_NULL_STATE) then
		return;
	end

	self.processing_state = KM_NULL_STATE;
	self:Init();
end

-----------------------------------------

function AtrSearch:CheckForDuplicatePage ()

	local isDup = self.query:CheckForDuplicatePage(self.current_page);

	if (isDup) then
--		zc.msg_red ("DUPLICATE PAGE FOUND: ", "  current_page: ", self.current_page, "  numDupPages: ", self.query.numDupPages);

		self.current_page	= self.current_page - 1;   -- requery the page
		
		self.processing_state = KM_PREQUERY;
        -- entering PREQUERY again after detecting duplicate page
        self.prequery_when   = (gAtr_ptime or 0);
	end
		
	return isDup;
end


-----------------------------------------

function AtrSearch:AnalyzeResultsPage()

	self.processing_state = KM_ANALYZING;

	if (self.query.numDupPages > 10) then 	 -- hopefully this will never happen but need check to avoid looping
		return true;						 -- done
	end


	local numBatchAuctions, totalAuctions = GetNumAuctionItems("list");

	if (self.current_page == 1 and totalAuctions > 3000) then -- give Blizz servers a break
		Atr_Error_Display (ZT("Too many results\n\nPlease narrow your search"));
		return true;  -- done
	end

	if (totalAuctions >= 50) then
		Atr_SetMessage (string.format (ZT("Scanning auctions: page %d"), self.current_page));
	end

	-- analyze

	local numNilOwners = 0;

	if (numBatchAuctions > 0) then

		local x;

		for x = 1, numBatchAuctions do

			local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", x);

			if (owner == nil) then
				numNilOwners = numNilOwners + 1;
			end
			
			local exactMatch = zc.StringSame (name, self.searchText);

			if (exactMatch or not self.exact) then

				-- SAME-NAME VARIANTS (BACKLOG item 12 part 1).  This server ships
				-- genuinely different items under one name -- a rare and an epic
				-- Bloodforged Imperial Jewel -- and one bucket per name averages
				-- them into a single misleading row.
				--
				-- Split on QUALITY.  It comes free from GetAuctionItemInfo above
				-- and it separates the reported case.  Deliberately NOT on level:
				-- Ascension scales gear per instance, so listings of one item
				-- carry many required levels and a level split would shatter every
				-- gear row into dozens of buckets.
				--
				-- This replaces a TEXTURE comparison that never fired where it
				-- mattered -- variants share an icon.  Measured on a real database
				-- 2026-08-19: 3 splits in 5267 entries, all recipes or a container,
				-- none on gear.
				--
				-- Only the lookup KEY carries the quality.  scn.itemName stays the
				-- item's real name, so the UI still shows a name and the finaliser
				-- still writes one database row per name (two buckets both write
				-- it, last one wins -- no worse than the single merged number this
				-- wrote before, and the shape part 3 extends).
				local baseName = name;
				local scn      = self.items[baseName];

				if (scn == nil) then
					scn = Atr_FindScanAndInit (baseName, baseName);
					self.items[baseName] = scn;
				end

				-- adopt the first quality this search sees as the primary bucket's;
				-- Init clears it, so a scan reused from an earlier search cannot
				-- leak a stale value in here
				if (scn.variantQuality == nil) then
					scn.variantQuality = quality;
				end

				if (quality ~= nil and quality ~= scn.variantQuality) then
					local vkey = baseName .. "#q" .. tostring (quality);
					local vscn = self.items[vkey];
					if (vscn == nil) then
						vscn = Atr_FindScanAndInit (vkey, baseName);
						vscn.variantQuality = quality;
						self.items[vkey] = vscn;
					end
					scn = vscn;
				end

				local curpage = (tonumber(self.current_page)-1);

				scn:AddScanItem (name, count, buyoutPrice, owner, 1, curpage);
				
				if (scn.itemLink == nil or self.itemClass == nil) then
					scn:UpdateItemLink (GetAuctionItemLink("list", x));
				end

				if (self.callback) then
					self.callback (x, numBatchAuctions, count, buyoutPrice, owner);
				end
				
			end
		end
	end
	
	local done = (numBatchAuctions < 50);

	if (not done) then
        self.processing_state = KM_PREQUERY;
        -- entering PREQUERY to request next page
        self.prequery_when   = (gAtr_ptime or 0);
    end
	
	return done;
end

-----------------------------------------

function AtrScan:AddScanItem (name, stackSize, buyoutPrice, owner, numAuctions, curpage)

	local sd = {};
	local i;

	if (numAuctions == nil) then
		numAuctions = 1;
	end

	for i = 1, numAuctions do
		sd["stackSize"]		= stackSize;
		sd["buyoutPrice"]	= buyoutPrice;
		sd["owner"]			= owner;
		sd["pagenum"]		= curpage;

		tinsert (self.scanData, sd);
		
		if (buyoutPrice) then
			local itemPrice = math.floor (buyoutPrice / stackSize);

			Atr_AddToLowPrices (self.lowprices, itemPrice);
		end
	end

end


-----------------------------------------

function AtrScan:AddSDXToScan (price, owner, volume)	-- helper function for AddExternalDataToScan

	local sd = {};

	if (price and price > 0) then
		sd["stackSize"]		= 1;
		sd["buyoutPrice"]	= price;
		sd["owner"]			= owner;

		if (volume) then
			sd["volume"] = volume;
		end

		tinsert (self.scanData, sd);
	end
	
end

-----------------------------------------

function AtrScan:AddExternalDataToScan ()

	if (self.itemLink == nil) then
		return;
	end

	-- Wowecon

	if (Wowecon and Wowecon.API) then
	
		local priceG, volG = Wowecon.API.GetAuctionPrice_ByLink (self.itemLink, Wowecon.API.GLOBAL_PRICE)
		local priceS, volS = Wowecon.API.GetAuctionPrice_ByLink (self.itemLink, Wowecon.API.SERVER_PRICE)

		self:AddSDXToScan (priceG, "__wowEconG", volG);
		self:AddSDXToScan (priceS, "__wowEconS", volS);
		
	end
	
	-- GoingPrice Wowhead
	
	local id = zc.ItemIDfromLink (self.itemLink);
	
	id = tonumber(id);

	if (GoingPrice_Wowhead_Data and GoingPrice_Wowhead_Data[id] and GoingPrice_Wowhead_SV._index) then
		local index = GoingPrice_Wowhead_SV._index["Buyout price"];

		if (index ~= nil) then
			local price = GoingPrice_Wowhead_Data[id][index];
		
			self:AddSDXToScan (price, "__wowHead");
		end
	end

	-- GoingPrice Allakhazam
	
	if (GoingPrice_Allakhazam_Data and GoingPrice_Allakhazam_Data[id] and GoingPrice_Allakhazam_SV._index) then
		local index = GoingPrice_Allakhazam_SV._index["Median"];

		if (index ~= nil) then
			local price = GoingPrice_Allakhazam_Data[id][index];
		
			self:AddSDXToScan (price, "__allakhazam");
		end
	end

	-- most recent historical price
	
	local price = Atr_Process_Historydata();
	if (price ~= nil) then
		self:AddSDXToScan (price, "__atrLast");
	end

end

-----------------------------------------

function AtrScan:SubtractScanItem (name, stackSize, buyoutPrice)

	local sd;
	local i;

	for i,sd in ipairs (self.scanData) do
		
		if (sd.stackSize == stackSize and sd.buyoutPrice == buyoutPrice) then
			
			tremove (self.scanData, i);
			return;
		end
	end

end

-----------------------------------------

function Atr_IsCompoundSearch (searchString)
	
	return zc.StringContains (searchString, ">") or zc.StringContains (searchString, "/");
end

-----------------------------------------

function Atr_ParseCompoundSearch (searchString)

	local delim = "/";

	if (zc.StringContains (searchString, ">")) then
		delim = ">";
	end

	local tbl	= { strsplit (delim, searchString) };
	
	local queryString	= "";
	local itemClass		= 0;
	local itemSubclass	= 0;
	local minLevel		= nil;
	local maxLevel		= nil;
	local prevWasItemClass;
	local n;
	
	for n = 1,#tbl do
		local s = tbl[n];

		local handled = false;

		if (not handled and tonumber(s)) then
			if (minLevel == nil) then
				minLevel = tonumber(s);
			elseif (maxLevel == nil) then
				maxLevel = tonumber(s);
			end
			
			handled = true;
			prevWasItemClass = false;
		end
		
		if (not handled and prevWasItemClass and itemSubclass == 0) then
			itemSubclass = Atr_SubType2AuctionSubclass (itemClass, s);
			if (itemSubclass > 0) then
				handled = true;
				prevWasItemClass = false;
			end
		end
		
		if (not handled and itemClass == 0) then

			itemClass = Atr_ItemType2AuctionClass (s);

			if (itemClass > 0) then
				prevWasItemClass = true;
				handled = true;
			end
		end
		
		if (not handled) then
			queryString = s;
			handled = true;
		end
	end	

	return queryString, itemClass, itemSubclass, minLevel, maxLevel;
end

-----------------------------------------

function AtrSearch:Continue()

	if (CanSendAuctionQuery()) then

		self.processing_state = KM_INQUERY;

		local queryString = self.searchText;

--	zc.md (queryString.."  page:"..self.current_page);
		
		local itemClass		= 0;
		local itemSubclass	= 0;
		local minLevel		= nil;
		local maxLevel		= nil;
		
		if (self.exact) then
			local scn = self:GetFirstScan();
			itemClass		= scn.itemClass;
			itemSubclass	= scn.itemSubclass;
		end

		if (Atr_IsCompoundSearch(queryString)) then
		
			queryString, itemClass, itemSubclass, minLevel, maxLevel = Atr_ParseCompoundSearch (queryString);
		
		end

		queryString = zc.UTF8_Truncate (queryString,63);	-- attempting to reduce number of disconnects

		QueryAuctionItems (queryString, minLevel, maxLevel, nil, itemClass, itemSubclass, self.current_page, nil, nil);

		self.query_sent_when	= gAtr_ptime;
		self.processing_state	= KM_POSTQUERY;
		self.current_page		= self.current_page + 1;
	end

end

-----------------------------------------

local gSortScansBy;

-----------------------------------------

local function Atr_SortScans (x, y)

	if (gSortScansBy == ATR_SORTBY_NAME_ASC) then		return string.lower (x.itemName) < string.lower (y.itemName);	end
	if (gSortScansBy == ATR_SORTBY_NAME_DES) then		return string.lower (x.itemName) > string.lower (y.itemName);	end

	local xprice = 0;
	local yprice = 0;
	
	if (x.absoluteBest) then	xprice = zc.round(x.absoluteBest.buyoutPrice/x.absoluteBest.stackSize);		end;
	if (y.absoluteBest) then	yprice = zc.round(y.absoluteBest.buyoutPrice/y.absoluteBest.stackSize);		end;
	
	if (gSortScansBy == ATR_SORTBY_PRICE_ASC) then		return xprice < yprice;		end
	if (gSortScansBy == ATR_SORTBY_PRICE_DES) then		return xprice > yprice;		end

end

-----------------------------------------

function AtrSearch:Finish()

	local finishTime = time();
	
	self.processing_state	= KM_NULL_STATE;
	self.current_page		= -1;
	self.query_sent_when	= nil;
	
	self.sortedScans = nil;
	
	local wasExactSearch = (self:NumScans() == 1);		-- search returned only 1 item
	
	local x = 1;
	self.sortedScans = {};
	
	for name,scn in pairs (self.items) do
	
		self.sortedScans[x] = scn;
		x = x + 1;
		
		scn.whenScanned		= finishTime;
		scn.searchText		= self.searchText;

		scn:CondenseAndSort ();

		-- update the fullscan DB
		
		local newprice = Atr_CalcNewDBprice (scn.itemName, scn.lowprices);
		
		if (newprice > 0) then
			if (scn.itemQuality + 1 >= AUCTIONATOR_SCAN_MINLEVEL) then
				-- The one writer that KNOWS its variant: after the quality split
				-- (part 1) each bucket carries its own listing's link, so the price
				-- lands in that variant's slot instead of overwriting the name.
				-- Without a link it stores as before, against the name's default.
				if (type (Atr_PriceStore) == "function") then
					local vkey = (type (Atr_VariantKey) == "function") and Atr_VariantKey (scn.itemLink) or nil;
					Atr_PriceStore (gAtr_ScanDB, scn.itemName, newprice, vkey);
				else
					gAtr_ScanDB[scn.itemName] = newprice;
				end

				-- Keep the median sample set in step with the auction price.  A
				-- targeted search used to write gAtr_ScanDB alone, so its auction
				-- number drifted away from a median built only from full scans --
				-- the two tooltip lines were drawn from different populations, and
				-- names touched only here got an auction price but no samples at
				-- all.  Append a sample here too, matching the full-scan / Finder /
				-- Bazaar feeds: cap at 15, evict at random when full, keep sorted
				-- for Atr_GetMeanPrice.
				--
				-- The sample is the quantity-weighted median of THIS scan's
				-- current listings, not its single lowest price -- see
				-- Atr_WeightedMedianPrice.  Feeding the lowest price made the
				-- median collapse onto the Auction line; the across-listings
				-- median lets it reflect the whole book.  Fall back to the lowest
				-- price only when no listing detail is available.
				if (type (gAtr_MeanDB) == "table") then
					local medsample = Atr_ScanListingsMedian (scn) or newprice;

					Atr_MeanAppend (gAtr_MeanDB, scn.itemName, medsample);		-- item 13: one-sample shape
				end
			end
		end
	end

	-- Targeted scan updated the price DB: drop the suffix-variant estimate cache
	-- so base gear estimates (Atr_GetAHVariantEstimate) pick up the new prices.
	if (Atr_AH_InvalidateVariantCache) then Atr_AH_InvalidateVariantCache (); end

	Atr_ClearBrowseListings();
	
	gSortScansBy = self.sortHow;
	table.sort (self.sortedScans, Atr_SortScans);
	
end

-----------------------------------------

function AtrSearch:ClickPriceCol()

	if (self.sortHow == ATR_SORTBY_PRICE_ASC) then
		self.sortHow = ATR_SORTBY_PRICE_DES;
	else
		self.sortHow = ATR_SORTBY_PRICE_ASC;
	end

	gSortScansBy = self.sortHow;
	table.sort (self.sortedScans, Atr_SortScans);

end

-----------------------------------------

function AtrSearch:ClickNameCol()

	if (self.sortHow == ATR_SORTBY_NAME_ASC) then
		self.sortHow = ATR_SORTBY_NAME_DES;
	else
		self.sortHow = ATR_SORTBY_NAME_ASC;
	end

	gSortScansBy = self.sortHow;
	table.sort (self.sortedScans, Atr_SortScans);
end

-----------------------------------------

function AtrSearch:UpdateArrows()

	Atr_Col1_Heading_ButtonArrow:Hide();
	Atr_Col3_Heading_ButtonArrow:Hide();
	
	if (self.sortHow == ATR_SORTBY_PRICE_ASC) then
		Atr_Col1_Heading_ButtonArrow:Show();
		Atr_Col1_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 0, 1.0);
	elseif (self.sortHow == ATR_SORTBY_PRICE_DES) then
		Atr_Col1_Heading_ButtonArrow:Show();
		Atr_Col1_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 1.0, 0);
	elseif (self.sortHow == ATR_SORTBY_NAME_ASC) then
		Atr_Col3_Heading_ButtonArrow:Show();
		Atr_Col3_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 0, 1.0);
	elseif (self.sortHow == ATR_SORTBY_NAME_DES) then
		Atr_Col3_Heading_ButtonArrow:Show();
		Atr_Col3_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 1.0, 0);
	end
end

-----------------------------------------

function Atr_ClearBrowseListings()
	
	local start = time();

	while (time() - start < 5) do
	
		if (CanSendAuctionQuery()) then
			QueryAuctionItems("xyzzy", 43, 43, 0, 7, 0);
			break;
		end
	end

end

-----------------------------------------

function Atr_SortAuctionData (x, y)

	return x.itemPrice < y.itemPrice;

end

-----------------------------------------

function AtrScan:CondenseAndSort ()

	----- Condense the scan data into a table that has only a single entry per stacksize/price combo

	self.sortedData	= {};

	local i,sd;
	local conddata = {};

	for i,sd in ipairs (self.scanData) do

		local ownerCode = "x";
		local dataType  = "n";		-- normal
		
		if (sd.owner == UnitName("player")) then
			ownerCode = "y";
--		elseif (Atr_IsMyToon (sd.owner)) then
--			ownerCode = sd.owner;
		elseif (sd.owner == "__wowEconG") then
			dataType = "eg";
		elseif (sd.owner == "__wowEconS") then
			dataType = "es";
		elseif (sd.owner == "__wowHead") then
			dataType = "h";
		elseif (sd.owner == "__allakhazam") then
			dataType = "k";
		elseif (sd.owner == "__atrLast") then
			dataType = "a";
		end

		local key = "_"..sd.stackSize.."_"..sd.buyoutPrice.."_"..ownerCode..dataType;

		if (conddata[key]) then
			conddata[key].count		= conddata[key].count + 1;
			conddata[key].minpage 	= zc.Min (conddata[key].minpage, sd.pagenum);
			conddata[key].maxpage 	= zc.Max (conddata[key].maxpage, sd.pagenum);
		else
			local data = {};

			data.stackSize 		= sd.stackSize;
			data.buyoutPrice	= sd.buyoutPrice;
			data.itemPrice		= sd.buyoutPrice / sd.stackSize;
			data.minpage		= sd.pagenum;
			data.maxpage		= sd.pagenum;
			data.count			= 1;
			data.type			= dataType;
			data.yours			= (ownerCode == "y");
			
			if (ownerCode ~= "x" and ownerCode ~= "y") then
				data.altname = ownerCode;
			end
			
			if (sd.volume) then
				data.volume = sd.volume;
			end
			
			conddata[key] = data;
		end

	end

	----- create a table of these entries

	local n = 1;

	local i, v;

	for i,v in pairs (conddata) do
		self.sortedData[n] = v;
		n = n + 1;
	end

	-- sort the table by itemPrice

	table.sort (self.sortedData, Atr_SortAuctionData);

	-- analyze and store some info about the data

	self:AnalyzeSortData ();

end

-----------------------------------------

function AtrScan:AnalyzeSortData ()

	self.absoluteBest			= nil;
	self.bestPrices				= {};		-- a table with one entry per stacksize that is the cheapest auction for that particular stacksize
	self.numMatches				= 0;
	self.numMatchesWithBuyout	= 0;
	self.hasStack				= false;
	self.yourBestPrice			= nil;
	self.yourWorstPrice			= nil;
	self.numYourSingletons		= 0;

	local j, sd;

	----- find the best price per stacksize and overall -----

	for j,sd in ipairs(self.sortedData) do

		if (sd.type == "n") then

			self.numMatches = self.numMatches + 1;

			if (sd.itemPrice > 0) then

				self.numMatchesWithBuyout = self.numMatchesWithBuyout + 1;

				if (self.bestPrices[sd.stackSize] == nil or self.bestPrices[sd.stackSize].itemPrice >= sd.itemPrice) then
					self.bestPrices[sd.stackSize] = sd;
				end

				if (self.absoluteBest == nil or self.absoluteBest.itemPrice > sd.itemPrice) then
					self.absoluteBest = sd;
				end
				
				if (sd.yours) then
					if (self.yourBestPrice == nil or self.yourBestPrice > sd.itemPrice) then
						self.yourBestPrice = sd.itemPrice;
					end
					
					if (self.yourWorstPrice == nil or self.yourWorstPrice < sd.itemPrice) then
						self.yourWorstPrice = sd.itemPrice;
					end
					
					if (sd.stackSize == 1) then
						self.numYourSingletons = self.numYourSingletons + sd.count;
					end
				end
			end

			if (sd.stackSize > 1) then
				self.hasStack = true;
			end
		end
	end
end

-----------------------------------------

function AtrScan:FindInSortedData (stackSize, buyoutPrice)
	local j = 1;
	for j = 1,#self.sortedData do
		sd = self.sortedData[j];
		if (sd.stackSize == stackSize and sd.buyoutPrice == buyoutPrice and sd.yours) then
			return j;
		end
	end
	
	return 0;
end


-----------------------------------------

function AtrScan:FindMatchByStackSize (stackSize)

	local index = nil;

	local basedata = self.absoluteBest;

	if (self.bestPrices[stackSize]) then
		basedata = self.bestPrices[stackSize];
	end

	local numrows = #self.sortedData;

	local n;

	for n = 1,numrows do

		local data = self.sortedData[n];

		if (basedata and data.itemPrice == basedata.itemPrice and data.stackSize == basedata.stackSize and data.yours == basedata.yours) then
			index = n;
			break;
		end
	end

	return index;
	
end

-----------------------------------------

function AtrScan:FindMatchByYours ()

	local index = nil;

	local j;
	for j = 1,#self.sortedData do
		sd = self.sortedData[j];
		if (sd.yours) then
			index = j;
			break;
		end
	end

	return index;

end

-----------------------------------------

function AtrScan:FindCheapest ()

	local index = nil;

	local j;
	for j = 1,#self.sortedData do
		sd = self.sortedData[j];
		if (sd.itemPrice > 0) then
			index = j;
			break;
		end
	end

	return index;

end


-----------------------------------------

function AtrScan:GetNumAvailable ()

	local num = 0;

	local j, data;
	for j = 1,#self.sortedData do

		data = self.sortedData[j];
		num = num + (data.count * data.stackSize);
	end
	
	return num;
end

-----------------------------------------

function AtrScan:IsNil ()

	if (self.itemName == nil or self.itemName == "" or self.itemName == "nil") then
		return true;
	end
	
	return false;
end

-----------------------------------------

ATR_FS_NULL			= 0;
ATR_FS_STARTED		= 1;
ATR_FS_ANALYZING	= 2;
ATR_FS_CLEANING_UP	= 3;

ATR_FSS_NULL		= 0;

gAtr_FullScanState		= ATR_FS_NULL;
gAtr_FullScanSubState	= ATR_FSS_NULL;

local gAtr_FullScanIsSlowScan;

local gAtr_SlowScanClass = nil;
local gAtr_SlowScanSubClass = nil;

local gAtr_FullScanStart;
local gAtr_FullScanDur;
-- Track timeout state and reason for stopping early
gAtr_FullScanTimedOut = false;
gAtr_FullScanStopReason = nil;

-----------------------------------------

function Atr_GetDBsize()

	local n = 0;
	local a,v;

	for a,v in pairs (gAtr_ScanDB) do
		n = n + 1;
	end
	
	return n;
end


-----------------------------------------

local gNumAdded, gNumUpdated;

-----------------------------------------

function Atr_FullScanStart()

	local gAtr_FullScanIsSlowScan = false;
--	local gAtr_FullScanIsSlowScan = Atr_FullScan_Slow:GetChecked();
--	zc.md (gAtr_FullScanIsSlowScan);
	
	local canQuery,canQueryAll = CanSendAuctionQuery();
	
	if (canQueryAll or gAtr_FullScanIsSlowScan) then
	
		Atr_FullScanStatus:SetText (ZT("Scanning").."...");
		Atr_FullScanStartButton:Disable();
		Atr_FullScanDone:Disable();
		
		gAtr_FullScanStart = time();
		gAtr_FullScanDur   = nil;
		gAtr_FullScanTimedOut = false;
		gAtr_FullScanStopReason = nil;
		
		SortAuctionClearSort ("list");

		gNumAdded = 0;
		gNumUpdated = 0;

		if (gAtr_FullScanIsSlowScan) then
			gAtr_SlowScanClass = nil;
			gAtr_SlowScanSubClass = nil;
		else
			QueryAuctionItems ("", nil, nil, 0, 0, 0, 0, 0, 0, true);
		end
        gAtr_FullScanState = ATR_FS_STARTED;
	end

end

-----------------------------------------

function Atr_CalcNewDBprice (name, prices)

	if (prices[1] ~= BIGNUM) then
		return prices[1];
	end

	return 0;

end

-----------------------------------------

-- FINDER_TAB: quantity-weighted median of a scan's CURRENT listings.
--
-- The "Auction median" tooltip line reads from gAtr_MeanDB, a rolling set of
-- up-to-15 per-scan samples.  Each scan used to contribute only its single
-- LOWEST per-unit price (Atr_CalcNewDBprice -> prices[1]) -- the same figure
-- the "Auction" line already shows.  A commodity whose lowest price barely
-- moves therefore filled the whole sample set with that one low value, so the
-- median sat ON the lowest price and never reflected the rest of the book.
--
-- This computes the median ACROSS the listings instead, weighted by quantity:
-- every item for sale gets a vote, so a wall of 19 stacks counts far more than
-- a lone lowball stack.  Feeding THIS as the per-scan sample lets the median
-- track where supply actually sits.  `entries` is an array of
-- { price = <per-unit copper>, weight = <#items in the listing> }.  Returns a
-- floored median, or 0 when there is nothing to measure.
function Atr_WeightedMedianPrice (entries)

	if (type (entries) ~= "table" or #entries == 0) then
		return 0;
	end

	table.sort (entries, function (a, b) return a.price < b.price; end);

	local total = 0;
	local i;
	for i = 1, #entries do
		total = total + (entries[i].weight or 0);
	end

	if (total <= 0) then
		return 0;
	end

	local half = total / 2;
	local cum  = 0;
	for i = 1, #entries do
		cum = cum + (entries[i].weight or 0);
		if (cum > half) then
			return math.floor (entries[i].price);
		end
		if (cum == half) then
			-- exact split: average the two straddling prices for a true median
			local nextp = (entries[i + 1] and entries[i + 1].price) or entries[i].price;
			return math.floor ((entries[i].price + nextp) / 2);
		end
	end

	return math.floor (entries[#entries].price);
end

-----------------------------------------

-- FINDER_TAB: quantity-weighted median of a single AtrScan's listings.
--
-- Walks scn.scanData -- every real auction posting for the item -- and returns
-- the across-listings median (see Atr_WeightedMedianPrice).  Synthetic
-- "__wowEcon*/__wowHead/__allakhazam/__atrLast" seed rows are skipped so the
-- median rests on the live market, matching the population the Auction line's
-- lowprices are drawn from.  Returns nil when there is no usable listing, so
-- the caller can fall back to the lowest-price sample.
function Atr_ScanListingsMedian (scn)

	if (type (scn) ~= "table" or type (scn.scanData) ~= "table") then
		return nil;
	end

	local entries = {};
	local i, sd;
	for i, sd in ipairs (scn.scanData) do
		local o = sd.owner;
		local synthetic = (type (o) == "string" and string.sub (o, 1, 2) == "__");
		if (not synthetic and sd.buyoutPrice and sd.buyoutPrice > 0
				and sd.stackSize and sd.stackSize > 0) then
			tinsert (entries, {
				price  = sd.buyoutPrice / sd.stackSize,
				weight = sd.stackSize,
			});
		end
	end

	local med = Atr_WeightedMedianPrice (entries);
	if (med > 0) then
		return med;
	end

	return nil;
end

-----------------------------------------

function Atr_AddToLowPrices (lowprices, itemPrice)
	
	if (itemPrice > 0) then
		if (itemPrice < lowprices[1]) then
			if (lowprices[1] < lowprices[2]) then
				lowprices[2] = lowprices[1];
			end
			lowprices[1] = itemPrice;
			return true;
		elseif (itemPrice < lowprices[2]) then
			lowprices[2] = itemPrice;
			return true;
		end
	end

	return false;
end




-----------------------------------------

local gScanDetails = {}

-----------------------------------------

function Atr_FullScanMoreDetails ()

	local minutes = math.floor (gAtr_FullScanDur/60);
	local seconds = gAtr_FullScanDur - (minutes * 60);

	zc.msg (" ");
	zc.msg_atr (string.format ("Scan complete (%d:%02d)", minutes, seconds));
	zc.msg_atr (ZT("Auctions scanned")..": |cffffffff", gScanDetails.numBatchAuctions, " |r("..gScanDetails.totalItems, "items)");
	zc.msg_atr ("|cffa335ee   "..ZT("Epic items")..": |r",		gScanDetails.numEachQual[5]);
	zc.msg_atr ("|cff0070dd   "..ZT("Rare items")..": |r",		gScanDetails.numEachQual[4]);
	zc.msg_atr ("|cff1eff00   "..ZT("Uncommon items")..": |r",	gScanDetails.numEachQual[3]);
	zc.msg_atr ("|cffffffff   "..ZT("Common items")..": |r",		gScanDetails.numEachQual[2]);
	zc.msg_atr ("|cff9d9d9d   "..ZT("Poor items")..": |r",		gScanDetails.numEachQual[1]);
	
	
	if (gScanDetails.numRemoved[4] > 0) then		zc.msg_atr (ZT("Rare items").." "..ZT("removed from database")..": |cffffffff",		gScanDetails.numRemoved[4]);		end
	if (gScanDetails.numRemoved[3] > 0) then		zc.msg_atr (ZT("Uncommon items").." "..ZT("removed from database")..": |cffffffff",	gScanDetails.numRemoved[3]);		end
	if (gScanDetails.numRemoved[2] > 0) then		zc.msg_atr (ZT("Common items").." "..ZT("removed from database")..": |cffffffff",	gScanDetails.numRemoved[2]);		end
	if (gScanDetails.numRemoved[1] > 0) then		zc.msg_atr (ZT("Poor items").." "..ZT("removed from database")..": |cffffffff",		gScanDetails.numRemoved[1]);		end
	
	zc.msg_atr (ZT("Items added to database")..": |cffffffff", gScanDetails.gNumAdded);
	zc.msg_atr (ZT("Items updated in database")..": |cffffffff", gScanDetails.gNumUpdated);
	zc.msg_atr (ZT("Items ignored")..": |cffffffff", gScanDetails.totalItems - (gScanDetails.gNumAdded + gScanDetails.gNumUpdated));
	zc.msg (" ");
end

-----------------------------------------

function Atr_FullScanAnalyze()

	gAtr_FullScanState = ATR_FS_ANALYZING;

	Atr_FullScanStatus:SetText (ZT("Processing"));
	
	local numBatchAuctions, totalAuctions = GetNumAuctionItems("list");

	zc.md ("FULL SCAN:"..numBatchAuctions.." out of  "..totalAuctions)

	local lowprices = {};
	local x;

	local qualities = {};

	-- FINDER_TAB: per-name listing detail for the quantity-weighted median
	-- sample (see Atr_WeightedMedianPrice).  lowprices alone can only feed the
	-- median its single lowest price, which pins the median to the Auction line.
	local alllistings = {};
	
	if (numBatchAuctions > 0) then

		for x = 1, numBatchAuctions do

			local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice = GetAuctionItemInfo("list", x);
			
			if (name ~= nil and buyoutPrice ~= nil) then
            
                -- Superseded (item 13): this used to pre-create an EMPTY table for
                -- every name it saw, which is what made 64% of this database a
                -- table wrapped around a single number.  Atr_MeanAppend now
                -- creates the right shape on the first real sample instead, so
                -- there is nothing to pre-create.

                qualities[name] = quality;
			
				local itemPrice = math.floor (buyoutPrice / count);

				if (itemPrice > 0) then
					if (not lowprices[name]) then
						lowprices[name] = {BIGNUM,BIGNUM,BIGNUM};		-- one extra for later
					end

					Atr_AddToLowPrices (lowprices[name], itemPrice);

					if (not alllistings[name]) then alllistings[name] = {}; end
					tinsert (alllistings[name], { price = itemPrice, weight = count });
				end
			end

			if (x % 100 == 0) then
				Atr_FullScanStatus:SetText (ZT("Processing").." ("..x..")");
			end
		end
	end

	local numEachQual = {0, 0, 0, 0, 0, 0, 0, 0, 0};
	local totalItems = 0;
	local numRemoved = { 0, 0, 0, 0, 0, 0, 0, 0 };
	
	for name,prices in pairs (lowprices) do
		
		local newprice = Atr_CalcNewDBprice (name, prices);
		
		if (newprice > 0) then
		
			local qx = qualities[name] + 1;
			
			numEachQual[qx]	= numEachQual[qx] + 1;
			totalItems		= totalItems + 1;
			
			if (qx < AUCTIONATOR_SCAN_MINLEVEL and gAtr_ScanDB[name]) then
				numRemoved[qx] = numRemoved[qx] + 1;
				gAtr_ScanDB[name] = nil;
				zc.md ("removed: |cffbbbbbb", name, "   ("..qx..")");
			end
			
			if (qx >= AUCTIONATOR_SCAN_MINLEVEL) then

				if (gAtr_ScanDB[name] == nil) then
					gNumAdded = gNumAdded + 1;
				else
					gNumUpdated = gNumUpdated + 1;
				end

				-- full scan: aggregated by name with no per-variant link, so this
				-- updates the name's default and leaves any variants alone
				if (type (Atr_PriceStore) == "function") then Atr_PriceStore (gAtr_ScanDB, name, newprice);
				else gAtr_ScanDB[name] = newprice; end

                -- Sample the quantity-weighted median of this scan's listings,
                -- not its lowest price, so the median reflects the whole book
                -- (Atr_WeightedMedianPrice).  Fall back to newprice if detail
                -- is somehow missing.
                local medsample = Atr_WeightedMedianPrice (alllistings[name] or {});
                if (medsample <= 0) then medsample = newprice; end

                Atr_MeanAppend (gAtr_MeanDB, name, medsample)        -- item 13: one-sample shape
			end
		end
	end
    
    for name in pairs(gAtr_MeanDB) do
        if (type (gAtr_MeanDB[name]) == "table") then table.sort(gAtr_MeanDB[name]) end
    end

	-- Scan rewrote the price DB: drop the suffix-variant estimate cache so base
	-- gear estimates (Atr_GetAHVariantEstimate) reflect the fresh prices.
	if (Atr_AH_InvalidateVariantCache) then Atr_AH_InvalidateVariantCache (); end

	gScanDetails.numBatchAuctions		= numBatchAuctions;
	gScanDetails.totalItems				= totalItems;
	gScanDetails.numEachQual			= numEachQual;
	gScanDetails.numRemoved				= numRemoved;
	gScanDetails.gNumAdded				= gNumAdded;
	gScanDetails.gNumUpdated			= gNumUpdated;


	if (Atr_PrintBargains and Atr_CheckForBargain and numBatchAuctions > 0) then

		for x = 1, numBatchAuctions do
			Atr_CheckForBargain (x);
		end
		
		Atr_PrintBargains();
	end
	
	gAtr_FullScanState = ATR_FS_CLEANING_UP;

	Atr_FullScanMoreDetails();

	if (gAtr_FullScanTimedOut and gAtr_FullScanStopReason) then
		Atr_FullScanStatus:SetText (gAtr_FullScanStopReason);
	else
		Atr_FullScanStatus:SetText (ZT("Cleaning up"));
	end
	
	Atr_FullScanDone:Enable();
	-- Keep the stop reason visible; only clear status if not timed out
	if (not gAtr_FullScanTimedOut) then
		Atr_FullScanStatus:SetText ("");
	end
	
	Atr_FSR_scanned_count:SetText	(numBatchAuctions);
	Atr_FSR_added_count:SetText		(gNumAdded);
	Atr_FSR_updated_count:SetText	(gNumUpdated);
	Atr_FSR_ignored_count:SetText	(totalItems - (gNumAdded + gNumUpdated));
	
	Atr_FullScanHTML:Hide();
	Atr_FullScanResults:Show();
	
	Atr_FullScanResults:SetBackdropColor (0.3, 0.3, 0.4);
	
	AUCTIONATOR_LAST_SCAN_TIME = time();
	
	Atr_UpdateFullScanFrame ();

	-- Ensure Auctionator Buy search controls are enabled after a full scan completes
	if (Atr_Search_Button) then Atr_Search_Button:Enable(); end
	if (Atr_Adv_Search_Button) then Atr_Adv_Search_Button:Enable(); end

	-- If the Buy pane is active, refresh its UI so the list and buttons reflect current state
	if (Atr_IsTabSelected and (Atr_IsTabSelected(BUY_TAB) or (gCurrentPane == gShopPane))) then
		if (Atr_Shop_UpdateUI) then Atr_Shop_UpdateUI(); end
	end

	Atr_ClearBrowseListings();
	
	lowprices = {};
	collectgarbage ("collect");
end

-----------------------------------------

function Atr_ShowFullScanFrame()

	Atr_FullScanHTML:Show();
	Atr_FullScanResults:Hide();

	Atr_FullScanFrame:Show();
	Atr_FullScanFrame:SetBackdropColor(0,0,0,100);
	
	Atr_UpdateFullScanFrame();
	Atr_FullScanStatus:SetText ("");

	local expText = "<html><body>"
					.."<p>"
					..ZT("Scanning is entirely optional.")
					.."<br/><br/>"
					..ZT("SCAN_EXPLANATION")
					.."</p>"
					.."</body></html>"
					;



	Atr_FullScanHTML:SetText (expText);
	Atr_FullScanHTML:SetSpacing (3);
end

-----------------------------------------

function Atr_UpdateFullScanFrame()

	Atr_FullScanDBsize:SetText (Atr_GetDBsize());
	
	if (AUCTIONATOR_LAST_SCAN_TIME) then
		Atr_FullScanDBwhen:SetText (date ("%A, %B %d at %I:%M %p", AUCTIONATOR_LAST_SCAN_TIME));
	else
		Atr_FullScanDBwhen:SetText (ZT("Never"));
	end

	local canQuery,canQueryAll = CanSendAuctionQuery();

	if (canQueryAll) then
		Atr_FullScanStatus:SetText ("");
		Atr_FullScanStartButton:Enable();
		Atr_FullScanNext:SetText(ZT("Now"));
	else	
		Atr_FullScanStartButton:Disable();

		if (AUCTIONATOR_LAST_SCAN_TIME) then
			local when = 15*60 - (time() - AUCTIONATOR_LAST_SCAN_TIME);
		
			when = math.floor (when/60);
		
			if (when == 0) then
				Atr_FullScanNext:SetText (ZT("in less than a minute"));
			elseif (when == 1) then
				Atr_FullScanNext:SetText (ZT("in about one minute"));
			elseif (when > 0) then
				Atr_FullScanNext:SetText (string.format (ZT("in about %d minutes"), when));
			else
				Atr_FullScanNext:SetText (ZT("unknown"));
			end
		else
			Atr_FullScanNext:SetText (ZT("unknown"));
		end
	end
end

-----------------------------------------

function Atr_FullScan_GetDurString()

	local minutes = math.floor (gAtr_FullScanDur/60);
	local seconds = gAtr_FullScanDur - (minutes * 60);

	return string.format ("%d:%02d", minutes, seconds);
end

-----------------------------------------

function Atr_FullScanFrameIdle()

    if (gAtr_FullScanState == ATR_FS_STARTED) then

        if (gAtr_FullScanIsSlowScan) then
            
        end

        local btext = Atr_FullScanStatus:GetText ();
        
        if (btext) then
            gAtr_FullScanDur = time()- gAtr_FullScanStart;
            Atr_FullScanStatus:SetText (string.format ("Scanning (%s)", Atr_FullScan_GetDurString()));
        end

        -- Hard stop after 20 seconds to avoid hanging on unresponsive servers
        if (not gAtr_FullScanTimedOut and (time() - gAtr_FullScanStart) > 20) then
            gAtr_FullScanTimedOut = true;
            gAtr_FullScanStopReason = "Stopped after 20s: server did not return all auctions";
            -- Analyze whatever we have and proceed to cleanup/results
            Atr_FullScanAnalyze();
            return;
        end
    end


    if (gAtr_FullScanState == ATR_FS_CLEANING_UP) then
    
        Atr_FullScanStatus:SetText ("Cleaning up");
        
        if (GetNumAuctionItems("list") < 100) then
            if (gAtr_FullScanTimedOut and gAtr_FullScanStopReason) then
                Atr_FullScanStatus:SetText (gAtr_FullScanStopReason .. " — " .. string.format ("Scan complete (%s)", Atr_FullScan_GetDurString()));
            else
                Atr_FullScanStatus:SetText (string.format ("Scan complete (%s)", Atr_FullScan_GetDurString()));
            end
            PlaySound("AuctionWindowClose");
            gAtr_FullScanState = ATR_FS_NULL;
        end
    end
    
end