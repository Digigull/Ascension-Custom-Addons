--[[ LoadProfile.lua — per-addon LOAD-TIME cost + login timeline (PURE, tested).

     The initial-load lag is a different scenario from the in-play spikes the
     driver catches: it happens before the first frame the OnUpdate ever sees.
     This module quantifies it.

     THE KEY IDEA — load-time attribution sidesteps the locks that kill runtime
     attribution. Ascension locks per-addon CPU (scriptProfile -> 0) and per-addon
     memory (GetAddOnMemoryUsage -> 0). But ADDON_LOADED fires ONCE PER ADDON,
     SERIALLY, and both debugprofilestop() (ms since login) and
     collectgarbage("count") (aggregate heap KB) work. So the DELTA between two
     consecutive ADDON_LOADED marks is the load cost of the addon that just
     finished loading — in ms (CPU) and KB (Lua heap). That is a real per-addon
     CPU *and* memory channel the engine does not block, available only at load.

     PURE: no WoW APIs. The caller (Core) stamps each mark with a clock reading and
     a heap reading; all the delta math, ranking, and the timeline live here and
     self-test under bare Lua 5.1.

     VISIBILITY FLOOR: the probe can only mark addons that load AFTER its own
     ADDON_LOADED (its listener must exist first). Everything before it is
     UNMEASURABLE here — see the clock note — so we reference the whole timeline to
     the probe's own load (t=0) and report from there, honestly, rather than invent
     a floor number.

     CLOCK NOTE (measured 2026-08-13): debugprofilestop() is monotonic since SYSTEM
     boot — it does NOT reset on /reload, login, OR a full client quit+relaunch (one
     capture read ~59.2M ms ≈ 16 h; a later capture read 62.1M ms, continuous across a
     confirmed full restart — so it tracks OS uptime, not the client process). ABSOLUTE
     readings are therefore system uptime, useless as a load cost; only DELTAS are
     meaningful. This module keeps the first mark's reading as the reference t0 and
     expresses milestones as (clock - t0). Per-addon costs were always deltas, so
     they were correct all along.

     WINDOW: marks are the initial-load cascade only. The caller stops feeding
     ADDON_LOADED at PLAYER_ENTERING_WORLD, so a mid-session load-on-demand addon
     is NOT counted here (that's a runtime spike, a different measurement).
]]

local ADDON, ns = ...
ns = ns or {}

local LoadProfile = {}
LoadProfile.__index = LoadProfile

function LoadProfile.new()
    return setmetatable({
        marks      = {},    -- ordered { name=, ms=, heapKB=, dMs=, dHeapKB= } for attributed addons (post-probe)
        seen       = {},    -- name -> true (dedup: ignore a repeated ADDON_LOADED)
        prevMs     = nil,   -- absolute clock of the previous mark
        prevHeap   = nil,   -- heap at the previous mark
        t0Ms       = nil,   -- clock at the FIRST mark (the probe): the timeline's t=0 reference
        milestones = {},    -- name -> absolute clock (PLAYER_LOGIN, PLAYER_ENTERING_WORLD, ...)
    }, LoadProfile)
end

-- mark(name, nowMs, heapKB): record one ADDON_LOADED.
--   nowMs  = debugprofilestop() (ms since login), absolute; deltas make it per-addon.
--   heapKB = collectgarbage("count") (may be nil if unavailable).
-- The FIRST mark is the probe itself: its clock seeds the t=0 reference (the
-- pre-probe cascade is unmeasurable — see the clock note), and it is not ranked.
-- Every later mark's delta from the previous mark IS that addon's own load cost.
-- A repeated name (rare) is ignored.
function LoadProfile:mark(name, nowMs, heapKB)
    name = tostring(name or "?")
    if self.seen[name] then return end
    self.seen[name] = true
    nowMs = tonumber(nowMs) or 0

    if self.prevMs == nil then
        -- reference: the probe's own load is t=0 for the whole timeline
        self.t0Ms = nowMs
        self.prevMs = nowMs
        self.prevHeap = tonumber(heapKB)
        return
    end

    local dMs = nowMs - self.prevMs
    if dMs < 0 then dMs = 0 end
    local dHeap
    if type(heapKB) == "number" and type(self.prevHeap) == "number" then
        dHeap = heapKB - self.prevHeap
    end
    self.marks[#self.marks + 1] = { name = name, ms = nowMs, heapKB = heapKB,
                                    dMs = dMs, dHeapKB = dHeap }
    self.prevMs = nowMs
    self.prevHeap = tonumber(heapKB) or self.prevHeap
end

-- milestone(name, nowMs): stamp a login-sequence event (PLAYER_LOGIN, etc.).
function LoadProfile:milestone(name, nowMs)
    self.milestones[tostring(name or "?")] = tonumber(nowMs) or 0
end

-- ranked(n) -> desc { name, dMs, dHeapKB } of attributed addons by load ms.
function LoadProfile:ranked(n)
    local out = {}
    for _, m in ipairs(self.marks) do
        out[#out + 1] = { name = m.name, dMs = m.dMs, dHeapKB = m.dHeapKB }
    end
    table.sort(out, function(a, b)
        if a.dMs ~= b.dMs then return a.dMs > b.dMs end
        return tostring(a.name) < tostring(b.name)
    end)
    if n and #out > n then for i = #out, n + 1, -1 do out[i] = nil end end
    return out
end

-- summary() -> the timeline (all times relative to the probe's load, t=0).
--   addons  = attributed addon count (loaded after the probe)
--   capMs   = sum of attributed per-addon load ms
--   loginMs = ms from the probe's load to PLAYER_LOGIN (nil if not reached)
--   worldMs = ms from the probe's load to PLAYER_ENTERING_WORLD (nil if not reached)
-- Absolute clock values are client uptime (see the clock note), so we never
-- expose them — only the probe-relative gaps, which are real durations.
function LoadProfile:summary()
    local capMs, capHeap = 0, 0
    for _, m in ipairs(self.marks) do
        capMs = capMs + (m.dMs or 0)
        if type(m.dHeapKB) == "number" then capHeap = capHeap + m.dHeapKB end
    end
    local function rel(v)
        return (type(v) == "number" and type(self.t0Ms) == "number") and (v - self.t0Ms) or nil
    end
    return {
        addons  = #self.marks,
        capMs   = capMs,
        capHeapKB = capHeap,
        loginMs = rel(self.milestones.PLAYER_LOGIN),
        worldMs = rel(self.milestones.PLAYER_ENTERING_WORLD),
    }
end

-- true once we've captured anything worth reporting (the reference or an addon).
function LoadProfile:hasData()
    return self.t0Ms ~= nil
end

ns.LoadProfile = LoadProfile

--============================================================================--
if _SELFTEST then
    local function eq(a, b, msg)
        assert(a == b, (msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end

    local lp = LoadProfile.new()
    eq(lp:hasData(), false, "empty profile has no data")

    -- first mark = the probe itself: seeds the t=0 reference, not ranked
    lp:mark("ClientPerfProbe", 800, 100000)
    eq(lp:hasData(), true, "reference mark registers data")
    eq(lp:summary().addons, 0, "reference mark is not an attributed addon")
    eq(#lp:ranked(), 0, "reference mark is not ranked")

    -- subsequent marks: delta from previous = that addon's own load cost
    lp:mark("HeavyAddon", 1100, 118000)   -- 300ms, +18MB
    lp:mark("LightAddon", 1150, 118500)   -- 50ms, +0.5MB
    lp:mark("MidAddon",  1300, 120000)    -- 150ms, +1.5MB

    local r = lp:ranked()
    eq(#r, 3, "three attributed addons")
    eq(r[1].name, "HeavyAddon", "ranked desc by load ms")
    eq(r[1].dMs, 300, "delta ms = per-addon load cost")
    eq(r[1].dHeapKB, 18000, "delta heap = per-addon load memory")
    eq(r[2].name, "MidAddon", "second heaviest")
    eq(r[3].name, "LightAddon", "lightest last")

    -- a repeated ADDON_LOADED for the same addon is ignored (no double count)
    lp:mark("HeavyAddon", 1400, 121000)
    eq(#lp:ranked(), 3, "repeated addon name ignored")

    -- milestones + summary totals (milestones are ms since the probe's load, t0=800)
    lp:milestone("PLAYER_LOGIN", 1500)
    lp:milestone("PLAYER_ENTERING_WORLD", 4200)
    local s = lp:summary()
    eq(s.addons, 3, "summary counts attributed addons")
    eq(s.capMs, 500, "summary sums per-addon load ms (300+50+150)")
    eq(s.capHeapKB, 20000, "summary sums per-addon heap (18000+500+1500)")
    eq(s.loginMs, 700, "PLAYER_LOGIN is probe-relative (1500-800), not the raw uptime clock")
    eq(s.worldMs, 3400, "PLAYER_ENTERING_WORLD is probe-relative (4200-800)")

    -- ranked top-n truncation
    eq(#lp:ranked(2), 2, "ranked top-n truncates")

    -- defensive: out-of-order clock never yields a negative cost
    local lp2 = LoadProfile.new()
    lp2:mark("A", 500)          -- floor, no heap
    lp2:mark("B", 400)          -- earlier clock -> clamp to 0, not negative
    eq(lp2:ranked()[1].dMs, 0, "backwards clock clamps to 0")
    eq(lp2:ranked()[1].dHeapKB, nil, "no heap readings -> nil heap delta (not 0)")

    print("LoadProfile: OK")
end

return ns.LoadProfile
