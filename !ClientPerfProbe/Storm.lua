--[[ Storm.lua — "addon storm" detector (PURE, self-tested).

     The owner asked for a minimap notifier that BLINKS when it catches an addon
     storm "like Exad had" — the live ExadTweaks capture fired ADDON_ACTION_BLOCKED
     at 45/s (a protected call retried every frame under combat lockdown), a taint
     storm that hammers the client. That self-describing blocked-event rate is the
     primary storm signal (honest: the engine NAMES the offender, README findings).

     This module is the pure decision core — no WoW calls, no frames — so the blink
     logic is offline-testable and the thresholds live in one place, tuned from the
     measured 45/s catch (not a guessed story; CLAUDE.md ground rule 1). The minimap
     feeds it live inputs each throttled tick and maps the returned level to a colour.

     Inputs (all optional; missing => 0):
        blockedPS   instantaneous ADDON_ACTION_BLOCKED/_FORBIDDEN rate (events/sec)
        spikeCount  fresh notable spikes (>= a display threshold) in the recent window
        worstMs     worst fresh spike frame-time (ms) in the recent window
        chatPS      instantaneous CHAT_MSG_CHANNEL rate (messages/sec)

     Levels: "none" (quiet) · "watch" (something to look at) · "storm" (blink).
     Only a taint storm blinks — that's the specific, self-attributed, actionable
     event the owner named. A stutter cluster raises "watch" (steady tint), never a
     false "storm" alarm.
]]

local ADDON, ns = ...
ns = ns or {}

local Storm = {}

-- Thresholds. Blocked rates are anchored to the measured ExadTweaks 45/s storm;
-- WATCH is set well below it so an emerging retry-loop is flagged before it's a
-- full storm. Spike thresholds mark "the client is visibly stuttering right now".
-- All tunable from real captures — do not harden into stories.
Storm.BLOCKED_STORM_PS  = 10    -- sustained blocked/s at/above this = taint storm (blink)
Storm.BLOCKED_WATCH_PS  = 3     -- a protected call retrying a few times a second
Storm.SPIKE_NOTABLE_MS  = 100   -- a frame this long is a felt hitch (what spikeCount counts)
Storm.SPIKE_CLUSTER     = 3     -- this many notable spikes in the window = stuttery => watch
Storm.SPIKE_BIG_MS      = 250   -- one spike this big alone is worth a watch tint
-- Chat channel flood. Anchored to the live Ironforge capture: three addon data
-- channels delivered 107/s between them while every channel humans talked in totalled
-- 0.44/s. 20/s is far above anything conversation produces and far below what was
-- actually measured, so it cannot fire on a busy realm's trade chat.
Storm.CHAT_FLOOD_PS     = 20

-- evaluate(inputs) -> { level, blink, reason }
--   level : "none" | "watch" | "storm"
--   blink : true only for a taint storm (the Exad class)
--   reason: short human string for the tooltip / UI (never nil)
function Storm.evaluate(inp)
    inp = inp or {}
    local blockedPS  = tonumber(inp.blockedPS)  or 0
    local spikeCount = tonumber(inp.spikeCount) or 0
    local worstMs    = tonumber(inp.worstMs)    or 0
    local chatPS     = tonumber(inp.chatPS)     or 0

    if blockedPS >= Storm.BLOCKED_STORM_PS then
        return {
            level  = "storm",
            blink  = true,
            reason = string.format("Addon taint storm: %d blocked calls/s", math.floor(blockedPS + 0.5)),
        }
    end

    if blockedPS >= Storm.BLOCKED_WATCH_PS then
        return {
            level  = "watch",
            blink  = false,
            reason = string.format("Blocked calls climbing: %.1f/s", blockedPS),
        }
    end

    if spikeCount >= Storm.SPIKE_CLUSTER then
        return {
            level  = "watch",
            blink  = false,
            reason = string.format("%d recent spikes (worst %d ms)", spikeCount, math.floor(worstMs + 0.5)),
        }
    end

    if worstMs >= Storm.SPIKE_BIG_MS then
        return {
            level  = "watch",
            blink  = false,
            reason = string.format("Big frame spike: %d ms", math.floor(worstMs + 0.5)),
        }
    end

    -- Chat flood: a steady tax rather than an acute stutter, so it sits BELOW the
    -- spike checks — what you are feeling right now outranks what is costing you
    -- continuously. It does not blink either: only a taint storm does. The reason
    -- points at the report rather than naming the channel, because naming it needs
    -- GetChannelList + GetChatWindowChannels and this runs on a ~1s tick; the C rows
    -- do the naming, this only tells you to go and look.
    if chatPS >= Storm.CHAT_FLOOD_PS then
        return {
            level  = "watch",
            blink  = false,
            reason = string.format("Chat channel flood: %d msg/s - /cpp to see which channel",
                                   math.floor(chatPS + 0.5)),
        }
    end

    return { level = "none", blink = false, reason = "No stutter detected" }
end

ns.Storm = Storm

--============================================================================--
if _SELFTEST then
    local function eq(a, b, msg)
        assert(a == b, (msg or "eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
    end

    -- quiet client
    local r = Storm.evaluate({ blockedPS = 0, spikeCount = 0, worstMs = 20 })
    eq(r.level, "none", "quiet => none")
    eq(r.blink, false, "quiet does not blink")

    -- the Exad taint storm (45/s) => storm + blink
    r = Storm.evaluate({ blockedPS = 45 })
    eq(r.level, "storm", "45/s blocked => storm")
    eq(r.blink, true, "a taint storm blinks")
    assert(r.reason:find("storm"), "storm reason names it")

    -- exactly at the storm line
    eq(Storm.evaluate({ blockedPS = Storm.BLOCKED_STORM_PS }).level, "storm", "storm boundary is inclusive")

    -- emerging retry loop => watch, no blink
    r = Storm.evaluate({ blockedPS = 4 })
    eq(r.level, "watch", "blocked over watch line => watch")
    eq(r.blink, false, "watch does not blink")

    -- a cluster of notable spikes => watch (stutter, not a taint storm)
    r = Storm.evaluate({ blockedPS = 0, spikeCount = 3, worstMs = 140 })
    eq(r.level, "watch", "spike cluster => watch")
    eq(r.blink, false, "spike cluster does not blink (not a taint storm)")

    -- one big spike alone => watch
    eq(Storm.evaluate({ worstMs = 300 }).level, "watch", "one big spike => watch")

    -- a single small blip below every line => none
    eq(Storm.evaluate({ spikeCount = 1, worstMs = 120 }).level, "none", "single sub-cluster blip => none")

    -- storm dominates watch-level spikes (blocked wins)
    r = Storm.evaluate({ blockedPS = 20, spikeCount = 5, worstMs = 500 })
    eq(r.level, "storm", "blocked storm outranks spike watch")

    -- a chat flood raises a watch, never a blink (only a taint storm blinks)
    r = Storm.evaluate({ chatPS = 107 })
    eq(r.level, "watch", "107 msg/s of channel chat => watch")
    eq(r.blink, false, "a chat flood does not blink")
    assert(r.reason:find("/cpp"), "chat reason sends you to the rows that name the channel")
    eq(Storm.evaluate({ chatPS = Storm.CHAT_FLOOD_PS }).level, "watch", "chat line is inclusive")

    -- real city conversation must never trip it (measured: 0.44/s across all channels)
    eq(Storm.evaluate({ chatPS = 0.44 }).level, "none", "human chat volume => none")
    eq(Storm.evaluate({ chatPS = 3 }).level, "none", "even a busy realm's trade chat => none")

    -- an acute stutter outranks the chronic tax
    r = Storm.evaluate({ chatPS = 107, spikeCount = 3, worstMs = 140 })
    assert(r.reason:find("spikes"), "a spike cluster is reported ahead of a chat flood")
    -- ...and a taint storm outranks both
    eq(Storm.evaluate({ blockedPS = 45, chatPS = 107 }).level, "storm", "taint storm still wins")

    -- garbage-in never crashes, degrades to none
    eq(Storm.evaluate(nil).level, "none", "nil input => none")
    eq(Storm.evaluate({ blockedPS = "x" }).level, "none", "non-number input degrades to none")

    print("Storm: OK")
end

return ns.Storm
