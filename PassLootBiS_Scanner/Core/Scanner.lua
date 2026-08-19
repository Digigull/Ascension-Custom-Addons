--[[ Scanner.lua -- event wiring, on/off toggle, slash commands, and the compare
flow. This is the addon's live half; everything scoring/parsing lives in the pure
cores and LibScaledStats-1.0.

Flow on START_LOOT_ROLL(rollID), only when toggled on (DESIGN §6.1), all inside a
pcall so a scan error can never interfere with the actual roll:
  1. link -> item slot(s) via Slots.
  2. score the roll item (stats + weapon DPS, read through the library).
  3. score the equipped item(s) in that slot; take the worst (the one you'd replace).
  4. if the roll beats it by >= threshold (or the slot is empty), fire the alert.
  5. (guarded) add a high-value flag from the Auctionator fork if present.

Guarded: under bare lua5.1 this file defines the namespace and returns without
touching the WoW API, so the pure cores still self-test.
]]

local _, ns = ...
if type(ns) ~= "table" then
	ns = rawget(_G, "PLBiSScanner") or {}
end
-- Publish the namespace UNCONDITIONALLY. In-game `...` hands every file of an
-- addon the same private addon table, so `type(ns) == "table"` is always true and
-- the assignment used to sit inside the branch above -- meaning _G.PLBiSScanner
-- only ever existed under bare lua5.1, where `...` carries no table. Everything
-- documented as "reachable as _G.PLBiSScanner..." (this file's API, the host's
-- status panel) was therefore invisible to other addons in the client and only
-- worked offline. Every file shares this one table, so publishing it here covers
-- the whole addon.
_G.PLBiSScanner = ns

-- Under bare lua5.1 there is no client; stop before any API use.
if not rawget(_G, "CreateFrame") then
	return
end

local Score       = ns.Score
local Slots       = ns.Slots
local SpecWeights = ns.SpecWeights
local Filter      = ns.Filter
local Alert       = ns.Alert
local Auctionator = ns.Auctionator
local Verdict     = ns.Verdict
local WonLedger   = ns.WonLedger
local ItemLink    = ns.ItemLink

local ScaledStats  -- resolved from LibStub at login

----------------------------------------------------------------------
-- SavedVariables + defaults
----------------------------------------------------------------------

local DEFAULTS = {
	enabled       = true,
	threshold     = 0.03,   -- +3% minimum delta to call an upgrade (§6.3)
	-- class/spec are PER-CHARACTER (a character is exactly one class); they live in
	-- chardb, not here -- see initCharDB. Kept out of the account-wide DEFAULTS.
	useChat       = true,
	useFrame      = false,  -- floating frame off by default; chat is the safe minimum
	useSound      = false,  -- cue on ANY upgrade -- the threshold above is the cutoff
	useSoundGold  = false,  -- cue on the high-value flag -- goldThreshold is its cutoff
	tooltip       = true,   -- annotate item tooltips with score + upgrade arrow
	goldThreshold = 500000, -- 50g in copper, for the Auctionator flag (Phase 4)
	-- Score equipped gear WITHOUT its enchants, so a fresh drop is compared like for
	-- like (ns.equippedStats has the full why, including why this is off by default).
	ignoreEnchants = false,
	powerMode     = "off",  -- score a CoA flat Power stat: "off" | "pve" | "pvp"
	powerWeight   = 1,      -- weight per point of the chosen Power (tunable in GUI)
	-- minimap = { angle, hide } and options = { point, x, y } are seeded in
	-- initDB() (nested tables, kept out of the flat DEFAULTS copy loop).
}

local db   -- PassLootBiS_ScannerDB, populated on ADDON_LOADED
local chardb   -- PassLootBiS_ScannerCharDB (per-character), populated on ADDON_LOADED
local warnedNoWeights = false
local warnedPlaceholder = false

local function chat(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PLBiS|r " .. msg)
end

local function initDB()
	if type(PassLootBiS_ScannerDB) ~= "table" then PassLootBiS_ScannerDB = {} end
	db = PassLootBiS_ScannerDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	-- Nested tables get per-field seeding so an older saved DB still gains any
	-- newly-added field (and so we never alias the DEFAULTS table).
	if type(db.minimap) ~= "table" then db.minimap = {} end
	if db.minimap.angle == nil then db.minimap.angle = 220 end   -- degrees around the ring
	if db.minimap.hide  == nil then db.minimap.hide  = false end
	if type(db.options) ~= "table" then db.options = {} end
	ns.db = db   -- share with sibling modules (Tooltip, MinimapButton, Options)
end

-- Per-character store (## SavedVariablesPerCharacter). Holds the armor/weapon
-- inclusion filter so each character keeps its own picks; account-wide settings
-- (spec, toggles, thresholds) stay in `db`. Empty tables mean "include everything"
-- (Filter treats absent keys as included), so a fresh character scans as before.
local function initCharDB()
	if type(PassLootBiS_ScannerCharDB) ~= "table" then PassLootBiS_ScannerCharDB = {} end
	chardb = PassLootBiS_ScannerCharDB
	if type(chardb.filter) ~= "table" then chardb.filter = {} end
	if type(chardb.filter.armor) ~= "table" then chardb.filter.armor = {} end
	if type(chardb.filter.weapons) ~= "table" then chardb.filter.weapons = {} end
	-- Dual-wield off-hand DPS factor (0..1): how much a second one-hander's DPS
	-- counts toward the combined weapon score. 0.5 mirrors WoW's off-hand penalty.
	if chardb.dwOffhandDps == nil then chardb.dwOffhandDps = 0.5 end
	-- Class/spec are per-character: a character is exactly one class, and you pick a
	-- spec per character. (They used to sit in the account-wide db, so every alt
	-- shared one spec.) Migrate a legacy account-wide pick to this character once,
	-- so an existing single-character user doesn't have to re-select. Absent keys
	-- stay nil -> a fresh character scans nothing until it picks a spec (as before).
	if chardb.class == nil and db and db.class then
		chardb.class = db.class
		chardb.spec  = db.spec
	end
	ns.chardb = chardb   -- share with Tooltip + Options (the filter window)
end

-- The current character's filter table, or nil (Filter treats nil as include-all).
local function charFilter() return ns.chardb and ns.chardb.filter end

----------------------------------------------------------------------
-- Weights selection
----------------------------------------------------------------------

local function currentWeights()
	if not db or not chardb then return nil end
	local data = rawget(_G, "PLBiSScannerWeights")
	if type(data) ~= "table" then return nil end
	-- Convenience: inherit spec from an imported PLBIS1 list if the user hasn't
	-- picked one and PasslootBiS exposes it (§5.4). Guarded, optional. Per-character.
	if (not chardb.class or not chardb.spec) then
		local host = rawget(_G, "PasslootBiS")
		if host and host.API and host.API.GetImportedSpec then
			local ok, cls, spc = pcall(host.API.GetImportedSpec)
			if ok and cls and spc then chardb.class, chardb.spec = cls, spc end
		end
	end
	local w = SpecWeights.get(data, chardb.class, chardb.spec)
	if not w then return nil end
	-- Fold in the user's chosen CoA Power stat (pvePower/pvpPower), if any. Returns
	-- a copy, so the shared spec weights are never mutated.
	return SpecWeights.withPower(w, db.powerMode, db.powerWeight)
end

-- Shared with sibling modules (Tooltip.lua): the active weights + library handle.
ns.getActiveWeights = currentWeights
ns.getScaledStats = function() return ScaledStats end

-- Single validate-and-set path for the active spec, shared by the /plbisscan
-- spec command AND the Options window's class/spec dropdowns, so both go through
-- exactly the same matching (SpecWeights, already offline-tested). `class` and
-- `spec` may be any case; on success chardb.class/chardb.spec are set to the
-- canonical names (per-character). Returns ok, canonicalClass, canonicalSpec.
function ns.setSpec(class, spec)
	local data = rawget(_G, "PLBiSScannerWeights")
	local c = SpecWeights.matchClass(data, class)
	local s = c and SpecWeights.matchSpec(data, c, spec)
	if c and s then
		if chardb then chardb.class, chardb.spec = c, s end
		return true, c, s
	end
	return false
end

----------------------------------------------------------------------
-- BiS-list membership + the run's win ledger (BiS Check)
----------------------------------------------------------------------
-- The BiS list belongs to PasslootBiS, not to us. Two ways to reach the answer,
-- in order of trust:
--   1. the roll ctx the host puts on the advisor call -- authoritative, already
--      computed, and the only one available mid-roll for free;
--   2. host.API:IsBiSItem(id, name) -- for the scanner's own alert path, which is
--      driven off a link with no ctx anywhere near it.
-- Both guarded: PasslootBiS is an OptionalDep, so with no host at all this simply
-- answers false and BiS Check never fires (there is no BiS list to be stale).

local function itemIdFromLink(link)
	if type(link) ~= "string" then return nil end
	local id = link:match("|Hitem:(%d+)")
	return id and tonumber(id) or nil
end

function ns.isBiSItem(link, name, ctx)
	if type(ctx) == "table" and ctx.isBiS ~= nil then
		return ctx.isBiS and true or false
	end
	local host = rawget(_G, "PasslootBiS")
	if not (host and host.API and type(host.API.IsBiSItem) == "function") then
		return false
	end
	local ok, isBiS = pcall(host.API.IsBiSItem, host.API, itemIdFromLink(link), name)
	return (ok and isBiS) and true or false
end

-- Loot-message patterns, built once at login from the client's own globals so the
-- match follows whatever locale is running. Order matters -- see WonLedger.
local lootPatterns

local function buildLootPatterns()
	if lootPatterns then return lootPatterns end
	lootPatterns = {}
	-- The "...x3." stacked forms MUST come first: the plain form's (.+) would
	-- otherwise capture the count along with the link.
	local formats = {
		rawget(_G, "LOOT_ITEM_SELF_MULTIPLE"),
		rawget(_G, "LOOT_ITEM_PUSHED_SELF_MULTIPLE"),
		rawget(_G, "LOOT_ITEM_SELF"),
		rawget(_G, "LOOT_ITEM_PUSHED_SELF"),
	}
	for i = 1, #formats do
		local p = WonLedger and WonLedger.toPattern(formats[i])
		if p then lootPatterns[#lootPatterns + 1] = p end
	end
	return lootPatterns
end

-- Record an item that just entered YOUR bags, so the rest of the run compares
-- against it. Deliberately hooked on receipt rather than on winning a roll: master
-- loot, personal loot and a free-for-all pickup all end the same way, and this
-- catches every route in one place.
--
-- An item with no equipLoc (trash, reagents, quest items) scores nothing and is
-- dropped by WonLedger.record, so no filtering is needed here.
local function recordWin(link)
	if not (WonLedger and ScaledStats) then return end
	local weights = currentWeights()
	if not weights then return end
	local name, _, _, _, _, _, subType, _, equipLoc = GetItemInfo(link)
	if not equipLoc or equipLoc == "" then return end
	if not Slots.slotsFor(equipLoc) then return end
	local stats = ScaledStats:GetStatsWithDps("SetHyperlink", subType, equipLoc, link)
	WonLedger.record(equipLoc, Score.scoreItem(stats, weights), link, name)
end

----------------------------------------------------------------------
-- The compare flow
----------------------------------------------------------------------

-- Read an item's full stats (armor + secondaries + weapon DPS) through the
-- library, so both sides of the compare use the same path.
local function scoreRollItem(rollID, weights, subType, equipLoc)
	local stats = ScaledStats:GetStatsWithDps("SetLootRollItem", subType, equipLoc, rollID)
	return Score.scoreItem(stats, weights), stats
end

-- THE one place equipped stats are read. Three callers had their own copy of this
-- line (here, evalHand, and Core/Tooltip.lua's hover compare); the option below has
-- to reach all three or the tooltip and the roll would quote different numbers for
-- the same item.
--
-- An empty slot -> no lines -> empty stats -> score 0 (always beatable).
--
-- db.ignoreEnchants: score the equipped item WITHOUT its enchant, by scanning its
-- link with the enchant field zeroed (Core/ItemLink.lua). The comparison is
-- otherwise unfair in a way that always points the same direction: a loot roll is
-- a fresh drop with no enchant on it, your equipped item has one, so the equipped
-- side scores high and real upgrades read as smaller than they are (or as
-- downgrades, which is what BiS Check would then veto).
--
-- Gems are deliberately left in. They are the same kind of player investment and
-- the same argument applies, but the owner asked about enchants; stripping sockets
-- as well would change more scores than were asked about, and it is one extra field
-- set away (ItemLink.FIELD_ENCHANT_AND_GEMS) whenever that is wanted.
--
-- OFF by default, and this is the important part: it moves the equipped read from
-- SetInventoryItem (your real instance) to SetHyperlink, which LibScaledStats
-- warns "MAY be cached-first / nominal for scaled instances". On Ascension that is
-- precisely the lie the whole library exists to route around, so trading a known
-- enchant skew for a possible scaled-stat skew is not a trade to make blind.
-- /plbisdebug reports the three numbers side by side (see API:GetEnchantCheck) so
-- it can be checked on real gear before being trusted.
function ns.equippedStats(slotId, subType, equipLoc)
	if db and db.ignoreEnchants then
		local link = GetInventoryItemLink("player", slotId)
		local stripped = link and ItemLink and ItemLink.stripEnchant(link)
		if stripped then
			return ScaledStats:GetStatsWithDps("SetHyperlink", subType, equipLoc, stripped)
		end
		-- No link, or a link we could not parse: fall through to the real instance
		-- rather than scoring the slot as empty.
	end
	return ScaledStats:GetStatsWithDps("SetInventoryItem", subType, equipLoc, "player", slotId)
end

local function scoreEquipped(slotId, weights, subType, equipLoc)
	return Score.scoreItem(ns.equippedStats(slotId, subType, equipLoc), weights)
end

-- Evaluate one equipped hand slot for the weapon-loadout compare: its score, the
-- DPS-weighted portion of that score (so the off-hand penalty can discount just the
-- DPS), and whether it's a two-hander / a weapon at all.
local function evalHand(slotId, weights)
	local link = GetInventoryItemLink("player", slotId)
	if not link then
		return { score = 0, dpsW = 0, is2H = false, isWeapon = false }
	end
	local _, _, _, _, _, itemType, subType, _, eqLoc = GetItemInfo(link)
	local stats = ns.equippedStats(slotId, subType, eqLoc)
	local score = Score.scoreItem(stats, weights)
	local dpsW = (stats.weaponDps or 0) * (weights.weaponDps or 0)   -- DPS-weighted part
	return {
		score = score,
		dpsW = dpsW,
		is2H = (eqLoc == "INVTYPE_2HWEAPON"),
		isWeapon = (itemType == "Weapon"),
	}
end

-- The equipped value a weapon roll of `equipLoc` must beat, from the live equipped
-- hands + this character's dual-wield off-hand DPS factor. Shared by the roll
-- compare and the tooltip so the two always agree. Returns nil for non-hand slots
-- (caller falls back to worst-equipped). MAINHAND=16, OFFHAND=17.
function ns.weaponEquippedValue(equipLoc, weights)
	if not Slots.isHandSlot(equipLoc) then return nil end
	local mh = evalHand(Slots.INV.MAINHAND, weights)
	local oh = evalHand(Slots.INV.OFFHAND, weights)
	local f = (chardb and chardb.dwOffhandDps) or 0.5
	-- Discount the off-hand DPS only when the off hand actually holds a weapon.
	local ohAdj = oh.isWeapon and Slots.offhandDpsAdjust(oh.score, oh.dpsW, f) or oh.score
	local canDW = (rawget(_G, "CanDualWield") and CanDualWield()) and true or false
	return Slots.weaponReplacementValue(equipLoc, canDW, mh.score, mh.is2H, ohAdj)
end

-- The score a candidate for this slot has to beat.
--
-- Split out of compareRoll so the dry run (ns.API:GetLinkVerdict) reaches the SAME
-- number a live roll would. A diagnostic that computes its own target is a
-- diagnostic that can agree with itself while disagreeing with the feature.
--
-- Weapons/off-hands use the loadout rule (1H vs 2H, dual wield); everything else
-- uses the worst equipped in the slot group (§6.2). On top of that, what you
-- already WON this run counts as equipped, or the second shoulder of a run still
-- reads as an upgrade over the shoulders you are technically still wearing
-- (Core/WonLedger.lua has the full why).
function ns.effectiveTarget(equipLoc, subType, weights, slotIds)
	local target = ns.weaponEquippedValue(equipLoc, weights)
	local wins = WonLedger and WonLedger.winsFor(equipLoc)
	if target == nil then
		local scores = {}
		for i, slotId in ipairs(slotIds) do
			scores[i] = scoreEquipped(slotId, weights, subType, equipLoc)
		end
		if wins then scores = WonLedger.applyWins(scores, wins) end
		target = Slots.worstEquipped(scores)
	elseif wins then
		-- Hand slots come back from the loadout rule as ONE already-resolved number,
		-- not a per-slot list, so the displacement model has nothing to displace.
		-- Raising the single bar is the honest approximation here: it can under-warn
		-- on a dual-wield pair (a win in one hand lifts the bar for both) but never
		-- over-warns, which is the right way round for a check whose false positive
		-- costs you an item.
		local best = WonLedger.bestFor(equipLoc)
		if best and best.score > target then target = best.score end
	end
	return target
end

-- Score vs. target -> the three verdict inputs. Also split out so the dry run and
-- the live roll cannot drift apart.
--
-- BiS Check (the third reason; see Verdict.build) is only ever raised for an item
-- the HOST says is on a currently-rolling BiS list -- a lesser item that was never
-- on your list is just loot, not a mistake worth interrupting for. It needs the
-- score to be STRICTLY below the target, not merely under the upgrade threshold:
-- an item scoring +1% against a +3% threshold is not an upgrade, but it is not a
-- downgrade either, and vetoing that roll would be wrong.
function ns.judge(rollScore, target, equipLoc, isBiS)
	local isUpgrade, delta = Score.verdict(rollScore, target, db.threshold)
	local down
	if isBiS and not isUpgrade and rollScore > 0 then
		local d = Score.deltaFraction(rollScore, target)
		if d < 0 then
			local best = WonLedger and WonLedger.bestFor(equipLoc)
			down = { delta = d, wonName = best and best.name or nil }
		end
	end
	return isUpgrade, delta, down
end

-- Shared compare core: score the rolled item vs. the worst equipped in its slot
-- group and read the optional Auctionator high-value flag. Used by BOTH the
-- scanner's own alert (evaluateRoll) and the roll-advisor verdict (ns.API), so the
-- two can never disagree. Returns a compare table, or nil if there's no roll link.
-- `scannable` is false for non-equippable slots or when no spec weights are picked
-- (then isUpgrade=false, delta=0); the gold flag is still evaluated in both cases.
-- `ctx` is the host's roll context (PasslootBiS ProcessLootRoll), present only on
-- the advisor path. Its isBiS field is the ONLY way this addon can know an item is
-- on a BiS list -- that list lives in the host's rules. On the scanner's own alert
-- path there is no ctx, so we ask the host directly through its published API.
local function compareRoll(rollID, ctx)
	local link = GetLootRollItemLink(rollID)
	if not link then return nil end

	-- Roll-frame bind status. BoP loot is soulbound the instant you win it, so it
	-- can never go on the auction house -- the "worth Need for gold" high-value flag
	-- must NOT fire for it (a BoP item has no sale value to you). GetLootRollItemInfo
	-- returns bindOnPickup as its 5th value.
	local bop
	if rawget(_G, "GetLootRollItemInfo") then
		local ok, _, _, _, _, boundOnPickup = pcall(GetLootRollItemInfo, rollID)
		if ok then bop = boundOnPickup and true or false end
	end

	local name, _, _, _, _, itemType, subType, _, equipLoc, texture = GetItemInfo(link)
	local isBiS = ns.isBiSItem(link, name, ctx)
	local slotIds = Slots.slotsFor(equipLoc)
	local weights = currentWeights()
	-- Per-character armor/weapon filter: an unchecked category scores 0 (never an
	-- upgrade). Non-filterable items (necks, rings, trinkets, ...) always score.
	local scored = (not Filter) or Filter.isScored(itemType, subType, charFilter(), equipLoc)

	local isUpgrade, delta = false, 0
	local down                    -- BiS-downgrade info for Verdict.build, or nil
	local rollScore, target
	if slotIds and weights and scored then
		rollScore = scoreRollItem(rollID, weights, subType, equipLoc)
		target = ns.effectiveTarget(equipLoc, subType, weights, slotIds)
		isUpgrade, delta, down = ns.judge(rollScore, target, equipLoc, isBiS)
	end

	-- Optional high-value flag (Phase 4; guarded -- nil if no Auctionator fork).
	-- `sellable = not bop`: a BoP win can't be auctioned, so it never counts as
	-- high-value (highValueFlag returns nil when sellable is false).
	local goldFlag
	if Auctionator then
		goldFlag = Auctionator.liveFlag(link, db.goldThreshold, not bop)
	end

	return {
		link      = link,
		name      = name,
		texture   = texture,
		equipLoc  = equipLoc,
		bop       = bop,
		isBiS     = isBiS,
		down      = down,
		scannable = (slotIds ~= nil),
		hadWeights = (weights ~= nil),
		filtered  = (slotIds ~= nil) and (not scored),  -- excluded by the char filter
		isUpgrade = isUpgrade,
		delta     = delta,
		goldFlag  = goldFlag,
	}
end

local function evaluateRoll(rollID)
	if not db.enabled then return end

	local r = compareRoll(rollID)
	if not r then return end

	-- The stat-UPGRADE path needs a scannable slot + a picked spec; warn once if a
	-- scannable item can't be scored because no weights are selected. High VALUE is
	-- independent of all that -- it is purely the last-scan AH price (BoP excluded)
	-- and fires for ANY item, equippable or not, regardless of the equip filter (a
	-- BoE weapon of any type, a recipe, a trade good). So we never return early on a
	-- goldFlag's account.
	if r.scannable and not r.hadWeights and not warnedNoWeights then
		warnedNoWeights = true
		chat("no spec weights selected -- use |cffffffff/plbisscan spec|r to pick one. Upgrade scanning is idle until then (high-value gold alerts still work).")
	end

	if not r.isUpgrade and not r.goldFlag then return end

	-- Slot label for the alert (localized global with fallback).
	local slotName = r.equipLoc and (_G[r.equipLoc] or r.equipLoc) or nil

	Alert.Show({
		itemLink = r.link,
		itemName = r.name,
		texture  = r.texture,
		slotName = slotName,
		delta    = r.isUpgrade and r.delta or nil,
		goldText = r.goldFlag and r.goldFlag.text or nil,
		isBiS    = r.isBiS, -- from the host's BiS list (§6.3); see ns.isBiSItem
	}, db)
end

----------------------------------------------------------------------
-- Roll-advisor verdict API (act-path; integration.md §5.2a)
----------------------------------------------------------------------
-- PasslootBiS's held-confirm gate pulls this per roll:
--   PLBiSScanner.API:GetRollVerdict(rollID) -> { upgrade, delta, highValue, reason }
-- (or nil to abstain). The scanner is the ONLY stat scorer -- it just answers the
-- query; PassLoot owns the popup, the hold timer, and the single RollOnLoot. The
-- scanner never rolls. Reuses compareRoll above, so the verdict can't drift from
-- the scanner's own alert.

local API = {}

function API:GetRollVerdict(rollID, ctx)
	if not db or not db.enabled then return nil end
	local r = compareRoll(rollID, ctx)
	if not r then return nil end
	-- Two independent reasons to advise a roll, with DIFFERENT scope:
	--   * stat upgrade  -- gated by the equip filter + a scannable slot + weights.
	--     compareRoll already forces isUpgrade=false for a filtered/off-material or
	--     non-equippable item, so a cloth item is never an "upgrade" for a Leather
	--     Ranger. Nothing to gate here.
	--   * high value    -- purely the last-scan AH price (BoP excluded, handled in
	--     compareRoll). This is INDEPENDENT of the character's equip filter and of
	--     equippability: a BoE weapon of any type, a recipe, a trade good worth gold
	--     is still worth greeding. So it must NOT be filter-gated.
	--   * downgrade    -- BiS Check. Set only for an item the host says is on a
	--     currently-rolling BiS list AND that scores below what it would replace
	--     (compareRoll). Unlike the two above it is a reason NOT to roll, and the
	--     host treats it as a veto rather than an invitation.
	local goldText = r.goldFlag and r.goldFlag.text or nil
	return Verdict.build(r.isUpgrade, r.delta, goldText, r.down)
end

-- DIAGNOSTIC: what would this item link do if it were rolled right now?
--
-- Exists because BiS Check is almost impossible to test on purpose -- it needs a
-- specific stale item to actually drop off a specific boss. This answers the same
-- question against any link you can shift-click, using ns.effectiveTarget and
-- ns.judge, which are the very functions the live roll path uses. If this says
-- "downgrade" then a real roll would too.
--
-- Returns a REPORT, not a verdict: the host's diagnostic wants the intermediate
-- numbers (score, target, why it was skipped) far more than the yes/no.
--   { link, name, equipLoc, scannable, hadWeights, filtered, isBiS,
--     score, target, isUpgrade, delta, down, verdict }
-- `isBiS` is passed in by the host (it owns the BiS list); nil means "ask", which
-- routes through the same ns.isBiSItem the alert path uses.
function API:GetLinkVerdict(link, isBiS)
	if type(link) ~= "string" or link == "" then return nil end
	if not ScaledStats then return nil end
	local name, _, _, _, _, itemType, subType, _, equipLoc = GetItemInfo(link)
	if not name then
		-- Cold cache: the query above is itself what starts the fill, so the caller
		-- gets a "try again" rather than a wrong answer built from nils.
		return { link = link, uncached = true }
	end
	if isBiS == nil then isBiS = ns.isBiSItem(link, name, nil) end

	local slotIds = Slots.slotsFor(equipLoc)
	local weights = currentWeights()
	local scored = (not Filter) or Filter.isScored(itemType, subType, charFilter(), equipLoc)
	local r = {
		link = link, name = name, equipLoc = equipLoc,
		scannable = (slotIds ~= nil), hadWeights = (weights ~= nil),
		filtered = (slotIds ~= nil) and (not scored),
		isBiS = isBiS and true or false,
	}
	if not (slotIds and weights and scored) then return r end

	local stats = ScaledStats:GetStatsWithDps("SetHyperlink", subType, equipLoc, link)
	r.score = Score.scoreItem(stats, weights)
	r.target = ns.effectiveTarget(equipLoc, subType, weights, slotIds)
	r.isUpgrade, r.delta, r.down = ns.judge(r.score, r.target, equipLoc, r.isBiS)
	r.verdict = Verdict.build(r.isUpgrade, r.delta, nil, r.down)
	return r
end

-- DIAGNOSTIC: is the enchant strip safe to switch on for THIS character's gear?
--
-- The strip has to read the equipped item through SetHyperlink, which the library
-- warns may report cached/nominal stats for a scaled instance instead of the real
-- one. That is unverifiable from here, so this measures it instead of guessing:
-- for each equipped slot it scores the item three ways --
--   real     : SetInventoryItem, the true instance (what we use today)
--   link     : SetHyperlink on the item's OWN link, unmodified
--   stripped : SetHyperlink on the link with the enchant zeroed
--
-- The test is `real` vs `link`. Those two describe the SAME item, so if they agree
-- then SetHyperlink is faithful on this client and `stripped` can be trusted; if
-- they disagree the link scan is lying and the option must stay off, whatever the
-- enchant is worth. `stripped` vs `link` is then just how much enchant was in the
-- score, which is the number that says whether any of this was worth doing.
--
-- Returns { { slot, name, real, link, stripped }, ... } for filled, scoreable slots.
function API:GetEnchantCheck()
	local out = {}
	if not (ScaledStats and ItemLink) then return out end
	local weights = currentWeights()
	if not weights then return out end
	for _, slotId in ipairs(Slots.DIAG_SLOT_IDS or {}) do
		local link = GetInventoryItemLink("player", slotId)
		if link then
			local name, _, _, _, _, _, subType, _, equipLoc = GetItemInfo(link)
			if equipLoc and Slots.slotsFor(equipLoc) then
				local stripped = ItemLink.stripEnchant(link)
				local function score(setter, ...)
					return Score.scoreItem(
						ScaledStats:GetStatsWithDps(setter, subType, equipLoc, ...), weights)
				end
				out[#out + 1] = {
					slot     = slotId,
					name     = name or "?",
					real     = score("SetInventoryItem", "player", slotId),
					link     = score("SetHyperlink", link),
					stripped = stripped and score("SetHyperlink", stripped) or nil,
				}
			end
		end
	end
	return out
end

-- DIAGNOSTIC: a flat copy of what the win ledger holds for this run, so the host's
-- report can show that the run tracking is actually recording things -- the one
-- half of BiS Check that CAN be exercised without a stale item dropping.
-- Returns { { equipLoc, count, bestScore, bestName }, ... }, sorted.
function API:GetRunLedger()
	if not WonLedger then return {} end
	local out = {}
	for _, equipLoc in ipairs(Slots.DIAG_EQUIPLOCS or {}) do
		local wins = WonLedger.winsFor(equipLoc)
		if wins and #wins > 0 then
			local best = WonLedger.bestFor(equipLoc)
			out[#out + 1] = {
				equipLoc = equipLoc, count = #wins,
				bestScore = best and best.score or 0,
				bestName = best and best.name or nil,
			}
		end
	end
	table.sort(out, function(a, b) return a.equipLoc < b.equipLoc end)
	return out
end

-- End the current run: drop everything the win ledger collected. Called by the
-- host when the zone changes (Core/BiSCleanup.lua), which is where "a run" is
-- defined -- the scanner does not watch zones itself, so the host's suggestion
-- window and this ledger can never disagree about when the run ended.
function API:EndRun()
	if WonLedger then WonLedger.clear() end
end

-- Readiness snapshot for a host that wants to SHOW whether the scanner can
-- actually advise -- PasslootBiS's rules page draws its advisor status panel from
-- this (Core/AdvisorStatus.lua). Purely descriptive: it reports state, it never
-- changes a roll, and it deliberately does NOT decide how any of it should read
-- to a user (wording and colour are the host's business).
--
-- The two capabilities are independent, exactly as they are on the roll path:
--   * gear    -- needs spec weights (upgrade scoring is idle without them).
--   * value   -- needs the Auctionator fork AND at least one finished AH scan;
--                the fork's price functions exist from login but answer nil
--                until a scan has written gAtr_ScanDB.
-- `version` lets a host tell this shape apart from a later one.
function API:GetStatus()
	local st = {
		version     = 1,
		loaded      = true,
		enabled     = (db and db.enabled) and true or false,
		placeholder = rawget(_G, "PLBiSScannerWeights_IsPlaceholder") and true or false,
	}
	if chardb then
		st.class, st.spec = chardb.class, chardb.spec
	end
	if db then
		st.threshold, st.goldThreshold = db.threshold, db.goldThreshold
		-- Reported so a host can SAY which way equipped gear is being scored; it
		-- changes what every number in a compare means (ns.equippedStats).
		st.ignoreEnchants = db.ignoreEnchants and true or false
	end

	-- currentWeights() is the same call the roll path makes, so "ready" here can
	-- never disagree with what actually happens on a roll -- including its
	-- inherit-spec-from-an-imported-BiS-list step (§5.4).
	local ok, weights = pcall(currentWeights)
	st.hasWeights = (ok and type(weights) == "table") or false
	-- Class/spec may have just been adopted by that call; re-read so a host that
	-- labels the row with the spec name shows the one actually in use.
	if chardb then
		st.class, st.spec = chardb.class, chardb.spec
	end
	st.gearReady = st.hasWeights and st.enabled

	st.auctionator = (Auctionator and Auctionator.liveProvider() ~= nil) or false
	if st.auctionator and Auctionator.liveScanCount then
		st.scanCount, st.scanCapped = Auctionator.liveScanCount()
	end
	-- No enabled-gate on the count itself, but an off scanner advises nothing.
	st.valueReady = st.auctionator and (st.scanCount or 0) > 0 and st.enabled

	return st
end

ns.API = API   -- reachable as _G.PLBiSScanner.API:GetRollVerdict(rollID)

-- Register ourselves as a PasslootBiS roll advisor when the host is present
-- (## OptionalDeps: PasslootBiS -> it loads first). OnReady is load-order-proof:
-- it fires now if the host is already enabled, else queues until it is. Guarded so
-- a missing/older host can never break login.
local function registerAdvisor()
	local host = rawget(_G, "PasslootBiS")
	if not (host and host.API and type(host.API.OnReady) == "function") then return end
	host.API:OnReady(function()
		if type(host.API.RegisterRollAdvisor) == "function" then
			host.API:RegisterRollAdvisor("PLScanner", ns.API)
		end
	end)
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

local ef = CreateFrame("Frame", "PLBiSScannerEvents")
ef:RegisterEvent("ADDON_LOADED")
ef:RegisterEvent("PLAYER_LOGIN")
ef:RegisterEvent("START_LOOT_ROLL")
ef:RegisterEvent("CANCEL_LOOT_ROLL")
-- Feeds the run's win ledger (BiS Check): what actually landed in your bags this
-- run is what the rest of the run gets compared against.
ef:RegisterEvent("CHAT_MSG_LOOT")

local function scannerOnEvent(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == "PassLootBiS_Scanner" then initDB(); initCharDB() end
	elseif event == "PLAYER_LOGIN" then
		if not db then initDB() end
		if not chardb then initCharDB() end
		ScaledStats = LibStub and LibStub("LibScaledStats-1.0", true)
		if not ScaledStats then
			chat("|cffff0000error|r: LibScaledStats-1.0 missing; scanner disabled.")
			db.enabled = false
			return
		end
		if rawget(_G, "PLBiSScannerWeights_IsPlaceholder") and not warnedPlaceholder then
			warnedPlaceholder = true
			chat("|cffffff00note|r: using PLACEHOLDER weights. Bake the real weights.json (see README) for accurate scores.")
		end
		-- Hand-rolled minimap button (Core/MinimapButton.lua); opens the settings
		-- window on left-click. Guarded call so a missing file can't break login.
		if ns.MinimapButton and ns.MinimapButton.Create then ns.MinimapButton.Create() end
		-- Offer our verdict to PasslootBiS's held-confirm roll advisor (act-path).
		pcall(registerAdvisor)
		chat("loaded. |cffffffff/plbisscan options|r for the settings window. Scanning is " ..
			(db.enabled and "|cff00ff00on|r" or "|cffff0000off|r") .. ".")
	elseif event == "START_LOOT_ROLL" then
		-- pcall so a scan error never disturbs the actual roll (§6.1).
		pcall(evaluateRoll, arg1)
	elseif event == "CANCEL_LOOT_ROLL" then
		if Alert and Alert.Hide then Alert.Hide() end
	elseif event == "CHAT_MSG_LOOT" then
		-- pcall for the same reason START_LOOT_ROLL has one: a scoring error here
		-- must never surface as a Lua error on every item you pick up.
		local link = WonLedger and
			WonLedger.linkFromLootMessage(arg1, buildLootPatterns()) or nil
		if link then pcall(recordWin, link) end
	end
end

ef:SetScript("OnEvent", scannerOnEvent)

----------------------------------------------------------------------
-- Debug dump (/plbisscan debug) -- diagnose why items score 0
----------------------------------------------------------------------
-- Self-contained on purpose: its own hidden tooltip and copy box, independent of
-- whichever LibScaledStats copy won LibStub (both addons embed it). Chat can't be
-- copied on this client, so the dump goes into a selectable EditBox (Ctrl+C).

local dbgTip, dbgFrame

-- Scan an equipped slot with a private hidden tooltip and return its raw lines
-- (left column, plus any right-column text appended) exactly as rendered.
local function debugScanLines(slotId)
	if not dbgTip then
		dbgTip = CreateFrame("GameTooltip", "PLBiSScannerDebugTip", nil, "GameTooltipTemplate")
	end
	dbgTip:SetOwner(UIParent, "ANCHOR_NONE")
	dbgTip:ClearLines()
	local lines = {}
	if not pcall(dbgTip.SetInventoryItem, dbgTip, "player", slotId) then return lines end
	for i = 1, dbgTip:NumLines() do
		local l = _G["PLBiSScannerDebugTipTextLeft" .. i]
		local r = _G["PLBiSScannerDebugTipTextRight" .. i]
		local lt = l and l:GetText() or ""
		local rt = r and r:GetText() or ""
		if lt ~= "" or rt ~= "" then
			lines[#lines + 1] = lt .. (rt ~= "" and ("   [R] " .. rt) or "")
		end
	end
	return lines
end

-- Format a copper amount as "Ng Ms Kc" for the debug dump (nil -> "nil").
local function moneyStr(copper)
	copper = tonumber(copper)
	if not copper then return "nil" end
	copper = math.floor(copper)
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100
	return string.format("%dg %ds %dc", g, s, c)
end

-- Build the full diagnostic text.
local function debugCollect()
	local out = {}
	local function add(s) out[#out + 1] = s or "" end

	add("== PLBiS Scanner debug ==")
	local weights = currentWeights()
	if weights then
		local wk = {}
		for k in pairs(weights) do wk[#wk + 1] = k end
		table.sort(wk)
		add("spec: " .. tostring(chardb.class) .. " / " .. tostring(chardb.spec))
		add("weight keys: " .. table.concat(wk, ", "))
	else
		add("weights: NONE resolved (class=" .. tostring(chardb.class) .. " spec=" .. tostring(chardb.spec) .. ")")
	end

	add("")
	add("== per-character armor/weapon filter (excluded = scored 0) ==")
	-- Shows which categories THIS character has switched off; an excluded item
	-- returns a 0 score and never alerts. Empty/absent -> everything included.
	local flt = charFilter()
	if Filter then
		local function line(cat, list)
			local off = {}
			for _, key in ipairs(list) do
				if not Filter.included(flt, cat, key) then off[#off + 1] = key end
			end
			add(cat .. ": " .. (#off > 0 and ("excluded { " .. table.concat(off, ", ") .. " }") or "all included"))
		end
		line("armor", Filter.ARMOR)
		line("weapons", Filter.WEAPONS)
	else
		add("Filter core not loaded")
	end
	local canDW = (rawget(_G, "CanDualWield") and CanDualWield()) and true or false
	add(string.format("dual wield: %s, off-hand DPS factor: %s (of full)",
		tostring(canDW), tostring((chardb and chardb.dwOffhandDps) or 0.5)))

	add("")
	add("== ITEM_MOD globals (raw format strings) ==")
	local names = {
		"ITEM_MOD_STRENGTH", "ITEM_MOD_STRENGTH_SHORT",
		"ITEM_MOD_AGILITY", "ITEM_MOD_AGILITY_SHORT",
		"ITEM_MOD_STAMINA", "ITEM_MOD_STAMINA_SHORT",
		"ITEM_MOD_INTELLECT", "ITEM_MOD_INTELLECT_SHORT",
		"ITEM_MOD_SPIRIT", "ITEM_MOD_SPIRIT_SHORT",
		"ITEM_MOD_CRIT_RATING", "ITEM_MOD_CRIT_RATING_SHORT",
		"ITEM_MOD_HASTE_RATING", "ITEM_MOD_HASTE_RATING_SHORT",
		"ITEM_MOD_HIT_RATING", "ITEM_MOD_HIT_RATING_SHORT",
		"ITEM_MOD_ATTACK_POWER", "ITEM_MOD_ATTACK_POWER_SHORT",
		"ITEM_MOD_SPELL_POWER", "ITEM_MOD_SPELL_POWER_SHORT",
		"ITEM_MOD_ARMOR_PENETRATION_RATING", "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT",
		"ITEM_MOD_RANGED_ATTACK_POWER", "ITEM_MOD_RANGED_ATTACK_POWER_SHORT",
		"ITEM_MOD_DAMAGE_PER_SECOND", "ITEM_MOD_DAMAGE_PER_SECOND_SHORT",
	}
	for _, n in ipairs(names) do add(n .. " = " .. tostring(rawget(_G, n))) end

	add("")
	add("== Auctionator (last-scanned Auction price) ==")
	-- Exercises the live fork read path (Integrations/Auctionator.lua): resolves the
	-- fork's globals and the "Auction" value per equipped item, so we can eyeball the
	-- copper values in-game. Never reads median/vendor -- same path as the gold flag.
	add("goldThreshold: " .. tostring(db.goldThreshold) .. " copper (" .. moneyStr(db.goldThreshold) .. ")")
	add("Atr_GetAuctionBuyout global: " .. type(rawget(_G, "Atr_GetAuctionBuyout")))
	add("Atr_GetAuctionPrice  global: " .. type(rawget(_G, "Atr_GetAuctionPrice")))
	local provider = Auctionator and Auctionator.liveProvider()
	if not provider then
		add("provider: NONE -- fork not loaded / no price fns (gold flag will be nil)")
	else
		for _, slot in ipairs({ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 16, 17, 18 }) do
			local link = GetInventoryItemLink("player", slot)
			if link then
				local price = Auctionator.priceFrom(provider, link)
				local name = GetItemInfo(link) or link
				add(string.format("-- slot %d: %s = %s", slot, name,
					price and (moneyStr(price) .. " (" .. price .. "c)") or "nil (unscanned)"))
			end
		end
	end

	add("")
	add("== equipped raw tooltip lines ==")
	-- head, neck, shoulder, chest, waist, legs, feet, wrist, hands, ring, ring,
	-- main hand, off hand, ranged.
	for _, slot in ipairs({ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 16, 17, 18 }) do
		local link = GetInventoryItemLink("player", slot)
		if link then
			add("-- slot " .. slot .. ": " .. link)
			for _, l in ipairs(debugScanLines(slot)) do add("    " .. l) end
		end
	end

	return table.concat(out, "\n")
end

-- Show text in a movable frame with a selectable multiline EditBox (Ctrl+C).
local function debugShow(text)
	if not dbgFrame then
		dbgFrame = CreateFrame("Frame", "PLBiSScannerDebugBox", UIParent)
		dbgFrame:SetWidth(520)
		dbgFrame:SetHeight(440)
		dbgFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
		-- Deliberately NOT ns.UI.applyWindowChrome (which uses MEDIUM): this is a
		-- copy/paste box you open to select text out of, so it has to float above
		-- whatever is on screen rather than sit under the Blizzard panels.
		-- Spike-free regardless, because it never calls SetToplevel.
		dbgFrame:SetFrameStrata("DIALOG")
		ns.UI.applyDarkBackdrop(dbgFrame)   -- shared house chrome (Core/UI.lua)
		dbgFrame:EnableMouse(true)
		dbgFrame:SetMovable(true)
		dbgFrame:RegisterForDrag("LeftButton")
		dbgFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
		dbgFrame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)

		local title = dbgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", dbgFrame, "TOP", 0, -14)
		title:SetText("PLBiS debug -- Ctrl+A then Ctrl+C to copy, then paste to Claude")

		local close = CreateFrame("Button", nil, dbgFrame, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", dbgFrame, "TOPRIGHT", -6, -6)

		local scroll = CreateFrame("ScrollFrame", "PLBiSScannerDebugBoxScroll", dbgFrame, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", dbgFrame, "TOPLEFT", 16, -40)
		scroll:SetPoint("BOTTOMRIGHT", dbgFrame, "BOTTOMRIGHT", -34, 16)

		local eb = CreateFrame("EditBox", "PLBiSScannerDebugBoxEdit", scroll)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject(ChatFontNormal)
		eb:SetWidth(460)
		eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		scroll:SetScrollChild(eb)
		dbgFrame.eb = eb
	end
	dbgFrame.eb:SetText(text)
	dbgFrame.eb:HighlightText()
	dbgFrame.eb:SetCursorPosition(0)
	dbgFrame:Show()
	dbgFrame.eb:SetFocus()
end

local function debugDump()
	local ok, textOrErr = pcall(debugCollect)
	if not ok then
		chat("|cffff0000debug failed|r: " .. tostring(textOrErr))
		return
	end
	debugShow(textOrErr)
	chat("debug dump opened -- select all (Ctrl+A), copy (Ctrl+C), paste to Claude.")
end

----------------------------------------------------------------------
-- Slash commands (§6.5)
----------------------------------------------------------------------

local function listSpecs()
	local data = rawget(_G, "PLBiSScannerWeights")
	if type(data) ~= "table" then chat("no weights loaded.") return end
	for _, cls in ipairs(SpecWeights.classes(data)) do
		local specs = SpecWeights.specs(data, cls)
		chat("|cffffd700" .. cls .. "|r: " .. table.concat(specs, ", "))
	end
	chat("set with |cffffffff/plbisscan spec <Class> | <Spec>|r")
end

SLASH_PLBISSCAN1 = "/plbisscan"
SLASH_PLBISSCAN2 = "/plbs"
SlashCmdList["PLBISSCAN"] = function(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "" or cmd == "status" then
		chat("scanning: " .. (db.enabled and "|cff00ff00on|r" or "|cffff0000off|r")
			.. ", spec: " .. (chardb.class and chardb.spec and (chardb.class .. " / " .. chardb.spec) or "|cffff0000none|r")
			.. ", threshold: " .. string.format("+%d%%", math.floor(db.threshold * 100 + 0.5)))
		chat("commands: options | filter | on | off | toggle | threshold <n%> | spec | spec <Class> | <Spec> | frame | chat | sound | soundgold | tooltip | debug | price <item>")
	elseif cmd == "on" then
		db.enabled = true; chat("scanning |cff00ff00on|r.")
	elseif cmd == "off" then
		db.enabled = false; chat("scanning |cffff0000off|r.")
	elseif cmd == "toggle" then
		db.enabled = not db.enabled
		chat("scanning " .. (db.enabled and "|cff00ff00on|r" or "|cffff0000off|r") .. ".")
	elseif cmd == "threshold" then
		local n = tonumber((rest:gsub("%%", "")))
		if n then
			db.threshold = n / 100
			chat("threshold set to " .. string.format("+%d%%", math.floor(db.threshold * 100 + 0.5)))
		else
			chat("usage: /plbisscan threshold 3")
		end
	elseif cmd == "options" or cmd == "config" or cmd == "gui" then
		if ns.Options and ns.Options.Toggle then
			ns.Options.Toggle()
		else
			chat("options window unavailable.")
		end
	elseif cmd == "filter" then
		-- Per-character armor/weapon inclusion picker.
		if ns.Options and ns.Options.ToggleFilter then
			ns.Options.ToggleFilter()
		else
			chat("filter window unavailable.")
		end
	elseif cmd == "debug" then
		-- Dump the raw stat-line data the scorer sees into a copyable popup, to
		-- diagnose 0-scores. Self-contained (own hidden tooltip + copy box) so it
		-- doesn't depend on whichever LibScaledStats copy won LibStub.
		debugDump()
	elseif cmd == "price" then
		-- Probe the fork's last-scanned Auction price for ONE specific item: shift-
		-- click an item into chat after the command (or type its exact name). Uses the
		-- same read path as the gold flag. Note: Soulbound gear never has AH scan data
		-- -- point this at an auctionable item (a BoE, or a trade good) to smoke-test.
		if rest == "" then
			chat("usage: /plbisscan price [shift-click an item into chat, or type its exact name]")
		elseif not Auctionator then
			chat("|cffff0000price|r: Auctionator integration not loaded.")
		else
			local provider = Auctionator.liveProvider()
			if not provider then
				chat("|cffff0000price|r: Auctionator fork not detected (no Atr_GetAuctionBuyout / Atr_GetAuctionPrice global).")
			else
				local name = GetItemInfo(rest) or rest
				local price = Auctionator.priceFrom(provider, rest)
				if price then
					local hit = (price >= (db.goldThreshold or 0)) and "  |cff00ff00>= threshold|r" or ""
					chat("|cffffd700" .. name .. "|r last-scanned Auction: " .. moneyStr(price) .. " (" .. price .. "c)" .. hit)
				else
					chat("|cffffd700" .. name .. "|r: no scan data (nil) -- scan it at the AH, or it may be unauctionable.")
				end
			end
		end
	elseif cmd == "spec" then
		local data = rawget(_G, "PLBiSScannerWeights")
		-- Normalize: WoW chat may double a typed pipe; accept | / , ; as separators.
		rest = (rest or ""):gsub("||", "|")
		-- Validate + set through the shared ns.setSpec path (same as the GUI).
		local function setSpec(cls, spc)
			local ok, c, s = ns.setSpec(cls, spc)
			if ok then
				chat("spec set to |cffffd700" .. c .. " / " .. s .. "|r.")
				if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
			end
			return ok
		end
		if rest == "" then
			listSpecs()
		else
			local a, b = rest:match("^(.-)%s*[|/,;]%s*(.+)$")
			if a and b then
				-- Explicit "Class SEP Spec" (case-insensitive).
				if not setSpec(a, b) then
					chat("no weights for '" .. a .. " / " .. b .. "'. Try |cffffffff/plbisscan spec|r to list.")
				end
			else
				-- A single token: a class name (list its specs) or a spec name (set it).
				local cls = SpecWeights.matchClass(data, rest)
				if cls then
					chat("|cffffd700" .. cls .. "|r specs: " .. table.concat(SpecWeights.specs(data, cls), ", "))
					chat("set with |cffffffff/plbisscan spec " .. cls .. " / <Spec>|r")
				else
					local hits = SpecWeights.findSpec(data, rest)
					if #hits == 1 then
						setSpec(hits[1].class, hits[1].spec)
					elseif #hits > 1 then
						local opts = {}
						for _, h in ipairs(hits) do opts[#opts + 1] = h.class .. " / " .. h.spec end
						chat("'" .. rest .. "' is in several classes: " .. table.concat(opts, ", ")
							.. ". Use |cffffffff/plbisscan spec <Class> / " .. rest .. "|r")
					else
						chat("no class or spec matching '" .. rest .. "'. Try |cffffffff/plbisscan spec|r to list.")
					end
				end
			end
		end
	elseif cmd == "frame" then
		db.useFrame = not db.useFrame
		chat("floating frame " .. (db.useFrame and "on" or "off") .. ".")
	elseif cmd == "chat" then
		db.useChat = not db.useChat
		chat("chat alerts " .. (db.useChat and "on" or "off") .. ".")
	elseif cmd == "sound" then
		db.useSound = not db.useSound
		chat("upgrade sound cue " .. (db.useSound and "on" or "off") .. ".")
	elseif cmd == "soundgold" then
		db.useSoundGold = not db.useSoundGold
		chat("high-value sound cue " .. (db.useSoundGold and "on" or "off") .. ".")
	elseif cmd == "tooltip" then
		db.tooltip = not db.tooltip
		chat("tooltip score/arrow " .. (db.tooltip and "on" or "off") .. ".")
	else
		chat("unknown command '" .. cmd .. "'. Try |cffffffff/plbisscan|r.")
	end
end

ns.Scanner = { evaluateRoll = evaluateRoll }   -- exposed for debugging
