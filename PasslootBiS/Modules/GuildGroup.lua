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
local module_key = "GuildGroup"
local module_name = L["Guild Group"]
local module_tooltip = L["Guild Group_Desc"]

local module = PasslootBiS:NewModule(module_name)

module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{
		module_key,
		-- {
		-- [1] = { MinGuildyPercent, Exception }
		-- },
	},
}
module.NewFilterValue = 60

function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_GuildGroup"
	return PasslootBiS:CreateTextBoxOptionalCheckBox(self, module_name, frame_name, module_tooltip)
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
	local NewTable = {
		module.NewFilterValue,
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
	if (not Value or not Value[module.FilterIndex]) then
		return
	end
	module.Widget.TextBox:SetText(Value[module.FilterIndex][1])
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return Value[Index][1]
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
	local Group, NumGroup
	if (UnitInRaid("player")) then
		Group = "raid"
		NumGroup = GetNumRaidMembers()
	else
		Group = "party"
		NumGroup = GetNumPartyMembers()
	end
	if (NumGroup > 0) then
		local NumInMyGuild = 0
		for Index = 1, NumGroup do
			if (UnitIsInMyGuild(Group .. Index)) then -- If guildless, it's nil
				NumInMyGuild = NumInMyGuild + 1
			end
		end
		if (Group == "party") then -- Parties don't include myself, so add myself.
			NumInMyGuild = NumInMyGuild + 1
			NumGroup = NumGroup + 1
		end
		module.CurrentMatch = math.floor(NumInMyGuild / NumGroup * 100 + 0.5)
	else
		module.CurrentMatch = 100 -- We're solo.. maybe someone is doing a /passloot test
	end
	module:Debug(string.format("Guild Group: %s%%", module.CurrentMatch))
end

function module.Widget:GetMatch(RuleNum, Index)
	local Value = self:GetData(RuleNum)
	local NumGuildies = Value[Index][1]
	if (module.CurrentMatch >= NumGuildies) then
		return true
	end
	return false
end

function module:SetPercentGuildies(Frame)
	local Num = tonumber(Frame:GetText()) or 0
	if (Num < 0) then
		Num = 0
	end
	if (Num > 100) then
		Num = 100
	end
	local Value = self.Widget:GetData()
	Value[self.FilterIndex][1] = Num
	self:SetConfigOption(module_key, Value)
end
