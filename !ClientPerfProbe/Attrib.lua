--[[ Attrib.lua — per-addon CPU + memory attribution sampler (README §6 step 4).

     Answers the "WHO" the community wants: which addon spent the CPU/memory in
     the last window. CPU requires scriptProfile=1 (armed via a reload); memory
     does not. Everything is feature-gated through Probe.caps() — if the CPU
     family is stripped on Ascension, attribution degrades to memory deltas only
     and the report still stands on event rates.

     Cost control (§4, measurement perturbs): a FULL addon scan is expensive, so
     it runs on an interval (default 5s), NOT per frame. Spike records borrow the
     most recent interval snapshot rather than scanning inside the spike.

     WoW-facing; syntax-checked only. Ranking/formatting lives in Report (pure).
]]

local ADDON, ns = ...

local Attrib = {}

local prevCPU = {}     -- addon name -> cumulative ms at last snapshot
local prevMem = {}     -- addon name -> cumulative KB at last snapshot
local lastRanked = {}  -- most recent ranked delta list (for spike records)
local haveBaseline = false
local cpuSeen = false  -- have we ever read a nonzero per-addon CPU value?
local memSeen = false  -- have we ever read a nonzero per-addon memory value?

-- Take a snapshot of all loaded addons and return per-addon DELTAS since the
-- previous snapshot. First call establishes a baseline and returns {}.
function Attrib.sample()
    local caps = ns.Probe and ns.Probe.caps() or {}
    if not caps.enumAddons then
        lastRanked = {}
        return lastRanked
    end

    if caps.addonCPU and caps.profileOn and type(UpdateAddOnCPUUsage) == "function" then
        UpdateAddOnCPUUsage()
    end
    if caps.addonMem and type(UpdateAddOnMemoryUsage) == "function" then
        UpdateAddOnMemoryUsage()
    end

    local n = GetNumAddOns()
    local out = {}
    for i = 1, n do
        local name = GetAddOnInfo(i)
        if name then
            local cpu = (caps.addonCPU and caps.profileOn) and (GetAddOnCPUUsage(i) or 0) or nil
            local mem = caps.addonMem and (GetAddOnMemoryUsage(i) or 0) or nil
            if cpu and cpu > 0 then cpuSeen = true end
            if mem and mem > 0 then memSeen = true end

            local cpuDelta, memDelta = 0, 0
            if cpu ~= nil then
                cpuDelta = cpu - (prevCPU[name] or cpu)  -- 0 on first sight
                prevCPU[name] = cpu
            end
            if mem ~= nil then
                memDelta = mem - (prevMem[name] or mem)
                prevMem[name] = mem
            end

            -- keep only addons that did something this window (or, on baseline, all)
            if not haveBaseline or cpuDelta > 0 or memDelta ~= 0 then
                out[#out + 1] = {
                    name = name,
                    cpuMs = cpuDelta > 0 and cpuDelta or 0,
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

-- Cheap accessor for spike records: the top few offenders from the last
-- interval sample, shaped as { name=, ms= } for Report.classify / spike rows.
function Attrib.topForSpike(limit)
    local out = {}
    for i = 1, math.min(limit or 3, #lastRanked) do
        out[i] = { name = lastRanked[i].name, ms = lastRanked[i].cpuMs }
    end
    return out
end

function Attrib.lastRanked() return lastRanked end

-- Attribution capability actually observed live: "none" is the Ascension case
-- (both CPU and memory return 0). Drives the report header's attr= field so a
-- pasted capture is honest about why offender rows are empty.
function Attrib.attrMode()
    if cpuSeen and memSeen then return "cpu+mem" end
    if cpuSeen then return "cpu" end
    if memSeen then return "mem" end
    return "none"
end

function Attrib.reset()
    prevCPU, prevMem, lastRanked = {}, {}, {}
    haveBaseline = false
    -- deliberately DON'T reset cpuSeen/memSeen: capability is a client fact, not
    -- a per-window one, and clear/reset shouldn't relitigate it.
end

ns.Attrib = Attrib
