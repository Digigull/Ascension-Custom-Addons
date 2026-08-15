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
local module_key = "Zone"
local module_name = L["Zone Name"]
local module_tooltip = L["Zone Name_Desc"]

local module = PasslootBiS:NewModule(module_name)

module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{
		module_key,
		-- {
		-- [1] = { Value, Exception }
		-- },
	},
}
module.NewFilterValue = L["Temp Zone Name"]

function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_Zone"
	local Widget = PasslootBiS:CreateTextBoxOptionalCheckBox(self, module_name, frame_name, module_tooltip)
	Widget:SetScript("OnMouseUp", function(...) self:SetItemName(...) end)
	return Widget
end

module.Widget = module:CreateWidget()

-- Local function to get the data and make sure it's valid data
function module.Widget:GetData(RuleNum)
	return module:GetConfigOption(module_key, RuleNum) or {}
end

function module.Widget:GetNumFilters(RuleNum)
	local Value = self:GetData(RuleNum)
	return #Value
end

function module.Widget:AddNewFilter()
	local Value = self:GetData()
	table.insert(Value, { module.NewFilterValue, false })
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
	if (not Value or not Value[module.FilterIndex]) then
		return
	end
	module.Widget.TextBox:SetText(Value[module.FilterIndex][1])
	module.Widget.TextBox:SetScript("OnUpdate", function(...) module:ScrollLeft(...) end)
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return Value[Index][1]
end

function module.Widget:IsException(RuleNum, Index)
	local Data = self:GetData(RuleNum)
	return Data[Index][2]
end

function module.Widget:SetException(RuleNum, Index, Value)
	local Data = self:GetData(RuleNum)
	Data[Index][2] = Value
	module:SetConfigOption(module_key, Data)
end

function module.Widget:SetMatch(itemObj, Tooltip)
	module.CurrentMatch = string.lower(GetRealZoneText())
	module:Debug("Zone: " .. (module.CurrentMatch or ""))
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	if (RuleValue[Index][1] ~= "") then
		if (string.lower(RuleValue[Index][1]) ~= module.CurrentMatch) then
			module:Debug("Zone does not match")
			return false
		end
	end
	return true
end

function module:SetItemName(Frame, Button)
	local Value = self.Widget:GetData()
	if (Button) then
		if (Button == "RightButton" and IsShiftKeyDown() and GetRealZoneText()) then
			Value[self.FilterIndex][1] = GetRealZoneText()
			self:SetConfigOption(module_key, Value)
			Frame:SetText(GetRealZoneText())
			Frame:ClearFocus()
		end
		return
	else
		Value[self.FilterIndex][1] = Frame:GetText()
		self:SetConfigOption(module_key, Value)
	end
end
