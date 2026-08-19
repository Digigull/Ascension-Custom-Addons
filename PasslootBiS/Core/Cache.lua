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

-- `where` is the line's position as "L3"/"R1" -- left or right column, 1-based --
-- and is only used to label a red line for the trace (see below).
local function getLine(Line, where)
	if Line then
		local text = Line:GetText()
		local Red, Green, Blue, Alpha = Line:GetTextColor()
		if ColorCheck(Red, Green, Blue, Alpha) then
			local cache = PasslootBiS.TooltipCache
			cache.usable = false
			-- Keep the FIRST red line, with its position, for the trace. "Unusable" here
			-- is an inference from a colour, so a trace that prints only the verdict cannot
			-- be checked: a Dire Maul run (2026-08) ruled a pair of leather boots unusable
			-- on a leather-wearing character and left nothing to say which requirement the
			-- client had painted red. Modules/Usable.lua appends this to its trace line.
			--
			-- The position is worth having because the text alone does not say what KIND
			-- of refusal this is. Measured examples (owner, 2026-08):
			--   R4 Mail   -- an armour class you cannot wear. The armour type sits in the
			--                RIGHT column of the armour line, and the client reddens just
			--                that word. This is the commonest refusal by far.
			--
			-- SUPERSEDED, and worth stating because the wrong version was written down
			-- first: the guess was that a client refusal lives in the left column near the
			-- top and that a right-column red implied some addon had bolted a line on. The
			-- very first measurement was R4, so the column says nothing about the source.
			-- Nothing else hooks this tooltip anyway -- it is our own hidden PasslootBiSTT
			-- (Libs/Libs.xml), and the BiS Scanner annotates GameTooltip/ItemRefTooltip
			-- only, in a base colour the red test cannot see.
			--
			-- First red line rather than last, because later reds are usually knock-on: a
			-- missing profession reddens the "Requires" line and the recipe's spell line.
			if not cache.unusableLine then
				cache.unusableLine = (where and (where .. " ") or "") .. (text or "")
			end
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
	cache.unusableLine = nil

	PasslootBiSTT:ClearLines()
	PasslootBiSTT:SetHyperlink(item.link)
	local ttName = PasslootBiSTT:GetName()
	for Index = 1, PasslootBiSTT:NumLines() do
		cache.Left[Index]  = getLine(_G[ttName .. "TextLeft" .. Index], "L" .. Index)
		cache.Right[Index] = getLine(_G[ttName .. "TextRight" .. Index], "R" .. Index)
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
