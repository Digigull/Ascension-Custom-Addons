--[[--------------------------------------------------------------------------
  Proficiency.lua  —  PasslootBiS module: read what this character is actually
  able to equip, and turn the GAPS into "don't roll on it" rules.

  Same shape as Modules/BiSImport.lua: the table/merge/rule-build logic is pure
  Lua 5.1 and self-testable offline (§1-§2), the client probes are isolated in
  §3 behind rawget guards, and the in-game tail (§4) just hangs this table off
  the addon so the "Proficiencies" options page (Core/PassLoot.lua) can drive it.

  Client target: WoW 3.3.5 (Ascension), Lua 5.1. No external libs required.

  What a generated rule looks like
  -------------------------------
  Two rules, mirroring the two-rule split BiSImport uses (a rule ANDs its
  modules together, so one combined rule would match nothing useful):

    "Proficiency: unusable armor"    TypeSubType = every armor subclass this
                                     character has no proficiency for,
                                     EquipSlot  = Back/Shirt/Tabard as
                                     EXCEPTIONS (see below)
    "Proficiency: unusable weapons"  TypeSubType = every weapon subclass this
                                     character has no proficiency for

  Within one module's filter list the entries OR together and exception entries
  AND-NOT (PasslootBiS:EvaluateItem, Core/PassLoot.lua). A filter list made up
  ENTIRELY of exceptions therefore reads as "everything except these", which is
  exactly what the armor rule's EquipSlot list is for: cloaks, shirts and
  tabards are item subclass "Cloth" but need no proficiency, so a plate-only
  character must not pass on its back piece. That carve-out mirrors the same
  decision in PassLootBiS_Scanner/Core/Filter.lua.

  Safety invariants (these are the whole point — a wrong rule silently passes
  on loot you wanted):
    1. Detection failure NEVER produces a rule. If a family (armor / weapons)
       has ZERO detected proficiencies, that is far more likely to mean the
       probe didn't work on this client than that the character can equip
       nothing, so BuildRules refuses and says so.
    2. Only the MISSING subclasses are ever written into a rule. Anything this
       file doesn't know about (Fishing Poles, Miscellaneous weapons, Librams /
       Idols / Totems / Sigils / Relics) is never emitted, so an unknown item
       type is always left alone rather than passed on.
    3. Rules are keyed by a fixed Desc, so regenerating replaces in place
       instead of stacking duplicates.
----------------------------------------------------------------------------]]

--=============================================================================
-- 0. The proficiency table
--    subType numbers come from Modules/TypeSubType.lua's ItemTypes (the values
--    a rule actually stores). Numbers, not display strings, so this is
--    locale-proof on the rule-writing side.
--    `skill` is the enUS skill-line name (Skills window), `spell` the classic
--    proficiency passive's spell id — the two independent probes in §3.
--=============================================================================

local TYPE_WEAPON, TYPE_ARMOR = 2, 3

local Proficiency = {}

Proficiency.TYPE_WEAPON = TYPE_WEAPON
Proficiency.TYPE_ARMOR  = TYPE_ARMOR

-- Ordered: this drives both the report and the rule's filter order.
-- `key` doubles as the enUS item subclass string, which is how the same
-- categories are spelled in PassLootBiS_Scanner/Core/Filter.lua.
Proficiency.LIST = {
  -- weapons (TypeSubType Type 2)
  { key = "One-Handed Axes",   family = "weapon", subType = 2,  spell = 196,   skill = "Axes" },
  { key = "Two-Handed Axes",   family = "weapon", subType = 3,  spell = 197,   skill = "Two-Handed Axes" },
  { key = "Bows",              family = "weapon", subType = 4,  spell = 264,   skill = "Bows" },
  { key = "Guns",              family = "weapon", subType = 5,  spell = 266,   skill = "Guns" },
  { key = "One-Handed Maces",  family = "weapon", subType = 6,  spell = 198,   skill = "Maces" },
  { key = "Two-Handed Maces",  family = "weapon", subType = 7,  spell = 199,   skill = "Two-Handed Maces" },
  { key = "Polearms",          family = "weapon", subType = 8,  spell = 200,   skill = "Polearms" },
  { key = "One-Handed Swords", family = "weapon", subType = 9,  spell = 201,   skill = "Swords" },
  { key = "Two-Handed Swords", family = "weapon", subType = 10, spell = 202,   skill = "Two-Handed Swords" },
  { key = "Staves",            family = "weapon", subType = 11, spell = 227,   skill = "Staves" },
  { key = "Fist Weapons",      family = "weapon", subType = 12, spell = 15590, skill = "Fist Weapons" },
  { key = "Daggers",           family = "weapon", subType = 14, spell = 1180,  skill = "Daggers" },
  { key = "Thrown",            family = "weapon", subType = 15, spell = 2567,  skill = "Thrown" },
  { key = "Crossbows",         family = "weapon", subType = 16, spell = 5011,  skill = "Crossbows" },
  { key = "Wands",             family = "weapon", subType = 17, spell = 5009,  skill = "Wands" },
  -- armor (TypeSubType Type 3). Shields are item type Armor, so they live here
  -- even though the player picks one as an off-hand alternative to a weapon.
  { key = "Cloth",             family = "armor",  subType = 3,  spell = 9078,  skill = "Cloth" },
  { key = "Leather",           family = "armor",  subType = 4,  spell = 9077,  skill = "Leather" },
  { key = "Mail",              family = "armor",  subType = 5,  spell = 8737,  skill = "Mail" },
  { key = "Plate",             family = "armor",  subType = 6,  spell = 750,   skill = "Plate Mail" },
  { key = "Shields",           family = "armor",  subType = 7,  spell = 9116,  skill = "Shield" },
}

-- Deliberately NOT in the table above, and so never written into a rule
-- (invariant 2): Fishing Poles and Miscellaneous weapons (no proficiency gates
-- them), and Librams / Idols / Totems / Sigils / Relic — relic slots are
-- class-flavoured rather than proficiency-gated, and Ascension's classless
-- system makes "which relic can I use" a question this file can't answer.

-- Equip slots that carry an armor subclass but need no armor proficiency.
-- Values from Modules/Equipslot.lua's Choices: Back 3, Shirt 21, Tabard 23.
-- All three are item subclass "Cloth", so without this carve-out a plate-only
-- character would auto-pass its own cloak.
Proficiency.EXEMPT_EQUIP_SLOTS = { 3, 21, 23 }

-- Fixed rule descriptions (invariant 3 — regeneration replaces in place).
Proficiency.DESC_ARMOR   = "Proficiency: unusable armor"
Proficiency.DESC_WEAPONS = "Proficiency: unusable weapons"

-- Rule keys owned by the modules we write into.
local KEY_TYPESUBTYPE = "TypeSubType"   -- Modules/TypeSubType.lua module_key
local KEY_EQUIPSLOT   = "EquipSlot"     -- Modules/Equipslot.lua   module_key

local VALID_ROLL = { pass = true, greed = true, de = true, need = true }

--=============================================================================
-- 1. Merge + summarise  -- pure, no WoW API, unit-testable
--=============================================================================

-- Merge the two probes into one known-set plus a per-proficiency report row.
--   skillNames  set of skill-line names the client listed  (probe A, §3) or nil
--   spellKnown  set of proficiency KEYS the spell probe confirmed (probe B) or nil
--   aliases     optional { [key] = { "localized name", ... } } extra skill-line
--               names to accept, so a non-enUS client can still match probe A
-- Returns: known (set of keys), entries (ordered report rows)
function Proficiency.Resolve(skillNames, spellKnown, aliases)
  local known, entries = {}, {}
  for _, p in ipairs(Proficiency.LIST) do
    local viaSkill = false
    if type(skillNames) == "table" then
      if p.skill and skillNames[p.skill] then viaSkill = true end
      local alias = aliases and aliases[p.key]
      if type(alias) == "table" then
        for _, name in ipairs(alias) do
          if name and skillNames[name] then viaSkill = true end
        end
      end
    end
    local viaSpell = (type(spellKnown) == "table" and spellKnown[p.key] == true) or false
    local isKnown = viaSkill or viaSpell
    if isKnown then known[p.key] = true end
    entries[#entries + 1] = {
      key = p.key, family = p.family, subType = p.subType,
      viaSkill = viaSkill, viaSpell = viaSpell, known = isKnown,
    }
  end
  return known, entries
end

-- Split the proficiency table against a known-set.
-- Returns { armor = {known={p,...}, missing={p,...}}, weapon = {...} }
function Proficiency.Split(known)
  known = known or {}
  local out = {
    armor  = { known = {}, missing = {} },
    weapon = { known = {}, missing = {} },
  }
  for _, p in ipairs(Proficiency.LIST) do
    local bucket = out[p.family]
    if bucket then
      if known[p.key] then
        bucket.known[#bucket.known + 1] = p
      else
        bucket.missing[#bucket.missing + 1] = p
      end
    end
  end
  return out
end

--=============================================================================
-- 2. Rule builder  -- pure. Produces plain rule tables in PasslootBiS's
--    on-disk shape, exactly as a hand-built rule would look:
--      TypeSubType = { { Type, SubType, isException }, ... }   (Modules/TypeSubType.lua)
--      EquipSlot   = { { Value, isException }, ... }           (Modules/Equipslot.lua)
--      Desc (string) + Loot (array of roll strings)            (Core/Constants.lua)
--=============================================================================

-- opts = { roll = "pass"|"greed"|"de"|"need",   -- default "pass"
--          armor = bool,                        -- default true
--          weapons = bool,                      -- default true
--          equipSlotAvailable = bool }          -- default true; false when the
--            "Equip Slot" module is switched off, in which case the armor rule
--            cannot carry its cloak carve-out and is refused rather than built
--            wrong (invariant 1 in spirit: never emit a rule we know is unsafe).
-- Returns: rules (array of rule tables, may be empty), notes (array of strings
--          explaining every family that was NOT built)
function Proficiency.BuildRules(known, opts)
  opts = opts or {}
  local roll = opts.roll
  if not (type(roll) == "string" and VALID_ROLL[roll]) then roll = "pass" end
  local wantArmor   = opts.armor ~= false
  local wantWeapons = opts.weapons ~= false
  local equipSlotOK = opts.equipSlotAvailable ~= false

  local split = Proficiency.Split(known)
  local rules, notes = {}, {}

  local function build(family, want, desc)
    if not want then return end
    local bucket = split[family]
    -- Invariant 1: zero detected proficiencies in a family means the probe
    -- almost certainly failed, not that the character can equip nothing.
    if #bucket.known == 0 then
      notes[#notes + 1] = string.format(
        "No %s proficiency detected at all - refusing to build the %s rule (it would pass on every %s item).",
        family, family, family)
      return
    end
    if #bucket.missing == 0 then
      notes[#notes + 1] = string.format(
        "Proficient with every %s type - no %s rule needed.", family, family)
      return
    end
    if family == "armor" and not equipSlotOK then
      notes[#notes + 1] =
        "The \"Equip Slot\" module is disabled, so the armor rule cannot exempt cloaks/shirts/tabards " ..
        "(all item subclass Cloth) - skipping it. Enable that module and generate again."
      return
    end

    local filters = {}
    for _, p in ipairs(bucket.missing) do
      filters[#filters + 1] = {
        (family == "armor") and TYPE_ARMOR or TYPE_WEAPON,
        p.subType,
        false,   -- normal filter (these OR together)
      }
    end
    local rule = {
      Desc = desc,
      Loot = { roll },
      [KEY_TYPESUBTYPE] = filters,
    }
    if family == "armor" then
      local exempt = {}
      for _, slotValue in ipairs(Proficiency.EXEMPT_EQUIP_SLOTS) do
        exempt[#exempt + 1] = { slotValue, true }   -- exception => "anything but"
      end
      rule[KEY_EQUIPSLOT] = exempt
    end
    rules[#rules + 1] = rule
  end

  build("armor", wantArmor, Proficiency.DESC_ARMOR)
  build("weapon", wantWeapons, Proficiency.DESC_WEAPONS)
  return rules, notes
end

-- Write built rules into a rules array. Same-Desc rules are replaced IN PLACE
-- (keeping their position in the priority order, and their Disabled flag);
-- otherwise the rule is appended. Mutates `rules`; returns how many it wrote.
function Proficiency.ApplyToRules(rules, built)
  if type(rules) ~= "table" or type(built) ~= "table" then return 0 end
  local written = 0
  for _, rule in ipairs(built) do
    local at
    for i = 1, #rules do
      if rules[i] and rules[i].Desc == rule.Desc then at = i break end
    end
    if at then
      -- Keep the user's on/off toggle across a regenerate.
      if rules[at].Disabled then rule.Disabled = rules[at].Disabled end
      rules[at] = rule
    else
      rules[#rules + 1] = rule
    end
    written = written + 1
  end
  return written
end

-- Drop both generated rules from a rules array. Returns how many it removed.
function Proficiency.RemoveFromRules(rules)
  if type(rules) ~= "table" then return 0 end
  local removed = 0
  for i = #rules, 1, -1 do
    local desc = rules[i] and rules[i].Desc
    if desc == Proficiency.DESC_ARMOR or desc == Proficiency.DESC_WEAPONS then
      table.remove(rules, i)
      removed = removed + 1
    end
  end
  return removed
end

--=============================================================================
-- 3. Client probes  -- WoW-only, each guarded so this file still loads under
--    bare Lua 5.1. Two INDEPENDENT sources; a proficiency counts as known if
--    either says so, and the report shows which one found it, so a bad probe
--    on this client is visible instead of silently shaping the rules.
--=============================================================================

-- Probe A: the Skills window's own data (GetSkillLineInfo). Returns a set of
-- skill-line names, or nil + reason.
function Proficiency.ScanSkillLines()
  local GetNum  = rawget(_G, "GetNumSkillLines")
  local GetInfo = rawget(_G, "GetSkillLineInfo")
  if type(GetNum) ~= "function" or type(GetInfo) ~= "function" then
    return nil, "GetSkillLineInfo is not available on this client"
  end
  local Expand   = rawget(_G, "ExpandSkillHeader")
  local Collapse = rawget(_G, "CollapseSkillHeader")

  -- A COLLAPSED header hides its children from GetNumSkillLines entirely, so a
  -- character who has "Weapon Skills" collapsed would read as having no weapon
  -- proficiency at all — the exact failure that silently produces a pass-on-
  -- everything rule. Expand all, read, then re-collapse only the headers that
  -- were collapsed. Matching by NAME because indices shift as headers expand,
  -- and re-collapsing BACKWARDS because collapsing at index i only removes
  -- entries after i.
  local collapsed, hadCollapsed = {}, false
  if type(Expand) == "function" then
    for i = 1, GetNum() do
      local name, isHeader, isExpanded = GetInfo(i)
      if isHeader and not isExpanded then
        collapsed[name or ""] = true
        hadCollapsed = true
      end
    end
    Expand(0)
  end

  local seen = {}
  for i = 1, GetNum() do
    local name, isHeader = GetInfo(i)
    if name and not isHeader then seen[name] = true end
  end

  if hadCollapsed and type(Collapse) == "function" then
    for i = GetNum(), 1, -1 do
      local name, isHeader = GetInfo(i)
      if isHeader and collapsed[name or ""] then Collapse(i) end
    end
  end
  return seen
end

-- Probe B: the classic proficiency passives. Returns a set of proficiency KEYS,
-- plus the method string that produced it, or nil + reason.
function Proficiency.ScanKnownSpells()
  local SpellInfo = rawget(_G, "GetSpellInfo")
  if type(SpellInfo) ~= "function" then
    return nil, "GetSpellInfo is not available on this client"
  end
  local IsKnown = rawget(_G, "IsSpellKnown")
  local out, method = {}, nil
  for _, p in ipairs(Proficiency.LIST) do
    local ok, name = pcall(SpellInfo, p.spell)
    if ok and name then
      local isKnown
      if type(IsKnown) == "function" then
        local ok2, res = pcall(IsKnown, p.spell)
        if ok2 and res ~= nil then
          isKnown = res and true or false
          method = method or "IsSpellKnown(spellID)"
        end
      end
      if isKnown == nil then
        -- 3.3.5 idiom: a NAME lookup resolves only for a spell the player
        -- knows, while the ID lookup above resolves for any spell in the
        -- client's data. Weaker than IsSpellKnown (a same-named spell would
        -- fool it), which is why the report shows the method used.
        local ok3, byName = pcall(SpellInfo, name)
        isKnown = (ok3 and byName ~= nil) or false
        method = method or "GetSpellInfo(name) spellbook lookup"
      end
      if isKnown then out[p.key] = true end
    end
  end
  return out, (method or "no usable spell probe")
end

-- Run both probes and merge. Returns a report table:
--   { known = {key=true,...}, entries = {row,...}, split = ...,
--     skillOK/spellOK = bool, skillNote/spellNote = string,
--     ok = bool, reason = string|nil }
function Proficiency.Detect()
  local skillNames, skillNote = Proficiency.ScanSkillLines()
  local spellKnown, spellNote = Proficiency.ScanKnownSpells()

  -- Accept the client's own localized spell name as an extra skill-line alias.
  -- Free robustness on a non-enUS client: the armor names match one-for-one
  -- ("Plate Mail", "Shield", ...). The one-handed weapon spells are named
  -- "One-Handed Axes" where the skill line is just "Axes", so enUS still leans
  -- on the hardcoded `skill` field — the same enUS assumption
  -- PassLootBiS_Scanner/Core/Filter.lua already makes.
  local aliases
  local SpellInfo = rawget(_G, "GetSpellInfo")
  if type(SpellInfo) == "function" then
    aliases = {}
    for _, p in ipairs(Proficiency.LIST) do
      local ok, name = pcall(SpellInfo, p.spell)
      if ok and name then aliases[p.key] = { name } end
    end
  end

  local known, entries = Proficiency.Resolve(skillNames, spellKnown, aliases)
  local report = {
    known      = known,
    entries    = entries,
    split      = Proficiency.Split(known),
    skillOK    = skillNames ~= nil,
    skillNote  = skillNames and "skill lines" or (skillNote or "unavailable"),
    spellOK    = spellKnown ~= nil,
    spellNote  = spellNote or "unavailable",
    ok         = true,
  }
  if not (report.skillOK or report.spellOK) then
    report.ok = false
    report.reason = "neither probe is available on this client"
  elseif not next(known) then
    report.ok = false
    report.reason = "both probes ran but found no proficiencies at all"
  end
  return report
end

--=============================================================================
-- 4. In-game hookup  -- WoW-only; skipped under bare Lua 5.1.
--    The options page + rule-list refresh live addon-side (Core/PassLoot.lua),
--    so this file stays free of UI code.
--=============================================================================

if rawget(_G, "LibStub") then
  local AceAddon = LibStub("AceAddon-3.0", true)
  local addon = AceAddon and AceAddon:GetAddon("PasslootBiS", true)
  if addon then addon.Proficiency = Proficiency end
end

--=============================================================================
-- 5. Offline self-test  -- run under Lua 5.1, guarded in-game.
--    Usage:  lua5.1 -e 'PROFICIENCY_SELFTEST=true' Proficiency.lua
--=============================================================================

if rawget(_G, "PROFICIENCY_SELFTEST") then
  local function assertEq(got, want, label)
    if got ~= want then
      error(("%s: got %q want %q"):format(label, tostring(got), tostring(want)))
    end
  end
  local function setOf(...)
    local s = {}
    for _, v in ipairs({ ... }) do s[v] = true end
    return s
  end
  -- Find a rule by Desc in a built list.
  local function ruleFor(rules, desc)
    for _, r in ipairs(rules) do if r.Desc == desc then return r end end
  end
  -- Does a TypeSubType filter list contain {type, sub} as a normal filter?
  local function hasFilter(rule, ty, sub)
    for _, f in ipairs(rule.TypeSubType or {}) do
      if f[1] == ty and f[2] == sub and not f[3] then return true end
    end
    return false
  end

  -- R1: the skill-line probe's enUS names resolve, including the ones whose
  -- skill name differs from the item subclass ("Swords" -> One-Handed Swords).
  local known1 = Proficiency.Resolve(
    setOf("Swords", "Two-Handed Swords", "Plate Mail", "Shield", "Cloth", "Leather", "Mail"), nil, nil)
  assertEq(known1["One-Handed Swords"], true, "R1 Swords -> One-Handed Swords")
  assertEq(known1["Two-Handed Swords"], true, "R1 two-handers")
  assertEq(known1["Plate"], true, "R1 Plate Mail -> Plate")
  assertEq(known1["Shields"], true, "R1 Shield -> Shields")
  assertEq(known1["Daggers"], nil, "R1 unlisted stays unknown")

  -- R2: the spell probe alone resolves, keyed by proficiency key, and the
  -- report rows record WHICH probe found each one.
  local known2, entries2 = Proficiency.Resolve(nil, setOf("Daggers", "Cloth"), nil)
  assertEq(known2["Daggers"], true, "R2 spell probe")
  local sawDagger = false
  for _, e in ipairs(entries2) do
    if e.key == "Daggers" then
      sawDagger = true
      assertEq(e.viaSpell, true, "R2 row viaSpell")
      assertEq(e.viaSkill, false, "R2 row viaSkill")
    end
  end
  assertEq(sawDagger, true, "R2 dagger row present")
  assertEq(#entries2, #Proficiency.LIST, "R2 one row per proficiency")

  -- R3: aliases let a localized skill-line name match.
  local known3 = Proficiency.Resolve(setOf("Dolche"), nil, { ["Daggers"] = { "Dolche" } })
  assertEq(known3["Daggers"], true, "R3 alias match")

  -- B1: a plate/sword character. The armor rule lists the three armor classes
  -- it can't wear and carries the cloak/shirt/tabard carve-out; the weapon rule
  -- lists every weapon type it lacks and nothing it has.
  local knownB = setOf("Plate", "Shields", "One-Handed Swords", "Two-Handed Swords")
  local rulesB, notesB = Proficiency.BuildRules(knownB, { roll = "pass" })
  assertEq(#rulesB, 2, "B1 two rules")
  assertEq(#notesB, 0, "B1 no notes")
  local armorB = ruleFor(rulesB, Proficiency.DESC_ARMOR)
  local wpnB   = ruleFor(rulesB, Proficiency.DESC_WEAPONS)
  assertEq(armorB.Loot[1], "pass", "B1 roll action")
  assertEq(#armorB.TypeSubType, 3, "B1 armor filters (Cloth/Leather/Mail)")
  assertEq(hasFilter(armorB, 3, 3), true, "B1 cloth filter")
  assertEq(hasFilter(armorB, 3, 6), false, "B1 plate NOT filtered")
  assertEq(hasFilter(armorB, 3, 7), false, "B1 shields NOT filtered")
  assertEq(#armorB.EquipSlot, 3, "B1 three equip-slot exceptions")
  for _, f in ipairs(armorB.EquipSlot) do
    assertEq(f[2], true, "B1 equip-slot entries are exceptions")
  end
  assertEq(armorB.EquipSlot[1][1], 3, "B1 back slot exempt")
  assertEq(hasFilter(wpnB, 2, 9), false, "B1 1h swords NOT filtered")
  assertEq(hasFilter(wpnB, 2, 14), true, "B1 daggers filtered")
  assertEq(hasFilter(wpnB, 2, 17), true, "B1 wands filtered")
  assertEq(#wpnB.TypeSubType, 13, "B1 weapon filters (15 types - 2 known)")
  assertEq(wpnB.EquipSlot, nil, "B1 weapon rule has no equip-slot list")

  -- B2 (invariant 1): nothing detected -> NO rules, and a note per family
  -- saying why. This is the case that would otherwise pass on all loot.
  local rulesB2, notesB2 = Proficiency.BuildRules({}, {})
  assertEq(#rulesB2, 0, "B2 refuses to build from an empty detection")
  assertEq(#notesB2, 2, "B2 one note per family")
  assert(notesB2[1]:match("^No armor proficiency detected"), "B2 armor note")
  assert(notesB2[2]:match("^No weapon proficiency detected"), "B2 weapon note")

  -- B3: a family with no gaps produces no rule, but the other still builds.
  local knownB3 = setOf("Cloth", "Leather", "Mail", "Plate", "Shields", "Daggers")
  local rulesB3, notesB3 = Proficiency.BuildRules(knownB3, {})
  assertEq(#rulesB3, 1, "B3 only the weapon rule")
  assertEq(rulesB3[1].Desc, Proficiency.DESC_WEAPONS, "B3 which rule")
  assertEq(#notesB3, 1, "B3 one note")
  assert(notesB3[1]:match("every armor type"), "B3 armor note")

  -- B4: family toggles and roll action.
  local rulesB4 = Proficiency.BuildRules(knownB, { armor = false, roll = "greed" })
  assertEq(#rulesB4, 1, "B4 weapons only")
  assertEq(rulesB4[1].Loot[1], "greed", "B4 greed action")
  local rulesB4b = Proficiency.BuildRules(knownB, { roll = "nonsense" })
  assertEq(ruleFor(rulesB4b, Proficiency.DESC_ARMOR).Loot[1], "pass", "B4b bad action -> pass")

  -- B5: without the Equip Slot module the armor rule is refused (it could not
  -- carry the cloak carve-out), while the weapon rule is unaffected.
  local rulesB5, notesB5 = Proficiency.BuildRules(knownB, { equipSlotAvailable = false })
  assertEq(#rulesB5, 1, "B5 weapons only")
  assertEq(rulesB5[1].Desc, Proficiency.DESC_WEAPONS, "B5 which rule")
  assert(notesB5[1]:match("Equip Slot"), "B5 note names the module")

  -- A1: applying writes both rules; re-applying REPLACES in place (invariant 3)
  -- rather than stacking duplicates, keeps their position, and preserves the
  -- user's Disabled toggle.
  local rules = { { Desc = "Greed on Green", Loot = { "greed" } } }
  assertEq(Proficiency.ApplyToRules(rules, rulesB), 2, "A1 wrote two")
  assertEq(#rules, 3, "A1 appended after the existing rule")
  assertEq(rules[1].Desc, "Greed on Green", "A1 existing rule untouched")
  assertEq(rules[2].Desc, Proficiency.DESC_ARMOR, "A1 armor rule position")
  rules[2].Disabled = true
  local again = Proficiency.BuildRules(knownB, { roll = "greed" })
  assertEq(Proficiency.ApplyToRules(rules, again), 2, "A1 rewrote two")
  assertEq(#rules, 3, "A1 no duplicates on regenerate")
  assertEq(rules[2].Loot[1], "greed", "A1 new action applied in place")
  assertEq(rules[2].Disabled, true, "A1 Disabled preserved")

  -- A2: removal takes out exactly the two generated rules.
  assertEq(Proficiency.RemoveFromRules(rules), 2, "A2 removed two")
  assertEq(#rules, 1, "A2 only the hand-made rule is left")
  assertEq(rules[1].Desc, "Greed on Green", "A2 kept the right one")
  assertEq(Proficiency.RemoveFromRules(rules), 0, "A2 idempotent")

  -- S1: Split buckets every proficiency exactly once.
  local split = Proficiency.Split(knownB)
  assertEq(#split.armor.known + #split.armor.missing +
           #split.weapon.known + #split.weapon.missing, #Proficiency.LIST, "S1 total")
  assertEq(#split.armor.known, 2, "S1 plate + shields")
  assertEq(#split.weapon.known, 2, "S1 both sword types")

  print("Proficiency self-test: all vectors passed.")
end

return Proficiency
