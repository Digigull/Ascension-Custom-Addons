--[[--------------------------------------------------------------------------
  RollAdvisor.lua  —  PasslootBiS.API roll-advisor facade + "held confirm" gate

  Implements the decided roll-arbitration protocol (docs/integration-api.md §3.6)
  and the "held confirm" behaviour a companion addon asked for (BiS-Scanner
  integration.md §5.2a):

    * A versioned, additive `PasslootBiS.API` facade (L0 handshake + advisor
      registry). Integrators wait via `OnReady`, then `RegisterRollAdvisor`.
    * PassLoot stays the SOLE roller. An advisor only *suggests* a verdict; it
      never calls RollOnLoot. This module never mixes stats into a rule — it sits
      entirely on the roll path, so CLAUDE.md invariants 1–2 are untouched.
    * On an actionable verdict (upgrade / high value) under the "held" trust mode,
      PassLoot shows a floating countdown popup (a CreateFrame, NEVER a
      StaticPopup — §8.6) for HALF the roll window and holds its auto-roll; the
      user clicks Need/Greed/Pass, or the timer expires and we fall through to the
      rule-computed RollMethod. A min-duration floor keeps short windows usable.

  Split like the addon's other tested modules: a PURE core (verdict/hold/trust
  logic, no WoW API) that self-tests offline under bare Lua 5.1, then a guarded
  in-game half (the API facade, the popup, the gate driver).

  Client target: WoW 3.3.5 (Ascension), Lua 5.1.
----------------------------------------------------------------------------]]

--=============================================================================
-- 0. Pure core — no WoW API, unit-testable offline (ROLLADVISOR_SELFTEST)
--=============================================================================

local RollAdvisor = {}

-- The three per-advisor trust modes (docs/integration-api.md §3.6, updated by
-- §5.2a to make "held" a first-class mode with the rollTime/2 timeout).
RollAdvisor.TRUST = { advisory = true, held = true, trust = true }

function RollAdvisor.IsValidTrust(mode)
  return RollAdvisor.TRUST[mode] == true
end

-- A verdict is "actionable" (worth prompting/casting) when it reports either a
-- stat upgrade or a high-value flag. Anything else is an abstain.
function RollAdvisor.IsActionable(v)
  if type(v) ~= "table" then return false end
  return v.upgrade == true or v.highValue == true
end

-- Sanitise a raw table an advisor returned into the frozen verdict shape
-- { upgrade(bool), highValue(bool), delta(number), reason(string|nil) }.
-- Returns nil only when the input isn't a table (a hard abstain).
function RollAdvisor.NormalizeVerdict(v)
  if type(v) ~= "table" then return nil end
  local reason = (type(v.reason) == "string" and v.reason ~= "") and v.reason or nil
  return {
    upgrade   = v.upgrade == true,
    highValue = v.highValue == true,
    delta     = tonumber(v.delta) or 0,
    reason    = reason,
  }
end

-- How long to hold the roll, in SECONDS. The design is half the roll window
-- (rollTimeMs / 2), floored so a fast window is still long enough to react to,
-- and capped a `margin` short of the full window so we ALWAYS fall through to
-- the rules before the server auto-passes. rollTimeMs is the client's ms value
-- from START_LOOT_ROLL; 0/nil defends to a 60s window.
function RollAdvisor.ResolveHoldSeconds(rollTimeMs, minHold, margin)
  minHold = tonumber(minHold) or 4
  margin  = tonumber(margin) or 1
  local rollSec = (tonumber(rollTimeMs) or 0) / 1000
  if rollSec <= 0 then rollSec = 60 end
  local hold = rollSec / 2
  if hold < minHold then hold = minHold end
  local cap = rollSec - margin
  if cap < 0 then cap = 0 end
  if hold > cap then hold = cap end
  return hold
end

--=============================================================================
-- 1. Offline self-test (skipped in-game; run by scripts/test.sh)
--=============================================================================

if rawget(_G, "ROLLADVISOR_SELFTEST") then
  local passed = 0
  local function ok(cond, msg)
    if not cond then error("RollAdvisor self-test FAILED: " .. tostring(msg), 2) end
    passed = passed + 1
  end
  local function near(a, b, msg)
    ok(type(a) == "number" and math.abs(a - b) <= 1e-9, (msg or "near") ..
      " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
  end

  -- IsValidTrust
  ok(RollAdvisor.IsValidTrust("advisory"), "trust advisory valid")
  ok(RollAdvisor.IsValidTrust("held"), "trust held valid")
  ok(RollAdvisor.IsValidTrust("trust"), "trust trust valid")
  ok(not RollAdvisor.IsValidTrust("confirm"), "trust confirm invalid")
  ok(not RollAdvisor.IsValidTrust(""), "trust empty invalid")
  ok(not RollAdvisor.IsValidTrust(nil), "trust nil invalid")

  -- IsActionable
  ok(RollAdvisor.IsActionable({ upgrade = true }), "upgrade actionable")
  ok(RollAdvisor.IsActionable({ highValue = true }), "highValue actionable")
  ok(RollAdvisor.IsActionable({ upgrade = true, highValue = true }), "both actionable")
  ok(not RollAdvisor.IsActionable({ upgrade = false, highValue = false }), "neither not actionable")
  ok(not RollAdvisor.IsActionable({}), "empty not actionable")
  ok(not RollAdvisor.IsActionable(nil), "nil not actionable")
  ok(not RollAdvisor.IsActionable("nope"), "string not actionable")

  -- NormalizeVerdict
  ok(RollAdvisor.NormalizeVerdict(nil) == nil, "normalize nil -> nil")
  ok(RollAdvisor.NormalizeVerdict(42) == nil, "normalize number -> nil")
  local n1 = RollAdvisor.NormalizeVerdict({})
  ok(n1 and n1.upgrade == false and n1.highValue == false, "normalize {} defaults false")
  near(n1.delta, 0, "normalize {} delta 0")
  ok(n1.reason == nil, "normalize {} reason nil")
  local n2 = RollAdvisor.NormalizeVerdict({ upgrade = true, delta = 0.08, reason = "Upgrade +8%" })
  ok(n2.upgrade == true and n2.highValue == false, "normalize upgrade flags")
  near(n2.delta, 0.08, "normalize delta preserved")
  ok(n2.reason == "Upgrade +8%", "normalize reason preserved")
  local n3 = RollAdvisor.NormalizeVerdict({ highValue = true, reason = "" })
  ok(n3.highValue == true and n3.reason == nil, "normalize empty reason dropped")
  local n4 = RollAdvisor.NormalizeVerdict({ upgrade = 1, delta = "not a number" })
  ok(n4.upgrade == false, "normalize non-boolean upgrade coerced to false")
  near(n4.delta, 0, "normalize non-number delta -> 0")

  -- ResolveHoldSeconds
  near(RollAdvisor.ResolveHoldSeconds(60000, 4, 1), 30, "60s window -> 30s hold")
  near(RollAdvisor.ResolveHoldSeconds(6000, 4, 1), 4, "6s window floored to 4s")
  near(RollAdvisor.ResolveHoldSeconds(4000, 4, 1), 3, "4s window capped to 3s (margin)")
  near(RollAdvisor.ResolveHoldSeconds(2000, 4, 1), 1, "2s window capped to 1s (margin)")
  near(RollAdvisor.ResolveHoldSeconds(0, 4, 1), 30, "0 window -> 60s default -> 30s")
  near(RollAdvisor.ResolveHoldSeconds(nil, 4, 1), 30, "nil window -> 60s default -> 30s")
  near(RollAdvisor.ResolveHoldSeconds(60000), 30, "default minHold/margin -> 30s")

  print("RollAdvisor self-test: all " .. passed .. " vectors passed.")
  return
end

--=============================================================================
-- 2. In-game half — the API facade, the popup, the gate driver.
--    Guarded: bare Lua 5.1 has no LibStub, so the file stops here offline.
--=============================================================================

if not rawget(_G, "LibStub") then
  return RollAdvisor
end

local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")

-- Expose the pure core on the addon (handy for debugging / a future test hook).
PasslootBiS.RollAdvisorCore = RollAdvisor

--------------------------------------------------------------------------------
-- 2a. The PasslootBiS.API facade (L0 handshake + advisor registry)
--------------------------------------------------------------------------------

local advisors    = {}   -- name -> { fn = function } | { obj = table w/ :GetRollVerdict }
local onReadyQueue = {}

local API = {}
API.VERSION      = 1        -- bump on any breaking change (additive within a version)
API.ready        = false    -- flips true once OnEnable has run (see FireReady)
API.enabled      = true     -- master switch for the advisor gate
API.defaultTrust = "held"   -- the decided behaviour for upgrades/high-value (§5.2a)
API.minHold      = 4        -- seconds: floor so a short roll window is still usable
API.margin       = 1        -- seconds: never hold into the last moment before auto-pass
PasslootBiS.API  = API

local function safeCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and geterrorhandler then geterrorhandler()(err) end
  return ok
end

-- Run fn now if we're ready, else queue it until OnEnable (load-order-proof).
function API:OnReady(fn)
  if type(fn) ~= "function" then return end
  if self.ready then
    safeCall(fn)
  else
    onReadyQueue[#onReadyQueue + 1] = fn
  end
end

-- Called once from PasslootBiS:OnEnable — mark ready and flush the queue.
function API:FireReady()
  if self.ready then return end
  self.ready = true
  local q = onReadyQueue
  onReadyQueue = {}
  for _, fn in ipairs(q) do
    safeCall(fn)
  end
end

-- Register an advisor. `advisor` may be either a function fn(ctx) -> verdict, or
-- a table exposing :GetRollVerdict(rollID) -> verdict (the scanner registers its
-- PLBiSScanner.API table directly). Both cover the pull hook and the push path.
function API:RegisterRollAdvisor(name, advisor)
  if type(name) ~= "string" or name == "" then return false end
  if type(advisor) == "function" then
    advisors[name] = { fn = advisor }
  elseif type(advisor) == "table" and type(advisor.GetRollVerdict) == "function" then
    advisors[name] = { obj = advisor }
  else
    return false
  end
  return true
end

function API:UnregisterRollAdvisor(name)
  advisors[name] = nil
end

-- Per-advisor trust mode, persisted in the profile (keyed by advisor name so you
-- can trust your own scanner while keeping a stranger's addon on a tighter mode).
local function trustStore()
  local p = PasslootBiS.db and PasslootBiS.db.profile
  if not p then return nil end
  if type(p.RollAdvisor) ~= "table" then p.RollAdvisor = {} end
  if type(p.RollAdvisor.trust) ~= "table" then p.RollAdvisor.trust = {} end
  return p.RollAdvisor.trust
end

function API:GetTrustMode(name)
  local store = trustStore()
  local mode = store and store[name]
  if RollAdvisor.IsValidTrust(mode) then return mode end
  return self.defaultTrust
end

function API:SetTrustMode(name, mode)
  if type(name) ~= "string" or name == "" then return false end
  if not RollAdvisor.IsValidTrust(mode) then return false end
  local store = trustStore()
  if not store then return false end
  store[name] = mode
  return true
end

-- Consult every registered advisor (each pcall-guarded — one that errors, blocks
-- returning, or abstains is skipped and never breaks the roll). Returns the first
-- ACTIONABLE verdict plus the name of the advisor that produced it, or nil.
function API:ConsultAdvisors(ctx)
  for name, entry in pairs(advisors) do
    local ok, raw
    if entry.fn then
      ok, raw = pcall(entry.fn, ctx)
    else
      ok, raw = pcall(entry.obj.GetRollVerdict, entry.obj, ctx.rollID)
    end
    if ok then
      local v = RollAdvisor.NormalizeVerdict(raw)
      if RollAdvisor.IsActionable(v) then
        return v, name
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- 2b. The floating "held confirm" popup (CreateFrame — never a StaticPopup)
--------------------------------------------------------------------------------

local POOL    = {}   -- reusable frames (a roll window can have several open at once)
local occupied = {}  -- slot index -> true, for vertical stacking
local active  = {}   -- RollID -> frame currently showing

local function acquireSlot()
  local i = 1
  while occupied[i] do i = i + 1 end
  occupied[i] = true
  return i
end

local function makeFrame()
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetWidth(320)
  f:SetHeight(120)
  -- FULLSCREEN_DIALOG, and deliberately NO SetToplevel: on Ascension 3.3.5 a
  -- SetToplevel(true) frame re-raises on every click/drag and each raise
  -- restacks the strata, spiking the client. These popups are placed at
  -- distinct non-overlapping vertical slots on a high strata, so they never
  -- need click-to-raise — dropping SetToplevel gives 0 spikes on drag.
  -- (see DRAGFREEZE note — the "0 spikes" cure)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  PasslootBiS:ApplyDarkBackdrop(f)   -- shared house chrome (Core/PassLoot.lua)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
  f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing() end)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", f, "TOP", 0, -12)

  f.item = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.item:SetPoint("TOP", f.title, "BOTTOM", 0, -6)
  f.item:SetWidth(292)
  f.item:SetJustifyH("CENTER")

  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetStatusBarColor(0.25, 0.6, 1)
  f.bar:SetHeight(10)
  f.bar:SetWidth(280)
  f.bar:SetPoint("TOP", f.item, "BOTTOM", 0, -6)
  f.bar:SetBackdrop({
    ["bgFile"] = "Interface\\TargetingFrame\\UI-StatusBar",
    ["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
    ["edgeSize"] = 8,
    ["insets"] = { ["left"] = 1, ["right"] = 1, ["top"] = 1, ["bottom"] = 1 },
  })
  f.timeText = f.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.timeText:SetPoint("CENTER", f.bar, "CENTER", 0, 0)

  local function mkBtn(label)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetWidth(92)
    b:SetHeight(22)
    b:SetText(label)
    return b
  end
  f.needBtn  = mkBtn(rawget(_G, "NEED") or "Need")
  f.greedBtn = mkBtn(rawget(_G, "GREED") or "Greed")
  f.passBtn  = mkBtn(rawget(_G, "PASS") or "Pass")
  f.needBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
  f.greedBtn:SetPoint("LEFT", f.needBtn, "RIGHT", 6, 0)
  f.passBtn:SetPoint("LEFT", f.greedBtn, "RIGHT", 6, 0)
  return f
end

-- Show a bounded-hold confirm for one roll. On a button click cast that choice;
-- on timeout fall through to `fallbackMethod` (the rule-computed RollMethod, which
-- may be nil = don't roll, exactly as PassLoot behaves today).
function PasslootBiS:ShowRollConfirm(RollID, ctx, verdict, holdSecs, fallbackMethod, advisorName)
  if active[RollID] then return end   -- already prompting this roll

  local f = table.remove(POOL) or makeFrame()
  f.slot = acquireSlot()
  f.resolved = false
  f:ClearAllPoints()
  f:SetPoint("TOP", UIParent, "TOP", 0, -200 - (f.slot - 1) * 132)

  f.title:SetText("|cffffcc00PLBiS|r " .. (advisorName or "advisor") .. " suggests a roll")
  local reason = verdict.reason
  f.item:SetText((ctx.itemLink or "?") .. (reason and ("\n|cff9d9d9d" .. reason .. "|r") or ""))

  f.bar:SetMinMaxValues(0, holdSecs > 0 and holdSecs or 1)
  f.bar:SetValue(holdSecs)
  f.endTime = GetTime() + holdSecs

  -- Need/Greed eligibility can arrive a beat AFTER START_LOOT_ROLL on Ascension,
  -- so the snapshot in ctx (taken at roll-start) sometimes reports only Pass even
  -- for an item you can Need. Re-poll GetLootRollItemInfo during the hold and light
  -- the buttons up as soon as the server says they're rollable. Falls back to the
  -- ctx snapshot if the live API is unavailable.
  local applyElig = function(canNeed, canGreed)
    if canNeed then f.needBtn:Enable() else f.needBtn:Disable() end
    if canGreed then f.greedBtn:Enable() else f.greedBtn:Disable() end
  end
  applyElig(ctx.canNeed, ctx.canGreed)
  f.nextElig = 0

  f:SetScript("OnUpdate", function(fr)
    local now = GetTime()
    local remain = fr.endTime - now
    if remain < 0 then remain = 0 end
    fr.bar:SetValue(remain)
    fr.timeText:SetText(string.format("%.0fs", remain))
    -- Throttled live eligibility re-check (~3/sec) until resolved.
    if not fr.resolved and now >= fr.nextElig then
      fr.nextElig = now + 0.3
      local gi = rawget(_G, "GetLootRollItemInfo")
      if gi then
        local ok, _, _, _, _, _, cn, cg = pcall(gi, RollID)
        if ok then applyElig(cn and true or false, cg and true or false) end
      end
    end
  end)

  local function resolve(method)
    if f.resolved then return end
    f.resolved = true
    if f.timer then PasslootBiS:CancelTimer(f.timer); f.timer = nil end
    f:SetScript("OnUpdate", nil)
    f:Hide()
    active[RollID] = nil
    occupied[f.slot] = nil
    POOL[#POOL + 1] = f
    PasslootBiS:QueueRoll(RollID, method)
  end

  f.needBtn:SetScript("OnClick", function() resolve(PasslootBiS.RollMethod.need) end)
  f.greedBtn:SetScript("OnClick", function() resolve(PasslootBiS.RollMethod.greed) end)
  f.passBtn:SetScript("OnClick", function() resolve(PasslootBiS.RollMethod.pass) end)

  active[RollID] = f
  f:Show()

  -- The bounded hold: half the roll window (floored), then fall through.
  f.timer = PasslootBiS:ScheduleTimer(function() resolve(fallbackMethod) end, holdSecs)
end

--------------------------------------------------------------------------------
-- 2c. The gate driver — called from START_LOOT_ROLL before the rollQueue insert
--------------------------------------------------------------------------------

-- Under "trust" mode we auto-cast the strongest allowed intent (Need > Greed >
-- the rule-computed method) with no popup.
local function autoMethod(ctx, RollMethod)
  if ctx.canNeed then return PasslootBiS.RollMethod.need end
  if ctx.canGreed then return PasslootBiS.RollMethod.greed end
  return RollMethod
end

-- Small label helper for the trust-mode chat line (0/1/2/3 -> word).
local METHOD_LABEL = { [0] = "Pass", [1] = "Need", [2] = "Greed", [3] = "Disenchant" }
local function methodLabel(method)
  return METHOD_LABEL[method] or "Ignore"
end

-- Returns true if the advisor took responsibility for this roll (held it behind a
-- popup, or auto-cast it) — in which case START_LOOT_ROLL must NOT also queue.
-- Returns false to let the normal queue proceed (no verdict, or advisory mode).
function PasslootBiS:HandleRoll(RollID, rollTime, itemObj, RollMethod, ctx)
  local api = self.API
  if not api or not api.enabled then return false end

  local verdict, advisorName = api:ConsultAdvisors(ctx)
  if not verdict then return false end

  local mode = api:GetTrustMode(advisorName)
  if mode == "advisory" then
    -- Display-only: the advisor shows its own alert and the user clicks the roll
    -- themselves. The host does not hold — fall through to the normal queue.
    return false
  elseif mode == "trust" then
    local method = autoMethod(ctx, RollMethod)
    self:QueueRoll(RollID, method)
    if not self.db.profile.Quiet then
      self:Print(string.format("|cff33ff99%s|r auto-rolled %s: %s",
        advisorName, methodLabel(method), verdict.reason or ""))
    end
    return true
  else -- "held" (held confirm)
    local holdSecs = RollAdvisor.ResolveHoldSeconds(rollTime, api.minHold, api.margin)
    self:ShowRollConfirm(RollID, ctx, verdict, holdSecs, RollMethod, advisorName)
    return true
  end
end

--------------------------------------------------------------------------------
-- 2d. /plbisadvisor — inspect + set per-advisor trust mode (and master on/off)
--------------------------------------------------------------------------------

function PasslootBiS:AdvisorCommand(input)
  input = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local name, mode = input:match("^(%S*)%s*(%S*)$")

  if name == "on" then
    self.API.enabled = true
    self:Print("roll advisor gate |cff33ff99enabled|r.")
    return
  elseif name == "off" then
    self.API.enabled = false
    self:Print("roll advisor gate |cffff0000disabled|r (rules roll normally).")
    return
  end

  if name == "" then
    self:Print("Roll advisor trust modes (advisory / held / trust):")
    local any = false
    for advName in pairs(advisors) do
      any = true
      self:Print("  " .. advName .. ": |cffffd700" .. self.API:GetTrustMode(advName) .. "|r")
    end
    if not any then self:Print("  (no advisors registered)") end
    self:Print("Usage: /plbisadvisor <name> <advisory|held|trust>  |  /plbisadvisor on|off")
    return
  end

  if mode == "" then
    self:Print(name .. ": |cffffd700" .. self.API:GetTrustMode(name) .. "|r")
    return
  end

  if self.API:SetTrustMode(name, mode) then
    self:Print(name .. " trust mode set to |cff33ff99" .. mode .. "|r.")
  else
    self:Print("invalid mode '" .. tostring(mode) .. "'. Use advisory | held | trust.")
  end
end

if PasslootBiS.RegisterChatCommand then
  PasslootBiS:RegisterChatCommand("plbisadvisor", "AdvisorCommand")
end

return RollAdvisor
