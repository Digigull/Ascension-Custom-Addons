--[[ usable-smoke.lua -- offline test for the red-text "usable" scan in Core/Cache.lua.

Run from the REPO ROOT:  lua5.1 management/addons/passlootbis/tools/usable-smoke.lua

Why this file exists: the scan decides "can I use this?" purely from the colour the
client painted a tooltip line, and getting that wrong is invisible from the outside.
The Not Usable rule and the Catch All rule both greed, so a misread reached the right
outcome anyway and the bug below survived three play sessions before a diagnostic
happened to print the evidence.

The bug (owner, 2026-08): GameTooltip REUSES its FontStrings. ClearLines() hides
them but does not reset their colour, so a string another item left red still answers
red through GetTextColor() when the current item leaves it blank. The scan read that
as an unmet requirement, and a leather-wearing character's Not Usable rule started
swallowing plainly wearable leather boots -- intermittently, depending only on what
had been scanned just before them. Case 1 is that exact tooltip.

Cache.lua touches no frames at load time, so the whole scan runs under bare lua5.1
with a stubbed tooltip. Nothing here needs the client.

Not shipped: lives under management/ per management/docs/CLAUDE.md.
]]

local addon = {}
_G.LibStub = function() return { GetAddon = function() return addon end } end

-- The client's unmet-requirement red, as ColorCheck matches it, and a plain white.
local RED   = { 1.0, 0.12549, 0.12549, 1.0 }
local WHITE = { 1.0, 1.0, 1.0, 1.0 }

-- A FontString: text plus the colour it is currently left in. The two are
-- INDEPENDENT, which is the whole point -- that is what the real widget does.
local function fs(text, colour)
	local c = colour or WHITE
	return {
		GetText = function() return text end,
		GetTextColor = function() return c[1], c[2], c[3], c[4] end,
	}
end

-- Install one tooltip's worth of lines under the names BuildTooltipCache looks up.
-- `rows` is an array of { left, right }, either side optionally nil.
local function setTooltip(rows)
	_G.PasslootBiSTT = {
		ClearLines = function() end,
		SetHyperlink = function() end,
		GetName = function() return "TT" end,
		NumLines = function() return #rows end,
	}
	for i = 1, #rows do
		_G["TTTextLeft" .. i] = rows[i][1]
		_G["TTTextRight" .. i] = rows[i][2]
	end
end

-- Core/Cache.lua is one of the three files in this repo that carry a UTF-8 BOM.
-- The 3.3.5 loader tolerates it and management/docs/CLAUDE.md says to leave it
-- alone, but bare lua5.1 chokes on it, so strip it here rather than "fixing" the
-- shipped file.
local f = assert(io.open("PasslootBiS/Core/Cache.lua", "rb"))
local src = f:read("*a")
f:close()
src = src:gsub("^\239\187\191", "")
assert(loadstring(src, "Cache.lua"))()

local passed, failed = 0, 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL: " .. msg)
	end
end

-- Every case rebuilds from a fresh link, because BuildTooltipCache short-circuits
-- when the link matches the one already cached.
local nextLink = 0
local function scan(rows)
	nextLink = nextLink + 1
	setTooltip(rows)
	addon:BuildTooltipCache({ link = "item:" .. nextLink })
	return addon.TooltipCache.usable, addon:UnusableReason()
end

--=============================================================================
-- 1. THE REGRESSION. A blank line left red by a previous item.
--=============================================================================
-- An empty line states no requirement, whatever colour it is in. This is the case
-- that shipped broken; if it ever fails again, the Not Usable rule is silently
-- eating wearable gear.
local usable, reason = scan({
	{ fs("Bloodforged Shadefiend Boots"), nil },
	{ fs("Binds when picked up"),         nil },
	{ fs("Feet"),                         fs("Leather") },
	{ fs("155 Armor"),                    fs("", RED) },   -- blank, but still red
})
check(usable == true, "blank red line must NOT make an item unusable")
check(reason == nil, "blank red line must not be reported as a reason")

-- Same, with the blank red string carrying nil text rather than "".
usable, reason = scan({
	{ fs("Some Boots"), nil },
	{ fs("Feet"),       fs(nil, RED) },
})
check(usable == true, "nil-text red line must NOT make an item unusable")
check(reason == nil, "nil-text red line must not be reported")

--=============================================================================
-- 2. A real refusal still lands
--=============================================================================
-- The measured shape: an armour class you cannot wear reddens the armour TYPE,
-- which sits in the RIGHT column of the armour line.
-- Four rows, so the armour line lands at index 4 exactly as the measured one did.
usable, reason = scan({
	{ fs("Leggings of Destruction"), nil },
	{ fs("Heroic"),                  nil },
	{ fs("Binds when picked up"),    nil },
	{ fs("Legs"),                    fs("Mail", RED) },
})
check(usable == false, "a red armour type must make the item unusable")
check(reason == "R4 Mail", "red line must be reported with its position, got " .. tostring(reason))

-- Left column too -- the position is a label, not a filter.
usable, reason = scan({
	{ fs("Plans: Radiant Gloves"),             nil },
	{ fs("Binds when picked up"),              nil },
	{ fs("Requires Blacksmithing (200)", RED), nil },
})
check(usable == false, "a red left-column requirement must make the item unusable")
check(reason == "L3 Requires Blacksmithing (200)", "got " .. tostring(reason))

--=============================================================================
-- 3. Several reds are all reported
--=============================================================================
-- One red can sit behind another, and each round trip to discover that costs a
-- play session. All of them come back, in scan order (L1, R1, L2, R2, ...).
usable, reason = scan({
	{ fs("Bloodforged", RED),     nil },
	{ fs("Leggings of Doom"),     nil },
	{ fs("Binds when picked up"), nil },
	{ fs("Legs"),                 fs("Mail", RED) },
})
check(usable == false, "multiple reds -> unusable")
check(reason == "L1 Bloodforged | R4 Mail",
	"both reds must be reported in scan order, got " .. tostring(reason))

--=============================================================================
-- 4. A clean item
--=============================================================================
usable, reason = scan({
	{ fs("Shadefiend Boots"), nil },
	{ fs("Feet"),             fs("Leather") },
})
check(usable == true, "no red -> usable")
check(reason == nil, "no red -> no reason")

--=============================================================================
-- 5. The cap holds
--=============================================================================
local many = {}
for i = 1, 8 do many[i] = { fs("red " .. i, RED), nil } end
usable, reason = scan(many)
check(usable == false, "many reds -> unusable")
local n = 0
for _ in reason:gmatch("|") do n = n + 1 end
check(n == 4, "at most 5 red lines are kept (4 separators), got " .. n)

print(string.format("\nusable-smoke: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
