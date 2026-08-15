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
local module_key = "EquipSlot"
local module_name = L["Equip Slot"]
local module_tooltip = L["Selected rule will only match these items."]

local module = PasslootBiS:NewModule(module_name)
local binv, BI


if (not LibStub("LibBabble-Inventory-3.0", true)) then
	return
end

function module:SetupValues()
	binv = LibStub("LibBabble-Inventory-3.0")
	BI = binv:GetUnstrictLookupTable()
	module.Choices = {
		{
			["Name"] = L["Any"],
			["Type"] = {
				"",
			},
			["Group"] = {},
			["Value"] = 1,
		},
		{
			["Name"] = L["None"],
			["Type"] = {
				"",
			},
			["Group"] = {},
			["Value"] = 2,
		},
		{
			["Name"] = L["Armor"],
			["Type"] = {
				"",
			},
			["Group"] = {
				{
					["Name"] = BI["Chest"] or INVTYPE_CHEST,
					["Type"] = {
						"INVTYPE_CHEST",
						"INVTYPE_ROBE",
					},
					["Value"] = 5,
				},
				{
					["Name"] = BI["Feet"] or INVTYPE_FEET,
					["Type"] = {
						"INVTYPE_FEET",
					},
					["Value"] = 6,
				},
				{
					["Name"] = BI["Hands"] or INVTYPE_HAND,
					["Type"] = {
						"INVTYPE_HAND",
					},
					["Value"] = 8,
				},
				{
					["Name"] = BI["Head"] or INVTYPE_HEAD,
					["Type"] = {
						"INVTYPE_HEAD",
					},
					["Value"] = 9,
				},
				{
					["Name"] = BI["Legs"] or INVTYPE_LEGS,
					["Type"] = {
						"INVTYPE_LEGS",
					},
					["Value"] = 11,
				},
				{
					["Name"] = BI["Shield"] or "Shield", --INVTYPE_SHIELD == "Off Hand"
					["Type"] = {
						"INVTYPE_SHIELD",
					},
					["Value"] = 20,
				},
				{
					["Name"] = BI["Shoulder"] or INVTYPE_SHOULDER,
					["Type"] = {
						"INVTYPE_SHOULDER",
					},
					["Value"] = 22,
				},
				{
					["Name"] = BI["Waist"] or INVTYPE_WAIST,
					["Type"] = {
						"INVTYPE_WAIST",
					},
					["Value"] = 26,
				},
				{
					["Name"] = BI["Wrist"] or INVTYPE_WRIST,
					["Type"] = {
						"INVTYPE_WRIST",
					},
					["Value"] = 27,
				},
			},
		},
		{
			["Name"] = L["Weapons"],
			["Type"] = {
				"",
			},
			["Group"] = {
				{
					["Name"] = BI["Held in Off-Hand"] or INVTYPE_HOLDABLE,
					["Type"] = {
						"INVTYPE_HOLDABLE",
					},
					["Value"] = 10,
				},
				{
					["Name"] = BI["Main Hand"] or INVTYPE_WEAPONMAINHAND, --Main-Hand Weapon
					["Type"] = {
						"INVTYPE_WEAPONMAINHAND",
					},
					["Value"] = 12,
				},
				{
					["Name"] = BI["Off Hand"] or INVTYPE_WEAPONOFFHAND, --Off Hand Weapon
					["Type"] = {
						"INVTYPE_WEAPONOFFHAND",
					},
					["Value"] = 14,
				},
				{
					["Name"] = BI["One-Hand"] or INVTYPE_WEAPON, --One-Hand Weapon
					["Type"] = {
						"INVTYPE_WEAPON",
					},
					["Value"] = 15,
				},
				{
					["Name"] = BI["Ranged"] or INVTYPE_RANGED, --Ranged Weapon
					["Type"] = {
						"INVTYPE_RANGED",
						"INVTYPE_RANGEDRIGHT",
						"INVTYPE_THROWN",
					},
					["Value"] = 18,
				},
				{
					["Name"] = BI["Two-Hand"] or INVTYPE_2HWEAPON, --Two-Handed Weapon
					["Type"] = {
						"INVTYPE_2HWEAPON",
					},
					["Value"] = 25,
				},
			},
		},
		{
			["Name"] = L["Accessories"],
			["Type"] = {
				"",
			},
			["Group"] = {
				{
					["Name"] = BI["Back"] or INVTYPE_CLOAK,
					["Type"] = {
						"INVTYPE_CLOAK",
					},
					["Value"] = 3,
				},
				{
					["Name"] = BI["Bag"] or INVTYPE_BAG,
					["Type"] = {
						"INVTYPE_BAG",
					},
					["Value"] = 4,
				},
				{
					["Name"] = BI["Neck"] or INVTYPE_NECK,
					["Type"] = {
						"INVTYPE_NECK",
					},
					["Value"] = 13,
				},
				{
					["Name"] = BI["Projectile"] or INVTYPE_AMMO,
					["Type"] = {
						"INVTYPE_AMMO",
					},
					["Value"] = 16,
				},
				-- Quiver equip slot defined in GlobalStrings.lua, but nothing uses it as of WoW patch 2.3.3
				-- {
				-- ["Name"] = BI["Quiver"] or INVTYPE_QUIVER,
				-- ["Type"] = {
				-- "INVTYPE_QUIVER",
				-- },
				-- ["Value"] = 17,
				-- },
				{
					["Name"] = BI["Relic"] or INVTYPE_RELIC,
					["Type"] = {
						"INVTYPE_RELIC",
					},
					["Value"] = 19,
				},
				{
					["Name"] = BI["Ring"] or INVTYPE_FINGER, --Finger
					["Type"] = {
						"INVTYPE_FINGER",
					},
					["Value"] = 7,
				},
				{
					["Name"] = BI["Shirt"] or INVTYPE_BODY,
					["Type"] = {
						"INVTYPE_BODY",
					},
					["Value"] = 21,
				},
				{
					["Name"] = BI["Tabard"] or INVTYPE_TABARD,
					["Type"] = {
						"INVTYPE_TABARD",
					},
					["Value"] = 23,
				},
				{
					["Name"] = BI["Trinket"] or INVTYPE_TRINKET,
					["Type"] = {
						"INVTYPE_TRINKET",
					},
					["Value"] = 24,
				},
			},
		},
	}
end

module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{
		module_key,
		-- {
		-- [1] = { Value, Exception }
		-- }
	},
}
module.NewFilterValue = 1

function module:OnEnable()
	self:SetupValues()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_EquipSlot"
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
	UIDropDownMenu_SetText(module.Widget, module:GetEquipSlotText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetEquipSlotText(Value[Index][1])
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
	module.CurrentMatch = module:FindEquipSlot(itemObj.equipSlot)
	if (itemObj.equipSlot) then
		module:Debug("Equip Loc: " .. (itemObj.equipSlot or "nil") .. " Found: (" .. module.CurrentMatch .. ") ")
		if (module.CurrentMatch == -1) then
			module:Debug("Could not find EquipSlot: " .. (itemObj.equipSlot or "nil"))
		end
	end
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
	if (Level == 1) then
		for Key, Value in ipairs(self.Choices) do
			info.text = Value.Name
			if (#Value.Group > 0) then
				info.hasArrow = true
				info.notClickable = true
				info.value = Key
			else
				info.hasArrow = false
				info.notClickable = false
				info.value = Value.Value
			end
			UIDropDownMenu_AddButton(info, Level)
		end
	else
		for Key, Value in ipairs(self.Choices[UIDROPDOWNMENU_MENU_VALUE].Group) do
			info.text = Value.Name
			info.hasArrow = false
			info.notClickable = false
			info.value = Value.Value
			UIDropDownMenu_AddButton(info, Level)
		end
	end
end

function module:DropDown_OnClick(Frame)
	local Value = self.Widget:GetData()
	Value[self.FilterIndex][1] = Frame.value
	self:SetConfigOption(module_key, Value)
	UIDropDownMenu_SetText(Frame.owner, Frame:GetText())
	DropDownList1:Hide() -- Nested dropdown buttons don't hide their parent menus on click.
end

function module:GetEquipSlotText(EquipID)
	for Key, Value in ipairs(self.Choices) do
		if (#Value.Group > 0) then
			for GroupKey, GroupValue in ipairs(Value.Group) do
				if (GroupValue.Value == EquipID) then
					return GroupValue.Name
				end
			end
		else
			if (Value.Value == EquipID) then
				return Value.Name
			end
		end
	end
	return ""
end

function module:FindEquipSlot(Slot)
	for Key, Value in pairs(self.Choices) do
		if (#Value.Group > 0) then
			for GroupKey, GroupValue in pairs(Value.Group) do
				for TypeKey, TypeValue in pairs(GroupValue.Type) do
					if (Slot == TypeValue) then
						return GroupValue.Value
					end
				end
			end
		else
			for TypeKey, TypeValue in pairs(Value.Type) do
				if (Slot == TypeValue and Value.Value ~= 1) then --Don't return type 1 (Any), can return 2 (None)
					return Value.Value
				end
			end
		end
	end
	return -1
end
