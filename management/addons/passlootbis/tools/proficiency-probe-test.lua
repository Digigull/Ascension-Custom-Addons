--[[--------------------------------------------------------------------------
  proficiency-probe-test.lua — offline harness for PasslootBiS/Modules/Proficiency.lua

  Modules/Proficiency.lua carries its own self-test for the PURE half (Resolve /
  Split / BuildRules / ApplyToRules). This harness covers the other half: the §3
  client probes, by faking just enough of the 3.3.5 skill + spell API to run them.

  It exists because the probes contain the two things most likely to be wrong and
  least likely to be noticed in-game:
    * the collapsed-header dance in ScanSkillLines (a collapsed header HIDES its
      children from GetNumSkillLines, so a naive scan reads "no weapon skills"),
    * the restore afterwards (indices shift when headers expand, so the
      re-collapse matches by name and walks backwards).

  Not shipped — this lives under management/ and needs no WoW client.

  Run:  lua5.1 management/addons/passlootbis/tools/proficiency-probe-test.lua
        (from the repo root; pass a path as arg 1 to point it elsewhere)
----------------------------------------------------------------------------]]

local MODULE = arg and arg[1] or "PasslootBiS/Modules/Proficiency.lua"

local failures = 0
local function check(ok, label)
  if ok then
    print("  ok   " .. label)
  else
    failures = failures + 1
    print("  FAIL " .. label)
  end
end
local function eq(got, want, label)
  check(got == want, string.format("%s (got %s, want %s)", label, tostring(got), tostring(want)))
end

--=============================================================================
-- A fake Skills window. `tree` is { {header, expanded, {child, ...}}, ... }.
-- GetNumSkillLines / GetSkillLineInfo only ever see VISIBLE lines — children of
-- a collapsed header are invisible, which is the whole trap being tested.
--=============================================================================

local function makeSkillAPI(tree)
  local api = { expandCalls = 0, collapseCalls = 0 }

  local function visible()
    local out = {}
    for _, group in ipairs(tree) do
      out[#out + 1] = { name = group.header, isHeader = true, isExpanded = group.expanded }
      if group.expanded then
        for _, child in ipairs(group.children) do
          out[#out + 1] = { name = child, isHeader = false, isExpanded = false }
        end
      end
    end
    return out
  end

  function api.GetNumSkillLines() return #visible() end

  function api.GetSkillLineInfo(i)
    local row = visible()[i]
    if not row then return nil end
    -- Real signature: name, isHeader, isExpanded, rank, tempPoints, modifier, maxRank, ...
    return row.name, row.isHeader, row.isExpanded, 1, 0, 0, 1
  end

  function api.ExpandSkillHeader(index)
    api.expandCalls = api.expandCalls + 1
    if index == 0 then
      for _, group in ipairs(tree) do group.expanded = true end
    else
      local row = visible()[index]
      for _, group in ipairs(tree) do
        if group.header == (row and row.name) then group.expanded = true end
      end
    end
  end

  function api.CollapseSkillHeader(index)
    api.collapseCalls = api.collapseCalls + 1
    local row = visible()[index]
    if not row or not row.isHeader then
      failures = failures + 1
      print("  FAIL CollapseSkillHeader called on a non-header index " .. tostring(index))
      return
    end
    for _, group in ipairs(tree) do
      if group.header == row.name then group.expanded = false end
    end
  end

  function api.expansionState()
    local out = {}
    for _, group in ipairs(tree) do out[group.header] = group.expanded end
    return out
  end

  return api
end

local function installSkillAPI(api)
  _G.GetNumSkillLines    = api and api.GetNumSkillLines or nil
  _G.GetSkillLineInfo    = api and api.GetSkillLineInfo or nil
  _G.ExpandSkillHeader   = api and api.ExpandSkillHeader or nil
  _G.CollapseSkillHeader = api and api.CollapseSkillHeader or nil
end

-- A fake spell API. `known` is a set of spell IDs the character has.
local SPELL_NAMES = {
  [196] = "One-Handed Axes", [197] = "Two-Handed Axes", [198] = "One-Handed Maces",
  [199] = "Two-Handed Maces", [200] = "Polearms", [201] = "One-Handed Swords",
  [202] = "Two-Handed Swords", [227] = "Staves", [264] = "Bows", [266] = "Guns",
  [1180] = "Daggers", [2567] = "Thrown", [5009] = "Wands", [5011] = "Crossbows",
  [15590] = "Fist Weapons", [750] = "Plate Mail", [8737] = "Mail",
  [9077] = "Leather", [9078] = "Cloth", [9116] = "Shield",
}

local function installSpellAPI(known, withIsSpellKnown)
  if not known then
    _G.GetSpellInfo, _G.IsSpellKnown = nil, nil
    return
  end
  local knownNames = {}
  for id in pairs(known) do knownNames[SPELL_NAMES[id]] = true end
  _G.GetSpellInfo = function(idOrName)
    if type(idOrName) == "number" then
      local n = SPELL_NAMES[idOrName]
      if n then return n, nil, nil, 0, 0, 0, idOrName end
      return nil
    end
    -- A NAME lookup resolves only for a spell the player knows (3.3.5 idiom).
    if knownNames[idOrName] then return idOrName, nil, nil, 0, 0, 0, 0 end
    return nil
  end
  _G.IsSpellKnown = withIsSpellKnown and function(id) return known[id] == true end or nil
end

--=============================================================================

local Proficiency = dofile(MODULE)
assert(type(Proficiency) == "table", "module did not return its table")

print("== ScanSkillLines ==")

-- S1: everything expanded — the plain case.
local tree1 = {
  { header = "Armor Proficiencies", expanded = true, children = { "Cloth", "Leather", "Mail", "Plate Mail", "Shield" } },
  { header = "Weapon Skills", expanded = true, children = { "Axes", "Swords", "Two-Handed Swords" } },
  { header = "Professions", expanded = true, children = { "Mining", "Blacksmithing" } },
}
local api1 = makeSkillAPI(tree1)
installSkillAPI(api1)
installSpellAPI(nil)
local seen1 = Proficiency.ScanSkillLines()
check(seen1 ~= nil, "S1 probe available")
eq(seen1["Plate Mail"], true, "S1 armor child seen")
eq(seen1["Swords"], true, "S1 weapon child seen")
eq(seen1["Armor Proficiencies"], nil, "S1 headers are not skills")
eq(api1.collapseCalls, 0, "S1 nothing was collapsed (nothing had been)")

-- S2: the trap — a COLLAPSED "Weapon Skills" header. A naive scan sees no
-- weapon skills at all; the probe must expand, read, and put it back.
local tree2 = {
  { header = "Armor Proficiencies", expanded = false, children = { "Cloth", "Leather", "Mail", "Plate Mail", "Shield" } },
  { header = "Weapon Skills", expanded = false, children = { "Axes", "Swords", "Two-Handed Swords" } },
  { header = "Professions", expanded = true, children = { "Mining" } },
}
local api2 = makeSkillAPI(tree2)
installSkillAPI(api2)
eq(api2.GetNumSkillLines(), 4, "S2 collapsed headers really do hide children")
local seen2 = Proficiency.ScanSkillLines()
eq(seen2["Swords"], true, "S2 found a child under a collapsed header")
eq(seen2["Plate Mail"], true, "S2 found a child under the other collapsed header")
local state2 = api2.expansionState()
eq(state2["Weapon Skills"], false, "S2 restored: Weapon Skills re-collapsed")
eq(state2["Armor Proficiencies"], false, "S2 restored: Armor Proficiencies re-collapsed")
eq(state2["Professions"], true, "S2 restored: Professions left expanded")

-- S3: no expand/collapse API at all (a client that lacks them) — the probe must
-- still read whatever is visible instead of erroring.
local tree3 = {
  { header = "Weapon Skills", expanded = true, children = { "Daggers" } },
}
local api3 = makeSkillAPI(tree3)
installSkillAPI(api3)
_G.ExpandSkillHeader, _G.CollapseSkillHeader = nil, nil
local seen3 = Proficiency.ScanSkillLines()
eq(seen3["Daggers"], true, "S3 works without Expand/CollapseSkillHeader")

-- S4: no skill API at all -> nil + a reason, never an error.
installSkillAPI(nil)
local seen4, why4 = Proficiency.ScanSkillLines()
eq(seen4, nil, "S4 unavailable -> nil")
check(type(why4) == "string" and why4:match("GetSkillLineInfo"), "S4 reason names the API")

print("== ScanKnownSpells ==")

-- K1: IsSpellKnown present.
installSpellAPI({ [750] = true, [9116] = true, [201] = true }, true)
local spells1, method1 = Proficiency.ScanKnownSpells()
eq(spells1["Plate"], true, "K1 plate known")
eq(spells1["Shields"], true, "K1 shields known")
eq(spells1["One-Handed Swords"], true, "K1 1h swords known")
eq(spells1["Daggers"], nil, "K1 daggers not known")
check(method1:match("IsSpellKnown"), "K1 method reported: " .. tostring(method1))

-- K2: IsSpellKnown absent -> the GetSpellInfo(name) fallback, same answers here.
installSpellAPI({ [750] = true, [1180] = true }, false)
local spells2, method2 = Proficiency.ScanKnownSpells()
eq(spells2["Plate"], true, "K2 plate via name lookup")
eq(spells2["Daggers"], true, "K2 daggers via name lookup")
eq(spells2["Mail"], nil, "K2 unknown stays unknown")
check(method2:match("spellbook"), "K2 method reported: " .. tostring(method2))

-- K3: no spell API -> nil + reason.
installSpellAPI(nil)
local spells3, why3 = Proficiency.ScanKnownSpells()
eq(spells3, nil, "K3 unavailable -> nil")
check(type(why3) == "string" and why3:match("GetSpellInfo"), "K3 reason names the API")

print("== Detect + BuildRules end to end ==")

-- D1: a plate/sword character, both probes live. The generated armor rule must
-- list exactly Cloth/Leather/Mail and carry the cloak carve-out; the weapon rule
-- must not list the sword types.
installSkillAPI(makeSkillAPI({
  { header = "Armor Proficiencies", expanded = false, children = { "Plate Mail", "Shield" } },
  { header = "Weapon Skills", expanded = true, children = { "Swords", "Two-Handed Swords" } },
}))
installSpellAPI({ [750] = true, [9116] = true, [201] = true, [202] = true }, true)
local report = Proficiency.Detect()
eq(report.ok, true, "D1 detection ok")
eq(report.skillOK, true, "D1 skill probe live")
eq(report.spellOK, true, "D1 spell probe live")
eq(report.known["Plate"], true, "D1 plate known")
eq(report.known["Cloth"], nil, "D1 cloth NOT known")
eq(#report.split.armor.missing, 3, "D1 three armor gaps")

local rules, notes = Proficiency.BuildRules(report.known, { roll = "pass" })
eq(#rules, 2, "D1 two rules built")
eq(#notes, 0, "D1 no refusals")
local armor = rules[1].Desc == Proficiency.DESC_ARMOR and rules[1] or rules[2]
local weapons = rules[1].Desc == Proficiency.DESC_WEAPONS and rules[1] or rules[2]
eq(#armor.TypeSubType, 3, "D1 armor filters")
eq(#armor.EquipSlot, 3, "D1 cloak/shirt/tabard carve-out present")
eq(armor.Loot[1], "pass", "D1 roll action")
eq(#weapons.TypeSubType, 13, "D1 weapon filters (15 - 2 known)")
for _, f in ipairs(weapons.TypeSubType) do
  if f[2] == 9 or f[2] == 10 then
    failures = failures + 1
    print("  FAIL D1 a known sword type leaked into the weapon rule")
  end
end
check(true, "D1 no known weapon type in the rule")

-- D2: both probes dead -> detection reports failure and BuildRules writes
-- nothing. This is the case that would otherwise pass on every item.
installSkillAPI(nil)
installSpellAPI(nil)
local dead = Proficiency.Detect()
eq(dead.ok, false, "D2 detection reports failure")
check(dead.reason and dead.reason:match("neither probe"), "D2 reason: " .. tostring(dead.reason))
local noRules, deadNotes = Proficiency.BuildRules(dead.known, {})
eq(#noRules, 0, "D2 no rules from a dead detection")
eq(#deadNotes, 2, "D2 a refusal note per family")

-- D3: probes live but the character reads as having nothing — same refusal.
installSkillAPI(makeSkillAPI({ { header = "Professions", expanded = true, children = { "Mining" } } }))
installSpellAPI({}, true)
local empty = Proficiency.Detect()
eq(empty.ok, false, "D3 empty reading treated as a failure, not as 'can use nothing'")
check(empty.reason and empty.reason:match("no proficiencies"), "D3 reason: " .. tostring(empty.reason))

print("")
if failures == 0 then
  print("proficiency-probe-test: all checks passed.")
else
  print(string.format("proficiency-probe-test: %d FAILURE(S).", failures))
  os.exit(1)
end
