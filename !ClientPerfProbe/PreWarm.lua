--[[ PreWarm.lua — frontload / pre-warm PLANNER (PURE, tested). PROTOTYPE.

     The one data-backed mitigation candidate (README §7 / ROADMAP §1): the felt
     UI stutter is deterministic engine FIRST-EXERCISE first-layout — the first
     time a window is shown/dragged per client session costs ~600-800 ms, then it's
     free (warm across /reload, cold after a full restart). The lever is to pay that
     cost at LOGIN, when the player won't feel it, by touching each window once.

     THE OPEN QUESTION THIS PROTOTYPE ANSWERS (measure-first, ground rule 1):
     does a PROGRAMMATIC Show()+nudge reproduce the same native first-layout the
     felt manual first-drag pays? If yes, the later drag spike vanishes and the
     lever is real; if no, the whole approach is dead regardless of how we source
     the window list. Self-measure before/after with the normal spike logger.

     WHY A CURATED/OPT-IN LIST, NOT A BLIND EnumerateFrames SWEEP: showing an
     arbitrary frame taints it and runs its OnShow (server queries, state changes),
     and poking a PROTECTED frame under our addon's taint is exactly the
     ADDON_ACTION_BLOCKED storm the tool measured (ExadTweaks, 45/s). So this
     planner NAMES its targets and SKIPS anything protected — the discovery is
     free, the safe actuation is the constrained part.

     PURE: given a target name list and an `inspect(name)` callback that reports a
     frame's properties, plan() returns a warm/skip list. The actual Show/nudge/Hide
     (WoW-facing) lives in Core; this module — the eligibility policy and the skip
     reasons — is decoupled and self-tested under bare Lua 5.1.
]]

local ADDON, ns = ...
ns = ns or {}

local PreWarm = {}

-- Default targets. The owner's actual windows go here — GLOBAL frame names (find
-- one via /framestack, or the addon's XML `name="..."`). Absent/unknown names are
-- skipped gracefully, so a wrong guess costs nothing: use `/cpp prewarm list` to
-- see which resolve and `/cpp prewarm add <Name>` to add one. Kept short on
-- purpose — this is a curated list, not a sweep (see the header).
PreWarm.DEFAULT_TARGETS = {
    "ClientPerfProbeExport",   -- our own copy/paste window: a present, safe demonstrator
    -- e.g. the owner's stutter-y windows (confirm the real names in-game):
    --   "PassLootBiSManagerFrame",
    --   "BiSScannerFrame",
}

-- plan(targets, inspect) -> ordered array of steps:
--     { name=<string>, action="warm"|"skip", reason=<why, skip only>, wasShown=bool }
--   inspect(name) returns a properties table (or nil == absent):
--     { exists=bool, isFrame=bool, protected=bool, shown=bool, movable=bool }
--   Skip reasons, in the order they're checked:
--     "missing"     — no such global / inspect returned nil-ish (addon not loaded)
--     "not-a-frame" — the global exists but has no Show/Hide (not a frame)
--     "protected"   — a secure frame; warming it under our taint risks the blocked
--                     storm (ExadTweaks class) — never poke these
--   wasShown records visibility so the executor can RESTORE it (hide only what we
--   showed; never hide a window the owner already had open). Duplicate and
--   non-string names are dropped so the list can't double-warm or error.
function PreWarm.plan(targets, inspect)
    local steps = {}
    local seen = {}
    for _, name in ipairs(targets or {}) do
        if type(name) == "string" and name ~= "" and not seen[name] then
            seen[name] = true
            local p = inspect(name) or {}
            local action, reason
            if not p.exists then
                action, reason = "skip", "missing"
            elseif not p.isFrame then
                action, reason = "skip", "not-a-frame"
            elseif p.protected then
                action, reason = "skip", "protected"
            else
                action = "warm"
            end
            steps[#steps + 1] = {
                name = name, action = action, reason = reason,
                wasShown = p.shown and true or false,
            }
        end
    end
    return steps
end

-- tally(steps) -> { warmed=<n>, skipped=<n> }. Counts a step as warmed when its
-- action is "warm" (a plan) OR it carries warmed=true (an executed result), so the
-- same helper summarizes both the plan and the post-run results for chat/UI.
function PreWarm.tally(steps)
    local warmed, skipped = 0, 0
    for _, s in ipairs(steps or {}) do
        if s.warmed or s.action == "warm" then warmed = warmed + 1 else skipped = skipped + 1 end
    end
    return { warmed = warmed, skipped = skipped }
end

ns.PreWarm = PreWarm

--============================================================================--
if _SELFTEST then
    local function eq(a, b, m)
        assert(a == b, (m or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end

    -- a fake frame table keyed by name; inspect() reads it
    local world = {
        Movable  = { exists = true, isFrame = true, protected = false, shown = false, movable = true },
        OpenWin  = { exists = true, isFrame = true, protected = false, shown = true,  movable = true },
        Secure   = { exists = true, isFrame = true, protected = true,  shown = false, movable = false },
        NotFrame = { exists = true, isFrame = false },
        -- "Ghost" intentionally absent -> inspect returns nil
    }
    local function inspect(name) return world[name] end

    local steps = PreWarm.plan(
        { "Movable", "OpenWin", "Secure", "NotFrame", "Ghost", "Movable", "", 42 },
        inspect)

    -- dedup + type filter: "Movable" once, "" and 42 dropped entirely
    eq(#steps, 5, "plan dedups and drops non-string/empty names")
    eq(steps[1].name, "Movable", "order preserved")
    eq(steps[1].action, "warm", "eligible frame -> warm")
    eq(steps[1].wasShown, false, "hidden frame records wasShown=false")

    eq(steps[2].name, "OpenWin", "second target")
    eq(steps[2].action, "warm", "already-open frame still warms")
    eq(steps[2].wasShown, true, "open frame records wasShown=true (executor won't hide it)")

    eq(steps[3].action, "skip", "protected frame is skipped")
    eq(steps[3].reason, "protected", "protected skip reason (taint / blocked-storm risk)")

    eq(steps[4].action, "skip", "non-frame global skipped")
    eq(steps[4].reason, "not-a-frame", "not-a-frame reason")

    eq(steps[5].name, "Ghost", "absent target still appears as a skip (so list shows it)")
    eq(steps[5].action, "skip", "absent global skipped")
    eq(steps[5].reason, "missing", "missing reason for an unloaded/absent frame")

    -- tally over the plan
    local t = PreWarm.tally(steps)
    eq(t.warmed, 2, "tally counts warm steps")
    eq(t.skipped, 3, "tally counts skip steps")

    -- tally over executed results (warmed flag instead of action)
    local t2 = PreWarm.tally({ { warmed = true }, { warmed = true }, { skipped = "missing" } })
    eq(t2.warmed, 2, "tally counts executed warmed=true")
    eq(t2.skipped, 1, "tally counts executed non-warmed")

    -- empty / nil inputs are safe
    eq(#PreWarm.plan(nil, inspect), 0, "nil targets -> empty plan")
    eq(PreWarm.tally(nil).warmed, 0, "nil tally -> zero")

    print("PreWarm: OK")
end

return ns.PreWarm
