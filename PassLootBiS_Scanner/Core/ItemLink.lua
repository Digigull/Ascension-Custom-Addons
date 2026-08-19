--[[ ItemLink.lua -- surgery on an item link's numeric fields.

One job today: produce the link for "this same item, with nothing the PLAYER added
to it". A 3.3.5 item link is

    |cCOLOR|Hitem:itemId:enchant:gem1:gem2:gem3:gem4:suffixId:uniqueId:level|h[Name]|h|r

so the enchant is field 2 and the gems are 3-6. Everything after them -- suffixId,
uniqueId and the trailing level -- is part of WHICH item this is, and on Ascension
that trailing level is the scaled-variant selector. Zeroing a field is therefore
safe; dropping or reordering one is not, and a stripper that rebuilds the link from
a fixed template rather than editing in place would quietly change the item.

Why this exists: the scanner compares a fresh drop against your equipped gear, and
your equipped gear is enchanted while the drop is not, so the equipped side scores
higher than the item itself is worth and upgrades under-report. Scanning the
stripped link puts both sides on the same footing.

Pure: no WoW API, so it loads and self-tests under bare lua5.1.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local ItemLink = {}

-- Zero the chosen numeric fields of an item link's |Hitem:...| payload, in place.
--   link    : a full item link, or a bare "item:..." string
--   fields  : set of 1-based field indices to zero (1 = itemId, 2 = enchant, ...)
-- Returns the rewritten link, or nil if this is not an item link.
--
-- Only fields that are PRESENT are touched: a short link (some servers emit fewer
-- trailing fields) keeps its length, because appending the missing ones would be
-- inventing item identity we were not given.
function ItemLink.zeroFields(link, fields)
	if type(link) ~= "string" or type(fields) ~= "table" then return nil end
	local payload = link:match("|Hitem:([%-%d:]+)|h") or link:match("^item:([%-%d:]+)$")
	if not payload then return nil end

	local parts, i = {}, 0
	for piece in (payload .. ":"):gmatch("([^:]*):") do
		i = i + 1
		parts[i] = fields[i] and "0" or piece
	end
	if i == 0 then return nil end
	local rebuilt = table.concat(parts, ":", 1, i)

	if link:match("|Hitem:") then
		-- Anchored on the "|h" that closes the hyperlink header so the [Name] half,
		-- the colour codes and the trailing |r all survive untouched.
		return (link:gsub("|Hitem:[%-%d:]+|h", "|Hitem:" .. rebuilt .. "|h", 1))
	end
	return "item:" .. rebuilt
end

-- Field sets, named rather than written as literals at the call site: "{ [2] = true }"
-- at a call site is unreadable and one typo away from zeroing the item id.
ItemLink.FIELD_ENCHANT = { [2] = true }
ItemLink.FIELD_ENCHANT_AND_GEMS = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }

-- The item as it dropped: no enchant. Gems are deliberately NOT stripped -- see
-- the note in Scanner.lua's equippedStats.
function ItemLink.stripEnchant(link)
	return ItemLink.zeroFields(link, ItemLink.FIELD_ENCHANT)
end

--=============================================================================
-- Offline self-test (skipped in-game)
--=============================================================================

if rawget(_G, "ITEMLINK_SELFTEST") then
	local passed = 0
	local function ok(cond, msg)
		if not cond then error("ItemLink self-test FAILED: " .. tostring(msg), 2) end
		passed = passed + 1
	end
	local function eq(got, want, msg)
		ok(got == want, (msg or "") .. "\n  got  " .. tostring(got) .. "\n  want " .. tostring(want))
	end

	-- The everyday case: an enchanted, gemmed, scaled epic.
	local full = "|cffa335ee|Hitem:412491:3831:41398:0:0:0:0:0:60|h[Kyrstel Mantle]|h|r"
	eq(ItemLink.stripEnchant(full),
		"|cffa335ee|Hitem:412491:0:41398:0:0:0:0:0:60|h[Kyrstel Mantle]|h|r",
		"enchant zeroed, gem/suffix/level kept")

	-- The trailing level is the Ascension scaled-variant selector: losing it would
	-- silently score a different item. Guard it explicitly.
	ok(ItemLink.stripEnchant(full):find(":60|h", 1, true) ~= nil, "scaling level survives")
	ok(ItemLink.stripEnchant(full):find("412491", 1, true) ~= nil, "item id survives")
	ok(ItemLink.stripEnchant(full):find("[Kyrstel Mantle]", 1, true) ~= nil, "name half survives")
	ok(ItemLink.stripEnchant(full):find("|cffa335ee", 1, true) ~= nil, "colour prefix survives")
	ok(ItemLink.stripEnchant(full):find("|r", 1, true) ~= nil, "colour terminator survives")

	-- Already unenchanted -> unchanged.
	local bare = "|cff9d9d9d|Hitem:7073:0:0:0:0:0:0:0|h[Broken Fang]|h|r"
	eq(ItemLink.stripEnchant(bare), bare, "no enchant -> byte-identical")

	-- Suffix items carry a NEGATIVE suffixId; the field pattern must accept the sign
	-- or the whole link stops matching and we silently score the enchanted item.
	local suffix = "|cff1eff00|Hitem:24383:0:0:0:0:0:-19:1723:70|h[Sage's Cloak]|h|r"
	eq(ItemLink.stripEnchant(suffix), suffix, "negative suffixId link still parses")
	local suffixEnch = "|cff1eff00|Hitem:24383:2564:0:0:0:0:-19:1723:70|h[Sage's Cloak]|h|r"
	eq(ItemLink.stripEnchant(suffixEnch),
		"|cff1eff00|Hitem:24383:0:0:0:0:0:-19:1723:70|h[Sage's Cloak]|h|r",
		"negative suffixId preserved while enchant zeroed")

	-- Gems are left alone by stripEnchant, and removed by the wider set.
	eq(ItemLink.zeroFields(full, ItemLink.FIELD_ENCHANT_AND_GEMS),
		"|cffa335ee|Hitem:412491:0:0:0:0:0:0:0:60|h[Kyrstel Mantle]|h|r",
		"enchant + all four gem fields zeroed")

	-- A short link keeps its length: we must not invent trailing identity fields.
	eq(ItemLink.stripEnchant("|Hitem:12345:999:0:0|h[Short]|h"),
		"|Hitem:12345:0:0:0|h[Short]|h", "short link stays short")

	-- Bare payload form, no hyperlink wrapper.
	eq(ItemLink.stripEnchant("item:12345:999:0:0:0:0:0:0:80"),
		"item:12345:0:0:0:0:0:0:0:80", "bare item: string")

	-- Non-items and junk abstain rather than returning something wrong.
	ok(ItemLink.stripEnchant("|cffffd000|Hquest:123:60|h[A Quest]|h|r") == nil, "quest link -> nil")
	ok(ItemLink.stripEnchant("|Hspell:1234|h[Spell]|h") == nil, "spell link -> nil")
	ok(ItemLink.stripEnchant("just some text") == nil, "plain text -> nil")
	ok(ItemLink.stripEnchant("") == nil, "empty string -> nil")
	ok(ItemLink.stripEnchant(nil) == nil, "nil -> nil")
	ok(ItemLink.stripEnchant(12345) == nil, "non-string -> nil")
	ok(ItemLink.zeroFields(full, nil) == nil, "nil field set -> nil")

	-- Zeroing field 1 would destroy the item id. Not something we ever ask for, but
	-- the function must do exactly what it is told, so it is worth pinning.
	eq(ItemLink.zeroFields("item:12345:999", { [1] = true }), "item:0:999", "field 1 is the id")

	print("ItemLink self-test: all " .. passed .. " vectors passed.")
	return
end

ns.ItemLink = ItemLink
return ItemLink
