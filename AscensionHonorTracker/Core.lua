local ADDON, ns = ...

--=====================================================================
-- Ascension Honor Tracker - Core
--
-- The problem this solves:
--   On 3.3.5 (Ascension) the default Currency tab fails to populate its
--   PvP entries after a fresh login or a relog. Honor and Conquest just
--   aren't listed -- yet the values still exist on the client. They only
--   reappear once you next EARN or SPEND them, because any honor/arena
--   update forces the currency list to refresh.
--
-- The fix:
--   Don't rely on the currency *list* for the numbers. WotLK exposes the
--   values directly and reliably right after login:
--       GetHonorCurrency()  -> Honor Points
--       GetArenaCurrency()  -> Arena / Conquest Points
--   We read those, keep them fresh via events plus a light poll (custom
--   cores don't always fire the same events), and persist the last known
--   values per character as a final fallback. If the direct API is ever
--   unavailable we scan the currency list by name as a secondary source.
--=====================================================================

ns.version = (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "1.0.0"

-- Localized display names to look for when falling back to a currency-list
-- scan. Ascension renames Arena Points to "Conquest Points"; we accept the
-- classic names too so this keeps working on other 3.3.5 cores.
ns.HONOR_NAMES    = { "Honor Points", "Honor" }
ns.CONQUEST_NAMES = { "Conquest Points", "Conquest", "Arena Points" }

-- Shared icon paths, used by the popup panel and the vendor overlay.
ns.CONQUEST_ICON = "Interface\\PVPFrame\\PVP-ArenaPoints-Icon"

-- Honor icon depends on faction; safe to call after PLAYER_LOGIN.
function ns:HonorIcon()
    if UnitFactionGroup("player") == "Horde" then
        return "Interface\\PVPFrame\\PVP-Currency-Horde"
    end
    return "Interface\\PVPFrame\\PVP-Currency-Alliance"
end

--------------------------------------------------------------------
-- Listener registry
--
-- Other modules (the display, the currency-tab patch) register a
-- callback that is invoked with (honor, conquest, data) whenever the
-- tracked values change.
--------------------------------------------------------------------
local listeners = {}

function ns:RegisterListener(fn)
    table.insert(listeners, fn)
    -- If we already have data, push it immediately so late-loading
    -- modules render correct numbers without waiting for the next change.
    if self.data then
        fn(self.data.honor, self.data.conquest, self.data)
    end
end

local function Notify()
    local d = ns.data
    if not d then return end
    for i = 1, #listeners do
        listeners[i](d.honor, d.conquest, d)
    end
end

--------------------------------------------------------------------
-- Reading the values
--------------------------------------------------------------------

-- Secondary source: walk the currency list and match by localized name.
-- Only used if the direct API is missing on this core. Returns a number
-- or nil.
function ns:ScanCurrencyByNames(names)
    if type(GetCurrencyListSize) ~= "function" or type(GetCurrencyListInfo) ~= "function" then
        return nil
    end
    local size = GetCurrencyListSize()
    for i = 1, size do
        -- 3.3.5: name, isHeader, isExpanded, isUnused, isWatched, count, ...
        local name, isHeader, _, _, _, count = GetCurrencyListInfo(i)
        if name and not isHeader then
            for j = 1, #names do
                if name == names[j] then
                    return count or 0
                end
            end
        end
    end
    return nil
end

-- Primary source is the direct API; currency-list scan is the fallback.
local function ReadHonor()
    if type(GetHonorCurrency) == "function" then
        local v = GetHonorCurrency()
        if type(v) == "number" then return v end
    end
    return ns:ScanCurrencyByNames(ns.HONOR_NAMES)
end

local function ReadConquest()
    if type(GetArenaCurrency) == "function" then
        local v = GetArenaCurrency()
        if type(v) == "number" then return v end
    end
    return ns:ScanCurrencyByNames(ns.CONQUEST_NAMES)
end

-- Refresh reads current values and updates the (persisted) data table.
-- A nil reading is ignored so we never overwrite a good stored value with
-- a momentary blank. Pass force=true to notify listeners even when the
-- numbers are unchanged (used on login so the UI paints at least once).
function ns:Refresh(force)
    local d = ns.data
    if not d then return end

    local honor    = ReadHonor()
    local conquest = ReadConquest()
    local changed  = force and true or false

    if honor ~= nil and honor ~= d.honor then
        d.honor = honor
        changed = true
    end
    if conquest ~= nil and conquest ~= d.conquest then
        d.conquest = conquest
        changed = true
    end
    if honor ~= nil or conquest ~= nil then
        d.lastUpdated = time()
    end

    if changed then
        Notify()
    end
end

--------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------
local function InitData()
    -- Per-character store: we point ns.data straight at the saved table so
    -- every write is persisted automatically at logout.
    AscensionHonorTrackerCharDB = AscensionHonorTrackerCharDB or {}
    local cdb = AscensionHonorTrackerCharDB
    cdb.honor    = cdb.honor    or 0
    cdb.conquest = cdb.conquest or 0
    ns.data = cdb

    -- Global (account-wide) settings store for the display module.
    AscensionHonorTrackerDB = AscensionHonorTrackerDB or {}
    ns.settings = AscensionHonorTrackerDB
end

--------------------------------------------------------------------
-- Events + light poll
--------------------------------------------------------------------
local f = CreateFrame("Frame", "AscensionHonorTrackerCore")
ns.frame = f

-- Some event names may not exist on a given core; registering an unknown
-- event errors in 3.3.5, so guard the optional ones.
local function SafeRegister(event)
    pcall(f.RegisterEvent, f, event)
end

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
SafeRegister("HONOR_CURRENCY_UPDATE")
SafeRegister("CHAT_MSG_COMBAT_HONOR_GAIN")
SafeRegister("CURRENCY_DISPLAY_UPDATE")
SafeRegister("PLAYER_PVP_KILLS_CHANGED")

f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        InitData()
        ns:Refresh(true)
        if ns.OnLogin then ns:OnLogin() end
    elseif ns.data then
        ns:Refresh(true)
    end
end)

-- Poll as a safety net: GetHonorCurrency/GetArenaCurrency are cheap local
-- reads, and a custom core may change values without firing an event we
-- registered. One read per second is negligible and guarantees the display
-- and stored values stay honest.
local POLL_INTERVAL = 1.0
local accum = 0
f:SetScript("OnUpdate", function(self, elapsed)
    accum = accum + elapsed
    if accum >= POLL_INTERVAL then
        accum = 0
        if ns.data then ns:Refresh(false) end
    end
end)

--------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Honor Tracker|r: " .. msg)
end
ns.Print = Print

-- Geometry dump to help position the currency-tab button and vendor overlay
-- on whatever custom UI a given client is running. Open the Currency tab and
-- a PvP vendor first, then run "/aht debug".
function ns:PrintDebug()
    local function line(label, f)
        if not f then
            Print(label .. ": nil")
            return
        end
        Print(("%s: shown=%s vis=%s L=%s B=%s W=%s parent=%s"):format(
            label,
            tostring(f:IsShown()),
            tostring(f:IsVisible()),
            tostring(math.floor((f:GetLeft() or -1))),
            tostring(math.floor((f:GetBottom() or -1))),
            tostring(math.floor((f:GetWidth() or -1))),
            tostring((f:GetParent() and f:GetParent():GetName()) or "?")
        ))
    end
    Print(("UIParent %dx%d scale=%.2f"):format(
        UIParent:GetWidth(), UIParent:GetHeight(), UIParent:GetEffectiveScale()))
    line("Button", ns.currencyButton)
    line("VendorText", ns.vendorText)
    line("AscensionCurrencyPanel", _G["AscensionCurrencyPanel"])
    line("AscensionCharacterFrame", _G["AscensionCharacterFrame"])
    line("TokenFrame", _G["TokenFrame"])
    line("MerchantFrame", _G["MerchantFrame"])
end

SLASH_ASCENSIONHONORTRACKER1 = "/aht"
SLASH_ASCENSIONHONORTRACKER2 = "/honortracker"
SlashCmdList["ASCENSIONHONORTRACKER"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local Display = ns.Display

    if msg == "show" then
        if Display then Display:SetShown(true) end
    elseif msg == "hide" then
        if Display then Display:SetShown(false) end
    elseif msg == "toggle" or msg == "" then
        if Display then Display:Toggle() end
    elseif msg == "reset" then
        if Display then Display:ResetPosition() end
    elseif msg == "status" then
        local d = ns.data or {}
        Print(("Honor: %d   Conquest: %d"):format(d.honor or 0, d.conquest or 0))
    elseif msg == "debug" then
        ns:PrintDebug()
    else
        Print("commands: |cffffffff/aht|r toggle | show | hide | reset | status | debug")
        Print("tip: open the Currency tab and click |cffffffffShow PvP|r; shift-drag the window to move it.")
    end
end
