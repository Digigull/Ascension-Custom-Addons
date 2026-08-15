local ADDON, ns = ...

--=====================================================================
-- Ascension Honor Tracker - Display
--
-- A small popup panel showing the current Honor and Conquest totals.
-- It is opened from the "Show PvP" button on the Currency tab (see
-- CurrencyTab.lua) and closes when that tab is closed. The values come
-- straight from Core's client-API reads, so they are correct even on the
-- login where the Currency tab itself is blank.
--
-- Moving the panel requires holding Shift while dragging; its position is
-- remembered across sessions.
--=====================================================================

local CONQUEST_ICON = ns.CONQUEST_ICON

local Display = {}
ns.Display = Display

--------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------
local frame = CreateFrame("Frame", "AscensionHonorTrackerFrame", UIParent)
frame:SetWidth(190)
frame:SetHeight(70)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:SetClampedToScreen(true)
frame:SetFrameStrata("DIALOG")
frame:RegisterForDrag("LeftButton")
frame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, 0.85)
frame:Hide() -- opened via the Currency-tab button, not shown by default

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("TOP", 0, -8)
title:SetText("|cffffd700Ascension PvP Points|r")

-- Builds one "icon  label  value" row anchored below the given region.
local function BuildRow(anchor, yOffset, iconTexture)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(18)
    icon:SetHeight(18)
    icon:SetPoint("TOPLEFT", anchor, "TOPLEFT", 10, yOffset)
    if iconTexture then icon:SetTexture(iconTexture) end

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    label:SetJustifyH("LEFT")

    local value = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    value:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    value:SetPoint("TOP", icon, "TOP", 0, -1)
    value:SetJustifyH("RIGHT")

    return { icon = icon, label = label, value = value }
end

local honorRow    = BuildRow(frame, -26, ns:HonorIcon())
local conquestRow = BuildRow(frame, -48, CONQUEST_ICON)
honorRow.label:SetText("Honor")
conquestRow.label:SetText("Conquest")
honorRow.value:SetText("0")
conquestRow.value:SetText("0")

--------------------------------------------------------------------
-- Position persistence
--
-- Stored as an offset from UIParent's center so it is independent of
-- screen resolution and of whatever the panel was last anchored to.
--------------------------------------------------------------------
local function HasSavedPosition()
    return ns.settings and ns.settings.position ~= nil
end

local function SavePosition()
    local s = ns.settings
    if not s then return end
    local cx, cy = frame:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if cx and ux then
        s.position = { x = cx - ux, y = cy - uy }
    end
end

function Display:RestorePosition()
    frame:ClearAllPoints()
    if HasSavedPosition() then
        local p = ns.settings.position
        frame:SetPoint("CENTER", UIParent, "CENTER", p.x or 0, p.y or 0)
    else
        frame:SetPoint("CENTER")
    end
end

function Display:ResetPosition()
    if ns.settings then ns.settings.position = nil end
    self:RestorePosition()
    if ns.Print then ns.Print("display position reset.") end
end

--------------------------------------------------------------------
-- Movement: only while Shift is held
--------------------------------------------------------------------
frame:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then
        self.isMoving = true
        self:StartMoving()
    end
end)
frame:SetScript("OnDragStop", function(self)
    if self.isMoving then
        self:StopMovingOrSizing()
        self.isMoving = nil
        SavePosition()
    end
end)

-- Hover hint so the shift-drag requirement is discoverable.
frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Ascension PvP Points")
    GameTooltip:AddLine("Shift-drag to move", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
frame:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

--------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------
function Display:IsShown()
    return frame:IsShown()
end

function Display:Hide()
    frame:Hide()
end

-- Show at the remembered position (or screen center if never moved).
function Display:SetShown(shown)
    if shown then
        self:RestorePosition()
        frame:Show()
    else
        frame:Hide()
    end
end

function Display:Toggle()
    self:SetShown(not frame:IsShown())
end

-- Opened from the Currency-tab button: use the saved position if the user
-- has moved it, otherwise pop up just beneath the button.
function Display:ShowAnchoredTo(button)
    if HasSavedPosition() or not button then
        self:RestorePosition()
    else
        frame:ClearAllPoints()
        frame:SetPoint("TOP", button, "BOTTOM", 0, -2)
    end
    frame:Show()
end

--------------------------------------------------------------------
-- Value updates
--------------------------------------------------------------------
local function OnValuesChanged(honor, conquest)
    honorRow.value:SetText(tostring(honor or 0))
    conquestRow.value:SetText(tostring(conquest or 0))
end

--------------------------------------------------------------------
-- Login setup (settings + saved vars are ready here)
--------------------------------------------------------------------
function ns:OnLogin()
    honorRow.icon:SetTexture(ns:HonorIcon())

    -- Migration: earlier versions stored position as {point, relPoint, x, y};
    -- drop that so the new center-offset scheme starts clean instead of
    -- placing the panel using mismatched coordinates.
    local pos = ns.settings and ns.settings.position
    if pos and pos.point ~= nil then
        ns.settings.position = nil
    end

    Display:RestorePosition()
    frame:Hide() -- stays hidden until opened from the Currency tab
    ns:RegisterListener(OnValuesChanged)
end
