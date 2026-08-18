local ADDON, ns = ...

-- Interface > AddOns > ExadMinimap.
--
-- Two pages: the settings that used to live behind /exadmm, and a Buttons page
-- that lists everything the collector can see. Buttons that never registered
-- with LibDBIcon are found by walking the minimap's children (see buttons.lua);
-- anything that walk cannot reach is added by clicking it, or by name.

local PANEL_TITLE = "|cff009cffExadMinimap|r"
local RELOAD_MARK = "|cffffd200*|r"

local mainPanel, buttonPanel, mainCategory
local refreshers = {}
local refreshing = false

-- ===== Small widget helpers =====

local function AddRefresher(func)
    refreshers[#refreshers + 1] = func
end

local function CreateHeader(panel, text, x, y)
    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", x, y)
    header:SetText(text)
    header:SetJustifyH("LEFT")
    return header
end

local function CreateLabel(panel, text, x, y, width)
    local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", x, y)
    label:SetJustifyH("LEFT")
    if width then
        label:SetWidth(width)
    end
    label:SetText(text)
    return label
end

local function CreateCheck(panel, id, key, label, tooltip, onChange)
    local check = CreateFrame("CheckButton", "ExadMinimapOption" .. id, panel, "InterfaceOptionsCheckButtonTemplate")
    _G[check:GetName() .. "Text"]:SetText(label)
    check.tooltipText = label
    check.tooltipRequirement = tooltip

    check:SetScript("OnClick", function(self)
        local value = self:GetChecked() and true or false
        if PlaySound then
            PlaySound(value and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
        end
        ns.db[key] = value
        if onChange then
            onChange(value)
        end
    end)

    AddRefresher(function()
        check:SetChecked(ns.db[key])
    end)

    return check
end

local function Round(value, step)
    if not step or step == 0 then
        return value
    end
    return math.floor(value / step + 0.5) * step
end

local function CreateSlider(panel, id, key, label, minVal, maxVal, step, onChange)
    local slider = CreateFrame("Slider", "ExadMinimapOption" .. id, panel, "OptionsSliderTemplate")
    slider:SetWidth(200)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)

    local text = _G[slider:GetName() .. "Text"]
    _G[slider:GetName() .. "Low"]:SetText(minVal)
    _G[slider:GetName() .. "High"]:SetText(maxVal)

    local function Describe(value)
        text:SetText(label .. ": " .. string.format(step % 1 == 0 and "%d" or "%.2f", value))
    end

    slider:SetScript("OnValueChanged", function(self, value)
        local rounded = Round(value, step)
        if self:GetValue() ~= rounded then
            self:SetValue(rounded)
            return
        end
        Describe(rounded)
        if refreshing then
            return
        end
        ns.db[key] = rounded
        if onChange then
            onChange(rounded)
        end
    end)

    AddRefresher(function()
        slider:SetValue(ns.db[key])
        Describe(ns.db[key])
    end)

    return slider
end

local function CreateButton(panel, id, label, width, onClick)
    local button = CreateFrame("Button", "ExadMinimapOption" .. id, panel, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateReloadButton(panel, id)
    local reload = CreateButton(panel, "Reload" .. id, "Reload UI", 100, function()
        ReloadUI()
    end)
    reload:SetPoint("BOTTOMRIGHT", -16, 16)
    return reload
end

-- ===== Highlighting a real button on the minimap =====
--
-- Hovering a row in the list, or a button while picking, outlines the actual
-- frame so there is never a guess about which "LibDBIcon10_Something" is which.

local highlight

local function HighlightFrame(frame)
    if not highlight then
        highlight = ns.CreateBackdropFrame("ExadMinimapHighlight", UIParent)
        highlight:SetFrameStrata("FULLSCREEN_DIALOG")
        highlight:SetFrameLevel(100)
        if highlight.SetBackdrop then
            highlight:SetBackdrop({
                edgeFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND",
                edgeSize = 2,
            })
            highlight:SetBackdropBorderColor(1, 0.82, 0, 1)
        end
        highlight:Hide()
    end

    if not frame or type(frame.GetLeft) ~= "function" or not frame:GetLeft() or not frame:IsVisible() then
        highlight:Hide()
        return
    end

    highlight:ClearAllPoints()
    highlight:SetPoint("TOPLEFT", frame, "TOPLEFT", -3, 3)
    highlight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 3, -3)
    highlight:Show()
end

local function ClearHighlight()
    if highlight then
        highlight:Hide()
    end
end

-- ===== Click-to-add picker =====
--
-- A full-screen frame swallows the click so the button's own OnClick never
-- fires, then the frame under the cursor is worked out by hit-testing the
-- candidate list rather than by asking for mouse focus (which would only ever
-- return the overlay itself).

local picker, pickerLabel, pickerCandidates, pickerCurrent, pickerRestoreGrid

local function FrameUnderCursor(list)
    local cursorX, cursorY = GetCursorPosition()
    local best, bestArea, bestLevel

    for _, frame in ipairs(list) do
        pcall(function()
            if not frame:IsVisible() then
                return
            end

            local scale = frame:GetEffectiveScale()
            if not scale or scale == 0 then
                return
            end

            local x, y = cursorX / scale, cursorY / scale
            local left, right = frame:GetLeft(), frame:GetRight()
            local top, bottom = frame:GetTop(), frame:GetBottom()
            if not left or not right or not top or not bottom then
                return
            end

            if x >= left and x <= right and y >= bottom and y <= top then
                local area = (right - left) * (top - bottom)
                local level = frame:GetFrameLevel() or 0
                -- Prefer whatever is drawn on top; break ties with the smaller
                -- frame, which is the button rather than the thing behind it.
                if not best or level > bestLevel or (level == bestLevel and area < bestArea) then
                    best, bestArea, bestLevel = frame, area, level
                end
            end
        end)
    end

    return best
end

local function StopPicker(message, isError)
    if picker then
        picker:Hide()
    end
    ClearHighlight()
    pickerCandidates, pickerCurrent = nil, nil

    if pickerRestoreGrid ~= nil then
        if ns.SetButtonsShown then
            ns.SetButtonsShown(pickerRestoreGrid)
        end
        pickerRestoreGrid = nil
    end

    if message then
        ns.Print((isError and "|cffff5555" or "") .. message .. (isError and "|r" or ""))
    end
end

local function PickFrame(frame)
    if not frame then
        StopPicker("nothing there to add - try again with /exadmm pick.", true)
        return
    end

    local name = ns.ButtonName(frame)
    if name == "" then
        StopPicker("that button has no frame name, so it cannot be saved. Use /framestack to find a named parent.", true)
        return
    end

    local collected = false
    for _, button in ipairs(ns.GetMinimapButtons()) do
        if button == frame then
            collected = true
            break
        end
    end

    ns.SetIgnored(name, false)
    local added = ns.AddExtraButton(name)

    if collected and not added then
        StopPicker(name .. " is already collected.")
    else
        StopPicker("added " .. name .. ".")
    end
end

local function EnsurePicker()
    if picker then
        return picker
    end

    picker = CreateFrame("Frame", "ExadMinimapPicker", UIParent)
    picker:SetAllPoints(UIParent)
    picker:SetFrameStrata("FULLSCREEN_DIALOG")
    picker:SetFrameLevel(50)
    picker:SetToplevel(true)
    picker:EnableMouse(true)
    picker:EnableKeyboard(true)
    picker:Hide()

    local banner = ns.CreateBackdropFrame(nil, picker)
    banner:SetPoint("TOP", UIParent, "TOP", 0, -120)
    banner:SetSize(420, 64)
    if banner.SetBackdrop then
        banner:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND",
            edgeFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND",
            edgeSize = 2,
        })
        banner:SetBackdropColor(0, 0, 0, 0.85)
        banner:SetBackdropBorderColor(1, 0.82, 0, 1)
    end

    local title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Click the minimap button you want to add")

    local hint = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
    hint:SetText("Right-click or press any key to cancel")

    pickerLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pickerLabel:SetPoint("TOP", hint, "BOTTOM", 0, -6)
    pickerLabel:SetText("")

    local elapsed = 0
    picker:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + delta
        if elapsed < 0.05 then
            return
        end
        elapsed = 0

        pickerCurrent = FrameUnderCursor(pickerCandidates or {})
        HighlightFrame(pickerCurrent)

        if pickerCurrent then
            local name = ns.ButtonName(pickerCurrent)
            pickerLabel:SetText(name ~= "" and ("|cff00ff00" .. name .. "|r") or "|cffff5555unnamed frame|r")
        else
            pickerLabel:SetText("")
        end
    end)

    picker:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            -- Hit-test again rather than trusting the throttled OnUpdate, so a
            -- click that lands between ticks still picks what is under it.
            PickFrame(FrameUnderCursor(pickerCandidates or {}))
        else
            StopPicker("cancelled.")
        end
    end)

    -- The overlay holds keyboard focus while it is up, so every key that is not
    -- a modifier gets out of it. Nothing here is worth trapping input for.
    local MODIFIERS = {
        LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
    }

    picker:SetScript("OnKeyDown", function(self, key)
        if not MODIFIERS[key] then
            StopPicker("cancelled.")
        end
    end)

    picker:SetScript("OnHide", function()
        ClearHighlight()
    end)

    return picker
end

function ns.StartButtonPicker()
    if not ns.db then
        return
    end

    EnsurePicker()

    -- Show the grid while picking so a button that is already collected can be
    -- seen (and identified) alongside the ones still on the minimap.
    if ns.AreButtonsShown and ns.SetButtonsShown then
        pickerRestoreGrid = ns.AreButtonsShown()
        ns.SetButtonsShown(true)
    end

    pickerCandidates = ns.GetPickCandidates and ns.GetPickCandidates() or {}
    pickerCurrent = nil
    pickerLabel:SetText("")
    picker:Show()
end

-- ===== The button list =====

local listScroll, listChild, listRows, listEmptyText
local moveUpButton, moveDownButton, resetOrderButton, orderHint

-- The selected row, held by frame *name* rather than by row or frame, so it
-- survives the list being rebuilt under it (a rescan, an ignore toggle, the
-- reorder itself). A name that stops having a row simply stops being selected.
local selectedName

local RefreshList

local function SelectButton(name)
    if not name or name == "" then
        return
    end
    selectedName = name
    RefreshList()
end

local function IsCollected(frame)
    for _, button in ipairs(ns.GetMinimapButtons()) do
        if button == frame then
            return true
        end
    end
    return false
end

local function BuildEntries()
    local entries, named = {}, {}

    for _, frame in ipairs(ns.GetAllButtons and ns.GetAllButtons() or {}) do
        local name = ns.ButtonName(frame)
        if name ~= "" then
            named[name] = true
        end
        entries[#entries + 1] = {
            frame = frame,
            name = name,
            manual = ns.IsExtraButton(name),
            ignored = ns.IsIgnored(name),
        }
    end

    -- Names the user tracked by hand whose frame is not there right now: the
    -- addon may be disabled, or the name may simply be wrong.
    for _, name in ipairs(ns.db.extraButtons) do
        if not named[name] then
            entries[#entries + 1] = { name = name, manual = true, missing = true, ignored = ns.IsIgnored(name) }
        end
    end

    -- Same comparator the grid uses (buttons.lua), so the order of the rows is
    -- the order of the buttons under the minimap.
    local compare = ns.ButtonOrderComparator()
    table.sort(entries, function(a, b)
        return compare(a.name or "", b.name or "")
    end)

    return entries
end

local ROW_HEIGHT = 24

local function CreateRow(index)
    local row = CreateFrame("Frame", "ExadMinimapButtonRow" .. index, listChild)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
    row:EnableMouse(true)

    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetTexture(1, 1, 1, 0.05)
    row.stripe:Hide()

    -- Drawn after the hover stripe so it stays visible while the cursor is on
    -- the row it marks.
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetTexture(1, 0.82, 0, 0.20)
    row.selection:Hide()

    row.check = CreateFrame("CheckButton", "ExadMinimapButtonRow" .. index .. "Check", row, "UICheckButtonTemplate")
    row.check:SetSize(22, 22)
    row.check:SetPoint("LEFT", 2, 0)
    row.check:SetScript("OnClick", function(self)
        local entry = row.entry
        if not entry or entry.name == "" then
            self:SetChecked(false)
            return
        end
        ns.SetIgnored(entry.name, not self:GetChecked())
    end)
    row.check:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Collect this button", 1, 1, 1)
        GameTooltip:AddLine("Unchecked leaves it on the minimap where its own addon put it.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row.check:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.label:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.status:SetPoint("RIGHT", -26, 0)
    row.status:SetJustifyH("RIGHT")

    row.remove = CreateFrame("Button", "ExadMinimapButtonRow" .. index .. "Remove", row, "UIPanelButtonTemplate")
    row.remove:SetSize(20, 18)
    row.remove:SetText("x")
    row.remove:SetPoint("RIGHT", -2, 0)
    row.remove:SetScript("OnClick", function()
        local entry = row.entry
        if entry and entry.name and entry.name ~= "" then
            ns.RemoveExtraButton(entry.name)
        end
    end)
    row.remove:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Stop tracking this name", 1, 1, 1)
        GameTooltip:Show()
    end)
    row.remove:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row:SetScript("OnMouseUp", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then
            return
        end
        local entry = self.entry
        if entry and entry.name and entry.name ~= "" then
            SelectButton(entry.name)
        end
    end)

    row:SetScript("OnEnter", function(self)
        self.stripe:Show()
        if self.entry then
            HighlightFrame(self.entry.frame)
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.stripe:Hide()
        ClearHighlight()
    end)

    return row
end

-- Assigns the local forward-declared above, so a row's OnMouseUp can rebuild
-- the list it lives in.
function RefreshList()
    if not listChild then
        return
    end

    local entries = BuildEntries()

    -- Where the selection sits now, and which rows are the ends of the run that
    -- can be reordered. Unnamed frames cannot hold a slot in the saved order, so
    -- they are not counted as somewhere a button can be moved to.
    local selectedIndex, firstNamed, lastNamed
    for index, entry in ipairs(entries) do
        if entry.name and entry.name ~= "" then
            firstNamed = firstNamed or index
            lastNamed = index
            if entry.name == selectedName then
                selectedIndex = index
            end
        end
    end
    if not selectedIndex then
        selectedName = nil
    end

    for index, entry in ipairs(entries) do
        local row = listRows[index]
        if not row then
            row = CreateRow(index)
            listRows[index] = row
        end

        row.entry = entry
        row.check:SetChecked(not entry.ignored and not entry.missing)
        if entry.name ~= "" and not entry.missing then
            row.check:Enable()
        else
            row.check:Disable()
        end

        local icon = entry.frame and ns.GetButtonIcon(entry.frame)
        if icon then
            row.icon:SetTexture(icon)
            row.icon:Show()
        else
            row.icon:Hide()
        end

        if entry.name == "" then
            row.label:SetText("|cff888888(unnamed frame)|r")
        else
            row.label:SetText(entry.name)
        end

        if entry.missing then
            row.status:SetText("|cffff5555not loaded|r")
        elseif entry.ignored then
            row.status:SetText("|cffffff00on the minimap|r")
        elseif IsCollected(entry.frame) then
            row.status:SetText("|cff00ff00collected|r")
        else
            row.status:SetText("")
        end

        if entry.manual then
            row.remove:Show()
        else
            row.remove:Hide()
        end

        if index == selectedIndex then
            row.selection:Show()
        else
            row.selection:Hide()
        end

        row:Show()
    end

    for index = #entries + 1, #listRows do
        listRows[index]:Hide()
        listRows[index].entry = nil
    end

    listChild:SetHeight(math.max(#entries * ROW_HEIGHT, 1))
    if #entries == 0 then
        listEmptyText:Show()
    else
        listEmptyText:Hide()
    end

    -- The reorder controls follow the selection: with nothing selected, or the
    -- selection already at the end it would move towards, the button is greyed.
    if moveUpButton then
        if selectedIndex and firstNamed and selectedIndex > firstNamed then
            moveUpButton:Enable()
        else
            moveUpButton:Disable()
        end

        if selectedIndex and lastNamed and selectedIndex < lastNamed then
            moveDownButton:Enable()
        else
            moveDownButton:Disable()
        end

        if #ns.db.buttonOrder > 0 then
            resetOrderButton:Enable()
        else
            resetOrderButton:Disable()
        end

        if selectedName then
            orderHint:SetText("Selected: |cffffd200" .. selectedName .. "|r")
        else
            orderHint:SetText("Click a row to select it, then move it.")
        end
    end
end

-- ===== Page 1: settings =====

local function BuildMainPanel()
    local panel = CreateFrame("Frame", "ExadMinimapOptionsPanel", InterfaceOptionsFramePanelContainer or UIParent)
    panel.name = PANEL_TITLE
    mainPanel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(PANEL_TITLE)

    CreateLabel(panel, "Square minimap skin and minimap button collector. Buttons live on the Buttons page.",
        16, -40, 560)

    local conflict = CreateLabel(panel, "", 16, -60, 560)
    conflict:SetTextColor(1, 0.35, 0.35)
    AddRefresher(function()
        conflict:SetText(ns.conflict
            and ("The skin is disabled: " .. ns.conflict .. " is managing the minimap.")
            or "")
    end)

    CreateHeader(panel, "Minimap", 16, -84)

    local square = CreateCheck(panel, "Square", "squareMinimap",
        "Square minimap skin " .. RELOAD_MARK,
        "Squares the minimap, removes Blizzard's border and zoom buttons, and adds the zone/clock bar underneath.")
    square:SetPoint("TOPLEFT", 14, -104)

    local wheel = CreateCheck(panel, "Wheel", "mouseWheelZoom",
        "Mousewheel zoom " .. RELOAD_MARK,
        "Zoom the minimap with the mousewheel, since the +/- buttons are removed by the skin.")
    wheel:SetPoint("TOPLEFT", 14, -130)

    local size = CreateSlider(panel, "Size", "minimapSize", "Minimap size " .. RELOAD_MARK, 120, 260, 5)
    size:SetPoint("TOPLEFT", 30, -176)

    CreateHeader(panel, "Button collector", 16, -216)

    local collector = CreateCheck(panel, "Collector", "buttonCollector",
        "Collect minimap buttons into a grid " .. RELOAD_MARK,
        "Gathers addon minimap buttons under the minimap, shown and hidden by the small icon on the zone bar.")
    collector:SetPoint("TOPLEFT", 14, -236)

    local detect = CreateCheck(panel, "Detect", "autoDetect",
        "Find buttons automatically",
        "Walks the minimap's own children to find buttons that never registered with LibDBIcon.", function()
            ns.InvalidateButtonCache()
            ns.RefreshButtonLayout()
            ns.RefreshOptions()
        end)
    detect:SetPoint("TOPLEFT", 14, -262)

    local skin = CreateCheck(panel, "Skin", "skinButtons",
        "Skin button borders " .. RELOAD_MARK,
        "Replaces each button's Blizzard ring with the flat dark forge border.")
    skin:SetPoint("TOPLEFT", 14, -288)

    local perRow = CreateSlider(panel, "PerRow", "buttonsPerRow", "Buttons per row", 1, 12, 1, function()
        ns.RefreshButtonLayout()
    end)
    perRow:SetPoint("TOPLEFT", 30, -334)

    local spacing = CreateSlider(panel, "Spacing", "buttonSpacing", "Button spacing", 20, 48, 1, function()
        ns.RefreshButtonLayout()
    end)
    spacing:SetPoint("TOPLEFT", 30, -384)

    -- Right-hand column: the live count and the two things you actually want to
    -- reach from here.
    local status = CreateLabel(panel, "", 320, -108, 260)
    AddRefresher(function()
        local collected = ns.GetMinimapButtons and #ns.GetMinimapButtons() or 0
        local total = ns.GetAllButtons and #ns.GetAllButtons() or 0
        status:SetText(collected .. " of " .. total .. " known button(s) collected.")
    end)

    local toggle = CreateButton(panel, "ToggleGrid", "Show/hide buttons", 150, function()
        if ns.ToggleButtons then
            ns.ToggleButtons()
        end
    end)
    toggle:SetPoint("TOPLEFT", 320, -130)

    local manage = CreateButton(panel, "GoButtons", "Manage buttons...", 150, function()
        if InterfaceOptionsFrame_OpenToCategory and buttonPanel then
            InterfaceOptionsFrame_OpenToCategory(buttonPanel)
            InterfaceOptionsFrame_OpenToCategory(buttonPanel)
        end
    end)
    manage:SetPoint("TOPLEFT", 320, -160)

    local fade = CreateSlider(panel, "Fade", "toggleFadeDelay", "Toggle icon fade delay " .. RELOAD_MARK, 0, 120, 5)
    fade:SetPoint("TOPLEFT", 334, -216)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 16, 22)
    note:SetJustifyH("LEFT")
    note:SetText(RELOAD_MARK .. " takes effect after a UI reload.")

    CreateReloadButton(panel, "Main")

    return panel
end

-- ===== Page 2: buttons =====

local function BuildButtonPanel()
    local panel = CreateFrame("Frame", "ExadMinimapButtonsPanel", InterfaceOptionsFramePanelContainer or UIParent)
    panel.name = "Buttons"
    panel.parent = PANEL_TITLE
    buttonPanel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Minimap buttons")

    CreateLabel(panel,
        "Every button the collector can see, in the order the grid lays them out. Uncheck one to leave it on "
        .. "the minimap instead of in the grid; hover a row to outline the real button, click it to select, "
        .. "then use Move up and Move down.",
        16, -40, 560)

    local pick = CreateButton(panel, "Pick", "Add by clicking", 150, function()
        ns.StartButtonPicker()
    end)
    pick:SetPoint("TOPLEFT", 16, -76)

    local rescan = CreateButton(panel, "Rescan", "Rescan", 100, function()
        if ns.ScanForButtons then
            ns.ScanForButtons()
        end
        ns.RefreshButtonLayout()
        ns.RefreshOptions()
    end)
    rescan:SetPoint("LEFT", pick, "RIGHT", 8, 0)

    local nameBox = CreateFrame("EditBox", "ExadMinimapAddByName", panel, "InputBoxTemplate")
    nameBox:SetSize(200, 20)
    nameBox:SetPoint("LEFT", rescan, "RIGHT", 20, 0)
    nameBox:SetAutoFocus(false)
    nameBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local addByName = CreateButton(panel, "AddName", "Add name", 90, function()
        local name = strtrim(nameBox:GetText() or "")
        if name == "" then
            return
        end
        if ns.AddExtraButton(name) then
            ns.Print("now tracking " .. name .. (_G[name] and "." or " (no such frame right now)."))
        else
            ns.Print(name .. " is already tracked.")
        end
        nameBox:SetText("")
        nameBox:ClearFocus()
    end)
    addByName:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)

    nameBox:SetScript("OnEnterPressed", function()
        addByName:Click()
    end)

    listScroll = CreateFrame("ScrollFrame", "ExadMinimapButtonList", panel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 16, -110)
    listScroll:SetPoint("BOTTOMRIGHT", -40, 142)

    local listBorder = ns.CreateBackdropFrame(nil, panel)
    listBorder:SetPoint("TOPLEFT", listScroll, "TOPLEFT", -4, 4)
    listBorder:SetPoint("BOTTOMRIGHT", listScroll, "BOTTOMRIGHT", 4, -4)
    if listBorder.SetBackdrop then
        listBorder:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND",
            edgeFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND",
            edgeSize = 2,
        })
        listBorder:SetBackdropColor(0, 0, 0, 0.35)
        listBorder:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    end

    listChild = CreateFrame("Frame", "ExadMinimapButtonListChild", listScroll)
    listChild:SetSize(520, 1)
    listScroll:SetScrollChild(listChild)
    listRows = {}

    listEmptyText = listChild:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    listEmptyText:SetPoint("TOPLEFT", 6, -6)
    listEmptyText:SetText("No minimap buttons found. Try Rescan, or add one by clicking it.")

    listScroll:HookScript("OnSizeChanged", function(self, width)
        if width and width > 0 then
            listChild:SetWidth(width)
        end
    end)

    -- The template's own wheel handling is not something to count on across
    -- clients, so scroll the bar directly.
    listScroll:EnableMouseWheel(true)
    listScroll:SetScript("OnMouseWheel", function(self, delta)
        local bar = _G[self:GetName() .. "ScrollBar"]
        if not bar then
            return
        end
        local minValue, maxValue = bar:GetMinMaxValues()
        local value = bar:GetValue() - delta * ROW_HEIGHT * 2
        bar:SetValue(math.max(minValue, math.min(maxValue, value)))
    end)

    -- ===== Reordering =====
    --
    -- The order is saved by frame name (ns.db.buttonOrder), so it survives a
    -- reload and an addon that has not loaded yet keeps its slot. Moving a row
    -- relays the grid straight away, whether or not it is open.

    moveUpButton = CreateButton(panel, "MoveUp", "Move up", 100, function()
        if selectedName then
            ns.MoveButton(selectedName, -1)
        end
    end)
    moveUpButton:SetPoint("BOTTOMLEFT", 16, 112)

    moveDownButton = CreateButton(panel, "MoveDown", "Move down", 100, function()
        if selectedName then
            ns.MoveButton(selectedName, 1)
        end
    end)
    moveDownButton:SetPoint("LEFT", moveUpButton, "RIGHT", 8, 0)

    resetOrderButton = CreateButton(panel, "ResetOrder", "Sort A-Z", 100, function()
        ns.ResetButtonOrder()
    end)
    resetOrderButton:SetPoint("LEFT", moveDownButton, "RIGHT", 8, 0)

    local function OrderTooltip(button, title, body)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(title, 1, 1, 1)
            GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    OrderTooltip(moveUpButton, "Move up",
        "Moves the selected button one place earlier in the grid. The grid fills left to right, "
        .. "so the first button is the top-left one.")
    OrderTooltip(moveDownButton, "Move down", "Moves the selected button one place later in the grid.")
    OrderTooltip(resetOrderButton, "Sort A-Z",
        "Forgets the custom order and goes back to sorting by frame name.")

    orderHint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    orderHint:SetPoint("LEFT", resetOrderButton, "RIGHT", 12, 0)
    orderHint:SetWidth(230)
    orderHint:SetJustifyH("LEFT")
    orderHint:SetText("Click a row to select it, then move it.")

    local pickHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    pickHint:SetPoint("BOTTOMLEFT", 16, 88)
    pickHint:SetWidth(560)
    pickHint:SetJustifyH("LEFT")
    pickHint:SetText("Not listed? Use |cffffd200Add by clicking|r, then click the button on the minimap.")

    local stackHint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    stackHint:SetPoint("BOTTOMLEFT", 16, 44)
    stackHint:SetWidth(560)
    stackHint:SetJustifyH("LEFT")
    stackHint:SetText("Last resort: type |cffffd200/framestack|r, hover the button, read its frame name off the "
        .. "list, then type that name in the box above and press Add name. |cffffd200/framestack|r again turns it "
        .. "off. |cffffd200/exadmm name|r also prints the name of whatever is under your cursor.")

    CreateReloadButton(panel, "Buttons")

    return panel
end

-- ===== Cancel support =====
--
-- The panel writes straight to the database as you click, so Cancel has to be
-- able to put it back. A snapshot is taken the first time a page is shown and
-- dropped again on Okay.

local SNAPSHOT_KEYS = {
    "squareMinimap", "minimapSize", "mouseWheelZoom", "buttonCollector",
    "buttonsPerRow", "buttonSpacing", "skinButtons", "toggleFadeDelay", "autoDetect",
}

local snapshot

local function CopyList(list)
    local copy = {}
    for index, value in ipairs(list or {}) do
        copy[index] = value
    end
    return copy
end

local function TakeSnapshot()
    if snapshot then
        return
    end
    snapshot = {}
    for _, key in ipairs(SNAPSHOT_KEYS) do
        snapshot[key] = ns.db[key]
    end
    snapshot.extraButtons = CopyList(ns.db.extraButtons)
    snapshot.ignoredButtons = CopyList(ns.db.ignoredButtons)
    snapshot.buttonOrder = CopyList(ns.db.buttonOrder)
end

local function RestoreSnapshot()
    if not snapshot then
        return
    end
    for _, key in ipairs(SNAPSHOT_KEYS) do
        ns.db[key] = snapshot[key]
    end
    ns.db.extraButtons = CopyList(snapshot.extraButtons)
    ns.db.ignoredButtons = CopyList(snapshot.ignoredButtons)
    ns.db.buttonOrder = CopyList(snapshot.buttonOrder)
    snapshot = nil

    ns.InvalidateButtonCache()
    ns.RefreshButtonLayout()
    ns.RefreshOptions()
end

local function ResetToDefaults()
    for _, key in ipairs(SNAPSHOT_KEYS) do
        ns.db[key] = ns.defaults[key]
    end
    ns.db.extraButtons = CopyList(ns.defaults.extraButtons)
    ns.db.ignoredButtons = {}
    ns.db.buttonOrder = {}

    ns.InvalidateButtonCache()
    ns.RefreshButtonLayout()
    ns.RefreshOptions()
    ns.Print("settings reset to defaults - /reload to apply the ones marked *.")
end

-- ===== Wiring =====

function ns.RefreshOptions()
    if not mainPanel or not ns.db or refreshing then
        return
    end

    refreshing = true
    for _, refresh in ipairs(refreshers) do
        pcall(refresh)
    end
    pcall(RefreshList)
    refreshing = false
end

local built = false

function ns.SetupOptions()
    if built or not ns.db then
        return
    end
    built = true

    BuildMainPanel()
    BuildButtonPanel()

    for _, panel in ipairs({ mainPanel, buttonPanel }) do
        panel.okay = function()
            snapshot = nil
        end
        panel.cancel = RestoreSnapshot
        panel.default = ResetToDefaults
        panel.refresh = function()
            TakeSnapshot()
            ns.RefreshOptions()
        end
        panel:SetScript("OnShow", function()
            TakeSnapshot()
            ns.RefreshOptions()
        end)
    end

    if Settings and Settings.RegisterCanvasLayoutCategory then
        mainCategory = Settings.RegisterCanvasLayoutCategory(mainPanel, mainPanel.name)
        Settings.RegisterAddOnCategory(mainCategory)
        local sub = Settings.RegisterCanvasLayoutSubcategory(mainCategory, buttonPanel, buttonPanel.name)
        Settings.RegisterAddOnCategory(sub)
    else
        InterfaceOptions_AddCategory(mainPanel)
        InterfaceOptions_AddCategory(buttonPanel)
    end

    ns.RefreshOptions()
end

function ns.OpenOptions()
    if not mainPanel then
        ns.Print("the options panel is not available.")
        return
    end

    if Settings and Settings.OpenToCategory and mainCategory then
        Settings.OpenToCategory(mainCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        -- On 3.3.5 the first call only opens the frame; the second one actually
        -- selects the category.
        InterfaceOptionsFrame_OpenToCategory(mainPanel)
        InterfaceOptionsFrame_OpenToCategory(mainPanel)
    end
end
