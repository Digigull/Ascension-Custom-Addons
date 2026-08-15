local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")
--[[
	WARNING: These functions are dependant on functions existing in the calling module
	This is not good code practice beyond reducing the code duplication
]]


--[[
	Creates a simple dropdown list for selecting a single predefined option
]]
function PasslootBiS:CreateSimpleDropdown(module, module_name, frame_name, module_tooltip)
	local Widget = CreateFrame("Frame", frame_name, nil, "UIDropDownMenuTemplate")
	Widget:EnableMouse(true)
	Widget:SetHitRectInsets(15, 15, 0, 0)
	_G[Widget:GetName() .. "Text"]:SetJustifyH("CENTER")
	UIDropDownMenu_SetWidth(Widget, 120)
	Widget:SetScript("OnEnter", function() self:ShowTooltip(module_name, module_tooltip) end)
	Widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local Button = _G[Widget:GetName() .. "Button"]
	Button:SetScript("OnEnter", function() self:ShowTooltip(module_name, module_tooltip) end)
	Button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local Title = Widget:CreateFontString(Widget:GetName() .. "Title", "BACKGROUND", "GameFontNormalSmall")
	Title:SetParent(Widget)
	Title:SetPoint("BOTTOMLEFT", Widget, "TOPLEFT", 20, 0)
	Title:SetText(module_name)
	Widget:SetParent(nil)
	Widget:Hide()
	Widget.initialize = function(...) module:DropDown_Init(...) end
	Widget.YPaddingTop = Title:GetHeight()
	Widget.Height = Widget:GetHeight() + Widget.YPaddingTop
	Widget.XPaddingLeft = -15
	Widget.XPaddingRight = -15
	Widget.Width = Widget:GetWidth() + Widget.XPaddingLeft + Widget.XPaddingRight
	Widget.PreferredPriority = 4
	Widget.Info = {
		module_name,
		module_tooltip,
	}
	return Widget
end

--[[
	Creates a text entry box with a checkbox
]]
function PasslootBiS:CreateTextBoxOptionalCheckBox(module, module_name, frame_name, module_tooltip, ...)
	local Widget = CreateFrame("Frame", frame_name)

	local TextBox = CreateFrame("EditBox", frame_name .. "TextBox")
	TextBox:SetBackdrop({
		["bgFile"] = "Interface\\Tooltips\\UI-Tooltip-Background",
		["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["tile"] = true,
		["insets"] = {
			["top"] = 5,
			["bottom"] = 5,
			["left"] = 5,
			["right"] = 5,
		},
		["tileSize"] = 32,
		["edgeSize"] = 16,
	})
	TextBox:SetBackdropColor(0, 0, 0, 0.95)
	TextBox:SetFontObject(ChatFontNormal)
	TextBox:SetTextInsets(6, 6, 6, 6)
	TextBox:SetHeight(26)
	TextBox:SetWidth(160)
	TextBox:SetMaxLetters(200)
	-- TextBox:SetHistoryLines(0)
	TextBox:SetAutoFocus(false)
	TextBox:SetScript("OnEnter", function() self:ShowTooltip(module_name, module_tooltip) end)
	TextBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
	TextBox:SetScript("OnEscapePressed", function(Frame) Frame:ClearFocus() end)
	TextBox:SetScript("OnEditFocusGained", function(Frame) Frame:HighlightText() end)
	TextBox:SetScript("OnEditfocusLost", function(Frame)
		Frame:HighlightText(0, 0)
		module.Widget:DisplayWidget()
	end)
	TextBox:SetScript("OnEnterPressed", function(Frame)
		module.SetItemName(module, Frame)
		Frame:ClearFocus()
	end)
	local Title = TextBox:CreateFontString(TextBox:GetName() .. "Title", "BACKGROUND", "GameFontNormalSmall")
	Title:SetParent(TextBox)
	Title:SetPoint("BOTTOMLEFT", TextBox, "TOPLEFT", 3, 0)
	Title:SetText(module_name)
	TextBox:SetParent(Widget)
	TextBox:SetPoint("BOTTOMLEFT", Widget, "BOTTOMLEFT", 0, 0)
	Widget.TextBox = TextBox

	local checkbox_name, checkbox_desc = ...
	local CheckBox
	if checkbox_name then
		CheckBox = CreateFrame("CheckButton", frame_name .. "CheckBox", Widget, "UICheckButtonTemplate")
		CheckBox:SetHeight(24)
		CheckBox:SetWidth(24)
		CheckBox:SetHitRectInsets(0, -60, 0, 0)
		CheckBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
		CheckBox:SetScript("OnClick", function(...) module:Exact_OnClick(...) end)
		CheckBox:SetScript("OnEnter", function() self:ShowTooltip(checkbox_name, checkbox_desc) end)
		_G[CheckBox:GetName() .. "Text"]:SetText(checkbox_name)
		CheckBox:SetPoint("BOTTOMLEFT", TextBox, "BOTTOMRIGHT", 5, 0)
		Widget.CheckBox = CheckBox
	end

	Widget:Hide()
	Widget:SetHeight(TextBox:GetHeight())
	Widget.YPaddingTop = Title:GetHeight() + 1
	Widget.YPaddingBottom = 4
	Widget.Height = Widget:GetHeight() + Widget.YPaddingTop + Widget.YPaddingBottom
	if checkbox_name then
		Widget:SetWidth(TextBox:GetWidth() + 5 + CheckBox:GetWidth() + 30)
	else
		Widget:SetWidth(TextBox:GetWidth() + 30)
	end
	Widget.PreferredPriority = 14
	Widget.Info = {
		module_name,
		module_tooltip,
	}
	return Widget
end

--[[
	Creates a dropdown list that includes edit boxes for custom values
]]
function PasslootBiS:CreateDropDownEditBox(module, dropdownframe_name)
	local DropDownEditBox = CreateFrame("EditBox", dropdownframe_name)
	DropDownEditBox:Hide()
	DropDownEditBox:SetParent(nil)
	DropDownEditBox:SetFontObject(ChatFontNormal)
	DropDownEditBox:SetMaxLetters(50) -- Was 8
	DropDownEditBox:SetAutoFocus(true)
	DropDownEditBox:SetScript("OnEnter", function(Frame)
		CloseDropDownMenus(Frame:GetParent():GetParent():GetID() + 1)
		UIDropDownMenu_StopCounting(Frame:GetParent():GetParent())
	end)
	DropDownEditBox:SetScript("OnEnterPressed", function(Frame)
		module:DropDown_OnClick(Frame) -- Calls Hide(), ClearAllPoints() and SetParent(nil)
		-- CloseMenus() only hides the DropDownList2, not this object, and even tho i will set parent to nil, i might as well cover bases
		CloseMenus()
	end)
	DropDownEditBox:SetScript("OnEscapePressed", function(Frame)
		Frame:Hide()
		Frame:ClearAllPoints()
		Frame:SetParent(nil)
		CloseMenus()
	end)
	DropDownEditBox:SetScript("OnEditFocusGained",
		function(Frame) UIDropDownMenu_StopCounting(Frame:GetParent():GetParent()) end)
	return DropDownEditBox
end
