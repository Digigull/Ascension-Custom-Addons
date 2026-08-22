--[[ Core.lua — driver OnUpdate, spike detection, ring buffer, SavedVariables,
     and the /perfprobe slash command. Wires the pure modules to the live client.

     Detection is dead simple and dependency-free (README Appendix B.2): a driver
     frame's OnUpdate diffs debugprofilestop() to get true whole-frame time; when
     it exceeds the threshold we record a spike with its context. Attribution of
     WHO comes from the interval sampler (Attrib), not from scanning inside the
     spike — the OnUpdate stays lean because measurement perturbs (README §4).

     WoW-facing; syntax-checked only. All heavy/pure logic lives in the tested
     modules (RingBuffer, Report, Events counter).
]]

local ADDON, ns = ...

local Core = {}
local VERSION = "0.2.4"

-- defaults (persisted into ClientPerfProbeDB.settings)
local DEFAULTS = {
    thresholdMs = 50,     -- ~3 dropped frames at 60fps; tune from data
    capacity    = 200,    -- spike ring buffer size
    -- Attrib interval. This was 5s and that was WRONG: the scan walks the whole
    -- Lua heap (UpdateAddOnMemoryUsage), measured at ~31ms on a 110MB heap — so the
    -- probe put a stall a third of a frame-budget long on the frame loop every 5
    -- seconds and then recorded it as an unattributed spike. See runSampler() and
    -- management/addons/clientperfprobe/SAMPLER-COST.md.
    sampleSec   = 30,     -- 0 disables the interval scan entirely (/cpp sample)
}

local db                  -- ClientPerfProbeDB
local ring                -- RingBuffer of spike records
local driver              -- OnUpdate frame
local bootTime = 0        -- GetTime() at this session's load; spikes with t<boot
                          -- were restored from SavedVariables (a prior session)

-- per-frame carry state
local lastClock           -- debugprofilestop() at previous frame
local lastHeap            -- collectgarbage("count") at previous frame
local lastCleu = 0        -- Events.cleuCount() at previous frame
local lastStream = 0      -- Events.streamCount() at previous frame (for spike str=)
local sampleAccum = 0     -- seconds accumulated toward the next Attrib.sample()
local probeCost = { n = 0, over = 0, max = 0, last = 0 }
                          -- the SAMPLER'S OWN measured cost (the P report row).
                          -- The probe's one genuinely expensive per-frame-ish job;
                          -- it used to be invisible and mis-billed to the client.
local spikeSeq = 0        -- monotonic spike index
local lastEnterWorld      -- GetTime() at the most recent zone-in (PLAYER_ENTERING_WORLD
                          -- / LOADING_SCREEN_DISABLED). A spike within a few seconds of
                          -- this is a loading-screen first-render even when the zone
                          -- event was flooded out of the recent-event ring (README: the
                          -- zone-in event burst evicts the very marker classify keys on).
local lastGC              -- last /cpp gc measurement { collectMs, freedKB, beforeKB, afterKB }
local lastMem             -- last /cpp mem walk (MemWalk.estimate result); on-demand only
local loadProf            -- LoadProfile: per-addon initial-load cost + login timeline
local started            -- guard so start() runs once

--------------------------------------------------------------------------------
-- meta / helpers

local function safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

-- GetNetStats snapshot for a spike frame. This is the one channel that can tell a
-- big UNATTRIBUTED pure-CPU stall (sus=?, dh~0, cleu=0 — the ~300ms Ironforge
-- class the addon-toggle A/B test isolated) apart from an I/O / streaming / server
-- stall (README causes A/D): if inbound bandwidth or WORLD latency is elevated on
-- the spike frame, the stall smells like network/streaming, not engine CPU.
-- Called ONLY on the rare spike frame (never per-frame), so the hot path stays
-- lean (README §4). HONEST LIMIT (README App. A / §9): GetNetStats returns rolling
-- RATES, not per-frame byte counters, so this is a coarse instantaneous read, not
-- a frame-scoped delta — read it ACROSS captures (lag vs no-lag, spike vs ambient),
-- never as a single-frame verdict. Arity is verified live in the matrix row.
local function netSnapshot()
    if type(GetNetStats) ~= "function" then return nil end
    local res = { pcall(GetNetStats) }
    if not res[1] then return nil end
    local n = #res - 1                 -- number of values GetNetStats returned
    if n < 1 then return nil end
    -- 3.3.5 returns bandwidthIn, bandwidthOut, latency (3 vals). Cata+ splits
    -- latency into home/world (4 vals); the WORLD latency (last value) is the one
    -- a streaming/zone stall would move, so take the last value either way.
    return {
        inKB  = tonumber(res[2]) or 0,
        outKB = tonumber(res[3]) or 0,
        lat   = tonumber(res[n + 1]) or 0,
    }
end

-- Mouse-button state on a spike frame — the WINDOW-DRAG signal. A drag runs through
-- frame scripts (OnDragStart / OnUpdate), invisible to the event system, and in a busy
-- city the GLOBAL_MOUSE_DOWN that started it is flooded out of the recent-event ring
-- before the spike snapshot (the live cpp-window drag: dt=855ms, ev=UNIT_AURA,
-- CHAT_MSG_CHANNEL,COMBAT_LOG_EVENT_UNFILTERED, NO mouse event) — so ev= cannot catch
-- a mid-drag stall (exactly the trap the zone-in-by-timestamp fix solved for PEW).
-- Sampling the button state DIRECTLY on the spike frame does: a big unattributed
-- pure-CPU frame with the button HELD is the documented UI-drag first-layout class
-- (~600-800ms first-touch, warm across /reload, re-cold on restart; owner Lua drag
-- handlers measured ~0ms, so it's engine-side or a non-cooperating addon). Called
-- ONLY on the rare spike frame, so the hot path stays lean (README §4).
-- HONEST LIMIT / ground rule 2: IsMouseButtonDown is NOT in the API dumps —
-- feature-detect, don't assume. nil when absent, so the DRAG tag simply never fires
-- there and the spike stays "?" as today (the matrix row confirms availability live).
local function mouseSnapshot()
    if type(IsMouseButtonDown) ~= "function" then return nil end
    local ok, held = pcall(IsMouseButtonDown, "LeftButton")
    if not ok then return nil end
    return held and true or false
end

local function currentMeta()
    local build, iface = "?", "30300"
    if type(GetBuildInfo) == "function" then
        local ok, _ver, b, _date, toc = pcall(GetBuildInfo)
        if ok then
            if b then build = b end
            if toc then iface = toc end
        end
    end
    local zone = safe(GetRealZoneText) or safe(GetZoneText) or "?"
    local realm = safe(GetRealmName) or "?"
    local char = safe(UnitName, "player") or "?"
    local runLen = 0
    if ns.Events then
        local _, elapsed = ns.Events.snapshotRates()
        runLen = elapsed
    end
    return {
        version    = VERSION,
        build      = build,
        iface      = iface,
        realm      = realm,
        zone       = zone,
        char       = char,
        windowSec  = string.format("%.0f", runLen or 0),
        thresholdMs = db and db.settings.thresholdMs or DEFAULTS.thresholdMs,
        attr       = ns.Attrib and ns.Attrib.attrMode() or "none",
        totalSpikes = spikeSeq,
        shownSpikes = ring and math.min(ring:count(), ns.Report.MAX_SPIKES) or 0,
        generatedAt = safe(GetTime) or 0,
        boot        = bootTime,   -- spikes with t<boot were restored (prior session)
    }
end

-- Is anything actually READING the per-addon attribution right now? Only the
-- at-a-glance window renders it live; the copy/paste report is built on demand.
local function attribHasLiveConsumer()
    return (ns.UI and ns.UI.IsShown and ns.UI.IsShown()) and true or false
end

-- Run the per-addon attribution scan and CHARGE ITS COST TO OURSELVES.
--
-- Attrib.sample() calls UpdateAddOnMemoryUsage(), which walks the whole Lua heap to
-- attribute memory per addon. Measured live at ~31ms on a 110MB heap with 21 addons
-- (the P row's last=30.7 max=30.9). The old driver stamped lastClock BEFORE running
-- it, so the cost landed in the NEXT frame's dt and the probe recorded its own scan
-- as an unattributed spike — a whole live capture came back as a perfect 5-second
-- grid of sus=? frames at 50.3-56.3ms that were the measurement itself (~31ms of
-- walk on top of a ~20ms city frame: the arithmetic closes). Full write-up:
-- management/addons/clientperfprobe/SAMPLER-COST.md.
--
-- So: time the scan, re-baseline the frame clock and heap AFTER it so it cannot
-- masquerade as a client stall, and account for it in the P report row. The probe
-- still pays a visible price for this data — it just no longer bills the client.
local function runSampler(thr)
    if not (ns.Attrib and type(debugprofilestop) == "function") then return end
    thr = thr or (db and db.settings.thresholdMs) or DEFAULTS.thresholdMs

    local t0 = debugprofilestop()
    ns.Attrib.sample()
    local ms = debugprofilestop() - t0

    -- window the resulting offender deltas cover = time since the PREVIOUS scan
    local nowT = safe(GetTime) or 0
    probeCost.since = (probeCost.at and nowT > probeCost.at) and (nowT - probeCost.at) or nil
    probeCost.at    = nowT
    probeCost.last  = ms
    probeCost.n     = probeCost.n + 1
    if ms > (probeCost.max or 0) then probeCost.max = ms end
    if ms > thr then probeCost.over = probeCost.over + 1 end

    -- Re-baseline AFTER the scan. Without this the driver measures the measurer:
    -- the next frame's dt would carry our walk, and its dh our string churn.
    lastClock = debugprofilestop()
    lastHeap  = safe(collectgarbage, "count") or lastHeap
end

-- assemble a full Report.build() input from live state.
local function buildReportData(includeMatrix)
    local rates = ns.Events and ns.Events.snapshotRates() or {}
    local data = {
        meta      = currentMeta(),
        spikes    = ring and ring:recent(ns.Report.MAX_SPIKES) or {},  -- newest first
        offenders = ns.Attrib and ns.Attrib.lastRanked() or {},
        rates     = rates,
        gc        = lastGC,
        mem       = lastMem,
        -- the measurement's own cost (P row) — never hide what the probe spends
        probe     = {
            interval = (db and db.settings.sampleSec) or DEFAULTS.sampleSec,
            live     = attribHasLiveConsumer(),
            last     = probeCost.last,
            max      = probeCost.max,
            n        = probeCost.n,
            over     = probeCost.over,
            since    = probeCost.since,
        },
        blocked   = ns.Events and ns.Events.blockedRanked(ns.Report.MAX_BLOCKED) or nil,
        -- per-channel chat breakdown (C rows): names WHICH channel the chat firehose
        -- is in, which the flat R rate row cannot. Read on demand, never per-frame.
        chat      = ns.Events and ns.Events.chatRanked and
                    ns.Events.chatRanked(ns.Report.MAX_CHANNELS) or nil,
    }
    -- Are the O rows above a baseline rather than real deltas? The first scan of a
    -- session (or after /cpp clear) only establishes one, so it reports every addon
    -- at zero. That used to be invisible because the 5s interval took the baseline
    -- seconds after login; now the scan is on demand, so SAY SO rather than let a
    -- page of zeros read as "no addon moved memory".
    if ns.Attrib and ns.Attrib.hasBaseline then
        data.probe.baseline = not ns.Attrib.hasBaseline()
    end
    if loadProf and loadProf:hasData() then
        data.load = {
            summary = loadProf:summary(),
            ranked  = loadProf:ranked(ns.Report.MAX_LOADADDONS),
        }
    end
    if includeMatrix ~= false and ns.Probe then
        data.matrix = ns.Probe.buildMatrix()
    end
    return data
end

-- Measure the cost of one forced full GC against the live heap. Pure
-- measurement (README §5 lists collectgarbage as the way to force a
-- deterministic collection) — it intentionally stalls this one frame, which is
-- the point: it sizes the cause-B pause directly. Not a mitigation.
-- The first live /cpp gc showed collect=0ms freed=0 on a 274MB heap, hinting
-- collectgarbage("collect") is neutered like the rest of the profiling surface.
-- Test it DEFINITIVELY with a canary: allocate known garbage, drop it, force a
-- collect, and see whether it's reclaimed. If not, GC control (the cause-B
-- mitigation lever) is unavailable and we must say so.
local function measureGC()
    if type(collectgarbage) ~= "function" or type(debugprofilestop) ~= "function" then
        return nil
    end
    local before = collectgarbage("count")
    -- canary: ~10k throwaway tables so a working collector has something to free
    local canary = {}
    for i = 1, 10000 do canary[i] = { i, i } end
    local peak = collectgarbage("count")
    canary = nil
    local t0 = debugprofilestop()
    collectgarbage("collect")
    local collectMs = debugprofilestop() - t0
    local after = collectgarbage("count")
    local allocKB = peak - before
    local freedKB = peak - after
    lastGC = {
        collectMs = collectMs,
        allocKB   = allocKB,
        freedKB   = freedKB,
        -- a working collector reclaims most of the canary; a no-op frees ~nothing
        works     = (allocKB > 0) and (freedKB >= allocKB * 0.5) or false,
        beforeKB  = before,
        afterKB   = after,
    }
    return lastGC
end

-- Run the bounded _G memory walk (the on-contract `memtables`). HEAVY + on-demand
-- only — it visits every reachable table, so it's never on the hot path. Times the
-- scan with debugprofilestop when available so the owner sees the cost. Stashes the
-- result for the report's WM/W rows.
local function runMemWalk()
    if not (ns.MemWalk and type(_G) == "table") then return nil end
    local t0 = (type(debugprofilestop) == "function") and debugprofilestop() or nil
    -- The walk is bounded, but on a huge/fragmented 32-bit heap a table doubling can
    -- still fail ("block too big"). pcall it so an OOM degrades to a message instead
    -- of erroring out of the UI's click handler (seen live on _G here).
    local ok, res = pcall(ns.MemWalk.estimate, _G, { limit = ns.Report and ns.Report.MAX_MEM or 12 })
    if not ok then
        lastMem = { failed = true, err = tostring(res), ranked = {} }
        return lastMem
    end
    lastMem = res
    if t0 then lastMem.scanMs = debugprofilestop() - t0 end
    return lastMem
end

-- Stamp the latest full report into SavedVariables so the owner can /reload and
-- attach ClientPerfProbe.lua as an alternate relay to the copy/paste window.
-- Kept lean: a single overwritten capture (already size-bounded), never a
-- growing log — see CLAUDE.md ground rule 6.
local function persistReport(report)
    if db and report and report.text then
        db.lastReport = { gen = safe(GetTime) or 0, text = report.text }
    end
end

-- Freshen the per-addon attribution for an EXPLICIT report. The interval scan only
-- runs while the at-a-glance window is reading it (see onUpdate), so with that window
-- closed the offender rows would be stale — take one scan here instead. Deliberately
-- NOT inside buildReportData(): the at-a-glance window calls that from a 5s poll, and
-- putting a full-heap walk back on a 5s timer is the exact bug this release fixes.
local function refreshAttribution()
    if attribHasLiveConsumer() then return end   -- the interval scan already owns it
    runSampler()
end

local function openExport(includeMatrix)
    if not (ns.Report and ns.ExportWindow) then return end
    refreshAttribution()
    local report = ns.Report.build(buildReportData(includeMatrix))
    persistReport(report)
    ns.ExportWindow.Show(report)
end

--------------------------------------------------------------------------------
-- live inputs for the minimap storm notifier + the UI window. These are the
-- SAME live objects the report is built from — the UI formats, never re-gathers,
-- so it adds nothing to the driver's render hot path (README §4).

-- Recent-spike stats for the storm heuristic: fresh (this-session) spikes over
-- the last `windowSec` seconds, counting only those big enough to be felt. This
-- runs on the minimap's ~1s tick, so it only scans the newest STORM_SCAN spikes
-- (a real storm floods the window fast; older spikes can't be "recent"). The
-- allocation was itself feeding cause-B — the probe must not perturb (README §4).
local STORM_SCAN = 40
local function recentSpikeStats(windowSec, notableMs)
    if not ring then return 0, 0 end
    local now = safe(GetTime) or 0
    local cutoff = now - (windowSec or 8)
    local count, worst = 0, 0
    for _, sp in ipairs(ring:recent(STORM_SCAN)) do
        local t = sp.t or 0
        if t >= cutoff and t >= bootTime then           -- fresh + within the window
            if (sp.dt or 0) >= (notableMs or 100) then count = count + 1 end
            if (sp.dt or 0) > worst then worst = sp.dt end
        end
    end
    return count, worst
end

-- Instantaneous blocked-event rate (ADDON_ACTION_BLOCKED/_FORBIDDEN per second),
-- diffed across storm samples the way the driver diffs CLEU. Lean: one counter read.
local lastBlocked, lastBlockedT
local lastChat, lastChatT
local function stormInputs()
    local now = safe(GetTime) or 0
    local total = ns.Events and ns.Events.blockedTotal() or 0
    local ps = 0
    if lastBlockedT and now > lastBlockedT then
        ps = (total - (lastBlocked or 0)) / (now - lastBlockedT)
    end
    lastBlocked, lastBlockedT = total, now

    -- Live CHAT_MSG_CHANNEL rate, diffed exactly like the blocked counter: ONE counter
    -- read, no API calls. Deliberately not the per-channel breakdown — naming the
    -- channel needs GetChannelList + GetChatWindowChannels, which is report-path work,
    -- not something to put on a ~1s tick. The notifier says "there is a flood"; the
    -- C rows say which channel and whether you can even see it.
    local chatTotal = ns.Events and ns.Events.chatTotal and ns.Events.chatTotal() or 0
    local chatPS = 0
    if lastChatT and now > lastChatT then
        chatPS = (chatTotal - (lastChat or 0)) / (now - lastChatT)
    end
    lastChat, lastChatT = chatTotal, now

    local count, worst = recentSpikeStats(8, ns.Storm and ns.Storm.SPIKE_NOTABLE_MS or 100)
    return { blockedPS = ps, spikeCount = count, worstMs = worst, chatPS = chatPS }
end

-- wipe captured spikes + counters (shared by /cpp clear and the UI Clear button).
local function doClear()
    if ring then ring:clear(); if db then db.spikes = ring:serialize() end end
    if ns.Events then ns.Events.reset() end
    if ns.Attrib then ns.Attrib.reset() end
    spikeSeq = 0
    lastCleu = 0
    lastStream = 0
    probeCost = { n = 0, over = 0, max = 0, last = 0 }
    lastBlocked, lastBlockedT = nil, nil
    lastChat, lastChatT = nil, nil
end

-- time-scoped clear: drop only spikes captured within the last `minutes`, keeping
-- older ones AND the whole-run counters (event rates/CLEU/blocked are aggregates
-- with no per-item timestamp, so they can't be partially cleared — only the full
-- doClear() resets them). Use it to discard a recently contaminated stretch (an
-- AFK, a devconsole scan) without losing an earlier clean capture. GetTime is
-- monotonic since boot, so recent spikes carry the largest t; keep t < cutoff.
-- Returns how many spikes were removed.
local function clearSince(minutes)
    minutes = tonumber(minutes)
    if not (ring and minutes and minutes > 0) then return 0 end
    local now = safe(GetTime) or 0
    local cutoff = now - minutes * 60
    local removed = ring:keepIf(function(sp)
        return not (type(sp) == "table" and type(sp.t) == "number" and sp.t >= cutoff)
    end)
    if db then db.spikes = ring:serialize() end
    return removed
end

--------------------------------------------------------------------------------
-- spike recording

local function recordSpike(dt, heapDelta, cleuPS, net, streamN, mouseHeld)
    spikeSeq = spikeSeq + 1
    local rec = {
        index    = spikeSeq,
        t        = safe(GetTime) or 0,
        dt       = dt,
        inCombat = (type(InCombatLockdown) == "function") and InCombatLockdown() and true or false,
        cleuPS   = cleuPS,
        heapDelta = heapDelta,
        zone     = safe(GetRealZoneText) or safe(GetZoneText) or "?",
        events   = ns.Events and ns.Events.recentNames(6) or {},
        -- Seconds since the most recent zone-in. A loading screen suspends the
        -- frame loop then resumes into an event flood (WORLD_MAP_UPDATE, quest/map
        -- updates, city chat) that evicts PLAYER_ENTERING_WORLD from the recent-
        -- event ring before this snapshot — so classify() keys ZONE on this
        -- timestamp too, not only on the (buried) event name. nil until first zone-in.
        sinceZone = lastEnterWorld and ((safe(GetTime) or 0) - lastEnterWorld) or nil,
        -- New-player load count on the spike frame (UNIT_MODEL_CHANGED +
        -- UNIT_PORTRAIT_UPDATE + NAME_PLATE_UNIT_ADDED delta) — the cause-A
        -- streaming fingerprint that survives the UNIT_AURA firehose flooding ev=.
        -- Reported as the str= field; not (yet) a classifier input (measure-first).
        streamN  = streamN,
        -- GetNetStats snapshot at the spike ({inKB,outKB,lat}, nil if API absent):
        -- separates an I/O/streaming stall (cause A/D) from engine CPU on a big
        -- unattributed frame. Coarse (rolling rates) — see netSnapshot().
        net      = net,
        -- Mouse-button-held state on the spike frame (nil if IsMouseButtonDown is
        -- absent). true = the button was down as the frame froze — the window-drag
        -- fingerprint the event ring can't catch (see mouseSnapshot). Drives sus=DRAG
        -- when no measured cause owns the frame, and prints as the mouse=held field.
        mouseHeld = mouseHeld,
    }
    ring:push(rec)
    if db then db.spikes = ring:serialize() end
end

--------------------------------------------------------------------------------
-- driver OnUpdate (lean — see README §4)

local function onUpdate(_, elapsed)
    local clock = debugprofilestop
    if type(clock) ~= "function" then return end
    local now = clock()

    if not lastClock then
        lastClock = now
        lastHeap = safe(collectgarbage, "count")
        lastCleu = ns.Events and ns.Events.cleuCount() or 0
        lastStream = ns.Events and ns.Events.streamCount() or 0
        return
    end

    local dt = now - lastClock
    lastClock = now

    local thr = (db and db.settings.thresholdMs) or DEFAULTS.thresholdMs

    -- Interval attribution sampler. Two rules, both learned the hard way:
    --   1. Only run it while something is READING it (the at-a-glance window).
    --      With the window closed the report takes its own scan on demand, so an
    --      interval scan while you play is pure self-inflicted cost.
    --   2. Never let it land in the next frame's dt — runSampler() re-baselines
    --      the clock after the walk. Skipping that is what made the probe report
    --      its own 5-second scan as a stall for the whole of 0.2.0.
    -- sampleSec = 0 turns the interval scan off outright (/cpp sample 0).
    local interval = (db and db.settings.sampleSec) or DEFAULTS.sampleSec
    if interval > 0 then
        sampleAccum = sampleAccum + (elapsed or 0)
        if sampleAccum >= interval then
            sampleAccum = 0
            if attribHasLiveConsumer() then runSampler(thr) end
        end
    end

    if dt <= thr then
        -- still keep heap/cleu/stream baselines fresh for the next comparison
        lastHeap = safe(collectgarbage, "count") or lastHeap
        lastCleu = ns.Events and ns.Events.cleuCount() or lastCleu
        lastStream = ns.Events and ns.Events.streamCount() or lastStream
        return
    end

    -- SPIKE: compute deltas against the previous frame
    local heapNow = safe(collectgarbage, "count")
    local heapDelta = (heapNow and lastHeap) and (heapNow - lastHeap) or 0
    lastHeap = heapNow or lastHeap

    local cleuNow = ns.Events and ns.Events.cleuCount() or lastCleu
    local dCleu = cleuNow - lastCleu
    lastCleu = cleuNow
    local cleuPS = (dt > 0) and (dCleu / (dt / 1000)) or 0

    -- streaming-signal count on this frame (new-player model/portrait/nameplate
    -- loads): the raw per-frame delta, reported as str= (not scaled to a rate —
    -- it's "how many loaded this frame", the cause-A fingerprint).
    local streamNow = ns.Events and ns.Events.streamCount() or lastStream
    local streamN = streamNow - lastStream
    lastStream = streamNow

    -- net snapshot: only read on the spike frame (lean hot path); lets a big
    -- unattributed pure-CPU stall self-classify I/O (cause A/D) vs engine CPU.
    local net = netSnapshot()

    -- mouse-button-held sample: the window-drag signal the event ring can't catch
    -- (sampled here on the spike frame only, lean hot path).
    local mouseHeld = mouseSnapshot()

    recordSpike(dt, heapDelta, cleuPS, net, streamN, mouseHeld)
end

--------------------------------------------------------------------------------
-- slash command

local function msg(s) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCPP|r " .. s) end

local function printStat()
    local m = currentMeta()
    msg(("v%s build %s | zone %s | run %ss | thr %sms | attr %s"):format(
        m.version, tostring(m.build), m.zone, m.windowSec, tostring(m.thresholdMs),
        tostring(m.attr)))
    msg(("spikes captured: %d (showing up to %d) | CLEU total: %d"):format(
        spikeSeq, ns.Report.MAX_SPIKES, ns.Events and ns.Events.cleuCount() or 0))
end

local function usage()
    msg("commands:")
    msg("  |cffffff00/cpp|r or |cffffff00/perfprobe|r — open the copy/paste report window")
    msg("  |cffffff00/cpp ui|r — open the at-a-glance window (or left-click the minimap)")
    msg("  |cffffff00/cpp minimap|r — show/hide the minimap button")
    msg("  |cffffff00/cpp matrix|r — API support matrix only")
    msg("  |cffffff00/cpp load|r — initial-load timeline + per-addon load cost")
    msg("  |cffffff00/cpp stat|r — quick summary in chat")
    msg("  |cffffff00/cpp thr <ms>|r — set spike threshold (now " ..
        tostring(db and db.settings.thresholdMs) .. "ms)")
    msg("  |cffffff00/cpp sample <sec>|r — per-addon scan interval, 0 = off (now " ..
        tostring(db and db.settings.sampleSec) .. "s; costs what the |cffffff00P|r row says)")
    msg("  |cffffff00/cpp gc|r — force one full GC and measure the pause (sizes cause B)")
    msg("  |cffffff00/cpp mem|r — bounded _G walk: rank the top memory globals (on-contract memtables)")
    msg("  |cffffff00/cpp backdrop <Frame>|r — read a window's backdrop (compare a laggy one vs Details/WA)")
    msg("  |cffffff00/cpp save|r — stamp report into SavedVariables, then /reload + attach the file")
    msg("  |cffffff00/cpp clear|r — wipe captured spikes + counters (|cffffff00/cpp clear <min>|r trims recent spikes only)")
end

local function handler(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "" or cmd == "show" or cmd == "report" then
        openExport(true)
    elseif cmd == "matrix" then
        if ns.Report and ns.ExportWindow and ns.Probe then
            ns.ExportWindow.Show(ns.Report.build({
                meta = currentMeta(), matrix = ns.Probe.buildMatrix(),
            }))
        end
    elseif cmd == "stat" then
        printStat()
    elseif cmd == "load" then
        if not (loadProf and loadProf:hasData()) then
            msg("no load profile captured yet (needs a fresh login/reload to see the ADDON_LOADED cascade).")
            return
        end
        if ns.Report and ns.ExportWindow then
            ns.ExportWindow.Show(ns.Report.build({
                meta = currentMeta(),
                load = { summary = loadProf:summary(), ranked = loadProf:ranked(ns.Report.MAX_LOADADDONS) },
            }))
        end
    elseif cmd == "gc" then
        msg("testing collectgarbage with a canary (allocates + frees, stalls one frame)...")
        local g = measureGC()
        if not g then
            msg("|cffff4444can't measure|r — collectgarbage/debugprofilestop unavailable.")
        else
            msg(("collect: |cffffff00%.1f ms|r, canary alloc %d KB, reclaimed %d KB"):format(
                g.collectMs, math.floor(g.allocKB), math.floor(g.freedKB)))
            if g.works then
                msg("collectgarbage |cff44ff44works|r — GC tuning is a viable cause-B lever.")
            else
                msg("collectgarbage(\"collect\") |cffff4444reclaimed ~nothing|r — appears |cffff4444neutered|r on this client;")
                msg("GC is engine-managed only, so GC-tuning mitigation is likely off the table too.")
            end
            openExport(false)   -- surface it in the copyable window (G^ row)
        end
    elseif cmd == "mem" then
        msg("walking _G for per-global Lua memory (bounded; HEAVY — stalls a moment)...")
        local m = runMemWalk()
        if not m then
            msg("|cffff4444can't walk|r — MemWalk unavailable.")
        else
            local top = m.ranked and m.ranked[1]
            if top then
                msg(("top: |cffffff00%s|r ~%d KB (%d tables)%s"):format(
                    top.name, math.floor((top.bytes or 0) / 1024), top.nodes or 0,
                    m.capHit and " |cffff8800[node cap hit — total is a floor]|r" or ""))
            else
                msg("no attributable globals found.")
            end
            openExport(false)   -- surface the ranked WM/W rows in the copyable window
        end
    elseif cmd == "backdrop" then
        if not ns.BackdropTest then msg("backdrop inspector unavailable."); return end
        if rest == "" then
            msg("usage: |cffffff00/cpp backdrop <GlobalFrameName>|r — read a window's backdrop.")
            msg("compare a laggy window (e.g. |cffddddddClientPerfProbeExport|r) vs Details/WeakAuras windows.")
            msg("find a frame name with |cffffff00/framestack|r (open the window, hover it).")
            return
        end
        local res = ns.BackdropTest.describe(rest)
        for _, l in ipairs(res.lines) do msg(l) end
    elseif cmd == "sample" then
        local v = tonumber(rest)
        if v and v >= 0 then
            db.settings.sampleSec = v
            sampleAccum = 0
            if v == 0 then
                msg("per-addon attribution scan |cffff8800off|r — the report still scans once when you open it.")
            else
                msg(("attribution scan interval set to %gs (only runs while the at-a-glance window is open)."):format(v))
            end
        else
            msg("usage: /cpp sample <sec>  (0 = off; current " ..
                tostring(db.settings.sampleSec) .. "s)")
            msg("the scan walks the whole Lua heap — see the |cffffff00P|r row for what it costs you.")
        end
    elseif cmd == "thr" then
        local v = tonumber(rest)
        if v and v > 0 then
            db.settings.thresholdMs = v
            msg("spike threshold set to " .. v .. "ms")
        else
            msg("usage: /cpp thr <ms>  (current " .. tostring(db.settings.thresholdMs) .. ")")
        end
    elseif cmd == "save" then
        if ns.Report then
            refreshAttribution()
            persistReport(ns.Report.build(buildReportData(true)))
            msg("report saved to SavedVariables. Now |cffffff00/reload|r, then attach:")
            msg("  |cffddddddWTF/Account/<ACCOUNT>/SavedVariables/ClientPerfProbe.lua|r")
        end
    elseif cmd == "clear" or cmd == "reset" then
        local mins = tonumber(rest)
        if mins and mins > 0 then
            local n = clearSince(mins)
            msg(("cleared %d spike(s) from the last %g min (counters kept)."):format(n, mins))
        else
            doClear()
            msg("cleared captured spikes and counters.")
        end
    elseif cmd == "ui" or cmd == "window" then
        if ns.UI then ns.UI.Toggle() else msg("UI not available.") end
    elseif cmd == "minimap" then
        if ns.Minimap then ns.Minimap.toggle(); msg("toggled the minimap button.") else msg("minimap button not available.") end
    elseif cmd == "help" then
        usage()
    else
        msg("unknown command '" .. cmd .. "'")
        usage()
    end
end

--------------------------------------------------------------------------------
-- bootstrap

local function initDB()
    if type(ClientPerfProbeDB) ~= "table" then ClientPerfProbeDB = {} end
    db = ClientPerfProbeDB
    db.version = VERSION
    if type(db.settings) ~= "table" then db.settings = {} end
    for k, v in pairs(DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    -- Drop settings left behind by removed features (the frontload/pre-warm
    -- prototype; the scriptProfile arming that went with CPU attribution) so an
    -- existing SavedVariables file doesn't carry dead keys forever. Cheap and
    -- idempotent; delete this once no live DB can still hold them.
    db.settings.prewarmOnLogin = nil
    db.settings.prewarmTargets = nil
    db.settings.profileArming  = nil
    db.settings.profileLocked  = nil
    -- MIGRATION: sampleSec defaulted to 5, which put a full-heap UpdateAddOnMemoryUsage
    -- walk on the frame loop every 5 seconds and had the probe record the result as an
    -- unattributed ~50ms spike (management/addons/clientperfprobe/SAMPLER-COST.md).
    -- Move an existing DB off it. Unambiguous today because /cpp sample did not exist
    -- when that value was written, so nobody can have chosen 5 deliberately — delete
    -- this once no live DB predates the command.
    if db.settings.sampleSec == 5 then db.settings.sampleSec = DEFAULTS.sampleSec end
    -- Stamp this session's load time. The spike ring persists across /reload (ground
    -- rule 6: so /cpp save can flush it to disk), which means a capture taken without
    -- a /cpp clear mixes THIS session's spikes with restored ones from a prior play
    -- session. Any restored spike has a t (GetTime, monotonic since client start,
    -- survives reload) earlier than this load — mark those `old=1` so a capture is
    -- never misread. Seen live: 6 stale 613/814ms drag ghosts rode a post-reload /cpp.
    bootTime = safe(GetTime) or 0
    ring = ns.RingBuffer.restore(db.spikes)
    -- if the capacity setting changed, migrate onto a fresh buffer preserving order
    if ring.capacity ~= db.settings.capacity then
        local keep = ring:toArray()
        ring = ns.RingBuffer.new(db.settings.capacity)
        for _, r in ipairs(keep) do ring:push(r) end
        db.spikes = ring:serialize()
    end
    spikeSeq = ring:count()
end

-- Feed the LoadProfile one ADDON_LOADED mark: the delta from the previous mark
-- is the just-loaded addon's own cost, in ms (debugprofilestop) and KB
-- (collectgarbage heap) — a per-addon channel Ascension's runtime locks don't
-- block (see LoadProfile.lua). Lean: two cheap reads per addon, at load only.
local function markLoad(name)
    if not loadProf then return end
    loadProf:mark(name, safe(debugprofilestop) or 0, safe(collectgarbage, "count"))
end

local function markMilestone(name)
    if not loadProf then return end
    loadProf:milestone(name, safe(debugprofilestop) or 0)
end

local function start()
    if started then return end
    started = true
    initDB()
    if ns.LoadProfile then loadProf = ns.LoadProfile.new() end
    if ns.Events then ns.Events.init() end

    driver = CreateFrame("Frame", "ClientPerfProbeDriver")
    driver:SetScript("OnUpdate", onUpdate)

    -- the front-end: a minimap button + at-a-glance window over the SAME live data.
    -- Both format only (no re-gathering, throttled refresh) — nothing lands on the
    -- driver hot path. The copy/paste export stays the definition-of-done relay.
    if ns.UI then
        ns.UI.init(db, {
            -- matrix is only computed when the caller asks (it scans all addons);
            -- the throttled panel refresh skips it except on the System Info tab.
            snapshot   = function(withMatrix) return buildReportData(withMatrix == true) end,
            openReport = function() openExport(true) end,
            runMemWalk = runMemWalk,
            clear      = doClear,
            clearSince = clearSince,
            stormInputs = stormInputs,
        })
    end
    if ns.Minimap then
        ns.Minimap.init(db, {
            toggleUI    = function() if ns.UI then ns.UI.Toggle() end end,
            openReport  = function() openExport(true) end,
            stormInputs = stormInputs,
        })
    end

    SLASH_CLIENTPERFPROBE1 = "/perfprobe"
    SLASH_CLIENTPERFPROBE2 = "/cpp"
    SlashCmdList["CLIENTPERFPROBE"] = handler

    msg(("v%s loaded. Type |cffffff00/cpp|r to open the report, |cffffff00/cpp help|r for commands."):format(VERSION))
    local caps = ns.Probe and ns.Probe.caps() or {}
    if not caps.clock then
        msg("|cffff4444WARNING|r debugprofilestop() not found — spike timing is unavailable on this client.")
    end
end

-- Boot + initial-load profiler. The probe's own ADDON_LOADED starts it; then we
-- keep listening so every addon that loads AFTER us is marked (the load cascade
-- is serial, so consecutive marks attribute each addon's cost). The window closes
-- at PLAYER_ENTERING_WORLD — mid-session load-on-demand addons are a runtime
-- spike, not initial-load lag, and are excluded here on purpose.
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then start() end
        markLoad(name)          -- our own load is the first (floor) mark
    elseif event == "PLAYER_LOGIN" then
        markMilestone("PLAYER_LOGIN")
    elseif event == "PLAYER_ENTERING_WORLD" then
        markMilestone("PLAYER_ENTERING_WORLD")
        self:UnregisterEvent("ADDON_LOADED")   -- close the initial-load window
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)

-- Session-long zone-in tracker (separate from `boot`, which unregisters
-- PLAYER_ENTERING_WORLD after login to close the load window). Stamps the time of
-- every zone-in so a spike on the first post-loading-screen frame classifies as
-- ZONE even after the event flood buries the marker in the recent-event ring.
-- Lean: the handler only writes a timestamp — no work on this path.
local zoneWatch = CreateFrame("Frame")
zoneWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneWatch:RegisterEvent("LOADING_SCREEN_DISABLED")
zoneWatch:SetScript("OnEvent", function()
    lastEnterWorld = safe(GetTime) or lastEnterWorld
end)

ns.Core = Core
