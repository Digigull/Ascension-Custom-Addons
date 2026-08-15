--[[ UI.lua — the at-a-glance report window, Details!-style (Community UX,
     docs/PROPOSAL.md Product A).

     A large, draggable, resizable window that shows the data as a ranked list of
     horizontal BARS (name on the bar, value on the right, width = value / the top
     value) — the Details! breakdown look. A dropdown at the top switches the
     measurement (Memory / Spikes / CPU / Events / Addon Storm / Load / API Matrix /
     Overview). Data that isn't a natural ranked-number list (API rows, overview
     facts) is shown as a FULL bar; clicking any bar opens a popup with that item's
     detail.

     This is a *convenience view* over the same live data the report collects — it
     formats only, never re-gathers or perturbs; a refresh is itself a frame cost
     (full snapshot + relayout), so the live poll defaults to a tame 5 s and is
     user-selectable (incl. Off). The §6a copy/paste export window stays the
     definition-of-done relay; "Export ▸" hands the current data straight to it.

     WoW-facing; syntax-checked only. Frame construction is deferred to first Show(),
     so this file makes no WoW calls at load. NOTE FontStrings/Textures are regions,
     not frames — they have no SetScript on 3.3.5 (the sim enforces this).
]]

local ADDON, ns = ...

local UI = {}

local api = {}          -- callbacks wired by Core (snapshot, openReport, runMemWalk, clear, stormInputs)
local db                -- ClientPerfProbeDB (persist window geometry + poll under db.ui)
local frame
local detailFrame
local currentCat = "spikes"    -- default view: frame spikes (the owner's ask)
local refreshAccum = 0
local lastRenderText = ""       -- plain-text mirror of the current view (sim/accessibility)

-- forward declarations so provider closures can reference them as upvalues
local render, showDetail, selectCat

-- Shared dark backdrop — matches the copy/paste export window (ExportWindow.lua):
-- the flat Details-style recipe (UI-Tooltip-Background + a 1px WHITE8X8 border,
-- dark-tinted), NOT the ornate gold UI-DialogBox parchment. Keeps every cpp
-- window on one consistent dark theme. Portable house style — see DRAG-FREEZE.md.
local function darkBackdrop(f)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true, tileSize = 64, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
    f:SetBackdropBorderColor(0.30, 0.30, 0.34, 1)
end

-- Live refresh cadence: a refresh rebuilds the snapshot + relays a big list, which
-- itself costs a frame, so default TAME and let the user slow it or turn it Off.
local POLL_OPTIONS = { 0, 1, 2, 5, 10 }   -- seconds; 0 = off (manual only)
local DEFAULT_POLL = 5
local refreshSec = DEFAULT_POLL

local ROW_H = 18
local ICON = 16

--------------------------------------------------------------------------------
-- format helpers

local function fmtKB(kb)
    kb = tonumber(kb) or 0
    if math.abs(kb) >= 1024 then return string.format("%.1f MB", kb / 1024) end
    return string.format("%d KB", math.floor(kb + 0.5))
end
local function ms(x) return string.format("%.0f", tonumber(x) or 0) end
local function ms1(x) return string.format("%.1f", tonumber(x) or 0) end

-- Put `str` in a FontString, truncated to one line within maxW (Details-style).
-- FontStrings without a set width render single-line; we shorten the text to fit
-- so a tiny window collapses names instead of wrapping. Uses GetStringWidth to
-- size the trim (approximate — variable-width font — then one corrective pass).
local function fitText(fs, str, maxW)
    str = str or ""
    fs:SetText(str)
    if type(maxW) ~= "number" or maxW <= 0 or #str <= 2 then return end
    local getW = fs.GetStringWidth
    local sw = getW and fs:GetStringWidth()
    if type(sw) ~= "number" or sw <= maxW then return end
    local keep = math.max(1, math.floor(#str * (maxW / sw)) - 1)
    fs:SetText(string.sub(str, 1, keep) .. "..")
    sw = fs:GetStringWidth()
    if type(sw) == "number" and sw > maxW and keep > 4 then
        fs:SetText(string.sub(str, 1, keep - 3) .. "..")
    end
end

--------------------------------------------------------------------------------
-- category data providers.
-- Each provider(d) -> { title=, rows={ {label,value,valueText,detail,action?,color?}, .. },
--                       accent={r,g,b}, note= }.  value=nil => a FULL bar.

local ACCENT = {
    overview = { 0.80, 0.80, 0.80 },
    spikes   = { 0.90, 0.35, 0.35 },
    cpu      = { 1.00, 0.70, 0.20 },
    events   = { 0.30, 0.75, 0.70 },
    storm    = { 0.90, 0.30, 0.30 },
    memory   = { 0.35, 0.60, 1.00 },
    load     = { 0.70, 0.50, 0.90 },
    matrix   = { 0.55, 0.55, 0.60 },
}

-- Title-case a friendly frame-open label ("auction house" -> "Auction House") for
-- the compact spike-list bar, where the trigger is shown next to the cause.
local function titleCase(s)
    return (tostring(s):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- triggerLabel(sp, code) -> friendly window name ("Auction House") the spike coincided
-- with, or nil. Complementary to the measured cause: names WHAT the owner did. Kept in
-- lockstep with the report's open= field (Report.frameOpenTag) — suppressed when it would
-- only duplicate the sus code (OPEN:) or during a zone-in.
local function triggerLabel(sp, code)
    local tag = ns.Report and ns.Report.frameOpenTag and ns.Report.frameOpenTag(sp)
    if not tag or code == ("OPEN:" .. tag) or code == "ZONE" then return nil end
    local lbl = (ns.Report.FRAMEOPEN_LABEL and ns.Report.FRAMEOPEN_LABEL[tag]) or tag
    return titleCase(lbl)
end

-- broadTrigger(sp, code) -> a friendly probable-trigger label for the spike LIST, or nil.
-- Generalizes triggerLabel past window-opens to the coincident activity (quest update,
-- inventory change, spellcast, ...) via Report.triggerGuess, with a raw-event fallback —
-- so a plain questing ALLOC reads "Heavy churn · Quest Update" instead of a bare cause.
-- Same suppression as the wire trig= (never duplicate the sus OPEN: code or a zone-in).
local function broadTrigger(sp, code)
    if not (ns.Report and ns.Report.triggerGuess) then return nil end
    local tag, _, friendly = ns.Report.triggerGuess(sp)
    if not tag or code == ("OPEN:" .. tag) or code == "ZONE" then return nil end
    return titleCase(friendly or tag)
end

local function spikeDetail(sp, boot)
    local code = ns.Report and ns.Report.classify(sp) or "?"
    local friendly = (ns.Report and ns.Report.suspectLabel) and ns.Report.suspectLabel(code) or code
    local lines = {
        ("Spike #%d — %s ms"):format(sp.index or 0, ms(sp.dt)),
        ("Cause (heuristic): %s  [%s]"):format(friendly, code),
    }
    -- probable-cause prose: what it likely is, and where the profiler is blind, the
    -- concrete next step to name it (the owner's "give probable candidates" ask).
    if ns.Report and ns.Report.explain then
        lines[#lines + 1] = ns.Report.explain(sp)
    end
    -- Frame-open TRIGGER context: names the window this stall coincided with, even
    -- when a measured cause (churn/cleanup/flood/addon) owns the label — the owner's
    -- ask (a Heavy-memory-churn spike that was really the auction-house first open).
    local trig = triggerLabel(sp, code)
    if trig then
        local line = ("Triggered while opening the %s (first open this session — one-time cost, cheap on later opens)."):format(trig)
        if type(sp.events) == "table" then
            for _, e in ipairs(sp.events) do
                if e == "ADDON_LOADED" then
                    line = line .. " An addon also loaded on demand this frame (ADDON_LOADED) — a genuine first-load cost."
                    break
                end
            end
        end
        lines[#lines + 1] = line
    else
        -- No interaction-window open, but name the coincident ACTIVITY as a labeled
        -- guess (quest update / inventory change / spellcast / raw event) — the owner's
        -- ask for the plain questing ALLOC spikes. A correlation, stated as such.
        local gtag, gev, gfriendly = ns.Report and ns.Report.triggerGuess and ns.Report.triggerGuess(sp)
        if gtag and code ~= ("OPEN:" .. gtag) and code ~= "ZONE" then
            lines[#lines + 1] = ("Probable trigger: coincided with %s (a best guess from what happened just before this frame — a correlation, not a measured cause)."):format(gfriendly or gtag)
        end
    end
    if sp.mouseHeld == true then
        lines[#lines + 1] = "Mouse: button held during the frame (window-drag fingerprint)"
    end
    lines[#lines + 1] = ("Heap delta: %s"):format(fmtKB(sp.heapDelta or 0))
    lines[#lines + 1] = ("CLEU rate: %s/s"):format(ms(sp.cleuPS or 0))
    lines[#lines + 1] = ("Combat: %s"):format(sp.inCombat and "yes" or "no")
    lines[#lines + 1] = ("Zone: %s"):format(sp.zone or "?")
    if type(sp.t) == "number" and boot and sp.t < boot then
        lines[#lines + 1] = "NOTE: restored from a prior session (old=1)"
    end
    if type(sp.topCPU) == "table" and sp.topCPU[1] and sp.topCPU[1].name then
        lines[#lines + 1] = ("Attributed CPU: %s = %s ms"):format(sp.topCPU[1].name, ms1(sp.topCPU[1].ms or 0))
    end
    if type(sp.events) == "table" and sp.events[1] then
        lines[#lines + 1] = "Recent events: " .. table.concat(sp.events, ", ")
    end
    if sp.net then
        lines[#lines + 1] = ("Net: in %s / out %s KB/s, world latency %s ms"):format(
            ms1(sp.net.inKB), ms1(sp.net.outKB), ms(sp.net.lat))
    end
    if type(sp.streamN) == "number" and sp.streamN > 0 then
        lines[#lines + 1] = ("New-player loads: %d (models/nameplates streamed in this frame)"):format(sp.streamN)
    end
    return table.concat(lines, "\n")
end

local function pMemory(d)
    local rows, mem = {}, d.mem
    local scanAction = function() if type(api.runMemWalk) == "function" then api.runMemWalk() end; render() end
    local note
    if mem and mem.failed then
        rows[1] = {
            label = "Scan hit the client's memory limit — click to retry",
            value = nil, valueText = "!", color = { 0.9, 0.35, 0.35 },
            detail = "The _G walk exceeded the 32-bit client's memory ('block too big'). The walk is bounded, but this client's _G is very large (pfQuest's pfDB alone is ~262k tables). Per-addon memory via the stock API is also locked (GetAddOnMemoryUsage -> 0). Total Lua heap is shown as a full bar below; retry runs a fresh bounded pass.\n\n" .. tostring(mem.err),
            action = scanAction,
        }
    elseif mem and mem.ranked and mem.ranked[1] then
        for i, w in ipairs(mem.ranked) do
            local kb = (w.bytes or 0) / 1024
            rows[#rows + 1] = {
                label = i .. ". " .. tostring(w.name) .. (w.capped and " (floor)" or ""),
                value = w.bytes or 0,
                valueText = fmtKB(kb),
                detail = ("Global: %s\nEstimated size: %s%s\nTables reached: %d\n\nRough shallow estimate of _G-reachable named state (closure locals invisible; shared subtrees go to the first root)."):format(
                    tostring(w.name), fmtKB(kb), w.capped and "  (a floor — this root hit the per-root cap)" or "", w.nodes or 0),
            }
        end
        if mem.partial then note = "partial estimate — sizes marked (floor) are a lower bound (client too large for a full walk)" end
    else
        rows[1] = {
            label = "Click to scan _G memory (heavy — stalls a moment)",
            value = nil, valueText = "scan",
            detail = "The bounded _G walk estimates per-global Lua memory (the on-contract 'memtables'). It is heavy and on-demand, so it does not run automatically. Click this bar (or the Scan button below) to run it. NOTE per-addon memory via the stock API is locked on Ascension, so this _G-global estimate is the closest available.",
            action = scanAction,
        }
    end
    -- always show the true total Lua heap as a full bar (works even when the walk can't)
    local okHeap, heapVal = pcall(collectgarbage, "count")
    if okHeap and type(heapVal) == "number" then
        rows[#rows + 1] = {
            label = "Total Lua heap (collectgarbage)",
            value = nil, valueText = fmtKB(heapVal), color = { 0.5, 0.5, 0.55 },
            detail = ("Total Lua memory in use: %s.\nThis is the whole client's Lua heap (all addons + the UI), the one aggregate the engine does expose. Per-addon breakdown is locked; the bounded _G walk above is the best available attribution."):format(fmtKB(heapVal)),
        }
    end
    return { title = "Per-global Lua memory (estimate)", rows = rows, accent = ACCENT.memory, note = note }
end

local function pCPU(d)
    local rows, prof = {}, d.profiled or {}
    if prof[1] then
        for i, p in ipairs(prof) do
            rows[#rows + 1] = {
                label = i .. ". " .. tostring(p.tag),
                value = p.ms or 0,
                valueText = ms1(p.ms) .. " ms",
                detail = ("%s\nTotal: %s ms over %d calls\nPer call: %s ms\n\nMeasured via the cooperative ClientPerfProbe library (debugprofilestop) — accurate but only for addons that opt in."):format(
                    tostring(p.tag), ms1(p.ms), p.calls or 0, ms1(p.perMs)),
            }
        end
    else
        rows[1] = {
            label = "No cooperating addons have opted in",
            value = nil, valueText = "",
            detail = "The stock per-addon CPU API (scriptProfile) is locked on Ascension, so per-handler CPU can only be measured for addons that call ClientPerfProbe.Wrap(). None have reported cost yet.",
        }
    end
    return { title = "Per-handler CPU (cooperating addons)", rows = rows, accent = ACCENT.cpu }
end

local function pSpikes(d)
    local rows, spikes = {}, d.spikes or {}
    local boot = (d.meta or {}).boot or 0
    if spikes[1] then
        for _, sp in ipairs(spikes) do
            local code = ns.Report and ns.Report.classify(sp) or "?"
            local stale = (type(sp.t) == "number" and sp.t < boot) and " [old]" or ""
            -- append the probable trigger so a measured-cause spike reads e.g.
            -- "ALLOC · Auction House" or "ALLOC · Quest Update" instead of a bare
            -- "ALLOC" (the owner's ask: name what churn spikes coincided with).
            local trig = broadTrigger(sp, code)
            local trigStr = trig and (" · " .. trig) or ""
            rows[#rows + 1] = {
                label = ("#%d  %s%s%s"):format(sp.index or 0, code, trigStr, stale),
                value = sp.dt or 0,
                valueText = ms(sp.dt) .. " ms",
                detail = spikeDetail(sp, boot),
            }
        end
    else
        rows[1] = { label = "No spikes captured yet", value = nil, valueText = "",
            detail = "Frames over the spike threshold appear here, worst first. Play a bit and check back." }
    end
    return { title = "Frame spikes (worst first)", rows = rows, accent = ACCENT.spikes }
end

local function pEvents(d)
    local rows, rates = {}, d.rates or {}
    if rates[1] then
        for i, e in ipairs(rates) do
            if i > 60 then break end
            rows[#rows + 1] = {
                label = tostring(e.name),
                value = e.count or 0,
                valueText = string.format("%d  (%s/s)", e.count or 0, ms1(e.perSec)),
                detail = ("%s\nCount this run: %d\nRate: %s/s"):format(tostring(e.name), e.count or 0, ms1(e.perSec)),
            }
        end
    else
        rows[1] = { label = "No events counted yet", value = nil, valueText = "", detail = "Event rates (RegisterAllEvents) appear here once the client fires some." }
    end
    return { title = "Event rates (this run)", rows = rows, accent = ACCENT.events }
end

local function pStorm(d)
    local rows, blk = {}, d.blocked or {}
    local st = ns.Storm and type(api.stormInputs) == "function" and ns.Storm.evaluate(api.stormInputs()) or nil
    if blk[1] then
        for i, b in ipairs(blk) do
            rows[#rows + 1] = {
                label = i .. ". " .. tostring(b.addon),
                value = b.count or 0,
                valueText = string.format("%d  (%s/s)", b.count or 0, ms1(b.perSec)),
                detail = ("Addon: %s\nBlocked function: %s\nBlocked %d times (%s/s)\n\nADDON_ACTION_BLOCKED is self-describing: the engine names the addon + the protected call it retried under combat lockdown. A high rate is a taint storm (the live ExadTweaks catch was 45/s)."):format(
                    tostring(b.addon), tostring(b.func), b.count or 0, ms1(b.perSec)),
            }
        end
    else
        rows[1] = { label = "No blocked calls — no taint storm", value = nil, valueText = "clear",
            detail = "A storm is an addon retrying a protected call every frame under combat lockdown. None seen. The minimap button blinks red if one is detected." }
    end
    local note = st and (st.level:upper() .. " — " .. st.reason) or nil
    return { title = "Addon storm (blocked calls)", rows = rows, accent = ACCENT.storm, note = note }
end

local function pLoad(d)
    local rows = {}
    local load = d.load
    if load and load.ranked and load.ranked[1] then
        for i, a in ipairs(load.ranked) do
            rows[#rows + 1] = {
                label = i .. ". " .. tostring(a.name),
                value = a.dMs or 0,
                valueText = ms(a.dMs) .. " ms",
                detail = ("%s\nLoad cost: %s ms\nHeap growth: %s\n\nFrom the serial ADDON_LOADED cascade (debugprofilestop delta) — a per-addon CPU+memory channel available only at load."):format(
                    tostring(a.name), ms(a.dMs), fmtKB(a.dHeapKB or 0)),
            }
        end
    else
        rows[1] = { label = "No load profile captured", value = nil, valueText = "",
            detail = "The initial-load profile is taken once per login. /reload and reopen to capture the ADDON_LOADED cascade." }
    end
    local s = load and load.summary
    local note = s and s.worldMs and ("login+world " .. ms(s.worldMs) .. " ms · " .. (s.addons or 0) .. " addons") or nil
    return { title = "Initial-load cost per addon", rows = rows, accent = ACCENT.load, note = note }
end

local function pMatrix(d)
    local rows, mtx = {}, d.matrix or {}
    if mtx[1] then
        for _, r in ipairs(mtx) do
            local st = r.status or "?"
            local c = (st == "ok") and { 0.4, 0.85, 0.4 } or (st == "missing") and { 0.9, 0.35, 0.35 } or { 0.95, 0.8, 0.2 }
            rows[#rows + 1] = {
                label = tostring(r.name),
                value = nil,                       -- not numeric -> full bar, coloured by status
                valueText = st,
                color = c,
                detail = ("%s\nStatus: %s\n%s"):format(tostring(r.name), st, r.detail ~= "" and r.detail or "(no detail)"),
            }
        end
    else
        rows[1] = { label = "Matrix unavailable", value = nil, valueText = "", detail = "The API feature-detection matrix could not be built." }
    end
    return { title = "API support matrix", rows = rows, accent = ACCENT.matrix }
end

local function pOverview(d)
    local m = d.meta or {}
    local rows = {}
    local function fact(label, value, detail)
        rows[#rows + 1] = { label = label, value = nil, valueText = value or "", detail = detail or (label .. ": " .. tostring(value)) }
    end
    local st = ns.Storm and type(api.stormInputs) == "function" and ns.Storm.evaluate(api.stormInputs()) or nil
    fact("Character", (m.char or "?") .. " — " .. (m.realm or "?"))
    fact("Zone", m.zone or "?")
    fact("Run length", (m.windowSec or "?") .. " s")
    fact("Attribution", m.attr or "none", "Which per-addon attribution the stock APIs give. 'none' on Ascension — scriptProfile + GetAddOnMemoryUsage are locked; cooperating addons still self-report CPU.")
    if st then fact("Status", st.reason, "Storm monitor: " .. st.level:upper() .. ". " .. st.reason) end
    local spikes = d.spikes or {}
    local worst
    for _, sp in ipairs(spikes) do if not worst or (sp.dt or 0) > (worst.dt or 0) then worst = sp end end
    fact("Spikes captured", tostring(m.totalSpikes or 0))
    if worst then fact("Worst spike", ms(worst.dt) .. " ms  (" .. (ns.Report and ns.Report.classify(worst) or "?") .. ")", spikeDetail(worst, m.boot or 0)) end
    local okHeap, heapVal = pcall(collectgarbage, "count")
    if okHeap and type(heapVal) == "number" then fact("Lua heap", fmtKB(heapVal)) end
    local prof = d.profiled or {}
    if prof[1] then fact("Top CPU", tostring(prof[1].tag) .. "  " .. ms1(prof[1].ms) .. " ms") end
    return { title = "Overview", rows = rows, accent = ACCENT.overview }
end

-- category registry (order = dropdown order); default lands on Spikes (see currentCat).
-- Labels are kept short so the top header stays compact even at a tiny window width.
-- `hidden = true` entries keep their provider (still reachable via UI.Select, e.g. the
-- sim) but are omitted from the dropdown — flip the flag to bring one back.
local CATS = {
    { id = "spikes",   label = "Spikes",    provider = pSpikes   },
    { id = "events",   label = "Events",    provider = pEvents   },
    { id = "storm",    label = "Storm",     provider = pStorm    },
    { id = "load",     label = "Load Time", provider = pLoad     },
    { id = "memory",   label = "Memory",    provider = pMemory   },
    { id = "cpu",      label = "CPU",      provider = pCPU,      hidden = true },
    { id = "matrix",   label = "Matrix",   provider = pMatrix,   hidden = true },
    { id = "overview", label = "Overview", provider = pOverview, hidden = true },
}

local function catById(id)
    for _, c in ipairs(CATS) do if c.id == id then return c end end
    return CATS[1]
end

--------------------------------------------------------------------------------
-- poll control

local function pollBadge()
    return (refreshSec > 0) and tostring(refreshSec) or "x"   -- "x" = Off (manual only)
end

local function setPoll(sec)
    refreshSec = sec
    refreshAccum = 0
    if db then
        if type(db.ui) ~= "table" then db.ui = {} end
        db.ui.refreshSec = sec
    end
    if frame and frame.pollBtn and frame.pollBtn.badge then frame.pollBtn.badge:SetText(pollBadge()) end
end

--------------------------------------------------------------------------------
-- bar rows (pooled)

local function acquireRow(i)
    local rows = frame.rows
    if rows[i] then return rows[i] end
    local content = frame.contentFrame
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    bg:SetPoint("TOPLEFT", 0, -1)
    bg:SetPoint("BOTTOMRIGHT", 0, 1)
    bg:SetVertexColor(0.10, 0.10, 0.10, 0.85)
    row.bg = bg

    local fill = row:CreateTexture(nil, "ARTWORK")
    fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    fill:SetPoint("TOPLEFT", 0, -1)
    fill:SetPoint("BOTTOMLEFT", 0, 1)
    fill:SetWidth(1)
    row.fill = fill

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", 6, 0)
    name:SetJustifyH("LEFT")
    row.nameFS = name

    local value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    value:SetPoint("RIGHT", -8, 0)
    value:SetJustifyH("RIGHT")
    row.valueFS = value

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local ht = row:GetHighlightTexture(); if ht then ht:SetAlpha(0.25) end

    row:SetScript("OnClick", function(self)
        if type(self._action) == "function" then self._action()
        elseif self._detail then showDetail(self._title, self._detail) end
    end)

    rows[i] = row
    return row
end

--------------------------------------------------------------------------------
-- render

render = function()
    if not (frame and frame:IsShown()) then return end
    local cat = catById(currentCat)
    local d = (type(api.snapshot) == "function") and api.snapshot(currentCat == "matrix") or {}

    local ok, res = pcall(cat.provider, d)
    if not ok or type(res) ~= "table" then
        res = { title = "render error", rows = { { label = "render error: " .. tostring(res), value = nil, valueText = "" } }, accent = { 1, 0.3, 0.3 } }
    end
    local rows = res.rows or {}
    local accent = res.accent or { 0.5, 0.5, 0.9 }

    -- top-left category header + optional status note
    if frame.catMenuBtn and frame.catMenuBtn.textFS then
        frame.catMenuBtn.textFS:SetText(cat.label .. "  |cffffd200v|r")
    end
    frame.viewNote:SetText(res.note and ("|cffff8800" .. res.note .. "|r") or "")
    if frame.pollBtn and frame.pollBtn.badge then frame.pollBtn.badge:SetText(pollBadge()) end

    -- max value for bar scaling (numeric rows only)
    local maxV = 0
    for _, r in ipairs(rows) do if type(r.value) == "number" and r.value > maxV then maxV = r.value end end
    if maxV <= 0 then maxV = 1 end

    -- available width for a bar
    local w = frame.scroll and frame.scroll:GetWidth()
    if type(w) ~= "number" or w <= 0 then w = (frame:GetWidth() or 800) - 60 end
    if frame.contentFrame then frame.contentFrame:SetWidth(w) end

    local textLines = { res.title or "" }
    for i, r in ipairs(rows) do
        local row = acquireRow(i)
        row:SetWidth(w)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H)

        local frac
        if type(r.value) == "number" then
            frac = r.value / maxV
            if frac < 0.03 then frac = 0.03 elseif frac > 1 then frac = 1 end
        else
            frac = 1                                   -- non-numeric => full bar
        end
        row.fill:SetWidth(math.max(1, frac * w))
        local c = r.color or accent
        row.fill:SetVertexColor(c[1], c[2], c[3], 0.85)

        -- value on the right (short); name on the left, TRUNCATED to one line to fit
        -- the space the value leaves — so a tiny window collapses names, never wraps.
        row.valueFS:SetText(r.valueText or "")
        local getVW = row.valueFS.GetStringWidth
        local vW = getVW and row.valueFS:GetStringWidth()
        local avail = w - ((type(vW) == "number") and vW or 0) - 18
        fitText(row.nameFS, r.label or "", avail)
        row._detail = r.detail
        row._title = r.label
        row._action = r.action
        row:Show()

        textLines[#textLines + 1] = (r.label or "") .. "  " .. (r.valueText or "")
    end
    -- hide unused pooled rows
    for i = #rows + 1, #frame.rows do frame.rows[i]:Hide() end

    if frame.contentFrame then frame.contentFrame:SetHeight(math.max(1, #rows * ROW_H + 4)) end
    lastRenderText = table.concat(textLines, "\n")

    if frame.scanBtn then
        if currentCat == "memory" then frame.scanBtn:Show() else frame.scanBtn:Hide() end
    end
end

selectCat = function(id)
    currentCat = id
    if frame and frame.catMenu then frame.catMenu:Hide() end
    render()
end

--------------------------------------------------------------------------------
-- detail popup

showDetail = function(title, text)
    if not detailFrame then
        local f = CreateFrame("Frame", "ClientPerfProbeDetail", UIParent)
        f:SetSize(420, 260)
        f:SetPoint("CENTER")
        -- No SetToplevel: a toplevel frame re-raises on every click/drag, and each
        -- raise restacks the strata (~50ms even on sparse FULLSCREEN_DIALOG) — a
        -- repeatable per-drag spike (management/docs/DRAG-FREEZE.md). Singleton popup, so
        -- click-to-raise is unused; showDetail() calls Raise() once instead.
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        darkBackdrop(f)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        t:SetPoint("TOPLEFT", 16, -14)
        t:SetPoint("TOPRIGHT", -16, -14)
        t:SetJustifyH("LEFT")
        f.titleFS = t

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)

        local scroll = CreateFrame("ScrollFrame", "ClientPerfProbeDetailScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -40)
        scroll:SetPoint("BOTTOMRIGHT", -34, 16)
        local body = CreateFrame("Frame", nil, scroll)
        body:SetSize(360, 10)
        local fs = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 0, 0)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetWidth(360)
        scroll:SetScrollChild(body)
        f.bodyFS = fs
        f.bodyFrame = body
        f.scroll = scroll
        detailFrame = f
    end
    detailFrame.titleFS:SetText(title or "Detail")
    detailFrame.bodyFS:SetText(text or "")
    local w = detailFrame.scroll:GetWidth()
    if type(w) == "number" and w > 0 then detailFrame.bodyFS:SetWidth(w) end
    local h = detailFrame.bodyFS:GetStringHeight()
    if type(h) == "number" and h > 0 then detailFrame.bodyFrame:SetHeight(h + 8) end
    detailFrame:Show()
    detailFrame:Raise()   -- front-of-strata on open; replaces the dropped SetToplevel
end

--------------------------------------------------------------------------------
-- glossary popup — a plain-English guide to the cause labels + the per-stutter
-- numbers (the owner asked for friendly names with longer descriptions, and to
-- flip to the technical "how it's derived" view on click). A new toolbar button
-- opens it. Content is PURE DATA from Report.GLOSSARY, so the names stay in sync
-- with the classifier and the whole thing is testable offline.

local glossaryFrame
local lastGlossaryText = ""
local buildGlossary, layoutGlossaryList, showGlossaryDetail   -- forward decls

local function glossaryEntries()
    return (ns.Report and ns.Report.glossary and ns.Report.glossary()) or {}
end

-- pooled group-header FontString
local function gHeader(i)
    local pool = glossaryFrame.headers
    if pool[i] then return pool[i] end
    local fs = glossaryFrame.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(1, 0.82, 0)
    pool[i] = fs
    return fs
end

-- pooled entry button: a friendly term line over a wrapped plain-English blurb;
-- clicking it flips the SAME window to that term's technical detail.
local function gEntry(i)
    local pool = glossaryFrame.entries
    if pool[i] then return pool[i] end
    local b = CreateFrame("Button", nil, glossaryFrame.content)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local ht = b:GetHighlightTexture(); if ht then ht:SetAlpha(0.20) end
    local term = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    term:SetPoint("TOPLEFT", 4, -2)
    term:SetJustifyH("LEFT")
    term:SetTextColor(0.60, 0.85, 1.00)
    b.termFS = term
    local desc = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", term, "BOTTOMLEFT", 0, -2)
    desc:SetJustifyH("LEFT")
    desc:SetTextColor(0.80, 0.80, 0.80)
    b.descFS = desc
    -- the spike-list code/abbreviation (sus= code for causes, field name for the
    -- numbers), right-aligned on the term line, in white CAPS.
    local code = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    code:SetPoint("TOPRIGHT", -6, -2)
    code:SetJustifyH("RIGHT")
    code:SetTextColor(1, 1, 1)
    b.codeFS = code
    b:SetScript("OnClick", function(self)
        if self._entry then showGlossaryDetail(self._entry) end
    end)
    pool[i] = b
    return b
end

-- list mode: friendly name + short description per entry, grouped by section.
layoutGlossaryList = function()
    if not glossaryFrame then return end
    local entries = glossaryEntries()
    local w = glossaryFrame.scroll and glossaryFrame.scroll:GetWidth()
    if type(w) ~= "number" or w <= 0 then w = 400 end
    glossaryFrame.content:SetWidth(w)
    glossaryFrame.backBtn:Hide()
    glossaryFrame.detailFS:Hide()
    glossaryFrame.titleFS:SetText("Guide — what the numbers mean (click a term for detail)")

    local textLines, y, hi, ei, lastGroup = {}, 0, 0, 0, nil
    local descW = w - 16
    for _, g in ipairs(entries) do
        if g.group ~= lastGroup then
            lastGroup = g.group
            hi = hi + 1
            local hfs = gHeader(hi)
            hfs:ClearAllPoints()
            hfs:SetPoint("TOPLEFT", 2, -y)
            hfs:SetPoint("TOPRIGHT", -2, -y)
            hfs:SetText(g.group or "")
            hfs:Show()
            y = y + 22
            textLines[#textLines + 1] = "== " .. (g.group or "") .. " =="
        end
        ei = ei + 1
        local b = gEntry(ei)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 0, -y)
        b:SetPoint("TOPRIGHT", 0, -y)
        b._entry = g
        b.termFS:SetText(g.term or "")
        local codeTxt = g.code or g.field
        if codeTxt and codeTxt ~= "" then
            b.codeFS:SetText(string.upper(codeTxt))
            b.codeFS:Show()
        else
            b.codeFS:SetText("")
            b.codeFS:Hide()
        end
        b.descFS:SetWidth(descW)
        b.descFS:SetText(g.plain or "")
        local dh = b.descFS.GetStringHeight and b.descFS:GetStringHeight()
        if type(dh) ~= "number" or dh <= 0 then dh = 40 end   -- offline fallback
        local bh = 16 + dh + 8
        b:SetHeight(bh)
        b:Show()
        y = y + bh + 3
        textLines[#textLines + 1] = (g.term or "") .. " — " .. (g.plain or "")
    end
    for i = hi + 1, #glossaryFrame.headers do glossaryFrame.headers[i]:Hide() end
    for i = ei + 1, #glossaryFrame.entries do glossaryFrame.entries[i]:Hide() end
    glossaryFrame.content:SetHeight(math.max(1, y + 4))
    lastGlossaryText = table.concat(textLines, "\n")
end

-- detail mode: the same window shows the clicked term's meaning + how it's derived.
showGlossaryDetail = function(entry)
    if not (glossaryFrame and entry) then return end
    for _, b in ipairs(glossaryFrame.entries) do b:Hide() end
    for _, h in ipairs(glossaryFrame.headers) do h:Hide() end
    glossaryFrame.backBtn:Show()
    glossaryFrame.titleFS:SetText(entry.term or "Detail")
    local w = glossaryFrame.scroll and glossaryFrame.scroll:GetWidth()
    if type(w) ~= "number" or w <= 0 then w = 400 end
    glossaryFrame.content:SetWidth(w)
    local body = ("%s\n\n%s\n\n|cffffd200How it's measured:|r\n%s"):format(
        entry.term or "", entry.plain or "", entry.tech or "")
    local fs = glossaryFrame.detailFS
    fs:SetWidth(w - 8)
    fs:SetText(body)
    fs:Show()
    local h = fs.GetStringHeight and fs:GetStringHeight()
    if type(h) ~= "number" or h <= 0 then h = 220 end
    glossaryFrame.content:SetHeight(h + 12)
    -- plain-text mirror for the sim: term + plain + tech (no color codes)
    lastGlossaryText = ("%s\n\n%s\n\nHow it's measured:\n%s"):format(
        entry.term or "", entry.plain or "", entry.tech or "")
end

buildGlossary = function()
    local f = CreateFrame("Frame", "ClientPerfProbeGuide", UIParent)
    f:SetSize(480, 470)
    f:SetPoint("CENTER")
    -- No SetToplevel: it would re-raise (and restack the strata) on every drag.
    -- Singleton popup — UI.ShowGlossary() calls Raise() once instead. See
    -- management/docs/DRAG-FREEZE.md.
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    darkBackdrop(f)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.headers = {}
    f.entries = {}

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("TOPLEFT", 16, -14)
    t:SetPoint("TOPRIGHT", -40, -14)
    t:SetJustifyH("LEFT")
    f.titleFS = t

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local back = CreateFrame("Button", nil, f)
    back:SetSize(130, 18)
    back:SetPoint("TOPLEFT", 12, -32)
    local bfs = back:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bfs:SetPoint("LEFT", 2, 0)
    bfs:SetText("|cffffd200< Back to guide|r")
    back:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    back:SetScript("OnClick", function() layoutGlossaryList() end)
    back:Hide()
    f.backBtn = back

    local scroll = CreateFrame("ScrollFrame", "ClientPerfProbeGuideScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -52)
    scroll:SetPoint("BOTTOMRIGHT", -34, 14)
    f.scroll = scroll
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(420, 10)
    scroll:SetScrollChild(content)
    f.content = content
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local sb = _G["ClientPerfProbeGuideScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - (delta or 0) * 40) end
    end)

    -- single body FontString reused for the technical detail view
    local dfs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dfs:SetPoint("TOPLEFT", 4, -2)
    dfs:SetPoint("TOPRIGHT", -4, -2)
    dfs:SetJustifyH("LEFT")
    dfs:SetJustifyV("TOP")
    dfs:Hide()
    f.detailFS = dfs

    glossaryFrame = f
end

--------------------------------------------------------------------------------
-- construction

local function saveGeom()
    if not (db and frame) then return end
    if type(db.ui) ~= "table" then db.ui = {} end
    db.ui.width = frame:GetWidth()
    db.ui.height = frame:GetHeight()
    local point, _, relPoint, x, y = frame:GetPoint()
    db.ui.point, db.ui.relPoint, db.ui.x, db.ui.y = point, relPoint, x, y
end

-- Persist the open/closed toggle so the window reappears (or stays closed) across
-- /reload and re-login. Only the explicit Show/Hide paths write it — NOT the OnHide
-- teardown that fires when the client tears frames down on reload — so a reload while
-- open is remembered as "open". Restored in UI.init.
local function saveShown(v)
    if not db then return end
    if type(db.ui) ~= "table" then db.ui = {} end
    db.ui.shown = v and true or false
end

-- small icon button (top-right toolbar, Details-style). tip = {title, line1, ...}
local function makeIconButton(tex, coords, tip, onClick)
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(ICON, ICON)
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetTexture(tex)
    if coords then t:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) end
    t:SetAllPoints(b)
    b.tex = t
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", function(self)
        if not GameTooltip or not tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        for i, line in ipairs(tip) do
            if i == 1 then GameTooltip:AddLine(line) else GameTooltip:AddLine(line, 0.85, 0.85, 0.85) end
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:SetScript("OnClick", onClick)
    return b
end

-- A small Details-style dropdown menu, anchored under a toolbar button. Every menu
-- built here is registered so opening one (or hiding the window) closes the others.
--   items = { { label=, check=fn|nil, onClick=fn, sep=bool }, ... }
--     check : fn()->bool — shows a checkmark on the active row (re-read on open)
--     sep   : draw a divider line above this row (groups actions, e.g. "Close window")
-- Selecting any row runs its onClick and closes the menu immediately.
local ALL_MENUS = {}

local function closeMenus(except)
    for _, m in ipairs(ALL_MENUS) do if m ~= except then m:Hide() end end
    if frame and frame.catMenu and frame.catMenu ~= except then frame.catMenu:Hide() end
end

local function makeMenu(menuName, items)
    local menu = CreateFrame("Frame", menuName, frame)
    -- FULLSCREEN_DIALOG puts the menu above the LOW-strata main window by strata
    -- alone, so SetToplevel adds nothing — and it would restack the strata on
    -- every click. closeMenus() keeps only one menu open at a time, so there is
    -- no sibling to raise above and no Raise() is needed. See
    -- management/docs/DRAG-FREEZE.md.
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    darkBackdrop(menu)
    menu:SetWidth(156)
    menu:Hide()
    menu.rows = {}

    local prev, h = nil, 6
    for _, item in ipairs(items) do
        local gap = item.sep and 8 or 1
        local mb = CreateFrame("Button", nil, menu)
        mb:SetHeight(20)
        mb:SetPoint("LEFT", 6, 0)
        mb:SetPoint("RIGHT", -6, 0)
        if prev then mb:SetPoint("TOP", prev, "BOTTOM", 0, -gap)
        else mb:SetPoint("TOP", 0, -6) end
        h = h + 20 + gap
        mb:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local ht = mb:GetHighlightTexture(); if ht then ht:SetAlpha(0.4) end

        if item.sep then
            local ln = menu:CreateTexture(nil, "ARTWORK")
            ln:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
            ln:SetVertexColor(0.5, 0.5, 0.5, 0.7)
            ln:SetHeight(1)
            ln:SetPoint("BOTTOMLEFT", mb, "TOPLEFT", 2, 4)
            ln:SetPoint("BOTTOMRIGHT", mb, "TOPRIGHT", -2, 4)
        end

        local chk = mb:CreateTexture(nil, "ARTWORK")
        chk:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        chk:SetWidth(16); chk:SetHeight(16)
        chk:SetPoint("LEFT", 0, 0)
        chk:Hide()
        mb.checkTex = chk
        mb.checkFn = item.check

        local txt = mb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        txt:SetPoint("LEFT", 18, 0)
        txt:SetJustifyH("LEFT")
        txt:SetText(item.label)

        mb:SetScript("OnClick", function()
            if type(item.onClick) == "function" then item.onClick() end
            menu:Hide()
        end)
        menu.rows[#menu.rows + 1] = mb
        prev = mb
    end
    menu:SetHeight(h + 6)

    -- re-read the checkmarks each time the menu opens (which row is active can change)
    menu:SetScript("OnShow", function(self)
        for _, mb in ipairs(self.rows) do
            if mb.checkFn and mb.checkFn() then mb.checkTex:Show() else mb.checkTex:Hide() end
        end
    end)

    ALL_MENUS[#ALL_MENUS + 1] = menu
    return menu
end

-- toggle a menu open/closed, dropping it down from the right edge of its button.
local function toggleMenu(menu, anchor)
    if not menu then return end
    if menu:IsShown() then menu:Hide(); return end
    closeMenus(menu)
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 2, -2)
    menu:Show()
end

-- the top-left category header — a clean clickable text label (no button chrome)
-- that also opens the category menu, Details-style.
local function buildDropdown()
    local btn = CreateFrame("Button", nil, frame)
    btn:SetSize(112, 18)     -- narrow: covers the short label only, clear of the icons
    btn:SetPoint("TOPLEFT", 10, -7)
    local htx = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    htx:SetPoint("LEFT", 2, 0)
    htx:SetJustifyH("LEFT")
    htx:SetText("Memory  |cffffd200v|r")
    btn.textFS = htx
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local bht = btn:GetHighlightTexture(); if bht then bht:SetAlpha(0.35) end
    frame.catMenuBtn = btn

    local menu = CreateFrame("Frame", "ClientPerfProbeUIMenu", frame)
    -- No SetToplevel — same reasoning as makeMenu() above: strata alone already
    -- lifts it over the LOW main window, and the flag would restack per click.
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    darkBackdrop(menu)
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(130)
    local nVis = 0
    for _, cat in ipairs(CATS) do if not cat.hidden then nVis = nVis + 1 end end
    menu:SetHeight(nVis * 20 + 12)
    menu:Hide()
    frame.catMenu = menu

    local prev
    for _, cat in ipairs(CATS) do
        if not cat.hidden then
        local mb = CreateFrame("Button", nil, menu)
        mb:SetHeight(20)
        mb:SetPoint("LEFT", 8, 0)
        mb:SetPoint("RIGHT", -8, 0)
        if prev then mb:SetPoint("TOP", prev, "BOTTOM", 0, -1)
        else mb:SetPoint("TOP", 0, -6) end
        mb:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local ht = mb:GetHighlightTexture(); if ht then ht:SetAlpha(0.4) end
        local txt = mb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        txt:SetPoint("LEFT", 4, 0)
        txt:SetText(cat.label)
        mb:SetScript("OnClick", function() selectCat(cat.id) end)
        prev = mb
        end
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide() else closeMenus(menu); menu:Show() end
    end)
end

local function build()
    frame = CreateFrame("Frame", "ClientPerfProbeUI", UIParent)
    frame.rows = {}
    frame:SetSize(420, 300)     -- compact, ~Details main-meter size; resizable
    if db and type(db.ui) == "table" and db.ui.width then
        frame:SetSize(math.max(360, db.ui.width), math.max(200, db.ui.height or 300))
    end
    frame:SetPoint("CENTER")
    if db and type(db.ui) == "table" and db.ui.point then
        frame:ClearAllPoints()
        frame:SetPoint(db.ui.point, UIParent, db.ui.relPoint or db.ui.point, db.ui.x or 0, db.ui.y or 0)
    end
    -- Strata LOW so the meter sits BEHIND the interaction panels (character
    -- panel, world map, bags, etc.) instead of on top of everything — LOW is
    -- below MEDIUM/HIGH/DIALOG/FULLSCREEN yet still above the 3D world (WORLD),
    -- so the window renders over the game but under the panels.
    -- No SetToplevel: that + a populated strata is the confirmed drag-freeze
    -- (variant A, management/docs/DRAG-FREEZE.md); without it any strata is spike-free
    -- (variant B). A one-time Raise() on open (UI.Show) only orders it among
    -- LOW siblings — it cannot cross strata, so the window stays under the panels.
    frame:SetFrameStrata("LOW")
    darkBackdrop(frame)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetMinResize then frame:SetMinResize(240, 140) end
    if frame.SetMaxResize then frame:SetMaxResize(1400, 1000) end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); saveGeom() end)
    frame:SetScript("OnHide", function() saveGeom(); closeMenus() end)
    frame:Hide()

    -- menus wired below; forward-declared so the button click handlers can capture them
    local pollMenu, clearMenu

    -- The red X is now a MENU (Details-style): time-scoped clears + Close window.
    -- Its own OnClick opens the menu; "Close window" inside the menu hides the frame.
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() toggleMenu(clearMenu, close) end)
    close:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Menu")
        GameTooltip:AddLine("Clear captured spikes by age, or close the window.", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    close:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    buildDropdown()   -- top-left category header (also the category menu trigger)

    -- top-right icon toolbar (Details-style), laid out right-to-left before the close.
    -- Poll opens a checkmark menu (active rate ticked); selecting a rate closes it.
    local iconPoll = makeIconButton("Interface\\Buttons\\UI-RefreshButton", nil,
        { "Live refresh rate", "Pick Off / 1 / 2 / 5 / 10 s (a check marks the active one).", "Refreshing rebuilds the report (a frame cost);", "slower or Off keeps the window cheap." },
        function() toggleMenu(pollMenu, frame.pollBtn) end)
    iconPoll:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -29, -8)
    local badge = iconPoll:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    badge:SetPoint("BOTTOMRIGHT", 2, -1)
    iconPoll.badge = badge
    frame.pollBtn = iconPoll

    local iconExport = makeIconButton("Interface\\Buttons\\UI-GuildButton-PublicNote-Up", nil,
        { "Export report", "Open the copy/paste window (Ctrl+C relay)." },
        function() if type(api.openReport) == "function" then api.openReport() end end)
    iconExport:SetPoint("RIGHT", iconPoll, "LEFT", -3, 0)

    -- Guide: a plain-English glossary of the cause labels + the per-stutter numbers,
    -- with a technical "how it's derived" view on click (the owner's ask).
    local iconGuide = makeIconButton("Interface\\Icons\\INV_Misc_Book_09", { 0.08, 0.92, 0.08, 0.92 },
        { "Guide", "Plain-English guide to the causes + numbers.", "Click a term for how it's measured." },
        function() UI.ShowGlossary() end)
    iconGuide:SetPoint("RIGHT", iconExport, "LEFT", -3, 0)

    local iconScan = makeIconButton("Interface\\Icons\\INV_Misc_Spyglass_03", { 0.08, 0.92, 0.08, 0.92 },
        { "Scan _G memory", "Run the bounded memory walk (heavy)." },
        function() if type(api.runMemWalk) == "function" then api.runMemWalk() end; render() end)
    iconScan:SetPoint("RIGHT", iconGuide, "LEFT", -3, 0)
    iconScan:Hide()
    frame.scanBtn = iconScan

    -- poll menu: one row per rate, active rate checkmarked; selecting closes the menu
    local pollItems = {}
    for _, v in ipairs(POLL_OPTIONS) do
        pollItems[#pollItems + 1] = {
            label = (v == 0) and "Off (manual)" or (v .. " s"),
            check = function() return refreshSec == v end,
            onClick = function() setPoll(v); render() end,
        }
    end
    pollMenu = makeMenu("ClientPerfProbeUIPollMenu", pollItems)

    -- clear menu: time-scoped clears (spikes only) + full clear + Close window.
    -- Time-scoped clears trim the spike ring; only "everything" also resets counters.
    local function clearSince(mins)
        if type(api.clearSince) == "function" then api.clearSince(mins)
        elseif type(api.clear) == "function" then api.clear() end
        render()
    end
    clearMenu = makeMenu("ClientPerfProbeUIClearMenu", {
        { label = "Clear last 30 min", onClick = function() clearSince(30) end },
        { label = "Clear last 10 min", onClick = function() clearSince(10) end },
        { label = "Clear last 5 min",  onClick = function() clearSince(5) end },
        { label = "Clear everything",  onClick = function() if type(api.clear) == "function" then api.clear() end; render() end },
        { label = "Close window", sep = true, onClick = function() UI.Hide() end },
    })

    -- current-view status note (under the header, left)
    local vn = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    vn:SetPoint("TOPLEFT", frame.catMenuBtn, "BOTTOMLEFT", 2, 0)
    vn:SetPoint("RIGHT", -12, 0)
    vn:SetJustifyH("LEFT")
    vn:SetHeight(10)
    frame.viewNote = vn

    -- bar list
    local scroll = CreateFrame("ScrollFrame", "ClientPerfProbeUIScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -40)
    scroll:SetPoint("BOTTOMRIGHT", -28, 10)
    frame.scroll = scroll
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(760, 10)
    scroll:SetScrollChild(content)
    frame.contentFrame = content
    -- mouse-wheel scrolling (the template ships a scrollbar but no wheel handler)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local sb = _G["ClientPerfProbeUIScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - (delta or 0) * ROW_H * 2) end
    end)

    -- resize grip
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); saveGeom(); render() end)

    -- throttled live refresh while shown; skipped entirely when polling is Off
    frame:SetScript("OnUpdate", function(self, elapsed)
        if refreshSec <= 0 then return end
        refreshAccum = refreshAccum + (elapsed or 0)
        if refreshAccum >= refreshSec then refreshAccum = 0; render() end
    end)
end

--------------------------------------------------------------------------------
-- public

function UI.init(database, callbacks)
    db = database
    api = callbacks or {}
    if db and type(db.ui) == "table" and type(db.ui.refreshSec) == "number" then
        refreshSec = db.ui.refreshSec
    end
    -- Restore the toggle state: if the window was open when the session last ended
    -- or reloaded, reopen it now (build() restores its saved position + size). Runs
    -- at the probe's ADDON_LOADED, where SavedVariables are already available.
    if db and type(db.ui) == "table" and db.ui.shown then
        UI.Show()
    end
end

function UI.Show()
    if not frame then build() end
    frame:Show()
    frame:Raise()   -- orders it among LOW siblings only (cannot cross strata); no SetToplevel per-drag restack (DRAG-FREEZE.md)
    saveShown(true)
    render()
end

function UI.Hide() saveShown(false); if frame then frame:Hide() end end
function UI.Toggle() if frame and frame:IsShown() then UI.Hide() else UI.Show() end end
function UI.IsShown() return frame and frame:IsShown() and true or false end

-- Select a category by id (also used by the offline sim to exercise each provider).
function UI.Select(id) if frame then selectCat(id) end end

-- Open the plain-English guide/glossary popup (also bound to the toolbar Guide icon).
function UI.ShowGlossary()
    if not glossaryFrame then buildGlossary() end
    glossaryFrame:Show()
    glossaryFrame:Raise()   -- front-of-strata on open; replaces the dropped SetToplevel
    layoutGlossaryList()
end

-- Test hooks: the guide's current text mirror, and a way to drive the click-to-detail
-- flip offline (the sim exercises both the list and the technical view).
function UI.__glossaryText() return lastGlossaryText end
function UI.__glossaryClick(i)
    local e = glossaryEntries()[i]
    if e then showGlossaryDetail(e) end
end

-- Live refresh rate (seconds; 0 = off). Exposed so the value is scriptable/testable.
function UI.SetPoll(sec) setPoll(tonumber(sec) or 0); render() end
function UI.GetPoll() return refreshSec end

-- Test hook: plain-text mirror of the current view (for the offline sim).
function UI.__text() return lastRenderText end

ns.UI = UI

return ns.UI
