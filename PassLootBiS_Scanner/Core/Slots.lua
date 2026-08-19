--[[ Slots.lua -- equipLoc -> paperdoll slot(s), and the dual-slot compare rule.

Pure logic (no WoW API): given an item's equipLoc (INVTYPE_*), return which
character inventory slot id(s) it can occupy, and pick which equipped item a roll
must beat. For dual slots (rings, trinkets, one-hand weapons) the roll only wins
the slot if it beats the WORSE of the two equipped items -- that is the one you
would actually replace (§6.2).

Loads under bare lua5.1 (constants are hardcoded numbers, matching 3.3.5's
INVSLOT_* which are stable and identical across clients).
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Slots = {}

-- Canonical 3.3.5 inventory slot ids (INVSLOT_*). Hardcoded so the file is
-- offline-testable; verified against the live globals in Scanner.lua at load.
Slots.INV = {
	HEAD = 1, NECK = 2, SHOULDER = 3, SHIRT = 4, CHEST = 5, WAIST = 6,
	LEGS = 7, FEET = 8, WRIST = 9, HAND = 10, FINGER1 = 11, FINGER2 = 12,
	TRINKET1 = 13, TRINKET2 = 14, BACK = 15, MAINHAND = 16, OFFHAND = 17,
	RANGED = 18, TABARD = 19,
}
local INV = Slots.INV

-- equipLoc (INVTYPE_*) -> ordered list of slot ids that could hold the item.
-- A list with >1 entry is a dual-slot group; the compare rule below uses the min.
-- Cosmetic/no-stat slots (SHIRT, TABARD) are intentionally absent -> never scanned.
Slots.EQUIPLOC_SLOTS = {
	INVTYPE_HEAD            = { INV.HEAD },
	INVTYPE_NECK            = { INV.NECK },
	INVTYPE_SHOULDER        = { INV.SHOULDER },
	INVTYPE_CHEST           = { INV.CHEST },
	INVTYPE_ROBE            = { INV.CHEST },
	INVTYPE_WAIST           = { INV.WAIST },
	INVTYPE_LEGS            = { INV.LEGS },
	INVTYPE_FEET            = { INV.FEET },
	INVTYPE_WRIST           = { INV.WRIST },
	INVTYPE_HAND            = { INV.HAND },
	INVTYPE_FINGER          = { INV.FINGER1, INV.FINGER2 },   -- dual slot
	INVTYPE_TRINKET         = { INV.TRINKET1, INV.TRINKET2 }, -- dual slot
	INVTYPE_CLOAK           = { INV.BACK },
	-- Weapons ------------------------------------------------------------
	INVTYPE_WEAPON          = { INV.MAINHAND, INV.OFFHAND },  -- one-hand: either hand
	INVTYPE_2HWEAPON        = { INV.MAINHAND },               -- two-hand occupies MH
	INVTYPE_WEAPONMAINHAND  = { INV.MAINHAND },
	INVTYPE_WEAPONOFFHAND   = { INV.OFFHAND },
	INVTYPE_HOLDABLE        = { INV.OFFHAND },
	INVTYPE_SHIELD          = { INV.OFFHAND },
	INVTYPE_RANGED          = { INV.RANGED },
	INVTYPE_RANGEDRIGHT     = { INV.RANGED },
	INVTYPE_THROWN          = { INV.RANGED },
	INVTYPE_RELIC           = { INV.RANGED },
}

-- Return the slot-id list for an equipLoc, or nil if the item is not scannable
-- (unknown / cosmetic).
function Slots.slotsFor(equipLoc)
	if type(equipLoc) ~= "string" then return nil end
	return Slots.EQUIPLOC_SLOTS[equipLoc]
end

function Slots.isDualSlot(equipLoc)
	local list = Slots.slotsFor(equipLoc)
	return list ~= nil and #list > 1
end

-- Given a list of equipped-item scores in a slot group, return the score the roll
-- must beat (the worst / the one you'd replace) and its index. An empty slot in the
-- group means score 0 -> that empty slot is the replacement target.
--   scores : array of numbers, one per slot in the group (0 for empty)
-- Returns: targetScore, targetIndex.  Empty array -> 0, nil.
function Slots.worstEquipped(scores)
	if type(scores) ~= "table" or #scores == 0 then
		return 0, nil
	end
	local worst, worstIdx = scores[1], 1
	for i = 2, #scores do
		if scores[i] < worst then
			worst, worstIdx = scores[i], i
		end
	end
	return worst, worstIdx
end

----------------------------------------------------------------------
-- Weapon loadout comparison (§6.2 extended for 1H/2H + dual wield)
----------------------------------------------------------------------
-- The naive "worst of the slot group" rule breaks for weapons: a one-hander maps
-- to { MAINHAND, OFFHAND }, so with a TWO-hander equipped (main hand full, off hand
-- empty) worstEquipped picks the empty off hand (0) and every 1H looks like a free
-- upgrade -- even though equipping it means giving up the two-hander. These helpers
-- compute the equipped value a weapon roll must actually beat, accounting for
-- main-hand/off-hand exclusivity and dual wield.

-- equipLocs that occupy a hand (so they use the loadout rule, not worst-of-group).
-- Ranged (its own single slot) is intentionally absent -- worst-equipped is fine.
Slots.HAND_EQUIPLOCS = {
	INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true,
	INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
	INVTYPE_HOLDABLE = true, INVTYPE_SHIELD = true,
}
function Slots.isHandSlot(equipLoc)
	return Slots.HAND_EQUIPLOCS[equipLoc] == true
end

-- Dual-wield off-hand penalty: an off-hand weapon's DPS-weighted value counts only
-- `factor` of full (WoW's off-hand swings for ~50% damage). score/dpsWeighted are
-- the already-weighted totals; only the DPS portion is discounted (other stats
-- apply fully regardless of hand). factor nil -> no discount.
function Slots.offhandDpsAdjust(score, dpsWeighted, factor)
	score = tonumber(score) or 0
	dpsWeighted = tonumber(dpsWeighted) or 0
	factor = tonumber(factor)
	if factor == nil then factor = 1 end
	return score - (1 - factor) * dpsWeighted
end

-- The equipped value a weapon roll must beat. `ohAdjScore` is the off-hand score
-- with its DPS already discounted by the caller (via offhandDpsAdjust) when the off
-- hand holds a weapon; 0 when the off hand is empty. Returns nil if equipLoc is not
-- a hand slot (caller falls back to worstEquipped).
--   equipLoc   : roll's INVTYPE_*
--   canDW      : character can dual wield
--   mhScore    : equipped main-hand score (0 if empty)
--   mhIs2H     : equipped main-hand item is a two-hander
--   ohAdjScore : equipped off-hand score, off-hand DPS already discounted (0 if empty)
function Slots.weaponReplacementValue(equipLoc, canDW, mhScore, mhIs2H, ohAdjScore)
	mhScore = tonumber(mhScore) or 0
	ohAdjScore = tonumber(ohAdjScore) or 0

	if equipLoc == "INVTYPE_2HWEAPON" then
		-- A two-hander fills both hands: you give up whatever is in both.
		return mhScore + ohAdjScore
	elseif equipLoc == "INVTYPE_WEAPON" then
		-- One-hander, either hand.
		if mhIs2H then
			return mhScore                       -- one 1H vs the equipped 2H you'd drop
		elseif canDW then
			return math.min(mhScore, ohAdjScore) -- takes the worse hand (empty OH = 0)
		else
			return mhScore                       -- non-DW: only the main hand is a weapon
		end
	elseif equipLoc == "INVTYPE_WEAPONMAINHAND" then
		return mhScore
	elseif equipLoc == "INVTYPE_WEAPONOFFHAND"
		or equipLoc == "INVTYPE_HOLDABLE"
		or equipLoc == "INVTYPE_SHIELD" then
		-- An off-hand item needs a free off hand; a 2H blocks it, so you'd drop the 2H.
		if mhIs2H then return mhScore end
		return ohAdjScore
	end
	return nil
end

-- Every equipLoc this addon can score, for diagnostics that need to ENUMERATE
-- slots rather than look one up (the run-ledger dump in Scanner.lua). Derived from
-- the table above rather than written out again, so a slot added there can never be
-- missing here.
Slots.DIAG_EQUIPLOCS = {}
for equipLoc in pairs(Slots.EQUIPLOC_SLOTS) do
	Slots.DIAG_EQUIPLOCS[#Slots.DIAG_EQUIPLOCS + 1] = equipLoc
end
table.sort(Slots.DIAG_EQUIPLOCS)

-- Every inventory slot id a scoreable equipLoc can occupy, deduped and ordered,
-- for diagnostics that walk the paperdoll (the enchant check in Scanner.lua).
-- Derived, like DIAG_EQUIPLOCS, so it cannot fall out of step with the table above.
Slots.DIAG_SLOT_IDS = {}
do
	local seen = {}
	for _, equipLoc in ipairs(Slots.DIAG_EQUIPLOCS) do
		for _, slotId in ipairs(Slots.EQUIPLOC_SLOTS[equipLoc]) do
			if not seen[slotId] then
				seen[slotId] = true
				Slots.DIAG_SLOT_IDS[#Slots.DIAG_SLOT_IDS + 1] = slotId
			end
		end
	end
	table.sort(Slots.DIAG_SLOT_IDS)
end

ns.Slots = Slots
return Slots
