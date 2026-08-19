-- FINDER: merchant (NPC / Bazaar) scanning -------------------------------------
--
-- Opening a vendor used to fire off TWO independent harvests -- the NPC
-- trade-good price learner (here, moved out of AuctionatorHints.lua) and the
-- Bazaar token learner (Atr_Bz_HarvestMerchant, still in AuctionatorBazaar.lua)
-- -- and BOTH ran again on every MERCHANT_UPDATE.  The client refires
-- MERCHANT_UPDATE in a burst while item data streams in, so a single vendor
-- open re-walked the whole merchant list many times over; that is what made
-- opening an NPC stutter.
--
-- This file is the single, gentle entry point for both:
--
--   * ONE event frame, shared by both harvests, that DEBOUNCES the update
--     storm down to a single pass a beat after the updates go quiet, and
--   * a session THROTTLE (Fdr_ScanThrottle_*) keyed on a fingerprint of the
--     merchant's list, so re-opening a vendor already learned this session --
--     or a late stray update for it -- costs only two link reads, not a walk.
--
-- Vendor stock does not change within a session, so "already scanned this
-- vendor" is a safe skip.  A different Bazaar gossip branch is a different list
-- (different items, so a different fingerprint) and is still scanned once each.
-- The mark is only set when the list was fully populated, so a scan taken while
-- the list was still filling in is retried on the next quiet update.

-- zc lives in the addon table (zcUtils.lua keeps it file-local), so a file that
-- wants it has to capture it.  This one did not: `zc` resolved to a nil GLOBAL,
-- so `ItemID` in Atr_NPC_HarvestMerchant below was always nil, every itemID came
-- out nil, and the harvest stored NOTHING -- silently, since the guard reads as
-- ordinary defensiveness.  AUCTIONATOR_NPC_PRICES was empty in both 2026-08-19
-- dumps, including one taken straight after visiting two supply vendors.
local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

-- Local translation passthrough (the Bazaar's BZT is file-local over there).
local function MZT (s)
	if (ZT) then return ZT (s); end
	return s;
end

-- FINDER_TAB: NPC (vendor-bought) trade-good prices -----------------------
-- Some crafting reagents are bought FROM an NPC at a fixed price and sold in
-- unlimited supply -- Empty Vial, Crystal Vial, Wooden Stock, thread, flux,
-- dyes, spices, and so on.  For those the going cost is the NPC price, not
-- whatever someone happens to relist them for on the AH, and their auction
-- number just misleads the crafting-cost maths.
--
-- We can't ask the client "is item X sold by a vendor"; that's only knowable
-- while a merchant window is open (GetMerchantItemInfo).  So we LEARN it: any
-- Trade Goods item a merchant offers at UNLIMITED stock for a plain gold price
-- is recorded in AUCTIONATOR_NPC_PRICES (account-wide) as itemID -> per-item
-- NPC buy price.  Presence in that table is exactly "this trade good is
-- normally sold by NPCs", and the value is its NPC price.  Coverage grows as
-- vendors are visited; nothing here needs a curated item list.
--
-- Note the deliberate naming: the addon already says "Vendor" for the price an
-- NPC pays YOU (the sell value from GetItemInfo).  This is the other
-- direction -- what you PAY an NPC to buy it -- so it is called the NPC price
-- throughout, never "vendor".

function Atr_NPC_DB ()
	if (type (AUCTIONATOR_NPC_PRICES) ~= "table") then AUCTIONATOR_NPC_PRICES = {}; end
	return AUCTIONATOR_NPC_PRICES;
end

-- Per-item NPC buy price for a learned trade good, or nil if we've never seen
-- it sold by a vendor.
function Atr_GetNPCPrice (itemID)
	itemID = tonumber (itemID);
	if (itemID == nil or type (AUCTIONATOR_NPC_PRICES) ~= "table") then return nil; end
	local p = AUCTIONATOR_NPC_PRICES[itemID];
	if (type (p) == "number" and p > 0) then return p; end
	return nil;
end

-- Walk the open merchant and learn every unlimited-stock, gold-priced Trade
-- Goods item as an NPC-sold reagent.  Limited-stock or item/honor-cost slots
-- are skipped: an unlimited gold price is what makes a reagent "normally sold
-- by NPCs" and caps its real cost at the NPC price.
--
-- Returns  stored, warm  where `warm` is false if any merchant slot had no item
-- link yet (the list is still populating).  The scheduler uses `warm` to decide
-- whether to lock this merchant out of re-scanning for the session, so a scan
-- taken before the list finished filling in is retried rather than frozen.
function Atr_NPC_HarvestMerchant ()
	if (type (GetMerchantNumItems) ~= "function" or type (GetMerchantItemInfo) ~= "function") then return 0, false; end
	local total = GetMerchantNumItems () or 0;
	if (total <= 0) then return 0, false; end

	local db     = Atr_NPC_DB ();
	local ItemID = (zc and zc.ItemIDfromLink) or nil;

	local stored, cold = 0, 0;
	for i = 1, total do
		local link = GetMerchantItemLink and GetMerchantItemLink (i) or nil;
		if (link == nil) then cold = cold + 1; end

		local _, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo (i);
		-- unlimited stock (numAvailable == -1), a real gold price, no item/token cost
		if (price and price > 0 and not extendedCost and numAvailable == -1) then
			local itemID = link and ItemID and tonumber ((ItemID (link))) or nil;   -- extra parens: ItemID returns 3 values
			if (itemID) then
				local itemType = link and select (6, GetItemInfo (link)) or nil;
				if (itemType == "Trade Goods") then
					local q = tonumber (quantity) or 1;
					if (q < 1) then q = 1; end
					local unit = math.floor (price / q);
					if (unit > 0) then db[itemID] = unit; stored = stored + 1; end
				end
			end
		end
	end

	return stored, (cold == 0);
end

-- A cheap fingerprint of the open merchant list: who is selling, how many items,
-- and the first and last item IDs.  Same NPC, same list -> same fingerprint, so
-- once it has been fully learned we can skip it for the rest of the session.  A
-- different Bazaar gossip branch is a different item set, so it fingerprints
-- differently and is learned on its own.  Returns nil when nothing is open.
local function Atr_Merchant_Signature (total)
	total = total or (GetMerchantNumItems and GetMerchantNumItems ()) or 0;
	if (total <= 0) then return nil; end

	local name    = (UnitName and UnitName ("npc")) or "npc";
	local firstL  = GetMerchantItemLink and GetMerchantItemLink (1) or nil;
	local lastL   = GetMerchantItemLink and GetMerchantItemLink (total) or nil;
	local firstID = firstL and tostring (firstL):match ("item:(%d+)") or "?";
	local lastID  = lastL  and tostring (lastL):match  ("item:(%d+)") or "?";

	return tostring (name) .. "#" .. total .. "#" .. firstID .. "#" .. lastID;
end

-- Learn NPC prices and Bazaar tokens whenever a merchant window opens or
-- refreshes.  A dedicated frame keeps this off the core event dispatcher, and
-- it is guarded so the file still loads under a bare Lua interpreter for tests.
if (type (CreateFrame) == "function") then

	local mf = CreateFrame ("Frame", "Atr_Finder_MerchantScan", UIParent);

	mf:RegisterEvent ("MERCHANT_SHOW");
	mf:RegisterEvent ("MERCHANT_UPDATE");
	mf:RegisterEvent ("MERCHANT_CLOSED");

	local DELAY   = 0.3;     -- seconds of quiet before harvesting; the list can
	local elapsed = 0;       -- populate a frame or two after the event fires

	mf:Hide ();              -- OnUpdate only ticks while shown; idle until armed

	local function DoMerchantScan ()
		local total = (GetMerchantNumItems and GetMerchantNumItems ()) or 0;
		if (total <= 0) then return; end

		local sig = Atr_Merchant_Signature (total);
		if (sig and type (Fdr_ScanThrottle_Seen) == "function" and Fdr_ScanThrottle_Seen (sig)) then
			return;   -- this exact merchant list already learned this session
		end

		-- NPC reagent prices; its warmth flag stands for the whole list.
		local okN, _, warm = pcall (Atr_NPC_HarvestMerchant);
		if (not okN) then warm = false; end

		-- Bazaar token items -- its own harvest, reads the gossip context set
		-- below.  Kept in AuctionatorBazaar.lua; called here as a global.
		if (type (Atr_Bz_HarvestMerchant) == "function") then
			local okB, n, cat = pcall (Atr_Bz_HarvestMerchant);
			if (okB and n and n > 0 and DEFAULT_CHAT_FRAME) then
				DEFAULT_CHAT_FRAME:AddMessage (string.format (
					"|cff44ddffAuctionator|r "..MZT ("Bazaar: learned %d items%s"),
					n, cat and (" ("..cat..")") or ""));
			end
		end

		-- Only lock this merchant out of re-scanning when the list was fully
		-- populated; a partial (cold) read is left open so a later quiet update
		-- fills the gaps.
		if (sig and warm and type (Fdr_ScanThrottle_Mark) == "function") then
			Fdr_ScanThrottle_Mark (sig);
		end
	end

	mf:SetScript ("OnEvent", function (self, event)
		if (event == "MERCHANT_CLOSED") then
			self:Hide (); elapsed = 0; return;
		end
		-- MERCHANT_SHOW / MERCHANT_UPDATE: (re)arm the settle timer.  The scan
		-- early-outs cheaply for a merchant already learned this session, so an
		-- update storm costs a couple of link reads, not a full walk.
		elapsed = 0;
		self:Show ();
	end);

	mf:SetScript ("OnUpdate", function (self, dt)
		elapsed = elapsed + (dt or 0);
		if (elapsed >= DELAY) then
			elapsed = 0;
			self:Hide ();        -- stop ticking before harvesting (one-shot)
			DoMerchantScan ();
		end
	end);

	-- Bazaar gossip context: which branch's list we are about to see.  Kept
	-- with the merchant scan because it feeds Atr_Bz_HarvestMerchant's category.
	-- Atr_Bz_SetGossipContext is a global defined in AuctionatorBazaar.lua.
	if (hooksecurefunc and type (SelectGossipOption) == "function") then
		hooksecurefunc ("SelectGossipOption", function (index)
			local btn = _G["GossipTitleButton"..tostring (index)];
			local txt = btn and btn.GetText and btn:GetText ();
			if (txt and type (Atr_Bz_SetGossipContext) == "function") then
				Atr_Bz_SetGossipContext (txt);
			end
		end);
	end
end
