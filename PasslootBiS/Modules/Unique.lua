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
local module_key = "Unique"
local module_name = L["Unique"]
local module_tooltip = L["Unique_Desc"]

local module = PasslootBiS:NewModule(module_name)

module.Choices = {
	{
		["Name"] = L["Any"],
		["Value"] = 1,
	},
	{
		["Name"] = L["Not"],
		["Value"] = 2,
	},
	{
		["Name"] = module_name,
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
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_Unique"
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
	UIDropDownMenu_SetText(module.Widget, module:GetUniqueSlotText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetUniqueSlotText(Value[Index][1])
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
	local Line, LineText
	local Unique
	-- Found on line 2 for normal items
	-- Found on line 3 for heroic and/or colorblind option items
	-- Found on line 4 for heroic and/or colorblind option bop items.
	-- Scan till line 5 or until newline character detected (patterns have a newline, not sure if anything else does)
	Unique = 2 -- module.Choices[2] = "Not"
	PasslootBiS:BuildTooltipCache(itemObj)
	local cache = PasslootBiS.TooltipCache
	for Index = 1, math.min(5, #cache.Left) do
		LineText = cache.Left[Index]
		if (LineText and LineText ~= "") then
			if (string.find(LineText, "^\n")) then
				break
			end
			if (LineText == ITEM_UNIQUE or LineText == ITEM_UNIQUE_EQUIPPABLE or LineText:match(ITEM_UNIQUE_MULTIPLE:gsub("%%d", ".+"))) then
				Unique = 3 -- module.Unique[3] == module_key
				break
			end
		end
	end
	module.CurrentMatch = Unique
	module:Debug("Unique Type: " .. Unique .. " (" .. module:GetUniqueSlotText(Unique) .. ")")
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	if (RuleValue[Index][1] > 1) then
		if (RuleValue[Index][1] ~= module.CurrentMatch) then
			module:Debug("Unique doesn't match")
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

function module:GetUniqueSlotText(UniqueID)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == UniqueID) then
			return Value.Name
		end
	end
	return ""
end
