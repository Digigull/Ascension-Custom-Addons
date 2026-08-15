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
local module_key = "ZoneType"
local module_name = L["Zone Type"]
local module_tooltip = L["Selected rule will only match items when you are in this type of zone."]

local module = PasslootBiS:NewModule(module_name)

module.Choices = {
	{
		["Name"] = L["Any"],
		["Group"] = {},
		["Value"] = 1,
	},
	{
		["Name"] = L["Outside"],
		["Group"] = {},
		["Value"] = 2,
	},
	{
		["Name"] = L["Group"],
		["Group"] = {
			{
				["Name"] = L["Any"],
				["Value"] = 3,
			},
			{
				["Name"] = L["Normal"],
				["Value"] = 4,
			},
			{
				["Name"] = L["Heroic"],
				["Value"] = 5,
			},
		},
	},
}
module.Choices[4] = {
	["Name"] = L["10 Man Raid"],
	["Group"] = {
		{
			["Name"] = L["Any"],
			["Value"] = 6,
		},
		{
			["Name"] = L["Normal"],
			["Value"] = 7,
		},
		{
			["Name"] = L["Heroic"],
			["Value"] = 9,
		},
	},
}
module.Choices[5] = {
	["Name"] = L["25 Man Raid"],
	["Group"] = {
		{
			["Name"] = L["Any"],
			["Value"] = 10,
		},
		{
			["Name"] = L["Normal"],
			["Value"] = 8,
		},
		{
			["Name"] = L["Heroic"],
			["Value"] = 11,
		},
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
	local frame_name = "PasslootBiS_Frames_Widgets_ZoneType"
	return PasslootBiS:CreateSimpleDropdown(self, module_name, frame_name, module_tooltip)
end

module.Widget = module:CreateWidget()

-- Local function to get the data and make sure it's valid data
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
	UIDropDownMenu_SetText(module.Widget, module:GetZoneTypeText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetZoneTypeText(Value[Index][1])
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
end

module.Widget.LookupTable = {
	-- 1 = Any
	-- 2 = Outside
	-- 3 = Group - Any
	-- 4 = Group - Normal
	-- 5 = Group - Heroic
	-- 6 = 10 Raid - Any
	-- 7 = 10 Raid - Normal
	-- 9 = 10 Raid - Heroic
	-- 10 = 25 Raid - Any
	-- 8 = 25 Raid - Normal
	-- 11 = 25 Raid - Heroic
	[1] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return true end,
	[2] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == nil and InstanceType == "none") end,
	[3] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "party") end,
	[4] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "party" and Difficulty == 1) end,
	[5] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "party" and Difficulty == 2) end,
	[6] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "raid" and MaxNumPlayers == 10) end,
	[7] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "raid" and MaxNumPlayers == 10 and Difficulty == 1 and DynamicDifficulty == 0) end,
	[9] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "raid" and MaxNumPlayers == 10 and ((Difficulty == 3 and DynamicDifficulty == 0) or (Difficulty == 1 and DynamicDifficulty == 1))) end,
	[10] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "raid" and MaxNumPlayers == 25) end,
	[8] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "raid" and MaxNumPlayers == 25 and Difficulty == 2 and DynamicDifficulty == 0) end,
	[11] = function(InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty) return (InInstance == 1 and InstanceType == "raid" and MaxNumPlayers == 25 and ((Difficulty == 4 and DynamicDifficulty == 0) or (Difficulty == 2 and DynamicDifficulty == 1))) end,
}

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	local InInstance, InstanceType = IsInInstance()
	-- InInstance is either nil or 1
	-- InstanceType is none, pvp, arena, party, raid
	local _, _, Difficulty, MaxNumPlayersText, MaxNumPlayers, DynamicDifficulty, DynamicInstance = GetInstanceInfo()
	-- DynamicDifficulty == 0 for normal, 1 for heroic
	if (self.LookupTable[RuleValue[Index][1]](InInstance, InstanceType, Difficulty, MaxNumPlayers, DynamicDifficulty)) then
		return true
	end
	module:Debug("ZoneType doesn't match")
	return false
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
				info.notClickable = false
				info.value = {
					["Key"] = Key,
					["Value"] = self.Choices[Key].Group[1].Value,
				}
			else
				info.hasArrow = false
				info.notClickable = false
				info.value = {
					["Key"] = Key,
					["Value"] = Value.Value,
				}
			end
			UIDropDownMenu_AddButton(info, Level)
		end
	else
		for Key, Value in ipairs(self.Choices[UIDROPDOWNMENU_MENU_VALUE.Key].Group) do
			info.text = Value.Name
			info.hasArrow = false
			info.notClickable = false
			info.value = {
				["Key"] = UIDROPDOWNMENU_MENU_VALUE.Key,
				["Value"] = Value.Value,
			}
			UIDropDownMenu_AddButton(info, Level)
		end
	end
end

function module:DropDown_OnClick(Frame)
	local Value = self.Widget:GetData()
	Value[self.FilterIndex][1] = Frame.value.Value
	self:SetConfigOption(module_key, Value)
	UIDropDownMenu_SetText(Frame.owner, self:GetZoneTypeText(Frame.value.Value))
	DropDownList1:Hide() -- Nested dropdown buttons don't hide their parent menus on click.
end

function module:GetZoneTypeText(ZoneID)
	for Key, Value in ipairs(self.Choices) do
		if (#Value.Group > 0) then
			for GroupKey, GroupValue in ipairs(Value.Group) do
				if (GroupValue.Value == ZoneID) then
					local ReturnValue = string.gsub(L["%zonetype% - %instancedifficulty%"], "%%zonetype%%", Value.Name)
					ReturnValue = string.gsub(ReturnValue, "%%instancedifficulty%%", GroupValue.Name)
					return ReturnValue
				end
			end
		else
			if (Value.Value == ZoneID) then
				return Value.Name
			end
		end
	end
	return ""
end
