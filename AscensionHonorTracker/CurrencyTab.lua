local ADDON, ns = ...

--=====================================================================
-- Ascension Honor Tracker - Currency tab button
--
-- Adds a "Show PvP" button to the top of the Currency tab. It toggles the
-- PvP points popup (Display.lua), which pops up next to the button and
-- closes automatically when the Currency tab is closed or the player
-- switches away from it.
--
-- Ascension ships a fully custom character UI. The currency tab is
-- AscensionCurrencyPanel inside AscensionCharacterFrame (Blizzard's
-- TokenFrame is never shown). The blank header band above the list belongs
-- to the OUTER frame, and the panel clips its own children, so we:
--   * parent the button to AscensionCharacterFrame (owns the band, no clip),
--   * anchor it just above the panel's list (into the band),
--   * show/hide it with the currency tab via the panel's OnShow/OnHide.
-- The Blizzard names are kept as a fallback for stock 3.3.5 clients.
--=====================================================================

-- Button position. BUTTON_X is the offset in from the panel's right edge;
-- BUTTON_GAP is how far above the list the button sits (raise it to move the
-- button further up into the blank band).
local BUTTON_X   = -28
local BUTTON_GAP = 4

local PANEL_CANDIDATES = { "AscensionCurrencyPanel", "TokenFrame" }
local FRAME_CANDIDATES = { "AscensionCharacterFrame", "CharacterFrame" }

local button

local function FindFirst(names)
    for i = 1, #names do
        local f = _G[names[i]]
        if f then return f end
    end
    return nil
end

local function SetButtonState(shown)
    if button then
        button:SetText(shown and "Hide PvP" or "Show PvP")
    end
end

local function EnsureButton()
    if button then return true end
    local panel = FindFirst(PANEL_CANDIDATES)
    if not panel then return false end
    -- Parent to the outer frame so the button isn't clipped by the panel.
    local parent = FindFirst(FRAME_CANDIDATES) or panel

    button = CreateFrame("Button", "AscensionHonorTrackerToggleButton", parent, "UIPanelButtonTemplate")
    button:SetWidth(90)
    button:SetHeight(20)
    button:SetText("Show PvP")
    -- Sit just above the currency list, in the blank header band.
    button:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", BUTTON_X, BUTTON_GAP)
    button:SetFrameStrata("HIGH")
    button:SetFrameLevel(parent:GetFrameLevel() + 10)
    if panel:IsShown() then button:Show() else button:Hide() end
    ns.currencyButton = button

    button:SetScript("OnClick", function()
        local Display = ns.Display
        if not Display then return end
        if Display:IsShown() then
            Display:Hide()
            SetButtonState(false)
        else
            Display:ShowAnchoredTo(button)
            SetButtonState(true)
        end
    end)

    -- Tie the button's visibility to the currency tab. Because the button is
    -- parented to the outer frame, it would otherwise show on every tab.
    panel:HookScript("OnShow", function()
        button:Show()
        SetButtonState(ns.Display and ns.Display:IsShown())
    end)
    panel:HookScript("OnHide", function()
        button:Hide()
        if ns.Display then ns.Display:Hide() end
        SetButtonState(false)
    end)

    return true
end

-- The custom Ascension UI is present by login; ADDON_LOADED covers the
-- stock Blizzard_TokenUI (load-on-demand) fallback path.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self)
    if EnsureButton() then
        self:UnregisterAllEvents()
    end
end)

-- In case the panel already exists when this file runs.
EnsureButton()
