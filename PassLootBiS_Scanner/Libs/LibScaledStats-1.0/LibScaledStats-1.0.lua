--[[ LibScaledStats-1.0 -- read an item's stats past Ascension's lying stat cache.

The shared "read true stats" primitive for the PassLootBiS addon family
(integration.md). Turns an item into a { [weightKey] = number } table using
BisBeard's 34 weight keys (stat-mapping.md), by scanning a rendered tooltip
pointed at the real instance -- NOT the link-derived GetItemStats/GetItemInfo
values, which are cached-first and lie for scaled instances.

Design (integration.md §3):
  * Emit BisBeard's key vocabulary, not raw ITEM_MOD_* names.
  * Own a single hidden scanning tooltip; never touch GameTooltip.
  * Never error into a caller -- pcall everything, return ok=false instead.
  * Split a PURE line parser (line -> statKey,value) from the tooltip DRIVER,
    so the parser self-tests offline under lua5.1.

Locale-proof: patterns are built at runtime from the client's own ITEM_MOD_*
format strings (which carry the number placeholder), never hardcoded enUS text.

The pure parser is exposed as _G.LibScaledStats_Parser for offline tests; the
LibStub registration + tooltip driver only run when the WoW API is present.
]]

----------------------------------------------------------------------
-- PURE PARSER (no WoW API) -- offline testable
----------------------------------------------------------------------

local Parser = {}

-- The BisBeard weight keys the scorer expects, plus the two CoA-custom flat
-- "Power" stats (pvePower / pvpPower) the scanner can optionally score.
Parser.WEIGHT_KEYS = {
	"agility", "armor", "armorPenetration", "arcaneResist", "attackPower",
	"block", "blockValue", "critRating", "defense", "dodge", "expertise",
	"feralAttackPower", "fireResist", "frostResist", "hasteRating",
	"healingPower", "hitRating", "intellect", "mp5", "natureResist", "parry",
	"rangedAttackPower", "rangedDps", "shadowResist", "shieldBlockValue",
	"spellDamage", "spellPenetration", "spellPower", "spirit", "stamina",
	"strength", "weaponDps",
	"pvePower", "pvpPower",   -- CoA-custom; scored only when the user opts in
}

-- weightKey -> the _G global name(s) whose format string carries this stat's
-- number. First global that yields a numeric-capture pattern wins.
--
-- SPIKE RESULT (Ascension / CoA 3.3.5, confirmed via /plbisscan debug): the
-- ITEM_MOD_*_SHORT globals are BARE LABELS with no number placeholder
-- ("Strength", "Critical Strike Rating") -- useless for value capture. The
-- non-SHORT ITEM_MOD_* globals are the real format strings carrying %d:
--   primary  ITEM_MOD_AGILITY   = "%c%d Agility"                        -> "+16 Agility"
--   rating   ITEM_MOD_CRIT_RATING = "Improves critical strike rating by %d." -> "Equip: Improves ... by 8."
--   power    ITEM_MOD_ATTACK_POWER = "Increases attack power by %d."
-- So we prefer the long global and keep the _SHORT as a harmless fallback for
-- any client/locale where the long form is absent (a bare label captures no
-- number, so it just no-ops rather than mis-parsing).
Parser.WEIGHT_KEY_GLOBALS = {
	strength          = { "ITEM_MOD_STRENGTH", "ITEM_MOD_STRENGTH_SHORT" },
	agility           = { "ITEM_MOD_AGILITY", "ITEM_MOD_AGILITY_SHORT" },
	stamina           = { "ITEM_MOD_STAMINA", "ITEM_MOD_STAMINA_SHORT" },
	intellect         = { "ITEM_MOD_INTELLECT", "ITEM_MOD_INTELLECT_SHORT" },
	spirit            = { "ITEM_MOD_SPIRIT", "ITEM_MOD_SPIRIT_SHORT" },
	armorPenetration  = { "ITEM_MOD_ARMOR_PENETRATION_RATING", "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT" },
	attackPower       = { "ITEM_MOD_ATTACK_POWER", "ITEM_MOD_ATTACK_POWER_SHORT" },
	rangedAttackPower = { "ITEM_MOD_RANGED_ATTACK_POWER", "ITEM_MOD_RANGED_ATTACK_POWER_SHORT" },
	feralAttackPower  = { "ITEM_MOD_FERAL_ATTACK_POWER", "ITEM_MOD_FERAL_ATTACK_POWER_SHORT" },
	critRating        = { "ITEM_MOD_CRIT_RATING", "ITEM_MOD_CRIT_RATING_SHORT" },
	hasteRating       = { "ITEM_MOD_HASTE_RATING", "ITEM_MOD_HASTE_RATING_SHORT" },
	hitRating         = { "ITEM_MOD_HIT_RATING", "ITEM_MOD_HIT_RATING_SHORT" },
	expertise         = { "ITEM_MOD_EXPERTISE_RATING", "ITEM_MOD_EXPERTISE_RATING_SHORT" },
	defense           = { "ITEM_MOD_DEFENSE_SKILL_RATING", "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT" },
	dodge             = { "ITEM_MOD_DODGE_RATING", "ITEM_MOD_DODGE_RATING_SHORT" },
	parry             = { "ITEM_MOD_PARRY_RATING", "ITEM_MOD_PARRY_RATING_SHORT" },
	block             = { "ITEM_MOD_BLOCK_RATING", "ITEM_MOD_BLOCK_RATING_SHORT" },
	blockValue        = { "ITEM_MOD_BLOCK_VALUE", "ITEM_MOD_BLOCK_VALUE_SHORT" },
	healingPower      = { "ITEM_MOD_SPELL_HEALING_DONE", "ITEM_MOD_SPELL_HEALING_DONE_SHORT" },
	spellPower        = { "ITEM_MOD_SPELL_POWER", "ITEM_MOD_SPELL_POWER_SHORT" },
	spellDamage       = { "ITEM_MOD_SPELL_DAMAGE_DONE", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT" },
	spellPenetration  = { "ITEM_MOD_SPELL_PENETRATION", "ITEM_MOD_SPELL_PENETRATION_SHORT" },
	mp5               = { "ITEM_MOD_MANA_REGENERATION", "ITEM_MOD_POWER_REGEN0", "ITEM_MOD_MANA_REGENERATION_SHORT" },
	fireResist        = { "ITEM_MOD_FIRE_RESISTANCE_SHORT" },
	frostResist       = { "ITEM_MOD_FROST_RESISTANCE_SHORT" },
	natureResist      = { "ITEM_MOD_NATURE_RESISTANCE_SHORT" },
	shadowResist      = { "ITEM_MOD_SHADOW_RESISTANCE_SHORT" },
	arcaneResist      = { "ITEM_MOD_ARCANE_RESISTANCE_SHORT" },
	-- armor / shieldBlockValue: base-stat lines, handled specially below.
	-- rangedDps / weaponDps: derived from the DPS line, routed by type+slot.
}

-- CoA-custom stat lines that have NO ITEM_MOD_* global (BisBeard doesn't model
-- them): the flat PvE/PvP Power damage stats. These render as plain English on
-- this English-only client ("Equip: Increases PvE Power by 38."), so we match
-- them with literal patterns rather than deriving from a format global. Each is a
-- ready Lua pattern with one numeric capture; appended to every pattern set.
Parser.EXTRA_PATTERNS = {
	{ key = "pvePower", pattern = "Increases PvE Power by ([%+%-]?[%d%.,]+)" },
	{ key = "pvpPower", pattern = "Increases PvP Power by ([%+%-]?[%d%.,]+)" },
}

-- GetItemStats() return-key (ITEM_MOD_*_SHORT name) -> weightKey. Used by the
-- hybrid strategy (DESIGN §4.1B): GetItemStats keys are reliable even when its
-- values lie, so this lets a caller learn which stats an item HAS.
Parser.GETITEMSTATS_KEY_TO_WEIGHT = {}
for weightKey, globals in pairs(Parser.WEIGHT_KEY_GLOBALS) do
	for _, g in ipairs(globals) do
		Parser.GETITEMSTATS_KEY_TO_WEIGHT[g] = weightKey
	end
end
Parser.GETITEMSTATS_KEY_TO_WEIGHT["ITEM_MOD_RESILIENCE_RATING_SHORT"] = nil -- resilience: no CoA weight

-- Ranged-weapon subtypes route the DPS line to rangedDps; melee weapon equip
-- slots route it to weaponDps. Mirrors candidates.RANGED_WEAPON_TYPES /
-- WEAPON_DPS_SLOTS exactly. Wands (spell-school DPS) deliberately route nowhere.
Parser.RANGED_WEAPON_SUBTYPES = {
	Bows = true, Crossbows = true, Guns = true, Thrown = true,
}
Parser.WEAPON_DPS_EQUIPLOCS = {
	INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true,
	INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
}

-- Which weight key (if any) the parsed DPS number feeds, given the item's
-- weapon subType and equipLoc. Returns "rangedDps" | "weaponDps" | nil.
function Parser.dpsWeightKey(subType, equipLoc)
	if subType and Parser.RANGED_WEAPON_SUBTYPES[subType] then
		return "rangedDps"
	end
	if equipLoc and Parser.WEAPON_DPS_EQUIPLOCS[equipLoc] then
		return "weaponDps"
	end
	return nil
end

-- Parse a numeric token out of tooltip text: strips + sign and thousands commas,
-- keeps a decimal point. "1,024" -> 1024, "37.5" -> 37.5, "+45" -> 45.
function Parser.parseNumber(str)
	if type(str) ~= "string" then return nil end
	str = str:gsub(",", ""):gsub("%+", "")
	return tonumber(str)
end

-- Turn a C-style format string (Blizzard global) into a Lua capture pattern with
-- exactly one numeric capture. Handles %d %s %c %.1f and positional %1$d, escapes
-- literals, and preserves stat wording so the pattern only matches the right line.
local NUM, ANY, PCT = "\001", "\002", "\003"
function Parser.formatToPattern(fmt)
	if type(fmt) ~= "string" or fmt == "" then return nil end
	fmt = fmt:gsub("%%%%", PCT)                       -- protect literal %%
	local convs, i = {}, 0
	fmt = fmt:gsub("%%[%-%+ #0]*%d*%$?[%-%+ #0]*%d*%.?%d*([diouxXeEfgGsc])", function(conv)
		i = i + 1
		convs[i] = conv
		return "\004" .. i .. "\005"
	end)
	-- value token = first numeric conversion, else first %s (pre-formatted number)
	local valueIdx
	for k, c in ipairs(convs) do
		if c ~= "s" and c ~= "c" then valueIdx = k break end
	end
	if not valueIdx then
		for k, c in ipairs(convs) do if c == "s" then valueIdx = k break end end
	end
	fmt = fmt:gsub("\004(%d+)\005", function(n)
		return (tonumber(n) == valueIdx) and NUM or ANY
	end)
	fmt = fmt:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")   -- escape lua magic
	fmt = fmt:gsub(NUM, function() return "([%+%-]?[%d%.,]+)" end)
	fmt = fmt:gsub(ANY, function() return ".-" end)
	fmt = fmt:gsub(PCT, function() return "%%" end)
	return fmt
end

-- Build the pattern set from a lookup(globalName) -> formatString function.
-- In-game the lookup is function(n) return _G[n] end; tests pass a fixture.
-- Returns an array of { key = weightKey, pattern = luaPattern }.
function Parser.buildPatternSet(lookup)
	local set = {}
	for weightKey, globals in pairs(Parser.WEIGHT_KEY_GLOBALS) do
		for _, name in ipairs(globals) do
			local fmt = lookup(name)
			local pat = fmt and Parser.formatToPattern(fmt)
			if pat then
				set[#set + 1] = { key = weightKey, pattern = pat }
				break   -- first existing global wins for this key
			end
		end
	end
	-- Append the CoA-custom literal patterns (PvE/PvP Power) -- no global to derive.
	for _, e in ipairs(Parser.EXTRA_PATTERNS) do
		set[#set + 1] = { key = e.key, pattern = e.pattern }
	end
	return set
end

-- Match one tooltip line against every pattern, accumulating into statsOut.
-- Accumulates (+=) so a stat that appears twice sums (stat-mapping.md pitfall).
function Parser.parseLine(line, patternSet, statsOut)
	if type(line) ~= "string" or line == "" then return end
	for _, entry in ipairs(patternSet) do
		local captured = line:match(entry.pattern)
		if captured then
			local n = Parser.parseNumber(captured)
			if n then
				statsOut[entry.key] = (statsOut[entry.key] or 0) + n
			end
		end
	end
end

-- Parse a whole set of tooltip lines into a stats table.
function Parser.parseLines(lines, patternSet)
	local stats = {}
	if type(lines) ~= "table" then return stats end
	for _, line in ipairs(lines) do
		Parser.parseLine(line, patternSet, stats)
	end
	return stats
end

-- Expose the pure parser for offline tests regardless of environment.
_G.LibScaledStats_Parser = Parser

----------------------------------------------------------------------
-- TOOLTIP DRIVER (WoW API) -- only when in-game and LibStub is present
----------------------------------------------------------------------

if not rawget(_G, "LibStub") or not rawget(_G, "CreateFrame") then
	return
end

-- MINOR history (this library is embedded in BOTH addons of the family and
-- LibStub keeps only the newest copy, so every fix bumps MINOR to out-version an
-- older copy that may load first):
--   2: parser reads the long ITEM_MOD_* globals (carry the %d), not _SHORT labels.
--   3: also parse the CoA-custom PvE/PvP Power lines (Parser.EXTRA_PATTERNS).
local MAJOR, MINOR = "LibScaledStats-1.0", 3
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end   -- an equal-or-newer copy already loaded

lib.Parser = Parser
lib.patternSet = nil   -- drop any pattern cache built by an older copy before upgrade

-- One hidden scanning tooltip, owned by the library (integration.md §3).
local SCAN_NAME = "LibScaledStatsScanTip"
lib.tip = lib.tip or CreateFrame("GameTooltip", SCAN_NAME, nil, "GameTooltipTemplate")
lib.tip:SetOwner(UIParent, "ANCHOR_NONE")

-- Lazily built once (globals exist by first use). Rebuildable if locale changes.
function lib:GetPatternSet()
	if not self.patternSet then
		self.patternSet = Parser.buildPatternSet(function(name) return _G[name] end)
	end
	return self.patternSet
end

-- Read the left-column FontString text of the currently-set tooltip.
local function readLines()
	local lines = {}
	for i = 1, lib.tip:NumLines() do
		local fs = _G[SCAN_NAME .. "TextLeft" .. i]
		local t = fs and fs:GetText()
		if t and t ~= "" then lines[#lines + 1] = t end
	end
	return lines
end

-- Core: point the tooltip at something via `setter`, scan its lines into stats.
-- Returns stats, ok. Never throws (pcall-wrapped) -- a stat read must never break
-- a loot roll (integration.md §3).
local function scanWith(setter, ...)
	local args = { ... }
	local ok, lines = pcall(function()
		lib.tip:ClearLines()
		setter(lib.tip, unpack(args))
		return readLines()
	end)
	if not ok or not lines then
		return {}, false
	end
	local stats = Parser.parseLines(lines, lib:GetPatternSet())
	return stats, true, lines
end

-- Public reads. Each returns stats, ok (integration.md §3 API).
function lib:GetRollItemStats(rollID)
	return scanWith(self.tip.SetLootRollItem, rollID)   -- server truth on the roll instance
end

function lib:GetEquippedStats(slotId)
	return scanWith(self.tip.SetInventoryItem, "player", slotId)  -- your real instance
end

function lib:GetHyperlinkStats(itemLink)
	-- MAY be cached-first / nominal for scaled instances (integration.md §3). Use
	-- only when a real instance isn't available.
	return scanWith(self.tip.SetHyperlink, itemLink)
end

-- Weapon DPS read straight off the tooltip's "(N.N damage per second)" line,
-- routed to rangedDps/weaponDps by subType+equipLoc. Returns dps, weightKey.
--   subType, equipLoc : from GetItemInfo, decide routing (nil weightKey -> no DPS)
--   setterName        : "SetLootRollItem" | "SetInventoryItem" | "SetHyperlink"
--   ...               : the args that setter needs (rollID / "player",slot / link)
function lib:GetWeaponDps(subType, equipLoc, setterName, ...)
	local key = Parser.dpsWeightKey(subType, equipLoc)
	if not key then return nil, nil end
	local setter = self.tip[setterName]
	if not setter then return nil, key end
	local args = { ... }
	local ok, dps = pcall(function()
		self.tip:ClearLines()
		setter(self.tip, unpack(args))
		local dpsGlobal = _G.ITEM_MOD_DAMAGE_PER_SECOND_SHORT
		local dpsPat = dpsGlobal and Parser.formatToPattern(dpsGlobal)
		for i = 1, self.tip:NumLines() do
			local fs = _G[SCAN_NAME .. "TextLeft" .. i]
			local t = fs and fs:GetText()
			if t then
				local captured = dpsPat and t:match(dpsPat)
				-- Fallback: any "(N.N ... per second)" style paren'd number.
				captured = captured or t:match("%(([%d%.,]+)%s")
				if captured then return Parser.parseNumber(captured) end
			end
		end
		return nil
	end)
	if ok then return dps, key end
	return nil, key
end

-- Convenience: scan an item's stats AND fold in its weapon DPS in one call, so
-- both sides of a compare are read through the same path. Returns stats, ok.
--   setterName, ... : as GetWeaponDps
--   subType, equipLoc : for DPS routing (pass nil,nil for armor)
function lib:GetStatsWithDps(setterName, subType, equipLoc, ...)
	local stats, ok = scanWith(self.tip[setterName], ...)
	local dps, key = self:GetWeaponDps(subType, equipLoc, setterName, ...)
	if dps and key then
		stats[key] = (stats[key] or 0) + dps
	end
	return stats, ok
end

-- Parse the stats off an ALREADY-SHOWN tooltip frame (e.g. the live GameTooltip
-- the player is hovering), rather than driving our own hidden tooltip. Reads the
-- item exactly as the client rendered it. Folds weapon DPS by subType+equipLoc.
-- Returns stats, ok. Never throws.
--   tooltip           : a GameTooltip frame with a global name (GetName())
--   subType, equipLoc : from GetItemInfo, for DPS routing (nil,nil for armor)
function lib:ParseShownTooltip(tooltip, subType, equipLoc)
	local name = tooltip and tooltip.GetName and tooltip:GetName()
	if not name then return {}, false end
	local ok, stats = pcall(function()
		local lines = {}
		for i = 1, tooltip:NumLines() do
			local fs = _G[name .. "TextLeft" .. i]
			local t = fs and fs:GetText()
			if t and t ~= "" then lines[#lines + 1] = t end
		end
		local s = Parser.parseLines(lines, self:GetPatternSet())
		local key = Parser.dpsWeightKey(subType, equipLoc)
		if key then
			local dpsGlobal = _G.ITEM_MOD_DAMAGE_PER_SECOND_SHORT
			local dpsPat = dpsGlobal and Parser.formatToPattern(dpsGlobal)
			for _, line in ipairs(lines) do
				local cap = (dpsPat and line:match(dpsPat)) or line:match("%(([%d%.,]+)%s")
				if cap then s[key] = (s[key] or 0) + Parser.parseNumber(cap); break end
			end
		end
		return s
	end)
	if ok then return stats, true end
	return {}, false
end

-- Hybrid introspection (DESIGN §4.1B): which BisBeard stat keys an item HAS,
-- from GetItemStats (keys reliable even when values lie). Returns a set { key=true }.
function lib:GetStatKeySet(itemLink)
	local present = {}
	if not _G.GetItemStats or not itemLink then return present end
	local ok, gi = pcall(function()
		local t = {}
		_G.GetItemStats(itemLink, t)
		return t
	end)
	if ok and gi then
		for giKey in pairs(gi) do
			local weightKey = Parser.GETITEMSTATS_KEY_TO_WEIGHT[giKey]
			if weightKey then present[weightKey] = true end
		end
	end
	return present
end

function lib:GetVersion() return MINOR end

return lib
