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
local module_key = "ItemLevel"
local module_name = L["Item Level"]
local module_tooltip = L["ItemLevel_DropDownTooltipDesc"]

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
	local frame_name = "PasslootBiS_Frames_Widgets_ItemLevelComparison"
	local DropDown = PasslootBiS:CreateSimpleDropdown(self, module_name, frame_name, module_tooltip)

	local dropdownframe_name = "PasslootBiS_Frames_Widgets_ItemLevelDropDownEditBox"
	local DropDownEditBox = PasslootBiS:CreateDropDownEditBox(self, dropdownframe_name)
	return DropDown, DropDownEditBox
end

module.Widget, module.DropDownEditBox = module:CreateWidget()

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
	UIDropDownMenu_SetText(module.Widget, module:GetItemLevelText(Value_LogicalOperator, Value_Comparison))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	local LogicalOperator = Value[Index][1]
	local Comparison = Value[Index][2]
	local Text = module:GetItemLevelText(LogicalOperator, Comparison)
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

module.Widget.EquipSlotToInvNumber = {
	[""] = nil,
	["INVTYPE_AMMO"] = { 0 },
	["INVTYPE_HEAD"] = { 1 },
	["INVTYPE_NECK"] = { 2 },
	["INVTYPE_SHOULDER"] = { 3 },
	["INVTYPE_BODY"] = { 4 },
	["INVTYPE_CHEST"] = { 5 },
	["INVTYPE_ROBE"] = { 5 },
	["INVTYPE_WAIST"] = { 6 },
	["INVTYPE_LEGS"] = { 7 },
	["INVTYPE_FEET"] = { 8 },
	["INVTYPE_WRIST"] = { 9 },
	["INVTYPE_HAND"] = { 10 },
	["INVTYPE_FINGER"] = { 11, 12 },
	["INVTYPE_TRINKET"] = { 13, 14 },
	["INVTYPE_CLOAK"] = { 15 },
	["INVTYPE_WEAPON"] = { 16, 17 },
	["INVTYPE_SHIELD"] = { 17 },
	["INVTYPE_2HWEAPON"] = { 16 },
	["INVTYPE_WEAPONMAINHAND"] = { 16 },
	["INVTYPE_WEAPONOFFHAND"] = { 17 },
	["INVTYPE_HOLDABLE"] = { 17 },
	["INVTYPE_RANGED"] = { 18 },
	["INVTYPE_THROWN"] = { 18 },
	["INVTYPE_RANGEDRIGHT"] = { 18 },
	["INVTYPE_RELIC"] = { 18 },
	["INVTYPE_TABARD"] = { 19 },
	["INVTYPE_BAG"] = { 20, 21, 22, 23 },
	["INVTYPE_QUIVER"] = { 20, 21, 22, 23 },
}
function module.Widget:GetCurrentItem(itemObj)
	local EquipSlot = itemObj.equipSlot
	local InvSlot = self.EquipSlotToInvNumber[EquipSlot]
	local ReturnValues = {}
	if (InvSlot) then
		local Link
		for Key, Value in pairs(InvSlot) do
			Link = GetInventoryItemLink("player", Value)
			if (Link) then
				table.insert(ReturnValues, Link)
			end
		end
	end
	return ReturnValues
end

function module.Widget:SetMatch(itemObj, Tooltip)
	module.CurrentMatch = itemObj.iLevel
	module.CurrentMatch = module.CurrentMatch or 0

	local CurrentItem, ItemLevel
	for Key, Value in pairs(self:GetCurrentItem(itemObj)) do
		_, _, _, ItemLevel = GetItemInfo(Value)
		if (ItemLevel) then
			CurrentItem = math.min(ItemLevel, CurrentItem or ItemLevel)
		end
	end
	module.Widget.Environment[L["current"]] = CurrentItem or 0
	module:Debug(string.format("Item Level: %s, Equipped Item Level: %s", module.CurrentMatch, CurrentItem or 0))
end

function module.Widget:GetMatch(RuleNum, Index)
	local Value = self:GetData(RuleNum)
	local LogicalOperator = Value[Index][1]
	local Comparison = self:Evaluate(Value[Index][2])
	if (LogicalOperator > 1) then
		if (LogicalOperator == 2) then -- Equal To
			if (module.CurrentMatch ~= Comparison) then
				module:Debug("ItemLevel (" .. module.CurrentMatch .. ") ~= " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 3) then -- Not Equal To
			if (module.CurrentMatch == Comparison) then
				module:Debug("ItemLevel (" .. module.CurrentMatch .. ") == " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 4) then -- Less than
			if (module.CurrentMatch >= Comparison) then
				module:Debug("ItemLevel (" .. module.CurrentMatch .. ") >= " .. Comparison)
				return false
			end
		elseif (LogicalOperator == 5) then -- Greater than
			if (module.CurrentMatch <= Comparison) then
				module:Debug("ItemLevel (" .. module.CurrentMatch .. ") <= " .. Comparison)
				return false
			end
		end
	end
	return true
end

-- Create an environment for the functions, so they can't access globals and such.
-- We can also add our variables here, so we don't have to string.gsub
module.Widget.Environment = {
	[L["current"]] = 0,
}
module.Widget.CachedFunc, module.Widget.CachedError = {},
	{} -- A list of functions and errors we have already tried loading
function module.Widget:Evaluate(Logic)
	local Function, Error = self.CachedFunc[Logic], self.CachedError[Logic]
	if (not Function and not Error) then
		Function, Error = loadstring("return " .. Logic)
		self.CachedFunc[Logic], self.CachedError[Logic] = Function, Error
	end
	if (Function and not Error) then
		setfenv(Function, self.Environment)    -- Limit what the loaded logic string can access
		local Success, ReturnValue = pcall(Function) -- Catch errors.
		if (Success) then
			return ReturnValue
		else
			self:Debug("Could not evaluate " .. (Logic or "") .. " - " .. (ReturnValue or ""))
			return
		end
	else
		self:Debug("Could not evaluate " .. (Logic or "") .. " - " .. (Error or ""))
	end
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
		self.DropDownEditBox:SetFocus()
		self.DropDownEditBox:HighlightText()
	end
end

function module:DropDown_OnClick(Frame)
	local Value = self.Widget:GetData()
	local LogicalOperator = Frame.value
	local Comparison = Value[self.FilterIndex][2]
	if (Frame:GetName() == self.DropDownEditBox:GetName()) then
		Comparison = Frame:GetText() or ""
	end
	Value[self.FilterIndex][1] = LogicalOperator
	Value[self.FilterIndex][2] = Comparison
	self:SetConfigOption(module_key, Value)
	UIDropDownMenu_SetText(Frame.owner, self:GetItemLevelText(LogicalOperator, Comparison))
	self.DropDownEditBox:Hide()
	self.DropDownEditBox:ClearAllPoints()
	self.DropDownEditBox:SetParent(nil)
end

function module:GetItemLevelText(LogicalOperator, Comparison)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == LogicalOperator) then
			return string.gsub(Value.Text, "%%num%%", Comparison)
		end
	end
end
