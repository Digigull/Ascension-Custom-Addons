--[[ Filter.lua -- the pure per-character armor/weapon inclusion filter.

Some characters only care about a subset of gear: a rogue wants Leather + a
handful of weapon types, and everything else (Plate, Bows, ...) is just noise.
This core decides, for one item, whether the current character wants it scored at
all. An item whose category is switched OFF for this character is treated as a
zero-score non-upgrade -- the scanner and tooltip skip it entirely.

Two filterable families, keyed by the localized `itemType`/`itemSubType` strings
`GetItemInfo` returns (the Options window builds its checkbox list from the same
client strings, so the stored keys always match what we compare against here):

  * armor materials -- Cloth / Leather / Mail / Plate   (itemType == "Armor")
  * weapon types    -- Daggers / Staves / Bows / ...     (itemType == "Weapon")
                       plus Shields, which are itemType "Armor" but read as an
                       off-hand *choice* alongside weapons, so they live in the
                       weapons group.

Everything else -- necks, rings, trinkets, cloaks (all itemType "Armor",
subType "Miscellaneous"), held-in-off-hand items, relics -- is NOT material- or
type-restricted, so it is ALWAYS scored and never appears as a checkbox.

Storage semantics (important): the filter table stores booleans keyed by subtype;
an ABSENT/nil entry means INCLUDED. Only an explicit `false` excludes. So a fresh
character (empty filter) scores everything exactly as before this feature existed,
and any weapon type we didn't list is included by default rather than silently
dropped. `included(filter, cat, key)` == `t[key] ~= false`.

No WoW API is touched here, so this file loads and self-tests under bare lua5.1.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Filter = {}

-- Ordered lists drive the Options checkboxes; the sets drive classification.
-- These are the enUS 3.3.5 item-subclass strings (stable on the Ascension client,
-- same source the Options window enumerates from) -- hardcoded so this core stays
-- offline-testable, mirroring how Slots.lua hardcodes the INVSLOT_* constants.
Filter.ARMOR = { "Cloth", "Leather", "Mail", "Plate" }
Filter.WEAPONS = {
	"Daggers", "Fist Weapons",
	"One-Handed Axes", "One-Handed Maces", "One-Handed Swords",
	"Polearms", "Staves",
	"Two-Handed Axes", "Two-Handed Maces", "Two-Handed Swords",
	"Bows", "Crossbows", "Guns", "Thrown", "Wands",
	"Shields",
}

local function toSet(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end
local ARMOR_SET  = toSet(Filter.ARMOR)
local WEAPON_SET = toSet(Filter.WEAPONS)

-- Classify an item into a filter category. Returns (category, key) where category
-- is "armor" or "weapons" and key is the subtype string, or nil if the item is not
-- filterable (always scored). `equipLoc` (INVTYPE_*) is optional but lets us exempt
-- the back piece (see below).
function Filter.categoryKey(itemType, itemSubType, equipLoc)
	-- The cloak is itemType Armor / subType "Cloth", but it is the ONE cloth item a
	-- non-cloth wearer still equips -- you never skip your back piece because you
	-- unchecked Cloth. Its subtype is indistinguishable from a cloth chest, so key
	-- off equipLoc and always score it (never a checkbox).
	if equipLoc == "INVTYPE_CLOAK" then return nil end
	if type(itemSubType) ~= "string" then return nil end
	if itemType == "Weapon" and WEAPON_SET[itemSubType] then
		return "weapons", itemSubType
	end
	if itemType == "Armor" then
		if ARMOR_SET[itemSubType] then return "armor", itemSubType end
		-- Shields are armor, but the player picks one as an off-hand alternative to
		-- a weapon, so group them with weapons.
		if itemSubType == "Shields" then return "weapons", "Shields" end
	end
	return nil
end

-- Is `key` in `cat` included for this character's `filter` table? Absent -> included.
function Filter.included(filter, cat, key)
	local t = filter and filter[cat]
	if type(t) ~= "table" then return true end
	return t[key] ~= false
end

-- The one call the scan/tooltip paths make: should this item be scored at all for
-- the current character? Non-filterable items (incl. the cloak) and a nil filter
-- always score.
function Filter.isScored(itemType, itemSubType, filter, equipLoc)
	local cat, key = Filter.categoryKey(itemType, itemSubType, equipLoc)
	if not cat then return true end
	return Filter.included(filter, cat, key)
end

ns.Filter = Filter
return Filter
