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
local module_key = "CanIRoll"
local module_name = L["Can I Roll"]
local module_tooltip = L["Selected rule will only match if you can roll this."]

local module = PasslootBiS:NewModule(module_name)

module.Choices = {
	{
		["Name"] = L["Any"],
		["Value"] = 1,
	},
	{
		["Name"] = L["None"],
		["Value"] = 2,
	},
	{
		["Name"] = NEED,
		["Value"] = 3,
	},
	{
		["Name"] = GREED,
		["Value"] = 4,
	},
	{
		["Name"] = ROLL_DISENCHANT,
		["Value"] = 5,
	},
}
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
	local frame_name = "PasslootBiS_Frames_Widgets_CanIRoll"
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
	if (Index) then
		module.FilterIndex = Index
	end
	local Value = self:GetData()
	UIDropDownMenu_SetText(module.Widget, module:GetRollTypeText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetRollTypeText(Value[Index][1])
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

module.CurrentMatch = {}
function module.Widget:SetMatch(itemObj, Tooltip, RollID)
	_, _, _, _, _, module.CurrentMatch.Need, module.CurrentMatch.Greed, module.CurrentMatch.DE = GetLootRollItemInfo(RollID)
	-- texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, reasonNeed, reasonGreed, reasonDisenchant, deSkillRequired = GetLootRollItemInfo(self.rollID)
	module:Debug(string.format("Need: %s Greed: %s DE %s", tostring(module.CurrentMatch.Need),
		tostring(module.CurrentMatch.Greed), tostring(module.CurrentMatch.DE)))
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	local RollType = RuleValue[Index][1]
	local Need, Greed, DE = module.CurrentMatch.Need, module.CurrentMatch.Greed, module.CurrentMatch.DE
	if (RollType > 1) then
		if (RollType == 2 and (Need or Greed or DE)) then
			return false
		elseif (RollType == 3 and not Need) then
			return false
		elseif (RollType == 4 and not Greed) then
			return false
		elseif (RollType == 5 and not DE) then
			return false
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
	Value[self.FilterIndex][1] = Frame.value
	self:SetConfigOption(module_key, Value)
	UIDropDownMenu_SetText(Frame.owner, Frame:GetText())
end

function module:GetRollTypeText(Roll)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == Roll) then
			return Value.Name
		end
	end
	return ""
end
