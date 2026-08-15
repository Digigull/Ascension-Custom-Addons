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
local module_key = "Items"
local module_name = L["Item Name"]
local module_tooltip = L["Selected rule will match on item names."]

local module = PasslootBiS:NewModule(module_name)

module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{
		module_key,
		-- {
		-- [1] = { Name, Type, Exception }
		-- },
	},
}
module.NewFilterValue_Name = L["Temp Item Name"]
module.NewFilterValue_Type = "Exact"

-- I could migrate to having our own db namespace with PasslootBiS.db:RegisterNamespace("ItemName", defaultstable)
-- in order to have a defaults section.
-- Not sure it's necessary at this point in time.
-- Note: I can NOT do that with rules.
module.ProfileOptionsTable = {
	["name"] = L["Use RegEx for partial"],
	["desc"] = L["Uses regular expressions when using partial matches."],
	["type"] = "toggle",
	["get"] = function(info)
		return module:GetProfileVariable("UseRegEx")
	end,
	["set"] = function(info, value)
		module:SetProfileVariable("UseRegEx", value)
	end,
}

function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
	self:AddModuleOptionTable("UseRegEx", self.ProfileOptionsTable)
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
	self:RemoveModuleOptionTable("UseRegEx")
end

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_ItemName"
	return PasslootBiS:CreateTextBoxOptionalCheckBox(self, module_name, frame_name, module_tooltip, L["Exact"],
		L["Exact_Desc"])
end

module.Widget = module:CreateWidget()

local function compare(a, b)
	local atest = a[1]:lower()
	local btext = b[1]:lower()
	return (atest < btext) or (atest == btext and a[2] < b[2])
end

-- return true if the tables are different
local function simplediff(a, b)
	if #a ~= #b then return true end
	for i = 1, #a do
		if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return true end
	end
	return false
end

local function simplecopytable(a)
	if (not a or type(a) ~= "table") then
		return a
	end
	local b
	b = {}
	for k, v in pairs(a) do
		if (type(v) ~= "table") then
			b[k] = v
		else
			b[k] = simplecopytable(v)
		end
	end
	return b
end

local function cleandata(a)
	-- remove duplicates
	local temp = simplecopytable(a)
	local hash = {}
	a = {}

	for _, v in ipairs(temp) do
		if (not hash[v[1] .. v[2]]) then
			a[#a + 1] = v
			hash[v[1] .. v[2]] = true
		end
	end
	table.sort(a, compare)
	if simplediff(temp, a) then return true, a end
	return false, a
end

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
		module.NewFilterValue_Name,
		module.NewFilterValue_Type,
		false
	}
	table.insert(Value, NewTable)
	_, Value = cleandata(Value)
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
	module.Widget.TextBox:SetScript("OnUpdate", function(...) module:ScrollLeft(...) end)
	if (Value[module.FilterIndex][2] == "Exact") then
		module.Widget.CheckBox:SetChecked(true)
	else
		module.Widget.CheckBox:SetChecked(false)
	end
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return Value[Index][1]
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

function module.Widget:SetMatch(itemObj, Tooltip)
	module.CurrentMatch = string.lower(itemObj.name or "")
	module:Debug("Item name: " .. (module.CurrentMatch or ""))
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	local Name, Type = string.lower(RuleValue[Index][1]), RuleValue[Index][2]
	if (Type == "Exact") then
		if (module.CurrentMatch == Name) then
			module:Debug("Found item name (exact)")
			return true
		end
	else
		local UseRegEx = module:GetProfileVariable("UseRegEx")
		if (not UseRegEx) then
			Name = string.gsub(Name, "([%%%$%(%)%.%[%]%*%+%-%?%^])", "%%%1")
		end
		if (string.find(module.CurrentMatch, Name)) then
			module:Debug("Found item name (partial)")
			return true
		end
	end
	return false
end

function module:SetItemName(Frame)
	local Value = self.Widget:GetData()
	Value[self.FilterIndex][1] = Frame:GetText()
	_, Value = cleandata(Value)
	self:SetConfigOption(module_key, Value)
end

function module:Exact_OnClick(Frame, Button)
	local Value = self.Widget:GetData()
	if (Frame:GetChecked()) then
		Value[self.FilterIndex][2] = "Exact"
	else
		Value[self.FilterIndex][2] = "Partial"
	end
	self:SetConfigOption(module_key, Value)
end
