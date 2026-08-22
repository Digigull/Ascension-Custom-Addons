-----------------------------------------------------------------------------
-- BATCH POST -- the right half of the SELL tab's inventory area.
--
-- Owner's request (2026-08-22): "divide the inventory area in half and make the
-- new (right half) called batch post, add items from inventory section into
-- batch by right clicking them.  Press Batch Post button, sells at automatic set
-- price discount, and whatever duration is currently set."
--
-- So: a queue you fill by right-clicking inventory tiles, and one button that
-- posts the whole queue at the price the SELL tab would have recommended for
-- each item, without you having to drop them into the sell box one at a time.
--
-- WHERE THIS SITS.  FRAMEWORK.md §4 says new UI goes in World 2 -- its own panel,
-- its own file -- and this is as close to that as a SELL-tab feature can get.
-- The queue, its panel and the post driver are all here and are all built in
-- Lua; Auctionator.lua only calls in.  What it cannot avoid is that the column
-- it shares the row with (Atr_SellBrowser) belongs to World 1, so the two
-- entry points that place and unplace this panel are the expanded SELL layout's
-- apply/reset pair, and nothing here may leave a widget showing when the player
-- switches to Buy.  Atr_BP_Layout / Atr_BP_Unplace are that contract.
--
-- IT SCANS THE LIVE PRICE FOR EACH ITEM AS IT GOES (owner's request,
-- 2026-08-23: "let's have it scan the current prices at the batch post time.
-- Maybe have a progress bar, prices can change quickly").
--
-- The first build priced off the stored scan database, which made the batch as
-- stale as your last Scan Inventory and -- because that database records a
-- price with no owner attached -- able to undercut your own standing listing.
-- Both are gone.  The run now interleaves:
--
--     for each queued item, in order:
--        if this NAME has not been scanned yet this run:
--             Atr_Finder_StartNameScan (name)      <- one auction query
--             ... wait for it, then read F.GetResults() ...
--             price EVERY queued entry of that name off those live listings
--        post it
--
-- Interleaved rather than scan-everything-then-post-everything, and that is the
-- whole point of the request: the same total wall clock either way, but this
-- way the gap between an item's price being read and that item being listed is
-- one tick instead of the length of the entire scan phase.
--
-- Scanning by NAME and pricing every entry of that name from the one result set
-- is what keeps a queue of five Saronite Ore stacks to one query rather than
-- five.
--
-- WHAT IT TAKES FROM THE RESULTS.  The lowest per-unit buyout among listings
-- that (a) carry this item's variant key and (b) are NOT yours -- `rec.owner`
-- is on every scan record, which is the thing the price database throws away.
-- So the batch no longer undercuts itself, and that limitation is retired.
-- Then the ordinary arithmetic, which is Atr_UpdateRecommendation's line for
-- line:
--
--     buyout per item  = Atr_CalcUndercutPrice (lowest live listing)
--     start  per item  = Atr_CalcStartPrice (buyout)        -- STARTING_DISCOUNT
--     stack prices     = the two above x the stack size in the sell slot
--     duration         = whatever Atr_Duration holds, read once at run start
--
-- THREE THINGS THE SCAN CAN COME BACK WITH, and they are not the same:
--
--   * listings that are not yours  -> undercut the lowest.  The normal case.
--   * NOTHING listed at all        -> there is nothing to undercut, so it falls
--                                     back to Atr_GetAuctionPrice's cascade and
--                                     deliberately does NOT trim it.  Shaving a
--                                     step off a price nobody is competing with
--                                     is pure loss.
--   * the scan could not be run    -> (Finder absent, engine busy, timed out)
--                                     the stored cascade price, undercut, i.e.
--                                     exactly what the first build did.  Said
--                                     out loud in chat, never silently.
--
-- An item with no price from ANY of those is NOT guessed at -- it stays in the
-- queue, greyed, and the run skips it.  Posting at a made-up price is worse
-- than not posting.
--
-- THE DRIVER IS A TICKER, NOT AN EVENT CHAIN.  StartAuction is asynchronous and
-- the client's completion signal differs between a one-stack post and a
-- multi-sell run (Atr_OnAuctionMultiSellUpdate only ever sees the latter).  The
-- one thing that is true in both cases is that the item LEAVES the auction sell
-- slot when the auction goes up, so the driver posts one item, then polls
-- GetAuctionSellItemInfo until the slot is empty before moving on.  That is
-- also what makes it safe to interrupt: nothing is queued server-side, and the
-- one scan that might be in flight is cancelled with it.
--
-- A run is therefore minutes rather than seconds -- a query per distinct name,
-- throttled -- which is why there is a progress bar over the column and why it
-- keeps moving DURING a scan rather than only between items.
-----------------------------------------------------------------------------

local addonName, addonTable = ...;
local F = addonTable and addonTable.Finder;		-- the scan engine's shared surface

local ATR_BP_ROW_H		= 18;		-- one queue row
local ATR_BP_TICK		= 0.25;		-- driver step interval, seconds
local ATR_BP_WAIT		= 6;		-- seconds to wait for one auction to leave
									-- the sell slot before calling it failed
-- A batch run is one server round trip per item and the queue is re-resolved
-- after every one of them (see Atr_BP_Resolve).  Sixty is already the better
-- part of a minute standing at the auctioneer; past that this stops being a
-- convenience and starts being a macro nobody asked for.
local ATR_BP_MAX		= 60;

-- Give one name scan this long before deciding the engine is not going to call
-- back.  The Finder has its own paging retries and runaway guard, so this is a
-- backstop against the callback being dropped entirely (a cancel from somewhere
-- that does not route through Atr_BP_ScanCancelled), not a per-query budget.
local ATR_BP_SCAN_TIMEOUT	= 45;

-- Only used to make the progress bar creep while a scan is out.  A typical name
-- scan is one query plus the throttle; this is the shape of the fill, not a
-- deadline, and it is capped short of the next item's slice either way.
local ATR_BP_SCAN_EXPECT	= 8;

-- The queue.  Session-only, deliberately: a batch you did not post is a
-- decision about right now, and a /reload dropping it is the correct amount of
-- memory (the same reasoning that keeps the Advisor's "skip" state out of
-- AUCTIONATOR_ADVISOR -- FRAMEWORK.md §5).
local gQueue = {};

-- The run in progress, or nil.  { posted, skipped, failed, duration,
-- pending = <entry being posted>, wait = <seconds so far>, done, keep }
local gRun = nil;

local gRowPool = {};		-- recycled queue rows; frames cannot be destroyed

-- The single-item scan the bar is currently showing, and how long it has been
-- showing it.  Nothing to do with gRun -- see Atr_BP_WatchSellScan.
local gWatchLabel = nil;
local gWatchWait  = 0;

-----------------------------------------------------------------------------
-- Small shared helpers
-----------------------------------------------------------------------------

local function Atr_BP_Msg (text)
	if (DEFAULT_CHAT_FRAME) then
		DEFAULT_CHAT_FRAME:AddMessage ("|cffffcc00Auctionator:|r " .. text);
	end
end

local function Atr_BP_Money (copper)
	return (Atr_Bz_MoneyString and Atr_Bz_MoneyString (copper)) or tostring (copper or 0);
end

local function Atr_BP_Key (bag, slot)
	return tostring (bag) .. ":" .. tostring (slot);
end

-- Set `text` on a FontString, trimmed to fit `maxW`.  Measured down rather than
-- bounded with SetWidth, for the reason Atr_Sell_SetHeaderName gives: a 3.3.5
-- FontString WRAPS the moment a width is set, and a wrapped item name inside an
-- 18px row runs into the row under it.
local function Atr_BP_FitText (fs, text, maxW)

	local s = text or "";
	fs:SetText (s);

	while (string.len (s) > 4 and fs:GetStringWidth() > maxW) do
		s = string.sub (s, 1, string.len (s) - 1);
		fs:SetText (s .. "...");
	end
end

-----------------------------------------------------------------------------
-- The progress bar
--
-- It takes the title's row for the length of a run.  A run is minutes, not
-- seconds -- one throttled auction query per distinct name -- so a column that
-- just sat there would read as a hang.
-----------------------------------------------------------------------------

local function Atr_BP_ShowProgress (fraction, text)

	if (not Atr_BP_Progress) then return; end

	local f = tonumber (fraction) or 0;
	if (f < 0) then f = 0; elseif (f > 1) then f = 1; end

	Atr_BP_Progress:SetValue (f);
	if (Atr_BP_Progress.text) then Atr_BP_Progress.text:SetText (text or ""); end
	Atr_BP_Progress:Show();

	if (Atr_BP_Title) then Atr_BP_Title:Hide(); end
end

local function Atr_BP_HideProgress ()
	if (Atr_BP_Progress) then Atr_BP_Progress:Hide(); end
	if (Atr_BP_Title)    then Atr_BP_Title:Show();    end
end

-- Repaint the bar from the run's own counters.
--
-- Each queue entry is one unit of work.  An entry whose name is out for a scan
-- fills up to 0.8 of its own unit as the query runs -- the fill is driven off
-- the tick counter, not off a real estimate, and it is capped short of the
-- item's full slice so it can never run ahead of what has happened.  Without
-- it the bar would freeze for seconds at exactly the moments the run is doing
-- the most work, which is the failure this bar exists to prevent.
local function Atr_BP_PaintProgress ()

	if (gRun == nil) then return; end

	local total = gRun.total;
	if (total == nil or total < 1) then total = 1; end

	local dealt = gRun.posted + gRun.skipped + gRun.failed;
	local done  = dealt;
	local label;

	if (gRun.scanName) then
		local part = (gRun.scanWait or 0) / ATR_BP_SCAN_EXPECT;
		if (part > 0.95) then part = 0.95; end
		done  = done + 0.8 * part;
		label = string.format ("Scanning %s  (%d/%d)", gRun.scanName,
							   math.min (dealt + 1, total), total);
	else
		label = string.format ("Posting  %d/%d", math.min (dealt + 1, total), total);
	end

	Atr_BP_ShowProgress (done / total, label);
end

-- THE BAR ALSO SHOWS ORDINARY SINGLE-ITEM SEARCHES (owner's request,
-- 2026-08-23: "link up the progress bar to single item scans, like when i just
-- choose one to sell").
--
-- Dropping one item in the sell box makes the pane run exactly the same
-- throttled query a batch run makes per name, and the column is sitting right
-- there saying nothing for the length of it.  So the ticker runs for as long as
-- the column is placed, not only during a run, and when there is no run it asks
-- the sell pane what it is doing.
--
-- Atr_Sell_SearchLabel is a POLL, and that is the design rather than laziness:
-- a sell search starts from at least four places and gains more whenever
-- somebody adds a path, so a list of hooks goes stale silently where asking
-- cannot.  See its comment in Auctionator.lua.
--
-- The fill creeps off the tick counter exactly as the batch's own scan fill
-- does, and for the same reason: the client will not say how many pages are
-- coming, and a bar frozen at zero for six seconds reads as a hang.
local function Atr_BP_WatchSellScan (dt)

	local label = (Atr_BP_Panel and Atr_BP_Panel:IsShown() and Atr_Sell_SearchLabel)
	              and Atr_Sell_SearchLabel() or nil;

	if (label == nil) then
		-- Only tear down if WE put something up; the bar is shared with the run.
		if (gWatchLabel) then
			gWatchLabel = nil;
			gWatchWait  = 0;
			Atr_BP_HideProgress();
			Atr_BP_Build();			-- the title text under it may be stale
		end
		return;
	end

	if (gWatchLabel ~= label) then
		gWatchLabel = label;
		gWatchWait  = 0;
	end

	gWatchWait = gWatchWait + dt;

	local part = gWatchWait / ATR_BP_SCAN_EXPECT;
	if (part > 0.95) then part = 0.95; end

	Atr_BP_ShowProgress (part, "Scanning " .. label .. "...");
end

-- Atr_CalcUndercutPrice bottoms out at 0 for a 1c item, and a zero buyout is
-- not a free listing -- it is an auction with no buyout at all.
local function Atr_BP_Undercut (price)
	local p = math.floor (tonumber (price) or 0);
	if (p <= 0) then return nil; end
	p = math.floor (tonumber (Atr_CalcUndercutPrice and Atr_CalcUndercutPrice (p) or p) or 0);
	if (p < 1) then p = 1; end
	return p;
end

-- The STORED per-item buyout: what the price database and its fallbacks think
-- this is worth, undercut.  This is the run's fallback now, not its source --
-- see Atr_BP_LiveUnit for what a run actually prices off.
--
-- Variant-keyed for the same reason Atr_SB_BestMethod is (BACKLOG item 4, the
-- read half): a name-only read answers the ATR_PV_ANY slot, which only a full
-- scan writes, so the price a Sell or Buy search just found would be invisible
-- here.
--
-- `raw` skips the undercut.  Its one caller is the scanned-and-empty case: with
-- no competing listing there is nothing to undercut, and trimming a step off a
-- price nobody is bidding against is pure loss.
function Atr_BP_UnitPrice (link, name, raw)

	if (link == nil) then return nil; end
	if (name == nil) then name = GetItemInfo (link); end
	if (name == nil or Atr_GetAuctionPrice == nil) then return nil; end

	local vkey = (Atr_VariantKey) and Atr_VariantKey (link) or nil;
	local ah   = tonumber (Atr_GetAuctionPrice (name, vkey)) or 0;

	if (ah <= 0) then return nil; end
	if (raw) then return math.floor (ah); end

	return Atr_BP_Undercut (ah);
end

-- Read the just-finished name scan and answer, for ONE queued link: the lowest
-- per-unit buyout among listings of that item's variant that are not yours.
-- nil means the scan found no such listing -- which is a real answer ("nobody
-- is selling this"), not a failure, and the caller treats it as one.
--
-- **`rec.owner` is the whole reason this exists.** It is on every scan record
-- and the price database throws it away, so a batch priced off the database
-- would undercut its own standing listing every time you ran it twice.  Here
-- your own rows are simply dropped before the minimum is taken.
--
-- A listing whose owner has not arrived from the server yet (`owner` nil) is
-- treated as somebody else's.  That errs toward seeing competition that might
-- be your own, which costs one undercut step; the other way round would mean
-- ignoring real competition and listing above the market.
--
-- Global rather than local ONLY so batch-price-smoke.lua can drive it. Same-name
-- variants have escaped this addon three times (BACKLOG items 12, 15, 16) and
-- this function does variant matching AND owner filtering over a result order
-- nobody controls -- which is exactly the shape sell-variant-smoke.lua exists
-- for.  Keep it global.
function Atr_BP_LiveUnit (link, name)

	if (F == nil or F.GetResults == nil) then return nil; end

	local res = F.GetResults();
	if (type (res) ~= "table") then return nil; end

	local want = (Atr_VariantKey) and Atr_VariantKey (link) or nil;
	local me   = UnitName and UnitName ("player") or nil;
	local low  = nil;

	for i = 1, #res do
		local rec = res[i];
		if (rec and rec.name == name and (me == nil or rec.owner ~= me)) then

			-- Same-name variants are genuinely different items on this server
			-- (BACKLOG item 12 part 2).  Price against this one's own variant,
			-- and only fall back to name-matching when a key cannot be read.
			local key = (Atr_VariantKey and rec.link) and Atr_VariantKey (rec.link) or nil;

			if (want == nil or key == nil or key == want) then
				local cnt = tonumber (rec.count) or 1;
				if (cnt < 1) then cnt = 1; end
				local bo = tonumber (rec.buyoutPrice) or 0;
				if (bo > 0) then
					local unit = math.floor (bo / cnt);
					if (unit > 0 and (low == nil or unit < low)) then low = unit; end
				end
			end
		end
	end

	return low;
end

-- The per-item buyout an entry will actually post at, given what the run knows
-- about it so far.  Three cases, in the order the header lists them.
function Atr_BP_EffectiveUnit (entry)

	if (entry == nil) then return nil; end

	if (entry.scanned) then
		if (entry.liveUnit) then
			return Atr_BP_Undercut (entry.liveUnit);		-- undercut the market
		end
		-- Scanned and nothing is listed: nothing to undercut.
		return Atr_BP_UnitPrice (entry.link, entry.name, true);
	end

	-- Not scanned (yet, or at all): the stored cascade, undercut, which is what
	-- the pre-scan build did for everything.
	return Atr_BP_UnitPrice (entry.link, entry.name);
end

-- The duration the SELL tab is currently set to.  Falls back to the saved
-- default rather than to a literal, so a batch never posts for longer than the
-- player has chosen anywhere.
function Atr_BP_Duration ()

	local d = nil;
	if (Atr_Duration and UIDropDownMenu_GetSelectedValue) then
		d = tonumber (UIDropDownMenu_GetSelectedValue (Atr_Duration));
	end

	if (d == nil) then
		if     (AUCTIONATOR_DEF_DURATION == "S") then d = 1;
		elseif (AUCTIONATOR_DEF_DURATION == "L") then d = 3;
		else                                          d = 2;
		end
	end

	return d;
end

-----------------------------------------------------------------------------
-- The queue
-----------------------------------------------------------------------------

function Atr_BP_Count ()
	return #gQueue;
end

function Atr_BP_Running ()
	return gRun ~= nil;
end

-- Is this bag slot already queued?  Used by the inventory browser to mark the
-- tile, so a right-click that did nothing is visibly distinguishable from one
-- that queued something.
function Atr_BP_Contains (bag, slot)
	for _, e in ipairs (gQueue) do
		if (e.bag == bag and e.slot == slot) then return true; end
	end
	return false;
end

-- Find a bag slot holding `link` that no queue entry has claimed yet.  A slot
-- whose stack size matches what was queued wins; failing that, any slot with
-- the item does, and the caller takes the count it actually finds.
local function Atr_BP_FindSlot (link, wantCount, claimed)

	if (link == nil or GetContainerNumSlots == nil) then return nil; end

	local anyBag, anySlot, anyCount;

	for bag = 0, (NUM_BAG_SLOTS or 4) do
		for slot = 1, (GetContainerNumSlots (bag) or 0) do
			if (not claimed[Atr_BP_Key (bag, slot)]) then
				if (GetContainerItemLink (bag, slot) == link) then
					local _, cnt = GetContainerItemInfo (bag, slot);
					cnt = cnt or 1;
					if (cnt == wantCount) then return bag, slot, cnt; end
					if (anyBag == nil) then anyBag, anySlot, anyCount = bag, slot, cnt; end
				end
			end
		end
	end

	return anyBag, anySlot, anyCount;
end

-- Re-point every entry at a bag slot that really holds its item, and drop the
-- ones whose item has gone.  Bags reshuffle constantly -- and a batch run empties
-- slots as it goes -- so a queue held as (bag, slot) pairs is stale the moment
-- anything moves.  The LINK is what was queued; the slot is only ever a hint.
function Atr_BP_Resolve ()

	if (GetContainerItemLink == nil) then return; end

	local claimed, keep = {}, {};

	-- Entries still sitting where they were keep their slot; claim those first
	-- so a re-home below cannot steal one out from under them.
	for _, e in ipairs (gQueue) do
		if (GetContainerItemLink (e.bag, e.slot) == e.link) then
			claimed[Atr_BP_Key (e.bag, e.slot)] = true;
		end
	end

	for _, e in ipairs (gQueue) do
		if (GetContainerItemLink (e.bag, e.slot) ~= e.link) then
			local b, s, n = Atr_BP_FindSlot (e.link, e.count, claimed);
			if (b) then
				e.bag, e.slot, e.count = b, s, n;
				claimed[Atr_BP_Key (b, s)] = true;
			end
		end

		if (GetContainerItemLink (e.bag, e.slot) == e.link) then
			local _, cnt = GetContainerItemInfo (e.bag, e.slot);
			e.count = cnt or e.count;
			-- GetItemInfo can have been cold when this was queued, in which case
			-- the "name" is the link.  Atr_BP_PostOne compares it against the
			-- sell slot's name, so a stale one there would fail every post.
			e.name  = GetItemInfo (e.link) or e.name;
			table.insert (keep, e);
		end
	end

	gQueue = keep;
end

-- Queue one bag slot.  Returns true when the queue actually changed, so the
-- caller knows whether a rebuild is worth doing.
function Atr_BP_Add (bag, slot, link)

	if (bag == nil or slot == nil) then return false; end

	link = link or (GetContainerItemLink and GetContainerItemLink (bag, slot));
	if (link == nil) then return false; end

	if (gRun) then
		Atr_BP_Msg ("a batch is posting -- cancel it before changing the queue.");
		return false;
	end

	if (Atr_BP_Contains (bag, slot)) then return false; end

	if (#gQueue >= ATR_BP_MAX) then
		Atr_BP_Msg (string.format ("the batch holds %d items already -- post or clear it first.", ATR_BP_MAX));
		return false;
	end

	local texture, count = GetContainerItemInfo (bag, slot);
	local name, _, _, _, _, _, _, _, _, icon = GetItemInfo (link);

	table.insert (gQueue, {
		bag		= bag,
		slot	= slot,
		link	= link,
		name	= name or link,
		count	= count or 1,
		icon	= texture or icon,
	});

	return true;
end

function Atr_BP_RemoveAt (index)
	if (gRun) then
		Atr_BP_Msg ("a batch is posting -- cancel it before changing the queue.");
		return false;
	end
	if (gQueue[index] == nil) then return false; end
	table.remove (gQueue, index);
	return true;
end

-- Take one bag slot back out of the queue.  The inventory browser's right-click
-- toggle needs this: it knows a slot, not an index.
function Atr_BP_RemoveSlot (bag, slot)
	for i, e in ipairs (gQueue) do
		if (e.bag == bag and e.slot == slot) then
			return Atr_BP_RemoveAt (i);
		end
	end
	return false;
end

function Atr_BP_Clear ()
	if (gRun) then Atr_BP_Cancel (true); end
	gQueue = {};
	Atr_BP_Build();
	if (Atr_SB_Build) then Atr_SB_Build(); end
end

-----------------------------------------------------------------------------
-- The panel
--
-- Everything is built here rather than in Auctionator.xml for the reason the
-- drop zone and the Ignore button already are: this lives beside widgets the
-- panel's other tabs share, so it has to be created, placed and unplaced per
-- tab.  Nothing below is anchored to a shared widget: the two buttons hang off
-- this column's own list, as Scan Inventory hangs off the inventory.
-----------------------------------------------------------------------------

-- A label above a column.  Its own frame so it can be shown and hidden with
-- one call and cannot be clipped by the scroll frame it titles.
local function Atr_BP_LabelEnsure (globalName, text)

	if (_G[globalName]) then return _G[globalName]; end
	if (not Atr_Main_Panel or not CreateFrame) then return nil; end

	local f = CreateFrame ("Frame", globalName, Atr_Main_Panel);
	f:SetWidth  (200);
	f:SetHeight (14);
	local fs = f:CreateFontString (globalName .. "_Text", "OVERLAY", "GameFontNormalSmall");
	fs:SetPoint ("LEFT", 0, 0);
	fs:SetText (text);
	f.text = fs;
	f:Hide();

	return f;
end

function Atr_BP_Ensure ()

	if (Atr_BP_Panel) then return Atr_BP_Panel; end
	if (not Atr_Main_Panel or not CreateFrame) then return nil; end

	local p = CreateFrame ("Frame", "Atr_BP_Panel", Atr_Main_Panel);
	p:Hide();

	-- Same art as Atr_SellBrowser so the two halves read as one area.  The
	-- right inset reaches under the scroll bar, which is what stops a bare
	-- strip appearing beside the list.
	local list = CreateFrame ("ScrollFrame", "Atr_BP_List", p, "UIPanelScrollFrameTemplate");
	list:SetBackdrop ({
		bgFile = "Interface\\CharacterFrame\\UI-Party-Background",
		tile = true, tileSize = 256,
		insets = { left = 0, right = -24, top = 0, bottom = 0 },
	});

	local content = CreateFrame ("Frame", "Atr_BP_Content", list);
	content:SetWidth  (10);
	content:SetHeight (10);
	list:SetScrollChild (content);

	local title = p:CreateFontString ("Atr_BP_Title", "OVERLAY", "GameFontNormalSmall");
	title:SetPoint ("BOTTOMLEFT", list, "TOPLEFT", 2, 3);
	title:SetText ("Batch Post");

	-- The progress bar takes the title's row while a run is going, so it costs
	-- no layout: a run has nothing to say that the title was saying.  A run is
	-- minutes long -- one throttled auction query per distinct name -- and the
	-- bar is the only thing on screen that says the addon is still working.
	local bar = CreateFrame ("StatusBar", "Atr_BP_Progress", p);
	bar:SetStatusBarTexture ("Interface\\TargetingFrame\\UI-StatusBar");
	bar:SetStatusBarColor (0.20, 0.55, 0.25);
	bar:SetMinMaxValues (0, 1);
	bar:SetValue (0);

	bar.bg = bar:CreateTexture (nil, "BACKGROUND");
	bar.bg:SetAllPoints (bar);
	bar.bg:SetTexture (0, 0, 0, 0.55);

	-- No SetWidth on this, ever: a 3.3.5 FontString wraps the moment one is set
	-- and nothing clips the result.  Left unsized it measures its own text,
	-- which is also what lets a CENTER anchor centre it with no arithmetic.
	bar.text = bar:CreateFontString ("Atr_BP_ProgressText", "OVERLAY", "GameFontHighlightSmall");
	bar.text:SetPoint ("CENTER", bar, "CENTER", 0, 0);

	bar:Hide();

	-- The empty-queue caption.  A blank panel beside a full inventory reads as
	-- broken; this says what the right half is FOR, which is the one thing a
	-- new column has to do.
	local hint = content:CreateFontString ("Atr_BP_Hint", "OVERLAY", "GameFontDisableSmall");
	hint:SetPoint ("TOPLEFT", 8, -8);
	hint:SetText ("Right-click items on the left\nto add them here.");

	-- The two buttons sit under this column, at its bottom-left corner -- the
	-- batch half of the action row Atr_BP_Layout places.  Children of the PANEL
	-- rather than of Atr_BP_Panel so their frame level can be raised clear of
	-- the headings-bar divider independently of the list, which must stay under
	-- it.
	--
	-- Narrow: a few pixels of padding around the label, and around "Cancel",
	-- which is the only other caption the Go button wears.  A pair wider than
	-- this used to run out from under the column it belongs to.
	local go = CreateFrame ("Button", "Atr_BP_Go", Atr_Main_Panel, "UIPanelButtonTemplate");
	go:SetWidth (72);
	go:SetHeight (18);
	go:SetText ("Batch Post");
	local gofs = go:GetFontString();
	if (gofs) then gofs:SetFontObject ("GameFontNormalSmall"); end
	go:SetScript ("OnClick", function () Atr_BP_GoClicked(); end);
	go:Hide();

	local clr = CreateFrame ("Button", "Atr_BP_ClearButton", Atr_Main_Panel, "UIPanelButtonTemplate");
	clr:SetWidth (48);
	clr:SetHeight (18);
	clr:SetText ("Clear");
	local clrfs = clr:GetFontString();
	if (clrfs) then clrfs:SetFontObject ("GameFontNormalSmall"); end
	clr:SetScript ("OnClick", function () Atr_BP_Clear(); end);
	clr:Hide();

	Atr_BP_LabelEnsure ("Atr_BP_InvLabel", "Inventory");

	-- The clock.  It drives two things and runs for as long as the column is
	-- placed, not only during a run -- the second of them is the whole reason
	-- for that: with no run going it watches for an ordinary single-item sell
	-- search and puts that on the same bar.
	--
	-- Parented to UIParent, not to the panel: hiding the panel (a tab switch
	-- mid-run) must reach Atr_BP_Cancel's bookkeeping, and an OnUpdate on a
	-- hidden frame never fires.  Atr_BP_Unplace is what stops it.
	local tick = CreateFrame ("Frame", "Atr_BP_Ticker", UIParent);
	tick:Hide();
	tick.elapsed = 0;
	tick:SetScript ("OnUpdate", function (self, e)
		self.elapsed = self.elapsed + (e or 0);
		if (self.elapsed < ATR_BP_TICK) then return; end
		self.elapsed = 0;
		if (gRun) then
			Atr_BP_Step();
		else
			Atr_BP_WatchSellScan (ATR_BP_TICK);
		end
	end);

	return p;
end

-- Place the column and show it.  x/y are Atr_Main_Panel-relative, matching the
-- units the rest of the expanded layout uses.
function Atr_BP_Layout (x, y, w, h, labelX, labelY, labelW)

	local p = Atr_BP_Ensure();
	if (not p) then return; end

	p:ClearAllPoints();
	p:SetPoint ("TOPLEFT", Atr_Main_Panel, "TOPLEFT", x, y);
	p:SetWidth  (w);
	p:SetHeight (h + 16);

	Atr_BP_List:ClearAllPoints();
	Atr_BP_List:SetPoint ("TOPLEFT", p, "TOPLEFT", 0, -16);
	Atr_BP_List:SetWidth  (w);
	Atr_BP_List:SetHeight (h);

	Atr_BP_Content:SetWidth (w - 24);

	if (Atr_BP_Progress) then
		Atr_BP_Progress:ClearAllPoints();
		Atr_BP_Progress:SetPoint ("TOPLEFT", p, "TOPLEFT", 1, -1);
		Atr_BP_Progress:SetWidth  (w - 26);
		Atr_BP_Progress:SetHeight (13);
	end

	if (Atr_BP_InvLabel) then
		Atr_BP_InvLabel:ClearAllPoints();
		Atr_BP_InvLabel:SetPoint ("BOTTOMLEFT", Atr_Main_Panel, "TOPLEFT", labelX, labelY);
		Atr_BP_InvLabel:SetWidth (labelW or 200);
		Atr_BP_InvLabel:Show();
	end

	-- THE BUTTONS RIDE THIS COLUMN, and nothing else.
	--
	-- Two earlier placements are worth keeping in view, because each fixed a
	-- real overlap and the current one has to keep both fixed:
	--
	--   * At the batch column's left edge on the headings bar (panel x 298..451)
	--     Clear sat squarely on top of the Current tab -- Atr_ListTabs owns
	--     x 361..611 (owner's screenshot, 2026-08-23).
	--   * Chained onto Profit Margin instead, the four buttons made one long row
	--     that started under the inventory and ended at panel x ~331 -- clear of
	--     the tabs, but reading as four inventory buttons, with nothing under the
	--     batch column at all (owner's screenshot, 2026-08-24).
	--
	-- So: anchored to Atr_BP_List's bottom-left corner, tight under the list, and
	-- narrow enough that the pair ends at panel x ~424, well inside this column
	-- (298..574).  x is no longer what keeps it off the tabs, though -- y is:
	-- the columns were shortened 168 -> 150 so both rows sit at -234..-252, six
	-- pixels above the tab strip, which is the only reason a pair starting at
	-- x 298 is safe at all.  ATR_SELL_BROWSER_H carries that arithmetic; do not
	-- lengthen the columns without moving these.
	--
	-- The frame level is raised for the same reason Scan Inventory's is: not
	-- load-bearing at this y, but it is what stops the divider burying a button
	-- if the results block is ever nudged back up.
	if (Atr_BP_List and Atr_BP_Go) then
		local lvl = ((Atr_HeadingsBar and Atr_HeadingsBar:GetFrameLevel()) or 5) + 5;
		local gap = ATR_SELL_BTN_GAP or 6;

		Atr_BP_Go:ClearAllPoints();
		Atr_BP_Go:SetPoint ("TOPLEFT", Atr_BP_List, "BOTTOMLEFT", 0, ATR_SELL_BTNROW_Y or -2);
		Atr_BP_Go:SetFrameLevel (lvl);
		Atr_BP_Go:Show();

		Atr_BP_ClearButton:ClearAllPoints();
		Atr_BP_ClearButton:SetPoint ("LEFT", Atr_BP_Go, "RIGHT", gap, 0);
		Atr_BP_ClearButton:SetFrameLevel (lvl);
		Atr_BP_ClearButton:Show();
	end

	p:Show();

	-- The ticker runs while the column is placed: with no batch going it is the
	-- single-item scan watcher.  Cheap -- two global reads every 0.25s.
	if (Atr_BP_Ticker and not Atr_BP_Ticker:IsShown()) then
		Atr_BP_Ticker.elapsed = 0;
		Atr_BP_Ticker:Show();
	end

	Atr_BP_Build();
end

-- The other half of the contract with the expanded SELL layout: leave nothing
-- showing once the player is on another tab.
function Atr_BP_Unplace ()
	if (gRun) then Atr_BP_Cancel (true); end

	-- The one place the ticker stops.  Cancel and Finish deliberately leave it
	-- running: the column is still up and still watching for single-item scans.
	if (Atr_BP_Ticker)		then Atr_BP_Ticker:Hide();		end
	gWatchLabel = nil;
	gWatchWait  = 0;

	if (Atr_BP_Progress)	then Atr_BP_Progress:Hide();	end
	if (Atr_BP_Panel)		then Atr_BP_Panel:Hide();		end
	if (Atr_BP_Go)			then Atr_BP_Go:Hide();			end
	if (Atr_BP_ClearButton)	then Atr_BP_ClearButton:Hide();	end
	if (Atr_BP_InvLabel)	then Atr_BP_InvLabel:Hide();	end
end

-----------------------------------------------------------------------------
-- Drawing the queue
-----------------------------------------------------------------------------

local function Atr_BP_RowEnsure (i)

	if (gRowPool[i]) then return gRowPool[i]; end
	if (not Atr_BP_Content or not CreateFrame) then return nil; end

	local r = CreateFrame ("Button", nil, Atr_BP_Content);
	r:SetHeight (ATR_BP_ROW_H);
	r:RegisterForClicks ("LeftButtonUp", "RightButtonUp");

	r.icon = r:CreateTexture (nil, "ARTWORK");
	r.icon:SetWidth (16);
	r.icon:SetHeight (16);
	r.icon:SetPoint ("LEFT", 2, 0);

	r.name = r:CreateFontString (nil, "OVERLAY", "GameFontHighlightSmall");
	r.name:SetPoint ("LEFT", r.icon, "RIGHT", 4, 0);
	r.name:SetJustifyH ("LEFT");

	r.price = r:CreateFontString (nil, "OVERLAY", "GameFontHighlightSmall");
	r.price:SetPoint ("RIGHT", -4, 0);
	r.price:SetJustifyH ("RIGHT");

	r:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");

	r:SetScript ("OnClick", function (self)
		if (Atr_BP_RemoveAt (self.qIndex)) then
			-- The inventory tile that just lost its green wash needs repainting
			-- too, and Atr_SB_Build's tail repaints this list on the way back.
			if (Atr_SB_Build) then Atr_SB_Build(); else Atr_BP_Build(); end
		end
	end);

	r:SetScript ("OnEnter", function (self)
		if (self.itemLink and GameTooltip) then
			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
			GameTooltip:SetHyperlink (self.itemLink);
			GameTooltip:AddLine ("Click to take out of the batch", 0.6, 0.6, 0.6);
			GameTooltip:Show();
		end
	end);

	r:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

	gRowPool[i] = r;
	return r;
end

function Atr_BP_Build ()

	if (not Atr_BP_Content) then return; end

	-- A run is emptying bag slots underneath us; re-pointing the queue mid-post
	-- would drop the entry currently in the sell slot.  The driver re-resolves
	-- between items instead.
	if (not gRun) then Atr_BP_Resolve(); end

	local width = (Atr_BP_Content:GetWidth() or 240);
	local total, priced = 0, 0;
	local y = -2;

	for i, e in ipairs (gQueue) do
		local r = Atr_BP_RowEnsure (i);
		if (r) then
			local unit  = Atr_BP_EffectiveUnit (e);
			local stack = unit and (unit * (e.count or 1)) or nil;

			r.qIndex   = i;
			r.itemLink = e.link;

			r:SetWidth (width - 4);
			r:ClearAllPoints();
			r:SetPoint ("TOPLEFT", 2, y);

			r.icon:SetTexture (e.icon);

			local label = e.name or "";
			if ((e.count or 1) > 1) then label = label .. " x" .. e.count; end
			Atr_BP_FitText (r.name, label, width - 100);

			if (stack) then
				-- Quality colour, applied AFTER the trim: chopping a string that
				-- already carried |cxxxxxxxx cuts the escape in half and prints
				-- its tail as text (same trap as Atr_Sell_SetHeaderName).
				local _, _, quality = GetItemInfo (e.link);
				local cr, cg, cb = 1, 0.82, 0;
				if (quality and GetItemQualityColor) then
					local qr, qg, qb = GetItemQualityColor (quality);
					if (qr) then cr, cg, cb = qr, qg, qb; end
				end
				r.name:SetTextColor (cr, cg, cb);
				r.price:SetText (Atr_BP_Money (stack));
				total  = total + stack;
				priced = priced + 1;
			else
				-- The run will skip this one, and it has to look skipped.
				r.name:SetTextColor (0.55, 0.55, 0.55);
				r.price:SetText ("|cff888888no price|r");
			end

			r:Show();
			y = y - ATR_BP_ROW_H;
		end
	end

	for i = #gQueue + 1, #gRowPool do
		gRowPool[i]:Hide();
	end

	Atr_BP_Content:SetHeight (math.max (10, -y + 4));

	if (Atr_BP_Hint) then
		if (#gQueue == 0) then Atr_BP_Hint:Show(); else Atr_BP_Hint:Hide(); end
	end

	-- The title text is kept current even while the progress bar covers it, so
	-- it is right the instant the run ends and the bar goes away.
	if (Atr_BP_Title) then
		if (#gQueue == 0) then
			Atr_BP_Title:SetText ("Batch Post");
		else
			Atr_BP_Title:SetText (string.format ("Batch Post (%d)  %s", #gQueue, Atr_BP_Money (total)));
		end
	end

	if (Atr_BP_Go and not gRun) then
		Atr_BP_Go:SetText ("Batch Post");
		if (priced > 0) then Atr_BP_Go:Enable(); else Atr_BP_Go:Disable(); end
	end
end

-----------------------------------------------------------------------------
-- Posting the batch
-----------------------------------------------------------------------------

local function Atr_BP_SetGoButton (text, enabled)
	if (not Atr_BP_Go) then return; end
	Atr_BP_Go:SetText (text or "Batch Post");
	if (enabled == false) then Atr_BP_Go:Disable(); else Atr_BP_Go:Enable(); end
end

-- Everything a completed post has to tell the rest of the addon.  The normal
-- Create Auction path gets this from Atr_OnAuctionMultiSellUpdate, which only
-- fires for a multi-stack run and only when gAtr_SellTriggeredByAuctionator is
-- up -- and this driver deliberately leaves that flag alone, so that handler
-- skips a batch entirely and the bookkeeping is done here instead.  pcall'd
-- because a batch that half-records is still a batch that posted.
local function Atr_BP_Record (entry, stackPrice, duration)

	local unit = math.floor (stackPrice / (entry.count or 1));

	if (type (Atr_AddToScan) == "function") then
		pcall (Atr_AddToScan, entry.name, entry.count, stackPrice, 1);
	end
	if (type (Atr_AddHistoricalPrice) == "function") then
		pcall (Atr_AddHistoricalPrice, entry.name, unit, entry.count, entry.link);
	end
	if (type (Atr_Ledger_RecordPost) == "function") then
		pcall (Atr_Ledger_RecordPost, entry.name, entry.link, entry.count, stackPrice, 1);
	end
	if (type (Atr_LogMsg) == "function") then
		pcall (Atr_LogMsg, entry.link, entry.count, stackPrice, 1);
	end
end

function Atr_BP_Cancel (quiet)

	if (not gRun) then return; end

	local r = gRun;
	gRun = nil;

	-- The ticker keeps running: the column is still placed, so it goes back to
	-- watching for single-item scans.  Only Atr_BP_Unplace stops it.
	if (ClearCursor) then ClearCursor(); end
	Atr_BP_HideProgress();

	-- A name scan may still be out.  gRun is already nil above, so the engine's
	-- cancel path calling back into Atr_BP_ScanCancelled short-circuits there
	-- rather than recursing into here.
	if (r.scanName and Atr_Finder_CancelSearch) then
		pcall (Atr_Finder_CancelSearch, false);
	end

	-- A quiet cancel is a tab switch or a Clear: the caller is already tearing
	-- the column down or repainting it, and calling Atr_SB_Build from inside
	-- Atr_ResetSellExpandedLayout would re-show the browser that function is
	-- three lines away from hiding.
	if (quiet) then return; end

	Atr_BP_Msg (string.format ("batch stopped -- %d posted, %d skipped, %d failed, %d left.",
							   r.posted, r.skipped, r.failed, math.max (0, #gQueue)));

	Atr_BP_Build();
	if (Atr_SB_Build) then Atr_SB_Build(); end
end

local function Atr_BP_Finish ()

	local r = gRun;
	gRun = nil;

	Atr_BP_HideProgress();		-- the ticker stays up; see Atr_BP_Cancel

	if (r) then
		local parts = string.format ("%d posted", r.posted);
		if (r.skipped > 0) then parts = parts .. ", " .. r.skipped .. " skipped (no price)"; end
		if (r.failed  > 0) then parts = parts .. ", " .. r.failed  .. " failed"; end
		Atr_BP_Msg ("batch done -- " .. parts .. ".");
	end

	Atr_BP_Build();
	if (Atr_SB_Build) then Atr_SB_Build(); end
end

-----------------------------------------------------------------------------
-- The scan phase
-----------------------------------------------------------------------------

-- The engine called back.  Price EVERY queued entry of this name off the
-- listings it just brought in -- one query serves all of that item's stacks,
-- which is the reason the run scans by name rather than by queue entry.
local function Atr_BP_ScanFinished (name)

	if (gRun == nil or gRun.scanName ~= name) then return; end	-- stale callback

	gRun.scanned[name] = true;
	gRun.scanName = nil;
	gRun.scanWait = 0;

	for _, e in ipairs (gQueue) do
		if (e.name == name) then
			e.liveUnit = Atr_BP_LiveUnit (e.link, name);	-- nil = nothing listed
			e.scanned  = true;
		end
	end

	-- Repaint: the column's prices and total are what the run is about to post
	-- at, and they have just changed under the player.
	Atr_BP_Build();
	Atr_BP_PaintProgress();
end

-- Send one name to the scan engine.  Returns false when it could not be sent,
-- which the caller treats as "price this one from the database" rather than as
-- a failure -- posting at a stale price beats not posting.
local function Atr_BP_StartScan (name)

	if (type (Atr_Finder_StartNameScan) ~= "function") then return false; end
	if (F == nil or F.GetState == nil or F.GetState() ~= F.State_NULL) then return false; end

	-- The callback closes over the name so a scan that finishes after the run
	-- moved on (a cancel, a timeout) is recognised as stale and dropped.
	local ok = Atr_Finder_StartNameScan (name, function ()
		Atr_BP_ScanFinished (name);
	end);

	if (not ok) then return false; end

	gRun.scanName = name;
	gRun.scanWait = 0;
	Atr_BP_PaintProgress();

	return true;
end

-- Called by Atr_Finder_CancelSearch, the same way that path already tells the
-- Sell tab's Scan Inventory driver.  Our per-name callback rides gFdr_OnFinish,
-- which a cancel clears, so without this a batch waiting on a scan would sit
-- there until its own timeout.
function Atr_BP_ScanCancelled ()

	if (gRun == nil or gRun.scanName == nil) then return; end

	Atr_BP_Msg ("the price scan was cancelled -- batch stopped.");
	Atr_BP_Cancel (true);
	Atr_BP_Build();
end

-- Put one bag slot into the auction sell slot and start its auction.
-- Returns "posted", "skipped", "failed" or "nomoney".
local function Atr_BP_PostOne (entry, duration)

	-- Whatever the scan phase learned about this entry, or the stored price if
	-- it learned nothing.  Atr_BP_EffectiveUnit is the single place those three
	-- cases are decided; nothing here re-decides them.
	local unit = Atr_BP_EffectiveUnit (entry);
	if (unit == nil) then return "skipped"; end

	-- Anything already on the cursor would be swapped INTO the bag slot we are
	-- about to pick up from.
	ClearCursor();

	PickupContainerItem (entry.bag, entry.slot);
	if (GetCursorInfo() ~= "item") then
		if (ClearCursor) then ClearCursor(); end
		return "failed";
	end

	-- ClickAuctionSellItemButton, NOT Atr_ClickAuctionSellItemButton.  The
	-- wrapper raises gAtr_ClickAuctionSell, which sends Atr_OnNewAuctionUpdate
	-- into gSellPane:DoSearch -- a full auction query per item, on the same
	-- throttled channel this run needs, for a price we are not going to use.
	-- The duration guard is the one thing the wrapper does that we still need:
	-- the client computes the deposit off AuctionFrameAuctions.duration and it
	-- is nil until the dropdown has been touched.
	if (AuctionFrameAuctions and AuctionFrameAuctions.duration == nil) then
		AuctionFrameAuctions.duration = 1;
	end
	ClickAuctionSellItemButton();
	ClearCursor();

	local sellName, _, sellCount = GetAuctionSellItemInfo();
	if (sellName == nil or sellName == "") then
		return "failed";			-- soulbound, conjured, already listed, bag locked
	end

	-- THE ONE CHECK THAT MUST NOT BE SKIPPED.  Bag slots move on their own and
	-- the previous post may have put an item back while this one was picking
	-- up; if the slot does not hold what we priced, posting anyway would list
	-- some other item at this one's estimate.  Bail instead.
	if (entry.name and sellName ~= entry.name) then
		return "failed";
	end

	-- The slot is authoritative about how many are in it -- the queue's count is
	-- only as fresh as the last rebuild.  Price off what is really there.
	local count = tonumber (sellCount) or entry.count or 1;
	if (count < 1) then count = 1; end

	local stackBuy   = unit * count;
	local stackStart = (Atr_CalcStartPrice and Atr_CalcStartPrice (unit) or unit) * count;
	if (stackStart < 1) then stackStart = 1; end
	if (stackStart > stackBuy) then stackStart = stackBuy; end

	if (type (CalculateAuctionDeposit) == "function") then
		local ok, dep = pcall (CalculateAuctionDeposit, duration);
		if (ok and tonumber (dep) and tonumber (dep) > (GetMoney() or 0)) then
			return "nomoney";
		end
	end

	-- The Ledger reads the deposit off the item while it is still in the slot,
	-- so the intent has to be noted here and committed once the post lands.
	if (type (Atr_Ledger_NotePostIntent) == "function") then
		pcall (Atr_Ledger_NotePostIntent, duration);
	end

	entry.count      = count;
	entry.stackPrice = stackBuy;

	StartAuction (stackStart, stackBuy, duration, count, 1);

	return "posted";
end

-- One step of the driver.  At any tick it is doing exactly one of three things:
-- waiting for a name scan to come back, waiting for the auction it started to
-- clear the sell slot, or starting the next item.
function Atr_BP_Step ()

	-- Only ever called with a run going (the ticker dispatches), but a stale
	-- call must not act on nil.
	if (not gRun) then return; end

	-- Anything that takes the auction house or the SELL tab away takes the run
	-- with it.  There is nothing queued server-side, so stopping is free, and
	-- Atr_BP_Cancel kills the scan that may be in flight.
	if (not AuctionFrame or not AuctionFrame:IsShown()
		or (Atr_IsModeCreateAuction and not Atr_IsModeCreateAuction())) then
		Atr_BP_Cancel();
		return;
	end

	-- Waiting on a name scan.  This is the long half of a run -- a query plus
	-- the engine's throttle -- so the bar is repainted every tick through it.
	if (gRun.scanName) then

		gRun.scanWait = gRun.scanWait + ATR_BP_TICK;
		Atr_BP_PaintProgress();

		if (gRun.scanWait < ATR_BP_SCAN_TIMEOUT) then return; end

		-- The engine never called back.  Almost certainly a cancel from a path
		-- that does not route through Atr_BP_ScanCancelled -- but whatever the
		-- cause, a run must not hang on it.  Fall through to the stored price.
		Atr_BP_Msg ("the price scan for " .. tostring (gRun.scanName)
					.. " did not finish -- using the stored price for it.");
		gRun.scanned[gRun.scanName] = true;
		gRun.scanName = nil;
		gRun.scanWait = 0;
		if (Atr_Finder_CancelSearch) then pcall (Atr_Finder_CancelSearch, false); end
	end

	-- Waiting on the post we started last step.  The item leaving the sell slot
	-- is the completion signal (see the header): it is the one thing that is
	-- true whether or not the client sent a multi-sell event.
	if (gRun.pending) then
		local sellName = GetAuctionSellItemInfo();

		if (sellName ~= nil and sellName ~= "") then
			gRun.wait = gRun.wait + ATR_BP_TICK;
			if (gRun.wait < ATR_BP_WAIT) then return; end

			-- Still sitting in the sell box.  Leave it alone rather than
			-- retrying: a second StartAuction on the same item is how you post
			-- it twice.  The next item's ClickAuctionSellItemButton swaps this
			-- one back out to the cursor and ClearCursor returns it to the bags.
			gRun.failed = gRun.failed + 1;
			Atr_BP_Msg ("could not post " .. (gRun.pending.link or "an item") .. " -- skipped.");
			gRun.keep[gRun.pending] = true;
		else
			gRun.posted = gRun.posted + 1;
			Atr_BP_Record (gRun.pending, gRun.pending.stackPrice, gRun.duration);
		end

		gRun.pending = nil;
		gRun.wait    = 0;
	end

	-- Bag slots moved under us as the last auction consumed one, so the queue
	-- has to be re-pointed before the next entry's slot is read.
	Atr_BP_Resolve();
	Atr_BP_Build();
	Atr_BP_PaintProgress();

	-- One tick, one AUCTION -- but a queue entry that never reaches the server
	-- (nothing known about its price, or the slot refused to load) costs no
	-- round trip, so walk past those inside this tick.  Spending 0.25s each on
	-- a queue of unpriced items would look exactly like a hang.  The loop
	-- terminates because every iteration marks an entry done and the picker
	-- skips done entries.
	while (true) do

		-- The queue shrinks as the run drains it, so this walks a list that is
		-- being rebuilt.  Take the first entry not yet dealt with.
		local entry = nil;
		for _, e in ipairs (gQueue) do
			if (not gRun.done[e] and not gRun.keep[e]) then entry = e; break; end
		end

		if (entry == nil) then
			-- What is left in the queue is what could not be posted.
			local left = {};
			for _, e in ipairs (gQueue) do
				if (gRun.keep[e]) then table.insert (left, e); end
			end
			gQueue = left;
			Atr_BP_Finish();
			return;
		end

		-- SCAN FIRST (owner's request, 2026-08-23).  One query per distinct
		-- NAME, taken out immediately before the first entry of that name is
		-- posted rather than in a phase of its own -- which is the whole point:
		-- the gap between reading a price and listing at it is one tick.
		--
		-- Note the entry is deliberately NOT marked done here.  The scan
		-- returns, the next tick picks this same entry again, and by then
		-- gRun.scanned says the price is fresh.
		if (not gRun.noScan and not gRun.scanned[entry.name]) then
			if (Atr_BP_StartScan (entry.name)) then return; end

			-- Could not be sent -- something else owns the query channel.  Say
			-- so once and finish the run on stored prices rather than stopping:
			-- a stale price beats an unlisted item.
			gRun.noScan = true;
			gRun.scanned[entry.name] = true;
			Atr_BP_Msg ("could not start a price scan -- the rest of this batch uses stored prices.");
		end

		gRun.done[entry] = true;

		local result = Atr_BP_PostOne (entry, gRun.duration);

		if (result == "posted") then
			gRun.pending = entry;
			gRun.wait    = 0;
			Atr_BP_PaintProgress();
			return;

		elseif (result == "nomoney") then
			gRun.keep[entry] = true;
			Atr_BP_Msg ("not enough money for the deposit.");
			Atr_BP_Cancel();
			return;

		elseif (result == "skipped") then
			gRun.skipped = gRun.skipped + 1;
			gRun.keep[entry] = true;	-- unpriced: keep it, a scan can fix it

		else	-- failed
			gRun.failed = gRun.failed + 1;
			gRun.keep[entry] = true;
		end
	end
end

-- The button.  A second click while a run is going cancels it, the way Scan
-- Inventory's does.
function Atr_BP_GoClicked ()

	if (gRun) then
		Atr_BP_Cancel();
		return;
	end

	Atr_BP_Resolve();

	if (#gQueue == 0) then
		Atr_BP_Msg ("the batch is empty -- right-click items in the inventory to add them.");
		return;
	end

	if (not AuctionFrame or not AuctionFrame:IsShown()) then
		Atr_BP_Msg ("open the auction house first.");
		return;
	end

	-- The run wants the query channel for one scan per distinct name, and it is
	-- shared.  Refuse rather than silently downgrading the whole batch to stored
	-- prices: the player asked for live ones and can free the channel in a click.
	local canScan = (type (Atr_Finder_StartNameScan) == "function")
					and F ~= nil and F.GetState ~= nil;

	if (canScan and F.GetState() ~= F.State_NULL) then
		Atr_BP_Msg ("a Finder scan is running -- finish or cancel it first.");
		return;
	end
	if (Atr_SB_ScanRunning and Atr_SB_ScanRunning()) then
		Atr_BP_Msg ("Scan Inventory is running -- finish or cancel it first.");
		return;
	end
	-- The sell pane holds the same one channel while it prices whatever is in
	-- the sell box (Atr_Finder_ChannelBusy).  Unlike the two above there is
	-- nothing to cancel and nothing to decide -- a pane search is over in a
	-- second or two -- so this one is just "not yet".
	if (Atr_Sell_QueryBusy and Atr_Sell_QueryBusy()) then
		Atr_BP_Msg ("the sell pane is still searching -- try again in a moment.");
		return;
	end
	if (not canScan) then
		Atr_BP_Msg ("the Finder scan engine is not loaded -- posting at stored prices.");
	end

	-- An item left sitting in the sell box would be swapped out by the first
	-- post and land back in the bags mid-run -- which is the one moment the
	-- queue is being re-pointed at bag slots.  Put it away before starting.
	-- Atr_Sell_ClearSlot is the same lift-and-drop this used to inline, plus the
	-- pane reset; one implementation beats two that have to agree.
	if (Atr_Sell_ClearSlot) then Atr_Sell_ClearSlot(); end

	-- Whatever a previous run learned is stale by definition -- that is the
	-- reason this run is scanning at all.
	for _, e in ipairs (gQueue) do
		e.scanned  = nil;
		e.liveUnit = nil;
	end

	gRun = {
		posted	= 0,
		skipped	= 0,
		failed	= 0,
		wait	= 0,
		total	= #gQueue,		-- fixed at the start: the bar's denominator
		done	= {},			-- entries this run has already tried
		keep	= {},			-- entries to leave in the queue afterwards
		scanned	= {},			-- item names this run has already scanned
		scanName = nil,			-- the name currently out for a scan
		scanWait = 0,			-- ticks x ATR_BP_TICK spent waiting on it
		noScan	= not canScan,
		duration = Atr_BP_Duration(),
	};

	Atr_BP_Ensure();		-- before the paint: the bar is one of its children

	Atr_BP_SetGoButton ("Cancel", true);
	Atr_BP_PaintProgress();

	if (Atr_BP_Ticker) then
		Atr_BP_Ticker.elapsed = 0;
		Atr_BP_Ticker:Show();
	end

	Atr_BP_Step();
end
