--[[ Score.lua -- the pure scoring engine.

Reproduces the converter's score_item (converter/plbis/candidates.py:246) verbatim
so in-game scores match the web/CLI:

    score = sum( stats[k] * weights[k]  for k in (stats ∩ weights) )

Overlap only; a stat with no weight, or a weight with no stat, contributes nothing.
No WoW API is touched here, so this file loads and self-tests under bare lua5.1.
]]

-- Resolve the shared addon namespace. In-game `...` is (addonName, addonTable);
-- under bare lua5.1 it is the CLI args, so fall back to a global table the tests
-- can reach.
local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Score = {}

-- Dot the item's stats against a spec's weights over their intersection.
-- stats, weights: { [weightKey] = number }.  Returns a single number.
function Score.scoreItem(stats, weights)
	if type(stats) ~= "table" or type(weights) ~= "table" then
		return 0
	end
	local total = 0
	-- Iterate the (smaller, fixed) weight table; only overlapping keys count.
	for key, weight in pairs(weights) do
		local value = stats[key]
		if type(value) == "number" and type(weight) == "number" then
			total = total + value * weight
		end
	end
	return total
end

-- Percentage delta of a roll vs. the equipped item it would replace.
-- Empty slot (equippedScore <= 0) -> +infinity sentinel so any positive roll is
-- always an upgrade (§6.3). Returns a fraction (0.08 == +8%), not a percent.
function Score.deltaFraction(rollScore, equippedScore)
	rollScore = tonumber(rollScore) or 0
	equippedScore = tonumber(equippedScore) or 0
	if equippedScore <= 0 then
		if rollScore > 0 then return math.huge else return 0 end
	end
	return (rollScore - equippedScore) / equippedScore
end

-- The upgrade verdict used by the compare flow (§6.3).
--   rollScore      : score of the rolled item
--   equippedScore  : score of the equipped item it would replace (worst of a group)
--   threshold      : minimum delta fraction to count as an upgrade (e.g. 0.03)
-- Returns: isUpgrade(bool), delta(fraction).  A zero-weight roll (score 0) is never
-- an upgrade (avoids alerting on off-spec loot).
function Score.verdict(rollScore, equippedScore, threshold)
	rollScore = tonumber(rollScore) or 0
	threshold = tonumber(threshold) or 0
	if rollScore <= 0 then
		return false, 0
	end
	local delta = Score.deltaFraction(rollScore, equippedScore)
	return delta >= threshold, delta
end

ns.Score = Score
return Score
