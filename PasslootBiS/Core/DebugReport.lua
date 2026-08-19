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
	out[#out + 1] = "  auto-confirm on roll:   " .. yn(p.AutoConfirmBindOnRoll)
	out[#out + 1] = "  auto-confirm on pickup: " .. yn(p.AutoConfirmBindOnPickup)
	out[#out + 1] = "  allow multiple popups:  " .. yn(p.AllowMultipleConfirmPopups)
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
local function addItemSection(out, link)
	out[#out + 1] = "[Item test] " .. tostring(link)
	local isBiS, list = PasslootBiS:IsBiSItem(GetItemInfoFromHyperlink(link), nil)
	if not isBiS then
		-- Retry by name: a list can match on exact name rather than id.
		local nm = PasslootBiS.RollRetry and PasslootBiS.RollRetry.NameFromLink(link)
		if nm then isBiS, list = PasslootBiS:IsBiSItem(nil, nm) end
	end
	out[#out + 1] = "  on a rolling BiS list: " .. yn(isBiS) .. (list and ("  (" .. list .. ")") or "")

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
