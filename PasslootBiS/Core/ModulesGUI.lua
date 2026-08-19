local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

-- Not using AceGUI until I decide to make my own multi-tier drop down menu widget.
-- local AceGUI = LibStub("AceGUI-3.0")

PasslootBiS.Prototypes = {}
PasslootBiS.PluginInfo = {}

-- Unused.  We can let the module unregister variables, and remove widgets from the filter list.
-- function PasslootBiS.Prototypes:OnDisable()
  -- ChatFrame1:AddMessage("OnDisable() Called for "..self:GetName())
  -- self:UnregisterDefaultVariables()
  -- self:RemoveWidgets()
-- end

-- Registers the default variables
-- RuleVariables = {
  -- { VariableName, Default},
  -- { VariableName, Default},
-- }
function PasslootBiS.Prototypes:RegisterDefaultVariables(RuleVariables)
  local Module = self:GetName()
  PasslootBiS.PluginInfo[Module] = PasslootBiS.PluginInfo[Module] or {}
  if ( type(RuleVariables) ~= "table" ) then
    return
  end
  for NewKey, NewValue in pairs(RuleVariables) do
    if ( type(NewValue) ~= "table" ) then
      return
    end
    for VariableKey, VariableValue in pairs(PasslootBiS.DefaultTemplate) do
      if ( NewValue[1] == VariableValue[1] ) then
        return
      end
    end
  end
  PasslootBiS.PluginInfo[Module].RuleVariables = PasslootBiS.PluginInfo[Module].RuleVariables or {}
  for Key, Value in pairs(RuleVariables) do
    -- table.insert(PasslootBiS.PluginInfo[self:GetName()].RuleVariables, { Value[1], PasslootBiS:CopyTable(Value[2]) })
    PasslootBiS.PluginInfo[self:GetName()].RuleVariables[Value[1]] = true
    -- table.sort(PasslootBiS.PluginInfo[self:GetName()].RuleVariables, function(A, B) if ( A[1] < B[1] ) then return true end end)
    table.insert(PasslootBiS.DefaultTemplate, { Value[1], PasslootBiS:CopyTable(Value[2]) })
  end
end

function PasslootBiS.Prototypes:UnregisterDefaultVariables()
  local Module = self:GetName()
  PasslootBiS.PluginInfo[Module] = PasslootBiS.PluginInfo[Module] or {}
  PasslootBiS.PluginInfo[Module].RuleVariables = PasslootBiS.PluginInfo[Module].RuleVariables or {}
  for VarKey, VarValue in pairs(PasslootBiS.PluginInfo[Module].RuleVariables) do
    for Index = #PasslootBiS.DefaultTemplate, 1, -1 do
      if ( PasslootBiS.DefaultTemplate[Index][1] == VarKey ) then
        table.remove(PasslootBiS.DefaultTemplate, Index)
        break
      end
    end
  end
end

-- Each Widget is a filter for PasslootBiS.
-- Each Filter must have: (Index refers to the index of multiple filters for the same rule)
-- GetNumFilters(RuleNum) -- Returns the number of filters for the rule
-- AddNewFilter() -- Creates a new filter for the currently selected rule
-- RemoveFilter(Index) -- Removes a filter from the currently selected rule at Index
-- DisplayWidget(Index) -- Called when the Filter is selected from the active filters list.  (Needs to prepare/update the widget's display, does not need to do Widget:Show())
-- GetFilterText(Index) -- Gets text to be displayed for the active filter scroll frame for the Filter's Index
-- SetMatch(ItemLink, Tooltip) -- Called when a loot window is popped up with the itemlink and tooltip frame of the item.
-- GetMatch(RuleNum, Index) -- Needs to return true/false if the loot matches this filter's index.  DO NOT RETURN INVERSE RESULTS IF EXCEPTION IS SET
-- IsException(RuleNum, Index)  -- If the filter is an exception.
-- SetException(RuleNum, Index, true/false) -- Set the exception.
function PasslootBiS.Prototypes:AddWidget(Widget)
  if ( type(Widget) ~= "table"
  or not Widget.GetNumFilters
  or not Widget.AddNewFilter
  or not Widget.RemoveFilter
  or not Widget.DisplayWidget
  or not Widget.GetFilterText
  or not Widget.SetMatch
  or not Widget.GetMatch
  or type(Widget.Info) ~= "table" ) then
    -- 1 = Module Text to display in filter list
    -- 2 = Tooltip info
    -- 3 = Module this belongs to.  (Set here)
    return
  end
  if ( not Widget.IsException or not Widget.SetException ) then
    Widget.IsException = PasslootBiS.TempIsException
    Widget.SetException = PasslootBiS.TempSetException
  end
  PasslootBiS.RuleWidgets = PasslootBiS.RuleWidgets or {}
  for Key, Value in pairs(PasslootBiS.RuleWidgets) do
    if ( Value == Widget ) then
      return
    end
  end
  local Module = self:GetName()
  Widget.Info[3] = Module
  Widget.PreferredPriority = Widget.PreferredPriority or 1000
  -- Widget.ModuleOwner = self:GetName()
  table.insert(PasslootBiS.RuleWidgets, Widget)
  -- PasslootBiS:Settings_ScrollFrame_Update()
  -- table.sort(PasslootBiS.RuleWidgets, function(a, b) if ( a.PreferredPriority < b.PreferredPriority ) then return true end end)
  table.sort(PasslootBiS.RuleWidgets, function(a, b) if ( (a.Info[3] < b.Info[3]) or ((a.Info[3] == b.Info[3]) and (a.PreferredPriority < b.PreferredPriority)) ) then return true end end)
  Widget:ClearAllPoints()
  -- Anchored under the filter lists' button row, NOT up from the settings box's
  -- bottom edge as this used to be: that box no longer has a fixed height (it takes
  -- whatever the options panel leaves below the rule list, Core/MainGUI.lua), so
  -- anchoring to its bottom would slide the widget up into the filter lists. -27
  -- from the filter boxes' bottom is exactly where this sat when the box was 298.
  Widget:SetPoint("TOP", PasslootBiS.RulesFrame.Settings.AvailableFilters, "BOTTOM", ((Widget.XPaddingLeft or 0) - (Widget.XPaddingRight or 0)) / 2, -27 - (Widget.YPaddingTop or 0))
  Widget:SetParent(PasslootBiS.RulesFrame.Settings)
  Widget:Hide()
  PasslootBiS.PluginInfo[Module] = PasslootBiS.PluginInfo[Module] or {}
  PasslootBiS.PluginInfo[Module].RuleWidgets = PasslootBiS.PluginInfo[Module].RuleWidgets or {}
  for Key, Value in pairs(PasslootBiS.PluginInfo[Module].RuleWidgets) do
    if ( Value == Widget ) then
      return
    end
  end
  table.insert(PasslootBiS.PluginInfo[Module].RuleWidgets, Widget)
end

function PasslootBiS.Prototypes:RemoveWidgets()
  local Module = self:GetName()
  PasslootBiS.PluginInfo[Module] = PasslootBiS.PluginInfo[Module] or {}
  PasslootBiS.PluginInfo[Module].RuleWidgets = PasslootBiS.PluginInfo[Module].RuleWidgets or {}
  for PluginKey, PluginValue in pairs(PasslootBiS.PluginInfo[Module].RuleWidgets) do
    for RuleKey, RuleValue in pairs(PasslootBiS.RuleWidgets) do
      if ( RuleValue == PluginValue ) then
        PluginValue:Hide()
        PluginValue:SetParent(nil)
        table.remove(PasslootBiS.RuleWidgets, RuleKey)
        break
      end
    end
  end
end

function PasslootBiS.Prototypes:AddModuleOptionTable(TableName, Table)
  local Module = self:GetName()
  if ( not PasslootBiS.OptionsTable.args.Modules.args[Module].args[TableName] ) then
    PasslootBiS.OptionsTable.args.Modules.args[Module].args[TableName] = Table
  end
end

function PasslootBiS.Prototypes:RemoveModuleOptionTable(TableName)
  local Module = self:GetName()
  if ( PasslootBiS.OptionsTable.args.Modules.args[Module].args[TableName] ) then
    PasslootBiS.OptionsTable.args.Modules.args[Module].args[TableName] = nil
  end
end

-- Sets a variable in the rule.  This function verifies that the variable being set is registered to the module.
function PasslootBiS.Prototypes:SetConfigOption(Variable, Value, RuleNum)
  local Module = self:GetName()
  RuleNum = RuleNum or PasslootBiS.CurrentRule
  if ( RuleNum > 0
  and Module
  and PasslootBiS.PluginInfo[Module]
  and PasslootBiS.PluginInfo[Module].RuleVariables ) then
    if ( PasslootBiS.PluginInfo[Module].RuleVariables[Variable] ) then
      PasslootBiS.db.profile.Rules[RuleNum][Variable] = Value
      PasslootBiS:Rules_ActiveFilters_OnScroll()
      return
    end
  end
end

-- Gets a variable from a rule.  This function does not verify that the variable belongs to the module.
function PasslootBiS.Prototypes:GetConfigOption(Variable, RuleNum)
  RuleNum = RuleNum or PasslootBiS.CurrentRule
  if ( RuleNum > 0 ) then
    return PasslootBiS.db.profile.Rules[RuleNum][Variable]
  end
end

function PasslootBiS.Prototypes:SetGlobalVariable(Variable, Value)
  local Module = self:GetName()
  if ( Module
  and PasslootBiS.db.global.Modules
  and PasslootBiS.db.global.Modules[Module] ) then
    PasslootBiS.db.global.Modules[Module].Vars = PasslootBiS.db.global.Modules[Module].Vars or {}
    PasslootBiS.db.global.Modules[Module].Vars[Variable] = Value
  end
end

function PasslootBiS.Prototypes:GetGlobalVariable(Variable)
  local Module = self:GetName()
  if ( Module
  and PasslootBiS.db.global.Modules
  and PasslootBiS.db.global.Modules[Module]
  and PasslootBiS.db.global.Modules[Module].Vars ) then
    return PasslootBiS.db.global.Modules[Module].Vars[Variable]
  end
end

function PasslootBiS.Prototypes:SetProfileVariable(Variable, Value)
  local Module = self:GetName()
  if ( Module
  and PasslootBiS.db.profile.Modules
  and PasslootBiS.db.profile.Modules[Module] ) then
    PasslootBiS.db.profile.Modules[Module].ProfileVars = PasslootBiS.db.profile.Modules[Module].ProfileVars or {}
    PasslootBiS.db.profile.Modules[Module].ProfileVars[Variable] = Value
  end
end

function PasslootBiS.Prototypes:GetProfileVariable(Variable)
  local Module = self:GetName()
  if ( Module
  and PasslootBiS.db.profile.Modules
  and PasslootBiS.db.profile.Modules[Module]
  and PasslootBiS.db.profile.Modules[Module].ProfileVars ) then
    return PasslootBiS.db.profile.Modules[Module].ProfileVars[Variable]
  end
end

PasslootBiS.Prototypes.ShowTooltip = PasslootBiS.ShowTooltip

-- I am going to use this function to scroll text boxes to the left instead of SetCursorPosition()
-- SetCursorPosition(0) requires I ClearFocus(), which will create a loop that I don't really like.
PasslootBiS.Prototypes.ScrollLeft = PasslootBiS.ScrollLeft

function PasslootBiS.Prototypes:Debug(...)
  local DebugLine, Counter
  if ( PasslootBiS.DebugVar == true ) then
    if ( self.GetName ) then
      DebugLine = "("..(self:GetName() or "")..") "
    else
      DebugLine = ""
    end
    for Counter = 1, select("#", ...) do
      DebugLine = DebugLine..select(Counter, ...)
    end
    -- PasslootBiS:Print(_G[PasslootBiS.db.profile.OutputFrame], DebugLine)
    PasslootBiS:Pour("|cff33ff99PasslootBiS|r: "..DebugLine)
  end
end

PasslootBiS:SetDefaultModulePrototype(PasslootBiS.Prototypes)
PasslootBiS:SetDefaultModuleState(false)

function PasslootBiS:IsModuleEnabled(Info)
  return self.modules[Info.arg].enabledState
end

function PasslootBiS:SetModuleEnabled(Info, Value)
  local Module = Info.arg
  self.db.profile.Modules[Module].Status = Value
  if ( Value ) then
    self:EnableModule(Module)
  else
    self:DisableModule(Module)
  end
  self:CheckRuleTables()
  self:Rules_RuleList_OnScroll()
  self:DisplayCurrentRule()
  -- self:CountEnabledModules()
end

local Modules_ScrollFrame_RowSpacing = 3
local Modules_ScrollFrame_InitialHeight = 10
function PasslootBiS:SetupModulesOptionsTables()
  local Module
  for Key, Value in self:IterateModules() do
    Module = Value:GetName()
    self.db.profile.Modules[Module] = self.db.profile.Modules[Module] or {}
    if ( not self.OptionsTable.args.Modules.args[Module] ) then
      self.OptionsTable.args.Modules.args[Module] = {
        ["name"] = Module,
        ["type"] = "group",
        ["inline"] = true,
        ["args"] = {
          ["Enabled"] = {
            ["name"] = L["Enabled"],
            ["desc"] = L["Enable / Disable this module."],
            ["type"] = "toggle",
            ["order"] = 0,
            ["get"] = "IsModuleEnabled",
            ["set"] = "SetModuleEnabled",
            ["arg"] = Module,
          },
        },
      }
    end
  end
end

function PasslootBiS:TempIsException()
  return false
end

function PasslootBiS:TempSetException()
end
