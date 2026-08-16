local ADDON, ns = ...

local MEDIA = "Interface\\AddOns\\ExadMinimap\\textures\\"

-- Everything below runs once, out of combat, against the minimap cluster only.
-- Minimap widgets are not secure frames, so none of this can produce the
-- "prevented the call of the secure function" storm the full ExadTweaks package
-- can (see COMBAT_TAINT.md in the parent repo).

function ns.ApplyMinimapSkin()
    local db = ns.db
    local colVal = db.borderShade

    -- Blizzard tints the clock's backdrop region; darken it either way so the
    -- clock does not stay bright white against the rest of the UI.
    if TimeManagerClockButton then
        local ok, region = pcall(TimeManagerClockButton.GetRegions, TimeManagerClockButton)
        if ok and region and region.SetVertexColor then
            region:SetVertexColor(colVal, colVal, colVal)
        end
    end

    if not db.squareMinimap then
        if MinimapBorderTop and MinimapBorderTop.SetVertexColor then
            MinimapBorderTop:SetVertexColor(colVal, colVal, colVal)
        end
        return
    end

    -- ===== Suppress the Blizzard minimap furniture =====

    if MiniMapWorldMapButton and MiniMapWorldMapButton.Show and MiniMapWorldMapButton.Hide then
        hooksecurefunc(MiniMapWorldMapButton, "Show", function()
            if MiniMapWorldMapButton then
                MiniMapWorldMapButton:Hide()
            end
        end)
    end

    if MinimapNorthTag and MinimapNorthTag.Show and MinimapNorthTag.Hide then
        hooksecurefunc(MinimapNorthTag, "Show", function()
            if MinimapNorthTag then
                MinimapNorthTag:Hide()
            end
        end)
    end

    local elementsToHide = {
        MinimapBorderTop,
        MinimapToggleButton,
        MinimapZoomIn,
        MinimapZoomOut,
        MinimapNorthTag,
        MiniMapMailBorder,
        MinimapBorder,
        MiniMapWorldMapButton,
    }

    for _, v in pairs(elementsToHide) do
        if v and v.Hide and v.SetAlpha then
            pcall(v.Hide, v)
            pcall(v.SetAlpha, v, 0)
        end
    end

    -- ===== Mousewheel zoom (replaces the removed +/- buttons) =====

    if db.mouseWheelZoom and Minimap and Minimap.EnableMouseWheel and Minimap.SetScript then
        pcall(Minimap.EnableMouseWheel, Minimap, true)
        Minimap:SetScript("OnMouseWheel", function(minimap, delta)
            if not minimap or not minimap.GetZoom or not minimap.SetZoom then return end

            local currentZoom = minimap:GetZoom()
            if not currentZoom then return end

            if delta > 0 and currentZoom < 5 then
                minimap:SetZoom(currentZoom + 1)
            elseif delta < 0 and currentZoom > 0 then
                minimap:SetZoom(currentZoom - 1)
            end
        end)
    end

    -- Tracking moves off the minimap face, so right-click has to open its menu.
    if MiniMapTracking and MiniMapTracking.Hide then
        MiniMapTracking:Hide()
        if Minimap and Minimap.SetScript then
            Minimap:SetScript("OnMouseUp", function(minimap, btn)
                if btn == "RightButton" and ToggleDropDownMenu then
                    ToggleDropDownMenu(1, nil, MiniMapTrackingDropDown, "MiniMapTracking", 0, -5)
                elseif Minimap_OnClick then
                    Minimap_OnClick(minimap)
                end
            end)
        end
    end

    if MiniMapMailFrame and MiniMapMailFrame.ClearAllPoints and MiniMapMailFrame.SetPoint then
        MiniMapMailFrame:ClearAllPoints()
        MiniMapMailFrame:SetPoint("TOPLEFT", -6, 0)
    end

    if MiniMapMailIcon and MiniMapMailIcon.SetTexture then
        MiniMapMailIcon:SetTexture(MEDIA .. "mailicon")
    end

    -- ===== Square the minimap =====

    local MinimapSize = db.minimapSize
    if Minimap and Minimap.SetMaskTexture and Minimap.SetSize then
        pcall(Minimap.SetMaskTexture, Minimap, MEDIA .. "rectangle")

        if MinimapBorderTop and MinimapBorderTop.SetTexture then
            pcall(MinimapBorderTop.SetTexture, MinimapBorderTop, 0)
        end

        Minimap:SetSize(MinimapSize, MinimapSize)

        if Minimap.SetHitRectInsets then
            Minimap:SetHitRectInsets(0, 0, 24, 24)
        end

        local ok, p, r, rp, ofx, ofy = pcall(Minimap.GetPoint, Minimap)
        if ok and p then
            Minimap:ClearAllPoints()
            Minimap:SetPoint(p, r, rp, ofx - 10, ofy)
        end
    end

    if not Minimap then
        return
    end

    -- ===== Replacement border and zone/clock bar =====

    local bg = ns.CreateBackdropFrame(nil, Minimap)
    if bg and bg.SetBackdrop then
        bg:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -1, -21)
        bg:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 1, 21)
        bg:SetBackdrop({ edgeFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND", edgeSize = 2 })
        bg:SetBackdropBorderColor(0.1, 0.1, 0.1, 0.7)
        bg:SetBackdropColor(0.1, 0.1, 0.1)
    end

    if not MinimapCluster then
        return
    end

    local topbg = ns.CreateBackdropFrame(nil, MinimapCluster)
    topbg:SetPoint("TOP", Minimap, "BOTTOM", 0, 21)
    topbg:SetSize(MinimapSize + 2, 15)
    if topbg.SetBackdrop then
        topbg:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND",
            edgeFile = "Interface\\ChatFrame\\CHATFRAMEBACKGROUND",
            edgeSize = 2,
        })
        topbg:SetBackdropBorderColor(0.1, 0.1, 0.1, 0.5)
        topbg:SetBackdropColor(0.1, 0.1, 0.1, 0.3)
    end
    topbg:EnableMouse(false)
    ns.topbg = topbg

    -- ===== Clock into the left of the bar =====

    if TimeManagerClockTicker and MinimapZoneTextButton then
        TimeManagerClockTicker:SetParent(MinimapZoneTextButton)
        if TimeManagerClockTicker.SetFont then
            TimeManagerClockTicker:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        end
        TimeManagerClockTicker:ClearAllPoints()
        TimeManagerClockTicker:SetPoint("LEFT", topbg, "LEFT", 2, 0)
        if TimeManagerClockTicker.SetJustifyH then
            TimeManagerClockTicker:SetJustifyH("LEFT")
        end
    end

    if TimeManagerClockButton and MinimapZoneTextButton and MinimapZoneText then
        TimeManagerClockButton:SetParent(MinimapZoneTextButton)
        if TimeManagerClockButton.SetAlpha then
            TimeManagerClockButton:SetAlpha(0)
        end
        TimeManagerClockButton:ClearAllPoints()
        if TimeManagerClockButton.SetWidth then
            TimeManagerClockButton:SetWidth(42)
        end
        TimeManagerClockButton:SetPoint("LEFT", MinimapZoneText, "LEFT", -52, 0)
    end

    -- ===== Zone text into the right of the bar =====

    if MinimapZoneText then
        if MinimapZoneText.SetFont then
            MinimapZoneText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        end
        if MinimapZoneText.SetJustifyH then
            MinimapZoneText:SetJustifyH("RIGHT")
        end
        if MinimapZoneText.SetWidth then
            MinimapZoneText:SetWidth(120)
        end
        MinimapZoneText:ClearAllPoints()
        MinimapZoneText:SetPoint("RIGHT", topbg, "RIGHT", 0, 0)
    end

    if MinimapZoneTextButton and ToggleMinimap then
        MinimapZoneTextButton:HookScript("OnClick", function()
            pcall(ToggleMinimap)
        end)
        MinimapZoneTextButton:ClearAllPoints()
        MinimapZoneTextButton:SetPoint("RIGHT", topbg, "RIGHT", 2, -1)
    end

    -- ===== Reposition the remaining Blizzard minimap widgets =====

    if MiniMapBattlefieldBorder and MiniMapBattlefieldBorder.Hide then
        MiniMapBattlefieldBorder:Hide()
    end

    if MiniMapBattlefieldFrame then
        MiniMapBattlefieldFrame:ClearAllPoints()
        MiniMapBattlefieldFrame:SetPoint("BOTTOMLEFT", Minimap, "BOTTOMLEFT", -5, 20)
    end

    if MiniMapInstanceDifficulty and MiniMapInstanceDifficulty.GetPoint then
        local ok, r, p, re, xoff, yoff = pcall(MiniMapInstanceDifficulty.GetPoint, MiniMapInstanceDifficulty)
        if ok and r then
            MiniMapInstanceDifficulty:SetParent(Minimap)
            MiniMapInstanceDifficulty:ClearAllPoints()
            MiniMapInstanceDifficulty:SetPoint(r, p, re, 2.5, yoff)
        end
    end

    if MiniMapLFGFrame then
        MiniMapLFGFrame:ClearAllPoints()
        MiniMapLFGFrame:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -14, -6)
        if MiniMapLFGFrameBorder and MiniMapLFGFrameBorder.Hide then
            MiniMapLFGFrameBorder:Hide()
        end
    end

    -- Calendar button: retextured, moved clear of the bar, and faded until hovered.
    if GameTimeFrame then
        if GameTimeFrame.SetNormalTexture then
            GameTimeFrame:SetNormalTexture(MEDIA .. "cal")
        end
        if GameTimeFrame.SetPushedTexture then
            GameTimeFrame:SetPushedTexture("")
        end
        if GameTimeFrame.SetHighlightTexture then
            GameTimeFrame:SetHighlightTexture("")
        end
        if GameTimeFrame.SetScale then
            GameTimeFrame:SetScale(0.8)
        end

        local ok, r, p, re, xoff, yoff = pcall(GameTimeFrame.GetPoint, GameTimeFrame, 1)
        if ok and r then
            GameTimeFrame:ClearAllPoints()
            GameTimeFrame:SetPoint(r, p, re, xoff, yoff - 30)
        end

        if GameTimeFrame.SetAlpha then
            GameTimeFrame:SetAlpha(0)
        end

        GameTimeFrame:HookScript("OnEnter", function(frame)
            if frame and frame.SetAlpha then
                frame:SetAlpha(1)
            end
        end)
        GameTimeFrame:HookScript("OnLeave", function(frame)
            if frame and frame.SetAlpha then
                frame:SetAlpha(0)
            end
        end)
    end

    -- Only nudge the consolidated buff anchor if it is still at Blizzard's
    -- default spot, so a bar addon that already moved it is left alone.
    if ConsolidatedBuffs and ConsolidatedBuffs.GetPoint and UIParent then
        local ok, r, p, re, xoff, yoff = pcall(ConsolidatedBuffs.GetPoint, ConsolidatedBuffs)
        if ok and r == "TOPRIGHT" and p == UIParent and re == "TOPRIGHT"
                and math.ceil(xoff) == -180 and math.ceil(yoff) == -13 then
            ConsolidatedBuffs:ClearAllPoints()
            ConsolidatedBuffs:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -205, -27)
        end
    end

    if MinimapCluster.EnableMouse then
        MinimapCluster:EnableMouse(false)
    end

    -- ===== Tracking icon, reskinned and parked outside the minimap =====

    if MiniMapTrackingIcon and GetTrackingTexture then
        local ok, trackingTexture = pcall(GetTrackingTexture)
        if ok and trackingTexture ~= nil and MiniMapTrackingIcon.GetTexture then
            local currentTexture = MiniMapTrackingIcon:GetTexture()
            if not currentTexture and MiniMapTrackingIcon.SetTexture then
                MiniMapTrackingIcon:SetTexture(trackingTexture)
                if MiniMapTracking and MiniMapTracking.Show then
                    MiniMapTracking:Show()
                end
            end
        end
    end

    if MiniMapTracking and MiniMapTrackingBorder then
        if MiniMapTrackingBorder.SetAtlas then
            pcall(MiniMapTrackingBorder.SetAtlas, MiniMapTrackingBorder, "Forge-ColorSwatchBorder", true)
        end
        if MiniMapTrackingBorder.SetSize then
            MiniMapTrackingBorder:SetSize(22, 22)
        end
        MiniMapTrackingBorder:ClearAllPoints()
        MiniMapTrackingBorder:SetPoint("CENTER", MiniMapTracking, "CENTER")

        if MiniMapTrackingIcon then
            if MiniMapTrackingIcon.SetSize then
                MiniMapTrackingIcon:SetSize(16, 16)
            end
            MiniMapTrackingIcon:ClearAllPoints()
            MiniMapTrackingIcon:SetPoint("CENTER", MiniMapTracking, "CENTER")
            if MiniMapTrackingIcon.SetTexCoord then
                MiniMapTrackingIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            end
        end

        if MinimapBackdrop then
            MiniMapTracking:ClearAllPoints()
            MiniMapTracking:SetPoint("TOPLEFT", MinimapBackdrop, "LEFT", -5, -26)
        end
    end

    -- ===== Keep the bar attached when the minimap itself is toggled off =====

    if Minimap.HookScript then
        Minimap:HookScript("OnShow", function()
            topbg:ClearAllPoints()
            topbg:SetPoint("TOP", Minimap, "BOTTOM", 0, 21)
            if ns.RepositionToggle then
                ns.RepositionToggle(true)
            end
        end)

        Minimap:HookScript("OnHide", function()
            topbg:ClearAllPoints()
            topbg:SetPoint("TOP", MinimapCluster, "TOP", 0, -25)
            if ns.RepositionToggle then
                ns.RepositionToggle(false)
            end
        end)
    end

    -- ===== Ping snitch: show who pinged in the zone text for two seconds =====

    local pingTicker
    if Minimap.RegisterEvent and Minimap.HookScript then
        Minimap:RegisterEvent("MINIMAP_PING")
        Minimap:HookScript("OnEvent", function(map, evt, unit)
            pcall(function()
                if evt ~= "MINIMAP_PING" or unit == "player" or not UnitName then return end

                local name = UnitName(unit)
                if not name or not MinimapZoneText or not MinimapZoneText.SetText then return end

                MinimapZoneText:SetText(name)

                if UnitClass then
                    local _, class = UnitClass(unit)
                    local c = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class])
                        or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
                    if c and MinimapZoneText.SetTextColor then
                        MinimapZoneText:SetTextColor(c.r, c.g, c.b)
                    end
                end

                if pingTicker and pingTicker.Cancel then
                    pingTicker:Cancel()
                    pingTicker = nil
                end

                if Minimap_Update then
                    if C_Timer and C_Timer.NewTimer then
                        pingTicker = C_Timer.NewTimer(2, function()
                            pcall(Minimap_Update)
                            pingTicker = nil
                        end)
                    else
                        ns.After(2, function() pcall(Minimap_Update) end)
                    end
                end
            end)
        end)
    end

    -- LibDBIcon and friends read this to place buttons along a square edge.
    function GetMinimapShape()
        return "SQUARE"
    end
end

-- ===== LFG eye (Blizzard_GroupFinder_VanillaStyle) =====

local lfgDone = false

function ns.ApplyLFGButton()
    if lfgDone or not ns.db or ns.ConflictingAddon() then
        return
    end

    local frame = LFGMinimapFrame
    if not frame then
        return
    end
    lfgDone = true

    if not ns.db.squareMinimap then
        if LFGMinimapFrameBorder and LFGMinimapFrameBorder.SetVertexColor then
            local colVal = ns.db.borderShade
            LFGMinimapFrameBorder:SetVertexColor(colVal, colVal, colVal)
        end
        return
    end

    local function HasActiveEntry()
        return C_LFGList and C_LFGList.HasActiveEntryInfo and C_LFGList.HasActiveEntryInfo()
    end

    if not HasActiveEntry() and frame.SetAlpha then
        frame:SetAlpha(0)
    end

    local borderName = frame:GetName() and (frame:GetName() .. "Border")
    local border = borderName and _G[borderName]
    if border and border.Hide then
        border:Hide()
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -14, -6)

    frame:HookScript("OnEnter", function(f)
        if f and f.GetAlpha and f.SetAlpha and f:GetAlpha() < 1 then
            f:SetAlpha(1)
        end
    end)

    frame:HookScript("OnLeave", function(f)
        if not HasActiveEntry() and f and f.SetAlpha then
            f:SetAlpha(0)
        end
    end)

    -- Hidden by default, visible while actively listed.
    frame:HookScript("OnEvent", function(f, evt)
        if evt == "LFG_LIST_ACTIVE_ENTRY_UPDATE" and f and f.SetAlpha then
            f:SetAlpha(HasActiveEntry() and 1 or 0)
        end
    end)
end
