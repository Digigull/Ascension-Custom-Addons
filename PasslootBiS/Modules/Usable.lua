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
local module_key = "Usable"
local module_name = L["Usable"]
local module_tooltip = L["Selected rule will only match usable items."]

local module = PasslootBiS:NewModule(module_name)

module.Choices = {
	{
		["Name"] = L["Any"],
		["Value"] = 1,
	},
	{
		["Name"] = module_name,
		["Value"] = 2,
	},
	{
		["Name"] = L["Unusable"],
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
	local frame_name = "PasslootBiS_Frames_Widgets_Usable"
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
	module:SetConfigOption(module_key, Data)
end

function module.Widget:SetMatch(itemObj, Tooltip)
	PasslootBiS:BuildTooltipCache(itemObj)
	local cache = PasslootBiS.TooltipCache

	-- There is no fixed line to read: the old comment here listed which tooltip line
	-- the requirement lands on (3 normally, 4 for unique or heroic/colorblind, 5 for
	-- both, 7 for a BoP unique mount with a riding requirement), which is exactly why
	-- counting lines was abandoned. Core/Cache.lua instead paints the verdict off the
	-- COLOUR while it scans -- any line the client renders in its unmet-requirement
	-- red (255,32,32) makes the item unusable, wherever it sits.
	--
	-- The trace line used to print a hardcoded 2, so it read "Usable: 2 (Usable)" for
	-- every item ever scanned, including the ones this very filter had just ruled
	-- unusable. A Dire Maul trace (2026-08) therefore showed the "Not Usable" rule
	-- matching three items the trace called usable -- the filter was right and only
	-- its own report was wrong. Print what was decided, and name the red line that
	-- decided it: "unusable" is an inference from a colour, and an inference you
	-- cannot audit from a trace is one you end up debugging twice.
	module.CurrentMatch = cache.usable and 2 or 3
	local reason = PasslootBiS:UnusableReason()
	module:Debug("Usable: " .. module.CurrentMatch ..
		" (" .. module:GetUsableText(module.CurrentMatch) .. ")" ..
		(reason and ("  red lines: " .. reason) or ""))
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

function module:GetUsableText(ID)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == ID) then
			return Value.Name
		end
	end
	return ""
end
