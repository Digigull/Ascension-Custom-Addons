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
local module_key = "PlayerClass"
local module_name = L["Player Class"]
local module_tooltip = L["Selected rule will match against the player's class."]

local module = PasslootBiS:NewModule(module_name)

module.Choices = { {
	["Name"] = "|c" .. RAID_CLASS_COLORS["HERO"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["HERO"] .. "|r", -- Hero
	["Value"] = "HERO",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["DRUID"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["DRUID"] .. "|r", -- Druid
	["Value"] = "DRUID",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["HUNTER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["HUNTER"] .. "|r", -- Hunter
	["Value"] = "HUNTER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["MAGE"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["MAGE"] .. "|r", -- Mage
	["Value"] = "MAGE",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["PALADIN"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["PALADIN"] .. "|r", -- Paladin
	["Value"] = "PALADIN",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["PRIEST"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["PRIEST"] .. "|r", -- Priest
	["Value"] = "PRIEST",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["ROGUE"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["ROGUE"] .. "|r", -- Rogue
	["Value"] = "ROGUE",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["SHAMAN"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["SHAMAN"] .. "|r", -- Shaman
	["Value"] = "SHAMAN",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["WARLOCK"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["WARLOCK"] .. "|r", -- Warlock
	["Value"] = "WARLOCK",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["WARRIOR"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["WARRIOR"] .. "|r", -- Warrior
	["Value"] = "WARRIOR",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["BARBARIAN"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["BARBARIAN"] .. "|r", -- Barbarian
	["Value"] = "BARBARIAN",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["CHRONOMANCER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["CHRONOMANCER"] .. "|r", -- Chronomancer
	["Value"] = "CHRONOMANCER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["CULTIST"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["CULTIST"] .. "|r", -- Cultist
	["Value"] = "CULTIST",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["DEATHKNIGHT"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["DEATHKNIGHT"] .. "|r", -- Death Knight
	["Value"] = "DEATHKNIGHT",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["DEMONHUNTER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["DEMONHUNTER"] .. "|r", -- Felsworn
	["Value"] = "DEMONHUNTER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["FLESHWARDEN"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["FLESHWARDEN"] .. "|r", -- Knight of Xoroth
	["Value"] = "FLESHWARDEN",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["GUARDIAN"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["GUARDIAN"] .. "|r", -- Guardian
	["Value"] = "GUARDIAN",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["MONK"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["MONK"] .. "|r", -- Templar
	["Value"] = "MONK",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["NECROMANCER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["NECROMANCER"] .. "|r", -- Necromancer
	["Value"] = "NECROMANCER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["PROPHET"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["PROPHET"] .. "|r", -- Venomancer
	["Value"] = "PROPHET",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["PYROMANCER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["PYROMANCER"] .. "|r", -- Pyromancer
	["Value"] = "PYROMANCER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["RANGER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["RANGER"] .. "|r", -- Ranger
	["Value"] = "RANGER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["REAPER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["REAPER"] .. "|r", -- Reaper
	["Value"] = "REAPER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["SONOFARUGAL"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["SONOFARUGAL"] .. "|r", -- Bloodmage
	["Value"] = "SONOFARUGAL",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["SPIRITMAGE"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["SPIRITMAGE"] .. "|r", -- Runemaster
	["Value"] = "SPIRITMAGE",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["STARCALLER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["STARCALLER"] .. "|r", -- Starcaller
	["Value"] = "STARCALLER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["STORMBRINGER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["STORMBRINGER"] .. "|r", -- Stormbringer
	["Value"] = "STORMBRINGER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["SUNCLERIC"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["SUNCLERIC"] .. "|r", -- Sun Cleric
	["Value"] = "SUNCLERIC",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["TINKER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["TINKER"] .. "|r", -- Tinker
	["Value"] = "TINKER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["WILDWALKER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["WILDWALKER"] .. "|r", -- Primalist
	["Value"] = "WILDWALKER",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["WITCHDOCTOR"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["WITCHDOCTOR"] .. "|r", -- Witch Doctor
	["Value"] = "WITCHDOCTOR",
}, {
	["Name"] = "|c" .. RAID_CLASS_COLORS["WITCHHUNTER"].colorStr .. LOCALIZED_CLASS_NAMES_MALE["WITCHHUNTER"] .. "|r", -- Witch Hunter
	["Value"] = "WITCHHUNTER",
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
module.NewFilterValue = select(2, UnitClass("player"))

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
	local _, class = UnitClass("player")
	module.CurrentMatch = class
	module:Debug("Player Class: " .. class)
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	if (RuleValue[Index][1] == module.CurrentMatch) then
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
