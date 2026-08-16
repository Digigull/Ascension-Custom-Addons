--[[ Attrib.lua — per-addon MEMORY attribution sampler (README §6 step 4).

     Answers the "WHO" the community wants: which addon moved memory in the last
     window. The CPU half is gone: it required scriptProfile=1, which this client
     resets to 0 on load, so GetAddOnCPUUsage only ever returned zeros here.
     Feature-gated through Probe.caps() — with GetAddOnMemoryUsage locked too, this
     degrades to nothing and the report stands on event rates and the load profile.

     Cost control (§4, measurement perturbs): a FULL addon scan is expensive, so
     it runs on an interval (default 5s), NOT per frame. Spike records borrow the
     most recent interval snapshot rather than scanning inside the spike.

     WoW-facing; syntax-checked only. Ranking/formatting lives in Report (pure).
]]

local ADDON, ns = ...

local Attrib = {}

local prevMem = {}     -- addon name -> cumulative KB at last snapshot
local lastRanked = {}  -- most recent ranked delta list
local haveBaseline = false
local memSeen = false  -- have we ever read a nonzero per-addon memory value?

-- Take a snapshot of all loaded addons and return per-addon DELTAS since the
-- previous snapshot. First call establishes a baseline and returns {}.
function Attrib.sample()
    local caps = ns.Probe and ns.Probe.caps() or {}
    if not caps.enumAddons then
        lastRanked = {}
        return lastRanked
    end

    if caps.addonMem and type(UpdateAddOnMemoryUsage) == "function" then
        UpdateAddOnMemoryUsage()
    end

    local n = GetNumAddOns()
    local out = {}
    for i = 1, n do
        local name = GetAddOnInfo(i)
        if name then
            local mem = caps.addonMem and (GetAddOnMemoryUsage(i) or 0) or nil
            if mem and mem > 0 then memSeen = true end

            local memDelta = 0
            if mem ~= nil then
                memDelta = mem - (prevMem[name] or mem)  -- 0 on first sight
                prevMem[name] = mem
            end

            -- keep only addons that did something this window (or, on baseline, all)
            if not haveBaseline or memDelta ~= 0 then
                out[#out + 1] = {
                    name = name,
                    memKb = memDelta,
                    events = 0,
                }
            end
        end
    end

    haveBaseline = true
    lastRanked = ns.Report and ns.Report.rankOffenders(out, ns.Report.MAX_OFFENDERS) or out
    return lastRanked
end

function Attrib.lastRanked() return lastRanked end

-- Attribution capability actually observed live: "none" is the Ascension case
-- (per-addon memory reads back 0). Drives the report header's attr= field so a
-- pasted capture is honest about why offender rows are empty.
function Attrib.attrMode()
    if memSeen then return "mem" end
    return "none"
end

function Attrib.reset()
    prevMem, lastRanked = {}, {}
    haveBaseline = false
    -- deliberately DON'T reset memSeen: capability is a client fact, not a
    -- per-window one, and clear/reset shouldn't relitigate it.
end

ns.Attrib = Attrib
