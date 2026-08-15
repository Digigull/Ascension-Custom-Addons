local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")

function PasslootBiS:ResetCache()
	PasslootBiS.EvalCache = {}
	PasslootBiS.TooltipCache = { tt = "", Left = {}, Right = {} }
end

local function initCache()
	if not PasslootBiS.EvalCache or not PasslootBiS.TooltipCache then
		PasslootBiS:ResetCache()
	end
end

local function ColorCheck(Red, Green, Blue, Alpha)
	Red = math.floor(Red * 255 + 0.5)
	Green = math.floor(Green * 255 + 0.5)
	Blue = math.floor(Blue * 255 + 0.5)
	Alpha = math.floor(Alpha * 255 + 0.5)
	return (Red == 255 and Green == 32 and Blue == 32 and Alpha == 255)
end

local function getLine(Line)
	if Line then
		local text = Line:GetText()
		local Red, Green, Blue, Alpha = Line:GetTextColor()
		if ColorCheck(Red, Green, Blue, Alpha) then
			PasslootBiS.TooltipCache.usable = false
		end
		return text and text or ""
	else
		return ""
	end
end

function PasslootBiS:BuildTooltipCache(item)
	initCache()
	if not item or not item.link then return end
	local cache = PasslootBiS.TooltipCache
	if item.link == cache.link then return end
	cache.Left, cache.Right = {}, {}
	cache.link = item.link
	cache.usable = true

	PasslootBiSTT:ClearLines()
	PasslootBiSTT:SetHyperlink(item.link)
	local ttName = PasslootBiSTT:GetName()
	for Index = 1, PasslootBiSTT:NumLines() do
		cache.Left[Index]  = getLine(_G[ttName .. "TextLeft" .. Index])
		cache.Right[Index] = getLine(_G[ttName .. "TextRight" .. Index])
	end
end

function PasslootBiS:GetItemEvaluation(item, RollID)
	initCache()
	if not item or not item.link then
		print("failed")
		return
	end
	local cache = PasslootBiS.EvalCache
	if not (cache[item.link] and cache[item.link]["expiresAt"] > GetTime()) or cache[item.link].result == nil then
		if PasslootBiS:ValidateItemObj(item) then
			local r, m = PasslootBiS:EvaluateItem(item, RollID)
			-- Full TTL only for a GetItemInfo-resolved item. If we evaluated on the
			-- link-derived id/name alone (GetItemInfo still cold -- the roll path's
			-- retries ran out), the stat-based rules saw no data, so keep the result
			-- only briefly and re-evaluate next time, once the client has the item.
			local ttl = item.infoResolved and self.db.profile.CacheExpires or 5
			cache[item.link] = {
				["itemObj"] = item,
				["result"] = r,
				["match"] = m,
				["expiresAt"] = GetTime() + ttl
			}
		else
			cache[item.link] = { ["itemObj"] = item, ["result"] = nil, ["match"] = -1, ["expiresAt"] = GetTime() + 5 }
		end
	end
	return cache[item.link]["result"], cache[item.link]["match"]
end

function PasslootBiS:ValidateItemObj(itemObj)
	return itemObj.name and itemObj.id and itemObj.link
end
