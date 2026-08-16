--[[ Report.lua — spike classification, offender ranking, and the compact,
     paste-parseable report format (PURE LOGIC, self-tested offline).

     No WoW APIs. Loadable under bare Lua 5.1 for `make test`.

     WIRE FORMAT (schema "CPP1"): pipe-delimited, one record per line, so a
     pasted blob is parseable without guesswork. Documented in CLAUDE.md.
       Header : CPP1|ver=..|build=..|iface=..|realm=..|zone=..|char=..|
                win=..|thr=..|prof=..|spikes=..|shown=..|gen=..[|page=i/n]
       Matrix : M|api=<name>|st=<ok|missing|zero|off|n/a>|d=<detail>
       Load-T : T|pre=<ms>|login=<ms>|world=<ms>|addons=<n>|cap=<ms>|capkb=<KB>
       Load-A : L|r=..|addon=<name>|ms=<loadMs>|heap=<KB>
       Spike  : S|i=..|t=..|dt=..|cmb=..|cleu=..|dh=..|sus=<CODE>|zone=..|ev=..|cpu=..[|open=<frame>][|mouse=held][|net=in/out/lat][|str=n][|old=1]
       Offend : O|r=..|addon=..|cpu=..|mem=..|ev=..
       Blocked: B|r=..|addon=<name>|func=<protected fn>|n=<count>|ps=<perSec>
       MemSum : WM|kb=<estTotal>|tbls=<visited>|roots=<n>|cap=<0/1>|shown=<n>
       MemTop : W|r=..|name=<global>|kb=<estKB>|tbls=<tableCount>
       Rate   : R|ev=<name>|n=<count>|ps=<perSec>
       Footer : END|lines=<n>

     CLASSIFICATION is an explicit, rule-based HEURISTIC suspect tag, never a
     verdict. It only reports what the signals show; when signals are weak the
     tag is "?" (unattributed). Measure, don't guess — this labels evidence, it
     does not decide the fix.
]]

local ADDON, ns = ...
ns = ns or {}

local Report = {}

-- Tunables for the classifier. Conservative on purpose. Tuned against the first
-- live Tanaris/Stormwind capture (heap ~277MB, big +dh spikes, engine auto-GC).
Report.HEAP_FREED_KB   = 64    -- heap dropped >= this in the spike frame => a GC collection likely ran
Report.HEAP_ALLOC_KB   = 512   -- heap grew >= this (KB) in one frame => allocation-heavy (cause-B pressure)
Report.CLEU_HOT_PS     = 300   -- CLEU events/sec at/above this is a "firehose" signal
Report.ADDON_DOMINATES = 0.50  -- one addon >= this fraction of frame CPU => name it
Report.ZONE_WINDOW_SEC = 5     -- a spike within this many seconds of a zone-in is a
                               -- loading-screen first-render (ZONE) even when the zone
                               -- event was flooded out of the recent-event ring

-- Bounds so the report fits a 3.3.5 EditBox (see README §6a.3 / §9.7).
Report.MAX_SPIKES    = 20
Report.MAX_OFFENDERS = 15
Report.MAX_EVENTS    = 15
Report.MAX_PROFILED  = 20
Report.MAX_LOADADDONS = 20
Report.MAX_BLOCKED   = 10
Report.MAX_MEM       = 12    -- top-N memory globals in the /cpp mem walk
Report.PAGE_LINES    = 120     -- rows per page before pagination kicks in

--------------------------------------------------------------------------------
-- helpers

-- Field separator. NOT "|": in WoW, "|" is the escape lead-in (|c |r |T |t |H
-- |h |n |k), and the font renderer EATS those when the owner Ctrl+C's out of the
-- EditBox — the first live capture came back with "|realm" and "|thr" mangled to
-- "ealm"/"hr" (|r and |t consumed). "^" is a plain printable that WoW never
-- treats specially, so the copy/paste channel round-trips intact.
local SEP = "^"
Report.SEP = SEP

-- strip characters that would break the wire format (the separator itself, any
-- stray "|" that could still form a WoW escape on display, and newlines)
local function clean(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("[%^|\r\n]", " ")
    return s
end

local function f1(x)
    if type(x) ~= "number" then return "?" end
    return string.format("%.1f", x)
end

local function inum(x)
    if type(x) ~= "number" then return "?" end
    return string.format("%d", math.floor(x + 0.5))
end

--------------------------------------------------------------------------------
-- classify(spike) -> code, reasons[]
-- Inputs (all optional, defensive):
--   spike.dt        frame time ms
--   spike.inCombat  boolean
--   spike.cleuPS    COMBAT_LOG_EVENT_UNFILTERED events/sec at the spike
--   spike.heapDelta KB change in collectgarbage("count") across the spike frame
--   spike.events    array of recent event names (newest first)
--   spike.topCPU    array of { name=, ms= } for the sample window (desc)
-- Returns a short CODE and the list of human reasons that fired.
local ZONE_EVENTS = {
    PLAYER_ENTERING_WORLD = true,
    LOADING_SCREEN_ENABLED = true,
    LOADING_SCREEN_DISABLED = true,
    ZONE_CHANGED = true,
    ZONE_CHANGED_NEW_AREA = true,
    ZONE_CHANGED_INDOORS = true,
    NEW_WMO_CHUNK = true,
}

-- Interaction-frame FIRST-OPEN events -> a short tag naming which window opened.
-- The repeatedly-confirmed open-world/UI stutter class is cause-E first-exercise:
-- the FIRST render of an interaction frame this session spikes (~100-1000 ms) then
-- goes cheap. Across captures the unattributed spikes cluster on exactly these
-- events (LOOT_OPENED in Stratholme, MERCHANT_SHOW/GOSSIP_SHOW in Winterspring,
-- QUEST_DETAIL open-world). Naming the trigger is more useful to the owner than a
-- bare "?". This is a low-confidence, recent-event CORRELATION (not a measured
-- mechanism), so classify() only reaches for it when nothing stronger fired.
-- Deliberately CONSERVATIVE: WORLD_MAP_UPDATE and ZONE_INSTANCE_LIST are EXCLUDED
-- because they fire ambiguously (map-open AND other paths — see findings), so this
-- never over-claims a frame-open it can't stand behind.
local FRAMEOPEN_EVENTS = {
    LOOT_OPENED           = "loot",
    MERCHANT_SHOW         = "vendor",
    GOSSIP_SHOW           = "gossip",
    QUEST_DETAIL          = "quest",
    QUEST_GREETING        = "quest",
    QUEST_PROGRESS        = "quest",
    QUEST_COMPLETE        = "quest",
    BANKFRAME_OPENED      = "bank",
    GUILDBANKFRAME_OPENED = "guildbank",
    MAIL_SHOW             = "mail",
    TRAINER_SHOW          = "trainer",
    AUCTION_HOUSE_SHOW    = "auction",
    TAXIMAP_OPENED        = "flightmap",
    TRADE_SHOW            = "trade",
}

-- Friendly names for the at-a-glance window (the copy/paste report keeps the terse
-- code; the UI wants prose). Keyed by the short FRAMEOPEN tag.
local FRAMEOPEN_LABEL = {
    loot = "loot window", vendor = "vendor window", gossip = "NPC gossip",
    quest = "quest dialog", bank = "bank window", guildbank = "guild bank",
    mail = "mailbox", trainer = "trainer window", auction = "auction house",
    flightmap = "flight map", trade = "trade window",
}
Report.FRAMEOPEN_EVENTS = FRAMEOPEN_EVENTS
Report.FRAMEOPEN_LABEL = FRAMEOPEN_LABEL

-- frameOpenTag(spike) -> (short trigger tag, the event that named it) or nil.
-- Pulls the interaction-frame FIRST-OPEN event out of the recent-event window,
-- INDEPENDENT of classify()'s priority. classify() uses it only as the lowest-
-- priority OPEN: fallback, but the trigger is also useful as COMPLEMENTARY CONTEXT
-- on a spike a MEASURED cause already claimed — e.g. a Heavy-memory-churn (ALLOC)
-- frame that fired while first-opening the auction house (the live AH capture:
-- dh=+2057KB => ALLOC, ev carries AUCTION_HOUSE_SHOW). Reporting the trigger next
-- to the mechanism names WHAT the owner did without demoting the measured cause of
-- HOW it stalled. Still a recent-event CORRELATION, not a measured mechanism — same
-- honesty caveat as OPEN: (a non-cooperating addon hooking that event could own it).
function Report.frameOpenTag(spike)
    if type(spike) == "table" and type(spike.events) == "table" then
        for _, e in ipairs(spike.events) do
            local tag = FRAMEOPEN_EVENTS[e]
            if tag then return tag, e end
        end
    end
    return nil
end

-- Broader ACTIVITY vocabulary for the "probable trigger" guess (trig=). frameOpenTag
-- only names interaction-WINDOW opens; but the pervasive ALLOC spikes the owner sees
-- while just playing coincide with *activity* events — questing, looting into bags,
-- swapping gear, casting — none of which open a window. triggerGuess generalizes the
-- open= idea: name the most recent MEANINGFUL event next to the measured cause, so a
-- "Heavy memory churn" spike reads "churn · quest update" instead of a bare ALLOC.
-- Grounded in real captures (the Tanaris ALLOC spikes recurred on QUEST_LOG_UPDATE/
-- QUEST_POI_UPDATE). Curated tag -> friendly, mirroring FRAMEOPEN_EVENTS/_LABEL.
local ACTIVITY_EVENTS = {
    QUEST_LOG_UPDATE = "quest", QUEST_POI_UPDATE = "quest", QUEST_QUERY_COMPLETE = "quest",
    QUEST_ACCEPTED = "quest", QUEST_TURNED_IN = "quest", QUEST_WATCH_UPDATE = "quest",
    BAG_UPDATE = "bags", BAG_UPDATE_DELAYED = "bags", ITEM_PUSH = "bags",
    LOOT_SLOT_CLEARED = "bags", LOOT_CLOSED = "bags",
    UNIT_INVENTORY_CHANGED = "gear", PLAYER_EQUIPMENT_CHANGED = "gear",
    PLAYER_REGEN_DISABLED = "combatstart", PLAYER_REGEN_ENABLED = "combatend",
    PLAYER_TARGET_CHANGED = "target", UPDATE_MOUSEOVER_UNIT = "mouseover",
    UNIT_SPELLCAST_START = "cast", UNIT_SPELLCAST_SUCCEEDED = "cast",
    UNIT_SPELLCAST_CHANNEL_START = "cast", CURRENT_SPELL_CAST_CHANGED = "cast",
    NAME_PLATE_UNIT_ADDED = "nameplate",
    GROUP_ROSTER_UPDATE = "group", PARTY_MEMBERS_CHANGED = "group", RAID_ROSTER_UPDATE = "group",
    WORLD_MAP_UPDATE = "map", ADDON_LOADED = "addonload",
    PLAYER_MONEY = "money", SKILL_LINES_CHANGED = "skills",
}
local ACTIVITY_LABEL = {
    quest = "quest update", bags = "inventory change", gear = "gear change",
    combatstart = "entering combat", combatend = "leaving combat",
    target = "target changed", mouseover = "mouseover unit", cast = "spellcast",
    nameplate = "nameplate appeared", group = "group change", map = "map update",
    addonload = "addon load-on-demand", money = "money change", skills = "skill update",
}
Report.ACTIVITY_EVENTS = ACTIVITY_EVENTS
Report.ACTIVITY_LABEL = ACTIVITY_LABEL

-- Events that must NEVER be named as a trigger: firehoses (combat log, auras, chat),
-- ambient polls (the ~1.5/s COMMENTATOR poll findings flagged), high-frequency state
-- churn (cooldown/usable/power/health ticks), and the mouse-down/up drag markers (the
-- mouse=held field + DRAG code already own that story). Without this the guess would
-- just name the loudest ambient event — the exact trap the drag-capture hit (ev= came
-- back CHAT_MSG_CHANNEL, burying the real fingerprint). CHAT_MSG_* is matched by prefix.
local TRIGGER_NOISE = {
    UNIT_AURA = true, COMBAT_LOG_EVENT_UNFILTERED = true,
    COMMENTATOR_SKIRMISH_QUEUE_REQUEST = true,
    SPELL_UPDATE_COOLDOWN = true, SPELL_UPDATE_USABLE = true, SPELL_UPDATE_CHARGES = true,
    ACTIONBAR_UPDATE_COOLDOWN = true, ACTIONBAR_UPDATE_USABLE = true, ACTIONBAR_UPDATE_STATE = true,
    BAG_UPDATE_COOLDOWN = true,
    UNIT_POWER = true, UNIT_POWER_UPDATE = true, UNIT_POWER_FREQUENT = true, UNIT_MAXPOWER = true,
    UNIT_HEALTH = true, UNIT_HEALTH_FREQUENT = true, UNIT_MANA = true, UNIT_ENERGY = true,
    UNIT_RAGE = true, UNIT_FOCUS = true, UNIT_DISPLAYPOWER = true,
    GLOBAL_MOUSE_DOWN = true, GLOBAL_MOUSE_UP = true, UNIT_SPELLCAST_SENT = true,
    CURSOR_UPDATE = true,
}
local function triggerNoise(ev)
    if type(ev) ~= "string" then return true end
    if TRIGGER_NOISE[ev] then return true end
    if ev:sub(1, 9) == "CHAT_MSG_" then return true end
    return false
end
Report.triggerNoise = triggerNoise

-- triggerGuess(spike) -> tag, event, friendly, isRaw   (or nil when no guess).
-- The broader companion to frameOpenTag: walks the recent-event ring NEWEST-FIRST,
-- skips NOISE and zone events, and returns the first meaningful event as the probable
-- trigger. An interaction window resolves via FRAMEOPEN_LABEL; a curated activity via
-- ACTIVITY_LABEL; anything else is the RAW event name (isRaw=true) — the "at least take
-- its best guess" fallback. Like OPEN:, this is a recent-event CORRELATION, never a
-- measured mechanism: it does NOT feed classify(); it only adds context to sus=.
function Report.triggerGuess(spike)
    if type(spike) ~= "table" or type(spike.events) ~= "table" then return nil end
    for _, e in ipairs(spike.events) do
        if not triggerNoise(e) and not ZONE_EVENTS[e] then
            local fo = FRAMEOPEN_EVENTS[e]
            if fo then return fo, e, FRAMEOPEN_LABEL[fo] or fo, false end
            local ac = ACTIVITY_EVENTS[e]
            if ac then return ac, e, ACTIVITY_LABEL[ac] or ac, false end
            return e, e, e, true   -- raw fallback: an uncurated but meaningful event
        end
    end
    return nil
end

function Report.classify(spike)
    spike = spike or {}
    local reasons = {}
    local code = "?"

    -- E/A: a zone/loading transition in the recent event window -> first-exercise
    -- warm-up or first-see I/O (README §3 A/E). Checked first: a zone-in owns its
    -- frame outright, so it must win over the weaker heap/rate signals below.
    local zoneHit
    if type(spike.events) == "table" then
        for _, e in ipairs(spike.events) do
            if ZONE_EVENTS[e] then zoneHit = e; break end
        end
    end
    if zoneHit then
        code = "ZONE"
        reasons[#reasons + 1] = "zone/load event " .. zoneHit
    end

    -- B: heap dropped sharply in the spike frame -> a GC collection stalled it.
    if type(spike.heapDelta) == "number" and spike.heapDelta <= -Report.HEAP_FREED_KB then
        if code == "?" then code = "GC" end
        reasons[#reasons + 1] = string.format("heap freed %dKB (GC pause)", -math.floor(spike.heapDelta))
    end

    -- C: combat-log firehose. NOT gated on inCombat — the first live capture had
    -- a CLEU burst (cleuPS 3237) while cmb=0; combat only raises confidence.
    if type(spike.cleuPS) == "number" and spike.cleuPS >= Report.CLEU_HOT_PS then
        if code == "?" then code = "CLEU" end
        reasons[#reasons + 1] = string.format("CLEU %d/s%s", math.floor(spike.cleuPS),
            spike.inCombat and " in combat" or "")
    end

    -- B (pressure): the frame allocated heavily. Distinct from a GC *pause*
    -- (freeing) — this is the allocation that feeds it. The biggest live spikes
    -- (dh +1961/+1923/+931 KB) were this, previously all unattributed.
    if code == "?" and type(spike.heapDelta) == "number" and spike.heapDelta >= Report.HEAP_ALLOC_KB then
        code = "ALLOC"
        reasons[#reasons + 1] = string.format("heap grew %dKB in the frame (allocation pressure)",
            math.floor(spike.heapDelta))
    end

    -- C (attribution): one addon dominates the frame's measured CPU.
    if type(spike.topCPU) == "table" and spike.topCPU[1] and type(spike.dt) == "number" and spike.dt > 0 then
        local top = spike.topCPU[1]
        if type(top.ms) == "number" and top.ms >= Report.ADDON_DOMINATES * spike.dt then
            if code == "?" or code == "CLEU" then code = "ADDON:" .. clean(top.name) end
            reasons[#reasons + 1] = string.format("%s used %sms of %sms frame",
                clean(top.name), f1(top.ms), f1(spike.dt))
        end
    end

    -- E/A (zone-in backstop): a loading screen suspends the frame loop, then the
    -- first post-load frame resumes into an event flood (WORLD_MAP_UPDATE, quest/map
    -- updates, city chat) that evicts PLAYER_ENTERING_WORLD from the recent-event
    -- ring before the spike snapshot — so the top-of-function event check misses it
    -- and the frame comes back "?" (the live hearthstone/BG-pop captures). This
    -- backstop tags ZONE when the spike lands within ZONE_WINDOW_SEC of the last
    -- zone-in (a timestamp the driver stamps on PLAYER_ENTERING_WORLD /
    -- LOADING_SCREEN_DISABLED). LOW priority — only when no MEASURED signal fired —
    -- because a 5s window is a correlation, not a mechanism: a genuine CLEU/GC/ALLOC
    -- frame that happens seconds after zoning must keep its measured cause. Ranked
    -- ABOVE frame-open, though: "Zoning in" is the more specific, more actionable
    -- cause than a coincidental window-open during the same transition.
    if code == "?" and type(spike.sinceZone) == "number"
            and spike.sinceZone >= 0
            and spike.sinceZone <= Report.ZONE_WINDOW_SEC then
        code = "ZONE"
        reasons[#reasons + 1] = ("zone-in %.1fs ago"):format(spike.sinceZone)
    end

    -- E (UI drag): the pervasive WINDOW-DRAG stutter, the owner's long-standing "window
    -- drag lag". A drag runs through frame scripts (OnDragStart/OnUpdate), invisible to
    -- the event system, and in a busy city the GLOBAL_MOUSE_DOWN that started it is
    -- flooded out of the recent-event ring before the spike snapshot — so ev= misses it
    -- (the live cpp-window drag came back sus=? with ev=UNIT_AURA,CHAT,CLEU and no mouse
    -- event). Instead the driver SAMPLES the mouse-button state on the spike frame
    -- (spike.mouseHeld); a big unattributed pure-CPU stall with the button HELD is the
    -- documented UI-drag first-layout class (~600-2600ms first-touch). Cause now CONFIRMED
    -- (management/docs/DRAG-FREEZE.md): a hand-rolled window pairing SetToplevel(true) with a populated
    -- strata (e.g. HIGH) — the drag re-raises it and the engine restacks the whole strata.
    -- Pure engine CPU (owner Lua drag handlers measured ~0ms), so it's unnameable by the
    -- per-addon channels, but the trigger is the addon's frame setup. LOW priority (only
    -- when no measured cause fired) but ABOVE the frame-open OPEN: correlation: a held
    -- button is a stronger, real-time signal than a lingering window-open event, and a
    -- genuine first-open RELEASES the button before the window renders (so it stays "?"→
    -- OPEN, not DRAG). Still a heuristic — a held button could also be a camera turn — so
    -- suspectLabel/explain carry the caveat and it never feeds a mitigation on its own.
    if code == "?" and spike.mouseHeld == true then
        code = "DRAG"
        reasons[#reasons + 1] = "mouse button held during the frame (UI drag / window move)"
    end

    -- E (specific first-exercise): an interaction-frame FIRST-OPEN in the recent
    -- event window. LOWEST priority — only when nothing measured fired (code still
    -- "?") — because it is a recent-event correlation, not a measured mechanism.
    -- It turns the pervasive unattributed cause-E spike into a named probable cause
    -- (OPEN:vendor / OPEN:loot / ...) instead of a bare "?". Still heuristic: a
    -- non-cooperating addon hooking that same event could be the real owner.
    if code == "?" then
        local tag, ev = Report.frameOpenTag(spike)
        if tag then
            code = "OPEN:" .. tag
            reasons[#reasons + 1] = string.format("first open of the %s (%s) — first-exercise",
                FRAMEOPEN_LABEL[tag] or tag, ev)
        end
    end

    return code, reasons
end

--------------------------------------------------------------------------------
-- suspectLabel(code) -> a friendly human name for a suspect code (for the UI).
-- The wire keeps the terse code (sus=OPEN:vendor); the at-a-glance window shows
-- this. Pure string mapping, no state.
function Report.suspectLabel(code)
    code = code or "?"
    if code == "?"     then return "Unknown (likely the game engine)" end
    if code == "ZONE"  then return "Zoning in" end
    if code == "GC"    then return "Memory cleanup pause" end
    if code == "ALLOC" then return "Heavy memory churn" end
    if code == "CLEU"  then return "Combat data flood" end
    if code == "STREAM" then return "Loading players" end
    if code == "DRAG"  then return "Window drag (addon strata)" end
    local kind, rest = code:match("^(%u+):(.+)$")
    if kind == "ADDON" then return "Addon: " .. rest end
    if kind == "OPEN"  then return "First-open: " .. (FRAMEOPEN_LABEL[rest] or rest) end
    return code
end

--------------------------------------------------------------------------------
-- explain(spike) -> a friendly probable-cause SENTENCE for the at-a-glance window
-- (the copy/paste report uses the terse sus= code; the UI wants prose). Pure:
-- derives from classify(), adds honest first-exercise / attribution context and,
-- where the profiler is blind, the concrete next step to name it.
function Report.explain(spike)
    local code = Report.classify(spike)
    local kind, rest = code:match("^(%u+):(.+)$")
    if kind == "OPEN" then
        return string.format(
            "Probable: first open of the %s this session (first-exercise — one-time cost, cheap on later opens). "
            .. "No cooperating addon self-attributed this frame; a non-cooperating addon that hooks this event may own "
            .. "it — wrap it with ClientPerfProbe to confirm.", FRAMEOPEN_LABEL[rest] or rest)
    elseif kind == "ADDON" then
        return rest .. " owned this frame — measured directly via the cooperative Meter."
    elseif code == "GC" then
        return "The game paused to clean up unused memory (garbage collection). It can't be tuned from Lua here, and a bigger memory pile makes every cleanup longer."
    elseif code == "ALLOC" then
        return "A lot of memory was used up in this one frame — the churn that later triggers the cleanup pauses."
    elseif code == "CLEU" then
        return "Combat data flood — the combat log fired a huge burst of events this frame and processing them all is what froze it."
    elseif code == "ZONE" then
        return "Zoning in — the one-time setup cost of entering or loading a new area (happens once per zone-in)."
    elseif code == "DRAG" then
        return "You were holding the mouse button as this froze — the long-standing 'window drag lag'. "
            .. "On this client it now has a CONFIRMED cause: a hand-rolled addon window that calls SetToplevel(true) while sitting on a crowded frame strata (like HIGH). "
            .. "Grabbing the window re-raises it, and raising a toplevel frame into a busy strata makes the engine restack that whole strata — a ~0.6-2.6 s freeze the first time you drag each session (re-colds on a full restart). "
            .. "It is pure engine CPU, so no addon's Lua can be named for it — but the trigger is the addon's frame setup, and the fix lives in that addon: drop SetToplevel(true), or move the window to a near-empty strata like FULLSCREEN_DIALOG, and Raise() once on open. "
            .. "(A held button could also be a camera turn, but the window-drag freeze is by far the common case here.) See management/docs/DRAG-FREEZE.md for the measurement and the two-line fix."
    end
    return "Unknown — none of the probe's measurements owned this frame (no addon, no memory cleanup, no combat flood, no window-open). "
        .. "That usually means the cost is inside the game engine itself, which addons can't see or fix."
end

--------------------------------------------------------------------------------
-- GLOSSARY — plain-English guide to every metric + cause label the UI shows.
-- PURE DATA (no WoW APIs) so it's testable offline and shared by the at-a-glance
-- window's "Guide" popup. Each entry:
--   group : section header the UI lists entries under
--   term  : the friendly name shown on screen (kept in sync with suspectLabel)
--   plain : what it means, no jargon (the glossary list line)
--   tech  : how it's derived / measured (the "flip to technical" view on click)
--   code  : (optional) the sus= code this explains — a self-test asserts every
--           classifier label has a glossary entry so names never drift
--   field : (optional) the S-row field this explains
-- Text is deliberately free of "^" and "|" so it round-trips through any relay.
Report.GLOSSARY = {
    -- concept -----------------------------------------------------------------
    { group = "How to read this",
      term = "What a spike (stutter) actually is",
      plain = "A spike is a single frame where the game froze for a moment - what you feel as a stutter. The main thread was busy and could not draw. The probe catches every frame longer than the threshold (50 ms by default) and tries to name what kept it busy.",
      tech = "Each frame is timed with debugprofilestop(). A frame over the threshold is saved with its context (memory change, combat-log rate, recent events, cooperating-addon time, new-player loads) and run through classify() to pick a probable cause." },
    { group = "How to read this",
      term = "Why ping is never the cause",
      plain = "High ping or a laggy server does NOT freeze a frame - the game keeps drawing, it just shows slightly old information. The network only causes a spike indirectly, when data arrives and forces the game to do work right then: process a burst of combat log, or load players streaming into view. So we name those two things - never 'server lag'.",
      tech = "This is why there is no 'network' cause label and no I/O classifier built on GetNetStats: its numbers are rolling multi-second averages (latency refreshes only ~every 30 s), far too coarse to blame one frame. Network-triggered cost surfaces instead as Combat data flood or Loading players, both countable per frame." },

    -- cause labels ------------------------------------------------------------
    { group = "What caused a spike", code = "CLEU",
      term = "Combat data flood",
      plain = "A burst of combat made the game's combat log fire thousands of events (damage, heals, buffs) in one frame. Every addon watching combat had to process all of them at once, and that is what froze the frame. This is the classic big-battleground spike.",
      tech = "From COMBAT_LOG_EVENT_UNFILTERED (CLEU): events are counted and scaled to a per-second rate for the frame. At or above 300/s it is tagged a flood. Confirmed in a 40v40 BG at 544/s average with bursts near 1950/s." },
    { group = "What caused a spike", code = "GC",
      term = "Memory cleanup pause",
      plain = "The game paused to clean up memory it no longer needed (garbage collection). It is necessary housekeeping, but the bigger the memory pile, the longer it takes - and you feel it as a hitch. On this client the game does this on its own; addons cannot trigger or tune it.",
      tech = "From collectgarbage('count') sampled around the frame: a drop of 64 KB or more means a collection ran. Measured a 236 ms frame that freed ~14 MB mid-fight in a BG." },
    { group = "What caused a spike", code = "ALLOC",
      term = "Heavy memory churn",
      plain = "A lot of new memory got used up in this single frame. That costs time by itself, and it is also what fills the pile that later triggers a Memory cleanup pause. High churn is an early warning that pauses are coming.",
      tech = "From the collectgarbage('count') delta: a rise of 512 KB or more in one frame is tagged as churn (distinct from a cleanup pause, which is a drop)." },
    { group = "What caused a spike", code = "ZONE",
      term = "Zoning in",
      plain = "You were entering or loading a new area. The first frames after a loading screen do a lot of one-time setup, so a hitch there is expected and happens once per zone-in.",
      tech = "From recent event names: PLAYER_ENTERING_WORLD, the LOADING_SCREEN events, ZONE_CHANGED*, NEW_WMO_CHUNK. Highest-priority tag - a zone-in owns its frame, so it wins over the weaker heap/rate signals." },
    { group = "What caused a spike", code = "OPEN:vendor",
      term = "First-open (vendor / loot / ...)",
      plain = "The first time you open a particular window this session - a vendor, a loot window, NPC chat, the map - the game and your addons build it for the first time, which costs a moment. Open it again and it is cheap. A one-time warm-up cost.",
      tech = "Lowest-priority tag, used only when nothing measurable owned the frame. Matches a window-open event in the recent-event ring (LOOT_OPENED, MERCHANT_SHOW, GOSSIP_SHOW, quest/bank/mail/...). It names the TRIGGER, not the culprit - a non-cooperating addon hooking that event could be the real owner. Ambiguous events like the map update are deliberately excluded." },
    { group = "What caused a spike", code = "ADDON:example",
      term = "Addon: <name>",
      plain = "One specific addon's code ran long enough to own this frame - and because that addon cooperates with the probe, we can name it directly. This is the most trustworthy label: it is measured, not guessed.",
      tech = "Only cooperating addons (those calling ClientPerfProbe.Wrap/Enter/Leave) are timed, via debugprofilestop. If one tag used at least 50% of the frame it is named. Example: BiSScanner:OnTooltipSetItem owned a loot-window frame in Stratholme." },
    { group = "What caused a spike", code = "STREAM",
      term = "Loading players",
      plain = "A batch of new players (or their gear and mounts) just came into view and the game had to load their character models and textures right then. In a 40v40 this happens constantly as people stream into range, and each load can cause a brief hitch. This is the closest thing to a 'network-caused' spike - but it is the loading work that costs time, not the connection itself.",
      tech = "From a trailing count of UNIT_MODEL_CHANGED + UNIT_PORTRAIT_UPDATE + NAME_PLATE_UNIT_ADDED on the spike frame (the str= field / New-player loads). This is a correlation signal, not yet an automatic verdict - the count is reported, but the probe will not blame streaming until a capture proves the biggest spikes line up with it." },
    { group = "What caused a spike", code = "DRAG",
      term = "Window drag (addon strata)",
      plain = "You were holding the mouse button when the game froze - almost always dragging a movable addon window around (the long-standing 'window drag lag'). This one has a CONFIRMED cause on this client: a hand-rolled addon window that is set 'always on top' (SetToplevel) while sitting on a crowded UI layer. Grabbing it re-raises the window and the game has to re-sort that whole layer, which freezes the first drag of each session (~0.6 to 2.6 s); afterwards it is cheap. It is fixable - in the offending addon, not the game.",
      tech = "The driver samples IsMouseButtonDown('LeftButton') on the spike frame - a drag is a frame script the event system cannot see, and in a busy city the mouse-down event is flooded out of the recent-event ring before the snapshot. A big unattributed pure-CPU frame (cpu= empty, heap ~0) with the button held is the window-drag first-layout class. CONFIRMED cause (single-variable isolation, management/docs/DRAG-FREEZE.md): a frame that pairs SetToplevel(true) with a populated strata (e.g. HIGH). The click/drag raises the toplevel frame, which restacks the entire strata in one ~1 s engine pass; an EMPTY HIGH+toplevel frame still froze 1273 ms, so it is the raise/restack, not the backdrop or children. Fix lives in the addon: drop SetToplevel(true) (a singleton or non-overlapping window never needs click-to-raise) and/or move it to a near-empty strata like FULLSCREEN_DIALOG, then Raise() once on open. Verified in-game: all three of this addon-family's hand-rolled windows now log no sus=DRAG spike, cold or warm. A held button could also be a camera turn, but the window-drag freeze is by far the common case." },
    { group = "What caused a spike", code = "?",
      term = "Unknown (likely the game engine)",
      plain = "None of the probe's measurements owned this frame - no addon, no memory cleanup, no combat flood, no window-open. That usually means the cost is inside the game engine itself (its own rendering / first-layout work), which addons cannot see or fix. These are the honest 'we cannot name it' stalls.",
      tech = "The fallback when every signal is weak: no cooperating-addon time, memory change near zero, combat-log rate below the line, no zone or window-open event. This client gives Lua only aggregate signals, so a purely engine-side cost cannot be split further." },

    -- per-spike fields --------------------------------------------------------
    { group = "The numbers on each spike", field = "dt",
      term = "Freeze length",
      plain = "How long the game froze on that frame, in milliseconds. Anything you can feel is usually 100 ms or more; the big battleground monsters hit 1000-1800 ms.",
      tech = "Elapsed time across one OnUpdate frame, from debugprofilestop() - the one high-resolution timer that works on this client. Default spike threshold is 50 ms (change with /cpp thr)." },
    { group = "The numbers on each spike", field = "dh",
      term = "Memory change",
      plain = "How much the memory pile grew or shrank during that frame. A big plus means a lot was used up (churn); a big minus means the game cleaned up (a pause).",
      tech = "collectgarbage('count') delta across the frame, in KB. Feeds the Memory cleanup (negative) and Heavy churn (positive) labels." },
    { group = "The numbers on each spike", field = "cleu",
      term = "Combat data rate",
      plain = "How busy the combat log was at that instant, in events per second. Low out of combat (~1-3), moderate in a dungeon (~40), a firehose in a big battleground (500+).",
      tech = "Instantaneous COMBAT_LOG_EVENT_UNFILTERED count for the frame, scaled to per-second. 300/s is the flood line." },
    { group = "The numbers on each spike", field = "cmb",
      term = "In combat",
      plain = "Whether you were in combat when the spike happened. Helps tell a combat-driven hitch from a UI or loading one.",
      tech = "InCombatLockdown() at capture time; shown as yes/no (1/0 in the export)." },
    { group = "The numbers on each spike", field = "cpu",
      term = "Addon time",
      plain = "Time spent inside cooperating addons' code during that frame. Empty for most spikes, because most addons (and the game engine) do not report their time on this client.",
      tech = "Per-tag debugprofilestop totals for the spike frame only (folded in from the cooperative Meter). This is the only per-addon channel this client allows - the stock CPU API is locked." },
    { group = "The numbers on each spike", field = "net",
      term = "Network snapshot",
      plain = "A reading of your connection at the moment of the spike - download and upload speed, and ping. Useful as background context, but it cannot prove a spike was network-caused (see 'Why ping is never the cause').",
      tech = "GetNetStats() on the spike frame: inbound KB/s, outbound KB/s, world latency ms. These are rolling averages (latency refreshes ~every 30 s), too coarse to pin one frame - kept as ambient context, never a cause." },
    { group = "The numbers on each spike", field = "open",
      term = "Triggered by (window open)",
      plain = "The interaction window you opened on that frame - auction house, vendor, loot, bank, mailbox. Shown next to the cause when a spike happened while first-opening one of these this session. It names what you DID (opened the auction house), alongside the measured cause of HOW it stalled (heavy memory churn).",
      tech = "From the same interaction-frame first-open events as the First-open label (AUCTION_HOUSE_SHOW, MERCHANT_SHOW, LOOT_OPENED, GOSSIP_SHOW, bank/mail/trainer/...), but reported as complementary context even when a MEASURED cause already owns sus=. A recent-event correlation, not a mechanism - suppressed when it would duplicate a First-open tag or during a zone-in. If ADDON_LOADED also fired on the frame, an addon loaded on demand right then: a genuine first-load cost, paid once." },
    { group = "The numbers on each spike", field = "trig",
      term = "Probable trigger (guess)",
      plain = "A best guess at what you were doing when the spike hit - a quest update, an inventory change, a spellcast, opening a window. It names WHAT coincided with the stall, shown next to the measured cause of HOW it stalled (like Heavy memory churn), so two churn spikes from different activities no longer look the same. It is a guess, not a measurement: noisy background events (chat, auras, the combat log, cooldown ticks) are filtered out so it points at something meaningful.",
      tech = "From the recent-event ring, newest first: the first event that is not a known firehose or ambient poll. Known activities get a friendly name (quest update, inventory change, gear change, spellcast, ...); anything uncurated falls back to the raw event name. Suppressed when it would duplicate the window-open context (open=), the sus code, or a zone-in. A correlation, never a mechanism - it does not feed the cause classifier (Report.triggerGuess)." },
    { group = "The numbers on each spike", field = "mouse",
      term = "Mouse held",
      plain = "Shown when you were holding the mouse button as the frame froze - the fingerprint of dragging a window. It appears next to the cause even when something else is named, as context for what you were doing at the time.",
      tech = "IsMouseButtonDown('LeftButton') sampled on the spike frame. Feature-detected (not in the API dump); when absent the field is simply omitted. Drives the Window-drag label when no measured cause owns the frame, and is reported as complementary context (mouse=held) otherwise." },
    { group = "The numbers on each spike", field = "str",
      term = "New-player loads",
      plain = "How many new players or models were streaming into view on that frame. A high number next to a big unexplained freeze is a hint that model-loading (see 'Loading players') caused it.",
      tech = "Per-frame count of UNIT_MODEL_CHANGED + UNIT_PORTRAIT_UPDATE + NAME_PLATE_UNIT_ADDED. Added because in a BG the UNIT_AURA firehose floods the recent-event list and hides these - a dedicated counter surfaces the streaming fingerprint." },
}

-- glossary() -> the ordered entry list (UI reads this to build the Guide popup).
function Report.glossary() return Report.GLOSSARY end

--------------------------------------------------------------------------------
-- rankOffenders(samples, n) -> sorted top-n copy
-- samples: array of { name=, cpuMs=, memKb=, events= }. Sort by cpuMs desc,
-- tie-break memKb desc, then name asc for determinism.
function Report.rankOffenders(samples, n)
    local out = {}
    if type(samples) == "table" then
        for _, s in ipairs(samples) do out[#out + 1] = s end
    end
    table.sort(out, function(a, b)
        local ac, bc = a.cpuMs or 0, b.cpuMs or 0
        if ac ~= bc then return ac > bc end
        local am, bm = a.memKb or 0, b.memKb or 0
        if am ~= bm then return am > bm end
        return tostring(a.name) < tostring(b.name)
    end)
    if n and #out > n then
        for i = #out, n + 1, -1 do out[i] = nil end
    end
    return out
end

--------------------------------------------------------------------------------
-- format one header line (optionally with a page marker)
local function headerLine(meta, page, npages)
    meta = meta or {}
    local parts = {
        "CPP1",
        "ver=" .. clean(meta.version or "?"),
        "build=" .. clean(meta.build or "?"),
        "iface=" .. clean(meta.iface or "?"),
        "realm=" .. clean(meta.realm or "?"),
        "zone=" .. clean(meta.zone or "?"),
        "char=" .. clean(meta.char or "?"),
        "win=" .. clean(meta.windowSec or "?"),
        "thr=" .. clean(meta.thresholdMs or "?"),
        "prof=" .. (meta.profileOn and "1" or "0"),
        "attr=" .. clean(meta.attr or "none"),
        "spikes=" .. inum(meta.totalSpikes or 0),
        "shown=" .. inum(meta.shownSpikes or 0),
        "gen=" .. f1(meta.generatedAt or 0),
    }
    if page then parts[#parts + 1] = "page=" .. page .. "/" .. npages end
    return table.concat(parts, SEP)
end

--------------------------------------------------------------------------------
-- build(data) -> { pages = { str, ... }, text = str, lineCount = n }
-- data = {
--   meta      = header fields (see headerLine),
--   matrix    = array of { name=, status=, detail= },   -- API support matrix
--   spikes    = array of spike records (newest first),
--   offenders = array of { name=, cpuMs=, memKb=, events= },
--   blocked   = array of { addon=, func=, count=, perSec= } (misbehaving-addon namer),
--   mem       = MemWalk.estimate result { ranked={name,bytes,nodes}, totalBytes, totalNodes, capHit, roots },
--   rates     = array of { name=, count=, perSec= },
-- }
function Report.build(data)
    data = data or {}
    local meta = data.meta or {}
    local body = {}   -- all rows (no header/footer); paginated later

    -- MATRIX
    if type(data.matrix) == "table" and #data.matrix > 0 then
        for _, m in ipairs(data.matrix) do
            body[#body + 1] = table.concat({
                "M",
                "api=" .. clean(m.name),
                "st=" .. clean(m.status or "?"),
                "d=" .. clean(m.detail or ""),
            }, SEP)
        end
    end

    -- GC measurement (from /cpp gc): a canary-based test of whether Lua can
    -- collect at all on this client (Ascension stubs the profiling family, so
    -- collectgarbage may be neutered too). alloc=known garbage created,
    -- freed=reclaimed by the forced collect, works=1 if the collect reclaimed it.
    if type(data.gc) == "table" then
        local g = data.gc
        body[#body + 1] = table.concat({
            "G",
            "collect=" .. f1(g.collectMs),
            "alloc=" .. inum(g.allocKB),
            "freed=" .. inum(g.freedKB),
            "works=" .. (g.works and "1" or "0"),
            "before=" .. inum(g.beforeKB),
            "after=" .. inum(g.afterKB),
        }, SEP)
    end

    -- LOAD PROFILE (initial-load lag). The per-addon load cost is a real per-addon
    -- CPU+memory channel that Ascension's runtime locks (scriptProfile,
    -- GetAddOnMemoryUsage) do NOT block: it comes from debugprofilestop /
    -- collectgarbage deltas across the serial ADDON_LOADED cascade. `T` is the
    -- login timeline (the floor + milestone gaps), `L` the per-addon ranking.
    if type(data.load) == "table" then
        local s = data.load.summary
        if type(s) == "table" then
            -- login/world are ms from the probe's own load (t=0); absolute
            -- debugprofilestop is client uptime, not a load cost (see LoadProfile).
            local function optms(x) return (type(x) == "number") and f1(x) or "?" end
            body[#body + 1] = table.concat({
                "T",
                "login=" .. optms(s.loginMs),
                "world=" .. optms(s.worldMs),
                "addons=" .. inum(s.addons or 0),
                "cap=" .. f1(s.capMs or 0),
                "capkb=" .. inum(s.capHeapKB or 0),
            }, SEP)
        end
        if type(data.load.ranked) == "table" then
            local shown = 0
            for r, a in ipairs(data.load.ranked) do
                if shown >= Report.MAX_LOADADDONS then break end
                shown = shown + 1
                body[#body + 1] = table.concat({
                    "L",
                    "r=" .. r,
                    "addon=" .. clean(a.name),
                    "ms=" .. f1(a.dMs or 0),
                    "heap=" .. ((type(a.dHeapKB) == "number") and inum(a.dHeapKB) or "?"),
                }, SEP)
            end
        end
    end

    -- MEMORY WALK (from /cpp mem). The on-contract answer to per-addon memory:
    -- GetAddOnMemoryUsage is 0 here and devconsole `memtables` prints off-contract
    -- and OOMs on bare _G. MemWalk bounds the scan and ranks the top memory globals
    -- into the copy/paste window. `WM` is the summary (rough est total KB, tables
    -- visited, whether the node cap truncated it — a capped total is a FLOOR), `W`
    -- the per-global ranking. kb figures are ROUGH ESTIMATES (see MemWalk).
    if type(data.mem) == "table" then
        local m = data.mem
        local function kb(bytes) return (type(bytes) == "number") and (bytes / 1024) or 0 end
        body[#body + 1] = table.concat({
            "WM",
            "kb=" .. inum(kb(m.totalBytes)),
            "tbls=" .. inum(m.totalNodes or 0),
            "roots=" .. inum(m.roots or 0),
            "cap=" .. (m.capHit and "1" or "0"),
            "shown=" .. inum(m.ranked and #m.ranked or 0),
        }, SEP)
        if type(m.ranked) == "table" then
            local shown = 0
            for r, g in ipairs(m.ranked) do
                if shown >= Report.MAX_MEM then break end
                shown = shown + 1
                body[#body + 1] = table.concat({
                    "W",
                    "r=" .. r,
                    "name=" .. clean(g.name),
                    "kb=" .. inum(kb(g.bytes)),
                    "tbls=" .. inum(g.nodes or 0),
                }, SEP)
            end
        end
    end

    -- SPIKES (already newest-first; bound to MAX_SPIKES)
    if type(data.spikes) == "table" then
        local shown = 0
        for _, sp in ipairs(data.spikes) do
            if shown >= Report.MAX_SPIKES then break end
            shown = shown + 1
            local code = Report.classify(sp)
            local evStr = ""
            if type(sp.events) == "table" then
                local ev = {}
                for i = 1, math.min(4, #sp.events) do ev[i] = clean(sp.events[i]) end
                evStr = table.concat(ev, ",")
            end
            local cpuStr = ""
            if type(sp.topCPU) == "table" then
                local cp = {}
                for i = 1, math.min(3, #sp.topCPU) do
                    local t = sp.topCPU[i]
                    cp[i] = clean(t.name) .. ":" .. f1(t.ms)
                end
                cpuStr = table.concat(cp, ";")
            end
            local srow = {
                "S",
                "i=" .. inum(sp.index or shown),
                "t=" .. f1(sp.t),
                "dt=" .. f1(sp.dt),
                "cmb=" .. (sp.inCombat and "1" or "0"),
                "cleu=" .. inum(sp.cleuPS or 0),
                "dh=" .. inum(sp.heapDelta or 0),
                "sus=" .. code,
                "zone=" .. clean(sp.zone or ""),
                "ev=" .. evStr,
                "cpu=" .. cpuStr,
            }
            -- Frame-open TRIGGER context (open=<tag>). Complementary to sus=: names
            -- the interaction-frame first-open the spike coincided with, even when a
            -- MEASURED cause (ALLOC/GC/CLEU/ADDON) owns the classification — the live
            -- AH capture (opening the auction house, dh=+2057KB => sus=ALLOC) was the
            -- motivating case: the owner sees "Heavy memory churn" but wants to know it
            -- was the auction-house first-open. Emitted only when it ADDS information:
            -- suppressed when sus is already that same OPEN: tag (redundant) or a ZONE
            -- transition (zoning dominates the narrative; a coincidental window-open
            -- during a loading screen would mislead). Correlation, not mechanism.
            local openTag = Report.frameOpenTag(sp)
            if openTag and code ~= ("OPEN:" .. openTag) and code ~= "ZONE" then
                srow[#srow + 1] = "open=" .. openTag
            end
            -- Broader ACTIVITY trigger (trig=<tag>). Generalizes open= beyond window
            -- first-opens to the coincident activity (quest update, inventory change,
            -- spellcast, ...) so a measured-cause spike — chiefly the pervasive ALLOC
            -- churn the owner watches while playing — names WHAT coincided next to HOW
            -- it stalled, instead of a bare "Heavy memory churn". Suppressed when it
            -- would only duplicate open= (same window), the sus OPEN: code, or a zone-in.
            -- A recent-event correlation, not a mechanism (does not feed classify()).
            local trigTag = Report.triggerGuess(sp)
            if trigTag and trigTag ~= openTag
                    and code ~= ("OPEN:" .. trigTag) and code ~= "ZONE" then
                srow[#srow + 1] = "trig=" .. clean(trigTag)
            end
            -- Mouse-button-held context (mouse=held). Complementary to sus= like open=:
            -- prints whenever the button was down as the frame froze (the window-drag
            -- fingerprint the event ring can't catch), even when a measured cause owns
            -- the classification. sus=DRAG fires off this same signal only when nothing
            -- measured explained the frame. Present only when held (nil/false omitted,
            -- matching net='s/str='s "only when meaningful").
            if sp.mouseHeld == true then
                srow[#srow + 1] = "mouse=held"
            end
            -- GetNetStats snapshot at the spike (down KB/s / up KB/s / world latency
            -- ms). Present only when the driver could read GetNetStats. This is the
            -- channel that separates an I/O/streaming stall (cause A/D) from engine
            -- CPU on a big UNATTRIBUTED frame (cpu= empty, dh~0, cleu=0). It does NOT
            -- feed classify() yet: GetNetStats returns coarse rolling rates, and the
            -- "elevated" thresholds must be tuned from a real capture, not guessed
            -- (same discipline that added ALLOC only after seeing +1961KB live).
            if type(sp.net) == "table" then
                srow[#srow + 1] = "net=" .. f1(sp.net.inKB or 0) .. "/" ..
                    f1(sp.net.outKB or 0) .. "/" .. inum(sp.net.lat or 0)
            end
            -- New-player load count on the spike frame (str=). Present only when
            -- some streaming events fired (a positive count is the signal; 0 is the
            -- default and simply omitted, matching net='s "only when meaningful").
            -- Not a classifier input yet — reported for the owner to read across
            -- captures (does a monster spike carry a burst of loads?).
            if type(sp.streamN) == "number" and sp.streamN > 0 then
                srow[#srow + 1] = "str=" .. inum(sp.streamN)
            end
            -- Mark spikes restored from a prior session (t before this session's
            -- load) so a capture taken without /cpp clear can't be misread as fresh.
            local boot = tonumber(meta.boot) or 0
            if boot > 0 and type(sp.t) == "number" and sp.t > 0 and sp.t < boot then
                srow[#srow + 1] = "old=1"
            end
            body[#body + 1] = table.concat(srow, SEP)
        end
    end

    -- OFFENDERS
    if type(data.offenders) == "table" then
        local ranked = Report.rankOffenders(data.offenders, Report.MAX_OFFENDERS)
        for r, o in ipairs(ranked) do
            body[#body + 1] = table.concat({
                "O",
                "r=" .. r,
                "addon=" .. clean(o.name),
                "cpu=" .. f1(o.cpuMs),
                "mem=" .. f1(o.memKb),
                "ev=" .. inum(o.events or 0),
            }, SEP)
        end
    end

    -- PROFILED (cooperative Meter participants): real per-tag CPU via
    -- debugprofilestop, the one route that survives Ascension's lockdown. Caller
    -- passes Meter:ranked(). Empty on a client with no participating addons.
    if type(data.profiled) == "table" then
        local shown = 0
        for r, p in ipairs(data.profiled) do
            if shown >= Report.MAX_PROFILED then break end
            shown = shown + 1
            body[#body + 1] = table.concat({
                "P",
                "r=" .. r,
                "tag=" .. clean(p.tag),
                "ms=" .. f1(p.ms),
                "calls=" .. inum(p.calls or 0),
                "pms=" .. f1(p.perMs or 0),
            }, SEP)
        end
    end

    -- BLOCKED (the misbehaving-addon namer). Each ADDON_ACTION_BLOCKED/FORBIDDEN is
    -- SELF-DESCRIBING: the engine names the offending addon + the protected function
    -- it retried under combat lockdown. Ranked by count — a live capture named
    -- ExadTweaks (TargetFrameToT:Show) at 45/s this way with no hooks/scriptProfile.
    -- This is HONEST attribution (the event carries the name), not a heuristic
    -- suspect tag — so it names a NON-cooperating addon, unlike the P^ Meter rows.
    if type(data.blocked) == "table" then
        local shown = 0
        for r, b in ipairs(data.blocked) do
            if shown >= Report.MAX_BLOCKED then break end
            shown = shown + 1
            body[#body + 1] = table.concat({
                "B",
                "r=" .. r,
                "addon=" .. clean(b.addon),
                "func=" .. clean(b.func),
                "n=" .. inum(b.count or 0),
                "ps=" .. f1(b.perSec or 0),
            }, SEP)
        end
    end

    -- RATES (bound to MAX_EVENTS; assume caller passes desc by count)
    if type(data.rates) == "table" then
        local shown = 0
        for _, rt in ipairs(data.rates) do
            if shown >= Report.MAX_EVENTS then break end
            shown = shown + 1
            body[#body + 1] = table.concat({
                "R",
                "ev=" .. clean(rt.name),
                "n=" .. inum(rt.count or 0),
                "ps=" .. f1(rt.perSec or 0),
            }, SEP)
        end
    end

    -- paginate: each page is self-describing (own header + footer).
    local perPage = Report.PAGE_LINES
    local npages = math.max(1, math.ceil(#body / perPage))
    local pages = {}
    for p = 1, npages do
        local lines = {}
        lines[1] = headerLine(meta, npages > 1 and p or nil, npages)
        local from = (p - 1) * perPage + 1
        local to = math.min(#body, p * perPage)
        for i = from, to do lines[#lines + 1] = body[i] end
        lines[#lines + 1] = "END" .. SEP .. "lines=" .. (#lines)  -- lines counts header + rows
        pages[p] = table.concat(lines, "\n")
    end

    -- single-page reports paste as one blob; multi-page join for a full copy.
    local text = (npages == 1) and pages[1] or table.concat(pages, "\n\n")
    return { pages = pages, text = text, lineCount = #body + 2 }
end

ns.Report = Report

--============================================================================--
if _SELFTEST then
    local function has(hay, needle, msg)
        assert(hay:find(needle, 1, true), (msg or "find") .. ": missing '" .. needle .. "'")
    end
    local function eq(a, b, msg)
        assert(a == b, (msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end

    -- classify: zone transition
    local c = Report.classify({ events = { "SPELL_UPDATE_COOLDOWN", "PLAYER_ENTERING_WORLD" } })
    eq(c, "ZONE", "classify zone")

    -- classify: zone-in by TIMESTAMP even when the zone event was flooded out of the
    -- recent-event ring (the live hearthstone case: dt=1259, ev=WORLD_MAP_UPDATE,
    -- QUEST_LOG_UPDATE,UPDATE_SHAPESHIFT_FORMS,UNIT_MODEL_CHANGED, no PLAYER_ENTERING_WORLD)
    c = Report.classify({ dt = 1259, heapDelta = 260, cleuPS = 1, sinceZone = 1.5, streamN = 2,
        events = { "WORLD_MAP_UPDATE", "QUEST_LOG_UPDATE", "UPDATE_SHAPESHIFT_FORMS", "UNIT_MODEL_CHANGED" } })
    eq(c, "ZONE", "classify zone by timestamp when event flooded out of ring")

    -- classify: a STALE zone-in (spike long after the last zone change) does NOT
    -- get the ZONE tag — the timestamp window is bounded.
    c = Report.classify({ dt = 200, sinceZone = 42.0,
        events = { "WORLD_MAP_UPDATE" } })
    eq(c, "?", "old zone-in outside window stays unattributed")

    -- classify: a negative sinceZone (clock skew / pre-first-zone-in) is ignored.
    c = Report.classify({ dt = 200, sinceZone = -1.0, events = { "WORLD_MAP_UPDATE" } })
    eq(c, "?", "negative sinceZone ignored")

    -- classify: the zone-in TIMESTAMP backstop is LOW priority — a genuine measured
    -- signal (GC/CLEU/ALLOC) seconds after a zone-in keeps its measured cause, so a
    -- real firehose right after zoning into a dungeon is not masked as ZONE.
    c = Report.classify({ heapDelta = -2000, sinceZone = 1.0 })
    eq(c, "GC", "measured GC beats the low-priority zone-timestamp backstop")
    c = Report.classify({ inCombat = true, cleuPS = 500, sinceZone = 1.0 })
    eq(c, "CLEU", "measured CLEU beats the low-priority zone-timestamp backstop")

    -- classify: the timestamp backstop DOES beat a frame-open correlation — "Zoning
    -- in" is more specific than a coincidental window-open during the same transition.
    c = Report.classify({ dt = 300, sinceZone = 1.0, events = { "MERCHANT_SHOW" } })
    eq(c, "ZONE", "zone-timestamp backstop beats frame-open (OPEN:)")

    -- classify: GC pause (heap freed)
    c = Report.classify({ heapDelta = -200 })
    eq(c, "GC", "classify gc")

    -- classify: CLEU firehose in combat
    c = Report.classify({ inCombat = true, cleuPS = 500 })
    eq(c, "CLEU", "classify cleu")

    -- classify: CLEU burst even out of combat (the i=51 live case, cmb=0)
    c = Report.classify({ inCombat = false, cleuPS = 3237 })
    eq(c, "CLEU", "classify cleu burst regardless of combat")

    -- classify: allocation-heavy frame (the big +dh live spikes)
    c = Report.classify({ heapDelta = 1961 })
    eq(c, "ALLOC", "classify allocation pressure")

    -- classify: GC (freeing) takes precedence over ALLOC (they can't both hold)
    c = Report.classify({ heapDelta = -11717 })
    eq(c, "GC", "classify gc beats alloc")

    -- classify: a dominant addon names itself, overriding a bare CLEU tag
    c = Report.classify({ inCombat = true, cleuPS = 500, dt = 60, topCPU = { { name = "BigAddon", ms = 40 } } })
    eq(c, "ADDON:BigAddon", "classify dominant addon")

    -- classify: weak/absent signals -> unattributed (small +dh below ALLOC thr)
    c = Report.classify({ dt = 55, cleuPS = 10, heapDelta = 263 })
    eq(c, "?", "classify weak -> ?")

    -- classify: below thresholds stays "?"
    c = Report.classify({ heapDelta = -10, inCombat = true, cleuPS = 100 })
    eq(c, "?", "classify below thresholds")

    -- classify: interaction-frame first-open names the trigger (the Winterspring
    -- MERCHANT_SHOW / GOSSIP_SHOW and Stratholme LOOT_OPENED spike class).
    c = Report.classify({ dt = 177, heapDelta = 104, cleuPS = 0,
        events = { "MERCHANT_SHOW", "CHAT_MSG_SYSTEM", "CURSOR_UPDATE", "ITEM_LOCKED" } })
    eq(c, "OPEN:vendor", "classify frame-open (vendor)")
    c = Report.classify({ dt = 106, heapDelta = 5,
        events = { "CHAT_MSG_CHANNEL", "GOSSIP_SHOW", "UNIT_COMBO_POINTS" } })
    eq(c, "OPEN:gossip", "classify frame-open (gossip)")
    c = Report.classify({ dt = 996, heapDelta = 11, cleuPS = 0,
        events = { "UNIT_AURA", "SPELL_UPDATE_USABLE", "LOOT_OPENED", "CURRENT_SPELL_CAST_CHANGED" } })
    eq(c, "OPEN:loot", "classify frame-open (loot)")

    -- classify: frame-open is LOWEST priority — a measured signal wins over it.
    c = Report.classify({ heapDelta = 2000, events = { "MERCHANT_SHOW" } })
    eq(c, "ALLOC", "measured ALLOC beats frame-open correlation")
    c = Report.classify({ events = { "MERCHANT_SHOW", "PLAYER_ENTERING_WORLD" } })
    eq(c, "ZONE", "zone transition beats frame-open")

    -- classify: ambiguous events are deliberately NOT frame-open (stay "?"). The
    -- Winterspring i=1 ZONE_INSTANCE_LIST spike must not be over-claimed as an open.
    c = Report.classify({ dt = 207, heapDelta = 10,
        events = { "UNIT_AURA", "ZONE_INSTANCE_LIST", "CHAT_MSG_SYSTEM", "MIRROR_TIMER_STOP" } })
    eq(c, "?", "ambiguous ZONE_INSTANCE_LIST stays unattributed")
    c = Report.classify({ dt = 149, events = { "WORLD_MAP_UPDATE" } })
    eq(c, "?", "ambiguous WORLD_MAP_UPDATE stays unattributed")

    -- classify: WINDOW-DRAG. A big unattributed pure-CPU frame with the mouse button
    -- held is the documented window-drag stutter (the live cpp-window drag: dt=855,
    -- dh~0, cleu below the line, cpu= empty, no mouse event in ev= because the city
    -- firehose flooded GLOBAL_MOUSE_DOWN out of the ring). The driver's spike-frame
    -- button sample (spike.mouseHeld) catches what ev= can't.
    c = Report.classify({ dt = 855, heapDelta = 77, cleuPS = 28, mouseHeld = true,
        events = { "UNIT_AURA", "CHAT_MSG_CHANNEL", "COMBAT_LOG_EVENT_UNFILTERED" } })
    eq(c, "DRAG", "classify window-drag from the spike-frame mouse-held sample")

    -- classify: DRAG is a LOW-priority backstop — a measured cause still wins (a held
    -- button during a GC/ALLOC/CLEU frame keeps the measured mechanism).
    c = Report.classify({ dt = 300, heapDelta = -2000, mouseHeld = true })
    eq(c, "GC", "measured GC beats the held-button DRAG backstop")
    c = Report.classify({ dt = 300, heapDelta = 2000, mouseHeld = true })
    eq(c, "ALLOC", "measured ALLOC beats the held-button DRAG backstop")

    -- classify: DRAG (held button) OUTRANKS the frame-open OPEN: correlation — a held
    -- button is a stronger real-time signal than a lingering window-open event.
    c = Report.classify({ dt = 300, mouseHeld = true, events = { "MERCHANT_SHOW" } })
    eq(c, "DRAG", "held-button DRAG beats a coincidental frame-open event")

    -- classify: a genuine first-open RELEASES the button before the window renders, so
    -- mouseHeld is absent/false there and it stays OPEN:, never mislabeled DRAG.
    c = Report.classify({ dt = 177, mouseHeld = false, events = { "MERCHANT_SHOW" } })
    eq(c, "OPEN:vendor", "released button leaves a first-open as OPEN:, not DRAG")

    -- classify: ZONE (a loading-screen first-render) still wins over a held button.
    c = Report.classify({ dt = 900, sinceZone = 1.0, mouseHeld = true, events = { "WORLD_MAP_UPDATE" } })
    eq(c, "ZONE", "zone-in beats the held-button DRAG backstop")

    -- classify: no mouse signal (API absent -> mouseHeld nil) leaves it unattributed.
    c = Report.classify({ dt = 855, heapDelta = 77, cleuPS = 28,
        events = { "UNIT_AURA", "CHAT_MSG_CHANNEL" } })
    eq(c, "?", "no mouse sample -> stays ? (DRAG never fires without the signal)")

    -- build: a window-drag spike carries sus=DRAG and the complementary mouse=held field
    -- (the live cpp-window capture reproduced end-to-end).
    local dragout = Report.build({ meta = { version = "1" },
        spikes = { { index = 1, t = 10.0, dt = 855.2, heapDelta = 77, cleuPS = 28, zone = "Stormwind City",
                     mouseHeld = true, net = { inKB = 18.3, outKB = 0.1, lat = 125 },
                     events = { "UNIT_AURA", "CHAT_MSG_CHANNEL", "COMBAT_LOG_EVENT_UNFILTERED" } } } })
    has(dragout.text, "sus=DRAG", "window-drag spike classifies DRAG in the wire report")
    has(dragout.text, "^mouse=held", "window-drag spike carries the mouse=held signal")
    assert(not dragout.text:find("|", 1, true), "mouse= field carries no '|' (copy-safety)")

    -- build: mouse=held is complementary context — it prints even when a MEASURED cause
    -- owns sus= (a held button during an ALLOC frame), like open=.
    local dragalloc = Report.build({ meta = { version = "1" },
        spikes = { { index = 2, t = 10.0, dt = 140.0, heapDelta = 2057, zone = "x",
                     mouseHeld = true, events = { "GLOBAL_MOUSE_DOWN" } } } })
    has(dragalloc.text, "sus=ALLOC", "measured ALLOC keeps sus= even with the button held")
    has(dragalloc.text, "^mouse=held", "mouse=held prints as complementary context under a measured cause")

    -- build: a frame with the button UP omits mouse= (no fake signal), like net=/str=.
    local nodrag = Report.build({ meta = { version = "1" },
        spikes = { { index = 3, t = 10.0, dt = 90.0, zone = "x", mouseHeld = false, events = {} } } })
    assert(not nodrag.text:find("mouse=", 1, true), "button-up frame omits mouse=")

    -- suspectLabel: friendly names for the UI (the owner-approved plain-English set)
    eq(Report.suspectLabel("?"), "Unknown (likely the game engine)", "label ?")
    eq(Report.suspectLabel("OPEN:vendor"), "First-open: vendor window", "label OPEN:vendor")
    eq(Report.suspectLabel("ADDON:BiSScanner:OnTooltipSetItem"),
       "Addon: BiSScanner:OnTooltipSetItem", "label ADDON")
    eq(Report.suspectLabel("GC"), "Memory cleanup pause", "label GC")
    eq(Report.suspectLabel("CLEU"), "Combat data flood", "label CLEU")
    eq(Report.suspectLabel("ALLOC"), "Heavy memory churn", "label ALLOC")
    eq(Report.suspectLabel("ZONE"), "Zoning in", "label ZONE")
    eq(Report.suspectLabel("STREAM"), "Loading players", "label STREAM")
    eq(Report.suspectLabel("DRAG"), "Window drag (addon strata)", "label DRAG")

    -- explain: prose probable-cause for the at-a-glance window
    local ex = Report.explain({ events = { "MERCHANT_SHOW" } })
    has(ex, "first open of the vendor window", "explain frame-open names the window")
    has(ex, "wrap it with ClientPerfProbe", "explain frame-open gives the next step")
    ex = Report.explain({ dt = 60, topCPU = { { name = "BiSScanner:X", ms = 40 } } })
    has(ex, "owned this frame", "explain addon attribution")
    ex = Report.explain({ heapDelta = 10, events = { "UNIT_AURA" } })
    has(ex, "Unknown", "explain unknown fallback")
    ex = Report.explain({ dt = 855, mouseHeld = true, events = { "UNIT_AURA" } })
    has(ex, "window drag lag", "explain DRAG names the long-standing window-drag lag")

    -- GLOSSARY: every classifier label the UI can show MUST have a plain+tech entry,
    -- so the friendly names never drift from what classify()/suspectLabel produce.
    do
        local byCode = {}
        for _, g in ipairs(Report.GLOSSARY) do
            assert(type(g.term) == "string" and #g.term > 0, "glossary entry needs a term")
            assert(type(g.plain) == "string" and #g.plain > 0, "glossary '" .. g.term .. "' needs plain text")
            assert(type(g.tech) == "string" and #g.tech > 0, "glossary '" .. g.term .. "' needs tech text")
            assert(not (g.plain .. g.tech):find("[%^|]"), "glossary '" .. g.term .. "' must be ^/| free (relay-safe)")
            if g.code then byCode[g.code] = true end
        end
        -- the codes classify() can emit (bare + prefixed families) are all covered
        for _, code in ipairs({ "?", "CLEU", "GC", "ALLOC", "ZONE", "STREAM", "DRAG" }) do
            assert(byCode[code], "glossary missing an entry for classifier code " .. code)
        end
        assert(byCode["OPEN:vendor"], "glossary missing the OPEN: family entry")
        assert(byCode["ADDON:example"], "glossary missing the ADDON: family entry")
    end

    -- build: a frame-open spike lands OPEN:<tag> in the wire sus= field
    local foout = Report.build({ meta = { version = "1" },
        spikes = { { index = 3, t = 10.0, dt = 177.0, heapDelta = 104, zone = "Winterspring",
                     events = { "MERCHANT_SHOW", "CHAT_MSG_SYSTEM" } } } })
    has(foout.text, "sus=OPEN:vendor", "build spike row carries the frame-open suspect code")
    assert(not foout.text:find("|", 1, true), "frame-open sus code carries no '|' (copy-safety)")

    -- frameOpenTag: pulls the interaction-frame trigger out of the recent events,
    -- independent of classify()'s priority (so a measured-cause spike can still name it).
    eq(Report.frameOpenTag({ events = { "AUCTION_HOUSE_SHOW", "WORLD_MAP_UPDATE" } }), "auction", "frameOpenTag auction")
    eq(Report.frameOpenTag({ events = { "CHAT_MSG_CHANNEL", "GLOBAL_MOUSE_DOWN" } }), nil, "frameOpenTag none")
    eq(Report.frameOpenTag({}), nil, "frameOpenTag defensive (no events)")

    -- classify is UNCHANGED by the refactor: a measured cause still wins over the
    -- frame-open trigger (the live AH capture: dh=+2057KB while opening the AH => ALLOC).
    local ahspike = { index = 1, t = 10.0, dt = 140.1, heapDelta = 2057, cleuPS = 0,
        zone = "Stormwind City",
        events = { "AUCTION_HOUSE_SHOW", "WORLD_MAP_UPDATE", "ADDON_LOADED", "UNIT_COMBO_POINTS" } }
    eq(Report.classify(ahspike), "ALLOC", "AH-open ALLOC frame keeps its measured cause")

    -- build: the measured-cause spike carries the trigger as complementary open= context,
    -- so the owner sees BOTH "Heavy memory churn" (sus=ALLOC) and the auction-house trigger.
    local ahout = Report.build({ meta = { version = "1" }, spikes = { ahspike } })
    has(ahout.text, "sus=ALLOC", "AH spike wire keeps the measured ALLOC cause")
    has(ahout.text, "^open=auction", "AH spike carries the frame-open trigger as complementary context")
    assert(not ahout.text:find("|", 1, true), "open= field carries no '|' (copy-safety)")

    -- build: open= is NOT emitted when it would only duplicate the sus code (a PURE
    -- first-open with no measured cause already classifies OPEN:auction).
    local pureopen = Report.build({ meta = { version = "1" },
        spikes = { { index = 2, t = 10.0, dt = 177.0, heapDelta = 5, zone = "x",
                     events = { "AUCTION_HOUSE_SHOW" } } } })
    has(pureopen.text, "sus=OPEN:auction", "pure first-open still classifies OPEN:auction")
    assert(not pureopen.text:find("open=auction", 1, true), "open= not duplicated when sus is already OPEN:auction")

    -- build: open= is suppressed on a zone-in — the transition narrative dominates, and
    -- a window-open coinciding with a loading screen would mislead.
    local zoneopen = Report.build({ meta = { version = "1" },
        spikes = { { index = 3, t = 10.0, dt = 300.0, sinceZone = 1.0, zone = "x",
                     events = { "AUCTION_HOUSE_SHOW" } } } })
    has(zoneopen.text, "sus=ZONE", "zone-in dominates over the frame-open trigger")
    assert(not zoneopen.text:find("open=", 1, true), "open= suppressed on a zone-in spike")

    -- triggerGuess: the BROADER activity trigger. Generalizes frameOpenTag past
    -- interaction-window opens by walking recent events newest-first, skipping
    -- firehose/ambient NOISE, and naming a curated activity or the raw event.
    do
        local tag, ev, friendly, isRaw

        -- curated activity: the questing ALLOC case (Tanaris capture: QUEST_LOG_UPDATE/
        -- QUEST_POI_UPDATE beside the big +dh spikes) now self-names "quest".
        tag, ev, friendly, isRaw = Report.triggerGuess({ events = { "UNIT_AURA", "QUEST_LOG_UPDATE" } })
        eq(tag, "quest", "triggerGuess names quest activity")
        eq(isRaw, false, "curated activity is not a raw fallback")
        eq(friendly, "quest update", "curated activity friendly label")

        -- NOISE (firehoses + ambient polls + cooldown/mouse churn) is skipped entirely.
        eq(Report.triggerGuess({ events = { "UNIT_AURA", "CHAT_MSG_CHANNEL",
            "COMBAT_LOG_EVENT_UNFILTERED", "SPELL_UPDATE_COOLDOWN",
            "COMMENTATOR_SKIRMISH_QUEUE_REQUEST", "GLOBAL_MOUSE_DOWN" } }), nil,
            "triggerGuess returns nil when every recent event is noise")

        -- newest-first: the most recent non-noise event is the probable trigger.
        eq((Report.triggerGuess({ events = { "BAG_UPDATE", "QUEST_LOG_UPDATE" } })), "bags",
            "triggerGuess takes the newest non-noise event")

        -- raw fallback: an uncurated but meaningful event returns its raw name (the
        -- owner's "at least take its best guess"), flagged isRaw for the UI.
        tag, ev, friendly, isRaw = Report.triggerGuess({ events = { "UNIT_AURA", "SOME_CUSTOM_EVENT" } })
        eq(tag, "SOME_CUSTOM_EVENT", "triggerGuess falls back to the raw event name")
        eq(isRaw, true, "raw fallback flagged isRaw")

        -- windows resolve too (the frameOpenTag vocabulary is included).
        eq((Report.triggerGuess({ events = { "AUCTION_HOUSE_SHOW" } })), "auction",
            "triggerGuess resolves interaction windows as well")

        -- zone events are never a mere trigger (classify owns the ZONE narrative).
        eq(Report.triggerGuess({ events = { "PLAYER_ENTERING_WORLD" } }), nil,
            "triggerGuess skips zone events")

        -- defensive
        eq(Report.triggerGuess({}), nil, "triggerGuess defensive (no events)")
        eq(Report.triggerGuess(nil), nil, "triggerGuess defensive (nil)")
    end

    -- build: trig= rides along as complementary context on a measured-cause spike whose
    -- trigger is NOT an interaction window — the questing ALLOC the owner asked to name.
    local trigout = Report.build({ meta = { version = "1" },
        spikes = { { index = 1, t = 10.0, dt = 180.0, heapDelta = 2057, zone = "Tanaris",
                     events = { "UNIT_AURA", "QUEST_LOG_UPDATE" } } } })
    has(trigout.text, "sus=ALLOC", "questing ALLOC keeps its measured cause")
    has(trigout.text, "^trig=quest", "questing ALLOC carries the broader trig= activity guess")
    assert(not trigout.text:find("|", 1, true), "trig= field carries no '|' (copy-safety)")

    -- build: trig= is NOT duplicated when open= already names the same window.
    local trigwin = Report.build({ meta = { version = "1" },
        spikes = { { index = 2, t = 10.0, dt = 140.0, heapDelta = 2057, zone = "x",
                     events = { "AUCTION_HOUSE_SHOW" } } } })
    has(trigwin.text, "^open=auction", "window trigger still uses open=")
    assert(not trigwin.text:find("trig=", 1, true), "trig= suppressed when open= already names the window")

    -- build: trig= suppressed on a zone-in (the transition narrative dominates).
    local trigzone = Report.build({ meta = { version = "1" },
        spikes = { { index = 3, t = 10.0, dt = 300.0, sinceZone = 1.0, zone = "x",
                     events = { "QUEST_LOG_UPDATE" } } } })
    has(trigzone.text, "sus=ZONE", "zone-in owns the classification")
    assert(not trigzone.text:find("trig=", 1, true), "trig= suppressed on a zone-in spike")

    -- build: an ALLOC frame whose recent events are all noise emits no trig= (no guess).
    local trignoise = Report.build({ meta = { version = "1" },
        spikes = { { index = 4, t = 10.0, dt = 90.0, heapDelta = 2000, zone = "x",
                     events = { "UNIT_AURA", "CHAT_MSG_CHANNEL" } } } })
    has(trignoise.text, "sus=ALLOC", "noise-only ALLOC still classified")
    assert(not trignoise.text:find("trig=", 1, true), "no trig= when every recent event is noise")

    -- build: raw-event fallback rides the wire as trig=<RAW_EVENT>.
    local trigraw = Report.build({ meta = { version = "1" },
        spikes = { { index = 5, t = 10.0, dt = 120.0, heapDelta = 900, zone = "x",
                     events = { "UNIT_AURA", "TRANSMOGRIFY_UPDATE" } } } })
    has(trigraw.text, "^trig=TRANSMOGRIFY_UPDATE", "uncurated meaningful event rides as raw trig=")

    -- rankOffenders: sort + tie-break + top-n
    local ranked = Report.rankOffenders({
        { name = "b", cpuMs = 5, memKb = 100 },
        { name = "a", cpuMs = 5, memKb = 200 },  -- ties cpu, higher mem -> first
        { name = "c", cpuMs = 9, memKb = 10 },
    }, 2)
    eq(#ranked, 2, "rank top-n length")
    eq(ranked[1].name, "c", "rank highest cpu first")
    eq(ranked[2].name, "a", "rank tie-break by mem")

    -- build: header self-describing + all section tags present
    local out = Report.build({
        meta = { version = "0.2.0", build = "12340", iface = "30300",
                 realm = "TestRealm", zone = "Ragefire Chasm", char = "Probey",
                 windowSec = 30, thresholdMs = 50, profileOn = true,
                 totalSpikes = 3, shownSpikes = 1, generatedAt = 123.4 },
        matrix = { { name = "debugprofilestop", status = "ok", detail = "confirmed" },
                   { name = "GetAddOnCPUUsage", status = "off", detail = "scriptProfile=0" } },
        spikes = { { index = 1, t = 100.0, dt = 62.5, inCombat = true, cleuPS = 480,
                     heapDelta = -128, zone = "Ragefire Chasm",
                     events = { "COMBAT_LOG_EVENT_UNFILTERED", "PLAYER_ENTERING_WORLD" },
                     topCPU = { { name = "BigAddon", ms = 40.0 } } } },
        offenders = { { name = "BigAddon", cpuMs = 40.0, memKb = 2048.0, events = 999 } },
        rates = { { name = "COMBAT_LOG_EVENT_UNFILTERED", count = 14400, perSec = 480.0 } },
    })
    has(out.text, "CPP1^ver=0.2.0", "build header")
    has(out.text, "iface=30300", "build header iface")
    has(out.text, "^realm=TestRealm", "build header realm (the field that got eaten by |r)")
    has(out.text, "M^api=debugprofilestop^st=ok", "build matrix row")
    has(out.text, "S^i=1^", "build spike row")
    has(out.text, "sus=", "build spike suspect")
    has(out.text, "O^r=1^addon=BigAddon", "build offender row")
    has(out.text, "R^ev=COMBAT_LOG_EVENT_UNFILTERED", "build rate row")
    has(out.text, "END^lines=", "build footer")
    assert(not out.text:find("old=1"), "fresh spike (no boot set) carries no old marker")

    -- build: restored-spike marker. boot=150 => a spike at t=100 predates this
    -- session's load (restored from SavedVariables) and must be flagged old=1; a
    -- spike at t=200 is this-session and must not be.
    local rout = Report.build({
        meta = { version = "1", boot = 150.0 },
        spikes = { { index = 9, t = 100.0, dt = 800.0, zone = "Ironforge", events = {} },
                   { index = 10, t = 200.0, dt = 90.0, zone = "Ironforge", events = {} } },
    })
    has(rout.text, "S^i=9^t=100.0^dt=800.0^cmb=0^cleu=0^dh=0^sus=?^zone=Ironforge^ev=^cpu=^old=1",
        "restored spike (t<boot) flagged old=1")
    has(rout.text, "S^i=10^t=200.0^", "this-session spike present")
    local _, oldCount = rout.text:gsub("old=1", "")
    eq(oldCount, 1, "only the restored spike (t<boot) is flagged old; this-session spike is not")

    -- build: GC measurement row (canary verdict)
    local gout = Report.build({ meta = { version = "1" },
        gc = { collectMs = 0.0, allocKB = 900, freedKB = 0, works = false, beforeKB = 274848, afterKB = 275748 } })
    has(gout.text, "G^collect=0.0^alloc=900^freed=0^works=0^before=274848", "build GC row (no-op verdict)")

    -- build: load-profile rows (timeline + per-addon load ranking)
    local lout = Report.build({ meta = { version = "1" },
        load = {
            summary = { loginMs = 700.0, worldMs = 3400.0,
                        addons = 2, capMs = 350.0, capHeapKB = 19500 },
            ranked = { { name = "HeavyAddon", dMs = 300.0, dHeapKB = 18000 },
                       { name = "LightAddon", dMs = 50.0, dHeapKB = nil } },
        } })
    has(lout.text, "T^login=700.0^world=3400.0^addons=2^cap=350.0^capkb=19500", "build load timeline row (probe-relative)")
    has(lout.text, "L^r=1^addon=HeavyAddon^ms=300.0^heap=18000", "build per-addon load row (heaviest)")
    has(lout.text, "L^r=2^addon=LightAddon^ms=50.0^heap=?", "build per-addon load row (nil heap -> ?)")

    -- build: cooperative Meter participant rows
    local pout = Report.build({ meta = { version = "1" },
        profiled = { { tag = "MyAddon:OnUpdate", ms = 42.5, calls = 900, perMs = 0.047 },
                     { tag = "MyAddon:OnEvent", ms = 3.1, calls = 12, perMs = 0.258 } } })
    has(pout.text, "P^r=1^tag=MyAddon:OnUpdate^ms=42.5^calls=900", "build profiled participant row")

    -- build: BLOCKED namer rows (self-describing addon+function offenders, ranked)
    local bout = Report.build({ meta = { version = "1" },
        blocked = { { addon = "ExadTweaks", func = "TargetFrameToT:Show()", count = 37385, perSec = 45.3 },
                    { addon = "OtherAddon", func = "Frame:Hide()", count = 12, perSec = 0.1 } } })
    has(bout.text, "B^r=1^addon=ExadTweaks^func=TargetFrameToT:Show()^n=37385^ps=45.3",
        "build blocked namer row (self-describing offender, ranked by count)")
    has(bout.text, "B^r=2^addon=OtherAddon^func=Frame:Hide()^n=12^ps=0.1", "build lesser blocked offender")
    assert(not bout.text:find("|", 1, true), "blocked rows carry no '|' (copy-safety)")

    -- build: memory-walk rows (WM summary + ranked W globals; bytes -> KB)
    local mout = Report.build({ meta = { version = "1" },
        mem = { totalBytes = 166 * 1024 * 1024, totalNodes = 262144, roots = 40, capHit = true,
                ranked = { { name = "pfDB", bytes = 158 * 1024 * 1024, nodes = 262000 },
                           { name = "AUCTIONATOR_PRICE_DATABASE", bytes = 730 * 1024, nodes = 8207 } } } })
    has(mout.text, "WM^kb=169984^tbls=262144^roots=40^cap=1^shown=2", "build mem summary row (cap=floor)")
    has(mout.text, "W^r=1^name=pfDB^kb=161792^tbls=262000", "build top memory global (the elephant)")
    has(mout.text, "W^r=2^name=AUCTIONATOR_PRICE_DATABASE^kb=730^tbls=8207", "build lesser memory global")
    assert(not mout.text:find("|", 1, true), "mem rows carry no '|' (copy-safety)")

    -- build: a spike carries the GetNetStats snapshot (net=in/out/lat). This is the
    -- channel that separates an I/O/streaming stall from engine CPU on a big
    -- unattributed frame — it must round-trip through the S row.
    local nout = Report.build({ meta = { version = "1" },
        spikes = { { index = 5, t = 10.0, dt = 300.0, heapDelta = 1, zone = "Ironforge",
                     events = {}, net = { inKB = 8.0, outKB = 2.0, lat = 241 } } } })
    has(nout.text, "^cpu=^net=8.0/2.0/241", "spike carries the GetNetStats snapshot (down/up/world-latency)")
    -- a spike WITHOUT a net snapshot (API absent, or a record from before this
    -- field existed) simply omits net= — no fake 0/0/0 that reads as measured.
    local nnout = Report.build({ meta = { version = "1" },
        spikes = { { index = 6, t = 10.0, dt = 90.0, zone = "x", events = {} } } })
    assert(not nnout.text:find("net=", 1, true), "spike without a net snapshot omits net=")

    -- str= (New-player loads): present only when streaming events fired on the frame
    -- (a positive count is the signal). A monster BG spike would carry it; a quiet
    -- frame omits it, so old exact-match rows are unaffected.
    local sout = Report.build({ meta = { version = "1" },
        spikes = { { index = 7, t = 10.0, dt = 1283.0, heapDelta = 23, zone = "Hillsbrad Foothills",
                     events = { "UNIT_AURA" }, streamN = 14,
                     net = { inKB = 61.0, outKB = 0.6, lat = 122 } } } })
    has(sout.text, "^net=61.0/0.6/122^str=14", "spike carries str= after net= when streaming events fired")
    local snone = Report.build({ meta = { version = "1" },
        spikes = { { index = 8, t = 10.0, dt = 90.0, zone = "x", events = {}, streamN = 0 } } })
    assert(not snone.text:find("str=", 1, true), "a frame with zero new-player loads omits str=")

    -- COPY-SAFETY INVARIANT: the report must contain NO "|" anywhere, or the WoW
    -- font renderer eats |r/|t/|c... on Ctrl+C (the first live-capture bug).
    assert(not out.text:find("|", 1, true), "report must contain no '|' (WoW escape lead-in)")

    -- build: separator/pipe/newline injection in dynamic fields is sanitized
    local inj = Report.build({ meta = { zone = "Bad|Zone^Evil\nName", version = "1" } })
    eq(select(2, inj.text:gsub("\n", "")) <= 2, true, "no stray newlines from zone")
    assert(not inj.text:find("|", 1, true), "pipe in zone must be stripped")
    assert(inj.text:find("Bad Zone Evil Name", 1, true), "sep/pipe in zone neutralized to spaces")

    -- pagination: many rows -> multiple self-describing pages
    local manyRates = {}
    for i = 1, 300 do manyRates[i] = { name = "E" .. i, count = i, perSec = i } end
    Report.MAX_EVENTS = 300
    local paged = Report.build({ meta = { version = "1" }, rates = manyRates })
    assert(#paged.pages >= 2, "pagination should split large bodies")
    has(paged.pages[1], "page=1/", "page marker on page 1")
    has(paged.pages[2], "page=2/", "page marker on page 2")
    Report.MAX_EVENTS = 15

    print("Report: OK")
end

return ns.Report
