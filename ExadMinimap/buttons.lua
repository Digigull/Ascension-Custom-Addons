local ADDON, ns = ...

local MEDIA = "Interface\\AddOns\\ExadMinimap\\textures\\"

-- ===== Collecting the buttons =====
--
-- ExadTweaks rebuilt this list by walking the whole of _G, wrapping every single
-- global in its own closure + pcall, on every show and every hide. On a loaded
-- client that is tens of thousands of protected calls per click. Here the list is
-- built once and cached until an ADDON_LOADED says a new button may exist, the
-- LibDBIcon registry is asked directly when the library is available, and the _G
-- fallback matches on the key string instead of calling a method on every value.

local cache, cacheValid = {}, false

-- Everything the last rebuild found, *before* the ignore list was applied. The
-- options panel lists this so a button you told the collector to leave alone is
-- still something you can see and switch back on.
local candidates = {}

-- Frames the minimap scan has turned up this session. Collected buttons get
-- reparented onto the grid anchor, so a later scan of Minimap's children would
-- no longer see them; remembering them here keeps them in the list.
local discovered = {}

function ns.InvalidateButtonCache()
    cacheValid = false
end

local function IsMinimapButton(frame)
    return type(frame) == "table"
        and type(frame.SetPoint) == "function"
        and type(frame.Show) == "function"
        and type(frame.Hide) == "function"
end

local function ButtonName(frame)
    if type(frame) ~= "table" or type(frame.GetName) ~= "function" then
        return ""
    end
    local ok, name = pcall(frame.GetName, frame)
    return (ok and type(name) == "string" and name) or ""
end

ns.ButtonName = ButtonName

-- ===== Scanning the minimap for buttons that skipped LibDBIcon =====
--
-- Walking _G is what the original did, and it is both slow and indiscriminate.
-- Every minimap button has to be a *child of the minimap* to be drawn on it, so
-- walking the minimap's own children finds the same buttons for the cost of a
-- few dozen comparisons. Blizzard's own minimap furniture is filtered by name.

local BLIZZARD_MINIMAP_FRAMES = {
    Minimap = true,
    MinimapCluster = true,
    MinimapBackdrop = true,
    MinimapBorder = true,
    MinimapBorderTop = true,
    MinimapNorthTag = true,
    MinimapZoomIn = true,
    MinimapZoomOut = true,
    MinimapToggleButton = true,
    MinimapZoneTextButton = true,
    MinimapPing = true,
    MiniMapPing = true,
    MiniMapTracking = true,
    MiniMapTrackingButton = true,
    MiniMapTrackingBorder = true,
    MiniMapMailFrame = true,
    MiniMapMailBorder = true,
    MiniMapBattlefieldFrame = true,
    MiniMapBattlefieldBorder = true,
    MiniMapWorldMapButton = true,
    MiniMapRecordingButton = true,
    MiniMapInstanceDifficulty = true,
    MiniMapLFGFrame = true,
    MiniMapVoiceChatFrame = true,
    MiniMapMeetingStoneFrame = true,
    LFGMinimapFrame = true,
    GameTimeFrame = true,
    TimeManagerClockButton = true,
    QueueStatusMinimapButton = true,
    GarrisonLandingPageMinimapButton = true,
}

-- Roots worth walking. Buttons overwhelmingly parent to Minimap; a handful pick
-- MinimapBackdrop or MinimapCluster instead.
local SCAN_ROOTS = { "Minimap", "MinimapBackdrop", "MinimapCluster" }

local function Children(frame)
    if type(frame) ~= "table" or type(frame.GetChildren) ~= "function" then
        return {}
    end
    local packed = { pcall(frame.GetChildren, frame) }
    if not packed[1] then
        return {}
    end
    table.remove(packed, 1)
    return packed
end

ns.Children = Children

-- Deliberately loose: a false positive is one click to switch off in the panel,
-- a false negative is a button you can never collect without knowing its name.
local function LooksLikeAButton(frame, name)
    if name == "" or BLIZZARD_MINIMAP_FRAMES[name] then
        return false
    end
    if string.find(name, "^ExadMinimap") then
        return false
    end

    -- Never adopt a frame that is hidden right now. Collecting a button means
    -- calling Show() on it, and a frame its owner deliberately hid may not
    -- survive being shown: MiniMapRecordingButton, for one, ships hidden and
    -- its OnUpdate calls MovieRecording_GetTime(), which does not exist on this
    -- client, so showing it throws an error on every tooltip tick. Anything
    -- that appears later is picked up by the next scan (see ns.QuickScan).
    if type(frame.IsShown) ~= "function" or not frame:IsShown() then
        return false
    end

    local objectType = frame.GetObjectType and frame:GetObjectType()
    if objectType ~= "Button" and objectType ~= "Frame" then
        return false
    end

    -- Minimap buttons are small and square-ish. Anything the size of the map
    -- itself is a backdrop or an overlay, not a button.
    local width = frame.GetWidth and frame:GetWidth() or 0
    local height = frame.GetHeight and frame:GetHeight() or 0
    if width < 12 or width > 48 or height < 12 or height > 48 then
        return false
    end

    -- A button you can click has the mouse enabled; decorative frames do not.
    if frame.IsMouseEnabled and not frame:IsMouseEnabled() then
        return false
    end

    return true
end

-- Returns true when the scan turned up something it had not seen before.
local function ScanMinimap()
    local found = false
    for _, rootName in ipairs(SCAN_ROOTS) do
        for _, child in ipairs(Children(_G[rootName])) do
            if not discovered[child] then
                local ok, isButton = pcall(LooksLikeAButton, child, ButtonName(child))
                if ok and isButton then
                    discovered[child] = true
                    found = true
                end
            end
        end
    end
    return found
end

-- Minimap children only, no _G walk, so this is cheap enough to run every time
-- the grid opens. That is what lets the "must be shown" rule above be safe: a
-- button that only appears after login is picked up the next time you look.
function ns.QuickScan()
    if not ns.db or not ns.db.autoDetect then
        return false
    end
    if ScanMinimap() then
        ns.InvalidateButtonCache()
        return true
    end
    return false
end

function ns.ScanForButtons()
    ScanMinimap()
    ns.InvalidateButtonCache()
    return ns.GetMinimapButtons()
end

-- ===== The ignore list =====

local function IgnoredSet()
    local set = {}
    for _, name in ipairs((ns.db and ns.db.ignoredButtons) or {}) do
        set[name] = true
    end
    return set
end

function ns.IsIgnored(name)
    if not name or name == "" then
        return false
    end
    return IgnoredSet()[name] or false
end

local function RemoveFrom(list, value)
    for i, entry in ipairs(list) do
        if entry == value then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- Returns the state the name ended up in.
function ns.SetIgnored(name, ignored)
    if not ns.db or not name or name == "" then
        return false
    end

    if ignored then
        if not ns.IsIgnored(name) then
            table.insert(ns.db.ignoredButtons, name)
        end
    else
        RemoveFrom(ns.db.ignoredButtons, name)
    end

    ns.InvalidateButtonCache()
    if ns.RefreshButtonLayout then
        ns.RefreshButtonLayout()
    end
    if ns.RefreshOptions then
        ns.RefreshOptions()
    end
    return ignored and true or false
end

function ns.IsExtraButton(name)
    if not ns.db or not name or name == "" then
        return false
    end
    for _, entry in ipairs(ns.db.extraButtons) do
        if entry == name then
            return true
        end
    end
    return false
end

function ns.AddExtraButton(name)
    if not ns.db or not name or name == "" or ns.IsExtraButton(name) then
        return false
    end

    table.insert(ns.db.extraButtons, name)
    -- Adding a button by hand is an explicit "collect this", so an old ignore
    -- entry for the same name should not silently win.
    RemoveFrom(ns.db.ignoredButtons, name)

    ns.InvalidateButtonCache()
    if ns.RefreshButtonLayout then
        ns.RefreshButtonLayout()
    end
    if ns.RefreshOptions then
        ns.RefreshOptions()
    end
    return true
end

function ns.RemoveExtraButton(name)
    if not ns.db or not RemoveFrom(ns.db.extraButtons, name) then
        return false
    end

    ns.InvalidateButtonCache()
    if ns.RefreshButtonLayout then
        ns.RefreshButtonLayout()
    end
    if ns.RefreshOptions then
        ns.RefreshOptions()
    end
    return true
end

-- ===== Grid order =====
--
-- ns.db.buttonOrder is a list of frame names in the order the grid lays them
-- out. A name that is not in it -- a button belonging to an addon installed
-- since the last reorder -- sorts after every name that is, alphabetically, so
-- something new lands at the end of the grid instead of shuffling what you
-- already arranged. With the list empty, everything is unranked and the order
-- is the plain alphabetical sort this addon has always used.

local function OrderRanks()
    local ranks = {}
    for index, name in ipairs((ns.db and ns.db.buttonOrder) or {}) do
        if ranks[name] == nil then
            ranks[name] = index
        end
    end
    return ranks
end

-- One comparator over frame names, shared by the grid and the options list so
-- the row you drag past another is the button you see move on screen.
function ns.ButtonOrderComparator()
    local ranks = OrderRanks()
    return function(a, b)
        local rankA, rankB = ranks[a or ""], ranks[b or ""]
        if rankA and rankB then
            return rankA < rankB
        elseif rankA or rankB then
            return rankA ~= nil
        end
        return (a or "") < (b or "")
    end
end

-- Every name the options list can show, in grid order. Unnamed frames are left
-- out: the order is stored by name, so a frame without one cannot hold a slot.
function ns.GetOrderedNames()
    local names, seen = {}, {}

    local function add(name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    for _, frame in ipairs(ns.GetAllButtons and ns.GetAllButtons() or {}) do
        add(ButtonName(frame))
    end
    -- Names tracked by hand whose frame is not loaded right now are still rows
    -- in the panel, so they still take part in the ordering.
    for _, name in ipairs((ns.db and ns.db.extraButtons) or {}) do
        add(name)
    end

    table.sort(names, ns.ButtonOrderComparator())
    return names
end

-- Move one button a slot up (delta -1) or down (delta 1). The whole order is
-- written back, not just the pair that swapped: pinning every name at once is
-- what stops the rest of the grid drifting the next time something unranked
-- turns up.
function ns.MoveButton(name, delta)
    if not ns.db or not name or name == "" or not delta or delta == 0 then
        return false
    end

    local names = ns.GetOrderedNames()
    local index
    for position, entry in ipairs(names) do
        if entry == name then
            index = position
            break
        end
    end
    if not index then
        return false
    end

    local target = index + delta
    if target < 1 or target > #names then
        return false
    end
    names[index], names[target] = names[target], names[index]

    -- A name from the old order that is nowhere in the panel today -- its addon
    -- is disabled, say -- keeps its slot rather than being dropped and coming
    -- back at the end of the grid whenever the addon is switched on again.
    local present = {}
    for _, entry in ipairs(names) do
        present[entry] = true
    end
    for oldIndex, old in ipairs(ns.db.buttonOrder) do
        if not present[old] then
            present[old] = true
            table.insert(names, math.min(oldIndex, #names + 1), old)
        end
    end

    ns.db.buttonOrder = names

    ns.InvalidateButtonCache()
    if ns.RefreshButtonLayout then
        ns.RefreshButtonLayout()
    end
    if ns.RefreshOptions then
        ns.RefreshOptions()
    end
    return true
end

-- Back to alphabetical: drop every remembered slot, including the ones held for
-- buttons that are not loaded.
function ns.ResetButtonOrder()
    if not ns.db or #ns.db.buttonOrder == 0 then
        return false
    end

    ns.db.buttonOrder = {}

    ns.InvalidateButtonCache()
    if ns.RefreshButtonLayout then
        ns.RefreshButtonLayout()
    end
    if ns.RefreshOptions then
        ns.RefreshOptions()
    end
    return true
end

local function Rebuild()
    local all, seen = {}, {}

    local function add(frame)
        if IsMinimapButton(frame) and not seen[frame] then
            seen[frame] = true
            all[#all + 1] = frame
        end
    end

    -- 1. Ask LibDBIcon, which is where nearly every modern button lives.
    local lib = LibStub and LibStub("LibDBIcon-1.0", true)
    if lib then
        if type(lib.GetButtonList) == "function" and type(lib.GetMinimapButton) == "function" then
            local ok, list = pcall(lib.GetButtonList, lib)
            if ok and type(list) == "table" then
                for _, name in ipairs(list) do
                    local ok2, button = pcall(lib.GetMinimapButton, lib, name)
                    if ok2 then
                        add(button)
                    end
                end
            end
        elseif type(lib.objects) == "table" then
            for _, button in pairs(lib.objects) do
                add(button)
            end
        end
    end

    -- 2. Catch buttons from an older embedded LibDBIcon the registry above
    --    missed. Matching on the global's *name* keeps this to one cheap string
    --    compare per global, with no method calls on unknown tables.
    for key, value in pairs(_G) do
        if type(key) == "string" and string.find(key, "^LibDBIcon10_") then
            add(value)
        end
    end

    -- 3. Buttons built without LibDBIcon, found by walking the minimap.
    if ns.db.autoDetect then
        ScanMinimap()
        for frame in pairs(discovered) do
            add(frame)
        end
    end

    -- 4. Anything the scan cannot reach, named by the user.
    for _, name in ipairs(ns.db.extraButtons) do
        add(_G[name])
    end

    -- pairs() order is arbitrary, so sort to keep the grid stable across
    -- sessions: the order you set in the options panel first, then alphabetical
    -- for anything you have never moved.
    local compare = ns.ButtonOrderComparator()
    table.sort(all, function(a, b)
        return compare(ButtonName(a), ButtonName(b))
    end)

    local ignored = IgnoredSet()
    local results = {}
    for _, frame in ipairs(all) do
        if not ignored[ButtonName(frame)] then
            results[#results + 1] = frame
        end
    end

    candidates = all
    cache = results
    cacheValid = true
    return cache
end

function ns.GetMinimapButtons()
    if not ns.db then
        return {}
    end
    if not cacheValid then
        return Rebuild()
    end
    return cache
end

-- Collected *and* ignored, for the options panel's list.
function ns.GetAllButtons()
    ns.QuickScan()
    ns.GetMinimapButtons()
    return candidates
end

-- ===== The collector grid and its toggle =====

local buttonAnchor, toggleTrigger
local showingButtons = false

-- Where each button sat before the grid took it over, so switching it off in
-- the options panel puts it back on the minimap without a reload.
local homes = {}

local function RememberHome(button)
    if homes[button] then
        return
    end
    local packed = { pcall(button.GetPoint, button, 1) }
    homes[button] = {
        parent = button:GetParent(),
        point = packed[1] and packed[2] or nil,
        relativeTo = packed[3],
        relativePoint = packed[4],
        x = packed[5],
        y = packed[6],
        shown = button:IsShown() and true or false,
    }
end

function ns.ReleaseButton(button)
    local home = homes[button]
    if not home then
        return false
    end
    homes[button] = nil

    pcall(function()
        button:ClearAllPoints()
        button:SetParent(home.parent or Minimap or UIParent)
        if home.point then
            button:SetPoint(home.point, home.relativeTo, home.relativePoint, home.x or 0, home.y or 0)
        else
            button:SetPoint("CENTER", Minimap or UIParent, "CENTER")
        end
        if home.shown then
            button:Show()
        else
            button:Hide()
        end
    end)
    return true
end

local function LayoutButtons()
    local db = ns.db
    local row, col = 0, 0

    for _, button in ipairs(ns.GetMinimapButtons()) do
        pcall(function()
            RememberHome(button)
            button:ClearAllPoints()
            button:SetParent(buttonAnchor)
            button:SetPoint("TOPLEFT", buttonAnchor, "TOPLEFT", col * db.buttonSpacing, -row * db.buttonSpacing)
            button:Show()

            col = col + 1
            if col >= db.buttonsPerRow then
                col = 0
                row = row + 1
            end
        end)
    end
end

local function ShowMinimapButtons()
    -- A button created after login lands in the grid the first time you open it.
    ns.QuickScan()
    LayoutButtons()
    if #ns.GetMinimapButtons() > 0 then
        buttonAnchor:Show()
    end
end

function ns.SetButtonsShown(shown)
    if not buttonAnchor then
        return
    end

    showingButtons = shown and true or false
    if showingButtons then
        -- Re-lay out on show: a button registered after login still lands in the grid.
        ShowMinimapButtons()
        buttonAnchor:Show()
    else
        buttonAnchor:Hide()
    end
end

function ns.AreButtonsShown()
    return showingButtons
end

function ns.ToggleButtons()
    ns.SetButtonsShown(not showingButtons)
end

-- Re-run the grid maths after a spacing/per-row change or an ignore-list edit.
function ns.RefreshButtonLayout()
    if not buttonAnchor then
        return
    end

    -- Anything now excluded goes back where it came from.
    local wanted = {}
    for _, button in ipairs(ns.GetMinimapButtons()) do
        wanted[button] = true
    end
    for button in pairs(homes) do
        if not wanted[button] then
            ns.ReleaseButton(button)
        end
    end

    if showingButtons then
        ShowMinimapButtons()
    else
        LayoutButtons()
        buttonAnchor:Hide()
    end
end

function ns.RepositionToggle(minimapShown)
    if not toggleTrigger or not ns.topbg then
        return
    end

    toggleTrigger:ClearAllPoints()
    if minimapShown then
        toggleTrigger:SetPoint("BOTTOMRIGHT", ns.topbg, "BOTTOMRIGHT", 2, 12)
    else
        -- With the minimap hidden the bar is all that is left, so keep the
        -- toggle visible for a few seconds to make it findable.
        toggleTrigger:SetPoint("TOPLEFT", ns.topbg, "TOPLEFT", -20, 3)
        toggleTrigger:SetAlpha(1)
        ns.After(5, function()
            if toggleTrigger then
                toggleTrigger:SetAlpha(0)
            end
        end)
    end
end

-- The button borders are Blizzard-style rings; swap them for the flat forge
-- border so a row of collected buttons reads as one strip.
--
-- ExadTweaks addressed the regions positionally, but its unpack was wrong
-- (`local ok, regions = pcall(...)` keeps only the *first* return, so the
-- indices it read were always nil and the skin silently did nothing). Rather
-- than restore a positional guess, identify the regions by what they are: the
-- ring is whichever texture is still Blizzard's tracking border, and the icon is
-- the ARTWORK-layer texture LibDBIcon draws the addon's own art into.
local function FindRegions(button)
    local packed = { pcall(button.GetRegions, button) }
    if not packed[1] then
        return nil, nil
    end

    local border, icon
    for i = 2, #packed do
        local region = packed[i]
        if type(region) == "table" and region.IsObjectType and region:IsObjectType("Texture") then
            local texture = region.GetTexture and region:GetTexture()
            if not border and type(texture) == "string" and string.find(texture, "TrackingBorder") then
                border = region
            elseif not icon and region.GetDrawLayer and region:GetDrawLayer() == "ARTWORK" then
                icon = region
            end
        end
    end

    return border, icon
end

-- The options panel draws each row with the button's own icon, which is far
-- easier to match up with the minimap than a frame name is.
function ns.GetButtonIcon(button)
    if type(button) ~= "table" then
        return nil
    end

    local function TextureOf(region)
        if type(region) ~= "table" or type(region.GetTexture) ~= "function" then
            return nil
        end
        local ok, texture = pcall(region.GetTexture, region)
        if ok and type(texture) == "string" and texture ~= "" then
            return texture
        end
        return nil
    end

    -- LibDBIcon keeps the icon on the button as `.icon`.
    local texture = TextureOf(button.icon)
    if texture then
        return texture
    end

    if type(button.GetNormalTexture) == "function" then
        local ok, normal = pcall(button.GetNormalTexture, button)
        if ok then
            texture = TextureOf(normal)
            if texture then
                return texture
            end
        end
    end

    local _, icon = FindRegions(button)
    return TextureOf(icon)
end

-- Frames the click-to-add picker will hit-test against. Wider than the collect
-- scan on purpose: the whole point is to reach a button the scan did not find,
-- including ones parked on UIParent next to the minimap.
function ns.GetPickCandidates()
    local list, seen = {}, {}

    local function consider(frame)
        if seen[frame] or not IsMinimapButton(frame) then
            return
        end
        seen[frame] = true

        local name = ButtonName(frame)
        if name == "" or string.find(name, "^ExadMinimap") then
            return
        end
        if type(frame.IsVisible) ~= "function" or not frame:IsVisible() then
            return
        end

        local width = frame.GetWidth and frame:GetWidth() or 0
        local height = frame.GetHeight and frame:GetHeight() or 0
        if width < 8 or width > 64 or height < 8 or height > 64 then
            return
        end

        list[#list + 1] = frame
    end

    for _, rootName in ipairs(SCAN_ROOTS) do
        for _, child in ipairs(Children(_G[rootName])) do
            pcall(consider, child)
        end
    end
    for _, child in ipairs(Children(buttonAnchor)) do
        pcall(consider, child)
    end
    for _, child in ipairs(Children(UIParent)) do
        pcall(consider, child)
    end

    return list
end

local function SkinButton(button)
    local borderIcon, icon = FindRegions(button)

    if borderIcon then
        if borderIcon.SetTexture then
            borderIcon:SetTexture(MEDIA .. "artifactforge")
        end
        if borderIcon.SetTexCoord then
            borderIcon:SetTexCoord(0.216797, 0.324219, 0.826172, 0.879883)
        end
        borderIcon:ClearAllPoints()
        borderIcon:SetPoint("CENTER", button, "CENTER")
        if borderIcon.SetSize then
            borderIcon:SetSize(28, 28)
        end
        if borderIcon.SetDrawLayer then
            borderIcon:SetDrawLayer("OVERLAY", 1)
        end
        if borderIcon.Show then
            borderIcon:Show()
        end
        if borderIcon.SetVertexColor then
            borderIcon:SetVertexColor(0.1, 0.1, 0.1, 1.0)
        end
    end

    if icon then
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", button, "CENTER")
        if icon.SetSize then
            icon:SetSize(22, 22)
        end
        if icon.SetTexCoord then
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
    end
end

-- BugSack is worth an exception: when it goes red there is an error waiting, so
-- pull just that button back onto the minimap even while the grid is collapsed.
local function HookBugSack(button)
    local ldb = _G["BugSackLDB"]
    if button ~= _G["LibDBIcon10_BugSack"] or not ldb or not ldb.Update then
        return
    end

    hooksecurefunc(ldb, "Update", function()
        pcall(function()
            if buttonAnchor:IsShown() then
                return
            end

            if ldb.icon == "Interface\\AddOns\\BugSack\\Media\\icon_red" then
                button:ClearAllPoints()
                button:SetParent(Minimap)
                button:SetPoint("TOPRIGHT", Minimap, "TOPRIGHT", 10, -5)
                button:SetFrameLevel(999)
                button:Show()
            elseif ldb.icon == "Interface\\AddOns\\BugSack\\Media\\icon" then
                ShowMinimapButtons()
                buttonAnchor:Hide()
            end
        end)
    end)
end

function ns.SetupButtonCollector()
    local db = ns.db

    -- The grid normally hangs under the zone bar; without the square skin there
    -- is no bar, so fall back to the bottom-left of the minimap itself.
    local anchorParent = ns.topbg or Minimap
    if not anchorParent then
        return
    end

    buttonAnchor = CreateFrame("Frame", "ExadMinimapButtonAnchor", MinimapCluster or UIParent)
    buttonAnchor:SetSize(1, 1)
    if ns.topbg then
        buttonAnchor:SetPoint("TOPLEFT", ns.topbg, "BOTTOMLEFT", -2, 0)
    else
        buttonAnchor:SetPoint("TOPLEFT", Minimap, "BOTTOMLEFT", 0, -2)
    end
    buttonAnchor:Hide()

    -- Buttons register during load, so do the first pass on the next frame and
    -- collapse the grid immediately: hidden is the default state.
    ns.After(0, function()
        pcall(ShowMinimapButtons)
        buttonAnchor:Hide()

        for _, button in ipairs(ns.GetMinimapButtons()) do
            pcall(HookBugSack, button)
            if db.skinButtons then
                pcall(SkinButton, button)
            end
        end
    end)

    -- ===== Toggle icon on the zone bar =====

    toggleTrigger = CreateFrame("Frame", "ExadMinimapToggle", anchorParent)
    toggleTrigger:SetSize(21, 21)
    if ns.topbg then
        toggleTrigger:SetPoint("BOTTOMRIGHT", ns.topbg, "BOTTOMRIGHT", 2, 12)
    else
        toggleTrigger:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 0, 0)
    end
    toggleTrigger:EnableMouse(true)

    local iconTexture = toggleTrigger:CreateTexture(nil, "OVERLAY")
    iconTexture:SetAllPoints()
    iconTexture:SetTexture(MEDIA .. "transmogrify")
    iconTexture:SetSize(36, 30)
    iconTexture:SetTexCoord(0.507812, 0.578125, 0.300781, 0.359375)
    iconTexture:Show()

    -- Fade the icon out once you have had time to find it. It stays clickable,
    -- and hovering brings it back.
    if db.toggleFadeDelay and db.toggleFadeDelay > 0 then
        ns.After(db.toggleFadeDelay, function()
            if toggleTrigger and not showingButtons then
                toggleTrigger:SetAlpha(0)
            end
        end)
    end

    toggleTrigger:SetScript("OnMouseUp", ns.ToggleButtons)

    toggleTrigger:SetScript("OnEnter", function(trigger)
        if GameTooltip then
            GameTooltip:SetOwner(trigger, "ANCHOR_TOPRIGHT")
            GameTooltip:SetText("Click to show or hide minimap buttons", 1, 1, 1)
            GameTooltip:Show()
        end
        trigger:SetAlpha(1)
    end)

    toggleTrigger:SetScript("OnLeave", function(trigger)
        if GameTooltip and GameTooltip.Hide then
            GameTooltip:Hide()
        end
        if not showingButtons then
            trigger:SetAlpha(0)
        end
    end)
end
