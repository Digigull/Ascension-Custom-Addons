-- batch-price-smoke.lua -- pins BACKLOG item 13's pricing.
--
-- Run from the repo root:   lua5.1 management/addons/auctionator/tools/batch-price-smoke.lua
--
-- Why this one exists when the house rule is "ship it, tooling is a fallback":
-- Batch Post now prices off a live name scan, and picking the right number out
-- of that result set means doing two things this addon has got wrong before --
-- matching SAME-NAME VARIANTS (BACKLOG items 12, 15 and 16; sell-variant-smoke.lua
-- exists because that symptom escaped twice) and telling YOUR OWN listings from
-- everybody else's, which is the whole reason the batch stopped using the price
-- database.  Both are pure functions over a result array whose ORDER nobody
-- controls, so the orders are enumerated here rather than reasoned about.
--
-- It stubs only what those two functions touch.  It is not a client emulator and
-- must not grow into one: nothing here drives frames, the scan engine, or a post.

local passed, failed = 0, 0

local function check (ok, what)
	if (ok) then
		passed = passed + 1
	else
		failed = failed + 1
		print ("FAIL: " .. what)
	end
end

local function eq (got, want, what)
	check (got == want, string.format ("%s -- got %s, wanted %s", what, tostring (got), tostring (want)))
end

--------------------------------------------------------------------
-- the item: one name, two variants.  This is the real case on this server.
--------------------------------------------------------------------

local NAME  = "Bloodforged Imperial Jewel"
local PLAIN = "|cff0070dd|Hitem:50001:0:0:0:0:0:0:0|h[" .. NAME .. "]|h|r"
local SUFFX = "|cff0070dd|Hitem:50001:0:0:0:0:0:137:0|h[" .. NAME .. "]|h|r"
local OTHER = "|cffffffff|Hitem:50002:0:0:0:0:0:0:0|h[Saronite Ore]|h|r"

local ME = "Tester"

--------------------------------------------------------------------
-- client + addon stubs
--------------------------------------------------------------------

local gListings = {}

function UnitName () return ME end
function GetItemInfo (link) return (link == OTHER) and "Saronite Ore" or NAME end

-- The real one, copied in shape from AuctionatorHints.lua: itemId:suffixId.
function Atr_VariantKey (link)
	if (type (link) ~= "string") then return nil end
	local itemId, suffixId = link:match ("item:(%d+):%-?%d*:%-?%d*:%-?%d*:%-?%d*:%-?%d*:(%-?%d+)")
	if (itemId == nil) then
		itemId = link:match ("item:(%d+)")
		if (itemId == nil) then return nil end
		suffixId = "0"
	end
	return itemId .. ":" .. (suffixId or "0")
end

-- Whole-copper undercut, so the arithmetic in the assertions stays readable.
function Atr_CalcUndercutPrice (p) return math.floor (p) - 1 end

local gStored = {}
function Atr_GetAuctionPrice (name, vkey) return gStored[(vkey or name)] or gStored[name] end

local F = { GetResults = function () return gListings end }

--------------------------------------------------------------------
-- load the real file with a stubbed addon table
--------------------------------------------------------------------

local path = "Auctionator-Finder-Ascension/AuctionatorBatchPost.lua"
local chunk = loadfile (path)
if (chunk == nil) then
	print ("FAIL: could not load " .. path .. " -- run this from the repo root")
	os.exit (1)
end
chunk ("Auctionator-Finder-Ascension", { Finder = F })

--------------------------------------------------------------------
-- Atr_BP_LiveUnit: the lowest per-UNIT buyout that is not yours
--------------------------------------------------------------------

local function listing (link, count, buyout, owner)
	return { name = GetItemInfo (link), link = link, count = count, buyoutPrice = buyout, owner = owner }
end

gListings = { listing (PLAIN, 1, 500, "Someone") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 500, "one listing, stack of one")

gListings = { listing (PLAIN, 5, 500, "Someone") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 100, "buyout is for the STACK, so it divides by count")

-- the lowest wins, in both presentation orders
gListings = { listing (PLAIN, 1, 900, "A"), listing (PLAIN, 1, 300, "B"), listing (PLAIN, 1, 600, "C") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 300, "lowest wins (cheapest in the middle)")
gListings = { listing (PLAIN, 1, 300, "B"), listing (PLAIN, 1, 900, "A") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 300, "lowest wins (cheapest first)")
gListings = { listing (PLAIN, 1, 900, "A"), listing (PLAIN, 1, 300, "B") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 300, "lowest wins (cheapest last)")

-- a stack of ten at 1000 undercuts a single at 150 on a PER UNIT basis
gListings = { listing (PLAIN, 1, 150, "A"), listing (PLAIN, 10, 1000, "B") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 100, "per-unit, not per-listing")

--------------------------------------------------------------------
-- YOUR OWN listings are dropped.  This is the reason the batch stopped
-- pricing off the database, which keeps no owner.
--------------------------------------------------------------------

gListings = { listing (PLAIN, 1, 300, ME), listing (PLAIN, 1, 900, "Someone") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 900, "your own cheaper listing is ignored")

gListings = { listing (PLAIN, 1, 300, ME) }
eq (Atr_BP_LiveUnit (PLAIN, NAME), nil, "only your own listings reads as nothing listed")

gListings = { listing (PLAIN, 1, 300, ME), listing (PLAIN, 1, 400, ME) }
eq (Atr_BP_LiveUnit (PLAIN, NAME), nil, "several of your own still reads as nothing listed")

-- owner not yet sent by the server: counted as competition, deliberately
gListings = { listing (PLAIN, 1, 300, nil), listing (PLAIN, 1, 900, "Someone") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 300, "an unknown owner counts as somebody else")

--------------------------------------------------------------------
-- SAME-NAME VARIANTS.  The suffixed jewel and the plain one share a name
-- and must not price each other.
--------------------------------------------------------------------

gListings = { listing (SUFFX, 1, 100, "A"), listing (PLAIN, 1, 900, "B") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 900, "the other variant's cheaper listing is not ours to undercut")
eq (Atr_BP_LiveUnit (SUFFX, NAME), 100, "...and the suffixed one prices off its own")

gListings = { listing (SUFFX, 1, 100, "A") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), nil, "only the other variant listed reads as nothing listed")

-- a different item that happens to be in the same result set
gListings = { listing (OTHER, 1, 5, "A"), listing (PLAIN, 1, 900, "B") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 900, "another item in the results is ignored")

--------------------------------------------------------------------
-- rows with nothing to read
--------------------------------------------------------------------

gListings = {}
eq (Atr_BP_LiveUnit (PLAIN, NAME), nil, "empty results")

gListings = { listing (PLAIN, 1, 0, "A") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), nil, "a bid-only listing has no buyout to undercut")

gListings = { listing (PLAIN, 1, 0, "A"), listing (PLAIN, 1, 700, "B") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 700, "a bid-only listing does not hide a real one")

gListings = { listing (PLAIN, nil, 800, "A") }
eq (Atr_BP_LiveUnit (PLAIN, NAME), 800, "a missing count is one")

--------------------------------------------------------------------
-- Atr_BP_EffectiveUnit: the three cases the header names
--------------------------------------------------------------------

gStored = { ["50001:0"] = 1000 }

-- 1. not scanned -> stored price, undercut
eq (Atr_BP_EffectiveUnit ({ link = PLAIN, name = NAME }), 999,
	"unscanned entry uses the stored price, undercut")

-- 2. scanned, competition found -> undercut the LIVE price, not the stored one
eq (Atr_BP_EffectiveUnit ({ link = PLAIN, name = NAME, scanned = true, liveUnit = 400 }), 399,
	"scanned entry undercuts the live listing")

-- 3. scanned, nothing listed -> stored price, NOT undercut.  There is nothing
--    to undercut, and shaving a step off an uncontested price is pure loss.
eq (Atr_BP_EffectiveUnit ({ link = PLAIN, name = NAME, scanned = true, liveUnit = nil }), 1000,
	"scanned but nothing listed uses the stored price WITHOUT the undercut")

-- nothing known at all
gStored = {}
eq (Atr_BP_EffectiveUnit ({ link = PLAIN, name = NAME }), nil,
	"no stored price and no scan means no price at all")
eq (Atr_BP_EffectiveUnit ({ link = PLAIN, name = NAME, scanned = true, liveUnit = nil }), nil,
	"scanned, nothing listed, nothing stored -- still no price")
eq (Atr_BP_EffectiveUnit (nil), nil, "no entry")

-- the floor: an undercut must never reach zero, which would be an auction with
-- no buyout rather than a cheap one
eq (Atr_BP_EffectiveUnit ({ link = PLAIN, name = NAME, scanned = true, liveUnit = 1 }), 1,
	"undercutting a 1c listing floors at 1c, never 0")

--------------------------------------------------------------------

print (string.format ("batch-price-smoke: %d passed, %d failed", passed, failed))
if (failed > 0) then os.exit (1) end
