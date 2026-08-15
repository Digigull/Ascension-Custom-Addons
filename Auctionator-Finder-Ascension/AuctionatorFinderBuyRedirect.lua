-------------------------------------------------------------------------------
-- AuctionatorFinderBuyRedirect.lua
--
-- "Gear on the Buy tab comes back here": when the user searches gear from the
-- stock Buy tab, these hooks bounce them to the Finder (which handles scaled
-- gear correctly).  Wraps Atr_Search_Onclick / Atr_OnSearchComplete /
-- Atr_EntryOnClick.
--
-- Split out of AuctionatorFinder.lua (was the "gear on the Buy tab comes back
-- here" section).  It reaches back into the scan engine through the shared
-- Finder surface: the redirect table (Redir), and a read of the live scan
-- state to suppress the bounce mid-scan (GetState/State_NULL).
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;
local F  = addonTable and addonTable.Finder;
local FT = F and F.FT;

-- Shared Buy<->Finder redirect table (core mutates fields, never reassigns).
local gFdr_Redir = F and F.Redir;
-- Idle-state sentinel; the live state itself is read through F.GetState().
local FDR_NULL   = F and F.State_NULL;

-- ---------------------------------------------------------------------------
-- FINDER_TAB begin: gear on the Buy tab comes back here
--
-- The mirror image of the block above, and it exists for the reason stated in
-- AUCTIONATOR-INTERNALS: the Buy tab condenses a scan by item NAME and keeps
-- essentially one item link per name, so on a server that scales item
-- INSTANCES invisibly to the link (ASCENSION-CLIENT-NOTES, "THE BIG ONE") its
-- icon and tooltip show one cached version standing in for every variant, and
-- a purchase can deliver a different item than the one displayed.  For gear
-- that is not a cosmetic problem, it is the wrong item.  This tab exists
-- because of it.
--
-- So: pick a weapon or a piece of armor on the Buy tab and you land here
-- instead, with that name searched.  Three entry points, because there are
-- three ways to arrive at one item:
--   1. Atr_Search_Onclick     - typed or pasted name, intercepted BEFORE the
--                               query goes out, so nothing is scanned twice
--   2. Atr_OnSearchComplete   - the same, for a name GetItemInfo had never
--                               cached (most custom IDs here): the class is
--                               only knowable once the auction rows arrive
--   3. Atr_EntryOnClick       - a row picked out of a multi-item result, i.e.
--                               the Advanced Search drill-down
--
-- All three WRAP the upstream global rather than hooking it: 1 and 3 need to
-- act BEFORE the original runs, and hooksecurefunc cannot do that.  The toc
-- loads this file after Auctionator.lua / AuctionatorShop.lua, so the later
-- definition wins and no upstream file is edited -- the same mechanism the
-- full scan replacement below uses.
--
-- FOUR THINGS THIS MUST NOT DO, each of which it would do unguarded:
--   1. Steal the BAZAAR's hand-off.  Atr_Bz_JumpToBuy sends items to the Buy
--      tab to be bought, and 53 heirlooms plus Tiraxis's gold weapon stock
--      are class Weapon/Armor.  Suppressed while the Bazaar's own Back
--      button is up, which is exactly the window its jump is outstanding.
--   2. Fire on the SELL tab.  Atr_OnSearchComplete runs for whichever pane is
--      current, and the Sell tab prices a stack you are about to post with
--      its own exact search.  Every entry point is gated on the Buy tab
--      actually being the selected one.
--   3. Trap the user.  The Buy tab still has price history, the mean-price
--      database and the shopping lists, and stock unscaled gear displays
--      there perfectly well.  Searching the same name a second time is let
--      through, so the tab is always one repeat away.
--   4. Guess.  Fdr_IsGearClassName returns nil when there is no class to
--      test; only an explicit true redirects.  Both directions resolve the
--      unknown case the same way -- leave the user where they are.
-- ---------------------------------------------------------------------------

-- default ON: this is the behaviour the tab was asked for
function Fdr_BuyRedirect_Enabled ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then return true; end
	return (AUCTIONATOR_FINDER_SETTINGS.gearToFinder ~= false);
end


-- GetItemInfo's localized class string for a name, or nil when the client has
-- never cached it.  Atr_GetItemLink is Auctionator's own name -> link cache,
-- which is already warm for anything looked up this session.
function Fdr_BuyRedirect_ClassOf (name, link)

	if (GetItemInfo == nil) then return nil; end

	if (link == nil and Atr_GetItemLink) then
		link = Atr_GetItemLink (name);
	end

	local _, _, _, _, _, sType = GetItemInfo (link or name);
	return sType;
end


-- Strips the quotes Auctionator uses for an exact match and rejects anything
-- that is not a plain single-item name.  A compound search ("Armor/Leather")
-- is a browse, not an item, and is left alone -- the user picks a row from it
-- and entry point 3 takes over there.
function Fdr_BuyRedirect_PlainName (text)

	if (type (text) ~= "string") then return nil; end

	text = text:gsub ("^%s+", ""):gsub ("%s+$", "");
	if (text == "") then return nil; end

	if (Atr_IsCompoundSearch and Atr_IsCompoundSearch (text)) then return nil; end

	local inner = text:match ('^"(.*)"$');
	if (inner) then text = inner; end

	if (text == "") then return nil; end
	return text;
end


-- Sends the Finder to a name handed over by the Buy tab.
--
-- ClearFilters first, and deliberately the whole thing: a category selection
-- left over from an earlier sweep would constrain the query, and the gear
-- autofills (min level = charLevel-5, Usable, My Lvl) would filter out the
-- very item we were sent here to display -- a level 70 weapon on a level 30
-- character would arrive to an empty list.  It resets the My Lvl setting as a
-- side effect, which is the lesser surprise: the alternative is landing on
-- zero rows for the item you just asked to see.
--
-- Returns false when the Finder cannot take it, so the caller leaves the Buy
-- tab to get on with the search it was already doing.
function Atr_Finder_JumpFromBuy (name)

	if (name == nil or name == "") then return false; end

	if (Atr_SelectPane == nil or Atr_Finder_Panel == nil) then return false; end
	if (Atr_Finder_SearchBox == nil or Atr_Finder_StartSearch == nil) then return false; end

	-- a scan cannot be running (leaving this tab cancels it) but the guard is
	-- free, and Atr_Finder_StartSearch CANCELS rather than starts when busy --
	-- it would silently throw the scan away and search nothing
	if (F.GetState () ~= FDR_NULL) then return false; end

	Atr_SelectPane (ATR_FINDER_TAB or 4);

	if (Atr_Finder_ClearFilters) then Atr_Finder_ClearFilters (); end

	Atr_Finder_SearchBox:SetText (name);
	Atr_Finder_StartSearch ();

	return true;
end


-- The decision, shared by all three entry points.
-- Returns true when the redirect happened and the caller must not continue.
function Fdr_BuyRedirect_Consider (name, link)

	if (not Fdr_BuyRedirect_Enabled ()) then return false; end
	if (name == nil or name == "") then return false; end

	-- guard 2: the Buy tab, and only the Buy tab
	if (Atr_IsTabSelected == nil) then return false; end
	if (not Atr_IsTabSelected (ATR_BUY_TAB or 3)) then return false; end

	-- guard 1: the Bazaar sent this here to be bought
	if (Atr_Bz_BuyBackButton and Atr_Bz_BuyBackButton:IsShown()) then return false; end

	-- guard 3: we already made this point about this item
	local key = string.lower (name);
	if (gFdr_Redir.skip == key) then return false; end

	-- guard 4: nil is not false
	if (Fdr_IsGearClassName (Fdr_BuyRedirect_ClassOf (name, link)) ~= true) then
		return false;
	end

	if (not Atr_Finder_JumpFromBuy (name)) then return false; end

	gFdr_Redir.skip = key;

	-- The status line cannot carry this: Atr_Finder_StartSearch overwrites it
	-- with "Scanning..." and the progress heartbeat rebuilds it every tick.
	-- Chat is the only channel that survives, and a tab change the user did
	-- not ask for has to explain itself.
	local s = string.format (FT("Finder: showing |cffffd200%s|r here - the Buy tab shows one cached version of every scaled variant."), name);

	if (not gFdr_Redir.told) then
		gFdr_Redir.told = true;
		s = s.."  "..FT("Search it again to stay on the Buy tab, or turn this off in Auctionator options > Scanning.");
	end

	if (zc and zc.msg_atr) then zc.msg_atr (s);
	elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end

	return true;
end


-- entry point 1: before the query.  The cheap path -- for a name the client
-- has cached, no page is ever fetched by the Buy tab at all.
gFdr_Redir.prevSearch = Atr_Search_Onclick;

function Atr_Search_Onclick (...)

	local box = (Atr_Search_Box and Atr_Search_Box.GetText) and Atr_Search_Box:GetText() or nil;
	local nm  = Fdr_BuyRedirect_PlainName (box);

	if (nm and Fdr_BuyRedirect_Consider (nm)) then return; end

	if (gFdr_Redir.prevSearch) then return gFdr_Redir.prevSearch (...); end
end


-- entry point 2: after the query, for names entry point 1 could not classify.
-- NumScans() == 1 is upstream's own test for "the search settled on one item",
-- and it is the same condition under which Atr_OnSearchComplete assigns
-- activeScan -- whose itemLink came from a real auction row, so the class is
-- known even for an item this client had never seen.
function Fdr_BuyRedirect_AfterSearch ()

	local pane = Atr_GetCurrentPane and Atr_GetCurrentPane ();
	if (pane == nil or pane.activeSearch == nil or pane.activeScan == nil) then return; end
	if (pane.activeSearch.NumScans == nil) then return; end
	if (pane.activeSearch:NumScans() ~= 1) then return; end

	if (pane.activeScan.itemName == nil) then return; end

	Fdr_BuyRedirect_Consider (pane.activeScan.itemName, pane.activeScan.itemLink);
end

gFdr_Redir.prevComplete = Atr_OnSearchComplete;

function Atr_OnSearchComplete (...)

	if (gFdr_Redir.prevComplete) then gFdr_Redir.prevComplete (...); end
	Fdr_BuyRedirect_AfterSearch ();
end


-- entry point 3: a row picked out of a multi-item result.
--
-- Atr_ShowingSearchSummary must be read BEFORE the original runs.  It is
-- derived from gCurrentPane:IsScanEmpty(), and the original's whole job in
-- that branch is to assign a non-empty activeScan -- so by the time a
-- post-hook could look, the answer has already flipped to false.  This is why
-- the function is wrapped rather than hooked.
gFdr_Redir.prevEntry = Atr_EntryOnClick;

function Atr_EntryOnClick (entry, ...)

	local fromSummary = (Atr_ShowingSearchSummary and Atr_ShowingSearchSummary()) and true or false;

	if (gFdr_Redir.prevEntry) then gFdr_Redir.prevEntry (entry, ...); end

	if (fromSummary) then
		local pane = Atr_GetCurrentPane and Atr_GetCurrentPane ();
		local scn  = pane and pane.activeScan;
		if (scn and scn.itemName) then
			Fdr_BuyRedirect_Consider (scn.itemName, scn.itemLink);
		end
	end
end
-- FINDER_TAB end: gear on the Buy tab comes back here
