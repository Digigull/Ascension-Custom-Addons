--[[ BackdropTest.lua — controlled A/B/C/D drag experiment (DIAGNOSTIC, WoW-facing).

     Owner realization (2026-08-14): every window that spikes on drag shares the
     standard Blizzard dialog LOOK (cpp window, both BiS windows, Bartender options),
     while custom-skinned windows that do NOT spike (Details options, WeakAuras
     options) look entirely different. Common factor = the default tiled dialog
     backdrop (`UI-DialogBox-Background` + `UI-DialogBox-Border` via SetBackdrop).

     This spawns four otherwise-identical movable frames differing ONLY in backdrop,
     so a cold drag of each isolates the cost to a specific backdrop component:
        A = FULL standard dialog backdrop (tiled bg + 9-slice border) — the suspect
        B = BORDER only (no background)
        C = TILED BACKGROUND only (no border)
        D = NO backdrop (a plain solid texture, the Details/WeakAuras-style bypass)
     If A/B/C spike but D does not, the default backdrop is the cause; whichever of
     B vs C spikes points at the border vs the tiled fill. The FIX that follows —
     replace the heavy backdrop with a light one — is a real fix (eliminates the
     cost), not a frontload (moves it). Read the drag spikes from the normal /cpp
     log (sus=DRAG) and/or by feel, one frame at a time.

     WoW-facing; syntax-checked only. All CreateFrame/SetBackdrop calls are inside
     toggle()/build(), never at file scope.
]]

local ADDON, ns = ...

local BackdropTest = {}

local BG   = "Interface\\DialogFrame\\UI-DialogBox-Background"
local EDGE = "Interface\\DialogFrame\\UI-DialogBox-Border"
local INSETS = { left = 11, right = 12, top = 12, bottom = 11 }

-- The four variants: identical frames, backdrop the ONLY difference.
local VARIANTS = {
    { key = "A", text = "A: FULL dialog backdrop\n(tiled bg + border)\n<-- the suspect -->\nDRAG ME",
      backdrop = { bgFile = BG, edgeFile = EDGE, tile = true, tileSize = 32, edgeSize = 32, insets = INSETS } },
    { key = "B", text = "B: BORDER only\n(no background)\nDRAG ME",
      backdrop = { edgeFile = EDGE, edgeSize = 32, insets = INSETS } },
    { key = "C", text = "C: TILED BG only\n(no border)\nDRAG ME",
      backdrop = { bgFile = BG, tile = true, tileSize = 32, insets = INSETS } },
    { key = "D", text = "D: NO backdrop\n(plain solid texture)\nDRAG ME",
      solid = true },
}
-- 2x2 grid near the top-left, spaced so each is easy to grab without overlap.
local POS = { { 40, -140 }, { 300, -140 }, { 40, -320 }, { 300, -320 } }

local frames

local function build()
    frames = {}
    for i, v in ipairs(VARIANTS) do
        local f = CreateFrame("Frame", "ClientPerfProbeBackdropTest" .. v.key, UIParent)
        f:SetSize(240, 150)
        f:SetPoint("TOPLEFT", POS[i][1], POS[i][2])
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        if v.backdrop then f:SetBackdrop(v.backdrop) end
        if v.solid then
            local t = f:CreateTexture(nil, "BACKGROUND")
            t:SetAllPoints(f)
            t:SetTexture(0.10, 0.10, 0.16, 0.90)   -- flat color, no tiling/9-slice
        end
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("CENTER")
        fs:SetWidth(210)
        fs:SetJustifyH("CENTER")
        fs:SetText(v.text)
        f:Hide()
        frames[i] = f
    end
end

-- Show/hide all four. Returns true if now shown. Diagnostic-only; never on a hot path.
function BackdropTest.toggle()
    if not frames then build() end
    local anyShown = false
    for _, f in ipairs(frames) do if f:IsShown() then anyShown = true; break end end
    for _, f in ipairs(frames) do
        if anyShown then f:Hide() else f:Show() end
    end
    return not anyShown
end

-- describe(name): read a LIVE frame's backdrop straight from the owner's client, so a
-- spiking window can be compared to a non-spiking one (Details / WeakAuras) without
-- guessing from third-party source (their installed 3.3.5 builds may differ from any
-- public/retail source). Uses the standard GetBackdrop() — feature-detected (ground
-- rule 2). Returns { found=bool, heavy=bool, lines={...} } for the caller to print.
-- A frame with a plain custom texture / no SetBackdrop returns GetBackdrop()==nil (the
-- non-spiking style); a standard dialog window returns the UI-DialogBox table (suspect).
function BackdropTest.describe(name)
    local f = (type(name) == "string") and (rawget(_G, name) or _G[name]) or nil
    if type(f) ~= "table" or type(f.GetBackdrop) ~= "function" then
        return { found = false, lines = {
            tostring(name) .. ": not found / not backdrop-capable (open the window first — many are lazy)" } }
    end
    local ok, bd = pcall(f.GetBackdrop, f)
    if not ok then
        return { found = false, lines = { tostring(name) .. ": GetBackdrop() failed on this client" } }
    end
    if type(bd) ~= "table" then
        return { found = true, heavy = false, lines = {
            tostring(name) .. ": |cff44ff44NO SetBackdrop|r (custom textures / none) — the NON-spiking style" } }
    end
    local bg = tostring(bd.bgFile or "-")
    local edge = tostring(bd.edgeFile or "-")
    local heavy = (bg:find("UI%-DialogBox") or edge:find("UI%-DialogBox")) and true or false
    return {
        found = true, heavy = heavy,
        lines = {
            tostring(name) .. ": SetBackdrop present" ..
                (heavy and " |cffff4444(standard UI-DialogBox — the SUSPECT style)|r" or " |cffffff00(non-standard backdrop)|r"),
            ("  bg=|cffdddddd%s|r"):format(bg),
            ("  edge=|cffdddddd%s|r tile=%s tileSize=%s edgeSize=%s"):format(
                edge, tostring(bd.tile), tostring(bd.tileSize), tostring(bd.edgeSize)),
        },
    }
end

-- ---------------------------------------------------------------------------
-- RESOLVED (2026-08-14): this dropdown-axis test is the WRONG axis for the
-- drag-freeze. The decisive test was run in the actual reproducing window
-- (Digigull/BiS-Scanner, /plbisscan dragtest) varying STRATA + SetToplevel, not
-- children: an EMPTY HIGH+SetToplevel(true) frame still froze 1273ms, while
-- FULLSCREEN_DIALOG or dropping SetToplevel was smooth. CAUSE = SetToplevel(true)
-- raising into the crowded HIGH strata (children/backdrop/dropdowns all
-- exonerated). See docs/DRAG-FREEZE.md + docs/FINDINGS.md. The E/F/G/H frames
-- below are kept as a backdrop/children control; they do NOT reproduce the bug.
--
-- CONSTRUCTION isolation test (2026-08-14) — the backdrop is EXONERATED.
--
-- Field result: swapping the heavy UI-DialogBox backdrop for the light Details
-- recipe on the BiS-Scanner windows did NOT remove the freeze. The earlier
-- "backdrop CONFIRMED" A/B was confounded — it dragged the *cpp* window (light
-- backdrop) against the *BiS-Scanner* window (heavy backdrop), two DIFFERENT
-- windows that also differ in children/strata. The cpp export window is smooth
-- AND it already uses SetToplevel(true) + RegisterForDrag (ExportWindow.lua),
-- so toplevel, drag-wiring ("guarded mouse event"), and strata are all
-- exonerated by our own smooth window. The one thing the frozen BiS-Scanner
-- window has that the smooth cpp window lacks is UIDropDownMenuTemplate ×3
-- (cpp uses light UIPanelButtonTemplate children). UIDropDownMenuTemplate is
-- heavy on 3.3.5 (dozens of sub-regions each). PRIME SUSPECT: the engine's
-- first-layout of the dropdown children, triggered when the frame is raised on
-- first drag.
--
-- These four frames hold backdrop CONSTANT (all the light recipe) and vary only
-- the CHILDREN (and strata for H), to name the real cause:
--    E = light backdrop, NO children               (Details-like control)  -> expect SMOOTH
--    F = light backdrop, + UIDropDownMenuTemplate ×3   (the suspect)        -> expect FREEZE
--    G = light backdrop, + UIPanelButton ×4 + close   (cpp-style children)  -> expect SMOOTH
--    H = light backdrop, HIGH strata, dropdowns ×3 + close (full BiS recipe)-> expect FREEZE
-- Reading: F freezes but G smooth  => UIDropDownMenuTemplate is the cause (not
-- children in general). E is the negative control; H reproduces the real
-- BiS-Scanner recipe with only the backdrop changed. Drag each ONE at a time
-- from a cold client and read sus=DRAG from /cpp (or by feel).
--
-- WoW-facing; every CreateFrame / template call is inside buildC(), never at
-- file scope. Blizzard globals (UIDropDownMenu_*) are feature-detected.
-- ---------------------------------------------------------------------------

local LIGHT = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile = true, tileSize = 64, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local CVARIANTS = {
    { key = "E", text = "E: light backdrop\nNO children\n(control)\nDRAG ME", strata = "FULLSCREEN_DIALOG" },
    { key = "F", text = "F: light backdrop\n+ 3 DROPDOWNS\n<-- suspect -->\nDRAG ME", strata = "FULLSCREEN_DIALOG", dropdowns = 3 },
    { key = "G", text = "G: light backdrop\n+ 4 buttons + close\n(cpp-style children)\nDRAG ME", strata = "FULLSCREEN_DIALOG", buttons = 4, close = true },
    { key = "H", text = "H: FULL BiS recipe\nHIGH strata\n3 dropdowns + close\nDRAG ME", strata = "HIGH", dropdowns = 3, close = true },
}
local CPOS = { { 40, -140 }, { 300, -140 }, { 40, -320 }, { 300, -320 } }

local cframes

-- Add `n` UIDropDownMenuTemplate children (the suspect heavy widget). Feature-
-- detects the Blizzard init helpers so the dropdowns get a realistic first
-- layout (ground rule 2 — don't assume an API exists on this client).
local function addDropdowns(f, n)
    for i = 1, n do
        local dd = CreateFrame("Frame", f:GetName() .. "Drop" .. i, f, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 34)
        if type(UIDropDownMenu_Initialize) == "function" then
            pcall(UIDropDownMenu_Initialize, dd, function() end)
        end
        if type(UIDropDownMenu_SetWidth) == "function" then pcall(UIDropDownMenu_SetWidth, dd, 120) end
        if type(UIDropDownMenu_SetText) == "function" then pcall(UIDropDownMenu_SetText, dd, "opt " .. i) end
    end
end

local function buildC()
    cframes = {}
    for i, v in ipairs(CVARIANTS) do
        local f = CreateFrame("Frame", "ClientPerfProbeConstructTest" .. v.key, UIParent)
        f:SetSize(240, 150)
        f:SetPoint("TOPLEFT", CPOS[i][1], CPOS[i][2])
        f:SetFrameStrata(v.strata)
        -- Kept deliberately: this harness VARIES strata and holds toplevel constant,
        -- so the flag must stay to isolate the strata axis. Note it no longer mirrors
        -- the shipping windows — those have since dropped SetToplevel entirely to
        -- kill the residual ~50ms per-drag restack (docs/DRAG-FREEZE.md).
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")     -- same drag path the real cpp windows use
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop(LIGHT)                -- backdrop held CONSTANT across E/F/G/H
        f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
        f:SetBackdropBorderColor(0.30, 0.30, 0.34, 1)
        if v.dropdowns then addDropdowns(f, v.dropdowns) end
        if v.buttons then
            for b = 1, v.buttons do
                local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
                btn:SetSize(70, 22)
                btn:SetPoint("TOPLEFT", 8, -8 - (b - 1) * 26)
                btn:SetText("btn " .. b)
            end
        end
        if v.close then
            local x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
            x:SetPoint("TOPRIGHT", 2, 2)
        end
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("BOTTOM", 0, 10)
        fs:SetWidth(210)
        fs:SetJustifyH("CENTER")
        fs:SetText(v.text)
        f:Hide()
        cframes[i] = f
    end
end

-- Show/hide the four construction-isolation frames. Returns true if now shown.
function BackdropTest.toggleConstruction()
    if not cframes then buildC() end
    local anyShown = false
    for _, f in ipairs(cframes) do if f:IsShown() then anyShown = true; break end end
    for _, f in ipairs(cframes) do
        if anyShown then f:Hide() else f:Show() end
    end
    return not anyShown
end

ns.BackdropTest = BackdropTest

return ns.BackdropTest
