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
PasslootBiS.FontGold = "|cffffcc00"
PasslootBiS.FontWhite = "|cffffffff"
PasslootBiS.FontGray = "|cff736f6e"
PasslootBiS.FontRed = "|cffff0000"
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
