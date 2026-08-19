--[[ report-smoke.lua -- offline smoke test for /plbisdebug's report builder.

Run from the REPO ROOT:  lua5.1 management/addons/passlootbis/tools/report-smoke.lua

Core/DebugReport.lua builds no frames at load time (the copy box is lazy), so the
whole report can be exercised under bare lua5.1 with a stubbed addon. That matters
because the report is almost entirely reaching THROUGH other objects -- the advisor
API, the scanner's diagnostic surface, the rules table -- and every one of those can
be absent in a real install. A nil-index there turns "tell me what went wrong" into
a second thing that went wrong.

Three passes: a fully-wired install, the same without an item to test, and the
degenerate case (no scanner, no API, no BiS lists), which must still produce a
readable report rather than an error. Eyeball the output; a crash exits non-zero.

Not shipped: lives under management/ per management/docs/CLAUDE.md.
]]


-- Pure advisor core first, while LibStub is absent (that is its offline exit).
_G.PLBiSScanner = {}
local RollAdvisorCore = dofile("PasslootBiS/Core/RollAdvisor.lua")

local addon = {}
addon.DebugVar, addon.DebugEcho, addon.DebugLog = true, false, {}
addon.printed = {}
function addon:Print(...) self.printed[#self.printed+1] = table.concat({...}, " ") end
function addon:RegisterChatCommand() end
function addon:ApplyDarkBackdrop(f) return f end
addon.RollAdvisorCore = RollAdvisorCore
addon.RollRetry = { NameFromLink = function(l) return l and l:match("%[(.-)%]") end }
addon.db = { profile = { Rules = {
  { Desc = "Ranger P0 (IDs)",    Loot = {"need"}, BeforeAdvisor = true, ItemIDs = {{"412491", false, false}} },
  { Desc = "Ranger P0 (Suffix)", Loot = {"need"}, BeforeAdvisor = true, Items = {{"Kyrstel Mantle","Exact",false}} },
  { Desc = "Not Usable", Loot = {"greed"} },
  { Desc = "Catch All",  Loot = {"greed"}, Disabled = true },
}, AutoConfirmBinds = true } }
function addon:EnumerateBiSLists() return { "Ranger P0" } end
function addon:CollectBiSListItems() return { {kind="id",key="412491",rolls=true}, {kind="id",key="999",rolls=false} } end
function addon:CollectStaleBiSItems()
  return { { list="Ranger P0", kind="id", key="412491", name="Kyrstel Mantle", delta=-0.12 } }
end
function addon:FormatBiSDelta(d) return string.format("-%d%%", math.floor(math.abs(d)*100+0.5)) end
function addon:IsBiSItem(id, name)
  if tostring(id) == "412491" or name == "Kyrstel Mantle" then return true, "Ranger P0" end
  return false, nil
end

-- A scanner advisor with the new diagnostic surface.
local scanner = {}
function scanner:GetStatus() return { enabled=true, hasWeights=true, class="Hunter",
  spec="Ranger", threshold=0.03, placeholder=false, ignoreEnchants=false } end
-- Slot 3 deliberately disagrees between real and link: that is the "SetHyperlink is
-- lying about a scaled item" case the check exists to catch, and the report has to
-- come back with the do-NOT-enable verdict rather than a clean bill of health.
function scanner:GetEnchantCheck() return {
  { slot=1,  name="Helm",      real=100.0, link=100.0, stripped=88.0 },
  { slot=3,  name="Shoulders", real=131.5, link=104.2, stripped=104.2 },
  { slot=15, name="Cloak",     real=60.0,  link=60.0,  stripped=60.0 },
} end
function scanner:GetRunLedger() return { { equipLoc="INVTYPE_SHOULDER", count=1,
  bestScore=131.5, bestName="Won Mantle" } } end
function scanner:GetLinkVerdict(link, isBiS)
  return { link=link, name="Kyrstel Mantle", equipLoc="INVTYPE_SHOULDER", scannable=true,
    hadWeights=true, filtered=false, isBiS=isBiS, score=115.2, target=131.5,
    isUpgrade=false, delta=-0.124, down={ delta=-0.124, wonName="Won Mantle" },
    verdict={ reason="On your BiS list, but -12% vs the Won Mantle you won" } }
end

addon.API = {
  VERSION = 1, enabled = true,
  GetAdvisor = function(_, n) return n == "PLScanner" and scanner or nil end,
  GetAdvisorNames = function() return { "PLScanner" } end,
  GetTrustMode = function() return "held" end,
  IsSourceEnabled = function(_, k) return true end,
}

_G.LibStub = function(n) return {
  GetAddon = function() return addon end,
  GetLocale = function() return setmetatable({}, { __index = function(_, k) return k end }) end,
} end
_G.CreateFrame = function() error("no frames should be built at load time") end
_G.GetItemInfoFromHyperlink = function(l) return tonumber(l:match("|Hitem:(%d+)")) end
_G.ChatFontNormal = {}

for i = 1, 5 do addon.DebugLog[i] = "trace line " .. i end

dofile("PasslootBiS/Core/DebugReport.lua")

local LINK = "|cffa335ee|Hitem:412491:0:0:0:0:0:0:0:60|h[Kyrstel Mantle]|h|r"
local ok, report = pcall(addon.BuildDebugReport, addon, LINK)
if not ok then print("BuildDebugReport ERROR: " .. tostring(report)); os.exit(1) end
print(report)
print("\n================ no-item variant ================\n")
local ok2, r2 = pcall(addon.BuildDebugReport, addon, nil)
if not ok2 then print("ERROR: " .. tostring(r2)); os.exit(1) end
print(r2)

-- Degenerate: no scanner, no API, no lists. The report must still build.
addon.API = nil
addon.EnumerateBiSLists = function() return {} end
addon.CollectStaleBiSItems = function() return {} end
addon.DebugVar = false
local ok3, r3 = pcall(addon.BuildDebugReport, addon, nil)
if not ok3 then print("DEGENERATE ERROR: " .. tostring(r3)); os.exit(1) end
print("\n================ degenerate (no scanner/API/lists) ================\n")
print(r3)
