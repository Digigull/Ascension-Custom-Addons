AtrPane = {};
AtrPane.__index = AtrPane;

ATR_SHOW_CURRENT	= 1;
ATR_SHOW_HISTORY	= 2;
ATR_SHOW_HINTS		= 3;

-- THE LEDGER SUB-TAB IS 4, NOT 3, AND THE REASON IS WORTH KEEPING (BACKLOG
-- item 8).  Slot 3 looks free -- its button is hidden and the backlog recorded
-- the hint view as dead, "whose sources (Wowecon, GoingPrice, gAtr_ScanDB) are
-- not installed".  Two thirds of that is right and the last third is not:
-- Atr_BuildHints also reads gAtr_ScanDB and your own most recent posting, both
-- of which exist here, and Atr_OnSearchComplete still calls SetToShowHints()
-- when a CREATE-AUCTION search comes back with no current listings.  So the
-- branch is live, it fires on the Sell tab exactly when you have nothing to
-- price against, and taking its slot would have swapped a pricing hint for a
-- ledger at the moment the hint is most useful.  A fourth id costs nothing:
-- PanelTemplates only ever indexes the tabs it is told about, and a hidden one
-- in the middle is invisible to it.
ATR_SHOW_LEDGER		= 4;

function AtrPane.create ()

	local pane = {};
	setmetatable (pane,AtrPane);

	pane.fullStackSize	= 0;

	pane.totalItems		= 0;		-- total in bags for this item

	pane.UINeedsUpdate	= false;
	pane.showWhich		= ATR_SHOW_CURRENT;
	
	pane.activeSearch	= nil;
	pane.sortedHist		= nil;
	pane.marketHist		= nil;		-- the market series for this item (BACKLOG item 1)
	pane.hints			= nil;
	pane.itemLedger		= nil;		-- this item's ledger rows (BACKLOG item 8)
	pane.itemLedgerFor	= nil;		-- ...the name they are for
	pane.itemLedgerRev	= nil;		-- ...and the gAtr_LedgerRev they were built at
	
	pane.hlistScrollOffset	= 0;
	
	pane:ClearSearch();
	
	return pane;
end


-----------------------------------------

-- Is the shared auction query channel spoken for?
--
-- Three things can hold it and they are not the same thing:
--
--   * Atr_Finder_ChannelBusy  -- the Finder engine has a query out RIGHT NOW.
--   * Atr_BP_Running          -- a Batch Post run is going.  It holds the
--   * Atr_SB_ScanRunning      -- Scan Inventory is going.     channel one NAME
--                                at a time, so the engine is genuinely idle in
--                                the gaps; taking it there would cost the run's
--                                next item its live price.
--
-- A run outlasts the engine's own busy flag, which is why both are asked.
local function Atr_Pane_ChannelBusy ()

	if (Atr_Finder_ChannelBusy and Atr_Finder_ChannelBusy()) then return true; end
	if (Atr_BP_Running       and Atr_BP_Running())       then return true; end
	if (Atr_SB_ScanRunning   and Atr_SB_ScanRunning())   then return true; end

	return false;
end

-----------------------------------------

function AtrPane:DoSearch (searchText, exact, rescanThreshold, callback)

	self.currIndex			= nil;
	self.histIndex			= nil;
	self.hintsIndex			= nil;
	
	self.sortedHist			= nil;
	self.marketHist			= nil;
	self.hints				= nil;
	self.itemLedger			= nil;
	self.itemLedgerFor		= nil;
	self.itemLedgerRev		= nil;
	
	self.SS_hilite_itemName	= searchText;		-- by name for search summary

	-- A new search supersedes one that never got the channel.  Cleared before
	-- anything below can set it again.
	self.searchPending		= false;
	
	Atr_ClearBuyState();

	self.activeScan = Atr_FindScan (nil);
	
	Atr_ClearAll();		-- it's fast, might as well just do it now for cleaner UE
	
	self.UINeedsUpdate = false;		-- will be set when scan finishes
			
	self.activeSearch = Atr_NewSearch (searchText, exact, rescanThreshold, callback);
	
	if (exact) then
		self.activeScan = self.activeSearch:GetFirstScan();
	end
	
	local cacheHit = false;
	
	if (searchText ~= "") then
		if (self.activeScan.whenScanned ~= 0) then		-- check whenScanned so we don't rescan cache hits
			self.UINeedsUpdate = true;
			cacheHit = true;

		-- WAIT FOR THE QUERY CHANNEL RATHER THAN RACING IT.
		--
		-- There is one auction query channel and its answers are anonymous:
		-- AUCTION_ITEM_LIST_UPDATE says a batch arrived, never whose it is.
		-- Two drivers paging at once each read the other's pages, call them
		-- duplicates and re-query -- Atr_Finder_ChannelBusy's comment has the
		-- full account, and the failure it ends in is a disconnect, not a
		-- wrong number on screen.
		--
		-- The SELL tab is where the two meet in ordinary use: dropping an item
		-- into the sell slot starts one of these searches, and the Finder
		-- engine is already holding the channel whenever Scan Inventory or a
		-- Batch Post run is going.  So this stands down and Atr_Idle starts it
		-- the moment the channel is free.  Deferred, NOT skipped: the pane is
		-- otherwise fully set up by the lines above, so the item's price simply
		-- arrives a few seconds later instead of not at all.
		elseif (Atr_Pane_ChannelBusy()) then
			self.searchPending = true;

		else
			self.activeSearch:Start();
		end
	end
	
	return cacheHit;
end

-----------------------------------------

function AtrPane:ClearSearch ()
	self:DoSearch ("", true);
end

-----------------------------------------

function AtrPane:GetProcessingState ()
	
	if (self.activeSearch) then
		return self.activeSearch.processing_state;
	end
	
	return KM_NULL_STATE;
end

-----------------------------------------

-- Start a search that stood down for the query channel, if it is free now.
-- Driven from Atr_Idle; returns true if it actually started one.
function AtrPane:ResumePendingSearch ()

	if (not self.searchPending) then return false; end
	if (Atr_Pane_ChannelBusy()) then return false; end

	self.searchPending = false;

	if (self.activeSearch == nil) then return false; end

	self.activeSearch:Start();

	return true;
end

-----------------------------------------

function AtrPane:IsScanEmpty ()
	
	return (self.activeScan == nil or self.activeScan:IsNil());
	
end

-----------------------------------------

function AtrPane:ShowCurrent ()
	
	return self.showWhich == ATR_SHOW_CURRENT;
	
end

-----------------------------------------

function AtrPane:ShowHistory ()
	
	return self.showWhich == ATR_SHOW_HISTORY;
	
end

-----------------------------------------

function AtrPane:ShowHints ()
	
	return self.showWhich == ATR_SHOW_HINTS;
	
end

-----------------------------------------

function AtrPane:SetToShowCurrent ()
	
	self.showWhich = ATR_SHOW_CURRENT;
	
end

-----------------------------------------

function AtrPane:SetToShowHistory ()
	
	self.showWhich = ATR_SHOW_HISTORY;
	
end

-----------------------------------------

function AtrPane:SetToShowHints ()
	
	self.showWhich = ATR_SHOW_HINTS;
	
end

-----------------------------------------

function AtrPane:ShowLedger ()
	
	return self.showWhich == ATR_SHOW_LEDGER;
	
end

-----------------------------------------

function AtrPane:SetToShowLedger ()
	
	self.showWhich = ATR_SHOW_LEDGER;
	
end


