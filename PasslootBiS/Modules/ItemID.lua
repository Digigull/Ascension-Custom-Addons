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
local module_key = "ItemIDs"
local module_name = L["Item ID"]
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
module.NewFilterValue_ID = L["Temp Item ID"]

function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
end

function module:OnDisable()
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

function module:CreateWidget()
	local frame_name = "PasslootBiS_Frames_Widgets_ItemID"
	return PasslootBiS:CreateTextBoxOptionalCheckBox(self, module_name, frame_name, module_tooltip)
end

module.Widget = module:CreateWidget()

local function compare(a, b)
	return a[1]:lower() < b[1]:lower()
end

-- return true if the tables are different
local function simplediff(a, b)
	if #a ~= #b then return true end
	for i = 1, #a do
		if a[i][1] ~= b[i][1] then return true end
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
		if (not hash[v[1]]) then
			a[#a + 1] = v
			hash[v[1]] = true
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
		module.NewFilterValue_ID,
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
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	if tonumber(Value[Index][1]) then
		return Value[Index][1] .. " - " .. C_Item.GetColoredItemName(Value[Index][1])
	end
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
	module.CurrentMatch = itemObj.id
	module:Debug("Item ID: " .. (module.CurrentMatch or ""))
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	local ID = tonumber(RuleValue[Index][1])
	if module.CurrentMatch == ID then
		module:Debug("Found item ID match")
		return true
	end

	return false
end

-- should be SetItemID, but trying to template the Widget creation
function module:SetItemName(Frame)
	local Value = self.Widget:GetData()
	Value[self.FilterIndex][1] = Frame:GetText()
	_, Value = cleandata(Value)
	self:SetConfigOption(module_key, Value)
end
