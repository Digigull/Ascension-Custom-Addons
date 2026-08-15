--[[ Meter.lua — cooperative per-tag timing + accumulator core (PURE, tested).

     The engine denies us scriptProfile, but debugprofilestop() works. So instead
     of asking the client to profile addons, we let addons (or a future auto-hook
     layer) bracket their own work with a tag, and we accumulate the wall time
     per tag into a ranked table. That is the foundation of the "library other
     addons use" idea: accurate per-addon / per-handler cost without any locked
     API.

     PURE: the clock is injected (debugprofilestop in-game, a fake in tests), so
     this whole module runs and self-tests under bare Lua 5.1.

     Timing is INCLUSIVE wall time between enter/leave (nested different tags
     overlap — that's fine, we rank by inclusive ms). Re-entrancy of the SAME tag
     is depth-guarded so recursion/reentry never double-counts.
]]

local ADDON, ns = ...
ns = ns or {}

local Meter = {}
Meter.__index = Meter

-- new(clock) : clock is a function returning milliseconds (debugprofilestop).
-- May be nil/absent — then timed brackets record 0 ms (but calls still count),
-- so a client without the timer degrades instead of erroring.
function Meter.new(clock)
    return setmetatable({
        clock  = clock,
        totals = {},   -- tag -> { ms = , calls = }
        active = {},   -- tag -> { start = , depth = }  (open brackets)
    }, Meter)
end

function Meter:setClock(clock) self.clock = clock end

local function nowMs(self)
    local c = self.clock
    if type(c) ~= "function" then return 0 end
    local ok, v = pcall(c)
    return (ok and type(v) == "number") and v or 0
end

local function bucket(self, tag)
    local t = self.totals[tag]
    if not t then t = { ms = 0, calls = 0 }; self.totals[tag] = t end
    return t
end

-- Direct accumulate: for authors who already timed the work themselves.
function Meter:add(tag, ms, calls)
    local t = bucket(self, tag)
    t.ms = t.ms + (tonumber(ms) or 0)
    t.calls = t.calls + (tonumber(calls) or 1)
end

function Meter:enter(tag)
    local a = self.active[tag]
    if a then a.depth = a.depth + 1; return end        -- reentrancy: don't restart
    self.active[tag] = { start = nowMs(self), depth = 1 }
end

function Meter:leave(tag)
    local a = self.active[tag]
    if not a then return end
    if a.depth > 1 then a.depth = a.depth - 1; return end
    local ms = nowMs(self) - a.start
    self.active[tag] = nil
    local t = bucket(self, tag)
    t.ms = t.ms + (ms >= 0 and ms or 0)
    t.calls = t.calls + 1
end

-- Time a single call. pcall-guarded so a throwing callee still records, then the
-- error is re-raised unchanged.
function Meter:measure(tag, fn, ...)
    self:enter(tag)
    local ok, r1, r2, r3, r4 = pcall(fn, ...)
    self:leave(tag)
    if not ok then error(r1, 0) end
    return r1, r2, r3, r4
end

-- Wrap a function so every call is measured under tag. The idiomatic library
-- entry point: frame:SetScript("OnEvent", meter:wrap("MyAddon:OnEvent", handler))
function Meter:wrap(tag, fn)
    return function(...) return self:measure(tag, fn, ...) end
end

-- ranked(n) -> desc { tag, ms, calls, perMs } (perMs = ms/calls)
function Meter:ranked(n)
    local out = {}
    for tag, t in pairs(self.totals) do
        out[#out + 1] = { tag = tag, ms = t.ms, calls = t.calls,
                          perMs = (t.calls > 0) and (t.ms / t.calls) or 0 }
    end
    table.sort(out, function(a, b)
        if a.ms ~= b.ms then return a.ms > b.ms end
        return tostring(a.tag) < tostring(b.tag)
    end)
    if n and #out > n then for i = #out, n + 1, -1 do out[i] = nil end end
    return out
end

-- frameDeltas(snap, collect, minMs, maxN)
--   Per-frame attribution primitive for the spike driver. `snap` is a
--   caller-owned table {tag -> ms} holding the totals as of the PREVIOUS call;
--   this updates it IN PLACE to the current totals (no allocation) so successive
--   calls each measure the interval since the last call. The driver calls this
--   every frame to keep `snap` fresh at ~zero cost.
--   When `collect` is true (only on the rare spike frame) it ALSO returns a
--   desc-by-ms list { {name=tag, ms=delta}, ... } of tags whose delta >= minMs,
--   truncated to maxN — ready to drop straight into a spike record's `topCPU`.
--   When `collect` is false it returns nil and allocates nothing (the lean hot
--   path). Emits name= (not tag=) so Report.classify and the S^ `cpu=` field
--   consume it directly — same shape as the Attrib offender list.
function Meter:frameDeltas(snap, collect, minMs, maxN)
    minMs = minMs or 0
    local out
    for tag, t in pairs(self.totals) do
        local d = t.ms - (snap[tag] or 0)
        snap[tag] = t.ms
        if collect and d > 0 and d >= minMs then
            out = out or {}
            out[#out + 1] = { name = tag, ms = d }
        end
    end
    if out then
        table.sort(out, function(a, b)
            if a.ms ~= b.ms then return a.ms > b.ms end
            return tostring(a.name) < tostring(b.name)
        end)
        if maxN and #out > maxN then
            for i = #out, maxN + 1, -1 do out[i] = nil end
        end
    end
    return out
end

function Meter:reset()
    self.totals = {}
    self.active = {}
end

ns.Meter = Meter

--============================================================================--
if _SELFTEST then
    local function eq(a, b, msg)
        assert(a == b, (msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end

    -- injectable fake clock
    local t = 0
    local m = Meter.new(function() return t end)

    -- enter/leave accumulates wall time + call count
    m:enter("A"); t = t + 10; m:leave("A")
    m:enter("A"); t = t + 5;  m:leave("A")
    eq(m.totals["A"].ms, 15, "enter/leave sums ms")
    eq(m.totals["A"].calls, 2, "enter/leave counts calls")

    -- same-tag reentrancy: nested enter/leave counts ONCE, spanning the outer
    m:enter("B"); t = t + 2
      m:enter("B"); t = t + 3; m:leave("B")
      t = t + 4
    m:leave("B")
    eq(m.totals["B"].ms, 9, "reentrant tag spans outer bracket (2+3+4)")
    eq(m.totals["B"].calls, 1, "reentrant tag counts once")

    -- leave without enter is a no-op (defensive)
    m:leave("never")
    eq(m.totals["never"], nil, "stray leave is a no-op")

    -- direct add
    m:add("C", 7, 3)
    eq(m.totals["C"].ms, 7, "add ms")
    eq(m.totals["C"].calls, 3, "add calls")

    -- measure returns the callee's values and records time
    local r = m:measure("D", function(x) t = t + 8; return x * 2 end, 21)
    eq(r, 42, "measure returns callee result")
    eq(m.totals["D"].ms, 8, "measure records ms")

    -- measure re-raises errors but still records the bracket
    local ok = pcall(function() m:measure("D", function() t = t + 1; error("boom") end) end)
    eq(ok, false, "measure re-raises")
    eq(m.totals["D"].calls, 2, "measure records even on error")

    -- wrap
    local w = m:wrap("E", function(x) t = t + 1; return x + 1 end)
    eq(w(9), 10, "wrap passes through result")
    eq(m.totals["E"].ms, 1, "wrap records ms")

    -- ranked: desc by ms, perMs computed
    local r2 = m:ranked()
    eq(r2[1].tag, "A", "ranked top by ms (A=15)")
    eq(r2[1].perMs, 7.5, "ranked perMs = ms/calls")
    -- top-n truncation
    eq(#m:ranked(2), 2, "ranked top-n")

    -- missing clock -> 0 ms, calls still count (graceful, no error)
    local m2 = Meter.new(nil)
    m2:enter("Z"); m2:leave("Z")
    eq(m2.totals["Z"].ms, 0, "no clock -> 0 ms")
    eq(m2.totals["Z"].calls, 1, "no clock -> still counts calls")

    -- frameDeltas: per-interval attribution against a caller-owned snapshot
    local fm = Meter.new(function() return 0 end)
    fm:add("X", 100, 1); fm:add("Y", 40, 1)
    local snap = {}
    local d1 = fm:frameDeltas(snap, true, 0)
    eq(d1[1].name, "X", "frameDeltas ranks by delta desc")
    eq(d1[1].ms, 100, "frameDeltas first delta = full total (empty snapshot)")
    eq(snap.X, 100, "frameDeltas updates snapshot in place")
    -- no new work since the snapshot -> nothing to collect
    eq(fm:frameDeltas(snap, true, 0), nil, "frameDeltas: no delta -> nil list")
    -- add to X only; minMs filters Y's zero delta, delta measures just the interval
    fm:add("X", 30, 1)
    local d3 = fm:frameDeltas(snap, true, 1)
    eq(#d3, 1, "frameDeltas: only positive deltas at/above minMs")
    eq(d3[1].name, "X", "frameDeltas attributes the interval to the active tag")
    eq(d3[1].ms, 30, "frameDeltas measures only the new interval, not the total")
    -- collect=false refreshes the snapshot but returns no list (the lean path)
    fm:add("Y", 5, 1)
    eq(fm:frameDeltas(snap, false), nil, "frameDeltas collect=false returns nil")
    eq(snap.Y, 45, "frameDeltas collect=false still refreshes the snapshot")
    -- maxN truncates the ranked list
    fm:reset(); fm:add("A", 3, 1); fm:add("B", 2, 1); fm:add("C", 1, 1)
    eq(#fm:frameDeltas({}, true, 0, 2), 2, "frameDeltas maxN truncates")

    -- reset
    m:reset()
    eq(next(m.totals), nil, "reset clears totals")

    print("Meter: OK")
end

return ns.Meter
