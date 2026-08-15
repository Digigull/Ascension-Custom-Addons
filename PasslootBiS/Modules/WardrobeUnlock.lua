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
local module_key = "Wardrobe"
local module_name = L["Wardrobe Unlock"]
local module_tooltip = L["Selected rule will only match unlearned Wardrobe items."]

local module = PasslootBiS:NewModule(module_name)

-- item types that will show they have a wardrobe unlock but cannot be unlocked
local BAD_WARDROBE_SUBTYPES = {
	["Thrown"] = true,
	["Fishing Poles"] = true,
	["Miscellaneous"] = true,
}

module.Choices = { {
	["Name"] = L["Any"],
	["Value"] = 1,
}, {
	["Name"] = L["Unlocked"],
	["Value"] = 2,
}, {
	["Name"] = L["Unknown"],
	["Value"] = 3,
}, {
	["Name"] = L["Unlocked from Different Item"],
	["Value"] = 4,
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
	local frame_name = "PasslootBiS_Frames_Widgets_Wardrobe"
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
	local Owned = 0                                                                  -- 0 means no Wardrobe line on tooltip
	if not (BAD_WARDROBE_SUBTYPES[itemObj.subclass] and itemObj.class == "Weapon") then -- you can't get wardrobe unlocks from some items
		local appearanceID = C_Appearance.GetItemAppearanceID(itemObj.id)
		if appearanceID then
			local isCollected = C_AppearanceCollection.IsAppearanceCollected(appearanceID)
			if isCollected then -- unlocked
				Owned = 2
			else    -- unknown
				Owned = 3
			end
		end
	end

	module.CurrentMatch = Owned
	module:Debug("Wardrobe: " .. Owned .. " (" .. itemObj.id .. ")")
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	if (RuleValue[Index][1] == 1 and module.CurrentMatch > 0) or -- rule is "any" and item contains a Wardrobe line
		(RuleValue[Index][1] > 1 and RuleValue[Index][1] == module.CurrentMatch) then
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
