-------------------------------------------------------------------------------
-- AuctionatorBazaar.lua -- the "Bazaar" tab (Ascension fork).
--
-- PHASE 1: the currency rate engine only.  No UI, no merchant harvesting,
-- no AH scanning -- those land in later phases in this same file.
--
-- Ascension sells vanity/convenience goods for Bazaar Tokens.  Tokens are
-- obtainable two ways: with real money via DP on the webshop, or with gold
-- by buying them off the auction house (they are ordinary item 975001).
-- That makes four currencies on one chain:
--
--      USD  --bundle-->  DP  --shop rate-->  BT  --auction house-->  gold
--
-- Every rate on that chain is a player-visible, changeable number, so all
-- three edges are user-editable and persisted.  Internally everything is
-- reduced to COPPER, because copper is the only exact integer axis we have
-- (the AH hands us copper) and gold is what the player actually compares
-- against.  USD is the least precise end of the chain -- DP is sold in
-- volume-discounted bundles, so there is no single true USD/DP rate; the
-- player enters whichever bundle they actually buy.
--
-- Ported from the standalone converter page (ACCC.html); its defaults were
-- $15 = 50 DP = 1250 BT = 738g, i.e. 1 BT = 0g 59.04s.
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;

local function BZT (s)
	if (ZT) then return ZT(s); end
	return s;
end

local function Bz_Now ()
	if (time) then return time(); end
	return os and os.time and os.time() or 0;
end

-------------------------------------------------------------------------------
-- constants
-------------------------------------------------------------------------------

-- established by the Phase 0 probe: the sole alt currency Tiraxis accepts
ATR_BZ_TOKEN_ITEMID	= 975001;
ATR_BZ_TOKEN_NAME	= "Bazaar Token";

ATR_BZ_RATES_VERSION = 1;

-- canonical unit ids.  COPPER is the gold axis; the UI labels it "Gold" but
-- every value crossing this module's boundary in that unit is copper.
ATR_BZ_UNITS = { "USD", "DP", "BT", "COPPER" };

-- defaults carried over from ACCC.html
ATR_BZ_RATE_DEFAULTS = {
	usdBundle	= 15,		-- you pay this many USD ...
	dpBundle	= 50,		-- ... and receive this many DP
	dpUnits		= 1,		-- this many DP ...
	btUnits		= 25,		-- ... buys this many Bazaar Tokens
	copperPerBT	= 5904,		-- 0g 59.04s per token
	btSource	= "default",	-- "default" | "manual" | "auction"
	btStamp		= 0,		-- when copperPerBT was last set
	btSampleN	= 0,		-- auctions sampled, when source == "auction"
	ahCutPct	= 5,		-- auction house cut on a sale, percent
};

-------------------------------------------------------------------------------
-- validation helpers
-------------------------------------------------------------------------------

-- a usable rate input: a finite, strictly positive number
local function Bz_IsPositiveNumber (v)
	v = tonumber (v);
	if (v == nil)			then return nil; end
	if (v ~= v)				then return nil; end	-- NaN
	if (v == math.huge)		then return nil; end
	if (v == -math.huge)	then return nil; end
	if (v <= 0)				then return nil; end
	return v;
end

local function Bz_Round (v)
	if (v == nil) then return 0; end
	if (v >= 0) then return math.floor (v + 0.5); end
	return -math.floor (-v + 0.5);
end

-- gold + silver text boxes -> copper.  Silver is allowed to be fractional
-- (the converter's default is literally 59.04s) so the product is rounded
-- rather than truncated: 59.04 * 100 is 5904.000000000001 in IEEE doubles.
function Atr_Bz_CopperFromGS (gold, silver, copper)
	local g = tonumber (gold)	or 0;
	local s = tonumber (silver)	or 0;
	local c = tonumber (copper)	or 0;
	if (g ~= g) then g = 0; end
	if (s ~= s) then s = 0; end
	if (c ~= c) then c = 0; end
	return Bz_Round (g * 10000 + s * 100 + c);
end

-------------------------------------------------------------------------------
-- persistence
-------------------------------------------------------------------------------

-- AUCTIONATOR_BAZAAR is declared by the main .toc (Phase 2).  Everything here
-- tolerates it being absent so the engine is testable and never hard-errors
-- if the SavedVariable failed to load.
function Atr_Bz_InitRates ()

	AUCTIONATOR_BAZAAR = AUCTIONATOR_BAZAAR or {};

	local db = AUCTIONATOR_BAZAAR;

	if (db.rates == nil or db.ratesVersion ~= ATR_BZ_RATES_VERSION) then
		local old = db.rates;
		db.rates = {};
		local k, v;
		for k, v in pairs (ATR_BZ_RATE_DEFAULTS) do
			db.rates[k] = v;
		end
		-- forward-migrate any still-valid fields from an older layout
		if (type (old) == "table") then
			for k in pairs (ATR_BZ_RATE_DEFAULTS) do
				if (type (old[k]) == type (ATR_BZ_RATE_DEFAULTS[k])) then
					db.rates[k] = old[k];
				end
			end
		end
		db.ratesVersion = ATR_BZ_RATES_VERSION;
	end

	-- repair any field that went missing or invalid on disk
	local k, v;
	for k, v in pairs (ATR_BZ_RATE_DEFAULTS) do
		if (db.rates[k] == nil) then
			db.rates[k] = v;
		end
	end
	if (not Bz_IsPositiveNumber (db.rates.usdBundle))	then db.rates.usdBundle		= ATR_BZ_RATE_DEFAULTS.usdBundle;	end
	if (not Bz_IsPositiveNumber (db.rates.dpBundle))	then db.rates.dpBundle		= ATR_BZ_RATE_DEFAULTS.dpBundle;	end
	if (not Bz_IsPositiveNumber (db.rates.dpUnits))		then db.rates.dpUnits		= ATR_BZ_RATE_DEFAULTS.dpUnits;		end
	if (not Bz_IsPositiveNumber (db.rates.btUnits))		then db.rates.btUnits		= ATR_BZ_RATE_DEFAULTS.btUnits;		end
	if (not Bz_IsPositiveNumber (db.rates.copperPerBT))	then db.rates.copperPerBT	= ATR_BZ_RATE_DEFAULTS.copperPerBT;	end

	return db.rates;
end

function Atr_Bz_GetRates ()
	return Atr_Bz_InitRates();
end

function Atr_Bz_ResetRates ()
	if (AUCTIONATOR_BAZAAR) then AUCTIONATOR_BAZAAR.rates = nil; end
	return Atr_Bz_InitRates();
end

-------------------------------------------------------------------------------
-- setters
-------------------------------------------------------------------------------

-- rates that may legitimately be zero.  A 0% auction house cut is a real
-- setting (and useful for "what would I clear gross?"), so it cannot go
-- through the strictly-positive validator the exchange rates use.
local BZ_ALLOW_ZERO = { ahCutPct = true };

local BZ_SETTABLE = {
	usdBundle	= true,
	dpBundle	= true,
	dpUnits		= true,
	btUnits		= true,
	copperPerBT	= true,
	ahCutPct	= true,
};

-- returns  ok(boolean), errorMessage(string or nil)
-- A rejected value leaves the stored rate untouched: a half-typed edit box
-- must never be able to zero out someone's rates.
function Atr_Bz_SetRate (key, value)

	if (not BZ_SETTABLE[key]) then
		return false, BZT("unknown rate");
	end

	local v = Bz_IsPositiveNumber (value);

	if (v == nil and BZ_ALLOW_ZERO[key]) then
		local z = tonumber (value);
		if (z == 0) then v = 0; end
	end

	if (v == nil) then
		if (BZ_ALLOW_ZERO[key]) then
			return false, BZT("must be zero or a positive number");
		end
		return false, BZT("must be a positive number");
	end

	local rates = Atr_Bz_GetRates();
	rates[key] = v;

	if (key == "copperPerBT") then
		rates.copperPerBT	= Bz_Round (v);
		rates.btSource		= "manual";
		rates.btStamp		= Bz_Now();
		rates.btSampleN		= 0;
	end

	return true, nil;
end

-- Bazaar Tokens are themselves an auction house item, so the gold edge of the
-- chain can be observed rather than guessed.  Callers pass the cheapest
-- per-unit buyout seen in a scan (Phase 5 wires this up).
function Atr_Bz_SetTokenRateFromAuction (copperPerUnit, sampleCount)

	local v = Bz_IsPositiveNumber (copperPerUnit);
	if (v == nil) then
		return false, BZT("no usable auction price");
	end

	local rates = Atr_Bz_GetRates();
	rates.copperPerBT	= Bz_Round (v);
	rates.btSource		= "auction";
	rates.btStamp		= Bz_Now();
	rates.btSampleN		= tonumber (sampleCount) or 0;

	return true, nil;
end

-------------------------------------------------------------------------------
-- the derived rate table
-------------------------------------------------------------------------------

-- Everything reduces to "how many copper is one unit of X worth".  One
-- multiplication table, so every conversion is a single ratio and there are
-- no per-pair special cases to get wrong.
function Atr_Bz_Derived ()

	local r = Atr_Bz_GetRates();

	local copperPerBT	= r.copperPerBT;
	local btPerDP		= r.btUnits / r.dpUnits;
	local copperPerDP	= copperPerBT * btPerDP;
	local dpPerUSD		= r.dpBundle / r.usdBundle;
	local copperPerUSD	= copperPerDP * dpPerUSD;

	return {
		copperPerBT		= copperPerBT,
		copperPerDP		= copperPerDP,
		copperPerUSD	= copperPerUSD,
		btPerDP			= btPerDP,
		dpPerUSD		= dpPerUSD,
		btPerUSD		= btPerDP * dpPerUSD,
		btSource		= r.btSource,
		btStamp			= r.btStamp,
		btSampleN		= r.btSampleN,
	};
end

local function Bz_PerCopper (d)
	return {
		COPPER	= 1,
		BT		= d.copperPerBT,
		DP		= d.copperPerDP,
		USD		= d.copperPerUSD,
	};
end

-- Atr_Bz_Convert (100, "BT", "COPPER")  ->  copper value of 100 tokens
-- returns nil on an unknown unit rather than a silently wrong number.
function Atr_Bz_Convert (amount, fromUnit, toUnit)

	local a = tonumber (amount);
	if (a == nil or a ~= a) then return nil; end

	local per = Bz_PerCopper (Atr_Bz_Derived());

	local f = per[fromUnit];
	local t = per[toUnit];
	if (f == nil or t == nil or t == 0) then return nil; end

	local v = a * f / t;

	if (toUnit == "COPPER") then return Bz_Round (v); end
	return v;
end

-- the whole row for one vendor item, given its token price
function Atr_Bz_ItemValues (btCost)

	local bt = tonumber (btCost) or 0;

	return {
		bt		= bt,
		copper	= Atr_Bz_Convert (bt, "BT", "COPPER"),
		dp		= Atr_Bz_Convert (bt, "BT", "DP"),
		usd		= Atr_Bz_Convert (bt, "BT", "USD"),
	};
end

-- the inverse: what an observed auction price is "worth" on the other axes
function Atr_Bz_CopperValues (copper)

	local c = tonumber (copper) or 0;

	return {
		copper	= c,
		bt		= Atr_Bz_Convert (c, "COPPER", "BT"),
		dp		= Atr_Bz_Convert (c, "COPPER", "DP"),
		usd		= Atr_Bz_Convert (c, "COPPER", "USD"),
	};
end

-------------------------------------------------------------------------------
-- formatting
-------------------------------------------------------------------------------

-- same visual convention as the Finder's Fdr_MoneyString
function Atr_Bz_MoneyString (copper)

	if (copper == nil or copper <= 0) then
		return "|cff888888--|r";
	end

	copper = Bz_Round (copper);

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

function Atr_Bz_USDString (usd)
	if (usd == nil or usd <= 0) then return "|cff888888--|r"; end
	if (usd < 0.01) then return "|cff88dd88<$0.01|r"; end
	return string.format ("|cff88dd88$%.2f|r", usd);
end

function Atr_Bz_DPString (dp)
	if (dp == nil or dp <= 0) then return "|cff888888--|r"; end
	if (dp < 10) then return string.format ("|cffcc88ff%.1f|r", dp); end
	return string.format ("|cffcc88ff%d|r", Bz_Round (dp));
end

function Atr_Bz_BTString (bt)
	if (bt == nil or bt <= 0) then return "|cff888888--|r"; end
	return string.format ("|cffffd70b%d|r", Bz_Round (bt));
end

-- one-line human summary of the whole chain, for the tab header
function Atr_Bz_RateSummary ()

	local r = Atr_Bz_GetRates();
	local d = Atr_Bz_Derived();

	local src = r.btSource;
	if (src == "auction") then
		src = string.format (BZT("live AH, %d seen"), r.btSampleN or 0);
	elseif (src == "manual") then
		src = BZT("manual");
	else
		src = BZT("default");
	end

	return string.format ("$%g = %g DP   |   %g DP = %g BT   |   1 BT = %s   (%s)",
			r.usdBundle, r.dpBundle,
			r.dpUnits, r.btUnits,
			Atr_Bz_MoneyString (r.copperPerBT),
			src);
end

-------------------------------------------------------------------------------
-- expose the validators for the UI's edit boxes (Phase 4)
-------------------------------------------------------------------------------

Atr_Bz_IsPositiveNumber	= Bz_IsPositiveNumber;
Atr_Bz_Round			= Bz_Round;

-------------------------------------------------------------------------------
-- PHASE 4a: the panel.
--
-- Deliberately NOT a refit of the Buy tab.  The Buy tab is not a component --
-- it is a mode of the shared Atr_Main_Panel, and its widgets (Atr_Search_Box,
-- Atr_Hlist, Atr_DropDownSL, the SList buttons, AuctionatorScrollFrame,
-- gCurrentPane) are globals shared with Sell and More, shown and hidden by
-- branching in Atr_AuctionFrameTab_OnClick.  Adding a fifth mode to all of
-- them is where bugs breed.  So this is a standalone panel, like the Finder's,
-- that REPRODUCES Buy's geometry rather than inheriting it:
--
--   Atr_DropDownSL's slot   -> category picker
--   Atr_Hlist's slot        -> item navigator for that category
--   the four SList buttons  -> the exchange-rate block
--   the results area        -> the currency table
--
-- Anchoring follows CLAUDE.md: fixed TOPLEFT offsets for left-side controls,
-- but anything at the right or bottom edge anchors to AuctionFrame itself,
-- because this client's AuctionFrame is not the stock 758x447.
-------------------------------------------------------------------------------

-- Row counts are computed from the frame's REAL height at runtime, never
-- hardcoded: this client's AuctionFrame is not the stock 758x447, so any
-- constant here is a guess that shows up as dead space or clipping.  A fixed
-- pool of widgets is created once and the visible count varies.
local BZ_NAV_POOL	= 40;		-- item navigator, left column
local BZ_NAV_H		= 15;
local BZ_ROW_POOL	= 40;		-- currency table, right pane
local BZ_ROW_H		= 21;

local BZ_LEFT_X		= 10;		-- left column x, inside the panel
local BZ_LEFT_W		= 150;
local BZ_DD_Y		= 72;		-- category dropdown y; clears the portrait
local BZ_NAV_TOP	= 118;		-- navigator start, below dropdown + summary
local BZ_TABLE_TOP	= 20;		-- y offset inside the pane, below headers
local BZ_PANE_TOP	= 104;		-- pane y: puts the headers on the light art band
-- Bottom reserve, in pixels, subtracted before dividing by row height.  It no
-- longer has to house the status line (that moved up beside the filter), so
-- it is just enough to keep the last row clear of the pane edge.
local BZ_TABLE_BOT	= 5;
local BZ_SB_GUTTER	= 24;		-- room reserved for a scrollbar
local BZ_BACK_Y		= 14;		-- fallback only; normally measured off the bottom bar

-- Back lives up on the filter row and Price these stays on the bottom bar, so
-- the two are nowhere near each other.  They used to share one slot, which
-- meant returning from an item left the cursor over "Price these" and a second
-- click started a scan nobody asked for.  Both are always present; only their
-- enabled state changes with the view.
local BZ_BTN_W		= 130;		-- Price these, on the bottom bar
local BZ_BTN_H		= 24;
local BZ_BACK_W		= 88;		-- Back, on the filter row
local BZ_BACK_H		= 18;

-- Columns are placed by distance from the row's RIGHT edge, so the Item
-- column absorbs whatever width is left over and nothing can be pushed off a
-- frame that is wider or narrower than stock.
--
-- The two views want different orders, so each carries its own layout and the
-- cells are repositioned when the view changes.  ITEM also reserves a taller
-- strip at the top of the pane for the icon and title, which is what makes
-- its list shorter than the catalogue's.
local BZ_COLSETS = {

	-- "gold" means the same thing in both views: a per-item gold price.  In the
	-- catalogue that is what the item sells for; in the auction list it is what
	-- that listing asks.  The catalogue has no stack, so it omits "ah".
	-- headerTop: where the column header strip sits inside the pane.  The
	-- catalogue puts it at the very top; the drill-down pushes it below the
	-- item icon and title so the headers label the listings directly.
	LIST = {
		headerTop = 0, top = 20, nameRight = 360,
		{ key = "gold",		w = 84,	right = 270 },
		{ key = "bt",		w = 50,	right = 214 },
		{ key = "dp",		w = 44,	right = 164 },
		{ key = "usd",		w = 56,	right = 102 },
		{ key = "margin",	w = 70,	right = 26 },
	},

	ITEM = {
		headerTop = 58, top = 80, nameRight = 450,
		{ key = "ah",		w = 84,	right = 360 },
		{ key = "gold",		w = 80,	right = 274 },
		{ key = "bt",		w = 54,	right = 214 },
		{ key = "dp",		w = 44,	right = 164 },
		{ key = "usd",		w = 56,	right = 102 },
		{ key = "margin",	w = 70,	right = 26 },
	},
};

local BZ_COLS = BZ_COLSETS.ITEM;			-- the superset, for widget creation
local BZ_ALL_KEYS = { "bt", "gold", "dp", "usd", "ah", "margin" };

-- the same seven cells carry different meanings in the two views
local BZ_HEAD_LIST = {
	name = "Item", bt = "BT", gold = "Per Item", dp = "DP",
	usd = "USD", ah = "AH price", margin = "Margin",
};
-- what each column actually means.  Margin especially: a -179g figure is
-- alarming until you know it is being compared against the vendor's token
-- price, not against nothing.
-- A hint is either a plain string or a list of {text, r, g, b} lines.  Margin
-- uses the list form so its legend can be printed in the same two colours the
-- cells themselves use; ATR_BZ_MARGIN_RED/GREEN are the single source of both.
ATR_BZ_MARGIN_RED	= { 1, 0.333, 0.333 };
ATR_BZ_MARGIN_GREEN	= { 0.267, 1, 0.267 };

ATR_BZ_HEAD_TIP = {
	name	= "Number of auctions at this price and stack size.",
	bt		= "Cost in Bazaar Tokens.",
	gold	= "That cost converted to gold at your current token rate.",
	dp		= "That cost converted to Ascension donation points.",
	usd	 	= "That cost converted to real money, using the DP bundle you set.",
	ah		= "What the item is selling for on the auction house.",
	margin	= {
		{ "Cheaper to buy with tokens",	ATR_BZ_MARGIN_RED },
		{ "Cheaper to buy with gold",	ATR_BZ_MARGIN_GREEN },
	},
};

local BZ_HEAD_TIP = ATR_BZ_HEAD_TIP;

local BZ_HEAD_ITEM = {
	-- "BT val." because in this view the number is what the LISTING is worth in
	-- tokens, not what the item costs at the vendor
	name = "Auctions", bt = "BT val.", gold = "Per Item", dp = "DP",
	usd = "USD", ah = "Stack Price", margin = "Margin",
};

local gBz_NavRows	= 15;		-- currently visible, set by Bz_Relayout
local gBz_TableRows	= 13;

local gBz_Cat		= "CONV";	-- selected category key
local gBz_ShowBound	= true;		-- dim bound items rather than hiding them
local gBz_Sel		= nil;		-- selected catalogue record
-- Auctionator's own BUY_TAB constant is file-local to Auctionator.lua, and
-- AuctionatorFinder.lua hardcodes the same 3.  Prefer a global if one ever
-- appears rather than baking the number in permanently.
local BZ_BUY_TAB	= ATR_BUY_TAB or 3;

local gBz_BackToBz	= false;	-- a Bazaar -> Buy jump is outstanding
local gBz_View		= "LIST";	-- "LIST" = the catalogue, "ITEM" = one item's auctions
local gBz_Listings	= {};		-- condensed auctions, when in ITEM view
local gBz_SortKey	= "bt";		-- column currently sorted on, catalogue view
local gBz_SortAsc	= true;
local gBz_ISortKey	= "gold";	-- ... and in the auction list, kept separate so
local gBz_ISortAsc	= true;		--     drilling in and out does not reorder either
local gBz_Headers	= {};
local gBz_Filter	= "";		-- text filter, applied over the category
local gBz_FellBack	= false;	-- filter found nothing here, so we widened
local gBz_Rows		= {};		-- current right-pane contents

-------------------------------------------------------------------------------

local function Bz_CategoryLabel (key)
	local i;
	for i = 1, #ATR_BZ_CATEGORIES do
		if (ATR_BZ_CATEGORIES[i].key == key) then return ATR_BZ_CATEGORIES[i].label; end
	end
	return key or "?";
end

-- 3.3.5 FontStrings wrap once a width is set, and nothing clips them, so a
-- long item name spills over the row below.  Measure and chop instead.
local function Bz_FitText (fs, text, maxW)

	text = text or "";
	fs:SetText (text);

	if (maxW == nil and fs.GetWidth) then maxW = fs:GetWidth(); end
	if (maxW == nil or maxW <= 0) then return text; end
	if (not fs.GetStringWidth or fs:GetStringWidth() <= maxW) then return text; end

	local lo, hi = 1, string.len (text);
	while (lo < hi) do
		local mid = math.floor ((lo + hi + 1) / 2);
		fs:SetText (string.sub (text, 1, mid).."...");
		if (fs:GetStringWidth() <= maxW) then lo = mid; else hi = mid - 1; end
	end

	local out = string.sub (text, 1, lo).."...";
	fs:SetText (out);
	return out;
end

function Atr_Bz_CurrentCatLabel ()
	return Bz_CategoryLabel (gBz_Cat);
end

-- Real item tooltip where we can get one.  SetHyperlink needs the server to
-- know the id; if it does not, fall back to the name rather than an empty box.
function Atr_Bz_ShowItemTooltip (owner, rec, anchor)

	if (not GameTooltip or rec == nil) then return; end

	GameTooltip:SetOwner (owner, anchor or "ANCHOR_RIGHT");

	local shown = false;
	if (rec.id and GameTooltip.SetHyperlink) then
		shown = pcall (GameTooltip.SetHyperlink, GameTooltip, "item:"..rec.id);
	end

	if (not shown) then
		GameTooltip:SetText (rec.name or "");
	end

	GameTooltip:Show();
end

function Atr_Bz_ItemTexture (rec)
	if (rec == nil) then return nil; end
	if (rec.tex and rec.tex ~= "") then return rec.tex; end
	if (rec.id and GetItemInfo) then
		local _, _, _, _, _, _, _, _, _, tex = GetItemInfo (rec.id);
		if (tex) then return tex; end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark";
end

function Atr_Bz_SetMessage (msg)
	if (Atr_Bz_Message) then Atr_Bz_Message:SetText (msg or ""); end
end

-------------------------------------------------------------------------------
-- display
-------------------------------------------------------------------------------

-- Gold, DP and USD are all monotonic transforms of the token cost, so they
-- share its ordering; only the market columns need their own value.
local function Bz_SortValue (rec, key)

	if (key == "name")		then return string.lower (rec.name or ""); end
	if (key == "margin")	then return (Atr_Bz_Margin (rec)); end

	-- "Per Item" and the old AH column are both the market price
	if (key == "gold" or key == "ah") then return Atr_Bz_MarketPrice (rec); end

	return rec.bt or 0;			-- BT, DP and USD all track the vendor cost
end

local function Bz_NameLess (a, b)
	local an = string.lower (a.name or "");
	local bn = string.lower (b.name or "");
	if (an ~= bn) then return an < bn; end
	return (a.id or 0) < (b.id or 0);		-- keeps the order total, so table.sort is stable
end

local function Bz_Comparator (a, b)

	local av = Bz_SortValue (a, gBz_SortKey);
	local bv = Bz_SortValue (b, gBz_SortKey);

	-- Rows with no market data sort LAST in both directions.  Letting them
	-- fall wherever nil-vs-number lands would put every unpriced item at the
	-- top of a descending margin sort, which is exactly the view you asked
	-- the column to give you.
	if (av == nil and bv == nil)	then return Bz_NameLess (a, b); end
	if (av == nil)					then return false; end
	if (bv == nil)					then return true; end

	if (av == bv) then return Bz_NameLess (a, b); end

	if (gBz_SortAsc) then return av < bv; end
	return av > bv;
end

function Atr_Bz_SetSort (key, asc)
	gBz_SortKey = key or "bt";
	gBz_SortAsc = asc and true or false;
	Atr_Bz_UpdateHeaderArrows();
	Atr_Bz_RebuildDisplay();
end

function Atr_Bz_SortKey ()	return gBz_SortKey; end
function Atr_Bz_SortAsc ()	return gBz_SortAsc; end

function Atr_Bz_UpdateHeaderArrows ()

	local activeKey = (gBz_View == "ITEM") and gBz_ISortKey or gBz_SortKey;
	local activeAsc = (gBz_View == "ITEM") and gBz_ISortAsc or gBz_SortAsc;

	local key, btn;
	for key, btn in pairs (gBz_Headers) do
		if (btn.arrow) then
			if (key == activeKey) then
				btn.arrow:SetText (activeAsc and "|cff88ccff^|r" or "|cff88ccffv|r");
			else
				btn.arrow:SetText ("");
			end
		end
	end
end

function Atr_Bz_HeaderClick (key)

	if (gBz_View == "ITEM") then

		if (gBz_ISortKey == key) then
			gBz_ISortAsc = not gBz_ISortAsc;
		else
			gBz_ISortKey = key;
			gBz_ISortAsc = (key ~= "margin");	-- best margin first, prices cheapest first
		end

		Atr_Bz_UpdateHeaderArrows();
		Atr_Bz_SortListings();
		Atr_Bz_RefreshTable();
		return;
	end

	if (gBz_SortKey == key) then
		gBz_SortAsc = not gBz_SortAsc;
	else
		gBz_SortKey = key;
		-- cost columns read best cheapest-first; market columns best-first
		gBz_SortAsc = not (key == "gold" or key == "ah" or key == "margin");
	end

	Atr_Bz_UpdateHeaderArrows();
	Atr_Bz_RebuildDisplay();
end

-- plain substring, not a Lua pattern: item names contain "(", "-" and ":"
local function Bz_Matches (rec, needle)
	if (needle == "") then return true; end
	return string.find (string.lower (rec.name or ""), needle, 1, true) ~= nil;
end

local function Bz_Filtered (list, needle)
	local out = {};
	local i;
	for i = 1, #list do
		if (Bz_Matches (list[i], needle)) then out[#out + 1] = list[i]; end
	end
	return out;
end

function Atr_Bz_SetFilter (text)
	gBz_Filter = text or "";
	Atr_Bz_RebuildDisplay();
end

function Atr_Bz_CurrentFilter ()	return gBz_Filter; end
function Atr_Bz_FilterFellBack ()	return gBz_FellBack; end

function Atr_Bz_RebuildDisplay ()

	local needle = string.lower (gBz_Filter or "");

	gBz_FellBack	= false;
	gBz_Rows		= Bz_Filtered (Atr_Bz_ItemsInCategory (gBz_Cat, gBz_ShowBound), needle);

	-- nothing here but the player typed something: widen to the whole
	-- catalogue rather than showing an empty pane
	if (#gBz_Rows == 0 and needle ~= "") then
		local wide = Bz_Filtered (Atr_Bz_ItemsInCategory (nil, gBz_ShowBound), needle);
		if (#wide > 0) then
			gBz_Rows	= wide;
			gBz_FellBack = true;
		end
	end

	local counts	= Atr_Bz_CategoryCounts();
	local c			= counts[gBz_Cat];

	if (Atr_Bz_CatSummary) then
		if (c) then
			local priced = Atr_Bz_PricedCount (gBz_Rows);
			Atr_Bz_CatSummary:SetText (string.format (BZT("%d tradeable of %d, %d priced"),
					c.tradeable, c.total, priced));
		else
			Atr_Bz_CatSummary:SetText ("");
		end
	end

	table.sort (gBz_Rows, Bz_Comparator);

	Atr_Bz_RefreshNav();
	Atr_Bz_RefreshTable();

	if (#gBz_Rows == 0) then
		if (gBz_Filter ~= "") then
			Atr_Bz_SetMessage (string.format (BZT("No item matches '%s'"), gBz_Filter));
		else
			Atr_Bz_SetMessage (BZT("Nothing in this category yet - visit Tiraxis to learn it."));
		end
	elseif (gBz_FellBack) then
		Atr_Bz_SetMessage (string.format (
			BZT("No match in %s - showing all categories"), Bz_CategoryLabel (gBz_Cat)));
	else
		Atr_Bz_SetMessage ("");
	end
end

-- left column: one line per item, the navigator
function Atr_Bz_RefreshNav ()

	if (not Atr_Bz_NavScroll) then return; end

	FauxScrollFrame_Update (Atr_Bz_NavScroll, #gBz_Rows, gBz_NavRows, BZ_NAV_H);
	local offset = FauxScrollFrame_GetOffset (Atr_Bz_NavScroll) or 0;

	local i;
	for i = 1, BZ_NAV_POOL do

		local row = _G["Atr_Bz_NavRow"..i];
		local rec = gBz_Rows[i + offset];

		if (row) then
			if (rec and i <= gBz_NavRows) then
				row.rec = rec;
				row.full = rec.name or ("item:"..tostring (rec.id));
				Bz_FitText (row.text, row.full, BZ_LEFT_W - BZ_SB_GUTTER - 6);
				if (not rec.tradeable) then
					row.text:SetTextColor (0.55, 0.55, 0.55);
				elseif (gBz_Sel and gBz_Sel.id == rec.id) then
					row.text:SetTextColor (1, 0.82, 0);
				else
					row.text:SetTextColor (0.9, 0.9, 0.9);
				end
				row:Show();
			else
				row.rec = nil;
				row:Hide();
			end
		end
	end
end

-- right pane: the currency table
-- one condensed auction line: "9 stacks of 100" plus the same money in every
-- currency, so a listing can be judged against the token price directly
-- "10 stacks of 1" reads as an auction count; "10 x 1" reads as arithmetic
local function Bz_StackText (stacks, count)
	if (stacks == 1) then
		return string.format (BZT("1 stack of %d"), count);
	end
	return string.format (BZT("%d stacks of %d"), stacks, count);
end

local function Bz_ShowListingRow (row, L)

	if (L.perItem == nil) then
		row.name:SetText (Bz_StackText (L.stacks, L.count));
		row.gold:SetText ("|cff888888"..BZT("no buyout").."|r");
		row.bt:SetText ("");
		row.dp:SetText ("");
		row.usd:SetText ("");
		row.ah:SetText ("");
		row.margin:SetText ("");
		row.name:SetTextColor (0.6, 0.6, 0.6);
		return;
	end

	local per = Atr_Bz_Round (L.perItem);

	row.name:SetText (Bz_StackText (L.stacks, L.count));
	row.gold:SetText (Atr_Bz_MoneyString (per));
	row.bt:SetText  (Atr_Bz_BTString  (Atr_Bz_Convert (per, "COPPER", "BT")));
	row.dp:SetText  (Atr_Bz_DPString  (Atr_Bz_Convert (per, "COPPER", "DP")));
	row.usd:SetText (Atr_Bz_USDString (Atr_Bz_Convert (per, "COPPER", "USD")));
	row.ah:SetText  (Atr_Bz_MoneyString (per * L.count));
	row.name:SetTextColor (1, 1, 1);

	-- what you would clear selling into this listing's price
	local rec = Atr_Bz_Selected();
	if (rec and rec.tradeable and rec.bt) then
		local r	   = Atr_Bz_GetRates();
		local cut  = (tonumber (r.ahCutPct) or 0) / 100;
		local cost = Atr_Bz_Convert (rec.bt, "BT", "COPPER");
		row.margin:SetText (Atr_Bz_MarginString (Atr_Bz_Round (per * (1 - cut) - cost)));
	else
		row.margin:SetText ("|cff888888--|r");
	end
end

function Atr_Bz_RefreshTable ()

	if (not Atr_Bz_TableScroll) then return; end

	if (gBz_View == "ITEM") then

		FauxScrollFrame_Update (Atr_Bz_TableScroll, #gBz_Listings, gBz_TableRows, BZ_ROW_H);
		local offset = FauxScrollFrame_GetOffset (Atr_Bz_TableScroll) or 0;

		local i;
		for i = 1, BZ_ROW_POOL do
			local row = _G["Atr_Bz_Row"..i];
			local L   = gBz_Listings[i + offset];
			if (row) then
				if (L and i <= gBz_TableRows) then
					row.rec = nil;
					Bz_ShowListingRow (row, L);
					row:Show();
				else
					row:Hide();
				end
			end
		end

		return;
	end

	FauxScrollFrame_Update (Atr_Bz_TableScroll, #gBz_Rows, gBz_TableRows, BZ_ROW_H);
	local offset = FauxScrollFrame_GetOffset (Atr_Bz_TableScroll) or 0;

	local i;
	for i = 1, BZ_ROW_POOL do

		local row = _G["Atr_Bz_Row"..i];
		local rec = gBz_Rows[i + offset];

		if (row) then
			if (rec and i <= gBz_TableRows) then

				local v = Atr_Bz_ItemValues (rec.bt);

				row.rec = rec;
				row.full = rec.name or ("item:"..tostring (rec.id));
				Bz_FitText (row.name, row.full, nil);
				row.bt:SetText   (Atr_Bz_BTString (v.bt));
				row.dp:SetText   (Atr_Bz_DPString (v.dp));
				row.usd:SetText  (Atr_Bz_USDString (v.usd));

				-- "Per Item" is the market price here, not a conversion of the
				-- vendor cost: BT, DP and USD already carry that.
				if (rec.tradeable) then
					local margin, market = Atr_Bz_Margin (rec);
					row.gold:SetText (market and Atr_Bz_MoneyString (market) or "|cff888888--|r");
					row.margin:SetText (Atr_Bz_MarginString (margin));
				else
					row.gold:SetText ("|cff888888"..BZT("bound").."|r");
					row.margin:SetText ("|cff888888--|r");
				end

				if (rec.tradeable) then
					row.name:SetTextColor (1, 1, 1);
				else
					row.name:SetTextColor (0.55, 0.55, 0.55);
				end

				row:Show();
			else
				row.rec = nil;
				row:Hide();
			end
		end
	end
end

function Atr_Bz_SelectCategory (key)
	gBz_Cat = key;
	gBz_Sel = nil;
	if (Atr_Bz_CatDD and UIDropDownMenu_SetSelectedValue) then
		UIDropDownMenu_SetSelectedValue (Atr_Bz_CatDD, key);
	end
	if (FauxScrollFrame_SetOffset) then
		if (Atr_Bz_NavScroll)	then FauxScrollFrame_SetOffset (Atr_Bz_NavScroll, 0); end
		if (Atr_Bz_TableScroll)	then FauxScrollFrame_SetOffset (Atr_Bz_TableScroll, 0); end
	end
	Atr_Bz_RebuildDisplay();
end

function Atr_Bz_SelectItem (rec)
	gBz_Sel = rec;
	Atr_Bz_RefreshNav();
end

function Atr_Bz_SetShowBound (v)
	gBz_ShowBound = v and true or false;
	Atr_Bz_RebuildDisplay();
end

-- exposed for tests
function Atr_Bz_View ()			return gBz_View; end
function Atr_Bz_Listings ()		return gBz_Listings; end

-- BT, DP, USD and Margin are all monotonic in the per-item price, so they
-- share its ordering; only stack size and stack price differ.
local function Bz_ListingSortValue (L, key)

	if (key == "name") then return L.count or 0; end

	if (key == "ah") then
		if (L.perItem == nil) then return nil; end
		return L.perItem * (L.count or 1);
	end

	return L.perItem;			-- nil for a bid-only listing
end

local function Bz_ListingComparator (a, b)

	local av = Bz_ListingSortValue (a, gBz_ISortKey);
	local bv = Bz_ListingSortValue (b, gBz_ISortKey);

	-- bid-only listings have no price to rank, so they sit at the bottom
	-- whichever way the column is pointing
	if (av == nil and bv == nil)	then return (a.count or 0) < (b.count or 0); end
	if (av == nil)					then return false; end
	if (bv == nil)					then return true; end

	if (av == bv) then return (a.count or 0) < (b.count or 0); end

	if (gBz_ISortAsc) then return av < bv; end
	return av > bv;
end

function Atr_Bz_SortListings ()
	table.sort (gBz_Listings, Bz_ListingComparator);
end

function Atr_Bz_SetListings (rows)
	gBz_Listings = rows or {};
	Atr_Bz_SortListings();
	Atr_Bz_RefreshTable();
end

-- Switches the seven column headers between the two meanings and shows or
-- hides the Back control.  Sorting only applies to the catalogue view.
function Atr_Bz_SetView (view)

	gBz_View = (view == "ITEM") and "ITEM" or "LIST";

	local labels = (gBz_View == "ITEM") and BZ_HEAD_ITEM or BZ_HEAD_LIST;
	local key, btn;
	for key, btn in pairs (gBz_Headers) do
		if (btn.label and labels[key]) then btn.label:SetText (BZT(labels[key])); end
	end
	Atr_Bz_UpdateHeaderArrows();

	-- both stay put; only their enabled state changes, so neither button ever
	-- appears under a cursor that was aimed at the other one
	local function setEnabled (btn, on)
		if (not btn) then return; end
		if (btn.Show) then btn:Show(); end
		if (on) then
			if (btn.Enable) then btn:Enable(); end
		else
			if (btn.Disable) then btn:Disable(); end
		end
	end

	setEnabled (Atr_Bz_BackButton, gBz_View == "ITEM");
	setEnabled (Atr_Bz_ScanButton, gBz_View ~= "ITEM");
	Atr_Bz_ApplyColumns();
	Atr_Bz_Relayout();
	Atr_Bz_RefreshItemTitle();

	Atr_Bz_RefreshTable();
end

-- The drill-down's Margin column is meaningless without the number it is
-- measured against, so the vendor price sits in the title beside the name.
function Atr_Bz_RefreshItemTitle ()

	if (not Atr_Bz_ItemTitle) then return; end

	if (gBz_View ~= "ITEM" or gBz_Sel == nil) then
		Atr_Bz_ItemTitle:SetText ("");
		if (Atr_Bz_ItemSub) then Atr_Bz_ItemSub:SetText (""); end
		if (Atr_Bz_ItemIcon) then Atr_Bz_ItemIcon:Hide(); end
		return;
	end

	if (Atr_Bz_ItemIcon) then
		if (Atr_Bz_ItemIcon.texture) then
			Atr_Bz_ItemIcon.texture:SetTexture (Atr_Bz_ItemTexture (gBz_Sel));
		end
		Atr_Bz_ItemIcon:Show();
	end

	Atr_Bz_ItemTitle:SetText (gBz_Sel.name or "");

	if (not Atr_Bz_ItemSub) then return; end

	-- The NPC's actual asking price, not a conversion.  Anything the vendor
	-- does not stock -- the webshop-only items, for instance -- says so rather
	-- than showing a zero.
	if (gBz_Sel.bt == nil or gBz_Sel.bt <= 0) then
		Atr_Bz_ItemSub:SetText ("|cff888888"..BZT("not sold by Tiraxis").."|r");
		return;
	end

	Atr_Bz_ItemSub:SetText (string.format ("|cff888888%s|r %s |cffffd70bBT|r",
			BZT("vendor:"), Atr_Bz_BTString (gBz_Sel.bt)));
end

-- Hands the item to Auctionator's Buy tab rather than reimplementing purchase.
-- Buying is not one call: indices from GetAuctionItemInfo are only valid for
-- the page currently loaded, and our listings are condensed across up to eight
-- pages, so a row here corresponds to no single live auction.  Auctionator
-- already re-queries, rebuilds a match list and handles partial fills, with a
-- confirmation step -- all of it tested by people spending real gold.
function Atr_Bz_JumpToBuy ()

	-- only from a listing: the selection survives CloseItem so the navigator
	-- can keep highlighting it, so a bare "is something selected" test would
	-- also fire from the catalogue view
	if (gBz_View ~= "ITEM") then return false; end

	local rec = gBz_Sel;
	if (rec == nil or rec.name == nil) then return false; end

	if (Atr_SelectPane == nil or Atr_Search_Box == nil or Atr_Search_Onclick == nil) then
		Atr_Bz_SetMessage (BZT("The Buy tab is not available."));
		return false;
	end

	gBz_BackToBz = true;

	-- select first: the search box belongs to the shared main panel and is
	-- hidden until the Buy tab is up
	Atr_SelectPane (BZ_BUY_TAB);

	-- quoted, so Auctionator treats it as an exact name rather than a substring
	Atr_Search_Box:SetText ('"'..rec.name..'"');
	Atr_Search_Onclick();

	return true;
end

function Atr_Bz_ReturnFromBuy ()
	gBz_BackToBz = false;
	if (Atr_Bz_BuyBackButton) then Atr_Bz_BuyBackButton:Hide(); end
	if (Atr_SelectPane and ATR_BAZAAR_TAB) then Atr_SelectPane (ATR_BAZAAR_TAB); end
end

function Atr_Bz_JumpPending () return gBz_BackToBz; end

function Atr_Bz_OpenItem (rec)
	if (rec == nil) then return; end
	-- a manual drill-down takes over the scanner, so stop any bulk run first
	if (Atr_Bz_CancelCategoryScan) then Atr_Bz_CancelCategoryScan (true); end
	gBz_Sel = rec;
	Atr_Bz_SetListings ({});
	Atr_Bz_SetView ("ITEM");
	Atr_Bz_RefreshNav();
	if (Atr_Bz_StartItemScan) then Atr_Bz_StartItemScan (rec); end
end

function Atr_Bz_CloseItem ()
	if (Atr_Bz_CancelItemScan) then Atr_Bz_CancelItemScan (true); end
	Atr_Bz_SetView ("LIST");
	Atr_Bz_SetMessage ("");
	Atr_Bz_RebuildDisplay();
end

function Atr_Bz_CurrentRows ()	return gBz_Rows; end
function Atr_Bz_CurrentCat ()	return gBz_Cat; end
function Atr_Bz_Selected ()		return gBz_Sel; end

-------------------------------------------------------------------------------
-- rate display
-------------------------------------------------------------------------------

function Atr_Bz_RefreshRateDisplay ()

	local r = Atr_Bz_GetRates();

	if (Atr_Bz_RateUSD) then
		Atr_Bz_RateUSD:SetText (string.format ("$%g = %g DP", r.usdBundle, r.dpBundle));
	end
	if (Atr_Bz_RateDP) then
		Atr_Bz_RateDP:SetText (string.format ("%g DP = %g BT", r.dpUnits, r.btUnits));
	end
	if (Atr_Bz_RateBT) then
		Atr_Bz_RateBT:SetText ("1 BT = "..Atr_Bz_MoneyString (r.copperPerBT));
	end
	if (Atr_Bz_RateSrc) then
		local src = r.btSource;
		if (src == "auction") then
			src = string.format (BZT("live AH, %d seen"), r.btSampleN or 0);
		end
		Atr_Bz_RateSrc:SetText ("|cff888888("..BZT(src)..")|r");
	end

	Atr_Bz_RefreshItemTitle();
	Atr_Bz_RefreshTable();
end

-------------------------------------------------------------------------------
-- category dropdown (the same API Auctionator's own dropdowns use)
-------------------------------------------------------------------------------

function Atr_Bz_CatDD_OnClick (self)
	if (UIDropDownMenu_SetSelectedValue) then
		UIDropDownMenu_SetSelectedValue (Atr_Bz_CatDD, self.value);
	end
	Atr_Bz_SelectCategory (self.value);
end

function Atr_Bz_CatDD_Initialize (self)

	local i;
	for i = 1, #ATR_BZ_CATEGORIES do
		local entry = ATR_BZ_CATEGORIES[i];
		local info = UIDropDownMenu_CreateInfo();
		info.text		= entry.label;
		info.value		= entry.key;
		info.func		= Atr_Bz_CatDD_OnClick;
		info.owner		= self;
		info.checked	= nil;
		UIDropDownMenu_AddButton (info);
	end
end

-------------------------------------------------------------------------------
-- layout, measured rather than assumed
-------------------------------------------------------------------------------

-- Repositions every header and cell for the active view.  Called whenever the
-- view changes, so the two column orders can differ without duplicating any
-- widgets.
function Atr_Bz_ApplyColumns ()

	local set = BZ_COLSETS[gBz_View] or BZ_COLSETS.LIST;

	-- a key absent from this view's layout must be hidden, or it lingers with
	-- stale text at whatever position the other view left it
	local active = {};
	local k;
	for k = 1, #set do active[set[k].key] = true; end

	local function visible (obj, key)
		if (not obj) then return; end
		if (active[key]) then
			if (obj.Show) then obj:Show(); end
		else
			if (obj.Hide) then obj:Hide(); end
		end
	end

	local function place (obj, right, w)
		if (not obj) then return; end
		if (obj.ClearAllPoints) then obj:ClearAllPoints(); end
		obj:SetPoint ("RIGHT", obj.__host, "RIGHT", -right, 0);
		if (obj.SetWidth) then obj:SetWidth (w); end
	end

	local i, c;

	if (Atr_Bz_Headers) then

		if (Atr_Bz_Headers.ClearAllPoints) then Atr_Bz_Headers:ClearAllPoints(); end
		Atr_Bz_Headers:SetPoint ("TOPLEFT", 0, -(set.headerTop or 0));
		Atr_Bz_Headers:SetPoint ("TOPRIGHT", 0, -(set.headerTop or 0));

		local hn = gBz_Headers["name"];
		if (hn) then
			if (hn.ClearAllPoints) then hn:ClearAllPoints(); end
			hn:SetPoint ("LEFT", Atr_Bz_Headers, "LEFT", 4, 0);
			hn:SetPoint ("RIGHT", Atr_Bz_Headers, "RIGHT", -set.nameRight, 0);
		end

		for k, btn in pairs (gBz_Headers) do
			if (k ~= "name") then visible (btn, k); end
		end

		for i = 1, #set do
			local btn = gBz_Headers[set[i].key];
			if (btn) then
				btn.__host = Atr_Bz_Headers;
				place (btn, set[i].right - 2, set[i].w + 4);
			end
		end
	end

	for i = 1, BZ_ROW_POOL do

		local row = _G["Atr_Bz_Row"..i];
		if (row) then

			local y = -set.top - (i - 1) * BZ_ROW_H;
			if (row.ClearAllPoints) then row:ClearAllPoints(); end
			row:SetPoint ("TOPLEFT", 0, y);
			row:SetPoint ("TOPRIGHT", 0, y);

			if (row.name) then
				if (row.name.ClearAllPoints) then row.name:ClearAllPoints(); end
				row.name:SetPoint ("LEFT", row, "LEFT", 6, 0);
				row.name:SetPoint ("RIGHT", row, "RIGHT", -set.nameRight, 0);
			end

			for c = 1, #BZ_ALL_KEYS do
				visible (row[BZ_ALL_KEYS[c]], BZ_ALL_KEYS[c]);
			end

			for c = 1, #set do
				local fs = row[set[c].key];
				if (fs) then
					fs.__host = row;
					place (fs, set[c].right, set[c].w);
				end
			end
		end
	end

	if (Atr_Bz_TableScroll and Atr_Bz_TableScroll.ClearAllPoints) then
		Atr_Bz_TableScroll:ClearAllPoints();
		Atr_Bz_TableScroll:SetPoint ("TOPLEFT", 0, -set.top);
		Atr_Bz_TableScroll:SetPoint ("RIGHT", 0, 0);
		if (Atr_Bz_TableScroll.SetHeight) then
			Atr_Bz_TableScroll:SetHeight (gBz_TableRows * BZ_ROW_H);
		end
	end
end

-- FauxScrollFrameTemplate parks its scrollbar OUTSIDE the frame's right edge,
-- which put the navigator's bar inside the results pane.  Pull both bars in.
local function Bz_ContainScrollBar (frameName, host)

	local sb = _G[frameName.."ScrollBar"];
	if (not sb or not sb.ClearAllPoints or not host) then return; end

	sb:ClearAllPoints();
	sb:SetPoint ("TOPRIGHT", host, "TOPRIGHT", -2, -16);
	sb:SetPoint ("BOTTOMRIGHT", host, "BOTTOMRIGHT", -2, 16);
end

-- Called after the panel exists and again every time the tab is shown: the
-- frame can be resized by other addons, and its height is not known until it
-- has actually been laid out.
function Atr_Bz_Relayout ()

	if (not Atr_Bz_Panel or not Atr_Bz_RateBox) then return; end

	-- left column: navigator fills from BZ_NAV_TOP down to the rate block
	local panelH = (Atr_Bz_Panel.GetHeight and Atr_Bz_Panel:GetHeight()) or 447;
	local rateH  = (Atr_Bz_RateBox.GetHeight and Atr_Bz_RateBox:GetHeight()) or 92;
	local navH   = panelH - BZ_NAV_TOP - rateH - 40;

	gBz_NavRows = math.floor (navH / BZ_NAV_H);
	if (gBz_NavRows < 4) then gBz_NavRows = 4; end
	if (gBz_NavRows > BZ_NAV_POOL) then gBz_NavRows = BZ_NAV_POOL; end

	if (Atr_Bz_NavScroll and Atr_Bz_NavScroll.SetHeight) then
		Atr_Bz_NavScroll:SetHeight (gBz_NavRows * BZ_NAV_H);
	end

	-- right pane: rows fill whatever is under the headers
	local paneH = (Atr_Bz_TablePane and Atr_Bz_TablePane.GetHeight
					and Atr_Bz_TablePane:GetHeight()) or 380;
	local set	= BZ_COLSETS[gBz_View] or BZ_COLSETS.LIST;
	local rowsH	= paneH - set.top - BZ_TABLE_BOT;

	gBz_TableRows = math.floor (rowsH / BZ_ROW_H);
	if (gBz_TableRows < 4) then gBz_TableRows = 4; end
	if (gBz_TableRows > BZ_ROW_POOL) then gBz_TableRows = BZ_ROW_POOL; end

	if (Atr_Bz_TableScroll and Atr_Bz_TableScroll.SetHeight) then
		Atr_Bz_TableScroll:SetHeight (gBz_TableRows * BZ_ROW_H);
	end

	-- Put Back on the frame's own bottom bar by measuring where Auctionator's
	-- Buy button sits, rather than guessing a pixel offset: that button is
	-- already on the bar, and the Finder anchors its own Back to it.
	if (Atr_Bz_ScanButton and Atr_Bz_ScanButton.SetPoint) then

		local y = BZ_BACK_Y;

		if (Atr_Buy1_Button and Atr_Buy1_Button.GetBottom
			and AuctionFrame and AuctionFrame.GetBottom) then
			local bb = Atr_Buy1_Button:GetBottom();
			local fb = AuctionFrame:GetBottom();
			if (bb and fb) then y = bb - fb; end
		end

		if (Atr_Bz_ScanButton and Atr_Bz_ScanButton.ClearAllPoints) then
			Atr_Bz_ScanButton:ClearAllPoints();
			Atr_Bz_ScanButton:SetPoint ("BOTTOM", AuctionFrame, "BOTTOM", 0, y);
		end
	end

	Atr_Bz_ApplyColumns();

	Bz_ContainScrollBar ("Atr_Bz_NavScroll", Atr_Bz_NavScroll);
	Bz_ContainScrollBar ("Atr_Bz_TableScroll", Atr_Bz_TableScroll);

	Atr_Bz_RefreshNav();
	Atr_Bz_RefreshTable();
end

-- exposed for tests
function Atr_Bz_VisibleRows () return gBz_NavRows, gBz_TableRows; end

-------------------------------------------------------------------------------
-- construction
-------------------------------------------------------------------------------

function Atr_Bz_Init ()

	if (Atr_Bz_Panel) then
		return Atr_Bz_Panel;
	end

	Atr_Bz_InitRates();

	local panel = CreateFrame ("Frame", "Atr_Bz_Panel", AuctionFrame);
	panel:SetSize (738, 447);
	panel:SetPoint ("TOPLEFT", 10, 0);
	panel:Hide();

	local title = panel:CreateFontString ("Atr_Bz_Title", "BACKGROUND", "GameFontNormal");
	title:SetPoint ("TOP", -10, -18);
	title:SetText ("Auctionator - "..BZT("Bazaar"));

	-- ---------------------------------------------------------------- left
	-- category picker, sitting where the Buy tab's shopping-list dropdown does

	local dd = CreateFrame ("Frame", "Atr_Bz_CatDD", panel, "UIDropDownMenuTemplate");
	-- a UIDropDownMenu's visible box is inset ~16px inside its own frame
	dd:SetPoint ("TOPLEFT", BZ_LEFT_X - 16, -BZ_DD_Y);

	if (UIDropDownMenu_Initialize) then
		UIDropDownMenu_Initialize (dd, Atr_Bz_CatDD_Initialize);
		UIDropDownMenu_SetWidth (dd, BZ_LEFT_W - 24);
		UIDropDownMenu_JustifyText (dd, "LEFT");
		UIDropDownMenu_SetSelectedValue (dd, gBz_Cat);
	end

	local summary = panel:CreateFontString ("Atr_Bz_CatSummary", "ARTWORK", "GameFontDisableSmall");
	summary:SetPoint ("TOPLEFT", BZ_LEFT_X + 2, -(BZ_NAV_TOP - 16));
	summary:SetWidth (BZ_LEFT_W);
	summary:SetJustifyH ("LEFT");

	-- item navigator
	local navScroll = CreateFrame ("ScrollFrame", "Atr_Bz_NavScroll", panel, "FauxScrollFrameTemplate");
	navScroll:SetSize (BZ_LEFT_W, gBz_NavRows * BZ_NAV_H);
	navScroll:SetPoint ("TOPLEFT", BZ_LEFT_X, -BZ_NAV_TOP);
	navScroll:SetScript ("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll (self, offset, BZ_NAV_H, Atr_Bz_RefreshNav);
	end);

	local i;
	for i = 1, BZ_NAV_POOL do
		local row = CreateFrame ("Button", "Atr_Bz_NavRow"..i, panel);
		row:SetSize (BZ_LEFT_W - BZ_SB_GUTTER, BZ_NAV_H);
		row:SetPoint ("TOPLEFT", BZ_LEFT_X, -BZ_NAV_TOP - (i - 1) * BZ_NAV_H);
		row:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");
		row.text = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
		row.text:SetPoint ("LEFT", 3, 0);
		row.text:SetJustifyH ("LEFT");
		row:SetScript ("OnClick", function (self)
			if (self.rec) then Atr_Bz_OpenItem (self.rec); end
		end);
		-- names are chopped to fit, so hovering gives the real item tooltip
		row:SetScript ("OnEnter", function (self)
			if (self.rec) then Atr_Bz_ShowItemTooltip (self, self.rec); end
		end);
		row:SetScript ("OnLeave", function ()
			if (GameTooltip) then GameTooltip:Hide(); end
		end);
		row:Hide();
	end

	-- ------------------------------------------------- exchange rate block
	-- occupying the four shopping-list buttons' slot

	local rateBox = CreateFrame ("Frame", "Atr_Bz_RateBox", panel);
	rateBox:SetSize (BZ_LEFT_W, 92);
	-- anchored to the frame's own bottom-left so it always sits just above the
	-- money frame regardless of how tall AuctionFrame really is
	rateBox:SetPoint ("BOTTOMLEFT", AuctionFrame, "BOTTOMLEFT", BZ_LEFT_X + 10, 34);

	local rbg = rateBox:CreateTexture (nil, "BACKGROUND");
	rbg:SetTexture (0, 0, 0, 0.5);
	rbg:SetAllPoints();

	local rlabel = rateBox:CreateFontString ("Atr_Bz_RateLabel", "ARTWORK", "GameFontNormalSmall");
	rlabel:SetPoint ("TOPLEFT", 4, -4);
	rlabel:SetText (BZT("Exchange rates"));

	local rusd = rateBox:CreateFontString ("Atr_Bz_RateUSD", "ARTWORK", "GameFontHighlightSmall");
	rusd:SetPoint ("TOPLEFT", 6, -20);

	local rdp = rateBox:CreateFontString ("Atr_Bz_RateDP", "ARTWORK", "GameFontHighlightSmall");
	rdp:SetPoint ("TOPLEFT", 6, -33);

	local rbt = rateBox:CreateFontString ("Atr_Bz_RateBT", "ARTWORK", "GameFontHighlightSmall");
	rbt:SetPoint ("TOPLEFT", 6, -46);

	local rsrc = rateBox:CreateFontString ("Atr_Bz_RateSrc", "ARTWORK", "GameFontDisableSmall");
	rsrc:SetPoint ("TOPLEFT", 6, -59);

	local setBtn = CreateFrame ("Button", "Atr_Bz_SetRatesButton", rateBox, "UIPanelButtonTemplate");
	setBtn:SetSize (72, 20);
	setBtn:SetPoint ("BOTTOMLEFT", 3, 3);
	setBtn:SetText (BZT("Set rates"));

	local ahBtn = CreateFrame ("Button", "Atr_Bz_RateFromAHButton", rateBox, "UIPanelButtonTemplate");
	ahBtn:SetSize (72, 20);
	ahBtn:SetPoint ("BOTTOMRIGHT", -3, 3);
	ahBtn:SetText (BZT("From AH"));

	-- both land in Phase 4b / Phase 5; say so rather than doing nothing
	setBtn:SetScript ("OnClick", function ()
		if (Atr_Bz_RateFrame and Atr_Bz_RateFrame:IsShown()) then
			Atr_Bz_HideRateEditor();
		else
			Atr_Bz_ShowRateEditor();
		end
	end);
	ahBtn:SetScript ("OnClick", function ()
		if (Atr_Bz_TokenScanRunning and Atr_Bz_TokenScanRunning()) then
			Atr_Bz_CancelTokenScan();
		elseif (Atr_Bz_StartTokenScan) then
			Atr_Bz_StartTokenScan();
		end
	end);

	-- --------------------------------------------------------------- right
	-- results area, its right edge pinned to the real frame corner

	local pane = CreateFrame ("Frame", "Atr_Bz_TablePane", panel);
	pane:SetPoint ("TOPLEFT", BZ_LEFT_X + BZ_LEFT_W + 12, -BZ_PANE_TOP);
	pane:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -12, 34);

	-- the dark fill starts below the header strip, leaving the column titles
	-- sitting on the frame's own lighter art band
	local pbg = pane:CreateTexture (nil, "BACKGROUND");
	pbg:SetTexture (0, 0, 0, 0.55);
	pbg:SetPoint ("TOPLEFT", 0, -BZ_TABLE_TOP);
	pbg:SetPoint ("BOTTOMRIGHT", 0, 0);

	local flabel = panel:CreateFontString ("Atr_Bz_FilterLabel", "ARTWORK", "GameFontHighlightSmall");
	flabel:SetPoint ("BOTTOMLEFT", pane, "TOPLEFT", 4, 10);
	flabel:SetText (BZT("Filter"));

	local fbox = CreateFrame ("EditBox", "Atr_Bz_FilterBox", panel, "InputBoxTemplate");
	fbox:SetSize (150, 18);
	fbox:SetPoint ("BOTTOMLEFT", pane, "TOPLEFT", 44, 6);
	fbox:SetAutoFocus (false);
	fbox:SetMaxLetters (40);
	fbox:SetScript ("OnTextChanged", function (self)
		Atr_Bz_SetFilter (self:GetText());
	end);
	fbox:SetScript ("OnEscapePressed", function (self)
		self:SetText ("");
		self:ClearFocus();
		Atr_Bz_SetFilter ("");
	end);
	fbox:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); end);

	local headers = CreateFrame ("Frame", "Atr_Bz_Headers", pane);
	headers:SetPoint ("TOPLEFT", 0, 0);
	headers:SetPoint ("TOPRIGHT", 0, 0);
	headers:SetHeight (18);

	-- clickable headers, same shape as the Finder's: a button carrying a label
	-- plus a sort arrow.  The arrow sits on the inside edge of each column so
	-- it never pushes the right-aligned numbers around.
	gBz_Headers = {};

	local function makeHeader (key, text, isName, col)

		local btn = CreateFrame ("Button", "Atr_Bz_Head_"..key, headers);
		btn:SetHeight (18);

		if (isName) then
			btn:SetPoint ("LEFT", headers, "LEFT", 4, 0);
			btn:SetPoint ("RIGHT", headers, "RIGHT", -BZ_COLSETS.LIST.nameRight, 0);
		else
			btn:SetPoint ("RIGHT", headers, "RIGHT", -col.right + 2, 0);
			btn:SetWidth (col.w + 4);
		end

		local hl = btn:CreateTexture (nil, "BACKGROUND");
		hl:SetAllPoints();
		hl:SetTexture (1, 1, 1, 0.06);

		local label = btn:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
		local arrow = btn:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");

		if (isName) then
			label:SetPoint ("LEFT", 2, 0);
			arrow:SetPoint ("LEFT", label, "RIGHT", 3, 0);
			label:SetJustifyH ("LEFT");
		else
			label:SetPoint ("RIGHT", -2, 0);
			arrow:SetPoint ("RIGHT", label, "LEFT", -3, 0);
			label:SetJustifyH ("RIGHT");
		end

		label:SetText (text);
		btn.label = label;
		btn.arrow = arrow;

		btn:SetScript ("OnClick", function () Atr_Bz_HeaderClick (key); end);

		btn:SetScript ("OnEnter", function (self)

			local tip = BZ_HEAD_TIP[key];
			if (not GameTooltip or not tip) then return; end

			GameTooltip:SetOwner (self, "ANCHOR_BOTTOMLEFT");
			GameTooltip:SetText (self.label and self.label:GetText() or "", 1, 1, 1);

			if (type (tip) == "table") then
				local i;
				for i = 1, #tip do
					local c = tip[i][2];
					GameTooltip:AddLine (BZT(tip[i][1]), c[1], c[2], c[3], true);
				end
			else
				GameTooltip:AddLine (BZT(tip), 0.85, 0.85, 0.85, true);
			end

			GameTooltip:Show();
		end);
		btn:SetScript ("OnLeave", function ()
			if (GameTooltip) then GameTooltip:Hide(); end
		end);
		btn:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");

		gBz_Headers[key] = btn;
		return btn;
	end

	-- Labels come from BZ_HEAD_LIST / BZ_HEAD_ITEM, not from the column sets:
	-- the sets carry geometry only.  Reading a .label off them silently yielded
	-- nil, which is why the headers used to render blank until the first view
	-- switch filled them in.
	makeHeader ("name", BZT(BZ_HEAD_LIST.name), true, nil);

	for i = 1, #BZ_COLS do
		local key = BZ_COLS[i].key;
		makeHeader (key, BZT(BZ_HEAD_LIST[key] or key), false, BZ_COLS[i]);
	end

	Atr_Bz_UpdateHeaderArrows();

	-- on the frame's own bottom bar, level with the money frame, where the Buy
	-- tab keeps its "Back to Finder"
	-- "Back to Bazaar" lives on the BUY tab, beside Auctionator's own buy
	-- controls.  Anchored left of the Finder's equivalent where that exists, so
	-- the two cannot overlap if it is ever wired up.
	if (Atr_Buy1_Button) then

		local bb = CreateFrame ("Button", "Atr_Bz_BuyBackButton",
					Atr_Buy1_Button:GetParent() or AuctionFrame, "UIPanelButtonTemplate");
		bb:SetSize (120, 24);

		if (Atr_Finder_BackButton) then
			bb:SetPoint ("RIGHT", Atr_Finder_BackButton, "LEFT", -6, 0);
		else
			bb:SetPoint ("RIGHT", Atr_Buy1_Button, "LEFT", -45, 0);
		end

		bb:SetText (BZT("Back to Bazaar"));
		bb:Hide();
		bb:SetScript ("OnClick", Atr_Bz_ReturnFromBuy);
	end

	-- immediately right of the Filter box, on the same line
	local back = CreateFrame ("Button", "Atr_Bz_BackButton", panel, "UIPanelButtonTemplate");
	back:SetSize (BZ_BACK_W, BZ_BACK_H);
	back:SetPoint ("BOTTOMLEFT", pane, "TOPLEFT", 204, 6);
	back:SetText (BZT("Back"));
	back:SetScript ("OnClick", function () Atr_Bz_CloseItem(); end);
	back:Hide();

	-- The icon and title live inside the pane, above the column headers, in the
	-- taller strip the ITEM column set reserves.  That strip is also what makes
	-- the auction list shorter than the catalogue's.
	local iconBtn = CreateFrame ("Button", "Atr_Bz_ItemIcon", pane);
	iconBtn:SetSize (42, 42);
	-- the drill-down's header strip now sits BELOW this, so the icon and title
	-- take the top of the pane
	iconBtn:SetPoint ("TOPLEFT", 10, -8);
	iconBtn:Hide();

	local iconTex = iconBtn:CreateTexture ("Atr_Bz_ItemIconTexture", "ARTWORK");
	iconTex:SetAllPoints();
	iconBtn.texture = iconTex;

	iconBtn:SetScript ("OnEnter", function (self)
		Atr_Bz_ShowItemTooltip (self, Atr_Bz_Selected(), "ANCHOR_BOTTOMRIGHT");
	end);
	iconBtn:SetScript ("OnLeave", function ()
		if (GameTooltip) then GameTooltip:Hide(); end
	end);

	-- Back and the bulk-pricing button occupy the same spot on the bottom bar:
	-- only one of them is ever meaningful at a time.
	local scan = CreateFrame ("Button", "Atr_Bz_ScanButton", panel, "UIPanelButtonTemplate");
	scan:SetSize (BZ_BTN_W, BZ_BTN_H);
	scan:SetPoint ("BOTTOM", AuctionFrame, "BOTTOM", 0, BZ_BACK_Y);
	scan:SetText (BZT("Price these"));
	if (scan.SetNormalFontObject and GameFontNormalLarge) then
		scan:SetNormalFontObject (GameFontNormalLarge);
		if (scan.SetHighlightFontObject) then scan:SetHighlightFontObject (GameFontNormalLarge); end
	end
	scan:SetScript ("OnClick", function ()
		if (Atr_Bz_StartCategoryScan) then Atr_Bz_StartCategoryScan(); end
	end);

	local ititle = pane:CreateFontString ("Atr_Bz_ItemTitle", "ARTWORK", "GameFontNormalLarge");
	ititle:SetPoint ("TOPLEFT", 62, -12);
	ititle:SetPoint ("RIGHT", pane, "RIGHT", -12, 0);
	ititle:SetJustifyH ("LEFT");

	local isub = pane:CreateFontString ("Atr_Bz_ItemSub", "ARTWORK", "GameFontHighlightSmall");
	isub:SetPoint ("TOPLEFT", 64, -36);
	isub:SetPoint ("RIGHT", pane, "RIGHT", -12, 0);
	isub:SetJustifyH ("LEFT");

	local tblScroll = CreateFrame ("ScrollFrame", "Atr_Bz_TableScroll", pane, "FauxScrollFrameTemplate");
	tblScroll:SetPoint ("TOPLEFT", 0, -BZ_TABLE_TOP);
	tblScroll:SetPoint ("RIGHT", 0, 0);
	tblScroll:SetHeight (gBz_TableRows * BZ_ROW_H);
	tblScroll:SetScript ("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll (self, offset, BZ_ROW_H, Atr_Bz_RefreshTable);
	end);

	for i = 1, BZ_ROW_POOL do

		local row = CreateFrame ("Button", "Atr_Bz_Row"..i, pane);
		row:SetHeight (BZ_ROW_H);
		row:SetPoint ("TOPLEFT", 0, -BZ_TABLE_TOP - (i - 1) * BZ_ROW_H);
		row:SetPoint ("TOPRIGHT", 0, -BZ_TABLE_TOP - (i - 1) * BZ_ROW_H);
		row:SetHighlightTexture ("Interface\\QuestFrame\\UI-QuestTitleHighlight");

		local nm = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
		nm:SetPoint ("LEFT", row, "LEFT", 6, 0);
		nm:SetPoint ("RIGHT", row, "RIGHT", -BZ_COLSETS.LIST.nameRight, 0);
		nm:SetJustifyH ("LEFT");
		row.name = nm;

		local c;
		for c = 1, #BZ_COLS do
			local col = BZ_COLS[c];
			local fs = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			fs:SetPoint ("RIGHT", row, "RIGHT", -col.right, 0);
			fs:SetWidth (col.w);
			fs:SetJustifyH ("RIGHT");
			row[col.key] = fs;
		end

		row:SetScript ("OnClick", function (self)
			if (gBz_View == "ITEM") then
				Atr_Bz_JumpToBuy();
			elseif (self.rec) then
				Atr_Bz_OpenItem (self.rec);
			end
		end);
		row:SetScript ("OnEnter", function (self)
			if (self.rec) then Atr_Bz_ShowItemTooltip (self, self.rec); end
		end);
		row:SetScript ("OnLeave", function ()
			if (GameTooltip) then GameTooltip:Hide(); end
		end);
		row:Hide();
	end

	-- the status line shares the filter row instead of sitting under the table,
	-- so the rows can run all the way to the bottom of the pane
	local msg = panel:CreateFontString ("Atr_Bz_Message", "ARTWORK", "GameFontNormal");
	msg:SetPoint ("BOTTOMRIGHT", pane, "TOPRIGHT", -4, 8);
	msg:SetPoint ("BOTTOMLEFT", pane, "TOPLEFT", 310, 8);
	msg:SetJustifyH ("RIGHT");

	Atr_Bz_BuildRateEditor (panel);

	Atr_Bz_RefreshRateDisplay();
	Atr_Bz_RebuildDisplay();

	-- settle the view once, so labels, column layout and button visibility are
	-- all correct on the very first frame rather than after the first drill-in
	Atr_Bz_SetView (gBz_View);

	return panel;
end

-- called at the top of Atr_AuctionFrameTab_OnClick for EVERY tab, before
-- Blizzard's handler runs.  Later phases cancel scans here.
function Atr_Bz_OnTabClick (index)

	if (ATR_BAZAAR_TAB == nil or Atr_FindTabIndex == nil) then return; end

	if (Atr_Bz_BuyBackButton) then
		if (gBz_BackToBz and index == Atr_FindTabIndex (BZ_BUY_TAB)) then
			Atr_Bz_BuyBackButton:Show();
		else
			Atr_Bz_BuyBackButton:Hide();
		end
	end

	if (index == Atr_FindTabIndex (ATR_BAZAAR_TAB)) then
		gBz_BackToBz = false;
		Atr_Bz_RefreshRateDisplay();
		Atr_Bz_RebuildDisplay();
		Atr_Bz_Relayout();
	elseif (Atr_Bz_HideRateEditor) then
		Atr_Bz_HideRateEditor();
		if (Atr_Bz_CancelTokenScan) then Atr_Bz_CancelTokenScan (true); end
		if (Atr_Bz_CancelCategoryScan) then Atr_Bz_CancelCategoryScan (true); end
		if (Atr_Bz_CancelItemScan) then Atr_Bz_CancelItemScan (true); end
	end
end

-------------------------------------------------------------------------------
-- PHASE 4c: the rate editor.
--
-- Applied ATOMICALLY.  Every box is validated before any rate is written, so
-- one bad field can never leave the chain half-updated -- a state that would
-- silently misprice all 294 items with no visible error.
-------------------------------------------------------------------------------

-- returns  ok(boolean), badKey(string or nil), message(string or nil)
function Atr_Bz_ApplyRates (vals)

	if (type (vals) ~= "table") then
		return false, nil, BZT("no values");
	end

	local order = { "usdBundle", "dpBundle", "dpUnits", "btUnits", "copperPerBT" };
	local clean = {};

	local i;
	for i = 1, #order do
		local key = order[i];
		if (vals[key] ~= nil) then
			local v = Atr_Bz_IsPositiveNumber (vals[key]);
			if (v == nil) then
				return false, key, BZT("must be a positive number");
			end
			clean[key] = v;
		end
	end

	local key, v;
	for key, v in pairs (clean) do
		Atr_Bz_SetRate (key, v);
	end

	Atr_Bz_RefreshRateDisplay();
	return true;
end

-------------------------------------------------------------------------------

function Atr_Bz_LoadRateEditor ()

	local r = Atr_Bz_GetRates();

	local gold		= math.floor (r.copperPerBT / 10000);
	local silver	= (r.copperPerBT - gold * 10000) / 100;

	if (Atr_Bz_Edit_usdBundle)	then Atr_Bz_Edit_usdBundle:SetText (tostring (r.usdBundle)); end
	if (Atr_Bz_Edit_dpBundle)	then Atr_Bz_Edit_dpBundle:SetText (tostring (r.dpBundle)); end
	if (Atr_Bz_Edit_dpUnits)	then Atr_Bz_Edit_dpUnits:SetText (tostring (r.dpUnits)); end
	if (Atr_Bz_Edit_btUnits)	then Atr_Bz_Edit_btUnits:SetText (tostring (r.btUnits)); end
	if (Atr_Bz_Edit_gold)		then Atr_Bz_Edit_gold:SetText (tostring (gold)); end
	if (Atr_Bz_Edit_silver)		then Atr_Bz_Edit_silver:SetText (tostring (silver)); end

	if (Atr_Bz_RateError) then Atr_Bz_RateError:SetText (""); end
end

function Atr_Bz_ShowRateEditor ()
	if (not Atr_Bz_RateFrame) then return; end
	Atr_Bz_LoadRateEditor();
	Atr_Bz_RateFrame:Show();
end

function Atr_Bz_HideRateEditor ()
	if (Atr_Bz_RateFrame) then Atr_Bz_RateFrame:Hide(); end
end

-- returns ok, so the harness can drive it without the UI
function Atr_Bz_SaveRateEditor ()

	local function boxNum (name)
		local box = _G[name];
		return box and box:GetText();
	end

	local copper = Atr_Bz_CopperFromGS (boxNum ("Atr_Bz_Edit_gold"), boxNum ("Atr_Bz_Edit_silver"));

	local ok, badKey, msg = Atr_Bz_ApplyRates {
		usdBundle	= boxNum ("Atr_Bz_Edit_usdBundle"),
		dpBundle	= boxNum ("Atr_Bz_Edit_dpBundle"),
		dpUnits		= boxNum ("Atr_Bz_Edit_dpUnits"),
		btUnits		= boxNum ("Atr_Bz_Edit_btUnits"),
		copperPerBT	= copper,
	};

	if (not ok) then
		if (Atr_Bz_RateError) then
			local label = badKey or BZT("token price");
			if (badKey == nil) then label = BZT("token price"); end
			Atr_Bz_RateError:SetText ("|cffff5555"..label..": "..(msg or "?").."|r");
		end
		return false;
	end

	Atr_Bz_HideRateEditor();
	Atr_Bz_SetMessage (BZT("Exchange rates updated."));
	return true;
end

function Atr_Bz_ResetRateEditor ()
	Atr_Bz_ResetRates();
	Atr_Bz_LoadRateEditor();
	Atr_Bz_RefreshRateDisplay();
end

-------------------------------------------------------------------------------

-- InputBoxTemplate draws border art a few pixels beyond the editable width,
-- so layout maths has to allow for it or boxes visually collide with labels.
local BZ_EDIT_PAD	= 14;
local BZ_ROW_GAP	= 7;

local function Bz_MakeEdit (parent, key, w)

	local box = CreateFrame ("EditBox", "Atr_Bz_Edit_"..key, parent, "InputBoxTemplate");
	box:SetSize (w, 18);
	box:SetAutoFocus (false);
	box:SetMaxLetters (10);
	box:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);
	box:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); Atr_Bz_SaveRateEditor(); end);
	return box;
end

-- Lays a row out symmetrically about the frame's CENTER rather than from a
-- hardcoded left margin: measured labels mean nothing can overlap regardless
-- of how wide a translated string turns out to be.
local function Bz_CenterRow (f, y, parts)

	local widths	= {};
	local total		= 0;
	local i;

	for i = 1, #parts do

		local p = parts[i];

		if (p.key) then
			p.obj		= Bz_MakeEdit (f, p.key, p.w);
			widths[i]	= p.w + BZ_EDIT_PAD;
		else
			p.obj = f:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			p.obj:SetText (p.label);
			widths[i] = (p.obj.GetStringWidth and p.obj:GetStringWidth())
						or (string.len (p.label) * 6);
		end

		total = total + widths[i];
		if (i > 1) then total = total + BZ_ROW_GAP; end
	end

	local x = -total / 2;
	for i = 1, #parts do
		parts[i].obj:SetPoint ("LEFT", f, "CENTER", x, y);
		x = x + widths[i] + BZ_ROW_GAP;
	end

	return total;
end

function Atr_Bz_BuildRateEditor (panel)

	local f = CreateFrame ("Frame", "Atr_Bz_RateFrame", panel);
	f:SetSize (300, 186);
	f:SetPoint ("CENTER", Atr_Bz_TablePane or panel, "CENTER", 0, 20);
	f:SetFrameStrata ("DIALOG");
	f:EnableMouse (true);
	f:Hide();

	if (f.SetBackdrop) then
		f:SetBackdrop {
			bgFile		= "Interface\\Buttons\\WHITE8X8",
			edgeFile	= "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		};
		-- flat opaque dark grey: the translucent fill made the dialog hard to read
		if (f.SetBackdropColor)			then f:SetBackdropColor (0.13, 0.13, 0.13, 1); end
		if (f.SetBackdropBorderColor)	then f:SetBackdropBorderColor (1, 1, 1, 1); end
	end

	local title = f:CreateFontString ("Atr_Bz_RateTitle", "ARTWORK", "GameFontNormal");
	title:SetPoint ("TOP", 0, -12);
	title:SetText (BZT("Set exchange rates"));

	-- row 1: the bundle you actually buy.  DP is sold in volume-discounted
	-- tiers, so there is no single true USD/DP rate to hardcode.
	Bz_CenterRow (f, 34, {
		{ label = "$" },
		{ key = "usdBundle",	w = 25 },
		{ label = "=" },
		{ key = "dpBundle",		w = 30 },
		{ label = "DP" },
	});

	Bz_CenterRow (f, 8, {
		{ label = "DP" },
		{ key = "dpUnits",		w = 25 },
		{ label = "=" },
		{ key = "btUnits",		w = 30 },
		{ label = "BT" },
	});

	-- silver is the one field that holds a decimal (59.04), so it keeps a
	-- little more room than a straight halving would give it
	Bz_CenterRow (f, -18, {
		{ label = "1 BT =" },
		{ key = "gold",			w = 22 },
		{ label = "g" },
		{ key = "silver",		w = 30 },
		{ label = "s" },
	});

	local err = f:CreateFontString ("Atr_Bz_RateError", "ARTWORK", "GameFontHighlightSmall");
	err:SetPoint ("TOP", f, "CENTER", 0, -38);
	err:SetWidth (270);
	err:SetJustifyH ("CENTER");

	local save = CreateFrame ("Button", "Atr_Bz_RateSave", f, "UIPanelButtonTemplate");
	save:SetSize (76, 22);
	save:SetText (BZT("Save"));
	save:SetScript ("OnClick", Atr_Bz_SaveRateEditor);

	local cancel = CreateFrame ("Button", "Atr_Bz_RateCancel", f, "UIPanelButtonTemplate");
	cancel:SetSize (76, 22);
	cancel:SetText (BZT("Cancel"));
	cancel:SetScript ("OnClick", Atr_Bz_HideRateEditor);

	local reset = CreateFrame ("Button", "Atr_Bz_RateReset", f, "UIPanelButtonTemplate");
	reset:SetSize (76, 22);
	reset:SetText (BZT("Defaults"));
	reset:SetScript ("OnClick", Atr_Bz_ResetRateEditor);

	-- three equal buttons, centred as a group
	local bw, bgap = 76, 8;
	local bTotal = bw * 3 + bgap * 2;
	reset:SetPoint  ("LEFT", f, "CENTER", -bTotal / 2, -68);
	cancel:SetPoint ("LEFT", f, "CENTER", -bTotal / 2 + bw + bgap, -68);
	save:SetPoint   ("LEFT", f, "CENTER", -bTotal / 2 + (bw + bgap) * 2, -68);

	return f;
end

-------------------------------------------------------------------------------
-- PHASE 3: the catalogue.
--
-- Two sources, merged:
--   1. the seed table below, extracted from the Phase 0 probe harvest, so the
--      tab is useful before the player ever walks to Tiraxis;
--   2. a live harvest at the merchant, which supersedes the seed per itemID
--      and keeps working when Ascension changes the vendor.
--
-- Plus a third, small, hand-maintained list: items that are tradeable on the
-- auction house but sold ONLY on the webshop, so they appear on no vendor and
-- cannot be discovered automatically (the Heirloom Weapon Token and heirloom
-- caches are the known cases).  See Atr_Bz_AddExtra.
-------------------------------------------------------------------------------

ATR_BZ_CATEGORIES = {
	{ key = "TOKENS",	label = "Bazaar Tokens" },
	{ key = "BAZAAR",	label = "Browse Bazaar" },
	{ key = "CONV",		label = "Convenience Items" },
	{ key = "CONSUM",	label = "Consumables" },
	{ key = "STONES",	label = "Stones of Retreat" },
	{ key = "HEIRLOOM",	label = "Heirlooms" },
	{ key = "MYSTERY",	label = "Mysterious Wares" },
	{ key = "EXTRA",	label = "Webshop only" },
};

-- Bind codes that cannot be resold.  REALM is Ascension's custom
-- "Binds to realm" line: it has no ITEM_BIND_* global, and leaving it out
-- silently marks 58 bound items as flippable (see ASCENSION-CLIENT-NOTES).
ATR_BZ_UNTRADEABLE = { BOP = true, REALM = true, SOUL = true, QUEST = true };

-- tooltip line -> bind code.  Built from the globals where they exist so
-- non-enUS clients still match, with the observed English text as fallback.
local function Bz_BindMap ()
	return {
		[ITEM_BIND_ON_PICKUP	or "Binds when picked up"]	= "BOP",
		[ITEM_BIND_ON_EQUIP		or "Binds when equipped"]	= "BOE",
		[ITEM_BIND_ON_USE		or "Binds when used"]		= "BOU",
		[ITEM_SOULBOUND			or "Soulbound"]				= "SOUL",
		[ITEM_BIND_QUEST		or "Quest Item"]			= "QUEST",
		["Binds to realm"]									= "REALM",
	};
end

function Atr_Bz_IsTradeable (bind)
	return not ATR_BZ_UNTRADEABLE[bind or "NONE"];
end

-- gossip titles and some tooltip lines arrive wrapped in texture and colour
-- escapes: "|TInterface/ICONS/x:40:40:-22:0|t|rStones of Retreat"
function Atr_Bz_CleanEscapes (s)
	if (type (s) ~= "string") then return ""; end
	s = s:gsub ("|T.-|t", "");
	s = s:gsub ("|c%x%x%x%x%x%x%x%x", "");
	s = s:gsub ("|r", "");
	s = s:gsub ("^%s+", "");
	s = s:gsub ("%s+$", "");
	return s;
end

-- The currency itself.  Its "cost" is 1 token by definition, which makes the
-- BT/DP/USD columns show what one token is worth and the Margin column show
-- how far the auction house has drifted from the rate you have configured.
-- Anything else the token search turns up (the 100-token bundle, say) is
-- learned into this category by the From AH scan.
ATR_BZ_TOKEN_ITEMS = {
	{ id = 975001, bt = 1, bind = "NONE", cat = "TOKENS",
	  name = "Bazaar Token", tex = "Interface\\Icons\\Spell_Shadow_Teleport" },
};

-- id, bazaar-token cost, bind code, category, name, icon
-- The icon path is shipped rather than looked up: GetItemInfo returns nil for
-- an uncached custom item, so a fresh install would otherwise show question
-- marks until the player had physically seen every one of these.
ATR_BZ_SEED = {
	{ 5523428,  100,   "BOE",    "BAZAAR",   "Gnoll Doorstop (Backsheath)",                 "Interface\\Icons\\INV_Axe_04" },
	{ 55012,    100,   "BOE",    "BAZAAR",   "Night Elven Bow",                             "Interface\\Icons\\inv_weapon_bow_11" },
	{ 39662,    200,   "BOE",    "BAZAAR",   "Blade of the Dancing Princess",               "Interface\\Icons\\INV_Sword_24" },
	{ 158330,   200,   "BOE",    "BAZAAR",   "Proudmoore Marine's Crest",                   "Interface\\Icons\\inv_shield_1h_kultirasquest_b_02" },
	{ 67473,    200,   "BOE",    "BAZAAR",   "Vicious Gladiator's Hacker",                  "Interface\\Icons\\inv_axe_1h_pvp400_c_01" },
	{ 189437,   300,   "BOU",    "BAZAAR",   "Brindlehoof Fawn",                            "Interface\\Icons\\inv_babydeer_brown" },
	{ 99948,    300,   "BOE",    "BAZAAR",   "Chromie's Spare Beacon",                      "Interface\\Icons\\inv_offhand_1h_dragonquest_b_02_bronze" },
	{ 44727,    300,   "BOE",    "BAZAAR",   "Shard of the Frozen Hall",                    "Interface\\Icons\\INV_Axe_01" },
	{ 5544727,  300,   "BOE",    "BAZAAR",   "Shard of the Frozen Hall (Backsheath)",       "Interface\\Icons\\INV_Axe_01" },
	{ 50138,    400,   "BOE",    "BAZAAR",   "Bilgewater Backstabber",                      "Interface\\Icons\\inv_weapon_shortblade_109" },
	{ 93372,    400,   "BOE",    "BAZAAR",   "Cobalt Thunderstick",                         "Interface\\Icons\\inv_weapon_rifle_43blue" },
	{ 192152,   400,   "BOE",    "BAZAAR",   "Finger of Zon'ozz",                           "Interface\\Icons\\inv_wand_1h_deathwingraid_d_02" },
	{ 50145,    400,   "BOE",    "BAZAAR",   "Sparkplug Slicer",                            "Interface\\Icons\\inv_axe_117" },
	{ 77189,    500,   "BOE",    "BAZAAR",   "Blade of the Unmaker",                        "Interface\\Icons\\inv_knife_1h_deathwingraiddw_d_01" },
	{ 8210103,  500,   "BOE",    "BAZAAR",   "Blood Troll Guard's Green Spear",             "Interface\\Icons\\inv_weapon_1h_shortspear_bloodtroll" },
	{ 52052,    500,   "BOE",    "BAZAAR",   "Brassmoon Carbine",                           "Interface\\Icons\\inv_weapon_rifle_40" },
	{ 5141602,  500,   "BOE",    "BAZAAR",   "Eredar Splitter(Backsheath)",                 "Interface\\Icons\\inv_axe_121" },
	{ 5546410,  500,   "BOE",    "BAZAAR",   "Frostwolf Frostbiter (Backsheath)",           "Interface\\Icons\\inv_axe_09" },
	{ 71312,    500,   "BOE",    "BAZAAR",   "Gatecrasher",                                 "Interface\\Icons\\inv_axe_1h_firelandsraid_d_02" },
	{ 140552,   500,   "BOE",    "BAZAAR",   "Netherlight Spire",                           "Interface\\Icons\\inv_staff_2h_draenorcrafted_d_01_a_horde" },
	{ 46657,    500,   "BOU",    "BAZAAR",   "Quillbert",                                   "Interface\\Icons\\inv_pineconecritter_white" },
	{ 65791,    500,   "BOE",    "BAZAAR",   "Shield of the Returning Prince",              "Interface\\Icons\\inv_shield_cataclysm_b_01_blue" },
	{ 49423,    600,   "BOE",    "BAZAAR",   "Cursed Thornstaff",                           "Interface\\Icons\\inv_staff_09" },
	{ 99917,    600,   "BOE",    "BAZAAR",   "Drakewatcher's Beacon",                       "Interface\\Icons\\inv_staff_2h_dragonquest_b_01_green" },
	{ 52517,    600,   "BOE",    "BAZAAR",   "Eclipse Stiletto",                            "Interface\\Icons\\inv_weapon_shortblade_110" },
	{ 108506,   600,   "BOE",    "BAZAAR",   "Jade Iron Sharpshooter",                      "Interface\\Icons\\inv_firearm_2h_rifle_draenordungeon_c_01green" },
	{ 290554,   600,   "BOU",    "BAZAAR",   "Malevolent Dunestalker's Set Cache",          "Interface\\Icons\\INV_Chest_Awakening" },
	{ 83758,    600,   "BOE",    "BAZAAR",   "Shield of Orbiss",                            "Interface\\Icons\\inv_shield_pandariaquest_b_01" },
	{ 55354,    600,   "BOE",    "BAZAAR",   "Steelspark Gun",                              "Interface\\Icons\\blue_inv_firearm_2h_rifle_cataclysm_b_02" },
	{ 134929,   700,   "BOE",    "BAZAAR",   "Hornstrider's Pike",                          "Interface\\Icons\\inv_polearm_2h_dragonquest_b_01_green" },
	{ 98884,    700,   "BOU",    "BAZAAR",   "Stone Armadillo Pup",                         "Interface\\Icons\\inv_misc_babyarmadillopet" },
	{ 55064,    800,   "BOE",    "BAZAAR",   "Elementium Spellblade",                       "Interface\\Icons\\inv_knife_1h_grimbatolraid_d_03" },
	{ 264470,   800,   "BOE",    "BAZAAR",   "Emerald Swoglet",                             "Interface\\Icons\\inv_babyhornswog_green" },
	{ 10351,    800,   "BOE",    "BAZAAR",   "Fists of Pained Senses",                      "Interface\\Icons\\INV_Chest_Awakening" },
	{ 5549931,  800,   "BOE",    "BAZAAR",   "Godsbane (Backsheath)",                       "Interface\\Icons\\INV_Sword_04" },
	{ 546730,   800,   "BOU",    "BAZAAR",   "Spring Flutterling",                          "Interface\\Icons\\inv_butterflymount_pink" },
	{ 69596,    800,   "BOE",    "BAZAAR",   "Voodoo Hunting Bow",                          "Interface\\Icons\\INV_Waepon_Bow_ZulGrub_D_02" },
	{ 108476,   900,   "BOE",    "BAZAAR",   "Draenic Protector",                           "Interface\\Icons\\inv_shield_draenorquest95_b_01" },
	{ 86126,    900,   "BOE",    "BAZAAR",   "Malevolent Gladiator's Shield",               "Interface\\Icons\\inv_shield_pvppandarias1_c_01_green" },
	{ 181209,   1000,  "BOE",    "BAZAAR",   "Devourer's Bite",                             "Interface\\Icons\\inv_polarm_2h_revendrethquest_b_01" },
	{ 574494,   1000,  "BOE",    "BAZAAR",   "Dream Raider's Emerald Censer",               "Interface\\Icons\\inv_offhand_1h_emeralddreamraid_d_01_turquoise" },
	{ 118981,   1000,  "BOE",    "BAZAAR",   "Expeditious Bow",                             "Interface\\Icons\\inv_bow_1h_draenorhonor_c_01" },
	{ 115070,   1000,  "BOE",    "BAZAAR",   "Primal Combatant's Energy Staff",             "Interface\\Icons\\inv_staff_2h_draenorhonor_c_02_green" },
	{ 155900,   1000,  "BOE",    "BAZAAR",   "Scalesworn Cultist's Emberkissed Effigy",     "Interface\\Icons\\inv_shoulder_cloth_raidwarlockprimalist_d_01_lightorange" },
	{ 303596,   1100,  "BOU",    "BAZAAR",   "Foreststalker's Honeyleaf Favor",             "Interface\\Icons\\INV_Chest_Awakening" },
	{ 348797,   1100,  "BOE",    "BAZAAR",   "Silver Chainkini",                            "Interface\\Icons\\inv_chest_mail_chainmailset_b_01" },
	{ 86522,    1200,  "BOE",    "BAZAAR",   "Blade of the Prime",                          "Interface\\Icons\\inv_sword_1h_mantid_01" },
	{ 499242,   1200,  "BOE",    "BAZAAR",   "Gavel of the Eredar (Purple)",                "Interface\\Icons\\inv_mace_1h_felfireraid_d_03" },
	{ 178864,   1200,  "BOE",    "BAZAAR",   "Gorebound Predator's Gavel",                  "Interface\\Icons\\inv_mace_1h_oribosdungeon_c_02" },
	{ 110051,   1200,  "BOE",    "BAZAAR",   "Overseer's Final Word",                       "Interface\\Icons\\inv_axe_2h_draenordungeon_c_01" },
	{ 499249,   1200,  "BOE",    "BAZAAR",   "Runeaxe of the Breaker (Red)",                "Interface\\Icons\\inv_axe_1h_felfireraid_d_01" },
	{ 163895,   1200,  "BOE",    "BAZAAR",   "Sanctified Aegis",                            "Interface\\Icons\\inv_shield_1h_warfrontsalliance_c_02" },
	{ 106259,   1200,  "BOE",    "BAZAAR",   "Scepter of Hollow Winds",                     "Interface\\Icons\\inv_staff_2h_arakkoa_c_02_red" },
	{ 174299,   1200,  "BOE",    "BAZAAR",   "Sinful Gladiator's Splitter",                 "Interface\\Icons\\inv_axe_1h_bastion_d_01" },
	{ 110054,   1200,  "BOE",    "BAZAAR",   "Thunderlord Flamestaff",                      "Interface\\Icons\\inv_staff_2h_draenordungeon_c_01" },
	{ 499697,   1300,  "BOE",    "BAZAAR",   "Furnace of the Great Machine",                "Interface\\Icons\\inv_shield_draenorchallenge_d_01" },
	{ 283043,   1300,  "BOE",    "BAZAAR",   "The Horseman's Chilling Great Blade",         "Interface\\Icons\\blue_inv_sword_2h_headless_d_01" },
	{ 174414,   1400,  "BOE",    "BAZAAR",   "Disciple's Peacebound Poniard (Reverse-Grip)", "Interface\\Icons\\inv_knife_1h_bastion_d_01" },
	{ 1777371,  1500,  "BOU",    "BAZAAR",   "Garn Steelmaw",                               "Interface\\Icons\\inv_wolfdraenormountshadow" },
	{ 104179,   1500,  "BOE",    "BAZAAR",   "Iceshear (Aqua)",                             "Interface\\Icons\\inv_knife_1h_artifactfangs_d_05" },
	{ 86387,    1500,  "BOE",    "BAZAAR",   "Kilrak, Jaws of Terror",                      "Interface\\Icons\\inv_sword_1h_pandaraid_d_02" },
	{ 179340,   1500,  "BOE",    "BAZAAR",   "Supercollider",                               "Interface\\Icons\\inv_mace_1h_oribosdungeon_c_02" },
	{ 163956,   1500,  "BOE",    "BAZAAR",   "Treiya's Shining Pillar",                     "Interface\\Icons\\inv_staff_2h_armyoflight_c_01" },
	{ 53137,    1500,  "BOE",    "BAZAAR",   "Triton's Wrath Pike",                         "Interface\\Icons\\inv_staff_115" },
	{ 141378,   1500,  "BOE",    "BAZAAR",   "Unholy Ebon Blade",                           "Interface\\Icons\\inv_sword_1h_ebonblade_b_01_green" },
	{ 291928,   1600,  "BOE",    "BAZAAR",   "Arcing Runeaxe",                              "Interface\\Icons\\yellow_inv_axe_1h_arathoroutdoor_d_01" },
	{ 96518,    1600,  "BOE",    "BAZAAR",   "Athame of the Sanguine Ritual (Gold)",        "Interface\\Icons\\inv_knife_1h_thunderisleraid_d_02" },
	{ 104175,   1600,  "BOE",    "BAZAAR",   "Bloodfeaster (Purple)",                       "Interface\\Icons\\inv_knife_1h_artifactfangs_d_04" },
	{ 106848,   1600,  "BOE",    "BAZAAR",   "Cursed Hand (Red)",                           "Interface\\Icons\\inv_knife_1h_artifactgarona_d_02" },
	{ 291925,   1600,  "BOE",    "BAZAAR",   "Cursed Runeaxe",                              "Interface\\Icons\\purple_inv_axe_1h_arathoroutdoor_d_01" },
	{ 86148,    1600,  "BOE",    "BAZAAR",   "Tihan, Scepter of the Sleeping Emperor (Green)", "Interface\\Icons\\inv_mace_1h_pandaraid_d_02" },
	{ 141380,   1600,  "BOE",    "BAZAAR",   "Unholy Ebon Warblade",                        "Interface\\Icons\\inv_sword_1h_ebonblade_b_02_green" },
	{ 87423,    1800,  "BOE",    "BAZAAR",   "Bjam's Door-Breaker",                         "Interface\\Icons\\inv_sword_2h_pandung_c_01" },
	{ 139134,   1800,  "BOE",    "BAZAAR",   "Hat of the Second Sister",                    "Interface\\Icons\\inv_helm_cloth_witchhat_b_01" },
	{ 96442,    1800,  "BOE",    "BAZAAR",   "Megaera's Poisoned Fang",                     "Interface\\Icons\\inv_knife_1h_thunderisleraid_d_01" },
	{ 181629,   1800,  "BOP",    "BAZAAR",   "Waylight Defender",                           "Interface\\Icons\\inv_shield_1h_bastionquest_b_01" },
	{ 99991,    2000,  "BOE",    "BAZAAR",   "Burnished Aegis of Aggramar",                 "Interface\\Icons\\inv_aegis_of_aggramar_cooper" },
	{ 167938,   2000,  "BOE",    "BAZAAR",   "Notorious Combatant's Deckpounder",           "Interface\\Icons\\inv_mace_2h_warfrontshorde_c_01" },
	{ 49665,    2000,  "BOU",    "BAZAAR",   "Pandaren Monk",                               "Interface\\Icons\\inv_misc_pet_03" },
	{ 1777169,  2200,  "BOE",    "BAZAAR",   "Yasahm the Riftbreaker",                      "Interface\\Icons\\inv_crossbow_2h_broker_c_01" },
	{ 113672,   2400,  "BOU",    "BAZAAR",   "Beastmaster's Whistle: Lunar Tracker",        "Interface\\Icons\\Ability_Hunter_BeastCall" },
	{ 100475,   2400,  "BOE",    "BAZAAR",   "Soulbringer Staff",                           "Interface\\Icons\\inv_staff_2h_spirit_d_01_purple" },
	{ 78448,    2500,  "BOE",    "BAZAAR",   "Blackhorn's Mighty Bulwark (Red)",            "Interface\\Icons\\inv_shield_deathwingraid_d_02" },
	{ 113966,   2500,  "BOE",    "BAZAAR",   "Gar'an's Brutal Spearlauncher",               "Interface\\Icons\\inv_firearm_2h_rifle_draenorraid_d_01" },
	{ 105006,   2500,  "BOE",    "BAZAAR",   "Seismic Bore (Green)",                        "Interface\\Icons\\inv_mace_1h_orgrimmarraid_d_04" },
	{ 165030,   2500,  "BOE",    "BAZAAR",   "Sinister Gladiator's Greatsword",             "Interface\\Icons\\inv_sword_2h_warfrontsforsaken_d_01" },
	{ 124380,   2800,  "BOE",    "BAZAAR",   "Spur of the Great Devourer",                  "Interface\\Icons\\inv_staff_2h_felfireraid_d_01" },
	{ 10431,    3000,  "BOE",    "BAZAAR",   "Goblin-Gougers Gyrator",                      "Interface\\Icons\\INV_Chest_Awakening" },
	{ 111654,   3000,  "BOE",    "BAZAAR",   "Legion's Doom (Green)",                       "Interface\\Icons\\inv_offhand_1h_artifactdoomhammer_d_03" },
	{ 111073,   3000,  "BOE",    "BAZAAR",   "Primal Gladiator's Heavy Crossbow (Red)",     "Interface\\Icons\\inv_bow_2h_crossbow_pvpdraenors1_d_01" },
	{ 274472,   3200,  "BOU",    "BAZAAR",   "Azure Junkwalker's Set Cache",                "Interface\\Icons\\INV_Chest_Awakening" },
	{ 574522,   3200,  "BOE",    "BAZAAR",   "Dream Raider's Shadowflame Trident",          "Interface\\Icons\\inv_staff_2h_emeralddreamraid_d_01_dark" },
	{ 734421,   3200,  "BOU",    "BAZAAR",   "Grove Guardians Set Cache",                   "Interface\\Icons\\INV_Chest_Awakening" },
	{ 199157,   3200,  "BOU",    "BAZAAR",   "Reins of the Savage Armored Growler",         "Interface\\Icons\\inv_blue_hyena2goblinmount" },
	{ 145339,   3200,  "BOU",    "BAZAAR",   "Twilight Radiant Lightbringer Scaled Armorset", "Interface\\Icons\\INV_Chest_Awakening" },
	{ 110882,   3500,  "BOE",    "BAZAAR",   "Guardian's Focus (Red)",                      "Interface\\Icons\\inv_staff_2h_artifactantonidas_d_02" },
	{ 106236,   3500,  "BOE",    "BAZAAR",   "Strom'kar, the Warbreaker (Red)",             "Interface\\Icons\\inv_sword_2h_artifactarathor_d_01" },
	{ 499483,   3500,  "BOU",    "BAZAAR",   "Witchwood Stag (White)",                      "Interface\\Icons\\inv_ardenwealdstagmount2_white" },
	{ 274438,   4000,  "BOU",    "BAZAAR",   "Azure Shredder Tank",                         "Interface\\Icons\\blue_inv_goblinspidertank" },
	{ 281707,   4000,  "BOU",    "BAZAAR",   "Blessed Seraph's Radiance",                   "Interface\\Icons\\INV_Chest_Awakening" },
	{ 444094,   4000,  "BOU",    "BAZAAR",   "Cache of the Voidstar Ascendant",             "Interface\\Icons\\INV_Chest_Awakening" },
	{ 574512,   4000,  "BOE",    "BAZAAR",   "Dream Raider's Emerald Poleaxe",              "Interface\\Icons\\inv_staff_2h_emeralddreamraid_d_03_turquoise" },
	{ 291914,   4000,  "BOU",    "BAZAAR",   "Emberwing Sky Guide",                         "Interface\\Icons\\inv_dwarfgryphonmount_red" },
	{ 487318,   4000,  "BOU",    "BAZAAR",   "Heartfire Sentinel's Platinum Authority",     "Interface\\Icons\\INV_Chest_Awakening" },
	{ 107524,   4000,  "BOE",    "BAZAAR",   "Touch of Undeath (Purple)",                   "Interface\\Icons\\inv_axe_2h_artifactmaw_d_06" },
	{ 192632,   4800,  "BOU",    "BAZAAR",   "Ochre Dreamtalon's Reins",                    "Interface\\Icons\\inv_sabretoothraptormount_green" },
	{ 1179003,  7500,  "BOU",    "BAZAAR",   "Summoner's Stone: Shadowflame Terrorwalker",  "Interface\\Icons\\inv_misc_uncutgemnormal1" },
	{ 696664,   60,    "NONE",   "CONSUM",   "Keeper's Scroll: Aggramar",                   "Interface\\Icons\\inv_misc_scrollrolled02c" },
	{ 696665,   60,    "NONE",   "CONSUM",   "Keeper's Scroll: Eonar",                      "Interface\\Icons\\inv_misc_scrollrolled02c" },
	{ 1179261,  60,    "NONE",   "CONSUM",   "Keeper's Scroll: Featherfall",                "Interface\\Icons\\custom_feather_b_01_Border" },
	{ 696661,   60,    "NONE",   "CONSUM",   "Keeper's Scroll: Golganneth",                 "Interface\\Icons\\inv_misc_scrollrolled02c" },
	{ 696663,   60,    "NONE",   "CONSUM",   "Keeper's Scroll: Khaz'goroth",                "Interface\\Icons\\inv_misc_scrollrolled02c" },
	{ 696662,   60,    "NONE",   "CONSUM",   "Keeper's Scroll: Norgannon",                  "Interface\\Icons\\inv_misc_scrollrolled02c" },
	{ 1179266,  75,    "NONE",   "CONSUM",   "Keeper's Scroll: Ghost Runner",               "Interface\\Icons\\nhi_magicspeed_Border" },
	{ 1179269,  100,   "NONE",   "CONSUM",   "Keeper's Scroll: Crafting Speed",             "Interface\\Icons\\inv_inscription_80_warscroll_fortitude" },
	{ 1179240,  100,   "NONE",   "CONSUM",   "Keeper's Scroll: Steadfast",                  "Interface\\Icons\\nhi_magicspeed_Border" },
	{ 1179126,  150,   "NONE",   "CONSUM",   "Keeper's Scroll: Ancient Enchanting Altar",   "Interface\\Icons\\INV_Scroll_01" },
	{ 1179267,  250,   "NONE",   "CONSUM",   "Keeper's Scroll: Celebrate",                  "Interface\\Icons\\inv_helm_misc_fireworkpartyhat" },
	{ 818046,   35,    "NONE",   "CONV",     "Potion of Experience",                        "Interface\\Icons\\INV_Potion_26" },
	{ 818047,   35,    "NONE",   "CONV",     "Potion of Reputation",                        "Interface\\Icons\\INV_Potion_95" },
	{ 505002,   35,    "REALM",  "CONV",     "Pristine Pouch",                              "Interface\\Icons\\INV_Misc_Bag_22" },
	{ 101257,   50,    "BOP",    "CONV",     "Scroll of Defense: Ashenvale",                "Interface\\Icons\\INV_Scroll_03" },
	{ 101258,   50,    "BOP",    "CONV",     "Scroll of Defense: Hillsbrad Foothills",      "Interface\\Icons\\INV_Scroll_03" },
	{ 3001006,  100,   "NONE",   "CONV",     "Riding Tome: Apprentice Riding",              "Interface\\Icons\\INV_Misc_Book_07" },
	{ 910201,   150,   "NONE",   "CONV",     "Customization Potion",                        "Interface\\Icons\\INV_Alchemy_Elixir_03" },
	{ 818059,   250,   "NONE",   "CONV",     "Aura of Experience",                          "Interface\\Icons\\xpbonus_icon" },
	{ 200001,   250,   "NONE",   "CONV",     "Race Change Potion",                          "Interface\\Icons\\INV_Alchemy_Elixir_05" },
	{ 106955,   250,   "NONE",   "CONV",     "Tome of Specialization II",                   "Interface\\Icons\\inv_custom_SpecTome" },
	{ 106956,   300,   "NONE",   "CONV",     "Tome of Specialization III",                  "Interface\\Icons\\inv_custom_SpecTome" },
	{ 750750,   350,   "BOU",    "CONV",     "Book of Artisans",                            "Interface\\Icons\\inv_custom_trainerBook" },
	{ 98457,    350,   "BOU",    "CONV",     "Book of Ascension",                           "Interface\\Icons\\inv_custom_trainerBook" },
	{ 505003,   350,   "REALM",  "CONV",     "Heroes' Satchel",                             "Interface\\Icons\\INV_Misc_Bag_26_Spellfire" },
	{ 106957,   400,   "NONE",   "CONV",     "Tome of Specialization IV",                   "Interface\\Icons\\inv_custom_SpecTome" },
	{ 3211009,  475,   "NONE",   "CONV",     "Riding Tome: Expert Riding",                  "Interface\\Icons\\INV_Misc_Book_07" },
	{ 818061,   500,   "NONE",   "CONV",     "Aura of Reputation",                          "Interface\\Icons\\Achievement_Reputation_06" },
	{ 97871,    500,   "NONE",   "CONV",     "Craftsman's Codex",                           "Interface\\Icons\\inv_artifact_tome02" },
	{ 1777064,  500,   "BOU",    "CONV",     "Portable Sawmill",                            "Interface\\Icons\\custom_saw_b_01_Border" },
	{ 3001005,  500,   "NONE",   "CONV",     "Riding Tome: Journeyman Riding",              "Interface\\Icons\\INV_Misc_Book_07" },
	{ 1777028,  500,   "BOU",    "CONV",     "Thermal Anvil",                               "Interface\\Icons\\trade_blacksmithing" },
	{ 106958,   500,   "NONE",   "CONV",     "Tome of Specialization V",                    "Interface\\Icons\\inv_custom_SpecTome" },
	{ 777998,   500,   "NONE",   "CONV",     "Tradesman's Scroll",                          "Interface\\Icons\\inv_inscription_80_scroll" },
	{ 43345,    600,   "REALM",  "CONV",     "Dragon Hide Bag",                             "Interface\\Icons\\INV_Misc_Bag_26_Spellfire" },
	{ 910200,   600,   "NONE",   "CONV",     "Faction Change Potion",                       "Interface\\Icons\\INV_Alchemy_Elixir_06" },
	{ 1004003,  700,   "BOE",    "CONV",     "Alchemist's Hat",                             "Interface\\Icons\\INV_Helmet_30" },
	{ 898070,   700,   "BOU",    "CONV",     "Battle Horn",                                 "Interface\\Icons\\INV_Misc_Horn_01" },
	{ 1004004,  700,   "BOE",    "CONV",     "Blacksmith's Hat",                            "Interface\\Icons\\INV_Helmet_25" },
	{ 1004017,  700,   "BOE",    "CONV",     "Chef's Hat",                                  "Interface\\Icons\\achievement_profession_chefhat" },
	{ 1004006,  700,   "BOE",    "CONV",     "Enchanter's Hat",                             "Interface\\Icons\\INV_Helmet_11" },
	{ 1004007,  700,   "BOE",    "CONV",     "Engineer's Goggles",                          "Interface\\Icons\\INV_Helmet_47" },
	{ 1004014,  700,   "BOE",    "CONV",     "Field Medic's Hat",                           "Interface\\Icons\\inv_helmet_64" },
	{ 1004000,  700,   "BOE",    "CONV",     "Herbalist's Hat",                             "Interface\\Icons\\INV_Helmet_24" },
	{ 1004012,  700,   "BOE",    "CONV",     "Leatherworker's Hat",                         "Interface\\Icons\\INV_Helmet_51" },
	{ 1004001,  700,   "BOE",    "CONV",     "Miner's Hat",                                 "Interface\\Icons\\INV_Helmet_25" },
	{ 1004002,  700,   "BOE",    "CONV",     "Skinner's Hat",                               "Interface\\Icons\\INV_Helmet_04" },
	{ 1004013,  700,   "BOE",    "CONV",     "Tailor's Hat",                                "Interface\\Icons\\INV_Helmet_29" },
	{ 106959,   700,   "NONE",   "CONV",     "Tome of Specialization VI",                   "Interface\\Icons\\inv_custom_SpecTome" },
	{ 1004036,  800,   "REALM",  "CONV",     "Ironweave Bag",                               "Interface\\Icons\\INV_Misc_Bag_26_Spellfire" },
	{ 57000,    800,   "BOU",    "CONV",     "Lootbot 3000",                                "Interface\\Icons\\inv_pet_lilsmoky" },
	{ 101169,   800,   "BOU",    "CONV",     "Wondrous Wisdomball",                         "Interface\\Icons\\quest_khadgar" },
	{ 1004040,  1500,  "REALM",  "CONV",     "Mekkatorque's Neverending Storage Contraption", "Interface\\Icons\\INV_Gizmo_GoblinBoomBox_01" },
	{ 1179243,  1500,  "NONE",   "CONV",     "Riding Tome: Extraordinary Riding",           "Interface\\Icons\\INV_Misc_Book_07" },
	{ 106960,   1500,  "NONE",   "CONV",     "Tome of Specialization VII",                  "Interface\\Icons\\inv_custom_SpecTome" },
	{ 190190,   1600,  "BOU",    "CONV",     "Loot-Transfigurator 5000",                    "Interface\\Icons\\inv_eng_interdimensionalcompanionrepository" },
	{ 97332,    2000,  "NONE",   "CONV",     "Master's Tome Of Specialization (8-20)",      "Interface\\Icons\\inv_custom_SpecTome" },
	{ 1642992,  500,   "REALM",  "HEIRLOOM", "Discerning Eye of the Beast",                 "Interface\\Icons\\INV_Jewelry_Talisman_08" },
	{ 1644098,  500,   "REALM",  "HEIRLOOM", "Inherited Insignia of the Alliance",          "Interface\\Icons\\INV_Jewelry_TrinketPVP_01" },
	{ 1644097,  500,   "REALM",  "HEIRLOOM", "Inherited Insignia of the Horde",             "Interface\\Icons\\INV_Jewelry_TrinketPVP_02" },
	{ 1642991,  500,   "REALM",  "HEIRLOOM", "Swift Hand of Justice",                       "Interface\\Icons\\INV_Jewelry_Talisman_01" },
	{ 1644102,  600,   "REALM",  "HEIRLOOM", "Aged Pauldrons of The Five Thunders",         "Interface\\Icons\\INV_Shoulder_29" },
	{ 1642944,  600,   "REALM",  "HEIRLOOM", "Balanced Heartseeker",                        "Interface\\Icons\\INV_Sword_17" },
	{ 1644096,  600,   "REALM",  "HEIRLOOM", "Battleworn Thrash Blade",                     "Interface\\Icons\\INV_Sword_36" },
	{ 3142949,  600,   "REALM",  "HEIRLOOM", "Burnished Spaulders of Might",                "Interface\\Icons\\INV_Shoulder_29" },
	{ 1642950,  600,   "REALM",  "HEIRLOOM", "Champion Herod's Shoulder",                   "Interface\\Icons\\INV_Shoulder_01" },
	{ 1642948,  600,   "REALM",  "HEIRLOOM", "Devout Aurastone Hammer",                     "Interface\\Icons\\INV_Hammer_05" },
	{ 1642896,  600,   "REALM",  "HEIRLOOM", "Druid Idol of Agility",                       "Interface\\Icons\\Ability_Druid_HealingInstincts" },
	{ 1642897,  600,   "REALM",  "HEIRLOOM", "Druid Idol of Spells",                        "Interface\\Icons\\Spell_Arcane_Arcane03" },
	{ 1644103,  600,   "REALM",  "HEIRLOOM", "Exceptional Stormshroud Shoulders",           "Interface\\Icons\\INV_Shoulder_05" },
	{ 1644107,  600,   "REALM",  "HEIRLOOM", "Exquisite Sunderseer Mantle",                 "Interface\\Icons\\INV_Shoulder_02" },
	{ 1644105,  600,   "REALM",  "HEIRLOOM", "Lasting Feralheart Spaulders",                "Interface\\Icons\\INV_Shoulder_01" },
	{ 1642951,  600,   "REALM",  "HEIRLOOM", "Mystical Pauldrons of Elements",              "Interface\\Icons\\INV_Shoulder_29" },
	{ 1642901,  600,   "REALM",  "HEIRLOOM", "Paladin Libram of Healing",                   "Interface\\Icons\\INV_Relics_LibramofTruth" },
	{ 1642900,  600,   "REALM",  "HEIRLOOM", "Paladin Libram of Strength",                  "Interface\\Icons\\INV_Misc_StoneTablet_05" },
	{ 3148335,  600,   "REALM",  "HEIRLOOM", "Polished Observer's Shield",                  "Interface\\Icons\\INV_Shield_13" },
	{ 1642949,  600,   "REALM",  "HEIRLOOM", "Polished Spaulders of Valor",                 "Interface\\Icons\\INV_Shoulder_30" },
	{ 1642984,  600,   "REALM",  "HEIRLOOM", "Preened Ironfeather Shoulders",               "Interface\\Icons\\inv_shoulder_15" },
	{ 1644100,  600,   "REALM",  "HEIRLOOM", "Pristine Lightforge Spaulders",               "Interface\\Icons\\INV_Shoulder_10" },
	{ 1644101,  600,   "REALM",  "HEIRLOOM", "Prized Beastmaster's Mantle",                 "Interface\\Icons\\INV_Shoulder_10" },
	{ 1518202,  600,   "REALM",  "HEIRLOOM", "Rethreaded Left Bear Claw",                   "Interface\\Icons\\INV_Misc_MonsterClaw_04" },
	{ 1518203,  600,   "REALM",  "HEIRLOOM", "Rethreaded Right Bear Claw",                  "Interface\\Icons\\INV_Misc_MonsterClaw_04" },
	{ 1642898,  600,   "REALM",  "HEIRLOOM", "Shaman Totem of Agility",                     "Interface\\Icons\\Spell_unused" },
	{ 1642899,  600,   "REALM",  "HEIRLOOM", "Shaman Totem of Spells",                      "Interface\\Icons\\Spell_Nature_SlowingTotem" },
	{ 1644091,  600,   "REALM",  "HEIRLOOM", "Sharpened Scarlet Kris",                      "Interface\\Icons\\INV_Weapon_ShortBlade_03" },
	{ 1642952,  600,   "REALM",  "HEIRLOOM", "Stained Shadowcraft Spaulders",               "Interface\\Icons\\INV_Shoulder_07" },
	{ 1644099,  600,   "REALM",  "HEIRLOOM", "Strengthened Stockade Pauldrons",             "Interface\\Icons\\INV_Shoulder_20" },
	{ 1642985,  600,   "REALM",  "HEIRLOOM", "Tattered Dreadmist Mantle",                   "Interface\\Icons\\INV_Misc_Bone_TaurenSkull_01" },
	{ 1644094,  600,   "REALM",  "HEIRLOOM", "The Blessed Hammer of Grace",                 "Interface\\Icons\\INV_Hammer_07" },
	{ 1642902,  600,   "REALM",  "HEIRLOOM", "Thrown Axe of the Executioner",               "Interface\\Icons\\INV_ThrowingAxe_06" },
	{ 3140350,  600,   "REALM",  "HEIRLOOM", "Urn of Aspiring Light",                       "Interface\\Icons\\INV_Offhand_Naxxramas_04" },
	{ 1642945,  600,   "REALM",  "HEIRLOOM", "Venerable Dal'Rend's Sacred Charge",          "Interface\\Icons\\INV_Sword_43" },
	{ 1648716,  600,   "REALM",  "HEIRLOOM", "Venerable Mass of McGowan",                   "Interface\\Icons\\INV_Hammer_17" },
	{ 1642999,  800,   "REALM",  "HEIRLOOM", "Ancient Crossbow",                            "Interface\\Icons\\INV_Weapon_Crossbow_12" },
	{ 1642943,  800,   "REALM",  "HEIRLOOM", "Bloodied Arcanite Reaper",                    "Interface\\Icons\\inv_axe_09" },
	{ 3148685,  800,   "REALM",  "HEIRLOOM", "Burnished Breastplate of Might",              "Interface\\Icons\\INV_Chest_Plate16" },
	{ 1648677,  800,   "REALM",  "HEIRLOOM", "Champion's Deathdealer Breastplate",          "Interface\\Icons\\INV_Chest_Chain_07" },
	{ 1642946,  800,   "REALM",  "HEIRLOOM", "Charmed Ancient Bone Bow",                    "Interface\\Icons\\INV_Weapon_Bow_08" },
	{ 1642947,  800,   "REALM",  "HEIRLOOM", "Dignified Headmaster's Charge",               "Interface\\Icons\\INV_Jewelry_Talisman_12" },
	{ 1644095,  800,   "REALM",  "HEIRLOOM", "Grand Staff of Jordan",                       "Interface\\Icons\\INV_Staff_13" },
	{ 1648683,  800,   "REALM",  "HEIRLOOM", "Mystical Vest of Elements",                   "Interface\\Icons\\INV_Chest_Chain_11" },
	{ 1648685,  800,   "REALM",  "HEIRLOOM", "Polished Breastplate of Valor",               "Interface\\Icons\\INV_Chest_Plate03" },
	{ 1648687,  800,   "REALM",  "HEIRLOOM", "Preened Ironfeather Breastplate",             "Interface\\Icons\\inv_chest_chain_13" },
	{ 1644092,  800,   "REALM",  "HEIRLOOM", "Reforged Truesilver Champion",                "Interface\\Icons\\INV_Sword_19" },
	{ 1648718,  800,   "REALM",  "HEIRLOOM", "Repurposed Lava Dredger",                     "Interface\\Icons\\INV_Gizmo_02" },
	{ 1648689,  800,   "REALM",  "HEIRLOOM", "Stained Shadowcraft Tunic",                   "Interface\\Icons\\INV_Chest_Leather_07" },
	{ 3142943,  800,   "REALM",  "HEIRLOOM", "Sturdied Arcanite Spear",                     "Interface\\Icons\\INV_Weapon_Halberd15" },
	{ 1648691,  800,   "REALM",  "HEIRLOOM", "Tattered Dreadmist Robe",                     "Interface\\Icons\\INV_Chest_Cloth_49" },
	{ 1644093,  800,   "REALM",  "HEIRLOOM", "Upgraded Dwarven Hand Cannon",                "Interface\\Icons\\INV_Weapon_Rifle_09" },
	{ 1642846,  800,   "REALM",  "HEIRLOOM", "Wand of the Forgotten Lich",                  "Interface\\Icons\\inv_wand_1h_cataclysm_c_03" },
	{ 777903,   125,   "BOP",    "MYSTERY",  "Ethereal Box of Banners",                     "Interface\\Icons\\INV_Chest_Awakening" },
	{ 777900,   125,   "BOP",    "MYSTERY",  "Ethereal Box of Wares",                       "Interface\\Icons\\inv_legion_chest_courtoffarnodis" },
	{ 1777036,  350,   "BOU",    "STONES",   "Stone of Retreat: Aerie Peak",                "Interface\\Icons\\inv_item_stonea" },
	{ 1780058,  350,   "BOU",    "STONES",   "Stone of Retreat: Ambermill",                 "Interface\\Icons\\inv_item_stonea" },
	{ 1780026,  350,   "BOU",    "STONES",   "Stone of Retreat: Astranaar",                 "Interface\\Icons\\inv_item_stonea" },
	{ 1780024,  350,   "BOU",    "STONES",   "Stone of Retreat: Auberdine",                 "Interface\\Icons\\inv_item_stonea" },
	{ 777023,   350,   "BOU",    "STONES",   "Stone of Retreat: Azshara",                   "Interface\\Icons\\inv_item_stonen" },
	{ 1780055,  350,   "BOU",    "STONES",   "Stone of Retreat: Bloodhoof Village",         "Interface\\Icons\\inv_item_stoneh" },
	{ 777021,   350,   "BOU",    "STONES",   "Stone of Retreat: Bloodvenom Post",           "Interface\\Icons\\inv_item_stonen" },
	{ 777008,   350,   "BOU",    "STONES",   "Stone of Retreat: Booty Bay",                 "Interface\\Icons\\inv_item_stonen" },
	{ 1780014,  350,   "BOU",    "STONES",   "Stone of Retreat: Brackenwall Village",       "Interface\\Icons\\inv_item_stoneh" },
	{ 1780050,  350,   "BOU",    "STONES",   "Stone of Retreat: Brill",                     "Interface\\Icons\\inv_item_stoneh" },
	{ 1777024,  350,   "BOU",    "STONES",   "Stone of Retreat: Camp Mojache",              "Interface\\Icons\\inv_item_stoneh" },
	{ 1780015,  350,   "BOU",    "STONES",   "Stone of Retreat: Camp Taurajo",              "Interface\\Icons\\inv_item_stoneh" },
	{ 777013,   350,   "BOU",    "STONES",   "Stone of Retreat: Cenarion Hold",             "Interface\\Icons\\inv_item_stonen" },
	{ 1880049,  350,   "BOU",    "STONES",   "Stone of Retreat: Chillwind Camp",            "Interface\\Icons\\inv_item_stonea" },
	{ 1780030,  350,   "BOU",    "STONES",   "Stone of Retreat: Darkshire",                 "Interface\\Icons\\inv_item_stonea" },
	{ 777004,   350,   "BOU",    "STONES",   "Stone of Retreat: Darnassus",                 "Interface\\Icons\\inv_item_stonea" },
	{ 1780052,  350,   "BOU",    "STONES",   "Stone of Retreat: Dolanaar",                  "Interface\\Icons\\inv_item_stonea" },
	{ 1780031,  350,   "BOU",    "STONES",   "Stone of Retreat: Eastvale Logging Camp",     "Interface\\Icons\\inv_item_stonea" },
	{ 1780023,  350,   "BOU",    "STONES",   "Stone of Retreat: Emerald Sanctuary",         "Interface\\Icons\\inv_item_stonen" },
	{ 777007,   350,   "BOU",    "STONES",   "Stone of Retreat: Everlook",                  "Interface\\Icons\\inv_item_stonen" },
	{ 1780045,  350,   "BOU",    "STONES",   "Stone of Retreat: Faldir's Cove",             "Interface\\Icons\\inv_item_stonen" },
	{ 1780040,  350,   "BOU",    "STONES",   "Stone of Retreat: Farstrider Lodge",          "Interface\\Icons\\inv_item_stonea" },
	{ 1777025,  350,   "BOU",    "STONES",   "Stone of Retreat: Feathermoon Stronghold",    "Interface\\Icons\\inv_item_stonea" },
	{ 1780056,  350,   "BOU",    "STONES",   "Stone of Retreat: Flame Crest",               "Interface\\Icons\\inv_item_stoneh" },
	{ 1780027,  350,   "BOU",    "STONES",   "Stone of Retreat: Forest Song",               "Interface\\Icons\\inv_item_stonea" },
	{ 1780012,  350,   "BOU",    "STONES",   "Stone of Retreat: Freewind Post",             "Interface\\Icons\\inv_item_stoneh" },
	{ 777009,   350,   "BOU",    "STONES",   "Stone of Retreat: Gadgetzan",                 "Interface\\Icons\\inv_item_stonen" },
	{ 1780020,  350,   "BOU",    "STONES",   "Stone of Retreat: Ghost Walker's Post",       "Interface\\Icons\\inv_item_stoneh" },
	{ 1780033,  350,   "BOU",    "STONES",   "Stone of Retreat: Grom'gol Basecamp",         "Interface\\Icons\\inv_item_stoneh" },
	{ 1780025,  350,   "BOU",    "STONES",   "Stone of Retreat: Grove of the Ancients",     "Interface\\Icons\\inv_item_stonea" },
	{ 777020,   350,   "BOU",    "STONES",   "Stone of Retreat: Gurubashi Arena",           "Interface\\Icons\\inv_item_stonen" },
	{ 1780044,  350,   "BOU",    "STONES",   "Stone of Retreat: Hammerfall",                "Interface\\Icons\\inv_item_stoneh" },
	{ 1780039,  350,   "BOU",    "STONES",   "Stone of Retreat: Hammertoe Digsite",         "Interface\\Icons\\inv_item_stonea" },
	{ 777005,   350,   "BOU",    "STONES",   "Stone of Retreat: Ironforge",                 "Interface\\Icons\\inv_item_stonea" },
	{ 777031,   350,   "BOU",    "STONES",   "Stone of Retreat: Karazhan",                  "Interface\\Icons\\inv_item_stonen" },
	{ 1780038,  350,   "BOU",    "STONES",   "Stone of Retreat: Kargath",                   "Interface\\Icons\\inv_item_stoneh" },
	{ 1780049,  350,   "BOU",    "STONES",   "Stone of Retreat: Kharanos",                  "Interface\\Icons\\inv_item_stonea" },
	{ 1780036,  350,   "BOU",    "STONES",   "Stone of Retreat: Lakeshire",                 "Interface\\Icons\\inv_item_stonea" },
	{ 777006,   350,   "BOU",    "STONES",   "Stone of Retreat: Light's Hope",              "Interface\\Icons\\inv_item_stonen" },
	{ 1780010,  350,   "BOU",    "STONES",   "Stone of Retreat: Marshal's Refuge",          "Interface\\Icons\\inv_item_stonen" },
	{ 1780042,  350,   "BOU",    "STONES",   "Stone of Retreat: Menethil Harbor",           "Interface\\Icons\\inv_item_stonea" },
	{ 1780017,  350,   "BOU",    "STONES",   "Stone of Retreat: Mor'shan Base Camp",        "Interface\\Icons\\inv_item_stoneh" },
	{ 1780037,  350,   "BOU",    "STONES",   "Stone of Retreat: Morgan's Vigil",            "Interface\\Icons\\inv_item_stonea" },
	{ 777012,   350,   "BOU",    "STONES",   "Stone of Retreat: Mudsprocket",               "Interface\\Icons\\inv_item_stonen" },
	{ 1780035,  350,   "BOU",    "STONES",   "Stone of Retreat: Nesingwary's Expedition",   "Interface\\Icons\\inv_item_stonen" },
	{ 1777026,  350,   "BOU",    "STONES",   "Stone of Retreat: Nethergarde Keep",          "Interface\\Icons\\inv_item_stonea" },
	{ 1777044,  350,   "BOU",    "STONES",   "Stone of Retreat: Nijel's Point",             "Interface\\Icons\\inv_item_stonea" },
	{ 777010,   350,   "BOU",    "STONES",   "Stone of Retreat: Ratchet",                   "Interface\\Icons\\inv_item_stonen" },
	{ 1780034,  350,   "BOU",    "STONES",   "Stone of Retreat: Rebel Camp",                "Interface\\Icons\\inv_item_stonea" },
	{ 1780043,  350,   "BOU",    "STONES",   "Stone of Retreat: Refuge Point",              "Interface\\Icons\\inv_item_stonea" },
	{ 1777037,  350,   "BOU",    "STONES",   "Stone of Retreat: Revantusk Village",         "Interface\\Icons\\inv_item_stoneh" },
	{ 1780053,  350,   "BOU",    "STONES",   "Stone of Retreat: Sen'jin Village",           "Interface\\Icons\\inv_item_stoneh" },
	{ 1780032,  350,   "BOU",    "STONES",   "Stone of Retreat: Sentinel Hill",             "Interface\\Icons\\inv_item_stonea" },
	{ 1777043,  350,   "BOU",    "STONES",   "Stone of Retreat: Shadowprey Village",        "Interface\\Icons\\inv_item_stoneh" },
	{ 1780046,  350,   "BOU",    "STONES",   "Stone of Retreat: Southshore",                "Interface\\Icons\\inv_item_stonea" },
	{ 1780028,  350,   "BOU",    "STONES",   "Stone of Retreat: Splintertree Post",         "Interface\\Icons\\inv_item_stoneh" },
	{ 1777027,  350,   "BOU",    "STONES",   "Stone of Retreat: Stonard",                   "Interface\\Icons\\inv_item_stoneh" },
	{ 1780019,  350,   "BOU",    "STONES",   "Stone of Retreat: Stonetalon Peak",           "Interface\\Icons\\inv_item_stonea" },
	{ 1780018,  350,   "BOU",    "STONES",   "Stone of Retreat: Sun Rock Retreat",          "Interface\\Icons\\inv_item_stoneh" },
	{ 1880047,  350,   "BOU",    "STONES",   "Stone of Retreat: Talonbranch Glade",         "Interface\\Icons\\inv_item_stonea" },
	{ 1780021,  350,   "BOU",    "STONES",   "Stone of Retreat: Talrendis Point",           "Interface\\Icons\\inv_item_stonea" },
	{ 1780047,  350,   "BOU",    "STONES",   "Stone of Retreat: Tarren Mill",               "Interface\\Icons\\inv_item_stoneh" },
	{ 1780011,  350,   "BOU",    "STONES",   "Stone of Retreat: Thalanaar",                 "Interface\\Icons\\inv_item_stonea" },
	{ 1780059,  350,   "BOU",    "STONES",   "Stone of Retreat: The Bulwark",               "Interface\\Icons\\inv_item_stoneh" },
	{ 1780016,  350,   "BOU",    "STONES",   "Stone of Retreat: The Crossroads",            "Interface\\Icons\\inv_item_stoneh" },
	{ 1780057,  350,   "BOU",    "STONES",   "Stone of Retreat: The Harborage",             "Interface\\Icons\\inv_item_stonea" },
	{ 1780048,  350,   "BOU",    "STONES",   "Stone of Retreat: The Sepulcher",             "Interface\\Icons\\inv_item_stoneh" },
	{ 1780041,  350,   "BOU",    "STONES",   "Stone of Retreat: Thelsamar",                 "Interface\\Icons\\inv_item_stonea" },
	{ 1780013,  350,   "BOU",    "STONES",   "Stone of Retreat: Theramore Isle",            "Interface\\Icons\\inv_item_stonea" },
	{ 777011,   350,   "BOU",    "STONES",   "Stone of Retreat: Thorium Point",             "Interface\\Icons\\inv_item_stonen" },
	{ 777002,   350,   "BOU",    "STONES",   "Stone of Retreat: Thunder Bluff",             "Interface\\Icons\\inv_item_stoneh" },
	{ 777001,   350,   "BOU",    "STONES",   "Stone of Retreat: Undercity",                 "Interface\\Icons\\inv_item_stoneh" },
	{ 1780022,  350,   "BOU",    "STONES",   "Stone of Retreat: Valormok",                  "Interface\\Icons\\inv_item_stoneh" },
	{ 1777023,  350,   "BOU",    "STONES",   "Stone of Retreat: Yojamba Isle",              "Interface\\Icons\\inv_item_stonen" },
	{ 1780029,  350,   "BOU",    "STONES",   "Stone of Retreat: Zoram'gar Outpost",         "Interface\\Icons\\inv_item_stoneh" },
};

-------------------------------------------------------------------------------
-- catalogue access
-------------------------------------------------------------------------------

local gBz_CatalogCache = nil;

function Atr_Bz_InvalidateCatalog ()
	gBz_CatalogCache = nil;
	if (Atr_Bz_InvalidateBridge) then Atr_Bz_InvalidateBridge (); end	-- FINDER_TAB
end

local function Bz_DB ()
	AUCTIONATOR_BAZAAR			= AUCTIONATOR_BAZAAR or {};
	AUCTIONATOR_BAZAAR.learned	= AUCTIONATOR_BAZAAR.learned or {};
	AUCTIONATOR_BAZAAR.extra	= AUCTIONATOR_BAZAAR.extra or {};
	AUCTIONATOR_BAZAAR.tokens	= AUCTIONATOR_BAZAAR.tokens or {};
	return AUCTIONATOR_BAZAAR;
end

-- merged view, keyed by itemID: seed first, learned overrides it, extras added
function Atr_Bz_GetCatalog ()

	if (gBz_CatalogCache) then return gBz_CatalogCache; end

	local db	= Bz_DB();
	local byID	= {};

	local i, rec;
	for i = 1, #ATR_BZ_SEED do
		local s = ATR_BZ_SEED[i];
		byID[s[1]] = { id = s[1], bt = s[2], bind = s[3], cat = s[4],
						name = s[5], tex = s[6], src = "seed" };
	end

	for _, rec in pairs (db.learned) do
		if (rec and rec.id) then
			byID[rec.id] = {
				id = rec.id, bt = rec.bt, bind = rec.bind, tex = rec.tex,
				cat = rec.cat, name = rec.name, src = "vendor", seen = rec.seen,
			};
		end
	end

	for i = 1, #ATR_BZ_TOKEN_ITEMS do
		local s = ATR_BZ_TOKEN_ITEMS[i];
		byID[s.id] = {
			id = s.id, bt = s.bt, bind = s.bind, cat = s.cat,
			name = s.name, tex = s.tex, src = "token",
		};
	end

	for _, rec in pairs (db.tokens or {}) do
		if (rec and rec.id) then
			byID[rec.id] = {
				id = rec.id, bt = rec.bt, bind = "NONE", cat = "TOKENS",
				name = rec.name, tex = rec.tex, src = "token",
			};
		end
	end

	for _, rec in pairs (db.extra) do
		if (rec and rec.id) then
			byID[rec.id] = {
				id = rec.id, bt = rec.bt, bind = rec.bind or "BOU",
				cat = rec.cat or "EXTRA", name = rec.name, src = "extra", note = rec.note,
			};
		end
	end

	local list = {};
	for _, rec in pairs (byID) do
		rec.tradeable = Atr_Bz_IsTradeable (rec.bind);
		list[#list + 1] = rec;
	end

	table.sort (list, function (a, b)
		if (a.cat ~= b.cat)	then return a.cat < b.cat; end
		if (a.bt ~= b.bt)	then return (a.bt or 0) < (b.bt or 0); end
		return (a.name or "") < (b.name or "");
	end);

	gBz_CatalogCache = list;
	return list;
end

-- includeBound=false hides Binds-to-realm / BoP items rather than dimming them
function Atr_Bz_ItemsInCategory (cat, includeBound)

	local out	= {};
	local list	= Atr_Bz_GetCatalog();

	local i;
	for i = 1, #list do
		local rec = list[i];
		if ((cat == nil or rec.cat == cat) and (includeBound or rec.tradeable)) then
			out[#out + 1] = rec;
		end
	end

	return out;
end

function Atr_Bz_CategoryCounts ()

	local counts	= {};
	local list		= Atr_Bz_GetCatalog();

	local i;
	for i = 1, #list do
		local rec = list[i];
		counts[rec.cat] = counts[rec.cat] or { total = 0, tradeable = 0 };
		counts[rec.cat].total = counts[rec.cat].total + 1;
		if (rec.tradeable) then
			counts[rec.cat].tradeable = counts[rec.cat].tradeable + 1;
		end
	end

	return counts;
end

-- the hand-maintained webshop-only list
function Atr_Bz_AddExtra (itemID, name, btCost, note)

	local id = tonumber (itemID);
	if (id == nil or id <= 0) then return false, BZT("need a numeric itemID"); end

	local db = Bz_DB();
	db.extra[tostring (id)] = {
		id = id, name = name or ("item:"..id),
		bt = tonumber (btCost), bind = "BOU", cat = "EXTRA", note = note,
	};

	Atr_Bz_InvalidateCatalog();
	return true;
end

function Atr_Bz_RemoveExtra (itemID)
	local db = Bz_DB();
	local key = tostring (tonumber (itemID) or "");
	if (db.extra[key] == nil) then return false; end
	db.extra[key] = nil;
	Atr_Bz_InvalidateCatalog();
	return true;
end

-------------------------------------------------------------------------------
-- the merchant harvester
--
-- Everything here encodes a Phase 0 finding.  GetMerchantNumItems returns the
-- WHOLE vendor list rather than the visible page, so one MERCHANT_SHOW per
-- gossip branch is a complete harvest.  The six branches are disjoint sets --
-- "Browse Bazaar" is not a superset -- so each must be visited.
-------------------------------------------------------------------------------

local gBz_GossipLabel	= nil;
local gBz_GossipAt		= 0;

function Atr_Bz_SetGossipContext (label)
	gBz_GossipLabel	= Atr_Bz_CleanEscapes (label);
	gBz_GossipAt	= Bz_Now();
end

-- gossip label -> category key.  Matched loosely because Ascension decorates
-- the titles ("Heirlooms (Requires a level 60)").
local function Bz_CategoryFromGossip (label)

	if (label == nil or label == "") then return nil; end
	local l = label:lower();

	if (l:find ("browse bazaar"))	then return "BAZAAR"; end
	if (l:find ("mysterious"))		then return "MYSTERY"; end
	if (l:find ("convenience"))		then return "CONV"; end
	if (l:find ("consumable"))		then return "CONSUM"; end
	if (l:find ("heirloom"))		then return "HEIRLOOM"; end
	if (l:find ("stone"))			then return "STONES"; end

	return nil;
end

local gBz_ScanTip = nil;

local function Bz_EnsureScanTip ()
	if (gBz_ScanTip) then return gBz_ScanTip; end
	if (not CreateFrame) then return nil; end
	gBz_ScanTip = CreateFrame ("GameTooltip", "Atr_BzScanTip", UIParent, "GameTooltipTemplate");
	return gBz_ScanTip;
end

-- returns the bind code for merchant slot i, read from the server tooltip
function Atr_Bz_MerchantBind (index)

	local tip = Bz_EnsureScanTip();
	if (not tip or not tip.SetMerchantItem) then return "NONE"; end

	tip:SetOwner (UIParent, "ANCHOR_NONE");
	tip:ClearLines();
	if (not pcall (tip.SetMerchantItem, tip, index)) then return "NONE"; end

	local map	= Bz_BindMap();
	local n		= tip:NumLines() or 0;

	local j;
	for j = 1, n do
		local L = _G["Atr_BzScanTipTextLeft"..j];
		local txt = L and L:GetText();
		if (txt) then
			local code = map[Atr_Bz_CleanEscapes (txt)];
			if (code) then return code; end
		end
	end

	return "NONE";
end

-- Reads one merchant slot.  Returns nil unless the slot is priced in Bazaar
-- Tokens.  The cost test is deliberately "cost1[3] is a link for item 975001"
-- and NOT "some entry in the cost tuple is non-nil": gold-priced items carry a
-- literal 0 in that tuple, which made the Phase 0 probe count Tiraxis's 27
-- ordinary weapons as token items.
function Atr_Bz_ReadMerchantSlot (index)

	if (not GetMerchantItemCostItem) then return nil; end

	local ok, tex, value, link = pcall (GetMerchantItemCostItem, index, 1);
	if (not ok or link == nil) then return nil; end

	local currencyID = tonumber (tostring (link):match ("item:(%d+)"));
	if (currencyID ~= ATR_BZ_TOKEN_ITEMID) then return nil; end

	local name, tex;
	if (GetMerchantItemInfo) then name, tex = GetMerchantItemInfo (index); end
	local ilink	= GetMerchantItemLink and GetMerchantItemLink (index);
	local itemID = ilink and tonumber (tostring (ilink):match ("item:(%d+)"));

	if (itemID == nil) then return nil; end

	return {
		id		= itemID,
		bt		= tonumber (value) or 0,
		bind	= Atr_Bz_MerchantBind (index),
		name	= name,
		tex		= tex,
	};
end

-- returns  numberStored, categoryKey, numberSkipped
function Atr_Bz_HarvestMerchant ()

	if (not GetMerchantNumItems) then return 0, nil, 0; end

	local total = GetMerchantNumItems() or 0;
	if (total == 0) then return 0, nil, 0; end

	local fresh = (gBz_GossipLabel and (Bz_Now() - gBz_GossipAt) <= 15) and gBz_GossipLabel or nil;
	local cat	= Bz_CategoryFromGossip (fresh);

	local db	= Bz_DB();
	local n, skipped = 0, 0;

	local i;
	for i = 1, total do
		local rec = Atr_Bz_ReadMerchantSlot (i);
		if (rec) then
			-- without a gossip label we still record the item, but must not
			-- guess its category: keep whatever we already knew
			local prev = db.learned[tostring (rec.id)];
			rec.cat		= cat or (prev and prev.cat) or "BAZAAR";
			rec.seen	= Bz_Now();
			db.learned[tostring (rec.id)] = rec;
			n = n + 1;
		else
			skipped = skipped + 1;
		end
	end

	if (n > 0) then Atr_Bz_InvalidateCatalog(); end

	return n, cat, skipped;
end

-------------------------------------------------------------------------------
-- events.
--
-- The merchant-open harvest and the gossip-branch context hook used to live
-- here.  They moved to AuctionatorFinderMerchant.lua, which now drives ALL
-- merchant-window scanning (this Bazaar harvest and the NPC price learner)
-- through one debounced, session-throttled event frame -- so opening a vendor
-- no longer re-walks the list on every MERCHANT_UPDATE.  It calls the two
-- globals defined above, Atr_Bz_HarvestMerchant and Atr_Bz_SetGossipContext,
-- exactly as this frame did.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- PHASE 5a: live token price from the auction house.
--
-- Bazaar Tokens are themselves an ordinary auction item, so the gold edge of
-- the rate chain can be OBSERVED rather than typed.  Three traps:
--
--   * a name query for "Bazaar Token" also returns "100 Bazaar Tokens", a
--     separate item that sells at a WORSE per-token price (72g90s per 100 =
--     72.9s each, against 59s for singles).  Including it would quietly
--     corrupt the rate, so listings are filtered by itemID 975001, never by
--     name.
--   * many token listings carry no buyout at all ("no buyout price, 13 stacks
--     of 10").  Those have no purchase price and must be skipped, not read
--     as free.
--   * price is per STACK; the rate is per token.  Divide by the stack count.
--
-- getAll is disabled on this server (see ASCENSION-CLIENT-NOTES), so this is
-- a paged scan gated on CanSendAuctionQuery, exactly like the Finder's.
-------------------------------------------------------------------------------

local BZSCAN_NULL		= 0;
local BZSCAN_PREQUERY	= 1;
local BZSCAN_POSTQUERY	= 2;

local BZSCAN_MAX_PAGES	= 10;

local gBzScan_State	= BZSCAN_NULL;
local gBzScan_Page	= 0;
local gBzScan_Best	= nil;		-- cheapest copper-per-token seen
local gBzScan_N		= 0;		-- qualifying listings counted

function Atr_Bz_TokenScanRunning ()
	return gBzScan_State ~= BZSCAN_NULL;
end

-- returns copper-per-token for auction row `index`, or nil if the listing
-- does not qualify.  Split out so it can be tested without a scan.
function Atr_Bz_ReadTokenListing (index)

	if (not GetAuctionItemInfo) then return nil; end

	local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo ("list", index);
	if (name == nil) then return nil; end

	-- bid-only listing: there is no price to read here
	if (buyout == nil or buyout <= 0) then return nil; end

	-- itemID, never name: this is what excludes "100 Bazaar Tokens"
	local link = GetAuctionItemLink and GetAuctionItemLink ("list", index);
	local id   = link and tonumber (string.match (tostring (link), "item:(%d+)"));
	if (id ~= ATR_BZ_TOKEN_ITEMID) then return nil; end

	count = count or 1;
	if (count <= 0) then return nil; end

	return buyout / count;
end

-- A search for "Bazaar Token" also returns things like "100 Bazaar Tokens".
-- Those are excluded from the rate -- that was the whole point -- but they are
-- still token prices, so they get filed under the Bazaar Tokens category where
-- their value per token can be compared against buying singles.
function Atr_Bz_LearnTokenSibling (index)

	if (not GetAuctionItemLink or not GetAuctionItemInfo) then return; end

	local link = GetAuctionItemLink ("list", index);
	local id   = link and tonumber (string.match (tostring (link), "item:(%d+)"));

	if (id == nil or id == ATR_BZ_TOKEN_ITEMID) then return; end

	local name, tex = GetAuctionItemInfo ("list", index);
	if (name == nil) then return; end

	-- a leading count in the name ("100 Bazaar Tokens") is how many tokens the
	-- item is worth.  No number, no claim: bt stays nil and the currency
	-- columns simply stay blank rather than inventing a value.
	local bt = tonumber (string.match (name, "^(%d+)%s"));

	local db = Bz_DB();
	db.tokens = db.tokens or {};
	db.tokens[tostring (id)] = { id = id, name = name, tex = tex, bt = bt };

	Atr_Bz_InvalidateCatalog();
end

function Atr_Bz_HarvestTokenPage ()

	local numBatch = GetNumAuctionItems and (GetNumAuctionItems ("list")) or 0;

	local i;
	for i = 1, numBatch do
		local per = Atr_Bz_ReadTokenListing (i);
		Atr_Bz_LearnTokenSibling (i);
		if (per) then
			gBzScan_N = gBzScan_N + 1;
			if (gBzScan_Best == nil or per < gBzScan_Best) then
				gBzScan_Best = per;
			end
		end
	end

	return numBatch;
end

function Atr_Bz_CancelTokenScan (quiet)
	local was = gBzScan_State;
	gBzScan_State	= BZSCAN_NULL;
	gBzScan_Page	= 0;
	if (was ~= BZSCAN_NULL and not quiet) then
		Atr_Bz_SetMessage (BZT("Token scan cancelled."));
	end
end

function Atr_Bz_FinishTokenScan ()

	gBzScan_State = BZSCAN_NULL;

	if (gBzScan_Best == nil) then
		Atr_Bz_SetMessage (BZT("No Bazaar Token buyouts found."));
		return false;
	end

	Atr_Bz_SetTokenRateFromAuction (gBzScan_Best, gBzScan_N);

	-- so the Bazaar Tokens category shows a price straight away
	if (Atr_Bz_RecordPrice) then
		Atr_Bz_RecordPrice (ATR_BZ_TOKEN_ITEMID, gBzScan_Best, gBzScan_N);
	end

	Atr_Bz_RefreshRateDisplay();

	Atr_Bz_SetMessage (string.format (BZT("1 BT = %s  (%d listings)"),
			Atr_Bz_MoneyString (Atr_Bz_Round (gBzScan_Best)), gBzScan_N));

	return true;
end

function Atr_Bz_StartTokenScan ()

	if (gBzScan_State ~= BZSCAN_NULL) then
		return false;
	end

	if (AuctionFrame and AuctionFrame.IsShown and not AuctionFrame:IsShown()) then
		Atr_Bz_SetMessage (BZT("Open the auction house first."));
		return false;
	end

	gBzScan_Page	= 0;
	gBzScan_Best	= nil;
	gBzScan_N		= 0;
	gBzScan_State	= BZSCAN_PREQUERY;

	Atr_Bz_SetMessage (BZT("Scanning for Bazaar Tokens..."));
	return true;
end

-- driven from OnUpdate: the query can only go out when the server lets it
function Atr_Bz_TokenScanOnUpdate ()

	if (gBzScan_State ~= BZSCAN_PREQUERY) then return; end
	if (CanSendAuctionQuery and not CanSendAuctionQuery()) then return; end
	if (not QueryAuctionItems) then Atr_Bz_CancelTokenScan (true); return; end

	gBzScan_State = BZSCAN_POSTQUERY;
	QueryAuctionItems (ATR_BZ_TOKEN_NAME, nil, nil, nil, nil, nil, gBzScan_Page, nil, nil);
end

function Atr_Bz_TokenScanOnListUpdate ()

	if (gBzScan_State ~= BZSCAN_POSTQUERY) then return; end

	local numBatch = Atr_Bz_HarvestTokenPage();

	-- a short page is the last page
	if (numBatch < 50 or gBzScan_Page + 1 >= BZSCAN_MAX_PAGES) then
		Atr_Bz_FinishTokenScan();
		return;
	end

	gBzScan_Page	= gBzScan_Page + 1;
	gBzScan_State	= BZSCAN_PREQUERY;

	Atr_Bz_SetMessage (string.format (BZT("Scanning for Bazaar Tokens... page %d"), gBzScan_Page + 1));
end

-------------------------------------------------------------------------------

if (CreateFrame) then

	local sf = CreateFrame ("Frame", "Atr_Bz_ScanFrame", UIParent);

	sf:RegisterEvent ("AUCTION_ITEM_LIST_UPDATE");
	sf:RegisterEvent ("AUCTION_HOUSE_CLOSED");

	sf:SetScript ("OnEvent", function (self, event)
		if (event == "AUCTION_HOUSE_CLOSED") then
			Atr_Bz_CancelTokenScan (true);
			if (Atr_Bz_CancelCategoryScan) then Atr_Bz_CancelCategoryScan (true); end
			if (Atr_Bz_CancelItemScan) then Atr_Bz_CancelItemScan (true); end
			return;
		end
		-- both scans ignore the event unless they are the one running, so
		-- Auctionator's own list updates pass straight through
		Atr_Bz_TokenScanOnListUpdate();
		if (Atr_Bz_ItemScanOnListUpdate) then Atr_Bz_ItemScanOnListUpdate(); end
	end);

	sf:SetScript ("OnUpdate", function ()
		Atr_Bz_TokenScanOnUpdate();
		if (Atr_Bz_ItemScanOnUpdate) then Atr_Bz_ItemScanOnUpdate(); end
	end);
end

-------------------------------------------------------------------------------
-- PHASE 5b: market price and margin.
--
-- No scanning of its own.  Auctionator already writes gAtr_ScanDB[itemName]
-- on EVERY ordinary Buy/Sell search, not just full scans, so any bazaar item
-- the player has ever looked up already has a price on disk.  Name-keying is
-- safe here for once: these are vanity and convenience goods, not the scaled
-- gear that breaks the Buy tab's data model.
--
-- Margin is what you would actually clear:
--
--     margin = (market price - auction house cut) - token cost in gold
--
-- The cut matters.  WotLK takes 5% of the buyout on a sale, so a margin that
-- ignores it is systematically optimistic on every row -- worst on exactly
-- the expensive items where a flip decision is worth most.
-------------------------------------------------------------------------------

function Atr_Bz_MarketPrice (rec)

	if (rec == nil) then return nil; end

	-- our own cache first: it is keyed by itemID, so it cannot confuse two
	-- items whose names overlap the way "Bazaar Token" and "100 Bazaar
	-- Tokens" do
	if (Atr_Bz_StoredPrice and rec.id) then
		local c = Atr_Bz_StoredPrice (rec.id);
		if (c) then return c; end
	end

	if (rec.name == nil or gAtr_ScanDB == nil) then return nil; end

	-- variant-aware read (BACKGROUND: BACKLOG item 12 part 3).  No link here, so
	-- this asks for the name's default, which is the lowest known variant --
	-- exactly the number this line showed before variants existed.
	local p = (type (Atr_PriceValue) == "function") and Atr_PriceValue (gAtr_ScanDB[rec.name]) or gAtr_ScanDB[rec.name];
	if (type (p) ~= "number" or p <= 0) then return nil; end

	return p;
end

-- returns  margin(copper or nil), market(copper or nil), cost(copper)
function Atr_Bz_Margin (rec)

	local cost = Atr_Bz_Convert (rec and rec.bt or 0, "BT", "COPPER");

	if (rec == nil or not rec.tradeable) then
		return nil, nil, cost;
	end

	local market = Atr_Bz_MarketPrice (rec);
	if (market == nil) then
		return nil, nil, cost;
	end

	local r	  = Atr_Bz_GetRates();
	local cut = (tonumber (r.ahCutPct) or 0) / 100;
	local net = market * (1 - cut);

	return Atr_Bz_Round (net - cost), market, cost;
end

-- uncoloured, so a caller can wrap the whole string in one colour
function Atr_Bz_PlainMoneyString (copper)

	copper = Atr_Bz_Round (math.abs (copper or 0));

	local gold	 = math.floor (copper / 10000);
	local silver = math.floor ((copper % 10000) / 100);
	local cop	 = copper % 100;

	if (gold > 0)	then return string.format ("%dg %02ds", gold, silver); end
	if (silver > 0)	then return string.format ("%ds %02dc", silver, cop); end
	return string.format ("%dc", cop);
end

-- Colour reads the column as a BUYING signal, not a flipping one: negative
-- means the auction house is undercutting the vendor, which is the good case
-- for a buyer, so it shows green.  Positive is red.  Note this is the reverse
-- of the usual profit-is-green convention -- deliberate, see the header hint.
-- {r,g,b} -> "|cffRRGGBB", so the legend and the cells share one definition
function Atr_Bz_ColourCode (c)
	return string.format ("|cff%02x%02x%02x",
			Atr_Bz_Round ((c[1] or 1) * 255),
			Atr_Bz_Round ((c[2] or 1) * 255),
			Atr_Bz_Round ((c[3] or 1) * 255));
end

function Atr_Bz_MarginString (delta)

	if (delta == nil) then return "|cff888888--|r"; end
	if (delta == 0) then return "|cffaaaaaa0|r"; end

	if (delta > 0) then
		return Atr_Bz_ColourCode (ATR_BZ_MARGIN_RED).."+"..Atr_Bz_PlainMoneyString (delta).."|r";
	end

	return Atr_Bz_ColourCode (ATR_BZ_MARGIN_GREEN).."-"..Atr_Bz_PlainMoneyString (delta).."|r";
end

-- how many rows in the current view actually have market data
function Atr_Bz_PricedCount (rows)

	local n = 0;
	local i;

	for i = 1, #(rows or {}) do
		if (Atr_Bz_MarketPrice (rows[i])) then n = n + 1; end
	end

	return n;
end

-------------------------------------------------------------------------------
-- PHASE 5c: one item's live listings.
--
-- Same paged-scan shape as the token price, but collecting every listing for
-- one itemID instead of just the cheapest.  Two things it must get right:
--
--   * filter by itemID, not name.  A name query for "Bazaar Token" returns
--     "100 Bazaar Tokens" too, and the same trap exists for any item whose
--     name is a prefix of another's.
--   * condense by (price per item, stack size), which is what makes the Buy
--     tab's "9 stacks of 100" line.  Listings with no buyout are kept and
--     shown as such rather than dropped -- they are still real competition.
-------------------------------------------------------------------------------

local BZITEM_NULL		= 0;
local BZITEM_PREQUERY	= 1;
local BZITEM_POSTQUERY	= 2;

local BZITEM_MAX_PAGES	= 8;

local gBzItem_State	= BZITEM_NULL;
local gBzItem_Page	= 0;
local gBzItem_Rec	= nil;
local gBzItem_Raw	= {};
local gBzItem_Silent = false;	-- driven by the category queue: no view switch

function Atr_Bz_ItemScanRunning ()
	return gBzItem_State ~= BZITEM_NULL;
end

-- One auction row, or nil if it is not the item we asked for.
-- returns  perItem(copper or nil when bid-only), count, buyout
function Atr_Bz_ReadListingAt (index, wantID)

	if (not GetAuctionItemInfo) then return nil; end

	local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo ("list", index);
	if (name == nil) then return nil; end

	local link = GetAuctionItemLink and GetAuctionItemLink ("list", index);
	local id   = link and tonumber (string.match (tostring (link), "item:(%d+)"));
	if (wantID and id ~= wantID) then return nil; end

	count = count or 1;
	if (count <= 0) then count = 1; end

	if (buyout == nil or buyout <= 0) then
		return nil, count, 0;			-- bid-only: real listing, no buyout
	end

	return buyout / count, count, buyout;
end

-- Groups identical (price per item, stack size) pairs, cheapest first, with
-- the bid-only listings collected at the end the way the Buy tab shows them.
function Atr_Bz_CondenseListings (raw)

	local keyed = {};
	local out	= {};

	local i;
	for i = 1, #(raw or {}) do

		local r		= raw[i];
		local key	= tostring (r.perItem or "nobuy").."/"..tostring (r.count);
		local slot	= keyed[key];

		if (slot == nil) then
			slot = { perItem = r.perItem, count = r.count, stacks = 0, buyout = r.buyout };
			keyed[key]	= slot;
			out[#out + 1] = slot;
		end

		slot.stacks = slot.stacks + 1;
	end

	table.sort (out, function (a, b)
		if (a.perItem == nil and b.perItem == nil) then return a.count < b.count; end
		if (a.perItem == nil) then return false; end	-- no buyout sorts last
		if (b.perItem == nil) then return true; end
		if (a.perItem ~= b.perItem) then return a.perItem < b.perItem; end
		return a.count < b.count;
	end);

	return out;
end

function Atr_Bz_CancelItemScan (quiet)
	local was = gBzItem_State;
	gBzItem_State	= BZITEM_NULL;
	gBzItem_Page	= 0;
	if (was ~= BZITEM_NULL and not quiet) then
		Atr_Bz_SetMessage (BZT("Listing scan cancelled."));
	end
end

function Atr_Bz_StartItemScan (rec, silent)

	if (rec == nil) then return false; end

	if (AuctionFrame and AuctionFrame.IsShown and not AuctionFrame:IsShown()) then
		Atr_Bz_SetMessage (BZT("Open the auction house first."));
		return false;
	end

	Atr_Bz_CancelItemScan (true);

	gBzItem_Rec		= rec;
	gBzItem_Raw		= {};
	gBzItem_Page	= 0;
	gBzItem_State	= BZITEM_PREQUERY;
	gBzItem_Silent	= silent and true or false;

	if (not gBzItem_Silent) then
		Atr_Bz_SetListings ({});
		Atr_Bz_SetMessage (BZT("Searching..."));
	end

	return true;
end

function Atr_Bz_ItemScanOnUpdate ()

	if (gBzItem_State ~= BZITEM_PREQUERY) then return; end
	if (CanSendAuctionQuery and not CanSendAuctionQuery()) then return; end
	if (not QueryAuctionItems) then Atr_Bz_CancelItemScan (true); return; end

	gBzItem_State = BZITEM_POSTQUERY;
	QueryAuctionItems (gBzItem_Rec.name, nil, nil, nil, nil, nil, gBzItem_Page, nil, nil);
end

function Atr_Bz_ItemScanHarvestPage ()

	local numBatch = GetNumAuctionItems and (GetNumAuctionItems ("list")) or 0;

	local i;
	for i = 1, numBatch do
		local perItem, count, buyout = Atr_Bz_ReadListingAt (i, gBzItem_Rec and gBzItem_Rec.id);
		if (count) then
			gBzItem_Raw[#gBzItem_Raw + 1] = { perItem = perItem, count = count, buyout = buyout };
		end
	end

	return numBatch;
end

function Atr_Bz_FinishItemScan ()

	gBzItem_State = BZITEM_NULL;

	-- Remember the cheapest per-item buyout whether or not anyone is looking:
	-- this is what makes the catalogue's AH price column fill in.
	local best = nil;
	local i;
	for i = 1, #gBzItem_Raw do
		local p = gBzItem_Raw[i].perItem;
		if (p and (best == nil or p < best)) then best = p; end
	end

	if (best and gBzItem_Rec and Atr_Bz_RecordPrice) then
		Atr_Bz_RecordPrice (gBzItem_Rec.id, best, #gBzItem_Raw);
	end

	if (gBzItem_Silent) then
		gBzItem_Silent = false;
		Atr_Bz_RefreshTable();
		if (Atr_Bz_CategoryScanNext) then Atr_Bz_CategoryScanNext(); end
		return best and 1 or 0;
	end

	local rows = Atr_Bz_CondenseListings (gBzItem_Raw);
	Atr_Bz_SetListings (rows);

	if (#rows == 0) then
		Atr_Bz_SetMessage (BZT("No auctions found for this item."));
	else
		Atr_Bz_SetMessage (string.format (BZT("%d listings"), #gBzItem_Raw));
	end

	return #rows;
end

function Atr_Bz_ItemScanOnListUpdate ()

	if (gBzItem_State ~= BZITEM_POSTQUERY) then return; end

	local numBatch = Atr_Bz_ItemScanHarvestPage();

	if (numBatch < 50 or gBzItem_Page + 1 >= BZITEM_MAX_PAGES) then
		Atr_Bz_FinishItemScan();
		return;
	end

	gBzItem_Page	= gBzItem_Page + 1;
	gBzItem_State	= BZITEM_PREQUERY;
end

-- keep the token scanner's public entry point working unchanged
function Atr_Bz_ReadTokenListing (index)
	local perItem = Atr_Bz_ReadListingAt (index, ATR_BZ_TOKEN_ITEMID);
	return perItem;
end

-------------------------------------------------------------------------------
-- PHASE 5d: remembering prices, and pricing a whole category.
--
-- Until now the catalogue's AH price column read only Auctionator's
-- gAtr_ScanDB, so drilling into an item showed you its live auctions and then
-- forgot them -- you could look at 63 listings and come back to a blank cell.
-- Every listing scan now records the cheapest per-item buyout, keyed by
-- itemID rather than by name.
--
-- itemID matters: gAtr_ScanDB is name-keyed, which is fine for these goods but
-- cannot tell "Bazaar Token" from "100 Bazaar Tokens".  Our own cache has no
-- such ambiguity, so it takes precedence and the name-keyed database stays as
-- a fallback for items we have never opened.
-------------------------------------------------------------------------------

function Atr_Bz_RecordPrice (itemID, copper, listings)

	local id = tonumber (itemID);
	local c  = tonumber (copper);

	if (id == nil or c == nil or c <= 0) then return false; end

	local db = Bz_DB();
	db.prices = db.prices or {};
	db.prices[tostring (id)] = {
		copper = Atr_Bz_Round (c),
		when   = Bz_Now(),
		n      = tonumber (listings) or 0,
	};

	-- FINDER_TAB: mirror into the name-keyed database so the base addon's
	-- tooltips show bazaar goods too.  Hooked HERE rather than at the call
	-- sites so every pricing path is covered at once.
	if (Atr_Bz_FeedPriceDB) then Atr_Bz_FeedPriceDB (id, c); end

	return true;
end

-- FINDER_TAB begin: price database bridge
--
-- The itemID-keyed store above is the Bazaar's own truth and stays that way.
-- But Auctionator's tooltips read the NAME-keyed gAtr_ScanDB, so a bazaar
-- item priced here showed nothing on its tooltip anywhere else in the game.
--
-- Bridging is safe for MOST of this catalogue but not all of it, and the
-- exception is the reason the itemID store exists: "Bazaar Token" and
-- "100 Bazaar Tokens" are different items, and a name-keyed write cannot
-- tell two same-named catalogue entries apart either.  So a name is bridged
-- only when it maps to EXACTLY ONE itemID in the seed catalogue.  Ambiguous
-- names stay itemID-only and lose nothing - the Bazaar tab still prices them.
--
-- Unit convention already matches: Atr_Bz_RecordPrice is handed the cheapest
-- PER-ITEM buyout, which is exactly what gAtr_ScanDB stores.

-- Built from Atr_Bz_GetCatalog (NOT ATR_BZ_SEED, whose rows are positional
-- and which omits the hand-maintained "extra" list), and invalidated with it.
local gBz_BridgeMap = nil;			-- itemID -> name, unambiguous names only

function Atr_Bz_InvalidateBridge ()
	gBz_BridgeMap = nil;
end

function Atr_Bz_BridgeMap ()

	if (gBz_BridgeMap) then return gBz_BridgeMap; end

	local list	= (Atr_Bz_GetCatalog and Atr_Bz_GetCatalog ()) or {};
	local byName = {};

	local i;
	for i = 1, #list do
		local rec = list[i];
		if (rec and rec.name and rec.id) then
			if (byName[rec.name] == nil) then
				byName[rec.name] = rec.id;
			elseif (byName[rec.name] ~= rec.id) then
				byName[rec.name] = false;		-- two items share this name: never bridge it
			end
		end
	end

	gBz_BridgeMap = {};

	local n, id;
	for n, id in pairs (byName) do
		if (id) then gBz_BridgeMap[id] = n; end
	end

	return gBz_BridgeMap;
end


function Atr_Bz_FeedPriceDB_Enabled ()

	if (AUCTIONATOR_BAZAAR == nil) then return true; end
	return (AUCTIONATOR_BAZAAR.feedPriceDB ~= false);		-- default ON
end


-- returns true when the name-keyed database was written
function Atr_Bz_FeedPriceDB (itemID, copper)

	if (not Atr_Bz_FeedPriceDB_Enabled ()) then return false; end
	if (type (gAtr_ScanDB) ~= "table") then return false; end

	local id = tonumber (itemID);
	local c  = tonumber (copper);
	if (id == nil or c == nil or c <= 0) then return false; end

	local name = Atr_Bz_BridgeMap ()[id];
	if (name == nil) then return false; end		-- unknown, or an ambiguous name

	local price = Atr_Bz_Round (c);

	-- through the store, so a Bazaar write cannot flatten a variant table the
	-- auction scan has already built for this name (BACKLOG item 12 part 3)
	if (type (Atr_PriceStore) == "function") then Atr_PriceStore (gAtr_ScanDB, name, price);
	else gAtr_ScanDB[name] = price; end

	if (type (gAtr_MeanDB) == "table") then
		local m = gAtr_MeanDB[name];
		if (type (m) ~= "table") then m = {}; gAtr_MeanDB[name] = m; end
		if (#m >= 15) then table.remove (m, math.random (1, #m)); end
		tinsert (m, price);
		table.sort (m);
	end

	return true;
end
-- FINDER_TAB end: price database bridge


function Atr_Bz_StoredPrice (itemID)

	if (AUCTIONATOR_BAZAAR == nil or AUCTIONATOR_BAZAAR.prices == nil) then return nil; end

	local p = AUCTIONATOR_BAZAAR.prices[tostring (itemID or "")];
	if (p == nil or type (p.copper) ~= "number" or p.copper <= 0) then return nil; end

	return p.copper, p.when, p.n;
end

function Atr_Bz_ForgetPrices ()
	local db = Bz_DB();
	db.prices = {};
end

-------------------------------------------------------------------------------
-- pricing every tradeable item currently on screen
-------------------------------------------------------------------------------

local gBzCat_Queue	= nil;
local gBzCat_Index	= 0;

function Atr_Bz_CategoryScanRunning ()
	return gBzCat_Queue ~= nil;
end

function Atr_Bz_CategoryScanProgress ()
	if (gBzCat_Queue == nil) then return 0, 0; end
	return gBzCat_Index, #gBzCat_Queue;
end

function Atr_Bz_CancelCategoryScan (quiet)

	local was = gBzCat_Queue;

	gBzCat_Queue = nil;
	gBzCat_Index = 0;

	if (Atr_Bz_CancelItemScan) then Atr_Bz_CancelItemScan (true); end
	if (Atr_Bz_UpdateScanButton) then Atr_Bz_UpdateScanButton(); end

	if (was and not quiet) then
		Atr_Bz_SetMessage (BZT("Pricing cancelled."));
	end
end

-- Walks the queue one item at a time.  Sequential rather than parallel because
-- CanSendAuctionQuery throttles us anyway, and a single in-flight query keeps
-- the results unambiguous.
function Atr_Bz_CategoryScanNext ()

	if (gBzCat_Queue == nil) then return; end

	gBzCat_Index = gBzCat_Index + 1;

	local rec = gBzCat_Queue[gBzCat_Index];

	if (rec == nil) then
		local n = #gBzCat_Queue;
		gBzCat_Queue = nil;
		gBzCat_Index = 0;
		if (Atr_Bz_UpdateScanButton) then Atr_Bz_UpdateScanButton(); end
		-- rebuild FIRST: it clears the status line, so setting the message
		-- before it would wipe the result the moment it appeared
		Atr_Bz_RebuildDisplay();
		Atr_Bz_SetMessage (string.format (BZT("Priced %d items."), n));
		return;
	end

	Atr_Bz_SetMessage (string.format (BZT("Pricing %d of %d: %s"),
			gBzCat_Index, #gBzCat_Queue, rec.name or "?"));

	if (Atr_Bz_UpdateScanButton) then Atr_Bz_UpdateScanButton(); end

	if (not Atr_Bz_StartItemScan (rec, true)) then
		-- could not start at all: stop rather than spin
		Atr_Bz_CancelCategoryScan (true);
	end
end

function Atr_Bz_StartCategoryScan ()

	if (gBzCat_Queue ~= nil) then
		Atr_Bz_CancelCategoryScan();
		return false;
	end

	if (AuctionFrame and AuctionFrame.IsShown and not AuctionFrame:IsShown()) then
		Atr_Bz_SetMessage (BZT("Open the auction house first."));
		return false;
	end

	-- whatever is on screen, minus the items that cannot be sold: honouring
	-- the filter means "price what I am looking at"
	local rows	= Atr_Bz_CurrentRows();
	local queue	= {};

	local i;
	for i = 1, #rows do
		if (rows[i].tradeable) then queue[#queue + 1] = rows[i]; end
	end

	if (#queue == 0) then
		Atr_Bz_SetMessage (BZT("Nothing here can be sold."));
		return false;
	end

	gBzCat_Queue = queue;
	gBzCat_Index = 0;

	Atr_Bz_CategoryScanNext();
	return true;
end

function Atr_Bz_UpdateScanButton ()

	if (not Atr_Bz_ScanButton) then return; end

	-- progress lives in the status line, which has room for the item name; the
	-- button just needs to say what clicking it will do
	if (Atr_Bz_CategoryScanRunning()) then
		Atr_Bz_ScanButton:SetText (BZT("Cancel"));
	else
		Atr_Bz_ScanButton:SetText (BZT("Price these"));
	end
end
