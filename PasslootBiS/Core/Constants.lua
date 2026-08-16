local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")
local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")

PasslootBiS.DefaultTemplate = {
  { "Desc", L["Temp Description"] },
  { "Loot", {  -- Choices: "de", "pass", "greed", "need", disabled is an empty table
    -- [1] = "de",
    -- [2] = "need",
    -- [3] = "greed",
  } },
}
-- ## The rules a profile with NO rules of its own starts with ##
-- Seeded once per profile by PasslootBiS:SeedDefaultRules() (Core/PassLoot.lua),
-- NOT declared in the AceDB `defaults` table: AceDB deep-merges its defaults into
-- whatever is already stored, so a rule list declared there would graft Usable/
-- CanIRoll filters onto rules 1 and 2 of every existing profile.
--
-- Both rules greed, and they are ordered so the narrow one is tried first (rules
-- are evaluated top-down; the first match wins):
--   1) "Not Usable" -- Usable = 3 ("Unusable", NOT an exception). The Usable module
--      reports 3 when the item tooltip carries a red requirement line, so this is
--      the "I can't use it, take the gold" rule.
--   2) "Catch All"  -- CanIRoll = 1 ("Any"), which always matches, so anything the
--      rule above didn't claim still gets a greed rather than being ignored.
-- The inner { Value, Exception } shape is the module widget filter format shared by
-- every dropdown module (see Modules/Usable.lua).
PasslootBiS.DefaultRules = {
  {
    ["Desc"] = L["DefaultRule_NotUsable"],
    ["Loot"] = { "greed" },
    ["Usable"] = { { 3, false } },
  },
  {
    ["Desc"] = L["DefaultRule_CatchAll"],
    ["Loot"] = { "greed" },
    ["CanIRoll"] = { { 1, false } },
  },
}
PasslootBiS.FontGold = "|cffffcc00"
PasslootBiS.FontWhite = "|cffffffff"
PasslootBiS.FontGray = "|cff736f6e"
PasslootBiS.FontRed = "|cffff0000"
-- Traffic-light pair used by the advisor status panel (Core/AdvisorStatus.lua):
-- green = ready, yellow = present but not fully usable, FontRed = missing/off.
PasslootBiS.FontGreen = "|cff33ff99"
PasslootBiS.FontYellow = "|cffffd100"
PasslootBiS.NumRuleListLines = 6
PasslootBiS.NumItemListLines = 5
PasslootBiS.RuleListLineHeight = 16
PasslootBiS.ItemListLineHeight = 16
PasslootBiS.NumFilterLines = 8
PasslootBiS.FilterLineHeight = 16
PasslootBiS.RollOrder = { "need", "de", "greed", "pass" }
PasslootBiS.RollOrderToIndex = {}
for Key, Value in pairs(PasslootBiS.RollOrder) do
  PasslootBiS.RollOrderToIndex[Value] = Key
end
-- PasslootBiS.RollMsg = {
  -- ["need"] = L["Rolling need on %item% (%rule%)"],
  -- ["greed"] = L["Rolling greed on %item% (%rule%)"],
  -- ["de"] = L["Rolling disenchant on %item% (%rule%)"],
  -- ["pass"] = L["Rolling pass on %item% (%rule%)"],
  -- ["ignore"] = L["Ignoring %item% (%rule%)"],
-- }
PasslootBiS.RollMethod = {
  ["need"] = 1,
  ["greed"] = 2,
  ["de"] = 3,
  ["pass"] = 0,
}
--[===[@debug@
PasslootBiS.DebugVar = false
--@end-debug@]===]
