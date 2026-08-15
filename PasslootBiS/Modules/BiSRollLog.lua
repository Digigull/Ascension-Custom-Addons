--[[--------------------------------------------------------------------------
  BiSRollLog.lua  —  PasslootBiS module: passive loot-roll data collector

  Purpose (research §5, §6, §8.6 — "the one live-client unknown"): any given BiS
  item is rare, so we cannot just wait for one to drop and eyeball it. Instead we
  passively record EVERY loot roll the player sees, pairing the two facts that
  actually matter, and let the corpus grow over normal play until it answers the
  open question and lets us tune the importer:

    * the ID a PasslootBiS `ItemIDs` rule would compare against — i.e.
      GetItemInfoFromHyperlink(link), which is exactly how PasslootBiS builds
      itemObj.id (addon/PasslootBiS/Core/ItemInfo.lua:52); and
    * the item's difficulty, derived from GetItemFlavorText the same way PasslootBiS
      does (ItemInfo.lua:11-30): Heroic / Mythic N / Ascension / Bloodforged / ...

  If, across the corpus, Mythic items consistently carry a distinct ID from their
  Normal/Heroic counterparts on the ROLL FRAME, the numeric ID strategy (and
  per-variant selection) is confirmed for loot rolls. If a Mythic roll shows the
  base ID instead, ID-level variant matching can't fire there and we fall back to
  exact-name only. This module gathers the evidence to decide.

  Client target: WoW 3.3.5 (Ascension), Lua 5.1. No external libs.

  Structure mirrors BiSImport.lua: the parse/record/summarise core is pure and
  offline-unit-tested (self-test behind BISROLLLOG_SELFTEST); every WoW-API touch
  is isolated in an in-game-only block guarded by the presence of real globals,
  so the same file loads clean in the client and runs under bare Lua 5.1.

  Invariant reminder (research §2.4a): link-derived item level / reqLevel / stats
  are cached-first and LIE for scaled instances. This module records them ONLY as
  anomaly signal (to *detect* the lie), never to drive a rule. IDs and names are
  the trustworthy fields.
----------------------------------------------------------------------------]]

local ADDON_NAME = ...  -- unused for now; kept for parity with BiSImport wiring

local BiSRollLog = {}

BiSRollLog.SV_NAME  = "PassLootBiSRollLogDB"
BiSRollLog.SV_VERSION = 1

--=============================================================================
-- 1. Pure link parser  -- no WoW API, unit-testable
--    Splits a WoW 3.3.5 item link/string into its numeric fields.
--    Stock link: item:itemId:ench:g1:g2:g3:g4:suffixId:uniqueId:level (research
--    Appendix / §2.5). Field 1 = id, field 7 = suffixId, field 8 = uniqueId.
--=============================================================================

local function splitColon(s)
  local out = {}
  for part in (s .. ":"):gmatch("(.-):") do out[#out + 1] = part end
  return out
end

-- Returns { id, suffixId, uniqueId, linkLevel, name } or nil, err.
-- `name` is the bracketed display name if the link is a full hyperlink; nil for
-- a bare "item:..." string.
function BiSRollLog.ParseLink(link)
  if type(link) ~= "string" then return nil, "no link" end
  local itemseg = link:match("item:([%-%d:]+)")
  if not itemseg then return nil, "not an item link" end
  local f = splitColon(itemseg)
  local id = tonumber(f[1])
  if not id then return nil, "no item id" end
  return {
    id        = id,
    suffixId  = tonumber(f[7]) or 0,
    uniqueId  = tonumber(f[8]) or 0,
    linkLevel = tonumber(f[9]) or 0,
    name      = link:match("|h%[(.-)%]|h"),   -- nil for bare item: strings
  }
end

--=============================================================================
-- 2. Difficulty label (mirrors PasslootBiS ItemInfo.lua:11-30)  -- pure
--=============================================================================

-- inp booleans: isHeroic, isMythic, isAscended, isBloodforged, isWorldforged
-- inp.mythicLevel: number (0 = not Mythic+)
function BiSRollLog.DifficultyLabel(inp)
  local base
  if inp.isHeroic then
    base = "Heroic"
  elseif inp.isMythic then
    base = (inp.mythicLevel and inp.mythicLevel > 0)
           and ("Mythic " .. inp.mythicLevel) or "Mythic"
  elseif inp.isAscended then
    base = "Ascended"
  else
    base = "Normal"
  end
  local mods = {}
  if inp.isBloodforged then mods[#mods + 1] = "Bloodforged" end
  if inp.isWorldforged then mods[#mods + 1] = "Worldforged" end
  if #mods > 0 then
    return base .. " (" .. table.concat(mods, ",") .. ")"
  end
  return base
end

-- Extract the item link that follows the "sim" subcommand ("sim <link>").
-- Pure/testable; returns the trimmed link string, or nil when none is present.
function BiSRollLog.ParseSimArg(msg)
  local rest = tostring(msg or ""):match("^%s*%S+%s+(.+)$")
  if not rest then return nil end
  rest = rest:gsub("%s+$", "")
  if rest == "" then return nil end
  return rest
end

--=============================================================================
-- 3. Record builder  -- pure; assembles a normalised roll record
--    Takes a table of already-fetched raw values (so the WoW-API calls stay in
--    the in-game block) and returns the record we persist.
--=============================================================================

-- inp = {
--   link,                              -- raw loot-roll link (ground truth)
--   hyperlinkId,                       -- GetItemInfoFromHyperlink(link) (rule ID)
--   lootName, quality, canNeed, canGreed, canDe,   -- GetLootRollItemInfo
--   giName, iLevel, reqLevel,          -- GetItemInfo (UNTRUSTED: may lie, §2.4a)
--   isHeroic, isMythic, isAscended, isBloodforged, isWorldforged, mythicLevel,
-- }
function BiSRollLog.BuildRecord(inp)
  if type(inp) ~= "table" then return nil, "no input" end
  local parsed = BiSRollLog.ParseLink(inp.link)
  if not parsed then return nil, "unparseable link" end

  local hyperId = tonumber(inp.hyperlinkId)
  local id = hyperId or parsed.id
  local diff = BiSRollLog.DifficultyLabel(inp)

  local rec = {
    id        = id,                 -- the ID a numeric ItemIDs rule compares
    parsedId  = parsed.id,          -- id from a plain link string-parse
    suffixId  = parsed.suffixId,
    uniqueId  = parsed.uniqueId,
    name      = inp.lootName or inp.giName or parsed.name,
    difficulty = diff,
    -- UNTRUSTED link-derived values — recorded for lie-detection only (§2.4a):
    iLevel    = inp.iLevel,
    reqLevel  = inp.reqLevel,
    quality   = inp.quality,
    canNeed   = inp.canNeed,
    canGreed  = inp.canGreed,
    canDe     = inp.canDe,
    link      = inp.link,
    -- true unless the rule-ID and the plain-parse ID disagree (they shouldn't):
    idMatchesParsed = (hyperId == nil) or (hyperId == parsed.id),
  }
  -- Aggregation key: same physical roll variant collapses to one row + a count.
  rec.signature = table.concat({
    rec.id, rec.suffixId, rec.difficulty,
    rec.iLevel or "?", rec.reqLevel or "?",
  }, "|")
  return rec
end

--=============================================================================
-- 4. Summariser  -- pure; turns the aggregate map into tuning-ready stats
--    agg: signature -> { rec = <record>, count, firstSeen, lastSeen }
--=============================================================================

function BiSRollLog.Summarize(agg)
  local byDifficulty, idCounts, ilvlById = {}, {}, {}
  local total, distinctSig = 0, 0
  local mythic, heroic, idAnomalies = {}, {}, {}

  for _, e in pairs(agg or {}) do
    local r, c = e.rec, (e.count or 1)
    distinctSig = distinctSig + 1
    total = total + c
    byDifficulty[r.difficulty] = (byDifficulty[r.difficulty] or 0) + c
    idCounts[r.id] = (idCounts[r.id] or 0) + c
    if r.difficulty:find("Mythic", 1, true) then mythic[#mythic + 1] = r end
    if r.difficulty:find("Heroic", 1, true) then heroic[#heroic + 1] = r end
    if not r.idMatchesParsed then idAnomalies[#idAnomalies + 1] = r end
    -- per-instance scaling evidence: one id observed at >1 distinct ilvl
    if r.iLevel ~= nil then
      ilvlById[r.id] = ilvlById[r.id] or {}
      ilvlById[r.id][tostring(r.iLevel)] = true
    end
  end

  local distinctIds = 0
  for _ in pairs(idCounts) do distinctIds = distinctIds + 1 end

  local scalingIds = {}
  for id, set in pairs(ilvlById) do
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    if n > 1 then scalingIds[#scalingIds + 1] = id end
  end

  return {
    totalRolls          = total,
    distinctSignatures  = distinctSig,
    distinctIds         = distinctIds,
    byDifficulty        = byDifficulty,
    mythicSightings     = mythic,
    heroicSightings     = heroic,
    idParseAnomalies    = idAnomalies,   -- rule-ID != plain-parse ID (unexpected)
    perInstanceScalingIds = scalingIds,  -- same id seen at multiple ilvls (§2.4a(b))
  }
end

--=============================================================================
-- 5. In-game collector  -- WoW-API ONLY; skipped entirely under bare Lua 5.1
--    Guarded by the presence of real client globals so the file self-tests
--    offline without ever touching WoW APIs.
--=============================================================================

-- Flavor-text difficulty probe (mirrors ItemInfo.lua). Returns the six values
-- BuildRecord wants, or nil if the API/id is unavailable.
function BiSRollLog._Flavor(id)
  local getFlavor = rawget(_G, "GetItemFlavorText")
  if not getFlavor or not id then return end
  local ok, flavor = pcall(getFlavor, id)
  if not ok or type(flavor) ~= "string" then return end
  local isHeroic = flavor:find("Heroic", 1, true) ~= nil
  local isMythic = (not isHeroic) and (flavor:find("Mythic", 1, true) ~= nil)
  local isAscended = (not isHeroic and not isMythic)
                     and (flavor:find("Ascended", 1, true) ~= nil)
  local isBloodforged = flavor:find("Bloodforged", 1, true) ~= nil
  local isWorldforged = flavor:find("Worldforged", 1, true) ~= nil
  local mythicLevel = 0
  if isMythic then
    local l = flavor:match("Mythic (%d*)")
    mythicLevel = l and tonumber(l) or 0
  end
  return isBloodforged, isHeroic, isMythic, isAscended, isWorldforged, mythicLevel
end

if rawget(_G, "CreateFrame") and rawget(_G, "GetLootRollItemLink") then
  local function safecall(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return unpack(r, 2) end
  end

  local function ensureDB()
    local db = rawget(_G, BiSRollLog.SV_NAME)
    if type(db) ~= "table" then db = {}; _G[BiSRollLog.SV_NAME] = db end
    db.version = BiSRollLog.SV_VERSION
    db.rolls = db.rolls or {}
    return db
  end
  BiSRollLog._EnsureDB = ensureDB

  -- Build a record from a raw item link using live client APIs. Shared by the
  -- passive collector and the `sim` dry-run. `extra` (optional) carries the
  -- loot-roll-only fields (lootName/canNeed/...) that a bare link can't provide.
  local function buildFromLink(link, extra)
    if type(link) ~= "string" then return nil end
    extra = extra or {}
    local giName, _, quality, iLevel, reqLevel = safecall(_G.GetItemInfo, link)
    local hyperlinkId = safecall(rawget(_G, "GetItemInfoFromHyperlink"), link)
    local flavorId = hyperlinkId or link:match("item:(%d+)")
    local isBF, isH, isM, isA, isW, mLvl = BiSRollLog._Flavor(flavorId)
    return BiSRollLog.BuildRecord({
      link = link, hyperlinkId = hyperlinkId,
      lootName = extra.lootName, quality = quality or extra.quality,
      canNeed = extra.canNeed, canGreed = extra.canGreed, canDe = extra.canDe,
      giName = giName, iLevel = iLevel, reqLevel = reqLevel,
      isBloodforged = isBF, isHeroic = isH, isMythic = isM,
      isAscended = isA, isWorldforged = isW, mythicLevel = mLvl,
    })
  end
  BiSRollLog._BuildFromLink = buildFromLink

  --===========================================================================
  -- SPIKE (bis-scanner/spike-first.md): measure whether the loot-roll tooltip
  -- shows TRUE scaled stats vs the (lying) GetItemStats values. Measurement
  -- ONLY -- no scoring, does not drive any rule, does not touch the pure core or
  -- its vectors. Attaches raw evidence to each roll record for `/plbisroll tips`
  -- to print side by side, so divergence can be eyeballed on live. Remove this
  -- block (and the two lines in record() + the `tips` slash branch) to revert.
  --===========================================================================
  local scan = CreateFrame("GameTooltip", "PLBiSRollScanTip", nil, "GameTooltipTemplate")
  scan:SetOwner(UIParent, "ANCHOR_NONE")

  -- Read every non-empty left-column line of whatever the scan tooltip shows.
  local function scanLines(setter, ...)
    if type(setter) ~= "function" then return {} end
    local ok = pcall(function(...)
      scan:ClearLines()
      setter(scan, ...)
    end, ...)
    if not ok then return {} end
    local lines = {}
    for i = 1, scan:NumLines() do
      local fs = _G["PLBiSRollScanTipTextLeft" .. i]
      local t = fs and fs:GetText()
      if t and t ~= "" then lines[#lines + 1] = t end
    end
    return lines
  end
  BiSRollLog._ScanLines = scanLines

  local function record(rollID)
    local link = safecall(_G.GetLootRollItemLink, rollID)
    if not link then return end
    local _, lootName, _, lootQuality, _, canNeed, canGreed, canDe =
      safecall(_G.GetLootRollItemInfo, rollID)
    local rec = buildFromLink(link, {
      lootName = lootName, quality = lootQuality,
      canNeed = canNeed, canGreed = canGreed, canDe = canDe,
    })
    if not rec then return end

    -- SPIKE: capture the (lying) GetItemStats values and the roll-frame tooltip
    -- lines for the SAME item, so `/plbisroll tips` can show whether they diverge
    -- (divergence => tooltip carries server-true scaled stats => scanner is
    -- accurate-tier). Measurement only; recorded like iLevel/reqLevel (§2.4a).
    local giStats = {}
    if _G.GetItemStats then safecall(_G.GetItemStats, link, giStats) end
    rec.giStats  = giStats                              -- { ITEM_MOD_*_SHORT = value } (may lie)
    rec.tipLines = scanLines(scan.SetLootRollItem, rollID)  -- raw tooltip text (server truth?)

    local db = ensureDB()
    local now = (rawget(_G, "time") and _G.time()) or 0
    local e = db.rolls[rec.signature]
    if e then
      e.count = (e.count or 1) + 1
      e.lastSeen = now
    else
      db.rolls[rec.signature] = { rec = rec, count = 1, firstSeen = now, lastSeen = now }
    end
  end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent("START_LOOT_ROLL")
  frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "START_LOOT_ROLL" then
      -- Never let a logging error interfere with rolling.
      pcall(record, arg1)
    end
  end)
  BiSRollLog._frame = frame

  -- Slash command:  /plbisroll [summary|list|dump|sim <itemlink>|clear]
  if rawget(_G, "SlashCmdList") then
    _G.SLASH_PLBISROLL1 = "/plbisroll"
    _G.SlashCmdList["PLBISROLL"] = function(msg)
      BiSRollLog.SlashHandler(tostring(msg or ""))
    end
  end
end

--=============================================================================
-- 6. Slash handler (in-game reporting)  -- print-based; safe to define always
--=============================================================================

local function out(line) if rawget(_G, "print") then print(line) end end

function BiSRollLog.SlashHandler(msg)
  local cmd = (msg:match("^%s*(%S*)") or ""):lower()
  local db = rawget(_G, BiSRollLog.SV_NAME)
  local rolls = (type(db) == "table" and db.rolls) or {}

  if cmd == "clear" then
    if type(db) == "table" then db.rolls = {} end
    out("|cff33ff99PLBIS roll-log|r: cleared.")
    return
  end

  if cmd == "sim" then
    local link = BiSRollLog.ParseSimArg(msg)
    if not link then
      out("|cff33ff99PLBIS roll-log|r sim: shift-click an item into chat after '/plbisroll sim'.")
      return
    end
    local builder = BiSRollLog._BuildFromLink
    if not builder then
      out("|cff33ff99PLBIS roll-log|r sim: only available in-game.")
      return
    end
    local rec = builder(link)
    if not rec then
      out("|cff33ff99PLBIS roll-log|r sim: couldn't parse that item link.")
      return
    end
    out("|cff33ff99PLBIS roll-log|r sim (dry-run \226\128\148 NOT recorded):")
    out(string.format("  id=%s  parsedId=%s  suffix=%s  idMatchesParsed=%s",
      tostring(rec.id), tostring(rec.parsedId), tostring(rec.suffixId),
      tostring(rec.idMatchesParsed)))
    out(string.format("  difficulty=%s  name=%s", rec.difficulty, tostring(rec.name or "?")))
    out(string.format("  ilvl=%s  req=%s  quality=%s  (link-derived, may lie \226\128\148 research 2.4a)",
      tostring(rec.iLevel), tostring(rec.reqLevel), tostring(rec.quality)))
    out("  signature=" .. tostring(rec.signature))
    return
  end

  if cmd == "tips" then
    -- SPIKE readout: per recorded variant, print the raw roll-frame tooltip lines
    -- next to the GetItemStats values, so tooltip-vs-cache divergence is visible.
    local n = 0
    for _, e in pairs(rolls) do
      local r = e.rec
      out(string.format("|cff33ff99PLBIS tips|r  id=%s [%s]  %s",
        tostring(r.id), r.difficulty, tostring(r.name or "?")))
      out("  GetItemStats (link-derived, may lie):")
      local any = false
      for k, v in pairs(r.giStats or {}) do
        any = true
        out(string.format("    %s = %s", tostring(k), tostring(v)))
      end
      if not any then out("    (none / not captured)") end
      out("  roll-frame tooltip lines (SetLootRollItem — server truth?):")
      if r.tipLines and #r.tipLines > 0 then
        for _, line in ipairs(r.tipLines) do out("    | " .. line) end
      else
        out("    (empty — SetLootRollItem may not populate at roll-start; see spike-first.md)")
      end
      n = n + 1
    end
    if n == 0 then out("|cff33ff99PLBIS tips|r: no rolls recorded yet.") end
    return
  end

  local s = BiSRollLog.Summarize(rolls)

  if cmd == "list" or cmd == "dump" then
    out("|cff33ff99PLBIS roll-log|r — " .. s.distinctSignatures ..
        " variants, " .. s.totalRolls .. " rolls:")
    for _, e in pairs(rolls) do
      local r = e.rec
      out(string.format("  id=%s suffix=%s [%s] x%d  ilvl=%s req=%s  %s",
        tostring(r.id), tostring(r.suffixId), r.difficulty, e.count or 1,
        tostring(r.iLevel), tostring(r.reqLevel), tostring(r.name or "?")))
    end
    return
  end

  -- default: summary
  out("|cff33ff99PLBIS roll-log|r summary:")
  out(string.format("  total rolls: %d   distinct variants: %d   distinct ids: %d",
    s.totalRolls, s.distinctSignatures, s.distinctIds))
  local diffs = {}
  for d, n in pairs(s.byDifficulty) do diffs[#diffs + 1] = d .. "=" .. n end
  table.sort(diffs)
  out("  by difficulty: " .. (table.concat(diffs, "  ") ~= "" and table.concat(diffs, "  ") or "(none)"))
  out(string.format("  Mythic sightings: %d   Heroic sightings: %d",
    #s.mythicSightings, #s.heroicSightings))
  if #s.idParseAnomalies > 0 then
    out("  |cffff3333WARNING|r: " .. #s.idParseAnomalies ..
        " roll(s) where the rule-ID != plain-parse ID (investigate).")
  end
  if #s.perInstanceScalingIds > 0 then
    out("  per-instance scaling seen on " .. #s.perInstanceScalingIds ..
        " id(s) (same id, multiple ilvls — confirms §2.4a, ilvl is untrustworthy).")
  end
  out("  use '/plbisroll list' for per-variant rows, '/plbisroll tips' for the spike " ..
      "readout (tooltip vs GetItemStats), '/plbisroll sim <itemlink>' to " ..
      "dry-run an item, '/plbisroll clear' to reset.")
end

--=============================================================================
-- 7. Offline self-test (run under Lua 5.1, guarded in-game)
--    Usage:  lua5.1 -e 'BISROLLLOG_SELFTEST=true' BiSRollLog.lua
--=============================================================================

if rawget(_G, "BISROLLLOG_SELFTEST") then
  local function eq(got, want, label)
    if got ~= want then
      error(("%s: got %q want %q"):format(label, tostring(got), tostring(want)))
    end
  end

  -- R1: bare plain link
  local p1 = assert(BiSRollLog.ParseLink("item:18473:0:0:0:0:0:0:0:80"))
  eq(p1.id, 18473, "R1 id"); eq(p1.suffixId, 0, "R1 suffix")

  -- R2: full hyperlink with suffix + display name
  local p2 = assert(BiSRollLog.ParseLink(
    "|cffa335ee|Hitem:1154704:0:0:0:0:0:9141:0:80|h[Devilsaur Gauntlets of the Beast]|h|r"))
  eq(p2.id, 1154704, "R2 id"); eq(p2.suffixId, 9141, "R2 suffix")
  eq(p2.name, "Devilsaur Gauntlets of the Beast", "R2 name")

  -- R3: Mythic 10 record — difficulty label + id from hyperlinkId
  local r3 = assert(BiSRollLog.BuildRecord({
    link = "item:412491:0:0:0:0:0:0:0:80", hyperlinkId = 412491,
    lootName = "Embrace of the Lycan", iLevel = 72, reqLevel = 60,
    isMythic = true, mythicLevel = 10,
  }))
  eq(r3.id, 412491, "R3 id"); eq(r3.difficulty, "Mythic 10", "R3 difficulty")
  eq(r3.idMatchesParsed, true, "R3 idMatchesParsed")

  -- R4: Normal record
  local r4 = assert(BiSRollLog.BuildRecord({
    link = "item:9479:0:0:0:0:0:0:0:80", hyperlinkId = 9479, iLevel = 50,
  }))
  eq(r4.difficulty, "Normal", "R4 difficulty")

  -- R5: anomaly — rule-ID disagrees with the plain-parse ID
  local r5 = assert(BiSRollLog.BuildRecord({
    link = "item:9479:0:0:0:0:0:0:0:80", hyperlinkId = 412491,
  }))
  eq(r5.idMatchesParsed, false, "R5 anomaly flagged")

  -- R6: Summarize — difficulty tally, Mythic sighting, scaling detection
  local agg = {
    [r3.signature] = { rec = r3, count = 2 },
    [r4.signature] = { rec = r4, count = 5 },
    -- same id 9479 at a *different* ilvl → per-instance scaling evidence
    ["scale"] = { rec = (function()
        local x = BiSRollLog.BuildRecord({ link = "item:9479:0:0:0:0:0:0:0:80",
          hyperlinkId = 9479, iLevel = 95 }); return x end)(), count = 1 },
  }
  local s = BiSRollLog.Summarize(agg)
  eq(s.totalRolls, 8, "R6 total")
  eq(s.byDifficulty["Mythic 10"], 2, "R6 mythic count")
  eq(#s.mythicSightings, 1, "R6 mythic sightings")
  eq(#s.perInstanceScalingIds, 1, "R6 scaling ids")   -- id 9479 seen at ilvl 50 & 95

  -- R7: sim-arg extraction pulls the link after the subcommand (pure glue)
  eq(BiSRollLog.ParseSimArg("sim item:18473:0:0:0:0:0:0:0:80"),
     "item:18473:0:0:0:0:0:0:0:80", "R7 sim arg")
  eq(BiSRollLog.ParseSimArg("sim"), nil, "R7 sim no-arg")
  eq(BiSRollLog.ParseSimArg("  sim   item:9479  "), "item:9479", "R7 sim trims")

  print("BiSRollLog self-test: all vectors passed.")
end

return BiSRollLog
