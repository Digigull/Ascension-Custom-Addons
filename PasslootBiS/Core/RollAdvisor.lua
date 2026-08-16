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

-- Mask a verdict by which ADVICE SOURCES the user has left switched on (the two
-- checkboxes on the rules page's advisor status panel). An advisor reports two
-- independent reasons to prompt — a stat upgrade and a high auction value — and
-- either can be turned off without touching the other, or the scanner's own
-- settings, or the trust mode.
--
-- The `reason` is dropped when masking actually suppresses a flag: it is a single
-- human string built by the ADVISOR ("Upgrade +8% / ~120g -- worth Need"), so with
-- one half switched off we cannot honestly attribute the halves without parsing a
-- format that belongs to another addon. Better a headline with no detail than a
-- detail line describing advice the user turned off. Untouched when nothing is
-- masked, which is the default and the common case.
function RollAdvisor.ApplySources(v, useGear, useValue)
  if type(v) ~= "table" then return v end
  -- nil means "not configured" and defaults ON, so only an explicit false hides.
  local upgrade   = (useGear  ~= false) and (v.upgrade == true)
  local highValue = (useValue ~= false) and (v.highValue == true)
  local masked = (v.upgrade == true and not upgrade) or (v.highValue == true and not highValue)
  return {
    upgrade   = upgrade,
    highValue = highValue,
    delta     = upgrade and (tonumber(v.delta) or 0) or 0,
    reason    = (not masked) and v.reason or nil,
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

  -- ApplySources
  local both = { upgrade = true, highValue = true, delta = 0.08, reason = "Upgrade +8% / ~120g" }
  local s1 = RollAdvisor.ApplySources(both, true, true)
  ok(s1.upgrade and s1.highValue, "sources both on -> both flags kept")
  ok(s1.reason == "Upgrade +8% / ~120g", "nothing masked -> reason kept")
  near(s1.delta, 0.08, "nothing masked -> delta kept")
  local s2 = RollAdvisor.ApplySources(both, false, true)
  ok(not s2.upgrade and s2.highValue, "gear off -> only high value survives")
  ok(s2.reason == nil, "masked -> advisor's combined reason dropped")
  near(s2.delta, 0, "gear off -> delta zeroed")
  local s3 = RollAdvisor.ApplySources(both, true, false)
  ok(s3.upgrade and not s3.highValue, "value off -> only upgrade survives")
  local s4 = RollAdvisor.ApplySources(both, false, false)
  ok(not RollAdvisor.IsActionable(s4), "both off -> verdict is not actionable")
  -- nil = unconfigured, which must behave as ON (that is the shipped default).
  local s5 = RollAdvisor.ApplySources(both, nil, nil)
  ok(s5.upgrade and s5.highValue and s5.reason == both.reason, "nil sources default to on")
  -- Masking a flag the verdict never set is not "masking" -- the reason stays.
  local onlyValue = { highValue = true, reason = "~120g" }
  local s6 = RollAdvisor.ApplySources(onlyValue, false, true)
  ok(s6.highValue and s6.reason == "~120g", "turning off an unset flag keeps the reason")
  ok(RollAdvisor.ApplySources(nil, true, true) == nil, "non-table passes through")

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
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

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

-- Read-only view of the registry, for status displays (the rules page's advisor
-- panel, Core/AdvisorStatus.lua) and /plbisadvisor. Sorted so a polled display
-- doesn't reshuffle between refreshes.
function API:GetAdvisorNames()
  local out = {}
  for name in pairs(advisors) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

function API:HasAdvisor(name)
  return advisors[name] ~= nil
end

-- The object an advisor registered with (nil for a plain-function advisor, or if
-- the name isn't registered). This is the ONE handle on a companion addon that
-- needs nothing from the global namespace: an addon's `...` table is private, so
-- a companion that never publishes a global is still reachable here. The status
-- panel reads the scanner's GetStatus through it.
function API:GetAdvisor(name)
  local entry = advisors[name]
  return entry and entry.obj or nil
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

-- The two advice sources the user can switch off independently, from the
-- checkboxes on the rules page's status panel. Both default ON: an absent key
-- means "never configured", not "off", so an existing profile keeps behaving
-- exactly as it did before these toggles existed.
API.SOURCES = { gear = true, value = true }

local function sourceStore()
  local p = PasslootBiS.db and PasslootBiS.db.profile
  if not p then return nil end
  if type(p.RollAdvisor) ~= "table" then p.RollAdvisor = {} end
  if type(p.RollAdvisor.sources) ~= "table" then p.RollAdvisor.sources = {} end
  return p.RollAdvisor.sources
end

function API:IsSourceEnabled(key)
  if not API.SOURCES[key] then return false end
  local store = sourceStore()
  return not (store and store[key] == false)
end

function API:SetSourceEnabled(key, on)
  if not API.SOURCES[key] then return false end
  local store = sourceStore()
  if not store then return false end
  store[key] = on and true or false
  return true
end

-- Saved geometry for the held-confirm popup: where the user dragged it and what
-- size they stretched it to. Lives in the profile so it travels with the rest of
-- the rule setup. Empty until the window is first moved or resized.
local function windowStore()
  local p = PasslootBiS.db and PasslootBiS.db.profile
  if not p then return nil end
  if type(p.RollAdvisor) ~= "table" then p.RollAdvisor = {} end
  if type(p.RollAdvisor.window) ~= "table" then p.RollAdvisor.window = {} end
  return p.RollAdvisor.window
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
      -- Mask by the user's source toggles BEFORE the actionable test, so a verdict
      -- whose only reason was switched off abstains here and the next advisor still
      -- gets its turn (rather than this one claiming the roll and then prompting
      -- with nothing to say).
      local v = RollAdvisor.ApplySources(RollAdvisor.NormalizeVerdict(raw),
        self:IsSourceEnabled("gear"), self:IsSourceEnabled("value"))
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

-- Deliberately narrow: the popup interrupts a fight, so it says one thing in one
-- glance. The user can stretch it from the corner grip and the size sticks.
-- Height leaves room for a long item name to wrap beside the icon and still clear
-- the countdown bar: the text block grows downward from the top while the bar and
-- buttons are anchored up from the bottom, so too little height overlaps them.
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 220, 150
local MIN_WIDTH, MIN_HEIGHT = 170, 120
local MAX_WIDTH, MAX_HEIGHT = 600, 320
local SLOT_GAP = 8          -- vertical space between stacked popups
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
-- Where the first popup sits until the user drags it somewhere else: centred at
-- the top of the screen, clear of the very edge. High enough to be out of the way
-- of the action, and the stacking offset runs downward from here into empty space.
local DEFAULT_ANCHOR = { ["point"] = "TOP", ["relPoint"] = "TOP", ["x"] = 0, ["y"] = -20 }
local BTN_HEIGHT = 22
local BTN_BOTTOM = 16       -- clears the resize grip in the bottom-right corner

-- The verdict headline: the whole point of the window, so it is large, coloured,
-- and says which KIND of advice this is. Green for a stat upgrade, gold for gold.
local HEADLINE_UPGRADE = { text = L["RollAdvisor_GearUpgrade"], r = 0.1, g = 1.0, b = 0.4 }
local HEADLINE_VALUE   = { text = L["RollAdvisor_HighValue"],   r = 1.0, g = 0.82, b = 0.0 }

local function acquireSlot()
  local i = 1
  while occupied[i] do i = i + 1 end
  occupied[i] = true
  return i
end

-- Buttons share the width evenly, so the row still fits when the frame is shrunk
-- to MIN_WIDTH and spreads out when it is stretched. Everything else takes its
-- width from edge anchors and needs no help here.
local function layoutFrame(f)
  if not f.needBtn then return end   -- called before the row exists; nothing to lay out
  local w = f:GetWidth() or DEFAULT_WIDTH
  local btnW = math.floor((w - 24 - 12) / 3)   -- 12px margins, two 6px gaps
  if btnW < 40 then btnW = 40 end
  f.needBtn:SetWidth(btnW)
  f.greedBtn:SetWidth(btnW)
  f.passBtn:SetWidth(btnW)
end

-- Persist where the user put the window and how big they made it.
local function saveGeometry(f)
  local store = windowStore()
  if not store then return end
  local point, _, relPoint, x, y = f:GetPoint()
  if point then
    -- Store where SLOT 1 would sit. Dragging the second popup of a busy roll
    -- otherwise saves a position one slot lower and walks the window down the
    -- screen a little further on every subsequent multi-roll.
    local step = (f:GetHeight() or DEFAULT_HEIGHT) + SLOT_GAP
    store.point, store.relPoint, store.x = point, relPoint, x
    store.y = y + (((f.slot or 1) - 1) * step)
  end
  store.width, store.height = f:GetWidth(), f:GetHeight()
end

local function applyGeometry(f)
  local store = windowStore()
  local w = (store and tonumber(store.width)) or DEFAULT_WIDTH
  local h = (store and tonumber(store.height)) or DEFAULT_HEIGHT
  if w < MIN_WIDTH then w = MIN_WIDTH elseif w > MAX_WIDTH then w = MAX_WIDTH end
  if h < MIN_HEIGHT then h = MIN_HEIGHT elseif h > MAX_HEIGHT then h = MAX_HEIGHT end
  f:SetWidth(w)
  f:SetHeight(h)
  layoutFrame(f)
end

-- Place the frame at its saved anchor, offset downward by its stacking slot.
local function placeFrame(f, slot)
  local store = windowStore()
  local step = (f:GetHeight() or DEFAULT_HEIGHT) + SLOT_GAP
  local dy = -((slot - 1) * step)
  f:ClearAllPoints()
  if store and store.point and tonumber(store.x) and tonumber(store.y) then
    f:SetPoint(store.point, UIParent, store.relPoint or store.point, store.x, store.y + dy)
  else
    f:SetPoint(DEFAULT_ANCHOR.point, UIParent, DEFAULT_ANCHOR.relPoint,
      DEFAULT_ANCHOR.x, DEFAULT_ANCHOR.y + dy)
  end
end

local function makeFrame()
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetWidth(DEFAULT_WIDTH)
  f:SetHeight(DEFAULT_HEIGHT)
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
  f:SetResizable(true)
  f:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
  f:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
  f:SetScript("OnDragStop", function(fr)
    fr:StopMovingOrSizing()
    saveGeometry(fr)
  end)
  -- Item icon, and the hover behaviour of a real loot roll button: the item
  -- tooltip on mouseover, and modified-click to link it into chat or send it to
  -- the dressing room. The tooltip comes from SetLootRollItem where possible —
  -- that is the exact call Blizzard's GroupLootFrame makes, so it shows what the
  -- stock roll window shows (including the red "can't use this" lines).
  f.icon = CreateFrame("Button", nil, f)
  f.icon:SetWidth(32)
  f.icon:SetHeight(32)
  f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10)
  f.icon:SetNormalTexture(FALLBACK_ICON)
  local iconTex = f.icon:GetNormalTexture()
  if iconTex then iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93) end   -- trim the stock border
  f.icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  f.icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  -- Reads f.rollID / f.itemLink / f.preview, which Show sets per roll: the frame
  -- itself is pooled and reused, so nothing here may close over one roll's values.
  f.icon:SetScript("OnEnter", function(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    local shown = false
    if not f.preview and f.rollID and GameTooltip.SetLootRollItem then
      shown = pcall(GameTooltip.SetLootRollItem, GameTooltip, f.rollID)
    end
    if not shown and f.itemLink then
      shown = pcall(GameTooltip.SetHyperlink, GameTooltip, f.itemLink)
    end
    if shown then GameTooltip:Show() else GameTooltip:Hide() end
  end)
  f.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.icon:SetScript("OnClick", function()
    local handle = rawget(_G, "HandleModifiedItemClick")
    if handle and f.itemLink then handle(f.itemLink) end
  end)

  -- Verdict headline. Large and coloured; this is what you read.
  f.headline = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.headline:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 8, 0)
  f.headline:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
  f.headline:SetJustifyH("LEFT")

  -- One supporting line: the item, plus the advisor's reason when there is one.
  f.item = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.item:SetPoint("TOPLEFT", f.headline, "BOTTOMLEFT", 0, -3)
  f.item:SetPoint("TOPRIGHT", f.headline, "BOTTOMRIGHT", 0, -3)
  f.item:SetJustifyH("LEFT")

  local function mkBtn(label)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetWidth(60)
    b:SetHeight(BTN_HEIGHT)
    b:SetText(label)
    return b
  end
  f.needBtn  = mkBtn(rawget(_G, "NEED") or "Need")
  f.greedBtn = mkBtn(rawget(_G, "GREED") or "Greed")
  f.passBtn  = mkBtn(rawget(_G, "PASS") or "Pass")
  f.needBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, BTN_BOTTOM)
  f.greedBtn:SetPoint("LEFT", f.needBtn, "RIGHT", 6, 0)
  f.passBtn:SetPoint("LEFT", f.greedBtn, "RIGHT", 6, 0)

  -- Countdown bar, sitting on top of the button row so it tracks a resize from
  -- the bottom up while the text above tracks from the top down.
  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetStatusBarColor(0.25, 0.6, 1)
  f.bar:SetHeight(10)
  f.bar:SetPoint("BOTTOMLEFT", f.needBtn, "TOPLEFT", 0, 6)
  f.bar:SetPoint("BOTTOMRIGHT", f.passBtn, "TOPRIGHT", 0, 6)
  f.bar:SetBackdrop({
    ["bgFile"] = "Interface\\TargetingFrame\\UI-StatusBar",
    ["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
    ["edgeSize"] = 8,
    ["insets"] = { ["left"] = 1, ["right"] = 1, ["top"] = 1, ["bottom"] = 1 },
  })
  f.timeText = f.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.timeText:SetPoint("CENTER", f.bar, "CENTER", 0, 0)

  -- Corner grip: drag to stretch or shrink. Sits below the button row (they end
  -- at BTN_BOTTOM = the grip's height) so the two never fight over a click.
  f.grip = CreateFrame("Button", nil, f)
  f.grip:SetWidth(16)
  f.grip:SetHeight(16)
  f.grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, -1)
  f.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  f.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  f.grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  f.grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  f.grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    layoutFrame(f)
    saveGeometry(f)
  end)

  -- Wired LAST, deliberately: OnSizeChanged fires during a live drag-resize and
  -- reaches for the buttons, which only exist from here on.
  f:SetScript("OnSizeChanged", function(fr) layoutFrame(fr) end)

  return f
end

-- Point the headline at the right verdict. Upgrade wins when both apply: it is
-- the stronger claim, and the value half still shows in the reason line.
local function applyHeadline(f, verdict)
  local h = verdict.upgrade and HEADLINE_UPGRADE or HEADLINE_VALUE
  f.headline:SetText(h.text)
  f.headline:SetTextColor(h.r, h.g, h.b)
end

-- The item's icon. GetLootRollItemInfo is asked FIRST for a live roll: it is the
-- loot frame's own source and it answers on a first-see item, where GetItemInfo
-- still returns nil until the client has cached it (Core/RollRetry.lua).
local function resolveTexture(rollID, itemLink, isPreview)
  if not isPreview and rollID then
    local gi = rawget(_G, "GetLootRollItemInfo")
    if gi then
      local ok, texture = pcall(gi, rollID)
      if ok and texture then return texture end
    end
  end
  if itemLink and rawget(_G, "GetItemInfo") then
    local ok, _, _, _, _, _, _, _, _, _, texture = pcall(GetItemInfo, itemLink)
    if ok and texture then return texture end
  end
  return FALLBACK_ICON
end

local function setIconTexture(f, texture)
  f.icon:SetNormalTexture(texture)
  local tex = f.icon:GetNormalTexture()
  if tex then tex:SetTexCoord(0.07, 0.93, 0.07, 0.93) end   -- trim the stock border
end

-- Bind one roll's item to the pooled frame: icon, and the fields its permanently
-- installed hover/click handlers read.
--
-- `iconResolved` false means we are still showing the question mark. GetItemInfo
-- populates ASYNCHRONOUSLY: for an item the client has never seen, the first query
-- returns nil and is itself what starts the fill, so the icon cannot be right on
-- the first attempt however early we ask. The OnUpdate loop retries until it
-- lands (see retryIcon) rather than leaving a question mark up for the whole roll.
local function applyItem(f, rollID, ctx, isPreview)
  f.rollID = rollID
  f.itemLink = ctx.itemLink
  local texture = resolveTexture(rollID, ctx.itemLink, isPreview)
  f.iconResolved = (texture ~= FALLBACK_ICON)
  setIconTexture(f, texture)
end

-- Re-ask for the icon. Cheap: two table lookups and a client call, run at most a
-- few times a second and only until it resolves.
local function retryIcon(f)
  local texture = resolveTexture(f.rollID, f.itemLink, f.preview)
  if texture ~= FALLBACK_ICON then
    setIconTexture(f, texture)
    f.iconResolved = true
  end
end

-- Show a bounded-hold confirm for one roll. On a button click cast that choice;
-- on timeout fall through to `fallbackMethod` (the rule-computed RollMethod, which
-- may be nil = don't roll, exactly as PassLoot behaves today).
--
-- `isPreview` drives the "Show Loot Advisor" button on the rules page: an
-- identical window, on a fake roll, that never queues a roll when it resolves.
-- It exists so the geometry above can be set up out of combat instead of during
-- the few seconds of a real roll.
function PasslootBiS:ShowRollConfirm(RollID, ctx, verdict, holdSecs, fallbackMethod, advisorName, isPreview)
  if active[RollID] then return end   -- already prompting this roll

  local f = table.remove(POOL) or makeFrame()
  f.slot = acquireSlot()
  f.resolved = false
  f.preview = isPreview and true or false
  applyGeometry(f)
  placeFrame(f, f.slot)

  applyHeadline(f, verdict)
  applyItem(f, RollID, ctx, f.preview)
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
    -- Throttled (~3/sec) re-checks of the two things the client answers late.
    if not fr.resolved and now >= fr.nextElig then
      fr.nextElig = now + 0.3
      -- Roll eligibility. Skipped for the preview, whose RollID is a sentinel the
      -- client knows nothing about.
      if not fr.preview then
        local gi = rawget(_G, "GetLootRollItemInfo")
        if gi then
          local ok, _, _, _, _, _, cn, cg = pcall(gi, RollID)
          if ok then applyElig(cn and true or false, cg and true or false) end
        end
      end
      -- The icon, until it lands. An item the client has never seen resolves one
      -- query AFTER the one that triggered its cache fill, so the first attempt in
      -- applyItem necessarily draws the question mark.
      if not fr.iconResolved then
        retryIcon(fr)
      end
    end
  end)

  local function resolve(method)
    if f.resolved then return end
    f.resolved = true
    if f.timer then PasslootBiS:CancelTimer(f.timer); f.timer = nil end
    f:SetScript("OnUpdate", nil)
    -- Keep whatever the user dragged/stretched it to while it was on screen.
    saveGeometry(f)
    f:Hide()
    active[RollID] = nil
    occupied[f.slot] = nil
    POOL[#POOL + 1] = f
    -- A preview resolves exactly like the real thing, minus the one line that
    -- matters: it never casts a roll.
    if not f.preview then
      PasslootBiS:QueueRoll(RollID, method)
    end
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
-- 2b-ii. The preview ("Show Loot Advisor" on the rules page)
--------------------------------------------------------------------------------
-- A real roll gives you a handful of seconds to notice the popup, which is no
-- time at all to decide where you want it to live. This shows the same window on
-- a fake roll so it can be dragged, stretched and dismissed at leisure.

local PREVIEW_ROLLID = -424242   -- can never collide with a live rollID
local previewFlip = false        -- alternate the two headline styles per showing

-- A real item, so the preview exercises the real icon and tooltip path rather
-- than a placeholder: Thunderfury, Blessed Blade of the Windseeker.
-- https://db.ascension.gg/?item=19019
local PREVIEW_ITEM_ID = 19019
local PREVIEW_ITEM_NAME = "Thunderfury, Blessed Blade of the Windseeker"

-- The preview item's link. GetItemInfo returns nil until the client has cached
-- the item, and asking is itself what starts the cache fill — so a first press on
-- a cold cache falls back to a hand-built link (which still renders, and which
-- SetHyperlink still resolves server-side), and a later press gets the real one.
local function previewItemLink()
  if rawget(_G, "GetItemInfo") then
    local ok, _, link = pcall(GetItemInfo, PREVIEW_ITEM_ID)
    if ok and link then return link end
  end
  return "|cffff8000|Hitem:" .. PREVIEW_ITEM_ID .. ":0:0:0:0:0:0:0:0|h[" ..
    PREVIEW_ITEM_NAME .. "]|h|r"
end

function PasslootBiS:IsRollConfirmPreviewShown()
  return active[PREVIEW_ROLLID] ~= nil
end

-- Ask the client about the preview item ahead of time. The return value is
-- deliberately unused: the CALL is the point, because the first GetItemInfo for an
-- item the client has never seen returns nil and merely starts the cache fill. The
-- status panel calls this when it opens, so by the time the button is clicked the
-- icon is already there and no question mark is ever drawn.
function PasslootBiS:WarmRollConfirmPreview()
  previewItemLink()
end

function PasslootBiS:ShowRollConfirmPreview()
  if self:IsRollConfirmPreviewShown() then return end
  -- Alternate green "Gear Upgrade" and gold "High Value" on successive showings,
  -- so both looks can be checked without contriving a real roll of each kind.
  previewFlip = not previewFlip
  local verdict = previewFlip
    and { upgrade = true,  highValue = false, delta = 0.08, reason = "Upgrade +8%" }
    or  { upgrade = false, highValue = true,  delta = 0,    reason = "~250g -- worth Need" }
  local ctx = {
    itemLink = previewItemLink(),
    canNeed = true,
    canGreed = true,
  }
  self:ShowRollConfirm(PREVIEW_ROLLID, ctx, verdict, 20, nil, "preview", true)
end

function PasslootBiS:HideRollConfirmPreview()
  local f = active[PREVIEW_ROLLID]
  if not f then return end
  -- Route through the frame's own Pass button so teardown takes exactly the same
  -- path as a real dismissal (timer cancelled, slot released, frame pooled).
  f.passBtn:Click()
end

function PasslootBiS:ToggleRollConfirmPreview()
  if self:IsRollConfirmPreviewShown() then
    self:HideRollConfirmPreview()
  else
    self:ShowRollConfirmPreview()
  end
  return self:IsRollConfirmPreviewShown()
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
