--[[ contract-check.lua -- the PasslootBiS <-> PassLootBiS_Scanner verdict contract.

Run from the REPO ROOT:   lua5.1 management/addons/passlootbis/tools/contract-check.lua

The two addons ship separately and are wired together only by the shape of one
table: the scanner builds it in Core/Verdict.lua, the host reads it in
Core/RollAdvisor.lua's NormalizeVerdict. Nothing in either addon fails if they
drift -- a field the host does not know about is silently dropped on arrival, and
the feature it belonged to just quietly stops working in game. That is exactly the
kind of break nobody notices for a month, so it gets a test.

Both halves are pure Lua with no WoW API, which is what makes this runnable at all.
It pipes a verdict through the real files end to end (build -> normalize -> mask ->
actionable), and checks the win-ledger displacement that feeds the compare target.

Not shipped: lives under management/ per management/docs/CLAUDE.md.
]]

_G.PLBiSScanner = {}
local Verdict   = dofile("PassLootBiS_Scanner/Core/Verdict.lua")
local Score     = dofile("PassLootBiS_Scanner/Core/Score.lua")
local Slots     = dofile("PassLootBiS_Scanner/Core/Slots.lua")
local WonLedger = dofile("PassLootBiS_Scanner/Core/WonLedger.lua")
local Advisor   = dofile("PasslootBiS/Core/RollAdvisor.lua")

local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end

-- Full pipe: scanner side -> wire -> host side.
local function pipe(isUpgrade, delta, goldText, down, useGear, useValue, useBiS)
  local wire = Verdict.build(isUpgrade, delta, goldText, down)
  if wire == nil then return nil end
  return Advisor.ApplySources(Advisor.NormalizeVerdict(wire), useGear, useValue, useBiS)
end

-- 1. The headline case: BiS item, scores 12% under what it replaces, no gold.
local v = pipe(false, 0, nil, { delta = -0.12 })
ok(v ~= nil, "BiS downgrade produces a verdict at all")
ok(v.downgrade == true, "downgrade survives the wire")
ok(v.upgrade == false and v.highValue == false, "downgrade alone sets nothing else")
ok(math.abs(v.downDelta + 0.12) < 1e-9, "downDelta survives the wire")
ok(Advisor.IsActionable(v), "downgrade is actionable (the host must speak)")
ok(v.reason:find("BiS list", 1, true) ~= nil, "reason names the BiS list: " .. v.reason)
ok(v.reason:find("-12%", 1, true) ~= nil, "reason quotes the delta: " .. v.reason)

-- 2. Named-win variant (the "you already won these shoulders" case).
local v2 = pipe(false, 0, nil, { delta = -0.09, wonName = "Kyrstel Mantle" })
ok(v2.reason:find("Kyrstel Mantle", 1, true) ~= nil, "reason names what beat it: " .. v2.reason)

-- 3. Turning BiS Check off must return the roll to old behaviour: no verdict.
local v3 = pipe(false, 0, nil, { delta = -0.12 }, true, true, false)
ok(not Advisor.IsActionable(v3), "bis source off -> abstain -> rules roll as before")

-- 4. Turning BiS Check off must NOT disturb the other two reasons.
local v4 = pipe(true, 0.08, "~250g", nil, true, true, false)
ok(v4.upgrade and v4.highValue, "bis off leaves upgrade + value intact")

-- 5. An old scanner (no 4th arg) still produces exactly what it always did.
local v5 = pipe(true, 0.08, nil, nil)
ok(v5.upgrade and v5.downgrade == false, "pre-BiS-Check verdict unchanged")
ok(Verdict.build(false, 0, nil, nil) == nil, "no reason at all -> still abstains")

-- 6. Contradictory advisor: both better and worse. Upgrade must win, both halves.
local v6 = pipe(true, 0.08, nil, { delta = -0.12 })
ok(v6.upgrade and not v6.downgrade, "upgrade beats downgrade end to end")

-- 7. The scenario the user described, scored for real.
--    Shoulders: equipped 100. Win a 130 pair mid-run (still in bags). A 110 pair
--    then drops -- better than what you WEAR, worse than what you WON, and on the
--    BiS list.
local equipped = { 100 }
WonLedger.record("INVTYPE_SHOULDER", 130, "|Hitem:1|h[Won Mantle]|h", "Won Mantle")
local withWins = WonLedger.applyWins(equipped, WonLedger.winsFor("INVTYPE_SHOULDER"))
local target = Slots.worstEquipped(withWins)
ok(target == 130, "target rises to the won item, not the worn one (got " .. target .. ")")
local up, d = Score.verdict(110, target, 0.03)
ok(not up, "the lesser second drop is NOT an upgrade any more")
ok(d < 0, "and it scores negative against the run's real best")
local v7 = pipe(up, d, nil, { delta = d, wonName = WonLedger.bestFor("INVTYPE_SHOULDER").name })
ok(v7.downgrade, "so BiS Check fires on it")

--    Without the ledger it would have looked like a +10% upgrade and auto-rolled.
local up0 = Score.verdict(110, Slots.worstEquipped(equipped), 0.03)
ok(up0, "control: against equipped alone it WOULD have read as an upgrade")

-- 8. Rings: a second ring worse than the one you won is still an upgrade over the
--    other finger. The ledger must not over-suppress here.
WonLedger.clear()
WonLedger.record("INVTYPE_FINGER", 130, "|Hitem:2|h[Won Ring]|h", "Won Ring")
local ringTarget = Slots.worstEquipped(
  WonLedger.applyWins({ 100, 110 }, WonLedger.winsFor("INVTYPE_FINGER")))
ok(ringTarget == 110, "ring target is the surviving finger, not the win (got " .. ringTarget .. ")")
ok((Score.verdict(120, ringTarget, 0.03)), "a 120 ring is still a real upgrade")

print(string.format("contract check: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
