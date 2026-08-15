--[[--------------------------------------------------------------------------
  LootTracker.lua  —  PasslootBiS module: passive loot-roll tracker

  Feeds the right-click "Loot Window" (Core/LootWindow.lua). It watches the group
  loot-roll chat and records, per item, WHO rolled WHAT (Need / Greed / Disenchant
  / Pass) and WHO WON — the data the window renders.

  Structure mirrors BiSRollLog.lua: the parse/aggregate core is pure and
  offline-unit-tested (self-test behind LOOTTRACKER_SELFTEST); every WoW-API touch
  lives in an in-game-only block guarded by real client globals, so the file loads
  clean in the client and under bare Lua 5.1.

  Robustness notes (the format assumptions are the flagged in-game unknowns —
  reference/minimap-loot-window-plan.md §7):
    * Patterns are BUILT FROM THE GLOBAL STRINGS at runtime (LOOT_ROLL_WON, …),
      never hardcoded English, so they follow whatever the client actually uses.
    * Field mapping uses the invariant WoW loot-string layout: the first token is
      the roller/winner, the last token is the item, and a middle numeric token
      (if present) is the roll value.
    * The exact global NAMES and whether the ROLLED_* lines arrive on
      CHAT_MSG_LOOT vs CHAT_MSG_SYSTEM vary; we register both and aggregation is
      idempotent (roll dedup by player, winner is a set), so double-delivery is
      harmless. Missing globals are skipped, not errored.

  Client target: WoW 3.3.5 (Ascension), Lua 5.1. No external libs.
----------------------------------------------------------------------------]]

local LootTracker = {}

--=============================================================================
-- 1. Pattern builder  -- pure. Turns a global-string template into a Lua match
--    pattern + an ordered list of capture types ("s"/"d").
--=============================================================================

-- Lua pattern magic characters that must be escaped in the LITERAL parts of a
-- format string (item links contain none of these in a way that matters, but the
-- templates do — e.g. "rolls Need - %d" has a "-").
local MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"
local function esc(ch)
	return (ch:gsub(MAGIC, "%%%0"))
end

-- Returns pattern, caps  (caps = { "s", "d", ... } in order of appearance).
-- %s -> greedy string capture, %d -> integer capture. Anchored at the start so a
-- roller name always begins the line.
function LootTracker.BuildPattern(template)
	local pat, caps = "^", {}
	local i, n = 1, #template
	while (i <= n) do
		local c = template:sub(i, i)
		if (c == "%") then
			local nxt = template:sub(i + 1, i + 1)
			if (nxt == "s") then
				pat = pat .. "(.+)"
				caps[#caps + 1] = "s"
				i = i + 2
			elseif (nxt == "d") then
				pat = pat .. "(%d+)"
				caps[#caps + 1] = "d"
				i = i + 2
			elseif (nxt == "%") then
				pat = pat .. "%%"
				i = i + 2
			else
				-- Positional/other specifier we don't model; treat the % literally.
				pat = pat .. "%%"
				i = i + 1
			end
		else
			pat = pat .. esc(c)
			i = i + 1
		end
	end
	return pat, caps
end

-- The roll-message families we care about, each with the candidate global names
-- to look up (first present wins). Order matters: more specific first.
LootTracker.SPECS = {
	{ kind = "roll",      choice = "need",       names = { "LOOT_ROLL_ROLLED_NEED" } },
	{ kind = "roll",      choice = "greed",      names = { "LOOT_ROLL_ROLLED_GREED" } },
	{ kind = "roll",      choice = "disenchant", names = { "LOOT_ROLL_ROLLED_DE", "LOOT_ROLL_ROLLED_DISENCHANT" } },
	{ kind = "roll",      choice = "pass",       names = { "LOOT_ROLL_ROLLED_PASS", "LOOT_ROLL_PASSED" } },
	{ kind = "won",       isSelf = true,         names = { "LOOT_ROLL_YOU_WON" } },
	{ kind = "won",       isSelf = false,        names = { "LOOT_ROLL_WON" } },
	{ kind = "allpassed",                        names = { "LOOT_ROLL_ALL_PASSED" } },
}

-- Build the ordered pattern table from a globals map (name -> template).
-- In-game, pass _G; in tests, pass a mock table.
function LootTracker.BuildPatterns(globals)
	globals = globals or {}
	local out = {}
	for _, spec in ipairs(LootTracker.SPECS) do
		local template
		for _, name in ipairs(spec.names) do
			if (type(globals[name]) == "string") then
				template = globals[name]
				break
			end
		end
		if (template) then
			local pat, caps = LootTracker.BuildPattern(template)
			out[#out + 1] = {
				pattern = pat, caps = caps,
				kind = spec.kind, choice = spec.choice, isSelf = spec.isSelf,
			}
		end
	end
	return out
end

--=============================================================================
-- 2. Message parser  -- pure. Given a chat line + prebuilt patterns, returns an
--    event { kind, choice?, player?, value?, item } or nil.
--=============================================================================

-- A capture is the ITEM token if it carries a hyperlink or a bracketed name. Used
-- to locate the item regardless of WHERE it sits in the string, because the token
-- order is not the same across clients (see the field-mapping note below).
local function isItemToken(s)
	if (type(s) ~= "string") then return false end
	return (s:find("|Hitem:", 1, true) ~= nil) or (s:find("[", 1, true) ~= nil)
end

function LootTracker.ParseMessage(line, patterns)
	if (type(line) ~= "string" or type(patterns) ~= "table") then
		return nil
	end
	for _, p in ipairs(patterns) do
		local m = { line:find(p.pattern) }
		if (m[1]) then
			local caps = {}
			for i = 3, #m do
				caps[#caps + 1] = m[i]
			end
			local ev = { kind = p.kind, choice = p.choice }
			-- Field mapping is POSITION-INDEPENDENT. The token order differs by
			-- client: Ascension's roll line is "<Choice> Roll - <value> for <item>
			-- by <player>" (value first, item middle, player LAST), whereas the
			-- retail-style line is "<player> rolls <Choice> - <value> for <item>"
			-- (player FIRST, item last). A fixed first=player/last=item rule
			-- mis-groups one of them (roller shown as the item, roll value shown as
			-- the player). Instead: the item is the capture that carries a
			-- link/bracket, the value is the numeric capture, and the player is
			-- whatever string capture is left over.
			local itemIdx
			for i = 1, #caps do
				if (isItemToken(caps[i])) then itemIdx = i; break end
			end
			ev.item = (itemIdx and caps[itemIdx]) or caps[#caps]
			if (p.kind ~= "allpassed") then
				if (p.isSelf) then
					ev.player = "you" -- resolved to UnitName("player") on apply
				end
				for i = 1, #caps do
					if (i ~= itemIdx) then
						local num = tonumber(caps[i])
						if (num) then
							ev.value = num
						elseif (not p.isSelf and not ev.player) then
							ev.player = caps[i] -- the leftover string is the roller/winner
						end
					end
				end
			end
			return ev
		end
	end
	return nil
end

--=============================================================================
-- 3. Item key  -- pure. A stable per-item identity so ROLLED and WON lines for
--    the same drop group together. Prefer itemID:suffix from the link; fall back
--    to the bracketed name.
--=============================================================================

function LootTracker.ItemKey(itemStr)
	if (type(itemStr) ~= "string") then
		return "?"
	end
	local id = itemStr:match("item:(%d+)")
	if (id) then
		local suffix = itemStr:match("item:%d+:%d+:%d+:%d+:%d+:%d+:(%-?%d+)")
		return id .. ":" .. (suffix or "0")
	end
	local name = itemStr:match("%[(.-)%]")
	if (name) then
		return "n:" .. name
	end
	return "s:" .. itemStr
end

local function itemName(itemStr)
	if (type(itemStr) ~= "string") then
		return "?"
	end
	return itemStr:match("|h%[(.-)%]|h") or itemStr:match("%[(.-)%]") or itemStr
end

--=============================================================================
-- 4. Log + aggregation  -- pure. A log is { groups = { <group>, ... },
--    openByKey = { key -> group } }. A group is one item's roll session.
--=============================================================================

function LootTracker.NewLog()
	return { groups = {}, openByKey = {} }
end

local function getOrOpen(log, itemStr)
	local key = LootTracker.ItemKey(itemStr)
	local g = log.openByKey[key]
	if (g and not g.closed) then
		return g
	end
	g = {
		key = key,
		link = itemStr,
		name = itemName(itemStr),
		rolls = {},
		rollByPlayer = {},
		winner = nil,
		allPassed = false,
		closed = false,
	}
	log.groups[#log.groups + 1] = g
	log.openByKey[key] = g
	return g
end
LootTracker._getOrOpen = getOrOpen

-- Open (or reuse) a group for an item — used by START_LOOT_ROLL so the item shows
-- in the window even if no individual roll line is captured.
function LootTracker.OpenRoll(log, itemStr)
	if (type(log) ~= "table" or type(itemStr) ~= "string") then
		return
	end
	return getOrOpen(log, itemStr)
end

-- Apply a parsed event to the log. playerName resolves the "you" sentinel.
function LootTracker.ApplyEvent(log, ev, playerName)
	if (type(log) ~= "table" or type(ev) ~= "table" or not ev.item) then
		return
	end
	local g = getOrOpen(log, ev.item)
	if (ev.kind == "roll") then
		local player = ev.player
		if (player == "you") then
			player = playerName or "You"
		end
		if (not player) then
			return g
		end
		local r = g.rollByPlayer[player]
		if (not r) then
			r = { player = player }
			g.rolls[#g.rolls + 1] = r
			g.rollByPlayer[player] = r
		end
		r.choice = ev.choice
		r.value = ev.value
	elseif (ev.kind == "won") then
		local player = ev.player
		if (player == "you") then
			player = playerName or "You"
		end
		g.winner = player
		g.closed = true
		log.openByKey[g.key] = nil
	elseif (ev.kind == "allpassed") then
		g.allPassed = true
		g.closed = true
		log.openByKey[g.key] = nil
	end
	return g
end

-- Rebuild a runtime log from a persisted groups array (no shared refs saved).
function LootTracker.Hydrate(groups)
	local log = LootTracker.NewLog()
	for _, g in ipairs(groups or {}) do
		g.rolls = g.rolls or {}
		g.rollByPlayer = {}
		for _, r in ipairs(g.rolls) do
			if (r.player) then
				g.rollByPlayer[r.player] = r
			end
		end
		log.groups[#log.groups + 1] = g
		if (not g.closed) then
			log.openByKey[g.key] = g
		end
	end
	return log
end

-- Cap the log to the most recent `max` groups (drop oldest); rebuild openByKey.
function LootTracker.Trim(log, max)
	max = max or 50
	local n = #log.groups
	if (n <= max) then
		return
	end
	local kept = {}
	for i = (n - max) + 1, n do
		kept[#kept + 1] = log.groups[i]
	end
	log.groups = kept
	log.openByKey = {}
	for _, g in ipairs(log.groups) do
		if (not g.closed) then
			log.openByKey[g.key] = g
		end
	end
end

-- Per-player need counts. Pure. Walks the groups oldest-first and, for each Need
-- roll, records the player's CONSECUTIVE need streak (any non-need roll of theirs
-- — greed / pass / disenchant — resets it to 0; items they didn't roll on don't
-- affect it) AND their cumulative TOTAL needs over the run (never reset). Returns
-- out[i] = { [player] = { streak = S, total = T } } for players who Needed in
-- group i. Display-only — never touches rolls/rules (feeds the Loot Window's
-- "needed N times consecutively / total" callouts).
function LootTracker.NeedCounts(groups)
	local streak, total, out = {}, {}, {}
	for i = 1, #(groups or {}) do
		local g = groups[i]
		out[i] = {}
		for _, r in ipairs((g and g.rolls) or {}) do
			if (r.player) then
				if (r.choice == "need") then
					streak[r.player] = (streak[r.player] or 0) + 1
					total[r.player] = (total[r.player] or 0) + 1
					out[i][r.player] = { streak = streak[r.player], total = total[r.player] }
				else
					streak[r.player] = 0
				end
			end
		end
	end
	return out
end

--=============================================================================
-- 5. In-game collector  -- WoW-API ONLY; skipped entirely under bare Lua 5.1.
--=============================================================================

if (rawget(_G, "CreateFrame") and rawget(_G, "GetLootRollItemLink")) then
	local addon
	local function A()
		if (not addon) then
			addon = LibStub("AceAddon-3.0"):GetAddon("PasslootBiS", true)
		end
		return addon
	end

	local patterns
	local function P()
		if (not patterns) then
			patterns = LootTracker.BuildPatterns(_G)
		end
		return patterns
	end

	--===========================================================================
	-- Raw-line diagnostic (/plbisloot). The exact LOOT_ROLL_ROLLED_* string names
	-- and formats on Ascension are a flagged in-game unknown; when a roll line is
	-- mis-parsed (roller shown as the item, the roll value shown as a player, etc.)
	-- we need the RAW chat string to fix the pattern/field mapping. This captures a
	-- small ring of recent CHAT_MSG_LOOT/SYSTEM lines with their parse result, and
	-- can print the actual template globals the parser is working from. Off by
	-- default (SYSTEM is chatty); toggle with `/plbisloot on`. Logging only — it
	-- never touches the pure parse/aggregate core.
	--===========================================================================
	local RING_MAX = 25
	local dbg = { on = false, ring = {} }
	LootTracker._dbg = dbg

	local function dbgPush(event, raw, ev)
		local ring = dbg.ring
		ring[#ring + 1] = { event = event, raw = raw, ev = ev }
		while (#ring > RING_MAX) do table.remove(ring, 1) end
	end

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("CHAT_MSG_LOOT")
	frame:RegisterEvent("CHAT_MSG_SYSTEM")
	frame:RegisterEvent("START_LOOT_ROLL")
	frame:SetScript("OnEvent", function(_, event, arg1)
		local a = A()
		if (not a or not a.LootTracker_Record) then
			return
		end
		if (event == "START_LOOT_ROLL") then
			local ok, link = pcall(_G.GetLootRollItemLink, arg1)
			if (ok and link) then
				pcall(function() a:LootTracker_OpenRoll(link) end)
			end
		else
			local ev = LootTracker.ParseMessage(arg1, P())
			if (dbg.on) then dbgPush(event, arg1, ev) end
			if (ev) then
				pcall(function() a:LootTracker_Record(ev) end)
			end
		end
	end)
	LootTracker._frame = frame

	-- Slash command:  /plbisloot [on|off|globals|dump|clear]
	if (rawget(_G, "SlashCmdList")) then
		local function out(line) if (rawget(_G, "print")) then print(line) end end
		-- The roll-string globals the parser derives its patterns from.
		local GLOBAL_NAMES = {
			"LOOT_ROLL_ROLLED_NEED", "LOOT_ROLL_ROLLED_GREED",
			"LOOT_ROLL_ROLLED_DE", "LOOT_ROLL_ROLLED_DISENCHANT",
			"LOOT_ROLL_ROLLED_PASS", "LOOT_ROLL_PASSED",
			"LOOT_ROLL_YOU_WON", "LOOT_ROLL_WON", "LOOT_ROLL_ALL_PASSED",
		}
		_G.SLASH_PLBISLOOT1 = "/plbisloot"
		_G.SlashCmdList["PLBISLOOT"] = function(msg)
			local cmd = (tostring(msg or ""):match("^%s*(%S*)") or ""):lower()
			if (cmd == "on") then
				dbg.on = true
				out("|cff33ff99PLBIS loot-tracker|r: raw-line capture |cff00ff00ON|r. Do a run, then '/plbisloot dump'.")
			elseif (cmd == "off") then
				dbg.on = false
				out("|cff33ff99PLBIS loot-tracker|r: raw-line capture |cffff0000OFF|r.")
			elseif (cmd == "clear") then
				dbg.ring = {}
				out("|cff33ff99PLBIS loot-tracker|r: captured lines cleared.")
			elseif (cmd == "globals") then
				out("|cff33ff99PLBIS loot-tracker|r roll-string globals (parser templates):")
				for _, n in ipairs(GLOBAL_NAMES) do
					out("  " .. n .. " = " .. (type(_G[n]) == "string" and ("|cffffffff" .. _G[n] .. "|r") or "|cff999999nil|r"))
				end
			else -- dump (default)
				out("|cff33ff99PLBIS loot-tracker|r captured (" .. #dbg.ring .. ", capture " ..
					(dbg.on and "|cff00ff00on|r" or "|cffff0000off|r") .. "):")
				if (#dbg.ring == 0) then
					out("  (none — '/plbisloot on', do a run, then '/plbisloot dump'. Also try '/plbisloot globals'.)")
				end
				for _, e in ipairs(dbg.ring) do
					out("  [" .. tostring(e.event) .. "] " .. tostring(e.raw))
					if (e.ev) then
						out(string.format("      -> kind=%s choice=%s player=%s value=%s item=%s",
							tostring(e.ev.kind), tostring(e.ev.choice), tostring(e.ev.player),
							tostring(e.ev.value), tostring(e.ev.item)))
					else
						out("      -> |cffff3333no match|r")
					end
				end
			end
		end
	end

	-- Attach so Core/LootWindow.lua can reach the pure helpers.
	local a0 = A()
	if (a0) then
		a0.LootTracker = LootTracker
	end
end

--=============================================================================
-- 6. Offline self-test (guarded in-game)
--    Usage:  lua5.1 -e 'LOOTTRACKER_SELFTEST=true' LootTracker.lua
--=============================================================================

if (rawget(_G, "LOOTTRACKER_SELFTEST")) then
	local function eq(got, want, label)
		if (got ~= want) then
			error(("%s: got %q want %q"):format(label, tostring(got), tostring(want)))
		end
	end

	-- Representative 3.3.5-shaped templates. The parser derives everything from
	-- these, so it validates the LOGIC (first=player, last=item, mid=value) and
	-- the magic-char escaping ("- %d") regardless of the exact English.
	local G = {
		LOOT_ROLL_ROLLED_NEED  = "%s rolls Need - %d for %s",
		LOOT_ROLL_ROLLED_GREED = "%s rolls Greed - %d for %s",
		LOOT_ROLL_ROLLED_DE    = "%s rolls Disenchant - %d for %s",
		LOOT_ROLL_ROLLED_PASS  = "%s passes on %s",
		LOOT_ROLL_WON          = "%s won: %s",
		LOOT_ROLL_YOU_WON      = "You won: %s",
		LOOT_ROLL_ALL_PASSED   = "Everyone passed on: %s",
	}
	local P = LootTracker.BuildPatterns(G)
	local LINK = "|cffa335ee|Hitem:412491:0:0:0:0:0:0:0:80|h[Embrace of the Lycan]|h|r"

	-- LT1: Need roll with a value + a magic "-" in the template.
	local e1 = LootTracker.ParseMessage(string.format(G.LOOT_ROLL_ROLLED_NEED, "Alice", 91, LINK), P)
	eq(e1.kind, "roll", "LT1 kind"); eq(e1.choice, "need", "LT1 choice")
	eq(e1.player, "Alice", "LT1 player"); eq(e1.value, 91, "LT1 value")
	eq(e1.item, LINK, "LT1 item")

	-- LT2: Greed roll.
	local e2 = LootTracker.ParseMessage(string.format(G.LOOT_ROLL_ROLLED_GREED, "Bob", 44, LINK), P)
	eq(e2.choice, "greed", "LT2 choice"); eq(e2.player, "Bob", "LT2 player"); eq(e2.value, 44, "LT2 value")

	-- LT3: Pass line has no value token.
	local e3 = LootTracker.ParseMessage(string.format(G.LOOT_ROLL_ROLLED_PASS, "Cara", LINK), P)
	eq(e3.choice, "pass", "LT3 choice"); eq(e3.player, "Cara", "LT3 player")
	eq(e3.value, nil, "LT3 no value")

	-- LT4: Someone else won.
	local e4 = LootTracker.ParseMessage(string.format(G.LOOT_ROLL_WON, "Alice", LINK), P)
	eq(e4.kind, "won", "LT4 kind"); eq(e4.player, "Alice", "LT4 winner"); eq(e4.item, LINK, "LT4 item")

	-- LT5: You won -> "you" sentinel.
	local e5 = LootTracker.ParseMessage(string.format(G.LOOT_ROLL_YOU_WON, LINK), P)
	eq(e5.kind, "won", "LT5 kind"); eq(e5.player, "you", "LT5 self sentinel")

	-- LT6: Everyone passed.
	local e6 = LootTracker.ParseMessage(string.format(G.LOOT_ROLL_ALL_PASSED, LINK), P)
	eq(e6.kind, "allpassed", "LT6 kind"); eq(e6.item, LINK, "LT6 item")

	-- LT7: ItemKey from link (id:suffix) and from a bare name.
	eq(LootTracker.ItemKey(LINK), "412491:0", "LT7 key id")
	eq(LootTracker.ItemKey("[Some Name]"), "n:Some Name", "LT7 key name")

	-- LT8: Aggregation — rolls collect, self win resolves, group closes.
	local log = LootTracker.NewLog()
	LootTracker.ApplyEvent(log, e1, "Me")          -- Alice Need 91
	LootTracker.ApplyEvent(log, e2, "Me")          -- Bob Greed 44
	LootTracker.ApplyEvent(log, e5, "Me")          -- "you won" -> Me
	eq(#log.groups, 1, "LT8 one group")
	local g = log.groups[1]
	eq(#g.rolls, 2, "LT8 two rolls"); eq(g.winner, "Me", "LT8 winner resolved")
	eq(g.closed, true, "LT8 closed")

	-- LT9: Roll dedup — same player rolling again replaces, not appends.
	local log2 = LootTracker.NewLog()
	LootTracker.ApplyEvent(log2, e1, "Me")
	LootTracker.ApplyEvent(log2, LootTracker.ParseMessage(
		string.format(G.LOOT_ROLL_ROLLED_GREED, "Alice", 12, LINK), P), "Me")
	eq(#log2.groups[1].rolls, 1, "LT9 dedup one roll")
	eq(log2.groups[1].rollByPlayer["Alice"].choice, "greed", "LT9 latest choice")

	-- LT10: Hydrate rebuilds openByKey + rollByPlayer; an open group stays open.
	local openLog = LootTracker.NewLog()
	LootTracker.ApplyEvent(openLog, e1, "Me")      -- open group, not closed
	local hy = LootTracker.Hydrate(openLog.groups)
	eq(#hy.groups, 1, "LT10 group survived")
	eq(hy.openByKey["412491:0"] ~= nil, true, "LT10 open group reindexed")
	eq(hy.groups[1].rollByPlayer["Alice"].value, 91, "LT10 rollByPlayer rebuilt")

	-- LT11: Trim keeps the most recent N.
	local big = LootTracker.NewLog()
	for i = 1, 10 do
		LootTracker.ApplyEvent(big, {
			kind = "won", player = "P" .. i,
			item = "|Hitem:" .. (1000 + i) .. ":0:0:0:0:0:0:0:80|h[I" .. i .. "]|h",
		}, "Me")
	end
	LootTracker.Trim(big, 4)
	eq(#big.groups, 4, "LT11 trimmed to 4")
	eq(big.groups[1].winner, "P7", "LT11 oldest dropped")

	-- LT12: the REAL Ascension roll format — "<Choice> Roll - <value> for <item>
	-- by <player>" (value first, item MIDDLE, player LAST). This is the opposite
	-- token order from the retail-style G above; the position-independent field
	-- mapping must group it under the item, not the roller. (Captured live from
	-- the client: "Need Roll - 17 for [Blackened Defias Armor] by Falku".)
	local GA = {
		LOOT_ROLL_ROLLED_NEED  = "Need Roll - %d for %s by %s",
		LOOT_ROLL_ROLLED_GREED = "Greed Roll - %d for %s by %s",
		LOOT_ROLL_ROLLED_PASS  = "%s passed on: %s",
		LOOT_ROLL_WON          = "%s won: %s",
		LOOT_ROLL_YOU_WON      = "You won: %s",
		LOOT_ROLL_ALL_PASSED   = "Everyone passed on: %s",
	}
	local PA = LootTracker.BuildPatterns(GA)

	local a1 = LootTracker.ParseMessage(string.format(GA.LOOT_ROLL_ROLLED_NEED, 17, LINK, "Falku"), PA)
	eq(a1.kind, "roll", "LT12 need kind"); eq(a1.choice, "need", "LT12 need choice")
	eq(a1.player, "Falku", "LT12 need player is LAST token"); eq(a1.value, 17, "LT12 need value")
	eq(a1.item, LINK, "LT12 need item is MIDDLE token")

	local a2 = LootTracker.ParseMessage(string.format(GA.LOOT_ROLL_ROLLED_GREED, 90, LINK, "Elotradawn"), PA)
	eq(a2.choice, "greed", "LT12 greed choice"); eq(a2.player, "Elotradawn", "LT12 greed player")
	eq(a2.value, 90, "LT12 greed value"); eq(a2.item, LINK, "LT12 greed item")

	-- Aggregation groups all three rolls under the one item, not under a roller.
	local alog = LootTracker.NewLog()
	LootTracker.ApplyEvent(alog, a1, "Me")
	LootTracker.ApplyEvent(alog, a2, "Me")
	eq(#alog.groups, 1, "LT12 one group (item, not roller)")
	eq(alog.groups[1].name, "Embrace of the Lycan", "LT12 topline is the item")

	-- LT13: Ascension won/passed are player-FIRST — the same mapping still holds.
	local a3 = LootTracker.ParseMessage(string.format(GA.LOOT_ROLL_WON, "Elotradawn", LINK), PA)
	eq(a3.kind, "won", "LT13 won kind"); eq(a3.player, "Elotradawn", "LT13 won player"); eq(a3.item, LINK, "LT13 won item")
	local a4 = LootTracker.ParseMessage(string.format(GA.LOOT_ROLL_ROLLED_PASS, "Thoorgrim", LINK), PA)
	eq(a4.choice, "pass", "LT13 pass choice"); eq(a4.player, "Thoorgrim", "LT13 pass player"); eq(a4.item, LINK, "LT13 pass item")

	-- LT14: an intent line ("X has selected Greed for: [item]") is NOT a roll and
	-- must not be captured (the numeric "Greed Roll" line is the real roll).
	eq(LootTracker.ParseMessage("Thalg has selected Greed for: " .. LINK, PA), nil, "LT14 intent line ignored")

	-- LT15: need counts — consecutive streak increments per Need in a row and is
	-- reset by a non-need roll of that player, while the total keeps climbing and
	-- never resets; non-participation is ignored; both are per-player (feed the
	-- Loot Window "needed N times consecutively / total" callouts).
	local ns = LootTracker.NewLog()
	local function nev(choice, player, id)
		return { kind = "roll", choice = choice, player = player,
		         item = "|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[i" .. id .. "]|h" }
	end
	LootTracker.ApplyEvent(ns, nev("need",  "Ninja", 1), "Me")   -- g1: Ninja need  -> streak 1 / total 1
	LootTracker.ApplyEvent(ns, nev("need",  "Ninja", 2), "Me")   -- g2: Ninja need  -> streak 2 / total 2
	LootTracker.ApplyEvent(ns, nev("greed", "Fair",  2), "Me")   -- g2: Fair greed  (no need entry)
	LootTracker.ApplyEvent(ns, nev("need",  "Ninja", 3), "Me")   -- g3: Ninja need  -> streak 3 / total 3
	LootTracker.ApplyEvent(ns, nev("greed", "Ninja", 4), "Me")   -- g4: Ninja greed -> streak reset
	LootTracker.ApplyEvent(ns, nev("need",  "Ninja", 5), "Me")   -- g5: Ninja need  -> streak 1 / total 4
	local S = LootTracker.NeedCounts(ns.groups)
	eq(S[1]["Ninja"].streak, 1, "LT15 g1 streak 1"); eq(S[1]["Ninja"].total, 1, "LT15 g1 total 1")
	eq(S[2]["Ninja"].streak, 2, "LT15 g2 streak 2"); eq(S[2]["Ninja"].total, 2, "LT15 g2 total 2")
	eq(S[2]["Fair"], nil, "LT15 g2 greed not a need")
	eq(S[3]["Ninja"].streak, 3, "LT15 g3 streak 3"); eq(S[3]["Ninja"].total, 3, "LT15 g3 total 3")
	eq(S[4]["Ninja"], nil, "LT15 g4 greed resets streak (no need entry)")
	eq(S[5]["Ninja"].streak, 1, "LT15 g5 streak restarts at 1")
	eq(S[5]["Ninja"].total, 4, "LT15 g5 total keeps climbing to 4")

	print("LootTracker self-test: all vectors passed.")
end

return LootTracker
