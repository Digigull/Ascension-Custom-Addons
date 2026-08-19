local PasslootBiS = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS")
local L = LibStub("AceLocale-3.0"):GetLocale("PasslootBiS")

--[[--------------------------------------------------------------------------
  DebugReport.lua  —  /plbisdebug: a copyable diagnostic + trace

  Chat on this client cannot be selected or copied, so a trace you can only READ
  is a trace you cannot report. Everything here exists to end up inside one
  selectable EditBox: Ctrl+A, Ctrl+C, paste.

  NOTHING IS PERSISTED. The trace ring, the on/off flag and the echo flag all live
  on the addon table, never in db.profile, so a /reload wipes the lot and no
  diagnostic state is ever left behind in SavedVariables (owner decision: the
  SavedVariables file is not a debug dump unless there is no alternative, and here
  there is one).

  Two flags, because they answer different questions:
    * DebugVar  — collect the trace at all. Buffered SILENTLY by default: this is
      meant to be left on through a boss fight, and a Debug() line per rule per
      roll would bury the fight in chat.
    * DebugEcho — additionally mirror each line to chat as it happens, for when you
      want to watch it live rather than read it afterwards.

  Strata: FULLSCREEN_DIALOG. It is a copy/paste box, which the strata table in
  management/docs/CLAUDE.md puts there — you open it to select text out of, so it
  has to float above whatever is on screen. Raise() on open is fine there (that
  strata is near-empty); SetToplevel is not, ever (management/docs/DRAG-FREEZE.md).
----------------------------------------------------------------------------]]

-- Ring capacity. 400 lines is a couple of boss pulls' worth of roll tracing, and
-- caps the copy box at something a chat window can actually take as a paste.
local MAX_LINES = 400

PasslootBiS.DebugLog = PasslootBiS.DebugLog or {}
PasslootBiS.DebugEcho = false

--=============================================================================
-- 1. The trace ring
--=============================================================================

-- Append one line. Called from PasslootBiS:Debug (Core/PassLoot.lua) — everything
-- already instrumented with Debug() lands here for free, which is the whole reason
-- the capture went there rather than at each call site.
function PasslootBiS:DebugCapture(line)
	local log = self.DebugLog
	log[#log + 1] = line
	if #log > MAX_LINES then
		-- Drop from the front. table.remove on a 400-entry array a few times a second
		-- is nothing next to the tooltip scans the roll path is doing anyway.
		table.remove(log, 1)
	end
end

function PasslootBiS:ClearDebugLog()
	self.DebugLog = {}
end

--=============================================================================
-- 2. Report sections
--=============================================================================

local function yn(v) return v and "yes" or "no" end

-- Signed percent. Rounds the MAGNITUDE and re-applies the sign: math.floor rounds
-- toward -infinity, so the obvious one-liner renders -12.4% as "-13%" -- next to a
-- "-12%" from Verdict.fmtDownDelta in the very same report. Same trap, third time.
local function pct(v)
	if type(v) ~= "number" then return "?" end
	local mag = math.floor(math.abs(v) * 100 + 0.5)
	return string.format("%s%d%%", v < 0 and "-" or "+", mag)
end

-- The scanner's advisor object, by the name it registers under — the same handle
-- Core/AdvisorStatus.lua uses, and for the same reason: an addon's namespace table
-- is private, so the registry entry is the supported way to reach it.
local function scannerAPI()
	local api = PasslootBiS.API
    if not (api and api.GetAdvisor) then return nil end
	return api:GetAdvisor("PLScanner")
end

local function addAdvisorSection(out)
	local api = PasslootBiS.API
	out[#out + 1] = "[Advisor]"
	if not api then
		out[#out + 1] = "  API: MISSING (Core/RollAdvisor.lua did not load)"
		return
	end
	out[#out + 1] = "  gate enabled: " .. yn(api.enabled) .. "   (API version " .. tostring(api.VERSION) .. ")"
	local names = api:GetAdvisorNames()
	if #names == 0 then
		out[#out + 1] = "  advisors: NONE REGISTERED  <- BiS Check cannot fire without one"
	end
	for _, name in ipairs(names) do
		out[#out + 1] = "  advisor: " .. name .. "  trust=" .. tostring(api:GetTrustMode(name))
	end
	out[#out + 1] = "  sources: gear=" .. yn(api:IsSourceEnabled("gear")) ..
		" value=" .. yn(api:IsSourceEnabled("value")) ..
		" bis=" .. yn(api:IsSourceEnabled("bis")) ..
		((not api:IsSourceEnabled("bis")) and "   <- BiS Check is SWITCHED OFF" or "")
end

local function addScannerSection(out)
	out[#out + 1] = "[Scanner]"
	local scanner = scannerAPI()
	if not scanner then
		out[#out + 1] = "  not registered as an advisor  <- BiS Check cannot score anything"
		return
	end
	local ok, st = pcall(scanner.GetStatus, scanner)
	if not ok or type(st) ~= "table" then
		out[#out + 1] = "  GetStatus failed: " .. tostring(st)
		return
	end
	out[#out + 1] = "  enabled: " .. yn(st.enabled) .. "   weights: " .. yn(st.hasWeights) ..
		((not st.hasWeights) and "  <- no spec, nothing can be scored" or "")
	out[#out + 1] = "  class/spec: " .. tostring(st.class) .. " / " .. tostring(st.spec) ..
		(st.placeholder and "   (PLACEHOLDER weights)" or "")
	out[#out + 1] = "  upgrade threshold: " .. pct(st.threshold)
end

local function addBiSListSection(out)
	out[#out + 1] = "[BiS lists]"
	local lists = PasslootBiS:EnumerateBiSLists()
	if #lists == 0 then
		out[#out + 1] = "  none  <- BiS Check has nothing to check against"
		return
	end
	for _, base in ipairs(lists) do
		local items = PasslootBiS:CollectBiSListItems(base)
		local rolling = 0
		for _, it in ipairs(items) do
			if it.rolls then rolling = rolling + 1 end
		end
		out[#out + 1] = string.format("  %s: %d items, %d rolling", base, #items, rolling)
	end
	-- Which rules carry the Before Advisor tick matters specifically here: those are
	-- the ones BiS Check has to outrank, so seeing them listed is the evidence that
	-- the ordering is being exercised at all.
	local rules = PasslootBiS.db and PasslootBiS.db.profile and PasslootBiS.db.profile.Rules
	if type(rules) == "table" then
		for i = 1, #rules do
			local r = rules[i]
			if r then
				out[#out + 1] = string.format("  rule %d: %s%s%s%s", i, tostring(r.Desc),
					r.Loot and (" loot=" .. table.concat(r.Loot, "/")) or "",
					r.BeforeAdvisor and " [BeforeAdvisor]" or "",
					r.Disabled and " [DISABLED]" or "")
			end
		end
	end
end

local function addRunSection(out)
	out[#out + 1] = "[This run]"
	local scanner = scannerAPI()
	local ledger = scanner and scanner.GetRunLedger and select(2, pcall(scanner.GetRunLedger, scanner))
	if type(ledger) ~= "table" then
		out[#out + 1] = "  win ledger: unavailable (older scanner?)"
	elseif #ledger == 0 then
		out[#out + 1] = "  win ledger: empty (nothing scoreable looted since the last zone change)"
	else
		for _, e in ipairs(ledger) do
			out[#out + 1] = string.format("  won %s: %d item(s), best %.1f (%s)",
				e.equipLoc, e.count, e.bestScore or 0, tostring(e.bestName))
		end
	end
	local stale = PasslootBiS:CollectStaleBiSItems()
	if #stale == 0 then
		out[#out + 1] = "  BiS Check vetoes: none this run"
	end
	for _, it in ipairs(stale) do
		out[#out + 1] = string.format("  vetoed %s (%s, %s)",
			tostring(it.name), tostring(it.list), PasslootBiS:FormatBiSDelta(it.delta))
	end
end

local function addConfirmSection(out)
	local p = PasslootBiS.db and PasslootBiS.db.profile
	if not p then return end
	out[#out + 1] = "[Bind confirms]"
	-- One line, because there is now one setting: it answers the roll prompt (the
	-- addon's own rolls AND ones you cast by hand) and the pickup prompt, and clears
	-- the popup-queue bit. The only bind prompt still left for you while this says
	-- yes is a disenchant, which keeps its per-rule Confirm DE opt-in. Anything else
	-- still asking for a click is a bug, and the [Trace] line to quote is
	-- "auto-confirming roll N" -- whether it is there at all, and which origin it
	-- names.
	out[#out + 1] = "  auto-confirm bind popups: " .. yn(p.AutoConfirmBinds)
	out[#out + 1] = "    covers hand-cast rolls: yes   disenchant: no (per-rule Confirm DE)"
end

-- Is the scanner's "ignore enchants" scoring still safe on THIS gear?
--
-- The option is ON by default, on the strength of this check, so this is not a
-- one-off decision aid -- it is the standing evidence for a default, and it is
-- worth re-reading it after a big gear change.
--
-- Stripping an enchant means reading the item through SetHyperlink, and
-- LibScaledStats warns that path may report cached or nominal stats for a scaled
-- instance. Rather than guess, this prints the measured answer: `real` and `link`
-- describe the SAME item by two routes, so if they agree the link scan is faithful
-- here. If any slot disagrees, untick the box -- an enchant skew is a known,
-- bounded error, and the scaled-stat lie is the unbounded one this whole addon
-- exists to avoid.
--
-- `stripped` vs `link` is then how much enchant is in each item: with the option on
-- that is what is being kept OUT of the compare, and with it off it is the skew you
-- are living with.
local function addEnchantSection(out)
	out[#out + 1] = "[Enchant strip check]"
	local scanner = scannerAPI()
	if not (scanner and scanner.GetEnchantCheck) then
		out[#out + 1] = "  unavailable (scanner not loaded, or older)"
		return
	end
	local ok, rows = pcall(scanner.GetEnchantCheck, scanner)
	if not ok or type(rows) ~= "table" then
		out[#out + 1] = "  check failed: " .. tostring(rows)
		return
	end
	if #rows == 0 then
		out[#out + 1] = "  nothing scoreable equipped (or no spec weights picked)"
		return
	end
	out[#out + 1] = "  slot  real   link   stripped  item"
	local mismatch, enchanted = 0, 0
	for _, r in ipairs(rows) do
		-- 0.5 of a weighted point: below that it is float noise in the tooltip
		-- numbers, not a different item being described.
		local drift = math.abs((r.real or 0) - (r.link or 0))
		if drift > 0.5 then mismatch = mismatch + 1 end
		if r.stripped and math.abs((r.link or 0) - r.stripped) > 0.5 then
			enchanted = enchanted + 1
		end
		out[#out + 1] = string.format("  %-4d  %-6.1f %-6.1f %-9s %s%s",
			r.slot, r.real or 0, r.link or 0,
			r.stripped and string.format("%.1f", r.stripped) or "-",
			tostring(r.name), drift > 0.5 and "   <- MISMATCH" or "")
	end
	local sok, st = pcall(scanner.GetStatus, scanner)
	local ignoring = sok and type(st) == "table" and st.ignoreEnchants
	if mismatch > 0 then
		out[#out + 1] = "  VERDICT: " .. mismatch ..
			" slot(s) score differently by link than by instance -- UNTICK 'Ignore" ..
			" enchants'; SetHyperlink is not faithful on this client."
	else
		out[#out + 1] = "  VERDICT: link and instance agree on every slot -- the strip is safe here."
		out[#out + 1] = "  " .. enchanted .. " slot(s) carry enchant value" ..
			(ignoring and " -- kept out of the compare." or " -- currently counted in their score.")
	end
	out[#out + 1] = "  option 'Ignore enchants' is currently: " .. yn(ignoring)
end

-- Push a synthetic downgrade through the REAL contract, in game, between the
-- INSTALLED copies of the two addons. The offline check in management/ proves the
-- two files in the repo agree; this proves the two folders in Interface\AddOns do,
-- which is the version that can actually be mismatched.
local function addContractSection(out)
	out[#out + 1] = "[Contract self-test]"
	local core = PasslootBiS.RollAdvisorCore
	if not core then
		out[#out + 1] = "  RollAdvisorCore missing -- cannot self-test"
		return
	end
	local wire = { downgrade = true, downDelta = -0.12, reason = "synthetic" }
	local v = core.ApplySources(core.NormalizeVerdict(wire), true, true, true)
	local pass = v and v.downgrade == true and core.IsActionable(v)
	out[#out + 1] = "  host reads a downgrade verdict: " .. (pass and "PASS" or "FAIL")
	local masked = core.ApplySources(core.NormalizeVerdict(wire), true, true, false)
	out[#out + 1] = "  bis source off suppresses it:   " ..
		((masked and not core.IsActionable(masked)) and "PASS" or "FAIL")
	-- And the scanner's own half, if it is here: does its builder still emit the
	-- field this host knows how to read?
	local scanner = scannerAPI()
	if scanner and scanner.GetLinkVerdict then
		out[#out + 1] = "  scanner exposes GetLinkVerdict:  PASS"
	else
		out[#out + 1] = "  scanner exposes GetLinkVerdict:  no (older scanner)"
	end
end

-- One item, dry-run through the live scoring path. The only way to exercise BiS
-- Check without waiting for the right stale item to drop off the right boss.
-- The "Not Usable" rule's verdict on one item, WITHOUT waiting for it to drop.
--
-- This is the half of the dry run that could not be exercised on demand. The
-- scanner half below scores any link you shift-click, but the rule filters only
-- ever ran inside a live START_LOOT_ROLL, so "why did this greed under Not Usable?"
-- needed the right item to drop off the right boss -- a dungeon per attempt, and
-- the drops are random (owner, 2026-08).
--
-- Routed through the module the rule itself uses rather than a copy of its logic:
-- a dry run that quietly disagreed with the live filter would be worse than no dry
-- run at all. SetMatch only reads itemObj.link, so a bare { link = link } is the
-- whole item this needs.
--
-- Leaving module.CurrentMatch set behind us is safe: EvaluateItem (Core/PassLoot.lua)
-- calls SetMatch on EVERY widget before it checks a single rule, so a real roll
-- always overwrites this first.
local function addUsableLine(out, link)
	local ok, mod = pcall(PasslootBiS.GetModule, PasslootBiS, L["Usable"], true)
	if not (ok and type(mod) == "table" and mod.Widget and mod.Widget.SetMatch) then
		out[#out + 1] = "  usable: Modules/Usable.lua not loaded -- cannot dry-run the rule"
		return
	end
	if not pcall(mod.Widget.SetMatch, mod.Widget, { link = link }, nil) then
		out[#out + 1] = "  usable: check failed"
		return
	end
	local match = mod.CurrentMatch
	local reason = PasslootBiS.UnusableReason and PasslootBiS:UnusableReason()
	-- The red line is the evidence, not decoration: "unusable" is inferred from the
	-- client painting a requirement red (Core/Cache.lua), so without it the verdict
	-- cannot be checked -- which is exactly how a pair of plainly wearable leather
	-- boots came to greed under Not Usable with nothing to say why.
	out[#out + 1] = "  usable: " .. yn(match == 2) ..
		"   (" .. tostring(match) .. " " .. tostring(mod:GetUsableText(match)) .. ")" ..
		(reason and ("   red lines: " .. reason) or "")
end

local function addItemSection(out, link)
	out[#out + 1] = "[Item test] " .. tostring(link)
	local isBiS, list = PasslootBiS:IsBiSItem(GetItemInfoFromHyperlink(link), nil)
	if not isBiS then
		-- Retry by name: a list can match on exact name rather than id.
		local nm = PasslootBiS.RollRetry and PasslootBiS.RollRetry.NameFromLink(link)
		if nm then isBiS, list = PasslootBiS:IsBiSItem(nil, nm) end
	end
	out[#out + 1] = "  on a rolling BiS list: " .. yn(isBiS) .. (list and ("  (" .. list .. ")") or "")
	addUsableLine(out, link)

	local scanner = scannerAPI()
	if not (scanner and scanner.GetLinkVerdict) then
		out[#out + 1] = "  scanner cannot dry-run this (not loaded, or older)"
		return
	end
	local ok, r = pcall(scanner.GetLinkVerdict, scanner, link, isBiS)
	if not ok or type(r) ~= "table" then
		out[#out + 1] = "  dry run failed: " .. tostring(r)
		return
	end
	if r.uncached then
		out[#out + 1] = "  item not cached yet -- run the command again in a second"
		return
	end
	out[#out + 1] = "  slot: " .. tostring(r.equipLoc) ..
		"  scannable=" .. yn(r.scannable) .. " weights=" .. yn(r.hadWeights) ..
		" filteredOut=" .. yn(r.filtered)
	if r.score == nil then
		out[#out + 1] = "  not scored -- one of the three above is the reason"
		return
	end
	out[#out + 1] = string.format("  score %.1f vs target %.1f  -> %s",
		r.score, r.target or 0, pct(r.delta))
	-- The working behind the target, slot by slot. Round 1 produced a feet dry run
	-- whose target was nowhere near what the same report scored the equipped feet at,
	-- and there was no way to tell from the outside which read had gone wrong -- the
	-- equipped scan, the win ledger, or the slot group being resolved to the wrong
	-- slot. This line says. A weapon/off-hand roll prints nothing here: that path
	-- resolves the whole loadout to one number with no per-slot breakdown to show.
	if type(r.targetParts) == "table" and #r.targetParts > 0 then
		local bits = {}
		for _, part in ipairs(r.targetParts) do
			local bit = string.format("slot %d = %.1f", part.slot, part.score or 0)
			if part.afterWins and math.abs(part.afterWins - (part.score or 0)) > 0.05 then
				bit = bit .. string.format(" (%.1f after wins)", part.afterWins)
			end
			bits[#bits + 1] = bit
		end
		out[#out + 1] = "  target from equipped: " .. table.concat(bits, ", ")
	end
	out[#out + 1] = "  would be an upgrade: " .. yn(r.isUpgrade)
	if r.down then
		out[#out + 1] = "  BiS Check WOULD VETO this roll: " .. PasslootBiS:FormatBiSDelta(r.down.delta) ..
			(r.down.wonName and ("  vs the " .. r.down.wonName .. " you won") or " vs equipped")
	else
		out[#out + 1] = "  BiS Check would not fire" ..
			(isBiS and "" or " (not on a rolling BiS list)")
	end
	if r.verdict then
		out[#out + 1] = "  verdict reason: " .. tostring(r.verdict.reason)
	end
end

-- Assemble the whole thing.
function PasslootBiS:BuildDebugReport(link)
	local out = {}
	out[#out + 1] = "PassLoot (BiS) diagnostic"
	out[#out + 1] = "trace: " .. (self.DebugVar and "on" or "off") ..
		"   echo to chat: " .. yn(self.DebugEcho) ..
		"   captured lines: " .. #self.DebugLog
	out[#out + 1] = ""
	addAdvisorSection(out); out[#out + 1] = ""
	addScannerSection(out); out[#out + 1] = ""
	addBiSListSection(out); out[#out + 1] = ""
	addRunSection(out);     out[#out + 1] = ""
	addConfirmSection(out); out[#out + 1] = ""
	addEnchantSection(out); out[#out + 1] = ""
	addContractSection(out)
	if link then
		out[#out + 1] = ""
		addItemSection(out, link)
	end
	out[#out + 1] = ""
	out[#out + 1] = "[Trace] " .. #self.DebugLog .. " line(s)" ..
		(self.DebugVar and "" or "  -- trace is OFF; /plbisdebug on to collect")
	for i = 1, #self.DebugLog do
		out[#out + 1] = "  " .. self.DebugLog[i]
	end
	return table.concat(out, "\n")
end

--=============================================================================
-- 3. The copy box
--=============================================================================

local box

local function makeBox()
	local f = CreateFrame("Frame", "PasslootBiSDebugBox", UIParent)
	f:SetWidth(560)
	f:SetHeight(460)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	-- FULLSCREEN_DIALOG, NOT the house MEDIUM chrome: this is a copy/paste box you
	-- open to select text out of, so it must float over whatever is on screen.
	-- No SetToplevel, ever (management/docs/DRAG-FREEZE.md).
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	PasslootBiS:ApplyDarkBackdrop(f)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetResizable(true)
	f:SetMinResize(360, 240)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
	f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing() end)

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOP", f, "TOP", 0, -14)
	f.title:SetText(L["DebugBox_Title"])

	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

	f.scroll = CreateFrame("ScrollFrame", "PasslootBiSDebugBoxScroll", f,
		"UIPanelScrollFrameTemplate")
	f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -40)
	f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 16)

	f.eb = CreateFrame("EditBox", "PasslootBiSDebugBoxEdit", f.scroll)
	f.eb:SetMultiLine(true)
	f.eb:SetAutoFocus(false)
	f.eb:SetFontObject(ChatFontNormal)
	f.eb:SetWidth(490)
	f.eb:SetScript("OnEscapePressed", function(eb) eb:ClearFocus() end)
	f.scroll:SetScrollChild(f.eb)

	-- Resize grip, so a long report can be made readable instead of scrolled.
	f.grip = CreateFrame("Button", nil, f)
	f.grip:SetWidth(16)
	f.grip:SetHeight(16)
	f.grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, -1)
	f.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	f.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	f.grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	f.grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		f.eb:SetWidth(f:GetWidth() - 70)
	end)
	return f
end

function PasslootBiS:ShowDebugBox(text)
	if not box then box = makeBox() end
	box.eb:SetText(text)
	box:Show()
	-- Raise is safe here and only here: FULLSCREEN_DIALOG is near-empty, so the
	-- restack is cheap (management/docs/DRAG-FREEZE.md). Never do this on MEDIUM.
	box:Raise()
	-- Focus + select-all last, and cursor to the top so the paste starts at line 1.
	box.eb:SetFocus()
	box.eb:HighlightText()
	box.eb:SetCursorPosition(0)
end

--=============================================================================
-- 4. /plbisdebug
--=============================================================================

function PasslootBiS:DebugCommand(input)
	input = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local word = input:match("^(%S*)"):lower()
	local rest = input:match("^%S*%s+(.*)$")

	if word == "on" then
		self.DebugVar = true
		self:Print(L["DebugCmd_On"])
	elseif word == "off" then
		self.DebugVar = false
		self:Print(L["DebugCmd_Off"])
	elseif word == "chat" then
		self.DebugEcho = not self.DebugEcho
		self:Print("trace echo to chat: " .. (self.DebugEcho and "on" or "off"))
	elseif word == "clear" then
		self:ClearDebugLog()
		self:Print("trace cleared.")
	elseif word == "item" then
		-- Shift-clicking an item into the chat box pastes its full link, so `rest` is
		-- the link itself. Anything without |Hitem: in it cannot be dry-run.
		if not rest or not rest:find("|Hitem:", 1, true) then
			self:Print(L["DebugCmd_ItemUsage"])
			return
		end
		self:ShowDebugBox(self:BuildDebugReport(rest))
	elseif word == "show" or word == "" then
		self:ShowDebugBox(self:BuildDebugReport(nil))
	else
		self:Print(L["DebugCmd_Usage"])
	end
end

if PasslootBiS.RegisterChatCommand then
	PasslootBiS:RegisterChatCommand("plbisdebug", "DebugCommand")
end
