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
local module_key = "ConfirmDE"
local module_name = L["Confirm DE"]
local module_tooltip = L["Will click yes on Disenchant dialogues."]

local module = PasslootBiS:NewModule(module_name, "AceEvent-3.0")
if (not module) then
	return
end

module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{ module_key, nil },
}
module.NewFilterValue = true

local Hooked = false
function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
	-- self:RegisterEvent("LOOT_BIND_CONFIRM")  -- Fired when you loot an item that isn't being rolled on
	self:RegisterEvent("CONFIRM_DISENCHANT_ROLL")
	self:RegisterMessage("PasslootBiS_OnRoll")
	-- if ( not Hooked ) then
	-- hooksecurefunc("StaticPopup_OnShow", function(...) self:StaticPopup_OnShow(...) end)
	-- Hooked = true
	-- end
	self.ItemsAwaitingConfirmation = {}
end

function module:OnDisable()
	self:UnregisterEvent("CONFIRM_DISENCHANT_ROLL")
	-- self:UnregisterEvent("CHAT_MSG_LOOT")
	self:UnregisterMessage("PasslootBiS_OnRoll")
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

-- Order of events currently in 3.3:
-- PasslootBiS Matches a rule
-- PasslootBiS sends Message, Should check if the rule we matched it on, has our ConfirmDE status.  If so, add to ItemsAwaitingConfirmation
-- PasslootBiS tries to roll
-- StaticPopup_OnShow("CONFIRM_LOOT_ROLL")
-- Event CONFIRM_DISENCHANT_ROLL()
-- If we accept, roll proceeds, and we win or don't win.
function module:PasslootBiS_OnRoll(Event, ItemLink, RuleNum, RollID, RollMethod)
	self:Debug("ConfirmDE is being told Passloot is rolling!")
	if (not RollID) then
		return                              -- Adding this because when I use test items, no rollid is done.
	end
	local Value = self.Widget:GetData(RuleNum) -- Is this filter added to the rule number we are using to roll on?
	if (Value and RollMethod ~= 0 and RollMethod ~= 1 and RollMethod ~= 2) then
		-- If this is a matching rule with THIS filter
		-- And we did not roll GREED/NEED/PASS (Allow Ignore/DE), then added it to ItemsAwaitingConfirmation
		self.ItemsAwaitingConfirmation[RollID] = { ItemLink, RuleNum, RollID, 0 }
	end
end

--[=[
function module:StaticPopup_OnShow(...)
  if ( not self:IsEnabled() ) then
    return
  end
  self:Debug("popup on show happened!")
  local Frame = ...
  -- Frame.which = "LOOT_BIND_CONFIRM" happens when trying to pick up a BoP item
  -- Frame.which = "CONFIRM_LOOT_ROLL" happens when rolling on a BoP item or rolling DE on a BoP item.
  self:Debug("Frame.which "..Frame.which)
  if ( Frame.which == "CONFIRM_LOOT_ROLL" ) then
    local Text = _G[Frame:GetName().."Text"]:GetText()
    -- module.TempText = Text
    self:Debug("Text: "..Text)
    local Item
    self:Debug("Checking items awaiting confirmation")
    for Key, Value in pairs(self.ItemsAwaitingConfirmation) do
    self:Debug("Item: "..Value[1])
      Item = GetItemInfo(Value[1])
      Item = string.gsub(Item, "([%%%$%(%)%.%[%]%*%+%-%?%^])", "%%%1") -- special case for regex special characters.
      if ( string.find(Text, Item) ) then
        self:Debug("Found frame, hiding it")
        Frame:Hide()
        self:RemoveItemAwaitingConfirmation(Key)
        break
      end
    end
  end
end
]=]

function module:CONFIRM_DISENCHANT_ROLL(Event, RollID, RollMethod)
	self:Debug("ConfirmDE CONFIRM_DISENCHANT_ROLL")
	-- local arg1, arg2 = ...
	-- local ItemLink = GetLootSlotLink(arg2)  -- The slot in the actuall loot window
	local ItemLink = GetLootRollItemLink(RollID)
	self:Debug("ItemLink: " .. (ItemLink or "nil"))
	if (self.ItemsAwaitingConfirmation[RollID] and self.ItemsAwaitingConfirmation[RollID][1] == ItemLink) then
		self:Debug("ConfirmLootRoll(" .. RollID .. "," .. RollMethod .. ")")
		ConfirmLootRoll(RollID, RollMethod)
		StaticPopup_Hide("CONFIRM_LOOT_ROLL", RollID)
		self.ItemsAwaitingConfirmation[RollID] = nil
	end
	--[=[
  self:Debug("Checking items awaiting confirmation")
  for Key, Value in pairs(self.ItemsAwaitingConfirmation) do
    self:Debug("Item: "..Value[1])
    if ( ItemLink == Value[1] ) then
      self:Debug("ConfirmLootRoll("..RollID..","..RollMethod..")")
      ConfirmLootRoll(RollID, RollMethod)
      self:RemoveItemAwaitingConfirmation(Key)
      break
    end
  end
  ]=]
end

--[=[
-- We basically want to only remove the item from ItemsAwaitingConfirmation once both LOOT_BIND_CONFIRM and StaticPopup_Show has been called.
function module:RemoveItemAwaitingConfirmation(Key)
  self.ItemsAwaitingConfirmation[Key][4] = self.ItemsAwaitingConfirmation[Key][4] + 1
  if ( self.ItemsAwaitingConfirmation[Key][4] >= 2 ) then
    self:Debug("removing from ItemsAwaitingConfirmation")
    table.remove(self.ItemsAwaitingConfirmation, Key)
  end
end
]=]

function module:CreateWidget()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(150)
	Frame:SetHeight(30)

	Frame.Title = Frame:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
	Frame.Title:SetParent(Frame)
	Frame.Title:SetPoint("TOPLEFT", Frame, "TOPLEFT")
	Frame.Title:SetText(L["Will confirm disenchant!"])

	Frame.Height = Frame:GetHeight()
	Frame.Width = Frame:GetWidth()

	Frame.Info = {
		module_name,
		module_tooltip,
	}
	Frame.PreferredPriority = 6
	return Frame
end

module.Widget = module:CreateWidget()

-- Local function to get the data and make sure it's valid data
function module.Widget:GetData(RuleNum)
  local Data = module:GetConfigOption("ConfirmDE", RuleNum)
  if ( Data ~= nil and Data ~= true ) then
    Data = true
    module:SetConfigOption("ConfirmDE", Data)
  end
  return Data
end

function module.Widget:GetNumFilters(RuleNum)
	local Value = self:GetData(RuleNum)
	if (Value) then
		return 1
	else
		return 0
	end
end

function module.Widget:AddNewFilter()
	local Dialog = StaticPopup_Show("PasslootBiS_ConfirmDE")
	if (Dialog) then
		Dialog.PasslootBiS_ConfirmDE = PasslootBiS.CurrentRule
	end
end

function module.Widget:RemoveFilter(Index)
	module:SetConfigOption(module_key, nil)
end

function module.Widget:DisplayWidget(Index)
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	if (Value) then
		return L["Will confirm disenchant!"]
	end
end

function module.Widget:IsException(RuleNum, Index)
	return false
end

function module.Widget:SetException(RuleNum, Index, Value)
end

function module.Widget:SetMatch(itemObj, Tooltip)
end

function module.Widget:GetMatch(RuleNum, Index)
	return true
end

StaticPopupDialogs.PasslootBiS_ConfirmDE = {
	["text"] = L
		["By adding the Confirm DE filter you will not get any confirmations when rolling disenchant.  This might get you into trouble with your group, are you sure?"],
	["button1"] = YES,
	["button2"] = NO,
	["timeout"] = 0,
	["whileDead"] = 1,
	["hideOnEscape"] = 1,
	["OnAccept"] = function(self)
		if (self.PasslootBiS_ConfirmDE) then
			module:SetConfigOption(module_key, module.NewFilterValue, self.PasslootBiS_ConfirmDE)
			self.PasslootBiS_ConfirmDE = nil
		end
	end,
	["OnCancel"] = function(self)
		self.PasslootBiS_ConfirmDE = nil
	end,
}
