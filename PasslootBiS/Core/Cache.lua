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

-- How many red lines to keep. More than one matters: a red line can sit behind
-- another, and each extra round trip to find that out costs a whole play session.
local MAX_RED_LINES = 5

-- `where` is the line's position as "L3"/"R1" -- left or right column, 1-based --
-- and is only used to label a red line for the trace (see below).
local function getLine(Line, where)
	if Line then
		local text = Line:GetText()
		-- EMPTY LINES STATE NO REQUIREMENT, whatever colour they are left in, and this
		-- guard is the whole reason the check works. GameTooltip reuses its FontStrings:
		-- ClearLines() hides them but does NOT reset their colour, so a string another
		-- item left red still answers red through GetTextColor() when the current item
		-- leaves it blank. Reading that as "unusable" made the Not Usable rule greed
		-- items the player could plainly wear -- a pair of leather boots on a leather
		-- wearer, intermittently, depending only on what had been scanned before them.
		--
		-- It stayed hidden for so long because the symptom is invisible from the outside:
		-- Not Usable and Catch All both greed, so the wrong rule reached the right
		-- outcome. What caught it was the capture below printing "red line: R4 " with
		-- nothing after the position (owner, 2026-08).
		if text and text ~= "" then
			local Red, Green, Blue, Alpha = Line:GetTextColor()
			if ColorCheck(Red, Green, Blue, Alpha) then
				local cache = PasslootBiS.TooltipCache
				cache.usable = false
				-- Keep the red lines, with their positions, for the trace. "Unusable" here
				-- is an inference from a colour, so a report that prints only the verdict
				-- cannot be checked -- which is exactly how the blank-line bug above
				-- survived. Measured vocabulary so far:
				--   R4 Mail  -- an armour class you cannot wear. The armour TYPE sits in the
				--              right column of the armour line and the client reddens just
				--              that word.
				-- (Superseded guess, recorded because it is the one someone re-derives: that
				-- a client refusal lives in the left column and a right-column red meant an
				-- addon had added the line. The first measurement was R4. The column says
				-- nothing about the source, and nothing else hooks this tooltip anyway.)
				local reds = cache.unusableLines
				if reds and #reds < MAX_RED_LINES then
					reds[#reds + 1] = (where and (where .. " ") or "") .. text
				end
			end
		end
		return text and text or ""
	else
		return ""
	end
end

-- The red lines behind an "unusable" verdict, as one string, or nil if the item is
-- usable. Shared so the trace line (Modules/Usable.lua) and the item dry run
-- (Core/DebugReport.lua) can never describe the same verdict differently.
function PasslootBiS:UnusableReason()
	local reds = self.TooltipCache and self.TooltipCache.unusableLines
	if not (reds and #reds > 0) then return nil end
	return table.concat(reds, " | ")
end

function PasslootBiS:BuildTooltipCache(item)
	initCache()
	if not item or not item.link then return end
	local cache = PasslootBiS.TooltipCache
	if item.link == cache.link then return end
	cache.Left, cache.Right = {}, {}
	cache.link = item.link
	cache.usable = true
	cache.unusableLines = {}

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
