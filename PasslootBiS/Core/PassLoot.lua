local VERSION = "1.0"
PasslootBiS = LibStub("AceAddon-3.0"):NewAddon("PasslootBiS", "AceConsole-3.0", "AceEvent-3.0", "AceBucket-3.0", "LibSink-2.0",
	"AceTimer-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")
local LDB = LibStub:GetLibrary("LibDataBroker-1.1")

local rollQueue = {}

-- Rolls THIS ADDON cast, as RollID -> the item link that was up when we cast.
-- Read by the CONFIRM_LOOT_ROLL handler so the bind warning is auto-answered only
-- for rolls the addon made on your behalf. A Need you clicked yourself keeps its
-- "this will bind to you" prompt -- that is the stock client's safety net on a
-- deliberate action, and silently removing it is not what auto-rolling was asked
-- to do.
--
-- The value is the LINK, not `true`, because rollIDs are recycled within a session.
-- A mark left behind by a cast that never drew a confirm (any non-BoP roll) would
-- otherwise make the next roll to reuse that id look like ours. Comparing the link
-- at confirm time settles it without a timer to get wrong.
PasslootBiS.CastRolls = {}

function PasslootBiS:delay_rollOnLoot()
	local nextRoll = table.remove(rollQueue, 1)
	-- Skip a roll that is no longer live. Entries sit here for up to 0.5s per queued
	-- roll ahead of them, and in that window the user can roll by hand, the roll can
	-- be cancelled, or the window can expire -- GetLootRollItemLink goes nil for all
	-- three. RollOnLoot on a dead id throws, which would surface as a red error and
	-- abandon this drain pass. (The same guard the first-see retry already uses.)
	if nextRoll then
		local link = (nextRoll.RollID > -1) and GetLootRollItemLink(nextRoll.RollID) or nil
		if nextRoll.RollID <= -1 or link then
			PasslootBiS.CastRolls[nextRoll.RollID] = link
			RollOnLoot(nextRoll.RollID, nextRoll.RollMethod)
		end
	end
	if rawequal(next(rollQueue), nil) then
		PasslootBiS:CancelTimer(PasslootBiS.delay_rollOnLoot_active)
		PasslootBiS.delay_rollOnLoot_active = nil
	end
end

-- Queue a single roll for the delayed RollOnLoot drain. This is the ONE roll path
-- (PassLoot stays the sole roller, integration-api.md §3.6): START_LOOT_ROLL uses
-- it, and so does the roll advisor's held-confirm gate (Core/RollAdvisor.lua) when
-- the user clicks a choice or the hold expires. RollMethod 0 (Pass) is a valid
-- cast; nil means "don't roll" (no rule matched) and is a no-op.
function PasslootBiS:QueueRoll(RollID, RollMethod)
	if RollMethod == nil or not RollID or RollID <= -1 then return end
	table.insert(rollQueue, { ["RollID"] = RollID, ["RollMethod"] = RollMethod })
	if not self.delay_rollOnLoot_active then
		self.delay_rollOnLoot_active = self:ScheduleRepeatingTimer("delay_rollOnLoot", 0.5)
	end
end

local defaults = {
	["profile"] = {
		["Quiet"] = false,
		["AllowMultipleConfirmPopups"] = false,
		-- Auto-answer the client's "this item will bind to you" warning when you take
		-- a BoP item out of a loot window (Core/PassLoot.lua, LOOT_BIND_CONFIRM).
		-- OFF by default: confirming binds the item for good, so it is the user's call.
		["AutoConfirmBindOnPickup"] = false,
		-- Auto-answer the "this item will bind to you" warning raised by a ROLL the
		-- addon itself cast (CONFIRM_LOOT_ROLL). ON by default, unlike the pickup one
		-- above: your rules already decided to roll, and the client is only asking you
		-- to reconfirm that decision. With it off, auto-rolling silently does not work
		-- on BoP loot -- which is most of what a boss drops.
		-- Need/Greed only; disenchant keeps its own opt-in filter (Modules/ConfirmDE).
		["AutoConfirmBindOnRoll"] = true,
		["Rules"] = {},
		-- Flipped by SeedDefaultRules() the first time a profile is loaded, so the
		-- starter rules (Constants.lua DefaultRules) are handed out exactly once. A
		-- user who then deletes them does NOT get them back on the next login.
		["DefaultRulesSeeded"] = false,
		["Modules"] = {},
		-- Per-item manager metadata captured from imported PLBIS1 strings' additive
		-- `mgr` block (protocol §3.5), keyed by BiS list name (the rule Desc without
		-- its " (IDs)"/" (Suffix)" suffix): BiSManage[listName] = { {kind,key,name,
		-- source,category[,slot][,score]}, ... }. Powers the BiS Manager window's
		-- grouped/sortable view and ties each item back to its rule entry on removal.
		-- Empty until an import carries an mgr block.
		["BiSManage"] = {},
		-- BiS Manager window state (the custom floating frame in PassLoot.lua): the
		-- chosen sort mode ("source"/"slot"/"score") and its saved screen position.
		["BiSManagerWindow"] = {
			["sort"] = "source",
			["shown"] = false,
		},
		-- Minimap button state (Core/MinimapButton.lua): pos = angle in degrees
		-- around the minimap ring; hide = whether the button is suppressed.
		["Minimap"] = {
			["hide"] = false,
			["pos"] = 220,
		},
		-- Loot Window state (Core/LootWindow.lua): shown + saved position, plus the
		-- persisted per-item roll log (array of groups; see Modules/LootTracker.lua).
		["LootWindow"] = {
			["shown"] = false,
			["log"] = {},
		},
		["SinkOptions"] = {},
		["SkipRules"] = false,
		["SkipWarning"] = true,
		["DisplayUnknownVars"] = true,
		["CacheExpires"] = 900,
		["MessageText"] = {
			["need"] = L["Rolling need on %item% (%rule%)"],
			["greed"] = L["Rolling greed on %item% (%rule%)"],
			["de"] = L["Rolling disenchant on %item% (%rule%)"],
			["pass"] = L["Rolling pass on %item% (%rule%)"],
			["ignore"] = L["Ignoring %item% (%rule%)"],
		},
	},
}

local function handleMouseover(cmdname)
	local name, link = GameTooltip:GetItem()
	if GameTooltip:IsShown() and link then
		if cmdname == "IDRule" then
			local item = PasslootBiS:InitItem(link)
			return tostring(item.id)
		else
			return name:lower()
		end
	end
	PasslootBiS:Pour("No valid item tooltip found.")
end

local function dupcheck(a, b)
	if #a == 2 then
		for i = 1, #a do
			if (a[i][2] == "Exact") and a[i][1]:lower() == b then return true end
		end
	else
		for i = 1, #a do
			if a[i][1] == b then return true end
		end
	end
	return false
end

local function slash_feedback(flag, idx, command)
	PasslootBiS:Pour("Completed: " ..
		flag .. " '" .. command .. "' to rule #" .. idx .. " '" .. PasslootBiS.db.profile.Rules[idx].Desc .. "'")
end

local function compare_name(a, b)
	local atest = a[1]:lower()
	local btext = b[1]:lower()
	return (atest < btext) or (atest == btext and a[2] < b[2])
end

local function compare_id(a, b)
	return a[1]:lower() < b[1]:lower()
end

local function handleAddRemove(value, cmdname, dbkey, example)
	local idx, flag, command = value:match("(%d-) (%S*) (.*)")
	if command and idx and flag then
		flag = flag:lower()
		idx = tonumber(idx)
	end
	if not command or not idx or (flag ~= "add" and flag ~= "remove") or not PasslootBiS.db.profile.Rules[idx] then
		PasslootBiS:Pour(
			"This command requires a valid Rule Number, the operation 'add' or 'remove', and either the value to add or 'mouseover' to use the current tooltip.")
		PasslootBiS:Pour("Example: /PasslootBiS " .. cmdname .. " 1 add " .. example)
		PasslootBiS:Pour("Example: /PasslootBiS " .. cmdname .. " 1 remove mouseover")
		return
	end
	if command == "mouseover" then
		command = handleMouseover(cmdname)
	end
	if command then
		if flag == "add" then
			PasslootBiS.db.profile.Rules[idx][dbkey] = PasslootBiS.db.profile.Rules[idx][dbkey] or {}
			-- check if already in rule
			if not dupcheck(PasslootBiS.db.profile.Rules[idx][dbkey], command) then
				if cmdname == "IDRule" then
					table.insert(PasslootBiS.db.profile.Rules[idx][dbkey], { command, false })
					if PasslootBiS.db.profile.Rules[idx][dbkey]["ItemIDs"] then
						table.sort(PasslootBiS.db.profile.Rules[idx][dbkey]["ItemIDs"], compare_id)
					end
				else
					table.insert(PasslootBiS.db.profile.Rules[idx][dbkey], { command, "Exact", false })
					if PasslootBiS.db.profile.Rules[idx][dbkey]["Items"] then
						table.sort(PasslootBiS.db.profile.Rules[idx][dbkey]["Items"], compare_name)
					end
				end
				slash_feedback(flag, idx, command)
			else
				PasslootBiS:Pour("Item already present in Rule, skipping.")
			end
		elseif PasslootBiS.db.profile.Rules[idx][dbkey] then
			local found = false
			for i, v in pairs(PasslootBiS.db.profile.Rules[idx][dbkey]) do
				if v[1]:lower() == command then
					found = true
					table.remove(PasslootBiS.db.profile.Rules[idx][dbkey], i)
					slash_feedback(flag, idx, command)
					break
				end
			end
			if not found then PasslootBiS:Pour("Item not found in Rule.") end
		end
	end
end

PasslootBiS.OptionsTable = {
	["type"] = "group",
	["handler"] = PasslootBiS,
	["get"] = "OptionsGet",
	["set"] = "OptionsSet",
	["args"] = {
		["Menu"] = {
			["name"] = L["Menu"],
			["order"] = 0,
			["desc"] = L["Opens the PasslootBiS Menu."],
			["type"] = "execute",
			["func"] = function()
				InterfaceOptionsFrame_OpenToCategory(L["PasslootBiS"])
			end,
		},
		["Test"] = {
			["name"] = L["Test"],
			["order"] = 30,
			["desc"] = L["Test an item link to see how we would roll"],
			["type"] = "input",
			["get"] = function() end,
			["set"] = function(info, value)
				local _, link = GetItemInfo(value)
				if not link then
					_, link = GameTooltip:GetItem()
				end

				if PasslootBiS.EvalCache[link] then
					PasslootBiS.TestLink = PasslootBiS.EvalCache[link]["itemObj"]
				else
					PasslootBiS.TestLink = PasslootBiS:InitItem(link)
				end
				if (PasslootBiS.TestLink) then
					PasslootBiS.TestCanNeed, PasslootBiS.TestCanGreed, PasslootBiS.TestCanDisenchant = true, true, true
					PasslootBiS:START_LOOT_ROLL()
				else
					PasslootBiS.TestLink = nil -- to make sure
				end
			end,
		},
		["NameRule"] = {
			["name"] = L["NameRule"],
			["order"] = 60,
			["desc"] = L["(Add) or (remove) an item by name to an existing rule."],
			["type"] = "input",
			["get"] = function() end,
			["set"] = function(info, value)
				handleAddRemove(value, "NameRule", "Items", "Turtle Meat")
				PasslootBiS:ResetCache()
			end,
		},
		["IDRule"] = {
			["name"] = L["IDRule"],
			["order"] = 50,
			["desc"] = L["(Add) or (remove) an item by id to an existing rule"],
			["type"] = "input",
			["get"] = function() end,
			["set"] = function(info, value)
				handleAddRemove(value, "IDRule", "ItemIDs", "3712")
				PasslootBiS:ResetCache()
			end,
		},
		["Options"] = {
			["name"] = L["Options"],
			["order"] = 20,
			["desc"] = L["General Options"],
			["type"] = "group",
			["args"] = {
				["Enable"] = {
					["name"] = L["Enable Mod"],
					["desc"] = L["Enable or disable this mod."],
					["type"] = "toggle",
					["order"] = 0,
					["get"] = "IsEnabled",
					["set"] = function(info, v)
						if (v) then
							PasslootBiS:Enable()
						else
							PasslootBiS:Disable()
						end
					end,
				},
				["Messages"] = {
					["name"] = L["Messages"],
					["type"] = "group",
					["order"] = 10,
					["inline"] = true,
					["args"] = {
						["Quiet"] = {
							["name"] = L["Quiet"],
							["desc"] = L["Checking this will prevent extra details from being displayed."],
							["type"] = "toggle",
							["order"] = 0,
							["arg"] = { "Quiet" },
						},
						["RollNeed"] = {
							["name"] = NEED,
							["desc"] = L["Enter the text displayed when rolling."],
							["type"] = "input",
							["order"] = 10,
							["arg"] = { "MessageText", "need" },
						},
						["RollGreed"] = {
							["name"] = GREED,
							["desc"] = L["Enter the text displayed when rolling."],
							["type"] = "input",
							["order"] = 20,
							["arg"] = { "MessageText", "greed" },
						},
						["RollDisenchant"] = {
							["name"] = ROLL_DISENCHANT,
							["desc"] = L["Enter the text displayed when rolling."],
							["type"] = "input",
							["order"] = 30,
							["arg"] = { "MessageText", "de" },
						},
						["RollPass"] = {
							["name"] = PASS,
							["desc"] = L["Enter the text displayed when rolling."],
							["type"] = "input",
							["order"] = 40,
							["arg"] = { "MessageText", "pass" },
						},
						["Ignore"] = {
							["name"] = IGNORE,
							["desc"] = L["Enter the text displayed when rolling."],
							["type"] = "input",
							["order"] = 50,
							["arg"] = { "MessageText", "ignore" },
						},
					},
				},
				["AllowMultipleConfirmPopups"] = {
					["name"] = L["Allow Multiple Confirm Popups"],
					["desc"] = L
						["Checking this will disable the exclusive bit to allow multiple confirmation of loot roll popups"],
					["type"] = "toggle",
					["order"] = 20,
					["arg"] = { "AllowMultipleConfirmPopups" },
					["set"] = function(info, value)
						PasslootBiS:OptionsSet(info, value)
						PasslootBiS:SetExclusiveConfirmPopupBit()
					end,
					["width"] = "full",
					["disabled"] = function(info, value) return not StaticPopupDialogs.CONFIRM_LOOT_ROLL end, -- Some versions of WoW (or addons that remove) don't have CONFIRM_LOOT_ROLL
				},
				["AutoConfirmBindOnRoll"] = {
					["name"] = L["Auto-Confirm Bind on Roll"],
					["desc"] = L["AutoConfirmBindOnRoll_Desc"],
					["type"] = "toggle",
					["order"] = 21,
					["arg"] = { "AutoConfirmBindOnRoll" },
					["width"] = "full",
				},
				["AutoConfirmBindOnPickup"] = {
					["name"] = L["Auto-Confirm Bind on Pickup"],
					["desc"] = L["AutoConfirmBindOnPickup_Desc"],
					["type"] = "toggle",
					["order"] = 22,
					["arg"] = { "AutoConfirmBindOnPickup" },
					["width"] = "full",
				},
				["ShowMinimapButton"] = {
					["name"] = L["Show Minimap Button"],
					["desc"] = L["Show Minimap Button_Desc"],
					["type"] = "toggle",
					["order"] = 25,
					["get"] = function() return not PasslootBiS.db.profile.Minimap.hide end,
					["set"] = function(info, value) PasslootBiS:SetMinimapButtonHidden(not value) end,
					["width"] = "full",
				},
				["SkipRules"] = {
					["name"] = L["Skip Rules"],
					["desc"] = L["Skip rules that have disabled or unknown filters."],
					["type"] = "toggle",
					["order"] = 30,
					["arg"] = { "SkipRules" },
				},
				["SkipWarning"] = {
					["name"] = L["Skip Warning"],
					["desc"] = L["Display a warning when a rule is skipped."],
					["type"] = "toggle",
					["order"] = 40,
					["arg"] = { "SkipWarning" },
				},
				["DisplayUnknownVars"] = {
					["name"] = L["Unknown Filters"],
					["desc"] = L["Displays disabled or unknown filter variables."],
					["type"] = "toggle",
					["order"] = 50,
					["arg"] = { "DisplayUnknownVars" },
					["set"] = function(info, value)
						PasslootBiS:OptionsSet(info, value)
						PasslootBiS:Rules_ActiveFilters_OnScroll()
					end,
				},
				["CleanRules"] = {
					["name"] = L["Clean Rules"],
					["desc"] = L["Removes disabled or unknown filters from current rules."],
					["type"] = "execute",
					["order"] = 60,
					["func"] = "CleanRules",
					["confirm"] = true,
					["confirmText"] = L["CLEAN RULES DESC"],
				},
			},
		},
		["Modules"] = {
			["name"] = L["Modules"],
			["order"] = 10,
			["type"] = "group",
			["args"] = {},
		},
		["Profiles"] = nil, -- Reserved for profile options
		["Output"] = nil, -- Reserved for sink output options
	},
}

-- A list of variables that are used in the DefaultTemplate (this is a quick lookup table of what variables are used)
PasslootBiS.DefaultVars = {
	-- [VariableName] = true,
}

function PasslootBiS:OptionsSet(Info, Value)
	local Table = self.db.profile
	for Key = 1, (#Info.arg - 1) do
		if (not Table[Info.arg[Key]]) then
			Table[Info.arg[Key]] = {}
		end
		Table = Table[Info.arg[Key]]
	end
	Table[Info.arg[#Info.arg]] = Value
end

function PasslootBiS:OptionsGet(Info)
	local Table = self.db.profile
	for Key = 1, (#Info.arg - 1) do
		if (not Table[Info.arg[Key]]) then
			Table[Info.arg[Key]] = {}
		end
		Table = Table[Info.arg[Key]]
	end
	return Table[Info.arg[#Info.arg]]
end

function PasslootBiS:SetExclusiveConfirmPopupBit()
	if (StaticPopupDialogs and StaticPopupDialogs.CONFIRM_LOOT_ROLL) then -- Some versions of WoW (or addons that remove) don't have CONFIRM_LOOT_ROLL
		if (self.db.profile.AllowMultipleConfirmPopups) then
			StaticPopupDialogs.CONFIRM_LOOT_ROLL.exclusive = nil
			StaticPopupDialogs.CONFIRM_LOOT_ROLL.multiple = 1
		else
			if (not StaticPopupDialogs.CONFIRM_LOOT_ROLL.exclusive) then -- Only modify this if we touched it.
				StaticPopupDialogs.CONFIRM_LOOT_ROLL.exclusive = 1
				StaticPopupDialogs.CONFIRM_LOOT_ROLL.multiple = nil
			end
		end
	end
end

function PasslootBiS:OnInitialize()
	-- Called when the addon is loaded
	-- LibStub("AceConsole-3.0"):RegisterChatCommand(L["PASSLOOT_SLASH_COMMAND"], function() InterfaceOptionsFrame_OpenToCategory(L["PasslootBiS"]) end)
	-- `true` (not "Default") => each character defaults to its OWN profile
	-- (keyed by "Name - Realm"), so loot rules + all profile state are
	-- character-specific instead of account-wide.
	self.db = LibStub("AceDB-3.0"):New("PasslootBiSDB", defaults, true)

	-- One-time migration off the legacy shared "Default" profile. Installs that
	-- predate the per-character default have every character pointing at the one
	-- shared "Default" profile; with the flip above, a NEW character lands on its
	-- own profile but an EXISTING one keeps its stored "Default" pointer. So the
	-- first time we see such a character, move it onto its own profile and copy
	-- the shared rules across, so nothing appears to vanish. Runs BEFORE the
	-- profile callbacks are registered, so the SetProfile/CopyProfile here stays
	-- silent (OnProfileChanged touches UI frames that don't exist yet in init).
	-- The flag lives in db.char (always per-character, profile-independent), so
	-- each character migrates exactly once and later manual profile choices in
	-- the Profiles tab are respected (we only move a char still on "Default").
	if not self.db.char.migratedToPerChar then
		local charKey = self.db.keys and self.db.keys.char
		if charKey and charKey ~= L["Default"] and self.db:GetCurrentProfile() == L["Default"] then
			self.db:SetProfile(charKey)
			self.db:CopyProfile(L["Default"], true)   -- copy shared rules in (silent)
		end
		self.db.char.migratedToPerChar = true
	end

	self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
	self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
	self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")
	-- self.db.RegisterCallback(self, "OnProfileDeleted", "OnProfileNewOrDelete")
	-- self.db.RegisterCallback(self, "OnNewProfile", "OnProfileNewOrDelete")
	self:SetSinkStorage(self.db.profile.SinkOptions)

	self.OptionsTable.args.Profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
	self.OptionsTable.args.Output = self:GetSinkAce3OptionsDataTable()
	self.OptionsTable.args.Import = self:BuildImportOptions()
	self.OptionsTable.args.BiSManager = self:BuildBiSManagerOptions()
	LibStub("AceConfig-3.0"):RegisterOptionsTable(L["PasslootBiS"], self.OptionsTable, { L["PASSLOOT_SLASH_COMMAND"] })
	-- Ability_Racial_PackHobgoblin
	-- INV_Misc_Bag_10
	-- INV_Misc_Coin_02
	-- Racial_Dwarf_FindTreasure
	self.LDB = LDB:NewDataObject("PasslootBiS", {
		["type"] = "launcher",
		-- The WoW Need-roll dice; kept in sync with the minimap button via
		-- PasslootBiS.MINIMAP_ICON (Core/MinimapButton.lua).
		["icon"] = PasslootBiS.MINIMAP_ICON,
		-- Both the LDB launcher and our own minimap button funnel into the same
		-- shared handlers so their left/right-click behaviour never drifts.
		["OnClick"] = function(_, button)
			PasslootBiS:MinimapButton_OnClick(button)
		end,
		["OnTooltipShow"] = function(tooltip)
			PasslootBiS:MinimapButton_OnTooltip(tooltip)
		end,
	})

	-- Our own minimap button (does not depend on an external LDB display addon).
	self:CreateMinimapButton()

	-- self.MainFrame = self:Create_MainFrame()
	self.RulesFrame = self:Create_RulesFrame()
	InterfaceOptions_AddCategory(self.RulesFrame)
	-- First paint of the advisor status panel (Core/AdvisorStatus.lua). It keeps
	-- itself current from its own OnShow/OnUpdate afterwards; this is just so the
	-- rows are never blank on the very first look, whatever order the panel's
	-- OnShow and this assignment happen to land in.
	self:RefreshAdvisorStatus()
	self.Tooltip = self:Create_PasslootBiSTooltip()
	-- self.BlizOptionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("PasslootBiS", L["PasslootBiS"])
	self.BlizOptionsFrames = {
		["Modules"] = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(L["PasslootBiS"], L["Modules"], L["PasslootBiS"],
			"Modules"),
		["GeneralOptions"] = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(L["PasslootBiS"], L["Options"], L["PasslootBiS"],
			"Options"),
		["Profiles"] = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(L["PasslootBiS"], L["Profiles"], L["PasslootBiS"],
			"Profiles"),
		["Output"] = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(L["PasslootBiS"], L["Output"], L["PasslootBiS"], "Output"),
		["Import"] = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(L["PasslootBiS"], L["Import BiS"], L["PasslootBiS"], "Import"),
		["BiSManager"] = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(L["PasslootBiS"], L["BiS Manager"], L["PasslootBiS"], "BiSManager"),
	}

	-- PanelTemplates_SetNumTabs(PasslootBiS_TabbedMenuContainer, 2)  -- 2 because there are 2 tabs total.
	-- PanelTemplates_SetTab(PasslootBiS_TabbedMenuContainer, 1)      -- 1 because we want tab 1 selected.
	-- PanelTemplates_UpdateTabs(PasslootBiS_TabbedMenuContainer)
	self.DropDownFrame = CreateFrame("Frame", "PasslootBiS_DropDownMenu", nil, "UIDropDownMenuTemplate")
end

-- The "Import BiS" options panel (Interface > AddOns > PassLoot (BiS) > Import
-- BiS). A paste box for a PLBIS1 string + Replace/Merge + an Import button.
-- The actual parse/validate/build lives in Modules/BiSImport.lua, which attaches
-- itself to this addon as self.BiSImport once loaded.
function PasslootBiS:BuildImportOptions()
	return {
		["type"] = "group",
		["name"] = L["Import BiS"],
		["order"] = 50,
		["args"] = {
			["intro"] = {
				["type"] = "description",
				["order"] = 1,
				["fontSize"] = "medium",
				["name"] = L["ImportBiS_Intro"],
			},
			["url"] = {
				["type"] = "input",
				["order"] = 2,
				["width"] = "full",
				["name"] = L["ImportBiS_GetString"],
				["desc"] = L["ImportBiS_UrlDesc"],
				-- Read-only, on-page copy source: the field always shows the URL
				-- so it can be clicked and copied (Ctrl+A, Ctrl+C) without a
				-- pop-up — pop-ups render behind the Blizzard options window on
				-- this client. Edits are ignored so the address can't be clobbered.
				["get"] = function() return L["ImportBiS_Url"] end,
				["set"] = function() end,
			},
			["input"] = {
				["type"] = "input",
				["order"] = 3,
				["width"] = "full",
				["multiline"] = 10,
				["name"] = L["Import string"],
				["desc"] = L["ImportBiS_InputDesc"],
				["get"] = function() return self.BiSImportBuffer or "" end,
				["set"] = function(_, value) self.BiSImportBuffer = value end,
			},
			-- New vs. overwrite: by default an import creates a NEW list (its own
			-- name, uniquified so it never clobbers an existing one). The user can
			-- instead pick an existing BiS list to overwrite. Values are rebuilt
			-- from the live rules each time the dropdown opens.
			["target"] = {
				["type"] = "select",
				["order"] = 4,
				["style"] = "dropdown",
				["name"] = L["ImportBiS_Target"],
				["desc"] = L["ImportBiS_TargetDesc"],
				["values"] = function()
					local vals = { ["\1new"] = L["ImportBiS_NewList"] }
					for _, name in ipairs(self:EnumerateBiSLists()) do
						vals[name] = L["ImportBiS_Overwrite"] .. " " .. name
					end
					return vals
				end,
				["get"] = function()
					local t = self.BiSImportTarget or "\1new"
					-- Fall back to "new" if the chosen list was since removed.
					if t ~= "\1new" and not self:BiSListExists(t) then
						t = "\1new"; self.BiSImportTarget = t
					end
					return t
				end,
				["set"] = function(_, value) self.BiSImportTarget = value end,
			},
			["go"] = {
				["type"] = "execute",
				["order"] = 5,
				["name"] = L["Import"],
				["desc"] = L["ImportBiS_GoDesc"],
				["func"] = function() self:DoBiSImport() end,
			},
			-- In-panel result line. LibSink output (self:Pour) can land behind
			-- the Interface Options window; this always shows the last result
			-- right here in the panel. Blank until the first import.
			["status"] = {
				["type"] = "description",
				["order"] = 6,
				["fontSize"] = "medium",
				["name"] = function() return PasslootBiS.BiSImportStatus or "" end,
			},
		},
	}
end

-- === BiS Manager =========================================================
-- The BiS Manager page replaces the old Farm Plan + Alternatives panels: pick an
-- imported BiS list and see ALL its items grouped by drop source (kept as data,
-- from the imported string's additive `mgr` block — protocol §3.5,
-- db.profile.BiSManage). Each item's checkbox means "auto-roll on this": items
-- from sources that produce a loot-roll window (dungeon / raid / forged drops)
-- default ON; the rest (vendor / reputation / crafting …) default OFF — visible
-- and toggleable, but off the roll rules so they don't clutter them (rolling on
-- an item you can't get a roll frame for is pointless). Apply rebuilds the list's
-- two match rules from exactly the ticked items. Invariants 1-2 hold: the id/name
-- lists stay ID/name-only and never combine; we only ever choose WHICH already-
-- classified items to roll on (curation, not resolution — invariant 3 intact).

-- A BiS list is a pair of rules "<name> (IDs)" / "<name> (Suffix)"; the list
-- name is the Desc with that suffix stripped.
local LIST_ID_SUFFIX = " (IDs)"
local LIST_NAME_SUFFIX = " (Suffix)"

-- Source categories that produce a loot-roll window, so their items auto-roll by
-- default (owner decision 2026-08-11; sources use the DB's `sourceCategory` enum,
-- matching the converter). Everything else (vendor / reputation / crafting /
-- affixed / worldboe / pvp / quests / events) is kept on the list as data but off
-- the roll rules until the user ticks it. Edit this set to change the defaults;
-- the per-item checkboxes always override it.
local ROLL_SOURCE_CATEGORIES = {
	["dungeon"] = true,
	["raid"] = true,
	["worldboss"] = true,
	["worldforged"] = true,
	["bloodforged"] = true,
}
local function isRollCategory(cat)
	return cat ~= nil and ROLL_SOURCE_CATEGORIES[cat] == true
end

local function baseFromDesc(desc)
	if type(desc) ~= "string" then return nil end
	if desc:sub(-#LIST_ID_SUFFIX) == LIST_ID_SUFFIX then
		return desc:sub(1, #desc - #LIST_ID_SUFFIX)
	end
	if desc:sub(-#LIST_NAME_SUFFIX) == LIST_NAME_SUFFIX then
		return desc:sub(1, #desc - #LIST_NAME_SUFFIX)
	end
	return nil
end

-- First index of a rule with this exact Desc, or nil.
local function findRuleByDesc(rules, desc)
	for i = 1, #rules do
		if rules[i] and rules[i].Desc == desc then return i end
	end
	return nil
end

-- Remove every rule whose Desc matches (there should be at most one). Iterates
-- backwards so table.remove doesn't skip entries.
local function removeRuleByDesc(rules, desc)
	for i = #rules, 1, -1 do
		if rules[i] and rules[i].Desc == desc then table.remove(rules, i) end
	end
end

-- Best-effort display name for an ID-matched item lacking stored `mgr` metadata
-- (an old import). Names read from the client are reliable (research §2.4a);
-- only ilvl/stats lie. Falls back to "Item #<id>" until the cache fills.
local function idDisplayName(key)
	if type(GetItemInfo) == "function" then
		local n = GetItemInfo(tonumber(key) or 0)
		if n and n ~= "" then return n end
	end
	return "Item #" .. tostring(key)
end

-- Ordered list of BiS list names present in the rules (first-seen order), plus a
-- set for existence checks. Only import-built lists (the "(IDs)"/"(Suffix)" pairs)
-- count — hand-made rules like "Greed on Green" are not BiS lists.
function PasslootBiS:EnumerateBiSLists()
	local rules = self.db and self.db.profile and self.db.profile.Rules
	local order, seen = {}, {}
	local function add(base)
		if base and base ~= "" and not seen[base] then
			seen[base] = true
			order[#order + 1] = base
		end
	end
	if type(rules) == "table" then
		for _, rule in ipairs(rules) do add(baseFromDesc(rule and rule.Desc)) end
	end
	-- Also surface lists that still hold `mgr` data but currently have no rules
	-- (e.g. the user unticked every item), so they stay visible + editable here.
	local manage = self.db and self.db.profile and self.db.profile.BiSManage
	if type(manage) == "table" then
		for base in pairs(manage) do add(base) end
	end
	return order, seen
end

function PasslootBiS:BiSListExists(name)
	local _, seen = self:EnumerateBiSLists()
	return seen[name] == true
end

-- A list name that does not collide with an existing BiS list (append " (2)",
-- " (3)"... until free), so "create new list" never clobbers another list.
function PasslootBiS:UniqueBiSListName(base)
	base = (type(base) == "string" and base ~= "") and base or "PLBIS import"
	local _, seen = self:EnumerateBiSLists()
	if not seen[base] then return base end
	local i = 2
	while seen[base .. " (" .. i .. ")"] do i = i + 1 end
	return base .. " (" .. i .. ")"
end

-- The set of match keys ("id\0<id>" / "name\0<name>") currently IN a list's two
-- rules — i.e. which items the character auto-rolls on right now. Used to seed the
-- BiS Manager checkboxes.
function PasslootBiS:BiSListRuleKeySet(base)
	local rules = self.db.profile.Rules
	local set = {}
	local idIdx = findRuleByDesc(rules, base .. LIST_ID_SUFFIX)
	if idIdx and type(rules[idIdx].ItemIDs) == "table" then
		for _, tuple in ipairs(rules[idIdx].ItemIDs) do set["id\0" .. tostring(tuple[1])] = true end
	end
	local nameIdx = findRuleByDesc(rules, base .. LIST_NAME_SUFFIX)
	if nameIdx and type(rules[nameIdx].Items) == "table" then
		for _, tuple in ipairs(rules[nameIdx].Items) do set["name\0" .. tostring(tuple[1])] = true end
	end
	return set
end

-- Is this item on a BiS list that is CURRENTLY ROLLING, and if so which list?
-- The host half of BiS Check: an advisor cannot see the BiS list (it lives in these
-- rules), so this answer is put on the roll ctx for it (see ProcessLootRoll).
--
-- "Currently rolling" is the rule entries, not BiSManage. BiSManage is the full
-- imported list including items the user has unticked, and an unticked item never
-- produces a roll to warn about — warning on it would be noise about a decision the
-- user already made.
--
-- Exception entries (the tuple's 3rd field) are skipped: an exception means "match
-- everything EXCEPT this", so the item is explicitly NOT wanted and is the opposite
-- of a BiS pick.
--
-- Deliberately uncached. It runs a handful of times per boss, costs one pass over
-- the rules with an early exit, and allocates nothing — where a cache would need
-- invalidating from import, Apply, delete, every rule edit and every profile
-- switch, and would answer stale exactly when the user had just fixed their list.
function PasslootBiS:IsBiSItem(id, name)
	local rules = self.db and self.db.profile and self.db.profile.Rules
	if type(rules) ~= "table" then return false, nil end
	local idKey = id and tostring(id) or nil
	if not idKey and not name then return false, nil end

	for i = 1, #rules do
		local rule = rules[i]
		local base = rule and baseFromDesc(rule.Desc)
		if base then
			if idKey and type(rule.ItemIDs) == "table" then
				for _, tuple in ipairs(rule.ItemIDs) do
					if not tuple[3] and tostring(tuple[1]) == idKey then return true, base end
				end
			end
			if name and type(rule.Items) == "table" then
				for _, tuple in ipairs(rule.Items) do
					-- Exact-match entries only. A BiS list only ever emits "Exact" names
					-- (BiSImport invariant), and a substring rule the user hand-added to
					-- the same list is not a BiS pick for a specific item.
					if not tuple[3] and tuple[2] == "Exact" and tuple[1] == name then
						return true, base
					end
				end
			end
		end
	end
	return false, nil
end

-- Gather ALL of a BiS list's items for the manager view. When the list has stored
-- `mgr` metadata (the normal case) that is the membership — every item, whether or
-- not it currently rolls — each tagged with `.rolls` (is it in the rules now?).
-- Without `mgr` (an old / lean import) we fall back to the rule entries themselves,
-- which by definition all roll. Returns an array of
-- { kind, key, name, source, category, rolls } in stored order.
function PasslootBiS:CollectBiSListItems(base)
	local rules = self.db.profile.Rules
	local manage = self.db.profile.BiSManage and self.db.profile.BiSManage[base]
	local inRules = self:BiSListRuleKeySet(base)
	local items = {}

	if type(manage) == "table" and #manage > 0 then
		for _, rec in ipairs(manage) do
			local key = tostring(rec.key)
			items[#items + 1] = {
				kind = rec.kind, key = rec.key,
				name = (rec.name and rec.name ~= "" and rec.name)
					or (rec.kind == "id" and idDisplayName(key) or rec.key),
				source = rec.source and rec.source ~= "" and rec.source or nil,
				category = rec.category and rec.category ~= "" and rec.category or nil,
				slot = rec.slot and rec.slot ~= "" and rec.slot or nil,
				score = type(rec.score) == "number" and rec.score or nil,
				rolls = inRules[tostring(rec.kind) .. "\0" .. key] == true,
			}
		end
		return items
	end

	-- Fallback: no mgr metadata — build from the rule entries (all rolling).
	local idIdx = findRuleByDesc(rules, base .. LIST_ID_SUFFIX)
	if idIdx and type(rules[idIdx].ItemIDs) == "table" then
		for _, tuple in ipairs(rules[idIdx].ItemIDs) do
			local key = tostring(tuple[1])
			items[#items + 1] = { kind = "id", key = key, name = idDisplayName(key),
				source = nil, category = nil, rolls = true }
		end
	end
	local nameIdx = findRuleByDesc(rules, base .. LIST_NAME_SUFFIX)
	if nameIdx and type(rules[nameIdx].Items) == "table" then
		for _, tuple in ipairs(rules[nameIdx].Items) do
			items[#items + 1] = { kind = "name", key = tuple[1], name = tuple[1],
				source = nil, category = nil, rolls = true }
		end
	end
	return items
end

-- Rebuild the BiS Manager options table and tell Ace to redraw it. Called after
-- an import, a list switch, an Apply, or a Reset.
function PasslootBiS:RefreshBiSManager()
	if self.OptionsTable and self.OptionsTable.args then
		self.OptionsTable.args.BiSManager = self:BuildBiSManagerOptions()
		local reg = LibStub("AceConfigRegistry-3.0", true)
		if reg then reg:NotifyChange(L["PasslootBiS"]) end
	end
	-- Keep the floating window in sync (list switch, Apply, Reset, import).
	if self.BiSManagerWindowFrame and self.BiSManagerWindowFrame:IsShown() then
		self:BiSManagerWindow_Render()
	end
end

-- The effective "auto-roll on this item" state for a manager checkbox: an
-- unsaved tick the user made this session (staging) wins; otherwise it reflects
-- whether the item is in the rules right now (`base_rolls`, from CollectBiSListItems).
function PasslootBiS:BiSManagerRolls(base, kind, key, base_rolls)
	local st = self.BiSManagerStaging and self.BiSManagerStaging[base]
	local sk = tostring(kind) .. "\0" .. tostring(key)
	if type(st) == "table" and st[sk] ~= nil then return st[sk] == true end
	return base_rolls == true
end

-- The BiS Manager options panel — a thin launcher for the floating manager
-- window. Real in-game item tooltips and by-source/slot/score sorting need custom
-- frame rows (Ace's options widgets can't show an item tooltip or re-sort in
-- place), so the item list, tick boxes, and Apply/Reset live in the window
-- (CreateBiSManagerWindow below); this page just picks the list and opens it.
function PasslootBiS:BuildBiSManagerOptions()
	local args = {
		["intro"] = {
			["type"] = "description",
			["order"] = 1,
			["fontSize"] = "medium",
			["name"] = L["BiSManager_Intro"],
		},
	}

	local lists = self:EnumerateBiSLists()
	if #lists == 0 then
		args["empty"] = {
			["type"] = "description",
			["order"] = 2,
			["fontSize"] = "medium",
			["name"] = L["BiSManager_Empty"],
		}
		return { ["type"] = "group", ["name"] = L["BiS Manager"], ["order"] = 55, ["args"] = args }
	end

	-- Keep the selection valid (default to the first list).
	local sel = self.BiSManagerSelected
	local selValid = false
	for _, n in ipairs(lists) do if n == sel then selValid = true; break end end
	if not selValid then sel = lists[1]; self.BiSManagerSelected = sel end

	local listVals = {}
	for _, n in ipairs(lists) do listVals[n] = n end
	args["list"] = {
		["type"] = "select",
		["order"] = 2,
		["style"] = "dropdown",
		["name"] = L["BiSManager_List"],
		["desc"] = L["BiSManager_ListDesc"],
		["values"] = listVals,
		["get"] = function() return self.BiSManagerSelected end,
		["set"] = function(_, value)
			self.BiSManagerSelected = value
			self.BiSManagerConfirmDelete = nil   -- disarm a pending delete on switch
			self.BiSManagerStatus = nil   -- clear a prior list's "applied" line
			self:RefreshBiSManager()      -- redraws this page + the window if open
		end,
	}
	args["open"] = {
		["type"] = "execute",
		["order"] = 3,
		["name"] = L["BiSManager_Open"],
		["desc"] = L["BiSManager_OpenDesc"],
		["func"] = function() self:ToggleBiSManagerWindow(true) end,
	}
	-- Delete the selected list (per-character). Arm-to-confirm: first click arms
	-- and recolors the label, second click deletes. No StaticPopup (§8.6 — this
	-- client keeps all UI on the options page; no popups/overlays).
	args["delete"] = {
		["type"] = "execute",
		["order"] = 6,
		["name"] = function()
			if self.BiSManagerConfirmDelete
			   and self.BiSManagerConfirmDelete == self.BiSManagerSelected then
				return "|cffff4444" ..
					string.format(L["BiSManager_DeleteConfirm"], tostring(self.BiSManagerSelected)) .. "|r"
			end
			return L["BiSManager_Delete"]
		end,
		["desc"] = L["BiSManager_DeleteDesc"],
		["func"] = function()
			local selNow = self.BiSManagerSelected
			if not selNow then return end
			if self.BiSManagerConfirmDelete == selNow then
				self:DeleteBiSList(selNow)         -- clears the arm + refreshes
			else
				self.BiSManagerConfirmDelete = selNow   -- arm; recolor on redraw
				self:RefreshBiSManager()
			end
		end,
	}
	args["hint"] = {
		["type"] = "description",
		["order"] = 4,
		["fontSize"] = "medium",
		["name"] = L["BiSManager_Hint"],
	}
	args["status"] = {
		["type"] = "description",
		["order"] = 10,
		["fontSize"] = "medium",
		["name"] = function() return PasslootBiS.BiSManagerStatus or "" end,
	}

	return { ["type"] = "group", ["name"] = L["BiS Manager"], ["order"] = 55, ["args"] = args }
end

-- Commit the current tick selection for the active list: rebuild its two match
-- rules from exactly the items ticked "auto-roll", leaving ALL items on the list
-- as data (BiSManage is never pruned — that's what keeps the unrolled items
-- visible for reference and future features). Then refresh the rule list + page.
function PasslootBiS:ApplyBiSManager()
	local base = self.BiSManagerSelected
	local BiS = self.BiSImport
	local rules = self.db and self.db.profile and self.db.profile.Rules
	if not (base and BiS and type(rules) == "table") then return end

	-- Preserve the list's roll action (need/greed/…) from whichever rule exists.
	local roll = "need"
	local idIdx = findRuleByDesc(rules, base .. LIST_ID_SUFFIX)
	local nameIdx = findRuleByDesc(rules, base .. LIST_NAME_SUFFIX)
	if idIdx and rules[idIdx].Loot and rules[idIdx].Loot[1] then
		roll = rules[idIdx].Loot[1]
	elseif nameIdx and rules[nameIdx].Loot and rules[nameIdx].Loot[1] then
		roll = rules[nameIdx].Loot[1]
	end

	-- Build the roll set from the effective tick state over ALL of the list's items.
	local items = self:CollectBiSListItems(base)
	local ids, names, seenId, seenName = {}, {}, {}, {}
	local rolled = 0
	for _, it in ipairs(items) do
		if self:BiSManagerRolls(base, it.kind, it.key, it.rolls) then
			rolled = rolled + 1
			if it.kind == "id" then
				local n = tonumber(it.key)
				if n and not seenId[n] then seenId[n] = true; ids[#ids + 1] = n end
			elseif not seenName[it.key] then
				seenName[it.key] = true; names[#names + 1] = it.key
			end
		end
	end

	-- Rebuild the two rules from exactly the ticked items. ApplyToRules rebuilds each
	-- one WHERE IT STANDS and drops the one a now-empty list no longer needs, so this
	-- keeps the priority the user gave the list and their Before Advisor tick --
	-- deleting the rules here first (as this used to) threw both away on every apply.
	BiS.ApplyToRules({ ids = ids, names = names, roll = roll, desc = base }, "replace", rules)
	self:PartitionRules(rules) -- keep the two rule-list sections truthful

	-- Selection committed; clear staging for this list.
	self.BiSManagerStaging = self.BiSManagerStaging or {}
	self.BiSManagerStaging[base] = {}

	self.BiSManagerStatus = "|cff55ff55" ..
		string.format(L["BiSManager_Applied"], rolled, #items, tostring(base)) .. "|r"

	-- Drop the main rule-list selection, redraw it, then refresh this page. Clearing
	-- rather than clamping: rebuilding a list can add or drop a rule above the
	-- selected one, and a highlight left on a shifted index points at the wrong rule.
	self.CurrentRule = 0
	if self.RulesFrame and self.Rules_RuleList_OnScroll then
		self:Rules_RuleList_OnScroll()
		self:DisplayCurrentRule()   -- clears the filter/description half for "no rule"
	end
	self:RefreshBiSManager()
end

-- Delete a BiS list ENTIRELY (not just untick its items): drop its two match
-- rules AND its stored `mgr` metadata + any transient staging. Rules and
-- BiSManage both live in db.profile, which is now per-character, so this only
-- cleans up the CURRENT character — every other character keeps its own copy
-- (the per-character migration gave each one a separate copy of the old shared
-- lists, which is why an old account-wide list shows up here to begin with).
function PasslootBiS:DeleteBiSList(base)
	if not base or base == "" then return end
	local rules = self.db.profile.Rules
	if type(rules) == "table" then
		removeRuleByDesc(rules, base .. LIST_ID_SUFFIX)
		removeRuleByDesc(rules, base .. LIST_NAME_SUFFIX)
	end
	if type(self.db.profile.BiSManage) == "table" then
		self.db.profile.BiSManage[base] = nil
	end
	if type(self.BiSManagerStaging) == "table" then
		self.BiSManagerStaging[base] = nil
	end

	-- Selection + confirm-arm move off the now-gone list.
	if self.BiSManagerSelected == base then self.BiSManagerSelected = nil end
	self.BiSManagerConfirmDelete = nil

	-- Keep the main rule-list selection valid + redraw it.
	if type(rules) == "table" and self.CurrentRule and self.CurrentRule > #rules then
		self.CurrentRule = nil
	end
	if self.RulesFrame and self.Rules_RuleList_OnScroll then self:Rules_RuleList_OnScroll() end

	-- If the floating window is open and nothing's left to show, close it (a nil
	-- selection has no list to render); otherwise RefreshBiSManager re-renders it
	-- against the re-validated selection.
	if self.BiSManagerWindowFrame and self.BiSManagerWindowFrame:IsShown() then
		local remaining = self:EnumerateBiSLists()
		if #remaining == 0 then self:ToggleBiSManagerWindow(false) end
	end

	self.BiSManagerStatus = "|cff55ff55" ..
		string.format(L["BiSManager_Deleted"], tostring(base)) .. "|r"
	self:RefreshBiSManager()
end


--=============================================================================
-- BiS Manager window (custom floating frame)
--
-- Real in-game item tooltips + sortable-by-source/slot/score need custom widgets:
-- Ace's options page can neither show an item tooltip on hover nor re-sort a
-- multiselect in place. So the manager's item list is a floating frame of pooled
-- rows — each row a roll checkbox + a rarity-coloured label — and hovering a row
-- shows the item's WoW tooltip (SetHyperlink for an ID item; a text panel for a
-- suffix/name item, which carries no id). It reuses the SAME staging/apply logic
-- as before (BiSManagerStaging / BiSManagerRolls / ApplyBiSManager), so ticking
-- here and clicking Apply rebuilds the two match rules exactly as the old options
-- page did — no matching/resolution change (invariants 1-3 untouched).
--
-- §8.6: a plain gameplay frame (not a StaticPopup), at a strata above the
-- Interface Options window + SetToplevel, so it renders in front of the options
-- panel it is launched from.
--=============================================================================

local MGR_ROW_HEIGHT = 20
local MGR_WIN_WIDTH = 380
local MGR_CONTENT_WIDTH = 336
local MGR_SORTS = { "source", "slot", "score" }

-- Perf probe (opt-in via /plbismgr perf). debugprofilestop() is ms since login and
-- is a stock Blizzard API (absent from the Ascension dumps only because those skew
-- to custom surface); guard so a client without it degrades to untimed.
local mgrProfClock = (type(debugprofilestop) == "function") and debugprofilestop or nil

-- When the probe is on, time a tooltip resolve and fold it into PasslootBiS.MgrPerf
-- SILENTLY (per-line prints flood the chat) — read the summary on demand with
-- /plbismgr. Field data (2026-08-12) showed the visible GameTooltip render, not the
-- item-data load, is what costs ~3-11ms per hover (data load is ~0.5ms and stays
-- cached), so we keep measuring that but without the spam. Peak keeps its link so
-- the report can name the worst offender — handy for catching a once-per-login
-- outlier (enable perf right after a fresh LOGIN, before the first hover/drag).
local function mgrTimeSetHyperlink(tt, link, tag)
	if not (PasslootBiS.MgrPerfDebug and mgrProfClock) then
		tt:SetHyperlink(link)
		return
	end
	local t0 = mgrProfClock()
	tt:SetHyperlink(link)
	local dt = mgrProfClock() - t0
	local perf = PasslootBiS.MgrPerf
	if type(perf) ~= "table" then perf = {}; PasslootBiS.MgrPerf = perf end
	local s = perf[tag]
	if not s then s = { n = 0, total = 0, peak = 0 }; perf[tag] = s end
	s.n = s.n + 1
	s.total = s.total + dt
	if dt > s.peak then s.peak = dt; s.peakLink = link end
end

-- Paperdoll slot order for the "by slot" sort (mirrors the converter's SLOT_ORDER
-- in candidates.py). Slots not listed sort after these; items with no slot fall in
-- the Unknown bucket, which sinks to the end.
local MGR_SLOT_ORDER = {
	"Head", "Neck", "Shoulders", "Back", "Chest", "Wrists", "Hands", "Waist",
	"Legs", "Feet", "Finger", "Trinket", "One-Hand", "Two-Hand", "Main Hand",
	"Off Hand", "Held In Off-hand", "Shield", "Ranged",
}
local MGR_SLOT_RANK = {}
for i = 1, #MGR_SLOT_ORDER do MGR_SLOT_RANK[MGR_SLOT_ORDER[i]] = i end

-- A display score: whole numbers bare, otherwise one decimal.
local function mgrScoreText(score)
	if type(score) ~= "number" then return nil end
	if math.floor(score) == score then return string.format("%d", score) end
	return string.format("%.1f", score)
end

-- Hex colour for an item name. An ID item borrows its cached quality colour when
-- known (names/quality read from the client are reliable — only ilvl/stats lie,
-- research §2.4a); everything else is plain white.
local function mgrNameHex(it)
	if it.kind == "id" and type(GetItemInfo) == "function" then
		local _, _, quality = GetItemInfo(tonumber(it.key) or 0)
		if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
			local c = ITEM_QUALITY_COLORS[quality]
			return string.format("%02x%02x%02x",
				math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
		end
	end
	return "ffffff"
end

-- Row label: rarity-coloured name + compact grey tags (score / slot / category),
-- dropping whichever tag we're currently grouped by so it isn't repeated.
local function mgrRowLabel(it, mode)
	local label = "|cff" .. mgrNameHex(it) .. tostring(it.name) .. "|r"
	local tags = {}
	local st = mgrScoreText(it.score)
	if st and mode ~= "score" then tags[#tags + 1] = string.format(L["BiSManager_ScoreLabel"], st) end
	if it.slot and mode ~= "slot" then tags[#tags + 1] = tostring(it.slot) end
	if it.category then tags[#tags + 1] = tostring(it.category) end
	if #tags > 0 then
		label = label .. "  |cff808080" .. table.concat(tags, " \194\183 ") .. "|r"
	end
	return label
end

-- Item tooltip on row hover: the real WoW tooltip for an ID item (SetHyperlink),
-- a text panel for a name item, both with a manager footer (score + roll state —
-- metadata the item link lacks). Base stats shown are nominal; Ascension scales
-- instances server-side (invariant 1), so treat the numbers as identification.
local function mgrRowTooltip(row)
	local it = row.item
	if not it then return end
	-- While the window is being dragged, skip tooltip resolution entirely (mitigation
	-- #2). A native StartMoving drag keeps the cursor on the grabbed row so this
	-- rarely fires mid-drag, but the guard makes sure a row sliding under the cursor
	-- never triggers a first-see item load in the middle of a move.
	if PasslootBiS.BiSManagerDragging then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	if it.kind == "id" then
		mgrTimeSetHyperlink(GameTooltip, "item:" .. tostring(it.key), "hover")
	else
		GameTooltip:SetText(tostring(it.name), 1, 1, 1)
		if it.slot then GameTooltip:AddLine(tostring(it.slot), 0.8, 0.8, 0.8) end
		if it.source then GameTooltip:AddLine(tostring(it.source), 0.8, 0.8, 0.8) end
	end
	local st = mgrScoreText(it.score)
	if st then GameTooltip:AddLine(string.format(L["BiSManager_ScoreLabel"], st), 0.6, 0.8, 1.0) end
	local rolling = PasslootBiS:BiSManagerRolls(row.base, it.kind, it.key, it.rolls)
	if rolling then
		GameTooltip:AddLine(L["BiSManager_TipRolling"], 0.3, 1.0, 0.3)
	else
		GameTooltip:AddLine(L["BiSManager_TipNotRolling"], 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

-- Score-desc comparator (scored items first, then by name) shared by the score
-- view and the within-slot ordering.
local function mgrByScore(a, b)
	local sa, sb = a.score, b.score
	local ha, hb = (type(sa) == "number"), (type(sb) == "number")
	if ha ~= hb then return ha end
	if ha and hb and sa ~= sb then return sa > sb end
	return tostring(a.name) < tostring(b.name)
end

-- Build the ordered display list (header + item entries) for a sort mode. Entries
-- are { header = true, text, count, roll, showTag } or { it = <item> }.
local function mgrBuildDisplayList(items, mode)
	local OTHER = L["BiSManager_OtherSource"]
	local UNKNOWN = L["BiSManager_UnknownSlot"]
	local entries = {}

	if mode == "score" then
		local sorted = {}
		for i = 1, #items do sorted[i] = items[i] end
		table.sort(sorted, mgrByScore)
		entries[#entries + 1] = { header = true, text = L["BiSManager_ScoreHeader"], count = #sorted }
		for i = 1, #sorted do entries[#entries + 1] = { it = sorted[i] } end
		return entries
	end

	-- Group by source or slot.
	local groups, gorder = {}, {}
	for _, it in ipairs(items) do
		local gkey
		if mode == "slot" then gkey = it.slot or UNKNOWN else gkey = it.source or OTHER end
		local g = groups[gkey]
		if not g then g = { key = gkey, items = {} }; groups[gkey] = g; gorder[#gorder + 1] = g end
		g.items[#g.items + 1] = it
	end

	if mode == "slot" then
		table.sort(gorder, function(a, b)
			local ua, ub = (a.key == UNKNOWN), (b.key == UNKNOWN)
			if ua ~= ub then return ub end                              -- Unknown last
			local ra = MGR_SLOT_RANK[a.key] or (#MGR_SLOT_ORDER + 1)
			local rb = MGR_SLOT_RANK[b.key] or (#MGR_SLOT_ORDER + 1)
			if ra ~= rb then return ra < rb end
			return a.key < b.key
		end)
		for _, g in ipairs(gorder) do table.sort(g.items, mgrByScore) end
	else -- source: rank by count, Other last, then name
		table.sort(gorder, function(a, b)
			local ao, bo = (a.key == OTHER), (b.key == OTHER)
			if ao ~= bo then return bo end
			if #a.items ~= #b.items then return #a.items > #b.items end
			return a.key < b.key
		end)
	end

	for _, g in ipairs(gorder) do
		local cat = g.items[1] and g.items[1].category
		entries[#entries + 1] = {
			header = true, text = g.key, count = #g.items,
			-- Only the source view can tag a whole group roll/info (one source maps
			-- to one category); a slot mixes categories, so no tag there.
			roll = (mode == "source") and isRollCategory(cat) or nil,
			showTag = (mode == "source"),
		}
		for _, it in ipairs(g.items) do entries[#entries + 1] = { it = it } end
	end
	return entries
end

-- Acquire (or lazily create) pooled row `i` under the window's scroll content.
local function mgrAcquireRow(f, i)
	local row = f.rows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, f.content)
	row:SetWidth(MGR_CONTENT_WIDTH)
	row:SetHeight(MGR_ROW_HEIGHT)
	row:EnableMouse(true)

	local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	check:SetWidth(20)
	check:SetHeight(20)
	check:SetPoint("LEFT", row, "LEFT", 8, 0)
	row.check = check

	local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetJustifyH("LEFT")
	row.label = label

	row:SetScript("OnEnter", function(self2) mgrRowTooltip(self2) end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	check:SetScript("OnClick", function(cb)
		local it = row.item
		if not it or not row.base then return end
		PasslootBiS.BiSManagerStaging = PasslootBiS.BiSManagerStaging or {}
		local st = PasslootBiS.BiSManagerStaging[row.base]
		if type(st) ~= "table" then st = {}; PasslootBiS.BiSManagerStaging[row.base] = st end
		-- Record the desired roll state (true = roll on it). Cleared to the rules'
		-- current state on Apply / Reset.
		st[tostring(it.kind) .. "\0" .. tostring(it.key)] = cb:GetChecked() and true or false
	end)

	f.rows[i] = row
	return row
end

-- Strata + frame level for a hand-rolled window that has to be visible while you
-- play. Defined here for the same reason as the backdrop below: Core/PassLoot.lua
-- loads first (see Core/Core.xml), so one edit moves every window that uses it.
--
-- MEDIUM, not LOW: LOW is where Blizzard's action bars and unit frames live, and
-- they are toplevel, so clicking one restacks LOW and lifts it over anything of ours
-- sitting there. MEDIUM clears them and still leaves the window UNDER the Blizzard
-- panels on HIGH and above (bags, character sheet, world map), which is the layering
-- custom UI is expected to take.
--
-- The level matters as much as the strata: bar addons (Bartender among them) default
-- to MEDIUM too, and within one strata the higher frame level wins. Blizzard's frames
-- and the bar addons sit in the low single digits there, so 100 clears them with room
-- for a window's own children, which take 101 upwards.
--
-- It also replaces Raise() for front-on-open. Raise() reorders a frame against every
-- sibling in its strata -- the exact operation the drag-freeze is made of, cheap on a
-- sparse strata but the ~0.6-2.6s engine pass on a populated one, and MEDIUM is
-- populated. Setting one frame's level reorders nothing, so call this again from the
-- show path instead of calling Raise(). Like Raise() it cannot cross strata, so the
-- window still stays under the Blizzard panels.
--
-- Never pair this (or any strata) with SetToplevel(true): a toplevel frame re-raises
-- on every click/drag, which is that same restack once per grab. See the DRAGFREEZE
-- notes in this file and management/docs/DRAG-FREEZE.md.
PasslootBiS.WINDOW_STRATA = "MEDIUM"
PasslootBiS.WINDOW_LEVEL = 100

function PasslootBiS:ApplyWindowChrome(frame)
	if not frame or type(frame.SetFrameStrata) ~= "function" then return frame end
	frame:SetFrameStrata(self.WINDOW_STRATA)
	if type(frame.SetFrameLevel) == "function" then
		frame:SetFrameLevel(self.WINDOW_LEVEL)
	end
	return frame
end

-- House window chrome: the flat dark "Details-style" backdrop -- the tooltip
-- background tiled behind a 1px WHITE8X8 border, tinted near-black -- replacing the
-- ornate gold UI-DialogBox parchment. Defined here because Core/PassLoot.lua loads
-- first (see Core/Core.xml), so LootWindow.lua and RollAdvisor.lua can both use it
-- and one edit re-themes every hand-rolled window in the addon.
--
-- Deliberately NOT applied to the frames embedded in the Blizzard Interface Options
-- panel (MainGUI.lua): those sit inside shared Blizzard chrome, where a dark box on
-- the stock parchment reads as a seam rather than as a theme.
--
-- Cosmetic only. This is unrelated to the drag-freeze fixes elsewhere in this file:
-- the backdrop was explicitly exonerated as a cause (an EMPTY frame with no backdrop
-- still froze; the strata + SetToplevel pairing is what mattered).
PasslootBiS.DARK_BACKDROP = {
	["bgFile"] = "Interface\\Tooltips\\UI-Tooltip-Background",
	["edgeFile"] = "Interface\\Buttons\\WHITE8X8",
	["tile"] = true,
	["tileSize"] = 64,
	["edgeSize"] = 1,
	["insets"] = { ["left"] = 1, ["right"] = 1, ["top"] = 1, ["bottom"] = 1 },
}

function PasslootBiS:ApplyDarkBackdrop(frame)
	if not frame or type(frame.SetBackdrop) ~= "function" then return frame end
	frame:SetBackdrop(self.DARK_BACKDROP)
	if type(frame.SetBackdropColor) == "function" then
		frame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)        -- dark, mostly opaque
	end
	if type(frame.SetBackdropBorderColor) == "function" then
		frame:SetBackdropBorderColor(0.30, 0.30, 0.34, 1)     -- thin muted border
	end
	return frame
end

function PasslootBiS:CreateBiSManagerWindow()
	if self.BiSManagerWindowFrame then return self.BiSManagerWindowFrame end

	local f = CreateFrame("Frame", "PasslootBiS_BiSManagerWindow", UIParent)
	f:SetWidth(MGR_WIN_WIDTH)
	f:SetHeight(460)
	-- FULLSCREEN_DIALOG already sits ABOVE the DIALOG-strata Interface Options
	-- window (§8.6) by strata alone, so no SetToplevel is needed to render in
	-- front. We deliberately do NOT call SetToplevel(true) here: it would auto-
	-- raise the frame on every click/drag, and on Ascension 3.3.5 each raise
	-- restacks the strata (~50ms) — a repeatable micro-spike on every drag. This
	-- is a singleton window that never needs click-to-raise, so dropping it is
	-- the DRAGFREEZE note's "0 spikes" cure. (The one-time f:Raise() on open in
	-- ToggleBiSManagerWindow still guarantees front-of-strata when it's shown.)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	self:ApplyDarkBackdrop(f)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(frame)
		PasslootBiS.BiSManagerDragging = true
		GameTooltip:Hide()                          -- drop any hover tooltip for the move
		frame:StartMoving()
	end)
	f:SetScript("OnDragStop", function(frame)
		frame:StopMovingOrSizing()
		PasslootBiS.BiSManagerDragging = false
		local point, _, relPoint, x, y = frame:GetPoint()
		local w = PasslootBiS.db.profile.BiSManagerWindow
		w.point, w.relPoint, w.x, w.y = point, relPoint, x, y
	end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", f, "TOP", 0, -16)
	f.title = title

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
	close:SetScript("OnClick", function() PasslootBiS:ToggleBiSManagerWindow(false) end)

	-- Sort-mode buttons.
	local sortLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sortLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -42)
	sortLabel:SetText(L["BiSManager_SortBy"])
	local labels = {
		["source"] = L["BiSManager_SortSource"],
		["slot"] = L["BiSManager_SortSlot"],
		["score"] = L["BiSManager_SortScore"],
	}
	f.sortButtons = {}
	local prev
	for _, mode in ipairs(MGR_SORTS) do
		local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		b:SetHeight(20)
		b:SetWidth(70)
		if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
		else b:SetPoint("LEFT", sortLabel, "RIGHT", 8, 0) end
		b:SetText(labels[mode])
		b:SetScript("OnClick", function()
			PasslootBiS.db.profile.BiSManagerWindow.sort = mode
			PasslootBiS:BiSManagerWindow_Render()
		end)
		f.sortButtons[mode] = b
		prev = b
	end

	-- Scrollable item list.
	local scroll = CreateFrame("ScrollFrame", "PasslootBiS_BiSManagerScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -70)
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 72)
	local content = CreateFrame("Frame", "PasslootBiS_BiSManagerContent", scroll)
	content:SetWidth(MGR_CONTENT_WIDTH)
	content:SetHeight(1)
	scroll:SetScrollChild(content)
	f.scroll = scroll
	f.content = content
	f.rows = {}

	-- Apply / Reset / status.
	local apply = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	apply:SetHeight(22)
	apply:SetWidth(120)
	apply:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 16)
	apply:SetText(L["BiSManager_Apply"])
	apply:SetScript("OnClick", function() PasslootBiS:ApplyBiSManager() end)

	local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	reset:SetHeight(22)
	reset:SetWidth(100)
	reset:SetPoint("LEFT", apply, "RIGHT", 6, 0)
	reset:SetText(L["BiSManager_Reset"])
	reset:SetScript("OnClick", function()
		local sel = PasslootBiS.BiSManagerSelected
		PasslootBiS.BiSManagerStaging = PasslootBiS.BiSManagerStaging or {}
		PasslootBiS.BiSManagerStaging[sel] = {}
		PasslootBiS:BiSManagerWindow_Render()
	end)

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 44)
	status:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 44)
	status:SetJustifyH("LEFT")
	f.status = status

	self.BiSManagerWindowFrame = f

	-- Restore saved position (or centre).
	local w = self.db.profile.BiSManagerWindow
	f:ClearAllPoints()
	if w.point then
		f:SetPoint(w.point, UIParent, w.relPoint or w.point, w.x or 0, w.y or 0)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	f:Hide()
	return f
end

-- Redraw the window for the currently-selected list + sort mode.
function PasslootBiS:BiSManagerWindow_Render()
	local f = self.BiSManagerWindowFrame
	if not f then return end

	-- Keep the selection valid (mirrors the options page).
	local lists = self:EnumerateBiSLists()
	local sel = self.BiSManagerSelected
	local ok = false
	for _, n in ipairs(lists) do if n == sel then ok = true; break end end
	if not ok then sel = lists[1]; self.BiSManagerSelected = sel end

	f.title:SetText(sel and string.format(L["BiSManager_WindowTitle"], tostring(sel))
		or L["BiS Manager"])
	f.status:SetText(self.BiSManagerStatus or "")

	local mode = self.db.profile.BiSManagerWindow.sort or "source"
	if mode ~= "source" and mode ~= "slot" and mode ~= "score" then mode = "source" end
	for m, b in pairs(f.sortButtons) do
		if m == mode then b:LockHighlight() else b:UnlockHighlight() end
	end

	local items = sel and self:CollectBiSListItems(sel) or {}
	local entries = mgrBuildDisplayList(items, mode)
	if #entries == 0 then
		entries = { { header = true, text = L["BiSManager_WindowEmpty"], gray = true } }
	end

	local y = 0
	for i, entry in ipairs(entries) do
		local row = mgrAcquireRow(f, i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -y)
		row.label:ClearAllPoints()
		row:Show()
		if entry.header then
			row.item = nil
			row.base = nil
			row.check:Hide()
			row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
			row.label:SetPoint("RIGHT", row, "RIGHT", -2, 0)
			local col = entry.gray and "|cff999999" or "|cffffd100"
			local text = col .. tostring(entry.text) .. "|r"
			if entry.count then text = text .. "  |cff808080(" .. entry.count .. ")|r" end
			if entry.showTag then
				text = text .. (entry.roll
					and "  |cff40c040" .. L["BiSManager_RollTag"] .. "|r"
					or  "  |cff808080" .. L["BiSManager_InfoTag"] .. "|r")
			end
			row.label:SetText(text)
		else
			local it = entry.it
			row.item = it
			row.base = sel
			row.check:Show()
			row.check:SetChecked(self:BiSManagerRolls(sel, it.kind, it.key, it.rolls) and true or false)
			row.label:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
			row.label:SetPoint("RIGHT", row, "RIGHT", -2, 0)
			row.label:SetText(mgrRowLabel(it, mode))
		end
		y = y + MGR_ROW_HEIGHT
	end

	-- Hide leftover pooled rows from a previous, longer render.
	for i = #entries + 1, #f.rows do f.rows[i]:Hide() end

	f.content:SetHeight(y > 0 and y or 1)
	f.content:SetWidth(MGR_CONTENT_WIDTH)
end

-- show: true/false, or nil to toggle.
function PasslootBiS:ToggleBiSManagerWindow(show)
	local f = self:CreateBiSManagerWindow()
	if show == nil then show = not f:IsShown() end
	if show then
		self:BiSManagerWindow_Render()
		f:Show()
		f:Raise()
	else
		f:Hide()
		GameTooltip:Hide()
	end
	self.db.profile.BiSManagerWindow.shown = show and true or false
end


-- Set the in-panel import result line (see BuildImportOptions "status") and
-- refresh the panel so it shows immediately. Green for success, red for errors.
function PasslootBiS:SetImportStatus(text, isError)
	if text and text ~= "" then
		self.BiSImportStatus = (isError and "|cffff5555" or "|cff55ff55") .. text .. "|r"
	else
		self.BiSImportStatus = ""
	end
	local reg = LibStub("AceConfigRegistry-3.0", true)
	if reg then reg:NotifyChange(L["PasslootBiS"]) end
end

-- Run the import: hand the pasted string to BiSImport, write the two match rules
-- as a named BiS list (a NEW list by default, or overwriting one the user chose),
-- stash that list's per-item `mgr` metadata for the BiS Manager page, and refresh
-- both the rule list and the manager. Feedback goes to the in-panel status line
-- (a Pour message renders behind the Blizzard options window on this client).
function PasslootBiS:DoBiSImport()
	local BiS = self.BiSImport
	if not BiS then
		self:SetImportStatus(L["ImportBiS_NotLoaded"], true)
		return
	end
	local text = self.BiSImportBuffer or ""
	if text:gsub("%s", "") == "" then
		self:SetImportStatus(L["ImportBiS_Empty"], true)
		return
	end
	local parsed, perr = BiS.Parse(text)
	if not parsed then
		self:SetImportStatus(L["ImportBiS_Failed"] .. " " .. tostring(perr), true)
		return
	end

	local rules = self.db.profile.Rules

	-- Resolve the target list name. "\1new" (the default) mints a fresh,
	-- non-colliding name from the string's own desc; otherwise the user picked an
	-- existing list to overwrite (falling back to a new list if it was removed).
	local target = self.BiSImportTarget or "\1new"
	local base
	if target ~= "\1new" and self:BiSListExists(target) then
		base = target
	else
		base = self:UniqueBiSListName(parsed.desc)
	end
	parsed.desc = base

	-- Clean overwrite is ApplyToRules' job now: it rebuilds a rule this list already
	-- owns in place (keeping its priority and its Before Advisor tick) and drops the
	-- one a re-import with, say, no name items no longer needs. A brand-new unique
	-- name owns nothing, so its rules are new and land at the top of the list.
	--
	-- Build the initial roll rules. When the string carries `mgr` metadata we roll
	-- only on items from roll-window sources (dungeon / raid / forged) — the rest
	-- stay on the list as data (visible + toggleable in the BiS Manager) but off the
	-- rules, so the roll list isn't cluttered with items you can't get a roll frame
	-- for. Without mgr metadata (a lean string) we can't tell sources apart, so we
	-- fall back to rolling on everything (the old behaviour).
	local rollSet
	if type(parsed.manage) == "table" and #parsed.manage > 0 then
		rollSet = BiS.SelectRollItems(parsed.manage, ROLL_SOURCE_CATEGORIES)
	else
		rollSet = { ids = parsed.ids, names = parsed.names }
	end
	local ok = BiS.ApplyToRules(
		{ ids = rollSet.ids, names = rollSet.names, roll = parsed.roll, desc = base },
		"replace", rules)
	self:PartitionRules(rules) -- keep the two rule-list sections truthful
	if ok then
		-- Stash this list's per-item manager metadata (ALL items — source + match
		-- key) for the BiS Manager page. nil when the string carried no `mgr` block
		-- (the manager then falls back to the rule entries for this list).
		self.db.profile.BiSManage = self.db.profile.BiSManage or {}
		self.db.profile.BiSManage[base] = parsed.manage or nil

		local total = (type(parsed.manage) == "table" and #parsed.manage)
			or (#parsed.ids + #parsed.names)
		local rolled = #rollSet.ids + #rollSet.names
		self:SetImportStatus(string.format(L["ImportBiS_Done"], base, rolled, total), false)

		-- Show the just-imported list in the manager, with a clean tick selection.
		self.BiSManagerSelected = base
		self.BiSManagerStaging = self.BiSManagerStaging or {}
		self.BiSManagerStaging[base] = {}
		self:RefreshBiSManager()

		-- Drop the rule-list selection, then redraw it: an import inserts its rules at
		-- the top, so every index below them has moved and a highlight left where it
		-- was would point at the wrong rule.
		self.CurrentRule = 0
		if self.RulesFrame and self.Rules_RuleList_OnScroll then
			self:Rules_RuleList_OnScroll()
			self:DisplayCurrentRule()   -- clears the filter/description half for "no rule"
		end
	else
		self:SetImportStatus(L["ImportBiS_Failed"], true)
	end
end

local BUCKET_BAG_UPDATE, BUCKET_PLAYER_LEVEL_UP
function PasslootBiS:OnEnable()
	-- events that may fire multiple times in quick succession and require a cache update, but don't require information from the event
	BUCKET_BAG_UPDATE = self:RegisterBucketEvent("BAG_UPDATE", 1, "UpdateBags")
	BUCKET_PLAYER_LEVEL_UP = self:RegisterBucketEvent("PLAYER_LEVEL_UP", 1, "ClearItemCache")
	-- events that only fire occassionally
	self:RegisterEvent("START_LOOT_ROLL")
	-- Always registered; the handler no-ops unless the profile toggle is on, so
	-- flipping the option takes effect immediately with no re-registration dance.
	self:RegisterEvent("LOOT_BIND_CONFIRM")
	-- Same shape: always registered, gated inside the handler on its own toggle.
	self:RegisterEvent("CONFIRM_LOOT_ROLL")
	self:RegisterEvent("ASCENSION_STORE_COLLECTION_ITEM_LEARNED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
	-- End-of-run watch for BiS Check's cleanup suggestion (Core/BiSCleanup.lua).
	-- Two events for one question ("did the zone change?"), because neither fires on
	-- every route out of an instance; the handler de-duplicates on the zone name.
	-- PLAYER_ENTERING_WORLD is the OTHER half and is handled via OnEnteringWorld --
	-- AceEvent keeps ONE handler per event per object, so registering it a second
	-- time here would silently REPLACE the item-cache reset rather than add to it.
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "BiSCleanup_ZoneCheck")
	-- events that require the event details and also fire with BAG_UPDATE
	C_Hook:Register(self, "BAG_ITEM_REMOVED, BAG_ITEM_COUNT_CHANGED")

	self:SetupModulesOptionsTables() -- Creates Module header frames and lays them out in the scroll frame
	self:OnProfileChanged()
	self.LastRolls = {}           -- Last 10 rolls.
	-- Reopen the Loot Window if it was open last session (Core/LootWindow.lua).
	if (self.db.profile.LootWindow and self.db.profile.LootWindow.shown) then
		self:ToggleLootWindow(true)
	end
	-- Rules/DB are ready now: flip PasslootBiS.API.ready and flush any queued
	-- OnReady callbacks so roll advisors (Core/RollAdvisor.lua) can register.
	if self.API and self.API.FireReady then
		self.API:FireReady()
	end
end

function PasslootBiS:OnDisable()
	-- events that may fire multiple times in quick succession and require a cache update, but don't require information from the event
	self:UnregisterBucket(BUCKET_BAG_UPDATE)
	self:UnregisterBucket(BUCKET_PLAYER_LEVEL_UP)
	-- events that only fire occassionally
	self:UnregisterEvent("START_LOOT_ROLL")
	self:UnregisterEvent("LOOT_BIND_CONFIRM")
	self:UnregisterEvent("CONFIRM_LOOT_ROLL")
	self:UnregisterEvent("ASCENSION_STORE_COLLECTION_ITEM_LEARNED")
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	self:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
	-- events that require the event details and also fire a BAG_UPDATE
	C_Hook:Unregister(self, "BAG_ITEM_REMOVED, BAG_ITEM_COUNT_CHANGED")
	self:UnregisterEvent("START_LOOT_ROLL")
end

function PasslootBiS:OnProfileChanged()
	-- this is called every time your profile changes (after the change)
	self:SetExclusiveConfirmPopupBit()
	self.CurrentRule = 0
	self.CurrentRuleUnknownVars = {}
	self.CurrentOptionFilter = { nil, 0 } -- Frame, line #
	self:LoadModules()
	self:SendMessage("PasslootBiS_OnProfileChanged")
	-- A profile that has never held a rule gets the starter pair (Not Usable >
	-- Greed, Catch All > Greed). Must run BEFORE CheckRuleTables so the seeded
	-- rules go through the same DefaultTemplate fill-in as any other rule.
	self:SeedDefaultRules()
	-- Now we check our rules to see if all variables are set.
	-- We could check profile variables, but some modules need more than just setting defaults, they need to act on them.
	self:CheckRuleTables()
	self:PartitionRules() -- Before Advisor rules to the front; see the function's note
	self:Rules_RuleList_OnScroll()
	self:DisplayCurrentRule()
	self:ResetCache()
	-- self:OnProfileNewOrDelete()
end

-- function PasslootBiS:OnProfileNewOrDelete()
-- end

function PasslootBiS:LoadModules()
	local Module
	for ModuleKey, ModuleValue in self:IterateModules() do
		Module = ModuleValue:GetName()
		self.db.profile.Modules[Module] = self.db.profile.Modules[Module] or {}
		if (self.db.profile.Modules[Module].Status == nil) then
			self.db.profile.Modules[Module].Status = true
		end
		if (self.db.profile.Modules[Module].Status ~= ModuleValue.enabledState) then
			if (self.db.profile.Modules[Module].Status) then
				ModuleValue:Enable()
			else
				ModuleValue:Disable()
			end
		end
	end
end

local CanRoll = {
	["need"] = nil,
	["greed"] = nil,
	["de"] = nil,
	["pass"] = true,
}

local RollMethodLookup = {
	[1] = L["Need"],
	[2] = L["Greed"],
	[3] = L["Disenchant"],
	[0] = L["Pass"],
}

-- Reverse of PasslootBiS.RollMethod: the numeric RollOnLoot code -> roll key, used
-- to hand the roll advisor PassLoot's own decision (ctx.passlootDecision).
local RollMethodKey = {
	[1] = "need",
	[2] = "greed",
	[3] = "de",
	[0] = "pass",
}

local QueueOperations = {
	["reset"] = false,
	["IDs"] = {}, -- set of IDs to invalidate matching caches
}

-- Bucket Event to handle updating the item cache
function PasslootBiS:UpdateBags(...)
	local currentTime = GetTime()
	-- if we are resetting the cache, only do that since any updates or single item deletes will be useless
	if QueueOperations["reset"] then
		PasslootBiS:ResetCache()
		-- forget items based on item id
	elseif type(next(QueueOperations["IDs"])) ~= "nil" then
		for k, v in pairs(PasslootBiS.EvalCache) do
			if QueueOperations["IDs"][v["itemObj"].id] then
				PasslootBiS.EvalCache[k] = nil
			end
		end
	end
	-- TODO: forget any expired cache items
	-- we processed the update, reset the queue
	QueueOperations = { ["reset"] = false, ["IDs"] = {} }
	-- remove any cache that expired
	for k, v in pairs(PasslootBiS.EvalCache) do
		if PasslootBiS.EvalCache[k]["expiresAt"] < currentTime then
			PasslootBiS.EvalCache[k] = nil
		end
	end
end

function PasslootBiS:ClearItemCache(...)
	QueueOperations["reset"] = true
end

-- The single PLAYER_ENTERING_WORLD handler. Two unrelated things want that event
-- and AceEvent stores exactly ONE handler per event per object, so a second
-- RegisterEvent for it replaces the first instead of adding to it. Anything else
-- that comes to need this event belongs in here, not in another RegisterEvent.
function PasslootBiS:OnEnteringWorld(...)
	self:ClearItemCache(...)
	self:BiSCleanup_ZoneCheck()
end

function PasslootBiS:ASCENSION_STORE_COLLECTION_ITEM_LEARNED(Event, ID, ...)
	QueueOperations["IDs"][ID] = true
end

function PasslootBiS:BAG_ITEM_REMOVED(Bag, Slot, ID, StackCount, ...)
	QueueOperations["IDs"][ID] = true
end

function PasslootBiS:BAG_ITEM_COUNT_CHANGED(Bag, Slot, ID, NewStackNum, Change, ...)
	QueueOperations["IDs"][ID] = true
	--	QueueOperations["BagSlots_Count"][Bag][Slot] = NewStackNum
end

function PasslootBiS:AddLastRoll(RollMethod, itemObj, RuleID)
	-- Add to LastRolls
	local TextLine, Method
	if (RollMethod) then
		Method = RollMethodLookup[RollMethod]
	else
		Method = L["Ignored"]
	end
	TextLine = string.format("|T%s:0|t %s - %s -> %s", itemObj.texture, itemObj.link, Method,
		PasslootBiS.db.profile.Rules[RuleID].Desc)
	if (#self.LastRolls == 10) then
		table.remove(self.LastRolls, 1)
	end
	table.insert(self.LastRolls, TextLine)
end

-- Confirm one loot roll's bind warning exactly once, whoever asks.
--
-- TWO independent things answer CONFIRM_LOOT_ROLL now: the profile-wide
-- AutoConfirmBindOnRoll below, and the older per-rule "Confirm BoP" filter
-- (Modules/ConfirmBoP.lua) for anyone who set one up. Both fire for the same roll
-- when a ticked rule matches, so the confirm is funnelled through here and the
-- second caller becomes a no-op. Returns true if THIS call is the one that
-- confirmed.
--
-- The popup is hidden twice, immediately and on the next tick, for the same reason
-- the pickup path does it: the client's own GroupLootFrame listens for this event
-- too and the dispatch order between its handler and ours is undefined, so a popup
-- raised after our first hide needs a second one to catch it.
local confirmedRolls = {}
function PasslootBiS:ConfirmRollOnce(RollID, RollMethod)
	if (not RollID or confirmedRolls[RollID]) then
		return false
	end
	confirmedRolls[RollID] = true
	self:Debug("ConfirmLootRoll(" .. tostring(RollID) .. ", " .. tostring(RollMethod) .. ")")
	ConfirmLootRoll(RollID, RollMethod)
	StaticPopup_Hide("CONFIRM_LOOT_ROLL", RollID)
	self:ScheduleTimer(function()
		StaticPopup_Hide("CONFIRM_LOOT_ROLL", RollID)
		-- The guard is per-roll and rollIDs are reused across a session, so it has to
		-- be released or the second roll to reuse an id would never be confirmed.
		-- Released here rather than on a fixed sweep: by now the confirm has either
		-- landed or it never will.
		confirmedRolls[RollID] = nil
	end, 0.05)
	return true
end

-- Bind-on-ROLL auto-confirm: CONFIRM_LOOT_ROLL -> ConfirmLootRoll(id, rollType).
--
-- This is the popup you get for rolling Need or Greed on a bind-on-pickup item --
-- the one that stops a boss drop mid-auto-roll and waits for a click. Distinct
-- from the pickup warning handled below, which is about taking an item out of a
-- loot window rather than rolling for one.
--
-- Why this is profile-wide and not another per-rule filter. The addon HAS a
-- per-rule filter for it (Modules/ConfirmBoP.lua's "Confirm BoP") and it works --
-- but it only fires when the rule that matched has it ticked, and none of the
-- rules a normal setup actually rolls with do. The two seeded starter rules
-- ("Not Usable > Greed", "Catch All > Greed", Core/Constants.lua DefaultRules)
-- carry no filters beyond their match condition, and neither do BiS-imported
-- rules. So on live boss loot -- which is BoP, which is why this looks like an
-- "epic items" problem -- the rule matched, the roll was cast, and then the
-- confirm sat there unanswered because the matched rule had no Confirm BoP tick.
-- A setting nobody's rules opt into is a setting that does not work.
--
-- Disenchant (rollType 3) is deliberately NOT auto-confirmed here. Rolling DE on
-- someone else's upgrade is the one roll in this addon that can genuinely annoy a
-- group, which is why Modules/ConfirmDE.lua makes you confirm the FILTER before it
-- will auto-confirm the roll. That opt-in stands; this must not quietly undo it.
function PasslootBiS:CONFIRM_LOOT_ROLL(Event, RollID, RollMethod)
	if (not self.db.profile.AutoConfirmBindOnRoll) then
		return
	end
	if (type(RollID) ~= "number" or RollMethod == self.RollMethod.de) then
		return
	end
	-- Only rolls the addon itself cast (see CastRolls). The event fires for a roll
	-- you clicked by hand too, and answering that one for you would remove a prompt
	-- the client puts on a deliberate action -- a different feature from the one
	-- being asked for here, and not one anybody opted into.
	local cast = self.CastRolls[RollID]
	if (not cast or cast ~= GetLootRollItemLink(RollID)) then
		self:Debug("CONFIRM_LOOT_ROLL " .. RollID .. ": not our roll, leaving the popup")
		return
	end
	self.CastRolls[RollID] = nil
	self:Debug("CONFIRM_LOOT_ROLL: auto-confirming roll " .. RollID)
	self:ConfirmRollOnce(RollID, RollMethod)
end

-- Bind-on-pickup auto-confirm: LOOT_BIND_CONFIRM -> ConfirmLootSlot(slot).
--
-- This is the OTHER BoP prompt, and it is not the one the ConfirmBoP/ConfirmDE
-- modules answer. Those two answer the *roll* confirmation (CONFIRM_LOOT_ROLL /
-- CONFIRM_DISENCHANT_ROLL) and are per-rule filters, because a roll has a RollID
-- and a matched rule behind it. This one fires when you take a BoP item straight
-- out of a loot window -- a master-loot award, personal loot, or whatever is left
-- in the corpse once the rolls are done. It carries only a loot slot: no RollID,
-- no rule, nothing to hang a per-rule filter off. So it is a single profile-wide
-- toggle (Options > Auto-Confirm Bind on Pickup), OFF by default, because saying
-- yes binds the item for good and that is the user's call to make, not ours.
--
-- Why this is more than a convenience. The client has a small fixed pool of
-- StaticPopup frames, and CONFIRM_LOOT_ROLL ships with the `exclusive` bit set
-- (SetExclusiveConfirmPopupBit above, and the "Allow Multiple Confirm Popups"
-- option that clears it), so only one of them shows at a time. A boss that drops
-- several BoP items at once leaves a stack of unanswered LOOT_BIND popups sitting
-- in that pool -- exactly the thing that can crowd out the roll-confirm popup our
-- own BoP rolls have to go through. Answering these as they arrive keeps the
-- queue empty and the roll path clear.
--
-- Dispatch order: the client's own LootFrame listens for this same event and
-- raises the popup itself, and whether its handler runs before or after ours is
-- undefined. So we hide the dialog twice -- once now (it went first) and once on
-- the next tick (it went second, and the popup appeared after our first hide).
-- Both hides are keyed to this slot, which is what the client stores as the
-- dialog's `data`, so a popup for some other slot is never touched.
function PasslootBiS:LOOT_BIND_CONFIRM(Event, Slot)
	if (not self.db.profile.AutoConfirmBindOnPickup) then
		return
	end
	if (type(Slot) ~= "number") then
		return
	end
	self:Debug("LOOT_BIND_CONFIRM: auto-confirming loot slot " .. Slot)
	ConfirmLootSlot(Slot)
	StaticPopup_Hide("LOOT_BIND", Slot)
	self:ScheduleTimer(function()
		StaticPopup_Hide("LOOT_BIND", Slot)
	end, 0.05)
end

-- Texture, Name, Count, Quality, BindOnPickup, CanNeed, CanGreed, CanDisenchant = GetLootRollItemInfo(rollID)
-- RollOnLoot(RollID, #)  0 = pass, 1 = need, 2 = greed, 3 = de
function PasslootBiS:START_LOOT_ROLL(Event, RollID, rollTime, ...)
	local ItemLink
	if (self.TestLink) then
		RollID = -1
		ItemLink = self.TestLink.link
	else
		ItemLink = GetLootRollItemLink(RollID)
	end
	if (not ItemLink) then
		self:Print("A roll for an item started, but could not get an item link!")
		return
	end
	-- Evaluate on attempt 1. ProcessLootRoll re-schedules itself if the client has
	-- not cached the item's info yet (first-see); see Core/RollRetry.lua.
	self:ProcessLootRoll(RollID, rollTime, ItemLink, 1)
end

-- Evaluate a single loot roll and act on it (advisor gate + queue the roll). Split
-- out of START_LOOT_ROLL so it can RETRY: on 3.3.5, GetItemInfo() returns nil until
-- the client has cached a first-see item, which makes ValidateItemObj (Core/Cache.lua)
-- skip rule evaluation ENTIRELY and the roll silently fall through with no auto-roll
-- (Core/RollRetry.lua has the full why). We re-build the item and re-check a handful
-- of times over ~1s; the info populates async right after the first query. `attempt`
-- is 1-based. There is no double-roll risk: the retry chain is linear and only its
-- one terminal path reaches QueueRoll.
function PasslootBiS:ProcessLootRoll(RollID, rollTime, ItemLink, attempt)
	-- Refresh roll eligibility for THIS roll on every attempt: CanRoll is a shared
	-- table another roll's START_LOOT_ROLL could clobber, and on Ascension the
	-- Need/Greed flags can populate a beat after the roll starts (RollAdvisor field
	-- finding). The test path seeds them from its own stubs instead.
	if (self.TestLink) then
		CanRoll.need, CanRoll.greed, CanRoll.de = self.TestCanNeed, self.TestCanGreed, self.TestCanDisenchant
	else
		_, _, _, _, _, CanRoll.need, CanRoll.greed, CanRoll.de = GetLootRollItemInfo(RollID)
	end

	-- Build the item. Reuse the eval cache ONLY when it holds a GetItemInfo-resolved
	-- item; a first-see attempt caches an itemObj whose stats aren't in yet (only the
	-- link-derived id/name), and reusing it would defeat the retry — so fall back to a
	-- fresh InitItem, which re-queries GetItemInfo (which may have cached since the last
	-- attempt).
	local itemObj
	local cached = PasslootBiS.EvalCache and PasslootBiS.EvalCache[ItemLink]
	if cached and cached.itemObj and cached.itemObj.infoResolved then
		itemObj = cached.itemObj
	else
		itemObj = PasslootBiS:InitItem(ItemLink)
	end

	-- First-see retry gate (real rolls only; the test path is synchronous, no timer).
	-- Wait on GetItemInfo specifically (itemObj.infoResolved): id + name already come
	-- from the link and match regardless, but the stat-based rules need GetItemInfo. If
	-- it hasn't populated and attempts remain, schedule the next attempt and bail;
	-- otherwise fall through and evaluate now (worst case: the id/name rules still match).
	if (not self.TestLink and RollID and RollID > -1 and self.RollRetry) then
		local resolved = (itemObj and itemObj.infoResolved) and true or false
		if (self.RollRetry.ShouldRetry(resolved, attempt, self.RollRetry.MAX_ATTEMPTS)) then
			self:ScheduleTimer(function()
				-- Skip if the roll is already gone (user rolled, or it expired): the
				-- link goes nil, so we neither re-evaluate nor roll after the fact.
				if (GetLootRollItemLink(RollID)) then
					self:ProcessLootRoll(RollID, rollTime, ItemLink, attempt + 1)
				end
			end, self.RollRetry.DELAY)
			return
		end
	end

	local RollMethod, RuleID = PasslootBiS:GetItemEvaluation(itemObj, RollID)
	if RollMethod ~= nil then
		PasslootBiS:AddLastRoll(RollMethod, itemObj, RuleID)
	end
	if not self.TestLink and RollID > -1 then
		-- Roll-advisor held-confirm gate (docs/integration-api.md §3.6 / BiS-Scanner
		-- integration.md §5.2a). Consult any registered advisor for a verdict; under
		-- the user's trust mode it may hold this roll behind a bounded countdown popup
		-- or auto-cast, casting exactly ONE RollOnLoot via QueueRoll. The whole gate is
		-- pcall-wrapped so a buggy advisor can never break the roll: on abstain / error
		-- / advisory mode we queue the rule-computed RollMethod exactly as before.
		-- isBiS/bisList are the host's half of BiS Check: the BiS list lives HERE, in
		-- the rules, and an advisor has no way to see it. The scanner reads these off
		-- ctx to decide whether a low score is worth warning about at all (a lesser
		-- item that was never on your list is just loot, not a mistake).
		local IsBiS, BiSList = self:IsBiSItem(itemObj and itemObj.id, itemObj and itemObj.name)
		local ctx = {
			itemLink = ItemLink,
			itemName = itemObj and itemObj.name or nil,
			rollID   = RollID,
			slot     = itemObj and itemObj.equipSlot or nil,
			canNeed  = CanRoll.need and true or false,
			canGreed = CanRoll.greed and true or false,
			canDe    = CanRoll.de and true or false,
			isBiS    = IsBiS,
			bisList  = BiSList,
			passlootDecision = RollMethod and RollMethodKey[RollMethod] or nil,
		}
		-- "Before Advisor" (the rightmost checkbox on the rule list): a rule ticked
		-- there OUTRANKS the advisor. When such a rule matched AND produced a roll
		-- method, roll it straight away and never consult the gate -- no popup, no
		-- advisor auto-cast to argue with. A rule that matched but rolls nothing
		-- (empty Loot, or nothing it wanted was allowed on this roll) has no decision
		-- to defend, so the advisor still gets its turn.
		local Rule = RuleID and self.db.profile.Rules[RuleID]
		local BeforeAdvisor = (Rule and Rule.BeforeAdvisor and RollMethod ~= nil) and true or false
		local handled = false
		-- The gate is now consulted even for a Before Advisor rule, and told about the
		-- tick rather than being skipped for it. BiS Check (Core/RollAdvisor.lua) has
		-- to outrank Before Advisor, and it cannot outrank a gate it never reaches --
		-- the stale-BiS rolls it exists to stop come from BiS-imported rules, which
		-- ship with Before Advisor already ticked. HandleRoll honours the tick itself,
		-- immediately below its veto, so every other rule keeps beating the advisor
		-- exactly as before.
		if self.API then
			local ok, res = pcall(self.HandleRoll, self, RollID, rollTime, itemObj, RollMethod, ctx,
				BeforeAdvisor)
			handled = ok and res
		end
		if not handled and RollMethod and RollMethod ~= nil then
			self:QueueRoll(RollID, RollMethod)
		end
	end
end

function PasslootBiS:EvaluateItem(itemObj, RollID)
	if not itemObj or not itemObj.link then return end
	local Name = itemObj.name
	PasslootBiSTT:ClearLines()
	PasslootBiSTT:SetHyperlink(itemObj.link)
	for WidgetKey, WidgetValue in ipairs(self.RuleWidgets) do
		WidgetValue:SetMatch(itemObj, PasslootBiSTT, RollID or -1)
	end
	local MatchedRule, NumFilters
	local IsMatch, IsException, NormalMatch, ExceptionMatch, HadNoNormal
	local NormalMatchText, ExceptionMatchText = "", ""
	for RuleKey, RuleValue in ipairs(self.db.profile.Rules) do
		self:Debug("Checking rule " .. RuleKey .. " " .. RuleValue.Desc)
		if (RuleValue.Disabled) then
			-- User turned this rule off via the minimap button's left-click menu
			-- (Core/MinimapButton.lua). Skip it entirely; no roll evaluation.
			self:Debug("Rule " .. RuleKey .. " is disabled by the user; skipping.")
		elseif (self.db.profile.SkipRules and self.SkipRules[RuleKey]) then
			if (self.db.profile.SkipWarning) then
				self:Pour("|cff33ff99" ..
					L["PasslootBiS"] .. "|r: " .. string.gsub(L["Skipping %rule%"], "%%rule%%", RuleValue.Desc))
			end
		else
			MatchedRule = true
			for WidgetKey, WidgetValue in ipairs(self.RuleWidgets) do
				NumFilters = WidgetValue:GetNumFilters(RuleKey) or 0
				if (NumFilters > 0) then
					NormalMatchText, ExceptionMatchText = "", ""
					self:Debug("Checking filter " .. WidgetValue.Info[1] .. " (" .. NumFilters .. " NumFilters)")
					-- I can not simply OR normal ones and AND NOT the exception ones.. example: for a 1hd mace
					-- Filter1: OR Armor
					-- Filter2: AND NOT 1hd mace
					-- Filter3: OR Weapon
					-- Will evaluate true, when it should have evaluated false.
					-- It should have been (Armor OR Weapon) AND NOT (1hd mace)
					NormalMatch = false
					ExceptionMatch = false
					HadNoNormal = true
					for Index = 1, NumFilters do
						IsMatch = WidgetValue:GetMatch(RuleKey, Index)
						if (IsMatch) then
							IsMatch = true
						else
							IsMatch = false
						end
						IsException = WidgetValue:IsException(RuleKey, Index)
						if (IsException) then
							ExceptionMatch = ExceptionMatch or IsMatch
							ExceptionMatchText = ExceptionMatchText .. Index .. "-" .. tostring(IsMatch) .. " OR "
							if (IsMatch) then -- don't have to go any further, one single true in the exception = a false in the entire filter.
								break
							end
						else
							NormalMatch = NormalMatch or IsMatch
							HadNoNormal = false
							NormalMatchText = NormalMatchText .. Index .. "-" .. tostring(IsMatch) .. " OR "
						end
					end -- Each Filter
					if ((NormalMatch or HadNoNormal) and not ExceptionMatch) then
						self:Debug("Filter matched: (" ..
							NormalMatchText .. tostring(HadNoNormal) .. ") AND NOT (" .. ExceptionMatchText .. " false)")
					else
						self:Debug("Filter did not match: (" ..
							NormalMatchText .. tostring(HadNoNormal) .. ") AND NOT (" .. ExceptionMatchText .. " false)")
						MatchedRule = false
						break
					end
				end -- NumFilters > 0
			end -- Each Widget

			if (MatchedRule) then
				self:Debug("Matched rule")
				local StatusMsg, RollMethod
				StatusMsg = self.db.profile.MessageText.ignore
				-- To make absolutely sure I roll according to RollOrder
				local WantToRoll = {}
				for LootKey, LootValue in pairs(RuleValue.Loot) do
					WantToRoll[LootValue] = true
				end
				for RollOrderKey, RollOrderValue in ipairs(self.RollOrder) do
					if (WantToRoll[RollOrderValue] and CanRoll[RollOrderValue]) then
						RollMethod = self.RollMethod[RollOrderValue]
						StatusMsg = self.db.profile.MessageText[RollOrderValue]
						break
					end
				end
				-- for LootKey, LootValue in ipairs(RuleValue.Loot) do
				-- if ( CanRoll[LootValue] ) then
				-- RollMethod = self.RollMethod[LootValue]
				-- StatusMsg = self.db.profile.MessageText[LootValue]
				-- break
				-- end
				-- end
				self:SendMessage("PasslootBiS_OnRoll", itemObj.link, RuleKey, RollID, RollMethod) -- Maybe change this to OnRuleMatched
				if (not self.TestLink) then
					if (RollMethod) then
						-- RollOnLoot(RollID, RollMethod)
						return RollMethod, RuleKey
					end
				end
				-- Send StatusMsg
				if (self.db.profile.Quiet == false) then
					-- Workaround for LibSink.  It can handle |c and |r color stuff, but not full ItemLinks
					local ItemText
					if (self.db.profile.SinkOptions.sink20OutputSink == "Channel") then
						ItemText = itemObj.name
					else
						ItemText = itemObj.link
					end
					StatusMsg = string.gsub(StatusMsg, "%%item%%", ItemText)
					StatusMsg = string.gsub(StatusMsg, "%%rule%%", RuleValue.Desc)
					self:Pour("|cff33ff99" .. L["PasslootBiS"] .. "|r: " .. StatusMsg)
				end
				--We found the item, and rolled on it, so go ahead and quit.
				self.TestLink, CanRoll.greed, CanRoll.need, CanRoll.de = nil, nil, nil, nil
				return
			end --MatchedRule
		end -- SkipRules
		self:Debug("Rule not matched, trying another")
	end --RuleKey, RuleValue
	self:Debug("Ran out of rules, ignoring")
	if (self.TestLink) then
		self:Pour(itemObj.link .. ": " .. L["No rules matched."])
	end
	self.TestLink, CanRoll.greed, CanRoll.need, CanRoll.de = nil, nil, nil, nil
end

function PasslootBiS:CleanRules()
	-- local DefaultVars = {}
	-- for DefaultKey, DefaultValue in pairs(self.DefaultTemplate) do
	-- DefaultVars[DefaultValue[1]] = true
	-- end
	for RuleKey, RuleValue in pairs(self.db.profile.Rules) do
		for VarKey, VarValue in pairs(RuleValue) do
			if (not self.DefaultVars[VarKey]) then
				self.db.profile.Rules[RuleKey][VarKey] = nil
			end
		end
	end
	self.SkipRules = {}
end

-- Hand a profile the starter rules (Constants.lua PasslootBiS.DefaultRules) the
-- first time we see it. Two guards, both deliberate:
--   * `DefaultRulesSeeded` is set even when we DON'T seed, so this runs exactly
--     once per profile. Delete the starter rules and they stay deleted.
--   * we only seed a profile with NO rules at all, so an existing install (or a
--     profile whose rules came from a BiS import) is never touched.
-- Called from OnProfileChanged before CheckRuleTables, which then fills in any
-- DefaultTemplate variable the seeded rules don't set. Resetting a profile from
-- the Profiles tab clears the flag with the rules, so Defaults re-seeds — which is
-- what "restore defaults" should do.
function PasslootBiS:SeedDefaultRules()
	local Profile = self.db.profile
	Profile.Rules = Profile.Rules or {}
	if (Profile.DefaultRulesSeeded) then
		return
	end
	Profile.DefaultRulesSeeded = true
	if (#Profile.Rules > 0) then
		return
	end
	for _, Rule in ipairs(self.DefaultRules or {}) do
		table.insert(Profile.Rules, self:CopyTable(Rule))
	end
end

-- Keep a rules array PARTITIONED: every rule ticked "Before Advisor" first, then
-- everything else. That partition is not cosmetic -- it is what makes the rule
-- list's two sections (Core/MainGUI.lua) the real roll order rather than a picture
-- of one. Rules are evaluated top-down and the first match wins, so a rule that
-- claims to be checked "before the advisor" has to actually sit above the rules
-- that aren't.
--
-- The sort is STABLE, which is what gives ticking and unticking their obvious
-- behaviour for free: a rule ticked at the bottom rises to the END of the Before
-- Advisor block (below the ones already there, which it was below), and unticking
-- one drops it to the HEAD of the block underneath (above the ones it was above).
--
-- `rules` defaults to the current profile's. Pass `TrackIndex` to follow one rule
-- across the move: its new index comes back, so a caller can keep the selection on
-- the rule the user was looking at instead of on whatever now holds that number.
function PasslootBiS:PartitionRules(rules, TrackIndex)
	rules = rules or self.db.profile.Rules
	if (type(rules) ~= "table") then
		return nil
	end
	local Tracked = TrackIndex and rules[TrackIndex]
	local Before, After = {}, {}
	for _, Rule in ipairs(rules) do
		if (Rule.BeforeAdvisor) then
			Before[#Before + 1] = Rule
		else
			After[#After + 1] = Rule
		end
	end
	for Index = 1, #Before do
		rules[Index] = Before[Index]
	end
	for Index = 1, #After do
		rules[#Before + Index] = After[Index]
	end
	if (Tracked) then
		for Index = 1, #rules do
			if (rules[Index] == Tracked) then
				return Index
			end
		end
	end
	return nil
end

-- We make sure each rule has a default value
-- Update the DefaultVars lookup table.
-- Based on DefaultVars, create a list of rules to skip  (A rule has a module variable set, but no module is loaded to check it)
function PasslootBiS:CheckRuleTables()
	for Key, Value in pairs(self.DefaultVars) do
		self.DefaultVars[Key] = nil
	end
	for DefaultKey, DefaultValue in pairs(self.DefaultTemplate) do
		self.DefaultVars[DefaultValue[1]] = true
	end
	self.SkipRules = {}
	local RulesSkipped = false
	self.db.profile.Rules = self.db.profile.Rules or {}
	for RuleKey, RuleValue in pairs(self.db.profile.Rules) do
		for DefaultKey, DefaultValue in ipairs(self.DefaultTemplate) do
			-- Check if the rule does not have a variable but the default template says we should.
			if (not RuleValue[DefaultValue[1]] and DefaultValue[2]) then
				self.db.profile.Rules[RuleKey][DefaultValue[1]] = self:CopyTable(DefaultValue[2])
			end
		end
		-- Check each variable to see if it's listed in the DefaultTemplate
		for VarKey, VarValue in pairs(RuleValue) do
			if (not self.DefaultVars[VarKey]) then
				self:Debug("Could not find some variables in rule " .. RuleValue.Desc)
				self.SkipRules[RuleKey] = true
				RulesSkipped = true
				break
			end
		end
	end
	if (RulesSkipped and self.db.profile.SkipRules) then
		self:Pour("|cff33ff99" .. L["PasslootBiS"] .. "|r: " .. L["Found some rules that will be skipped."])
	end
end

function PasslootBiS:Debug(...)
	local DebugLine, Counter
	if (self.DebugVar == true) then
		DebugLine = ""
		for Counter = 1, select("#", ...) do
			DebugLine = DebugLine .. select(Counter, ...)
		end
		self:Print(DebugLine)
	end
end

-- Print the accumulated perf summary (per tag: count / avg / peak + worst link).
function PasslootBiS:BiSManagerPerfReport()
	local perf = self.MgrPerf
	if type(perf) ~= "table" or not next(perf) then
		self:Print("|cff33ff99BiS Mgr|r perf: no samples yet — '|cffffd100/plbismgr perf|r', then hover/drag the window.")
		return
	end
	for _, tag in ipairs({ "hover" }) do
		local s = perf[tag]
		if s and s.n > 0 then
			self:Print(string.format(
				"|cff33ff99BiS Mgr|r %s: n=%d  avg=|cffffd100%.2f|r ms  peak=|cffffd100%.2f|r ms (%s)",
				tag, s.n, s.total / s.n, s.peak, tostring(s.peakLink or "?")))
		end
	end
end

-- /plbismgr — opt-in perf probe for the BiS Manager window. `perf` (or `on`) starts
-- SILENTLY timing every tooltip resolve the window does, so the first-see/render cost
-- can be MEASURED rather than inferred (it's the same class of hitch the dungeon roll
-- path pays). `off` stops and prints a final summary; no arg (or `report`) prints the
-- running summary. To catch a once-per-login outlier, enable perf right after a fresh
-- LOGIN — before opening/dragging the window — then read the report.
function PasslootBiS:BiSManagerCommand(input)
	local arg = tostring(input or ""):lower():gsub("%s+", "")
	if arg == "perf" or arg == "on" then
		self.MgrPerfDebug = true
		self.MgrPerf = {}
		if not mgrProfClock then
			self:Print("|cff33ff99BiS Mgr|r perf |cff00ff00ON|r, but debugprofilestop() is missing here — no timings will be collected.")
		else
			self:Print("|cff33ff99BiS Mgr|r perf |cff00ff00ON|r (silent). Use the window, then '|cffffd100/plbismgr|r' to read the summary, '|cffffd100/plbismgr off|r' to stop.")
		end
	elseif arg == "off" then
		self.MgrPerfDebug = false
		self:BiSManagerPerfReport()
		self:Print("|cff33ff99BiS Mgr|r perf |cffff5555OFF|r.")
	else -- no arg / "report" / anything else: print the running summary
		self:BiSManagerPerfReport()
	end
end

-- /plbisdebug -- flip the Debug() trace on for a run. There was no way to turn
-- DebugVar on short of editing Core/Constants.lua, which makes "tell me what the
-- addon thought it was doing" an unanswerable question during in-game testing --
-- and the roll/confirm path is the one place where the only evidence is timing.
function PasslootBiS:DebugCommand(input)
	input = tostring(input or ""):lower():gsub("%s", "")
	if input == "on" then
		self.DebugVar = true
	elseif input == "off" then
		self.DebugVar = false
	else
		self.DebugVar = not self.DebugVar
	end
	self:Print("debug trace " .. (self.DebugVar and "|cff33ff99on|r" or "|cffff0000off|r") ..
		". Rolls, rule matches and bind confirms are logged to chat while it is on.")
end

if PasslootBiS.RegisterChatCommand then
	PasslootBiS:RegisterChatCommand("plbisdebug", "DebugCommand")
	PasslootBiS:RegisterChatCommand("plbismgr", "BiSManagerCommand")
end

function PasslootBiS:IterateRules(CallbackFunc, ...)
	if (PasslootBiSDB and PasslootBiSDB.profiles) then
		for ProfileKey, ProfileValue in pairs(PasslootBiSDB.profiles) do
			if (ProfileValue.Rules) then
				for RuleKey, RuleValue in ipairs(ProfileValue.Rules) do
					if (type(CallbackFunc) == "string") then
						self[CallbackFunc](self, RuleValue, ...)
					elseif (type(CallbackFunc) == "function") then
						CallbackFunc(RuleValue, ...)
					end
				end -- RuleKey, RuleValue
			end -- if ProfileValue.Rules
		end -- ProfileKey, ProfileValue
	elseif (self.db and self.db.profile and self.db.profile.Rules) then
		for RuleKey, RuleValue in ipairs(self.db.profile.Rules) do
			if (type(CallbackFunc) == "string") then
				self[CallbackFunc](self, RuleValue, ...)
			elseif (type(CallbackFunc) == "function") then
				CallbackFunc(RuleValue, ...)
			end
		end -- RuleKey, RuleValue
	end
end

-- ####### Structures ########
-- ## Main PasslootBiS DB structure ##
-- DB Version 12 structure:
-- PasslootBiS Global = {
-- ["Modules"] = {
-- ["ModuleName"] = {
-- ["Version"] = 1,
-- },
-- },
-- }
-- PasslootBiS Profile = {
-- ["Quiet"] = false,
-- ["Rules"] = {
-- {
-- ["Desc"] = "Description",
-- ["ModuleVar"] = ModuleValue,
-- ["ModuleVar"] = ModuleValue,
-- },
-- },
-- ["Modules"] = {
-- ["ModuleName"] = {
-- ["Status"] = true/false,
-- ["ProfileVars"] = {},
-- },
-- },
-- }

-- ## Table format of Default Template when creating a new rule ##
-- # Also the format for registering the variables
-- PasslootBiS.DefaultTemplate = {
-- { VariableName, Default },
-- { VariableName, Default },
-- }

-- ## Plugin Lookup Table ##
-- This is a lookup only table, we do not delete entries from this table generated
-- # RuleVariables are created when a module uses RegisterDefaultVariables()
-- Used as verification, as the only variables our module can access with GetConfigOption() and SetConfigOption()
-- Also used in CheckDBVersion, as a list of variables to upgrade with the Callback function.
-- # RuleWidgets are created when a module uses AddWidget()
-- Used as a list of widgets to remove from the PasslootBiS.RuleWidgets table.
-- (PasslootBiS.RuleWidgets is a sorted table of all widgets to display)
-- PasslootBiS.PluginInfo = {
-- [ModuleName] = {
-- ["RuleVariables"] = {
-- VariableName = true,
-- VariableName = true,
-- },
-- ["RuleWidgets"] = {
-- [1] = WidgetA,
-- [2] = WidgetB,
-- },
-- },
-- }

-- ## Main table of SORTED (Alphabetical > preferred priority) rule widgets to display ##
-- PasslootBiS.RuleWidgets = {
-- WidgetA,
-- WidgetB,
-- }

-- ## Module List in a SORTED order.  Actual headers in self.PluginInfo.ProfileHeader ##
-- PasslootBiS.ModuleHeaders = {
-- "ModuleA",
-- "ModuleB",
-- }

-- Widget.Info = {
-- [1] = "Text to display in filter list",
-- [2] = "Tooltip description",
-- [3] = "Module name this belongs to",
-- }
