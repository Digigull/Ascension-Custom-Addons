--[[ mountpet-smoke.lua -- offline check for the Mount / Pet filter's classifier.

Run from the REPO ROOT:  lua5.1 management/addons/passlootbis/tools/mountpet-smoke.lua

Modules/MountPet.lua decides whether a drop is a mount or a companion pet, and the
"Mounts & Pets" starter rule Needs on what it says yes to -- so a wrong answer here
is a wrong roll in front of a group, on the one drop of the run that anybody minds.
What it cannot be reasoned about is the input: the subclass string the LIVE client
returns for those two item classes is not something this repo can read, which is why
the module takes several spellings and falls back to the item's Use: line at all.
The cases below pin both routes against the two items the request named
(management/addons/passlootbis/MOUNT-PET.md has their database rows).

Three stubs and no client emulation: the module needs LibStub, a NewModule to hand
its table back through, and a BuildTooltipCache that serves canned lines.

Not shipped: lives under management/ per management/docs/CLAUDE.md.
]]

local captured
local addon = {}
addon.Prototypes = {}
function addon.Prototypes:Debug(...) end
function addon:NewModule(name) local m = setmetatable({}, {__index = addon.Prototypes}); captured = m; return m end
function addon:CreateSimpleDropdown() return {} end
function addon:BuildTooltipCache(item) addon.TooltipCache = { link = item.link, Left = item.ttLeft or {} } end
_G.LibStub = function(n, silent)
  if n == "LibBabble-Inventory-3.0" then
    return { GetUnstrictLookupTable = function() return { Mount = "Mount", Pet = "Pet" } end }
  end
  return { GetAddon = function() return addon end,
           GetLocale = function() return setmetatable({}, {__index=function(_,k) return k end}) end }
end
dofile("PasslootBiS/Modules/MountPet.lua")
local m = captured
m:SetupValues()

local passes, fails = 0, 0
local function ok(cond, what)
  print((cond and "  ok   " or "  FAIL ") .. what)
  if cond then passes = passes + 1 else fails = fails + 1 end
end
local function check(item, want, wantHow, what)
  local v, how = m:Classify(item)
  ok(v == want and how == wantHow, what .. "  -> " .. tostring(v) .. "/" .. tostring(how))
end

check({ link = "l1", subclass = "Mounts" }, 2, "subclass", "13335 subclass Mounts")
check({ link = "l2", subclass = "Companions" }, 3, "subclass", "60060 subclass Companions")
check({ link = "l3", subclass = "Mount" }, 2, "subclass", "client subclass Mount")
check({ link = "l4", subclass = "Pet" }, 3, "subclass", "client subclass Pet")
check({ link = "l5", subclass = "Junk", ttLeft = { "Sigil of X", "Binds when used",
  "Use: Teaches you how to summon this companion.  This is a non-combat companion.", "1 Charge" } },
  3, "tooltip", "junk subclass, companion Use line")
check({ link = "l6", subclass = "Other", ttLeft = { "Reins of X", "Binds when picked up",
  "Use: Teaches you how to summon this mount. This is a Ground mount.", "1 Charge" } },
  2, "tooltip", "other subclass, mount Use line")
check({ link = "l7", subclass = "Engineering", ttLeft = { "Schematic: Chopper", "Binds when picked up",
  "Use: Teaches you how to make a Chopper.", "\nMekgineer's Chopper", "Binds when picked up",
  "Use: Teaches you how to summon this mount." } }, 0, "none", "recipe for a mount is NOT a mount")
check({ link = "l8", subclass = "Mail", ttLeft = { "Kyrstel Mantle", "Mail", "+30 Agility" } },
  0, "none", "plain gear")
check({ subclass = nil }, 0, "none", "no item data")

local rule = { { 1, false } }
m.Widget.GetData = function() return rule end
m.CurrentMatch = 2
ok(m.Widget:GetMatch(1, 1) == true, "Mount or Pet matches a mount")
m.CurrentMatch = 3
ok(m.Widget:GetMatch(1, 1) == true, "Mount or Pet matches a pet")
m.CurrentMatch = 0
ok(m.Widget:GetMatch(1, 1) == false, "Mount or Pet rejects gear")
rule = { { 2, false } }
m.CurrentMatch = 3
ok(m.Widget:GetMatch(1, 1) == false, "Mount rejects a pet")
m.CurrentMatch = 2
ok(m.Widget:GetMatch(1, 1) == true, "Mount accepts a mount")
print(string.format("\nmountpet-smoke: %d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
