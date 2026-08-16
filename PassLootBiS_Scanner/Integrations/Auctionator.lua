--[[ Integrations/Auctionator.lua -- optional high-gold-value flag (Phase 4).

Reads the *last-scanned* Auction price for an item from the owner's Auctionator
fork (Auctionator-Ascension-Finder) and flags items worth >= the user's gold
threshold as roll-Need-worthy even when they aren't a stat upgrade (DESIGN §7).

Why we read the fork's price API and NOT the item tooltip: Auctionator's tooltip
lines (Vendor / Auction / Auction median) are user-configurable, so a given user
may have the "Auction" line turned off. The scan value lives in the fork's price
database (gAtr_ScanDB) regardless of what the tooltip shows, so we read it there.

We deliberately use ONLY the "Auction" (last scanned) value -- never the vendor
price, and never the "Auction median". The fork exposes these as plain globals
(AuctionatorHints.lua / AuctionatorAPI.lua):

  Atr_GetAuctionPrice(name|id)   -> last-scanned "Auction" price in copper (nil if
                                    unscanned); reads gAtr_ScanDB. Needs a NAME.
  Atr_GetAuctionBuyout(link|name)-> same last-scanned value, but resolves an item
                                    LINK to a name first (delegates to the above).
  Atr_GetMeanPrice(name|id)      -> "Auction median"  -- we do NOT call this.
  Atr_GetSellValue(name|id)      -> vendor price      -- we do NOT call this.

Absent fork -> returns nil, everything still works.

WoW-API-adjacent but written to also load offline: the pure logic reads a passed
`provider` table, and only liveProvider()/liveFlag() touch real globals.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Auctionator = {}
ns.Auctionator = Auctionator

-- Read the last-scanned Auction price (copper) for an item from a provider table
-- (pure/testable). `provider` models the fork's globals:
--   { GetAuctionBuyout = fn(link|name) -> copper,   -- preferred: link-aware
--     GetAuctionPrice  = fn(name)      -> copper,   -- the raw "Auction" line
--     GetItemName      = fn(link)      -> name }    -- link -> name resolver
-- Only the "Auction" (last scanned) value is ever read here -- never median/vendor.
function Auctionator.priceFrom(provider, itemLink)
	if type(provider) ~= "table" then return nil end

	local price
	-- Preferred: the fork's link-aware entry point. It resolves the link to a
	-- name and returns the same last-scanned value as Atr_GetAuctionPrice.
	if type(provider.GetAuctionBuyout) == "function" then
		local ok, p = pcall(provider.GetAuctionBuyout, itemLink)
		if ok then price = p end
	end
	-- Fallback: resolve the link to a name ourselves and read the raw "Auction"
	-- line (Atr_GetAuctionPrice needs a name, not a link).
	if (type(price) ~= "number" or price <= 0) and type(provider.GetAuctionPrice) == "function" then
		local name = itemLink
		if type(provider.GetItemName) == "function" then
			local ok, n = pcall(provider.GetItemName, itemLink)
			if ok and type(n) == "string" then name = n end
		end
		local ok, p = pcall(provider.GetAuctionPrice, name)
		if ok then price = p end
	end

	if type(price) == "number" and price > 0 then
		return price
	end
	return nil
end

-- Return a high-value flag { price, text } if the item clears goldThreshold
-- (copper), else nil. sellable=false (BoP/soulbound you can't sell) -> nil.
function Auctionator.highValueFlag(provider, itemLink, goldThreshold, sellable)
	if sellable == false then return nil end
	local price = Auctionator.priceFrom(provider, itemLink)
	if not price then return nil end
	goldThreshold = tonumber(goldThreshold) or 0
	if price < goldThreshold then return nil end
	local gold = math.floor(price / 10000)
	return { price = price, text = string.format("~%dg -- worth Need", gold) }
end

-- Build a provider from the live Auctionator fork globals, or nil if the fork
-- (or at least one of its price functions) isn't present.
function Auctionator.liveProvider()
	local buyout = rawget(_G, "Atr_GetAuctionBuyout")
	local price  = rawget(_G, "Atr_GetAuctionPrice")
	if type(buyout) ~= "function" and type(price) ~= "function" then
		return nil
	end
	local getItemInfo = rawget(_G, "GetItemInfo")
	return {
		GetAuctionBuyout = (type(buyout) == "function") and buyout or nil,
		GetAuctionPrice  = (type(price)  == "function") and price  or nil,
		GetItemName      = (type(getItemInfo) == "function")
			and function(link) return (getItemInfo(link)) end or nil,
	}
end

-- In-game convenience: read the live fork's last-scanned Auction value.
function Auctionator.liveFlag(itemLink, goldThreshold, sellable)
	local provider = Auctionator.liveProvider()
	return Auctionator.highValueFlag(provider, itemLink, goldThreshold, sellable)
end

----------------------------------------------------------------------
-- "Has any scan actually run?" -- for status displays, not the roll path
----------------------------------------------------------------------
-- The price functions above exist as soon as the fork loads, which is NOT the
-- same as having data: a fresh install answers every price query with nil until
-- the user runs one AH scan. A host that wants to tell the user "high-value
-- advice is ready" has to look at the DB itself.

-- How many names the fork's price DB holds. `scanDB` is gAtr_ScanDB (a flat
-- name -> copper table) or anything shaped like it. Counting stops at the cap --
-- a busy realm holds tens of thousands of names and no caller needs an exact
-- figure, only "none / some / lots". Returns count, capped(bool), or nil when
-- the DB isn't a table (Auctionator's Atr_InitScanDB has not run yet). Pure.
Auctionator.SCAN_COUNT_CAP = 2000

function Auctionator.scanCount(scanDB)
	if type(scanDB) ~= "table" then return nil end
	local n = 0
	for _ in pairs(scanDB) do
		n = n + 1
		if n >= Auctionator.SCAN_COUNT_CAP then return n, true end
	end
	return n, false
end

-- Live count off the fork's global, memoised for CACHE_SECS. The consumer is a
-- panel that polls while it is open, and walking a large table on every tick
-- would be pure waste -- price data only changes when an AH scan finishes.
local CACHE_SECS = 10
local cacheAt, cacheN, cacheCapped

function Auctionator.liveScanCount()
	local getTime = rawget(_G, "GetTime")
	local now = getTime and getTime() or nil
	if now and cacheAt and (now - cacheAt) < CACHE_SECS then
		return cacheN, cacheCapped
	end
	local n, capped = Auctionator.scanCount(rawget(_G, "gAtr_ScanDB"))
	-- Only memoise when there is a clock to expire against (offline there isn't).
	cacheAt, cacheN, cacheCapped = now, n, capped
	return n, capped
end

return Auctionator
