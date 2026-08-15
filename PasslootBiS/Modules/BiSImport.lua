--[[--------------------------------------------------------------------------
  BiSImport.lua  —  PasslootBiS module: import a BisBeard BiS list as PasslootBiS rules

  Implements the PLBIS1 protocol (see docs/protocol.md). Parse / validate /
  rule-build / apply are all pure Lua and unit-testable offline (Lua 5.1); a
  small in-game tail (§5) attaches this table to the addon so the "Import BiS"
  options panel (Core/PassLoot.lua) can call BiSImport.Import against the live
  rules array. The panel + rule-list refresh live addon-side by design, so this
  file stays free of WoW-API and UI code.

  Client target: WoW 3.3.5 (Ascension), Lua 5.1. No external libs required.

  Design invariants (frozen — see research §2.4a / §2.5, protocol §1, §8):
    * Match on item ID and exact name ONLY. Never emit ilvl / quality / stat
      filters — link-derived stats are unreliable on this client.
    * Two separate rules: ID items and name items. A single rule ANDs its
      modules together and would match nothing.
    * All BisBeard-side resolution (baseItemId ?? id, classification, name
      lookup) happened converter-side. This module trusts the two pre-split
      lists and only dedupes/validates.
----------------------------------------------------------------------------]]

local ADDON_NAME = ...  -- unused for now; kept for AceAddon:NewModule wiring

--=============================================================================
-- 0. Constants
--=============================================================================

local PREFIX_PLAIN = "PLBIS1:"
local PREFIX_ZIP   = "PLBIS1Z:"
local INT32_MAX    = 2147483647

-- roll= token -> PasslootBiS Loot value (protocol §6 / PasslootBiS RollOrder)
local ROLL_VALID = { need = true, greed = true, de = true, pass = true }

--=============================================================================
-- 1. String helpers (protocol §5.1)  -- pure, no WoW API, unit-testable
--=============================================================================

local function trim(s)
  return (tostring(s):gsub("^%s*(.-)%s*$", "%1"))
end

-- Unescape a single, ALREADY-SPLIT element. Lenient: unknown "\x" stays "\x".
local function unescape(s)
  return (s:gsub("\\(.)", function(c)
    if c == "\\" or c == ";" or c == "|" then return c end
    return "\\" .. c
  end))
end

-- Split on an UNESCAPED single-char delimiter, honouring backslash escapes.
-- Splits first; callers unescape the pieces afterwards (protocol §5).
local function splitUnescaped(s, delim)
  local out, buf, i, n = {}, {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and i < n then
      buf[#buf + 1] = s:sub(i, i + 1); i = i + 2
    elseif c == delim then
      out[#out + 1] = table.concat(buf); buf = {}; i = i + 1
    else
      buf[#buf + 1] = c; i = i + 1
    end
  end
  out[#out + 1] = table.concat(buf)
  return out
end

-- Plain split (no escape handling) — used for the digit-only ids list.
local function splitPlain(s, delim)
  local out = {}
  local pat = "([^" .. delim .. "]+)"
  for piece in s:gmatch(pat) do out[#out + 1] = piece end
  return out
end

--=============================================================================
-- 2. Parser + validator (protocol §3, §9)
--    Returns:  parsed table  |  nil, errString
--    parsed = { v=1, roll="need", desc="...", ids={num,...}, names={"...",...} }
--=============================================================================

local BiSImport = {}

-- Parse the optional additive `farm` field (protocol §11) into ranked rows.
-- Value shape: `<row>|<row>|...`, each row `category=source=name1=name2=...`,
-- already ranked converter-side (highest yield first). Display-only metadata
-- for the Farm Plan page — never feeds the matching rules. Split rows on `|`,
-- then fields on `=`, then unescape (split-before-unescape, protocol §5). Count
-- per source is derived as the number of item names, so it can never disagree
-- with the list. Malformed rows (fewer than category+source+1 name) are skipped.
local function parseFarm(value)
  local rows = {}
  for _, rowStr in ipairs(splitUnescaped(value, "|")) do
    local parts = splitUnescaped(rowStr, "=")
    if #parts >= 3 then
      local category = trim(unescape(parts[1]))
      local source   = trim(unescape(parts[2]))
      local items = {}
      for i = 3, #parts do
        local nm = trim(unescape(parts[i]))
        if nm ~= "" then items[#items + 1] = nm end
      end
      if source ~= "" and #items > 0 then
        rows[#rows + 1] = { category = category, source = source,
                            items = items, count = #items }
      end
    end
  end
  return rows
end

-- Parse the optional additive `cand` field (protocol §3.4) into per-slot pools.
-- Value shape: `<row>|<row>|...`, each row one candidate
-- `slot=name=score=source=version`, already ordered converter-side (grouped by
-- slot in paperdoll order, best score first within a slot). Display-only metadata
-- for the Alternatives page — the names here are display labels, NOT the matching
-- `names` list (protocol §8). Split rows on `|`, fields on `=`, then unescape
-- (split-before-unescape, protocol §5). Consecutive rows for the same slot are
-- grouped, preserving first-seen slot order; count per slot is derived. Malformed
-- rows (fewer than slot+name) are skipped.
local function parseCand(value)
  local order, bySlot = {}, {}
  for _, rowStr in ipairs(splitUnescaped(value, "|")) do
    local parts = splitUnescaped(rowStr, "=")
    if #parts >= 2 then
      local slot = trim(unescape(parts[1]))
      local name = trim(unescape(parts[2]))
      if slot ~= "" and name ~= "" then
        local bucket = bySlot[slot]
        if not bucket then
          bucket = { slot = slot, candidates = {} }
          bySlot[slot] = bucket
          order[#order + 1] = bucket
        end
        bucket.candidates[#bucket.candidates + 1] = {
          name    = name,
          score   = parts[3] and trim(unescape(parts[3])) or "",
          source  = parts[4] and trim(unescape(parts[4])) or "",
          version = parts[5] and trim(unescape(parts[5])) or "",
          -- Additive Stage-2 promotion fields (protocol §3.4). Absent on older
          -- strings (5-field rows) -> nil, so the item is simply not promotable.
          -- These are converter-pre-classified; the addon copies them into a rule
          -- without resolving anything (invariant 3).
          promoteKind = parts[6] and trim(unescape(parts[6])) or nil,
          promoteKey  = parts[7] and trim(unescape(parts[7])) or nil,
        }
      end
    end
  end
  -- derive per-slot count so it can never disagree with the list
  for _, bucket in ipairs(order) do bucket.count = #bucket.candidates end
  return order  -- { { slot, count, candidates = { {name,score,source,version}, ... } }, ... }
end

-- Parse the optional additive `mgr` field (protocol §3.5) into per-item manager
-- records. Value shape: `<row>|<row>|...`, each row one list item
-- `kind=key=name=source=category`, in slot order (deduped 1:1 with the two match
-- rules converter-side). Display/edit metadata for the BiS Manager page: `kind`
-- (`id`/`name`) + `key` (the real id string / exact name) tie each item back to a
-- specific rule entry when the user removes it; `source`/`category` drive the
-- source-grouped view; `name` is a display label so an ID item shows its name
-- without a client GetItemInfo lookup. Split rows on `|`, fields on `=`, then
-- unescape (split-before-unescape, protocol §5). Rows missing kind or key are
-- skipped. This NEVER feeds the matching rules directly (invariants 1-2) — the
-- manager edits the rule the import already built, keyed by kind/key (invariant 3).
local function parseManage(value)
  local rows = {}
  for _, rowStr in ipairs(splitUnescaped(value, "|")) do
    local parts = splitUnescaped(rowStr, "=")
    if #parts >= 2 then
      local kind = trim(unescape(parts[1]))
      local key  = trim(unescape(parts[2]))
      if (kind == "id" or kind == "name") and key ~= "" then
        -- Additive display fields (protocol §3.5): [6]=slot, [7]=score. Absent on
        -- rows from a lean/enriched index; drive the BiS Manager's slot/score sort.
        local slot = parts[6] and trim(unescape(parts[6])) or ""
        local score = nil
        if parts[7] then
          score = tonumber(trim(unescape(parts[7])))
        end
        rows[#rows + 1] = {
          kind     = kind,
          key      = key,
          name     = parts[3] and trim(unescape(parts[3])) or key,
          source   = parts[4] and trim(unescape(parts[4])) or "",
          category = parts[5] and trim(unescape(parts[5])) or "",
          slot     = (slot ~= "") and slot or nil,
          score    = score,
        }
      end
    end
  end
  return rows
end

function BiSImport.Parse(raw)
  if type(raw) ~= "string" then
    return nil, "no import string provided"
  end
  local str = trim(raw)

  ------------------------------------------------------------------ prefix
  if str:sub(1, #PREFIX_ZIP) == PREFIX_ZIP then
    return nil, "compressed imports (PLBIS1Z) are not supported in this version"
  end
  if str:sub(1, #PREFIX_PLAIN) ~= PREFIX_PLAIN then
    return nil, "not a PLBIS import string"
  end
  local payload = str:sub(#PREFIX_PLAIN + 1)

  ------------------------------------------------------------------ fields
  local fields = {}
  for _, field in ipairs(splitUnescaped(payload, ";")) do
    local eq = field:find("=", 1, true)   -- first '=' only (protocol §3)
    if eq then
      local key = field:sub(1, eq - 1)
      local val = field:sub(eq + 1)
      fields[key] = val                   -- last-wins on dup keys
    end
    -- fields with no '=' are ignored
  end

  ------------------------------------------------------------------ v / roll
  local v = fields.v
  if v ~= "1" then
    return nil, "unsupported payload version: " .. tostring(v)
  end

  local roll = fields.roll
  if not (roll and ROLL_VALID[roll]) then
    return nil, "invalid roll action: " .. tostring(roll)
  end

  ------------------------------------------------------------------ ids
  local ids, seenId = {}, {}
  if fields.ids and fields.ids ~= "" then
    for _, tok in ipairs(splitPlain(fields.ids, ",")) do
      tok = trim(tok)
      if not tok:match("^%d+$") then
        return nil, "invalid item id token: '" .. tok .. "'"
      end
      local num = tonumber(tok)
      if not num or num <= 0 then
        return nil, "invalid item id: '" .. tok .. "'"
      end
      if num > INT32_MAX then
        -- A resolved real id never exceeds int32; this means the converter
        -- failed to resolve a composite id (research §2.4). Fail loudly.
        return nil, "item id exceeds int32 (unresolved composite?): " .. tok
      end
      if not seenId[num] then           -- dedupe, first-wins (protocol §3.2)
        seenId[num] = true
        ids[#ids + 1] = num
      end
    end
  end

  ------------------------------------------------------------------ names
  local names, seenName = {}, {}
  if fields.names and fields.names ~= "" then
    for _, part in ipairs(splitUnescaped(fields.names, "|")) do
      local name = trim(unescape(part))
      if name ~= "" and not seenName[name] then
        seenName[name] = true
        names[#names + 1] = name
      end
      -- empty-after-unescape entries are skipped (protocol §9)
    end
  end

  local desc = fields.desc and trim(unescape(fields.desc)) or nil

  local farm = nil
  if fields.farm and fields.farm ~= "" then
    farm = parseFarm(fields.farm)   -- display-only; absent/unknown -> nil (§11)
  end

  local cand = nil
  if fields.cand and fields.cand ~= "" then
    cand = parseCand(fields.cand)   -- display-only; absent/unknown -> nil (§11)
  end

  local manage = nil
  if fields.mgr and fields.mgr ~= "" then
    manage = parseManage(fields.mgr)  -- display/edit-only; absent/unknown -> nil (§3.5)
  end

  ------------------------------------------------------------------ non-empty
  -- A string must carry something actionable, but not necessarily a match rule:
  -- an alternatives-only build (no BiS picks) has empty ids/names and just a cand
  -- block, which the Alternatives page turns into rolls via "roll on alternatives".
  -- Only a truly empty string (no ids, no names, no cand) is nothing to import.
  if #ids == 0 and #names == 0 and not (cand and #cand > 0) then
    return nil, "no items to import"
  end

  return { v = 1, roll = roll, desc = desc, ids = ids, names = names,
           farm = farm, cand = cand, manage = manage }
end

--=============================================================================
-- 3. Rule builders (protocol §8)
--    Produce plain rule tables in PasslootBiS's on-disk shape.
--    VERIFIED against the vendored PasslootBiS source (upstream ec0dc3e):
--      * ItemID  module_key = "ItemIDs"; tuple { idString, false, isException }.
--        GetMatch reads tonumber(RuleValue[Index][1]) vs itemObj.id; index 3 is
--        isException (Modules/ItemID.lua:104-108,142-167). handleAddRemove
--        inserts { command, false } (Core/PasslootBiS.lua:101) — index 3 left nil,
--        which is falsy-equivalent to our explicit false and to protocol §8.
--      * ItemName module_key = "Items";  tuple { name, "Exact", isException }.
--        GetMatch reads RuleValue[Index][2] as the match mode ("Exact"/"Partial")
--        and RuleValue[Index][1] as the name (Modules/ItemName.lua:124-134,
--        183-202). handleAddRemove inserts { command, "Exact", false }
--        (Core/PasslootBiS.lua:106).
--      * Rule schema: Desc (string) + Loot (array of roll strings), per
--        PasslootBiS.DefaultTemplate / RollOrder (Core/Constants.lua:4-22).
--    Conclusion: the builders below are CORRECT as written — no index changes
--    were needed. See docs/protocol.md §8 and CLAUDE.md for the audit trail.
--=============================================================================

local function descFor(parsed, suffix)
  local base = (parsed.desc and parsed.desc ~= "") and parsed.desc
               or "PLBIS import"
  return base .. " " .. suffix
end

function BiSImport.BuildIDRule(parsed)
  if #parsed.ids == 0 then return nil end
  local ItemIDs = {}
  for _, num in ipairs(parsed.ids) do
    ItemIDs[#ItemIDs + 1] = { tostring(num), false, false } -- {idStr, unused, isException}
  end
  return {
    Desc    = descFor(parsed, "(IDs)"),
    Loot    = { parsed.roll },
    ItemIDs = ItemIDs,
  }
end

function BiSImport.BuildNameRule(parsed)
  if #parsed.names == 0 then return nil end
  local Items = {}
  for _, name in ipairs(parsed.names) do
    Items[#Items + 1] = { name, "Exact", false }           -- {name, matchMode, isException}
  end
  return {
    Desc  = descFor(parsed, "(Suffix)"),
    Loot  = { parsed.roll },
    Items = Items,
  }
end

-- "Roll on alternatives" (Stage 2, feature2-research §8.7): collect the user's
-- selected per-slot alternatives into { ids = {...}, names = {...} } for rule
-- building. `pools` is the parsed cand block (BiSImport.Parse .cand); `isSelected`
-- is a predicate (poolIndex, candIndex) -> bool. Each candidate carries the
-- converter's PRE-CLASSIFIED promoteKind/promoteKey, so this only copies — it never
-- resolves (invariant 3). id-kind -> ids (int32-guarded, mirrors the parser);
-- name-kind -> names (promoteKey is the exact name). Non-promotable candidates
-- (no/other promoteKind, e.g. an older 5-field cand row) are skipped. Deduped.
function BiSImport.CollectPromoted(pools, isSelected)
  local ids, names, seenId, seenName = {}, {}, {}, {}
  for pi, pool in ipairs(pools or {}) do
    for ci, c in ipairs(pool.candidates or {}) do
      if isSelected(pi, ci) then
        if c.promoteKind == "id" then
          local n = tonumber(c.promoteKey)
          if n and n > 0 and n <= INT32_MAX and not seenId[n] then
            seenId[n] = true
            ids[#ids + 1] = n
          end
        elseif c.promoteKind == "name" then
          local nm = c.promoteKey
          if nm and nm ~= "" and not seenName[nm] then
            seenName[nm] = true
            names[#names + 1] = nm
          end
        end
      end
    end
  end
  return { ids = ids, names = names }
end

-- Select which of a list's items should AUTO-ROLL, by drop-source category
-- (Feature 3 refinement). Only some sources produce a loot-roll window — dungeon
-- and raid bosses, forged drops — so rolling on a vendor / reputation / crafting
-- item is pointless (you never see a roll frame for it). Given the parsed `manage`
-- records (each carries the converter's `category`) and a set of roll-eligible
-- categories, return { ids = {num,...}, names = {str,...} } for the items that
-- should become match rules. The rest are kept by the caller as data (the BiS
-- Manager still shows them) but stay out of the roll rules. Pure; mirrors the
-- id/name split + int32 guard + dedupe of the parser. This is NOT resolution
-- (invariant 3 intact — the converter already classified every item); it only
-- CHOOSES which pre-classified items to roll on, a curation step.
function BiSImport.SelectRollItems(manage, categorySet)
  local ids, names, seenId, seenName = {}, {}, {}, {}
  for _, rec in ipairs(manage or {}) do
    if type(rec) == "table" and categorySet[rec.category or ""] then
      if rec.kind == "id" then
        local n = tonumber(rec.key)
        if n and n > 0 and n <= INT32_MAX and not seenId[n] then
          seenId[n] = true
          ids[#ids + 1] = n
        end
      elseif rec.kind == "name" then
        local nm = rec.key
        if nm and nm ~= "" and not seenName[nm] then
          seenName[nm] = true
          names[#names + 1] = nm
        end
      end
    end
  end
  return { ids = ids, names = names }
end

--=============================================================================
-- 4. Apply to a rules array (protocol §7: replace / merge)  -- pure
--    Operates on a rules array PASSED IN by the caller (the addon passes
--    PasslootBiS.db.profile.Rules; the self-test passes a plain table). No
--    globals, so this stays offline-unit-testable.
--=============================================================================

local function findRuleByDesc(rules, desc)
  for i = 1, #rules do
    if rules[i] and rules[i].Desc == desc then return i end
  end
  return nil
end

-- Union src list into dst rule under dbkey, deduping by a key function.
local function mergeList(dstRule, dbkey, srcList, keyOf)
  dstRule[dbkey] = dstRule[dbkey] or {}
  local seen = {}
  for _, tuple in ipairs(dstRule[dbkey]) do seen[keyOf(tuple)] = true end
  for _, tuple in ipairs(srcList) do
    local k = keyOf(tuple)
    if not seen[k] then
      seen[k] = true
      dstRule[dbkey][#dstRule[dbkey] + 1] = tuple
    end
  end
end

local KEY_ID   = function(t) return tostring(t[1]) end
local KEY_NAME = function(t) return t[1] end

-- Sort a rule's list to match PassLoot's own on-disk order, so an imported rule
-- is byte-identical to a hand-edited one (protocol §7). These mirror the
-- compare() funcs in Modules/ItemID.lua and Modules/ItemName.lua exactly.
local function sortRuleList(rule, dbkey)
  local list = rule[dbkey]
  if type(list) ~= "table" then return end
  if dbkey == "ItemIDs" then
    table.sort(list, function(a, b) return a[1]:lower() < b[1]:lower() end)
  elseif dbkey == "Items" then
    table.sort(list, function(a, b)
      local al, bl = a[1]:lower(), b[1]:lower()
      return (al < bl) or (al == bl and a[2] < b[2])
    end)
  end
end

-- mode: "replace" (default) or "merge". Mutates `rules` in place.
-- returns: ok(bool), message(string), rulesApplied(number)
function BiSImport.ApplyToRules(parsed, mode, rules)
  mode = mode or "replace"
  if type(rules) ~= "table" then return false, "no rules table provided" end

  local built = {
    { rule = BiSImport.BuildIDRule(parsed),   dbkey = "ItemIDs", keyOf = KEY_ID },
    { rule = BiSImport.BuildNameRule(parsed), dbkey = "Items",   keyOf = KEY_NAME },
  }

  local applied = 0
  for _, b in ipairs(built) do
    if b.rule then
      local idx = findRuleByDesc(rules, b.rule.Desc)
      local target
      if mode == "merge" and idx then
        mergeList(rules[idx], b.dbkey, b.rule[b.dbkey], b.keyOf)
        rules[idx].Loot = rules[idx].Loot or b.rule.Loot
        target = idx
      else
        -- replace: overwrite an existing same-Desc rule, else append
        target = idx or (#rules + 1)
        rules[target] = b.rule
      end
      sortRuleList(rules[target], b.dbkey)
      applied = applied + 1
    end
  end

  if applied == 0 then
    -- Alternatives-only import: no match rules, but a cand block was stored.
    -- The caller (DoBiSImport) stashes parsed.cand for the Alternatives page.
    return true,
      "No BiS match rules in this list — open the Alternatives page to pick items to roll on.",
      0
  end

  return true, string.format(
    "Imported %d rule(s): %d item IDs, %d exact names (%s).",
    applied, #parsed.ids, #parsed.names, mode), applied
end

-- Convenience: string + rules array in, mutated rules out.
function BiSImport.Import(raw, mode, rules)
  local parsed, err = BiSImport.Parse(raw)
  if not parsed then return false, err end
  return BiSImport.ApplyToRules(parsed, mode, rules)
end

--=============================================================================
-- 5. In-game hookup  -- WoW-only; skipped under bare Lua 5.1
--    Attach this module to the addon object so the "Import BiS" options panel
--    (Core/PassLoot.lua) can reach BiSImport.Import. The panel + rule-list
--    refresh live addon-side; this module stays pure logic.
--=============================================================================

if rawget(_G, "LibStub") then
  local AceAddon = LibStub("AceAddon-3.0", true)
  local addon = AceAddon and AceAddon:GetAddon("PasslootBiS", true)
  if addon then addon.BiSImport = BiSImport end
end

--=============================================================================
-- 7. Offline self-test (protocol §10)  — run under Lua 5.1, guarded in-game
--    Usage offline:  lua -e 'BISIMPORT_SELFTEST=true' BiSImport.lua
--    (or set the global before load). Skipped inside WoW.
--=============================================================================

if rawget(_G, "BISIMPORT_SELFTEST") then
  local function assertEq(got, want, label)
    if got ~= want then
      error(("%s: got %q want %q"):format(label, tostring(got), tostring(want)))
    end
  end

  -- T1: full build
  local t1 = "PLBIS1:v=1;roll=need;desc=Ranger/Archery P0;" ..
    "ids=279033,397156,226653,214072,247233,1414521,1663095,18473,34423,253636,195068;" ..
    "names=Warbear Harness of the Beast|Devilsaur Gauntlets of the Beast|" ..
    "Might of the Timbermaw of the Beast|Devilsaur Leggings of the Beast|Mongoose Boots of the Beast"
  local p = assert(BiSImport.Parse(t1))
  assertEq(#p.ids, 11, "T1 ids"); assertEq(#p.names, 5, "T1 names")
  local ra = BiSImport.BuildIDRule(p); local rb = BiSImport.BuildNameRule(p)
  assertEq(ra.Desc, "Ranger/Archery P0 (IDs)", "T1 ruleA desc")
  assertEq(rb.Items[2][2], "Exact", "T1 name matchmode")

  -- T3: escaped delimiters (split-before-unescape)
  local p3 = assert(BiSImport.Parse(
    "PLBIS1:v=1;roll=greed;desc=Weird\\; Build|test;names=Foo \\| Bar of the Beast|Baz\\; Qux"))
  assertEq(p3.desc, "Weird; Build|test", "T3 desc")
  assertEq(p3.names[1], "Foo | Bar of the Beast", "T3 name1")
  assertEq(p3.names[2], "Baz; Qux", "T3 name2")

  -- T4: empty -> reject
  local _, e4 = BiSImport.Parse("PLBIS1:v=1;roll=need")
  assertEq(e4, "no items to import", "T4")

  -- T5: unknown prefix
  local _, e5 = BiSImport.Parse("PLBIS2:v=2;roll=need;ids=1")
  assertEq(e5, "not a PLBIS import string", "T5")

  -- T6: composite id leak
  local _, e6 = BiSImport.Parse("PLBIS1:v=1;roll=need;ids=8000009479")
  assert(e6:match("^item id exceeds int32"), "T6")

  -- T7: dedupe
  local p7 = assert(BiSImport.Parse(
    "PLBIS1:v=1;roll=need;ids=100,100,200;names=Boots of the Beast|Boots of the Beast"))
  assertEq(#p7.ids, 2, "T7 ids"); assertEq(#p7.names, 1, "T7 names")

  -- A1: ApplyToRules replace — two rules appended into an empty rules array,
  -- lists sorted to PassLoot's on-disk order (string compare for IDs).
  local rules = {}
  local okA, msgA, n = BiSImport.Import(t1, "replace", rules)
  assert(okA, "A1 ok"); assertEq(n, 2, "A1 applied")
  assertEq(#rules, 2, "A1 rule count")
  assertEq(rules[1].Desc, "Ranger/Archery P0 (IDs)", "A1 ruleA desc")
  assertEq(#rules[1].ItemIDs, 11, "A1 ruleA ids"); assertEq(#rules[2].Items, 5, "A1 ruleB names")
  assertEq(rules[1].ItemIDs[1][1], "1414521", "A1 id sort (string compare, first)")
  assertEq(rules[1].Loot[1], "need", "A1 loot")

  -- A2: replace again onto the same array overwrites same-Desc rules (no dupes)
  local _, _, n2 = BiSImport.Import(t1, "replace", rules)
  assertEq(#rules, 2, "A2 still two rules"); assertEq(n2, 2, "A2 applied")

  -- A3: merge unions new ids into the existing ID rule, deduping
  BiSImport.Import("PLBIS1:v=1;roll=need;desc=Ranger/Archery P0;ids=279033,999999", "merge", rules)
  assertEq(#rules[1].ItemIDs, 12, "A3 merged unique id added (11 + 999999)")

  -- F1: the additive farm= block parses into ranked rows (shared cross-side
  -- vector — the converter's PLBIS1_FARM_EXPECTED). Display-only; ids/names
  -- unaffected. Rows come pre-ranked (highest yield first); count == #items.
  local farmStr = t1 .. ";farm=" ..
    "worldboe=Ascended Vault - Trash Mobs=Warbear Harness of the Beast=" ..
    "Devilsaur Gauntlets of the Beast=Might of the Timbermaw of the Beast=" ..
    "Devilsaur Leggings of the Beast=Mongoose Boots of the Beast" ..
    "|raid=Naxxramas=Hood of Remorse=Sweet Perfume Broach=Death's Clutch=" ..
    "Bracers of the Eclipse" ..
    "|reputation=The Ruby Attrition=Azerothian Diamond Ring=" ..
    "Fighter's Seal of Eldre'Thalas" ..
    "|dungeon=Zul'Farrak - Chief Ukorz Sandscalp=Graverot Cape=Assault Band" ..
    "|dungeon=Blackrock Depths - Emperor Dagran Thaurissan=Soulpiercer" ..
    "|crafting=Blacksmithing=Strength of the High Chief" ..
    "|raid=Onyxia's Lair - Onyxia=Dakrya, Hand of the Second Eidolon"
  local pf = assert(BiSImport.Parse(farmStr))
  assertEq(#pf.ids, 11, "F1 ids unaffected"); assertEq(#pf.names, 5, "F1 names unaffected")
  assertEq(#pf.farm, 7, "F1 farm row count")
  assertEq(pf.farm[1].source, "Ascended Vault - Trash Mobs", "F1 top source")
  assertEq(pf.farm[1].category, "worldboe", "F1 top category")
  assertEq(pf.farm[1].count, 5, "F1 top count")
  assertEq(pf.farm[1].items[1], "Warbear Harness of the Beast", "F1 top first item")
  assertEq(pf.farm[2].source, "Naxxramas", "F1 second source")
  assertEq(pf.farm[2].count, 4, "F1 second count")
  assertEq(pf.farm[7].source, "Onyxia's Lair - Onyxia", "F1 last source")
  assertEq(pf.farm[7].items[1], "Dakrya, Hand of the Second Eidolon", "F1 last item (comma in name)")

  -- F2: escaped delimiters inside a farm row survive split-before-unescape
  -- (mirror of converter E8). Source has both `|` and `;`; names have each.
  local pf2 = assert(BiSImport.Parse(
    "PLBIS1:v=1;roll=need;ids=1;farm=dungeon=A\\|B\\; C=Foo \\| Bar=Baz\\; Qux"))
  assertEq(#pf2.farm, 1, "F2 one row")
  assertEq(pf2.farm[1].source, "A|B; C", "F2 source unescaped")
  assertEq(pf2.farm[1].items[1], "Foo | Bar", "F2 item1 unescaped")
  assertEq(pf2.farm[1].items[2], "Baz; Qux", "F2 item2 unescaped")

  -- F3: no farm field -> parsed.farm is nil (backward compatible).
  local pf3 = assert(BiSImport.Parse("PLBIS1:v=1;roll=need;ids=1"))
  assertEq(pf3.farm, nil, "F3 farm absent")

  -- CAND1: the additive cand= block parses into per-slot pools (shared cross-side
  -- vector — the converter's PLBIS1_CAND_EXPECTED). Display-only; ids/names
  -- unaffected. Rows come grouped by slot (paperdoll order), best score first;
  -- count == #candidates per slot.
  local candStr = t1 .. ";cand=" ..
    "Trinket=Strength of the High Chief=100=Blacksmithing=Crafted" ..
    "|Trinket=Fighter's Seal of Eldre'Thalas=31.55=The Ruby Attrition=Phase 2" ..
    "|Ranged=Bow of Testing=72.25=Naxxramas=Phase 2" ..
    "|Ranged=Soulpiercer=70.42=Blackrock Depths - Emperor Dagran Thaurissan=Normal"
  local pc = assert(BiSImport.Parse(candStr))
  assertEq(#pc.ids, 11, "CAND1 ids unaffected"); assertEq(#pc.names, 5, "CAND1 names unaffected")
  assertEq(#pc.cand, 2, "CAND1 slot count")
  assertEq(pc.cand[1].slot, "Trinket", "CAND1 first slot")
  assertEq(pc.cand[1].count, 2, "CAND1 first slot count")
  assertEq(pc.cand[1].candidates[1].name, "Strength of the High Chief", "CAND1 top name")
  assertEq(pc.cand[1].candidates[1].score, "100", "CAND1 top score")
  assertEq(pc.cand[1].candidates[1].source, "Blacksmithing", "CAND1 top source")
  assertEq(pc.cand[1].candidates[1].version, "Crafted", "CAND1 top version")
  assertEq(pc.cand[2].slot, "Ranged", "CAND1 second slot")
  assertEq(pc.cand[2].candidates[2].name, "Soulpiercer", "CAND1 second slot last name")
  assertEq(pc.cand[2].candidates[2].source, "Blackrock Depths - Emperor Dagran Thaurissan",
           "CAND1 source with hyphen")

  -- CAND2: escaped delimiters inside a cand row survive split-before-unescape.
  local pc2 = assert(BiSImport.Parse(
    "PLBIS1:v=1;roll=need;ids=1;cand=Off Hand=Foo \\| Bar=5=A\\|B\\; C=Normal"))
  assertEq(#pc2.cand, 1, "CAND2 one slot")
  assertEq(pc2.cand[1].slot, "Off Hand", "CAND2 slot")
  assertEq(pc2.cand[1].candidates[1].name, "Foo | Bar", "CAND2 name unescaped")
  assertEq(pc2.cand[1].candidates[1].source, "A|B; C", "CAND2 source unescaped")

  -- CAND3: no cand field -> parsed.cand is nil (backward compatible).
  local pc3 = assert(BiSImport.Parse("PLBIS1:v=1;roll=need;ids=1"))
  assertEq(pc3.cand, nil, "CAND3 cand absent")

  -- CAND4: additive Stage-2 promotion fields (slot=name=score=source=version=
  -- promoteKind=promoteKey). Parse reads them; CollectPromoted routes selected
  -- candidates id-vs-name by the converter's pre-classification.
  local pcp = assert(BiSImport.Parse(
    "PLBIS1:v=1;roll=need;ids=1;cand=" ..
    "Ranged=Bow of Testing=72.25=Naxxramas=Phase 2=id=300001" ..
    "|Ranged=Soulpiercer=70.42=BRD=Normal=id=195068" ..
    "|Chest=Warbear Harness of the Beast=80=Ascended Vault=Bloodforged=name=Warbear Harness of the Beast"))
  assertEq(pcp.cand[1].candidates[1].promoteKind, "id", "CAND4 kind id")
  assertEq(pcp.cand[1].candidates[1].promoteKey, "300001", "CAND4 key id")
  assertEq(pcp.cand[2].candidates[1].promoteKind, "name", "CAND4 kind name")
  assertEq(pcp.cand[2].candidates[1].promoteKey, "Warbear Harness of the Beast", "CAND4 key name")
  -- Select the first Ranged candidate (id) and the Chest candidate (name); skip
  -- the second Ranged one. CollectPromoted -> one id, one name.
  local sel = { ["1|1"] = true, ["2|1"] = true }
  local collected = BiSImport.CollectPromoted(pcp.cand, function(pi, ci)
    return sel[pi .. "|" .. ci] == true
  end)
  assertEq(#collected.ids, 1, "CAND4 collected ids")
  assertEq(collected.ids[1], 300001, "CAND4 collected id value")
  assertEq(#collected.names, 1, "CAND4 collected names")
  assertEq(collected.names[1], "Warbear Harness of the Beast", "CAND4 collected name value")

  -- CAND4b: the collected lists build the same two rule shapes as a BiS import,
  -- so promoted alternatives merge into the existing matching rules unchanged.
  local altParsed = { ids = collected.ids, names = collected.names,
                      roll = "need", desc = "P0 Alt" }
  local altId = BiSImport.BuildIDRule(altParsed)
  local altName = BiSImport.BuildNameRule(altParsed)
  assertEq(altId.ItemIDs[1][1], "300001", "CAND4b alt id rule")
  assertEq(altName.Items[1][1], "Warbear Harness of the Beast", "CAND4b alt name rule")
  assertEq(altName.Items[1][2], "Exact", "CAND4b alt name exact")

  -- CAND5: a 5-field (pre-Stage-2) cand row has no promote fields -> not
  -- promotable; CollectPromoted skips it even when selected.
  local pc5 = assert(BiSImport.Parse(
    "PLBIS1:v=1;roll=need;ids=1;cand=Ranged=Legacy Bow=50=Somewhere=Normal"))
  assertEq(pc5.cand[1].candidates[1].promoteKind, nil, "CAND5 no kind")
  local c5 = BiSImport.CollectPromoted(pc5.cand, function() return true end)
  assertEq(#c5.ids, 0, "CAND5 nothing promoted (ids)")
  assertEq(#c5.names, 0, "CAND5 nothing promoted (names)")

  -- CAND6: an alternatives-only string (no ids/names, only a cand block) parses
  -- OK — the Alternatives page + "roll on alternatives" act on it. ApplyToRules
  -- builds zero match rules but succeeds, so DoBiSImport still stashes parsed.cand.
  local candOnly = "PLBIS1:v=1;roll=need;cand=" ..
    "Ranged=Bow of Testing=72.25=Naxxramas=Phase 2=id=300001" ..
    "|Ranged=Soulpiercer=70.42=BRD=Normal=id=195068"
  local pco = assert(BiSImport.Parse(candOnly))
  assertEq(#pco.ids, 0, "CAND6 no ids"); assertEq(#pco.names, 0, "CAND6 no names")
  assertEq(#pco.cand, 1, "CAND6 one slot")
  assertEq(pco.cand[1].count, 2, "CAND6 two candidates")
  local rulesCo = {}
  local okCo, _, nCo = BiSImport.ApplyToRules(pco, "replace", rulesCo)
  assert(okCo, "CAND6 apply ok"); assertEq(nCo, 0, "CAND6 zero rules applied")
  assertEq(#rulesCo, 0, "CAND6 no rules written")

  -- CAND7: a truly empty string (no ids/names/cand) is still rejected.
  local _, e7 = BiSImport.Parse("PLBIS1:v=1;roll=need")
  assertEq(e7, "no items to import", "CAND7 truly empty rejected")

  -- MGR1: the additive mgr= block parses into per-item manager records (shared
  -- cross-side vector — the converter's MGR_FIELD_EXPECTED). Display/edit-only;
  -- ids/names unaffected. Rows come in slot order, one per rule entry, with the
  -- match key + source. Two rows below: an id-kind and a name-kind item.
  local mgrStr = t1 .. ";mgr=" ..
    "id=279033=Hood of Remorse=Naxxramas=raid=Head=70.42" ..
    "|name=Warbear Harness of the Beast=Warbear Harness of the Beast=" ..
    "Ascended Vault - Trash Mobs=worldboe"
  local pm = assert(BiSImport.Parse(mgrStr))
  assertEq(#pm.ids, 11, "MGR1 ids unaffected"); assertEq(#pm.names, 5, "MGR1 names unaffected")
  assertEq(#pm.manage, 2, "MGR1 row count")
  assertEq(pm.manage[1].kind, "id", "MGR1 row1 kind")
  assertEq(pm.manage[1].key, "279033", "MGR1 row1 key")
  assertEq(pm.manage[1].name, "Hood of Remorse", "MGR1 row1 name")
  assertEq(pm.manage[1].source, "Naxxramas", "MGR1 row1 source")
  assertEq(pm.manage[1].category, "raid", "MGR1 row1 category")
  -- Additive slot/score fields decode (§3.5): row1 carries them, row2 (5-field) omits.
  assertEq(pm.manage[1].slot, "Head", "MGR1 row1 slot")
  assertEq(pm.manage[1].score, 70.42, "MGR1 row1 score (number)")
  assertEq(pm.manage[2].kind, "name", "MGR1 row2 kind")
  assertEq(pm.manage[2].key, "Warbear Harness of the Beast", "MGR1 row2 key")
  assertEq(pm.manage[2].source, "Ascended Vault - Trash Mobs", "MGR1 row2 source")
  assertEq(pm.manage[2].slot, nil, "MGR1 row2 slot absent (backward-compat)")
  assertEq(pm.manage[2].score, nil, "MGR1 row2 score absent (backward-compat)")

  -- MGR2: escaped delimiters inside a mgr row survive split-before-unescape, and a
  -- row with an unknown kind is skipped (only id/name are valid).
  local pm2 = assert(BiSImport.Parse(
    "PLBIS1:v=1;roll=need;ids=1;mgr=" ..
    "name=Foo \\| Bar=Foo \\| Bar=A\\|B\\; C=dungeon" ..
    "|bogus=whatever=Nope=Src=cat"))
  assertEq(#pm2.manage, 1, "MGR2 one valid row (bogus kind skipped)")
  assertEq(pm2.manage[1].key, "Foo | Bar", "MGR2 key unescaped")
  assertEq(pm2.manage[1].source, "A|B; C", "MGR2 source unescaped")

  -- MGR3: no mgr field -> parsed.manage is nil (backward compatible).
  local pm3 = assert(BiSImport.Parse("PLBIS1:v=1;roll=need;ids=1"))
  assertEq(pm3.manage, nil, "MGR3 manage absent")

  -- MGR4: SelectRollItems keeps only items whose category is roll-eligible, split
  -- by kind, deduped. Vendor/reputation/crafting are pointless to roll on (no roll
  -- window), so they're dropped from the rule set (the manager still shows them).
  local ROLLCATS = { dungeon = true, raid = true, worldforged = true, bloodforged = true }
  local manage = {
    { kind = "id",   key = "100", name = "Raid Ring",    source = "Naxx",   category = "raid" },
    { kind = "id",   key = "200", name = "Vendor Cloak", source = "Vendor", category = "vendor" },
    { kind = "id",   key = "300", name = "Dungeon Bow",  source = "BRD",    category = "dungeon" },
    { kind = "id",   key = "300", name = "Dungeon Bow",  source = "BRD",    category = "dungeon" }, -- dup
    { kind = "name", key = "Warbear Harness of the Beast", name = "Warbear Harness of the Beast",
      source = "Vault", category = "bloodforged" },
    { kind = "name", key = "Crafted Belt", name = "Crafted Belt", source = "BS", category = "crafting" },
    { kind = "id",   key = "400", name = "Rep Trinket",  source = "Rep",    category = "reputation" },
  }
  local roll = BiSImport.SelectRollItems(manage, ROLLCATS)
  assertEq(#roll.ids, 2, "MGR4 rolled ids (raid + dungeon, dup collapsed)")
  assertEq(roll.ids[1], 100, "MGR4 first rolled id")
  assertEq(roll.ids[2], 300, "MGR4 second rolled id (deduped)")
  assertEq(#roll.names, 1, "MGR4 rolled names (bloodforged only; crafting dropped)")
  assertEq(roll.names[1], "Warbear Harness of the Beast", "MGR4 rolled name value")

  -- MGR5: an empty category set rolls nothing; an item with no category is never
  -- eligible (kept as data only).
  local none = BiSImport.SelectRollItems(manage, {})
  assertEq(#none.ids, 0, "MGR5 empty set -> no ids")
  assertEq(#none.names, 0, "MGR5 empty set -> no names")
  local noCat = BiSImport.SelectRollItems(
    { { kind = "id", key = "9", name = "Mystery", source = "?", category = "" } }, ROLLCATS)
  assertEq(#noCat.ids, 0, "MGR5 empty category not eligible")

  print("BiSImport self-test: all vectors passed.")
end

return BiSImport
