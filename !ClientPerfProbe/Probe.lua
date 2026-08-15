--[[ Probe.lua — §5 / Appendix-A API feature-detection support matrix.

     This is the GATE for everything else. The profiling family is ABSENT from
     Ascension's API dumps, so nothing here is assumed — every API is probed
     live in-game and reported with a status. Only debugprofilestop() is known
     to work; the rest is confirmed at runtime, not by trusting a reference.

     WoW-facing (reads _G, GetCVar). Not run under `make test`; syntax-checked
     only. All detection is lazy (called from events), never at file scope.
]]

local ADDON, ns = ...

local Probe = {}

-- status codes used in the report matrix (see Report wire format):
--   ok      present and (where checkable) returning live data
--   missing symbol absent on this client
--   off     present but gated OFF (CPU family without scriptProfile)
--   zero    present but returning 0/empty (armed but no data yet)
--   n/a     not applicable / not yet checked

local function isFn(name)
    return type(rawget(_G, name) or _G[name]) == "function"
end

-- Probe the whole toolbox. Returns an ordered array of { name, status, detail }
-- suitable for Report.build{ matrix = ... }.
function Probe.buildMatrix()
    local m = {}
    local function add(name, status, detail)
        m[#m + 1] = { name = name, status = status, detail = detail or "" }
    end

    -- High-res wall clock (the confirmed backbone).
    if isFn("debugprofilestop") then
        local ok, v = pcall(debugprofilestop)
        add("debugprofilestop", ok and "ok" or "missing", ok and (tostring(math.floor(v)) .. "ms") or "call failed")
    else
        add("debugprofilestop", "missing", "no high-res timer")
    end
    add("debugprofilestart", isFn("debugprofilestart") and "ok" or "missing")

    -- Coarse corroboration.
    add("GetFramerate", isFn("GetFramerate") and "ok" or "missing")
    add("GetTime", isFn("GetTime") and "ok" or "missing")
    -- GetNetStats backs the spike net= channel (I/O vs engine-CPU discrimination).
    -- Report a live sample + the arity: on 3.3.5 it returns 3 values (in, out,
    -- latency); Cata+ returns 4 (latency split home/world). Confirming the arity
    -- live answers README App. A / §9 ("verify the arity in-game").
    if isFn("GetNetStats") then
        local res = { pcall(GetNetStats) }
        if res[1] then
            local n = #res - 1
            add("GetNetStats", "ok", string.format("n=%d in=%s out=%s lat=%s",
                n, tostring(res[2]), tostring(res[3]), tostring(res[#res])))
        else
            add("GetNetStats", "ok", "present; call failed")
        end
    else
        add("GetNetStats", "missing")
    end

    -- IsMouseButtonDown backs the spike mouse=held signal + the Window-drag (DRAG)
    -- classifier. A drag is a frame script the event system can't see, and in a busy
    -- city the GLOBAL_MOUSE_DOWN gets flooded out of the recent-event ring before a
    -- spike snapshot — so the driver samples the button state on the spike frame
    -- instead. Not in the API dumps (feature-detect, ground rule 2): confirm it live
    -- here, with the current LeftButton state as the sample.
    if isFn("IsMouseButtonDown") then
        local ok, held = pcall(IsMouseButtonDown, "LeftButton")
        add("IsMouseButtonDown", ok and "ok" or "missing",
            ok and ("LeftButton=" .. (held and "1" or "0")) or "call failed")
    else
        add("IsMouseButtonDown", "missing", "window-drag detection unavailable")
    end

    -- Lua heap / GC (no CVar needed).
    do
        local ok, kb = pcall(collectgarbage, "count")
        add("collectgarbage(count)", (ok and type(kb) == "number") and "ok" or "missing",
            (ok and type(kb) == "number") and (string.format("%dKB", math.floor(kb))) or "")
    end
    add("gcinfo", isFn("gcinfo") and "ok" or "missing")

    -- Per-addon memory (usually available without the CVar). This is our PRIMARY
    -- attribution fallback now that scriptProfile is locked, so the matrix scans
    -- ALL addons by index and reports the total + the top consumer: if per-addon
    -- memory is also stubbed (all zero), we need to know here, not mid-dungeon.
    add("UpdateAddOnMemoryUsage", isFn("UpdateAddOnMemoryUsage") and "ok" or "missing")
    if isFn("GetAddOnMemoryUsage") then
        local ok, detail = pcall(function()
            if isFn("UpdateAddOnMemoryUsage") then UpdateAddOnMemoryUsage() end
            local selfKb = GetAddOnMemoryUsage(ADDON) or 0
            local total, topName, topKb = 0, "?", 0
            if isFn("GetNumAddOns") and isFn("GetAddOnInfo") then
                for i = 1, GetNumAddOns() do
                    local nm = GetAddOnInfo(i)
                    local kb = GetAddOnMemoryUsage(i) or 0
                    total = total + kb
                    if kb > topKb then topKb, topName = kb, nm end
                end
            end
            return string.format("self=%dKB total=%dKB top=%s:%dKB",
                math.floor(selfKb), math.floor(total), tostring(topName), math.floor(topKb))
        end)
        -- "zero" (present but all-zero) is a distinct, important verdict vs "ok".
        local status = "ok"
        if ok and type(detail) == "string" and detail:find("total=0KB", 1, true) then status = "zero" end
        add("GetAddOnMemoryUsage", ok and status or "missing", ok and detail or "")
    else
        add("GetAddOnMemoryUsage", "missing")
    end

    -- scriptProfile CVar — the crux for CPU attribution.
    local prof = "n/a"
    if isFn("GetCVar") then
        local ok, v = pcall(GetCVar, "scriptProfile")
        if ok then prof = tostring(v) end
        add("cvar:scriptProfile", ok and "ok" or "missing", "value=" .. prof)
    else
        add("cvar:scriptProfile", "missing", "no GetCVar")
    end
    local profileOn = (prof == "1")

    -- Input/display CVars that are CANDIDATE levers for the window-drag / mouse stall
    -- (sus=DRAG). REPORTED ONLY, never a recommendation: the owner A/B-tests them
    -- (toggle in Video > Display, re-capture the same drag, compare the DRAG spike) and
    -- the data decides — measure-first (ground rule 1; README §2's killed pre-warm is the
    -- cautionary tale). Names are PROBED across candidates, not asserted (ground rules
    -- 2/5): the detail shows which CVar name actually matched on this client, so the
    -- owner's matrix confirms the real Ascension names instead of us hardcoding a story.
    -- reduceInputLag forces a per-frame GPU pipeline flush (latency vs frame stalls); the
    -- hardware cursor avoids a per-frame software-cursor redraw — both plausibly touch a
    -- drag frame. Read via GetCVar (confirmed live: the scriptProfile row above).
    if isFn("GetCVar") then
        local function reportCVar(label, candidates)
            for _, name in ipairs(candidates) do
                local ok, v = pcall(GetCVar, name)
                if ok and v ~= nil then
                    add("cvar:" .. label, "ok", name .. "=" .. tostring(v))
                    return
                end
            end
            add("cvar:" .. label, "missing", "tried " .. table.concat(candidates, "/"))
        end
        -- The two graphics CVars that resolve live on Ascension are both gx*-prefixed
        -- (gxVSync=0 / gxTripleBuffer=0), while the plain reduceInputLag / hardwareCursor
        -- names came back missing — so probe the gx* variants too (a data-driven bet from
        -- the observed naming convention, still a probe not an assertion). If these also
        -- miss, the two settings likely aren't GetCVar-readable here and the owner can
        -- supply the real name via the devconsole `cvar` command.
        reportCVar("reduceInputLag", { "reduceInputLag", "gxReduceInputLag" })
        reportCVar("hardwareCursor", { "hwCursor", "useHardwareCursor", "hardwareCursor",
                                       "gxCursor", "gxHardwareCursor" })
        reportCVar("vsync",          { "gxVSync", "verticalSync" })
        reportCVar("tripleBuffer",   { "gxTripleBuffer", "tripleBuffer" })
    end

    -- Per-addon / frame / event CPU (requires scriptProfile=1 + a reload to arm).
    -- Present-but-off is reported as "off" so the owner knows to arm it.
    local cpuFns = {
        "UpdateAddOnCPUUsage", "GetAddOnCPUUsage", "ResetCPUUsage",
        "GetFrameCPUUsage", "GetEventCPUUsage", "GetFunctionCPUUsage",
        "GetScriptCPUUsage",
    }
    for _, name in ipairs(cpuFns) do
        if isFn(name) then
            add(name, profileOn and "ok" or "off", profileOn and "" or "needs scriptProfile=1 + reload")
        else
            add(name, "missing")
        end
    end

    -- Addon enumeration (needed to iterate offenders).
    add("GetNumAddOns", isFn("GetNumAddOns") and "ok" or "missing")
    add("GetAddOnInfo", isFn("GetAddOnInfo") and "ok" or "missing")

    return m
end

-- Quick capability flags the rest of the addon branches on. Cheap; recomputed
-- on demand so it reflects the live CVar state after an arming reload.
function Probe.caps()
    local prof = isFn("GetCVar") and (select(1, pcall(GetCVar, "scriptProfile")) and GetCVar("scriptProfile")) or nil
    return {
        clock      = isFn("debugprofilestop"),
        heap       = (select(1, pcall(collectgarbage, "count"))),
        addonMem   = isFn("GetAddOnMemoryUsage") and isFn("UpdateAddOnMemoryUsage"),
        addonCPU   = isFn("GetAddOnCPUUsage") and isFn("UpdateAddOnCPUUsage"),
        enumAddons = isFn("GetNumAddOns") and isFn("GetAddOnInfo"),
        profileOn  = (prof == "1"),
        cvar       = isFn("GetCVar") and isFn("SetCVar"),
        mouse      = isFn("IsMouseButtonDown"),   -- window-drag (DRAG) detection
    }
end

ns.Probe = Probe
