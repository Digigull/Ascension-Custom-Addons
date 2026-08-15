local ADDON, ns = ...

--=====================================================================
-- Ascension Honor Tracker - Vendor overlay
--
-- When a vendor that sells honor- or conquest-purchased items is opened,
-- show the player's current relevant points in the bottom-left corner of
-- the merchant window (above Ascension's "Automatically sell junk"
-- checkbox). Vendors that don't deal in PvP points show nothing.
--
-- The text lives on its own HIGH-strata frame parented to MerchantFrame so
-- it draws above whatever custom buttons/checkboxes an enhanced-merchant
-- addon layers on top of the default frame.
--=====================================================================

-- Anchor of the overlay inside MerchantFrame's bottom-left corner. Nudge
-- these two numbers if it doesn't sit exactly where you want it.
local ANCHOR_X = 20
local ANCHOR_Y = 92

local host     -- HIGH-strata frame
local overlay  -- FontString on `host`
local usesHonor, usesArena = false, false

local function EnsureOverlay()
    if overlay then return true end
    if not _G["MerchantFrame"] then return false end

    host = CreateFrame("Frame", "AscensionHonorTrackerVendorFrame", MerchantFrame)
    host:SetFrameStrata("HIGH")
    host:SetFrameLevel(MerchantFrame:GetFrameLevel() + 10)
    host:SetWidth(240)
    host:SetHeight(20)
    host:SetPoint("BOTTOMLEFT", MerchantFrame, "BOTTOMLEFT", ANCHOR_X, ANCHOR_Y)

    overlay = host:CreateFontString("AscensionHonorTrackerVendorText", "OVERLAY", "GameFontHighlight")
    overlay:SetPoint("LEFT", host, "LEFT", 0, 0)
    overlay:SetJustifyH("LEFT")

    host:Hide()
    ns.vendorText = overlay
    return true
end

local function BuildText()
    local d = ns.data or {}
    local parts = {}
    if usesHonor then
        parts[#parts + 1] = ("|T%s:16:16:0:0|t %d Honor"):format(ns:HonorIcon(), d.honor or 0)
    end
    if usesArena then
        parts[#parts + 1] = ("|T%s:16:16:0:0|t %d Conquest"):format(ns.CONQUEST_ICON, d.conquest or 0)
    end
    return table.concat(parts, "    ")
end

local function Refresh()
    if not host then return end
    if usesHonor or usesArena then
        overlay:SetText(BuildText())
        host:Show()
    else
        host:Hide()
    end
end

-- Does anything the open vendor sells cost honor or arena/conquest points?
local function ScanVendor()
    usesHonor, usesArena = false, false
    local n = (GetMerchantNumItems and GetMerchantNumItems()) or 0
    for i = 1, n do
        -- WotLK signature: honorPoints, arenaPoints, itemCount. If a core
        -- returns only a single value (itemCount), the 3rd result is nil and
        -- we skip it, so we never misread an item count as a points cost.
        local honor, arena, itemCount = GetMerchantItemCostInfo(i)
        if itemCount ~= nil then
            if (tonumber(honor) or 0) > 0 then usesHonor = true end
            if (tonumber(arena) or 0) > 0 then usesArena = true end
        end
        if usesHonor and usesArena then break end
    end
end

local f = CreateFrame("Frame", "AscensionHonorTrackerVendor")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_UPDATE")
f:RegisterEvent("MERCHANT_CLOSED")
f:SetScript("OnEvent", function(self, event)
    if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        -- Cost data can lag MERCHANT_SHOW on some cores; MERCHANT_UPDATE
        -- rescans once it's populated.
        EnsureOverlay()
        ScanVendor()
        Refresh()
    elseif event == "MERCHANT_CLOSED" then
        usesHonor, usesArena = false, false
        if host then host:Hide() end
    end
end)

-- Keep the numbers live if points change while the vendor is open.
ns:RegisterListener(function()
    if host and host:IsShown() then
        overlay:SetText(BuildText())
    end
end)
