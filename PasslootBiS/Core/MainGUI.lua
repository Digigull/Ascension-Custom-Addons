local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")
local LootOrderIcons = {
	"Interface\\MoneyFrame\\UI-GoldIcon",
	"Interface\\MoneyFrame\\UI-SilverIcon",
	"Interface\\MoneyFrame\\UI-CopperIcon",
}

--[=[  Frame layout:
PasslootBiS.RulesFrame = {
	["List"] = {  -- Has a background
		-- Two sections, in roll order: "Before" (rules ticked Before Advisor, tried
		-- first, rolled without asking the advisor) then "After" (everything else).
		-- Each scrolls over its own slice of db.profile.Rules and is reordered on its
		-- own; the rules array is kept partitioned to match (PasslootBiS:PartitionRules,
		-- Core/PassLoot.lua) so the two sections ARE the evaluation order.
		["Sections"] = {
			["Before"] and ["After"] = {  -- no background of their own
				["Title"] = FontString,
				["TitleHit"] = Frame,  -- mouse target for the heading's tooltip
				["ScrollFrame"] = FauxScrollFrame,
				["ScrollLine1"] = {
					["RuleNum"] = index into db.profile.Rules, set on every paint,
					["Highlight"] = Highlight Texture,
					["Text"] = FontString,
					["Need"] = CheckButton {
						["Title"] = FontString,
					},
					["Disenchant"] = CheckButton { ... },
					["Greed"] = CheckButton { ... },
					["Pass"] = CheckButton { ... },
					["BeforeAdvisor"] = CheckButton { ... },  -- moves the rule between sections
				},
				["ScrollLine3"],
			},
		},
		["Divider"] = Texture,  -- the line between the two sections
		["Add"] = Button,
		["Remove"] = Button,
		["Up"] = Button,        -- both move within one section only
		["Down"] = Button,
	},
	["Settings"] = {  -- Has a background
		["Desc"] = EditBox {
			["Title"] = FontString,
		},
		["AvailableFilters"] = {  -- Has a background
			["Title"] = FontString,
			["ScrollFrame"] = FauxScrollFrame,
			["ScrollLine1"] = {
				["Highlight"] = Highlight Texture,
				["Text"] = FontString,
			},
			["ScrollLine8"],
		},
		["ActiveFilters"] = {  -- Has a background
			["Title"] = FontString,
			["ScrollFrame"] = FauxScrollFrame,
			["ScrollLine1"] = {
				["Highlight"] = Highlight Texture,
				["Text"] = FontString,
			},
			["ScrollLine8"],
		},
		["Add"] = Button,
		["Remove"] = Button,
		-- We insert rule widgets here, PasslootBiS.PluginInfo[ModuleName].RuleWidgets is a table of widgets per module.
	},
}
]=]

function PasslootBiS:ShowTooltip(...)
	if (select("#", ...) == 0) then
		return
	end
	-- GameTooltip:SetOwner(PasslootBiS_MainFrame, "ANCHOR_TOPLEFT")
	GameTooltip:SetOwner(InterfaceOptionsFramePanelContainer, "ANCHOR_TOPLEFT")
	GameTooltip:SetText(PasslootBiS.FontWhite .. select(1, ...))
	for i = 2, select("#", ...) do
		GameTooltip:AddLine(PasslootBiS.FontGold .. select(i, ...))
	end
	GameTooltip:Show()
end

--Function to copy tables, since passing tables is always by reference.
function PasslootBiS:CopyTable(OldDB)
	if (not OldDB or type(OldDB) ~= "table") then
		return OldDB
	end
	local NewDB
	NewDB = {}
	for Key, Value in pairs(OldDB) do
		if (type(Value) ~= "table") then
			NewDB[Key] = Value
		else
			NewDB[Key] = self:CopyTable(Value)
		end
	end
	return NewDB
end

-- I am going to use this function to scroll text boxes to the left instead of SetCursorPosition()
-- SetCursorPosition(0) requires I ClearFocus(), which will create a loop that I don't really like.
function PasslootBiS:ScrollLeft(Frame, Elapsed)
	Frame:HighlightText(0, 1)
	Frame:Insert(" " .. strsub(Frame:GetText(), 1, 1))
	Frame:HighlightText(0, 1)
	Frame:Insert("")
	Frame:SetScript("OnUpdate", nil)
end

function PasslootBiS:DisplayCurrentRule()
	if (not self.CurrentRule) then
		self.CurrentRule = 0
	end
	self.CurrentOptionFilter = { nil, 0 } -- Frame, line #
	self:BuildUnknownVars()
	self:DisplayCurrentOptionFilter()
	if (self.CurrentRule > 0) then
		self.RulesFrame.Settings.Desc:Show()
		self.RulesFrame.Settings.AvailableFilters:Show()
		self.RulesFrame.Settings.ActiveFilters:Show()
		self:Rules_AvailableFilters_OnScroll()
		self:Rules_ActiveFilters_OnScroll()
		self.RulesFrame.Settings.Desc:SetText(self.db.profile.Rules[self.CurrentRule].Desc)
		self.RulesFrame.Settings.Desc:SetScript("OnUpdate", function(...) self:ScrollLeft(...) end)
	else
		self.RulesFrame.Settings.Desc:Hide()
		self.RulesFrame.Settings.AvailableFilters:Hide()
		self.RulesFrame.Settings.ActiveFilters:Hide()
	end
end

-- Show the widget that is selected
function PasslootBiS:DisplayCurrentOptionFilter()
	local Widget
	if (self.OldOptionFilter) then
		self.OldOptionFilter:Hide()
	end
	if (self.CurrentOptionFilter[1] == "Available") then
		self.RulesFrame.Settings.Add:Show()
		self.RulesFrame.Settings.Remove:Hide()
		self.RulesFrame.Settings.Exception:Hide()
	elseif (self.CurrentOptionFilter[1] == "Active") then
		local WidgetKey, Offset, KnownVar = self:GetWidgetFromLineNum(self.CurrentOptionFilter[2])
		self.RulesFrame.Settings.Add:Hide()
		self.RulesFrame.Settings.Remove:Show()
		if (KnownVar) then
			self.RulesFrame.Settings.Exception:Show()
			if (Offset) then
				Widget = self.RuleWidgets[WidgetKey]
				Widget:DisplayWidget(Offset)
				Widget:Show()
			end
		else
			self.RulesFrame.Settings.Exception:Hide()
		end
	else
		self.RulesFrame.Settings.Add:Hide()
		self.RulesFrame.Settings.Remove:Hide()
		self.RulesFrame.Settings.Exception:Hide()
	end
	self.OldOptionFilter = Widget
end

-- The rule a scroll line is currently showing. Lines are recycled across BOTH
-- sections of the list and across scroll offsets, so the line carries the rule
-- index the last paint gave it (Rules_RuleSection_OnScroll) rather than deriving
-- one from its position -- there is no single offset to derive it from any more.
-- nil on a line that is painted blank (an empty section, or past the last rule).
local function ruleOf(Line)
	return Line and Line.RuleNum
end

function PasslootBiS:SetLootMethod(Line, Method)
	local RuleNum = ruleOf(Line)
	if (not RuleNum or not self.db.profile.Rules[RuleNum]) then
		return
	end
	local Value
	if (Method == "pass") then
		Value = Line.Pass:GetChecked()
	elseif (Method == "greed") then
		Value = Line.Greed:GetChecked()
	elseif (Method == "need") then
		Value = Line.Need:GetChecked()
	elseif (Method == "de") then
		Value = Line.Disenchant:GetChecked()
	end
	if (Value) then
		table.insert(self.db.profile.Rules[RuleNum].Loot, Method)
		table.sort(self.db.profile.Rules[RuleNum].Loot,
			function(a, b) return self.RollOrderToIndex[a] < self.RollOrderToIndex[b] end)
	else
		for LootKey, LootValue in pairs(self.db.profile.Rules[RuleNum].Loot) do
			if (LootValue == Method) then
				table.remove(self.db.profile.Rules[RuleNum].Loot, LootKey)
				return
			end
		end
		self:Debug("Couldn't find roll method to remove")
	end
end

-- Toggle a rule's "Before Advisor" flag from the rightmost checkbox on its line.
-- The click has already flipped the checkbox's visual state, so read it back the
-- way SetLootMethod does. Stored as true / nil rather than true / false, matching
-- the addon's other runtime rule flag (Disabled, Core/MinimapButton.lua).
--
-- The tick is also what MOVES a rule between the list's two sections, so re-sort
-- and repaint: PartitionRules (Core/PassLoot.lua) lifts it to the end of the Before
-- Advisor block, or drops it to the head of the block below, and hands back where
-- the rule ended up so the selection follows it instead of staying on an index that
-- is now a different rule.
function PasslootBiS:SetBeforeAdvisor(Line)
	local RuleNum = ruleOf(Line)
	local Rule = RuleNum and self.db.profile.Rules[RuleNum]
	if (not Rule) then
		return
	end
	Rule.BeforeAdvisor = Line.BeforeAdvisor:GetChecked() and true or nil
	self.CurrentRule = self:PartitionRules(nil, RuleNum) or 0
	self:Rules_RuleList_OnScroll()
	self:RevealCurrentRule()
	self:DisplayCurrentRule()
end

function PasslootBiS:SetDisenchant(Line)
	local RuleNum = ruleOf(Line)
	local Rule = RuleNum and self.db.profile.Rules[RuleNum]
	if (not Rule) then
		return
	end
	if (Rule.Disenchant) then
		Rule.Disenchant = nil
		Line.Disenchant:SetChecked(false)
	else
		Rule.Disenchant = true
	end
end

-- Select the rule a line is showing. Repaints rather than walking the lines to move
-- the highlight: the highlight is one line of the paint, and there are two sections
-- of lines to clear now, one of which may be showing a different scroll offset.
function PasslootBiS:SetCurrentRule(Line)
	self.CurrentRule = ruleOf(Line) or 0
	self:Rules_RuleList_OnScroll()
	self:DisplayCurrentRule()
end

function PasslootBiS:BuildUnknownVars()
	-- Check what variables are unknown in this rule.
	for Key, Value in pairs(self.CurrentRuleUnknownVars) do
		self.CurrentRuleUnknownVars[Key] = nil
	end
	if (self.CurrentRule > 0) then
		for VarKey, VarValue in pairs(self.db.profile.Rules[self.CurrentRule]) do
			if (not self.DefaultVars[VarKey]) then
				table.insert(self.CurrentRuleUnknownVars, VarKey)
				self:Debug("Unknown key: " .. VarKey)
			end
		end
		table.sort(self.CurrentRuleUnknownVars)
		if (#self.CurrentRuleUnknownVars == 0) then
			self.SkipRules[self.CurrentRule] = nil
		else
			self.SkipRules[self.CurrentRule] = true
		end
	end
end

-- Sets what filter list was selected and what line number was selected, and highlights the line.
function PasslootBiS:SetCurrentOptionFilter(FilterList, LineNum, Button)
	local Counter
	self.CurrentOptionFilter = {
		FilterList,
		LineNum + FauxScrollFrame_GetOffset(self.RulesFrame.Settings[FilterList .. "Filters"].ScrollFrame),
	}
	if (Button == "RightButton" and IsShiftKeyDown() and FilterList == "Active") then
		self:RemoveFilter()
	else
		for Counter = 1, self.NumFilterLines do
			if (LineNum == Counter) then
				if (FilterList == "Available") then
					self.RulesFrame.Settings.AvailableFilters["ScrollLine" .. Counter].Highlight:Show()
					self.RulesFrame.Settings.ActiveFilters["ScrollLine" .. Counter].Highlight:Hide()
				else
					self.RulesFrame.Settings.AvailableFilters["ScrollLine" .. Counter].Highlight:Hide()
					self.RulesFrame.Settings.ActiveFilters["ScrollLine" .. Counter].Highlight:Show()
				end
			else
				self.RulesFrame.Settings.AvailableFilters["ScrollLine" .. Counter].Highlight:Hide()
				self.RulesFrame.Settings.ActiveFilters["ScrollLine" .. Counter].Highlight:Hide()
			end
		end
	end
	self:DisplayCurrentOptionFilter()
end

function PasslootBiS:RemoveFilter()
	if (self.CurrentRule > 0 and self.CurrentOptionFilter[1] == "Active" and self.CurrentOptionFilter[2] > 0) then
		local WidgetKey, Offset, KnownVar = self:GetWidgetFromLineNum(self.CurrentOptionFilter[2])
		if (KnownVar) then
			if (Offset) then
				self.RuleWidgets[WidgetKey]:RemoveFilter(Offset)
			else
				for Index = self.RuleWidgets[WidgetKey]:GetNumFilters(), 1, -1 do
					self.RuleWidgets[WidgetKey]:RemoveFilter(Index)
				end
			end
			for Key, Value in pairs(self.RuleWidgets) do
				Value:Hide()
			end
		else
			local UnknownVar = self.CurrentRuleUnknownVars[Offset]
			if (UnknownVar) then
				self:Debug("Removing " .. UnknownVar)
				self.db.profile.Rules[self.CurrentRule][UnknownVar] = nil
				self:BuildUnknownVars()
			end
		end
		self.CurrentOptionFilter = { nil, 0 } -- Frame, line #
		-- self:DisplayCurrentOptionFilter()
		self:Rules_AvailableFilters_OnScroll()
		self:Rules_ActiveFilters_OnScroll()
	end
end

function PasslootBiS:ChangeFilterException()
	if (self.CurrentRule > 0 and self.CurrentOptionFilter[1] == "Active" and self.CurrentOptionFilter[2] > 0) then
		local WidgetKey, Offset, KnownVar = self:GetWidgetFromLineNum(self.CurrentOptionFilter[2])
		if (KnownVar) then
			if (Offset) then
				self.RuleWidgets[WidgetKey]:SetException(self.CurrentRule, Offset,
					not self.RuleWidgets[WidgetKey]:IsException(self.CurrentRule, Offset))
			else
				for Index = 1, self.RuleWidgets[WidgetKey]:GetNumFilters() do
					self.RuleWidgets[WidgetKey]:SetException(self.CurrentRule, Index,
						not self.RuleWidgets[WidgetKey]:IsException(self.CurrentRule, Index))
				end
			end
			self:Rules_ActiveFilters_OnScroll()
		end
	end
end

-- How many rules sit in the "Before Advisor" section: the leading run of ticked
-- rules. PartitionRules (Core/PassLoot.lua) keeps every ticked rule at the front,
-- so the run IS the section -- and reading it as a run rather than a count means a
-- rule that somehow got ticked without a re-sort simply draws in the lower section
-- (with its box ticked, so it is obvious) instead of shifting every number by one.
function PasslootBiS:NumBeforeAdvisorRules()
	local Count = 0
	for _, Rule in ipairs(self.db.profile.Rules) do
		if (not Rule.BeforeAdvisor) then
			break
		end
		Count = Count + 1
	end
	return Count
end

-- Paint one section of the rule list. Both sections scroll independently over their
-- own slice of db.profile.Rules, so a line's rule number is First + its position in
-- the slice, and it is stashed on the line for the click handlers to read back.
-- Numbering is per section and deliberately different between them: "01)" in the
-- Before Advisor block, plain "1)" below it, so a number always says which block it
-- belongs to.
function PasslootBiS:Rules_RuleSection_OnScroll(Key)
	local Section = self.RulesFrame.List.Sections[Key]
	local Rules = self.db.profile.Rules
	local NumBefore = self:NumBeforeAdvisorRules()
	local First, Count
	if (Key == "Before") then
		First, Count = 1, NumBefore
	else
		First, Count = NumBefore + 1, #Rules - NumBefore
	end
	FauxScrollFrame_Update(Section.ScrollFrame, Count, self.NumRuleSectionLines, self.RuleListLineHeight)
	local Offset = FauxScrollFrame_GetOffset(Section.ScrollFrame)
	for Line = 1, self.NumRuleSectionLines do
		local LineFrame = Section["ScrollLine" .. Line]
		local Index = Line + Offset             -- position within this section
		local RuleNum = First + Index - 1
		if (Index <= Count and Rules[RuleNum]) then
			LineFrame.RuleNum = RuleNum
			if (Key == "Before") then
				LineFrame.Text:SetText(string.format("%02d) %s", Index, Rules[RuleNum].Desc))
			else
				LineFrame.Text:SetText(Index .. ") " .. Rules[RuleNum].Desc)
			end
			LineFrame.Pass:SetChecked(false)
			LineFrame.Greed:SetChecked(false)
			LineFrame.Need:SetChecked(false)
			LineFrame.Disenchant:SetChecked(false)
			-- Independent of Loot: not a roll method, a priority flag.
			LineFrame.BeforeAdvisor:SetChecked(Rules[RuleNum].BeforeAdvisor and true or false)
			for Key2, Value in ipairs(Rules[RuleNum].Loot) do
				if (Value == "pass") then
					LineFrame.Pass:SetChecked(true)
				elseif (Value == "greed") then
					LineFrame.Greed:SetChecked(true)
				elseif (Value == "need") then
					LineFrame.Need:SetChecked(true)
				elseif (Value == "de") then
					LineFrame.Disenchant:SetChecked(true)
				end
			end
			LineFrame:Show()
			if (RuleNum == self.CurrentRule) then
				LineFrame.Highlight:Show()
			else
				LineFrame.Highlight:Hide()
			end
		else
			LineFrame.RuleNum = nil
			LineFrame.Highlight:Hide()
			LineFrame:Hide()
		end
	end
end

function PasslootBiS:Rules_RuleList_OnScroll()
	if (not (self.RulesFrame and self.RulesFrame.List and self.RulesFrame.List.Sections)) then
		return
	end
	self:Rules_RuleSection_OnScroll("Before")
	self:Rules_RuleSection_OnScroll("After")
end

-- Scroll whichever section holds the selected rule until that rule is on screen.
-- Worth doing since a rule can now MOVE while selected: ticking Before Advisor
-- sends it to the end of the other section, which may already be scrolled past its
-- three visible lines, and Up/Down can walk it off the top or bottom. Without this
-- the rule the user just acted on simply vanishes. Call it after a repaint -- the
-- scrollbar's range is only right once Rules_RuleSection_OnScroll has set it.
function PasslootBiS:RevealCurrentRule()
	local List = self.RulesFrame and self.RulesFrame.List
	if (not (List and List.Sections) or not self.CurrentRule or self.CurrentRule < 1) then
		return
	end
	local NumBefore = self:NumBeforeAdvisorRules()
	local Section, Index
	if (self.CurrentRule <= NumBefore) then
		Section, Index = List.Sections.Before, self.CurrentRule
	else
		Section, Index = List.Sections.After, self.CurrentRule - NumBefore
	end
	local Lines = self.NumRuleSectionLines
	local Offset = FauxScrollFrame_GetOffset(Section.ScrollFrame)
	if (Index <= Offset) then
		Offset = Index - 1
	elseif (Index > Offset + Lines) then
		Offset = Index - Lines
	else
		return -- already visible
	end
	local Bar = _G[Section.ScrollFrame:GetName() .. "ScrollBar"]
	if (Bar) then
		Bar:SetValue(Offset * self.RuleListLineHeight) -- fires OnVerticalScroll, which repaints
	end
end

function PasslootBiS:Rules_AvailableFilters_OnScroll()
	local Frame = self.RulesFrame.Settings.AvailableFilters
	local Line, LineNum
	local NumOptions = #self.RuleWidgets
	FauxScrollFrame_Update(Frame.ScrollFrame, NumOptions, self.NumFilterLines, self.FilterLineHeight)
	for Line = 1, self.NumFilterLines do
		LineNum = Line + FauxScrollFrame_GetOffset(Frame.ScrollFrame)
		if (LineNum <= NumOptions) then
			Frame["ScrollLine" .. Line].Text:SetText(self.RuleWidgets[LineNum].Info[1] or "")
			Frame["ScrollLine" .. Line]:Show()
			if (self.CurrentOptionFilter[1] == "Available" and self.CurrentOptionFilter[2] == LineNum) then
				Frame["ScrollLine" .. Line].Highlight:Show()
			else
				Frame["ScrollLine" .. Line].Highlight:Hide()
			end
		else
			Frame["ScrollLine" .. Line].Highlight:Hide()
			Frame["ScrollLine" .. Line]:Hide()
		end
	end
end

function PasslootBiS:Rules_ActiveFilters_OnScroll()
	if (self.CurrentRule < 1) then
		return
	end
	local Frame = self.RulesFrame.Settings.ActiveFilters
	local Line, LineNum
	local NumLines = 0
	local WidgetKey, Offset, Text, NumFilters
	-- Count how many lines from active filters
	for WidgetKey, WidgetValue in ipairs(self.RuleWidgets) do
		NumFilters = (WidgetValue:GetNumFilters() or 0)
		if (NumFilters > 0) then
			NumLines = NumLines + NumFilters + 1
		end
	end
	if (self.db.profile.DisplayUnknownVars) then
		NumLines = NumLines + #self.CurrentRuleUnknownVars
	end
	self:Debug(string.format("NumLines %s, UnknownVars %s", NumLines, #self.CurrentRuleUnknownVars))
	FauxScrollFrame_Update(Frame.ScrollFrame, NumLines, self.NumFilterLines, self.FilterLineHeight)
	for Line = 1, self.NumFilterLines do
		LineNum = Line + FauxScrollFrame_GetOffset(Frame.ScrollFrame)
		if (LineNum <= NumLines) then
			WidgetKey, Offset, KnownVar = self:GetWidgetFromLineNum(LineNum)
			if (KnownVar) then
				if (Offset) then
					Text = self.RuleWidgets[WidgetKey]:GetFilterText(Offset) or "Value Error"
					if (self.RuleWidgets[WidgetKey]:IsException(self.CurrentRule, Offset)) then
						Text = self.FontRed .. L["EXCEPTION_PREFIX"] .. "|r" .. Text
					end
				else
					Text = PasslootBiS.FontGold .. (self.RuleWidgets[WidgetKey].Info[1] or "Name Error")
				end
			else
				if (self.db.profile.DisplayUnknownVars and self.CurrentRuleUnknownVars[Offset]) then
					Text = self.FontGray .. self.CurrentRuleUnknownVars[Offset]
				end
			end -- KnownVar
			Frame["ScrollLine" .. Line].Text:SetText(Text)
			Frame["ScrollLine" .. Line]:Show()
			if (self.CurrentOptionFilter[1] == "Active" and self.CurrentOptionFilter[2] == LineNum) then
				Frame["ScrollLine" .. Line].Highlight:Show()
			else
				Frame["ScrollLine" .. Line].Highlight:Hide()
			end
		else
			Frame["ScrollLine" .. Line].Highlight:Hide()
			Frame["ScrollLine" .. Line]:Hide()
		end
	end
end

-- For Active filters:  Returns WidgetIndex, Offset, true
-- For Unknown filter variables:  Returns nil, Offset, false
function PasslootBiS:GetWidgetFromLineNum(Offset)
	local VariableList, NumFilters
	for WidgetKey, WidgetValue in ipairs(self.RuleWidgets) do
		NumFilters = WidgetValue:GetNumFilters() or 0
		if (NumFilters > 0) then
			Offset = Offset - 1
			if (Offset == 0) then
				return WidgetKey, nil, true
			end
		end
		if (Offset <= NumFilters) then
			return WidgetKey, Offset, true
		else
			Offset = Offset - NumFilters
		end
	end
	-- Gone through every filter, so it must an unknown
	return nil, Offset, false
end

--[=[ ##########################
           START OF LUA UI
      ##########################
]=]

-- Tooltip used for scanning (we pass the frame to modules, and they can scan)
function PasslootBiS:Create_PasslootBiSTooltip()
	local Frame = CreateFrame("GameTooltip", "PasslootBiSTooltip", UIParent, "GameTooltipTemplate")
	Frame:Hide()
	Frame:SetOwner(UIParent, "ANCHOR_NONE")
	return Frame
end

-- Left column: the advisor status panel. Fixed now, because the rule list takes
-- its width from what is left over rather than the other way round (see below).
-- 110 is about what the panel already worked out to when it was the leftover half
-- of a centred 413-wide list, and it wraps its own text, so a few units either way
-- only change its height.
local STATUS_WIDTH = 110
local STATUS_LEFT = 4
local STATUS_GAP = 6

-- Rule list box, top to bottom: 4 gap, a section (title 12 + 3 + 3 lines of 16 =
-- 63), 4 gap, the 1px divider, 4 gap, the second section, 3 gap, the button row
-- (21), and a bottom margin. Six rule lines in total, same as the single list this
-- replaced, so the box only grows by the two headings and the divider.
local RULE_SECTION_TITLE = 12
local RULE_LIST_HEIGHT = 170

function PasslootBiS:Create_RulesFrame()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(413)
	Frame:SetHeight(428)

	-- Blizzard SetAllPoints' this frame onto InterfaceOptionsFramePanelContainer, so
	-- it is as wide as that container — comfortably wider than the 413 the list and
	-- settings boxes are. They used to be centred in it, which spent the slack on two
	-- empty side margins; now the status panel takes a fixed column on the left and
	-- BOTH boxes span from there to the right edge. That reclaimed width is what pays
	-- for the "Before Advisor" column on every rule line, and what is left over goes
	-- to the rule description. Both edges are anchored rather than a width guessed,
	-- so the panel still fits the container exactly at any UI scale.
	Frame.List = self:Create_RuleListFrame()
	Frame.List:SetParent(Frame)
	Frame.List:SetPoint("TOPLEFT", Frame, "TOPLEFT", STATUS_LEFT + STATUS_WIDTH + STATUS_GAP, 0)
	Frame.List:SetPoint("TOPRIGHT", Frame, "TOPRIGHT", -4, 0)

	-- The settings box takes the height that is left, rather than a fixed 298: the
	-- rule list above it is taller now that it is split into two sections, and the
	-- panel this all sits in is only so tall. Its contents anchor downward from its
	-- TOP (Core/ModulesGUI.lua included, deliberately), so what varies is the empty
	-- margin under the last widget.
	Frame.Settings = self:Create_RuleSettingsFrame()
	Frame.Settings:SetParent(Frame)
	Frame.Settings:SetPoint("TOPLEFT", Frame.List, "BOTTOMLEFT")
	Frame.Settings:SetPoint("TOPRIGHT", Frame.List, "BOTTOMRIGHT")
	Frame.Settings:SetPoint("BOTTOM", Frame, "BOTTOM", 0, 2)

	-- Advisor status (Core/AdvisorStatus.lua), in the column left of the rule list.
	-- It sizes its own height to its wrapped text, so the fixed width plus this one
	-- corner anchor is all it needs.
	Frame.Status = self:Create_AdvisorStatusFrame()
	Frame.Status:SetParent(Frame)
	Frame.Status:SetWidth(STATUS_WIDTH)
	Frame.Status:SetPoint("TOPLEFT", Frame, "TOPLEFT", STATUS_LEFT, -8)

	-- Blizzard Interface Options Panel stuff:
	Frame.name = L["PasslootBiS"]

	return Frame
end

-- One section of the rule list: a heading, and a scroll frame with its own lines
-- and its own scrollbar. The two sections are the roll order made visible -- the
-- Before Advisor block is tried first and rolls without asking the advisor, the
-- block below it is everything else -- so each is ordered on its own and Up/Down
-- never carries a rule across the divider. The "Before Advisor" checkbox does that.
function PasslootBiS:Create_RuleListSection(Key, Title, TitleTip)
	local Frame = CreateFrame("Frame")
	Frame.SectionKey = Key
	Frame:SetHeight(RULE_SECTION_TITLE + 3 + (PasslootBiS.NumRuleSectionLines * PasslootBiS.RuleListLineHeight))

	-- The heading needs a mouse-able frame of its own to carry the tooltip that
	-- explains what the section MEANS -- a FontString can't take one.
	Frame.Title = Frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	Frame.Title:SetPoint("TOPLEFT", Frame, "TOPLEFT", 12, 0)
	Frame.Title:SetJustifyH("LEFT")
	Frame.Title:SetText(PasslootBiS.FontGold .. Title)

	Frame.TitleHit = CreateFrame("Frame", nil, Frame)
	Frame.TitleHit:SetPoint("TOPLEFT", Frame.Title, "TOPLEFT")
	Frame.TitleHit:SetPoint("BOTTOMRIGHT", Frame.Title, "BOTTOMRIGHT")
	Frame.TitleHit:EnableMouse(true)
	Frame.TitleHit:SetScript("OnEnter", function() self:ShowTooltip(Title, TitleTip) end)
	Frame.TitleHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

	Frame.ScrollFrame = CreateFrame("ScrollFrame", "PasslootBiS_Rules" .. Key .. "_Scroll", Frame,
		"FauxScrollFrameTemplate")
	Frame.ScrollFrame:SetPoint("TOPLEFT", Frame, "TOPLEFT", 0, -(RULE_SECTION_TITLE + 3))
	-- Right edge rather than a fixed width, since the list frame is now as wide as
	-- the options panel allows. -32 is the room FauxScrollFrameTemplate's scrollbar
	-- wants OUTSIDE the scroll frame's right edge — the same gap the old fixed
	-- 381-in-413 pair left it.
	Frame.ScrollFrame:SetPoint("TOPRIGHT", Frame, "TOPRIGHT", -32, -(RULE_SECTION_TITLE + 3))
	Frame.ScrollFrame:SetHeight(PasslootBiS.NumRuleSectionLines * PasslootBiS.RuleListLineHeight)
	Frame.ScrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
		FauxScrollFrame_OnVerticalScroll(frame, offset, PasslootBiS.RuleListLineHeight,
			function() self:Rules_RuleSection_OnScroll(Key) end)
	end)

	for Index = 1, PasslootBiS.NumRuleSectionLines do
		local Line = self:Create_RuleListScrollLine()
		Line:SetParent(Frame)
		-- Both edges: a line's checkbox columns hang off its RIGHT edge
		-- (Create_RuleListScrollLine), so every line has to span the scroll frame.
		if (Index == 1) then
			Line:SetPoint("TOPLEFT", Frame.ScrollFrame, "TOPLEFT", 8, 0)
			Line:SetPoint("TOPRIGHT", Frame.ScrollFrame, "TOPRIGHT", 6, 0)
		else
			Line:SetPoint("TOPLEFT", Frame["ScrollLine" .. (Index - 1)], "BOTTOMLEFT")
			Line:SetPoint("TOPRIGHT", Frame["ScrollLine" .. (Index - 1)], "BOTTOMRIGHT")
		end
		Line.SectionKey = Key
		Frame["ScrollLine" .. Index] = Line
	end

	return Frame
end

function PasslootBiS:Create_RuleListFrame()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(413) -- placeholder: Create_RulesFrame anchors both edges instead
	Frame:SetHeight(RULE_LIST_HEIGHT)
	Frame:SetBackdrop({
		["bgFile"] = "Interface\\Tooltips\\UI-Tooltip-Background",
		["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["tile"] = true,
		["insets"] = {
			["top"] = 5,
			["bottom"] = 5,
			["left"] = 5,
			["right"] = 5,
		},
		["tileSize"] = 16,
		["edgeSize"] = 16,
	})
	Frame:SetBackdropBorderColor(0.4, 0.4, 0.4)
	Frame:SetBackdropColor(0.5, 0.5, 0.5)

	-- Two sections, stacked, with a line between them. The upper one is the roll
	-- order's first stop and the lower one everything after it, which is why the
	-- divider is drawn rather than left implied: the two blocks are read top to
	-- bottom as one order, but reordered separately.
	Frame.Sections = {}
	Frame.Sections.Before = self:Create_RuleListSection("Before", L["RuleSection_Before"],
		L["RuleSection_Before_Desc"])
	Frame.Sections.Before:SetParent(Frame)
	Frame.Sections.Before:SetPoint("TOPLEFT", Frame, "TOPLEFT", 0, -4)
	Frame.Sections.Before:SetPoint("TOPRIGHT", Frame, "TOPRIGHT", 0, -4)

	Frame.Divider = Frame:CreateTexture(nil, "ARTWORK")
	Frame.Divider:SetTexture(0.4, 0.4, 0.4, 1)   -- the backdrop's own border colour
	Frame.Divider:SetHeight(1)
	Frame.Divider:SetPoint("TOPLEFT", Frame.Sections.Before, "BOTTOMLEFT", 12, -4)
	Frame.Divider:SetPoint("TOPRIGHT", Frame.Sections.Before, "BOTTOMRIGHT", -12, -4)

	Frame.Sections.After = self:Create_RuleListSection("After", L["RuleSection_After"],
		L["RuleSection_After_Desc"])
	Frame.Sections.After:SetParent(Frame)
	Frame.Sections.After:SetPoint("TOPLEFT", Frame.Divider, "BOTTOMLEFT", -12, -4)
	Frame.Sections.After:SetPoint("TOPRIGHT", Frame.Divider, "BOTTOMRIGHT", 12, -4)

	Frame.Add = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Add:SetPoint("TOPLEFT", Frame.Sections.After.ScrollFrame, "BOTTOMLEFT", 12, -3)
	Frame.Add:SetWidth(90) -- My other mods: 80
	Frame.Add:SetHeight(21) -- My other mods: 22
	Frame.Add:SetScript("OnEnter", function() self:ShowTooltip(L["Add"], L["Add a new rule."]) end)
	Frame.Add:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame.Add:SetScript("OnClick", function(frame, button)
		local TempDB = {}
		for Key, Value in ipairs(self.DefaultTemplate) do
			TempDB[Value[1]] = self:CopyTable(Value[2])
		end
		table.insert(self.db.profile.Rules, TempDB)
		self:Rules_RuleList_OnScroll()
	end)
	Frame.Add:SetText(L["Add"])

	Frame.Remove = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Remove:SetPoint("TOPLEFT", Frame.Add, "TOPRIGHT", 10, 0)
	Frame.Remove:SetWidth(90) -- My other mods: 80
	Frame.Remove:SetHeight(21) -- My other mods: 22
	Frame.Remove:SetScript("OnEnter", function() self:ShowTooltip(L["Remove"], L["Remove selected rule."]) end)
	Frame.Remove:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame.Remove:SetScript("OnClick", function(frame, button)
		if (self.CurrentRule > 0) then
			table.remove(self.db.profile.Rules, self.CurrentRule)
			self.CurrentRule = 0
			self:Rules_RuleList_OnScroll()
			self:DisplayCurrentRule()
		end
	end)
	Frame.Remove:SetText(L["Remove"])

	Frame.Up = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Up:SetPoint("TOPLEFT", Frame.Remove, "TOPRIGHT", 10, 0)
	Frame.Up:SetWidth(90) -- My other mods: 80
	Frame.Up:SetHeight(21) -- My other mods: 22
	Frame.Up:SetScript("OnEnter", function() self:ShowTooltip(L["Up"], L["Move selected rule up in priority."]) end)
	Frame.Up:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame.Up:SetScript("OnClick", function(frame, button)
		self:MoveCurrentRule(-1)
	end)
	Frame.Up:SetText(L["Up"])

	Frame.Down = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Down:SetPoint("TOPLEFT", Frame.Up, "TOPRIGHT", 10, 0)
	Frame.Down:SetWidth(90) -- My other mods: 80
	Frame.Down:SetHeight(21) -- My other mods: 22
	Frame.Down:SetScript("OnEnter", function() self:ShowTooltip(L["Down"], L["Move selected rule down in priority."]) end)
	Frame.Down:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame.Down:SetScript("OnClick", function(frame, button)
		self:MoveCurrentRule(1)
	end)
	Frame.Down:SetText(L["Down"])

	-- The four buttons split the row evenly instead of being a fixed 90 each: 90x4
	-- plus the three 10px gaps exactly filled the old 413-wide box, and the box is
	-- now as wide as the options panel allows. They stay chained left-to-right, so
	-- setting one width lays out the whole row. OnSizeChanged catches Blizzard
	-- sizing the options panel; the direct call covers the pre-display width.
	local function LayoutButtons(ListFrame)
		local Width = ListFrame:GetWidth() or 413
		local ButtonWidth = math.floor((Width - 12 - 11 - 30) / 4) -- left inset, right inset, 3 gaps
		if (ButtonWidth < 60) then
			ButtonWidth = 60
		end
		ListFrame.Add:SetWidth(ButtonWidth)
		ListFrame.Remove:SetWidth(ButtonWidth)
		ListFrame.Up:SetWidth(ButtonWidth)
		ListFrame.Down:SetWidth(ButtonWidth)
	end
	Frame:SetScript("OnSizeChanged", function(ListFrame) LayoutButtons(ListFrame) end)
	LayoutButtons(Frame)

	return Frame
end

-- Move the selected rule one place up (-1) or down (1) WITHIN ITS OWN SECTION.
-- The swap is refused at a section's edge -- the neighbour on the other side of the
-- divider carries the opposite Before Advisor flag, and crossing the divider is the
-- checkbox's job, not this button's. Same swap either way, so both buttons share it.
function PasslootBiS:MoveCurrentRule(Step)
	local Rules = self.db.profile.Rules
	local From = self.CurrentRule or 0
	local To = From + Step
	if (From < 1 or not Rules[From] or not Rules[To]) then
		return
	end
	if ((Rules[From].BeforeAdvisor and true or false) ~= (Rules[To].BeforeAdvisor and true or false)) then
		return
	end
	Rules[From], Rules[To] = Rules[To], Rules[From]
	self.CurrentRule = To
	self:Rules_RuleList_OnScroll()
	self:RevealCurrentRule()
	self:DisplayCurrentRule()
end

function PasslootBiS:CopyCurrentRuleToProfile(profile)
	local self =
		PasslootBiS -- as I will be using this from PasslootBiS.CopyCurrentRuleToProfile and the first arg will be the frame
	if (self.CurrentRule > 0) then
		if (not self.db.profiles[profile] or not self.db.profiles[profile].Rules) then
			self:Print(L["Unable to copy rule"])
			return
		end
		local Rule = self:CopyTable(self.db.profile.Rules[self.CurrentRule])
		table.insert(self.db.profiles[profile].Rules, Rule)
		-- The copy carries the original's Before Advisor tick, and an append puts it
		-- at the bottom -- the wrong side of that profile's divider if it is ticked.
		self:PartitionRules(self.db.profiles[profile].Rules)
	end
end

PasslootBiS.EasyMenu_RuleListMenu = {
	[1] = {
		["text"] = L["Create Copy"],
		-- ["tooltipTitle"] = "Create Copy",
		-- ["tooltipText"] = "Create a duplicate at the bottom of the rules",
		["func"] = function(frame, arg)
			PasslootBiS:CopyCurrentRuleToProfile(PasslootBiS.db:GetCurrentProfile())
			PasslootBiS:Rules_RuleList_OnScroll()
		end,
		["notCheckable"] = true,
	},
	[2] = {
		["text"] = L["Export To"],
		["notCheckable"] = true,
		["hasArrow"] = true,
		["menuList"] = {},
	},
}

function PasslootBiS:Create_RuleListScrollLine()
	local Frame = CreateFrame("Button")
	Frame:SetWidth(379) -- placeholder: Create_RuleListFrame anchors both edges instead
	Frame:SetHeight(16)
	Frame:SetScript("OnEnter",
		function(frame) self:ShowTooltip(L["Rule List"], L["Click to select and edit this rule."]) end)
	Frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame:SetScript("OnClick", function(frame, button)
		self:SetCurrentRule(Frame)
		if (button == "RightButton" and Frame.RuleNum) then
			self.EasyMenu_RuleListMenu[1].arg1 = Frame.RuleNum
			-- self.EasyMenu_RuleListMenu[2].arg1 = Name
			-- self.EasyMenu_RuleListMenu[3].arg1 = Name
			-- self.EasyMenu_RuleListMenu[5].arg1 = "Raider"..Name
			local CurrentProfile = self.db:GetCurrentProfile()
			local ProfileList = self.db:GetProfiles()
			self.EasyMenu_RuleListMenu[2].menuList = {}
			for k, v in pairs(ProfileList) do
				if (v ~= CurrentProfile) then
					table.insert(self.EasyMenu_RuleListMenu[2].menuList, {
						["text"] = v,
						["func"] = self.CopyCurrentRuleToProfile,
						["disabled"] = false,
						["notCheckable"] = true,
						["arg1"] = v
					})
				end
			end
			EasyMenu(self.EasyMenu_RuleListMenu, self.DropDownFrame, "cursor", nil, nil, "MENU")
		end
	end)
	Frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	Frame.Highlight = Frame:CreateTexture(nil, "BACKGROUND")
	Frame.Highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	Frame.Highlight:SetAllPoints(Frame)
	Frame.Highlight:SetBlendMode("ADD")
	Frame.Highlight:Hide()

	Frame.Text = Frame:CreateFontString(nil, "BACKGROUND", "ChatFontSmall")
	Frame.Text:SetHeight(16)
	Frame.Text:SetJustifyH("LEFT")

	Frame.Need = self:Create_CheckBox()
	Frame.Need:SetParent(Frame)
	Frame.Need:SetScript("OnClick", function(frame, button) self:SetLootMethod(Frame, "need") end)
	Frame.Need:SetScript("OnEnter",
		function()
			self:ShowTooltip(L["Need"], L["Will roll need on all loot matching this rule."],
				L["Rolling is tried from left to right"])
		end)
	Frame.Need.Text:SetText(L["Need"])

	Frame.Disenchant = self:Create_CheckBox()
	Frame.Disenchant:SetParent(Frame)
	-- Frame.Disenchant:SetScript("OnClick", function(frame, button) self:SetDisenchant(Frame) end)
	Frame.Disenchant:SetScript("OnClick", function(frame, button) self:SetLootMethod(Frame, "de") end)
	Frame.Disenchant:SetScript("OnEnter",
		function() self:ShowTooltip(L["Disenchant"], L["Disenchant_Desc"], L["Rolling is tried from left to right"]) end)
	Frame.Disenchant.Text:SetText(L["Disenchant"])

	Frame.Greed = self:Create_CheckBox()
	Frame.Greed:SetParent(Frame)
	Frame.Greed:SetScript("OnClick", function(frame, button) self:SetLootMethod(Frame, "greed") end)
	Frame.Greed:SetScript("OnEnter",
		function()
			self:ShowTooltip(L["Greed"], L["Will roll greed on all loot matching this rule."],
				L["Rolling is tried from left to right"])
		end)
	Frame.Greed.Text:SetText(L["Greed"])

	Frame.Pass = self:Create_CheckBox()
	Frame.Pass:SetParent(Frame)
	Frame.Pass:SetScript("OnClick", function(frame, button) self:SetLootMethod(Frame, "pass") end)
	Frame.Pass:SetScript("OnEnter",
		function()
			self:ShowTooltip(L["Pass"], L["Will pass on all loot matching this rule."],
				L["Rolling is tried from left to right"])
		end)
	Frame.Pass.Text:SetText(L["Pass"])

	-- "Before Advisor" — NOT a roll method, so it gets its own setter rather than
	-- joining the four above in Loot. Ticked, a match on this rule is rolled straight
	-- away and the roll advisor is never consulted (Core/PassLoot.lua ProcessLootRoll):
	-- no held-confirm popup, no trust-mode auto-cast overriding it. Unticked — the
	-- default for a hand-made rule — the advisor keeps its say. The rules a BiS list
	-- import writes tick it (Modules/BiSImport.lua): your BiS picks are the whole
	-- point of the list, so nothing should get to talk you out of them.
	Frame.BeforeAdvisor = self:Create_CheckBox()
	Frame.BeforeAdvisor:SetParent(Frame)
	Frame.BeforeAdvisor:SetScript("OnClick", function(frame, button) self:SetBeforeAdvisor(Frame) end)
	Frame.BeforeAdvisor:SetScript("OnEnter",
		function() self:ShowTooltip(L["Before Advisor"], L["BeforeAdvisor_Desc"]) end)
	Frame.BeforeAdvisor.Text:SetText(L["Before Advisor"])

	-- Column layout, in one block here because it runs RIGHT to LEFT: the five
	-- checkboxes hang off the line's right edge as a fixed-width cluster and the
	-- description takes everything left of them, so the wider the options panel lets
	-- the rule list be, the more of a long rule name you can read. Sizing (every
	-- label is drawn to the RIGHT of its box, GameFontNormalSmall):
	--   * 36 between columns, down from 40 to buy back some of what the fifth column
	--     costs. Still ~11 clear of the widest label it has to span ("Greed").
	--   * 84 held back at the far right for "Before Advisor", much the longest of the
	--     five labels and the only one with nothing to its right to bound it.
	-- Cluster total 308, which leaves the description ~155 — what it used to be given
	-- outright — on the narrowest panel this client shows, and more on a roomier one.
	Frame.BeforeAdvisor:SetPoint("TOPRIGHT", Frame, "TOPRIGHT", -84, 0)
	Frame.Pass:SetPoint("TOPRIGHT", Frame.BeforeAdvisor, "TOPLEFT", -36, 0)
	Frame.Greed:SetPoint("TOPRIGHT", Frame.Pass, "TOPLEFT", -36, 0)
	Frame.Disenchant:SetPoint("TOPRIGHT", Frame.Greed, "TOPLEFT", -36, 0)
	Frame.Need:SetPoint("TOPRIGHT", Frame.Disenchant, "TOPLEFT", -36, 0)
	Frame.Text:SetPoint("TOPLEFT", Frame, "TOPLEFT", 0, 0)
	Frame.Text:SetPoint("TOPRIGHT", Frame.Need, "TOPLEFT", -4, 0)

	return Frame
end

function PasslootBiS:Create_CheckBox()
	local Frame = CreateFrame("CheckButton")
	Frame:SetHeight(16)
	Frame:SetWidth(16)
	Frame:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
	Frame:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
	Frame:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
	Frame:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	Frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame:SetHitRectInsets(0, -30, 0, 0)
	Frame.Text = Frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	Frame.Text:SetPoint("LEFT", Frame, "RIGHT", -2, 0)
	return Frame
end

function PasslootBiS:Create_RuleSettingsFrame()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(413)  -- placeholder: Create_RulesFrame anchors both edges instead
	Frame:SetHeight(298) -- placeholder: and its bottom, so this height is transient
	Frame:SetBackdrop({
		["bgFile"] = "Interface\\Tooltips\\UI-Tooltip-Background",
		["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["tile"] = true,
		["insets"] = {
			["top"] = 5,
			["bottom"] = 5,
			["left"] = 5,
			["right"] = 5,
		},
		["tileSize"] = 16,
		["edgeSize"] = 16,
	})
	Frame:SetBackdropBorderColor(0.4, 0.4, 0.4)
	Frame:SetBackdropColor(0.5, 0.5, 0.5)

	Frame.Desc = self:Create_EditBox()
	Frame.Desc:SetParent(Frame)
	Frame.Desc:SetPoint("TOP", Frame, "TOP", 0, -15)
	Frame.Desc:SetWidth(160)
	Frame.Desc:SetHeight(26)
	Frame.Desc.Title:SetText(L["Description"])
	Frame.Desc:SetScript("OnEnter", function(frame) self:ShowTooltip(L["Description"], L["Description_Desc"]) end)
	Frame.Desc:SetScript("OnEnterPressed", function(frame)
		if (self.CurrentRule > 0) then
			self.db.profile.Rules[self.CurrentRule].Desc = frame:GetText()
		end
		frame:ClearFocus()
		self:Rules_RuleList_OnScroll()
	end)

	-- The two filter boxes are a fixed-width pair (190 + 213, butted together), so
	-- centre them as one unit: this box is no longer a fixed 413 they happened to
	-- fill, it spans the options panel (Create_RulesFrame). Everything else in here
	-- is centred on the box already — the description edit box above, and the module
	-- rule widgets below (Core/ModulesGUI.lua) — and the Add/Remove/Exception buttons
	-- hang off these two, so they follow.
	Frame.AvailableFilters = self:Create_RuleAvailableFiltersFrame()
	Frame.AvailableFilters:SetParent(Frame)
	Frame.AvailableFilters:SetPoint("TOPLEFT", Frame, "TOP", -202, -51)

	Frame.ActiveFilters = self:Create_RuleActiveFiltersFrame()
	Frame.ActiveFilters:SetParent(Frame)
	Frame.ActiveFilters:SetPoint("TOPLEFT", Frame.AvailableFilters, "TOPRIGHT", 0, 0)

	Frame.Add = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Add:SetPoint("TOPLEFT", Frame.AvailableFilters, "BOTTOMLEFT", 0, -5)
	Frame.Add:SetWidth(80)
	Frame.Add:SetHeight(21)
	Frame.Add:SetScript("OnEnter", function() self:ShowTooltip(L["Add"], L["Add this filter."]) end)
	Frame.Add:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame.Add:SetScript("OnClick", function(frame, button)
		if (self.CurrentRule > 0 and self.CurrentOptionFilter[1] == "Available" and self.CurrentOptionFilter[2] > 0) then
			self.RuleWidgets[self.CurrentOptionFilter[2]]:AddNewFilter()
			self:Rules_ActiveFilters_OnScroll()
		end
	end)
	Frame.Add:SetText(L["Add"])
	Frame.Add:Hide()

	Frame.Remove = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Remove:SetPoint("TOPRIGHT", Frame.ActiveFilters, "BOTTOMRIGHT", 0, -5)
	Frame.Remove:SetWidth(80)
	Frame.Remove:SetHeight(21)
	Frame.Remove:SetScript("OnEnter", function() self:ShowTooltip(L["Remove"], L["Remove this filter."]) end)
	Frame.Remove:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame.Remove:SetScript("OnClick", function(frame, button)
		self:RemoveFilter()
	end)
	Frame.Remove:SetText(L["Remove"])
	Frame.Remove:Hide()

	Frame.Exception = CreateFrame("Button", nil, Frame, "UIPanelButtonTemplate")
	Frame.Exception:SetPoint("TOPRIGHT", Frame.Remove, "TOPLEFT", -5, 0)
	Frame.Exception:SetWidth(90)
	Frame.Exception:SetHeight(21)
	Frame.Exception:SetScript("OnEnter",
		function() self:ShowTooltip(L["Exception"], L["Change the exception status of this filter."]) end)
	Frame.Exception:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame.Exception:SetScript("OnClick", function(frame, button)
		self:ChangeFilterException()
	end)
	Frame.Exception:SetText(L["Exception"])
	Frame.Exception:Hide()

	return Frame
end

function PasslootBiS:Create_EditBox()
	local Frame = CreateFrame("EditBox")
	Frame:SetBackdrop({
		["bgFile"] = "Interface\\Tooltips\\UI-Tooltip-Background",
		["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["tile"] = true,
		["insets"] = {
			["top"] = 5,
			["bottom"] = 5,
			["left"] = 5,
			["right"] = 5,
		},
		["tileSize"] = 32,
		["edgeSize"] = 16,
	})
	Frame:SetBackdropColor(0, 0, 0, 0.95)
	Frame:EnableMouse(true)
	Frame:SetMaxLetters(200)
	-- Frame:SetHistoryLines(0)
	Frame:SetAutoFocus(false)
	Frame:SetFontObject("ChatFontNormal")
	Frame:SetTextInsets(6, 6, 6, 6)
	Frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame:SetScript("OnEscapePressed", function() Frame:ClearFocus() end)
	Frame:SetScript("OnEditFocusGained", function() Frame:HighlightText() end)
	Frame:SetScript("OnEditFocusLost", function()
		Frame:HighlightText(0, 0)
		self:DisplayCurrentRule()
	end)

	Frame.Title = Frame:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
	Frame.Title:SetPoint("BOTTOMLEFT", Frame, "TOPLEFT", 3, 0)

	return Frame
end

function PasslootBiS:Create_RuleAvailableFiltersFrame()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(190)
	Frame:SetHeight(137)
	Frame:SetBackdrop({
		["bgFile"] = "Interface\\DialogFrame\\UI-DialogBox-Background",
		["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["tile"] = true,
		["insets"] = {
			["top"] = 2,
			["bottom"] = 2,
			["left"] = 2,
			["right"] = 2,
		},
		["tileSize"] = 16,
		["edgeSize"] = 16,
	})

	Frame.Title = Frame:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
	Frame.Title:SetPoint("BOTTOMLEFT", Frame, "TOPLEFT", 3, 0)
	Frame.Title:SetText(L["Available Filters"])

	Frame.ScrollFrame = CreateFrame("ScrollFrame", "PasslootBiS_AvailableFilters_Scroll", Frame, "FauxScrollFrameTemplate")
	Frame.ScrollFrame:SetPoint("TOPLEFT", Frame, "TOPLEFT", 0, -5)
	Frame.ScrollFrame:SetWidth(162)
	Frame.ScrollFrame:SetHeight(128)
	Frame.ScrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
		FauxScrollFrame_OnVerticalScroll(frame, offset, 16, function() self:Rules_AvailableFilters_OnScroll() end)
	end)

	Frame.ScrollLine1 = self:Create_AvailableFiltersScrollLine()
	Frame.ScrollLine1:SetParent(Frame)
	Frame.ScrollLine1:SetPoint("TOPLEFT", Frame.ScrollFrame, "TOPLEFT", 8, 0)
	Frame.ScrollLine1.LineNum = 1
	for Index = 2, 8 do
		Frame["ScrollLine" .. Index] = self:Create_AvailableFiltersScrollLine()
		Frame["ScrollLine" .. Index]:SetParent(Frame)
		Frame["ScrollLine" .. Index]:SetPoint("TOPLEFT", Frame["ScrollLine" .. (Index - 1)], "BOTTOMLEFT")
		Frame["ScrollLine" .. Index].LineNum = Index
	end

	return Frame
end

function PasslootBiS:Create_AvailableFiltersScrollLine()
	local Frame = CreateFrame("Button")
	Frame:SetWidth(162)
	Frame:SetHeight(16)
	Frame:SetScript("OnEnter", function(frame) self:ShowTooltip(L["Available Filters"], L["Available Filters_Desc"]) end)
	Frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame:SetScript("OnClick",
		function(frame, button) self:SetCurrentOptionFilter("Available", Frame.LineNum, button) end)

	Frame.Highlight = Frame:CreateTexture(nil, "BACKGROUND")
	Frame.Highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	Frame.Highlight:SetAllPoints(Frame)
	Frame.Highlight:SetBlendMode("ADD")
	Frame.Highlight:Hide()

	Frame.Text = Frame:CreateFontString(nil, "BACKGROUND", "ChatFontNormal")
	Frame.Text:SetWidth(162)
	Frame.Text:SetHeight(16)
	Frame.Text:SetPoint("TOPLEFT", Frame, "TOPLEFT", 0, 0)
	Frame.Text:SetJustifyH("LEFT")
	return Frame
end

function PasslootBiS:Create_RuleActiveFiltersFrame()
	local Frame = CreateFrame("Frame")
	Frame:SetWidth(213)
	Frame:SetHeight(137)
	Frame:SetBackdrop({
		["bgFile"] = "Interface\\DialogFrame\\UI-DialogBox-Background",
		["edgeFile"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["tile"] = true,
		["insets"] = {
			["top"] = 2,
			["bottom"] = 2,
			["left"] = 2,
			["right"] = 2,
		},
		["tileSize"] = 16,
		["edgeSize"] = 16,
	})

	Frame.Title = Frame:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
	Frame.Title:SetPoint("BOTTOMLEFT", Frame, "TOPLEFT", 3, 0)
	Frame.Title:SetText(L["Active Filters"])

	Frame.ScrollFrame = CreateFrame("ScrollFrame", "PasslootBiS_ActiveFilters_Scroll", Frame, "FauxScrollFrameTemplate")
	Frame.ScrollFrame:SetPoint("TOPLEFT", Frame, "TOPLEFT", 0, -5)
	Frame.ScrollFrame:SetWidth(185)
	Frame.ScrollFrame:SetHeight(128)
	Frame.ScrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
		FauxScrollFrame_OnVerticalScroll(frame, offset, 16, function() self:Rules_ActiveFilters_OnScroll() end)
	end)

	Frame.ScrollLine1 = self:Create_ActiveFiltersScrollLine()
	Frame.ScrollLine1:SetParent(Frame)
	Frame.ScrollLine1:SetPoint("TOPLEFT", Frame.ScrollFrame, "TOPLEFT", 8, 0)
	Frame.ScrollLine1.LineNum = 1
	for Index = 2, 8 do
		Frame["ScrollLine" .. Index] = self:Create_ActiveFiltersScrollLine()
		Frame["ScrollLine" .. Index]:SetParent(Frame)
		Frame["ScrollLine" .. Index]:SetPoint("TOPLEFT", Frame["ScrollLine" .. (Index - 1)], "BOTTOMLEFT")
		Frame["ScrollLine" .. Index].LineNum = Index
	end

	return Frame
end

function PasslootBiS:Create_ActiveFiltersScrollLine()
	local Frame = CreateFrame("Button")
	Frame:SetWidth(185)
	Frame:SetHeight(16)
	Frame:SetScript("OnEnter", function(frame) self:ShowTooltip(L["Active Filters"], L["Active Filters_Desc"]) end)
	Frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Frame:SetScript("OnClick", function(frame, button) self:SetCurrentOptionFilter("Active", Frame.LineNum, button) end)
	Frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	Frame.Highlight = Frame:CreateTexture(nil, "BACKGROUND")
	Frame.Highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	Frame.Highlight:SetAllPoints(Frame)
	Frame.Highlight:SetBlendMode("ADD")
	Frame.Highlight:Hide()

	Frame.Text = Frame:CreateFontString(nil, "BACKGROUND", "ChatFontNormal")
	Frame.Text:SetWidth(185)
	Frame.Text:SetHeight(16)
	Frame.Text:SetPoint("TOPLEFT", Frame, "TOPLEFT", 0, 0)
	Frame.Text:SetJustifyH("LEFT")
	return Frame
end
