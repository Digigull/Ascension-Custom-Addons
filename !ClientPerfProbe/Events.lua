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
-- PURE per-CHANNEL chat counting ----------------------------------------------
-- Why this exists: a live Ironforge capture came back with CHAT_MSG_CHANNEL at
-- 109.3/s — 14,231 messages in 130s, which at the observed sizes is essentially the
-- whole 19.2 KB/s inbound. The R rate row can say "chat is the firehose" but not
-- WHICH channel or WHO, and that distinction IS the diagnosis: an addon cannot make
-- CHAT_MSG_CHANNEL fire for traffic you would not otherwise receive UNLESS something
-- joined a channel. "Trade - City" at the top means genuine spam and no addon is at
-- fault; an unrecognised channel means something joined it on your behalf. Same
-- honest-attribution principle as the Blocked counter — the event carries the answer,
-- we only have to keep it.
--
-- MESSAGE TEXT IS NEVER STORED, only the channel, the sender, a count and a byte
-- total. The report is a copy/paste blob the owner pastes in public; it must not
-- carry other people's conversations. Byte totals are kept because they are what
-- ties an event rate to the observed inbound bandwidth.
local Chat = {}
Chat.__index = Chat

-- Distinct senders tracked per channel. A flood is a repeat offender, so the top
-- sender lands well inside this; the cap only bounds a channel with thousands of
-- distinct speakers, and capped=true says when it bit.
Chat.SENDER_CAP = 48

function Chat.new()
    return setmetatable({ chans = {}, total = 0 }, Chat)
end

-- record one CHAT_MSG_CHANNEL: channel base name (arg9), channel index (arg8),
-- sender (arg2), and the message LENGTH (never the message).
function Chat:record(name, id, sender, bytes)
    name = (type(name) == "string" and name ~= "") and name or "?"
    local c = self.chans[name]
    if not c then
        c = { name = name, id = tonumber(id), n = 0, bytes = 0,
              senders = {}, distinct = 0, capped = false }
        self.chans[name] = c
    end
    c.n = c.n + 1
    -- bytes arrives as a number from the caller's #message; a tonumber() call here
    -- would be a wasted C call on a path that runs at the flood rate.
    c.bytes = c.bytes + ((type(bytes) == "number") and bytes or 0)
    if c.id == nil then c.id = tonumber(id) end
    self.total = self.total + 1

    if type(sender) == "string" and sender ~= "" then
        local have = c.senders[sender]
        if have then
            c.senders[sender] = have + 1
        elseif c.distinct < Chat.SENDER_CAP then
            c.senders[sender] = 1
            c.distinct = c.distinct + 1
        else
            c.capped = true
        end
    end
end

-- ranked(elapsedSec, limit, joined) -> desc array of per-channel rows.
-- `joined` is an optional { [channelId] = name } map from GetChannelList(). Channels
-- in it that carried NO traffic are still emitted at n=0 — a data channel something
-- joined silently is exactly what we are hunting and it may be quiet in this window.
-- Matching is by channel ID, not name: GetChannelList's naming need not match arg9's,
-- and an ID is the one key both sides agree on.
function Chat:ranked(elapsedSec, limit, joined)
    local dt = (type(elapsedSec) == "number" and elapsedSec > 0) and elapsedSec or 1
    local out = {}
    for name, c in pairs(self.chans) do
        -- Tri-state, and it must NOT be written as `cond and X or nil`: when X is
        -- false that idiom yields nil, collapsing "definitely not joined" into
        -- "unknown" — the one verdict this row exists to deliver.
        --   true  = we can enumerate channels and this is one of them
        --   false = we can enumerate channels and this is NOT one (suspicious)
        --   nil   = GetChannelList unavailable, so no opinion
        local isJoined
        if type(joined) == "table" and c.id ~= nil then
            isJoined = (joined[c.id] ~= nil)
        end
        local topName, topN = nil, 0
        for sender, n in pairs(c.senders) do
            -- name ascending breaks a tie so the row is deterministic
            if n > topN or (n == topN and topName and sender < topName) then
                topName, topN = sender, n
            end
        end
        out[#out + 1] = {
            name = name, id = c.id, count = c.n, perSec = c.n / dt,
            kbPerSec = (c.bytes / 1024) / dt,
            senders = c.distinct, capped = c.capped,
            top = topName, topCount = topN,
            joined = isJoined,
        }
    end
    if type(joined) == "table" then
        local seen = {}
        for _, c in pairs(self.chans) do if c.id then seen[c.id] = true end end
        for id, nm in pairs(joined) do
            if not seen[id] then
                out[#out + 1] = { name = nm, id = id, count = 0, perSec = 0,
                                  kbPerSec = 0, senders = 0, joined = true }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return tostring(a.name) < tostring(b.name)
    end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function Chat:reset()
    self.chans = {}
    self.total = 0
end

ns.ChatCounter = Chat

-- parseChannelList(flat) -> { [id] = name } from GetChannelList()'s flat returns.
-- STRIDE-AGNOSTIC on purpose (ground rule 2: feature-detect, do not assume). 3.3.5
-- is documented as returning id,name pairs and later clients add a third `disabled`
-- value; rather than betting on which one Ascension ships, walk the list and pair
-- every number that is followed by a string, skipping anything that does not pair.
-- Both shapes fall out correctly. PURE — self-tested.
local function parseChannelList(flat)
    local out, n = {}, 0
    local i = 1
    while i <= #flat do
        local id, name = tonumber(flat[i]), flat[i + 1]
        if id and type(name) == "string" then
            out[id] = name
            n = n + 1
            i = i + 2
        else
            i = i + 1
        end
    end
    if n == 0 then return nil end
    return out
end
ns.parseChannelList = parseChannelList

--------------------------------------------------------------------------------
-- WoW wiring -------------------------------------------------------------------
local Events = {}
local counter = Counter.new()
local blocked = Blocked.new()
local chat = Chat.new()
local windowStart = 0            -- GetTime() when the current count window opened
local recent                     -- RingBuffer of recent event names (context for spikes)

function Events.init()
    counter:reset()
    blocked:reset()
    chat:reset()
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

    -- Dedicated frame for the per-channel chat breakdown. Registered NARROWLY, not on
    -- the all-events firehose, for exactly the reason the blocked frame is: capturing
    -- args up there would pay the arg cost on every CLEU as well. Here it is paid only
    -- on the event being dissected. CHAT_MSG_CHANNEL args on 3.3.5:
    --   1 message  2 sender  3 language  4 channelString  5 target
    --   6 flags    7 zoneId  8 channelIndex  9 channelBaseName
    -- arg9 is preferred and arg4 is the fallback: the base name is absent on some
    -- server-generated lines, and a row labelled "?" names nothing.
    local cf = CreateFrame("Frame", "ClientPerfProbeChat")
    cf:RegisterEvent("CHAT_MSG_CHANNEL")
    cf:SetScript("OnEvent", function(_, _, message, sender, _, chanString,
                                     _, _, _, chanIndex, chanBase)
        chat:record(chanBase or chanString, chanIndex, sender,
                    (type(message) == "string") and #message or 0)
    end)
    Events.chatFrame = cf
end

-- Channels this client is currently JOINED to, { [id] = name }, or nil when the API
-- is absent. Read on demand (report build), never on the hot path.
local function joinedChannels()
    if type(GetChannelList) ~= "function" then return nil end
    local ok, flat = pcall(function() return { GetChannelList() } end)
    if not ok then return nil end
    return parseChannelList(flat)
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

-- ranked per-channel CHAT_MSG_CHANNEL traffic over the window since the last reset,
-- with joined-but-silent channels included at n=0.
function Events.chatRanked(limit)
    local now = (type(GetTime) == "function") and GetTime() or (windowStart + 1)
    return chat:ranked(now - windowStart, limit, joinedChannels())
end

function Events.chatTotal() return chat.total end

function Events.reset()
    counter:reset()
    blocked:reset()
    chat:reset()
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

    -- ChatCounter: the per-channel breakdown that answers "who is flooding the
    -- channel", the question the flat R rate row cannot.
    do
        local ch = ns.ChatCounter.new()
        for i = 1, 30 do ch:record("Trade - City", 2, "Spammer", 100) end
        for i = 1, 5 do ch:record("Trade - City", 2, "Someone", 40) end
        ch:record("General - Ironforge", 1, "Player", 10)
        eq(ch.total, 36, "chat counter totals every message")

        local r = ch:ranked(10)
        eq(r[1].name, "Trade - City", "busiest channel ranks first")
        eq(r[1].count, 35, "per-channel count")
        eq(string.format("%.1f", r[1].perSec), "3.5", "per-channel rate = count/elapsed")
        eq(r[1].top, "Spammer", "names the loudest sender in the channel")
        eq(r[1].topCount, 30, "and how many of the messages were theirs")
        eq(r[1].senders, 2, "counts distinct senders")
        -- bytes -> KB/s, the field that ties the event rate to inbound bandwidth
        -- 30*100 + 5*40 = 3200 bytes over 10s = 0.3125 KB/s
        eq(string.format("%.2f", r[1].kbPerSec), "0.31", "per-channel KB/s from message sizes")
        eq(r[2].name, "General - Ironforge", "quieter channel ranks second")

        -- a joined channel with NO traffic still shows: a data channel something
        -- joined silently is the thing being hunted and may be quiet right now.
        local withJoined = ch:ranked(10, nil, { [1] = "General - Ironforge",
                                                [2] = "Trade - City",
                                                [9] = "xtensionxtooltip2" })
        local quiet
        for _, row in ipairs(withJoined) do
            if row.id == 9 then quiet = row end
        end
        assert(quiet, "a joined channel with no traffic still gets a row")
        eq(quiet.count, 0, "silent joined channel reports zero traffic")
        eq(quiet.joined, true, "and is marked as joined")

        -- traffic from a channel NOT in the joined list is the suspicious case
        local unknown = ch:ranked(10, nil, { [1] = "General - Ironforge" })
        for _, row in ipairs(unknown) do
            if row.name == "Trade - City" then
                eq(row.joined, false, "traffic from an unjoined channel is flagged")
            end
        end

        -- the distinct-sender cap bounds memory and says when it bit
        local many = ns.ChatCounter.new()
        for i = 1, ns.ChatCounter.SENDER_CAP + 10 do many:record("World", 5, "P" .. i, 10) end
        eq(many.chans["World"].distinct, ns.ChatCounter.SENDER_CAP, "distinct senders are capped")
        eq(many:ranked(1)[1].capped, true, "and the cap is reported, not hidden")

        -- limit trims the ranked list
        eq(#ch:ranked(10, 1), 1, "ranked honours the limit")

        -- a message with no usable channel name is still counted, never dropped
        local anon = ns.ChatCounter.new()
        anon:record(nil, nil, "X", 5)
        eq(anon:ranked(1)[1].name, "?", "unnamed channel falls back to '?' rather than vanishing")
    end

    -- parseChannelList is STRIDE-AGNOSTIC: 3.3.5 is documented as id,name pairs and
    -- later clients add a third `disabled` value. Both must parse, because betting on
    -- one would silently produce an empty joined-channel list on the other.
    do
        local pairsForm = ns.parseChannelList({ 1, "General - Ironforge", 2, "Trade - City" })
        eq(pairsForm[1], "General - Ironforge", "pairs form: first channel")
        eq(pairsForm[2], "Trade - City", "pairs form: second channel")

        local triplesForm = ns.parseChannelList({ 1, "General - Ironforge", 0,
                                                  2, "Trade - City", 0 })
        eq(triplesForm[1], "General - Ironforge", "triples form: first channel")
        eq(triplesForm[2], "Trade - City", "triples form: second channel")

        eq(ns.parseChannelList({}), nil, "no channels -> nil, not an empty table")
    end

    print("Events: OK")
end

return ns.Events
