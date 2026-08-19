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
local module_key = "ConfirmBoP"
local module_name = L["Confirm BoP"]
local module_tooltip = L["Will click yes on BoP dialogues."]

local module = PasslootBiS:NewModule(module_name, "AceEvent-3.0")

if (not module) then
	return
end

-- ToDo:  Since we added manual option, we need to hook the buttons to remove item from itemsawaitingconfirmation
module.ConfigOptions_RuleDefaults = {
	-- { VariableName, Default },
	{ module_key, nil },
}
module.NewFilterValue = true

local Hooked = false
function module:OnEnable()
	self:RegisterDefaultVariables(self.ConfigOptions_RuleDefaults)
	self:AddWidget(self.Widget)
	-- LOOT_BIND_CONFIRM (the bind warning when you LOOT a BoP item rather than roll
	-- on one) is deliberately not handled here: it carries a loot slot, not a RollID,
	-- so there is no rule to hang this per-rule filter off. It is a profile-wide
	-- toggle instead -- see PasslootBiS:LOOT_BIND_CONFIRM in Core/PassLoot.lua. Do not
	-- register it here as well, or the slot gets confirmed twice.
	self:RegisterEvent("CONFIRM_LOOT_ROLL")
	-- self:RegisterEvent("CHAT_MSG_LOOT")
	self:RegisterMessage("PasslootBiS_OnRoll")
	-- if ( not Hooked ) then
	-- hooksecurefunc("StaticPopup_OnShow", function(...) self:StaticPopup_OnShow(...) end)
	-- Hooked = true
	-- end
	self.ItemsAwaitingConfirmation = {}
end

function module:OnDisable()
	-- Unregister what OnEnable actually registered. This used to unregister
	-- LOOT_BIND_CONFIRM, which this module has never listened for, and so left
	-- CONFIRM_LOOT_ROLL live after the module was switched off.
	self:UnregisterEvent("CONFIRM_LOOT_ROLL")
	-- self:UnregisterEvent("CHAT_MSG_LOOT")
	self:UnregisterMessage("PasslootBiS_OnRoll")
	self:UnregisterDefaultVariables()
	self:RemoveWidgets()
end

-- Order of events currently in 3.0:
-- PasslootBiS Matches a rule
-- PasslootBiS sends Message, Should check if the rule we matched it on, has our ConfirmBoP status.  If so, add to ItemsAwaitingConfirmation
-- PasslootBiS tries to roll
-- StaticPopup_OnShow("CONFIRM_LOOT_ROLL")
-- Event CONFIRM_LOOT_ROLL
-- If we accept, roll proceeds, and we win or don't win.
function module:PasslootBiS_OnRoll(Event, ItemLink, RuleNum, RollID, RollMethod)
	self:Debug("ConfirmBoP is being told Passloot is rolling!")
	if (not RollID) then
		return                               -- Adding this because when I use test items, no rollid is done.
	end
	local Value = self.Widget:GetData(RuleNum) -- Is this filter added to the rule number we are using to roll on?
	local _, _, _, _, BoP = GetLootRollItemInfo(RollID)
	-- if ( Value and BoP and RollMethod and RollMethod > 0) then
	if (Value and BoP and RollMethod ~= 0 and RollMethod ~= 3) then
		-- If this is a matching rule with THIS filter
		-- And the item is BoP
		-- And we did not roll PASS/DE (Allow Ignore/GREED/NEED), then added it to ItemsAwaitingConfirmation
		self.ItemsAwaitingConfirmation[RollID] = { ItemLink, RuleNum }
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
  -- Frame.which = "CONFIRM_LOOT_ROLL" happens when rolling on a BoP item
  self:Debug("Frame.which "..Frame.which)
  if ( Frame.which == "CONFIRM_LOOT_ROLL" ) then
    local Text = _G[Frame:GetName().."Text"]:GetText()
    self:Debug("Text in popup: "..Text)
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

function module:CONFIRM_LOOT_ROLL(Event, RollID, RollMethod)
	self:Debug("ConfirmBoP CONFIRM_LOOT_ROLL")
	-- local arg1, arg2 = ...
	-- local ItemLink = GetLootSlotLink(arg2)  -- The slot in the actuall loot window
	local ItemLink = GetLootRollItemLink(RollID)
	self:Debug("ItemLink: " .. (ItemLink or "nil"))
	-- self:Debug("Checking items awaiting confirmation")
	if (self.ItemsAwaitingConfirmation[RollID] and ItemLink == self.ItemsAwaitingConfirmation[RollID][1]) then
		-- Routed through the shared once-guard (PasslootBiS:ConfirmRollOnce): the
		-- profile-wide AutoConfirmBindOnRoll answers this same event, so on a rule
		-- that HAS this filter ticked both handlers fire for one roll. The guard makes
		-- whichever runs second a no-op, and owns the popup-hide (twice, for the
		-- dispatch-order reason documented there) instead of the single hide this
		-- used to do.
		PasslootBiS:ConfirmRollOnce(RollID, RollMethod)
		self.ItemsAwaitingConfirmation[RollID] = nil
	end
	--[=[
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
    self.ItemsAwaitingConfirmation[Key] = nil
  end
end
]=]

-- function module:CHAT_MSG_LOOT(Event, ...)
-- needbeforegreed is round robin + rolling on some items.
-- if ( GetLootMethod() == "group" or #self.ItemsBeingRolledOn == 0 ) then
-- if ( #self.ItemsBeingRolledOn == 0 ) then
-- return
-- end
-- local CurrentCounter
-- local Pattern = string.gsub(LOOT_ROLL_WON, "%%s", "(.+)")
-- local Start, End, Who, Item = string.find(select(1, ...), Pattern)
-- if ( Start and Who and Item ) then
-- self:Debug("Someone won "..Item)
-- for Key, Value in pairs(self.ItemsBeingRolledOn) do
-- if ( Value[1] == Item and PasslootBiS.db.profile.Rules[Value[2]] ) then
-- if ( Who == YOU or Who == UnitName("player") ) then
-- self:Debug("We won "..Item)
-- table.insert(self.ItemsAwaitingConfirmation, ItemLink)
-- else
-- self:Debug("Someone else won "..Item)
-- end
-- self:Debug("Removing "..Item.." from ItemsBeingRolledOn")
-- table.remove(self.ItemsBeingRolledOn, Key)
-- return
-- end
-- end
-- end
-- Pattern = string.gsub(LOOT_ROLL_ALL_PASSED, "%%s", "(.+)")
-- Start, End, Item = string.find(select(1, ...), Pattern)
-- if ( Start and Item ) then
-- self:Debug("Everyone passed on "..Item)
-- for Key, Value in pairs(self.ItemsBeingRolledOn) do
-- if ( Value[1] == Item ) then
-- self:Debug("Removing "..Item.." from ItemsBeingRolledOn")
-- table.remove(self.ItemsBeingRolledOn, Key)
-- return
-- end
-- end
-- end
-- end

function module:CreateWidget()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(150)
	Frame:SetHeight(30)

	Frame.Title = Frame:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
	Frame.Title:SetParent(Frame)
	Frame.Title:SetPoint("TOPLEFT", Frame, "TOPLEFT")
	Frame.Title:SetText(L["Will confirm bind!"])

	Frame.Height = Frame:GetHeight()
	Frame.Width = Frame:GetWidth()

	Frame.Info = {
		module_name,
		module_tooltip,
	}
	Frame.PreferredPriority = 5
	return Frame
end

module.Widget = module:CreateWidget()

-- Local function to get the data and make sure it's valid data
function module.Widget:GetData(RuleNum)
  return module:GetConfigOption("ConfirmBoP", RuleNum)
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
	module:SetConfigOption(module_key, module.NewFilterValue)
end

function module.Widget:RemoveFilter(Index)
	module:SetConfigOption(module_key, nil)
end

function module.Widget:DisplayWidget(Index)
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	if (Value) then
		return L["Will confirm bind!"]
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
