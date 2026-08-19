--[[ CustomWeights.lua -- per-spec user overrides on top of the baked weights.

Data/Weights.lua ships BisBeard's numbers for every class/spec. They are a good
default and a bad law: a build that stacks one stat, a CoA class the converter
models loosely, or simply a player who disagrees, all want to nudge a weight
without regenerating the data file. This core holds the override store and the
merge; Core/Options.lua is the editor over it, and Core/Scanner.lua folds it into
the active weights.

WHERE THEY LIVE, AND WHY: account-wide (PassLootBiS_ScannerDB), keyed by class and
spec -- db.customWeights[class][spec][weightKey] = number. Class/spec themselves are
per-character (a character is exactly one class), but a WEIGHT is a property of the
spec, not of the character holding it: two alts on Ranger / Brigand want the same
tuning, and two specs on one character must not share it. Keying by (class, spec)
is what gives both. Nothing here migrates, because an absent key means "use the
shipped default" -- an old DB with no customWeights table scores exactly as before.

An override REPLACES the shipped weight for that key; it does not scale it. Setting
a key the spec does not ship (weight 0 by omission) adds it, which is the point --
that is how you make a spec score spirit when the shipped table ignores it.

Deliberately NOT settable here: pvePower / pvpPower. Those two are owned by the
"Score CoA Power" dropdown + weight box in the options window, which writes them
LAST (SpecWeights.withPower, applied after this merge in Scanner.currentWeights).
Two editors for one number is a bug report waiting to happen, so the editor's key
list leaves them out and the dropdown stays the one place they are set.

Pure logic (no WoW API); loads and runs under bare lua5.1.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local CustomWeights = {}

-- The editable weight keys, in the order the editor lays them out, with the label
-- it shows. Mirrors LibScaledStats' Parser.WEIGHT_KEYS (the keys the stat reader
-- can actually produce) MINUS pvePower/pvpPower -- see the header. If a key is ever
-- added to the library, add it here too or it will be un-editable.
--
-- Order is by usefulness, not alphabetical: the editor fills its first column top
-- to bottom and then its second, so the first half is offense/throughput (what a
-- player actually retunes) and the second half is defensive stats and the resists
-- nobody weights. Alphabetical would interleave the two and bury critRating under
-- blockValue.
CustomWeights.KEYS = {
	-- column 1: primaries, power, throughput ratings
	{ key = "strength",           label = "Strength" },
	{ key = "agility",            label = "Agility" },
	{ key = "stamina",            label = "Stamina" },
	{ key = "intellect",          label = "Intellect" },
	{ key = "spirit",             label = "Spirit" },
	{ key = "attackPower",        label = "Attack Power" },
	{ key = "rangedAttackPower",  label = "Ranged AP" },
	{ key = "feralAttackPower",   label = "Feral AP" },
	{ key = "spellPower",         label = "Spell Power" },
	{ key = "spellDamage",        label = "Spell Damage" },
	{ key = "healingPower",       label = "Healing Power" },
	{ key = "critRating",         label = "Crit" },
	{ key = "hasteRating",        label = "Haste" },
	{ key = "hitRating",          label = "Hit" },
	{ key = "expertise",          label = "Expertise" },
	{ key = "armorPenetration",   label = "Armor Pen" },
	-- column 2: weapon DPS, mana, mitigation, resists
	{ key = "weaponDps",          label = "Weapon DPS" },
	{ key = "rangedDps",          label = "Ranged DPS" },
	{ key = "spellPenetration",   label = "Spell Pen" },
	{ key = "mp5",                label = "MP5" },
	{ key = "armor",              label = "Armor" },
	{ key = "defense",            label = "Defense" },
	{ key = "dodge",              label = "Dodge" },
	{ key = "parry",              label = "Parry" },
	{ key = "block",              label = "Block" },
	{ key = "blockValue",         label = "Block Value" },
	{ key = "shieldBlockValue",   label = "Shield Block" },
	{ key = "arcaneResist",       label = "Arcane Resist" },
	{ key = "fireResist",         label = "Fire Resist" },
	{ key = "frostResist",        label = "Frost Resist" },
	{ key = "natureResist",       label = "Nature Resist" },
	{ key = "shadowResist",       label = "Shadow Resist" },
}

-- Set of editable keys, for a cheap "is this one ours?" test.
CustomWeights.EDITABLE = {}
for _, e in ipairs(CustomWeights.KEYS) do
	CustomWeights.EDITABLE[e.key] = true
end

-- The override table for one spec, or nil. `store` is db.customWeights.
function CustomWeights.get(store, class, spec)
	if type(store) ~= "table" or type(class) ~= "string" or type(spec) ~= "string" then
		return nil
	end
	local byClass = store[class]
	if type(byClass) ~= "table" then return nil end
	local w = byClass[spec]
	if type(w) ~= "table" then return nil end
	return w
end

-- Set (or with value == nil, clear) one override. Returns the store, creating the
-- nested tables on the way down and PRUNING them on the way back up, so a spec the
-- user reset leaves no empty husk in SavedVariables and `get` keeps returning nil
-- for it. Non-numeric values are refused rather than stored -- a string weight
-- would silently score 0 forever.
function CustomWeights.set(store, class, spec, key, value)
	if type(store) ~= "table" or type(class) ~= "string" or type(spec) ~= "string" then
		return store
	end
	if not CustomWeights.EDITABLE[key] then return store end

	if value ~= nil then
		value = tonumber(value)
		if not value then return store end
	end

	if value == nil then
		local w = CustomWeights.get(store, class, spec)
		if not w then return store end
		w[key] = nil
		if next(w) == nil then
			store[class][spec] = nil
			if next(store[class]) == nil then store[class] = nil end
		end
		return store
	end

	if type(store[class]) ~= "table" then store[class] = {} end
	if type(store[class][spec]) ~= "table" then store[class][spec] = {} end
	store[class][spec][key] = value
	return store
end

-- Drop every override for one spec (the editor's "Reset to defaults").
function CustomWeights.clear(store, class, spec)
	if type(store) ~= "table" or type(class) ~= "string" or type(spec) ~= "string" then
		return store
	end
	if type(store[class]) == "table" then
		store[class][spec] = nil
		if next(store[class]) == nil then store[class] = nil end
	end
	return store
end

-- How many keys this spec overrides (0 when none). Used for the button's label and
-- for the debug dump, both of which only care "is anything custom here?".
function CustomWeights.count(store, class, spec)
	local w = CustomWeights.get(store, class, spec)
	if not w then return 0 end
	local n = 0
	for _ in pairs(w) do n = n + 1 end
	return n
end

-- Merge overrides onto a spec's shipped weights. Returns a NEW table whenever there
-- is anything to apply, so the shared Data/Weights.lua table is never mutated; with
-- no overrides it returns `base` untouched (same contract as SpecWeights.withPower,
-- which runs straight after it in Scanner.currentWeights).
--
-- A stored 0 is kept as 0, not dropped: "this spec should ignore stamina entirely"
-- is a real thing to want, and Score.scoreItem sums over the weight table's own
-- keys, so a 0 there contributes 0 exactly as an absent key does -- but it also
-- shows up in the debug dump as a deliberate choice rather than an omission.
function CustomWeights.apply(base, overrides)
	if type(base) ~= "table" then return base end
	if type(overrides) ~= "table" or next(overrides) == nil then return base end
	local out = {}
	for k, v in pairs(base) do out[k] = v end
	for k, v in pairs(overrides) do
		if CustomWeights.EDITABLE[k] and type(v) == "number" then out[k] = v end
	end
	return out
end

-- A stable scalar signature of one spec's overrides, for the tooltip's equipped-
-- score cache (Tooltip.weightsSignature). Sorted, so it does not change with pairs
-- order; "" when nothing is overridden.
function CustomWeights.signature(store, class, spec)
	local w = CustomWeights.get(store, class, spec)
	if not w then return "" end
	local keys = {}
	for k in pairs(w) do keys[#keys + 1] = k end
	table.sort(keys)
	for i = 1, #keys do
		keys[i] = keys[i] .. "=" .. tostring(w[keys[i]])
	end
	return table.concat(keys, ",")
end

ns.CustomWeights = CustomWeights
return CustomWeights
