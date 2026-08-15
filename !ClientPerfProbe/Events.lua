--[[ Events.lua — event-rate counters, CLEU firehose focus (README §3 cause C).

     RegisterAllEvents on a dedicated frame and count every event by name. The
     OnEvent handler is deliberately trivial (one table increment + a recent-name
     push) because it runs on the firehose itself — measurement perturbs (§4), so
     keep the perturbation minimal and constant.

     The counting core (Events.Counter) is PURE and self-tested offline; the WoW
     frame just feeds it. CLEU is tracked separately for instantaneous rate.
]]

local ADDON, ns = ...
ns = ns or {}

local CLEU = "COMBAT_LOG_EVENT_UNFILTERED"

-- Streaming-signal events: these fire when a NEW player/unit comes into view and
-- the client must load its character model / portrait / nameplate — the cause-A
-- "Loading players" fingerprint (README, epic-BG findings). Counted separately so
-- a model-streaming stall can self-name even when the UNIT_AURA firehose (63-237/s
-- in a 40v40) floods the recent-event ring and hides these in ev=. A per-frame
-- delta of this counter is the spike's str= field. NOT yet a classifier input —
-- the count is reported; blaming streaming waits on a capture that correlates it.
local STREAM_EVENTS = {
    UNIT_MODEL_CHANGED    = true,
    UNIT_PORTRAIT_UPDATE  = true,
    NAME_PLATE_UNIT_ADDED = true,
}
ns.STREAM_EVENTS = STREAM_EVENTS

--------------------------------------------------------------------------------
-- PURE counting core -----------------------------------------------------------
local Counter = {}
Counter.__index = Counter

function Counter.new()
    return setmetatable({ counts = {}, total = 0, cleu = 0, stream = 0 }, Counter)
end

function Counter:bump(name)
    self.counts[name] = (self.counts[name] or 0) + 1
    self.total = self.total + 1
    if name == CLEU then self.cleu = self.cleu + 1 end
    if STREAM_EVENTS[name] then self.stream = self.stream + 1 end
end

-- rates(elapsedSec) -> desc array of { name, count, perSec }
function Counter:rates(elapsedSec)
    local dt = (type(elapsedSec) == "number" and elapsedSec > 0) and elapsedSec or 1
    local out = {}
    for name, n in pairs(self.counts) do
        out[#out + 1] = { name = name, count = n, perSec = n / dt }
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return out
end

function Counter:reset()
    self.counts = {}
    self.total = 0
    self.cleu = 0
    self.stream = 0
end

ns.EventsCounter = Counter

--------------------------------------------------------------------------------
-- PURE misbehaving-addon namer --------------------------------------------------
-- ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN are SELF-DESCRIBING: the engine
-- fires them with the offending addon + the protected function it retried under
-- combat lockdown (arg1=addon, arg2=function). No heuristic, no scriptProfile —
-- a live capture named ExadTweaks (TargetFrameToT:Show) at 45/s this way for free
-- (CLAUDE.md findings). We rank distinct (addon, func) pairs by how often the
-- client blocked them, so the worst offender is one-shot obvious in the report.
local Blocked = {}
Blocked.__index = Blocked

function Blocked.new()
    return setmetatable({ seen = {}, total = 0 }, Blocked)
end

function Blocked:record(addon, func)
    addon = (addon ~= nil and tostring(addon) ~= "") and tostring(addon) or "?"
    func  = (func ~= nil and tostring(func) ~= "") and tostring(func) or "?"
    local key = addon .. "\1" .. func
    local e = self.seen[key]
    if e then
        e.count = e.count + 1
    else
        self.seen[key] = { addon = addon, func = func, count = 1 }
    end
    self.total = self.total + 1
end

-- ranked(elapsedSec, limit) -> desc array of { addon, func, count, perSec }
function Blocked:ranked(elapsedSec, limit)
    local dt = (type(elapsedSec) == "number" and elapsedSec > 0) and elapsedSec or 1
    local out = {}
    for _, e in pairs(self.seen) do
        out[#out + 1] = { addon = e.addon, func = e.func, count = e.count, perSec = e.count / dt }
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        if a.addon ~= b.addon then return a.addon < b.addon end
        return a.func < b.func
    end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function Blocked:reset()
    self.seen = {}
    self.total = 0
end

ns.BlockedCounter = Blocked

--------------------------------------------------------------------------------
-- WoW wiring -------------------------------------------------------------------
local Events = {}
local counter = Counter.new()
local blocked = Blocked.new()
local windowStart = 0            -- GetTime() when the current count window opened
local recent                     -- RingBuffer of recent event names (context for spikes)

function Events.init()
    counter:reset()
    blocked:reset()
    windowStart = (type(GetTime) == "function") and GetTime() or 0
    -- Deep enough that a firehose (city chat ~14/s, dungeon CLEU) can't flush the
    -- rarer context (e.g. the GLOBAL_MOUSE_DOWN behind a window-drag spike) before
    -- a spike frame reads it. Names only — trivial memory.
    if ns.RingBuffer then recent = ns.RingBuffer.new(32) end

    local f = CreateFrame("Frame", "ClientPerfProbeEvents")
    f:RegisterAllEvents()
    f:SetScript("OnEvent", function(_, event)
        counter:bump(event)
        if recent then recent:push(event) end
    end)
    Events.frame = f

    -- Dedicated frame for the misbehaving-addon namer. Registered narrowly (NOT on
    -- the all-events firehose) so the args capture costs nothing on the CLEU hot
    -- path — it only fires on the rare blocked/forbidden event. arg1=addon,
    -- arg2=protected function retried under lockdown (the ExadTweaks catch).
    local bf = CreateFrame("Frame", "ClientPerfProbeBlocked")
    bf:RegisterEvent("ADDON_ACTION_BLOCKED")
    bf:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    bf:SetScript("OnEvent", function(_, _, addon, func)
        blocked:record(addon, func)
    end)
    Events.blockedFrame = bf
end

-- cumulative CLEU count since window open (Core diffs this per-frame for rate).
function Events.cleuCount() return counter.cleu end
function Events.totalCount() return counter.total end
-- cumulative streaming-signal count (Core diffs this per-frame for a spike's str=).
function Events.streamCount() return counter.stream end
-- cumulative blocked/forbidden count (the Storm monitor diffs this for a live rate).
function Events.blockedTotal() return blocked.total end

-- distinctRecent(names, limit) -> the first `limit` DISTINCT names from a
-- newest-first list, preserving recency order. In a firehose (city chat, dungeon
-- CLEU) the raw last-N slots fill with one repeated event and bury the actual
-- trigger — the first cold-tour capture showed drag spikes with ev=CHAT_MSG_CHANNEL
-- ×4 while the real signal (a window drag = GLOBAL_MOUSE_DOWN, not an event at all)
-- sat one slot deeper. Keeping distinct types surfaces that rarer context. Per-event
-- counts already live in the R rate rows, so dropping repeats loses no attribution.
-- PURE — self-tested.
local function distinctRecent(names, limit)
    limit = limit or 6
    local out, seen = {}, {}
    for i = 1, #names do
        local nm = names[i]
        if nm ~= nil and not seen[nm] then
            seen[nm] = true
            out[#out + 1] = nm
            if #out >= limit then break end
        end
    end
    return out
end
Events._distinctRecent = distinctRecent   -- exposed for the self-test

-- snapshot of recent DISTINCT event types (newest-first) for a spike record.
function Events.recentNames(limit)
    if not recent then return {} end
    -- reduce the full ring (newest-first) to distinct types so a firehose doesn't
    -- crowd out the diagnostic context.
    return distinctRecent(recent:recent(recent:count()), limit or 6)
end

-- ranked rates over the window since the last reset.
function Events.snapshotRates()
    local now = (type(GetTime) == "function") and GetTime() or (windowStart + 1)
    return counter:rates(now - windowStart), (now - windowStart)
end

-- ranked (addon, func) block offenders over the window since the last reset.
function Events.blockedRanked(limit)
    local now = (type(GetTime) == "function") and GetTime() or (windowStart + 1)
    return blocked:ranked(now - windowStart, limit)
end

function Events.reset()
    counter:reset()
    blocked:reset()
    windowStart = (type(GetTime) == "function") and GetTime() or 0
end

ns.Events = Events

--============================================================================--
if _SELFTEST then
    local function eq(a, b, msg)
        assert(a == b, (msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end

    local c = Counter.new()
    c:bump("A"); c:bump("A"); c:bump("B"); c:bump(CLEU); c:bump(CLEU); c:bump(CLEU)
    eq(c.total, 6, "counter total")
    eq(c.cleu, 3, "cleu tracked")
    eq(c.counts["A"], 2, "count A")

    -- streaming-signal counter: the 3 new-player load events feed counter.stream
    -- (the spike str= field) without disturbing the CLEU counter.
    eq(c.stream, 0, "stream starts at 0 (no streaming events yet)")
    c:bump("UNIT_MODEL_CHANGED"); c:bump("UNIT_PORTRAIT_UPDATE")
    c:bump("NAME_PLATE_UNIT_ADDED"); c:bump("UNIT_AURA")
    eq(c.stream, 3, "stream counts only the model/portrait/nameplate load events")
    eq(c.cleu, 3, "streaming events don't touch the CLEU counter")

    local r = c:rates(3)         -- 3 seconds
    eq(r[1].name, CLEU, "rates sorted by count desc")
    eq(r[1].count, 3, "rates count")
    eq(string.format("%.1f", r[1].perSec), "1.0", "rates perSec = count/elapsed")
    -- deterministic tie-break: A(2) before B(1); check A precedes B
    local posA, posB
    for i, e in ipairs(r) do
        if e.name == "A" then posA = i elseif e.name == "B" then posB = i end
    end
    assert(posA < posB, "tie/lower-count ordering deterministic")

    -- elapsed<=0 guard doesn't divide by zero
    local r0 = c:rates(0)
    assert(type(r0[1].perSec) == "number", "rates guards elapsed<=0")

    c:reset()
    eq(c.total, 0, "reset total")
    eq(c.cleu, 0, "reset cleu")
    eq(c.stream, 0, "reset stream")
    eq(next(c.counts), nil, "reset counts")

    -- distinctRecent: firehose can't crowd out rarer recent context
    local dr = Events._distinctRecent
    -- newest-first ring after a chat firehose buried a drag's mouse-down
    local names = { "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL",
                    "GLOBAL_MOUSE_DOWN", "CHAT_MSG_CHANNEL", "WORLD_MAP_UPDATE" }
    local d = dr(names, 6)
    eq(#d, 3, "distinct collapses repeats")
    eq(d[1], "CHAT_MSG_CHANNEL", "distinct keeps newest-first order")
    eq(d[2], "GLOBAL_MOUSE_DOWN", "distinct surfaces the drag signature the firehose buried")
    eq(d[3], "WORLD_MAP_UPDATE", "distinct reaches deeper for more context")
    eq(#dr(names, 2), 2, "distinct respects limit")
    eq(#dr({}, 6), 0, "distinct handles empty")

    -- Blocked namer: rank (addon, func) pairs by count, with rates + limit.
    local B = ns.BlockedCounter
    local b = B.new()
    b:record("ExadTweaks", "TargetFrameToT:Show()")
    b:record("ExadTweaks", "TargetFrameToT:Show()")
    b:record("ExadTweaks", "TargetFrameToT:Show()")
    b:record("OtherAddon", "SomeFrame:Hide()")
    eq(b.total, 4, "blocked total")
    local br = b:ranked(3)                 -- 3-second window
    eq(br[1].addon, "ExadTweaks", "blocked ranks worst offender first")
    eq(br[1].func, "TargetFrameToT:Show()", "blocked keeps the function name")
    eq(br[1].count, 3, "blocked counts repeats of the same (addon,func)")
    eq(string.format("%.1f", br[1].perSec), "1.0", "blocked perSec = count/elapsed")
    eq(br[2].addon, "OtherAddon", "blocked lists the lesser offender second")
    -- nil/empty args degrade to "?" (never crash, never fabricate a name)
    b:record(nil, nil)
    local bany = false
    for _, e in ipairs(b:ranked(1)) do if e.addon == "?" then bany = true end end
    assert(bany, "blocked degrades missing args to '?'")
    -- limit caps the list
    eq(#b:ranked(1, 1), 1, "blocked respects limit")
    b:reset()
    eq(b.total, 0, "blocked reset")
    eq(next(b.seen), nil, "blocked reset clears pairs")

    print("Events: OK")
end

return ns.Events
