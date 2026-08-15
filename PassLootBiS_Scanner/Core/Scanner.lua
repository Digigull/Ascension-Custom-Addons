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
	_G.PLBiSScanner = ns
end

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

local ScaledStats  -- resolved from LibStub at login

----------------------------------------------------------------------
-- SavedVariables + defaults
----------------------------------------------------------------------

local DEFAULTS = {
	enabled       = true,
	threshold     = 0.03,   -- +3% minimum delta to call an upgrade (§6.3)
	strongDelta   = 0.10,   -- >= +10% counts as a "strong" upgrade (sound cue)
	-- class/spec are PER-CHARACTER (a character is exactly one class); they live in
	-- chardb, not here -- see initCharDB. Kept out of the account-wide DEFAULTS.
	useChat       = true,
	useFrame      = false,  -- floating frame off by default; chat is the safe minimum
	useSound      = false,
	tooltip       = true,   -- annotate item tooltips with score + upgrade arrow
	goldThreshold = 500000, -- 50g in copper, for the Auctionator flag (Phase 4)
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
-- The compare flow
----------------------------------------------------------------------

-- Read an item's full stats (armor + secondaries + weapon DPS) through the
-- library, so both sides of the compare use the same path.
local function scoreRollItem(rollID, weights, subType, equipLoc)
	local stats = ScaledStats:GetStatsWithDps("SetLootRollItem", subType, equipLoc, rollID)
	return Score.scoreItem(stats, weights), stats
end

local function scoreEquipped(slotId, weights, subType, equipLoc)
	-- An empty slot -> no lines -> empty stats -> score 0 (always beatable).
	local stats = ScaledStats:GetStatsWithDps("SetInventoryItem", subType, equipLoc, "player", slotId)
	return Score.scoreItem(stats, weights)
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
	local stats = ScaledStats:GetStatsWithDps("SetInventoryItem", subType, eqLoc, "player", slotId)
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

-- Shared compare core: score the rolled item vs. the worst equipped in its slot
-- group and read the optional Auctionator high-value flag. Used by BOTH the
-- scanner's own alert (evaluateRoll) and the roll-advisor verdict (ns.API), so the
-- two can never disagree. Returns a compare table, or nil if there's no roll link.
-- `scannable` is false for non-equippable slots or when no spec weights are picked
-- (then isUpgrade=false, delta=0); the gold flag is still evaluated in both cases.
local function compareRoll(rollID)
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
	local slotIds = Slots.slotsFor(equipLoc)
	local weights = currentWeights()
	-- Per-character armor/weapon filter: an unchecked category scores 0 (never an
	-- upgrade). Non-filterable items (necks, rings, trinkets, ...) always score.
	local scored = (not Filter) or Filter.isScored(itemType, subType, charFilter(), equipLoc)

	local isUpgrade, delta = false, 0
	if slotIds and weights and scored then
		local rollScore = scoreRollItem(rollID, weights, subType, equipLoc)
		-- Weapons/off-hands use the loadout rule (1H vs 2H, dual wield); everything
		-- else uses the worst equipped in the slot group as the target (§6.2).
		local target = ns.weaponEquippedValue(equipLoc, weights)
		if target == nil then
			local scores = {}
			for i, slotId in ipairs(slotIds) do
				scores[i] = scoreEquipped(slotId, weights, subType, equipLoc)
			end
			target = Slots.worstEquipped(scores)
		end
		isUpgrade, delta = Score.verdict(rollScore, target, db.threshold)
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
		strong   = r.isUpgrade and (r.delta >= db.strongDelta),
		goldText = r.goldFlag and r.goldFlag.text or nil,
		isBiS    = false,   -- TODO: mark BiS picks from an imported list (§6.3)
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

function API:GetRollVerdict(rollID)
	if not db or not db.enabled then return nil end
	local r = compareRoll(rollID)
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
	local goldText = r.goldFlag and r.goldFlag.text or nil
	return Verdict.build(r.isUpgrade, r.delta, goldText)
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
	end
end

-- Opt into ClientPerfProbe per-handler timing when that measuring addon is present
-- (github.com/Digigull/Ascension-Stutter). Guarded + pass-through: probe absent =>
-- ClientPerfProbe is nil => the bare handler is used and nothing changes. Times the
-- START_LOOT_ROLL scoring path as a P^ row (BiSScanner:OnEvent) in /cpp.
ef:SetScript("OnEvent",
	(ClientPerfProbe and ClientPerfProbe.Wrap("BiSScanner:OnEvent", scannerOnEvent)) or scannerOnEvent)

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
		-- Deliberately NOT ns.UI.applyWindowChrome (which uses LOW): this is a
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
		chat("commands: options | filter | on | off | toggle | threshold <n%> | spec | spec <Class> | <Spec> | frame | chat | sound | tooltip | debug | price <item>")
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
	elseif cmd == "dragtest" then
		-- Spawn four movable frames that isolate the window-drag-freeze cause
		-- (Core/DragTest.lua). Cold client, then drag each ONE at a time.
		if ns.DragTest and ns.DragTest.toggle then
			local shown = ns.DragTest.toggle()
			if shown then
				chat("drag-freeze isolation frames |cff44ff44shown|r. Cold (or |cffffffff/reload|r) first, then drag each ONE at a time:")
				chat("  |cffffffffA|r repro (should freeze) · |cffffffffB|r no toplevel · |cffffffffC|r lighter strata · |cffffffffD|r no children")
				chat("Note which HITCH. With ClientPerfProbe on: |cffffffff/cpp clear|r, drag one, |cffffffff/cpp|r reads a sus=DRAG spike per frame.")
			else
				chat("drag-freeze isolation frames hidden.")
			end
		else
			chat("dragtest harness unavailable.")
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
		chat("sound cue " .. (db.useSound and "on" or "off") .. ".")
	elseif cmd == "tooltip" then
		db.tooltip = not db.tooltip
		chat("tooltip score/arrow " .. (db.tooltip and "on" or "off") .. ".")
	else
		chat("unknown command '" .. cmd .. "'. Try |cffffffff/plbisscan|r.")
	end
end

ns.Scanner = { evaluateRoll = evaluateRoll }   -- exposed for debugging
