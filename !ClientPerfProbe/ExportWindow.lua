--[[ ExportWindow.lua — the REQUIRED §6a copy/paste export window.

     This is the ONLY channel that gets data back to Claude: the owner opens it,
     the text is PRE-SELECTED, they press Ctrl+C, and paste. Chat scrollback and
     screenshots are ruled out (README §6a).

     A plain CreateFrame window (NOT a StaticPopup — StaticPopups can't hold
     arbitrary selectable multi-line text and render behind the options frame on
     this client) with a multi-line EditBox in a ScrollFrame. Text is highlighted
     and focused on show. Supports paginated reports (Prev/Next) per §6a.3.

     WoW-facing; syntax-checked only.
]]

local ADDON, ns = ...

local ExportWindow = {}

local frame
local pages = {}
local pageIndex = 1

local function render()
    local eb = frame.editBox
    local text = pages[pageIndex] or ""
    eb:SetText(text)
    eb:HighlightText()          -- pre-select all -> owner just presses Ctrl+C
    eb:SetCursorPosition(0)
    eb:SetFocus()
    if frame.pageLabel then
        if #pages > 1 then
            frame.pageLabel:SetText(("Page %d / %d"):format(pageIndex, #pages))
            frame.prev:Show(); frame.next:Show()
        else
            frame.pageLabel:SetText("")
            frame.prev:Hide(); frame.next:Hide()
        end
    end
end

local function step(delta)
    local n = #pages
    if n <= 1 then return end
    pageIndex = ((pageIndex - 1 + delta) % n) + 1
    render()
end

local function build()
    frame = CreateFrame("Frame", "ClientPerfProbeExport", UIParent)
    frame:SetSize(600, 440)
    frame:SetPoint("CENTER")
    -- No SetToplevel. This window was the reference "never freezes" control while
    -- the drag-freeze was being isolated, on FULLSCREEN_DIALOG + toplevel — and it
    -- never showed the ~1s cold freeze, because the sparse strata makes the raise
    -- cheap. But cheap is not free: the follow-up measurement put each toplevel
    -- raise at ~50ms, paid on EVERY click/drag. Dropping the flag takes that to
    -- zero. Singleton window, so click-to-raise is unused; ExportWindow.Show()
    -- calls Raise() once for front-on-open. See docs/DRAG-FREEZE.md.
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    -- LIGHT backdrop — the Details/DetailsFramework recipe (a 1px WHITE8X8 border + the
    -- flat UI-Tooltip-Background), REPLACING the standard tiled UI-DialogBox parchment +
    -- ornate 32px 9-slice border. MEASURE-FIRST EXPERIMENT (docs/FINDINGS.md "BACKDROP
    -- LEAD"): the ornate UI-DialogBox backdrop is the prime suspect for the one-time
    -- window-drag first-layout stall — every window that spikes uses it, and Details
    -- (which never spikes) systematically avoids it with exactly this light recipe.
    -- Drag the cpp window before/after (owner has abundant "before" captures) to confirm.
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true, tileSize = 64, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
    frame:SetBackdropBorderColor(0.30, 0.30, 0.34, 1)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Client Perf Probe — select all is done for you, press Ctrl+C")
    frame.title = title

    local scroll = CreateFrame("ScrollFrame", "ClientPerfProbeExportScroll", frame,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -36)
    scroll:SetPoint("BOTTOMRIGHT", -34, 48)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetFontObject(ChatFontNormal)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(0)                    -- unlimited; report is bounded/paginated upstream
    eb:SetWidth(540)
    eb:SetScript("OnEscapePressed", function() frame:Hide() end)
    -- keep selection sticky: reselect if the owner clicks in and the text is set
    eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scroll:SetScrollChild(eb)
    frame.editBox = eb

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(90, 22)
    close:SetPoint("BOTTOMRIGHT", -16, 14)
    close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)

    local reselect = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reselect:SetSize(110, 22)
    reselect:SetPoint("RIGHT", close, "LEFT", -8, 0)
    reselect:SetText("Select All")
    reselect:SetScript("OnClick", function() frame.editBox:SetFocus(); frame.editBox:HighlightText() end)

    local prev = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    prev:SetSize(70, 22)
    prev:SetPoint("BOTTOMLEFT", 16, 14)
    prev:SetText("< Prev")
    prev:SetScript("OnClick", function() step(-1) end)
    frame.prev = prev

    local nextb = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    nextb:SetSize(70, 22)
    nextb:SetPoint("LEFT", prev, "RIGHT", 6, 0)
    nextb:SetText("Next >")
    nextb:SetScript("OnClick", function() step(1) end)
    frame.next = nextb

    local pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", nextb, "RIGHT", 10, 0)
    frame.pageLabel = pageLabel
end

-- Show(report) where report is either a plain string or a Report.build() result
-- ({ pages = {...}, text = ... }). Pages get Prev/Next; a string is one page.
function ExportWindow.Show(report)
    if not frame then build() end
    if type(report) == "table" and type(report.pages) == "table" and #report.pages > 0 then
        pages = report.pages
    elseif type(report) == "table" and type(report.text) == "string" then
        pages = { report.text }
    else
        pages = { tostring(report) }
    end
    pageIndex = 1
    frame:Show()
    frame:Raise()   -- front-of-strata on open; replaces the dropped SetToplevel
    render()
end

ns.ExportWindow = ExportWindow
