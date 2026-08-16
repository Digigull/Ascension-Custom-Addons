local ADDON, ns = ...

-- ExadMinimap: the minimap skin + minimap button collector from ExadTweaks,
-- pulled out as a standalone addon. It touches nothing but the minimap cluster
-- and addon-created minimap buttons, so it cannot taint unit frames or action
-- bars the way the full package's frame/aura/keypress modules can.

local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local LoadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn

ns.defaults = {
    -- Square minimap skin: mask, size, border, zone/clock bar, repositioned
    -- Blizzard minimap widgets. Turn off to keep the round Blizzard minimap.
    squareMinimap = true,
    minimapSize = 175,
    mouseWheelZoom = true,

    -- Button collector: gathers every addon minimap button into a hidden grid
    -- under the minimap, toggled by the small icon on the zone bar.
    buttonCollector = true,
    buttonsPerRow = 6,
    buttonSpacing = 32,

    -- Off by default: the equivalent ExadTweaks code never actually ran (see the
    -- note in buttons.lua), so leaving this off reproduces the look you already
    -- have. Turn it on with /exadmm skin to get the dark forge-style borders.
    skinButtons = false,

    -- Seconds before the toggle icon fades out after login. 0 keeps it visible.
    toggleFadeDelay = 45,

    -- Shade applied to the Blizzard minimap border when squareMinimap is off.
    borderShade = 0.25,

    -- Walk the minimap's children to find buttons that never registered with
    -- LibDBIcon, instead of relying on the manual list below.
    autoDetect = true,

    -- Buttons the collector should leave on the minimap, by frame name. Managed
    -- from the Buttons page of the options panel, or /exadmm ignore <FrameName>.
    ignoredButtons = {},

    -- Buttons the scan cannot reach. Add their exact frame names here, or in
    -- game with: /exadmm add <FrameName>
    extraButtons = {
        "PLBiSScannerMinimapButton",
        "PasslootBiS_MinimapButton",
    },
}

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff009cffExadMinimap|r: " .. tostring(msg))
end

-- Frames created from a Secure*Template are the only ones we would ever need to
-- worry about; everything here is a plain frame, so BackdropTemplate is only a
-- client-compatibility concern.
function ns.CreateBackdropFrame(name, parent)
    if BackdropTemplateMixin then
        return CreateFrame("Frame", name, parent, "BackdropTemplate")
    end
    return CreateFrame("Frame", name, parent)
end

-- C_Timer is present on Ascension, but fall back to an OnUpdate ticker so a
-- client without it still gets the deferred button styling and the icon fade.
function ns.After(delay, func)
    if C_Timer and C_Timer.After then
        return C_Timer.After(delay, func)
    end

    local ticker = CreateFrame("Frame")
    local elapsed = 0
    ticker:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + delta
        if elapsed >= delay then
            self:SetScript("OnUpdate", nil)
            func()
        end
    end)
end

local function CopyDefaults(dst, src)
    for key, value in pairs(src) do
        if type(value) == "table" then
            if type(dst[key]) ~= "table" then
                dst[key] = {}
            end
            CopyDefaults(dst[key], value)
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
end

local function InitDB()
    if type(ExadMinimapDB) ~= "table" then
        ExadMinimapDB = {}
    end
    CopyDefaults(ExadMinimapDB, ns.defaults)
    ns.db = ExadMinimapDB

    -- The panel reads ns.db as it builds its widgets, so it can only go up once
    -- the database exists.
    if ns.SetupOptions then
        ns.SetupOptions()
    end
end

-- The skin fights with addons that own the minimap outright. Bail rather than
-- half-apply on top of them, exactly as ExadTweaks did.
function ns.ConflictingAddon()
    if IsAddOnLoaded("SexyMap") then
        return "SexyMap"
    end
    if IsAddOnLoaded("Leatrix_Plus") and LeaPlusDB and LeaPlusDB["MinimapModder"] == "On" then
        return "Leatrix_Plus (Minimap Modder)"
    end
    return nil
end

local applied = false

local function Apply()
    if applied or not ns.db then
        return
    end

    local conflict = ns.ConflictingAddon()
    if conflict then
        ns.conflict = conflict
        return
    end

    applied = true
    ns.ApplyMinimapSkin()

    if ns.db.buttonCollector then
        ns.SetupButtonCollector()
    end
end

ns.IsApplied = function()
    return applied
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, addon)
    if event == "ADDON_LOADED" then
        if addon == ADDON then
            InitDB()
        end

        -- Any newly loaded addon may have registered a minimap button, so the
        -- cached button list has to be rebuilt on the next toggle.
        ns.InvalidateButtonCache()

        if addon == "Blizzard_TimeManager" then
            Apply()
        elseif addon == "Blizzard_GroupFinder_VanillaStyle" then
            ns.ApplyLFGButton()
        end
        return
    end

    -- PLAYER_LOGIN: the clock may already have loaded before us (or be missing
    -- entirely), so cover both cases instead of relying on the ADDON_LOADED order.
    InitDB()
    if not applied then
        if not IsAddOnLoaded("Blizzard_TimeManager") then
            pcall(LoadAddOn, "Blizzard_TimeManager")
        end
        Apply()
    end
    if IsAddOnLoaded("Blizzard_GroupFinder_VanillaStyle") then
        ns.ApplyLFGButton()
    end
end)

-- ===== Slash commands =====

local function Bool(value)
    return value and "|cff00ff00on|r" or "|cffff0000off|r"
end

local toggles = {
    square = "squareMinimap",
    buttons = "buttonCollector",
    skin = "skinButtons",
    wheel = "mouseWheelZoom",
}

local function Usage()
    ns.Print("commands:")
    ns.Print("  /exadmm config           - open the options panel")
    ns.Print("  /exadmm pick             - click a minimap button to add it")
    ns.Print("  /exadmm toggle           - show/hide the collected minimap buttons")
    ns.Print("  /exadmm scan             - look for newly created minimap buttons")
    ns.Print("  /exadmm square           - square minimap skin on/off (reload)")
    ns.Print("  /exadmm buttons          - button collector on/off (reload)")
    ns.Print("  /exadmm skin             - button border skinning on/off (reload)")
    ns.Print("  /exadmm wheel            - mousewheel zoom on/off (reload)")
    ns.Print("  /exadmm detect           - automatic button detection on/off")
    ns.Print("  /exadmm add <FrameName>  - track a button the scan cannot reach")
    ns.Print("  /exadmm remove <FrameName>")
    ns.Print("  /exadmm ignore <FrameName> - leave a button on the minimap")
    ns.Print("  /exadmm list             - show tracked buttons and status")
    ns.Print("  /exadmm name             - print the frame name under your cursor")
end

SLASH_EXADMINIMAP1 = "/exadmm"
SLASH_EXADMINIMAP2 = "/exadminimap"
SlashCmdList["EXADMINIMAP"] = function(input)
    if not ns.db then
        InitDB()
    end

    local cmd, arg = string.match(strtrim(input or ""), "^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")

    if cmd == "config" then
        if ns.OpenOptions then
            ns.OpenOptions()
        else
            ns.Print("the options panel is not available.")
        end

    elseif cmd == "pick" then
        if ns.StartButtonPicker then
            ns.StartButtonPicker()
        else
            ns.Print("the options panel is not available.")
        end

    elseif cmd == "toggle" then
        if ns.ToggleButtons then
            ns.ToggleButtons()
        else
            ns.Print("the button collector is not active.")
        end

    elseif cmd == "scan" then
        local found = ns.ScanForButtons and ns.ScanForButtons() or {}
        if ns.RefreshButtonLayout then
            ns.RefreshButtonLayout()
        end
        if ns.RefreshOptions then
            ns.RefreshOptions()
        end
        ns.Print(#found .. " button(s) collected after the scan.")

    elseif cmd == "detect" then
        ns.db.autoDetect = not ns.db.autoDetect
        ns.InvalidateButtonCache()
        if ns.RefreshButtonLayout then
            ns.RefreshButtonLayout()
        end
        if ns.RefreshOptions then
            ns.RefreshOptions()
        end
        ns.Print("automatic button detection is now " .. Bool(ns.db.autoDetect) .. ".")

    elseif toggles[cmd] then
        local key = toggles[cmd]
        ns.db[key] = not ns.db[key]
        if ns.RefreshOptions then
            ns.RefreshOptions()
        end
        ns.Print(cmd .. " is now " .. Bool(ns.db[key]) .. " - /reload to apply.")

    elseif cmd == "ignore" then
        if arg == "" then
            ns.Print("usage: /exadmm ignore <FrameName>")
            return
        end
        local nowIgnored = ns.SetIgnored and ns.SetIgnored(arg, not ns.IsIgnored(arg))
        ns.Print(arg .. (nowIgnored and " is left on the minimap." or " is collected again."))

    elseif cmd == "add" then
        if arg == "" then
            ns.Print("usage: /exadmm add <FrameName>")
            return
        end
        if not ns.AddExtraButton or not ns.AddExtraButton(arg) then
            ns.Print(arg .. " is already tracked.")
            return
        end
        ns.Print("now tracking " .. arg .. (_G[arg] and "." or " (no such frame right now)."))

    elseif cmd == "remove" then
        if ns.RemoveExtraButton and ns.RemoveExtraButton(arg) then
            ns.Print("stopped tracking " .. arg .. ".")
        else
            ns.Print(arg .. " was not tracked.")
        end

    elseif cmd == "list" then
        if ns.conflict then
            ns.Print("skin disabled: " .. ns.conflict .. " is managing the minimap.")
        end
        ns.Print("square=" .. Bool(ns.db.squareMinimap)
            .. " collector=" .. Bool(ns.db.buttonCollector)
            .. " skin=" .. Bool(ns.db.skinButtons)
            .. " wheel=" .. Bool(ns.db.mouseWheelZoom)
            .. " detect=" .. Bool(ns.db.autoDetect))
        local buttons = ns.GetMinimapButtons and ns.GetMinimapButtons() or {}
        ns.Print(#buttons .. " button(s) currently collected.")
        if #ns.db.extraButtons == 0 then
            ns.Print("no manually tracked buttons.")
        else
            for _, name in ipairs(ns.db.extraButtons) do
                ns.Print("  " .. name .. (_G[name] and "" or " |cffff0000(missing)|r"))
            end
        end
        for _, name in ipairs(ns.db.ignoredButtons) do
            ns.Print("  " .. name .. " |cffffff00(left on the minimap)|r")
        end

    elseif cmd == "name" then
        local focus = GetMouseFocus and GetMouseFocus()
        ns.Print("frame under cursor: " .. ((focus and focus.GetName and focus:GetName()) or "unnamed"))

    else
        Usage()
    end
end
