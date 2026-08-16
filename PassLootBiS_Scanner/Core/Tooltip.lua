--[[ Tooltip.lua -- annotate item tooltips with the stat-weight score.

On hover over a piece of gear, show its stat-weight score in the top-right of the
tooltip. If the item is NOT currently equipped, also show an up/down arrow vs. the
equipped item it would replace (the worst-scoring item in that slot group -- the
one you'd actually swap out, mirroring the loot-roll compare, §6.2).

Both sides are read through LibScaledStats: the hovered item off the already-shown
tooltip (as the client rendered it), the equipped item off SetInventoryItem.

The decision logic (which arrow, what colour, the score text) is PURE and
offline-tested; the tooltip hooks are guarded so the file loads under bare lua5.1.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
	_G.PLBiSScanner = ns
end

local Tooltip = {}
ns.Tooltip = Tooltip

-- Glyphs + colours. ▲/▼ render in the stock 3.3.5 font (used by Pawn/RatingBuster).
Tooltip.UP   = "|cff20ff20\226\150\178|r"   -- green ▲
Tooltip.DOWN = "|cffff3030\226\150\188|r"   -- red ▼
-- Inline colour codes for the composed annotation. The score is ALWAYS blue; the
-- diff-vs-equipped number is green (better) / red (worse) / grey (sidegrade/none).
Tooltip.BLUE      = "|cff3f9dff"   -- score colour (blue)
Tooltip.DIFF_UP   = "|cff20ff20"   -- diff better (green)
Tooltip.DIFF_DOWN = "|cffff3030"   -- diff worse (red)
Tooltip.DIFF_ZERO = "|cff999999"   -- diff zero / within epsilon (grey)
local RESET = "|r"
local COLOR_NEU = { 0.90, 0.90, 0.60 }   -- FontString base (segments carry their own codes)

-- Round a score for display.
local function fmtScore(score)
	return tostring(math.floor((tonumber(score) or 0) + 0.5))
end
Tooltip.fmtScore = fmtScore

-- Signed, rounded diff string: "+300", "-200", or "0" (symmetric rounding).
local function fmtDiff(d)
	d = tonumber(d) or 0
	d = (d >= 0) and math.floor(d + 0.5) or -math.floor(-d + 0.5)
	if d == 0 then return "0" end
	return string.format("%+d", d)
end
Tooltip.fmtDiff = fmtDiff

-- PURE: decide the top-right annotation, composed as
--   <blue score>  <coloured diff-vs-equipped>  <up/down arrow>
-- so you read the item's own score (blue), how much better/worse it is than what
-- you'd replace (green/red/grey number), and the at-a-glance arrow.
--   score        : the hovered item's stat-weight score
--   equippedScore: worst equipped score in the item's slot group (nil if unknown)
--   isEquipped   : true if the hovered item is the one you're already wearing
--   epsilon      : ignore |delta| <= epsilon as a sidegrade (no arrow); default 0
-- Returns: text (with colour codes), r, g, b  -- the base colour for the FontString
-- (each segment already carries its own inline colour, so base is neutral).
function Tooltip.annotation(score, equippedScore, isEquipped, epsilon)
	local scoreSeg = Tooltip.BLUE .. fmtScore(score) .. RESET
	epsilon = tonumber(epsilon) or 0

	-- Equipped item, or nothing to compare against -> score only (blue).
	if isEquipped or equippedScore == nil then
		return scoreSeg, COLOR_NEU[1], COLOR_NEU[2], COLOR_NEU[3]
	end

	local s = tonumber(score) or 0
	local e = tonumber(equippedScore) or 0
	if e < 0 then e = 0 end   -- empty slot: compare against nothing (diff == score)
	local delta = s - e

	local diffColor, arrow
	if delta > epsilon then
		diffColor, arrow = Tooltip.DIFF_UP, " " .. Tooltip.UP
	elseif delta < -epsilon then
		diffColor, arrow = Tooltip.DIFF_DOWN, " " .. Tooltip.DOWN
	else
		diffColor, arrow = Tooltip.DIFF_ZERO, ""   -- sidegrade: coloured number, no arrow
	end

	local diffSeg = diffColor .. fmtDiff(delta) .. RESET
	return scoreSeg .. "  " .. diffSeg .. arrow, COLOR_NEU[1], COLOR_NEU[2], COLOR_NEU[3]
end

-- PURE: item id out of a link/string ("item:12345:..." -> 12345). For deciding
-- whether the hovered item is the same as what's equipped in the slot.
function Tooltip.itemId(link)
	if type(link) ~= "string" then return nil end
	return tonumber(link:match("item:(%d+)"))
end

-- PURE: a cheap scalar signature of everything the active weights derive from.
-- ns.getActiveWeights (currentWeights) returns a FRESH copy each call (it folds in
-- the CoA Power stat via SpecWeights.withPower), so table identity can't tell us
-- when the weights actually changed. Instead we compare this signature of the four
-- inputs that vary -- per-character class/spec + account-wide power mode/weight --
-- and rebuild the equipped-score cache only when it changes.
function Tooltip.weightsSignature(chardb, db)
	return table.concat({
		tostring(chardb and chardb.class),
		tostring(chardb and chardb.spec),
		tostring(db and db.powerMode),
		tostring(db and db.powerWeight),
	}, "\1")
end

-- PURE: score every slot in a group, memoized. `cache` maps slotId -> score;
-- `computeSlot(slotId)` produces the score on a miss (the caller injects the real
-- SetInventoryItem tooltip scan). computeSlot runs at most ONCE per slotId until the
-- cache is cleared. This is the fix for #2: the equipped-side scores depend only on
-- (equipped gear, active weights), never on the hovered item, yet the hook used to
-- re-scan them on every hovered tooltip -- measured as this addon's #1 dungeon CPU
-- cost (a full equipped rescan per loot/bag/vendor tooltip the client renders).
function Tooltip.equippedScores(slotIds, cache, computeSlot)
	local scores = {}
	for i = 1, #slotIds do
		local slotId = slotIds[i]
		local s = cache[slotId]
		if s == nil then
			s = computeSlot(slotId)
			cache[slotId] = s
		end
		scores[i] = s
	end
	return scores
end

-- Everything below touches the WoW API.
if not rawget(_G, "CreateFrame") then
	return Tooltip
end

local Score = ns.Score
local Slots = ns.Slots
local Filter = ns.Filter

-- Equipped-side score cache (see Tooltip.equippedScores / #2). Memoizes the worst-
-- equipped scan per slot so it runs once per (gear, weights) instead of once per
-- hovered tooltip. Invalidated on PLAYER_EQUIPMENT_CHANGED (gear changed) and when
-- the weights signature changes (spec / CoA Power setting changed).
local equippedCache = {}
local cacheSig = nil
local function wipeEquippedCache() equippedCache = {} end
ns.invalidateEquippedScoreCache = wipeEquippedCache   -- exposed for other modules

-- Is the hovered item currently equipped in one of its slots? (match by item id,
-- so a scaled instance still counts as "the same item").
local function isEquippedItem(itemId, slotIds)
	if not itemId then return false end
	for _, slotId in ipairs(slotIds) do
		local eqLink = GetInventoryItemLink("player", slotId)
		if eqLink and Tooltip.itemId(eqLink) == itemId then
			return true
		end
	end
	return false
end

-- Set the tooltip's top-right (line 1) text -- the "upper right portion".
-- Idempotent: if the same annotation is already shown, leave the FontString alone
-- and report "no change", so the caller can skip the tt:Show() width recompute.
-- That re-layout is exactly what makes the tooltip "shake" when something else
-- re-renders it every frame (e.g. near an open auction house). Returns true only
-- when the text actually changed.
local function setTopRight(tt, text, r, g, b)
	local rt = _G[tt:GetName() .. "TextRight1"]
	if not rt then return false end
	if rt:IsShown() and rt:GetText() == text then return false end
	rt:SetText(text)
	rt:SetTextColor(r or 1, g or 1, b or 1)
	rt:Show()
	return true
end

-- Remember the annotation we last put on a tooltip, so a re-fire of
-- OnTooltipSetItem for the SAME item can restore it without re-scoring. One
-- table per tooltip frame, mutated in place (GameTooltip and ItemRefTooltip are
-- annotated independently, so this cannot be a module-level single slot).
local function rememberAnnotation(tt, link, text, r, g, b)
	local memo = tt.plbisAnnotation
	if not memo then memo = {}; tt.plbisAnnotation = memo end
	memo.link, memo.text, memo.r, memo.g, memo.b = link, text, r, g, b
end

-- The hook body: score the hovered gear and annotate.
local function annotate(tt)
	local db = ns.db
	if not db or not db.tooltip then return end
	local getStats = ns.getScaledStats
	local ScaledStats = getStats and getStats()
	if not ScaledStats then return end
	local weights = ns.getActiveWeights and ns.getActiveWeights()
	if not weights then return end   -- no spec picked yet -> stay quiet

	local _, link = tt:GetItem()
	if not link then return end

	-- One *scoring pass* per item per mouseover. While the auction house is open,
	-- something re-drives item tooltips every frame (re-firing OnTooltipSetItem
	-- and/or re-Show()ing them); re-running our score + width recompute each frame
	-- makes the tooltip visibly SHAKE and needlessly burns CPU. So if we've already
	-- scored this exact item on this tooltip, reuse the annotation we composed.
	--
	-- Reuse, NOT skip. Some hosts re-drive the tooltip by calling its setter again
	-- (GameTooltip:SetGuildBankItem, ContainerFrameItemButton_OnEnter, ...), and a
	-- setter starts by CLEARING every line -- including the top-right FontString we
	-- annotated -- before re-firing OnTooltipSetItem. Returning early there left the
	-- score wiped for as long as the cursor stayed put: it appeared once and then
	-- vanished. The web-shop "Personal Bank" (a personal vault rendered through the
	-- stock guild-bank UI) does exactly this; a bag addon that sets the tooltip once
	-- on enter does not, which is why the same item scored fine in the backpack.
	--
	-- Re-applying is cheap and stays shake-free because setTopRight is idempotent:
	-- when the text survived it reports "no change" and we skip the tt:Show() width
	-- recompute, so the AH case behaves exactly as before. Only an actual wipe costs
	-- a re-layout, and there the host just rebuilt the whole tooltip anyway.
	--
	-- The memo is set only after a successful annotation (below) -- so a first hover
	-- where GetItemInfo hasn't cached yet stays retryable -- and cleared when the
	-- tooltip hides (OnHide hook below), so moving to another item re-scores.
	local memo = tt.plbisAnnotation
	if memo and memo.link == link and memo.text then
		if setTopRight(tt, memo.text, memo.r, memo.g, memo.b) then
			tt:Show()
		end
		return
	end

	local _, _, _, _, _, itemType, subType, _, equipLoc = GetItemInfo(link)
	local slotIds = Slots.slotsFor(equipLoc)
	if not slotIds then return end   -- not a scannable gear slot

	-- Per-character armor/weapon filter: an excluded category shows a plain 0 with no
	-- upgrade arrow (it never counts as an upgrade), matching the loot-roll behavior.
	local excluded = Filter and not Filter.isScored(itemType, subType, ns.chardb and ns.chardb.filter, equipLoc)

	-- Hovered item's score, read off the tooltip the client already rendered.
	local stats = ScaledStats:ParseShownTooltip(tt, subType, equipLoc)
	local score = excluded and 0 or Score.scoreItem(stats, weights)

	local itemId = Tooltip.itemId(link)
	local equipped = isEquippedItem(itemId, slotIds)

	-- The replacement target: weapons/off-hands use the loadout rule (1H vs 2H, dual
	-- wield) shared with the roll compare; everything else is the worst equipped in
	-- the slot group (§6.2).
	local worst
	if not equipped and not excluded then
		worst = ns.weaponEquippedValue and ns.weaponEquippedValue(equipLoc, weights)
		if worst == nil then
			-- Rebuild the equipped cache if the active weights changed (spec / Power).
			-- Gear changes clear it via PLAYER_EQUIPMENT_CHANGED (hook below). The
			-- scan is DPS-routed by the hovered subType/equipLoc, but that routing is
			-- constant per slot group here (weapons short-circuit via
			-- weaponEquippedValue; only ranged folds DPS, always as "rangedDps"), so
			-- slotId alone is a sufficient cache key.
			local sig = Tooltip.weightsSignature(ns.chardb, ns.db)
			if sig ~= cacheSig then wipeEquippedCache(); cacheSig = sig end
			local scores = Tooltip.equippedScores(slotIds, equippedCache, function(slotId)
				local eStats = ScaledStats:GetStatsWithDps("SetInventoryItem", subType, equipLoc, "player", slotId)
				return Score.scoreItem(eStats, weights)
			end)
			worst = Slots.worstEquipped(scores)
		end
	end

	local text, r, g, b = Tooltip.annotation(score, worst, equipped)
	if setTopRight(tt, text, r, g, b) then
		tt:Show()   -- recompute width only when the annotation actually changed
	end
	-- Scored successfully: remember the composed annotation so re-fires this
	-- mouseover re-apply it (idempotently) instead of re-scoring.
	rememberAnnotation(tt, link, text, r, g, b)
end

-- Guard against re-entrancy from our own :Show()/SetText.
local busy = false
local function safeAnnotate(tt)
	if busy then return end
	busy = true
	pcall(annotate, tt)
	busy = false
end

-- On the auction house, some addons draw the cached (nominal) item body, fire
-- OnTooltipSetItem, and only THEN overwrite the stat lines with the listing's
-- TRUE server values -- e.g. the Auctionator-Ascension-Finder fork's list rows
-- call SetHyperlink (cached) and then replay the captured server tooltip over it.
-- Parsing inside OnTooltipSetItem would read the pre-replay nominal lines. So when
-- the AuctionFrame is open we defer the parse to the next frame, by which point
-- both paths have settled: Blizzard's Browse tab (SetAuctionItem -- already true)
-- and a fork's list (true lines now painted over the cached body). One shared
-- one-shot OnUpdate frame carries the pending tooltip; tooltips elsewhere annotate
-- immediately with no delay.
local deferFrame
local function scheduleDeferred(tt)
	if not deferFrame then
		deferFrame = CreateFrame("Frame")
		deferFrame:Hide()
		deferFrame:SetScript("OnUpdate", function(self)
			self:Hide()   -- one-shot: stop ticking until re-armed
			local pending = self.tt
			self.tt = nil
			-- Skip if the cursor has moved off (tooltip hidden); annotate re-reads
			-- GetItem(), so it acts on whatever the tooltip actually holds now.
			if pending and pending:IsShown() then safeAnnotate(pending) end
		end)
	end
	deferFrame.tt = tt
	deferFrame:Show()   -- fires OnUpdate on the next frame, then hides itself
end

-- Is this tooltip owned by the auction-house UI (a Browse listing button, or a
-- fork Finder-list row -- both parented under AuctionFrame)? Only those get the
-- true-lines-after-the-event replay that the one-frame defer exists to catch.
-- A bag/inventory/merchant tooltip hovered WHILE the AH is open is NOT such a
-- tooltip: its stats are already correct synchronously, so deferring it just adds
-- a one-frame width lag that reads as the tooltip "shaking" whenever the client
-- re-renders it. Walk the owner chain to AuctionFrame to tell them apart.
local function ownedByAuctionUI(tt)
	local af = rawget(_G, "AuctionFrame")
	if not (af and af:IsShown()) then return false end
	local owner = tt.GetOwner and tt:GetOwner()
	local guard = 0
	while owner and guard < 60 do
		if owner == af then return true end
		owner = owner.GetParent and owner:GetParent() or nil
		guard = guard + 1
	end
	return false
end

-- Hook the common item tooltips. OnTooltipSetItem fires after the item is drawn.
-- Defer only for auction-house tooltips (see above); annotate inline everywhere
-- else -- including bag items while the AH is open.
local function onTooltipSetItem(tt)
	if ownedByAuctionUI(tt) then
		scheduleDeferred(tt)
	else
		safeAnnotate(tt)
	end
end

-- Clear the once-per-mouseover memo when the tooltip hides, so the next hover
-- (even of the same item) re-scores. Moving the cursor between items hides the
-- tooltip in between, which is exactly the boundary we want.
local function onTooltipHide(tt)
	tt.plbisAnnotation = nil
end

GameTooltip:HookScript("OnTooltipSetItem", onTooltipSetItem)
GameTooltip:HookScript("OnHide", onTooltipHide)
if _G.ItemRefTooltip then
	ItemRefTooltip:HookScript("OnTooltipSetItem", onTooltipSetItem)
	ItemRefTooltip:HookScript("OnHide", onTooltipHide)
end

-- Drop the equipped-score cache whenever the player's gear changes, so the next
-- hover re-scans the new equipped item (weights changes are caught inline by the
-- signature check in annotate).
local invFrame = CreateFrame("Frame")
invFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
invFrame:SetScript("OnEvent", wipeEquippedCache)

return Tooltip
