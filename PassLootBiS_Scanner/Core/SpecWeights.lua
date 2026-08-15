--[[ SpecWeights.lua -- pick the active spec's weight table.

The scanner ships all class/spec weights baked into Data/Weights.lua (global
PLBiSScannerWeights). The spec is USER-SELECTED, not auto-detected from talents
(DESIGN §5.4): Ascension is classless and the CoA weights use BisBeard's custom
taxonomy, so there is no clean talent->spec identity to read in-game.

Pure logic (no WoW API); offline-testable.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local SpecWeights = {}

-- Resolve a { [weightKey] = number } table for (class, spec) from a weights DB
-- shaped { [class] = { [spec] = { key = number, ... } } }. Returns nil if absent.
function SpecWeights.get(db, class, spec)
	if type(db) ~= "table" or type(class) ~= "string" or type(spec) ~= "string" then
		return nil
	end
	local byClass = db[class]
	if type(byClass) ~= "table" then return nil end
	local weights = byClass[spec]
	if type(weights) ~= "table" then return nil end
	return weights
end

-- Sorted list of class names present in the DB (for a class dropdown).
function SpecWeights.classes(db)
	local out = {}
	if type(db) ~= "table" then return out end
	for class in pairs(db) do out[#out + 1] = class end
	table.sort(out)
	return out
end

-- Sorted list of spec names for a class (for a spec dropdown).
function SpecWeights.specs(db, class)
	local out = {}
	if type(db) ~= "table" or type(db[class]) ~= "table" then return out end
	for spec in pairs(db[class]) do out[#out + 1] = spec end
	table.sort(out)
	return out
end

-- Case-insensitive exact class match -> canonical class name, or nil.
function SpecWeights.matchClass(db, query)
	if type(db) ~= "table" or type(query) ~= "string" then return nil end
	query = query:lower()
	for class in pairs(db) do
		if class:lower() == query then return class end
	end
	return nil
end

-- Case-insensitive spec match within a class -> canonical spec name, or nil.
function SpecWeights.matchSpec(db, class, query)
	if type(db) ~= "table" or type(db[class]) ~= "table" or type(query) ~= "string" then
		return nil
	end
	query = query:lower()
	for spec in pairs(db[class]) do
		if spec:lower() == query then return spec end
	end
	return nil
end

-- Find every (class, spec) whose spec name matches `query` (case-insensitive),
-- across all classes. Used to resolve a spec typed on its own. Returns an array
-- of { class = , spec = }, sorted for stable output.
function SpecWeights.findSpec(db, query)
	local out = {}
	if type(db) ~= "table" or type(query) ~= "string" then return out end
	query = query:lower()
	for _, class in ipairs(SpecWeights.classes(db)) do
		for _, spec in ipairs(SpecWeights.specs(db, class)) do
			if spec:lower() == query then
				out[#out + 1] = { class = class, spec = spec }
			end
		end
	end
	return out
end

-- Fold the user's chosen CoA "Power" stat into a spec's weights. CoA items carry
-- flat pvePower/pvpPower that BisBeard doesn't model, so the user opts one in via
-- the settings window with a tunable weight. Returns a NEW table (never mutates
-- the shared spec weights); with mode "off"/nil/unknown, returns `weights` as-is.
-- Pure; offline-testable.
function SpecWeights.withPower(weights, mode, weight)
	if type(weights) ~= "table" then return weights end
	local key
	if mode == "pve" then key = "pvePower"
	elseif mode == "pvp" then key = "pvpPower"
	else return weights end
	local out = {}
	for k, v in pairs(weights) do out[k] = v end
	out[key] = tonumber(weight) or 0
	return out
end

ns.SpecWeights = SpecWeights
return SpecWeights
