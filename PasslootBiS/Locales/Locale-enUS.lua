local L = LibStub("AceLocale-3.0"):NewLocale("PasslootBiS", "enUS", true)
if not L then return end
L["Active Filters"] = true
L["Active Filters_Desc"] = [=[Select a filter to modify, or shift-right-click to remove this filter
(Each filter must have at least one match)]=]
L["Add"] = true
L["Add a new rule."] = true
L["Add this filter."] = true
L["Allow Multiple Confirm Popups"] = true
L["Available Filters"] = true
L["Available Filters_Desc"] = [=[Select a filter to use.
(Each filter must have at least one match)]=]
L["Change the exception status of this filter."] = true
L["Checking this will disable the exclusive bit to allow multiple confirmation of loot roll popups"] = true
L["Checking this will prevent extra details from being displayed."] = true
L["Clean Rules"] = true
L["CLEAN RULES DESC"] = [=[Are you sure?

It is recommended that you activate all modules used in rules.
]=]
L["Click to select and edit this rule."] = [=[Click to select and edit this rule.
Right click to copy or export this rule.]=]
L["Create Copy"] = true
L["Default"] = true
L["Description"] = true
L["Description_Desc"] = [=[Description of this rule.
(Saves when you press enter)]=]
L["Disenchant"] = "DE"
L["Disenchant_Desc"] = "If an enchanter is present, will roll disenchant on all loot matching this rule."
L["Display a warning when a rule is skipped."] = true
L["Displays disabled or unknown filter variables."] = true
L["Down"] = true
L["Enabled"] = true
L["Enable / Disable this module."] = true
L["Enable Mod"] = true
L["Enable or disable this mod."] = true
L["Enter the text displayed when rolling."] = [=[Enter the text displayed when rolling.
Use '%item%' for item being rolled on.
Use '%rule%' for rule that was matched.
]=]
L["Exception"] = true
L["EXCEPTION_PREFIX"] = "! "
L["Export To"] = true
L["Found some rules that will be skipped."] = true
L["General Options"] = true
L["Greed"] = true
L["Ignored"] = true
L["Ignoring %item% (%rule%)"] = true
L["Menu"] = true
L["Messages"] = true
L["Module"] = true
L["Modules"] = true
L["Move selected rule down in priority."] = true
L["Move selected rule up in priority."] = true
L["Need"] = true
L["No rules matched."] = true
L["Opens the PasslootBiS Menu."] = true
L["Options"] = true
L["Output"] = true
L["Pass"] = true
L["PasslootBiS"] = "PassLoot (BiS)"
L["PASSLOOT_SLASH_COMMAND"] = "passlootbis"
L["Profiles"] = true
L["Quiet"] = true
L["Remove"] = true
L["Removes disabled or unknown filters from current rules."] = true
L["Remove selected rule."] = true
L["Remove this filter."] = true
L["Rolling disenchant on %item% (%rule%)"] = true
L["Rolling greed on %item% (%rule%)"] = true
L["Rolling is tried from left to right"] = true
L["Rolling need on %item% (%rule%)"] = true
L["Rolling pass on %item% (%rule%)"] = true
L["Rule List"] = true
L["Skipping %rule%"] = true
L["Skip Rules"] = true
L["Skip rules that have disabled or unknown filters."] = true
L["Skip Warning"] = true
L["Temp Description"] = true
L["Test"] = true
L["Test an item link to see how we would roll"] = true
L["Unable to copy rule"] = true
L["Unknown Filters"] = true
L["Up"] = true
L["Will pass on all loot matching this rule."] = true
L["Will roll greed on all loot matching this rule."] = true
L["Will roll need on all loot matching this rule."] = true

L["Owned"] = true
L["Unowned"] = true
L["Selected rule will only match unlearned vanity items."] = true
L["Selected rule will only match learned vanity items."] = true
L["Vanity Unlock"] = true
L["Unlocked"] = true
L["Unknown"] = true
L["Unlocked from Different Item"] = true
L["Selected rule will only match unlearned Wardrobe items."] = true
L["Selected rule will only match learned Wardrobe items."] = true
L["Wardrobe Unlock"] = true
L["Any RE"] = true
L["Any RE Known"] = true
L["Any RE Unknown"] = true
L["WRE Known"] = true
L["WRE Unknown"] = true
L["Non-WRE Known"] = true
L["Non-WRE Unknown"] = true
L["Mystic Enchant"] = true
L["Selected rule will only match unlearned mystic enchants."] = true
L["10 Man Raid"] = true
L["25 Man Raid"] = true
L["Accessories"] = true
L["Account"] = true
L["Any"] = true
L["Armor"] = true
L["Bind On"] = true
L["Binds On"] = true
L["By adding the Confirm DE filter you will not get any confirmations when rolling disenchant.  This might get you into trouble with your group, are you sure?"] = true
L["Can I Roll"] = true
L["%class% - %spec%"] = true
L["Class Spec"] = true
L["Confirm BoP"] = true
L["Confirm DE"] = true
L["current"] = true
L["Current Spec: %spec%"] = true
L["Equal to"] = true
L["Equal to %num%"] = true
L["Equip"] = true
L["Equipable"] = true
L["Equip Slot"] = true
L["Exact"] = true
L["Exact_Desc"] = [=[Checked: Item must match exactly.
Unchecked: Item must have this phrase.]=]
L["Greater than"] = true
L["Greater than %num%"] = true
L["Group"] = true
L["Group / Raid"] = true
L["Guild Group"] = true
L["Guild Group_Desc"] = "Selected rule will match when the group has this percentage of guild mates."
L["Heroic"] = true
L["Hybrid"] = true
L["Inventory"] = true
L["Item Level"] = true
L["ItemLevel_DropDownTooltipDesc"] = [=[Selected rule will only match items when comparing the item level to this.
(use 'current' for your currently equipped item level)]=]
L["Item ID"] = true
L["Item Name"] = true
L["Item Price"] = true
L["Later"] = true
L["Learned"] = true
L["Learned Item"] = true
L["Less than"] = true
L["Less than %num%"] = true
L["level"] = true
L["Loot Won"] = true
L["Loot Won Comparison"] = true
L["Loot Won Counter"] = true
L["Loot Won Counter_Desc"] = [=[Set how many times we have won loot on this rule
(Saves when you press enter)]=]
L["None"] = true
L["Normal"] = true
L["Not"] = true
L["Not Equal to"] = true
L["Not Equal to %num%"] = true
L["Now"] = true
L["Outside"] = true
L["Pickup"] = true
L["Player Name"] = true
L["Player Level"] = true
L["PlayerLevel_DropDownTooltipDesc"] = true
L["Mythic Plus Level"] = true
L["MythicPlusLevel_DropDownTooltipDesc"] = [=[Selected rule will only match items that have a mythic plus level compared to this value.
0 means the item is not a Mythic Plus item]=]
L["Exceptional Item"] = true
L["Selected module checks if an item is no longer normal."] = true
L["Bloodforged"] = true
L["Heroic"] = true
L["Mythic"] = true
L["Ascended"] = true
L["Worldforged"] = true
L["Quality"] = true
L["Raid"] = true
L["Required Level"] = true
L["RequiredLevel_DropDownTooltipDesc"] = [=[Selected rule will only match items when comparing the required level to this.
(Use 'level' for your current level)]=]
L["Reset Counters On Join"] = true
L["Reset Counters On Join_Desc"] = [=[Checking this will reset counters on joining a group or raid.
Shift-click to reset all current counters.]=]
L["Selected rule will match on item names."] = true
L["Selected rule will match on player names."] = true
L["Selected rule will only match if you are in a group or raid."] = true
L["Selected rule will only match if you can roll this."] = true
L["Selected rule will only match items that are equipable."] = true
L["Selected rule will only match items when compared to vendor value."] = true
L["Selected rule will only match items when comparing already aquired inventory to this."] = true
L["Selected rule will only match items when comparing the item level to this."] = true
L["Selected rule will only match items when comparing the loot won counter to this."] = true
L["Selected rule will only match items when comparing the required level to this."] = true
L["Selected rule will only match items when you are in this type of zone."] = true
L["Selected rule will only match items when you are this class and spec."] = true
L["Selected rule will only match items with this equip slot."] = true
L["Selected rule will only match items with this type and subtype."] = true
L["Selected rule will only match these items."] = true
L["Selected rule will only match this quality of items."] = true
L["Selected rule will only match usable items."] = true
L["Temp Item ID"] = true
L["Temp Item Name"] = true
L["Temp Name"] = true
L["Temp Zone Name"] = true
L["%type% - %subtype%"] = true
L["Type / SubType"] = true
L["Unique"] = true
L["Unique_Desc"] = [=[Selected rule will only match items that are unique.
This includes items which have a unique stack higher than 1, such as battleground tokens, as well as items which are Unique-Equip.]=]
L["Unlearned"] = true
L["Unusable"] = true
L["Usable"] = true
L["Use"] = true
L["Use RegEx for partial"] = true
L["Uses regular expressions when using partial matches."] = true
L["Weapons"] = true
L["Will click yes on BoP dialogues."] = true
L["Will click yes on Disenchant dialogues."] = true
L["Will confirm bind!"] = true
L["Will confirm disenchant!"] = true
L["Zone Name"] = true
L["Zone Name_Desc"] = [=[Zone name to match selected rule to, leave empty to match any zone.
(Saves when you press enter)
Shift-right-click to fill with current zone name]=]
L["Zone Type"] = true
L["%zonetype% - %instancedifficulty%"] = true
L["NameRule"] = true
L["(Add) or (remove) an item by name to an existing rule."] = true
L["IDRule"] = true
L["(Add) or (remove) an item by id to an existing rule"] = true
L["Player Class"] = true
L["Selected rule will match against the player's class."] = true

-- BiS import panel (Modules/BiSImport.lua + Core "Import BiS" options)
L["Import BiS"] = true
L["ImportBiS_Intro"] =
	"Paste a PLBIS1 import string (from the BisBeard \226\134\146 PassLoot converter) " ..
	"and click Import. It creates two auto-roll rules \226\128\148 one matching by item " ..
	"ID, one by exact name \226\128\148 which you can then edit in the Rules list like any other." ..
	"\n\nDon't have a string yet? See the converter page below."
L["ImportBiS_GetString"] = "Converter page"
L["ImportBiS_Url"] = "https://throatrip.net/bis"
L["ImportBiS_UrlDesc"] =
	"Build your list on BisBeard, click Share, then paste that link into this page " ..
	"to get your PLBIS1 string. To copy this address: click the box above, press " ..
	"Ctrl+A to select it, then Ctrl+C."
L["Import string"] = "PLBIS1 import string"
L["ImportBiS_InputDesc"] = "Paste the whole PLBIS1: string here."
L["ImportBiS_Target"] = "Import into"
L["ImportBiS_TargetDesc"] =
	"By default an import creates a NEW BiS list. Pick an existing list here to " ..
	"overwrite it instead (its old items are replaced)."
L["ImportBiS_NewList"] = "Create new list"
L["ImportBiS_Overwrite"] = "Overwrite:"
L["Import"] = true
L["ImportBiS_GoDesc"] = "Parse the string and create (or overwrite) this BiS list's rules."
L["ImportBiS_NotLoaded"] = "BiS importer module not loaded."
L["ImportBiS_Empty"] = "Nothing to import \226\128\148 paste a PLBIS1 string first."
L["ImportBiS_Failed"] = "Import failed:"
-- %s = list name, %d = items rolled on, %d = total items on the list.
L["ImportBiS_Done"] =
	"Imported \"%s\" \226\128\148 rolling on %d of %d item(s). Open BiS Manager to " ..
	"see the full list by source and turn rolls on/off."

-- BiS Manager panel (Core "BiS Manager" options; mgr= block from Modules/BiSImport.lua)
L["BiS Manager"] = true
L["BiSManager_Intro"] =
	"Manage your imported BiS lists. Pick a list, then open the manager window to see " ..
	"ALL its items \226\128\148 hover any item for its in-game tooltip and sort by source, " ..
	"slot or score. A ticked item auto-rolls; untick to stop rolling on it. Items from " ..
	"sources with a loot-roll window (dungeons, raids, forged drops) are ticked by " ..
	"default \226\128\148 vendor, reputation and crafting items are kept for reference but " ..
	"left unticked (you never get a roll frame for them). Click Apply in the window to " ..
	"update the auto-roll rules on the main page."
L["BiSManager_Empty"] =
	"No BiS lists yet. Import a PLBIS1 string on the Import BiS page and it will show " ..
	"up here, grouped by drop source."
L["BiSManager_List"] = "BiS list"
L["BiSManager_ListDesc"] = "Choose which imported BiS list to view and edit."
L["BiSManager_Hint"] =
	"Ticked = auto-roll on this item. Roll-window sources (dungeon/raid/forged) are " ..
	"ticked by default; the rest are shown for reference but unticked. Change any " ..
	"box, then click Apply."
L["BiSManager_OtherSource"] = "Other / unknown source"
L["BiSManager_RollTag"] = "rolls by default"
L["BiSManager_InfoTag"] = "info only \226\128\148 tick to roll"
L["BiSManager_Apply"] = "Apply changes"
L["BiSManager_ApplyDesc"] =
	"Rebuild this list's auto-roll rules from exactly the ticked items."
L["BiSManager_Reset"] = "Reset ticks"
L["BiSManager_ResetDesc"] = "Undo unapplied tick changes (back to what's rolling now)."
-- %d = items now rolled on, %d = total items on the list, %s = list name.
L["BiSManager_Applied"] = "Applied \226\128\148 rolling on %d of %d item(s) in \"%s\"."
-- Delete a whole BiS list (arm-to-confirm: two clicks, no popup). Per-character,
-- since rules + stored list data live in the profile (now per-character).
L["BiSManager_Delete"] = "Delete this list"
-- %s = list name.
L["BiSManager_DeleteConfirm"] = "Click again to permanently delete \"%s\""
L["BiSManager_DeleteDesc"] =
	"Remove this BiS list from THIS character only \226\128\148 its auto-roll rules and " ..
	"its stored items. Other characters keep their own copy. Click once to arm, again to confirm."
-- %s = list name.
L["BiSManager_Deleted"] = "Deleted BiS list \"%s\" from this character."
-- Floating BiS Manager window (Core/PassLoot.lua custom frame): hover an item for
-- its in-game tooltip, sort by source / slot / score, tick which items to roll on.
L["BiSManager_Open"] = "Open BiS Manager window"
L["BiSManager_OpenDesc"] =
	"Open the floating manager window for the selected list: hover an item for its " ..
	"in-game tooltip, sort by source, slot or score, and tick which items to auto-roll on."
-- %s = the selected list name.
L["BiSManager_WindowTitle"] = "BiS Manager \226\128\148 %s"
L["BiSManager_SortBy"] = "Sort by:"
L["BiSManager_SortSource"] = "Source"
L["BiSManager_SortSlot"] = "Slot"
L["BiSManager_SortScore"] = "Score"
L["BiSManager_ScoreHeader"] = "All items \226\128\148 highest score first"
L["BiSManager_UnknownSlot"] = "Unknown slot"
L["BiSManager_WindowEmpty"] = "This list has no items."
-- Tooltip footer lines on a manager item row.
L["BiSManager_TipRolling"] = "Auto-rolling on this item"
L["BiSManager_TipNotRolling"] = "Not rolling \226\128\148 tick to roll"
-- %s = a numeric score; shown on the row + in the tooltip when the import carried it.
L["BiSManager_ScoreLabel"] = "Score %s"

-- Minimap button (Core/MinimapButton.lua). The icon is the WoW Need-roll dice.
L["Minimap_LeftClick"] = "Left-click: open the Loot Window or BiS Manager"
L["Minimap_RightClick"] = "Right-click: toggle rules on/off"
L["Minimap_LootWindowSoon"] = "Loot Window coming soon."
L["Minimap_RulesTitle"] = "Toggle rules"
L["Minimap_NoRules"] = "No rules yet \226\128\148 import a BiS list first."
-- Left-click "open a window" menu.
L["Minimap_OpenTitle"] = "Open"
L["Minimap_OpenLootWindow"] = "Loot Window"
L["Minimap_OpenBiSManager"] = "BiS Manager"
L["Minimap_OpenSettings"] = "Settings (Interface Options)"
L["Show Minimap Button"] = true
L["Show Minimap Button_Desc"] = "Show the PassLoot (BiS) button on the minimap."

-- Loot Window (Core/LootWindow.lua): who rolled what / who won, per item.
L["LootWindow_Title"] = "PassLoot \226\128\148 Loot Rolls"
L["LootWindow_Clear"] = "Clear"
L["LootWindow_Winner"] = "Winner: %s"
L["LootWindow_AllPassed"] = "Everyone passed"
L["LootWindow_Rolling"] = "Rolling\226\128\166"
L["LootWindow_Empty"] = "No loot rolls yet. Rolls you see in a group show up here."
-- %s = player, %d = need count. Both callouts show from 3 on, coloured by count
-- (3 green / 4 yellow / 5+ red): the consecutive streak and the running total.
L["LootWindow_NeedStreak"] = "%s has needed %d times consecutively"
L["LootWindow_NeedTotal"] = "%s has needed %d times total"
L["LootWindow_FontSize"] = "Font size"

-- Loot advisor popup (Core/RollAdvisor.lua). The headline is the whole message,
-- so keep it to two words: it is set in a large font in a deliberately narrow
-- window, and anything longer wraps or clips.
L["RollAdvisor_GearUpgrade"] = "Gear Upgrade"
L["RollAdvisor_HighValue"] = "High Value"
-- Fake item name in the "Show Loot Advisor" preview popup.
L["RollAdvisor_PreviewItem"] = "Test Item"

-- The two rules a profile with no rules of its own starts with
-- (Core/Constants.lua DefaultRules). Plain rule descriptions: they are copied
-- into the profile once and are editable from the rules page afterwards.
L["DefaultRule_NotUsable"] = "Not Usable"
L["DefaultRule_CatchAll"] = "Catch All"

-- Advisor status panel on the rules page (Core/AdvisorStatus.lua). Kept SHORT:
-- the panel lives in the narrow column beside the rule list, so anything longer
-- than about twenty characters wraps. Detail belongs in the _Tip lines, which
-- show in the tooltip and have the whole screen to play with.
L["AdvisorStatus_Title"] = "Advisor status"
L["AdvisorStatus_Ready"] = "Ready"
L["AdvisorStatus_Unavailable"] = "Unavailable"
L["AdvisorStatus_NoScanner_Tip"] = "Needs the PassLootBiS Scanner addon, which is not loaded."
L["AdvisorStatus_NoStatus_Tip"] = "The scanner is loaded but did not report its state. It is probably an older build; /plbisscan status still works."
L["AdvisorStatus_Refresh"] = "Refresh"
L["AdvisorStatus_Refresh_Tip"] = "Re-check the scanner. Nothing here is polled, so use this after loading the scanner, picking a spec, or finishing an Auction House scan."
-- Per-source checkboxes on the Gear advice / High value rows.
L["AdvisorStatus_UseSource"] = "Use this advice"
L["AdvisorStatus_UseSource_Tip"] = "Tick to let the loot advisor prompt on this kind of find. Unticked, it is ignored and your rules roll as usual. Both are on by default."
L["AdvisorStatus_SourceOff"] = "Off"
L["AdvisorStatus_SourceOff_Tip"] = "Switched off: the loot advisor will not prompt on this."
L["AdvisorStatus_SourceOff_State"] = "Would otherwise be: %s"
-- Shortcut icon on the BiS Scanner row.
L["AdvisorStatus_OpenScanner"] = "Scanner settings"
L["AdvisorStatus_OpenScanner_Tip"] = "Open the BiS Scanner's settings window, the same one its minimap button opens. This closes the Interface panel so the window is not hidden behind it."
L["AdvisorStatus_OpenScannerFailed"] = "Could not open the BiS Scanner settings window."
-- "Show Loot Advisor" preview button.
-- Label stays put when the preview is up; see the note in Core/AdvisorStatus.lua.
L["AdvisorStatus_ShowAdvisor"] = "Show Advisor"
L["AdvisorStatus_ShowAdvisor_Tip"] = "Pop a test roll prompt so you can drag it where you want it and stretch it from the bottom-right corner. Position and size are remembered. Let the timer run out, pick a button, or click this again to dismiss it. Nothing is rolled."
L["AdvisorStatus_ScanningOff"] = "Scanning off"
L["AdvisorStatus_ScanningOff_Tip"] = "The scanner is switched off. Turn it back on with /plbisscan on."
-- Row 1: the PassLoot <-> Scanner link.
L["AdvisorStatus_LinkLabel"] = "BiS Scanner"
L["AdvisorStatus_LinkMissing"] = "Not installed"
L["AdvisorStatus_LinkMissing_Tip"] = "PassLootBiS Scanner is not installed, so no roll advice is available. Rules still roll normally."
L["AdvisorStatus_LinkNotLoaded"] = "Not loaded"
L["AdvisorStatus_LinkNotLoaded_Tip"] = "PassLootBiS Scanner is installed but the client did not load it. Tick it in the character-select AddOns list and reload."
L["AdvisorStatus_LinkLoaded"] = "Loaded, not linked"
L["AdvisorStatus_LinkLoaded_Tip"] = "The scanner is loaded but has not registered as a roll advisor. A /reload usually fixes it."
L["AdvisorStatus_LinkGateOff"] = "Linked, gate off"
L["AdvisorStatus_LinkGateOff_Tip"] = "Linked, but the advisor gate is switched off, so advice is ignored. Turn it on with /plbisadvisor on."
L["AdvisorStatus_LinkOk"] = "Linked"
L["AdvisorStatus_LinkOk_Tip"] = "The scanner is registered and the advisor gate is on."
L["AdvisorStatus_AdvisorsLine"] = "Advisors: %s"
-- Row 2: gear (stat upgrade) advice.
L["AdvisorStatus_GearLabel"] = "Gear advice"
L["AdvisorStatus_GearNoSpec"] = "No spec set"
L["AdvisorStatus_GearNoSpec_Tip"] = "No stat weights are selected, so upgrade scoring is idle. Pick a spec with /plbisscan spec."
L["AdvisorStatus_GearPlaceholder"] = "Ready, test weights"
L["AdvisorStatus_GearPlaceholder_Tip"] = "The scanner is using PLACEHOLDER weights; scores will not be accurate until the real weights are baked in."
L["AdvisorStatus_GearReady_Tip"] = "Stat weights are loaded, so rolled gear is scored against what you have equipped."
L["AdvisorStatus_SpecLine"] = "Spec: %s / %s"
L["AdvisorStatus_ThresholdLine"] = "Upgrade threshold: +%d%%"
-- Row 3: high-value (Auctionator price) advice.
L["AdvisorStatus_ValueLabel"] = "High value"
L["AdvisorStatus_ValueNoAuctionator"] = "No Auctionator"
L["AdvisorStatus_ValueNoAuctionator_Tip"] = "Auctionator is not loaded, so there are no auction prices to read."
L["AdvisorStatus_ValueNoData"] = "No scan data"
L["AdvisorStatus_ValueNoData_Tip"] = "Auctionator is loaded but has no prices yet. Run one Auction House scan and this turns green."
L["AdvisorStatus_ValueReady_Tip"] = "Auction prices are available, so items worth gold are flagged even when they are not an upgrade."
L["AdvisorStatus_PricesLine"] = "Prices known: %s items"
L["AdvisorStatus_GoldLine"] = "Flags items worth %dg or more"
