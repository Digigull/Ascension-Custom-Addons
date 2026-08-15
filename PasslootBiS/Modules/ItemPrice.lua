local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

--[[
Checklist if creating a new module
- first choose an existing module that most closely matches what you want to do
- modify module_key, module_name, module_tooltip to unique values
- make sure to update locales
- Modify SetMatch and GetMatch
- Create/Modify local functions as needed
]]
local module_key = "ItemPrice"
local module_name = L["Item Price"]
local module_tooltip = L["Selected rule will only match items when compared to vendor value."]

local module = PasslootBiS:NewModule(module_name)

module.Choices = {
	{
		["Name"] = L["Any"],
		["Text"] = L["Any"],
		["Value"] = 1,
	},
	{
		["Name"] = L["Equal to"],
		["Text"] = L["Equal to %num%"],
		["Value"] = 2,
	},
	{
		["Name"] = L["Not Equal to"],
		["Text"] = L["Not Equal to %num%"],
		["Value"] = 3,
	},
	{
		["Name"] = L["Less than"],
		["Text"] = L["Less than %num%"],
		["Value"] = 4,
	},
	{
		["Name"] = L["Greater than"],
		["Text"] = L["Greater than %num%"],
		["Value"] = 5,
	},
}
module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{
		module_key,
		-- {
		-- [1] = { Operator, Comparison, Exception }
		-- },
	},
}
module.NewFilterValue_LogicalOperator = 1
module.NewFilterValue_Comparison = 0

function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

local function SetMoney_MoneyInputFrame(Frame, Money)
	local Gold = floor(Money / (COPPER_PER_SILVER * SILVER_PER_GOLD))
	local Silver = floor((Money - (Gold * COPPER_PER_SILVER * SILVER_PER_GOLD)) / COPPER_PER_SILVER)
	local Copper = mod(Money, COPPER_PER_SILVER)
	if (Gold == 0 and Silver == 0 and Copper == 0) then
		Gold, Silver, Copper = "", "", ""
	end
	Frame.Gold:SetText(Gold)
	Frame.Silver:SetText(Silver)
	Frame.Copper:SetText(Copper)
end

local function GetMoney_MoneyInputFrame(Frame)
	local Gold = Frame.Gold:GetNumber()
	local Silver = Frame.Silver:GetNumber()
	local Copper = Frame.Copper:GetNumber()
	local Money = Gold * (COPPER_PER_SILVER * SILVER_PER_GOLD)
	Money = Money + Silver * COPPER_PER_SILVER
	Money = Money + Copper
	return Money
end

function module:CreateEditBox(LeftOffsetX, LeftOffsetY, RightOffsetX, RightOffsetY)
	local Frame = CreateFrame("EditBox")
	Frame:SetAutoFocus(false)
	Frame:SetScript("OnEscapePressed", function(frame) frame:ClearFocus() end)
	Frame:SetScript("OnEditFocusLost", function(frame) frame:HighlightText(0, 0) end)
	Frame:SetScript("OnEditFocusGained", function(frame) frame:HighlightText() end)

	Frame.LeftTexture = Frame:CreateTexture(nil, "BACKGROUND")
	Frame.LeftTexture:SetTexture("Interface\\Common\\Common-Input-Border")
	Frame.LeftTexture:SetTexCoord(0, 0.0625, 0, 0.625)
	Frame.LeftTexture:SetWidth(8)
	Frame.LeftTexture:SetHeight(20)
	Frame.LeftTexture:SetPoint("TOPLEFT", Frame, "TOPLEFT", LeftOffsetX, LeftOffsetY)

	Frame.RightTexture = Frame:CreateTexture(nil, "BACKGROUND")
	Frame.RightTexture:SetTexture("Interface\\Common\\Common-Input-Border")
	Frame.RightTexture:SetTexCoord(0.9375, 1, 0, 0.625)
	Frame.RightTexture:SetWidth(8)
	Frame.RightTexture:SetHeight(20)
	Frame.RightTexture:SetPoint("RIGHT", Frame, "RIGHT", RightOffsetX, RightOffsetY)

	Frame.MiddleTexture = Frame:CreateTexture(nil, "BACKGROUND")
	Frame.MiddleTexture:SetTexture("Interface\\Common\\Common-Input-Border")
	Frame.MiddleTexture:SetTexCoord(0.0625, 0.9375, 0, 0.625)
	Frame.MiddleTexture:SetWidth(10)
	Frame.MiddleTexture:SetHeight(20)
	Frame.MiddleTexture:SetPoint("LEFT", Frame.LeftTexture, "RIGHT")
	Frame.MiddleTexture:SetPoint("RIGHT", Frame.RightTexture, "LEFT")

	return Frame
end

function module:CreateMoneyInputFrame()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(176)
	Frame:SetHeight(18)

	Frame.Gold = self:CreateEditBox(-5, 0, 0, 0)
	Frame.Gold:SetParent(Frame)
	Frame.Gold:SetPoint("TOPLEFT", Frame, "TOPLEFT")
	Frame.Gold:SetWidth(58)
	Frame.Gold:SetHeight(20)
	Frame.Gold:SetNumeric(true)
	Frame.Gold:SetMaxLetters(6)
	Frame.Gold:SetFontObject(ChatFontNormal)
	Frame.Gold:SetScript("OnEnterPressed", function() Frame.Silver:SetFocus() end)
	Frame.Gold:SetScript("OnTabPressed", function()
		if (IsShiftKeyDown()) then
			Frame.Copper:SetFocus()
		else
			Frame.Silver:SetFocus()
		end
	end)
	Frame.Gold:SetScript("OnTextChanged", function() self:SetMoney() end)

	Frame.Gold.IconTexture = Frame.Gold:CreateTexture(nil, "BACKGROUND")
	Frame.Gold.IconTexture:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
	Frame.Gold.IconTexture:SetTexCoord(0, 0.25, 0, 1)
	Frame.Gold.IconTexture:SetWidth(13)
	Frame.Gold.IconTexture:SetHeight(13)
	Frame.Gold.IconTexture:SetPoint("LEFT", Frame.Gold, "RIGHT", 2, 0)

	Frame.Silver = self:CreateEditBox(-5, 0, -10, 0)
	Frame.Silver:SetParent(Frame)
	Frame.Silver:SetPoint("LEFT", Frame.Gold, "RIGHT", 26, 0)
	Frame.Silver:SetWidth(30)
	Frame.Silver:SetHeight(20)
	Frame.Silver:SetNumeric(true)
	Frame.Silver:SetMaxLetters(2)
	Frame.Silver:SetFontObject(ChatFontNormal)
	Frame.Silver:SetScript("OnEnterPressed", function() Frame.Copper:SetFocus() end)
	Frame.Silver:SetScript("OnTabPressed", function()
		if (IsShiftKeyDown()) then
			Frame.Gold:SetFocus()
		else
			Frame.Copper:SetFocus()
		end
	end)
	Frame.Silver:SetScript("OnTextChanged", function() self:SetMoney() end)

	Frame.Silver.IconTexture = Frame.Silver:CreateTexture(nil, "BACKGROUND")
	Frame.Silver.IconTexture:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
	Frame.Silver.IconTexture:SetTexCoord(0.25, 0.5, 0, 1)
	Frame.Silver.IconTexture:SetWidth(13)
	Frame.Silver.IconTexture:SetHeight(13)
	Frame.Silver.IconTexture:SetPoint("LEFT", Frame.Silver, "RIGHT", -8, 0)

	Frame.Copper = self:CreateEditBox(-5, 0, -10, 0)
	Frame.Copper:SetParent(Frame)
	Frame.Copper:SetPoint("LEFT", Frame.Silver, "RIGHT", 16, 0)
	Frame.Copper:SetWidth(30)
	Frame.Copper:SetHeight(20)
	Frame.Copper:SetNumeric(true)
	Frame.Copper:SetMaxLetters(2)
	Frame.Copper:SetFontObject(ChatFontNormal)
	Frame.Copper:SetScript("OnTabPressed", function()
		if (IsShiftKeyDown()) then
			Frame.Silver:SetFocus()
		else
			Frame.Gold:SetFocus()
		end
	end)
	Frame.Copper:SetScript("OnEnterPressed", function()
		Frame.Copper:ClearFocus()
	end)
	Frame.Copper:SetScript("OnTextChanged", function() self:SetMoney() end)

	Frame.Copper.IconTexture = Frame.Copper:CreateTexture(nil, "BACKGROUND")
	Frame.Copper.IconTexture:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
	Frame.Copper.IconTexture:SetTexCoord(0.5, 0.75, 0, 1)
	Frame.Copper.IconTexture:SetWidth(13)
	Frame.Copper.IconTexture:SetHeight(13)
	Frame.Copper.IconTexture:SetPoint("LEFT", Frame.Copper, "RIGHT", -8, 0)

	Frame.SetMoney = SetMoney_MoneyInputFrame
	Frame.GetMoney = GetMoney_MoneyInputFrame
	return Frame
end

function module:CreateDropDown()
	local DropDown = CreateFrame("Frame", "PasslootBiS_Frames_Widgets_ItemPriceComparison", nil, "UIDropDownMenuTemplate")
	DropDown:EnableMouse(true)
	DropDown:SetHitRectInsets(15, 15, 0, 0)
	_G[DropDown:GetName() .. "Text"]:SetJustifyH("CENTER")
	UIDropDownMenu_SetWidth(DropDown, 120)
	DropDown:SetScript("OnEnter",
		function()
			self:ShowTooltip(module_name,
				module_tooltip)
		end)
	DropDown:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local DropDownButton = _G[DropDown:GetName() .. "Button"]
	DropDownButton:SetScript("OnEnter",
		function()
			self:ShowTooltip(module_name,
				module_tooltip)
		end)
	DropDownButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	DropDown.Title = DropDown:CreateFontString(DropDown:GetName() .. "Title", "BACKGROUND", "GameFontNormalSmall")
	DropDown.Title:SetParent(DropDown)
	DropDown.Title:SetPoint("BOTTOMLEFT", DropDown, "TOPLEFT", 20, 0)
	DropDown.Title:SetText(module_name)
	DropDown.initialize = function(...) self:DropDown_Init(...) end
	return DropDown
end

function module:CreateWidget()
	local Frame = CreateFrame("Frame")
	Frame.DropDown = self:CreateDropDown()
	Frame.DropDown:SetParent(Frame)
	Frame.DropDown:SetPoint("BOTTOMLEFT", Frame, "BOTTOMLEFT")

	Frame.MoneyInputFrame = self:CreateMoneyInputFrame()
	Frame.MoneyInputFrame:SetParent(Frame)
	Frame.MoneyInputFrame:SetPoint("LEFT", Frame.DropDown, "RIGHT", 0, 3)

	Frame:SetHeight(math.max(Frame.DropDown:GetHeight() + Frame.DropDown.Title:GetHeight(),
		Frame.MoneyInputFrame:GetHeight()))
	Frame:SetWidth(Frame.DropDown:GetWidth() - 15 + Frame.MoneyInputFrame:GetWidth())
	Frame.YPaddingTop = 0
	Frame.XPaddingLeft = -15
	Frame.XPaddingRight = 0
	Frame.Height = Frame:GetHeight()
	Frame.Width = Frame:GetWidth()
	Frame.Info = {
		module_name,
		module_tooltip,
	}
	Frame:SetParent(nil)
	Frame:Hide()
	Frame.PreferredPriority = 15
	return Frame
end

module.Widget = module:CreateWidget()

-- Local function to get the data or return an empty table if no data found
function module.Widget:GetData(RuleNum)
	return module:GetConfigOption(module_key, RuleNum) or {}
end

function module.Widget:GetNumFilters(RuleNum)
	local Value = self:GetData(RuleNum)
	return #Value
end

function module.Widget:AddNewFilter()
	local Value = self:GetData()
	local NewTable = {
		module.NewFilterValue_LogicalOperator,
		module.NewFilterValue_Comparison,
		false
	}
	table.insert(Value, NewTable)
	module:SetConfigOption(module_key, Value)
end

function module.Widget:RemoveFilter(Index)
	local Value = self:GetData()
	table.remove(Value, Index)
	if (#Value == 0) then
		Value = nil
	end
	module:SetConfigOption(module_key, Value)
end

function module.Widget:DisplayWidget(Index)
	if (Index) then
		module.FilterIndex = Index
	end
	local Value = self:GetData()
	local Value_LogicalOperator = Value[module.FilterIndex][1]
	local Value_Comparison = Value[module.FilterIndex][2]
	UIDropDownMenu_SetText(module.Widget.DropDown, module:GetDropDownText(Value_LogicalOperator))
	module.Widget.MoneyInputFrame:SetMoney(Value_Comparison)
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	local LogicalOperator = Value[Index][1]
	local Comparison = Value[Index][2]
	local Text = module:GetItemPriceText(LogicalOperator, Comparison)
	return Text
end

function module.Widget:IsException(RuleNum, Index)
	local Data = self:GetData(RuleNum)
	return Data[Index][3]
end

function module.Widget:SetException(RuleNum, Index, Value)
	local Data = self:GetData(RuleNum)
	Data[Index][3] = Value
	module:SetConfigOption(module_key, Data)
end

function module.Widget:SetMatch(itemObj, Tooltip)
	module.CurrentMatch = itemObj.vendorPrice
	module.CurrentMatch = module.CurrentMatch or 0
	module:Debug("Item Price: " .. module.CurrentMatch)
end

function module.Widget:GetMatch(RuleNum, Index)
	local Value = self:GetData(RuleNum)
	local LogicalOperator = Value[Index][1]
	local Comparison = Value[Index][2]
	if (LogicalOperator > 1) then
		if (LogicalOperator == 2) then -- Equal To
			if (module.CurrentMatch ~= Comparison) then
				module:Debug("ItemPrice (" .. module.CurrentMatch .. ") ~= " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 3) then -- Not Equal To
			if (module.CurrentMatch == Comparison) then
				module:Debug("ItemPrice (" .. module.CurrentMatch .. ") == " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 4) then -- Less than
			if (module.CurrentMatch >= Comparison) then
				module:Debug("ItemPrice (" .. module.CurrentMatch .. ") >= " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 5) then -- Greater than
			if (module.CurrentMatch <= Comparison) then
				module:Debug("ItemPrice (" .. module.CurrentMatch .. ") <= " .. Comparison)
				return false
			end
		end
	end
	return true
end

function module:DropDown_Init(Frame, Level)
	Level = Level or 1
	local info = {}
	info.checked = false
	info.notCheckable = true
	info.func = function(...) self:DropDown_OnClick(...) end
	info.owner = Frame
	for Key, Value in ipairs(self.Choices) do
		info.text = Value.Name
		info.value = Value.Value
		UIDropDownMenu_AddButton(info, Level)
	end
end

function module:DropDown_OnClick(Frame)
	local Value = self.Widget:GetData()
	local LogicalOperator = Frame.value
	Value[self.FilterIndex][1] = LogicalOperator
	self:SetConfigOption(module_key, Value)
	UIDropDownMenu_SetText(Frame.owner, self:GetDropDownText(LogicalOperator))
end

function module:SetMoney()
	if (not self.FilterIndex) then
		return
	end
	local Value = self.Widget:GetData()
	local Comparison = self.Widget.MoneyInputFrame:GetMoney()
	Value[self.FilterIndex][2] = Comparison
	self:SetConfigOption(module_key, Value)
end

function module:GetItemPriceText(LogicalOperator, Comparison)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == LogicalOperator) then
			return string.gsub(Value.Text, "%%num%%", GetCoinTextureString(Comparison))
		end
	end
end

function module:GetDropDownText(LogicalOperator)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == LogicalOperator) then
			return Value.Name
		end
	end
end
