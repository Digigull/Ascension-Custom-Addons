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
local module_key = "LearnedItem"
local module_name = L["Learned Item"]
local module_tooltip = L["Selected rule will only match these items."]

local module = PasslootBiS:NewModule(module_name)

module.Choices = {
	{
		["Name"] = L["Any"],
		["Value"] = 1,
	},
	{
		["Name"] = L["Learned"],
		["Value"] = 2,
	},
	{
		["Name"] = L["Unlearned"],
		["Value"] = 3,
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
	local frame_name = "PasslootBiS_Frames_Widgets_LearnedItem"
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
	UIDropDownMenu_SetText(module.Widget, module:GetLearnedItemText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetLearnedItemText(Value[Index][1])
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
	local TextLine, Text
	module.CurrentMatch = 3 -- module.Choices[2] = "Unlearned"
	PasslootBiS:BuildTooltipCache(itemObj)
	local cache = PasslootBiS.TooltipCache
	-- Found on line 7 of Reins of the Bronze Drake
	for Index = 2, #cache.Left do
		Text = cache.Left[Index]
		-- Search for the "Already known" text unless we hit a newline character at the beginning of a line.
		-- new line is usually a recipe.  We don't want to scan the item a recipe makes
		-- as that might be a mount (mechano-hog / chopper) that might be learned.
		-- Might be items other than recipes that are similar...
		if (Text == nil or string.find(Text, "^\n")) then
			break
		elseif (Text == ITEM_SPELL_KNOWN) then
			module.CurrentMatch = 2 -- module.Choices[2] = "Learned"
			break
		end
	end
	module:Debug("Learned Item: " .. module.CurrentMatch .. " (" .. module:GetLearnedItemText(module.CurrentMatch) .. ")")
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	if (RuleValue[Index][1] > 1) then
		if (RuleValue[Index][1] ~= module.CurrentMatch) then
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

function module:GetLearnedItemText(Which)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == Which) then
			return Value.Name
		end
	end
	return ""
end
