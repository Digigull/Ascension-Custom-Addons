--[[ Minimap.lua — the minimap button + addon-storm blink notifier.

     Left-click  : toggle the main UI window (UI.lua).
     Right-click : open the copy/paste export report (the definition-of-done relay).
     Drag        : reposition around the minimap ring (angle saved in SavedVariables).

     The button also carries the storm notifier the owner asked for: a throttled
     tick (NOT the render hot path — see README §4) re-samples the live blocked-event
     rate + recent spike stats, runs the PURE Storm.evaluate, and blinks a red
     overlay when a taint storm ("like Exad had") is detected. Quiet the rest of the
     time; a steady tint marks the lesser "watch" level.

     WoW-facing; syntax-checked only. All decision logic is in Storm.lua (pure/tested).
     Frame construction is deferred to init() (called from Core after ADDON_LOADED),
     so this file makes no WoW calls at load — the syntax gate stays meaningful.

     NOTE: the module table is `MB`, never `Minimap` — `Minimap` is the WoW global
     minimap frame this button anchors to; shadowing it would break positioning.
]]

local ADDON, ns = ...

local MB = {}

local RADIUS   = 80          -- distance from minimap centre to the button
local ICON     = "Interface\\Icons\\INV_Misc_PocketWatch_01"   -- a clock: fits a perf/timing probe
local ICON_STORM = "Interface\\Icons\\Spell_Fire_SelfDestruct" -- swapped in while a storm blinks

local button                 -- the Button frame
local api = {}               -- callbacks wired by Core: toggleUI, openReport, stormInputs
local db                     -- ClientPerfProbeDB (for saved angle / enable)
local dragging = false
local blinkPhase = 0         -- accumulates while a storm blinks (fades the overlay)
local sampleAccum = 0        -- seconds toward the next storm re-evaluation
local lastLevel = "none"
local lastReason = "No spikes detected"

local SAMPLE_SEC = 1.0       -- storm re-evaluation cadence (cheap; off the render path)

--------------------------------------------------------------------------------
-- position on the ring

local function saveAngle(a)
    if not db then return end
    if type(db.minimap) ~= "table" then db.minimap = {} end
    db.minimap.angle = a
end

local function getAngle()
    if db and type(db.minimap) == "table" and type(db.minimap.angle) == "number" then
        return db.minimap.angle
    end
    return 200   -- lower-left by default: clear of the tracking/clock corners
end

local function updatePosition(angle)
    if not button then return end
    local rad = math.rad(angle)
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * RADIUS, math.sin(rad) * RADIUS)
end

-- while dragging, follow the cursor: convert its offset from the minimap centre
-- into a ring angle. Standard LibDBIcon-style math, scaled by the UI.
local function dragTick()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    if not (mx and my and scale and cx and cy) then return end
    cx, cy = cx / scale, cy / scale
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    updatePosition(angle)
    saveAngle(angle)
end

--------------------------------------------------------------------------------
-- storm notifier (throttled — off the hot path)

local function stormSample()
    local inputs = (type(api.stormInputs) == "function") and api.stormInputs() or nil
    local res = ns.Storm and ns.Storm.evaluate(inputs) or { level = "none", blink = false, reason = "" }
    lastLevel = res.level
    lastReason = res.reason or ""

    -- colour the icon border by level; swap to the alarm icon only during a storm.
    local border = button and button.border
    if res.level == "storm" then
        if button.icon then button.icon:SetTexture(ICON_STORM) end
        if border then border:SetVertexColor(1, 0.2, 0.2) end
    elseif res.level == "watch" then
        if button.icon then button.icon:SetTexture(ICON) end
        if border then border:SetVertexColor(1, 0.82, 0) end
    else
        if button.icon then button.icon:SetTexture(ICON) end
        if border then border:SetVertexColor(1, 1, 1) end
    end

    if not res.blink and button and button.alarm then
        button.alarm:Hide()          -- storm cleared: stop blinking
        blinkPhase = 0
    end

    -- refresh a hovering tooltip so the reason updates live
    if button and GameTooltip and GameTooltip:IsOwned(button) then
        MB.showTooltip()
    end
end

-- the button's own throttled OnUpdate: re-evaluate the storm ~1/s and animate the
-- blink. Cheap and constant; it never scans addons or walks tables (that stays on
-- explicit /cpp commands). Runs only while the button is shown.
local function onUpdate(self, elapsed)
    if dragging then dragTick() end

    sampleAccum = sampleAccum + (elapsed or 0)
    if sampleAccum >= SAMPLE_SEC then
        sampleAccum = 0
        stormSample()
    end

    if lastLevel == "storm" and self.alarm then
        blinkPhase = blinkPhase + (elapsed or 0)
        -- ~1.4 Hz pulse: alpha oscillates so the overlay visibly blinks
        local a = 0.5 + 0.5 * math.sin(blinkPhase * 9)
        self.alarm:Show()
        self.alarm:SetAlpha(a)
    end
end

--------------------------------------------------------------------------------
-- tooltip

function MB.showTooltip()
    if not (button and GameTooltip) then return end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine("Client Perf Probe")
    local colour = "|cff88ff88"
    if lastLevel == "storm" then colour = "|cffff4444"
    elseif lastLevel == "watch" then colour = "|cffffd200" end
    GameTooltip:AddLine(colour .. lastReason .. "|r")
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffeeeeeeLeft-click|r toggle the report window")
    GameTooltip:AddLine("|cffeeeeeeRight-click|r open the copy/paste export")
    GameTooltip:AddLine("|cffeeeeeeDrag|r move around the minimap")
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- construction

local function build()
    button = CreateFrame("Button", "ClientPerfProbeMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    -- circular icon, inset inside the ring border (the standard minimap-button look)
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(ICON)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.icon = icon

    -- red alarm ring that blinks during a storm (hidden otherwise)
    local alarm = button:CreateTexture(nil, "OVERLAY")
    alarm:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")   -- reuse a known ring texture
    alarm:SetVertexColor(1, 0.1, 0.1)
    alarm:SetSize(54, 54)
    alarm:SetPoint("TOPLEFT", 0, 0)
    alarm:SetBlendMode("ADD")
    alarm:Hide()
    button.alarm = alarm

    -- the raised metal ring border on top
    local border = button:CreateTexture(nil, "BORDER")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)
    button.border = border

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            if type(api.openReport) == "function" then api.openReport() end
        else
            if type(api.toggleUI) == "function" then api.toggleUI() end
        end
    end)

    button:SetScript("OnDragStart", function() dragging = true end)
    button:SetScript("OnDragStop", function() dragging = false end)

    button:SetScript("OnEnter", function() MB.showTooltip() end)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    button:SetScript("OnUpdate", onUpdate)

    updatePosition(getAngle())
end

--------------------------------------------------------------------------------
-- public

-- init(database, callbacks): build the button and wire the Core callbacks.
--   callbacks.toggleUI()    -> toggle the main window (left-click)
--   callbacks.openReport()  -> open the copy/paste export (right-click)
--   callbacks.stormInputs() -> { blockedPS, spikeCount, worstMs } for Storm.evaluate
function MB.init(database, callbacks)
    db = database
    api = callbacks or {}
    if not button then build() end
    if db and type(db.minimap) == "table" and db.minimap.hidden then
        button:Hide()
    else
        button:Show()
    end
    stormSample()   -- prime the level/tooltip immediately
end

function MB.show()
    if button then button:Show() end
    if db then
        if type(db.minimap) ~= "table" then db.minimap = {} end
        db.minimap.hidden = nil
    end
end

function MB.hide()
    if button then button:Hide() end
    if db then
        if type(db.minimap) ~= "table" then db.minimap = {} end
        db.minimap.hidden = true
    end
end

function MB.toggle()
    if button and button:IsShown() then MB.hide() else MB.show() end
end

function MB.frame() return button end

ns.Minimap = MB

return ns.Minimap
