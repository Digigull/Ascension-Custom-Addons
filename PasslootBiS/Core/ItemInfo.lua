local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")

--[[
	Remix of Ascension code for the following functions
	-- IsItemBloodforged
	-- IsItemHeroic
	-- IsItemMythic
	-- IsItemAscended
	-- GetItemMythicLevel
]]
local function processItemFlavorText(item)
	local flavor = GetItemFlavorText(item.id)

	item.isBloodforged = flavor:find("Bloodforged", 1, true) ~= nil
	item.isHeroic = flavor:find("Heroic", 1, true) ~= nil
	if not item.isHeroic then
		item.isMythic = flavor:find("Mythic", 1, true) ~= nil
		if not item.isMythic then
			item.isAscended = flavor:find("Ascended", 1, true) ~= nil
		end
	end
	item.isWorldforged = flavor:find("Worldforged", 1, true) ~= nil
	local level
	if item.isMythic then
		level = flavor:match("Mythic (%d*)")
		level = level and tonumber(level)
	end

	item.mythicLevel = level or 0 -- 0 means not a Mythic+ item
end

local function fillItemInfo(item)
	local name, _, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(item.link)
	-- Did the client actually have this item cached? GetItemInfo returns nil for a
	-- first-see item (its name is the signal the whole tuple came back). The stat-based
	-- rules (quality / type / usable) need this data, so the roll path (RollRetry) keeps
	-- retrying while this is false; the id + name below do NOT need it.
	item.infoResolved = name ~= nil
	-- Name is match-critical (the exact-name BiS rule, Modules/ItemName.lua) and must
	-- NEVER depend on the cache — on Ascension one base item spawns many scaled variants
	-- and GetItemInfo is cache-first (research §2.4a). Fall back to the link's own
	-- [bracket] text, which is exactly what the server sent for THIS instance. item.id
	-- is already a pure link parse (InitItem), so BOTH BiS match rules keep working even
	-- if GetItemInfo never loads for this item.
	local linkName = PasslootBiS.RollRetry and PasslootBiS.RollRetry.NameFromLink(item.link) or nil
	item.name = name or linkName
	item.quality = quality
	item.iLevel = iLevel
	item.reqLevel = reqLevel or 0
	item.class = class
	item.subclass = subclass
	item.maxStack = maxStack
	item.equipSlot = equipSlot
	item.texture = texture
	item.vendorPrice = vendorPrice
	return item
end

function PasslootBiS:InitItem(link)
	if not link then return end

	local item = {}
	item.link = link
	item.id = GetItemInfoFromHyperlink(link)
	item = fillItemInfo(item)
	processItemFlavorText(item)
	return item
end
