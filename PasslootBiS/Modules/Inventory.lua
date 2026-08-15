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
local module_key = "Inventory"
local module_name = L["Inventory"]
local module_tooltip = L["Selected rule will only match items when comparing already aquired inventory to this."]

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

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_InventoryComparison"
	local DropDown = PasslootBiS:CreateSimpleDropdown(self, module_name, frame_name, module_tooltip)

	local dropdownframe_name = "PasslootBiS_Frames_Widgets_InventoryDropDownEditBox"
	local DropDownEditBox = PasslootBiS:CreateDropDownEditBox(self, dropdownframe_name)
	return DropDown, DropDownEditBox
end

module.Widget, module.DropDownEditBox = module:CreateWidget(module)

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
	UIDropDownMenu_SetText(module.Widget, module:GetInventoryText(Value_LogicalOperator, Value_Comparison))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	local LogicalOperator = Value[Index][1]
	local Comparison = Value[Index][2]
	local Text = module:GetInventoryText(LogicalOperator, Comparison)
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
	module.CurrentMatch = GetItemCount(itemObj.link, true, false) or 0
	module:Debug("Inventory: " .. module.CurrentMatch)
end

function module.Widget:GetMatch(RuleNum, Index)
	local Value = self:GetData(RuleNum)
	local LogicalOperator = Value[Index][1]
	local Comparison = Value[Index][2]
	if (LogicalOperator > 1) then
		if (LogicalOperator == 2) then -- Equal To
			if (module.CurrentMatch ~= Comparison) then
				module:Debug("Inventory (" .. module.CurrentMatch .. ") ~= " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 3) then -- Not Equal To
			if (module.CurrentMatch == Comparison) then
				module:Debug("Inventory (" .. module.CurrentMatch .. ") == " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 4) then -- Less than
			if (module.CurrentMatch >= Comparison) then
				module:Debug("Inventory (" .. module.CurrentMatch .. ") >= " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 5) then -- Greater than
			if (module.CurrentMatch <= Comparison) then
				module:Debug("Inventory (" .. module.CurrentMatch .. ") <= " .. Comparison)
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
	if (Level == 1) then
		for Key, Value in ipairs(self.Choices) do
			info.text = Value.Name
			info.value = Value.Value
			if (Key == 1) then
				info.hasArrow = false
			else
				info.hasArrow = true
			end
			info.notClickable = false
			UIDropDownMenu_AddButton(info, Level)
		end
	else
		self.DropDownEditBox.value = UIDROPDOWNMENU_MENU_VALUE
		info.text = ""
		info.notClickable = false
		UIDropDownMenu_AddButton(info, Level)
		DropDownList2.maxWidth = 80
		DropDownList2:SetWidth(80)
		self.DropDownEditBox.owner = info.owner
		self.DropDownEditBox:ClearAllPoints()
		self.DropDownEditBox:SetParent(DropDownList2Button1)
		self.DropDownEditBox:SetPoint("TOPLEFT", DropDownList2Button1, "TOPLEFT")
		self.DropDownEditBox:SetPoint("BOTTOMRIGHT", DropDownList2Button1, "BOTTOMRIGHT")
		local Value = self.Widget:GetData()
		self.DropDownEditBox:SetText(Value[self.FilterIndex][2])
		self.DropDownEditBox:Show()
		self.DropDownEditBox:HighlightText()
	end
end

function module:DropDown_OnClick(Frame)
	local Value = self.Widget:GetData()
	local LogicalOperator = Frame.value
	local Comparison = Value[self.FilterIndex][2]
	if (Frame:GetName() == self.DropDownEditBox:GetName()) then
		Comparison = Frame:GetText() or ""
		Comparison = tonumber(Frame:GetText()) or 0
		if (Comparison < 0) then
			Comparison = 0
		end
		Comparison = math.floor(Comparison + 0.5)
	end
	Value[self.FilterIndex][1] = LogicalOperator
	Value[self.FilterIndex][2] = Comparison
	self:SetConfigOption(module_key, Value)
	UIDropDownMenu_SetText(Frame.owner, self:GetInventoryText(LogicalOperator, Comparison))
	self.DropDownEditBox:Hide()
	self.DropDownEditBox:ClearAllPoints()
	self.DropDownEditBox:SetParent(nil)
end

function module:GetInventoryText(LogicalOperator, Comparison)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == LogicalOperator) then
			return string.gsub(Value.Text, "%%num%%", Comparison)
		end
	end
end
