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
local module_key = "Exceptionaltem"
local module_name = L["Exceptional Item"]
local module_tooltip = L["Selected module checks if an item is no longer normal."]

local module = PasslootBiS:NewModule(module_name)

module.Choices = { {
	["Name"] = L["None"],
	["Value"] = 1,
}, {
	["Name"] = L["Any"],
	["Value"] = 2,
}, {
	["Name"] = L["Bloodforged"],
	["Value"] = 3,
}, {
	["Name"] = L["Heroic"],
	["Value"] = 4,
}, {
	["Name"] = L["Mythic"],
	["Value"] = 5,
}, {
	["Name"] = L["Ascended"],
	["Value"] = 6,
}, {
	["Name"] = L["Worldforged"],
	["Value"] = 7,
} }

module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{
		module_key,
		-- {
		-- [1] = { Value, Exception }
		-- },
	},
}
module.NewFilterValue = 1

function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
	-- self:AddProfileWidget(self.Widget)
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_Exceptionaltem"
	return PasslootBiS:CreateSimpleDropdown(self, module_name, frame_name, module_tooltip)
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
	if (Index) then module.FilterIndex = Index end
	local Value = self:GetData()
	UIDropDownMenu_SetText(module.Widget, module:GetUsableText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetUsableText(Value[Index][1])
end

function module.Widget:IsException(RuleNum, Index)
	local Data = self:GetData(RuleNum)
	return Data[Index][2]
end

function module.Widget:SetException(RuleNum, Index, Value)
	local Data = self:GetData(RuleNum)
	Data[Index][2] = Value
	module:SetConfigOption("Unowned", Data)
end

function module.Widget:SetMatch(itemObj, Tooltip)
	module.CurrentMatch = { itemObj.isBloodforged, itemObj.isHeroic, itemObj.isMythic, itemObj.isAscended, itemObj.isWorldforged }
	module:Debug("Exceptionaltem: " .. "true" and itemObj.isBloodforged or "false"
		.. "," .. "true" and itemObj.isHeroic or "false"
		.. "," .. "true" and itemObj.isMythic or "false"
		.. "," .. "true" and itemObj.isAscended or "false" .. " (" .. itemObj.link .. ")")
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	local t_EI = module.CurrentMatch
	local anyTrue = t_EI[1] or t_EI[2] or t_EI[3] or t_EI[4] or t_EI[5]
	if (RuleValue[Index][1] == 1 and not anyTrue) or -- rule is "None" and item is not exceptional
		(RuleValue[Index][1] == 2 and anyTrue) or -- rule is "any" and the item is exceptional in some way
		(RuleValue[Index][1] == 3 and t_EI[1]) or -- bloodforged
		(RuleValue[Index][1] == 4 and t_EI[2]) or -- heroic
		(RuleValue[Index][1] == 5 and t_EI[3]) or -- mythic
		(RuleValue[Index][1] == 6 and t_EI[4]) or -- ascended
		(RuleValue[Index][1] == 7 and t_EI[5]) then -- worldforged
		return true
	end
	return false
end

function module:DropDown_Init(Frame, Level)
	Level = Level or 1
	local info = {}
	info.checked = false
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
	Value[self.FilterIndex][1] = Frame.value
	self:SetConfigOption(module_key, Value)
	UIDropDownMenu_SetText(Frame.owner, Frame:GetText())
end

function module:GetUsableText(ID)
	for Key, Value in ipairs(self.Choices) do if (Value.Value == ID) then return Value.Name end end
	return ""
end
