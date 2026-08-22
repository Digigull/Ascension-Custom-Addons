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
--
-- ## Why this module exists, when Type / SubType already has "Miscellaneous - Mount"
--
-- Chase items (mounts, companion pets) were being auto-GREEDED out of the box: they
-- fall past both starter rules to "Catch All > Greed", and a mount you have not got
-- the riding skill for is worse than that -- it carries a red requirement line, so
-- "Not Usable > Greed" claims it first. In a pick-up group the convention on a mount
-- or a pet is Need, so the default configuration was rolling the wrong thing on the
-- only drops anybody in the group actually cares about.
--
-- Modules/TypeSubType.lua can express "Miscellaneous - Mount", but it is not a safe
-- basis for a rule we SHIP, because it matches the subclass by NAME: it compares
-- GetItemInfo's localized subclass string against LibBabble's "Mount" / "Pet". Two
-- ways that misses on this server:
--   * the names are not fixed. Ascension's own database calls the two subclasses
--     "Mounts" (class 15 / subclass 5, e.g. Deathcharger's Reins, item 13335) and
--     "Companions" (class 15 / subclass 2, e.g. Sigil of Lethtendris, item 60060) --
--     neither is the singular string TypeSubType looks for. Whatever the live client
--     returns, a shipped default that hangs on one exact spelling is one DBC edit
--     away from silently doing nothing.
--   * a custom item can simply be filed wrong. 60060 is quality 6 ("Vanity"), an
--     Ascension-only quality; nothing says every custom collectible got the right
--     subclass.
-- So this module answers "is this a mount or a companion pet?" from TWO independent
-- signals and takes either: the subclass (cheap, no tooltip), and failing that the
-- item's own Use: line, which is what the player reads to decide it is a mount:
--   13335: "Use: Teaches you how to summon this mount. This is a Ground mount."
--   60060: "Use: Teaches you how to summon this companion.  This is a non-combat companion."
--
-- The module deliberately answers ONLY that question. Whether you already own the
-- thing is Modules/LearnedItem.lua's job, and the shipped rule (Core/Constants.lua
-- DefaultRules) combines the two rather than duplicating either.
local module_key = "MountPet"
local module_name = L["Mount / Pet"]
local module_tooltip = L["Selected rule will only match mounts and companion pets."]

local module = PasslootBiS:NewModule(module_name)

-- Choice 1 is "Mount or Pet", NOT "Any". Every other dropdown module's "Any" means
-- "do not filter on me", which would make this module a no-op -- the one thing a
-- rule that exists to single out mounts and pets must never be. Same shape as
-- Modules/VanityUnlock.lua, whose "Any" also means "is one of these".
module.Choices = {
	{
		["Name"] = L["Mount or Pet"],
		["Value"] = 1,
	},
	{
		["Name"] = L["Mount"],
		["Value"] = 2,
	},
	{
		["Name"] = L["Pet"],
		["Value"] = 3,
	},
}

-- SetMatch's verdict: 0 = neither, 2 = mount, 3 = pet (2/3 line up with Choices so
-- GetMatch can compare them directly).
module.MATCH_NONE = 0
module.MATCH_MOUNT = 2
module.MATCH_PET = 3
module.CurrentMatch = 0
-- How the last verdict was reached, for the trace and the /plbisreport dry run.
module.CurrentSource = "none"

-- Subclass strings that mean mount / companion pet, lowercased. Both spellings the
-- Ascension database uses are here alongside the client's own, and OnEnable adds
-- LibBabble's translation of "Mount" and "Pet" for non-enUS clients.
local MOUNT_SUBCLASS = {
	["mount"] = true,
	["mounts"] = true,
}
local PET_SUBCLASS = {
	["pet"] = true,
	["pets"] = true,
	["companion"] = true,
	["companions"] = true,
	["companion pets"] = true,
	["non-combat pet"] = true,
	["non-combat pets"] = true,
}

-- Fallback signal: the item's Use: line. Plain substring finds, not patterns -- the
-- text is a sentence, and a stray "-" in "non-combat" is a pattern character.
local MOUNT_TEXT = {
	"summon this mount",
	"summons this mount",
}
local PET_TEXT = {
	"summon this companion",
	"summons this companion",
	"summon this pet",
	"non-combat companion",
	"non-combat pet",
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

function module:SetupValues()
	local binv = LibStub("LibBabble-Inventory-3.0", true)
	if (not binv) then
		return
	end
	-- Unstrict: a locale missing the key returns nil instead of raising a translation
	-- warning at the user (Libs/LibBabble-Inventory-3.0/LibBabble-3.0.lua).
	local BI = binv:GetUnstrictLookupTable()
	if (BI["Mount"]) then
		MOUNT_SUBCLASS[string.lower(BI["Mount"])] = true
	end
	if (BI["Pet"]) then
		PET_SUBCLASS[string.lower(BI["Pet"])] = true
	end
end

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
	local frame_name = "PasslootBiS_Frames_Widgets_MountPet"
	return PasslootBiS:CreateSimpleDropdown(self, module_name, frame_name, module_tooltip)
end

module.Widget = module:CreateWidget()

-- Signal 1: GetItemInfo's subclass string. Costs nothing -- it is already on the
-- item object -- and is right for every mount and pet that is filed correctly.
local function subclassVerdict(subclass)
	if (type(subclass) ~= "string" or subclass == "") then
		return nil
	end
	local Key = string.lower(subclass)
	if (MOUNT_SUBCLASS[Key]) then
		return module.MATCH_MOUNT
	elseif (PET_SUBCLASS[Key]) then
		return module.MATCH_PET
	end
	return nil
end

local function findAny(Text, List)
	for _, Needle in ipairs(List) do
		if (string.find(Text, Needle, 1, true)) then
			return true
		end
	end
	return false
end

-- Signal 2: the tooltip's Use: line, for an item whose subclass does not say.
--
-- Stops at the first line beginning with a newline, exactly as Modules/LearnedItem.lua
-- does and for the same reason: that break is where a RECIPE's tooltip starts
-- describing the item it creates. Without it, "Recipe: Mekgineer's Chopper" would read
-- as a mount and Need itself -- the recipe is a trade good, and the convention this
-- module ships for is about the mount, not the pattern that makes one.
local function tooltipVerdict(itemObj)
	PasslootBiS:BuildTooltipCache(itemObj)
	local Cache = PasslootBiS.TooltipCache
	if (not (Cache and Cache.Left)) then
		return nil
	end
	for Index = 2, #Cache.Left do
		local Text = Cache.Left[Index]
		if (Text == nil or string.find(Text, "^\n")) then
			break
		end
		Text = string.lower(Text)
		if (findAny(Text, MOUNT_TEXT)) then
			return module.MATCH_MOUNT
		elseif (findAny(Text, PET_TEXT)) then
			return module.MATCH_PET
		end
	end
	return nil
end

-- Is this item a mount or a companion pet? Returns the verdict and the signal that
-- produced it. Shared so the item dry run (Core/DebugReport.lua) reports exactly what
-- the live filter decided rather than a second copy of this logic.
function module:Classify(itemObj)
	if (not itemObj) then
		return self.MATCH_NONE, "none"
	end
	local Verdict = subclassVerdict(itemObj.subclass)
	if (Verdict) then
		return Verdict, "subclass"
	end
	if (itemObj.link) then
		Verdict = tooltipVerdict(itemObj)
		if (Verdict) then
			return Verdict, "tooltip"
		end
	end
	return self.MATCH_NONE, "none"
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
	UIDropDownMenu_SetText(module.Widget, module:GetMountPetText(Value[module.FilterIndex][1]))
end

function module.Widget:GetFilterText(Index)
	local Value = self:GetData()
	return module:GetMountPetText(Value[Index][1])
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
	module.CurrentMatch, module.CurrentSource = module:Classify(itemObj)
	module:Debug("Mount / Pet: " .. module.CurrentMatch ..
		" (" .. module:MatchLabel(module.CurrentMatch) .. ", by " .. module.CurrentSource .. ")")
end

function module.Widget:GetMatch(RuleNum, Index)
	local RuleValue = self:GetData(RuleNum)
	local Want = RuleValue[Index][1]
	if (Want == 1) then -- "Mount or Pet": either verdict will do
		return module.CurrentMatch > module.MATCH_NONE
	end
	return Want == module.CurrentMatch
end

function module:DropDown_Init(Frame, Level)
	Level = Level or 1
	local info = {}
	info.checked = false
	info.notCheckable = true
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

-- Label for a VERDICT rather than for a dropdown choice: 0 ("neither") has no entry
-- in Choices, so GetMountPetText answers "" for it -- fine in the widget, useless in
-- a trace line or in the item dry run (Core/DebugReport.lua), which are the two places
-- that have to say the item is not one of these.
function module:MatchLabel(Which)
	if (Which == self.MATCH_MOUNT or Which == self.MATCH_PET) then
		return self:GetMountPetText(Which)
	end
	return "neither"
end

function module:GetMountPetText(Which)
	for Key, Value in ipairs(self.Choices) do
		if (Value.Value == Which) then
			return Value.Name
		end
	end
	return ""
end
