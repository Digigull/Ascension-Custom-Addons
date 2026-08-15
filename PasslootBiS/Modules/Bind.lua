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
local module_key = "Bind"
local module_name = L["Bind On"]
local module_tooltip = L["Selected rule will only match these items."]

local module = PasslootBiS:NewModule(module_name)


module.Choices = {
	{
		["Name"] = L["Any"],
		["Type"] = "",
		["Value"] = 1,
	},
	{
		["Name"] = L["None"],
		["Type"] = "",
		["Value"] = 2,
	},
	{
		["Name"] = L["Equip"],
		["Type"] = ITEM_BIND_ON_EQUIP,
		["Value"] = 3,
	},
	{
		["Name"] = L["Pickup"],
		["Type"] = ITEM_BIND_ON_PICKUP,
		["Value"] = 4,
	},
	{
		["Name"] = L["Use"],
		["Type"] = ITEM_BIND_ON_USE,
		["Value"] = 5,
	},
	{
		["Name"] = ITEM_BIND_QUEST,
		["Type"] = ITEM_BIND_QUEST,
		["Value"] = 6,
	},
	{
		["Name"] = L["Account"],
		["Type"] = ITEM_BIND_TO_ACCOUNT,
		["Value"] = 7,
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
	local frame_name = "PasslootBiS_Frames_Widgets_Bind"
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
	UIDropDownMenu_SetText(module.Widget, module:GetBindSlotText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetBindSlotText(Value[Index][1])
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
	local LineText
	local Bind
	-- Found on line 2 for most items
	-- Found on line 3 for Heroic / colorblind mode items
	-- Scan till line 4 or until newline character detected (patterns have a newline, not sure if anything else does)
	Bind = 2 -- module.Bind[2] = "None"
	PasslootBiS:BuildTooltipCache(itemObj)
	local cache = PasslootBiS.TooltipCache
	for Index = 2, math.min(4, #cache.Left) do
		LineText = cache.Left[Index]
		if (LineText and LineText ~= "") then
			if (string.find(LineText, "^\n")) then break end
			for Key = 3, #module.Choices do --Don't check for Key 1 (Any) or 2 (None)
				if (LineText == module.Choices[Key].Type) then
					Bind = Key
					break
				end
			end
		end
	end

	module.CurrentMatch = Bind
	module:Debug("Bind Type: " .. Bind .. " (" .. module:GetBindSlotText(Bind) .. ")")
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

function module:GetBindSlotText(BindID)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == BindID) then
			return Value.Name
		end
	end
	return ""
end
